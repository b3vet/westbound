class_name WaterDef
extends Resource
## Water beside the road: the coast's ocean ("ocean on one side ... the sun sinks
## into the sea") and the valley's river glimpses. Spec: World → Biomes (coastal
## highway, valley fog), Color script (every biome must look good across it), Night
## lighting (no real reflections). Drawn by WaterRibbon (src/world/ocean/).
##
## Cross-section on the water's side, measured outward from the scenery line
## (guardrail face + RoadTuning.prop_clearance_m), so the road and its clear zone
## are never covered:
##   scenery line | shore_offset_m (+ meander, + arrival) | shore strip | waterline |
##   surf | water ... width_m | far bank (rivers)
## Flat water (`drop_m` = 0, rivers) lies `lift_m` above the road plane at each row
## (the ground ribbon is at road level), so it follows the road's elevation.
##
## Sea slopes (`drop_m` > 0, the coast): the road is cut into the hillside above a
## flat sea, so the ocean fills the view on its side (a low camera sees nothing of
## water at road level beyond a thin band). The first `shore_offset_m` is a strip at
## road level (the seawall stands on it), then the land falls over `slope_run_m` in a
## craggy, faceted slope to the sea level, where the beach, surf and sea lie flat. The
## sea level is the road's elevation smoothed over +-`level_smoothing_m`, minus
## `drop_m`, and at least `min_drop_m` below the road at every row. The ground ribbon
## beyond the scenery line on the water side must be lowered below the sea
## (WaterRibbon.ground_drop_at: the road mesher hook, GroundDropMesher); no roadside
## prop may stand on that side beyond the strip. Rocky islets (sea stacks, the
## lighthouse) stand in the sea, merged into the water's own mesh.

## Which side of the road the water is on: -1 left (d < 0), +1 right. The coast's
## ocean is on the player's side (+1, next to their carriageway: a low chase camera
## sees the sea only there) and must be the sun's side, so the sun sinks into the sea:
## the road plan has to keep the sun right of the axis through coast legs
## (docs/BIOMES.md).
@export var side: int = -1
## Scenery line to the start of the shore strip.
@export var shore_offset_m: float = 6.0
## Shore strip (beach, river bank) from its start to the waterline.
@export var shore_width_m: float = 24.0
## Waterline to the far edge of the water.
@export var width_m: float = 3000.0
## A bank strip beyond the water (rivers); 0 = none.
@export var far_bank_width_m: float = 0.0
## Surf / foam band from the waterline.
@export var surf_width_m: float = 5.0
## First water column width beyond the surf; each next one is `column_growth_factor`
## wider (fine facets near the shore, few far away).
@export var near_column_m: float = 9.0
@export var column_growth_factor: float = 1.6
## Rows along s.
@export var row_step_m: float = 12.0
## Height above the road plane (clears the ground ribbon).
@export var lift_m: float = 0.35

@export_group("Sea cliffs")
## Nominal sea level below the (smoothed) road; 0 = flat water at road level.
@export var drop_m: float = 0.0
@export var min_drop_m: float = 8.0
@export var level_smoothing_m: float = 1600.0
## Horizontal run of the slope from the strip's edge to the beach.
@export var slope_run_m: float = 46.0
## How far each row's slope breaks jut in and out (craggy, faceted), at most.
@export var slope_jag_m: float = 4.0
## Height of the road-level strip above the road plane (it meets the verge there).
@export var top_lift_m: float = 0.02

@export_group("Islets")
## Rocky islets in the sea (sea stacks, a lighthouse): meshes (world conventions,
## UV2.x emissive class), weights, per cell of `islet_cell_m` with `islet_chance_frac`,
## `islet_offset_min_m`..`max_m` beyond the waterline, scaled in the range.
@export var islet_mesh_paths: PackedStringArray = []
@export var islet_weights: PackedFloat64Array = []
@export var islet_cell_m: float = 500.0
@export var islet_chance_frac: float = 0.0
@export var islet_offset_min_m: float = 40.0
@export var islet_offset_max_m: float = 260.0
@export var islet_scale_min_factor: float = 0.8
@export var islet_scale_max_factor: float = 1.3

@export_group("Colors (sRGB)")
@export var shore_color: Color = Color(0.86, 0.79, 0.62)
## Road-level strip (usually the biome's ground color), the upper slope (scrub) and
## the lower slope (rock).
@export var top_color: Color = Color(0.55, 0.57, 0.38)
@export var cliff_color: Color = Color(0.49, 0.46, 0.42)
@export var cliff_dark_color: Color = Color(0.36, 0.34, 0.32)
@export var far_bank_color: Color = Color(0.45, 0.52, 0.3)
@export var foam_color: Color = Color(0.9, 0.93, 0.92)
@export var shallow_color: Color = Color(0.2, 0.55, 0.58)
@export var deep_color: Color = Color(0.08, 0.26, 0.4)
## Distance from the waterline over which the water goes from shallow to deep.
@export var deep_distance_m: float = 140.0

@export_group("Waves and light (water.gdshader)")
## Vertex bob amplitude of the faceted surface, reached `wave_ramp_m` from the waterline.
@export var wave_height_m: float = 0.3
@export var wave_ramp_m: float = 14.0
@export var wave_period_s: float = 3.5
## How much the sky reflects at grazing angles (Fresnel), and the gain of the sun's
## reflected halo (the glittering sun path; follows the color script's sun glow).
@export var sky_reflect_factor: float = 0.7
@export var sun_path_gain: float = 2.2
## Fraction of the view distance the water is pulled toward the camera in depth
## (the lift alone z-fights with the ground ribbon far away).
@export var depth_pull_frac: float = 0.004

@export_group("Presence")
## 0 = continuous through the biome. > 0: the water shows in cells of this length,
## each with `span_chance_frac` (river glimpses), sweeping in and out at the cell ends.
@export var span_cell_m: float = 0.0
@export var span_chance_frac: float = 1.0
## At the ends of a biome span (and of a river cell) the shoreline sweeps in from
## `arrive_offset_m` further out over `arrive_m`.
@export var arrive_m: float = 600.0
@export var arrive_offset_m: float = 700.0
## Lazy meander of the shoreline (0 = straight): amplitude and wavelength.
@export var meander_amplitude_m: float = 0.0
@export var meander_length_m: float = 900.0
## Window step (BiomeFeature): the next window is built while this one shows.
## Background build budget of the next window: rows per frame.
@export var build_units_per_frame: int = 3
@export var rebuild_step_m: float = 60.0


## The side of the sun the road plan must hold beside this water (RoadPlanGen's
## convention: +1 the road heads right of the sun, -1 left; 0 = free): a sea below the
## road (`drop_m` > 0, the coast) keeps the sun on its own side, so the sun sinks into
## the sea (-side: water on the right needs the sun right of the axis). Rivers: free.
func road_sun_side() -> int:
	return -signi(side) if drop_m > 0.0 else 0


## |d| offsets of the water columns from the waterline: 0, surf, then growing
## columns until width_m (the last is exactly width_m).
func water_columns() -> PackedFloat64Array:
	var out := PackedFloat64Array([0.0])
	var x := minf(surf_width_m, width_m)
	if x > 0.0:
		out.append(x)
	var w := near_column_m
	while x < width_m:
		x = minf(x + w, width_m)
		out.append(x)
		w *= column_growth_factor
	return out
