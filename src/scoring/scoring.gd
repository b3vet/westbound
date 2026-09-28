class_name Scoring
extends ScoringRuleSet
## The v1 (Chase the Sun) scoring rules. Spec: Scoring (all of it: scoring events,
## anti-exploit rules, multiplier, chain and banking, boost); Core loop → Sky timeline
## (small nudges), Night (x2); Lives (nothing scores in the ghost period; the
## minimum-speed rule pauses 3 s after a hit); Traffic reacts to the player (close-pass
## horn). Rules as implemented, every threshold and worked examples: docs/SCORING.md.
##
##   var rules := Scoring.new(ctx)                  # or Scoring.new() + reset(ctx)
##   rules.set_player_body(car.length_m, car.width_m)
##   rules.step(dt, player, traffic.state, road, events)   # 120 Hz, after collisions
##   player.boost_meter = minf(1.0, player.boost_meter + rules.take_boost_fill())
##
## Pure (RefCounted, no Node or autoload access), deterministic (no randomness at all)
## and allocation-free per tick: per-car memory lives in preallocated arrays indexed
## by TrafficState slot and is re-keyed whenever the slot's vehicle_id changes.
##
## Kinds written besides the ScoringRuleSet ones (CONTRACTS §7):
##   ScoreEvents.PASS / CLOSE_PASS / CUT / THREAD: points, multiplier (the one the
##     points were computed with, before this event's gain), clearance_m (passes and
##     threads; -1 for cuts), slot (the car; for a thread the second car).
## Extra kind (not an Events signal, like KIND_SUN_NUDGE):
##   KIND_NEAR_MISS: slot = the car. A physical close pass (clearance under
##     close_pass_clearance_m), scored or not (shoulder), except in the ghost period.
##     run.gd calls TrafficSim.notify_close_pass(slot) for it (the ~30% horn).

const KIND_NEAR_MISS := &"near_miss"

## Pass-tracking phase per slot.
const _NONE := 0      ## not eligible: seen beside or behind the player first
const _AHEAD := 1     ## fully ahead of the player (no longitudinal hull overlap)
const _OVERLAP := 2   ## overlapping longitudinally, having come from ahead
## Why a pass in progress may not score.
const _TAINT_GHOST := 1
const _TAINT_SHOULDER := 2
## Recent qualifying passes remembered for the thread window (a ring).
const _THREAD_RING := 8

var _sc: ScoringTuning
var _inset: float
var _day_span_nudge_thread: float
var _day_span_nudge_close: float
var _cp_window: float

# Params (SI), converted once in reset().
var _floor: float
var _min_v: float
var _cut_v: float
var _slip_v: float
var _night_f := 1.0

# Player hull (half sizes, inset).
var _p_hl: float
var _p_hw: float

# Run state.
var _t := 0.0
var _mult := 1.0
var _chain := 0
var _banked := 0
var _boost_fill := 0.0
var _night := false
var _ghost := false
var _ended := false
var _reached_min := false
var _hit_grace := 0.0
var _too_slow := false
var _slow_time := 0.0
var _hesitated := false
var _dipped := false          ## below minimum speed since the last multiplier gain
var _on_shoulder := false
var _shoulder_time := 0.0
var _penalty_block := 0.0
var _penalty := false
var _slip := false
var _prev_lane := -1
var _sf := 1.0                ## speed factor of the current tick

# Per-slot memory (index = TrafficState slot), valid while _vid[i] == vehicle_id[i].
var _cap := 0
var _vid := PackedInt32Array()
var _phase := PackedInt32Array()
var _taint := PackedInt32Array()
var _crossed := PackedByteArray()
var _min_clear := PackedFloat64Array()
var _cross_dd := PackedFloat64Array()   ## car d - player d when the centers crossed
var _cross_t := PackedFloat64Array()
var _cut_t := PackedFloat64Array()      ## last time this car contributed to a cut

# Thread ring: recent scored passes with clearance under thread_clearance_m.
var _tr_t := PackedFloat64Array()
var _tr_side := PackedInt32Array()
var _tr_clear := PackedFloat64Array()
var _tr_used := PackedByteArray()
var _tr_head := 0

# Close passes for the sun nudge (ring of close_pass_nudge_count times).
var _cp_t := PackedFloat64Array()
var _cp_head := 0
var _cp_n := 0


func _init(ctx: RunContext = null) -> void:
	if ctx != null:
		reset(ctx)


## New run: reads scoring, lives (collision inset), sun (nudges) and traffic (default
## player body, slot capacity) from ctx.tuning. Allocates the per-slot memory.
func reset(ctx: RunContext) -> void:
	var t := ctx.tuning
	_sc = t.scoring
	_inset = t.lives.collision_inset_m
	_day_span_nudge_thread = Units.pct_to_frac(t.sun.thread_nudge_pct)
	_day_span_nudge_close = Units.pct_to_frac(t.sun.close_pass_nudge_pct)
	_cp_window = t.sun.close_pass_nudge_window_s
	_floor = _sc.multiplier_start
	_min_v = _sc.min_speed_mps()
	_cut_v = _sc.cut_min_speed_mps()
	_slip_v = _sc.slipstream_min_speed_mps()
	set_player_body(t.traffic.player_length_m, t.traffic.player_width_m)
	_ensure_slots(t.traffic.max_active_vehicles)
	_cp_t.resize(maxi(t.sun.close_pass_nudge_count, 1))
	_tr_t.resize(_THREAD_RING)
	_tr_side.resize(_THREAD_RING)
	_tr_clear.resize(_THREAD_RING)
	_tr_used.resize(_THREAD_RING)
	_t = 0.0
	_mult = _floor
	_chain = 0
	_banked = 0
	_boost_fill = 0.0
	_night = false
	_night_f = 1.0
	_ghost = false
	_ended = false
	_reached_min = not _sc.min_speed_grace_until_reached
	_hit_grace = 0.0
	_too_slow = false
	_slow_time = 0.0
	_hesitated = false
	_dipped = false
	_on_shoulder = false
	_shoulder_time = 0.0
	_penalty_block = 0.0
	_penalty = false
	_slip = false
	_prev_lane = -1
	_sf = 1.0
	_vid.fill(0)
	_clear_thread_ring()
	_cp_head = 0
	_cp_n = 0


## The player's visual body (run.gd passes the CarDef's length_m / width_m). The hull
## is inset by lives.collision_inset_m on each side. Default: TrafficTuning.player_*.
func set_player_body(length_m: float, width_m: float) -> void:
	_p_hl = length_m * 0.5 - _inset
	_p_hw = width_m * 0.5 - _inset


# ---------------------------------------------------------------- Tick

func step(dt: float, player: VehicleState, traffic: TrafficState, road: RoadPath,
		out_events: ScoreEventBuffer) -> void:
	if _ended:
		return
	_t += dt
	var v := player.v
	var ps := player.s
	var pd := player.d
	_sf = _sc.speed_factor(v)
	_step_shoulder(dt, ps, pd, road, out_events)
	_step_min_speed(dt, v, out_events)
	if traffic.capacity > _cap:
		_ensure_slots(traffic.capacity)   # only if the traffic state outgrew tuning's cap
	var lane := road.lane_index_at(pd, ps)
	var slip := false
	var slip_ok := not _ghost and lane >= 0 and v >= _slip_v
	for i in traffic.capacity:
		if traffic.active[i] == 0:
			_vid[i] = 0
			continue
		var ds := traffic.s[i] - ps
		var hl_sum := traffic.length[i] * 0.5 - _inset + _p_hl
		if _vid[i] != traffic.vehicle_id[i]:
			_vid[i] = traffic.vehicle_id[i]
			_cut_t[i] = -INF
			_phase[i] = _AHEAD if ds >= hl_sum else _NONE
		if slip_ok and not slip and traffic.lane[i] == lane and ds > 0.0 \
				and ds - hl_sum <= _sc.slipstream_distance_m:
			slip = true
		var ph := _phase[i]
		if ph == _AHEAD and ds < hl_sum:
			ph = _OVERLAP
			_min_clear[i] = INF
			_crossed[i] = 0
			_taint[i] = 0
		if ph == _OVERLAP:
			var clr := RoadHull.clearance(ps, pd, player.yaw, _p_hl, _p_hw,
				traffic.s[i], traffic.d[i], atan2(traffic.v_lat[i], traffic.v[i]),
				traffic.length[i] * 0.5 - _inset, traffic.width[i] * 0.5 - _inset)
			_min_clear[i] = minf(_min_clear[i], clr)
			if _ghost:
				_taint[i] |= _TAINT_GHOST
			if _on_shoulder:
				_taint[i] |= _TAINT_SHOULDER
			if ds <= 0.0:
				if _crossed[i] == 0:
					_crossed[i] = 1
					_cross_dd[i] = traffic.d[i] - pd
					_cross_t[i] = _t
			else:
				_crossed[i] = 0
			if ds >= hl_sum:
				ph = _AHEAD        # the player dropped back: no pass
			elif ds <= -hl_sum:
				ph = _NONE         # fully behind: the pass is complete
				_complete_pass(i, out_events)
		elif ph == _NONE and ds >= hl_sum:
			ph = _AHEAD
		_phase[i] = ph
	# Cut: the player's center crossed a lane line.
	if lane >= 0 and _prev_lane >= 0 and lane != _prev_lane and not _ghost and v >= _cut_v:
		_try_cut(lane, _prev_lane, ps, traffic, out_events)
	_prev_lane = lane
	# Slipstream.
	if slip:
		_boost_fill += Units.pct_to_frac(_sc.boost_fill_slipstream_pct_per_s) * dt
	if slip != _slip:
		_slip = slip
		out_events.push(KIND_SLIPSTREAM, 0, 0.0, -1.0, -1, 1.0 if slip else 0.0)
	_step_multiplier(dt, player, out_events)


func _step_shoulder(dt: float, ps: float, pd: float, road: RoadPath, out: ScoreEventBuffer) -> void:
	# "Any wheel on the shoulder": either side of the hull is over a shoulder.
	var on := road.is_on_shoulder(pd - _p_hw, ps) or road.is_on_shoulder(pd + _p_hw, ps)
	if on:
		_shoulder_time = _shoulder_time + dt if _on_shoulder else dt
	elif _on_shoulder and _shoulder_time > _sc.shoulder_penalty_after_s:
		_penalty_block = _sc.shoulder_penalty_block_s
	elif _penalty_block > 0.0:
		_penalty_block -= dt
	_on_shoulder = on
	var pen := (on and _shoulder_time > _sc.shoulder_penalty_after_s) or _penalty_block > 0.0
	if pen != _penalty:
		_penalty = pen
		out.push(KIND_SHOULDER, 0, 0.0, -1.0, -1, 1.0 if pen else 0.0)


func _step_min_speed(dt: float, v: float, out: ScoreEventBuffer) -> void:
	if v >= _min_v:
		_reached_min = true
	if _hit_grace > 0.0:
		_hit_grace -= dt
	var slow := _reached_min and _hit_grace <= 0.0 and v < _min_v
	if slow != _too_slow:
		_too_slow = slow
		out.push(KIND_TOO_SLOW, 0, 0.0, -1.0, -1, 1.0 if slow else 0.0)
	if not slow:
		_slow_time = 0.0
		_hesitated = false
		return
	_slow_time += dt
	if _slow_time > _sc.hesitation_timeout_s and not _hesitated:
		_hesitated = true
		out.push(KIND_HESITATED)
		_lose_chain(ScoreEvents.REASON_HESITATED, out)
		_mult = _floor


func _step_multiplier(dt: float, player: VehicleState, out: ScoreEventBuffer) -> void:
	if _too_slow:
		_mult = maxf(_floor, _mult - _sc.below_min_drain_per_s * dt)
	else:
		var rate := _sc.multiplier_decay_per_s * _sc.decay_term(player.v)
		if player.boost_active:
			rate *= _sc.boost_decay_factor
		if _on_shoulder:
			rate *= _sc.shoulder_decay_factor
		_mult = maxf(_floor, _mult - rate * dt)
	if player.v < _min_v:
		_dipped = true
	# Cash-out: the multiplier is back at its floor and the player stayed above the
	# minimum speed since the last gain.
	if _chain > 0 and _mult <= _floor and not _dipped:
		_bank(ScoreEvents.REASON_CASH_OUT, out)


# ---------------------------------------------------------------- Events

func _complete_pass(i: int, out: ScoreEventBuffer) -> void:
	var dd := _cross_dd[i]
	if absf(dd) > _sc.pass_lateral_window_m:
		return
	var clr := _min_clear[i]
	var close := clr < _sc.close_pass_clearance_m
	var taint := _taint[i]
	if close and (taint & _TAINT_GHOST) == 0:
		out.push(KIND_NEAR_MISS, 0, 0.0, clr, i)
	if taint != 0:
		return   # ghost period or shoulder during the overlap: scores nothing
	if close:
		_score(ScoreEvents.CLOSE_PASS, _sc.close_pass_points, _sc.close_pass_multiplier_gain, clr, i, out)
		_boost_fill += Units.pct_to_frac(_sc.boost_fill_close_pass_pct)
		_note_close_pass(out)
	else:
		_score(ScoreEvents.PASS, _sc.pass_points, _sc.pass_multiplier_gain, clr, i, out)
	if clr < _sc.thread_clearance_m:
		_thread_check(i, 1 if dd >= 0.0 else -1, _cross_t[i], clr, out)


## One car on each side within the thread window, both under the thread clearance.
func _thread_check(i: int, side: int, cross_t: float, clr: float, out: ScoreEventBuffer) -> void:
	for k in _THREAD_RING:
		if _tr_used[k] == 1 or _tr_side[k] != -side or absf(cross_t - _tr_t[k]) > _sc.thread_window_s:
			continue
		_tr_used[k] = 1
		_score(ScoreEvents.THREAD, _sc.thread_points, _sc.thread_multiplier_gain,
			maxf(clr, _tr_clear[k]), i, out)
		_boost_fill += Units.pct_to_frac(_sc.boost_fill_thread_pct)
		out.push(KIND_SUN_NUDGE, 0, 0.0, -1.0, -1, _day_span_nudge_thread)
		return
	_tr_t[_tr_head] = cross_t
	_tr_side[_tr_head] = side
	_tr_clear[_tr_head] = clr
	_tr_used[_tr_head] = 0
	_tr_head = (_tr_head + 1) % _THREAD_RING


## Five close passes within ten seconds lift the sun (then the count starts over).
func _note_close_pass(out: ScoreEventBuffer) -> void:
	var n := _cp_t.size()
	_cp_t[_cp_head] = _t
	_cp_head = (_cp_head + 1) % n
	_cp_n += 1
	if _cp_n >= n and _t - _cp_t[_cp_head] <= _cp_window:
		_cp_n = 0
		out.push(KIND_SUN_NUDGE, 0, 0.0, -1.0, -1, _day_span_nudge_close)


func _try_cut(lane: int, prev_lane: int, ps: float, traffic: TrafficState, out: ScoreEventBuffer) -> void:
	var nearest := -1
	var nearest_gap := INF
	for i in traffic.capacity:
		if not _cut_candidate(i, lane, prev_lane, ps, traffic):
			continue
		var gap := absf(traffic.s[i] - ps) - (traffic.length[i] * 0.5 - _inset + _p_hl)
		if gap < nearest_gap:
			nearest_gap = gap
			nearest = i
	if nearest < 0:
		return   # no traffic nearby (or all of it on cooldown): weaving scores nothing
	for i in traffic.capacity:
		if _cut_candidate(i, lane, prev_lane, ps, traffic):
			_cut_t[i] = _t
	_score(ScoreEvents.CUT, _sc.cut_points, _sc.cut_multiplier_gain, -1.0, nearest, out)


func _cut_candidate(i: int, lane: int, prev_lane: int, ps: float, traffic: TrafficState) -> bool:
	if traffic.active[i] == 0 or (traffic.lane[i] != lane and traffic.lane[i] != prev_lane):
		return false
	if _t - _cut_t[i] < _sc.cut_per_car_cooldown_s:
		return false
	var gap := absf(traffic.s[i] - ps) - (traffic.length[i] * 0.5 - _inset + _p_hl)
	return gap <= _sc.cut_traffic_window_m


func _score(kind: StringName, base: int, gain: float, clearance: float, slot: int,
		out: ScoreEventBuffer) -> void:
	var pts := roundi(float(base) * _mult * _sf * _night_f)
	out.push(kind, pts, _mult, clearance, slot)
	_chain += pts
	if not gains_blocked():
		_mult += gain
		_dipped = false


func _bank(reason: StringName, out: ScoreEventBuffer) -> void:
	if _chain <= 0:
		return
	var amount := _chain
	_chain = 0
	_banked += amount
	out.push(KIND_BANKED, amount, _mult, -1.0, -1, float(_banked), reason)


func _lose_chain(reason: StringName, out: ScoreEventBuffer) -> void:
	if _chain <= 0:
		return
	var amount := _chain
	_chain = 0
	out.push(KIND_CHAIN_LOST, amount, _mult, -1.0, -1, 0.0, reason)


# ---------------------------------------------------------------- Run hooks

func set_night(on: bool) -> void:
	_night = on
	_night_f = _sc.night_factor if on else 1.0


## Ghost period after a hit (lives): nothing scores. A pass whose overlap window
## touches the ghost period never scores; cuts and slipstream are off.
func set_ghost(on: bool) -> void:
	_ghost = on


## First (or any) hit: the chain is lost, the multiplier drops to its start value and
## the minimum-speed rule pauses for min_speed_grace_after_hit_s.
func notify_hit(out_events: ScoreEventBuffer) -> void:
	if _ended:
		return
	_lose_chain(ScoreEvents.REASON_HIT, out_events)
	_mult = _floor
	_hit_grace = _sc.min_speed_grace_after_hit_s
	_slow_time = 0.0
	_hesitated = false
	if _too_slow:
		_too_slow = false
		out_events.push(KIND_TOO_SLOW, 0, 0.0, -1.0, -1, 0.0)
	_clear_thread_ring()


## Checkpoint: the chain banks (the multiplier is kept).
func notify_checkpoint(out_events: ScoreEventBuffer) -> void:
	if _ended:
		return
	_bank(ScoreEvents.REASON_CHECKPOINT, out_events)


## Straight into the banked total, x night_factor while set_night(true). For a leg
## finished at night, run.gd pays the leg bonuses before the dawn clears the night.
func award_bonus(bonus_kind: StringName, base_points: int, out_events: ScoreEventBuffer) -> void:
	if _ended:
		return
	var pts := roundi(float(base_points) * _night_f)
	_banked += pts
	out_events.push(KIND_BONUS, pts, 0.0, -1.0, -1, float(_banked), bonus_kind)


## Run over: the held chain is lost; the final score is banked(). Later calls are ignored.
func notify_run_end(out_events: ScoreEventBuffer) -> void:
	if _ended:
		return
	_lose_chain(ScoreEvents.REASON_RUN_END, out_events)
	_ended = true


# ---------------------------------------------------------------- Queries

func multiplier() -> float:
	return _mult


func chain() -> int:
	return _chain


func banked() -> int:
	return _banked


func take_boost_fill() -> float:
	var f := _boost_fill
	_boost_fill = 0.0
	return f


## Below the minimum speed with the rule active (HUD TOO SLOW; the sun sinks 3x).
func is_too_slow() -> bool:
	return _too_slow


## Any wheel on the shoulder this tick.
func is_on_shoulder() -> bool:
	return _on_shoulder


## The shoulder penalty (more than shoulder_penalty_after_s on the shoulder, and the
## block after leaving it).
func shoulder_penalty_active() -> bool:
	return _penalty


## Multiplier gains are blocked (on the shoulder, or the shoulder penalty).
func gains_blocked() -> bool:
	return _on_shoulder or _penalty


func is_slipstreaming() -> bool:
	return _slip


func is_ghost() -> bool:
	return _ghost


func is_night() -> bool:
	return _night


func is_ended() -> bool:
	return _ended


## Hash of the rule state (determinism traces).
func hash_into(h: int) -> int:
	h = TraceHash.mix_float(h, _t)
	h = TraceHash.mix_float(h, _mult)
	h = TraceHash.mix_int(h, _chain)
	h = TraceHash.mix_int(h, _banked)
	h = TraceHash.mix_float(h, _boost_fill)
	h = TraceHash.mix_float(h, _slow_time)
	h = TraceHash.mix_float(h, _hit_grace)
	h = TraceHash.mix_float(h, _shoulder_time)
	h = TraceHash.mix_float(h, _penalty_block)
	h = TraceHash.mix_int(h, _prev_lane)
	h = TraceHash.mix_bool(h, _too_slow)
	h = TraceHash.mix_bool(h, _dipped)
	h = TraceHash.mix_bool(h, _slip)
	h = TraceHash.mix_i32_array(h, _vid, _cap)
	h = TraceHash.mix_i32_array(h, _phase, _cap)
	h = TraceHash.mix_f64_array(h, _min_clear, _cap)
	h = TraceHash.mix_f64_array(h, _cut_t, _cap)
	return h


func trace_hash() -> int:
	return hash_into(TraceHash.SEED)


# ---------------------------------------------------------------- Storage

func _ensure_slots(n: int) -> void:
	if n <= _cap:
		return
	_vid.resize(n)
	_phase.resize(n)
	_taint.resize(n)
	_crossed.resize(n)
	_min_clear.resize(n)
	_cross_dd.resize(n)
	_cross_t.resize(n)
	_cut_t.resize(n)
	for i in range(_cap, n):
		_vid[i] = 0
	_cap = n


func _clear_thread_ring() -> void:
	_tr_used.fill(1)
	_tr_head = 0
