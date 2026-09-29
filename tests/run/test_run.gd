extends WBTest
## Run (src/run/run.tscn) headless integration: the flow COUNTDOWN -> RUNNING -> first
## hit -> CRASH -> RESULTS -> retry, events on the bus, the §4 tick order, determinism.
## The run ticks manually (manual_ticks): tick() is one 120 Hz tick, frame() one
## rendered frame, so simulated time is exact and no test waits on the wall clock.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 11
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const BOT_SPEED_MPS := 52.0

var _runs: Array[Run] = []
var _log: Array = []
var _conns: Array = []
var _base_ticks: int
var _reduced: bool


## Records the order of the per-tick calls (controller, lives, scoring, sun, legs).
class Order:
	extends RefCounted
	var calls: PackedStringArray = []
	var traffic_hash_at_scoring: int = 0
	var player_hash_at_scoring: int = 0


class SpyController:
	extends VehicleController
	var order: Order
	var inner: VehicleController

	func _init(o: Order, wrapped: VehicleController) -> void:
		order = o
		inner = wrapped

	func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		order.calls.append("controller")
		inner.update(dt, state, out_input)


class SpyLives:
	extends Lives
	var order: Order

	func step(dt: float, player: VehicleState, out: ScoreEventBuffer) -> void:
		order.calls.append("lives")
		super.step(dt, player, out)


class SpyScoring:
	extends Scoring
	var order: Order

	func step(dt: float, player: VehicleState, traffic: TrafficState, road: RoadPath,
			out_events: ScoreEventBuffer) -> void:
		order.calls.append("scoring")
		order.traffic_hash_at_scoring = traffic.trace_hash()
		order.player_hash_at_scoring = player.trace_hash()
		super.step(dt, player, traffic, road, out_events)


class SpySun:
	extends SunClock
	var order: Order

	func advance(dt: float, too_slow: bool, out: ScoreEventBuffer) -> void:
		order.calls.append("sun")
		super.advance(dt, too_slow, out)


class SpyLegs:
	extends LegTracker
	var order: Order

	func step(dt: float, player_s: float, is_night: bool, out: ScoreEventBuffer) -> bool:
		order.calls.append("legs")
		return super.step(dt, player_s, is_night, out)


func before_each() -> void:
	_log.clear()
	_base_ticks = Engine.physics_ticks_per_second
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", false)
	_listen(Events.countdown_tick, func(n: int) -> void: _log.append(["countdown_tick", n]))
	_listen(Events.game_state_changed, func(_f: StringName, t: StringName) -> void: _log.append(["state", t]))
	_listen(Events.scored, func(k: StringName, _p: int, _m: float, _c: float) -> void: _log.append(["scored", k]))
	_listen(Events.hit, func(src: StringName, left: int) -> void: _log.append(["hit", src, left]))
	_listen(Events.chain_lost, func(a: int, r: StringName) -> void: _log.append(["chain_lost", a, r]))
	_listen(Events.ghost_started, func(d: float) -> void: _log.append(["ghost_started", d]))
	_listen(Events.ghost_ended, func() -> void: _log.append(["ghost_ended"]))
	_listen(Events.slowmo_requested, func(sc: float, d: float, r: StringName) -> void: _log.append(["slowmo", sc, d, r]))
	_listen(Events.crash_started, func() -> void: _log.append(["crash_started"]))
	_listen(Events.crash_finished, func() -> void: _log.append(["crash_finished"]))
	_listen(Events.run_over, func(res: Dictionary) -> void: _log.append(["run_over", res]))
	_listen(Events.run_started, func(m: StringName, s: int) -> void: _log.append(["run_started", m, s]))
	_listen(Events.checkpoint_crossed, func(leg: int, summary: Dictionary) -> void: _log.append(["checkpoint_crossed", leg, summary]))
	_listen(Events.bonus_awarded, func(k: StringName, p: int, _t: int) -> void: _log.append(["bonus_awarded", k, p]))
	_listen(Events.leg_started, func(leg: int, _b: StringName, _o: StringName) -> void: _log.append(["leg_started", leg]))


func after_each() -> void:
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	tree.paused = false
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame
	Settings.set_value(&"reduced_motion", _reduced)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _make(run_seed: int = SEED, crash_cinematic: bool = false) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = crash_cinematic
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	return r


## A weaving bot on the run's current road and traffic (re-make it after a retry).
func _bot(r: Run, bot_seed: int = BOT_SEED) -> SandboxBot:
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, bot_seed)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	return bot


## n ticks with a rendered frame every TICKS_PER_FRAME ticks.
func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(Tuning.load_default().vehicle.physics_tick_hz))


func _count(name: String) -> int:
	var n := 0
	for e: Array in _log:
		if e[0] == name:
			n += 1
	return n


func _last(name: String) -> Array:
	for i in range(_log.size() - 1, -1, -1):
		if _log[i][0] == name:
			return _log[i]
	return []


# ---------------------------------------------------------------- Flow

func test_countdown_then_running() -> void:
	var r := _make()
	var hud := Tuning.load_default().hud
	eq(r.state, Game.COUNTDOWN)
	eq(Game.state, Game.COUNTDOWN)
	eq(_last("run_started"), ["run_started", RunContext.MODE_JOURNEY, SEED])
	var s0 := r.car.state.s
	var countdown_ticks := _ticks_for(float(hud.countdown_from) * hud.countdown_step_s)
	_run_ticks(r, countdown_ticks - 1)
	eq(r.state, Game.COUNTDOWN, "one tick before GO")
	eq(r.car.state.s, s0, "the car waits on the line during the countdown")
	_run_ticks(r, 1)
	eq(r.state, Game.RUNNING)
	eq(Game.state, Game.RUNNING)
	var ticks: Array = []
	for e: Array in _log:
		if e[0] == "countdown_tick":
			ticks.append(e[1])
	eq(ticks, [3, 2, 1, 0], "countdown_tick 3, 2, 1, GO")
	_run_ticks(r, 60)
	gt(r.car.state.s, s0 + 10.0, "driving after GO")


func test_manual_countdown_waits_for_go() -> void:
	var r := _make()
	r.auto_countdown = false
	_run_ticks(r, _ticks_for(5.0))
	eq(r.state, Game.COUNTDOWN, "WP4.4's screen decides when to go")
	r.go()
	eq(r.state, Game.RUNNING)


func test_pause_freezes_and_resumes() -> void:
	var r := _make()
	r.go()
	r.pause()
	eq(r.state, Game.PAUSED)
	eq(Game.state, Game.PAUSED)
	check(tree.paused, "the tree is paused")
	check(r.screens.pause_screen.visible, "the pause menu shows")
	r.resume()
	eq(r.state, Game.RUNNING)
	eq(Game.state, Game.RUNNING)
	check(not tree.paused)
	r.pause()
	r.toggle_pause()
	eq(r.state, Game.RUNNING, "toggle resumes")


func test_hud_and_feed() -> void:
	var r := _make()
	check(r.hud != null, "the HUD is installed")
	r.go()
	_run_ticks(r, 20)
	gt(r.feed.speed_mps, 0.0, "the feed is filled every frame")
	eq(r.feed.lives, 2)
	eq(r.feed.leg_index, 1)
	gt(r.feed.checkpoint_distance_m, 0.0, "a checkpoint is planned ahead")


# ---------------------------------------------------------------- A whole run

## The Jolt cinematic (CrashSequence) takes the car at the second hit, emits the crash
## events once, ends into the results after its duration, and retry parks it again.
func test_crash_cinematic_flow() -> void:
	var r := _make(SEED, true)
	var t := Tuning.load_default()
	var cs := r.crash_sequence as CrashSequence
	if not check(cs != null, "the cinematic is installed"):
		return
	r.go()
	_run_ticks(r, _ticks_for(1.0))
	r.lives.lives = 1
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.state, Game.CRASH)
	check(cs.is_running(), "the sequence took the car")
	eq(_count("crash_started"), 1, "crash_started once (from the sequence)")
	eq(_last("slowmo"), ["slowmo", t.feel.slowmo_crash_scale, t.feel.slowmo_crash_s, &"crash"])
	var s_crash := r.car.state.s
	_run_ticks(r, 30)
	eq(r.car.state.s, s_crash, "the run no longer ticks the car; the body carries it")
	r.skip()
	eq(r.state, Game.RESULTS, "tap skips to the results")
	eq(_count("crash_finished"), 1, "crash_finished once")
	eq(Engine.time_scale, 1.0)
	r.retry()
	check(not cs.is_running(), "retry parks the bodies")
	eq(r.state, Game.COUNTDOWN)
	r.go()
	_run_ticks(r, _ticks_for(0.5))
	gt(r.car.state.s, r.start_s_m(), "drivable again after retry")


func test_score_hit_crash_results_retry() -> void:
	var r := _make()
	var t := Tuning.load_default()
	_bot(r)
	r.go()
	# Drive until something scores and a chain is held.
	var ticks := 0
	while ticks < _ticks_for(40.0) and (r.scoring.chain() <= 0 or _count("scored") == 0):
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	gt(_count("scored"), 0, "score events on the bus")
	gt(r.scoring.chain(), 0, "a chain is held")
	var chain := r.scoring.chain()

	# First hit.
	r.force_hit(HitDetection.HIT_BARRIER, -1, -1)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.lives.lives, 1)
	check(r.lives.is_ghost(), "ghost period")
	check(r.scoring.is_ghost(), "scoring follows the ghost")
	eq(_last("hit"), ["hit", Events.HIT_BARRIER, 1])
	eq(_last("chain_lost"), ["chain_lost", chain, Events.REASON_HIT], "the chain is lost")
	eq(r.scoring.chain(), 0)
	eq(_last("slowmo"), ["slowmo", t.feel.slowmo_first_hit_scale, t.feel.slowmo_first_hit_s, TimeScale.REASON_FIRST_HIT])
	near(Engine.time_scale, t.feel.slowmo_first_hit_scale, 1e-9, "0.5x")
	check(r.fx.damaged, "damage look after the first hit")
	check(r.fx.get_smoke() != null and r.fx.get_smoke().emitting, "hood smoke")
	check(r.fx.get_lamp() != null and r.fx.get_lamp().visible, "flickering headlight")
	check(r.fx.ghost, "ghost flicker")
	check(not r.legs.is_leg_clean(), "the leg is no longer clean")
	r.time_scale.advance_real(t.feel.slowmo_first_hit_s + FRAME_S)
	eq(Engine.time_scale, 1.0, "back to 1.0x")

	# A contact during the ghost does not count.
	r.force_hit(HitDetection.HIT_BARRIER)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.lives.lives, 1, "ghost: ignored")
	eq(r.state, Game.RUNNING)
	_run_ticks(r, _ticks_for(t.lives.ghost_period_s))
	check(not r.lives.is_ghost())
	eq(_count("ghost_ended"), 1)

	# Second hit: crash, then results.
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.state, Game.CRASH)
	eq(Game.state, Game.CRASH)
	eq(_count("crash_started"), 1)
	eq(_last("slowmo"), ["slowmo", t.feel.slowmo_crash_scale, t.feel.slowmo_crash_s, TimeScale.REASON_CRASH])
	check(r.scoring.is_ended(), "scoring ended at the second hit")
	var braking := 0
	for i in r.sim.state.capacity:
		if r.sim.state.active[i] != 0 and r.sim.state.has_flag(i, TrafficState.FLAG_HIT):
			braking += 1
	gt(braking, 0, "surrounding traffic brakes (hazards on)")
	var s_crash := r.car.state.s
	_run_ticks(r, 60)
	lt(r.car.state.v, Units.kmh_to_mps(400.0), "still simulated during the crash")
	gt(r.car.state.s, s_crash, "the car skids on")
	r.frame(t.feel.slowmo_crash_s * 0.5)
	eq(r.state, Game.CRASH, "the cinematic runs its time")
	r.frame(t.feel.slowmo_crash_s * 0.5 + FRAME_S)
	eq(r.state, Game.RESULTS, "results after the crash time")
	eq(Game.state, Game.RESULTS)
	eq(_count("crash_finished"), 1)
	eq(Engine.time_scale, 1.0)
	var over := _last("run_over")
	check(not over.is_empty(), "run_over fired")
	var res: Dictionary = over[1]
	for key: StringName in [&"score", &"distance_m", &"legs_completed", &"coast_reached", &"best_chain",
			&"best_multiplier", &"threads", &"close_passes", &"top_speed_kmh", &"night_time_s", &"hits",
			&"seed", &"mode"]:
		check(res.has(key), "results has %s" % key)
	eq(res[&"hits"], 2)
	eq(res[&"seed"], SEED)
	eq(res[&"mode"], RunContext.MODE_JOURNEY)
	eq(res[&"score"], r.scoring.banked())
	ge(float(res[&"best_chain"]), float(chain), "the lost chain counts as the best chain")
	gt(float(res[&"distance_m"]), 100.0)
	gt(float(res[&"top_speed_kmh"]), 150.0)
	check(r.screens.results_screen.visible, "results screen")

	# Retry: back on the road in the same frame, new seed, everything reset.
	var frames_before := Engine.get_process_frames()
	var t0 := Time.get_ticks_usec()
	r.retry()
	var usec := Time.get_ticks_usec() - t0
	print("      retry rebuild: %.0f ms (budget %.1f s)" % [usec / 1000.0, t.hud.retry_max_s])
	eq(Engine.get_process_frames() - frames_before, 0, "retry needs no frame (no scene reload)")
	le(float(usec), t.hud.retry_max_s * 1e6, "retry rebuild inside hud.retry_max_s")
	eq(r.state, Game.COUNTDOWN)
	eq(Game.state, Game.COUNTDOWN)
	ne(r.current_seed, SEED, "a new seed per Journey run")
	eq(r.run_count, 2)
	eq(r.lives.lives, 2)
	eq(r.scoring.banked(), 0)
	eq(r.stats.hits, 0)
	near(r.car.state.s, r.start_s_m(), 1e-6, "back on the start line")
	check(not r.fx.damaged, "damage cleared")
	check(not r.screens.results_screen.visible)
	gt(r.sim.state.count, 0, "traffic refilled")
	_bot(r)
	_run_ticks(r, _ticks_for(3.0) + 10)
	eq(r.state, Game.RUNNING, "and driving again after the countdown")


## The ghost flicker never shows a body the cockpit camera hid (and restores hidden).
func test_ghost_flicker_respects_hidden_body() -> void:
	var r := _make()
	r.go()
	_run_ticks(r, 10)
	r.car.set_body_visible(false)
	r.fx.start_ghost(1.0)
	for i in 30:
		r.fx.advance(1.0 / 60.0)
		if r.car.visual.visible:
			fail("body shown by the flicker at step %d" % i)
			break
	r.fx.stop_ghost()
	check(not r.car.visual.visible, "still hidden after the ghost")
	r.car.set_body_visible(true)
	check(r.car.visual.visible)


func test_retry_seeds_are_deterministic() -> void:
	var a := _make()
	a.retry()
	a.retry()
	var seeds_a := [a.current_seed]
	var b := _make()
	b.retry()
	b.retry()
	eq(seeds_a, [b.current_seed], "run k's seed depends only on the first seed and k")
	eq(a.current_seed, Rng.derive_seed(SEED, "retry/2"))


func test_checkpoint_crossing_runs_the_leg_sequence() -> void:
	var r := _make()
	var t := Tuning.load_default()
	r.go()
	_run_ticks(r, 4)
	var cp := r.legs.distance_to_checkpoint(r.car.state.s)
	check(is_finite(cp), "a checkpoint is queued")
	r.sun.sky_t = 0.4   # late afternoon: the crossing lifts the sun visibly
	# Jump to just before the line and roll across it.
	r.dev_teleport(r.car.state.s + cp - 15.0, Units.kmh_to_mps(180.0))
	var ticks := 0
	while r.legs.legs_completed == 0 and ticks < _ticks_for(3.0):
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	eq(r.legs.legs_completed, 1, "crossed")
	var crossed := _last("checkpoint_crossed")
	check(not crossed.is_empty(), "checkpoint_crossed on the bus")
	eq(crossed[1], 1)
	var summary: Dictionary = crossed[2]
	eq(summary[&"clean"], true, "no hit in the leg")
	var clean_paid := false
	for e: Array in _log:
		if e[0] == "bonus_awarded" and e[1] == LegTracker.BONUS_CLEAN:
			clean_paid = true
			eq(e[2], t.legs.bonus_clean_points, "Clean bonus, day")
	check(clean_paid, "leg bonus paid")
	ge(int(summary[&"bonus_points"]), t.legs.bonus_clean_points)
	eq(_last("leg_started"), ["leg_started", 2])
	eq(r.director.leg, 2, "director difficulty follows the leg")
	lt(r.sun.sky_t, 0.4 - Units.pct_to_frac(t.sun.checkpoint_lift_pct) * t.sun.day_span() + 0.01,
		"the checkpoint lifted the sun")


func test_clean_leg_restores_a_life() -> void:
	var r := _make()
	r.go()
	r.force_hit(HitDetection.HIT_BARRIER)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.lives.lives, 1)
	# The hit leg is not clean: no restore at its checkpoint.
	var cp := r.legs.distance_to_checkpoint(r.car.state.s)
	r.dev_teleport(r.car.state.s + cp - 10.0, Units.kmh_to_mps(180.0))
	_run_ticks(r, _ticks_for(1.0))
	eq(r.legs.legs_completed, 1)
	eq(r.lives.lives, 1, "hit leg: no life back")
	# The next leg is clean.
	cp = r.legs.distance_to_checkpoint(r.car.state.s)
	check(is_finite(cp), "the next checkpoint is queued")
	r.dev_teleport(r.car.state.s + cp - 10.0, Units.kmh_to_mps(180.0))
	_run_ticks(r, _ticks_for(1.0))
	eq(r.legs.legs_completed, 2)
	eq(r.lives.lives, 2, "clean leg restores the life")


func test_night_switches_traffic_headlights() -> void:
	var r := _make()
	r.go()
	_run_ticks(r, 2)
	check(not r.sim.headlights(), "afternoon: headlights off")
	r.sun.sky_t = Tuning.load_default().sun.sky_t_night
	r.sun.phase = SunClock.Phase.NIGHT
	_run_ticks(r, 2)
	check(r.sim.headlights(), "night: headlights on (the sky's headlight ramp)")
	check(r.director.is_night)
	check(r.scoring.is_night(), "scoring x2 follows the sun clock")
	eq(r.sky.sky_t, r.sun.sky_t, "the sun drives the sky")


# ---------------------------------------------------------------- Tick order and determinism

func test_tick_order_follows_the_contract() -> void:
	var r := _make()
	var t := Tuning.load_default()
	r.go()
	_run_ticks(r, 10)
	var order := Order.new()
	var spy_lives := SpyLives.new(t.lives)
	spy_lives.order = order
	r.lives = spy_lives
	var spy_scoring := SpyScoring.new(r.ctx)
	spy_scoring.order = order
	spy_scoring.set_player_body(r.car.car.length_m, r.car.car.width_m)
	r.scoring = spy_scoring
	r.adapter.scoring = spy_scoring
	var spy_sun := SpySun.new(t.sun, t.legs)
	spy_sun.order = order
	r.sun = spy_sun
	var spy_legs := SpyLegs.new(t.legs)
	spy_legs.order = order
	spy_legs.plan_ahead(r.road, r.car.state.s + 1000.0)
	r.legs = spy_legs
	r.adapter.legs = spy_legs
	r.drive_controller = SpyController.new(order, PlayerController.new(r.hub))
	var traffic_before := r.sim.state.trace_hash()
	r.tick()
	eq(order.calls, PackedStringArray(["controller", "lives", "scoring", "sun", "legs"]),
		"controller -> (physics, traffic) -> lives/hits -> scoring -> sun -> legs")
	ne(order.traffic_hash_at_scoring, traffic_before, "traffic stepped before scoring")
	eq(order.traffic_hash_at_scoring, r.sim.state.trace_hash(), "scoring saw this tick's traffic")
	eq(order.player_hash_at_scoring, r.car.state.trace_hash(), "scoring saw this tick's car")


func test_same_seed_same_inputs_same_run() -> void:
	var hashes: Array = []
	for pass_i in 2:
		var r := _make()
		_bot(r)
		r.go()
		var trace := PackedInt64Array()
		for sec in 20:
			_run_ticks(r, _ticks_for(1.0))
			trace.append(r.trace_hash())
		hashes.append(trace)
		gt(r.car.state.s, 500.0, "the bot drove")
		r.queue_free()
		_runs.erase(r)
		await tree.process_frame
	eq(hashes[0], hashes[1], "identical 20 s traces")


func test_slow_motion_does_not_change_the_run() -> void:
	# The sim dt is fixed per tick: a run with slow motion and one with reduced motion
	# (no slow motion) produce the same trace.
	var hashes: Array = []
	for reduced: bool in [false, true]:
		Settings.set_value(&"reduced_motion", reduced)
		var r := _make()
		_bot(r)
		r.go()
		_run_ticks(r, _ticks_for(2.0))
		r.force_hit(HitDetection.HIT_BARRIER)
		_run_ticks(r, _ticks_for(4.0))
		hashes.append(r.trace_hash())
		eq(r.time_scale.applied_count, 0 if reduced else 1)
		r.queue_free()
		_runs.erase(r)
		await tree.process_frame
	eq(hashes[0], hashes[1])


func test_infinite_lives_dev_toggle() -> void:
	var r := _make()
	r.infinite_lives = true
	r.go()
	for i in 3:
		r.force_hit(HitDetection.HIT_BARRIER)
		_run_ticks(r, _ticks_for(Tuning.load_default().lives.ghost_period_s) + 4)
	eq(r.state, Game.RUNNING, "never crashes")
	eq(r.lives.lives, r.lives.max_lives, "topped up after the ghost")


func test_engine_driven_frames() -> void:
	# The engine's own loop (not manual ticks): physics and process frames drive it.
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	await tree.process_frame
	r.go()
	var s0 := r.car.state.s
	for i in 60:
		await tree.physics_frame
	gt(r.car.state.s - s0, 5.0, "the car drives in the engine loop")
	gt(r.tick_count, 50)
	var rig: CameraRig = r.get_node("CameraRig")
	lt(rig.camera().global_position.distance_to(r.car.global_position), 40.0, "camera near the car")
	gt(r.builder.active_chunk_count(), 0, "road is built")


func test_ticks_create_no_objects() -> void:
	# Per-tick glue allocates no objects (CLAUDE.md rule 6). Director batches and road
	# generation are director rate: measured over a window without either.
	var r := _make()
	_bot(r)
	r.go()
	_run_ticks(r, _ticks_for(2.0))
	var batches := r.director.batches_planned
	var generated := r.road.length_generated()
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 60:
		r.tick()
	if r.director.batches_planned != batches or r.road.length_generated() != generated:
		print("      (a batch or road chunk landed in the window; skipped)")
		return
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects created by 60 ticks")
