class_name CarModularImport
extends RefCounted
## G1: the modular player-car import (docs/ART_PRODUCTION.md §3.6, §3.11; spec: Cars →
## Modular car convention, Art pipeline step 3). assets/cars/car_import.gd takes this path
## when the sidecar says "modular": true or the file has a `Body` node; the placeholder
## bake stays as it was. Also usable without the editor importer (tests, tools): feed it
## the scene GLTFDocument.generate_scene() returns.
##
## What it does, keeping the file's node tree:
##   - the convention root is the node whose child is `Body` (Blender's Car_<Name> Empty);
##     it becomes the new root, named root_name (sidecar) or Car_<PascalCase file name).
##   - every mesh is rebuilt by material NAME (ArtMaterials): one surface per slot (paint,
##     trim, glass, lamp, signal: the project's vehicle_*.tres), the interior material
##     (cockpit.gdshader) and the gauges material (cockpit_gauges.gdshader, aspect from
##     the quad). COLOR = the name's exact sRGB (paint: its shade 1 / 0.8 / 0.55). Flat
##     normals (one per face, facing like the file's). UV0 kept (livery, gauges).
##   - meshes shared in the file stay shared (the four Tire nodes, the four Rim nodes):
##     that is what lets CarModel draw the wheels as one MultiMesh.
##   - Tire_* / Rim_* under a Wheel_XX become Tire / Rim (Blender needs unique names).
##   - Markers/* become Marker3D; signal lights (brake_*, blinker_*, reverse) are hidden;
##     Interior and Damage are hidden (G4 shows the Interior in the cockpit view only).
##   - CarModel.conform() adds the CollisionBox and stubs anything missing.
## Root meta: car_import_modular = true, car_import_stubbed (what conform made besides the
## CollisionBox; should be empty), car_import_problems (names and conventions broken:
## unknown materials, a light in the wrong slot, wheels that don't share meshes, ...).
## Load/import time only; allocates.

const INTERIOR_SHADER := preload("res://src/camera/cockpit/cockpit.gdshader")
const GAUGE_SHADER := preload("res://src/camera/cockpit/cockpit_gauges.gdshader")
const MODULAR_KEY := "modular"
const SURFACE_INTERIOR := &"interior"
const SURFACE_GAUGES := &"gauges"
## Top-level nodes of the convention (anything else is reported).
const TOP_NODES: Array[StringName] = [CarModel.BODY, CarModel.LIGHTS, CarModel.INTERIOR, CarModel.MARKERS,
	CarModel.DAMAGE, &"Wheel_FL", &"Wheel_FR", &"Wheel_RL", &"Wheel_RR"]
## Lights shown only while switched on (CarVisual / CarModel.set_signal).
const SIGNAL_LIGHTS: Array[StringName] = [&"brake_L", &"brake_R", &"blinker_FL", &"blinker_FR",
	&"blinker_RL", &"blinker_RR", &"reverse"]
## Two meshes count as the same wheel geometry when their bounds agree this closely (m).
const SHARE_EPS_M := 1e-4


## Conversion state for one file.
class _Ctx extends RefCounted:
	var mats: ArtMaterials
	var flat := true
	## Source mesh instance id -> converted ArrayMesh (keeps linked duplicates shared).
	var meshes := {}
	## Content hash -> converted meshes: identical geometry is shared too (an exporter
	## that writes one glTF mesh per object, like Godot's own, still gives shared wheels).
	var by_content := {}
	var interior_material: ShaderMaterial
	var problems := PackedStringArray()


## One output surface being assembled.
class _Bucket extends RefCounted:
	var key: StringName
	var material: Material
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()


## True when `scene` should take the modular path.
static func is_modular(scene: Node, hints: Dictionary) -> bool:
	if hints.has(MODULAR_KEY):
		return bool(hints[MODULAR_KEY])
	return convention_root(scene) != null


## The node whose direct child is `Body` (breadth first), or null.
static func convention_root(scene: Node) -> Node:
	var queue: Array[Node] = [scene]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n.get_node_or_null(NodePath(CarModel.BODY)) != null:
			return n
		queue.append_array(n.get_children())
	return null


## Converts the imported `scene` (left untouched; the caller frees it) into a new
## convention root. `palette` may be shared between calls. `complete` = false (a LOD1
## file: one Body, G8) converts the tree without CarModel.conform().
static func convert(scene: Node, hints: Dictionary, root_name: String, palette: ArtPalette = null,
		complete: bool = true) -> Node3D:
	var ctx := _Ctx.new()
	ctx.mats = ArtMaterials.new(palette)
	ctx.flat = bool(hints.get("flat_shading", true))
	var root := Node3D.new()
	root.name = root_name
	var src := convention_root(scene)
	if src == null:
		ctx.problems.append("no Body node: not a modular car")
		src = scene
	var src3 := src as Node3D
	if src3 != null and src3 != scene and not src3.transform.is_equal_approx(Transform3D.IDENTITY):
		ctx.problems.append("root %s has a transform (apply it in Blender)" % src.name)
	for c in src.get_children():
		if not TOP_NODES.has(StringName(c.name)):
			ctx.problems.append("unexpected node %s under the root" % c.name)
		var copy := _copy(c, ctx, StringName(c.name), false)
		if copy != null:
			root.add_child(copy)
	_finish(root, ctx)
	var made := CarModel.conform(root, null, hints) if complete else PackedStringArray()
	var stubbed := PackedStringArray()
	for p in made:
		if p != String(CarModel.COLLISION_BOX):
			stubbed.append(p)
	root.set_meta(&"car_import_modular", true)
	root.set_meta(&"car_import_stubbed", stubbed)
	root.set_meta(&"car_import_problems", ctx.problems)
	return root


## A garage rim file (G5): the first mesh (a node named Rim* preferred) in trim, under a
## root named `root_name` as its child `Rim`.
static func convert_rim(scene: Node, root_name: String, palette: ArtPalette = null) -> Node3D:
	var ctx := _Ctx.new()
	ctx.mats = ArtMaterials.new(palette)
	var found: Array[Node] = scene.find_children("Rim*", "MeshInstance3D", true, false)
	if found.is_empty():
		found = scene.find_children("*", "MeshInstance3D", true, false)
	var root := Node3D.new()
	root.name = root_name
	if found.is_empty():
		ctx.problems.append("no mesh in the rim file")
	else:
		var src := found[0] as MeshInstance3D
		var mi := MeshInstance3D.new()
		mi.name = CarModel.RIM
		mi.mesh = _convert_mesh(src, ctx)
		root.add_child(mi)
		for s in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_name(s) != CarModel.SLOT_NAMES[CarModel.Slot.TRIM]:
				ctx.problems.append("rim surface %s is not trim" % mi.mesh.surface_get_name(s))
	root.set_meta(&"car_import_problems", ctx.problems)
	return root


# ---------------------------------------------------------------- Tree

static func _copy(n: Node, ctx: _Ctx, top: StringName, under_markers: bool) -> Node3D:
	var src3 := n as Node3D
	if src3 == null:
		return null
	var out: Node3D
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		var m := MeshInstance3D.new()
		m.mesh = _convert_mesh(mi, ctx)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		out = m
	elif under_markers:
		out = Marker3D.new()
	else:
		out = Node3D.new()
	out.name = _node_name(n)
	out.transform = src3.transform
	out.visible = true
	for c in n.get_children():
		var cc := _copy(c, ctx, top, top == CarModel.MARKERS)
		if cc != null:
			out.add_child(cc)
	return out


## Tire_FL -> Tire, Rim_FL -> Rim under a wheel pivot.
static func _node_name(n: Node) -> String:
	var s := String(n.name)
	var p := n.get_parent()
	if p != null and CarModel.WHEEL_NAMES.has(StringName(p.name)):
		for base: StringName in [CarModel.TIRE, CarModel.RIM]:
			if s.begins_with(String(base)):
				return String(base)
	return s


## Visibility, light slots, wheel sharing.
static func _finish(root: Node3D, ctx: _Ctx) -> void:
	for hidden: StringName in [CarModel.INTERIOR, CarModel.DAMAGE]:
		var h := root.get_node_or_null(NodePath(hidden)) as Node3D
		if h != null:
			h.visible = false
	var lights := root.get_node_or_null(NodePath(CarModel.LIGHTS))
	if lights != null:
		for l in lights.get_children():
			var mi := l as MeshInstance3D
			if mi == null:
				continue
			var want := CarModel.Slot.SIGNAL if SIGNAL_LIGHTS.has(StringName(l.name)) else CarModel.Slot.LAMP
			mi.visible = want != CarModel.Slot.SIGNAL
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				if mi.mesh.surface_get_name(s) != CarModel.SLOT_NAMES[want]:
					ctx.problems.append("light %s uses %s (only %s materials)" % [l.name,
						mi.mesh.surface_get_name(s), CarModel.SLOT_NAMES[want]])
	for part: StringName in [CarModel.TIRE, CarModel.RIM]:
		var first: Mesh = null
		for w: StringName in CarModel.WHEEL_NAMES:
			var mi := root.get_node_or_null(NodePath("%s/%s" % [w, part])) as MeshInstance3D
			if mi == null:
				continue
			if first == null:
				first = mi.mesh
			elif mi.mesh != first:
				ctx.problems.append("%s/%s does not share the %s mesh (Blender: linked duplicates, Alt+D)" % [w, part, part])
	var interior := root.get_node_or_null(NodePath(CarModel.INTERIOR))
	for mi: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		var inside := interior != null and interior.is_ancestor_of(mi)
		for s in mesh.get_surface_count():
			var sn: String = mesh.surface_get_name(s)
			if (sn == String(SURFACE_INTERIOR) or sn == String(SURFACE_GAUGES)) and not inside:
				ctx.problems.append("%s uses %s materials outside the Interior" % [mi.name, sn])


# ---------------------------------------------------------------- Meshes

static func _convert_mesh(mi: MeshInstance3D, ctx: _Ctx) -> ArrayMesh:
	var key := mi.mesh.get_instance_id()
	if ctx.meshes.has(key):
		return ctx.meshes[key]
	var buckets: Array[_Bucket] = []
	var src := mi.mesh
	for s in src.get_surface_count():
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			ctx.problems.append("%s surface %d is not triangles; skipped" % [mi.name, s])
			continue
		var mat := src.surface_get_material(s)
		if mat == null:
			mat = mi.get_active_material(s)
		var mname := mat.resource_name if mat != null else ""
		var cm := ctx.mats.car(mname)
		if not cm.error.is_empty():
			ctx.problems.append("%s: %s" % [mi.name, cm.error])
			cm.kind = ArtMaterials.CarKind.SLOT
			cm.slot = CarModel.Slot.TRIM
			cm.color = _albedo(mat)
		var b := _bucket_for(buckets, cm, ctx)
		_emit(b, src.surface_get_arrays(s), cm, ctx.flat)
	var out := ArrayMesh.new()
	for b in _ordered(buckets):
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = b.verts
		arrays[Mesh.ARRAY_NORMAL] = b.normals
		arrays[Mesh.ARRAY_COLOR] = b.colors
		arrays[Mesh.ARRAY_TEX_UV] = b.uvs
		arrays[Mesh.ARRAY_TEX_UV2] = b.uv2s
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var i := out.get_surface_count() - 1
		out.surface_set_name(i, b.key)
		if b.key == SURFACE_GAUGES:
			var gm := ShaderMaterial.new()
			gm.shader = GAUGE_SHADER
			gm.resource_name = String(SURFACE_GAUGES)
			gm.set_shader_parameter(&"aspect", _uv_aspect(b))
			out.surface_set_material(i, gm)
		else:
			out.surface_set_material(i, b.material)
	out = _dedup(out, ctx)
	ctx.meshes[key] = out
	return out


## `mesh`, or an already converted mesh with exactly the same surfaces and materials.
static func _dedup(mesh: ArrayMesh, ctx: _Ctx) -> ArrayMesh:
	var surfaces: Array = []
	for s in mesh.get_surface_count():
		surfaces.append([mesh.surface_get_name(s), mesh.surface_get_material(s), mesh.surface_get_arrays(s)])
	var h := hash(surfaces)
	var same: Array = ctx.by_content.get(h, [])
	for cand: ArrayMesh in same:
		if cand.get_surface_count() != mesh.get_surface_count():
			continue
		var equal := true
		for s in mesh.get_surface_count():
			var a: Array = surfaces[s]
			if cand.surface_get_name(s) != a[0] or cand.surface_get_material(s) != a[1] \
					or cand.surface_get_arrays(s) != a[2]:
				equal = false
				break
		if equal:
			return cand
	same.append(mesh)
	ctx.by_content[h] = same
	return mesh


static func _bucket_for(buckets: Array[_Bucket], cm: ArtMaterials.CarMat, ctx: _Ctx) -> _Bucket:
	var key: StringName
	var mat: Material = null
	match cm.kind:
		ArtMaterials.CarKind.INTERIOR:
			key = SURFACE_INTERIOR
			if ctx.interior_material == null:
				ctx.interior_material = ShaderMaterial.new()
				ctx.interior_material.shader = INTERIOR_SHADER
				ctx.interior_material.resource_name = String(SURFACE_INTERIOR)
			mat = ctx.interior_material
		ArtMaterials.CarKind.GAUGES:
			key = SURFACE_GAUGES
		_:
			key = CarModel.SLOT_NAMES[cm.slot]
			mat = CarModel.slot_material(cm.slot)
	for b in buckets:
		if b.key == key:
			return b
	var nb := _Bucket.new()
	nb.key = key
	nb.material = mat
	buckets.append(nb)
	return nb


## Slots in CarModel.Slot order, then the interior, then the gauges.
static func _ordered(buckets: Array[_Bucket]) -> Array[_Bucket]:
	var order: Array[StringName] = []
	order.append_array(CarModel.SLOT_NAMES)
	order.append(SURFACE_INTERIOR)
	order.append(SURFACE_GAUGES)
	var out: Array[_Bucket] = []
	for k in order:
		for b in buckets:
			if b.key == k:
				out.append(b)
	return out


## Appends one source surface, de-indexed, flat-shaded (a normal per face, turned to
## agree with the file's normals), COLOR from the name.
static func _emit(b: _Bucket, arrays: Array, cm: ArtMaterials.CarMat, flat: bool) -> void:
	var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null \
		else PackedVector3Array()
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null \
		else PackedVector2Array()
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null \
		else PackedInt32Array()
	var count := idx.size() if not idx.is_empty() else verts.size()
	var uv2 := Vector2(cm.emissive, 0.0)
	for t in range(0, count - count % 3, 3):
		var ia := idx[t] if not idx.is_empty() else t
		var ib := idx[t + 1] if not idx.is_empty() else t + 1
		var ic := idx[t + 2] if not idx.is_empty() else t + 2
		var pa := verts[ia]
		var pb := verts[ib]
		var pc := verts[ic]
		var geo := (pc - pa).cross(pb - pa)
		if geo.length_squared() <= 0.0:
			continue   # degenerate: drop (no normal to give it)
		geo = geo.normalized()
		if not norms.is_empty():
			var avg := norms[ia] + norms[ib] + norms[ic]
			if geo.dot(avg) < 0.0:
				geo = -geo
		for j: int in [ia, ib, ic]:
			b.verts.append(verts[j])
			b.normals.append(geo if flat or norms.is_empty() else norms[j].normalized())
			b.colors.append(cm.color)
			b.uvs.append(uv[j] if not uv.is_empty() else Vector2.ZERO)
			b.uv2s.append(uv2)


## Width / height of a quad along its UV axes (the gauges shader's `aspect`).
static func _uv_aspect(b: _Bucket) -> float:
	if b.verts.size() < 3:
		return 1.0
	var e1 := b.verts[1] - b.verts[0]
	var e2 := b.verts[2] - b.verts[0]
	var d1 := b.uvs[1] - b.uvs[0]
	var d2 := b.uvs[2] - b.uvs[0]
	var det := d1.x * d2.y - d2.x * d1.y
	if absf(det) <= 0.0:
		return 1.0
	var dp_du := (e1 * d2.y - e2 * d1.y) / det
	var dp_dv := (e2 * d1.x - e1 * d2.x) / det
	var h := dp_dv.length()
	return dp_du.length() / h if h > 0.0 else 1.0


static func _albedo(mat: Material) -> Color:
	var bm := mat as BaseMaterial3D
	return bm.albedo_color if bm != null else Color.MAGENTA
