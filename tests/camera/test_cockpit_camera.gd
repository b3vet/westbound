extends WBTest
## Cockpit camera (plan D11, WP4.7; docs/COCKPIT.md). Spec: Cameras (cycling and saved
## choice, speed response, look-ahead, roll, shake, FOV punch, reduced motion); Cars →
## Modular car convention (Markers/cam_cockpit, SteeringWheel rotating with steer);
## Performance budget (draw calls, no StandardMaterial3D, no shadows). Hidden from
## players since 2026-10-01 (owner; CameraTuning.cockpit_player_enabled): these tests
## drive the mode directly (set_mode, cycle_mode(true)).

const RIG_SCENE := "res://src/camera/camera_rig.tscn"
const CAR_SCENE := "res://src/vehicle/player_car.tscn"
## A car on the old placeholder bake: these cases test the procedural cockpit and the stub eye
## (tests/art/test_art_cameras.gd covers model interiors).
const CAR_PATH := "res://tests/fixtures/placeholder_car/placeholder_car.tres"
const TOP_KMH := 280.0
const DT := 1.0 / 120.0

var ct: CameraTuning
var vt: VehicleTuning
var _tuning: Tuning
var _params: VehicleParams
var _nodes: Array[Node] = []
var _saved_mode: Variant
var _saved_reduced: Variant


func before_all() -> void:
	_tuning = Tuning.load_default()
	ct = _tuning.camera
	vt = _tuning.vehicle


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


func _make_rig(target: Node3D, state: VehicleState, mode: StringName = &"cockpit",
		car_def: CarDef = null) -> CameraRig:
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_mode(mode)
	rig.set_target(target, state, _top(), car_def)
	return rig


func _state(kmh: float) -> VehicleState:
	var st := VehicleState.new()
	st.v = Units.kmh_to_mps(kmh)
	return st


func _car_def(length_m: float, width_m: float, height_m: float) -> CarDef:
	var c := CarDef.new()
	c.length_m = length_m
	c.width_m = width_m
	c.height_m = height_m
	return c


func _player_car(road: RoadPath, self_tick: bool = false) -> PlayerCar:
	var def := load(CAR_PATH) as CarDef
	if _params == null:
		_params = VehicleParams.build(_tuning, def)
	var origin := FloatingOrigin.new()
	tree.root.add_child(origin)
	_nodes.append(origin)
	origin.setup(_tuning.road.floating_origin_shift_km)
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as PlayerCar
	car.self_tick = self_tick
	tree.root.add_child(car)
	_nodes.append(car)
	car.setup(RunContext.new(1), road, origin, def, _params)
	return car


## Camera3D local offset with the head's look rotation removed (sway + shake only).
func _head_offset(rig: CameraRig) -> Vector3:
	return rig.camera().transform.origin


# ---------------------------------------------------------------- Modes

func test_dev_cycle_includes_cockpit_and_wraps() -> void:
	check(ct.mode_arrays_error().is_empty(), ct.mode_arrays_error())
	eq(ct.modes[ct.modes.size() - 1], "cockpit", "cockpit appended last")
	eq(ct.cockpit_index(), ct.modes.size() - 1)
	var rig := _make_rig(_make_target(), _state(150.0), &"chase")
	var seen: Array[StringName] = []
	var on_changed := func(m: StringName) -> void: seen.append(m)
	Events.camera_mode_changed.connect(on_changed)
	for i in ct.modes.size():
		rig.cycle_mode(true)
		eq(Settings.get_value(&"camera_mode"), rig.mode, "saved")
	Events.camera_mode_changed.disconnect(on_changed)
	eq(seen, [&"far", &"hood", &"overhead", &"cockpit", &"chase"] as Array[StringName], "wraps")


func test_cockpit_hidden_from_players() -> void:
	check(not ct.cockpit_player_enabled, "hidden until further notice (owner, 2026-10-01)")
	eq(ct.player_modes(), PackedStringArray(["chase", "far", "hood", "overhead"]))
	check(not ct.is_player_mode(&"cockpit"))
	eq(ct.player_mode(&"cockpit"), &"hood", "a saved cockpit falls back to the other mounted view")
	eq(ct.player_mode(&"overhead"), &"overhead")
	eq(ct.player_mode(&"bogus"), StringName(ct.default_mode))
	# The C key / HUD CAM cycle never stops on it, and leaves it for chase when a dev
	# tool put the camera there.
	var rig := _make_rig(_make_target(), _state(150.0), &"chase")
	var seen: Array[StringName] = []
	for i in ct.modes.size():
		rig.cycle_mode()
		seen.append(rig.mode)
	eq(seen, [&"far", &"hood", &"overhead", &"chase", &"far"] as Array[StringName], "skips the cockpit")
	rig.set_mode(&"cockpit")
	check(rig.is_cockpit(), "still reachable directly (tests, dev tools)")
	rig.cycle_mode()
	eq(rig.mode, &"chase")
	# A saved cockpit loads as hood.
	Settings.from_dict({"camera_mode": "cockpit"})
	eq(Settings.get_value(&"camera_mode"), &"hood")
	eq(rig.mode, &"hood", "the rig follows the loaded value")


func test_player_switch_brings_the_cockpit_back() -> void:
	var on := ct.duplicate(true) as CameraTuning
	on.cockpit_player_enabled = true
	eq(on.mode_arrays_error(), "")
	eq(on.player_modes(), ct.modes, "every mode again")
	eq(on.player_mode(&"cockpit"), &"cockpit")
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	rig.tuning = on
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_target(_make_target(), _state(150.0), _top())
	rig.set_mode(&"overhead")
	rig.cycle_mode()
	eq(rig.mode, &"cockpit", "the player cycle reaches it")
	var bad := ct.duplicate(true) as CameraTuning
	bad.cockpit_fallback_mode = "cockpit"
	ne(bad.mode_arrays_error(), "", "the fallback must be a mode players can pick")


func test_cockpit_set_in_session_restored_at_startup() -> void:
	# A dev tool's choice (Settings.set_value is not sanitized; loading a save is).
	Settings.set_value(&"camera_mode", &"cockpit")
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	eq(rig.mode, &"cockpit")
	check(rig.is_cockpit())
	rig.set_physics_process(false)
	rig.set_target(_make_target(), _state(100.0), _top())
	check(rig.cockpit() != null and rig.cockpit().visible, "cockpit shown once there is a target")


func test_cockpit_only_visible_in_cockpit_mode() -> void:
	var rig := _make_rig(_make_target(), _state(150.0))
	check(rig.cockpit().visible, "visible in cockpit")
	for m: String in ct.modes:
		rig.set_mode(StringName(m))
		eq(rig.cockpit().visible, m == "cockpit", "visible only in cockpit (%s)" % m)
		if m != "cockpit":
			eq(rig.head_transform(), Transform3D.IDENTITY, "no head transform in %s" % m)


# ---------------------------------------------------------------- Eye position

func test_eye_derives_from_car_dims() -> void:
	for dims: Vector3 in [Vector3(4.5, 1.9, 1.25), Vector3(5.0, 2.0, 1.5), Vector3(4.0, 1.7, 1.1)]:
		var def := _car_def(dims.x, dims.y, dims.z)
		var target := _make_target()
		var rig := _make_rig(target, _state(120.0), &"cockpit", def)
		var want := Vector3(dims.y * ct.cockpit_eye_right_frac, dims.z * ct.cockpit_eye_up_frac,
			dims.x * ct.cockpit_eye_back_frac)
		near((rig.cockpit_eye_local() - want).length(), 0.0, 1e-6, "eye from %s" % dims)
		check(not rig.cockpit_eye_from_marker())
		near((rig.global_position - target.global_position - want).length(), 0.0, 1e-5, "rig at the eye")
		lt(want.x, 0.0, "left seat (right-hand traffic)")
		gt(want.y, dims.z * 0.5, "head height")
		lt(want.y, dims.z, "below the roof")


func test_eye_uses_marker_and_stays_rigid() -> void:
	var target := _make_target()
	var markers := Node3D.new()
	markers.name = "Markers"
	target.add_child(markers)
	var mk := Node3D.new()
	mk.name = "cam_cockpit"
	mk.position = Vector3(-0.41, 1.12, 0.3)
	markers.add_child(mk)
	var st := _state(200.0)
	var rig := _make_rig(target, st)
	check(rig.cockpit_eye_from_marker(), "authored marker used")
	near((rig.global_position - mk.global_position).length(), 0.0, 1e-5, "at the marker")
	# Moves and turns with the car: no spring lag at all.
	for i in 30:
		target.position += Vector3(0.05, 0.01, -st.v * DT)
		target.rotate_y(-0.002)
		rig.advance(DT)
		near((rig.global_position - mk.global_position).length(), 0.0, 1e-4, "rigid on the marker %d" % i)
		near((rig.global_basis.z - target.global_basis.z).length(), 0.0, 1e-4, "heading with the car %d" % i)


func test_player_car_stub_marker_falls_back_to_car_dims() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _player_car(road)
	car.place_at(10.0, road.lane_center_d(1, 10.0), 30.0)
	check(car.model.marker(&"cam_cockpit") != null, "placeholder has a (stub) marker")
	var rig := _make_rig(car, car.state, &"cockpit")
	check(not rig.cockpit_eye_from_marker(), "conform() stub ignored")
	var want := ct.cockpit_eye_default(car.car.length_m, car.car.width_m, car.car.height_m)
	near((rig.cockpit_eye_local() - want).length(), 0.0, 1e-6, "CarDef-proportional eye")


# ---------------------------------------------------------------- Body visibility

func test_body_hidden_in_cockpit_and_restored() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _player_car(road)
	var rig := _make_rig(car, car.state, &"chase")
	check(car.visual.visible and car.shadow.visible, "body shown in chase")
	rig.set_mode(&"cockpit")
	check(not car.visual.visible, "body hidden in cockpit")
	check(not car.shadow.visible, "blob shadow hidden in cockpit")
	rig.cycle_mode()   # cockpit -> chase (wraps)
	eq(rig.mode, &"chase")
	check(car.visual.visible and car.shadow.visible, "restored when leaving cockpit")
	for i in ct.modes.size() - 1:
		rig.cycle_mode(true)
		eq(car.visual.visible, rig.mode != &"cockpit", "shown only outside cockpit (%s)" % rig.mode)
	eq(rig.mode, &"cockpit")
	check(not car.visual.visible, "hidden again")

	# Target change while in cockpit: the old car comes back, the new one hides.
	var car2 := _player_car(road)
	rig.set_target(car2, car2.state, car2.params.top_speed_mps)
	check(car.visual.visible and car.shadow.visible, "old target restored")
	check(not car2.visual.visible and not car2.shadow.visible, "new target hidden")
	# Freeing the rig gives the body back.
	rig.free()
	check(car2.visual.visible and car2.shadow.visible, "restored when the rig leaves")


func test_targets_without_the_method_are_fine() -> void:
	var target := _make_target()
	var rig := _make_rig(target, _state(100.0))
	check(target.visible, "untouched")
	rig.set_mode(&"chase")
	check(target.visible)


# ---------------------------------------------------------------- Wheel and gauges

func test_wheel_follows_steer_sign_and_ratio() -> void:
	var st := _state(150.0)
	var rig := _make_rig(_make_target(), st)
	var ck := rig.cockpit()
	var ratio := vt.steering_wheel_ratio_factor
	for steer: float in [0.0, 0.03, -0.03, 0.06, -0.2]:
		st.steer_angle = steer
		rig.advance(DT)
		near(ck.wheel_angle_rad(), steer * ratio, 1e-9, "turn = steer x ratio (%s)" % steer)
		# The rim's 12 o'clock moves right (+X in the pivot frame) when steering right.
		var top := ck.steering_wheel.transform * Vector3.UP
		if steer > 0.0:
			gt(top.x, 0.0, "steer right -> clockwise")
		elif steer < 0.0:
			lt(top.x, 0.0, "steer left -> counter-clockwise")
		else:
			near(top.x, 0.0, 1e-9, "centred")
	# The column faces the driver: the pivot's +Z points back and up toward the eye.
	var col := ck.steering_pivot.transform.basis.z
	gt(col.z, 0.0, "column toward the driver")
	gt(col.y, 0.0, "tilted up")


func test_gauge_uniforms_track_speed_and_rpm() -> void:
	var st := _state(0.0)
	var rig := _make_rig(_make_target(), st)
	var mat := rig.cockpit().gauge_material
	var speedo := Units.kmh_to_mps(ct.cockpit_speedo_max_kmh)
	for pair: Vector2 in [Vector2(0.0, 900.0), Vector2(100.0, 4200.0), Vector2(250.0, 6800.0), Vector2(400.0, 9000.0)]:
		st.v = Units.kmh_to_mps(pair.x)
		st.rpm = pair.y
		rig.advance(DT)
		var sf := clampf(st.v / speedo, 0.0, 1.0)
		var rf := clampf(st.rpm / ct.cockpit_tach_max_rpm, 0.0, 1.0)
		near(rig.cockpit().speed_frac(), sf, 1e-9, "speed frac at %s km/h" % pair.x)
		near(rig.cockpit().rpm_frac(), rf, 1e-9, "rpm frac at %s" % pair.y)
		near(float(mat.get_shader_parameter(&"speed_frac")), sf, 1e-6, "speed uniform")
		near(float(mat.get_shader_parameter(&"rpm_frac")), rf, 1e-6, "rpm uniform")
	near(float(mat.get_shader_parameter(&"redline_frac")), vt.engine_redline_rpm / ct.cockpit_tach_max_rpm, 1e-6,
		"red band from the engine redline")


func test_draw_calls_and_materials_within_budget() -> void:
	var rig := _make_rig(_make_target(), _state(150.0), &"cockpit", _car_def(4.5, 1.9, 1.25))
	var ck := rig.cockpit()
	le(ck.draw_surface_count(), 4, "at most 4 draw calls")
	var meshes: Array[MeshInstance3D] = []
	var stack: Array[Node] = [ck]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MeshInstance3D:
			meshes.append(n as MeshInstance3D)
	var surfaces := 0
	var tris := 0
	for mi in meshes:
		surfaces += mi.mesh.get_surface_count()
		tris += CarModel.triangle_count(mi.mesh)
		eq(mi.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s casts no shadow" % mi.name)
		check(mi.material_override is ShaderMaterial, "%s uses a project shader" % mi.name)
	eq(surfaces, ck.draw_surface_count(), "every drawn surface counted")
	le(tris, 5000, "within the spec's interior budget (5k)")
	# The wheel and the gauges sit ahead of the eye, beyond the near plane.
	for mi: MeshInstance3D in [ck.steering_wheel, ck.gauges]:
		var aabb := CameraRig._relative_xform(ck, mi) * mi.mesh.get_aabb()
		lt(aabb.end.z, -ct.near_plane_m, "%s beyond the near plane" % mi.name)
		lt(aabb.end.y, 0.0, "%s below the eye line" % mi.name)


# ---------------------------------------------------------------- Interpolation

func test_cockpit_moves_exactly_with_camera_and_car() -> void:
	Settings.set_value(&"reduced_motion", true)   # no head sway: the head is constant
	var road := ArcRoadPath.new(400.0, 1, 3, _tuning.road)
	var car := _player_car(road, true)
	car.place_at(20.0, road.lane_center_d(1, 20.0), Units.kmh_to_mps(160.0))
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_mode(&"cockpit")
	rig.set_target(car, car.state, car.params.top_speed_mps)
	var ck := rig.cockpit()
	check(ck.get_parent() == rig and not ck.top_level, "child of the rig: same interpolated parent")
	await tree.physics_frame
	await tree.process_frame
	var ref_cam := Transform3D()
	var ref_car := Transform3D()
	var frames := 0
	for i in 40:
		await tree.process_frame
		var cam_i := rig.camera().get_global_transform_interpolated()
		var ck_i := ck.get_global_transform_interpolated()
		var car_i := car.get_global_transform_interpolated()
		var rel_cam := cam_i.affine_inverse() * ck_i
		var rel_car := car_i.affine_inverse() * ck_i
		if frames == 0:
			ref_cam = rel_cam
			ref_car = rel_car
		else:
			near((rel_cam.origin - ref_cam.origin).length(), 0.0, 1e-4, "cockpit vs camera, frame %d" % i)
			near((rel_cam.basis.z - ref_cam.basis.z).length(), 0.0, 1e-4, "cockpit vs camera basis, frame %d" % i)
			near((rel_car.origin - ref_car.origin).length(), 0.0, 1e-3, "cockpit vs car, frame %d" % i)
			near((rel_car.basis.z - ref_car.basis.z).length(), 0.0, 1e-3, "cockpit vs car basis, frame %d" % i)
		frames += 1
	gt(car.state.s, 25.0, "the car drove")


# ---------------------------------------------------------------- Motion

func test_head_sway_and_roll_bounded_and_off_with_reduced_motion() -> void:
	var st := _state(200.0)
	var rig := _make_rig(_make_target(), st)
	st.accel_lat = 7.0   # turning right hard
	st.accel_long = -9.0   # braking
	var peak := 0.0
	for i in 240:
		rig.advance(DT)
		var off := _head_offset(rig)
		peak = maxf(peak, maxf(absf(off.x), absf(off.z)))
	lt(_head_offset(rig).x, 0.0, "turning right sways the head left")
	lt(_head_offset(rig).z, 0.0, "braking sways the head forward")
	le(peak, ct.cockpit_head_sway_max_m + 1e-9, "sway bounded")
	gt(peak, 0.0, "sway present")
	lt(rig.roll_rad(), 0.0, "leans out of the turn with the body")
	le(absf(rig.roll_rad()), deg_to_rad(ct.roll_max_deg) + 1e-9, "roll bounded")
	# The cockpit rolls with the seat frame: its horizon tilts with the car body.
	gt(rig.global_basis.x.y, 0.0, "right side up (leaning left)")

	Settings.set_value(&"reduced_motion", true)
	for i in 60:
		rig.advance(DT)
		eq(_head_offset(rig), Vector3.ZERO, "no sway")
		eq(rig.roll_rad(), 0.0, "no roll")
	near(rig.global_basis.x.y, 0.0, 1e-6, "level seat frame")


func test_look_ahead_turns_the_head_not_the_cockpit() -> void:
	var st := _state(200.0)
	var target := _make_target()
	var rig := _make_rig(target, st)
	var seat0 := rig.global_basis
	var fwd0 := -rig.camera().global_basis.z
	st.yaw = deg_to_rad(3.0)   # moving into the right lane
	st.v_lat = 0.5
	for i in 240:
		rig.advance(DT)
	var fwd1 := -rig.camera().global_basis.z
	gt(fwd1.x, fwd0.x, "the view turns right")
	near((rig.global_basis.z - seat0.z).length(), 0.0, 1e-6, "the seat frame (and cockpit) stays with the car")
	# Smaller than chase: the head turns at most atan(look_ahead_max / look distance).
	var ci := ct.cockpit_index()
	var max_yaw := atan(ct.look_ahead_max_m / ct.mode_look_ahead_m[ci])
	var yaw := atan2(fwd1.x, -fwd1.z) - atan2(fwd0.x, -fwd0.z)
	le(yaw, max_yaw + 1e-4, "bounded look-ahead")
	# Looks forward and very slightly down at the road, never up into the sun.
	le(fwd0.y, 0.0, "never looks up")
	gt(fwd0.y, -0.1, "not at the dash")


func test_fov_follows_speed_with_mode_offset() -> void:
	var st := _state(100.0)
	var rig := _make_rig(_make_target(), st)
	var ci := ct.cockpit_index()
	near(rig.camera().fov, ct.fov_min_deg + ct.mode_fov_offset_deg[ci], 1e-4, "at 100 km/h")
	st.v = _top()
	rig.advance(DT)
	near(rig.camera().fov, ct.fov_max_deg + ct.mode_fov_offset_deg[ci], 1e-4, "at top speed")


func test_shake_and_punch_work_but_subtler() -> void:
	var peaks := {}
	for m: StringName in [&"chase", &"cockpit"]:
		var st := _state(150.0)
		var rig := _make_rig(_make_target(), st, m)
		var base_fov := rig.camera().fov
		var head := rig.head_transform()
		Events.hit.emit(Events.HIT_TRAFFIC, 1)
		Events.boost_started.emit()
		var shake_peak := 0.0
		var punch_peak := 0.0
		for i in 60:
			rig.advance(DT)
			var shake_local := rig.head_transform().affine_inverse() * rig.camera().transform
			shake_peak = maxf(shake_peak, shake_local.origin.length())
			punch_peak = maxf(punch_peak, rig.camera().fov - base_fov)
		eq(rig.head_transform(), head, "head steady at constant speed")
		peaks[m] = Vector2(shake_peak, punch_peak)
		_nodes.erase(rig)
		rig.free()
	var chase: Vector2 = peaks[&"chase"]
	var cockpit: Vector2 = peaks[&"cockpit"]
	gt(cockpit.x, 0.0, "cockpit shakes on a hit")
	lt(cockpit.x, chase.x, "subtler shake")
	gt(cockpit.y, 0.0, "cockpit FOV punch on boost")
	lt(cockpit.y, chase.y, "subtler punch")

	# Reduced motion: none of it.
	Settings.set_value(&"reduced_motion", true)
	var st2 := _state(150.0)
	var rig2 := _make_rig(_make_target(), st2)
	var fov := rig2.camera().fov
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	Events.boost_started.emit()
	for i in 30:
		rig2.advance(DT)
		eq(rig2.camera().transform, rig2.head_transform(), "no shake")
		near(rig2.camera().fov, fov, 1e-6, "no punch")


func test_rig_view_only_in_cockpit() -> void:
	var st := _state(220.0)
	st.accel_lat = 3.0
	st.steer_angle = 0.02
	st.rpm = 5000.0
	var h := st.trace_hash()
	var rig := _make_rig(_make_target(), st)
	for i in 120:
		rig.advance(DT)
	rig.cycle_mode()
	eq(st.trace_hash(), h, "camera and cockpit are view-only")
