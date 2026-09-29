extends WBTest
## HUD layout vs the touch controls. Spec: UI, HUD and design system (the ASCII
## layout; "the middle third stays clear"; safe areas; mirrored left-handed controls);
## plan D9 (manual pedals: the gas column + brake, sized by controls_scale).
## CONTRACTS §14: the HUD stays clear of the controls overlay's pedal columns.
##
## Canvases: 16:9 (1280x720) and 19.5:9 (the owner's iPhone: 1361x720 after stretch,
## and 1560x720), with and without a notch/home-indicator safe inset. Controls: drag
## and gyro steering with manual throttle (the pedal layouts) and auto (no pedals),
## right- and left-handed, controls_scale 0.8 / 1.0 / 1.2; text size 100% / 125%.

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1361.0, 720.0), Vector2(1560.0, 720.0)]
## Landscape iPhone: notch side, the other side, home indicator (canvas px).
const INSET := Vector4(44.0, 0.0, 44.0, 21.0)
const SCALES: Array[float] = [0.8, 1.0, 1.2]
const HUD_SCENE := "res://src/ui/hud/hud.tscn"
## The top-centre readouts end above this share of the height.
const MIDDLE_TOP_FRAC := 0.45

var t: Tuning
var _cases: int = 0


func before_all() -> void:
	t = Tuning.load_default()


func after_each() -> void:
	Settings.reset_to_defaults()


func _controls(full: Rect2, safe: Rect2, steering: StringName, throttle: StringName, left: bool,
		scale: float) -> ControlsLayout:
	var c := ControlsLayout.new()
	var px_per_cm := PlayerInput.canvas_px_per_cm(t.controls, full.size, Vector2i.ZERO)
	c.build(t.controls, full, safe, px_per_cm, steering, throttle, left, scale)
	return c


## The middle third where traffic (and the player's car) is read: the central third
## of the safe width, below the top-centre readouts (sun bar, chain, event stack).
func _middle(l: HudLayout) -> Rect2:
	var col := l.middle_column()
	var top := l.safe.position.y + l.safe.size.y * MIDDLE_TOP_FRAC
	return Rect2(col.position.x, top, col.size.x, l.safe.end.y - top)


func _check_layout(l: HudLayout, what: String, middle: bool = true) -> void:
	_cases += 1
	var rects := l.rects()
	var names := HudLayout.names()
	for i in rects.size():
		var r := rects[i]
		var n := "%s %s" % [what, names[i]]
		check(l.safe.encloses(r), "%s inside the safe area %s: %s" % [n, l.safe, r])
		for p in l.pedals:
			check(not r.intersects(p), "%s %s overlaps a pedal %s" % [n, r, p])
		if middle:
			check(not r.intersects(_middle(l)), "%s %s in the middle third" % [n, r])
		for j in range(i + 1, rects.size()):
			check(not r.intersects(rects[j]), "%s overlaps %s" % [n, names[j]])


func test_hud_clear_of_manual_pedals_every_handedness_scale_and_aspect() -> void:
	for size in CANVASES:
		for inset: bool in [false, true]:
			var full := Rect2(Vector2.ZERO, size)
			var safe := full
			if inset:
				safe = Rect2(Vector2(INSET.x, INSET.y), size - Vector2(INSET.x + INSET.z, INSET.y + INSET.w))
			for steering: StringName in [PlayerInput.DRAG, PlayerInput.GYRO]:
				for left: bool in [false, true]:
					for scale in SCALES:
						for ts in t.hud.text_scales:
							var c := _controls(full, safe, steering, PlayerInput.MANUAL, left, scale)
							check(c.has(c.gas_control) and c.has(c.brake_rect), "manual layouts have pedals")
							var l := HudLayout.new()
							l.build(t.hud, full, safe, c, ts)
							_check_layout(l, "%dx%d%s %s %s x%.1f text %.2f" % [size.x, size.y,
									" inset" if inset else "", steering, "left" if left else "right", scale, ts])
	gt(_cases, 0)


## The setting's extremes (0.6x, 1.6x): huge pedals may push a panel toward the
## middle, but never onto a pedal, off screen or onto another panel.
func test_extreme_control_scales_still_clear_of_pedals() -> void:
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		for steering: StringName in [PlayerInput.DRAG, PlayerInput.GYRO]:
			for left: bool in [false, true]:
				for scale: float in [t.controls.controls_scale_min_factor, t.controls.controls_scale_max_factor]:
					for ts in t.hud.text_scales:
						var c := _controls(full, full, steering, PlayerInput.MANUAL, left, scale)
						var l := HudLayout.new()
						l.build(t.hud, full, full, c, ts)
						_check_layout(l, "%dx%d %s %s x%.1f text %.2f" % [size.x, size.y, steering,
								"left" if left else "right", scale, ts], false)


func test_auto_throttle_uses_the_corners() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	var c := _controls(full, full, PlayerInput.DRAG, PlayerInput.AUTO, false, 1.0)
	var l := HudLayout.new()
	l.build(t.hud, full, full, c, 1.0)
	_check_layout(l, "auto")
	var m := t.hud.edge_margin_px
	near(l.speedo.position.x, m, 1e-3, "speed bottom-left")
	near(l.speedo.end.y, full.end.y - m, 1e-3)
	near(l.boost.end.x, full.end.x - m, 1e-3, "boost bottom-right")
	check(not l.speedo_raised and not l.boost_raised)
	near(l.score.position.x, m, 1e-3, "score top-left")
	near(l.sun.get_center().x, full.get_center().x, 1e-3, "sun bar top-centre")
	check(l.camera.end.x <= full.end.x - m + 1e-3, "buttons top-right")


func test_layout_follows_the_safe_area() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[1])
	var safe := Rect2(Vector2(INSET.x, 0.0), full.size - Vector2(INSET.x + INSET.z, INSET.w))
	var l := HudLayout.new()
	l.build(t.hud, full, safe, null, 1.0)
	_check_layout(l, "notch")
	near(l.score.position.x, INSET.x + t.hud.edge_margin_px, 1e-3, "clear of the notch")
	near(l.speedo.end.y, safe.end.y - t.hud.edge_margin_px, 1e-3, "clear of the home indicator")


## The real nodes: a PlayerInput hub (manual, left-handed, scaled via Settings) and a
## Hud in the tree; the Hud re-places itself when the controls change.
func test_hud_node_follows_the_live_controls_layout() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[1])
	var hub := PlayerInput.new()
	hub.auto_advance = false
	hub.controls = t.controls
	hub.configure_screen(full, full, PlayerInput.canvas_px_per_cm(t.controls, full.size, Vector2i.ZERO))
	tree.root.add_child(hub)
	var hud := (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(full, full)
	tree.root.add_child(hud)
	for left: bool in [false, true]:
		for scale in SCALES:
			Settings.set_value(&"throttle_mode", PlayerInput.MANUAL)
			Settings.set_value(&"left_handed", left)
			Settings.set_value(&"controls_scale", scale)
			hud.advance(1.0 / 60.0)
			var pedals := HudLayout.pedal_rects(hub.layout)
			eq(pedals.size(), 2, "gas column + brake")
			for r in hud.occupied_rects():
				for p in pedals:
					check(not r.intersects(p), "left=%s x%.1f: %s overlaps %s" % [left, scale, r, p])
	hud.free()
	hub.free()
