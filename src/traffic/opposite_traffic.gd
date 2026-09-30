class_name OppositeTraffic
extends RefCounted
## Visual-only traffic on the opposite carriageway. Spec: Traffic → Spawning and the
## opposite carriageway ("visual-only traffic across the median. It runs at constant
## speed with no collision and at lower density, and shows headlights at night").
## See docs/CONTRACTS.md §5 (its own TrafficState, d < 0, moving toward -s, v = speed)
## and docs/SPAWNING.md.
##
## No IDM, no lane changes, no collisions: every vehicle keeps its lane's constant
## speed, so vehicles in a lane never close on each other. The count is held at a
## target (the opposite share of the leg's density over the visible window); a vehicle
## that passes behind the camera is recycled to beyond the fog end ahead (placed past
## its lane's front-most vehicle), so the count stays stable and nothing pops in.
## step() allocates nothing.
##
## Tick cost (WP4.6): s moves every tick (the view interpolates between ticks), but
## the lane-center d, the only road query per vehicle, is refreshed at the far-traffic
## rate (TrafficTuning.far_tick_ratio(): 30 Hz), a quarter of the vehicles per tick,
## like far traffic in TrafficSim. A lane's center only moves where the road's cross-
## section changes, so this is invisible. The top-up search runs only when the count
## is off target.

var state: TrafficState
## Distance ahead of the player where recycled vehicles appear (the director's ahead
## distance: beyond the fog end).
var ahead_m: float
## Recycles performed (metrics, tests).
var recycled: int = 0

var _tt: TrafficTuning
var _road: RoadPath
var _flow: SpawnSources.Flow
var _ctx: SpawnSource.Context
var _rng: Rng
var _rec := SpawnSource.Record.new()
var _density_per_km_lane: float = 0.0   ## opposite side (already scaled by the share)
var _target_count: int = 0
var _night: bool = false
var _front := PackedFloat64Array()   ## scratch: front-most s per lane
## Lane-center refresh: slot i refreshes d on ticks where i % _d_ratio == _d_phase.
var _d_ratio: int = 1
var _d_phase: int = 0


## `mix_ctx` is read for the driver/vehicle mix (leg, aggressive share, hesitant, biome
## palette); the director passes its own shared Context. `rng` is this side's stream.
func _init(traffic_tuning: TrafficTuning, road: RoadPath, flow: SpawnSources.Flow, mix_ctx: SpawnSource.Context,
		rng: Rng, ahead_distance_m: float) -> void:
	_tt = traffic_tuning
	_road = road
	_flow = flow
	_ctx = mix_ctx
	_rng = rng
	ahead_m = ahead_distance_m
	state = TrafficState.new(_tt.opposite_max_vehicles)
	_front.resize(_tt.lane_flow_speeds_from_right_kmh.size())
	_d_ratio = _tt.far_tick_ratio()


## Clears and fills the whole window [player_s - recycle_behind, player_s + ahead_m]
## evenly for `player_density_per_km_lane` (the player side's density; the opposite
## share is applied here). Director rate.
func reset(player_s: float, player_density_per_km_lane: float) -> void:
	state.clear()
	recycled = 0
	_set_density(player_density_per_km_lane, player_s)
	var lanes := _lane_count(player_s)
	var back := player_s - _tt.opposite_recycle_behind_m
	var window := ahead_m + _tt.opposite_recycle_behind_m
	var jitter := Units.pct_to_frac(_tt.opposite_spacing_jitter_pct)
	for lane in lanes:
		var per_lane := floori(float(_target_count) / float(lanes)) + (1 if lane < _target_count % lanes else 0)
		if per_lane <= 0:
			continue
		var cell := window / float(per_lane)
		for k in per_lane:
			var s := back + (float(k) + 0.5 + (_rng.unit() - 0.5) * jitter) * cell
			_place(s, lane, lanes)


## The leg's (player-side) density changed. The count follows through recycling.
func set_density(player_density_per_km_lane: float, player_s: float) -> void:
	_set_density(player_density_per_km_lane, player_s)


func set_night(on: bool) -> void:
	_night = on
	for i in state.capacity:
		if state.active[i] == 1:
			state.set_flag(i, TrafficState.FLAG_HEADLIGHTS, on)


func target_count() -> int:
	return _target_count


## Density actually shown, per km per lane over the window (metrics, tests).
func density_per_km_lane() -> float:
	return _density_per_km_lane


## Per tick: move toward -s at constant speed, recycle what passed behind the camera,
## keep the count at the target. Allocation-free.
func step(dt: float, player_s: float) -> void:
	var back := player_s - _tt.opposite_recycle_behind_m
	_d_phase = (_d_phase + 1) % _d_ratio
	# Packed arrays are shared by reference: locals skip a property lookup per access.
	var active := state.active
	var ss := state.s
	var vv := state.v
	for i in state.capacity:
		if active[i] == 0:
			continue
		var s := ss[i] - vv[i] * dt
		ss[i] = s
		if s < back:
			state.free_slot(i)
			recycled += 1
		elif i % _d_ratio == _d_phase:
			state.d[i] = _road.opposite_lane_center_d(state.lane[i], s)
	if state.count == _target_count:
		return
	while state.count > _target_count:
		state.free_slot(_furthest())
	while state.count < _target_count:
		if not _step_place_ahead(player_s):
			break


## Places one vehicle beyond the fog in the lane whose front-most vehicle is furthest
## back (most room), past that front by a jittered mean spacing. Allocation-free.
func _step_place_ahead(player_s: float) -> bool:
	var line := player_s + ahead_m
	var lanes := _lane_count(line)
	for lane in lanes:
		_front[lane] = -INF
	for i in state.capacity:
		if state.active[i] == 1 and state.lane[i] < lanes:
			_front[state.lane[i]] = maxf(_front[state.lane[i]], state.s[i])
	var lane := 0
	for l in lanes:
		if _front[l] < _front[lane]:
			lane = l
	var jitter := Units.pct_to_frac(_tt.opposite_spacing_jitter_pct)
	var spacing := Units.M_PER_KM / _density_per_km_lane * _rng.float_range(1.0 - jitter, 1.0 + jitter)
	var s := maxf(_front[lane] + spacing, line)
	s = minf(s, maxf(line, _road.length_generated()))
	return _place(s, lane, lanes)


func _place(s: float, lane: int, lanes: int) -> bool:
	if not _flow.draw_into(_ctx, _rng, lane, lanes, 0.0, _rec):
		return false
	var i := state.allocate()
	if i < 0:
		return false
	var v := _lane_speed(lane, lanes)
	state.s[i] = s
	state.d[i] = _road.opposite_lane_center_d(lane, s)
	state.v[i] = v
	state.v0[i] = v
	state.length[i] = _flow.length_of(_rec.type_id)
	state.width[i] = _flow.width_of(_rec.type_id)
	state.lane[i] = lane
	state.target_lane[i] = lane
	state.type_id[i] = _rec.type_id
	state.profile_id[i] = _rec.profile_id
	state.model_variant[i] = _rec.model_variant
	state.color_index[i] = _rec.color_index
	state.flags[i] = TrafficState.FLAG_HEADLIGHTS if _night else 0
	return true


## Constant speed of opposite lane `lane` of `lanes` (0 = next to the median, fastest).
func _lane_speed(lane: int, lanes: int) -> float:
	return Units.kmh_to_mps(_tt.opposite_speed_kmh + float(lanes - 1 - lane) * _tt.opposite_lane_speed_step_kmh)


func _lane_count(s: float) -> int:
	return mini(_road.lane_count(s), _front.size())


func _furthest() -> int:
	var best := -1
	for i in state.capacity:
		if state.active[i] == 1 and (best < 0 or state.s[i] > state.s[best]):
			best = i
	return best


func _set_density(player_density_per_km_lane: float, player_s: float) -> void:
	_density_per_km_lane = player_density_per_km_lane * Units.pct_to_frac(_tt.opposite_density_pct)
	var window_km := (ahead_m + _tt.opposite_recycle_behind_m) / Units.M_PER_KM
	var want := roundi(_density_per_km_lane * window_km * float(_lane_count(player_s)))
	_target_count = clampi(want, 0, state.capacity)
