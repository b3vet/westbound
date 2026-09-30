class_name HudObjective
extends HudWidget
## The leg objective chip, under the score panel. Spec: Core loop -> Legs and
## checkpoints ("Each leg shows one optional objective on entry ... Completing it pays
## a bonus"); UI -> HUD elements (update rule: labels change only when their value
## changes, nothing animates when idle); Accessibility (color is never the only cue:
## a tick or FAILED as well as gold or hot). docs/HUD.md -> Leg objective and toast.
##
##   LEG 2 OBJECTIVE
##   <> 5 CLOSE PASSES                3/5
##
## WP5.6: the chip sizes itself to its content (content_width(); the Hud clamps it
## between objective_chip_size_px.x and objective_chip_max_width_px), so a long label
## ("5 S OF SLIPSTREAM") never runs into its progress ("0/5"). If a label still does not
## fit at the widest, its text drops to the label size (fits_text() says whether it did).
##
## A new objective pops in; progress redraws the text only when the count changes;
## completion turns the edge, text and icon gold with a tick; a broken "no X" objective
## shows FAILED in hot. Either way it holds objective_end_hold_s, then fades out and
## hides until the next leg's objective (reduced motion, WP9.3: no pop, the fade stays).
## The pop and fade are scale and modulate only
## (no redraws). One plate + one font (label) = two draw calls.

enum State { PENDING, DONE, FAILED }

const CAPTION := "LEG %d OBJECTIVE"
const WORD_FAILED := "FAILED"
const PROGRESS := "%d/%d"
const ICON_FACETS := 4
## The icon is a diamond (a square turned 45 degrees).
const ICON_ANGLE := PI * 0.25

var _key_leg: int = -1
var _key_id: StringName = &""
var _caption: String = ""
var _text: String = ""
var _progress: int = -1
var _target: int = -1
var _progress_text: String = ""
var _state: State = State.PENDING
var _pop_t: float = -1.0
var _end_t: float = -1.0


## Sets the leg's objective (&"" = none: hidden). `text` is its HUD label; a new leg or
## id restarts the chip (pop-in).
func set_objective(leg_index: int, id: StringName, text: String) -> void:
	if leg_index == _key_leg and id == _key_id and text == _text:
		return
	var fresh := leg_index != _key_leg or id != _key_id
	_key_leg = leg_index
	_key_id = id
	_text = text
	_caption = CAPTION % leg_index
	if fresh:
		_state = State.PENDING
		_progress = -1
		_target = -1
		_progress_text = ""
		_end_t = -1.0
		modulate.a = 1.0
		visible = id != &""
		if visible and style != null:
			_pop_t = 0.0
			scale = Vector2.ONE if style.reduced_motion \
					else Vector2.ONE * Units.pct_to_frac(style.tuning.objective_pop_from_pct)
	_value_changed()


## Progress as shown ("3/5"); target 0 = nothing to count (reach and "no X" objectives).
func set_progress(progress: int, target: int) -> void:
	if progress == _progress and target == _target:
		return
	_progress = progress
	_target = target
	_progress_text = PROGRESS % [mini(progress, target), target] if target > 0 else ""
	_text_changed()


func set_state(done: bool, failed: bool) -> void:
	var st := State.DONE if done else (State.FAILED if failed else State.PENDING)
	if st == _state:
		return
	_state = st
	_end_t = 0.0 if st != State.PENDING else -1.0
	modulate.a = 1.0
	_value_changed()


func objective_text() -> String:
	return _text


func progress_text() -> String:
	return _progress_text


func caption_text() -> String:
	return _caption


func state() -> State:
	return _state


## The width the chip needs to show its caption, icon, text and progress side by side
## (canvas px at the current text size). 0 without a style.
func content_width() -> float:
	if style == null:
		return 0.0
	return ceilf(maxf(_caption_right(), _text_x() + _text_width(style.size_small) + _tail_room()))


## The objective text is drawn at full size (false: it dropped to the label size).
func fits_text() -> bool:
	return style == null or _text_x() + _text_width(style.size_small) + _tail_room() <= size.x + EPS


func _tail() -> String:
	return WORD_FAILED if _state == State.FAILED else _progress_text


## Room the progress takes at the right: the text's gap, the progress, the padding.
func _tail_room() -> float:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	var tail := _tail()
	if tail.is_empty():
		return pad
	var cell := s.digit_cell(s.label, s.size_small)
	return s.px(s.tuning.spacing_grid_px) * 2.0 + HudDraw.number_width(s.label, tail, s.size_small, cell) + pad


func _text_x() -> float:
	var s := style
	return s.px(s.tuning.panel_padding_px) + _icon_radius() * 2.0 + s.px(s.tuning.spacing_grid_px)


func _text_width(font_size: int) -> float:
	return HudDraw.text_width(style.label, _text, font_size)


func _caption_right() -> float:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	return pad + HudDraw.text_width(s.label, _caption, s.size_label) + pad


func animate(dt: float) -> bool:
	var t := style.tuning
	if _pop_t >= 0.0:
		_pop_t += dt
		var k := clampf(_pop_t / maxf(t.objective_pop_s, EPS), 0.0, 1.0)
		var e := 1.0 - (1.0 - k) * (1.0 - k)
		var from := Units.pct_to_frac(t.objective_pop_from_pct)
		scale = Vector2.ONE if style.reduced_motion else Vector2.ONE * lerpf(from, 1.0, e)
		if k >= 1.0:
			_pop_t = -1.0
	if _end_t >= 0.0:
		_end_t += dt
		var fade := (_end_t - t.objective_end_hold_s) / maxf(t.objective_fade_s, EPS)
		if fade >= 1.0:
			_end_t = -1.0
			visible = false
			modulate.a = 1.0
		elif fade > 0.0:
			modulate.a = 1.0 - fade
	return false


func _update_pivot() -> void:
	super._update_pivot()
	pivot_offset = Vector2(0.0, size.y * 0.5)   # pops from its left edge (left-anchored)


func _icon_center() -> Vector2:
	var pad := style.px(style.tuning.panel_padding_px)
	var r := _icon_radius()
	return Vector2(pad + r, size.y - pad - HudDraw.cap_height(style.size_small) * 0.5)


func _icon_radius() -> float:
	return HudDraw.cap_height(style.size_small) * ICON_SIZE


func _paint_plate(m: HudMesh) -> void:
	var s := style
	var edge := s.edge_idle
	var icon := s.accent
	match _state:
		State.DONE:
			edge = s.gold
			icon = s.gold
		State.FAILED:
			edge = s.hot
			icon = s.hot
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, edge, s.edge_w)
	m.rect(Rect2(Vector2(s.bevel_panel + s.edge_w, s.edge_w), s.tuning.accent_tab_size_px), s.accent)
	var c := _icon_center()
	var r := _icon_radius()
	if _state == State.PENDING:
		m.ngon(c, r, ICON_FACETS, Color(icon, 0.0), icon, s.edge_w, ICON_ANGLE)
		return
	m.ngon(c, r, ICON_FACETS, icon, icon, s.edge_w * 0.5, ICON_ANGLE)
	var w := s.edge_w * 1.5
	if _state == State.DONE:
		# A tick in ink on the gold diamond.
		m.line(c + Vector2(-r * 0.45, 0.0), c + Vector2(-r * 0.1, r * 0.35), w, s.ink)
		m.line(c + Vector2(-r * 0.1, r * 0.35), c + Vector2(r * 0.45, -r * 0.35), w, s.ink)
	else:
		# A cross.
		var k := r * 0.35
		m.line(c + Vector2(-k, -k), c + Vector2(k, k), w, s.ink)
		m.line(c + Vector2(-k, k), c + Vector2(k, -k), w, s.ink)


## One font (label): caption, text and progress, so the glyphs batch into one draw.
func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var y_cap := pad + HudDraw.cap_height(s.size_label)
	var y_text := size.y - pad
	HudDraw.text(self, s.label, Vector2(pad, y_cap), _caption, s.size_label, s.muted)
	var x := _text_x()
	var right := size.x - pad
	var tail := _tail()
	var tail_color := s.accent
	match _state:
		State.DONE:
			tail_color = s.gold
		State.FAILED:
			tail_color = s.hot
	var text_color := s.text
	if _state == State.DONE:
		text_color = s.gold
	elif _state == State.FAILED:
		text_color = s.muted
	var text_size := s.size_small if fits_text() else s.size_label
	HudDraw.text(self, s.label, Vector2(x, y_text), _text, text_size, text_color)
	if tail.is_empty():
		return
	var cell := s.digit_cell(s.label, s.size_small)
	var w := HudDraw.number_width(s.label, tail, s.size_small, cell)
	HudDraw.number(self, s.label, Vector2(right - w, y_text), tail, s.size_small, cell, tail_color)


const EPS := 1e-6   # lint: allow-number divide guard
## Icon radius per cap height of the objective text.
const ICON_SIZE := 0.75   # lint: allow-number icon proportion
