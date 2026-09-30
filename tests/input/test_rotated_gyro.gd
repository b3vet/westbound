extends WBTest
## Gyro steering on a rotated web page (WP9.7: landscape only). Spec: Controls → Gyro
## steering; Tests ("Gyro: the sign is correct in both landscape orientations").
## docs/WEB.md → Landscape only.
##
## A portrait page (orientation locked, screen.orientation.angle 0) that the shell turns
## 90° clockwise is held like a landscape phone with its top on the left: the game adds
## the shell's quarter turn to the page's angle (WebMotionSource.game_rotation_deg), so
## the same physical hold steers exactly as in real landscape (angle 90).

const TestGyro := preload("res://tests/unit/test_gyro_control.gd")
const DT := 1.0 / 120.0

## The phone as the web source reports it: device-frame gravity for a physical pose
## held with the game screen at `game_rotation` from the device's natural orientation,
## while the page itself reports `page_angle` and the shell's `rotated` flag.
class PageGravity:
	extends TestGyro.FakeGravity
	var page_angle: int = 0
	var rotated: bool = true

	func screen_rotation_deg() -> int:
		return WebMotionSource.game_rotation_deg(page_angle, rotated)


var c: ControlsTuning


func before_all() -> void:
	c = Tuning.load_default().controls


func test_game_rotation_adds_the_quarter_turn() -> void:
	eq(WebMotionSource.game_rotation_deg(0, true), 90, "portrait-locked, rotated: like landscape, top on the left")
	eq(WebMotionSource.game_rotation_deg(180, true), 270, "upside-down page, rotated: the other landscape")
	eq(WebMotionSource.game_rotation_deg(270, true), 0, "wraps")
	eq(WebMotionSource.game_rotation_deg(90, false), 90, "real landscape: the page's angle")
	eq(WebMotionSource.game_rotation_deg(270, false), 270)
	eq(WebMotionSource.game_rotation_deg(0, false), 0)


func _gyro(src: GravitySource) -> GyroControl:
	var gy := GyroControl.new(src)
	var max_angle := deg_to_rad(c.gyro_max_angle_deg)
	gy.configure(c, max_angle, deg_to_rad(c.gyro_dead_zone_deg) / max_angle, c.response_curve_exponent)
	return gy


## Calibrate upright, then tilt `roll_deg` (right edge down = positive) and settle.
func _steer(src: TestGyro.FakeGravity, roll_deg: float) -> float:
	var gy := _gyro(src)
	src.roll_deg = 0.0
	gy.recalibrate()
	src.roll_deg = roll_deg
	for i in 240:
		gy.advance(DT)
	return gy.steer


func test_rotated_portrait_steers_like_landscape() -> void:
	for known: bool in [true, false]:
		var land := TestGyro.FakeGravity.new()
		land.rotation = 90
		land.known = known
		var page := PageGravity.new()
		page.rotation = 90   # the physical hold: the game screen a quarter turn from natural
		page.page_angle = 0
		page.rotated = true
		page.known = known
		for roll: float in [12.0, -12.0, 30.0]:
			var want := _steer(land, roll)
			var got := _steer(page, roll)
			near(got, want, 1e-9, "roll %+.0f°, sign %s: rotated portrait = landscape" % [roll, "known" if known else "fixed at calibration"])
			check(signf(got) == signf(roll), "right edge down steers right (%+.0f°)" % roll)


func test_upside_down_page_steers_like_the_other_landscape() -> void:
	var land := TestGyro.FakeGravity.new()
	land.rotation = 270
	var page := PageGravity.new()
	page.rotation = 270
	page.page_angle = 180
	page.rotated = true
	for roll: float in [15.0, -15.0]:
		near(_steer(page, roll), _steer(land, roll), 1e-9, "page 180 + rotated = landscape 270 (%+.0f°)" % roll)


func test_without_the_quarter_turn_the_rotated_page_would_misread() -> void:
	# The page's own angle (0) alone reads the portrait axes: the hold does not steer.
	var page := PageGravity.new()
	page.rotation = 90
	page.page_angle = 0
	page.rotated = false
	var s := _steer(page, 15.0)
	var good := PageGravity.new()
	good.rotation = 90
	good.page_angle = 0
	good.rotated = true
	gt(absf(_steer(good, 15.0) - s), 0.1, "the quarter turn is what makes it steer")
