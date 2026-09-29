class_name HudLives
extends HudWidget
## The life icons, top-right. Spec: UI → HUD elements ("2 life icons"); Lives, hits
## and crashes (first hit, ghost period, clean-leg restore). Hot = hits (Design system).
##
## Faceted gem icons. A hit breaks the lost icon (two halves fall apart and fade,
## leaving its empty outline); life_restored pops it back. During the ghost period
## the remaining icons blink and GHOST shows under them. Idle: no redraws.

const LABEL_GHOST := "GHOST"
const GEM_POINTS := 6
const HALF_POINTS := 4
## A broken gem's halves: top, the side's two points, bottom.
const HALF_RIGHT: PackedInt32Array = [0, 1, 2, 3]
const HALF_LEFT: PackedInt32Array = [0, 5, 4, 3]

var _max: int = 2
var _lives: int = 2
var _ghost: bool = false
var _break_i: int = -1
var _break_t: float = 0.0
var _restore_i: int = -1
var _restore_t: float = 0.0
var _clock: float = 0.0
var _gem := PackedVector2Array()
var _half := PackedVector2Array()
var _facet := PackedVector2Array()


func _init() -> void:
	super()
	_gem.resize(GEM_POINTS)
	_half.resize(HALF_POINTS)
	_facet.resize(3)


func lives_shown() -> int:
	return _lives


func breaking() -> bool:
	return _break_i >= 0


func restoring() -> bool:
	return _restore_i >= 0


func ghost_shown() -> bool:
	return _ghost


## The steady state from the feed (no animation).
func set_lives(lives: int, max_lives: int) -> void:
	if lives == _lives and max_lives == _max:
		return
	_lives = clampi(lives, 0, max_lives)
	_max = maxi(1, max_lives)
	_value_changed()


## A hit: the icon for the life just lost breaks.
func hit(lives_left: int) -> void:
	var i := clampi(lives_left, 0, _max - 1)
	_lives = clampi(lives_left, 0, _max)
	_break_i = i
	_break_t = 0.0
	if _restore_i == i:
		_restore_i = -1
	_value_changed()


func restore(lives: int) -> void:
	_lives = clampi(lives, 0, _max)
	_restore_i = clampi(lives - 1, 0, _max - 1)
	_restore_t = 0.0
	if _break_i == _restore_i:
		_break_i = -1
	_value_changed()


func set_ghost(on: bool) -> void:
	if on == _ghost:
		return
	_ghost = on
	_clock = 0.0
	_value_changed()


func animate(dt: float) -> bool:
	var t := style.tuning
	var active := false
	if _break_i >= 0:
		_break_t += dt
		if _break_t >= t.life_break_s:
			_break_i = -1
		active = true
	if _restore_i >= 0:
		_restore_t += dt
		if _restore_t >= t.life_restore_s:
			_restore_i = -1
		active = true
	if _ghost:
		_clock += dt
		active = true
	if active:
		_plate_redraw()
	return active


func _paint_plate(m: HudMesh) -> void:
	var s := style
	var t := s.tuning
	var icon := s.px(t.lives_icon_px)
	var gap := s.px(t.spacing_grid_px) * HudLayout.LIVES_PAD
	var button_h := s.px(t.button_size_px.y)
	var cy := button_h * 0.5
	var blink := blink_edge() if _ghost else 1.0
	var edge := Color(s.accent, blink) if _ghost else s.edge_idle
	m.panel(Rect2(0.0, 0.0, size.x, button_h), s.bevel_control, s.panel_fill, edge, s.edge_w)
	for i in _max:
		var c := Vector2(gap + icon * 0.5 + float(i) * (icon + gap), cy)
		var full := i < _lives
		if i == _restore_i:
			var k := clampf(_restore_t / t.life_restore_s, 0.0, 1.0)
			_gem_at(c, icon * _overshoot(k))
			_fill_gem(m, Color(s.hot, blink), Color(s.text, blink))
		elif full:
			_gem_at(c, icon)
			_fill_gem(m, Color(s.hot, blink), Color(s.text, blink))
		else:
			_gem_at(c, icon)
			m.edge(_gem, GEM_POINTS, s.edge_w, s.edge_idle)
		if i == _break_i:
			_draw_break(m, c, icon, clampf(_break_t / t.life_break_s, 0.0, 1.0))


## GHOST under the panel while the ghost period runs (steady text; the panel blinks).
func _paint() -> void:
	if not _ghost:
		return
	var s := style
	var t := s.tuning
	var y := s.px(t.button_size_px.y) + s.px(t.spacing_grid_px) * 0.5 + HudDraw.cap_height(s.size_label)
	var w := HudDraw.text_width(s.label, LABEL_GHOST, s.size_label)
	HudDraw.text(self, s.label, Vector2((size.x - w) * 0.5, y), LABEL_GHOST, s.size_label, s.accent,
			s.outline_px, s.outline)


func blink_edge() -> float:
	return lerpf(GHOST_MIN_ALPHA, 1.0, 0.5 + 0.5 * cos(TAU * style.tuning.ghost_pulse_hz * _clock))


## Ease-out with a small overshoot (0 → 1.1 → 1).
func _overshoot(k: float) -> float:
	var back := OVERSHOOT
	var x := k - 1.0
	return 1.0 + (back + 1.0) * x * x * x + back * x * x


## Two halves of the lost gem fly apart, fall, turn and fade.
func _draw_break(m: HudMesh, c: Vector2, icon: float, k: float) -> void:
	var s := style
	var a := 1.0 - k
	var spread := icon * k
	var fall := icon * k * k * 2.0
	var turn := k * BREAK_TURN_RAD
	_gem_at(Vector2.ZERO, icon)
	for side in 2:
		var sx := 1.0 if side == 1 else -1.0
		var idx := HALF_RIGHT if side == 1 else HALF_LEFT
		var off := Vector2(sx * spread, fall)
		for j in HALF_POINTS:
			_half[j] = c + off + _gem[idx[j]].rotated(turn * sx)
		m.fan(_half, HALF_POINTS, Color(s.hot, a))


func _gem_at(c: Vector2, icon: float) -> void:
	var hw := icon * GEM_WIDTH * 0.5
	var hh := icon * 0.5
	var q := hh * 0.5
	_gem[0] = c + Vector2(0.0, -hh)
	_gem[1] = c + Vector2(hw, -q)
	_gem[2] = c + Vector2(hw, q)
	_gem[3] = c + Vector2(0.0, hh)
	_gem[4] = c + Vector2(-hw, q)
	_gem[5] = c + Vector2(-hw, -q)


## Filled gem with a light facet (low-poly highlight) and a thin edge.
func _fill_gem(m: HudMesh, fill: Color, edge: Color) -> void:
	m.fan(_gem, GEM_POINTS, fill)
	var c := (_gem[0] + _gem[3]) * 0.5
	_facet[0] = _gem[0]
	_facet[1] = c
	_facet[2] = _gem[5]
	m.fan(_facet, 3, Color(style.text, fill.a * FACET_ALPHA))
	m.edge(_gem, GEM_POINTS, style.edge_w, edge)


const GEM_WIDTH := 0.72   # lint: allow-number icon shape (gem width / height)
const FACET_ALPHA := 0.35   # lint: allow-number icon shape (highlight facet)
const GHOST_MIN_ALPHA := 0.3   # lint: allow-number blink floor
const OVERSHOOT := 1.70158   # lint: allow-number standard ease-out-back constant
const BREAK_TURN_RAD := 0.9   # lint: allow-number break animation spin
