-- 四条展示语句及实测输出 / Four showcased statements and observed output
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET ECHO OFF
SET VERIFY OFF
SET SERVEROUTPUT ON
SET FEEDBACK ON
SET PAGESIZE 40
SET LINESIZE 110
SET DEFINE OFF
SET TAB OFF
SET COLSEP '  '
ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD';
COLUMN banner_full FORMAT A92
COLUMN title_name FORMAT A29
COLUMN matric_no FORMAT A13
COLUMN barcode FORMAT A13
COLUMN loan_id FORMAT 999999
COLUMN due_on FORMAT A10
COLUMN days_overdue FORMAT 999999
COLUMN title_id FORMAT 999999
COLUMN total_loans FORMAT 9999999999
COLUMN active_loans FORMAT 99999999999
COLUMN waiting_members FORMAT 99999999999999
PROMPT [Environment / 环境]
SET FEEDBACK OFF
SET HEADING OFF
SELECT product||' / '||version_full FROM product_component_version WHERE product LIKE 'Oracle%';
SELECT 'Schema '||SYS_CONTEXT('USERENV','SESSION_USER')||' on '||SYS_CONTEXT('USERENV','CON_NAME') FROM dual;
SELECT 'Visible tables: BOOK_TITLE, BOOK_COPY, LOAN, RESERVATION' FROM dual;
SELECT 'Schema tables = '||COUNT(*) FROM user_tables;
SET HEADING ON
SET FEEDBACK ON
PROMPT [Q1] Outstanding loans and days overdue / 未归还与逾期
SELECT l.loan_id,m.matric_no,t.title_name,c.barcode,l.due_on,
       GREATEST(DATE '2026-10-29'-TRUNC(l.due_on),0) AS days_overdue
FROM LOAN l JOIN LIB_MEMBER m ON m.member_id=l.member_id
JOIN BOOK_COPY c ON c.copy_id=l.copy_id JOIN BOOK_TITLE t ON t.title_id=c.title_id
WHERE l.returned_on IS NULL ORDER BY l.due_on,l.loan_id;
PROMPT [Q2] Loan totals by title / 按书目汇总借阅
SELECT t.title_id,t.title_name,COUNT(l.loan_id) AS total_loans,
       SUM(CASE WHEN l.loan_id IS NOT NULL AND l.returned_on IS NULL THEN 1 ELSE 0 END) AS active_loans
FROM BOOK_TITLE t LEFT JOIN BOOK_COPY c ON c.title_id=t.title_id
LEFT JOIN LOAN l ON l.copy_id=c.copy_id
GROUP BY t.title_id,t.title_name ORDER BY total_loans DESC,t.title_id;
PROMPT [Q3] Unmet reservation demand / 待满足的预约需求
SELECT t.title_id,t.title_name,COUNT(*) AS waiting_members
FROM RESERVATION r JOIN BOOK_TITLE t ON t.title_id=r.title_id
WHERE r.reservation_status='ACTIVE' AND NOT EXISTS
 (SELECT 1 FROM BOOK_COPY c WHERE c.title_id=t.title_id AND c.copy_status='AVAILABLE'
  AND NOT EXISTS (SELECT 1 FROM LOAN l WHERE l.copy_id=c.copy_id AND l.returned_on IS NULL))
GROUP BY t.title_id,t.title_name ORDER BY waiting_members DESC,t.title_id;
SAVEPOINT demo_return;
PROMPT [Q4] Return a loan / 归还借阅
BEGIN circulation_api.return_loan(1, DATE '2026-10-29'); END;
/
SET FEEDBACK OFF
SET HEADING OFF
SELECT 'Loan '||loan_id||' returned_on = '||TO_CHAR(returned_on,'YYYY-MM-DD') FROM loan WHERE loan_id=1;
SELECT 'Copy '||copy_id||' can_lend = '||can_lend FROM v_copy_availability WHERE copy_id=1;
PROMPT [Rollback / 回滚]
ROLLBACK TO demo_return;
SELECT 'Restored baseline: loan 1 active = '||COUNT(*) FROM loan WHERE loan_id=1 AND returned_on IS NULL;
SET HEADING ON
SET FEEDBACK ON

DECLARE
    total_loans NUMBER;
    open_loans NUMBER;
    demo_loan_open NUMBER;
BEGIN
    SELECT COUNT(*) INTO total_loans FROM loan;
    SELECT COUNT(*) INTO open_loans FROM loan WHERE returned_on IS NULL;
    SELECT COUNT(*) INTO demo_loan_open FROM loan WHERE loan_id=1 AND returned_on IS NULL;
    IF total_loans <> 8 OR open_loans <> 5 OR demo_loan_open <> 1 THEN
        RAISE_APPLICATION_ERROR(-20862, 'Demo rollback did not restore the fixture baseline');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OPEN_SHELF_DEMO=PASS');
END;
/
