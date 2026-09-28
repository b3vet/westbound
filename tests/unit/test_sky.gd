extends WBTest
## Sky (src/sun/sky.gd): pushes every declared wb_* global once, then only the
## changed ones; linear colors; sun direction; fog from the view distance;
## accent API. Spec: World → Color script, Sky; docs/CONTRACTS.md §13.

const SKY_SCENE := "res://src/sun/sky.tscn"
const VIEW_M := 700.0

var _sky: SkyRig
var _log: Dictionary = {}
var _calls: int = 0


func _record(global_name: StringName, value: Variant) -> void:
	_log[global_name] = value
	_calls += 1


func before_each() -> void:
	_log.clear()
	_calls = 0
	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.push_sink = _record
	_sky.view_distance_override_m = VIEW_M
	_sky.sky_t = Tuning.load_default().sun.sky_t_afternoon
	_sky.set_process(false)  # push_now() is called explicitly
	tree.root.add_child(_sky)


func after_each() -> void:
	_sky.free()


static func _declared_globals() -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in ProjectSettings.get_property_list():
		var n: String = p["name"]
		if n.begins_with("shader_globals/"):
			out.append(n.trim_prefix("shader_globals/"))
	out.sort()
	return out


func test_pushes_every_declared_global() -> void:
	var declared := _declared_globals()
	check(declared.size() > 0, "project declares shader globals")
	var pushed := PackedStringArray()
	for k: StringName in _log.keys():
		pushed.append(String(k))
	pushed.sort()
	eq(pushed, declared, "first push covers exactly the declared globals")
	var listed := PackedStringArray()
	for g: StringName in SkyRig.GLOBALS:
		listed.append(String(g))
	listed.sort()
	eq(listed, declared, "SkyRig.GLOBALS matches project.godot [shader_globals]")


func test_value_types_match_declarations() -> void:
	for g: StringName in _log.keys():
		var decl: Dictionary = ProjectSettings.get_setting("shader_globals/%s" % g)
		var v: Variant = _log[g]
		match String(decl["type"]):
			"color":
				check(v is Color, "%s is a Color" % g)
			"vec3":
				check(v is Vector3, "%s is a Vector3" % g)
			"float":
				check(v is float, "%s is a float" % g)
			_:
				fail("%s: unexpected declared type %s" % [g, decl["type"]])


func test_skips_unchanged_values() -> void:
	_calls = 0
	eq(_sky.push_now(), 0, "same sky_t: nothing pushed")
	eq(_calls, 0)
	# Moving sky_t changes colors but not e.g. the biome offset or player light.
	_sky.sky_t = Tuning.load_default().sun.sky_t_golden_hour
	var n := _sky.push_now()
	gt(n, 0, "new sky_t pushes")
	lt(n, SkyRig.GLOBALS.size(), "unchanged globals are skipped")
	eq(_calls, n)
	eq(_sky.push_now(), 0, "and settles again")


func test_setters_push_only_their_global() -> void:
	_log.clear()
	_sky.set_biome_tint_offset(Vector3(0.02, 0.0, -0.01))
	eq(_sky.push_now(), 1)
	check(_log.has(&"wb_biome_tint_offset"))


func test_colors_are_pushed_linear() -> void:
	var k := ColorScript.load_default().get_key(&"afternoon")
	var zen: Color = _log[&"wb_sky_zenith"]
	var expected := k.sky_zenith.srgb_to_linear()
	near(zen.r, expected.r, 1e-5)
	near(zen.g, expected.g, 1e-5)
	near(zen.b, expected.b, 1e-5)


func test_sun_direction_unit_west_and_elevated() -> void:
	var cs := ColorScript.load_default()
	for key: StringName in ColorScript.KEY_ORDER:
		_sky.sky_t = cs.position_of(key)
		_sky.push_now()
		var d: Vector3 = _log[&"wb_sun_dir"]
		near(d.length(), 1.0, 1e-5, "%s: unit length" % key)
		near(d.x, 0.0, 1e-6, "%s: azimuth at world heading 0 (no X)" % key)
		lt(d.z, 0.0, "%s: toward -Z (due west)" % key)
		var elev := rad_to_deg(asin(d.y))
		near(elev, cs.get_key(key).sun_elevation_deg, 1e-3, "%s: elevation from the color script" % key)
	near(SkyRig.sun_direction(0.0).z, -1.0, 1e-6, "heading 0 faces -Z")


func test_fog_tracks_view_distance() -> void:
	var k := _sky.current()
	near(_log[&"wb_fog_end"], k.fog_end_frac * VIEW_M, 1e-3)
	near(_log[&"wb_fog_start"], k.fog_start_frac * VIEW_M, 1e-3)
	le(_log[&"wb_fog_end"], VIEW_M, "fog ends within the view distance")
	_sky.view_distance_override_m = 500.0
	_sky.push_now()
	near(_log[&"wb_fog_end"], k.fog_end_frac * 500.0, 1e-3, "follows a lower tier")


func test_accent_api_and_signal() -> void:
	var cs := ColorScript.load_default()
	var got: Array[Color] = []
	_sky.accent_changed.connect(func(c: Color) -> void: got.append(c))
	eq(_sky.get_accent(), cs.get_key(&"afternoon").ui_accent)
	_sky.sky_t = cs.position_of(&"night")
	_sky.push_now()
	eq(got.size(), 1, "accent_changed once")
	eq(_sky.get_accent(), cs.get_key(&"night").ui_accent)
	_sky.push_now()
	eq(got.size(), 1, "no signal when unchanged")


func test_stars_hidden_by_day_shown_at_night() -> void:
	var stars := _sky.get_node("Stars") as MeshInstance3D
	check(not stars.visible, "no star draw call in the afternoon")
	_sky.sky_t = ColorScript.load_default().position_of(&"night")
	_sky.push_now()
	check(stars.visible, "stars at night")


func test_player_light_follows_headlight_ramp() -> void:
	_sky.set_player_light(Vector3(1, 2, 3), Vector3.FORWARD, 1.0)
	_sky.push_now()
	near(_log[&"wb_player_light_strength"], _sky.current().emissive_headlight, 1e-6, "day: ramp")
	_sky.sky_t = ColorScript.load_default().position_of(&"night")
	_sky.push_now()
	near(_log[&"wb_player_light_strength"], ColorScript.load_default().get_key(&"night").emissive_headlight, 1e-6)
	eq(_log[&"wb_player_light_pos"], Vector3(1, 2, 3))


func test_horizon_mesh_layout() -> void:
	var m := SkyRig.build_horizon_mesh(8, SkyRig.HORIZON_LAYERS)
	var arr := m.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	eq(verts.size(), SkyRig.HORIZON_LAYERS * 9 * 2)
	for v: Vector3 in verts:
		near(v.length(), 1.0, 1e-5)
		near(v.y, 0.0, 1e-6)
