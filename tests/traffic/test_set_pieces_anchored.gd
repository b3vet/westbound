extends WBTest
## The road-anchored set pieces of WP6.3: road works, merge zone, tunnel squeeze, toll
## gantry. Spec: Traffic → Traffic director, set-piece table ("Merge zone | On-ramp adds
## traffic from the right, then the right lane ends | Signs 500 m and 250 m ahead";
## "Road works | One or two lanes closed by cones and a barrier; traffic merges | Signs
## 400 m ahead, flashing arrow board"; "Tunnel squeeze | Two lanes, tighter traffic,
## light change at entry and exit | Tunnel portal"; "Toll gantry | Checkpoint landmark:
## booth lanes on the sides, open express lanes in the middle | Signs 1 km and 500 m
## ahead"); Fairness rules 1, 2, 4, 5, 6; Passability guarantee; Lives → what counts as
## a hit. docs/SET_PIECES.md.

const SEED := 630301
const EPS := 1e-6
## A feature-triggered piece is approached from this far (at 200 km/h the player still
## meets its vehicles, planned beyond the fog, in its zone).
const APPROACH_M := 2000.0

var tuning: Tuning
var canyon: BiomeDef


func before_all() -> void:
	tuning = Tuning.load_default()
	canyon = BiomePlan.load_biome(&"canyon")


## The whole run of a piece: every rule the soak gates, plus the works' closed area and
## the prop hits.
func _gate(r: SetPieceRig, what: String) -> void:
	var c := r.checker
	eq(c.collision_pairs, 0, "%s: no traffic collisions" % what)
	eq(c.signal_violations + c.unsignaled_moves, 0, "%s: every lane change telegraphed (rule 1)" % what)
	eq(c.ambush_violations, 0, "%s: no ambush (rule 2)" % what)
	eq(c.decel_violations, 0, "%s: no deceleration beyond 6 m/s^2 (rule 4)" % what)
	eq(c.brake_flag_violations, 0, "%s: readable braking (rule 3)" % what)
	eq(c.offroad_violations, 0, "%s: no traffic outside the driving lanes" % what)
	eq(c.rear_end_normal, 0, "%s: no rear-end of a normally driving player" % what)
	eq(r.closed_area_ticks, 0, "%s: no traffic inside a closed zone" % what)
	if not c.messages.is_empty():
		print("      %s: %s" % [what, c.messages.slice(0, 3)])


# ---------------------------------------------------------------- Data

func test_the_new_pieces_load_with_their_warnings() -> void:
	var defs := SetPieceSource.load_defs(tuning.director)
	var views := tuning.quality.view_distance_m
	var max_view := views[views.size() - 1]
	var spec := {
		&"merge_zone": [500.0, 250.0], &"road_works": [400.0], &"toll_gantry": [1000.0, 500.0],
		&"slalom": [], &"convoy": null, &"tunnel_squeeze": null,
	}
	for id: StringName in spec:
		if not check(defs.has(id), "data/set_pieces/%s.tres" % id):
			continue
		var d: SetPieceDef = defs[id]
		check(SetPieceSource.controller_for(d.kind) != null, "%s has a controller" % id)
		ge(d.speed_mps(0.0), tuning.scoring.min_speed_mps(), "%s never below the minimum speed" % id)
		var want: Variant = spec[id]
		if want != null:
			eq(Array(d.warning_sign_distances_m), want, "%s: the spec's warning distances" % id)
		if d.anchored:
			# Road hooks are decided beyond the view and the road chunks being built; the
			# piece's own signs (merge zone, road works) beyond the view.
			ge(d.schedule_lead_min_m, max_view + tuning.road.chunk_length_m + tuning.road.chunk_prefetch_m,
				"%s: its road hooks are decided beyond the built road" % id)
			if d.warning == SetPieceDef.Warning.SIGNS and d.trigger == SetPieceDef.Trigger.PEAK \
					or d.warning == SetPieceDef.Warning.SIGNS_AND_ARROW_BOARD:
				var far := 0.0
				for w in d.warning_sign_distances_m:
					far = maxf(far, w - d.warning_anchor_m)
				ge(d.schedule_lead_min_m - far, max_view + tuning.road.chunk_prefetch_m,
					"%s: its farthest sign is decided beyond the view" % id)
		check(not d.allows_hard_decel, "%s needs no deceleration beyond the clamp" % id)
	eq(defs[&"convoy"].warning, SetPieceDef.Warning.VISIBLE, "convoy: visible")
	eq(defs[&"slalom"].warning, SetPieceDef.Warning.NONE, "slalom: no warning needed")
	eq(defs[&"tunnel_squeeze"].warning, SetPieceDef.Warning.TUNNEL_PORTAL, "tunnel squeeze: the portal")
	eq(defs[&"toll_gantry"].trigger, SetPieceDef.Trigger.CHECKPOINT)
	eq(defs[&"tunnel_squeeze"].trigger, SetPieceDef.Trigger.TUNNEL)
	check(defs[&"toll_gantry"].is_checkpoint_landmark, "the toll gantry is a checkpoint landmark")


# ---------------------------------------------------------------- Road works

func test_road_works_close_one_or_two_lanes_with_cones_a_barrier_and_an_arrow_board() -> void:
	var sides := {}
	var counts := {}
	for lanes: int in [3, 4]:
		for k in 5:
			var r := SetPieceRig.new(SEED + k * 11 + lanes, lanes)
			var inst := r.force(&"road_works")
			if not check(inst != null, "%d lanes: live" % lanes):
				continue
			var w := inst.controller as RoadWorksPiece
			var n := w.closed_hi - w.closed_lo + 1
			counts[n] = true
			sides[w.side] = true
			ge(n, 1, "one or two lanes closed")
			le(n, 2)
			ge(lanes - n, 2, "the road drops to two lanes at least")
			check(w.side < 0 or w.closed_hi == lanes - 1, "right side: the outermost lanes")
			check(w.side > 0 or w.closed_lo == 0, "left side: from the median")
			# Closed in the sim over the whole zone.
			for lane in lanes:
				var closed := lane >= w.closed_lo and lane <= w.closed_hi
				eq(r.sim.closure_ahead(lane, inst.zone_s0 - 1.0) < 2.0, closed, "lane %d closure" % lane)
			# Cones: from the lane edge, tapering onto the open lanes' edge, back out.
			gt(w.cone_s.size(), 20, "cones")
			for j in range(1, w.cone_s.size()):
				ge(w.cone_s[j], w.cone_s[j - 1], "cones in order along the road")
			near(w.cone_d[0], w.line_start_d, EPS)
			var edge := r.road.lane_center_d(w.closed_lo, inst.zone_s0) - r.road.lane_width(inst.zone_s0) * 0.5 \
				if w.side > 0 else r.road.lane_center_d(w.closed_hi, inst.zone_s0) + r.road.lane_width(inst.zone_s0) * 0.5
			near(w.line_d_at(inst, (w.taper_end_s + w.works_end_s) * 0.5), edge + inst.def.cone_line_inset_m * float(w.side),
				EPS, "along the works the line is the open lanes' edge, inside the closed lane")
			# The barrier and the arrow board stand behind the cones, in the closed lanes.
			check(w.in_closed_area(inst, w.arrow_s, w.arrow_d - inst.def.arrow_board_width_m * 0.5,
				w.arrow_d + inst.def.arrow_board_width_m * 0.5), "the arrow board is in the closed area")
			var open_lane := w.closed_lo - 1 if w.side > 0 else w.closed_hi + 1
			var oc := r.road.lane_center_d(open_lane, w.arrow_s)
			check(not w.in_closed_area(inst, w.arrow_s, oc - 0.9, oc + 0.9), "the next lane is open")
			ge(w.barrier_s0, w.taper_end_s, "the barrier after the taper")
			le(w.barrier_s1, w.works_end_s)
			check(w.in_closed_area(inst, (w.barrier_s0 + w.barrier_s1) * 0.5, w.barrier_d - inst.def.barrier_width_m * 0.5,
				w.barrier_d + inst.def.barrier_width_m * 0.5), "the barrier is in the closed area")
	check(counts.has(1), "one lane closed sometimes")
	check(counts.has(2), "two lanes (on four) sometimes")
	check(sides.has(1) and sides.has(-1), "either side")


func test_road_works_traffic_merges_before_the_cones_and_the_bot_gets_through() -> void:
	var r := SetPieceRig.new(SEED, 3, null, null, 200.0, 1)
	var inst := r.force(&"road_works")
	if not check(inst != null, "live"):
		return
	var w := inst.controller as RoadWorksPiece
	check(r.run_until_ended(inst, 60.0), "ended (the player passed)")
	gt(r.sim.stat_merges, 0, "traffic merged out of the closed lanes")
	_gate(r, "road works")
	eq(r.prop_hits, 0, "the bot never touched a cone, the barrier or the board")
	eq(r.sim.lane_closure_count(), 0, "its closures are gone with it")
	var warn := r.events(SetPieceSource.KIND_WARNING)
	if check(warn.size() == 1, "one warning"):
		near(float(warn[0][3]), 400.0, 5.0, "at 400 m")
	check(r.bot.state.s > w.works_end_s, "the bot drove through")


# ---------------------------------------------------------------- Merge zone

func test_merge_zone_adds_a_ramp_lane_that_ends_and_ramp_cars_merge_left() -> void:
	var r := SetPieceRig.new(SEED + 1, 3, null, null, 200.0, 0)
	var inst := r.force(&"merge_zone")
	if not check(inst != null, "live"):
		return
	var mz := inst.controller as MergeZonePiece
	var d := inst.def
	var road := r.road
	# Road hooks: a lane gained at the nose, lost at the lane end; the rail open at the join.
	eq(road.lane_count(mz.nose_s - 1.0), 3, "3 lanes before the nose")
	eq(road.lane_count(mz.join_end_s + 1.0), 4, "the acceleration lane")
	eq(road.lane_count(inst.zone_s1 + 1.0), 3, "the right lane ends")
	check(road.rail_gap_at((mz.nose_s + mz.join_end_s) * 0.5), "the rail is open where the ramp joins")
	check(not road.rail_gap_at(mz.nose_s - 5.0) and not road.rail_gap_at(mz.join_end_s + 5.0), "only there")
	near(road.lanes_right_edge_d(mz.join_end_s + 1.0) - road.lanes_right_edge_d(mz.nose_s - 1.0),
		road.lane_width(mz.nose_s), 1e-3, "one lane wider")
	le(r.sim.closure_ahead(3, mz.lane_end_s - 1.0), 1.0, "the acceleration lane is closed where it ends")
	# Ramp traffic: planned in the acceleration lane, then merging left.
	var seen := 0
	var merged := 0
	var max_bound := 0
	var serial := inst.serial
	for k in roundi(60.0 / SetPieceRig.DT):
		r.tick()
		if r.dir.set_pieces.instance_by_serial(serial) == null:
			break
		max_bound = maxi(max_bound, inst.n)
		for j in inst.n:
			var i := inst.slot[j]
			if not r.dir.set_pieces.alive(inst, j):
				continue
			if r.sim.state.lane[i] == mz.accel_lane:
				seen = maxi(seen, 1)
			elif r.sim.state.lane[i] < mz.accel_lane:
				merged = maxi(merged, j + 1)
	ge(max_bound, d.vehicles_min, "ramp cars came")
	eq(seen, 1, "in the acceleration lane")
	gt(r.sim.stat_merges, 0, "mandatory merges out of the ending lane")
	ge(mz.released, 1, "ramp cars were sent on as the player came")
	_gate(r, "merge zone")
	var warn := r.events(SetPieceSource.KIND_WARNING)
	if check(warn.size() == 2, "two warnings"):
		near(float(warn[0][3]), 500.0, 5.0, "at 500 m")
		near(float(warn[1][3]), 250.0, 5.0, "and 250 m")


func test_merge_zone_needs_room_for_the_extra_lane() -> void:
	var defs := SetPieceSource.load_defs(tuning.director)
	var d: SetPieceDef = defs[&"merge_zone"]
	check(SetPieceSource.fits_lanes(d, 3), "3 lanes + the acceleration lane")
	check(not SetPieceSource.fits_lanes(d, 4), "never on 4 lanes (the road has at most 4)")


# ---------------------------------------------------------------- Tunnel squeeze

func _canyon_start(def_id: StringName) -> Array:
	# [rig start s, the tunnel's portal] for the first long-enough tunnel far enough on.
	var probe := SetPieceRig.new(SEED, 3, canyon)
	var def: SetPieceDef = probe.dir.set_pieces.defs[def_id]
	var f := probe.feature_s(RoadFeature.Kind.TUNNEL, APPROACH_M, def.tunnel_min_length_m)
	return [f - APPROACH_M, f]


func test_tunnel_squeeze_packs_its_tunnel_and_follows_closer_inside() -> void:
	var at := _canyon_start(&"tunnel_squeeze")
	if not check(not is_nan(float(at[1])), "a canyon tunnel"):
		return
	var r := SetPieceRig.new(SEED, 3, canyon, null, 200.0, 0, float(at[0]), 8)
	var inst := r.force(&"tunnel_squeeze")
	if not check(inst != null, "live"):
		return
	var sq := inst.controller as TunnelSqueezePiece
	near(inst.zone_s0, float(at[1]), EPS, "its zone starts at the portal")
	eq(inst.zone_s1, sq.exit_s, "and ends at the exit")
	eq(inst.lanes, 2, "two lanes")
	eq(r.road.lane_count((sq.portal_s + sq.exit_s) * 0.5), 2)
	near(r.sim.headway_scale_at((sq.portal_s + sq.exit_s) * 0.5), inst.def.headway_scale, EPS, "tighter inside")
	near(r.sim.headway_scale_at(sq.portal_s - 10.0), 1.0, EPS, "not outside")
	var inside := 0
	var serial := inst.serial
	var ended := false
	for k in roundi(80.0 / SetPieceRig.DT):
		r.tick()
		if r.dir.set_pieces.instance_by_serial(serial) == null:
			ended = true
			break
		if r.bot.state.s > sq.portal_s and r.bot.state.s < sq.exit_s and inst.n > 0:
			for j in inst.n:
				var s := r.sim.state.s[inst.slot[j]]
				if s > sq.portal_s and s < sq.exit_s:
					inside += 1
	gt(inside, 0, "the platoon is met inside the tunnel")
	check(ended, "it ended as the player left the tunnel")
	_gate(r, "tunnel squeeze")
	near(r.sim.headway_scale_at((sq.portal_s + sq.exit_s) * 0.5), 1.0, EPS, "its headway zone is gone with it")
	var warn := r.events(SetPieceSource.KIND_WARNING)
	if check(warn.size() == 1, "the portal warns"):
		near(float(warn[0][3]), 400.0, 5.0, "400 m before the portal")


func test_tunnel_light_changes_at_entry_and_exit() -> void:
	var r := SetPieceRig.new(SEED, 3, canyon)
	var portal := r.feature_s(RoadFeature.Kind.TUNNEL, 0.0)
	if not check(not is_nan(portal), "a tunnel"):
		return
	var found: Array[RoadFeature] = []
	r.road.features_in(portal, portal + 1.0, found)
	var exit_s := portal
	for f in found:
		if f.kind == RoadFeature.Kind.TUNNEL:
			exit_s = f.s_end
	var tl := TunnelLight.new(r.road)
	var ramp := tl.def.tunnel_light_ramp_m
	near(tl.factor_at(portal - ramp), 0.0, EPS, "daylight before the portal")
	near(tl.factor_at(portal), 0.5, 1e-3, "half way at the portal")
	near(tl.factor_at((portal + exit_s) * 0.5), 1.0, EPS, "dark inside")
	near(tl.factor_at(exit_s + ramp), 0.0, EPS, "daylight after the exit")
	var prev := 0.0
	var s := portal - ramp
	while s < portal + ramp:
		ge(tl.factor_at(s), prev - EPS, "the light changes smoothly at the entry")
		prev = tl.factor_at(s)
		s += 1.0


# ---------------------------------------------------------------- Toll gantry

## The toll test: a car in a booth lane within this far past the zone's start came in on
## it; nobody at the booths is above the booth speed x BOOTH_GROSS_FACTOR.
const BOOTH_ENTRY_WINDOW_M := 30.0
const BOOTH_GROSS_FACTOR := 1.5


func _toll_rig(v_kmh: float, lane: int) -> SetPieceRig:
	var cp := tuning.legs.leg_length_m()
	var r := SetPieceRig.new(SEED, 3, null, null, v_kmh, lane, cp - APPROACH_M)
	r.all_tolls()
	return r


func test_toll_gantry_booth_lanes_slow_and_the_express_lanes_stay_open() -> void:
	var r := _toll_rig(200.0, 1)
	var inst := r.force(&"toll_gantry")
	if not check(inst != null, "live at the toll checkpoint"):
		return
	var tg := inst.controller as TollGantryPiece
	var d := inst.def
	near(tg.checkpoint_s, tuning.legs.leg_length_m(), EPS, "at the checkpoint")
	check(tg.is_booth_lane(0) and tg.is_booth_lane(2), "booth lanes on the sides")
	check(not tg.is_booth_lane(1), "the express lane in the middle")
	var booth_v := Units.kmh_to_mps(d.booth_speed_kmh)
	var slow := 0
	var fast_express := 0
	var over := 0
	var gross := 0
	var pull_outs := 0
	var v_exit := Units.kmh_to_mps(d.booth_exit_kmh)
	var serial := inst.serial
	var ended := false
	# The slots that were in a booth lane when they entered the zone: they have had its
	# whole approach to slow down. (A car that moves into a booth lane late, inside the
	# zone, slows from where it joins: only the gross check applies to it.)
	var from_entry := PackedByteArray()
	from_entry.resize(r.sim.state.capacity)
	var lc_prev := PackedInt32Array()
	lc_prev.resize(r.sim.state.capacity)
	for k in roundi(80.0 / SetPieceRig.DT):
		r.tick()
		if r.dir.set_pieces.instance_by_serial(serial) == null:
			ended = true
			break
		var ts := r.sim.state
		for i in ts.capacity:
			# A discretionary lane change started out of a booth lane (not a merge out of
			# a lane that ends) below the exit speed, from the zone to the keep's end.
			var started := ts.active[i] == 1 and ts.lc_state[i] != TrafficState.LaneChange.NONE and lc_prev[i] == 0
			lc_prev[i] = ts.lc_state[i] if ts.active[i] == 1 else 0
			if started and tg.is_booth_lane(ts.lane[i]) and not tg.is_booth_lane(ts.target_lane[i]) \
					and ts.v[i] < v_exit and is_inf(r.sim.closure_ahead(ts.lane[i], ts.s[i])) \
					and ts.s[i] >= inst.zone_s0 and ts.s[i] <= inst.zone_s1 + d.booth_keep_after_m:
				pull_outs += 1
			if ts.active[i] == 0 or ts.s[i] < inst.zone_s0:
				from_entry[i] = 0
				continue
			var in_booth := tg.is_booth_lane(ts.lane[i]) and ts.lc_state[i] == TrafficState.LaneChange.NONE
			if ts.s[i] < inst.zone_s0 + BOOTH_ENTRY_WINDOW_M:
				from_entry[i] = 1 if in_booth else 0
			if ts.s[i] < tg.checkpoint_s - d.booth_before_m * 0.25 or ts.s[i] > inst.zone_s1:
				continue
			if in_booth:
				if from_entry[i] == 1:
					slow += 1
					if ts.v[i] > booth_v + 0.5:
						over += 1
				if ts.v[i] > booth_v * BOOTH_GROSS_FACTOR:
					gross += 1
			elif ts.v[i] > booth_v * 1.5:
				fast_express += 1
	gt(slow, 0, "traffic at the booths")
	le(float(over), float(slow) * 0.02, "booth lanes slow to the booth speed at the booths")
	eq(gross, 0, "and a car that moved into a booth lane late is well on its way down")
	eq(pull_outs, 0, "booth traffic never pulls out into an express lane at booth speed")
	gt(fast_express, 0, "the express lane keeps its speed")
	check(ended, "it ended past the checkpoint")
	_gate(r, "toll gantry")
	eq(r.sim.speed_limit_at(0, tg.checkpoint_s, 0), INF, "its speed zones are gone with it")
	eq(r.sim.speed_limit_at(2, tg.checkpoint_s, 0), INF)
	var warn := r.events(SetPieceSource.KIND_WARNING)
	if check(warn.size() == 2, "the landmark's two signs"):
		near(float(warn[0][3]), 1000.0, 5.0, "1 km before the checkpoint")
		near(float(warn[1][3]), 500.0, 5.0, "and 500 m")


func test_toll_gantry_only_at_toll_checkpoints_and_exempt_from_the_checkpoint_rule() -> void:
	# Every checkpoint of style sign gantry (the default): no toll; every one a toll
	# gantry (unforced, chance per feature 100 %): a toll at each, right at it.
	for tolls: bool in [false, true]:
		var cp := tuning.legs.leg_length_m()
		var r := SetPieceRig.new(SEED, 3, null, null, 220.0, 1, cp - APPROACH_M)
		if tolls:
			r.all_tolls()
		r.run(12.0)
		var inst := r.running(&"toll_gantry")
		if tolls:
			if check(inst != null, "a toll at the toll checkpoint"):
				near((inst.controller as TollGantryPiece).checkpoint_s, cp, EPS)
		else:
			eq(inst, null, "no toll at a sign gantry")


func test_a_speed_zone_slows_even_a_truck_in_time_and_nothing_spawns_into_it_too_fast() -> void:
	# A truck (IDM a 0.6 m/s^2) at 100 km/h, 400 m before a 50 km/h zone in its lane: it
	# brakes comfortably (at least the constant deceleration to reach the zone speed at
	# its start; IDM alone lags a falling limit) and is at the zone's speed there.
	var r := SetPieceRig.new(SEED, 3, null, null, 80.0, 0)
	r.dir.set_density_scale(0.0)
	for i in r.sim.state.capacity:
		if r.sim.state.active[i] == 1:
			r.sim.despawn(i)
	var rec := SpawnSource.Record.new()
	rec.lane = 2
	rec.type_id = r.registry.type_index(&"semi")
	rec.profile_id = r.registry.profile_index(&"truck")
	rec.v = Units.kmh_to_mps(100.0)
	rec.v0 = rec.v
	rec.s = r.bot.state.s + 60.0
	rec.flags = TrafficState.FLAG_SCRIPTED   # it keeps its lane (MOBIL would leave the slow one)
	var half := r.dir.set_pieces.flow.length_of(rec.type_id) * 0.5
	var z0 := rec.s + half + 400.0
	var vz := Units.kmh_to_mps(50.0)
	check(r.sim.add_speed_zone(2, z0, z0 + 300.0, vz, 1), "zone added")
	var i := r.sim.spawn(rec)
	if not check(i >= 0, "spawned"):
		return
	var min_a := 0.0
	var at_start := NAN
	for k in roundi(40.0 / SetPieceRig.DT):
		r.tick()
		min_a = minf(min_a, r.sim.state.accel[i])
		if r.sim.state.s[i] + half >= z0:
			at_start = r.sim.state.v[i]
			break
	eq(r.sim.state.lane[i], 2, "(in its lane)")
	finite(at_start, "reached the zone")
	le(at_start, vz + 0.5, "at the zone's speed at its start")
	ge(min_a, -tuning.traffic.max_decel_mps2 * 0.5, "comfortably (%.2f m/s^2)" % min_a)
	# Spawning: not into the zone lane at 100 km/h inside it or on its braking approach;
	# the next lane, or far before it, is fine.
	var src := r.dir.set_pieces
	var probe := SpawnSource.Record.new()
	probe.type_id = rec.type_id
	probe.profile_id = rec.profile_id
	probe.v = rec.v
	probe.lane = 2
	probe.s = z0 + 100.0
	check(not src.spawn_speed_ok(probe), "not inside the zone")
	check(not src.keeps_clear(probe), "(Flow's filter)")
	probe.s = z0 - 20.0
	check(not src.spawn_speed_ok(probe), "not just before it")
	probe.lane = 1
	check(src.spawn_speed_ok(probe), "the next lane is fine")
	probe.lane = 2
	probe.s = z0 - 2000.0
	check(src.spawn_speed_ok(probe), "and so is far before it")
	r.sim.remove_zones(1)
	probe.s = z0 + 100.0
	check(src.spawn_speed_ok(probe), "no zone, no limit")
