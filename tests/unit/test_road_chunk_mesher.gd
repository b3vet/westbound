extends WBTest
## RoadChunkMesher: chunk seams, dash continuity, marking positions, §13 vertex
## classes, normals and winding, lane-count tapers without gaps, precision far from
## the start. Spec: World → Road; Architecture rule 6; docs/CONTRACTS.md §2, §13.

const MM := 0.001
const EPS := 1e-6
const R := 1200.0

var t: RoadTuning


func before_all() -> void:
	t = Tuning.load_default().road


func _build(road: RoadPath, s0: float, s1: float) -> RoadChunkMesher:
	var m := RoadChunkMesher.new(t)
	m.build(road, s0, s1)
	return m


## Absolute (64-bit) world point of a mesher vertex.
func _abs(m: RoadChunkMesher, v: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([m.anchor_x + v.x, m.anchor_y + v.y, m.anchor_z + v.z])


func _dist(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


## Every vertex (both surfaces) lying in the cross-section plane at s.
func _vertices_at(m: RoadChunkMesher, road: RoadPath, s: float) -> Array[PackedFloat64Array]:
	var smp := road.sample(s)
	var fwd := Vector3(smp.tangent.x, 0.0, smp.tangent.z).normalized()
	var out: Array[PackedFloat64Array] = []
	for verts: PackedVector3Array in [m.road_vertices, m.world_vertices]:
		for v in verts:
			var p := _abs(m, v)
			var along := (p[0] - smp.pos_x) * fwd.x + (p[2] - smp.pos_z) * fwd.z
			if absf(along) < MM:
				out.append(p)
	return out


func _check_seam(road: RoadPath, s_boundary: float, label: String) -> void:
	var a := _build(road, s_boundary - t.chunk_length_m, s_boundary)
	var b := _build(road, s_boundary, s_boundary + t.chunk_length_m)
	var va := _vertices_at(a, road, s_boundary)
	var vb := _vertices_at(b, road, s_boundary)
	if not gt(va.size(), 50, "%s: boundary vertices found" % label):
		return
	eq(va.size(), vb.size(), "%s: same boundary vertex count on both sides" % label)
	var worst := 0.0
	for p in va:
		var best := INF
		for q in vb:
			best = minf(best, _dist(p, q))
		worst = maxf(worst, best)
	for q in vb:
		var best := INF
		for p in va:
			best = minf(best, _dist(p, q))
		worst = maxf(worst, best)
	le(worst, MM, "%s: boundary vertices coincide within 1 mm" % label)


## [center_d, width, s_start, s_end, tint, emissive] per road-surface quad, for a
## straight heading-0 road (x = d, s = -z).
func _quads_straight(m: RoadChunkMesher) -> Array[PackedFloat64Array]:
	var out: Array[PackedFloat64Array] = []
	for q in m.road_vertices.size() >> 2:
		var o := q * 4
		var x0 := INF
		var x1 := -INF
		var z0 := INF
		var z1 := -INF
		for i in 4:
			var p := _abs(m, m.road_vertices[o + i])
			x0 = minf(x0, p[0])
			x1 = maxf(x1, p[0])
			z0 = minf(z0, p[2])
			z1 = maxf(z1, p[2])
		out.append(PackedFloat64Array([0.5 * (x0 + x1), x1 - x0, -z1, -z0,
				m.road_uv2[o].y, m.road_uv2[o].x]))
	return out


# ---------------------------------------------------------------- Tuning

func test_build_tuning_fields_loaded() -> void:
	gt(t.dash_length_m, 0.0)
	gt(t.dash_gap_m, 0.0)
	gt(t.lane_line_width_m, 0.0)
	gt(t.edge_line_width_m, 0.0)
	gt(t.reflector_spacing_m, 0.0)
	gt(t.median_barrier_height_m, t.median_barrier_kink_height_m)
	le(t.median_barrier_kink_half_width_m, t.median_half_width_m)
	gt(t.guardrail_top_m, t.guardrail_bottom_m)
	gt(t.ground_ribbon_width_m, t.ground_verge_width_m)
	lt(t.ground_ribbon_width_m, t.min_curve_radius_m, "ground ribbon must not fold on the inside of a bend")
	ge(t.chunk_builds_per_frame_count, 1)
	gt(t.lane_taper_default_m, 0.0)


# ---------------------------------------------------------------- Seams

func test_seams_straight() -> void:
	var road := StraightRoadPath.new(3, t, 0.4, 0.04, Vector3(30.0, 5.0, -12.0))
	_check_seam(road, 200.0, "straight k0|k1")
	_check_seam(road, 1400.0, "straight k6|k7")


func test_seams_arc_right() -> void:
	var road := ArcRoadPath.new(R, 1, 3, t, 0.2)
	_check_seam(road, 200.0, "arc right k0|k1")
	_check_seam(road, 2600.0, "arc right k12|k13")


func test_seams_arc_left() -> void:
	var road := ArcRoadPath.new(R, -1, 4, t, -0.5, Vector3(-40.0, 2.0, 7.0))
	_check_seam(road, 400.0, "arc left k1|k2")


func test_rows_hit_chunk_bounds_and_stay_short() -> void:
	var m := _build(ArcRoadPath.new(R, 1, 3, t), 200.0, 400.0)
	near(m.row_s(0), 200.0, EPS, "first row at s0")
	near(m.row_s(m.row_count - 1), 400.0, EPS, "last row at s1")
	for r in m.row_count - 1:
		var step := m.row_s(r + 1) - m.row_s(r)
		gt(step, 0.0, "rows increase")
		le(step, t.mesh_max_step_m + EPS, "row spacing bounded")


# ---------------------------------------------------------------- Markings

func test_dashes_continuous_across_chunks() -> void:
	var road := StraightRoadPath.new(3, t)
	var line_d := road.lanes_left_edge_d(0.0) + road.lane_width(0.0)
	var period := t.dash_length_m + t.dash_gap_m
	for side: float in [1.0, -1.0]:
		var spans: Array[Vector2] = []
		for k in 3:
			var m := _build(road, k * t.chunk_length_m, (k + 1) * t.chunk_length_m)
			for q in _quads_straight(m):
				if q[4] == RoadChunkMesher.TINT_LINE and absf(q[0] - side * line_d) < 0.01:
					spans.append(Vector2(q[2], q[3]))
		spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
		# Merge touching pieces (dashes split by rows or chunk boundaries).
		var runs: Array[Vector2] = []
		for sp in spans:
			if not runs.is_empty() and absf(runs[-1].y - sp.x) < MM:
				runs[-1].y = sp.y
			else:
				runs.append(sp)
		eq(runs.size(), int(3 * t.chunk_length_m / period), "one dash per period over 600 m (side %s)" % side)
		for run in runs:
			near(run.y - run.x, t.dash_length_m, MM, "dash length at s=%s" % run.x)
			var ph := fposmod(run.x, period)
			check(ph < MM or period - ph < MM, "dash starts on the absolute phase (s=%s)" % run.x)


func test_lines_at_lane_edges() -> void:
	for lanes in [2, 3, 4]:
		var road := StraightRoadPath.new(lanes, t)
		var m := _build(road, 0.0, t.chunk_length_m)
		var left := road.lanes_left_edge_d(0.0)
		var w := road.lane_width(0.0)
		var expected: Array[float] = [left, road.lanes_right_edge_d(0.0)]
		for k in range(1, lanes):
			expected.append(left + k * w)
		var found: Array[float] = []
		for q in _quads_straight(m):
			if q[4] != RoadChunkMesher.TINT_LINE or q[5] != RoadChunkMesher.EMISSIVE_NONE:
				continue
			var c := snappedf(q[0], 0.001)
			if not found.has(c):
				found.append(c)
			var is_edge := absf(absf(q[0]) - left) < 0.01 or absf(absf(q[0]) - expected[1]) < 0.01
			near(q[1], t.edge_line_width_m if is_edge else t.lane_line_width_m, MM, "line width at d=%s" % q[0])
		eq(found.size(), 2 * expected.size(), "%d lanes: line positions (both sides)" % lanes)
		for d in expected:
			check(found.has(snappedf(d, 0.001)), "%d lanes: line at d=%s" % [lanes, d])
			check(found.has(snappedf(-d, 0.001)), "%d lanes: mirrored line at d=%s" % [lanes, -d])


func test_reflectors_on_lane_lines() -> void:
	var road := StraightRoadPath.new(3, t)
	var m := _build(road, 0.0, t.chunk_length_m)
	var per_row := 2 * 2  # 2 lane lines x 2 carriageways
	var rows := int(ceilf((t.chunk_length_m - (t.dash_length_m + 0.5 * t.dash_gap_m)) / t.reflector_spacing_m))
	eq(m.reflector_count, rows * per_row, "reflector count")
	var left := road.lanes_left_edge_d(0.0)
	var w := road.lane_width(0.0)
	var n := 0
	for q in _quads_straight(m):
		if q[5] != RoadChunkMesher.EMISSIVE_REFLECTOR:
			continue
		n += 1
		var dd := absf(q[0])
		check(absf(dd - (left + w)) < 0.1 or absf(dd - (left + 2.0 * w)) < 0.1, "reflector on a lane line (d=%s)" % q[0])
		check(not m.dash_on_at(0.5 * (q[2] + q[3])), "reflector sits in a dash gap")
	eq(n, m.reflector_count * RoadChunkMesher.REFLECTOR_QUADS, "5 faces per reflector")


# ---------------------------------------------------------------- Vertex classes, normals

func test_vertex_classes_normals_and_winding() -> void:
	var road := ArcRoadPath.new(R, 1, 3, t)
	var m := _build(road, 400.0, 600.0)
	var counts := {}
	for i in m.road_uv2.size():
		var uv := m.road_uv2[i]
		var key := "%d/%d" % [int(uv.x), int(uv.y)]
		counts[key] = int(counts.get(key, 0)) + 1
	check(counts.has("0/1"), "road surface: tint class 1")
	check(counts.has("0/2"), "lines: tint class 2")
	check(counts.has("1/0"), "reflectors: emissive class 1")
	eq(counts.size(), 3, "no other road classes: %s" % str(counts))
	for i in m.world_uv2.size():
		if m.world_uv2[i] != Vector2.ZERO:
			fail("world surface uses class 0/0")
			break
	eq(m.road_vertices.size(), m.road_normals.size())
	eq(m.road_vertices.size(), m.road_colors.size())
	eq(m.world_vertices.size(), m.world_normals.size())
	eq(m.world_vertices.size(), m.world_colors.size())
	var bad_unit := 0
	var bad_up := 0
	var bad_wind := 0
	var up := road.sample(500.0).up
	for surf in 2:
		var verts := m.road_vertices if surf == 0 else m.world_vertices
		var norms := m.road_normals if surf == 0 else m.world_normals
		var idx := m.road_indices if surf == 0 else m.world_indices
		for i in norms.size():
			if absf(norms[i].length() - 1.0) > 1e-3:
				bad_unit += 1
			if surf == 0 and m.road_uv2[i].x == RoadChunkMesher.EMISSIVE_NONE and norms[i].dot(up) < 0.99:
				bad_up += 1
		for tri in range(0, idx.size(), 3):
			var a := verts[idx[tri]]
			var b := verts[idx[tri + 1]]
			var c := verts[idx[tri + 2]]
			var fn := (c - a).cross(b - a)
			if fn.length_squared() > 1e-12 and fn.dot(norms[idx[tri]]) <= 0.0:
				bad_wind += 1
	eq(bad_unit, 0, "unit normals")
	eq(bad_up, 0, "road surface normals point up")
	eq(bad_wind, 0, "front faces (clockwise) face the normal")


func test_barrier_and_rails_in_place() -> void:
	var road := StraightRoadPath.new(3, t)
	var m := _build(road, 0.0, t.chunk_length_m)
	var max_h := -INF
	var rail_d := 0.0
	for v in m.world_vertices:
		if absf(v.x) <= road.median_barrier_d(0.0) + EPS:
			max_h = maxf(max_h, v.y)
		if v.y > t.guardrail_bottom_m - EPS:
			rail_d = maxf(rail_d, absf(v.x))
	near(max_h, t.median_barrier_height_m, MM, "median barrier height")
	near(rail_d, road.guardrail_d(0.0) + t.guardrail_depth_m, MM, "guardrail rail at guardrail_d")
	var ground_out := 0.0
	for v in m.world_vertices:
		ground_out = maxf(ground_out, absf(v.x))
	near(ground_out, road.shoulder_outer_d(0.0) + t.ground_ribbon_width_m, MM, "ground ribbon width")


func test_follows_grade() -> void:
	var road := StraightRoadPath.new(3, t, 0.0, 0.05)
	var m := _build(road, 1000.0, 1200.0)
	# Every road vertex lies on the plane through the reference line (flat cross-section).
	var smp := road.sample(1000.0)
	var worst := 0.0
	for i in m.road_vertices.size():
		if m.road_uv2[i].x != RoadChunkMesher.EMISSIVE_NONE:
			continue
		var p := _abs(m, m.road_vertices[i])
		var off := Vector3(p[0] - smp.pos_x, p[1] - smp.pos_y, p[2] - smp.pos_z)
		worst = maxf(worst, absf(off.dot(smp.up)))
	le(worst, MM, "road surface on the graded plane")


# ---------------------------------------------------------------- Lane-count tapers

func _check_taper(road: LaneChangeRoadPath, label: String) -> void:
	var w := road.lane_width(0.0)
	var left := road.lanes_left_edge_d(0.0)
	var prev_edge := NAN
	var mesh_m := RoadChunkMesher.new(t)
	for k in range(1, 5):
		var m := _build(road, k * t.chunk_length_m, (k + 1) * t.chunk_length_m)
		for r in m.row_count:
			var e := m.row_edge_d(r)
			if not is_nan(prev_edge):
				le(absf(e - prev_edge), 0.5, "%s: edge continuous at s=%s" % [label, m.row_s(r)])
			prev_edge = e
		# No gaps: per interval, the road quads (not reflectors) exactly tile
		# [barrier, outer shoulder] on both sides.
		var qpi := m.road_quads_per_interval
		for i in m.row_count - 1:
			var area := 0.0
			for q in range(i * qpi, (i + 1) * qpi):
				var o := q * 4
				var d1 := m.road_vertices[o + 2] - m.road_vertices[o]
				var d2 := m.road_vertices[o + 3] - m.road_vertices[o + 1]
				area += 0.5 * d1.cross(d2).length()
			var ds := m.row_s(i + 1) - m.row_s(i)
			var barrier := road.median_barrier_d(0.0)
			var expected := (m.row_outer_d(i) - barrier + m.row_outer_d(i + 1) - barrier) * ds
			near(area, expected, 1e-3 * expected, "%s: interval at s=%s tiled without gaps" % [label, m.row_s(i)])
		_check_seam(road, (k + 1) * t.chunk_length_m, "%s seam at %s" % [label, (k + 1) * t.chunk_length_m])
	near(mesh_m.lanes_right_edge_at(road, 300.0), left + 3.0 * w, MM, "%s: 3 lanes before" % label)
	near(mesh_m.lanes_right_edge_at(road, 700.0), left + 2.0 * w, MM, "%s: 2 lanes after" % label)
	var mid := mesh_m.lanes_right_edge_at(road, 475.0)
	check(mid > left + 2.0 * w + 0.1 and mid < left + 3.0 * w - 0.1, "%s: tapering mid-way (%s)" % [label, mid])


func test_lane_drop_taper_with_feature() -> void:
	_check_taper(LaneChangeRoadPath.new(3, 2, 400.0, 150.0, true, t), "feature taper")


func test_lane_drop_taper_without_feature() -> void:
	_check_taper(LaneChangeRoadPath.new(3, 2, 400.0, t.lane_taper_default_m, false, t), "bare step")


func test_lane_add_taper() -> void:
	var road := LaneChangeRoadPath.new(2, 4, 450.0, 200.0, true, t)
	var m := _build(road, 400.0, 600.0)
	eq(m.lane_slots, 4, "slots for the widest point")
	var after := _build(road, 800.0, 1000.0)
	var lines := {}
	for q in _quads_straight(after):
		if q[4] == RoadChunkMesher.TINT_LINE and q[5] == RoadChunkMesher.EMISSIVE_NONE and q[0] > 0.0:
			lines[snappedf(q[0], 0.001)] = true
	eq(lines.size(), 5, "4 lanes after the taper: 2 edge lines + 3 lane lines")


func test_dashed_line_ends_inside_taper() -> void:
	# 3 -> 2: the line between lanes 1 and 2 stops once the edge line reaches it.
	var road := LaneChangeRoadPath.new(3, 2, 400.0, 150.0, true, t)
	var m := _build(road, 400.0, 600.0)
	var line2 := road.lanes_left_edge_d(0.0) + 2.0 * road.lane_width(0.0)
	var last_dash_s := -INF
	for q in _quads_straight(m):
		if q[4] == RoadChunkMesher.TINT_LINE and absf(q[0] - line2) < 0.01 and q[1] < t.edge_line_width_m - EPS:
			last_dash_s = maxf(last_dash_s, q[3])
	check(last_dash_s > 400.0, "line 2 still dashed at the taper start")
	lt(last_dash_s, 550.0, "line 2 ends before the taper end")


# ---------------------------------------------------------------- Precision

func test_precision_far_from_start() -> void:
	# ~5,000 km out (a multiple of the chunk, dash and reflector periods): the chunk,
	# relative to its anchor, must be identical to the same chunk near the start.
	var road := StraightRoadPath.new(3, t, 0.3, 0.03)
	var s_far := 4_999_800.0
	var near_m := _build(road, 0.0, t.chunk_length_m)
	var far_m := _build(road, s_far, s_far + t.chunk_length_m)
	eq(far_m.road_vertices.size(), near_m.road_vertices.size(), "same road topology")
	eq(far_m.world_vertices.size(), near_m.world_vertices.size(), "same world topology")
	var worst := 0.0
	for i in mini(far_m.road_vertices.size(), near_m.road_vertices.size()):
		worst = maxf(worst, (far_m.road_vertices[i] - near_m.road_vertices[i]).length())
	for i in mini(far_m.world_vertices.size(), near_m.world_vertices.size()):
		worst = maxf(worst, (far_m.world_vertices[i] - near_m.world_vertices[i]).length())
	le(worst, MM, "vertices at 5,000 km match the near-start chunk within 1 mm")
	var smp := road.sample(s_far)
	near(far_m.anchor_x, smp.pos_x, EPS, "anchor is the 64-bit reference line")
	near(far_m.anchor_z, smp.pos_z, EPS)


# ---------------------------------------------------------------- Budget

func test_triangle_budget_and_build_cost() -> void:
	for lanes in [3, 4]:
		var road := ArcRoadPath.new(R, 1, lanes, t)
		var m := _build(road, 0.0, t.chunk_length_m)
		print("    road chunk, %d lanes: %d road + %d world = %d triangles, %d rows, %d reflectors" % [
			lanes, m.road_triangle_count(), m.world_triangle_count(), m.triangle_count(),
			m.row_count, m.reflector_count])
		le(m.triangle_count(), 4000, "%d lanes: triangles per chunk" % lanes)
	var mesher := RoadChunkMesher.new(t)
	var road3 := ArcRoadPath.new(R, 1, 3, t)
	var usec := WBBench.usec_per_call(func() -> void: mesher.build(road3, 1000.0, 1200.0), 3, 1, 3)
	WBBench.report("road chunk build (3 lanes, 200 m)", usec, 15000.0)
	le(usec, WBBench.budget(15000.0), "chunk build usec")
