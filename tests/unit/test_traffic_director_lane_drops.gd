extends WBTest
## Lane closures and mandatory merges (WP6.2 scope addition for WP6.4a's lane drops).
## Spec: World → Road ("tunnels and road works drop to 2" lanes); Traffic → Fairness
## rules 1 (telegraph every lane change), 2 (no ambush) and 5 (no pop-in; spawns);
## Spawning ("vehicles spawn ... at their lane's flow speed"); Lives → a player driving
## normally is never rear-ended. The mechanism is TrafficSim's "Lane closures and
## mandatory merges" block; the director feeds the road's lane-count changes into it and
## Flow keeps spawns out of lanes that close (docs/SPAWNING.md "Lane drops").

const SEED := 620401
const DT := 1.0 / 120.0
const EPS := 1e-6
## The test road's drop (3 -> 2 lanes) and widening (2 -> 3), with the default taper.
const DROP_S := 1500.0
const WIDEN_S := 2600.0

var tuning: Tuning
var taper: float


func before_all() -> void:
	tuning = Tuning.load_default()
	taper = tuning.road.lane_taper_length_m


## A 3-lane procedural road dropping to 2 lanes at DROP_S and back at WIDEN_S.
func _road(ctx: RunContext) -> ProceduralRoadPath:
	var r := ProceduralRoadPath.new(ctx)
	r.schedule_lane_count(DROP_S, 2, taper)
	r.schedule_lane_count(WIDEN_S, 3, taper)
	r.ensure_generated_to(6000.0)
	return r


## Traffic on that road: the real sim, closures synced, a bot player far behind.
func _scenario(seed_value: int = SEED) -> Dictionary:
	var ctx := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	var road := _road(ctx)
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var sim := TrafficSim.new(ctx, road, reg)
	var bot := TrafficBotPlayer.new(road, 0, Units.kmh_to_mps(60.0), TrafficBotPlayer.Mode.CRUISE, 7, -4000.0)
	sim.set_player_body(bot.length_m, bot.width_m)
	sim.sync_road_closures(-5000.0, 6000.0)
	var checker := TrafficRuleChecker.new(tuning, reg, road, bot.length_m, bot.width_m)
	return {"ctx": ctx, "road": road, "reg": reg, "sim": sim, "bot": bot, "checker": checker,
		"ev": ScoreEventBuffer.new(256), "t": 0.0}


func _add(sc: Dictionary, s: float, lane: int, kmh: float, profile: StringName = &"commuter",
		type: StringName = &"sedan", flags: int = 0) -> int:
	var reg: TrafficRegistry = sc["reg"]
	var rec := SpawnSource.Record.new()
	rec.s = s
	rec.lane = lane
	rec.v = Units.kmh_to_mps(kmh)
	rec.v0 = rec.v
	rec.profile_id = reg.profile_index(profile)
	rec.type_id = reg.type_index(type)
	rec.flags = flags
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


# ---------------------------------------------------------------- Closures

func test_road_lane_changes_become_closures() -> void:
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	eq(sim.lane_closure_count(), 2, "the dropped lane over the drop, the added lane over the widening")
	near(sim.closure_ahead(2, 1000.0), DROP_S - 1000.0, EPS, "lane 2 closes 500 m ahead")
	eq(sim.closure_ahead(1, 1000.0), INF, "lane 1 stays")
	eq(sim.closure_ahead(2, DROP_S + 10.0), 0.0, "inside the closure")
	near(sim.closure_ahead(2, DROP_S + taper + 1.0), WIDEN_S - DROP_S - taper - 1.0, EPS,
		"after the taper the lane does not exist (lane_count), the next closure is the widening's")
	sim.sync_road_closures(-5000.0, 6000.0)
	sim.sync_road_closures(0.0, 7000.0)
	eq(sim.lane_closure_count(), 2, "syncing again adds nothing")
	check(sim.add_lane_closure(1, 3500.0, 3600.0, 42), "a set piece's own closure")
	eq(sim.lane_closure_count(), 3)
	sim.remove_lane_closures(42)
	eq(sim.lane_closure_count(), 2, "removed by tag")
	sim.forget_lane_closures_before(DROP_S + taper + 1.0)
	eq(sim.lane_closure_count(), 1, "behind: forgotten")


func test_vehicles_merge_out_before_a_lane_drop() -> void:
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	var ts := sim.state
	var in_lane_2 := PackedInt32Array()
	for k in 8:
		in_lane_2.append(_add(sc, 500.0 + 90.0 * float(k), 2, 100.0))
	for k in 6:
		_add(sc, 450.0 + 150.0 * float(k), 1, 115.0)
	var wrong := 0
	for n in roundi(70.0 / DT):
		_tick(sc)
		for i in ts.capacity:
			if ts.active[i] == 1 and ts.lane[i] == 2 and ts.s[i] + ts.length[i] * 0.5 > DROP_S \
					and ts.s[i] < WIDEN_S:
				wrong += 1
	var c: TrafficRuleChecker = sc["checker"]
	eq(wrong, 0, "no vehicle in the dropped lane past the drop")
	eq(c.offroad_violations, 0, "nobody leaves the driving lanes")
	eq(c.signal_violations + c.unsignaled_moves, 0, "every merge telegraphed")
	eq(c.collision_pairs, 0)
	ge(sim.stat_merges, in_lane_2.size(), "each merged")
	for i in in_lane_2:
		check(ts.s[i] > WIDEN_S or ts.lane[i] < 2, "slot %d is through, in lanes 0-1" % i)


func test_no_gap_means_waiting_at_the_end_of_the_lane() -> void:
	# Lane 1 is a solid column (scripted, 25 m apart) beside the car in lane 2: it brakes
	# to the end of its lane and waits, then merges behind the column's tail. The last
	# resort since WP6.8: scripted vehicles never yield (the zipper), so nobody opens a
	# gap; ordinary traffic does (test_lane_drop_safety.gd).
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	var ts := sim.state
	var car := _add(sc, 700.0, 2, 90.0)
	for k in 16:
		_add(sc, 900.0 - 25.0 * float(k), 1, 90.0, &"commuter", &"sedan", TrafficState.FLAG_SCRIPTED)
	var stop_line := DROP_S - tuning.traffic.merge_stop_margin_m
	var min_v := INF
	var max_front := -INF
	var merged_at := -1.0
	for n in roundi(90.0 / DT):
		_tick(sc)
		if merged_at >= 0.0:
			continue
		if ts.lane[car] == 2 and ts.lc_state[car] == TrafficState.LaneChange.NONE:
			min_v = minf(min_v, ts.v[car])
			max_front = maxf(max_front, ts.s[car] + ts.length[car] * 0.5)
		elif ts.lc_state[car] == TrafficState.LaneChange.MOVING:
			merged_at = float(sc["t"])
	lt(min_v, 1.0, "it stopped")
	le(max_front, stop_line + 0.5, "at the end of its lane, never past it")
	gt(merged_at, 0.0, "and merged when a gap came")
	var c: TrafficRuleChecker = sc["checker"]
	eq(c.offroad_violations + c.collision_pairs + c.signal_violations + c.ambush_violations, 0)


func test_no_lane_change_into_a_closing_lane() -> void:
	# Slow cars in lane 1 want to keep right: never into lane 2 within merge_zone_m of its
	# closure (nor into the widening's lane before its taper ends). WP6.8: a road drop's
	# zone is lane_drop_merge_zone_m, longer still.
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	var ts := sim.state
	for k in 10:
		_add(sc, 300.0 + 200.0 * float(k), 1, 95.0, &"cruiser", &"sedan")
	var bad := 0
	var into_2 := 0
	for n in roundi(60.0 / DT):
		_tick(sc)
		for i in ts.capacity:
			if ts.active[i] == 1 and ts.lc_state[i] == TrafficState.LaneChange.SIGNALING and ts.target_lane[i] == 2 \
					and ts.lc_timer[i] == 0.0:
				into_2 += 1
				if sim.closure_ahead(2, ts.s[i] + ts.length[i] * 0.5) < tuning.traffic.lane_drop_merge_zone_m:
					bad += 1
	eq(bad, 0, "no move into lane 2 within lane_drop_merge_zone_m of a road drop")
	print("      %d moves into lane 2 signaled, all clear of its closures" % into_2)
	eq((sc["checker"] as TrafficRuleChecker).offroad_violations, 0)


func test_merges_obey_no_ambush() -> void:
	# The player drives beside the merge point in lane 1: the car in lane 2 does not move
	# into the player's predicted space (it waits for the player to pass).
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	var bot: TrafficBotPlayer = sc["bot"]
	bot.lane = 1
	bot.state.s = 1100.0
	bot.state.d = (sc["road"] as RoadPath).lane_center_d(1, 1100.0)
	bot.state.v = Units.kmh_to_mps(95.0)
	_add(sc, 1180.0, 2, 95.0)
	for n in roundi(30.0 / DT):
		_tick(sc)
	var c: TrafficRuleChecker = sc["checker"]
	eq(c.ambush_violations, 0, "no ambush")
	eq(c.offroad_violations + c.signal_violations, 0)
	gt(sim.stat_merges, 0, "it merged in the end")


func _trace(seed_value: int) -> int:
	var sc := _scenario(seed_value)
	var sim: TrafficSim = sc["sim"]
	for k in 8:
		_add(sc, 500.0 + 90.0 * float(k), 2, 100.0)
		_add(sc, 520.0 + 110.0 * float(k), 1, 110.0)
	var h: int = TraceHash.SEED
	for n in roundi(40.0 / DT):
		_tick(sc)
		if n % 120 == 0:
			h = sim.state.hash_into(h)
	return h


func test_merges_are_deterministic() -> void:
	eq(_trace(SEED), _trace(SEED), "same seed, same merges")


# ---------------------------------------------------------------- Spawns

func test_spawns_never_use_a_lane_that_is_about_to_end() -> void:
	# The director past the drop and the widening at 200 km/h: no vehicle appears in a
	# lane that closes within merge_spawn_clear_m, or inside a taper.
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, tuning)
	var road := _road(ctx)
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var sim := TrafficSim.new(ctx, road, reg)
	var bot := TrafficBotPlayer.new(road, 0, Units.kmh_to_mps(200.0), TrafficBotPlayer.Mode.CRUISE, 7, 0.0)
	sim.set_player_body(bot.length_m, bot.width_m)
	var dir := TrafficDirector.new(ctx, road, sim, reg.profiles, reg.types, bot.length_m, bot.width_m)
	dir.set_leg(8, 0.0)
	dir.reset(bot.state)
	var checker := TrafficRuleChecker.new(tuning, reg, road, bot.length_m, bot.width_m)
	var ev := ScoreEventBuffer.new(256)
	var seen := {}
	var bad := 0
	var checked := 0
	var clear := tuning.traffic.merge_spawn_clear_m
	var t := 0.0
	while bot.state.s < WIDEN_S + 1500.0:
		bot.update(DT, sim.state)
		sim.step(DT, bot.state, null, ev)
		ev.clear()
		t += DT
		checker.observe(t, sim.state, bot.state)
		dir.step(DT, bot.state)
		var ts := sim.state
		for i in ts.capacity:
			if ts.active[i] == 0 or seen.has(ts.vehicle_id[i]):
				continue
			seen[ts.vehicle_id[i]] = true
			if ts.s[i] < DROP_S - clear - 400.0 or ts.s[i] > WIDEN_S + taper + 100.0:
				continue
			checked += 1
			if sim.closure_ahead(ts.lane[i], ts.s[i]) < clear or ts.lane[i] >= road.lane_count(ts.s[i] + clear):
				bad += 1
	gt(checked, 10, "vehicles were spawned around the drop")
	eq(bad, 0, "none in a lane closing within merge_spawn_clear_m")
	eq(checker.offroad_violations, 0, "nobody off the driving lanes")
	eq(checker.collision_pairs + checker.signal_violations + checker.ambush_violations, 0)


# ---------------------------------------------------------------- Canyon

func test_canyon_tunnel_lane_drop_with_traffic() -> void:
	# The canyon biome's real road (tunnels drop 3 -> 2 lanes): the soak's director,
	# sim, rule checker and weaving bot from 1 km before the first drop to 400 m past
	# the lanes coming back. Nobody leaves the driving lanes, no ambush, no collisions.
	var canyon := BiomePlan.load_biome(&"canyon")
	if not check(canyon != null, "data/biomes/canyon.tres"):
		return
	var r := TrafficSoakRun.new(0, SEED, 8, -1.0, null, 5, canyon)
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
	if not check(drop > 0.0 and back > drop, "the canyon road drops lanes for a tunnel"):
		return
	r.bot.state.s = drop - 1000.0
	r.bot.state.d = r.road.lane_center_d(r.bot.lane, r.bot.state.s)
	r.bot.state.v = Units.kmh_to_mps(150.0)
	r.bot.v_target = r.bot.state.v
	r.bot.set_weave(2.0, 5.0)
	r.director.reset(r.bot.state)
	r.check_windows = false
	while r.bot.state.s < back + 400.0 and r.time < 200.0:
		r.tick()
	var d := r.result()
	print("      canyon drop at %.0f m, lanes back at %.0f m: %d merges, %d vehicles checked on the road" % [
		drop, back, d["merges"], d["lane_moves_checked"]])
	for m: String in d["messages"]:
		print("        ", m)
	eq(int(d["offroad_violations"]), 0, "nobody outside the driving lanes")
	eq(int(d["collision_pairs"]), 0)
	eq(int(d["ambush_violations"]) + int(d["signal_violations"]) + int(d["unsignaled_moves"]), 0)
	gt(int(d["merges"]), 0, "traffic merged for the tunnel")
