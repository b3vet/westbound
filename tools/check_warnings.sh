#!/usr/bin/env bash
# Fail on any GDScript warning. Headless Godot never prints warnings, so this
# temporarily writes an override.cfg raising every warning to error level, then
# loads every script under src/, tests/ and tools/ (fixtures excluded).
#   tools/check_warnings.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e override.cfg ]]; then echo "check_warnings: override.cfg already exists; refusing to overwrite" >&2; exit 2; fi
trap 'rm -f override.cfg' EXIT
tools/godot.sh --headless --path . --import </dev/null >/dev/null 2>&1
timeout 120 tools/godot.sh --headless --path . --script res://tools/check_warnings/list_warnings.gd </dev/null 2>/dev/null \
  | sed -n '/^\[debug\]/,$p' > override.cfg
log="$(mktemp)"
status=0
timeout 300 tools/godot.sh --headless --path . --script res://tools/check_warnings/load_all.gd </dev/null >"$log" 2>&1 || status=$?
[[ $status -eq 124 ]] && echo "check_warnings: timed out" >&2
grep -E "WARN-AS-ERROR|^SCRIPT ERROR|Parse Error|^ERROR|check_warnings:|   at: " "$log" | grep -v "Failed to load script" || true
rm -f "$log"
exit "$status"
