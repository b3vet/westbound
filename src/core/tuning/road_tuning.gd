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

@export_group("Roadside")
## Window of placed roadside props behind the focus (ahead = Quality view distance).
@export var roadside_behind_m: float = 60.0   # not in spec: keeps props under the chase camera and in mirrors
## The prop window advances in steps of this (props are rewritten only then, never per frame).
@export var roadside_update_step_m: float = 25.0   # not in spec: bounds per-frame roadside work
## Guardrail posts behind the rail (the rails are road geometry).
@export var guardrail_post_spacing_m: float = 4.0   # not in spec: real W-beam posts are ~1.9 m; doubled for the triangle budget
## Guardrail face to the post center.
@export var guardrail_post_offset_m: float = 0.3   # not in spec: post sits behind the rail's blockout
## Guardrail face to the reflector (delineator) post center.
@export var reflector_post_offset_m: float = 0.6   # not in spec: delineators just behind the rail
## Scenery (fences, billboards, fields, buildings, trees) stays at least this far beyond the guardrail face.
@export var prop_clearance_m: float = 4.0   # not in spec: clear zone behind the rail
## Nothing is lower than this above the carriageway (gantries, lamp arms).
@export var overhead_clearance_m: float = 5.5   # not in spec: typical highway vertical clearance
## Sign gantries: at most one per cell per carriageway, `cell / mean spacing` chance each.
@export var sign_gantry_cell_length_m: float = 1000.0   # not in spec: "occasional sign gantries"
@export var sign_gantry_mean_spacing_m: float = 2500.0   # not in spec: about one every 30 s at 300 km/h
## Guardrail face to the gantry's outer upright.
@export var sign_gantry_upright_offset_m: float = 1.5   # not in spec: upright clear of the rail
## Billboards (invented brands): per side, at most one per cell, `cell / mean spacing` chance each.
@export var billboard_cell_length_m: float = 400.0   # not in spec
@export var billboard_mean_spacing_m: float = 900.0   # not in spec: "billboards" in the roadside rhythm
## Distance from the scenery line (guardrail + prop clearance) to the board's footprint.
@export var billboard_setback_min_m: float = 6.0   # not in spec
@export var billboard_setback_max_m: float = 24.0   # not in spec
## Boards turn this far toward the road (0 = facing approaching traffic head-on).
@export var billboard_toe_in_deg: float = 18.0   # not in spec: boards angled toward approaching drivers


func lane_center_d(lane: int) -> float:
	return median_half_width_m + inner_shoulder_m + (float(lane) + 0.5) * lane_width_m


func max_curvature() -> float:
	return 1.0 / min_curve_radius_m


func max_grade_frac() -> float:
	return Units.pct_to_frac(max_grade_pct)


func floating_origin_shift_m() -> float:
	return Units.km_to_m(floating_origin_shift_km)
