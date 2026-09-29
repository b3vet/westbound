extends WBTest
## TimeScale (src/run/time_scale.gd): slow motion scales the physics tick rate with
## the time scale (fixed sim dt per tick), honours reduced motion, restores 1.0.

var _ts: TimeScale
var _base_ticks: int
var _reduced: bool


func before_each() -> void:
	_base_ticks = Engine.physics_ticks_per_second
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", false)
	_ts = TimeScale.new()
	tree.root.add_child(_ts)


func after_each() -> void:
	_ts.queue_free()
	await tree.process_frame
	Settings.set_value(&"reduced_motion", _reduced)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks


func test_first_hit_keeps_the_tick_dt() -> void:
	var feel := Tuning.load_default().feel
	Events.slowmo_requested.emit(feel.slowmo_first_hit_scale, feel.slowmo_first_hit_s, TimeScale.REASON_FIRST_HIT)
	check(_ts.is_slowed())
	near(Engine.time_scale, 0.5, 1e-12)
	eq(Engine.physics_ticks_per_second, roundi(_base_ticks * 0.5))
	# Each physics tick still stands for one base tick of simulated time.
	eq(float(Engine.physics_ticks_per_second) / Engine.time_scale, float(_base_ticks))
	eq(1.0 / float(Engine.physics_ticks_per_second) * Engine.time_scale, 1.0 / float(_base_ticks),
		"physics delta == the base tick dt, exactly")
	_ts.advance_real(0.29)
	check(_ts.is_slowed(), "0.3 s real")
	_ts.advance_real(0.02)
	check(not _ts.is_slowed())
	eq(Engine.time_scale, 1.0)
	eq(Engine.physics_ticks_per_second, _base_ticks)


func test_crash_quarter_speed() -> void:
	_ts.request(0.25, 2.5, TimeScale.REASON_CRASH)
	eq(Engine.physics_ticks_per_second, roundi(_base_ticks * 0.25))
	near(Engine.time_scale, 0.25, 1e-12)
	eq(_ts.reason, TimeScale.REASON_CRASH)


func test_rounded_scales_stay_exact_per_tick() -> void:
	_ts.request(0.6, 0.25, TimeScale.REASON_THREAD)
	eq(Engine.physics_ticks_per_second, roundi(_base_ticks * 0.6))
	near(float(Engine.physics_ticks_per_second) / Engine.time_scale, float(_base_ticks), 1e-9)


func test_weaker_request_never_cuts_a_stronger_one() -> void:
	_ts.request(0.25, 2.5, TimeScale.REASON_CRASH)
	_ts.request(0.6, 0.25, TimeScale.REASON_THREAD)
	near(Engine.time_scale, 0.25, 1e-12)
	eq(_ts.reason, TimeScale.REASON_CRASH)
	_ts.request(0.2, 0.1, &"stronger")
	near(_ts.scale, 0.2, 1e-12, "a stronger one replaces it")


func test_reduced_motion_ignores_requests() -> void:
	Settings.set_value(&"reduced_motion", true)
	_ts.request(0.5, 0.3, TimeScale.REASON_FIRST_HIT)
	check(not _ts.is_slowed())
	eq(Engine.time_scale, 1.0)
	eq(_ts.ignored_count, 1)


func test_invalid_requests_are_ignored() -> void:
	_ts.request(1.0, 1.0)
	_ts.request(0.5, 0.0)
	_ts.request(0.0, 1.0)
	check(not _ts.is_slowed())
	eq(_ts.applied_count, 0)


func test_leaving_the_tree_restores() -> void:
	_ts.request(0.5, 10.0)
	tree.root.remove_child(_ts)
	eq(Engine.time_scale, 1.0)
	eq(Engine.physics_ticks_per_second, _base_ticks)
	tree.root.add_child(_ts)
