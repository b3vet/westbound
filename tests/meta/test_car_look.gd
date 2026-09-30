extends WBTest
## WP8.2: paint and rims on the modular car (CarModel.apply_rim / apply_paint, CarLook,
## PlayerCar.setup's look). Spec: Modular car convention ("Rim: swappable mesh (scaled to
## wheel radius)"; rim budget 800 triangles, shared); Car shader ("Paint color ... [is a]
## shader parameter, so recoloring costs nothing"); Performance budget (draw calls: a
## merged car stays within CarModel.MERGED_DRAW_SURFACES_MAX). docs/GARAGE.md.

var t: Tuning
var cat: GarageCatalog
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()
	cat = Garage.catalog()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _model(path: String) -> CarModel:
	var car := load(path) as CarDef
	var m := CarModel.load_model(car.model_scene_path, car)
	_nodes.append(m.root)
	return m


func test_every_rim_style_fits_every_car() -> void:
	for path in Run.CAR_PATHS:
		for r in cat.rims:
			var m := _model(path)
			var before: Array[Mesh] = []
			for rim in m.rims:
				before.append((rim as MeshInstance3D).mesh)
			var swapped := m.apply_rim(r)
			eq(swapped, not r.model_default, "%s %s" % [path.get_file(), r.id])
			var shared: Mesh = (m.rims[0] as MeshInstance3D).mesh
			for i in m.rims.size():
				var mi := m.rims[i] as MeshInstance3D
				if r.model_default:
					eq(mi.mesh, before[i], "stock keeps the model's own rim")
				else:
					eq(mi.mesh, shared, "one shared rim mesh for the four wheels")
					ne(mi.mesh, before[i])
			if not r.model_default:
				le(CarModel.triangle_count(shared), t.progression.rim_tris, "rim budget")
				var aabb := shared.get_aabb()
				near(maxf(aabb.size.y, aabb.size.z) * 0.5, m.wheel_radius_m * r.radius_frac, 1e-3, "scaled to the wheel radius")
			m.merge_draw_surfaces()
			le(m.draw_surface_count(), CarModel.MERGED_DRAW_SURFACES_MAX, "%s %s: the merged draw budget" % [path.get_file(), r.id])


func test_rims_must_come_before_the_merge() -> void:
	var m := _model(Run.CAR_PATHS[0])
	m.merge_draw_surfaces()
	var mesh := (m.rims[0] as MeshInstance3D).mesh
	check(not m.apply_rim(cat.rims[cat.rims.size() - 1]), "refused after the merge")
	eq((m.rims[0] as MeshInstance3D).mesh, mesh)
	check(not m.apply_rim(null), "null keeps the rims")


func test_car_look_equality() -> void:
	var car := load(Run.CAR_PATHS[0]) as CarDef
	check(CarLook.same(null, null, car))
	check(CarLook.same(null, CarLook.factory(car), car), "null is the factory look")
	check(CarLook.same(CarLook.make(car.default_paint, cat.rims[0]), null, car), "the stock rim is the factory rim")
	check(not CarLook.same(CarLook.make(Color.BLUE), null, car), "another paint")
	check(not CarLook.same(CarLook.make(car.default_paint, cat.rims[1]), null, car), "other rims")
	check(CarLook.same(CarLook.make(Color.BLUE, cat.rims[1]), CarLook.make(Color.BLUE, cat.rims[1]), car))


func test_player_car_wears_the_look() -> void:
	var car := load(Run.CAR_PATHS[1]) as CarDef
	var ctx := RunContext.new(1, RunContext.MODE_JOURNEY, t)
	var road := ProceduralRoadPath.new(ctx)
	var pc := (load("res://src/vehicle/player_car.tscn") as PackedScene).instantiate() as PlayerCar
	pc.self_tick = false
	tree.root.add_child(pc)
	_nodes.append(pc)
	var look := CarLook.make(cat.paints[4].color, cat.rims[2])
	pc.setup(ctx, road, null, car, null, look)
	eq(pc.look, look)
	var painted := false
	for i in pc.model.body.mesh.get_surface_count():
		var mat := pc.model.body.get_active_material(i) as ShaderMaterial
		if mat != null and int(mat.get_shader_parameter(&"slot")) == CarModel.Slot.PAINT:
			var c: Vector3 = mat.get_shader_parameter(&"paint_color")
			check(c.is_equal_approx(Vector3(look.paint.r, look.paint.g, look.paint.b)), "the paint slot wears it")
			painted = true
	check(painted, "a paint slot exists")
	check(pc.model.merged, "then merged as usual")
	le(pc.model.draw_surface_count(), CarModel.MERGED_DRAW_SURFACES_MAX)
	var pc2 := (load("res://src/vehicle/player_car.tscn") as PackedScene).instantiate() as PlayerCar
	pc2.self_tick = false
	tree.root.add_child(pc2)
	_nodes.append(pc2)
	pc2.setup(ctx, road, null, car, pc.params)
	check(CarLook.same(pc2.look, null, car), "no look: the factory look")
