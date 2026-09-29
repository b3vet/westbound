extends WBTest
## The slow-motion table (TimeScale, WP7.4). Spec: Audio, haptics and game feel →
## "Slow motion: thread 0.6x for 0.25 s, first hit 0.5x for 0.3 s, crash 0.25x for
## 2.5 s"; Accessibility → Reduced motion turns off camera shake, camera roll, the FOV
## punch and slow motion. The thread's slow motion is asked by TimeScale itself on
## Events.scored(THREAD); the first hit and the crash arrive on slowmo_requested.
## (Shake, roll and punch under reduced motion: tests/unit/test_camera_rig.gd; here
## the rig is checked against the events the juice relies on.)

const RIG_SCENE := "res://src/camera/camera_rig.tscn"

var _ts: TimeScale
var _feel: FeelTuning
var _base_ticks: int
var _reduced: bool
var _nodes: Array[Node] = []


func before_each() -> void:
	_base_ticks = Engine.physics_ticks_per_second
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", false)
	_feel = Tuning.load_default().feel
	_ts = TimeScale.new()
	tree.root.add_child(_ts)
	_nodes.append(_ts)


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame
	Settings.set_value(&"reduced_motion", _reduced)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks


func _first_hit() -> void:
	Events.slowmo_requested.emit(_feel.slowmo_first_hit_scale, _feel.slowmo_first_hit_s, TimeScale.REASON_FIRST_HIT)


func _crash() -> void:
	Events.slowmo_requested.emit(_feel.slowmo_crash_scale, _feel.slowmo_crash_s, TimeScale.REASON_CRASH)


func _thread() -> void:
	Events.scored.emit(Events.THREAD, 60, 3.0, 0.3)


func test_the_spec_table() -> void:
	near(_feel.slowmo_thread_scale, 0.6, 1e-9)
	near(_feel.slowmo_thread_s, 0.25, 1e-9)
	near(_feel.slowmo_first_hit_scale, 0.5, 1e-9)
	near(_feel.slowmo_first_hit_s, 0.3, 1e-9)
	near(_feel.slowmo_crash_scale, 0.25, 1e-9)
	near(_feel.slowmo_crash_s, 2.5, 1e-9)


func test_thread_slows_to_0_6_for_0_25_s() -> void:
	_thread()
	check(_ts.is_slowed(), "a thread slows time")
	eq(_ts.reason, TimeScale.REASON_THREAD)
	near(_ts.scale, 0.6, 1e-12)
	near(float(Engine.physics_ticks_per_second) / Engine.time_scale, float(_base_ticks), 1e-9,
		"each tick is still one base tick of sim time")
	_ts.advance_real(0.24)
	check(_ts.is_slowed(), "0.25 s real")
	_ts.advance_real(0.02)
	check(not _ts.is_slowed())
	eq(Engine.time_scale, 1.0)


func test_other_scoring_events_do_not_slow_time() -> void:
	for k: StringName in [Events.PASS, Events.CLOSE_PASS, Events.CUT]:
		Events.scored.emit(k, 10, 1.0, 0.5)
	check(not _ts.is_slowed())
	eq(_ts.applied_count, 0)


func test_overlap_crash_beats_first_hit_beats_thread() -> void:
	_thread()
	_first_hit()
	eq(_ts.reason, TimeScale.REASON_FIRST_HIT, "a first hit replaces a thread")
	near(_ts.scale, 0.5, 1e-12)
	_thread()
	eq(_ts.reason, TimeScale.REASON_FIRST_HIT, "a thread never cuts a first hit short")
	_crash()
	eq(_ts.reason, TimeScale.REASON_CRASH, "the crash replaces everything")
	_first_hit()
	_thread()
	eq(_ts.reason, TimeScale.REASON_CRASH)
	near(_ts.remaining_s, 2.5, 1e-9, "and keeps its 2.5 s")
	_ts.advance_real(2.5)
	check(not _ts.is_slowed())
	_thread()
	eq(_ts.reason, TimeScale.REASON_THREAD, "after it ends, a thread slows again")


func test_back_to_back_threads_restart_the_duration() -> void:
	_thread()
	_ts.advance_real(0.2)
	_thread()
	near(_ts.remaining_s, _feel.slowmo_thread_s, 1e-9)
	_ts.advance_real(0.2)
	check(_ts.is_slowed())


func test_reduced_motion_turns_slow_motion_off() -> void:
	Settings.set_value(&"reduced_motion", true)
	_thread()
	_first_hit()
	_crash()
	check(not _ts.is_slowed())
	eq(Engine.time_scale, 1.0)
	eq(_ts.ignored_count, 3)


func test_reduced_motion_stops_shake_and_boost_punch_from_events() -> void:
	var target := Node3D.new()
	tree.root.add_child(target)
	_nodes.append(target)
	var st := VehicleState.new()
	st.v = 60.0
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_target(target, st, 80.0)
	Events.boost_started.emit()
	rig.advance(_feel.boost_fov_punch_s * 0.25)
	gt(rig.punch_deg(), 0.0, "boost_started punches the FOV")
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	gt(rig.shake_amplitude(), 0.0, "a hit shakes")
	Settings.set_value(&"reduced_motion", true)
	Events.boost_started.emit()
	Events.hit.emit(Events.HIT_BARRIER, 1)
	rig.advance(1.0 / 120.0)
	eq(rig.punch_deg(), 0.0, "no punch with reduced motion")
	eq(rig.shake_amplitude(), 0.0, "no shake with reduced motion")
