extends WBTest
## WP8.3: the pure AchievementTracker. Metric scopes (the best run, totals across runs,
## the garage's profile numbers), unlock-once through `pending`, the save's progress
## round trip, and no allocations in the event handlers (they run in the run's drain,
## every frame). Spec: Garage and progression (Achievements); CLAUDE.md rule 6.
## docs/ACHIEVEMENTS.md.

const M := AchievementTracker.Metric

var cat: AchievementCatalog


func before_all() -> void:
	cat = AchievementCatalog.load_path(AchievementTuning.load_default().catalog_path)


func _tracker() -> AchievementTracker:
	var t := AchievementTracker.new(cat)
	t.bind({})
	return t


func _pending_ids(t: AchievementTracker) -> Array[StringName]:
	var out: Array[StringName] = []
	for k in t.pending_count:
		out.append(cat.achievements[t.pending[k]].id)
	return out


func test_metric_tables_line_up() -> void:
	eq(AchievementTracker.METRIC_IDS.size(), M.size(), "an id per metric")
	eq(AchievementTracker.METRIC_SCOPES.size(), M.size(), "a scope per metric")
	eq(AchievementTracker.metric_index(&"threads_run"), M.THREADS_RUN)
	eq(AchievementTracker.metric_index(&"nope"), -1)


func test_run_metrics_keep_the_best_run() -> void:
	var t := _tracker()
	t.begin_run(&"journey", true, true)
	for i in 4:
		t.on_scored(Events.THREAD, 50, 3.0, 1.0)
	eq(t.run_value(M.THREADS_RUN), 4.0, "this run")
	t.end_run({})
	eq(t.value(M.THREADS_RUN), 4.0, "the best run")
	t.begin_run(&"journey", true, true)
	t.on_scored(Events.THREAD, 50, 3.0, 1.0)
	eq(t.value(M.THREADS_RUN), 4.0, "a weaker run leaves the best")
	t.end_run({})
	eq(t.value(M.THREADS_RUN), 4.0)
	eq(t.value(M.THREADS_TOTAL), 5.0, "totals add up")


func test_totals_only_in_the_garages_modes() -> void:
	var t := _tracker()
	t.begin_run(&"other", false, false)
	t.on_scored(Events.THREAD, 50, 3.0, 1.0)
	t.end_run({})
	eq(t.value(M.THREADS_TOTAL), 0.0, "a mode without XP adds no lifetime threads (as the garage)")
	eq(t.value(M.THREADS_RUN), 1.0, "the run record still counts")


func test_leg_one_is_reached_at_the_start() -> void:
	var t := _tracker()
	t.begin_run(&"journey", true, true)
	eq(t.run_value(M.LEG_RUN), 1.0)
	t.on_checkpoint_crossed({})
	eq(t.run_value(M.LEG_RUN), 2.0)
	t.begin_run(&"loop", false, true)
	eq(t.run_value(M.LEG_RUN), 0.0, "no legs in loop practice")


func test_profile_numbers() -> void:
	var t := _tracker()
	t.set_profile(10, 2, 7, 150)
	var ids := _pending_ids(t)
	for id: StringName in [&"level_10", &"new_wheels", &"daily_streak", &"first_thread", &"threads_total"]:
		check(ids.has(id), "%s from the profile" % id)
	t.clear_pending()
	t.set_profile(10, 2, 7, 150)
	eq(t.pending_count, 0, "never queued twice")


func test_each_unlocks_once_and_progress_reads() -> void:
	var t := _tracker()
	t.begin_run(&"journey", true, true)
	var i := cat.index_of(&"close_passes_run")
	for k in 10:
		t.on_scored(Events.CLOSE_PASS, 30, 3.0, 0.8)
	near(t.progress_of(i), 10.0 / 25.0, 1e-9, "10 of 25")
	for k in 40:
		t.on_scored(Events.CLOSE_PASS, 30, 3.0, 0.8)
	eq(_pending_ids(t).count(&"close_passes_run"), 1, "queued once")
	check(t.is_unlocked(i), "marked at once")
	eq(t.progress_of(i), 1.0)


func test_bind_and_write_progress() -> void:
	var t := _tracker()
	t.begin_run(&"journey", true, true)
	t.on_multiplier_changed(42.5)
	for k in 3:
		t.on_objective_completed()
	t.end_run({RunStats.TOP_SPEED_KMH: 280.0, RunStats.SCORE: 123456})
	var section := {AchievementTracker.KEY_UNLOCKED: {"first_leg": 20000}}
	t.write_progress(section)
	var back: Dictionary = JSON.parse_string(JSON.stringify(section))
	var u := AchievementTracker.new(cat)
	u.bind(back)
	for m in M.size():
		near(u.value(m), t.value(m), 1e-9, "%s round trip" % AchievementTracker.METRIC_IDS[m])
	check(u.is_unlocked(cat.index_of(&"first_leg")), "unlocked ids read back")
	check(not u.is_unlocked(cat.index_of(&"coast")), "and only those")


func test_no_allocations_in_the_handlers() -> void:
	var t := _tracker()
	var summary := {RunEvents.SUMMARY_CLEAN: true, RunEvents.SUMMARY_HEAT: true}
	t.begin_run(&"journey", true, true)
	_burst(t, summary, 1)   # warm every path (and unlock what it unlocks)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC)
	_burst(t, summary, 2000)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects per event")
	eq(Performance.get_monitor(Performance.MEMORY_STATIC), mem, "no memory kept per event")
	gt(t.pending_count, 0, "unlocks were queued along the way (into the pre-sized buffer)")


func _burst(t: AchievementTracker, summary: Dictionary, n: int) -> void:
	for k in n:
		t.on_scored(Events.PASS, 10, 2.0, 3.0)
		t.on_scored(Events.CLOSE_PASS, 30, 3.0, 0.2)
		t.on_scored(Events.THREAD, 50, 5.0, 1.0)
		t.on_multiplier_changed(float(k % 200))
		t.on_chain_banked(k, k * 2)
		t.on_bonus_awarded(k * 3)
		t.on_hit()
		t.on_set_piece_started()
		t.on_set_piece_ended()
		t.on_objective_completed()
		t.on_night_started()
		t.on_dawn_started()
		t.on_morning_reached()
		t.on_checkpoint_crossed(summary)
		t.on_coast_reached()
