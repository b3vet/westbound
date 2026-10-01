#!/usr/bin/env bash
# Build the Web export (Compatibility renderer, single-threaded) into build/web/.
#   tools/export_web.sh            # release build
#   tools/export_web.sh --debug    # debug build (debug template, verbose engine errors)
#   --template=auto|slim|official  (or WB_WEB_TEMPLATE=...) which engine template (WP9.9):
#     auto (default): the slim one (tools/web_template/build.sh) when it is built for the
#     current config and has every class the game uses, else the official one (with a note);
#     slim: fail instead of falling back; official: Godot's own; a .zip path: that
#     template as is (experiments; no checks).
# Installs the export templates on first use (tools/export_templates.sh).
# Writes build/web/version.json and fills the custom shell's tokens (docs/WEB.md).
# Then smoke-test it with:  node tools/web_smoke/smoke.mjs
set -euo pipefail
cd "$(dirname "$0")/.."

mode="release"
template="${WB_WEB_TEMPLATE:-auto}"
for a in "$@"; do
  case "$a" in
    --release) mode="release" ;;
    --debug) mode="debug" ;;
    --template=*) template="${a#--template=}" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "export_web.sh: unknown option '$a' (use --debug, --release, --template=auto|slim|official)" >&2; exit 2 ;;
  esac
done
case "$template" in
  auto|slim|official) ;;
  *.zip) [[ -s "$template" ]] || { echo "export_web.sh: no template $template" >&2; exit 2; } ;;
  *) echo "export_web.sh: --template must be auto, slim, official or a .zip" >&2; exit 2 ;;
esac

out_dir="build/web"
out="$out_dir/index.html"

tools/export_templates.sh

# Keep Godot from scanning/importing build output as project resources.
mkdir -p build
[[ -f build/.gdignore ]] || : >build/.gdignore
rm -rf "$out_dir"
mkdir -p "$out_dir"

log="$(mktemp)"
trap 'rm -f "$log" "$log.raw"' EXIT

# Build stamp for the dev report (src/ui/dev_report.gd); gitignored, packed via include_filter.
{
  echo "[build]"
  echo "commit=\"$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD 2>/dev/null || echo +dirty)\""
  echo "date=\"$(date -u +%Y-%m-%dT%H:%MZ)\""
} > build_info.cfg

echo "export_web.sh: importing project..." >&2
if ! tools/godot.sh --headless --path . --import >"$log" 2>&1; then
  cat "$log"; echo "export_web.sh: import failed" >&2; exit 1
fi

# WP9.9 engine template (docs/WEB.md → Slim engine). The Web preset's custom_template
# fields point at build/web_template/selected/, filled here with the slim template (when
# built for this config and the class check passes) or the official one.
if [[ -n "${GODOT_TEMPLATES_DIR:-}" ]]; then official_dir="$GODOT_TEMPLATES_DIR"
elif [[ "$(uname -s)" == "Darwin" ]]; then official_dir="$HOME/Library/Application Support/Godot/export_templates/4.7.stable"
else official_dir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/4.7.stable"; fi
slim_dir="build/web_template"
selected="$slim_dir/selected"
use_slim=0
why=""
if [[ "$template" == *.zip ]]; then
  why="replaced by $template for this export"
elif [[ "$template" != official ]]; then
  want_hash="$(tools/web_template/build.sh --hash)"
  if [[ ! -s "$slim_dir/web_nothreads_$mode.zip" ]]; then
    why="not built (tools/web_template/build.sh$([[ $mode == debug ]] && echo ' --debug' || true))"
  elif ! grep -q "\"config_hash\": \"$want_hash\"" "$slim_dir/template.json" 2>/dev/null; then
    why="built for another config (rebuild: tools/web_template/build.sh)"
  elif ! tools/godot.sh --headless --path . --script res://tools/web_template/detect_classes.gd -- --check >"$log" 2>&1; then
    why="the game uses classes it lacks: $(grep -o 'the game uses .*' "$log" | head -3 | tr '\n' ';' || true)"
  else
    use_slim=1
  fi
  if [[ $use_slim -eq 0 && "$template" == slim ]]; then
    echo "export_web.sh: slim template $why" >&2; exit 1
  fi
fi
mkdir -p "$selected"
for m in release debug; do
  src="$official_dir/web_nothreads_$m.zip"
  if [[ $use_slim -eq 1 && -s "$slim_dir/web_nothreads_$m.zip" ]]; then src="$slim_dir/web_nothreads_$m.zip"; fi
  [[ "$template" == *.zip && $m == "$mode" ]] && src="$template"
  cp -f "$src" "$selected/web_nothreads_$m.zip"
done
if [[ "$template" == *.zip ]]; then
  engine="$template (as given)"
elif [[ $use_slim -eq 1 ]]; then
  engine="slim (tools/web_template, config $want_hash)"
else
  engine="official 4.7-stable${why:+; slim template $why}"
fi
echo "$engine" >"$selected/ENGINE"   # for tools/web_template/ci_gate.sh

echo "export_web.sh: exporting Web ($mode) -> $out" >&2
status=0
tools/godot.sh --headless --path . "--export-$mode" "Web" "$out" >"$log.raw" 2>&1 || status=$?
sed $'s/\x1b\\[[0-9;]*m//g' "$log.raw" >"$log"; rm -f "$log.raw"   # strip ANSI colors
# Godot can exit 0 on some export failures, so also scan the log for errors.
if [[ $status -ne 0 ]] || grep -qE '^(ERROR|SCRIPT ERROR|USER ERROR):|Project export for preset .* failed' "$log"; then
  cat "$log"
  echo "export_web.sh: export failed (exit $status)" >&2
  exit 1
fi

for f in index.html index.js index.wasm index.pck; do
  if [[ ! -s "$out_dir/$f" ]]; then
    cat "$log"; echo "export_web.sh: missing $out_dir/$f" >&2; exit 1
  fi
done

if grep -qE '^WARNING:' "$log"; then
  echo "export_web.sh: export warnings:" >&2
  grep -E '^WARNING:' -A1 "$log" >&2 || true
fi

# WP9.2 music pack (docs/WEB.md): when the Web preset's exclude filter leaves the music
# out of index.pck, the tracks ship as music.pck, which the game fetches after it
# starts (src/platform/web_music_pack.gd). The pack's directory holds plain paths
# (the tracks' .import remaps; audio.tres names the .ogg files too, so match .ogg.import).
if grep -aqE 'assets/audio/music_[a-z0-9_]+\.ogg\.import' "$out_dir/index.pck"; then
  music="in index.pck (the Web preset does not exclude assets/audio/music_*)"
else
  echo "export_web.sh: packing the music -> $out_dir/music.pck" >&2
  if ! tools/godot.sh --headless --path . --script res://platform/web/pack_music.gd -- "$PWD/$out_dir/music.pck" >"$log" 2>&1 \
      || [[ ! -s "$out_dir/music.pck" ]]; then
    cat "$log"; echo "export_web.sh: music pack failed" >&2; exit 1
  fi
  music="music.pck, loaded after the title is up"
fi

# WP9.2 (docs/WEB.md): the build id is a hash of the engine and the packs, so a deploy
# that changes none of them keeps every cache warm. version.json (read uncached by the
# custom shell) lets a stale cached index.html reload itself. The custom shell
# (platform/web/shell.html, html/custom_html_shell in export_presets.cfg) carries two
# tokens: __WB_BUILD__ (the ?v= on index.js, index.wasm, index.pck and music.pck) and
# __WB_FONT__ (the loading screen's wordmark font, inlined so it needs no request).
hashed=("$out_dir/index.wasm" "$out_dir/index.pck")
[[ -f "$out_dir/music.pck" ]] && hashed+=("$out_dir/music.pck")
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }   # Linux, macOS
build_id="$(cat "${hashed[@]}" | sha256 | cut -c1-12)"
printf '{"build":"%s","commit":"%s"}\n' "$build_id" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  >"$out_dir/version.json"
if grep -q '__WB_BUILD__' "$out_dir/index.html"; then
  font="platform/web/wordmark.woff"
  [[ -s "$font" ]] || { echo "export_web.sh: missing $font (python3 platform/web/make_font.py)" >&2; exit 1; }
  sed -e "s/__WB_BUILD__/$build_id/g" -e "s|__WB_FONT__|$(base64 <"$font" | tr -d '\n')|g" \
    "$out_dir/index.html" >"$out_dir/index.html.tmp"
  mv "$out_dir/index.html.tmp" "$out_dir/index.html"
  shell="custom (platform/web/shell.html)"
else
  shell="Godot default; the custom one needs html/custom_html_shell=\"res://platform/web/shell.html\" (docs/WEB.md)"
fi

human() { awk '{ if ($1 >= 1048576) printf "%.1f MiB", $1 / 1048576; else printf "%.1f KiB", $1 / 1024 }'; }
size() { wc -c <"$1" | human; }
gz() { gzip -9c "$1" | wc -c | human; }
echo "export_web.sh: built $out ($mode), build $build_id"
echo "  engine: $engine"
echo "  shell: $shell"
echo "  music: $music"
for f in index.wasm index.pck index.js music.pck; do
  [[ -f "$out_dir/$f" ]] || continue
  printf '  %-11s %10s   gzip %10s\n' "$f" "$(size "$out_dir/$f")" "$(gz "$out_dir/$f")"
done
printf '  %-11s %10s\n' "total" "$(du -sk "$out_dir" | awk '{ print $1 * 1024 }' | human)"
# What a first visit downloads before the title (every file but the music pack,
# gzip-encoded as GitHub Pages serves them, ~level 6).
wire=0
for f in "$out_dir"/*; do
  [[ "$(basename "$f")" == music.pck ]] && continue
  wire=$((wire + $(gzip -6c "$f" | wc -c)))
done
printf '  %-11s %10s   (to the title: every file but music.pck, gzip -6 as GitHub Pages serves them)\n' "transfer" "$(echo "$wire" | human)"
