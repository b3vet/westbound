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
##   - stays on the driving lanes (no shoulders) where they are: WP6.10, a lane that
##     ends (the road's right edge, RoadPath.lanes_right_edge_d, sampled every
##     EDGE_SAMPLE_M and one sample wider at both ends) or that the traffic sim closes
##     (`zones`: road works, a merge zone's lane end, the road's drops synced into the
##     sim) is a static obstacle for every grid position whose body overlaps it; a lane
##     that opens within the horizon is on the grid from where it exists;
##   - never comes within clearance_m (0.3 m) of a predicted hull (full body boxes,
##     axis-aligned in road space, grown by the clearance on every side).
## Traffic prediction (simplified; passability.gd forward-simulates the real models):
##   - vehicles fully behind the player at t0 are ignored: they follow the player (IDM
##     with the player as leader, Lives → rear-end prevention) instead of driving into it;
##   - every other vehicle drives with bounded acceleration toward its desired speed
##     (WP6.10: IDM's free-road term a_max (1 - (v / v0)^delta), clamped at the
##     traffic's max_decel_mps2; v0 capped by the sim's speed and lane-drop zones), but
##     never drives through the vehicle ahead of it on its lateral path (it queues
##     behind it at min(s0, its current gap)), nor into a closure of its lane before
##     its lane change out of it starts (it stops merge_stop_margin_m before it);
##   - a MOVING lane change continues its smoothstep to its final d; a SIGNALING one is
##     assumed to happen: it starts at the end of its signal time and takes the
##     profile's longest move time (it may still cancel, which only frees space); a
##     lane-splitting bike keeps riding the boundary.
## Anti-tunneling: positions are propagated in sub-steps short enough that neither the
## player nor any vehicle can jump over the shortest hull-plus-clearance block.
##
##   var iw := ImpossibleWindowChecker.new(tuning, registry, car)
##   iw.zones = sim                                         # optional: the sim's closures and zones
##   if not iw.is_passable(sim.state, player, road): ...   # iw.fail_t, iw.lanes, ...

const MAX_STATES := 64
## A sub-step moves the player at most this fraction of the shortest block (< 1: no tunneling).
const SUB_STEP_BLOCK_FRAC := 0.9
## CarDef.zero_to_200_s is the time to this speed (mean acceleration = speed / time).
const ZERO_TO_KMH := 200.0
## Lane ends: the right edge is sampled this often (m) where the lane count changes; a
## closed stretch is widened by one sample at both ends. Lane counts are compared every
## LANE_SCAN_M first (no change and no taper: no lane end in the corridor).
const EDGE_SAMPLE_M := 2.0
const LANE_SCAN_M := 50.0
## A player body this far beyond the right edge or into a closed lane is outside
## (TrafficRuleChecker's off-road tolerance).
const EDGE_TOL_M := 0.05

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
var max_decel: float
var merge_stop: float

## The traffic sim's lane closures and zones (WP6.10), read when set: anything with
## lane_closure_count(), closure_ahead(lane, s), speed_zone_count(), speed_limit_at(lane,
## front, profile), lane_drop_zone_count() and lane_drop_limit_at(lane, front, profile)
## (TrafficSim's public queries); anything else is ignored (null). The same sources
## passability.gd reads; the code here is written independently.
var zones: Object:
	set(v):
		zones = v if v != null and v.has_method(&"lane_closure_count") and v.has_method(&"closure_ahead") \
			and v.has_method(&"speed_zone_count") and v.has_method(&"speed_limit_at") \
			and v.has_method(&"lane_drop_zone_count") and v.has_method(&"lane_drop_limit_at") else null

# Results of the last check.
var checks := 0
var impossible := 0
## Seconds into the horizon at which every path had ended (the last check; INF = passable).
var fail_t := INF
## Grid positions and obstacles of the last check.
var positions := 0
var obstacles := 0
## The player overlapped a hull (+ clearance) already at t0 in the last check, or its
## body was already in a closed lane or beyond the lanes' right edge (started_in_closure).
var started_in_contact := false
var started_in_closure := false
## Static road obstacles (lane ends and closures) of the last check.
var road_obstacles := 0

# Scratch (reused between checks).
var _obs := PackedInt32Array()
var _ps := PackedFloat64Array()    # predicted s, [o * (n_sub_total + 1) + g]
var _pv := PackedFloat64Array()    # predicted v, same layout (vehicles only)
var _st_a := PackedFloat64Array()  # static obstacles: player-center s range blocked
var _st_b := PackedFloat64Array()
var _st_bits := PackedInt32Array() # ... at these grid positions
var _cl_open := PackedFloat64Array()
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
	max_decel = t.traffic.max_decel_mps2
	merge_stop = t.traffic.merge_stop_margin_m
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
	started_in_closure = false
	var s0 := player.s
	# Never slower than the minimum speed, or than the player already is: a player below
	# it (e.g. keeping its lane behind a truck) may hold its speed, not jump to 100 km/h.
	var v_low := minf(min_speed, maxf(player.v, 0.0))
	var v_start := maxf(player.v, v_low)
	var steps := ceili(horizon / step - 1e-9)
	var v_end := minf(v_start + accel * horizon, maxf(top_speed, v_start))
	var lw := road.lane_width(s0)
	var grid := lat_step_lanes * lw
	var d_first := road.lane_center_d(0, s0)
	# The corridor the player's body can reach, and the grid over every lane in it: a
	# lane still tapering away at s0, and a lane that opens ahead (the right edge blocks
	# it until it exists).
	var r_lo := s0 - player_length
	var r_hi := s0 + v_end * horizon + player_length
	var left := road.lanes_left_edge_d(s0)
	var lanes := maxi(road.lane_count(s0), ceili((road.lanes_right_edge_d(s0) - left) / lw - 1e-6))
	var uniform := absf(road.lanes_right_edge_d(s0) - left - float(road.lane_count(s0)) * lw) < 1e-6
	var sx := s0
	while sx < r_hi:
		sx = minf(sx + LANE_SCAN_M, r_hi)
		var n := road.lane_count(sx)
		if n != road.lane_count(s0) or absf(road.lanes_right_edge_d(sx) - left - float(n) * lw) > 1e-6:
			uniform = false
		lanes = maxi(lanes, n)
	var d_last := road.lane_center_d(lanes - 1, s0)
	var n_pos := roundi((d_last - d_first) / grid) + 1
	positions = n_pos
	_pos_d.resize(n_pos)
	for j in n_pos:
		_pos_d[j] = d_first + float(j) * grid
	var half_move_steps := maxi(1, roundi(vehicle_tuning.lane_change_target_s(v_start) * 0.5 / step))
	var n_states := n_pos + (n_pos - 1) * half_move_steps
	assert(n_states <= MAX_STATES, "ImpossibleWindowChecker: too many lanes for MAX_STATES")
	_state_bits.resize(n_states)
	for j in n_pos:
		_state_bits[j] = 1 << j
	for p in n_pos - 1:
		for m in half_move_steps:
			_state_bits[n_pos + p * half_move_steps + m] = (1 << p) | (1 << (p + 1))
	# Static road obstacles: lanes that end, lanes the sim closes.
	_st_a.clear()
	_st_b.clear()
	_st_bits.clear()
	if not uniform:
		_load_lane_ends(road, r_lo, r_hi)
	_load_closures(left, lw, lanes, r_lo, r_hi)
	var n_st := _st_a.size()
	road_obstacles = n_st
	started_in_closure = _in_closure(road, player, left, lw, lanes)

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
	for q in n_st:
		min_block = minf(min_block, _st_b[q] - _st_a[q])
	# Sub-steps: nothing may cross the shortest block within one sub-step.
	var n_sub := 1
	if n_obs + n_st > 0:
		n_sub = maxi(1, ceili(step * v_end / (SUB_STEP_BLOCK_FRAC * min_block)))
	var dt := step / float(n_sub)
	var n_g := steps * n_sub
	_predict(ts, road, n_obs, steps, n_sub, dt, lw)
	_place_statics(n_obs, n_st, steps, n_g)
	n_obs += n_st

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
	started_in_contact = _in_contact(ts, player) or started_in_closure

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


## Lanes that end (WP6.10): per grid position, the stretches where the player's body
## there would stick out beyond the right edge of the driving lanes (sampled every
## EDGE_SAMPLE_M, one sample wider at both ends) block the player's center wherever its
## body would overlap them.
func _load_lane_ends(road: RoadPath, lo: float, hi: float) -> void:
	var hw := player_width * 0.5
	var n_pos := _pos_d.size()
	_cl_open.resize(n_pos)
	_cl_open.fill(NAN)
	var n := ceili((hi - lo) / EDGE_SAMPLE_M)
	for k in n + 1:
		var x := lo + float(k) * EDGE_SAMPLE_M
		var edge := road.lanes_right_edge_d(x) + EDGE_TOL_M
		for j in n_pos:
			var out := _pos_d[j] + hw > edge
			if out and is_nan(_cl_open[j]):
				_cl_open[j] = x - EDGE_SAMPLE_M
			elif not out and not is_nan(_cl_open[j]):
				_add_static(_cl_open[j], x, 1 << j)
				_cl_open[j] = NAN
	for j in n_pos:
		if not is_nan(_cl_open[j]):
			_add_static(_cl_open[j], hi + EDGE_SAMPLE_M, 1 << j)


## The sim's lane closures (zones): each closed stretch of a lane blocks every grid
## position whose body overlaps that lane (its center and both half-lanes). The start
## is exact (closure_ahead), the end sampled every EDGE_SAMPLE_M (one sample late).
func _load_closures(left: float, lw: float, lanes: int, lo: float, hi: float) -> void:
	if zones == null or int(zones.call(&"lane_closure_count")) == 0:
		return
	var hw := player_width * 0.5
	for lane in lanes:
		var l_lo := left + float(lane) * lw + EDGE_TOL_M
		var l_hi := left + float(lane + 1) * lw - EDGE_TOL_M
		var bits := 0
		for j in _pos_d.size():
			if _pos_d[j] - hw < l_hi and _pos_d[j] + hw > l_lo:
				bits |= 1 << j
		var a := lo + float(zones.call(&"closure_ahead", lane, lo))
		while a <= hi:
			var b := a
			while b <= hi and float(zones.call(&"closure_ahead", lane, b)) <= 0.0:
				b += EDGE_SAMPLE_M
			_add_static(a, b, bits)
			a = b + float(zones.call(&"closure_ahead", lane, b))
	# (The road's own lane ends are also in the sim as closures: blocking twice is harmless.)


## A static obstacle: the player's body must not overlap [a, b] at the grid bits.
func _add_static(a: float, b: float, bits: int) -> void:
	_st_a.append(a - player_length * 0.5)
	_st_b.append(b + player_length * 0.5)
	_st_bits.append(bits)


## The static obstacles as obstacle rows n_obs.. (constant s, every step's mask).
func _place_statics(n_obs: int, n_st: int, steps: int, n_g: int) -> void:
	var n := n_obs + n_st
	_ps.resize(n * (n_g + 1))
	_mask.resize(n * steps)
	_hl.resize(n)
	for q in n_st:
		var oi := n_obs + q
		var c := (_st_a[q] + _st_b[q]) * 0.5
		_hl[oi] = (_st_b[q] - _st_a[q]) * 0.5
		var base := oi * (n_g + 1)
		for g in n_g + 1:
			_ps[base + g] = c
		for k in steps:
			_mask[oi * steps + k] = _st_bits[q]


## The player's own body is already in a closed lane or beyond the right edge at t0.
func _in_closure(road: RoadPath, player: VehicleState, left: float, lw: float, lanes: int) -> bool:
	var hw := player_width * 0.5
	var edge := minf(road.lanes_right_edge_d(player.s), minf(road.lanes_right_edge_d(player.s - player_length * 0.5),
		road.lanes_right_edge_d(player.s + player_length * 0.5)))
	if player.d + hw > edge + EDGE_TOL_M:
		return true
	if zones == null or int(zones.call(&"lane_closure_count")) == 0:
		return false
	for lane in lanes:
		var l_lo := left + float(lane) * lw + EDGE_TOL_M
		var l_hi := left + float(lane + 1) * lw - EDGE_TOL_M
		if player.d - hw < l_hi and player.d + hw > l_lo \
				and float(zones.call(&"closure_ahead", lane, player.s - player_length * 0.5)) <= player_length:
			return true
	return false


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
	_pv.resize(n_obs * (n_g + 1))
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
	# Longitudinal: front to back, bounded acceleration toward the desired speed, queued
	# behind the leader on its lateral path and stopped before a closure of its lane.
	var order := PackedInt32Array()
	order.resize(n_obs)
	for oi in n_obs:
		order[oi] = oi
	var sorted_order := Array(order)
	sorted_order.sort_custom(func(a: int, b: int) -> bool: return ts.s[_obs[a]] > ts.s[_obs[b]])
	var sz := zones != null and int(zones.call(&"speed_zone_count")) > 0
	var dz := zones != null and int(zones.call(&"lane_drop_zone_count")) > 0
	var cz := zones != null and int(zones.call(&"lane_closure_count")) > 0
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
		var v_i := maxf(ts.v[i], 0.0)
		var hl_i := ts.length[i] * 0.5
		var p := ts.profile_id[i]
		var floor_gap := 0.0
		var half := 0.0
		if lead >= 0:
			var j := _obs[lead]
			half = (ts.length[i] + ts.length[j]) * 0.5
			floor_gap = clampf(ts.s[j] - s_i - half, 0.0, registry.s0[p])
		# A closure of its lane ahead: it stops merge_stop before it (or where it is, if
		# already closer) until its lane change out of the lane starts.
		var wall := INF
		if cz:
			var ahead := float(zones.call(&"closure_ahead", ts.lane[i], s_i + hl_i))
			if not is_inf(ahead):
				wall = s_i + maxf(ahead - merge_stop, 0.0)
		# Lane-splitting motorbikes (riding a lane line, no lane change) keep their speed.
		var accel_on := not (registry.is_motorbike[ts.type_id[i]] == 1 \
			and ts.lc_state[i] == TrafficState.LaneChange.NONE \
			and absf(ts.d[i] - road.lane_center_d(ts.lane[i], s_i)) > lw * 0.25)
		var v0 := ts.v0[i]
		var a_max := registry.a_max[p]
		var delta := registry.delta[p]
		var base := oi * (n_g + 1)
		_ps[base] = s_i
		_pv[base] = v_i
		var x := s_i
		var v := v_i
		for g in range(1, n_g + 1):
			var t := float(g) * dt
			var nv := v
			if accel_on and v0 > 0.0:
				var ve := v0
				if sz or dz:
					var ln := ts.lane[i] if t < t_mv1[oi] else ts.target_lane[i]
					if sz:
						ve = minf(ve, float(zones.call(&"speed_limit_at", ln, x + hl_i, p)))
					if dz:
						ve = minf(ve, float(zones.call(&"lane_drop_limit_at", ln, x + hl_i, p)))
				var a := maxf(Idm.free_accel(v, maxf(ve, 0.01), a_max, delta), -max_decel)
				nv = maxf(v + a * dt, 0.0)
			var nx := x + (v + nv) * 0.5 * dt
			if lead >= 0:
				var cap := _ps[lead * (n_g + 1) + g] - half - floor_gap
				if nx > cap:
					nx = cap
					nv = minf(nv, _pv[lead * (n_g + 1) + g])
			if t < t_mv0[oi] and nx > wall:
				nx = wall
				nv = 0.0
			nx = maxf(nx, x)
			_ps[base + g] = nx
			_pv[base + g] = nv
			x = nx
			v = nv
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
