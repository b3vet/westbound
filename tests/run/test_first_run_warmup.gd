extends WBTest
## The first run's empty-road warm-up (WP8.1) on the real Run: 20 s of RUNNING with no
## traffic on either carriageway (the prefill too), then the density fades back in and
## traffic arrives from beyond the fog; SKIP; the countdown and the pause do not count;
## only a Journey from the title on a fresh save warms up (not Daily, not a retry, not a
## direct boot, not with the first run off); recorded in the save; the run is kept off the
## leaderboards; deterministic. Spec: Controls → Settings and first run. docs/RUN.md →
## First-run warm-up.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2

var t: Tuning
var _nodes: Array[Node] = []
var _was_enabled: bool = false


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.restore_defaults()
	_was_enabled = Save.first_run_enabled
	Save.first_run_enabled = true
	Save.reset_fresh()


func after_each() -> void:
	tree.paused = false
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame
	Save.first_run_enabled = _was_enabled
	Save.reset_fresh()
	Settings.restore_defaults()


func _run(run_seed: int = SEED) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.title_on_boot = true
	tree.root.add_child(r)
	_nodes.append(r)
	r.screens.persist_settings = false
	r.title.persist_settings = false
	return r


## From the title, as PLAY does after the chooser, then GO.
func _start(r: Run, mode: StringName = RunContext.MODE_JOURNEY) -> void:
	r.start_mode(mode)
	r.go()


func _ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(t.vehicle.physics_tick_hz))


static func _vehicles(r: Run) -> int:
	return r.sim.state.count + r.director.opposite.state.count


func test_twenty_seconds_of_empty_road_then_traffic() -> void:
	var r := _run()
	_start(r)
	check(r.warmup.active, "the first Journey warms up")
	eq(_vehicles(r), 0, "the road starts empty (no prefill)")
	eq(r.director.density_scale, 0.0)
	check(not r.director.racer_arrivals_enabled, "no racers from behind either")
	var warm := _ticks_for(t.meta.warmup_s)
	var most := 0
	for i in warm - 1:
		_ticks(r, 1)
		most = maxi(most, _vehicles(r))
	eq(most, 0, "no vehicle on either carriageway for the whole warm-up")
	check(r.warmup.active, "still warming up one tick before the end")
	_ticks(r, 1)
	check(not r.warmup.active, "over after exactly warmup_s of RUNNING")
	check(r.director.racer_arrivals_enabled, "arrivals back")
	gt(r.director.density_scale, 0.0, "the fade-in starts at once")
	lt(r.director.density_scale, 1.0)
	check(not Save.warmup_pending(), "recorded as done")
	_ticks(r, _ticks_for(t.meta.warmup_fade_s))
	near(r.director.density_scale, 1.0, 1e-9, "full density after the fade")
	gt(r.sim.state.count, 0, "traffic has arrived")
	check(r.state == Game.RUNNING)


func test_every_vehicle_arrives_beyond_the_fog() -> void:
	var r := _run()
	_start(r)
	_ticks(r, _ticks_for(t.meta.warmup_s))
	var near_count := 0
	var fog := r.director.min_ahead_m()
	for i in _ticks_for(t.meta.warmup_fade_s):
		var before := r.sim.state.next_vehicle_id
		_ticks(r, 1)
		# New vehicles never appear inside the view (rule 5: spawned beyond the fog or behind).
		for k in r.sim.state.capacity:
			if r.sim.state.active[k] == 1 and r.sim.state.vehicle_id[k] >= before:
				var ds := r.sim.state.s[k] - r.car.state.s
				if ds > 0.0 and ds < fog:
					near_count += 1
	eq(near_count, 0, "traffic fades in out of the distance")


func test_skip_ends_it_now() -> void:
	var r := _run()
	_start(r)
	_ticks(r, _ticks_for(2.0))
	check(r.warmup.hint != null and r.warmup.hint.visible, "the hint shows")
	eq(r.warmup.hint.seconds, roundi(t.meta.warmup_s - 2.0), "with the seconds left")
	r.warmup.hint.skip_button.pressed.emit()
	check(not r.warmup.active, "SKIP ends the empty road")
	check(r.warmup.skipped)
	gt(r.director.density_scale, 0.0)
	check(not Save.warmup_pending())
	check(r.warmup.hint.ending, "TRAFFIC AHEAD")
	check(not r.warmup.hint.skip_button.visible)
	_ticks(r, _ticks_for(t.meta.warmup_end_note_s) + 1)
	check(not r.warmup.hint.visible, "the hint goes")


func test_countdown_and_pause_do_not_count() -> void:
	var r := _run()
	r.start_mode(RunContext.MODE_JOURNEY)
	var left := r.warmup.ticks_left
	_ticks(r, _ticks_for(1.0))   # the countdown
	eq(r.warmup.ticks_left, left, "the countdown does not count")
	r.go()
	_ticks(r, 10)
	eq(r.warmup.ticks_left, left - 10)
	r.pause()
	_ticks(r, 50)
	eq(r.warmup.ticks_left, left - 10, "the pause does not count")
	check(r.warmup.active)
	r.resume()


func test_only_the_first_journey_from_the_title() -> void:
	var r := _run()
	_start(r, RunContext.MODE_DAILY)
	check(not r.warmup.active, "Daily Drive never warms up (same traffic for everyone)")
	check(Save.warmup_pending(), "still pending for the first Journey")
	r.enter_menu()
	_start(r)
	check(r.warmup.active, "the first Journey does")
	_ticks(r, _ticks_for(t.meta.warmup_s) + 1)
	r.lives.lives = 1
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_ticks(r, TICKS_PER_FRAME)
	r.skip()
	eq(r.state, Game.RESULTS)
	check(bool(r.last_results.get(RunWarmup.RESULT_KEY, false)), "the results say it warmed up")
	check(not NetRunPayload.eligible(r.last_results, NetTuning.load_default()), "kept off the leaderboards")
	r.retry()
	r.go()
	check(not r.warmup.active, "a retry never warms up")
	gt(_vehicles(r), 0, "traffic from the start")
	eq(r.director.density_scale, 1.0)


func test_quitting_early_keeps_it_pending() -> void:
	var r := _run()
	_start(r)
	_ticks(r, _ticks_for(3.0))
	r.pause()
	r.enter_menu()
	check(not r.warmup.active, "the title ends it")
	check(r.warmup.hint == null or not r.warmup.hint.visible)
	check(Save.warmup_pending(), "the next Journey warms up again")
	_start(r)
	check(r.warmup.active)


func test_off_when_the_first_run_is_off() -> void:
	Save.first_run_enabled = false
	var r := _run()
	_start(r)
	check(not r.warmup.active, "tests and tools: no warm-up")
	gt(_vehicles(r), 0)


func test_a_direct_boot_never_warms_up() -> void:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_nodes.append(r)
	r.go()
	check(not r.warmup.active, "?title=0 and tools boot straight into traffic")


func test_deterministic() -> void:
	var hashes: Array[int] = []
	for k in 2:
		Save.reset_fresh()
		var r := _run()
		_start(r)
		var h := 0
		for i in _ticks_for(t.meta.warmup_s + 6.0):
			_ticks(r, 1)
			if i % 60 == 0:
				h = TraceHash.mix_int(h, r.trace_hash())
				h = TraceHash.mix_int(h, _vehicles(r))
		hashes.append(h)
		_nodes.erase(r)
		r.free()
	eq(hashes[0], hashes[1], "same seed, same warm-up: the same run")


func test_empty_for_other_seeds() -> void:
	for sd: int in [424242, 9001]:
		Save.reset_fresh()
		var r := _run(sd)
		_start(r)
		var most := _vehicles(r)
		for i in _ticks_for(t.meta.warmup_s) - 1:
			_ticks(r, 1)
			most = maxi(most, _vehicles(r))
		eq(most, 0, "seed %d: empty for the whole warm-up" % sd)
		_nodes.erase(r)
		r.free()


func test_title_play_chooser_then_the_warmup() -> void:
	var r := _run()
	r.title.set_screen(Rect2(0.0, 0.0, 1280.0, 720.0), Rect2(0.0, 0.0, 1280.0, 720.0))
	eq(r.state, Game.MENU)
	r.title.title.play.emit(RunContext.MODE_JOURNEY)
	eq(r.state, Game.MENU, "the chooser first: no run yet")
	check(r.title.first_run != null and r.title.first_run.visible)
	r.title.first_run.drive()
	eq(r.state, Game.COUNTDOWN, "DRIVE: the countdown")
	check(not Save.chooser_pending())
	r.go()
	check(r.warmup.active, "then the empty-road warm-up")
	eq(_vehicles(r), 0)
