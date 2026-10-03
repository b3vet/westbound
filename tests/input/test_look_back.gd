extends WBTest
## Look back (owner request, 2026-10-03): the LOOK BACK hold button just above the gas
## column (every layout, mirrored for left hands, inside the safe area, sized by
## controls_scale up to 100 %), held through multi-touch with the gas (iOS-style touch
## ids through TouchSlots), B on the keyboard, gamepad B on any device and the right
## stick pushed back (with hysteresis); Events.look_back_changed on every change, never
## while paused, and never a change to what the car is told (VehicleInput).
## docs/CONTROLS.md → Look back.

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const NOTCHED_SAFE := Rect2(80.0, 0.0, 1120.0, 690.0)
const PX_PER_CM := 720.0 / 6.8
const DT := 1.0 / 120.0
const IOS_GAS := 1_893_457_201
const IOS_LOOK := 2_404_118_377
const PAD_DEVICE := 3

var t: Tuning
var hub: PlayerInput
var _events: Array[bool] = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	_events.clear()
	Events.look_back_changed.connect(_on_look_back)
	hub = _make_hub(PlayerInput.DRAG, PlayerInput.MANUAL, false)


func after_each() -> void:
	if Events.look_back_changed.is_connected(_on_look_back):
		Events.look_back_changed.disconnect(_on_look_back)
	tree.paused = false
	if hub != null:
		hub.free()
		hub = null
	Settings.reset_to_defaults()


func _on_look_back(on: bool) -> void:
	_events.append(on)


func _make_hub(steering: StringName, throttle: StringName, left: bool, safe: Rect2 = SCREEN) -> PlayerInput:
	var h := PlayerInput.new()
	h.auto_advance = false
	h.controls = t.controls
	h.configure_screen(SCREEN, safe, PX_PER_CM)
	h.set_layout(steering, throttle, left)
	tree.root.add_child(h)
	return h


func _touch(id: int, pos: Vector2, pressed: bool, time_s: float) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = id
	ev.position = pos
	ev.pressed = pressed
	hub.handle_pointer(ev, time_s)


func _drag(id: int, pos: Vector2, time_s: float) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = id
	ev.position = pos
	hub.handle_pointer(ev, time_s)


func _button(b: JoyButton, pressed: bool, device: int = PAD_DEVICE) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = b
	ev.pressed = pressed
	ev.device = device
	return ev


func _axis(a: JoyAxis, v: float, device: int = PAD_DEVICE) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.axis = a
	ev.axis_value = v
	ev.device = device
	return ev


func _key_b(pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_B
	ev.pressed = pressed
	return ev


# ---------------------------------------------------------------- Layout

func test_button_sits_just_above_the_gas_column_in_every_layout() -> void:
	var l := hub.layout
	for steering: StringName in [PlayerInput.DRAG, PlayerInput.GYRO]:
		for throttle: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
			for left: bool in [false, true]:
				hub.set_layout(steering, throttle, left)
				var what := "%s %s %s" % [steering, throttle, "left" if left else "right"]
				check(l.has(l.look_rect), "%s: the button exists" % what)
				check(l.safe.encloses(l.look_rect), "%s: inside the safe area" % what)
				var cm := l.px_per_cm
				near(l.look_rect.size.x, t.controls.look_back_width_cm * cm, 1e-3, "%s: width" % what)
				near(l.look_rect.size.y, t.controls.look_back_height_cm * cm, 1e-3, "%s: height" % what)
				var cap_top := l.safe.end.y - t.controls.controls_margin_cm * cm \
						- (t.controls.pedal_height_cm + t.controls.boost_cap_height_cm) * cm
				near(l.look_rect.end.y, cap_top - t.controls.look_back_gap_cm * cm, 1e-3,
						"%s: the gap above the cap" % what)
				var edge := t.controls.controls_margin_cm * cm
				if left:
					near(l.look_rect.position.x, l.safe.position.x + edge, 1e-3, "%s: mirrored to the left" % what)
				else:
					near(l.look_rect.end.x, l.safe.end.x - edge, 1e-3, "%s: on the right" % what)
				if l.has(l.gas_control):
					near(l.look_rect.get_center().x, l.gas_control.get_center().x, 1e-3, "%s: over the gas" % what)
					check(not l.look_rect.intersects(l.gas_control), "%s: off the gas column" % what)
					check(not l.look_rect.intersects(l.brake_rect), "%s: off the brake" % what)
				eq(l.zone_at(l.look_rect.get_center()), ControlsLayout.Zone.LOOK, "%s: hit-tests first" % what)


func test_button_follows_the_safe_area_and_caps_its_size() -> void:
	hub.free()
	hub = _make_hub(PlayerInput.DRAG, PlayerInput.MANUAL, false, NOTCHED_SAFE)
	var l := hub.layout
	check(NOTCHED_SAFE.encloses(l.look_rect), "inside a notched safe area")
	Settings.set_value(&"controls_scale", 0.8)
	near(l.look_rect.size.x, t.controls.look_back_width_cm * PX_PER_CM * 0.8, 1e-3, "80 %: smaller")
	Settings.set_value(&"controls_scale", 1.2)
	near(l.look_rect.size.x, t.controls.look_back_width_cm * PX_PER_CM, 1e-3, "120 %: never past 100 %")
	hub.free()
	hub = _make_hub(PlayerInput.DRAG, PlayerInput.MANUAL, false)
	l = hub.layout
	for cs: float in t.hud.settings_controls_scales:
		Settings.set_value(&"controls_scale", cs)
		ge(l.look_rect.position.y, t.controls.look_back_top_clear_cm * PX_PER_CM - 1e-3,
				"controls %d %%: clear of the HUD's top band (lives, buttons, achievement toast)" % roundi(cs * 100.0))
		check(not l.look_rect.intersects(l.gas_control), "controls %d %%: off the gas column" % roundi(cs * 100.0))
	Settings.set_value(&"controls_scale", t.controls.controls_scale_max_factor)
	near(l.look_rect.size.y, t.controls.look_back_min_height_cm * PX_PER_CM, 1e-3,
			"the largest controls: the minimum height, still a target")
	near(l.gas_control.position.y - l.look_rect.end.y, t.controls.look_back_min_gap_cm * PX_PER_CM, 1e-3,
			"and the minimum gap to the cap")


# ---------------------------------------------------------------- Touch

func test_hold_with_the_gas_held_multi_touch_ios_ids() -> void:
	var l := hub.layout
	_touch(IOS_GAS, l.gas_rect.get_center(), true, 0.0)
	hub.advance(DT)
	eq(hub.throttle, 1.0, "gas held")
	check(not hub.look_back, "not looking back yet")
	_touch(IOS_LOOK, l.look_rect.get_center(), true, 0.1)
	hub.advance(DT)
	check(hub.look_back and hub.look_pressed, "a second finger on LOOK BACK")
	eq(hub.throttle, 1.0, "the gas stays on")
	eq(_events, [true] as Array[bool], "Events.look_back_changed(true) once")
	# The look finger slides onto the gas column: it stays a look finger (captured).
	_drag(IOS_LOOK, l.gas_rect.get_center(), 0.2)
	check(hub.look_back, "captured while it slides")
	_touch(IOS_LOOK, l.gas_rect.get_center(), false, 0.3)
	hub.advance(DT)
	check(not hub.look_back, "lifted: back to the road ahead")
	eq(hub.throttle, 1.0, "the gas finger still holds")
	eq(_events, [true, false] as Array[bool])
	_touch(IOS_GAS, l.gas_rect.get_center(), false, 0.4)
	hub.advance(DT)
	eq(hub.throttle, 0.0)
	check(not hub.gas_pressed)


func test_drag_auto_button_takes_its_touch_from_the_drag_zone() -> void:
	hub.set_layout(PlayerInput.DRAG, PlayerInput.AUTO, false)
	_touch(IOS_LOOK, hub.layout.look_rect.get_center(), true, 0.0)
	check(hub.look_back, "looking back")
	check(not hub.drag.active, "not a steering thumb")
	_touch(IOS_GAS, Vector2(300.0, 400.0), true, 0.1)
	check(hub.drag.active, "another thumb still steers")
	_touch(IOS_LOOK, Vector2.ZERO, false, 0.2)
	check(not hub.look_back)


# ---------------------------------------------------------------- Keys and pad

func test_keyboard_b_holds_look_back() -> void:
	hub.handle_key_event(_key_b(true))
	check(hub.look_back, "B held")
	hub.handle_key_event(_key_b(false))
	check(not hub.look_back, "B released")
	eq(_events, [true, false] as Array[bool])


func test_gamepad_b_on_any_device_and_the_right_stick() -> void:
	for device: int in [0, 1, PAD_DEVICE]:
		hub.handle_key_event(_button(JOY_BUTTON_B, true, device))
		check(hub.look_back, "pad %d: B held" % device)
		hub.handle_key_event(_button(JOY_BUTTON_B, false, device))
		check(not hub.look_back, "pad %d: B released" % device)
	var on := t.controls.gamepad_look_back_frac()
	var off := t.controls.gamepad_look_back_release_frac()
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, on - 0.05))
	check(not hub.look_back, "below the threshold")
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, on + 0.05))
	check(hub.look_back, "pushed back past it")
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, (on + off) * 0.5))
	check(hub.look_back, "hysteresis: still back between the two shares")
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, off - 0.05))
	check(not hub.look_back, "released below the release share")
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, -1.0))
	check(not hub.look_back, "pushed forward: no")
	# B and the stick together: either keeps it.
	hub.handle_key_event(_button(JOY_BUTTON_B, true))
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, 1.0))
	hub.handle_key_event(_button(JOY_BUTTON_B, false))
	check(hub.look_back, "the stick still holds it")
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, 0.0))
	check(not hub.look_back)


func test_never_while_paused_and_released_on_pause() -> void:
	hub.handle_key_event(_key_b(true))
	check(hub.look_back)
	tree.paused = true
	hub.release_all()   # what the hub does on the pause edge
	check(not hub.look_back, "pausing lets go")
	hub.handle_key_event(_button(JOY_BUTTON_B, true))
	check(not hub.look_back, "B in the pause menu is back, not look back")
	hub.handle_key_event(_button(JOY_BUTTON_B, false))
	tree.paused = false
	eq(_events, [true, false] as Array[bool])


func test_vehicle_input_is_untouched() -> void:
	var ctl := PlayerController.new(hub)
	var a := VehicleInput.new()
	var b := VehicleInput.new()
	var st := VehicleState.new()
	_touch(IOS_GAS, hub.layout.gas_rect.get_center(), true, 0.0)
	hub.handle_key_event(_button(JOY_BUTTON_A, true))
	hub.advance(DT)
	ctl.update(DT, st, a)
	hub.handle_key_event(_button(JOY_BUTTON_A, false))
	hub.handle_key_event(_button(JOY_BUTTON_A, true))
	_touch(IOS_LOOK, hub.layout.look_rect.get_center(), true, 0.1)
	hub.handle_key_event(_key_b(true))
	hub.handle_key_event(_axis(JOY_AXIS_RIGHT_Y, 1.0))
	hub.advance(DT)
	ctl.update(DT, st, b)
	check(hub.look_back)
	eq([b.steer, b.throttle, b.brake, b.boost], [a.steer, a.throttle, a.brake, a.boost],
			"looking back changes nothing the car reads")


func test_a_menu_boost_is_dropped_when_a_countdown_starts() -> void:
	hub.handle_key_event(_button(JOY_BUTTON_A, true))   # A on the title's PLAY
	hub.handle_key_event(_button(JOY_BUTTON_A, false))
	Events.game_state_changed.emit(Game.MENU, Game.COUNTDOWN)
	check(not hub.consume_boost(), "no boost carried into the run")
	hub.handle_key_event(_button(JOY_BUTTON_A, true))
	check(hub.consume_boost(), "A boosts in the run")
	Events.game_state_changed.emit(Game.COUNTDOWN, Game.MENU)


func test_overlay_lights_the_button_and_stays_idle() -> void:
	var overlay := (load("res://src/ui/controls_overlay.tscn") as PackedScene).instantiate() as ControlsOverlay
	tree.root.add_child(overlay)
	await tree.process_frame
	await tree.process_frame
	var n := overlay.redraw_count()
	await tree.process_frame
	eq(overlay.redraw_count(), n, "idle: no redraw")
	_touch(IOS_LOOK, hub.layout.look_rect.get_center(), true, 0.0)
	await tree.process_frame
	await tree.process_frame
	eq(overlay.redraw_count(), n + 1, "held: one redraw (the button lights)")
	await tree.process_frame
	eq(overlay.redraw_count(), n + 1, "held still: no more")
	_touch(IOS_LOOK, hub.layout.look_rect.get_center(), false, 0.1)
	await tree.process_frame
	await tree.process_frame
	eq(overlay.redraw_count(), n + 2, "let go: one redraw")
	overlay.free()
