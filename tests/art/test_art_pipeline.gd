extends WBTest
## Game-side art pipeline (WP-ART-G; docs/ART_PRODUCTION.md §3, §3.11 G1-G9). The
## calibration assets (tools/art/art_calib.gd; fixtures in tests/art/fixtures, written by
## tools/art/make_calibration.gd) go through the modular car import (G1: through the
## editor importer and without it), the colour round trip (G9), the rim swap (G5), the
## converters (G2 props, G3 traffic) and the id renames (G7).

const CAR_DEF := "res://tests/art/fixtures/calib_car/calib_car.tres"
const CAR_GLB := "res://tests/art/fixtures/calib_car/calib_car.glb"
const RIM_GLB := "res://tests/art/fixtures/calib_rim/calib_rim.glb"
const TRAFFIC_GLB := "res://tests/art/fixtures/export/traffic/calib_traffic.glb"
const TRAFFIC_LOD1_GLB := "res://tests/art/fixtures/export/traffic/calib_traffic_lod1.glb"
const SWATCH_GLB := "res://tests/art/fixtures/export/props/common/calib_swatch.glb"
const OUT_DIR := "user://art_pipeline_test"
## Vertex COLOR is stored as 8 bits per channel: the round trip must hold to 1/255.
const COLOR_TOL := 1.0 / 255.0
const POS_TOL := 1e-3

var _tuning: Tuning
var _pal: ArtPalette
var _nodes: Array[Node] = []


func before_all() -> void:
	_tuning = Tuning.load_default()
	_pal = ArtPalette.new()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _keep(n: Node) -> Node:
	_nodes.append(n)
	return n


func _same_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= COLOR_TOL and absf(a.g - b.g) <= COLOR_TOL and absf(a.b - b.b) <= COLOR_TOL


## The calibration car converted without the editor: scene -> .glb -> GLTFDocument -> G1.
func _runtime_car() -> Node3D:
	var path := OUT_DIR + "/calib_car_runtime.glb"
	var built := ArtCalib.new(_pal).build_car()
	eq(ArtCalib.write_glb(built, path), OK, "writes the calibration .glb")
	built.free()
	var scene := ArtCalib.read_glb(path)
	check(scene != null, "reads it back")
	var root := CarModularImport.convert(scene, {"modular": true}, "Car_CalibCar", _pal)
	scene.free()
	return _keep(root) as Node3D


func _imported_car() -> Node3D:
	var scene := load(CAR_GLB) as PackedScene
	check(scene != null, "the fixture is imported with assets/cars/car_import.gd")
	return _keep(scene.instantiate()) as Node3D


# ---------------------------------------------------------------- G1 + G9

func test_calibration_car_round_trip_through_the_editor_import() -> void:
	_check_calib_car(_imported_car(), "editor import")


func test_calibration_car_round_trip_without_the_editor() -> void:
	_check_calib_car(_runtime_car(), "GLTFDocument")


## Every palette colour, shade and fixed vehicle colour arrives exactly; the tree, the
## node types, the transforms and the visibility rules survive.
func _check_calib_car(root: Node3D, label: String) -> void:
	eq(String(root.name), "Car_CalibCar", "%s: root name" % label)
	eq(root.get_meta(&"car_import_problems", PackedStringArray(["no meta"])), PackedStringArray(), "%s: no problems" % label)
	eq(root.get_meta(&"car_import_stubbed", PackedStringArray(["no meta"])), PackedStringArray(), "%s: nothing stubbed" % label)
	check(bool(root.get_meta(&"car_import_modular", false)), "%s: took the modular path" % label)
	for p in CarModel.required_paths():
		check(root.get_node_or_null(NodePath(p)) != null, "%s: %s exists" % [label, p])
	# Body: one surface per slot, the swatches exact.
	var body := root.get_node(^"Body") as MeshInstance3D
	var slots := PackedStringArray()
	for s in body.mesh.get_surface_count():
		slots.append(body.mesh.surface_get_name(s))
	eq(slots, PackedStringArray(["paint", "trim", "glass"]), "%s: Body surfaces" % label)
	var trim := body.mesh.surface_get_arrays(1)
	var tv: PackedVector3Array = trim[Mesh.ARRAY_VERTEX]
	var tc: PackedColorArray = trim[Mesh.ARRAY_COLOR]
	var names := _pal.all_names()
	var half := ArtCalib.swatch_tile_half(names.size())
	var wrong := PackedStringArray()
	for i in names.size():
		var c := ArtCalib.swatch_tile_center(i, names.size())
		var found := 0
		for k in tv.size():
			var d := tv[k] - c
			if absf(d.x) <= POS_TOL and absf(d.y) <= half.x + POS_TOL and absf(d.z) <= half.y + POS_TOL:
				found += 1
				if not _same_color(tc[k], _pal.color(names[i])):
					wrong.append("%s %s != %s" % [names[i], tc[k].to_html(false), _pal.color(names[i]).to_html(false)])
					break
		if found == 0:
			wrong.append("%s: no tile" % names[i])
	eq(wrong, PackedStringArray(), "%s: every palette colour arrives exact (%d names)" % [label, names.size()])
	# Paint shades 1 / 0.8 / 0.55 in COLOR.r; glass colours.
	var shades := {}
	for col: Color in body.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]:
		shades[snappedf(col.r, 0.01)] = true
	eq(shades.keys().size(), 3, "%s: three paint shades" % label)
	for k: float in [1.0, 0.8, 0.55]:
		check(shades.has(snappedf(k, 0.01)), "%s: paint shade %s" % [label, k])
	var glass_cols: PackedColorArray = body.mesh.surface_get_arrays(2)[Mesh.ARRAY_COLOR]
	check(glass_cols.has(CarModel.COLOR_GLASS) or _any_color(glass_cols, CarModel.COLOR_GLASS), "%s: glass colour" % label)
	check(_any_color(glass_cols, _pal.color(&"roof_slate")), "%s: glass_roof_slate" % label)
	# Lights: slot, colour, visibility.
	for spec: Array in [["headlight_L", CarModel.Slot.LAMP, CarModel.COLOR_HEADLIGHT, true],
			["taillight_R", CarModel.Slot.LAMP, CarModel.COLOR_TAILLIGHT, true],
			["brake_L", CarModel.Slot.SIGNAL, CarModel.COLOR_BRAKE, false],
			["blinker_FR", CarModel.Slot.SIGNAL, CarModel.COLOR_BLINKER, false],
			["blinker_RL", CarModel.Slot.SIGNAL, CarModel.COLOR_BLINKER, false],
			["reverse", CarModel.Slot.SIGNAL, CarModel.COLOR_REVERSE, false]]:
		var l := root.get_node("Lights/%s" % spec[0]) as MeshInstance3D
		eq(l.mesh.surface_get_name(0), String(CarModel.SLOT_NAMES[int(spec[1])]), "%s: %s slot" % [label, spec[0]])
		check(_same_color((l.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray)[0], spec[2]),
			"%s: %s colour" % [label, spec[0]])
		eq(l.visible, bool(spec[3]), "%s: %s shown only when switched" % [label, spec[0]])
	var head := root.get_node(^"Lights/headlight_L") as Node3D
	lt(head.position.z, 0.0, "%s: headlights at the front (-Z)" % label)
	lt(head.position.x, 0.0, "%s: headlight_L on the left (-X)" % label)
	# Wheels: shared meshes, left pivots turned, hubs where the calibration put them.
	var tire0 := (root.get_node(^"Wheel_FL/Tire") as MeshInstance3D).mesh
	var rim0 := (root.get_node(^"Wheel_FL/Rim") as MeshInstance3D).mesh
	for w: StringName in CarModel.WHEEL_NAMES:
		eq((root.get_node("%s/Tire" % w) as MeshInstance3D).mesh, tire0, "%s: %s shares the tire mesh" % [label, w])
		eq((root.get_node("%s/Rim" % w) as MeshInstance3D).mesh, rim0, "%s: %s shares the rim mesh" % [label, w])
	var fl := root.get_node(^"Wheel_FL") as Node3D
	check(fl.position.is_equal_approx(Vector3(-ArtCalib.TRACK_HALF, ArtCalib.WHEEL_R, -ArtCalib.CAR_WHEELBASE * 0.5)),
		"%s: Wheel_FL hub %s" % [label, fl.position])
	check(fl.basis.is_equal_approx(Basis.IDENTITY), "%s: pivots unrotated" % label)
	var left_tire := root.get_node(^"Wheel_RL/Tire") as Node3D
	near(left_tire.basis.x.x, -1.0, POS_TOL, "%s: left tire turned 180 degrees" % label)
	near((root.get_node(^"Wheel_RR/Tire") as Node3D).basis.x.x, 1.0, POS_TOL, "%s: right tire not turned" % label)
	# Markers: Marker3D at their spots.
	for mk: StringName in CarModel.MARKER_NAMES:
		check(root.get_node("Markers/%s" % mk) is Marker3D, "%s: %s is a Marker3D" % [label, mk])
	check((root.get_node(^"Markers/cam_cockpit") as Node3D).position.is_equal_approx(ArtCalib.EYE), "%s: eye" % label)
	# Interior: hidden, interior and gauges materials, colours, screen emissive class.
	var interior := root.get_node(^"Interior") as Node3D
	check(not interior.visible, "%s: Interior hidden (cockpit view only)" % label)
	var cabin := root.get_node(^"Interior/Cabin") as MeshInstance3D
	eq(cabin.mesh.get_surface_count(), 1, "%s: the Cabin is one draw" % label)
	var cmat := cabin.mesh.surface_get_material(0) as ShaderMaterial
	check(cmat != null and cmat.shader == CarModularImport.INTERIOR_SHADER, "%s: cockpit.gdshader" % label)
	var ca := cabin.mesh.surface_get_arrays(0)
	var ccol: PackedColorArray = ca[Mesh.ARRAY_COLOR]
	var cuv2: PackedVector2Array = ca[Mesh.ARRAY_TEX_UV2]
	for n: StringName in [&"asphalt", &"steel_dark", &"roof_slate", &"cream"]:
		check(_any_color(ccol, _pal.color(n)), "%s: interior_%s" % [label, n])
	var screen := 0
	for k in ccol.size():
		if cuv2[k].x == ArtMaterials.SCREEN_EMISSIVE:
			screen += 1
			check(_same_color(ccol[k], ArtMaterials.SCREEN_COLOR), "%s: screen colour" % label)
	eq(screen, 6, "%s: the screen quad glows (vehicle-light class)" % label)
	var sw := root.get_node(^"Interior/SteeringWheel") as Node3D
	near(sw.basis.z.y, sin(ArtCalib.STEER_TILT_RAD), POS_TOL, "%s: steering wheel keeps its column tilt" % label)
	var gauges := root.get_node(^"Interior/Gauges") as MeshInstance3D
	var gmat := gauges.mesh.surface_get_material(0) as ShaderMaterial
	check(gmat != null and gmat.shader == CarModularImport.GAUGE_SHADER, "%s: gauges shader" % label)
	near(float(gmat.get_shader_parameter(&"aspect")), 2.6, 0.01, "%s: gauges aspect from the quad" % label)


func _any_color(cols: PackedColorArray, want: Color) -> bool:
	for c in cols:
		if _same_color(c, want):
			return true
	return false


func test_calibration_car_is_a_valid_car_with_five_draws() -> void:
	var def := load(CAR_DEF) as CarDef
	var m := CarModel.load_model(def.model_scene_path, def)
	_keep(m.root)
	eq(m.stubbed.size(), 0, "nothing stubbed at load")
	eq(m.missing_nodes().size(), 0, "complete")
	within_pct(m.body_aabb.size.z, def.length_m, 0.05, "Body length vs the CarDef")
	within_pct(m.body_aabb.size.x, def.width_m, 0.05, "Body width vs the CarDef")
	near(m.wheel_radius_m, ArtCalib.WHEEL_R, 0.005, "wheel radius from the tire mesh")
	check(m.has_authored_interior(), "brings an interior")
	check(not m.interior.visible, "interior hidden outside the cockpit")
	var v := CarVisual.new()
	_keep(v)
	v.add_child(m.root)
	v.bind(m, _tuning.vehicle)
	eq(m.wheel_draws.size(), 1, "the four wheels share one MultiMesh")
	le(m.draw_surface_count(), CarModel.MERGED_DRAW_SURFACES_MAX, "at most 5 draws, lights off")
	eq(m.draw_surface_count(), 5, "body 3 + lamps 1 + wheels 1")
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	inp.brake = 1.0
	v.tick(1.0 / 120.0, st, inp)
	eq(m.draw_surface_count(), 6, "braking adds the merged brake lights")
	inp.brake = 0.0
	v.tick(1.0 / 120.0, st, inp)
	eq(m.draw_surface_count(), 5, "and takes them away")
	m.set_interior_visible(true)
	eq(m.draw_surface_count(), 8, "the interior is 3 more draws (cockpit view only)")
	m.set_interior_visible(false)


func test_signals_blinkers_and_reverse() -> void:
	var def := load(CAR_DEF) as CarDef
	var m := CarModel.load_model(def.model_scene_path, def)
	var v := CarVisual.new()
	_keep(v)
	v.add_child(m.root)
	v.bind(m, _tuning.vehicle)
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	var fl := m.light[&"blinker_FL"] as Node3D
	var fr := m.light[&"blinker_FR"] as Node3D
	var rl := m.light[&"blinker_RL"] as Node3D
	check(not fl.visible and not fr.visible, "blinkers off by default")
	v.set_blinkers(true, false)
	check(fl.visible and rl.visible and not fr.visible, "left blinkers start lit")
	var tv := TrafficViewTuning.load_default()
	var lit_s := tv.blinker_duty_frac() / tv.blinker_hz
	var ticks := ceili(lit_s * 120.0) + 1
	for i in ticks:
		v.tick(1.0 / 120.0, st, inp)
	check(not fl.visible, "then flash off after the duty share of a cycle")
	v.set_blinkers(true, true)
	check(fl.visible and fr.visible, "hazards: both sides")
	v.set_blinkers(false, false)
	check(not fl.visible and not fr.visible, "off again")
	var rev := m.light[&"reverse"] as Node3D
	check(not rev.visible, "reverse lamp off")
	st.v = -1.0
	v.tick(1.0 / 120.0, st, inp)
	check(rev.visible, "reverse lamp while rolling backwards")
	st.v = 1.0
	v.tick(1.0 / 120.0, st, inp)
	check(not rev.visible, "off rolling forwards")


## §3.3: the colour comes from the material name, not from vertex colours (which a
## .glb may carry through the round trip, but the contract ignores).
func test_material_names_win_over_vertex_colours() -> void:
	var root := Node3D.new()
	root.name = "Car_Vc"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p: Vector3 in [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0)]:
		st.set_color(Color.MAGENTA)
		st.set_normal(Vector3.BACK)
		st.add_vertex(p)
	var mesh := st.commit()
	mesh.surface_set_material(0, ArtCalib.new(_pal).mat("trim_ink"))
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	root.add_child(body)
	var path := OUT_DIR + "/vertex_colours.glb"
	eq(ArtCalib.write_glb(root, path), OK, "written")
	root.free()
	var scene := ArtCalib.read_glb(path)
	var carried: Variant = (scene.find_child("Body", true, false) as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	print("      vertex COLOR through GLTFDocument: %s" % ("kept" if carried != null else "dropped"))
	var out := _keep(CarModularImport.convert(scene, {}, "Car_Vc", _pal)) as Node3D
	scene.free()
	var col: PackedColorArray = (out.get_node(^"Body") as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(_same_color(col[0], _pal.color(&"ink")), "COLOR = the name's colour (ink), not the vertex colour")


## Any modular car delivered under assets/cars/<id>/ (and the Blender agent's P0
## calib_box) imports with no problems and nothing stubbed; its LOD1 imports as a Body.
func test_delivered_modular_cars_import_cleanly() -> void:
	var checked := 0
	for dir in DirAccess.get_directories_at("res://assets/cars"):
		if dir == "placeholder" or dir == "rims":
			continue
		for f in DirAccess.get_files_at("res://assets/cars".path_join(dir)):
			if f.get_extension() != "glb":
				continue
			var path := "res://assets/cars".path_join(dir).path_join(f)
			var scene := load(path) as PackedScene
			if not check(scene != null, "%s imports" % path):
				continue
			var root := _keep(scene.instantiate())
			eq(root.get_meta(&"car_import_problems", PackedStringArray()), PackedStringArray(), "%s: no problems" % path)
			if not f.get_basename().ends_with(CarModel.LOD1_SUFFIX):
				check(bool(root.get_meta(&"car_import_modular", false)), "%s took the modular path" % path)
				eq(root.get_meta(&"car_import_stubbed", PackedStringArray()), PackedStringArray(), "%s: nothing stubbed" % path)
			checked += 1
	print("      delivered modular car files: %d" % checked)


func test_placeholders_keep_their_import_path() -> void:
	# The roster cars are modular now; their old placeholder files keep the old path.
	for id: String in ["falcon_gt", "night_viper", "brute_v8"]:
		var scene := load("res://assets/cars/placeholder/%s.glb" % id) as PackedScene
		var root := _keep(scene.instantiate())
		check(not root.has_meta(&"car_import_modular"), "%s: placeholder bake, not the modular path" % id)
		check(root.get_node_or_null(^"Interior") == null, "%s: no interior" % id)


# ---------------------------------------------------------------- G5 rims

func test_authored_rim_swaps_in_scaled() -> void:
	var style := RimStyle.new()
	style.id = &"calib"
	style.radius_frac = 0.66
	style.mesh_path = RIM_GLB
	var unit := CarModel.load_rim_mesh(RIM_GLB)
	check(unit != null, "the rim file loads (imported by car_import.gd's rim path)")
	le(CarModel.triangle_count(unit), _tuning.progression.rim_tris, "rim within its budget")
	near(unit.get_aabb().size.y * 0.5, 1.0, 0.01, "authored at radius 1.0")
	for path: String in [CAR_DEF, "res://data/cars/falcon_gt.tres"]:
		var def := load(path) as CarDef
		var m := CarModel.load_model(def.model_scene_path, def)
		_keep(m.root)
		check(m.apply_rim(style), "%s: swapped" % def.id)
		var r0 := (m.rims[0] as MeshInstance3D).mesh
		for r in m.rims:
			eq((r as MeshInstance3D).mesh, r0, "%s: one rim mesh for the four wheels" % def.id)
		near(r0.get_aabb().size.y * 0.5, m.wheel_radius_m * style.radius_frac, 0.005, "%s: scaled to the wheel" % def.id)
		var tw := (m.tires[0] as MeshInstance3D).mesh.get_aabb().size.x
		gt(r0.get_aabb().end.x, tw * 0.5, "%s: the face sits outside the tire" % def.id)
		m.merge_draw_surfaces()
		eq(m.wheel_draws.size(), 1, "%s: still one wheel draw" % def.id)
	var missing := RimStyle.new()
	missing.mesh_path = "res://nowhere/rim.glb"
	missing.spokes = 6
	var m2 := CarModel.load_model((load(CAR_DEF) as CarDef).model_scene_path, load(CAR_DEF) as CarDef)
	_keep(m2.root)
	check(m2.apply_rim(missing), "a missing file falls back to the procedural rim")


# ---------------------------------------------------------------- G3 traffic

func _convert_traffic(path: String) -> ArtConvert.Result:
	var probs := PackedStringArray()
	var side := ArtConvert.load_sidecar(TRAFFIC_GLB, ".traffic.json", probs)
	eq(probs, PackedStringArray(), "sidecar parses")
	var scene := ArtCalib.read_glb(path)
	check(scene != null, "reads %s" % path)
	var r := ArtConvert.new(_pal).traffic(scene, side, path)
	scene.free()
	return r


func test_traffic_converter_writes_the_traffic_convention() -> void:
	var r := _convert_traffic(TRAFFIC_GLB)
	eq(r.problems, PackedStringArray(), "no problems")
	var mesh := r.mesh
	eq(mesh.get_surface_count(), 1, "one surface")
	var mat := mesh.surface_get_material(0) as ShaderMaterial
	eq(mat.shader.resource_path, "res://assets/shaders/traffic.gdshader", "traffic material")
	var t := load("res://data/vehicle_types/%s.tres" % ArtCalib.TRAFFIC_TYPE) as VehicleType
	eq(StringName(mesh.get_meta(&"vehicle_type")), t.id, "vehicle_type meta")
	var bb := mesh.get_aabb()
	within_pct(bb.size.z, t.length_m, 0.05, "length vs the type")
	near(bb.position.y, 0.0, 0.02, "on the ground")
	near(float(mesh.get_meta(&"wheel_radius_m")), ArtCalib.T_WHEEL_R, 1e-3, "wheel radius = hub height")
	var gf: Vector3 = mesh.get_meta(&"glow_front")
	var gr: Vector3 = mesh.get_meta(&"glow_rear")
	lt(gf.z, 0.0, "glow_front at the nose")
	gt(gr.z, 0.0, "glow_rear at the tail")
	near(gf.x, 0.6, POS_TOL, "glow_front half spacing")
	eq(int(mesh.get_meta(&"tris")), CarModel.triangle_count(mesh), "tris meta")
	eq(str(mesh.get_meta(ArtConvert.SOURCE_META)), TRAFFIC_GLB, "marked as converted")
	# Parts, colours, hubs.
	var a := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var c: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var uv2: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
	var seen := {}
	var bad_hub := 0
	for k in v.size():
		var part := roundi(uv[k].x)
		seen[part] = true
		if part == TrafficLights.PART_WHEEL:
			var hub := Vector2(ArtCalib.T_WHEEL_R, signf(v[k].z) * ArtCalib.T_AXLE_Z)
			if not uv2[k].is_equal_approx(hub):
				bad_hub += 1
		else:
			check(uv2[k] == Vector2.ZERO, "no hub on non-wheel parts")
		if part == TrafficLights.PART_HEAD:
			check(_same_color(c[k], _pal.color(&"cream")), "head_cream colour")
		elif part == TrafficLights.PART_BLINK_L:
			lt(v[k].x, 0.0, "blinkL on the left")
	eq(bad_hub, 0, "every wheel vertex carries its hub (y, z)")
	for p: int in [TrafficLights.PART_FIXED, TrafficLights.PART_PAINT, TrafficLights.PART_GLASS, TrafficLights.PART_WHEEL,
			TrafficLights.PART_HEAD, TrafficLights.PART_REAR, TrafficLights.PART_BRAKE, TrafficLights.PART_BLINK_L,
			TrafficLights.PART_BLINK_R]:
		check(seen.has(p), "part %d present" % p)
	# LOD1.
	var lod := _convert_traffic(TRAFFIC_LOD1_GLB)
	eq(lod.problems, PackedStringArray(), "LOD1 converts")
	lt(CarModel.triangle_count(lod.mesh), CarModel.triangle_count(mesh), "LOD1 is lighter")
	le(CarModel.triangle_count(lod.mesh), _tuning.progression.traffic_tris_lod1, "LOD1 budget")


func test_converted_traffic_saves_loads_and_retires_its_recipe() -> void:
	var r := _convert_traffic(TRAFFIC_GLB)
	var dir := OUT_DIR + "/traffic"
	eq(ArtConvert.save_traffic(r.mesh, "calib_traffic", dir), OK, "saves .res + .tscn")
	var mesh := TrafficView.load_model_mesh(dir + "/calib_traffic.tscn")
	check(mesh != null, "TrafficView loads the wrapper scene")
	eq(TrafficView.mesh_triangles(mesh), CarModel.triangle_count(r.mesh), "same mesh")
	check(ArtConvert.is_converted(dir + "/calib_traffic.res"), "a converted model is kept by the recipes")
	check(not ArtConvert.is_converted("res://assets/traffic/sedan_a.res"), "the procedural models are not")
	check(not ArtConvert.is_converted(dir + "/nothing.res"), "a missing file is not")


func test_traffic_converter_reports_broken_conventions() -> void:
	var scene := ArtCalib.new(_pal).build_traffic()
	_keep(scene)
	var body := scene.get_node(^"Body") as MeshInstance3D
	var mat := body.mesh.surface_get_material(0).duplicate() as Material
	mat.resource_name = "paint.001"
	body.mesh = body.mesh.duplicate() as Mesh
	body.mesh.surface_set_material(0, mat)
	scene.get_node(^"glow_rear").free()
	var r := ArtConvert.new(_pal).traffic(scene, {"vehicle_type": "sedan"})
	var all := ", ".join(r.problems)
	check(all.contains("paint.001"), "a Blender duplicate suffix is reported (%s)" % all)
	check(all.contains("glow_rear"), "a missing glow Empty is reported")
	var r2 := ArtConvert.new(_pal).traffic(scene, {"vehicle_type": "semi"})
	check(", ".join(r2.problems).contains("length"), "a size that does not fit the type is reported")


# ---------------------------------------------------------------- G2 props

func _convert_swatch() -> ArtConvert.Result:
	var probs := PackedStringArray()
	var side := ArtConvert.load_sidecar(SWATCH_GLB, ".prop.json", probs)
	var scene := ArtCalib.read_glb(SWATCH_GLB)
	var r := ArtConvert.new(_pal).prop(scene, side, SWATCH_GLB)
	scene.free()
	return r


func test_prop_converter_colours_and_emissive_classes() -> void:
	var r := _convert_swatch()
	eq(r.problems, PackedStringArray(), "no problems")
	var mesh := r.mesh
	eq(mesh.get_surface_count(), 1, "one surface")
	eq((mesh.surface_get_material(0) as ShaderMaterial).resource_path, ArtConvert.WINDOWS_MATERIAL,
		"world_windows (it has __window faces)")
	eq(float(mesh.get_meta(&"length_m")), 10.0, "sidecar meta")
	var a := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var c: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var uv2: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var names := ArtCalib.new(_pal).swatch_prop_names()
	var wrong := PackedStringArray()
	for i in names.size():
		var center := ArtCalib.swatch_quad_center(i)
		var pm := ArtMaterials.new(_pal).prop(names[i])
		var hits := 0
		for k in v.size():
			var d := v[k] - center
			if absf(d.x) <= 0.5 + POS_TOL and absf(d.y) <= 0.5 + POS_TOL:
				hits += 1
				if not _same_color(c[k], pm.color) or roundi(uv2[k].x) != pm.emissive:
					wrong.append(names[i])
					break
				gt(n[k].dot(Vector3.BACK), 0.999, "faces +Z (approaching traffic)")
		if hits == 0:
			wrong.append("%s: no quad" % names[i])
	eq(wrong, PackedStringArray(), "every palette colour and emissive class exact")
	var rooms := {}
	for k in v.size():
		if roundi(uv2[k].x) == ArtMaterials.EMISSIVE_WINDOW:
			rooms[uv2[k].y] = true
			check(uv2[k].y == 0.0 or (uv2[k].y >= ArtConvert.WINDOW_LIT_MIN and uv2[k].y <= ArtConvert.WINDOW_LIT_MAX),
				"room brightness 0 or lit")
	le(rooms.size(), 1, "one window quad: one brightness across its two triangles")
	var again := _convert_swatch()
	eq(again.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2], uv2, "deterministic room brightness")


func test_prop_palette_follows_the_biome() -> void:
	var b := ArtCalib.new(_pal)
	var root := Node3D.new()
	_keep(root)
	var bb := ArtCalib.Builder.new(b)
	bb.quad("sand", Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0), Vector3.BACK)
	var mi := MeshInstance3D.new()
	mi.mesh = bb.commit()
	root.add_child(mi)
	var conv := ArtConvert.new(_pal)
	var desert := conv.prop(root, {"biome": "desert"}).mesh
	var coast := conv.prop(root, {"biome": "coast"}).mesh
	check(_same_color((desert.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray)[0], BiomeColors.COLORS[&"sand"]),
		"desert sand from BiomeColors")
	check(_same_color((coast.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray)[0],
		_pal.color(&"sand", ArtPalette.SET_COAST_CITY_VALLEY)), "coast sand from palette_biomes_4_6")


# ---------------------------------------------------------------- Names

func test_material_names() -> void:
	var m := ArtMaterials.new(_pal)
	near(m.car("paint_shade").color.r, 0.8, 1e-6, "paint_shade")
	eq(m.car("Trim_Ink").slot, CarModel.Slot.TRIM, "case-insensitive")
	eq(m.car("glass").slot, CarModel.Slot.GLASS, "glass")
	eq(m.car("signal_blinker").slot, CarModel.Slot.SIGNAL, "signal")
	eq(m.car("interior_screen").kind, ArtMaterials.CarKind.INTERIOR, "screen")
	eq(m.car("gauges").kind, ArtMaterials.CarKind.GAUGES, "gauges")
	ne(m.car("trim_nope").error, "", "unknown colour")
	ne(m.car("paint.001").error, "", "Blender duplicate suffix")
	ne(m.car("chrome").error, "", "unknown name")
	eq(m.traffic("blinkL_reflector_amber").part, TrafficLights.PART_BLINK_L, "blinkL")
	eq(m.traffic("blinkR_reflector_amber").part, TrafficLights.PART_BLINK_R, "blinkR")
	eq(m.traffic("glass_dark").part, TrafficLights.PART_FIXED, "glass_dark is a colour (fixed)")
	eq(m.traffic("glass_roof_slate").part, TrafficLights.PART_GLASS, "glass_ prefix")
	eq(m.traffic("wheel_ink").part, TrafficLights.PART_WHEEL, "wheel")
	near(m.traffic("paint_dark").color.r, 0.55, 1e-6, "traffic paint_dark")
	eq(m.prop("lamp_warm__lamp").emissive, 2, "street lamp class")
	eq(m.prop("white__reflector").emissive, 1, "reflector class")
	check(m.prop("glass__window").window, "window")
	ne(m.prop("white__glow").error, "", "unknown suffix")


# ---------------------------------------------------------------- G7 ids

func test_car_id_renames_move_unlocks_and_looks() -> void:
	var unlocks := {"car/slot_4": 7, "car/falcon_gt": 0, "paint/teal": 3}
	var garage := {"car": "slot_4", "looks": {"slot_4": {"paint": "teal"}}}
	var renames := {"slot_4": "kestrel_rs"}
	check(SaveMigrations.rename_car_ids(unlocks, garage, renames), "moved")
	eq(unlocks, {"car/kestrel_rs": 7, "car/falcon_gt": 0, "paint/teal": 3}, "unlock carried over")
	eq(garage["car"], "kestrel_rs", "selected car")
	eq(garage["looks"], {"kestrel_rs": {"paint": "teal"}}, "look carried over")
	check(not SaveMigrations.rename_car_ids(unlocks, garage, renames), "a no-op once done")
	var both := {"car/slot_5": 9, "car/coastliner": 4}
	SaveMigrations.rename_car_ids(both, {}, {"slot_5": "coastliner"})
	eq(both, {"car/coastliner": 4}, "keeps the earlier unlock when both exist")
	# Data-driven from the catalog.
	var cat := GarageCatalog.new()
	var s := GarageSlot.new()
	s.id = &"kestrel_rs"
	s.former_ids = PackedStringArray(["slot_4"])
	var other := GarageSlot.new()
	other.id = &"slot_5"
	other.former_ids = PackedStringArray(["kestrel_rs"])   # a current id: ignored
	cat.slots = [s, other]
	eq(cat.car_id_renames(), {"slot_4": "kestrel_rs"}, "renames from GarageSlot.former_ids")


func test_roster_catalog_renames_are_consistent() -> void:
	var cat := GarageCatalog.load_path(_tuning.progression.garage_catalog_path)
	var renames := cat.car_id_renames()
	for from: Variant in renames:
		check(cat.slot(StringName(str(from))) == null, "%s is no longer a slot id" % from)
		check(cat.slot(StringName(str(renames[from]))) != null, "%s is a slot" % renames[from])
