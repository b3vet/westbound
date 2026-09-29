class_name ImpossibleWindowChecker
extends RefCounted
## Pre-director "impossible window" oracle for the traffic soak: a simplified version of
## the spec's passability search (Traffic → Passability guarantee; Tests (headless):
## "10,000 simulated km with a bot driver produce zero impossible windows"). It is an
## independent test observer: it reads only the published TrafficState and the
## player's VehicleState, never TrafficSim internals. Phase 6's passability.gd (the
## director's own guarantee) replaces the search in the game; this stays the oracle.
##
## Definition. At a moment t0, a window is IMPOSSIBLE when, looking horizon_s (8 s)
## ahead with the traffic's forward prediction, no path exists for the player that:
##   - moves over the lateral grid of lane centers and half-lanes
##     (PassabilityTuning.lateral_step_lanes) in decisions every step_s (0.25 s); a
##     half-lane move takes the car's lane-change time for half a lane at its current
##     speed (VehicleTuning.lane_change_target_s / 2, whole steps, at least one), and
##     the car occupies both grid positions while it moves;
##   - keeps its speed in [minimum speed (ScoringTuning, 100 km/h), current speed + the
##     car's mean acceleration x t] (capped at its top speed). Any speed in the range is
##     allowed at any moment: a relaxation of the braking and acceleration limits. A
##     player already below the minimum speed may hold its current speed instead (the
##     lower bound is min(minimum speed, current speed));
##   - stays on the driving lanes (no shoulders);
##   - never comes within clearance_m (0.3 m) of a predicted hull (full body boxes,
##     axis-aligned in road space, grown by the clearance on every side).
## Traffic prediction (simplified; passability.gd forward-simulates the real models):
##   - vehicles fully behind the player at t0 are ignored: they follow the player (IDM
##     with the player as leader, Lives → rear-end prevention) instead of driving into it;
##   - every other vehicle keeps its speed, but never drives through the vehicle ahead
##     of it on its lateral path (it queues behind it at min(s0, its current gap));
##   - a MOVING lane change continues its smoothstep to its final d; a SIGNALING one is
##     assumed to happen: it starts at the end of its signal time and takes the
##     profile's longest move time (it may still cancel, which only frees space); a
##     lane-splitting bike keeps riding the boundary.
## Anti-tunneling: positions are propagated in sub-steps short enough that neither the
## player nor any vehicle can jump over the shortest hull-plus-clearance block.
##
##   var iw := ImpossibleWindowChecker.new(tuning, registry, car)
##   if not iw.is_passable(sim.state, player, road): ...   # iw.fail_t, iw.lanes, ...

const MAX_STATES := 64
## A sub-step moves the player at most this fraction of the shortest block (< 1: no tunneling).
const SUB_STEP_BLOCK_FRAC := 0.9
## CarDef.zero_to_200_s is the time to this speed (mean acceleration = speed / time).
const ZERO_TO_KMH := 200.0

var clearance: float
var horizon: float
var step: float
var lat_step_lanes: float
var min_speed: float
var accel: float
var top_speed: float
var player_length: float
var player_width: float
var vehicle_tuning: VehicleTuning
var registry: TrafficRegistry

# Results of the last check.
var checks := 0
var impossible := 0
## Seconds into the horizon at which every path had ended (the last check; INF = passable).
var fail_t := INF
## Grid positions and obstacles of the last check.
var positions := 0
var obstacles := 0
## The player overlapped a hull (+ clearance) already at t0 in the last check.
var started_in_contact := false

# Scratch (reused between checks).
var _obs := PackedInt32Array()
var _ps := PackedFloat64Array()    # predicted s, [o * (n_sub_total + 1) + g]
var _mask := PackedInt32Array()    # blocked grid positions (bits), [o * steps + k]
var _hl := PackedFloat64Array()    # block half length (player center frame)
var _pos_d := PackedFloat64Array()
var _state_bits := PackedInt32Array()
var _iv: Array[PackedFloat64Array] = []
var _order := PackedInt32Array()
var _cand := PackedInt32Array()


func _init(t: Tuning, reg: TrafficRegistry, car: CarDef) -> void:
	var pt := t.passability
	clearance = pt.clearance_m
	horizon = pt.horizon_s
	step = pt.step_s
	lat_step_lanes = pt.lateral_step_lanes
	min_speed = t.scoring.min_speed_mps()
	vehicle_tuning = t.vehicle
	registry = reg
	top_speed = Units.kmh_to_mps(car.top_speed_kmh)
	accel = Units.kmh_to_mps(ZERO_TO_KMH) / car.zero_to_200_s
	player_length = car.length_m
	player_width = car.width_m
	for k in MAX_STATES:
		_iv.append(PackedFloat64Array())


## True when a path exists (see the class doc). Updates the counters and fail_t.
func is_passable(ts: TrafficState, player: VehicleState, road: RoadPath) -> bool:
	checks += 1
	var ok := _search(ts, player, road)
	if not ok:
		impossible += 1
	return ok


func _search(ts: TrafficState, player: VehicleState, road: RoadPath) -> bool:
	fail_t = INF
	started_in_contact = false
	var s0 := player.s
	var lanes := road.lane_count(s0)
	var lw := road.lane_width(s0)
	var grid := lat_step_lanes * lw
	var d_first := road.lane_center_d(0, s0)
	var d_last := road.lane_center_d(lanes - 1, s0)
	var n_pos := roundi((d_last - d_first) / grid) + 1
	positions = n_pos
	_pos_d.resize(n_pos)
	for j in n_pos:
		_pos_d[j] = d_first + float(j) * grid
	# Never slower than the minimum speed, or than the player already is: a player below
	# it (e.g. keeping its lane behind a truck) may hold its speed, not jump to 100 km/h.
	var v_low := minf(min_speed, maxf(player.v, 0.0))
	var v_start := maxf(player.v, v_low)
	var steps := ceili(horizon / step - 1e-9)
	var v_end := minf(v_start + accel * horizon, maxf(top_speed, v_start))
	var half_move_steps := maxi(1, roundi(vehicle_tuning.lane_change_target_s(v_start) * 0.5 / step))
	var n_states := n_pos + (n_pos - 1) * half_move_steps
	assert(n_states <= MAX_STATES, "ImpossibleWindowChecker: too many lanes for MAX_STATES")
	_state_bits.resize(n_states)
	for j in n_pos:
		_state_bits[j] = 1 << j
	for p in n_pos - 1:
		for m in half_move_steps:
			_state_bits[n_pos + p * half_move_steps + m] = (1 << p) | (1 << (p + 1))

	# Obstacles: everything not fully behind the player.
	var p_rear := s0 - player_length * 0.5 - clearance
	_obs.clear()
	var min_block := INF
	for i in ts.capacity:
		if ts.active[i] == 1 and ts.s[i] + ts.length[i] * 0.5 > p_rear:
			_obs.append(i)
			min_block = minf(min_block, ts.length[i] + player_length + 2.0 * clearance)
	var n_obs := _obs.size()
	obstacles = n_obs
	# Sub-steps: nothing may cross the shortest block within one sub-step.
	var n_sub := 1
	if n_obs > 0:
		n_sub = maxi(1, ceili(step * v_end / (SUB_STEP_BLOCK_FRAC * min_block)))
	var dt := step / float(n_sub)
	var n_g := steps * n_sub
	_predict(ts, road, n_obs, steps, n_sub, dt, lw)

	# Initial states: the grid positions bracketing the player's d.
	for k in n_states:
		_iv[k].clear()
	var x := (player.d - d_first) / grid
	var j_lo := clampi(floori(x), 0, n_pos - 1)
	var j_hi := clampi(ceili(x), 0, n_pos - 1)
	_iv[j_lo].append(s0)
	_iv[j_lo].append(s0)
	if j_hi != j_lo:
		_iv[j_hi].append(s0)
		_iv[j_hi].append(s0)
	started_in_contact = _in_contact(ts, player)

	var g := 0
	for k in steps:
		_decide(n_pos, half_move_steps)
		# Candidates of this step: obstacles inside the corridor the player can reach.
		var c_lo := s0 + v_low * float(k) * step
		var c_hi := s0 + v_end * float(k + 1) * step
		_cand.clear()
		for oi in n_obs:
			var base := oi * (n_g + 1)
			if _ps[base + (k + 1) * n_sub] + _hl[oi] > c_lo and _ps[base + k * n_sub] - _hl[oi] < c_hi:
				_cand.append(oi)
		for m in n_sub:
			g += 1
			var t := float(g) * dt
			var vmax := minf(v_start + accel * t, maxf(top_speed, v_start))
			var alive := false
			for st in n_states:
				var iv := _iv[st]
				if iv.is_empty():
					continue
				var nx := PackedFloat64Array()
				for q in range(0, iv.size(), 2):
					nx.append(iv[q] + v_low * dt)
					nx.append(iv[q + 1] + vmax * dt)
				nx = _clip(_merge(nx), k, g, _state_bits[st], steps, n_g)
				_iv[st] = nx
				if not nx.is_empty():
					alive = true
			if not alive:
				fail_t = t
				return false
	return true


## At a decision point: finished half moves land on either end, positions may start a
## half move toward either neighbor, moves in progress advance one step.
func _decide(n_pos: int, hm: int) -> void:
	# Landing (last stage of each pair -> both ends).
	for p in n_pos - 1:
		var last := n_pos + p * hm + hm - 1
		var iv := _iv[last]
		if iv.is_empty():
			continue
		_union_into(p, iv)
		_union_into(p + 1, iv)
	# Advance stages (from the end, so each moves one step).
	for p in n_pos - 1:
		var base := n_pos + p * hm
		for m in range(hm - 1, 0, -1):
			_iv[base + m] = _iv[base + m - 1].duplicate()
		_iv[base].clear()
	# Start half moves from the (possibly just landed) positions.
	for p in n_pos - 1:
		var base := n_pos + p * hm
		_union_into(base, _iv[p])
		_union_into(base, _iv[p + 1])
	# Clear landed pairs' last stage (already copied forward or landed).
	# (With hm == 1 the start just refilled it: nothing to clear.)


func _union_into(st: int, src: PackedFloat64Array) -> void:
	if src.is_empty():
		return
	var a := _iv[st].duplicate()
	a.append_array(src)
	_iv[st] = _merge(a)


## A flat [lo, hi, ...] list sorted by lo with overlaps merged.
func _merge(a: PackedFloat64Array) -> PackedFloat64Array:
	var n := a.size() >> 1
	if n <= 1:
		return a
	_order.resize(n)
	for q in n:
		_order[q] = q
	# Insertion sort by lo (lists are tiny).
	for q in range(1, n):
		var x := _order[q]
		var r := q - 1
		while r >= 0 and a[2 * _order[r]] > a[2 * x]:
			_order[r + 1] = _order[r]
			r -= 1
		_order[r + 1] = x
	var out := PackedFloat64Array()
	for q in n:
		var lo := a[2 * _order[q]]
		var hi := a[2 * _order[q] + 1]
		var m := out.size()
		if m > 0 and lo <= out[m - 1]:
			out[m - 1] = maxf(out[m - 1], hi)
		else:
			out.append(lo)
			out.append(hi)
	return out


## Removes from `a` every s blocked at sub-step g (decision step k) for the grid bits.
func _clip(a: PackedFloat64Array, k: int, g: int, bits: int, steps: int, n_g: int) -> PackedFloat64Array:
	for oi in _cand:
		if a.is_empty():
			return a
		if (_mask[oi * steps + k] & bits) == 0:
			continue
		var c := _ps[oi * (n_g + 1) + g]
		var bl := c - _hl[oi]
		var bh := c + _hl[oi]
		if bh <= a[0] or bl >= a[a.size() - 1]:
			continue
		var out := PackedFloat64Array()
		for q in range(0, a.size(), 2):
			var lo := a[q]
			var hi := a[q + 1]
			if hi <= bl or lo >= bh:
				out.append(lo)
				out.append(hi)
				continue
			if lo < bl:
				out.append(lo)
				out.append(bl)
			if hi > bh:
				out.append(bh)
				out.append(hi)
		a = out
	return a


## The player's body (+ clearance) already overlaps a hull at t0.
func _in_contact(ts: TrafficState, player: VehicleState) -> bool:
	for i in _obs:
		if absf(ts.s[i] - player.s) < (ts.length[i] + player_length) * 0.5 + clearance \
				and absf(ts.d[i] - player.d) < (ts.width[i] + player_width) * 0.5 + clearance:
			return true
	return false


## Forward prediction of the obstacles: s at every sub-step, blocked grid bits per step.
func _predict(ts: TrafficState, road: RoadPath, n_obs: int, steps: int, n_sub: int, dt: float, lw: float) -> void:
	var n_g := steps * n_sub
	_ps.resize(n_obs * (n_g + 1))
	_mask.resize(n_obs * steps)
	_hl.resize(n_obs)
	# Lateral span per obstacle: current d, final d, when the lateral move runs.
	var d_now := PackedFloat64Array()
	var d_fin := PackedFloat64Array()
	var t_mv0 := PackedFloat64Array()   # move start (s into the horizon)
	var t_mv1 := PackedFloat64Array()   # move end (INF = holds both lanes to the horizon)
	d_now.resize(n_obs)
	d_fin.resize(n_obs)
	t_mv0.resize(n_obs)
	t_mv1.resize(n_obs)
	for oi in n_obs:
		var i := _obs[oi]
		_hl[oi] = (ts.length[i] + player_length) * 0.5 + clearance
		var d := ts.d[i]
		d_now[oi] = d
		d_fin[oi] = d
		t_mv0[oi] = INF
		t_mv1[oi] = INF
		var st := ts.lc_state[i]
		if st == TrafficState.LaneChange.NONE:
			continue
		var s := ts.s[i]
		var target := d
		if ts.target_lane[i] != ts.lane[i]:
			target = road.lane_center_d(ts.target_lane[i], s)
		elif (ts.flags[i] & TrafficState.FLAG_BLINKER_LEFT) != 0:
			target = d - lw * 0.5
		elif (ts.flags[i] & TrafficState.FLAG_BLINKER_RIGHT) != 0:
			target = d + lw * 0.5
		if st == TrafficState.LaneChange.SIGNALING:
			d_fin[oi] = target
			t_mv0[oi] = maxf(0.0, ts.lc_duration[i] - ts.lc_timer[i])
			t_mv1[oi] = t_mv0[oi] + registry.move_max_s[ts.profile_id[i]]
		else:
			var dur := maxf(ts.lc_duration[i], 1e-6)
			var u := clampf(ts.lc_timer[i] / dur, 0.0, 1.0)
			var sm := u * u * (3.0 - 2.0 * u)
			var d0 := ts.lc_start_d[i]
			d_fin[oi] = d0 + (d - d0) / sm if sm > 1e-3 else target
			d_now[oi] = d0   # smoothstep origin: _d_at(0) is the current d
			t_mv0[oi] = -ts.lc_timer[i]
			t_mv1[oi] = dur - ts.lc_timer[i]
	# Longitudinal: front to back, constant speed, queued behind the leader on its path.
	var order := PackedInt32Array()
	order.resize(n_obs)
	for oi in n_obs:
		order[oi] = oi
	var sorted_order := Array(order)
	sorted_order.sort_custom(func(a: int, b: int) -> bool: return ts.s[_obs[a]] > ts.s[_obs[b]])
	for q in n_obs:
		var oi: int = sorted_order[q]
		var i := _obs[oi]
		var lo := minf(d_now[oi], d_fin[oi]) - ts.width[i] * 0.5
		var hi := maxf(d_now[oi], d_fin[oi]) + ts.width[i] * 0.5
		var lead := -1
		var lead_s := INF
		for r in q:
			var oj: int = sorted_order[r]
			var j := _obs[oj]
			var jlo := minf(d_now[oj], d_fin[oj]) - ts.width[j] * 0.5
			var jhi := maxf(d_now[oj], d_fin[oj]) + ts.width[j] * 0.5
			if jlo < hi and jhi > lo and ts.s[j] < lead_s:
				lead = oj
				lead_s = ts.s[j]
		var s_i := ts.s[i]
		var v_i := ts.v[i]
		var floor_gap := 0.0
		var half := 0.0
		if lead >= 0:
			var j := _obs[lead]
			half = (ts.length[i] + ts.length[j]) * 0.5
			floor_gap = clampf(ts.s[j] - s_i - half, 0.0, registry.s0[ts.profile_id[i]])
		var base := oi * (n_g + 1)
		_ps[base] = s_i
		for g in range(1, n_g + 1):
			var x := s_i + v_i * float(g) * dt
			if lead >= 0:
				x = minf(x, _ps[lead * (n_g + 1) + g] - half - floor_gap)
			_ps[base + g] = maxf(x, _ps[base + g - 1])
	# Lateral: blocked grid bits per decision step.
	for oi in n_obs:
		var i := _obs[oi]
		var hw := ts.width[i] * 0.5 + player_width * 0.5 + clearance
		for k in steps:
			var ta := float(k) * step
			var tb := float(k + 1) * step
			var da := _d_at(oi, ta, d_now, d_fin, t_mv0, t_mv1)
			var db := _d_at(oi, tb, d_now, d_fin, t_mv0, t_mv1)
			var lo := minf(da, db)
			var hi := maxf(da, db)
			var bits := 0
			for j in _pos_d.size():
				if _pos_d[j] - hw < hi and _pos_d[j] + hw > lo:
					bits |= 1 << j
			_mask[oi * steps + k] = bits


func _d_at(oi: int, t: float, d_now: PackedFloat64Array, d_fin: PackedFloat64Array, t_mv0: PackedFloat64Array,
		t_mv1: PackedFloat64Array) -> float:
	if is_inf(t_mv1[oi]):
		return d_now[oi]   # no lateral move
	var dur := t_mv1[oi] - t_mv0[oi]
	var u := clampf((t - t_mv0[oi]) / dur, 0.0, 1.0)
	return d_now[oi] + (d_fin[oi] - d_now[oi]) * u * u * (3.0 - 2.0 * u)
