class_name ControlsLayout
extends RefCounted
## Where each touch control sits for the current layout. Spec: Controls (the four
## layouts table, Mirroring); UI → HUD elements (controls overlay, safe areas); plan
## D9 (one thumb per side: the gas pedal carries the boost cap). docs/CONTROLS.md →
## Layouts.
##
## One instance, owned by PlayerInput: the hub hit-tests touches against it and the
## overlay draws it, so they can never disagree.
##
##   drag + auto    drag zone = the whole screen (GUI buttons take their own touches
##                  first, since the hub listens in _unhandled_input)
##   drag + manual  drag zone = the left half; the gas column (boost cap directly on
##                  top of the gas pedal) bottom-right, the brake pedal beside it
##                  (inward, bottom-aligned): all within reach of the right thumb
##   gyro + auto    hold zone = the whole screen: touch and hold brakes, swipe up boosts
##   gyro + manual  brake pedal bottom-left, the gas column bottom-right
##   left-handed    every rect mirrored across the safe area's centre
##
## Rects are in canvas pixels, inside the safe area. Sizes come from ControlsTuning in
## physical cm, converted with px_per_cm (DPI or the fallback, see PlayerInput), and
## multiplied by the controls_scale setting (the margin to the safe-area edge is not).

enum Zone { NONE, DRAG, HOLD, GAS, BRAKE, BOOST }

const DRAG := &"drag"
const GYRO := &"gyro"

var steering_mode: StringName = DRAG
var throttle_mode: StringName = ThrottleInput.AUTO
var mirrored: bool = false
var px_per_cm: float = 1.0
var scale: float = 1.0
var full: Rect2 = Rect2()
var safe: Rect2 = Rect2()

## Zero-size rects are absent in this layout.
var drag_zone: Rect2 = Rect2()
var hold_zone: Rect2 = Rect2()
var gas_rect: Rect2 = Rect2()
var brake_rect: Rect2 = Rect2()
## The boost cap: directly on top of the gas pedal, same width.
var boost_rect: Rect2 = Rect2()
## The joined gas control: gas pedal + boost cap.
var gas_control: Rect2 = Rect2()
## A pedal finger switches pedals only this far outside its own control (canvas px).
var capture_px: float = 0.0
## Below the cap by this much before sliding up boosts again (canvas px).
var boost_rearm_px: float = 0.0


func build(tuning: ControlsTuning, full_rect: Rect2, safe_rect: Rect2, pixels_per_cm: float,
		steering: StringName, throttle: StringName, left_handed: bool, size_scale: float = 1.0) -> void:
	full = full_rect
	safe = safe_rect
	px_per_cm = pixels_per_cm
	scale = size_scale
	steering_mode = steering
	throttle_mode = throttle
	mirrored = left_handed
	drag_zone = Rect2()
	hold_zone = Rect2()
	gas_rect = Rect2()
	brake_rect = Rect2()
	boost_rect = Rect2()
	gas_control = Rect2()

	var manual := throttle == ThrottleInput.MANUAL
	var cm := px_per_cm * scale
	var margin := tuning.controls_margin_cm * px_per_cm
	var gap := tuning.controls_gap_cm * cm
	var pedal := Vector2(tuning.pedal_width_cm, tuning.pedal_height_cm) * cm
	var cap_h := tuning.boost_cap_height_cm * cm
	var brake := Vector2(tuning.brake_width_cm, tuning.brake_height_cm) * cm
	capture_px = tuning.pedal_capture_cm * cm
	boost_rearm_px = tuning.boost_cap_rearm_cm * cm
	var right := safe.end.x - margin
	var bottom := safe.end.y - margin

	if manual:
		gas_rect = Rect2(right - pedal.x, bottom - pedal.y, pedal.x, pedal.y)
		boost_rect = Rect2(gas_rect.position.x, gas_rect.position.y - cap_h, pedal.x, cap_h)
		var brake_x := safe.position.x + margin
		if steering != GYRO:
			brake_x = gas_rect.position.x - gap - brake.x
		brake_rect = Rect2(brake_x, bottom - brake.y, brake.x, brake.y)
	if steering == GYRO:
		if not manual:
			hold_zone = full
	elif manual:
		drag_zone = Rect2(full.position, Vector2(full.size.x * 0.5, full.size.y))
	else:
		drag_zone = full

	if mirrored:
		gas_rect = _mirror(gas_rect)
		brake_rect = _mirror(brake_rect)
		boost_rect = _mirror(boost_rect)
		drag_zone = _mirror_full(drag_zone)
	if has(gas_rect):
		gas_control = gas_rect.merge(boost_rect)


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


## Whether a gas finger at `pos` is on the boost cap: anywhere above the joint line
## (the thumb is captured, so a slide up and slightly sideways still counts).
func above_gas_joint(y: float) -> bool:
	return has(gas_rect) and y < gas_rect.position.y


## A gas finger switches to braking only when it is on the brake pedal and clearly off
## the gas control (outside it by more than the capture margin).
func brake_takes(pos: Vector2) -> bool:
	return _hit(brake_rect, pos) and not gas_control.grow(capture_px).has_point(pos)


## A brake finger switches to gas only when it is on the gas control and clearly off
## the brake pedal.
func gas_takes(pos: Vector2) -> bool:
	return _hit(gas_control, pos) and not brake_rect.grow(capture_px).has_point(pos)


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
