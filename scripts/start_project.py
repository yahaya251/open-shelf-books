#!/usr/bin/env python3
"""Start Open Shelf Books safely; build only an absent or empty project schema."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from oracle import LauncherError, OracleLauncher, Settings

ROOT = Path(__file__).resolve().parents[1]
TABLES = ("MEMBER_TYPE", "LIB_MEMBER", "STAFF", "PUBLISHER", "BOOK_TITLE",
          "AUTHOR", "TITLE_AUTHOR", "BOOK_COPY", "LOAN", "RENEWAL", "RESERVATION")


def announce(message: str) -> None:
    print(message, flush=True)


def nonsecret_environment(environment: dict[str, str]) -> dict[str, str]:
    return {key: value for key, value in environment.items()
            if not key.endswith("_DB_PASSWORD")}


def add_engine_paths(environment: dict[str, str]) -> None:
    """Finder does not necessarily inherit Homebrew or Docker's CLI directory."""
    directories = ["/opt/homebrew/bin", "/usr/local/bin",
                   "/Applications/Docker.app/Contents/Resources/bin"]
    if os.name == "nt":
        directories.append(str(Path(environment.get("ProgramFiles", r"C:\Program Files"))
                               / "Docker" / "Docker" / "resources" / "bin"))
    found = [directory for directory in directories if Path(directory).is_dir()]
    environment["PATH"] = os.pathsep.join([*found, environment.get("PATH", os.defpath)])


def local_configuration(root: Path) -> dict:
    file = root / ".local" / "runtime.json"
    if not file.exists():
        return {}
    try:
        value = json.loads(file.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as error:
        raise LauncherError(f"Cannot read .local/runtime.json: {error}") from None
    if not isinstance(value, dict) or "password" in value:
        raise LauncherError("Local runtime configuration must be an object without a password.")
    return value


def runtime_root(root: Path, config: dict, environment: dict[str, str]) -> Path:
    value = environment.get("OPEN_SHELF_RUNTIME_ROOT") or config.get("runtime_root") or ".local-macos"
    if not isinstance(value, str):
        raise LauncherError("runtime_root must be a directory path.")
    path = Path(value).expanduser()
    return (path if path.is_absolute() else root / path).resolve()


def select_backend(root: Path, requested: str, config: dict,
                   environment: dict[str, str]) -> tuple[str, Path | None]:
    backend = requested if requested != "auto" else config.get("backend", "auto")
    local_root = runtime_root(root, config, environment)
    if backend == "auto":
        if environment.get("OPEN_SHELF_ENGINE"):
            backend = "external"
        else:
            available = [(name, shutil.which(name, path=environment.get("PATH")))
                         for name in ("docker", "podman")]
            installed = [(name, executable) for name, executable in available if executable]
            backend = None
            for name, executable in installed:
                try:
                    info = subprocess.run([executable, "info"], env=nonsecret_environment(environment),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8, check=False)
                    if info.returncode == 0:
                        backend = name
                        break
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if backend is None and installed:
                backend = installed[0][0]
            if backend is None:
                raise LauncherError("No container engine found. Install Python 3.10+ and Docker Desktop, "
                                    "or explicitly configure a healthy existing Lima environment. See docs/setup.md.")
    if backend not in ("lima", "docker", "podman", "external"):
        raise LauncherError("Choose backend auto, docker, podman, lima, or external.")
    if backend == "lima":
        if sys.platform != "darwin":
            raise LauncherError("The preserved Lima environment is available only on its original Mac.")
        binary = local_root / "10_Oracle_Runtime" / "lima" / "bin" / "limactl"
        instance = config.get("instance", "db")
        if not isinstance(instance, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", instance):
            raise LauncherError("Invalid Lima instance name.")
        if not binary.is_file() or not (local_root / ".vm" / instance / "lima.yaml").is_file():
            raise LauncherError("The existing Lima runtime is incomplete. No new VM was created. "
                                "See docs/local-macos.md for recovery.")
        environment["OPEN_SHELF_RUNTIME_ROOT"] = str(local_root)
        environment["OPEN_SHELF_LIMA_INSTANCE"] = instance
        environment["OPEN_SHELF_PYTHON"] = sys.executable
        environment["OPEN_SHELF_ENGINE"] = str(root / "scripts" / "lima-engine")
        environment.setdefault("OPEN_SHELF_CONTAINER", config.get("container", "wia2001-oracle"))
        return backend, local_root
    if backend in ("docker", "podman"):
        environment["OPEN_SHELF_ENGINE"] = backend
    elif not environment.get("OPEN_SHELF_ENGINE"):
        raise LauncherError("The external backend requires OPEN_SHELF_ENGINE.")
    return backend, None


def run_local(command: list[str], environment: dict[str, str], *, timeout: int = 600):
    try:
        completed = subprocess.run(command, env=nonsecret_environment(environment),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LauncherError(f"Cannot complete the local runtime command: {type(error).__name__}") from None
    if completed.returncode:
        output = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
        raise LauncherError(output.strip() or "The local runtime command failed.")
    return completed


def start_lima(launcher: OracleLauncher, local_root: Path) -> None:
    environment = dict(launcher.environment)
    environment["LIMA_HOME"] = str(local_root / ".vm")
    environment["XDG_CACHE_HOME"] = str(local_root / "10_Oracle_Runtime" / "cache")
    binary = str(local_root / "10_Oracle_Runtime" / "lima" / "bin" / "limactl")
    instance = environment["OPEN_SHELF_LIMA_INSTANCE"]
    completed = run_local([binary, "list", instance, "--json"], environment, timeout=30)
    try:
        info = json.loads(completed.stdout.decode("utf-8"))
    except ValueError:
        raise LauncherError("Cannot read the existing Lima instance status.") from None
    status = info.get("status", "unknown")
    if status == "Stopped":
        announce("Starting the preserved local Mac VM; its disk and data stay in place...")
        run_local([binary, "start", "--tty=false", "--timeout=8m", instance], environment)
    elif status != "Running":
        raise LauncherError(f"The preserved VM reports {status}. No automatic repair was attempted. "
                            "See docs/local-macos.md.")
    info = launcher.inspect(optional=True)
    if info is None:
        raise LauncherError("The existing Lima Oracle container was not found. No replacement was created.")
    if (info.get("State") or {}).get("Status") != "running":
        launcher.checked(launcher.engine_run(["start", launcher.container]))
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if launcher.readiness():
            announce("PDB_READY=FREEPDB1:READ WRITE")
            return
        time.sleep(2)
    raise LauncherError("The existing Oracle container did not become ready; its data was retained.")


def ensure_engine(launcher: OracleLauncher, backend: str, *, open_desktop: bool) -> None:
    if launcher.engine_run(["info"], timeout=15).returncode == 0:
        return
    if backend != "docker" or not open_desktop:
        raise LauncherError("Start the selected Docker or Podman engine, then run this launcher again.")
    environment = nonsecret_environment(launcher.environment)
    command = None
    if sys.platform == "darwin" and Path("/Applications/Docker.app").is_dir():
        command = ["/usr/bin/open", "-a", "Docker"]
    elif os.name == "nt":
        desktop = Path(environment.get("ProgramFiles", r"C:\Program Files")) / "Docker" / "Docker" / "Docker Desktop.exe"
        if desktop.is_file():
            command = [str(desktop)]
    if command is None:
        raise LauncherError("Docker is installed but its engine is stopped. Open Docker Desktop and retry.")
    announce("Opening Docker Desktop and waiting for its Linux engine...")
    subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if launcher.engine_run(["info"], timeout=15).returncode == 0:
            return
        time.sleep(3)
    raise LauncherError("Docker Desktop is not ready yet. Finish any first-run setup, then retry.")


def number(output: str, marker: str) -> int:
    values = re.findall(r"^" + re.escape(marker) + r"=([0-9]+)\s*$", output, re.MULTILINE)
    if len(values) != 1:
        raise LauncherError(f"Missing database state result: {marker}")
    return int(values[0])


def prepare_schema(launcher: OracleLauncher) -> bool:
    """Return True after a fresh build. Never reset a populated account."""
    body = f"""WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF VERIFY OFF HEADING OFF FEEDBACK OFF PAGESIZE 0
ALTER SESSION SET CONTAINER=FREEPDB1;
SELECT 'OSB_SCHEMA_EXISTS='||COUNT(*) FROM dba_users WHERE username='{launcher.schema}';
EXIT SUCCESS ROLLBACK
"""
    output = launcher.checked(launcher.admin(body), sql=True, show=False)
    exists = number(output, "OSB_SCHEMA_EXISTS")
    launcher.ask_password()
    launcher.sync_sql()
    if exists == 0:
        announce("Creating the dedicated project account and synthetic sample database...")
        launcher.bootstrap()
        launcher.sql_scripts("build")
        return True
    if exists != 1:
        raise LauncherError("Unexpected project account state; no data was changed.")
    names = ",".join("'" + name + "'" for name in TABLES)
    output = launcher.app_sql(f"""SET ECHO OFF VERIFY OFF HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'OSB_OBJECTS='||COUNT(*) FROM user_objects;
SELECT 'OSB_TABLES='||COUNT(*) FROM user_tables;
SELECT 'OSB_PROJECT_TABLES='||COUNT(*) FROM user_tables WHERE table_name IN ({names});
SELECT 'OSB_INVALID='||COUNT(*) FROM user_objects WHERE status='INVALID';
SELECT 'OSB_ERRORS='||COUNT(*) FROM user_errors;
""")
    if number(output, "OSB_OBJECTS") == 0:
        announce("The dedicated account is empty; loading the project schema and samples...")
        launcher.sql_scripts("build")
        return True
    if (number(output, "OSB_TABLES") != len(TABLES)
            or number(output, "OSB_PROJECT_TABLES") != len(TABLES)
            or number(output, "OSB_INVALID") != 0 or number(output, "OSB_ERRORS") != 0):
        raise LauncherError("This account is populated but does not match a healthy project schema. "
                            "Existing objects were retained; no reset was attempted.")
    announce("Existing project database found. Its records were preserved.")
    return False


def start(args, *, root: Path = ROOT) -> None:
    environment = dict(os.environ)
    add_engine_paths(environment)
    config = local_configuration(root)
    backend, local_root = select_backend(root, args.backend, config, environment)
    announce(f"Open Shelf Books | backend: {backend}")
    launcher = OracleLauncher(Settings.load(root), environment)
    if args.status:
        launcher.status()
        return
    if args.stop:
        if backend in ("lima", "external"):
            raise LauncherError("The selected existing runtime may be shared. Use its owner's stop procedure; "
                                "this launcher did not stop it.")
        launcher.run("stop")
        return
    if backend == "lima":
        start_lima(launcher, local_root)
    elif backend == "external":
        launcher.require_ready()
    else:
        ensure_engine(launcher, backend, open_desktop=not args.no_desktop)
        launcher.start()
    prepare_schema(launcher)
    if args.verify:
        announce("Running the baseline Oracle verification...")
        launcher.sql_scripts("verify")
    if args.demo:
        announce("Running the rollback-only four-statement demonstration...")
        launcher.sql_scripts("demo")
    if args.scenario:
        announce("Running the optional synthetic circulation scenario...")
        launcher.app_sql((root / "db" / "06_synthetic_scenario.sql").read_text(encoding="utf-8"),
                         markers=["SIM_SCENARIO=PASS"])
    if args.concurrency:
        announce("Running two independent Oracle sessions...")
        launcher.concurrency()
    if args.sql_file is not None:
        announce("Running the selected UTF-8 SQL file...")
        body = args.sql_file.read_bytes().decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
        launcher.app_sql(body)
    announce("OPEN_SHELF_START=PASS")
    announce(f"The database is ready. SQL input: python scripts/start_project.py --backend {backend} --sql-file queries/overview.sql")
    announce("The database stays running; its data volume is retained.")


def main(argv=None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["auto", "docker", "podman", "lima", "external"], default="auto")
    parser.add_argument("--demo", action="store_true", help="Run the rollback-only baseline demo")
    parser.add_argument("--verify", action="store_true", help="Verify the untouched synthetic fixture")
    parser.add_argument("--scenario", action="store_true", help="Run the optional three-member scenario, then roll it back")
    parser.add_argument("--concurrency", action="store_true", help="Run the baseline two-session contention tests")
    parser.add_argument("--no-desktop", action="store_true", help="Do not open Docker Desktop automatically")
    operations = parser.add_mutually_exclusive_group()
    operations.add_argument("--status", action="store_true", help="Read the selected container/PDB status without starting it")
    operations.add_argument("--stop", action="store_true", help="Stop only this project's managed container; retain its volume")
    parser.add_argument("--sql-file", type=Path, help="Run a UTF-8 SQL file using the same selected backend")
    args = parser.parse_args(argv)
    if (args.status or args.stop) and (args.demo or args.verify or args.scenario or args.concurrency or args.sql_file):
        parser.error("--status/--stop cannot be combined with database actions")
    try:
        if sys.version_info < (3, 10):
            raise LauncherError("Python 3.10 or newer is required.")
        start(args)
        return 0
    except (LauncherError, OSError, UnicodeDecodeError) as error:
        print(str(error), file=sys.stderr)
        print("No automatic reset or data deletion was performed. See docs/setup.md.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted; existing data was retained.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
