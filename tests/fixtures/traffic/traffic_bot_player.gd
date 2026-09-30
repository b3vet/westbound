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
##   free gap, as long as the target lane is not occupied beside it (physically, or
##   by a car already moving into it, WP6.8). It
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
## Lane drops (WP6.2): a lane that ends within this far ahead is left for the next lane
## to the left as soon as it is clear beside the bot, and weaving never picks it.
const DROP_LOOK_M := 350.0
## WP6.8, road lane drops: like a player reading the LANE ENDS sign, the bot leaves a
## lane that the road drops within DROP_EARLY_M, as soon as the lane beside it is clear
## beside it and has at least EXIT_HEADWAY_S (and EXIT_GAP_MIN_M) of free road ahead;
## weaving never picks such a lane. (Before, it left only DROP_LOOK_M out, into any gap
## beside it: cut-ins a few metres behind slow traffic at 140 km/h that no player would
## make, flagged as impossible windows.)
const DROP_EARLY_M := 800.0
const EXIT_HEADWAY_S := 1.5
const EXIT_GAP_MIN_M := 30.0
## WP6.8: the forced exit from a lane the road drops (within DROP_LOOK_M) waits for at
## least FORCED_HEADWAY_S (and FORCED_GAP_MIN_M) of free road ahead in the lane beside it
## while the lane still has FORCED_ANY_M to go; only then does any gap clear beside it do.
## (Before, it took any gap clear beside it: a cut-in 1.5 m behind a car 30 km/h slower,
## braking hard, flagged as a traffic window since it was not yet in contact.)
const FORCED_HEADWAY_S := 0.5
const FORCED_GAP_MIN_M := 10.0
const FORCED_ANY_M := 150.0

## WP6.3: anything with closure_ahead(lane, s) (the TrafficSim): a lane closed within
## DROP_LOOK_M ahead (road works, a merge zone's acceleration lane) is left for an open
## neighbour (left first) as soon as it is clear beside the bot, and never picked;
## so is a lane with a speed zone slower than the bot's target speed there or within
## DROP_LOOK_M ahead (a toll's booth lane: the player takes the express lanes).
var closures: Object

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
## WP6.3 tests: a lane change to the adjacent lane `to`, the car's own (LANE_CHANGE_S,
## WEAVE mode moves it). Ignored while one runs.
func change_lane(to: int) -> void:
	if _lc_t >= 0.0 or to == lane or absi(to - lane) != 1:
		return
	_lc_t = 0.0
	_from_d = state.d
	_to_d = road.lane_center_d(to, state.s)
	lane = to
	lane_changes += 1


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

	if _lc_t < 0.0 and not _lane_ends_ahead(lane) and lane >= road.lane_count(state.s + DROP_EARLY_M):
		var early := -1
		for t: int in [lane - 1, lane + 1]:
			if early < 0 and t >= 0 and t < road.lane_count(state.s + DROP_EARLY_M) and not _lane_ends_ahead(t) \
					and _side_clear(traffic, t) \
					and _free_ahead(traffic, t) >= maxf(EXIT_GAP_MIN_M, state.v * EXIT_HEADWAY_S):
				early = t
		if early >= 0:
			if mode == Mode.WEAVE:
				_lc_t = 0.0
				_from_d = state.d
				_to_d = road.lane_center_d(early, state.s)
			lane = early
			lane_changes += 1
	elif _lc_t < 0.0 and _lane_ends_ahead(lane):
		var to := -1
		# WP6.8: a lane the road drops, still there FORCED_ANY_M on: wait for a real gap.
		var need := 0.0
		if lane >= road.lane_count(state.s + DROP_LOOK_M) and lane < road.lane_count(state.s + FORCED_ANY_M):
			need = maxf(FORCED_GAP_MIN_M, state.v * FORCED_HEADWAY_S)
		for t: int in [lane - 1, lane + 1]:
			if to < 0 and t >= 0 and t < road.lane_count(state.s) and not _lane_ends_ahead(t) and _side_clear(traffic, t) \
					and (need <= 0.0 or _free_ahead(traffic, t) >= need):
				to = t
		if to >= 0:
			if mode == Mode.WEAVE:
				_lc_t = 0.0
				_from_d = state.d
				_to_d = road.lane_center_d(to, state.s)
			lane = to
			lane_changes += 1
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
	var lanes := mini(road.lane_count(state.s), road.lane_count(state.s + DROP_EARLY_M))
	var best := lane
	var best_gap := _free_ahead(traffic, lane)
	var order := [lane - 1, lane + 1]
	if _rng.chance(0.5):
		order = [lane + 1, lane - 1]
	for t: int in order:
		if t < 0 or t >= lanes or _lane_ends_ahead(t) or not _side_clear(traffic, t):
			continue
		var g := _free_ahead(traffic, t)
		if g > best_gap or (best == lane and g > 30.0 and _rng.chance(0.5)):
			best = t
			best_gap = g
	return best


## Lane t ends (a lane drop) or is closed (WP6.3) within DROP_LOOK_M ahead.
func _lane_ends_ahead(t: int) -> bool:
	if t >= road.lane_count(state.s + DROP_LOOK_M):
		return true
	if closures == null:
		return false
	if float(closures.call(&"closure_ahead", t, state.s)) < DROP_LOOK_M:
		return true
	# WP6.3: a slow zone ahead in the lane (a toll's booth lane): take the express lanes.
	return closures.has_method(&"speed_zone_count") and int(closures.call(&"speed_zone_count")) > 0 \
		and minf(float(closures.call(&"speed_limit_at", t, state.s, 0)),
			float(closures.call(&"speed_limit_at", t, state.s + DROP_LOOK_M, 0))) < v_target


## Vehicle i is in lane t, or (WP6.8) already moving into it: the bot does not swerve
## into a lane beside a car that is visibly merging into it (before, it could pick the
## lane of an early lane-drop merger 5 m ahead: two cars converging on one lane).
func _lane_hit(traffic: TrafficState, i: int, t: int) -> bool:
	if traffic.lc_state[i] == TrafficState.LaneChange.MOVING and traffic.target_lane[i] == t:
		return true
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
