class_name ControlsLayout
extends RefCounted
## Where each touch control sits for the current layout. Spec: Controls (the four
## layouts table, Mirroring); UI → HUD elements (controls overlay, safe areas).
## docs/CONTROLS.md → Layouts.
##
## One instance, owned by PlayerInput: the hub hit-tests touches against it and the
## overlay draws it, so they can never disagree.
##
##   drag + auto    drag zone = the whole screen (GUI buttons take their own touches
##                  first, since the hub listens in _unhandled_input)
##   drag + manual  drag zone = the left half; gas pedal bottom-right with the boost
##                  (top) and brake (bottom) buttons in a column beside it
##   gyro + auto    hold zone = the whole screen: touch and hold brakes, swipe up boosts
##   gyro + manual  brake pedal bottom-left, gas pedal bottom-right, boost above gas
##   left-handed    every rect mirrored across the safe area's centre
##
## Rects are in canvas pixels, inside the safe area. Sizes come from ControlsTuning in
## physical cm, converted with px_per_cm (DPI or the fallback, see PlayerInput).

enum Zone { NONE, DRAG, HOLD, GAS, BRAKE, BOOST }

const DRAG := &"drag"
const GYRO := &"gyro"

var steering_mode: StringName = DRAG
var throttle_mode: StringName = ThrottleInput.AUTO
var mirrored: bool = false
var px_per_cm: float = 1.0
var full: Rect2 = Rect2()
var safe: Rect2 = Rect2()

## Zero-size rects are absent in this layout.
var drag_zone: Rect2 = Rect2()
var hold_zone: Rect2 = Rect2()
var gas_rect: Rect2 = Rect2()
var brake_rect: Rect2 = Rect2()
var boost_rect: Rect2 = Rect2()


func build(tuning: ControlsTuning, full_rect: Rect2, safe_rect: Rect2, pixels_per_cm: float,
		steering: StringName, throttle: StringName, left_handed: bool) -> void:
	full = full_rect
	safe = safe_rect
	px_per_cm = pixels_per_cm
	steering_mode = steering
	throttle_mode = throttle
	mirrored = left_handed
	drag_zone = Rect2()
	hold_zone = Rect2()
	gas_rect = Rect2()
	brake_rect = Rect2()
	boost_rect = Rect2()

	var manual := throttle == ThrottleInput.MANUAL
	var margin := tuning.controls_margin_cm * px_per_cm
	var gap := tuning.controls_gap_cm * px_per_cm
	var pedal := Vector2(tuning.pedal_width_cm, tuning.pedal_height_cm) * px_per_cm
	var button := tuning.button_size_cm * px_per_cm
	var right := safe.end.x - margin
	var bottom := safe.end.y - margin

	if steering == GYRO:
		if manual:
			gas_rect = Rect2(right - pedal.x, bottom - pedal.y, pedal.x, pedal.y)
			brake_rect = Rect2(safe.position.x + margin, bottom - pedal.y, pedal.x, pedal.y)
			boost_rect = Rect2(gas_rect.position.x + (pedal.x - button) * 0.5,
					gas_rect.position.y - gap - button, button, button)
		else:
			hold_zone = full
	else:
		if manual:
			gas_rect = Rect2(right - pedal.x, bottom - pedal.y, pedal.x, pedal.y)
			var col_x := gas_rect.position.x - gap - button
			boost_rect = Rect2(col_x, gas_rect.position.y, button, button)
			var brake_top := boost_rect.end.y + gap
			brake_rect = Rect2(col_x, brake_top, button, gas_rect.end.y - brake_top)
			drag_zone = Rect2(full.position, Vector2(full.size.x * 0.5, full.size.y))
		else:
			drag_zone = full

	if mirrored:
		gas_rect = _mirror(gas_rect)
		brake_rect = _mirror(brake_rect)
		boost_rect = _mirror(boost_rect)
		drag_zone = _mirror_full(drag_zone)


## Which control a touch landing at `pos` belongs to. Buttons and pedals first.
func zone_at(pos: Vector2) -> Zone:
	if _hit(boost_rect, pos):
		return Zone.BOOST
	if _hit(gas_rect, pos):
		return Zone.GAS
	if _hit(brake_rect, pos):
		return Zone.BRAKE
	if _hit(drag_zone, pos):
		return Zone.DRAG
	if _hit(hold_zone, pos):
		return Zone.HOLD
	return Zone.NONE


## How far up the brake pedal `y` sits: 0 at the bottom edge, 1 at the top.
func brake_up_frac(y: float) -> float:
	if brake_rect.size.y <= 0.0:
		return 0.0
	return clampf((brake_rect.end.y - y) / brake_rect.size.y, 0.0, 1.0)


func has(r: Rect2) -> bool:
	return r.size.x > 0.0 and r.size.y > 0.0


func _hit(r: Rect2, pos: Vector2) -> bool:
	return has(r) and r.has_point(pos)


func _mirror(r: Rect2) -> Rect2:
	if not has(r):
		return r
	return Rect2(safe.position.x + safe.end.x - r.end.x, r.position.y, r.size.x, r.size.y)


func _mirror_full(r: Rect2) -> Rect2:
	if not has(r):
		return r
	return Rect2(full.position.x + full.end.x - r.end.x, r.position.y, r.size.x, r.size.y)
