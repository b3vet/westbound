class_name HudLayout
extends RefCounted
## Where each HUD element sits. Spec: UI, HUD and design system (the ASCII layout:
## score top-left, sun bar / chain / event stack top-centre, lives and buttons
## top-right; the middle third stays clear; safe areas); plan D9 (the manual pedals sit
## in the bottom corners); plan D14 (speed, the minimum-speed strip and boost move to a
## compact bottom-centre cluster under the car, and no readout goes into the thumb
## zones). CONTRACTS §14: the HUD stays clear of the controls overlay's pedal columns.
## docs/HUD.md → Layout.
##
## Pure: canvas rects in, canvas rects out. Thumb zones (hud.thumb_zone_size_cm, in
## physical cm via the controls' px_per_cm) are the canvas's lower outer corners, where
## the thumbs rest and drag in every control layout; with the manual pedals (the
## ControlsLayout's gas column and brake, either hand, any controls_scale) they are
## the thumb areas no readout may touch. The cluster sits on the bottom edge centred
## under the car (speed, then boost, in a row; the TOO SLOW strip above), slid
## sideways into the free span between the thumb areas; stacked (boost under speed)
## when the row does not fit. Sizes scale with the text size, margins do not.
## WP9.1: the governor's cooling icon has a small slot centred under [II]
## (docs/QUALITY.md → Cooling icon).

var full: Rect2 = Rect2()
var safe: Rect2 = Rect2()
var ts: float = 1.0

var score: Rect2 = Rect2()
var sun: Rect2 = Rect2()
var chain: Rect2 = Rect2()
var stack: Rect2 = Rect2()
var lives: Rect2 = Rect2()
var pause: Rect2 = Rect2()
var camera: Rect2 = Rect2()
## WP5.5: the high-beam button, under [CAM] (its slot is kept while it is hidden by day,
## so nothing moves when it appears).
var high_beam: Rect2 = Rect2()
## WP9.1: the governor's cooling icon, a small square centred under [II] (its slot is kept
## while it is hidden, so nothing moves when it appears).
var cooling: Rect2 = Rect2()
## Plan D14, the bottom-centre cluster: the speedometer and the boost meter beside it
## (or under it when stacked), and the minimum-speed strip above them (its slot is
## reserved while it is hidden).
var speedo: Rect2 = Rect2()
var min_speed: Rect2 = Rect2()
var boost: Rect2 = Rect2()
## The cluster's bounds (the three rects above).
var cluster: Rect2 = Rect2()
## The row did not fit between the thumb areas: boost sits under the speedometer.
var cluster_stacked: bool = false
## Not even the stacked cluster fit (extreme control scales only): it keeps clear of
## the pedals but may reach into a thumb zone.
var cluster_squeezed: bool = false
## WP5.2: the leg objective chip, under the score panel (left-anchored like it); under
## the lives and buttons instead when a raised bottom-left panel needs that space.
## WP5.6: this is the slot for the widest chip (objective_chip_max_width_px); the chip
## itself is as wide as its content (objective_fit()), anchored to the slot's side.
var objective: Rect2 = Rect2()
## Where a narrower chip sits in the slot: 0 left, 0.5 centred, 1 right.
var objective_anchor: float = 0.0
## WP5.2: the leg toast. It takes the event stack's slot (the stack hides while it
## shows): the stack's width, and as tall as leg_toast_size_px (never into the middle
## third). It overlaps the stack by design, so it is not in rects().
var toast: Rect2 = Rect2()
## WP6.5: the JOURNEY COMPLETE banner: centred over the toast's slot, wider than it
## (within the safe area). Like the toast, not in rects().
var journey: Rect2 = Rect2()

## The touch controls this layout avoids (canvas rects, not grown).
var pedals: Array[Rect2] = []
## Plan D14: the thumb zones, left then right (canvas rects, not grown).
var thumb_zones: Array[Rect2] = []
## Canvas px per physical cm the zones were sized with.
var px_per_cm: float = 1.0

var _hud: HudTuning

## The life icons sit in a small panel: padding each side, in spacing-grid steps.
const LIVES_PAD := 1.5   # lint: allow-number layout proportion


func build(hud: HudTuning, full_rect: Rect2, safe_rect: Rect2, controls: ControlsLayout,
		text_scale: float, life_icons: int = 2) -> void:
	_hud = hud
	full = full_rect
	safe = safe_rect
	ts = text_scale
	pedals = pedal_rects(controls)
	px_per_cm = controls.px_per_cm if controls != null else fallback_px_per_cm(full)
	thumb_zones = thumb_zone_rects(hud, full, px_per_cm)
	var m := hud.edge_margin_px
	var gap := hud.spacing_grid_px
	var top := safe.position.y + m

	score = Rect2(Vector2(safe.position.x + m, top), hud.score_size_px * ts)
	var chip := Vector2(maxf(hud.objective_chip_max_width_px, hud.objective_chip_size_px.x),
			hud.objective_chip_size_px.y) * ts
	_objective_left = Rect2(Vector2(score.position.x, score.end.y + gap), chip)

	var button := hud.button_size_px * ts
	camera = Rect2(Vector2(safe.end.x - m - button.x, top), button)
	pause = Rect2(Vector2(camera.position.x - gap - button.x, top), button)
	high_beam = Rect2(Vector2(camera.position.x, camera.end.y + gap), button)
	var cool := HudCooling.side_px(hud, ts)
	cooling = Rect2(Vector2(pause.get_center().x - cool * 0.5, pause.end.y + gap), Vector2(cool, cool))
	var n := maxi(1, life_icons)
	var icon := hud.lives_icon_px * ts
	var lives_w := float(n) * icon + float(n + 1) * gap * LIVES_PAD
	lives = Rect2(Vector2(pause.position.x - gap * 2.0 - lives_w, top),
			Vector2(lives_w, button.y + float(hud.font_label_px) * ts + gap))

	var sun_size := hud.sun_bar_size_px * ts
	sun = Rect2(Vector2(_top_centre_x(sun_size.x, top, top + sun_size.y), top), sun_size)
	var row := hud.chain_row_size_px * ts
	var chain_y := sun.end.y + gap
	var stack_h := hud.event_line_height_px * ts * float(hud.event_stack_lines)
	var row_x := _top_centre_x(row.x, chain_y, chain_y + row.y + gap + stack_h)
	chain = Rect2(Vector2(row_x, chain_y), row)
	stack = Rect2(Vector2(row_x, chain.end.y + gap), Vector2(row.x, stack_h))
	toast = Rect2(stack.position, Vector2(stack.size.x, hud.leg_toast_size_px.y * ts))
	var jw := minf(hud.journey_toast_size_px.x * ts, safe.size.x - m * 2.0)
	journey = Rect2(Vector2(_top_centre_x(jw, 0.0, 0.0, false), toast.position.y),
			Vector2(jw, hud.journey_toast_size_px.y * ts))

	_place_cluster()
	objective = _place_objective(chip)
	_widen_chain(sun_size.x)


## The objective chip at `width` (its content width): clamped between the chip's
## smallest and the slot's width, anchored in the slot.
func objective_fit(width: float) -> Rect2:
	var w := clampf(width, minf(_hud.objective_chip_size_px.x * ts, objective.size.x), objective.size.x)
	var x := objective.position.x + (objective.size.x - w) * objective_anchor
	return Rect2(Vector2(x, objective.position.y), Vector2(w, objective.size.y))


## Every HUD rect (tests check them against the touch controls and each other).
func rects() -> Array[Rect2]:
	return [score, sun, chain, stack, lives, pause, camera, min_speed, speedo, boost, objective, high_beam,
			cooling]


static func names() -> PackedStringArray:
	return PackedStringArray(["score", "sun", "chain", "stack", "lives", "pause", "camera",
			"min_speed", "speedo", "boost", "objective", "high_beam", "cooling"])


## The thumb areas no readout may touch: the thumb zones and the pedals.
func thumb_areas() -> Array[Rect2]:
	var out: Array[Rect2] = []
	out.append_array(thumb_zones)
	out.append_array(pedals)
	return out


## Plan D14: the thumb zones, the canvas's lower-left and lower-right corners, where
## the thumbs rest and drag. They start at the canvas edge, not the safe area's: the
## thumbs hold the phone's physical edges (a notch inset does not move them). WP9.7:
## the drag zone now starts at the safe area's side, but a thumb landing just right of
## the phone minimum (0.7 cm) and dragging the full max drag (2.5 cm) still stays inside
## the 3.4 cm zone (tests/input/test_screen_insets.gd).
static func thumb_zone_rects(hud: HudTuning, full_rect: Rect2, pixels_per_cm: float) -> Array[Rect2]:
	var z := hud.thumb_zone_size_cm * pixels_per_cm
	z = Vector2(minf(z.x, full_rect.size.x * 0.5), minf(z.y, full_rect.size.y))
	var y := full_rect.end.y - z.y
	var out: Array[Rect2] = [Rect2(Vector2(full_rect.position.x, y), z),
			Rect2(Vector2(full_rect.end.x - z.x, y), z)]
	return out


## Canvas px per cm without a controls layout: the same fallback PlayerInput uses where
## the DPI is unknown (the canvas height is a phone's landscape height).
static func fallback_px_per_cm(full_rect: Rect2) -> float:
	return PlayerInput.canvas_px_per_cm(Tuning.load_default().controls, full_rect.size, Vector2i.ZERO)


## The touch controls' rects: the joined gas column (pedal + boost cap) and the brake.
static func pedal_rects(controls: ControlsLayout) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if controls == null:
		return out
	if controls.has(controls.gas_control):
		out.append(controls.gas_control)
	elif controls.has(controls.gas_rect):
		out.append(controls.gas_rect)
	if controls.has(controls.brake_rect):
		out.append(controls.brake_rect)
	return out


## The display's safe area (notch, camera cutout, home indicator) in canvas
## coordinates: ScreenInsets.canvas_safe_rect (WP9.7: the web shell's insets, rotated
## with a portrait page, and the phone minimum on the left). Headless and unknown safe
## areas give the whole canvas.
static func canvas_safe_rect(full_rect: Rect2) -> Rect2:
	return ScreenInsets.canvas_safe_rect(full_rect)


var _objective_left: Rect2 = Rect2()


## Plan D14: the cluster on the bottom edge (cluster_bottom_margin_px above the safe
## area's bottom), centred under the car (the canvas centre) and slid sideways into
## the free span between the thumb areas. First that fits of: speed and boost in a
## row (bottom-aligned); stacked, boost under speed (as wide as the widest of them and
## the strip's minimum); stacked, clear of the pedals only (extreme control scales).
## The minimum-speed strip spans the cluster's width above it.
func _place_cluster() -> void:
	var gap := _hud.spacing_grid_px
	var sp := _hud.speedo_size_px * ts
	var bo := _hud.boost_size_px * ts
	var strip := _hud.min_speed_row_px * ts
	var bottom := safe.end.y - _hud.cluster_bottom_margin_px
	cluster_stacked = false
	cluster_squeezed = false
	var row := Vector2(sp.x + gap + bo.x, maxf(sp.y, bo.y) + gap + strip)
	var span := _free_span(bottom - row.y, bottom, true)
	if span.y - span.x >= row.x:
		var x := _centred_x(row.x, span)
		speedo = Rect2(Vector2(x, bottom - sp.y), sp)
		boost = Rect2(Vector2(speedo.end.x + gap, bottom - bo.y), bo)
		min_speed = Rect2(Vector2(x, bottom - row.y), Vector2(row.x, strip))
		cluster = min_speed.merge(speedo).merge(boost)
		return
	cluster_stacked = true
	var w := maxf(maxf(sp.x, bo.x), _hud.min_speed_row_min_width_px * ts)
	var h := sp.y + gap + bo.y + gap + strip
	span = _free_span(bottom - h, bottom, true)
	if span.y - span.x < w:
		cluster_squeezed = true
		span = _free_span(bottom - h, bottom, false)
	var sx := _centred_x(w, span)
	boost = Rect2(Vector2(sx, bottom - bo.y), Vector2(w, bo.y))
	speedo = Rect2(Vector2(sx, boost.position.y - gap - sp.y), Vector2(w, sp.y))
	min_speed = Rect2(Vector2(sx, speedo.position.y - gap - strip), Vector2(w, strip))
	cluster = min_speed.merge(speedo).merge(boost)


## WP9.7: the top-centre readouts (sun bar, chain and stack, the journey banner) are
## centred over the car (the canvas centre, like the cluster), not the safe area's
## centre, so a one-sided inset (the camera cutout on the left) does not push them
## towards the right thumb zone. Inside the safe area's side margins; slid clear
## (spacing_grid_px) of the corner panels that share their band y0..y1 (`avoid`): the
## score and the objective chip's left slot, the lives and the buttons. With symmetric
## insets nothing moves.
func _top_centre_x(width: float, y0: float, y1: float, avoid: bool = true) -> float:
	var m := _hud.edge_margin_px
	var gap := _hud.spacing_grid_px
	var cx := full.get_center().x
	var lo := safe.position.x + m
	var hi := safe.end.x - m
	if avoid:
		for r: Rect2 in [score, _objective_left, lives, pause, camera, high_beam]:
			if r.size.x <= 0.0 or r.end.y + gap <= y0 or r.position.y - gap >= y1:
				continue
			if r.get_center().x < cx:
				lo = maxf(lo, r.end.x + gap)
			else:
				hi = minf(hi, r.position.x - gap)
	return clampf(cx - width * 0.5, lo, maxf(lo, hi - width))


## Left edge of a `width` block centred on the canvas centre, kept in `span` (x..y).
func _centred_x(width: float, span: Vector2) -> float:
	var x := full.get_center().x - width * 0.5
	return clampf(x, span.x, maxf(span.x, span.y - width))


## The free horizontal span (x = left, y = right) between the thumb areas (zones too
## when `zones`, else the pedals only), each grown by the pedal clearance, that reach
## into the band top..bottom; inside the safe area's side margins.
func _free_span(top: float, bottom: float, zones: bool) -> Vector2:
	var clear := _hud.pedal_clearance_px
	var lo := safe.position.x + _hud.edge_margin_px
	var hi := safe.end.x - _hud.edge_margin_px
	var cx := full.get_center().x
	var areas := thumb_areas() if zones else pedals
	for a in areas:
		var g := a.grow(clear)
		if g.end.y <= top or g.position.y >= bottom:
			continue
		if a.get_center().x < cx:
			lo = maxf(lo, g.end.x)
		else:
			hi = minf(hi, g.position.x)
	return Vector2(lo, hi)


## The objective chip: under the score, else under the lives and buttons, else
## centred under the toast's slot, else under the score anyway. (Since D14 the
## fallbacks only matter on canvases so short that a thumb zone or the cluster reaches
## the chip.)
func _place_objective(size: Vector2) -> Rect2:
	var gap := _hud.spacing_grid_px
	var left := Rect2(_objective_left.position, size)
	objective_anchor = 0.0
	if _clear_of_bottom(left.grow(gap)):
		return left
	var right := Rect2(Vector2(camera.end.x - size.x, maxf(lives.end.y, high_beam.end.y) + gap), size)
	if _clear_of_bottom(right.grow(gap)) and not right.intersects(middle_column()) \
			and not right.intersects(cooling):
		objective_anchor = 1.0
		return right
	var centre := Rect2(Vector2(stack.get_center().x - size.x * 0.5, toast.end.y + gap), size)
	if _clear_of_bottom(centre.grow(gap)):
		objective_anchor = 0.5
		return centre
	return left


## WP5.6: the chain row spans the sun bar above it (when that is wider) unless another
## panel or the objective chip needs the room beside it, so a six-digit chain
## and its CHAIN label fit its half. The stack and the toast keep the tuned row width.
func _widen_chain(width: float) -> void:
	if width <= chain.size.x:
		return
	var wide := Rect2(Vector2(chain.get_center().x - width * 0.5, chain.position.y), Vector2(width, chain.size.y))
	if not safe.encloses(wide):
		return
	for r: Rect2 in [score, lives, pause, camera, high_beam, cooling, min_speed, speedo, boost, objective]:
		if wide.intersects(r):
			return
	if _hits(wide, _hud.pedal_clearance_px):
		return
	chain = wide


func _clear_of_bottom(r: Rect2) -> bool:
	if not safe.encloses(r):
		return false
	for p: Rect2 in [min_speed, speedo, boost]:
		if r.intersects(p):
			return false
	return not _hits(r, _hud.pedal_clearance_px)


## The middle third of the safe width, where traffic is read: the top-centre readouts
## live at its top and the D14 cluster on its bottom edge, under the car.
func middle_column() -> Rect2:
	var w := safe.size.x / 3.0
	return Rect2(Vector2(safe.position.x + w, safe.position.y), Vector2(w, safe.size.y))


## Whether `r` comes within `clear` of a thumb zone or a pedal.
func _hits(r: Rect2, clear: float) -> bool:
	for p in pedals:
		if p.grow(clear).intersects(r):
			return true
	for z in thumb_zones:
		if z.grow(clear).intersects(r):
			return true
	return false

