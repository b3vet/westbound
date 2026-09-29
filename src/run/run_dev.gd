class_name RunDevPanel
extends Node
## The run's dev buttons (Working rule 10: the review tools keep working at every
## milestone). The M3 drive scene's rows (src/dev/car_drive.gd), rebuilt on the
## read-only DriveControls, folded behind one DEV toggle, plus LIVES INF so the owner
## can drive endlessly.
##
## Placement: the spec's HUD owns the four corners and the top-center (score
## top-left, sun bar and chain top-center, lives + pause + camera top-right, speed
## bottom-left, boost bottom-right). The dev rows hang from the top-left, pushed down
## below the score block (the layer's offset), so they never cover a HUD readout.
##   row 0: DEV +/-, HUD (dev HUD), CAM
##   row 1: STEER, THR, MIRROR
##   row 2: CAR, RECAL, RESET (car back into a lane), RETRY (a new run now)
##   row 3: RING/WHEEL, SIZE, LIVES
##   row 4: LEG (auto or a fixed director leg), SANDBOX, DRIVE (the M3 drive scene)
## Dev scene values below are canvas px, not tuning.

const BUTTON := Vector2(124.0, 44.0)
const CAM_BUTTON := Vector2(150.0, 44.0)
## Below the HUD's score block (BANKED, total, BEST) on the 720 px canvas.
const TOP_OFFSET_PX := 150.0
const LEG_COUNT := 8

var run: Run
var controls: DriveControls
var open: bool = false

var _dev_button: Button
var _cam_button: Button
var _steer_button: Button
var _throttle_button: Button
var _mirror_button: Button
var _car_button: Button
var _visual_button: Button
var _size_button: Button
var _lives_button: Button
var _leg_button: Button


func setup(owner_run: Run) -> void:
	run = owner_run
	controls = DriveControls.new()
	controls.name = "DriveControls"
	controls.process_mode = Node.PROCESS_MODE_ALWAYS
	controls.offset = Vector2(0.0, TOP_OFFSET_PX)
	var c := DriveControls.Corner.TOP_LEFT
	_dev_button = controls.add_button(c, 0, "DEV +", DriveControls.WIDE, toggle)
	controls.add_button(c, 0, "HUD", DriveControls.WIDE, _toggle_dev_hud)
	_cam_button = controls.add_button(c, 0, "CAM", CAM_BUTTON, run.hub.request_camera_cycle)
	_steer_button = controls.add_button(c, 1, "STEER", BUTTON, _toggle_steering, true)
	_throttle_button = controls.add_button(c, 1, "THR", BUTTON, _toggle_throttle, true)
	_mirror_button = controls.add_button(c, 1, "MIRROR", BUTTON, _toggle_mirror, true)
	_car_button = controls.add_button(c, 2, "CAR", BUTTON, _next_car, true)
	controls.add_button(c, 2, "RECAL", BUTTON, run.hub.recalibrate_gyro, true)
	controls.add_button(c, 2, "RESET", BUTTON, run.dev_reset_car, true)
	controls.add_button(c, 2, "RETRY", BUTTON, run.retry, true)
	_visual_button = controls.add_button(c, 3, "RING", BUTTON, _toggle_drag_visual, true)
	_size_button = controls.add_button(c, 3, "SIZE", BUTTON, _cycle_controls_scale, true)
	_lives_button = controls.add_button(c, 3, "LIVES 2", BUTTON, _toggle_lives, true)
	_leg_button = controls.add_button(c, 4, "LEG AUTO", BUTTON, _next_leg, true)
	controls.add_button(c, 4, "SANDBOX", BUTTON, run.open_sandbox, true)
	controls.add_button(c, 4, "DRIVE", BUTTON, run.open_drive_scene, true)
	add_child(controls)
	Events.camera_mode_changed.connect(func(_m: StringName) -> void: refresh())
	Events.settings_changed.connect(func(_k: StringName) -> void: refresh())
	_apply_rows()
	refresh()


## Opens or folds the dev rows (fewer draw calls while playing).
func toggle() -> void:
	open = not open
	_apply_rows()


func refresh() -> void:
	if controls == null or run == null:
		return
	DriveControls.set_text(_cam_button, "CAM %s" % String(run.rig.mode).to_upper())
	var steering := String(run.hub.effective_steering).to_upper()
	if Settings.get_value(&"steering_mode") == &"gyro" and run.hub.effective_steering != &"gyro":
		steering = "GYRO N/A"
	DriveControls.set_text(_steer_button, "STEER %s" % steering)
	DriveControls.set_text(_throttle_button, "THR %s" % String(Settings.get_value(&"throttle_mode")).to_upper())
	DriveControls.set_text(_mirror_button, "LEFT-H" if Settings.get_value(&"left_handed") else "RIGHT-H")
	DriveControls.set_text(_car_button, String(run.car.car.id).to_upper() if run.car != null else "CAR")
	DriveControls.set_text(_visual_button, String(Settings.get_value(&"drag_visual")).to_upper())
	DriveControls.set_text(_size_button, "SIZE %.1f" % float(Settings.get_value(&"controls_scale")))
	DriveControls.set_text(_lives_button, "LIVES INF" if run.infinite_lives else "LIVES %d" % run.lives.max_lives)
	DriveControls.set_text(_leg_button, "LEG AUTO" if run.leg_override <= 0 else "LEG %d" % run.leg_override)


func _apply_rows() -> void:
	controls.set_rows_visible(DriveControls.Corner.TOP_LEFT, 1, open)
	DriveControls.set_text(_dev_button, "DEV -" if open else "DEV +")


func _toggle_dev_hud() -> void:
	var dev_hud := run.get_node_or_null(^"DevHud")
	if dev_hud != null and dev_hud.has_method(&"toggle"):
		dev_hud.call(&"toggle")


func _toggle_steering() -> void:
	var gyro: bool = Settings.get_value(&"steering_mode") != &"gyro"
	Settings.set_value(&"steering_mode", &"gyro" if gyro else &"drag")
	if gyro:
		# Web: arms the one-shot motion-permission request on the next tap (iOS Safari).
		run.hub.gyro.source.activate()
		run.hub.recalibrate_gyro()


func _toggle_throttle() -> void:
	var manual: bool = Settings.get_value(&"throttle_mode") != &"manual"
	Settings.set_value(&"throttle_mode", &"manual" if manual else &"auto")


func _toggle_mirror() -> void:
	Settings.set_value(&"left_handed", not bool(Settings.get_value(&"left_handed")))


func _toggle_drag_visual() -> void:
	var wheel: bool = Settings.get_value(&"drag_visual") != PlayerInput.WHEEL
	Settings.set_value(&"drag_visual", PlayerInput.WHEEL if wheel else PlayerInput.RING)


## Cycles the touch-control size: 0.8, 1.0, 1.2 (dev steps of the controls_scale setting).
func _cycle_controls_scale() -> void:
	var steps: Array[float] = [0.8, 1.0, 1.2]
	var current := float(Settings.get_value(&"controls_scale"))
	var next := steps[0]
	for i in steps.size():
		if is_equal_approx(steps[i], current):
			next = steps[(i + 1) % steps.size()]
	Settings.set_value(&"controls_scale", next)


func _next_car() -> void:
	run.dev_next_car()
	refresh()


func _toggle_lives() -> void:
	run.infinite_lives = not run.infinite_lives
	refresh()


func _next_leg() -> void:
	run.set_leg_override((run.leg_override + 1) % (LEG_COUNT + 1))
	refresh()
