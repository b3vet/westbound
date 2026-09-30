class_name PassabilityBot
extends TrafficBotPlayer
## Bot driver on passability's path (spec: Traffic → Passability guarantee, "The same
## module runs in tests with a bot driver"; Tests (headless): "10,000 simulated km with a
## bot driver produce zero impossible windows"). Not a test suite (no test_ prefix).
##
## A kinematic car in road space (yaw 0: v = ds/dt, v_lat = dd/dt) that traffic reads as
## the player participant: a TrafficBotPlayer (same interface: state, v_target,
## set_weave, keep_lane, update) that drives passability's path instead. Every replan_steps decision steps (Passability's
## step_s grid, so its lateral state is always a grid state at a replan) it runs
## Passability.check_player from its exact state and re-extracts the path with its own
## preferences: its target speed (per leg), a target lane (WEAVE: a new random lane every
## few seconds; KEEP: its own lane). Between replans it drives that path exactly: s and d
## linear between the path's points (a straight segment in (t, s) per step, the case the
## search proves collision-free; d stays within the occupied positions). Speed changes
## are those the path takes (kept within the traffic's comfortable clamp when the good
## set allows).
##
## Without a path (the prediction and the live traffic diverged, or it started in a
## hopeless spot) it settles in the lane holding its center (aborting a lane change) and
## follows the vehicle ahead with IDM, and counts it (no_path_checks). It only reads the published TrafficState.
##
## WP6.10 (the M6 gate soak's toll windows): it reads a toll's booth lanes as closed
## (BoothClosures) and leaves a lane that ends, closes or turns into a booth lane early
## (a check pinned one step into the move toward the open lane, at that lane's pace).

## Replan every this many decision steps (0.5 s at step_s 0.25).
const REPLAN_STEPS := 2
## Time headway kept behind what is ahead on the path (a sensible player; the search
## itself allows the clearance alone, since any speed down to the minimum is allowed).
const HEADWAY_S := 1.0
## Leaving a lane that ends: the pace of the open lane is its nearest vehicle this far ahead.
const PACE_AHEAD_M := 150.0
## ... and with a vehicle beside it in the open lane (or ahead closer than HEADWAY_S), it
## drops back this much slower than that vehicle.
const PACE_DROP_BACK_MPS := 3.0
## Fallback following (no path): a pushy player's IDM, the car's braking.
const IDM_A := 3.0
const IDM_B := 4.0
const IDM_T := 0.8
const IDM_S0 := 2.0
const BRAKE := 9.0

## WP6.10: the sim's closures and zones as the bot's passability reads them, plus the
## booth lanes of a toll (a speed zone below the minimum speed) closed from BOOTH_LEAD_M
## before their traffic drops below the minimum speed: like a player reading the TOLL
## legends, the bot plans its way into the express lanes early instead of driving a booth
## lane until the search's braking relaxation has it brake to the minimum at the booths
## (gate soak, runs 36, 44 and 64: three windows behind 50 km/h booth traffic).
class BoothClosures extends RefCounted:
	var sim: Object
	var a := PackedFloat64Array()   # per lane: booth closure start (INF: none)
	var b := PackedFloat64Array()
	var n := 0

	func _init() -> void:
		a.resize(MAX_LANES)
		b.resize(MAX_LANES)
		a.fill(INF)

	## Re-reads the booth lanes over [s_from, s_to] for `lanes` lanes. The closure of the
	## bot's own lane never starts behind `s_from + escape_m`: a bot that could not leave
	## in time still gets a path out as soon as a gap opens (instead of being inside a
	## closure, without any path, until the booths). Allocation-free.
	func refresh(lanes: int, s_from: float, s_to: float, v_min: float, own_lane: int, escape_m: float) -> void:
		n = 0
		a.fill(INF)
		if sim == null or int(sim.call(&"speed_zone_count")) == 0:
			return
		for lane in mini(lanes, MAX_LANES):
			var x := s_from
			while x <= s_to:
				var slow := float(sim.call(&"speed_limit_at", lane, x, 0)) < v_min
				if slow and is_inf(a[lane]):
					a[lane] = x - BOOTH_LEAD_M
					n += 1
				if slow:
					b[lane] = x
				elif is_finite(a[lane]):
					break
				x += BOOTH_SAMPLE_M
		if own_lane >= 0 and own_lane < MAX_LANES and is_finite(a[own_lane]):
			a[own_lane] = maxf(a[own_lane], s_from + escape_m)
			if a[own_lane] > b[own_lane]:
				a[own_lane] = INF
				n -= 1

	func lane_closure_count() -> int:
		return n + (int(sim.call(&"lane_closure_count")) if sim != null else 0)

	func closure_ahead(lane: int, s: float) -> float:
		var d := float(sim.call(&"closure_ahead", lane, s)) if sim != null else INF
		if lane < MAX_LANES and is_finite(a[lane]) and b[lane] >= s:
			d = minf(d, maxf(a[lane] - s, 0.0))
		return d

	func speed_zone_count() -> int:
		return int(sim.call(&"speed_zone_count")) if sim != null else 0

	func speed_limit_at(lane: int, front: float, p: int) -> float:
		return float(sim.call(&"speed_limit_at", lane, front, p)) if sim != null else INF


## Booth lanes (BoothClosures): lanes read, sampling step, how far before the booth
## traffic drops below the minimum speed the bot treats the lane as closed, and how far
## ahead it looks.
const MAX_LANES := 8
const BOOTH_SAMPLE_M := 10.0
const BOOTH_LEAD_M := 250.0
const BOOTH_LOOK_M := 900.0
## A bot still in a booth lane: its closure starts at least this far beyond its body.
const BOOTH_ESCAPE_M := 10.0

var params: VehicleParams
var booths := BoothClosures.new()
var _v_min := 0.0
var passability: Passability
var result := Passability.Result.new()
var target_lane: int

# Counters
var checks := 0
var no_path_checks := 0
var check_usec := 0          ## wall time in Passability (not simulation state)

var _tick := 0
var _ticks_per_step := 30
var _plan_k := 0             ## decision step of the current path we are in
var _has_path := false
var _path_s := PackedFloat64Array()
var _path_d := PackedFloat64Array()
var _path_x := PackedInt32Array()
var _path_n := 0
var _x := -1                 ## lateral grid state at the last replan (a position or a move stage)
var _seg_t := 0              ## ticks into the current step
var _s0 := 0.0               ## segment start / end
var _s1 := 0.0
var _d0 := 0.0
var _d1 := 0.0
var _fallback := false


func _init(road_path: RoadPath, reg: TrafficRegistry, tuning: Tuning, car: CarDef, car_params: VehicleParams,
		start_lane: int, speed_mps: float, seed_value: int, start_s: float = 0.0) -> void:
	super(road_path, start_lane, speed_mps, Mode.WEAVE, seed_value, start_s)
	params = car_params
	_v_min = tuning.scoring.min_speed_mps()
	length_m = car.length_m
	width_m = car.width_m
	passability = Passability.new(tuning, reg, road)
	passability.set_player_body(length_m, width_m)
	target_lane = start_lane
	_next_weave = INF
	_ticks_per_step = roundi(passability.step_s() * float(tuning.vehicle.physics_tick_hz))
	_path_s.resize(passability.steps() + 1)
	_path_d.resize(passability.steps() + 1)
	_path_x.resize(passability.steps() + 1)


## The IDM headway scale the traffic uses (the director's leg scale), for the prediction.
func set_headway_scale(k: float) -> void:
	passability.set_headway_scale(k)


## Lane keeping (its target lane is always its own).
func keep_lane() -> void:
	mode = Mode.CRUISE
	_next_weave = INF
	target_lane = lane


## A new random target lane every [min_s, max_s] seconds (from now).
func set_weave(min_s: float, max_s: float) -> void:
	mode = Mode.WEAVE
	weave_min_s = min_s
	weave_max_s = max_s
	_next_weave = _clock + _rng.float_range(min_s, max_s)


## True while the bot's own lateral move runs.
func is_changing_lanes() -> bool:
	return absf(state.v_lat) > 0.0


func update(dt: float, traffic: TrafficState) -> void:
	_clock += dt
	if mode == Mode.WEAVE and _clock >= _next_weave:
		_next_weave = _clock + _rng.float_range(weave_min_s, weave_max_s)
		target_lane = _rng.int_range(0, road.lane_count(state.s) - 1)
	if _tick % _ticks_per_step == 0:
		_on_step_boundary(traffic)
	_tick += 1
	_seg_t += 1
	var u := float(_seg_t) / float(_ticks_per_step)
	var step := passability.step_s()
	var v_prev := state.v
	if _fallback:
		_follow(dt, traffic)
	else:
		state.s = _s0 + (_s1 - _s0) * u
		state.v = (_s1 - _s0) / step
	state.d = _d0 + (_d1 - _d0) * u
	state.v_lat = (_d1 - _d0) / step
	state.accel_long = (state.v - v_prev) / step if _seg_t == 1 else 0.0
	if _seg_t == 1 and _fallback:
		state.accel_long = (state.v - v_prev) / dt


## At every decision time: replan (every REPLAN_STEPS), then set up the next segment.
func _on_step_boundary(traffic: TrafficState) -> void:
	_seg_t = 0
	if _plan_k >= REPLAN_STEPS or not _has_path or _plan_k + 1 >= _path_n:
		_replan(traffic)
	var k := _plan_k
	if _has_path and k + 1 < _path_n:
		_fallback = false
		_s0 = state.s
		_s1 = _path_s[k + 1] + (state.s - _path_s[k])
		_d0 = state.d
		_d1 = _path_d[k + 1]
		var x1 := _path_x[k + 1]
		var j := passability.state_position(x1)
		if j >= 0:
			var new_lane := road.lane_index_at(passability.position_d(j), state.s)
			if new_lane >= 0 and new_lane != lane:
				lane = new_lane
				lane_changes += 1
				if mode == Mode.CRUISE:
					target_lane = lane
		_x = x1
		_plan_k = k + 1
	else:
		# No path: follow with IDM and settle in the lane holding the body's center (an
		# interrupted lane change is aborted, not frozen astride two lanes), a half lane
		# per move time at most.
		_fallback = true
		_s0 = state.s
		_s1 = state.s
		_d0 = state.d
		var lanes := road.lane_count(state.s)
		var lw := road.lane_width(state.s)
		var home := clampi(floori((state.d - road.lanes_left_edge_d(state.s)) / lw), 0, lanes - 1)
		var max_dd := lw * 0.5 / float(maxi(passability.move_steps(), 1))
		_d1 = state.d + clampf(road.lane_center_d(home, state.s) - state.d, -max_dd, max_dd)
		if home != lane:
			lane = home
			lane_changes += 1
		_x = -1


func _replan(traffic: TrafficState) -> void:
	checks += 1
	var t0 := Time.get_ticks_usec()
	var pos := -1
	var pair := -1
	var stage := 0
	if _x >= 0 and _has_path:
		pos = passability.state_position(_x)
		if pos < 0:
			pair = passability.state_pair(_x)
			stage = passability.state_stage(_x)
	booths.sim = closures
	booths.refresh(road.lane_count(state.s), state.s, state.s + BOOTH_LOOK_M, _v_min, lane,
		length_m + BOOTH_ESCAPE_M)
	passability.zones = booths
	var open := _open_lane_near(target_lane)
	var d_pref := road.lane_center_d(open, state.s)
	# WP6.10: leaving a lane that ends, closes or turns into a booth lane, the bot first
	# tries to start the move now (the check pinned one step into the half-lane move
	# toward the open lane: a one-step lateral head start). The path is extracted
	# greedily and a lane change costs as much as it gains at first, so the path
	# otherwise stays in the lane to the last feasible step (on an empty road the bot
	# left a booth lane 40 m before its closure, braking to the minimum speed).
	var ok := false
	var early := false
	if pos >= 0 and pair < 0 and open != lane and _lane_ends_ahead(lane) and passability.move_steps() > 1:
		var ep := pos if open > lane else pos - 1
		if ep >= 0 and ep < passability.position_count() - 1:
			early = passability.check_player(traffic, state, params, road, result, -1, ep, 1)
			ok = early
	if not early:
		ok = passability.check_player(traffic, state, params, road, result, pos, pair, stage)
	# ... and it prefers the open lane's pace (dropping back behind a car beside it there),
	# so its own target speed does not keep the path in the lane it is leaving.
	var v_pref := v_target
	if open != lane and _lane_ends_ahead(lane):
		v_pref = minf(v_target, _pace_into(traffic, open))
	if ok:
		ok = passability.extract_path(result, result.path_state[0], state.s, v_pref, d_pref, state.v, HEADWAY_S)
	check_usec += Time.get_ticks_usec() - t0
	_plan_k = 0
	if not ok or result.path_n < 2:
		no_path_checks += 1
		_has_path = false
		return
	_has_path = true
	_path_n = result.path_n
	for k in _path_n:
		_path_s[k] = result.path_s[k]
		_path_d[k] = result.path_d[k]
		_path_x[k] = result.path_state[k]


## Fallback: IDM on the vehicle ahead in its lateral span (braking hard if it must).
func _follow(dt: float, traffic: TrafficState) -> void:
	var gap := INF
	var dv := 0.0
	var lo := state.d - width_m * 0.5
	var hi := state.d + width_m * 0.5
	for i in traffic.capacity:
		if traffic.active[i] == 0:
			continue
		var hw := traffic.width[i] * 0.5
		if traffic.d[i] - hw >= hi or traffic.d[i] + hw <= lo:
			continue
		var g := traffic.s[i] - state.s - (traffic.length[i] + length_m) * 0.5
		if g > -length_m and g < gap:
			gap = g
			dv = state.v - traffic.v[i]
	var a := Idm.accel(state.v, maxf(v_target, 1.0), gap, dv, IDM_A, IDM_B, IDM_T, IDM_S0, 4, 0.1)
	a = clampf(a, -BRAKE, IDM_A)
	state.v = maxf(0.0, state.v + a * dt)
	state.s += state.v * dt


## The pace to take into lane t: a vehicle in it beside the bot or ahead closer than
## HEADWAY_S means dropping back behind it (PACE_DROP_BACK_MPS slower than it); else the
## speed of the nearest vehicle ahead in it within PACE_AHEAD_M (INF: none).
func _pace_into(traffic: TrafficState, t: int) -> float:
	var best := INF
	var v := INF
	var back := INF
	for i in traffic.capacity:
		if traffic.active[i] == 0 or not _lane_hit(traffic, i, t):
			continue
		var g := traffic.s[i] - state.s
		var gap := absf(g) - (traffic.length[i] + length_m) * 0.5
		if gap < SIDE_CLEAR_M or (g > 0.0 and gap < HEADWAY_S * traffic.v[i]):
			back = minf(back, traffic.v[i] - PACE_DROP_BACK_MPS)
		elif g > 0.0 and g < PACE_AHEAD_M and g < best:
			best = g
			v = traffic.v[i]
	return minf(v, maxf(back, 0.0))


## The lane nearest `t` (itself first, then left before right) that neither ends nor
## closes within DROP_LOOK_M (TrafficBotPlayer._lane_ends_ahead: lane drops, WP6.3
## closures and slow zones): the lane the path prefers. The check itself keeps the path
## out of what is closed.
func _open_lane_near(t: int) -> int:
	var lanes := road.lane_count(state.s)
	var c := clampi(t, 0, lanes - 1)
	for k in lanes:
		for x: int in [c - k, c + k]:
			if x >= 0 and x < lanes and not _lane_ends_ahead(x):
				return x
	return c
