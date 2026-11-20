# Open Shelf Books

Open Shelf Books is an Oracle database for physical library circulation. It tracks titles, copies, checkout, return, renewal, reservations, and borrowing reports. All fixtures are synthetic. An application using this database supplies its own authentication and user interface.

## Run on Windows or macOS

Install Python 3.10 or later and start Docker Desktop. On Windows, select Linux containers with the WSL 2 backend. On macOS, install Docker Desktop for your Mac's processor. Launch a terminal at the repository root. The Python launcher uses only the standard library. [Windows setup](https://docs.docker.com/desktop/setup/install/windows-install/) · [macOS setup](https://docs.docker.com/desktop/setup/install/mac-install/)

| Task | Windows PowerShell | macOS Terminal |
| --- | --- | --- |
| Check engine | `docker info` | `docker info` |
| Start Oracle | `py -3 scripts/oracle.py start` | `python3 scripts/oracle.py start` |
| Build once | `py -3 scripts/oracle.py setup` | `python3 scripts/oracle.py setup` |
| Verify | `py -3 scripts/oracle.py verify` | `python3 scripts/oracle.py verify` |
| Run the demo | `py -3 scripts/oracle.py demo` | `python3 scripts/oracle.py demo` |
| Test concurrency | `py -3 scripts/oracle.py concurrency` | `python3 scripts/oracle.py concurrency` |
| Stop and retain data | `py -3 scripts/oracle.py stop` | `python3 scripts/oracle.py stop` |

The database opens `FREEPDB1` inside the container. The first start downloads the Oracle Free Lite image. The launcher uses the dedicated `OPEN_SHELF_BOOKS` schema and prompts for a password of 12–64 ASCII letters, digits, or underscores. Use the same password for subsequent commands. Once built, restart with `start` and continue with `verify` or `demo`.

The verification should report 11 tables, 12 enabled foreign keys, and 30 passing assertions. The demo uses four statements, then rolls back its return. It restores the eight-loan fixture, including five open loans.

[Complete operational guide](docs/oracle-workflow.md) · [Schema and ERD](docs/schema.md) · [Design and policies](docs/design.md) · [Demo and transcript](demo/README.md) · [Verification](tests/VERIFIED.md)

## Project files

- `db/` contains the schema, synthetic seed data, circulation package, reports, demo, and explicit reset SQL.
- `tests/` contains Oracle assertions, transaction and concurrency tests, and a 44-check offline validator.
- `scripts/` contains the cross-platform launcher.
- `docs/` and `demo/` contain operating and design guidance and sample output.
