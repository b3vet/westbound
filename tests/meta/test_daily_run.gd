extends WBTest
## WP8.4: Daily Drive's ghost on a real run (DailyDrive on the Run): the run records its
## ghost at 20 Hz, the day's best is kept, a retry plays it back exactly on the recorded
## path, the ghost changes nothing in the run, it is off in other modes and when disabled,
## and the per-tick hooks allocate nothing. Also the determinism check's scripted run
## (DailyTrace) in short. Spec: Core loop → Modes at launch (Daily Drive), Architecture
## rule 2. docs/DAILY.md.

const RUN_SCENE := preload("res://src/run/run.tscn")
const DATE := "2026-09-30"
const DRIVE_S := 3.0
const TICKS_PER_FRAME := 2
const FRAME_S := 1.0 / 60.0
const MATCH_M := 0.005
const ALLOC_TICKS := 1000

var dt: DailyTuning
var _nodes: Array[Node] = []
var _dir: String


func before_all() -> void:
	dt = DailyTuning.resolve()


func before_each() -> void:
	_dir = "user://test_daily_run_%d" % OS.get_process_id()
	_wipe()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	_wipe()
	await tree.process_frame


func _wipe() -> void:
	if DirAccess.dir_exists_absolute(_dir):
		for f in DirAccess.get_files_at(_dir):
			DirAccess.remove_absolute(_dir.path_join(f))
		DirAccess.remove_absolute(_dir)


## A Daily run on DATE with its ghost store in the test folder (restarted so the store is used).
func _run(mode: StringName = RunContext.MODE_DAILY, tuning: DailyTuning = null) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.mode = mode
	r.daily_date = DATE
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_nodes.append(r)
	if tuning != null:
		r.daily.tuning = tuning
	r.daily.store = DailyGhostStore.new({}, r.daily.tuning, _dir)
	r.daily.today = DATE
	r.daily.save_enabled = true
	r.retry()
	return r


## Drives `seconds` with the open-loop script driver (the same inputs every time).
## `each` is called after every tick.
func _drive(r: Run, seconds: float, each: Callable = Callable()) -> void:
	var hz := r.tuning.vehicle.physics_tick_hz
	r.drive_controller = DailyScriptDriver.new(dt, hz)
	r.go()
	for i in roundi(seconds * float(hz)):
		r.tick()
		if r.tick_count % TICKS_PER_FRAME == 0:
			r.frame(FRAME_S)
		if each.is_valid():
			each.call(i + 1)


func test_a_daily_run_records_and_a_retry_plays_it_back() -> void:
	var r := _run()
	var dd := r.daily
	check(dd.active, "Daily Drive records")
	eq(dd.date, DATE)
	eq(r.current_seed, Rng.daily_seed(2026, 9, 30), "the date's seed")
	check(not dd.playback.has_ghost(), "no ghost on the first run of the day")
	_drive(r, DRIVE_S)
	dd.on_run_over({RunStats.SCORE: 1234})
	check(dd.saved, "the first run of the day is kept")
	eq(dd.store.best_score(DATE), 1234)
	var g := dd.store.load_ghost(DATE)
	if not check(g != null, "its file"):
		return
	eq(g.sample_count, roundi(DRIVE_S * dt.ghost_sample_hz) + 1, "20 Hz and the final sample")
	eq(g.seed_value, r.current_seed)
	eq(g.car, String(r.car.car.id))
	r.retry()
	check(dd.playback.has_ghost(), "a retry of the same date plays it")
	eq(r.current_seed, g.seed_value, "Daily keeps the seed on retry")
	var worst := [0.0, 0]
	var every := dt.ghost_sample_ticks(r.tuning.vehicle.physics_tick_hz)
	_drive(r, DRIVE_S - 0.5, func(k: int) -> void:
		dd.update_view()
		if (k - 1) % every != 0:
			return
		var err := dd.ghost_car.global_position.distance_to(r.car.global_position)
		if err > worst[0]:
			worst[0] = err
		worst[1] += 1)
	gt(float(worst[1]), 0.0, "sample ticks compared")
	lt(worst[0], MATCH_M, "same seed, same inputs: the ghost drives exactly on the car (%.4f m)" % worst[0])
	check(dd.ghost_car.visible, "drawn")
	eq(dd.ghost_car.draw_count(), 1, "one draw")
	dd.on_run_over({RunStats.SCORE: 1000})
	check(not dd.saved, "a worse run does not replace the best")
	eq(dd.store.best_score(DATE), 1234)


func test_the_ghost_changes_nothing_in_the_run() -> void:
	var a := _run()
	_drive(a, DRIVE_S)
	var plain := a.trace_hash()
	a.daily.on_run_over({RunStats.SCORE: 50})
	a.retry()
	check(a.daily.playback.has_ghost(), "the ghost is on")
	_drive(a, DRIVE_S, func(_k: int) -> void: a.daily.update_view())
	check(a.daily.ghost_car.visible, "and drawn")
	eq(a.trace_hash(), plain, "no collisions, no scoring: the run's state is the same with the ghost")


func test_disabled_or_other_modes_draw_nothing() -> void:
	var off := dt.duplicate() as DailyTuning
	off.ghost_enabled = false
	var r := _run(RunContext.MODE_DAILY, off)
	_drive(r, 1.0)
	r.daily.on_run_over({RunStats.SCORE: 50})
	check(not r.daily.saved, "disabled: nothing kept")
	r.daily.store.write(r.daily.recorder.ghost)   # a ghost of the day exists anyway
	r.retry()
	check(not r.daily.playback.has_ghost(), "disabled: not loaded")
	_drive(r, 0.5, func(_k: int) -> void: r.daily.update_view())
	check(not r.daily.ghost_car.visible, "disabled: hidden")
	eq(r.daily.ghost_car.draw_count(), 0, "disabled: no draw")
	var j := _run(RunContext.MODE_JOURNEY)
	check(not j.daily.active, "Journey: no Daily ghost")
	_drive(j, 0.5, func(_k: int) -> void: j.daily.update_view())
	j.daily.on_run_over({RunStats.SCORE: 50})
	check(not j.daily.saved, "Journey: nothing kept")
	eq(j.daily.ghost_car.draw_count(), 0, "Journey: no draw")


func test_hooks_allocate_nothing() -> void:
	var r := _run()
	_drive(r, 1.0)
	r.daily.on_run_over({RunStats.SCORE: 50})
	r.retry()
	r.go()
	var dd := r.daily
	dd.after_tick(true)
	dd.update_view()
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in ALLOC_TICKS:
		dd.after_tick(true)
		dd.update_view()
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects per tick or frame")
	check(dd.recorder.ghost.sample_count > 0, "it recorded meanwhile")


func test_the_determinism_check_runs_and_repeats() -> void:
	var first := _trace(1)
	var second := _trace(1)
	if not check(first.size() >= 6, "info, libm, detmath, params, a second, done: %s" % str(first)):
		return
	check(first[0].begins_with("DT info date=%s" % DATE), first[0])
	check(first[0].contains("driver=script"), "the open-loop driver by default")
	check(first[1].begins_with("DT libm "), "the libm probe")
	check(first[2].begins_with("DT detmath "), "the DetMath probe (N8.2)")
	check(first[3].begins_with("DT params ") and first[3].contains(" cap_time_s="), "the car's constants")
	check(first[4].begins_with("DT sec=1 all=") and first[4].contains(" score="), first[4])
	eq(first[first.size() - 1], "DT done seconds=1")
	eq(second, first, "the same run twice: the same trace")


func _trace(seconds: int) -> PackedStringArray:
	var host := Node.new()
	tree.root.add_child(host)
	_nodes.append(host)
	var t := DailyTrace.new(dt)
	t.start(host, DATE, seconds)
	var guard := 0
	while not t.step_ticks(dt.check_web_ticks_per_step) and guard < seconds * 4:
		guard += 1
	var lines := t.take_lines()
	t.finish()
	return lines
