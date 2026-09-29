class_name HudMultiplier
extends HudWidget
## The multiplier readout, right of the chain. Spec: Scoring → Multiplier ("the HUD
## shows up to 999×"); Score feedback ("hue-cycles faster as it grows and wobbles
## above 20×"); Design system (speed tilt).
##
## The text redraws only when the shown value (tenths) changes. The hue cycle is the
## item's self_modulate and the wobble its rotation: per-frame property writes, no
## redraw, and none at all at 1.0× (idle).

var _key: int = -1
var _m: float = 1.0
var _text: String = ""
var _phase: float = 0.0
var _clock: float = 0.0


func set_multiplier(m: float) -> void:
	_m = m
	var t := style.tuning
	var key := HudFormat.multiplier_key(m, t.multiplier_decimals_below, t.multiplier_display_max)
	if key == _key:
		return
	_key = key
	_text = HudFormat.multiplier_text(key, t.multiplier_decimals_below)
	_value_changed()


func _has_plate() -> bool:
	return false


func multiplier_text() -> String:
	return _text


## Turns per second of the hue cycle at multiplier m (0 at 1.0×).
static func hue_hz(t: HudTuning, m: float) -> float:
	if m <= 1.0:
		return 0.0
	return minf(t.mult_hue_hz_base + t.mult_hue_hz_per_x * (m - 1.0), t.mult_hue_hz_max)


## Wobble amplitude (radians) at multiplier m (0 at or below the wobble threshold).
static func wobble_rad(t: HudTuning, m: float) -> float:
	if m <= t.multiplier_wobble_above:
		return 0.0
	var k := clampf((m - t.multiplier_wobble_above) / maxf(t.mult_wobble_full_at - t.multiplier_wobble_above, 1.0), 0.0, 1.0)
	return deg_to_rad(t.mult_wobble_deg) * k


func animate(dt: float) -> bool:
	var t := style.tuning
	var hz := hue_hz(t, _m)
	if hz <= 0.0:
		if self_modulate != style.muted:
			self_modulate = style.muted
			rotation = 0.0
		return false
	_phase = fposmod(_phase + hz * dt, 1.0)
	self_modulate = Color.from_hsv(fposmod(_phase + style.gold.h, 1.0),
			Units.pct_to_frac(t.mult_hue_saturation_pct), 1.0)
	var amp := wobble_rad(t, _m)
	if amp > 0.0:
		_clock += dt
		rotation = amp * sin(TAU * t.mult_wobble_hz * _clock)
	elif rotation != 0.0:
		rotation = 0.0
	return false


func _paint() -> void:
	var s := style
	var cell := s.digit_cell(s.display, s.size_readout)
	var y := size.y * 0.5 + HudDraw.cap_height(s.size_readout) * 0.5
	HudDraw.number(self, s.display, Vector2(0.0, y), _text, s.size_readout, cell, Color.WHITE,
			s.outline_px, s.outline)
