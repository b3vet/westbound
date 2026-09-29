extends WBTest
## Water beside the road (WP6.4b): WaterPlan (shoreline offsets, sweeps, river cells)
## and WaterRibbon (the coast's ocean, the valley's river). Spec: World → Biomes
## (coastal highway: ocean on one side, the sun sinks into the sea; valley river),
## Road (floating origin), Performance budget (one draw call), Architecture rule 2
## (deterministic by seed).

const SEED := 20260928
const VIEW_M := 700.0
const POS_EPS := 0.01

var _t: Tuning
var _coast: BiomeDef
var _valley: BiomeDef
var _farmland: BiomeDef
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()
	_coast = load("res://data/biomes/coast.tres") as BiomeDef
	_valley = load("res://data/biomes/valley_fog.tres") as BiomeDef
	_farmland = load(BiomeDirector.DEFAULT_BIOME_PATH) as BiomeDef


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _origin() -> FloatingOrigin:
	var o := FloatingOrigin.new()
	o.setup(_t.road.floating_origin_shift_km)
	tree.root.add_child(o)
	_nodes.append(o)
	return o


## A director with `first` everywhere, then each [leg, biome] from that leg on.
func _director(first: BiomeDef, spans: Array = []) -> BiomeDirector:
	var d := BiomeDirector.new()
	d.default_biome = first
	d.journey = false
	tree.root.add_child(d)
	_nodes.append(d)
	d.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), null, null)
	for sp: Array in spans:
		d.set_biome_from_leg(int(sp[0]), sp[1] as BiomeDef)
	return d


func _ribbon(road: RoadPath, origin: FloatingOrigin, biome: BiomeDef, director: BiomeDirector = null,
		seed_value: int = SEED) -> WaterRibbon:
	var w := WaterRibbon.new()
	w.fallback_biome = biome
	w.biome_director = director
	w.view_distance_override_m = VIEW_M
	tree.root.add_child(w)
	_nodes.append(w)
	w.setup(RunContext.new(seed_value, RunContext.MODE_JOURNEY, _t), road, origin)
	return w


## Absolute (x, y, z) of every vertex of the ribbon's mesh.
func _abs_vertices(w: WaterRibbon, origin: FloatingOrigin) -> Array[PackedFloat64Array]:
	var out: Array[PackedFloat64Array] = []
	var m := w.mesh()
	if m.get_surface_count() == 0:
		return out
	var verts: PackedVector3Array = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var p := w.mesh_instance().position
	for v in verts:
		out.append(PackedFloat64Array([origin.origin_x + p.x + v.x, origin.origin_y + p.y + v.y,
			origin.origin_z + p.z + v.z]))
	return out


# ---------------------------------------------------------------- WaterPlan

func test_coast_ocean_is_continuous_below_the_road() -> void:
	var def := _coast.water
	if not check(def != null, "coast has water"):
		return
	eq(absi(def.side), 1, "the ocean is on one side")
	gt(def.drop_m, def.min_drop_m, "the sea lies below the road")
	eq(def.span_cell_m, 0.0, "the ocean is continuous")
	ge(def.width_m, VIEW_M * 2.0, "the ocean reaches past the fog on every tier")
	var plan := WaterPlan.new(SEED, Callable(), _coast)
	for s: float in [0.0, 500.0, 5000.0, 12345.0]:
		near(plan.shore_offset_at(s), def.shore_offset_m, 1e-9, "no sweep without biome edges at s = %s" % s)


func test_shoreline_sweeps_in_and_out_at_biome_edges() -> void:
	# Coast over legs 2-3.
	var leg := _t.legs.leg_length_m()
	var a := leg
	var b := leg * 3.0
	var d := _director(_farmland, [[2, _coast], [4, _farmland]])
	var plan := WaterPlan.new(SEED, d.biome_at)
	var def := _coast.water
	eq(plan.shore_offset_at(a - 10.0), WaterPlan.NONE, "no water in farmland")
	eq(plan.shore_offset_at(b + 10.0), WaterPlan.NONE, "no water after the coast")
	near(plan.shore_offset_at(a + def.arrive_m + 1.0), def.shore_offset_m, 1e-6, "settled after the sweep")
	near(plan.shore_offset_at((a + b) * 0.5), def.shore_offset_m, 1e-6, "settled mid-span")
	near(plan.shore_offset_at(a), def.shore_offset_m + def.arrive_offset_m, 1.0, "starts far out at the edge")
	var prev := INF
	var s := a
	while s <= a + def.arrive_m:
		var off := plan.shore_offset_at(s)
		if not le(off, prev + 1e-6, "the shoreline only comes closer while arriving (s = %s)" % s):
			return
		prev = off
		s += 10.0
	gt(plan.shore_offset_at(b - 100.0), def.shore_offset_m + 1.0, "and leaves before the span ends")


func test_river_cells_are_seeded_and_match_the_chance() -> void:
	var def := _valley.water
	if not check(def != null and def.span_cell_m > 0.0, "the valley river shows in cells"):
		return
	var a := WaterPlan.new(SEED, Callable(), _valley)
	var b := WaterPlan.new(SEED, Callable(), _valley)
	var c := WaterPlan.new(SEED + 1, Callable(), _valley)
	var present := 0
	var same := true
	var differs := false
	var n := 400
	for i in n:
		var pa := a.cell_present(i, def)
		present += 1 if pa else 0
		same = same and pa == b.cell_present(i, def)
		differs = differs or pa != c.cell_present(i, def)
	check(same, "same seed, same river")
	check(differs, "another seed, another river")
	near(float(present) / float(n), def.span_chance_frac, 0.1, "share of cells with a river")
	# Inside a present cell the river meanders but stays beyond the meadows and within its band.
	var s := 0.0
	var lo := INF
	var hi := -INF
	while s < def.span_cell_m * 40.0:
		var off := a.shore_offset_at(s)
		if off != WaterPlan.NONE:
			lo = minf(lo, off)
			hi = maxf(hi, off)
		s += 7.0
	ge(lo, def.shore_offset_m - def.meander_amplitude_m - 1e-6, "meander low bound")
	le(hi, def.shore_offset_m + def.meander_amplitude_m + def.arrive_offset_m + 1e-6, "meander + sweep high bound")
	var grid := _valley.field_grid
	gt(lo, grid.setback_m + float(grid.band_count) * grid.band_depth_m, "the river never runs through the meadows")


# ---------------------------------------------------------------- WaterRibbon

func test_ocean_mesh_lies_beyond_the_scenery_line_below_the_road() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var origin := _origin()
	var w := _ribbon(road, origin, _coast)
	w.update_view(1000.0)
	eq(w.draw_calls(), 1, "one draw call")
	gt(w.triangles(), 500, "an ocean was built")
	var def := _coast.water
	var side := float(def.side)
	var line := road.guardrail_d(0.0) + _t.road.prop_clearance_m
	var slope_end := line + def.shore_offset_m + def.slope_run_m
	var sea_y := -def.drop_m + def.lift_m
	var verts := _abs_vertices(w, origin)
	var max_out := 0.0
	var at_sea := 0
	for p in verts:
		var out := p[0] * side
		if out < line - POS_EPS:
			fail("vertex at |d| = %.2f inside the scenery line %.2f" % [out, line])
			return
		if out < slope_end - def.slope_jag_m - POS_EPS and p[1] > def.top_lift_m + POS_EPS:
			fail("something rises above the road beside it at d = %.2f (h = %.2f)" % [out, p[1]])
			return
		if absf(p[1] - sea_y) < POS_EPS:
			at_sea += 1
		max_out = maxf(max_out, out)
	gt(at_sea, 200, "the beach and sea lie flat at the sea level")
	near(max_out, slope_end + def.shore_width_m + def.width_m, POS_EPS, "out to the ocean's width")
	var s_min := INF
	var s_max := -INF
	for p in verts:
		s_min = minf(s_min, -p[2])
		s_max = maxf(s_max, -p[2])
	le(s_min, w.window_s_lo + POS_EPS, "rows from the window start")
	ge(s_max, w.window_s_hi - POS_EPS, "rows to the window end")
	ge(w.window_s_hi - 1000.0, VIEW_M, "the window reaches the view distance")


func test_ground_drops_below_the_sea_on_the_water_side_only() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var w := _ribbon(road, _origin(), _coast)
	var def := _coast.water
	var side := float(def.side)
	near(w.ground_drop_at(1000.0, side), def.drop_m + def.lift_m, 1e-6, "field lowered below the sea (flat road)")
	eq(w.ground_drop_at(1000.0, -side), 0.0, "the land side stays")
	near(w.sea_level_at(1000.0, def), -def.drop_m, 1e-6, "sea level on a flat road")
	# On a climbing road the sea stays level-ish and at least min_drop below the road.
	var hill := StraightRoadPath.new(3, _t.road, 0.0, _t.road.max_grade_frac())
	var wh := _ribbon(hill, _origin(), _coast)
	var smp := RoadSample.new()
	for s: float in [0.0, 500.0, 1600.0, 4000.0]:
		hill.sample_into(s, smp)
		le(wh.sea_level_at(s, def), smp.pos_y - def.min_drop_m + 1e-6, "min drop at s = %s" % s)
	var farm := _ribbon(road, _origin(), _farmland)
	eq(farm.ground_drop_at(1000.0, side), 0.0, "no drop without water")
	var valley := _ribbon(road, _origin(), _valley)
	eq(valley.ground_drop_at(1000.0, float(_valley.water.side)), 0.0, "rivers run at road level")


func test_no_water_where_the_biome_has_none() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var w := _ribbon(road, _origin(), _farmland)
	w.update_view(500.0)
	eq(w.triangles(), 0)
	eq(w.draw_calls(), 0, "no draw call without water")


func test_windows_swap_per_step_and_survive_origin_shifts() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var origin := _origin()
	var w := _ribbon(road, origin, _coast)
	var step := _coast.water.rebuild_step_m
	var s0 := step * 16.0
	w.update_view(s0)
	var n0 := w.rebuilds
	check(w.is_prefetching(), "the next window builds in the background")
	w.update_view(s0 + step * 0.3)
	eq(w.rebuilds, n0, "no new window inside a step")
	var before := _abs_vertices(w, origin)
	# Shift the origin 3 km away: the node moves, nothing is rebuilt, absolute
	# positions are unchanged.
	var smp := RoadSample.new()
	road.sample_into(3000.0, smp)
	check(origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z), "origin shifted")
	w.update_view(s0 + step * 0.4)
	eq(w.rebuilds, n0, "an origin shift rebuilds nothing")
	var after := _abs_vertices(w, origin)
	eq(after.size(), before.size(), "same vertex count")
	var worst := 0.0
	for i in mini(after.size(), before.size()):
		for k in 3:
			worst = maxf(worst, absf(after[i][k] - before[i][k]))
	le(worst, POS_EPS, "absolute vertex positions unchanged by the shift")
	# The next window (prefetched before the shift) swaps in at the step, in place.
	for i in 200:
		w.update_view(s0 + step * 0.5)
	w.update_view(s0 + step * 1.1)
	eq(w.rebuilds, n0 + 1, "one new window per step")
	var line := road.guardrail_d(0.0) + _t.road.prop_clearance_m
	var ok := true
	var at_sea := 0
	for p in _abs_vertices(w, origin):
		ok = ok and p[0] * float(_coast.water.side) >= line - POS_EPS
		if absf(p[1] - (_coast.water.lift_m - _coast.water.drop_m)) <= POS_EPS:
			at_sea += 1
	check(ok, "the prefetched window is in place after the shift")
	gt(at_sea, 200, "and at the sea level")
	le(w.window_s_lo, s0 + step * 1.1 - _t.road.roadside_behind_m + POS_EPS, "window follows the focus")


## Prefetching and swapping per step keep every frame cheap: the p99.5 update_view
## while driving at top speed stays well inside a frame.
func test_frame_cost_while_driving() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var w := _ribbon(road, _origin(), _coast)
	var v := Units.kmh_to_mps(_t.vehicle.car_top_speed_max_kmh) * (1.0 + Units.pct_to_frac(_t.vehicle.boost_top_speed_bonus_pct))
	var per_frame_m := v / float(_t.quality.gameplay_fps)
	w.update_view(0.0)
	var samples := PackedInt64Array()
	var s := 0.0
	while s < 6000.0:
		s += per_frame_m
		var t0 := Time.get_ticks_usec()
		w.update_view(s)
		samples.append(Time.get_ticks_usec() - t0)
	samples.sort()
	var p995 := samples[int(float(samples.size() - 1) * 0.995)]
	WBBench.report("water ribbon p99.5 frame (prefetch + swap)", float(p995), 1500.0)
	le(float(p995), WBBench.budget(1500.0), "p99.5 water frame usec")


func test_same_seed_same_river() -> void:
	var sigs: Array[int] = []
	for seed_value: int in [SEED, SEED, SEED + 7]:
		var ctx := RunContext.new(seed_value, RunContext.MODE_JOURNEY, _t)
		var road := ProceduralRoadPath.new(ctx)
		road.ensure_generated_to(9000.0)
		var w := _ribbon(road, _origin(), _valley, null, seed_value)
		var h := TraceHash.SEED
		var s := 1000.0
		while s < 8000.0:
			w.update_view(s)
			var m := w.mesh()
			if m.get_surface_count() > 0:
				var verts: PackedVector3Array = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				h = TraceHash.mix_int(h, verts.size())
				for i in range(0, verts.size(), 17):
					h = TraceHash.mix_float(h, snappedf(verts[i].x, 0.001))
					h = TraceHash.mix_float(h, snappedf(verts[i].z, 0.001))
			s += 450.0
		sigs.append(h)
	eq(sigs[0], sigs[1], "same seed: same river geometry")
	ne(sigs[0], sigs[2], "another seed: another river")


func test_sea_direction_feeds_the_horizon() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var w := _ribbon(road, _origin(), _coast)
	var mat := ShaderMaterial.new()
	mat.shader = load(HorizonSetDef.SHADER_PATH) as Shader
	w.horizon_material = mat
	w.update_view(800.0)
	var dir: Vector2 = mat.get_shader_parameter(&"sea_dir")
	# Heading 0: right of travel is +X.
	near(dir.x, float(_coast.water.side), 1e-5, "sea direction = the water's side")
	near(dir.y, 0.0, 1e-5)
	eq(w.sea_dir(), dir)
