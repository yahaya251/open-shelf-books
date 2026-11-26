# Open Shelf Books

An English Oracle database project for physical library circulation: catalogue editions, barcoded copies, membership policies, checkout, return, renewal history, reservations and reports. Its 11 tables and 12 foreign keys use synthetic data. The database API is ready for a separate application to add authentication and a user interface.

## Start the project

Open this folder and double-click:

| Your computer | Start file |
| --- | --- |
| Windows | `run_windows.bat` |
| macOS | `run_macos.command` |

The launcher selects a usable Docker or Podman engine. The preserved original Mac environment is an optional, explicitly configured backend. With Docker installed, it opens Docker Desktop if needed. Python 3.10 or later is required. A new machine needs a running Linux container engine; a healthy existing Mac VM can be reused without Docker Desktop after explicit configuration. [Environment setup](docs/setup.md)

On first use, enter a password of 12–64 ASCII letters, digits or underscores for `OPEN_SHELF_BOOKS`. Use that same password later. The launcher builds only an absent or empty project account. When project tables already exist, it keeps their records and runs the rollback-only demonstration. It does not automatically reset data or stop the database.

Wait for `OPEN_SHELF_START=PASS`. The demo ends with `OPEN_SHELF_DEMO=PASS` and restores its eight-loan sample, including five open loans. If you have intentionally changed sample records, start without the fixture demo:

```sh
python3 scripts/start_project.py
```

Windows uses `py -3` in place of `python3`. [Complete run guide](docs/oracle-workflow.md) · [Original Mac runtime and migration](docs/local-macos.md)

## Verify and explore

From this directory:

```sh
python3 scripts/start_project.py --verify --concurrency
python3 scripts/start_project.py --sql-file queries/overview.sql
```

The untouched fixture should pass 30 Oracle assertions and the two-session tests. Use `python3 tests/validate_offline.py` for the 44 offline checks when Oracle is unavailable. [Existing validation record](tests/VERIFIED.md)

The optional three-member scenario exercises a successful renewal, pending holds, rejected queue bypass, cancellation and returns, then rolls back all added rows:

```sh
python3 scripts/start_project.py --scenario
```

It ends with `SIM_SCENARIO=PASS`. It uses the same tested schema, seed and circulation API. Oracle identity counters can advance even when rows are rolled back.

## Project contents

| Path | Contents |
| --- | --- |
| `db/` | Schema, synthetic fixtures, circulation API, reports, demo and optional scenario |
| `scripts/` | Portable Oracle CLI and one-click startup |
| `queries/` | Ready-to-run SQL examples |
| `tests/` | Offline, Oracle, rollback and concurrency checks |
| [Schema and ERD](docs/schema.md) | Entities, attributes, keys, relationships and constraints |
| [Design and policies](docs/design.md) | Workflow, locking and transaction ownership |
| [Demo](demo/README.md) | Baseline explanation and recorded output |

The local-only `.local-macos/` directory holds the original VM and installed Mac runtime after migration. `.local/` may hold machine settings, but never a password. Both directories are ignored by Git and excluded from a public source export. [Sharing the source safely](docs/sharing.md)
