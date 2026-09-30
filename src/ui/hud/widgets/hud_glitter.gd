class_name HudGlitter
extends HudWidget
## Glitter bursts. Spec: Scoring → Score feedback ("Glitter bursts on close passes and
## threads at high multipliers"). Cheap: at most hud.glitter_max diamond sparks, all
## drawn as one triangle array; pre-sized buffers; hidden when no spark is alive.
## Visual only, so its jitter comes from a local generator, not the run's Rng.

const SPARK_POINTS := 4
const SPARK_INDICES := 6
const JITTER_SEED := 0x5eed

var _cap: int = 0
var _alive: int = 0
var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _age := PackedFloat64Array()
var _spin := PackedFloat64Array()
var _tint := PackedInt32Array()
var _pts := PackedVector2Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()
var _rng := RandomNumberGenerator.new()


func _restyled() -> void:
	var cap := maxi(0, style.tuning.glitter_max)
	if cap == _cap:
		return
	_cap = cap
	_rng.seed = JITTER_SEED
	_pos.resize(cap)
	_vel.resize(cap)
	_age.resize(cap)
	_spin.resize(cap)
	_tint.resize(cap)
	_pts.resize(cap * SPARK_POINTS)
	_cols.resize(cap * SPARK_POINTS)
	_idx.resize(cap * SPARK_INDICES)
	for i in cap:
		var v := i * SPARK_POINTS
		var k := i * SPARK_INDICES
		_idx[k] = v
		_idx[k + 1] = v + 1
		_idx[k + 2] = v + 2
		_idx[k + 3] = v
		_idx[k + 4] = v + 2
		_idx[k + 5] = v + 3
	_alive = 0


func _has_plate() -> bool:
	return false


func alive() -> int:
	return _alive


## A burst of `count` sparks (clamped to the free slots) from canvas point `at`. None
## with reduced motion (WP9.3: flying particles are motion; the event's word and
## sound carry it).
func burst(at: Vector2, count: int) -> void:
	if style.reduced_motion:
		return
	var t := style.tuning
	var n := mini(count, _cap - _alive)
	for k in n:
		var i := _alive
		var a := TAU * (float(k) + _rng.randf()) / float(maxi(n, 1))
		var speed := t.glitter_speed_px_s * style.ts * lerpf(0.5, 1.0, _rng.randf())
		_pos[i] = at - global_position
		_vel[i] = Vector2(cos(a), sin(a) - UPWARD) * speed
		_age[i] = 0.0
		_spin[i] = _rng.randf() * TAU
		_tint[i] = k % TINTS
		_alive += 1
	if _alive > 0:
		visible = true
		queue_redraw()


func settle_motion() -> void:
	_alive = 0
	visible = false
	queue_redraw()


## Sparks in flight (tests, WP9.3).
func motion_amount() -> float:
	return float(_alive)


func animate(dt: float) -> bool:
	if _alive == 0:
		return false
	var t := style.tuning
	var g := t.glitter_gravity_px_s2 * style.ts
	var i := 0
	while i < _alive:
		_age[i] += dt
		if _age[i] >= t.glitter_s:
			_alive -= 1
			_pos[i] = _pos[_alive]
			_vel[i] = _vel[_alive]
			_age[i] = _age[_alive]
			_spin[i] = _spin[_alive]
			_tint[i] = _tint[_alive]
			continue
		var vel := _vel[i]
		vel.y += g * dt
		_vel[i] = vel
		_pos[i] += vel * dt
		i += 1
	if _alive == 0:
		visible = false
		return false
	queue_redraw()
	return true


func _paint() -> void:
	if _alive == 0:
		return
	var t := style.tuning
	var size_px := t.glitter_size_px * style.ts
	for i in _cap:
		var v := i * SPARK_POINTS
		if i >= _alive:
			# Dead slots collapse to a point (zero-area, fixed index buffer).
			for j in SPARK_POINTS:
				_pts[v + j] = Vector2.ZERO
				_cols[v + j] = Color.TRANSPARENT
			continue
		var k := clampf(_age[i] / t.glitter_s, 0.0, 1.0)
		var r := size_px * (1.0 - k * 0.5)
		var rot := _spin[i] + k * TAU
		var c := _color(_tint[i])
		c.a = 1.0 - k * k
		var ax := Vector2(cos(rot), sin(rot)) * r
		var ay := Vector2(-ax.y, ax.x) * SPARK_THIN
		_pts[v] = _pos[i] + ax
		_pts[v + 1] = _pos[i] + ay
		_pts[v + 2] = _pos[i] - ax
		_pts[v + 3] = _pos[i] - ay
		for j in SPARK_POINTS:
			_cols[v + j] = c
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _idx, _pts, _cols)


func _color(tint: int) -> Color:
	match tint:
		0:
			return style.gold
		1:
			return style.accent
	return style.text


const TINTS := 3
const UPWARD := 0.6   # lint: allow-number bursts lean upward
const SPARK_THIN := 0.45   # lint: allow-number diamond aspect
