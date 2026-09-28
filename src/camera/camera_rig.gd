class_name CameraRig
extends Node3D
## Gameplay camera rig. Spec: Cameras (chase, far chase, hood, overhead; spring follow,
## speed response, look-ahead, roll and shake, reduced motion, cycling, glare rule);
## Audio, haptics and game feel (shake on hits, FOV punch on boost); Accessibility ->
## Reduced motion; Performance budget (far plane just past the fog end).
##
## View-only: it reads the target node and its VehicleState and never writes gameplay
## state, so camera choice cannot affect scoring. Every number is in CameraTuning
## (data/tuning/camera.tres); shake and punch strengths for hits, close passes and boost
## come from FeelTuning.
##
## Structure: this node (top-level) carries the spring-followed pose; the Camera3D child
## carries only the shake offset. FOV = speed FOV + mode offset + punch.
##
## Update in _physics_process, at the fixed physics tick, after the car (priority): the
## springs then step with a constant dt (exact closed form, see DampedSpring) and read
## the car's physics-tick transform, and Godot's physics interpolation interpolates the
## rig with the same fraction as the car. Car and camera are therefore always sampled
## at the same instant, so the car never jitters against the camera at 60 fps render /
## 120 Hz physics (or 30 fps battery saver). Updating in _process from interpolated
## transforms would also work, but would step the springs at a variable frame dt.
##
## Follow model:
##   - heading: a spring on the target's world heading (yaw), wrapped;
##   - position: a spring on the mode's offset from the target, in the smoothed heading
##     frame, scaled by the speed pull-back. The target's forward and vertical velocity is
##     fed forward, so there is no lag at constant speed or on grades; lateral motion
##     (lane changes) and accelerations lag, which gives the spring feel;
##   - look point: ahead of the car along the smoothed heading, shifted up to 1.2 m toward
##     the road-relative lateral velocity (the lane you are moving into);
##   - roll: up to 1.5 deg into the lateral acceleration (right turn = right side down);
##   - hood: rigid (0 Hz springs) at the model's Markers/cam_hood when it has one.
## Reduced motion (Settings `reduced_motion`) zeroes shake, roll and the FOV punch.

## Runs after the player car's physics tick (default priority 0).
const PHYSICS_PRIORITY := 100
## Shake noise: per channel (offset x, offset y, pitch, yaw, roll) two sines at
## incommensurate multiples of shake_frequency_hz. Shape constants, not tuning.
const NOISE_RATE_A: Array[float] = [1.0, 1.13, 0.87, 1.29, 0.79]
const NOISE_RATE_B: Array[float] = [2.31, 1.97, 2.63, 2.11, 1.83]
const NOISE_PHASE: Array[float] = [0.0, 1.7, 3.1, 4.4, 5.3]
const NOISE_MIX := 0.65  # lint: allow-number share of the first sine in the shake noise
const CH_X := 0
const CH_Y := 1
const CH_PITCH := 2
const CH_YAW := 3
const CH_ROLL := 4
## |view.y| above this counts as looking straight up or down (looking_at needs another up).
const STRAIGHT_DOWN_COS := 0.999  # lint: allow-number numerical guard, about 2.5 deg from vertical

## Camera tuning; null -> Tuning.load_default().camera on ready.
@export var tuning: CameraTuning
## Shake and punch strengths for hits, close passes and boost; null -> default.
@export var feel: FeelTuning

## Current mode (one of tuning.modes).
var mode: StringName:
	get:
		return StringName(tuning.modes[_mode_i]) if tuning != null else &""

var _cam: Camera3D
var _target: Node3D
var _state: VehicleState
var _top_speed_mps: float = 0.0
var _marker: Node3D
var _mode_i: int = 0
var _reduced_motion: bool = false

var _pos := DampedSpring.new()
var _heading := DampedSpring.new()
var _look_lat := DampedSpring.new()
var _roll := DampedSpring.new()
var _prev_anchor := Vector3.ZERO
var _time_s: float = 0.0

var _shake_strength: float = 0.0
var _shake_duration_s: float = 0.0
var _shake_t: float = 0.0
var _punch_deg: float = 0.0
var _punch_duration_s: float = 0.0
var _punch_t: float = 0.0

var _roll_out: float = 0.0
var _fov_out: float = 0.0


func _ready() -> void:
	if tuning == null:
		tuning = Tuning.load_default().camera
	if feel == null:
		feel = Tuning.load_default().feel
	var err := tuning.mode_arrays_error()
	assert(err.is_empty(), "CameraTuning: %s" % err)
	top_level = true
	process_physics_priority = PHYSICS_PRIORITY
	_cam = get_node_or_null(^"Camera3D") as Camera3D
	if _cam == null:
		_cam = Camera3D.new()
		_cam.name = "Camera3D"
		add_child(_cam)
	_cam.near = tuning.near_plane_m
	_cam.fov = tuning.fov_min_deg
	_fov_out = tuning.fov_min_deg
	_look_lat.configure(tuning.look_ahead_hz, tuning.look_ahead_damping_ratio)
	_roll.configure(tuning.roll_hz, tuning.roll_damping_ratio)
	_reduced_motion = bool(Settings.get_value(&"reduced_motion"))
	_apply_mode_index(_restored_mode_index())
	_apply_far_plane()

	Events.settings_changed.connect(_on_settings_changed)
	Events.origin_shifted.connect(_on_origin_shifted)
	Events.quality_changed.connect(_on_quality_changed)
	Events.governor_changed.connect(_on_governor_changed)
	Events.camera_shake_requested.connect(shake)
	Events.boost_started.connect(_on_boost_started)
	Events.hit.connect(_on_hit)
	Events.scored.connect(_on_scored)


func _physics_process(delta: float) -> void:
	advance(delta)


# ---------------------------------------------------------------- API

## target: the player car node (its global_transform is the car pose). state: read for
## speed (FOV, pull-back), lateral velocity (look-ahead) and lateral acceleration (roll).
## top_speed_mps: the speed where the FOV reaches its maximum. Snaps to the target.
func set_target(target: Node3D, state: VehicleState, top_speed_mps: float) -> void:
	_target = target
	_state = state
	_top_speed_mps = top_speed_mps
	_resolve_marker()
	snap_to_target()


## Switches mode (&"chase", &"far", &"hood", &"overhead", ...: CameraTuning.modes) and
## snaps. Does not save the choice (cycle_mode does).
func set_mode(new_mode: StringName) -> void:
	var i := tuning.mode_index(new_mode)
	if i < 0:
		push_warning("CameraRig: unknown mode %s" % new_mode)
		return
	if i == _mode_i and _target != null:
		return
	_apply_mode_index(i)


## Next mode in CameraTuning.modes (wrapping); saves the choice and emits
## Events.camera_mode_changed.
func cycle_mode() -> void:
	var i := (_mode_i + 1) % tuning.modes.size()
	_apply_mode_index(i)
	Settings.set_value(&"camera_mode", mode)
	Events.camera_mode_changed.emit(mode)


## Shake with a normalized strength (1 = a hit) that fades over duration_s. A weaker
## request never cuts a stronger shake short. Silent with reduced motion.
func shake(strength: float, duration_s: float) -> void:
	if strength <= 0.0 or duration_s <= 0.0:
		return
	if strength >= shake_amplitude():
		_shake_strength = strength
		_shake_duration_s = duration_s
		_shake_t = 0.0


## Widens the FOV by amount_deg and eases back over duration_s. Off with reduced motion.
func fov_punch(amount_deg: float, duration_s: float) -> void:
	if duration_s <= 0.0:
		return
	_punch_deg = amount_deg
	_punch_duration_s = duration_s
	_punch_t = 0.0


## Places everything at its goal with no spring lag (spawn, mode change, retry).
func snap_to_target() -> void:
	if not _has_target():
		return
	_update(0.0, true)
	reset_physics_interpolation()
	_cam.reset_physics_interpolation()


func camera() -> Camera3D:
	return _cam


## One follow step (called from _physics_process; tests call it directly).
func advance(dt: float) -> void:
	if not _has_target():
		return
	_time_s += dt
	_shake_t += dt
	_punch_t += dt
	_update(dt, false)


# ---------------------------------------------------------------- Read-outs

## Current shake amplitude (normalized strength); 0 with reduced motion.
func shake_amplitude() -> float:
	if _reduced_motion or _shake_t >= _shake_duration_s:
		return 0.0
	var k := 1.0 - _shake_t / _shake_duration_s
	return _shake_strength * k * k


## Current FOV punch (deg); 0 with reduced motion.
func punch_deg() -> float:
	if _reduced_motion or _punch_t >= _punch_duration_s:
		return 0.0
	var u := _punch_t / _punch_duration_s
	var a := tuning.fov_punch_attack_frac
	if u < a:
		return _punch_deg * smoothstep(0.0, a, u)
	return _punch_deg * (1.0 - smoothstep(a, 1.0, u))


## Current camera roll (rad, + right side down); 0 with reduced motion.
func roll_rad() -> float:
	return _roll_out


## Smoothed world heading the offsets hang from (rad, clockwise from above, 0 faces -Z).
func heading_rad() -> float:
	return _heading.value


## Current look-target lateral shift (m, + right).
func look_ahead_lateral_m() -> float:
	return _look_lat.value


func is_reduced_motion() -> bool:
	return _reduced_motion


# ---------------------------------------------------------------- Internals

func _has_target() -> bool:
	return _target != null and is_instance_valid(_target) and _cam != null


func _restored_mode_index() -> int:
	var saved: Variant = Settings.get_value(&"camera_mode")
	var i := tuning.mode_index(StringName(str(saved)))
	if i < 0:
		i = tuning.mode_index(StringName(tuning.default_mode))
	return maxi(i, 0)


func _apply_mode_index(i: int) -> void:
	_mode_i = i
	_pos.configure(tuning.mode_position_hz[i], tuning.mode_position_damping_ratio[i])
	_heading.configure(tuning.mode_heading_hz[i], tuning.mode_heading_damping_ratio[i])
	_resolve_marker()
	snap_to_target()


func _resolve_marker() -> void:
	_marker = null
	if not _has_target():
		return
	var path := tuning.mode_marker[_mode_i]
	if not path.is_empty():
		_marker = _target.get_node_or_null(NodePath(path)) as Node3D


## World heading of `b` (rad, clockwise from above, 0 faces -Z), or `fallback` when the
## forward axis is vertical.
static func heading_of(b: Basis, fallback: float) -> float:
	var fwd := -b.z
	if absf(fwd.x) + absf(fwd.z) <= 0.0:
		return fallback
	return atan2(fwd.x, -fwd.z)


func _update(dt: float, snap: bool) -> void:
	var tp := _target.global_transform
	var anchor := tp.origin
	var mi := _mode_i
	var v := _state.v if _state != null else 0.0

	# Heading spring (wrapped so it always takes the short way round).
	var target_heading := heading_of(tp.basis, _heading.value)
	if snap:
		_heading.reset(target_heading)
	else:
		_heading.step(_heading.value + wrapf(target_heading - _heading.value, -PI, PI), dt)
		if absf(_heading.value) > PI:
			_heading.value = wrapf(_heading.value, -PI, PI)
	var psi := _heading.value
	var fwd := Vector3(sin(psi), 0.0, -cos(psi))
	var right := Vector3(cos(psi), 0.0, sin(psi))

	# Position goal: marker, or the mode offset scaled by the speed pull-back.
	var goal: Vector3
	if _marker != null and is_instance_valid(_marker):
		goal = _marker.global_position
	else:
		var k := tuning.pullback_scale(v, _top_speed_mps, mi)
		goal = anchor - fwd * (tuning.mode_behind_m[mi] * k) + Vector3.UP * (tuning.mode_height_m[mi] * k)
	if snap or dt <= 0.0:
		_pos.reset_vec(goal)
	elif _pos.is_rigid():
		_pos.reset_vec(goal)
	else:
		# Feed forward the non-lateral target velocity (moving-frame spring).
		var tvel := (anchor - _prev_anchor) / dt
		var ff := tvel - right * tvel.dot(right)
		_pos.vec_value += ff * dt
		_pos.vec_velocity -= ff
		_pos.step_vec(goal, dt)
		_pos.vec_velocity += ff
	_prev_anchor = anchor

	# Look-ahead toward the road-relative lateral velocity (d_dot, + right).
	var lat_speed := 0.0
	var accel_lat := 0.0
	if _state != null:
		lat_speed = _state.v * sin(_state.yaw) + _state.v_lat * cos(_state.yaw)
		accel_lat = _state.accel_lat
	var lat_goal := tuning.look_ahead_lateral_m(lat_speed)
	var roll_goal := 0.0 if _reduced_motion else tuning.roll_rad(accel_lat)
	if snap:
		_look_lat.reset(lat_goal)
		_roll.reset(roll_goal)
	else:
		_look_lat.step(lat_goal, dt)
		_roll.step(roll_goal, dt)
	_roll_out = 0.0 if _reduced_motion else _roll.value

	var look := anchor + fwd * tuning.mode_look_ahead_m[mi] \
			+ Vector3.UP * tuning.mode_look_height_m[mi] + right * _look_lat.value
	var eye := _pos.vec_value
	var view := look - eye
	var b := Basis(Vector3.UP, -psi)
	if not view.is_zero_approx():
		# Straight down (an overhead offset with no "behind"): keep the heading as screen-up.
		var up_hint := Vector3.UP if absf(view.normalized().y) < STRAIGHT_DOWN_COS else fwd
		b = Basis.looking_at(view, up_hint)
	# + roll = right side down = negative rotation about the camera's local Z.
	b = b * Basis(Vector3.BACK, -_roll_out)
	global_transform = Transform3D(b, eye)

	_fov_out = tuning.fov_deg(v, _top_speed_mps) + tuning.mode_fov_offset_deg[mi] + punch_deg()
	_cam.fov = _fov_out
	_apply_shake()


func _apply_shake() -> void:
	var a := shake_amplitude()
	if a <= 0.0:
		_cam.transform = Transform3D.IDENTITY
		return
	var off := tuning.shake_offset_m * a
	var rot := deg_to_rad(tuning.shake_rotation_deg) * a
	var euler := Vector3(_noise(CH_PITCH) * rot, _noise(CH_YAW) * rot, _noise(CH_ROLL) * rot)
	_cam.transform = Transform3D(Basis.from_euler(euler), Vector3(_noise(CH_X) * off, _noise(CH_Y) * off, 0.0))


## Smooth deterministic noise in [-1, 1] for one shake channel (no RNG: view-only).
func _noise(ch: int) -> float:
	var f := TAU * tuning.shake_frequency_hz * _time_s
	return sin(f * NOISE_RATE_A[ch] + NOISE_PHASE[ch]) * NOISE_MIX \
			+ sin(f * NOISE_RATE_B[ch] + NOISE_PHASE[ch]) * (1.0 - NOISE_MIX)


func _apply_far_plane() -> void:
	Quality.apply_far_plane(_cam)


func _on_settings_changed(key: StringName) -> void:
	if key == &"reduced_motion":
		_reduced_motion = bool(Settings.get_value(&"reduced_motion"))
		if _reduced_motion:
			_roll_out = 0.0
			_cam.transform = Transform3D.IDENTITY
	elif key == &"camera_mode":
		var i := tuning.mode_index(StringName(str(Settings.get_value(&"camera_mode"))))
		if i >= 0 and i != _mode_i:
			_apply_mode_index(i)


## Floating origin: move the whole spring state with the world so the camera-to-target
## offset (and any spring transient) is unchanged across the shift.
func _on_origin_shifted(offset: Vector3) -> void:
	_pos.vec_value -= offset
	_prev_anchor -= offset
	var t := global_transform
	t.origin -= offset
	global_transform = t
	reset_physics_interpolation()
	_cam.reset_physics_interpolation()


func _on_quality_changed(_tier: StringName) -> void:
	_apply_far_plane()


func _on_governor_changed(_rung: int) -> void:
	_apply_far_plane()


func _on_boost_started() -> void:
	fov_punch(feel.boost_fov_punch_deg, feel.boost_fov_punch_s)


func _on_hit(_source: StringName, _lives_left: int) -> void:
	shake(feel.hit_shake_strength, feel.hit_shake_s)


func _on_scored(kind: StringName, _points: int, _multiplier: float, _clearance_m: float) -> void:
	if kind == Events.CLOSE_PASS:
		shake(feel.close_pass_shake_strength, feel.close_pass_shake_s)
