extends WBTest
## WP6.4c: WP6.4b's biome features wired into the real run. The run owns WaterRibbon,
## ElevatedSections and FogCards (BiomeFeatures) with its BiomeDirector; the road
## builder lowers its ground under the city's viaducts and beside the coast's sea
## (RoadBuilder.set_ground_drop); the sky's one horizon material takes the biome
## extensions and the sea direction; retries and floating-origin shifts reuse every
## node. Spec: World → Biomes (coast: the sea below the road, the sun sinks into it;
## city: elevated highway sections; valley fog), Road (floating origin, pooling),
## Performance budget. docs/BIOMES.md → Wiring.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const CITY_LEG := 6
const VALLEY_LEG := 8
const COAST_LEG := 9

var t: Tuning
var _runs: Array[Run] = []


func before_each() -> void:
	t = Tuning.load_default()


func after_each() -> void:
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame


func _make(run_seed: int = SEED) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	r.infinite_lives = true
	return r


func _frames(r: Run, n: int) -> void:
	for i in n:
		for k in TICKS_PER_FRAME:
			r.tick()
		r.frame(FRAME_S)


func _leg_s(leg: int, into_m: float) -> float:
	return float(leg - 1) * t.legs.leg_length_m() + into_m


## Lowest ground vertex of the live chunk at s, relative to the road there (m).
func _chunk_drop(r: Run, s: float) -> float:
	var k := int(floor(s / t.road.chunk_length_m))
	var c := r.builder.get_chunk(k)
	if c == null:
		return 0.0
	var smp := r.road.sample(s)
	var verts: PackedVector3Array = c.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lowest := INF
	for v in verts:
		lowest = minf(lowest, float(c.anchor_y) + v.y - smp.pos_y)
	return lowest


func test_run_wires_the_features() -> void:
	var r := _make()
	check(r.features != null, "the run owns the biome features")
	eq(r.features.features().size(), 3, "water, elevated, fog")
	for f in r.features.features():
		eq(f.biome_director, r.biome_director, "%s follows the run's biome plan" % f.name)
		check(f.road == r.road, "%s is set up on the run's road" % f.name)
	check(r.builder.has_ground_drop(), "the road mesher lowers the ground where features need it")
	check(r.features.water.horizon_material != null, "the water feeds a horizon material")
	eq(r.features.water.horizon_material, r.sky.horizon_material(), "the sky's own")
	eq(r.features.elevated.clearance, r.features.clearance, "the viaducts keep clear of landmarks")
	eq(r.traffic_view.biome_director, r.biome_director, "traffic palettes follow the biome")
	var coast := BiomePlan.load_biome(t.legs.endless_biome_id)
	ge(r.reach_behind_m(), coast.water.level_smoothing_m, "the road is kept for the sea level's smoothing")


func test_city_viaducts_lower_the_ground() -> void:
	var r := _make()
	# The middle of the first elevated stretch in the city legs.
	var s := _leg_s(CITY_LEG, 400.0)
	var plan := r.features.elevated.plan
	var end := _leg_s(CITY_LEG + 2, 0.0)
	while s < end and plan.drop_at(s) < plan.def_at(s).height_m:
		s += 20.0
	if not check(s < end, "the city legs have an elevated stretch at full height"):
		return
	r.dev_teleport(s, Units.kmh_to_mps(t.legs.start_speed_kmh))
	_frames(r, 3)
	eq(r.features.elevated.draw_calls(), 1, "the viaduct is drawn")
	gt(r.features.elevated.triangles(), 0)
	le(_chunk_drop(r, s), -0.9 * plan.def_at(s).height_m, "the ground under the viaduct is lowered")
	# Farmland keeps its ground at road level.
	var r2 := _make()
	_frames(r2, 3)
	ge(_chunk_drop(r2, r2.car.state.s), -2.0, "no drop in the farmland")
	eq(r2.features.draw_calls(), 0, "no features in the farmland")


func test_coast_sea_below_the_road_with_the_sun_over_it() -> void:
	var r := _make()
	var s := _leg_s(COAST_LEG, 1600.0)
	r.dev_teleport(s, Units.kmh_to_mps(t.legs.start_speed_kmh))
	_frames(r, 3)
	var coast := r.biome_director.biome_at(s)
	eq(coast.id, &"coast")
	eq(r.features.water.draw_calls(), 1, "the sea is drawn")
	gt(r.features.water.ground_drop_at(s, float(coast.water.side)), coast.water.min_drop_m,
		"the ground on the sea side lies below the sea")
	le(_chunk_drop(r, s), -coast.water.min_drop_m, "and the road chunk is built that way")
	lt(r.road.heading_at(s), 0.0, "the sun is right of the road, over the sea")
	var mat := r.sky.horizon_material()
	eq(mat.get_shader_parameter(&"layer_land"), coast.horizon_def.layer_land, "the coast's horizon set")
	var sea: Vector2 = mat.get_shader_parameter(&"sea_dir")
	near(sea.length(), 1.0, 1e-4, "the horizon knows where the sea is")


func test_valley_fog_cards_and_river() -> void:
	var r := _make()
	var s := _leg_s(VALLEY_LEG, 1200.0)
	r.dev_teleport(s, Units.kmh_to_mps(t.legs.start_speed_kmh))
	_frames(r, 3)
	eq(r.biome_director.biome_at(s).id, &"valley_fog")
	gt(r.features.fog.bank_count, 0, "fog banks in the valley")
	le(r.features.draw_calls(), 2, "fog cards and, sometimes, the river: a draw call each")


## Retries rebuild on the same nodes, and a floating-origin shift moves the meshes
## without a rebuild.
func test_retry_and_origin_shift_reuse_the_nodes() -> void:
	var r := _make()
	var s := _leg_s(COAST_LEG, 900.0)
	r.dev_teleport(s, Units.kmh_to_mps(t.legs.start_speed_kmh))
	_frames(r, 3)
	var nodes: Array[Node] = []
	for f in r.features.features():
		nodes.append(f.mesh_instance())
	var children := r.features.get_child_count()
	var water := r.features.water
	var rebuilds := water.rebuilds
	# World position = origin + node position must survive a shift.
	var o := r.origin
	var before := Vector3(o.origin_x, o.origin_y, o.origin_z) + water.mesh_instance().position
	o.update_focus(o.origin_x + o.shift_distance_m * 1.5, o.origin_y, o.origin_z)
	var after := Vector3(o.origin_x, o.origin_y, o.origin_z) + water.mesh_instance().position
	near(after.distance_to(before), 0.0, 0.01, "the sea stays put in the world across a shift")
	eq(water.rebuilds, rebuilds, "no rebuild for a shift")
	r.retry()
	_frames(r, 2)
	r.dev_teleport(s, Units.kmh_to_mps(t.legs.start_speed_kmh))
	_frames(r, 3)
	eq(r.features.get_child_count(), children, "no nodes added on retry")
	for i in nodes.size():
		check(r.features.features()[i].mesh_instance() == nodes[i], "the same mesh node after a retry")
	eq(r.features.water.draw_calls(), 1, "the sea is back after the retry")
