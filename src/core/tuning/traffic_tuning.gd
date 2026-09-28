class_name TrafficTuning
extends Resource
## Traffic simulation, fairness rules, spawning and reactions to the player.
## Spec: Traffic (road-space simulation, IDM, MOBIL, fairness rules, reactions,
## spawning, tests). Saved as data/tuning/traffic.tres.
## Per-personality IDM/MOBIL values live in DriverProfile (data/driver_profiles/);
## the values here are global rules and floors that apply to every profile.

@export_group("Simulation budget")
@export var max_active_vehicles: int = 60   # TrafficState capacity, player's carriageway
@export var near_radius_m: float = 200.0
@export var near_tick_hz: int = 120
@export var far_tick_hz: int = 30

@export_group("IDM")
@export var idm_delta: float = 4.0
## Deceleration clamp outside scripted set pieces (fairness rule 4).
@export var max_decel_mps2: float = 6.0

@export_group("Readable braking")
@export var brake_light_decel_mps2: float = 1.0
@export var brake_light_strong_decel_mps2: float = 4.0

@export_group("Lane changes (telegraphing)")
@export var signal_time_s: float = 1.0
@export var signal_time_aggressive_s: float = 0.6
@export var signal_time_floor_s: float = 0.5
@export var lane_change_move_min_s: float = 2.0
@export var lane_change_move_max_s: float = 3.0
@export var lane_change_move_aggressive_s: float = 1.5
@export var hesitant_cancel_pct: float = 20.0

@export_group("No ambush / player safety")
@export var no_ambush_window_s: float = 1.5
@export var no_ambush_margin_m: float = 1.0
## MOBIL b_safe when the player would be the new follower.
@export var player_b_safe_mps2: float = 2.0

@export_group("Lane discipline")
## Lane flow speeds, indexed from the RIGHTMOST lane (index 0 = slow lane).
## Lane i of n (0 = next to the median) uses entry [n - 1 - i]. Rises toward the left.
@export var lane_flow_speeds_from_right_kmh: PackedFloat64Array = [95.0, 115.0, 135.0, 150.0]   # not in spec: only "rises toward the left"

@export_group("Spawning")
@export var spawn_ahead_m: float = 750.0
@export var spawn_behind_m: float = 150.0
@export var despawn_behind_m: float = 200.0

@export_group("Opposite carriageway (visual only)")
@export var opposite_max_vehicles: int = 30   # not in spec: "lower density"
@export var opposite_density_pct: float = 50.0   # not in spec: share of the leg's density
@export var opposite_speed_kmh: float = 110.0   # not in spec: "constant speed"

@export_group("Reactions to the player")
@export var tailgate_high_beam_distance_m: float = 10.0   # at night
@export var tailgate_high_beam_s: float = 1.0
@export var close_pass_horn_pct: float = 30.0
@export var cut_in_brake_tap_distance_m: float = 10.0
@export var blind_spot_horn_s: float = 3.0
## A traffic car hit by the player swerves, brakes, hazards on, then recovers after this.
@export var hit_recover_s: float = 4.0

@export_group("Tests and metrics")
@export var soak_distance_km: float = 10000.0
@export var trace_hash_interval_s: float = 1.0
@export var metrics_tolerance_pct: float = 15.0


func near_dt() -> float:
	return Units.hz_to_dt(float(near_tick_hz))


func far_dt() -> float:
	return Units.hz_to_dt(float(far_tick_hz))


func lane_flow_speed_mps(lane: int, lane_count: int) -> float:
	var i := clampi(lane_count - 1 - lane, 0, lane_flow_speeds_from_right_kmh.size() - 1)
	return Units.kmh_to_mps(lane_flow_speeds_from_right_kmh[i])


func hesitant_cancel_frac() -> float:
	return Units.pct_to_frac(hesitant_cancel_pct)
