class_name VehicleTuning
extends Resource
## Player car physics targets, steering pipeline and visual body motion.
## Spec: Car physics and feel; Tech stack (physics tick). Saved as data/tuning/vehicle.tres.
## Per-car stats live in CarDef (data/cars/*.tres); per-type profiles in VehicleType.

@export_group("Simulation")
@export var physics_tick_hz: int = 120

@export_group("Lane-change time targets (3.6 m move and settle; full input, then release)")
@export var lane_change_speeds_kmh: PackedFloat64Array = [100.0, 200.0, 280.0]
@export var lane_change_times_s: PackedFloat64Array = [0.80, 1.00, 1.15]
@export var lane_change_tolerance_pct: float = 5.0
## A car's handling stat scales the lane-change times within this range.
@export var handling_scale_min: float = 0.9
@export var handling_scale_max: float = 1.1

@export_group("Steering pipeline")
@export var steer_max_deg_at_rest: float = 30.0   # at 0 km/h
@export var steer_max_deg_at_speed: float = 3.5   # at steer_ease_end_kmh
@export var steer_ease_end_kmh: float = 250.0
@export var steer_full_lock_s: float = 0.12

@export_group("Forces and limits")
@export var braking_mps2: float = 9.0
@export var slip_angle_max_deg: float = 8.0
@export var boost_top_speed_bonus_pct: float = 8.0
## Boost thrust up to the car's normal top speed; above it the thrust tapers so the
## boosted top speed is exactly boost_top_speed_bonus_pct higher (VehiclePhysics.boost_accel).
@export var boost_thrust_mps2: float = 3.0   # not in spec: "extra thrust"; tuned in WP1.5
## A boost request starts a boost only with at least this much meter.
@export var boost_start_min_pct: float = 10.0   # not in spec: "if the meter allows"

@export_group("Model: yaw and lateral grip (vehicle_physics.gd; see docs/PHYSICS.md)")
## Lateral grip limit (m/s^2) at each of lane_change_speeds_kmh, interpolated linearly
## and held beyond the ends (x 1 / handling^2 per car). Tuned so the lane-change
## targets hold; the spec's 0.8 s at 100 km/h needs ~3.2 g (docs/PHYSICS.md).
@export var grip_lateral_max_mps2: PackedFloat64Array = [31.8, 16.6, 12.4]   # not in spec: tuned to the lane-change targets
## Yaw-rate lag (the "yaw damping" time constant) at each of lane_change_speeds_kmh
## (x handling per car). Longer at speed = heavier; it also sets how fast the heading
## returns on release.
@export var yaw_lag_ms: PackedFloat64Array = [25.0, 40.0, 55.0]   # not in spec: tuned to the lane-change targets
## Heading return to the lane direction on release: 1 = critically damped (spec).
@export var heading_damping_ratio: float = 1.0
## Below this speed the heading return fades out (a parked car does not turn itself).
@export var heading_align_fade_kmh: float = 30.0   # not in spec
## Lateral grip time constant: how fast tire force scrubs lateral velocity (cornering
## stiffness). Smaller = stiffer, less slip.
@export var lateral_grip_lag_ms: float = 40.0   # not in spec: "high cornering stiffness"
## Understeer characteristic speed of the bicycle model: the steady yaw rate per steer
## angle is v / (L (1 + (v / v_ch)^2)). Shapes the response to partial input.
@export var understeer_speed_kmh: float = 300.0   # not in spec

@export_group("Model: longitudinal (engine curve shape, drag and power are derived per car)")
## Engine acceleration cap at low speed (traction-limited); above it the engine is
## power-limited (a = P / v). P and the aero drag coefficient are solved per car from
## its top speed and 0-200 km/h time (VehicleParams).
@export var engine_traction_max_mps2: float = 9.0   # not in spec
@export var rolling_resistance_mps2: float = 0.15   # not in spec: ~1.5% of g
## Coasting (throttle 0) decelerates by this much on top of drag and rolling resistance.
@export var engine_brake_mps2: float = 0.8   # not in spec: "coasts under engine braking"

@export_group("Feel targets")
@export var brake_target_from_kmh: float = 250.0
@export var brake_target_to_kmh: float = 100.0
## Full-brake 250 -> 100 km/h time the physics test holds every car to (the model's
## value: 9 m/s^2 plus drag, rolling resistance and engine braking).
@export var brake_target_s: float = 3.6   # owner decision 2026-09-28: 9 m/s^2 wins over the spec's 1.3 s
@export var brake_target_tolerance_pct: float = 10.0   # not in spec: the spec says "about"
@export var input_to_yaw_max_ms: float = 50.0
@export var boost_feel_max_s: float = 0.1

@export_group("Test acceptance")
@export var settle_overshoot_max_pct: float = 5.0   # of lane width, after release
@export var settle_drift_max_m: float = 0.3
@export var settle_window_s: float = 1.0
@export var straight_stability_s: float = 60.0
@export var straight_stability_drift_max_m: float = 0.3
@export var performance_tolerance_pct: float = 2.0   # top speed, 0-200 km/h time
@export var fuzz_duration_min: float = 10.0
## "Visible yaw": the yaw rate reaches this share of the maneuver's peak yaw rate
## (full input at speed) within input_to_yaw_max_ms.
@export var input_visible_yaw_rate_pct: float = 25.0   # not in spec: defines "visible"

@export_group("Lane-change procedure and capability curve (VehicleParams)")
## The spec's lane change: "move 3.6 m sideways and settle straight".
@export var lane_change_distance_m: float = 3.6
## Settled = within this of the target offset and with |yaw| below the next value.
@export var lane_change_settle_m: float = 0.1   # not in spec
@export var lane_change_settle_yaw_deg: float = 0.5   # not in spec
## Safety horizon for one simulated maneuver after release.
@export var lane_change_sim_max_s: float = 5.0   # not in spec
## Grid of the precomputed capability table (speed x lateral distance). Keep 100, 200
## and 280 km/h in the speeds so the targets are knots.
@export var capability_speeds_kmh: PackedFloat64Array = [60.0, 80.0, 100.0, 150.0, 200.0, 240.0, 280.0, 330.0]   # not in spec: 330 covers the fastest boosted car (300 x 1.08)
## Small moves are dense because the settle time dominates them (not linear in distance).
@export var capability_distances_m: PackedFloat64Array = [0.3, 0.9, 1.8, 3.6, 7.2, 10.8]   # not in spec: up to three lanes

@export_group("Car roster limits (CarDef)")
@export var car_top_speed_min_kmh: float = 240.0
@export var car_top_speed_max_kmh: float = 300.0
@export var car_stat_spread_pct: float = 10.0
## CarDef.zero_to_200_s is the full-throttle time from rest to this speed.
@export var accel_stat_to_kmh: float = 200.0

@export_group("Gearbox (simulated automatic)")
@export var gear_count_min: int = 6
@export var gear_count_max: int = 7
@export var shift_dip_pct: float = 10.0   # not in spec: "a tiny acceleration dip on each shift"
@export var shift_dip_s: float = 0.12   # not in spec
@export var engine_idle_rpm: float = 900.0   # not in spec
@export var engine_redline_rpm: float = 7000.0   # not in spec
## Upshift when the rpm in the current gear reaches this share of redline; downshift
## when it falls below shift_down_pct. Gear ratios are geometric.
@export var shift_up_pct: float = 92.0   # not in spec
@export var shift_down_pct: float = 55.0   # not in spec
## Top gear reaches redline at the car's top speed x this (above the boosted top speed).
@export var top_gear_speed_factor: float = 1.12   # not in spec
## First gear reaches redline at this share of top gear's redline speed.
@export var first_gear_speed_pct: float = 33.0   # not in spec

@export_group("Visual body motion (car_visual.gd, never feeds physics)")
@export var body_roll_max_deg: float = 4.0
@export var body_pitch_max_deg: float = 2.0
@export var body_spring_hz: float = 2.5
@export var body_damping_ratio: float = 0.6
@export var tire_smoke_min_decel_mps2: float = 4.0
@export var tire_smoke_min_speed_kmh: float = 150.0


func physics_dt() -> float:
	return Units.hz_to_dt(float(physics_tick_hz))


## Speed-sensitive maximum steer angle (radians), easing linearly from rest to steer_ease_end_kmh.
## WP1.5 may replace the easing shape; the endpoints are the spec's.
func steer_max_rad(speed_mps: float) -> float:
	var t := clampf(Units.mps_to_kmh(speed_mps) / steer_ease_end_kmh, 0.0, 1.0)
	return deg_to_rad(lerpf(steer_max_deg_at_rest, steer_max_deg_at_speed, t))


## Lane-change target time (s) at a speed, linear between lane_change_speeds_kmh and
## held beyond the ends, before the car's handling scale.
func lane_change_target_s(speed_mps: float) -> float:
	return interp_speed_table(lane_change_times_s, speed_mps)


## Linear interpolation of `values` over lane_change_speeds_kmh, clamped at the ends.
## Allocation-free.
func interp_speed_table(values: PackedFloat64Array, speed_mps: float) -> float:
	var kmh := Units.mps_to_kmh(speed_mps)
	var n := lane_change_speeds_kmh.size()
	if kmh <= lane_change_speeds_kmh[0]:
		return values[0]
	for i in range(1, n):
		if kmh <= lane_change_speeds_kmh[i]:
			var t := (kmh - lane_change_speeds_kmh[i - 1]) / (lane_change_speeds_kmh[i] - lane_change_speeds_kmh[i - 1])
			return lerpf(values[i - 1], values[i], t)
	return values[n - 1]


func slip_angle_max_rad() -> float:
	return deg_to_rad(slip_angle_max_deg)
