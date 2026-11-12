# Open Shelf Books

[简体中文](README.zh-CN.md)

Open Shelf Books is a standalone Oracle database for lending physical library books. It separates titles from copies, applies loan policies per member category, records renewal history, and manages a first-in, first-out reservation queue. It includes an Oracle schema, a PL/SQL circulation API, sample data, reporting queries, and tests.

All seed records, identifiers, and transaction dates are synthetic. The database exposes SQL and PL/SQL interfaces. An integrating application supplies its own authentication and user interface.

## Quick start

Run the following from the repository root with Docker or Podman running. The helper starts a pinned Oracle Free Lite container and uses a dedicated `OPEN_SHELF_BOOKS` schema. Commands that access that schema prompt for its password. Use 12–64 ASCII letters, digits, or underscores.

```sh
./scripts/oracle.sh start
./scripts/oracle.sh setup
./scripts/oracle.sh verify
./scripts/oracle.sh demo
```

The demo reports outstanding loans, title popularity, and unmet reservations. It also returns a copy through the API and rolls back that return to restore the fixture. Run `./scripts/oracle.sh concurrency` with Python 3 to test competing checkouts through two Oracle sessions.

Use `./scripts/oracle.sh status` to check the container and PDB. To send SQL to the schema, pipe it into `./scripts/oracle.sh sql`, which reads standard input. `./scripts/oracle.sh stop` stops the container and keeps its volume. `./scripts/oracle.sh reset --confirm` drops this project’s objects and data in the dedicated schema.

### Existing Oracle instance

The SQL targets Oracle Database 19c or newer. Connect to a **dedicated, empty schema** using SQL*Plus or SQLcl. The schema needs `CREATE SESSION`, `CREATE TABLE`, `CREATE VIEW`, `CREATE PROCEDURE`, `CREATE SEQUENCE`, and a tablespace quota. The failure-injection test additionally needs `CREATE TRIGGER`. Keep passwords out of scripts and version control.

From a SQL session started at the repository root:

```sql
@db/00_build.sql
@tests/01_assertions.sql
@db/05_demo.sql
```

Oracle DDL commits implicitly. To deliberately clear a disposable project schema, connect as its owner and run `@db/99_drop_project_objects.sql`. The reset script accepts `OPEN_SHELF_BOOKS` or a suffixed name such as `OPEN_SHELF_BOOKS_DEV`. For checks without Oracle, use `python3 tests/validate_offline.py`. Offline checks do not exercise PL/SQL or Oracle row locks.

## Circulation workflow

| Action | Database behavior |
| --- | --- |
| Check out | Verify membership, copy condition, loan quota, and reservation priority. Create the loan and fulfill the first reservation if it belongs to the borrower. |
| Return | Close the loan and recalculate whether the copy can be lent. |
| Renew | Validate the loan, membership, renewal count, and competing reservations. Store the old and new due dates as a renewal event. |
| Reserve or cancel | Queue one active reservation per member and title when no copy can be lent. Close an active reservation on cancellation. |
| Report | Read inventory availability, overdue items, title popularity, and unmet demand. |

The API locks title and member rows before checking shared state. The caller commits successful changes or rolls them back. The schema also enforces uniqueness for open loans by copy and active reservations by member and title.

## Verification

In an isolated schema on Oracle AI Database 26ai Free `23.26.3.0.0`, the build, 30 assertions, DML, atomic rollback, and runtime checks passed. Both concurrent checkout tests passed. One covered two borrowers competing for the same copy and the other covered two checkouts competing for a member’s final loan slot. The tests reported 11 tables, 12 foreign keys, no invalid objects, and no compilation errors. Live validation used an existing Oracle container. [Observed demo output](demo/oracle-demo.txt)

## Project files

| Path | Contents |
| --- | --- |
| [`db/`](db/) | Schema, synthetic fixtures, PL/SQL package, reports, and repeatable demo |
| [`scripts/`](scripts/) | Local Oracle runtime commands |
| [`tests/`](tests/) | Oracle assertions, transaction and concurrency tests, and offline checks |
| [Schema and ERD](docs/schema.md) | Relationships, field dictionary, and constraints |
| [Design and policies](docs/design.md) | Workflow, access model, locking, and fixture policy source |
| [Demo](demo/README.md) | Commands and baseline fixture results |
