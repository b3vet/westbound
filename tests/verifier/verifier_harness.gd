extends "res://tests/integration/run_harness.gd"
## Shared harness for the replay verifier suites (WP N8.1): records a real headless bot run
## with NetReplayRecorder (the real Run scene, manual ticks, a weaving and boosting bot in
## real traffic, until its crash or a time cap) and plays it back through ReplayVerifier.
## Not a suite itself (the runner discovers test_*.gd only).

const RUN_SPEED_MPS := 52.0
const CLIENT_BUILD := 7

var net: NetTuning
var _recorders: Array[Node] = []


## One recorded bot run.
class Recorded:
	extends RefCounted
	var bytes: PackedByteArray
	var replay: NetReplayFile
	var score: int
	var hits: int
	var crashed: bool
	var seconds: float
	var record_ms: int
	## With `exact`: the car's state after every RUNNING tick (s, d, yaw, v, v_lat per
	## tick, flat) and the simulation's hash (sim_hash) after it.
	var states := PackedFloat64Array()
	var hashes := PackedInt64Array()


func before_all() -> void:
	super.before_all()
	net = NetTuning.load_default()


func after_each() -> void:
	for n in _recorders:
		if is_instance_valid(n):
			n.queue_free()
	_recorders.clear()
	await super.after_each()


## Records a run on `run_seed` with car `car_index`: a weaving, boosting bot drives until
## the run's crash (2 hits) or `max_s` of driving. A run cut at the cap claims its
## banked score, as its end would (the held chain is lost).
func record_bot_run(run_seed: int, car_index: int, max_s: float, mode: StringName = RunContext.MODE_JOURNEY,
		bot_seed: int = BOT_SEED, speed_mps: float = RUN_SPEED_MPS, exact: bool = false) -> Recorded:
	var make := func(r: Run) -> VehicleController:
		var bot := BoostingBot.new(r.road, r.sim.state, r.car.params, bot_seed)
		bot.mode = SandboxBot.Mode.WEAVE
		bot.v_target = speed_mps
		bot.length_m = r.car.car.length_m
		bot.width_m = r.car.car.width_m
		return bot
	return await record_run(run_seed, car_index, max_s, make, mode, exact)


## A driver that holds its start lane at full throttle and never avoids anything: it runs
## into the traffic ahead (real hits on the recorded path).
func record_rammer_run(run_seed: int, car_index: int, max_s: float) -> Recorded:
	var make := func(r: Run) -> VehicleController:
		var drv := Driver.new(r.road, r.car.params)
		drv.target_d = r.car.state.d
		drv.full_throttle = true
		return drv
	return await record_run(run_seed, car_index, max_s, make)


func record_run(run_seed: int, car_index: int, max_s: float, make_controller: Callable,
		mode: StringName = RunContext.MODE_JOURNEY, exact: bool = false) -> Recorded:
	var started := Time.get_ticks_msec()
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.mode = mode
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.car_index = car_index
	_run = r
	tree.root.add_child(r)
	_runs.append(r)
	var rec := NetReplayRecorder.new(net, CLIENT_BUILD)
	rec.auto_attach = false
	tree.root.add_child(rec)
	_recorders.append(rec)
	r.drive_controller = make_controller.call(r) as VehicleController
	r.go()
	check(rec.begin(r), "the recorder starts")
	var out := Recorded.new()
	var left := _ticks_for(max_s)
	while left > 0 and r.state == Game.RUNNING:
		r.tick()
		rec.capture()
		if exact and r.state == Game.RUNNING:
			var st := r.car.state
			out.states.append_array([st.s, st.d, st.yaw, st.v, st.v_lat])
			out.hashes.append(sim_hash(r))
		if r.tick_count % TICKS_PER_FRAME == 0:
			r.frame(FRAME_S)
		left -= 1
	out.seconds = r.stats.duration_s
	out.crashed = r.state == Game.CRASH
	if out.crashed:
		for i in TICKS_PER_FRAME * 2:
			r.tick()
			rec.capture()
			r.frame(FRAME_S)
	# The run end loses the held chain (Scoring.notify_run_end): the score is banked().
	out.score = r.scoring.banked()
	out.hits = r.stats.hits
	var results := {RunStats.SCORE: out.score, RunStats.HITS: out.hits, RunStats.DISTANCE_M: r.stats.distance_m}
	out.bytes = rec.finish(results, "2026-09-29")
	out.replay = NetReplayFile.decode(out.bytes)
	out.record_ms = Time.get_ticks_msec() - started
	_runs.erase(r)
	if _run == r:
		_run = null
	r.queue_free()
	await tree.process_frame
	return out


## Plays `replay` back (optionally with the server's claims) and returns the result.
## `resim` false: the N8.1 kinematic playback even when the replay has inputs.
func verify(replay: NetReplayFile, score: int = -1, hits: int = -1, run_seed: int = -1,
		resim: bool = true) -> Dictionary:
	var v := ReplayVerifier.new(replay, net)
	v.claimed_score = score
	v.claimed_hits = hits
	v.expected_seed = run_seed
	v.resim = resim
	var res := v.verify(tree.root)
	await tree.process_frame
	return res


## Plays `rec` back kinematically with the original's exact car state fed in at every tick
## (instead of the quantized, interpolated samples) and returns the first tick whose simulation hash
## differs from the original's (-1: identical throughout) and the result.
func verify_exact(rec: Recorded) -> Array:
	var v := ReplayVerifier.new(rec.replay, net)
	v.resim = false   # the kinematic playback, fed the exact states
	v.claimed_score = rec.score
	v.claimed_hits = rec.hits
	var first := [-1]
	v.on_state = func(k: int, st: VehicleState) -> void:
		var i := (k - 1) * 5
		if i + 4 < rec.states.size():
			st.s = rec.states[i]
			st.d = rec.states[i + 1]
			st.yaw = rec.states[i + 2]
			st.v = rec.states[i + 3]
			st.v_lat = rec.states[i + 4]
	v.on_tick = func(k: int, r: Run) -> void:
		if first[0] < 0 and k - 1 < rec.hashes.size() and sim_hash(r) != rec.hashes[k - 1]:
			first[0] = k
	var res := v.verify(tree.root)
	await tree.process_frame
	return [first[0], res]


## Everything the tick simulates except the car's own physics fields: traffic, scoring,
## lives, legs, the objective, the sun, the forks and the stats.
static func sim_hash(r: Run) -> int:
	var h := r.sim.state.hash_into(TraceHash.SEED)
	h = r.scoring.hash_into(h)
	h = r.lives.hash_into(h)
	h = r.legs.hash_into(h)
	h = r.objectives.hash_into(h)
	h = TraceHash.mix_float(h, r.sun.sky_t)
	h = r.forks.hash_into(h)
	return r.stats.hash_into(h)


static func describe(res: Dictionary) -> String:
	return "%s: recomputed %s vs claimed %s (%.3f %%), hits %s/%s, unreported %s, traffic diverged at %s s, %s violations %s" % [
		res.get("reason", res.get("error", "?")), res.get("recomputed_score"), res.get("claimed_score"),
		float(res.get("diff_pct", 0.0)), res.get("recomputed_hits"), res.get("claimed_hits"),
		res.get("unreported_hits"), str(res.get("traffic_diverged_at_s")), res.get("violation_count"),
		str(res.get("violations", []))]
