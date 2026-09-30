#!/usr/bin/env bash
# Renderer parity check (spec rule: every shader looks the same on Mobile and
# Compatibility). Snaps a scene on both renderers with tools/snap.sh and compares
# each Compatibility image with its Mobile twin.
#   tools/parity.sh <scene.tscn> [--max=N] [--mean=X] [--keep] [snap.sh options ...]
#   tools/parity.sh src/sun/dev/look_preview.tscn --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.66,0.85
# Metrics (per-channel difference, 0..255; see tools/parity/parity_diff.gd): edge-
# tolerant max / p99.9 / p99 of each pixel's largest channel difference, the plain
# mean, and the plain max. --max bounds p99.9 (default 12: sub-pixel thin geometry
# rasterizes differently on llvmpipe and lavapipe); --mean bounds the mean (default
# 2.0: Mobile's 10-bit linear buffer bands darks differently from 8-bit sRGB).
# A color-space bug scores ~50-70 on both. --keep writes the images and x16 diff
# images to tests/out/parity/. Prints "PARITY <image> ... ok|FAIL" per pair.
# Exit 0 = all pairs within limits, 1 = a pair failed or a snap failed, 2 = bad arguments.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

max=12
mean=2.0
keep=0
snap_args=()
for a in "$@"; do
  case "$a" in
    --max=*) max="${a#--max=}" ;;
    --mean=*) mean="${a#--mean=}" ;;
    --keep) keep=1 ;;
    --renderer=*|--out=*) echo "parity.sh: $a is set by parity.sh" >&2; exit 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) snap_args+=("$a") ;;
  esac
done
[[ ${#snap_args[@]} -gt 0 ]] || { echo "usage: tools/parity.sh <scene.tscn> [options]" >&2; exit 2; }

if [[ $keep -eq 1 ]]; then
  out="$root/tests/out/parity"
  rm -rf "$out"; mkdir -p "$out"
else
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi

snap_log="$out/snap.log"
if ! "$root/tools/snap.sh" "${snap_args[@]}" --renderer=both --out="$out" >/dev/null 2>"$snap_log"; then
  cat "$snap_log" >&2; echo "parity.sh: snap failed" >&2; exit 1
fi
# Engine and script errors always surface (snap's own "snap:" notes do not).
grep -E 'ERROR|WARNING|^ +at: ' "$snap_log" >&2 || true
[[ $keep -eq 1 ]] || rm -f "$snap_log"

pairs=()
shopt -s nullglob
for m in "$out"/*.png; do
  base="$(basename "$m")"
  [[ "$base" == *_mobile* ]] || continue
  c="$out/${base/_mobile/}"
  [[ -f "$c" ]] || { echo "parity.sh: no Compatibility twin for $base" >&2; exit 1; }
  pairs+=("$c" "$m")
done
[[ ${#pairs[@]} -gt 0 ]] || { echo "parity.sh: no image pairs produced" >&2; exit 1; }

diff_args=()
[[ $keep -eq 1 ]] && diff_args+=("--diff-dir=$out")
log="$out/parity.log"
status=0
"$root/tools/godot.sh" --headless --path "$root" --script res://tools/parity/parity_diff.gd -- \
  --max="$max" --mean="$mean" "${diff_args[@]}" "${pairs[@]}" >"$log" 2>&1 || status=$?
grep -E '^(PARITY|parity_diff)' "$log" || cat "$log" >&2
[[ $keep -eq 1 ]] || rm -f "$log"
exit "$status"
