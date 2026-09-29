class_name PlayerInput
extends Node
## The input hub: every control layout in, one set of control signals out. Spec:
## Controls (four layouts, mirroring, drag, gyro, manual throttle, keyboard and
## gamepad, settings). docs/CONTROLS.md; API in docs/CONTROLS.md → Hub.
##
## One per run. Touches (and the desktop mouse) arrive in _unhandled_input, so GUI
## buttons (pause, camera) keep their own touches: that is "the whole screen minus UI
## buttons". Keys and gamepad arrive in _input (releases are never lost to the GUI).
## Each physics tick (before the player car: PHYSICS_PRIORITY) advance() runs the
## ramps and filters and combines the sources:
##   steer    = drag or gyro (by layout) vs keyboard/gamepad: the larger magnitude
##   brake    = the strongest brake source; any brake cuts the throttle (ThrottleInput)
##   throttle = auto: 1; manual: gas pedal / W / right trigger
##   boost    = edge; consume_boost() returns it once (PlayerController, per tick)
## The layout follows Settings (steering_mode, throttle_mode, left_handed and the
## steer_* scales) until set_layout() pins one; use_settings() goes back. The look
## settings (controls_scale, drag_visual) are always followed.
##
## Manual pedals (plan D9, one thumb per side): a finger that lands on the gas column
## (gas pedal + the boost cap on top) is captured until it lifts and gives full gas
## wherever it slides, except clearly onto the brake. Sliding up past the joint line
## onto the cap, or flicking up, fires one boost; the thumb must come back down below
## the cap (and stop flicking) before it can boost again. A brake finger is captured
## the same way (proportional to its height on the pedal) and switches to gas only
## when clearly on the gas column.
##
## Per-event and per-tick code allocates nothing (packed per-finger arrays sized once).

signal camera_cycle_requested()
signal pause_requested()
signal mute_toggled()
## The high beams were switched (plan D8: a manual toggle, visual only; it never
## touches scoring or traffic). Until Events.high_beam_changed exists, listen here.
signal high_beam_changed(on: bool)

const DRAG := ControlsLayout.DRAG
const GYRO := ControlsLayout.GYRO
const AUTO := ThrottleInput.AUTO
const MANUAL := ThrottleInput.MANUAL

## The overlay and the preview find the hub through this group.
const GROUP := &"wb_player_input"
## Run before default-priority nodes in each physics tick (the player car reads us).
const PHYSICS_PRIORITY := -100
## Fingers tracked (more are ignored), plus one slot for the desktop mouse.
const MAX_TOUCHES := 10
const MOUSE_SLOT := MAX_TOUCHES
const SLOTS := MAX_TOUCHES + 1
const S_PER_USEC := 0.000001
const CM_PER_INCH := 2.54
const M_PER_CM := 0.01

## Setting keys and their fallbacks while Settings.DEFAULTS lacks them (the steer_*
## scales are requested in the WP2.2 handoff; 1.0 = the tuned spec values).
const SET_STEERING := &"steering_mode"
const SET_THROTTLE := &"throttle_mode"
const SET_LEFT_HANDED := &"left_handed"
const SET_SENSITIVITY := &"steer_sensitivity"
const SET_DEAD_ZONE := &"steer_dead_zone"
const SET_CURVE := &"steer_curve"
const SET_DRAG_VISUAL := &"drag_visual"
const SET_CONTROLS_SCALE := &"controls_scale"
## drag_visual values (plan D10): anchor ring + thumb dot, or a turning steering wheel.
const RING := &"ring"
const WHEEL := &"wheel"
const SETTING_FALLBACKS := {
	SET_STEERING: DRAG,
	SET_THROTTLE: AUTO,
	SET_LEFT_HANDED: false,
	SET_SENSITIVITY: 1.0,
	SET_DEAD_ZONE: 1.0,
	SET_CURVE: 1.0,
	SET_DRAG_VISUAL: RING,
	SET_CONTROLS_SCALE: 1.0,
}

## false: the owner calls advance(dt) itself (tests, scripted runs).
@export var auto_advance: bool = true

var controls: ControlsTuning

## Outputs, valid after advance().
var steer: float = 0.0
var throttle: float = 0.0
var brake: float = 0.0

## Sources (read by the overlay and the preview).
var drag := DragControl.new()
var gyro: GyroControl
var keys := KeysGamepad.new()
var throttle_input := ThrottleInput.new()
var layout := ControlsLayout.new()

## Requested layout, and the steering actually used (gyro falls back to drag where
## the platform has no tilt: desktop, or web without motion permission).
var steering_mode: StringName = DRAG
var throttle_mode: StringName = AUTO
var left_handed: bool = false
var effective_steering: StringName = DRAG
var follows_settings: bool = true
## Bumped whenever the layout is rebuilt (the overlay redraws its pedals).
var layout_version: int = 0

## Player settings in effect (multipliers of the tuned values).
var sensitivity: float = 1.0
var dead_zone_scale: float = 1.0
var curve_scale: float = 1.0
## Look settings: touch control size multiplier (clamped) and the drag visual.
var controls_scale: float = 1.0
var drag_visual: StringName = RING

## Manual high beams (plan D8): H, gamepad X, or toggle_high_beam() (the HUD button).
## Kept across runs and release_all() until toggled again.
var high_beam: bool = false

## Touch-derived state (overlay).
var gas_pressed: bool = false
var boost_pressed: bool = false
var pedal_brake: float = 0.0
var hold_brake: float = 0.0
var hold_pos: Vector2 = Vector2.ZERO

var _boost_pending: bool = false
var _screen_set: bool = false
var _zone: PackedInt32Array = PackedInt32Array()
var _slot_brake: PackedFloat64Array = PackedFloat64Array()
var _pos: PackedVector2Array = PackedVector2Array()
## Gas fingers: on the boost cap now (1/0), and allowed to boost again (1/0).
var _in_cap: PackedByteArray = PackedByteArray()
var _boost_armed: PackedByteArray = PackedByteArray()
var _flicks: Array[FlickMeter] = []
var _was_paused: bool = false
## Browser touch ids (large on iOS Safari) → slots 0..MAX_TOUCHES-1.
var _touch_slots := TouchSlots.new(MAX_TOUCHES)


func _init() -> void:
	gyro = GyroControl.new(_default_gravity_source())
	_zone.resize(SLOTS)
	_zone.fill(ControlsLayout.Zone.NONE)
	_slot_brake.resize(SLOTS)
	_slot_brake.fill(0.0)
	_pos.resize(SLOTS)
	_in_cap.resize(SLOTS)
	_in_cap.fill(0)
	_boost_armed.resize(SLOTS)
	_boost_armed.fill(0)
	for i in SLOTS:
		_flicks.append(FlickMeter.new())


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = PHYSICS_PRIORITY
	KeysGamepad.register_actions()
	if controls == null:
		controls = Tuning.load_default().controls
	if not _screen_set:
		_update_screen()
		get_viewport().size_changed.connect(_update_screen)
	if follows_settings:
		_read_settings()
	else:
		_apply_layout()


func _enter_tree() -> void:
	add_to_group(GROUP)
	if not Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all()


func _physics_process(delta: float) -> void:
	var paused := get_tree().paused
	if paused != _was_paused:
		_was_paused = paused
		release_all()
	if auto_advance and not paused:
		advance(delta)


func _input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_handle_keys(event)


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag \
			or event is InputEventMouseButton or event is InputEventMouseMotion:
		handle_pointer(event, float(Time.get_ticks_usec()) * S_PER_USEC)


# ---------------------------------------------------------------- API

## Edge-triggered boost request: true once per request (PlayerController, per tick).
func consume_boost() -> bool:
	var b := _boost_pending
	_boost_pending = false
	return b


## Pins a layout (the first-run chooser's live preview, tests, the input preview).
## Settings are followed again after use_settings().
func set_layout(steering: StringName, throttle_kind: StringName, mirrored: bool) -> void:
	follows_settings = false
	steering_mode = steering
	throttle_mode = throttle_kind
	left_handed = mirrored
	if is_inside_tree() and controls != null:
		_apply_layout()


## Follow Settings again (the default).
func use_settings() -> void:
	follows_settings = true
	if is_inside_tree():
		_read_settings()


## Capture the current tilt as neutral (the countdown; the pause menu's Recalibrate).
func recalibrate_gyro() -> void:
	gyro.recalibrate()


## The HUD camera button calls this (same as C / gamepad Y).
func request_camera_cycle() -> void:
	camera_cycle_requested.emit()


## Switches the high beams (H, gamepad X; the HUD's high-beam button calls this).
func toggle_high_beam() -> void:
	set_high_beam(not high_beam)


## Sets the high beams; emits high_beam_changed only on a change.
func set_high_beam(on: bool) -> void:
	if on == high_beam:
		return
	high_beam = on
	high_beam_changed.emit(on)


## Whether gyro steering can work on this platform (the settings UI hides it if not).
func is_gyro_supported() -> bool:
	return gyro.source.is_supported()


## Replace the tilt source (tests inject a fake; the preview a simulated one).
func set_gravity_source(src: GravitySource) -> void:
	gyro.source = src
	gyro.calibrated = false
	if is_inside_tree() and controls != null:
		_apply_layout()


## Screen geometry in canvas pixels: the whole viewport, its safe area, and physical
## scale. Called on resize; tests and the preview call it directly.
func configure_screen(full: Rect2, safe: Rect2, px_per_cm: float) -> void:
	_screen_set = true
	layout.full = full
	layout.safe = safe
	layout.px_per_cm = px_per_cm
	if controls != null:
		_apply_layout()


## Lifts every finger and key (focus loss, pause, layout change).
func release_all() -> void:
	drag.reset()
	keys.reset()
	gyro.reset()
	_touch_slots.clear()
	_zone.fill(ControlsLayout.Zone.NONE)
	_slot_brake.fill(0.0)
	_in_cap.fill(0)
	_boost_armed.fill(0)
	gas_pressed = false
	boost_pressed = false
	pedal_brake = 0.0
	hold_brake = 0.0
	_boost_pending = false
	steer = 0.0
	throttle = 0.0
	brake = 0.0


## One physics tick: ramps, filters, then the combined outputs.
func advance(dt: float) -> void:
	drag.advance(dt)
	keys.advance(dt)
	var touch_steer := drag.steer
	if effective_steering == GYRO:
		gyro.advance(dt)
		touch_steer = gyro.steer
	steer = touch_steer if absf(touch_steer) > absf(keys.steer) else keys.steer
	var gas := 1.0 if gas_pressed else 0.0
	gas = maxf(gas, keys.gas)
	var b := maxf(maxf(drag.brake, pedal_brake), maxf(hold_brake, keys.brake))
	throttle_input.update(gas, b)
	throttle = throttle_input.throttle
	brake = throttle_input.brake


# ---------------------------------------------------------------- Events

## Touch / mouse routing. `time_s` from any monotonic clock (tests script it).
func handle_pointer(event: InputEvent, time_s: float) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed and not t.canceled:
			var slot := _touch_slots.acquire(t.index)
			if slot != TouchSlots.FREE:
				_down(slot, t.position, time_s)
		else:
			var slot := _touch_slots.release(t.index)
			if slot != TouchSlots.FREE:
				_up(slot, time_s)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		var slot := _touch_slots.find(d.index)
		if slot != TouchSlots.FREE:
			_move(slot, d.position, time_s)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.device == InputEvent.DEVICE_ID_EMULATION or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_down(MOUSE_SLOT, mb.position, time_s)
		else:
			_up(MOUSE_SLOT, time_s)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if _zone[MOUSE_SLOT] != ControlsLayout.Zone.NONE:
			_move(MOUSE_SLOT, mm.position, time_s)


## Keys and gamepad: held state, and the edge signals.
func handle_key_event(event: InputEvent) -> void:
	_handle_keys(event)


func _handle_keys(event: InputEvent) -> void:
	var edges := keys.handle_event(event)
	if edges == 0:
		return
	if edges & KeysGamepad.EDGE_BOOST and not get_tree().paused:
		_boost_pending = true
	if edges & KeysGamepad.EDGE_CAMERA:
		camera_cycle_requested.emit()
	if edges & KeysGamepad.EDGE_PAUSE:
		pause_requested.emit()
	if edges & KeysGamepad.EDGE_MUTE:
		mute_toggled.emit()
	if edges & KeysGamepad.EDGE_HIGH_BEAM:
		toggle_high_beam()


func _down(slot: int, pos: Vector2, time_s: float) -> void:
	if _zone[slot] != ControlsLayout.Zone.NONE:
		_up(slot, time_s)
	var zone := layout.zone_at(pos)
	if zone == ControlsLayout.Zone.DRAG and drag.active:
		return  # one steering thumb; a second finger in the zone is ignored
	_zone[slot] = zone
	_pos[slot] = pos
	match zone:
		ControlsLayout.Zone.DRAG:
			drag.touch_down(slot, pos, time_s)
		ControlsLayout.Zone.HOLD:
			_flicks[slot].start(pos, time_s)
			hold_pos = pos
		ControlsLayout.Zone.GAS, ControlsLayout.Zone.BOOST:
			# The cap is part of the gas control: gas, plus a boost on landing.
			_zone[slot] = ControlsLayout.Zone.GAS
			_flicks[slot].start(pos, time_s)
			_start_gas(slot)
			_gas_moved(slot, pos, false)
		ControlsLayout.Zone.BRAKE:
			_flicks[slot].start(pos, time_s)
			_set_pedal_brake(slot, pos)
	_refresh_touch_state()


func _move(slot: int, pos: Vector2, time_s: float) -> void:
	var zone := _zone[slot]
	if zone == ControlsLayout.Zone.NONE:
		return
	_pos[slot] = pos
	match zone:
		ControlsLayout.Zone.DRAG:
			drag.touch_move(slot, pos, time_s)
			if drag.take_boost():
				_boost_pending = true
		ControlsLayout.Zone.HOLD:
			if _flicks[slot].move(pos, time_s):
				_boost_pending = true
			hold_pos = pos
			_refresh_touch_state()
		ControlsLayout.Zone.GAS, ControlsLayout.Zone.BRAKE:
			_pedal_moved(slot, pos, time_s)
			_refresh_touch_state()


## A captured pedal finger moved: switch pedals only when clearly on the other one.
func _pedal_moved(slot: int, pos: Vector2, time_s: float) -> void:
	var flicked := _flicks[slot].move(pos, time_s)
	if _zone[slot] == ControlsLayout.Zone.GAS:
		if layout.brake_takes(pos):
			_zone[slot] = ControlsLayout.Zone.BRAKE
			_in_cap[slot] = 0
		else:
			_gas_moved(slot, pos, flicked)
			return
	elif layout.gas_takes(pos):
		_zone[slot] = ControlsLayout.Zone.GAS
		_slot_brake[slot] = 0.0
		_start_gas(slot)
		_gas_moved(slot, pos, false)
		return
	_set_pedal_brake(slot, pos)


func _start_gas(slot: int) -> void:
	_in_cap[slot] = 0
	_boost_armed[slot] = 1


## Gas finger: boost on entering the cap or on an upward flick, once until re-armed
## (back below the cap by the re-arm distance, with the flick meter settled).
func _gas_moved(slot: int, pos: Vector2, flicked: bool) -> void:
	var in_cap := layout.above_gas_joint(pos.y)
	var entered := in_cap and _in_cap[slot] == 0
	if (entered or flicked) and _boost_armed[slot] == 1:
		_boost_pending = true
		_boost_armed[slot] = 0
	elif _boost_armed[slot] == 0 and _flicks[slot].is_armed() \
			and pos.y > layout.gas_rect.position.y + layout.boost_rearm_px:
		_boost_armed[slot] = 1
	_in_cap[slot] = 1 if in_cap else 0


func _set_pedal_brake(slot: int, pos: Vector2) -> void:
	_slot_brake[slot] = ThrottleInput.pedal_brake(layout.brake_up_frac(pos.y),
			controls.pedal_brake_min_frac())


func _up(slot: int, time_s: float) -> void:
	var zone := _zone[slot]
	if zone == ControlsLayout.Zone.NONE:
		return
	_zone[slot] = ControlsLayout.Zone.NONE
	_slot_brake[slot] = 0.0
	_in_cap[slot] = 0
	if zone == ControlsLayout.Zone.DRAG:
		drag.touch_up(slot, time_s)
	_refresh_touch_state()


## Gas / pedal brake / hold brake / pressed flags from the per-finger zones.
func _refresh_touch_state() -> void:
	var gas := false
	var boost := false
	var pb := 0.0
	var hb := 0.0
	for i in SLOTS:
		match _zone[i]:
			ControlsLayout.Zone.GAS:
				gas = true
				if _in_cap[i] == 1:
					boost = true
			ControlsLayout.Zone.BRAKE:
				pb = maxf(pb, _slot_brake[i])
			ControlsLayout.Zone.HOLD:
				# Touch and hold brakes; a finger that swiped up (boost) stops braking.
				if not _flicks[i].fired:
					hb = 1.0
	gas_pressed = gas
	boost_pressed = boost
	pedal_brake = pb
	hold_brake = hb


# ---------------------------------------------------------------- Layout

func _read_settings() -> void:
	steering_mode = StringName(_setting(SET_STEERING))
	throttle_mode = StringName(_setting(SET_THROTTLE))
	left_handed = bool(_setting(SET_LEFT_HANDED))
	_apply_layout()


func _on_setting_changed(key: StringName) -> void:
	if key == SET_DRAG_VISUAL:
		# Visual only: the overlay redraws, the fingers stay down.
		drag_visual = _read_drag_visual()
	elif key == SET_CONTROLS_SCALE:
		if controls != null:
			_apply_layout()
	elif follows_settings and SETTING_FALLBACKS.has(key):
		_read_settings()


func _read_drag_visual() -> StringName:
	return WHEEL if StringName(_setting(SET_DRAG_VISUAL)) == WHEEL else RING


func _setting(key: StringName) -> Variant:
	if Settings.DEFAULTS.has(key):
		return Settings.get_value(key)
	return SETTING_FALLBACKS[key]


func _apply_layout() -> void:
	release_all()
	var lo := controls.setting_scale_min_factor
	var hi := controls.setting_scale_max_factor
	sensitivity = clampf(float(_setting(SET_SENSITIVITY)), lo, hi)
	dead_zone_scale = clampf(float(_setting(SET_DEAD_ZONE)), lo, hi)
	curve_scale = clampf(float(_setting(SET_CURVE)), lo, hi)
	controls_scale = clampf(float(_setting(SET_CONTROLS_SCALE)), controls.controls_scale_min_factor,
			controls.controls_scale_max_factor)
	drag_visual = _read_drag_visual()
	var exponent := controls.response_curve_exponent * curve_scale

	effective_steering = GYRO if steering_mode == GYRO and gyro.source.is_supported() else DRAG
	throttle_input.mode = MANUAL if throttle_mode == MANUAL else AUTO
	var px_per_cm := layout.px_per_cm
	layout.build(controls, layout.full, layout.safe, px_per_cm, effective_steering,
			throttle_input.mode, left_handed, controls_scale)

	var px_per_m := px_per_cm / M_PER_CM
	drag.configure(controls, controls.drag_max_m() / sensitivity,
			controls.drag_dead_zone_frac() * dead_zone_scale, exponent, px_per_m,
			throttle_input.mode == AUTO)
	var max_angle := deg_to_rad(controls.gyro_max_angle_deg) / sensitivity
	var gyro_dz := deg_to_rad(controls.gyro_dead_zone_deg) * dead_zone_scale / max_angle
	gyro.configure(controls, max_angle, gyro_dz, exponent)
	keys.configure(controls, dead_zone_scale, exponent)
	for f in _flicks:
		f.configure(controls, px_per_m)
	if effective_steering == GYRO:
		gyro.source.activate()
	layout_version += 1


func _update_screen() -> void:
	var vp := get_viewport()
	var full := vp.get_visible_rect()
	var safe := full
	var win_size := DisplayServer.window_get_size()
	if DisplayServer.get_name() != "headless" and win_size.x > 0 and win_size.y > 0:
		var sa := DisplayServer.get_display_safe_area()
		if sa.size.x > 0 and sa.size.y > 0:
			var win_pos := DisplayServer.window_get_position()
			var scale := full.size / Vector2(win_size)
			var left := maxf(0.0, float(sa.position.x - win_pos.x)) * scale.x
			var top := maxf(0.0, float(sa.position.y - win_pos.y)) * scale.y
			var right := maxf(0.0, float(win_pos.x + win_size.x - sa.end.x)) * scale.x
			var bottom := maxf(0.0, float(win_pos.y + win_size.y - sa.end.y)) * scale.y
			safe = Rect2(full.position + Vector2(left, top),
					full.size - Vector2(left + right, top + bottom))
	layout.full = full
	layout.safe = safe
	layout.px_per_cm = canvas_px_per_cm(controls, full.size, win_size)
	_apply_layout()


## Canvas pixels per physical cm. Native mobile: the screen DPI, scaled from window
## pixels to canvas pixels. Web and desktop (DPI unknown or in CSS inches, which are
## not physical on phones): the canvas height is taken as a phone's landscape height.
static func canvas_px_per_cm(tuning: ControlsTuning, canvas_size: Vector2, win_size: Vector2i) -> float:
	if OS.has_feature("mobile") and not OS.has_feature("web") and win_size.y > 0:
		var dpi := DisplayServer.screen_get_dpi()
		if dpi > 0:
			return float(dpi) / CM_PER_INCH * canvas_size.y / float(win_size.y)
	return canvas_size.y / tuning.fallback_screen_height_cm


static func _default_gravity_source() -> GravitySource:
	if OS.has_feature("web"):
		return WebMotionSource.new()
	return GravitySource.new()
