extends WBTest
## Gyro steering. Spec: Controls → Gyro steering and Tests ("Gyro: the sign is correct
## in both landscape orientations"), plus the mapping (2° dead zone, 25° max), the
## 60 ms smoothing time constant, calibration and a mid-run orientation flip.
##
## A fake GravitySource plays the phone: it holds a physical pose (roll = steering-
## wheel tilt, right edge down positive; pitch = tilted back from upright) and the
## screen rotation, and reports gravity in the device's natural (portrait) frame, as
## the web source does.

const G := 9.81
const DT := 1.0 / 120.0


class FakeGravity:
	extends GravitySource
	var roll_deg: float = 0.0
	var pitch_deg: float = 40.0
	var rotation: int = 90
	var reaction: bool = false   ## report the upward reaction vector (sign unknown)
	var known: bool = true
	var zero: bool = false

	func read_gravity() -> Vector3:
		if zero:
			return Vector3.ZERO
		var r := deg_to_rad(roll_deg)
		var p := deg_to_rad(pitch_deg)
		# Earth-pointing gravity in the screen frame (x right, y up, z out of the screen).
		var s := Vector3(sin(r), -cos(r) * cos(p), -cos(r) * sin(p)) * G
		var dev := FakeGravity.screen_to_device(s, rotation)
		return -dev if reaction else dev

	func screen_rotation_deg() -> int:
		return rotation

	func sign_known() -> bool:
		return known

	func is_supported() -> bool:
		return true

	## Inverse of GravitySource.to_screen.
	static func screen_to_device(s: Vector3, rot: int) -> Vector3:
		match rot:
			90:
				return Vector3(s.y, -s.x, s.z)
			180:
				return Vector3(-s.x, -s.y, s.z)
			270:
				return Vector3(-s.y, s.x, s.z)
		return s


var c: ControlsTuning
var src: FakeGravity
var gy: GyroControl


func before_all() -> void:
	c = Tuning.load_default().controls


func before_each() -> void:
	src = FakeGravity.new()
	gy = _make(src, c)


func _make(s: GravitySource, tuning: ControlsTuning) -> GyroControl:
	var g := GyroControl.new(s)
	g.configure(tuning, deg_to_rad(tuning.gyro_max_angle_deg), tuning.gyro_dead_zone_frac(),
			tuning.response_curve_exponent)
	return g


func _settle(seconds: float = 1.0) -> void:
	for i in ceili(seconds / DT):
		gy.advance(DT)


func test_to_screen_round_trip() -> void:
	var v := Vector3(1.0, 2.0, 3.0)
	for rot: int in [0, 90, 180, 270]:
		eq(GravitySource.to_screen(FakeGravity.screen_to_device(v, rot), rot), v, "rotation %d" % rot)
	eq(GravitySource.to_screen(v, -90), GravitySource.to_screen(v, 270), "negative angles wrap")


func test_sign_in_both_landscape_orientations() -> void:
	for rot: int in [90, 270]:
		src.rotation = rot
		src.roll_deg = 0.0
		gy = _make(src, c)
		gy.recalibrate()
		src.roll_deg = 12.0
		_settle()
		gt(gy.steer, 0.0, "right edge down steers right, rotation %d" % rot)
		src.roll_deg = -12.0
		_settle()
		lt(gy.steer, 0.0, "left edge down steers left, rotation %d" % rot)


func test_same_device_vector_flips_with_orientation() -> void:
	# The raw sensor reading is identical; only the screen rotation differs.
	src.rotation = 90
	src.roll_deg = 12.0
	var raw := src.read_gravity()
	var a := GyroControl._long_axis_angle(GravitySource.to_screen(raw, 90))
	var b := GyroControl._long_axis_angle(GravitySource.to_screen(raw, 270))
	near(a, -b, 1e-6, "landscape-left and landscape-right read opposite tilts")
	near(a, deg_to_rad(12.0), 1e-5, "and the right one reads the pose")


func test_flip_mid_run_keeps_neutral_and_sign() -> void:
	src.rotation = 90
	src.roll_deg = 3.0   # the player's natural hold is slightly off level
	gy.recalibrate()
	_settle()
	eq(gy.steer, 0.0, "neutral")
	src.rotation = 270   # the phone is turned over; same hold relative to the screen
	_settle()
	eq(gy.steer, 0.0, "still neutral after the flip")
	src.roll_deg = 3.0 + 15.0
	_settle()
	gt(gy.steer, 0.0, "tilt right still steers right")
	src.roll_deg = 3.0 - 15.0
	_settle()
	lt(gy.steer, 0.0)


func test_mapping_edge_mid_full() -> void:
	var e := c.response_curve_exponent
	src.roll_deg = 0.0
	gy.recalibrate()
	src.roll_deg = 1.9
	_settle()
	eq(gy.steer, 0.0, "inside the 2 deg dead zone")
	src.roll_deg = 13.5
	_settle()
	near(gy.steer, pow(0.5, e), 1e-4, "13.5 deg = live-range midpoint (float32 sensor vector)")
	src.roll_deg = 25.0
	_settle()
	near(gy.steer, 1.0, 1e-4, "25 deg = full")
	src.roll_deg = 40.0
	_settle()
	eq(gy.steer, 1.0, "clamped past 25 deg")
	src.roll_deg = -40.0
	_settle()
	eq(gy.steer, -1.0)


func test_pitch_does_not_steer() -> void:
	# Tilting the phone back/forward (flat to upright) is not steering.
	src.roll_deg = 0.0
	src.pitch_deg = 30.0
	gy.recalibrate()
	for p: float in [0.0, 20.0, 60.0, 80.0]:
		src.pitch_deg = p
		_settle(0.3)
		eq(gy.steer, 0.0, "pitch %d" % int(p))


func test_calibrated_neutral() -> void:
	src.roll_deg = 6.0
	gy.recalibrate()
	_settle()
	eq(gy.steer, 0.0, "the calibrated hold is straight")
	src.roll_deg = 6.0 + 30.0
	_settle()
	eq(gy.steer, 1.0, "full is measured from neutral")
	near(rad_to_deg(gy.neutral_rad), 6.0, 1e-4)


func test_smoothing_time_constant_60ms() -> void:
	near(c.gyro_smoothing_s(), 0.06, 1e-12)
	src.roll_deg = 0.0
	gy.recalibrate()
	src.roll_deg = 20.0
	var target := deg_to_rad(20.0)
	# 1 ms steps: after 60 ms the first-order filter is at 1 - 1/e.
	for i in 60:
		gy.advance(0.001)
	near(gy.filtered_rad / target, 1.0 - exp(-1.0), 1e-4, "63.2% after one time constant")
	# At the 120 Hz tick: 63.2% is crossed between 7 and 8 ticks (58-67 ms).
	gy = _make(src, c)
	src.roll_deg = 0.0
	gy.recalibrate()
	src.roll_deg = 20.0
	var ticks := 0
	while gy.filtered_rad < target * (1.0 - exp(-1.0)):
		gy.advance(DT)
		ticks += 1
	near(float(ticks) * DT, 0.06, DT, "time to 63.2% ~ 60 ms")


func test_reaction_vector_source_fixed_at_calibration() -> void:
	# The web: some browsers report accelerationIncludingGravity pointing up.
	for reaction: bool in [false, true]:
		src = FakeGravity.new()
		src.known = false
		src.reaction = reaction
		gy = _make(src, c)
		gy.recalibrate()
		src.roll_deg = 15.0
		_settle()
		gt(gy.steer, 0.0, "right is right (reaction=%s)" % reaction)
		eq(gy.sign_factor, -1.0 if reaction else 1.0)


func test_no_sensor_means_no_steer() -> void:
	src.zero = true
	_settle(0.1)
	check(not gy.has_sensor, "zero gravity = no sensor")
	eq(gy.steer, 0.0)
	check(not gy.calibrated, "calibration waits for data")
	src.zero = false
	src.roll_deg = 5.0
	gy.advance(DT)
	check(gy.calibrated, "first reading calibrates")
	eq(gy.steer, 0.0, "the first hold is neutral")
