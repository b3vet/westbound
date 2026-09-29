class_name SetPieceMeshBuilder
extends RefCounted
## Flat-shaded low-poly geometry for set-piece props, built in road space and placed on
## the road (WP6.3). Spec: World → "flat-shaded low-poly"; Art pipeline (palette, flat
## shading); Performance budget (one vertex-lit shader, one draw call per piece).
## Vertex conventions: docs/CONTRACTS.md §13 (COLOR = palette sRGB, UV2.x = emissive
## class, UV2.y = tint class), plus UV = text (set_piece.gdshader: -1 = none, v in
## [0, 1] = a sign line, v in [2, 3] = a painted road legend) and emissive class 4 =
## flashing lamp.
##
## Every point is (s, d, h): the road at s (RoadPath.sample_into), d to the right,
## h up the road's surface normal, relative to a 64-bit anchor (the road at anchor_s),
## so the node goes at FloatingOrigin-local anchor and nothing loses precision far out.
## Faces take an outward hint and fix their winding (Godot: clockwise = front).
## Director rate (a piece's mesh is built once when it appears): allocates.

const NO_TEXT := Vector2(-1.0, -1.0)
const EMISSIVE_NONE := 0.0
const EMISSIVE_REFLECTOR := 1.0
const EMISSIVE_FLASH := 4.0
const TINT_NONE := 0.0
const TINT_ROAD := 1.0
const TINT_LINE := 2.0
## A painted legend's text v is offset by this (set_piece.gdshader).
const PAINT_V := 2.0

var road: RoadPath
var palette: WBPalette
var anchor_x: float = 0.0
var anchor_y: float = 0.0
var anchor_z: float = 0.0

var verts := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()
var uv2s := PackedVector2Array()

var _smp := RoadSample.new()


func _init(p: WBPalette) -> void:
	palette = p


## Starts a mesh anchored at the road at `anchor_s`.
func begin(on_road: RoadPath, anchor_s: float) -> void:
	road = on_road
	road.sample_into(anchor_s, _smp)
	anchor_x = _smp.pos_x
	anchor_y = _smp.pos_y
	anchor_z = _smp.pos_z
	verts.clear()
	normals.clear()
	colors.clear()
	uvs.clear()
	uv2s.clear()


func col(color_name: StringName) -> Color:
	return palette.color(color_name)


## The point (s, d, h) relative to the anchor.
func point(s: float, d: float, h: float) -> Vector3:
	road.sample_into(s, _smp)
	return _smp.local_point(d, anchor_x, anchor_y, anchor_z) + _smp.up * h


## The road's forward tangent and up at s (world directions).
func forward_at(s: float) -> Vector3:
	road.sample_into(s, _smp)
	return _smp.tangent


func up_at(s: float) -> Vector3:
	road.sample_into(s, _smp)
	return _smp.up


func right_at(s: float) -> Vector3:
	road.sample_into(s, _smp)
	return _smp.right


func triangle_count() -> int:
	return int(verts.size() / 3.0)


## One flat quad p0..p3 (a cyclic order), facing `outward`. Optional text UVs per corner.
func quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, outward: Vector3, c: Color,
		emissive: float = EMISSIVE_NONE, tint: float = TINT_NONE,
		t0: Vector2 = NO_TEXT, t1: Vector2 = NO_TEXT, t2: Vector2 = NO_TEXT, t3: Vector2 = NO_TEXT) -> void:
	var n := (p1 - p0).cross(p2 - p0)
	if n.length_squared() <= 0.0:
		n = (p2 - p0).cross(p3 - p0)
	var uv2 := Vector2(emissive, tint)
	if n.dot(outward) > 0.0:
		# Counter-clockwise seen from outside: emit reversed (Godot fronts are clockwise).
		_tri(p0, p3, p2, t0, t3, t2, n.normalized(), c, uv2)
		_tri(p0, p2, p1, t0, t2, t1, n.normalized(), c, uv2)
	else:
		_tri(p0, p1, p2, t0, t1, t2, -n.normalized(), c, uv2)
		_tri(p0, p2, p3, t0, t2, t3, -n.normalized(), c, uv2)


func _tri(a: Vector3, b: Vector3, c: Vector3, ta: Vector2, tb: Vector2, tc: Vector2, n: Vector3, color: Color,
		uv2: Vector2) -> void:
	verts.append(a)
	verts.append(b)
	verts.append(c)
	for k in 3:
		normals.append(n)
		colors.append(color)
		uv2s.append(uv2)
	uvs.append(ta)
	uvs.append(tb)
	uvs.append(tc)


## A box following the road: s0..s1 along, d0..d1 across, h0..h1 up; no bottom face.
## `front` colors the face toward approaching traffic (the s0 end), `top` the top.
func box(s0: float, s1: float, d0: float, d1: float, h0: float, h1: float, c: Color,
		emissive: float = EMISSIVE_NONE, front: Color = Color(-1, 0, 0), front_emissive: float = -1.0) -> void:
	var a0 := point(s0, d0, h0)
	var b0 := point(s0, d1, h0)
	var a1 := point(s0, d0, h1)
	var b1 := point(s0, d1, h1)
	var c0 := point(s1, d0, h0)
	var e0 := point(s1, d1, h0)
	var c1 := point(s1, d0, h1)
	var e1 := point(s1, d1, h1)
	var fwd := forward_at((s0 + s1) * 0.5)
	var up := up_at((s0 + s1) * 0.5)
	var rt := right_at((s0 + s1) * 0.5)
	var fc := c if front.r < 0.0 else front
	var fe := emissive if front_emissive < 0.0 else front_emissive
	quad(a0, b0, b1, a1, -fwd, fc, fe)
	quad(c0, e0, e1, c1, fwd, c, emissive)
	quad(a1, b1, e1, c1, up, c, emissive)
	quad(a0, c0, c1, a1, -rt, c, emissive)
	quad(b0, e0, e1, b1, rt, c, emissive)


## A flat strip on the road surface over [s0, s1] between d_in and d_out (possibly
## varying linearly), lifted `lift`, split every `seg` m.
func strip(s0: float, s1: float, d_in0: float, d_out0: float, d_in1: float, d_out1: float, lift: float,
		c: Color, tint: float, seg: float) -> void:
	var n := maxi(ceili((s1 - s0) / seg), 1)
	for k in n:
		var u0 := float(k) / float(n)
		var u1 := float(k + 1) / float(n)
		var sa := lerpf(s0, s1, u0)
		var sb := lerpf(s0, s1, u1)
		var p0 := point(sa, lerpf(d_in0, d_in1, u0), lift)
		var p1 := point(sa, lerpf(d_out0, d_out1, u0), lift)
		var p2 := point(sb, lerpf(d_out0, d_out1, u1), lift)
		var p3 := point(sb, lerpf(d_in0, d_in1, u1), lift)
		quad(p0, p1, p2, p3, up_at((sa + sb) * 0.5), c, EMISSIVE_NONE, tint)


## A vertical panel across the road at s (facing approaching traffic), d0..d1, h0..h1,
## with optional text (atlas rect r: u0, v0, du, dv) filling it.
func panel(s: float, d0: float, d1: float, h0: float, h1: float, c: Color, emissive: float,
		r: Vector4 = Vector4(-1, -1, 0, 0)) -> void:
	var p0 := point(s, d0, h0)
	var p1 := point(s, d1, h0)
	var p2 := point(s, d1, h1)
	var p3 := point(s, d0, h1)
	if r.x < 0.0:
		quad(p0, p1, p2, p3, -forward_at(s), c, emissive)
		return
	# Atlas v runs down the image: the panel's top is v0.
	quad(p0, p1, p2, p3, -forward_at(s), c, emissive, TINT_NONE,
		Vector2(r.x, r.y + r.w), Vector2(r.x + r.z, r.y + r.w), Vector2(r.x + r.z, r.y), Vector2(r.x, r.y))


## A painted word lying on the road: across d0..d1, along s0..s1 (read by an
## approaching driver: the text's top is at s1), paint color c.
func legend(s0: float, s1: float, d0: float, d1: float, lift: float, c: Color, r: Vector4) -> void:
	var p0 := point(s0, d0, lift)
	var p1 := point(s0, d1, lift)
	var p2 := point(s1, d1, lift)
	var p3 := point(s1, d0, lift)
	quad(p0, p1, p2, p3, up_at((s0 + s1) * 0.5), c, EMISSIVE_NONE, TINT_LINE,
		Vector2(r.x, r.y + r.w + PAINT_V), Vector2(r.x + r.z, r.y + r.w + PAINT_V), Vector2(r.x + r.z, r.y + PAINT_V),
		Vector2(r.x, r.y + PAINT_V))


## Writes the built geometry into `mesh` (one surface) with `material`.
func commit(mesh: ArrayMesh, material: Material) -> void:
	mesh.clear_surfaces()
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)


## The cone (for the cones' MultiMesh): a `sides`-sided frustum on a square base plate,
## orange with a retro-reflective white collar, in its own frame (y up, origin at the
## base centre).
static func cone_mesh(look: SetPieceLook, p: WBPalette, material: Material) -> ArrayMesh:
	var b := SetPieceMeshBuilder.new(p)
	var body := p.color(look.cone_color)
	var band := p.color(look.cone_band_color)
	var h := look.cone_height_m
	var r0 := look.cone_base_m * 0.5
	var r1 := look.cone_top_m * 0.5
	var lo := look.cone_band_lo_frac * h
	var hi := look.cone_band_hi_frac * h
	var n := maxi(look.cone_sides, 3)
	var cuts: Array[float] = [0.0, lo, hi, h]
	for k in n:
		var a0 := TAU * float(k) / float(n)
		var a1 := TAU * float(k + 1) / float(n)
		for j in 3:
			var ya := cuts[j]
			var yb := cuts[j + 1]
			var ra := lerpf(r0, r1, ya / h)
			var rb := lerpf(r0, r1, yb / h)
			var q0 := Vector3(cos(a0) * ra, ya, sin(a0) * ra)
			var q1 := Vector3(cos(a1) * ra, ya, sin(a1) * ra)
			var q2 := Vector3(cos(a1) * rb, yb, sin(a1) * rb)
			var q3 := Vector3(cos(a0) * rb, yb, sin(a0) * rb)
			var mid := (a0 + a1) * 0.5
			var out := Vector3(cos(mid), 0.0, sin(mid))
			var is_band := j == 1
			b.quad(q0, q1, q2, q3, out, band if is_band else body, EMISSIVE_REFLECTOR if is_band else EMISSIVE_NONE)
	# Base plate.
	var pw := r0 * 1.25
	var ph := h * 0.06
	for f in 4:
		var ang := TAU * float(f) / 4.0
		var out := Vector3(cos(ang), 0.0, sin(ang))
		var side := Vector3(-out.z, 0.0, out.x)
		var c0 := out * pw - side * pw
		var c1 := out * pw + side * pw
		b.quad(c0, c1, c1 + Vector3(0, ph, 0), c0 + Vector3(0, ph, 0), out, body)
	b.quad(Vector3(-pw, ph, -pw), Vector3(pw, ph, -pw), Vector3(pw, ph, pw), Vector3(-pw, ph, pw), Vector3.UP, body)
	var mesh := ArrayMesh.new()
	b.commit(mesh, material)
	return mesh
