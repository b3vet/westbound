extends WBTest
## WP8.3: every achievement's trigger through the real `Events` bus and the run's results
## (table-driven: one row per catalog entry, each checked locked one step before and
## unlocked by its final step), the mode rules (loop sectors are not legs; events outside
## a run count for nothing; QUIT drops the run's values), unlock-once, the save's round
## trip (JSON, a reload, a migration), and the quiet unlock of what an older save already
## earned. The service is a listener only. Spec: Garage and progression (Achievements);
## Scoring; Core loop; Save data. docs/ACHIEVEMENTS.md.

const SECTION := AchievementService.SECTION

var svc: AchievementService
var cat: AchievementCatalog
var _saved: Dictionary
var _got: Array[StringName] = []


func before_all() -> void:
	cat = AchievementCatalog.load_path(AchievementTuning.load_default().catalog_path)


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	_fresh_save()
	_got.clear()
	svc = _service()


func after_each() -> void:
	if svc != null and is_instance_valid(svc):
		svc.free()
	svc = null
	Save.data = _saved
	Save.dirty = false
	Settings.reset_to_defaults()


func _fresh_save() -> void:
	for k: String in [SECTION, Garage.SECTION_STATS, Garage.SECTION_UNLOCKS, Garage.SECTION_GARAGE]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true   # whatever bests other tests left


func _service() -> AchievementService:
	var s := AchievementService.new()
	s.run_under_tools = true
	s.show_toast = false
	s.haptic_tick = false
	s.platform = PlatformLeaderboards.recorder()
	tree.root.add_child(s)
	s.unlocked.connect(func(id: StringName) -> void: _got.append(id))
	return s


# ---------------------------------------------------------------- Bus helpers

func _start(mode: StringName = &"journey") -> void:
	Events.run_started.emit(mode, 1)


func _over(mode: StringName = &"journey", extra: Dictionary = {}) -> void:
	var r := {RunStats.MODE: mode, RunStats.SCORE: 0, RunStats.TOP_SPEED_KMH: 0.0, RunStats.LEGS_COMPLETED: 0,
			RunStats.COAST_REACHED: false, RunStats.DISTANCE_M: 0.0}
	r.merge(extra, true)
	Events.run_over.emit(r)


func _thread(n: int = 1) -> void:
	for i in n:
		Events.scored.emit(Events.THREAD, 50, 5.0, 1.0)


func _close(n: int = 1, clearance: float = 0.8) -> void:
	for i in n:
		Events.scored.emit(Events.CLOSE_PASS, 30, 3.0, clearance)


func _cross(n: int = 1, clean: bool = false, heat: bool = false) -> void:
	for i in n:
		Events.checkpoint_crossed.emit(i + 1, {RunEvents.SUMMARY_CLEAN: clean, RunEvents.SUMMARY_HEAT: heat})


func _piece(hit: bool = false) -> void:
	Events.set_piece_started.emit(&"convoy")
	if hit:
		Events.hit.emit(Events.HIT_TRAFFIC, 1)
	Events.set_piece_ended.emit(&"convoy")


func _stats() -> Dictionary:
	return Save.section(Garage.SECTION_STATS)


func _prog() -> ProgressionTuning:
	return Garage.tuning()


# ---------------------------------------------------------------- The table

## One row per achievement: `steps` leaves it one step short, `final` takes that step.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		{id = &"first_thread", steps = _start, final = _thread},
		{id = &"threads_run", steps = _s_threads_run, final = _thread},
		{id = &"threads_total", steps = _s_threads_total, final = _thread},
		{id = &"close_passes_run", steps = _s_close_passes_run, final = _close},
		{id = &"hairline", steps = _s_hairline, final = _f_hairline},
		{id = &"multiplier_50", steps = _s_multiplier_50, final = _f_multiplier_50},
		{id = &"multiplier_100", steps = _s_multiplier_100, final = _f_multiplier_100},
		{id = &"top_speed_300", steps = _s_top_speed, final = _f_top_speed},
		{id = &"first_leg", steps = _start, final = _cross},
		{id = &"halfway", steps = _s_halfway, final = _cross},
		{id = &"coast", steps = _s_coast, final = _f_coast},
		{id = &"clean_journey", steps = _start, final = _f_coast},
		{id = &"clean_legs", steps = _s_clean_legs, final = _f_clean_leg},
		{id = &"heat", steps = _s_heat, final = _f_heat},
		{id = &"night_survived", steps = _s_night, final = _f_dawn},
		{id = &"night_thread", steps = _s_night_thread, final = _thread},
		{id = &"hazards", steps = _s_hazards, final = _piece},
		{id = &"big_bank", steps = _s_big_bank, final = _f_big_bank},
		{id = &"half_million", steps = _s_half_million, final = _f_half_million},
		{id = &"objectives", steps = _s_objectives, final = _f_objective},
		{id = &"level_10", steps = _s_level, final = _f_level},
		{id = &"new_wheels", steps = _s_new_wheels, final = _f_new_wheels},
		{id = &"daily_driver", steps = _start_daily, final = _over_daily},
		{id = &"daily_streak", steps = _s_daily_streak, final = _f_daily_streak},
		{id = &"in_the_loop", steps = _start_loop, final = _over_loop},
	]
	return out


func _start_daily() -> void:
	_start(&"daily")


func _over_daily() -> void:
	_over(&"daily")


func _start_loop() -> void:
	_start(&"loop")


func _over_loop() -> void:
	_over(&"loop")


func _s_threads_run() -> void:
	_start()
	_thread(9)


func _s_threads_total() -> void:
	_stats()[MetaProfile.THREADS] = 98
	_start()
	_thread()


func _s_close_passes_run() -> void:
	_start()
	_close(24)


func _s_hairline() -> void:
	_start()
	_close(1, 0.6)
	_close(1, -1.0)   # no clearance measured


func _f_hairline() -> void:
	_close(1, 0.2)


func _s_multiplier_50() -> void:
	_start()
	Events.multiplier_changed.emit(49.9)


func _f_multiplier_50() -> void:
	Events.multiplier_changed.emit(50.0)


func _s_multiplier_100() -> void:
	_start()
	Events.scored.emit(Events.PASS, 10, 99.0, 2.0)


func _f_multiplier_100() -> void:
	Events.scored.emit(Events.PASS, 10, 100.5, 2.0)


func _s_top_speed() -> void:
	_start()
	_over(&"journey", {RunStats.TOP_SPEED_KMH: 299.4})


func _f_top_speed() -> void:
	_start()
	_over(&"journey", {RunStats.TOP_SPEED_KMH: 300.0})


func _s_halfway() -> void:
	_start()
	_cross(2)


func _s_coast() -> void:
	_start()
	_cross(7)


func _f_coast() -> void:
	Events.coast_reached.emit()


func _s_clean_legs() -> void:
	_start()
	_cross(2, true)
	_cross(1, false)


func _f_clean_leg() -> void:
	_cross(1, true)


func _s_heat() -> void:
	_start()
	_cross(2, true, false)


func _f_heat() -> void:
	_cross(1, false, true)


func _s_night() -> void:
	_start()
	Events.dawn_started.emit(6.0)   # a dawn without a night first is no night survived
	Events.night_started.emit()


func _f_dawn() -> void:
	Events.dawn_started.emit(6.0)


func _s_night_thread() -> void:
	_start()
	_thread()
	Events.night_started.emit()
	Events.dawn_started.emit(6.0)
	_thread()
	Events.night_started.emit()


func _s_hazards() -> void:
	_start()
	for i in 9:
		_piece()
	_piece(true)


func _s_big_bank() -> void:
	_start()
	Events.chain_banked.emit(49_999, Events.REASON_CASH_OUT, 49_999)


func _f_big_bank() -> void:
	Events.chain_banked.emit(50_000, Events.REASON_CHECKPOINT, 99_999)


func _s_half_million() -> void:
	_start()
	Events.bonus_awarded.emit(&"clean", 1000, 499_999)


func _f_half_million() -> void:
	Events.chain_banked.emit(1, Events.REASON_CASH_OUT, 500_000)


func _s_objectives() -> void:
	_start()
	for i in 9:
		Events.objective_completed.emit(&"close_passes", 5000)


func _f_objective() -> void:
	Events.objective_completed.emit(&"threads", 5000)


func _s_level() -> void:
	_stats()[MetaProfile.XP] = Progression.xp_to_reach(10, _prog()) - 1
	_start()


func _f_level() -> void:
	_stats()[MetaProfile.XP] = Progression.xp_to_reach(10, _prog())   # as Garage.award_run, before run_over
	_over()


func _s_new_wheels() -> void:
	Save.section(Garage.SECTION_UNLOCKS)["car/slot_5"] = 1   # a placeholder slot: not a car yet
	_start()
	_over()


func _f_new_wheels() -> void:
	_start()
	Save.section(Garage.SECTION_UNLOCKS)["car/night_viper"] = 3
	_over()


func _s_daily_streak() -> void:
	_stats()[MetaProfile.DAILY_BEST_STREAK] = 6
	_start(&"daily")


func _f_daily_streak() -> void:
	_stats()[MetaProfile.DAILY_BEST_STREAK] = 7
	_over(&"daily")


func test_every_achievement_has_a_row() -> void:
	var ids := {}
	for r in rows():
		ids[r.id] = true
	for a in cat.achievements:
		check(ids.has(a.id), "%s: a trigger row" % a.id)
	eq(ids.size(), cat.achievements.size(), "no row for an unknown id")


func test_every_trigger_unlocks_exactly_at_its_step() -> void:
	for r in rows():
		var id: StringName = r.id
		# A fresh profile and a fresh service for each row.
		svc.free()
		_fresh_save()
		_got.clear()
		svc = _service()
		(r.steps as Callable).call()
		check(not svc.is_unlocked(id), "%s: still locked one step before" % id)
		(r.final as Callable).call()
		check(svc.is_unlocked(id), "%s: unlocked by its trigger" % id)
		eq(_got.count(id), 1, "%s: announced once" % id)
		if svc.tracker.active:
			_over()


# ---------------------------------------------------------------- Rules

func test_a_hit_before_the_coast_is_not_a_clean_journey() -> void:
	_start()
	Events.hit.emit(Events.HIT_BARRIER, 1)
	Events.coast_reached.emit()
	check(svc.is_unlocked(&"coast"), "the coast counts")
	check(not svc.is_unlocked(&"clean_journey"), "not clean")


func test_loop_sectors_are_not_legs() -> void:
	_start(&"loop")
	_cross(5, true, true)
	Events.coast_reached.emit()
	_over(&"loop", {RunStats.LEGS_COMPLETED: 5, RunStats.COAST_REACHED: true})
	for id: StringName in [&"first_leg", &"halfway", &"coast", &"clean_journey", &"clean_legs", &"heat"]:
		check(not svc.is_unlocked(id), "%s: not from loop practice's sectors" % id)
	check(svc.is_unlocked(&"in_the_loop"), "the loop run counts as one")


func test_leg_milestone_from_the_results_too() -> void:
	_start()
	_over(&"journey", {RunStats.LEGS_COMPLETED: 3})
	check(svc.is_unlocked(&"halfway"), "legs_completed + 1 = leg 4 reached")


func test_nothing_counts_outside_a_run() -> void:
	_thread(20)
	Events.multiplier_changed.emit(500.0)
	Events.coast_reached.emit()
	eq(_got.size(), 0, "no run, no unlocks (the title's attract drive never scores anyway)")
	_start()
	_over()
	_thread(20)
	eq(_got.size(), 0, "after run_over either")


func test_a_quit_run_keeps_its_unlocks_but_not_its_counts() -> void:
	_start()
	_thread(3)
	check(svc.is_unlocked(&"first_thread"), "unlocked mid-run")
	Events.game_state_changed.emit(Game.PAUSED, Game.MENU)   # QUIT
	check(not svc.tracker.active, "the run was dropped")
	_start()
	_over()
	eq(int(svc.tracker.value(AchievementTracker.Metric.THREADS_RUN)), 0, "the quit run's threads are not a best")
	check(svc.is_unlocked(&"first_thread"), "still unlocked")


func test_hazards_count_only_without_a_hit() -> void:
	_start()
	_piece(true)
	_piece()
	Events.set_piece_started.emit(&"convoy")
	Events.set_piece_started.emit(&"slalom")   # overlapping pieces: one hit spoils both
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	Events.set_piece_ended.emit(&"slalom")
	Events.set_piece_ended.emit(&"convoy")
	Events.set_piece_ended.emit(&"stray")   # an end without a start counts nothing
	_over()
	eq(int(svc.tracker.value(AchievementTracker.Metric.SET_PIECES_TOTAL)), 1, "one clean hazard")


func test_totals_add_up_across_runs() -> void:
	for run in 3:
		_start()
		for i in 3:
			Events.objective_completed.emit(&"close_passes", 5000)
		_over()
	check(not svc.is_unlocked(&"objectives"), "9 of 10")
	_start()
	Events.objective_completed.emit(&"threads", 5000)
	check(svc.is_unlocked(&"objectives"), "the 10th, in the 4th run")


# ---------------------------------------------------------------- Once, and the save

func test_unlocks_exactly_once() -> void:
	for run in 3:
		_start()
		_thread(12)
		Events.multiplier_changed.emit(60.0)
		_over(&"journey", {RunStats.TOP_SPEED_KMH: 305.0})
	for id: StringName in [&"first_thread", &"threads_run", &"multiplier_50", &"top_speed_300"]:
		eq(_got.count(id), 1, "%s: announced once over three runs" % id)
		eq(svc.session_unlocks.count(id), 1, "%s: recorded once" % id)
	var day: Variant = (Save.section(SECTION)[AchievementTracker.KEY_UNLOCKED] as Dictionary)["first_thread"]
	_start()
	_thread()
	eq((Save.section(SECTION)[AchievementTracker.KEY_UNLOCKED] as Dictionary)["first_thread"], day, "the first unlock's day stays")


func test_persistence_round_trip() -> void:
	_start()
	_thread(4)
	_close(7)
	Events.multiplier_changed.emit(33.0)
	Events.objective_completed.emit(&"close_passes", 5000)
	_over(&"journey", {RunStats.TOP_SPEED_KMH: 250.0})
	var n := _got.size()
	gt(n, 0, "something unlocked")
	# Through JSON (numbers come back as floats) and the migration chain.
	var text := JSON.stringify(Save.data)
	var doc: Dictionary = JSON.parse_string(text)
	doc = SaveMigrations.migrate(doc)
	check(doc.has(SECTION), "the section survives the migration (additive: no new version)")
	Save.data = doc
	svc.free()
	_got.clear()
	svc = _service()
	eq(_got.size(), 0, "nothing unlocks again after a reload")
	eq(svc.unlocked_count(), n, "every unlock is back")
	var trk := svc.tracker
	eq(int(trk.value(AchievementTracker.Metric.THREADS_RUN)), 4, "best threads in a run")
	eq(int(trk.value(AchievementTracker.Metric.CLOSE_PASSES_RUN)), 7, "best close passes in a run")
	near(trk.value(AchievementTracker.Metric.MULTIPLIER_RUN), 33.0, 1e-9, "best multiplier")
	near(trk.value(AchievementTracker.Metric.TOP_SPEED_RUN), Units.kmh_to_mps(250.0), 1e-9, "best top speed (m/s)")
	eq(int(trk.value(AchievementTracker.Metric.OBJECTIVES_TOTAL)), 1, "objectives in total")
	check(not svc.is_unlocked(&"threads_run"), "4 in the best run: not yet")
	_start()
	_thread(10)
	check(svc.is_unlocked(&"threads_run"), "a later run still counts")


func test_a_damaged_section_loads_quietly() -> void:
	Save.data[SECTION] = {AchievementTracker.KEY_UNLOCKED: "nope", AchievementTracker.KEY_PROGRESS: {"threads_run": "x", "close_passes_run": INF}}
	svc.free()
	_got.clear()
	svc = _service()
	eq(svc.unlocked_count(), 0, "nothing unlocked")
	eq(svc.tracker.value(AchievementTracker.Metric.THREADS_RUN), 0.0, "bad numbers read as 0")
	_start()
	_thread()
	check(svc.is_unlocked(&"first_thread"), "and it still works")


func test_an_older_save_gets_what_it_earned_quietly() -> void:
	svc.free()
	_got.clear()
	_stats()[MetaProfile.THREADS] = 150
	_stats()[MetaProfile.XP] = Progression.xp_to_reach(11, _prog())
	var s := AchievementService.new()
	s.run_under_tools = true
	s.haptic_tick = false
	s.platform = PlatformLeaderboards.recorder()
	tree.root.add_child(s)
	svc = s
	for id: StringName in [&"first_thread", &"threads_total", &"level_10"]:
		check(svc.is_unlocked(id), "%s: earned before achievements existed" % id)
	check(svc.toast != null and not svc.toast.showing(), "quietly: no toast at start")
	check(not svc.is_unlocked(&"threads_run"), "run records are not guessed")


func test_listener_only() -> void:
	# The service never emits gameplay signals: a run's worth of events in, nothing out
	# but its own `unlocked`.
	var emitted := [0]
	var count := func(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void: emitted[0] += 1
	for sig: Signal in [Events.chain_banked, Events.bonus_awarded, Events.hit, Events.slowmo_requested,
			Events.camera_shake_requested]:
		sig.connect(count)
	_start()
	_thread(12)
	_close(30, 0.1)
	for sig: Signal in [Events.chain_banked, Events.bonus_awarded, Events.hit, Events.slowmo_requested,
			Events.camera_shake_requested]:
		sig.disconnect(count)
	eq(emitted[0], 0, "no gameplay signal from the service")
	gt(_got.size(), 0, "while it unlocked things")
