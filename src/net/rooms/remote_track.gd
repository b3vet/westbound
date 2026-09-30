class_name NetRemoteTrack
extends RefCounted
# lint: sim
## One remote player's recent states, interpolated and extrapolated for display. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Players ("Clients show remote cars 100 ms behind with
## interpolation and extrapolate up to 250 ms, then fade the car until data arrives"), The
## loop map ("s wraps modulo L. Every distance comparison uses the wrapped signed
## difference"); Tuning reference. docs/ROOMS_CLIENT.md → Remote players. WP N5.2.
##
## Pure and allocation-free after init: a ring of `capacity` states in packed arrays.
## States arrive in wire order but may be late, lost or reordered (PROTOCOL.md: room
## traffic must tolerate a later UDP transport); an older or repeated tick is dropped.
##
## The seam: each pushed s (wrapped into [0, L) on the wire) is unwrapped next to the
## newest stored s with the wrapped signed difference, so the track's s is continuous
## across the start / finish line (it may run past L or below 0). The consumer maps it next
## to its own unwrapped s (LoopRoadPath.unwrap_near). A jump farther than `snap_m` from
## where the track predicted (a server placement: spawn, respawn, rejoin) restarts the
## track, so the car jumps instead of sliding there.
##
## sample(render_tick) writes the display state into the out fields:
##   - between two states: linear interpolation (INTERPOLATED);
##   - before the oldest: the oldest (INTERPOLATED);
##   - past the newest: dead reckoning along the road, s += v cos(heading) t, d += v sin(heading) t
##     (road-relative heading), for at most `extrap_max_ticks` (EXTRAPOLATED); beyond that
##     the car holds there and fades out over `fade_ticks` (STALE, `alpha` 1 → 0).

enum Mode { EMPTY, INTERPOLATED, EXTRAPOLATED, STALE }

var capacity: int = 0
## Loop length (m); 0 = no wrapping (tests of a straight road).
var loop_length: float = 0.0
## Room ticks per second (the tick → seconds conversion for dead reckoning).
var tick_rate: float = 1.0
## A state this far (m) from the track's prediction restarts the track.
var snap_m: float = 0.0
## States stored / dropped as late or repeated / restarts after a teleport.
var count: int = 0
var dropped: int = 0
var restarts: int = 0
## The newest stored tick (-1 when empty).
var newest_tick: int = -1

## sample() output.
var mode: Mode = Mode.EMPTY
var s: float = 0.0
var d: float = 0.0
var heading: float = 0.0
var speed: float = 0.0
var flags: int = 0
var run_state: int = 0
var alpha: float = 0.0

var _head: int = 0
var _tick := PackedInt64Array()
var _s := PackedFloat64Array()
var _d := PackedFloat64Array()
var _heading := PackedFloat64Array()
var _speed := PackedFloat64Array()
var _flags := PackedInt32Array()
var _run_state := PackedInt32Array()


func _init(samples: int, loop_length_m: float, ticks_per_s: float, snap_distance_m: float) -> void:
	capacity = maxi(samples, 2)
	loop_length = loop_length_m
	tick_rate = maxf(ticks_per_s, 1.0)
	snap_m = snap_distance_m
	_tick.resize(capacity)
	_s.resize(capacity)
	_d.resize(capacity)
	_heading.resize(capacity)
	_speed.resize(capacity)
	_flags.resize(capacity)
	_run_state.resize(capacity)
	clear()


## Forgets every state (a slot handed to another player, a player gone).
func clear() -> void:
	count = 0
	_head = 0
	newest_tick = -1
	mode = Mode.EMPTY
	alpha = 0.0


## Stores one state (physical units: s wrapped or not, d + right, road-relative heading,
## speed). Returns false when it is dropped (not newer than the newest). Allocation-free.
func push(tick: int, s_m: float, d_m: float, heading_rad: float, speed_mps: float,
		flag_bits: int, run_state_index: int) -> bool:
	if count > 0 and tick <= newest_tick:
		dropped += 1
		return false
	var su := s_m
	if count > 0:
		var n := _index(count - 1)
		su = _s[n] + _wrapped_delta(_s[n], s_m)
		var dt := float(tick - _tick[n]) / tick_rate
		var predicted := _s[n] + _speed[n] * cos(_heading[n]) * dt
		if absf(su - predicted) > snap_m + absf(speed_mps - _speed[n]) * dt:
			restarts += 1
			count = 0
			_head = 0
	var i := _index(count) if count < capacity else _head
	if count < capacity:
		count += 1
	else:
		_head = (_head + 1) % capacity
	_tick[i] = tick
	_s[i] = su
	_d[i] = d_m
	_heading[i] = heading_rad
	_speed[i] = speed_mps
	_flags[i] = flag_bits
	_run_state[i] = run_state_index
	newest_tick = tick
	return true


## The display state at `render_tick` (fractional room tick: server_now() minus the
## interpolation delay). Returns the mode; the out fields hold the state. Allocation-free.
func sample(render_tick: float, extrap_max_ticks: float, fade_ticks: float) -> Mode:
	if count == 0:
		mode = Mode.EMPTY
		alpha = 0.0
		return mode
	var oldest := _index(0)
	if render_tick <= float(_tick[oldest]):
		_copy(oldest)
		mode = Mode.INTERPOLATED
		alpha = 1.0
		return mode
	var newest := _index(count - 1)
	if render_tick > float(_tick[newest]):
		return _extrapolate(newest, render_tick, extrap_max_ticks, fade_ticks)
	for k in range(count - 1, 0, -1):
		var a := _index(k - 1)
		if float(_tick[a]) <= render_tick:
			var b := _index(k)
			var u := (render_tick - float(_tick[a])) / float(_tick[b] - _tick[a])
			s = lerpf(_s[a], _s[b], u)
			d = lerpf(_d[a], _d[b], u)
			heading = lerpf(_heading[a], _heading[b], u)
			speed = lerpf(_speed[a], _speed[b], u)
			flags = _flags[b]
			run_state = _run_state[b]
			mode = Mode.INTERPOLATED
			alpha = 1.0
			return mode
	return _extrapolate(newest, render_tick, extrap_max_ticks, fade_ticks)


## Past the newest state: dead reckoning, capped, then a fade.
func _extrapolate(n: int, render_tick: float, extrap_max_ticks: float, fade_ticks: float) -> Mode:
	_copy(n)
	var ahead := render_tick - float(_tick[n])
	var t := minf(ahead, extrap_max_ticks) / tick_rate
	s += speed * cos(heading) * t
	d += speed * sin(heading) * t
	if ahead <= extrap_max_ticks:
		mode = Mode.EXTRAPOLATED
		alpha = 1.0
	else:
		mode = Mode.STALE
		alpha = clampf(1.0 - (ahead - extrap_max_ticks) / maxf(fade_ticks, 1.0), 0.0, 1.0)
	return mode


## The newest stored s (continuous; see the class notes), NAN when empty.
func newest_s() -> float:
	return _s[_index(count - 1)] if count > 0 else NAN


func _copy(i: int) -> void:
	s = _s[i]
	d = _d[i]
	heading = _heading[i]
	speed = _speed[i]
	flags = _flags[i]
	run_state = _run_state[i]


## Ring index of the k-th oldest stored state.
func _index(k: int) -> int:
	return (_head + k) % capacity


## How far `b` is ahead of `a` along the loop, in [-L/2, L/2) (plain b - a without a loop).
func _wrapped_delta(a: float, b: float) -> float:
	if loop_length <= 0.0:
		return b - a
	return fposmod(b - a + loop_length * 0.5, loop_length) - loop_length * 0.5
