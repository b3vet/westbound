class_name ControlsOverlay
extends Control
## The touch controls overlay. Spec: Controls → Drag steering ("Indicator. A faint ring
## shows the anchor and a dot shows the thumb, both in the design system's accent
## color"); UI → HUD elements ("Controls overlay: the drag anchor ring (drag modes) or
## pedals and buttons (manual and gyro modes), mirrored for left-handed play"; safe
## areas; "nothing animates when idle"); Design system (faceted panels, 1.5 px neon
## edge, accent from the color script). docs/CONTROLS.md → Overlay.
##
## Draws what PlayerInput's ControlsLayout says, so touch zones and visuals always
## agree (mirroring and safe areas included). Never takes input (mouse_filter IGNORE).
## Redraws only when something it shows changed: a cheap per-frame comparison, no
## allocation, and no redraw at all while nothing moves.
##
## Accent: follows the SkyRig (accent_changed) when there is one; set_accent() for
## anything else; falls back to the color script's run-start accent.
## Colors below are the design system's until ui/theme.tres exists (WP4.3).

const COLOR_PANEL := Color("#111a30")
const COLOR_LINE := Color("#8a93ad")
const COLOR_TEXT := Color("#f4f7ff")
const COLOR_HOT := Color("#ff5a4d")
const LABEL_GAS := "GAS"
const LABEL_BRAKE := "BRAKE"
const LABEL_BOOST := "BOOST"
## Octagon: faceted ring and dot (low-poly style instead of a smooth circle).
const FACETS := 8

## The hub; empty = the first node in PlayerInput.GROUP.
@export var input_path: NodePath

var hub: PlayerInput
var accent: Color = Color.WHITE

var _controls: ControlsTuning
var _hud: HudTuning
var _box_idle := StyleBoxFlat.new()
var _box_pressed := StyleBoxFlat.new()
var _box_fill := StyleBoxFlat.new()
## Closed outline (polyline) and the same shape open (filled polygon).
var _poly := PackedVector2Array()
var _fill := PackedVector2Array()
var _font: Font
var _sky: SkyRig

# What was drawn last (redraw only on change).
var _shown_version: int = -1
var _shown_drag: bool = false
var _shown_anchor: Vector2 = Vector2.ZERO
var _shown_thumb: Vector2 = Vector2.ZERO
var _shown_drag_brake: float = 0.0
var _shown_gas: bool = false
var _shown_boost: bool = false
var _shown_pedal_brake: float = 0.0
var _shown_hold: float = 0.0
var _shown_hold_pos: Vector2 = Vector2.ZERO
var _redraws: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var t := Tuning.load_default()
	_controls = t.controls
	_hud = t.hud
	_font = ThemeDB.fallback_font
	_poly.resize(FACETS + 1)
	_fill.resize(FACETS)
	accent = _fallback_accent(t)
	_setup_box(_box_idle, t.hud.control_bevel_px)
	_setup_box(_box_pressed, t.hud.control_bevel_px)
	_setup_box(_box_fill, t.hud.control_bevel_px)


func _process(_delta: float) -> void:
	if hub == null or not is_instance_valid(hub):
		hub = _find_hub()
		if hub == null:
			return
	if _sky == null:
		_sky = get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig
		if _sky != null:
			_sky.accent_changed.connect(set_accent)
			set_accent(_sky.get_accent())
	if _changed():
		queue_redraw()


## The design system's accent ("the sky's neon").
func set_accent(color: Color) -> void:
	if color == accent:
		return
	accent = color
	queue_redraw()


## How many times the overlay has drawn (tests: nothing redraws when idle).
func redraw_count() -> int:
	return _redraws


func _draw() -> void:
	_redraws += 1
	if hub == null:
		return
	var l := hub.layout
	var idle_a := Units.pct_to_frac(_controls.overlay_idle_alpha_pct)
	_draw_control(l, l.gas_rect, LABEL_GAS, hub.gas_pressed, accent, idle_a, 0.0)
	_draw_control(l, l.brake_rect, LABEL_BRAKE, hub.pedal_brake > 0.0, COLOR_HOT, idle_a, hub.pedal_brake)
	_draw_control(l, l.boost_rect, LABEL_BOOST, hub.boost_pressed, accent, idle_a, 0.0)

	var dot_r := _controls.overlay_dot_radius_px
	var edge := _hud.neon_border_px
	if hub.drag.active:
		var ring := accent
		ring.a = Units.pct_to_frac(_controls.overlay_ring_alpha_pct)
		_octagon(hub.drag.anchor, _controls.overlay_ring_radius_px)
		draw_polyline(_poly, ring, edge, true)
		var dot := COLOR_HOT if hub.drag.brake > 0.0 else accent
		_octagon(hub.drag.thumb, dot_r)
		draw_colored_polygon(_fill, dot)
	if hub.hold_brake > 0.0:
		_octagon(hub.hold_pos, dot_r * 2.0)
		draw_polyline(_poly, COLOR_HOT, edge, true)
		_octagon(hub.hold_pos, dot_r)
		draw_colored_polygon(_fill, COLOR_HOT)


func _draw_control(l: ControlsLayout, r: Rect2, label: String, pressed: bool, on_color: Color,
		idle_alpha: float, fill_frac: float) -> void:
	if not l.has(r):
		return
	var box := _box_pressed if pressed else _box_idle
	box.bg_color = Color(COLOR_PANEL, 1.0 if pressed else idle_alpha)
	draw_style_box(box, r)
	var bevel := _hud.control_bevel_px
	if fill_frac > 0.0:
		# The brake level, bottom-up, inside the pedal.
		var h := r.size.y * fill_frac
		var fill := Rect2(r.position.x, r.end.y - h, r.size.x, h)
		_box_fill.bg_color = Color(on_color, Units.pct_to_frac(_controls.overlay_ring_alpha_pct))
		draw_style_box(_box_fill, fill)
	var edge_color := on_color if pressed else Color(COLOR_LINE, idle_alpha)
	_chamfer(r, bevel)
	draw_polyline(_poly, edge_color, _hud.neon_border_px, true)
	var font_px := _controls.overlay_label_px
	var text_color := on_color if pressed else Color(COLOR_TEXT, idle_alpha)
	var baseline := r.position.y + r.size.y * 0.5 + font_px * 0.5
	draw_string(_font, Vector2(r.position.x, baseline), label, HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, roundi(font_px), text_color)


func _changed() -> bool:
	var d := hub.drag
	var changed := hub.layout_version != _shown_version \
			or d.active != _shown_drag \
			or (d.active and (d.anchor != _shown_anchor or d.thumb != _shown_thumb
				or d.brake != _shown_drag_brake)) \
			or hub.gas_pressed != _shown_gas or hub.boost_pressed != _shown_boost \
			or hub.pedal_brake != _shown_pedal_brake or hub.hold_brake != _shown_hold \
			or (hub.hold_brake > 0.0 and hub.hold_pos != _shown_hold_pos)
	if changed:
		_shown_version = hub.layout_version
		_shown_drag = d.active
		_shown_anchor = d.anchor
		_shown_thumb = d.thumb
		_shown_drag_brake = d.brake
		_shown_gas = hub.gas_pressed
		_shown_boost = hub.boost_pressed
		_shown_pedal_brake = hub.pedal_brake
		_shown_hold = hub.hold_brake
		_shown_hold_pos = hub.hold_pos
	return changed


func _find_hub() -> PlayerInput:
	if not input_path.is_empty():
		return get_node_or_null(input_path) as PlayerInput
	return get_tree().get_first_node_in_group(PlayerInput.GROUP) as PlayerInput


## Faceted panel fill: StyleBoxFlat with corner_detail 1 turns the radius into a chamfer.
func _setup_box(box: StyleBoxFlat, bevel: float) -> void:
	box.set_corner_radius_all(roundi(bevel))
	box.corner_detail = 1


## The chamfered outline of `r` into _poly (closed).
func _chamfer(r: Rect2, bevel: float) -> void:
	var b := minf(bevel, minf(r.size.x, r.size.y) * 0.5)
	var p := r.position
	var e := r.end
	_poly[0] = Vector2(p.x + b, p.y)
	_poly[1] = Vector2(e.x - b, p.y)
	_poly[2] = Vector2(e.x, p.y + b)
	_poly[3] = Vector2(e.x, e.y - b)
	_poly[4] = Vector2(e.x - b, e.y)
	_poly[5] = Vector2(p.x + b, e.y)
	_poly[6] = Vector2(p.x, e.y - b)
	_poly[7] = Vector2(p.x, p.y + b)
	_poly[8] = _poly[0]


## A regular octagon (flat top) around `c` into _poly (closed).
func _octagon(c: Vector2, radius: float) -> void:
	for i in FACETS:
		var a := TAU * (float(i) + 0.5) / float(FACETS)
		_poly[i] = c + Vector2(cos(a), sin(a)) * radius
		_fill[i] = _poly[i]
	_poly[FACETS] = _poly[0]


static func _fallback_accent(t: Tuning) -> Color:
	var cs := ColorScript.load_default()
	cs.bind(t.sun)
	return cs.accent_at(t.sun.sky_t_run_start)
