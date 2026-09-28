class_name DampedSpring
extends RefCounted
## Closed-form damped harmonic spring for the camera rig. Spec: Cameras -> "Spring
## follow" (spring-damped follow on position and heading, as in cool_drive's camera.js).
##
## Each step solves x'' = w^2 (target - x) - 2 z w x' exactly over dt with the target
## held (Ryan Juckett's "damped springs" coefficients), so a step response is identical
## whatever the step size: 30, 60 and 120 Hz stepping land on the same curve. Handles
## under-damped (z < 1), critical (z = 1) and over-damped (z > 1). A frequency of 0 (or
## less) makes it rigid: the value jumps to the target.
##
## One instance holds either a scalar (`value`, `velocity`, `step`) or a Vector3
## (`vec_value`, `vec_velocity`, `step_vec`). Allocation-free per step; coefficients are
## cached per (frequency, damping, dt).

## |z - 1| below this counts as critically damped (avoids 1/sqrt(z^2 - 1) blow-up).
const CRITICAL_BAND := 1e-4

var frequency_hz: float = 0.0
var damping_ratio: float = 1.0

var value: float = 0.0
var velocity: float = 0.0
var vec_value: Vector3 = Vector3.ZERO
var vec_velocity: Vector3 = Vector3.ZERO

var _c_dt: float = -1.0
var _c_hz: float = -1.0
var _c_zeta: float = -1.0
var _pp: float = 1.0
var _pv: float = 0.0
var _vp: float = 0.0
var _vv: float = 1.0


func _init(hz: float = 0.0, zeta: float = 1.0) -> void:
	configure(hz, zeta)


func configure(hz: float, zeta: float) -> void:
	frequency_hz = hz
	damping_ratio = zeta


func is_rigid() -> bool:
	return frequency_hz <= 0.0


func reset(v: float) -> void:
	value = v
	velocity = 0.0


func reset_vec(v: Vector3) -> void:
	vec_value = v
	vec_velocity = Vector3.ZERO


## Advances the scalar state toward `target` over dt. Returns the new value.
func step(target: float, dt: float) -> float:
	if is_rigid() or dt <= 0.0:
		if is_rigid():
			reset(target)
		return value
	_update_coefficients(dt)
	var x := value - target
	value = target + x * _pp + velocity * _pv
	velocity = x * _vp + velocity * _vv
	return value


## Advances the Vector3 state toward `target` over dt. Returns the new value.
func step_vec(target: Vector3, dt: float) -> Vector3:
	if is_rigid() or dt <= 0.0:
		if is_rigid():
			reset_vec(target)
		return vec_value
	_update_coefficients(dt)
	var x := vec_value - target
	vec_value = target + x * _pp + vec_velocity * _pv
	vec_velocity = x * _vp + vec_velocity * _vv
	return vec_value


func _update_coefficients(dt: float) -> void:
	if dt == _c_dt and frequency_hz == _c_hz and damping_ratio == _c_zeta:
		return
	_c_dt = dt
	_c_hz = frequency_hz
	_c_zeta = damping_ratio
	var w := TAU * frequency_hz
	var z := maxf(damping_ratio, 0.0)
	if absf(z - 1.0) < CRITICAL_BAND:
		var e := exp(-w * dt)
		var te := dt * e
		var tew := te * w
		_pp = tew + e
		_pv = te
		_vp = -w * tew
		_vv = -tew + e
	elif z < 1.0:
		var wz := w * z
		var alpha := w * sqrt(1.0 - z * z)
		var e := exp(-wz * dt)
		var c := cos(alpha * dt)
		var s := sin(alpha * dt)
		var es := e * s
		var ec := e * c
		var ews := e * wz * s / alpha
		_pp = ec + ews
		_pv = es / alpha
		_vp = -es * alpha - wz * ews
		_vv = ec - ews
	else:
		var za := -w * z
		var zb := w * sqrt(z * z - 1.0)
		var z1 := za - zb
		var z2 := za + zb
		var e1 := exp(z1 * dt)
		var e2 := exp(z2 * dt)
		var inv := 1.0 / (2.0 * zb)
		var e1o := e1 * inv
		var e2o := e2 * inv
		var z1e1 := z1 * e1o
		var z2e2 := z2 * e2o
		_pp = e1o * z2 - z2e2 + e2
		_pv = -e1o + e2o
		_vp = (z1e1 - z2e2 + e2) * z2
		_vv = -z1e1 + z2e2
