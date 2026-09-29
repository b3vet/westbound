extends WBTest
## RoadChunkMesher (WP6.4a): road tunnels built into the chunks (shell, hill, ridge,
## portals, lamps, darker interior), canyon cliffs, ground colours blended along a
## chunk. Spec: World → Biomes (canyon: cliffs, tunnels), World → Road (flat-shaded
## ribbon chunks), Night lighting (lamps on the street-lamp ramp), Performance budget
## (no extra draw call), docs/CONTRACTS.md §13 (vertex classes). docs/BIOMES.md.

const TS := 300.0
const TE := 700.0
const EPS := 1e-3

var t: RoadTuning
var ltun: LandmarkTuning


func before_all() -> void:
	t = Tuning.load_default().road
	ltun = LandmarkTuning.load_default()


func _tunnel_road(lanes: int = 2) -> StraightRoadPath:
	var r := StraightRoadPath.new(lanes, t)
	r.add_feature(RoadFeature.make(RoadFeature.Kind.TUNNEL, TS, TE, TE - TS))
	return r


func _build(road: RoadPath, s0: float, s1: float, plan: BiomePlan = null) -> RoadChunkMesher:
	var m := RoadChunkMesher.new(t, RoadPalette.new(), ltun)
	m.biome_plan = plan
	m.cliff_seed = 77
	m.build(road, s0, s1)
	return m


## On StraightRoadPath (heading 0): world x = d, z = -s, y = height.
func _each_world_vertex(m: RoadChunkMesher, fn: Callable) -> void:
	for i in m.world_vertices.size():
		var v := m.world_vertices[i]
		fn.call(Vector3(m.anchor_x + v.x, m.anchor_y + v.y, m.anchor_z + v.z), i)


func test_arrays_fully_written_and_normals_unit() -> void:
	var road := _tunnel_road()
	for s0: float in [TS - 100.0, TS, 400.0, TE - 50.0, TE]:
		var m := _build(road, s0, s0 + t.chunk_length_m)
		var bad := 0
		for n in m.world_normals:
			if absf(n.length() - 1.0) > EPS:
				bad += 1
		eq(bad, 0, "chunk at %.0f: every world vertex written with a unit normal" % s0)
		eq(m.world_indices.size(), (m.world_vertices.size() >> 2) * 6)


## Below the overhead clearance nothing stands over a lane or shoulder (the roof, the
## portal band and its chamfers stay above it); walls and lamps are beyond the
## guardrails, the central wall inside the median barrier.
func test_shell_keeps_the_carriageways_clear() -> void:
	var road := _tunnel_road()
	var inner := road.median_barrier_d(0.0) + EPS
	var outer := road.guardrail_d(0.0) - EPS
	var low := [0]
	var roof := [0]
	for s0: float in [TS - 100.0, 400.0, 600.0]:
		var m := _build(road, s0, s0 + t.chunk_length_m)
		_each_world_vertex(m, func(p: Vector3, _i: int) -> void:
			var ad := absf(p.x)
			if ad > inner and ad < outer and p.y > EPS:
				if p.y < t.overhead_clearance_m:
					low[0] += 1
				else:
					roof[0] += 1)
	eq(low[0], 0, "nothing low over the carriageways")
	gt(roof[0], 0, "the roof spans them")


func _road_colors_near(m: RoadChunkMesher, s: float) -> Color:
	var col := Color.BLACK
	var n := 0
	for i in m.road_vertices.size():
		var v := m.road_vertices[i]
		var sv := -(m.anchor_z + v.z)
		if absf(sv - s) < 12.0 and m.road_uv2[i].y == RoadChunkMesher.TINT_ROAD:
			col += m.road_colors[i]
			n += 1
	return col / float(maxi(n, 1))


func test_interior_is_darker_and_lamps_are_street_lamps() -> void:
	var road := _tunnel_road()
	var m := _build(road, 400.0, 600.0)
	var outside := _build(road, 800.0, 1000.0)
	var in_c := _road_colors_near(m, 500.0)
	var out_c := _road_colors_near(outside, 900.0)
	near(in_c.r, out_c.r * t.tunnel_interior_shade_frac, 1e-4, "asphalt darkened inside")
	var lamps := 0
	for i in m.world_uv2.size():
		if m.world_uv2[i].x == RoadChunkMesher.EMISSIVE_STREETLAMP:
			lamps += 1
	var stations := floori(t.chunk_length_m / ltun.tunnel_lamp_spacing_m)
	within_pct(float(lamps) / 16.0, float(stations), 10.0, "a lamp station every tunnel_lamp_spacing_m (4 quads)")


## One portal face at each end, facing its traffic, emitted by exactly one chunk even
## when the portal is on a chunk boundary.
func test_portals_face_traffic_once() -> void:
	var road := _tunnel_road()
	var entrance := [0]
	var exit := [0]
	for s0: float in [100.0, TS, 500.0, TE]:
		var m := _build(road, s0, s0 + t.chunk_length_m)
		_each_world_vertex(m, func(p: Vector3, i: int) -> void:
			var n := m.world_normals[i]
			if absf(-p.z - TS) < EPS and n.z > 0.99:
				entrance[0] += 1
			elif absf(-p.z - TE) < EPS and n.z < -0.99:
				exit[0] += 1)
	eq(entrance[0], RoadChunkMesher.PORTAL_QUADS * 4, "the entrance faces approaching traffic (+z), once")
	eq(exit[0], RoadChunkMesher.PORTAL_QUADS * 4, "the exit faces the other carriageway (-z), once")


## The hill: rock colours, the ridge rising inside, hips falling to the ground beyond
## the portals, and nothing of it past a hip's end.
func test_hill_ridge_and_hips() -> void:
	var road := _tunnel_road()
	var pal := RoadPalette.new()
	var m := _build(road, 400.0, 600.0)
	var top := [0.0]
	_each_world_vertex(m, func(p: Vector3, _i: int) -> void:
		top[0] = maxf(top[0], p.y))
	near(top[0], ltun.tunnel_cover_top_m + t.tunnel_ridge_height_m, 1e-3, "the ridge over the bore")
	var hip := _build(road, TS - 100.0, TS)
	var hip_top := [0.0]
	var past := [0]
	_each_world_vertex(hip, func(p: Vector3, i: int) -> void:
		var s := -p.z
		if hip.world_colors[i] == pal.rock or hip.world_colors[i] == pal.rock_shade:
			hip_top[0] = maxf(hip_top[0], p.y)
			if s < TS - ltun.tunnel_hill_width_m - EPS:
				past[0] += 1)
	near(hip_top[0], ltun.tunnel_cover_top_m, 1e-3, "the hip meets the portal at the cover height")
	eq(past[0], 0, "nothing of the hill past the hip")


## Canyon cliffs: beyond the scenery line on both sides, cleared around a checkpoint.
func test_cliffs_stand_beyond_the_scenery_line() -> void:
	var road := StraightRoadPath.new(3, t)
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 3500.0, 3500.0, 1.0))
	var b := BiomeDef.new()
	b.id = &"walls"
	b.cliffs = CliffDef.new()
	b.cliffs.presence_left_frac = 1.0
	b.cliffs.presence_right_frac = 1.0
	b.cliffs.band_colors = PackedColorArray([Color.RED])
	var plan := BiomePlan.uniform(b, 3500.0)
	var line := road.guardrail_d(0.0) + t.prop_clearance_m
	var tall := [0, 0]
	var inside := [0]
	for s0: float in [1000.0, 1200.0]:
		var m := _build(road, s0, s0 + t.chunk_length_m, plan)
		_each_world_vertex(m, func(p: Vector3, i: int) -> void:
			if m.world_colors[i] != Color.RED:
				return
			if absf(p.x) < line - EPS:
				inside[0] += 1
			if p.y > 5.0:
				tall[0 if p.x > 0.0 else 1] += 1)
	eq(inside[0], 0, "no cliff vertex inside the scenery line")
	gt(tall[0], 0, "a wall on the right")
	gt(tall[1], 0, "a wall on the left")
	var near_cp := _build(road, 3400.0, 3600.0, plan)
	var high := [0]
	_each_world_vertex(near_cp, func(p: Vector3, i: int) -> void:
		if near_cp.world_colors[i] == Color.RED and p.y > 0.0:
			high[0] += 1)
	eq(high[0], 0, "no wall at the checkpoint (its landmark)")
	# Deterministic: same seed, same mesh.
	var a := _build(road, 1000.0, 1200.0, plan)
	var c := _build(road, 1000.0, 1200.0, plan)
	eq(a.world_vertices, c.world_vertices)


func test_ground_colours_blend_along_the_chunk() -> void:
	var road := StraightRoadPath.new(3, t)
	var pal := RoadPalette.new()
	pal.ground_field = Color(0.2, 0.2, 0.2)
	pal.ground_field_end = Color(0.8, 0.8, 0.8)
	var m := RoadChunkMesher.new(t, pal, ltun)
	m.build(road, 0.0, 200.0)
	var far := road.guardrail_d(0.0) + t.prop_clearance_m + 10.0
	var checked := 0
	for i in m.world_vertices.size():
		var v := m.world_vertices[i]
		if absf(v.x) > far and absf(v.y) < EPS:
			var u := -(m.anchor_z + v.z) / 200.0
			near(m.world_colors[i].r, lerpf(0.2, 0.8, u), 1e-4, "field colour at s = %.1f" % (u * 200.0))
			checked += 1
	gt(checked, 20)


## The heaviest chunk (a portal, the bore and canyon walls both sides) stays within the
## farmland chunk's build budget (the builder time-slices rows anyway).
func test_canyon_tunnel_chunk_cost() -> void:
	var road := _tunnel_road(3)
	var b := BiomeDef.new()
	b.cliffs = CliffDef.new()
	b.cliffs.presence_left_frac = 1.0
	b.cliffs.presence_right_frac = 1.0
	var plan := BiomePlan.uniform(b, 3500.0)
	var m := _build(road, TS - 100.0, TS + 100.0, plan)
	print("      canyon tunnel chunk: %d triangles (%d world), %d rows" % [m.triangle_count(),
		m.world_triangle_count(), m.row_count])
	le(m.triangle_count(), 9000, "triangles per chunk")
	var mesher := RoadChunkMesher.new(t, RoadPalette.new(), ltun)
	mesher.biome_plan = plan
	var usec := WBBench.usec_per_call(func() -> void: mesher.build(road, TS - 100.0, TS + 100.0), 3, 1, 3)
	WBBench.report("road chunk build (canyon tunnel, 200 m)", usec, 30000.0)
	le(usec, WBBench.budget(30000.0), "chunk build usec")
