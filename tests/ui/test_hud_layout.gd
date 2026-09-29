extends WBTest
## HUD layout vs the thumbs and the touch controls. Spec: UI, HUD and design system
## (the ASCII layout; "the middle third stays clear"; safe areas; mirrored left-handed
## controls); plan D9 (manual pedals: the gas column + brake, sized by controls_scale);
## plan D14 (speed, the minimum-speed strip and boost in a bottom-centre cluster under
## the car; no readout in the thumb zones, the lower outer corners, in any control
## layout). CONTRACTS §14: the HUD stays clear of the controls overlay's pedal columns.
##
## Canvases: 16:9 (1280x720) and 19.5:9 (the owner's iPhone: 1361x720 after stretch,
## and 1560x720), with and without a notch/home-indicator safe inset. Controls: drag
## and gyro steering, auto and manual throttle, right- and left-handed,
## controls_scale 0.8 / 1.0 / 1.2; text size 100% / 125%.

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1361.0, 720.0), Vector2(1560.0, 720.0)]
## Landscape iPhone: notch side, the other side, home indicator (canvas px).
const INSET := Vector4(44.0, 0.0, 44.0, 21.0)
const SCALES: Array[float] = [0.8, 1.0, 1.2]
const HUD_SCENE := "res://src/ui/hud/hud.tscn"
## The top-centre readouts end above this share of the height.
const MIDDLE_TOP_FRAC := 0.45
## D14: the cluster (TOO SLOW strip included) stays in this bottom share of the safe
## height; the traffic area is the middle third between MIDDLE_TOP_FRAC and it.
const BOTTOM_BAND_FRAC := 0.2
## The owner's steering thumb (M4 playtest, iPhone): it dragged where the old
## speedometer sat, about 0.2..2.8 cm in from the left edge and up to 1.2 cm up.
const OWNER_THUMB_CM := Vector2(2.8, 1.2)
const EPS := 1e-3

var t: Tuning
var _cases: int = 0


func before_all() -> void:
	t = Tuning.load_default()


func after_each() -> void:
	Settings.reset_to_defaults()


func _px_per_cm(full: Rect2) -> float:
	return PlayerInput.canvas_px_per_cm(t.controls, full.size, Vector2i.ZERO)


func _controls(full: Rect2, safe: Rect2, steering: StringName, throttle: StringName, left: bool,
		scale: float) -> ControlsLayout:
	var c := ControlsLayout.new()
	c.build(t.controls, full, safe, _px_per_cm(full), steering, throttle, left, scale)
	return c


static func _safe(full: Rect2, inset: bool) -> Rect2:
	if not inset:
		return full
	return Rect2(full.position + Vector2(INSET.x, INSET.y), full.size - Vector2(INSET.x + INSET.z, INSET.y + INSET.w))


## The bottom band the cluster lives in.
func _band(l: HudLayout) -> Rect2:
	var top := l.safe.end.y - l.safe.size.y * BOTTOM_BAND_FRAC
	return Rect2(l.safe.position.x, top, l.safe.size.x, l.safe.end.y - top)


## The middle third where traffic is read: the central third of the safe width,
## between the top-centre readouts (sun bar, chain, event stack) and the cluster band.
func _traffic(l: HudLayout) -> Rect2:
	var col := l.middle_column()
	var top := l.safe.position.y + l.safe.size.y * MIDDLE_TOP_FRAC
	return Rect2(col.position.x, top, col.size.x, _band(l).position.y - top)


## Every readout inside the safe area, off the pedals and (unless `zones` is false)
## off the thumb zones, pedal_clearance_px apart; no two overlapping; and (unless
## `placement` is false: extreme control scales) out of the traffic area with the
## cluster in the bottom band.
func _check_layout(l: HudLayout, what: String, zones: bool = true, placement: bool = true) -> void:
	_cases += 1
	var clear := t.hud.pedal_clearance_px - EPS
	var rects := l.rects()
	var names := HudLayout.names()
	var traffic := _traffic(l)
	for i in rects.size():
		var r := rects[i]
		if not l.safe.encloses(r):
			fail("%s %s %s outside the safe area %s" % [what, names[i], r, l.safe])
		for p in l.pedals:
			if r.intersects(p.grow(clear)):
				fail("%s %s %s on a pedal %s" % [what, names[i], r, p])
		if zones:
			for z in l.thumb_zones:
				if r.intersects(z.grow(clear)):
					fail("%s %s %s in a thumb zone %s" % [what, names[i], r, z])
		if placement and r.intersects(traffic):
				fail("%s %s %s in the traffic area %s" % [what, names[i], r, traffic])
		for j in range(i + 1, rects.size()):
			if r.intersects(rects[j]):
				fail("%s %s overlaps %s" % [what, names[i], names[j]])
	if placement:
		var band := _band(l)
		for r: Rect2 in [l.min_speed, l.speedo, l.boost]:
			if not band.encloses(r):
				fail("%s cluster %s outside the bottom band %s" % [what, r, band])


func test_thumb_zones_are_the_lower_outer_corners_in_cm() -> void:
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		for inset: bool in [false, true]:
			var ppc := _px_per_cm(full)
			var l := HudLayout.new()
			l.build(t.hud, full, _safe(full, inset), _controls(full, _safe(full, inset), PlayerInput.DRAG,
					PlayerInput.AUTO, false, 1.0), 1.0)
			eq(l.thumb_zones.size(), 2, "one per side")
			near(l.px_per_cm, ppc, EPS, "sized with the controls' px per cm")
			var z := t.hud.thumb_zone_size_cm * ppc
			var left := l.thumb_zones[0]
			var right := l.thumb_zones[1]
			near(left.size.x, z.x, EPS)
			near(left.size.y, z.y, EPS)
			eq(right.size, left.size, "the same both sides")
			near(left.position.x, full.position.x, EPS, "from the canvas edge (the thumbs hold the phone)")
			near(right.end.x, full.end.x, EPS)
			near(left.end.y, full.end.y, EPS, "the lower corners")
			near(right.end.y, full.end.y, EPS)
			# Where the owner's steering thumb dragged over the old speedometer.
			var owner := Rect2(Vector2(full.position.x, full.end.y - OWNER_THUMB_CM.y * ppc),
					OWNER_THUMB_CM * ppc)
			check(left.encloses(owner), "%s: the left zone covers the owner's thumb" % size)
	# Without a controls layout (screens, previews) the zones use PlayerInput's fallback.
	var full0 := Rect2(Vector2.ZERO, CANVASES[1])
	var l0 := HudLayout.new()
	l0.build(t.hud, full0, full0, null, 1.0)
	near(l0.px_per_cm, _px_per_cm(full0), EPS)
	eq(l0.thumb_zones.size(), 2)


## Every mode (drag/gyro × auto/manual), hand, controls scale, text size and canvas:
## no readout in a thumb zone or on a pedal, the cluster in one row on the bottom band.
func test_readouts_avoid_thumb_zones_and_pedals_in_every_layout() -> void:
	for size in CANVASES:
		for inset: bool in [false, true]:
			var full := Rect2(Vector2.ZERO, size)
			var safe := _safe(full, inset)
			for steering: StringName in [PlayerInput.DRAG, PlayerInput.GYRO]:
				for throttle: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
					for left: bool in [false, true]:
						for scale in SCALES:
							var c := _controls(full, safe, steering, throttle, left, scale)
							if throttle == PlayerInput.MANUAL:
								check(c.has(c.gas_control) and c.has(c.brake_rect), "manual layouts have pedals")
							for ts in t.hud.text_scales:
								var l := HudLayout.new()
								l.build(t.hud, full, safe, c, ts)
								var what := "%dx%d%s %s %s %s x%.1f text %.2f" % [size.x, size.y,
										" inset" if inset else "", steering, throttle, "left" if left else "right",
										scale, ts]
								_check_layout(l, what)
								check(not l.cluster_stacked, "%s: speed and boost in one row" % what)
	eq(_cases, CANVASES.size() * 2 * 2 * 2 * 2 * SCALES.size() * t.hud.text_scales.size())


## The setting's extremes (0.6x, 1.6x): huge pedals may stack the cluster or push it
## into a thumb zone, but never onto a pedal, off screen or onto another panel.
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
								"left" if left else "right", scale, ts], not l.cluster_squeezed, false)


## D14: speed, then boost, on the bottom edge centred under the car (the canvas
## centre); the TOO SLOW strip above spanning both; the corners stay empty.
func test_cluster_sits_bottom_centre_under_the_car() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	for ts in t.hud.text_scales:
		var c := _controls(full, full, PlayerInput.DRAG, PlayerInput.AUTO, false, 1.0)
		var l := HudLayout.new()
		l.build(t.hud, full, full, c, ts)
		_check_layout(l, "auto text %.2f" % ts)
		var bottom := full.end.y - t.hud.cluster_bottom_margin_px
		near(l.speedo.end.y, bottom, EPS, "speed on the bottom edge")
		near(l.boost.end.y, bottom, EPS, "boost bottom-aligned with it")
		check(l.speedo.end.x < l.boost.position.x, "speed left of boost")
		near(l.cluster.get_center().x, full.get_center().x, EPS, "centred under the car")
		near(l.min_speed.position.x, l.speedo.position.x, EPS, "the strip spans the cluster")
		near(l.min_speed.end.x, l.boost.end.x, EPS)
		check(l.min_speed.end.y <= minf(l.speedo.position.y, l.boost.position.y) - t.hud.spacing_grid_px + EPS,
				"the strip above both")
		near(l.speedo.size.x, t.hud.speedo_size_px.x * ts, EPS, "sizes scale with the text")
		near(l.boost.size.y, t.hud.boost_size_px.y * ts, EPS)
		near(l.score.position.x, t.hud.edge_margin_px, EPS, "score top-left")
		near(l.sun.get_center().x, full.get_center().x, EPS, "sun bar top-centre")
		check(l.camera.end.x <= full.end.x - t.hud.edge_margin_px + EPS, "buttons top-right")


## The cluster slides away from a pedal block that reaches past its thumb zone, and
## stays centred when it has room.
func test_cluster_slides_clear_of_big_pedals() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	for left: bool in [false, true]:
		var c := _controls(full, full, PlayerInput.DRAG, PlayerInput.MANUAL, left, SCALES[SCALES.size() - 1])
		var l := HudLayout.new()
		l.build(t.hud, full, full, c, t.hud.text_scales[t.hud.text_scales.size() - 1])
		_check_layout(l, "big pedals %s" % ("left" if left else "right"))
		for p in l.pedals:
			var gap := (p.position.x - l.cluster.end.x) if not left else (l.cluster.position.x - p.end.x)
			ge(gap, t.hud.pedal_clearance_px - EPS, "clear of the pedals")


func test_layout_follows_the_safe_area() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[1])
	var safe := Rect2(Vector2(INSET.x, 0.0), full.size - Vector2(INSET.x + INSET.z, INSET.w))
	var l := HudLayout.new()
	l.build(t.hud, full, safe, null, 1.0)
	_check_layout(l, "notch")
	near(l.score.position.x, INSET.x + t.hud.edge_margin_px, EPS, "clear of the notch")
	near(l.speedo.end.y, safe.end.y - t.hud.cluster_bottom_margin_px, EPS, "clear of the home indicator")


## The real nodes: a PlayerInput hub (every mode, both hands, scaled via Settings)
## and a Hud in the tree; the Hud re-places itself when the controls change.
func test_hud_node_follows_the_live_controls_layout() -> void:
	var full := Rect2(Vector2.ZERO, CANVASES[1])
	var hub := PlayerInput.new()
	hub.auto_advance = false
	hub.controls = t.controls
	hub.configure_screen(full, full, _px_per_cm(full))
	tree.root.add_child(hub)
	var hud := (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(full, full)
	tree.root.add_child(hud)
	for throttle: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
		for left: bool in [false, true]:
			for scale in SCALES:
				Settings.set_value(&"throttle_mode", throttle)
				Settings.set_value(&"left_handed", left)
				Settings.set_value(&"controls_scale", scale)
				hud.advance(1.0 / 60.0)
				var pedals := HudLayout.pedal_rects(hub.layout)
				eq(pedals.size(), 2 if throttle == PlayerInput.MANUAL else 0, "gas column + brake")
				var areas: Array[Rect2] = []
				areas.append_array(pedals)
				areas.append_array(HudLayout.thumb_zone_rects(t.hud, full, hub.layout.px_per_cm))
				for r in hud.occupied_rects():
					for p in areas:
						check(not r.intersects(p), "%s left=%s x%.1f: %s overlaps %s" % [throttle, left, scale, r, p])
	hud.free()
	hub.free()
