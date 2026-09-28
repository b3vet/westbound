extends WBTest
## The input hub and PlayerController. Spec: Controls (four layouts, mirroring,
## manual throttle, keyboard and gamepad) and Tests ("Equivalence: all four layouts
## produce identical physics for the same input values").
##
## Screen used here: 1280x720 canvas at 40 px/cm (max_drag = 100 px), touches with
## scripted timestamps through PlayerInput.handle_pointer().

const TestGyro := preload("res://tests/unit/test_gyro_control.gd")
const TestKeys := preload("res://tests/unit/test_keys_gamepad.gd")

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const PX_PER_CM := 40.0
const MAX_PX := 100.0
const DT := 1.0 / 120.0

var t: Tuning
var params: VehicleParams
var hub: PlayerInput
var fake: TestGyro.FakeGravity


func before_all() -> void:
	t = Tuning.load_default()
	params = VehicleParams.build(t, load("res://data/cars/falcon_gt.tres") as CarDef)


func before_each() -> void:
	hub = _make_hub(t.controls)


func after_each() -> void:
	if hub != null:
		hub.free()
		hub = null
	Settings.reset_to_defaults()


func _make_hub(tuning: ControlsTuning, safe: Rect2 = SCREEN) -> PlayerInput:
	var h := PlayerInput.new()
	h.auto_advance = false
	h.controls = tuning
	fake = TestGyro.FakeGravity.new()
	h.set_gravity_source(fake)
	h.configure_screen(SCREEN, safe, PX_PER_CM)
	h.set_layout(PlayerInput.DRAG, PlayerInput.AUTO, false)
	tree.root.add_child(h)
	return h


func _touch(i: int, pos: Vector2, pressed: bool, time_s: float, h: PlayerInput = null) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = i
	ev.position = pos
	ev.pressed = pressed
	(h if h != null else hub).handle_pointer(ev, time_s)


func _drag(i: int, pos: Vector2, time_s: float, h: PlayerInput = null) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = i
	ev.position = pos
	(h if h != null else hub).handle_pointer(ev, time_s)


func _key(h: PlayerInput, code: Key, pressed: bool, physical: bool = false) -> void:
	h.handle_key_event(TestKeys.key(code, pressed, physical))


# ---------------------------------------------------------------- Layouts

func test_layout_rects_right_and_left_handed() -> void:
	var l := hub.layout
	hub.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, false)
	check(l.has(l.gas_rect) and l.has(l.brake_rect) and l.has(l.boost_rect), "drag+manual has pedals")
	eq(l.drag_zone, Rect2(0.0, 0.0, 640.0, 720.0), "drag zone = left half")
	gt(l.gas_rect.position.x, 640.0, "gas on the right")
	lt(l.brake_rect.end.x, l.gas_rect.position.x, "brake beside the gas")
	lt(l.boost_rect.end.y, l.brake_rect.position.y, "boost above brake")
	near(l.gas_rect.size.x, t.controls.pedal_width_cm * PX_PER_CM, 1e-4, "pedal size in cm")
	hub.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, true)
	eq(l.drag_zone, Rect2(640.0, 0.0, 640.0, 720.0), "mirrored: drag zone right half")
	lt(l.gas_rect.end.x, 640.0, "mirrored: gas on the left")
	gt(l.brake_rect.position.x, l.gas_rect.end.x, "mirrored: brake beside")

	hub.set_layout(PlayerInput.GYRO, PlayerInput.MANUAL, false)
	lt(l.brake_rect.end.x, 640.0, "gyro+manual: brake bottom-left")
	gt(l.gas_rect.position.x, 640.0, "gas bottom-right")
	lt(l.boost_rect.end.y, l.gas_rect.position.y, "boost above gas")
	check(not l.has(l.drag_zone) and not l.has(l.hold_zone), "no drag or hold zone")
	hub.set_layout(PlayerInput.GYRO, PlayerInput.MANUAL, true)
	gt(l.brake_rect.position.x, 640.0, "mirrored: brake bottom-right")
	lt(l.gas_rect.end.x, 640.0, "mirrored: gas bottom-left")

	hub.set_layout(PlayerInput.GYRO, PlayerInput.AUTO, false)
	eq(l.hold_zone, SCREEN, "gyro+auto: hold anywhere")
	hub.set_layout(PlayerInput.DRAG, PlayerInput.AUTO, true)
	eq(l.drag_zone, SCREEN, "drag+auto: the whole screen")


func test_pedals_respect_the_safe_area() -> void:
	var safe := Rect2(88.0, 0.0, 1280.0 - 88.0 - 60.0, 720.0 - 42.0)
	var h := _make_hub(t.controls, safe)
	for mirrored: bool in [false, true]:
		h.set_layout(PlayerInput.GYRO, PlayerInput.MANUAL, mirrored)
		var l := h.layout
		for r: Rect2 in [l.gas_rect, l.brake_rect, l.boost_rect]:
			check(safe.encloses(r), "%s inside the safe area (mirrored=%s)" % [r, mirrored])
	h.free()


func test_gyro_falls_back_to_drag_when_unsupported() -> void:
	var src := GravitySource.new()   # desktop: not mobile
	hub.set_gravity_source(src)
	hub.set_layout(PlayerInput.GYRO, PlayerInput.AUTO, false)
	eq(hub.effective_steering, PlayerInput.DRAG, "no tilt on this platform")
	check(not hub.is_gyro_supported())
	hub.set_gravity_source(fake)
	eq(hub.effective_steering, PlayerInput.GYRO)


func test_follows_settings_until_pinned() -> void:
	hub.use_settings()
	eq(hub.steering_mode, PlayerInput.DRAG, "default drag")
	eq(hub.throttle_mode, PlayerInput.AUTO, "default auto")
	Settings.set_value(&"throttle_mode", &"manual")
	eq(hub.throttle_mode, PlayerInput.MANUAL, "follows the setting")
	Settings.set_value(&"left_handed", true)
	check(hub.layout.mirrored, "follows left-handed")
	Settings.set_value(&"steering_mode", &"gyro")
	eq(hub.effective_steering, PlayerInput.GYRO)
	hub.set_layout(PlayerInput.DRAG, PlayerInput.AUTO, false)
	Settings.set_value(&"steering_mode", &"drag")
	Settings.set_value(&"steering_mode", &"gyro")
	eq(hub.steering_mode, PlayerInput.DRAG, "pinned layout ignores Settings")


func test_sensitivity_scales_max_drag_and_angle() -> void:
	# Settings.DEFAULTS has no steer_* keys yet: the fallbacks (1.0) apply.
	near(hub.sensitivity, 1.0, 1e-12)
	near(hub.drag.max_drag_px, MAX_PX, 1e-9)
	near(hub.gyro.max_angle_rad, deg_to_rad(25.0), 1e-12)


# ---------------------------------------------------------------- Throttle and brake

func test_auto_throttle() -> void:
	hub.advance(DT)
	eq(hub.throttle, 1.0, "auto: full throttle")
	eq(hub.brake, 0.0)
	_touch(0, Vector2(640.0, 300.0), true, 0.0)
	_drag(0, Vector2(640.0, 400.0), 0.5)
	hub.advance(DT)
	eq(hub.brake, 1.0, "drag down brakes")
	eq(hub.throttle, 0.0, "braking cuts the throttle")


func test_manual_gas_and_proportional_brake_pedal() -> void:
	hub.set_layout(PlayerInput.GYRO, PlayerInput.MANUAL, false)
	var l := hub.layout
	hub.advance(DT)
	eq(hub.throttle, 0.0, "manual: coast without gas")
	_touch(0, l.gas_rect.get_center(), true, 0.0)
	hub.advance(DT)
	eq(hub.throttle, 1.0, "gas pedal = full throttle")
	check(hub.gas_pressed)
	var min_b := t.controls.pedal_brake_min_frac()
	var br := l.brake_rect
	_touch(1, Vector2(br.get_center().x, br.end.y - 0.001), true, 0.1)
	hub.advance(DT)
	near(hub.brake, min_b, 1e-4, "bottom edge of the brake pedal")
	eq(hub.throttle, 0.0, "brake cuts the gas")
	_drag(1, br.get_center(), 0.2)
	hub.advance(DT)
	near(hub.brake, min_b + (1.0 - min_b) * 0.5, 1e-6, "halfway up")
	_drag(1, Vector2(br.get_center().x, br.position.y), 0.3)
	hub.advance(DT)
	eq(hub.brake, 1.0, "top of the pedal = full brake")
	_drag(1, Vector2(br.get_center().x, br.position.y - 200.0), 0.4)
	hub.advance(DT)
	eq(hub.brake, 1.0, "the finger keeps the pedal when it slides off")
	_touch(1, Vector2.ZERO, false, 0.5)
	hub.advance(DT)
	eq(hub.brake, 0.0)
	eq(hub.throttle, 1.0, "gas again")
	_touch(0, Vector2.ZERO, false, 0.6)
	hub.advance(DT)
	eq(hub.throttle, 0.0, "released gas coasts")


func test_boost_button_is_one_edge() -> void:
	hub.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, false)
	var ctrl := PlayerController.new(hub)
	var input := VehicleInput.new()
	var state := VehicleState.new()
	_touch(0, hub.layout.boost_rect.get_center(), true, 0.0)
	hub.advance(DT)
	ctrl.update(DT, state, input)
	check(input.boost, "boost on this tick")
	hub.advance(DT)
	ctrl.update(DT, state, input)
	check(not input.boost, "and only this tick, although the finger is still down")


func test_gyro_auto_hold_brakes_and_swipe_boosts() -> void:
	hub.set_layout(PlayerInput.GYRO, PlayerInput.AUTO, false)
	_touch(0, Vector2(900.0, 500.0), true, 0.0)
	hub.advance(DT)
	eq(hub.brake, 1.0, "touch and hold anywhere brakes")
	_touch(0, Vector2(900.0, 500.0), false, 0.5)
	hub.advance(DT)
	eq(hub.brake, 0.0)
	# Swipe up: 300 px (7.5 cm) in 50 ms = 1.5 m/s.
	_touch(1, Vector2(900.0, 500.0), true, 1.0)
	_drag(1, Vector2(900.0, 200.0), 1.05)
	hub.advance(DT)
	check(hub.consume_boost(), "swipe up boosts")
	eq(hub.brake, 0.0, "the swiping finger stops braking")
	_touch(1, Vector2(900.0, 200.0), false, 1.1)


func test_drag_manual_ignores_right_half_for_steering() -> void:
	hub.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, false)
	_touch(0, Vector2(900.0, 100.0), true, 0.0)
	_drag(0, Vector2(1100.0, 100.0), 0.1)
	hub.advance(DT)
	eq(hub.steer, 0.0, "a touch on the right half does not steer")
	_touch(1, Vector2(300.0, 400.0), true, 0.2)
	_drag(1, Vector2(400.0, 400.0), 0.3)
	hub.advance(DT)
	eq(hub.steer, 1.0, "left half steers")


func test_keys_emit_signals_through_the_tree() -> void:
	var counts := {&"cam": 0, &"pause": 0, &"mute": 0}
	hub.camera_cycle_requested.connect(func() -> void: counts[&"cam"] += 1)
	hub.pause_requested.connect(func() -> void: counts[&"pause"] += 1)
	hub.mute_toggled.connect(func() -> void: counts[&"mute"] += 1)
	for code: Key in [KEY_C, KEY_P, KEY_ESCAPE, KEY_M]:
		tree.root.push_input(TestKeys.key(code, true))
		tree.root.push_input(TestKeys.key(code, false))
	tree.root.push_input(TestKeys.button(JOY_BUTTON_Y, true))
	hub.request_camera_cycle()
	eq(counts[&"cam"], 3, "C, pad Y, HUD button")
	eq(counts[&"pause"], 2, "P and Esc")
	eq(counts[&"mute"], 1, "M")


func test_touch_through_the_tree_and_gui_buttons_keep_theirs() -> void:
	# push_input takes window coordinates; the headless window is small and stretched.
	var to_window := tree.root.get_final_transform()
	var button := Button.new()
	button.position = Vector2(1100.0, 20.0)
	button.size = Vector2(120.0, 80.0)
	tree.root.add_child(button)
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.position = to_window * Vector2(1150.0, 50.0)
	ev.pressed = true
	tree.root.push_input(ev)
	check(not hub.drag.active, "a touch on a GUI button is not a steering touch")
	var up := ev.duplicate() as InputEventScreenTouch
	up.pressed = false
	tree.root.push_input(up)
	button.free()
	var down := InputEventScreenTouch.new()
	down.index = 1
	down.position = to_window * Vector2(500.0, 400.0)
	down.pressed = true
	tree.root.push_input(down)
	check(hub.drag.active, "elsewhere it starts the drag")
	var mv := InputEventScreenDrag.new()
	mv.index = 1
	mv.position = to_window * Vector2(620.0, 400.0)
	tree.root.push_input(mv)
	hub.advance(DT)
	eq(hub.steer, 1.0, "and steers")
	var lift := down.duplicate() as InputEventScreenTouch
	lift.pressed = false
	tree.root.push_input(lift)


func test_desktop_mouse_drags_emulated_mouse_ignored() -> void:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = Vector2(500.0, 400.0)
	mb.device = InputEvent.DEVICE_ID_EMULATION
	hub.handle_pointer(mb, 0.0)
	check(not hub.drag.active, "mouse emulated from touch is ignored (the touch counts)")
	mb.device = 0
	hub.handle_pointer(mb, 0.0)
	check(hub.drag.active, "a real mouse drags")
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(400.0, 400.0)
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	hub.handle_pointer(mm, 0.1)
	hub.advance(DT)
	eq(hub.steer, -1.0)


func test_release_all_on_focus_loss() -> void:
	_touch(0, Vector2(500.0, 400.0), true, 0.0)
	_drag(0, Vector2(700.0, 400.0), 0.1)
	_key(hub, KEY_S, true, true)
	hub.advance(DT)
	hub.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	hub.advance(DT)
	eq(hub.steer, 0.0)
	eq(hub.brake, 0.0, "no stuck keys")
	check(not hub.drag.active)


# ---------------------------------------------------------------- Equivalence

## Scripted logical inputs: [start_s, steer, brake, boost_at_start].
const SCRIPT: Array = [
	[0.0, 0.0, 0.0, false],
	[0.5, 1.0, 0.0, false],
	[1.5, 0.0, 0.0, false],
	[2.0, -1.0, 1.0, false],
	[2.8, 0.0, 0.0, false],
	[3.0, 0.0, 0.0, true],
	[3.5, 1.0, 0.0, false],
	[4.0, 1.0, 0.0, true],
	[4.2, -1.0, 0.0, false],
]
const RUN_S := 5.0
const LAYOUTS: Array[StringName] = [
	&"drag_auto", &"drag_manual", &"gyro_auto", &"gyro_manual",
	&"keys_auto", &"keys_manual", &"pad_auto", &"pad_manual",
]


class Driver:
	extends RefCounted
	var kind: StringName
	var hub: PlayerInput
	var fake: TestGyro.FakeGravity
	var steer := 0.0
	var brake := 0.0

	func _init(k: StringName, h: PlayerInput, f: TestGyro.FakeGravity) -> void:
		kind = k
		hub = h
		fake = f

	func manual() -> bool:
		return String(kind).ends_with("manual")

	func touch(i: int, pos: Vector2, pressed: bool, time_s: float) -> void:
		var ev := InputEventScreenTouch.new()
		ev.index = i
		ev.position = pos
		ev.pressed = pressed
		hub.handle_pointer(ev, time_s)

	func move(i: int, pos: Vector2, time_s: float) -> void:
		var ev := InputEventScreenDrag.new()
		ev.index = i
		ev.position = pos
		hub.handle_pointer(ev, time_s)

	func key(code: Key, pressed: bool) -> void:
		hub.handle_key_event(TestKeys.key(code, pressed))

	func start() -> void:
		var l := hub.layout
		match kind:
			&"drag_auto":
				touch(0, Vector2(640.0, 360.0), true, 0.0)
			&"drag_manual":
				touch(0, Vector2(320.0, 360.0), true, 0.0)
		if manual():
			match kind:
				&"keys_manual":
					key(KEY_UP, true)
				&"pad_manual":
					hub.handle_key_event(TestKeys.axis(JOY_AXIS_TRIGGER_RIGHT, 1.0))
				_:
					touch(5, l.gas_rect.get_center(), true, 0.0)
		if kind.begins_with("gyro"):
			fake.roll_deg = 0.0
			hub.recalibrate_gyro()

	## Raw events that make this layout produce (s, b) and, if asked, a boost.
	func apply(s: float, b: float, boost: bool, time_s: float) -> void:
		var l := hub.layout
		match kind:
			&"drag_auto":
				# Steer and brake with the thumb; a boost is a flick straight up
				# (300 px in 50 ms = 1.5 m/s) right after.
				var a := hub.drag.anchor
				var y := a.y + (MAX_PX * 1.2 if b > 0.0 else 0.0)
				var t0 := time_s - 0.05 if boost else time_s
				move(0, Vector2(a.x + s * MAX_PX * 1.2, y), t0)
				if boost:
					move(0, hub.drag.thumb + Vector2(0.0, -300.0), time_s)
			&"drag_manual":
				var a := hub.drag.anchor
				move(0, Vector2(a.x + s * MAX_PX * 1.2, a.y), time_s)
			&"gyro_auto", &"gyro_manual":
				fake.roll_deg = s * 30.0
			&"keys_auto", &"keys_manual":
				if (s > 0.0) != (steer > 0.0):
					key(KEY_RIGHT, s > 0.0)
				if (s < 0.0) != (steer < 0.0):
					key(KEY_LEFT, s < 0.0)
			&"pad_auto", &"pad_manual":
				hub.handle_key_event(TestKeys.axis(JOY_AXIS_LEFT_X, s))
		# Brake.
		match kind:
			&"drag_auto":
				pass
			&"gyro_auto":
				if b > 0.0 and brake == 0.0:
					touch(1, Vector2(900.0, 500.0), true, time_s)
				elif b == 0.0 and brake > 0.0:
					touch(1, Vector2(900.0, 500.0), false, time_s)
			&"keys_auto", &"keys_manual":
				if (b > 0.0) != (brake > 0.0):
					key(KEY_DOWN, b > 0.0)
			&"pad_auto", &"pad_manual":
				hub.handle_key_event(TestKeys.axis(JOY_AXIS_TRIGGER_LEFT, b))
			_:
				var br := l.brake_rect
				if b > 0.0 and brake == 0.0:
					touch(1, Vector2(br.get_center().x, br.position.y), true, time_s)
				elif b == 0.0 and brake > 0.0:
					touch(1, br.get_center(), false, time_s)
		# Boost.
		if boost:
			match kind:
				&"drag_auto":
					pass
				&"gyro_auto":
					touch(2, Vector2(300.0, 500.0), true, time_s - 0.05)
					move(2, Vector2(300.0, 200.0), time_s)
					touch(2, Vector2(300.0, 200.0), false, time_s)
				&"keys_auto", &"keys_manual":
					key(KEY_SHIFT, true)
					key(KEY_SHIFT, false)
				&"pad_auto", &"pad_manual":
					hub.handle_key_event(TestKeys.button(JOY_BUTTON_A, true))
					hub.handle_key_event(TestKeys.button(JOY_BUTTON_A, false))
				_:
					touch(3, l.boost_rect.get_center(), true, time_s)
					touch(3, l.boost_rect.get_center(), false, time_s)
		steer = s
		brake = b


## Runs the script through `kind` (or straight into VehicleInput when kind is empty).
## Returns [input_trace_hash, state_trace_hash, segment_end_inputs (PackedFloat64Array),
## boost_ticks, brake_ticks].
func _run(kind: StringName, tuning: ControlsTuning) -> Array:
	var state := VehicleState.new()
	VehiclePhysics.place(state, params, 0.0, 0.0, Units.kmh_to_mps(150.0))
	state.boost_meter = 1.0
	var input := VehicleInput.new()
	var h: PlayerInput = null
	var drv: Driver = null
	var ctrl: PlayerController = null
	if kind != &"":
		h = _make_hub(tuning)
		var steering := PlayerInput.GYRO if String(kind).begins_with("gyro") else PlayerInput.DRAG
		var thr := PlayerInput.MANUAL if String(kind).ends_with("manual") else PlayerInput.AUTO
		h.set_layout(steering, thr, false)
		drv = Driver.new(kind, h, fake)
		drv.start()
		ctrl = PlayerController.new(h)
		ctrl.on_attached(state)
	var ih := TraceHash.SEED
	var sh := TraceHash.SEED
	var ends := PackedFloat64Array()
	var seg := -1
	var ticks := roundi(RUN_S / DT)
	var ref_boost := false
	var boost_ticks := 0
	var brake_ticks := 0
	for i in ticks:
		var now := float(i) * DT
		var next_seg: int = seg + 1
		if next_seg < SCRIPT.size() and now >= float(SCRIPT[next_seg][0]) - DT * 0.5:
			if seg >= 0:
				ends.append(input.steer)
				ends.append(input.throttle)
				ends.append(input.brake)
			seg = next_seg
			var row: Array = SCRIPT[seg]
			if drv != null:
				drv.apply(float(row[1]), float(row[2]), bool(row[3]), now)
			ref_boost = bool(row[3])
		var row_now: Array = SCRIPT[seg]
		if ctrl != null:
			h.advance(DT)
			ctrl.update(DT, state, input)
		else:
			input.steer = float(row_now[1])
			input.brake = float(row_now[2])
			input.throttle = 0.0 if input.brake > 0.0 else 1.0
			input.boost = ref_boost
			ref_boost = false
		ih = input.hash_into(ih)
		VehiclePhysics.step(state, input, DT, params)
		sh = state.hash_into(sh)
		boost_ticks += 1 if state.boost_active else 0
		brake_ticks += 1 if input.brake > 0.0 else 0
	ends.append(input.steer)
	ends.append(input.throttle)
	ends.append(input.brake)
	if h != null:
		h.free()
	return [ih, sh, ends, boost_ticks, brake_ticks]


func _instant_tuning() -> ControlsTuning:
	# The layouts' own feel dynamics (80 ms release, 60 ms gyro filter, 0.15 s key ramp)
	# are tested on their own. Set to zero, every layout can jump to a value at once,
	# so the traces must match bit for bit.
	var c := t.controls.duplicate() as ControlsTuning
	c.drag_release_ms = 0.0
	c.gyro_smoothing_ms = 0.0
	c.keyboard_steer_ramp_s = 0.0
	return c


func test_equivalence_identical_physics_all_layouts() -> void:
	var c := _instant_tuning()
	var ref := _run(&"", c)
	gt(float(ref[3]), 0.0, "the script really boosts")
	gt(float(ref[4]), 0.0, "and brakes")
	for kind in LAYOUTS:
		var r := _run(kind, c)
		eq(r[2], ref[2], "%s: same inputs at every segment end" % kind)
		eq(r[0], ref[0], "%s: identical VehicleInput trace" % kind)
		eq(r[1], ref[1], "%s: identical physics trace hash (5 s)" % kind)


func test_equivalence_steady_values_with_real_tuning() -> void:
	# With the spec's dynamics the transitions differ by design; every held value
	# (end of each segment) must still be identical in every layout.
	var ref := _run(&"", t.controls)
	for kind in LAYOUTS:
		var r := _run(kind, t.controls)
		eq(r[2], ref[2], "%s: same held inputs" % kind)


func test_controller_copies_without_extras() -> void:
	var ctrl := PlayerController.new(hub)
	var input := VehicleInput.new()
	input.steer = 0.7
	input.boost = true
	hub.advance(DT)
	ctrl.update(DT, VehicleState.new(), input)
	eq(input.steer, 0.0, "overwrites every field")
	eq(input.throttle, 1.0)
	eq(input.brake, 0.0)
	check(not input.boost)


# ---------------------------------------------------------------- Overlay

func test_overlay_redraws_only_on_change() -> void:
	hub.auto_advance = false
	var overlay := (load("res://src/ui/controls_overlay.tscn") as PackedScene).instantiate() as ControlsOverlay
	tree.root.add_child(overlay)
	for i in 3:
		await tree.process_frame
	check(overlay.hub == hub, "finds the hub through its group")
	var n := overlay.redraw_count()
	gt(float(n), 0.0, "drew once")
	for i in 5:
		await tree.process_frame
	eq(overlay.redraw_count(), n, "idle: no redraw")
	_touch(0, Vector2(600.0, 400.0), true, 0.0)
	await tree.process_frame
	await tree.process_frame
	gt(float(overlay.redraw_count()), float(n), "a touch redraws")
	n = overlay.redraw_count()
	for i in 5:
		await tree.process_frame
	eq(overlay.redraw_count(), n, "a finger held still: no redraw")
	hub.set_layout(PlayerInput.GYRO, PlayerInput.MANUAL, true)
	await tree.process_frame
	await tree.process_frame
	gt(float(overlay.redraw_count()), float(n), "a layout change redraws")
	overlay.free()


func test_input_preview_scene_runs_every_layout() -> void:
	var preview := (load("res://src/input/dev/input_preview.tscn") as PackedScene).instantiate()
	tree.root.add_child(preview)
	await tree.process_frame
	var p_hub: PlayerInput = preview.get("hub")
	for steering: String in ["drag", "gyro"]:
		for throttle_kind: String in ["auto", "manual"]:
			preview.call("snap_setup", {"steering": steering, "throttle": throttle_kind,
					"left_handed": true})
			for i in 3:
				await tree.physics_frame
			eq(p_hub.effective_steering, StringName(steering), "simulated tilt stands in for gyro")
			check(p_hub.layout.mirrored)
			preview.call("refresh_readout")
			var label := preview.get_node("Panel/Readout") as Label
			check(label.text.contains(steering + " + " + throttle_kind), "readout shows the layout")
	preview.free()
