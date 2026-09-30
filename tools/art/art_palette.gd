class_name ArtPalette
extends RefCounted
## Every named colour an art asset may use (docs/ART_PRODUCTION.md §2.2, §3.3; spec: Art
## pipeline, "palette of about 30 colors"). The converters and the modular car import
## (G1-G3) look material names up here and write the exact sRGB value into the vertex
## COLOR the shaders read. Three sources, searched in this order unless a set is
## preferred:
##   style           assets/palette/palette.tres (WBPalette, the style-guide sheet)
##   coast_city_valley   tools/props/palette_biomes_4_6.tres (WBPalette)
##   desert_canyon   tools/props/biome_colors.gd (BiomeColors.COLORS)
## `sand` and `scrub` exist in both biome sets with different values: a prop names its
## biome (sidecar or export folder) and that set wins (prefer_set_for_biome()).
##
##   var pal := ArtPalette.new()
##   pal.has_name(&"ink")                       # true
##   pal.color(&"sand", ArtPalette.SET_DESERT)  # the desert's sand
##
## Load time only (tools and import scripts); allocates.

const SET_STYLE := &"style"
const SET_COAST_CITY_VALLEY := &"coast_city_valley"
const SET_DESERT_CANYON := &"desert_canyon"
const STYLE_PATH := "res://assets/palette/palette.tres"
const BIOMES_4_6_PATH := "res://tools/props/palette_biomes_4_6.tres"
## Biome ids (data/biomes/<id>.tres) and the set whose colours they use.
const DESERT_CANYON_BIOMES: Array[StringName] = [&"desert", &"canyon"]
const COAST_CITY_VALLEY_BIOMES: Array[StringName] = [&"coast", &"city", &"valley", &"valley_fog"]

## Set id -> {StringName name: Color sRGB}.
var sets: Dictionary = {}
## Search order when no set is preferred.
var order: Array[StringName] = [SET_STYLE, SET_COAST_CITY_VALLEY, SET_DESERT_CANYON]


func _init() -> void:
	sets[SET_STYLE] = _from_wb(STYLE_PATH)
	sets[SET_COAST_CITY_VALLEY] = _from_wb(BIOMES_4_6_PATH)
	var desert := {}
	for k: StringName in BiomeColors.COLORS:
		desert[k] = BiomeColors.COLORS[k]
	sets[SET_DESERT_CANYON] = desert


## A WBPalette .tres's names -> colours, parsed from its text: the car import script
## runs in the editor's importer, where WBPalette (not a tool script) loads as a
## placeholder without its values. Falls back to the loaded resource.
static func _from_wb(path: String) -> Dictionary:
	var out := {}
	var names := PackedStringArray()
	var nums := PackedFloat64Array()
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("names = PackedStringArray("):
			for part in line.get_slice("(", 1).trim_suffix(")").split(","):
				names.append(part.strip_edges().trim_prefix("\"").trim_suffix("\""))
		elif line.begins_with("colors = PackedColorArray("):
			for part in line.get_slice("(", 1).trim_suffix(")").split(","):
				nums.append(part.strip_edges().to_float())
	if not names.is_empty() and nums.size() == names.size() * 4:
		for i in names.size():
			out[StringName(names[i])] = Color(nums[i * 4], nums[i * 4 + 1], nums[i * 4 + 2], nums[i * 4 + 3])
		return out
	var p := load(path) as WBPalette
	if p != null:
		for i in mini(p.names.size(), p.colors.size()):
			out[StringName(p.names[i])] = p.colors[i]
	return out


## The set a biome's props take their colours from (&"" = the default order).
static func prefer_set_for_biome(biome: StringName) -> StringName:
	if DESERT_CANYON_BIOMES.has(biome):
		return SET_DESERT_CANYON
	if COAST_CITY_VALLEY_BIOMES.has(biome):
		return SET_COAST_CITY_VALLEY
	return &""


## Search order with `prefer` (a set id) right after the style palette.
func search_order(prefer: StringName = &"") -> Array[StringName]:
	if prefer == &"" or prefer == SET_STYLE or not sets.has(prefer):
		return order
	var out: Array[StringName] = [SET_STYLE, prefer]
	for s in order:
		if not out.has(s):
			out.append(s)
	return out


func has_name(color_name: StringName, prefer: StringName = &"") -> bool:
	for s in search_order(prefer):
		if (sets[s] as Dictionary).has(color_name):
			return true
	return false


## The named sRGB colour (Color.MAGENTA when unknown: check has_name first).
func color(color_name: StringName, prefer: StringName = &"") -> Color:
	for s in search_order(prefer):
		var d: Dictionary = sets[s]
		if d.has(color_name):
			return d[color_name]
	return Color.MAGENTA


## Every name, each once, in search order (calibration files, tests).
func all_names(prefer: StringName = &"") -> Array[StringName]:
	var out: Array[StringName] = []
	for s in search_order(prefer):
		for k: StringName in sets[s]:
			if not out.has(k):
				out.append(k)
	return out
