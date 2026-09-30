extends WBTest
## WP8.4: the Daily Drive ghost car (GhostCar): one merged surface, one draw, the custom
## ghost shader (no StandardMaterial3D), its lamps, nothing drawn while hidden. Spec: Core
## loop → Modes at launch ("a translucent ghost car"), Performance budget (draw calls,
## materials). docs/DAILY.md → Ghost car.

var _nodes: Array[Node] = []


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


func test_every_car_merges_into_one_surface() -> void:
	for path in Run.CAR_PATHS:
		var car := load(path) as CarDef
		var mesh := GhostCar.build_mesh(car)
		if not eq(mesh.get_surface_count(), 1, "%s: one surface, one draw" % car.id):
			continue
		var arrays := mesh.surface_get_arrays(0)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		gt(float(verts.size()), 100.0, "%s: the whole car" % car.id)
		var classes := {}
		for uv: Vector2 in arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array:
			classes[uv.x] = true
		check(classes.has(GhostCar.CLASS_BODY) and classes.has(GhostCar.CLASS_LAMP) and classes.has(GhostCar.CLASS_BRAKE),
			"%s: body, lamps and brake lamps tagged (%s)" % [car.id, str(classes.keys())])
		var box := mesh.get_aabb()
		near(box.size.z, car.length_m, car.length_m * 0.25, "%s: about the car's length" % car.id)


func test_one_draw_when_shown_none_when_hidden() -> void:
	var g := GhostCar.new()
	tree.root.add_child(g)
	_nodes.append(g)
	eq(g.draw_count(), 0, "hidden until placed")
	check(g.material is ShaderMaterial and not (g.mesh_instance.material_override is StandardMaterial3D),
		"the custom ghost shader")
	eq((g.material as ShaderMaterial).shader, GhostCar.MATERIAL.shader)
	g.show_at(Transform3D.IDENTITY, false, false)
	eq(g.draw_count(), 0, "no car chosen yet: nothing to draw")
	g.use_car(load(Run.CAR_PATHS[0]) as CarDef)
	var mesh := g.mesh_instance.mesh
	g.show_at(Transform3D(Basis.IDENTITY, Vector3(1, 0, -5)), true, false)
	eq(g.draw_count(), 1, "one draw")
	eq(g.mesh_instance.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no shadow")
	eq(float(g.material.get_shader_parameter(GhostCar.PARAM_BRAKE)), 1.0, "brake lamps on")
	eq(float(g.material.get_shader_parameter(GhostCar.PARAM_LAMPS)), 0.0, "headlamps off")
	g.show_at(Transform3D.IDENTITY, false, true)
	eq(float(g.material.get_shader_parameter(GhostCar.PARAM_BRAKE)), 0.0)
	eq(float(g.material.get_shader_parameter(GhostCar.PARAM_LAMPS)), 1.0)
	g.hide_ghost()
	eq(g.draw_count(), 0, "hidden: no draw")
	g.use_car(load(Run.CAR_PATHS[0]) as CarDef)
	check(g.mesh_instance.mesh == mesh, "the same car keeps its mesh (pooled, cached)")
	var other := GhostCar.new()
	_nodes.append(other)
	other.use_car(load(Run.CAR_PATHS[0]) as CarDef)
	check(other.mesh_instance.mesh == mesh, "the merged mesh is built once per car")
