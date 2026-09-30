class_name GhostCar
extends Node3D
## The Daily Drive ghost's car: one translucent draw. Spec: Core loop → Modes at launch
## ("shown as a translucent ghost car"), Performance budget (draw calls; Materials:
## custom unlit / single-light vertex-lit shaders, no StandardMaterial3D). WP8.4;
## docs/DAILY.md → Ghost car.
##
##   ghost_car.use_car(car_def)                   # load time: the merged mesh (cached)
##   ghost_car.show_at(xform, brake, lamps)       # frame rate
##   ghost_car.hide_ghost()
##
## The car's model (CarModel, the modular convention) is merged into ONE surface: the body,
## the wheels (tires and rims, at rest) and the head, tail and brake lamps (their class in
## UV.x, their color in COLOR), drawn with ghost_car.gdshader. One MeshInstance3D, made
## once and reused for every retry (pooled); the merged mesh is cached per car. Hidden,
## it draws nothing. No collisions, no scoring: it is only a view (DailyDrive places it).
## show_at / hide_ghost allocate nothing.

const MATERIAL := preload("res://src/world/ghost/ghost_car.tres")
const PARAM_BRAKE := &"brake_on"
const PARAM_LAMPS := &"lamps_on"
const CLASS_BODY := 0.0
const CLASS_LAMP := 1.0
const CLASS_BRAKE := 2.0
const LAMPS: Array[StringName] = [&"headlight_L", &"headlight_R", &"taillight_L", &"taillight_R"]
const BRAKES: Array[StringName] = [&"brake_L", &"brake_R"]
## Subtrees that are not part of the silhouette.
const SKIP: Array[StringName] = [&"Interior", &"Markers", &"Damage", &"CollisionBox"]

static var _mesh_cache: Dictionary[StringName, ArrayMesh] = {}

var mesh_instance: MeshInstance3D
var material: ShaderMaterial
## The car whose mesh is in use (&"" = none yet).
var car_id: StringName = &""

var _brake: bool = false
var _lamps: bool = false


func _init() -> void:
	name = "GhostCar"
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	material = MATERIAL.duplicate() as ShaderMaterial
	mesh_instance.material_override = material
	add_child(mesh_instance)
	visible = false


## The ghost wears `car_def`'s shape (merged once per car id and cached). Load time.
func use_car(car_def: CarDef) -> void:
	if car_def == null or car_def.id == car_id:
		return
	car_id = car_def.id
	if not _mesh_cache.has(car_id):
		_mesh_cache[car_id] = build_mesh(car_def)
	mesh_instance.mesh = _mesh_cache[car_id]


## Places the ghost (render space) and sets its lamps. Allocation-free.
func show_at(xform: Transform3D, brake: bool, lamps: bool) -> void:
	transform = xform
	if brake != _brake:
		_brake = brake
		material.set_shader_parameter(PARAM_BRAKE, 1.0 if brake else 0.0)
	if lamps != _lamps:
		_lamps = lamps
		material.set_shader_parameter(PARAM_LAMPS, 1.0 if lamps else 0.0)
	visible = mesh_instance.mesh != null


func hide_ghost() -> void:
	visible = false


## Draw calls it issues now (0 hidden, else its mesh's surfaces: 1).
func draw_count() -> int:
	if not is_visible_in_tree() or mesh_instance.mesh == null:
		return 0
	return mesh_instance.mesh.get_surface_count()


# ---------------------------------------------------------------- Mesh (load time)

## One surface of the car's silhouette: every mesh of the model in root space, the lamps
## tagged (UV.x = class, COLOR = the lamp's color).
static func build_mesh(car_def: CarDef) -> ArrayMesh:
	var model := CarModel.load_model(car_def.model_scene_path, car_def)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var parts: Array[MeshInstance3D] = []
	_collect(model.root, parts)
	for mi in parts:
		var cls := CLASS_BODY
		if LAMPS.has(mi.name):
			cls = CLASS_LAMP
		elif BRAKES.has(mi.name):
			cls = CLASS_BRAKE
		var xf := _xform_to(model.root, mi)
		for s in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			_append(mi.mesh.surface_get_arrays(s), xf, cls, verts, normals, colors, uvs, indices)
	model.root.free()
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Every MeshInstance3D under `n` with a mesh, minus the interior, markers, damage and
## collision subtrees and the switched signals (blinkers, reverse).
static func _collect(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if SKIP.has(c.name):
			continue
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			var parent_is_lights := c.get_parent() != null and c.get_parent().name == CarModel.LIGHTS
			if not parent_is_lights or LAMPS.has(mi.name) or BRAKES.has(mi.name):
				out.append(mi)
		_collect(c, out)


static func _xform_to(root: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		var n3 := cur as Node3D
		if n3 != null:
			xf = n3.transform * xf
		cur = cur.get_parent()
	return xf


static func _append(arrays: Array, xf: Transform3D, cls: float, verts: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray, uvs: PackedVector2Array,
		indices: PackedInt32Array) -> void:
	var base := verts.size()
	var src := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var nrm: Variant = arrays[Mesh.ARRAY_NORMAL]
	var col: Variant = arrays[Mesh.ARRAY_COLOR]
	for i in src.size():
		verts.append(xf * src[i])
		normals.append((xf.basis * (nrm as PackedVector3Array)[i]).normalized() if nrm != null else Vector3.UP)
		colors.append((col as PackedColorArray)[i] if col != null and cls != CLASS_BODY else Color.WHITE)
		uvs.append(Vector2(cls, 0.0))
	var idx: Variant = arrays[Mesh.ARRAY_INDEX]
	if idx != null:
		for i: int in idx as PackedInt32Array:
			indices.append(base + i)
	else:
		for i in src.size():
			indices.append(base + i)
