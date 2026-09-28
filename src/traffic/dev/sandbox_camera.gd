class_name SandboxCamera
extends Node3D
# lint: not-sim dev camera for the traffic sandbox
## Free camera for the traffic sandbox. Spec: Traffic → Traffic sandbox (debug scene)
## ("a free camera"). Three modes:
##   FOLLOW  the gameplay CameraRig (its own CAM modes); this node only makes the rig's
##           camera current and passes pointer input through to the player's controls.
##   TOP     straight down over the player, travel direction to the RIGHT of the screen
##           (a landscape phone then shows the longest stretch of road). Drag pans
##           along / across the road, pinch or wheel zooms.
##   FREE    orbit around a focus that moves with the player (offset in road space).
##           One finger / left mouse drag orbits, two fingers / right or middle mouse
##           drag pans, pinch / wheel zooms; keys WASD pan, Q / E orbit.
## In TOP and FREE the camera consumes pointer input (and WASD, Q, E), so it never
## steers the player car; switch to FOLLOW to drive by touch.
## A short tap (any mode) emits `tapped` (the sandbox selects the vehicle under it).
## The anchor is the player car's interpolated transform, so the view never jitters
## against it.

signal tapped(position: Vector2)

enum Mode { FOLLOW, TOP, FREE }
const MODE_NAMES: Array[String] = ["FOLLOW", "TOP", "FREE"]

const FOV_DEG := 50.0
const NEAR_M := 0.3
const TOP_HEIGHT_M := 80.0
const TOP_HEIGHT_MIN_M := 25.0
const TOP_HEIGHT_MAX_M := 500.0
## The player sits this share of the height behind the view center (more road ahead).
const TOP_AHEAD_FRAC := 0.55
const FREE_DIST_M := 45.0
const FREE_DIST_MIN_M := 4.0
const FREE_DIST_MAX_M := 600.0
const FREE_PITCH_DEG := -28.0
const PITCH_MIN_DEG := -89.0
const PITCH_MAX_DEG := -3.0
## Orbit: radians per pixel of drag. Pan: fraction of the view size per pixel.
const ORBIT_RAD_PER_PX := 0.006
const PAN_PER_PX := 0.0016
const ZOOM_STEP := 1.12
const KEY_PAN_FRAC_PER_S := 0.8
const KEY_ORBIT_RAD_PER_S := 1.4
const TAP_MAX_S := 0.3
const TAP_MAX_PX := 14.0
const FAR_MARGIN_M := 60.0
const USEC_PER_S := 1000000.0

var mode: Mode = Mode.FOLLOW
var rig: CameraRig
var road: RoadPath
## The player car (anchor) and its state (road-space frame).
var target: Node3D
var target_state: VehicleState
## View distance for the far plane (fog end); the sandbox keeps it current.
var view_distance_m: float = 700.0

var top_height_m: float = TOP_HEIGHT_M
## Focus offset in road space relative to the anchor (m along the road, m across).
var pan_s_m: float = 0.0
var pan_d_m: float = 0.0
var orbit_yaw: float = 0.0
var orbit_pitch: float = deg_to_rad(FREE_PITCH_DEG)
var orbit_dist_m: float = FREE_DIST_M

var _cam: Camera3D
var _smp := RoadSample.new()
# Touches keyed by the raw event index. Never index arrays with it: the web export
# passes the browser's Touch.identifier, which iOS Safari makes a large arbitrary
# number (M2 playtest).
var _touches: Dictionary = {}          ## index -> Vector2
var _press_pos: Dictionary = {}        ## index -> Vector2 (tap detection)
var _press_usec: Dictionary = {}       ## index -> int
var _mouse_press_pos := Vector2.ZERO
var _mouse_press_usec: int = -1
var _pinch_dist: float = 0.0
var _mouse_orbit: bool = false
var _mouse_pan: bool = false


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_cam = Camera3D.new()
	_cam.name = "Camera3D"
	_cam.fov = FOV_DEG
	_cam.near = NEAR_M
	add_child(_cam)


func camera() -> Camera3D:
	return _cam


## The camera that renders now.
func current_camera() -> Camera3D:
	return rig.camera() if mode == Mode.FOLLOW and rig != null else _cam


func set_mode(m: Mode) -> void:
	mode = m
	if mode == Mode.FOLLOW:
		if rig != null:
			rig.camera().make_current()
	else:
		_cam.make_current()
		_update_pose()
	_touches.clear()
	_mouse_orbit = false
	_mouse_pan = false


func cycle_mode() -> void:
	set_mode(((mode + 1) % MODE_NAMES.size()) as Mode)


## Back to the preset framing of the current mode.
func reset_view() -> void:
	top_height_m = TOP_HEIGHT_M
	pan_s_m = 0.0
	pan_d_m = 0.0
	orbit_yaw = 0.0
	orbit_pitch = deg_to_rad(FREE_PITCH_DEG)
	orbit_dist_m = FREE_DIST_M


func _process(delta: float) -> void:
	if mode == Mode.FOLLOW:
		return
	if mode == Mode.FREE:
		var pan := Vector2.ZERO
		if Input.is_physical_key_pressed(KEY_W):
			pan.y += 1.0
		if Input.is_physical_key_pressed(KEY_S):
			pan.y -= 1.0
		if Input.is_physical_key_pressed(KEY_D):
			pan.x += 1.0
		if Input.is_physical_key_pressed(KEY_A):
			pan.x -= 1.0
		if pan != Vector2.ZERO:
			var k := orbit_dist_m * KEY_PAN_FRAC_PER_S * delta
			var c := cos(orbit_yaw)
			var s := sin(orbit_yaw)
			pan_s_m += (pan.y * c - pan.x * s) * k
			pan_d_m += (pan.y * s + pan.x * c) * k
		if Input.is_physical_key_pressed(KEY_Q):
			orbit_yaw -= KEY_ORBIT_RAD_PER_S * delta
		if Input.is_physical_key_pressed(KEY_E):
			orbit_yaw += KEY_ORBIT_RAD_PER_S * delta
	_update_pose()


func _update_pose() -> void:
	if target == null or target_state == null or road == null or _cam == null:
		return
	var anchor := target.get_global_transform_interpolated().origin
	road.sample_into(target_state.s, _smp)
	var fwd := Vector3(_smp.tangent.x, 0.0, _smp.tangent.z).normalized()
	var right := Vector3(_smp.right.x, 0.0, _smp.right.z).normalized()
	if mode == Mode.TOP:
		var focus := anchor + fwd * (pan_s_m + top_height_m * TOP_AHEAD_FRAC) + right * pan_d_m
		# Camera x = travel direction (screen right), y = the road's left (screen up).
		var bx := fwd
		var by := -right
		global_transform = Transform3D(Basis(bx, by, bx.cross(by)), focus + Vector3.UP * top_height_m)
		_cam.far = top_height_m + view_distance_m
	else:
		var focus := anchor + fwd * pan_s_m + right * pan_d_m
		# Direction from the focus to the eye: behind the car, rotated by the orbit.
		var back := -fwd.rotated(Vector3.UP, -orbit_yaw)
		var eye_dir := (back * cos(orbit_pitch) - Vector3.UP * sin(orbit_pitch)).normalized()
		var eye := focus + eye_dir * orbit_dist_m
		global_transform = Transform3D(Basis.IDENTITY, eye).looking_at(focus, Vector3.UP)
		_cam.far = orbit_dist_m + view_distance_m + FAR_MARGIN_M


# ---------------------------------------------------------------- Input

func _input(event: InputEvent) -> void:
	# In FREE mode WASD / Q / E move the camera, not the car (PlayerInput reads keys in
	# _input; this node sits after it in the tree, so it sees them first).
	if mode != Mode.FREE or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	match k.physical_keycode:
		KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E:
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
	else:
		return
	if mode != Mode.FOLLOW:
		get_viewport().set_input_as_handled()


func _on_touch(t: InputEventScreenTouch) -> void:
	if t.pressed and not t.canceled:
		_touches[t.index] = t.position
		_press_pos[t.index] = t.position
		_press_usec[t.index] = Time.get_ticks_usec()
		_pinch_dist = _two_finger_dist()
		return
	_touches.erase(t.index)
	_pinch_dist = _two_finger_dist()
	if _press_pos.has(t.index):
		var held := float(Time.get_ticks_usec() - int(_press_usec[t.index])) / USEC_PER_S
		var moved := (t.position - (_press_pos[t.index] as Vector2)).length()
		_press_pos.erase(t.index)
		_press_usec.erase(t.index)
		if held <= TAP_MAX_S and moved <= TAP_MAX_PX and _touches.is_empty():
			tapped.emit(t.position)


func _on_drag(e: InputEventScreenDrag) -> void:
	if not _touches.has(e.index):
		return
	_touches[e.index] = e.position
	if mode == Mode.FOLLOW:
		return
	if _touches.size() >= 2:
		var dist := _two_finger_dist()
		if _pinch_dist > 0.0 and dist > 0.0:
			_zoom(_pinch_dist / dist)
		_pinch_dist = dist
		_pan(e.relative / float(_touches.size()))
	elif mode == Mode.FREE:
		_orbit(e.relative)
	else:
		_pan(e.relative)


func _on_mouse_button(mb: InputEventMouseButton) -> void:
	if mb.device == InputEvent.DEVICE_ID_EMULATION:
		return
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed and mode != Mode.FOLLOW:
				_zoom(1.0 / ZOOM_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed and mode != Mode.FOLLOW:
				_zoom(ZOOM_STEP)
		MOUSE_BUTTON_LEFT:
			_mouse_orbit = mb.pressed
			if mb.pressed:
				_mouse_press_pos = mb.position
				_mouse_press_usec = Time.get_ticks_usec()
			elif _mouse_press_usec >= 0:
				var held := float(Time.get_ticks_usec() - _mouse_press_usec) / USEC_PER_S
				var moved := (mb.position - _mouse_press_pos).length()
				_mouse_press_usec = -1
				if held <= TAP_MAX_S and moved <= TAP_MAX_PX:
					tapped.emit(mb.position)
		MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
			_mouse_pan = mb.pressed


func _on_mouse_motion(mm: InputEventMouseMotion) -> void:
	if mm.device == InputEvent.DEVICE_ID_EMULATION or mode == Mode.FOLLOW:
		return
	if _mouse_pan or (_mouse_orbit and mode == Mode.TOP):
		_pan(mm.relative)
	elif _mouse_orbit:
		_orbit(mm.relative)


func _orbit(rel: Vector2) -> void:
	orbit_yaw += rel.x * ORBIT_RAD_PER_PX
	orbit_pitch = clampf(orbit_pitch - rel.y * ORBIT_RAD_PER_PX, deg_to_rad(PITCH_MIN_DEG), deg_to_rad(PITCH_MAX_DEG))


## Pixels -> road-space offset (screen right = +s in TOP; along the view in FREE).
func _pan(rel: Vector2) -> void:
	if mode == Mode.TOP:
		var k := top_height_m * PAN_PER_PX
		pan_s_m -= rel.x * k
		pan_d_m -= rel.y * k
	else:
		var k := orbit_dist_m * PAN_PER_PX
		var c := cos(orbit_yaw)
		var s := sin(orbit_yaw)
		pan_s_m += (rel.y * c + rel.x * s) * k
		pan_d_m += (rel.y * s - rel.x * c) * k


func _zoom(factor: float) -> void:
	if mode == Mode.TOP:
		top_height_m = clampf(top_height_m * factor, TOP_HEIGHT_MIN_M, TOP_HEIGHT_MAX_M)
	else:
		orbit_dist_m = clampf(orbit_dist_m * factor, FREE_DIST_MIN_M, FREE_DIST_MAX_M)


func _two_finger_dist() -> float:
	if _touches.size() < 2:
		return 0.0
	var pts: Array = _touches.values()
	return ((pts[0] as Vector2) - (pts[1] as Vector2)).length()
