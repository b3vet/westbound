extends WBTest
## Drag steering. Spec: Controls → Drag steering and Tests ("Drag anchor: the anchor
## follows when the thumb goes past max_drag"), plus the 80 ms release, the auto-mode
## down-drag brake (30% of max_drag) and the flick boost (0.6 m/s).
##
## Scale used here: 40 canvas px per cm, so max_drag (2.5 cm) = 100 px.

const PX_PER_M := 4000.0
const MAX_PX := 100.0
const ORIGIN := Vector2(500.0, 300.0)

var c: ControlsTuning
var d: DragControl


func before_all() -> void:
	c = Tuning.load_default().controls


func before_each() -> void:
	d = _make(true)


func _make(auto_verticals: bool) -> DragControl:
	var dc := DragControl.new()
	dc.configure(c, c.drag_max_m(), c.drag_dead_zone_frac(), c.response_curve_exponent,
			PX_PER_M, auto_verticals)
	return dc


func _at(dx: float, dy: float = 0.0) -> Vector2:
	return ORIGIN + Vector2(dx, dy)


func test_max_drag_is_physical() -> void:
	near(d.max_drag_px, MAX_PX, 1e-9, "2.5 cm at 40 px/cm")


func test_mapping_edge_mid_full() -> void:
	var e := c.response_curve_exponent
	d.touch_down(0, ORIGIN, 0.0)
	eq(d.steer, 0.0, "anchor where the thumb lands")
	eq(d.anchor, ORIGIN)
	d.touch_move(0, _at(4.0), 0.01)
	eq(d.steer, 0.0, "4% dead-zone edge")
	d.touch_move(0, _at(52.0), 0.02)
	near(d.steer, pow(0.5, e), 1e-9, "live-range midpoint")
	d.touch_move(0, _at(100.0), 0.03)
	eq(d.steer, 1.0, "full right at max_drag")
	d.touch_move(0, _at(-52.0), 0.04)
	near(d.steer, -pow(0.5, e), 1e-9, "midpoint left")
	d.touch_move(0, _at(-100.0), 0.05)
	eq(d.steer, -1.0, "full left")


func test_anchor_follows_past_max_drag() -> void:
	d.touch_down(0, ORIGIN, 0.0)
	d.touch_move(0, _at(150.0), 0.1)
	eq(d.anchor.x, ORIGIN.x + 50.0, "anchor dragged along")
	eq(d.steer, 1.0)
	# Re-centering is one small move: back by max_drag from the far point.
	d.touch_move(0, _at(50.0), 0.2)
	eq(d.steer, 0.0, "centred again after moving back max_drag")
	# Past the other side: follows left.
	d.touch_move(0, _at(-200.0), 0.3)
	eq(d.anchor.x, ORIGIN.x - 100.0, "anchor follows left")
	eq(d.steer, -1.0)
	# Within max_drag the anchor stays put.
	var a := d.anchor
	d.touch_move(0, _at(-150.0), 0.4)
	eq(d.anchor, a, "no follow inside max_drag")


func test_release_ramps_to_zero_in_80ms() -> void:
	near(c.drag_release_s(), 0.08, 1e-12)
	var dt := 0.01
	for start_x: float in [100.0, -100.0, 52.0]:
		var dc := _make(true)
		dc.touch_down(0, ORIGIN, 0.0)
		dc.touch_move(0, _at(start_x), 0.1)
		var s0 := dc.steer
		dc.touch_up(0, 0.2)
		eq(dc.steer, s0, "release starts from the held value")
		for i in 4:
			dc.advance(dt)
		near(dc.steer, s0 * 0.5, 1e-9, "halfway at 40 ms from %.2f" % s0)
		for i in 3:
			dc.advance(dt)
		ne(dc.steer, 0.0, "still moving at 70 ms")
		dc.advance(dt)
		near(dc.steer, 0.0, 1e-12, "zero at 80 ms from %.2f" % s0)
		dc.advance(dt)
		eq(dc.steer, 0.0, "stays zero")


func test_down_drag_brake_threshold() -> void:
	near(c.drag_brake_threshold_frac(), 0.3, 1e-12)
	d.touch_down(0, ORIGIN, 0.0)
	d.touch_move(0, _at(0.0, 29.0), 0.1)
	eq(d.brake, 0.0, "below 30%")
	d.touch_move(0, _at(0.0, 30.0), 0.2)
	eq(d.brake, 0.0, "at 30%")
	d.touch_move(0, _at(0.0, 65.0), 0.3)
	near(d.brake, 0.5, 1e-9, "proportional: halfway from 30% to 100%")
	d.touch_move(0, _at(0.0, 100.0), 0.4)
	eq(d.brake, 1.0, "full at max_drag")
	d.touch_move(0, _at(0.0, 180.0), 0.5)
	eq(d.brake, 1.0, "anchor follows down too")
	d.touch_move(0, _at(0.0, 80.0), 0.6)
	eq(d.brake, 0.0, "back up to the (followed) anchor")
	d.touch_move(0, _at(0.0, 180.0), 0.7)
	d.touch_up(0, 0.8)
	eq(d.brake, 0.0, "release lets go of the brake at once")
	eq(d.steer, 0.0, "vertical drag does not steer")


func test_manual_mode_has_no_verticals() -> void:
	var m := _make(false)
	m.touch_down(0, ORIGIN, 0.0)
	m.touch_move(0, _at(0.0, 100.0), 0.1)
	eq(m.brake, 0.0, "manual: down does not brake")
	m.touch_move(0, _at(0.0, -200.0), 0.15)
	check(not m.take_boost(), "manual: flick does not boost")


func test_flick_up_fires_boost_once() -> void:
	near(c.flick_boost_min_mps, 0.6, 1e-12)
	# 0.6 m/s = 2400 px/s here. 100 px over 50 ms = 2000 px/s: not a flick.
	d.touch_down(0, ORIGIN, 0.0)
	d.touch_move(0, _at(0.0, -100.0), 0.05)
	check(not d.take_boost(), "0.5 m/s is too slow")
	# 150 px over 50 ms = 3000 px/s = 0.75 m/s: flick.
	d.touch_move(0, _at(0.0, -250.0), 0.1)
	check(d.take_boost(), "0.75 m/s upward fires boost")
	check(not d.take_boost(), "edge: taken once")
	d.touch_move(0, _at(0.0, -400.0), 0.15)
	check(not d.take_boost(), "one boost per flick while still moving fast")
	d.touch_move(0, _at(0.0, -400.0), 0.2)
	d.touch_move(0, _at(0.0, -550.0), 0.25)
	check(d.take_boost(), "re-armed after slowing down")


func test_sideways_or_down_fast_does_not_boost() -> void:
	d.touch_down(0, ORIGIN, 0.0)
	d.touch_move(0, _at(300.0, -150.0), 0.05)
	check(not d.take_boost(), "fast steering with some upward motion is not a flick")
	d.touch_move(0, _at(300.0, 150.0), 0.1)
	check(not d.take_boost(), "fast down is not a flick")


func test_jitter_inside_window_is_ignored() -> void:
	d.touch_down(0, ORIGIN, 0.0)
	# 20 px in 5 ms would be 4000 px/s, but the window is 40 ms.
	d.touch_move(0, _at(0.0, -20.0), 0.005)
	check(not d.take_boost(), "no speed measured inside the window")


func test_second_finger_is_ignored() -> void:
	d.touch_down(0, ORIGIN, 0.0)
	d.touch_move(1, _at(100.0), 0.1)
	eq(d.steer, 0.0, "only the steering finger moves the thumb")
	d.touch_up(1, 0.2)
	check(d.active, "lifting another finger does not release")
	d.touch_up(0, 0.3)
	check(not d.active)
