class_name SandboxBot
extends VehicleController
# lint: not-sim dev-only sandbox driver; its gains are sandbox knobs, not gameplay tuning
## Bot driver for the traffic sandbox (spec: Traffic → Traffic sandbox (debug scene);
## Architecture rule 8, controller abstraction). It drives the real PlayerCar through
## VehiclePhysics like PlayerController does, so the player takes part in the traffic
## sim exactly as in a run; only the input source differs.
##
## - Lateral: a cascade on road-space quantities. The target lane center gives a
##   desired lateral speed (capped), that gives a desired heading, and steering holds
##   the heading with yaw-rate damping.
## - Longitudinal: IDM on the vehicle ahead in its path (read from the published
##   TrafficState) toward `v_target`, turned into throttle or brake through the
##   car's own longitudinal model (VehiclePhysics.longitudinal_accel is linear in
##   throttle).
## - KEEP: holds its lane. WEAVE: every few seconds moves to the adjacent lane with
##   the longest free gap ahead if it is clear beside the car (it does not wait for a
##   gap that is comfortable for traffic behind: the traffic has to cope, as with a
##   real player).
## Deterministic given its seed. update() allocates nothing.

enum Mode { KEEP, WEAVE }

## Lateral cascade gains (sandbox knobs).
const K_POS := 2.5            ## 1/s: lateral speed per meter of lateral error
const VLAT_MAX := 3.2         ## m/s: lane change speed cap (~1.3 s over 3.6 m)
const K_YAW := 40.0           ## steer per rad of heading error
const K_RATE := 3.0           ## steer per rad/s of yaw rate
const YAW_MAX := 0.12         ## rad: heading cap while changing lanes
const MIN_V := 1.0            ## m/s: below this, no heading math
## Following (IDM, a pushy player).
const IDM_A := 3.0
const IDM_B := 4.0
const IDM_T := 0.8
const IDM_S0 := 2.5
const IDM_DELTA := 4
const IDM_GAP_FLOOR := 0.1
const LOOK_M := 300.0
## Weaving.
const WEAVE_MIN_S := 2.5
const WEAVE_MAX_S := 6.0
const SIDE_CLEAR_M := 2.0     ## free length beside the car in the target lane
const WEAVE_MIN_GAIN_M := 15.0   ## the target lane's free gap must beat the current by this
const LANE_REACHED_M := 0.3

var mode: Mode = Mode.KEEP
var road: RoadPath
var traffic: TrafficState
var target_lane: int = 1
var v_target: float = 36.0
var length_m: float = 4.5
var width_m: float = 1.9
var params: VehicleParams
var lane_changes: int = 0

var _rng: Rng
var _clock: float = 0.0
var _next_weave: float = 0.0


func _init(road_path: RoadPath, traffic_state: TrafficState, vehicle_params: VehicleParams, seed_value: int) -> void:
	road = road_path
	traffic = traffic_state
	params = vehicle_params
	_rng = Rng.new(seed_value)
	_next_weave = _rng.float_range(WEAVE_MIN_S, WEAVE_MAX_S)


func on_attached(state: VehicleState) -> void:
	target_lane = clampi(road.lane_index_at(state.d, state.s), 0, road.lane_count(state.s) - 1)


func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
	_clock += dt
	var lanes := road.lane_count(state.s)
	target_lane = clampi(target_lane, 0, lanes - 1)
	var d_t := road.lane_center_d(target_lane, state.s)
	if mode == Mode.WEAVE and _clock >= _next_weave and absf(state.d - d_t) < LANE_REACHED_M:
		_next_weave = _clock + _rng.float_range(WEAVE_MIN_S, WEAVE_MAX_S)
		var t := _pick_lane(state, lanes)
		if t != target_lane:
			target_lane = t
			lane_changes += 1
			d_t = road.lane_center_d(target_lane, state.s)

	# Lateral: lateral error -> lateral speed -> heading -> steer.
	var v := maxf(state.v, MIN_V)
	var vlat_des := clampf(K_POS * (d_t - state.d), -VLAT_MAX, VLAT_MAX)
	var yaw_des := clampf(asin(clampf(vlat_des / v, -1.0, 1.0)), -YAW_MAX, YAW_MAX)
	out_input.steer = clampf(K_YAW * (yaw_des - state.yaw) - K_RATE * state.yaw_rate, -1.0, 1.0)
	out_input.boost = false

	# Longitudinal: IDM on the vehicle ahead in the car's lateral path.
	var gap := INF
	var dv := 0.0
	var lo := minf(state.d, d_t) - width_m * 0.5
	var hi := maxf(state.d, d_t) + width_m * 0.5
	for i in traffic.capacity:
		if traffic.active[i] == 0:
			continue
		var hw := traffic.width[i] * 0.5
		if traffic.d[i] - hw >= hi or traffic.d[i] + hw <= lo:
			continue
		var g := traffic.s[i] - state.s - (traffic.length[i] + length_m) * 0.5
		if g > -length_m and g < gap and g < LOOK_M:
			gap = g
			dv = state.v - traffic.v[i]
	var a_des := Idm.accel(state.v, maxf(v_target, MIN_V), gap, dv, IDM_A, IDM_B, IDM_T, IDM_S0,
		IDM_DELTA, IDM_GAP_FLOOR)
	var a_coast := VehiclePhysics.longitudinal_accel(params, state.v, 0.0, 0.0, 0.0, 1.0)
	if a_des >= a_coast:
		var a_full := VehiclePhysics.longitudinal_accel(params, state.v, 1.0, 0.0, 0.0, 1.0)
		out_input.throttle = clampf((a_des - a_coast) / maxf(a_full - a_coast, MIN_V), 0.0, 1.0)
		out_input.brake = 0.0
	else:
		out_input.throttle = 0.0
		out_input.brake = clampf((a_coast - a_des) / params.braking_mps2, 0.0, 1.0)


func _pick_lane(state: VehicleState, lanes: int) -> int:
	var best := target_lane
	var best_gap := _free_ahead(state, target_lane) + WEAVE_MIN_GAIN_M
	var first := -1 if _rng.chance(0.5) else 1
	for k in 2:
		var t := target_lane + (first if k == 0 else -first)
		if t < 0 or t >= lanes or not _side_clear(state, t):
			continue
		var g := _free_ahead(state, t)
		if g > best_gap:
			best = t
			best_gap = g
	return best


func _in_lane(i: int, t: int, s: float) -> bool:
	return absf(traffic.d[i] - road.lane_center_d(t, s)) < (traffic.width[i] + width_m) * 0.5


func _free_ahead(state: VehicleState, t: int) -> float:
	var g := LOOK_M
	for i in traffic.capacity:
		if traffic.active[i] == 1 and _in_lane(i, t, state.s):
			var x := traffic.s[i] - state.s - (traffic.length[i] + length_m) * 0.5
			if x > 0.0:
				g = minf(g, x)
	return g


func _side_clear(state: VehicleState, t: int) -> bool:
	for i in traffic.capacity:
		if traffic.active[i] == 1 and _in_lane(i, t, state.s):
			if absf(traffic.s[i] - state.s) < (traffic.length[i] + length_m) * 0.5 + SIDE_CLEAR_M:
				return false
	return true
