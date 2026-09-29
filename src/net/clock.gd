class_name NetClock
extends RefCounted
## Server clock sync: `server_now()` is the room's fractional tick (20 Hz). Spec: multiplayer
## handoff → Networking protocol → Clock sync ("keeps the 8 most recent samples, takes the
## offset from the sample with the lowest round trip, and slews its estimate smoothly (never
## jumps backward)"); docs/PROTOCOL.md §1 (Ping/Pong fields). WP N2.2. Pure: time comes from
## the injected NetTimeSource (Time.get_ticks_usec in production, NetVirtualTime in tests).
##
## Per Pong: rtt = receive − send; the server's clock `server_tick + tick_fraction / 65536`
## is taken to belong to the midpoint `send + rtt / 2`, giving an offset
## `server_ticks − local_seconds × tick_rate`. The newest `clock_samples` samples are kept;
## the lowest-RTT one (least queueing, so the most symmetric path) is the target offset.
##
## The estimate moves toward the target with a time constant (`clock_settle_smoothing_s`
## while the window fills, `clock_smoothing_s` after) and at most `clock_slew_max_rate`
## ticks per tick, so the server clock never runs backward: a target behind the estimate
## only slows it down. A target more than `clock_snap_forward_ms` ahead is jumped to (forward
## only). The first sample sets the estimate directly. `server_now()` is also clamped to be
## non-decreasing across calls.
##
## A Pong with tick 0 and fraction 0 comes from outside a room and is not a clock sample.
## Call `reset()` when joining a different room (its tick restarts).
##
## Ping send times: `ping_time_ms()` returns the u32 `client_time_ms` for the next Ping and
## remembers the exact send time, so RTT has microsecond resolution; an unknown echo falls
## back to the millisecond value (u32 wrap-around safe).

const USEC_PER_S := 1000000.0
const MS_PER_S := 1000.0
const USEC_PER_MS := 1000
const U32_MOD := 4294967296
## Outstanding pings remembered for exact send times.
const PING_SLOTS := 16

## Samples taken / used (dev HUD, tests).
var samples_taken: int = 0
## Round trip of the latest sample and of the current best sample, seconds.
var last_rtt_s: float = 0.0
var best_rtt_s: float = 0.0

var _time: NetTimeSource
var _tuning: NetTuning
var _rate: float = 0.0

var _rtt := PackedFloat64Array()
var _off := PackedFloat64Array()
var _count: int = 0
var _head: int = 0

var _ping_ms := PackedInt64Array()
var _ping_us := PackedInt64Array()
var _ping_head: int = 0

var _synced: bool = false
var _offset: float = 0.0
var _target: float = 0.0
var _updated_us: int = 0
var _last_now: float = -INF


func _init(tuning: NetTuning, time_source: NetTimeSource = null) -> void:
	_tuning = tuning
	_time = time_source if time_source != null else NetTimeSource.new()
	_rate = tuning.tick_rate_hz
	var n := maxi(tuning.clock_samples, 1)
	_rtt.resize(n)
	_off.resize(n)
	_ping_ms.resize(PING_SLOTS)
	_ping_us.resize(PING_SLOTS)
	_ping_ms.fill(-1)


## Forgets every sample (joining another room: its tick restarts).
func reset() -> void:
	_count = 0
	_head = 0
	_synced = false
	_last_now = -INF
	samples_taken = 0


## Server tick rate (from Welcome.tick_rate_hz). A change drops the samples (offsets are
## kept in ticks).
func set_tick_rate(hz: float) -> void:
	if hz <= 0.0 or hz == _rate:
		return
	reset()
	_rate = hz


func tick_rate() -> float:
	return _rate


func has_sync() -> bool:
	return _synced


## `client_time_ms` for the Ping about to be sent (local monotonic ms, wrapping u32).
func ping_time_ms() -> int:
	var now := _time.now_usec()
	@warning_ignore("integer_division")
	var ms := (now / USEC_PER_MS) % U32_MOD
	_ping_ms[_ping_head] = ms
	_ping_us[_ping_head] = now
	_ping_head = (_ping_head + 1) % PING_SLOTS
	return ms


## Feeds one Pong. Returns true when it became a clock sample.
func on_pong(client_time_ms: int, server_tick: int, tick_fraction: int) -> bool:
	var now := _time.now_usec()
	var sent := _sent_usec(client_time_ms, now)
	var rtt_us := now - sent
	if rtt_us < 0 or rtt_us > _tuning.clock_max_rtt_ms * USEC_PER_MS:
		return false
	if server_tick == 0 and tick_fraction == 0:
		return false
	var server_ticks := server_tick + tick_fraction / NetCodec.TICK_FRACTION_SCALE
	var mid_s := (sent + rtt_us * 0.5) / USEC_PER_S
	var rtt_s := rtt_us / USEC_PER_S
	_advance(now)
	_rtt[_head] = rtt_s
	_off[_head] = server_ticks - mid_s * _rate
	_head = (_head + 1) % _rtt.size()
	_count = mini(_count + 1, _rtt.size())
	samples_taken += 1
	last_rtt_s = rtt_s
	var best := 0
	for i in range(1, _count):
		if _rtt[i] < _rtt[best]:
			best = i
	best_rtt_s = _rtt[best]
	_target = _off[best]
	if not _synced:
		_synced = true
		_offset = _target
		_updated_us = now
	return true


## The room's current tick, fractional (0.0 before the first sample). Never decreases
## between calls.
func server_now() -> float:
	if not _synced:
		return 0.0
	var now := _time.now_usec()
	_advance(now)
	var v := now / USEC_PER_S * _rate + _offset
	if v < _last_now:
		v = _last_now
	_last_now = v
	return v


## Estimate minus target, in milliseconds (dev HUD: how far the slew still has to go).
func slew_remaining_ms() -> float:
	return (_offset - _target) / _rate * MS_PER_S if _synced else 0.0


func _advance(now: int) -> void:
	if not _synced:
		return
	var dt := (now - _updated_us) / USEC_PER_S
	_updated_us = now
	if dt <= 0.0:
		return
	var diff := _target - _offset
	if diff > _tuning.clock_snap_forward_ms / MS_PER_S * _rate:
		_offset = _target
		return
	var tau := _tuning.clock_smoothing_s if _count >= _rtt.size() \
		else _tuning.clock_settle_smoothing_s
	var step := diff * minf(1.0, dt / maxf(tau, 1.0e-6))   # lint: allow-number avoids /0
	var max_step := _tuning.clock_slew_max_rate * _rate * dt
	_offset += clampf(step, -max_step, max_step)


func _sent_usec(client_time_ms: int, now: int) -> int:
	for i in PING_SLOTS:
		if _ping_ms[i] == client_time_ms:
			return _ping_us[i]
	@warning_ignore("integer_division")
	var now_ms := (now / USEC_PER_MS) % U32_MOD
	var age_ms := (now_ms - client_time_ms + U32_MOD) % U32_MOD
	return now - age_ms * USEC_PER_MS
