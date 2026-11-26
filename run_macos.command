#!/bin/bash
set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
project_python=''
for candidate in "${OPEN_SHELF_PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
    "$(command -v python3 2>/dev/null)" \
    "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && \
        "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3,10))' >/dev/null 2>&1; then
        project_python=$candidate
        break
    fi
done
if [ -n "$project_python" ]; then
    "$project_python" -X utf8 scripts/start_project.py --demo "$@"
    result=$?
else
    printf '%s\n' 'Install Python 3.10 or newer, then open this file again. See docs/setup.md.'
    result=1
fi
if [ -t 0 ]; then
    printf '\nPress Return to close this window.\n'
    IFS= read -r answer
fi
exit "$result"
