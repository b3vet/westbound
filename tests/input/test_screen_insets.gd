extends WBTest
## Safe-area insets (WP9.7: landscape only, room for the camera cutout on the left).
## Spec: UI, HUD and design system → Safe areas; Controls (the controls respect safe
## areas). docs/SCREENS.md → Safe area, docs/WEB.md → Landscape only.
##
## ScreenInsets is pure except canvas_safe_rect(): the rotated page's insets map into
## the landscape box (the portrait top, where the camera is, becomes the left), CSS px
## scale to canvas px, the engine's safe area converts as before, and phones get the
## minimum left inset (ControlsTuning.min_left_inset_cm) while the right side keeps
## only what the device reports. Then the touch controls: the drag zone starts at the
## safe area's side and the drag visual stays inside it; iOS-style touch ids.

const IOS_ID := 1_893_457_201
const EPS := 1e-4
## An iPhone 14 portrait page in Safari: 390 x 664 CSS px, turned to a 664 x 390 box;
## the canvas (1280 x 720 base, canvas_items / expand) is then 1280 x 752.
const BOX := Vector2(664.0, 390.0)
const CANVAS := Vector2(1280.0, 752.0)
## env(safe-area-inset-*) of a portrait page: left, top (the camera), right, bottom.
const PORTRAIT := Vector4(0.0, 59.0, 0.0, 34.0)

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


func after_each() -> void:
	Settings.reset_to_defaults()


# ---------------------------------------------------------------- Pure mapping

func test_rotated_page_insets_map_the_top_to_the_left() -> void:
	var r := ScreenInsets.rotate_cw(Vector4(1.0, 2.0, 3.0, 4.0))
	eq(r, Vector4(2.0, 3.0, 4.0, 1.0), "left = page top, top = page right, right = page bottom, bottom = page left")
	var ins := ScreenInsets.web_canvas_insets(PORTRAIT, true, BOX, CANVAS)
	var k := CANVAS.x / BOX.x
	near(ins.x, PORTRAIT.y * k, EPS, "the camera (portrait top) is on the left")
	near(ins.y, 0.0, EPS, "no top inset")
	near(ins.z, PORTRAIT.w * CANVAS.x / BOX.x, EPS, "the home indicator (portrait bottom) is on the right")
	near(ins.w, 0.0, EPS, "no bottom inset")


func test_landscape_page_insets_scale_to_canvas_px() -> void:
	# An iPhone 14 Pro in landscape Safari: 852 x 342 CSS px (1794 x 720 canvas).
	var box := Vector2(852.0, 342.0)
	var canvas := Vector2(720.0 * box.x / box.y, 720.0)
	var ins := ScreenInsets.web_canvas_insets(Vector4(59.0, 0.0, 59.0, 21.0), false, box, canvas)
	var k := 720.0 / box.y
	near(ins.x, 59.0 * k, EPS, "left")
	near(ins.z, 59.0 * k, EPS, "right")
	near(ins.w, 21.0 * k, EPS, "bottom")
	eq(ScreenInsets.web_canvas_insets(Vector4(-3.0, 0.0, 0.0, 0.0), false, box, canvas).x, 0.0, "never negative")
	eq(ScreenInsets.web_canvas_insets(PORTRAIT, true, Vector2.ZERO, canvas), Vector4.ZERO, "no box: no insets")


func test_display_safe_area_to_canvas_insets() -> void:
	# A 2556 x 1179 px window with 177 px side insets and a 63 px home indicator.
	var area := Rect2i(177, 0, 2556 - 354, 1179 - 63)
	var canvas := Vector2(720.0 * 2556.0 / 1179.0, 720.0)
	var ins := ScreenInsets.display_canvas_insets(area, Vector2i.ZERO, Vector2i(2556, 1179), canvas)
	var k := 720.0 / 1179.0
	near(ins.x, 177.0 * k, 1e-3, "left")
	near(ins.z, 177.0 * k, 1e-3, "right")
	near(ins.w, 63.0 * k, 1e-3, "bottom")
	eq(ScreenInsets.display_canvas_insets(Rect2i(), Vector2i.ZERO, Vector2i(2556, 1179), canvas), Vector4.ZERO,
			"no safe area: no insets")


func test_phone_minimum_left_inset_only_raises_the_left() -> void:
	var c := t.controls
	gt(c.min_left_inset_cm, 0.0, "tuned")
	var ppcm := PlayerInput.canvas_px_per_cm(c, Vector2(1560.0, 720.0), Vector2i.ZERO)
	var min_left := ScreenInsets.min_left_px(c, ppcm)
	near(min_left, c.min_left_inset_cm * 720.0 / c.fallback_screen_height_cm, EPS, "cm at the web's px/cm")
	# Safari reporting nothing: the left gets the minimum, the right stays 0.
	var none := ScreenInsets.with_min_left(Vector4.ZERO, min_left)
	eq(none, Vector4(min_left, 0.0, 0.0, 0.0), "0 reported: minimum on the left only")
	# A reported inset larger than the minimum is kept, and the right side as reported.
	var big := ScreenInsets.with_min_left(Vector4(min_left + 20.0, 0.0, 30.0, 21.0), min_left)
	eq(big, Vector4(min_left + 20.0, 0.0, 30.0, 21.0), "a bigger reported inset stays")


func test_safe_rect_and_headless() -> void:
	var full := Rect2(Vector2.ZERO, Vector2(1560.0, 720.0))
	var safe := ScreenInsets.safe_rect(full, Vector4(85.0, 0.0, 10.0, 21.0))
	eq(safe, Rect2(85.0, 0.0, 1560.0 - 95.0, 720.0 - 21.0), "shrunk by the insets")
	eq(ScreenInsets.safe_rect(full, Vector4(2000.0, 0.0, 0.0, 0.0)).size.x, 0.0, "never negative")
	eq(ScreenInsets.canvas_safe_rect(full), full, "headless: the whole canvas")
	eq(HudLayout.canvas_safe_rect(full), full, "the HUD's safe rect is the same source")
	check(not WebLayout.available() and not WebLayout.rotated() and not WebLayout.phone(), "no page off the web")
	eq(WebLayout.box_css(), Vector2.ZERO)


# ---------------------------------------------------------------- Touch controls

func _hub(full: Rect2, safe: Rect2, steering: StringName, throttle: StringName, mirrored: bool) -> PlayerInput:
	var h := PlayerInput.new()
	h.auto_advance = false
	h.controls = t.controls
	h.configure_screen(full, safe, 40.0)
	h.set_layout(steering, throttle, mirrored)
	tree.root.add_child(h)
	return h


func _touch(h: PlayerInput, pos: Vector2, pressed: bool, time_s: float) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = IOS_ID
	ev.position = pos
	ev.pressed = pressed
	h.handle_pointer(ev, time_s)


func test_drag_zone_starts_at_the_left_inset() -> void:
	var full := Rect2(Vector2.ZERO, Vector2(1560.0, 720.0))
	var safe := ScreenInsets.safe_rect(full, Vector4(85.0, 0.0, 0.0, 21.0))
	var h := _hub(full, safe, PlayerInput.DRAG, PlayerInput.AUTO, false)
	var l := h.layout
	eq(l.drag_zone, Rect2(85.0, 0.0, 1560.0 - 85.0, 720.0), "drag + auto: the safe width, full height")
	_touch(h, Vector2(40.0, 600.0), true, 0.0)
	check(not h.drag.active, "a thumb under the camera cutout does not steer")
	_touch(h, Vector2(40.0, 600.0), false, 0.1)
	_touch(h, Vector2(120.0, 600.0), true, 0.2)
	check(h.drag.active, "just right of the inset steers")
	_touch(h, Vector2(120.0, 600.0), false, 0.3)
	h.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, false)
	eq(l.drag_zone, Rect2(85.0, 0.0, 780.0 - 85.0, 720.0), "drag + manual: from the inset to the middle")
	h.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, true)
	eq(l.drag_zone, Rect2(780.0, 0.0, 780.0, 720.0), "mirrored: the middle to the right edge (no right inset)")
	ge(l.brake_rect.position.x, safe.position.x, "mirrored: the pedals stay in the safe area")
	h.set_layout(PlayerInput.GYRO, PlayerInput.MANUAL, false)
	ge(l.brake_rect.position.x, 85.0 + t.controls.controls_margin_cm * 40.0 - EPS,
			"gyro + manual: the left brake pedal clears the inset")
	h.free()


func test_drag_visual_stays_inside_the_safe_area() -> void:
	var full := Rect2(Vector2.ZERO, Vector2(1560.0, 720.0))
	var safe := ScreenInsets.safe_rect(full, Vector4(85.0, 0.0, 30.0, 21.0))
	var h := _hub(full, safe, PlayerInput.DRAG, PlayerInput.AUTO, false)
	var l := h.layout
	eq(l.drag_visual_offset(Vector2(700.0, 500.0), 50.0), Vector2.ZERO, "room: drawn on the anchor")
	eq(l.drag_visual_offset(Vector2(100.0, 500.0), 50.0), Vector2(35.0, 0.0), "near the inset: shifted right")
	eq(l.drag_visual_offset(Vector2(1520.0, 500.0), 50.0), Vector2(-40.0, 0.0), "near the right inset: shifted left")
	eq(l.drag_visual_offset(Vector2(100.0, 500.0), 2000.0), Vector2.ZERO, "wider than the safe area: unshifted")
	var overlay := (load("res://src/ui/controls_overlay.tscn") as PackedScene).instantiate() as ControlsOverlay
	tree.root.add_child(overlay)
	Settings.set_value(&"drag_visual", &"wheel")
	await tree.process_frame
	_touch(h, Vector2(95.0, 500.0), true, 0.0)
	check(overlay.wheel_visible(), "the wheel shows")
	eq(h.drag.anchor, Vector2(95.0, 500.0), "the anchor stays under the thumb (steering unchanged)")
	near(overlay.wheel_center().x - overlay.wheel_radius_px(), safe.position.x, EPS,
			"the wheel is drawn right of the inset")
	Settings.set_value(&"drag_visual", &"ring")
	near(overlay.wheel_center().x - overlay.ring_radius_px(), maxf(safe.position.x, 95.0 - overlay.ring_radius_px()),
			EPS, "the ring too")
	overlay.free()
	h.free()


func test_thumb_zone_covers_a_drag_from_the_inset() -> void:
	# The HUD's thumb zones stay at the canvas edge (the thumbs hold the phone): a thumb
	# landing just right of the phone minimum and dragging the full max drag stays in.
	for size: Vector2 in [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0), Vector2(1280.0, 752.0)]:
		var full := Rect2(Vector2.ZERO, size)
		var ppcm := HudLayout.fallback_px_per_cm(full)
		var z := HudLayout.thumb_zone_rects(t.hud, full, ppcm)
		var reach := ScreenInsets.min_left_px(t.controls, ppcm) + t.controls.drag_max_cm * ppcm
		ge(z[0].end.x, reach, "%s: the left zone covers inset + max drag" % size)
		eq(z[0].position.x, 0.0, "from the canvas edge")


func test_review_override_argument() -> void:
	var v := ScreenInsets.parse_override(PackedStringArray(["--state=busy", "--safe_insets=85,0,0,21"]))
	eq(v, PackedFloat64Array([85.0, 0.0, 0.0, 21.0]), "four canvas-px insets")
	eq(ScreenInsets.parse_override(PackedStringArray(["--safe_insets=85,0"])).size(), 0, "needs all four")
	eq(ScreenInsets.parse_override(PackedStringArray()).size(), 0, "none")
	eq(ScreenInsets.parse_override(PackedStringArray(["--safe_insets=-5,0,0,0"]))[0], 0.0, "never negative")
