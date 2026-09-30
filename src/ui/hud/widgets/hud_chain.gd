class_name HudChain
extends HudWidget
## The unbanked chain, top-centre under the sun bar (left of the multiplier). Spec:
## Scoring → Chain and banking ("shown big at the top center"); Design system (speed
## tilt on the chain readout). Pulses on every scored event (a scale pop, no redraw).
##
## Drawn right-aligned to its rect's right edge, so the chain and the multiplier meet
## at the screen's centre line. The CHAIN label sits left of the number; a number too
## long for both (millions at the tuned row width) shows alone (WP5.6: nothing is drawn
## outside the widget).

const LABEL_CHAIN := "CHAIN"

var _value: int = -1
var _text: String = ""
var _pulse_t: float = -1.0
## Pulses started (tests: WP7.5's one-frame check reads it right after the drain).
var pulses: int = 0


func set_chain(v: int) -> void:
	if v == _value:
		return
	_value = v
	_text = HudFormat.thousands(v)
	_value_changed()


func chain_text() -> String:
	return _text


## Where the chain number sits (canvas), for the bank fly-out to start from.
func number_center() -> Vector2:
	return global_position + Vector2(size.x * 0.75, size.y * 0.5)


func _has_plate() -> bool:
	return false


func pulse() -> void:
	_pulse_t = 0.0
	pulses += 1


func animate(dt: float) -> bool:
	if _pulse_t < 0.0:
		return false
	var dur := style.tuning.chain_pulse_s
	_pulse_t += dt
	if _pulse_t >= dur:
		_pulse_t = -1.0
		scale = Vector2.ONE
		return false
	var k := sin(PI * _pulse_t / dur)
	scale = Vector2.ONE * (1.0 + Units.pct_to_frac(style.tuning.chain_pulse_scale_pct) * k)
	return true


func _paint() -> void:
	var s := style
	var cell := s.digit_cell(s.display, s.size_readout)
	var w := HudDraw.number_width(s.display, _text, s.size_readout, cell)
	var y := size.y * 0.5 + HudDraw.cap_height(s.size_readout) * 0.5
	var x := size.x - w
	var gap := s.px(s.tuning.spacing_grid_px)
	var lw := HudDraw.text_width(s.label, LABEL_CHAIN, s.size_label)
	if x - gap - lw >= 0.0:
		HudDraw.text(self, s.label, Vector2(x - gap - lw, y), LABEL_CHAIN, s.size_label, s.text,
				s.outline_px, s.outline)
	HudDraw.number(self, s.display, Vector2(x, y), _text, s.size_readout, cell, s.text,
			s.outline_px, s.outline)
