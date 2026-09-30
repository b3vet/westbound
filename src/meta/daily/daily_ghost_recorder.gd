class_name DailyGhostRecorder
extends RefCounted
# lint: sim
## Records a Daily Drive run's ghost at 20 Hz. Spec: Core loop → Modes at launch ("the
## car's s, d and heading sampled at 20 Hz"). WP8.4; docs/DAILY.md → Recording.
##
##   rec.begin(date, seed, car_id, tick_hz, sample_ticks, reserve_samples)
##   rec.note_fork(k, index, side)   # the tick a fork resolved (before step(k))
##   rec.step(k, s, d, yaw, v, flags, reset)   # after every RUNNING tick k = 1, 2, ...
##   var ghost := rec.finish(score)
##
## Samples the state after ticks k = 1, 1 + n, 1 + 2n, ... (n = sample_ticks: 6 = 20 Hz).
## A fork swap to the right branch (d jumps by the fork's shift) and the safety net's
## reset are always sampled, together with the tick before them, so playback never
## interpolates across the jump; the last tick seen becomes the FINAL sample. Pure: no
## Node, no autoloads. step() allocates nothing within the reserve (the columns double
## past it).

## Fork rows reserved up front (a journey has a handful of forks; more double).
const FORK_RESERVE := 16

var ghost: DailyGhost
var recording: bool = false

var _every: int = 1
var _last_k: int = 0
var _last_sample_k: int = 0
var _jump_pending: int = 0
var _has_prev: bool = false
var _p_k: int = 0
var _p_s: float = 0.0
var _p_d: float = 0.0
var _p_yaw: float = 0.0
var _p_v: float = 0.0
var _p_flags: int = 0


## A new ghost (allocates: run start).
func begin(date: String, seed_value: int, car_id: String, tick_hz: int, sample_ticks: int,
		reserve_samples: int) -> void:
	ghost = DailyGhost.new()
	ghost.date = date
	ghost.seed_value = seed_value
	ghost.car = car_id
	ghost.tick_hz = tick_hz
	ghost.sample_ticks = maxi(sample_ticks, 1)
	ghost.reserve(reserve_samples, FORK_RESERVE)
	_every = ghost.sample_ticks
	_last_k = 0
	_last_sample_k = 0
	_jump_pending = 0
	_has_prev = false
	recording = true


## Fork `index` resolved to `side` at tick k (a RIGHT swap moves d: a jump).
func note_fork(k: int, index: int, side: int) -> void:
	if not recording:
		return
	ghost.add_fork(k, index, side)
	if side == ForkPlan.RIGHT:
		_jump_pending |= DailyGhost.FLAG_FORK_SWAP


## The state after RUNNING tick k (k grows by one per tick). `reset`: the safety net moved
## the car this tick. Allocation-free within the reserve.
func step(k: int, s: float, d: float, yaw: float, v: float, sample_flags: int, reset: bool) -> void:
	if not recording or k <= _last_k:
		return
	var jump := _jump_pending
	_jump_pending = 0
	if reset:
		jump |= DailyGhost.FLAG_RESET
	if jump != 0 and _has_prev and _p_k > _last_sample_k and _p_k == k - 1:
		# The tick before the jump, so playback holds it until the jump.
		ghost.add_sample(_p_k, _p_s, _p_d, _p_yaw, _p_v, _p_flags)
		_last_sample_k = _p_k
	if jump != 0 or (k - 1) % _every == 0:
		ghost.add_sample(k, s, d, yaw, v, sample_flags | jump)
		_last_sample_k = k
	_has_prev = true
	_p_k = k
	_p_s = s
	_p_d = d
	_p_yaw = yaw
	_p_v = v
	_p_flags = sample_flags
	_last_k = k


## Stops and returns the ghost with its summary (`score` = the banked score); the last
## tick seen is its FINAL sample. Null when nothing was recorded.
func finish(score: int) -> DailyGhost:
	if not recording or ghost == null:
		recording = false
		return null
	recording = false
	if ghost.sample_count == 0:
		return null
	if _has_prev and _p_k > _last_sample_k:
		ghost.add_sample(_p_k, _p_s, _p_d, _p_yaw, _p_v, _p_flags | DailyGhost.FLAG_FINAL)
	else:
		ghost.flags[ghost.sample_count - 1] = ghost.flags[ghost.sample_count - 1] | DailyGhost.FLAG_FINAL
	ghost.ticks = _last_k
	ghost.score = score
	return ghost


## Stops without a ghost (a quit, a retry before the end).
func cancel() -> void:
	recording = false
