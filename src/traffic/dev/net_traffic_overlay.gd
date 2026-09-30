class_name NetTrafficOverlay
extends Control
# lint: not-sim sandbox overlay (Control drawing); it only reads the network traffic harness
## The traffic sandbox's network overlays (N4.3). Spec: multiplayer handoff → Implementation
## milestones, N4 ("network overlays in the traffic sandbox"), Client network traffic
## (corrections, late intents, dev metrics); plan N4.3 ("sandbox network overlays").
## docs/NET_TRAFFIC.md → Sandbox.
##
## Per car near the player (nearest `label_cap`, within LABEL_RANGE_M):
##   GHOST  the last correction, carried to now with its speed (cyan outline): where the
##          server said the car was; the car drawn by TrafficView is the client's prediction
##          plus the blend still running. The server's true car at the same true time (the
##          fake authority, magenta outline) shows what the clock and the model miss.
##   LABEL  "#<car id> <last correction size> <offset still blending> <v0 estimate>".
##   INTENT a lane change's timeline under the label: blinker (amber) until the lateral move
##          may start, the move (green) to its end, a white tick at now, a red tick at the
##          server's move tick when the client holds past it (a late intent).
## A panel at the bottom left, above the sky slider: link, corrections per second, mean /
## p99 / max correction, late intents, bytes per second, teleports and snaps.
## Never takes input (mouse IGNORE); text with draw_string (no Label nodes).

const LABEL_RANGE_M := 250.0
const DEFAULT_LABEL_CAP := 10
const FONT_SIZE := 13
const OUTLINE_PX := 4
const LINE_PX := 2.0
const LABEL_LIFT_M := 1.4
const BOX_LIFT_M := 0.2
const BAR_W_PX := 120.0
const BAR_H_PX := 5.0
const BAR_GAP_PX := 4.0
## The panel's bottom edge sits this far above the screen's (clear of the sky slider).
const PANEL_BOTTOM_PX := 64.0
const PANEL_LEFT_PX := 16.0
const PANEL_PAD_PX := 8.0
const LINK_MIN_M := 0.02
const M_TO_CM := 100.0
const M_TO_MM := 1000.0

const COL_TEXT := Color("#f4f7ff")
const COL_OUTLINE := Color(0.0, 0.0, 0.0, 0.85)
const COL_GHOST := Color(0.35, 0.9, 1.0, 0.95)
const COL_TRUTH := Color(1.0, 0.35, 0.85, 0.9)
const COL_BLINK := Color("#ffae1a")
const COL_MOVE := Color("#6cff8a")
const COL_LATE := Color("#ff5a4d")
const COL_NOW := Color("#ffffff")
const COL_PANEL := Color(0.067, 0.102, 0.188, 0.9)

var harness: NetTrafficHarness
var road: RoadPath
var origin: FloatingOrigin
var camera: Camera3D
var player: VehicleState
var registry: TrafficRegistry
var link_name: String = ""
var label_cap: int = DEFAULT_LABEL_CAP
var text_scale: float = 1.0
var show_truth: bool = true

var _font: Font
var _smp := RoadSample.new()
var _pick := PackedInt32Array()
var _pick_d := PackedFloat64Array()
var _n: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font


func bind(h: NetTrafficHarness, road_path: RoadPath, floating_origin: FloatingOrigin, player_state: VehicleState) -> void:
	harness = h
	road = road_path
	origin = floating_origin
	player = player_state
	registry = h.registry
	_pick.resize(h.client_state.capacity)
	_pick_d.resize(h.client_state.capacity)


func _process(_delta: float) -> void:
	if harness != null and visible:
		queue_redraw()


func _draw() -> void:
	if harness == null or camera == null or player == null:
		return
	_pick_cars()
	var src := harness.source
	var st := harness.client_state
	var now := src.now_ticks
	for k in _n:
		var i := _pick[k]
		var h := registry.types[st.type_id[i]].height_m
		# The last correction, carried to now.
		var ct := src.last_correction_tick(i)
		if ct >= 0:
			var gs := src.last_correction_s(i) + src.last_correction_v(i) * (now - float(ct)) * src.tick_dt
			var gd := src.last_correction_d(i)
			_box_sd(gs, gd, st.length[i], st.width[i], BOX_LIFT_M, COL_GHOST)
			if absf(gs - st.s[i]) + absf(gd - st.d[i]) > LINK_MIN_M:
				_line_sd(st.s[i], st.d[i], gs, gd, h, COL_GHOST)
		if show_truth:
			_draw_truth(i)
		_draw_label(i, h, now)
	_draw_panel()


func _draw_truth(i: int) -> void:
	var auth := harness.authority
	var j := auth.slot_of_car(harness.source.car_id(i))
	if j < 0:
		return
	var srv := auth.sim.state
	var lag := (harness.true_server_ticks() - float(auth.tick)) / harness.net.tick_rate_hz
	var ts := NetTrafficWire.s_unwrap(road, srv.s[j] + srv.v[j] * lag, player.s)
	_box_sd(ts, srv.d[j], srv.length[j], srv.width[j], BOX_LIFT_M * 2.0, COL_TRUTH)


func _draw_label(i: int, h: float, now: float) -> void:
	var src := harness.source
	var st := harness.client_state
	var p := _world(st.s[i], st.d[i], h + LABEL_LIFT_M)
	if camera.is_position_behind(p):
		return
	var at := camera.unproject_position(p)
	var off := sqrt(src.offset_s(i) * src.offset_s(i) + src.offset_d(i) * src.offset_d(i))
	var text := "#%d  e %.0f mm  off %.0f cm  v0 %d" % [src.car_id(i), src.last_correction_error(i) * M_TO_MM,
		off * M_TO_CM, roundi(Units.mps_to_kmh(src.v0_estimate(i)))]
	var fs := roundi(float(FONT_SIZE) * text_scale)
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := at - Vector2(w * 0.5, 0.0)
	draw_string_outline(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OUTLINE_PX, COL_OUTLINE)
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)
	if src.has_lane_change(i):
		_draw_timeline(i, at + Vector2(-BAR_W_PX * 0.5, BAR_GAP_PX), now)


## Blinker → lateral start (amber), move (green), now (white), the server's move tick (red,
## when the client holds past it).
func _draw_timeline(i: int, at: Vector2, now: float) -> void:
	var src := harness.source
	var t0 := src.lane_change_blink_tick(i)
	var hold := src.lane_change_hold_tick(i)
	var t1 := src.lane_change_end_tick(i)
	var span := maxf(t1 - t0, 1.0)
	var x_hold := at.x + BAR_W_PX * clampf((hold - t0) / span, 0.0, 1.0)
	draw_rect(Rect2(at.x, at.y, x_hold - at.x, BAR_H_PX), COL_BLINK)
	draw_rect(Rect2(x_hold, at.y, at.x + BAR_W_PX - x_hold, BAR_H_PX), COL_MOVE)
	var move_t := src.lane_change_move_tick(i)
	if hold > move_t:
		var xm := at.x + BAR_W_PX * clampf((move_t - t0) / span, 0.0, 1.0)
		draw_line(Vector2(xm, at.y - BAR_H_PX), Vector2(xm, at.y + BAR_H_PX * 2.0), COL_LATE, LINE_PX)
	var xn := at.x + BAR_W_PX * clampf((now - t0) / span, 0.0, 1.0)
	draw_line(Vector2(xn, at.y - BAR_H_PX), Vector2(xn, at.y + BAR_H_PX * 2.0), COL_NOW, LINE_PX)


func _draw_panel() -> void:
	var s := harness.source.stats
	var lines := PackedStringArray()
	lines.append("NET %s  rtt %.0f ms  slew %.1f ms  cars %d" % [link_name,
		harness.clock.best_rtt_s * NetClock.MS_PER_S, harness.clock.slew_remaining_ms(), harness.client_state.count])
	lines.append("corrections %.0f/s  mean %.1f cm  p99 %.1f cm  max %.0f cm  (near p99 %.1f cm)" % [
		s.rate(NetTrafficStats.Counter.CORRECTIONS), s.mean_error() * M_TO_CM,
		s.percentile(NetTrafficStats.P99) * M_TO_CM, s.err_max * M_TO_CM, s.percentile(NetTrafficStats.P99, true) * M_TO_CM])
	lines.append("late intents %d (%.1f/min)  %.0f B/s  teleports %d  snaps %d  unsignaled %d" % [s.late_intents,
		s.rate(NetTrafficStats.Counter.LATE_INTENTS) * Units.S_PER_MIN, s.rate(NetTrafficStats.Counter.BYTES),
		s.teleports, s.snaps, s.unsignaled_lateral])
	var fs := roundi(float(FONT_SIZE) * text_scale)
	var lh := float(fs) + 3.0
	var w := 0.0
	for line in lines:
		w = maxf(w, _font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var hgt := lh * float(lines.size()) + PANEL_PAD_PX
	var x := PANEL_LEFT_PX + PANEL_PAD_PX
	var top := size.y - PANEL_BOTTOM_PX - hgt
	draw_rect(Rect2(PANEL_LEFT_PX, top, w + PANEL_PAD_PX * 2.0, hgt), COL_PANEL)
	for k in lines.size():
		draw_string(_font, Vector2(x, top + lh * float(k + 1)), lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)


## The nearest label_cap client cars within LABEL_RANGE_M of the player.
func _pick_cars() -> void:
	var st := harness.client_state
	_n = 0
	for i in st.capacity:
		if st.active[i] == 0:
			continue
		var dist := absf(st.s[i] - player.s)
		if dist > LABEL_RANGE_M:
			continue
		var k := mini(_n, label_cap)
		while k > 0 and _pick_d[k - 1] > dist:
			if k < label_cap:
				_pick[k] = _pick[k - 1]
				_pick_d[k] = _pick_d[k - 1]
			k -= 1
		if k < label_cap:
			_pick[k] = i
			_pick_d[k] = dist
			_n = mini(_n + 1, label_cap)


func _world(s: float, d: float, h: float) -> Vector3:
	road.sample_into(s, _smp)
	return _smp.local_point(d, origin.origin_x, origin.origin_y, origin.origin_z) + _smp.up * h


func _line_sd(s0: float, d0: float, s1: float, d1: float, h: float, col: Color) -> void:
	var a := _world(s0, d0, h)
	var b := _world(s1, d1, h)
	if camera.is_position_behind(a) or camera.is_position_behind(b):
		return
	draw_line(camera.unproject_position(a), camera.unproject_position(b), col, LINE_PX, true)


func _box_sd(s: float, d: float, ln: float, wd: float, h: float, edge: Color) -> void:
	var pts := PackedVector2Array()
	for c: Vector2 in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
		var p := _world(s + ln * c.x, d + wd * c.y, h)
		if camera.is_position_behind(p):
			return
		pts.append(camera.unproject_position(p))
	pts.append(pts[0])
	draw_polyline(pts, edge, LINE_PX, true)
