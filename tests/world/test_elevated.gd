extends WBTest
## Elevated highway stretches (WP6.4b, city): ElevatedPlan (where the ground drops
## below the road), ElevatedSections (piers, deck edges, parapets, underside) and the
## GroundDropMesher hook (the ground ribbon lowered, the road untouched). Spec:
## World → Biomes (city: elevated highway sections), Checkpoint landmarks, Road
## (floating origin), Performance budget, Architecture rule 2 (deterministic by seed).

const SEED := 20260928
const VIEW_M := 700.0
const POS_EPS := 0.01
const LEG_M := 3500.0
const CHECKPOINTS := 12

var _t: Tuning
var _city: BiomeDef
var _farmland: BiomeDef
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()
	_city = load("res://data/biomes/city.tres") as BiomeDef
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


func _sections(road: RoadPath, origin: FloatingOrigin, clearance: LandmarkClearance = null) -> ElevatedSections:
	var e := ElevatedSections.new()
	e.fallback_biome = _city
	e.clearance = clearance
	e.view_distance_override_m = VIEW_M
	tree.root.add_child(e)
	_nodes.append(e)
	e.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, origin)
	return e


## Middle of the first full-height stretch after `from`.
func _stretch_mid(plan: ElevatedPlan, from: float) -> float:
	var def := _city.elevated
	var s := from
	while s < from + def.cell_length_m * 40.0:
		if plan.drop_at(s) >= def.height_m - 1e-6:
			return s + def.ramp_m
		s += 5.0
	return -1.0


# ---------------------------------------------------------------- ElevatedPlan

func test_stretches_are_seeded_whole_and_smooth() -> void:
	var def := _city.elevated
	if not check(def != null, "the city has elevated sections"):
		return
	var a := ElevatedPlan.new(SEED, Callable(), _city)
	var b := ElevatedPlan.new(SEED, Callable(), _city)
	var c := ElevatedPlan.new(SEED + 1, Callable(), _city)
	var cells := 200
	var with_stretch := 0
	var differs := false
	for i in cells:
		var has := a.cell_has_stretch(i, def)
		with_stretch += 1 if has else 0
		differs = differs or has != c.cell_has_stretch(i, def)
	near(float(with_stretch) / float(cells), def.chance_frac, 0.1, "share of cells with a stretch")
	check(differs, "another seed, other stretches")
	var max_slope := 0.0
	var prev := a.drop_at(0.0)
	var step := 2.0
	var s := step
	var same := true
	while s < float(cells) * def.cell_length_m * 0.25:
		var dr := a.drop_at(s)
		same = same and dr == b.drop_at(s)
		if not (dr >= 0.0 and dr <= def.height_m + 1e-9):
			fail("drop %s out of range at s = %s" % [dr, s])
			return
		max_slope = maxf(max_slope, absf(dr - prev) / step)
		prev = dr
		s += step
	check(same, "same seed, same stretches")
	# smoothstep's steepest slope is 1.5 x height / ramp.
	le(max_slope, 1.5 * def.height_m / def.ramp_m * 1.02, "the ground falls away smoothly (no step)")
	for i in cells:
		near(a.drop_at(float(i) * def.cell_length_m), 0.0, 1e-9, "every stretch lies inside its cell")


func test_stretches_stay_inside_the_city() -> void:
	var d := BiomeDirector.new()
	d.default_biome = _farmland
	tree.root.add_child(d)
	_nodes.append(d)
	d.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), null, null)
	d.set_biome_from(5000.0, _city)
	d.set_biome_from(16000.0, _farmland)
	var plan := ElevatedPlan.new(SEED, d.biome_at)
	var s := 0.0
	var elevated := 0.0
	while s < 25000.0:
		var dr := plan.drop_at(s)
		if dr > 0.0:
			elevated += 10.0
			check(s > 5000.0 and s < 16000.0, "elevated only in the city (s = %s)" % s)
		s += 10.0
	gt(elevated, 1000.0, "the city has elevated road")


func test_stretches_avoid_checkpoint_landmarks() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var kinds := LandmarkBuilds.kinds()
	for i in CHECKPOINTS:
		var cp := LEG_M * float(i + 1)
		for w in _t.legs.checkpoint_warning_distances_m:
			road.add_feature(RoadFeature.make(RoadFeature.Kind.SIGN, cp - w, cp - w, w, ProceduralRoadPath.SIGN_CHECKPOINT))
		road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, cp, cp, float(i + 1), kinds[i % kinds.size()]))
	var clearance := LandmarkClearance.new()
	clearance.setup(road, LandmarkTuning.load_default())
	var free := ElevatedPlan.new(SEED, Callable(), _city)
	var plan := ElevatedPlan.new(SEED, Callable(), _city)
	plan.clearance = clearance
	var s := 0.0
	var dropped := 0
	var elevated := 0
	while s < LEG_M * float(CHECKPOINTS):
		var dr := plan.drop_at(s)
		if dr > 0.0:
			elevated += 1
			if clearance.blocks(s, s, -1.0e4, 1.0e4, 1.0e9):
				fail("elevated over a landmark zone at s = %s" % s)
				return
		elif free.drop_at(s) > 0.0:
			dropped += 1
		s += 20.0
	gt(elevated, 100, "stretches remain")
	gt(dropped, 0, "stretches over landmark zones were dropped")


# ---------------------------------------------------------------- ElevatedSections

func test_structure_holds_the_road_without_touching_it() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var origin := _origin()
	var e := _sections(road, origin)
	var mid := _stretch_mid(e.plan, 2000.0)
	if not check(mid > 0.0, "found a stretch"):
		return
	e.update_view(mid)
	eq(e.draw_calls(), 1, "one draw call")
	var m := e.mesh()
	if not check(m.get_surface_count() == 1, "a mesh was built"):
		return
	var arrays := m.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	check(arrays[Mesh.ARRAY_COLOR] != null, "vertex colors (world material)")
	eq(normals.size(), verts.size(), "normals")
	var p := e.mesh_instance().position
	var outer := road.shoulder_outer_d(0.0)
	var grail := road.guardrail_d(0.0)
	var def := _city.elevated
	var lowest := 0.0
	for v in verts:
		var x := origin.origin_x + p.x + v.x
		var y := origin.origin_y + p.y + v.y
		var ad := absf(x)
		lowest = minf(lowest, y)
		if ad < outer - POS_EPS and y > POS_EPS:
			fail("structure above the carriageway at |d| = %.2f, h = %.2f" % [ad, y])
			return
		if y > ElevatedSections.DECK_LIFT_M + POS_EPS and ad < grail - POS_EPS:
			fail("parapet inside the guardrail at |d| = %.2f" % ad)
			return
	near(lowest, -def.height_m, 0.05, "piers reach the lowered ground")
	check(verts.size() > 200, "piers and deck edges")


func test_frame_cost_while_driving() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var e := _sections(road, _origin())
	var v := Units.kmh_to_mps(_t.vehicle.car_top_speed_max_kmh) * (1.0 + Units.pct_to_frac(_t.vehicle.boost_top_speed_bonus_pct))
	var per_frame_m := v / float(_t.quality.gameplay_fps)
	e.update_view(0.0)
	var samples := PackedInt64Array()
	var s := 0.0
	while s < 8000.0:
		s += per_frame_m
		var t0 := Time.get_ticks_usec()
		e.update_view(s)
		samples.append(Time.get_ticks_usec() - t0)
	samples.sort()
	var p995 := samples[int(float(samples.size() - 1) * 0.995)]
	WBBench.report("elevated sections p99.5 frame (prefetch + swap)", float(p995), 1500.0)
	le(float(p995), WBBench.budget(1500.0), "p99.5 elevated frame usec")


# ---------------------------------------------------------------- Road mesher hook

func test_ground_mesher_lowers_only_the_ground() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var base := RoadChunkMesher.new(_t.road, RoadPalette.new())
	var hooked := GroundDropMesher.new(_t.road, base.palette)
	var drop := 7.5
	hooked.drop_at = func(_s: float) -> float: return drop
	base.build(road, 400.0, 600.0)
	hooked.build(road, 400.0, 600.0)
	eq(hooked.road_vertices, base.road_vertices, "road surface untouched")
	eq(hooked.world_vertices.size(), base.world_vertices.size(), "same world geometry size")
	var lowered := 0
	for i in base.world_vertices.size():
		var col := base.world_colors[i]
		var a := base.world_vertices[i]
		var b := hooked.world_vertices[i]
		if col == base.palette.ground_verge or col == base.palette.ground_field:
			near(b.y, a.y - drop, 1e-4, "ground lowered")
			lowered += 1
		else:
			near((b - a).length(), 0.0, 1e-6, "barrier and rails untouched")
	gt(lowered, 0, "ground vertices found")

