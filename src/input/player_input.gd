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
## steer_* scales) until set_layout() pins one; use_settings() goes back.
##
## Per-event and per-tick code allocates nothing (packed per-finger arrays sized once).

signal camera_cycle_requested()
signal pause_requested()
signal mute_toggled()

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
const SETTING_FALLBACKS := {
	SET_STEERING: DRAG,
	SET_THROTTLE: AUTO,
	SET_LEFT_HANDED: false,
	SET_SENSITIVITY: 1.0,
	SET_DEAD_ZONE: 1.0,
	SET_CURVE: 1.0,
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
var _flicks: Array[FlickMeter] = []
var _was_paused: bool = false


func _init() -> void:
	gyro = GyroControl.new(_default_gravity_source())
	_zone.resize(SLOTS)
	_zone.fill(ControlsLayout.Zone.NONE)
	_slot_brake.resize(SLOTS)
	_slot_brake.fill(0.0)
	_pos.resize(SLOTS)
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
	_zone.fill(ControlsLayout.Zone.NONE)
	_slot_brake.fill(0.0)
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
		if t.index >= 0 and t.index < MAX_TOUCHES:
			if t.pressed and not t.canceled:
				_down(t.index, t.position, time_s)
			else:
				_up(t.index, time_s)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index >= 0 and d.index < MAX_TOUCHES:
			_move(d.index, d.position, time_s)
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
		ControlsLayout.Zone.GAS:
			pass
		ControlsLayout.Zone.BRAKE:
			_slot_brake[slot] = ThrottleInput.pedal_brake(layout.brake_up_frac(pos.y),
					controls.pedal_brake_min_frac())
		ControlsLayout.Zone.BOOST:
			_boost_pending = true
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
		ControlsLayout.Zone.BRAKE:
			_slot_brake[slot] = ThrottleInput.pedal_brake(layout.brake_up_frac(pos.y),
					controls.pedal_brake_min_frac())
			_refresh_touch_state()


func _up(slot: int, time_s: float) -> void:
	var zone := _zone[slot]
	if zone == ControlsLayout.Zone.NONE:
		return
	_zone[slot] = ControlsLayout.Zone.NONE
	_slot_brake[slot] = 0.0
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
			ControlsLayout.Zone.BOOST:
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
	if follows_settings and SETTING_FALLBACKS.has(key):
		_read_settings()


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
	var exponent := controls.response_curve_exponent * curve_scale

	effective_steering = GYRO if steering_mode == GYRO and gyro.source.is_supported() else DRAG
	throttle_input.mode = MANUAL if throttle_mode == MANUAL else AUTO
	var px_per_cm := layout.px_per_cm
	layout.build(controls, layout.full, layout.safe, px_per_cm, effective_steering,
			throttle_input.mode, left_handed)

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
