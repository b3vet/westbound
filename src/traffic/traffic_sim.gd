class_name TrafficSim
extends RefCounted
## Traffic on the player's carriageway: IDM car following, MOBIL lane changes with
## telegraphing, the fairness rules, near/far ticks and reactions to the player.
## Spec: Traffic → Road-space simulation, Longitudinal model: IDM, Lane changes:
## MOBIL, Fairness rules (non-negotiable), Driver types, Traffic reacts to the player;
## Lives → Fairness rules (rear-end prevention); Performance budget → CPU.
## Model, rule implementation and measured numbers: docs/TRAFFIC.md.
##
##   var sim := TrafficSim.new(ctx, road, TrafficRegistry.load_default(ctx.tuning.traffic))
##   sim.spawn(record)                                  # director (WP2.5)
##   sim.step(dt, player_state, player_params, events)  # run.gd, 120 Hz, after vehicle physics
##   sim.notify_hit(slot)                               # run.gd, after collisions
##
## Pure (RefCounted, no Node or autoload access) and allocation-free after _init:
## step, spawn, despawn, notify_hit, honk, set_headlights and every query. `state`
## (TrafficState) is the only published state; the arrays below prefixed "_" are
## scratch and per-slot bookkeeping the sim owns.
##
## One step (synchronous, deterministic order):
##   1. every vehicle integrates longitudinally over dt with the acceleration decided
##      at its last model tick (far vehicles hold theirs between 30 Hz updates);
##   2. each vehicle due this tick finds its leader (the player included, at the same
##      instant) in road space and gets its IDM acceleration, reaction modifiers, the
##      clamp and its brake lights, applied from the next tick;
##   3. each due vehicle runs its lane-change state machine (MOBIL, telegraphing,
##      no-ambush, hesitant cancels), hit recovery and player reactions.
## Vehicles further than near_radius_m from the player are "far" (FLAG_FAR): their
## model (steps 2 and 3) runs at far_tick_hz with the accumulated dt.
##
## Lateral occupancy: every vehicle has a physical lateral interval (its body; while
## MOVING, the whole span from its body to the move's target) used for leaders, and a
## claim interval (also covering the target while SIGNALING) used for MOBIL's gap
## search, so two cars never signal into the same gap. The player is entry
## `player_index()` in the same arrays, with its interval stretched by its lateral
## velocity (player_lateral_anticipation_s). Because leaders are found by lateral
## overlap rather than lane index, a motorbike riding a lane boundary (lane
## splitting, profile lane_split) filters past vehicles narrow enough to leave it
## lane_split_clearance_m and follows the rest.

## Event kinds written to the caller's ScoreEventBuffer (slot = TrafficState slot).
## The Events adapter maps them to the signal of the same name.
const KIND_HORN := &"traffic_horn"               ## tag: TAG_*; adapter adds the world position
const KIND_BRAKE_TAP := &"traffic_brake_tap"     ## tight cut-in ahead of the car
const KIND_HAZARDS := &"traffic_hazards"         ## value 1 = on, 0 = off
const TAG_BLIND_SPOT := &"blind_spot"
const TAG_CLOSE_PASS := &"close_pass"
const TAG_HONK := &"honk"
const TAG_CUT_IN := &"cut_in"
const TAG_HIT := &"hit"

## Lane closures (WP6.2): at most this many at once; the road's own carry this tag.
const MAX_LANE_CLOSURES := 32
const ROAD_CLOSURE_TAG := -1
## Set-piece zones (WP6.3): lane speed limits (toll booth lanes) and headway zones
## (tunnel squeeze), live at once.
const MAX_SPEED_ZONES := 8
const MAX_HEADWAY_ZONES := 4

const _PEND_HAZARD_ON := 1
const _PEND_HORN := 2
const _BLINKERS := TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BLINKER_RIGHT
const _BRAKES := TrafficState.FLAG_BRAKE | TrafficState.FLAG_BRAKE_STRONG
const _NONE := TrafficState.LaneChange.NONE
const _SIGNALING := TrafficState.LaneChange.SIGNALING
const _MOVING := TrafficState.LaneChange.MOVING
## Smoothstep 3u^2 - 2u^3 and its derivative 6u(1 - u).
const _SMOOTH_A := 3.0   # lint: allow-number smoothstep polynomial coefficient
const _SMOOTH_D := 6.0   # lint: allow-number smoothstep derivative coefficient

var state: TrafficState
var road: RoadPath
var registry: TrafficRegistry
var tuning: TrafficTuning

# ---------------------------------------------------------------- Counters (metrics, tests, sandbox)
var stat_signals := 0              ## lane changes signaled
var stat_hesitant_signals := 0     ## ... by profiles with cancel_probability > 0
var stat_moves := 0                ## lateral moves started
var stat_completed := 0            ## lateral moves finished
var stat_cancel_player := 0        ## cancelled: the player entered the target gap / space
var stat_cancel_hesitant := 0      ## cancelled: Hesitant profile
var stat_cancel_unsafe := 0        ## cancelled: gap no longer safe at the end of the signal
var stat_model_updates := 0        ## vehicle model evaluations (near + far)
var stat_merges := 0               ## mandatory merges signaled (a lane closing ahead)

var _cap: int
var _P: int                        # the player's index in the mirrors and the order
var _rng_lc: Rng
var _rng_react: Rng
var _rng_spawn: Rng
var _headlights := false

# Cached tuning (SI)
var _max_decel: float
var _scripted_decel: float
var _brake_decel: float
var _brake_strong: float
var _look: float
var _gap_floor: float
var _lat_m: float
var _near_r: float
var _far_ratio: int
var _window: float
var _margin: float
var _player_b_safe: float
var _cooldown: float
var _disc: float
var _antic: float
var _pl_a: float
var _pl_b: float
var _pl_T: float
var _pl_s0: float
var _hit_recover: float
var _hit_swerve_m: float
var _hit_swerve_s: float
var _hit_decel: float
var _hit_brake_s: float
var _tap_decel: float
var _tap_s: float
var _cut_in_m: float
var _blind_m: float
var _blind_s: float
var _blind_frac: float
var _close_frac: float
var _react_cool: float
var _react_range: float
var _split_max_v: float
var _split_v0: float
var _split_scan: float
var _split_clear: float
var _split_player_lat: float
var _split_player_range: float

# Per profile (copies of the registry's SI arrays)
var _pa := PackedFloat64Array()
var _pb := PackedFloat64Array()
var _pT := PackedFloat64Array()
var _ps0 := PackedFloat64Array()
var _pdl := PackedInt32Array()
var _ppol := PackedFloat64Array()
var _pth := PackedFloat64Array()
var _pbias := PackedFloat64Array()
var _pbsafe := PackedFloat64Array()
var _psig := PackedFloat64Array()
var _pmmin := PackedFloat64Array()
var _pmmax := PackedFloat64Array()
var _peval := PackedFloat64Array()
var _pcancel := PackedFloat64Array()
var _pkr := PackedByteArray()
var _pkrl := PackedInt32Array()
var _psplit := PackedByteArray()
# Per type
var _tlen := PackedFloat64Array()
var _twid := PackedFloat64Array()

# Player (road frame), refreshed at the start of every step
var _ps := 0.0
var _pv := 0.0
var _pd := 0.0
var _pvl := 0.0
var _plen: float
var _pw: float
var _plo := NAN                    # player body interval (no anticipation)
var _phi := NAN

# Road cross-section at the player (lane geometry is constant over the active window)
var _edge: float
var _lw: float

# Mirrors, capacity + 1 entries (the last one is the player)
var _ks := PackedFloat64Array()    # s
var _kv := PackedFloat64Array()    # v along the road
var _khl := PackedFloat64Array()   # half length
var _klo := PackedFloat64Array()   # physical lateral interval
var _khi := PackedFloat64Array()
var _kclo := PackedFloat64Array()  # claim lateral interval
var _kchi := PackedFloat64Array()
# Order by s (active slots + the player) and each entry's position in it
var _ord := PackedInt32Array()
var _rank := PackedInt32Array()
var _n := 0

# Per slot
var _acc_t := PackedFloat64Array()     # far: time accumulated since the last model update
var _acc_n := PackedInt32Array()       # far: ticks accumulated
var _due := PackedByteArray()          # model runs this tick
var _mdt := PackedFloat64Array()       # model dt this tick
var _lead := PackedInt32Array()        # leader at the last model tick (-1 none, _P = the player)
var _lead_gap := PackedFloat64Array()
var _a_raw := PackedFloat64Array()     # IDM acceleration before reactions and clamp
var _mobil_t := PackedFloat64Array()   # time to the next MOBIL evaluation (or cooldown)
var _will_cancel := PackedByteArray()  # Hesitant: this signal ends in a cancel
var _tap_t := PackedFloat64Array()     # > 0 brake tap active; counts down to -cooldown (re-armed)
var _blind_t := PackedFloat64Array()   # > 0 time with the player in the blind spot; < 0 cooldown
var _prev_lead_p := PackedByteArray()  # the player was this car's leader last model tick
var _swerve_dir := PackedFloat64Array()   # hit swerve direction (+1 right, -1 left, 0 none)
var _swerve_base := PackedFloat64Array()
var _hit_hazard := PackedByteArray()   # hazards were switched on by a hit (switch off on recovery)
var _lc_target_d := PackedFloat64Array()   # d the signaled / moving lateral move ends at
var _lc_split := PackedInt32Array()    # the move enters a lane split (-1 left / +1 right boundary), 0 = no
var _split := PackedInt32Array()       # riding the lane boundary on this side of `lane` (motorbikes), 0 = no
var _hard_ok := PackedByteArray()      # set pieces: may brake beyond the clamp (announced >= 300 m ahead)
var _hold := PackedByteArray()         # set pieces (WP6.3): held out of the mandatory merge
# Lane closures (WP6.2): lane, [s0, s1], tag
var _cl_lane := PackedInt32Array()
var _cl_s0 := PackedFloat64Array()
var _cl_s1 := PackedFloat64Array()
var _cl_tag := PackedInt32Array()
var _cl_n := 0
var _cl_road_to := -INF
var _merge_zone: float
var _merge_urg: float
var _merge_stop: float
# Set-piece zones (WP6.3): speed limits per lane over [s0, s1], headway scales over [s0, s1].
var _sz_lane := PackedInt32Array()
var _sz_s0 := PackedFloat64Array()
var _sz_s1 := PackedFloat64Array()
var _sz_v := PackedFloat64Array()
var _sz_tag := PackedInt32Array()
var _sz_keep_s1 := PackedFloat64Array()   # vehicles in the lane keep it until here ...
var _sz_keep_v := PackedFloat64Array()    # ... while slower than this (0: no keep)
var _sz_n := 0
var _hz_s0 := PackedFloat64Array()
var _hz_s1 := PackedFloat64Array()
var _hz_k := PackedFloat64Array()
var _hz_tag := PackedInt32Array()
var _hz_n := 0
var _pending := PackedInt32Array()     # _PEND_* bits emitted at the next step
var _pending_tag: Array[StringName] = []
var _n_pending := 0

# Neighbor query results (avoid allocating return tuples)
var _q_player := false


func _init(ctx: RunContext, road_path: RoadPath, reg: TrafficRegistry) -> void:
	road = road_path
	registry = reg
	tuning = ctx.tuning.traffic
	_cap = tuning.max_active_vehicles
	_P = _cap
	state = TrafficState.new(_cap)
	_rng_lc = ctx.rng_traffic.derive(&"sim_lane_change")
	_rng_react = ctx.rng_traffic.derive(&"sim_react")
	_rng_spawn = ctx.rng_traffic.derive(&"sim_spawn")
	_cache_tuning()
	_pa = reg.a_max.duplicate()
	_pb = reg.b_comfort.duplicate()
	_pT = reg.headway.duplicate()
	_ps0 = reg.s0.duplicate()
	_pdl = reg.delta.duplicate()
	_ppol = reg.politeness.duplicate()
	_pth = reg.a_threshold.duplicate()
	_pbias = reg.a_bias.duplicate()
	_pbsafe = reg.b_safe.duplicate()
	_psig = reg.signal_s.duplicate()
	_pmmin = reg.move_min_s.duplicate()
	_pmmax = reg.move_max_s.duplicate()
	_peval = reg.eval_interval_s.duplicate()
	_pcancel = reg.cancel_p.duplicate()
	_pkr = reg.keep_right.duplicate()
	_pkrl = reg.keep_right_lanes.duplicate()
	_psplit = reg.lane_split.duplicate()
	_tlen = reg.length.duplicate()
	_twid = reg.width.duplicate()
	var max_len := 0.0
	for x in _tlen:
		max_len = maxf(max_len, x)
	_react_range = _blind_m + max_len + _plen

	# Packed arrays are values: resize each member directly (never through a loop copy).
	_ks.resize(_cap + 1)
	_kv.resize(_cap + 1)
	_khl.resize(_cap + 1)
	_klo.resize(_cap + 1)
	_khi.resize(_cap + 1)
	_kclo.resize(_cap + 1)
	_kchi.resize(_cap + 1)
	_ord.resize(_cap + 1)
	_rank.resize(_cap + 1)
	_acc_t.resize(_cap)
	_mdt.resize(_cap)
	_lead_gap.resize(_cap)
	_a_raw.resize(_cap)
	_mobil_t.resize(_cap)
	_tap_t.resize(_cap)
	_blind_t.resize(_cap)
	_swerve_dir.resize(_cap)
	_swerve_base.resize(_cap)
	_acc_n.resize(_cap)
	_lead.resize(_cap)
	_pending.resize(_cap)
	_due.resize(_cap)
	_will_cancel.resize(_cap)
	_prev_lead_p.resize(_cap)
	_hit_hazard.resize(_cap)
	_lc_target_d.resize(_cap)
	_lc_split.resize(_cap)
	_split.resize(_cap)
	_hard_ok.resize(_cap)
	_hold.resize(_cap)
	_cl_lane.resize(MAX_LANE_CLOSURES)
	_cl_s0.resize(MAX_LANE_CLOSURES)
	_cl_s1.resize(MAX_LANE_CLOSURES)
	_cl_tag.resize(MAX_LANE_CLOSURES)
	_sz_lane.resize(MAX_SPEED_ZONES)
	_sz_s0.resize(MAX_SPEED_ZONES)
	_sz_s1.resize(MAX_SPEED_ZONES)
	_sz_v.resize(MAX_SPEED_ZONES)
	_sz_tag.resize(MAX_SPEED_ZONES)
	_sz_keep_s1.resize(MAX_SPEED_ZONES)
	_sz_keep_v.resize(MAX_SPEED_ZONES)
	_hz_s0.resize(MAX_HEADWAY_ZONES)
	_hz_s1.resize(MAX_HEADWAY_ZONES)
	_hz_k.resize(MAX_HEADWAY_ZONES)
	_hz_tag.resize(MAX_HEADWAY_ZONES)
	_pending_tag.resize(_cap)
	_pending_tag.fill(&"")
	_edge = road.lanes_left_edge_d(0.0)
	_lw = road.lane_width(0.0)
	clear()


## Removes every vehicle (state.clear()) and resets the counters.
func clear() -> void:
	state.clear()
	_n = 1
	_ord[0] = _P
	_rank[_P] = 0
	_ks[_P] = -INF
	_kv[_P] = 0.0
	_khl[_P] = _plen * 0.5
	_klo[_P] = NAN
	_khi[_P] = NAN
	_kclo[_P] = NAN
	_kchi[_P] = NAN
	_n_pending = 0
	for i in _cap:
		_pending[i] = 0
	stat_signals = 0
	stat_hesitant_signals = 0
	stat_moves = 0
	stat_completed = 0
	stat_cancel_player = 0
	stat_cancel_hesitant = 0
	stat_cancel_unsafe = 0
	stat_model_updates = 0
	stat_merges = 0


## The player's body size (run.gd passes the CarDef's length_m / width_m). Until then
## TrafficTuning.player_length_m / player_width_m are used.
func set_player_body(length_m: float, width_m: float) -> void:
	_plen = length_m
	_pw = width_m
	_khl[_P] = _plen * 0.5


## Plan D11 (the director's late-leg density): every profile's IDM time headway T
## becomes its DriverProfile value x `scale` (denser late legs drive closer). Director
## rate (on a leg change), never per tick; Flow's spawn gaps use the same scale.
func set_headway_scale(scale: float) -> void:
	for p in _pT.size():
		_pT[p] = registry.headway[p] * scale


## Profile p's IDM time headway T in use (after set_headway_scale).
func headway(p: int) -> float:
	return _pT[p]


## Index that stands for the player in leader_of() (= capacity).
func player_index() -> int:
	return _P


## Leader found at this vehicle's last model update: a slot, player_index(), or -1.
func leader_of(slot: int) -> int:
	return _lead[slot]


## Bumper gap to leader_of(slot) at its last model update (INF when none).
func leader_gap(slot: int) -> float:
	return _lead_gap[slot]


## IDM acceleration before reactions and the clamp, at the last model update.
func idm_accel(slot: int) -> float:
	return _a_raw[slot]


# ---------------------------------------------------------------- Spawning (director rate, no alloc)

## Commits one planned vehicle into a free slot and returns it, or -1 when the state
## is full. The director (WP2.5) owns spacing, passability and the ghost zone, so no
## gap or overlap is re-checked here. d = NAN means the lane center; lane and
## target_lane are rec.lane. rec.v0 <= 0 uses the middle of the profile's range.
## Allocation-free.
func spawn(rec: SpawnSource.Record) -> int:
	if state.is_full():
		return -1
	var tid := rec.type_id
	var pid := rec.profile_id
	assert(tid >= 0 and tid < _tlen.size() and pid >= 0 and pid < _pa.size(),
		"TrafficSim.spawn: bad type_id/profile_id")
	var hl := _tlen[tid] * 0.5
	var ln := rec.lane
	var d := rec.d
	if is_nan(d):
		d = road.lane_center_d(ln, rec.s)
	var i := state.allocate()
	state.s[i] = rec.s
	state.d[i] = d
	state.v[i] = rec.v
	state.v0[i] = rec.v0 if rec.v0 > 0.0 else (registry.v0_min[pid] + registry.v0_max[pid]) * 0.5
	state.length[i] = _tlen[tid]
	state.width[i] = _twid[tid]
	state.lane[i] = ln
	state.target_lane[i] = ln
	state.type_id[i] = tid
	state.profile_id[i] = pid
	state.model_variant[i] = rec.model_variant
	state.color_index[i] = rec.color_index
	var f := rec.flags & ~(TrafficState.FLAG_FAR | TrafficState.FLAG_HIT | _BLINKERS | _BRAKES)
	if _headlights:
		f |= TrafficState.FLAG_HEADLIGHTS
	state.flags[i] = f

	_acc_t[i] = 0.0
	_acc_n[i] = state.vehicle_id[i] % _far_ratio
	_due[i] = 0
	_mdt[i] = 0.0
	_lead[i] = -1
	_lead_gap[i] = INF
	_a_raw[i] = 0.0
	_mobil_t[i] = _rng_spawn.float_range(0.0, _peval[pid])
	_will_cancel[i] = 0
	_tap_t[i] = -_react_cool
	_blind_t[i] = 0.0
	_prev_lead_p[i] = 0
	_swerve_dir[i] = 0.0
	_swerve_base[i] = d
	_hit_hazard[i] = 0
	_pending[i] = 0
	_lc_target_d[i] = d
	_lc_split[i] = 0
	_split[i] = 0
	_hard_ok[i] = 0
	_hold[i] = 0

	_ks[i] = rec.s
	_kv[i] = rec.v
	_khl[i] = hl
	_refresh_interval(i)
	var k := _n
	while k > 0 and _ks[_ord[k - 1]] > rec.s:
		_ord[k] = _ord[k - 1]
		_rank[_ord[k]] = k
		k -= 1
	_ord[k] = i
	_rank[i] = k
	_n += 1
	return i


## Frees a slot (director despawn). Ignores inactive slots. Allocation-free.
func despawn(slot: int) -> void:
	if not state.is_active(slot):
		return
	var k := _rank[slot]
	while k < _n - 1:
		_ord[k] = _ord[k + 1]
		_rank[_ord[k]] = k
		k += 1
	_n -= 1
	_pending[slot] = 0
	state.free_slot(slot)


# ---------------------------------------------------------------- Run hooks

## The player hit this car: it cancels a signaled lane change, swerves away from the
## player, brakes hard, turns its hazards on and recovers after hit_recover_s
## (lives: "about 4 s"). A car already moving between lanes finishes its move
## instead of swerving. Emits KIND_HAZARDS (on) at the next step.
func notify_hit(slot: int) -> void:
	if not state.is_active(slot):
		return
	var f := state.flags[slot]
	if state.lc_state[slot] == _SIGNALING:
		_cancel(slot)
	if (f & TrafficState.FLAG_HIT) == 0:
		_hit_hazard[slot] = 0 if (f & TrafficState.FLAG_HAZARD) != 0 else 1
		if _hit_hazard[slot] == 1:
			_pending[slot] |= _PEND_HAZARD_ON
			_n_pending += 1
	state.flags[slot] = f | TrafficState.FLAG_HIT | TrafficState.FLAG_HAZARD
	state.react_timer[slot] = _hit_recover
	if state.lc_state[slot] == _MOVING:
		_swerve_dir[slot] = 0.0
	else:
		if _swerve_dir[slot] == 0.0:
			_swerve_base[slot] = state.d[slot]   # a hit during a swerve keeps the original line
		_swerve_dir[slot] = 1.0 if _swerve_base[slot] >= _pd else -1.0


## Sounds this car's horn (emitted at the next step as KIND_HORN with `tag`).
func honk(slot: int, tag: StringName = TAG_HONK) -> void:
	if not state.is_active(slot):
		return
	if _pending[slot] == 0:
		_n_pending += 1
	_pending[slot] |= _PEND_HORN
	_pending_tag[slot] = tag


## Scoring reports a close pass: the car honks close_pass_horn_pct of the time
## (traffic stream). Returns true when it honks.
func notify_close_pass(slot: int) -> bool:
	if not state.is_active(slot) or not _rng_react.chance(_close_frac):
		return false
	honk(slot, TAG_CLOSE_PASS)
	return true


## Headlights follow the sun clock (run.gd). New spawns inherit the setting.
func set_headlights(on: bool) -> void:
	_headlights = on
	for k in _n:
		var i := _ord[k]
		if i != _P:
			state.set_flag(i, TrafficState.FLAG_HEADLIGHTS, on)


func headlights() -> bool:
	return _headlights


## Scripted lane change (set pieces, sandbox, tests): signals toward `target_lane` if
## the change is safe and passes no-ambush now, then runs the normal telegraphed
## sequence (it can still cancel). Returns false if refused.
func request_lane_change(slot: int, target_lane: int) -> bool:
	if not state.is_active(slot) or state.lc_state[slot] != _NONE \
			or absi(target_lane - state.lane[slot]) != 1 \
			or (state.flags[slot] & TrafficState.FLAG_HIT) != 0:
		return false
	if _split[slot] != 0:
		return false
	if (state.flags[slot] & TrafficState.FLAG_SCRIPTED) != 0:
		# Set pieces (WP6.2) place their vehicles in any lane: no keep-right restriction,
		# the same safety and no-ambush checks.
		if target_lane < 0 or target_lane >= road.lane_count(_ks[slot]) or _closes_soon(target_lane, slot) \
				or is_inf(_eval_move(slot, _lane_d(target_lane), target_lane, false)):
			return false
	elif is_inf(_eval_target(slot, target_lane, false)):
		return false
	_start_signal(slot, target_lane, _lane_d(target_lane), 0)
	return true


## True while this motorbike rides a lane boundary (lane splitting).
func is_lane_splitting(slot: int) -> bool:
	return _split[slot] != 0


# ---------------------------------------------------------------- Set-piece hooks (WP6.2)
# The set-piece controllers (SetPieceSource) script FLAG_SCRIPTED vehicles only through
# these (plus request_lane_change): a desired speed, a brake tap, the hard-decel
# permission, and the release back to ordinary traffic. Allocation-free.

## A scripted vehicle's desired speed (m/s).
func set_scripted_v0(slot: int, v0: float) -> void:
	if state.is_active(slot):
		state.v0[slot] = v0


## A brake tap (brake_tap_decel_mps2 for brake_tap_s, as the cut-in reaction; the brake
## lights show it). False when inactive, hit, or a tap is still running.
func scripted_brake_tap(slot: int) -> bool:
	if not state.is_active(slot) or _tap_t[slot] > 0.0 or (state.flags[slot] & TrafficState.FLAG_HIT) != 0:
		return false
	_tap_t[slot] = _tap_s
	return true


## Fairness rule 4: a FLAG_SCRIPTED vehicle brakes beyond max_decel_mps2 (up to
## scripted_max_decel_mps2) only while this is on. The set-piece source turns it on
## after the piece was announced >= set_piece_min_warning_m ahead; spawn clears it.
func set_hard_decel_allowed(slot: int, on: bool) -> void:
	if state.is_active(slot):
		_hard_ok[slot] = 1 if on else 0


func hard_decel_allowed(slot: int) -> bool:
	return _hard_ok[slot] == 1


## WP6.3 (merge zone ramp traffic): while on, a FLAG_SCRIPTED vehicle starts no
## mandatory merge (it still stops at the end of its lane). release_scripted clears it.
func set_merge_hold(slot: int, on: bool) -> void:
	if state.is_active(slot):
		_hold[slot] = 1 if on and (state.flags[slot] & TrafficState.FLAG_SCRIPTED) != 0 else 0


func merge_held(slot: int) -> bool:
	return _hold[slot] == 1


## WP6.3 (convoy): a scripted vehicle's hazard lights on or off (a hit's own hazards
## are left alone).
func set_hazards(slot: int, on: bool) -> void:
	if state.is_active(slot) and (state.flags[slot] & TrafficState.FLAG_HIT) == 0:
		state.set_flag(slot, TrafficState.FLAG_HAZARD, on)


## Ends scripted control: FLAG_SCRIPTED off, desired speed `v0`, no hard decel, and
## MOBIL resumes after the lane-change cooldown.
func release_scripted(slot: int, v0: float) -> void:
	if not state.is_active(slot):
		return
	state.flags[slot] &= ~TrafficState.FLAG_SCRIPTED
	state.v0[slot] = v0
	_hard_ok[slot] = 0
	_hold[slot] = 0
	_mobil_t[slot] = _cooldown


# ---------------------------------------------------------------- Lane closures and mandatory merges (WP6.2)
# A closure: lane `lane` cannot be driven over [s0, s1]: a road lane drop (the dropped
# lanes from the change's start through its taper), the added lanes of a widening while
# their taper runs, and WP6.3's merge zone and road works (their own closures, by tag).
#   - Vehicles in a lane that closes within merge_zone_m merge out: MOBIL (safety and
#     no-ambush as always) with an incentive bonus ramping from 0 to merge_urgency_mps2
#     at the closure, evaluated every model tick, telegraphed like any lane change (the
#     blinker for the profile's signal time); a Hesitant driver never cancels it. Set-
#     piece vehicles (FLAG_SCRIPTED) merge too.
#   - Until it has started moving out, a vehicle in the closing lane brakes for a
#     standing obstacle merge_stop_margin_m before the closure (IDM): one that finds no
#     gap stops and waits at the end of its lane instead of driving onto the shoulder.
#   - Nobody changes into (or lane-splits next to) a lane that closes within merge_zone_m.
# The director feeds the road's closures (sync_road_closures, director rate); Flow keeps
# spawns out of lanes that close within merge_spawn_clear_m (closure_ahead).

## Adds a closure of `lane` over [s0, s1] (`tag` groups closures for removal; the road's
## use ROAD_CLOSURE_TAG). False when MAX_LANE_CLOSURES are live. Director rate.
func add_lane_closure(lane: int, s0: float, s1: float, tag: int = 0) -> bool:
	if _cl_n >= MAX_LANE_CLOSURES:
		return false
	_cl_lane[_cl_n] = lane
	_cl_s0[_cl_n] = s0
	_cl_s1[_cl_n] = s1
	_cl_tag[_cl_n] = tag
	_cl_n += 1
	return true


## Removes every closure with this tag. Director rate.
func remove_lane_closures(tag: int) -> void:
	var w := 0
	for c in _cl_n:
		if _cl_tag[c] != tag:
			_keep_closure(c, w)
			w += 1
	_cl_n = w


## Drops closures that end before `s` (behind the player). Director rate.
func forget_lane_closures_before(s: float) -> void:
	var w := 0
	for c in _cl_n:
		if _cl_s1[c] >= s:
			_keep_closure(c, w)
			w += 1
	_cl_n = w


func lane_closure_count() -> int:
	return _cl_n


## The road's lane-count changes starting in [s_from, s_to) become closures (the lanes
## between the old and the new count, over the change's start and taper). Repeated
## calls never add a change twice. Director rate: allocates.
func sync_road_closures(s_from: float, s_to: float) -> void:
	var lo := maxf(s_from, _cl_road_to)
	if s_to <= lo:
		return
	var found: Array[RoadFeature] = []
	road.features_in(lo, s_to, found)
	for f in found:
		if f.kind != RoadFeature.Kind.LANE_COUNT_CHANGE or (f.s_start < lo and is_finite(_cl_road_to)):
			continue
		var before := road.lane_count(f.s_start - road.lane_width(f.s_start))
		var after := int(f.value)
		for l in range(mini(before, after), maxi(before, after)):
			add_lane_closure(l, f.s_start, f.s_end, ROAD_CLOSURE_TAG)
	_cl_road_to = s_to


## Distance from s to the start of the next closure of `lane` still ahead of s (0 when
## s is inside one), INF when none. Allocation-free.
func closure_ahead(lane: int, s: float) -> float:
	var best := INF
	for c in _cl_n:
		if _cl_lane[c] == lane and _cl_s1[c] >= s:
			best = minf(best, maxf(_cl_s0[c] - s, 0.0))
	return best


## Lane t closes within merge_zone_m ahead of vehicle i's front (or i is inside the closure).
func _closes_soon(t: int, i: int) -> bool:
	return closure_ahead(t, _ks[i] + _khl[i]) < _merge_zone


func _keep_closure(from: int, to: int) -> void:
	_cl_lane[to] = _cl_lane[from]
	_cl_s0[to] = _cl_s0[from]
	_cl_s1[to] = _cl_s1[from]
	_cl_tag[to] = _cl_tag[from]


## IDM for a standing obstacle merge_stop_margin_m before the closure of vehicle i's
## lane (INF: none within the lookahead, or i is already moving out of the lane).
func _closure_wall_accel(i: int, vi: float, v0: float, p: int) -> float:
	var cur := state.lane[i]
	if state.lc_state[i] == _MOVING and state.target_lane[i] != cur:
		return INF
	var dist := closure_ahead(cur, _ks[i] + _khl[i])
	if dist > _look:
		return INF
	return Idm.accel(vi, v0, maxf(dist - _merge_stop, _gap_floor), vi, _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p],
		_gap_floor)


## A mandatory merge out of a closing lane (see above).
func _consider_merge(i: int) -> void:
	if state.lc_state[i] != _NONE:
		return
	if _split[i] != 0:
		_consider_split_exit(i)
		return
	var cur := state.lane[i]
	var dist := closure_ahead(cur, _ks[i] + _khl[i])
	var urgency := _merge_urg * clampf(1.0 - dist / _merge_zone, 0.0, 1.0)
	var gl := _eval_target(i, cur - 1, true) + urgency
	var gr := _eval_target(i, cur + 1, true) + urgency
	var t := -1
	if gl > 0.0 and gl >= gr:
		t = cur - 1
	elif gr > 0.0:
		t = cur + 1
	if t < 0:
		return
	_start_signal(i, t, _lane_d(t), 0)
	_will_cancel[i] = 0
	stat_merges += 1


# ---------------------------------------------------------------- Set-piece zones (WP6.3)
# Additive scripting hooks for road-anchored set pieces (docs/SET_PIECES.md):
#   - a speed zone caps the desired speed of every vehicle in `lane` over [s0, s1] at
#     v_max (toll booth lanes: "traffic slows at the booths"); before s0 a vehicle's
#     allowed speed is the one it can brake from to v_max at s0 at its profile's
#     comfortable deceleration (IDM free road toward it), so it slows smoothly, never
#     beyond the 6 m/s^2 clamp. MOBIL sees the zone in a target lane too.
#     With keep_v > 0 the zone's slow traffic keeps its lane: a vehicle in the lane
#     from the lookahead before s0 to s1 + keep_after_m makes no discretionary lane
#     change while slower than keep_v (booth traffic does not pull out into the express
#     lanes at booth speed; it rejoins once back up to speed or past the keep).
#   - a headway zone scales every vehicle's IDM time headway T over [s0, s1]
#     (tunnel squeeze: "tighter traffic").
# Zones are grouped by tag (the set piece's serial) for removal. Director rate to add or
# remove; the tick reads them allocation-free.

## Caps lane `lane`'s speed at v_max (m/s) over [s0, s1]; with keep_v > 0 its traffic
## keeps the lane up to s1 + keep_after_m while slower than keep_v (m/s). False when
## MAX_SPEED_ZONES are live.
func add_speed_zone(lane: int, s0: float, s1: float, v_max: float, tag: int, keep_after_m: float = 0.0,
		keep_v: float = 0.0) -> bool:
	if _sz_n >= MAX_SPEED_ZONES:
		return false
	_sz_lane[_sz_n] = lane
	_sz_s0[_sz_n] = s0
	_sz_s1[_sz_n] = s1
	_sz_v[_sz_n] = v_max
	_sz_tag[_sz_n] = tag
	_sz_keep_s1[_sz_n] = s1 + keep_after_m
	_sz_keep_v[_sz_n] = keep_v
	_sz_n += 1
	return true


## True when vehicle i keeps its lane for a speed zone (see add_speed_zone). Allocation-free.
func kept_by_zone(i: int) -> bool:
	var si := _ks[i]
	var lane := state.lane[i]
	for z in _sz_n:
		if _sz_lane[z] == lane and _kv[i] < _sz_keep_v[z] and si <= _sz_keep_s1[z] and _sz_s0[z] - si < _look:
			return true
	return false


## Scales every vehicle's IDM time headway by `scale` over [s0, s1]. False when full.
func add_headway_zone(s0: float, s1: float, scale: float, tag: int) -> bool:
	if _hz_n >= MAX_HEADWAY_ZONES:
		return false
	_hz_s0[_hz_n] = s0
	_hz_s1[_hz_n] = s1
	_hz_k[_hz_n] = scale
	_hz_tag[_hz_n] = tag
	_hz_n += 1
	return true


## Removes every speed and headway zone with this tag. Director rate.
func remove_zones(tag: int) -> void:
	var w := 0
	for z in _sz_n:
		if _sz_tag[z] != tag:
			_sz_lane[w] = _sz_lane[z]
			_sz_s0[w] = _sz_s0[z]
			_sz_s1[w] = _sz_s1[z]
			_sz_v[w] = _sz_v[z]
			_sz_tag[w] = _sz_tag[z]
			_sz_keep_s1[w] = _sz_keep_s1[z]
			_sz_keep_v[w] = _sz_keep_v[z]
			w += 1
	_sz_n = w
	w = 0
	for z in _hz_n:
		if _hz_tag[z] != tag:
			_hz_s0[w] = _hz_s0[z]
			_hz_s1[w] = _hz_s1[z]
			_hz_k[w] = _hz_k[z]
			_hz_tag[w] = _hz_tag[z]
			w += 1
	_hz_n = w


func speed_zone_count() -> int:
	return _sz_n


func headway_zone_count() -> int:
	return _hz_n


## The speed a vehicle of profile p at `front` (its front bumper) in `lane` may drive:
## v_max inside a zone of the lane, the speed it can comfortably brake from to reach
## v_max at the zone before one, INF with none ahead within the lookahead.
## Allocation-free.
func speed_limit_at(lane: int, front: float, p: int) -> float:
	var lim := INF
	for z in _sz_n:
		if _sz_lane[z] != lane or front > _sz_s1[z]:
			continue
		var ahead := _sz_s0[z] - front
		if ahead <= 0.0:
			lim = minf(lim, _sz_v[z])
		elif ahead < _look:
			lim = minf(lim, sqrt(_sz_v[z] * _sz_v[z] + 2.0 * _pb[p] * ahead))
	return lim


## The headway scale at s (1 outside every headway zone). Allocation-free.
func headway_scale_at(s: float) -> float:
	var k := 1.0
	for z in _hz_n:
		if s >= _hz_s0[z] and s <= _hz_s1[z]:
			k = minf(k, _hz_k[z])
	return k


## IDM free-road acceleration toward the lane's speed limit and, before a zone, at
## least the constant deceleration that brings the vehicle to the zone's speed at its
## start (INF: no zone ahead). IDM alone lags a falling limit by about b v / (delta a):
## a truck (a 0.6, b 1.5) would come into the zone far above its speed.
func _speed_zone_accel(lane: int, i: int, vi: float, v0: float, p: int) -> float:
	var front := _ks[i] + _khl[i]
	var lim := speed_limit_at(lane, front, p)
	if lim >= v0:
		return INF
	var a := Idm.free_accel(vi, lim, _pa[p], _pdl[p])
	for z in _sz_n:
		if _sz_lane[z] != lane or vi <= _sz_v[z]:
			continue
		var ahead := _sz_s0[z] - front
		if ahead > 0.0 and ahead < _look:
			a = minf(a, (_sz_v[z] * _sz_v[z] - vi * vi) / (2.0 * ahead))
	return a


# ---------------------------------------------------------------- Tick

## Advances traffic by dt (called at 120 Hz after vehicle physics). `player` is the
## player's state this tick (a participant: a leader for cars behind it, a follower
## in MOBIL's safety check). Reactions go to out_events. Allocation-free.
func step(dt: float, player: VehicleState, _player_params: VehicleParams, out_events: ScoreEventBuffer) -> void:
	if _n_pending > 0:
		_emit_pending(out_events)
	_read_player(player)
	_edge = road.lanes_left_edge_d(_ps)
	_lw = road.lane_width(_ps)
	# 1. Schedule (near / far) and integrate every vehicle over dt with the acceleration
	#    decided last model tick (far vehicles hold theirs between 30 Hz updates).
	for k in _n:
		var i := _ord[k]
		if i == _P:
			continue
		var far := absf(_ks[i] - _ps) > _near_r
		var f := state.flags[i]
		var nf := (f | TrafficState.FLAG_FAR) if far else (f & ~TrafficState.FLAG_FAR)
		if nf != f:
			state.flags[i] = nf
		var due := 1
		if far:
			_acc_t[i] += dt
			_acc_n[i] += 1
			if _acc_n[i] >= _far_ratio:
				_mdt[i] = _acc_t[i]
				_acc_t[i] = 0.0
				_acc_n[i] = 0
			else:
				due = 0
		else:
			_mdt[i] = dt + _acc_t[i]
			_acc_t[i] = 0.0
			_acc_n[i] = 0
		_due[i] = due
		var a := state.accel[i]
		var v := _kv[i]
		var s := _ks[i]
		var nv := v + a * dt
		if nv < 0.0:
			if a < 0.0:
				s -= v * v / (2.0 * a)
			nv = 0.0
		else:
			s += (v + nv) * 0.5 * dt
		_ks[i] = s
		_kv[i] = nv
		state.s[i] = s
		state.v[i] = nv
		if due == 0:
			var vl := state.v_lat[i]
			if vl != 0.0:
				state.d[i] += vl * dt
				_refresh_interval(i)
	_sort()
	# 2. Model accelerations of the due vehicles, everyone (the player too) at the same
	#    instant: leaders, IDM, reactions, the clamp and the brake lights.
	for k in _n:
		var i := _ord[k]
		if i != _P and _due[i] == 1:
			_step_accel(i, k, out_events)
	# 3. Lane changes, hit recovery, reactions.
	for k in _n:
		var i := _ord[k]
		if i != _P and _due[i] == 1:
			_step_lateral(i, out_events)


# ---------------------------------------------------------------- Model: acceleration

func _step_accel(i: int, k: int, out: ScoreEventBuffer) -> void:
	var si := _ks[i]
	var vi := _kv[i]
	var v0 := state.v0[i]
	var margin := _lat_m
	if _split[i] != 0:
		v0 = minf(v0, _split_v0)
		margin = _split_clear
	var lo := _klo[i] - margin
	var hi := _khi[i] + margin
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
	var p := state.profile_id[i]
	var a: float
	var gap := INF
	var hw_t := _pT[p] if _hz_n == 0 else _pT[p] * headway_scale_at(si)   # WP6.3 headway zones
	if lead >= 0:
		gap = _ks[lead] - si - _khl[lead] - _khl[i]
		a = Idm.accel(vi, v0, gap, vi - _kv[lead], _pa[p], _pb[p], hw_t, _ps0[p], _pdl[p], _gap_floor)
	else:
		a = Idm.free_accel(vi, v0, _pa[p], _pdl[p])
	if _cl_n > 0:
		a = minf(a, _closure_wall_accel(i, vi, v0, p))
	if _sz_n > 0:
		a = minf(a, _speed_zone_accel(state.lane[i], i, vi, v0, p))   # WP6.3 speed zones
	_lead[i] = lead
	_lead_gap[i] = gap
	_a_raw[i] = a
	stat_model_updates += 1

	# Brake tap when the player cuts in less than cut_in_brake_tap_distance_m ahead.
	var mdt := _mdt[i]
	var tap := _tap_t[i]
	if tap > -_react_cool:
		tap = maxf(tap - mdt, -_react_cool)
	var lead_p := lead == _P
	if lead_p and _prev_lead_p[i] == 0 and gap < _cut_in_m and tap <= -_react_cool:
		tap = _tap_s
		out.push(KIND_BRAKE_TAP, 0, 0.0, -1.0, i, gap, TAG_CUT_IN)
	_tap_t[i] = tap
	_prev_lead_p[i] = 1 if lead_p else 0
	if tap > 0.0:
		a = minf(a, -_tap_decel)
	var f := state.flags[i]
	if (f & TrafficState.FLAG_HIT) != 0 and _hit_recover - state.react_timer[i] < _hit_brake_s:
		a = minf(a, -_hit_decel)
	# Fairness rule 4: never beyond the clamp outside set pieces announced >= 300 m ahead.
	var lim := _scripted_decel if (f & TrafficState.FLAG_SCRIPTED) != 0 and _hard_ok[i] == 1 else _max_decel
	if a < -lim:
		a = -lim
	state.accel[i] = a
	# Fairness rule 3: readable braking.
	var nf := f & ~_BRAKES
	if a < -_brake_decel:
		nf |= TrafficState.FLAG_BRAKE
	if a < -_brake_strong:
		nf |= TrafficState.FLAG_BRAKE_STRONG
	if nf != f:
		state.flags[i] = nf


# ---------------------------------------------------------------- Model: lateral

func _step_lateral(i: int, out: ScoreEventBuffer) -> void:
	var mdt := _mdt[i]
	var st := state.lc_state[i]
	var f := state.flags[i]
	if st == _SIGNALING:
		_tick_signaling(i, mdt)
	elif st == _MOVING:
		_tick_moving(i, mdt)
	elif (f & TrafficState.FLAG_HIT) == 0 and _cl_n > 0 and _hold[i] == 0 \
			and closure_ahead(state.lane[i], _ks[i] + _khl[i]) < _merge_zone:
		# Mandatory merge: every model tick, or a MOBIL interval after a cancelled one.
		var mt := minf(_mobil_t[i], _peval[state.profile_id[i]]) - mdt
		_mobil_t[i] = maxf(mt, 0.0)
		if mt <= 0.0:
			_consider_merge(i)
	elif (f & (TrafficState.FLAG_HIT | TrafficState.FLAG_SCRIPTED)) == 0:
		var mt := _mobil_t[i] - mdt
		if mt <= 0.0:
			var p := state.profile_id[i]
			_mobil_t[i] = _peval[p]
			if _split[i] != 0:
				_consider_split_exit(i)
			elif _sz_n > 0 and kept_by_zone(i):
				pass   # WP6.3: slow zone traffic keeps its lane
			else:
				_consider_lane_change(i)
				if _psplit[p] == 1 and state.lc_state[i] == _NONE:
					_consider_split(i)
		else:
			_mobil_t[i] = mt
	if (f & TrafficState.FLAG_HIT) != 0:
		_tick_hit(i, mdt, out)
	if absf(_ks[i] - _ps) < _react_range:
		_tick_reactions(i, mdt, out)
	_refresh_interval(i)


func _tick_signaling(i: int, mdt: float) -> void:
	var timer := state.lc_timer[i] + mdt
	state.lc_timer[i] = timer
	var ok := not is_inf(_eval_move(i, _lc_target_d[i], state.target_lane[i], false))
	# Fairness rule 2: the player entered the target gap (or its predicted space) -> cancel.
	if not ok and _q_player:
		_cancel(i)
		stat_cancel_player += 1
		return
	if timer < state.lc_duration[i]:
		return
	if _will_cancel[i] == 1:
		_cancel(i)
		stat_cancel_hesitant += 1
	elif not ok:
		_cancel(i)
		stat_cancel_unsafe += 1
	else:
		# Fairness rule 1: lateral motion only after the full signal time. The move
		# starts next model tick from here (lc_start_d).
		var p := state.profile_id[i]
		state.lc_state[i] = _MOVING
		state.lc_timer[i] = 0.0
		state.lc_start_d[i] = state.d[i]
		var mn := _pmmin[p]
		var mx := _pmmax[p]
		state.lc_duration[i] = mn if mx <= mn else _rng_lc.float_range(mn, mx)
		stat_moves += 1


func _tick_moving(i: int, mdt: float) -> void:
	var dur := state.lc_duration[i]
	var tm := state.lc_timer[i] + mdt
	state.lc_timer[i] = tm
	var t := state.target_lane[i]
	var tc := _lc_target_d[i]
	if tm >= dur:
		if state.d[i] != tc:
			# Last lateral step with the blinker still on; finish on the next model tick.
			state.d[i] = tc
			state.v_lat[i] = 0.0
			return
		state.lane[i] = t
		state.d[i] = tc
		state.v_lat[i] = 0.0
		state.lc_state[i] = _NONE
		state.lc_timer[i] = 0.0
		state.lc_duration[i] = 0.0
		state.flags[i] &= ~_BLINKERS
		_split[i] = _lc_split[i]
		_lc_split[i] = 0
		_mobil_t[i] = _cooldown
		stat_completed += 1
		return
	var d0 := state.lc_start_d[i]
	var span := tc - d0
	var u := tm / dur
	state.d[i] = d0 + span * u * u * (_SMOOTH_A - 2.0 * u)
	state.v_lat[i] = span * _SMOOTH_D * u * (1.0 - u) / dur


func _tick_hit(i: int, mdt: float, out: ScoreEventBuffer) -> void:
	var rt := state.react_timer[i] - mdt
	var dir := _swerve_dir[i]
	if dir != 0.0 and state.lc_state[i] == _NONE:
		var elapsed := _hit_recover - rt
		if elapsed < _hit_swerve_s and rt > 0.0:
			# Out and back: smoothstep up over the first half, down over the second.
			var u := elapsed / _hit_swerve_s
			var x := 2.0 * u
			var sgn := 1.0
			if u > 0.5:
				x = 2.0 - x
				sgn = -1.0
			var off := _hit_swerve_m * x * x * (_SMOOTH_A - 2.0 * x)
			var rate := _hit_swerve_m * _SMOOTH_D * x * (1.0 - x) * 2.0 / _hit_swerve_s
			state.d[i] = _swerve_base[i] + dir * off
			state.v_lat[i] = dir * sgn * rate
		else:
			state.d[i] = _swerve_base[i]
			state.v_lat[i] = 0.0
			_swerve_dir[i] = 0.0
	if rt <= 0.0:
		rt = 0.0
		var f := state.flags[i] & ~TrafficState.FLAG_HIT
		if _hit_hazard[i] == 1:
			f &= ~TrafficState.FLAG_HAZARD
			_hit_hazard[i] = 0
			out.push(KIND_HAZARDS, 0, 0.0, -1.0, i, 0.0, TAG_HIT)
		state.flags[i] = f
		_mobil_t[i] = _cooldown
	state.react_timer[i] = rt


func _tick_reactions(i: int, mdt: float, out: ScoreEventBuffer) -> void:
	var rel := _ks[i] - _ps   # car center ahead of the player's center
	var same_path := _klo[i] < _phi and _khi[i] > _plo
	# No night-tailgating high beams (owner decision D8): FLAG_HIGH_BEAM stays defined for
	# later use (the player's manual high beams), but the sim never sets it.
	# Blind spot: one lane over, the player's center up to blind_spot_behind_m behind the car's.
	var bt := _blind_t[i]
	if bt < 0.0:
		bt = minf(bt + mdt, 0.0)
	elif not same_path and rel >= 0.0 and rel <= _blind_m and absf(_pd - state.d[i]) < _lw + _lw * 0.5:
		bt += mdt
		if bt >= _blind_s:
			bt = -_react_cool
			if _rng_react.chance(_blind_frac):
				out.push(KIND_HORN, 0, 0.0, -1.0, i, 0.0, TAG_BLIND_SPOT)
	else:
		bt = 0.0
	_blind_t[i] = bt


# ---------------------------------------------------------------- Lane changes

func _consider_lane_change(i: int) -> void:
	var cur := state.lane[i]
	var gl := _eval_target(i, cur - 1, true)
	var gr := _eval_target(i, cur + 1, true)
	if gl > 0.0 and gl >= gr:
		_start_signal(i, cur - 1, _lane_d(cur - 1), 0)
	elif gr > 0.0:
		_start_signal(i, cur + 1, _lane_d(cur + 1), 0)


## Motorbikes: in slow traffic that MOBIL cannot escape, move onto a lane boundary
## (left one first) with the usual telegraphing, then filter past narrow-enough
## vehicles. Never starts during the player's lane change nearby.
func _consider_split(i: int) -> void:
	if _cl_n > 0 and (_closes_soon(state.lane[i], i) or _closes_soon(state.lane[i] - 1, i) \
			or _closes_soon(state.lane[i] + 1, i)):
		return   # no lane splitting next to a lane that ends
	if _sz_n > 0 and _slow_zone_beside(i):
		return   # WP6.3: nor beside a slow zone (a toll's booth lane next to the express lanes)
	var lead := _lead[i]
	if lead < 0 or lead == _P or _kv[lead] >= _split_max_v or _lead_gap[i] > _split_scan \
			or state.v0[i] <= _split_max_v:
		return
	if absf(_pvl) > _split_player_lat and absf(_ks[i] - _ps) < _split_player_range:
		return
	var cur := state.lane[i]
	var half := _lw * 0.5
	if cur > 0 and not is_inf(_eval_move(i, _lane_d(cur) - half, cur, false)):
		_start_signal(i, cur, _lane_d(cur) - half, -1)
	elif cur < road.lane_count(_ks[i]) - 1 and not is_inf(_eval_move(i, _lane_d(cur) + half, cur, false)):
		_start_signal(i, cur, _lane_d(cur) + half, 1)


## True when a speed zone (WP6.3) lies within the lookahead in vehicle i's lane or one
## beside it. Allocation-free.
func _slow_zone_beside(i: int) -> bool:
	var front := _ks[i] + _khl[i]
	var cur := state.lane[i]
	for z in _sz_n:
		if absi(_sz_lane[z] - cur) <= 1 and front <= _sz_s1[z] and _sz_s0[z] - front < _look:
			return true
	return false


## A splitting bike returns to a lane center once nothing slow is left ahead of it.
func _consider_split_exit(i: int) -> void:
	var si := _ks[i]
	var di := state.d[i]
	var kk := _rank[i] + 1
	# WP6.3: a slow zone beside it ends the split whatever is ahead (between a slow lane
	# and a fast one a splitting bike would hide the fast lane's traffic from cars
	# leaving the slow one: MOBIL's safety check sees the nearest follower only).
	if _sz_n > 0 and _slow_zone_beside(i):
		kk = _n
	while kk < _n:
		var j := _ord[kk]
		if _ks[j] - si > _split_scan:
			break
		if j != _P and _kv[j] < _split_max_v and absf(state.d[j] - di) < _lw:
			return
		kk += 1
	var cur := state.lane[i]
	var other := cur + _split[i]
	if not is_inf(_eval_move(i, _lane_d(cur), cur, false)):
		_start_signal(i, cur, _lane_d(cur), 0)
	elif not is_inf(_eval_move(i, _lane_d(other), other, false)):
		_start_signal(i, other, _lane_d(other), 0)


## Starts the blinker for a lateral move to target_d (lane t; `split` = entering a
## lane split on that side of the lane, else 0).
func _start_signal(i: int, t: int, target_d: float, split: int) -> void:
	var p := state.profile_id[i]
	state.lc_state[i] = _SIGNALING
	state.target_lane[i] = t
	state.lc_timer[i] = 0.0
	state.lc_duration[i] = _psig[p]
	_lc_target_d[i] = target_d
	_lc_split[i] = split
	_split[i] = 0
	var f := state.flags[i] & ~_BLINKERS
	f |= TrafficState.FLAG_BLINKER_LEFT if target_d < state.d[i] else TrafficState.FLAG_BLINKER_RIGHT
	state.flags[i] = f
	var pc := _pcancel[p]
	_will_cancel[i] = 0
	if pc > 0.0:
		stat_hesitant_signals += 1
		if _rng_lc.chance(pc):
			_will_cancel[i] = 1
	stat_signals += 1
	_refresh_interval(i)


func _cancel(i: int) -> void:
	state.lc_state[i] = _NONE
	state.target_lane[i] = state.lane[i]
	state.lc_timer[i] = 0.0
	state.lc_duration[i] = 0.0
	state.flags[i] &= ~_BLINKERS
	_will_cancel[i] = 0
	_mobil_t[i] = _cooldown
	if _lc_split[i] == 0 and absf(state.d[i] - _lane_d(state.lane[i])) > _lw * 0.5 * 0.5:
		# A cancelled return from a lane split keeps riding the boundary.
		_split[i] = 1 if state.d[i] > _lane_d(state.lane[i]) else -1
	_lc_split[i] = 0
	_refresh_interval(i)


## MOBIL for a move of vehicle i into lane t. Returns -INF when the move is not allowed
## (lane, keep-right, overlap, safety or no-ambush), else the incentive minus the
## threshold (> 0 = MOBIL accepts), or 0 when with_incentive is false. Sets _q_player
## when the refusal involves the player.
func _eval_target(i: int, t: int, with_incentive: bool) -> float:
	_q_player = false
	var lanes := road.lane_count(_ks[i])
	if t < 0 or t >= lanes:
		return -INF
	if _cl_n > 0 and _closes_soon(t, i):
		return -INF   # never into a lane that ends within merge_zone_m
	var krl := _pkrl[state.profile_id[i]]
	if krl > 0 and t < state.lane[i] and t < lanes - krl:
		return -INF
	return _eval_move(i, _lane_d(t), t, with_incentive)


## Safety (and optionally MOBIL's incentive) of a lateral move of vehicle i to tc,
## ending in lane t. Same result convention as _eval_target.
func _eval_move(i: int, tc: float, t: int, with_incentive: bool) -> float:
	_q_player = false
	var si := _ks[i]
	var cur := state.lane[i]
	var p := state.profile_id[i]
	var vi := _kv[i]
	var wi := state.width[i]
	var hw := wi * 0.5
	var lo := tc - hw - _lat_m
	var hi := tc + hw + _lat_m
	var k := _rank[i]
	# New leader and new follower in the target lane (claims count).
	var lead := -1
	var kk := k + 1
	while kk < _n:
		var j := _ord[kk]
		if _ks[j] - si > _look:
			break
		if _kclo[j] < hi and _kchi[j] > lo:
			lead = j
			break
		kk += 1
	var foll := -1
	kk = k - 1
	while kk >= 0:
		var j := _ord[kk]
		if si - _ks[j] > _look:
			break
		if _kclo[j] < hi and _kchi[j] > lo:
			foll = j
			break
		kk -= 1
	var v0 := state.v0[i]
	var bsafe := _pbsafe[p]
	var a_c_new: float
	if lead >= 0:
		var gl := _ks[lead] - si - _khl[lead] - _khl[i]
		if gl <= 0.0:
			_q_player = lead == _P
			return -INF
		a_c_new = Idm.accel(vi, v0, gl, vi - _kv[lead], _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p], _gap_floor)
		if a_c_new < -bsafe:
			_q_player = lead == _P
			return -INF
	else:
		a_c_new = Idm.free_accel(vi, v0, _pa[p], _pdl[p])
	if _sz_n > 0:
		a_c_new = minf(a_c_new, _speed_zone_accel(t, i, vi, v0, p))   # WP6.3: a slow zone in the target lane
	var a_n_new := 0.0
	if foll >= 0:
		var gf := si - _ks[foll] - _khl[i] - _khl[foll]
		if gf <= 0.0:
			_q_player = foll == _P
			return -INF
		a_n_new = _follower_accel(foll, gf, _kv[foll] - vi)
		var b := Mobil.b_safe_for(bsafe, foll == _P, _player_b_safe)
		if not Mobil.is_safe(a_n_new, b):
			_q_player = foll == _P
			return -INF
	# Fairness rule 2: no ambush.
	if NoAmbush.violates(si, vi, state.length[i], wi, tc, _ps, _pv, _pd, _pvl, _plen, _pw, _window, _margin):
		_q_player = true
		return -INF
	if not with_incentive:
		return 0.0
	var a_n := 0.0
	if foll >= 0:
		if lead >= 0:
			a_n = _follower_accel(foll, _ks[lead] - _ks[foll] - _khl[lead] - _khl[foll], _kv[foll] - _kv[lead])
		else:
			a_n = _follower_accel(foll, INF, 0.0)
	# Old follower (physical path behind i).
	var olo := _klo[i] - _lat_m
	var ohi := _khi[i] + _lat_m
	var of := -1
	kk = k - 1
	while kk >= 0:
		var j := _ord[kk]
		if si - _ks[j] > _look:
			break
		if _klo[j] < ohi and _khi[j] > olo:
			of = j
			break
		kk -= 1
	var a_o := 0.0
	var a_o_new := 0.0
	if of >= 0:
		a_o = _follower_accel(of, si - _ks[of] - _khl[i] - _khl[of], _kv[of] - vi)
		var ol := _lead[i]
		if ol >= 0 and ol != of:
			a_o_new = _follower_accel(of, _ks[ol] - _ks[of] - _khl[ol] - _khl[of], _kv[of] - _kv[ol])
		else:
			a_o_new = _follower_accel(of, INF, 0.0)
	var inc := Mobil.incentive(a_c_new, _a_raw[i], a_n_new, a_n, a_o_new, a_o, _ppol[p])
	# Keep-right bias, plus lane discipline (fairness rule 7): slow drivers keep right.
	var lanes := road.lane_count(si)
	var to_right := t > cur
	var bias := _pbias[p]
	if to_right:
		if _pkr[p] == 1 or v0 < tuning.lane_flow_speed_mps(cur, lanes):
			bias += _disc
	elif v0 < tuning.lane_flow_speed_mps(t, lanes):
		bias += _disc
	return inc - Mobil.threshold(_pth[p], bias, to_right)


## IDM acceleration of follower f (slot or the player) at this gap / closing speed.
## The player is judged as holding its speed (interaction term only).
func _follower_accel(f: int, gap: float, dv: float) -> float:
	if f == _P:
		return Idm.interaction_accel(_kv[_P], gap, dv, _pl_a, _pl_b, _pl_T, _pl_s0, _gap_floor)
	var p := state.profile_id[f]
	return Idm.accel(_kv[f], state.v0[f], gap, dv, _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p], _gap_floor)


# ---------------------------------------------------------------- Helpers

## Lane center d (lane geometry of this tick).
func _lane_d(lane: int) -> float:
	return _edge + (float(lane) + 0.5) * _lw


func _read_player(player: VehicleState) -> void:
	var cy := cos(player.yaw)
	var sy := sin(player.yaw)
	var kappa := road.curvature_at(player.s)
	_ps = player.s
	_pd = player.d
	_pv = (player.v * cy - player.v_lat * sy) / (1.0 - kappa * player.d)
	_pvl = player.v * sy + player.v_lat * cy
	_plo = _pd - _pw * 0.5
	_phi = _pd + _pw * 0.5
	var ahead := _pvl * _antic
	_ks[_P] = _ps
	_kv[_P] = _pv
	_klo[_P] = _plo + minf(0.0, ahead)
	_khi[_P] = _phi + maxf(0.0, ahead)
	_kclo[_P] = _klo[_P]
	_kchi[_P] = _khi[_P]


## Insertion sort of the order by s (nearly sorted every tick: ~O(n)).
func _sort() -> void:
	var swapped := false
	for k in range(1, _n):
		var x := _ord[k]
		var sx := _ks[x]
		var m := k - 1
		while m >= 0 and _ks[_ord[m]] > sx:
			_ord[m + 1] = _ord[m]
			m -= 1
		if m != k - 1:
			_ord[m + 1] = x
			swapped = true
	if swapped:
		for k in _n:
			_rank[_ord[k]] = k


func _refresh_interval(i: int) -> void:
	var hw := state.width[i] * 0.5
	var d := state.d[i]
	var lo := d - hw
	var hi := d + hw
	var st := state.lc_state[i]
	if st == _NONE:
		if _split[i] != 0:
			# A bike on the boundary claims both lanes for MOBIL's gap search, so no car
			# changes lanes across it.
			_kclo[i] = d - _lw * 0.5
			_kchi[i] = d + _lw * 0.5
		else:
			_kclo[i] = lo
			_kchi[i] = hi
	else:
		var tc := _lc_target_d[i]
		var clo := minf(lo, tc - hw)
		var chi := maxf(hi, tc + hw)
		_kclo[i] = clo
		_kchi[i] = chi
		if st == _MOVING:
			lo = clo
			hi = chi
	_klo[i] = lo
	_khi[i] = hi


func _emit_pending(out: ScoreEventBuffer) -> void:
	for k in _n:
		var i := _ord[k]
		if i == _P:
			continue
		var pb := _pending[i]
		if pb == 0:
			continue
		if (pb & _PEND_HAZARD_ON) != 0:
			out.push(KIND_HAZARDS, 0, 0.0, -1.0, i, 1.0, TAG_HIT)
		if (pb & _PEND_HORN) != 0:
			out.push(KIND_HORN, 0, 0.0, -1.0, i, 0.0, _pending_tag[i])
		_pending[i] = 0
	_n_pending = 0


func _cache_tuning() -> void:
	var t := tuning
	_max_decel = t.max_decel_mps2
	_scripted_decel = maxf(t.scripted_max_decel_mps2, t.max_decel_mps2)
	_brake_decel = t.brake_light_decel_mps2
	_brake_strong = t.brake_light_strong_decel_mps2
	_look = t.idm_lookahead_m
	_gap_floor = t.idm_gap_floor_m
	_lat_m = t.lateral_margin_m
	_near_r = t.near_radius_m
	_far_ratio = t.far_tick_ratio()
	_window = t.no_ambush_window_s
	_margin = t.no_ambush_margin_m
	_player_b_safe = t.player_b_safe_mps2
	_cooldown = t.lane_change_cooldown_s
	_disc = t.lane_discipline_bias_mps2
	_antic = t.player_lateral_anticipation_s
	_pl_a = t.player_idm_a_max_mps2
	_pl_b = t.player_idm_b_comfort_mps2
	_pl_T = t.player_idm_headway_s
	_pl_s0 = t.player_idm_s0_m
	_plen = t.player_length_m
	_pw = t.player_width_m
	_hit_recover = t.hit_recover_s
	_hit_swerve_m = t.hit_swerve_m
	_hit_swerve_s = t.hit_swerve_s
	_hit_decel = t.hit_brake_decel_mps2
	_hit_brake_s = t.hit_brake_s
	_tap_decel = t.brake_tap_decel_mps2
	_tap_s = t.brake_tap_s
	_cut_in_m = t.cut_in_brake_tap_distance_m
	_blind_m = t.blind_spot_behind_m
	_blind_s = t.blind_spot_horn_s
	_blind_frac = t.blind_spot_horn_frac()
	_close_frac = t.close_pass_horn_frac()
	_react_cool = t.reaction_cooldown_s
	_split_max_v = Units.kmh_to_mps(t.lane_split_max_traffic_kmh)
	_split_v0 = Units.kmh_to_mps(t.lane_split_max_speed_kmh)
	_split_scan = t.lane_split_scan_m
	_split_clear = t.lane_split_clearance_m
	_split_player_lat = t.lane_split_player_lateral_mps
	_split_player_range = t.lane_split_player_range_m
	_merge_zone = t.merge_zone_m
	_merge_urg = t.merge_urgency_mps2
	_merge_stop = t.merge_stop_margin_m
