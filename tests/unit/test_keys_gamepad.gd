extends WBTest
## Keyboard and gamepad. Spec: Controls → Keyboard and gamepad, and Tests
## ("Keyboard: the steering ramp reaches full input in 0.15 s").

const DT := 1.0 / 120.0

var c: ControlsTuning
var k: KeysGamepad


func before_all() -> void:
	c = Tuning.load_default().controls
	KeysGamepad.register_actions()


func before_each() -> void:
	k = KeysGamepad.new()
	k.configure(c, 1.0, c.response_curve_exponent)


static func key(code: Key, pressed: bool, physical: bool = false, echo: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	if physical:
		ev.physical_keycode = code
	else:
		ev.keycode = code
	ev.pressed = pressed
	ev.echo = echo
	return ev


static func button(b: JoyButton, pressed: bool) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = b
	ev.pressed = pressed
	return ev


static func axis(a: JoyAxis, value: float) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.axis = a
	ev.axis_value = value
	return ev


func _ticks(n: int) -> void:
	for i in n:
		k.advance(DT)


func test_actions_registered_once() -> void:
	for a: StringName in [KeysGamepad.STEER_LEFT, KeysGamepad.STEER_RIGHT, KeysGamepad.GAS,
			KeysGamepad.BRAKE, KeysGamepad.BOOST, KeysGamepad.CAMERA, KeysGamepad.PAUSE,
			KeysGamepad.MUTE]:
		check(InputMap.has_action(a), a)
	var n := InputMap.action_get_events(KeysGamepad.PAUSE).size()
	KeysGamepad.register_actions()
	eq(InputMap.action_get_events(KeysGamepad.PAUSE).size(), n, "idempotent")
	eq(n, 3, "P, Esc, gamepad Start")


func test_ramp_reaches_full_in_015s() -> void:
	near(c.keyboard_steer_ramp_s, 0.15, 1e-12)
	k.handle_event(key(KEY_D, true, true))
	_ticks(9)
	near(k.steer, 0.5, 1e-9, "halfway at 75 ms")
	_ticks(8)
	lt(k.steer, 1.0, "not yet full at 17 ticks (142 ms)")
	_ticks(1)
	near(k.steer, 1.0, 1e-9, "full at 18 ticks = 0.15 s")
	_ticks(1)
	eq(k.steer, 1.0, "held at full")
	k.handle_event(key(KEY_D, false, true))
	_ticks(18)
	near(k.steer, 0.0, 1e-9, "back to 0 in 0.15 s")


func test_left_arrow_and_a_share_the_action() -> void:
	k.handle_event(key(KEY_LEFT, true))
	k.handle_event(key(KEY_A, true, true))
	k.handle_event(key(KEY_LEFT, false))
	_ticks(30)
	eq(k.steer, -1.0, "A still held after Left is released")
	k.handle_event(key(KEY_A, false, true))
	_ticks(30)
	eq(k.steer, 0.0)


func test_echo_does_not_double_count() -> void:
	k.handle_event(key(KEY_RIGHT, true))
	k.handle_event(key(KEY_RIGHT, true, false, true))
	k.handle_event(key(KEY_RIGHT, true, false, true))
	k.handle_event(key(KEY_RIGHT, false))
	_ticks(30)
	eq(k.steer, 0.0, "one release lifts it despite echoes")


func test_gas_and_brake_keys() -> void:
	k.handle_event(key(KEY_W, true, true))
	k.handle_event(key(KEY_DOWN, true))
	_ticks(1)
	eq(k.gas, 1.0, "W")
	eq(k.brake, 1.0, "Down")
	k.handle_event(key(KEY_W, false, true))
	k.handle_event(key(KEY_DOWN, false))
	k.handle_event(key(KEY_UP, true))
	k.handle_event(key(KEY_S, true, true))
	_ticks(1)
	eq(k.gas, 1.0, "Up")
	eq(k.brake, 1.0, "S")


func test_edges() -> void:
	eq(k.handle_event(key(KEY_SHIFT, true)), KeysGamepad.EDGE_BOOST, "Shift")
	eq(k.handle_event(key(KEY_SHIFT, true, false, true)), 0, "echo is not an edge")
	eq(k.handle_event(key(KEY_SHIFT, false)), 0, "release is not an edge")
	eq(k.handle_event(key(KEY_C, true)), KeysGamepad.EDGE_CAMERA, "C")
	eq(k.handle_event(key(KEY_P, true)), KeysGamepad.EDGE_PAUSE, "P")
	eq(k.handle_event(key(KEY_ESCAPE, true)), KeysGamepad.EDGE_PAUSE, "Esc")
	eq(k.handle_event(key(KEY_M, true)), KeysGamepad.EDGE_MUTE, "M")
	eq(k.handle_event(button(JOY_BUTTON_A, true)), KeysGamepad.EDGE_BOOST, "pad A")
	eq(k.handle_event(button(JOY_BUTTON_Y, true)), KeysGamepad.EDGE_CAMERA, "pad Y")
	eq(k.handle_event(button(JOY_BUTTON_START, true)), KeysGamepad.EDGE_PAUSE, "pad Start")


func test_stick_uses_dead_zone_and_curve() -> void:
	var dz := c.gamepad_dead_zone_frac()
	var e := c.response_curve_exponent
	k.handle_event(axis(JOY_AXIS_LEFT_X, dz * 0.9))
	_ticks(1)
	eq(k.steer, 0.0, "rest noise")
	k.handle_event(axis(JOY_AXIS_LEFT_X, 1.0))
	_ticks(1)
	eq(k.steer, 1.0, "full right at once (no ramp on the stick)")
	k.handle_event(axis(JOY_AXIS_LEFT_X, -0.6))
	_ticks(1)
	near(k.steer, SteeringInput.curve(-0.6, dz, e), 1e-6, "shared curve")


func test_larger_of_stick_and_keys_wins() -> void:
	k.handle_event(axis(JOY_AXIS_LEFT_X, -0.5))
	k.handle_event(key(KEY_RIGHT, true))
	_ticks(30)
	eq(k.steer, 1.0, "full key beats half stick")
	k.handle_event(key(KEY_RIGHT, false))
	_ticks(30)
	lt(k.steer, 0.0, "stick again once the key ramps out")


func test_triggers_are_analog() -> void:
	var dz := c.gamepad_dead_zone_frac()
	k.handle_event(axis(JOY_AXIS_TRIGGER_RIGHT, 1.0))
	k.handle_event(axis(JOY_AXIS_TRIGGER_LEFT, 0.5))
	_ticks(1)
	eq(k.gas, 1.0, "RT full")
	near(k.brake, (0.5 - dz) / (1.0 - dz), 1e-6, "LT half")
	k.handle_event(axis(JOY_AXIS_TRIGGER_LEFT, dz * 0.5))
	_ticks(1)
	eq(k.brake, 0.0, "trigger rest noise")
