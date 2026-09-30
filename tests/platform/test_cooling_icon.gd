extends WBTest
## The HUD's cooling icon (WP9.1). Spec: Performance budget → Adaptive governor ("A small
## 'cooling' icon shows while it is active"); UI → HUD layout (safe areas, the middle third
## clear, mirrored left-handed controls); plan D14 (no readout in the thumb zones).
## docs/QUALITY.md → Cooling icon.
##
## Placement across canvases, safe insets, text size 100% / 125%, right and left hands,
## drag and gyro steering, auto and manual pedals, controls_scale 0.8 / 1 / 1.2; it
## follows Quality.is_cooling(); hidden it draws nothing, shown it never redraws.

const HUD_SCENE := "res://src/ui/hud/hud.tscn"
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1361.0, 720.0), Vector2(1560.0, 720.0)]
const INSET := Vector4(44.0, 0.0, 44.0, 21.0)
const SCALES: Array[float] = [0.8, 1.0, 1.2]
const DT := 1.0 / 60.0
const EPS := 1e-3

var t: Tuning
var hud: Hud
var _saved_rung: int = 0


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved_rung = Quality.governor_rung


func after_each() -> void:
	if hud != null:
		hud.free()
		hud = null
	Quality.thermal.clear_force()
	Quality.governor.configure(Quality.tuning)
	Quality.set_governor_rung(_saved_rung)
	Settings.reset_to_defaults()


func _make_hud(full: Rect2, safe: Rect2) -> Hud:
	hud = (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(full, safe)
	tree.root.add_child(hud)
	return hud


static func _safe(full: Rect2, inset: bool) -> Rect2:
	if not inset:
		return full
	return Rect2(full.position + Vector2(INSET.x, INSET.y), full.size - Vector2(INSET.x + INSET.z, INSET.y + INSET.w))


func test_icon_is_small_and_under_the_pause_button() -> void:
	for ts: float in t.hud.text_scales:
		var full := Rect2(Vector2.ZERO, CANVASES[0])
		var l := HudLayout.new()
		var c := ControlsLayout.new()
		c.build(t.controls, full, full, PlayerInput.canvas_px_per_cm(t.controls, full.size, Vector2i.ZERO),
			PlayerInput.DRAG, PlayerInput.AUTO, false, 1.0)
		l.build(t.hud, full, full, c, ts)
		near(l.cooling.size.x, t.hud.lives_icon_px * ts, EPS, "a life icon's size at %.2f" % ts)
		near(l.cooling.size.x, l.cooling.size.y, EPS, "square")
		lt(l.cooling.size.x, l.pause.size.x, "smaller than a button")
		near(l.cooling.get_center().x, l.pause.get_center().x, EPS, "centred under [II]")
		near(l.cooling.position.y, l.pause.end.y + t.hud.spacing_grid_px, EPS, "one grid step below")


## Every canvas, inset, text size, hand, steering, throttle and controls scale: inside the
## safe area, off the thumb zones and pedals (with the clearance), in the top band (never
## the middle third where traffic is read), overlapping no other readout.
func test_placement_in_every_layout() -> void:
	var cases := 0
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		for inset: bool in [false, true]:
			var safe := _safe(full, inset)
			var ppc := PlayerInput.canvas_px_per_cm(t.controls, full.size, Vector2i.ZERO)
			for ts: float in t.hud.text_scales:
				for left: bool in [false, true]:
					for steering: StringName in [PlayerInput.DRAG, PlayerInput.GYRO]:
						for throttle: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
							for scale in SCALES:
								var c := ControlsLayout.new()
								c.build(t.controls, full, safe, ppc, steering, throttle, left, scale)
								var l := HudLayout.new()
								l.build(t.hud, full, safe, c, ts)
								_check(l, "%s inset=%s ts=%.2f left=%s %s %s x%.1f" % [size, inset, ts, left,
									steering, throttle, scale])
								cases += 1
	gt(cases, 100.0)


func _check(l: HudLayout, what: String) -> void:
	var r := l.cooling
	var clear := t.hud.pedal_clearance_px - EPS
	if not l.safe.encloses(r):
		fail("%s: cooling %s outside the safe area %s" % [what, r, l.safe])
	for z in l.thumb_areas():
		if r.intersects(z.grow(clear)):
			fail("%s: cooling %s in a thumb area %s" % [what, r, z])
	if r.intersects(l.middle_column()) or r.end.y > l.safe.position.y + l.safe.size.y * 0.3:
		fail("%s: cooling %s not in the top-right corner" % [what, r])
	var rects := l.rects()
	var names := HudLayout.names()
	for i in rects.size():
		if names[i] != "cooling" and r.intersects(rects[i]):
			fail("%s: cooling overlaps %s" % [what, names[i]])
	# Transient panels too: the leg toast and the JOURNEY COMPLETE banner.
	for transient: Rect2 in [l.toast, l.journey]:
		if r.intersects(transient):
			fail("%s: cooling overlaps a toast %s" % [what, transient])


func test_hud_places_the_icon_in_its_slot_at_both_text_sizes() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[1])
	_make_hud(full, _safe(full, true))
	for ts: float in t.hud.text_scales:
		Settings.set_value(&"text_scale", ts)
		hud.set_cooling(true)
		check(hud.cooling_visible())
		var r := hud.cooling_rect()
		eq(r, hud.layout.cooling, "at %.2f" % ts)
		near(r.size.x, t.hud.lives_icon_px * ts, EPS)
	Settings.set_value(&"left_handed", true)
	eq(hud.cooling_rect(), hud.layout.cooling, "left-handed")


func test_icon_follows_the_governor() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	_make_hud(full, full)
	check(not hud.cooling_visible(), "hidden at the user's tier")
	Quality.governor.reset()   # a step may come at once
	Quality.thermal.force(Thermal.SERIOUS)
	# One governor step from the thermal state, whatever the game state (thermal counts
	# outside gameplay too).
	Quality.step_governor(DT)
	eq(Quality.governor_rung, 1, "a thermal step")
	check(Quality.is_cooling())
	check(hud.cooling_visible(), "shown while the governor holds a thermal step")
	Quality.set_governor_rung(0)
	check(not hud.cooling_visible(), "hidden back at the tier")
	Quality.set_governor_rung(2)   # a step that was not thermal (a dev / frame step)
	check(not hud.cooling_visible(), "no icon for a frame-time step")
	Quality.set_governor_rung(0)
	hud.set_cooling(true)
	check(hud.cooling_visible(), "pinned (previews)")
	hud.unpin_cooling()
	check(not hud.cooling_visible(), "unpinned: follows Quality again")


func test_hidden_draws_nothing_and_shown_never_redraws() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	_make_hud(full, full)
	for i in 5:
		hud.advance(DT)
	await tree.process_frame
	var items := hud.visible_item_count()
	hud.set_cooling(true)
	eq(hud.visible_item_count(), items + 1, "one canvas item while shown")
	for i in 5:
		hud.advance(DT)
	await tree.process_frame
	await tree.process_frame
	var r0 := hud.redraw_count()
	for i in 30:
		hud.advance(DT)
	await tree.process_frame
	eq(hud.redraw_count(), r0, "static while shown")
	hud.set_cooling(false)
	eq(hud.visible_item_count(), items, "nothing while hidden")


func test_icon_takes_no_touches() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	_make_hud(full, full)
	hud.set_cooling(true)
	var icon := hud.get_node("Root/Cooling") as Control
	eq(icon.mouse_filter, Control.MOUSE_FILTER_IGNORE, "the controls under it keep working")
