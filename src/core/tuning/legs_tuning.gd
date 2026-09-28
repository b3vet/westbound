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
@export var objective_close_passes_count: int = 5
@export var objective_threads_count: int = 2
@export var objective_bonus_points: int = 2500   # not in spec

@export_group("Journey")
@export var journey_bonus_points: int = 50000   # not in spec


func leg_length_m() -> float:
	return Units.km_to_m(leg_length_km)


func pace_target_mps() -> float:
	return Units.kmh_to_mps(pace_target_kmh)
