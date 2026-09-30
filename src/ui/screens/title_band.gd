class_name TitleBand
extends Control
## The slanted ink band behind the title's and the online hub's left-anchored menus
## (WP8.5). Spec: UI, HUD and design system → Design system (ink #0b1020, thin neon edge,
## speed tilt: the band's edge leans like the -7° type; no gradients, no frosted glass
## without an edge); Screens → Title. docs/SCREENS.md → Title.
##
## One triangle array (HudMesh: one draw call): ink at HudTuning.title_band_pct from the
## left edge to `width` px, the right edge leaning with the speed tilt, lined with the
## accent. Never takes touches; redraws only when resized or restyled.

var style: HudStyle
## Band width at the bottom (px); the top reaches further by the tilt's lean.
var width: float = 0.0:
	set(value):
		if value != width:
			width = value
			queue_redraw()

var _mesh := HudMesh.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func setup(s: HudStyle) -> void:
	style = s
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## How far the band's top edge reaches past its bottom width (px).
func lean() -> float:
	if style == null:
		return 0.0
	return size.y * tan(absf(style.tilt_rad))


func _draw() -> void:
	if style == null or width <= 0.0:
		return
	var t := style.tuning
	var l := lean()
	_mesh.begin()
	_mesh.slant(Rect2(Vector2.ZERO, Vector2(width, size.y)), l, Color(style.ink, Units.pct_to_frac(t.title_band_pct)))
	_mesh.line(Vector2(width + l, 0.0), Vector2(width, size.y), style.edge_w, style.accent)
	_mesh.flush(self)
