#!/usr/bin/env bash
# Build the Web export (Compatibility renderer, single-threaded) into build/web/.
#   tools/export_web.sh            # release build
#   tools/export_web.sh --debug    # debug build (debug template, verbose engine errors)
# Installs the export templates on first use (tools/export_templates.sh).
# Then smoke-test it with:  node tools/web_smoke/smoke.mjs
set -euo pipefail
cd "$(dirname "$0")/.."

mode="release"
case "${1:-}" in
  "") ;;
  --release) mode="release" ;;
  --debug) mode="debug" ;;
  -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  *) echo "export_web.sh: unknown option '$1' (use --debug or --release)" >&2; exit 2 ;;
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

human() { awk '{ if ($1 >= 1048576) printf "%.1f MiB", $1 / 1048576; else printf "%.1f KiB", $1 / 1024 }'; }
size() { wc -c <"$1" | human; }
gz() { gzip -9c "$1" | wc -c | human; }
echo "export_web.sh: built $out ($mode)"
for f in index.wasm index.pck index.js; do
  printf '  %-11s %10s   gzip %10s\n' "$f" "$(size "$out_dir/$f")" "$(gz "$out_dir/$f")"
done
printf '  %-11s %10s\n' "total" "$(du -sk "$out_dir" | awk '{ print $1 * 1024 }' | human)"
