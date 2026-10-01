class_name FirstRunSketch
extends Control
## A small sketch of a control layout on a landscape phone, for the chooser. Spec:
## Controls (the four layouts: drag + auto one thumb; drag + manual steer left, gas
## right; gyro + auto tilt, hold to brake; gyro + manual pedals both sides; mirrored for
## left-handed play). WP8.1; docs/SCREENS.md → First run. Plan D9: the gas pedal carries
## the boost cap on top, the brake sits beside it.
##
## Drag steering shows the look the player will get (plan D10, the drag_visual setting;
## WP9.10): the faceted steering wheel by default, drawn like ControlsOverlay's (the same
## facets, rim, spokes, hub and 12 o'clock marker from ControlsTuning), or the ring and
## thumb dot. Short strokes outside it say what the thumb does (left / right steers;
## with auto throttle, down brakes and a flick up boosts).
##
## Drawn in the design system's shapes (HudMesh: chamfered panels, neon edges, accent)
## as fractions of the phone, so it scales with the space it gets. Redraws only when the
## layout changes. Never takes touches.

var style: HudStyle
var steering: StringName = &"drag"
var throttle: StringName = &"auto"
var left_handed: bool = false
## The drag look: PlayerInput.WHEEL (the default) or PlayerInput.RING.
var drag_visual: StringName = PlayerInput.WHEEL
## _draw calls (tests: an unchanged layout does not redraw).
var redraws: int = 0

var _mesh := HudMesh.new()
var _controls: ControlsTuning
## The wheel's outer and inner rim loops.
var _outer := PackedVector2Array()
var _inner := PackedVector2Array()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_outer.resize(HudMesh.MAX_LOOP)
	_inner.resize(HudMesh.MAX_LOOP)


func setup(s: HudStyle) -> void:
	style = s
	_controls = Tuning.load_default().controls
	queue_redraw()


func set_layout(steer: StringName, throttle_mode: StringName, mirrored: bool,
		visual: StringName = PlayerInput.WHEEL) -> void:
	var look := PlayerInput.RING if visual == PlayerInput.RING else PlayerInput.WHEEL
	if steer == steering and throttle_mode == throttle and mirrored == left_handed and look == drag_visual:
		return
	steering = steer
	throttle = throttle_mode
	left_handed = mirrored
	drag_visual = look
	queue_redraw()


## Drag steering is drawn as the steering wheel (else the ring and dot).
func wheel_shown() -> bool:
	return steering != &"gyro" and drag_visual == PlayerInput.WHEEL


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	redraws += 1
	if style == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var s := style
	var gyro := steering == &"gyro"
	var manual := throttle == &"manual"
	var tilt := TILT_RAD if gyro else 0.0
	var c := size * 0.5
	var ph := Rect2(-c * PHONE_SCALE, size * PHONE_SCALE)
	# Tilt steering: the phone leans; everything is drawn in its frame.
	draw_set_transform(c, tilt)
	_mesh.begin()
	_mesh.panel(ph, s.bevel_panel, Color(s.ink, s.panel_fill.a), s.edge_idle, s.edge_w)
	# The road running off to the horizon, for scale.
	var road := Color(s.muted, ROAD_A)
	_mesh.line(_p(ph, ROAD_NEAR_L, 1.0), _p(ph, ROAD_FAR_L, HORIZON), s.edge_w, road)
	_mesh.line(_p(ph, 1.0 - ROAD_NEAR_L, 1.0), _p(ph, 1.0 - ROAD_FAR_L, HORIZON), s.edge_w, road)
	var thumb_x := 1.0 - THUMB_X if left_handed else THUMB_X
	var other_x := 1.0 - thumb_x
	if not gyro:
		var ring_x := thumb_x
		if manual:
			# Drag + manual: the steering zone is the other half.
			var zone := Rect2(_p(ph, 0.5 if left_handed else 0.0, 0.0), ph.size * Vector2(0.5, 1.0))
			_mesh.rect(zone.grow(-s.edge_w * 2.0), Color(s.accent, ZONE_A))
			ring_x = other_x
		var rc := _p(ph, ring_x, RING_Y)
		if wheel_shown():
			var wr := ph.size.y * WHEEL_R
			_wheel(rc, wr)
			# Left / right steers: strokes either side of the rim.
			for side: float in [-1.0, 1.0]:
				_mesh.line(rc + Vector2(side * wr * STROKE_FROM, 0.0), rc + Vector2(side * wr * STROKE_TO, 0.0),
						s.edge_w, s.text)
			if not manual:
				_mesh.line(rc + Vector2(0.0, wr * STROKE_FROM), rc + Vector2(0.0, wr * STROKE_TO), s.edge_w, s.hot)
				_mesh.line(rc - Vector2(0.0, wr * STROKE_FROM), rc - Vector2(0.0, wr * STROKE_TO), s.edge_w, s.accent)
		else:
			var rr := ph.size.y * RING_R
			_mesh.ngon(rc, rr, RING_SIDES, Color(s.accent, RING_FILL_A), s.accent, s.edge_w)
			_mesh.ngon(rc + Vector2(rr * DOT_OFFSET, 0.0), rr * DOT_R, RING_SIDES, s.accent)
			# Left / right steers.
			_mesh.line(rc - Vector2(rr * ARROW_REACH, 0.0), rc + Vector2(rr * ARROW_REACH, 0.0), s.edge_w, s.text)
			if not manual:
				# Down brakes (hot), a flick up boosts (accent).
				_mesh.line(rc + Vector2(0.0, rr), rc + Vector2(0.0, rr * ARROW_REACH), s.edge_w, s.hot)
				_mesh.line(rc - Vector2(0.0, rr), rc - Vector2(0.0, rr * ARROW_REACH), s.edge_w, s.accent)
	elif not manual:
		# Gyro + auto: hold anywhere to brake (a soft touch in the middle).
		var tc := _p(ph, 0.5, RING_Y)
		_mesh.ngon(tc, ph.size.y * RING_R, RING_SIDES, Color(s.hot, ZONE_A), Color(s.hot, RING_FILL_A * 2.0), s.edge_w)
	if manual:
		# The gas column on the thumb side (gas pedal, boost cap on top) and the brake:
		# beside it inward (drag), or on the other side (gyro).
		var pw := ph.size.x * PEDAL_W
		var gh := ph.size.y * PEDAL_H
		var ch := ph.size.y * CAP_H
		var bottom := ph.end.y - ph.size.y * PEDAL_MARGIN
		var gx := _p(ph, thumb_x, 0.0).x - pw * 0.5
		var gas := Rect2(gx, bottom - gh, pw, gh)
		_mesh.panel(gas, s.bevel_control, s.panel_fill, s.text, s.edge_w)
		_mesh.panel(Rect2(gx, gas.position.y - ch, pw, ch), s.bevel_control, Color(s.accent, RING_FILL_A * 2.0),
				s.accent, s.edge_w)
		var bx := gx - pw - ph.size.x * PEDAL_GAP if not left_handed else gx + pw + ph.size.x * PEDAL_GAP
		if gyro:
			bx = _p(ph, other_x, 0.0).x - pw * 0.5
		_mesh.panel(Rect2(bx, bottom - gh, pw, gh), s.bevel_control, s.panel_fill, s.hot, s.edge_w)
	_mesh.flush(self)
	draw_set_transform(Vector2.ZERO, 0.0)
	if gyro:
		# Two arcs either side: tilt.
		var r := size.y * TILT_ARC_R
		for side: float in [-1.0, 1.0]:
			var ac := c + Vector2(side * size.x * TILT_ARC_X, 0.0)
			var a0 := (0.0 if side > 0.0 else PI) - TILT_ARC_SPAN
			draw_arc(ac, r, a0, a0 + TILT_ARC_SPAN * 2.0, ARC_POINTS, s.accent, s.edge_w, true)


## The faceted steering wheel of ControlsOverlay._draw_wheel at rest, centred on `c`:
## the rim (quads between two n-gons), three spokes, the opaque hub and the solid
## 12 o'clock facet; a subtle panel fill with accent edges. Proportions, facets and
## alphas from ControlsTuning, so the two always match.
func _wheel(c: Vector2, radius: float) -> void:
	var s := style
	var ct := _controls
	var n := clampi(ct.wheel_facets, 3, HudMesh.MAX_LOOP)
	var inner := radius * Units.pct_to_frac(ct.wheel_rim_inner_pct)
	var hub_r := radius * Units.pct_to_frac(ct.wheel_hub_pct)
	var spoke_half := radius * Units.pct_to_frac(ct.wheel_spoke_width_pct) * 0.5
	var fill := Color(s.panel, Units.pct_to_frac(ct.overlay_idle_alpha_pct))
	var edge := Color(s.accent, Units.pct_to_frac(ct.wheel_edge_alpha_pct))
	HudDraw.ngon(c, radius, n, _outer)
	HudDraw.ngon(c, inner, n, _inner)
	for i in n:
		var j := (i + 1) % n
		_mesh.quad(_outer[i], _outer[j], _inner[j], _inner[i], fill, fill, fill, fill)
	for base: float in ControlsOverlay.SPOKE_ANGLES:
		var dir := Vector2.from_angle(base)
		var side := Vector2(-dir.y, dir.x) * spoke_half
		_mesh.quad(c + dir * (hub_r * 0.5) + side, c + dir * inner + side, c + dir * inner - side,
				c + dir * (hub_r * 0.5) - side, fill, fill, fill, fill)
	var half := PI / float(n)
	var m0 := Vector2.from_angle(ControlsOverlay.MARKER_ANGLE - half)
	var m1 := Vector2.from_angle(ControlsOverlay.MARKER_ANGLE + half)
	_mesh.quad(c + m0 * radius, c + m1 * radius, c + m1 * inner, c + m0 * inner, s.accent, s.accent, s.accent,
			s.accent)
	_mesh.edge(_outer, n, s.edge_w, edge)
	_mesh.edge(_inner, n, s.edge_w, edge)
	for base: float in ControlsOverlay.SPOKE_ANGLES:
		var dir := Vector2.from_angle(base)
		var side := Vector2(-dir.y, dir.x) * spoke_half
		_mesh.line(c + dir * hub_r + side, c + dir * inner + side, s.edge_w, edge)
		_mesh.line(c + dir * hub_r - side, c + dir * inner - side, s.edge_w, edge)
	_mesh.ngon(c, hub_r, ControlsOverlay.FACETS, Color(s.panel, 1.0), edge, s.edge_w)


## A point at fractions (fx, fy) of `r`.
static func _p(r: Rect2, fx: float, fy: float) -> Vector2:
	return r.position + r.size * Vector2(fx, fy)


## Proportions of the sketch (fractions of the phone; look, not tuning).
const PHONE_SCALE := 0.84   # lint: allow-number sketch proportion
const TILT_RAD := -0.14   # lint: allow-number sketch proportion
const HORIZON := 0.3   # lint: allow-number sketch proportion
const ROAD_NEAR_L := 0.28   # lint: allow-number sketch proportion
const ROAD_FAR_L := 0.47   # lint: allow-number sketch proportion
const ROAD_A := 0.45   # lint: allow-number sketch proportion
const THUMB_X := 0.78   # lint: allow-number sketch proportion
const RING_Y := 0.62   # lint: allow-number sketch proportion
const RING_R := 0.13   # lint: allow-number sketch proportion
const RING_SIDES := 16   # HudMesh.MAX_LOOP
const RING_FILL_A := 0.18   # lint: allow-number sketch proportion
const DOT_OFFSET := 0.45   # lint: allow-number sketch proportion
const DOT_R := 0.28   # lint: allow-number sketch proportion
const ARROW_REACH := 1.7   # lint: allow-number sketch proportion
## The wheel (radius, fraction of the phone's height: the in-game 2.4 cm on a phone) and
## its steer strokes (from / to, fractions of the radius, outside the rim).
const WHEEL_R := 0.17   # lint: allow-number sketch proportion
const STROKE_FROM := 1.18   # lint: allow-number sketch proportion
const STROKE_TO := 1.55   # lint: allow-number sketch proportion
const ZONE_A := 0.1   # lint: allow-number sketch proportion
const PEDAL_W := 0.075   # lint: allow-number sketch proportion
const PEDAL_H := 0.24   # lint: allow-number sketch proportion
const CAP_H := 0.1   # lint: allow-number sketch proportion
const PEDAL_MARGIN := 0.07   # lint: allow-number sketch proportion
const PEDAL_GAP := 0.025   # lint: allow-number sketch proportion
const TILT_ARC_R := 0.5   # lint: allow-number sketch proportion
const TILT_ARC_X := 0.02   # lint: allow-number sketch proportion
const TILT_ARC_SPAN := 0.35   # lint: allow-number sketch proportion
const ARC_POINTS := 16
