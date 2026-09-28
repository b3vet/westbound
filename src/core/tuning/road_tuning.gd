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

@export_group("Road build: markings (WP1.2)")
## Dashed lane lines: dash and gap lengths. The dash phase is taken from absolute s
## (a dash starts at every s = n * (dash + gap)), so it is continuous across chunks.
@export var dash_length_m: float = 3.0   # not in spec: US-style 10 ft dash
@export var dash_gap_m: float = 9.0   # not in spec: 30 ft gap (a 12 m speed rhythm)
@export var lane_line_width_m: float = 0.15   # not in spec: typical dashed lane line
@export var edge_line_width_m: float = 0.2   # not in spec: typical solid edge line
## Raised reflectors on the lane lines (emissive class 1), centred in the dash gaps.
@export var reflector_spacing_m: float = 24.0   # not in spec: one every two dash periods
@export var reflector_width_m: float = 0.12   # not in spec: raised pavement marker footprint
@export var reflector_length_m: float = 0.12   # not in spec: raised pavement marker footprint
@export var reflector_height_m: float = 0.025   # not in spec: raised pavement marker height

@export_group("Road build: barriers and ground (WP1.2)")
## Concrete median barrier profile (centred on d = 0, base = median_half_width_m).
@export var median_barrier_height_m: float = 0.85   # not in spec: Jersey-style barrier height
@export var median_barrier_kink_height_m: float = 0.25   # not in spec: height of the lower slope break
@export var median_barrier_kink_half_width_m: float = 0.3   # not in spec: half-width at the slope break
@export var median_barrier_top_half_width_m: float = 0.1   # not in spec: half-width of the top
## Guardrail rail (W-beam) at guardrail_d: continuous chunk geometry (posts are roadside props).
@export var guardrail_bottom_m: float = 0.45   # not in spec: rail bottom above the road surface
@export var guardrail_top_m: float = 0.75   # not in spec: rail top above the road surface
@export var guardrail_depth_m: float = 0.1   # not in spec: W-beam depth, away from the road
## Ground ribbon from the paved shoulder edge outward, far enough to vanish in the fog
## (roadside fields reach ~400 m). The verge color runs to guardrail + prop_clearance_m.
@export var ground_ribbon_width_m: float = 500.0   # not in spec: past the fog at typical lateral view angles

@export_group("Road build: chunks (WP1.2)")
## Longest mesh row spacing along s (rows also fall on every dash boundary).
@export var mesh_max_step_m: float = 10.0   # not in spec: ~1 cm chord error at the minimum radius
## Chunks are kept from this far behind the focus to the quality view distance ahead.
@export var chunk_keep_behind_m: float = 150.0   # not in spec: matches the behind-spawn distance
## Chunk builds completed per frame at most (a chunk is also time-sliced, below).
@export var chunk_builds_per_frame_count: int = 1   # not in spec: one 200 m chunk per frame is ~100x the needed rate
## Mesh rows (row intervals) built per frame: a 200 m chunk (~35 rows) spreads over
## ~3 frames, so no frame pays for a whole chunk.
@export var chunk_build_rows_per_frame_count: int = 12   # not in spec: ~1 ms of GDScript mesh work per frame on desktop
## Chunks are started this far beyond the view distance, so the time-sliced build
## finishes before the chunk is needed.
@export var chunk_prefetch_m: float = 50.0   # not in spec: ~15 frames of travel at 350 km/h and 30 fps

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


## Table samples per generation block.
func generation_block_samples() -> int:
	return int(round(generation_block_m / sample_spacing_m))


func floating_origin_shift_m() -> float:
	return Units.km_to_m(floating_origin_shift_km)
