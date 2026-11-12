-- Explicit reset of this application's objects in an Open Shelf Books schema.
-- 仅在 Open Shelf Books 的专用 schema 内显式重置对象。
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET SERVEROUTPUT ON
DECLARE
    PROCEDURE drop_if_present(statement VARCHAR2, missing_code NUMBER) IS
    BEGIN
        EXECUTE IMMEDIATE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE <> missing_code THEN RAISE; END IF;
    END;
BEGIN
    IF NOT REGEXP_LIKE(USER, '^OPEN_SHELF_BOOKS(_[A-Z][A-Z0-9_]{0,10})?$')
       OR SYS_CONTEXT('USERENV','CURRENT_SCHEMA') <> USER THEN
        RAISE_APPLICATION_ERROR(-20863, 'Reset requires an Open Shelf Books schema owned by the connected account');
    END IF;
    drop_if_present('DROP VIEW v_active_loans', -942);
    drop_if_present('DROP VIEW v_copy_availability', -942);
    drop_if_present('DROP PACKAGE circulation_api', -4043);
    drop_if_present('DROP TABLE OSB_DDL_PROBE PURGE', -942);
    drop_if_present('DROP TABLE renewal PURGE', -942);
    drop_if_present('DROP TABLE reservation PURGE', -942);
    drop_if_present('DROP TABLE loan PURGE', -942);
    drop_if_present('DROP TABLE title_author PURGE', -942);
    drop_if_present('DROP TABLE book_copy PURGE', -942);
    drop_if_present('DROP TABLE author PURGE', -942);
    drop_if_present('DROP TABLE book_title PURGE', -942);
    drop_if_present('DROP TABLE publisher PURGE', -942);
    drop_if_present('DROP TABLE staff PURGE', -942);
    drop_if_present('DROP TABLE lib_member PURGE', -942);
    drop_if_present('DROP TABLE member_type PURGE', -942);
    DBMS_OUTPUT.PUT_LINE('OPEN_SHELF_RESET=PASS');
END;
/
