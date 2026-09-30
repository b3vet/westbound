#!/usr/bin/env bash
# Install only the Godot Linux x86_64 debug export template (what the replay verifier's
# export needs; WP N8.3, docs/DETERMINISM.md → Verifier deploy) instead of every platform
# (tools/export_templates.sh --all extracts about 1.5 GB, iOS and Android included).
#
#   tools/verifier/install_linux_template.sh
#
# The official .tpz is the one tools/export_templates.sh pins (same URL and SHA-512, read
# from that script): downloaded once, checked, and only templates/version.txt and
# templates/linux_debug.x86_64 extracted into
#   ${WESTBOUND_CACHE:-~/.cache/westbound}/export_templates/4.7.stable/
# (the tpz is deleted afterwards unless WESTBOUND_KEEP_TPZ=1), then symlinked into the
# directory the Godot editor reads (Linux: ${XDG_DATA_HOME:-~/.local/share}/godot/
# export_templates/4.7.stable/; GODOT_TEMPLATES_DIR=... overrides). Re-running is cheap.
set -euo pipefail
cd "$(dirname "$0")/../.."

pinned="tools/export_templates.sh"
version="$(sed -n 's/^GODOT_VERSION="\(.*\)"$/\1/p' "$pinned")"
templates_version="$(sed -n 's/^TEMPLATES_VERSION="\([^"]*\)".*$/\1/p' "$pinned")"
sha="$(sed -n 's/^TPZ_SHA512="\(.*\)"$/\1/p' "$pinned")"
[[ -n "$version" && -n "$templates_version" && -n "$sha" ]] || {
  echo "install_linux_template.sh: cannot read the pinned template from $pinned" >&2; exit 2; }
tpz_name="Godot_v${version}_export_templates.tpz"
tpz_url="https://github.com/godotengine/godot/releases/download/${version}/${tpz_name}"
files=(version.txt linux_debug.x86_64)

cache_root="${WESTBOUND_CACHE:-$HOME/.cache/westbound}"
cache_dir="$cache_root/export_templates/$templates_version"
dest="${GODOT_TEMPLATES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$templates_version}"

has_files() {
  local f
  for f in "${files[@]}"; do [[ -f "$1/$f" ]] || return 1; done
  [[ "$(tr -d '[:space:]' <"$1/version.txt")" == "$templates_version" ]]
}

if has_files "$dest"; then
  echo "install_linux_template.sh: linux_debug.x86_64 ($templates_version) already in $dest"
  exit 0
fi
if ! has_files "$cache_dir"; then
  mkdir -p "$cache_dir"
  tpz="$cache_root/$tpz_name"
  if [[ ! -f "$tpz" ]] || [[ "$(sha512sum "$tpz" | cut -d' ' -f1)" != "$sha" ]]; then
    echo "install_linux_template.sh: downloading $tpz_name (~1.3 GB)..." >&2
    curl -fL --retry 3 -sS -o "$tpz.part" "$tpz_url"
    mv "$tpz.part" "$tpz"
    if [[ "$(sha512sum "$tpz" | cut -d' ' -f1)" != "$sha" ]]; then
      echo "install_linux_template.sh: SHA-512 mismatch for $tpz" >&2
      rm -f "$tpz"; exit 1
    fi
  fi
  unzip -oqj "$tpz" "${files[@]/#/templates/}" -d "$cache_dir"
  [[ "${WESTBOUND_KEEP_TPZ:-0}" == "1" ]] || rm -f "$tpz"
  chmod +x "$cache_dir/linux_debug.x86_64"
  has_files "$cache_dir" || { echo "install_linux_template.sh: extraction incomplete in $cache_dir" >&2; exit 1; }
fi
mkdir -p "$dest"
for f in "${files[@]}"; do ln -sfn "$cache_dir/$f" "$dest/$f"; done
has_files "$dest" || { echo "install_linux_template.sh: install into $dest failed" >&2; exit 1; }
echo "install_linux_template.sh: installed linux_debug.x86_64 ($templates_version) into $dest"
