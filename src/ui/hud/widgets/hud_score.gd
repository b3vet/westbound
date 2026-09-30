class_name HudScore
extends HudWidget
## Top-left: the banked total and the personal best. Spec: UI → HUD elements
## ("Top-left: banked score and personal best"); Scoring → Chain and banking (the
## count-up lands here); Design system (gold = records).
##
## The banked number is what the Hud's count-up says; the edge turns gold while it
## counts. When the run beats the best, BEST shows the run's total in gold as NEW BEST.

const LABEL_BANKED := "BANKED"
const LABEL_BEST := "BEST"
const LABEL_NEW_BEST := "NEW BEST"
const NO_BEST := "—"

var _banked: int = 0
var _best: int = -1
var _counting: bool = false
var _banked_text: String = "0"
var _best_text: String = NO_BEST
var _new_best: bool = false


## The banked total shown now (the count-up's current value).
func shown_banked() -> int:
	return _banked


## Where the banked number sits (canvas), for the bank fly-in to aim at.
func number_target() -> Vector2:
	var pad := style.px(style.tuning.panel_padding_px) if style != null else 0.0
	return global_position + Vector2(pad, size.y * 0.5)


func set_banked(v: int) -> void:
	if v == _banked:
		return
	_banked = v
	_banked_text = HudFormat.thousands(v)
	_refresh_best()
	_text_changed()


func set_best(v: int) -> void:
	if v == _best:
		return
	_best = v
	_refresh_best()
	_value_changed()


func set_counting(on: bool) -> void:
	if on == _counting:
		return
	_counting = on
	_redraw_all()


func _refresh_best() -> void:
	_new_best = _best > 0 and _banked > _best
	var v := maxi(_best, _banked) if _new_best else _best
	_best_text = HudFormat.thousands(v) if v > 0 else NO_BEST


func _paint_plate(m: HudMesh) -> void:
	var s := style
	var edge := s.gold if _counting else s.edge_idle
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, edge, s.edge_w)
	m.rect(Rect2(Vector2(s.bevel_panel + s.edge_w, s.edge_w), s.tuning.accent_tab_size_px), s.accent)


## Text grouped by font (600 first, then 700) so the glyphs batch.
func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	var y_label := pad + HudDraw.cap_height(s.size_label)
	var y_score := y_label + gap + HudDraw.cap_height(s.size_score)
	var y_best := y_score + gap + HudDraw.cap_height(s.size_small)
	HudDraw.text(self, s.label, Vector2(pad, y_label), LABEL_BANKED, s.size_label, s.muted)
	var label := LABEL_NEW_BEST if _new_best else LABEL_BEST
	HudDraw.text(self, s.label, Vector2(pad, y_best), label, s.size_label,
			s.gold if _new_best else s.muted)
	var lw := HudDraw.text_width(s.label, label, s.size_label) + gap
	HudDraw.number(self, s.body, Vector2(pad + lw, y_best), _best_text, s.size_small,
			s.digit_cell(s.body, s.size_small), s.gold)
	HudDraw.number(self, s.display, Vector2(pad, y_score), _banked_text, s.size_score,
			s.digit_cell(s.display, s.size_score), s.gold if _counting else s.text)
