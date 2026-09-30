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

@export_group("Biome lanes and road tunnels (WP6.4a, docs/BIOMES.md)")
## A leg whose biome has another lane count changes it this far after the leg's
## checkpoint (clear of the landmark's reach: the bridge's backstays end ~272 m after
## the line), tapering over biome_lane_taper_m.
@export var biome_lane_change_after_m: float = 320.0   # not in spec
@export var biome_lane_taper_m: float = 250.0   # not in spec
## Lanes inside a road tunnel ("tunnels and road works drop to 2").
@export var tunnel_lanes: int = 2
## Tunnel length (portal to exit).
@export var tunnel_length_min_m: float = 300.0   # not in spec
@export var tunnel_length_max_m: float = 800.0   # not in spec
## Expected tunnels per leg at BiomeDef.tunnel_frequency_scale 1 (farmland 0).
@export var tunnels_per_leg: float = 0.8   # not in spec
@export var tunnel_max_per_leg_count: int = 2   # not in spec
## Open road between two tunnels of one leg (they share one narrowed section).
@export var tunnel_gap_min_m: float = 120.0   # not in spec
@export var tunnel_gap_max_m: float = 360.0   # not in spec
## The narrowed section: the lane drop's taper (lane_taper_length_m) ends this far
## before the first portal, and the lane comes back this far after the last exit.
@export var tunnel_lane_lead_m: float = 150.0   # not in spec: the merge is done before the portal
@export var tunnel_lane_trail_m: float = 80.0   # not in spec
## Tunnels (with their tapers) stay this far after a leg's checkpoint and this far
## before the next checkpoint's first warning sign.
@export var tunnel_leg_margin_after_m: float = 650.0   # not in spec: clear of the landmark and a biome lane change
@export var tunnel_leg_margin_before_m: float = 150.0   # not in spec
## A "lane ends" warning SIGN stands this far before a lane drop's taper.
@export var lane_ends_sign_distance_m: float = 400.0   # not in spec: like road works (400 m)
## Road tunnel look: interior albedo factor (road, barrier, rails, walls) and the
## lamp strips' length along the wall (spacing and shell size: LandmarkTuning.tunnel_*).
@export var tunnel_interior_shade_frac: float = 0.42   # not in spec: "the interior reads darker"
@export var tunnel_lamp_length_m: float = 1.6   # not in spec
## A rock ridge rises over a road tunnel's bore (above the landmark-sized hill), from
## the portals inward over tunnel_ridge_ramp_m: the road dives into a mountain.
@export var tunnel_ridge_height_m: float = 20.0   # not in spec
@export var tunnel_ridge_ramp_m: float = 45.0   # not in spec

@export_group("Forks (WP6.5, docs/FORKS.md)")
## The carriageway splits at the fork checkpoint's line (the split): the left lanes go
## on as the left branch, the right lanes as the right branch. Before it the road holds
## a straight approach so both branches share the reference line up to the split.
@export var fork_approach_straight_m: float = 600.0   # not in spec: a readable Y ahead
## Each branch turns this far away from the other (left branch left, right branch right)
## in one bend right after the split, then runs straight (fork_straight_after_m).
@export var fork_branch_deflection_deg: float = 7.0   # not in spec: stays inside the 15-30 deg sun band
@export var fork_branch_radius_m: float = 1500.0   # not in spec: >= the minimum radius
@export var fork_straight_after_m: float = 2400.0   # not in spec: no bend while the other branch is in sight
## Both branches are drawn this far past the split before the choice (ForkView): at
## least the longest view distance + prefetch + a chunk, so no world system builds
## there first.
@export var fork_draw_m: float = 1200.0   # not in spec
## After the choice the other branch narrows to nothing over [draw + vanish_start,
## + vanish_len] (it curves away and fades into the fog), and its ground hands over
## to the taken branch's over fork_ground_blend_m.
@export var fork_vanish_start_m: float = 0.0   # not in spec
@export var fork_vanish_length_m: float = 450.0   # not in spec
@export var fork_ground_blend_m: float = 300.0   # not in spec
## Each branch widens back to its biome's lane count this far past the split.
@export var fork_widen_after_m: float = 350.0   # not in spec
@export var fork_widen_taper_m: float = 250.0   # not in spec
## Gore-side shoulder and rail reach full width once the branches are this far apart.
@export var fork_gore_full_gap_m: float = 8.0   # not in spec
## The crash cushion on the gore nose at the split: across (centred on the lane line
## between the two branches' lanes) and along the road.
@export var fork_cushion_width_m: float = 1.2   # not in spec: a typical attenuator
@export var fork_cushion_length_m: float = 6.0   # not in spec
## The opposite carriageway veers away to the left before the split (the carriageways
## separate), over [split - lead - length, split - lead], to `fork_veer_offset_m`, and
## narrows to nothing over the last fork_veer_fade_frac of its veer; the taken branch's
## comes back the same way from split + fork_rejoin_after_m.
@export var fork_veer_offset_m: float = 220.0   # not in spec
@export var fork_veer_length_m: float = 550.0   # not in spec
@export var fork_veer_lead_m: float = 150.0   # not in spec
@export var fork_veer_fade_frac: float = 0.35   # not in spec
@export var fork_rejoin_after_m: float = 2100.0   # not in spec: after the other branch has vanished
## Opposite traffic where its carriageway is not drawn is parked this far away (out of sight).
@export var fork_opposite_hide_m: float = 5000.0   # not in spec
## No roadside props, lamps or biome features on either side for this far past the split
## (post-choice world systems would otherwise pop them in within view).
@export var fork_quiet_after_m: float = 1000.0   # not in spec: >= longest view distance
## The main path stops reporting road past split + this until the fork is resolved (so
## no world system builds on a branch that may not be taken; the gantry fits).
@export var fork_hold_margin_m: float = 40.0   # not in spec
## After the choice the branch not taken sits this much lower (its ground always under
## the taken branch's where they overlap; invisible at that distance).
@export var fork_other_sink_m: float = 0.08   # not in spec
## Traffic around an unresolved fork: the director spawns nothing in
## [split - before, split + after]; a car still at split - guard or beyond is removed
## (it would reach a branch the player may not take). The approach is quiet by the
## time the player gets there.
@export var fork_breather_before_m: float = 900.0   # not in spec
@export var fork_breather_after_m: float = 1200.0   # not in spec
@export var fork_traffic_guard_m: float = 60.0   # not in spec

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
## The simulation's view of the road ahead, the same on every device (N8.2): the road is
## generated and the leg planner queues checkpoints this far past the car, the director
## spawns traffic past it (its "fog end") and fork candidates are built within it. The
## quality tier's view distance (fog, draw distance) is rendering only and may be shorter
## (cars beyond it wait in the fog). Must be >= every tier's view distance
## (QualityTuning.view_distance_m) so traffic always spawns past the fog (fairness rule 5).
@export var sim_horizon_m: float = 800.0   # not in spec: N8.2, tier-independent simulation (= the high tier's view distance)

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
