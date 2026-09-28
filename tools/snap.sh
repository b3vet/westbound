#!/usr/bin/env bash
# Screenshot a scene with the Compatibility renderer (review tooling, plan §3).
#   tools/snap.sh <scene.tscn> [--size=WxH] [--frames=N] [--seconds=S]
#                 [--sweep=key:v1,v2,...]... [--out=DIR] [--tag=NAME] [--key=value ...]
#   tools/snap.sh src/main.tscn
#   tools/snap.sh src/sun/sky_preview.tscn --sweep=sky_t:0,0.17,0.33,0.5,0.67,0.83,1
# Unreserved --key=value pairs reach the scene root's snap_setup(args: Dictionary).
# PNGs go to tests/out/snaps/ (gitignored) as <scene>[_<tag>][_<key>-<value>].png;
# their paths are printed one per line on stdout. See docs/TOOLS.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

size="1280x720"
scene=""
pass=()
for a in "$@"; do
  case "$a" in
    --size=*) size="${a#--size=}"; pass+=("$a") ;;
    --out=*) pass+=("--out=$(realpath -m "${a#--out=}")") ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) pass+=("$a") ;;
    *)
      if [[ "$a" == res://* ]]; then scene="$a"
      else
        abs="$(realpath -m "$a")"
        [[ "$abs" == "$root"/* ]] || { echo "snap.sh: scene must be inside the project: $a" >&2; exit 2; }
        scene="res://${abs#"$root"/}"
      fi
      pass+=("$scene") ;;
  esac
done
[[ -n "$scene" ]] || { echo "usage: tools/snap.sh <scene.tscn> [options]  (see docs/TOOLS.md)" >&2; exit 2; }
[[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || { echo "snap.sh: --size must be WxH, got $size" >&2; exit 2; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! "$root/tools/godot.sh" --headless --path "$root" --import >"$log" 2>&1; then
  cat "$log" >&2; echo "snap.sh: import failed" >&2; exit 1
fi

cmd=("$root/tools/godot.sh" --path "$root"
  --rendering-method gl_compatibility --rendering-driver opengl3
  --audio-driver Dummy --resolution "$size" --fixed-fps 60
  --script res://tools/snap/snap.gd -- "${pass[@]}")
if [[ -z "${DISPLAY:-}" ]]; then
  command -v xvfb-run >/dev/null || { echo "snap.sh: no \$DISPLAY and no xvfb-run" >&2; exit 1; }
  cmd=(xvfb-run -a -s "-screen 0 ${size}x24" "${cmd[@]}")
fi

status=0
"${cmd[@]}" >"$log" 2>&1 || status=$?

# Godot errors and script errors always surface; the full log only on failure.
if [[ $status -ne 0 ]]; then
  grep -v '^SNAP ' "$log" >&2 || true
  echo "snap.sh: failed (exit $status)" >&2
  exit "$status"
fi
# Xvfb/llvmpipe cannot set V-Sync; that warning (and its "at:" line) is noise.
awk '/Could not set V-Sync mode/ {skip=1; next}
     skip && /^ +at: / {skip=0; next}
     {skip=0}
     /ERROR|WARNING|^snap: |^ +at: / {print}' "$log" >&2
if ! grep -q '^SNAP ' "$log"; then
  cat "$log" >&2; echo "snap.sh: no image written" >&2; exit 1
fi
grep '^SNAP ' "$log" | cut -c6- | while read -r f; do
  if [[ "$f" == "$root"/* ]]; then echo "${f#"$root"/}"; else echo "$f"; fi
done
