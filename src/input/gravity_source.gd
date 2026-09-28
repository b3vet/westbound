class_name GravitySource
extends RefCounted
## Where gyro steering reads the gravity vector. Spec: Controls → Gyro steering
## ("tilt comes from the gravity vector (Input.get_gravity())"). docs/CONTROLS.md → Gyro.
##
## Base = native (Android, iOS): Input.get_gravity(). Godot's mobile backends already
## rotate the sensor vector into the current screen orientation (Android: display
## rotation; iOS: interface orientation) and report it pointing toward the earth
## (m/s², x = screen right, y = screen up, z = out of the screen), so
## screen_rotation_deg() is 0 and the sign is known.
##
## Subclasses: WebMotionSource (device-frame DeviceMotionEvent data + the page's
## screen.orientation.angle, sign checked at calibration), and fakes in the tests.

## Gravity in the device's natural frame (x right, y up, z out of the screen, for the
## device held in its natural orientation), m/s². Vector3 is a value: no allocation.
func read_gravity() -> Vector3:
	return Input.get_gravity()


## How far the screen content is rotated from the device's natural orientation
## (0, 90, 180 or 270; screen.orientation.angle semantics). 0 when read_gravity()
## is already in the screen frame.
func screen_rotation_deg() -> int:
	return 0


## False when the source may report the reaction vector (pointing up) instead of
## gravity: GyroControl then fixes the sign at calibration from the hold.
func sign_known() -> bool:
	return true


## Whether this platform can provide tilt at all (the setting is hidden otherwise).
func is_supported() -> bool:
	return OS.has_feature("mobile")


## Called when the player picks gyro steering (web: arms the permission request).
func activate() -> void:
	pass


## Rotate a device-frame vector into the screen frame for `rotation_deg`.
## rotation 90: the device is turned a quarter counter-clockwise (its top edge on the
## left), so screen right = device down and screen up = device right.
static func to_screen(g: Vector3, rotation_deg: int) -> Vector3:
	match posmod(rotation_deg, 360):
		90:
			return Vector3(-g.y, g.x, g.z)
		180:
			return Vector3(-g.x, -g.y, g.z)
		270:
			return Vector3(g.y, -g.x, g.z)
	return g
