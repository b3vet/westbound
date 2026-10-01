#!/usr/bin/env bash
# WP9.9: build Westbound's slim Godot web export template (docs/WEB.md → Slim engine).
#
#   tools/web_template/build.sh              # release template (what tools/export_web.sh uses)
#   tools/web_template/build.sh --debug      # debug template (tools/export_web.sh --debug)
#   tools/web_template/build.sh --all        # both
#   tools/web_template/build.sh --hash       # print the config hash (CI cache key) and exit
#   options: --jobs=N  --keep (keep the object files for a quicker rebuild)
#
# Pinned inputs: the Godot 4.7-stable source tarball (SHA-512 from the release's
# SHA512-SUMS.txt), emsdk / Emscripten 4.0.20 (the version godotengine/build-containers
# uses for 4.7, i.e. the official template's compiler) at a pinned emsdk commit, and
# SCons 4.10.1 (same container). The engine is built single-threaded (threads=no, the
# Web preset's variant) with the official template's settings (production=yes,
# optimize=size, wasm SIMD) plus: full LTO, the modules and features the game does not
# use turned off (SCONS_ARGS below, each with its reason) and the class build profile
# westbound.gdbuild.
#
# Everything downloaded or built lives in ${WESTBOUND_CACHE:-~/.cache/westbound}/web_template
# (emsdk ~1.6 GB, the source tree + objects ~3 GB while building; the objects are deleted
# afterwards unless --keep). Output, next to a manifest (template.json: the config hash,
# the pins, the sizes):
#   build/web_template/web_nothreads_release.zip   (and web_nothreads_debug.zip)
# tools/export_web.sh picks it up when its config hash matches (else the official template).
# No Docker: a pinned emsdk checkout is just as reproducible and runs the same in CI.
set -euo pipefail
cd "$(dirname "$0")/../.."
here="tools/web_template"

GODOT_VERSION="4.7-stable"
GODOT_SRC_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/godot-${GODOT_VERSION}.tar.xz"
GODOT_SRC_SHA512="0afddbd2acb1e2eba0bb2b885d58c321e9b7d4adc30481d7ab70b348dc96d9ccf1c11fd7de39900eb646c543488225280b7321831b0237cde9d27655962fefc0"
EMSDK_VERSION="4.0.20"
EMSDK_COMMIT="e4fe26ef59168ff44f4c23c466e497bf60b3411e"   # emsdk tag 4.0.20
SCONS_VERSION="4.10.1"
PROFILE="$here/westbound.gdbuild"

# SCons arguments on top of platform/target. Keep one per line with its reason: the hash
# of this file is the template's identity (CI cache key, export_web.sh's staleness check).
SCONS_ARGS=(
  threads=no                          # the Web preset's variant (variant/thread_support=false)
  production=yes                      # as the official templates (no debug symbols, static C++)
  optimize=size                       # the web platform's default, as official (-Os)
  lto=full                            # official uses lto=thin; full LTO drops more dead code
  scu_build=yes                       # single compilation units: ~2x faster cold build (full LTO
                                      # merges every unit anyway; wasm floats are strict IEEE)
  javascript_eval=yes                 # JavaScriptBridge.eval: WebAudioBridge, js_bridge.gd
  wasm_simd=yes                       # as official (the same float code as the official build)
  "build_profile=$PROFILE"            # unused classes unregistered (see westbound.gdbuild)
  # Whole features the game never uses (the sim is road-space GDScript; the crash
  # cinematic is the only physics and it is 3D Jolt).
  disable_physics_2d=yes              # no 2D bodies/areas/shapes anywhere
  disable_navigation_2d=yes           # no navigation (traffic is IDM/MOBIL in road space)
  disable_navigation_3d=yes
  disable_xr=yes                      # no XR (also drops the webxr and mobile_vr modules)
  brotli=no                           # Brotli is only for WOFF2 fonts; the fonts are TTF
  module_text_server_adv_enabled=yes  # kept: HarfBuzz shaping (GPOS kerning), BiDi, Unicode names
  graphite=no                         # SIL Graphite smart fonts; Chakra Petch has no Graphite tables
  # Modules off (grep-audited against src/, data/, assets/, platform/; docs/WEB.md).
  module_godot_physics_3d_enabled=no  # project uses Jolt (physics/3d/physics_engine); Jolt kept
  module_vhacd_enabled=no             # convex decomposition (import-time only)
  module_csg_enabled=no               # no CSG nodes
  module_gridmap_enabled=no           # no GridMap
  module_gltf_enabled=no              # .glb is imported at edit time; no runtime GLTFDocument
  module_fbx_enabled=no               # no runtime FBX
  module_meshoptimizer_enabled=no     # LODs are generated at import; no runtime SurfaceTool LOD
  module_multiplayer_enabled=no       # own WebSocket protocol; no SceneMultiplayer / @rpc
  module_enet_enabled=no              # ENet cannot run in a browser
  module_webrtc_enabled=no            # no WebRTC
  module_upnp_enabled=no              # no UPnP (and none in a browser)
  module_jsonrpc_enabled=no           # only the GDScript language server (editor) uses it
  module_theora_enabled=no            # no video
  module_mp3_enabled=no               # audio is OGG Vorbis (loops/music) and WAV (one-shots)
  module_interactive_music_enabled=no # no AudioStreamInteractive/Playlist/Synchronized
  module_noise_enabled=no             # no FastNoiseLite / NoiseTexture
  module_visual_shader_enabled=no     # every shader is a .gdshader
  module_zip_enabled=no               # no ZIPReader/ZIPPacker (core .zip packs stay: minizip=yes)
  module_astcenc_enabled=no           # runtime ASTC (de)compression: the pack has no VRAM textures
  module_bcdec_enabled=no             # runtime BCn decompression: idem
  module_etcpak_enabled=no            # runtime ETC2 compression: idem
  module_basis_universal_enabled=no   # no Basis Universal textures
  module_ktx_enabled=no               # no KTX images
  module_dds_enabled=no               # no DDS images
  module_bmp_enabled=no               # runtime image loaders: textures are imported .ctex
  module_tga_enabled=no               #   (PNG core, WebP lossless module kept), no runtime
  module_hdr_enabled=no               #   Image.load of these formats
  module_jpg_enabled=no
  module_tinyexr_enabled=no
)

targets=(release)
jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
keep=0
for a in "$@"; do
  case "$a" in
    --release) targets=(release) ;;
    --debug) targets=(debug) ;;
    --all) targets=(release debug) ;;
    --jobs=*) jobs="${a#--jobs=}" ;;
    --keep) keep=1 ;;
    --hash) ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build.sh: unknown option '$a'" >&2; exit 2 ;;
  esac
done

sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
# The template's identity: this script (pins + SCons arguments) and the class profile.
config_hash="$(cat "$0" "$PROFILE" | sha256 | cut -c1-16)"
for a in "$@"; do [[ "$a" == --hash ]] && { echo "$config_hash"; exit 0; }; done

cache="${WESTBOUND_CACHE:-$HOME/.cache/westbound}/web_template"
out_dir="build/web_template"
mkdir -p "$cache" "$out_dir"
# Templates of another config never mix with this one's.
if [[ -f "$out_dir/template.json" ]] && ! grep -q "\"config_hash\": \"$config_hash\"" "$out_dir/template.json"; then
  rm -f "$out_dir"/web_nothreads_*.zip "$out_dir/template.json"
fi
[[ -f build/.gdignore ]] || : >build/.gdignore
log() { echo "build.sh: $*" >&2; }
t_start=$SECONDS

# 1. Godot source (release tarball, checksummed).
tarball="$cache/godot-${GODOT_VERSION}.tar.xz"
sha512_ok() { local s; if command -v sha512sum >/dev/null; then s="$(sha512sum "$1")"; else s="$(shasum -a 512 "$1")"; fi; [[ "${s%% *}" == "$GODOT_SRC_SHA512" ]]; }
if [[ ! -f "$tarball" ]] || ! sha512_ok "$tarball"; then
  log "downloading godot-${GODOT_VERSION}.tar.xz"
  curl -fL --retry 3 -sS -o "$tarball.part" "$GODOT_SRC_URL"
  mv "$tarball.part" "$tarball"
  sha512_ok "$tarball" || { rm -f "$tarball"; log "SHA-512 mismatch for the Godot source"; exit 1; }
fi

# 2. emsdk at the pinned tag and commit.
emsdk="$cache/emsdk-$EMSDK_VERSION"
if [[ ! -f "$emsdk/.westbound_ready" ]]; then
  rm -rf "$emsdk"
  log "installing emsdk $EMSDK_VERSION (~1.6 GB)"
  git clone -q --depth 1 --branch "$EMSDK_VERSION" https://github.com/emscripten-core/emsdk "$emsdk"
  got="$(git -C "$emsdk" rev-parse HEAD)"
  [[ "$got" == "$EMSDK_COMMIT" ]] || { log "emsdk tag $EMSDK_VERSION is $got, expected $EMSDK_COMMIT"; exit 1; }
  "$emsdk/emsdk" install "$EMSDK_VERSION" >&2
  "$emsdk/emsdk" activate "$EMSDK_VERSION" >/dev/null
  : >"$emsdk/.westbound_ready"
fi
# shellcheck disable=SC1091
EMSDK_QUIET=1 source "$emsdk/emsdk_env.sh" >/dev/null
emver="$(emcc -dumpversion)"
[[ "$emver" == "$EMSDK_VERSION" ]] || { log "emcc is $emver, expected $EMSDK_VERSION"; exit 1; }

# 3. SCons in its own venv.
venv="$cache/scons-$SCONS_VERSION"
if [[ ! -x "$venv/bin/scons" ]]; then
  log "installing SCons $SCONS_VERSION"
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q "scons==$SCONS_VERSION"
fi

# 4. A clean source tree per config (objects kept across targets, removed at the end).
src="$cache/build-$config_hash"
if [[ ! -f "$src/.westbound_extracted" ]]; then
  rm -rf "$cache"/build-*
  mkdir -p "$src"
  log "extracting the source into $src"
  tar xf "$tarball" -C "$src" --strip-components=1
  : >"$src/.westbound_extracted"
fi
cp "$PROFILE" "$src/westbound.gdbuild"

human() { awk '{ if ($1 >= 1048576) printf "%.1f MiB", $1 / 1048576; else printf "%.1f KiB", $1 / 1024 }'; }
manifest_sizes=""
for t in "${targets[@]}"; do
  log "building template_$t (jobs $jobs; a cold build takes 30-60 min)"
  args=("${SCONS_ARGS[@]}")
  args=("${args[@]/#build_profile=*/build_profile=westbound.gdbuild}")
  ( cd "$src" && BUILD_NAME=westbound_slim GODOT_VERSION_STATUS=stable nice -n 10 \
      "$venv/bin/scons" -j"$jobs" platform=web "target=template_$t" "${args[@]}" \
      progress=no warnings=no verbose=no ) >&2
  zip_in="$src/bin/godot.web.template_$t.wasm32.nothreads.zip"
  [[ -s "$zip_in" ]] || { log "missing $zip_in"; exit 1; }
  cp "$zip_in" "$out_dir/web_nothreads_$t.zip"
  wasm_raw="$(unzip -p "$zip_in" godot.wasm | wc -c | tr -d ' ')"
  wasm_gz="$(unzip -p "$zip_in" godot.wasm | gzip -6 | wc -c | tr -d ' ')"
  manifest_sizes+="$(printf '"%s": {"wasm": %s, "wasm_gzip6": %s}, ' "$t" "$wasm_raw" "$wasm_gz")"
  log "template_$t: godot.wasm $(echo "$wasm_raw" | human), gzip $(echo "$wasm_gz" | human)"
done

# Merge with an existing manifest of the same config (a --debug after a --release).
prev="$out_dir/template.json"
if [[ -f "$prev" ]] && grep -q "\"config_hash\": \"$config_hash\"" "$prev"; then
  for t in release debug; do
    [[ " ${targets[*]} " == *" $t "* ]] && continue
    old="$(grep -o "\"$t\": {[^}]*}" "$prev" || true)"
    [[ -n "$old" ]] && manifest_sizes+="$old, "
  done
fi
cat >"$out_dir/template.json" <<EOF
{"config_hash": "$config_hash", "godot": "$GODOT_VERSION", "emscripten": "$EMSDK_VERSION", "scons": "$SCONS_VERSION",
 "sizes": {${manifest_sizes%, }}, "built": "$(date -u +%Y-%m-%dT%H:%MZ)"}
EOF

if [[ $keep -eq 0 ]]; then
  log "removing the build tree ($(du -sh "$src" | cut -f1))"
  rm -rf "$src"
fi
log "done in $(( (SECONDS - t_start) / 60 )) min: $out_dir (config $config_hash)"
