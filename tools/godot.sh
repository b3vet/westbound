#!/usr/bin/env bash
# Run the pinned Godot binary, downloading it on first use (Linux x86_64).
# Override with GODOT=/path/to/godot (e.g. on macOS).
#   tools/godot.sh --version
#   tools/godot.sh --headless --path . --script res://tests/run_all.gd
set -euo pipefail

GODOT_VERSION="4.7-stable"
GODOT_CACHE="${WESTBOUND_CACHE:-$HOME/.cache/westbound}/godot"
GODOT_BIN_NAME="Godot_v${GODOT_VERSION}_linux.x86_64"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_BIN_NAME}.zip"

if [[ -n "${GODOT:-}" ]]; then
  exec "$GODOT" "$@"
fi

bin="$GODOT_CACHE/$GODOT_BIN_NAME"
if [[ ! -x "$bin" ]]; then
  mkdir -p "$GODOT_CACHE"
  echo "godot.sh: downloading Godot ${GODOT_VERSION}..." >&2
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/godot.zip" "$GODOT_URL"
  unzip -oq "$tmp/godot.zip" -d "$GODOT_CACHE"
  rm -rf "$tmp"
  chmod +x "$bin"
fi
exec "$bin" "$@"
