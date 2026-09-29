extends WBTest
## Roadside for the desert and canyon biomes (WP6.4a): their prop layers fill, keep the
## scenery clear zone, stay within the draw-call and triangle budget (at most farmland
## + 6 draw calls), follow the look contract, and swap at the checkpoint line in a
## journey. Spec: World → Biomes (desert: mesas, cacti; canyon: boulders, pines), Road
## (roadside rhythm, MultiMesh), Performance budget. docs/BIOMES.md.

const SEED := 20260928
const VIEW_M := 700.0
const EPS := 0.005
const MESH_TRIANGLE_BUDGET := 400
## Farmland's roadside share (tests/unit/test_roadside.gd) and the headroom for a new biome.
const FARMLAND_DRAW_CALLS := 25
const EXTRA_DRAW_CALLS := 6
const TRIANGLE_SHARE := 60000

var _t: Tuning
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()


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


func _roadside(road: RoadPath, biome: BiomeDef) -> Roadside:
	var rs := Roadside.new()
	rs.view_distance_override_m = VIEW_M
	rs.fallback_biome = biome
	tree.root.add_child(rs)
	_nodes.append(rs)
	rs.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, _origin())
	return rs


func _drive(rs: Roadside, s1: float, step: float) -> Vector2i:
	var worst := Vector2i.ZERO
	var s := 0.0
	while s <= s1:
		rs.update_view(s)
		worst.x = maxi(worst.x, rs.draw_calls())
		worst.y = maxi(worst.y, rs.triangles())
		s += step
	return worst


func _farmland_draw_calls() -> int:
	var rs := _roadside(StraightRoadPath.new(3, _t.road), load(BiomeDirector.DEFAULT_BIOME_PATH) as BiomeDef)
	return _drive(rs, 12000.0, 250.0).x


func test_budget_against_farmland() -> void:
	var farm := _farmland_draw_calls()
	for id: StringName in [&"desert", &"canyon"]:
		var b := BiomePlan.load_biome(id)
		var rs := _roadside(StraightRoadPath.new(3, _t.road), b)
		var worst := _drive(rs, 12000.0, 250.0)
		print("      roadside %s: worst %d draw calls (farmland %d), %d triangles, %d instances" % [id, worst.x, farm,
			worst.y, rs.instance_count()])
		le(worst.x, farm + EXTRA_DRAW_CALLS, "%s draw calls within farmland + %d" % [id, EXTRA_DRAW_CALLS])
		le(worst.x, FARMLAND_DRAW_CALLS + EXTRA_DRAW_CALLS)
		le(worst.y, TRIANGLE_SHARE, "%s triangles" % id)
		for layer in rs.layers:
			if layer.biome == b:
				gt(layer.instance_count(), 0, "%s fills" % layer.id)
			for pool in layer.pools:
				eq(pool.dropped, 0, "%s never overflows" % layer.id)


## Scenery stays beyond the guardrail + prop clearance (the verge), in both biomes.
func test_scenery_keeps_the_clear_zone() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var line := road.guardrail_d(0.0) + _t.road.prop_clearance_m
	for id: StringName in [&"desert", &"canyon"]:
		var b := BiomePlan.load_biome(id)
		var rs := _roadside(road, b)
		_drive(rs, 3000.0, 250.0)
		var checked := 0
		for layer in rs.layers:
			if layer.biome != b:
				continue
			for pool in layer.pools:
				var verts := (pool.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
				for i in mini(pool.count, 40):
					var xf := pool.get_transform(i)
					var min_d := INF
					for v in verts:
						min_d = minf(min_d, absf(layer.anchor_x + (xf * v).x - road.origin_x))
					checked += 1
					if min_d < line - EPS:
						fail("%s %s instance %d at |d| %.2f inside the clear zone (%.2f)" % [id, layer.id, i, min_d, line])
						return
		gt(checked, 50, "%s instances checked" % id)


func test_prop_meshes_follow_the_look_contract() -> void:
	var world: Material = load("res://assets/shaders/materials/world.tres")
	var paths := PackedStringArray()
	for id: StringName in [&"desert", &"canyon"]:
		var b := BiomePlan.load_biome(id)
		if b.fence_mesh_path != "":
			paths.append(b.fence_mesh_path)
		for p in b.scatter_props:
			paths.append_array(p.mesh_paths)
	for path in paths:
		var m := load(path) as Mesh
		eq(m.get_surface_count(), 1, "%s: one surface" % path)
		check(m.surface_get_material(0) == world, "%s uses world.tres" % path)
		var arrays := m.surface_get_arrays(0)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		check(arrays[Mesh.ARRAY_TEX_UV2] != null, "%s has UV2" % path)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		le(int(verts.size() / 3.0), MESH_TRIANGLE_BUDGET, "%s triangle budget" % path)
		var bad := 0
		for n in normals:
			if absf(n.length() - 1.0) > 1e-3:
				bad += 1
		eq(bad, 0, "%s unit normals" % path)
		for c in colors:
			if c.r < 0.0 or c.r > 1.0 or c.g < 0.0 or c.g > 1.0 or c.b < 0.0 or c.b > 1.0:
				fail("%s colour out of range %s" % [path, c])
				break
		var aabb := m.get_aabb()
		ge(aabb.position.y, -1.0, "%s sits on the ground" % path)
	var fence := load(BiomePlan.load_biome(&"desert").fence_mesh_path) as Mesh
	gt(float(fence.get_meta(&"length_m", 0.0)), 0.0, "the desert fence has its segment length")


## In a journey the props swap at the checkpoint line: farmland's layers fill cells
## before it, the desert's after it.
func test_props_swap_at_the_checkpoint() -> void:
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, _t)
	var road := StraightRoadPath.new(3, _t.road)
	var director := BiomeDirector.new()
	tree.root.add_child(director)
	_nodes.append(director)
	director.setup(ctx, road, null)
	var rs := Roadside.new()
	rs.view_distance_override_m = VIEW_M
	rs.biome_director = director
	tree.root.add_child(rs)
	_nodes.append(rs)
	rs.setup(ctx, road, _origin())
	var line := _t.legs.leg_length_m()
	rs.update_view(line - 200.0)
	var farm_after := 0
	var desert_before := 0
	var desert_any := 0
	for layer in rs.layers:
		if layer.biome == null:
			continue
		for pool in layer.pools:
			for i in pool.count:
				var s := road.origin_z - (layer.anchor_z + pool.get_transform(i).origin.z)
				if layer.biome.id == &"farmland" and s > line + layer.cell_length_m:
					farm_after += 1
				if layer.biome.id == &"desert":
					desert_any += 1
					if s < line - layer.cell_length_m:
						desert_before += 1
	eq(farm_after, 0, "no farmland prop past the line (beyond its last cell)")
	eq(desert_before, 0, "no desert prop before the line")
	gt(desert_any, 0, "the desert is in view past the line")
