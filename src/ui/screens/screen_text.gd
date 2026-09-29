class_name ScreenText
extends Control
## One line of screen type in the design system. Spec: UI, HUD and design system →
## Design system (Chakra Petch display and tracked labels, tabular numbers, speed tilt,
## colors); Accessibility (text size). docs/SCREENS.md.
##
## Custom-drawn with the HUD's helpers (HudDraw), so screens and HUD share one look:
## the same fonts, outline and drop shadow, and tabular digits (Chakra Petch has no
## `tnum`, so a counting number never jitters). Redraws only when its text, color or
## style changes. Never takes touches.

enum Face { DISPLAY, LABEL, BODY }
enum Ink { TEXT, MUTED, GOLD, HOT, ACCENT, INK }

## Line box height per em (room for the outline and the drop shadow).
const LINE_EM := 1.3   # lint: allow-number font metric

var style: HudStyle
var face: Face = Face.LABEL
var ink: Ink = Ink.TEXT
## Base size in canvas px at 100% text size (scaled by the style's text size).
var size_px: int = 16
var outline: bool = false
var tabular: bool = false
var align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
var text: String = "":
	set(value):
		if value == text:
			return
		text = value
		update_minimum_size()
		queue_redraw()

var _tilt: ShaderMaterial


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


## A line of `face` type at `base_px`, in `color_ink`.
static func make(text_value: String, text_face: Face, base_px: int, color_ink: Ink = Ink.TEXT) -> ScreenText:
	var t := ScreenText.new()
	t.face = text_face
	t.size_px = base_px
	t.ink = color_ink
	t.text = text_value
	return t


func setup(s: HudStyle) -> void:
	style = s
	update_minimum_size()
	queue_redraw()


func set_ink(value: Ink) -> void:
	if value != ink:
		ink = value
		queue_redraw()


## Speed tilt (speed_tilt.gdshader, vertex-only: the same on both renderers).
func use_tilt(shader: Shader, tilt_rad: float) -> void:
	if _tilt == null:
		_tilt = ShaderMaterial.new()
	_tilt.shader = shader
	_tilt.set_shader_parameter(HudWidget.TILT, tilt_rad)
	material = _tilt
	_update_pivot()


## Font size in canvas px now (text size applied).
func font_px() -> int:
	if style == null:
		return size_px
	return maxi(1, roundi(float(size_px) * style.ts))


func font() -> Font:
	if style == null:
		return ThemeDB.fallback_font
	match face:
		Face.DISPLAY:
			return style.display
		Face.BODY:
			return style.body
	return style.label


func text_width() -> float:
	var f := font()
	var fs := font_px()
	if tabular and style != null:
		return HudDraw.number_width(f, text, fs, style.digit_cell(f, fs))
	return HudDraw.text_width(f, text, fs)


func color() -> Color:
	if style == null:
		return Color.WHITE
	match ink:
		Ink.MUTED:
			return style.muted
		Ink.GOLD:
			return style.gold
		Ink.HOT:
			return style.hot
		Ink.ACCENT:
			return style.accent
		Ink.INK:
			return style.ink
	return style.text


func _get_minimum_size() -> Vector2:
	return Vector2(ceilf(text_width()), ceilf(float(font_px()) * LINE_EM))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_pivot()


func _update_pivot() -> void:
	pivot_offset = size * 0.5
	if _tilt != null:
		_tilt.set_shader_parameter(HudWidget.PIVOT_Y, size.y * 0.5)


func _draw() -> void:
	if style == null or text.is_empty():
		return
	var f := font()
	var fs := font_px()
	var w := text_width()
	var x := 0.0
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		x = (size.x - w) * 0.5
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		x = size.x - w
	var pos := Vector2(x, (size.y + HudDraw.cap_height(fs)) * 0.5)
	var ol := style.outline_px if outline else 0
	if tabular:
		HudDraw.number(self, f, pos, text, fs, style.digit_cell(f, fs), color(), ol, style.outline)
	else:
		HudDraw.text(self, f, pos, text, fs, color(), ol, style.outline)
