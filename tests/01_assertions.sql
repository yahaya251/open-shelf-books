-- Oracle positive and negative assertions with fixture rollback.
-- Run on the freshly built schema. Oracle executes these tests, no mocks.
-- Test fixtures and API changes are rolled back; identity gaps are expected.
SET SERVEROUTPUT ON
SET ECHO ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SAVEPOINT project_test;
DECLARE
 v_id NUMBER; v_loan NUMBER; v_hold NUMBER; v_count NUMBER; v_due DATE;
 v_tests NUMBER:=0;
 PROCEDURE ok(p_condition BOOLEAN,p_label VARCHAR2) IS BEGIN
  IF p_condition IS NULL OR NOT p_condition THEN
   RAISE_APPLICATION_ERROR(-20999,'FAIL: '||p_label);
  END IF;
  v_tests:=v_tests+1; DBMS_OUTPUT.PUT_LINE('PASS '||TO_CHAR(v_tests)||': '||p_label);
 END;
 PROCEDURE rejects(p_sql VARCHAR2,p_code NUMBER,p_label VARCHAR2) IS
  v_actual NUMBER:=0;
 BEGIN
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN v_actual:=SQLCODE; END;
  ok(v_actual=p_code,p_label||' (expected '||p_code||', got '||v_actual||')');
 END;
BEGIN
 SELECT COUNT(*) INTO v_count FROM USER_ERRORS WHERE name='CIRCULATION_API';
 ok(v_count=0,'Oracle package has no compilation errors');
 INSERT INTO MEMBER_TYPE VALUES(900,'Test small quota',1,7,3);
 INSERT INTO LIB_MEMBER VALUES(900,'TEST900','Test One','test900@example.invalid',900,DATE '2030-12-31','ACTIVE');
 INSERT INTO LIB_MEMBER VALUES(901,'TEST901','Test Two','test901@example.invalid',900,DATE '2030-12-31','ACTIVE');
 INSERT INTO LIB_MEMBER VALUES(902,'TEST902','Test Suspended','test902@example.invalid',900,DATE '2030-12-31','SUSPENDED');
 INSERT INTO BOOK_TITLE VALUES(900,NULL,'Test title A',NULL,NULL);
 INSERT INTO BOOK_TITLE VALUES(901,NULL,'Test title B',NULL,NULL);
 INSERT INTO BOOK_COPY VALUES(900,'TEST-C900',900,'TEST','AVAILABLE');
 INSERT INTO BOOK_COPY VALUES(901,'TEST-C901',901,'TEST','AVAILABLE');
 INSERT INTO BOOK_COPY VALUES(902,'TEST-C902',901,'TEST','REPAIR');
 rejects(q'[INSERT INTO LIB_MEMBER VALUES(903,'TEST900','Test Duplicate','test903@example.invalid',900,DATE '2030-12-31','ACTIVE')]',-1,'Duplicate matric rejected');
 rejects(q'[INSERT INTO BOOK_COPY VALUES(903,'TEST-C900',900,'TEST','AVAILABLE')]',-1,'Unique barcode');
 rejects(q'[INSERT INTO BOOK_COPY VALUES(903,'TEST-C903',99999,'TEST','AVAILABLE')]',-2291,'Foreign key rejects unknown title');
 rejects(q'[INSERT INTO LOAN VALUES(900,900,900,1,DATE '2026-10-29',DATE '2026-10-28',NULL)]',-2290,'Due date follows borrowing');
 rejects(q'[INSERT INTO RESERVATION VALUES(900,900,900,DATE '2026-10-29','ACTIVE',DATE '2026-10-30')]',-2290,'Active reservation has no closure');
 rejects(q'[INSERT INTO RESERVATION VALUES(900,900,900,DATE '2026-10-29','FULFILLED',NULL)]',-2290,'Closed reservation requires closure date');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.reserve_title(900,901,DATE '2026-10-29',x); END;]',-20014,'Available title cannot be reserved');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.checkout(900,902,1,DATE '2026-10-29',x); END;]',-20002,'Suspended membership');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.checkout(900,7,1,DATE '2026-10-29',x); END;]',-20002,'Expired membership');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.checkout(902,900,1,DATE '2026-10-29',x); END;]',-20003,'Repair copy cannot be lent');
 circulation_api.checkout(900,900,1,DATE '2026-10-29',v_loan);
 SELECT due_on INTO v_due FROM LOAN WHERE loan_id=v_loan;
 ok(v_due=DATE '2026-11-05','Checkout derives seven-day policy due date');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.checkout(900,901,1,DATE '2026-10-29',x); END;]',-20004,'Active copy cannot be lent twice');
 rejects(q'[INSERT INTO LOAN VALUES(901,900,901,1,DATE '2026-10-29',DATE '2026-11-05',NULL)]',-1,'Conditional unique index protects open loan');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.checkout(901,900,1,DATE '2026-10-29',x); END;]',-20005,'Member quota is enforced');
 circulation_api.reserve_title(900,901,DATE '2026-10-29',v_hold);
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.reserve_title(900,901,DATE '2026-10-29',x); END;]',-20011,'Duplicate active hold rejected');
 rejects('DECLARE x NUMBER; BEGIN circulation_api.renew_loan('||v_loan||q'[,1,DATE '2026-10-30',x); END;]',-20010,'Other holder blocks renewal');
 rejects('BEGIN circulation_api.return_loan('||v_loan||q'[,DATE '2026-10-28'); END;]',-20013,'Return chronology');
 circulation_api.return_loan(v_loan,DATE '2026-10-30');
 rejects('BEGIN circulation_api.return_loan('||v_loan||q'[,DATE '2026-10-30'); END;]',-20007,'Repeated return rejected');
 SELECT COUNT(*) INTO v_count FROM LOAN WHERE loan_id=v_loan AND returned_on IS NOT NULL;
 ok(v_count=1,'Return records history');
 rejects(q'[DECLARE x NUMBER; BEGIN circulation_api.checkout(900,900,1,DATE '2026-10-30',x); END;]',-20006,'FIFO gives waiting member priority');
 circulation_api.checkout(900,901,1,DATE '2026-10-30',v_loan);
 SELECT COUNT(*) INTO v_count FROM RESERVATION WHERE reservation_id=v_hold
  AND reservation_status='FULFILLED' AND closed_on=DATE '2026-10-30';
 ok(v_count=1,'Checkout fulfills earliest hold');
 FOR i IN 1..3 LOOP circulation_api.renew_loan(v_loan,1,DATE '2026-10-31',v_id); END LOOP;
 SELECT COUNT(*) INTO v_count FROM RENEWAL WHERE loan_id=v_loan;
 ok(v_count=3,'Three renewal events retained');
 SELECT due_on INTO v_due FROM LOAN WHERE loan_id=v_loan;
 ok(v_due=DATE '2026-11-27','Three renewals extend current due date by three policy periods');
 rejects('BEGIN circulation_api.return_loan('||v_loan||q'[,DATE '2026-10-30'); END;]',-20013,'Return before last renewal rejected');
 rejects('DECLARE x NUMBER; BEGIN circulation_api.renew_loan('||v_loan||q'[,1,DATE '2026-10-31',x); END;]',-20009,'Fourth renewal rejected');
 rejects('DECLARE x NUMBER; BEGIN circulation_api.renew_loan('||v_loan||q'[,1,DATE '2026-12-01',x); END;]',-20008,'Overdue renewal rejected');
 rejects(q'[DELETE FROM BOOK_TITLE WHERE title_id=900]',-2292,'Referenced title deletion restricted');
 -- A cancellable hold while title remains unavailable.
 circulation_api.reserve_title(900,900,DATE '2026-10-31',v_hold);
 circulation_api.cancel_reservation(v_hold,900,DATE '2026-11-01');
 SELECT COUNT(*) INTO v_count FROM RESERVATION WHERE reservation_id=v_hold AND reservation_status='CANCELLED';
 ok(v_count=1,'Cancellation records closed state');
 rejects('BEGIN circulation_api.cancel_reservation('||v_hold||q'[,900,DATE '2026-11-01'); END;]',-20012,'Repeated cancellation rejected');
 DBMS_OUTPUT.PUT_LINE('ORACLE TESTS PASSED: '||v_tests);
END;
/
ROLLBACK TO project_test;
PROMPT Test data rolled back.
