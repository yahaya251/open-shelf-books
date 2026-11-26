-- Synthetic same-session circulation scenario
-- Run against this project's untouched synthetic fixture. No COMMIT or DDL is used.
-- Rollback restores table data. Oracle identity values can have gaps.
SET ECHO OFF
SET DEFINE OFF
SET VERIFY OFF
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED
SET AUTOCOMMIT OFF
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  TYPE counts_by_table IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
  before_counts counts_by_table;
  table_name VARCHAR2(30);
  actual_count NUMBER;
  initial_open NUMBER;
  initial_due DATE;
  current_due DATE;
  previous_due DATE;
  next_due DATE;
  event_on CONSTANT DATE := DATE '2026-11-20';
  loan_a NUMBER;
  loan_b NUMBER;
  renewal_a NUMBER;
  hold_b NUMBER;
  hold_c NUMBER;
  ignored_id NUMBER;
  actual_error NUMBER;

  PROCEDURE require_true(p_condition BOOLEAN, message_text VARCHAR2) IS
  BEGIN
    IF p_condition IS NULL OR NOT p_condition THEN
      RAISE_APPLICATION_ERROR(-20981, message_text);
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: ' || message_text);
  END;

  FUNCTION stamp(p_value DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_value, 'YYYY-MM-DD HH24:MI:SS');
  END;
BEGIN
  SAVEPOINT synthetic_circ_scenario;
  DBMS_OUTPUT.PUT_LINE('SIM_SCENARIO=BEGIN');
  DBMS_OUTPUT.PUT_LINE('All people and records are synthetic');
  DBMS_OUTPUT.PUT_LINE('Scenario date: ' || stamp(event_on));
  DBMS_OUTPUT.PUT_LINE('Schema: ' || SYS_CONTEXT('USERENV','SESSION_USER'));

  FOR item IN (
    SELECT table_name FROM user_tables
    WHERE table_name IN ('MEMBER_TYPE','LIB_MEMBER','STAFF','PUBLISHER',
      'BOOK_TITLE','AUTHOR','TITLE_AUTHOR','BOOK_COPY','LOAN','RENEWAL','RESERVATION')
    ORDER BY table_name
  ) LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || item.table_name INTO actual_count;
    before_counts(item.table_name) := actual_count;
  END LOOP;
  require_true(before_counts.COUNT = 11, 'All 11 project tables exist');
  SELECT COUNT(*) INTO initial_open FROM loan WHERE returned_on IS NULL;
  require_true(before_counts('LOAN') = 8 AND initial_open = 5,
    'Seed baseline: 8 loans, 5 open');

  INSERT INTO MEMBER_TYPE VALUES (2100, 'Synthetic scenario policy', 2, 7, 3);
  INSERT INTO LIB_MEMBER VALUES (2100, 'SIM2100A', 'Synthetic Member A',
    'sim2100a@example.invalid', 2100, DATE '2030-12-31', 'ACTIVE');
  INSERT INTO LIB_MEMBER VALUES (2101, 'SIM2101B', 'Synthetic Member B',
    'sim2101b@example.invalid', 2100, DATE '2030-12-31', 'ACTIVE');
  INSERT INTO LIB_MEMBER VALUES (2102, 'SIM2102C', 'Synthetic Member C',
    'sim2102c@example.invalid', 2100, DATE '2030-12-31', 'ACTIVE');
  INSERT INTO STAFF VALUES (2100, 'Synthetic circulation officer',
    'simstaff2100@example.invalid');
  INSERT INTO BOOK_TITLE VALUES (2100, NULL, 'Synthetic circulation handbook', NULL, 2026);
  INSERT INTO BOOK_COPY VALUES (2100, 'SIM-C2100', 2100, 'SIM-SHELF', 'AVAILABLE');
  DBMS_OUTPUT.PUT_LINE('Created: A, B, C; one title and copy; one staff member; seven-day loan policy');

  circulation_api.checkout(2100, 2100, 2100, event_on, loan_a);
  SELECT due_on INTO initial_due FROM loan WHERE loan_id = loan_a;
  require_true(initial_due = event_on + 7,
    'A checkout uses seven-day policy');
  DBMS_OUTPUT.PUT_LINE('A checkout: loan_id=' || loan_a || ' due_on=' || stamp(initial_due));

  circulation_api.renew_loan(loan_a, 2100, event_on + 1, renewal_a);
  SELECT due_on INTO current_due FROM loan WHERE loan_id = loan_a;
  SELECT previous_due_on, new_due_on INTO previous_due, next_due
    FROM renewal WHERE renewal_id = renewal_a;
  require_true(current_due = event_on + 14 AND previous_due = initial_due
    AND next_due = current_due,
    'A renewal preserves old/new dates and extends by seven days');
  DBMS_OUTPUT.PUT_LINE('A renewal: previous=' || stamp(previous_due) || ' new=' || stamp(next_due));

  circulation_api.reserve_title(2100, 2101, event_on + 2, hold_b);
  circulation_api.reserve_title(2100, 2102, event_on + 2 + 1/24, hold_c);
  DBMS_OUTPUT.PUT_LINE('Queue: B at ' || stamp(event_on + 2)
    || ', then C at ' || stamp(event_on + 2 + 1/24));

  actual_error := 0;
  BEGIN
    circulation_api.renew_loan(loan_a, 2100, event_on + 3, ignored_id);
  EXCEPTION WHEN OTHERS THEN actual_error := SQLCODE;
  END;
  require_true(actual_error = -20010,
    'Renewal blocked by another member hold, code -20010');
  SELECT due_on INTO current_due FROM loan WHERE loan_id = loan_a;
  SELECT COUNT(*) INTO actual_count FROM renewal WHERE loan_id = loan_a;
  require_true(current_due = event_on + 14 AND actual_count = 1,
    'Rejected renewal leaves due date/history unchanged');

  circulation_api.return_loan(loan_a, event_on + 4);
  DBMS_OUTPUT.PUT_LINE('A return: ' || stamp(event_on + 4));
  actual_error := 0;
  BEGIN
    circulation_api.checkout(2100, 2102, 2100, event_on + 4 + 1/24, ignored_id);
  EXCEPTION WHEN OTHERS THEN actual_error := SQLCODE;
  END;
  require_true(actual_error = -20006,
    'C cannot bypass earlier holder B, code -20006');

  circulation_api.checkout(2100, 2101, 2100, event_on + 4 + 2/24, loan_b);
  SELECT COUNT(*) INTO actual_count FROM reservation
    WHERE reservation_id = hold_b AND member_id = 2101
      AND reservation_status = 'FULFILLED' AND closed_on = event_on + 4 + 2/24;
  require_true(actual_count = 1,
    'B checkout atomically fulfills first hold');
  SELECT due_on INTO current_due FROM loan WHERE loan_id = loan_b;
  require_true(current_due = event_on + 11 + 2/24,
    'B due date equals checkout plus seven days');
  DBMS_OUTPUT.PUT_LINE('B checkout: loan_id=' || loan_b || ' due_on=' || stamp(current_due));

  circulation_api.cancel_reservation(hold_c, 2102, event_on + 4 + 3/24);
  circulation_api.return_loan(loan_b, event_on + 5);
  SELECT COUNT(*) INTO actual_count FROM reservation
    WHERE reservation_id = hold_c AND reservation_status = 'CANCELLED'
      AND closed_on = event_on + 4 + 3/24;
  require_true(actual_count = 1, 'C hold cancelled');
  SELECT COUNT(*) INTO actual_count FROM loan WHERE copy_id = 2100 AND returned_on IS NULL;
  require_true(actual_count = 0, 'Both scenario loans returned');
  SELECT COUNT(*) INTO actual_count FROM v_copy_availability
    WHERE copy_id = 2100 AND can_lend = 'YES';
  require_true(actual_count = 1, 'Scenario copy is lendable again');

  DBMS_OUTPUT.PUT_LINE('REPORT: loan history');
  FOR item IN (
    SELECT l.loan_id, m.full_name, l.borrowed_on, l.due_on, l.returned_on
    FROM loan l JOIN lib_member m ON m.member_id = l.member_id
    WHERE l.copy_id = 2100 ORDER BY l.borrowed_on, l.loan_id
  ) LOOP
    DBMS_OUTPUT.PUT_LINE(item.full_name || ' loan_id=' || item.loan_id
      || ' borrowed=' || stamp(item.borrowed_on) || ' due=' || stamp(item.due_on)
      || ' returned=' || stamp(item.returned_on));
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('REPORT: reservation queue');
  FOR item IN (
    SELECT r.reservation_id, m.full_name, r.reserved_on, r.reservation_status, r.closed_on
    FROM reservation r JOIN lib_member m ON m.member_id = r.member_id
    WHERE r.title_id = 2100 ORDER BY r.reserved_on, r.reservation_id
  ) LOOP
    DBMS_OUTPUT.PUT_LINE(item.full_name || ' reservation_id=' || item.reservation_id
      || ' queued=' || stamp(item.reserved_on) || ' status=' || item.reservation_status
      || ' closed=' || stamp(item.closed_on));
  END LOOP;
  SELECT COUNT(*) INTO actual_count FROM loan;
  require_true(actual_count = before_counts('LOAN') + 2,
    'Exactly two scenario loans recorded');
  DBMS_OUTPUT.PUT_LINE('Before rollback: total_loans=' || actual_count
    || '; scenario_loans=2; scenario_active_loans=0; B=FULFILLED; C=CANCELLED');

  ROLLBACK TO synthetic_circ_scenario;
  table_name := before_counts.FIRST;
  WHILE table_name IS NOT NULL LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || table_name INTO actual_count;
    require_true(actual_count = before_counts(table_name),
      'Restored row count: ' || table_name || '=' || actual_count);
    table_name := before_counts.NEXT(table_name);
  END LOOP;
  SELECT COUNT(*) INTO actual_count FROM loan WHERE returned_on IS NULL;
  require_true(actual_count = initial_open, 'Five original open loans preserved');
  SELECT COUNT(*) INTO actual_count FROM lib_member WHERE member_id IN (2100,2101,2102);
  require_true(actual_count = 0, 'Synthetic members removed by rollback');
  SELECT COUNT(*) INTO actual_count FROM book_copy WHERE copy_id = 2100;
  require_true(actual_count = 0, 'Synthetic copy removed by rollback');
  DBMS_OUTPUT.PUT_LINE('All table changes rolled back; identity gaps are expected');
  DBMS_OUTPUT.PUT_LINE('SIM_SCENARIO=PASS');
EXCEPTION WHEN OTHERS THEN
  ROLLBACK TO synthetic_circ_scenario;
  DBMS_OUTPUT.PUT_LINE('SIM_SCENARIO=FAIL: ' || SQLERRM);
  RAISE;
END;
/
