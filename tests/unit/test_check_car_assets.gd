extends WBTest
## Car asset validation (spec: Cars → Art pipeline step 4, `tests/check_car_assets.gd`;
## named test_check_car_assets.gd so the runner discovers it). Every car in data/cars
## must load its model and, after CarModel's stubbing, have every convention node, fit
## the triangle budgets (ProgressionTuning), face -Z with Y up, and be plausibly sized
## (3.8-5.2 m long and matching its CarDef body). Only the vehicle shader is used.

const CARS_DIR := "res://data/cars"
## WP-ART-G: the modular calibration car (tools/art/make_calibration.gd), checked like a
## roster car but never in data/cars (tests only).
const CALIB_CAR := "res://tests/art/fixtures/calib_car/calib_car.tres"
## Plausible car length (spec: "wrong scale").
const LENGTH_MIN_M := 3.8
const LENGTH_MAX_M := 5.2
## The model's body must match the CarDef body dimensions this closely.
const DIMENSION_TOL_FRAC := 0.05
## Tires touch the ground (hub height = wheel radius) within this.
const GROUND_TOL_M := 0.02
## The axle center sits on the origin within this.
const AXLE_TOL_M := 0.05

var _tuning: Tuning
var _roots: Array[Node] = []


func before_all() -> void:
	_tuning = Tuning.load_default()


func after_each() -> void:
	for n in _roots:
		if is_instance_valid(n):
			n.free()
	_roots.clear()


func _car_defs() -> Array[CarDef]:
	var out: Array[CarDef] = []
	for f in DirAccess.get_files_at(CARS_DIR):
		if f.ends_with(".tres"):
			var c := load(CARS_DIR.path_join(f)) as CarDef
			if c != null:
				out.append(c)
	return out


## Every problem with a resolved model (empty = valid).
func _problems(m: CarModel, car: CarDef) -> PackedStringArray:
	var out := PackedStringArray()
	var pt := _tuning.progression
	for p in m.missing_nodes():
		out.append("missing node %s" % p)
	if not out.is_empty():
		return out
	# Budgets.
	if m.body_triangles() > pt.player_body_tris_lod0:
		out.append("body %d tris > %d" % [m.body_triangles(), pt.player_body_tris_lod0])
	for r in m.rims:
		var rim := r as MeshInstance3D
		if rim != null and CarModel.triangle_count(rim.mesh) > pt.rim_tris:
			out.append("rim %d tris > %d" % [CarModel.triangle_count(rim.mesh), pt.rim_tris])
	if m.interior != null:
		var tris := 0
		for mi in m.interior.find_children("*", "MeshInstance3D", true, false):
			tris += CarModel.triangle_count((mi as MeshInstance3D).mesh)
		if tris > pt.player_interior_tris:
			out.append("interior %d tris > %d" % [tris, pt.player_interior_tris])
	# Scale.
	var size := m.body_aabb.size
	if size.z < LENGTH_MIN_M or size.z > LENGTH_MAX_M:
		out.append("length %.2f m outside %.1f-%.1f" % [size.z, LENGTH_MIN_M, LENGTH_MAX_M])
	if car != null:
		if absf(size.z - car.length_m) > car.length_m * DIMENSION_TOL_FRAC:
			out.append("length %.2f m != CarDef %.2f" % [size.z, car.length_m])
		if absf(size.x - car.width_m) > car.width_m * DIMENSION_TOL_FRAC:
			out.append("width %.2f m != CarDef %.2f" % [size.x, car.width_m])
	if size.x >= size.z:
		out.append("wider than long: X/Z axes swapped?")
	if size.y >= size.z or m.body_aabb.position.y < -GROUND_TOL_M:
		out.append("not Y up on the ground (bounds %s)" % m.body_aabb)
	# Orientation: -Z forward, +X right, origin between the axles.
	var fl := m.wheels[0].position
	var fr := m.wheels[1].position
	var rl := m.wheels[2].position
	var rr := m.wheels[3].position
	if not (fl.z < 0.0 and fr.z < 0.0 and rl.z > 0.0 and rr.z > 0.0):
		out.append("front wheels not toward -Z")
	if not (fl.x < 0.0 and rl.x < 0.0 and fr.x > 0.0 and rr.x > 0.0):
		out.append("left wheels not toward -X")
	if absf((fl.z + rl.z) * 0.5) > AXLE_TOL_M or absf(fl.x + fr.x) > AXLE_TOL_M:
		out.append("origin not at the center between the axles")
	for w in m.wheels:
		if absf(w.position.y - m.wheel_radius_m) > GROUND_TOL_M:
			out.append("%s not on the ground" % w.name)
	var head := (m.light[&"headlight_L"] as Node3D).position
	var tail := (m.light[&"taillight_L"] as Node3D).position
	if not (head.z < tail.z and head.z < 0.0 and head.x < 0.0):
		out.append("headlights not at the front left/right")
	if m.marker(&"cam_hood").position.z >= 0.0 or m.marker(&"exhaust_L").position.z <= 0.0:
		out.append("markers not front/rear")
	# Materials: the project vehicle shader only (no PBR), with a paint slot; the Interior
	# uses the cockpit's interior and gauges shaders (G4, docs/ART_PRODUCTION.md §3.3.2).
	var has_paint := false
	for mi in m.root.find_children("*", "MeshInstance3D", true, false):
		var inst := mi as MeshInstance3D
		var in_interior := m.interior != null and m.interior.is_ancestor_of(inst)
		for i in inst.mesh.get_surface_count():
			var mat := inst.get_active_material(i) as ShaderMaterial
			if in_interior and mat != null and (mat.shader == Cockpit.INTERIOR_SHADER or mat.shader == Cockpit.GAUGE_SHADER):
				continue
			if mat == null or mat.shader != CarModel.VEHICLE_SHADER:
				out.append("%s surface %d not on the vehicle shader" % [inst.name, i])
			elif inst == m.body and int(mat.get_shader_parameter(&"slot")) == CarModel.Slot.PAINT:
				has_paint = true
	if not has_paint:
		out.append("no paint slot on the Body")
	# Collision box: the body inset by lives.collision_inset_m on each side.
	var inset := _tuning.lives.collision_inset_m
	if absf(m.collision_box.size.x - (size.x - inset * 2.0)) > 1e-3 \
			or absf(m.collision_box.size.z - (size.z - inset * 2.0)) > 1e-3:
		out.append("collision box %s is not the body inset by %s" % [m.collision_box, inset])
	return out


func test_every_car_model_passes() -> void:
	var cars := _car_defs()
	ge(cars.size(), 3, "the roster has the three placeholder cars")
	for car in cars:
		ne(car.model_scene_path, "", "%s has a model" % car.id)
		var m := CarModel.load_model(car.model_scene_path, car)
		_roots.append(m.root)
		ne(String(m.root.name), "Car_Stub", "%s model loaded (not the fallback stub)" % car.id)
		var problems := _problems(m, car)
		check(problems.is_empty(), "%s: %s" % [car.id, ", ".join(problems)])
		# The import script already conformed it: nothing left for runtime stubbing.
		eq(m.stubbed.size(), 0, "%s conformed at import (runtime stubbed %s)" % [car.id, m.stubbed])
		print("      %s: body %d tris, rim %d, wheel r %.3f m, bounds %s" % [car.id,
			m.body_triangles(), CarModel.triangle_count((m.rims[0] as MeshInstance3D).mesh),
			m.wheel_radius_m, m.body_aabb.size])


func test_calibration_car_passes() -> void:
	var car := load(CALIB_CAR) as CarDef
	var m := CarModel.load_model(car.model_scene_path, car)
	_roots.append(m.root)
	var problems := _problems(m, car)
	check(problems.is_empty(), "calib_car: %s" % ", ".join(problems))
	eq(m.stubbed.size(), 0, "nothing stubbed at runtime")
	eq(m.root.get_meta(&"car_import_stubbed", PackedStringArray(["?"])), PackedStringArray(),
		"the modular import stubbed nothing")
	eq(m.root.get_meta(&"car_import_problems", PackedStringArray(["?"])), PackedStringArray(),
		"the modular import found no problems")


## G8: a car's LOD1 (`<id>_lod1.glb`, when it has one) fits player_body_tris_lod1 and
## keeps the Body's slots.
func test_lod1_models_fit_their_budget() -> void:
	var cars := _car_defs()
	cars.append(load(CALIB_CAR) as CarDef)
	var found := 0
	for car in cars:
		var lod := CarModel.load_lod1_mesh(car)
		if lod == null:
			continue
		found += 1
		le(CarModel.triangle_count(lod), _tuning.progression.player_body_tris_lod1, "%s LOD1 budget" % car.id)
		for i in lod.get_surface_count():
			var mat := lod.surface_get_material(i) as ShaderMaterial
			check(mat != null and mat.shader == CarModel.VEHICLE_SHADER, "%s LOD1 on the vehicle shader" % car.id)
	ge(found, 1, "the calibration car has a LOD1")
	eq(CarModel.lod1_path("res://a/b.glb"), "res://a/b_lod1.glb", "LOD1 next to the model")


func test_bare_mesh_is_stubbed_to_the_convention() -> void:
	# A model that is only a mesh (no convention nodes) is completed at runtime.
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.name = "SomeMesh"
	var box := BoxMesh.new()
	box.size = Vector3(1.8, 1.2, 4.4)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	mesh.surface_set_material(0, CarModel.slot_material(CarModel.Slot.PAINT))
	mi.mesh = mesh
	mi.position = Vector3(0.0, 0.6, 0.0)
	root.add_child(mi)
	_roots.append(root)
	var m := CarModel.from_root(root)
	eq(m.missing_nodes().size(), 0, "all convention nodes after stubbing")
	gt(m.stubbed.size(), 20, "reports what it stubbed")
	eq(m.body, mi, "largest mesh adopted as Body")
	var p := _problems(m, null)
	check(p.is_empty(), ", ".join(p))


func test_missing_model_falls_back_to_a_stub() -> void:
	var car := load("res://data/cars/brute_v8.tres") as CarDef
	var m := CarModel.load_model("", car)
	_roots.append(m.root)
	eq(m.missing_nodes().size(), 0, "stub is complete")
	near(m.body_aabb.size.z, car.length_m, 1e-3, "stub sized from the CarDef")
	check(_problems(m, car).is_empty(), ", ".join(_problems(m, car)))


func test_the_check_catches_bad_models() -> void:
	var car := load("res://data/cars/falcon_gt.tres") as CarDef
	# Facing +Z: the whole model turned around.
	var m := CarModel.load_model(car.model_scene_path, car)
	_roots.append(m.root)
	for c in m.root.get_children():
		var n := c as Node3D
		if n != null:
			n.transform = Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * n.transform
	m._resolve(m.root)
	var p := _problems(m, car)
	check(", ".join(p).contains("-Z"), "a model facing +Z fails (%s)" % ", ".join(p))
	# Centimeters instead of meters.
	var m2 := CarModel.load_model(car.model_scene_path, car)
	_roots.append(m2.root)
	m2.body.scale = Vector3.ONE * 100.0
	m2._resolve(m2.root)
	check(", ".join(_problems(m2, car)).contains("length"), "a 100x model fails")
	# A missing node that stubbing cannot know about is reported.
	var m3 := CarModel.load_model(car.model_scene_path, car)
	_roots.append(m3.root)
	m3.root.get_node(^"Lights/brake_L").free()
	check(", ".join(_problems(m3, car)).contains("Lights/brake_L"), "a missing light fails")
