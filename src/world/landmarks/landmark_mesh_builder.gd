class_name LandmarkMeshBuilder
extends RefCounted
## Low-poly, flat-shaded landmark geometry in road space (WP5.3). Spec: World →
## "flat-shaded low-poly", Checkpoint landmarks; Art pipeline (palette, flat shading,
## no photo textures); Performance budget (one vertex-lit world shader, one draw call
## per build). Vertex conventions: docs/CONTRACTS.md §13, plus a text channel.
##
## Template frame (what landmark.gdshader bends along the road):
##   x = d (lateral, right-positive, from the reference line)
##   y = height above the road's reference line (vertical, never pitched)
##   z = -(s - checkpoint s): +z faces approaching traffic, -z is the way ahead
## Geometry that runs along s is split every `max_segment_m` so the bend follows the
## road's curve (the shader moves vertices, not edges).
##
## Channels: COLOR.rgb = palette sRGB (x a shade factor), UV2.x = emissive class
## (0 none, 1 reflector, 2 street lamp, 3 vehicle light), UV2.y = tint class (0),
## UV = text: (-1, -1) = no text; else (u 0..1 across the line strip,
## 2 * line + v with v 0..1 bottom to top). Front faces are clockwise (Godot); each
## primitive takes an outward hint and fixes its winding. Runtime-safe (no tools/).

const EMISSIVE_NONE := 0
const EMISSIVE_REFLECTOR := 1
const EMISSIVE_STREETLAMP := 2
const EMISSIVE_VEHICLE := 3
const NO_TEXT := Vector2(-1.0, -1.0)
## Up to this many text lines per build (landmark.gdshader line_rect[]).
const MAX_LINES := 4

var palette: WBPalette
var max_segment_m: float = 8.0

var _v := PackedVector3Array()
var _n := PackedVector3Array()
var _c := PackedColorArray()
var _uv := PackedVector2Array()
var _uv2 := PackedVector2Array()
## Width / height of each text line's strip (sets its atlas region's aspect).
var line_aspect := PackedFloat64Array()


func _init(p: WBPalette, segment_m: float) -> void:
	palette = p
	max_segment_m = segment_m


## Palette color by name, optionally darkened (tunnel interiors, shade sides).
func col(color_name: StringName, shade: float = 1.0) -> Color:
	var c := palette.color(color_name)
	return Color(c.r * shade, c.g * shade, c.b * shade)


func triangle_count() -> int:
	return int(_v.size() / 3.0)


func vertices() -> PackedVector3Array:
	return _v


# ---------------------------------------------------------------- Faces

## Convex polygon (fan). `outward` picks the front side. `uvs` (text) parallel to points.
func face(points: PackedVector3Array, outward: Vector3, color: Color, emissive: int = EMISSIVE_NONE,
		uvs: PackedVector2Array = PackedVector2Array()) -> void:
	var n := (points[2] - points[0]).cross(points[1] - points[0])
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	var flip := n.dot(outward) < 0.0
	if flip:
		n = -n
	var has_uv := uvs.size() == points.size()
	for i in range(1, points.size() - 1):
		var ids := [0, i, i + 1] if not flip else [0, i + 1, i]
		for k: int in ids:
			_v.append(points[k])
			_n.append(n)
			_c.append(color)
			_uv.append(uvs[k] if has_uv else NO_TEXT)
			_uv2.append(Vector2(float(emissive), 0.0))


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, color: Color,
		emissive: int = EMISSIVE_NONE) -> void:
	face(PackedVector3Array([a, b, c, d]), outward, color, emissive)


## Axis-aligned box from its min and max corners. `top` null = the side color.
func box(lo: Vector3, hi: Vector3, side: Color, top: Variant = null, bottom: bool = false,
		emissive: int = EMISSIVE_NONE) -> void:
	var t: Color = side if top == null else top
	var x0 := lo.x
	var y0 := lo.y
	var z0 := lo.z
	var x1 := hi.x
	var y1 := hi.y
	var z1 := hi.z
	quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.UP, t, emissive)
	quad(Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3.RIGHT, side, emissive)
	quad(Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x0, y0, z1), Vector3.LEFT, side, emissive)
	quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK, side, emissive)
	quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3.FORWARD, side, emissive)
	if bottom:
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3.DOWN, side, emissive)


## The body behind a sign face at `z_front` (facing +z when z_front > z_back): every
## side but the front, so nothing is coplanar with the face (no depth fighting).
func panel_back(x0: float, x1: float, y0: float, y1: float, z_front: float, z_back: float, color: Color) -> void:
	var f := signf(z_front - z_back)
	quad(Vector3(x0, y1, z_back), Vector3(x1, y1, z_back), Vector3(x1, y1, z_front), Vector3(x0, y1, z_front),
		Vector3.UP, color)
	quad(Vector3(x0, y0, z_back), Vector3(x1, y0, z_back), Vector3(x1, y0, z_front), Vector3(x0, y0, z_front),
		Vector3.DOWN, color)
	quad(Vector3(x0, y0, z_back), Vector3(x0, y1, z_back), Vector3(x0, y1, z_front), Vector3(x0, y0, z_front),
		Vector3.LEFT, color)
	quad(Vector3(x1, y0, z_back), Vector3(x1, y1, z_back), Vector3(x1, y1, z_front), Vector3(x1, y0, z_front),
		Vector3.RIGHT, color)
	quad(Vector3(x0, y0, z_back), Vector3(x1, y0, z_back), Vector3(x1, y1, z_back), Vector3(x0, y1, z_back),
		Vector3(0.0, 0.0, -f), color)


## A box whose z extent is split into segments of at most max_segment_m (long walls,
## slabs, girders that must follow the bend). Faces between segments are omitted.
func box_along(lo: Vector3, hi: Vector3, side: Color, top: Variant = null, bottom: bool = false,
		ends: bool = true, emissive: int = EMISSIVE_NONE) -> void:
	var t: Color = side if top == null else top
	var n := _segments(hi.z - lo.z)
	for i in n:
		var z0 := lerpf(lo.z, hi.z, float(i) / float(n))
		var z1 := lerpf(lo.z, hi.z, float(i + 1) / float(n))
		quad(Vector3(lo.x, hi.y, z0), Vector3(hi.x, hi.y, z0), Vector3(hi.x, hi.y, z1), Vector3(lo.x, hi.y, z1),
			Vector3.UP, t, emissive)
		quad(Vector3(hi.x, lo.y, z0), Vector3(hi.x, hi.y, z0), Vector3(hi.x, hi.y, z1), Vector3(hi.x, lo.y, z1),
			Vector3.RIGHT, side, emissive)
		quad(Vector3(lo.x, lo.y, z0), Vector3(lo.x, hi.y, z0), Vector3(lo.x, hi.y, z1), Vector3(lo.x, lo.y, z1),
			Vector3.LEFT, side, emissive)
		if bottom:
			quad(Vector3(lo.x, lo.y, z0), Vector3(hi.x, lo.y, z0), Vector3(hi.x, lo.y, z1), Vector3(lo.x, lo.y, z1),
				Vector3.DOWN, side, emissive)
	if ends:
		quad(Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
			Vector3.BACK, side, emissive)
		quad(Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
			Vector3.FORWARD, side, emissive)


## A strip whose cross-section is the polyline `profile` (x, y points) swept along z
## from z0 to z1 in bend segments; `outward` (x, y) of each profile edge's front side.
## Used for sloped hill faces and tapered shells.
func sweep(profile: PackedVector2Array, z0: float, z1: float, outward: PackedVector2Array, color: Color,
		emissive: int = EMISSIVE_NONE) -> void:
	var n := _segments(absf(z1 - z0))
	for i in n:
		var za := lerpf(z0, z1, float(i) / float(n))
		var zb := lerpf(z0, z1, float(i + 1) / float(n))
		for k in profile.size() - 1:
			var p := profile[k]
			var q := profile[k + 1]
			var o := outward[k]
			quad(Vector3(p.x, p.y, za), Vector3(q.x, q.y, za), Vector3(q.x, q.y, zb), Vector3(p.x, p.y, zb),
				Vector3(o.x, o.y, 0.0), color, emissive)


## A square-section beam from `a` to `b`, `w` wide (struts, cables, suspenders).
## Not split: callers split long runs themselves (see cable()).
func beam(a: Vector3, b: Vector3, w: float, color: Color, with_ends: bool = true) -> void:
	var axis := b - a
	var along := axis.normalized()
	var ref := Vector3.UP if absf(along.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := along.cross(ref).normalized() * (w * 0.5)
	var v := along.cross(u).normalized() * (w * 0.5)
	var ring := PackedVector3Array([u + v, u - v, -u - v, -u + v])
	for i in 4:
		var p := ring[i]
		var q := ring[(i + 1) % 4]
		quad(a + p, a + q, b + q, b + p, (p + q) * 0.5, color)
	if with_ends:
		face(PackedVector3Array([a + ring[0], a + ring[1], a + ring[2], a + ring[3]]), -along, color)
		face(PackedVector3Array([b + ring[0], b + ring[1], b + ring[2], b + ring[3]]), along, color)


## A beam through the points of a polyline (each piece <= max_segment_m along z).
func cable(points: PackedVector3Array, w: float, color: Color) -> void:
	for i in points.size() - 1:
		beam(points[i], points[i + 1], w, color, false)


## Upright n-gon frustum (piers, bollards): from `base` up `height`.
func prism(base: Vector3, r0: float, r1: float, height: float, sides: int, color: Color) -> void:
	var top_c := base + Vector3(0.0, height, 0.0)
	var lo := PackedVector3Array()
	var hi := PackedVector3Array()
	for i in sides:
		var a := TAU * (float(i) + 0.5) / float(sides)
		var dir := Vector3(cos(a), 0.0, sin(a))
		lo.append(base + dir * r0)
		hi.append(top_c + dir * r1)
	for i in sides:
		var j := (i + 1) % sides
		quad(lo[i], lo[j], hi[j], hi[i], (lo[i] + lo[j]) * 0.5 - base, color)
	face(hi, Vector3.UP, color)


# ---------------------------------------------------------------- Text

## A new text line whose strip is `width` x `height` metres; returns its index.
func add_line(width: float, height: float) -> int:
	assert(line_aspect.size() < MAX_LINES, "LandmarkMeshBuilder: too many text lines")
	line_aspect.append(width / height)
	return line_aspect.size() - 1


## A vertical text strip facing `facing_z` (+1 = approaching traffic, -1 = the other
## way) at depth z, spanning x0..x1 and y0..y1, showing `line` over `bg`.
## Several strips may show the same line (same text, same region).
func text_strip(x0: float, x1: float, y0: float, y1: float, z: float, facing_z: float, line: int, bg: Color,
		emissive: int = EMISSIVE_REFLECTOR) -> void:
	var v0 := float(line) * 2.0
	# Reading left to right as seen from the facing side.
	var left := x0 if facing_z > 0.0 else x1
	var right := x1 if facing_z > 0.0 else x0
	var pts := PackedVector3Array([Vector3(left, y0, z), Vector3(right, y0, z), Vector3(right, y1, z),
		Vector3(left, y1, z)])
	var uvs := PackedVector2Array([Vector2(0.0, v0), Vector2(1.0, v0), Vector2(1.0, v0 + 1.0),
		Vector2(0.0, v0 + 1.0)])
	face(pts, Vector3(0.0, 0.0, facing_z), bg, emissive, uvs)


## A flat vertical panel face without text (coplanar with text strips beside it).
func panel_face(x0: float, x1: float, y0: float, y1: float, z: float, facing_z: float, bg: Color,
		emissive: int = EMISSIVE_REFLECTOR) -> void:
	quad(Vector3(x0, y0, z), Vector3(x1, y0, z), Vector3(x1, y1, z), Vector3(x0, y1, z), Vector3(0.0, 0.0, facing_z),
		bg, emissive)


# ---------------------------------------------------------------- Output

## One-surface ArrayMesh (the caller sets the material on the instance).
func commit() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _v
	arrays[Mesh.ARRAY_NORMAL] = _n
	arrays[Mesh.ARRAY_COLOR] = _c
	arrays[Mesh.ARRAY_TEX_UV] = _uv
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _segments(length: float) -> int:
	return maxi(1, int(ceil(absf(length) / max_segment_m - 1e-6)))
