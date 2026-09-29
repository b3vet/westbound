extends WBTest
## Shared harness for the end-to-end integration suites (WP4.5): the real Run scene
## (src/run/run.tscn), ticked manually and headless, driven by scripted controllers,
## observed only through the `Events` bus. Not a suite itself (the runner discovers
## test_*.gd only); the suites extend it by path.
##
## - _make(): a Run with manual ticks (tick() = one 120 Hz tick, frame() = one
##   rendered frame), so simulated time is exact and nothing waits on the wall clock.
## - _quiet(): swaps the director for one that spawns nothing (QuietDirector, an empty
##   SpawnSource), so a scenario places its own traffic with _spawn() through the real
##   TrafficSim.spawn API. Scripted cars carry FLAG_SCRIPTED (no lane changes) and
##   drive at their desired speed.
## - Driver: a scripted player controller that holds a lateral offset `target_d` and a
##   speed `v_target` through the real VehiclePhysics (the same lateral cascade as
##   SandboxBot, a proportional speed loop), and fires a boost on request.
## - _log: every gameplay signal as [tick, name, args...] (tick = Run.tick_count when
##   the adapter published it, once per frame).

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 11
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const BOT_SPEED_MPS := 52.0
const CAR_TYPE := &"sedan"
const CAR_PROFILE := &"commuter"

var t: Tuning
var _runs: Array[Run] = []
var _run: Run
var _log: Array = []
var _conns: Array = []
var _base_ticks: int
var _reduced: bool


## Spawns nothing ahead or behind (the scenario places its traffic); still despawns.
class EmptySource:
	extends SpawnSource

	func source_id() -> StringName:
		return &"empty"

	func plan_batch(_ctx: SpawnSource.Context, _s_from: float, _s_to: float, _out_spawns: Array[SpawnSource.Record]) -> void:
		pass


class QuietDirector:
	extends TrafficDirector

	func step(_dt: float, player: VehicleState) -> void:
		step_despawn(player.s)


## Scripted player: lateral cascade (offset -> lateral speed -> heading -> steer, as
## SandboxBot) toward target_d, a proportional speed loop toward v_target (or full
## throttle), and one boost request per request_boost().
class Driver:
	extends VehicleController
	const K_POS := 2.5
	const K_YAW := 40.0
	const K_RATE := 3.0
	const YAW_MAX := 0.12
	const K_V := 2.0
	const MIN_V := 1.0

	var road: RoadPath
	var params: VehicleParams
	var target_d: float = 0.0
	var v_target: float = 40.0
	var vlat_max: float = 3.2
	var full_throttle: bool = false
	var ticks: int = 0
	var _boost: bool = false

	func _init(road_path: RoadPath, vehicle_params: VehicleParams) -> void:
		road = road_path
		params = vehicle_params

	func request_boost() -> void:
		_boost = true

	func update(_dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		ticks += 1
		var v := maxf(state.v, MIN_V)
		var vlat_des := clampf(K_POS * (target_d - state.d), -vlat_max, vlat_max)
		var yaw_des := clampf(asin(clampf(vlat_des / v, -1.0, 1.0)), -YAW_MAX, YAW_MAX)
		out_input.steer = clampf(K_YAW * (yaw_des - state.yaw) - K_RATE * state.yaw_rate, -1.0, 1.0)
		out_input.boost = _boost
		_boost = false
		if full_throttle:
			out_input.throttle = 1.0
			out_input.brake = 0.0
			return
		var a_des := K_V * (v_target - state.v)
		var a_coast := VehiclePhysics.longitudinal_accel(params, state.v, 0.0, 0.0, 0.0, 1.0)
		if a_des >= a_coast:
			var a_full := VehiclePhysics.longitudinal_accel(params, state.v, 1.0, 0.0, 0.0, 1.0)
			out_input.throttle = clampf((a_des - a_coast) / maxf(a_full - a_coast, MIN_V), 0.0, 1.0)
			out_input.brake = 0.0
		else:
			out_input.throttle = 0.0
			out_input.brake = clampf((a_coast - a_des) / params.braking_mps2, 0.0, 1.0)


## SandboxBot's weaving plus a boost whenever the meter is full (the fairness and
## determinism runs use it; deterministic given its seed).
class BoostingBot:
	extends SandboxBot

	func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		super.update(dt, state, out_input)
		out_input.boost = state.boost_meter >= 1.0 and not state.boost_active


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	_log.clear()
	_run = null
	_base_ticks = Engine.physics_ticks_per_second
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", false)
	_listen(Events.scored, func(k: StringName, p: int, m: float, c: float) -> void: _add(["scored", k, p, m, c]))
	_listen(Events.chain_banked, func(a: int, r: StringName, tot: int) -> void: _add(["chain_banked", a, r, tot]))
	_listen(Events.chain_lost, func(a: int, r: StringName) -> void: _add(["chain_lost", a, r]))
	_listen(Events.hesitated, func() -> void: _add(["hesitated"]))
	_listen(Events.too_slow_changed, func(on: bool) -> void: _add(["too_slow_changed", on]))
	_listen(Events.shoulder_penalty_changed, func(on: bool) -> void: _add(["shoulder_penalty_changed", on]))
	_listen(Events.slipstream_changed, func(on: bool) -> void: _add(["slipstream_changed", on]))
	_listen(Events.bonus_awarded, func(k: StringName, p: int, tot: int) -> void: _add(["bonus_awarded", k, p, tot]))
	_listen(Events.boost_meter_changed, func(f: float) -> void: _add(["boost_meter_changed", f]))
	_listen(Events.boost_started, func() -> void: _add(["boost_started"]))
	_listen(Events.boost_ended, func() -> void: _add(["boost_ended"]))
	_listen(Events.hit, func(src: StringName, left: int) -> void: _add(["hit", src, left]))
	_listen(Events.ghost_started, func(d: float) -> void: _add(["ghost_started", d]))
	_listen(Events.ghost_ended, func() -> void: _add(["ghost_ended"]))
	_listen(Events.crash_started, func() -> void: _add(["crash_started"]))
	_listen(Events.crash_finished, func() -> void: _add(["crash_finished"]))
	_listen(Events.run_over, func(res: Dictionary) -> void: _add(["run_over", res]))
	_listen(Events.checkpoint_crossed, func(leg: int, summary: Dictionary) -> void: _add(["checkpoint_crossed", leg, summary]))
	_listen(Events.game_state_changed, func(_f: StringName, to: StringName) -> void: _add(["state", to]))
	_listen(Events.sun_lifted, func(f: float) -> void: _add(["sun_lifted", f]))
	_listen(Events.countdown_tick, func(n: int) -> void: _add(["countdown_tick", n]))


func after_each() -> void:
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	tree.paused = false
	for r in _runs:
		if is_instance_valid(r):
			r.queue_free()
	_runs.clear()
	_run = null
	await tree.process_frame
	Settings.set_value(&"reduced_motion", _reduced)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _add(entry: Array) -> void:
	entry.push_front(_run.tick_count if _run != null and is_instance_valid(_run) else -1)
	_log.append(entry)


# ---------------------------------------------------------------- Runs

func _make(run_seed: int = SEED, crash_cinematic: bool = false, car_index: int = 0) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = crash_cinematic
	r.record_best = false
	r.car_index = car_index
	_run = r
	tree.root.add_child(r)
	_runs.append(r)
	return r


## Frees a run now (sequential runs in one test).
func _drop(r: Run) -> void:
	_runs.erase(r)
	if _run == r:
		_run = null
	r.queue_free()
	await tree.process_frame


## n ticks with a rendered frame every TICKS_PER_FRAME ticks of the run (so one-tick
## steps still get their frames).
func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if r.tick_count % TICKS_PER_FRAME == 0:
			r.frame(FRAME_S)


func _run_s(r: Run, seconds: float) -> void:
	_run_ticks(r, _ticks_for(seconds))


## Runs until `cond` holds (checked every frame) or `max_s` pass. Returns whether it held.
func _run_until(r: Run, cond: Callable, max_s: float) -> bool:
	var left := _ticks_for(max_s)
	while left > 0:
		_run_ticks(r, TICKS_PER_FRAME)
		left -= TICKS_PER_FRAME
		if cond.call():
			return true
	return false


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(t.vehicle.physics_tick_hz))


func _dt() -> float:
	return t.vehicle.physics_dt()


## Starts driving (GO) with the scripted Driver, on a road with no traffic; at `v`
## (m/s) from the start line when given, else at the rolling-start speed.
func _go_quiet(r: Run, v: float = -1.0) -> Driver:
	var drv := Driver.new(r.road, r.car.params)
	r.drive_controller = drv
	_quiet(r)
	if v > 0.0:
		r.dev_teleport(r.car.state.s, v)
	drv.target_d = r.car.state.d
	drv.v_target = r.car.state.v
	r.go()
	return drv


## Replaces the director with one that spawns nothing and clears the carriageway.
func _quiet(r: Run) -> void:
	var q := QuietDirector.new(r.ctx, r.road, r.sim, r.registry.profiles, r.registry.types,
		r.car.car.length_m, r.car.car.width_m)
	q.source = EmptySource.new()
	q.frustum_check = r.director.frustum_check
	q.set_fog_end(r.builder.view_distance_m())
	q.set_leg(r.legs.leg_index, r.car.state.s)
	q.reset(r.car.state)
	r.director = q


## A scripted car `ds` ahead of the player (box centers) in `lane`, `d_offset` from
## the lane center (+ right), at `v` (its desired speed too). Returns the slot.
func _spawn(r: Run, ds: float, lane: int, v: float, d_offset: float = 0.0, type_id: StringName = CAR_TYPE) -> int:
	var rec := SpawnSource.Record.new()
	rec.s = r.car.state.s + ds
	rec.lane = lane
	rec.d = r.road.lane_center_d(lane, rec.s) + d_offset
	rec.v = v
	rec.v0 = v
	rec.type_id = r.registry.type_index(type_id)
	rec.profile_id = r.registry.profile_index(CAR_PROFILE)
	rec.flags = TrafficState.FLAG_SCRIPTED
	var slot := r.sim.spawn(rec)
	check(slot >= 0, "spawned a scripted car")
	return slot


func _lane_d(r: Run, lane: int) -> float:
	return r.road.lane_center_d(lane, r.car.state.s)


## The player's d that leaves `clearance` (hull to hull, collision-inset boxes) to a
## car of `type_id` at `car_d`, on the side `side` (+1: the player right of the car).
func _d_for_clearance(r: Run, car_d: float, clearance: float, side: float, type_id: StringName = CAR_TYPE) -> float:
	var inset := t.lives.collision_inset_m
	var car_hw := r.registry.width[r.registry.type_index(type_id)] * 0.5 - inset
	var player_hw := r.car.car.width_m * 0.5 - inset
	return car_d + side * (car_hw + player_hw + clearance)


# ---------------------------------------------------------------- The log

func _entries(name: String) -> Array:
	var out: Array = []
	for e: Array in _log:
		if e[1] == name:
			out.append(e)
	return out


func _count(name: String) -> int:
	return _entries(name).size()


## Entries `name` whose first argument equals `arg`.
func _entries_with(name: String, arg: Variant) -> Array:
	var out: Array = []
	for e: Array in _entries(name):
		if e.size() > 2 and e[2] == arg:
			out.append(e)
	return out


func _scored(kind: StringName) -> Array:
	return _entries_with("scored", kind)


func _last(name: String) -> Array:
	for i in range(_log.size() - 1, -1, -1):
		if _log[i][1] == name:
			return _log[i]
	return []


## Scored events published between two ticks (inclusive).
func _scored_between(t0: int, t1: int) -> Array:
	var out: Array = []
	for e: Array in _entries("scored"):
		if e[0] >= t0 and e[0] <= t1:
			out.append(e)
	return out
