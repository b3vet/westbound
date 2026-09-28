class_name VehiclePhysics
extends RefCounted
## Player-car physics: a hand-rolled grip bicycle model in road space at 120 Hz.
## Spec: Car physics and feel (model steps 1-6, steering pipeline, gearbox, boost);
## Scoring -> Boost. Equations, integration and tuning knobs: docs/PHYSICS.md.
##
## Pure and static: step() reads `input`, `params` and (optionally) `road`, and
## MUTATES `state` in place (the contract's "returns new state", done without
## allocating). No Node, no autoload, no randomness, no allocation per tick.
##
## Road-relative formulation: yaw, yaw_rate and the grip dynamics are relative to the
## road tangent at s. The road's own turning (curvature x s_dot) is fed forward, so
## zero steering input keeps the car parallel to the lane through bends (step 5). The
## lateral position d is never corrected (this is not lane-centering). The heading
## returns to the lane direction on release, critically damped (steering pipeline).
## state.yaw_rate is therefore d(yaw)/dt, road-relative; world yaw rate = yaw_rate +
## curvature * s_dot.


## One physics tick. `dt` in seconds (1/120 in play). `road` supplies curvature at s;
## null means a straight road. Tick order and ownership: docs/CONTRACTS.md section 4.
static func step(state: VehicleState, input: VehicleInput, dt: float, params: VehicleParams,
		road: RoadPath = null) -> void:
	var v := state.v
	var kappa := 0.0
	if road != null:
		kappa = road.curvature_at(state.s)

	# Steering pipeline: input -> speed-sensitive max angle -> rate limit (full lock in
	# steer_lock_s at any speed) -> steer angle.
	var steer_max := params.steer_max_rad(v)
	var steer_target := clampf(input.steer, -1.0, 1.0) * steer_max
	state.steer_angle = move_toward(state.steer_angle, steer_target, steer_max / params.steer_lock_s * dt)

	# Boost: an edge request starts a boost if the meter allows; it runs until empty.
	if input.boost and not state.boost_active and state.boost_meter >= params.boost_start_min_frac:
		state.boost_active = true

	# Longitudinal (car frame): engine, boost, brake, engine braking, rolling, drag.
	var brake := clampf(input.brake, 0.0, 1.0)
	var throttle := clampf(input.throttle, 0.0, 1.0) * (1.0 - brake)
	var dip := step_gearbox(state, params, v, dt)
	var boost := 1.0 - brake if state.boost_active else 0.0
	var a_long := longitudinal_accel(params, v, throttle, brake, boost, dip)
	var v_next := maxf(v + a_long * dt, 0.0)
	state.accel_long = (v_next - v) / dt

	# Yaw: grip-limited bicycle yaw rate + heading return, through the yaw lag.
	var s_dot := (v * cos(state.yaw) - state.v_lat * sin(state.yaw)) / (1.0 - kappa * state.d)
	var omega_road := kappa * s_dot
	var lag_blend := 1.0 - exp(-dt / params.yaw_lag_s(v))
	var align := heading_align_rate(lag_blend, dt, params.heading_align_ratio) \
		* clampf(v / params.align_fade_mps, 0.0, 1.0)
	var r_cmd := steer_yaw_rate(params, v, state.steer_angle) - align * state.yaw
	var r_lim := params.grip_mps2(v) / maxf(v, params.align_fade_mps)
	r_cmd = clampf(r_cmd, -r_lim - omega_road, r_lim - omega_road)
	state.yaw_rate += (r_cmd - state.yaw_rate) * lag_blend
	state.yaw += state.yaw_rate * dt

	# Lateral grip: the car frame turns under the velocity (-v r), tire force scrubs the
	# lateral velocity (cornering stiffness), and the slip angle is hard-clamped.
	var v_lat_prev := state.v_lat
	var v_lat := (v_lat_prev - v * state.yaw_rate * dt) * exp(-dt * params.lateral_grip_rate)
	var v_lat_max := params.slip_max_tan * v
	state.v_lat = clampf(v_lat, -v_lat_max, v_lat_max)

	# Road-space kinematics (exact for the offset curve at d).
	var cy := cos(state.yaw)
	var sy := sin(state.yaw)
	s_dot = (v * cy - state.v_lat * sy) / (1.0 - kappa * state.d)
	state.s += s_dot * dt
	state.d += (v * sy + state.v_lat * cy) * dt
	state.accel_lat = (state.v_lat - v_lat_prev) / dt + v * (state.yaw_rate + kappa * s_dot)
	state.v = v_next

	# Boost meter drain (the caller adds the scoring fill).
	if state.boost_active:
		state.boost_meter -= params.boost_drain_per_s * dt
		if state.boost_meter <= 0.0:
			state.boost_meter = 0.0
			state.boost_active = false


## Longitudinal acceleration (m/s^2) at speed v for effective throttle and brake (0..1),
## boost thrust share (0..1) and gearbox dip factor. Shared by step() and the per-car
## calibration in VehicleParams, so the calibrated numbers are the simulated ones.
static func longitudinal_accel(params: VehicleParams, v: float, throttle: float, brake: float,
		boost: float, dip: float) -> float:
	var a := throttle * engine_accel(params, v) * dip \
		- brake * params.braking_mps2 \
		- (1.0 - throttle) * params.engine_brake_mps2 \
		- params.rolling_mps2 \
		- params.drag_per_m * v * v
	if boost > 0.0:
		a += boost * boost_accel(params, v)
	return a


## Boost thrust (m/s^2) at speed v: boost_thrust_mps2 up to about the car's top speed,
## then tapering so that at full throttle the net acceleration is taper x (Vb - v):
## the boosted top speed Vb is exactly the bonus above the normal one.
static func boost_accel(params: VehicleParams, v: float) -> float:
	var hold := params.drag_per_m * v * v + params.rolling_mps2 - engine_accel(params, v)
	return clampf(hold + params.boost_taper_per_s * (params.boost_top_speed_mps - v),
		0.0, params.boost_thrust_mps2)


## Full-throttle engine acceleration: traction-limited at low speed, then constant
## power (a = P / v).
static func engine_accel(params: VehicleParams, v: float) -> float:
	if v * params.traction_mps2 <= params.power_per_kg:
		return params.traction_mps2
	return params.power_per_kg / v


## Heading return rate (1/s) that makes the discrete release dynamics (yaw-rate lag
## blend b per tick, then yaw += yaw_rate dt) critically damped when ratio = 1:
## the double pole needs a dt = (2 - b - 2 sqrt(1 - b)) / b. Larger ratios (damping
## ratio < 1) oscillate; smaller ones are overdamped. Continuous limit: 1 / (4 lag).
static func heading_align_rate(lag_blend: float, dt: float, ratio: float) -> float:
	return (2.0 - lag_blend - 2.0 * sqrt(1.0 - lag_blend)) / (lag_blend * dt) * ratio


## Bicycle-model yaw rate (rad/s) for a steer angle at speed v, with understeer.
static func steer_yaw_rate(params: VehicleParams, v: float, steer_angle: float) -> float:
	var q := v / params.understeer_speed_mps
	return v * tan(steer_angle) / (params.wheelbase_m * (1.0 + q * q)) * params.steer_gain_factor


## Simulated automatic gearbox: picks the gear, moves rpm toward the gear's rpm at the
## sync rate, and returns the thrust factor (1, or 1 - shift dip while rpm is syncing
## after a shift). The rpm lag is the shift timer, so no extra state is needed.
static func step_gearbox(state: VehicleState, params: VehicleParams, v: float, dt: float) -> float:
	var g := clampi(state.gear, 1, params.gear_count)
	var rpm_target := params.gear_rpm(v, g)
	if g < params.gear_count and rpm_target >= params.shift_up_rpm:
		g += 1
	elif g > 1 and rpm_target < params.shift_down_rpm:
		g -= 1
	state.gear = g
	rpm_target = params.gear_rpm(v, g)
	state.rpm = move_toward(state.rpm, rpm_target, params.rpm_sync_per_s * dt)
	return params.shift_dip_factor if state.rpm != rpm_target else 1.0


## Resets `state` and places the car at (s, d) moving at v along the lane, with the
## gearbox already in the right gear (no spurious shifts on the first ticks).
static func place(state: VehicleState, params: VehicleParams, s: float, d: float, v: float) -> void:
	state.reset()
	state.s = s
	state.d = d
	state.v = v
	var g := 1
	while g < params.gear_count and params.gear_rpm(v, g) >= params.shift_up_rpm:
		g += 1
	state.gear = g
	state.rpm = params.gear_rpm(v, g)


## Road surface (step 6). Physics is planar in road space; the visual places the car at
## sample.local_point(d, ...) on the road surface (flat cross-section, so the height at
## (s, d) is the road elevation at s) and pitches it by this angle (rad, + nose up).
static func surface_pitch(sample: RoadSample) -> float:
	return atan(sample.grade)


## Road surface height (m, world Y) at (sample.s, d): flat cross-section, no banking.
static func surface_height(sample: RoadSample, _d: float) -> float:
	return sample.pos_y


## Body slip angle (rad, + velocity points right of the nose).
static func slip_angle(state: VehicleState) -> float:
	return atan2(state.v_lat, state.v)
