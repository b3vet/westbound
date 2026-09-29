class_name HudLayout
extends RefCounted
## Where each HUD element sits. Spec: UI, HUD and design system (the ASCII layout:
## score top-left, sun bar / chain / event stack top-centre, lives and buttons
## top-right, speed bottom-left, boost bottom-right; the middle third stays clear;
## safe areas); plan D9 (the manual pedals sit in the bottom corners). CONTRACTS §14:
## the HUD stays clear of the controls overlay's pedal columns. docs/HUD.md → Layout.
##
## Pure: canvas rects in, canvas rects out. The speedometer and the boost meter start
## in their bottom corners; when the touch controls (ControlsLayout: gas column,
## brake, in either handedness, at any controls_scale) are there, the panel moves
## inward beside them if it still fits in its half of the screen, else it rises above
## them. Sizes scale with the text size, margins do not.

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
## The speedometer panel, and the minimum-speed strip directly above it.
var speedo: Rect2 = Rect2()
var min_speed: Rect2 = Rect2()
var boost: Rect2 = Rect2()
## WP5.2: the leg objective chip, under the score panel (left-anchored like it); under
## the lives and buttons instead when a raised bottom-left panel needs that space.
var objective: Rect2 = Rect2()
## WP5.2: the leg toast. It takes the event stack's slot (the stack hides while it
## shows): the stack's width, and as tall as leg_toast_size_px (never into the middle
## third). It overlaps the stack by design, so it is not in rects().
var toast: Rect2 = Rect2()
## The panel rose above the touch controls (no room beside them).
var speedo_raised: bool = false
var boost_raised: bool = false

## The touch controls this layout avoids (canvas rects, not grown).
var pedals: Array[Rect2] = []

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
	var m := hud.edge_margin_px
	var gap := hud.spacing_grid_px
	var cx := safe.get_center().x
	var top := safe.position.y + m

	score = Rect2(Vector2(safe.position.x + m, top), hud.score_size_px * ts)
	_objective_left = Rect2(Vector2(score.position.x, score.end.y + gap), hud.objective_chip_size_px * ts)

	var button := hud.button_size_px * ts
	camera = Rect2(Vector2(safe.end.x - m - button.x, top), button)
	pause = Rect2(Vector2(camera.position.x - gap - button.x, top), button)
	high_beam = Rect2(Vector2(camera.position.x, camera.end.y + gap), button)
	var n := maxi(1, life_icons)
	var icon := hud.lives_icon_px * ts
	var lives_w := float(n) * icon + float(n + 1) * gap * LIVES_PAD
	lives = Rect2(Vector2(pause.position.x - gap * 2.0 - lives_w, top),
			Vector2(lives_w, button.y + float(hud.font_label_px) * ts + gap))

	var sun_size := hud.sun_bar_size_px * ts
	sun = Rect2(Vector2(cx - sun_size.x * 0.5, top), sun_size)
	var row := hud.chain_row_size_px * ts
	chain = Rect2(Vector2(cx - row.x * 0.5, sun.end.y + gap), row)
	stack = Rect2(Vector2(chain.position.x, chain.end.y + gap),
			Vector2(row.x, hud.event_line_height_px * ts * float(hud.event_stack_lines)))
	toast = Rect2(stack.position, Vector2(stack.size.x, hud.leg_toast_size_px.y * ts))

	var sp := hud.speedo_size_px * ts
	var strip := hud.min_speed_row_px * ts
	var block := _place_bottom(Vector2(sp.x, sp.y + gap + strip), true)
	speedo_raised = _raised
	min_speed = Rect2(block.position, Vector2(sp.x, strip))
	speedo = Rect2(Vector2(block.position.x, block.end.y - sp.y), sp)
	boost = _place_bottom(hud.boost_size_px * ts, false)
	boost_raised = _raised
	objective = _place_objective(hud.objective_chip_size_px * ts)


## Every HUD rect (tests check them against the touch controls and each other).
func rects() -> Array[Rect2]:
	return [score, sun, chain, stack, lives, pause, camera, min_speed, speedo, boost, objective, high_beam]


static func names() -> PackedStringArray:
	return PackedStringArray(["score", "sun", "chain", "stack", "lives", "pause", "camera",
			"min_speed", "speedo", "boost", "objective", "high_beam"])


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


## The display's safe area (notch, home indicator) in canvas coordinates. Headless
## and unknown safe areas give the whole canvas.
static func canvas_safe_rect(full_rect: Rect2) -> Rect2:
	var win_size := DisplayServer.window_get_size()
	if DisplayServer.get_name() == "headless" or win_size.x <= 0 or win_size.y <= 0:
		return full_rect
	var sa := DisplayServer.get_display_safe_area()
	if sa.size.x <= 0 or sa.size.y <= 0:
		return full_rect
	var win_pos := DisplayServer.window_get_position()
	var k := full_rect.size / Vector2(win_size)
	var left := maxf(0.0, float(sa.position.x - win_pos.x)) * k.x
	var top := maxf(0.0, float(sa.position.y - win_pos.y)) * k.y
	var right := maxf(0.0, float(win_pos.x + win_size.x - sa.end.x)) * k.x
	var bottom := maxf(0.0, float(win_pos.y + win_size.y - sa.end.y)) * k.y
	return Rect2(full_rect.position + Vector2(left, top),
			full_rect.size - Vector2(left + right, top + bottom))


var _raised: bool = false
var _objective_left: Rect2 = Rect2()


## A bottom-corner panel of `size`, first that fits of: the corner; beside the
## controls on that side (inward, not into the middle column); above them (below the
## top readouts). With none free (huge controls), beside them anyway.
func _place_bottom(size: Vector2, left: bool) -> Rect2:
	_raised = false
	var m := _hud.edge_margin_px
	var clear := _hud.pedal_clearance_px
	var corner_x := safe.position.x + m if left else safe.end.x - m - size.x
	var bottom_y := safe.end.y - m - size.y
	var r := Rect2(Vector2(corner_x, bottom_y), size)
	if not _hits(r, clear):
		return r
	var side := _side_block(left)
	var x := side.end.x + clear if left else side.position.x - clear - size.x
	var beside := Rect2(Vector2(x, bottom_y), size)
	if not beside.intersects(middle_column()) and not _hits(beside, clear):
		return beside
	var above := Rect2(Vector2(corner_x, side.position.y - clear - size.y), size)
	if _clear_of_top(above.grow(_hud.spacing_grid_px)):
		_raised = true
		return above
	return beside


## The objective chip: under the score, else under the lives and buttons (a raised
## bottom panel took the space), else (both corners raised: extreme control scales
## only) centred under the toast's slot, else under the score anyway.
func _place_objective(size: Vector2) -> Rect2:
	var gap := _hud.spacing_grid_px
	var left := Rect2(_objective_left.position, size)
	if _clear_of_bottom(left.grow(gap)):
		return left
	var right := Rect2(Vector2(camera.end.x - size.x, maxf(lives.end.y, high_beam.end.y) + gap), size)
	if _clear_of_bottom(right.grow(gap)) and not right.intersects(middle_column()):
		return right
	var centre := Rect2(Vector2(stack.get_center().x - size.x * 0.5, toast.end.y + gap), size)
	if _clear_of_bottom(centre.grow(gap)):
		return centre
	return left


func _clear_of_bottom(r: Rect2) -> bool:
	if not safe.encloses(r):
		return false
	for p: Rect2 in [min_speed, speedo, boost]:
		if r.intersects(p):
			return false
	return not _hits(r, _hud.pedal_clearance_px)


## The middle third of the safe width: the bottom panels stay out of it (the
## top-centre readouts live at its top).
func middle_column() -> Rect2:
	var w := safe.size.x / 3.0
	return Rect2(Vector2(safe.position.x + w, safe.position.y), Vector2(w, safe.size.y))


func _clear_of_top(r: Rect2) -> bool:
	if not safe.encloses(r):
		return false
	for top: Rect2 in [score, sun, chain, stack, lives, pause, camera, high_beam, toast]:
		if r.intersects(top):
			return false
	return true


func _hits(r: Rect2, clear: float) -> bool:
	for p in pedals:
		if p.grow(clear).intersects(r):
			return true
	return false


## The union of the controls on one side of the screen (by centre).
func _side_block(left: bool) -> Rect2:
	var cx := safe.get_center().x
	var out := Rect2()
	var any := false
	for p in pedals:
		if (p.get_center().x < cx) != left:
			continue
		out = p if not any else out.merge(p)
		any = true
	return out
