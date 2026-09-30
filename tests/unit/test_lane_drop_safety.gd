extends WBTest
## Lane-drop safety (WP6.8). Spec: Traffic → Fairness rules (1 telegraph, 2 no ambush,
## 4 "no decel over 6 m/s^2 except announced set pieces"), Lane changes: MOBIL (safety),
## Tests (headless): "zero traffic-to-traffic collisions"; World → Road (tunnels drop to
## 2 lanes). What is tested (docs/TRAFFIC.md "Lane drops (WP6.8)"):
##   - MOBIL's safety check sees a fast car hidden behind a lane-splitting motorbike;
##   - a zipper merge at a drop beside fast lanes: no contact, nobody near the clamp;
##   - the harmonisation zone: fast cars brake into it smoothly, at their comfortable
##     deceleration, and reach the capped speed at its start;
##   - nobody stops beside a fast lane at a drop (canyon road, leg-8 traffic);
##   - canyon determinism;
##   - the rule checker's box heading for slow lateral movers (spurious vs real contacts).

const SEED := 680801
const DT := 1.0 / 120.0
## The test road's drop (3 -> 2 lanes) and widening (2 -> 3).
const DROP_S := 2500.0
const WIDEN_S := 3600.0
## "Stopped" and "a fast lane beside it" for the no-standstill check (km/h).
const STOPPED_KMH := 15.0
const FAST_BESIDE_KMH := 60.0
## How far along the road a vehicle in the next lane counts as "beside" (m).
const BESIDE_M := 40.0

var tuning: Tuning
var taper: float


func before_all() -> void:
	tuning = Tuning.load_default()
	taper = tuning.road.lane_taper_length_m


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


# ---------------------------------------------------------------- MOBIL: every follower

func test_mobil_sees_a_fast_car_behind_a_lane_splitting_bike() -> void:
	# Lanes 1 and 2 crawl at 50 km/h (scripted columns). A motorbike behind them splits
	# onto the lane 0|1 boundary: it claims half of lane 0, so for a car in lane 1 asking
	# for lane 0 it is the nearest follower, and it is slow. A racer at 200 km/h comes up
	# lane 0 behind the bike. Before WP6.8 MOBIL judged the bike only and cut the racer
	# off; now the racer is judged too.
	var sc := TrafficScenario.new(SEED)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 60.0, 2)
	sc.bot.state.s = -5000.0
	var column := PackedInt32Array()
	for k in 14:
		column.append(sc.add(300.0 + 30.0 * float(k), 1, &"commuter", &"sedan", 50.0, 50.0, NAN,
			TrafficState.FLAG_SCRIPTED))
		sc.add(290.0 + 30.0 * float(k), 2, &"commuter", &"sedan", 50.0, 50.0, NAN, TrafficState.FLAG_SCRIPTED)
	var bike := sc.add(250.0, 1, &"motorbike", &"motorbike", 50.0, 140.0)
	# A lane-0 car beside the bike keeps it from simply changing lanes (despawned below).
	var blocker := sc.add(250.0, 0, &"commuter", &"sedan", 50.0, 50.0, NAN, TrafficState.FLAG_SCRIPTED)
	var t_split := -1.0
	for n in roundi(20.0 / DT):
		sc.tick()
		if sc.sim.is_lane_splitting(bike) and sc.sim.state.lc_state[bike] == TrafficState.LaneChange.NONE:
			t_split = sc.time
			break
	if not check(t_split > 0.0, "the bike splits lanes behind the columns"):
		return
	sc.sim.despawn(blocker)
	var ts := sc.sim.state
	# The column car 60-100 m ahead of the bike asks for lane 0.
	var car := -1
	for c in column:
		var ahead := ts.s[c] - ts.s[bike]
		if car < 0 and ahead > 60.0 and ahead < 100.0:
			car = c
	if not check(car >= 0, "a column car 60-100 m ahead of the bike"):
		return
	var racer := sc.add(ts.s[car] - 130.0, 0, &"racer", &"sports", 200.0, 200.0)
	sc.sim.step(0.0, sc.bot.state, null, sc.events)   # refresh the order
	check(sc.sim.is_lane_splitting(bike), "still splitting")
	check(not sc.sim.request_lane_change(car, 0), "refused: the racer behind the bike would reach the gap")
	sc.sim.despawn(racer)
	sc.sim.step(0.0, sc.bot.state, null, sc.events)
	check(sc.sim.request_lane_change(car, 0), "allowed without the racer: the bike alone is no threat")


func test_organic_lane_changes_never_cut_off_a_fast_car_behind_a_bike() -> void:
	# The same scene run for a while with MOBIL deciding: column cars keep asking for the
	# free lane 0 while racers arrive behind the splitting bike (from far enough back that
	# the column cars already in lane 0 are an ordinary approach). Nobody touches, and no
	# racer ever has to brake beyond its MOBIL b_safe.
	var sc := TrafficScenario.new(SEED + 1)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 60.0, 2)
	sc.bot.state.s = -5000.0
	for k in 14:
		sc.add(300.0 + 30.0 * float(k), 1, &"commuter", &"sedan", 50.0, 120.0)
		sc.add(290.0 + 30.0 * float(k), 2, &"commuter", &"sedan", 50.0, 50.0, NAN, TrafficState.FLAG_SCRIPTED)
	sc.add(750.0, 1, &"truck", &"semi", 50.0, 50.0, NAN, TrafficState.FLAG_SCRIPTED)   # the column's head
	var bike := sc.add(250.0, 1, &"motorbike", &"motorbike", 50.0, 140.0)
	var blocker := sc.add(250.0, 0, &"commuter", &"sedan", 50.0, 50.0, NAN, TrafficState.FLAG_SCRIPTED)
	var racers := PackedInt32Array()
	var ts := sc.sim.state
	var b_safe := sc.registry.profiles[sc.registry.profile_index(&"racer")].mobil_b_safe_mps2
	var worst := 0.0
	var spawned := false
	for n in roundi(40.0 / DT):
		sc.tick()
		if not spawned and sc.sim.is_lane_splitting(bike):
			spawned = true
			sc.sim.despawn(blocker)
			for k in 4:
				racers.append(sc.add(ts.s[bike] - 600.0 - 200.0 * float(k), 0, &"racer", &"sports", 200.0, 200.0))
		for r in racers:
			if ts.is_active(r):
				worst = minf(worst, ts.accel[r])
	check(spawned, "the bike split")
	print("      racers' hardest braking %.2f m/s^2 (b_safe %.1f), %d lane changes" % [worst, b_safe, sc.checker.moves])
	gt(sc.checker.moves, 0, "column cars changed lanes")
	ge(worst, -b_safe - 1e-6, "no racer braked beyond its b_safe for a cut-in")
	eq(sc.checker.collision_pairs, 0)
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


# ---------------------------------------------------------------- A drop with fast traffic

## A 3-lane procedural road dropping to 2 lanes at DROP_S and back at WIDEN_S, the real
## sim with the road's closures (and lane-drop zones) synced, a bot player far behind.
func _drop_scene(seed_value: int = SEED) -> Dictionary:
	var ctx := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	var road := ProceduralRoadPath.new(ctx)
	road.schedule_lane_count(DROP_S, 2, taper)
	road.schedule_lane_count(WIDEN_S, 3, taper)
	road.ensure_generated_to(8000.0)
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var sim := TrafficSim.new(ctx, road, reg)
	var bot := TrafficBotPlayer.new(road, 0, _kmh(60.0), TrafficBotPlayer.Mode.CRUISE, 7, -6000.0)
	sim.set_player_body(bot.length_m, bot.width_m)
	sim.sync_road_closures(-7000.0, 8000.0)
	var checker := TrafficRuleChecker.new(tuning, reg, road, bot.length_m, bot.width_m)
	return {"ctx": ctx, "road": road, "reg": reg, "sim": sim, "bot": bot, "checker": checker,
		"ev": ScoreEventBuffer.new(256), "t": 0.0}


func _add(sc: Dictionary, s: float, lane: int, kmh: float, profile: StringName, type: StringName,
		v0_kmh: float = -1.0) -> int:
	var reg: TrafficRegistry = sc["reg"]
	var rec := SpawnSource.Record.new()
	rec.s = s
	rec.lane = lane
	rec.v = _kmh(kmh)
	rec.v0 = _kmh(v0_kmh if v0_kmh > 0.0 else kmh)
	rec.profile_id = reg.profile_index(profile)
	rec.type_id = reg.type_index(type)
	return (sc["sim"] as TrafficSim).spawn(rec)


func _tick(sc: Dictionary) -> void:
	var sim: TrafficSim = sc["sim"]
	var bot: TrafficBotPlayer = sc["bot"]
	var ev: ScoreEventBuffer = sc["ev"]
	bot.update(DT, sim.state)
	sim.step(DT, bot.state, null, ev)
	ev.clear()
	sc["t"] = float(sc["t"]) + DT
	(sc["checker"] as TrafficRuleChecker).observe(float(sc["t"]), sim.state, bot.state)


func test_drop_zone_from_the_road() -> void:
	var sc := _drop_scene()
	var sim: TrafficSim = sc["sim"]
	eq(sim.lane_drop_zone_count(), 1, "one zone for the drop, none for the widening")
	near(sim.lane_drop_zone_s0(0), DROP_S - tuning.traffic.lane_drop_slow_zone_m, 1e-6,
		"no lane_ends sign on this road: the zone starts lane_drop_slow_zone_m before the taper")
	near(sim.lane_drop_zone_s1(0), WIDEN_S + taper + tuning.traffic.lane_drop_slow_after_m, 1e-6,
		"through the narrowed section, to past the lanes coming back")
	var p := (sc["reg"] as TrafficRegistry).profile_index(&"commuter")
	near(sim.lane_drop_limit_at(0, DROP_S - 100.0, p), _kmh(tuning.traffic.lane_drop_through_kmh), 1e-9,
		"through lanes capped inside the zone")
	near(sim.lane_drop_limit_at(2, DROP_S - 100.0, p), _kmh(tuning.traffic.lane_drop_merge_lane_kmh), 1e-9,
		"the dropping lane a little slower")
	gt(sim.lane_drop_limit_at(0, DROP_S - 600.0, p), _kmh(tuning.traffic.lane_drop_through_kmh),
		"before the zone: the braking envelope")
	near(sim.lane_drop_limit_at(1, (DROP_S + WIDEN_S) * 0.5, p), _kmh(tuning.traffic.lane_drop_through_kmh), 1e-9,
		"the two-lane section is harmonised too")
	eq(sim.lane_drop_limit_at(0, WIDEN_S + taper + tuning.traffic.lane_drop_slow_after_m + 1.0, p), INF,
		"past it: no cap")
	near(sim.merge_zone_frac(2, DROP_S - 500.0), 500.0 / tuning.traffic.lane_drop_merge_zone_m, 1e-9,
		"a road drop's merge zone is lane_drop_merge_zone_m long")
	sim.forget_lane_closures_before(WIDEN_S + taper + tuning.traffic.lane_drop_slow_after_m + 1.0)
	eq(sim.lane_drop_zone_count(), 0, "forgotten behind the player")


func test_zipper_merge_beside_fast_lanes() -> void:
	# Lane 2 (dropping) carries trucks, buses and cruisers at 85-100 km/h; lanes 0 and 1
	# carry racers, aggressive drivers and commuters at 130-210 km/h, dense. Everyone in
	# lane 2 merges before the taper, nobody touches, nobody gets near the clamp, nobody
	# stops.
	var sc := _drop_scene()
	var sim: TrafficSim = sc["sim"]
	var ts := sim.state
	var mergers := PackedInt32Array()
	var slow: Array[StringName] = [&"truck", &"cruiser", &"bus", &"cruiser"]
	var slow_types: Array[StringName] = [&"semi", &"sedan", &"coach", &"hatchback"]
	for k in 12:
		mergers.append(_add(sc, 700.0 + 85.0 * float(k), 2, 85.0 + 5.0 * float(k % 4), slow[k % 4], slow_types[k % 4],
			95.0))
	for k in 16:
		_add(sc, 500.0 + 70.0 * float(k), 1, 130.0 + 5.0 * float(k % 3), &"commuter", &"sedan", 140.0)
	for k in 10:
		_add(sc, 300.0 + 110.0 * float(k), 0, 170.0 + 15.0 * float(k % 3),
			&"racer" if k % 2 == 0 else &"aggressive", &"sports", 210.0)
	var min_a := 0.0
	var min_v := INF
	for n in roundi(75.0 / DT):
		_tick(sc)
		for i in ts.capacity:
			if ts.active[i] == 1 and ts.s[i] > DROP_S - 1000.0 and ts.s[i] < WIDEN_S:
				min_a = minf(min_a, ts.accel[i])
				min_v = minf(min_v, ts.v[i])
	var c: TrafficRuleChecker = sc["checker"]
	print("      %d merges, hardest braking %.2f m/s^2, slowest %.0f km/h" % [sim.stat_merges, min_a, min_v * 3.6])
	for m in c.messages:
		print("        ", m)
	eq(c.collision_pairs, 0, "no contact")
	eq(c.decel_violations, 0)
	gt(min_a, -tuning.traffic.max_decel_mps2 + 1.0, "nobody near the 6 m/s^2 clamp")
	gt(min_v, _kmh(STOPPED_KMH), "nobody stops")
	eq(c.offroad_violations + c.signal_violations + c.unsignaled_moves + c.ambush_violations, 0)
	for i in mergers:
		check(ts.lane[i] < 2 or ts.s[i] > WIDEN_S, "slot %d merged out of the dropping lane" % i)


func test_harmonisation_zone_brakes_smoothly() -> void:
	# Alone on the road: a racer at 250 km/h (lane 0), a commuter at 145 (lane 1) and an
	# aggressive driver at 190 in the dropping lane (it merges on the way). Each eases
	# into the zone (braking never beyond its comfortable b, and never harder by more
	# than ONSET_JERK per second: no step when the zone comes into view), reaches its
	# lane's harmonised speed where the zone starts (+2 km/h) and holds it inside.
	const ONSET_JERK := 12.0   # m/s^3: a step of b in one tick would be ~500
	var sc := _drop_scene()
	var sim: TrafficSim = sc["sim"]
	var reg: TrafficRegistry = sc["reg"]
	var ts := sim.state
	var z0 := sim.lane_drop_zone_s0(0)
	var cars := PackedInt32Array([
		_add(sc, z0 - 1500.0, 0, 250.0, &"racer", &"sports"),
		_add(sc, z0 - 900.0, 1, 145.0, &"commuter", &"sedan"),
		_add(sc, z0 - 1200.0, 2, 190.0, &"aggressive", &"coupe")])
	var worst := PackedFloat64Array([0.0, 0.0, 0.0])
	var jerk := PackedFloat64Array([0.0, 0.0, 0.0])
	var at_zone := PackedFloat64Array([INF, INF, INF])
	var over := PackedFloat64Array([-INF, -INF, -INF])   # inside: speed above its lane's cap
	var prev := PackedFloat64Array([0.0, 0.0, 0.0])
	for n in roundi(45.0 / DT):
		_tick(sc)
		for k in cars.size():
			var i := cars[k]
			var front := ts.s[i] + ts.length[i] * 0.5
			if front > DROP_S - 50.0:
				continue
			var cap := _kmh(tuning.traffic.lane_drop_merge_lane_kmh if ts.lane[i] == 2 \
				else tuning.traffic.lane_drop_through_kmh)
			worst[k] = minf(worst[k], ts.accel[i])
			if n > 0:
				jerk[k] = maxf(jerk[k], (prev[k] - ts.accel[i]) / DT)   # braking harder
			prev[k] = ts.accel[i]
			if front >= z0:
				if is_inf(at_zone[k]):
					at_zone[k] = ts.v[i] - cap
				if ts.lc_state[i] == 0:
					over[k] = maxf(over[k], ts.v[i] - cap)
	var c: TrafficRuleChecker = sc["checker"]
	for k in cars.size():
		var p := reg.profiles[ts.profile_id[cars[k]]]
		print("      %s: hardest %.2f m/s^2 (b %.1f), max onset jerk %.1f m/s^3, %+.1f km/h against the cap at the zone, max %+.1f inside" % [
			p.id, worst[k], p.idm_b_comfort_mps2, jerk[k], at_zone[k] * 3.6, over[k] * 3.6])
		ge(worst[k], -p.idm_b_comfort_mps2 - 0.05, "%s: at most its comfortable deceleration" % p.id)
		lt(worst[k], -0.5, "%s: it did brake" % p.id)
		le(at_zone[k], _kmh(2.0), "%s: at the zone's speed where it starts" % p.id)
		le(over[k], _kmh(2.0), "%s: and holds it" % p.id)
		lt(jerk[k], ONSET_JERK, "%s: no step in the braking" % p.id)
	eq(c.brake_flag_violations + c.decel_violations + c.collision_pairs, 0, "brake lights follow it")


# ---------------------------------------------------------------- The canyon road

## The first lane drop on a canyon run's road, and where its lanes come back.
func _canyon_drop(r: TrafficSoakRun) -> Vector2:
	var found: Array[RoadFeature] = []
	r.road.ensure_generated_to(40000.0)
	r.road.features_in(0.0, 40000.0, found)
	var drop := -1.0
	var back := -1.0
	for f in found:
		if f.kind == RoadFeature.Kind.LANE_COUNT_CHANGE:
			if drop < 0.0 and int(f.value) < r.road.lane_count(f.s_start - 10.0):
				drop = f.s_start
			elif drop >= 0.0 and back < 0.0:
				back = f.s_end
	return Vector2(drop, back)


func test_nobody_stops_beside_a_fast_lane_at_a_canyon_drop() -> void:
	# The canyon's real road and director at leg-8 density, a lane-keeping bot at
	# 140 km/h through the first tunnel's lane drop: every tick, no vehicle slower than
	# STOPPED_KMH has a vehicle faster than FAST_BESIDE_KMH beside it in the next lane.
	var canyon := BiomePlan.load_biome(&"canyon")
	if not check(canyon != null, "data/biomes/canyon.tres"):
		return
	var r := TrafficSoakRun.new(2, SEED, 8, -1.0, null, 8, canyon)
	var db := _canyon_drop(r)
	if not check(db.x > 0.0 and db.y > db.x, "the canyon road drops lanes for a tunnel"):
		return
	r.bot.state.s = db.x - 800.0
	r.bot.lane = 0
	r.bot.state.d = r.road.lane_center_d(0, r.bot.state.s)
	r.bot.state.v = _kmh(140.0)
	r.bot.v_target = r.bot.state.v
	r.bot.keep_lane()
	r.director.reset(r.bot.state)
	r.check_windows = false
	var ts := r.sim.state
	var bad := 0
	var slowest := INF
	while r.bot.state.s < db.y + 300.0 and r.time < 120.0:
		r.tick()
		for i in ts.capacity:
			if ts.active[i] == 0 or ts.s[i] < db.x - 1000.0 or ts.s[i] > db.y:
				continue
			slowest = minf(slowest, ts.v[i])
			if ts.v[i] >= _kmh(STOPPED_KMH):
				continue
			for j in ts.capacity:
				if ts.active[j] == 1 and absi(ts.lane[j] - ts.lane[i]) == 1 and absf(ts.s[j] - ts.s[i]) < BESIDE_M \
						and ts.v[j] > _kmh(FAST_BESIDE_KMH):
					bad += 1
	var d := r.result()
	print("      drop at %.0f m: %d merges, slowest vehicle near it %.0f km/h, %d collisions" % [
		db.x, d["merges"], slowest * 3.6, d["collision_pairs"]])
	eq(bad, 0, "nobody stopped beside a lane moving faster than %.0f km/h" % FAST_BESIDE_KMH)
	eq(int(d["collision_pairs"]) + int(d["offroad_violations"]) + int(d["decel_violations"]), 0)
	gt(int(d["merges"]), 0, "traffic merged")


func _canyon_trace(seed_value: int) -> int:
	var canyon := BiomePlan.load_biome(&"canyon")
	var r := TrafficSoakRun.new(1, seed_value, 2, 600.0, null, 6, canyon)
	r.check_windows = false
	r.run_to_end()
	var merges := int(r.result()["merges"])
	gt(merges, 0, "the trace covers merges at a lane drop")
	print("      %d merges in the traced run" % merges)
	return r.trace


func test_canyon_lane_drops_are_deterministic() -> void:
	var canyon := BiomePlan.load_biome(&"canyon")
	if not check(canyon != null, "data/biomes/canyon.tres"):
		return
	eq(_canyon_trace(SEED), _canyon_trace(SEED), "same seed, same canyon trace (drop zones, zipper, merges)")


# ---------------------------------------------------------------- Rule checker: box heading

## A two-vehicle TrafficState: slot a at (s_a, d_a) with v_a / v_lat_a, slot b at (s_b, d_b).
func _pair(type_a: StringName, s_a: float, d_a: float, v_a: float, v_lat_a: float,
		type_b: StringName, s_b: float, d_b: float, v_b: float) -> TrafficState:
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var ts := TrafficState.new(4)
	var ss := PackedFloat64Array([s_a, s_b])
	var dd := PackedFloat64Array([d_a, d_b])
	var vv := PackedFloat64Array([v_a, v_b])
	var types: Array[StringName] = [type_a, type_b]
	for k in 2:
		var i := ts.allocate()
		var t := reg.types[reg.type_index(types[k])]
		ts.s[i] = ss[k]
		ts.d[i] = dd[k]
		ts.v[i] = vv[k]
		ts.length[i] = t.length_m
		ts.width[i] = t.width_m
		ts.profile_id[i] = reg.profile_index(&"commuter")
		ts.type_id[i] = reg.type_index(types[k])
		ts.flags[i] = TrafficState.FLAG_BLINKER_LEFT
	ts.v_lat[0] = v_lat_a
	return ts


func _collides(ts: TrafficState) -> int:
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var road := StraightRoadPath.new(3, tuning.road)
	var c := TrafficRuleChecker.new(tuning, reg, road, 4.5, 1.9)
	var player := VehicleState.new()
	player.s = -1000.0
	c.observe(0.0, ts, player)
	return c.collision_pairs


func test_rule_checker_box_heading_for_slow_lateral_movers() -> void:
	var cap := TrafficRuleChecker.MAX_BOX_YAW_RAD
	near(TrafficRuleChecker.box_yaw(0.0, 1.8), cap, 1e-12, "stopped, moving sideways: clamped")
	near(TrafficRuleChecker.box_yaw(0.0, -1.8), -cap, 1e-12)
	near(TrafficRuleChecker.box_yaw(30.0, 1.5), atan2(1.5, 30.0), 1e-12, "at traffic speeds: the path's heading")
	eq(TrafficRuleChecker.box_yaw(0.0, 0.0), 0.0, "standing still")
	# The WP6.3 soak's case (run 12): a coach nearly stopped at the end of lane 2 (d 9.6)
	# merging toward lane 1 at 1.8 m/s sideways, a racer passing in lane 0 (d 3.5). Their
	# bodies are a lane apart, but turned to atan2(1.8, 0.1) (87 degrees) the coach's
	# 12 m box reached across lane 1 into lane 0.
	var ts := _pair(&"coach", 100.0, 9.6, 0.0, -1.8, &"sports", 100.0, 3.5, 40.0)
	var c := TrafficRuleChecker.new(tuning, TrafficRegistry.load_default(tuning.traffic),
		StraightRoadPath.new(3, tuning.road), 4.5, 1.9)
	check(c._overlap(100.0, 9.6, 12.0, 2.55, atan2(-1.8, 0.1), 100.0, 3.5, 4.5, 1.95, 0.0),
		"the old heading made the boxes overlap")
	eq(_collides(ts), 0, "a stopped lateral mover's box no longer turns sideways")
	# Real contacts still count: the coach's body moving sideways into a car beside it ...
	var beside := _pair(&"coach", 100.0, 8.9, 0.0, -1.8, &"sedan", 100.0, 7.1, 0.0)
	eq(_collides(beside), 1, "a body overlap beside it is still a collision")
	# ... and a rear-end at speed.
	var rear := _pair(&"sedan", 100.0, 7.1, 30.0, 0.0, &"sedan", 104.5, 7.1, 20.0)
	eq(_collides(rear), 1, "a rear-end is still a collision")
