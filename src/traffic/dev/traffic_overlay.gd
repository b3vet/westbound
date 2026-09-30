class_name TrafficOverlay
extends Control
# lint: not-sim sandbox overlay (Control drawing); it only reads TrafficSim state and the MobilProbe
## Immediate-mode overlays for the traffic sandbox. Spec: Traffic → Traffic sandbox
## (debug scene): "overlays for each vehicle's IDM gap and target speed, MOBIL
## decisions with incentive values, blinker timers, the player's predicted occupancy,
## and the passability paths the director found".
##
## Layers (each toggled on its own):
##   IDM   per labeled car: bumper gap to its leader, speed / target speed (v0, or the
##         lane-split cap), applied acceleration (and raw IDM when the clamp or a
##         reaction changed it); a leader link colored by the acceleration.
##   MOBIL per labeled car: the current left / right evaluation from MobilProbe
##         (incentive vs threshold, or the safety refusal), refreshed at MOBIL_HZ; and
##         the last observed decision (signal start: the incentive and threshold at
##         that moment; outcome: moved, or cancelled with the cause).
##   BLINK per signaling / moving car: time in state / duration; the car's target
##         space (its box at the target d) for signaling cars.
##   OCC   the player's predicted occupancy for no-ambush: its box at t = 0 and at
##         t = no_ambush_window_s, grown by no_ambush_margin_m, and the swept hull.
##   PASS  passability (WP6.1): the paths the director found for its last batches
##         (passability_paths, polylines in (s, d), from TrafficDirector.pass_paths_s/_d)
##         and the player's own path from where it is now (player_path, refreshed by
##         the sandbox a few times a second), or "NO PATH" when it has none.
## A tapped car (select_at) gets every MOBIL term for both sides in a side panel.
##
## Cost: labels are capped (label_cap, nearest to the camera first), text is drawn
## with draw_string (no Label nodes), MOBIL probes run for labeled cars only, a few
## times per second, into Results allocated once. Never takes input (mouse IGNORE).

const MOBIL_HZ := 5.0
const LABEL_RANGE_M := 220.0
const DEFAULT_LABEL_CAP := 14
const FONT_SIZE := 13
const SMALL_FONT_SIZE := 12
const OUTLINE_PX := 4
const LINE_PX := 2.0
const LABEL_LIFT_M := 1.2
const LINK_LIFT_M := 0.6
const BOX_LIFT_M := 0.15
const EVENT_SHOW_S := 1.5
const SELECT_RADIUS_PX := 60.0
## Below the sandbox's five top-right button rows (tabs, two set-piece rows, fast
## traffic, racer arrivals).
const PANEL_TOP_PX := 308.0
const PANEL_MARGIN_PX := 16.0
const ACCEL_WARN_MPS2 := 1.0
## Show the raw IDM acceleration next to the applied one when they differ this much.
const ACCEL_SHOW_RAW_MPS2 := 0.25
const LABEL_PAD_PX := 2.0
## Short profile tags, in TrafficRegistry.PROFILE_IDS order.
const PROFILE_TAGS: Array[String] = ["CRU", "COM", "AGG", "TRK", "BUS", "VAN", "MOTO", "HES", "RACE"]

const COL_TEXT := Color("#f4f7ff")
const COL_MUTED := Color("#aab2c8")
const COL_OUTLINE := Color(0.0, 0.0, 0.0, 0.85)
const COL_GOOD := Color("#6cff8a")
const COL_BAD := Color("#ff5a4d")
const COL_WARN := Color("#ffc94d")
const COL_BLINK := Color("#ffae1a")
const COL_OCC := Color(0.3, 0.85, 1.0, 0.9)
const COL_OCC_FILL := Color(0.3, 0.85, 1.0, 0.16)
const COL_PASS := Color(0.75, 0.45, 1.0, 0.9)
const COL_PASS_PLAYER := Color(0.35, 1.0, 0.95, 0.95)
const COL_PANEL := Color(0.067, 0.102, 0.188, 0.94)
const COL_SELECT := Color("#ffffff")
const COL_LINK := Color(0.45, 1.0, 0.6, 0.75)
const COL_LABEL_BG := Color(0.043, 0.063, 0.125, 0.55)

## Last-decision outcomes.
enum Outcome { NONE, PENDING, MOVED, CANCEL_PLAYER, CANCEL_HESITANT, CANCEL_UNSAFE, CANCEL }
const OUTCOME_NAMES: Array[String] = ["", "signaling", "moved", "cancel: player", "cancel: hesitant",
	"cancel: unsafe", "cancel"]
## Reaction event markers.
enum Mark { NONE, HORN, BRAKE_TAP, HIGH_BEAMS, HAZARDS, HIT }
const MARK_NAMES: Array[String] = ["", "HORN", "BRAKE TAP", "HIGH BEAMS", "HAZARDS", "HIT"]

var show_idm: bool = true
var show_mobil: bool = true
var show_blink: bool = true
var show_occupancy: bool = true
var show_passability: bool = false
var label_cap: int = DEFAULT_LABEL_CAP
## Text size multiplier (the sandbox raises it on touch screens: phones).
var text_scale: float = 1.0
## Display safe area (canvas px); the side panel and labels stay inside it.
var safe_rect := Rect2(0.0, 0.0, 0.0, 0.0)
## Selected slot (-1 none): full MOBIL terms in the side panel.
var selected_slot: int = -1

var sim: TrafficSim
var road: RoadPath
var origin: FloatingOrigin
var probe: MobilProbe
var camera: Camera3D
var player: VehicleState
var player_length_m: float = 4.5
var player_width_m: float = 1.9
## Passability paths the director found (WP6.1): each a polyline of Vector2(s, d).
var passability_paths: Array[PackedVector2Array] = []
## The player's own passability path (Vector2(s, d) per 0.25 s), empty when none.
var player_path := PackedVector2Array()
## False when the player's last check found no path (its window is impossible).
var player_path_ok := true
## One line under the player: the last check's numbers (the sandbox fills it).
var player_path_note := ""

var _font: Font
var _smp := RoadSample.new()
var _cap: int = 0
# Labeled slots this frame, nearest first.
var _labels := PackedInt32Array()
var _label_dist := PackedFloat64Array()
var _n_labels: int = 0
var _placed: Array[Rect2] = []
var _n_placed: int = 0
var _lines := PackedStringArray()
var _colors := PackedColorArray()
# Cached probe results per slot (left, right) and their refresh clock.
var _mob_left: Array[MobilProbe.Result] = []
var _mob_right: Array[MobilProbe.Result] = []
var _mob_valid := PackedByteArray()
var _mob_clock: float = 0.0
var _sel_left := MobilProbe.Result.new()
var _sel_right := MobilProbe.Result.new()
# Decision tracking per slot.
var _prev_lc := PackedInt32Array()
var _prev_id := PackedInt32Array()
var _dec_id := PackedInt32Array()
var _dec_to := PackedInt32Array()
var _dec_inc := PackedFloat64Array()
var _dec_th := PackedFloat64Array()
var _dec_ref := PackedInt32Array()
var _dec_outcome := PackedInt32Array()
var _dec_split := PackedByteArray()
var _dec_requested := PackedByteArray()
var _req_id := PackedInt32Array()
var _dec_probe := MobilProbe.Result.new()
var _prev_cancel_player: int = 0
var _prev_cancel_hesitant: int = 0
var _prev_cancel_unsafe: int = 0
# Reaction markers per slot.
var _mark := PackedInt32Array()
var _mark_t := PackedFloat64Array()
var _mark_id := PackedInt32Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font


## Binds the overlay to a sim (again after a re-seed). Allocates the per-slot arrays.
func bind(traffic_sim: TrafficSim, road_path: RoadPath, floating_origin: FloatingOrigin,
		mobil_probe: MobilProbe) -> void:
	sim = traffic_sim
	road = road_path
	origin = floating_origin
	probe = mobil_probe
	_cap = sim.state.capacity
	_labels.resize(_cap)
	_label_dist.resize(_cap)
	_placed.resize(_cap)
	_n_labels = 0
	_mob_left.clear()
	_mob_right.clear()
	for i in _cap:
		_mob_left.append(MobilProbe.Result.new())
		_mob_right.append(MobilProbe.Result.new())
	_mob_valid.resize(_cap)
	_mob_valid.fill(0)
	_prev_lc.resize(_cap)
	_prev_lc.fill(0)
	_prev_id.resize(_cap)
	_prev_id.fill(-1)
	_dec_id.resize(_cap)
	_dec_id.fill(-1)
	_dec_to.resize(_cap)
	_dec_inc.resize(_cap)
	_dec_th.resize(_cap)
	_dec_ref.resize(_cap)
	_dec_outcome.resize(_cap)
	_dec_outcome.fill(Outcome.NONE)
	_dec_split.resize(_cap)
	_dec_requested.resize(_cap)
	_req_id.resize(_cap)
	_req_id.fill(-1)
	_mark.resize(_cap)
	_mark.fill(Mark.NONE)
	_mark_t.resize(_cap)
	_mark_id.resize(_cap)
	_prev_cancel_player = sim.stat_cancel_player
	_prev_cancel_hesitant = sim.stat_cancel_hesitant
	_prev_cancel_unsafe = sim.stat_cancel_unsafe
	selected_slot = -1


## Call after every sim tick (the sandbox does): records MOBIL decisions as they
## happen. At a signal start the probe evaluates the move the car just chose, so the
## incentive and threshold shown are the ones at the decision.
func observe_tick() -> void:
	if sim == null:
		return
	var st := sim.state
	var dp := sim.stat_cancel_player - _prev_cancel_player
	var dh := sim.stat_cancel_hesitant - _prev_cancel_hesitant
	var du := sim.stat_cancel_unsafe - _prev_cancel_unsafe
	_prev_cancel_player = sim.stat_cancel_player
	_prev_cancel_hesitant = sim.stat_cancel_hesitant
	_prev_cancel_unsafe = sim.stat_cancel_unsafe
	var single_cause := Outcome.CANCEL
	if dp + dh + du == 1:
		single_cause = Outcome.CANCEL_PLAYER if dp == 1 else (Outcome.CANCEL_HESITANT if dh == 1 else Outcome.CANCEL_UNSAFE)
	var probed := false
	for i in _cap:
		if st.active[i] == 0:
			_prev_id[i] = -1
			continue
		var id := st.vehicle_id[i]
		var lc := st.lc_state[i]
		var was := _prev_lc[i] if _prev_id[i] == id else TrafficState.LaneChange.NONE
		if lc != was:
			if lc == TrafficState.LaneChange.SIGNALING:
				if not probed:
					probe.set_player(player)
					probed = true
				_record_signal(i, id)
			elif was == TrafficState.LaneChange.SIGNALING and _dec_id[i] == id:
				_dec_outcome[i] = Outcome.MOVED if lc == TrafficState.LaneChange.MOVING else single_cause
		_prev_lc[i] = lc
		_prev_id[i] = id


func _record_signal(i: int, id: int) -> void:
	var st := sim.state
	_dec_id[i] = id
	_dec_to[i] = st.target_lane[i]
	_dec_outcome[i] = Outcome.PENDING
	var split := st.target_lane[i] == st.lane[i]
	_dec_split[i] = 1 if split else 0
	_dec_requested[i] = 1 if _req_id[i] == id else 0
	_req_id[i] = -1
	if split or _dec_requested[i] == 1:
		_dec_inc[i] = NAN
		_dec_th[i] = NAN
		_dec_ref[i] = MobilProbe.Refusal.NONE
		return
	probe.evaluate_into(i, st.target_lane[i], _dec_probe)
	_dec_inc[i] = _dec_probe.incentive
	_dec_th[i] = _dec_probe.threshold
	_dec_ref[i] = _dec_probe.refusal


## The sandbox asked this car to change lanes (TrafficSim.request_lane_change checks
## safety only): its next signal is shown as requested, not as a MOBIL decision.
func note_request(slot: int) -> void:
	if slot >= 0 and slot < _cap:
		_req_id[slot] = sim.state.vehicle_id[slot]


## A reaction event for `slot` (the sandbox forwards the sim's event buffer).
func note_event(slot: int, mark: Mark) -> void:
	if slot < 0 or slot >= _cap:
		return
	_mark[slot] = mark
	_mark_t[slot] = EVENT_SHOW_S
	_mark_id[slot] = sim.state.vehicle_id[slot]


## Last recorded decision of a slot (tests): [target lane, incentive, threshold,
## refusal, outcome], or an empty array.
func last_decision(slot: int) -> Array:
	if slot < 0 or slot >= _cap or _dec_id[slot] != sim.state.vehicle_id[slot]:
		return []
	return [_dec_to[slot], _dec_inc[slot], _dec_th[slot], _dec_ref[slot], _dec_outcome[slot]]


## Selects the vehicle drawn nearest to a screen point (canvas px), or clears the
## selection. Returns the slot or -1.
func select_at(pos: Vector2) -> int:
	selected_slot = -1
	if sim == null or camera == null:
		return -1
	var st := sim.state
	var best := SELECT_RADIUS_PX
	for i in st.capacity:
		if st.active[i] == 0:
			continue
		var p := _world(st.s[i], st.d[i], st.width[i])
		if camera.is_position_behind(p):
			continue
		var dist := camera.unproject_position(p).distance_to(pos)
		if dist < best:
			best = dist
			selected_slot = i
	return selected_slot


func _process(delta: float) -> void:
	if sim == null or camera == null or player == null:
		return
	for i in _cap:
		if _mark_t[i] > 0.0:
			_mark_t[i] -= delta
	_pick_labels()
	_mob_clock -= delta
	if show_mobil and _mob_clock <= 0.0:
		_mob_clock = 1.0 / MOBIL_HZ
		_refresh_mobil()
	queue_redraw()


func _pick_labels() -> void:
	var st := sim.state
	var cam_pos := camera.global_position
	_n_labels = 0
	for i in st.capacity:
		if st.active[i] == 0:
			continue
		var p := _world(st.s[i], st.d[i], 0.0)
		if camera.is_position_behind(p):
			continue
		var dist := float(p.distance_to(cam_pos))
		if dist > LABEL_RANGE_M * _range_scale():
			continue
		# Insertion into the nearest-first list, capped.
		var k := mini(_n_labels, label_cap)
		while k > 0 and _label_dist[k - 1] > dist:
			if k < label_cap:
				_labels[k] = _labels[k - 1]
				_label_dist[k] = _label_dist[k - 1]
			k -= 1
		if k < label_cap:
			_labels[k] = i
			_label_dist[k] = dist
			_n_labels = mini(_n_labels + 1, label_cap)
	if selected_slot >= 0 and st.active[selected_slot] == 0:
		selected_slot = -1


## Label range grows with the camera height (top-down views cover more road).
func _range_scale() -> float:
	return maxf(1.0, camera.global_position.y / LABEL_RANGE_M * 2.0 + 1.0) if camera != null else 1.0


func _refresh_mobil() -> void:
	probe.set_player(player)
	_mob_valid.fill(0)
	for k in _n_labels:
		var i := _labels[k]
		_probe_both(i, _mob_left[i], _mob_right[i])
		_mob_valid[i] = 1


func _probe_both(i: int, left: MobilProbe.Result, right: MobilProbe.Result) -> void:
	var lane := sim.state.lane[i]
	probe.evaluate_into(i, lane - 1, left)
	probe.evaluate_into(i, lane + 1, right)


# ---------------------------------------------------------------- Drawing

func _draw() -> void:
	if sim == null or camera == null or player == null:
		return
	if show_passability:
		_draw_passability()
	if show_occupancy:
		_draw_occupancy()
	if show_blink:
		_draw_targets()
	if show_idm:
		for k in _n_labels:
			_draw_link(_labels[k])
	_n_placed = 0
	for k in _n_labels:
		_draw_label(_labels[k])
	if selected_slot >= 0:
		_draw_selected()


func _draw_label(i: int) -> void:
	var st := sim.state
	var h := _height(i) + LABEL_LIFT_M
	var p := _world(st.s[i], st.d[i], h)
	if camera.is_position_behind(p):
		return
	var at := camera.unproject_position(p)
	_lines.clear()
	_colors.clear()
	var head := PROFILE_TAGS[st.profile_id[i]] if st.profile_id[i] < PROFILE_TAGS.size() else "?"
	if sim.is_lane_splitting(i):
		head += " split"
	if show_idm:
		# v/v0 km/h, applied accel (raw IDM when a reaction or the clamp changed it), gap.
		var v0 := st.v0[i]
		if sim.is_lane_splitting(i):
			v0 = minf(v0, Units.kmh_to_mps(sim.tuning.lane_split_max_speed_kmh))
		var a := st.accel[i]
		var raw := sim.idm_accel(i)
		var lead := sim.leader_of(i)
		var gtxt := "free" if lead < 0 else ("P%.0f" % sim.leader_gap(i) if lead == sim.player_index() else "%.0fm" % sim.leader_gap(i))
		head += " %d/%d %+.1f%s %s" % [roundi(Units.mps_to_kmh(st.v[i])), roundi(Units.mps_to_kmh(v0)), a,
			"(%+.1f)" % raw if absf(raw - a) > ACCEL_SHOW_RAW_MPS2 else "", gtxt]
	_add_line(head, _accel_color(st.accel[i], i) if show_idm else COL_MUTED)
	if show_mobil and _mob_valid[i] == 1:
		var l := _mob_left[i]
		var r := _mob_right[i]
		_add_line("%s  %s" % [_side_text("L", l), _side_text("R", r)],
			COL_GOOD if l.accepts() or r.accepts() else COL_MUTED)
	if show_mobil and _dec_id[i] == st.vehicle_id[i] and _dec_outcome[i] != Outcome.NONE:
		_add_line(_decision_text(i), COL_BLINK if _dec_outcome[i] == Outcome.PENDING else COL_MUTED)
	if show_blink and st.lc_state[i] != TrafficState.LaneChange.NONE:
		var sig := st.lc_state[i] == TrafficState.LaneChange.SIGNALING
		_add_line("%s%s %.1f/%.1fs" % ["SIG " if sig else "MOVE ",
			"<" if st.has_flag(i, TrafficState.FLAG_BLINKER_LEFT) else ">", st.lc_timer[i], st.lc_duration[i]], COL_BLINK)
	if _mark_t[i] > 0.0 and _mark_id[i] == st.vehicle_id[i]:
		_add_line(MARK_NAMES[_mark[i]], COL_WARN)
	# Greedy de-cluttering: nearest cars were placed first; a label that would overlap
	# one already drawn is dropped this frame (the car keeps its links and boxes).
	var box := _text_box(at, _lines, _fs(FONT_SIZE))
	# Keep labels on screen.
	var area := _area()
	var dx := clampf(box.position.x, area.position.x + LABEL_PAD_PX, area.end.x - box.size.x - LABEL_PAD_PX) \
		- box.position.x
	box.position.x += dx
	at.x += dx
	for k in _n_placed:
		if _placed[k].intersects(box):
			return
	if _n_placed < _placed.size():
		_placed[_n_placed] = box
		_n_placed += 1
	draw_rect(box.grow(LABEL_PAD_PX), COL_LABEL_BG)
	_draw_lines(at, _lines, _colors, _fs(FONT_SIZE), true)


func _area() -> Rect2:
	return safe_rect if safe_rect.has_area() else Rect2(Vector2.ZERO, size)


func _fs(base: int) -> int:
	return roundi(float(base) * text_scale)


func _add_line(text: String, col: Color) -> void:
	_lines.append(text)
	_colors.append(col)


func _text_box(at: Vector2, lines: PackedStringArray, font_size: int) -> Rect2:
	var lh := float(font_size) + 2.0
	var w := 0.0
	for line in lines:
		w = maxf(w, _font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var hgt := lh * float(lines.size())
	return Rect2(at.x - w * 0.5, at.y - hgt, w, hgt)


## One side of the MOBIL readout: "-" no lane, "x <reason>" refused (P = because of
## the player), else the margin incentive - threshold (> 0 = MOBIL would go).
func _side_text(side: String, r: MobilProbe.Result) -> String:
	if r.refusal == MobilProbe.Refusal.NO_LANE:
		return "%s -" % side
	if r.refusal != MobilProbe.Refusal.NONE:
		return "%s x %s%s" % [side, MobilProbe.REFUSAL_NAMES[r.refusal], " P" if r.refusal_is_player else ""]
	return "%s %+.2f" % [side, r.margin()]


func _decision_text(i: int) -> String:
	var dir := "<" if _dec_to[i] < sim.state.lane[i] or (_dec_to[i] == sim.state.lane[i]
		and sim.state.has_flag(i, TrafficState.FLAG_BLINKER_LEFT)) else ">"
	if _dec_split[i] == 1:
		return "last %s split: %s" % [dir, OUTCOME_NAMES[_dec_outcome[i]]]
	if _dec_requested[i] == 1:
		return "last %sL%d requested: %s" % [dir, _dec_to[i], OUTCOME_NAMES[_dec_outcome[i]]]
	return "last %sL%d inc %+.2f th %+.2f: %s" % [dir, _dec_to[i], _dec_inc[i], _dec_th[i],
		OUTCOME_NAMES[_dec_outcome[i]]]


func _accel_color(a: float, i: int) -> Color:
	var b := sim.registry.b_comfort[sim.state.profile_id[i]]
	if a < -b:
		return COL_BAD
	if a < -ACCEL_WARN_MPS2:
		return COL_WARN
	return COL_TEXT


func _link_color(a: float, i: int) -> Color:
	var b := sim.registry.b_comfort[sim.state.profile_id[i]]
	if a < -b:
		return COL_BAD
	if a < -ACCEL_WARN_MPS2:
		return COL_WARN
	return COL_LINK


func _draw_lines(at: Vector2, lines: PackedStringArray, colors: PackedColorArray, font_size: int, centered: bool) -> void:
	var lh := float(font_size) + 2.0
	var y := at.y - lh * float(lines.size())
	for k in lines.size():
		var w := _font.get_string_size(lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x := at.x - w * 0.5 if centered else at.x
		var pos := Vector2(x, y + lh * float(k) + float(font_size) - 2.0)
		draw_string_outline(_font, pos, lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, OUTLINE_PX, COL_OUTLINE)
		draw_string(_font, pos, lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colors[k])


## Leader link: from the car's front to the leader's rear, colored by the car's accel.
func _draw_link(i: int) -> void:
	var st := sim.state
	var lead := sim.leader_of(i)
	if lead < 0:
		return
	var s0 := st.s[i] + st.length[i] * 0.5
	var d0 := st.d[i]
	var s1: float
	var d1: float
	if lead == sim.player_index():
		s1 = player.s - player_length_m * 0.5
		d1 = player.d
	elif st.active[lead] == 1:
		s1 = st.s[lead] - st.length[lead] * 0.5
		d1 = st.d[lead]
	else:
		return
	_line_sd(s0, d0, s1, d1, LINK_LIFT_M, _link_color(st.accel[i], i))


## Signaling cars: their target space (body at the target d).
func _draw_targets() -> void:
	var st := sim.state
	for i in st.capacity:
		if st.active[i] == 0 or st.lc_state[i] != TrafficState.LaneChange.SIGNALING:
			continue
		var td := probe.move_target_d(i)
		_box_sd(st.s[i], td, st.length[i], st.width[i], BOX_LIFT_M, COL_BLINK, Color(0, 0, 0, 0))


## No-ambush prediction: the player's grown box now and at the end of the window.
func _draw_occupancy() -> void:
	var t := sim.tuning
	probe.set_player(player)
	var win := t.no_ambush_window_s
	var m := t.no_ambush_margin_m
	var cy := cos(player.yaw)
	var sy := sin(player.yaw)
	var kappa := road.curvature_at(player.s)
	var sdot := (player.v * cy - player.v_lat * sy) / (1.0 - kappa * player.d)
	var ddot := player.v * sy + player.v_lat * cy
	var ln := player_length_m + m * 2.0
	var wd := player_width_m + m * 2.0
	_box_sd(player.s, player.d, ln, wd, BOX_LIFT_M, COL_OCC, COL_OCC_FILL)
	var s1 := player.s + sdot * win
	var d1 := player.d + ddot * win
	_box_sd(s1, d1, ln, wd, BOX_LIFT_M, COL_OCC, COL_OCC_FILL)
	# Swept hull edges (corner to corner).
	for cs: float in [-0.5, 0.5]:
		for cd: float in [-0.5, 0.5]:
			_line_sd(player.s + ln * cs, player.d + wd * cd, s1 + ln * cs, d1 + wd * cd, BOX_LIFT_M, COL_OCC)
	var at := _world(s1 + ln * 0.5, d1, BOX_LIFT_M)
	if not camera.is_position_behind(at):
		_draw_lines(camera.unproject_position(at), PackedStringArray(["no-ambush %.1fs" % win]),
			PackedColorArray([COL_OCC]), _fs(SMALL_FONT_SIZE), true)


func _draw_passability() -> void:
	for path in passability_paths:
		for k in range(1, path.size()):
			_line_sd(path[k - 1].x, path[k - 1].y, path[k].x, path[k].y, BOX_LIFT_M, COL_PASS)
	for k in range(1, player_path.size()):
		_line_sd(player_path[k - 1].x, player_path[k - 1].y, player_path[k].x, player_path[k].y, BOX_LIFT_M,
			COL_PASS_PLAYER)
	var at := _world(player.s + player_length_m, player.d, BOX_LIFT_M)
	if camera.is_position_behind(at):
		return
	var text := "passability: %s  (%d batch paths)" % ["path" if player_path_ok else "NO PATH",
		passability_paths.size()]
	if not player_path_note.is_empty():
		text += "  " + player_path_note
	_draw_lines(camera.unproject_position(at) + Vector2(0.0, float(_fs(FONT_SIZE)) * 3.0),
		PackedStringArray([text]), PackedColorArray([COL_PASS_PLAYER if player_path_ok else COL_BAD]),
		_fs(SMALL_FONT_SIZE), true)


func _draw_selected() -> void:
	var st := sim.state
	var i := selected_slot
	_box_sd(st.s[i], st.d[i], st.length[i] + 1.0, st.width[i] + 1.0, BOX_LIFT_M, COL_SELECT, Color(0, 0, 0, 0))
	probe.set_player(player)
	_probe_both(i, _sel_left, _sel_right)
	var p := sim.registry.profiles[st.profile_id[i]]
	var lines := PackedStringArray()
	lines.append("#%d %s (%s) slot %d  lane %d" % [st.vehicle_id[i], String(p.id),
		String(sim.registry.types[st.type_id[i]].id), i, st.lane[i]])
	lines.append("v %.0f  v0 %.0f km/h  a %+.2f  idm %+.2f" % [Units.mps_to_kmh(st.v[i]),
		Units.mps_to_kmh(st.v0[i]), st.accel[i], sim.idm_accel(i)])
	lines.append("leader %s  gap %.1f m" % [_who(sim.leader_of(i)), sim.leader_gap(i)])
	lines.append("p %.2f  a_th %.2f  a_bias %.2f  b_safe %.1f" % [sim.registry.politeness[st.profile_id[i]],
		sim.registry.a_threshold[st.profile_id[i]], sim.registry.a_bias[st.profile_id[i]],
		sim.registry.b_safe[st.profile_id[i]]])
	for r: MobilProbe.Result in [_sel_left, _sel_right]:
		var side := "RIGHT" if r.to_right else "LEFT"
		if r.refusal == MobilProbe.Refusal.NO_LANE:
			lines.append("%s: no lane" % side)
			continue
		lines.append("%s -> L%d: %s%s" % [side, r.target_lane, MobilProbe.REFUSAL_NAMES[r.refusal],
			" (player)" if r.refusal_is_player else ""])
		lines.append("  c %+.2f -> %+.2f  lead %s" % [r.a_c, r.a_c_new, _who(r.lead)])
		lines.append("  n %+.2f -> %+.2f  foll %s  b_safe %.1f" % [r.a_n, r.a_n_new, _who(r.follower), r.b_safe])
		lines.append("  o %+.2f -> %+.2f  old %s" % [r.a_o, r.a_o_new, _who(r.old_follower)])
		lines.append("  inc %+.3f  th %+.3f (bias %.2f)  %s" % [r.incentive, r.threshold, r.bias,
			"GO" if r.accepts() else "stay"])
	if _dec_id[i] == st.vehicle_id[i] and _dec_outcome[i] != Outcome.NONE:
		lines.append(_decision_text(i))
	var colors := PackedColorArray()
	colors.resize(lines.size())
	colors.fill(COL_TEXT)
	var fs := _fs(SMALL_FONT_SIZE)
	var lh := float(fs) + 2.0
	var w := 0.0
	for line in lines:
		w = maxf(w, _font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var x := _area().end.x - w - PANEL_MARGIN_PX
	var rect := Rect2(x - 8.0, PANEL_TOP_PX, w + 16.0, lh * float(lines.size()) + 12.0)
	draw_rect(rect, COL_PANEL)
	_draw_lines(Vector2(x, PANEL_TOP_PX + 6.0 + lh * float(lines.size())), lines, colors, fs, false)


func _who(j: int) -> String:
	if j < 0:
		return "none"
	if j == sim.player_index():
		return "PLAYER"
	return "#%d" % sim.state.vehicle_id[j]


# ---------------------------------------------------------------- Road-space helpers

func _height(i: int) -> float:
	return sim.registry.types[sim.state.type_id[i]].height_m


func _world(s: float, d: float, h: float) -> Vector3:
	road.sample_into(s, _smp)
	return _smp.local_point(d, origin.origin_x, origin.origin_y, origin.origin_z) + _smp.up * h


func _line_sd(s0: float, d0: float, s1: float, d1: float, h: float, col: Color) -> void:
	var a := _world(s0, d0, h)
	var b := _world(s1, d1, h)
	if camera.is_position_behind(a) or camera.is_position_behind(b):
		return
	draw_line(camera.unproject_position(a), camera.unproject_position(b), col, LINE_PX, true)


## Box outline (and optional fill) of length x width centered at (s, d).
func _box_sd(s: float, d: float, ln: float, wd: float, h: float, edge: Color, fill: Color) -> void:
	var pts := PackedVector2Array()
	for c: Vector2 in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
		var p := _world(s + ln * c.x, d + wd * c.y, h)
		if camera.is_position_behind(p):
			return
		pts.append(camera.unproject_position(p))
	if fill.a > 0.0:
		draw_colored_polygon(pts, fill)
	pts.append(pts[0])
	draw_polyline(pts, edge, LINE_PX, true)
