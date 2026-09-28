@tool
extends EditorScenePostImport
## Car import wiring (spec: Cars → Art pipeline step 3, "Godot import script"; Modular
## car convention). Set as `import_script/path` on a car's .glb import.
##
## 1. Hints: an optional sidecar `<model>.car.json` next to the .glb (see
##    assets/cars/placeholder/*.car.json): root_name, forward_axis (+X/-X/+Z/-Z: which
##    source axis the nose points along), length_m (target body length), lift_frac
##    (body bottom above the ground, fraction of length), optional width_m and
##    height_m (fit the CarDef body; non-uniform scale), wheel_radius_frac,
##    wheel_track_frac, wheel_base_frac, wheel_offset_z_frac (see CarModel), and
##    flat_shading (default true).
## 2. Normalize: rotate the nose to -Z, scale to length_m, center the axles on the
##    origin and put the body on the ground; transforms are applied to the vertices.
## 3. Body and materials by slot name. Surfaces whose material is named paint, trim,
##    glass, lamp/light or signal get the project vehicle shader for that slot. Any
##    other material (e.g. the placeholders' AI-generated textures) is baked: the
##    base-color texture is sampled per face into vertex COLOR, and each face is
##    classified into paint (the dominant saturated hue; COLOR becomes a shade
##    multiplier so the paint can be recolored), glass (dark, above the belt line)
##    or trim. Faces are flat shaded. The textures are dropped.
## 4. Convention: CarModel.conform() stubs every missing node (wheels, lights,
##    markers) and builds the CollisionBox (body bounds inset by
##    lives.collision_inset_m).
## LOD1 is not generated: flat-shaded faces share no vertices, so the simplifier has
## nothing to merge, and the placeholder bodies (~5k tris) already fit the LOD1 budget.
## Real models bring their LOD1 from the Blender step (ART2).
##
## The same conform() runs at runtime (CarModel.load_model), so a model imported
## without this script still works; tests/unit/test_check_car_assets.gd validates.

const HINT_SUFFIX := ".car.json"
## Classification (placeholder bake). HSV on the sRGB face color.
const PAINT_MIN_SAT := 0.3
const PAINT_MIN_VAL := 0.2
const PAINT_HUE_TOL_DEG := 18.0
const HUE_BINS := 36
const GLASS_MAX_VAL := 0.4
const GLASS_MAX_SAT := 0.4
const GLASS_BELT_FRAC := 0.55
const GLASS_MIN_NORMAL_Y := -0.3
## Paint shade multiplier range (keeps baked panel detail without muddying the paint).
const PAINT_SHADE_MIN := 0.55


func _post_import(scene: Node) -> Object:
	var hints := _load_hints(get_source_file())
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(scene, meshes)
	var root := Node3D.new()
	root.name = String(hints.get("root_name", _root_name(get_source_file())))
	var body := _build_body(scene, meshes, hints)
	if body != null:
		root.add_child(body)
	var made := CarModel.conform(root, null, hints)
	_own(root, root)
	root.set_meta(&"car_import_stubbed", made)
	scene.free()
	return root


static func _load_hints(source: String) -> Dictionary:
	var path := source.get_basename() + HINT_SUFFIX
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	push_error("car_import: bad hints file %s" % path)
	return {}


static func _root_name(source: String) -> String:
	return "Car_" + source.get_file().get_basename().to_pascal_case()


static func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		out.append(mi)
	for c in n.get_children():
		_collect_meshes(c, out)


## Normalizes and bakes every mesh into one Body with one surface per slot.
func _build_body(scene: Node, meshes: Array[MeshInstance3D], hints: Dictionary) -> MeshInstance3D:
	if meshes.is_empty():
		return null
	var orient := _orientation(String(hints.get("forward_axis", "-Z")))
	# Bounds after orientation, to find the scale and the placement.
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for mi in meshes:
		var xf := orient * CarModel._xform_to(scene as Node3D, mi) if scene is Node3D \
			else orient * mi.transform
		for s in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				var p := xf * v
				lo = lo.min(p)
				hi = hi.max(p)
	var size := hi - lo
	var target_len := float(hints.get("length_m", size.z))
	var kz := target_len / size.z if size.z > 0.0 else 1.0
	# Width and height default to the uniform scale; given, they fit the CarDef body.
	var k := Vector3(kz, kz, kz)
	if hints.has("width_m") and size.x > 0.0:
		k.x = float(hints["width_m"]) / size.x
	if hints.has("height_m") and size.y > 0.0:
		k.y = float(hints["height_m"]) / size.y
	var lift := target_len * float(hints.get("lift_frac", 0.0))
	var offset_z := target_len * float(hints.get("wheel_offset_z_frac", 0.0))
	# Center x, ground y, and the axle center (body center shifted by -offset) on 0.
	var center := (lo + hi) * 0.5
	var place := Transform3D(Basis.from_scale(k), Vector3.ZERO) \
		.translated(Vector3(-center.x * k.x, -lo.y * k.y + lift, -center.z * k.z - offset_z))
	var flat := bool(hints.get("flat_shading", true))
	var body_h := size.y * k.y

	# Per slot: positions, normals, colors, uvs.
	var pos: Array[PackedVector3Array] = []
	var nor: Array[PackedVector3Array] = []
	var col: Array[PackedColorArray] = []
	var uvs: Array[PackedVector2Array] = []
	for i in CarModel.SLOT_NAMES.size():
		pos.append(PackedVector3Array())
		nor.append(PackedVector3Array())
		col.append(PackedColorArray())
		uvs.append(PackedVector2Array())

	var baked: Array[Dictionary] = []   # faces to classify: {p, n, uv, c}
	for mi in meshes:
		var xf := place * orient * CarModel._xform_to(scene as Node3D, mi) if scene is Node3D \
			else place * orient * mi.transform
		var nb := xf.basis.inverse().transposed()
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var mat := mi.get_active_material(s)
			var slot := _slot_by_name(mat)
			var verts := PackedVector3Array(arrays[Mesh.ARRAY_VERTEX])
			var norms := PackedVector3Array() if arrays[Mesh.ARRAY_NORMAL] == null \
				else PackedVector3Array(arrays[Mesh.ARRAY_NORMAL])
			var tex_uv := PackedVector2Array() if arrays[Mesh.ARRAY_TEX_UV] == null \
				else PackedVector2Array(arrays[Mesh.ARRAY_TEX_UV])
			var vcol := PackedColorArray() if arrays[Mesh.ARRAY_COLOR] == null \
				else PackedColorArray(arrays[Mesh.ARRAY_COLOR])
			var idx := PackedInt32Array() if arrays[Mesh.ARRAY_INDEX] == null \
				else PackedInt32Array(arrays[Mesh.ARRAY_INDEX])
			var img := _albedo_image(mat)
			var tint := _albedo_color(mat)
			var tri_count := (idx.size() if idx.size() > 0 else verts.size()) / 3
			for t in tri_count:
				var ia := idx[t * 3] if idx.size() > 0 else t * 3
				var ib := idx[t * 3 + 1] if idx.size() > 0 else t * 3 + 1
				var ic := idx[t * 3 + 2] if idx.size() > 0 else t * 3 + 2
				var p := PackedVector3Array([xf * verts[ia], xf * verts[ib], xf * verts[ic]])
				var n := PackedVector3Array()
				var geo := (p[2] - p[0]).cross(p[1] - p[0]).normalized()
				if norms.size() > 0:
					var avg := (nb * norms[ia] + nb * norms[ib] + nb * norms[ic]).normalized()
					if geo.dot(avg) < 0.0:
						geo = -geo
					if flat:
						n = PackedVector3Array([geo, geo, geo])
					else:
						n = PackedVector3Array([(nb * norms[ia]).normalized(),
							(nb * norms[ib]).normalized(), (nb * norms[ic]).normalized()])
				else:
					n = PackedVector3Array([geo, geo, geo])
				var uv := PackedVector2Array()
				if tex_uv.size() > 0:
					uv = PackedVector2Array([tex_uv[ia], tex_uv[ib], tex_uv[ic]])
				else:
					uv = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
				if slot >= 0:
					var c := PackedColorArray()
					for j in 3:
						var vc := vcol[[ia, ib, ic][j]] if vcol.size() > 0 else Color.WHITE
						c.append(vc * tint)
					_emit(pos, nor, col, uvs, slot, p, n, uv, c)
				else:
					baked.append({"p": p, "n": n, "uv": uv, "c": _face_color(img, tint, uv)})
	_classify_and_emit(baked, pos, nor, col, uvs, body_h)

	var im := ImporterMesh.new()
	for s in CarModel.SLOT_NAMES.size():
		if pos[s].is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pos[s]
		arr[Mesh.ARRAY_NORMAL] = nor[s]
		arr[Mesh.ARRAY_COLOR] = col[s]
		arr[Mesh.ARRAY_TEX_UV] = uvs[s]
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, CarModel.slot_material(s),
			String(CarModel.SLOT_NAMES[s]))
	var body := MeshInstance3D.new()
	body.name = CarModel.BODY
	body.mesh = im.get_mesh()
	return body


static func _orientation(axis: String) -> Transform3D:
	match axis.to_upper():
		"+X", "X":
			return Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO)
		"-X":
			return Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3.ZERO)
		"+Z", "Z":
			return Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	return Transform3D.IDENTITY


## Slot from the material name (paint, trim, glass, lamp/light, signal), or -1 to bake.
static func _slot_by_name(mat: Material) -> int:
	if mat == null:
		return -1
	var n := mat.resource_name.to_lower()
	if n.begins_with("paint"):
		return CarModel.Slot.PAINT
	if n.begins_with("trim"):
		return CarModel.Slot.TRIM
	if n.begins_with("glass"):
		return CarModel.Slot.GLASS
	if n.begins_with("lamp") or n.begins_with("light"):
		return CarModel.Slot.LAMP
	if n.begins_with("signal"):
		return CarModel.Slot.SIGNAL
	return -1


static func _albedo_image(mat: Material) -> Image:
	var bm := mat as BaseMaterial3D
	if bm == null or bm.albedo_texture == null:
		return null
	var img := bm.albedo_texture.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	return img


static func _albedo_color(mat: Material) -> Color:
	var bm := mat as BaseMaterial3D
	return bm.albedo_color if bm != null else Color.WHITE


## Average of the texture at the three corners and the centroid (sRGB).
static func _face_color(img: Image, tint: Color, uv: PackedVector2Array) -> Color:
	if img == null:
		return tint
	var sum := Color(0, 0, 0, 0)
	var cen := (uv[0] + uv[1] + uv[2]) / 3.0
	for q: Vector2 in [uv[0], uv[1], uv[2], cen, cen]:
		sum += _sample(img, q)
	return Color(sum.r / 5.0, sum.g / 5.0, sum.b / 5.0) * tint


static func _sample(img: Image, uv: Vector2) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var x := clampi(int(fposmod(uv.x, 1.0) * w), 0, w - 1)
	var y := clampi(int(fposmod(uv.y, 1.0) * h), 0, h - 1)
	return img.get_pixel(x, y)


static func _emit(pos: Array[PackedVector3Array], nor: Array[PackedVector3Array],
		col: Array[PackedColorArray], uvs: Array[PackedVector2Array], slot: int,
		p: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array, c: PackedColorArray) -> void:
	pos[slot].append_array(p)
	nor[slot].append_array(n)
	uvs[slot].append_array(uv)
	col[slot].append_array(c)


## Splits baked faces into paint / glass / trim. Paint is the dominant saturated hue
## (area-weighted); its COLOR becomes a grey shade multiplier relative to the mean
## paint luminance. Glass is dark, unsaturated and above the belt line.
static func _classify_and_emit(faces: Array[Dictionary], pos: Array[PackedVector3Array],
		nor: Array[PackedVector3Array], col: Array[PackedColorArray],
		uvs: Array[PackedVector2Array], body_h: float) -> void:
	if faces.is_empty():
		return
	var bins := PackedFloat64Array()
	bins.resize(HUE_BINS)
	var areas := PackedFloat64Array()
	for f in faces:
		var p: PackedVector3Array = f["p"]
		var area := (p[1] - p[0]).cross(p[2] - p[0]).length() * 0.5
		areas.append(area)
		var c: Color = f["c"]
		if c.s >= PAINT_MIN_SAT and c.v >= PAINT_MIN_VAL:
			bins[int(c.h * HUE_BINS) % HUE_BINS] += area
	var peak := 0
	for i in HUE_BINS:
		if bins[i] > bins[peak]:
			peak = i
	var paint_hue := (float(peak) + 0.5) / float(HUE_BINS)
	var has_paint := bins[peak] > 0.0
	var is_paint := PackedByteArray()
	is_paint.resize(faces.size())
	var lum_sum := 0.0
	var area_sum := 0.0
	for i in faces.size():
		var c: Color = faces[i]["c"]
		var dh := absf(c.h - paint_hue)
		dh = minf(dh, 1.0 - dh) * 360.0
		if has_paint and c.s >= PAINT_MIN_SAT and c.v >= PAINT_MIN_VAL and dh <= PAINT_HUE_TOL_DEG:
			is_paint[i] = 1
			lum_sum += c.srgb_to_linear().get_luminance() * areas[i]
			area_sum += areas[i]
	var ref_lum := lum_sum / area_sum if area_sum > 0.0 else 1.0
	for i in faces.size():
		var f: Dictionary = faces[i]
		var c: Color = f["c"]
		var p: PackedVector3Array = f["p"]
		var n: PackedVector3Array = f["n"]
		var slot := CarModel.Slot.TRIM
		var out := c
		if is_paint[i] == 1:
			slot = CarModel.Slot.PAINT
			var shade := clampf(c.srgb_to_linear().get_luminance() / ref_lum, PAINT_SHADE_MIN, 1.0)
			out = Color(shade, shade, shade)
		else:
			var cy := (p[0].y + p[1].y + p[2].y) / 3.0
			var ny := (n[0].y + n[1].y + n[2].y) / 3.0
			if c.v <= GLASS_MAX_VAL and c.s <= GLASS_MAX_SAT and cy >= body_h * GLASS_BELT_FRAC \
					and ny >= GLASS_MIN_NORMAL_Y:
				slot = CarModel.Slot.GLASS
		_emit(pos, nor, col, uvs, slot, p, n, f["uv"], PackedColorArray([out, out, out]))


## Sets the owner of every descendant so the importer saves them.
static func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_own(c, owner_node)
