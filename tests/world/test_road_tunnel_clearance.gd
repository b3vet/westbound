extends WBTest
## Road tunnels and the roadside (WP6.4a): LandmarkClearance lists a zone kind
## ZONE_TUNNEL for every TUNNEL feature (the central wall on the median through the
## bore, walls and hill with its hips beyond the guardrails), the road-built shell lies
## inside those zones, and the roadside keeps its props out (median light poles, posts,
## fences, scatter) while canyon cliffs run on through. Spec: World → Biomes (canyon:
## tunnels), World → Road (roadside rhythm). docs/BIOMES.md, docs/LANDMARKS.md.

const TS := 1300.0
const TE := 1800.0
const EPS := 1e-3
const VIEW_M := 700.0

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


func _road() -> StraightRoadPath:
	var r := StraightRoadPath.new(2, _t.road)
	r.add_feature(RoadFeature.make(RoadFeature.Kind.TUNNEL, TS, TE, TE - TS))
	return r


func test_tunnel_zones_block_the_median_and_the_hill() -> void:
	var road := _road()
	var c := LandmarkClearance.new()
	c.setup(road, _lt, null)
	c.prepare(0.0, 3000.0)
	var pole := (load(Roadside.LIGHT_POLE_MESH) as Mesh).get_aabb()
	check(c.blocks_upright(pole, 1500.0, 0.0, 0.0), "median pole inside the bore")
	check(not c.blocks_upright(pole, 1000.0, 0.0, 0.0), "none before the tunnel")
	check(not c.blocks_upright(pole, 1500.0, 0.0, 0.0, 1.0, 1.0, 1.0, LandmarkClearance.ZONE_LANDMARK),
		"a landmark-only query ignores road tunnels")
	var hill_d := road.guardrail_d(TS) + _lt.tunnel_wall_offset_m + 10.0
	check(c.blocks(TS - 10.0, TS - 9.0, hill_d, hill_d + 1.0, 3.0), "the hip before the portal")
	check(not c.blocks(TS - 10.0, TS - 9.0, hill_d, hill_d + 1.0, _lt.clearance_ground_cover_m * 0.5),
		"low ground cover runs under the hill")
	check(not c.blocks(TS - _lt.tunnel_hill_width_m - 5.0, TS - _lt.tunnel_hill_width_m - 4.0, hill_d, hill_d + 1.0,
		3.0), "clear past the hip")
	var zones := PackedFloat64Array()
	c.zones_in(0.0, 3000.0, zones)
	eq(int(zones.size() / float(LandmarkBuilds.ZONE_FLOATS)), 3, "median + both sides")


## Every shell / hill vertex beyond the guardrails (above the ground cover) lies in a
## zone, so no roadside prop can stand in the built tunnel.
func test_built_shell_lies_in_its_zones() -> void:
	var road := _road()
	var c := LandmarkClearance.new()
	c.setup(road, _lt, null)
	var zones := PackedFloat64Array()
	c.zones_in(0.0, 3000.0, zones)
	var pal := RoadPalette.new()
	var outside := 0
	var checked := 0
	var g := road.guardrail_d(0.0) + _lt.tunnel_wall_offset_m - EPS
	for s0: float in [TS - 200.0, TS, TS + 200.0, TS + 400.0]:
		var m := RoadChunkMesher.new(_t.road, pal, _lt)
		m.build(road, s0, s0 + _t.road.chunk_length_m)
		for i in m.world_vertices.size():
			var col := m.world_colors[i]
			if col != pal.rock and col != pal.rock_shade and col != pal.portal and col != pal.tunnel_wall \
					and not col.is_equal_approx(pal.tunnel_wall * _t.road.tunnel_interior_shade_frac):
				continue
			var v := m.world_vertices[i]
			var s := -(m.anchor_z + v.z)
			var d := m.anchor_x + v.x
			if absf(d) < g or v.y <= _lt.clearance_ground_cover_m:
				continue
			checked += 1
			var inside := false
			for k in range(0, zones.size(), LandmarkBuilds.ZONE_FLOATS):
				if s >= zones[k] - EPS and s <= zones[k + 1] + EPS and d >= zones[k + 2] - EPS \
						and d <= zones[k + 3] + EPS:
					inside = true
					break
			if not inside:
				outside += 1
	gt(checked, 100, "shell vertices checked")
	eq(outside, 0, "every shell vertex beyond the guardrails is in a zone")


## The real canyon road with the roadside: no median pole inside a tunnel, and the
## roadside cleared props there.
func test_roadside_keeps_out_of_real_tunnels() -> void:
	var ctx := RunContext.new(20260929, RunContext.MODE_JOURNEY, _t)
	var road := ProceduralRoadPath.new(ctx)
	var director := BiomeDirector.new()
	tree.root.add_child(director)
	_nodes.append(director)
	director.setup(ctx, road, null)
	var origin := FloatingOrigin.new()
	origin.setup(_t.road.floating_origin_shift_km)
	tree.root.add_child(origin)
	_nodes.append(origin)
	var leg := _t.legs.leg_length_m()
	road.ensure_generated_to(leg * 5.0)
	var tunnels: Array[RoadFeature] = []
	var all: Array[RoadFeature] = []
	road.features_in(3.0 * leg, 5.0 * leg, all)
	for f in all:
		if f.kind == RoadFeature.Kind.TUNNEL:
			tunnels.append(f)
	if not gt(tunnels.size(), 0, "canyon legs have tunnels"):
		return
	var rs := Roadside.new()
	rs.view_distance_override_m = VIEW_M
	rs.biome_director = director
	tree.root.add_child(rs)
	_nodes.append(rs)
	rs.setup(ctx, road, origin)
	var f := tunnels[0]
	var s := f.s_start - 300.0
	var smp := RoadSample.new()
	var saw_inside := false
	while s < f.s_end + 100.0:
		road.ensure_generated_to(s + VIEW_M + 500.0)
		road.sample_into(s, smp)
		origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
		rs.update_view(s)
		var poles := rs.find_layer(&"light_pole")
		for pool in poles.pools:
			for i in pool.count:
				var p := pool.get_transform(i).origin
				var ax := poles.anchor_x + p.x
				var az := poles.anchor_z + p.z
				# Poles stand at s = k * spacing: find k from the nearest road sample.
				var k := roundi(s / _t.road.light_pole_spacing_m)
				for dk in range(-20, 20):
					var sk := float(k + dk) * _t.road.light_pole_spacing_m
					if sk < 0.0:
						continue
					road.sample_into(sk, smp)
					if absf(smp.pos_x - ax) < 0.01 and absf(smp.pos_z - az) < 0.01:
						if sk > f.s_start + 1.0 and sk < f.s_end - 1.0:
							fail("a median pole inside the tunnel at %.0f" % sk)
							return
						saw_inside = saw_inside or (sk > f.s_start - 100.0)
		s += 100.0
	check(saw_inside, "poles found around the tunnel")
	gt(rs.cleared_count(), 0, "props were cleared")
