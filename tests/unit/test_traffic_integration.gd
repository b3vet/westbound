extends WBTest
## Integration: the real TrafficDirector (WP2.5) feeding the real TrafficSim
## (WP2.4) around a bot player on the procedural road, checked by the
## independent TrafficRuleChecker. Spec: Traffic → Tests (zero traffic-to-traffic
## collisions, zero rule violations), Lives → rear-end prevention.

const DT := 1.0 / 120.0


func _run(seconds: float, leg: int, weave: bool, seed_value: int) -> Dictionary:
	var ctx := RunContext.new(seed_value)
	var road := ProceduralRoadPath.new(ctx)
	var registry := TrafficRegistry.load_default(ctx.tuning.traffic)
	var sim := TrafficSim.new(ctx, road, registry)
	# WEAVE mode follows traffic ahead; keep_lane() turns off its lane changes
	# (CRUISE is constant speed and would drive through slower cars).
	var bot := TrafficBotPlayer.new(road, 1, 38.0, TrafficBotPlayer.Mode.WEAVE, seed_value)
	if not weave:
		bot.keep_lane()
	sim.set_player_body(bot.length_m, bot.width_m)
	var director := TrafficDirector.new(ctx, road, sim, registry.profiles, registry.types,
		bot.length_m, bot.width_m)
	# Behind the player counts as outside the camera frustum.
	director.frustum_check = func(s: float, _d: float) -> bool: return s > bot.state.s - 10.0
	director.set_leg(leg, bot.state.s)
	var checker := TrafficRuleChecker.new(ctx.tuning, registry, road, bot.length_m, bot.width_m)
	var events := ScoreEventBuffer.new(ctx.tuning.scoring.event_buffer_capacity)
	road.ensure_generated_to(2000.0)
	director.reset(bot.state)
	var t := 0.0
	var peak := 0
	while t < seconds:
		road.ensure_generated_to(bot.state.s + 2000.0)
		bot.update(DT, sim.state)
		sim.step(DT, bot.state, null, events)
		director.step(DT, bot.state)
		events.clear()
		checker.observe(t, sim.state, bot.state)
		peak = maxi(peak, sim.state.count)
		t += DT
	return {
		"violations": checker.total_violations(), "collisions": checker.collision_pairs,
		"rear_ends": checker.rear_end_contacts, "spawned": director.spawned_ahead + director.spawned_behind,
		"peak": peak, "summary": checker.summary(), "km": bot.state.s / 1000.0,
	}


func _check(r: Dictionary, label: String) -> void:
	print("  %s: %.1f km, spawned %d, peak %d active; %s" % [label, r["km"], r["spawned"], r["peak"], r["summary"]])
	eq(r["violations"], 0, "%s rule violations" % label)
	eq(r["collisions"], 0, "%s traffic-to-traffic collisions" % label)
	gt(r["spawned"], 10, "%s traffic actually spawned" % label)


func test_director_and_sim_one_minute() -> void:
	var r := _run(60.0, 1, true, 20260928)
	_check(r, "leg 1 weave")


func soak_director_and_sim_leg1_weave() -> void:
	_check(_run(600.0, 1, true, 11), "leg 1 weave 10 min")


func soak_director_and_sim_leg8_weave() -> void:
	_check(_run(600.0, 8, true, 12), "leg 8 weave 10 min")


func soak_director_and_sim_leg8_lane_keeping() -> void:
	var r := _run(600.0, 8, false, 13)
	_check(r, "leg 8 lane-keeping 10 min")
	eq(r["rear_ends"], 0, "traffic never rear-ends a player who drives normally")


# ---------------------------------------------------------------- Director spawn hardening (WP3.3)
# WP2.4's soak lessons for the director: (a) a vehicle signaling or moving into a lane
# already occupies it, (b) the gap behind a slower leader is IDM's s* with the closing
# speed term, (c) no spawn overlaps a lane-splitting motorbike. Checked on both spawn
# paths: the Flow planner (plan_batch / plan_single's fits_between_neighbors_into) and
# the director's final commit check (keeps_live_gaps).

## A scenario on a straight road with the real sim, a director on it and the player far
## away (no ghost zone, no player gaps involved).
func _hardening_scene(seed_value: int, lanes: int) -> Array:
	var sc := TrafficScenario.new(seed_value, lanes)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 100.0, lanes - 1)
	sc.bot.keep_lane()
	sc.bot.state.s = -5000.0
	var dir := TrafficDirector.new(sc.ctx, sc.road, sc.sim, sc.registry.profiles, sc.registry.types,
		sc.bot.length_m, sc.bot.width_m)
	return [sc, dir]


func _rec(sc: TrafficScenario, s: float, lane: int, profile: StringName, type: StringName, kmh: float) -> SpawnSource.Record:
	var r := SpawnSource.Record.new()
	r.s = s
	r.lane = lane
	r.d = NAN
	r.v = Units.kmh_to_mps(kmh)
	r.v0 = r.v
	r.profile_id = sc.registry.profile_index(profile)
	r.type_id = sc.registry.type_index(type)
	return r


## Both spawn paths refuse (or accept) `rec`.
func _spawn_ok(dir: TrafficDirector, rec: SpawnSource.Record) -> bool:
	var a := dir.keeps_live_gaps(rec)
	var b := dir.flow.fits_between_neighbors_into(dir.ctx, rec)
	eq(a, b, "director commit check and Flow agree at s=%.1f lane %d" % [rec.s, rec.lane])
	return a and b


## Every record of a Flow batch around `slot` keeps s* to it when in a lane it occupies.
func _batch_keeps_gaps(sc: TrafficScenario, dir: TrafficDirector, slot: int, lanes: PackedInt32Array,
		expect_near: bool = true) -> int:
	var out: Array[SpawnSource.Record] = []
	dir.ctx.density_per_km_lane = 40.0   # dense, so the batch tries hard to fill every gap
	dir.flow.plan_batch(dir.ctx, sc.sim.state.s[slot] - 200.0, sc.sim.state.s[slot] + 200.0, out)
	var ts := sc.sim.state
	var bad := 0
	var near_count := 0
	for r in out:
		if not lanes.has(r.lane):
			continue
		var ln := dir.flow.length_of(r.type_id)
		var ahead := ts.s[slot] - r.s
		var need := dir.flow.min_spacing(r.profile_id, r.v, ln, ts.v[slot], ts.length[slot]) if ahead >= 0.0 \
			else dir.flow.min_spacing(ts.profile_id[slot], ts.v[slot], ts.length[slot], r.v, ln)
		if absf(ahead) < need:
			bad += 1
		if absf(ahead) < 100.0:
			near_count += 1
	if expect_near:
		gt(near_count, 0, "the batch did place vehicles near it")
	return bad


func test_spawn_gap_counts_a_car_signaling_or_moving_into_the_lane() -> void:
	var r := _hardening_scene(4101, 3)
	var sc: TrafficScenario = r[0]
	var dir: TrafficDirector = r[1]
	var car := sc.add(1000.0, 1, &"commuter", &"sedan", 110.0, 110.0)
	check(_spawn_ok(dir, _rec(sc, 1000.0, 0, &"commuter", &"sedan", 110.0)), "lane 0 is free before the signal")
	check(sc.sim.request_lane_change(car, 0), "signals left")
	eq(sc.sim.state.lc_state[car], TrafficState.LaneChange.SIGNALING)
	for ds: float in [-20.0, 0.0, 20.0]:
		check(not _spawn_ok(dir, _rec(sc, 1000.0 + ds, 0, &"commuter", &"sedan", 110.0)), "signaling: lane 0 taken (%+.0f m)" % ds)
	eq(_batch_keeps_gaps(sc, dir, car, PackedInt32Array([0, 1])), 0, "batch while signaling")
	while sc.sim.state.lc_state[car] == TrafficState.LaneChange.SIGNALING:
		sc.tick()
	eq(sc.sim.state.lc_state[car], TrafficState.LaneChange.MOVING)
	var s := sc.sim.state.s[car]
	check(not _spawn_ok(dir, _rec(sc, s, 0, &"commuter", &"sedan", 110.0)), "moving: the target lane is taken")
	check(not _spawn_ok(dir, _rec(sc, s, 1, &"commuter", &"sedan", 110.0)), "moving: the origin lane is taken")
	eq(_batch_keeps_gaps(sc, dir, car, PackedInt32Array([0, 1])), 0, "batch while moving")
	while sc.sim.state.lc_state[car] != TrafficState.LaneChange.NONE:
		sc.tick()
	s = sc.sim.state.s[car]
	check(_spawn_ok(dir, _rec(sc, s, 1, &"commuter", &"sedan", 110.0)), "after the move the origin lane is free")
	check(not _spawn_ok(dir, _rec(sc, s, 0, &"commuter", &"sedan", 110.0)), "and the car holds lane 0")
	check(_spawn_ok(dir, _rec(sc, s, 2, &"commuter", &"sedan", 110.0)), "lane 2 was never involved")


func test_spawn_gap_counts_a_lane_splitting_motorbike() -> void:
	# Slow 2-lane jam (the sim test's layout): the bike signals onto the lane line
	# (target_lane stays its own lane) and rides it. Both lanes are taken beside it.
	var r := _hardening_scene(4102, 2)
	var sc: TrafficScenario = r[0]
	var dir: TrafficDirector = r[1]
	for k in 24:
		var ln := k % 2
		var type := &"semi" if k == 17 else &"sedan"
		var prof := &"truck" if k == 17 else &"commuter"
		sc.add(300.0 + 28.0 * float(k >> 1) + 9.0 * ln, ln, prof, type, 40.0, 40.0)
	var bike := sc.add(260.0, 1, &"motorbike", &"motorbike", 40.0, 130.0)
	var saw_signal := false
	for n in roundi(30.0 / TrafficScenario.DT):
		sc.tick()
		var ts := sc.sim.state
		if ts.lc_state[bike] == TrafficState.LaneChange.SIGNALING and not sc.sim.is_lane_splitting(bike) and not saw_signal:
			saw_signal = true
			eq(ts.target_lane[bike], ts.lane[bike], "a split entry keeps its own target lane")
			check(not _spawn_ok(dir, _rec(sc, ts.s[bike], 0, &"motorbike", &"motorbike", ts.v[bike] / Units.kmh_to_mps(1.0))),
				"signaling a split to the left: lane 0 is taken")
		if sc.sim.is_lane_splitting(bike) and ts.lc_state[bike] == TrafficState.LaneChange.NONE:
			break
	check(saw_signal, "the bike signaled its split")
	if not check(sc.sim.is_lane_splitting(bike), "the bike splits lanes"):
		return
	var s := sc.sim.state.s[bike]
	var kmh := sc.sim.state.v[bike] / Units.kmh_to_mps(1.0)
	eq(sc.sim.state.lane[bike], 1, "a splitting bike's lane is the one it came from")
	# Only the bike left (no jam car beside it doing the refusing), still on the line.
	for i in sc.sim.state.capacity:
		if i != bike:
			sc.sim.despawn(i)
	for ln in 2:
		for ds: float in [-2.0, 0.0, 2.0]:
			check(not _spawn_ok(dir, _rec(sc, s + ds, ln, &"motorbike", &"motorbike", kmh)),
				"no spawn overlapping the splitting bike (lane %d, %+.0f m)" % [ln, ds])
	eq(_batch_keeps_gaps(sc, dir, bike, PackedInt32Array([0, 1])), 0, "batch around the splitting bike")


func test_spawn_gap_behind_a_slower_leader_includes_closing_speed() -> void:
	var r := _hardening_scene(4103, 3)
	var sc: TrafficScenario = r[0]
	var dir: TrafficDirector = r[1]
	var truck := sc.add(1000.0, 0, &"truck", &"semi", 60.0, 60.0)
	var reg := sc.registry
	var p := reg.profile_index(&"commuter")
	var v := sc.tuning.traffic.lane_flow_speed_mps(0, 3)
	var v_lead := Units.kmh_to_mps(60.0)
	var half := (reg.length[reg.type_index(&"semi")] + reg.length[reg.type_index(&"sedan")]) * 0.5
	var s_plain := reg.s0[p] + v * reg.headway[p]
	var s_star := SpawnSources.idm_desired_gap(v, v - v_lead, reg.headway[p], reg.s0[p], reg.a_max[p], reg.b_comfort[p])
	gt(s_star, s_plain + 20.0, "the closing term matters here")
	var mid := 1000.0 - half - (s_plain + s_star) * 0.5
	check(not _spawn_ok(dir, _rec(sc, mid, 0, &"commuter", &"sedan", v / Units.kmh_to_mps(1.0))),
		"closer than s* (though beyond s0 + vT): refused")
	var ok_s := 1000.0 - half - s_star - 0.5
	check(_spawn_ok(dir, _rec(sc, ok_s, 0, &"commuter", &"sedan", v / Units.kmh_to_mps(1.0))), "at s* + 0.5 m: accepted")
	eq(_batch_keeps_gaps(sc, dir, truck, PackedInt32Array([0])), 0, "batch behind the slow truck")
	# And the sim agrees: spawned at s*, the follower closes in without contact, inside the clamp.
	var f := sc.add(ok_s, 0, &"commuter", &"sedan", v / Units.kmh_to_mps(1.0), 130.0)
	var min_a := 0.0
	for n in roundi(20.0 / TrafficScenario.DT):
		sc.tick()
		min_a = minf(min_a, sc.sim.state.accel[f])
	eq(sc.checker.collision_pairs, 0, "no contact")
	ge(min_a, -sc.tuning.traffic.max_decel_mps2, "never beyond the clamp")
	print("      follower spawned at s* = %.1f m (s0 + vT = %.1f m): min accel %.2f m/s^2" % [s_star, s_plain, min_a])


func test_failed_behind_spawns_back_off() -> void:
	# The player is slow, so the left lanes owe arrivals from behind, but the spawn point
	# is always visible: each attempt fails. Attempts are retried every
	# spawn_behind_retry_s, not every tick (each one draws a vehicle and scans the lane).
	var sc := TrafficScenario.new(4104, 3)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 60.0, 2)
	sc.bot.keep_lane()
	var dir := TrafficDirector.new(sc.ctx, sc.road, sc.sim, sc.registry.profiles, sc.registry.types,
		sc.bot.length_m, sc.bot.width_m)
	dir.frustum_check = func(_s: float, _d: float) -> bool: return true
	dir.set_leg(8, sc.bot.state.s)
	dir.reset(sc.bot.state)
	var seconds := 10.0
	for n in roundi(seconds / TrafficScenario.DT):
		sc.tick()
		dir.step(TrafficScenario.DT, sc.bot.state)
	var lanes_behind := mini(sc.tuning.traffic.spawn_behind_lane_count, 2)
	gt(dir.rejected_visible, 0, "behind spawns were attempted")
	le(dir.rejected_visible, lanes_behind * (ceili(seconds / sc.tuning.traffic.spawn_behind_retry_s) + 1),
		"one attempt per lane per retry interval")
	eq(dir.spawned_behind, 0)
