#!/usr/bin/env bash
# Build the headless replay verifier (WP N8.2; docs/DETERMINISM.md → Verifier deploy) into
# build/verifier/: the Godot Linux x86_64 release template as `westbound` and this build's
# game pack as `<client_build>.pck` (NetTuning.client_build, the `{build}` placeholder of
# the server's verifier command), exported with the "Verifier (Linux headless)" preset
# (every game resource plus tools/verifier/, no tests, docs or dev tools). Then, unless
# --no-smoke, it records a sample replay with the editor binary and verifies it with the
# exported binary and pack exactly as the server's worker will (exit 0 = accepted).
# build/verifier/ is also the Docker build context of westbound-server/verifier/Dockerfile.
#
#   tools/verifier/export_verifier.sh [--no-smoke] [--seconds=20]
#   docker build -f westbound-server/verifier/Dockerfile -t westbound-verifier build/verifier
#
# Needs the Linux export templates (tools/export_templates.sh --all).
set -euo pipefail
cd "$(dirname "$0")/../.."

smoke=1
seconds=20
for a in "$@"; do
  case "$a" in
    --no-smoke) smoke=0 ;;
    --seconds=*) seconds="${a#--seconds=}" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "export_verifier.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

preset="Verifier (Linux headless)"
out_dir="build/verifier"
build="$(sed -n 's/^client_build = \([0-9][0-9]*\)$/\1/p' data/tuning/net.tres)"
[[ -n "$build" ]] || { echo "export_verifier.sh: no client_build in data/tuning/net.tres" >&2; exit 2; }
templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/4.7.stable"
[[ -f "$templates/linux_release.x86_64" ]] || tools/export_templates.sh --all

mkdir -p build
[[ -f build/.gdignore ]] || : >build/.gdignore
rm -rf "$out_dir"
mkdir -p "$out_dir"
{
  echo "[build]"
  echo "commit=\"$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD 2>/dev/null || echo +dirty)\""
  echo "date=\"$(date -u +%Y-%m-%dT%H:%MZ)\""
} > build_info.cfg

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
tools/godot.sh --headless --path . --import >"$log" 2>&1 || { cat "$log"; exit 1; }
if ! nice tools/godot.sh --headless --path . --export-release "$preset" "$out_dir/westbound" >"$log" 2>&1; then
  cat "$log"; echo "export_verifier.sh: export failed" >&2; exit 1
fi
[[ -f "$out_dir/westbound" && -f "$out_dir/westbound.pck" ]] || {
  cat "$log"; echo "export_verifier.sh: no binary / pack in $out_dir" >&2; exit 1; }
mv "$out_dir/westbound.pck" "$out_dir/$build.pck"
chmod +x "$out_dir/westbound"
echo "export_verifier.sh: $out_dir/westbound + $out_dir/$build.pck ($(du -h "$out_dir/$build.pck" | cut -f1))" >&2

if [[ $smoke -eq 1 ]]; then
  work="$(mktemp -d)"
  trap 'rm -f "$log"; rm -rf "$work"' EXIT
  nice tools/godot.sh --headless --path . --script res://tools/verifier/record_sample_replay.gd -- \
    --out="$work/sample.wbr" --claims="$work/claims.json" --seconds="$seconds" --server=off >"$log" 2>&1 || {
      cat "$log"; echo "export_verifier.sh: recording the sample replay failed" >&2; exit 1; }
  seed="$(sed -n 's/.*"seed": *"\{0,1\}\([0-9]*\).*/\1/p' "$work/claims.json")"
  score="$(sed -n 's/.*"score": *\([0-9]*\).*/\1/p' "$work/claims.json")"
  hits="$(sed -n 's/.*"hits": *\([0-9]*\).*/\1/p' "$work/claims.json")"
  # Exactly the server's command (docs/SERVER.md → Running the verifier), in a fresh HOME.
  set +e
  HOME="$work/home" nice -n 10 "$out_dir/westbound" --headless --main-pack "$out_dir/$build.pck" \
    --script res://tools/verifier/verify_replay.gd -- --server=off --replay="$work/sample.wbr" \
    --out="$work/result.json" --seed="$seed" --claimed-score="$score" --claimed-hits="$hits" >"$log" 2>&1
  status=$?
  set -e
  grep -h "^verify_replay:" "$log" >&2 || cat "$log" >&2
  if [[ $status -ne 0 ]]; then
    echo "export_verifier.sh: SMOKE FAIL (exit $status)" >&2
    exit 1
  fi
  echo "export_verifier.sh: SMOKE PASS (the exported verifier accepted a ${seconds} s replay)" >&2
fi
