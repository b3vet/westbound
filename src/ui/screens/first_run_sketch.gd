class_name FirstRunSketch
extends Control
## A small sketch of a control layout on a landscape phone, for the chooser. Spec:
## Controls (the four layouts: drag + auto one thumb; drag + manual steer left, gas
## right; gyro + auto tilt, hold to brake; gyro + manual pedals both sides; mirrored for
## left-handed play). WP8.1; docs/SCREENS.md → First run. Plan D9: the gas pedal carries
## the boost cap on top, the brake sits beside it.
##
## Drawn in the design system's shapes (HudMesh: chamfered panels, neon edges, accent)
## as fractions of the phone, so it scales with the space it gets. Redraws only when the
## layout changes. Never takes touches.

var style: HudStyle
var steering: StringName = &"drag"
var throttle: StringName = &"auto"
var left_handed: bool = false
## _draw calls (tests: an unchanged layout does not redraw).
var redraws: int = 0

var _mesh := HudMesh.new()
var _ring := PackedVector2Array()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_ring.resize(HudDraw.CHAMFER_POINTS)


func setup(s: HudStyle) -> void:
	style = s
	queue_redraw()


func set_layout(steer: StringName, throttle_mode: StringName, mirrored: bool) -> void:
	if steer == steering and throttle_mode == throttle and mirrored == left_handed:
		return
	steering = steer
	throttle = throttle_mode
	left_handed = mirrored
	queue_redraw()


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
