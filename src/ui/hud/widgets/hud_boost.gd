class_name HudBoost
extends HudWidget
## The boost meter, beside the speedometer in the bottom-centre cluster (plan D14; the
## spec's "Bottom-right: boost meter" moved off the gas thumb). Spec: Scoring → Boost
## ("The boost meter fills from slipstream, close passes and threads. Full meter = 3
## seconds of extra thrust"); UI → HUD elements.
##
## Slanted segments fill with the meter; READY in the accent when full; while boost
## burns the segments turn gold and pulse (steady with reduced motion, WP9.3), and the
## label reads BOOSTING. Redraws only
## when the lit segment count, the percentage or the state changes, or while boosting.

const LABEL_BOOST := "BOOST"
const LABEL_READY := "READY"
const LABEL_BOOSTING := "BOOSTING"
const PERCENT := "%"

var _lit: int = -1
var _pct: int = -1
var _pct_text: String = ""
var _boosting: bool = false
var _full: bool = false
var _clock: float = 0.0


func lit_segments() -> int:
	return _lit


func pulsing() -> bool:
	return _boosting


## Boost started or ended (Events.boost_started / boost_ended): the gold BOOSTING state
## shows in the frame of the event, before the HUD next reads the feed (WP7.5).
func set_boosting(on: bool) -> void:
	if on == _boosting or _lit < 0:
		return
	_boosting = on
	_clock = 0.0
	_value_changed()


func set_fill(fill: float, boosting: bool) -> void:
	var f := clampf(fill, 0.0, 1.0)
	var n := maxi(1, style.tuning.boost_bar_segments)
	var lit := clampi(ceili(f * float(n) - LIT_EPS), 0, n)
	var pct := roundi(f * Units.PCT)
	var full := f >= 1.0
	if lit == _lit and pct == _pct and boosting == _boosting and full == _full:
		return
	var shapes := lit != _lit or boosting != _boosting or full != _full
	if pct != _pct:
		_pct = pct
		_pct_text = str(pct) + PERCENT
	if boosting != _boosting:
		_clock = 0.0
	_lit = lit
	_boosting = boosting
	_full = full
	if shapes:
		_value_changed()
	else:
		_text_changed()


func animate(dt: float) -> bool:
	if not _boosting or style.reduced_motion:
		return false
	_clock += dt
	_plate_redraw()
	return true


func _paint_plate(m: HudMesh) -> void:
	var s := style
	var t := s.tuning
	var pulse := _pulse()
	var edge := s.gold if _boosting else (s.accent if _full else s.edge_idle)
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, edge, s.edge_w)
	m.rect(Rect2(Vector2(size.x - s.bevel_panel - s.edge_w - t.accent_tab_size_px.x, s.edge_w),
			t.accent_tab_size_px), s.accent)
	var pad := s.px(t.panel_padding_px)
	var bh := s.px(t.boost_bar_height_px)
	var bar := Rect2(Vector2(pad, size.y - s.px(t.spacing_grid_px) - bh), Vector2(size.x - pad * 2.0, bh))
	var lit := Color(s.gold, pulse) if _boosting else s.accent
	var n := maxi(1, t.boost_bar_segments)
	m.segments(bar, n, s.px(t.segment_gap_px), 1.0, Units.pct_to_frac(t.segment_lean_pct), _lit,
			lit, lit, n, Color(s.muted, OFF_ALPHA))


## Pulse depth now (tests, WP9.3).
func motion_amount() -> float:
	return super.motion_amount() + (1.0 - _pulse())


func _pulse() -> float:
	if not _boosting or style.reduced_motion:
		return 1.0
	return lerpf(PULSE_MIN, 1.0, 0.5 + 0.5 * cos(TAU * style.tuning.boost_pulse_hz * _clock))


## The label on the left (BOOST, or BOOSTING in gold); the percentage or READY on the
## right (nothing while boosting: the compact plate has room for one long word).
func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var base := s.px(t.spacing_grid_px) + HudDraw.cap_height(s.size_small)
	if _boosting:
		HudDraw.text(self, s.label, Vector2(pad, base), LABEL_BOOSTING, s.size_small, s.gold)
		return
	HudDraw.text(self, s.label, Vector2(pad, base), LABEL_BOOST, s.size_small, s.text)
	if not _full:
		var cell := s.digit_cell(s.body, s.size_small)
		var w := HudDraw.number_width(s.body, _pct_text, s.size_small, cell)
		HudDraw.number(self, s.body, Vector2(size.x - pad - w, base), _pct_text, s.size_small, cell, s.muted)
		return
	var rw := HudDraw.text_width(s.label, LABEL_READY, s.size_label)
	HudDraw.text(self, s.label, Vector2(size.x - pad - rw, base), LABEL_READY, s.size_label, s.accent)


const PULSE_MIN := 0.55   # lint: allow-number pulse floor
const OFF_ALPHA := 0.22   # lint: allow-number unlit segment (design: faint)
## A fill a hair under a segment boundary still lights it (float noise).
const LIT_EPS := 1e-6   # lint: allow-number float noise
