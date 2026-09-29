class_name MergeZonePiece
extends SetPieceSource.Controller
## Merge zone (WP6.3). Spec: Traffic → Traffic director, set-piece table: "Merge zone |
## On-ramp adds traffic from the right, then the right lane ends | Signs 500 m and 250 m
## ahead"; World → Road (lane counts, tapers). docs/SET_PIECES.md.
##
## Road-anchored. The zone starts at the ramp nose. setup_zone() puts its road hooks in:
##   - the road gains a lane on the right at the nose (ProceduralRoadPath
##     .schedule_lane_count, over ramp_join_taper_m): the acceleration lane, where the
##     on-ramp joins; it ends accel_lane_m later (back to the old count over
##     lane_end_taper_m). The road mesh, the roadside and the barrier follow the tapers.
##   - the player-side guardrail is open over the join taper (add_rail_gap): the view
##     draws the on-ramp ribbon coming in from the right, its gore and its own rail.
##   - the sim closes the acceleration lane over both tapers (tag = the serial), so
##     traffic in it merges left before it ends (the mandatory merge: telegraphed,
##     no-ambush) and no Flow traffic spawns into it near its end.
## Ramp traffic: vehicles_min .. vehicles_max cars in the acceleration lane, planned in
## the batch that reaches it (beyond the fog). They come off the ramp slowly (between
## ramp_min_speed_kmh and ramp_speed_kmh: each paced to be ramp_goal_frac into the lane,
## in its order, when the player is ramp_go_s from reaching it at the closing speed),
## held out of the mandatory merge (TrafficSim.set_merge_hold); then they speed up to
## the piece's speed and merge left, in front of the player: the merge zone. A car that
## finds no gap waits at the end of the lane (the sim's closure wall).

## The road lanes before the zone (the acceleration lane's index).
var accel_lane: int = 0
var nose_s: float = 0.0
var join_end_s: float = 0.0
var lane_end_s: float = 0.0
## Ramp cars sent on so far (tests, dev).
var released: int = 0


func setup_zone(src: SetPieceSource, inst: SetPieceSource.Instance) -> bool:
	var d := inst.def
	var road := src.road as ProceduralRoadPath
	if road == null or not src.can_zone:
		return false
	accel_lane = inst.lanes
	nose_s = inst.zone_s0
	join_end_s = nose_s + d.ramp_join_taper_m
	lane_end_s = join_end_s + d.accel_lane_m
	inst.zone_s1 = lane_end_s + d.lane_end_taper_m
	# The sim first (it can refuse when full); the road hooks cannot be taken back.
	var sim := src.sim
	if not bool(sim.call(&"add_lane_closure", accel_lane, nose_s, join_end_s, inst.serial)) \
			or not bool(sim.call(&"add_lane_closure", accel_lane, lane_end_s, inst.zone_s1, inst.serial)):
		return false
	road.schedule_lane_count(nose_s, inst.lanes + 1, d.ramp_join_taper_m)
	road.schedule_lane_count(lane_end_s, inst.lanes, d.lane_end_taper_m)
	road.add_rail_gap(nose_s, join_end_s)
	return true


## The ramp cars are planned where the acceleration lane is full width.
func vehicles_rear_s(_src: SetPieceSource, inst: SetPieceSource.Instance) -> float:
	if inst.def.vehicles_max <= 0:
		return INF
	return join_end_s


func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: SetPieceSource.Instance) -> void:
	var d := inst.def
	var v := Units.kmh_to_mps(d.ramp_speed_kmh)
	var n := src.rng.int_range(d.vehicles_min, d.vehicles_max)
	var s := inst.s_rear
	# The last car keeps clear of the stop before the lane's end.
	var last := lane_end_s - ctx.run.tuning.traffic.merge_stop_margin_m
	for k in n:
		var rec := SpawnSource.Record.new()
		if not src.draw_vehicle(ctx, inst, accel_lane, rec):
			continue
		var ln := src.flow.length_of(rec.type_id)
		var c := s + ln * 0.5
		if c + ln * 0.5 > last:
			break
		rec.s = c
		rec.v = v
		src.add_record(inst, rec, k)
		s = c + ln * 0.5 + src.flow.min_spacing(rec.profile_id, v, ln, v, ln) - ln + d.vehicle_extra_gap_m


func on_bound(src: SetPieceSource, inst: SetPieceSource.Instance) -> void:
	var v := Units.kmh_to_mps(inst.def.ramp_speed_kmh)
	mark_formation(src, inst)
	for k in inst.n:
		src.set_v0_unfloored(inst, k, v)
		src.merge_hold(inst, k, true)


func step(src: SetPieceSource, inst: SetPieceSource.Instance, _dt: float, player: VehicleState) -> void:
	var d := inst.def
	var v_lo := Units.kmh_to_mps(d.ramp_min_speed_kmh)
	var v_hi := Units.kmh_to_mps(d.ramp_speed_kmh)
	var last := lane_end_s - src.state.length[inst.slot[0]] if inst.n > 0 else lane_end_s
	var goal0 := join_end_s + d.accel_lane_m * d.ramp_goal_frac
	for k in inst.n:
		if not src.is_held(inst, k):
			continue
		var i := inst.slot[k]
		var s_i := src.state.s[i]
		# Time until the player reaches it at the closing speed.
		var t := (s_i - player.s) / maxf(player.v - src.state.v[i], v_lo)
		if t <= d.ramp_go_s:
			src.merge_hold(inst, k, false)
			src.set_v0(inst, k, inst.speed)
			released += 1
			continue
		# Paced: at its goal (in formation order) when it is sent on.
		var goal := minf(goal0 + inst.slot_off[k], last)
		src.set_v0_unfloored(inst, k, clampf((goal - s_i) / (t - d.ramp_go_s), v_lo, v_hi))
