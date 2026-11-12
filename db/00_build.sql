-- Build into a dedicated empty Oracle schema / 在专用空 schema 中建库
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON
SET FEEDBACK ON
SET LINESIZE 160
DECLARE
    object_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO object_count FROM user_objects;
    IF object_count <> 0 OR SYS_CONTEXT('USERENV','CURRENT_SCHEMA') <> USER THEN
        RAISE_APPLICATION_ERROR(-20860, 'Build requires an empty schema owned by the connected account');
    END IF;
END;
/
@@01_schema.sql
@@02_seed.sql
@@03_circulation_api.sql
DECLARE
    table_count NUMBER;
    error_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO table_count FROM user_tables;
    SELECT COUNT(*) INTO error_count FROM user_errors;
    IF table_count <> 11 OR error_count <> 0 THEN
        RAISE_APPLICATION_ERROR(-20861, 'Expected 11 tables and no compile errors');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OPEN_SHELF_BUILD=PASS');
END;
/
