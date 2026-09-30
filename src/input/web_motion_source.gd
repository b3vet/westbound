class_name WebMotionSource
extends GravitySource
## Gyro steering on the web build. Spec: Controls → Gyro steering ("Web build. Gyro
## on the web needs verification: iOS Safari asks for motion permission from a user
## gesture"). Finding and test notes: docs/CONTROLS.md → Web gyro.
##
## Godot's web platform does not read device motion at all (Input.get_gravity() stays
## zero; the 4.7 web engine JS has no devicemotion listener), so this source installs
## its own through JavaScriptBridge:
##
## - A `devicemotion` listener stores accelerationIncludingGravity (negated to point
##   toward the earth, like Godot's native gravity) and screen.orientation.angle
##   (window.orientation on older Safari) in `window.wbMotion`, read here per tick.
## - iOS 13+ Safari needs DeviceMotionEvent.requestPermission() called *during* a
##   user gesture. Godot processes touches a frame later, outside the gesture, so a
##   GDScript touch handler cannot make the call. activate() instead arms a one-shot
##   capture-phase `touchend`/`click` listener on the document: the next tap anywhere
##   runs requestPermission() inside the browser's own gesture dispatch.
## - Browsers disagree on the sign of accelerationIncludingGravity, so sign_known()
##   is false and GyroControl fixes it at calibration.
## - WP9.7: when the custom shell rotates a portrait page to landscape (WebLayout.
##   rotated(): the canvas turned 90° clockwise, the phone's top on the player's left),
##   the game's screen sits another 90° from the page's, so screen_rotation_deg() adds
##   90 to the page's angle (as cool_drive does): a portrait-locked phone (angle 0)
##   then reads like landscape with its top on the left (90), and a page at 180 like
##   the other landscape (270).
##
## Off the web every method is inert (JavaScriptBridge returns null).

const JS_NAME := "wbMotion"
## The shell's rotation of a portrait page (clockwise), and a full turn, in degrees.
const QUARTER_TURN_DEG := 90
const FULL_TURN_DEG := 360
## Installed once per page (global execution context). ES5 so every browser parses it.
const JS_SOURCE := """
(function () {
	if (window.wbMotion) { return; }
	var m = { x: 0, y: 0, z: 0, angle: 0, count: 0, state: 'idle', armed: false };
	m.supported = typeof window.DeviceMotionEvent !== 'undefined';
	m.needsPermission = m.supported && typeof DeviceMotionEvent.requestPermission === 'function';
	function onMotion(e) {
		var g = e.accelerationIncludingGravity;
		if (!g || g.x === null || g.y === null || g.z === null) { return; }
		m.x = -g.x; m.y = -g.y; m.z = -g.z; m.count += 1;
	}
	function updateAngle() {
		var a = 0;
		if (window.screen && screen.orientation && typeof screen.orientation.angle === 'number') {
			a = screen.orientation.angle;
		} else if (typeof window.orientation === 'number') {
			a = window.orientation;
		}
		m.angle = ((a % 360) + 360) % 360;
	}
	function start() {
		if (m.listening) { return; }
		m.listening = true;
		window.addEventListener('devicemotion', onMotion, false);
	}
	m.arm = function () {
		if (!m.supported) { m.state = 'unsupported'; return; }
		if (!m.needsPermission) { m.state = 'granted'; start(); return; }
		if (m.state === 'granted' || m.state === 'pending' || m.armed) { return; }
		m.armed = true;
		m.state = 'armed';
		var ask = function () {
			document.removeEventListener('touchend', ask, true);
			document.removeEventListener('click', ask, true);
			m.armed = false;
			m.state = 'pending';
			DeviceMotionEvent.requestPermission().then(function (r) {
				if (r === 'granted') { m.state = 'granted'; start(); } else { m.state = 'denied'; }
			}).catch(function () { m.state = 'denied'; });
		};
		document.addEventListener('touchend', ask, true);
		document.addEventListener('click', ask, true);
	};
	updateAngle();
	window.addEventListener('orientationchange', updateAngle, false);
	if (window.screen && screen.orientation && screen.orientation.addEventListener) {
		screen.orientation.addEventListener('change', updateAngle, false);
	}
	window.wbMotion = m;
})();
"""

var _js: JavaScriptObject


func read_gravity() -> Vector3:
	if not _ensure():
		return Vector3.ZERO
	return Vector3(float(_js.get("x")), float(_js.get("y")), float(_js.get("z")))


func screen_rotation_deg() -> int:
	if not _ensure():
		return 0
	return game_rotation_deg(int(_js.get("angle")), WebLayout.rotated())


## The game screen's rotation from the device's natural orientation: the page's
## (screen.orientation.angle) plus the shell's quarter turn when it rotates the page.
static func game_rotation_deg(page_angle_deg: int, rotated: bool) -> int:
	return posmod(page_angle_deg + (QUARTER_TURN_DEG if rotated else 0), FULL_TURN_DEG)


func sign_known() -> bool:
	return false


## Web with a touchscreen and the DeviceMotionEvent API, and permission not refused.
func is_supported() -> bool:
	if not _ensure() or not DisplayServer.is_touchscreen_available():
		return false
	return bool(_js.get("supported")) and permission_state() != &"denied"


## Arms the permission request (iOS) or starts listening (everywhere else).
func activate() -> void:
	if _ensure():
		_js.call("arm")


## idle | armed | pending | granted | denied | unsupported (UI only; allocates).
func permission_state() -> StringName:
	if not _ensure():
		return &"unsupported"
	return StringName(str(_js.get("state")))


## Motion events received so far (0 until the permission is granted and data flows).
func event_count() -> int:
	if not _ensure():
		return 0
	return int(_js.get("count"))


func _ensure() -> bool:
	if _js != null:
		return true
	if not OS.has_feature("web"):
		return false
	JavaScriptBridge.eval(JS_SOURCE, true)
	_js = JavaScriptBridge.get_interface(JS_NAME)
	return _js != null
