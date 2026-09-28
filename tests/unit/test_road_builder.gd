extends WBTest
## RoadBuilder (pooled chunks around the focus, floating origin) and BlobShadow.
## Spec: World → Road; Architecture rules 6 (floating origin) and 7 (pooling);
## Performance budget (shadows, draw calls). Plan WP1.2 acceptance: "origin shift
## leaves no hitch or seam; pool never allocates after warm-up".

const MM := 0.001
const VIEW_M := 700.0

var t: RoadTuning
var _origin: FloatingOrigin
var _builder: RoadBuilder
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default().road


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_builder = null
	_origin = null


func _make(road: RoadPath, view_m: float = VIEW_M) -> RoadBuilder:
	_origin = FloatingOrigin.new()
	_origin.setup(t.floating_origin_shift_km)
	tree.root.add_child(_origin)
	_nodes.append(_origin)
	_builder = RoadBuilder.new()
	_builder.view_distance_override_m = view_m
	tree.root.add_child(_builder)
	_nodes.append(_builder)
	_builder.setup(RunContext.new(1), road, _origin)
	return _builder


func _expected_min(focus: float) -> int:
	return maxi(floori((focus - t.chunk_keep_behind_m) / t.chunk_length_m), 0)


func _expected_max(focus: float, view_m: float = VIEW_M) -> int:
	return floori((focus + view_m) / t.chunk_length_m)


func _covers(b: RoadBuilder, focus: float, view_m: float = VIEW_M) -> bool:
	for k in range(_expected_min(focus), _expected_max(focus, view_m) + 1):
		if not b.has_chunk(k):
			return false
	return true


## Chunk k's end point (reference line at s1, from its own node) vs chunk k+1's
## node: the render-space seam, in meters.
func _seam_gap(b: RoadBuilder, k: int) -> float:
	var a := b.get_chunk(k)
	var c := b.get_chunk(k + 1)
	var end_of_a := a.node.position + Vector3(c.anchor_x - a.anchor_x, c.anchor_y - a.anchor_y, c.anchor_z - a.anchor_z)
	return end_of_a.distance_to(c.node.position)


# ---------------------------------------------------------------- Coverage and budget

func test_covers_behind_to_view_distance() -> void:
	var b := _make(StraightRoadPath.new(3, t))
	var focus := 1234.0
	b.build_all_now(focus)
	check(_covers(b, focus), "chunks cover [focus - behind, focus + view]")
	eq(b.active_chunk_count(), _expected_max(focus) - _expected_min(focus) + 1, "no extra chunks")
	eq(b.needed_range_min(), _expected_min(focus))
	eq(b.needed_range_max(), _expected_max(focus))
	check(not b.has_chunk(_expected_min(focus) - 1), "nothing further behind")
	check(not b.has_chunk(_expected_max(focus) + 1), "nothing beyond the view distance")
	eq(b.draw_call_count(), 2 * b.active_chunk_count(), "two draw calls per chunk")
	print("    road at %d m view: %d chunks, %d draw calls, %d triangles (before culling)" % [
		int(VIEW_M), b.active_chunk_count(), b.draw_call_count(), b.triangle_count()])
	le(b.draw_call_count(), 16, "road draw calls stay a small share of the 100 budget")


func test_respects_per_frame_build_budget() -> void:
	var b := _make(StraightRoadPath.new(3, t))
	var n := t.chunk_builds_per_frame_count
	b.update_view(500.0)
	eq(b.builds_last_update, n, "at most N chunk builds per frame")
	eq(b.active_chunk_count(), n)
	check(b.has_chunk(floori(500.0 / t.chunk_length_m)), "the focus chunk is built first")
	var frames := 1
	while not _covers(b, 500.0) and frames < 20:
		b.update_view(500.0)
		le(b.builds_last_update, n, "budget on frame %d" % frames)
		frames += 1
	check(_covers(b, 500.0), "all chunks built within a few frames")
	b.update_view(500.0)
	eq(b.builds_last_update, 0, "nothing to build once covered")


func test_pool_stable_while_driving_20km() -> void:
	var b := _make(ArcRoadPath.new(t.min_curve_radius_m * 3.0, 1, 3, t))
	b.build_all_now(0.0)
	var pool := b.pool_size()
	var grows := b.pool_grow_count
	var builds0 := b.builds_total
	var uncovered := 0
	var s := 0.0
	var step := 25.0  # 90 km/h at 60 fps; faster only means fewer frames per chunk
	while s < 20000.0:
		s += step
		b.update_view(s)
		if not _covers(b, s):
			uncovered += 1
	eq(b.pool_size(), pool, "pool size unchanged after warm-up")
	eq(b.pool_grow_count, grows, "no chunk allocated while driving")
	eq(uncovered, 0, "view always covered at 25 m/frame with the per-frame budget")
	eq(b.builds_total - builds0, _expected_max(s) - _expected_max(0.0), "each chunk built exactly once")


func test_quality_view_distance_changes_range() -> void:
	var b := _make(StraightRoadPath.new(3, t), 500.0)
	b.build_all_now(1000.0)
	eq(b.needed_range_max(), _expected_max(1000.0, 500.0))
	b.view_distance_override_m = 800.0
	b.build_all_now(1000.0)
	eq(b.needed_range_max(), _expected_max(1000.0, 800.0), "longer view distance")
	check(_covers(b, 1000.0, 800.0))
	b.view_distance_override_m = -1.0
	Events.governor_changed.emit(0)
	var q: float = Quality.view_distance_m
	if q > 0.0:
		near(b.view_distance_m(), q, 1e-9, "follows Quality.view_distance_m")
	else:
		gt(b.view_distance_m(), 0.0, "falls back to the default tier")


func test_ground_color_setter_rebuilds_within_budget() -> void:
	var b := _make(StraightRoadPath.new(3, t))
	b.build_all_now(300.0)
	var live := b.active_chunk_count()
	var builds0 := b.builds_total
	b.set_ground_colors(Color(0.3, 0.5, 0.2), Color(0.4, 0.6, 0.25))
	var frames := 0
	while b.builds_total - builds0 < live and frames < 50:
		b.update_view(300.0)
		le(b.builds_last_update, t.chunk_builds_per_frame_count)
		frames += 1
	eq(b.builds_total - builds0, live, "every live chunk rebuilt once")
	b.update_view(300.0)
	eq(b.builds_last_update, 0, "then idle")


# ---------------------------------------------------------------- Floating origin

func test_origin_shift_moves_nodes_once_without_rebuild() -> void:
	var road := ArcRoadPath.new(t.min_curve_radius_m * 3.0, -1, 3, t, 0.4)
	var b := _make(road)
	var focus := 2400.0
	b.build_all_now(focus)
	var ks: Array[int] = []
	var before: Array[Vector3] = []
	for k in range(b.needed_range_min(), b.needed_range_max() + 1):
		ks.append(k)
		before.append(b.get_chunk(k).node.position)
	var ox := _origin.origin_x
	var oy := _origin.origin_y
	var oz := _origin.origin_z
	var builds := b.builds_total
	var smp := road.sample(focus + 200.0)
	check(_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z), "origin shifted")
	eq(b.shifts_applied, 1, "one shift handled")
	eq(b.builds_total, builds, "no rebuild on shift")
	var offset := _origin.last_offset
	for i in ks.size():
		var p := b.get_chunk(ks[i]).node.position
		near((p - (before[i] - offset)).length(), 0.0, MM, "chunk %d moved by -offset" % ks[i])
		# World position continuous: new origin + new local == old origin + old local.
		var dx := (_origin.origin_x + p.x) - (ox + before[i].x)
		var dy := (_origin.origin_y + p.y) - (oy + before[i].y)
		var dz := (_origin.origin_z + p.z) - (oz + before[i].z)
		le(sqrt(dx * dx + dy * dy + dz * dz), MM, "chunk %d world position continuous" % ks[i])
	# Chunks built after the shift meet the shifted ones without a seam.
	b.build_all_now(focus + 400.0)
	for k in range(b.needed_range_min(), b.needed_range_max()):
		le(_seam_gap(b, k), MM, "seam %d|%d after the shift" % [k, k + 1])


func test_origin_shifts_over_long_drive_keep_seams() -> void:
	var road := StraightRoadPath.new(3, t, 0.7, 0.02)
	var b := _make(road)
	var smp := RoadSample.new()
	var s := 0.0
	while s < 9000.0:
		s += 20.0
		road.sample_into(s, smp)
		_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
		b.update_view(s)
	eq(b.shifts_applied, _origin.shift_count, "every shift handled once")
	ge(b.shifts_applied, 4)
	for k in range(b.needed_range_min(), b.needed_range_max()):
		le(_seam_gap(b, k), MM, "seam %d|%d" % [k, k + 1])
		var c := b.get_chunk(k)
		var truth := _origin.to_local(c.anchor_x, c.anchor_y, c.anchor_z)
		le(c.node.position.distance_to(truth), MM, "chunk %d placed at its anchor" % k)


func test_precision_far_from_start() -> void:
	var road := StraightRoadPath.new(3, t, 0.3, 0.01)
	var b := _make(road)
	var s := 5_000_000.0
	var smp := road.sample(s)
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	b.build_all_now(s)
	check(_covers(b, s), "covered 5,000 km out")
	for k in range(b.needed_range_min(), b.needed_range_max() + 1):
		var c := b.get_chunk(k)
		lt(c.node.position.length(), 2.0 * VIEW_M, "chunk %d near the origin" % k)
		# Exact 64-bit placement.
		var ex := c.anchor_x - _origin.origin_x
		var ez := c.anchor_z - _origin.origin_z
		near(c.node.position.x, ex, MM)
		near(c.node.position.z, ez, MM)
	for k in range(b.needed_range_min(), b.needed_range_max()):
		le(_seam_gap(b, k), MM, "seam %d|%d at 5,000 km" % [k, k + 1])


# ---------------------------------------------------------------- Blob shadow

func test_blob_shadow_on_road_under_vehicle() -> void:
	var road := StraightRoadPath.new(3, t, 0.0, 0.05)
	var smp := road.sample(100.0)
	var d := road.lane_center_d(1, 100.0)
	var xf := BlobShadow.shadow_transform(smp, d, 0.0, 4.5, 1.9, null, 0.04, 0.2)
	var expected := smp.local_point(d, 0.0, 0.0, 0.0) + smp.up * 0.04
	near(xf.origin.distance_to(expected), 0.0, 1e-4, "centred under the vehicle, lifted off the road")
	near(xf.basis.x.length(), 1.9 * 1.2, 1e-4, "width from the vehicle")
	near(xf.basis.z.length(), 4.5 * 1.2, 1e-4, "length from the vehicle")
	near(xf.basis.y.normalized().dot(smp.up), 1.0, 1e-5, "follows the grade")
	# Yaw right: the nose (-Z of the quad) turns toward the road's right.
	var yawed := BlobShadow.shadow_transform(smp, d, 0.3, 4.5, 1.9, null, 0.04, 0.2)
	gt((-yawed.basis.z).dot(smp.right), 0.0, "positive yaw turns the footprint right")


func test_blob_shadow_node_and_multimesh() -> void:
	var road := ArcRoadPath.new(t.min_curve_radius_m, 1, 3, t)
	var origin := FloatingOrigin.new()
	origin.setup(t.floating_origin_shift_km)
	tree.root.add_child(origin)
	_nodes.append(origin)
	var shadow: BlobShadow = load("res://src/vehicle/blob_shadow.tscn").instantiate()
	tree.root.add_child(shadow)
	_nodes.append(shadow)
	check(shadow.mesh != null and shadow.material_override != null, "mesh and material set up")
	var smp := road.sample(300.0)
	shadow.place(smp, 5.3, 0.0, 4.5, 1.9, origin)
	near(shadow.position.distance_to(smp.local_point(5.3, 0.0, 0.0, 0.0) + smp.up * shadow.lift_m), 0.0, 1e-3)
	var multi := BlobShadowMulti.new()
	tree.root.add_child(multi)
	_nodes.append(multi)
	multi.setup(64)
	eq(multi.capacity(), 64)
	for i in 64:
		multi.place(i, smp, 1.0 + 0.1 * i, 0.0, 4.5, 1.9, origin)
	multi.hide_instance(3)
	eq(multi.multimesh.get_instance_transform(3).basis.get_scale(), Vector3.ZERO, "hidden instance collapsed")
