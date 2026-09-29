class_name PropMeshBuilder
extends RefCounted
## Low-poly, flat-shaded prop meshes with palette vertex colors (review/asset
## tooling for WP1.4). Spec: World → "flat-shaded low-poly"; Art pipeline
## (palette of ~30 colors, flat shading, no photo textures); Performance budget
## (vertex-lit world shader). Vertex conventions: docs/CONTRACTS.md §13.
##
##   var b := PropMeshBuilder.new(WBPalette.load_default())
##   b.box(Vector3(0, 1, 0), Vector3(0.2, 2, 0.2), &"steel")
##   var mesh := b.commit()          # one surface, material = world.tres
##
## Every face gets its own vertices (flat normals). COLOR.rgb = palette sRGB,
## UV2.x = emissive class (0 none, 1 reflector, 2 street lamp), UV2.y = 0.
## Front faces are clockwise (Godot); each primitive takes an outward hint and
## fixes its winding, so callers never think about vertex order.
## `xform` transforms everything added after it is set (for rotated parts).

const EMISSIVE_NONE := 0
const EMISSIVE_REFLECTOR := 1
const EMISSIVE_STREETLAMP := 2
const WORLD_MATERIAL := "res://assets/shaders/materials/world.tres"

var palette: WBPalette
## Named sRGB colours not (yet) in the palette, e.g. a biome's (BiomeColors). Looked up
## after the palette.
var extra_colors: Dictionary = {}
var xform := Transform3D.IDENTITY

var _v := PackedVector3Array()
var _n := PackedVector3Array()
var _c := PackedColorArray()
var _uv2 := PackedVector2Array()


func _init(p: WBPalette) -> void:
	palette = p


## The named colour: the palette's, else `extra_colors`' (an unknown name is an
## authoring error: WBPalette.color reports it).
func color_of(color_name: StringName) -> Color:
	if not palette.has_color(color_name) and extra_colors.has(color_name):
		return extra_colors[color_name]
	return palette.color(color_name)


func triangle_count() -> int:
	return int(_v.size() / 3.0)


# ---------------------------------------------------------------- Faces

## Convex polygon (fan). `outward` picks the front side (any vector on that side).
func face(points: PackedVector3Array, outward: Vector3, color_name: StringName,
		emissive: int = EMISSIVE_NONE) -> void:
	var col := color_of(color_name)
	var pts := PackedVector3Array()
	for p in points:
		pts.append(xform * p)
	var out_w := (xform.basis * outward).normalized()
	var n := (pts[2] - pts[0]).cross(pts[1] - pts[0])
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	var flip := n.dot(out_w) < 0.0
	if flip:
		n = -n
	for i in range(1, pts.size() - 1):
		var a := pts[0]
		var b := pts[i]
		var c := pts[i + 1]
		if flip:
			var t := b
			b = c
			c = t
		for p: Vector3 in [a, b, c]:
			_v.append(p)
			_n.append(n)
			_c.append(col)
			_uv2.append(Vector2(float(emissive), 0.0))


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, color_name: StringName,
		emissive: int = EMISSIVE_NONE) -> void:
	face(PackedVector3Array([a, b, c, d]), outward, color_name, emissive)


## Axis-aligned box from its center and size. `top` / `bottom` default to the side
## color; set `with_bottom` for boxes that hang in the air.
func box(center: Vector3, size: Vector3, side: StringName, top: StringName = &"",
		with_bottom: bool = false, emissive: int = EMISSIVE_NONE) -> void:
	var h := size * 0.5
	var t := side if top == &"" else top
	var x0 := center.x - h.x
	var x1 := center.x + h.x
	var y0 := center.y - h.y
	var y1 := center.y + h.y
	var z0 := center.z - h.z
	var z1 := center.z + h.z
	quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.UP, t, emissive)
	quad(Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3.RIGHT, side, emissive)
	quad(Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x0, y0, z1), Vector3.LEFT, side, emissive)
	quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK, side, emissive)
	quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3.FORWARD, side, emissive)
	if with_bottom:
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3.DOWN, side, emissive)


## A square-section beam from `a` to `b` (struts, arms, rails, blades), `w` wide.
func beam(a: Vector3, b: Vector3, w: float, color_name: StringName, with_ends: bool = true) -> void:
	var axis := b - a
	var along := axis.normalized()
	var ref := Vector3.UP if absf(along.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := along.cross(ref).normalized() * (w * 0.5)
	var v := along.cross(u).normalized() * (w * 0.5)
	var ring := PackedVector3Array([u + v, u - v, -u - v, -u + v])
	for i in 4:
		var p := ring[i]
		var q := ring[(i + 1) % 4]
		var mid := (p + q) * 0.5
		quad(a + p, a + q, b + q, b + p, mid, color_name)
	if with_ends:
		face(PackedVector3Array([a + ring[0], a + ring[1], a + ring[2], a + ring[3]]), -along, color_name)
		face(PackedVector3Array([b + ring[0], b + ring[1], b + ring[2], b + ring[3]]), along, color_name)


## Upright n-gon frustum (cylinder when r0 == r1, cone when r1 == 0).
func prism(base: Vector3, r0: float, r1: float, height: float, sides: int, side: StringName,
		top: StringName = &"", with_bottom: bool = false, phase: float = 0.5) -> void:
	var t := side if top == &"" else top
	var top_c := base + Vector3(0.0, height, 0.0)
	var lo := PackedVector3Array()
	var hi := PackedVector3Array()
	for i in sides:
		var a := TAU * (float(i) + phase) / float(sides)
		var dir := Vector3(cos(a), 0.0, sin(a))
		lo.append(base + dir * r0)
		hi.append(top_c + dir * r1)
	for i in sides:
		var j := (i + 1) % sides
		var mid_dir := ((lo[i] + lo[j]) * 0.5 - base)
		if r1 > 0.0:
			quad(lo[i], lo[j], hi[j], hi[i], mid_dir, side)
		else:
			face(PackedVector3Array([lo[i], lo[j], top_c]), mid_dir, side)
	if r1 > 0.0:
		face(hi, Vector3.UP, t)
	if with_bottom:
		face(lo, Vector3.DOWN, side)


## Horizontal n-gon frustum along an axis (hubs, tanks lying down): from `a` to `b`.
func tube(a: Vector3, b: Vector3, r0: float, r1: float, sides: int, color_name: StringName,
		caps: bool = true) -> void:
	var along := (b - a).normalized()
	var ref := Vector3.UP if absf(along.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := along.cross(ref).normalized()
	var v := along.cross(u).normalized()
	var lo := PackedVector3Array()
	var hi := PackedVector3Array()
	for i in sides:
		var ang := TAU * (float(i) + 0.5) / float(sides)
		var dir := u * cos(ang) + v * sin(ang)
		lo.append(a + dir * r0)
		hi.append(b + dir * r1)
	for i in sides:
		var j := (i + 1) % sides
		quad(lo[i], lo[j], hi[j], hi[i], (lo[i] + lo[j]) * 0.5 - a, color_name)
	if caps:
		face(lo, -along, color_name)
		if r1 > 0.0:
			face(hi, along, color_name)


## Hemisphere-ish dome on top of an upright prism (silos, water tanks).
func dome(base: Vector3, radius: float, height: float, sides: int, rings: int, color_name: StringName,
		phase: float = 0.5) -> void:
	var y := 0.0
	var r := radius
	for k in rings:
		var f1 := float(k + 1) / float(rings)
		var y1 := height * sin(f1 * PI * 0.5)
		var r1 := radius * cos(f1 * PI * 0.5)
		if k == rings - 1:
			prism(base + Vector3(0.0, y, 0.0), r, 0.0, height - y, sides, color_name, &"", false, phase)
		else:
			prism_no_cap(base + Vector3(0.0, y, 0.0), r, r1, y1 - y, sides, color_name, phase)
		y = y1
		r = r1


func prism_no_cap(base: Vector3, r0: float, r1: float, height: float, sides: int, color_name: StringName,
		phase: float = 0.5) -> void:
	var top_c := base + Vector3(0.0, height, 0.0)
	for i in sides:
		var j := (i + 1) % sides
		var a := TAU * (float(i) + phase) / float(sides)
		var b := TAU * (float(j) + phase) / float(sides)
		var da := Vector3(cos(a), 0.0, sin(a))
		var db := Vector3(cos(b), 0.0, sin(b))
		quad(base + da * r0, base + db * r0, top_c + db * r1, top_c + da * r1, da + db, color_name)


## Flat n-gon disc (logos, reflectors) centered at `center`, facing `normal`.
func disc(center: Vector3, normal: Vector3, radius: float, sides: int, color_name: StringName,
		emissive: int = EMISSIVE_NONE) -> void:
	var n := normal.normalized()
	var ref := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := n.cross(ref).normalized()
	var v := n.cross(u).normalized()
	var pts := PackedVector3Array()
	for i in sides:
		var a := TAU * float(i) / float(sides)
		pts.append(center + (u * cos(a) + v * sin(a)) * radius)
	face(pts, n, color_name, emissive)


## Gable roof over a rectangle (ridge along z): eaves at `eave_y`, ridge at `ridge_y`.
func gable_roof(center_xz: Vector2, half_x: float, half_z: float, eave_y: float, ridge_y: float,
		roof: StringName, gable: StringName, overhang: float = 0.0) -> void:
	var x0 := center_xz.x - half_x - overhang
	var x1 := center_xz.x + half_x + overhang
	var z0 := center_xz.y - half_z - overhang
	var z1 := center_xz.y + half_z + overhang
	var xm := center_xz.x
	quad(Vector3(x0, eave_y, z0), Vector3(xm, ridge_y, z0), Vector3(xm, ridge_y, z1), Vector3(x0, eave_y, z1),
		Vector3(-1.0, 1.0, 0.0), roof)
	quad(Vector3(x1, eave_y, z0), Vector3(xm, ridge_y, z0), Vector3(xm, ridge_y, z1), Vector3(x1, eave_y, z1),
		Vector3(1.0, 1.0, 0.0), roof)
	var gx0 := center_xz.x - half_x
	var gx1 := center_xz.x + half_x
	var gz0 := center_xz.y - half_z
	var gz1 := center_xz.y + half_z
	face(PackedVector3Array([Vector3(gx0, eave_y, gz0), Vector3(xm, ridge_y, gz0), Vector3(gx1, eave_y, gz0)]),
		Vector3.FORWARD, gable)
	face(PackedVector3Array([Vector3(gx0, eave_y, gz1), Vector3(xm, ridge_y, gz1), Vector3(gx1, eave_y, gz1)]),
		Vector3.BACK, gable)


# ---------------------------------------------------------------- Output

## One-surface ArrayMesh using the shared world material. `meta` entries are
## stored as resource metadata (e.g. span_m, length_m) for the placement code.
func commit(meta: Dictionary = {}) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _v
	arrays[Mesh.ARRAY_NORMAL] = _n
	arrays[Mesh.ARRAY_COLOR] = _c
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, load(WORLD_MATERIAL))
	for k: String in meta:
		mesh.set_meta(StringName(k), meta[k])
	return mesh


func clear() -> void:
	_v = PackedVector3Array()
	_n = PackedVector3Array()
	_c = PackedColorArray()
	_uv2 = PackedVector2Array()
	xform = Transform3D.IDENTITY
