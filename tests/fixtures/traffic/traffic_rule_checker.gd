class_name TrafficRuleChecker
extends RefCounted
## Independent observer of the traffic fairness rules (not a test suite). It reads only
## the published TrafficState and the player's VehicleState once per tick, and
## re-derives each rule from the spec's wording with its own code (no TrafficSim,
## NoAmbush or Idm calls). Spec: Traffic → Fairness rules 1-4; Tests (headless):
## "zero lane changes shorter than the minimum signal time, and zero no-ambush
## violations"; soak "zero traffic-to-traffic collisions"; Lives → rear-end prevention.
##
## - Signal time: from the tick a blinker comes on to the first tick the car's d moves,
##   at least the profile's signal time (DriverProfile.signal_time_s, floored by
##   TrafficTuning.signal_time_floor_s). Lateral motion with no blinker (outside a hit
##   swerve) is a violation too.
## - No ambush: the car and the player are snapshotted on the tick a car enters MOVING
##   (the start of its lateral motion); when the move ends, the car's final d is its
##   target space. Sampling t in [0, window] every AMBUSH_SAMPLE_S, the car's body at
##   that d moving at its speed must not overlap the player's body moving at its
##   snapshotted road velocity, grown by the margin on every side.
## - Collisions: oriented boxes in road space (yaw = atan2(v_lat, v)) inset by
##   LivesTuning.collision_inset_m, separating-axis test.
## - Deceleration clamp and brake-light thresholds, every tick, every car.

const AMBUSH_SAMPLE_S := 0.005
const LATERAL_EPS := 1e-9
const MAX_MESSAGES := 8

var traffic_tuning: TrafficTuning
var registry: TrafficRegistry
var road: RoadPath
var inset: float
var player_length: float
var player_width: float

# Counters
var signals := 0
var moves := 0
var cancels := 0
var hesitant_signals := 0
var hesitant_cancels := 0
var signal_violations := 0
var unsignaled_moves := 0
var ambush_violations := 0
var collisions := 0            ## ticks with at least one traffic-traffic overlap
var collision_pairs := 0
var player_contacts := 0       ## ticks with a traffic-player overlap
var rear_end_contacts := 0     ## ... where the car's center is behind the player's
var decel_violations := 0
var brake_flag_violations := 0
var brake_seen := 0
var brake_strong_seen := 0
var min_accel := 0.0
var messages := PackedStringArray()

var _vid := PackedInt32Array()
var _blink_t := PackedFloat64Array()
var _blinking := PackedByteArray()
var _moved := PackedByteArray()
var _prev_d := PackedFloat64Array()
var _prev_lc := PackedInt32Array()
var _ord := PackedInt32Array()
var _amb := PackedByteArray()        # a move started; evaluate when it ends
var _amb_s := PackedFloat64Array()
var _amb_v := PackedFloat64Array()
var _amb_ps := PackedFloat64Array()
var _amb_pd := PackedFloat64Array()
var _amb_psd := PackedFloat64Array()
var _amb_pdd := PackedFloat64Array()
var lane_moves_checked := 0
var _n_ord := 0
var _clamp: float
var _brake: float
var _strong: float
var _in_list := PackedByteArray()
var _list_vid := PackedInt32Array()
var _max_len := 0.0


func _init(t: Tuning, reg: TrafficRegistry, road_path: RoadPath, p_length: float, p_width: float) -> void:
	traffic_tuning = t.traffic
	registry = reg
	road = road_path
	inset = t.lives.collision_inset_m
	player_length = p_length
	player_width = p_width
	_clamp = traffic_tuning.max_decel_mps2
	_brake = traffic_tuning.brake_light_decel_mps2
	_strong = traffic_tuning.brake_light_strong_decel_mps2
	for x in reg.length:
		_max_len = maxf(_max_len, x)


func total_violations() -> int:
	return signal_violations + unsignaled_moves + ambush_violations + collisions + decel_violations \
		+ brake_flag_violations


func summary() -> String:
	return ("signals %d moves %d cancels %d | violations: signal %d unsignaled %d ambush %d collisions %d "
		+ "decel %d brake-flags %d | player contacts %d (rear-end %d)") % [
			signals, moves, cancels, signal_violations, unsignaled_moves, ambush_violations, collisions,
			decel_violations, brake_flag_violations, player_contacts, rear_end_contacts]


func observe(time: float, ts: TrafficState, player: VehicleState) -> void:
	if _vid.size() != ts.capacity:
		_vid.resize(ts.capacity)
		_vid.fill(0)
		_blink_t.resize(ts.capacity)
		_blinking.resize(ts.capacity)
		_moved.resize(ts.capacity)
		_prev_d.resize(ts.capacity)
		_prev_lc.resize(ts.capacity)
		for a: String in ["_amb_s", "_amb_v", "_amb_ps", "_amb_pd", "_amb_psd", "_amb_pdd"]:
			var arr := PackedFloat64Array()
			arr.resize(ts.capacity)
			set(a, arr)
		_amb.resize(ts.capacity)
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		if _vid[i] != ts.vehicle_id[i]:
			_vid[i] = ts.vehicle_id[i]
			_blinking[i] = 0
			_moved[i] = 0
			_prev_d[i] = ts.d[i]
			_prev_lc[i] = ts.lc_state[i]
			_amb[i] = 0
		_check_car(time, ts, i, player)
	_check_boxes(ts, player)


func _check_car(time: float, ts: TrafficState, i: int, player: VehicleState) -> void:
	var f := ts.flags[i]
	var blink := (f & (TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BLINKER_RIGHT)) != 0
	var hit := (f & TrafficState.FLAG_HIT) != 0
	var pid := ts.profile_id[i]
	if blink and _blinking[i] == 0:
		_blinking[i] = 1
		_moved[i] = 0
		_blink_t[i] = time
		signals += 1
		if registry.profiles[pid].cancel_probability > 0.0:
			hesitant_signals += 1
	elif not blink and _blinking[i] == 1:
		_blinking[i] = 0
		if _moved[i] == 0:
			cancels += 1
			if registry.profiles[pid].cancel_probability > 0.0:
				hesitant_cancels += 1
	if absf(ts.d[i] - _prev_d[i]) > LATERAL_EPS and not hit:
		if not blink:
			unsignaled_moves += 1
			_msg("t=%.3f slot %d moved laterally with no blinker" % [time, i])
		elif _moved[i] == 0:
			_moved[i] = 1
			moves += 1
			var prof := registry.profiles[pid]
			var need := maxf(prof.signal_time_s, traffic_tuning.signal_time_floor_s)
			var had := time - _blink_t[i]
			if had < need - 1e-9:
				signal_violations += 1
				_msg("t=%.3f slot %d (%s) moved after %.3f s of signal < %.3f s" % [time, i, prof.id, had, need])
	_prev_d[i] = ts.d[i]
	# Start of a lateral move: snapshot; judge it once its final d is known.
	var moving := ts.lc_state[i] == TrafficState.LaneChange.MOVING
	var was_moving := _prev_lc[i] == TrafficState.LaneChange.MOVING
	if moving and not was_moving:
		_amb[i] = 1
		_amb_s[i] = ts.s[i]
		_amb_v[i] = ts.v[i]
		_amb_ps[i] = player.s
		_amb_pd[i] = player.d
		_amb_psd[i] = player.v * cos(player.yaw) - player.v_lat * sin(player.yaw)
		_amb_pdd[i] = player.v * sin(player.yaw) + player.v_lat * cos(player.yaw)
	elif was_moving and not moving and _amb[i] == 1:
		_amb[i] = 0
		lane_moves_checked += 1
		if _ambush(ts, i):
			ambush_violations += 1
			_msg("t=%.3f slot %d started a lateral move into the player's predicted space" % [time, i])
	_prev_lc[i] = ts.lc_state[i]
	# Deceleration clamp and brake lights.
	var a := ts.accel[i]
	min_accel = minf(min_accel, a)
	if (f & TrafficState.FLAG_SCRIPTED) == 0 and a < -_clamp - 1e-9:
		decel_violations += 1
		_msg("t=%.3f slot %d decel %.3f beyond the clamp" % [time, i, -a])
	var want_brake := -a > _brake
	var want_strong := -a > _strong
	if want_brake != ((f & TrafficState.FLAG_BRAKE) != 0) or want_strong != ((f & TrafficState.FLAG_BRAKE_STRONG) != 0):
		brake_flag_violations += 1
		_msg("t=%.3f slot %d brake flags do not match decel %.3f" % [time, i, -a])
	if want_brake:
		brake_seen += 1
	if want_strong:
		brake_strong_seen += 1


func _ambush(ts: TrafficState, i: int) -> bool:
	var window := traffic_tuning.no_ambush_window_s
	var m := traffic_tuning.no_ambush_margin_m
	var target_d := ts.d[i]
	var half_s := (ts.length[i] + player_length) * 0.5 + m
	var half_d := (ts.width[i] + player_width) * 0.5 + m
	var n := ceili(window / AMBUSH_SAMPLE_S)
	for k in n + 1:
		var t := window * float(k) / float(n)
		var ds := (_amb_ps[i] + _amb_psd[i] * t) - (_amb_s[i] + _amb_v[i] * t)
		var dd := (_amb_pd[i] + _amb_pdd[i] * t) - target_d
		if absf(ds) < half_s and absf(dd) < half_d:
			return true
	return false


func _check_boxes(ts: TrafficState, player: VehicleState) -> void:
	# Live slots by s: a persistent list (nearly sorted from tick to tick, so the
	# insertion sort is ~O(n)); drop freed or reused slots, append new ones.
	if _in_list.size() != ts.capacity:
		_in_list.resize(ts.capacity)
		_in_list.fill(0)
		_list_vid.resize(ts.capacity)
		_ord.resize(ts.capacity)
		_n_ord = 0
	var w := 0
	for k in _n_ord:
		var i := _ord[k]
		if ts.active[i] == 1 and ts.vehicle_id[i] == _list_vid[i]:
			_ord[w] = i
			w += 1
		else:
			_in_list[i] = 0
	_n_ord = w
	for i in ts.capacity:
		if ts.active[i] == 1 and (_in_list[i] == 0 or _list_vid[i] != ts.vehicle_id[i]):
			if _in_list[i] == 0:
				_ord[_n_ord] = i
				_n_ord += 1
			_in_list[i] = 1
			_list_vid[i] = ts.vehicle_id[i]
	var n := _n_ord
	for k in range(1, n):
		var x := _ord[k]
		var m := k - 1
		while m >= 0 and ts.s[_ord[m]] > ts.s[x]:
			_ord[m + 1] = _ord[m]
			m -= 1
		_ord[m + 1] = x
	var hit_tick := false
	for a in n:
		var i := _ord[a]
		for b in range(a + 1, n):
			var j := _ord[b]
			if ts.s[j] - ts.s[i] >= (ts.length[i] + _max_len) * 0.5:
				break
			if ts.s[j] - ts.s[i] >= (ts.length[i] + ts.length[j]) * 0.5:
				continue
			if _overlap(ts.s[i], ts.d[i], ts.length[i], ts.width[i], atan2(ts.v_lat[i], maxf(ts.v[i], 0.1)),
					ts.s[j], ts.d[j], ts.length[j], ts.width[j], atan2(ts.v_lat[j], maxf(ts.v[j], 0.1))):
				collision_pairs += 1
				hit_tick = true
				_msg("collision slots %d/%d at s=%.1f d=%.2f/%.2f" % [i, j, ts.s[i], ts.d[i], ts.d[j]])
	if hit_tick:
		collisions += 1
	var p_contact := false
	for a in n:
		var i := _ord[a]
		if absf(ts.s[i] - player.s) >= (ts.length[i] + player_length) * 0.5:
			continue
		if _overlap(ts.s[i], ts.d[i], ts.length[i], ts.width[i], atan2(ts.v_lat[i], maxf(ts.v[i], 0.1)),
				player.s, player.d, player_length, player_width, player.yaw):
			p_contact = true
			if ts.s[i] < player.s:
				rear_end_contacts += 1
	if p_contact:
		player_contacts += 1


## Oriented boxes (center s, d; full length, width; yaw) inset on every side. SAT.
func _overlap(s1: float, d1: float, l1: float, w1: float, y1: float,
		s2: float, d2: float, l2: float, w2: float, y2: float) -> bool:
	var hl1 := l1 * 0.5 - inset
	var hw1 := w1 * 0.5 - inset
	var hl2 := l2 * 0.5 - inset
	var hw2 := w2 * 0.5 - inset
	var c1 := cos(y1)
	var n1 := sin(y1)
	var c2 := cos(y2)
	var n2 := sin(y2)
	var ts := s2 - s1
	var td := d2 - d1
	# Axes: box 1 forward (c1, n1), side (-n1, c1); box 2 likewise.
	var axes := [c1, n1, -n1, c1, c2, n2, -n2, c2]
	for k in 4:
		var us: float = axes[2 * k]
		var ud: float = axes[2 * k + 1]
		var r1 := hl1 * absf(c1 * us + n1 * ud) + hw1 * absf(-n1 * us + c1 * ud)
		var r2 := hl2 * absf(c2 * us + n2 * ud) + hw2 * absf(-n2 * us + c2 * ud)
		if absf(ts * us + td * ud) > r1 + r2:
			return false
	return true


func _msg(text: String) -> void:
	if messages.size() < MAX_MESSAGES:
		messages.append(text)
