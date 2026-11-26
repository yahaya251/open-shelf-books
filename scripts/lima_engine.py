#!/usr/bin/env python3
"""Docker-compatible engine adapter for the preserved, local-only Mac VM."""
from pathlib import Path
import os
import re
import sys

def main() -> int:
    root = Path(__file__).resolve().parents[1]
    local_root = Path(os.environ.get("OPEN_SHELF_RUNTIME_ROOT", str(root / ".local-macos"))).expanduser().resolve()
    binary = local_root / "10_Oracle_Runtime" / "lima" / "bin" / "limactl"
    instance = os.environ.get("OPEN_SHELF_LIMA_INSTANCE", "db")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", instance):
        print("Invalid Lima instance name.", file=sys.stderr)
        return 1
    if not binary.is_file() or not (local_root / ".vm" / instance / "lima.yaml").is_file():
        print("The local Mac runtime is unavailable; see docs/local-macos.md.", file=sys.stderr)
        return 1
    environment = dict(os.environ)
    environment["LIMA_HOME"] = str(local_root / ".vm")
    environment["LIMA_WORKDIR"] = "/tmp"
    environment["XDG_CACHE_HOME"] = str(local_root / "10_Oracle_Runtime" / "cache")
    environment.pop("OPEN_SHELF_DB_PASSWORD", None)
    os.execve(str(binary), [str(binary), "shell", instance, "sudo", "nerdctl", *sys.argv[1:]], environment)
    return 1

if __name__ == "__main__":
    sys.exit(main())
