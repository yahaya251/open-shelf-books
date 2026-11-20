"""Focused portable-launcher tests. They do not run Oracle or Docker."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

MODULE_FILE = Path(__file__).resolve().parents[1] / "scripts" / "oracle.py"
spec = importlib.util.spec_from_file_location("portable_oracle", MODULE_FILE)
oracle = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = oracle
spec.loader.exec_module(oracle)


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="launcher-test-", dir=MODULE_FILE.parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "project with spaces café"
        for directory in ("db", "tests", "scripts"):
            (self.root / directory).mkdir(parents=True)
        self.settings = oracle.Settings(root=self.root)
        for files in self.settings.sql.values():
            for relative in files:
                (self.root / relative).write_text("PROMPT fixture café\n", encoding="utf-8")
        (self.root / self.settings.concurrency).write_text("# test runner\n", encoding="utf-8")
        (self.root / ".env").write_text("PRIVATE=do-not-copy\n")
        (self.root / "db" / "private.env").write_text("PRIVATE=do-not-copy\n")
        self.password = "MockSecret_123456"
        self.environment = {"PATH": "/mock/bin", "OPEN_SHELF_DB_PASSWORD": self.password}
        self.engine = r"C:\Program Files\Docker\Docker\resources\bin\docker.exe"
        self.calls = []
        self.output = io.StringIO()

    def make_launcher(self, settings=None, environment=None):
        with patch.object(oracle.shutil, "which", return_value=self.engine):
            return oracle.OracleLauncher(settings or self.settings, environment or self.environment)

    def fake_engine(self, argv, **options):
        self.calls.append((argv, options))
        self.assertNotIn("shell", options)
        self.assertIsInstance(argv, list)
        self.assertNotIn(self.password, " ".join(argv))
        self.assertNotIn("OPEN_SHELF_DB_PASSWORD", options.get("env", {}))
        payload = options.get("input")
        self.assertTrue(payload is None or isinstance(payload, bytes))
        output = b""
        if "inspect" in argv:
            output = json.dumps([{"State": {"Status": "running"}, "Config": {
                "Labels": {self.settings.label_key: self.settings.label_value}}}]).encode()
        elif payload and b"SELECT 'PDB_READY=" in payload:
            output = oracle.READY_MARKER.encode()
        elif payload and b"CONNECT " in payload:
            output = ("café execution\nOPEN_SHELF_BUILD=PASS\nRUNTIME_CHECKS=PASS\n"
                      "OPEN_SHELF_DEMO=PASS\nOPEN_SHELF_RESET=PASS\n").encode("utf-8")
        return subprocess.CompletedProcess(argv, 0, output)

    def test_archive_is_posix_and_sql_only(self):
        launcher = self.make_launcher()
        with tarfile.open(fileobj=io.BytesIO(launcher.archive())) as archive:
            names = archive.getnames()
            self.assertEqual(len(names), 7)
            self.assertIn("db/00_build.sql", names)
            self.assertIn("tests/01_assertions.sql", names)
            self.assertTrue(all("\\" not in name and not name.startswith("/") for name in names))
            self.assertNotIn(".env", names)
            self.assertTrue(all(item.isfile() and item.mode == 0o644 for item in archive.getmembers()))
            self.assertEqual(archive.extractfile("db/00_build.sql").read(), b"PROMPT fixture caf\xc3\xa9\n")

    def test_setup_uses_bytes_and_no_password_in_argv_or_engine_env(self):
        launcher = self.make_launcher()
        with patch.object(oracle.subprocess, "run", side_effect=self.fake_engine), contextlib.redirect_stdout(self.output):
            launcher.run("setup")
        payloads = [options["input"] for _, options in self.calls if options.get("input")]
        self.assertTrue(any(b"CREATE USER OPEN_SHELF_BOOKS" in value for value in payloads))
        self.assertTrue(any(b'@"db/00_build.sql"' in value for value in payloads))
        self.assertIn("OPEN_SHELF_BUILD=PASS", self.output.getvalue())
        self.assertTrue(all(argv[0] == self.engine for argv, _ in self.calls))

    def test_sp2_failure_and_redaction(self):
        launcher = self.make_launcher()
        launcher.password = self.password
        completed = subprocess.CompletedProcess([], 0,
            ("SP2-0310: unable to open input file\n" + self.password).encode())
        with contextlib.redirect_stdout(self.output), self.assertRaises(oracle.LauncherError):
            launcher.checked(completed, sql=True)
        self.assertNotIn(self.password, self.output.getvalue())
        self.assertIn("[REDACTED]", self.output.getvalue())

    def test_missing_success_marker_fails(self):
        launcher = self.make_launcher()
        with contextlib.redirect_stdout(self.output), self.assertRaises(oracle.LauncherError):
            launcher.checked(subprocess.CompletedProcess([], 0, b"no result"), sql=True, markers=["PASS"])

    def test_foreign_container_cannot_be_started_or_stopped(self):
        launcher = self.make_launcher()
        for command in ("start", "stop"):
            with patch.object(launcher, "inspect", return_value={"Config": {"Labels": {}}}), \
                 patch.object(launcher, "engine_run") as runner, self.assertRaises(oracle.LauncherError):
                launcher.run(command)
            runner.assert_not_called()

    def test_new_container_uses_named_volume_no_host_mount_or_port(self):
        launcher = self.make_launcher()
        with patch.object(launcher, "inspect", return_value=None), \
             patch.object(launcher, "readiness", return_value=True), \
             patch.object(oracle.subprocess, "run", side_effect=self.fake_engine), \
             contextlib.redirect_stdout(self.output):
            launcher.start()
        argv = self.calls[0][0]
        self.assertEqual(argv[argv.index("--volume") + 1], "open-shelf-books-oracle-data:/opt/oracle/oradata")
        self.assertNotIn("-p", argv)
        self.assertIn(oracle.IMAGE, argv)

    def test_invalid_schema_and_password_never_reach_engine(self):
        for schema in ("SYS", "OPEN_SHELF_BOOKS';DROP USER SYS", "OPEN_SHELF_BOOKS_bad"):
            with self.assertRaises(oracle.LauncherError):
                self.make_launcher(environment=self.environment | {"OPEN_SHELF_SCHEMA": schema})
        launcher = self.make_launcher()
        launcher.password = "validPrefix_123'INVALID"
        with patch.object(launcher, "admin") as runner, self.assertRaises(oracle.LauncherError):
            launcher.bootstrap()
        runner.assert_not_called()

    def test_reset_requires_confirmation_before_engine_mutation(self):
        launcher = self.make_launcher()
        with patch.object(launcher, "engine_run") as runner, self.assertRaises(oracle.LauncherError):
            launcher.run("reset")
        runner.assert_not_called()
        with patch.object(oracle.subprocess, "run", side_effect=self.fake_engine), contextlib.redirect_stdout(self.output):
            launcher.run("reset", confirmed=True)
        self.assertIn("OPEN_SHELF_RESET=PASS", self.output.getvalue())

    def test_profile_and_localization(self):
        profile = {"env_prefix": "EXAMPLE_LIB", "schema_prefix": "EXAMPLE_LIB", "default_schema": "EXAMPLE_LIB_SIM",
            "container": "coursework-oracle", "workdir": "/tmp/coursework",
            "markers": {"concurrency": ["EXAMPLE_CONC_ALL_PASS"]},
            "messages": {"Container {container}: {state}": "Container status {container}:{state}"}}
        (self.root / "oracle.json").write_text(json.dumps(profile), encoding="utf-8-sig")
        settings = oracle.Settings.load(self.root)
        launcher = self.make_launcher(settings=settings, environment={"PATH": "/mock/bin"})
        self.assertEqual(launcher.schema, "EXAMPLE_LIB_SIM")
        self.assertEqual(launcher.container, "coursework-oracle")
        self.assertEqual(settings.markers["concurrency"], ["EXAMPLE_CONC_ALL_PASS"])
        self.assertEqual(settings.markers["build"], ["OPEN_SHELF_BUILD=PASS"])
        self.assertEqual(launcher.message("Container {container}: {state}", container="x", state="running"), "Container status x:running")

    def test_path_escape_and_symlink_refused(self):
        for path in ("../secret.sql", "/absolute.sql", "C:/secret.sql", 'db/a"\nPROMPT hack.sql'):
            with self.assertRaises(oracle.LauncherError):
                oracle.relative_file(path)
        external = Path(self.temporary.name) / "external.sql"
        external.write_text("PRIVATE")
        try:
            (self.root / "db" / "external.sql").symlink_to(external)
        except (OSError, NotImplementedError):
            self.skipTest("Creating symbolic links is unavailable on this host.")
        with self.assertRaises(oracle.LauncherError):
            self.make_launcher().archive()

    def test_sql_file_accepts_utf8_bom_without_using_stdin(self):
        query = self.root / "query with spaces.sql"
        query.write_bytes("PROMPT café\r\nSELECT 1 FROM dual;\r\n".encode("utf-8-sig"))
        with patch.object(oracle.Settings, "load", return_value=self.settings), \
             patch.object(oracle.shutil, "which", return_value=self.engine), \
             patch.dict(oracle.os.environ, self.environment, clear=True), \
             patch.object(oracle.subprocess, "run", side_effect=self.fake_engine), \
             patch.object(oracle.sys, "stdin", None), contextlib.redirect_stdout(self.output):
            result = oracle.main(["sql", "--file", str(query)])
        self.assertEqual(result, 0)
        payload = self.calls[-1][1]["input"]
        self.assertIn("PROMPT café".encode(), payload)
        self.assertNotIn(b"\xef\xbb\xbf", payload)
        self.assertNotIn(b"\r", payload)

    def test_concurrency_uses_python_and_utf8_env(self):
        launcher = self.make_launcher()
        launcher.ask_password()
        completed = subprocess.CompletedProcess([], 0, b"OSB_CONC_ALL_PASS\n")
        with patch.object(oracle.subprocess, "run", return_value=completed) as runner, contextlib.redirect_stdout(self.output):
            launcher.concurrency()
        argv = runner.call_args.args[0]
        environment = runner.call_args.kwargs["env"]
        self.assertEqual(argv[0], sys.executable)
        self.assertEqual(argv[2], sys.executable)
        self.assertEqual(argv[-1], "sql")
        self.assertNotIn(self.password, " ".join(argv))
        self.assertEqual(environment["OPEN_SHELF_DB_PASSWORD"], self.password)
        self.assertEqual(environment["PYTHONIOENCODING"], "utf-8")
        self.assertEqual(environment["PYTHONUTF8"], "1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
