class_name CarVisual
extends Node3D
## Visual body motion of a driven car. Spec: Car physics and feel → Visual body motion
## ("visual only, never feeds back into physics"); Lives → Damage (hook only).
##
## Child of PlayerCar, parent of the car model (CarModel.root). PlayerCar places the
## whole car from road space; the body's yaw is already that node's yaw. Here, per
## physics tick (PlayerCar calls tick() after VehiclePhysics.step, so physics
## interpolation smooths it like the car itself):
##   - body roll (up to body_roll_max_deg) from lateral acceleration and pitch (up to
##     body_pitch_max_deg) from longitudinal acceleration, each through a spring-damper
##     (body_spring_hz, body_damping_ratio), integrated exactly for any dt and clamped
##     to the maximum. The sprung nodes (Body, Lights, Interior, Damage) turn about the
##     hub-height axis; wheels stay planted.
##   - wheels spin at v / wheel radius; the front pivots show the steer angle.
##   - brake lights while brake input >= brake_light_min_input_pct.
##   - the Interior's SteeringWheel turns with the steer angle.
## Reads VehicleState and VehicleInput only; never writes them. tick() is
## allocation-free.
##
## Signs: roll > 0 leans the body to the left (turning right, accel_lat > 0, the body
## leans out to the left); pitch > 0 lifts the nose (accelerating squats the rear).

## Current body roll and pitch (rad, after the clamp) and their spring velocities.
var roll: float = 0.0
var pitch: float = 0.0
var roll_rate: float = 0.0
var pitch_rate: float = 0.0
## Wheel rotation (rad, wrapped to [0, TAU)); increases rolling forward.
var wheel_angle: float = 0.0
var brake_lights_on: bool = false
## True while braking hard at speed (tire smoke and squeal, for the feel layer).
var tire_smoke: bool = false
var damage_level: int = 0

var model: CarModel

var _roll_max: float = 0.0
var _pitch_max: float = 0.0
var _roll_per_accel: float = 0.0
var _pitch_per_accel: float = 0.0
var _omega: float = 0.0
var _zeta: float = 0.0
var _brake_min: float = 0.0
var _wheel_ratio: float = 0.0
var _smoke_decel: float = 0.0
var _smoke_speed: float = 0.0
var _pivot := Vector3.ZERO
var _radius: float = 1.0
## Unclamped spring positions (the displayed roll/pitch are clamped copies).
var _roll_x: float = 0.0
var _pitch_x: float = 0.0

var _sprung: Array[Node3D] = []
var _sprung_rest: Array[Transform3D] = []
var _pivots: Array[Node3D] = []
var _pivot_rest: Array[Transform3D] = []
var _spinners: Array[Node3D] = []
var _spinner_rest: Array[Transform3D] = []
var _brakes: Array[Node3D] = []
var _steering_wheel: Node3D
var _steering_rest := Transform3D.IDENTITY

# Exact spring step coefficients for the last dt: x' = a x + b v, v' = c x + e v.
var _dt_cached: float = -1.0
var _ka: float = 0.0
var _kb: float = 0.0
var _kc: float = 0.0
var _ke: float = 0.0

## Damping ratios at or above 1 are treated as just under critical (the exact step
## below is the underdamped solution).
const MAX_ZETA := 0.999   # lint: allow-number numerical bound, not a tuning value


## Takes over `car_model` (already a child of this node or about to be) and reads the
## body-motion tuning. Load time; allocates.
func bind(car_model: CarModel, tuning: VehicleTuning) -> void:
	model = car_model
	_roll_max = deg_to_rad(tuning.body_roll_max_deg)
	_pitch_max = deg_to_rad(tuning.body_pitch_max_deg)
	_roll_per_accel = _roll_max / tuning.body_roll_full_accel_mps2
	_pitch_per_accel = _pitch_max / tuning.body_pitch_full_accel_mps2
	_omega = TAU * tuning.body_spring_hz
	_zeta = minf(tuning.body_damping_ratio, MAX_ZETA)
	_brake_min = Units.pct_to_frac(tuning.brake_light_min_input_pct)
	_wheel_ratio = tuning.steering_wheel_ratio_factor
	_smoke_decel = tuning.tire_smoke_min_decel_mps2
	_smoke_speed = Units.kmh_to_mps(tuning.tire_smoke_min_speed_kmh)
	_dt_cached = -1.0
	_radius = car_model.wheel_radius_m if car_model.wheel_radius_m > 0.0 else 1.0
	_pivot = Vector3(0.0, car_model.wheel_radius_m, 0.0)

	_sprung.clear()
	_sprung_rest.clear()
	for n: Node3D in [car_model.body, car_model.lights, car_model.interior, car_model.damage]:
		if n != null:
			_sprung.append(n)
			_sprung_rest.append(n.transform)
	_pivots.clear()
	_pivot_rest.clear()
	for i in 2:   # front pivots steer
		if car_model.wheels[i] != null:
			_pivots.append(car_model.wheels[i])
			_pivot_rest.append(car_model.wheels[i].transform)
	_spinners.clear()
	_spinner_rest.clear()
	for i in car_model.wheels.size():
		for n: Node3D in [car_model.rims[i], car_model.tires[i]]:
			if n != null:
				_spinners.append(n)
				_spinner_rest.append(n.transform)
	_brakes.clear()
	for key: StringName in [&"brake_L", &"brake_R"]:
		var l: Node3D = car_model.light.get(key)
		if l != null:
			_brakes.append(l)
	_steering_wheel = car_model.steering_wheel
	if _steering_wheel != null:
		_steering_rest = _steering_wheel.transform
	reset()


## Settles the body (no roll, pitch or spring motion) and turns the brake lights off.
func reset() -> void:
	roll = 0.0
	pitch = 0.0
	roll_rate = 0.0
	pitch_rate = 0.0
	_roll_x = 0.0
	_pitch_x = 0.0
	tire_smoke = false
	_set_brake_lights(false)
	_apply(0.0)


## One visual tick. Reads `state` and `input`; never writes them. Allocation-free.
func tick(dt: float, state: VehicleState, input: VehicleInput) -> void:
	if model == null or dt <= 0.0:
		return
	_update_coefficients(dt)
	var roll_target := clampf(state.accel_lat * _roll_per_accel, -_roll_max, _roll_max)
	var pitch_target := clampf(state.accel_long * _pitch_per_accel, -_pitch_max, _pitch_max)
	var x := _roll_x - roll_target
	var nx := _ka * x + _kb * roll_rate
	roll_rate = _kc * x + _ke * roll_rate
	_roll_x = nx + roll_target
	x = _pitch_x - pitch_target
	nx = _ka * x + _kb * pitch_rate
	pitch_rate = _kc * x + _ke * pitch_rate
	_pitch_x = nx + pitch_target
	roll = clampf(_roll_x, -_roll_max, _roll_max)
	pitch = clampf(_pitch_x, -_pitch_max, _pitch_max)

	wheel_angle = fposmod(wheel_angle + state.v / _radius * dt, TAU)
	var braking := input != null and input.brake >= _brake_min
	if braking != brake_lights_on:
		_set_brake_lights(braking)
	tire_smoke = braking and state.accel_long <= -_smoke_decel and state.v >= _smoke_speed
	_apply(state.steer_angle)


## Wheel spin rate (rad/s) for a forward speed: v / wheel radius.
func wheel_spin_rate(v: float) -> float:
	return v / _radius


## Damage hook (spec: Lives → Damage). Level 1 is the first-hit look: smoke from the
## smoke_hood marker and one flickering headlight on the placeholder models.
## TODO(Phase 4, WP4.1): smoke particles at model.marker(&"smoke_hood") and the
## headlight_L flicker; real damage states swap the Damage meshes.
func set_damage_level(level: int) -> void:
	damage_level = maxi(level, 0)


func _apply(steer_angle: float) -> void:
	var b := Basis(Vector3.BACK, roll) * Basis(Vector3.RIGHT, pitch)
	var sprung := Transform3D(b, _pivot - b * _pivot)
	for i in _sprung.size():
		_sprung[i].transform = sprung * _sprung_rest[i]
	# Right-positive steer turns the wheels right: a negative Godot yaw.
	var steer := Basis(Vector3.UP, -steer_angle)
	for i in _pivots.size():
		var r := _pivot_rest[i]
		_pivots[i].transform = Transform3D(steer * r.basis, r.origin)
	# Rolling forward (-Z) turns the top of the wheel forward: negative about +X.
	var spin := Transform3D(Basis(Vector3.RIGHT, -wheel_angle), Vector3.ZERO)
	for i in _spinners.size():
		_spinners[i].transform = spin * _spinner_rest[i]
	if _steering_wheel != null:
		# Seen from the driver (looking along -Z), turning right is clockwise.
		_steering_wheel.transform = _steering_rest \
			* Transform3D(Basis(Vector3.BACK, -steer_angle * _wheel_ratio), Vector3.ZERO)


func _set_brake_lights(on: bool) -> void:
	brake_lights_on = on
	for l in _brakes:
		l.visible = on


## Exact discretization of x'' = -w^2 x - 2 z w x' over dt (underdamped), cached per dt.
func _update_coefficients(dt: float) -> void:
	if dt == _dt_cached:
		return
	_dt_cached = dt
	var sigma := _zeta * _omega
	var wd := _omega * sqrt(1.0 - _zeta * _zeta)
	var decay := exp(-sigma * dt)
	var c := cos(wd * dt)
	var s := sin(wd * dt)
	_ka = decay * (c + sigma / wd * s)
	_kb = decay * s / wd
	_kc = -decay * _omega * _omega / wd * s
	_ke = decay * (c - sigma / wd * s)
