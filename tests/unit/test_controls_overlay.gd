extends WBTest
## The controls overlay. Spec: Controls → Drag steering (Indicator); UI → HUD elements
## (controls overlay, "nothing animates when idle"); plan D9 (joined gas + boost, the
## controls_scale setting) and D10 (drag_visual = ring | wheel: a steering wheel that
## turns with the drag, visual only; the wheel is the default since 2026-10-01, owner).
## docs/CONTROLS.md → Overlay.
##
## Screen: 1280x720 canvas at 40 px/cm (max_drag = 100 px); iOS-style touch ids.

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const PX_PER_CM := 40.0
const MAX_PX := 100.0
const DT := 1.0 / 120.0
const IOS_ID := 1_893_457_201
const FRAMES_SETTLE := 3
const FRAMES_IDLE := 5

var t: Tuning
var hub: PlayerInput
var overlay: ControlsOverlay


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	hub = PlayerInput.new()
	hub.auto_advance = false
	hub.controls = t.controls
	hub.configure_screen(SCREEN, SCREEN, PX_PER_CM)
	hub.set_layout(PlayerInput.DRAG, PlayerInput.AUTO, false)
	tree.root.add_child(hub)
	overlay = (load("res://src/ui/controls_overlay.tscn") as PackedScene).instantiate() as ControlsOverlay
	tree.root.add_child(overlay)


func after_each() -> void:
	if overlay != null:
		overlay.free()
		overlay = null
	if hub != null:
		hub.free()
		hub = null
	Settings.reset_to_defaults()


func _touch(pos: Vector2, pressed: bool, time_s: float) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = IOS_ID
	ev.position = pos
	ev.pressed = pressed
	hub.handle_pointer(ev, time_s)


func _drag(pos: Vector2, time_s: float) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = IOS_ID
	ev.position = pos
	hub.handle_pointer(ev, time_s)


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func test_wheel_is_the_default_and_the_ring_unchanged() -> void:
	await _frames(FRAMES_SETTLE)
	eq(hub.drag_visual, PlayerInput.WHEEL, "default drag visual (owner, 2026-10-01: plan D10)")
	check(overlay.wheel_mode())
	Settings.set_value(&"drag_visual", &"ring")
	eq(hub.drag_visual, PlayerInput.RING, "the hub follows the setting")
	await _frames(FRAMES_SETTLE)
	check(not overlay.wheel_mode())
	near(overlay.ring_radius_px(), t.controls.overlay_ring_radius_px, 1e-9, "ring radius as tuned at scale 1")
	_touch(Vector2(600.0, 400.0), true, 0.0)
	_drag(Vector2(660.0, 400.0), 0.1)
	await _frames(FRAMES_SETTLE)
	check(not overlay.wheel_visible(), "ring mode never shows the wheel")


func test_wheel_turns_with_the_drag() -> void:
	Settings.set_value(&"drag_visual", &"wheel")
	eq(hub.drag_visual, PlayerInput.WHEEL, "the hub follows the setting")
	await _frames(FRAMES_SETTLE)
	check(overlay.wheel_mode(), "wheel mode")
	check(not overlay.wheel_visible(), "no touch: no wheel")
	var max_rad := deg_to_rad(t.controls.wheel_visual_max_deg)
	var anchor := Vector2(600.0, 400.0)
	_touch(anchor, true, 0.0)
	await _frames(FRAMES_SETTLE)
	check(overlay.wheel_visible(), "appears with the touch")
	near(overlay.wheel_rotation(), 0.0, 1e-12, "centred")
	eq(overlay.wheel_center(), anchor, "centred on the anchor")
	near(overlay.wheel_radius_px(), t.controls.wheel_visual_diameter_cm * 0.5 * PX_PER_CM, 1e-9,
			"sized in cm")
	# A scripted drag: half right, full left, then past max_drag (the anchor follows).
	for dx: float in [50.0, -100.0, 30.0]:
		_drag(anchor + Vector2(dx, 0.0), 0.1)
		hub.advance(DT)
		await _frames(FRAMES_SETTLE)
		near(overlay.wheel_rotation(), hub.drag.steer * max_rad, 1e-12, "rotation = steer x max (%+.0f px)" % dx)
	near(overlay.wheel_rotation(), hub.drag.steer * max_rad, 1e-12)
	_drag(anchor + Vector2(-100.0 - 70.0, 0.0), 0.2)
	await _frames(FRAMES_SETTLE)
	near(overlay.wheel_rotation(), -max_rad, 1e-12, "full left = -max")
	eq(overlay.wheel_center(), hub.drag.anchor, "follows the anchor past max_drag")
	near(overlay.wheel_center().x, anchor.x - 70.0, 1e-4, "the anchor moved")
	# Idle: the finger held still draws nothing new.
	var n := overlay.redraw_count()
	await _frames(FRAMES_IDLE)
	eq(overlay.redraw_count(), n, "wheel held still: no redraw")
	_drag(anchor + Vector2(-100.0 - 40.0, 0.0), 0.3)
	await _frames(FRAMES_SETTLE)
	gt(float(overlay.redraw_count()), float(n), "a move redraws")
	_touch(anchor, false, 0.4)
	await _frames(FRAMES_SETTLE)
	check(not overlay.wheel_visible(), "disappears with the touch")
	eq(hub.drag.max_drag_px, MAX_PX, "input math unchanged by the visual")


func test_wheel_and_ring_input_is_identical() -> void:
	var steers := PackedFloat64Array()
	for visual: StringName in [&"ring", &"wheel"]:
		Settings.set_value(&"drag_visual", visual)
		_touch(Vector2(600.0, 400.0), true, 0.0)
		_drag(Vector2(655.0, 430.0), 0.1)
		hub.advance(DT)
		steers.append(hub.steer)
		steers.append(hub.brake)
		_touch(Vector2(655.0, 430.0), false, 0.2)
		for i in 20:
			hub.advance(DT)
	eq(steers[0], steers[2], "same steer")
	eq(steers[1], steers[3], "same brake")


func test_visual_switch_redraws_without_releasing_the_finger() -> void:
	Settings.set_value(&"drag_visual", &"ring")
	await _frames(FRAMES_SETTLE)
	_touch(Vector2(600.0, 400.0), true, 0.0)
	await _frames(FRAMES_SETTLE)
	var n := overlay.redraw_count()
	Settings.set_value(&"drag_visual", &"wheel")
	await _frames(FRAMES_SETTLE)
	gt(float(overlay.redraw_count()), float(n), "switching the visual redraws")
	check(hub.drag.active, "the steering thumb is kept")
	check(overlay.wheel_visible())


func test_controls_scale_scales_the_drag_visuals() -> void:
	Settings.set_value(&"controls_scale", 1.2)
	await _frames(FRAMES_SETTLE)
	near(overlay.ring_radius_px(), t.controls.overlay_ring_radius_px * 1.2, 1e-9, "ring")
	near(overlay.wheel_radius_px(), t.controls.wheel_visual_diameter_cm * 0.5 * PX_PER_CM * 1.2, 1e-9,
			"wheel")
	Settings.set_value(&"controls_scale", 9.0)
	near(overlay.wheel_radius_px(),
			t.controls.wheel_visual_diameter_cm * 0.5 * PX_PER_CM * t.controls.controls_scale_max_factor,
			1e-9, "clamped")


func test_every_layout_draws_and_idles() -> void:
	for steering: StringName in [PlayerInput.DRAG, PlayerInput.GYRO]:
		for throttle_kind: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
			for mirrored: bool in [false, true]:
				for visual: StringName in [&"ring", &"wheel"]:
					Settings.set_value(&"drag_visual", visual)
					hub.set_layout(steering, throttle_kind, mirrored)
					await _frames(FRAMES_SETTLE)
					var n := overlay.redraw_count()
					await _frames(FRAMES_IDLE)
					eq(overlay.redraw_count(), n, "%s+%s mirrored=%s %s: idle" % [
							steering, throttle_kind, mirrored, visual])


func test_joined_gas_boost_pressed_states() -> void:
	hub.set_layout(PlayerInput.DRAG, PlayerInput.MANUAL, false)
	var l := hub.layout
	await _frames(FRAMES_SETTLE)
	var n := overlay.redraw_count()
	_touch(l.gas_rect.get_center(), true, 0.0)
	await _frames(FRAMES_SETTLE)
	gt(float(overlay.redraw_count()), float(n), "gas press redraws")
	check(hub.gas_pressed and not hub.boost_pressed)
	n = overlay.redraw_count()
	_drag(l.boost_rect.get_center(), 0.5)
	await _frames(FRAMES_SETTLE)
	gt(float(overlay.redraw_count()), float(n), "sliding onto the cap redraws")
	check(hub.gas_pressed and hub.boost_pressed, "gas and boost both lit")
	n = overlay.redraw_count()
	await _frames(FRAMES_IDLE)
	eq(overlay.redraw_count(), n, "held on the cap: idle")
	_touch(l.boost_rect.get_center(), false, 0.6)
