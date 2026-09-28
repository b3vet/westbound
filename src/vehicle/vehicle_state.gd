class_name VehicleState
extends RefCounted
## One driven vehicle's simulation state in road space (the player; later a hopped
## traffic car). Spec: Car physics and feel; Architecture rule 5.
## Plain 64-bit floats only (no Vector3 in sim state). Written by vehicle_physics;
## read by scoring, camera, car_visual, traffic (player as participant), passability.
## See docs/CONTRACTS.md "Vehicles".
##
## Sign conventions (right-positive): d > 0 right of the reference line; yaw > 0 nose
## points right of the road tangent; yaw_rate > 0 turning right; steer_angle > 0 front
## wheels turned right; v_lat > 0 moving toward the car's right; accel_lat > 0 toward
## the right. Kinematics: s_dot = v cos(yaw) / (1 - curvature * d), d_dot = v sin(yaw)
## (to first order; vehicle_physics owns the exact integration).
## World heading = road heading at s + yaw (Godot rotation.y = -(that)).

var s: float = 0.0            ## m along the road; center of the collision box
var d: float = 0.0            ## m lateral offset, + right
var yaw: float = 0.0          ## rad, car heading minus road tangent heading, + right
var v: float = 0.0            ## m/s forward speed (car frame)
var v_lat: float = 0.0        ## m/s lateral velocity (car frame), + right
var yaw_rate: float = 0.0     ## rad/s, + turning right
var steer_angle: float = 0.0  ## rad, front wheel angle after the steering pipeline, + right
var accel_long: float = 0.0   ## m/s^2, + accelerating
var accel_lat: float = 0.0    ## m/s^2, + toward the right
var rpm: float = 0.0          ## simulated gearbox (audio, visual); placeholder until WP1.5/WP2.1
var gear: int = 1
var boost_active: bool = false
var boost_meter: float = 0.0  ## 0..1 fill (1 = scoring.boost_full_s x car boost capacity)


func reset() -> void:
	s = 0.0
	d = 0.0
	yaw = 0.0
	v = 0.0
	v_lat = 0.0
	yaw_rate = 0.0
	steer_angle = 0.0
	accel_long = 0.0
	accel_lat = 0.0
	rpm = 0.0
	gear = 1
	boost_active = false
	boost_meter = 0.0


func copy_from(o: VehicleState) -> void:
	s = o.s
	d = o.d
	yaw = o.yaw
	v = o.v
	v_lat = o.v_lat
	yaw_rate = o.yaw_rate
	steer_angle = o.steer_angle
	accel_long = o.accel_long
	accel_lat = o.accel_lat
	rpm = o.rpm
	gear = o.gear
	boost_active = o.boost_active
	boost_meter = o.boost_meter


## Mixes every field into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_float(h, s)
	h = TraceHash.mix_float(h, d)
	h = TraceHash.mix_float(h, yaw)
	h = TraceHash.mix_float(h, v)
	h = TraceHash.mix_float(h, v_lat)
	h = TraceHash.mix_float(h, yaw_rate)
	h = TraceHash.mix_float(h, steer_angle)
	h = TraceHash.mix_float(h, accel_long)
	h = TraceHash.mix_float(h, accel_lat)
	h = TraceHash.mix_float(h, rpm)
	h = TraceHash.mix_int(h, gear)
	h = TraceHash.mix_bool(h, boost_active)
	return TraceHash.mix_float(h, boost_meter)


func trace_hash() -> int:
	return hash_into(TraceHash.SEED)
