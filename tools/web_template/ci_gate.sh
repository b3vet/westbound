#!/usr/bin/env bash
# WP9.9 CI gate for the slim web engine (.github/workflows/web.yml, docs/WEB.md → Slim engine).
#
#   tools/web_template/ci_gate.sh
#
# Run after tools/export_web.sh and the smoke deps. When the export used the slim
# template, checks it: the probe (tools/web_template/verify.sh: every script and resource
# of the pack loads as on the official engine), a default smoke run (boot to the title)
# and a 60 s Daily Drive determinism compare (native vs wasm, IDENTICAL). If any fails,
# re-exports with the official template, so a slim-engine problem never blocks a deploy
# (the workflow's own smoke steps then run on whatever was exported). Always exits 0
# unless the fallback export itself fails. Writes `engine=slim|official` to
# $GITHUB_OUTPUT and a line to $GITHUB_STEP_SUMMARY when set.
set -euo pipefail
cd "$(dirname "$0")/../.."

engine_file="build/web_template/selected/ENGINE"
engine="$(cat "$engine_file" 2>/dev/null || echo unknown)"
summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$1" >>"$GITHUB_STEP_SUMMARY"; echo "ci_gate.sh: $1"; }
output() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "engine=$1" >>"$GITHUB_OUTPUT"; return 0; }

if [[ "$engine" != slim* ]]; then
  summary "Web engine: $engine"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::notice title=Web engine::$engine"
  output official
  exit 0
fi

failed=""
tools/web_template/verify.sh || failed="probe (verify.sh)"
if [[ -z "$failed" ]]; then
  node tools/web_smoke/smoke.mjs --timeout 90000 --settle 6000 --screenshot build/web_smoke_slim.png || failed="default smoke"
fi
if [[ -z "$failed" ]]; then
  tools/determinism/compare.sh --seconds=60 --no-export --out=tests/out/determinism_slim || failed="determinism compare"
fi

if [[ -z "$failed" ]]; then
  summary "Web engine: $engine; probe, smoke and determinism passed"
  output slim
  exit 0
fi
summary "Web engine: slim template failed the $failed; deploying the official engine"
[[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::warning title=Slim web engine::failed the $failed; exported with the official template instead"
tools/export_web.sh --template=official
output official
