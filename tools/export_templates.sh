#!/usr/bin/env bash
# Install the Godot export templates matching tools/godot.sh (4.7-stable).
#   tools/export_templates.sh          # web templates only (what CI and export_web.sh need)
#   tools/export_templates.sh --all    # every platform (iOS, Android, desktop, web)
#
# The official .tpz (~1.3 GB) is downloaded once, checked against the pinned
# SHA-512, and the needed templates are extracted into
#   ${WESTBOUND_CACHE:-~/.cache/westbound}/export_templates/4.7.stable/
# (the tpz is deleted afterwards unless WESTBOUND_KEEP_TPZ=1). They are then
# symlinked into the directory the Godot editor reads:
#   Linux: ${XDG_DATA_HOME:-~/.local/share}/godot/export_templates/4.7.stable/
#   macOS: ~/Library/Application Support/Godot/export_templates/4.7.stable/
# Override the destination with GODOT_TEMPLATES_DIR=... . Already-installed
# templates are left alone, so re-running is cheap.
set -euo pipefail

GODOT_VERSION="4.7-stable"
TEMPLATES_VERSION="4.7.stable"   # the folder name / version.txt Godot expects
TPZ_NAME="Godot_v${GODOT_VERSION}_export_templates.tpz"
TPZ_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${TPZ_NAME}"
# From the release's SHA512-SUMS.txt.
TPZ_SHA512="1035dfde4edcc2472bb0c0b9610ce3ee9302642c2b9957e9066372f9f6bb759ab250c8887551a66f0bc5f51bbd9a58bb45e33a0f29844e97615a9b1138c1120e"

mode="web"
case "${1:-}" in
  "") ;;
  --all) mode="all" ;;
  --web) mode="web" ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "export_templates.sh: unknown option '$1' (use --all or --web)" >&2; exit 2 ;;
esac

cache_root="${WESTBOUND_CACHE:-$HOME/.cache/westbound}"
cache_dir="$cache_root/export_templates/$TEMPLATES_VERSION"

if [[ -n "${GODOT_TEMPLATES_DIR:-}" ]]; then
  dest="$GODOT_TEMPLATES_DIR"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  dest="$HOME/Library/Application Support/Godot/export_templates/$TEMPLATES_VERSION"
else
  dest="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$TEMPLATES_VERSION"
fi

# Files that must exist for the chosen mode. Web export is single-threaded
# (variant/thread_support=false), which uses the web_nothreads_* templates.
web_files=(version.txt web_nothreads_release.zip web_nothreads_debug.zip)
all_marker=".westbound_all_platforms"

has_files() { # dir -> 0 if the dir holds everything this mode needs
  local dir="$1" f
  for f in "${web_files[@]}"; do [[ -f "$dir/$f" ]] || return 1; done
  [[ "$(tr -d '[:space:]' <"$dir/version.txt")" == "$TEMPLATES_VERSION" ]] || return 1
  if [[ "$mode" == "all" ]]; then
    [[ -f "$dir/$all_marker" || -f "$dir/ios.zip" && -f "$dir/android_release.apk" ]] || return 1
  fi
}

tpz_ok() { # file -> 0 if its SHA-512 matches the pinned one (Linux or macOS)
  local sum
  if command -v sha512sum >/dev/null; then sum="$(sha512sum "$1")"; else sum="$(shasum -a 512 "$1")"; fi
  [[ "${sum%% *}" == "$TPZ_SHA512" ]]
}

if has_files "$dest"; then
  echo "export_templates.sh: $TEMPLATES_VERSION templates ($mode) already installed in $dest"
  exit 0
fi

if ! has_files "$cache_dir"; then
  mkdir -p "$cache_dir"
  tpz="$cache_root/$TPZ_NAME"
  if [[ ! -f "$tpz" ]] || ! tpz_ok "$tpz"; then
    echo "export_templates.sh: downloading $TPZ_NAME (~1.3 GB)..." >&2
    progress="-sS"; [[ -t 2 ]] && progress="--progress-bar"   # quiet in CI logs
    curl -fL --retry 3 "$progress" -o "$tpz.part" "$TPZ_URL"
    mv "$tpz.part" "$tpz"
    if ! tpz_ok "$tpz"; then
      echo "export_templates.sh: SHA-512 mismatch for $tpz" >&2
      rm -f "$tpz"; exit 1
    fi
  fi
  echo "export_templates.sh: extracting ($mode) into $cache_dir" >&2
  # The tpz is a zip with every file under templates/.
  if [[ "$mode" == "all" ]]; then
    unzip -oqj "$tpz" 'templates/*' -d "$cache_dir"
    touch "$cache_dir/$all_marker"
  else
    unzip -oqj "$tpz" "${web_files[@]/#/templates/}" -d "$cache_dir"
  fi
  [[ "${WESTBOUND_KEEP_TPZ:-0}" == "1" ]] || rm -f "$tpz"
  has_files "$cache_dir" || { echo "export_templates.sh: extraction incomplete in $cache_dir" >&2; exit 1; }
fi

mkdir -p "$dest"
for f in "$cache_dir"/* "$cache_dir"/.westbound_*; do
  [[ -e "$f" ]] || continue
  ln -sfn "$f" "$dest/$(basename "$f")"
done
has_files "$dest" || { echo "export_templates.sh: install into $dest failed" >&2; exit 1; }
echo "export_templates.sh: installed $TEMPLATES_VERSION templates ($mode) into $dest"
