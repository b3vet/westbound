class_name DriverProfile
extends Resource
# lint: not-sim data schema; defaults are placeholders overwritten by data/driver_profiles/*.tres
## A driver personality: IDM and MOBIL parameters plus lane-change behavior.
## Spec: Traffic → IDM, MOBIL, Fairness rules 1 and 7, Driver types table.
## Files: data/driver_profiles/<id>.tres (the eight profiles: cruiser, commuter,
## aggressive, truck, bus, van, motorbike, hesitant). TrafficState.profile_id indexes
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

@export_group("Director")
## First leg (1-based) on which this profile may spawn (Hesitant: 3).
@export var min_leg: int = 1


func desired_speed_min_mps() -> float:
	return Units.kmh_to_mps(desired_speed_min_kmh)


func desired_speed_max_mps() -> float:
	return Units.kmh_to_mps(desired_speed_max_kmh)
