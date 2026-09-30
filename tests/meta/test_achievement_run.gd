extends "res://tests/integration/run_harness.gd"
## WP8.3 through the real run (src/run/run.tscn): the run's title attaches one achievement
## service (until the `Achievements` autoload exists) and only when asked under the test
## runner; a thread published by the run's drain unlocks NEEDLE and shows its toast in
## that same frame, placed clear of the live HUD's readouts and thumb areas; a real run
## end (two hits, the crash, the results) records the run's progress; QUIT to the title
## drops the run's counts; the title's ACHIEVEMENTS opens the screen over the attract
## drive. Spec: Garage and progression (Achievements); Architecture rule 8 (listeners
## only). docs/ACHIEVEMENTS.md.

var _saved: Dictionary


func before_each() -> void:
	super.before_each()
	_saved = Save.data.duplicate(true)
	for k: String in [AchievementService.SECTION, Garage.SECTION_STATS, Garage.SECTION_UNLOCKS]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true
	AchievementService.attach_under_tools = true


func after_each() -> void:
	AchievementService.attach_under_tools = false
	await super.after_each()
	Save.data = _saved
	Save.dirty = false


func _service(r: Run) -> AchievementService:
	var s := AchievementService.current
	check(s != null and is_instance_valid(s), "the run's title attached a service")
	if s != null:
		check(r.is_ancestor_of(s), "under the run (its TitleScreens)")
		s.haptic_tick = false
	return s


func test_one_service_and_none_unless_asked() -> void:
	AchievementService.attach_under_tools = false
	var quiet := _make()
	check(AchievementService.current == null, "the test runner gets none by default (like the first run)")
	_runs.erase(quiet)
	quiet.free()
	AchievementService.attach_under_tools = true
	var r := _make()
	var s := _service(r)
	check(AchievementService.ensure(r) == s, "ensure() hands back the one service")


func test_a_thread_in_the_drain_unlocks_and_toasts_in_that_frame() -> void:
	var r := _make()
	var s := _service(r)
	if s == null:
		return
	r.go()
	_run_ticks(r, TICKS_PER_FRAME * 4)
	check(s.tracker.active, "tracking the run (run_started)")
	check(not s.is_unlocked(&"first_thread"), "not yet")
	r.events.push(ScoreEvents.THREAD, 500, 5.0, 1.0)
	r.frame(FRAME_S)
	check(s.is_unlocked(&"first_thread"), "unlocked in the drain")
	check(s.toast.showing(), "the toast shows in the same frame")
	eq(s.toast.widget.title_text(), "NEEDLE")
	var hud := r.hud as Hud
	var toast_r := s.toast.toast_rect
	for rect in hud.layout.rects():
		check(not toast_r.intersects(rect), "clear of the live HUD's readouts %s" % rect)
	check(HudAchievementLayer.clear_of_thumbs(hud.layout, toast_r, t.hud), "clear of the live thumb areas")


func test_a_real_run_end_records_the_runs_progress() -> void:
	var r := _make()
	var s := _service(r)
	if s == null:
		return
	r.go()
	_run_ticks(r, TICKS_PER_FRAME * 4)
	for i in 3:
		r.events.push(ScoreEvents.CLOSE_PASS, 300, 4.0, 0.7)
	r.frame(FRAME_S)
	for i in 2:
		r.force_hit()
		_run_until(r, func() -> bool: return r.state == Game.CRASH or _count("hit") > i, 2.0)
		_run_ticks(r, _ticks_for(t.lives.ghost_period_s + 0.1))
	_run_until(r, func() -> bool: return r.state == Game.CRASH, 2.0)
	r.skip()
	r.frame(FRAME_S)
	eq(r.state, Game.RESULTS, "the results")
	check(not s.tracker.active, "the run is over for the tracker")
	var progress: Dictionary = Save.section(AchievementService.SECTION).get(AchievementTracker.KEY_PROGRESS, {})
	eq(int(progress.get("close_passes_run", 0.0)), 3, "the run's close passes saved as its best")
	gt(float(progress.get("top_speed_run", 0.0)), 0.0, "its top speed from the results")


func test_quit_to_the_title_drops_the_run() -> void:
	var r := _make()
	var s := _service(r)
	if s == null:
		return
	r.go()
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.events.push(ScoreEvents.CLOSE_PASS, 300, 4.0, 0.7)
	r.frame(FRAME_S)
	r.enter_menu()
	check(not s.tracker.active, "QUIT: no run to track")
	var progress: Dictionary = Save.section(AchievementService.SECTION).get(AchievementTracker.KEY_PROGRESS, {})
	eq(int(progress.get("close_passes_run", 0.0)), 0, "its counts are not a best")
	r.title.open_achievements()
	r.title.finish_animations()
	check(r.title.achievements != null and r.title.achievements.visible, "ACHIEVEMENTS over the attract drive")
	check(r.title.achievements.tracker == s.tracker, "the screen reads the service's progress")
