extends WBTest
## The governor inside Quality (src/platform/quality.gd): forced thermal steps down and
## back up, the rungs never go above the user's tier and never touch the setting, the
## view-distance rung waits for the run to end, useless rungs are skipped, and the dev HUD
## shows the governor. Spec: Performance budget → Adaptive governor; M9 gate. WP9.1,
## docs/QUALITY.md.

const QualityScript := preload("res://src/platform/quality.gd")
const FRAME := 1.0 / 60.0

var _tuning: QualityTuning
var _node: QualityScript
var _saved_max_fps: int
var _saved_scale: float
var _saved_msaa: Viewport.MSAA
var _rungs: Array[int] = []
var _thermal: Array[StringName] = []
var _hud: CanvasLayer


## The live `Quality` autoload listens to Settings/Game events too; detach it so only
## the node under test applies to the viewport.
func before_all() -> void:
	var autoload := tree.root.get_node_or_null("Quality")
	if autoload != null:
		Events.settings_changed.disconnect(autoload._on_settings_changed)
		Events.game_state_changed.disconnect(autoload._on_game_state_changed)


func after_all() -> void:
	var autoload := tree.root.get_node_or_null("Quality")
	if autoload != null:
		Events.settings_changed.connect(autoload._on_settings_changed)
		Events.game_state_changed.connect(autoload._on_game_state_changed)
		autoload.apply()


func before_each() -> void:
	_tuning = Tuning.load_default().quality.duplicate() as QualityTuning
	_saved_max_fps = Engine.max_fps
	_saved_scale = tree.root.scaling_3d_scale
	_saved_msaa = tree.root.msaa_3d
	_rungs.clear()
	_thermal.clear()
	Settings.reset_to_defaults()
	DevStats.reset()
	Events.governor_changed.connect(_on_governor_changed)
	Events.thermal_state_changed.connect(_on_thermal_changed)


func after_each() -> void:
	Events.governor_changed.disconnect(_on_governor_changed)
	Events.thermal_state_changed.disconnect(_on_thermal_changed)
	if _node != null:
		_node.free()
		_node = null
	if _hud != null:
		_hud.free()
		_hud = null
	Engine.max_fps = _saved_max_fps
	tree.root.scaling_3d_scale = _saved_scale
	tree.root.msaa_3d = _saved_msaa
	Settings.reset_to_defaults()
	DevStats.reset()


func _on_governor_changed(rung: int) -> void:
	_rungs.append(rung)


func _on_thermal_changed(state: StringName) -> void:
	_thermal.append(state)


func _make() -> QualityScript:
	_node = QualityScript.new()
	_node.tuning = _tuning
	_node.is_web = false
	_node.pace_frames = true
	_node.governor_enabled = false   # the test steps it
	tree.root.add_child(_node)
	return _node


func _frames(q: QualityScript, seconds: float) -> void:
	for i in roundi(seconds / FRAME):
		q.step_governor(FRAME)


## [tier, battery saver] cases.
static func _cases() -> Array:
	return [[&"low", false], [&"medium", false], [&"high", false], [&"medium", true], [&"high", true]]


func test_forced_thermal_steps_down_and_back_up() -> void:
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	check(q.thermal.apply_override("serious:35,nominal"))
	eq(_thermal, [Thermal.SERIOUS] as Array[StringName], "forwarded to Events.thermal_state_changed")
	_frames(q, 1.0)
	eq(q.governor_rung, 1, "serious: a rung down at once")
	check(q.is_cooling(), "the cooling icon")
	eq(DevStats.get_value(QualityScript.DEV_COOLING), true)
	_frames(q, 34.0)
	eq(q.governor_rung, 4, "a rung every 10 s")
	eq(Engine.max_fps, 30, "the last rung: 30 fps")
	_frames(q, 4.0 * 60.0 + 12.0)
	eq(q.governor_rung, 0, "and back up, a rung a minute")
	eq(_rungs, [1, 2, 3, 4, 3, 2, 1, 0] as Array[int])
	check(not q.is_cooling())
	eq(Engine.max_fps, 60)
	eq(Settings.get_value(&"quality_tier"), &"medium", "the user's tier is never written")
	eq(_thermal, [Thermal.SERIOUS, Thermal.NOMINAL] as Array[StringName])


func test_frame_time_alone_steps_down_without_the_cooling_icon() -> void:
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	for i in roundi(12.0 / FRAME):
		q.step_governor(FRAME * 3.0 if i % 5 == 0 else FRAME)
	eq(q.governor_rung, 1)
	check(not q.is_cooling(), "frame time: no cooling icon (QualityTuning.cooling_icon_any_reason)")
	_tuning.cooling_icon_any_reason = true
	check(q.is_cooling(), "the spec's literal rule behind the switch")


func test_never_above_the_user_tier() -> void:
	# Short timings: the bound does not depend on them.
	_tuning.governor_window_s = 1.0
	_tuning.governor_step_down_interval_s = 2.0
	_tuning.governor_step_up_after_s = 5.0
	for c: Array in _cases():
		Settings.reset_to_defaults()
		Settings.set_value(&"quality_tier", c[0])
		Settings.set_value(&"battery_saver", c[1])
		var q := _make()
		Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
		var base := QualityScript.compute(_tuning, c[0], 0, false, c[1], true)
		q.thermal.apply_override("critical:10,nominal")
		for i in roundi(40.0 / FRAME):
			q.step_governor(FRAME)
			if i % 30 != 0:
				continue
			var e := q.effective
			var what := "%s saver %s at %.0f s" % [c[0], c[1], float(i) * FRAME]
			le(e.render_scale, base.render_scale, what)
			le(e.particle_scale, base.particle_scale, what)
			le(e.view_distance_m, base.view_distance_m, what)
			le(e.max_fps, base.max_fps, what)
			ge(q.governor_rung, 0, what)
		eq(q.governor_rung, 0, "%s: back at the tier" % c[0])
		eq(Settings.get_value(&"quality_tier"), c[0], "setting untouched")
		_node.free()
		_node = null


func test_battery_saver_skips_the_fps_rung() -> void:
	Settings.set_value(&"battery_saver", true)
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	check(not q.governor.is_useful(QualityScript.RUNG_FPS), "already at 30 fps")
	q.thermal.force(Thermal.SERIOUS)
	_frames(q, 60.0)
	eq(q.governor_rung, QualityScript.RUNG_VIEW_DISTANCE, "stops at the last rung that helps")
	eq(_rungs, [1, 2, 3] as Array[int])


## The switch (off by default since N8.2, when the simulation stopped reading the view
## distance) still holds the view-distance rung through a run when turned on.
func test_view_distance_rung_waits_for_the_run_to_end() -> void:
	_tuning.governor_view_distance_between_runs = true
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.COUNTDOWN)
	Events.game_state_changed.emit(Game.COUNTDOWN, Game.RUNNING)
	var view := q.view_distance_m
	var far := q.far_plane_m
	near(view, 700.0, 1e-9)
	q.thermal.force(Thermal.SERIOUS)
	_frames(q, 25.0)
	eq(q.governor_rung, 3)
	near(q.view_distance_m, view, 1e-9, "held for the rest of the run")
	near(q.far_plane_m, far, 1e-9, "far plane too (it matches the fog)")
	check(q.effective.view_pending, "waiting")
	lt(q.particle_scale, 1.0, "rendering rungs apply at once")
	lt(q.render_scale, 0.75)
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	near(q.view_distance_m, view, 1e-9, "a pause is still the run")
	Events.game_state_changed.emit(Game.PAUSED, Game.RUNNING)
	Events.game_state_changed.emit(Game.RUNNING, Game.CRASH)
	near(q.view_distance_m, view, 1e-9, "the crash too")
	_rungs.clear()
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	near(q.view_distance_m, view - _tuning.governor_view_distance_step_m, 1e-9, "applied between runs")
	check(not q.effective.view_pending)
	eq(_rungs, [3] as Array[int], "view readers are told to re-read")
	near(q.run_view_distance_m, 700.0, 1e-9, "the tier's view distance, for the simulation")
	_frames(q, 5.0)
	Events.game_state_changed.emit(Game.RESULTS, Game.COUNTDOWN)
	near(q.view_distance_m, view - _tuning.governor_view_distance_step_m, 1e-9,
		"the next run starts with it (docs/QUALITY.md: N8.2)")


func test_view_distance_live_by_default() -> void:
	check(not Tuning.load_default().quality.governor_view_distance_between_runs,
		"N8.2: the simulation reads RoadTuning.sim_horizon_m, so the rung applies live")
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	q.set_governor_rung(3)
	near(q.view_distance_m, 550.0, 1e-9, "the rung applies mid-run")


func test_outside_gameplay_frames_do_not_count() -> void:
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	for i in roundi(30.0 / FRAME):
		q.step_governor(FRAME * 4.0)
	eq(q.governor_rung, 0, "a paused game's frames are not judged")


func test_dev_stats_and_dev_hud_rows() -> void:
	var q := _make()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	q.thermal.force(Thermal.SERIOUS)
	_frames(q, 12.0)
	q.report_governor()
	eq(DevStats.get_value(QualityScript.DEV_GOVERNOR_PRESSURE), "thermal")
	eq(DevStats.get_value(QualityScript.DEV_GOVERNOR_REASON), "thermal")
	eq(DevStats.get_value(QualityScript.DEV_THERMAL_SOURCE), Thermal.SOURCE_FORCED)
	near(float(DevStats.get_value(QualityScript.DEV_GOVERNOR_P95_MS)), FRAME * 1000.0,
		_tuning.governor_hist_bin_ms + 1e-6, "p95 of 60 fps frames")
	_hud = (load("res://src/ui/dev_hud.tscn") as PackedScene).instantiate()
	tree.root.add_child(_hud)
	_hud.set_hud_visible(true)
	_hud.refresh()
	eq(_hud.get_row_text(_hud.Row.THERMAL), "serious  forced")
	var row: String = _hud.get_row_text(_hud.Row.GOVERNOR)
	check(row.begins_with("r2 particles  thermal  last thermal  p95 "), row)
	check(row.ends_with("cooling"), row)
	eq(_hud.thermal_button_text(), "THERMAL serious")


func test_rung_names_cover_the_rungs() -> void:
	eq(QualityScript.RUNG_NAMES.size(), QualityScript.RUNG_MAX + 1)
