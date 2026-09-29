extends WBTest
## Biomes 4-6 data (WP6.4b): coastal highway, city at night, valley fog. Spec: World →
## Biomes ("Biome data: prop sets and densities, tint offsets, lane count, set-piece
## mix, horizon silhouette set and checkpoint landmark style"; coast: ocean on one
## side, cliffs; city: skyline, elevated sections, neon billboards; valley: low fog,
## forests), Sky (horizon sets), Road (roadside, scenery line), Performance budget.

const SEED := 20260928
const VIEW_M := 700.0
const POS_EPS := 0.005
## Our share of the budget at Medium, as for farmland (tests/unit/test_roadside.gd).
const DRAW_CALL_SHARE := 25
const TRIANGLE_SHARE := 60000
const MESH_TRIANGLE_BUDGET := 400
const BIOMES: Array[String] = ["coast", "city", "valley_fog"]
const WORLD_MATERIAL := "res://assets/shaders/materials/world.tres"
const WINDOWS_MATERIAL := "res://assets/shaders/materials/world_windows.tres"

var _t: Tuning
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _biome(id: String) -> BiomeDef:
	return load("res://data/biomes/%s.tres" % id) as BiomeDef


func _mesh_paths(b: BiomeDef) -> PackedStringArray:
	var paths := PackedStringArray()
	if b.fence_mesh_path != "":
		paths.append(b.fence_mesh_path)
	if b.field_grid != null:
		paths.append_array(b.field_grid.crop_mesh_paths)
		paths.append_array(b.field_grid.yard_mesh_paths)
		paths.append_array(b.field_grid.tree_mesh_paths)
	for p in b.scatter_props:
		paths.append_array(p.mesh_paths)
	return paths


func _origin() -> FloatingOrigin:
	var o := FloatingOrigin.new()
	o.setup(_t.road.floating_origin_shift_km)
	tree.root.add_child(o)
	_nodes.append(o)
	return o


func _roadside(road: RoadPath, origin: FloatingOrigin, b: BiomeDef) -> Roadside:
	var rs := Roadside.new()
	rs.fallback_biome = b
	rs.view_distance_override_m = VIEW_M
	tree.root.add_child(rs)
	_nodes.append(rs)
	rs.setup(RunContext.new(SEED, RunContext.MODE_JOURNEY, _t), road, origin)
	return rs


# ---------------------------------------------------------------- Data

func _common_data(b: BiomeDef, id: String, order: int) -> void:
	if not check(b != null, "%s.tres loads" % id):
		return
	eq(b.id, StringName(id))
	eq(b.order, order, "%s order" % id)
	ge(b.lane_count, _t.road.lanes_min, "%s lanes" % id)
	le(b.lane_count, _t.road.lanes_max, "%s lanes" % id)
	ne(b.horizon_set, &"", "%s horizon set" % id)
	if check(b.horizon_def != null, "%s horizon definition" % id):
		eq(b.horizon_def.id, b.horizon_set, "%s horizon_def resolves horizon_set" % id)
	eq(b.set_piece_ids.size(), b.set_piece_weights.size(), "%s set-piece arrays parallel" % id)
	gt(b.traffic_palette.size(), 5, "%s traffic palette" % id)
	gt(b.scatter_props.size(), 0, "%s scatter props" % id)
	var styles: Array[StringName] = [BiomeDef.LANDMARK_TOLL_GANTRY, BiomeDef.LANDMARK_SUSPENSION_BRIDGE,
		BiomeDef.LANDMARK_SIGN_GANTRY, BiomeDef.LANDMARK_TUNNEL_PORTAL]
	check(styles.has(b.landmark_style), "%s landmark style" % id)
	for s in b.landmark_styles:
		check(styles.has(s), "%s landmark styles" % id)
	for c: Color in [b.world_tint_offset, b.fog_tint_offset]:
		for k in 3:
			le(absf(c[k]), 0.05, "%s tint offsets are small nudges" % id)
	for p in b.scatter_props:
		check(p.id != &"", "%s scatter prop has an id" % id)
		ge(p.setback_min_m, 0.0, "%s %s setback" % [id, p.id])
		le(p.setback_min_m, p.setback_max_m, "%s %s setback range" % [id, p.id])
		if not p.variant_weights.is_empty():
			eq(p.variant_weights.size(), p.mesh_paths.size(), "%s %s weights" % [id, p.id])
		if p.pattern == RoadsideProp.Pattern.ROW:
			le(float(p.row_count_max - 1) * p.row_spacing_m, p.cell_length_m, "%s %s row fits its cell" % [id, p.id])
	if b.field_grid != null:
		var g := b.field_grid
		eq(g.crop_mesh_paths.size(), g.crop_weights.size())
		eq(g.yard_mesh_paths.size(), g.yard_weights.size())
		eq(g.tree_mesh_paths.size(), g.tree_weights.size())
	for path in _mesh_paths(b):
		check(ResourceLoader.exists(path) and load(path) is Mesh, "%s mesh %s" % [id, path])


func test_coast_data() -> void:
	var b := _biome("coast")
	_common_data(b, "coast", 4)
	if b == null:
		return
	check(b.water != null, "the coast has an ocean")
	check(b.world_tint_offset.b > b.world_tint_offset.r, "the coast is tinted cooler")
	eq(b.landmark_style, BiomeDef.LANDMARK_SUSPENSION_BRIDGE, "the coast's own landmark is the bridge")
	# The land falls to the sea on the water's side: no scenery stands there (the sea
	# has its own islets); the land props (cliffs, houses, palms, scrub) are opposite.
	var land_side := RoadsideProp.Sides.RIGHT if b.water.side < 0 else RoadsideProp.Sides.LEFT
	for p in b.scatter_props:
		eq(p.sides, land_side, "%s on the land side" % p.id)
	eq(b.fence_mesh_path, "", "no fence: it would stand on the sea slope")
	gt(b.water.drop_m, 0.0, "the sea lies below the road")
	gt(b.water.islet_chance_frac, 0.0, "sea stacks and a lighthouse islet")
	for path in b.water.islet_mesh_paths:
		check(load(path) is Mesh, "islet mesh %s" % path)


func test_city_data() -> void:
	var b := _biome("city")
	_common_data(b, "city", 5)
	if b == null:
		return
	check(b.elevated != null, "the city has elevated sections")
	check(b.field_grid != null, "the city has blocks")
	var g := b.field_grid
	near(g.yard_chance_frac + g.bare_chance_frac, 1.0, 1e-9, "blocks are buildings or bare lots (no crops)")
	# Everything the city stands beside an elevated stretch reaches the lowered ground.
	var paths := PackedStringArray(g.yard_mesh_paths)
	paths.append_array(g.tree_mesh_paths)
	for p in b.scatter_props:
		paths.append_array(p.mesh_paths)
	for path in paths:
		var m := load(path) as Mesh
		le(m.get_aabb().position.y, -b.elevated.height_m + POS_EPS, "%s reaches the lowered ground" % path)
	# Neon: class 2 emissive faces (bright at night); buildings: lit windows (class 4).
	var neon := 0
	for p in b.scatter_props:
		if String(p.id).begins_with("neon"):
			neon += 1
			check(_emissive_classes(load(p.mesh_paths[0]) as Mesh).has(PropMeshBuilder.EMISSIVE_STREETLAMP),
				"%s glows at night" % p.id)
	ge(neon, 2, "two neon billboard sets")
	for path in g.yard_mesh_paths:
		var m := load(path) as Mesh
		if m.surface_get_material(0).resource_path == WINDOWS_MATERIAL:
			check(_emissive_classes(m).has(BiomePropBuilder.EMISSIVE_WINDOW), "%s has lit windows" % path)
	var sky := b.horizon_def
	gt(sky.layer_windows.x, 0.0, "the near skyline lights up at night")
	eq(sky.layer_style.x, float(HorizonSetDef.STYLE_SKYLINE), "a skyline horizon")


func test_valley_data() -> void:
	var b := _biome("valley_fog")
	_common_data(b, "valley_fog", 6)
	if b == null:
		return
	check(b.fog_cards != null, "the valley has low fog layers")
	check(b.water != null and b.water.span_cell_m > 0.0, "river glimpses")
	var forest := 0
	for p in b.scatter_props:
		if String(p.id).begins_with("forest"):
			forest += 1
	ge(forest, 2, "forests")
	gt(b.horizon_def.layer_mist.x, 0.0, "mist between the ridges")


func _emissive_classes(m: Mesh) -> Dictionary:
	var out := {}
	var uv2: PackedVector2Array = m.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	for u in uv2:
		out[int(u.x)] = true
	return out


# ---------------------------------------------------------------- Meshes

func test_meshes_follow_the_look_contract() -> void:
	var world: Material = load(WORLD_MATERIAL)
	var windows: Material = load(WINDOWS_MATERIAL)
	for id in BIOMES:
		for path in _mesh_paths(_biome(id)):
			var m := load(path) as Mesh
			eq(m.get_surface_count(), 1, "%s: one surface" % path)
			var mat := m.surface_get_material(0)
			check(mat == world or mat == windows, "%s uses world.tres or world_windows.tres" % path)
			var arrays := m.surface_get_arrays(0)
			check(arrays[Mesh.ARRAY_NORMAL] != null, "%s normals" % path)
			check(arrays[Mesh.ARRAY_COLOR] != null, "%s vertex colors" % path)
			check(arrays[Mesh.ARRAY_TEX_UV2] != null, "%s UV2 (emissive class)" % path)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			le(int(verts.size() / 3.0), MESH_TRIANGLE_BUDGET, "%s triangle budget" % path)


# ---------------------------------------------------------------- Roadside

## Each biome on the roadside at Medium: within the farmland share of draw calls and
## triangles, pools never overflow, and every scenery vertex stays beyond the scenery
## line (guardrail face + prop clearance): nothing on the carriageway or shoulders.
func test_roadside_budget_and_clearance() -> void:
	var road := StraightRoadPath.new(3, _t.road)
	var line := road.guardrail_d(0.0) + _t.road.prop_clearance_m
	for id in BIOMES:
		var origin := _origin()
		var rs := _roadside(road, origin, _biome(id))
		var worst_dc := 0
		var worst_tris := 0
		var s := 0.0
		var checked := 0
		while s <= 12000.0:
			var smp := road.sample(s)
			origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
			rs.update_view(s)
			worst_dc = maxi(worst_dc, rs.draw_calls())
			worst_tris = maxi(worst_tris, rs.triangles())
			if int(s) % 3000 == 0:
				checked += _check_clearance(rs, line, id)
			s += 250.0
		print("  %s roadside at %d m: worst %d draw calls, %d triangles, %d pools" % [id, int(VIEW_M), worst_dc,
			worst_tris, rs.pool_count()])
		le(worst_dc, DRAW_CALL_SHARE, "%s draw calls" % id)
		le(worst_tris, TRIANGLE_SHARE, "%s triangles" % id)
		gt(checked, 100, "%s instances checked" % id)
		for layer in rs.layers:
			for pool in layer.pools:
				eq(pool.dropped, 0, "%s %s: pools sized for the data" % [id, layer.id])


## Minimum |d| of every scenery instance's vertices on a straight road (d = x).
func _check_clearance(rs: Roadside, line: float, id: String) -> int:
	var n := 0
	for layer in rs.layers:
		if layer.biome == null and layer.id != &"billboard":
			continue
		for pool in layer.pools:
			var verts := pool.mesh.get_faces()
			for i in pool.count:
				var xf := pool.get_transform(i)
				var min_ad := INF
				for v in verts:
					min_ad = minf(min_ad, absf(layer.anchor_x + (xf * v).x))
				n += 1
				if min_ad < line - POS_EPS:
					fail("%s: %s instance at |d| = %.2f, inside the scenery line %.2f" % [id, layer.id, min_ad, line])
					return n
	return n


# ---------------------------------------------------------------- Horizon sets

func test_horizon_sets_apply_to_the_sky() -> void:
	var base_shader := load("res://assets/shaders/horizon.gdshader") as Shader
	var ext_shader := load(HorizonSetDef.SHADER_PATH) as Shader
	var ext_names := {}
	for u: Dictionary in ext_shader.get_shader_uniform_list():
		ext_names[u["name"]] = true
	for u: Dictionary in base_shader.get_shader_uniform_list():
		check(ext_names.has(u["name"]), "horizon_biomes keeps horizon.gdshader's uniform %s" % u["name"])
	for id in BIOMES:
		var set_def := _biome(id).horizon_def
		var mat := (load("res://assets/shaders/materials/horizon.tres") as ShaderMaterial).duplicate() as ShaderMaterial
		set_def.apply(mat)
		check(set_def.needs_extended_shader(), "%s uses the extensions" % id)
		eq(mat.shader.resource_path, HorizonSetDef.SHADER_PATH, "%s switches the shader" % id)
		eq(mat.render_priority, -98, "%s keeps the horizon's draw order" % id)
		eq(mat.get_shader_parameter(&"layer_style"), set_def.layer_style, "%s styles" % id)
		eq(mat.get_shader_parameter(&"layer_mist"), set_def.layer_mist, "%s mist" % id)
	var coast := _biome("coast").horizon_def
	eq(coast.layer_land.y, -1.0, "coast islands only over the sea")
	eq(coast.layer_land.x, 1.0, "coast headlands only over the land")


func test_palette_extension_is_additive() -> void:
	var base := WBPalette.load_default()
	var extra := load(BiomePropBuilder.EXTRA_PALETTE) as WBPalette
	eq(extra.names.size(), extra.colors.size(), "names and colors parallel")
	for n in extra.names:
		check(not base.names.has(n), "%s does not shadow a style-guide color" % n)
	var merged := BiomePropBuilder.merged_palette()
	eq(merged.size(), base.size() + extra.size())
