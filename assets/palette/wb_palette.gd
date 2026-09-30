class_name WBPalette
extends Resource
## The style-guide palette (ART1 start). Spec: Cars, garage, progression and art
## pipeline → Art pipeline ("one style guide sheet: palette of about 30 colors,
## flat shading, no photo textures"). Every world mesh takes its vertex colors
## (COLOR.rgb, sRGB) from here; see assets/palette/README.md.
##
## Data: assets/palette/palette.tres. `names` and `colors` are parallel.

const PATH := "res://assets/palette/palette.tres"

@export var names: PackedStringArray = []
## sRGB, as authored (the world shader converts to linear).
@export var colors: PackedColorArray = []


static func load_default() -> WBPalette:
	return load(PATH) as WBPalette


func has_color(color_name: StringName) -> bool:
	return names.has(String(color_name))


## The named color. Unknown names are an authoring error (magenta + push_error).
func color(color_name: StringName) -> Color:
	var i := names.find(String(color_name))
	if i < 0:
		push_error("WBPalette: unknown color %s" % color_name)
		return Color.MAGENTA
	return colors[i]


func size() -> int:
	return names.size()
