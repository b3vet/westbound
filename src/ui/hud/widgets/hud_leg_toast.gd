class_name HudLegToast
extends HudWidget
## The leg summary toast. Spec: Core loop -> Legs and checkpoints (crossing step 5: "a
## 2.5-second leg summary toast that does not pause play"; leg bonuses Clean, Pace,
## Threads, Heat, "Night doubles them"; the leg objective); UI -> Screens ("Leg summary:
## a non-blocking toast"); HUD layout (the middle third stays clear). docs/HUD.md.
##
##   LEG 2 COMPLETE                          BANKED +48,200
##   NIGHT ×2   CLEAN +10,000   PACE +6,000   OBJECTIVE +5,000
##   LIFE RESTORED
##   ─────────────────────────────────────────────────────
##   LEG 3 — FARMLAND                        5 CLOSE PASSES
##
## It sits in the event stack's slot under the chain (the Hud mutes the stack while it
## shows), takes no touches, and lasts hud.leg_toast_s: a fade in, a hold, a fade out
## (modulate only, so it draws once per crossing). The Hud fills it from the events of
## the crossing: begin() on checkpoint_crossed, then the bonuses, the banked chain, the
## life and the next leg as they arrive in the same frame. One plate + two fonts
## (display title, label for the rest) = three draw calls.

enum Role { TEXT, ACCENT, GOLD }

const TITLE := "LEG %d COMPLETE"
const WORD_BANKED := "BANKED"
const NEXT := "LEG %d — %s"
const NEXT_PLAIN := "LEG %d"
## N3.2 loop mode: sector gantries (a crossing's leg index is lap × sectors + gantry + 1;
## crossing gantry k ends sector k, gantry 0 ends the lap).
const TITLE_SECTOR := "SECTOR %d COMPLETE"
const TITLE_LAP := "LAP %d COMPLETE"
const NEXT_SECTOR := "SECTOR %d — %s"
const NEXT_SECTOR_PLAIN := "SECTOR %d"
## Most items it lists (night, four leg bonuses, objective, journey, life).
const MAX_ITEMS := 8

var _title: String = ""
var _banked: String = ""
var _next: String = ""
var _next_short: String = ""
var _next_objective: String = ""
# The footer as it fits (_fit_footer): texts and font sizes.
var _foot_next: String = ""
var _foot_objective: String = ""
var _foot_next_size: int = 0
var _foot_objective_size: int = 0
var _n: int = 0
var _word := PackedStringArray()
var _pts := PackedStringArray()
var _role := PackedInt32Array()
var _t: float = -1.0
## N3.2: sector gantries per lap in loop mode (0 = legs, the journey).
var loop_sectors: int = 0


func _init() -> void:
	super._init()
	_word.resize(MAX_ITEMS)
	_pts.resize(MAX_ITEMS)
	_role.resize(MAX_ITEMS)


## A new crossing: clears the card and shows it (from transparent).
func begin(leg_index: int) -> void:
	if loop_sectors > 0:
		var gantry := posmod(leg_index - 1, loop_sectors)
		var lap := floori(float(leg_index - 1) / float(loop_sectors))
		_title = TITLE_LAP % (lap - 1) if gantry == 0 else TITLE_SECTOR % gantry
	else:
		_title = TITLE % leg_index
	_banked = ""
	_next = ""
	_next_objective = ""
	_n = 0
	_t = 0.0
	modulate.a = 0.0
	visible = true
	_value_changed()


## One listed item: `word` ("CLEAN") with `points` ("+10,000", or "" for a tag).
func add_item(word: String, points: String, role: Role) -> void:
	if _n >= MAX_ITEMS:
		return
	_word[_n] = word
	_pts[_n] = points
	_role[_n] = role
	_n += 1
	_text_changed()


func has_item(word: String) -> bool:
	for i in _n:
		if _word[i] == word:
			return true
	return false


func set_banked(points: String) -> void:
	_banked = points
	_text_changed()


## The next leg: "LEG 3 — FARMLAND" and its objective's text ("" = none).
func set_next(leg_index: int, place: String, objective: String) -> void:
	if loop_sectors > 0:
		var sector := posmod(leg_index - 2, loop_sectors) + 1
		_next_short = NEXT_SECTOR_PLAIN % sector
		_next = NEXT_SECTOR % [sector, place] if not place.is_empty() else _next_short
	else:
		_next_short = NEXT_PLAIN % leg_index
		_next = NEXT % [leg_index, place] if not place.is_empty() else _next_short
	_next_objective = objective
	_value_changed()


## Hides it at once (a new run).
func dismiss() -> void:
	_t = -1.0
	visible = false


func showing() -> bool:
	return _t >= 0.0


## The card's lines as shown (tests): title, banked, items..., next leg, next objective.
func lines() -> PackedStringArray:
	var out := PackedStringArray([_title])
	if not _banked.is_empty():
		out.append("%s %s" % [WORD_BANKED, _banked])
	for i in _n:
		out.append(_word[i] if _pts[i].is_empty() else "%s %s" % [_word[i], _pts[i]])
	if not _next.is_empty():
		out.append(_next)
	if not _next_objective.is_empty():
		out.append(_next_objective)
	return out


## Items that fit the rows (the rest are dropped; tests check the worst case fits).
func items_shown() -> int:
	return _flow(false) if style != null else 0


func animate(dt: float) -> bool:
	if _t < 0.0:
		return false
	var t := style.tuning
	_t += dt
	var total := t.leg_toast_s
	if _t >= total:
		_t = -1.0
		visible = false
		return false
	var a := 1.0
	if _t < t.leg_toast_in_s:
		a = _t / maxf(t.leg_toast_in_s, EPS)
	elif _t > total - t.leg_toast_out_s:
		a = (total - _t) / maxf(t.leg_toast_out_s, EPS)
	modulate.a = clampf(a, 0.0, 1.0)
	return false


func _paint_plate(m: HudMesh) -> void:
	var s := style
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, s.gold, s.edge_w)
	m.rect(Rect2(Vector2(s.bevel_panel + s.edge_w, s.edge_w), s.tuning.accent_tab_size_px), s.accent)
	var pad := s.px(s.tuning.panel_padding_px)
	var y := _separator_y()
	m.rect(Rect2(pad, y, size.x - pad * 2.0, s.edge_w * 0.5), s.edge_idle)


func _separator_y() -> float:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	var gap := s.px(s.tuning.spacing_grid_px)
	return size.y - pad - HudDraw.cap_height(s.size_small) - gap


## Title in the display font; everything else in the label font (one batch each).
func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	var right := size.x - pad
	var y_title := pad + HudDraw.cap_height(s.size_event)
	HudDraw.text(self, s.display, Vector2(pad, y_title), _title, s.size_event, s.text)
	var cell := s.digit_cell(s.label, s.size_small)
	# Banked (header, right).
	if not _banked.is_empty():
		var wn := HudDraw.number_width(s.label, _banked, s.size_small, cell)
		var ww := HudDraw.text_width(s.label, WORD_BANKED, s.size_label)
		HudDraw.number(self, s.label, Vector2(right - wn, y_title), _banked, s.size_small, cell, s.gold)
		HudDraw.text(self, s.label, Vector2(right - wn - gap * 0.5 - ww, y_title), WORD_BANKED, s.size_label, s.muted)
	_flow(true)
	_fit_footer()
	var y_next := size.y - pad
	if not _foot_next.is_empty():
		HudDraw.text(self, s.label, Vector2(pad, y_next), _foot_next, _foot_next_size, s.text)
	if not _foot_objective.is_empty():
		var wo := HudDraw.text_width(s.label, _foot_objective, _foot_objective_size)
		HudDraw.text(self, s.label, Vector2(right - wo, y_next), _foot_objective, _foot_objective_size, s.accent)


## The footer as drawn (tests): the next leg ("LEG 3 — FARMLAND PLAINS") and its
## objective ("" when it did not fit).
func footer() -> PackedStringArray:
	if style == null:
		return PackedStringArray([_next, _next_objective])
	_fit_footer()
	return PackedStringArray([_foot_next, _foot_objective])


## Next leg (footer): "LEG 3 — FARMLAND PLAINS" left, its objective right. When both
## don't fit, the leg drops to the label size, then the objective does, then the
## objective goes (the objective chip shows it too). The place name stays (WP5.6: it
## used to go first, so most legs read just "LEG 4"); only a name too long for the card
## on its own falls back to "LEG 4".
func _fit_footer() -> void:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	var gap := s.px(s.tuning.spacing_grid_px)
	var inner := size.x - pad * 2.0
	_foot_next = _next
	_foot_objective = _next_objective
	_foot_next_size = s.size_small
	_foot_objective_size = s.size_small
	var wl := HudDraw.text_width(s.label, _foot_next, _foot_next_size)
	var wo := HudDraw.text_width(s.label, _foot_objective, _foot_objective_size) if not _foot_objective.is_empty() else 0.0
	if wo > 0.0 and wl + gap + wo > inner:
		_foot_next_size = s.size_label
		wl = HudDraw.text_width(s.label, _foot_next, _foot_next_size)
	if wo > 0.0 and wl + gap + wo > inner:
		_foot_objective_size = s.size_label
		wo = HudDraw.text_width(s.label, _foot_objective, _foot_objective_size)
	if wo > 0.0 and wl + gap + wo > inner:
		_foot_objective = ""
		_foot_next_size = s.size_small
		wl = HudDraw.text_width(s.label, _foot_next, _foot_next_size)
	if wl > inner:
		_foot_next_size = s.size_label
		wl = HudDraw.text_width(s.label, _foot_next, _foot_next_size)
	if wl > inner:
		_foot_next = _next_short


## Lays the items out left to right over leg_toast_item_rows rows (drawing them when
## `paint`); returns how many fit.
func _flow(paint: bool) -> int:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	var right := size.x - pad
	var cell := s.digit_cell(s.label, s.size_small)
	var row_h := HudDraw.cap_height(s.size_small) + gap
	var x := pad
	var row := 0
	var y := pad + HudDraw.cap_height(s.size_event) + gap + HudDraw.cap_height(s.size_small)
	var shown := 0
	for i in _n:
		var word := _word[i]
		var pts := _pts[i]
		var ww := HudDraw.text_width(s.label, word, s.size_label)
		var wp := 0.0 if pts.is_empty() else HudDraw.number_width(s.label, pts, s.size_small, cell) + gap * 0.5
		if x > pad and x + ww + wp > right:
			row += 1
			x = pad
			y += row_h
		if row >= t.leg_toast_item_rows:
			break
		if paint:
			var c := _color(_role[i])
			HudDraw.text(self, s.label, Vector2(x, y), word, s.size_label, c if pts.is_empty() else s.muted)
			if not pts.is_empty():
				HudDraw.number(self, s.label, Vector2(x + ww + gap * 0.5, y), pts, s.size_small, cell, c)
		x += ww + wp + gap * 2.0
		shown += 1
	return shown


func _color(role: int) -> Color:
	match role:
		Role.ACCENT:
			return style.accent
		Role.GOLD:
			return style.gold
	return style.text


const EPS := 1e-6   # lint: allow-number divide guard
