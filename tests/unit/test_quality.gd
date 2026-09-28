extends WBTest
## Quality tiers, frame pacing and governor rungs (src/platform/quality.gd).
## Spec: Performance budget (frame rate, quality tiers, adaptive governor).

const QualityScript := preload("res://src/platform/quality.gd")
const TuningFixture := preload("res://tests/fixtures/quality/quality_tuning_fixture.gd")

var _tuning: Resource
var _node: Node
var _saved_max_fps: int
var _saved_scale: float
var _saved_msaa: Viewport.MSAA
var _quality_events: Array[StringName] = []
var _governor_events: Array[int] = []


func before_each() -> void:
	_tuning = TuningFixture.new()
	_saved_max_fps = Engine.max_fps
	_saved_scale = tree.root.scaling_3d_scale
	_saved_msaa = tree.root.msaa_3d
	_quality_events.clear()
	_governor_events.clear()
	Settings.reset_to_defaults()
	DevStats.reset()


func after_each() -> void:
	if _node != null:
		_node.free()
		_node = null
	Engine.max_fps = _saved_max_fps
	tree.root.scaling_3d_scale = _saved_scale
	tree.root.msaa_3d = _saved_msaa
	Settings.reset_to_defaults()
	DevStats.reset()


func _eff(tier: StringName, rung: int = 0, web: bool = false, saver: bool = false,
		gameplay: bool = true) -> QualityScript.Effective:
	return QualityScript.compute(_tuning, tier, rung, web, saver, gameplay)


# ---------------------------------------------------------------- Pure computation

func test_tier_table_matches_spec() -> void:
	# Spec table: Low 0.6 / off / 500 m / 50%, Medium 0.75 / off / 700 m / 100%,
	# High 0.9 / 2x / 800 m / 100%.
	var rows := [
		[&"low", 0.6, 0, 500.0, 0.5],
		[&"medium", 0.75, 0, 700.0, 1.0],
		[&"high", 0.9, 2, 800.0, 1.0],
	]
	for row: Array in rows:
		var e := _eff(row[0])
		var what := String(row[0])
		eq(e.tier, row[0], what)
		near(e.render_scale, row[1], 1e-9, what + " render scale")
		eq(e.msaa_samples, row[2], what + " msaa")
		near(e.view_distance_m, row[3], 1e-9, what + " view distance")
		near(e.particle_scale, row[4], 1e-9, what + " particles")
		eq(e.governor_rung, 0, what)
		eq(e.max_fps, 60, what + " gameplay fps")


func test_msaa_modes() -> void:
	eq(QualityScript.msaa_mode(0), Viewport.MSAA_DISABLED)
	eq(QualityScript.msaa_mode(2), Viewport.MSAA_2X)
	eq(QualityScript.msaa_mode(4), Viewport.MSAA_4X)
	eq(QualityScript.msaa_mode(8), Viewport.MSAA_8X)


func test_web_forces_msaa_off() -> void:
	for tier: StringName in [&"low", &"medium", &"high"]:
		eq(_eff(tier, 0, true).msaa_samples, 0, String(tier))
	# Even if the web tuning asked for more than the tier, it never exceeds it.
	_tuning.web_msaa_samples = 4
	eq(_eff(&"medium", 0, true).msaa_samples, 0)
	# Web leaves the other tier values alone.
	near(_eff(&"high", 0, true).render_scale, 0.9, 1e-9)


func test_unknown_tier_falls_back_to_default() -> void:
	var e := _eff(&"ultra")
	eq(e.tier, &"medium")
	near(e.render_scale, 0.75, 1e-9)


func test_frame_caps() -> void:
	eq(_eff(&"medium", 0, false, false, true).max_fps, 60, "gameplay")
	eq(_eff(&"medium", 0, false, false, false).max_fps, 30, "menu")
	eq(_eff(&"medium", 0, false, true, true).max_fps, 30, "battery saver in gameplay")
	eq(_eff(&"medium", 0, false, true, false).max_fps, 30, "battery saver in menu")
	eq(_eff(&"high", 0, false, false, true).max_fps, 60, "high tier is still 60")


func test_never_above_60_fps() -> void:
	# Even if a menu or battery-saver cap were tuned higher, the gameplay cap
	# (60) is the ceiling, so 120 Hz screens never render at 120.
	_tuning.menu_fps = 120
	_tuning.battery_saver_fps = 90
	eq(_eff(&"high", 0, false, false, false).max_fps, 60)
	eq(_eff(&"high", 0, false, true, true).max_fps, 60)


func test_gameplay_states() -> void:
	check(QualityScript.is_gameplay_state(Game.RUNNING), "running")
	check(QualityScript.is_gameplay_state(Game.COUNTDOWN), "countdown")
	check(QualityScript.is_gameplay_state(Game.CRASH), "crash")
	for s: StringName in [Game.BOOT, Game.MENU, Game.PAUSED, Game.RESULTS]:
		check(not QualityScript.is_gameplay_state(s), String(s))


func test_governor_rungs_are_cumulative() -> void:
	var r0 := _eff(&"high", 0)
	var r1 := _eff(&"high", 1)
	var r2 := _eff(&"high", 2)
	var r3 := _eff(&"high", 3)
	var r4 := _eff(&"high", 4)
	# Rung 1: render scale -0.1.
	near(r1.render_scale, 0.8, 1e-9)
	near(r1.particle_scale, 1.0, 1e-9)
	near(r1.view_distance_m, 800.0, 1e-9)
	eq(r1.max_fps, 60)
	# Rung 2: + particles -50%.
	near(r2.render_scale, 0.8, 1e-9)
	near(r2.particle_scale, 0.5, 1e-9)
	near(r2.view_distance_m, 800.0, 1e-9)
	eq(r2.max_fps, 60)
	# Rung 3: + view distance -150 m.
	near(r3.render_scale, 0.8, 1e-9)
	near(r3.particle_scale, 0.5, 1e-9)
	near(r3.view_distance_m, 650.0, 1e-9)
	eq(r3.max_fps, 60)
	# Rung 4: + 30 fps.
	near(r4.render_scale, 0.8, 1e-9)
	near(r4.particle_scale, 0.5, 1e-9)
	near(r4.view_distance_m, 650.0, 1e-9)
	eq(r4.max_fps, 30)
	# The governor never changes MSAA or the tier.
	for e: QualityScript.Effective in [r0, r1, r2, r3, r4]:
		eq(e.msaa_samples, 2)
		eq(e.tier, &"high")
	eq(r4.governor_rung, 4)


func test_governor_rungs_clamp() -> void:
	var over := _eff(&"medium", 9)
	var top := _eff(&"medium", 4)
	eq(over.governor_rung, 4)
	near(over.render_scale, top.render_scale, 1e-9)
	eq(over.max_fps, top.max_fps)
	var under := _eff(&"medium", -3)
	eq(under.governor_rung, 0)
	near(under.render_scale, 0.75, 1e-9)


func test_governor_render_scale_floor() -> void:
	# Low: 0.6 - 0.1 = 0.5, exactly the floor.
	near(_eff(&"low", 1).render_scale, 0.5, 1e-9)
	# A bigger step still stops at the floor.
	_tuning.governor_render_scale_step = 0.3
	near(_eff(&"low", 1).render_scale, 0.5, 1e-9)
	near(_eff(&"medium", 4).render_scale, 0.5, 1e-9)
	# A tier already below the floor is never raised to it.
	_tuning.render_scale = PackedFloat64Array([0.4, 0.75, 0.9])
	near(_eff(&"low", 1).render_scale, 0.4, 1e-9)


func test_governor_fps_rung_in_menu_and_battery_saver() -> void:
	eq(_eff(&"medium", 4, false, false, false).max_fps, 30, "menu stays 30")
	eq(_eff(&"medium", 4, false, true, true).max_fps, 30, "battery saver stays 30")
	_tuning.menu_fps = 24
	eq(_eff(&"medium", 4, false, false, false).max_fps, 24, "never raises a lower cap")


func test_governor_never_exceeds_user_tier() -> void:
	for tier: StringName in [&"low", &"medium", &"high"]:
		var base := _eff(tier, 0)
		for rung in range(0, 5):
			for gameplay: bool in [true, false]:
				var e := _eff(tier, rung, false, false, gameplay)
				var b := _eff(tier, 0, false, false, gameplay)
				var what := "%s rung %d gameplay %s" % [tier, rung, gameplay]
				le(e.render_scale, base.render_scale, what)
				le(e.particle_scale, base.particle_scale, what)
				le(e.view_distance_m, base.view_distance_m, what)
				le(e.far_plane_m, base.far_plane_m, what)
				le(e.max_fps, b.max_fps, what)
				le(e.msaa_samples, base.msaa_samples, what)
				ge(e.render_scale, minf(base.render_scale, 0.5), what)


func test_far_plane_is_view_distance_plus_margin() -> void:
	near(_eff(&"low").far_plane_m, 520.0, 1e-9)
	near(_eff(&"medium").far_plane_m, 720.0, 1e-9)
	near(_eff(&"high").far_plane_m, 820.0, 1e-9)
	near(_eff(&"high", 3).far_plane_m, 670.0, 1e-9)
	_tuning.far_plane_margin_m = 5.0
	near(_eff(&"medium").far_plane_m, 705.0, 1e-9)


func test_thermal_stub_is_nominal() -> void:
	eq(Thermal.new().get_state(), Thermal.NOMINAL)


# ---------------------------------------------------------------- Applier node

func _on_quality_changed(tier: StringName) -> void:
	_quality_events.append(tier)


func _on_governor_changed(rung: int) -> void:
	_governor_events.append(rung)


func _make_applier() -> Node:
	_node = QualityScript.new()
	_node.tuning = _tuning
	_node.is_web = false
	_node.pace_frames = true
	tree.root.add_child(_node)
	return _node


func test_applier_sets_viewport_and_fps() -> void:
	var q := _make_applier()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	# Default tier (medium) in gameplay.
	near(tree.root.scaling_3d_scale, 0.75, 1e-6)
	eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	eq(Engine.max_fps, 60)
	Settings.set_value(&"quality_tier", &"high")
	near(tree.root.scaling_3d_scale, 0.9, 1e-6)
	eq(tree.root.msaa_3d, Viewport.MSAA_2X)
	near(q.view_distance_m, 800.0, 1e-9)
	near(q.far_plane_m, 820.0, 1e-9)
	near(q.particle_scale, 1.0, 1e-9)
	eq(q.tier, &"high")
	Settings.set_value(&"quality_tier", &"low")
	near(tree.root.scaling_3d_scale, 0.6, 1e-6)
	eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	near(q.particle_scale, 0.5, 1e-9)
	# Menus and pause run at 30; countdown and crash are gameplay.
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	eq(Engine.max_fps, 30, "paused")
	Events.game_state_changed.emit(Game.PAUSED, Game.COUNTDOWN)
	eq(Engine.max_fps, 60, "countdown")
	Events.game_state_changed.emit(Game.RUNNING, Game.CRASH)
	eq(Engine.max_fps, 60, "crash")
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	eq(Engine.max_fps, 30, "results")
	Events.game_state_changed.emit(Game.RESULTS, Game.RUNNING)
	Settings.set_value(&"battery_saver", true)
	eq(Engine.max_fps, 30, "battery saver")
	Settings.set_value(&"battery_saver", false)
	eq(Engine.max_fps, 60)


func test_applier_web_msaa_off() -> void:
	_node = QualityScript.new()
	_node.tuning = _tuning
	_node.is_web = true
	_node.pace_frames = true
	Settings.set_value(&"quality_tier", &"high")
	tree.root.add_child(_node)
	eq(tree.root.msaa_3d, Viewport.MSAA_DISABLED)
	near(tree.root.scaling_3d_scale, 0.9, 1e-6)


func test_applier_emits_quality_changed_on_tier_change() -> void:
	Events.quality_changed.connect(_on_quality_changed)
	_make_applier()
	_quality_events.clear()
	Settings.set_value(&"battery_saver", true)
	eq(_quality_events.size(), 0, "battery saver is not a tier change")
	Settings.set_value(&"quality_tier", &"high")
	Settings.set_value(&"quality_tier", &"high")
	Settings.set_value(&"quality_tier", &"low")
	Events.quality_changed.disconnect(_on_quality_changed)
	eq(_quality_events, [&"high", &"low"] as Array[StringName])


func test_governor_rung_is_an_offset_not_a_setting() -> void:
	Events.governor_changed.connect(_on_governor_changed)
	var q := _make_applier()
	Events.game_state_changed.emit(Game.MENU, Game.RUNNING)
	Settings.set_value(&"quality_tier", &"high")
	q.set_governor_rung(4)
	q.set_governor_rung(4)
	Events.governor_changed.disconnect(_on_governor_changed)
	eq(_governor_events, [4] as Array[int], "emits once per change")
	eq(q.governor_rung, 4)
	eq(Settings.get_value(&"quality_tier"), &"high", "user tier untouched")
	eq(q.tier, &"high")
	near(tree.root.scaling_3d_scale, 0.8, 1e-6)
	eq(Engine.max_fps, 30)
	near(q.view_distance_m, 650.0, 1e-9)
	# Changing the tier keeps the offset on top of the new tier.
	Settings.set_value(&"quality_tier", &"low")
	near(tree.root.scaling_3d_scale, 0.5, 1e-6)
	q.set_governor_rung(0)
	near(tree.root.scaling_3d_scale, 0.6, 1e-6)
	eq(Engine.max_fps, 60)


func test_applier_reports_dev_stats() -> void:
	_make_applier()
	Settings.set_value(&"quality_tier", &"high")
	eq(DevStats.get_value(DevStats.QUALITY_TIER), &"high")
	eq(DevStats.get_value(DevStats.GOVERNOR_RUNG), 0)
	eq(DevStats.get_value(DevStats.THERMAL), Thermal.NOMINAL)
	eq(DevStats.get_value(DevStats.DRAW_CALL_BUDGET), 100)
	eq(DevStats.get_value(DevStats.TRIANGLE_BUDGET), 150000)


func test_applier_without_tuning_is_inert() -> void:
	_node = QualityScript.new()
	_node.tuning = null
	_node.load_tuning_on_ready = false
	_node.pace_frames = true
	Engine.max_fps = 77
	tree.root.add_child(_node)
	eq(Engine.max_fps, 77, "no tuning -> nothing applied")
