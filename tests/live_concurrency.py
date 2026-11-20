#!/usr/bin/env python3
"""Exercise two real Oracle sessions using a supplied SQL*Plus launcher.

Usage: python3 live_concurrency.py python3 scripts/oracle.py sql
The launcher must connect to the dedicated dedicated demo schema, accept SQL on
stdin, and return SQL*Plus output on stdout. Do not pass credentials as args.
"""
from concurrent.futures import ThreadPoolExecutor
import re
import secrets
import subprocess
import sys


TYPE_ID = 970
MEMBER_A = 970
MEMBER_B = 971
COPY_A = 970
COPY_B = 971
BASELINE_LOANS = 8
SCRIPT_TIMEOUT = 50
DEMO_DATE = "DATE '2026-10-29'"
PREAMBLE = """SET ECHO OFF
SET VERIFY OFF
SET FEEDBACK OFF
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
"""
ERROR_LINE = re.compile(r"^\s*(?:SP2|ORA|PLS)-\d+:", re.MULTILINE)


class VerificationError(Exception):
    """A runtime check failed"""


def run_sql(launcher, body, label, marker):
    """Collect actual SQL*Plus output and require its success marker.
    """
    try:
        completed = subprocess.run(
            launcher,
            input=PREAMBLE + body + "\nEXIT SUCCESS ROLLBACK\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            timeout=SCRIPT_TIMEOUT,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        if output.strip():
            print(output.rstrip(), flush=True)
        raise VerificationError(f"{label}: SQL*Plus timed out") from None
    except OSError:
        raise VerificationError(f"{label}: SQL*Plus launcher failed") from None
    output = completed.stdout
    print(f"[{label}]\n{output.rstrip()}", flush=True)
    if completed.returncode != 0 or ERROR_LINE.search(output) or marker not in output:
        raise VerificationError(f"{label}: expected Oracle result missing")
    return output


def setup_sql(prefix):
    return f"""
DECLARE
    loan_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO loan_count FROM LOAN;
    IF loan_count <> {BASELINE_LOANS} THEN
        RAISE_APPLICATION_ERROR(-20870, 'Expected 8 seed loans');
    END IF;
    INSERT INTO MEMBER_TYPE VALUES ({TYPE_ID}, '{prefix}_INIT', 1, 7, 3);
    INSERT INTO LIB_MEMBER VALUES ({MEMBER_A}, '{prefix}A', 'Concurrency A',
        '{prefix}A@example.invalid', {TYPE_ID}, DATE '2030-12-31', 'ACTIVE');
    INSERT INTO LIB_MEMBER VALUES ({MEMBER_B}, '{prefix}B', 'Concurrency B',
        '{prefix}B@example.invalid', {TYPE_ID}, DATE '2030-12-31', 'ACTIVE');
    INSERT INTO BOOK_TITLE VALUES ({COPY_A}, NULL, '{prefix} Title A', NULL, NULL);
    INSERT INTO BOOK_TITLE VALUES ({COPY_B}, NULL, '{prefix} Title B', NULL, NULL);
    INSERT INTO BOOK_COPY VALUES ({COPY_A}, '{prefix}A', {COPY_A}, 'TEST', 'AVAILABLE');
    INSERT INTO BOOK_COPY VALUES ({COPY_B}, '{prefix}B', {COPY_B}, 'TEST', 'AVAILABLE');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('OSB_CONC_SETUP_OK: 8 seed loans; temporary fixtures ready');
END;
/
"""


def session_a_sql(prefix, race):
    locked = f"{prefix}_{race}_A"
    trying = f"{prefix}_{race}_B"
    return f"""
DECLARE
    new_loan_id NUMBER;
    phase MEMBER_TYPE.type_name%TYPE;
    PROCEDURE publish_lock IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE MEMBER_TYPE SET type_name = '{locked}' WHERE member_type_id = {TYPE_ID};
        COMMIT;
    END;
BEGIN
    DBMS_SESSION.SET_IDENTIFIER('OSB_CONC_{race}_A');
    circulation_api.checkout({COPY_A}, {MEMBER_A}, 1, {DEMO_DATE}, new_loan_id);
    -- Independent marker transaction signals that A holds circulation locks.
    publish_lock;
    FOR attempt IN 1..150 LOOP
        SELECT type_name INTO phase FROM MEMBER_TYPE WHERE member_type_id = {TYPE_ID};
        EXIT WHEN phase = '{trying}';
        DBMS_SESSION.SLEEP(0.10);
    END LOOP;
    IF phase <> '{trying}' THEN
        RAISE_APPLICATION_ERROR(-20871, 'Session B did not start');
    END IF;
    DBMS_SESSION.SLEEP(2.5);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('OSB_CONC_A_COMMITTED loan_id=' || new_loan_id || '');
END;
/
"""


def session_b_sql(prefix, race, copy_id, member_id, expected_code):
    locked = f"{prefix}_{race}_A"
    trying = f"{prefix}_{race}_B"
    return f"""
DECLARE
    phase MEMBER_TYPE.type_name%TYPE;
    started NUMBER;
    elapsed_centiseconds NUMBER;
    error_code NUMBER := 0;
    rejected_id NUMBER;
    active_count NUMBER;
    PROCEDURE publish_attempt IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE MEMBER_TYPE SET type_name = '{trying}' WHERE member_type_id = {TYPE_ID};
        COMMIT;
    END;
BEGIN
    DBMS_SESSION.SET_IDENTIFIER('OSB_CONC_{race}_B');
    FOR attempt IN 1..150 LOOP
        SELECT type_name INTO phase FROM MEMBER_TYPE WHERE member_type_id = {TYPE_ID};
        EXIT WHEN phase = '{locked}';
        DBMS_SESSION.SLEEP(0.10);
    END LOOP;
    IF phase <> '{locked}' THEN
        RAISE_APPLICATION_ERROR(-20872, 'Session A did not lock the fixture');
    END IF;
    publish_attempt;
    started := DBMS_UTILITY.GET_TIME;
    BEGIN
        circulation_api.checkout({copy_id}, {member_id}, 1, {DEMO_DATE}, rejected_id);
    EXCEPTION WHEN OTHERS THEN
        error_code := SQLCODE;
    END;
    elapsed_centiseconds := DBMS_UTILITY.GET_TIME - started;
    ROLLBACK;
    IF error_code <> {expected_code} THEN
        RAISE_APPLICATION_ERROR(-20873, 'Unexpected checkout result: ' || error_code);
    END IF;
    IF elapsed_centiseconds < 100 THEN
        RAISE_APPLICATION_ERROR(-20874, 'Observed wait was under 1 second');
    END IF;
    SELECT COUNT(*) INTO active_count FROM LOAN
    WHERE copy_id IN ({COPY_A}, {COPY_B}) AND returned_on IS NULL;
    IF active_count <> 1 THEN
        RAISE_APPLICATION_ERROR(-20875, 'Expected exactly one committed loan');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OSB_CONC_B_PASS code=' || error_code || ' wait_centiseconds=' || elapsed_centiseconds ||
        ' active_fixture_loans=' || active_count || '');
END;
/
"""


def clear_race_sql(prefix, loan_id):
    return f"""
BEGIN
    DELETE FROM LOAN WHERE loan_id = {loan_id}
    AND copy_id = {COPY_A} AND member_id = {MEMBER_A} AND borrowed_on = {DEMO_DATE};
    IF SQL%ROWCOUNT <> 1 THEN
        RAISE_APPLICATION_ERROR(-20876, 'Exact test loan could not be cleared');
    END IF;
    UPDATE MEMBER_TYPE SET type_name = '{prefix}_INIT' WHERE member_type_id = {TYPE_ID};
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('OSB_CONC_RACE_CLEARED');
END;
/
"""


def cleanup_sql(prefix):
    exact_markers = ", ".join(f"'{prefix}_{name}'" for name in ("INIT", "COPY_A", "COPY_B", "QUOTA_A", "QUOTA_B"))
    return f"""
DECLARE
    owned_fixture NUMBER;
    loan_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO owned_fixture FROM MEMBER_TYPE
    WHERE member_type_id = {TYPE_ID} AND type_name IN ({exact_markers});
    IF owned_fixture = 1 THEN
        -- Exact synthetic keys, with a run-specific ownership guard.
        DELETE FROM LOAN WHERE copy_id IN ({COPY_A}, {COPY_B})
        AND member_id IN ({MEMBER_A}, {MEMBER_B}) AND borrowed_on = {DEMO_DATE};
        DELETE FROM BOOK_COPY WHERE (copy_id = {COPY_A} AND barcode = '{prefix}A')
                                OR (copy_id = {COPY_B} AND barcode = '{prefix}B');
        DELETE FROM BOOK_TITLE WHERE (title_id = {COPY_A} AND title_name = '{prefix} Title A')
                                 OR (title_id = {COPY_B} AND title_name = '{prefix} Title B');
        DELETE FROM LIB_MEMBER WHERE (member_id = {MEMBER_A} AND matric_no = '{prefix}A')
                                 OR (member_id = {MEMBER_B} AND matric_no = '{prefix}B');
        DELETE FROM MEMBER_TYPE WHERE member_type_id = {TYPE_ID} AND type_name IN ({exact_markers});
        COMMIT;
    END IF;
    SELECT COUNT(*) INTO loan_count FROM LOAN;
    IF loan_count <> {BASELINE_LOANS} THEN
        RAISE_APPLICATION_ERROR(-20877, 'Seed baseline not restored');
    END IF;
    DBMS_OUTPUT.PUT_LINE('OSB_CONC_CLEANUP_OK baseline_loans=' || loan_count || '');
END;
/
"""


def verify(launcher):
    # A and B coordinate inside Oracle through autonomous marker transactions.
    prefix = "WC" + secrets.token_hex(5).upper()
    try:
        run_sql(launcher, setup_sql(prefix), "Setup", "OSB_CONC_SETUP_OK")
        races = (
            ("COPY", COPY_A, MEMBER_B, -20004, "Same copy"),
            ("QUOTA", COPY_B, MEMBER_A, -20005, "Member quota"),
        )
        for race, copy_id, member_id, expected_code, label in races:
            with ThreadPoolExecutor(max_workers=2) as pool:
                a = pool.submit(run_sql, launcher, session_a_sql(prefix, race), f"{label}, A", "OSB_CONC_A_COMMITTED")
                b = pool.submit(run_sql, launcher, session_b_sql(prefix, race, copy_id, member_id, expected_code),
                                f"{label}, B", "OSB_CONC_B_PASS")
                a_output = a.result()
                b.result()
            match = re.search(r"OSB_CONC_A_COMMITTED loan_id=(\d+)", a_output)
            if match is None:
                raise VerificationError("Missing exact committed loan ID")
            run_sql(launcher, clear_race_sql(prefix, int(match.group(1))), "Reset", "OSB_CONC_RACE_CLEARED")
    finally:
        run_sql(launcher, cleanup_sql(prefix), "Cleanup", "OSB_CONC_CLEANUP_OK")
    print("OSB_CONC_ALL_PASS: two real Oracle races verified")


def main():
    if len(sys.argv) < 2:
        print("Usage", file=sys.stderr)
        return 2
    try:
        verify(sys.argv[1:])
    except VerificationError as error:
        print(f"FAIL", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
