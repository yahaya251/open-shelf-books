# Environment setup

[Project overview](../README.md) · [Run guide](oracle-workflow.md)

The portable project uses Python 3.10+ and a Linux Oracle Free container. Its Python tools require only the standard library. Oracle and SQL*Plus run inside the container; no host listener port needs to be published.

## Windows

1. Install Python 3.10 or later with its Python launcher. Check `py -3 --version` in PowerShell.
2. Install Docker Desktop and finish its first-run setup. Select Linux containers. Alternatively, use an already configured Podman engine.
3. Open the project folder and run `run_windows.bat`.

The batch file chooses a working Python launcher and starts the project from its own directory, including when the folder path contains spaces. If you use a particular Python installation, set `OPEN_SHELF_PYTHON` to the full path of its executable.

## macOS

1. Install Python 3.10+ if no suitable local interpreter is available. Check `python3 --version` in Terminal.
2. Install Docker Desktop for the Mac's processor and finish its first-run setup, or start an existing Podman machine. A healthy preserved Lima VM is an optional backend that must be explicitly selected.
3. Open `run_macos.command`. If its execute permission was lost during copying, run `chmod +x run_macos.command scripts/lima-engine` from this directory.

The launcher searches common Python and Docker installation paths. An existing local application Python can also be used; the project has no dependency on a specific development app.

Official installation guides: [Python](https://www.python.org/downloads/) · [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/) · [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/) · [Podman](https://podman.io/docs/installation)

## Choose a backend

The default selects a working Docker or Podman engine first. If an installed Docker engine is stopped, startup can open Docker Desktop. It never automatically selects a stale or unavailable legacy VM. Select Lima explicitly with `--backend lima` or ignored local configuration. An explicit `OPEN_SHELF_ENGINE` selects an external engine that is already running.

```sh
python3 scripts/start_project.py --backend docker --demo
python3 scripts/start_project.py --backend podman --demo
python3 scripts/start_project.py --backend lima --demo
```

`--no-desktop` disables automatic opening of Docker Desktop. Podman's machine must already be configured and running. A first Oracle image download can take several minutes.

To point to an existing Mac runtime before or after migration, set `OPEN_SHELF_RUNTIME_ROOT` to the directory containing both `.vm/` and `10_Oracle_Runtime/`. Alternatively, create ignored `.local/runtime.json`:

```json
{
  "backend": "lima",
  "runtime_root": ".local-macos",
  "instance": "db",
  "container": "wia2001-oracle"
}
```

Paths in this file are relative to the project unless absolute. Keep machine-specific configuration local; do not include a password.

## Passwords and existing records

The account is `OPEN_SHELF_BOOKS` by default. Passwords contain 12–64 ASCII letters, digits or underscores. They are entered through a hidden terminal prompt and are not saved by startup. `OPEN_SHELF_DB_PASSWORD` is available for a noninteractive run; keep it outside source files and clear it when finished.

Startup creates only the dedicated missing account or builds an empty one. A healthy populated account is kept. An incomplete schema produces an error for review instead of automatically dropping or rebuilding its objects. A wrong password does not trigger account recreation.

## Use the same backend for later operations

Use `start_project.py` for backend-aware commands, especially when ignored local configuration selects Lima:

```sh
python3 scripts/start_project.py --status
python3 scripts/start_project.py --verify --demo --concurrency
python3 scripts/start_project.py --sql-file queries/overview.sql
python3 scripts/start_project.py --stop
```

`--status` does not start the runtime. `--stop` stops only a managed Docker/Podman project container and retains its data volume; it refuses shared existing environments. The lower-level `oracle.py` uses Docker/Podman defaults unless its engine environment variables are explicitly provided.
