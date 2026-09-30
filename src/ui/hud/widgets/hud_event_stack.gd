class_name HudEventStack
extends HudWidget
## The event message stack under the chain. Spec: Scoring → Score feedback ("each
## event pops a short label with its points (PASS, CLOSE!, CUT, THREAD!, HESITATED)
## in a stack of 4 lines that slide and fade"); Accessibility (every event has its own
## word: color is never the only cue); Design system (speed tilt on celebrations).
##
## Newest line on top; older lines slide down one row and dim. A line pops in from
## the left, holds, then fades; a new line past the limit pushes the oldest out.
## Storage is sized once (event_stack_lines); strings are built per event, never
## per frame. Redraws only while a line slides or fades. Reduced motion (WP9.3): lines
## fade in and out where they stand (no pop from the left, no slide down a row).

enum Role { TEXT, ACCENT, GOLD, HOT }

## WP5.2: hidden while the leg toast holds this slot. Lines still arrive and age (the
## Hud keeps animating the stack), so none shows up stale when the toast ends.
var muted: bool = false:
	set(value):
		muted = value
		visible = not value and _n > 0

var _n: int = 0
var _cap: int = 0
var _word := PackedStringArray()
var _pts := PackedStringArray()
var _role := PackedInt32Array()
var _age := PackedFloat64Array()
var _row := PackedFloat64Array()


func _restyled() -> void:
	var cap := maxi(1, style.tuning.event_stack_lines)
	if cap == _cap:
		return
	_cap = cap
	_word.resize(cap)
	_pts.resize(cap)
	_role.resize(cap)
	_age.resize(cap)
	_row.resize(cap)
	_n = mini(_n, cap)


## Adds a line on top: `word` ("CLOSE!") and `points` ("+1,450", or "").
func push(word: String, points: String, role: Role) -> void:
	if _cap == 0:
		return
	var last := mini(_n, _cap - 1)
	for i in range(last, 0, -1):
		_word[i] = _word[i - 1]
		_pts[i] = _pts[i - 1]
		_role[i] = _role[i - 1]
		_age[i] = _age[i - 1]
		_row[i] = _row[i - 1]
	_word[0] = word
	_pts[0] = points
	_role[0] = role
	_age[0] = 0.0
	_row[0] = 0.0
	_n = mini(_n + 1, _cap)
	if style != null and style.reduced_motion:
		for i in _n:
			_row[i] = float(i)   # WP9.3: older lines take their new row at once
	changes += 1
	visible = not muted
	queue_redraw()


func _has_plate() -> bool:
	return false


func line_count() -> int:
	return _n


## "CLOSE! +1,450" for line i (0 = newest).
func line_text(i: int) -> String:
	if i < 0 or i >= _n:
		return ""
	return _word[i] if _pts[i].is_empty() else "%s %s" % [_word[i], _pts[i]]


func clear() -> void:
	_n = 0
	visible = false


func settle_motion() -> void:
	for i in _n:
		_row[i] = float(i)
	super.settle_motion()


## The largest pop (px) or slide (px) of a line now (tests, WP9.3).
func motion_amount() -> float:
	var m := super.motion_amount()
	if style == null:
		return m
	var t := style.tuning
	for i in _n:
		var pop := clampf(_age[i] / maxf(t.event_slide_s, 1e-6), 0.0, 1.0)   # lint: allow-number divide guard
		var pop_px := 0.0 if style.reduced_motion else style.px(t.event_pop_px) * (1.0 - pop) * (1.0 - pop)
		m = maxf(m, pop_px + absf(_row[i] - float(i)) * style.px(t.event_line_height_px))
	return m


func animate(dt: float) -> bool:
	if _n == 0:
		return false
	var t := style.tuning
	var life := t.event_hold_s + t.event_fade_s
	var moving := false
	var step := dt / maxf(t.event_slide_s, dt)
	for i in _n:
		_age[i] += dt
		if _row[i] != float(i):
			# WP9.3: with reduced motion a line takes its new row at once (no slide).
			_row[i] = float(i) if style.reduced_motion else move_toward(_row[i], float(i), step)
			moving = true
		if _age[i] - dt < t.event_slide_s or _age[i] > t.event_hold_s:
			moving = true
	while _n > 0 and _age[_n - 1] >= life:
		_n -= 1
	if _n == 0:
		visible = false
		return false
	if moving:
		queue_redraw()
	return moving


## Two passes (every outline, then every fill) so all glyphs batch into two draws.
func _paint() -> void:
	_paint_pass(true)
	_paint_pass(false)


func _paint_pass(outlines: bool) -> void:
	var s := style
	var t := s.tuning
	var line_h := s.px(t.event_line_height_px)
	var gap := s.px(t.spacing_grid_px)
	var cell := s.digit_cell(s.display, s.size_event)
	var cap := HudDraw.cap_height(s.size_event)
	var rid := get_canvas_item()
	for i in _n:
		var a := _alpha(i, t)
		if a <= 0.0:
			continue
		var pop := clampf(_age[i] / maxf(t.event_slide_s, 1e-6), 0.0, 1.0)   # lint: allow-number divide guard
		var ease_in := 1.0 - (1.0 - pop) * (1.0 - pop)
		var word := _word[i]
		var pts := _pts[i]
		var ww := HudDraw.text_width(s.display, word, s.size_event)
		var pw := 0.0 if pts.is_empty() else HudDraw.number_width(s.display, pts, s.size_event, cell) + gap
		var pop_px := 0.0 if s.reduced_motion else s.px(t.event_pop_px) * (1.0 - ease_in)
		var x := (size.x - ww - pw) * 0.5 - pop_px
		var y := _row[i] * line_h + line_h * 0.5 + cap * 0.5
		if outlines:
			var o := Color(s.outline, s.outline.a * a)
			var sh := HudDraw.shadow_offset(s.size_event)
			s.display.draw_string(rid, Vector2(x, y) + sh, word, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s.size_event, o)
			if not pts.is_empty():
				HudDraw.glyphs(rid, s.display, Vector2(x + ww + gap, y) + sh, pts, s.size_event, cell, o, 0)
			s.display.draw_string_outline(rid, Vector2(x, y), word, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
					s.size_event, s.outline_px, o)
			if not pts.is_empty():
				HudDraw.glyphs(rid, s.display, Vector2(x + ww + gap, y), pts, s.size_event, cell, o, s.outline_px)
		else:
			s.display.draw_string(rid, Vector2(x, y), word, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s.size_event,
					Color(_color(_role[i]), a))
			HudDraw.note(self, Vector2(x, y), ww, s.size_event, word)
			if not pts.is_empty():
				HudDraw.glyphs(rid, s.display, Vector2(x + ww + gap, y), pts, s.size_event, cell,
						Color(s.text, a), 0)
				HudDraw.note(self, Vector2(x + ww + gap, y), pw - gap, s.size_event, pts)


func _alpha(i: int, t: HudTuning) -> float:
	var a := 1.0 - Units.pct_to_frac(t.event_age_dim_pct) * _row[i]
	var age := _age[i]
	if age < t.event_slide_s:
		a *= age / t.event_slide_s
	elif age > t.event_hold_s:
		a *= 1.0 - (age - t.event_hold_s) / maxf(t.event_fade_s, 1e-6)   # lint: allow-number divide guard
	return clampf(a, 0.0, 1.0)


func _color(role: int) -> Color:
	match role:
		Role.ACCENT:
			return style.accent
		Role.GOLD:
			return style.gold
		Role.HOT:
			return style.hot
	return style.text
