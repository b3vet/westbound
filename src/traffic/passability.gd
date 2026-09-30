class_name Passability
extends RefCounted
# lint: sim
## Passability guarantee. Spec: Traffic → Passability guarantee ("forward-simulate
## traffic at 10 Hz for 8 s; search player moves over a grid of lateral positions (lane
## centers and half-lanes) in 0.25 s steps, limited by the player car's real
## lane-change capability at its current speed; speed anywhere from minimum speed to
## current speed plus possible acceleration; require a path that stays at or above
## minimum speed and never comes within 0.3 m of a hull"; "the same module runs in
## tests with a bot driver"); Fairness rules; Traffic sandbox (the paths overlay).
## Algorithm, costs and the director's use: docs/PASSABILITY.md.
##
##   var pass := Passability.new(run.tuning, registry, road)
##   pass.set_player_body(car.length_m, car.width_m)
##   var res := Passability.Result.new()
##   pass.check_player(traffic, player, params, road, res)          # the player's own window
##   pass.set_planned(batch)                                         # director: a planned batch
##   pass.check(traffic, player, params, road, s_from, s_to, res)   # ... passable on arrival?
##   pass.begin_check(...); while not pass.advance(1): ...           # the same, time-sliced
##
## 1. Forward simulation. A lightweight step rather than a TrafficSim instance (the full
##    model costs ~5 µs per vehicle and step in GDScript, 2-3x this one). The vehicles
##    that can matter are copied (the published TrafficState is only read) into private
##    structure-of-arrays storage and stepped at sim_hz for horizon_s with the real
##    models: IDM (Idm's formula with each profile's parameters, the D11 headway scale,
##    the 6 m/s^2 clamp, hit braking, the lane-split speed cap) on the leader found by
##    lateral overlap like TrafficSim; running lane changes continue their smoothstep; a
##    signaled one is assumed to happen at the end of its signal time and to take the
##    profile's longest move time, occupying both lanes throughout (a cancel only frees
##    space). Traffic yields to the player as in the game: in the player check the
##    player is a participant on a nominal trajectory (its lane, its speed): cars behind
##    it follow it (IDM with the player as leader) and a signaled lane change into its
##    predicted space is cancelled (NoAmbush.violates, fairness rule 2). New MOBIL
##    decisions are not predicted: their timing is the live sim's own, and no-ambush
##    keeps them out of the player's predicted space. The batch check has no
##    participant (the player is not there yet).
## 2. Search, time-expanded over decision steps of step_s. Lateral states: the grid
##    positions (lane centers and half-lanes), the stages of a half-lane move (it takes
##    VehicleParams.move_time(v, half lane) rounded up to whole steps: the capability
##    curve; a moving car occupies both positions), and one start state per position in
##    which the vehicles following the player in that lane are exempt until it first
##    moves sideways (they brake for it: rear-end prevention). The car may take any speed
##    in [minimum speed, current speed + full-throttle acceleration] at any moment (the
##    spec's range; a player already below the minimum speed may hold its speed).
##    Obstacles are the predicted bodies grown by clearance_m (the visual body, not the
##    8 cm inset hull: conservative) plus the chord deviation of a decelerating vehicle
##    within one step. Within a step both the player and an obstacle move on straight
##    lines in (t, s), so a move is collision-free exactly when the player is on the same
##    side of the obstacle at both ends: no tunnelling at any speed. Sets of s are
##    interval lists per lateral state.
##    - Player check: backward from the horizon, G_k(x) = every s from which a valid
##      path exists; passable when the player's state is in G_0. The path is extracted
##      greedily through G (the bot re-extracts it with its own preferences).
##    - Batch check: a batch is planned ~750 m ahead, beyond what the player reaches in
##      8 s, so it is checked for a player *arriving* at it. The minimum speed only
##      bites behind vehicles slower than it: for each one V in the batch (or just
##      before it), a probe puts the arriving player anywhere in any free lane of the
##      stretch behind V from which even the minimum speed reaches V within the
##      horizon, at the player's current speed (at least the minimum); the probe passes
##      when some of those starts keeps a path to the horizon (forward reachable sets),
##      the batch when every probe passes. A wall across every lane fails; one open lane
##      passes.
## 3. Results: passable or not; the path found (sandbox overlay, bot driver); on
##    failure, how much path space each obstacle cut (forward sets from the failing
##    starts), for the director's "remove the vehicle that blocks the most paths".
##
## 4. Lanes that end (WP6.2 lane drops, tapers): where the right edge of the driving
##    lanes (RoadPath.lanes_right_edge_d, sampled) leaves a grid position's body outside,
##    a static road obstacle blocks that position and every one right of it. Lanes the
##    traffic sim closes (WP6.3 road works, a merge zone's lane end: `zones`) block the
##    positions overlapping them the same way. Road obstacles are never leaders for
##    traffic and never removable (Result.blocker_src = SRC_ROAD). The sim's speed zones
##    (a toll's booth lanes) cap the predicted vehicles' desired speed there.
##
## Pure and deterministic (RefCounted, no Node, no randomness). Allocation-free per
## check after _init (preallocated structure-of-arrays storage).

const MAX_LANES := 5
const MAX_POS := 2 * MAX_LANES - 1
## A half-lane move may take at most this many decision steps (capability curve).
const MAX_MOVE_STEPS := 8
## Regular states (positions + move stages), then one start state per position.
const MAX_REG := MAX_POS + (MAX_POS - 1) * (MAX_MOVE_STEPS - 1)
const MAX_STATES := MAX_REG + MAX_POS
## Occupancies: single positions, adjacent pairs (a move), start positions (followers exempt).
const MAX_OCC := 3 * MAX_POS - 1
## Intervals per lateral state and step (an overflow drops the new interval: conservative).
const MAX_IV := 24
const MAX_SUCC := 3
const MAX_PRED := 5
## Vehicles the forward simulation holds (live ones near the corridor + a planned batch).
const MAX_VEHICLES := 160
const MAX_PLANNED := 96
const MAX_PROBES := 48
## Result.blocker_src of a road obstacle (a lane that ends).
const SRC_ROAD := -(1 << 30)
## Sampling step of the lane edge for lane ends (a closure is widened by one step at both
## ends); lane counts are compared this far apart first (no change: no closures).
const CLOSURE_SAMPLE_M := 5.0   # lint: allow-number geometry sampling resolution, not gameplay
const CLOSURE_SCAN_M := 50.0    # lint: allow-number shorter than any lane taper or lane-count stretch
## Room kept for road obstacles in the vehicle storage.
const MAX_STATIC := 2 * MAX_POS
## Relevance entries per obstacle and step: at most 3 positions, 4 pairs, 3 starts.
const REL_PER_OBSTACLE := 10
## Substeps for integrating the full-throttle speed envelope over one decision step.
const ACCEL_SUBSTEPS := 8
## Chord deviation of a trajectory with constant acceleration a over dt: a dt^2 / 8.
const CHORD_FACTOR := 0.125   # lint: allow-number 1/8, parabola vs its chord
## Rounding guard when a move time is a whole number of steps.
const STEP_EPS := 1e-9   # lint: allow-number float rounding guard
## Work per slice of a time-sliced check: forward-simulation steps, relevance steps,
## backward steps, probes.
const PREDICT_SLICE := 20
const RELEVANCE_SLICE := 8
const BACKWARD_SLICE := 8
const PROBE_SLICE := 1
## advance() argument for "the whole check".
const ALL_SLICES := 1 << 20

const MODE_PLAYER := 0
const MODE_ARRIVAL := 1
## The spec's IDM exponent (every profile), computed as two squarings.
const IDM_DELTA_4 := 4

enum Phase { IDLE, PREDICT, OBSTACLES, RELEVANCE, START, BACKWARD, PROBES, FINISH, DONE }

const _NONE := TrafficState.LaneChange.NONE
const _SIGNALING := TrafficState.LaneChange.SIGNALING
const _MOVING := TrafficState.LaneChange.MOVING
const _SMOOTH_A := 3.0   # lint: allow-number smoothstep polynomial coefficient


## What one check found. Allocate one per caller and reuse it.
class Result:
	var passable := true
	var mode := MODE_PLAYER
	## Seconds into the horizon at which the last path from the failing start ended
	## (INF = passable).
	var fail_t := INF
	## Batch check: probes run and failed; s of the first failing probe.
	var probes := 0
	var failed_probes := 0
	var fail_s := NAN
	## Vehicles simulated, obstacles searched, lateral positions, half-move steps, steps.
	var vehicles := 0
	var obstacles := 0
	var positions := 0
	var move_steps := 0
	var steps := 0
	## Per obstacle: the vehicle (a TrafficState slot >= 0, or -(k + 1) for planned record
	## k) and, after a failure, the path space it cut (m, summed over steps).
	var blocker_src := PackedInt32Array()
	var blocker_cut := PackedFloat64Array()
	## The path found (the player's, or one arrival path for a batch): path_n points at
	## t = k * step_s; path_state = the lateral state (Passability.state_d()).
	var path_n := 0
	var path_s := PackedFloat64Array()
	var path_d := PackedFloat64Array()
	var path_state := PackedInt32Array()
	## Interval-list overflows (dropped intervals; should stay 0).
	var overflows := 0

	func _init() -> void:
		blocker_src.resize(MAX_VEHICLES)
		blocker_cut.resize(MAX_VEHICLES)

	## Index of the obstacle with the largest cut among those `removable` accepts (a
	## Callable(src: int) -> bool), or -1. Director rate.
	func worst_blocker(removable: Callable) -> int:
		var best := -1
		var best_cut := 0.0
		for o in obstacles:
			if blocker_cut[o] > best_cut and bool(removable.call(blocker_src[o])):
				best = o
				best_cut = blocker_cut[o]
		return best

	## Copies the path of `o` (allocation-free once sized).
	func copy_path_from(o: Result) -> void:
		if path_s.size() < o.path_n:
			path_s.resize(o.path_n)
			path_d.resize(o.path_n)
			path_state.resize(o.path_n)
		path_n = o.path_n
		for k in o.path_n:
			path_s[k] = o.path_s[k]
			path_d[k] = o.path_d[k]
			path_state[k] = o.path_state[k]


var tuning: Tuning
var registry: TrafficRegistry
var road: RoadPath

var _pt: PassabilityTuning
var _k_steps: int            ## decision steps in the horizon
var _sim_steps: int          ## forward-simulation steps in the horizon
var _sim_dt: float
var _sim_per_step: float     ## forward-simulation steps per decision step
var _min_speed: float
var _pad: float
var _slow_margin: float
var _plen := 0.0
var _pw := 0.0

# Traffic model constants (SI) and per-profile IDM parameters.
var _max_decel: float
var _scripted_decel: float
var _look: float
var _gap_floor: float
var _lat_m: float
var _hit_recover: float
var _hit_decel: float
var _hit_brake_s: float
var _split_v0: float
var _split_clear: float
var _window: float
var _margin: float
var _pa := PackedFloat64Array()
var _pb := PackedFloat64Array()
var _pT := PackedFloat64Array()
var _ps0 := PackedFloat64Array()
var _pdl := PackedInt32Array()
var _psq := PackedFloat64Array()     ## 2 sqrt(a b) per profile (IDM's s* term)
var _pmove := PackedFloat64Array()

# Planned records (director batch), references only.
var _planned: Array[SpawnSource.Record] = []
var _n_planned := 0

# The check in progress.
var _phase := Phase.IDLE
var _mode := MODE_PLAYER
var _out: Result
var _m := 0                  ## forward-simulation steps done
var _kb := 0                 ## next backward step
var _pi := 0                 ## next probe
var _with_player := false
var _start_x := -1
var _start_pair := -1
var _start_stage := 0
var _start_mask := 0         ## start positions in use (their start states have lists)
var _x_a := -1
var _x_b := -1
var _reach := PackedByteArray()      ## player check: state x reachable (laterally) at step k: [k * MAX_STATES + x]
var _s_lo := 0.0
var _s_hi := 0.0
var _s_from := 0.0
var _s_to := 0.0
var _p_s := 0.0              ## player at t0
var _p_d := 0.0
var _p_v := 0.0

# Vehicles (private copy): index q < _n_veh
var _n_veh := 0
var _n_move := 0              ## simulated vehicles [0, _n_move); road obstacles after them
var _cl_a := PackedFloat64Array()     ## per position: start of the closure being scanned (NAN: open)
var _sz_on := false          ## speed zones live (zones): the predictor caps v0 in them
var _left_d := 0.0           ## lanes' left edge and lane width at the reference s
var _lane_w := 0.0
var _vs := PackedFloat64Array()
var _vv := PackedFloat64Array()
var _vd := PackedFloat64Array()
var _va := PackedFloat64Array()
var _vv0 := PackedFloat64Array()
var _vlen := PackedFloat64Array()
var _vw := PackedFloat64Array()
var _vp := PackedInt32Array()
var _vsrc := PackedInt32Array()
var _vlim := PackedFloat64Array()     ## deceleration clamp
var _vhit := PackedFloat64Array()     ## hit recovery timer (> 0 recovering)
var _vsplit := PackedByteArray()      ## a bike riding a lane boundary
var _vst := PackedInt32Array()        ## lane change: NONE / SIGNALING / MOVING
var _vt := PackedFloat64Array()       ## time in state
var _vdur := PackedFloat64Array()     ## signal or move time
var _vd0 := PackedFloat64Array()      ## smoothstep origin
var _vd1 := PackedFloat64Array()      ## lateral target
var _vwide := PackedByteArray()       ## a predicted move: occupies both lanes throughout
var _vlat := PackedByteArray()        ## lateral activity in the horizon (else its extents are constant)
var _vlo := PackedFloat64Array()      ## body (lateral), both lanes during a predicted move
var _vhi := PackedFloat64Array()
var _vplo := PackedFloat64Array()     ## physical interval for leaders (moving: to the target)
var _vphi := PackedFloat64Array()
var _vord := PackedInt32Array()       ## by s
var _v_start0 := PackedFloat64Array() ## speed at t0 (probes)
# Samples at every forward-simulation step: [m * MAX_VEHICLES + q]
var _fs_s := PackedFloat64Array()
var _fs_lo := PackedFloat64Array()
var _fs_hi := PackedFloat64Array()

# Obstacles: the vehicles whose hull can meet the corridor
var _n_obs := 0
var _oq := PackedInt32Array()
var _oh := PackedFloat64Array()      ## longitudinal half extent (player + body + clearance + pad)
var _oc := PackedFloat64Array()      ## center s at t_k: [o * (K + 1) + k]
var _oj0 := PackedInt32Array()       ## blocked grid positions during step k: [o * K + k]
var _oj1 := PackedInt32Array()
var _oin := PackedByteArray()        ## the hull meets the corridor during step k: [o * K + k]
var _odl := PackedFloat64Array()     ## body lateral extents at t0
var _odh := PackedFloat64Array()
var _order := PackedInt32Array()
var _exempt := PackedInt32Array()    ## per obstacle: bits of the start positions it follows

# Relevance lists per (step, occupancy), sorted by hull start at t_{k+1}.
var _rel_start := PackedInt32Array()     ## [k * MAX_OCC + occ]
var _rel_n := PackedInt32Array()
var _rel_o := PackedInt32Array()         ## pool
var _rel_lo1 := PackedFloat64Array()     ## hull at t_{k+1}
var _rel_hi1 := PackedFloat64Array()
var _rel_pre := PackedFloat64Array()     ## prefix max of (center at t_k + h)
var _rel_suf := PackedFloat64Array()     ## suffix min of (center at t_k - h)
var _rel_used := 0
var _rel_regular := 0                    ## pool size before the start lists
# The same lists sorted by hull start at t_k, with the prefix max of (center at t_{k+1}
# + h) and the suffix min of (center at t_{k+1} - h) and the obstacles attaining them
# (forward sets: probes, failure analysis). Same layout as the _rel_ pool.
var _frel_o := PackedInt32Array()
var _frel_lo0 := PackedFloat64Array()
var _frel_hi0 := PackedFloat64Array()
var _frel_pre := PackedFloat64Array()
var _frel_pre_o := PackedInt32Array()
var _frel_suf := PackedFloat64Array()
var _frel_suf_o := PackedInt32Array()
var _kr := 0                             ## next relevance step

# Grid and lateral states
var _n_pos := 0
var _n_mv := 1
var _n_reg := 0
var _n_states := 0
var _n_occ := 0
var _occ_start := 0          ## first start occupancy
var _pos_d := PackedFloat64Array()
var _grid := 0.0
var _d_first := 0.0
var _state_d := PackedFloat64Array()     ## d of each state (a move stage: interpolated)
var _state_pos := PackedInt32Array()     ## position of a settled state, -1 mid-move
var _succ := PackedInt32Array()
var _succ_occ := PackedInt32Array()
var _succ_n := PackedInt32Array()
var _pred := PackedInt32Array()
var _pred_occ := PackedInt32Array()
var _pred_n := PackedInt32Array()

# Longitudinal envelope per step
var _dmin := PackedFloat64Array()
var _dmax := PackedFloat64Array()
var _cum_min := PackedFloat64Array()     ## [k] cumulative
var _cum_max := PackedFloat64Array()
var _corr_lo := PackedFloat64Array()     ## [k]
var _corr_hi := PackedFloat64Array()
var _v_lo := 0.0
var _v_start := 0.0

# Probes (batch check)
var _n_probes := 0
var _probe_s := PackedFloat64Array()     ## start window [probe_s - probe_w, probe_s]
var _probe_w := PackedFloat64Array()
var _probe_ok := PackedByteArray()
var _probe_lo := 0.0
var _probe_hi := 0.0
var _cut := PackedFloat64Array()         ## path space cut per obstacle (one forward pass)
## Batch check: also extract one arrival path (the sandbox overlay). Off in the game.
var record_paths := false
## The traffic sim's lane closures and speed zones (WP6.3), read when set: anything with
## lane_closure_count(), closure_ahead(lane, s), speed_zone_count() and
## speed_limit_at(lane, front, profile) (TrafficSim); anything else is ignored (null).
## Read only.
var zones: Object:
	set(v):
		zones = v if v != null and v.has_method(&"lane_closure_count") and v.has_method(&"closure_ahead") \
			and v.has_method(&"speed_zone_count") and v.has_method(&"speed_limit_at") else null

# Sets per step: G_k(x) (backward) or R_k(x) (forward, stored): [(k * MAX_STATES + x) * MAX_IV + q]
var _glo := PackedFloat64Array()
var _ghi := PackedFloat64Array()
var _gn := PackedInt32Array()

# Forward sets (double-buffered) and scratch
var _alo := PackedFloat64Array()
var _ahi := PackedFloat64Array()
var _an := PackedInt32Array()
var _blo := PackedFloat64Array()
var _bhi := PackedFloat64Array()
var _bn := PackedInt32Array()
var _plo := PackedFloat64Array()   ## pieces of one state (backward), unsorted
var _phi := PackedFloat64Array()
var _overflows := 0


func _init(t: Tuning, reg: TrafficRegistry, road_path: RoadPath) -> void:
	tuning = t
	registry = reg
	road = road_path
	_pt = t.passability
	var tt := t.traffic
	_min_speed = t.scoring.min_speed_mps()
	_k_steps = roundi(_pt.horizon_s / _pt.step_s)
	_sim_dt = 1.0 / float(_pt.sim_hz)
	_sim_steps = roundi(_pt.horizon_s * float(_pt.sim_hz))
	_sim_per_step = _pt.step_s * float(_pt.sim_hz)
	_max_decel = tt.max_decel_mps2
	_scripted_decel = maxf(tt.scripted_max_decel_mps2, tt.max_decel_mps2)
	_pad = _scripted_decel * _pt.step_s * _pt.step_s * CHORD_FACTOR
	_slow_margin = Units.kmh_to_mps(_pt.arrival_slow_margin_kmh)
	_look = tt.idm_lookahead_m
	_gap_floor = tt.idm_gap_floor_m
	_lat_m = tt.lateral_margin_m
	_hit_recover = tt.hit_recover_s
	_hit_decel = tt.hit_brake_decel_mps2
	_hit_brake_s = tt.hit_brake_s
	_split_v0 = Units.kmh_to_mps(tt.lane_split_max_speed_kmh)
	_split_clear = tt.lane_split_clearance_m
	_window = tt.no_ambush_window_s
	_margin = tt.no_ambush_margin_m
	_pa = reg.a_max.duplicate()
	_pb = reg.b_comfort.duplicate()
	_pT = reg.headway.duplicate()
	_ps0 = reg.s0.duplicate()
	_pdl = reg.delta.duplicate()
	_pmove = reg.move_max_s.duplicate()
	_psq.resize(_pa.size())
	for p in _pa.size():
		_psq[p] = 2.0 * sqrt(_pa[p] * _pb[p])
	_planned.resize(MAX_PLANNED)

	var k1 := _k_steps + 1
	var nv := MAX_VEHICLES
	_vs.resize(nv)
	_vv.resize(nv)
	_vd.resize(nv)
	_va.resize(nv)
	_vv0.resize(nv)
	_vlen.resize(nv)
	_vw.resize(nv)
	_vlim.resize(nv)
	_vhit.resize(nv)
	_vt.resize(nv)
	_vdur.resize(nv)
	_vd0.resize(nv)
	_vd1.resize(nv)
	_vlo.resize(nv)
	_vhi.resize(nv)
	_vplo.resize(nv)
	_vphi.resize(nv)
	_v_start0.resize(nv)
	_oh.resize(nv)
	_odl.resize(nv)
	_odh.resize(nv)
	_vp.resize(nv)
	_vsrc.resize(nv)
	_vst.resize(nv)
	_vord.resize(nv)
	_oq.resize(nv)
	_order.resize(nv)
	_exempt.resize(nv)
	_vsplit.resize(nv)
	_vwide.resize(nv)
	_vlat.resize(nv)
	_fs_s.resize((_sim_steps + 1) * nv)
	_fs_lo.resize((_sim_steps + 1) * nv)
	_fs_hi.resize((_sim_steps + 1) * nv)
	_oc.resize(nv * k1)
	_oj0.resize(nv * _k_steps)
	_oj1.resize(nv * _k_steps)
	_oin.resize(nv * _k_steps)
	_rel_start.resize(_k_steps * MAX_OCC)
	_rel_n.resize(_k_steps * MAX_OCC)
	var pool := _k_steps * nv * REL_PER_OBSTACLE
	_rel_lo1.resize(pool)
	_rel_hi1.resize(pool)
	_rel_pre.resize(pool)
	_rel_suf.resize(pool)
	_rel_o.resize(pool)
	_frel_o.resize(pool)
	_frel_lo0.resize(pool)
	_frel_hi0.resize(pool)
	_frel_pre.resize(pool)
	_frel_pre_o.resize(pool)
	_frel_suf.resize(pool)
	_frel_suf_o.resize(pool)
	_cut.resize(nv)
	_probe_ok.resize(MAX_PROBES)
	_pos_d.resize(MAX_POS)
	_cl_a.resize(MAX_POS)
	_state_d.resize(MAX_STATES)
	_state_pos.resize(MAX_STATES)
	_succ.resize(MAX_STATES * MAX_SUCC)
	_succ_occ.resize(MAX_STATES * MAX_SUCC)
	_succ_n.resize(MAX_STATES)
	_pred.resize(MAX_STATES * MAX_PRED)
	_pred_occ.resize(MAX_STATES * MAX_PRED)
	_pred_n.resize(MAX_STATES)
	_dmin.resize(_k_steps)
	_dmax.resize(_k_steps)
	_cum_min.resize(k1)
	_cum_max.resize(k1)
	_corr_lo.resize(k1)
	_corr_hi.resize(k1)
	_probe_s.resize(MAX_PROBES)
	_probe_w.resize(MAX_PROBES)
	_glo.resize(k1 * MAX_STATES * MAX_IV)
	_ghi.resize(k1 * MAX_STATES * MAX_IV)
	_gn.resize(k1 * MAX_STATES)
	_reach.resize(k1 * MAX_STATES)
	_alo.resize(MAX_STATES * MAX_IV)
	_ahi.resize(MAX_STATES * MAX_IV)
	_blo.resize(MAX_STATES * MAX_IV)
	_bhi.resize(MAX_STATES * MAX_IV)
	_an.resize(MAX_STATES)
	_bn.resize(MAX_STATES)
	_plo.resize(MAX_SUCC * MAX_IV * MAX_VEHICLES)
	_phi.resize(MAX_SUCC * MAX_IV * MAX_VEHICLES)


## The player's body (CarDef.length_m / width_m). Until set: TrafficTuning's player box.
func set_player_body(length_m: float, width_m: float) -> void:
	_plen = length_m
	_pw = width_m


## The IDM headway scale the live sim uses (plan D11, TrafficSim.set_headway_scale).
func set_headway_scale(k: float) -> void:
	for p in _pT.size():
		_pT[p] = registry.headway[p] * k


## A batch planned but not committed: included in the next checks as if spawned at its
## records. References are kept until clear_planned(). Director rate.
func set_planned(recs: Array[SpawnSource.Record]) -> void:
	_n_planned = mini(recs.size(), MAX_PLANNED)
	for k in _n_planned:
		_planned[k] = recs[k]


func clear_planned() -> void:
	_n_planned = 0


## Decision steps in the horizon (a path has steps() + 1 points).
func steps() -> int:
	return _k_steps


func step_s() -> float:
	return _pt.step_s


## Lateral d of state x in the last check (a move stage lies between its positions).
func state_d(x: int) -> float:
	return _state_d[x]


## Position index of a settled state (start states included), -1 for a move stage.
func state_position(x: int) -> int:
	return _state_pos[x]


## Half-lane move duration in steps, lateral positions and their d (last check).
func move_steps() -> int:
	return _n_mv


func position_count() -> int:
	return _n_pos


func position_d(j: int) -> float:
	return _pos_d[j]


## The state of a move between positions p and p + 1 after `stage` steps (1 ..
## move_steps() - 1), in the grid of the last check.
func move_state(p: int, stage: int) -> int:
	return _n_pos + p * (_n_mv - 1) + stage - 1


## The start state of position j (the followers in its lane are exempt until the
## player first moves sideways).
func start_state(j: int) -> int:
	return _n_reg + j


## The pair (lower position) of a move stage, or -1 for a settled state.
func state_pair(x: int) -> int:
	if x < _n_pos or x >= _n_reg:
		return -1
	return floori(float(x - _n_pos) / float(maxi(_n_mv - 1, 1)))


## Steps already done in a move stage (1 .. move_steps() - 1), 0 for a settled state.
func state_stage(x: int) -> int:
	if x < _n_pos or x >= _n_reg:
		return 0
	return (x - _n_pos) % maxi(_n_mv - 1, 1) + 1


# ---------------------------------------------------------------- Checks

## The player's own window: is there a path from where the player is now? The start
## can be pinned: `start_pos` = a grid position (its start state is used), or
## `start_pair` / `start_stage` = a half-lane move between positions p and p + 1 with
## that many steps done (a bot mid-move; clamped to this check's move duration). By
## default the player starts at the positions bracketing player.d. Fills `out` (the
## path included). Synchronous.
func check_player(traffic: TrafficState, player: VehicleState, params: VehicleParams, road_path: RoadPath,
		out: Result, start_pos: int = -1, start_pair: int = -1, start_stage: int = 0) -> bool:
	_start_pair = start_pair
	_start_stage = start_stage
	begin_check(traffic, player, params, road_path, MODE_PLAYER, player.s, player.s, out, start_pos)
	while not advance(ALL_SLICES):
		pass
	return out.passable


## A batch [s_from, s_to) (its records set with set_planned) checked for a player
## arriving at it. Fills `out`; on failure, the blocker cuts. Synchronous.
func check(traffic: TrafficState, player: VehicleState, params: VehicleParams, road_path: RoadPath,
		s_from: float, s_to: float, out: Result) -> bool:
	begin_check(traffic, player, params, road_path, MODE_ARRIVAL, s_from, s_to, out)
	while not advance(ALL_SLICES):
		pass
	return out.passable


## Starts a check (the traffic is copied now); advance() does the work in slices.
## MODE_PLAYER: s_from / s_to are ignored (the player's s). MODE_ARRIVAL: the batch.
func begin_check(traffic: TrafficState, player: VehicleState, params: VehicleParams, road_path: RoadPath,
		mode: int, s_from: float, s_to: float, out: Result, start_x: int = -1) -> void:
	if mode != MODE_PLAYER:
		_start_pair = -1
	road = road_path
	_out = out
	_mode = mode
	_start_x = start_x
	_with_player = mode == MODE_PLAYER
	_p_s = player.s
	_p_d = player.d
	_p_v = maxf(player.v, 0.0)
	_s_from = s_from
	_s_to = s_to
	_prepare(params)
	_n_probes = 0
	if mode == MODE_PLAYER:
		_s_lo = player.s
		_s_hi = player.s
	else:
		_find_probes(traffic)
		if _n_probes == 0:
			# Nothing slower than the minimum speed: every arrival keeps its lane's pace.
			_out.passable = true
			_phase = Phase.DONE
			return
		_s_lo = _probe_lo
		_s_hi = _probe_hi
	_set_corridor(_s_lo, _s_hi)
	_load(traffic)
	_m = 0
	_phase = Phase.PREDICT


## True while a begun check has not finished.
func is_busy() -> bool:
	return _phase != Phase.IDLE and _phase != Phase.DONE


## Does up to `slices` slices of the begun check (ALL_SLICES: all of it).
## Returns true when the check is complete (the result is in the Result given to
## begin_check). A slice is PREDICT_SLICE forward-simulation steps, the obstacles,
## RELEVANCE_SLICE steps of relevance lists, the start, BACKWARD_SLICE backward steps,
## PROBE_SLICE probes, or the evaluation.
func advance(slices: int) -> bool:
	var n := 0
	while n < slices and _phase != Phase.DONE and _phase != Phase.IDLE:
		match _phase:
			Phase.PREDICT:
				var to := mini(_m + PREDICT_SLICE, _sim_steps)
				_predict(_m, to)
				_m = to
				if _m >= _sim_steps:
					_phase = Phase.OBSTACLES
			Phase.OBSTACLES:
				_build_obstacles()
				_kr = 0
				_rel_used = 0
				_phase = Phase.RELEVANCE
			Phase.RELEVANCE:
				var to_k := mini(_kr + RELEVANCE_SLICE, _k_steps)
				_build_relevance(_kr, to_k)
				_kr = to_k
				if _kr >= _k_steps:
					_rel_regular = _rel_used
					_phase = Phase.START
			Phase.START:
				_start_search()
			Phase.BACKWARD:
				var stop := maxi(_kb - BACKWARD_SLICE, 0)
				_backward(_kb, stop)
				_kb = stop
				if _kb <= 0:
					_phase = Phase.FINISH
			Phase.PROBES:
				var last := mini(_pi + PROBE_SLICE, _n_probes)
				while _pi < last:
					_run_probe(_pi)
					_pi += 1
				if _pi >= _n_probes:
					_phase = Phase.FINISH
			Phase.FINISH:
				if _mode == MODE_PLAYER:
					_finish_player()
				else:
					_finish_arrival()
				_out.overflows = _overflows
				_phase = Phase.DONE
		n += 1
	return _phase == Phase.DONE


## Re-extracts the path of the last player check with a driver's preferences: from
## state x0 at s0 (it must have a path), a preferred speed and lateral target, the
## current speed (speed changes kept within the traffic's comfortable clamp when
## possible), and a time headway kept to what lies ahead when the good set allows
## (0: just the clearance). Returns false when (x0, s0) has no path. For the bot driver.
func extract_path(out: Result, x0: int, s0: float, v_pref: float, d_pref: float, v_now: float,
		headway_s: float = 0.0) -> bool:
	if _mode != MODE_PLAYER or not _g_contains(0, x0, s0):
		return false
	_extract(out, x0, s0, v_pref, d_pref, v_now, headway_s)
	return true


## True when (x, s) at decision step k of the last player check has a path.
func has_path_from(k: int, x: int, s: float) -> bool:
	return _mode == MODE_PLAYER and _g_contains(k, x, s)


func _start_search() -> void:
	_out.probes = _n_probes
	_out.failed_probes = 0
	_out.fail_s = NAN
	_out.passable = true
	for o in _n_obs:
		_out.blocker_src[o] = _vsrc[_oq[o]]
		_out.blocker_cut[o] = 0.0
	if _mode == MODE_PLAYER:
		_player_starts()
		_lateral_reach()
		_set_exempt(_p_s)
		_build_start_lists(_start_mask)
		_init_backward()
		_phase = Phase.BACKWARD
	else:
		for k in _k_steps:
			for occ in _occ_start:
				_forward_list(k * MAX_OCC + occ, k)
		_pi = 0
		_phase = Phase.PROBES


## The player check's start states (_x_a, _x_b; equal when pinned) and the start
## positions in use (_start_mask).
func _player_starts() -> void:
	var x_a := _start_x
	var x_b := _start_x
	if _start_x < 0 and _start_pair >= 0 and _start_pair < _n_pos - 1:
		if _n_mv > 1:
			x_a = move_state(_start_pair, clampi(_start_stage, 1, _n_mv - 1))
			x_b = x_a
		else:
			x_a = _start_pair
			x_b = _start_pair + 1
	elif _start_x < 0:
		var f := clampf((_p_d - _d_first) / _grid, 0.0, float(_n_pos - 1))
		x_a = floori(f)
		x_b = ceili(f)
	_start_mask = 0
	if x_a >= 0 and x_a < _n_pos:
		_start_mask |= 1 << x_a
		x_a = _n_reg + x_a
	if x_b >= 0 and x_b < _n_pos:
		_start_mask |= 1 << x_b
		x_b = _n_reg + x_b
	_x_a = x_a
	_x_b = x_b


## The states the player can be in at each step, ignoring obstacles (the state graph
## from the start states): the backward pass skips the others.
func _lateral_reach() -> void:
	for x in _n_states:
		_reach[x] = 1 if x == _x_a or x == _x_b else 0
	for k in _k_steps:
		var b0 := k * MAX_STATES
		var b1 := b0 + MAX_STATES
		for x in _n_states:
			_reach[b1 + x] = 0
		for x in _n_states:
			if _reach[b0 + x] == 1:
				for e in _succ_n[x]:
					_reach[b1 + _succ[x * MAX_SUCC + e]] = 1


func _finish_player() -> void:
	var out := _out
	out.passable = false
	out.fail_t = INF
	var s0 := _p_s
	var x_a := _x_a
	var x_b := _x_b
	var x := x_a if _g_contains(0, x_a, s0) else (x_b if _g_contains(0, x_b, s0) else -1)
	if x >= 0:
		out.passable = true
		_extract(out, x, s0, _p_v, _state_d[x], _p_v)
		return
	out.path_n = 0
	for k in _k_steps:
		for occ in _n_occ:
			if occ < _occ_start or (_start_mask >> (occ - _occ_start)) & 1 == 1:
				_forward_list(k * MAX_OCC + occ, k)
	_an.fill(0)
	if x_a >= 0 and x_a < _n_states:
		_an[x_a] = _iv_add_to(_alo, _ahi, x_a * MAX_IV, 0, s0, s0)
	if x_b >= 0 and x_b < _n_states and x_b != x_a:
		_an[x_b] = _iv_add_to(_alo, _ahi, x_b * MAX_IV, 0, s0, s0)
	out.fail_t = _forward(false)
	for o in _n_obs:
		out.blocker_cut[o] = _cut[o]


func _finish_arrival() -> void:
	var out := _out
	out.passable = out.failed_probes == 0
	out.path_n = 0
	if not record_paths:
		return
	# One arrival path for the overlay: the passing probe nearest the batch start.
	var best := -1
	for p in _n_probes:
		if _probe_ok[p] == 1 and (best < 0 or absf(_probe_s[p] - _s_from) < absf(_probe_s[best] - _s_from)):
			best = p
	if best >= 0 and _start_probe(best):
		_forward(true)
		_backtrack(out)


# ---------------------------------------------------------------- Setup

func _prepare(params: VehicleParams) -> void:
	_overflows = 0
	var out := _out
	out.mode = _mode
	out.obstacles = 0
	out.path_n = 0
	out.probes = 0
	out.failed_probes = 0
	out.fail_t = INF
	var s_ref := _p_s if _mode == MODE_PLAYER else _s_from
	var lw := road.lane_width(s_ref)
	_lane_w = lw
	_left_d = road.lanes_left_edge_d(s_ref)
	# A lane still tapering away at s_ref is on the grid (its closure blocks it).
	var edge_lanes := ceili((road.lanes_right_edge_d(s_ref) - road.lanes_left_edge_d(s_ref)) / lw - STEP_EPS)
	var lanes := clampi(maxi(road.lane_count(s_ref), edge_lanes), 1, MAX_LANES)
	_grid = _pt.lateral_step_lanes * lw
	_d_first = road.lane_center_d(0, s_ref)
	var d_last := road.lane_center_d(lanes - 1, s_ref)
	_n_pos = clampi(roundi((d_last - _d_first) / _grid) + 1, 1, MAX_POS)
	for j in _n_pos:
		_pos_d[j] = _d_first + float(j) * _grid
	# Speeds: [minimum speed, current + full-throttle acceleration]; a player already
	# below the minimum speed may hold its speed. Arrivals come at the minimum at least.
	if _mode == MODE_ARRIVAL:
		_v_lo = _min_speed
		_v_start = maxf(_p_v, _min_speed)
	else:
		_v_lo = minf(_min_speed, _p_v)
		_v_start = _p_v
	var step := _pt.step_s
	var vh := _v_start
	var h := step / float(ACCEL_SUBSTEPS)
	_cum_min[0] = 0.0
	_cum_max[0] = 0.0
	for k in _k_steps:
		_dmin[k] = _v_lo * step
		var dist := 0.0
		for m in ACCEL_SUBSTEPS:
			var a := maxf(VehiclePhysics.engine_accel(params, vh) - params.rolling_mps2
				- params.drag_per_m * vh * vh, 0.0)
			var nv := vh + a * h
			dist += (vh + nv) * 0.5 * h
			vh = nv
		_dmax[k] = maxf(dist, _dmin[k])
		_cum_min[k + 1] = _cum_min[k] + _dmin[k]
		_cum_max[k + 1] = _cum_max[k] + _dmax[k]
	# Lateral capability: a half-lane move at the current speed, in whole steps.
	var mt := params.move_time(maxf(_v_start, _v_lo), _grid)
	_n_mv = clampi(ceili(mt / step - STEP_EPS), 1, MAX_MOVE_STEPS)
	_build_states()
	out.positions = _n_pos
	out.move_steps = _n_mv
	out.steps = _k_steps


## Corridor: where the player can be at each step, starting anywhere in [lo, hi].
func _set_corridor(lo: float, hi: float) -> void:
	for k in _k_steps + 1:
		_corr_lo[k] = lo + _cum_min[k]
		_corr_hi[k] = hi + _cum_max[k]


## States: positions 0..n_pos-1, move stages (pair p, stage 1..n_mv-1), start states.
## Occupancies: position j = j; pair p = n_pos + p; start position j = occ_start + j.
func _build_states() -> void:
	var stages := _n_mv - 1
	_n_reg = _n_pos + (_n_pos - 1) * stages
	_n_states = _n_reg + _n_pos
	_occ_start = 2 * _n_pos - 1
	_n_occ = _occ_start + _n_pos
	for x in _n_states:
		_pred_n[x] = 0
	for j in _n_pos:
		for start in 2:
			var x := j if start == 0 else _n_reg + j
			_state_d[x] = _pos_d[j]
			_state_pos[x] = j
			_link(x, 0, x, j if start == 0 else _occ_start + j)
			var n := 1
			for side in 2:
				var p := j - 1 + side
				if p < 0 or p >= _n_pos - 1:
					continue
				var to := _n_pos + p * stages
				if stages == 0:
					to = p + 1 if p == j else p
				_link(x, n, to, _n_pos + p)
				n += 1
			_succ_n[x] = n
	for p in _n_pos - 1:
		for m in stages:
			var x := _n_pos + p * stages + m
			var u := float(m + 1) / float(_n_mv)
			_state_d[x] = _pos_d[p] + (_pos_d[p + 1] - _pos_d[p]) * u * u * (_SMOOTH_A - 2.0 * u)
			_state_pos[x] = -1
			if m + 1 < stages:
				_link(x, 0, x + 1, _n_pos + p)
				_succ_n[x] = 1
			else:
				_link(x, 0, p, _n_pos + p)
				_link(x, 1, p + 1, _n_pos + p)
				_succ_n[x] = 2


func _link(x: int, e: int, to: int, occ: int) -> void:
	_succ[x * MAX_SUCC + e] = to
	_succ_occ[x * MAX_SUCC + e] = occ
	var i := _pred_n[to]
	_pred[to * MAX_PRED + i] = x
	_pred_occ[to * MAX_PRED + i] = occ
	_pred_n[to] = i + 1


func _player_length() -> float:
	return _plen if _plen > 0.0 else tuning.traffic.player_length_m


func _player_width() -> float:
	return _pw if _pw > 0.0 else tuning.traffic.player_width_m


# ---------------------------------------------------------------- Forward simulation

## Copies the vehicles that can matter: those whose hull can meet the corridor within
## the horizon (a car behind at up to its desired speed catching a player at the
## minimum speed), plus leader context (leader_margin_m) beyond it; then the planned
## batch. Rebuilds each car's lane-change target from the published state.
func _load(traffic: TrafficState) -> void:
	var plen := _player_length()
	var lo0 := _corr_lo[0]
	var hi_k := _corr_hi[_k_steps] + _pt.leader_margin_m
	var horizon := _pt.horizon_s
	_n_veh = 0
	for i in traffic.capacity:
		if traffic.active[i] == 0:
			continue
		var h := (traffic.length[i] + plen) * 0.5 + _pt.clearance_m
		var s := traffic.s[i]
		if s - h > hi_k:
			continue
		if s + h + maxf(0.0, maxf(traffic.v[i], traffic.v0[i]) - _v_lo) * horizon < lo0:
			continue
		if _n_veh >= MAX_VEHICLES - MAX_STATIC:
			break
		_load_live(traffic, i, _n_veh)
		_n_veh += 1
	for k in _n_planned:
		if _n_veh >= MAX_VEHICLES - MAX_STATIC:
			break
		_load_planned(_planned[k], k, _n_veh)
		_n_veh += 1
	_n_move = _n_veh
	_load_closures()
	_load_lane_closures()
	_sz_on = zones != null and int(zones.call(&"speed_zone_count")) > 0
	for q in _n_veh:
		_vord[q] = q
		_v_start0[q] = _vv[q]
		_vlat[q] = 0 if _vst[q] == _NONE else 1
		_refresh_lateral(q)
		_fs_s[q] = _vs[q]
		_fs_lo[q] = _vlo[q]
		_fs_hi[q] = _vhi[q]
	for q in range(_n_move, _n_veh):
		_vplo[q] = INF   # never a leader for traffic
		_vphi[q] = -INF
	_out.vehicles = _n_move


## Lanes that end within the corridor: per grid position, the stretches where the
## player's body there would leave the driving lanes (the right edge sampled every
## CLOSURE_SAMPLE_M, one sample wider at both ends) become static road obstacles
## blocking that position and every position right of it. No lane-count change and no
## taper in the corridor (the common case): nothing to do.
func _load_closures() -> void:
	var lo := _corr_lo[0] - _player_length()
	var hi := _corr_hi[_k_steps] + _player_length()
	var lanes := road.lane_count(lo)
	var uniform := absf(road.lanes_right_edge_d(lo) - road.lane_center_d(lanes - 1, lo)
		- road.lane_width(lo) * 0.5) < STEP_EPS
	var s := lo
	while uniform and s < hi:
		s = minf(s + CLOSURE_SCAN_M, hi)
		uniform = road.lane_count(s) == lanes
	if uniform:
		return
	var hw := _player_width() * 0.5
	for j in _n_pos:
		_cl_a[j] = NAN
	var n := ceili((hi - lo) / CLOSURE_SAMPLE_M)
	for i in n + 1:
		var si := lo + float(i) * CLOSURE_SAMPLE_M
		var edge := road.lanes_right_edge_d(si)
		for j in _n_pos:
			var closed := _pos_d[j] + hw > edge
			if closed and is_nan(_cl_a[j]):
				_cl_a[j] = si - CLOSURE_SAMPLE_M
			elif not closed and not is_nan(_cl_a[j]):
				_add_closure(j, _cl_a[j], si)
				_cl_a[j] = NAN
	for j in _n_pos:
		if not is_nan(_cl_a[j]):
			_add_closure(j, _cl_a[j], hi + CLOSURE_SAMPLE_M)


## A static road obstacle over [a, b] blocking grid position j and every one right of it:
## from half a grid step left of where position j's player body (with the clearance)
## would touch it, to beyond the last position.
func _add_closure(j: int, a: float, b: float) -> void:
	_add_static(a, b, _pos_d[j] + _player_width() * 0.5 + _pt.clearance_m - _grid * 0.5,
		_pos_d[_n_pos - 1] + _grid)


## The sim's lane closures (zones) within the corridor: each closed stretch of a grid
## lane blocks the positions whose player body would overlap that lane (its center and
## both half-lanes). The start is exact (closure_ahead), the end sampled every
## CLOSURE_SAMPLE_M (one sample later: conservative).
func _load_lane_closures() -> void:
	if zones == null or int(zones.call(&"lane_closure_count")) == 0:
		return
	var lo := _corr_lo[0] - _player_length()
	var hi := _corr_hi[_k_steps] + _player_length()
	var clr := _pt.clearance_m
	for lane in (_n_pos + 1) >> 1:
		var c := _d_first + float(lane) * _lane_w
		var s := lo + float(zones.call(&"closure_ahead", lane, lo))
		while s <= hi:
			var b := s
			while b <= hi and float(zones.call(&"closure_ahead", lane, b)) <= 0.0:
				b += CLOSURE_SAMPLE_M
			_add_static(s, b, c - _lane_w * 0.5 + clr, c + _lane_w * 0.5 - clr)
			s = b + float(zones.call(&"closure_ahead", lane, b))


## A static road obstacle: body [a, b] in s, [d_lo, d_hi] laterally.
func _add_static(a: float, b: float, d_lo: float, d_hi: float) -> void:
	if _n_veh >= MAX_VEHICLES:
		_overflows += 1
		return
	var q := _n_veh
	var lo := d_lo
	var hi := d_hi
	_vs[q] = (a + b) * 0.5
	_vv[q] = 0.0
	_vd[q] = (lo + hi) * 0.5
	_va[q] = 0.0
	_vv0[q] = 1.0
	_vlen[q] = b - a
	_vw[q] = hi - lo
	_vp[q] = 0
	_vsrc[q] = SRC_ROAD
	_vlim[q] = _max_decel
	_vhit[q] = 0.0
	_vst[q] = _NONE
	_vt[q] = 0.0
	_vdur[q] = 0.0
	_vd0[q] = _vd[q]
	_vd1[q] = _vd[q]
	_vwide[q] = 0
	_vsplit[q] = 0
	_n_veh += 1


func _load_live(ts: TrafficState, i: int, q: int) -> void:
	var s := ts.s[i]
	var d := ts.d[i]
	var lane := ts.lane[i]
	var f := ts.flags[i]
	_vs[q] = s
	_vv[q] = ts.v[i]
	_vd[q] = d
	_va[q] = ts.accel[i]
	_vv0[q] = ts.v0[i]
	_vlen[q] = ts.length[i]
	_vw[q] = ts.width[i]
	_vp[q] = ts.profile_id[i]
	_vsrc[q] = i
	_vlim[q] = _scripted_decel if (f & TrafficState.FLAG_SCRIPTED) != 0 else _max_decel
	_vhit[q] = ts.react_timer[i] if (f & TrafficState.FLAG_HIT) != 0 else 0.0
	var st := ts.lc_state[i]
	_vst[q] = st
	_vt[q] = ts.lc_timer[i]
	_vdur[q] = ts.lc_duration[i]
	_vd0[q] = ts.lc_start_d[i]
	_vd1[q] = d
	_vwide[q] = 0
	_vsplit[q] = 0
	# The lateral target is the live sim's own bookkeeping: rebuilt from the published
	# state (a lane change ends on a lane center; a split entry on the boundary its
	# blinker points to; a return from a split on its lane center).
	var center := road.lane_center_d(lane, s)
	var quarter := road.lane_width(s) * 0.5 * 0.5
	if st == _NONE:
		if absf(d - center) > quarter:
			_vsplit[q] = 1
	elif ts.target_lane[i] != lane:
		_vd1[q] = road.lane_center_d(ts.target_lane[i], s)
	else:
		var from_d := ts.lc_start_d[i] if st == _MOVING else d
		if absf(from_d - center) > quarter:
			_vd1[q] = center
		else:
			var side := -1.0 if (f & TrafficState.FLAG_BLINKER_LEFT) != 0 else 1.0
			_vd1[q] = center + side * quarter * 2.0


func _load_planned(rec: SpawnSource.Record, k: int, q: int) -> void:
	var p := rec.profile_id
	_vs[q] = rec.s
	_vv[q] = rec.v
	_vd[q] = road.lane_center_d(rec.lane, rec.s) if is_nan(rec.d) else rec.d
	_va[q] = 0.0
	_vv0[q] = rec.v0 if rec.v0 > 0.0 else (registry.v0_min[p] + registry.v0_max[p]) * 0.5
	_vlen[q] = registry.length[rec.type_id]
	_vw[q] = registry.width[rec.type_id]
	_vp[q] = p
	_vsrc[q] = -(k + 1)
	_vlim[q] = _scripted_decel if (rec.flags & TrafficState.FLAG_SCRIPTED) != 0 else _max_decel
	_vhit[q] = 0.0
	_vst[q] = _NONE
	_vt[q] = 0.0
	_vdur[q] = 0.0
	_vd0[q] = _vd[q]
	_vd1[q] = _vd[q]
	_vwide[q] = 0
	_vsplit[q] = 0


## Body extents (both lanes during a predicted move) and the physical interval for
## leaders (TrafficSim: while moving, the whole span from the body to the target).
func _refresh_lateral(q: int) -> void:
	var hw := _vw[q] * 0.5
	var d := _vd[q]
	var lo := d - hw
	var hi := d + hw
	if _vwide[q] == 1:
		lo = minf(_vd0[q], _vd1[q]) - hw
		hi = maxf(_vd0[q], _vd1[q]) + hw
	_vlo[q] = lo
	_vhi[q] = hi
	if _vst[q] == _MOVING:
		lo = minf(lo, _vd1[q] - hw)
		hi = maxf(hi, _vd1[q] + hw)
	_vplo[q] = lo
	_vphi[q] = hi


## Forward-simulation steps [m_from, m_to): integrate with last step's acceleration,
## lateral moves, then new IDM accelerations (TrafficSim's order); record every body.
func _predict(m_from: int, m_to: int) -> void:
	var dt := _sim_dt
	var n := _n_veh
	var pw := _player_width()
	var plen := _player_length()
	# The player as a leader: its body at t0 only. TrafficSim also stretches it by the
	# player's lateral velocity (player_lateral_anticipation_s), but whether that lasts
	# depends on the path taken: assuming it would predict followers braking that a
	# reversed move never earns (optimistic), so it is left out (conservative).
	var p_lo := _p_d - pw * 0.5
	var p_hi := _p_d + pw * 0.5
	var look := _look
	var floor_gap := _gap_floor
	for m in range(m_from, m_to):
		var ps := _p_s + _p_v * dt * float(m + 1)
		# 1. Integrate; lateral state machines (road obstacles stay put).
		for q in _n_move:
			var a := _va[q]
			var v := _vv[q]
			var nv := v + a * dt
			if nv < 0.0:
				if a < 0.0:
					_vs[q] -= v * v / (2.0 * a)
				nv = 0.0
			else:
				_vs[q] += (v + nv) * 0.5 * dt
			_vv[q] = nv
			if _vhit[q] > 0.0:
				_vhit[q] = maxf(_vhit[q] - dt, 0.0)
			var st := _vst[q]
			if st == _NONE:
				continue
			var t := _vt[q] + dt
			_vt[q] = t
			if st == _SIGNALING:
				if _with_player and NoAmbush.violates(_vs[q], nv, _vlen[q], _vw[q], _vd1[q], ps, _p_v, _p_d, 0.0,
						plen, pw, _window, _margin):
					_vst[q] = _NONE   # fairness rule 2: the player is in the target space
				elif t >= _vdur[q]:
					_vst[q] = _MOVING
					_vt[q] = 0.0
					_vd0[q] = _vd[q]
					_vdur[q] = _pmove[_vp[q]]
					_vwide[q] = 1
			else:
				var dur := _vdur[q]
				if t >= dur:
					_vd[q] = _vd1[q]
					_vst[q] = _NONE
					_vwide[q] = 0
				else:
					var u := t / dur
					_vd[q] = _vd0[q] + (_vd1[q] - _vd0[q]) * u * u * (_SMOOTH_A - 2.0 * u)
			_refresh_lateral(q)
		# 2. Order by s (nearly sorted: insertion sort).
		for r in range(1, n):
			var x := _vord[r]
			var sx := _vs[x]
			var k := r - 1
			while k >= 0 and _vs[_vord[k]] > sx:
				_vord[k + 1] = _vord[k]
				k -= 1
			_vord[k + 1] = x
		# 3. IDM on the leader found by lateral overlap (the player included).
		for r in n:
			var q := _vord[r]
			if q >= _n_move:
				continue
			var s := _vs[q]
			var v := _vv[q]
			var v0 := _vv0[q]
			var mg := _lat_m
			if _vsplit[q] == 1:
				v0 = minf(v0, _split_v0)
				mg = _split_clear
			if _sz_on:
				var zl := floori((_vd[q] - _left_d) / _lane_w)
				v0 = minf(v0, float(zones.call(&"speed_limit_at", zl, s + _vlen[q] * 0.5, _vp[q])))
			var lo := _vplo[q] - mg
			var hi := _vphi[q] + mg
			var gap := INF
			var vl := 0.0
			var hl := _vlen[q] * 0.5
			for rr in range(r + 1, n):
				var j := _vord[rr]
				var sj := _vs[j]
				if sj - s > look:
					break
				if _vplo[j] < hi and _vphi[j] > lo:
					gap = sj - s - _vlen[j] * 0.5 - hl
					vl = _vv[j]
					break
			if _with_player and ps > s and p_lo < hi and p_hi > lo:
				var gp := ps - s - plen * 0.5 - hl
				if gp < gap:
					gap = gp
					vl = _p_v
			var p := _vp[q]
			# IDM (Idm.accel), inlined: a [1 - (v/v0)^delta - (s*/s)^2].
			var x := v / v0
			var pw4 := 1.0
			var e := _pdl[p]
			if e == IDM_DELTA_4:
				x *= x
				pw4 = x * x
			else:
				while e > 0:
					pw4 *= x
					e -= 1
			var a := 1.0 - pw4
			if gap < INF:
				var ss := _ps0[p] + maxf(0.0, v * _pT[p] + v * (v - vl) / _psq[p])
				var rr2 := ss / maxf(gap, floor_gap)
				a -= rr2 * rr2
			a *= _pa[p]
			if _vhit[q] > 0.0 and _hit_recover - _vhit[q] < _hit_brake_s:
				a = minf(a, -_hit_decel)
			_va[q] = maxf(a, -_vlim[q])
		# 4. Record (lateral extents only for the vehicles that move sideways).
		var base := (m + 1) * MAX_VEHICLES
		for q in n:
			_fs_s[base + q] = _vs[q]
			if _vlat[q] == 1:
				_fs_lo[base + q] = _vlo[q]
				_fs_hi[base + q] = _vhi[q]


# ---------------------------------------------------------------- Obstacles

## Obstacles: the simulated vehicles whose hull meets the corridor at some step, with
## their centers at every decision time and the grid positions they block during every
## step.
func _build_obstacles() -> void:
	var plen := _player_length()
	var hw_p := _player_width() * 0.5 + _pt.clearance_m
	var k1 := _k_steps + 1
	var n := 0
	var sps := _sim_per_step
	for q in _n_veh:
		var o := n
		var h := (_vlen[q] + plen) * 0.5 + _pt.clearance_m + _pad
		var relevant := false
		var ob := o * k1
		for k in k1:
			var t := float(k) * sps
			var m0 := mini(floori(t), _sim_steps)
			var m1 := mini(m0 + 1, _sim_steps)
			var c0 := _fs_s[m0 * MAX_VEHICLES + q]
			var c := c0 + (_fs_s[m1 * MAX_VEHICLES + q] - c0) * (t - float(m0))
			_oc[ob + k] = c
			if not relevant and c + h >= _corr_lo[k] and c - h <= _corr_hi[k]:
				relevant = true
		if not relevant:
			continue
		_oq[o] = q
		_oh[o] = h
		_odl[o] = _fs_lo[q]
		_odh[o] = _fs_hi[q]
		var j0 := maxi(floori((_fs_lo[q] - hw_p - _d_first) / _grid) + 1, 0)
		var j1 := mini(ceili((_fs_hi[q] + hw_p - _d_first) / _grid) - 1, _n_pos - 1)
		for k in _k_steps:
			if _vlat[q] == 1:
				var ma := floori(float(k) * sps)
				var mb := mini(ceili(float(k + 1) * sps), _sim_steps)
				var dlo := INF
				var dhi := -INF
				for m in range(ma, mb + 1):
					dlo = minf(dlo, _fs_lo[m * MAX_VEHICLES + q])
					dhi = maxf(dhi, _fs_hi[m * MAX_VEHICLES + q])
				j0 = maxi(floori((dlo - hw_p - _d_first) / _grid) + 1, 0)
				j1 = mini(ceili((dhi + hw_p - _d_first) / _grid) - 1, _n_pos - 1)
			_oj0[o * _k_steps + k] = j0
			_oj1[o * _k_steps + k] = j1
		n += 1
	_n_obs = n
	_out.obstacles = n


## Steps [k_from, k_to), per occupancy (positions and pairs): the obstacles that matter (lateral
## overlap during the step, hull within the corridor), sorted by hull start at the
## step's end, with the prefix max of (center + h) and the suffix min of (center - h)
## at the step's start.
func _build_relevance(k_from: int, k_to: int) -> void:
	var k1 := _k_steps + 1
	if k_from == 0:
		for o in _n_obs:
			_order[o] = o
	for k in range(k_from, k_to):
		# Insertion sort by hull start at t_{k+1} (nearly sorted from the last step).
		for q in range(1, _n_obs):
			var x := _order[q]
			var key := _oc[x * k1 + k + 1] - _oh[x]
			var r := q - 1
			while r >= 0 and _oc[_order[r] * k1 + k + 1] - _oh[_order[r]] > key:
				_order[r + 1] = _order[r]
				r -= 1
			_order[r + 1] = x
		var c_lo := _corr_lo[k]
		var c_hi := _corr_hi[k + 1]
		var base_k := k * MAX_OCC
		for occ in _occ_start:
			_rel_n[base_k + occ] = 0
		# Count per occupancy, then lay the lists out and fill them in hull order.
		for q in _n_obs:
			var o := _order[q]
			var ok := o * _k_steps + k
			var j0 := _oj0[ok]
			var j1 := _oj1[ok]
			if j0 > j1:
				continue
			var a := _oc[o * k1 + k]
			var b := _oc[o * k1 + k + 1]
			if maxf(a, b) + _oh[o] < c_lo or minf(a, b) - _oh[o] > c_hi:
				_oin[ok] = 0   # outside the corridor this step: skipped below too
				continue
			_oin[ok] = 1
			for j in range(j0, j1 + 1):
				_rel_n[base_k + j] += 1
			for p in range(maxi(j0 - 1, 0), mini(j1, _n_pos - 2) + 1):
				_rel_n[base_k + _n_pos + p] += 1
		for occ in _occ_start:
			_rel_start[base_k + occ] = _rel_used
			_rel_used += _rel_n[base_k + occ]
			_rel_n[base_k + occ] = 0
		for q in _n_obs:
			var o := _order[q]
			var ok := o * _k_steps + k
			var j0 := _oj0[ok]
			var j1 := _oj1[ok]
			if j0 > j1 or _oin[ok] == 0:
				continue
			var c1 := _oc[o * k1 + k + 1]
			var h := _oh[o]
			for j in range(j0, j1 + 1):
				_rel_push(base_k + j, o, c1, h)
			for p in range(maxi(j0 - 1, 0), mini(j1, _n_pos - 2) + 1):
				_rel_push(base_k + _n_pos + p, o, c1, h)
		for occ in _occ_start:
			_rel_bounds(base_k + occ, k)


func _rel_push(key: int, o: int, c1: float, h: float) -> void:
	var idx := _rel_start[key] + _rel_n[key]
	_rel_o[idx] = o
	_rel_lo1[idx] = c1 - h
	_rel_hi1[idx] = c1 + h
	_rel_n[key] += 1


## Prefix max of (center + h) and suffix min of (center - h) at t_k of a list.
func _rel_bounds(key: int, k: int) -> void:
	var k1 := _k_steps + 1
	var rs := _rel_start[key]
	var rn := _rel_n[key]
	var run := -INF
	for r in rn:
		var o := _rel_o[rs + r]
		run = maxf(run, _oc[o * k1 + k] + _oh[o])
		_rel_pre[rs + r] = run
	run = INF
	for r in range(rn - 1, -1, -1):
		var o := _rel_o[rs + r]
		run = minf(run, _oc[o * k1 + k] - _oh[o])
		_rel_suf[rs + r] = run


## The start positions' lists for a player starting at s0: position j's list minus
## the vehicles following it there (fully behind it at t0, overlapping position j and
## the player's actual body: a player between grid positions, e.g. an interrupted
## lane change, is not followed by the cars of the lane it has not entered).
func _set_exempt(s0: float) -> void:
	var k1 := _k_steps + 1
	var hp := _player_length() * 0.5
	var hw := _player_width() * 0.5
	for o in _n_obs:
		var bits := 0
		var q := _oq[o]
		if _oc[o * k1] + _vlen[q] * 0.5 <= s0 - hp and _odh[o] > _p_d - hw and _odl[o] < _p_d + hw:
			for j in _n_pos:
				if _odh[o] > _pos_d[j] - hw and _odl[o] < _pos_d[j] + hw:
					bits |= 1 << j
		_exempt[o] = bits


## The start states' lists (positions in `mask`) after _set_exempt: position j's list
## minus its followers. Arrival checks also get their forward copies.
func _build_start_lists(mask: int) -> void:
	_rel_used = _rel_regular
	for k in _k_steps:
		var base_k := k * MAX_OCC
		for j in _n_pos:
			if (mask >> j) & 1 == 0:
				continue
			var src := base_k + j
			var key := base_k + _occ_start + j
			var rs := _rel_start[src]
			_rel_start[key] = _rel_used
			var n := 0
			for r in _rel_n[src]:
				var o := _rel_o[rs + r]
				if (_exempt[o] >> j) & 1 == 1:
					continue
				_rel_o[_rel_used + n] = o
				_rel_lo1[_rel_used + n] = _rel_lo1[rs + r]
				_rel_hi1[_rel_used + n] = _rel_hi1[rs + r]
				n += 1
			_rel_n[key] = n
			_rel_used += n
			_rel_bounds(key, k)
			if _mode == MODE_ARRIVAL:
				_forward_list(key, k)


# ---------------------------------------------------------------- Backward search (player check)

## G_K = the corridor at the horizon, for every state.
func _init_backward() -> void:
	var gk := _k_steps * MAX_STATES
	for x in _n_states:
		_glo[(gk + x) * MAX_IV] = _corr_lo[_k_steps]
		_ghi[(gk + x) * MAX_IV] = _corr_hi[_k_steps]
		_gn[gk + x] = 1
	_kb = _k_steps


## G_k(x) for k in [k_to, k_from): the union over successors x2 of the pre-image of
## G_{k+1}(x2). A piece of G_{k+1}(x2) between hulls is reached from s when s is on the
## same side of every hull at t_k (prefix / suffix bounds) within the speed range.
func _backward(k_from: int, k_to: int) -> void:
	for k in range(k_from - 1, k_to - 1, -1):
		var dmin := _dmin[k]
		var dmax := _dmax[k]
		var clo := _corr_lo[k]
		var chi := _corr_hi[k]
		var gk1 := (k + 1) * MAX_STATES
		for x in _n_states:
			if _reach[k * MAX_STATES + x] == 0:
				_gn[k * MAX_STATES + x] = 0   # the player cannot be there at step k
				continue
			# Pieces of every successor into the scratch list, then sort and merge.
			var np := 0
			for e in _succ_n[x]:
				var x2 := _succ[x * MAX_SUCC + e]
				var key := k * MAX_OCC + _succ_occ[x * MAX_SUCC + e]
				var rs := _rel_start[key]
				var rn := _rel_n[key]
				var nb := (gk1 + x2) * MAX_IV
				for q in _gn[gk1 + x2]:
					var b := _ghi[nb + q]
					var cur := _glo[nb + q]
					var r := 0
					while true:
						while r < rn and _rel_lo1[rs + r] <= cur:
							cur = maxf(cur, _rel_hi1[rs + r])
							r += 1
						if cur >= b:
							break
						var ph := b
						var hi := chi
						if r < rn:
							ph = minf(_rel_lo1[rs + r], b)
							hi = minf(hi, _rel_suf[rs + r])
						var lo := maxf(cur - dmax, clo)
						hi = minf(hi, ph - dmin)
						if r > 0:
							lo = maxf(lo, _rel_pre[rs + r - 1])
						if lo <= hi:
							_plo[np] = lo
							_phi[np] = hi
							np += 1
						if r >= rn or _rel_lo1[rs + r] >= b:
							break
						cur = _rel_lo1[rs + r]
			_gn[k * MAX_STATES + x] = _merge_pieces(np, (k * MAX_STATES + x) * MAX_IV)


## Sorts the np scratch pieces by start and writes their union to G at `base`.
func _merge_pieces(np: int, base: int) -> int:
	for i in range(1, np):
		var lo := _plo[i]
		var hi := _phi[i]
		var j := i - 1
		while j >= 0 and _plo[j] > lo:
			_plo[j + 1] = _plo[j]
			_phi[j + 1] = _phi[j]
			j -= 1
		_plo[j + 1] = lo
		_phi[j + 1] = hi
	var n := 0
	for i in np:
		var lo := _plo[i]
		var hi := _phi[i]
		if n > 0 and lo <= _ghi[base + n - 1]:
			if hi > _ghi[base + n - 1]:
				_ghi[base + n - 1] = hi
		elif n < MAX_IV:
			_glo[base + n] = lo
			_ghi[base + n] = hi
			n += 1
		else:
			_overflows += 1
	return n


func _g_contains(k: int, x: int, s: float) -> bool:
	if x < 0 or x >= _n_states:
		return false
	var gb := (k * MAX_STATES + x) * MAX_IV
	for q in _gn[k * MAX_STATES + x]:
		if s >= _glo[gb + q] and s <= _ghi[gb + q]:
			return true
	return false


# ---------------------------------------------------------------- Probes and forward sets (batch check)

## Probes: behind every vehicle V slower than the minimum speed (now or by desire, by
## more than arrival_slow_margin_kmh: a car a hair below it is no wall) in
## [s_from - arrival_probe_back_m, s_to), live or planned, the start window of arrivals
## that reach V at the minimum speed within arrival_reach_frac of the horizon:
## [s_V - h - (v_lo - v_V) T f, s_V - h] (an arrival that only reaches V at the
## horizon's end would "pass" by just hanging back). Windows within arrival_probe_merge_m of another (a wall side by side) are
## merged. Sets the corridor's start range.
func _find_probes(traffic: TrafficState) -> void:
	_n_probes = 0
	var lo := _s_from - _pt.arrival_probe_back_m
	for i in traffic.capacity:
		if traffic.active[i] == 1:
			_probe_behind(traffic.s[i], minf(traffic.v[i], traffic.v0[i]), traffic.length[i], lo)
	for k in _n_planned:
		var rec := _planned[k]
		var v0 := rec.v0 if rec.v0 > 0.0 else registry.v0_max[rec.profile_id]
		_probe_behind(rec.s, minf(rec.v, v0), registry.length[rec.type_id], lo)
	var n := 0
	for i in _n_probes:
		if n > 0 and _probe_s[i] - _probe_s[n - 1] < _pt.arrival_probe_merge_m \
				and absf(_probe_w[i] - _probe_w[n - 1]) < _pt.arrival_probe_merge_m:
			continue
		_probe_s[n] = _probe_s[i]
		_probe_w[n] = _probe_w[i]
		n += 1
	_n_probes = n
	_probe_lo = INF
	_probe_hi = -INF
	for i in n:
		_probe_lo = minf(_probe_lo, _probe_s[i] - _probe_w[i])
		_probe_hi = maxf(_probe_hi, _probe_s[i])


## A probe behind a vehicle at s (speed or desired speed v, length len) when it is slow
## and in range; kept sorted by the window's front.
func _probe_behind(s: float, v: float, body_len: float, lo: float) -> void:
	if s < lo or s >= _s_to or v >= _v_lo - _slow_margin or _n_probes >= MAX_PROBES:
		return
	var front := s - (body_len + _player_length()) * 0.5 - _pt.clearance_m - _pad
	var i := _n_probes
	while i > 0 and _probe_s[i - 1] > front:
		_probe_s[i] = _probe_s[i - 1]
		_probe_w[i] = _probe_w[i - 1]
		i -= 1
	_probe_s[i] = front
	_probe_w[i] = (_v_lo - v) * _pt.horizon_s * _pt.arrival_reach_frac
	_n_probes += 1


## Starts of probe p: in every position, the part of the start window outside the
## hulls at t0 (start states: the vehicles behind the window in that lane follow the
## player and are exempt). False when there is none.
func _start_probe(p: int) -> bool:
	var s1 := _probe_s[p]
	var s0 := s1 - _probe_w[p]
	_set_exempt(s0)
	_an.fill(0)
	var mask := 0
	var k1 := _k_steps + 1
	for j in _n_pos:
		var rs := _rel_start[j]
		var x := _n_reg + j
		var n := _iv_add_to(_alo, _ahi, x * MAX_IV, 0, s0, s1)
		for r in _rel_n[j]:
			var o := _rel_o[rs + r]
			if (_exempt[o] >> j) & 1 == 0:
				n = _iv_cut(_alo, _ahi, x * MAX_IV, n, _oc[o * k1] - _oh[o], _oc[o * k1] + _oh[o])
		_an[x] = n
		if n > 0:
			mask |= 1 << j
	_start_mask = mask
	if mask == 0:
		return false
	_build_start_lists(mask)
	return true


## Removes the open interval (lo, hi) from the list at `base`. Returns the new count.
func _iv_cut(alo: PackedFloat64Array, ahi: PackedFloat64Array, base: int, n: int, lo: float, hi: float) -> int:
	var q := 0
	while q < n:
		var a := alo[base + q]
		var b := ahi[base + q]
		if b <= lo or a >= hi:
			q += 1
			continue
		if a < lo and b > hi:
			if n >= MAX_IV:
				_overflows += 1
				ahi[base + q] = lo
				return n
			var m := n
			while m > q + 1:
				alo[base + m] = alo[base + m - 1]
				ahi[base + m] = ahi[base + m - 1]
				m -= 1
			ahi[base + q] = lo
			alo[base + q + 1] = hi
			ahi[base + q + 1] = b
			return n + 1
		if a < lo:
			ahi[base + q] = lo
			q += 1
		elif b > hi:
			alo[base + q] = hi
			q += 1
		else:
			for m in range(q + 1, n):
				alo[base + m - 1] = alo[base + m]
				ahi[base + m - 1] = ahi[base + m]
			n -= 1
	return n


func _run_probe(p: int) -> void:
	_probe_ok[p] = 0
	if not _start_probe(p):
		return
	# Cheap first: a path that keeps its start lane is enough (the common case: a free
	# lane beside the slow vehicle).
	if _forward(false, true) == INF:
		_probe_ok[p] = 1
		return
	_start_probe(p)
	var t := _forward(false)
	if t == INF:
		_probe_ok[p] = 1
		return
	_out.failed_probes += 1
	_out.fail_t = minf(_out.fail_t, t)
	if is_nan(_out.fail_s):
		_out.fail_s = _probe_s[p]
	for o in _n_obs:
		_out.blocker_cut[o] += _cut[o]


## The forward copy of list `key` (step k): sorted by hull start at t_k, with the
## prefix max of (center + h) and the suffix min of (center - h) at t_{k+1} and the
## obstacles attaining them.
func _forward_list(key: int, k: int) -> void:
	var k1 := _k_steps + 1
	var rs := _rel_start[key]
	var rn := _rel_n[key]
	for r in rn:
		var o := _rel_o[rs + r]
		var c0 := _oc[o * k1 + k]
		var lo := c0 - _oh[o]
		var q := r - 1
		while q >= 0 and _frel_lo0[rs + q] > lo:
			_frel_o[rs + q + 1] = _frel_o[rs + q]
			_frel_lo0[rs + q + 1] = _frel_lo0[rs + q]
			_frel_hi0[rs + q + 1] = _frel_hi0[rs + q]
			q -= 1
		_frel_o[rs + q + 1] = o
		_frel_lo0[rs + q + 1] = lo
		_frel_hi0[rs + q + 1] = c0 + _oh[o]
	var run := -INF
	var arg := -1
	for r in rn:
		var o := _frel_o[rs + r]
		var v := _oc[o * k1 + k + 1] + _oh[o]
		if v > run:
			run = v
			arg = o
		_frel_pre[rs + r] = run
		_frel_pre_o[rs + r] = arg
	run = INF
	arg = -1
	for r in range(rn - 1, -1, -1):
		var o := _frel_o[rs + r]
		var v := _oc[o * k1 + k + 1] - _oh[o]
		if v < run:
			run = v
			arg = o
		_frel_suf[rs + r] = run
		_frel_suf_o[rs + r] = arg


## Forward reachable sets from the starts in _alo/_ahi/_an, to the horizon. Every
## obstacle is credited in _cut with the path space (m) it cuts at each step; `store`
## keeps R_k in the step sets for _backtrack; `stay_only` never moves sideways (a cheap
## sufficient test). Returns the time at which nothing is left (INF: a path survives).
func _forward(store: bool, stay_only: bool = false) -> float:
	for o in _n_obs:
		_cut[o] = 0.0
	if store:
		_store_sets(0)
	for k in _k_steps:
		var dmin := _dmin[k]
		var dmax := _dmax[k]
		var clo := _corr_lo[k + 1]
		var chi := _corr_hi[k + 1]
		for x in _n_states:
			_bn[x] = 0
		for x in _n_states:
			var na := _an[x]
			if na == 0:
				continue
			var ab := x * MAX_IV
			for e in (1 if stay_only else _succ_n[x]):
				var x2 := _succ[x * MAX_SUCC + e]
				var key := k * MAX_OCC + _succ_occ[x * MAX_SUCC + e]
				var rs := _rel_start[key]
				var rn := _rel_n[key]
				for q in na:
					var b := _ahi[ab + q]
					var cur := _alo[ab + q]
					var r := 0
					while true:
						while r < rn and _frel_lo0[rs + r] <= cur:
							var hi0 := _frel_hi0[rs + r]
							if hi0 > cur:
								_cut[_frel_o[rs + r]] += minf(hi0, b) - cur
								cur = hi0
							r += 1
						if cur > b:
							break
						var ph := b
						var upper := INF
						var up_o := -1
						if r < rn:
							ph = minf(_frel_lo0[rs + r], b)
							upper = _frel_suf[rs + r]
							up_o = _frel_suf_o[rs + r]
						var lo := cur + dmin
						var hi := ph + dmax
						if r > 0:
							var lower := _frel_pre[rs + r - 1]
							if lower > lo:
								_cut[_frel_pre_o[rs + r - 1]] += minf(lower - lo, hi - lo)
								lo = lower
						if upper < hi:
							_cut[up_o] += minf(hi - upper, hi - (cur + dmin))
							hi = upper
						lo = maxf(lo, clo)
						hi = minf(hi, chi)
						if lo <= hi:
							_bn[x2] = _iv_add_to(_blo, _bhi, x2 * MAX_IV, _bn[x2], lo, hi)
						if r >= rn or _frel_lo0[rs + r] >= b:
							break
						cur = _frel_lo0[rs + r]
		var any := false
		for x in _n_states:
			var n := _bn[x]
			_an[x] = n
			for q in n:
				_alo[x * MAX_IV + q] = _blo[x * MAX_IV + q]
				_ahi[x * MAX_IV + q] = _bhi[x * MAX_IV + q]
			if n > 0:
				any = true
		if store:
			_store_sets(k + 1)
		if not any:
			return float(k + 1) * _pt.step_s
	return INF


func _store_sets(k: int) -> void:
	for x in _n_states:
		var n := _an[x]
		_gn[k * MAX_STATES + x] = n
		var gb := (k * MAX_STATES + x) * MAX_IV
		for q in n:
			_glo[gb + q] = _alo[x * MAX_IV + q]
			_ghi[gb + q] = _ahi[x * MAX_IV + q]


## Adds [lo, hi] to the sorted, disjoint interval list at `base` (n entries), merging
## overlaps. Returns the new count. A full list drops the new interval (conservative).
func _iv_add_to(alo: PackedFloat64Array, ahi: PackedFloat64Array, base: int, n: int, lo: float, hi: float) -> int:
	if hi < lo:
		return n
	var i := 0
	while i < n and ahi[base + i] < lo:
		i += 1
	if i < n and alo[base + i] <= hi:
		alo[base + i] = minf(alo[base + i], lo)
		var top := maxf(ahi[base + i], hi)
		var j := i + 1
		while j < n and alo[base + j] <= top:
			top = maxf(top, ahi[base + j])
			j += 1
		ahi[base + i] = top
		var removed := j - i - 1
		if removed > 0:
			for m in range(j, n):
				alo[base + m - removed] = alo[base + m]
				ahi[base + m - removed] = ahi[base + m]
		return n - removed
	if n >= MAX_IV:
		_overflows += 1
		return n
	var m := n
	while m > i:
		alo[base + m] = alo[base + m - 1]
		ahi[base + m] = ahi[base + m - 1]
		m -= 1
	alo[base + i] = lo
	ahi[base + i] = hi
	return n + 1


# ---------------------------------------------------------------- Paths

## Greedy path through the good sets from (x0, s0): each step picks the successor and s'
## that stay in G, closest to the preferred speed (changing speed by at most the
## traffic's comfortable clamp per step when possible) and to d_pref, keeping room to
## the good set's edges.
func _extract(out: Result, x0: int, s0: float, v_pref: float, d_pref: float, v_now: float,
		headway_s: float = 0.0) -> void:
	var k1 := _k_steps + 1
	_ensure_path(out, k1)
	var x := x0
	var s := s0
	var v := v_now
	var step := _pt.step_s
	var comfort := step * _max_decel
	var margin := _pt.clearance_m + step * _v_lo
	out.path_s[0] = s
	out.path_d[0] = _state_d[x]
	out.path_state[0] = x
	out.path_n = 1
	for k in _k_steps:
		var best_score := INF
		var best_x := -1
		var best_s := 0.0
		var s_want := s + clampf(v_pref, v - comfort, v + comfort) * step
		for e in _succ_n[x]:
			var x2 := _succ[x * MAX_SUCC + e]
			var key := k * MAX_OCC + _succ_occ[x * MAX_SUCC + e]
			var rs := _rel_start[key]
			# Obstacle bounds (keep room to them) and the speed envelope (no room needed).
			var lower := -INF
			var upper := INF
			var inside := false
			for r in _rel_n[key]:
				var o := _rel_o[rs + r]
				var c0 := _oc[o * k1 + k]
				var h := _oh[o]
				if s <= c0 - h:
					upper = minf(upper, _rel_lo1[rs + r])
				elif s >= c0 + h:
					lower = maxf(lower, _rel_hi1[rs + r])
				else:
					inside = true
					break
			var v_lo := s + _dmin[k]
			var v_hi := s + _dmax[k]
			if inside or maxf(lower, v_lo) > minf(upper, v_hi):
				continue
			var lat := absf(_state_d[x2] - d_pref) + (0.0 if x2 == x else _grid * 0.5)
			var head := upper if headway_s <= 0.0 else _ahead_of(s, k, _succ_occ[x * MAX_SUCC + e])
			var gb := ((k + 1) * MAX_STATES + x2) * MAX_IV
			for q in _gn[(k + 1) * MAX_STATES + x2]:
				# The good interval's own edges are obstacle-bound too, unless they are the
				# corridor's (the speed envelope).
				var ga := _glo[gb + q]
				var gh := _ghi[gb + q]
				var a := maxf(maxf(ga, lower), v_lo)
				var b := minf(minf(gh, upper), v_hi)
				if a > b:
					continue
				var ra := maxf(ga if ga > _corr_lo[k + 1] else -INF, lower)
				var rb := minf(gh if gh < _corr_hi[k + 1] else INF, upper)
				# Room behind what is ahead: the headway at the new speed (at least the
				# margin), shrunk to fit; room ahead of what is behind: the margin.
				var room_b := minf(margin, (rb - ra) * 0.5)
				var room_f := maxf(margin, (s_want - s) / step * headway_s)
				var lo_p := maxf(a, ra + room_b)
				if lo_p > b:
					lo_p = a
				var pick := clampf(minf(s_want, minf(rb, head) - room_f), lo_p, b)
				var score := absf(pick - s_want) + lat
				if score < best_score:
					best_score = score
					best_x = x2
					best_s = pick
		if best_x < 0:
			return
		v = (best_s - s) / step
		x = best_x
		s = best_s
		out.path_s[k + 1] = s
		out.path_d[k + 1] = _state_d[x]
		out.path_state[k + 1] = x
		out.path_n = k + 2


## The hull start at t_{k+1} of the nearest obstacle ahead of s that overlaps
## occupancy `occ` during step k, reachable this step or not (the headway preference).
func _ahead_of(s: float, k: int, occ: int) -> float:
	var j_lo := occ
	var j_hi := occ
	if occ >= _occ_start:
		j_lo = occ - _occ_start
		j_hi = j_lo
	elif occ >= _n_pos:
		j_lo = occ - _n_pos
		j_hi = j_lo + 1
	var k1 := _k_steps + 1
	var best := INF
	for o in _n_obs:
		var ok := o * _k_steps + k
		if _oj0[ok] > j_hi or _oj1[ok] < j_lo or _oc[o * k1 + k] < s:
			continue
		best = minf(best, _oc[o * k1 + k + 1] - _oh[o])
	return best


## A path back from the horizon through stored forward sets (the batch check's
## overlay path): at each step a predecessor in R_k that reaches the current point.
func _backtrack(out: Result) -> void:
	var k1 := _k_steps + 1
	_ensure_path(out, k1)
	var kk := _k_steps
	var x := -1
	var s := 0.0
	for xx in _n_states:
		var n := _gn[kk * MAX_STATES + xx]
		if n > 0:
			x = xx
			var gb := (kk * MAX_STATES + xx) * MAX_IV
			s = (_glo[gb] + _ghi[gb]) * 0.5
			if _state_pos[xx] >= 0:
				break
	if x < 0:
		return
	out.path_s[kk] = s
	out.path_d[kk] = _state_d[x]
	out.path_state[kk] = x
	var v := _v_start
	for k in range(_k_steps - 1, -1, -1):
		var found := false
		for i in _pred_n[x]:
			var xp := _pred[x * MAX_PRED + i]
			var key := k * MAX_OCC + _pred_occ[x * MAX_PRED + i]
			var rs := _rel_start[key]
			var lower := s - _dmax[k]
			var upper := s - _dmin[k]
			var inside := false
			for r in _rel_n[key]:
				var o := _rel_o[rs + r]
				var c0 := _oc[o * k1 + k]
				var h := _oh[o]
				if s <= _rel_lo1[rs + r]:
					upper = minf(upper, c0 - h)
				elif s >= _rel_hi1[rs + r]:
					lower = maxf(lower, c0 + h)
				else:
					inside = true
					break
			if inside or lower > upper:
				continue
			var gb := (k * MAX_STATES + xp) * MAX_IV
			for q in _gn[k * MAX_STATES + xp]:
				var a := maxf(_glo[gb + q], lower)
				var b := minf(_ghi[gb + q], upper)
				if a <= b:
					var prev := clampf(s - v * _pt.step_s, a, b)
					v = (s - prev) / _pt.step_s
					s = prev
					x = xp
					found = true
					break
			if found:
				break
		if not found:
			out.path_n = 0
			return
		out.path_s[k] = s
		out.path_d[k] = _state_d[x]
		out.path_state[k] = x
	out.path_n = k1


func _ensure_path(out: Result, n: int) -> void:
	if out.path_s.size() < n:
		out.path_s.resize(n)
		out.path_d.resize(n)
		out.path_state.resize(n)
