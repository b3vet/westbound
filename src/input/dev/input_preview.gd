extends Control
## Input preview (dev scene). Spec: Controls (every layout outputs the same signals);
## plan WP2.2. Shows each source's raw and mapped values and the combined output for
## the chosen layout, with the real controls overlay on top. Runs on desktop (mouse
## as a finger, keyboard, gamepad; simulated tilt with [ and ] or the mouse wheel)
## and on phones (real touches and tilt; on the web the first tap asks for motion
## permission when gyro is chosen).
##
## The buttons (top right) switch steering, throttle and mirroring and recalibrate the
## gyro; being GUI buttons, they also show that the steering zone excludes UI buttons.
##
## snap_setup args: --steering=drag|gyro --throttle=auto|manual --left_handed=true|false
## --demo=true|false (demo: scripted fingers so the overlay shows its active state),
## --tilt_deg=<deg> (simulated tilt in the demo, default 12).

const SIM_TILT_STEP_DEG := 2.0
const SIM_TILT_MAX_DEG := 45.0
const READOUT_INTERVAL_MSEC := 100
const DEMO_TILT_DEG := 12.0

## Stand-in tilt for machines without a gravity sensor.
class SimulatedGravity:
	extends GravitySource
	var roll_deg: float = 0.0
	var pitch_deg: float = 40.0

	func read_gravity() -> Vector3:
		var r := deg_to_rad(roll_deg)
		var p := deg_to_rad(pitch_deg)
		return Vector3(sin(r), -cos(r) * cos(p), -cos(r) * sin(p)) * 9.81  # lint: allow-number g

	func is_supported() -> bool:
		return true


@onready var hub: PlayerInput = $PlayerInput
@onready var overlay: ControlsOverlay = $Overlay/ControlsOverlay
@onready var _readout: Label = $Panel/Readout
@onready var _meters: Control = $Meters
@onready var _steer_btn: Button = $Buttons/Steering
@onready var _throttle_btn: Button = $Buttons/Throttle
@onready var _mirror_btn: Button = $Buttons/Mirror
@onready var _recal_btn: Button = $Buttons/Recalibrate

var _sim: SimulatedGravity
var _boosts: int = 0
var _last_readout_msec: int = 0
var _shown_steer: float = NAN
var _shown_throttle: float = NAN
var _shown_brake: float = NAN


func _ready() -> void:
	if not hub.is_gyro_supported():
		_sim = SimulatedGravity.new()
		hub.set_gravity_source(_sim)
	hub.set_layout(hub.steering_mode, hub.throttle_mode, hub.left_handed)
	_steer_btn.pressed.connect(_on_steering)
	_throttle_btn.pressed.connect(_on_throttle)
	_mirror_btn.pressed.connect(_on_mirror)
	_recal_btn.pressed.connect(hub.recalibrate_gyro)
	hub.camera_cycle_requested.connect(_flash.bind("camera"))
	hub.pause_requested.connect(_flash.bind("pause"))
	hub.mute_toggled.connect(_flash.bind("mute"))
	_meters.draw.connect(_draw_meters)
	_refresh_buttons()


func _physics_process(_delta: float) -> void:
	# The preview plays PlayerController: it takes the boost edge each tick.
	if hub.consume_boost():
		_boosts += 1


func _process(_delta: float) -> void:
	if hub.steer != _shown_steer or hub.throttle != _shown_throttle or hub.brake != _shown_brake:
		_shown_steer = hub.steer
		_shown_throttle = hub.throttle
		_shown_brake = hub.brake
		_meters.queue_redraw()
	if Time.get_ticks_msec() - _last_readout_msec >= READOUT_INTERVAL_MSEC:
		refresh_readout()


## Rebuilds the readout text now (it refreshes on its own at 10 Hz).
func refresh_readout() -> void:
	_last_readout_msec = Time.get_ticks_msec()
	var text := _compose()
	if text != _readout.text:
		_readout.text = text


func _unhandled_input(event: InputEvent) -> void:
	if _sim == null:
		return
	var step := 0.0
	if event is InputEventKey and event.is_pressed():
		match (event as InputEventKey).keycode:
			KEY_BRACKETLEFT:
				step = -SIM_TILT_STEP_DEG
			KEY_BRACKETRIGHT:
				step = SIM_TILT_STEP_DEG
	elif event is InputEventMouseButton and event.is_pressed():
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_WHEEL_UP:
				step = -SIM_TILT_STEP_DEG
			MOUSE_BUTTON_WHEEL_DOWN:
				step = SIM_TILT_STEP_DEG
	if step != 0.0:
		_sim.roll_deg = clampf(_sim.roll_deg + step, -SIM_TILT_MAX_DEG, SIM_TILT_MAX_DEG)


func snap_setup(args: Dictionary) -> void:
	var steering := StringName(str(args.get("steering", "drag")))
	var throttle_kind := StringName(str(args.get("throttle", "auto")))
	var mirrored := bool(args.get("left_handed", false))
	hub.set_layout(steering, throttle_kind, mirrored)
	_refresh_buttons()
	if bool(args.get("demo", true)):
		_demo_fingers(float(args.get("tilt_deg", DEMO_TILT_DEG)))
	refresh_readout()


## Scripted fingers for screenshots: the active look of each layout.
func _demo_fingers(tilt_deg: float) -> void:
	var l := hub.layout
	var now := float(Time.get_ticks_usec()) * PlayerInput.S_PER_USEC
	var max_px := hub.drag.max_drag_px
	if hub.effective_steering == PlayerInput.DRAG:
		var zone := l.drag_zone
		var at := zone.position + zone.size * Vector2(0.55, 0.6)
		_finger(0, at, true, now)
		_move(0, at + Vector2(0.6, 0.15) * max_px, now + 0.5)
	else:
		if _sim != null:
			_sim.roll_deg = 0.0
			hub.recalibrate_gyro()
			_sim.roll_deg = tilt_deg
		if l.has(l.hold_zone):
			_finger(0, l.full.position + l.full.size * Vector2(0.62, 0.62), true, now)
	if l.has(l.gas_rect):
		_finger(1, l.gas_rect.get_center(), true, now)
	if l.has(l.brake_rect) and hub.effective_steering == PlayerInput.GYRO:
		_finger(2, l.brake_rect.get_center(), true, now)
		_finger(1, l.gas_rect.get_center(), false, now)


func _finger(i: int, pos: Vector2, down: bool, time_s: float) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = i
	ev.position = pos
	ev.pressed = down
	hub.handle_pointer(ev, time_s)


func _move(i: int, pos: Vector2, time_s: float) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = i
	ev.position = pos
	hub.handle_pointer(ev, time_s)


func _on_steering() -> void:
	var next := PlayerInput.GYRO if hub.steering_mode == PlayerInput.DRAG else PlayerInput.DRAG
	hub.set_layout(next, hub.throttle_mode, hub.left_handed)
	_refresh_buttons()


func _on_throttle() -> void:
	var next := PlayerInput.MANUAL if hub.throttle_mode == PlayerInput.AUTO else PlayerInput.AUTO
	hub.set_layout(hub.steering_mode, next, hub.left_handed)
	_refresh_buttons()


func _on_mirror() -> void:
	hub.set_layout(hub.steering_mode, hub.throttle_mode, not hub.left_handed)
	_refresh_buttons()


func _refresh_buttons() -> void:
	_steer_btn.text = "STEER  %s" % String(hub.steering_mode).to_upper()
	_throttle_btn.text = "THROTTLE  %s" % String(hub.throttle_mode).to_upper()
	_mirror_btn.text = "LEFT-HANDED" if hub.left_handed else "RIGHT-HANDED"


func _flash(what: String) -> void:
	print("input_preview: %s requested" % what)


func _compose() -> String:
	var l := hub.layout
	var d := hub.drag
	var g := hub.gyro
	var k := hub.keys
	var lines := PackedStringArray()
	lines.append("layout   %s + %s%s   (steering used: %s)" % [hub.steering_mode, hub.throttle_mode,
			"  mirrored" if hub.left_handed else "", hub.effective_steering])
	lines.append("screen   %dx%d  safe %d,%d %dx%d  %.1f px/cm  max_drag %.0f px" % [
			l.full.size.x, l.full.size.y, l.safe.position.x, l.safe.position.y,
			l.safe.size.x, l.safe.size.y, l.px_per_cm, d.max_drag_px])
	var off := d.offset_norm() if d.active else Vector2.ZERO
	lines.append("drag     %s  dx %+.2f  dy %+.2f  finger %.2f m/s  ->  steer %+.3f  brake %.2f" % [
			"DOWN" if d.active else "up  ", off.x, off.y,
			d.flick.velocity.length() / d.px_per_m, d.steer, d.brake])
	var perm := ""
	if g.source is WebMotionSource:
		perm = "  web motion: %s (%d events)" % [(g.source as WebMotionSource).permission_state(),
				(g.source as WebMotionSource).event_count()]
	elif _sim != null:
		perm = "  simulated: [ ] or wheel tilts"
	lines.append("gyro     g %+.1f %+.1f %+.1f  tilt %+.1f°  neutral %+.1f°  filtered %+.1f°  ->  steer %+.3f%s" % [
			g.gravity_screen.x, g.gravity_screen.y, g.gravity_screen.z,
			rad_to_deg(g.raw_angle_rad), rad_to_deg(g.neutral_rad), rad_to_deg(g.filtered_rad),
			g.steer, perm])
	lines.append("keys/pad key %+.2f  stick %+.2f  RT %.2f  LT %.2f  ->  steer %+.3f  gas %.2f  brake %.2f" % [
			k.key_steer, k.stick_x, k.trigger_gas, k.trigger_brake, k.steer, k.gas, k.brake])
	lines.append("pedals   gas %s  brake %.2f  hold %.2f  boost %s" % [
			"ON " if hub.gas_pressed else "off", hub.pedal_brake, hub.hold_brake,
			"ON" if hub.boost_pressed else "off"])
	lines.append("OUTPUT   steer %+.3f   throttle %.3f   brake %.3f   boosts %d" % [
			hub.steer, hub.throttle, hub.brake, _boosts])
	return "\n".join(lines)


func _draw_meters() -> void:
	# Steer (centre-zero), throttle and brake bars under the readout.
	var w := _meters.size.x
	var h := _meters.size.y / 3.0
	var track := Color(ControlsOverlay.COLOR_LINE, 0.35)
	var acc := overlay.accent
	for row in 3:
		_meters.draw_rect(Rect2(0.0, row * h + 2.0, w, h - 4.0), track, false, 1.0)
	var mid := w * 0.5
	_meters.draw_rect(Rect2(mid, 2.0, hub.steer * mid, h - 4.0).abs(), acc)
	_meters.draw_rect(Rect2(0.0, h + 2.0, hub.throttle * w, h - 4.0), acc)
	_meters.draw_rect(Rect2(0.0, 2.0 * h + 2.0, hub.brake * w, h - 4.0), ControlsOverlay.COLOR_HOT)
