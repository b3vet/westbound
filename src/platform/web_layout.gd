class_name WebLayout
extends RefCounted
## The web page's layout, as the custom shell reports it (WP9.7, landscape only). Spec:
## Platform (web export second); UI → Safe areas. docs/WEB.md → Landscape only.
##
## The shell (platform/web/shell.html) keeps the game landscape: on a touch device with
## a portrait viewport it sizes the canvas to the landscape box (the viewport's height
## by its width) and CSS-rotates it 90° clockwise, so the phone's top (the camera) is on
## the player's left. It also remaps the page's touch and mouse coordinates into the
## rotated box before the engine reads them, so the game never sees the rotation. What
## the game still needs, it reads here from `window.wbLayout`:
##
## - rotated: the extra 90° for the gyro (WebMotionSource) and the inset mapping;
## - phone: a phone-class touch device (the minimum left inset applies);
## - the landscape box in CSS px, and the page's safe-area insets in CSS px as the
##   browser reports them (env(safe-area-inset-*), in the page's own portrait frame
##   when rotated; ScreenInsets maps them).
##
## Without the custom shell (Godot's default shell) or off the web, available() is
## false and the game uses the engine's own safe area. Reads are cheap property gets
## (no eval after the first call).

const JS_NAME := "wbLayout"

static var _js: JavaScriptObject
static var _looked: bool = false


## True on the web with the custom shell's layout object.
static func available() -> bool:
	return _object() != null


## The canvas is CSS-rotated (a portrait viewport on a touch device).
static func rotated() -> bool:
	var js := _object()
	return js != null and bool(js.get("rotated"))


## A phone-class touch device (coarse pointer, short screen side).
static func phone() -> bool:
	var js := _object()
	return js != null and bool(js.get("phone"))


## The landscape box the game renders into, CSS px (zero when unavailable).
static func box_css() -> Vector2:
	var js := _object()
	if js == null:
		return Vector2.ZERO
	return Vector2(float(js.get("width")), float(js.get("height")))


## The page's safe-area insets, CSS px, in the page's frame (x left, y top, z right,
## w bottom).
static func page_insets_css() -> Vector4:
	var js := _object()
	if js == null:
		return Vector4.ZERO
	return Vector4(float(js.get("il")), float(js.get("it")), float(js.get("ir")), float(js.get("ib")))


static func _object() -> JavaScriptObject:
	if _looked:
		return _js
	_looked = true
	if OS.has_feature("web"):
		_js = JavaScriptBridge.get_interface(JS_NAME)
	return _js
