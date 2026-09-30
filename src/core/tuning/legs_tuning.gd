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

@export_group("Biome plan (WP6.4a, docs/BIOMES.md)")
## The journey's biome per leg (1-based order), by BiomeDef id (data/biomes/<id>.tres).
## Spec: "Each leg is one biome"; the coast is the destination after legs_to_coast legs.
## A missing file falls back to the leg before it (BiomePlan).
@export var leg_biome_ids: Array[StringName] = [&"farmland", &"desert", &"desert", &"canyon", &"canyon",
		&"city", &"city", &"valley_fog"]   # not in spec: the default order, the coast kept as the destination (BIOMES.md)
## Every leg after the list: the endless coastal highway ("The road continues as an
## endless coastal highway").
@export var endless_biome_id: StringName = &"coast"
## Ground, verge, rock and the world / fog tint offsets blend from one biome to the
## next over [checkpoint - before, checkpoint + after]; roadside props swap at the line.
@export var biome_blend_before_m: float = 250.0   # not in spec: blend over a distance
@export var biome_blend_after_m: float = 350.0   # not in spec
## The horizon silhouettes crossfade over [checkpoint - before, checkpoint + after].
@export var horizon_blend_before_m: float = 600.0   # not in spec: far layers change slowly
@export var horizon_blend_after_m: float = 900.0   # not in spec

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

@export_group("Forks (WP6.5, docs/FORKS.md)")
## "Some checkpoints split the road OutRun-style into two branches leading to different
## biomes." How many of the journey's checkpoints fork (drawn per run seed: the Daily
## Drive date gives everyone the same ones).
@export var fork_count_min: int = 2   # not in spec: "some checkpoints"
@export var fork_count_max: int = 3   # not in spec
## Forks can sit at checkpoints fork_first_checkpoint .. legs_to_coast - 1 (the last
## one leads to the coast, which is the destination, never a choice), at least this
## many checkpoints apart.
@export var fork_first_checkpoint: int = 1   # not in spec
@export var fork_min_spacing_legs: int = 2   # not in spec: one fork's zone is gone before the next is planned

@export_group("Journey")
@export var journey_bonus_points: int = 50000   # not in spec
## The finale plays this far past the coast's checkpoint (the ocean has opened by then).
@export var finale_after_m: float = 900.0   # not in spec: past the water's arrival sweep
## The traffic-free breather the finale asks the director for: no traffic within this
## much before and after the car for the finale's whole distance (plus the swing).
@export var finale_breather_before_m: float = 150.0   # not in spec
@export var finale_breather_after_m: float = 1200.0   # not in spec: beyond the fog
## The breather is requested this far before the finale point (so it is clear by then).
@export var finale_breather_lead_m: float = 1500.0   # not in spec
## Without a clear breather by then, the swing is skipped (the toast still shows).
@export var finale_give_up_m: float = 1500.0   # not in spec
## The car holds its lane and speed through the swing (input ignored): lateral error to
## lateral speed, heading error and yaw rate to steer, speed error over a time constant.
@export var finale_hold_lateral_gain: float = 2.5   # not in spec: 1/s
@export var finale_hold_steer_gain: float = 40.0   # not in spec: steer per rad
@export var finale_hold_rate_gain: float = 3.0   # not in spec: steer per rad/s
@export var finale_hold_speed_time_s: float = 1.0   # not in spec


## The id of leg `leg`'s biome (1-based) in the default plan.
func biome_id_for_leg(leg: int) -> StringName:
	var i := maxi(leg, 1) - 1
	if i < leg_biome_ids.size():
		return leg_biome_ids[i]
	return endless_biome_id


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
