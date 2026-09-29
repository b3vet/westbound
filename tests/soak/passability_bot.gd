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
## hopeless spot) it keeps its last path's lateral plan and follows the vehicle ahead
## with IDM, and counts it (no_path_checks). It only reads the published TrafficState.

## Replan every this many decision steps (0.5 s at step_s 0.25).
const REPLAN_STEPS := 2
## Time headway kept behind what is ahead on the path (a sensible player; the search
## itself allows the clearance alone, since any speed down to the minimum is allowed).
const HEADWAY_S := 1.0
## Fallback following (no path): a pushy player's IDM, the car's braking.
const IDM_A := 3.0
const IDM_B := 4.0
const IDM_T := 0.8
const IDM_S0 := 2.0
const BRAKE := 9.0

var params: VehicleParams
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
		target_lane = _rng.int_range(0, _lanes_ahead() - 1)
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
		# No path: hold the lateral position, follow with IDM.
		_fallback = true
		_s0 = state.s
		_s1 = state.s
		_d0 = state.d
		_d1 = state.d


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
	var ok := passability.check_player(traffic, state, params, road, result, pos, pair, stage)
	var d_pref := road.lane_center_d(clampi(target_lane, 0, _lanes_ahead() - 1), state.s)
	if ok:
		ok = passability.extract_path(result, result.path_state[0], state.s, v_target, d_pref, state.v, HEADWAY_S)
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


## Lanes here and DROP_LOOK_M ahead, the fewer (WP6.2 lane drops: an ending lane is
## neither picked nor preferred; the check itself keeps the path out of it).
func _lanes_ahead() -> int:
	return mini(road.lane_count(state.s), road.lane_count(state.s + DROP_LOOK_M))
