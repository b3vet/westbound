class_name HudButton
extends BaseButton
## The HUD's pause [II], camera [CAM] and high-beam buttons, top-right. Spec: UI → HUD
## elements ("Top-right: ... pause and camera buttons"); Design system (faceted small
## controls, 7 px bevel, neon edge switching to the accent when pressed); plan D8 (the
## player's manual high beams, WP5.5). The only HUD pieces that take touches
## (mouse_filter STOP); everything else lets touches through.
##
## The high-beam glyph is the headlamp symbol (a lamp with straight beams) drawn with
## HudMesh, so the button is one draw call. `lit` (high beams on) fills it gold with
## an ink glyph.

enum Glyph { PAUSE, CAMERA, HIGH_BEAM }

const LABEL_CAMERA := "CAM"
## Points on the lamp's rounded side (the flat side closes the fan).
const LAMP_ARC_POINTS := 11
const BEAMS := 4

@export var glyph: Glyph = Glyph.PAUSE

var style: HudStyle
## High beams on: gold fill, ink glyph (only the HIGH_BEAM glyph uses it).
var lit: bool = false
var _mesh := HudMesh.new()
var _lamp := PackedVector2Array()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	_lamp.resize(LAMP_ARC_POINTS)


func setup(s: HudStyle) -> void:
	style = s
	queue_redraw()


## Redraws only when the lit state changes.
func set_lit(on: bool) -> void:
	if on == lit:
		return
	lit = on
	queue_redraw()


## Shapes as one triangle array (one draw call), then the CAM label.
func _draw() -> void:
	if style == null:
		return
	var s := style
	var mode := get_draw_mode()
	var down := mode == DRAW_PRESSED or mode == DRAW_HOVER_PRESSED
	var fill := Color(s.ink, 1.0) if down else s.panel_fill
	var edge := s.accent if down or mode == DRAW_HOVER else s.edge_idle
	var ink := s.accent if down else s.text
	if lit and not down:
		fill = s.gold
		edge = s.gold
		ink = Color(s.ink, 1.0)
	var c := size * 0.5
	_mesh.begin()
	_mesh.panel(Rect2(Vector2.ZERO, size), s.bevel_control, fill, edge, s.edge_w)
	if glyph == Glyph.PAUSE:
		var h := HudDraw.cap_height(s.size_button) * PAUSE_HEIGHT
		var w := h * PAUSE_BAR
		var gap := w
		_mesh.rect(Rect2(Vector2(c.x - gap * 0.5 - w, c.y - h * 0.5), Vector2(w, h)), ink)
		_mesh.rect(Rect2(Vector2(c.x + gap * 0.5, c.y - h * 0.5), Vector2(w, h)), ink)
	elif glyph == Glyph.HIGH_BEAM:
		_high_beam_glyph(c, HudDraw.cap_height(s.size_button) * LAMP_HEIGHT, ink)
	_mesh.flush(self)
	if glyph == Glyph.CAMERA:
		var tw := HudDraw.text_width(s.label, LABEL_CAMERA, s.size_button)
		HudDraw.text(self, s.label, Vector2(c.x - tw * 0.5, c.y + HudDraw.cap_height(s.size_button) * 0.5),
				LABEL_CAMERA, s.size_button, ink)


## The high-beam symbol centred on `c`, `h` tall: a lamp (flat side left, rounded right)
## with straight beams to its left.
func _high_beam_glyph(c: Vector2, h: float, ink: Color) -> void:
	var lamp_w := h * LAMP_WIDTH
	var beam_l := h * BEAM_LENGTH
	var beam_gap := h * BEAM_GAP
	var beam_w := h * BEAM_WIDTH
	var total := beam_l + beam_gap + lamp_w
	var flat_x := c.x - total * 0.5 + beam_l + beam_gap
	# Rounded side: a half ellipse from the top of the flat side to its bottom.
	for i in LAMP_ARC_POINTS:
		var a := -PI * 0.5 + PI * float(i) / float(LAMP_ARC_POINTS - 1)
		_lamp[i] = Vector2(flat_x + cos(a) * lamp_w, c.y + sin(a) * h * 0.5)
	_mesh.fan(_lamp, LAMP_ARC_POINTS, ink)
	var x0 := flat_x - beam_gap - beam_l
	var x1 := flat_x - beam_gap
	var pitch := (h - beam_w) / float(BEAMS - 1)
	for i in BEAMS:
		var y := c.y - (h - beam_w) * 0.5 + float(i) * pitch
		_mesh.line(Vector2(x0, y), Vector2(x1, y), beam_w, ink)


const PAUSE_HEIGHT := 1.3   # lint: allow-number glyph proportion
const PAUSE_BAR := 0.28   # lint: allow-number glyph proportion
const LAMP_HEIGHT := 1.35   # lint: allow-number glyph proportion
const LAMP_WIDTH := 0.62   # lint: allow-number glyph proportion
const BEAM_LENGTH := 0.62   # lint: allow-number glyph proportion
const BEAM_GAP := 0.16   # lint: allow-number glyph proportion
const BEAM_WIDTH := 0.14   # lint: allow-number glyph proportion
