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
## Lane-drop harmonisation zones (WP6.8): one per road lane drop in the synced range.
const MAX_DROP_ZONES := 8

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
var _sig_pre := PackedFloat64Array()   # far: _acc_t already accumulated when a signal began between ticks
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
# WP6.8, per slot, from its last model tick (_drop_tick): merge-zone fractions of its
# own lane and the lanes left / right of it, its own closure's base urgency and distance,
# and the speed-matching factor.
var _cf_own := PackedFloat64Array()
var _cf_left := PackedFloat64Array()
var _cf_right := PackedFloat64Array()
var _cf_base := PackedFloat64Array()
var _cf_dist := PackedFloat64Array()
var _match := PackedFloat64Array()
# WP6.8: this step's zipper candidates (vehicles still in a closing lane, in the last
# lane_drop_yield_frac of its merge zone), in road order.
var _cand := PackedInt32Array()
var _cand_n := 0
# Lane closures (WP6.2): lane, [s0, s1], tag
var _cl_lane := PackedInt32Array()
var _cl_s0 := PackedFloat64Array()
var _cl_s1 := PackedFloat64Array()
var _cl_tag := PackedInt32Array()
var _cl_zone := PackedFloat64Array()   # WP6.8: this closure's merge zone (m)
var _cl_base := PackedFloat64Array()   # WP6.8: merge urgency at the start of that zone (m/s^2)
var _cl_n := 0
var _cl_road_to := -INF
var _merge_zone: float
var _merge_urg: float
var _merge_stop: float
# Lane drops (WP6.8): harmonisation zones [s0, s1]; lanes >= first lane are the dropping ones.
var _dz_s0 := PackedFloat64Array()
var _dz_s1 := PackedFloat64Array()
var _dz_lane := PackedInt32Array()
var _dz_n := 0
var _drop_zone: float
var _drop_urg_min: float
var _drop_slow: float
var _drop_after: float
var _drop_v_through: float
var _drop_v_merge: float
var _yield_range: float
var _yield_frac: float
var _yield_decel: float
var _foll_horizon: float
var _drop_onset: float
var _drop_view: float
var _drop_release: float
var _drop_floor: float
var _drop_floor_until: float
var _drop_narrow_max: float
var _look_through := false          # MP-D5 (WP6.11): a leader leaving the path hides nothing
var _predict_leaders := false       # MP-D5: MOBIL judges the new leader when the car is in the lane
var _anticipate := false            # MP-D5: brake for the leader's own stopping point
var _vmax := 0.0                   # fastest vehicle this step (bounds MOBIL's follower scan)
var _cl_lo := INF                  # this step: no closure's merge zone starts before here ...
var _cl_hi := -INF                 # ... and none ends after here
var _dz_lo := INF                  # this step: no drop zone is in view before here ...
var _dz_hi := -INF                 # ... or matters after here (release)
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
var _q_v0 := 0.0                   # _drop_tick: the matched desired speed


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
	_init_weave(reg)   # WP6.9
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
	_sig_pre.resize(_cap)
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
	_cf_own.resize(_cap)
	_cf_left.resize(_cap)
	_cf_right.resize(_cap)
	_cf_base.resize(_cap)
	_cf_dist.resize(_cap)
	_match.resize(_cap)
	_cand.resize(_cap)
	_cl_lane.resize(MAX_LANE_CLOSURES)
	_cl_s0.resize(MAX_LANE_CLOSURES)
	_cl_s1.resize(MAX_LANE_CLOSURES)
	_cl_tag.resize(MAX_LANE_CLOSURES)
	_cl_zone.resize(MAX_LANE_CLOSURES)
	_cl_base.resize(MAX_LANE_CLOSURES)
	_dz_s0.resize(MAX_DROP_ZONES)
	_dz_s1.resize(MAX_DROP_ZONES)
	_dz_lane.resize(MAX_DROP_ZONES)
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
	_sig_pre[i] = 0.0
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
	_cf_own[i] = INF
	_cf_left[i] = INF
	_cf_right[i] = INF
	_cf_base[i] = 0.0
	_cf_dist[i] = INF
	_match[i] = 0.0

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
#
# Road lane drops (WP6.8, docs/TRAFFIC.md "Lane drops"): the way real traffic takes a
# lane drop, so that nobody merges from a standstill into fast lanes.
#   - Early, graded merging: a road drop's merge zone is lane_drop_merge_zone_m (1 km)
#     long and its urgency starts at lane_drop_urgency_min_mps2; far from the drop the
#     merge is evaluated at the profile's MOBIL interval, within merge_zone_m every tick.
#   - Harmonisation: a drop zone caps every lane from the lane_ends sign through the
#     narrowed section (through lanes lane_drop_through_kmh, the dropping lane
#     lane_drop_merge_lane_kmh); vehicles brake into it at their comfortable
#     deceleration, and slower ones speed up to it (speed matching).
#   - Zipper: a vehicle beside a dropping lane eases off (at most
#     lane_drop_yield_decel_mps2) for the nearest car still in that lane ahead of it, so
#     the gap opens (_yield_accel).
#   - MOBIL's safety check covers every faster follower that could reach the gap
#     (_eval_move), not just the nearest one.

## Adds a closure of `lane` over [s0, s1] (`tag` groups closures for removal; the road's
## use ROAD_CLOSURE_TAG). `zone_m` > 0: its merge zone (default merge_zone_m); `base`:
## the merge urgency where that zone starts (m/s^2). False when MAX_LANE_CLOSURES are
## live. Director rate.
func add_lane_closure(lane: int, s0: float, s1: float, tag: int = 0, zone_m: float = 0.0,
		base: float = 0.0) -> bool:
	if _cl_n >= MAX_LANE_CLOSURES:
		return false
	_cl_lane[_cl_n] = lane
	_cl_s0[_cl_n] = s0
	_cl_s1[_cl_n] = s1
	_cl_tag[_cl_n] = tag
	_cl_zone[_cl_n] = zone_m if zone_m > 0.0 else _merge_zone
	_cl_base[_cl_n] = base
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


## Drops closures (and lane-drop zones) that end before `s` (behind the player).
## Director rate.
func forget_lane_closures_before(s: float) -> void:
	var w := 0
	for c in _cl_n:
		if _cl_s1[c] >= s:
			_keep_closure(c, w)
			w += 1
	_cl_n = w
	w = 0
	for z in _dz_n:
		if _dz_s1[z] >= s:
			_dz_s0[w] = _dz_s0[z]
			_dz_s1[w] = _dz_s1[z]
			_dz_lane[w] = _dz_lane[z]
			w += 1
	_dz_n = w


func lane_closure_count() -> int:
	return _cl_n


## The road's lane-count changes starting in [s_from, s_to) become closures (the lanes
## between the old and the new count, over the change's start and taper). A drop (fewer
## lanes after) gets the long lane-drop merge zone and a harmonisation zone (WP6.8) from
## its lane_ends sign (lane_drop_slow_zone_m before the taper without one) to
## lane_drop_slow_after_m past the lanes coming back (_lanes_back_s). Repeated calls
## never add a change twice.
## Director rate: allocates.
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
		var drop := after < before
		for l in range(mini(before, after), maxi(before, after)):
			if drop:
				add_lane_closure(l, f.s_start, f.s_end, ROAD_CLOSURE_TAG, _drop_zone, _drop_urg_min)
			else:
				add_lane_closure(l, f.s_start, f.s_end, ROAD_CLOSURE_TAG)
		if drop:
			add_lane_drop_zone(after, _lane_ends_sign_s(f.s_start), _lanes_back_s(f.s_end, before) + _drop_after)
	_cl_road_to = s_to


## Where the lanes a drop took away come back after it (the end of the widening's taper
## back to `lanes` lanes, within lane_drop_narrow_max_m), or `s_taper_end` when they do
## not: the harmonisation holds through the narrowed section (a tunnel's two lanes), so
## its traffic runs at the harmonised speeds instead of dropping back to trucks' and
## cruisers' 80-100 km/h in two lanes (a slow wall the player cannot pass at 100 km/h).
## Director rate: allocates.
func _lanes_back_s(s_taper_end: float, lanes: int) -> float:
	var found: Array[RoadFeature] = []
	road.features_in(s_taper_end, s_taper_end + _drop_narrow_max, found)
	for f in found:
		if f.kind == RoadFeature.Kind.LANE_COUNT_CHANGE and f.s_start >= s_taper_end and int(f.value) >= lanes:
			return f.s_end
	return s_taper_end


## Where the lane_ends sign of a drop starting at `s_drop` stands (the road's SIGN
## feature), or lane_drop_slow_zone_m before the drop without one. Director rate.
func _lane_ends_sign_s(s_drop: float) -> float:
	var signs: Array[RoadFeature] = []
	road.features_in(s_drop - 2.0 * _drop_slow, s_drop, signs)
	var best := s_drop - _drop_slow
	for f in signs:
		if f.kind == RoadFeature.Kind.SIGN and f.tag == ProceduralRoadPath.SIGN_LANE_ENDS and f.s_start <= s_drop \
				and absf(f.s_start + f.value - s_drop) < 1.0:
			best = f.s_start
	return best


## Lane-drop harmonisation zone (WP6.8) over [s0, s1] (the road's: from the lane_ends
## sign through the narrowed section to lane_drop_slow_after_m past the lanes coming
## back): lanes below `first_lane` are
## capped at lane_drop_through_kmh, lanes from it on (the dropping ones) at
## lane_drop_merge_lane_kmh. sync_road_closures adds the road's; tests and the sandbox
## may add their own. False when MAX_DROP_ZONES are live. Director rate.
func add_lane_drop_zone(first_lane: int, s0: float, s1: float) -> bool:
	if _dz_n >= MAX_DROP_ZONES:
		return false
	_dz_lane[_dz_n] = first_lane
	_dz_s0[_dz_n] = s0
	_dz_s1[_dz_n] = s1
	_dz_n += 1
	return true


func lane_drop_zone_count() -> int:
	return _dz_n


## Start and end of lane-drop zone z (tests, sandbox).
func lane_drop_zone_s0(z: int) -> float:
	return _dz_s0[z]


func lane_drop_zone_s1(z: int) -> float:
	return _dz_s1[z]


## The harmonised speed limit for a vehicle of profile p at `front` in `lane` (like
## speed_limit_at: the zone's cap inside it, the comfortable braking envelope before it,
## INF with none within lane_drop_view_m). Allocation-free.
func lane_drop_limit_at(lane: int, front: float, p: int) -> float:
	var lim := INF
	for z in _dz_n:
		if front > _dz_s1[z]:
			continue
		var vz := _drop_v_merge if lane >= _dz_lane[z] else _drop_v_through
		var ahead := _dz_s0[z] - front
		if ahead <= 0.0:
			lim = minf(lim, vz)
		elif ahead < _drop_view:
			lim = minf(lim, sqrt(vz * vz + 2.0 * _pb[p] * ahead))
	return lim


## The fraction of its merge zone left before the next closure of `lane` ahead of s
## (0 at or inside the closure, >= 1 before its zone), INF with none. Allocation-free.
func merge_zone_frac(lane: int, s: float) -> float:
	var best := INF
	for c in _cl_n:
		if _cl_lane[c] == lane and _cl_s1[c] >= s:
			best = minf(best, maxf(_cl_s0[c] - s, 0.0) / _cl_zone[c])
	return best


## Distance from s to the start of the next closure of `lane` still ahead of s (0 when
## s is inside one), INF when none. Allocation-free.
func closure_ahead(lane: int, s: float) -> float:
	var best := INF
	for c in _cl_n:
		if _cl_lane[c] == lane and _cl_s1[c] >= s:
			best = minf(best, maxf(_cl_s0[c] - s, 0.0))
	return best


## Lane t closes within its merge zone ahead of vehicle i's front (or i is inside the closure).
func _closes_soon(t: int, i: int) -> bool:
	return merge_zone_frac(t, _ks[i] + _khl[i]) < 1.0


func _keep_closure(from: int, to: int) -> void:
	_cl_lane[to] = _cl_lane[from]
	_cl_s0[to] = _cl_s0[from]
	_cl_s1[to] = _cl_s1[from]
	_cl_tag[to] = _cl_tag[from]
	_cl_zone[to] = _cl_zone[from]
	_cl_base[to] = _cl_base[from]


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
	var base := _cf_base[i]   # (_drop_tick, this model tick)
	var urgency := base + (_merge_urg - base) * clampf(1.0 - _cf_own[i], 0.0, 1.0)
	# WP6.8: a road drop (a closure with a base urgency) is left on the car's own
	# advantage plus the urgency, like a driver reading the lane_ends sign: no politeness
	# or keep-right threshold holds it in a lane that ends (safety and no-ambush as always).
	var own := base > 0.0
	var gl := _eval_target(i, cur - 1, true, own) + urgency
	var gr := _eval_target(i, cur + 1, true, own) + urgency
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
## a truck (a 0.6, b 1.5) would come into the zone far above its speed. Set-piece speed
## zones and lane-drop zones (WP6.8) alike, for vehicle i in `lane` (MOBIL's target).
func _speed_zone_accel(lane: int, i: int, vi: float, v0: float, p: int) -> float:
	var front := _ks[i] + _khl[i]
	var a := _set_zone_accel(lane, front, vi, v0, p) if _sz_n > 0 else INF
	if _dz_n == 0 or front <= _dz_lo or front >= _dz_hi:
		return a
	var lim := lane_drop_limit_at(lane, front, p)
	if lim < v0:
		a = minf(a, Idm.free_accel(vi, lim, _pa[p], _pdl[p]))
	for z in _dz_n:
		var vz := _drop_v_merge if lane >= _dz_lane[z] else _drop_v_through
		if vi > vz and front <= _dz_s1[z]:
			a = minf(a, _drop_brake(_dz_s0[z] - front, vz, vi, p))
	return a


## The set-piece speed zones' part of _speed_zone_accel (WP6.3).
func _set_zone_accel(lane: int, front: float, vi: float, v0: float, p: int) -> float:
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


## Lane-drop zones (WP6.8): the constant deceleration that brings a vehicle at vi down
## to vz `ahead` metres on, eased in (brake lights ripple instead of every fast car
## braking hard the moment the zone comes into view): none while it needs less than
## lane_drop_brake_onset_frac of the profile's comfortable b, all of it from b on, and
## never more than b (a vehicle that comes into view too fast to make it, or a hair above
## vz in the last centimetres, where the constant deceleration blows up, arrives a little
## fast and IDM's free-road term inside the zone takes it down). INF outside
## (0, lane_drop_view_m).
func _drop_brake(ahead: float, vz: float, vi: float, p: int) -> float:
	if ahead <= 0.0 or ahead >= _drop_view:
		return INF
	var req := (vz * vz - vi * vi) / (2.0 * ahead)
	return maxf(req * clampf((-req / _pb[p] - _drop_onset) / (1.0 - _drop_onset), 0.0, 1.0), -_pb[p])


## WP6.8, once per model tick of vehicle i (front at `front`, speed vi, desired speed v0,
## profile p), in one pass each over the closures and the drop zones; vehicles outside
## every closure's merge zone and every drop zone's reach skip the loops. Returns the
## drop zones' acceleration limit (the envelope and _drop_brake, as _speed_zone_accel)
## and leaves the matched desired speed in _q_v0. Caches per slot, for _step_accel,
## _step_lateral and MOBIL: the merge-zone fractions of its own lane and the lanes
## beside it, its own closure's base urgency and distance, the speed-matching factor.
## Allocation-free.
##
## Speed matching: how much of the way from its own desired speed up to
## lane_drop_merge_lane_kmh a vehicle drives (1: all of it; 0: none). All of it inside a
## lane-drop zone and, before it, while still in a lane that a road drop ends within its
## merge zone: slow trucks and cruisers match the harmonised through lanes, so a merge
## needs an ordinary gap instead of one sized for a 30 km/h speed difference. Past the
## zone it fades out over lane_drop_release_m (no brake lights for giving the speed
## back). Scripted and lane-splitting vehicles: 0.
func _drop_tick(i: int, front: float, vi: float, v0: float, p: int) -> float:
	var own := INF
	var left := INF
	var right := INF
	var base := 0.0
	var dist := INF
	var lane := state.lane[i]
	if _cl_n > 0 and front > _cl_lo and front <= _cl_hi:
		for c in _cl_n:
			if _cl_s1[c] < front:
				continue
			var dl := _cl_lane[c] - lane
			if dl < -1 or dl > 1:
				continue
			var d := maxf(_cl_s0[c] - front, 0.0)
			var u := d / _cl_zone[c]
			if dl == 0:
				if u < own:
					own = u
					base = _cl_base[c]
					dist = d
			elif dl < 0:
				left = minf(left, u)
			else:
				right = minf(right, u)
	_cf_own[i] = own
	_cf_left[i] = left
	_cf_right[i] = right
	_cf_base[i] = base
	_cf_dist[i] = dist
	var m := 1.0 if own < 1.0 and base > 0.0 else 0.0
	var acc := INF
	var lim := INF
	if _dz_n > 0 and front > _dz_lo and front < _dz_hi:
		for z in _dz_n:
			var s1z := _dz_s1[z]
			if front > s1z:
				m = maxf(m, 1.0 - (front - s1z) / _drop_release)
				continue
			var vz := _drop_v_merge if lane >= _dz_lane[z] else _drop_v_through
			var ahead := _dz_s0[z] - front
			if ahead <= 0.0:
				lim = minf(lim, vz)
				m = 1.0
			elif ahead < _drop_view:
				lim = minf(lim, sqrt(vz * vz + 2.0 * _pb[p] * ahead))
				if vi > vz:
					acc = minf(acc, _drop_brake(ahead, vz, vi, p))
	if (state.flags[i] & TrafficState.FLAG_SCRIPTED) != 0 or _split[i] != 0:
		m = 0.0
	_match[i] = m
	var v0e := v0 + (_drop_v_merge - v0) * m if v0 < _drop_v_merge else v0
	_q_v0 = v0e
	if lim < v0e:
		acc = minf(acc, Idm.free_accel(vi, lim, _pa[p], _pdl[p]))
	return acc


## Vehicle i is out of reach of every closure and drop zone (see _drop_tick).
func _clear_drop_cache(i: int) -> void:
	_cf_own[i] = INF
	_cf_left[i] = INF
	_cf_right[i] = INF
	_cf_base[i] = 0.0
	_cf_dist[i] = INF
	_match[i] = 0.0


## This step's reach of the closures and drop zones (_cl_lo.._cl_hi, _dz_lo.._dz_hi),
## so vehicles far from all of them skip _drop_tick's loops. Allocation-free.
func _update_drop_reach() -> void:
	_cl_lo = INF
	_cl_hi = -INF
	for c in _cl_n:
		_cl_lo = minf(_cl_lo, _cl_s0[c] - _cl_zone[c])
		_cl_hi = maxf(_cl_hi, _cl_s1[c])
	_dz_lo = INF
	_dz_hi = -INF
	for z in _dz_n:
		_dz_lo = minf(_dz_lo, _dz_s0[z] - _drop_view)
		_dz_hi = maxf(_dz_hi, _dz_s1[z] + _drop_release)


## WP6.8 zipper: vehicle i (rank k) beside a lane that closes within its merge zone
## eases off for the nearest car still in that lane ahead of it (within
## lane_drop_yield_range_m, its closure within lane_drop_yield_frac of its zone, not held,
## not splitting, not signaling away from i's lane): IDM behind it, but never braking
## harder than lane_drop_yield_decel_mps2 (or the profile's comfortable b, if lower), and
## only when falling back behind it at that rate is possible at all (dv^2 / 2(gap - s0)
## within it); otherwise i passes and the car merges behind. Beside it (its centre ahead
## of i's) and not slower, i always eases off. A car already MOVING is in i's lane and
## the leader search has it. INF: no yield. Allocation-free.
func _yield_accel(i: int, k: int, vi: float, v0: float, p: int, hw_t: float) -> float:
	if _cand_n == 0 or state.lc_state[i] == _MOVING or _cf_own[i] < 1.0:
		return INF   # (a car in a closing lane itself has to leave it)
	var cur := state.lane[i]
	var si := _ks[i]
	for c in _cand_n:
		var j := _cand[c]
		if _rank[j] <= k:
			continue
		if _ks[j] - si > _yield_range:
			break
		if absi(state.lane[j] - cur) != 1 or (state.lc_state[j] == _SIGNALING and state.target_lane[j] != cur):
			continue
		var gap := _ks[j] - si - _khl[j] - _khl[i]
		var dv := vi - _kv[j]
		var soft := minf(_yield_decel, _pb[p])
		if dv > 0.0 and (gap <= _ps0[p] or dv * dv > 2.0 * soft * (gap - _ps0[p])):
			return INF   # faster and too close to fall back comfortably: it merges behind i
		var ay := Idm.accel(vi, v0, gap, dv, _pa[p], _pb[p], hw_t, _ps0[p], _pdl[p], _gap_floor)
		return maxf(ay, -soft)
	return INF


## WP6.8: a lane drop's merge zone reaching back over a set piece's slow zone (a toll's
## booth lane just before a tunnel): its slow traffic keeps its lane (kept_by_zone) until
## it is back up to lane_drop_merge_floor_kmh (or within lane_drop_merge_floor_until_m of
## the closure), so booth traffic does not pull out into the express lane at booth speed,
## and nobody yields to it before that. Allocation-free.
func _zone_held(i: int) -> bool:
	return _sz_n > 0 and _kv[i] < _drop_floor and _cf_dist[i] > _drop_floor_until and kept_by_zone(i)


## WP6.8: this step's zipper candidates, in road order: vehicles (not the player) still
## in a lane that closes, in the last lane_drop_yield_frac of its merge zone (from their
## last model tick), not moving out yet, not held, not lane splitting, not hit.
## Allocation-free.
func _collect_yield_candidates() -> void:
	for k in _n:
		var j := _ord[k]
		if j == _P or _cf_own[j] >= _yield_frac or state.lc_state[j] == _MOVING or _hold[j] == 1 \
				or _split[j] != 0 or (state.flags[j] & TrafficState.FLAG_HIT) != 0 or _zone_held(j):
			continue
		_cand[_cand_n] = j
		_cand_n += 1


## WP6.8 zipper, the merging side: a vehicle still in a lane that a road drop ends
## within lane_drop_yield_frac of its merge zone (not yet moving out) lines up behind
## the nearest vehicle ahead of it in the lane it merges into: IDM behind it, braking no
## harder than lane_drop_yield_decel_mps2 (or its comfortable b). A vehicle beside it in
## that lane (overlapping along the road) and at least as fast has the right of way: it
## drops back at that rate until it is behind it (one slower than it is passed). So a car
## riding beside the target lane's traffic falls back into the gap behind it instead of
## running to the end of its lane (the car beside does not yield to it: _yield_accel).
## Not below lane_drop_merge_floor_kmh while more than lane_drop_merge_floor_until_m
## from the closure: a merging bus crawling behind car after car would be a slow wall;
## slower than that, the through lane's yield opens the gap. INF: nothing to line up
## behind. Allocation-free.
func _merge_gap_accel(i: int, k: int, vi: float, v0: float, p: int, hw_t: float) -> float:
	var st := state.lc_state[i]
	if st == _MOVING or _cf_own[i] >= _yield_frac or _cf_base[i] <= 0.0 \
			or (vi <= _drop_floor and _cf_dist[i] > _drop_floor_until) or _zone_held(i):
		return INF
	var cur := state.lane[i]
	var t := state.target_lane[i]
	if st != _SIGNALING:
		t = cur - 1
		if t < 0 or _cf_left[i] < 1.0:
			t = cur + 1
			if t >= road.lane_count(_ks[i]) or _cf_right[i] < 1.0:
				return INF
	var tc := _lane_d(t)
	var half := _lw * 0.5
	var si := _ks[i]
	var soft := minf(_yield_decel, _pb[p])
	var kb := k - 1
	while kb >= 0:
		var j := _ord[kb]
		kb -= 1
		if si - _ks[j] >= _khl[i] + _khl[j]:
			break
		if _klo[j] < tc + half and _khi[j] > tc - half and _kv[j] >= vi:
			return -soft   # beside it, and not slower: fall back behind it
	var kk := k + 1
	while kk < _n:
		var j := _ord[kk]
		kk += 1
		if _ks[j] - si > _yield_range:
			break
		if _klo[j] < tc + half and _khi[j] > tc - half:
			var gap := _ks[j] - si - _khl[j] - _khl[i]
			if gap <= 0.0 and _kv[j] < vi:
				continue   # a slower one beside it: passed
			var ay := Idm.accel(vi, v0, gap, vi - _kv[j], _pa[p], _pb[p], hw_t, _ps0[p], _pdl[p], _gap_floor)
			return maxf(ay, -soft)
	return INF


# ---------------------------------------------------------------- Tick

## Advances traffic by dt (called at 120 Hz after vehicle physics). `player` is the
## player's state this tick (a participant: a leader for cars behind it, a follower
## in MOBIL's safety check). Reactions go to out_events. Allocation-free.
func step(dt: float, player: VehicleState, _player_params: VehicleParams, out_events: ScoreEventBuffer) -> void:
	if _n_pending > 0:
		_emit_pending(out_events)
	_wclock += dt   # WP6.9: the lane-change cap's clock
	_read_player(player)
	_edge = road.lanes_left_edge_d(_ps)
	_lw = road.lane_width(_ps)
	# 1. Schedule (near / far) and integrate every vehicle over dt with the acceleration
	#    decided last model tick (far vehicles hold theirs between 30 Hz updates).
	var vmax := 0.0
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
		vmax = maxf(vmax, nv)
		if due == 0:
			var vl := state.v_lat[i]
			if vl != 0.0:
				state.d[i] += vl * dt
				_refresh_interval(i)
	_vmax = vmax
	if _cl_n > 0 or _dz_n > 0:
		_update_drop_reach()
	_sort()
	# 2. Model accelerations of the due vehicles, everyone (the player too) at the same
	#    instant: leaders, IDM, reactions, the clamp and the brake lights.
	_cand_n = 0
	if _cl_n > 0:
		_collect_yield_candidates()
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
	var p := state.profile_id[i]
	var front := si + _khl[i]
	var drop_a := INF
	if _cl_n > 0 or _dz_n > 0:
		if (front > _cl_lo and front <= _cl_hi) or (front > _dz_lo and front < _dz_hi):
			drop_a = _drop_tick(i, front, vi, v0, p)   # WP6.8: closures, drop zones, speed matching
			v0 = _q_v0
		elif _match[i] != 0.0 or _cf_own[i] != INF or _cf_left[i] != INF or _cf_right[i] != INF:
			_clear_drop_cache(i)
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
	var lead_k := kk
	var a: float
	var gap := INF
	var hw_t := _pT[p] if _hz_n == 0 else _pT[p] * headway_scale_at(si)   # WP6.3 headway zones
	if lead >= 0:
		gap = _ks[lead] - si - _khl[lead] - _khl[i]
		if _pweave[p] == 1 and lead != _P:
			# WP6.9: a weaving profile behind a traffic car (never behind the player).
			a = Idm.accel(vi, v0, gap, vi - _kv[lead], _pa[p], _wb[p], hw_t * _wTk[p], _ws0[p], _pdl[p], _gap_floor)
		else:
			a = Idm.accel(vi, v0, gap, vi - _kv[lead], _pa[p], _pb[p], hw_t, _ps0[p], _pdl[p], _gap_floor)
	else:
		a = Idm.free_accel(vi, v0, _pa[p], _pdl[p])
	# MP-D5: past a leader leaving the path, the next one counts too; and the leader's own
	# stopping point. The guards skip the calls (INF) for the common case: a leader in
	# lane, not braking (GDScript calls are the cost here).
	if _look_through and lead >= 0 and lead != _P and state.lc_state[lead] != _NONE:
		a = minf(a, _look_through_accel(i, lead, lead_k, lo, hi, false, vi, v0, p, hw_t))
	if _anticipate and lead >= 0 and ((lead != _P and state.accel[lead] < 0.0) or _kv[lead] <= 0.0):
		a = minf(a, _anticipation_accel(lead, gap, vi, p))
	if _cl_n > 0:
		a = minf(a, _closure_wall_accel(i, vi, v0, p))
	if _sz_n > 0:
		a = minf(a, _set_zone_accel(state.lane[i], front, vi, v0, p))   # WP6.3 speed zones
	a = minf(a, drop_a)   # WP6.8 drop zones
	if _cl_n > 0 and (state.flags[i] & (TrafficState.FLAG_SCRIPTED | TrafficState.FLAG_HIT)) == 0:
		if _cf_left[i] < 1.0 or _cf_right[i] < 1.0:
			a = minf(a, _yield_accel(i, k, vi, v0, p, hw_t))   # WP6.8 zipper: the through lane
		if _cf_own[i] < _yield_frac:
			a = minf(a, _merge_gap_accel(i, k, vi, v0, p, hw_t))   # WP6.8 zipper: the merging car
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
	elif (f & TrafficState.FLAG_HIT) == 0 and _cl_n > 0 and _hold[i] == 0 and _cf_own[i] < 1.0 \
			and not _zone_held(i):
		# Mandatory merge: every model tick within merge_zone_m of the closure, or a
		# MOBIL interval after a cancelled one; further out (a road drop's long zone,
		# WP6.8) at the profile's MOBIL interval.
		var mt := minf(_mobil_t[i], _peval[state.profile_id[i]]) - mdt
		if mt <= 0.0:
			_mobil_t[i] = 0.0 if _cf_dist[i] < _merge_zone else _peval[state.profile_id[i]]
			_consider_merge(i)
		else:
			_mobil_t[i] = mt
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
	# A signal started between ticks (request_lane_change) on a far vehicle: this model
	# dt also holds the time accumulated before the blinker came on (WP6.10).
	var timer := state.lc_timer[i] + mdt - _sig_pre[i]
	_sig_pre[i] = 0.0
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
		_mobil_t[i] = _cooldown_of(i)
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
	if _pweave[state.profile_id[i]] == 1:
		# WP6.9: weaving racers look ahead (and keep to their lane-change cap).
		if not _weave_cap_ok(i):
			return
		gl += _weave_bonus(i, cur - 1, cur)
		gr += _weave_bonus(i, cur + 1, cur)
		if gl > 0.0 or gr > 0.0:
			_weave_note_change(i)
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
	# Outside a model tick (a scripted request) a far vehicle may hold accumulated dt
	# from before the blinker; the next model tick must not count it (fairness rule 1).
	_sig_pre[i] = _acc_t[i]
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
	_mobil_t[i] = _cooldown_of(i)
	if _lc_split[i] == 0 and absf(state.d[i] - _lane_d(state.lane[i])) > _lw * 0.5 * 0.5:
		# A cancelled return from a lane split keeps riding the boundary.
		_split[i] = 1 if state.d[i] > _lane_d(state.lane[i]) else -1
	_lc_split[i] = 0
	_refresh_interval(i)


## MOBIL for a move of vehicle i into lane t. Returns -INF when the move is not allowed
## (lane, keep-right, overlap, safety or no-ambush), else the incentive minus the
## threshold (> 0 = MOBIL accepts), or 0 when with_incentive is false. `own_only` (a
## mandatory merge out of a road drop, WP6.8): the car's own advantage a~c - ac instead.
## Sets _q_player when the refusal involves the player.
func _eval_target(i: int, t: int, with_incentive: bool, own_only: bool = false) -> float:
	_q_player = false
	var lanes := road.lane_count(_ks[i])
	if t < 0 or t >= lanes:
		return -INF
	if _cl_n > 0 and _closes_soon(t, i):
		return -INF   # never into a lane that ends within merge_zone_m
	var krl := _pkrl[state.profile_id[i]]
	if krl > 0 and t < state.lane[i] and t < lanes - krl:
		return -INF
	return _eval_move(i, _lane_d(t), t, with_incentive, own_only)


## Safety (and optionally MOBIL's incentive) of a lateral move of vehicle i to tc,
## ending in lane t. Same result convention as _eval_target.
func _eval_move(i: int, tc: float, t: int, with_incentive: bool, own_only: bool = false) -> float:
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
	var lead_k := kk
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
	var k_foll := kk
	var v0 := state.v0[i]
	if v0 < _drop_v_merge and (_cl_n > 0 or _dz_n > 0) and _split[i] == 0:
		v0 += (_drop_v_merge - v0) * _match[i]   # WP6.8: as in _step_accel (its last model tick)
	var bsafe := _pbsafe[p] if _pweave[p] == 0 else _wbsafe[p]   # WP6.9: toward traffic followers
	var a_c_new: float
	if lead >= 0:
		var gl := _ks[lead] - si - _khl[lead] - _khl[i]
		if gl <= 0.0:
			_q_player = lead == _P
			return -INF
		if _pweave[p] == 1 and lead != _P:
			a_c_new = Idm.accel(vi, v0, gl, vi - _kv[lead], _pa[p], _wb[p], _pT[p] * _wTk[p], _ws0[p], _pdl[p],
				_gap_floor)   # WP6.9: its IDM toward traffic
		else:
			a_c_new = Idm.accel(vi, v0, gl, vi - _kv[lead], _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p], _gap_floor)
		if a_c_new < -(bsafe if lead != _P else _pbsafe[p]):
			_q_player = lead == _P
			return -INF
		if _look_through and lead != _P and state.lc_state[lead] != _NONE:
			# MP-D5: a new leader leaving the target lane hides nothing.
			var a2 := _look_through_accel(i, lead, lead_k, lo, hi, true, vi, v0, p, _pT[p])
			if a2 < -bsafe:
				return -INF
			a_c_new = minf(a_c_new, a2)
		if _predict_leaders and not _predicted_leaders_safe(i, lead, lead_k, lo, hi, vi, v0, p, bsafe):
			_q_player = lead == _P
			return -INF
	else:
		a_c_new = Idm.free_accel(vi, v0, _pa[p], _pdl[p])
	if _sz_n > 0 or _dz_n > 0:
		a_c_new = minf(a_c_new, _speed_zone_accel(t, i, vi, v0, p))   # WP6.3 / WP6.8: a slow zone in the target lane
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
		# WP6.8: every faster vehicle behind it on the target path that would reach the
		# gap within mobil_follower_horizon_s must be safe too: a lane-splitting bike, a
		# car changing lanes or the player (none of which shields the lane behind it the
		# way a car in it does: that one has to brake for it first) must not hide a fast
		# car behind it.
		var reach := (maxf(_vmax, _kv[_P]) - vi) * _foll_horizon
		kk = k_foll - 1
		if foll != _P and _split[foll] == 0 and state.lc_state[foll] == _NONE:
			kk = -1
		while kk >= 0:
			var j := _ord[kk]
			kk -= 1
			var gj := si - _ks[j] - _khl[i] - _khl[j]
			if gj > reach or si - _ks[j] > _look:
				break
			var vj := _kv[j]
			if vj <= vi or gj > (vj - vi) * _foll_horizon or not (_kclo[j] < hi and _kchi[j] > lo):
				continue
			if not Mobil.is_safe(_follower_accel(j, gj, vj - vi), Mobil.b_safe_for(bsafe, j == _P, _player_b_safe)):
				_q_player = j == _P
				return -INF
	# Fairness rule 2: no ambush.
	if NoAmbush.violates(si, vi, state.length[i], wi, tc, _ps, _pv, _pd, _pvl, _plen, _pw, _window, _margin):
		_q_player = true
		return -INF
	if not with_incentive:
		return 0.0
	if own_only:
		return a_c_new - _a_raw[i]
	var a_n := 0.0
	if foll >= 0:
		if lead >= 0:
			a_n = _follower_accel(foll, _ks[lead] - _ks[foll] - _khl[lead] - _khl[foll], _kv[foll] - _kv[lead],
				lead == _P)
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
			a_o_new = _follower_accel(of, _ks[ol] - _ks[of] - _khl[ol] - _khl[of], _kv[of] - _kv[ol], ol == _P)
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


# ---------------------------------------------------------------- Lane-drop queue safety (MP-D5, WP6.11)
# Ported from the server's sim crate (N4.1: westbound-server/crates/sim/src/traffic/sim.rs,
# look_through_accel / predicted_leaders_safe / anticipation_accel / leaving_path), which
# found them at the loop's rush-hour lane-drop queues. Flags: TrafficTuning's
# look_through_leaving_leaders, predict_leader_braking, anticipate_leader_braking.

## Look-through: while the leader `l` (at order position `lk`) is signalling or moving out
## of the path [lo, hi] (its target does not overlap it), the next vehicle on the path
## beyond it counts too: the most restrictive IDM acceleration of those (INF when `l`
## stays on the path; -INF when one of them already overlaps i). `claims`: match paths by
## claims (MOBIL's target lane) instead of physical intervals.
func _look_through_accel(i: int, l: int, lk: int, lo: float, hi: float, claims: bool, vi: float,
		v0: float, p: int, hw_t: float) -> float:
	var si := _ks[i]
	var a := INF
	var cur := l
	var kk := lk + 1
	while _leaving_path(cur, lo, hi):
		var nxt := -1
		while kk < _n:
			var j := _ord[kk]
			kk += 1
			if j == i or _ks[j] - si > _look:
				break
			var jlo := _kclo[j] if claims else _klo[j]
			var jhi := _kchi[j] if claims else _khi[j]
			if jlo < hi and jhi > lo:
				nxt = j
				break
		if nxt < 0:
			break
		var gap := _ks[nxt] - si - _khl[nxt] - _khl[i]
		if gap <= 0.0:
			return -INF
		if _pweave[p] == 1 and nxt != _P:
			# WP6.9: a weaving profile's IDM toward traffic, as toward any leader.
			a = minf(a, Idm.accel(vi, v0, gap, vi - _kv[nxt], _pa[p], _wb[p], hw_t * _wTk[p], _ws0[p], _pdl[p],
				_gap_floor))
		else:
			a = minf(a, Idm.accel(vi, v0, gap, vi - _kv[nxt], _pa[p], _pb[p], hw_t, _ps0[p], _pdl[p], _gap_floor))
		cur = nxt
	return a


## A braking new leader `l` (and, with look-through, the ones beyond it while they leave
## the path) extrapolated with its current deceleration to when the car is in the lane
## (signal + move_min / 2 seconds on), against the car holding its speed: the gap must stay
## open and the car's own IDM toward it (as in MOBIL's own-safety check) must not ask for
## more than b_safe. A leader that is not braking (the player holds its speed) is left to
## that check: extrapolating the car's approach alone refuses every gap it closes on (a
## racer 30 km/h faster, within its WP6.9 traffic b_safe).
func _predicted_leaders_safe(i: int, l: int, lk: int, lo: float, hi: float, vi: float, v0: float, p: int,
		bsafe: float) -> bool:
	var tau := _psig[p] + 0.5 * _pmmin[p]
	var si := _ks[i]
	var cur := l
	var kk := lk + 1
	while true:
		var al := 0.0 if cur == _P else state.accel[cur]
		if al < 0.0:
			var vl := _kv[cur]
			var vl_t := vl + al * tau
			var dl := (vl + vl_t) * 0.5 * tau
			if vl_t < 0.0:
				vl_t = 0.0
				dl = vl * vl / (-2.0 * al)
			var gap := _ks[cur] - si - _khl[cur] - _khl[i] + dl - vi * tau
			if gap <= 0.0:
				return false
			var a: float
			if _pweave[p] == 1:
				# WP6.9: a weaving profile's IDM toward traffic (a braking leader is traffic).
				a = Idm.accel(vi, v0, gap, vi - vl_t, _pa[p], _wb[p], _pT[p] * _wTk[p], _ws0[p], _pdl[p], _gap_floor)
			else:
				a = Idm.accel(vi, v0, gap, vi - vl_t, _pa[p], _pb[p], _pT[p], _ps0[p], _pdl[p], _gap_floor)
			if a < -bsafe:
				return false
		if not (_look_through and _leaving_path(cur, lo, hi)):
			return true
		var nxt := -1
		while kk < _n:
			var j := _ord[kk]
			kk += 1
			if j == i or _ks[j] - si > _look:
				break
			if _kclo[j] < hi and _kchi[j] > lo:
				nxt = j
				break
		if nxt < 0:
			return true
		cur = nxt
	return true


## The deceleration that stops a follower at vi (profile p) s0 behind where its leader
## `l`, `gap` ahead, stops at its current deceleration; applied only when it exceeds the
## comfortable b (an emergency IDM would react too late: a racer closing at 50 m/s on a
## car braking at the clamp into a queue). INF otherwise.
func _anticipation_accel(l: int, gap: float, vi: float, p: int) -> float:
	var vl := _kv[l]
	var al := 0.0 if l == _P else state.accel[l]
	var stop_l := 0.0
	if al < 0.0:
		stop_l = vl * vl / (-2.0 * al)
	elif vl > 0.0:
		return INF
	var room := gap - _ps0[p] + stop_l
	var a_stop := -(vi * vi) / (2.0 * room) if room > 0.0 else -INF
	return a_stop if a_stop < -_pb[p] else INF


## A vehicle signalling or moving to a target whose body does not overlap [lo, hi].
func _leaving_path(j: int, lo: float, hi: float) -> bool:
	if j == _P or state.lc_state[j] == _NONE:
		return false
	var hw := state.width[j] * 0.5
	var t := _lc_target_d[j]
	return not (t - hw < hi and t + hw > lo)


## IDM acceleration of follower f (slot or the player) at this gap / closing speed.
## The player is judged as holding its speed (interaction term only). `lead_is_player`:
## the leader is the player (a weaving follower then uses its ordinary IDM, WP6.9).
func _follower_accel(f: int, gap: float, dv: float, lead_is_player: bool = false) -> float:
	if f == _P:
		return Idm.interaction_accel(_kv[_P], gap, dv, _pl_a, _pl_b, _pl_T, _pl_s0, _gap_floor)
	var p := state.profile_id[f]
	if _pweave[p] == 1 and not lead_is_player:
		return Idm.accel(_kv[f], state.v0[f], gap, dv, _pa[p], _wb[p], _pT[p] * _wTk[p], _ws0[p], _pdl[p],
			_gap_floor)   # WP6.9: a weaving profile behind traffic
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
	_drop_zone = t.lane_drop_merge_zone_m
	_drop_urg_min = t.lane_drop_urgency_min_mps2
	_drop_slow = t.lane_drop_slow_zone_m
	_drop_after = t.lane_drop_slow_after_m
	_drop_v_through = Units.kmh_to_mps(t.lane_drop_through_kmh)
	_drop_v_merge = Units.kmh_to_mps(t.lane_drop_merge_lane_kmh)
	_yield_range = t.lane_drop_yield_range_m
	_yield_frac = t.lane_drop_yield_frac
	_yield_decel = t.lane_drop_yield_decel_mps2
	_foll_horizon = t.mobil_follower_horizon_s
	_drop_onset = t.lane_drop_brake_onset_frac
	_drop_view = t.lane_drop_view_m
	_drop_release = t.lane_drop_release_m
	_drop_floor = Units.kmh_to_mps(t.lane_drop_merge_floor_kmh)
	_drop_floor_until = t.lane_drop_merge_floor_until_m
	_drop_narrow_max = t.lane_drop_narrow_max_m
	_look_through = t.look_through_leaving_leaders
	_predict_leaders = t.predict_leader_braking
	_anticipate = t.anticipate_leader_braking


# ---------------------------------------------------------------- Racers weave harder (plan D17, WP6.9)
# Profiles with any DriverProfile "Weaving" field set (the racer) weave through traffic:
#   - toward a TRAFFIC leader they follow with their own T / s0 / b (_step_accel, and
#     wherever MOBIL predicts their IDM: _follower_accel);
#   - MOBIL's b_safe toward a TRAFFIC new follower (and for their own braking behind a
#     traffic new leader) is their own, never above the 6 m/s^2 clamp; the data keeps it
#     well below (the follower's braking can still grow a little after the cut-in:
#     RacerPassSurvey measures the hardest raw IDM braking a cut-in causes), so the car
#     they cut in front of never needs the clamp;
#   - lookahead lane choice: MOBIL's incentive gains lookahead_gain_per_s x (target
#     lane's pace - own lane's pace) within +-lookahead_incentive_max_mps2, a lane's pace
#     being the mean speed it could make there over lookahead_lane_choice_m (_weave_pace):
#     a racer boxed in behind slower traffic heads for the lane that is moving;
#   - their own cooldown, and at most lane_change_cap_count discretionary lane changes
#     started in any lane_change_cap_window_s (readability: no zig-zag).
# Toward the PLAYER nothing changes: behind the player the ordinary T / s0 / b (rear-end
# prevention), the player as new follower keeps player_b_safe_mps2 (min with theirs), the
# player as new leader the ordinary b_safe, no-ambush, the telegraphing (the profile's
# blinker, >= signal_time_floor_s). Allocation-free after _init.

## Longest lane-change cap a profile may ask for (per-slot ring size).
const WEAVE_CAP_MAX := 8

var _pweave := PackedByteArray()      # per profile: weaves (any weaving field set)
var _wTk := PackedFloat64Array()      # T toward traffic / T
var _ws0 := PackedFloat64Array()      # s0 toward traffic
var _wb := PackedFloat64Array()       # b toward traffic
var _wbsafe := PackedFloat64Array()   # b_safe toward traffic followers (<= the clamp)
var _wlook := PackedFloat64Array()    # lookahead distance (0 = off)
var _wgain := PackedFloat64Array()
var _wmax := PackedFloat64Array()
var _wcool := PackedFloat64Array()    # MOBIL cooldown after a lane change
var _wcap := PackedInt32Array()       # lane changes per window (0 = no cap)
var _wwin := PackedFloat64Array()
var _wclock := 0.0                    # sim time (s)
var _wvid := PackedInt32Array()       # per slot: the vehicle the ring below belongs to
var _wn := PackedInt32Array()         # per slot: lane changes noted
var _wt := PackedFloat64Array()       # per slot x WEAVE_CAP_MAX: their start times (ring)


func _init_weave(reg: TrafficRegistry) -> void:
	var n := reg.profile_count()
	_pweave.resize(n)
	_wTk.resize(n)
	_ws0.resize(n)
	_wb.resize(n)
	_wbsafe.resize(n)
	_wlook.resize(n)
	_wgain.resize(n)
	_wmax.resize(n)
	_wcool.resize(n)
	_wcap.resize(n)
	_wwin.resize(n)
	for p in n:
		var d := reg.profiles[p]
		var hw := d.idm_headway_vs_traffic_s
		_wTk[p] = hw / d.idm_headway_s if hw >= 0.0 and d.idm_headway_s > 0.0 else 1.0
		_ws0[p] = d.idm_s0_vs_traffic_m if d.idm_s0_vs_traffic_m >= 0.0 else _ps0[p]
		_wb[p] = d.idm_b_comfort_vs_traffic_mps2 if d.idm_b_comfort_vs_traffic_mps2 > 0.0 else _pb[p]
		var bs := d.mobil_b_safe_vs_traffic_mps2 if d.mobil_b_safe_vs_traffic_mps2 > 0.0 else _pbsafe[p]
		_wbsafe[p] = minf(bs, _max_decel)
		_wlook[p] = maxf(d.lookahead_lane_choice_m, 0.0)
		_wgain[p] = d.lookahead_gain_per_s
		_wmax[p] = d.lookahead_incentive_max_mps2
		_wcool[p] = d.lane_change_cooldown_s if d.lane_change_cooldown_s >= 0.0 else _cooldown
		_wcap[p] = clampi(d.lane_change_cap_count, 0, WEAVE_CAP_MAX)
		_wwin[p] = d.lane_change_cap_window_s
		var on := hw >= 0.0 or d.idm_s0_vs_traffic_m >= 0.0 or d.idm_b_comfort_vs_traffic_mps2 > 0.0 \
			or d.mobil_b_safe_vs_traffic_mps2 > 0.0 or _wlook[p] > 0.0 or d.lane_change_cooldown_s >= 0.0 \
			or _wcap[p] > 0
		_pweave[p] = 1 if on else 0
	_wvid.resize(_cap)
	_wvid.fill(-1)
	_wn.resize(_cap)
	_wt.resize(_cap * WEAVE_CAP_MAX)


## True when profile p weaves (any DriverProfile "Weaving" field set).
func weaves(p: int) -> bool:
	return _pweave[p] == 1


## b_safe a weaving profile p uses toward a traffic new follower (tests).
func weave_b_safe(p: int) -> float:
	return _wbsafe[p]


## The lookahead pace of lane `lane` for vehicle `slot` (m/s; _weave_pace with its
## profile's lookahead; its desired speed when the profile has none). Sandbox, tests.
func weave_lane_pace(slot: int, lane: int) -> float:
	var look := _wlook[state.profile_id[slot]]
	if look <= 0.0:
		return state.v0[slot]
	return _weave_pace(slot, _lane_d(lane), look)


## IDM of a weaving profile p behind a traffic car (its traffic T, s0 and b; the leg
## scale applies). Sandbox readout (MobilProbe).
func weave_idm_accel(p: int, v: float, v0: float, gap: float, dv: float) -> float:
	return Idm.accel(v, v0, gap, dv, _pa[p], _wb[p], _pT[p] * _wTk[p], _ws0[p], _pdl[p], _gap_floor)


## The lookahead term MOBIL adds for a discretionary move of `slot` into `lane`
## (_consider_lane_change). Sandbox readout (MobilProbe).
func weave_bonus(slot: int, lane: int) -> float:
	if _pweave[state.profile_id[slot]] == 0:
		return 0.0
	return _weave_bonus(slot, lane, state.lane[slot])


## MOBIL cooldown of vehicle i after a lane change (its profile's when it weaves).
func _cooldown_of(i: int) -> float:
	var p := state.profile_id[i]
	return _cooldown if _pweave[p] == 0 else _wcool[p]


## The lookahead term of a move of vehicle i from lane `cur` into lane t (0 when off, or
## t is not a lane; the move itself is judged by _eval_target, which it never overrides:
## -INF stays -INF).
func _weave_bonus(i: int, t: int, cur: int) -> float:
	var p := state.profile_id[i]
	var look := _wlook[p]
	if look <= 0.0 or t < 0 or t >= road.lane_count(_ks[i]):
		return 0.0
	var diff := _weave_pace(i, _lane_d(t), look) - _weave_pace(i, _lane_d(cur), look)
	return clampf(_wgain[p] * diff, -_wmax[p], _wmax[p])


## The pace of the lane centred at `c` ahead of vehicle i (m/s): the mean speed it can
## make there over the lookahead, H = look / its desired speed. Every vehicle j (the
## player included) whose path overlaps i's body there within `look` ahead bounds it:
## within H, i gets at most to its own following gap behind j, (gap_j + v_j H - (s0 +
## v_j T)) / H with its IDM toward traffic; its desired speed when nothing does. A slow
## car close ahead costs more than one far ahead, and a long gap beside a slow leader
## (room to get past it) is worth moving into. Allocation-free.
func _weave_pace(i: int, c: float, look: float) -> float:
	var p := state.profile_id[i]
	var hw := state.width[i] * 0.5
	var lo := c - hw - _lat_m
	var hi := c + hw + _lat_m
	var si := _ks[i]
	var v0 := state.v0[i]
	var h := look / v0
	var t_gap := _pT[p] * _wTk[p]
	var pace := v0
	var kk := _rank[i] + 1
	while kk < _n:
		var j := _ord[kk]
		kk += 1
		if _ks[j] - si > look:
			break
		if _klo[j] < hi and _khi[j] > lo:
			var vj := _kv[j]
			var gap := _ks[j] - si - _khl[j] - _khl[i]
			pace = minf(pace, maxf(gap + vj * h - _ws0[p] - vj * t_gap, 0.0) / h)
	return pace


## Vehicle i may start another discretionary lane change (its cap allows it).
func _weave_cap_ok(i: int) -> bool:
	var p := state.profile_id[i]
	var cap := _wcap[p]
	if cap <= 0:
		return true
	if _wvid[i] != state.vehicle_id[i]:
		_wvid[i] = state.vehicle_id[i]
		_wn[i] = 0
	var n := _wn[i]
	if n < cap:
		return true
	# The cap-th most recent change must be at least the window ago.
	return _wclock - _wt[i * WEAVE_CAP_MAX + (n - cap) % WEAVE_CAP_MAX] >= _wwin[p]


## Notes that vehicle i may be starting a discretionary lane change now (called when
## MOBIL accepts a side; a move later refused still counts, conservatively).
func _weave_note_change(i: int) -> void:
	if _wcap[state.profile_id[i]] <= 0:
		return
	if _wvid[i] != state.vehicle_id[i]:
		_wvid[i] = state.vehicle_id[i]
		_wn[i] = 0
	_wt[i * WEAVE_CAP_MAX + _wn[i] % WEAVE_CAP_MAX] = _wclock
	_wn[i] += 1
