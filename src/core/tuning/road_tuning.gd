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

@export_group("Roadside rhythm")
@export var light_pole_spacing_m: float = 50.0
@export var reflector_post_spacing_m: float = 25.0


func lane_center_d(lane: int) -> float:
	return median_half_width_m + inner_shoulder_m + (float(lane) + 0.5) * lane_width_m


func max_curvature() -> float:
	return 1.0 / min_curve_radius_m


func max_grade_frac() -> float:
	return Units.pct_to_frac(max_grade_pct)


func floating_origin_shift_m() -> float:
	return Units.km_to_m(floating_origin_shift_km)
