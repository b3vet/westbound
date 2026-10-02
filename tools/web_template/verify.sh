#!/usr/bin/env bash
# WP9.9: does the slim web template run everything in the game's pack like the official one?
#
#   tools/web_template/verify.sh [--pck-dir build/web] [--template build/web_template/web_nothreads_release.zip]
#                                [--net http://127.0.0.1:8080]
#
# Runs tools/web_template/web_probe.gd (compile every script, load every scene, resource
# and imported file of index.pck and music/*.pck) in headless Chromium twice: on the
# official 4.7 template and on the slim one, with the same packs. Fails when the slim
# engine fails anything the official one does not (a disabled class a script or a
# resource needs). Then the names check (web_names.gd: player names with diacritics,
# Turkish casing, Thai, fallback glyphs in the game's theme): the shaped widths and the
# screenshot pixels must match. --net also checks HTTP (fetch) and a WebSocket echo
# against a local westbound-server (web_net.gd; `cargo run -p server -- --config
# config/dev.toml` in westbound-server/). Also writes tools/web_template/removed_classes.txt: the classes the
# official engine has and the slim one lacks, which `detect_classes.gd --check`
# (tools/export_web.sh, CI) compares with what the game uses from then on.
# Needs a Web export in --pck-dir (tools/export_web.sh; either template) and `npm ci`
# in tools/web_smoke. Exit 0 ok, 1 differences, 2 setup error.
set -euo pipefail
cd "$(dirname "$0")/../.."

pck_dir="build/web"
custom="build/web_template/web_nothreads_release.zip"
net=""
for a in "$@"; do
  case "$a" in
    --net=*) net="${a#--net=}" ;;
    --pck-dir=*) pck_dir="${a#--pck-dir=}" ;;
    --template=*) custom="${a#--template=}" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

tools/export_templates.sh >/dev/null
if [[ -n "${GODOT_TEMPLATES_DIR:-}" ]]; then tdir="$GODOT_TEMPLATES_DIR"
elif [[ "$(uname -s)" == "Darwin" ]]; then tdir="$HOME/Library/Application Support/Godot/export_templates/4.7.stable"
else tdir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/4.7.stable"; fi
official="$tdir/web_nothreads_release.zip"
for f in "$official" "$custom" "$pck_dir/index.pck"; do
  [[ -s "$f" ]] || { echo "verify.sh: missing $f" >&2; exit 2; }
done

work="build/web_probe"
rm -rf "$work"
mkdir -p "$work"
[[ -f build/.gdignore ]] || : >build/.gdignore
status=0
for side in official custom; do
  zip="$official"; [[ "$side" == custom ]] && zip="$custom"
  mkdir -p "$work/$side"
  unzip -q -o "$zip" -d "$work/$side"
  cp "$pck_dir/index.pck" "$work/$side/"
  [[ -d "$pck_dir/music" ]] && cp -r "$pck_dir/music" "$work/$side/"
  nice node tools/web_template/probe.mjs --dir "$work/$side" --out "$work/$side.log" || status=2
  nice node tools/web_template/probe.mjs --dir "$work/$side" --out "$work/${side}_names.log" --names \
    --screenshot "$work/${side}_names.png" || status=2
  if [[ -n "$net" ]]; then
    nice node tools/web_template/probe.mjs --dir "$work/$side" --out "$work/${side}_net.log" --net "$net" --timeout 60000 \
      && echo "verify.sh: $side engine: HTTP and WebSocket echo ok against $net" \
      || { echo "verify.sh: $side engine: HTTP/WebSocket check failed (see $work/${side}_net.log)"; status=1; }
  fi
done
[[ $status -ne 2 ]] || { echo "verify.sh: a probe did not finish (logs in $work)" >&2; exit 2; }

# Failures and engine errors, normalized (no timings or addresses), official vs slim.
# (The slim build prints engine sources as ./modules/..., the official one as modules/....)
issues() { grep -E '^PROBE fail |ERROR|console.error|pageerror' "$1" | sed -E -e 's/0x[0-9a-f]+/0x?/g' -e 's/\(\.\//(/g' | sort -u; }
issues "$work/official.log" >"$work/official.issues"
issues "$work/custom.log" >"$work/custom.issues"
classes() { grep -m1 '^PROBE classes ' "$1" | cut -d' ' -f4 | tr ',' '\n' | sort; }
classes "$work/official.log" >"$work/official.classes"
classes "$work/custom.log" >"$work/custom.classes"

echo "verify.sh: official $(grep -m1 '^PROBE done' "$work/official.log"), $(wc -l <"$work/official.classes") classes"
echo "verify.sh: slim     $(grep -m1 '^PROBE done' "$work/custom.log"), $(wc -l <"$work/custom.classes") classes"
new_issues="$(comm -13 "$work/official.issues" "$work/custom.issues")"
if [[ -n "$new_issues" ]]; then
  echo "verify.sh: the slim template fails where the official one does not:"
  echo "$new_issues" | sed 's/^/  /'
  status=1
fi
if [[ -s "$work/official.issues" ]]; then
  echo "verify.sh: both templates report ($(wc -l <"$work/official.issues") lines, see $work/official.issues):"
  head -5 "$work/official.issues" | sed 's/^/  /'
fi

if ! diff <(grep '^PROBE text ' "$work/official_names.log") <(grep '^PROBE text ' "$work/custom_names.log") >"$work/names.diff"; then
  echo "verify.sh: names shape differently (see $work/names.diff)"; status=1
elif ! cmp -s "$work/official_names.png" "$work/custom_names.png"; then
  echo "verify.sh: names render differently: compare $work/official_names.png and $work/custom_names.png"; status=1
else
  echo "verify.sh: names: same widths, same pixels ($(grep -c '^PROBE text ' "$work/custom_names.log") lines)"
fi

removed="tools/web_template/removed_classes.txt"
{
  echo "# Classes the official Godot 4.7 web template has and the slim one lacks (disabled modules,"
  echo "# features and build-profile classes). Written by tools/web_template/verify.sh; read by"
  echo "# tools/web_template/detect_classes.gd --check. Config $(tools/web_template/build.sh --hash)."
  comm -23 "$work/official.classes" "$work/custom.classes"
} >"$removed.tmp"
if cmp -s "$removed.tmp" "$removed"; then rm "$removed.tmp"; else mv "$removed.tmp" "$removed"; echo "verify.sh: updated $removed"; fi
echo "verify.sh: $(grep -vc '^#' "$removed") classes removed from the engine"
[[ $status -eq 0 ]] && echo "verify.sh: ok, the slim template loads everything the official one does"
exit "$status"
