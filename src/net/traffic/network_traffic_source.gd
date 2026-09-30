class_name NetworkTrafficSource
extends SpawnSource
# lint: sim
## Server-driven traffic on the client: the multiplayer spawn source. Spec: multiplayer
## handoff → Traffic: server-authoritative with intents → Client network traffic ("A new
## traffic source. It plugs into the existing SpawnSource interface. In network mode the
## client director and client MOBIL are off; lane changes come only from server intents."
## "Longitudinal motion is local." "Server time, not frame time." Corrections, Late
## intents, Local-only extras), What the server sends; plan N4.3, MP-D6. Design, numbers and
## the server checklist: docs/NET_TRAFFIC.md. WP N4.3.
##
##   var src := NetworkTrafficSource.new(tuning.net, tuning.traffic, road, registry, sim.state)
##   src.set_headway_scale(tuning.director.headway_scale(loop_tuning.director_leg))
##   # per decoded server frame (NetCodec.decode_server_frame_into):
##   src.apply_frame(frame, car.state.s, clock.server_now(), one_way_ticks)
##   # per 120 Hz tick, instead of sim.step + director.step:
##   src.step(clock.server_now(), car.state, events)
##   src.notify_hit(slot)   # a local hit: hazards and a hard brake now, the server confirms
##
## It publishes into a TrafficState (usually the run's `sim.state`, which the sim then no
## longer steps), so TrafficView, hits, scoring, headlight cones and the sandbox see the
## network cars exactly like local ones. Slots and vehicle ids are the TrafficState's own
## (vehicle_id is unique per spawn; the wire car_id may come back after 30 s, MP-D6).
##
## **The model.** Every car known to the client runs the server's longitudinal model at
## the server's tick boundaries: integrate over one 20 Hz tick with the acceleration held
## from the last tick, then IDM toward its leader (the same leader search by lateral
## overlap as TrafficSim, the local player included as a participant, the profile's
## parameters, the leg's headway scale and the racers' weaving T / s0 / b toward traffic),
## the road's lane-drop harmonisation zones (WP6.8, mirrored), the MP-D5 lane-drop queue
## safety on the following side (WP6.11: looking through a leader that signals or moves out
## of the path, from its intent; braking for a leader's stopping point), the brake tap when
## the player cuts in, hard brakes and the clamp. It runs up to the
## integer part of `server_now()`; the published state is that tick's state carried
## ballistically to the fraction, so it moves smoothly between ticks and matches the
## server's discrete trajectory when the model agrees. MOBIL, lane splitting, lane-drop
## merging and the director never run here: lateral motion comes from intents only.
## The desired speed is not on the wire, so it is estimated from the corrections (free
## driving), with a per-car acceleration bias for what the model does not know (server
## rules, remote players); see TrafficCorrector for the history and blending.
##
## Pure (no Node or autoload access); allocation-free per tick (step, apply_frame,
## notify_hit and the queries), except `sync_road` (the road's lane drops, every ~1 km of
## the player's travel, director rate).

const SOURCE_ID := &"network"
const NO_SLOT := -1
## Car ids are u16.
const CAR_IDS := 65536
## Smoothstep 3u^2 - 2u^3 and its derivative 6u(1 - u).
const _SMOOTH_A := 3.0   # lint: allow-number smoothstep polynomial coefficient
const _SMOOTH_D := 6.0   # lint: allow-number smoothstep derivative coefficient
const _NONE := TrafficState.LaneChange.NONE
const _SIGNALING := TrafficState.LaneChange.SIGNALING
const _MOVING := TrafficState.LaneChange.MOVING
const _BLINKERS := TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BLINKER_RIGHT
## NetCodec.INTENT_KIND indices.
const INTENT_LANE_CHANGE := 0
const INTENT_CANCEL := 1
const INTENT_HAZARD := 2
const INTENT_HORN := 3
const INTENT_HARD_BRAKE := 4
const _PEND_HAZ_ON := 1
const _PEND_HAZ_OFF := 2
const _PEND_HORN := 4

var state: TrafficState
var road: RoadPath
var registry: TrafficRegistry
var traffic: TrafficTuning
var net: NetTuning
var corrector: TrafficCorrector
var stats: NetTrafficStats
## Server tick length (s).
var tick_dt: float
## The model's tick (-1 before the first frame or step).
var model_tick: int = -1
## Server time (ticks) of the last step.
var now_ticks: float = 0.0

var _cap: int
var _P: int
var _slot_of := PackedInt32Array()
var _cid := PackedInt32Array()
# Model state at model_tick (s unwrapped, road frame).
var _ms := PackedFloat64Array()
var _mv := PackedFloat64Array()
var _ma := PackedFloat64Array()
var _ma_held := PackedFloat64Array()  # the acceleration this model tick integrated with (the server's
                                      # state.accel of a leader when its followers are evaluated)
var _base_d := PackedFloat64Array()   # lateral position outside a lane change
var _v0e := PackedFloat64Array()      # estimated desired speed
var _bias := PackedFloat64Array()     # estimated unexplained acceleration
var _last_ct := PackedInt64Array()    # tick of the last applied correction (-1: none)
var _last_cv := PackedFloat64Array()  # the server's v at it
var _last_cs := PackedFloat64Array()  # ... its s (unwrapped) and d (overlays)
var _last_cd := PackedFloat64Array()
var _last_err := PackedFloat64Array() # ... and its size (m)
var _heard := PackedFloat64Array()    # server time (ticks) the car was last heard of
var _int_sum := PackedFloat64Array()  # |IDM interaction term| summed since the last correction
var _int_n := PackedInt32Array()
# Lane change from an intent (times in server ticks, fractional).
var _lc := PackedByteArray()          # 1 = a lane change is planned or running
var _lc_blink := PackedFloat64Array() # blinker visible from
var _lc_move := PackedFloat64Array()  # the server's move start
var _lc_dur := PackedFloat64Array()   # the move's length
var _lc_hold := PackedFloat64Array()  # the client's lateral start (late intents)
var _lc_catch := PackedFloat64Array() # catch-up length after a late hold (0: none)
var _lc_from := PackedFloat64Array()
var _lc_to := PackedFloat64Array()
var _lc_lane := PackedInt32Array()
var _lc_cancel := PackedFloat64Array() # a cancel dated ahead (a Hesitant's): the plan ends there
# Reactions.
var _haz_until := PackedFloat64Array()   # hazard intent (server ticks)
var _brake_from := PackedFloat64Array()  # hard brake intent / local hit
var _brake_until := PackedFloat64Array()
var _hit_until := PackedFloat64Array()   # local hit: FLAG_HIT until
var _own_haz := PackedByteArray()        # the spawn's hazard flag
var _brk_spawn := PackedByteArray()      # the spawn's braking flag (until the first model tick)
var _tap_t := PackedFloat64Array()
var _prev_lead_p := PackedByteArray()
var _pend := PackedInt32Array()
var _n_pend: int = 0
# Published continuity (the teleport metric).
var _pub_s := PackedFloat64Array()
var _pub_d := PackedFloat64Array()
var _pub_ok := PackedByteArray()
var _pub_t: float = 0.0
# Lane-drop harmonisation zones (the road's; TrafficSim's WP6.8 zones, mirrored).
var zone_syncs: int = 0
var _dz_n: int = 0
var _dz_s0 := PackedFloat64Array()
var _dz_s1 := PackedFloat64Array()
var _dz_lane := PackedInt32Array()
var _dz_lo: float = INF
var _dz_hi: float = -INF
var _dz_to: float = -INF
var _match := PackedFloat64Array()     # per slot: the last speed-matching factor
# Order by s (active slots + the player at _P) and the mirrors of the model tick.
var _ord := PackedInt32Array()
var _n: int = 0
var _ks := PackedFloat64Array()
var _kv := PackedFloat64Array()
var _khl := PackedFloat64Array()
var _klo := PackedFloat64Array()
var _khi := PackedFloat64Array()
# Per profile.
var _pa := PackedFloat64Array()
var _pb := PackedFloat64Array()
var _pT := PackedFloat64Array()
var _ps0 := PackedFloat64Array()
var _pdl := PackedInt32Array()
var _pweave := PackedByteArray()
var _wTk := PackedFloat64Array()
var _ws0 := PackedFloat64Array()
var _wb := PackedFloat64Array()
var _v0lo := PackedFloat64Array()
var _v0hi := PackedFloat64Array()
# Player (road frame) at server time _p_t.
var _p_s: float = 0.0
var _p_v: float = 0.0
var _p_d: float = 0.0
var _p_vl: float = 0.0
var _p_t: float = 0.0
var _plen: float
var _pw: float
var _headlights := false
# Scratch: the lateral evaluation of _lat().
var _q_d: float = 0.0
var _q_vl: float = 0.0
var _q_phase: int = 0
var _q_timer: float = 0.0
var _q_dur: float = 0.0
var _q_v0: float = 0.0
# Cached tuning.
var _max_decel: float
var _brake_decel: float
var _brake_strong: float
var _look: float
var _gap_floor: float
var _lat_m: float
var _antic: float
var _hit_recover_t: float
var _hit_decel: float
var _hit_brake_t: float
var _tap_decel: float
var _tap_s: float
var _cut_in_m: float
var _react_cool: float
var _stale_t: float
var _max_catchup: int
var _v0_gain: float
var _v0_free: float
var _v0_margin: float
var _bias_gain: float
var _bias_max: float
var _bias_fade_s: float
var _near_m: float
var _vis_behind: float
var _vis_ahead: float
var _unsig_m: float
var _teleport_v: float
var _drop_view: float
var _drop_release: float
var _drop_after: float
var _drop_slow: float
var _drop_narrow: float
var _drop_onset: float
var _v_through: float
var _v_merge: float
var _sync_lead: float
var _sync_len: float
var _sync_back: float
var _look_through := false   # MP-D5 (TrafficTuning.look_through_leaving_leaders)
var _anticipate := false     # MP-D5 (TrafficTuning.anticipate_leader_braking)


func _init(net_tuning: NetTuning, traffic_tuning: TrafficTuning, road_path: RoadPath,
		reg: TrafficRegistry, published: TrafficState) -> void:
	net = net_tuning
	traffic = traffic_tuning
	road = road_path
	registry = reg
	state = published
	tick_dt = 1.0 / net.tick_rate_hz
	_cap = state.capacity
	_P = _cap
	corrector = TrafficCorrector.new(_cap, net, tick_dt)
	stats = NetTrafficStats.new(net.traffic_metrics_window_s)
	_cache_tuning()
	_init_profiles()
	_slot_of.resize(CAR_IDS)
	_slot_of.fill(NO_SLOT)
	_cid.resize(_cap)
	_ms.resize(_cap)
	_mv.resize(_cap)
	_ma.resize(_cap)
	_ma_held.resize(_cap)
	_base_d.resize(_cap)
	_v0e.resize(_cap)
	_bias.resize(_cap)
	_last_ct.resize(_cap)
	_last_cv.resize(_cap)
	_last_cs.resize(_cap)
	_last_cd.resize(_cap)
	_last_err.resize(_cap)
	_heard.resize(_cap)
	_int_sum.resize(_cap)
	_int_n.resize(_cap)
	_lc.resize(_cap)
	_lc_blink.resize(_cap)
	_lc_move.resize(_cap)
	_lc_dur.resize(_cap)
	_lc_hold.resize(_cap)
	_lc_catch.resize(_cap)
	_lc_from.resize(_cap)
	_lc_to.resize(_cap)
	_lc_lane.resize(_cap)
	_lc_cancel.resize(_cap)
	_haz_until.resize(_cap)
	_brake_from.resize(_cap)
	_brake_until.resize(_cap)
	_hit_until.resize(_cap)
	_own_haz.resize(_cap)
	_brk_spawn.resize(_cap)
	_tap_t.resize(_cap)
	_prev_lead_p.resize(_cap)
	_pend.resize(_cap)
	_pub_s.resize(_cap)
	_pub_d.resize(_cap)
	_pub_ok.resize(_cap)
	_match.resize(_cap)
	_dz_s0.resize(TrafficSim.MAX_DROP_ZONES)
	_dz_s1.resize(TrafficSim.MAX_DROP_ZONES)
	_dz_lane.resize(TrafficSim.MAX_DROP_ZONES)
	_ord.resize(_cap + 1)
	_ks.resize(_cap + 1)
	_kv.resize(_cap + 1)
	_khl.resize(_cap + 1)
	_klo.resize(_cap + 1)
	_khi.resize(_cap + 1)
	_plen = traffic.player_length_m
	_pw = traffic.player_width_m
	clear()


func source_id() -> StringName:
	return SOURCE_ID


## The director is off in network mode: nothing is planned locally (the server spawns).
func plan_batch(_ctx: SpawnSource.Context, _s_from: float, _s_to: float,
		_out_spawns: Array[SpawnSource.Record]) -> void:
	pass


## Drops every car (joining another room, a reconnect). The next frame starts over.
func clear() -> void:
	for i in _cap:
		if state.active[i] == 1:
			_slot_of[_cid[i]] = NO_SLOT
			state.free_slot(i)
	_slot_of.fill(NO_SLOT)
	model_tick = -1
	now_ticks = 0.0
	_pub_t = 0.0
	_n = 1
	_ord[0] = _P
	_ks[_P] = -INF
	_kv[_P] = 0.0
	_khl[_P] = _plen * 0.5
	_klo[_P] = NAN
	_khi[_P] = NAN
	_n_pend = 0
	_pend.fill(0)
	_dz_n = 0
	_dz_to = -INF
	_dz_lo = INF
	_dz_hi = -INF


## The player's body (the CarDef's size), as TrafficSim.set_player_body.
func set_player_body(length_m: float, width_m: float) -> void:
	_plen = length_m
	_pw = width_m
	_khl[_P] = _plen * 0.5


## The leg's IDM headway scale (plan D11; the server uses the loop's director leg).
func set_headway_scale(scale: float) -> void:
	for p in _pT.size():
		_pT[p] = registry.headway[p] * scale


## Headlights on every car (client-side: the room clock's night).
func set_headlights(on: bool) -> void:
	_headlights = on


func headlights() -> bool:
	return _headlights


## Slot of a wire car id (NO_SLOT when unknown).
func slot_of(wire_car_id: int) -> int:
	return _slot_of[wire_car_id & 0xFFFF]


## Wire car id of a live slot.
func car_id(slot: int) -> int:
	return _cid[slot]


## The model's desired-speed estimate and acceleration bias of a slot (sandbox, tests).
func v0_estimate(slot: int) -> float:
	return _v0e[slot]


func accel_bias(slot: int) -> float:
	return _bias[slot]


## The current offset still being blended out (m), longitudinal and lateral (overlays).
func offset_s(slot: int) -> float:
	return corrector.off_s[slot]


func offset_d(slot: int) -> float:
	return corrector.off_d[slot]


## A lane change is planned or running for the slot; its times (server ticks) for the
## sandbox's intent timelines.
func has_lane_change(slot: int) -> bool:
	return _lc[slot] == 1


func lane_change_blink_tick(slot: int) -> float:
	return _lc_blink[slot]


func lane_change_move_tick(slot: int) -> float:
	return _lc_move[slot]


func lane_change_hold_tick(slot: int) -> float:
	return _lc_hold[slot]


func lane_change_end_tick(slot: int) -> float:
	return maxf(_lc_move[slot] + _lc_dur[slot], _lc_hold[slot] + _lc_catch[slot])


## Tick of the last applied correction of the slot (-1: none), the server's state in it
## and its size (overlays: the "last correction" ghost).
func last_correction_tick(slot: int) -> int:
	return _last_ct[slot]


func last_correction_s(slot: int) -> float:
	return _last_cs[slot]


func last_correction_d(slot: int) -> float:
	return _last_cd[slot]


func last_correction_v(slot: int) -> float:
	return _last_cv[slot]


func last_correction_error(slot: int) -> float:
	return _last_err[slot]


## Counts the protocol bytes of a received frame (dev HUD bytes/s).
func note_frame_bytes(n: int) -> void:
	stats.bytes += n


# ---------------------------------------------------------------- Frames

## Applies one decoded server frame: despawns, spawns, intents, corrections (in that order,
## whatever their order in the frame). `player_s` is the player's unwrapped s (places the
## wrapped wire s on the right lap), `now` the server time (ticks) at arrival, and
## `one_way_ticks` the estimated one-way delay, which dates a spawn when the frame carries
## no correction batch. Allocation-free.
func apply_frame(frame: NetServerFrame, player_s: float, now: float, one_way_ticks: float) -> void:
	stats.frames += 1
	if model_tick < 0:
		_start(now)
	var frame_tick := roundi(now - one_way_ticks)
	if frame.co_count > 0:
		frame_tick = frame.co_tick[0]
	var changed := false
	for k in frame.ds_count:
		var i := slot_of(frame.ds_car_id[k])
		if i == NO_SLOT:
			stats.unknown_car += 1
			continue
		_despawn(i)
		stats.despawns += 1
	for k in frame.sp_count:
		if _spawn_from(frame, k, frame_tick, player_s, now):
			changed = true
	for k in frame.in_count:
		_intent_from(frame, k, now)
	for k in frame.co_count:
		if _correct_from(frame, k, player_s, now):
			changed = true
	if changed:
		_sort()
		_accel_pass(false, null)


# ---------------------------------------------------------------- Tick

## Advances the model to `now` (server ticks, NetClock.server_now()) and publishes every car
## at `now` into the TrafficState. `player` is the local player's state (a participant:
## a leader for the cars behind it). Local events (a hit's hazards, horns from intents,
## brake taps) go to `out_events` when given. Allocation-free.
func step(now: float, player: VehicleState, out_events: ScoreEventBuffer) -> void:
	if model_tick < 0:
		_start(now)
	_read_player(player, now)
	if _p_s + _sync_lead > _dz_to:
		sync_road(_p_s - _sync_back, _p_s + _sync_len)   # lint: allow-alloc road features, every ~1 km of travel
	if _n_pend > 0 and out_events != null:
		_emit_pending(out_events)
	var target := floori(now)
	var steps := 0
	while model_tick < target and steps < _max_catchup:
		_model_step(out_events)
		steps += 1
	if model_tick < target:
		model_tick = target   # a stall: skip ahead, corrections put the cars back
	var dt_s := maxf(now - now_ticks, 0.0) * tick_dt
	now_ticks = now
	_step_stale(now)
	_publish(now, dt_s)
	stats.sample(now * tick_dt)


## The player hit this car (client-side, at once): hazards, a hard brake and FLAG_HIT for
## the recovery time, as TrafficSim.notify_hit (no swerve: the server's corrections bring
## its reaction). The server's own hazard / hard-brake intents follow. Allocation-free.
func notify_hit(slot: int) -> void:
	if slot < 0 or slot >= _cap or state.active[slot] == 0:
		return
	var now := now_ticks
	_hit_until[slot] = now + _hit_recover_t
	_brake_from[slot] = float(model_tick)
	_brake_until[slot] = maxf(_brake_until[slot], now + _hit_brake_t)
	if _lc[slot] == 1 and now < _lc_hold[slot]:
		_lc[slot] = 0
		state.target_lane[slot] = state.lane[slot]
	_queue(slot, _PEND_HAZ_ON)
	_accel_pass(false, null)


func _start(now: float) -> void:
	model_tick = floori(now)
	now_ticks = now
	_pub_t = now


func _model_step(out_events: ScoreEventBuffer) -> void:
	model_tick += 1
	var dt := tick_dt
	var fade := minf(dt / maxf(_bias_fade_s, dt), 1.0)
	for k in _n:
		var i := _ord[k]
		if i == _P:
			continue
		var a := _ma[i]
		_ma_held[i] = a
		var v := _mv[i]
		var s := _ms[i]
		var nv := v + a * dt
		if nv < 0.0:
			if a < 0.0:
				s -= v * v / (2.0 * a)
			nv = 0.0
		else:
			s += (v + nv) * 0.5 * dt
		_ms[i] = s
		_mv[i] = nv
		_bias[i] -= _bias[i] * fade
		_brk_spawn[i] = 0
	_sort()
	_accel_pass(true, out_events)
	var tk := model_tick
	for k in _n:
		var i := _ord[k]
		if i != _P:
			corrector.record(i, tk, _ms[i], _mv[i], _ks_d(i))


## Accelerations of every car at model_tick (the leader at the same instant, IDM, the
## bias, reactions, the clamp). `advance`: a real model tick (timers, the estimator's
## interaction sums, brake-tap events); false: a re-evaluation after a frame changed the
## state at the same tick.
func _accel_pass(advance: bool, out: ScoreEventBuffer) -> void:
	var tk := float(model_tick)
	for k in _n:
		var i := _ord[k]
		if i == _P:
			continue
		var si := _ks[i]
		var vi := _kv[i]
		var p := state.profile_id[i]
		var v0 := _v0e[i]
		var drop_a := INF
		_match[i] = 0.0
		var front := si + _khl[i]
		if _dz_n > 0 and front > _dz_lo and front < _dz_hi:
			drop_a = _drop_accel(i, front, vi, v0, p)
			v0 = _q_v0
		var lo := _klo[i] - _lat_m
		var hi := _khi[i] + _lat_m
		var lead := -1
		var kk := k + 1
		while kk < _n:
			var j := _ord[kk]
			if _ks[j] - si > _look:
				break
			if _klo[j] < hi and _khi[j] > lo:
				lead = j
				break
			kk += 1
		var lead_k := kk
		var free := Idm.free_accel(vi, v0, _pa[p], _pdl[p])
		var a := free
		var gap := INF
		if lead >= 0:
			gap = _ks[lead] - si - _khl[lead] - _khl[i]
			if _pweave[p] == 1 and lead != _P:
				a = Idm.accel(vi, v0, gap, vi - _kv[lead], _pa[p], _wb[p], _pT[p] * _wTk[p], _ws0[p],
					_pdl[p], _gap_floor)
			else:
				a = Idm.accel(vi, v0, gap, vi - _kv[lead], _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p],
					_gap_floor)
			# MP-D5 (TrafficSim._step_accel's order): past a leader leaving the path, the
			# next one counts too; and the leader's own stopping point.
			# (The guards skip the calls for a leader in lane and not braking.)
			if _look_through and lead != _P and _lc[lead] == 1:
				a = minf(a, _look_through_accel(i, lead, lead_k, lo, hi, vi, v0, p, tk))
			if _anticipate and ((lead != _P and _ma_held[lead] < 0.0) or _kv[lead] <= 0.0):
				a = minf(a, _anticipation_accel(lead, gap, vi, p))
		a = minf(a, drop_a)
		if advance:
			_int_sum[i] += free - a
			_int_n[i] += 1
		a += _bias[i]
		# The brake tap when the player cuts in (TrafficSim._step_accel's rule).
		var tap := _tap_t[i]
		var lead_p := lead == _P
		if advance:
			if tap > -_react_cool:
				tap = maxf(tap - tick_dt, -_react_cool)
			if lead_p and _prev_lead_p[i] == 0 and gap < _cut_in_m and tap <= -_react_cool:
				tap = _tap_s
				if out != null:
					out.push(TrafficSim.KIND_BRAKE_TAP, 0, 0.0, -1.0, i, gap, TrafficSim.TAG_CUT_IN)
			_tap_t[i] = tap
			_prev_lead_p[i] = 1 if lead_p else 0
		if tap > 0.0:
			a = minf(a, -_tap_decel)
		if tk >= _brake_from[i] and tk < _brake_until[i]:
			a = minf(a, -_hit_decel)
		if a < -_max_decel:
			a = -_max_decel
		_ma[i] = a


## TrafficSim._look_through_accel on the physical paths (MP-D5): while the leader `l` (at
## order position `lk`) signals or moves out of [lo, hi] at tick `tk`, the next vehicle on
## the path beyond it counts too (the most restrictive IDM acceleration; -INF on overlap).
func _look_through_accel(i: int, l: int, lk: int, lo: float, hi: float, vi: float, v0: float, p: int,
		tk: float) -> float:
	var si := _ks[i]
	var a := INF
	var cur := l
	var kk := lk + 1
	while _leaving_path(cur, lo, hi, tk):
		var nxt := -1
		while kk < _n:
			var j := _ord[kk]
			kk += 1
			if j == i or _ks[j] - si > _look:
				break
			if _klo[j] < hi and _khi[j] > lo:
				nxt = j
				break
		if nxt < 0:
			break
		var gap := _ks[nxt] - si - _khl[nxt] - _khl[i]
		if gap <= 0.0:
			return -INF
		if _pweave[p] == 1 and nxt != _P:
			a = minf(a, Idm.accel(vi, v0, gap, vi - _kv[nxt], _pa[p], _wb[p], _pT[p] * _wTk[p], _ws0[p], _pdl[p],
				_gap_floor))
		else:
			a = minf(a, Idm.accel(vi, v0, gap, vi - _kv[nxt], _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p], _gap_floor))
		cur = nxt
	return a


## TrafficSim._anticipation_accel (MP-D5) with the acceleration the leader's model held
## over this tick (the server's state.accel when it evaluates the follower; the player
## holds its speed).
func _anticipation_accel(l: int, gap: float, vi: float, p: int) -> float:
	var vl := _kv[l]
	var al := 0.0 if l == _P else _ma_held[l]
	var stop_l := 0.0
	if al < 0.0:
		stop_l = vl * vl / (-2.0 * al)
	elif vl > 0.0:
		return INF
	var room := gap - _ps0[p] + stop_l
	var a_stop := -(vi * vi) / (2.0 * room) if room > 0.0 else -INF
	return a_stop if a_stop < -_pb[p] else INF


## TrafficSim._leaving_path from the car's intent: a lane change signalled or moving at
## tick `tk` (the blinker on, not cancelled) whose target body does not overlap [lo, hi].
func _leaving_path(j: int, lo: float, hi: float, tk: float) -> bool:
	if j == _P or _lc[j] == 0 or tk < _lc_blink[j] or tk >= _lc_cancel[j]:
		return false
	var hw := state.width[j] * 0.5
	var t := _lc_to[j]
	return not (t - hw < hi and t + hw > lo)


# ---------------------------------------------------------------- Messages

func _spawn_from(f: NetServerFrame, k: int, frame_tick: int, player_s: float, now: float) -> bool:
	var cid := f.sp_car_id[k]
	var i := _slot_of[cid]
	if i != NO_SLOT:
		_despawn(i)   # a repeated spawn replaces the car
	var tid := f.sp_vehicle[k]
	var pid := f.sp_profile[k]
	if tid >= registry.type_count() or pid >= registry.profile_count():
		stats.bad_values += 1
		tid = mini(tid, registry.type_count() - 1)
		pid = mini(pid, registry.profile_count() - 1)
	i = state.allocate()
	if i < 0:
		stats.dropped_full += 1
		return false
	stats.spawns += 1
	_slot_of[cid] = i
	_cid[i] = cid
	var s := NetTrafficWire.s_unwrap(road, NetCodec.s_from_wire(f.sp_s_mm[k]), player_s)
	var d := NetTrafficWire.d_from_wire(f.sp_d_cm[k])
	var v := NetCodec.speed_from_wire(f.sp_speed_cms[k])
	var lanes := road.lane_count(s)
	var lane := NetTrafficWire.lane_from_wire(f.sp_lane[k], lanes)
	state.type_id[i] = tid
	state.profile_id[i] = pid
	state.model_variant[i] = cid
	state.color_index[i] = f.sp_color[k]
	state.length[i] = registry.length[tid]
	state.width[i] = registry.width[tid]
	state.lane[i] = lane
	state.target_lane[i] = lane
	var mid := (registry.v0_min[pid] + registry.v0_max[pid]) * 0.5
	_v0e[i] = clampf(maxf(v, mid), _v0lo[pid], _v0hi[pid])
	state.v0[i] = _v0e[i]
	_bias[i] = 0.0
	_int_sum[i] = 0.0
	_int_n[i] = 0
	_last_ct[i] = -1
	_last_cv[i] = v
	_last_cs[i] = s
	_last_cd[i] = d
	_last_err[i] = 0.0
	_heard[i] = now
	_haz_until[i] = -INF
	_brake_from[i] = INF
	_brake_until[i] = -INF
	_hit_until[i] = -INF
	var fl := f.sp_flags[k]
	_own_haz[i] = 1 if (fl & 1) != 0 else 0
	_brk_spawn[i] = 1 if (fl & 2) != 0 else 0
	_tap_t[i] = -_react_cool
	_prev_lead_p[i] = 0
	_pend[i] = 0
	_pub_ok[i] = 0
	corrector.reset_slot(i)
	# The state is at frame_tick; carry it to the model's tick.
	var dt_k := float(model_tick - frame_tick) * tick_dt
	_ms[i] = s + v * dt_k
	_mv[i] = v
	_ma[i] = 0.0
	_ma_held[i] = 0.0
	_base_d[i] = d
	_lc[i] = 0
	var phase := f.sp_lc_phase[k]
	if phase != _NONE:
		var tl := _target_lane(i, f.sp_lc_target_lane[k], s)
		var move_t := float(f.sp_lc_move_start_tick[k])
		var dur_t := NetTrafficWire.ms_to_s(f.sp_lc_duration_ms[k]) / tick_dt
		var to_d := road.lane_center_d(tl, s)
		var from_d := d
		if phase == _MOVING and dur_t > 0.0:
			var sm := _smooth(clampf((float(frame_tick) - move_t) / dur_t, 0.0, 1.0))
			from_d = (d - to_d * sm) / (1.0 - sm) if sm < 1.0 else to_d
		_set_plan(i, tl, float(frame_tick), move_t, dur_t, from_d, to_d)
		if phase == _MOVING:
			_lc_hold[i] = move_t   # already moving: no hold, no catch-up
			_lc_catch[i] = 0.0
		else:
			_lc_blink[i] = maxf(float(frame_tick), now)
			_lc_hold[i] = corrector.hold_tick(_lc_blink[i], move_t)
			_lc_catch[i] = corrector.catchup_ticks() if _lc_hold[i] > move_t else 0.0
	_add_to_order(i)
	for t in range(maxi(frame_tick, model_tick - corrector.hist_n + 1), model_tick + 1):
		corrector.record(i, t, s + v * float(t - frame_tick) * tick_dt, v, _lat_at(i, float(t)))
	return true


func _intent_from(f: NetServerFrame, k: int, now: float) -> void:
	var i := slot_of(f.in_car_id[k])
	if i == NO_SLOT:
		stats.unknown_car += 1
		return
	_heard[i] = now
	var start := float(f.in_start_tick[k])
	var move_t := float(f.in_move_start_tick[k])
	var dur_t := NetTrafficWire.ms_to_s(f.in_duration_ms[k]) / tick_dt
	match f.in_kind[k]:
		INTENT_LANE_CHANGE:
			stats.intents += 1
			if _lc[i] == 1:
				_complete_plan(i, now)
			# The lane numbering is converted at the car's s at the signal tick (the server's).
			var s := _ms[i]
			if corrector.lookup(i, f.in_start_tick[k]):
				s = corrector.q_s
			var tl := _target_lane(i, f.in_target_lane[k], s)
			var from_d := _base_d[i]
			_set_plan(i, tl, maxf(start, now), move_t, dur_t, from_d, road.lane_center_d(tl, s))
			if now > move_t - corrector.min_blinker_ticks():
				stats.late_intents += 1
			if now > move_t:
				stats.very_late_intents += 1
		INTENT_CANCEL:
			stats.cancels += 1
			if _lc[i] == 0:
				return
			if start > now:
				_lc_cancel[i] = start   # decided ahead: the blinker goes off there, no move
				return
			if now < _lc_hold[i]:
				_lc[i] = 0
				return
			# The car already moves on the client: back to its lane like an unsignaled slide.
			stats.late_cancels += 1
			var before := _lat_at(i, now)
			_lc[i] = 0
			state.target_lane[i] = state.lane[i]
			var after := _lat_at(i, now)
			corrector.add_offset(i, 0.0, before - after, _visible(i), true, now)
			stats.unsignaled_lateral += 1
			# The server's car never left its line: the history from the cancel on must not
			# hold the move either, or the next correction dated there reads the move as a
			# lateral error and shifts the car's line by it (WP6.11: an unsignaled 8 cm slide).
			for t in range(maxi(f.in_start_tick[k], model_tick - corrector.hist_n + 1), model_tick + 1):
				if corrector.lookup(i, t):
					corrector.record(i, t, corrector.q_s, corrector.q_v, _lat_at(i, float(t)))
		INTENT_HAZARD:
			_haz_until[i] = maxf(_haz_until[i], start + dur_t)
		INTENT_HORN:
			_queue(i, _PEND_HORN)
		INTENT_HARD_BRAKE:
			_brake_from[i] = start
			_brake_until[i] = start + dur_t


func _correct_from(f: NetServerFrame, k: int, player_s: float, now: float) -> bool:
	var i := slot_of(f.co_car_id[k])
	if i == NO_SLOT:
		stats.unknown_car += 1
		return false
	var n := f.co_tick[k]
	if n <= _last_ct[i]:
		stats.old_corrections += 1
		return false
	_heard[i] = now
	var s_srv := NetTrafficWire.s_unwrap(road, NetCodec.s_from_wire(f.co_s_mm[k]), player_s)
	var d_srv := NetTrafficWire.d_from_wire(f.co_d_cm[k])
	var v_srv := NetCodec.speed_from_wire(f.co_speed_cms[k])
	var kt := model_tick
	var ps := 0.0
	var pv := 0.0
	var pd := 0.0
	if corrector.lookup(i, n):
		ps = corrector.q_s
		pv = corrector.q_v
		pd = corrector.q_d
	else:
		if n < kt:
			stats.no_history += 1
		var dt_n := float(n - kt) * tick_dt
		ps = _ms[i] + _mv[i] * dt_n
		pv = _mv[i]
		if dt_n > 0.0:
			ps += 0.5 * _ma[i] * dt_n * dt_n
			pv = maxf(_mv[i] + _ma[i] * dt_n, 0.0)
		pd = _lat_at(i, float(n))
	var e_s := s_srv - ps
	var e_v := v_srv - pv
	var e_d := d_srv - pd
	var err := sqrt(e_s * e_s + e_d * e_d)
	stats.add_correction(err, e_d, absf(s_srv - player_s) <= _near_m)
	_estimate(i, n, v_srv, e_v)
	_last_cs[i] = s_srv
	_last_cd[i] = d_srv
	_last_err[i] = err
	# Carry the error to the model's tick; keep the published position where it was.
	var before_s := _pos_at(i, now)
	var before_d := _lat_at(i, now)
	_ms[i] += e_s + e_v * float(kt - n) * tick_dt
	_mv[i] = maxf(_mv[i] + e_v, 0.0)
	var unexplained := absf(e_d) >= _unsig_m
	if _lc[i] == 1:
		if unexplained:
			_lc[i] = 0   # the server does something else: follow its d
			_base_d[i] = d_srv
		else:
			e_d = 0.0   # small lateral errors during a lane change end with it
	else:
		_base_d[i] += e_d
	if _lc[i] == 0:
		var li := road.lane_index_at(_base_d[i], s_srv)
		if li >= 0:
			state.lane[i] = li
			state.target_lane[i] = li
	corrector.carry(i, n, kt, e_s, e_v, e_d)
	var ds := before_s - _pos_at(i, now)
	var dd := before_d - _lat_at(i, now)
	var blend := corrector.add_offset(i, ds, dd, _visible(i), unexplained, now)
	match blend:
		TrafficCorrector.Blend.SMALL:
			stats.blends_small += 1
		TrafficCorrector.Blend.MEDIUM:
			stats.blends_medium += 1
		TrafficCorrector.Blend.SNAP:
			stats.snaps += 1
		TrafficCorrector.Blend.CAPPED:
			stats.large_in_view += 1
	if unexplained and blend != TrafficCorrector.Blend.SNAP:
		stats.unsignaled_lateral += 1
	return true


## The desired-speed estimate (a car that drove free since the last correction: invert
## IDM's free term with the server's own mean acceleration) or else the acceleration bias.
func _estimate(i: int, n: int, v_srv: float, e_v: float) -> void:
	var last := _last_ct[i]
	if last >= 0 and n > last:
		var dtc := float(n - last) * tick_dt
		var p := state.profile_id[i]
		var free := _int_n[i] > 0 and _int_sum[i] / float(_int_n[i]) < _v0_free
		var braking := _brake_from[i] < float(n) and _brake_until[i] > float(last)
		if free and not braking:
			var a_obs := (v_srv - _last_cv[i]) / dtc
			var v_mean := (v_srv + _last_cv[i]) * 0.5
			var q := 1.0 - (a_obs - _bias[i]) / _pa[p]
			var m := _match[i]
			if q > 0.0 and v_mean > 0.0 and m < 1.0:
				# The model's v0 is matched toward the drop zone's merge-lane speed (m);
				# invert that too, so the estimate stays the car's own desired speed.
				var v0m := v_mean / sqrt(sqrt(q))
				var v0 := v0m if m <= 0.0 or v0m >= _v_merge else (v0m - _v_merge * m) / (1.0 - m)
				v0 = clampf(v0, _v0lo[p], _v0hi[p])
				_v0e[i] += (v0 - _v0e[i]) * _v0_gain
				state.v0[i] = _v0e[i]
		elif not braking:
			_bias[i] = clampf(_bias[i] + e_v / dtc * _bias_gain, -_bias_max, _bias_max)
	_last_ct[i] = n
	_last_cv[i] = v_srv
	_int_sum[i] = 0.0
	_int_n[i] = 0


# ---------------------------------------------------------------- Lateral

## Wire target lane → sim lane for car i at s (the lane count at s, as the server converts
## it). A lane change always goes to a lane next to the car's: when the count at s gives
## one that is not (the car within metres of a lane-count change, the two sides' positions
## a hair apart), the count one lane either side decides.
func _target_lane(i: int, wire: int, s: float) -> int:
	var n := road.lane_count(s)
	var tl := NetTrafficWire.lane_from_wire(wire, n)
	if wire == NetTrafficWire.RAMP_LANE:
		return tl
	var cur := state.lane[i]
	if absi(tl - cur) == 1:
		return tl
	var lo := NetTrafficWire.lane_from_wire(wire, n - 1)
	if absi(lo - cur) == 1:
		return lo
	var hi := NetTrafficWire.lane_from_wire(wire, n + 1)
	if absi(hi - cur) == 1:
		return hi
	stats.bad_values += 1
	return tl


func _set_plan(i: int, lane: int, blink_t: float, move_t: float, dur_t: float, from_d: float,
		to_d: float) -> void:
	_lc[i] = 1
	_lc_lane[i] = lane
	_lc_blink[i] = blink_t
	_lc_move[i] = move_t
	_lc_dur[i] = maxf(dur_t, 1.0)
	_lc_from[i] = from_d
	_lc_to[i] = to_d
	_lc_hold[i] = corrector.hold_tick(blink_t, move_t)
	_lc_catch[i] = corrector.catchup_ticks() if _lc_hold[i] > move_t else 0.0
	_lc_cancel[i] = INF
	state.target_lane[i] = lane


func _complete_plan(i: int, now: float) -> void:
	var before := _lat_at(i, now)
	_lc[i] = 0
	_base_d[i] = _lc_to[i]
	state.lane[i] = _lc_lane[i]
	state.target_lane[i] = _lc_lane[i]
	var dd := before - _lat_at(i, now)
	if dd != 0.0:
		corrector.add_offset(i, 0.0, dd, _visible(i), false, now)


## The model's lateral position at server time t (ticks) into _q_d / _q_vl (m/s) / _q_phase
## / _q_timer / _q_dur (s); returns _q_d.
func _lat_at(i: int, t: float) -> float:
	_q_vl = 0.0
	_q_timer = 0.0
	_q_dur = 0.0
	if _lc[i] == 0:
		_q_phase = _NONE
		_q_d = _base_d[i]
		return _q_d
	var from := _lc_from[i]
	var hold := _lc_hold[i]
	if t < _lc_blink[i] or t >= _lc_cancel[i]:
		_q_phase = _NONE
		_q_d = from
		return _q_d
	if t < hold:
		_q_phase = _SIGNALING
		_q_timer = maxf(t - _lc_blink[i], 0.0) * tick_dt
		_q_dur = (hold - _lc_blink[i]) * tick_dt
		_q_d = from
		return _q_d
	var span := _lc_to[i] - from
	var dur := _lc_dur[i]
	var u := clampf((t - _lc_move[i]) / dur, 0.0, 1.0)
	var c := from + span * _smooth(u)
	var cv := span * _SMOOTH_D * u * (1.0 - u) / (dur * tick_dt) if u > 0.0 and u < 1.0 else 0.0
	var catch := _lc_catch[i]
	_q_phase = _MOVING
	_q_timer = (t - hold) * tick_dt
	_q_dur = maxf(_lc_move[i] + dur, hold + catch) * tick_dt - hold * tick_dt
	if catch > 0.0 and t < hold + catch:
		var w_u := (t - hold) / catch
		var w := _smooth(w_u)
		var wv := _SMOOTH_D * w_u * (1.0 - w_u) / (catch * tick_dt)
		_q_d = from + (c - from) * w
		_q_vl = cv * w + (c - from) * wv
		return _q_d
	_q_d = c
	_q_vl = cv
	return _q_d


## The model's longitudinal position at server time t (ticks >= model_tick): ballistic from
## the model tick with its held acceleration.
func _pos_at(i: int, t: float) -> float:
	var u := maxf(t - float(model_tick), 0.0) * tick_dt
	var a := _ma[i]
	var v := _mv[i]
	if a < 0.0 and v + a * u < 0.0:
		return _ms[i] - v * v / (2.0 * a)
	return _ms[i] + v * u + 0.5 * a * u * u


func _vel_at(i: int, t: float) -> float:
	var u := maxf(t - float(model_tick), 0.0) * tick_dt
	return maxf(_mv[i] + _ma[i] * u, 0.0)


static func _smooth(u: float) -> float:
	return u * u * (_SMOOTH_A - 2.0 * u)


# ---------------------------------------------------------------- Publish

func _publish(now: float, dt_s: float) -> void:
	var st := state
	var hl := TrafficState.FLAG_HEADLIGHTS if _headlights else 0
	var check := dt_s > 0.0
	var jump_max := _teleport_v * dt_s
	for i in _cap:
		if st.active[i] == 0:
			continue
		if _lc[i] == 1 and now >= _lc_cancel[i]:
			_lc[i] = 0
			st.target_lane[i] = st.lane[i]
		elif _lc[i] == 1 and now >= lane_change_end_tick(i) + 1.0:
			_complete_plan(i, now)
		corrector.decay(i, dt_s, now)
		var s := _pos_at(i, now)
		var v := _vel_at(i, now)
		var d := _lat_at(i, now)
		var ps := s + corrector.off_s[i]
		var pd := d + corrector.off_d[i]
		var vl := _q_vl + corrector.offset_speed_d(i, now)
		if check and _pub_ok[i] == 1 and _visible_at(ps):
			var js := ps - _pub_s[i] - v * dt_s
			var jd := pd - _pub_d[i] - _q_vl * dt_s
			var jump := sqrt(js * js + jd * jd)
			if jump > jump_max:
				stats.teleports += 1
				stats.teleport_max_m = maxf(stats.teleport_max_m, jump)
		_pub_s[i] = ps
		_pub_d[i] = pd
		_pub_ok[i] = 1
		st.s[i] = ps
		st.d[i] = pd
		st.v[i] = v
		st.v_lat[i] = vl
		st.accel[i] = _ma[i]
		st.lc_state[i] = _q_phase
		st.lc_timer[i] = _q_timer
		st.lc_duration[i] = _q_dur
		st.lc_start_d[i] = _lc_from[i] if _lc[i] == 1 else d
		if _lc[i] == 0:
			st.target_lane[i] = st.lane[i]
		var f := hl | (st.flags[i] & TrafficState.FLAG_HIGH_BEAM)
		var a := _ma[i]
		if a < -_brake_decel or _brk_spawn[i] == 1:
			f |= TrafficState.FLAG_BRAKE
		if a < -_brake_strong:
			f |= TrafficState.FLAG_BRAKE_STRONG
		if _q_phase != _NONE:
			f |= TrafficState.FLAG_BLINKER_LEFT if _lc_to[i] < _lc_from[i] else TrafficState.FLAG_BLINKER_RIGHT
		elif corrector.blink_dir[i] != 0:
			f |= TrafficState.FLAG_BLINKER_LEFT if corrector.blink_dir[i] < 0 else TrafficState.FLAG_BLINKER_RIGHT
		var hit := now < _hit_until[i]
		if hit:
			f |= TrafficState.FLAG_HIT | TrafficState.FLAG_HAZARD
		elif _hit_until[i] > -INF:
			_hit_until[i] = -INF
			_queue(i, _PEND_HAZ_OFF)
		if _own_haz[i] == 1 or now < _haz_until[i]:
			f |= TrafficState.FLAG_HAZARD
		st.flags[i] = f
	_pub_t = now


func _visible(i: int) -> bool:
	return _visible_at(state.s[i] if _pub_ok[i] == 1 else _ms[i])


func _visible_at(s: float) -> bool:
	var ds := s - _p_s
	return ds >= -_vis_behind and ds <= _vis_ahead


func _step_stale(now: float) -> void:
	for i in _cap:
		if state.active[i] == 1 and now - _heard[i] > _stale_t:
			_despawn(i)
			stats.stale_despawns += 1


# ---------------------------------------------------------------- Order, player, slots

func _read_player(player: VehicleState, now: float) -> void:
	var cy := cos(player.yaw)
	var sy := sin(player.yaw)
	var kappa := road.curvature_at(player.s)
	_p_s = player.s
	_p_d = player.d
	_p_v = (player.v * cy - player.v_lat * sy) / (1.0 - kappa * player.d)
	_p_vl = player.v * sy + player.v_lat * cy
	_p_t = now


## Mirrors of the model tick: every car's s, v, half length and physical lateral interval
## (a lane change widens it to the target while it moves), the player's at the same
## instant; then the insertion sort by s.
func _sort() -> void:
	var tk := float(model_tick)
	for k in _n:
		var i := _ord[k]
		if i == _P:
			var ps := _p_s + _p_v * (tk - _p_t) * tick_dt
			var ahead := _p_vl * _antic
			_ks[_P] = ps
			_kv[_P] = _p_v
			_klo[_P] = _p_d - _pw * 0.5 + minf(0.0, ahead)
			_khi[_P] = _p_d + _pw * 0.5 + maxf(0.0, ahead)
			continue
		_ks[i] = _ms[i]
		_kv[i] = _mv[i]
		var d := _ks_d(i)
		var hw := state.width[i] * 0.5
		var lo := d - hw
		var hi := d + hw
		if _q_phase == _MOVING:
			var tc := _lc_to[i]
			lo = minf(lo, tc - hw)
			hi = maxf(hi, tc + hw)
		_klo[i] = lo
		_khi[i] = hi
	for k in range(1, _n):
		var x := _ord[k]
		var sx := _ks[x]
		var m := k - 1
		while m >= 0 and _ks[_ord[m]] > sx:
			_ord[m + 1] = _ord[m]
			m -= 1
		_ord[m + 1] = x


## The model's d at the model tick (and _q_phase).
func _ks_d(i: int) -> float:
	return _lat_at(i, float(model_tick))


func _add_to_order(i: int) -> void:
	_khl[i] = state.length[i] * 0.5
	_ks[i] = _ms[i]
	_kv[i] = _mv[i]
	_klo[i] = _base_d[i] - state.width[i] * 0.5
	_khi[i] = _base_d[i] + state.width[i] * 0.5
	var k := _n
	while k > 0 and _ks[_ord[k - 1]] > _ks[i]:
		_ord[k] = _ord[k - 1]
		k -= 1
	_ord[k] = i
	_n += 1


func _despawn(i: int) -> void:
	var k := 0
	while k < _n and _ord[k] != i:
		k += 1
	while k < _n - 1:
		_ord[k] = _ord[k + 1]
		k += 1
	if k < _n:
		_n -= 1
	if _slot_of[_cid[i]] == i:
		_slot_of[_cid[i]] = NO_SLOT
	if _pend[i] != 0:
		_n_pend -= 1
		_pend[i] = 0
	_lc[i] = 0
	state.free_slot(i)


func _queue(i: int, bits: int) -> void:
	if _pend[i] == 0:
		_n_pend += 1
	_pend[i] |= bits


func _emit_pending(out: ScoreEventBuffer) -> void:
	for i in _cap:
		var pb := _pend[i]
		if pb == 0:
			continue
		if state.active[i] == 1:
			if (pb & _PEND_HAZ_ON) != 0:
				out.push(TrafficSim.KIND_HAZARDS, 0, 0.0, -1.0, i, 1.0, TrafficSim.TAG_HIT)
			if (pb & _PEND_HAZ_OFF) != 0:
				out.push(TrafficSim.KIND_HAZARDS, 0, 0.0, -1.0, i, 0.0, TrafficSim.TAG_HIT)
			if (pb & _PEND_HORN) != 0:
				out.push(TrafficSim.KIND_HORN, 0, 0.0, -1.0, i, 0.0, TrafficSim.TAG_HONK)
		_pend[i] = 0
	_n_pend = 0


# ---------------------------------------------------------------- Lane-drop zones (WP6.8, mirrored)

## The road's lane-drop harmonisation zones over [s_from, s_to), as
## TrafficSim.sync_road_closures adds them (from the lane_ends sign, or
## lane_drop_slow_zone_m before the taper, through the narrowed section to
## lane_drop_slow_after_m past the lanes coming back); zones behind s_from are forgotten.
## `step` calls it every ~1 km of the player's travel. Director rate: allocates.
func sync_road(s_from: float, s_to: float) -> void:
	var k := 0
	for z in _dz_n:
		if _dz_s1[z] + _drop_release >= s_from:
			_dz_s0[k] = _dz_s0[z]
			_dz_s1[k] = _dz_s1[z]
			_dz_lane[k] = _dz_lane[z]
			k += 1
	_dz_n = k
	var lo := maxf(s_from, _dz_to)
	if s_to > lo:
		var found: Array[RoadFeature] = []
		road.features_in(lo, s_to, found)
		for f in found:
			if f.kind != RoadFeature.Kind.LANE_COUNT_CHANGE or (f.s_start < lo and is_finite(_dz_to)):
				continue
			var before := road.lane_count(f.s_start - road.lane_width(f.s_start))
			var after := int(f.value)
			if after < before and _dz_n < TrafficSim.MAX_DROP_ZONES:
				_dz_lane[_dz_n] = after
				_dz_s0[_dz_n] = _lane_ends_sign_s(f.s_start)
				_dz_s1[_dz_n] = _lanes_back_s(f.s_end, before) + _drop_after
				_dz_n += 1
		_dz_to = s_to
	_dz_lo = INF
	_dz_hi = -INF
	for z in _dz_n:
		_dz_lo = minf(_dz_lo, _dz_s0[z] - _drop_view)
		_dz_hi = maxf(_dz_hi, _dz_s1[z] + _drop_release)
	zone_syncs += 1


func lane_drop_zone_count() -> int:
	return _dz_n


## TrafficSim._lanes_back_s. Allocates.
func _lanes_back_s(s_taper_end: float, lanes: int) -> float:
	var found: Array[RoadFeature] = []
	road.features_in(s_taper_end, s_taper_end + _drop_narrow, found)
	for f in found:
		if f.kind == RoadFeature.Kind.LANE_COUNT_CHANGE and f.s_start >= s_taper_end and int(f.value) >= lanes:
			return f.s_end
	return s_taper_end


## TrafficSim._lane_ends_sign_s. Allocates.
func _lane_ends_sign_s(s_drop: float) -> float:
	var signs: Array[RoadFeature] = []
	road.features_in(s_drop - 2.0 * _drop_slow, s_drop, signs)
	var best := s_drop - _drop_slow
	for f in signs:
		if f.kind == RoadFeature.Kind.SIGN and f.tag == ProceduralRoadPath.SIGN_LANE_ENDS and f.s_start <= s_drop \
				and absf(f.s_start + f.value - s_drop) < 1.0:
			best = f.s_start
	return best


## The harmonisation part of TrafficSim._drop_tick for car i (its lane, front, speed,
## desired speed, profile): the zones' acceleration limit, the matched desired speed in
## _q_v0 and the matching factor in _match. Merge zones, the zipper and the closure wall
## are not mirrored (corrections and the bias cover them). Allocation-free.
func _drop_accel(i: int, front: float, vi: float, v0: float, p: int) -> float:
	var lane := state.lane[i]
	var m := 0.0
	var acc := INF
	var lim := INF
	for z in _dz_n:
		var s1z := _dz_s1[z]
		if front > s1z:
			m = maxf(m, 1.0 - (front - s1z) / _drop_release)
			continue
		var vz := _v_merge if lane >= _dz_lane[z] else _v_through
		var ahead := _dz_s0[z] - front
		if ahead <= 0.0:
			lim = minf(lim, vz)
			m = 1.0
		elif ahead < _drop_view:
			lim = minf(lim, sqrt(vz * vz + 2.0 * _pb[p] * ahead))
			if vi > vz:
				var req := (vz * vz - vi * vi) / (2.0 * ahead)
				acc = minf(acc, maxf(req * clampf((-req / _pb[p] - _drop_onset) / (1.0 - _drop_onset), 0.0, 1.0), -_pb[p]))
	_match[i] = m
	var v0e := v0 + (_v_merge - v0) * m if v0 < _v_merge else v0
	_q_v0 = v0e
	if lim < v0e:
		acc = minf(acc, Idm.free_accel(vi, lim, _pa[p], _pdl[p]))
	return acc


# ---------------------------------------------------------------- Setup

func _cache_tuning() -> void:
	var t := traffic
	_max_decel = t.max_decel_mps2
	_brake_decel = t.brake_light_decel_mps2
	_brake_strong = t.brake_light_strong_decel_mps2
	_look = t.idm_lookahead_m
	_gap_floor = t.idm_gap_floor_m
	_lat_m = t.lateral_margin_m
	_antic = t.player_lateral_anticipation_s
	_hit_recover_t = t.hit_recover_s / tick_dt
	_hit_decel = t.hit_brake_decel_mps2
	_hit_brake_t = t.hit_brake_s / tick_dt
	_tap_decel = t.brake_tap_decel_mps2
	_tap_s = t.brake_tap_s
	_cut_in_m = t.cut_in_brake_tap_distance_m
	_react_cool = t.reaction_cooldown_s
	_look_through = t.look_through_leaving_leaders
	_anticipate = t.anticipate_leader_braking
	var n := net
	_stale_t = n.traffic_stale_car_s / tick_dt
	_max_catchup = maxi(n.traffic_max_catchup_ticks, 1)
	_v0_gain = n.traffic_v0_gain
	_v0_free = n.traffic_v0_free_accel_mps2
	_v0_margin = n.traffic_v0_margin_frac
	_bias_gain = n.traffic_bias_gain
	_bias_max = n.traffic_bias_max_mps2
	_bias_fade_s = n.traffic_bias_fade_s
	_near_m = n.traffic_correction_near_m
	_vis_behind = n.traffic_visible_behind_m
	_vis_ahead = n.traffic_visible_ahead_m
	_unsig_m = n.traffic_unsignaled_lateral_m
	_teleport_v = n.traffic_teleport_speed_mps
	_drop_view = t.lane_drop_view_m
	_drop_release = t.lane_drop_release_m
	_drop_after = t.lane_drop_slow_after_m
	_drop_slow = t.lane_drop_slow_zone_m
	_drop_narrow = t.lane_drop_narrow_max_m
	_drop_onset = t.lane_drop_brake_onset_frac
	_v_through = Units.kmh_to_mps(t.lane_drop_through_kmh)
	_v_merge = Units.kmh_to_mps(t.lane_drop_merge_lane_kmh)
	_sync_lead = n.traffic_aoi_ahead_m + _drop_view
	_sync_len = _sync_lead + t.lane_drop_merge_zone_m
	_sync_back = n.traffic_aoi_behind_m + _drop_release


## Per-profile IDM parameters as TrafficSim keeps them (_init, _init_weave).
func _init_profiles() -> void:
	var reg := registry
	_pa = reg.a_max.duplicate()
	_pb = reg.b_comfort.duplicate()
	_pT = reg.headway.duplicate()
	_ps0 = reg.s0.duplicate()
	_pdl = reg.delta.duplicate()
	var np := reg.profile_count()
	_pweave.resize(np)
	_wTk.resize(np)
	_ws0.resize(np)
	_wb.resize(np)
	_v0lo.resize(np)
	_v0hi.resize(np)
	for p in np:
		var d := reg.profiles[p]
		var hw := d.idm_headway_vs_traffic_s
		_wTk[p] = hw / d.idm_headway_s if hw >= 0.0 and d.idm_headway_s > 0.0 else 1.0
		_ws0[p] = d.idm_s0_vs_traffic_m if d.idm_s0_vs_traffic_m >= 0.0 else _ps0[p]
		_wb[p] = d.idm_b_comfort_vs_traffic_mps2 if d.idm_b_comfort_vs_traffic_mps2 > 0.0 else _pb[p]
		var on := hw >= 0.0 or d.idm_s0_vs_traffic_m >= 0.0 or d.idm_b_comfort_vs_traffic_mps2 > 0.0 \
			or d.mobil_b_safe_vs_traffic_mps2 > 0.0 or d.lookahead_lane_choice_m > 0.0 \
			or d.lane_change_cooldown_s >= 0.0 or d.lane_change_cap_count > 0
		_pweave[p] = 1 if on else 0
		_v0lo[p] = reg.v0_min[p] * (1.0 - _v0_margin)
		_v0hi[p] = maxf(reg.v0_max[p] * (1.0 + _v0_margin), _v_merge)
