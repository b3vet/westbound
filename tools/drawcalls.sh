#!/usr/bin/env bash
# Draw-call measurement (plan WP4.6; spec Performance budget: <= 100 draw calls in
# gameplay). Renders a scene like tools/snap.sh (Compatibility renderer under Xvfb /
# Mesa llvmpipe, --fixed-fps 60) and prints the engine's draw calls, objects and
# primitives per frame: total, 3D only (CanvasLayers hidden), the canvas share, and
# each top-level 3D child's share.
#   tools/drawcalls.sh <scene.tscn> [--renderer=compat|mobile] [--size=WxH] [--frames=N]
#                      [--sample=N] [--set=prop:value]... [--no-breakdown] [--key=value ...]
#   tools/drawcalls.sh src/dev/car_drive.tscn --cam=hood --set=_leg:8 --s=3000
# --frames: warm-up frames after snap_setup (default 180), --sample: frames averaged
# per measurement (default 60), --set: a property on the scene root before
# snap_setup, other --key=value pairs go to the scene's snap_setup(args).
# Default size 1361x720: the owner's iPhone canvas (2496x1320 screen). See docs/TOOLS.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

size="1361x720"
scene=""
renderer="compat"
pass=()
for a in "$@"; do
  case "$a" in
    --renderer=*) renderer="${a#--renderer=}" ;;
    --size=*) size="${a#--size=}" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) pass+=("$a") ;;
    *)
      if [[ "$a" == res://* ]]; then scene="$a"
      else
        abs="$(realpath -m "$a")"
        [[ "$abs" == "$root"/* ]] || { echo "drawcalls.sh: scene must be inside the project: $a" >&2; exit 2; }
        scene="res://${abs#"$root"/}"
      fi
      pass+=("$scene") ;;
  esac
done
[[ -n "$scene" ]] || { echo "usage: tools/drawcalls.sh <scene.tscn> [options]  (see docs/TOOLS.md)" >&2; exit 2; }
[[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || { echo "drawcalls.sh: --size must be WxH, got $size" >&2; exit 2; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if ! "$root/tools/godot.sh" --headless --path "$root" --import >"$log" 2>&1; then
  cat "$log" >&2; echo "drawcalls.sh: import failed" >&2; exit 1
fi

cmd=("$root/tools/godot.sh" --path "$root")
env_prefix=()
case "$renderer" in
  compat) cmd+=(--rendering-method gl_compatibility --rendering-driver opengl3) ;;
  mobile)
    lvp_icd="${WB_LVP_ICD:-/usr/share/vulkan/icd.d/lvp_icd.json}"
    [[ -f "$lvp_icd" ]] || { echo "drawcalls.sh: Mobile renderer needs Mesa lavapipe: apt-get install -y mesa-vulkan-drivers" >&2; exit 1; }
    cmd+=(--rendering-method mobile --rendering-driver vulkan)
    env_prefix=(env "VK_ICD_FILENAMES=$lvp_icd") ;;
  *) echo "drawcalls.sh: --renderer must be compat or mobile, got $renderer" >&2; exit 2 ;;
esac
cmd+=(--audio-driver Dummy --resolution "$size" --fixed-fps 60
  --script res://tools/drawcalls/drawcalls.gd -- "${pass[@]}")
if [[ -z "${DISPLAY:-}" ]]; then
  command -v xvfb-run >/dev/null || { echo "drawcalls.sh: no \$DISPLAY and no xvfb-run" >&2; exit 1; }
  cmd=(xvfb-run -a -s "-screen 0 ${size}x24" "${cmd[@]}")
fi

status=0
"${env_prefix[@]}" "${cmd[@]}" >"$log" 2>&1 || status=$?
if [[ $status -ne 0 ]] || ! grep -q '^DRAWCALLS ' "$log"; then
  cat "$log" >&2; echo "drawcalls.sh: failed (exit $status)" >&2; exit $(( status == 0 ? 1 : status ))
fi
awk '/Could not set V-Sync mode/ {skip=1; next}
     skip && /^ +at: / {skip=0; next}
     {skip=0}
     /leaked|still in use|never freed|Pages in use|ObjectDB instances/ {skip=1; next}
     /ERROR|WARNING|SCRIPT ERROR|^drawcalls: / {print}' "$log" >&2
grep '^DRAWCALLS ' "$log" | cut -c11-
