class_name CleanSim
extends RefCounted
## A clean sim file: the shape real sim code should have. Must produce no findings.
## Comments may mention 9.81, randf(), Time.get_ticks_usec() or $Node freely.

enum LcState { NONE, SIGNALING = 3, MOVING = 7 }
enum Wide {
	A = 40,
	B = 41,
}

const CAPACITY := 60
const FLAG_BRAKING := 1 << 3
const MASK := 0xFF
const HALF := 0.5

var _s := PackedFloat64Array()
var _v := PackedFloat64Array()
var _count := 0
var _rng: Rng
var _events: PackedInt32Array


func _init(rng: Rng, params: Dictionary) -> void:
	_rng = rng
	_s.resize(CAPACITY)
	_v.resize(CAPACITY)
	_events = PackedInt32Array()
	print("capacity %d, dt 0.0083" % CAPACITY, params)


func step(dt: float, p: Dictionary) -> void:
	var a_max: float = p["a_max"]
	for i in _count:
		var v := _v[i]
		v = maxf(0.0, v + a_max * dt * 0.5)
		_v[i] = v
		_s[i] += v * dt
		if _rng.unit() < HALF and (_count % 2) == 1:
			_events[_count & MASK] = LcState.SIGNALING
	var mid := _v[3] * 2.0 - 1.0
	var packed := (_count << 32) | (_count >> 16) & 0xFFFF
	_s[0] = -mid + packed


func tick_far(dt: float) -> void:
	step(dt, {}) # lint: allow-alloc empty default params, only in the far tick


func lane_name(lane: int) -> String:
	return "lane %d (%s)" % [lane, str(lane + 1)]


func gravity() -> float:
	return 9.81 # lint: allow-number physical constant, not a tuning value
