#!/usr/bin/env bash
# Builds westbound_thermal.xcframework (device + simulator static libraries) for the
# WestboundThermal iOS plugin (WP9.1). UNTESTED: run on the owner's Mac with Xcode.
#
#   GODOT_SRC=~/src/godot platform/ios/thermal/build.sh [release|debug]
#
# GODOT_SRC is a Godot source checkout at the 4.7-stable tag whose headers were generated
# once (e.g. `scons platform=ios target=template_release` stopped after the generated
# headers, or a full template build). Plugins must be built against the same engine
# version as the export templates.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
target="${1:-release}"
: "${GODOT_SRC:?set GODOT_SRC to a Godot 4.7-stable source checkout}"
out="$here/bin"
mkdir -p "$out"

defs=(-DIOS_ENABLED -DUNIX_ENABLED -DVULKAN_ENABLED -DCOREAUDIO_ENABLED)
if [[ "$target" == "debug" ]]; then
  defs+=(-DDEBUG_ENABLED -DDEBUG_METHODS_ENABLED)
fi
incs=(-I"$GODOT_SRC" -I"$GODOT_SRC/platform/ios" -I"$GODOT_SRC/drivers/apple_embedded")

build_one() {  # sdk arch min-flag name
  local sdk="$1" arch="$2" min="$3" name="$4"
  local objs=()
  for src in westbound_thermal.mm westbound_thermal_module.mm; do
    local obj="$out/${name}_${src%.mm}.o"
    xcrun --sdk "$sdk" clang++ -std=c++17 -fobjc-arc -fmodules -O2 -arch "$arch" "$min" \
      "${defs[@]}" "${incs[@]}" -c "$here/$src" -o "$obj"
    objs+=("$obj")
  done
  xcrun --sdk "$sdk" libtool -static -o "$out/$name.a" "${objs[@]}"
}

build_one iphoneos arm64 -miphoneos-version-min=12.0 westbound_thermal_device
build_one iphonesimulator arm64 -mios-simulator-version-min=12.0 westbound_thermal_sim

rm -rf "$out/westbound_thermal.xcframework"
xcodebuild -create-xcframework \
  -library "$out/westbound_thermal_device.a" \
  -library "$out/westbound_thermal_sim.a" \
  -output "$out/westbound_thermal.xcframework"
echo "built $out/westbound_thermal.xcframework"
