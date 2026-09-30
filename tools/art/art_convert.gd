class_name ArtConvert
extends RefCounted
## G2 / G3: modelled .glb -> the one-surface mesh resources the game loads
## (docs/ART_PRODUCTION.md §3.3.3, §3.3.4, §3.7, §3.8, §3.11; CONTRACTS §13). The
## loaders (TrafficView, RoadsideProp / BiomeDef scatter, fences, fields) expect Mesh
## .res files, so the converter writes exactly what the procedural builders write
## (tools/traffic_models/, tools/props/): same vertex conventions, same materials, same
## mesh meta. A converted file therefore drops in with no loader change.
##
##   traffic  every mesh under the model root in one surface on traffic.tres:
##            COLOR = the name's sRGB (paint: its shade), UV.x = part, UV2 = the hub
##            (y, z) of wheel faces (their node's origin: each Wheel_* mesh is modelled
##            around its hub). Meta: glow_front / glow_rear (from the Empties),
##            wheel_radius_m (mean hub height), vehicle_type, tris, paint_palette
##            (sidecar), lod1_path (when <model>_lod1.glb exists), art_source.
##   prop     one surface on world.tres (world_windows.tres with __window faces):
##            COLOR = sRGB, UV2.x = emissive class, UV2.y = room brightness for window
##            faces (deterministic per face from the mesh name), meta from the sidecar
##            plus tris and art_source.
## Recipe retirement: a mesh with the `art_source` meta was converted from a .glb, and
## the procedural builders keep it (is_converted(); build_traffic_models.gd,
## build_props*.gd). Delete the .res (or the meta) to go back to the recipe.
## Tools and tests only; allocates.

const TRAFFIC_MATERIAL := "res://assets/shaders/materials/traffic.tres"
const WORLD_MATERIAL := "res://assets/shaders/materials/world.tres"
const WINDOWS_MATERIAL := "res://assets/shaders/materials/world_windows.tres"
## Mesh meta marking a converted mesh (the .glb it came from).
const SOURCE_META := &"art_source"
const LOD1_SUFFIX := "_lod1"
const GLOW_FRONT := "glow_front"
const GLOW_REAR := "glow_rear"
const WHEEL_PREFIX := "Wheel"
## The traffic wrapper scene (the path VehicleType.model_scene_paths lists), as
## tools/traffic_models/build_traffic_models.gd writes it.
const SCENE_TEMPLATE := """[gd_scene load_steps=2 format=3]

[ext_resource type="ArrayMesh" path="%s" id="1_mesh"]

[node name="%s" type="Node3D"]

[node name="Body" type="MeshInstance3D" parent="."]
mesh = ExtResource("1_mesh")
"""
## Lit-window rooms (tools/props/build_props_4_6.gd): a face is lit with this chance
## (sidecar `window_lit_chance` overrides), at a brightness in this range.
const WINDOW_LIT_CHANCE := 0.5
const WINDOW_LIT_MIN := 0.5
const WINDOW_LIT_MAX := 1.0
## Per-mesh prop budget (docs/ART_PRODUCTION.md §3.5; MESH_TRIANGLE_BUDGET in the roadside
## and biome tests). A sidecar `tris_budget` overrides it.
const PROP_TRIS_BUDGET := 400


## A conversion's output: the mesh (null when it failed) and what was wrong.
class Result extends RefCounted:
	var mesh: ArrayMesh
	var problems := PackedStringArray()
	var notes := PackedStringArray()


## Arrays being assembled (one surface).
class _Out extends RefCounted:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()

	func tris() -> int:
		@warning_ignore("integer_division")
		return v.size() / 3

	func commit(material_path: String) -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		arrays[Mesh.ARRAY_COLOR] = c
		if not uv.is_empty():
			arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, load(material_path))
		return mesh


var mats: ArtMaterials


func _init(palette: ArtPalette = null) -> void:
	mats = ArtMaterials.new(palette)


# ---------------------------------------------------------------- Files

## The sidecar next to a .glb (`<name><suffix>`), {} when absent; problems on bad JSON.
static func load_sidecar(glb_path: String, suffix: String, problems: PackedStringArray) -> Dictionary:
	var path := glb_path.get_basename() + suffix
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	problems.append("%s is not a JSON object" % path)
	return {}


## True when `res_path` holds a mesh converted from a .glb (the recipe must keep it).
static func is_converted(res_path: String) -> bool:
	if not ResourceLoader.exists(res_path):
		return false
	# Loaded directly (not through TrafficView, which needs the autoloads a --script run
	# does not have yet).
	var mesh := load(res_path) as Mesh
	return mesh != null and mesh.has_meta(SOURCE_META)


## Saves a traffic model: <out_dir>/<model>.res and the .tscn wrapper (text, so reruns
## are byte-identical). Returns OK or the first error.
static func save_traffic(mesh: ArrayMesh, model: String, out_dir: String) -> Error:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var mesh_path := out_dir.path_join(model + ".res")
	var err := ResourceSaver.save(mesh, mesh_path)
	if err != OK:
		return err
	var f := FileAccess.open(out_dir.path_join(model + ".tscn"), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(SCENE_TEMPLATE % [mesh_path, "Traffic_" + model])
	f.close()
	return OK


# ---------------------------------------------------------------- Shared

## The node whose direct child is `Body` (the Blender root Empty), else the scene.
static func model_root(scene: Node) -> Node:
	var found := CarModularImport.convention_root(scene)
	return found if found != null else scene


## Transform of `n` in `root`'s space.
static func xform_to(root: Node, n: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		var n3 := cur as Node3D
		if n3 != null:
			xf = n3.transform * xf
		cur = cur.get_parent()
	return xf


## Every mesh under `root` (depth first, in tree order).
static func meshes_under(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			out.append(mi)
	return out


## Calls `emit.call(p: PackedVector3Array, n: Vector3, material_name: String)` for every
## triangle of `mi` in root space, with a flat normal turned like the file's normals.
static func each_triangle(root: Node, mi: MeshInstance3D, emit: Callable) -> void:
	var xf := xform_to(root, mi)
	var nb := xf.basis.inverse().transposed()
	for s in mi.mesh.get_surface_count():
		if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var mat := mi.mesh.surface_get_material(s)
		if mat == null:
			mat = mi.get_active_material(s)
		var mname := mat.resource_name if mat != null else ""
		var arrays := mi.mesh.surface_get_arrays(s)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null \
			else PackedVector3Array()
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null \
			else PackedInt32Array()
		var count := idx.size() if not idx.is_empty() else verts.size()
		for t in range(0, count - count % 3, 3):
			var ia := idx[t] if not idx.is_empty() else t
			var ib := idx[t + 1] if not idx.is_empty() else t + 1
			var ic := idx[t + 2] if not idx.is_empty() else t + 2
			var p := PackedVector3Array([xf * verts[ia], xf * verts[ib], xf * verts[ic]])
			var geo := (p[2] - p[0]).cross(p[1] - p[0])
			if geo.length_squared() <= 0.0:
				continue
			geo = geo.normalized()
			if not norms.is_empty() and geo.dot(nb * (norms[ia] + norms[ib] + norms[ic])) < 0.0:
				geo = -geo
			emit.call(p, geo, mname)


# ---------------------------------------------------------------- Traffic (G3)

## Converts a traffic model scene. `sidecar`: {model, vehicle_type, paint_palette: [hex]}.
func traffic(scene: Node, sidecar: Dictionary, source: String = "") -> Result:
	var r := Result.new()
	var root := model_root(scene)
	var out := _Out.new()
	var hubs := PackedFloat64Array()
	for mi in meshes_under(root):
		var is_wheel := String(mi.name).begins_with(WHEEL_PREFIX)
		var hub := Vector2.ZERO
		if is_wheel:
			var o := xform_to(root, mi).origin
			hub = Vector2(o.y, o.z)
			hubs.append(o.y)
		var wheel_name := String(mi.name)
		each_triangle(root, mi, func(p: PackedVector3Array, nrm: Vector3, mname: String) -> void:
			var m := mats.traffic(mname)
			if not m.error.is_empty():
				_note(r.problems, m.error)
			var part := m.part
			if part == TrafficLights.PART_WHEEL and not is_wheel:
				_note(r.problems, "%s: wheel_ material outside a Wheel_* node (its hub is the node's origin)" % mname)
			elif is_wheel and part != TrafficLights.PART_WHEEL:
				_note(r.problems, "%s: %s uses %s (wheels take wheel_<colour> only)" % [wheel_name, mname, mname])
			for k in 3:
				out.v.append(p[k])
				out.n.append(nrm)
				out.c.append(m.color)
				out.uv.append(Vector2(float(part), 0.0))
				out.uv2.append(hub if part == TrafficLights.PART_WHEEL else Vector2.ZERO))
	if out.v.is_empty():
		r.problems.append("no geometry")
		return r
	var parts := PackedInt32Array()
	parts.resize(TrafficLights.PART_COUNT)
	for u in out.uv:
		parts[int(u.x)] += 1
	for req: Array in [[TrafficLights.PART_PAINT, "paint"], [TrafficLights.PART_WHEEL, "wheel_"],
			[TrafficLights.PART_HEAD, "head_"], [TrafficLights.PART_REAR, "rear_"],
			[TrafficLights.PART_BLINK_L, "blinkL_"], [TrafficLights.PART_BLINK_R, "blinkR_"]]:
		if parts[int(req[0])] == 0:
			r.problems.append("missing part %s (§3.7 required parts)" % req[1])
	var glow := {}
	for gname: String in [GLOW_FRONT, GLOW_REAR]:
		var g := root.find_child(gname, true, false) as Node3D
		if g == null:
			r.problems.append("missing Empty %s" % gname)
			continue
		var o := xform_to(root, g).origin
		glow[gname] = Vector3(absf(o.x), o.y, o.z)
	var mesh := out.commit(TRAFFIC_MATERIAL)
	var model := String(sidecar.get("model", source.get_file().get_basename()))
	mesh.resource_name = model
	if glow.has(GLOW_FRONT):
		mesh.set_meta(&"glow_front", glow[GLOW_FRONT])
	if glow.has(GLOW_REAR):
		mesh.set_meta(&"glow_rear", glow[GLOW_REAR])
	var radius := 0.0
	for h in hubs:
		radius += h
	if not hubs.is_empty():
		mesh.set_meta(&"wheel_radius_m", radius / float(hubs.size()))
	mesh.set_meta(&"vehicle_type", StringName(str(sidecar.get("vehicle_type", ""))))
	mesh.set_meta(&"tris", out.tris())
	var pal := PackedColorArray()
	var raw: Variant = sidecar.get("paint_palette", [])
	if raw is Array:
		for h: Variant in raw:
			if str(h).is_valid_html_color():
				pal.append(Color.html(str(h)))
			else:
				r.problems.append("paint_palette entry %s is not a #rrggbb colour" % h)
	if not pal.is_empty():
		mesh.set_meta(&"paint_palette", pal)
	mesh.set_meta(SOURCE_META, source)
	r.mesh = mesh
	_check_traffic_frame(mesh, sidecar, r)
	return r


## Size against the VehicleType, ground contact, lamps front and rear (§3.7; the same
## numbers as tests/unit/test_traffic_view.gd).
static func _check_traffic_frame(mesh: ArrayMesh, sidecar: Dictionary, r: Result) -> void:
	var bb := mesh.get_aabb()
	var type_id := str(sidecar.get("vehicle_type", ""))
	var type_path := "res://data/vehicle_types/%s.tres" % type_id
	if type_id.is_empty() or not ResourceLoader.exists(type_path):
		r.problems.append("vehicle_type %s: no data/vehicle_types/%s.tres" % [type_id, type_id])
		return
	var t := load(type_path) as VehicleType
	r.notes.append("%d tris, size %.2f x %.2f x %.2f (type %s %.2f x %.2f x %.2f)" % [
		CarModel.triangle_count(mesh), bb.size.x, bb.size.y, bb.size.z, t.id, t.width_m, t.height_m, t.length_m])
	if absf(bb.size.z - t.length_m) > t.length_m * 0.05:
		r.problems.append("length %.2f m vs the type's %.2f (+-5 %%)" % [bb.size.z, t.length_m])
	if bb.size.x < t.width_m * 0.95 or bb.size.x > t.width_m * 1.12:
		r.problems.append("width %.2f m vs the type's %.2f (-5 %% / +12 %%)" % [bb.size.x, t.width_m])
	if absf(bb.size.y - t.height_m) > t.height_m * 0.12:
		r.problems.append("height %.2f m vs the type's %.2f (+-12 %%)" % [bb.size.y, t.height_m])
	if absf(bb.position.y) > 0.02:
		r.problems.append("not on the ground (min y %.3f)" % bb.position.y)
	var front: Vector3 = mesh.get_meta(&"glow_front", Vector3.ZERO)
	var rear: Vector3 = mesh.get_meta(&"glow_rear", Vector3.ZERO)
	if front.z >= 0.0 or rear.z <= 0.0:
		r.problems.append("glow_front must be at -Z (the nose), glow_rear at +Z")


# ---------------------------------------------------------------- Props (G2)

## Converts a prop scene. `sidecar`: {mesh, material: world | world_windows, biome,
## meta: {...}, window_lit_chance}.
func prop(scene: Node, sidecar: Dictionary, source: String = "") -> Result:
	var r := Result.new()
	var root := model_root(scene)
	var biome := StringName(str(sidecar.get("biome", "")))
	var prefer := ArtPalette.prefer_set_for_biome(biome)
	var name_id := str(sidecar.get("mesh", source.get_file().get_basename()))
	var rng := Rng.new(name_id.hash())
	var lit_chance := float(sidecar.get("window_lit_chance", WINDOW_LIT_CHANCE))
	var out := _Out.new()
	var has_window := [false]
	# A window face keeps one brightness across its triangles (a quad's two halves).
	var last := {"n": Vector3.ZERO, "p": PackedVector3Array(), "lit": 0.0}
	for mi in meshes_under(root):
		each_triangle(root, mi, func(p: PackedVector3Array, nrm: Vector3, mname: String) -> void:
			var m := mats.prop(mname, prefer)
			if not m.error.is_empty():
				_note(r.problems, m.error)
			if m.emissive == ArtMaterials.EMISSIVE_WINDOW and not m.window:
				_note(r.problems, "%s: __flash is for set-piece kits, not props" % mname)
			var room := 0.0
			if m.window:
				has_window[0] = true
				if nrm.is_equal_approx(last["n"]) and _shares_edge(p, last["p"]):
					room = last["lit"]
				else:
					room = rng.float_range(WINDOW_LIT_MIN, WINDOW_LIT_MAX) if rng.chance(lit_chance) else 0.0
				last["n"] = nrm
				last["p"] = p
				last["lit"] = room
			for k in 3:
				out.v.append(p[k])
				out.n.append(nrm)
				out.c.append(m.color)
				out.uv2.append(Vector2(float(m.emissive), room)))
	if out.v.is_empty():
		r.problems.append("no geometry")
		return r
	var material := str(sidecar.get("material", "world_windows" if has_window[0] else "world"))
	if has_window[0] and material != "world_windows":
		r.problems.append("__window faces need \"material\": \"world_windows\"")
	var mesh := out.commit(WINDOWS_MATERIAL if material == "world_windows" else WORLD_MATERIAL)
	mesh.resource_name = name_id
	var meta: Variant = sidecar.get("meta", {})
	if meta is Dictionary:
		for k: Variant in meta:
			mesh.set_meta(StringName(str(k)), (meta as Dictionary)[k])
	mesh.set_meta(&"tris", out.tris())
	mesh.set_meta(SOURCE_META, source)
	# G10 preparation (§3.9): a kit part's text panels, Empties named text_<n>, as
	# {name: centre} in the part's frame (x = d, y = up, z = -s: LandmarkMeshBuilder's).
	var panels := {}
	for e in root.find_children("text_*", "Node3D", true, false):
		if not (e is MeshInstance3D):
			panels[String(e.name)] = xform_to(root, e).origin
	if not panels.is_empty():
		mesh.set_meta(&"text_panels", panels)
	var bb := mesh.get_aabb()
	r.notes.append("%d tris, size %.2f x %.2f x %.2f, %s" % [out.tris(), bb.size.x, bb.size.y, bb.size.z, material])
	r.mesh = mesh
	return r


static func _shares_edge(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if b.size() < 3:
		return false
	var shared := 0
	for p in a:
		for q in b:
			if p.is_equal_approx(q):
				shared += 1
	return shared >= 2


## Appends a problem once.
static func _note(problems: PackedStringArray, msg: String) -> void:
	if not problems.has(msg):
		problems.append(msg)
