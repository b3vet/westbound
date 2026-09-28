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

@export_group("Sim (model internals; not in spec, tuned in the traffic sandbox)")
## Leader/follower search horizon along the road. IDM interaction beyond it is ignored.
@export var idm_lookahead_m: float = 400.0   # not in spec: covers s* at the largest closing speeds
## Gap floor in the IDM interaction term (avoids a division by zero on contact).
@export var idm_gap_floor_m: float = 0.1   # not in spec: numerical floor
## Two lateral intervals closer than this count as the same path (leader search, gaps).
@export var lateral_margin_m: float = 0.2   # not in spec: must stay below lane width - widest body
## FLAG_SCRIPTED (set pieces warned >= 300 m ahead) may brake beyond max_decel_mps2, up to this.
@export var scripted_max_decel_mps2: float = 9.0   # not in spec: the player's braking (Physics)
## MOBIL is evaluated this often per vehicle (divided by the profile's lane_change_frequency_scale).
@export var mobil_eval_interval_s: float = 1.0   # not in spec
## No new lane-change decision for this long after a lane change completes or is cancelled.
@export var lane_change_cooldown_s: float = 3.0   # not in spec: prevents ping-pong
## Lane discipline: extra MOBIL bias (m/s^2) toward the right when a vehicle's desired speed is
## below its lane's flow speed, and against moving left into a lane that flows faster than it wants.
@export var lane_discipline_bias_mps2: float = 0.3   # not in spec: "slow profiles keep right"
## Traffic treats the player as already occupying the lateral space it will reach in this time.
@export var player_lateral_anticipation_s: float = 0.3   # not in spec
## IDM parameters used to judge the player's required braking in MOBIL's safety check
## (the player holds its speed; only the interaction term is used).
@export var player_idm_a_max_mps2: float = 2.0   # not in spec
@export var player_idm_b_comfort_mps2: float = 3.0   # not in spec
@export var player_idm_headway_s: float = 1.0   # not in spec
@export var player_idm_s0_m: float = 2.0   # not in spec
## Player body used until run.gd calls TrafficSim.set_player_body() with the CarDef's size.
@export var player_length_m: float = 4.5   # not in spec: CarDef default body
@export var player_width_m: float = 1.9   # not in spec: CarDef default body

@export_group("Motorbike lane splitting (not in spec: \"splits lanes in slow traffic\")")
## Splitting starts only behind traffic slower than this, and ends when nothing within
## lane_split_scan_m ahead in the two lanes beside the bike is slower.
@export var lane_split_max_traffic_kmh: float = 60.0   # not in spec: "slow traffic"
## A splitting bike's desired speed is capped at this.
@export var lane_split_max_speed_kmh: float = 85.0   # not in spec
@export var lane_split_scan_m: float = 60.0   # not in spec
## Lateral clearance a splitting bike keeps to the vehicles it filters past (it follows
## anything closer, e.g. trucks and vans, instead of squeezing by).
@export var lane_split_clearance_m: float = 0.3   # not in spec
## "Never during the player's lane change": no split starts while the player moves
## sideways faster than this within lane_split_player_range_m.
@export var lane_split_player_lateral_mps: float = 0.5   # not in spec
@export var lane_split_player_range_m: float = 100.0   # not in spec

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
## Hit swerve: lateral offset away from the player, out and back over hit_swerve_s.
@export var hit_swerve_m: float = 0.5   # not in spec
@export var hit_swerve_s: float = 1.2   # not in spec
## Hit hard brake: at least this deceleration for hit_brake_s (still under the 6 m/s^2 clamp).
@export var hit_brake_decel_mps2: float = 5.0   # not in spec: "brakes hard" (strong brake lights)
@export var hit_brake_s: float = 1.0   # not in spec
## Brake tap after a tight cut-in: at least this deceleration for brake_tap_s.
@export var brake_tap_decel_mps2: float = 2.0   # not in spec: above the brake-light threshold
@export var brake_tap_s: float = 0.5   # not in spec
## High-beam flash duration (FLAG_HIGH_BEAM on) after night tailgating.
@export var high_beam_flash_s: float = 0.4   # not in spec
## Blind spot: the player's center between the car's center and this far behind it, one lane over.
@export var blind_spot_behind_m: float = 6.0   # not in spec
## "Occasional" horn: chance per blind_spot_horn_s spent in the blind spot.
@export var blind_spot_horn_pct: float = 50.0   # not in spec
## A reaction (brake tap, high beams, blind-spot horn) re-arms on the same car after this.
@export var reaction_cooldown_s: float = 6.0   # not in spec

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


func close_pass_horn_frac() -> float:
	return Units.pct_to_frac(close_pass_horn_pct)


func blind_spot_horn_frac() -> float:
	return Units.pct_to_frac(blind_spot_horn_pct)


## Near ticks per far tick (120 / 30 = 4). At least 1.
func far_tick_ratio() -> int:
	return maxi(1, roundi(float(near_tick_hz) / float(far_tick_hz)))
