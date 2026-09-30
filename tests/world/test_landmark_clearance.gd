extends WBTest
## Roadside clearance around the checkpoint landmarks (WP5.5): LandmarkClearance zones
## (LandmarkBuilds.clearance_zones), the Roadside layers skipping props in them, and
## StreetLampPools skipping the pools of skipped poles. Spec: World → Road (roadside
## rhythm: light poles every 50 m, reflector posts every 25 m, ... sign gantries,
## billboards, fences), World → Checkpoint landmarks, Core loop → Legs and checkpoints
## (a landmark at every checkpoint, warning signs at 1 km and 500 m), Architecture
## rule 2 (deterministic by seed).

const SEED := 5505
const VIEW_M := 700.0
const LEG_M := 3500.0
const CHECKPOINTS := 10
const SKY_SCENE := "res://src/sun/sky.tscn"
## Template vertices on a zone's edge count as inside.
const EDGE_EPS := 1e-3
## Instance footprints from float32 transforms.
const POS_EPS := 0.01

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


## A straight road with CHECKPOINTS checkpoints cycling through the four styles (tags),
## each with its two warning signs.
func _road() -> StraightRoadPath:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var kinds := LandmarkBuilds.kinds()
	for i in CHECKPOINTS:
		var cp := LEG_M * float(i + 1)
		for w in _t.legs.checkpoint_warning_distances_m:
			road.add_feature(RoadFeature.make(RoadFeature.Kind.SIGN, cp - w, cp - w, w, ProceduralRoadPath.SIGN_CHECKPOINT))
		road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, cp, cp, float(i + 1), kinds[i % kinds.size()]))
	return road


func _roadside(road: RoadPath, origin: FloatingOrigin, clear: bool) -> Roadside:
	var rs := Roadside.new()
	rs.view_distance_override_m = VIEW_M
	rs.clear_landmarks = clear
	tree.root.add_child(rs)
	_nodes.append(rs)
	rs.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, origin)
	return rs


func _move(rs: Roadside, road: RoadPath, origin: FloatingOrigin, s: float) -> void:
	var smp := road.sample(s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	rs.update_view(s)


## Footprint of instance i on a straight road: (s0, s1, d0, d1, top) of its mesh box's
## corners through its transform (absolute, 64-bit via the layer anchor).
func _footprint(road: StraightRoadPath, layer: RoadsideLayer, pool: RoadsidePool, i: int) -> PackedFloat64Array:
	var xf := pool.get_transform(i)
	var a := pool.aabb
	var out := PackedFloat64Array([INF, -INF, INF, -INF, -INF])
	for k in 8:
		var c := xf * a.get_endpoint(k)
		var rx := layer.anchor_x + c.x - road.origin_x
		var rz := layer.anchor_z + c.z - road.origin_z
		var s := rx * sin(road.heading0) - rz * cos(road.heading0)
		var d := rx * cos(road.heading0) + rz * sin(road.heading0)
		out[0] = minf(out[0], s)
		out[1] = maxf(out[1], s)
		out[2] = minf(out[2], d)
		out[3] = maxf(out[3], d)
		out[4] = maxf(out[4], layer.anchor_y + c.y - road.origin_y)
	return out


static func _overlaps(fp: PackedFloat64Array, z: PackedFloat64Array, i: int, eps: float) -> bool:
	return fp[1] > z[i] + eps and fp[0] < z[i + 1] - eps and fp[3] > z[i + 2] + eps and fp[2] < z[i + 3] - eps \
		and fp[4] > z[i + 4] + eps


## Order-independent signature of every instance whose s range (grown by its mesh's
## footprint radius) touches no zone's s range: what must not change at all.
func _signature_outside(rs: Roadside, road: StraightRoadPath, zones: PackedFloat64Array) -> Array[String]:
	var out: Array[String] = []
	for layer in rs.layers:
		for pi in layer.pools.size():
			var pool := layer.pools[pi]
			var r := RoadsideLayer.footprint_radius(pool.mesh) * 2.0
			for i in pool.count:
				var fp := _footprint(road, layer, pool, i)
				var near_zone := false
				for z in range(0, zones.size(), LandmarkBuilds.ZONE_FLOATS):
					if fp[1] + r >= zones[z] and fp[0] - r <= zones[z + 1]:
						near_zone = true
						break
				if near_zone:
					continue
				var xf := pool.get_transform(i)
				out.append("%s/%d %.3f %.3f %.3f %.4f %.4f %.4f %.4f" % [layer.id, pi, layer.anchor_x + xf.origin.x,
					layer.anchor_y + xf.origin.y, layer.anchor_z + xf.origin.z, xf.basis.x.x, xf.basis.x.z,
					xf.basis.y.y, xf.basis.z.z])
	out.sort()
	return out


## Median light-pole s values of the live window.
func _pole_s(rs: Roadside, road: StraightRoadPath) -> Dictionary:
	var out := {}
	var layer := rs.find_layer(&"light_pole")
	var pool := layer.pools[0]
	for i in pool.count:
		var fp := _footprint(road, layer, pool, i)
		out[roundi((fp[0] + fp[1]) * 0.5 / _t.road.light_pole_spacing_m)] = true
	return out


# ---------------------------------------------------------------- Zones

## Every part of every build that stands on the median or out in the scenery band
## (beyond guardrail + prop clearance, where fields, trees, fences and billboards go)
## lies inside one of its zones (in s and d): the zones really describe the builds.
## (A zone's floor deliberately lets low things pass under raised parts: sign panels,
## the tunnel hill's flanks over crop tiles.)
func test_zones_cover_every_build() -> void:
	var pal := WBPalette.load_default()
	for lanes: int in [2, 3, 4]:
		var road := StraightRoadPath.new(lanes, _t.road)
		var x := LandmarkSection.at(road, 0.0)
		var scenery := x.guardrail_d + _t.road.prop_clearance_m
		for kind in LandmarkBuilds.kinds():
			var zones := PackedFloat64Array()
			LandmarkBuilds.clearance_zones(kind, x, _lt, zones)
			gt(zones.size(), 0, "%s has zones" % kind)
			var tpl := LandmarkBuilds.build(kind, x, _lt, pal)
			_check_covered(tpl.vertices, 0.0, zones, x.median_barrier_d, scenery, "%s, %d lanes" % [kind, lanes])
		# The warning sign, anchored at guardrail + setback.
		var sign_d := x.guardrail_d + _lt.sign_setback_m
		var sign_zones := PackedFloat64Array()
		LandmarkBuilds.sign_clearance_zones(sign_d, _lt, sign_zones)
		var sign_tpl := LandmarkBuilds.build(Landmarks.KIND_SIGN, x, _lt, pal)
		_check_covered(sign_tpl.vertices, sign_d, sign_zones, x.median_barrier_d, scenery, "sign, %d lanes" % lanes)


func _check_covered(verts: PackedVector3Array, d_offset: float, zones: PackedFloat64Array, median: float,
		scenery: float, label: String) -> void:
	var bad := 0
	var first := ""
	for v in verts:
		var d := v.x + d_offset
		if absf(d) > median + EDGE_EPS and absf(d) < scenery - EDGE_EPS:
			continue
		var s := -v.z
		var inside := false
		for i in range(0, zones.size(), LandmarkBuilds.ZONE_FLOATS):
			if s >= zones[i] - EDGE_EPS and s <= zones[i + 1] + EDGE_EPS and d >= zones[i + 2] - EDGE_EPS \
					and d <= zones[i + 3] + EDGE_EPS:
				inside = true
				break
		if not inside:
			bad += 1
			if first == "":
				first = "s %.2f d %.2f y %.2f" % [s, d, v.y]
	eq(bad, 0, "%s: vertices outside every zone (first: %s)" % [label, first])


func test_exclusion_zones_are_known_before_anything_is_placed() -> void:
	var road := _road()
	var origin := _origin()
	var lm := Landmarks.new()
	lm.view_distance_override_m = VIEW_M
	tree.root.add_child(lm)
	_nodes.append(lm)
	lm.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, origin)
	eq(lm.live_slots().size(), 0, "nothing placed yet")
	var zones := PackedFloat64Array()
	lm.exclusion_zones(LEG_M - 1100.0, LEG_M + 200.0, zones)
	gt(zones.size(), 0, "the first checkpoint's and its signs' zones")
	var own := PackedFloat64Array()
	LandmarkBuilds.clearance_zones(LandmarkBuilds.kinds()[0], LandmarkSection.at(road, LEG_M), _lt, own)
	var signs := PackedFloat64Array()
	LandmarkBuilds.sign_clearance_zones(road.guardrail_d(0.0) + _lt.sign_setback_m, _lt, signs)
	eq(zones.size(), own.size() + signs.size() * _t.legs.checkpoint_warning_distances_m.size(),
		"a toll gantry (tag) and two warning signs")
	var first := zones[0]
	for i in range(0, zones.size(), LandmarkBuilds.ZONE_FLOATS):
		first = minf(first, zones[i])
	near(first, LEG_M - _t.legs.checkpoint_warning_distances_m[0] - _lt.clearance_margin_m, 1e-6,
		"from the 1 km sign, margin included")


func test_prepare_is_cached_and_queries_allocate_nothing() -> void:
	var road := _road()
	var c := LandmarkClearance.new()
	c.setup(road, _lt)
	c.prepare(0.0, 2000.0)
	var refills := c.refills
	c.prepare(100.0, 1900.0)
	c.prepare(500.0, 2000.0 + _lt.clearance_cache_pad_m * 0.5)
	eq(c.refills, refills, "covered ranges do not refill")
	var pole := (load(Roadside.LIGHT_POLE_MESH) as Mesh).get_aabb()
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var hits := 0
	for k in 40:
		if c.blocks_upright(pole, float(k) * _t.road.light_pole_spacing_m, 0.0, 0.0):
			hits += 1
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects per query")
	eq(c.refills, refills)
	eq(hits, 0, "no checkpoint before 2 km")
	check(c.blocks_upright(pole, LEG_M, 0.0, 0.0), "the pole at the toll gantry's middle column")


# ---------------------------------------------------------------- Roadside

## Ten checkpoints (every style twice or more, with their warning signs): no roadside
## instance's footprint lies in any zone, while every instance away from the zones is
## exactly where it was without the clearance.
func test_no_roadside_instance_inside_a_landmark_across_ten_checkpoints() -> void:
	var road := _road()
	var origin := _origin()
	var rs := _roadside(road, origin, true)
	var before := _roadside(road, origin, false)
	var inside := 0
	var first := ""
	var checked := 0
	var same := 0
	var poles_missing := {}
	# Views before (the 1 km sign, the bridge's near tower), at and after each checkpoint.
	var views := PackedFloat64Array()
	for c in CHECKPOINTS:
		var cp := LEG_M * float(c + 1)
		for off: float in [-1050.0, -450.0, -150.0, 150.0]:
			views.append(cp + off)
	for s in views:
		_move(rs, road, origin, s)
		_move(before, road, origin, s)
		var local := PackedFloat64Array()
		rs.landmark_clearance.zones_in(rs.window_s_lo - 1000.0, rs.window_s_hi + 1000.0, local)
		gt(local.size(), 0, "zones around s %.0f" % s)
		for layer in rs.layers:
			for pool in layer.pools:
				for i in pool.count:
					checked += 1
					var fp := _footprint(road, layer, pool, i)
					for z in range(0, local.size(), LandmarkBuilds.ZONE_FLOATS):
						if _overlaps(fp, local, z, POS_EPS):
							inside += 1
							if first == "":
								first = "%s at s %.1f d %.1f..%.1f" % [layer.id, fp[0], fp[2], fp[3]]
		var a := _signature_outside(rs, road, local)
		var b := _signature_outside(before, road, local)
		gt(a.size(), 100, "instances away from the landmarks at s %.0f" % s)
		if eq(a, b, "instances away from the landmarks unchanged at s %.0f" % s):
			same += 1
		var kept := _pole_s(rs, road)
		for k: int in _pole_s(before, road):
			if not kept.has(k):
				poles_missing[k] = true
	gt(checked, 1000, "instances checked near checkpoints")
	eq(inside, 0, "roadside instances inside a landmark zone (first: %s)" % first)
	gt(same, 0)
	gt(rs.cleared_count(), 0, "props were skipped")
	eq(before.cleared_count(), 0, "nothing skipped without the clearance")
	# The median poles: gone at the toll and sign gantries and through the tunnel, kept
	# under the bridge.
	var per_leg := roundi(LEG_M / _t.road.light_pole_spacing_m)
	var kinds := LandmarkBuilds.kinds()
	for i in kinds.size():
		var k_cp := per_leg * (i + 1)
		var gone: bool = poles_missing.has(k_cp)
		match kinds[i]:
			BiomeDef.LANDMARK_SUSPENSION_BRIDGE:
				check(not gone, "the bridge keeps its median pole")
			BiomeDef.LANDMARK_TUNNEL_PORTAL:
				var through := roundi(_lt.tunnel_length_m / _t.road.light_pole_spacing_m)
				for j in through + 1:
					check(poles_missing.has(k_cp + j), "no pole inside the tunnel (+%d)" % j)
				check(not poles_missing.has(k_cp - 1), "the pole before the portal stays")
			_:
				check(gone, "no pole in the %s's median column" % kinds[i])
				check(not poles_missing.has(k_cp + 1), "the next pole stays")


func test_same_seed_same_clearance() -> void:
	var road := _road()
	var origin := _origin()
	var a := _roadside(road, origin, true)
	var b := _roadside(road, origin, true)
	for s: float in [0.0, LEG_M - 300.0, LEG_M * 3.0 - 100.0]:
		_move(a, road, origin, s)
	_move(b, road, origin, LEG_M * 3.0 - 100.0)
	var none := PackedFloat64Array()
	eq(_signature_outside(a, road, none), _signature_outside(b, road, none), "same placements, whatever the drive")


# ---------------------------------------------------------------- Lamp pools

## A pool under exactly the poles the roadside kept.
func test_lamp_pools_skip_the_removed_poles() -> void:
	var road := _road()
	var origin := _origin()
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, _t)
	var sky := (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	sky.push_sink = func(_n: StringName, _v: Variant) -> void: pass
	sky.set_process(false)
	tree.root.add_child(sky)
	_nodes.append(sky)
	sky.sky_t = _t.sun.sky_t_night
	sky.push_now()
	var pools := StreetLampPools.new()
	pools.sky = sky
	tree.root.add_child(pools)
	_nodes.append(pools)
	pools.setup(ctx, road, origin)
	var rs := _roadside(road, origin, true)
	var night := NightTuning.load_default()
	var spacing := _t.road.light_pole_spacing_m
	var kinds := LandmarkBuilds.kinds()
	for i in kinds.size():
		var s := LEG_M * float(i + 1) + 20.0
		_move(rs, road, origin, s)
		pools.update_view(s)
		var want := {}
		var poles := _pole_s(rs, road)
		var k0 := ceili((s - night.pool_behind_m) / spacing)
		var k1 := floori((s + night.pool_ahead_m) / spacing)
		for k in range(k0, k1 + 1):
			if poles.has(k):
				want[k] = true
		var got := {}
		for p in pools.count():
			var o := pools.pool_transform(p).origin
			var abs_z := origin.origin_z + o.z
			got[roundi(-(abs_z - road.origin_z) / spacing)] = true
		eq(got.size(), want.size(), "%s: pools under the kept poles only" % kinds[i])
		for k: int in want:
			check(got.has(k), "%s: a pool under pole %d" % [kinds[i], k])
		eq(pools.count(), want.size() * StreetLampPools.HEADS, "two per kept pole")
