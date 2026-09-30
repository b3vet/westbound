class_name PassabilityDriver
extends SandboxBot
## A reacting driver for the replay tests (WP N8.2): it drives the real car (PlayerCar,
## VehiclePhysics) along Passability's path, the way the soak's PassabilityBot drives its
## kinematic car. Every REPLAN_S it runs Passability.check_player from the car's exact
## state, re-extracts the path toward its preferred lane (a new random lane every few
## seconds) at its target speed, and takes the path's lane and pace LOOK_S ahead as
## SandboxBot's target lane and speed; SandboxBot's cascade steers and IDM follows. A
## closed loop on the whole traffic prediction: the kind of driver in which a 1-ulp
## difference flips a decision within seconds (WP8.4), so its replays test the verifier's
## re-simulation hardest. Not a test suite (no test_ prefix). Deterministic given its seed.

const REPLAN_S := 0.5
const LOOK_S := 1.5
const PREF_MIN_S := 3.0
const PREF_MAX_S := 7.0
const HEADWAY_S := 1.0
const V_MIN_FRAC := 0.6

var passability: Passability
var result := Passability.Result.new()
var v_cruise: float = 50.0
var checks: int = 0
var no_path: int = 0

var _pref_lane: int = 1
var _t: float = 0.0
var _next_plan: float = 0.0
var _next_pref: float = 0.0
var _prng: Rng


func _init(r: Run, seed_value: int, speed_mps: float) -> void:
	super(r.road, r.sim.state, r.car.params, seed_value)
	mode = SandboxBot.Mode.KEEP
	v_cruise = speed_mps
	v_target = speed_mps
	length_m = r.car.car.length_m
	width_m = r.car.car.width_m
	passability = Passability.new(r.tuning, r.registry, r.road)
	passability.set_player_body(length_m, width_m)
	_prng = Rng.new(seed_value).derive(&"passability_driver")


func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
	_t += dt
	var lanes := road.lane_count(state.s)
	if _t >= _next_pref:
		_next_pref = _t + _prng.float_range(PREF_MIN_S, PREF_MAX_S)
		_pref_lane = _prng.int_range(0, lanes - 1)
	if _t >= _next_plan:
		_next_plan = _t + REPLAN_S
		_plan(state, lanes)
	super.update(dt, state, out_input)


func _plan(state: VehicleState, lanes: int) -> void:
	checks += 1
	var ok := passability.check_player(traffic, state, params, road, result)
	if ok and result.path_n > 0:
		var d_pref := road.lane_center_d(clampi(_pref_lane, 0, lanes - 1), state.s)
		ok = passability.extract_path(result, result.path_state[0], state.s, v_cruise, d_pref, state.v, HEADWAY_S)
	if not ok or result.path_n < 2:
		no_path += 1
		v_target = v_cruise
		return
	var step := passability.step_s()
	var k := clampi(roundi(LOOK_S / step), 1, result.path_n - 1)
	target_lane = clampi(road.lane_index_at(result.path_d[k], state.s), 0, lanes - 1)
	var pace := (result.path_s[k] - result.path_s[0]) / (float(k) * step)
	v_target = clampf(pace, v_cruise * V_MIN_FRAC, v_cruise)
