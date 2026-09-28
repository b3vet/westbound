class_name MobilProbe
extends RefCounted
## Read-only MOBIL readout for the traffic sandbox overlays. Spec: Traffic → Traffic
## sandbox (debug scene): "overlays for ... MOBIL decisions with incentive values";
## Lane changes: MOBIL; Fairness rule 2 (no ambush). Model: docs/TRAFFIC.md → MOBIL.
##
## TrafficSim keeps its evaluation terms private, so this probe recomputes them from
## the published TrafficState and the sim's public queries (idm_accel, leader_of,
## is_lane_splitting, player_index) with the same Idm / Mobil / NoAmbush functions,
## the same registry parameters and the same neighbor search as TrafficSim's
## _eval_target / _eval_move:
##   - the new leader and follower are the nearest vehicles (the player included)
##     whose claim interval overlaps the target body +- lateral_margin_m, within
##     idm_lookahead_m; claims cover a signaling or moving car's target, and half a
##     lane each side of a lane-splitting bike;
##   - the old follower is the nearest one behind on the car's own physical path
##     (its body; the whole span while MOVING);
##   - a_c is the car's IDM acceleration at its last model update (sim.idm_accel),
##     and the old leader is sim.leader_of(slot);
##   - the player is judged with player_idm_* holding its speed (interaction term),
##     and tightens b_safe to player_b_safe_mps2.
## Differences from the sim's own evaluation, all small: the sim evaluates inside its
## tick (vehicles later in its lateral pass have not moved yet), and a motorbike's
## split-move target is inferred from its blinker and start position. The verdict
## (refusal) follows the sim's order of checks; the incentive terms are computed
## whenever the neighbors allow it, so a refused move still shows its incentive.
##
## Pure (RefCounted, no Node) and allocation-free: evaluate_into() writes into a
## caller-owned Result.

enum Refusal {
	NONE,               ## MOBIL's safety criteria and no-ambush pass
	NO_LANE,            ## the target lane does not exist
	KEEP_RIGHT,         ## keep-right profile: not left of its allowed lanes
	LEADER_OVERLAP,     ## the new leader overlaps longitudinally
	OWN_BRAKE,          ## the car's own a~c < -b_safe behind the new leader
	FOLLOWER_OVERLAP,   ## the new follower overlaps longitudinally
	FOLLOWER_BRAKE,     ## the new follower's a~n < -b_safe
	AMBUSH,             ## fairness rule 2: the player's predicted space
}

const REFUSAL_NAMES: Array[String] = [
	"ok", "no lane", "keep right", "lead overlap", "own brake", "foll overlap", "foll brake", "ambush",
]
const _NONE := TrafficState.LaneChange.NONE
const _MOVING := TrafficState.LaneChange.MOVING


## One evaluation of a move of `slot` into `target_lane`.
class Result:
	extends RefCounted
	var slot: int = -1
	var target_lane: int = -1
	var target_d: float = NAN
	var to_right: bool = false
	var refusal: int = Refusal.NONE
	var refusal_is_player: bool = false   ## the refusal involves the player (the sim cancels)
	var lead: int = -1                    ## new leader: slot, player_index() or -1
	var follower: int = -1                ## new follower
	var old_follower: int = -1
	var a_c: float = 0.0                  ## car now (sim.idm_accel)
	var a_c_new: float = 0.0              ## car behind the new leader
	var a_n: float = 0.0                  ## new follower now
	var a_n_new: float = 0.0              ## new follower with the car ahead
	var a_o: float = 0.0                  ## old follower now
	var a_o_new: float = 0.0              ## old follower after the car leaves
	var politeness: float = 0.0
	var b_safe: float = 0.0               ## as applied to the new follower
	var bias: float = 0.0                 ## keep-right bias + lane discipline
	var incentive: float = NAN
	var threshold: float = NAN

	## Incentive minus threshold (the sim's return value when the move is safe).
	func margin() -> float:
		return incentive - threshold

	func is_safe() -> bool:
		return refusal == Refusal.NONE

	## MOBIL (and the fairness checks) would start this lane change.
	func accepts() -> bool:
		return refusal == Refusal.NONE and incentive > threshold


var sim: TrafficSim
var road: RoadPath
var registry: TrafficRegistry
var tuning: TrafficTuning

# The player in the road frame (TrafficSim._read_player).
var _ps: float = 0.0
var _pv: float = 0.0
var _pd: float = 0.0
var _pvl: float = 0.0
var _plen: float
var _pw: float
var _plo: float = NAN
var _phi: float = NAN
var _edge: float = 0.0
var _lw: float = 0.0


func _init(traffic_sim: TrafficSim, road_path: RoadPath) -> void:
	sim = traffic_sim
	road = road_path
	registry = sim.registry
	tuning = sim.tuning
	_plen = tuning.player_length_m
	_pw = tuning.player_width_m


## The player's body (the size given to TrafficSim.set_player_body).
func set_player_body(length_m: float, width_m: float) -> void:
	_plen = length_m
	_pw = width_m


## The player's state for this readout (the state the sim last stepped with).
func set_player(player: VehicleState) -> void:
	var cy := cos(player.yaw)
	var sy := sin(player.yaw)
	var kappa := road.curvature_at(player.s)
	_ps = player.s
	_pd = player.d
	_pv = (player.v * cy - player.v_lat * sy) / (1.0 - kappa * player.d)
	_pvl = player.v * sy + player.v_lat * cy
	var ahead := _pvl * tuning.player_lateral_anticipation_s
	_plo = _pd - _pw * 0.5 + minf(0.0, ahead)
	_phi = _pd + _pw * 0.5 + maxf(0.0, ahead)
	_edge = road.lanes_left_edge_d(_ps)
	_lw = road.lane_width(_ps)


## Lane center d with the lane geometry at the player (as the sim uses it).
func lane_d(lane: int) -> float:
	return _edge + (float(lane) + 0.5) * _lw


## Evaluates a move of `slot` into `target_lane` (to its lane center). Allocation-free.
func evaluate_into(slot: int, target_lane: int, out: Result) -> void:
	var st := sim.state
	var p := st.profile_id[slot]
	var si := st.s[slot]
	var vi := st.v[slot]
	var cur := st.lane[slot]
	var lanes := road.lane_count(si)
	var tc := lane_d(target_lane)
	var gap_floor := tuning.idm_gap_floor_m
	var lat_m := tuning.lateral_margin_m
	out.slot = slot
	out.target_lane = target_lane
	out.target_d = tc
	out.to_right = target_lane > cur
	out.refusal = Refusal.NONE
	out.refusal_is_player = false
	out.lead = -1
	out.follower = -1
	out.old_follower = -1
	out.a_c = sim.idm_accel(slot)
	out.a_c_new = 0.0
	out.a_n = 0.0
	out.a_n_new = 0.0
	out.a_o = 0.0
	out.a_o_new = 0.0
	out.politeness = registry.politeness[p]
	out.b_safe = registry.b_safe[p]
	out.bias = 0.0
	out.incentive = NAN
	out.threshold = NAN
	if target_lane < 0 or target_lane >= lanes:
		out.refusal = Refusal.NO_LANE
		return
	var krl := registry.keep_right_lanes[p]
	if krl > 0 and target_lane < cur and target_lane < lanes - krl:
		out.refusal = Refusal.KEEP_RIGHT
		return

	var hw := st.width[slot] * 0.5
	var hl := st.length[slot] * 0.5
	var lo := tc - hw - lat_m
	var hi := tc + hw + lat_m
	var lead := _nearest(slot, si, lo, hi, true, true)
	var foll := _nearest(slot, si, lo, hi, false, true)
	out.lead = lead
	out.follower = foll
	var v0 := st.v0[slot]
	var bsafe := registry.b_safe[p]
	# New leader: overlap, then the car's own braking behind it.
	var gl := INF
	var dvl := 0.0
	if lead >= 0:
		gl = _s(lead) - si - _hl(lead) - hl
		dvl = vi - _v(lead)
		out.a_c_new = Idm.accel(vi, v0, gl, dvl, registry.a_max[p], registry.b_comfort[p], registry.headway[p],
			registry.s0[p], registry.delta[p], gap_floor)
	else:
		out.a_c_new = Idm.free_accel(vi, v0, registry.a_max[p], registry.delta[p])
	var pi := sim.player_index()
	if lead >= 0 and gl <= 0.0:
		_refuse(out, Refusal.LEADER_OVERLAP, lead == pi)
	elif lead >= 0 and out.a_c_new < -bsafe:
		_refuse(out, Refusal.OWN_BRAKE, lead == pi)
	# New follower: overlap, then its braking with the car ahead.
	if foll >= 0:
		var gf := si - _s(foll) - hl - _hl(foll)
		out.a_n_new = _follower_accel(foll, gf, _v(foll) - vi)
		out.b_safe = Mobil.b_safe_for(bsafe, foll == pi, tuning.player_b_safe_mps2)
		if out.refusal == Refusal.NONE:
			if gf <= 0.0:
				_refuse(out, Refusal.FOLLOWER_OVERLAP, foll == pi)
			elif not Mobil.is_safe(out.a_n_new, out.b_safe):
				_refuse(out, Refusal.FOLLOWER_BRAKE, foll == pi)
	if out.refusal == Refusal.NONE and NoAmbush.violates(si, vi, st.length[slot], st.width[slot], tc,
			_ps, _pv, _pd, _pvl, _plen, _pw, tuning.no_ambush_window_s, tuning.no_ambush_margin_m):
		_refuse(out, Refusal.AMBUSH, true)

	# Incentive terms (also shown for refused moves).
	if foll >= 0:
		if lead >= 0:
			out.a_n = _follower_accel(foll, _s(lead) - _s(foll) - _hl(lead) - _hl(foll), _v(foll) - _v(lead))
		else:
			out.a_n = _follower_accel(foll, INF, 0.0)
	var of := _old_follower(slot, si, lat_m)
	out.old_follower = of
	if of >= 0:
		out.a_o = _follower_accel(of, si - _s(of) - hl - _hl(of), _v(of) - vi)
		var ol := sim.leader_of(slot)
		if ol >= 0 and ol != of:
			out.a_o_new = _follower_accel(of, _s(ol) - _s(of) - _hl(ol) - _hl(of), _v(of) - _v(ol))
		else:
			out.a_o_new = _follower_accel(of, INF, 0.0)
	out.incentive = Mobil.incentive(out.a_c_new, out.a_c, out.a_n_new, out.a_n, out.a_o_new, out.a_o,
		registry.politeness[p])
	var bias := registry.a_bias[p]
	var disc := tuning.lane_discipline_bias_mps2
	if out.to_right:
		if registry.keep_right[p] == 1 or v0 < tuning.lane_flow_speed_mps(cur, lanes):
			bias += disc
	elif v0 < tuning.lane_flow_speed_mps(target_lane, lanes):
		bias += disc
	out.bias = bias
	out.threshold = Mobil.threshold(registry.a_threshold[p], bias, out.to_right)


# ---------------------------------------------------------------- Mirrors of the sim's view

func _refuse(out: Result, why: int, is_player: bool) -> void:
	out.refusal = why
	out.refusal_is_player = is_player


func _s(j: int) -> float:
	return _ps if j == sim.player_index() else sim.state.s[j]


func _v(j: int) -> float:
	return _pv if j == sim.player_index() else sim.state.v[j]


func _hl(j: int) -> float:
	return _plen * 0.5 if j == sim.player_index() else sim.state.length[j] * 0.5


## Nearest vehicle ahead (or behind) of s whose claim (or physical) interval overlaps
## [lo, hi], within idm_lookahead_m. The player counts. Returns a slot,
## player_index() or -1.
func _nearest(self_slot: int, s: float, lo: float, hi: float, ahead: bool, claims: bool) -> int:
	var st := sim.state
	var look := tuning.idm_lookahead_m
	var best := -1
	var best_ds := INF
	for j in st.capacity:
		if j == self_slot or st.active[j] == 0:
			continue
		var ds := st.s[j] - s if ahead else s - st.s[j]
		if ds <= 0.0 or ds > look or ds >= best_ds:
			continue
		var jlo := _claim_lo(j) if claims else _phys_lo(j)
		var jhi := _claim_hi(j) if claims else _phys_hi(j)
		if jlo < hi and jhi > lo:
			best = j
			best_ds = ds
	var dsp := _ps - s if ahead else s - _ps
	if dsp > 0.0 and dsp <= look and dsp < best_ds and _plo < hi and _phi > lo:
		best = sim.player_index()
	return best


func _old_follower(slot: int, s: float, lat_m: float) -> int:
	return _nearest(slot, s, _phys_lo(slot) - lat_m, _phys_hi(slot) + lat_m, false, false)


## d a signaling or moving vehicle's lateral move ends at (see the class comment for
## lane-split moves, whose target the sim keeps private).
func move_target_d(j: int) -> float:
	var st := sim.state
	var ln := st.lane[j]
	if st.target_lane[j] != ln:
		return lane_d(st.target_lane[j])
	var from_d := st.lc_start_d[j] if st.lc_state[j] == _MOVING else st.d[j]
	var center := lane_d(ln)
	if absf(from_d - center) > _lw * 0.5 * 0.5:
		return center   # leaving a lane split back to the lane center
	var left := st.has_flag(j, TrafficState.FLAG_BLINKER_LEFT)
	return center - _lw * 0.5 if left else center + _lw * 0.5


func _phys_lo(j: int) -> float:
	var st := sim.state
	var lo := st.d[j] - st.width[j] * 0.5
	if st.lc_state[j] == _MOVING:
		lo = minf(lo, move_target_d(j) - st.width[j] * 0.5)
	return lo


func _phys_hi(j: int) -> float:
	var st := sim.state
	var hi := st.d[j] + st.width[j] * 0.5
	if st.lc_state[j] == _MOVING:
		hi = maxf(hi, move_target_d(j) + st.width[j] * 0.5)
	return hi


func _claim_lo(j: int) -> float:
	var st := sim.state
	if st.lc_state[j] == _NONE:
		if sim.is_lane_splitting(j):
			return st.d[j] - _lw * 0.5
		return st.d[j] - st.width[j] * 0.5
	return minf(st.d[j] - st.width[j] * 0.5, move_target_d(j) - st.width[j] * 0.5)


func _claim_hi(j: int) -> float:
	var st := sim.state
	if st.lc_state[j] == _NONE:
		if sim.is_lane_splitting(j):
			return st.d[j] + _lw * 0.5
		return st.d[j] + st.width[j] * 0.5
	return maxf(st.d[j] + st.width[j] * 0.5, move_target_d(j) + st.width[j] * 0.5)


## IDM acceleration of follower f (slot or the player) at this gap / closing speed.
func _follower_accel(f: int, gap: float, dv: float) -> float:
	var gap_floor := tuning.idm_gap_floor_m
	if f == sim.player_index():
		return Idm.interaction_accel(_pv, gap, dv, tuning.player_idm_a_max_mps2, tuning.player_idm_b_comfort_mps2,
			tuning.player_idm_headway_s, tuning.player_idm_s0_m, gap_floor)
	var p := sim.state.profile_id[f]
	return Idm.accel(sim.state.v[f], sim.state.v0[f], gap, dv, registry.a_max[p], registry.b_comfort[p],
		registry.headway[p], registry.s0[p], registry.delta[p], gap_floor)
