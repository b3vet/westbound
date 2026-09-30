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
## - Collisions (WP9.6, as the Rust soak's N4.1 criterion): two cars collide when their
##   boxes overlap as the sim moves them (un-yawed bodies) or as clients draw them
##   (TrafficViewTuning's heading: atan2(v_lat, max(v, yaw_min_speed)) within +-yaw_max:
##   view_yaw()), inset by LivesTuning.collision_inset_m, separating-axis test. The older
##   heading (atan2(v_lat, v) within +-MAX_BOX_YAW_RAD: box_yaw()) is still evaluated and
##   reported as yaw_only_pairs, not gated: it turns a crawling 16 m semi far enough to
##   "touch" a car a lane over that the sim and the view never bring near it (ACCEPTANCE
##   F1). Player contacts keep box_yaw().
## - On the road (WP6.2, lane drops): every car's body stays between the left edge of
##   lane 0 and the right edge of the driving lanes at its s (lanes_left_edge_d /
##   lanes_right_edge_d, which follow a lane drop's taper), within OFFROAD_TOL_M.
## - Deceleration clamp and brake-light thresholds, every tick, every car. Rule 4's one
##   exception (WP6.2): "except in set pieces announced at least 300 m ahead". A car may
##   brake beyond the clamp only if it carries FLAG_SCRIPTED, `set_piece_of` maps it to a
##   set piece, and that piece's first warning (note_set_piece_warning, from the event
##   buffer) came when the player was at least DirectorTuning.set_piece_min_warning_m
##   from the nearest of the piece's cars, as measured here from TrafficState.

const AMBUSH_SAMPLE_S := 0.005
const LATERAL_EPS := 1e-9
const MAX_MESSAGES := 8
## Numerical slack of the on-the-road check (m).
const OFFROAD_TOL_M := 0.05
## WP6.8: the steepest heading a traffic box gets. The sim's lateral move is timed (the
## spec's 1.5-3 s), not steered, so a car moving sideways while nearly stopped had a
## box heading atan2(v_lat, max(v, 0.1)) of up to ~85 degrees: a 12 m coach crossing two
## lanes, counting collisions with cars that were never touched. A real car's heading in
## a lane change is its path's slope; the quickest move (1.5 s, smoothstep over a 3.6 m
## lane: peak v_lat 3.6 m/s) at 45 km/h is atan(3.6 / 12.5) = 0.28 rad. Above that speed
## nothing changes. The boxes still move with d, so a car that moves sideways into
## another still overlaps it (test_traffic_rule_checker_box_heading).
const MAX_BOX_YAW_RAD := 0.28

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
var collision_pairs := 0       ## pair-ticks: body or view-heading overlap (the gate)
## Pair-ticks whose un-yawed bodies overlap (a subset of collision_pairs).
var body_overlap_pairs := 0
## Reported, not gated: pair-ticks that overlap only with box_yaw()'s heading (WP6.8's
## +-MAX_BOX_YAW_RAD), and the faster car's top speed among them (m/s).
var yaw_only_pairs := 0
var yaw_only_max_speed := 0.0
## Where the last traffic-to-traffic collision was (s of its first vehicle; NAN: none yet).
var last_collision_s := NAN
var player_contacts := 0       ## ticks with a traffic-player overlap
var rear_end_contacts := 0     ## ... where the car's center is behind the player's
## Contact episodes (a car touching the player, counted once per touch).
var contact_episodes := 0
var rear_end_episodes := 0     ## ... started with the car's center behind the player's
## ... of a player driving normally: no lateral motion and no braking beyond the traffic
## clamp for `quiet_s` before the touch (Lives → rear-end prevention). Must stay 0.
var rear_end_normal := 0
## Slots whose contact with the player started this tick (the caller may notify_hit them).
var contacts_started := PackedInt32Array()
var quiet_s: float
var decel_violations := 0
## Ticks x cars with a body outside the driving lanes (WP6.2).
var offroad_violations := 0
var brake_flag_violations := 0
var brake_seen := 0
var brake_strong_seen := 0
var min_accel := 0.0
var messages := PackedStringArray()
## Set pieces (rule 4): slot -> the serial of its set piece (-1 = none). Unset: every
## deceleration beyond the clamp is a violation. The soak binds
## SetPieceSource.instance_of.
var set_piece_of: Callable
## Beyond-the-clamp decelerations allowed as a warned set piece's (reported).
var set_piece_hard_decels := 0

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
var _touch := PackedByteArray()      # in contact with the player at the last observe
var _touch_vid := PackedInt32Array()
var _prev_pd := NAN
var _last_lateral_t := -INF
var _last_hard_brake_t := -INF
var _time := 0.0
var _min_warning: float
var _view_min_v: float
var _view_max: float
var _warned_m: Dictionary = {}       # set-piece serial -> measured distance at its first warning


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
	quiet_s = traffic_tuning.soak_normal_driving_quiet_s
	_min_warning = t.director.set_piece_min_warning_m
	_view_min_v = t.traffic_view.yaw_min_speed_mps()
	_view_max = deg_to_rad(t.traffic_view.yaw_max_deg)


## A set piece's warning event (SetPieceSource.KIND_WARNING, serial in `points`): the
## first one per piece records the player's distance to the nearest of the piece's cars
## (rear box edge), measured here from TrafficState.
func note_set_piece_warning(serial: int, ts: TrafficState, player: VehicleState) -> void:
	if _warned_m.has(serial) or not set_piece_of.is_valid():
		return
	var d := INF
	for i in ts.capacity:
		if ts.active[i] == 1 and int(set_piece_of.call(i)) == serial:
			d = minf(d, ts.s[i] - ts.length[i] * 0.5 - player.s)
	_warned_m[serial] = d


## The measured distance of a set piece's first warning (-INF = never warned).
func set_piece_warned_m(serial: int) -> float:
	return float(_warned_m.get(serial, -INF))


## Time of the player's last lateral motion (-INF = never).
func player_last_lateral_t() -> float:
	return _last_lateral_t


func total_violations() -> int:
	return signal_violations + unsignaled_moves + ambush_violations + collisions + decel_violations \
		+ brake_flag_violations + offroad_violations


func summary() -> String:
	return ("signals %d moves %d cancels %d | violations: signal %d unsignaled %d ambush %d collisions %d "
		+ "(heading-only %d pair-ticks, reported) decel %d brake-flags %d | player contacts %d (rear-end %d) episodes %d "
		+ "(rear-end %d, normal driving %d)") % [
			signals, moves, cancels, signal_violations, unsignaled_moves, ambush_violations, collisions,
			yaw_only_pairs, decel_violations, brake_flag_violations, player_contacts, rear_end_contacts, contact_episodes,
			rear_end_episodes, rear_end_normal]


func observe(time: float, ts: TrafficState, player: VehicleState) -> void:
	_time = time
	contacts_started.clear()
	if absf(player.d - _prev_pd) > LATERAL_EPS or absf(player.v_lat) > LATERAL_EPS:
		_last_lateral_t = time
	if player.accel_long < -_clamp - 1e-9:
		_last_hard_brake_t = time
	_prev_pd = player.d
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
	var hw := ts.width[i] * 0.5
	if ts.d[i] + hw > road.lanes_right_edge_d(ts.s[i]) + OFFROAD_TOL_M \
			or ts.d[i] - hw < road.lanes_left_edge_d(ts.s[i]) - OFFROAD_TOL_M:
		offroad_violations += 1
		_msg("t=%.3f slot %d (lane %d, d %.2f) outside the driving lanes at s %.1f (%d lanes, right edge %.2f)" % [
			time, i, ts.lane[i], ts.d[i], ts.s[i], road.lane_count(ts.s[i]), road.lanes_right_edge_d(ts.s[i])])
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
	if a < -_clamp - 1e-9:
		var sp := -1
		if (f & TrafficState.FLAG_SCRIPTED) != 0 and set_piece_of.is_valid():
			sp = int(set_piece_of.call(i))
		if sp >= 0 and set_piece_warned_m(sp) >= _min_warning - 1e-6:
			set_piece_hard_decels += 1
		else:
			decel_violations += 1
			_msg("t=%.3f slot %d decel %.3f beyond the clamp (%s)" % [time, i, -a,
				"set piece %d warned at %.1f m" % [sp, set_piece_warned_m(sp)] if sp >= 0 else "not a warned set piece"])
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
			var body := _overlap(ts.s[i], ts.d[i], ts.length[i], ts.width[i], 0.0,
					ts.s[j], ts.d[j], ts.length[j], ts.width[j], 0.0)
			var seen := body or _overlap(ts.s[i], ts.d[i], ts.length[i], ts.width[i], view_yaw(ts.v[i], ts.v_lat[i]),
					ts.s[j], ts.d[j], ts.length[j], ts.width[j], view_yaw(ts.v[j], ts.v_lat[j]))
			if body:
				body_overlap_pairs += 1
			if not seen and _overlap(ts.s[i], ts.d[i], ts.length[i], ts.width[i], box_yaw(ts.v[i], ts.v_lat[i]),
					ts.s[j], ts.d[j], ts.length[j], ts.width[j], box_yaw(ts.v[j], ts.v_lat[j])):
				yaw_only_pairs += 1
				yaw_only_max_speed = maxf(yaw_only_max_speed, maxf(ts.v[i], ts.v[j]))
			if seen:
				collision_pairs += 1
				last_collision_s = ts.s[i]
				hit_tick = true
				_msg("collision slots %d/%d at s=%.1f d=%.2f/%.2f" % [i, j, ts.s[i], ts.d[i], ts.d[j]])
	if hit_tick:
		collisions += 1
	if _touch.size() != ts.capacity:
		_touch.resize(ts.capacity)
		_touch.fill(0)
		_touch_vid.resize(ts.capacity)
	var p_contact := false
	for i in ts.capacity:
		var touching := false
		if ts.active[i] == 1 and absf(ts.s[i] - player.s) < (ts.length[i] + player_length) * 0.5 \
				and _overlap(ts.s[i], ts.d[i], ts.length[i], ts.width[i], box_yaw(ts.v[i], ts.v_lat[i]),
				player.s, player.d, player_length, player_width, player.yaw):
			touching = true
			p_contact = true
			var rear := ts.s[i] < player.s
			if rear:
				rear_end_contacts += 1
			if _touch[i] == 0 or _touch_vid[i] != ts.vehicle_id[i]:
				contact_episodes += 1
				contacts_started.append(i)
				if rear:
					rear_end_episodes += 1
					if _time - _last_lateral_t >= quiet_s and _time - _last_hard_brake_t >= quiet_s:
						rear_end_normal += 1
						_msg("t=%.3f slot %d rear-ended a player driving normally (gap %.2f m, dv %.2f m/s)" % [
							_time, i, player.s - ts.s[i] - (ts.length[i] + player_length) * 0.5, ts.v[i] - player.v])
		_touch[i] = 1 if touching else 0
		_touch_vid[i] = ts.vehicle_id[i]
	if p_contact:
		player_contacts += 1


## A traffic car's heading as TrafficView draws it: atan2(v_lat, max(v, yaw_min_speed))
## within +-yaw_max (TrafficViewTuning; the Rust checker's view_yaw).
func view_yaw(v: float, v_lat: float) -> float:
	return clampf(atan2(v_lat, maxf(v, _view_min_v)), -_view_max, _view_max)


## A traffic box's heading in road space: atan2(v_lat, v), clamped to
## +-MAX_BOX_YAW_RAD (see there). Gates player contacts; reported only for traffic pairs.
static func box_yaw(v: float, v_lat: float) -> float:
	return clampf(atan2(v_lat, maxf(v, 0.0)), -MAX_BOX_YAW_RAD, MAX_BOX_YAW_RAD)


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
