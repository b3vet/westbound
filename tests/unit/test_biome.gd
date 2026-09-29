extends WBTest
## BiomeDef data (farmland, desert, canyon) and the BiomeDirector: the journey plan,
## biome_changed at checkpoints, forks. Spec: World → Biomes ("Each leg is one biome.
## Default order ...; forks swap the next biome"), Legs and checkpoints. docs/BIOMES.md.

const DESERT_PATH := "res://data/biomes/desert.tres"
const CANYON_PATH := "res://data/biomes/canyon.tres"

var _t: Tuning
var _director: BiomeDirector
var _changed: Array[StringName] = []


func _on_changed(biome: StringName) -> void:
	_changed.append(biome)


func before_each() -> void:
	_t = Tuning.load_default()
	_changed.clear()
	Events.biome_changed.connect(_on_changed)
	_director = BiomeDirector.new()
	tree.root.add_child(_director)


func after_each() -> void:
	Events.biome_changed.disconnect(_on_changed)
	_director.free()


func _setup(journey: bool = true) -> void:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	_director.journey = journey
	_director.setup(RunContext.new(7, RunContext.MODE_JOURNEY, _t), road, null)


func _leg_m() -> float:
	return _t.legs.leg_length_m()


# ---------------------------------------------------------------- Director

func test_uniform_plan_is_farmland_everywhere_and_changed_once_at_setup() -> void:
	_setup(false)
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


func test_journey_plan_follows_the_legs() -> void:
	_setup()
	var ids := _t.legs.leg_biome_ids
	for leg in range(1, ids.size() + 1):
		var want := BiomePlan.load_biome(ids[leg - 1])
		if want == null:
			continue   # a biome not authored yet falls back (test_biome_plan)
		eq(_director.biome_at(float(leg - 1) * _leg_m() + 1.0).id, ids[leg - 1], "leg %d" % leg)
	eq(_director.biome_at(0.0).id, &"farmland", "the run starts in farmland")
	eq(_director.biome_at(_leg_m() - 0.01).id, &"farmland", "leg 1 up to its checkpoint")
	eq(_director.biome_at(_leg_m()).id, &"desert", "leg 2 from the checkpoint line")
	eq(_director.biome_at(3.0 * _leg_m()).id, &"canyon", "leg 4")


func test_biome_changed_fires_once_per_crossing() -> void:
	_setup()
	var s := 0.0
	var end := 5.0 * _leg_m()
	while s < end:
		_director.update_view(s)
		s += 23.0
	eq(_changed, [&"farmland", &"desert", &"canyon"] as Array[StringName],
		"setup, then one event where the biome changes (desert legs 2-3, canyon 4-5)")
	eq(_director.current().id, &"canyon")


func test_plan_next_swaps_one_leg_and_bumps_the_version() -> void:
	_setup()
	var v0 := _director.plan_version
	var canyon := load(CANYON_PATH) as BiomeDef
	_director.plan_next(2, canyon)
	gt(_director.plan_version, v0, "plan version moved")
	eq(_director.biome_at(_leg_m() + 10.0).id, &"canyon", "leg 2 swapped")
	eq(_director.biome_at(2.0 * _leg_m() + 10.0).id, &"desert", "leg 3 untouched")
	check(_director.biomes().has(canyon), "the catalog has the fork's biome")
	var farmland := _director.biome_at(0.0)
	_director.set_biome_from_leg(3, farmland)
	eq(_director.biome_at(2.0 * _leg_m() + 10.0).id, &"farmland")
	eq(_director.biome_at(40.0 * _leg_m()).id, &"farmland", "the endless road too")


func test_catalog_lists_every_planned_biome_once() -> void:
	_setup()
	var cat := _director.biomes()
	var ids: Array[StringName] = []
	for b in cat:
		check(not ids.has(b.id), "%s once" % b.id)
		ids.append(b.id)
	for id: StringName in [&"farmland", &"desert", &"canyon"]:
		check(ids.has(id), "catalog has %s" % id)


# ---------------------------------------------------------------- Data

func _check_biome_data(b: BiomeDef, id: StringName, order: int) -> void:
	eq(b.id, id)
	eq(b.order, order)
	ne(b.display_name, "", "%s has a display name" % id)
	eq(b, BiomePlan.load_biome(id), "%s loads by id (HUD: data/biomes/<id>.tres)" % id)
	ge(b.lane_count, _t.road.lanes_min)
	le(b.lane_count, _t.road.lanes_max)
	ne(b.horizon_set, &"")
	for k in 4:
		var style := int(b.horizon_layer_style[k])
		check(style >= 0 and style <= SkyRig.HorizonStyle.SKYLINE, "%s horizon layer %d style" % [id, k])
		gt(b.horizon_layer_height_m[k], 0.0)
	eq(b.set_piece_ids.size(), b.set_piece_weights.size(), "%s set-piece mix arrays parallel" % id)
	gt(b.traffic_palette.size(), 0)
	for s in b.landmark_styles:
		check(LandmarkBuilds.kinds().has(s), "%s landmark style %s" % [id, s])
	var paths := PackedStringArray()
	if b.fence_mesh_path != "":
		paths.append(b.fence_mesh_path)
	for p in b.scatter_props:
		paths.append_array(p.mesh_paths)
		check(p.id != &"", "scatter prop has an id")
		ge(p.setback_min_m, 0.0, "%s setback" % p.id)
		le(p.setback_min_m, p.setback_max_m, "%s setback range" % p.id)
		if not p.variant_weights.is_empty():
			eq(p.variant_weights.size(), p.mesh_paths.size(), "%s weights per variant" % p.id)
	for path in paths:
		check(ResourceLoader.exists(path) and load(path) is Mesh, "mesh %s" % path)


func test_farmland_data() -> void:
	var b: BiomeDef = load(BiomeDirector.DEFAULT_BIOME_PATH)
	if not check(b != null, "farmland.tres loads"):
		return
	_check_biome_data(b, &"farmland", 1)
	eq(b.lane_count, 3)
	eq(b.landmark_style, BiomeDef.LANDMARK_TOLL_GANTRY)
	check(b.field_grid != null, "farmland has a field grid")
	check(b.fence_mesh_path != "", "farmland has a fence")
	eq(b.tunnel_frequency_scale, 0.0, "no road tunnels in farmland")
	var g := b.field_grid
	eq(g.crop_mesh_paths.size(), g.crop_weights.size())
	eq(g.yard_mesh_paths.size(), g.yard_weights.size())
	eq(g.tree_mesh_paths.size(), g.tree_weights.size())


## Spec: "Desert mesas: red rock mesas, cacti, long straights, fake heat shimmer near
## the horizon"; biomes add tint offsets ("desert warmer").
func test_desert_data() -> void:
	var b := load(DESERT_PATH) as BiomeDef
	if not check(b != null, "desert.tres loads"):
		return
	_check_biome_data(b, &"desert", 2)
	lt(b.curve_frequency_scale, 1.0, "long straights")
	eq(b.tunnel_frequency_scale, 0.0)
	gt(b.heat_shimmer, 0.0, "heat shimmer near the horizon")
	gt(b.world_tint_offset.r, b.world_tint_offset.b, "warmer")
	gt(b.fog_tint_offset.r, b.fog_tint_offset.b, "warmer haze")
	eq(b.horizon_layer_style.y, float(SkyRig.HorizonStyle.MESAS), "a mesa horizon")
	var ids: Array[StringName] = []
	for p in b.scatter_props:
		ids.append(p.id)
	for want: StringName in [&"mesas", &"saguaro", &"scrub", &"rocks"]:
		check(ids.has(want), "desert has %s" % want)
	check(b.fence_mesh_path.contains("desert"), "a desert fence")


## Spec: "Canyon pass: cliffs, tunnels, more curves and crests".
func test_canyon_data() -> void:
	var b := load(CANYON_PATH) as BiomeDef
	if not check(b != null, "canyon.tres loads"):
		return
	_check_biome_data(b, &"canyon", 3)
	gt(b.curve_frequency_scale, 1.0, "more curves")
	gt(b.crest_frequency_scale, 1.0, "more crests")
	gt(b.tunnel_frequency_scale, 0.0, "tunnels")
	gt(b.bend_sight_clearance_m, 0.0, "cliffs hide bends")
	lt(b.bend_sight_clearance_m, _t.road.bend_sight_clearance_m)
	check(b.cliffs != null, "cliffs")
	var c := b.cliffs
	gt(c.face_count(), 2)
	eq(c.profile_x_m.size(), c.profile_h_m.size(), "profile arrays parallel")
	eq(c.band_colors.size(), c.face_count(), "one band colour per face")
	for i in range(1, c.profile_x_m.size()):
		gt(c.profile_x_m[i], c.profile_x_m[i - 1], "profile runs outward")
	eq(c.profile_x_m[0], 0.0, "the profile starts at the foot")
	le(c.offset_jitter_m, c.setback_m, "the wobble never brings the foot inside the scenery line")
	check(b.landmark_styles.has(BiomeDef.LANDMARK_TUNNEL_PORTAL), "tunnel portal checkpoints")
	# Pines stand behind the cliffs, boulders in front of them.
	var back := c.setback_m + c.profile_x_m[c.profile_x_m.size() - 1] + c.offset_jitter_m
	for p in b.scatter_props:
		check(p.setback_max_m <= c.setback_m or p.setback_min_m >= back,
			"%s (%.0f..%.0f m) clear of the cliff band (%.0f..%.0f m)" % [p.id, p.setback_min_m, p.setback_max_m,
			c.setback_m, back])
