class_name DragControl
extends RefCounted
## Drag steering: one thumb, a floating anchor. Spec: Controls → Drag steering
## (drag_control.gd). docs/CONTROLS.md → Drag.
##
## - The anchor appears where the finger lands (the hub routes only touches that
##   land inside the steering zone here).
## - steer = sign(dx) · curve(|dx| / max_drag), dx = thumb.x - anchor.x.
## - Anchor follow: past max_drag (per axis) the anchor is dragged along, so the
##   offset never exceeds max_drag and re-centering is always one small move.
## - Release: steer returns to 0 linearly over `release_s` (from whatever it was).
## - Auto-throttle verticals (`verticals = true`):
##     dragging down more than `brake_threshold` · max_drag brakes, proportionally
##     (0 at the threshold, 1 at max_drag);
##     an upward flick faster than `flick_min_mps` (finger speed, physical) fires boost.
##
## Positions are canvas pixels; `px_per_m` converts physical distance (DPI) to them.
## Times are seconds from any monotonic clock (the hub passes real time; tests pass
## scripted times). Allocation-free: only floats and Vector2 values.

## Physical max drag, dead zone (fraction of max_drag), curve exponent.
var max_drag_px: float = 1.0
var dead_zone: float = 0.0
var exponent: float = 1.0
var release_s: float = 0.0
## Auto mode: down-drag brake and flick boost.
var verticals: bool = false
var brake_threshold: float = 0.0
var px_per_m: float = 1.0
var flick := FlickMeter.new()

## Outputs.
var steer: float = 0.0
var brake: float = 0.0

## Touch state (read by the overlay and the preview).
var active: bool = false
var touch_index: int = -1
var anchor: Vector2 = Vector2.ZERO
var thumb: Vector2 = Vector2.ZERO

var _release_rate: float = 0.0
var _boost_pending: bool = false


## `max_drag_m` is physical (already scaled by sensitivity); `px_per_m` from DPI.
func configure(tuning: ControlsTuning, max_drag_m: float, dead_zone_frac: float,
		curve_exponent: float, pixels_per_m: float, auto_verticals: bool) -> void:
	px_per_m = pixels_per_m
	max_drag_px = maxf(max_drag_m * pixels_per_m, 1.0)
	dead_zone = dead_zone_frac
	exponent = curve_exponent
	release_s = tuning.drag_release_s()
	verticals = auto_verticals
	brake_threshold = tuning.drag_brake_threshold_frac()
	flick.configure(tuning, pixels_per_m)
	if not verticals:
		brake = 0.0


func reset() -> void:
	active = false
	touch_index = -1
	steer = 0.0
	brake = 0.0
	_release_rate = 0.0
	_boost_pending = false


func touch_down(index: int, pos: Vector2, time_s: float) -> void:
	active = true
	touch_index = index
	anchor = pos
	thumb = pos
	flick.start(pos, time_s)
	_update_values()


func touch_move(index: int, pos: Vector2, time_s: float) -> void:
	if not active or index != touch_index:
		return
	thumb = pos
	# Anchor follow, per axis: the offset never exceeds max_drag.
	var dx := thumb.x - anchor.x
	if dx > max_drag_px:
		anchor.x = thumb.x - max_drag_px
	elif dx < -max_drag_px:
		anchor.x = thumb.x + max_drag_px
	var dy := thumb.y - anchor.y
	if dy > max_drag_px:
		anchor.y = thumb.y - max_drag_px
	elif dy < -max_drag_px:
		anchor.y = thumb.y + max_drag_px
	if flick.move(pos, time_s) and verticals:
		_boost_pending = true
	_update_values()


func touch_up(index: int, _time_s: float) -> void:
	if not active or index != touch_index:
		return
	active = false
	touch_index = -1
	brake = 0.0
	if release_s > 0.0:
		_release_rate = absf(steer) / release_s
	else:
		steer = 0.0


## Per tick: the release ramp.
func advance(dt: float) -> void:
	if active or steer == 0.0:
		return
	steer = move_toward(steer, 0.0, _release_rate * dt)


## Edge-triggered: true once per flick.
func take_boost() -> bool:
	var b := _boost_pending
	_boost_pending = false
	return b


## Normalized offsets (for the preview): x in -1..1, y in -1..1 (+ down).
func offset_norm() -> Vector2:
	return (thumb - anchor) / max_drag_px


func _update_values() -> void:
	var off := thumb - anchor
	steer = SteeringInput.curve(off.x / max_drag_px, dead_zone, exponent)
	if verticals:
		brake = down_brake(off.y / max_drag_px, brake_threshold)
	else:
		brake = 0.0


## Down-drag brake: 0 up to the threshold, rising linearly to 1 at max_drag.
static func down_brake(down_norm: float, threshold: float) -> float:
	if down_norm <= threshold:
		return 0.0
	return clampf((down_norm - threshold) / (1.0 - threshold), 0.0, 1.0)
