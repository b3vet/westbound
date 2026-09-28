class_name RoadTuning
extends Resource
## Road cross-section, geometry limits and roadside rhythm. Spec: World → Road,
## Architecture rule 6 (floating origin), Cameras → Glare rule (sun placement).
## Saved as data/tuning/road.tres. See docs/CONTRACTS.md "Road space".

@export_group("Cross-section (from the median outward)")
## Reference line (d = 0) to the median barrier face. The barrier is centered on d = 0.
@export var median_half_width_m: float = 0.5   # not in spec: ~1 m concrete median barrier centered on the reference line
## Paved strip between the median barrier face and lane 0.
@export var inner_shoulder_m: float = 1.2   # not in spec: typical inner (left) shoulder of a divided highway
@export var lane_width_m: float = 3.6
@export var shoulder_m: float = 3.0   # outer (right) shoulder
## Outer shoulder edge to the guardrail face.
@export var guardrail_offset_m: float = 0.5   # not in spec: guardrail set just beyond the paved shoulder

@export_group("Lanes per direction")
@export var lanes_default: int = 3
@export var lanes_min: int = 2   # tunnels, road works
@export var lanes_max: int = 4   # some biomes

@export_group("Geometry")
@export var min_curve_radius_m: float = 1200.0
@export var max_grade_pct: float = 5.0
@export var chunk_length_m: float = 200.0
@export var floating_origin_shift_km: float = 2.0
## The road heading keeps the sun this far off the camera axis.
@export var sun_offset_min_deg: float = 15.0
@export var sun_offset_max_deg: float = 30.0

@export_group("Procedural plan view (WP1.1)")
## Grid spacing of the precomputed sample table; sample_into interpolates between points.
@export var sample_spacing_m: float = 2.0   # not in spec: dense-table resolution (accuracy vs memory)
## The table is generated in fixed blocks of this length (a whole number of samples).
@export var generation_block_m: float = 1000.0   # not in spec: generation granularity
## The run starts on a straight this long.
@export var start_straight_m: float = 1000.0   # not in spec
@export var straight_min_m: float = 300.0   # not in spec: "mostly straights and sweepers"
@export var straight_max_m: float = 1500.0   # not in spec
## Normal bends draw their radius in [min_curve_radius_m, curve_radius_max_m].
@export var curve_radius_max_m: float = 4000.0   # not in spec: "long gentle curves"
## Heading change of one normal bend (also limited by the sun band width).
@export var curve_deflection_min_deg: float = 4.0   # not in spec
@export var curve_deflection_max_deg: float = 15.0   # not in spec: the sun band is 15 deg wide
## Length of each clothoid transition (curvature ramps linearly 0 <-> 1/R over it).
@export var transition_min_m: float = 100.0   # not in spec: continuous curvature for steering feed-forward
@export var transition_max_m: float = 250.0   # not in spec
## Distance between sun-side switches (the road crosses from sun-left to sun-right).
@export var sun_side_switch_min_km: float = 15.0   # not in spec: "switch sides rarely"
@export var sun_side_switch_max_km: float = 40.0   # not in spec
## Radius of the single arc that carries the heading through the +-sun_offset_min_deg zone.
@export var sun_side_switch_radius_m: float = 1200.0   # not in spec: "switch quickly" (tightest legal radius)

@export_group("Procedural vertical profile (WP1.1)")
## Normal grade segments draw their grade in [-grade_typical_pct, +grade_typical_pct].
@export var grade_typical_pct: float = 3.0   # not in spec: farmland is mostly gentle
@export var grade_length_min_m: float = 200.0   # not in spec: constant-grade tangent length
@export var grade_length_max_m: float = 1000.0   # not in spec
## Radius (1 / d(grade)/ds) of normal vertical curves; keep it above the blind-crest radius.
@export var vertical_radius_min_m: float = 20000.0   # not in spec: never blind at the sight rule below
@export var vertical_radius_max_m: float = 60000.0   # not in spec
## Beyond +-this elevation, normal grades turn back toward 0 (keeps the road near the ground plane).
@export var elevation_soft_limit_m: float = 40.0   # not in spec
## Chance per vertical curve to start a deliberate crest ("occasional blind crests").
@export var crest_chance_frac: float = 0.3   # not in spec
## A crest climbs and descends at least this grade (up to max_grade_pct).
@export var crest_grade_min_pct: float = 3.0   # not in spec
@export var crest_vertical_radius_min_m: float = 3000.0   # not in spec: sharp enough to hide traffic
@export var crest_vertical_radius_max_m: float = 6000.0   # not in spec

@export_group("Sight distance (Traffic fairness rule 6)")
## Driver eye height and obstacle height for the crest sight-distance rule.
@export var sight_eye_height_m: float = 1.1   # not in spec: sports-car driver eye
@export var sight_object_height_m: float = 0.5   # not in spec: a car's lower body / taillights
## A crest or bend whose sight distance is below this is flagged BLIND_CREST / BLIND_BEND.
@export var blind_sight_distance_m: float = 250.0   # not in spec: ~3.5 s at 250 km/h
## Lateral clearance from the driving line to sight obstructions inside a bend
## (farmland is open; biomes with cliffs would lower it). Sight = sqrt(8 R clearance).
@export var bend_sight_clearance_m: float = 15.0   # not in spec

@export_group("Warning signs and lane changes")
## Bends with a radius at or below this get a warning SIGN (Traffic fairness rule 6).
@export var sharp_bend_radius_m: float = 1300.0   # not in spec: only the tightest bends are "sharp"
## Warning signs for sharp bends and blind crests stand this far before them.
@export var hazard_sign_distance_m: float = 300.0   # not in spec
## Default taper length of a scheduled lane-count change.
@export var lane_taper_length_m: float = 200.0   # not in spec

@export_group("Roadside rhythm")
@export var light_pole_spacing_m: float = 50.0
@export var reflector_post_spacing_m: float = 25.0


func lane_center_d(lane: int) -> float:
	return median_half_width_m + inner_shoulder_m + (float(lane) + 0.5) * lane_width_m


func max_curvature() -> float:
	return 1.0 / min_curve_radius_m


func max_grade_frac() -> float:
	return Units.pct_to_frac(max_grade_pct)


## Table samples per generation block.
func generation_block_samples() -> int:
	return int(round(generation_block_m / sample_spacing_m))


func floating_origin_shift_m() -> float:
	return Units.km_to_m(floating_origin_shift_km)
