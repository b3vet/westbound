class_name ScreenInsets
extends RefCounted
## The display's safe area in canvas pixels, for the HUD, the menus and the touch
## controls (the 3D view stays full-bleed). Spec: UI, HUD and design system → Safe
## areas; Controls (the controls respect safe areas). WP9.7 (landscape only, room for
## the camera cutout on the left). docs/SCREENS.md → Safe area, docs/WEB.md →
## Landscape only.
##
## Insets are Vector4: x left, y top, z right, w bottom, in canvas px unless named
## otherwise. Sources, in order:
##   - web with the custom shell: the page's env(safe-area-inset-*) (WebLayout), mapped
##     into the landscape box when the shell rotates a portrait page (the portrait top,
##     where the camera is, becomes the left), scaled from CSS px to canvas px;
##   - native (and the web without the shell): DisplayServer.get_display_safe_area();
##   - then, on a phone-class device, at least ControlsTuning.min_left_inset_cm on the
##     left (Safari often reports 0 in landscape; most players hold the phone with its
##     camera on the left). The right side keeps only what the device reports.
## Headless (tests) gives the whole canvas. Everything but canvas_safe_rect() is pure.
## Review snaps: `--safe_insets=L,T,R,B` (canvas px, user args after `--`, e.g.
## tools/snap.sh ... --safe_insets=85,0,0,21) replaces every source, headless too.

const OVERRIDE_ARG := "--safe_insets="

static var _override_read: bool = false
static var _override_set: bool = false
static var _override: Vector4 = Vector4.ZERO

## A portrait page's insets in the landscape box the shell rotates 90° clockwise: the
## box's left edge is the page's top, its top the page's right, its right the page's
## bottom, its bottom the page's left.
static func rotate_cw(page: Vector4) -> Vector4:
	return Vector4(page.y, page.z, page.w, page.x)


## The web page's insets (CSS px, the page's frame) in canvas px: rotated into the
## landscape box when `rotated`, then scaled from the box (`box_css`) to the canvas.
static func web_canvas_insets(page_css: Vector4, rotated: bool, box_css: Vector2, canvas: Vector2) -> Vector4:
	if box_css.x <= 0.0 or box_css.y <= 0.0:
		return Vector4.ZERO
	var ins := rotate_cw(page_css) if rotated else page_css
	var k := canvas / box_css
	return Vector4(maxf(ins.x, 0.0) * k.x, maxf(ins.y, 0.0) * k.y, maxf(ins.z, 0.0) * k.x,
			maxf(ins.w, 0.0) * k.y)


## The engine's safe area (screen px) as canvas insets of a window at `win_pos`,
## `win_size` (screen px) showing a `canvas`-sized canvas. An empty area: no insets.
static func display_canvas_insets(area: Rect2i, win_pos: Vector2i, win_size: Vector2i, canvas: Vector2) -> Vector4:
	if area.size.x <= 0 or area.size.y <= 0 or win_size.x <= 0 or win_size.y <= 0:
		return Vector4.ZERO
	var k := canvas / Vector2(win_size)
	return Vector4(maxf(0.0, float(area.position.x - win_pos.x)) * k.x,
			maxf(0.0, float(area.position.y - win_pos.y)) * k.y,
			maxf(0.0, float(win_pos.x + win_size.x - area.end.x)) * k.x,
			maxf(0.0, float(win_pos.y + win_size.y - area.end.y)) * k.y)


## The left inset raised to `min_left` (canvas px); the other sides as they are.
static func with_min_left(ins: Vector4, min_left: float) -> Vector4:
	return Vector4(maxf(ins.x, min_left), ins.y, ins.z, ins.w)


## The minimum left inset in canvas px at `px_per_cm` canvas px per physical cm.
static func min_left_px(tuning: ControlsTuning, px_per_cm: float) -> float:
	return tuning.min_left_inset_cm * px_per_cm


## `full` shrunk by `ins` (never below zero size).
static func safe_rect(full: Rect2, ins: Vector4) -> Rect2:
	var size := full.size - Vector2(ins.x + ins.z, ins.y + ins.w)
	return Rect2(full.position + Vector2(ins.x, ins.y), size.max(Vector2.ZERO))


## The live safe area of a `full` canvas (the root viewport's visible rect). Headless
## and unknown safe areas give the whole canvas (plus the phone minimum, on phones).
static func canvas_safe_rect(full: Rect2) -> Rect2:
	if _has_override():
		return safe_rect(full, _override)
	var win_size := DisplayServer.window_get_size()
	if DisplayServer.get_name() == "headless" or win_size.x <= 0 or win_size.y <= 0:
		return full
	var ins := Vector4.ZERO
	var phone := false
	if WebLayout.available():
		ins = web_canvas_insets(WebLayout.page_insets_css(), WebLayout.rotated(), WebLayout.box_css(), full.size)
		phone = WebLayout.phone()
	else:
		ins = display_canvas_insets(DisplayServer.get_display_safe_area(), DisplayServer.window_get_position(),
				win_size, full.size)
		phone = OS.has_feature("mobile")
	if phone:
		var controls := Tuning.load_default().controls
		ins = with_min_left(ins, min_left_px(controls, PlayerInput.canvas_px_per_cm(controls, full.size, win_size)))
	return safe_rect(full, ins)


## `--safe_insets=L,T,R,B` in the user args: four canvas-px insets.
static func parse_override(args: PackedStringArray) -> PackedFloat64Array:
	for a in args:
		if a.begins_with(OVERRIDE_ARG):
			var parts := a.trim_prefix(OVERRIDE_ARG).split(",")
			if parts.size() == 4:
				var out := PackedFloat64Array()
				for p in parts:
					out.append(maxf(p.to_float(), 0.0))
				return out
	return PackedFloat64Array()


static func _has_override() -> bool:
	if not _override_read:
		_override_read = true
		var v := parse_override(OS.get_cmdline_user_args())
		if v.size() == 4:
			_override_set = true
			_override = Vector4(v[0], v[1], v[2], v[3])
	return _override_set
