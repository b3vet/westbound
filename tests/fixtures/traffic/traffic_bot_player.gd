class_name TrafficBotPlayer
extends RefCounted
## Scripted player for the traffic tests (not a test suite: the runner skips
## tests/fixtures). A kinematic car in road space (yaw 0, so v = ds/dt and v_lat =
## dd/dt) that traffic reads as the player participant. It never uses TrafficSim
## internals: it only reads the published TrafficState.
##
## Modes:
## - CRUISE: constant speed, keeps its lane center (the spec's "player driving
##   normally"). follow = false means it never brakes, whatever is ahead.
## - WEAVE: follows traffic ahead with its own IDM (up to the car's 9 m/s^2 braking)
##   and changes lanes every weave interval into the adjacent lane with the longest
##   free gap, as long as the target lane is not physically occupied beside it. It
##   does not wait for gaps that are comfortable for traffic behind: tight cut-ins
##   (and occasional contacts caused by the player) are part of the stress.

enum Mode { CRUISE, WEAVE }

const BOT_A_MAX := 3.0          ## m/s^2
const BOT_BRAKE := 9.0          ## m/s^2 (Physics: braking)
const BOT_B := 4.0
const BOT_T := 0.7              ## s headway (a pushy player)
const BOT_S0 := 2.0
const LANE_CHANGE_S := 1.0      ## the car's lane change (Physics: 0.8-1.15 s)
const SIDE_CLEAR_M := 1.0       ## required free length beside it in the target lane

var state := VehicleState.new()
var mode: Mode
var road: RoadPath
var lane: int
var v_target: float
var follow := true
var weave_min_s := 2.0
var weave_max_s := 5.0
var length_m := 4.5
var width_m := 1.9

var _rng: Rng
var _next_weave := 0.0
var _clock := 0.0
var _lc_t := -1.0
var _from_d := 0.0
var _to_d := 0.0
var lane_changes := 0


func _init(road_path: RoadPath, start_lane: int, speed_mps: float, bot_mode: Mode, seed_value: int,
		start_s: float = 0.0) -> void:
	road = road_path
	lane = start_lane
	v_target = speed_mps
	mode = bot_mode
	_rng = Rng.new(seed_value)
	state.reset()
	state.s = start_s
	state.d = road.lane_center_d(lane, start_s)
	state.v = speed_mps
	_next_weave = _rng.float_range(weave_min_s, weave_max_s)


## WEAVE without lane changes: lane keeping, following traffic ahead.
func keep_lane() -> void:
	weave_min_s = INF
	weave_max_s = INF
	_next_weave = INF


## WEAVE with a lane-change decision every [min_s, max_s] seconds (from now).
func set_weave(min_s: float, max_s: float) -> void:
	weave_min_s = min_s
	weave_max_s = max_s
	_next_weave = _clock + _rng.float_range(min_s, max_s)


## True while the bot's own lateral move runs.
func is_changing_lanes() -> bool:
	return _lc_t >= 0.0


func update(dt: float, traffic: TrafficState) -> void:
	_clock += dt
	var a := 0.0
	if v_target <= 0.0:
		a = -BOT_BRAKE if state.v > 0.0 else 0.0
	elif mode == Mode.WEAVE and follow:
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
		a = Idm.accel(state.v, v_target, gap, dv, BOT_A_MAX, BOT_B, BOT_T, BOT_S0, 4, 0.1)
		a = clampf(a, -BOT_BRAKE, BOT_A_MAX)
	state.v = maxf(0.0, state.v + a * dt)
	state.accel_long = a
	state.s += state.v * dt

	if mode == Mode.WEAVE:
		if _lc_t < 0.0 and _clock >= _next_weave:
			_next_weave = _clock + _rng.float_range(weave_min_s, weave_max_s)
			var target := _pick_lane(traffic)
			if target != lane:
				_lc_t = 0.0
				_from_d = state.d
				_to_d = road.lane_center_d(target, state.s)
				lane = target
				lane_changes += 1
		if _lc_t >= 0.0:
			_lc_t += dt
			var u := minf(_lc_t / LANE_CHANGE_S, 1.0)
			state.d = _from_d + (_to_d - _from_d) * u * u * (3.0 - 2.0 * u)
			state.v_lat = (_to_d - _from_d) * 6.0 * u * (1.0 - u) / LANE_CHANGE_S
			if u >= 1.0:
				_lc_t = -1.0
				state.v_lat = 0.0
	else:
		state.d = road.lane_center_d(lane, state.s)
		state.v_lat = 0.0


func _pick_lane(traffic: TrafficState) -> int:
	var lanes := road.lane_count(state.s)
	var best := lane
	var best_gap := _free_ahead(traffic, lane)
	var order := [lane - 1, lane + 1]
	if _rng.chance(0.5):
		order = [lane + 1, lane - 1]
	for t: int in order:
		if t < 0 or t >= lanes or not _side_clear(traffic, t):
			continue
		var g := _free_ahead(traffic, t)
		if g > best_gap or (best == lane and g > 30.0 and _rng.chance(0.5)):
			best = t
			best_gap = g
	return best


func _lane_hit(traffic: TrafficState, i: int, t: int) -> bool:
	var c := road.lane_center_d(t, state.s)
	var hw := traffic.width[i] * 0.5
	return absf(traffic.d[i] - c) < hw + width_m * 0.5


func _free_ahead(traffic: TrafficState, t: int) -> float:
	var g := 1e9
	for i in traffic.capacity:
		if traffic.active[i] == 1 and _lane_hit(traffic, i, t):
			var x := traffic.s[i] - state.s - (traffic.length[i] + length_m) * 0.5
			if x > 0.0:
				g = minf(g, x)
	return g


func _side_clear(traffic: TrafficState, t: int) -> bool:
	for i in traffic.capacity:
		if traffic.active[i] == 1 and _lane_hit(traffic, i, t):
			if absf(traffic.s[i] - state.s) < (traffic.length[i] + length_m) * 0.5 + SIDE_CLEAR_M:
				return false
	return true
