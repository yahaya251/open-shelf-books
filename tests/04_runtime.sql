-- Oracle版本、对象健康、种子状态及安全DDL验证 / Version, health, seed and disposable DDL probe
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET ECHO OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON
SET PAGESIZE 0
SET LINESIZE 160
SELECT 'PRODUCT='||product||' / '||version_full FROM product_component_version WHERE product LIKE 'Oracle%';
SELECT 'SCHEMA='||SYS_CONTEXT('USERENV','SESSION_USER')||' PDB='||SYS_CONTEXT('USERENV','CON_NAME') FROM dual;
SELECT 'TABLES='||COUNT(*) FROM user_tables;
SELECT 'FOREIGN_KEYS='||COUNT(*) FROM user_constraints WHERE constraint_type='R' AND status='ENABLED';
SELECT 'INVALID_OBJECTS='||COUNT(*) FROM user_objects WHERE status='INVALID';
SELECT 'USER_ERRORS='||COUNT(*) FROM user_errors;
SELECT 'BOOK_TITLES='||COUNT(*) FROM book_title;
SELECT 'BOOK_COPIES='||COUNT(*) FROM book_copy;
SELECT 'MEMBERS='||COUNT(*) FROM lib_member;
SELECT 'LOANS='||COUNT(*) FROM loan;
SELECT 'ACTIVE_LOANS='||COUNT(*) FROM loan WHERE returned_on IS NULL;
SELECT 'ACTIVE_HOLDS='||COUNT(*) FROM reservation WHERE reservation_status='ACTIVE';
SELECT 'OVERDUE_ON_2026-10-29='||COUNT(*) FROM loan WHERE returned_on IS NULL AND TRUNC(due_on)<DATE '2026-10-29';
SELECT 'LENDABLE_COPIES='||COUNT(*) FROM v_copy_availability WHERE can_lend='YES';
CREATE TABLE OSB_DDL_PROBE (id NUMBER PRIMARY KEY);
ALTER TABLE OSB_DDL_PROBE ADD (label VARCHAR2(20));
DROP TABLE OSB_DDL_PROBE PURGE;
SELECT 'DDL_CREATE_ALTER_DROP=PASS' FROM dual;
DECLARE
  actual_count NUMBER;
  PROCEDURE verify(expected NUMBER, actual NUMBER, label VARCHAR2) IS
  BEGIN
    IF expected <> actual THEN RAISE_APPLICATION_ERROR(-20980, label || ' expected=' || expected || ' actual=' || actual); END IF;
  END;
BEGIN
  SELECT COUNT(*) INTO actual_count FROM user_tables; verify(11, actual_count, 'Tables');
  SELECT COUNT(*) INTO actual_count FROM user_constraints WHERE constraint_type='R' AND status='ENABLED';
  verify(12, actual_count, 'Enabled foreign keys');
  SELECT COUNT(*) INTO actual_count FROM user_errors; verify(0, actual_count, 'USER_ERRORS');
  SELECT COUNT(*) INTO actual_count FROM user_objects WHERE status='INVALID'; verify(0, actual_count, 'Invalid objects');
  SELECT COUNT(*) INTO actual_count FROM loan; verify(8, actual_count, 'Baseline loan count');
  SELECT COUNT(*) INTO actual_count FROM loan WHERE returned_on IS NULL; verify(5, actual_count, 'Active loans');
  SELECT COUNT(*) INTO actual_count FROM loan WHERE loan_id=1 AND returned_on IS NULL;
  verify(1, actual_count, 'Demo state rollback');
  DBMS_OUTPUT.PUT_LINE('RUNTIME_CHECKS=PASS');
END;
/
