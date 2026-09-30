#!/usr/bin/env bash
# Import the project (builds the class_name cache) and run the headless tests.
#   tools/test.sh [--tier=fast|soak|all] [--filter=substr] [--list]
set -euo pipefail
cd "$(dirname "$0")/.."

log="$(mktemp)"
if ! tools/godot.sh --headless --path . --import >"$log" 2>&1; then
  cat "$log"; echo "test.sh: import failed" >&2; exit 1
fi
rm -f "$log"
exec tools/godot.sh --headless --path . --script res://tests/run_all.gd -- "$@"
