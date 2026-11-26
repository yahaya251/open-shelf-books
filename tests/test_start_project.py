"""Startup tests use mocks and temporary files, never Oracle or a host VM."""
from pathlib import Path
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import start_project as startup
import lima_engine
from oracle import LauncherError


def database_state(objects=40, tables=11, expected=11, invalid=0, errors=0):
    return (f"OSB_OBJECTS={objects}\nOSB_TABLES={tables}\nOSB_PROJECT_TABLES={expected}\n"
            f"OSB_INVALID={invalid}\nOSB_ERRORS={errors}\n")


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="open-shelf-start-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source with spaces"
        self.root.mkdir()
        self.output = io.StringIO()

    def launcher(self, exists=1, state=None):
        launcher = MagicMock()
        launcher.schema = "OPEN_SHELF_BOOKS"
        launcher.checked.return_value = f"OSB_SCHEMA_EXISTS={exists}\n"
        launcher.app_sql.return_value = state or database_state()
        return launcher

    def test_existing_schema_is_not_rebuilt(self):
        launcher = self.launcher()
        with contextlib.redirect_stdout(self.output):
            self.assertFalse(startup.prepare_schema(launcher))
        launcher.bootstrap.assert_not_called()
        launcher.sql_scripts.assert_not_called()

    def test_missing_schema_is_built_once(self):
        launcher = self.launcher(exists=0)
        with contextlib.redirect_stdout(self.output):
            self.assertTrue(startup.prepare_schema(launcher))
        launcher.bootstrap.assert_called_once()
        launcher.sql_scripts.assert_called_once_with("build")

    def test_existing_empty_schema_is_built_without_account_recreation(self):
        launcher = self.launcher(state=database_state(objects=0, tables=0, expected=0))
        with contextlib.redirect_stdout(self.output):
            self.assertTrue(startup.prepare_schema(launcher))
        launcher.bootstrap.assert_not_called()
        launcher.sql_scripts.assert_called_once_with("build")

    def test_partial_schema_is_retained_and_fails(self):
        launcher = self.launcher(state=database_state(tables=4, expected=4))
        with self.assertRaises(LauncherError):
            startup.prepare_schema(launcher)
        launcher.bootstrap.assert_not_called()
        launcher.sql_scripts.assert_not_called()

    def test_auto_does_not_select_legacy_assets_over_working_podman(self):
        (self.root / ".local-macos/.vm/db").mkdir(parents=True)
        (self.root / ".local-macos/.vm/db/lima.yaml").write_text("old assets")
        def which(name, **kwargs): return "/mock/" + name
        def run(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0 if "podman" in argv[0] else 1)
        with patch.object(startup.shutil, "which", side_effect=which), patch.object(startup.subprocess, "run", side_effect=run):
            backend, local = startup.select_backend(self.root, "auto", {}, {"PATH":"/mock"})
        self.assertEqual(backend, "podman")
        self.assertIsNone(local)

    def test_private_configuration_never_accepts_password(self):
        (self.root / ".local").mkdir()
        (self.root / ".local/runtime.json").write_text(json.dumps({"password":"not allowed"}))
        with self.assertRaises(LauncherError): startup.local_configuration(self.root)

    def test_status_does_not_start_or_prepare(self):
        args = startup.argparse.Namespace(backend="auto",status=True,stop=False)
        launcher = self.launcher()
        with patch.object(startup, "select_backend", return_value=("docker",None)), \
             patch.object(startup, "OracleLauncher", return_value=launcher), \
             patch.object(startup, "prepare_schema") as prepare, \
             contextlib.redirect_stdout(self.output):
            startup.start(args, root=self.root)
        launcher.status.assert_called_once()
        launcher.start.assert_not_called()
        prepare.assert_not_called()

    def test_shared_stop_is_refused_without_runtime_action(self):
        args = startup.argparse.Namespace(backend="lima",status=False,stop=True)
        launcher = self.launcher()
        with patch.object(startup, "select_backend", return_value=("lima",self.root)), \
             patch.object(startup, "OracleLauncher", return_value=launcher), \
             contextlib.redirect_stdout(self.output), self.assertRaises(LauncherError):
            startup.start(args, root=self.root)
        launcher.run.assert_not_called()
        launcher.start.assert_not_called()

    def test_lima_adapter_uses_new_home_and_no_password(self):
        runtime = self.root / "local runtime"
        binary = runtime / "10_Oracle_Runtime/lima/bin/limactl"
        binary.parent.mkdir(parents=True)
        binary.write_text("mock")
        (runtime / ".vm/db").mkdir(parents=True)
        (runtime / ".vm/db/lima.yaml").write_text("mock")
        with patch.dict(os.environ,{"OPEN_SHELF_RUNTIME_ROOT":str(runtime),"OPEN_SHELF_DB_PASSWORD":"private"}), \
             patch.object(sys,"argv",["lima_engine.py","exec","-i","container","sqlplus"]), \
             patch.object(os,"execve",side_effect=RuntimeError("captured")) as execute:
            with self.assertRaisesRegex(RuntimeError,"captured"): lima_engine.main()
        executable, argv, env = execute.call_args.args
        self.assertEqual(Path(executable).resolve(),binary.resolve())
        self.assertEqual(argv[1:5],["shell","db","sudo","nerdctl"])
        self.assertEqual(Path(env["LIMA_HOME"]).resolve(),(runtime / ".vm").resolve())
        self.assertNotIn("OPEN_SHELF_DB_PASSWORD",env)


if __name__ == "__main__":
    unittest.main(verbosity=2)
