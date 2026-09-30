class_name TrafficCorrector
extends RefCounted
# lint: sim
## The client's side of traffic corrections: a short history of every car's predicted
## state, the comparison of a correction against the prediction at its tick, the blend
## rules that ease the difference out, and the timing of late intents. Spec: multiplayer
## handoff → Client network traffic ("The client stores a short history of each car's
## state. When a correction for tick N arrives, it compares against its own state at tick N
## and carries the error forward. Errors under 0.5 m blend out over 0.3 s. Errors of
## 0.5–5 m blend out over 0.15 s. Anything larger snaps and is logged." "Late intents"),
## Tuning reference (correction blending). docs/NET_TRAFFIC.md → Corrections, Late intents.
## WP N4.3. Pure, allocation-free after _init; NetworkTrafficSource owns one.
##
## - **History:** per slot, a ring of `hist_n` server ticks of the model's (s, v, d)
##   (before blending offsets), recorded at every model tick. `lookup(i, tick)` finds a
##   tick still in the ring; `carry(i, n, k, e_s, e_v, e_d)` moves the entries after a
##   correction at tick n onto the corrected trajectory (s + e_s + e_v (t - n) dt), so the
##   next correction is compared against what the car does now, not twice against the
##   same error.
## - **Blending:** the source applies a correction to its model at once and hands the jump
##   of the published position to `add_offset`: the car is drawn where it was, plus an
##   offset that runs out linearly. The duration follows the spec's rule on the size of the
##   offset still to run (under blend_small_m: blend_small_s; under blend_medium_m:
##   blend_medium_s). A larger one snaps when the car is out of view; in view it never
##   snaps: it slides at up to blend_max_speed_mps (net tuning) instead.
## - **Unsignaled lateral corrections:** a lateral jump no intent explains (the source:
##   one of at least unsignaled_lateral_m, e.g. a lost intent; a cancel that arrived after
##   the move began) is shown like a lane change: the offset holds for late_min_blinker_s
##   with the blinker on (toward where the car will slide), then slides, blinker on until
##   it is done.
## - **Late intents** (`hold_tick`): the lateral move of a lane change starts at the
##   server's move tick, or once the blinker has shown for late_min_blinker_s, whichever is
##   later; after such a hold the car catches up with the server's move curve over
##   late_catchup_s.

enum Blend { NONE, SMALL, MEDIUM, SNAP, CAPPED }

## Offsets this small are finished (m).
const DONE_M := 1.0e-9   # lint: allow-number float noise floor

var hist_n: int
var tick_dt: float

## Per slot: the offset still to run out (m), how fast (m/s), the server tick (fractional)
## until which the lateral offset holds, and the blinker shown meanwhile (-1 left, +1 right).
var off_s := PackedFloat64Array()
var off_d := PackedFloat64Array()
var rate_s := PackedFloat64Array()
var rate_d := PackedFloat64Array()
var hold_until := PackedFloat64Array()
var blink_dir := PackedInt32Array()

## Result of lookup().
var q_s: float = 0.0
var q_v: float = 0.0
var q_d: float = 0.0

var _small_m: float
var _small_s: float
var _medium_m: float
var _medium_s: float
var _max_speed: float
var _min_blink_ticks: float
var _catchup_ticks: float

var _hs := PackedFloat64Array()
var _hv := PackedFloat64Array()
var _hd := PackedFloat64Array()
var _ht := PackedInt64Array()


func _init(capacity: int, net: NetTuning, dt: float) -> void:
	tick_dt = dt
	hist_n = maxi(ceili(net.traffic_history_s / dt), 2)
	_small_m = net.traffic_blend_small_m
	_small_s = net.traffic_blend_small_s
	_medium_m = net.traffic_blend_medium_m
	_medium_s = net.traffic_blend_medium_s
	_max_speed = maxf(net.traffic_blend_max_speed_mps, DONE_M)
	_min_blink_ticks = net.traffic_late_min_blinker_s / dt
	_catchup_ticks = net.traffic_late_catchup_s / dt
	off_s.resize(capacity)
	off_d.resize(capacity)
	rate_s.resize(capacity)
	rate_d.resize(capacity)
	hold_until.resize(capacity)
	blink_dir.resize(capacity)
	_hs.resize(capacity * hist_n)
	_hv.resize(capacity * hist_n)
	_hd.resize(capacity * hist_n)
	_ht.resize(capacity * hist_n)
	for i in capacity:
		reset_slot(i)


## A new car in slot i: no history, no offset.
func reset_slot(i: int) -> void:
	off_s[i] = 0.0
	off_d[i] = 0.0
	rate_s[i] = 0.0
	rate_d[i] = 0.0
	hold_until[i] = -INF
	blink_dir[i] = 0
	var o := i * hist_n
	for k in hist_n:
		_ht[o + k] = -1


## The model's state of slot i at server tick `tick`.
func record(i: int, tick: int, s: float, v: float, d: float) -> void:
	var k := i * hist_n + posmod(tick, hist_n)
	_ht[k] = tick
	_hs[k] = s
	_hv[k] = v
	_hd[k] = d


## True (and q_s, q_v, q_d set) when slot i's state at `tick` is still in the history.
func lookup(i: int, tick: int) -> bool:
	var k := i * hist_n + posmod(tick, hist_n)
	if _ht[k] != tick:
		return false
	q_s = _hs[k]
	q_v = _hv[k]
	q_d = _hd[k]
	return true


## After a correction at tick n (errors e_s, e_v, e_d against the history), the recorded
## ticks n..k move onto the corrected trajectory.
func carry(i: int, n: int, k: int, e_s: float, e_v: float, e_d: float) -> void:
	var o := i * hist_n
	for t in range(maxi(n, k - hist_n + 1), k + 1):
		var j := o + posmod(t, hist_n)
		if _ht[j] != t:
			continue
		_hs[j] += e_s + e_v * float(t - n) * tick_dt
		_hv[j] = maxf(_hv[j] + e_v, 0.0)
		_hd[j] += e_d


## The published position of slot i jumped by (ds, dd) because its model was corrected:
## the offset takes it back and runs out by the blend rules. `visible`: the car is in the
## player's view. `blink_first`: no intent explains the lateral part, so the car shows a
## blinker for late_min_blinker_s before it slides, and while it slides. `now` is the server
## time (ticks). Returns the Blend chosen.
func add_offset(i: int, ds: float, dd: float, visible: bool, blink_first: bool, now: float) -> Blend:
	var os := off_s[i] + ds
	var od := off_d[i] + dd
	var m := sqrt(os * os + od * od)
	if m <= DONE_M:
		off_s[i] = 0.0
		off_d[i] = 0.0
		rate_s[i] = 0.0
		rate_d[i] = 0.0
		return Blend.NONE
	var tau := _small_s
	var kind := Blend.SMALL
	if m >= _small_m:
		tau = _medium_s
		kind = Blend.MEDIUM
	if m >= _medium_m:
		if not visible:
			off_s[i] = 0.0
			off_d[i] = 0.0
			rate_s[i] = 0.0
			rate_d[i] = 0.0
			hold_until[i] = -INF
			blink_dir[i] = 0
			return Blend.SNAP
		tau = maxf(_medium_s, m / _max_speed)
		kind = Blend.CAPPED
	off_s[i] = os
	off_d[i] = od
	rate_s[i] = absf(os) / tau
	rate_d[i] = absf(od) / tau
	if blink_first and dd != 0.0 and blink_dir[i] == 0:
		hold_until[i] = now + _min_blink_ticks
		blink_dir[i] = 1 if od < 0.0 else -1
	return kind


## Runs slot i's offset out over dt_s seconds of server time `now` (ticks). The blinker of
## an unsignaled slide stays on through the tick the slide ends in.
func decay(i: int, dt_s: float, now: float) -> void:
	if off_d[i] == 0.0:
		blink_dir[i] = 0
	var os := off_s[i]
	if os != 0.0:
		var step := rate_s[i] * dt_s
		os = 0.0 if absf(os) <= step else os - signf(os) * step
		off_s[i] = os
	var od := off_d[i]
	if od != 0.0 and now >= hold_until[i]:
		var step := rate_d[i] * dt_s
		od = 0.0 if absf(od) <= step else od - signf(od) * step
		off_d[i] = od


## m/s the published s / d moves by because of the offset now (0 while held).
func offset_speed_s(i: int) -> float:
	return -signf(off_s[i]) * rate_s[i]


func offset_speed_d(i: int, now: float) -> float:
	if off_d[i] == 0.0 or now < hold_until[i]:
		return 0.0
	return -signf(off_d[i]) * rate_d[i]


## Late intents: the tick (fractional) the lateral move may start, given the blinker shows
## from `blink_t` and the server moves from `move_t`.
func hold_tick(blink_t: float, move_t: float) -> float:
	return maxf(move_t, blink_t + _min_blink_ticks)


## Catch-up length (ticks) after a hold that ended past the server's move start.
func catchup_ticks() -> float:
	return _catchup_ticks


func min_blinker_ticks() -> float:
	return _min_blink_ticks
