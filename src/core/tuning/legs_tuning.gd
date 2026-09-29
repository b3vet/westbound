class_name LegsTuning
extends Resource
## Legs, checkpoints, leg bonuses, objectives, forks and the journey.
## Spec: Core loop → Legs and checkpoints, The journey goal. Saved as data/tuning/legs.tres.
## Night doubles leg bonuses (ScoringTuning.night_factor).

@export_group("Legs")
@export var leg_length_km: float = 3.5
@export var legs_to_coast: int = 8
@export var checkpoint_warning_distances_m: PackedFloat64Array = [1000.0, 500.0]
@export var fork_sign_distance_m: float = 1000.0

@export_group("Run start")
## The rolling start: the car waits on the line in this lane (0 = next to the median)
## and leaves it at this speed when the countdown ends (above the minimum speed, so
## the run starts scoring at once).
@export var start_lane: int = 1   # not in spec: the M3 drive scene's lane
@export var start_speed_kmh: float = 120.0   # not in spec: a rolling start

@export_group("Pace (Pace bonus and the checkpoint sun lift)")
@export var pace_target_kmh: float = 170.0   # not in spec: "the leg's pace target"
## The pace sun lift reaches its maximum at this much above the target (linear from the target).
@export var pace_full_lift_margin_kmh: float = 40.0   # not in spec

@export_group("Leg bonuses")
@export var bonus_threads_min_count: int = 3
@export var bonus_heat_multiplier: float = 10.0
@export var bonus_heat_hold_s: float = 15.0
@export var bonus_clean_points: int = 5000   # not in spec
@export var bonus_pace_points: int = 3000   # not in spec
@export var bonus_threads_points: int = 3000   # not in spec
@export var bonus_heat_points: int = 5000   # not in spec

@export_group("Objectives (one optional per leg)")
## The objectives drawn from (LegObjectives ids), one per leg, never the same twice in a
## row. The spec's examples are "5 close passes", "thread twice" and "no braking".
@export var objective_pool: Array[StringName] = [&"close_passes", &"threads", &"no_braking",
		&"cuts", &"top_speed", &"slipstream", &"no_shoulder"]
## The first leg with an objective (1: every leg, the spec's "each leg ... on entry").
@export var objective_first_leg: int = 1
@export var objective_close_passes_count: int = 5
@export var objective_threads_count: int = 2
@export var objective_cuts_count: int = 6   # not in spec
@export var objective_top_speed_kmh: float = 250.0   # not in spec
## Slipstream objective: seconds in slipstream during the leg (added up, not continuous).
@export var objective_slipstream_s: float = 5.0   # not in spec
## "No X" objectives (no braking, no shoulder) ignore the leg's first seconds (the
## crossing itself, a hit's recovery at the line), then fail on the first offence and
## complete at the checkpoint if they never failed.
@export var objective_avoid_grace_s: float = 3.0   # not in spec
## "No braking" fails on brake input above this (0..1; a feathered touch is not braking).
@export var objective_brake_threshold: float = 0.2   # not in spec
@export var objective_bonus_points: int = 2500   # not in spec

@export_group("Journey")
@export var journey_bonus_points: int = 50000   # not in spec


func leg_length_m() -> float:
	return Units.km_to_m(leg_length_km)


func start_speed_mps() -> float:
	return Units.kmh_to_mps(start_speed_kmh)


func pace_target_mps() -> float:
	return Units.kmh_to_mps(pace_target_kmh)


func pace_full_lift_margin_mps() -> float:
	return Units.kmh_to_mps(pace_full_lift_margin_kmh)


func objective_top_speed_mps() -> float:
	return Units.kmh_to_mps(objective_top_speed_kmh)
