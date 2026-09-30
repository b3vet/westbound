class_name TrafficTuning
extends Resource
## Traffic simulation, fairness rules, spawning and reactions to the player.
## Spec: Traffic (road-space simulation, IDM, MOBIL, fairness rules, reactions,
## spawning, tests). Saved as data/tuning/traffic.tres.
## Per-personality IDM/MOBIL values live in DriverProfile (data/driver_profiles/);
## the values here are global rules and floors that apply to every profile.

@export_group("Simulation budget")
## Plan D7/D11: the spec's 60 raised to 90 (leg-8 density on 4 lanes; see docs/SPAWNING.md).
## WP9.6 (PL-2, proposed deviation): the TrafficState capacity (player's carriageway) and
## the director's cap on roads of wide_road_min_lanes lanes or more; narrower roads keep
## max_active_vehicles_narrow (active_cap). At leg 8 on 4 lanes the 90 cap bound 6 % of
## the time and cost 7 % of the density around the player (14 % at the peaks).
@export var max_active_vehicles: int = 120   # TrafficState capacity, player's carriageway
@export var max_active_vehicles_narrow: int = 90   # not in spec
@export var wide_road_min_lanes: int = 4   # not in spec
@export var near_radius_m: float = 200.0
@export var near_tick_hz: int = 120
@export var far_tick_hz: int = 30

@export_group("IDM")
@export var idm_delta: float = 4.0
## Deceleration clamp outside scripted set pieces (fairness rule 4).
@export var max_decel_mps2: float = 6.0

@export_group("Sim (model internals; not in spec, tuned in the traffic sandbox)")
## Leader/follower search horizon along the road. IDM interaction beyond it is ignored.
## Plan D15: 400 -> 560 m for the racer (250 km/h closing on an 80 km/h truck: s* = 537 m).
@export var idm_lookahead_m: float = 560.0   # not in spec: covers s* at the largest closing speeds
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

@export_group("Lane closures and mandatory merges (WP6.2; not in spec)")
## A lane that ends (a road lane drop, WP6.3's merge zone and road works) is left
## within this distance before it closes: vehicles in it merge out with a MOBIL
## incentive bonus that ramps from 0 here to merge_urgency_mps2 at the closure, and no
## vehicle changes into it any more.
@export var merge_zone_m: float = 600.0   # not in spec
@export var merge_urgency_mps2: float = 2.0   # not in spec
## A vehicle that found no gap brakes for a standing obstacle this far before the
## closure and waits there (never onto the shoulder).
@export var merge_stop_margin_m: float = 15.0   # not in spec
## Nothing spawns in a lane that closes within this distance ahead of the spawn.
@export var merge_spawn_clear_m: float = 400.0   # not in spec

@export_group("Lane drops: early merging, harmonisation, zipper (WP6.8; not in spec)")
## A road lane drop (a tunnel's 3 -> 2) is merged out of from this far before its taper
## (instead of merge_zone_m, which stays for set-piece closures): nobody moves into the
## lane any more, and its vehicles seek a gap with an urgency that starts at
## lane_drop_urgency_min_mps2 and ramps to merge_urgency_mps2 at the taper.
@export var lane_drop_merge_zone_m: float = 1000.0   # not in spec: "start seeking a gap far earlier"
@export var lane_drop_urgency_min_mps2: float = 0.6   # not in spec
## Speed harmonisation: every lane is capped from the lane_ends sign (or this far before
## the taper when the road has no sign) through the narrowed section;
## vehicles brake into it at their profile's comfortable deceleration (TrafficSim speed
## zones). Through lanes at lane_drop_through_kmh, the dropping lane(s) a little slower,
## so gaps in the through lane slide past a merging car instead of riding beside it.
@export var lane_drop_slow_zone_m: float = 400.0   # not in spec: the lane_ends sign distance
@export var lane_drop_slow_after_m: float = 150.0   # not in spec
## The zone holds through the narrowed section: to lane_drop_slow_after_m past the end of
## the taper where the lanes come back, if that is within this distance of the drop's taper
## (a tunnel section; else past the drop's taper only).
@export var lane_drop_narrow_max_m: float = 3000.0   # not in spec: tunnels 300-800 m, up to two
@export var lane_drop_through_kmh: float = 120.0   # not in spec: WP6.8 brief "~110-130 km/h"
@export var lane_drop_merge_lane_kmh: float = 110.0   # not in spec: "matched" to the through lanes
## Braking into the zone eases in: none while the constant deceleration still needed to
## reach the zone's speed at its start is below this fraction of the profile's
## comfortable b, all of it from b on.
@export var lane_drop_brake_onset_frac: float = 0.5   # not in spec
## Drivers react to a harmonisation zone this far ahead (the ease-in needs a racer at
## 250 km/h to see it ~930 m out: (69.4^2 - 33.3^2) / (2 x 0.5 x 4)).
@export var lane_drop_view_m: float = 1000.0   # not in spec
## Inside a zone (and in the dropping lane within its merge zone) slower vehicles drive
## at least lane_drop_merge_lane_kmh (speed matching); past the zone they give it back
## gradually over this distance.
@export var lane_drop_release_m: float = 400.0   # not in spec
## Zipper: a vehicle in a lane beside a dropping lane treats the nearest car still in
## the dropping lane ahead of it (within lane_drop_yield_range_m, its closure within
## lane_drop_yield_frac of its merge zone) as its leader, braking no harder than
## lane_drop_yield_decel_mps2 (or its profile's comfortable b, if lower), when it can
## fall back behind it at that rate: the gap opens by easing off, and the merging car
## takes it. When it cannot, it passes and the merging car goes behind it.
@export var lane_drop_yield_range_m: float = 400.0   # not in spec
@export var lane_drop_yield_frac: float = 0.6   # not in spec: the last 60 % of the merge zone
@export var lane_drop_yield_decel_mps2: float = 1.5   # not in spec: well under b_safe and the clamp
## The merging car lines up behind the through lane's traffic (dropping back behind a
## car beside it that is at least as fast) only while faster than this, until it is
## within lane_drop_merge_floor_until_m of the closure (then it must get in).
@export var lane_drop_merge_floor_kmh: float = 90.0   # not in spec: no slow walls from merging buses
@export var lane_drop_merge_floor_until_m: float = 250.0   # not in spec

@export_group("MOBIL safety: every follower that can reach the gap (WP6.8; not in spec)")
## Besides the nearest follower in the target lane, MOBIL's safety check covers every
## vehicle behind it on the target path that is faster than the changing car and would
## close the distance within this time (signal + move + margin): a lane-splitting bike
## or a slow car can no longer hide a fast car behind it.
@export var mobil_follower_horizon_s: float = 5.0   # not in spec: 1 s signal + 3 s move + 1 s

@export_group("Lane-drop queue safety (MP-D5, WP6.11; not in spec)")
## Three safety extensions found by the server's rush-hour soaks (N4.1) at lane-drop
## queues, ported so single-player, the server and the client's network model run one
## model (docs/TRAFFIC.md, *Lane-drop queue safety*). Off = the model before WP6.11.
## A leader signalling or moving to a target off the car's path does not hide what is
## ahead of it: following (IDM) and MOBIL's own-safety check also judge the next vehicle
## on the path beyond it (a cut-out revealing a stopped queue).
@export var look_through_leaving_leaders: bool = true   # not in spec
## MOBIL's own-safety check also judges each new leader extrapolated with its current
## deceleration to when the car is in the lane (signal time + half the minimum move time),
## against the car holding its speed (a stale decision behind a leader braking into a queue).
@export var predict_leader_braking: bool = true   # not in spec
## When stopping s0 behind the leader's own stopping point (at its current deceleration)
## needs more than the profile's comfortable b, the follower brakes for it now, never
## beyond the clamp (a racer closing on a car braking at the clamp into a queue).
@export var anticipate_leader_braking: bool = true   # not in spec

@export_group("Long vehicles merging from a crawl (WP9.6; not in spec)")
## ACCEPTANCE F1: a vehicle longer than long_merge_min_length_m (a semi, a coach) slower
## than long_merge_crawl_kmh starts no lane change while a vehicle faster than
## long_merge_fast_kmh in the lane beyond its target would reach its body within
## long_merge_guard_s (it waits for that lane to be clear too): a 16 m truck pulling out
## of a standstill queue swings its cab toward the next lane as it moves over.
@export var long_merge_guard: bool = true   # not in spec
@export var long_merge_min_length_m: float = 12.0   # not in spec
@export var long_merge_crawl_kmh: float = 20.0   # not in spec
@export var long_merge_fast_kmh: float = 60.0   # not in spec
@export var long_merge_guard_s: float = 5.0   # not in spec

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
## Plan D15 (owner, M5): faster left lanes (was 95 / 115 / 135 / 150). The leftmost
## lane of a 3-lane road flows at 165 km/h, so only the fast profiles fit it.
@export var lane_flow_speeds_from_right_kmh: PackedFloat64Array = [95.0, 130.0, 165.0, 180.0]   # not in spec: only "rises toward the left"

@export_group("Spawning")
@export var spawn_ahead_m: float = 750.0
@export var spawn_behind_m: float = 150.0
@export var despawn_behind_m: float = 200.0
## Ahead spawns land at least this far past the fog end (fairness rule 5). The ahead
## distance is max(spawn_ahead_m, fog end + this); the fog end comes from the run.
@export var spawn_fog_margin_m: float = 30.0   # not in spec: "past the fog end"
## Despawn ahead once beyond the ahead distance + one batch + this ("beyond the active window").
@export var spawn_despawn_ahead_margin_m: float = 100.0   # not in spec
## Behind spawns use this many lanes from the median (clamped to lane_count - 1, at least 1).
@export var spawn_behind_lane_count: int = 2   # not in spec: "the left lanes"
## A behind spawn must be at least this much faster than the player.
@export var spawn_behind_speed_margin_kmh: float = 10.0   # not in spec: "only when the player is slower"
## A behind spawn that failed (visible, or its IDM gaps don't fit) is retried after this.
@export var spawn_behind_retry_s: float = 0.5   # not in spec: keeps failed attempts off the per-tick cost
## Default ghost zone (no spawns): the player's box grown by these margins.
@export var spawn_ghost_margin_long_m: float = 20.0   # not in spec
@export var spawn_ghost_margin_lat_m: float = 1.0   # not in spec
## A profile may spawn in a lane if its top desired speed reaches the lane flow minus
## this; its desired speed is then drawn from [flow - this, max] within its range.
@export var spawn_lane_speed_tolerance_kmh: float = 10.0   # not in spec: "slow profiles keep right"
## keep_right profiles spawn only in this many rightmost lanes.
@export var spawn_keep_right_lane_count: int = 1   # not in spec: "keeps right"
## Mix of the traffic that is neither aggressive nor racer (their shares come from
## DirectorTuning by leg). Ids name DriverProfiles; a profile missing here never spawns from Flow.
@export var spawn_profile_ids: Array[StringName] = [&"cruiser", &"commuter", &"truck", &"bus", &"van", &"motorbike", &"hesitant"]
@export var spawn_profile_weights_pct: PackedFloat64Array = [26.0, 34.0, 12.0, 4.0, 10.0, 4.0, 10.0]   # not in spec
@export var spawn_aggressive_profile_id: StringName = &"aggressive"
## The fast "Racer" (plan D15): its share comes from DirectorTuning by leg, like the
## aggressive share; it spawns only in its profile's spawn_left_lane_count left lanes.
@export var spawn_racer_profile_id: StringName = &"racer"
## Per-car desired-speed jitter (plan D15): after v0 is drawn in the lane's band, it is
## moved by up to +-this % (kept inside the profile's range and above a behind spawn's
## minimum speed), so a lane's cars don't all want the same speed.
@export var spawn_v0_jitter_pct: float = 5.0   # not in spec
## Only from DirectorTuning.hesitant_first_leg (and the profile's own min_leg).
@export var spawn_hesitant_profile_id: StringName = &"hesitant"
## Color-index range when the biome has no traffic palette.
@export var spawn_palette_fallback_count: int = 8   # not in spec

@export_group("Opposite carriageway (visual only)")
@export var opposite_max_vehicles: int = 30   # not in spec: "lower density"
@export var opposite_density_pct: float = 50.0   # not in spec: share of the leg's density
@export var opposite_speed_kmh: float = 110.0   # not in spec: "constant speed"
## Opposite lanes run faster toward their median: lane i of n adds (n - 1 - i) x this.
@export var opposite_lane_speed_step_kmh: float = 15.0   # not in spec
## Spacing jitter around the mean (1000 / density) when placing opposite vehicles.
@export var opposite_spacing_jitter_pct: float = 50.0   # not in spec
## Recycled once this far behind the player (behind the camera).
@export var opposite_recycle_behind_m: float = 30.0   # not in spec: "recycled as it passes behind the camera"

@export_group("Reactions to the player")
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
## Blind spot: the player's center between the car's center and this far behind it, one lane over.
@export var blind_spot_behind_m: float = 6.0   # not in spec
## "Occasional" horn: chance per blind_spot_horn_s spent in the blind spot.
@export var blind_spot_horn_pct: float = 50.0   # not in spec
## A reaction (brake tap, blind-spot horn) re-arms on the same car after this.
@export var reaction_cooldown_s: float = 6.0   # not in spec

@export_group("Tests and metrics")
@export var soak_distance_km: float = 10000.0
@export var trace_hash_interval_s: float = 1.0
@export var metrics_tolerance_pct: float = 15.0
## Soak runs (docs/SOAK.md): one run drives this many legs (leg length from LegsTuning),
## leg k at leg k's density, on a fresh seed; the soak is many runs.
@export var soak_run_legs: int = 8   # not in spec: one journey (legs_to_coast) per run
## Bot player speeds, drawn per leg ("mixed speeds").
@export var soak_bot_min_kmh: float = 110.0   # not in spec: WP3.3 brief
@export var soak_bot_max_kmh: float = 250.0   # not in spec: WP3.3 brief
## Share of legs the bot weaves; it keeps its lane in the others.
@export var soak_bot_weave_pct: float = 60.0   # not in spec
## Seconds between lane-change decisions of a weaving bot (uniform in [min, max]).
@export var soak_bot_weave_min_s: float = 2.0   # not in spec
@export var soak_bot_weave_max_s: float = 6.0   # not in spec
## Lane counts the soak's runs cycle through (the procedural road with lanes_default set
## to each; biomes have 2-4 lanes, farmland 3).
@export var soak_lane_counts: PackedInt32Array = [3, 3, 2, 4]   # not in spec
## A traffic car's rear-end contact counts against traffic ("a player driving normally")
## only if the player neither moved sideways nor braked harder than max_decel_mps2 in
## this long before the contact (else the player caused it: Lives → rear-end prevention).
@export var soak_normal_driving_quiet_s: float = 3.0   # not in spec
## How often the soak runs the impossible-window check (the passability oracle).
@export var soak_window_check_interval_s: float = 1.0   # not in spec
## Metrics: a gap between consecutive vehicles in a lane counts toward gaps_per_km if it
## is at least this long (bumper to bumper; the player's car plus room either side).
@export var metrics_gap_min_m: float = 15.0   # not in spec
@export var metrics_sample_interval_s: float = 1.0   # not in spec
## Speed bands of the live-traffic speed line (dev report / sandbox, plan D15): the
## share of vehicles faster than each, in km/h.
@export var dev_speed_bands_kmh: PackedFloat64Array = [150.0, 180.0, 200.0]   # not in spec


func near_dt() -> float:
	return Units.hz_to_dt(float(near_tick_hz))


func far_dt() -> float:
	return Units.hz_to_dt(float(far_tick_hz))


func lane_flow_speed_mps(lane: int, lane_count: int) -> float:
	var i := clampi(lane_count - 1 - lane, 0, lane_flow_speeds_from_right_kmh.size() - 1)
	return Units.kmh_to_mps(lane_flow_speeds_from_right_kmh[i])


func spawn_v0_jitter_frac() -> float:
	return Units.pct_to_frac(spawn_v0_jitter_pct)


func hesitant_cancel_frac() -> float:
	return Units.pct_to_frac(hesitant_cancel_pct)


func close_pass_horn_frac() -> float:
	return Units.pct_to_frac(close_pass_horn_pct)


func blind_spot_horn_frac() -> float:
	return Units.pct_to_frac(blind_spot_horn_pct)


## Near ticks per far tick (120 / 30 = 4). At least 1.
func far_tick_ratio() -> int:
	return maxi(1, roundi(float(near_tick_hz) / float(far_tick_hz)))


## WP9.6: the director's cap on live vehicles on a road of `lanes` lanes.
func active_cap(lanes: int) -> int:
	if lanes >= wide_road_min_lanes:
		return max_active_vehicles
	return mini(max_active_vehicles_narrow, max_active_vehicles)
