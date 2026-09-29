extends WBTest
## CameraRig and DampedSpring. Spec: Cameras (spring follow, speed response 62 -> 78 deg,
## pull-back up to 15%, look-ahead up to 1.2 m toward the lateral velocity, roll up to
## 1.5 deg, shake, FOV punch, reduced motion, cycling and saved choice); Accessibility ->
## Reduced motion; Performance budget (far plane); Architecture (floating origin).

const RIG_SCENE := "res://src/camera/camera_rig.tscn"
const TOP_KMH := 280.0
const LANE_M := 3.6

var ct: CameraTuning
var _nodes: Array[Node] = []
var _saved_mode: Variant
var _saved_reduced: Variant


func before_all() -> void:
	ct = Tuning.load_default().camera


func before_each() -> void:
	_saved_mode = Settings.get_value(&"camera_mode")
	_saved_reduced = Settings.get_value(&"reduced_motion")
	Settings.set_value(&"camera_mode", &"chase")
	Settings.set_value(&"reduced_motion", false)


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	Settings.set_value(&"camera_mode", _saved_mode)
	Settings.set_value(&"reduced_motion", _saved_reduced)
	await tree.process_frame


# ---------------------------------------------------------------- Helpers

func _top() -> float:
	return Units.kmh_to_mps(TOP_KMH)


func _make_target() -> Node3D:
	var t := Node3D.new()
	t.name = "TestCar"
	tree.root.add_child(t)
	_nodes.append(t)
	return t


func _make_rig(target: Node3D, state: VehicleState, mode: StringName = &"chase") -> CameraRig:
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_mode(mode)
	rig.set_target(target, state, _top())
	return rig


func _state(kmh: float) -> VehicleState:
	var st := VehicleState.new()
	st.v = Units.kmh_to_mps(kmh)
	return st


## Steps `rig` for `seconds` at `hz`, moving the target forward at the state's speed
## along -Z (heading 0). Returns the camera position trace at every 1/30 s.
func _run(rig: CameraRig, target: Node3D, st: VehicleState, hz: float, seconds: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var dt := 1.0 / hz
	var steps := roundi(seconds * hz)
	var per := roundi(hz / 30.0)
	for i in steps:
		target.position += Vector3.FORWARD * (st.v * dt)
		rig.advance(dt)
		if (i + 1) % per == 0:
			out.append(rig.global_position - target.position)
	return out


# ---------------------------------------------------------------- DampedSpring

func test_spring_step_is_frame_rate_independent() -> void:
	for zeta: float in [0.6, 0.9, 1.0, 1.4]:
		var ref := PackedFloat64Array()
		for hz: float in [120.0, 60.0, 30.0]:
			var sp := DampedSpring.new(1.5, zeta)
			sp.reset(0.0)
			var per := roundi(hz / 30.0)
			var trace := PackedFloat64Array()
			for i in roundi(hz * 2.0):
				sp.step(1.0, 1.0 / hz)
				if (i + 1) % per == 0:
					trace.append(sp.value)
			if ref.is_empty():
				ref = trace
				continue
			for k in trace.size():
				near(trace[k], ref[k], 1e-9, "zeta %s hz %s sample %d" % [zeta, hz, k])


func test_spring_step_converges_with_bounded_overshoot() -> void:
	for zeta: float in [0.9, 1.0]:
		var sp := DampedSpring.new(1.6, zeta)
		sp.reset(0.0)
		var peak := 0.0
		for i in 240:
			sp.step(1.0, 1.0 / 120.0)
			peak = maxf(peak, sp.value)
		le(peak, 1.01, "overshoot at zeta %s" % zeta)
		near(sp.value, 1.0, 1e-3, "settled after 2 s at zeta %s" % zeta)
	var rigid := DampedSpring.new(0.0, 1.0)
	rigid.step(5.0, 1.0 / 120.0)
	near(rigid.value, 5.0, 0.0, "0 Hz is rigid")


# ---------------------------------------------------------------- Tuning

func test_tuning_mode_arrays_consistent() -> void:
	eq(ct.mode_arrays_error(), "")
	eq(ct.modes, PackedStringArray(["chase", "far", "hood", "overhead", "cockpit"]))
	eq(ct.mode_marker[ct.mode_index(&"hood")], "Markers/cam_hood")
	for i in ct.modes.size():
		le(ct.mode_position_damping_ratio[i], 1.0 + 1e-9, "position spring not over-damped")
		ge(ct.mode_position_damping_ratio[i], 0.7, "position spring at most slightly under-damped")


func test_fov_mapping() -> void:
	var top := _top()
	near(ct.fov_deg(Units.kmh_to_mps(100.0), top), 62.0, 1e-6, "62 at 100 km/h")
	near(ct.fov_deg(top, top), 78.0, 1e-6, "78 at top speed")
	near(ct.fov_deg(Units.kmh_to_mps(190.0), top), 70.0, 1e-6, "halfway (190 of 100..280)")
	near(ct.fov_deg(Units.kmh_to_mps(40.0), top), 62.0, 1e-6, "clamped below 100")
	near(ct.fov_deg(0.0, top), 62.0, 1e-6, "clamped at rest")
	near(ct.fov_deg(top * 1.08, top), 78.0, 1e-6, "clamped above top speed (boost)")
	# Monotonic in between.
	var prev := 0.0
	for kmh in range(100, 290, 10):
		var f := ct.fov_deg(Units.kmh_to_mps(float(kmh)), top)
		ge(f, prev, "monotonic at %d" % kmh)
		prev = f


func test_rig_fov_follows_speed() -> void:
	var target := _make_target()
	var st := _state(100.0)
	var rig := _make_rig(target, st)
	near(rig.camera().fov, 62.0, 1e-4, "rig FOV at 100 km/h")
	st.v = _top()
	rig.advance(1.0 / 120.0)
	near(rig.camera().fov, 78.0, 1e-4, "rig FOV at top speed")


func test_pullback_scales_with_speed_up_to_15_pct() -> void:
	var top := _top()
	var chase := ct.mode_index(&"chase")
	near(ct.pullback_scale(Units.kmh_to_mps(100.0), top, chase), 1.0, 1e-9)
	near(ct.pullback_scale(Units.kmh_to_mps(60.0), top, chase), 1.0, 1e-9)
	near(ct.pullback_scale(top, top, chase), 1.15, 1e-9)
	near(ct.pullback_scale(top * 1.1, top, chase), 1.15, 1e-9, "capped at 15%")
	near(ct.pullback_scale(Units.kmh_to_mps(190.0), top, chase), 1.075, 1e-9)
	near(ct.pullback_scale(top, top, ct.mode_index(&"hood")), 1.0, 1e-9, "hood is mounted")

	# In the rig: the settled chase distance at top speed is 15% longer than at 100 km/h.
	var target := _make_target()
	var st := _state(100.0)
	var rig := _make_rig(target, st)
	var slow := (rig.global_position - target.global_position).length()
	st.v = top
	rig.snap_to_target()
	var fast := (rig.global_position - target.global_position).length()
	within_pct(fast / slow, 1.15, 1e-4, "chase distance pull-back")


func test_no_lag_at_constant_speed() -> void:
	var target := _make_target()
	var st := _state(250.0)
	var rig := _make_rig(target, st)
	var start := rig.global_position - target.global_position
	var trace := _run(rig, target, st, 120.0, 2.0)
	near((trace[trace.size() - 1] - start).length(), 0.0, 1e-3, "camera keeps its offset at speed")


# ---------------------------------------------------------------- Rig springs

func test_rig_lateral_step_converges_same_at_any_rate() -> void:
	var traces: Array[PackedVector3Array] = []
	var overshoot := 0.0
	for hz: float in [120.0, 60.0, 30.0]:
		var target := _make_target()
		var st := _state(160.0)
		var rig := _make_rig(target, st)
		var before := rig.global_position - target.position
		target.position += Vector3.RIGHT * LANE_M   # the car jumps one lane right
		var trace := _run(rig, target, st, hz, 3.0)
		traces.append(trace)
		# Offset relative to the target: starts at before - lane, returns to before.
		for p in trace:
			overshoot = maxf(overshoot, (p - before).x)
		near((trace[trace.size() - 1] - before).length(), 0.0, 0.01, "settles at %s Hz" % hz)
	le(overshoot, 0.05 * LANE_M, "lateral overshoot bound")
	for k in traces[0].size():
		near((traces[1][k] - traces[0][k]).length(), 0.0, 1e-3, "60 vs 120 Hz sample %d" % k)
		near((traces[2][k] - traces[0][k]).length(), 0.0, 1e-3, "30 vs 120 Hz sample %d" % k)


func test_rig_heading_step_converges() -> void:
	var traces: Array[PackedFloat64Array] = []
	var springs: Array[PackedFloat64Array] = []
	var target_heading := deg_to_rad(20.0)
	for hz: float in [120.0, 60.0, 30.0]:
		var target := _make_target()
		var st := _state(0.0)
		var rig := _make_rig(target, st)
		target.basis = Basis(Vector3.UP, -target_heading)   # nose 20 deg to the right
		var trace := PackedFloat64Array()
		var spring := PackedFloat64Array()
		var peak := 0.0
		var per := roundi(hz / 30.0)
		for i in roundi(hz * 3.0):
			rig.advance(1.0 / hz)
			var h := CameraRig.heading_of(rig.global_basis, 0.0)
			peak = maxf(maxf(peak, h), rig.heading_rad())
			if (i + 1) % per == 0:
				trace.append(h)
				spring.append(rig.heading_rad())
		traces.append(trace)
		springs.append(spring)
		le(peak, target_heading * 1.05, "heading overshoot at %s Hz" % hz)
		near(trace[trace.size() - 1], target_heading, deg_to_rad(0.1), "heading settles at %s Hz" % hz)
		# The camera ends up behind the car on its new heading.
		var behind := rig.global_position - target.position
		near(CameraRig.heading_of(Basis.looking_at(-behind), 0.0), target_heading, deg_to_rad(0.5))
	for k in traces[0].size():
		# The heading spring is exact at any step size; the view direction also depends
		# on the position spring chasing the swinging offset (held per step), so it
		# agrees to a fraction of a degree.
		near(springs[1][k], springs[0][k], 1e-9, "heading spring 60 vs 120 Hz sample %d" % k)
		near(springs[2][k], springs[0][k], 1e-9, "heading spring 30 vs 120 Hz sample %d" % k)
		near(traces[1][k], traces[0][k], deg_to_rad(0.25), "view 60 vs 120 Hz sample %d" % k)
		near(traces[2][k], traces[0][k], deg_to_rad(0.5), "view 30 vs 120 Hz sample %d" % k)


func test_heading_wraps_the_short_way() -> void:
	var target := _make_target()
	var st := _state(0.0)
	target.basis = Basis(Vector3.UP, -deg_to_rad(179.0))
	var rig := _make_rig(target, st)
	target.basis = Basis(Vector3.UP, deg_to_rad(179.0))   # -179 deg: 2 deg away across +-180
	for i in 360:
		rig.advance(1.0 / 120.0)
		var h := CameraRig.heading_of(rig.global_basis, 0.0)
		ge(absf(h), deg_to_rad(170.0), "never swings through 0 (step %d)" % i)
		if absf(h) < deg_to_rad(170.0):
			return


# ---------------------------------------------------------------- Look-ahead and roll

func test_look_ahead_bounded_and_toward_lateral_velocity() -> void:
	near(ct.look_ahead_lateral_m(0.0), 0.0, 1e-9)
	near(ct.look_ahead_lateral_m(100.0), 1.2, 1e-9, "capped at 1.2 m")
	near(ct.look_ahead_lateral_m(-100.0), -1.2, 1e-9, "capped at 1.2 m to the left")
	gt(ct.look_ahead_lateral_m(1.0), 0.0, "+right lateral speed -> +right shift")

	var target := _make_target()
	var st := _state(200.0)
	var rig := _make_rig(target, st)
	st.yaw = deg_to_rad(3.0)   # nose right: moving into the right lane
	st.v_lat = 0.5
	var peak := 0.0
	for i in 240:
		rig.advance(1.0 / 120.0)
		peak = maxf(peak, absf(rig.look_ahead_lateral_m()))
	gt(rig.look_ahead_lateral_m(), 0.5, "shifted right")
	le(peak, 1.2 + 1e-6, "never past 1.2 m")
	# The camera looks to the right of straight ahead (heading 0 faces -Z; right is +X).
	gt(-rig.global_basis.z.x, 0.0, "view turns toward the right lane")


func test_roll_bounded_and_into_the_turn() -> void:
	var max_rad := deg_to_rad(1.5)
	near(ct.roll_rad(1000.0), max_rad, 1e-9)
	near(ct.roll_rad(-1000.0), -max_rad, 1e-9)
	var target := _make_target()
	var st := _state(200.0)
	var rig := _make_rig(target, st)
	st.accel_lat = 50.0
	var peak := 0.0
	for i in 360:
		rig.advance(1.0 / 120.0)
		peak = maxf(peak, absf(rig.roll_rad()))
	le(peak, max_rad + 1e-6, "roll never past 1.5 deg")
	near(rig.roll_rad(), max_rad, 1e-3, "full roll under hard lateral accel")
	lt(rig.global_basis.x.y, 0.0, "right turn -> right side down")


func test_reduced_motion_zeroes_roll_shake_and_punch() -> void:
	var target := _make_target()
	var st := _state(200.0)
	var rig := _make_rig(target, st)
	st.accel_lat = 5.0
	rig.shake(1.0, 1.0)
	rig.fov_punch(6.0, 1.0)
	for i in 60:
		rig.advance(1.0 / 120.0)
	gt(absf(rig.roll_rad()), 0.0, "roll without reduced motion")
	gt(rig.shake_amplitude(), 0.0, "shake without reduced motion")
	gt(rig.punch_deg(), 0.0, "punch without reduced motion")
	gt(rig.camera().position.length(), 0.0, "shake moves the camera")
	var base_fov := ct.fov_deg(st.v, _top())
	gt(rig.camera().fov, base_fov, "punch widens the FOV")

	Settings.set_value(&"reduced_motion", true)
	rig.shake(1.0, 1.0)
	rig.fov_punch(6.0, 1.0)
	Events.camera_shake_requested.emit(1.0, 1.0)
	Events.boost_started.emit()
	for i in 60:
		rig.advance(1.0 / 120.0)
		eq(rig.roll_rad(), 0.0, "no roll")
		eq(rig.shake_amplitude(), 0.0, "no shake")
		eq(rig.punch_deg(), 0.0, "no punch")
		eq(rig.camera().transform, Transform3D.IDENTITY, "camera not displaced")
		near(rig.camera().fov, base_fov, 1e-4, "FOV is the plain speed FOV")
	near(rig.global_basis.x.y, 0.0, 1e-6, "horizon level")


func test_shake_and_punch_fade_and_listen_to_events() -> void:
	var target := _make_target()
	var st := _state(150.0)
	var rig := _make_rig(target, st)
	Events.camera_shake_requested.emit(0.5, 0.2)
	near(rig.shake_amplitude(), 0.5, 1e-6, "shake request received")
	rig.shake(0.1, 5.0)
	near(rig.shake_amplitude(), 0.5, 1e-6, "a weaker shake does not cut a stronger one")
	for i in 30:
		rig.advance(1.0 / 120.0)
	eq(rig.shake_amplitude(), 0.0, "shake over after its duration")
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	near(rig.shake_amplitude(), Tuning.load_default().feel.hit_shake_strength, 1e-6, "hit shakes")
	for i in 120:
		rig.advance(1.0 / 120.0)
	Events.scored.emit(Events.CLOSE_PASS, 30, 1.0, 0.5)
	near(rig.shake_amplitude(), Tuning.load_default().feel.close_pass_shake_strength, 1e-6, "close pass: tiny shake")
	lt(rig.shake_amplitude(), Tuning.load_default().feel.hit_shake_strength, "tiny")
	Events.boost_started.emit()
	var peak := 0.0
	for i in 120:
		rig.advance(1.0 / 120.0)
		peak = maxf(peak, rig.punch_deg())
	near(peak, Tuning.load_default().feel.boost_fov_punch_deg, 0.05, "boost punch peaks at its amount")
	eq(rig.punch_deg(), 0.0, "punch eases back")


# ---------------------------------------------------------------- Modes

func test_cycle_mode_wraps_saves_and_emits() -> void:
	var target := _make_target()
	var rig := _make_rig(target, _state(150.0))
	var seen: Array[StringName] = []
	var on_changed := func(m: StringName) -> void: seen.append(m)
	Events.camera_mode_changed.connect(on_changed)
	eq(rig.mode, &"chase")
	for i in 5:
		rig.cycle_mode()
		eq(Settings.get_value(&"camera_mode"), rig.mode, "saved")
	Events.camera_mode_changed.disconnect(on_changed)
	eq(seen, [&"far", &"hood", &"overhead", &"cockpit", &"chase"] as Array[StringName],
			"wraps through the five modes (cockpit: WP4.7, tests/camera/test_cockpit_camera.gd)")


func test_saved_mode_restored_at_startup() -> void:
	Settings.set_value(&"camera_mode", &"overhead")
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	eq(rig.mode, &"overhead")
	Settings.set_value(&"camera_mode", &"bogus")
	var rig2: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig2)
	_nodes.append(rig2)
	eq(rig2.mode, StringName(ct.default_mode), "unknown saved mode -> default")


func test_hood_uses_marker_when_present() -> void:
	var target := _make_target()
	var markers := Node3D.new()
	markers.name = "Markers"
	target.add_child(markers)
	var cam_hood := Node3D.new()
	cam_hood.name = "cam_hood"
	cam_hood.position = Vector3(0.0, 1.05, -0.9)
	markers.add_child(cam_hood)
	var st := _state(200.0)
	var rig := _make_rig(target, st, &"hood")
	near((rig.global_position - cam_hood.global_position).length(), 0.0, 1e-5, "at the marker")
	target.position += Vector3(2.0, 0.0, -5.0)
	rig.advance(1.0 / 120.0)
	near((rig.global_position - cam_hood.global_position).length(), 0.0, 1e-5, "rigid on the marker")
	# Without a marker it falls back to the tuning offset.
	var bare := _make_target()
	var rig2 := _make_rig(bare, st, &"hood")
	var hi := ct.mode_index(&"hood")
	var want := Vector3(0.0, ct.mode_height_m[hi], ct.mode_behind_m[hi])
	near((rig2.global_position - bare.global_position - want).length(), 0.0, 1e-5, "tuning offset")


func test_modes_frame_the_car_ahead() -> void:
	# Every mode looks forward (heading 0 = -Z) and, except the mounted hood and cockpit,
	# sits behind and above.
	for m: String in ct.modes:
		var target := _make_target()
		var rig := _make_rig(target, _state(150.0), StringName(m))
		lt(-rig.global_basis.z.z, 0.0, "%s looks forward" % m)
		if m != "hood" and m != "cockpit":
			gt(rig.global_position.z, target.position.z, "%s is behind" % m)
			gt(rig.global_position.y, target.position.y + 1.0, "%s is above" % m)
			# Glare rule: chase-type cameras never pitch up above the horizon.
			le(-rig.global_basis.z.y, 0.0, "%s does not look up" % m)


# ---------------------------------------------------------------- Origin and far plane

func _origin_run(shift: bool) -> PackedVector3Array:
	var target := _make_target()
	var st := _state(200.0)
	var rig := _make_rig(target, st)
	var out := PackedVector3Array()
	target.position += Vector3.RIGHT * LANE_M   # mid-transient when the shift lands
	for i in 60:
		target.position += Vector3.FORWARD * (st.v / 120.0)
		rig.advance(1.0 / 120.0)
		if shift and i == 20:
			var offset := Vector3(1500.0, 3.0, -1300.0)
			var before := rig.global_position - target.position
			Events.origin_shifted.emit(offset)
			target.position -= offset
			near((rig.global_position - target.position - before).length(), 0.0, 1e-3,
					"no jump at the shift")
		out.append(rig.global_position - target.position)
	return out


func test_origin_shift_keeps_camera_to_target_offset() -> void:
	var plain := _origin_run(false)
	var shifted := _origin_run(true)
	for k in plain.size():
		near((shifted[k] - plain[k]).length(), 0.0, 2e-3, "offset unchanged at tick %d" % k)


func test_far_plane_from_quality() -> void:
	var target := _make_target()
	var rig := _make_rig(target, _state(150.0))
	if Quality.effective == null:
		fail("Quality has no effective settings")
		return
	near(rig.camera().far, Quality.far_plane_m, 1e-3, "far plane from Quality")
	var rung := Quality.governor_rung
	Quality.set_governor_rung(Quality.RUNG_VIEW_DISTANCE)
	near(rig.camera().far, Quality.far_plane_m, 1e-3, "re-applied on governor change")
	Quality.set_governor_rung(rung)
	near(rig.camera().far, Quality.far_plane_m, 1e-3, "and back")


func test_rig_never_writes_vehicle_state() -> void:
	var target := _make_target()
	var st := _state(220.0)
	st.accel_lat = 3.0
	st.yaw = 0.02
	var h := st.trace_hash()
	var rig := _make_rig(target, st)
	for i in 120:
		rig.advance(1.0 / 120.0)
	rig.cycle_mode()
	eq(st.trace_hash(), h, "camera is view-only")


func test_straight_down_offset_is_safe() -> void:
	var t := ct.duplicate() as CameraTuning
	var oi := t.mode_index(&"overhead")
	t.mode_behind_m[oi] = 0.0
	t.mode_look_ahead_m[oi] = 0.0
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	rig.tuning = t
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_mode(&"overhead")
	var target := _make_target()
	rig.set_target(target, _state(150.0), _top())
	rig.advance(1.0 / 120.0)
	near(-rig.global_basis.z.y, -1.0, 1e-4, "looks straight down")
	check(rig.global_basis.is_conformal(), "valid basis")
	# Screen-up is the direction of travel (heading 0 = -Z).
	lt(rig.global_basis.y.z, 0.0, "travel is up on screen")


func test_runs_after_the_car_each_physics_tick() -> void:
	var rig := _make_rig(_make_target(), _state(100.0))
	gt(rig.process_physics_priority, 0, "after default-priority nodes (the car)")
	check(rig.top_level, "independent of its parent's transform")
