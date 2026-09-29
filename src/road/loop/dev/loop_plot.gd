class_name LoopPlot
extends Control
## Top-down plot of the multiplayer loop for the loop editor (N3.1 review tool, not
## shipped in gameplay). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map (editor
## tool). docs/LOOP_MAP.md → Editor.
##
## North up (world +X), east right (world +Z). The road is drawn per section colour, as
## wide as its lane count; tunnels dark, the bridge white, elevated stretches outlined,
## road works orange on the right edge, ramps as spurs to the right, sector gantries as
## bars (S0 = start / finish, chequered), blind crests as red carets, lane changes as
## dots with the new count. A strip at the bottom shows the elevation over one lap.
## Handles (squares) mark the s-like parameters (tunnel portals, sector offsets, ramps,
## road works, lane changes): drag one along the loop to move it. Wheel zooms, right or
## middle drag pans, a click selects the nearest handle.

signal param_dragged(key: String, value: float)
signal param_selected(key: String)

const SECTION_COLORS: Array[Color] = [
	Color(0.93, 0.66, 0.32), Color(0.78, 0.42, 0.3), Color(0.35, 0.7, 0.92), Color(0.72, 0.72, 0.85),
	Color(0.55, 0.8, 0.38), Color(0.9, 0.5, 0.8),
]
const BG := Color(0.07, 0.08, 0.1)
const GRID := Color(0.18, 0.2, 0.23)
const TEXT := Color(0.92, 0.92, 0.95)
const DIM := Color(0.6, 0.62, 0.66)
const TUNNEL := Color(0.05, 0.05, 0.06)
const BRIDGE := Color(1.0, 1.0, 1.0)
const WORKS := Color(1.0, 0.55, 0.1)
const RAMP := Color(0.95, 0.95, 0.4)
const CREST := Color(1.0, 0.3, 0.3)
const ELEVATED := Color(0.75, 0.5, 1.0)
const SECTOR := Color(0.4, 1.0, 0.6)
const HANDLE := Color(1.0, 1.0, 1.0)
const SELECT := Color(0.2, 0.9, 1.0)
const STEP_M := 20.0
const PAD_PX := 24.0
const PROFILE_FRAC := 0.18
const LANE_PX := 1.6
const ROAD_MIN_PX := 2.0
const HANDLE_PX := 6.0
const PICK_PX := 14.0
const FONT_SIZE := 13
const ZOOM_STEP := 1.15
const RAMP_PX := 14.0
const CREST_PX := 6.0
const GRID_M := 1000.0
const LEGEND_BG := Color(0.07, 0.08, 0.1, 0.8)
const LEGEND_W_PX := 250.0
const LEGEND_ROW_PX := 17.0
## Legend rows besides the sections (symbols + the scale line).
const LEGEND_ROWS := 9
## Suffixes of the parameters drawn as draggable handles.
const HANDLE_SUFFIXES: Array[String] = ["portal_m", "offset_m", "off_m", "start_m", "change_m"]

var road: LoopRoadPath
## Parameter shown selected (its location is circled).
var selected_key: String = ""
var zoom: float = 1.0
var pan := Vector2.ZERO

var _pts := PackedVector2Array()      ## plan points every STEP_M (world z, -x)
var _s := PackedFloat64Array()
var _lo := Vector2.ZERO
var _hi := Vector2.ONE
var _drag_key: String = ""
var _drag_s: float = -1.0
var _panning: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func set_road(r: LoopRoadPath) -> void:
	road = r
	_pts.clear()
	_s.clear()
	var smp := RoadSample.new()
	var s := 0.0
	_lo = Vector2(INF, INF)
	_hi = Vector2(-INF, -INF)
	while s <= road.length():
		road.sample_into(s, smp)
		var p := Vector2(smp.pos_z, -smp.pos_x)
		_pts.append(p)
		_s.append(s)
		_lo = _lo.min(p)
		_hi = _hi.max(p)
		s += STEP_M
	queue_redraw()


# ---------------------------------------------------------------- Mapping

func _plan_rect() -> Rect2:
	var r := Rect2(Vector2.ZERO, size)
	return Rect2(r.position + Vector2(PAD_PX, PAD_PX), Vector2(r.size.x - PAD_PX * 2.0,
		r.size.y * (1.0 - PROFILE_FRAC) - PAD_PX * 2.0))


func _scale() -> float:
	var r := _plan_rect()
	var ext := _hi - _lo
	return minf(r.size.x / maxf(ext.x, 1.0), r.size.y / maxf(ext.y, 1.0)) * zoom


func _to_screen(p: Vector2) -> Vector2:
	var r := _plan_rect()
	var c := (_lo + _hi) * 0.5
	return r.get_center() + (p - c) * _scale() + pan


func _world_at(s: float) -> Vector2:
	var smp := road.sample(s)
	return Vector2(smp.pos_z, -smp.pos_x)


func _right_at(s: float) -> Vector2:
	var smp := road.sample(s)
	return Vector2(smp.right.z, -smp.right.x)


func _screen_at(s: float) -> Vector2:
	return _to_screen(_world_at(s))


## s of the plot point nearest to a screen position.
func s_at_screen(pos: Vector2) -> float:
	var best := INF
	var best_s := 0.0
	for i in _pts.size():
		var d := _to_screen(_pts[i]).distance_squared_to(pos)
		if d < best:
			best = d
			best_s = _s[i]
	return best_s


# ---------------------------------------------------------------- Handles

static func is_handle_key(key: String) -> bool:
	for suffix in HANDLE_SUFFIXES:
		if key.ends_with(suffix):
			return true
	return false


## Where a parameter acts on the loop now (see LoopGen._param).
func param_location(i: int) -> float:
	var o := road.layout
	return o.wrap_s(o.param_s[i] - o.param_default[i] + o.param_value[i])


## The parameter value that puts handle i at s (sector offsets wrap to the nearest).
func value_for_s(i: int, s: float) -> float:
	var o := road.layout
	var base := o.param_s[i] - o.param_default[i]
	return clampf(o.signed_delta(base, s), o.param_min[i], o.param_max[i])


func _handle_at(pos: Vector2) -> int:
	if road == null:
		return -1
	var o := road.layout
	var best := PICK_PX * PICK_PX
	var found := -1
	for i in o.param_key.size():
		if not is_handle_key(o.param_key[i]):
			continue
		var d := _screen_at(param_location(i)).distance_squared_to(pos)
		if d < best:
			best = d
			found = i
	return found


func _gui_input(event: InputEvent) -> void:
	if road == null:
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				var f := ZOOM_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP
				var anchor := mb.position - _plan_rect().get_center()
				pan = anchor + (pan - anchor) * f
				zoom *= f
				queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var i := _handle_at(mb.position)
				if i >= 0:
					_drag_key = road.layout.param_key[i]
					_drag_s = param_location(i)
					selected_key = _drag_key
					param_selected.emit(_drag_key)
					queue_redraw()
			elif _drag_key != "":
				var i := road.layout.param_index(_drag_key)
				var key := _drag_key
				_drag_key = ""
				if i >= 0 and absf(road.layout.signed_delta(param_location(i), _drag_s)) > 0.0:
					param_dragged.emit(key, snappedf(value_for_s(i, _drag_s), 1.0))
				queue_redraw()
			accept_event()
	var mm := event as InputEventMouseMotion
	if mm != null:
		if _panning:
			pan += mm.relative
			queue_redraw()
		elif _drag_key != "":
			_drag_s = s_at_screen(mm.position)
			queue_redraw()


# ---------------------------------------------------------------- Drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	if road == null or _pts.size() < 2:
		return
	var o := road.layout
	var font := get_theme_default_font()
	_draw_grid()
	# Road: per step, section colour, lane-count width.
	for i in _pts.size() - 1:
		var s := _s[i]
		var w := ROAD_MIN_PX + LANE_PX * float(road.lane_count(s))
		var col := SECTION_COLORS[o.section_at(s) % SECTION_COLORS.size()]
		draw_line(_to_screen(_pts[i]), _to_screen(_pts[i + 1]), col, w)
	var widest := 0
	for lanes in o.section_lanes:
		widest = maxi(widest, lanes)
	for i in o.elevated_s0.size():
		_draw_span(o.elevated_s0[i], o.elevated_s1[i], ELEVATED, 1.0, ROAD_MIN_PX + LANE_PX * float(widest) + 4.0)
	for i in o.tunnel_s0.size():
		_draw_span(o.tunnel_s0[i], o.tunnel_s1[i], TUNNEL, ROAD_MIN_PX + LANE_PX * float(o.tunnel_lanes[i]) + 2.0, 0.0)
		_label(font, o.tunnel_s0[i], "T%d (%d)" % [i, o.tunnel_lanes[i]], -1.0)
	_draw_span(o.bridge_s0, o.bridge_s1, BRIDGE, ROAD_MIN_PX + LANE_PX * 3.0, 0.0)
	_label(font, (o.bridge_s0 + o.bridge_s1) * 0.5, "BRIDGE", -1.0)
	for i in o.closure_s0.size():
		_draw_span(o.closure_s0[i], o.closure_s1[i], WORKS, 2.0, LANE_PX * 3.0 + 3.0)
	for i in o.ramp_s.size():
		var a := o.ramp_s[i]
		var b := a + o.ramp_len[i]
		var off := RAMP_PX
		if o.ramp_kind[i] == LoopLayout.RAMP_OFF:
			draw_line(_screen_at(a), _screen_at(b) + _right_at(b) * off, RAMP, 2.0)
		else:
			draw_line(_screen_at(a) + _right_at(a) * off, _screen_at(b), RAMP, 2.0)
	for f in o.features:
		if f.kind == RoadFeature.Kind.BLIND_CREST:
			var s := (f.s_start + f.s_end) * 0.5
			var p := _screen_at(s) - _right_at(s) * (LANE_PX * 3.0 + CREST_PX)
			draw_colored_polygon(PackedVector2Array([p + Vector2(-CREST_PX, CREST_PX * 0.5),
				p + Vector2(0.0, -CREST_PX), p + Vector2(CREST_PX, CREST_PX * 0.5)]), CREST)
	for i in o.lane_s.size():
		var p := _screen_at(o.lane_s[i])
		draw_circle(p, 3.0, TEXT)
		draw_string(font, p + _right_at(o.lane_s[i]) * 12.0, "%d" % o.lane_n[i], HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			FONT_SIZE, TEXT)
	for k in o.sector_s.size():
		var s := o.sector_s[k]
		var p := _screen_at(s)
		var rt := _right_at(s) * (LANE_PX * 4.0 + 8.0)
		if k == 0:
			draw_line(p - rt, p + rt, Color.WHITE, 6.0)
			draw_dashed_line(p - rt, p + rt, Color.BLACK, 6.0, 3.0)
		else:
			draw_line(p - rt, p + rt, SECTOR, 3.0)
		draw_string(font, p + rt * 1.6, "S%d%s" % [k, " START" if k == 0 else ""], HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			FONT_SIZE, SECTOR)
	# Direction of travel at s = 0.
	var p0 := _screen_at(0.0)
	var fwd := (_screen_at(STEP_M * 10.0) - p0).normalized()
	draw_line(p0, p0 + fwd * 40.0, TEXT, 2.0)
	draw_line(p0 + fwd * 40.0, p0 + fwd * 30.0 + fwd.orthogonal() * 6.0, TEXT, 2.0)
	draw_line(p0 + fwd * 40.0, p0 + fwd * 30.0 - fwd.orthogonal() * 6.0, TEXT, 2.0)
	_draw_handles()
	_draw_profile(font)
	_draw_legend(font)


func _draw_grid() -> void:
	var sc := _scale()
	if sc <= 0.0:
		return
	var r := _plan_rect()
	var step := GRID_M * sc
	if step < 8.0:
		return
	var origin := _to_screen(Vector2.ZERO)
	var x := fposmod(origin.x - r.position.x, step) + r.position.x
	while x < r.end.x:
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), GRID, 1.0)
		x += step
	var y := fposmod(origin.y - r.position.y, step) + r.position.y
	while y < r.end.y:
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), GRID, 1.0)
		y += step


## A stretch of road drawn over the centreline (lateral 0) or offset to the right.
func _draw_span(a: float, b: float, col: Color, width: float, lateral_px: float) -> void:
	var s := a
	var prev := _screen_at(s) + _right_at(s) * lateral_px
	while s < b:
		s = minf(s + STEP_M, b)
		var p := _screen_at(s) + _right_at(s) * lateral_px
		draw_line(prev, p, col, width)
		prev = p


func _label(font: Font, s: float, text: String, side: float) -> void:
	var p := _screen_at(s) + _right_at(s) * side * 22.0
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, TEXT)


func _draw_handles() -> void:
	var o := road.layout
	for i in o.param_key.size():
		var key := o.param_key[i]
		if not is_handle_key(key):
			continue
		var s := _drag_s if key == _drag_key else param_location(i)
		var p := _screen_at(s)
		var col := SELECT if key == selected_key else HANDLE
		draw_rect(Rect2(p - Vector2(HANDLE_PX, HANDLE_PX) * 0.5, Vector2(HANDLE_PX, HANDLE_PX)), col, false, 1.5)
	var sel := o.param_index(selected_key)
	if sel >= 0:
		draw_arc(_screen_at(param_location(sel)), 16.0, 0.0, TAU, 32, SELECT, 2.0)


## Elevation over one lap, sections shaded, tunnels dark, crests red.
func _draw_profile(font: Font) -> void:
	var o := road.layout
	var top := size.y * (1.0 - PROFILE_FRAC)
	var r := Rect2(PAD_PX, top, size.x - PAD_PX * 2.0, size.y * PROFILE_FRAC - PAD_PX)
	draw_rect(r, Color(0.1, 0.11, 0.14))
	var e_lo := INF
	var e_hi := -INF
	for v in o.e:
		e_lo = minf(e_lo, v)
		e_hi = maxf(e_hi, v)
	var span := maxf(e_hi - e_lo, 1.0)
	var L := road.length()
	for j in road.section_count():
		var x0 := r.position.x + road.section_start(j) / L * r.size.x
		var col := SECTION_COLORS[j % SECTION_COLORS.size()]
		draw_rect(Rect2(x0, r.position.y, o.section_length_m / L * r.size.x, 3.0), col)
		draw_string(font, Vector2(x0 + 4.0, r.end.y - 4.0), String(o.section_ids[j]), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			FONT_SIZE - 2, DIM)
	for i in o.tunnel_s0.size():
		draw_rect(Rect2(r.position.x + o.tunnel_s0[i] / L * r.size.x, r.position.y,
			(o.tunnel_s1[i] - o.tunnel_s0[i]) / L * r.size.x, r.size.y), Color(0, 0, 0, 0.5))
	var pts := PackedVector2Array()
	var step := maxi(floori(float(o.n) / maxf(r.size.x, 1.0)), 1)
	for i in range(0, o.n + 1, step):
		pts.append(Vector2(r.position.x + float(i) * o.dx / L * r.size.x,
			r.end.y - (o.e[i] - e_lo) / span * (r.size.y - 8.0) - 4.0))
	draw_polyline(pts, TEXT, 1.5)
	for f in o.features:
		if f.kind == RoadFeature.Kind.BLIND_CREST:
			draw_line(Vector2(r.position.x + f.s_start / L * r.size.x, r.position.y + 4.0),
				Vector2(r.position.x + minf(f.s_end, L) / L * r.size.x, r.position.y + 4.0), CREST, 3.0)
	draw_string(font, r.position + Vector2(4.0, 16.0), "elevation %.0f..%.0f m" % [e_lo, e_hi],
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 2, DIM)


func _draw_legend(font: Font) -> void:
	var o := road.layout
	# Inside the loop (the plan's middle), where no road is drawn.
	var h := LEGEND_ROW_PX * float(road.section_count() + LEGEND_ROWS)
	var p := _to_screen((_lo + _hi) * 0.5) - Vector2(LEGEND_W_PX, h) * 0.5 + Vector2(8.0, 18.0)
	draw_rect(Rect2(p - Vector2(8.0, 18.0), Vector2(LEGEND_W_PX, h)), LEGEND_BG)
	for j in road.section_count():
		draw_rect(Rect2(p + Vector2(0.0, -9.0), Vector2(14.0, 10.0)), SECTION_COLORS[j % SECTION_COLORS.size()])
		draw_string(font, p + Vector2(20.0, 0.0), "%d %s  %d lanes" % [j, o.section_ids[j], o.section_lanes[j]],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, TEXT)
		p.y += 17.0
	var rows: Array = [[TUNNEL, "tunnel (lanes)"], [BRIDGE, "suspension bridge"], [ELEVATED, "elevated"],
		[WORKS, "road works zone"], [RAMP, "ramp (off / on)"], [CREST, "blind crest"], [SECTOR, "sector gantry"]]
	for row: Array in rows:
		draw_line(p + Vector2(0.0, -4.0), p + Vector2(14.0, -4.0), row[0], 4.0)
		draw_string(font, p + Vector2(20.0, 0.0), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, DIM)
		p.y += 17.0
	draw_string(font, p + Vector2(0.0, 4.0), "L %.3f km   grid 1 km   north up" % (road.length() / Units.M_PER_KM),
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, DIM)
