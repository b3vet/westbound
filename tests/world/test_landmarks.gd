extends WBTest
## Checkpoint landmarks and warning signs (src/world/landmarks/, WP5.3). Spec: Core
## loop → Legs and checkpoints (landmark at every checkpoint; warning signs at 1 km
## and 500 m), World → Checkpoint landmarks (four kinds, per biome style, the big sign
## gantry shows the leg name and distance), Night lighting (retro-reflective signs),
## Performance budget (draw calls), Architecture rule 6 (floating origin).

const SEED := 5301
const VIEW_M := 700.0
const LEG_M := 3500.0
## Render positions a few hundred metres from their anchor (float32): millimetres.
const POS_EPS := 0.01
## The shader bends vertices, not edges: a vertex follows the road exactly up to the
## station chord error (8 m stations at R 1,200 m: < 1 cm).
const BEND_EPS := 0.02
## Our draw-call share with one landmark and two signs in view.
const DRAW_CALL_BUDGET := 6
const TRIANGLE_BUDGET := 6000

var _t: Tuning
var _lt: LandmarkTuning
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()
	_lt = LandmarkTuning.load_default()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


# ---------------------------------------------------------------- Helpers

func _origin() -> FloatingOrigin:
	var o := FloatingOrigin.new()
	o.setup(_t.road.floating_origin_shift_km)
	tree.root.add_child(o)
	_nodes.append(o)
	return o


func _director(road: RoadPath, origin: FloatingOrigin) -> BiomeDirector:
	var d := BiomeDirector.new()
	tree.root.add_child(d)
	_nodes.append(d)
	d.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, origin)
	return d


func _landmarks(road: RoadPath, origin: FloatingOrigin, director: BiomeDirector = null) -> Landmarks:
	var lm := Landmarks.new()
	lm.view_distance_override_m = VIEW_M
	lm.biome_director = director
	tree.root.add_child(lm)
	_nodes.append(lm)
	lm.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, origin)
	return lm


## A checkpoint at `cp` ending leg `leg` (tag = style) with its warning signs.
func _add_checkpoint(road: FixtureRoadPath, cp: float, leg: int, tag: StringName) -> void:
	for w in _t.legs.checkpoint_warning_distances_m:
		road.add_feature(RoadFeature.make(RoadFeature.Kind.SIGN, cp - w, cp - w, w, ProceduralRoadPath.SIGN_CHECKPOINT))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, cp, cp, float(leg), tag))


func _arc(bend: int = 1) -> ArcRoadPath:
	return ArcRoadPath.new(_t.road.min_curve_radius_m, bend, _t.road.lanes_default, _t.road)


func _view(lm: Landmarks, road: RoadPath, origin: FloatingOrigin, s: float) -> void:
	var smp := road.sample(s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	lm.update_view(s)


func _live(lm: Landmarks, kind: StringName) -> Array[Landmarks.Slot]:
	var out: Array[Landmarks.Slot] = []
	for slot in lm.live_slots():
		if slot.kind == kind:
			out.append(slot)
	return out


func _count_descendants(n: Node) -> int:
	var c := n.get_child_count()
	for child in n.get_children():
		c += _count_descendants(child)
	return c


## Absolute (64-bit) position of a template point of a live slot, through the node.
func _abs(lm: Landmarks, slot: Landmarks.Slot, origin: FloatingOrigin, v: Vector3) -> Vector3:
	var p := lm.render_point(slot, v)
	return Vector3(float(origin.origin_x + p.x), float(origin.origin_y + p.y), float(origin.origin_z + p.z))


func _expected_abs(road: RoadPath, s: float, d: float, h: float) -> Vector3:
	var smp := road.sample(s)
	return Vector3(smp.pos_x + smp.right.x * d, smp.pos_y + h, smp.pos_z + smp.right.z * d)


# ---------------------------------------------------------------- Placement

func test_landmark_sits_at_the_checkpoint() -> void:
	var road := _arc()
	_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_TOLL_GANTRY)
	var origin := _origin()
	var lm := _landmarks(road, origin)
	_view(lm, road, origin, LEG_M - VIEW_M - _lt.place_margin_m - 200.0)
	eq(_live(lm, BiomeDef.LANDMARK_TOLL_GANTRY).size(), 0, "beyond the view: not placed yet")
	_view(lm, road, origin, LEG_M - VIEW_M)
	var live := _live(lm, BiomeDef.LANDMARK_TOLL_GANTRY)
	if not eq(live.size(), 1, "placed once within the view"):
		return
	var slot := live[0]
	eq(slot.s, LEG_M, "at the checkpoint s")
	eq(slot.leg, 1)
	check(slot.node.visible)
	# The template origin (d 0, height 0, checkpoint line) is the road at the checkpoint.
	var got := _abs(lm, slot, origin, Vector3.ZERO)
	var want := _expected_abs(road, LEG_M, 0.0, 0.0)
	near(got.distance_to(want), 0.0, POS_EPS, "checkpoint line on the road")


func test_warning_signs_at_exactly_the_warning_features() -> void:
	var road := _arc(-1)
	_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_SIGN_GANTRY)
	var origin := _origin()
	var lm := _landmarks(road, origin)
	_view(lm, road, origin, LEG_M - 1000.0 - 100.0)
	var signs := _live(lm, Landmarks.KIND_SIGN)
	eq(signs.size(), 2, "both warning signs in the window")
	var seen := PackedFloat64Array()
	for slot in signs:
		seen.append(slot.s)
		near(slot.s + slot.distance_m, LEG_M, 1e-9, "announces this checkpoint")
		var d := road.guardrail_d(slot.s) + _lt.sign_setback_m
		var got := _abs(lm, slot, origin, Vector3.ZERO)
		near(got.distance_to(_expected_abs(road, slot.s, d, 0.0)), 0.0, POS_EPS, "right of the guardrail")
		gt(d, road.guardrail_d(slot.s), "outside the guardrail")
		# Faces approaching traffic: the node's -Z is the road's forward direction.
		var fwd := -slot.node.transform.basis.z
		near(fwd.dot(road.sample(slot.s).tangent), 1.0, 1e-4, "facing the player")
	seen.sort()
	eq(seen, PackedFloat64Array([LEG_M - 1000.0, LEG_M - 500.0]))


func test_sign_text_matches_leg_and_distance() -> void:
	var road := _arc()
	_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_SIGN_GANTRY)
	_add_checkpoint(road, 2.0 * LEG_M, 2, BiomeDef.LANDMARK_SIGN_GANTRY)
	var origin := _origin()
	var director := _director(road, origin)
	var lm := _landmarks(road, origin, director)
	var leg_name := director.biome_at(LEG_M + 1.0).display_name.to_upper()
	_view(lm, road, origin, LEG_M - 1100.0)
	for slot in _live(lm, Landmarks.KIND_SIGN):
		var dist := "1 KM" if slot.distance_m >= 1000.0 else "500 M"
		eq(slot.lines, PackedStringArray(["CHECKPOINT " + dist, "LEG 2 — " + leg_name]), "warning sign")
		for i in slot.regions.size():
			eq(lm.atlas.region_text[slot.regions[i]], slot.lines[i], "atlas holds the line")
			gt(lm.atlas.ink_share(slot.regions[i]), 0.02, "the line is drawn")
	_view(lm, road, origin, LEG_M - 300.0)
	var gantry := _live(lm, BiomeDef.LANDMARK_SIGN_GANTRY)
	if not eq(gantry.size(), 1):
		return
	eq(gantry[0].lines, PackedStringArray(["LEG 2 — " + leg_name, "NEXT CHECKPOINT 3.5 KM", "CHECKPOINT"]),
		"big sign gantry: next leg name and distance")
	eq(lm.atlas.dropped, 0, "every text region fits the atlas")


func test_text_formatting() -> void:
	eq(LandmarkText.distance(1000.0), "1 KM")
	eq(LandmarkText.distance(500.0), "500 M")
	eq(LandmarkText.distance(3500.0), "3.5 KM")
	eq(LandmarkText.leg(3, "Desert Mesas"), "LEG 3 — DESERT MESAS")
	eq(LandmarkText.leg(4, ""), "LEG 4")
	eq(LandmarkText.warning_sign(500.0, 2, ""), PackedStringArray(["CHECKPOINT 500 M", "LEG 2"]))
	eq(LandmarkText.landmark(BiomeDef.LANDMARK_TOLL_GANTRY, 1, "", 3500.0),
		PackedStringArray(["EXPRESS", "CHECKPOINT", "LEG 2"]))
	eq(LandmarkText.landmark(BiomeDef.LANDMARK_SUSPENSION_BRIDGE, 1, "", 3500.0).size(), 0)


func test_style_follows_the_checkpoint_tag() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var kinds := LandmarkBuilds.kinds()
	for i in kinds.size():
		_add_checkpoint(road, LEG_M * float(i + 1), i + 1, kinds[i])
	var origin := _origin()
	var lm := _landmarks(road, origin)
	for i in kinds.size():
		var cp := LEG_M * float(i + 1)
		_view(lm, road, origin, cp - 50.0)
		var slot := lm.find_live(kinds[i], cp)
		check(slot != null, "checkpoint %d is a %s" % [i + 1, kinds[i]])
		for other in kinds:
			if other != kinds[i]:
				check(lm.find_live(other, cp) == null, "and nothing else at %.0f" % cp)


func test_untagged_checkpoint_uses_the_biome_style() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	_add_checkpoint(road, LEG_M, 1, &"")
	var origin := _origin()
	var director := _director(road, origin)
	var lm := _landmarks(road, origin, director)
	var style := director.biome_at(LEG_M - 1.0).landmark_style
	_view(lm, road, origin, LEG_M - 50.0)
	check(lm.find_live(style, LEG_M) != null, "the biome's landmark_style (%s)" % style)
	# Without a biome director: the default style.
	var lm2 := _landmarks(road, origin)
	lm2.update_view(LEG_M - 50.0)
	check(lm2.find_live(lm2.default_style, LEG_M) != null, "default style")


# ---------------------------------------------------------------- Pools

func test_pooling_no_new_nodes_after_warm_up_across_ten_checkpoints() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var kinds := LandmarkBuilds.kinds()
	for i in 10:
		_add_checkpoint(road, LEG_M * float(i + 1), i + 1, kinds[i % kinds.size()])
	var origin := _origin()
	var lm := _landmarks(road, origin)
	var nodes := _count_descendants(lm)
	var ids := PackedInt64Array()
	for slot in lm.slots:
		ids.append(slot.node.get_instance_id())
		ids.append(slot.material.get_instance_id())
	var placed := {}
	var s := 0.0
	var max_live := {}
	while s <= LEG_M * 10.0 + 500.0:
		_view(lm, road, origin, s)
		var per_kind := {}
		for slot in lm.live_slots():
			placed["%s@%.0f" % [slot.kind, slot.s]] = true
			per_kind[slot.kind] = int(per_kind.get(slot.kind, 0)) + 1
		for k: StringName in per_kind:
			max_live[k] = maxi(int(max_live.get(k, 0)), int(per_kind[k]))
		s += _lt.update_step_m
	eq(_count_descendants(lm), nodes, "no nodes created after warm-up")
	var ids_after := PackedInt64Array()
	for slot in lm.slots:
		ids_after.append(slot.node.get_instance_id())
		ids_after.append(slot.material.get_instance_id())
	eq(ids_after, ids, "the same pooled nodes and materials")
	eq(lm.dropped, 0, "no placement found its pool empty")
	var landmarks := 0
	var signs := 0
	for key: String in placed:
		if key.begins_with(String(Landmarks.KIND_SIGN)):
			signs += 1
		else:
			landmarks += 1
	eq(landmarks, 10, "every checkpoint got its landmark")
	eq(signs, 20, "every warning sign was placed")
	for k: StringName in max_live:
		le(float(max_live[k]), float(_lt.landmarks_per_kind_count if k != Landmarks.KIND_SIGN
			else _lt.sign_pool_count), "at most the pool of %s live" % k)
	# A retry re-runs setup: still nothing new.
	lm.setup(RunContext.new(SEED + 1, RunContext.MODE_JOURNEY, _t), road, origin)
	eq(_count_descendants(lm), nodes, "setup again (retry) reuses the pools")
	eq(lm.live_slots().size(), 0, "and releases everything")


func test_recycled_behind_the_player() -> void:
	var road := _arc()
	_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_SUSPENSION_BRIDGE)
	var origin := _origin()
	var lm := _landmarks(road, origin)
	_view(lm, road, origin, LEG_M - 100.0)
	var live := _live(lm, BiomeDef.LANDMARK_SUSPENSION_BRIDGE)
	if not eq(live.size(), 1):
		return
	var slot := live[0]
	var gone := LEG_M + slot.template.s_after + _lt.keep_behind_m + _lt.update_step_m
	_view(lm, road, origin, gone - 2.0 * _lt.update_step_m)
	check(slot.live, "kept while any of it can still be behind the camera")
	_view(lm, road, origin, gone + _lt.update_step_m)
	check(not slot.live, "recycled once all of it is behind")
	check(not slot.node.visible, "and hidden")
	eq(_live(lm, Landmarks.KIND_SIGN).size(), 0, "the signs too")


func test_real_road_places_every_leg_end() -> void:
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, _t)
	var road := ProceduralRoadPath.new(ctx)
	var origin := _origin()
	var lm := _landmarks(road, origin)
	var s := 60.0
	var seen := {}
	var end := 2.0 * _t.legs.leg_length_m() + 400.0
	while s < end:
		road.ensure_generated_to(s + VIEW_M + 2.0 * _t.legs.leg_length_m())
		_view(lm, road, origin, s)
		for slot in lm.live_slots():
			seen["%s@%.0f" % [slot.kind, slot.s]] = slot.s
		s += _lt.update_step_m
	var cps := 0
	var sgn := 0
	for key: String in seen:
		if key.begins_with(String(Landmarks.KIND_SIGN)):
			sgn += 1
		else:
			cps += 1
			var cp: float = seen[key]
			near(fmod(cp, _t.legs.leg_length_m()), 0.0, 1e-6, "on a leg end")
	eq(cps, 2, "a landmark at each of the two leg ends")
	eq(sgn, 4, "two warning signs before each")


# ---------------------------------------------------------------- Floating origin and bending

func test_origin_shift_keeps_world_positions() -> void:
	var road := _arc()
	_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_SUSPENSION_BRIDGE)
	var origin := _origin()
	var lm := _landmarks(road, origin)
	_view(lm, road, origin, LEG_M - 520.0)
	var slots := lm.live_slots()
	check(slots.size() >= 2, "the bridge and a sign")
	var probes: Array[Vector3] = [Vector3.ZERO, Vector3(20.0, 50.0, 150.0), Vector3(-20.0, 5.0, -170.0)]
	var before: Array[Vector3] = []
	for slot in slots:
		for v in probes:
			before.append(_abs(lm, slot, origin, v))
	var shifts := origin.shift_count
	# Move the focus far enough to shift the origin (the handler moves the nodes).
	var s2 := road.sample(LEG_M + 2600.0)
	origin.update_focus(s2.pos_x, s2.pos_y, s2.pos_z)
	gt(float(origin.shift_count), float(shifts), "the origin moved")
	var k := 0
	for slot in slots:
		if not slot.live:
			k += probes.size()
			continue
		for v in probes:
			near(_abs(lm, slot, origin, v).distance_to(before[k]), 0.0, POS_EPS, "%s unchanged" % slot.kind)
			k += 1


func test_long_builds_follow_the_curved_road() -> void:
	for bend: int in [1, -1]:
		var road := _arc(bend)
		_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_SUSPENSION_BRIDGE)
		var origin := _origin()
		var lm := _landmarks(road, origin)
		_view(lm, road, origin, LEG_M - 300.0)
		var slot := lm.find_live(BiomeDef.LANDMARK_SUSPENSION_BRIDGE, LEG_M)
		if not check(slot != null):
			return
		var verts := slot.template.vertices
		var worst := 0.0
		for i in range(0, verts.size(), 7):
			var v := verts[i]
			var got := _abs(lm, slot, origin, v)
			var want := _expected_abs(road, LEG_M - v.z, v.x, v.y)
			worst = maxf(worst, got.distance_to(want))
		le(worst, BEND_EPS, "every vertex on its (s, d, height), bend %d" % bend)
		# The bent bounds cover the whole build (no frustum-culling pop).
		var aabb := slot.node.custom_aabb
		for i in range(0, verts.size(), 11):
			check(aabb.grow(POS_EPS).has_point(lm.local_point(slot, verts[i])), "inside the custom AABB")


# ---------------------------------------------------------------- Clearances

## Below the clearance, a triangle must lie wholly in the median (|d| <= median
## barrier) or wholly beyond one guardrail: never over a lane or a shoulder.
func _check_clear_of_lanes(tpl: LandmarkTemplate, x: LandmarkSection, clearance: float, label: String) -> void:
	var v := tpl.vertices
	var bad := 0
	var first := ""
	for i in range(0, v.size(), 3):
		var lo_y := minf(v[i].y, minf(v[i + 1].y, v[i + 2].y))
		if lo_y >= clearance - 1e-4:
			continue
		var region := -99
		var ok := true
		for k in 3:
			var d := v[i + k].x
			var r := 0
			if absf(d) <= x.median_barrier_d + 1e-4:
				r = 0
			elif d >= x.guardrail_d - 1e-4:
				r = 1
			elif d <= -x.guardrail_d + 1e-4:
				r = -1
			else:
				ok = false
			if region == -99:
				region = r
			elif r != region:
				ok = false
		if not ok:
			bad += 1
			if first == "":
				first = "%s %s %s" % [v[i], v[i + 1], v[i + 2]]
	eq(bad, 0, "%s: triangles over the carriageway below %.1f m (first: %s)" % [label, clearance, first])


func test_structures_stay_outside_the_drivable_area() -> void:
	var pal := WBPalette.load_default()
	for lanes: int in [2, 3, 4]:
		var road := StraightRoadPath.new(lanes, _t.road)
		var x := LandmarkSection.at(road, 0.0)
		for kind in LandmarkBuilds.kinds():
			var tpl := LandmarkBuilds.build(kind, x, _lt, pal)
			_check_clear_of_lanes(tpl, x, _lt.overhead_clearance_m, "%s, %d lanes" % [kind, lanes])
	# The warning sign stands beyond the guardrail from x = 0 outward.
	var sign_tpl := LandmarkBuilds.build(Landmarks.KIND_SIGN, LandmarkSection.new(), _lt, pal)
	for v in sign_tpl.vertices:
		if not ge(v.x, 0.0, "sign geometry beyond its inner edge"):
			break


func test_builds_have_the_spec_shapes() -> void:
	var pal := WBPalette.load_default()
	var x := LandmarkSection.at(StraightRoadPath.new(_t.road.lanes_default, _t.road), 0.0)
	var bridge := LandmarkBuilds.build(BiomeDef.LANDMARK_SUSPENSION_BRIDGE, x, _lt, pal)
	var half := _lt.bridge_span_m * 0.5
	ge(bridge.s_before, half, "bridge reaches the near tower")
	ge(bridge.s_after, half, "and the far one")
	var tops := 0
	for v in bridge.vertices:
		if v.y >= _lt.bridge_tower_height_m and absf(absf(v.z) - half) < _lt.bridge_tower_leg_width_m:
			tops += 1
	gt(float(tops), 0.0, "tower tops at checkpoint +/- span / 2")
	var tunnel := LandmarkBuilds.build(BiomeDef.LANDMARK_TUNNEL_PORTAL, x, _lt, pal)
	# Over the carriageways the portal starts at the checkpoint line and the shell runs
	# tunnel_length_m past it (the hill's ends reach further, beside the road).
	var z_hi := -INF
	var z_lo := INF
	for v in tunnel.vertices:
		if absf(v.x) < x.guardrail_d:
			z_hi = maxf(z_hi, v.z)
			z_lo = minf(z_lo, v.z)
	near(z_hi, 0.0, 1.0, "the portal is at the checkpoint line")
	near(-z_lo, _lt.tunnel_length_m, 1.0, "tunnel shell length past the portal")
	for kind in LandmarkBuilds.kinds():
		var tpl := LandmarkBuilds.build(kind, x, _lt, pal)
		le(float(tpl.triangles), float(TRIANGLE_BUDGET), "%s triangles" % kind)
		le(float(tpl.line_count()), float(LandmarkMeshBuilder.MAX_LINES), "%s text lines" % kind)
		eq(tpl.mesh.get_surface_count(), 1, "%s is one surface (one draw call)" % kind)


func test_draw_calls_with_a_landmark_and_two_signs() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	_add_checkpoint(road, LEG_M, 1, BiomeDef.LANDMARK_SUSPENSION_BRIDGE)
	var origin := _origin()
	var lm := _landmarks(road, origin)
	_view(lm, road, origin, LEG_M - 1000.0 + 20.0)
	eq(lm.live_slots().size(), 3, "a landmark and two signs")
	le(float(lm.draw_calls()), float(DRAW_CALL_BUDGET), "draw calls")
	for slot in lm.live_slots():
		check(slot.node.material_override is ShaderMaterial, "project shader material")
		eq(slot.node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no shadows")


# ---------------------------------------------------------------- Cost

## Per frame nothing happens until the focus crosses a step; a placement (stations,
## text, atlas upload) is director-rate work and stays small.
func test_update_view_cost() -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var kinds := LandmarkBuilds.kinds()
	for i in 8:
		_add_checkpoint(road, LEG_M * float(i + 1), i + 1, kinds[i % kinds.size()])
	var origin := _origin()
	var lm := _landmarks(road, origin)
	var s := 0.0
	var worst := 0
	while s < LEG_M * 8.0:
		var t0 := Time.get_ticks_usec()
		lm.update_view(s)
		if s >= LEG_M * 4.0:   # second lap: glyph caches warm, as in a run
			worst = maxi(worst, Time.get_ticks_usec() - t0)
		s += _lt.update_step_m * 0.2
	WBBench.report("landmarks update_view, worst frame (placements)", float(worst), 4000.0)
	le(float(worst), WBBench.budget(4000.0), "worst update_view usec")
	# Within a step, update_view does not even query the road.
	var q := floorf(s / _lt.update_step_m) * _lt.update_step_m + _lt.update_step_m
	lm.update_view(q + 1.0)
	var lo := lm.window_s_lo
	lm.update_view(q + _lt.update_step_m * 0.5)
	eq(lm.window_s_lo, lo, "no work inside a step")
