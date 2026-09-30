#!/usr/bin/env bash
# Cross-platform determinism check for Daily Drive (WP8.4, gate M8; docs/DAILY.md →
# Determinism check): the same scripted Daily run natively (Linux headless) and in the web
# build (wasm, headless Chromium), a trace hash per simulated second from each, compared.
#
#   tools/determinism/compare.sh [--date=2026-09-30] [--seconds=60] [--driver=script|bot]
#                                [--no-export] [--detail] [--out=tests/out/determinism]
#
# --no-export reuses build/web (else tools/export_web.sh runs first). --detail: when the
# traces diverge, both runs go again with per-tick lines for the first diverging second.
# Needs `npm ci` in tools/web_smoke once and a Chromium (see tools/web_smoke/smoke.mjs).
# Exit: 0 identical, 1 diverged, 2 a run failed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

date="2026-09-30"
seconds=60
export_web=1
detail=0
driver="script"
out="$root/tests/out/determinism"
for a in "$@"; do
  case "$a" in
    --date=*) date="${a#--date=}" ;;
    --seconds=*) seconds="${a#--seconds=}" ;;
    --driver=*) driver="${a#--driver=}" ;;
    --no-export) export_web=0 ;;
    --detail) detail=1 ;;
    --out=*) out="$(realpath -m "${a#--out=}")" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "compare.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done
out="$out/$driver"
mkdir -p "$out"
mkdir -p "$root/tests/out" && : >"$root/tests/out/.gdignore"

native() {  # $1 = log, $2 = extra args
  echo "compare.sh: native run ($seconds s, $date, $driver)..." >&2
  nice tools/godot.sh --headless --path . --script res://tools/determinism/daily_trace.gd -- \
    --date="$date" --seconds="$seconds" --driver="$driver" --out="$1" $2 >/dev/null 2>"$1.stderr" || {
      cat "$1.stderr" >&2; echo "compare.sh: native run failed" >&2; exit 2; }
}

web() {  # $1 = log, $2 = extra query
  echo "compare.sh: web run ($seconds s, $date, $driver)..." >&2
  nice node tools/web_smoke/smoke.mjs --query "determinism=daily&date=$date&seconds=$seconds&driver=$driver$2" \
    --wait-for "^DT done" --settle 5000 --screenshot "$out/web.png" --console-out "$1" \
    >"$1.smoke" 2>&1 || { tail -20 "$1.smoke" >&2; echo "compare.sh: web run failed" >&2; exit 2; }
}

if [[ $export_web -eq 1 ]]; then
  tools/export_web.sh >&2
fi
native "$out/native.log" ""
web "$out/web.log" ""
set +e
node tools/determinism/compare.mjs "$out/native.log" "$out/web.log" | tee "$out/compare.txt"
status=${PIPESTATUS[0]}
set -e
if [[ $status -eq 1 && $detail -eq 1 ]]; then
  sec="$(grep -o 'first divergence: *second [0-9]*' "$out/compare.txt" | grep -o '[0-9]*$')"
  if [[ -n "$sec" ]]; then
    echo "compare.sh: per-tick detail of second $sec..." >&2
    native "$out/native_detail.log" "--detail=$sec"
    web "$out/web_detail.log" "&detail=$sec"
    node tools/determinism/compare.mjs "$out/native_detail.log" "$out/web_detail.log" | tee "$out/compare_detail.txt" || true
  fi
fi
exit "$status"
