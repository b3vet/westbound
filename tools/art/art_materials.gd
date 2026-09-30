class_name ArtMaterials
extends RefCounted
## Material names -> what the game draws (docs/ART_PRODUCTION.md §3.3; CONTRACTS §13).
## The game never uses a file's materials: the modular car import (G1) and the .glb
## converters (G2 props, G3 traffic) replace them by name, and write the colour the name
## carries into vertex COLOR (sRGB), so glTF's colour-space conversions never touch it.
##
##   player car  paint | paint_shade | paint_dark | trim_<c> | glass | glass_<c> |
##               lamp_head | lamp_tail | signal_brake | signal_blinker | signal_reverse |
##               interior_<c> | interior_screen | gauges
##   traffic     <c> | fixed_<c> | paint* | glass_<c> | wheel_<c> | head_<c> | rear_<c> |
##               brake_<c> | blinkL_<c> | blinkR_<c>
##   prop        <c> | <c>__reflector | <c>__lamp | <c>__window | <c>__flash
## <c> is a palette name (ArtPalette). Names are matched case-insensitively (Blender
## keeps what you type); a Blender duplicate suffix (".001") is an error.
## Load time only; allocates.

## What a car material becomes.
enum CarKind { SLOT, INTERIOR, GAUGES, UNKNOWN }

## Paint shade multipliers in COLOR.r (vehicle.gdshader and traffic.gdshader multiply the
## paint by it). Same values as tools/traffic_models/build_traffic_models.gd.
const PAINT_SHADES := {&"paint": 1.0, &"paint_shade": 0.8, &"paint_dark": 0.55}
## Emissive class suffixes of world meshes (world_common.gdshaderinc, UV2.x). The window
## class is world_windows.gdshader's, the flash class set_piece.gdshader's (both 4).
const PROP_SUFFIXES := {&"reflector": 1, &"lamp": 2, &"window": 4, &"flash": 4}
const EMISSIVE_WINDOW := 4
const SUFFIX_SEP := "__"
## The centre-stack screen's colour (the procedural cockpit's) and its emissive class.
const SCREEN_COLOR := Cockpit.COL_STACK
const SCREEN_EMISSIVE := Cockpit.EMISSIVE_VEHICLE


class CarMat extends RefCounted:
	var kind: int = CarKind.UNKNOWN
	## CarModel.Slot for kind SLOT.
	var slot: int = CarModel.Slot.TRIM
	## sRGB (paint: a grey shade multiplier).
	var color: Color = Color.WHITE
	## UV2.x emissive class (interior faces only).
	var emissive: float = 0.0
	var error: String = ""


class TrafficMat extends RefCounted:
	var part: int = TrafficLights.PART_FIXED
	var color: Color = Color.WHITE
	var error: String = ""


class PropMat extends RefCounted:
	var color: Color = Color.WHITE
	var emissive: int = 0
	var window: bool = false
	var error: String = ""


var palette: ArtPalette


func _init(p: ArtPalette = null) -> void:
	palette = p if p != null else ArtPalette.new()


static func _clean(material_name: String) -> String:
	return material_name.strip_edges().to_lower()


static func _bad_chars(material_name: String) -> String:
	for ch: String in [".", " ", ":", "@", "/", "%", "\""]:
		if material_name.contains(ch):
			return "material %s: '%s' is not allowed in names (Blender duplicate?)" % [material_name, ch]
	return ""


## A player-car material (§3.3.1, §3.3.2).
func car(material_name: String) -> CarMat:
	var m := CarMat.new()
	var n := _clean(material_name)
	m.error = _bad_chars(material_name)
	if not m.error.is_empty():
		return m
	var sn := StringName(n)
	if PAINT_SHADES.has(sn):
		var k: float = PAINT_SHADES[sn]
		m.kind = CarKind.SLOT
		m.slot = CarModel.Slot.PAINT
		m.color = Color(k, k, k)
		return m
	match n:
		"glass":
			return _slot(m, CarModel.Slot.GLASS, CarModel.COLOR_GLASS)
		"lamp_head":
			return _slot(m, CarModel.Slot.LAMP, CarModel.COLOR_HEADLIGHT)
		"lamp_tail":
			return _slot(m, CarModel.Slot.LAMP, CarModel.COLOR_TAILLIGHT)
		"signal_brake":
			return _slot(m, CarModel.Slot.SIGNAL, CarModel.COLOR_BRAKE)
		"signal_blinker":
			return _slot(m, CarModel.Slot.SIGNAL, CarModel.COLOR_BLINKER)
		"signal_reverse":
			return _slot(m, CarModel.Slot.SIGNAL, CarModel.COLOR_REVERSE)
		"gauges":
			m.kind = CarKind.GAUGES
			return m
		"interior_screen":
			m.kind = CarKind.INTERIOR
			m.color = SCREEN_COLOR
			m.emissive = SCREEN_EMISSIVE
			return m
	for pair: Array in [["trim_", CarModel.Slot.TRIM], ["glass_", CarModel.Slot.GLASS]]:
		var prefix: String = pair[0]
		if n.begins_with(prefix):
			var c := StringName(n.trim_prefix(prefix))
			if palette.has_name(c):
				return _slot(m, int(pair[1]), palette.color(c))
			m.error = "material %s: %s is not a palette colour" % [material_name, c]
			return m
	if n.begins_with("interior_"):
		var c := StringName(n.trim_prefix("interior_"))
		if palette.has_name(c):
			m.kind = CarKind.INTERIOR
			m.color = palette.color(c)
			return m
		m.error = "material %s: %s is not a palette colour" % [material_name, c]
		return m
	m.error = "material %s: not a car material name (paint*, trim_<c>, glass[_<c>], lamp_head/tail, signal_*, interior_<c>, gauges)" % material_name
	return m


static func _slot(m: CarMat, slot: int, c: Color) -> CarMat:
	m.kind = CarKind.SLOT
	m.slot = slot
	m.color = c
	return m


## A traffic material (§3.3.3).
func traffic(material_name: String) -> TrafficMat:
	var m := TrafficMat.new()
	var n := _clean(material_name)
	m.error = _bad_chars(material_name)
	if not m.error.is_empty():
		return m
	var sn := StringName(n)
	if PAINT_SHADES.has(sn):
		var k: float = PAINT_SHADES[sn]
		m.part = TrafficLights.PART_PAINT
		m.color = Color(k, k, k)
		return m
	var prefixes := [
		["fixed_", TrafficLights.PART_FIXED], ["glass_", TrafficLights.PART_GLASS],
		["wheel_", TrafficLights.PART_WHEEL], ["head_", TrafficLights.PART_HEAD],
		["rear_", TrafficLights.PART_REAR], ["brake_", TrafficLights.PART_BRAKE],
		["blinkl_", TrafficLights.PART_BLINK_L], ["blinkr_", TrafficLights.PART_BLINK_R],
	]
	for pair: Array in prefixes:
		var prefix: String = pair[0]
		if n.begins_with(prefix):
			var c := StringName(n.trim_prefix(prefix))
			if palette.has_name(c):
				m.part = int(pair[1])
				m.color = palette.color(c)
				return m
	# A bare palette name (also one that starts like a prefix: glass_dark is a colour).
	if palette.has_name(sn):
		m.part = TrafficLights.PART_FIXED
		m.color = palette.color(sn)
		return m
	m.error = "material %s: not a traffic material name (<c>, fixed_/glass_/wheel_/head_/rear_/brake_/blinkL_/blinkR_<c>, paint*)" % material_name
	return m


## A world-mesh material (§3.3.4), colours looked up with `prefer_set` first.
func prop(material_name: String, prefer_set: StringName = &"") -> PropMat:
	var m := PropMat.new()
	var n := _clean(material_name)
	m.error = _bad_chars(material_name)
	if not m.error.is_empty():
		return m
	var base := n
	var i := n.find(SUFFIX_SEP)
	if i >= 0:
		base = n.substr(0, i)
		var suffix := StringName(n.substr(i + SUFFIX_SEP.length()))
		if not PROP_SUFFIXES.has(suffix):
			m.error = "material %s: unknown suffix __%s (reflector, lamp, window, flash)" % [material_name, suffix]
			return m
		m.emissive = int(PROP_SUFFIXES[suffix])
		m.window = suffix == &"window"
	if not palette.has_name(StringName(base), prefer_set):
		m.error = "material %s: %s is not a palette colour" % [material_name, base]
		return m
	m.color = palette.color(StringName(base), prefer_set)
	return m
