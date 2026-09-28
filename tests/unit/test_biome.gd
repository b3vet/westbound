extends WBTest
## BiomeDef data (farmland) and the BiomeDirector skeleton. Spec: World → Biomes.

var _director: BiomeDirector
var _changed: Array[StringName] = []


func _on_changed(biome: StringName) -> void:
	_changed.append(biome)


func before_each() -> void:
	_changed.clear()
	Events.biome_changed.connect(_on_changed)
	_director = BiomeDirector.new()
	tree.root.add_child(_director)


func after_each() -> void:
	Events.biome_changed.disconnect(_on_changed)
	_director.free()


func _setup() -> void:
	var t := Tuning.load_default()
	var road := StraightRoadPath.new(t.road.lanes_default, t.road)
	_director.setup(RunContext.new(7, RunContext.MODE_JOURNEY, t), road, null)


func test_farmland_everywhere_and_changed_once_at_setup() -> void:
	_setup()
	eq(_changed.size(), 1, "biome_changed emitted once at setup")
	if _changed.size() > 0:
		eq(_changed[0], &"farmland")
	for s: float in [0.0, 1.0, 999.0, 25_000.0, 1_000_000.0]:
		eq(_director.biome_at(s).id, &"farmland", "biome at %s" % s)
	var s := 0.0
	while s < 30_000.0:
		_director.update_view(s)
		s += 37.0
	eq(_changed.size(), 1, "no further change while farmland continues")
	eq(_director.current().id, &"farmland")


func test_set_biome_from_switches_once_when_crossed() -> void:
	_setup()
	var other := BiomeDef.new()
	other.id = &"desert"
	_director.set_biome_from(10_000.0, other)
	eq(_director.biome_at(9_999.0).id, &"farmland")
	eq(_director.biome_at(10_000.0).id, &"desert")
	eq(_director.biomes().size(), 2)
	_director.update_view(9_000.0)
	_director.update_view(10_500.0)
	_director.update_view(11_000.0)
	eq(_changed, [&"farmland", &"desert"] as Array[StringName])
	# A fork re-plans from s on, replacing what came after.
	_director.set_biome_from(8_000.0, _director.default_biome)
	eq(_director.biome_at(12_000.0).id, &"farmland")
	eq(_director.biomes().size(), 1)


func test_farmland_data() -> void:
	var b: BiomeDef = load(BiomeDirector.DEFAULT_BIOME_PATH)
	if not check(b != null, "farmland.tres loads"):
		return
	eq(b.id, &"farmland")
	eq(b.order, 1)
	eq(b.lane_count, 3)
	eq(b.landmark_style, BiomeDef.LANDMARK_TOLL_GANTRY)
	ne(b.horizon_set, &"")
	eq(b.set_piece_ids.size(), b.set_piece_weights.size(), "set-piece mix arrays parallel")
	gt(b.traffic_palette.size(), 0)
	check(b.field_grid != null, "farmland has a field grid")
	check(b.fence_mesh_path != "", "farmland has a fence")
	gt(b.scatter_props.size(), 0)
	var g := b.field_grid
	eq(g.crop_mesh_paths.size(), g.crop_weights.size())
	eq(g.yard_mesh_paths.size(), g.yard_weights.size())
	eq(g.tree_mesh_paths.size(), g.tree_weights.size())
	var paths := PackedStringArray([b.fence_mesh_path])
	paths.append_array(g.crop_mesh_paths)
	paths.append_array(g.yard_mesh_paths)
	paths.append_array(g.tree_mesh_paths)
	for p in b.scatter_props:
		paths.append_array(p.mesh_paths)
		check(p.id != &"", "scatter prop has an id")
		ge(p.setback_min_m, 0.0, "%s setback" % p.id)
		le(p.setback_min_m, p.setback_max_m, "%s setback range" % p.id)
		if p.pattern == RoadsideProp.Pattern.ROW:
			le(float(p.row_count_max - 1) * p.row_spacing_m, p.cell_length_m, "%s row fits its cell" % p.id)
	for path in paths:
		check(ResourceLoader.exists(path) and load(path) is Mesh, "mesh %s" % path)
