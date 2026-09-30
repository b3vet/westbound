class_name HudMesh
extends RefCounted
## All of a HUD widget's shapes (panel fill, neon edge, bars, icons) as one triangle
## array: one canvas command, so one draw call however many shapes (the canvas
## renderer never batches polygons, and each draw_polygon/draw_polyline is its own
## call). Spec: Performance budget (draw calls); Design system (faceted panels, 1.5 px
## neon edge). docs/HUD.md → Draw calls.
##
## Edges are antialiased by hand: a solid band plus a feather band on each side that
## fades to transparent (what draw_polyline(antialiased) does), so chamfers stay
## smooth on both renderers. Buffers grow to the widget's shape count once and are
## then reused; nothing is allocated while the shape count stays the same.

## Feather width of antialiased edges (canvas px; about one physical pixel on phones).
const FEATHER := 0.6   # lint: allow-number antialiasing feather
const MAX_LOOP := 16

var _pts := PackedVector2Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()
var _nv: int = 0
var _ni: int = 0
var _ring := PackedVector2Array()
var _nrm := PackedVector2Array()
var _tmp := PackedVector2Array()


func _init() -> void:
	_ring.resize(MAX_LOOP)
	_nrm.resize(MAX_LOOP)
	_tmp.resize(MAX_LOOP)


func begin() -> void:
	_nv = 0
	_ni = 0


func vertex_count() -> int:
	return _nv


## Draws everything added since begin() into `ci` as one triangle array.
func flush(ci: CanvasItem) -> void:
	if _ni == 0:
		return
	if _pts.size() != _nv:
		_pts.resize(_nv)
		_cols.resize(_nv)
	if _idx.size() != _ni:
		_idx.resize(_ni)
	RenderingServer.canvas_item_add_triangle_array(ci.get_canvas_item(), _idx, _pts, _cols)


func _v(p: Vector2, c: Color) -> int:
	if _nv >= _pts.size():
		_pts.resize(maxi(_nv + 1, _pts.size() * 2))
		_cols.resize(_pts.size())
	_pts[_nv] = p
	_cols[_nv] = c
	_nv += 1
	return _nv - 1


func _t(a: int, b: int, c: int) -> void:
	if _ni + 3 > _idx.size():
		_idx.resize(maxi(_ni + 3, _idx.size() * 2))
	_idx[_ni] = a
	_idx[_ni + 1] = b
	_idx[_ni + 2] = c
	_ni += 3


## A quad a-b-c-d (in order around it) with per-corner colors.
func quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	var i := _v(a, ca)
	_v(b, cb)
	_v(c, cc)
	_v(d, cd)
	_t(i, i + 1, i + 2)
	_t(i, i + 2, i + 3)


func rect(r: Rect2, c: Color) -> void:
	if c.a <= 0.0 or r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	quad(r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), c, c, c, c)


## A parallelogram leaning right by `lean` px at the top (speed-tilted bar segments).
func slant(r: Rect2, lean: float, c: Color) -> void:
	quad(Vector2(r.position.x + lean, r.position.y), Vector2(r.end.x + lean, r.position.y), r.end,
			Vector2(r.position.x, r.end.y), c, c, c, c)


## A convex polygon (first n points of `p`) as a fan.
func fan(p: PackedVector2Array, n: int, c: Color) -> void:
	if c.a <= 0.0 or n < 3:
		return
	var base := _nv
	for i in n:
		_v(p[i], c)
	for i in range(1, n - 1):
		_t(base, base + i, base + i + 1)


## A closed antialiased outline of the convex loop `p` (first n points), `width` wide.
func edge(p: PackedVector2Array, n: int, width: float, c: Color) -> void:
	if c.a <= 0.0 or n < 3 or n > MAX_LOOP:
		return
	var half := width * 0.5
	# Miter normals (outward for a clockwise loop in screen space).
	for i in n:
		var prev := p[(i + n - 1) % n]
		var next := p[(i + 1) % n]
		var d0 := (p[i] - prev).normalized()
		var d1 := (next - p[i]).normalized()
		var n0 := Vector2(d0.y, -d0.x)
		var n1 := Vector2(d1.y, -d1.x)
		var m := (n0 + n1).normalized()
		var k := m.dot(n1)
		_nrm[i] = m / maxf(k, MITER_MIN)
	var clear := Color(c, 0.0)
	for i in n:
		var j := (i + 1) % n
		var ai := p[i]
		var aj := p[j]
		var ni := _nrm[i]
		var nj := _nrm[j]
		# Outer feather, solid band, inner feather.
		quad(ai + ni * (half + FEATHER), aj + nj * (half + FEATHER), aj + nj * half, ai + ni * half,
				clear, clear, c, c)
		quad(ai + ni * half, aj + nj * half, aj - nj * half, ai - ni * half, c, c, c, c)
		quad(ai - ni * half, aj - nj * half, aj - nj * (half + FEATHER), ai - ni * (half + FEATHER),
				c, c, clear, clear)


## A straight antialiased line.
func line(a: Vector2, b: Vector2, width: float, c: Color) -> void:
	if c.a <= 0.0:
		return
	var d := (b - a).normalized()
	var nn := Vector2(-d.y, d.x)
	var half := width * 0.5
	var clear := Color(c, 0.0)
	quad(a + nn * (half + FEATHER), b + nn * (half + FEATHER), b + nn * half, a + nn * half, clear, clear, c, c)
	quad(a + nn * half, b + nn * half, b - nn * half, a - nn * half, c, c, c, c)
	quad(a - nn * half, b - nn * half, b - nn * (half + FEATHER), a - nn * (half + FEATHER), c, c, clear, clear)


## A faceted panel: chamfered fill and its neon edge.
func panel(r: Rect2, bevel: float, fill: Color, edge_color: Color, width: float) -> void:
	HudDraw.chamfer(r, bevel, _ring)
	fan(_ring, HudDraw.CHAMFER_POINTS, fill)
	edge(_ring, HudDraw.CHAMFER_POINTS, width, edge_color)


## A regular n-gon (flat top): fill and optional edge.
func ngon(c: Vector2, radius: float, n: int, fill: Color, edge_color: Color = Color.TRANSPARENT,
		width: float = 0.0, angle: float = 0.0) -> void:
	HudDraw.ngon(c, radius, n, _tmp, angle)
	fan(_tmp, n, fill)
	if width > 0.0:
		edge(_tmp, n, width, edge_color)


## Slanted bar segments across `r` (bottom-aligned), heights ramping from `ramp_min`
## to full; lit below `lit` (`hi` color from `hi_from`), `off` otherwise.
func segments(r: Rect2, count: int, gap: float, ramp_min: float, lean_frac: float, lit: int,
		lit_color: Color, hi_color: Color, hi_from: int, off: Color) -> void:
	var w := (r.size.x - gap * float(count - 1)) / float(count)
	var denom := float(maxi(1, count - 1))
	for i in count:
		var h := r.size.y * lerpf(ramp_min, 1.0, float(i) / denom)
		var x0 := r.position.x + float(i) * (w + gap)
		var c := off
		if i < lit:
			c = hi_color if i >= hi_from else lit_color
		slant(Rect2(x0, r.end.y - h, w, h), h * lean_frac, c)


const MITER_MIN := 0.25   # lint: allow-number miter limit (4x the half width)
