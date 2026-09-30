class_name DriverProfile
extends Resource
# lint: not-sim data schema; defaults are placeholders overwritten by data/driver_profiles/*.tres
## A driver personality: IDM and MOBIL parameters plus lane-change behavior.
## Spec: Traffic → IDM, MOBIL, Fairness rules 1 and 7, Driver types table.
## Files: data/driver_profiles/<id>.tres (the spec's eight profiles: cruiser, commuter,
## aggressive, truck, bus, van, motorbike, hesitant; plus racer, plan D15). TrafficState.profile_id indexes
## the loaded list. Global rules still apply on top of a profile: the 6 m/s^2 clamp,
## the 0.5 s signal floor, the player b_safe and no-ambush (TrafficTuning).
## Defaults below are a standard "commuter" driver; IDM/MOBIL values are not in the
## spec (typical highway values from the IDM/MOBIL literature) and get tuned in the
## traffic sandbox.

@export var id: StringName = &""
@export var display_name: String = ""

@export_group("Desired speed (v0 drawn uniformly in this range)")
@export var desired_speed_min_kmh: float = 100.0
@export var desired_speed_max_kmh: float = 130.0

@export_group("IDM")
@export var idm_a_max_mps2: float = 1.4   # not in spec
@export var idm_b_comfort_mps2: float = 2.0   # not in spec
@export var idm_headway_s: float = 1.3   # not in spec (T)
@export var idm_s0_m: float = 2.0   # not in spec (minimum gap)
@export var idm_delta: float = 4.0

@export_group("MOBIL")
@export var mobil_politeness: float = 0.3   # not in spec (p)
@export var mobil_threshold_mps2: float = 0.2   # not in spec (delta a_th)
@export var mobil_keep_right_bias_mps2: float = 0.3   # not in spec (a_bias, favors moving right)
@export var mobil_b_safe_mps2: float = 4.0   # not in spec (player case uses TrafficTuning.player_b_safe_mps2)

@export_group("Lane changes")
@export var signal_time_s: float = 1.0
@export var lane_change_move_min_s: float = 2.0
@export var lane_change_move_max_s: float = 3.0
## Scales how often MOBIL is evaluated / accepted (rare < 1 < frequent).
@export var lane_change_frequency_scale: float = 1.0
## Hesitant: probability of cancelling after signaling (blinker off, stays in lane).
@export var cancel_probability: float = 0.0
@export var keep_right: bool = false
## Keep-right profiles (trucks, buses: "right lanes") may only use the rightmost N lanes;
## 0 = any lane. A vehicle spawned further left may always move right.
@export var keep_right_lane_count: int = 0
## Motorbike: splits lanes in slow traffic (never during the player's lane change).
@export var lane_split: bool = false

@export_group("Weaving (plan D17, WP6.9)")
## Racers weave harder (owner, D17). Every field below toward other TRAFFIC only: toward
## the player a weaving driver keeps the values above (IDM's T, s0, b), the player's
## b_safe (TrafficTuning.player_b_safe_mps2), no-ambush and rear-end prevention exactly
## as every other profile. Defaults (< 0 / 0) switch all of it off, so profiles that do
## not set them are bit-identical to before. See docs/TRAFFIC.md, "Racers weave harder".
## IDM time headway T behind a traffic car (s); < 0 = idm_headway_s. The director's leg
## scale and headway zones scale it like T.
@export var idm_headway_vs_traffic_s: float = -1.0
## IDM minimum gap s0 behind a traffic car (m); < 0 = idm_s0_m.
@export var idm_s0_vs_traffic_m: float = -1.0
## IDM comfortable deceleration b behind a traffic car (m/s^2); < 0 = idm_b_comfort_mps2.
## Higher = it holds its speed longer before braking for a slower car (IDM's closing term).
@export var idm_b_comfort_vs_traffic_mps2: float = -1.0
## MOBIL b_safe when the new follower (or, for its own braking, the new leader) is a
## traffic car (m/s^2); < 0 = mobil_b_safe_mps2. Never above TrafficTuning.max_decel_mps2;
## keep it well below: the follower's braking can grow a little after the cut-in, and
## it must never need the 6 m/s^2 clamp. The player as new follower keeps
## player_b_safe_mps2, as new leader mobil_b_safe_mps2.
@export var mobil_b_safe_vs_traffic_mps2: float = -1.0
## Lookahead lane choice: MOBIL's incentive gains lookahead_gain_per_s x (the target
## lane's pace - its own lane's pace), capped at +-lookahead_incentive_max_mps2, where a
## lane's pace is the mean speed it could make there over this distance behind the
## vehicles in it (its desired speed when clear): the lane that is moving, not just
## its first car. 0 = off (only the immediate leader counts, as MOBIL).
@export var lookahead_lane_choice_m: float = 0.0
@export var lookahead_gain_per_s: float = 0.0
@export var lookahead_incentive_max_mps2: float = 0.0
## MOBIL cooldown after a lane change (s); < 0 = TrafficTuning.lane_change_cooldown_s.
@export var lane_change_cooldown_s: float = -1.0
## Readability cap: at most this many discretionary lane changes started in any
## lane_change_cap_window_s (0 = no cap beyond the cooldown).
@export var lane_change_cap_count: int = 0
@export var lane_change_cap_window_s: float = 10.0

@export_group("Director")
## First leg (1-based) on which this profile may spawn (Hesitant: 3).
@export var min_leg: int = 1
## Fast profiles that belong in the fast lanes (Racer, plan D15): Flow spawns them
## only in the leftmost N lanes, and never in the rightmost (slow) lane. 0 = any lane.
@export var spawn_left_lane_count: int = 0


func desired_speed_min_mps() -> float:
	return Units.kmh_to_mps(desired_speed_min_kmh)


func desired_speed_max_mps() -> float:
	return Units.kmh_to_mps(desired_speed_max_kmh)
