# Oracle operating guide

[Project overview](../README.md) · [One-click setup](setup.md) · [Optional local Mac runtime](local-macos.md)

The manual container commands below use managed Docker/Podman defaults. If you selected an existing local backend in `.local/runtime.json`, use `scripts/start_project.py --verify`, `--demo`, `--concurrency` or `--sql-file` so the same backend is selected again.

## Prerequisites

Use Python 3.10+ and an available Docker Linux container engine. Docker Desktop runs the Linux image on both macOS and Windows. On Windows, start Docker Desktop using its Linux container mode and WSL 2. Podman is an alternative when its machine is already running. Commands below assume the repository root. [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/) · [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/) · [Oracle Free Lite container guide](https://docs.oracle.com/en/database/oracle/agent-memory/26.6/guide/run-locally.html)

## Start and build

Run `py -3` in place of `python3` on Windows.

```sh
python3 scripts/oracle.py start
python3 scripts/oracle.py status
python3 scripts/oracle.py setup
```

Wait for `PDB_READY=FREEPDB1:READ WRITE`. Build a new `OPEN_SHELF_BOOKS` schema once and reuse the same schema password when prompted. The launcher uses a named Oracle data volume and communicates through SQL*Plus inside the container. It does not require exposing port 1521 on the host.

Running setup again in a populated schema returns `ORA-20860`. Use `start` and `status` after a shutdown, then continue with verification.

## Test and demonstrate

```sh
python3 scripts/oracle.py verify
python3 scripts/oracle.py demo
python3 scripts/oracle.py concurrency
```

Verification exercises 30 assertions, DML, failure rollback and runtime checks. The demo lists open loans, title totals and unmet reservations, then returns loan 1 and rolls back the return. The concurrency test opens two sessions to verify contention for the same copy and for a member's last loan slot. The fixture has 8 loans and 5 open at the end.

Run `python3 tests/validate_offline.py` for 44 fixture and static checks without an Oracle engine. [Recorded results](../tests/VERIFIED.md) · [Demo details](../demo/README.md)

## Run a SQL file

Save SQL as UTF-8. For example, save `SELECT COUNT(*) FROM loan WHERE returned_on IS NULL;` in `query.sql` and run:

```sh
python3 scripts/oracle.py sql --file query.sql
```

In PowerShell:

```powershell
py -3 scripts/oracle.py sql --file query.sql
```

The launcher rolls back uncommitted changes when SQL*Plus exits. Write `COMMIT;` explicitly in the file only when you intend to retain the change.

## Stop or restore sample data

`python3 scripts/oracle.py stop` stops the managed container and retains its volume.

To erase and rebuild the objects in a **disposable** project schema, use `reset --confirm`, then `setup` and `verify`. Reset deletes the application data. It is unnecessary for everyday use.

## Use an existing Oracle server

Connect through SQL*Plus or SQLcl to a dedicated, empty Oracle 19c+ schema with CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE SEQUENCE, CREATE TRIGGER, and a tablespace quota. Start the client at the project root. Run `@db/00_build.sql` once, then `@tests/01_assertions.sql` through `@tests/04_runtime.sql`, followed by `@db/05_demo.sql`. Other schemas on the server are independent of this project.
