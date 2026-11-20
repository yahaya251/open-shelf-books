#!/usr/bin/env python3
"""Portable Oracle Free controller, using only the Python 3.10+ standard library.

Run from any working directory: python scripts/oracle.py COMMAND.
Docker/Podman must already be installed and running. An optional oracle.json at
the repository root overrides Settings defaults for another project layout.
Passwords are supplied on standard input to SQL*Plus, never in engine argv.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import getpass
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import time
from typing import Mapping
import warnings


IMAGE = "container-registry.oracle.com/database/free@sha256:cf540c3fa190d7cffad08c491652ac07fc70314e510f6b87890449517d565e94"
READY_MARKER = "PDB_READY=FREEPDB1:READ WRITE"
SQL_ERROR = re.compile(r"^\s*(?:ORA|SP2|PLS)-[0-9]+:", re.MULTILINE)


class LauncherError(Exception):
    """An actionable configuration, engine, or Oracle error."""


def relative_file(value: str) -> str:
    """Keep profile paths relative and safe for a quoted SQL*Plus @ command."""
    if not isinstance(value, str) or not value or any(c in value for c in '\\"\r\n\0'):
        raise LauncherError("Profile file paths must be relative POSIX paths without quotes or control characters.")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or ":" in value:
        raise LauncherError(f"Profile file path escapes the project: {value!r}")
    return str(path)


@dataclass
class Settings:
    """Importable profile; oracle.json accepts these keys except root."""
    root: Path
    env_prefix: str = "OPEN_SHELF"
    schema_prefix: str = "OPEN_SHELF_BOOKS"
    default_schema: str = "OPEN_SHELF_BOOKS"
    container: str = "open-shelf-books-oracle"
    workdir: str = "/tmp/open-shelf-books"
    image: str = IMAGE
    label_key: str = "org.open-shelf-books.service"
    label_value: str = "oracle"
    sql_directories: list[str] = field(default_factory=lambda: ["db", "tests"])
    sql: dict[str, list[str]] = field(default_factory=lambda: {
        "build": ["db/00_build.sql"],
        "verify": ["tests/01_assertions.sql", "tests/02_admin_and_dml.sql",
                   "tests/03_atomicity.sql", "tests/04_runtime.sql"],
        "demo": ["db/05_demo.sql"],
        "reset": ["db/99_drop_project_objects.sql"],
    })
    markers: dict[str, list[str]] = field(default_factory=lambda: {
        "build": ["OPEN_SHELF_BUILD=PASS"],
        "verify": ["RUNTIME_CHECKS=PASS"],
        "demo": ["OPEN_SHELF_DEMO=PASS"],
        "reset": ["OPEN_SHELF_RESET=PASS"],
        "concurrency": ["OSB_CONC_ALL_PASS"],
    })
    concurrency: str = "tests/live_concurrency.py"
    messages: dict[str, str] = field(default_factory=dict)

    @classmethod
    def load(cls, root: Path) -> Settings:
        root = root.resolve()
        profile = root / "oracle.json"
        if not profile.is_file():
            return cls(root=root)
        try:
            raw = json.loads(profile.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as error:
            raise LauncherError(f"Cannot read oracle.json: {error}") from None
        if not isinstance(raw, dict):
            raise LauncherError("oracle.json must contain an object.")
        allowed = set(cls.__dataclass_fields__) - {"root"}
        unknown = set(raw) - allowed
        if unknown:
            raise LauncherError("Unknown oracle.json settings: " + ", ".join(sorted(unknown)))
        settings = cls(root=root)
        for key, value in raw.items():
            if key in ("sql", "markers"):
                if not isinstance(value, dict):
                    raise LauncherError(f"oracle.json {key} must contain an object.")
                getattr(settings, key).update(value)
            else:
                setattr(settings, key, value)
        return settings


class OracleLauncher:
    """Importable implementation for managed or explicitly selected containers."""

    def __init__(self, settings: Settings, environment: Mapping[str, str] | None = None):
        self.settings = settings
        self.environment = dict(os.environ if environment is None else environment)
        self.root = Path(settings.root).resolve()
        if not isinstance(settings.env_prefix, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", settings.env_prefix):
            raise LauncherError("Invalid environment variable prefix in oracle.json.")
        if not isinstance(settings.schema_prefix, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,39}", settings.schema_prefix):
            raise LauncherError("Invalid schema prefix in oracle.json.")
        self.password_variable = settings.env_prefix + "_DB_PASSWORD"
        self.container = self.environment.get(settings.env_prefix + "_CONTAINER", settings.container)
        self.schema = self.environment.get(settings.env_prefix + "_SCHEMA", settings.default_schema)
        if not isinstance(self.container, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", self.container):
            raise LauncherError("Invalid Oracle container name.")
        schema_pattern = re.escape(settings.schema_prefix) + r"(?:_[A-Z][A-Z0-9_]{0,10})?"
        if not isinstance(self.schema, str) or not re.fullmatch(schema_pattern, self.schema):
            raise LauncherError(f"Use {settings.schema_prefix} or an uppercase {settings.schema_prefix}_* schema.")
        if (not isinstance(settings.workdir, str) or not settings.workdir.startswith("/tmp/")
                or ".." in PurePosixPath(settings.workdir).parts
                or any(ord(c) < 32 for c in settings.workdir)):
            raise LauncherError("The container workdir must be a directory below /tmp/.")
        for name in ("image", "label_key", "label_value"):
            value = getattr(settings, name)
            if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
                raise LauncherError(f"Invalid {name} in oracle.json.")
        if settings.image.startswith("-") or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", settings.label_key):
            raise LauncherError("Invalid image or container label key in oracle.json.")
        if not isinstance(settings.sql_directories, list) or not settings.sql_directories:
            raise LauncherError("sql_directories must contain project directory paths.")
        settings.sql_directories = [relative_file(name) for name in settings.sql_directories]
        if not isinstance(settings.sql, dict) or not isinstance(settings.markers, dict):
            raise LauncherError("SQL scripts and markers must be objects.")
        if set(settings.sql) - {"build", "verify", "demo", "reset"}:
            raise LauncherError("SQL command keys must be build, verify, demo, or reset.")
        for command in ("build", "verify", "demo", "reset"):
            scripts = settings.sql.get(command)
            if not isinstance(scripts, list) or not scripts:
                raise LauncherError(f"The {command} SQL script list must not be empty.")
            settings.sql[command] = [relative_file(name) for name in scripts]
            if any(not name.lower().endswith(".sql") for name in settings.sql[command]):
                raise LauncherError("SQL command lists must contain .sql files.")
        settings.concurrency = relative_file(settings.concurrency)
        for command, markers in settings.markers.items():
            if not isinstance(markers, list) or any(not isinstance(m, str) or not m for m in markers):
                raise LauncherError(f"Invalid success markers for {command}.")
        if not isinstance(settings.messages, dict) or any(
                not isinstance(key, str) or not isinstance(value, str)
                for key, value in settings.messages.items()):
            raise LauncherError("messages must map English phrases to translated strings.")
        self.password = ""
        requested = self.environment.get(settings.env_prefix + "_ENGINE", "")
        search_path = self.environment.get("PATH", os.defpath)
        candidates = [requested] if requested else ["docker", "podman"]
        self.engine = next((found for name in candidates if (found := shutil.which(name, path=search_path))), None)
        if self.engine is None:
            raise LauncherError(f"Install and start Docker or Podman, or set {settings.env_prefix}_ENGINE to an executable path.")

    def redact(self, text: str) -> str:
        return text.replace(self.password, "[REDACTED]") if self.password else text

    def message(self, text: str, **values: str) -> str:
        return self.settings.messages.get(text, text).format(**values)

    def emit(self, text: str, *, error: bool = False) -> None:
        if text:
            print(self.redact(text).rstrip(), file=sys.stderr if error else sys.stdout, flush=True)

    def engine_run(self, args: list[str], payload: bytes | None = None, *, timeout: float = 180) -> subprocess.CompletedProcess:
        environment = dict(self.environment)
        environment.pop(self.password_variable, None)
        environment.pop("OPEN_SHELF_DB_PASSWORD", None)
        try:
            return subprocess.run([self.engine, *args], input=payload, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, env=environment, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            partial = (error.stdout or b"").decode("utf-8", errors="replace")
            raise LauncherError(self.redact(partial) + "\nThe container engine timed out.") from None
        except OSError as error:
            raise LauncherError(f"Cannot run the container engine: {error}") from None

    def checked(self, completed: subprocess.CompletedProcess, *, sql: bool = False,
                markers: tuple[str, ...] | list[str] = (), show: bool = True) -> str:
        output = self.redact(completed.stdout.decode("utf-8", errors="replace"))
        failed = completed.returncode != 0 or (sql and SQL_ERROR.search(output))
        missing = [marker for marker in markers if marker not in output]
        if show:
            self.emit(output)
        if failed or missing:
            if not show:
                self.emit(output, error=True)
            if missing:
                raise LauncherError("Expected result missing: " + ", ".join(missing))
            raise LauncherError("Oracle or the container engine reported an error; review the output above.")
        return output

    def inspect(self, *, optional: bool = False) -> dict | None:
        completed = self.engine_run(["container", "inspect", self.container])
        output = completed.stdout.decode("utf-8", errors="replace")
        if completed.returncode != 0 and optional:
            if re.search(r"no such (?:container|object)|container[^\r\n]*(?:not found|does not exist)", output, re.IGNORECASE):
                return None
        self.checked(completed, show=False)
        try:
            data = json.loads(output)
            if isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict):
                return data[0]
            if isinstance(data, dict):
                return data
        except ValueError:
            pass
        raise LauncherError("The container engine returned an unexpected inspect response.")

    def require_managed(self, info: dict) -> None:
        labels = (info.get("Config") or {}).get("Labels") or {}
        if labels.get(self.settings.label_key) != self.settings.label_value:
            raise LauncherError("This container belongs to another service. Use its own start/stop controller, or select a different container name.")

    def admin(self, body: str, *, timeout: float = 180) -> subprocess.CompletedProcess:
        return self.engine_run(["exec", "-i", "--env", "NLS_LANG=AMERICAN_AMERICA.AL32UTF8",
            self.container, "sqlplus", "-s", "-L", "/ as sysdba"], body.encode("utf-8"), timeout=timeout)

    def readiness(self) -> bool:
        body = """WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF VERIFY OFF HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'PDB_READY=FREEPDB1:READ WRITE' FROM v$pdbs WHERE name='FREEPDB1' AND open_mode='READ WRITE';
EXIT SUCCESS ROLLBACK
"""
        completed = self.admin(body, timeout=20)
        output = completed.stdout.decode("utf-8", errors="replace")
        return (completed.returncode == 0 and not SQL_ERROR.search(output)
                and any(line.strip() == READY_MARKER for line in output.splitlines()))

    def require_ready(self) -> None:
        if not self.readiness():
            raise LauncherError("FREEPDB1 is unavailable. Start the Oracle container first, then check status.")

    def start(self) -> None:
        info = self.inspect(optional=True)
        if info is not None:
            self.require_managed(info)
            self.checked(self.engine_run(["start", self.container]))
        else:
            self.emit(self.message("Starting Oracle; the first image download may take several minutes."))
            self.checked(self.engine_run(["run", "-d", "--name", self.container,
                "--label", self.settings.label_key + "=" + self.settings.label_value,
                "--shm-size=1g", "--volume", self.container + "-data:/opt/oracle/oradata",
                self.settings.image], timeout=1800))
        deadline = time.monotonic() + 180
        self.emit(self.message("Waiting for FREEPDB1 to open..."))
        while time.monotonic() < deadline:
            try:
                if self.readiness():
                    self.emit(READY_MARKER)
                    return
            except LauncherError:
                pass
            time.sleep(2)
        raise LauncherError("FREEPDB1 did not open within three minutes. Check the container logs, then retry status.")

    def status(self) -> None:
        info = self.inspect()
        state = (info.get("State") or {}).get("Status", "unknown")
        self.emit(self.message("Container {container}: {state}", container=self.container, state=state))
        self.require_ready()
        self.emit(READY_MARKER)

    def ask_password(self) -> None:
        password = self.environment.get(self.password_variable, "")
        if not password:
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("error", getpass.GetPassWarning)
                    password = getpass.getpass(self.message("Password for {schema}: ", schema=self.schema))
            except (EOFError, OSError, getpass.GetPassWarning):
                raise LauncherError(f"Set {self.password_variable} when no secure terminal is available.") from None
        if not re.fullmatch(r"[A-Za-z0-9_]{12,64}", password):
            raise LauncherError("Use 12–64 ASCII letters, digits or underscores for the schema password.")
        self.password = password

    def local_file(self, relative: str) -> Path:
        path = (self.root / Path(*PurePosixPath(relative).parts)).resolve()
        if not path.is_relative_to(self.root) or not path.is_file():
            raise LauncherError(f"Missing project file or file outside the project: {relative}")
        return path

    def archive(self) -> bytes:
        """Build POSIX archive names on Windows too; no VM, .env, or credentials."""
        files: dict[str, Path] = {}
        for directory in self.settings.sql_directories:
            base = (self.root / Path(*PurePosixPath(directory).parts)).resolve()
            if not base.is_relative_to(self.root) or not base.is_dir():
                raise LauncherError(f"Missing SQL source directory: {directory}")
            for path in base.rglob("*.sql"):
                relative = path.relative_to(self.root).as_posix()
                files[relative] = self.local_file(relative)
        for scripts in self.settings.sql.values():
            for relative in scripts:
                self.local_file(relative)
                if relative not in files:
                    raise LauncherError(f"Script is outside sql_directories: {relative}")
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for relative, path in sorted(files.items()):
                content = path.read_bytes()
                entry = tarfile.TarInfo(relative)
                entry.size = len(content)
                entry.mode = 0o644
                archive.addfile(entry, io.BytesIO(content))
        return data.getvalue()

    def ensure_workdir(self) -> None:
        self.checked(self.engine_run(["exec", "-i", self.container, "sh", "-ec",
            'mkdir -p "$1"', "sh", self.settings.workdir]))

    def sync_sql(self) -> None:
        self.checked(self.engine_run(["exec", "-i", self.container, "sh", "-ec",
            'mkdir -p "$1" && tar -xf - -C "$1"', "sh", self.settings.workdir], self.archive()))

    def bootstrap(self) -> None:
        # schema/password match strict ASCII patterns before reaching either DDL string.
        if not re.fullmatch(r"[A-Za-z0-9_]{12,64}", self.password):
            raise LauncherError("A valid schema password is required before account setup.")
        tablespace = self.schema + "_DATA"
        datafile = tablespace.lower() + ".dbf"
        body = f"""WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF DEFINE OFF
ALTER SESSION SET CONTAINER=FREEPDB1;
DECLARE
    present NUMBER;
BEGIN
    SELECT COUNT(*) INTO present FROM dba_users WHERE username='{self.schema}';
    IF present=0 THEN
        SELECT COUNT(*) INTO present FROM dba_tablespaces WHERE tablespace_name='{tablespace}';
        IF present=0 THEN
            EXECUTE IMMEDIATE 'CREATE TABLESPACE {tablespace} DATAFILE ''/opt/oracle/oradata/FREE/FREEPDB1/{datafile}'' SIZE 20M AUTOEXTEND ON NEXT 10M MAXSIZE 120M';
        END IF;
        EXECUTE IMMEDIATE 'CREATE USER {self.schema} IDENTIFIED BY "{self.password}" DEFAULT TABLESPACE {tablespace} QUOTA 100M ON {tablespace}';
        EXECUTE IMMEDIATE 'GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE SEQUENCE, CREATE TRIGGER TO {self.schema}';
    END IF;
END;
/
EXIT SUCCESS ROLLBACK
"""
        self.checked(self.admin(body), sql=True)

    def app_sql(self, body: str, *, markers: tuple[str, ...] | list[str] = ()) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_]{12,64}", self.password):
            raise LauncherError("A schema password must be supplied before opening an application session.")
        preamble = f"""SET ECHO OFF DEFINE OFF
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
CONNECT {self.schema}/"{self.password}"@//localhost:1521/FREEPDB1
BEGIN
    IF SYS_CONTEXT('USERENV','SESSION_USER') <> '{self.schema}' OR SYS_CONTEXT('USERENV','CURRENT_SCHEMA') <> USER THEN
        RAISE_APPLICATION_ERROR(-20864, 'Wrong application schema');
    END IF;
END;
/
"""
        payload = (preamble + body + "\nEXIT SUCCESS ROLLBACK\n").encode("utf-8")
        completed = self.engine_run(["exec", "-i", "--workdir", self.settings.workdir,
            "--env", "NLS_LANG=AMERICAN_AMERICA.AL32UTF8", self.container,
            "sqlplus", "-s", "-L", "/nolog"], payload)
        return self.checked(completed, sql=True, markers=markers)

    def sql_scripts(self, command: str) -> str:
        body = "\n".join('@"' + name + '"' for name in self.settings.sql[command])
        return self.app_sql(body, markers=self.settings.markers.get(command, []))

    def concurrency(self) -> None:
        script = self.local_file(self.settings.concurrency)
        environment = dict(self.environment)
        environment[self.password_variable] = self.password
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUTF8"] = "1"
        command = [sys.executable, str(script), sys.executable, str(Path(__file__).resolve()), "sql"]
        try:
            completed = subprocess.run(command, cwd=self.root, env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise LauncherError(f"Could not finish the concurrency runner: {type(error).__name__}") from None
        self.checked(completed, sql=True, markers=self.settings.markers.get("concurrency", []))

    def run(self, command: str, *, confirmed: bool = False, sql_input: str = "") -> None:
        if command == "start":
            self.start()
        elif command == "status":
            self.status()
        elif command == "stop":
            self.require_managed(self.inspect())
            self.checked(self.engine_run(["stop", self.container]))
        elif command in ("setup", "verify", "demo", "concurrency", "sql", "reset"):
            if command == "reset" and not confirmed:
                raise LauncherError("Reset drops this schema's project objects and data. Run reset --confirm to proceed.")
            self.require_ready()
            self.ask_password()
            if command == "sql":
                self.ensure_workdir()
                self.app_sql(sql_input)
                return
            self.sync_sql()
            if command == "setup":
                self.bootstrap()
                self.sql_scripts("build")
            elif command == "concurrency":
                self.concurrency()
            else:
                self.sql_scripts(command)
        else:
            raise LauncherError(f"Unknown command: {command}")


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["start", "status", "setup", "verify", "demo", "concurrency", "sql", "stop", "reset"])
    parser.add_argument("--confirm", action="store_true", help="Confirm reset of application objects and data")
    parser.add_argument("--file", type=Path, help="Read SQL from a UTF-8 file (sql command only; BOM accepted)")
    args = parser.parse_args(argv)
    if args.confirm and args.command != "reset":
        parser.error("--confirm is only valid with reset")
    if args.command == "reset" and not args.confirm:
        parser.error("reset deletes application objects and data; use reset --confirm")
    if args.file is not None and args.command != "sql":
        parser.error("--file is only valid with sql")
    settings = None
    try:
        settings = Settings.load(Path(__file__).resolve().parent.parent)
        launcher = OracleLauncher(settings)
        body = ""
        if args.command == "sql":
            data = args.file.read_bytes() if args.file is not None else sys.stdin.buffer.read()
            body = data.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
        launcher.run(args.command, confirmed=args.confirm, sql_input=body)
        return 0
    except UnicodeDecodeError:
        print("SQL input must be UTF-8 encoded.", file=sys.stderr)
        return 1
    except LauncherError as error:
        text = str(error).strip()
        if settings is not None:
            for original, translated in settings.messages.items():
                text = text.replace(original, translated)
        print(text, file=sys.stderr)
        return 1
    except OSError as error:
        print(f"Cannot read the SQL input file: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
