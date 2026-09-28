class_name GyroControl
extends RefCounted
## Gyro (tilt) steering. Spec: Controls → Gyro steering (gyro_control.gd).
## docs/CONTROLS.md → Gyro.
##
## - Tilt: the gravity vector, rotated into the screen frame, gives the elevation of
##   the screen's long (x) axis: angle = asin(g_x / |g|). Turning the phone like a
##   steering wheel (right edge down) makes it positive, whether the phone is held
##   upright or tilted back towards flat.
## - Relative to a calibrated neutral (recalibrate(): the countdown, the pause menu).
## - Low-pass: first-order, time constant `smoothing_s` (60 ms): each tick moves the
##   filtered angle by 1 - exp(-dt / tau) of the way to the raw angle.
## - steer = curve(clamp(angle / max_angle)) with the dead zone as a fraction of the
##   max angle (2° of 25°) and the shared exponent.
## - Orientation: the screen frame flips with landscape-left/right, so the sign of
##   the long-axis component flips with it and steering stays correct mid-run; the
##   neutral is stored in the screen frame, so it survives the flip.
##
## Allocation-free per tick.

var source: GravitySource
var max_angle_rad: float = 1.0
var dead_zone: float = 0.0
var exponent: float = 1.0
var smoothing_s: float = 0.0
var min_gravity: float = 0.0

## Outputs and state for the preview.
var steer: float = 0.0
var raw_angle_rad: float = 0.0       ## long-axis elevation, screen frame, before neutral
var filtered_rad: float = 0.0        ## relative to neutral, low-passed
var neutral_rad: float = 0.0
var calibrated: bool = false
var has_sensor: bool = false
## -1 when the source turned out to report the reaction vector (see sign_known()).
var sign_factor: float = 1.0
var gravity_screen: Vector3 = Vector3.ZERO


func _init(src: GravitySource = null) -> void:
	source = src if src != null else GravitySource.new()


## `max_angle_rad` and `dead_zone_frac` already include the player's settings.
func configure(tuning: ControlsTuning, max_angle: float, dead_zone_frac: float,
		curve_exponent: float) -> void:
	max_angle_rad = max_angle
	dead_zone = dead_zone_frac
	exponent = curve_exponent
	smoothing_s = tuning.gyro_smoothing_s()
	min_gravity = tuning.gyro_min_gravity_mps2


func reset() -> void:
	steer = 0.0
	filtered_rad = 0.0


## Capture the current tilt as neutral (and, for a source whose sign isn't known,
## decide the sign from the hold: in any normal landscape hold, from flat to upright,
## gravity points out of the back and bottom of the screen, so g.y + g.z < 0).
func recalibrate() -> void:
	var raw := _read_screen_unsigned()
	if raw.length() < min_gravity:
		calibrated = false
		return
	if not source.sign_known():
		sign_factor = -1.0 if raw.y + raw.z > 0.0 else 1.0
	var g := raw * sign_factor
	neutral_rad = _long_axis_angle(g)
	filtered_rad = 0.0
	steer = 0.0
	calibrated = true


func advance(dt: float) -> void:
	var raw := _read_screen_unsigned()
	has_sensor = raw.length() >= min_gravity
	if not has_sensor:
		gravity_screen = raw
		steer = 0.0
		return
	if not calibrated:
		recalibrate()
	var g := raw * sign_factor
	gravity_screen = g
	raw_angle_rad = _long_axis_angle(g)
	var rel := raw_angle_rad - neutral_rad
	var alpha := 1.0 - exp(-dt / smoothing_s) if smoothing_s > 0.0 else 1.0
	filtered_rad += (rel - filtered_rad) * alpha
	steer = SteeringInput.curve(filtered_rad / max_angle_rad, dead_zone, exponent)


func _read_screen_unsigned() -> Vector3:
	return GravitySource.to_screen(source.read_gravity(), source.screen_rotation_deg())


static func _long_axis_angle(g: Vector3) -> float:
	var n := g.length()
	if n <= 0.0:
		return 0.0
	return asin(clampf(g.x / n, -1.0, 1.0))
