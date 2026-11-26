SET SERVEROUTPUT ON
SET PAGESIZE 100
SET LINESIZE 160
SHOW USER
SELECT table_name FROM user_tables ORDER BY table_name;
SELECT COUNT(*) AS total_loans,
       COUNT(CASE WHEN returned_on IS NULL THEN 1 END) AS open_loans
FROM loan;
@db/04_reports.sql
