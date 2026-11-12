#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
launcher="$project/scripts/oracle.sh"
image='container-registry.oracle.com/database/free@sha256:cf540c3fa190d7cffad08c491652ac07fc70314e510f6b87890449517d565e94'
container=${OPEN_SHELF_CONTAINER:-open-shelf-books-oracle}
schema=${OPEN_SHELF_SCHEMA:-OPEN_SHELF_BOOKS}
engine_command=${OPEN_SHELF_ENGINE:-}
workdir=/tmp/open-shelf-books
label_key=org.open-shelf-books.service
password=''

usage() {
    cat <<'TEXT'
Usage: ./scripts/oracle.sh <command>
  start                Start the pinned Oracle Free Lite container and wait for FREEPDB1
  status               Show container state and PDB readiness
  setup                Create the dedicated account if absent and build an empty schema
  verify               Run assertions, DML, atomicity, and runtime checks
  demo                 Show four operations and verify rollback
  concurrency          Verify two independent Oracle sessions
  sql                  Read SQL from standard input as the dedicated account
  stop                 Stop the managed container and keep its volume
  reset --confirm      Drop this application's objects in the dedicated schema

Docker and Podman are supported. OPEN_SHELF_ENGINE selects the engine executable.
OPEN_SHELF_CONTAINER selects an existing container or the name to create.
OPEN_SHELF_SCHEMA defaults to OPEN_SHELF_BOOKS. OPEN_SHELF_DB_PASSWORD is optional
when a terminal is available. The launcher asks once per command and stores no password.
TEXT
}

die() { printf '%s\n' "$*" >&2; exit 1; }

choose_engine() {
    if [[ -z $engine_command ]]; then
        if command -v docker >/dev/null 2>&1; then
            engine_command=docker
        elif command -v podman >/dev/null 2>&1; then
            engine_command=podman
        else
            die 'Install and start Docker or Podman, or set OPEN_SHELF_ENGINE.'
        fi
    fi
    command -v "$engine_command" >/dev/null 2>&1 || die 'The selected container engine executable is unavailable.'
}

engine() (
    unset OPEN_SHELF_DB_PASSWORD
    "$engine_command" "$@"
)

ask_password() {
    password=${OPEN_SHELF_DB_PASSWORD:-}
    if [[ -z $password ]]; then
        [[ -t 0 || -t 1 || -t 2 ]] || die 'Set OPEN_SHELF_DB_PASSWORD when running without a terminal.'
        printf 'Password for %s: ' "$schema" >/dev/tty
        IFS= read -rs password </dev/tty || die 'Could not read the schema password.'
        printf '\n' >/dev/tty
    fi
    [[ $password =~ ^[A-Za-z0-9_]{12,64}$ ]] || die 'Use 12–64 ASCII letters, digits or underscores for the schema password.'
}

admin() {
    engine exec -i --env NLS_LANG=AMERICAN_AMERICA.AL32UTF8 "$container" sqlplus -s -L '/ as sysdba'
}

ready() {
    admin <<'SQL'
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'PDB_READY=FREEPDB1:READ WRITE' FROM v$pdbs WHERE name='FREEPDB1' AND open_mode='READ WRITE';
EXIT SUCCESS ROLLBACK
SQL
}

exists() { engine container inspect "$container" >/dev/null 2>&1; }

require_managed_container() {
    local label
    label=$(engine container inspect --format "{{ index .Config.Labels \"$label_key\" }}" "$container")
    [[ $label == oracle ]] || die 'A container with that name belongs to another service. Choose a different OPEN_SHELF_CONTAINER.'
}

start() {
    if exists; then
        require_managed_container
        engine start "$container" >/dev/null
    else
        engine run -d --name "$container" --label "$label_key=oracle" --shm-size=1g \
            --volume "$container-data:/opt/oracle/oradata" "$image" >/dev/null
    fi
    local attempt output
    for ((attempt=0; attempt<90; attempt++)); do
        if output=$(ready 2>/dev/null) && [[ $output == *'PDB_READY=FREEPDB1:READ WRITE'* ]]; then
            printf '%s\n' 'PDB_READY=FREEPDB1:READ WRITE'
            return
        fi
        sleep 2
    done
    die 'FREEPDB1 did not open within three minutes. Check the container status, then retry.'
}

require_ready() {
    local output
    if ! output=$(ready 2>/dev/null) || [[ $output != *'PDB_READY=FREEPDB1:READ WRITE'* ]]; then
        die 'FREEPDB1 is unavailable. Start the Oracle container first.'
    fi
}

sync_sql() {
    (cd "$project" && COPYFILE_DISABLE=1 tar --format ustar -cf - db/*.sql tests/*.sql) |
        engine exec -i "$container" sh -ec 'mkdir -p "$1" && tar -xf - -C "$1"' sh "$workdir"
}

# SQL*Plus can report client-side SP2 errors without a failing exit code.
# SQL*Plus 客户端的 SP2 错误可能未反映在退出状态中。
checked() {
    local output result=0
    output=$("$@" 2>&1) || result=$?
    if [[ -n $password ]]; then
        output=${output//"$password"/[REDACTED]}
    fi
    printf '%s\n' "$output"
    [[ $result == 0 ]] || return "$result"
    if LC_ALL=C grep -Eq '^[[:space:]]*(ORA|SP2|PLS)-[0-9]+:' <<<"$output"; then
        return 1
    fi
}

bootstrap() {
    local tablespace="${schema}_DATA" datafile
    datafile=$(printf '%s' "$tablespace" | LC_ALL=C tr 'A-Z' 'a-z')
    checked admin <<SQL
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF DEFINE OFF
ALTER SESSION SET CONTAINER=FREEPDB1;
DECLARE
    present NUMBER;
BEGIN
    SELECT COUNT(*) INTO present FROM dba_users WHERE username='$schema';
    IF present=0 THEN
        SELECT COUNT(*) INTO present FROM dba_tablespaces WHERE tablespace_name='$tablespace';
        IF present=0 THEN
            EXECUTE IMMEDIATE 'CREATE TABLESPACE $tablespace DATAFILE ''/opt/oracle/oradata/FREE/FREEPDB1/$datafile.dbf'' SIZE 20M AUTOEXTEND ON NEXT 10M MAXSIZE 120M';
        END IF;
        EXECUTE IMMEDIATE 'CREATE USER $schema IDENTIFIED BY "$password" DEFAULT TABLESPACE $tablespace QUOTA 100M ON $tablespace';
        EXECUTE IMMEDIATE 'GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE SEQUENCE, CREATE TRIGGER TO $schema';
    END IF;
END;
/
EXIT SUCCESS ROLLBACK
SQL
}

app_session() {
    {
        printf '%s\n' 'SET ECHO OFF DEFINE OFF' 'WHENEVER OSERROR EXIT FAILURE ROLLBACK' 'WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK'
        printf 'CONNECT %s/"%s"@//localhost:1521/FREEPDB1\n' "$schema" "$password"
        cat
        printf '\nEXIT SUCCESS ROLLBACK\n'
    } | engine exec -i --workdir "$workdir" --env NLS_LANG=AMERICAN_AMERICA.AL32UTF8 "$container" sqlplus -s -L /nolog
}

sql_script() { printf '%s\n' "$@" | checked app_session; }

case "${1:-help}" in
    help|-h|--help) usage; exit 0 ;;
    start|status|setup|verify|demo|concurrency|sql|stop|reset) ;;
    *) usage >&2; exit 2 ;;
esac

[[ $container =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'Invalid Oracle container name.'
[[ $schema =~ ^OPEN_SHELF_BOOKS(_[A-Z][A-Z0-9_]{0,10})?$ ]] || die 'Use OPEN_SHELF_BOOKS or an uppercase OPEN_SHELF_BOOKS_* schema.'
choose_engine

case "$1" in
    start) start ;;
    status)
        engine container inspect --format 'Container {{.Name}}: {{.State.Status}}' "$container"
        require_ready
        printf '%s\n' 'PDB_READY=FREEPDB1:READ WRITE'
        ;;
    stop)
        require_managed_container
        engine stop "$container"
        ;;
    setup)
        require_ready
        ask_password
        sync_sql
        bootstrap
        sql_script '@db/00_build.sql'
        ;;
    verify)
        require_ready
        ask_password
        sync_sql
        sql_script '@tests/01_assertions.sql' '@tests/02_admin_and_dml.sql' '@tests/03_atomicity.sql' '@tests/04_runtime.sql'
        ;;
    demo)
        require_ready
        ask_password
        sync_sql
        sql_script '@db/05_demo.sql'
        ;;
    concurrency)
        require_ready
        ask_password
        OPEN_SHELF_DB_PASSWORD="$password" python3 "$project/tests/live_concurrency.py" "$launcher" sql
        ;;
    sql)
        ask_password
        checked app_session
        ;;
    reset)
        [[ ${2:-} == --confirm && $# == 2 ]] || die 'Reset drops the application objects and data. Run reset --confirm to proceed.'
        require_ready
        ask_password
        sync_sql
        sql_script '@db/99_drop_project_objects.sql'
        ;;
esac
