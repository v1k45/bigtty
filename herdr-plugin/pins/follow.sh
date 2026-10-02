#!/bin/sh
# Runs on every space or tab switch; the work is in follow.py (Python 3).
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$(dirname "$0")/follow.py"
fi
echo "bigtty pins: needs python3 on this machine" >&2
exit 0
