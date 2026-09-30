class_name HudWidget
extends Control
## Base of the HUD's custom-drawn pieces. Spec: UI → HUD elements ("labels change
## only when their value changes; nothing animates when idle"); Performance budget.
##
## A widget draws its shapes on a plate behind it (HudPlate: one triangle array, one
## draw call) and its text itself, grouped by font so glyphs batch. Each redraws only
## when what it shows changes (`changes` counts shown-value changes) or while an
## animation runs (animate() returns true). It never takes touches (mouse_filter
## IGNORE), so the controls under it keep working.

const TILT := &"tilt_rad"
const PIVOT_Y := &"pivot_y"

var style: HudStyle
## Shown-value changes (a new number or state was drawn).
var changes: int = 0
## _draw calls (tests: nothing redraws when idle).
var redraws: int = 0

var _plate: HudPlate


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	if _has_plate():
		_plate = HudPlate.new()
		_plate.widget = self
		add_child(_plate, false, Node.INTERNAL_MODE_FRONT)


## _draw calls of this widget and its plate.
func redraw_total() -> int:
	return redraws + (_plate.redraws if _plate != null else 0)


## false for text-only widgets (no plate).
func _has_plate() -> bool:
	return true


## Adds the widget's shapes (local coordinates) to `m`.
func _paint_plate(_m: HudMesh) -> void:
	pass


func setup(s: HudStyle) -> void:
	style = s
	_restyled()
	_redraw_all()


## Draws this widget speed-tilted (speed_tilt.gdshader), skewed about its middle.
func use_tilt(shader: Shader, tilt_rad: float) -> void:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter(TILT, tilt_rad)
	material = m
	_update_pivot()


func _update_pivot() -> void:
	pivot_offset = size * 0.5
	var m := material as ShaderMaterial
	if m != null:
		m.set_shader_parameter(PIVOT_Y, size.y * 0.5)


## Advances animations by dt; true while something is moving (a redraw is queued).
## With style.reduced_motion a widget fades only: no scale, slide, rotation or pulse.
func animate(_dt: float) -> bool:
	return false


## How far from rest this widget is drawn now, in px, radians or pulse depth (tests,
## WP9.3): 0 when nothing but opacity changes. The base counts scale and rotation;
## widgets that move or pulse their drawing add their own.
func motion_amount() -> float:
	return (scale - Vector2.ONE).abs().length() + absf(rotation)


## Reduced motion turned on (WP9.3): puts a moving transform back at rest now.
func settle_motion() -> void:
	scale = Vector2.ONE
	rotation = 0.0
	_redraw_all()


## The accent changed (redraw if this widget shows it).
func accent_changed() -> void:
	if visible:
		_redraw_all()


## Called after setup (text size or theme changed): recompute cached metrics.
func _restyled() -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_pivot()
		if _plate != null:
			_plate.position = Vector2.ZERO
			_plate.size = size
		if style != null:
			_restyled()


## A shown value changed: text and shapes redraw.
func _value_changed() -> void:
	changes += 1
	_redraw_all()


## A shown value changed that only the text shows.
func _text_changed() -> void:
	changes += 1
	queue_redraw()


## Only the shapes move (animations).
func _plate_redraw() -> void:
	if _plate != null:
		_plate.queue_redraw()


func _redraw_all() -> void:
	queue_redraw()
	if _plate != null:
		_plate.queue_redraw()


func _draw() -> void:
	redraws += 1
	if style != null:
		_paint()


## Draws the widget's text (style is set).
func _paint() -> void:
	pass
