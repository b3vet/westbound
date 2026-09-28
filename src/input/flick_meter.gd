class_name FlickMeter
extends RefCounted
## Upward-flick detector for one finger. Spec: Controls → Drag steering ("a quick
## upward flick (over 0.6 m/s of finger speed) fires boost") and the gyro + auto
## layout ("swipe up to boost"). docs/CONTROLS.md → Flick.
##
## Finger velocity is measured between samples at least `window_s` apart (event
## jitter over a few ms can't fake a speed). A flick fires when the upward speed
## exceeds the threshold and dominates the sideways speed (hard steering never
## boosts). One boost per flick: it re-arms once the upward speed falls below
## `rearm` (or on the next touch). Canvas pixels, seconds; allocation-free.

var min_px_per_s: float = 0.0
var rearm_px_per_s: float = 0.0
var window_s: float = 0.0
## Last measured velocity, canvas px/s (+y down).
var velocity: Vector2 = Vector2.ZERO
## True once this touch has fired (the gyro hold zone stops braking for it).
var fired: bool = false

var _ref_pos: Vector2 = Vector2.ZERO
var _ref_t: float = 0.0
var _armed: bool = true


func configure(tuning: ControlsTuning, px_per_m: float) -> void:
	min_px_per_s = tuning.flick_boost_min_mps * px_per_m
	rearm_px_per_s = min_px_per_s * tuning.flick_rearm_frac()
	window_s = tuning.flick_window_s()


func start(pos: Vector2, time_s: float) -> void:
	_ref_pos = pos
	_ref_t = time_s
	_armed = true
	fired = false
	velocity = Vector2.ZERO


## False from a flick until the finger slows down again (the re-arm).
func is_armed() -> bool:
	return _armed


## Returns true on the sample that completes a flick.
func move(pos: Vector2, time_s: float) -> bool:
	var span := time_s - _ref_t
	if span <= 0.0 or span < window_s:
		return false
	velocity = (pos - _ref_pos) / span
	_ref_pos = pos
	_ref_t = time_s
	var up := -velocity.y
	if _armed:
		if up > min_px_per_s and up > absf(velocity.x):
			_armed = false
			fired = true
			return true
	elif up < rearm_px_per_s:
		_armed = true
	return false
