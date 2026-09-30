class_name HudFlyer
extends HudWidget
## The banked chain flying into the banked total. Spec: Scoring → Score feedback
## ("Banking animation. The chain flies into the banked total with a count-up and a
## chime"); Design system (speed tilt on celebrations). The count-up itself is the
## Hud's (it starts when the flyer lands). Hidden (not drawn) when not flying.
## Reduced motion (WP9.3): the banked amount fades out where the chain was, no flight.

var _text: String = ""
var _from: Vector2 = Vector2.ZERO
var _to: Vector2 = Vector2.ZERO
var _t: float = -1.0
var _dur: float = 1.0


func fly(text: String, from: Vector2, to: Vector2, duration: float) -> void:
	_text = text
	_from = from
	_to = to
	_dur = maxf(duration, 1e-3)   # lint: allow-number divide guard
	_t = 0.0
	visible = true
	_place(0.0)
	_value_changed()


func _has_plate() -> bool:
	return false


func flying() -> bool:
	return _t >= 0.0


func animate(dt: float) -> bool:
	if _t < 0.0:
		return false
	_t += dt
	if _t >= _dur:
		_t = -1.0
		visible = false
		return false
	_place(_t / _dur)
	return true


func settle_motion() -> void:
	super.settle_motion()
	if flying():
		_place(_t / _dur)


## Distance flown (px) and the shrink (tests, WP9.3).
func motion_amount() -> float:
	if not flying():
		return 0.0
	return super.motion_amount() + position.distance_to(_from - size * 0.5)


## Position along the flight (ease in: it accelerates into the total) and a shrink.
func _place(k: float) -> void:
	if style != null and style.reduced_motion:
		scale = Vector2.ONE
		position = _from - size * 0.5
		modulate.a = 1.0 - k
		return
	var e := k * k
	var c := _from.lerp(_to, e)
	var sc := lerpf(1.0, 0.5, e)
	scale = Vector2(sc, sc)
	position = c - size * 0.5
	modulate.a = 1.0 - maxf(0.0, (k - 0.5) * 2.0) * 0.5


func _paint() -> void:
	var s := style
	var cell := s.digit_cell(s.display, s.size_readout)
	var w := HudDraw.number_width(s.display, _text, s.size_readout, cell)
	var y := size.y * 0.5 + HudDraw.cap_height(s.size_readout) * 0.5
	HudDraw.number(self, s.display, Vector2((size.x - w) * 0.5, y), _text, s.size_readout, cell,
			s.gold, s.outline_px, s.outline)
