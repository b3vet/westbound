class_name ControlsOverlay
extends Control
## The touch controls overlay. Spec: Controls → Drag steering ("Indicator. A faint ring
## shows the anchor and a dot shows the thumb, both in the design system's accent
## color"); UI → HUD elements ("Controls overlay: the drag anchor ring (drag modes) or
## pedals and buttons (manual and gyro modes), mirrored for left-handed play"; safe
## areas; "nothing animates when idle"); Design system (faceted panels, 1.5 px neon
## edge, accent from the color script). docs/CONTROLS.md → Overlay.
##
## Drag visual (plan D10, the hub's drag_visual): the ring (anchor ring + thumb dot),
## or a faceted steering wheel centred on the anchor that turns by steer x
## wheel_visual_max_deg. Visual only. Manual pedals (plan D9): the gas pedal and its
## boost cap are drawn as one joined control. Everything is sized by controls_scale.
##
## Draws what PlayerInput's ControlsLayout says, so touch zones and visuals always
## agree (mirroring and safe areas included). Never takes input (mouse_filter IGNORE).
## Redraws only when something it shows changed: a cheap per-frame comparison, no
## allocation, and no redraw at all while nothing moves.
##
## Braking by drag (WP9.3, color is never the only cue): the thumb also gets a hot ring,
## the gyro hold-brake's shape, in both drag visuals.
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
## Wheel spokes (screen angles, +y down, at zero rotation): right, left, bottom.
const SPOKE_ANGLES: Array[float] = [0.0, PI, PI * 0.5]
## The rim marker at 12 o'clock (shows the wheel's rotation).
const MARKER_ANGLE := -PI * 0.5

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
## Wheel, drawn in two canvas commands (the draw-call budget): every fill as one
## triangle array (points, per-vertex colors, fixed indices) and every edge as one
## multiline. Sized once in _ready from wheel_facets.
var _wheel_pts := PackedVector2Array()
var _wheel_cols := PackedColorArray()
var _wheel_idx := PackedInt32Array()
var _wheel_edges := PackedVector2Array()
## The cap chevron.
var _chevron := PackedVector2Array()
var _box_cap := StyleBoxFlat.new()
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
var _shown_steer: float = 0.0
var _shown_visual: StringName = &""
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
	_build_wheel_buffers(_controls.wheel_facets)
	_chevron.resize(3)
	accent = _fallback_accent(t)
	_setup_box(_box_idle, t.hud.control_bevel_px)
	_setup_box(_box_pressed, t.hud.control_bevel_px)
	_setup_box(_box_fill, t.hud.control_bevel_px)
	_setup_box(_box_cap, t.hud.control_bevel_px)
	# The boost fill covers the cap only: chamfered on top, square where it meets the gas.
	_box_cap.corner_radius_bottom_left = 0
	_box_cap.corner_radius_bottom_right = 0


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


## The drag visual is the steering wheel (hub.drag_visual).
func wheel_mode() -> bool:
	return hub != null and hub.drag_visual == PlayerInput.WHEEL


## The drag brakes: the hot ring shows round the thumb (WP9.3, both drag visuals).
func brake_ring_visible() -> bool:
	return hub != null and hub.drag.active and hub.drag.brake > 0.0


## The wheel is on screen: wheel mode and a steering thumb down.
func wheel_visible() -> bool:
	return wheel_mode() and hub.drag.active


## Wheel angle in radians (+ = clockwise on screen = steering right).
func wheel_rotation() -> float:
	if hub == null:
		return 0.0
	return hub.drag.steer * _controls.wheel_visual_max_rad()


func wheel_center() -> Vector2:
	return hub.drag.anchor if hub != null else Vector2.ZERO


func wheel_radius_px() -> float:
	if hub == null:
		return 0.0
	return _controls.wheel_visual_diameter_cm * 0.5 * hub.layout.px_per_cm * hub.controls_scale


func ring_radius_px() -> float:
	return _controls.overlay_ring_radius_px * _scale()


func _draw() -> void:
	_redraws += 1
	if hub == null:
		return
	var l := hub.layout
	var idle_a := Units.pct_to_frac(_controls.overlay_idle_alpha_pct)
	_draw_gas_column(l, idle_a)
	_draw_control(l.brake_rect, LABEL_BRAKE, hub.pedal_brake > 0.0, COLOR_HOT, idle_a, hub.pedal_brake)

	var dot_r := _controls.overlay_dot_radius_px * _scale()
	var edge := _hud.neon_border_px
	if hub.drag.active:
		if wheel_mode():
			_draw_wheel(hub.drag.anchor, wheel_radius_px(), wheel_rotation(), hub.drag.brake > 0.0)
		else:
			var ring := accent
			ring.a = Units.pct_to_frac(_controls.overlay_ring_alpha_pct)
			_octagon(hub.drag.anchor, ring_radius_px())
			draw_polyline(_poly, ring, edge, true)
			var dot := COLOR_HOT if hub.drag.brake > 0.0 else accent
			_octagon(hub.drag.thumb, dot_r)
			draw_colored_polygon(_fill, dot)
		if brake_ring_visible():
			_octagon(hub.drag.thumb, dot_r * 2.0)
			draw_polyline(_poly, COLOR_HOT, edge, true)
	if hub.hold_brake > 0.0:
		_octagon(hub.hold_pos, dot_r * 2.0)
		draw_polyline(_poly, COLOR_HOT, edge, true)
		_octagon(hub.hold_pos, dot_r)
		draw_colored_polygon(_fill, COLOR_HOT)


func _draw_control(r: Rect2, label: String, pressed: bool, on_color: Color,
		idle_alpha: float, fill_frac: float) -> void:
	if not hub.layout.has(r):
		return
	var box := _box_pressed if pressed else _box_idle
	box.bg_color = Color(COLOR_PANEL, 1.0 if pressed else idle_alpha)
	draw_style_box(box, r)
	if fill_frac > 0.0:
		# The brake level, bottom-up, inside the pedal.
		var h := r.size.y * fill_frac
		var fill := Rect2(r.position.x, r.end.y - h, r.size.x, h)
		_box_fill.bg_color = Color(on_color, Units.pct_to_frac(_controls.overlay_ring_alpha_pct))
		draw_style_box(_box_fill, fill)
	var edge_color := on_color if pressed else Color(COLOR_LINE, idle_alpha)
	_chamfer(r, _hud.control_bevel_px)
	draw_polyline(_poly, edge_color, _hud.neon_border_px, true)
	_label(r, label, on_color if pressed else Color(COLOR_TEXT, idle_alpha))


## The joined gas control: one chamfered panel and edge around pedal + cap, a divider
## at the joint, an up chevron and BOOST on the cap, GAS on the pedal.
func _draw_gas_column(l: ControlsLayout, idle_alpha: float) -> void:
	if not l.has(l.gas_control):
		return
	var gc := l.gas_control
	var cap := l.boost_rect
	var pressed := hub.gas_pressed
	var box := _box_pressed if pressed else _box_idle
	box.bg_color = Color(COLOR_PANEL, 1.0 if pressed else idle_alpha)
	draw_style_box(box, gc)
	if hub.boost_pressed:
		_box_cap.bg_color = Color(accent, Units.pct_to_frac(_controls.overlay_ring_alpha_pct))
		draw_style_box(_box_cap, cap)
	var line := Color(COLOR_LINE, idle_alpha)
	var edge_color := accent if pressed else line
	var w := _hud.neon_border_px
	var bevel := _hud.control_bevel_px
	# Divider at the joint, inset by the bevel so it reads as one control.
	var joint := cap.end.y
	draw_line(Vector2(gc.position.x + bevel, joint), Vector2(gc.end.x - bevel, joint),
			accent if hub.boost_pressed else line, w, true)
	_chamfer(gc, bevel)
	draw_polyline(_poly, edge_color, w, true)
	var boost_text := accent if hub.boost_pressed else Color(COLOR_TEXT, idle_alpha)
	# Chevron (slide up) in the cap's upper part, the label below it.
	var font_px := _controls.overlay_label_px * _scale()
	var cx := cap.get_center().x
	var tip := cap.position.y + cap.size.y * 0.5 - font_px
	_chevron[0] = Vector2(cx - font_px * 0.5, tip + font_px * 0.5)
	_chevron[1] = Vector2(cx, tip)
	_chevron[2] = Vector2(cx + font_px * 0.5, tip + font_px * 0.5)
	draw_polyline(_chevron, boost_text, w, true)
	_label(Rect2(cap.position.x, cap.position.y + font_px * 0.5, cap.size.x, cap.size.y),
			LABEL_BOOST, boost_text)
	_label(l.gas_rect, LABEL_GAS, accent if pressed else Color(COLOR_TEXT, idle_alpha))


## Faceted low-poly steering wheel: rim ring (quads between two n-gons), three spokes,
## hub, and a marker facet at 12 o'clock. Subtle panel fill, accent (hot when braking)
## edges. Two canvas commands: one triangle array, one multiline.
func _draw_wheel(c: Vector2, radius: float, angle: float, braking: bool) -> void:
	var n := _controls.wheel_facets
	var inner := radius * Units.pct_to_frac(_controls.wheel_rim_inner_pct)
	var hub_r := radius * Units.pct_to_frac(_controls.wheel_hub_pct)
	var spoke_half := radius * Units.pct_to_frac(_controls.wheel_spoke_width_pct) * 0.5
	var fill := Color(COLOR_PANEL, Units.pct_to_frac(_controls.overlay_idle_alpha_pct))
	var edge := COLOR_HOT if braking else accent
	var marker := Color(edge, 1.0)
	edge.a = Units.pct_to_frac(_controls.wheel_edge_alpha_pct)
	var v := 0
	var e := 0
	# Rim: outer vertices 0..n-1, inner n..2n-1 (a vertex every facet, flat at the top).
	for i in n:
		var dir := Vector2.from_angle(angle + TAU * (float(i) + 0.5) / float(n))
		_wheel_pts[i] = c + dir * radius
		_wheel_pts[n + i] = c + dir * inner
		_wheel_cols[i] = fill
		_wheel_cols[n + i] = fill
	for i in n:
		var j := (i + 1) % n
		e = _edge(e, _wheel_pts[i], _wheel_pts[j])
		e = _edge(e, _wheel_pts[n + i], _wheel_pts[n + j])
	v = 2 * n
	# Spokes, from inside the hub to the inner rim.
	for base: float in SPOKE_ANGLES:
		var dir := Vector2.from_angle(angle + base)
		var side := Vector2(-dir.y, dir.x) * spoke_half
		_wheel_pts[v] = c + dir * (hub_r * 0.5) + side
		_wheel_pts[v + 1] = c + dir * inner + side
		_wheel_pts[v + 2] = c + dir * inner - side
		_wheel_pts[v + 3] = c + dir * (hub_r * 0.5) - side
		for k in 4:
			_wheel_cols[v + k] = fill
		e = _edge(e, c + dir * hub_r + side, _wheel_pts[v + 1])
		e = _edge(e, c + dir * hub_r - side, _wheel_pts[v + 2])
		v += 4
	# Hub: an opaque octagon fan (centre + FACETS).
	_wheel_pts[v] = c
	_wheel_cols[v] = Color(COLOR_PANEL, 1.0)
	for i in FACETS:
		_wheel_pts[v + 1 + i] = c + Vector2.from_angle(angle + TAU * (float(i) + 0.5) / float(FACETS)) * hub_r
		_wheel_cols[v + 1 + i] = _wheel_cols[v]
	for i in FACETS:
		e = _edge(e, _wheel_pts[v + 1 + i], _wheel_pts[v + 1 + (i + 1) % FACETS])
	v += FACETS + 1
	# 12 o'clock marker: the rim facet there, solid in the edge color.
	var half := PI / float(n)
	var m0 := Vector2.from_angle(angle + MARKER_ANGLE - half)
	var m1 := Vector2.from_angle(angle + MARKER_ANGLE + half)
	_wheel_pts[v] = c + m0 * radius
	_wheel_pts[v + 1] = c + m1 * radius
	_wheel_pts[v + 2] = c + m1 * inner
	_wheel_pts[v + 3] = c + m0 * inner
	for k in 4:
		_wheel_cols[v + k] = marker
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _wheel_idx, _wheel_pts, _wheel_cols)
	draw_multiline(_wheel_edges, edge, _hud.neon_border_px, true)


## One edge segment into the multiline buffer; returns the next free slot.
func _edge(at: int, a: Vector2, b: Vector2) -> int:
	_wheel_edges[at] = a
	_wheel_edges[at + 1] = b
	return at + 2


## Sizes the wheel buffers and writes the fixed triangle indices (topology only
## depends on the facet count).
func _build_wheel_buffers(n: int) -> void:
	var spokes := SPOKE_ANGLES.size()
	var verts := 2 * n + 4 * spokes + FACETS + 1 + 4
	_wheel_pts.resize(verts)
	_wheel_cols.resize(verts)
	# Edges: two rims (n segments each), two per spoke, the hub outline.
	_wheel_edges.resize(2 * (2 * n + 2 * spokes + FACETS))
	_wheel_idx.clear()
	for i in n:
		var j := (i + 1) % n
		_quad_indices(i, j, n + j, n + i)
	var v := 2 * n
	for _spoke in spokes:
		_quad_indices(v, v + 1, v + 2, v + 3)
		v += 4
	for i in FACETS:
		_wheel_idx.append(v)
		_wheel_idx.append(v + 1 + i)
		_wheel_idx.append(v + 1 + (i + 1) % FACETS)
	v += FACETS + 1
	_quad_indices(v, v + 1, v + 2, v + 3)


func _quad_indices(a: int, b: int, c: int, d: int) -> void:
	_wheel_idx.append_array(PackedInt32Array([a, b, c, a, c, d]))


func _label(r: Rect2, text: String, color: Color) -> void:
	var font_px := _controls.overlay_label_px * _scale()
	var baseline := r.position.y + r.size.y * 0.5 + font_px * 0.5
	draw_string(_font, Vector2(r.position.x, baseline), text, HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, roundi(font_px), color)


func _scale() -> float:
	return hub.controls_scale if hub != null else 1.0


func _changed() -> bool:
	var d := hub.drag
	var changed := hub.layout_version != _shown_version \
			or d.active != _shown_drag \
			or (d.active and (d.anchor != _shown_anchor or d.thumb != _shown_thumb
				or d.brake != _shown_drag_brake or d.steer != _shown_steer)) \
			or hub.drag_visual != _shown_visual \
			or hub.gas_pressed != _shown_gas or hub.boost_pressed != _shown_boost \
			or hub.pedal_brake != _shown_pedal_brake or hub.hold_brake != _shown_hold \
			or (hub.hold_brake > 0.0 and hub.hold_pos != _shown_hold_pos)
	if changed:
		_shown_version = hub.layout_version
		_shown_drag = d.active
		_shown_anchor = d.anchor
		_shown_thumb = d.thumb
		_shown_drag_brake = d.brake
		_shown_steer = d.steer
		_shown_visual = hub.drag_visual
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
