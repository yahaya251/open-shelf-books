#!/bin/sh
# Compatibility entry point for macOS and other POSIX shells.
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/oracle.py" "$@"
