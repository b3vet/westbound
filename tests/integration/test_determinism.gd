extends "res://tests/integration/run_harness.gd"
## WP4.5: determinism of the whole loop. Spec: Architecture rule 5 (deterministic by
## seed: same seed + same inputs = same run), Modes (Daily Drive replays one seed),
## Run end (retry). The real Run with a weaving, boosting bot in real traffic: hits,
## the crash, the results and retries included. The run state is hashed with
## Run.trace_hash (car, traffic, scoring, lives, legs, objective, sun, stats).
##
## Fast tier: through a crash and a retry, twice. Soak tier: 10 simulated minutes
## (retrying after every crash), twice, identical traces, no engine errors, no dropped
## events.

const SOAK_S := 600
const TRACE_EVERY_S := 10
const TRACES := 60   # SOAK_S / TRACE_EVERY_S


func test_same_seed_through_crash_and_retry() -> void:
	var a := await _crash_and_retry()
	var b := await _crash_and_retry()
	eq(a, b, "identical traces through hits, the crash, the results and a retry")


## Regression (found by the soak): the director's behind-spawn view check read the
## camera's render-interpolated pose, which outside a physics frame is wherever the
## engine last drew it, so two identical runs spawned different traffic. The check must
## follow the camera's simulated pose: here the camera jumps 1 km without an engine
## frame in between.
func test_behind_spawn_view_check_uses_the_simulated_camera() -> void:
	var r := _make()
	r.go()
	await tree.process_frame   # the engine draws the camera where it is now
	var old_s := r.car.state.s
	r.dev_teleport(old_s + 1000.0, r.car.state.v)   # snaps the camera, no frame drawn
	var lane := t.legs.start_lane
	var ahead := r.car.state.s + 40.0
	check(r.director.is_visible(ahead, r.road.lane_center_d(lane, ahead)), "40 m ahead of the camera: in view")
	var left := old_s + 40.0
	check(not r.director.is_visible(left, r.road.lane_center_d(lane, left)), "1 km behind the camera: out of view")


func soak_ten_minutes_twice_identical() -> void:
	var first := await _soak()
	var second := await _soak()
	eq(first.size(), TRACES)
	eq(first, second, "identical 10-minute traces")


func _bot(r: Run) -> BoostingBot:
	var bot := BoostingBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	return bot


## Drive, two scripted hits, the fallback crash to the results, retry, drive again.
func _crash_and_retry() -> PackedInt64Array:
	_log.clear()
	var r := _make()
	_bot(r)
	r.go()
	var trace := PackedInt64Array()
	_run_s(r, 2.0)
	trace.append(r.trace_hash())
	if r.state == Game.RUNNING and r.lives.lives == r.lives.max_lives:
		r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_run_s(r, t.lives.ghost_period_s + 0.5)
	trace.append(r.trace_hash())
	if r.state == Game.RUNNING:
		r.force_hit(HitDetection.HIT_BARRIER, -1, -1)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.state, Game.CRASH)
	check(_run_until(r, func() -> bool: return r.state == Game.RESULTS, t.feel.slowmo_crash_s + 1.0), "results")
	trace.append(r.trace_hash())
	trace.append(r.scoring.banked())
	r.retry()
	_bot(r)
	r.go()
	_run_s(r, 3.0)
	trace.append(r.trace_hash())
	await _drop(r)
	return trace


func _soak() -> PackedInt64Array:
	_log.clear()
	var r := _make()
	_bot(r)
	r.go()
	var trace := PackedInt64Array()
	var retries := 0
	var distance := 0.0
	var best := 0
	var ticks_per_trace := _ticks_for(float(TRACE_EVERY_S))
	for k in TRACES:
		for i in ticks_per_trace:
			_run_ticks(r, 1)
			if r.state == Game.RESULTS:
				distance += r.stats.distance_m
				best = maxi(best, r.scoring.banked())
				retries += 1
				r.retry()
				_bot(r)
				r.go()
		trace.append(r.trace_hash())
		eq(r.events.dropped, 0, "no dropped events")
		check(is_finite(r.car.state.s) and is_finite(r.car.state.v), "finite state")
	distance += r.stats.distance_m
	print("      soak: %d s simulated, %.1f km, %d runs, best %d, %d scored events, %d hits" % [
		SOAK_S, distance / 1000.0, retries + 1, maxi(best, r.scoring.banked()), _count("scored"), _count("hit")])
	gt(_count("scored"), 10, "the bot kept scoring")
	await _drop(r)
	return trace
