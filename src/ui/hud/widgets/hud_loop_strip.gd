class_name HudLoopStrip
extends Control
## The loop strip: the whole loop as one thin bar along the top of the HUD, a dot for every
## player and a mark for each sector gantry. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## Players ("Loop strip: a thin bar along the top of the HUD shows the whole loop with a
## dot for every player and a mark for each sector gantry"); Client changes (In-room HUD
## additions). docs/ROOMS_CLIENT.md → Room HUD. WP N5.2.
##
## Positions are fractions of the loop (wrapped s / L, 0 = the start / finish line at the
## left end). Remote dots take their crew color, yours is the accent, larger, drawn last.
## One triangle array (one draw call); redraws only when a dot moves a whole pixel or
## changes color. Never takes touches.

const DOT_FACETS := 6
const ME_SCALE := 1.6   # lint: allow-number look

var style: HudStyle
var net: NetTuning
## Redraws (tests: a still strip does not redraw).
var redraws: int = 0

var _sectors := PackedFloat64Array()
var _dot_px := PackedInt32Array()
var _dot_color: Array[Color] = []
var _me_px: int = -1
var _mesh := HudMesh.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func setup(s: HudStyle, net_tuning: NetTuning, dots: int) -> void:
	style = s
	net = net_tuning
	_dot_px.resize(dots)
	_dot_px.fill(-1)
	_dot_color.resize(dots)
	_dot_color.fill(Color.TRANSPARENT)
	queue_redraw()


## Sector gantries as fractions of the loop.
func set_sectors(fracs: PackedFloat64Array) -> void:
	_sectors = fracs
	queue_redraw()


## Dot i at loop fraction `frac` (< 0 hides it). Allocation-free.
func set_dot(i: int, frac: float, color: Color) -> void:
	if i < 0 or i >= _dot_px.size():
		return
	var px := _px(frac) if frac >= 0.0 else -1
	if px == _dot_px[i] and (px < 0 or color == _dot_color[i]):
		return
	_dot_px[i] = px
	_dot_color[i] = color
	queue_redraw()


func set_me(frac: float) -> void:
	var px := _px(frac)
	if px != _me_px:
		_me_px = px
		queue_redraw()


## The x (px, local) of loop fraction `frac` on the track.
func x_of(frac: float) -> float:
	return _track().position.x + clampf(frac, 0.0, 1.0) * _track().size.x


## Dots shown (tests).
func dots_shown() -> int:
	var n := 0
	for px in _dot_px:
		if px >= 0:
			n += 1
	return n


func dot_x(i: int) -> int:
	return _dot_px[i]


func me_x() -> int:
	return _me_px


func _px(frac: float) -> int:
	return roundi(x_of(fposmod(frac, 1.0)))


func _track() -> Rect2:
	var r := _dot_r() * ME_SCALE
	var h := style.px(net.room_strip_height_px) if style != null and net != null else 1.0
	return Rect2(r, (size.y - h) * 0.5, maxf(size.x - r * 2.0, 1.0), h)


func _dot_r() -> float:
	return style.px(net.room_strip_dot_px) * 0.5 if style != null and net != null else 1.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_dot_px.fill(-1)
		_me_px = -1
		queue_redraw()


func _draw() -> void:
	redraws += 1
	if style == null or net == null:
		return
	var s := style
	var t := _track()
	var cy := t.get_center().y
	_mesh.begin()
	_mesh.rect(t.grow(s.edge_w), Color(s.ink, s.panel_fill.a))
	_mesh.rect(t, s.edge_idle)
	for f in _sectors:
		var x := t.position.x + f * t.size.x
		_mesh.rect(Rect2(x - s.edge_w, t.position.y - t.size.y, s.edge_w * 2.0, t.size.y * 3.0), s.muted)
	var r := _dot_r()
	for i in _dot_px.size():
		if _dot_px[i] >= 0:
			_mesh.ngon(Vector2(float(_dot_px[i]), cy), r, DOT_FACETS, _dot_color[i], s.ink, s.edge_w)
	if _me_px >= 0:
		_mesh.ngon(Vector2(float(_me_px), cy), r * ME_SCALE, DOT_FACETS, s.accent, s.ink, s.edge_w)
	_mesh.flush(self)
