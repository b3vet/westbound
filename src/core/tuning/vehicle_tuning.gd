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
@export var boost_thrust_mps2: float = 3.0   # not in spec: "extra thrust"; tuned in WP1.5

@export_group("Feel targets")
@export var brake_target_from_kmh: float = 250.0
@export var brake_target_to_kmh: float = 100.0
@export var brake_target_s: float = 1.3
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

@export_group("Car roster limits (CarDef)")
@export var car_top_speed_min_kmh: float = 240.0
@export var car_top_speed_max_kmh: float = 300.0
@export var car_stat_spread_pct: float = 10.0

@export_group("Gearbox (simulated automatic)")
@export var gear_count_min: int = 6
@export var gear_count_max: int = 7
@export var shift_dip_pct: float = 10.0   # not in spec: "a tiny acceleration dip on each shift"
@export var shift_dip_s: float = 0.12   # not in spec

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


func slip_angle_max_rad() -> float:
	return deg_to_rad(slip_angle_max_deg)
