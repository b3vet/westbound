class_name HudSpeedo
extends HudWidget
## The speedometer, bottom-left. Spec: UI → HUD elements ("Bottom-left: speed");
## Design system (faceted panel, neon edge, speed tilt, tabular numbers, Chakra Petch).
##
## A big tabular speed (km/h or mph, the units setting) in a fixed three-digit slot,
## the gear, and a ramp of slanted segments filling with speed: accent up to the car's
## top speed, gold in the boost headroom above it, hot while TOO SLOW. Redraws only
## when the shown number, the lit segment count, the gear or a state flag changes.

const UNIT_KMH := "KM/H"
const UNIT_MPH := "MPH"
const LABEL_GEAR := "GEAR"
const SLOT_DIGITS := "000"

var _value: int = -1
var _text: String = ""
var _lit: int = -1
var _hi_from: int = 0
var _gear: int = 0
var _gear_text: String = ""
var _miles: bool = false
var _too_slow: bool = false
var _boosting: bool = false


func speed_text() -> String:
	return _text


func lit_segments() -> int:
	return _lit


## value: the shown speed; frac: speed / the bar's full scale; boost_from: the share of
## the bar above which the boost headroom starts.
func set_speed(value: int, frac: float, boost_from: float) -> void:
	var n := maxi(1, style.tuning.speed_bar_segments)
	var lit := clampi(roundi(frac * float(n)), 0, n)
	var hi := clampi(floori(boost_from * float(n)), 0, n)
	if value == _value and lit == _lit and hi == _hi_from:
		return
	if value != _value:
		_value = value
		_text = str(value)
		_text_changed()
	if lit != _lit or hi != _hi_from:
		_lit = lit
		_hi_from = hi
		changes += 1
		_plate_redraw()


func set_units(miles: bool) -> void:
	if miles == _miles:
		return
	_miles = miles
	_value_changed()


## 0 = unknown (hidden until the first gear_shifted).
func set_gear(gear: int) -> void:
	if gear == _gear:
		return
	_gear = gear
	_gear_text = str(gear) if gear > 0 else ""
	_value_changed()


func set_flags(too_slow: bool, boosting: bool) -> void:
	if too_slow == _too_slow and boosting == _boosting:
		return
	_too_slow = too_slow
	_boosting = boosting
	_value_changed()


func _paint_plate(m: HudMesh) -> void:
	var s := style
	var t := s.tuning
	var edge := s.hot if _too_slow else (s.gold if _boosting else s.edge_idle)
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, edge, s.edge_w)
	m.rect(Rect2(Vector2(s.bevel_panel + s.edge_w, s.edge_w), t.accent_tab_size_px), s.accent)
	if not _gear_text.is_empty():
		m.panel(_gear_box(), s.bevel_control, Color(s.ink, 1.0), s.accent, s.edge_w)
	var pad := s.px(t.panel_padding_px)
	var bh := s.px(t.speed_bar_height_px)
	var bar := Rect2(Vector2(pad, size.y - pad - bh), Vector2(size.x - pad * 2.0, bh))
	m.segments(bar, maxi(1, t.speed_bar_segments), s.px(t.segment_gap_px),
			Units.pct_to_frac(t.speed_bar_ramp_min_pct), Units.pct_to_frac(t.segment_lean_pct), _lit,
			s.hot if _too_slow else s.accent, s.gold, _hi_from, Color(s.muted, OFF_ALPHA))


func _gear_box() -> Rect2:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	var gs := HudDraw.cap_height(s.size_score) + pad
	return Rect2(Vector2(size.x - pad - gs, pad), Vector2(gs, gs))


## Text grouped by font: the 600 labels, then the 700 numbers.
func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	# The number, right-aligned in a fixed three-digit slot so it never jumps.
	var cell := s.digit_cell(s.display, s.size_speed)
	var slot := HudDraw.number_width(s.display, SLOT_DIGITS, s.size_speed, cell)
	var w := HudDraw.number_width(s.display, _text, s.size_speed, cell)
	var base := pad + HudDraw.cap_height(s.size_speed)
	HudDraw.text(self, s.label, Vector2(pad + slot + gap, base), UNIT_MPH if _miles else UNIT_KMH,
			s.size_label, s.muted)
	var box := _gear_box()
	if not _gear_text.is_empty():
		var lw := HudDraw.text_width(s.label, LABEL_GEAR, s.size_label)
		HudDraw.text(self, s.label, Vector2(box.position.x - gap - lw, box.get_center().y
				+ HudDraw.cap_height(s.size_label) * 0.5), LABEL_GEAR, s.size_label, s.muted)
	HudDraw.number(self, s.display, Vector2(pad + slot - w, base), _text, s.size_speed, cell,
			s.hot if _too_slow else s.text)
	if not _gear_text.is_empty():
		var gcell := s.digit_cell(s.display, s.size_score)
		var gw := HudDraw.number_width(s.display, _gear_text, s.size_score, gcell)
		HudDraw.number(self, s.display, Vector2(box.get_center().x - gw * 0.5,
				box.get_center().y + HudDraw.cap_height(s.size_score) * 0.5), _gear_text, s.size_score,
				gcell, s.text)


const OFF_ALPHA := 0.22   # lint: allow-number unlit segment (design: faint)
