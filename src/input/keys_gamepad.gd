class_name KeysGamepad
extends RefCounted
## Keyboard and gamepad (web and desktop testing). Spec: Controls → Keyboard and
## gamepad. docs/CONTROLS.md → Keyboard and gamepad.
##
## Keyboard: A/D or ←/→ steer with a 0.15 s ramp (0 → full, and back to 0 on
## release), W/↑ gas (manual mode), S/↓ brake, Shift boost, C camera, P or Esc pause,
## M mute. Gamepad: left stick steers (dead zone + the shared response curve),
## right trigger gas, left trigger brake (both analog), A boost, Y camera (Start
## pauses: not in spec). H or gamepad X toggles the high beams (plan D8; not in spec).
## Look back (owner request, 2026-10-03): hold B, gamepad B, or push the right stick down
## (back) past gamepad_look_back_stick_pct (released below gamepad_look_back_release_pct).
##
## Gamepad bindings match every device (InputMap's all-devices id): a browser numbers its
## pads by Gamepad.index, which is not always 0 (a second pad, a reconnect, another HID
## game device on the Mac), and an event from pad 1 never matched a device-0 binding.
##
## The actions are registered at runtime (register_actions(), idempotent) so the
## project file needs no [input] section; an action already defined there wins. The
## stick and triggers are read by axis, not through actions, to keep them analog.
##
## Event-driven: handle_event() tracks what is held (so it works with events pushed
## by tests as well as real ones) and returns the edges it saw. Allocation-free.

const STEER_LEFT := &"wb_steer_left"
const STEER_RIGHT := &"wb_steer_right"
const GAS := &"wb_gas"
const BRAKE := &"wb_brake"
const BOOST := &"wb_boost"
const CAMERA := &"wb_camera"
const PAUSE := &"wb_pause"
const MUTE := &"wb_mute"
const HIGH_BEAM := &"wb_high_beam"
const LOOK_BACK := &"wb_look_back"
## InputMap device id that matches every device (InputMap.ALL_DEVICES in the engine).
const ALL_DEVICES := -1

## Edge bits returned by handle_event().
const EDGE_BOOST := 1
const EDGE_CAMERA := 1 << 1
const EDGE_PAUSE := 1 << 2
const EDGE_MUTE := 1 << 3
const EDGE_HIGH_BEAM := 1 << 4

## Held-key counters (two keys can drive one action).
enum Held { LEFT, RIGHT, GAS, BRAKE, LOOK, COUNT }

var ramp_s: float = 0.0
var stick_dead_zone: float = 0.0
var trigger_dead_zone: float = 0.0
var exponent: float = 1.0
var look_stick_on: float = 1.0
var look_stick_off: float = 1.0

## Outputs.
var steer: float = 0.0
var gas: float = 0.0
var brake: float = 0.0
## Look back held (B, gamepad B, or the right stick pushed back). Updated per event.
var look_back: bool = false

## Raw state (the preview shows it).
var key_steer: float = 0.0
var stick_x: float = 0.0
var trigger_gas: float = 0.0
var trigger_brake: float = 0.0
var right_stick_y: float = 0.0
var _stick_look: bool = false

var _held: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	_held.resize(Held.COUNT)
	_held.fill(0)


func configure(tuning: ControlsTuning, dead_zone_scale: float, curve_exponent: float) -> void:
	ramp_s = tuning.keyboard_steer_ramp_s
	stick_dead_zone = clampf(tuning.gamepad_dead_zone_frac() * dead_zone_scale, 0.0, 1.0)
	trigger_dead_zone = tuning.gamepad_dead_zone_frac()
	exponent = curve_exponent
	look_stick_on = tuning.gamepad_look_back_frac()
	look_stick_off = minf(tuning.gamepad_look_back_release_frac(), look_stick_on)


func reset() -> void:
	_held.fill(0)
	key_steer = 0.0
	stick_x = 0.0
	trigger_gas = 0.0
	trigger_brake = 0.0
	right_stick_y = 0.0
	_stick_look = false
	look_back = false
	steer = 0.0
	gas = 0.0
	brake = 0.0


## Registers the wb_* actions that are missing from the InputMap. Safe to call often.
static func register_actions() -> void:
	_add(STEER_LEFT, [_phys(KEY_A), _key(KEY_LEFT)])
	_add(STEER_RIGHT, [_phys(KEY_D), _key(KEY_RIGHT)])
	_add(GAS, [_phys(KEY_W), _key(KEY_UP)])
	_add(BRAKE, [_phys(KEY_S), _key(KEY_DOWN)])
	_add(BOOST, [_key(KEY_SHIFT), _joy(JOY_BUTTON_A)])
	_add(CAMERA, [_key(KEY_C), _joy(JOY_BUTTON_Y)])
	_add(PAUSE, [_key(KEY_P), _key(KEY_ESCAPE), _joy(JOY_BUTTON_START)])
	_add(MUTE, [_key(KEY_M)])
	_add(HIGH_BEAM, [_phys(KEY_H), _joy(JOY_BUTTON_X)])
	_add(LOOK_BACK, [_phys(KEY_B), _joy(JOY_BUTTON_B)])
	# Older registrations (and project-defined actions) may bind a pad button to device 0
	# only: widen every wb_* joypad binding to all devices.
	for a: StringName in [BOOST, CAMERA, PAUSE, HIGH_BEAM, LOOK_BACK]:
		_widen_joy(a)
	PadNav.register_actions()


## Feeds one event; returns the EDGE_* bits it triggered (0 if none).
func handle_event(event: InputEvent) -> int:
	if event is InputEventJoypadMotion:
		_handle_axis(event as InputEventJoypadMotion)
		_update_look_back()
		return 0
	if not (event is InputEventKey or event is InputEventJoypadButton):
		return 0
	_track(event, STEER_LEFT, Held.LEFT)
	_track(event, STEER_RIGHT, Held.RIGHT)
	_track(event, GAS, Held.GAS)
	_track(event, BRAKE, Held.BRAKE)
	_track(event, LOOK_BACK, Held.LOOK)
	_update_look_back()
	var edges := 0
	if event.is_action_pressed(BOOST):
		edges |= EDGE_BOOST
	if event.is_action_pressed(CAMERA):
		edges |= EDGE_CAMERA
	if event.is_action_pressed(PAUSE):
		edges |= EDGE_PAUSE
	if event.is_action_pressed(MUTE):
		edges |= EDGE_MUTE
	if event.is_action_pressed(HIGH_BEAM):
		edges |= EDGE_HIGH_BEAM
	return edges


## Per tick: the keyboard ramp, then the combined outputs.
func advance(dt: float) -> void:
	var target := 0.0
	if _held[Held.RIGHT] > 0:
		target += 1.0
	if _held[Held.LEFT] > 0:
		target -= 1.0
	if ramp_s > 0.0:
		key_steer = move_toward(key_steer, target, dt / ramp_s)
	else:
		key_steer = target
	var stick := SteeringInput.curve(stick_x, stick_dead_zone, exponent)
	steer = stick if absf(stick) > absf(key_steer) else key_steer
	gas = maxf(1.0 if _held[Held.GAS] > 0 else 0.0, _trigger(trigger_gas))
	brake = maxf(1.0 if _held[Held.BRAKE] > 0 else 0.0, _trigger(trigger_brake))


func _track(event: InputEvent, action: StringName, slot: Held) -> void:
	if not event.is_action(action):
		return
	if event.is_echo():
		return
	if event.is_pressed():
		_held[slot] += 1
	else:
		_held[slot] = maxi(_held[slot] - 1, 0)


func _handle_axis(ev: InputEventJoypadMotion) -> void:
	match ev.axis:
		JOY_AXIS_LEFT_X:
			stick_x = ev.axis_value
		JOY_AXIS_TRIGGER_RIGHT:
			trigger_gas = ev.axis_value
		JOY_AXIS_TRIGGER_LEFT:
			trigger_brake = ev.axis_value
		JOY_AXIS_RIGHT_Y:
			right_stick_y = ev.axis_value


## Held key or button, or the right stick back (+y is down) with hysteresis.
func _update_look_back() -> void:
	if _stick_look:
		_stick_look = right_stick_y > look_stick_off
	else:
		_stick_look = right_stick_y >= look_stick_on
	look_back = _held[Held.LOOK] > 0 or _stick_look


func _trigger(v: float) -> float:
	if v <= trigger_dead_zone:
		return 0.0
	return clampf((v - trigger_dead_zone) / (1.0 - trigger_dead_zone), 0.0, 1.0)


static func _add(action: StringName, events: Array[InputEvent]) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for ev in events:
		InputMap.action_add_event(action, ev)


## Every joypad binding of `action` matches all devices.
static func _widen_joy(action: StringName) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if (ev is InputEventJoypadButton or ev is InputEventJoypadMotion) and ev.device != ALL_DEVICES:
			InputMap.action_erase_event(action, ev)
			ev.device = ALL_DEVICES
			InputMap.action_add_event(action, ev)


static func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	return ev


## Letter keys by position (WASD stays WASD on AZERTY and the like).
static func _phys(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	return ev


static func _joy(button: JoyButton) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	ev.device = ALL_DEVICES
	return ev
