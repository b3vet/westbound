#!/usr/bin/env bash
# Build the headless replay verifier (WP N8.2; docs/DETERMINISM.md → Verifier deploy) into
# build/verifier/<client_build>/: the Godot Linux x86_64 **debug** template as `westbound`
# and the game pack next to it as `westbound.pck` (loaded automatically), exported with
# the "Verifier (Linux headless)" preset (every game resource plus tools/verifier/, no
# tests, docs or dev tools). <client_build> is NetTuning.client_build, the `{build}`
# placeholder of the server's verifier command. Export templates ignore `--script` and
# `--main-pack`, so the verifier runs through the game's main scene: `-- --verifier=1`
# (Run._ready hands over to tools/verifier/verify_replay_main.gd). The debug template,
# because the 4.7 release template crashes (SIGSEGV) booting this project headless.
# Then, unless --no-smoke, it records a sample replay with the editor binary and verifies
# it with the exported binary exactly as the server's worker will (exit 0 = accepted).
# build/verifier/ is the Docker build context of westbound-server/verifier/Dockerfile.
#
#   tools/verifier/export_verifier.sh [--no-smoke] [--seconds=20] [--keep-sample=DIR]
#   docker build -f westbound-server/verifier/Dockerfile -t westbound-verifier build/verifier
#
# --keep-sample=DIR keeps the smoke test's replay and claims (DIR/sample.wbr,
# DIR/claims.json) for the image's own smoke test (tools/verifier/smoke_image.py).
# Needs the Linux debug export template (installed by tools/verifier/install_linux_template.sh
# when missing). N8.3: .github/workflows/verifier.yml runs this in CI.
set -euo pipefail
cd "$(dirname "$0")/../.."

smoke=1
seconds=20
keep_sample=""
for a in "$@"; do
  case "$a" in
    --no-smoke) smoke=0 ;;
    --seconds=*) seconds="${a#--seconds=}" ;;
    --keep-sample=*) keep_sample="${a#--keep-sample=}" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "export_verifier.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

preset="Verifier (Linux headless)"
out_dir="build/verifier"
build="$(sed -n 's/^client_build = \([0-9][0-9]*\)$/\1/p' data/tuning/net.tres)"
[[ -n "$build" ]] || { echo "export_verifier.sh: no client_build in data/tuning/net.tres" >&2; exit 2; }
templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/4.7.stable"
[[ -f "$templates/linux_debug.x86_64" ]] || tools/verifier/install_linux_template.sh

mkdir -p build
[[ -f build/.gdignore ]] || : >build/.gdignore
rm -rf "$out_dir"
mkdir -p "$out_dir/$build"
{
  echo "[build]"
  echo "commit=\"$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD 2>/dev/null || echo +dirty)\""
  echo "date=\"$(date -u +%Y-%m-%dT%H:%MZ)\""
} > build_info.cfg

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
tools/godot.sh --headless --path . --import >"$log" 2>&1 || { cat "$log"; exit 1; }
bin="$out_dir/$build/westbound"
if ! nice tools/godot.sh --headless --path . --export-debug "$preset" "$bin" >"$log" 2>&1; then
  cat "$log"; echo "export_verifier.sh: export failed" >&2; exit 1
fi
[[ -f "$bin" && -f "$bin.pck" ]] || { cat "$log"; echo "export_verifier.sh: no binary / pack in $out_dir/$build" >&2; exit 1; }
chmod +x "$bin"
cp build_info.cfg "$out_dir/$build/build_info.cfg"   # which commit this build's pack is
echo "export_verifier.sh: $bin + $bin.pck ($(du -h "$bin.pck" | cut -f1))" >&2

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
  HOME="$work/home" nice -n 10 "$bin" --headless -- --verifier=1 --server=off --replay="$work/sample.wbr" \
    --out="$work/result.json" --seed="$seed" --claimed-score="$score" --claimed-hits="$hits" \
    --require-inputs=1 >"$log" 2>&1
  status=$?
  set -e
  grep -h "^verify_replay:" "$log" >&2 || cat "$log" >&2
  if [[ $status -ne 0 ]]; then
    echo "export_verifier.sh: SMOKE FAIL (exit $status)" >&2
    exit 1
  fi
  echo "export_verifier.sh: SMOKE PASS (the exported verifier accepted a ${seconds} s replay)" >&2
  if [[ -n "$keep_sample" ]]; then
    mkdir -p "$keep_sample"
    cp "$work/sample.wbr" "$work/claims.json" "$keep_sample/"
    echo "export_verifier.sh: sample replay and claims kept in $keep_sample" >&2
  fi
fi
