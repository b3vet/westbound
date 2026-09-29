extends WBTest
## Driver profiles after plan D15 (WP6.6; owner, M5 playtest: "a variety of fast cars ...
## fast enough for me to follow for a bit and try to overtake"). Spec: Traffic →
## Driver types (+ Racer), Fairness rules 1-4 (telegraphing, no ambush, readable
## braking, no sudden stops), Lives → Fairness rules (rear-end prevention). The spec
## table itself is pinned in test_traffic_sim.gd (test_registry_profiles_match_spec).

var t: Tuning
var reg: TrafficRegistry


func before_all() -> void:
	t = Tuning.load_default()
	reg = TrafficRegistry.load_default(t.traffic)


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


func _p(id: StringName) -> DriverProfile:
	return reg.profiles[reg.profile_index(id)]


## A straight road, no spawner, a lane-keeping player that follows traffic.
func _scene(seed_value: int, player_kmh: float, player_lane: int, lanes: int = 3) -> TrafficScenario:
	var sc := TrafficScenario.new(seed_value, lanes)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, player_kmh, player_lane)
	sc.bot.keep_lane()
	return sc


# ---------------------------------------------------------------- Data

func test_racer_is_appended_to_the_registry() -> void:
	# Ids are stored in traces and saves: the racer goes at the end, the spec's eight keep
	# their indices.
	eq(TrafficRegistry.PROFILE_IDS.back(), &"racer")
	eq(reg.profile_index(&"racer"), TrafficRegistry.PROFILE_IDS.size() - 1)
	eq(reg.profile_index(&"hesitant"), 7, "the spec's profiles keep their ids")
	eq(t.traffic.spawn_racer_profile_id, &"racer")


func test_racer_profile() -> void:
	var r := _p(&"racer")
	var agg := _p(&"aggressive")
	var com := _p(&"commuter")
	# ~190-250 km/h: faster than the aggressive driver, followable by the player's cars
	# (270 km/h and up with boost).
	near(r.desired_speed_min_kmh, 190.0, 1e-9)
	near(r.desired_speed_max_kmh, 250.0, 1e-9)
	gt(r.desired_speed_max_kmh, agg.desired_speed_max_kmh)
	for car: String in ["brute_v8", "falcon_gt", "night_viper"]:
		var def := load("res://data/cars/%s.tres" % car) as CarDef
		lt(r.desired_speed_max_kmh, def.top_speed_kmh, "%s can catch a racer" % car)
	# Decisive, and telegraphed like the aggressive driver (fairness rule 1).
	near(r.signal_time_s, t.traffic.signal_time_aggressive_s, 1e-9, "0.6 s blinker")
	ge(reg.signal_s[reg.profile_index(&"racer")], t.traffic.signal_time_floor_s, "never under 0.5 s")
	near(r.lane_change_move_min_s, t.traffic.lane_change_move_aggressive_s, 1e-9, "1.5 s move")
	near(r.lane_change_move_max_s, t.traffic.lane_change_move_aggressive_s, 1e-9)
	le(r.idm_headway_s, agg.idm_headway_s, "short headway")
	lt(r.mobil_politeness, com.mobil_politeness, "low politeness")
	gt(r.lane_change_frequency_scale, 1.0, "frequent lane changes")
	lt(r.mobil_keep_right_bias_mps2, r.mobil_threshold_mps2, "a free racer does not drift right")
	eq(r.cancel_probability, 0.0, "never hesitates")
	check(not r.keep_right)
	eq(r.min_leg, 1)
	gt(r.spawn_left_lane_count, 0, "a fast-lane profile")
	near(r.idm_delta, t.traffic.idm_delta, 0.0)
	# Sports cars and coupes only.
	var types := reg.types_for_profile(reg.profile_index(&"racer"))
	check(not types.is_empty())
	for ti in types:
		check(reg.types[ti].id in [&"sports", &"coupe"], "racer drives %s" % reg.types[ti].id)


func test_wider_speed_spreads() -> void:
	# Plan D15: commuter 100-130 -> 95-145, aggressive 150-190 -> 140-200.
	var com := _p(&"commuter")
	var agg := _p(&"aggressive")
	gt(com.desired_speed_max_kmh - com.desired_speed_min_kmh, 30.0, "commuter spread widened")
	gt(agg.desired_speed_max_kmh - agg.desired_speed_min_kmh, 40.0, "aggressive spread widened")
	lt(com.desired_speed_max_kmh, agg.desired_speed_max_kmh)
	lt(agg.desired_speed_min_kmh, _p(&"racer").desired_speed_min_kmh)
	# Only the racer and aggressive drivers exceed 150 km/h.
	for p in reg.profiles:
		if p.id != &"racer" and p.id != &"aggressive":
			le(p.desired_speed_max_kmh, 150.0, "%s stays at or below 150 km/h" % p.id)


func test_lookahead_covers_the_racer() -> void:
	# A racer at its top speed closing on the slowest traffic sees it before IDM's s*.
	var pr := reg.profile_index(&"racer")
	var slowest := INF
	for i in reg.profile_count():
		slowest = minf(slowest, reg.v0_min[i])
	var v := reg.v0_max[pr]
	var s_star := Idm.desired_gap(v, v - slowest, reg.a_max[pr], reg.b_comfort[pr], reg.headway[pr], reg.s0[pr])
	ge(t.traffic.idm_lookahead_m, s_star, "lookahead %.0f m >= s* %.0f m" % [t.traffic.idm_lookahead_m, s_star])


# ---------------------------------------------------------------- Fairness with racers

func test_racer_brakes_behind_a_slow_lane_keeping_player() -> void:
	# Rear-end prevention: a racer at 250 km/h closes on a player holding 100 km/h in a
	# single lane (no escape). IDM with the player as leader: no contact, never beyond the
	# 6 m/s^2 clamp.
	for type: StringName in [&"sports", &"coupe"]:
		var sc := _scene(31, 100.0, 0, 1)
		var car := sc.add(-400.0, 0, &"racer", type, 250.0, 250.0)
		sc.run(40.0)
		eq(sc.checker.player_contacts, 0, "%s racer never touched the player" % type)
		ge(sc.checker.min_accel, -t.traffic.max_decel_mps2 - 1e-9, "within the clamp")
		lt(sc.checker.min_accel, -1.0, "it did brake")
		near(sc.sim.state.v[car], sc.bot.state.v, 0.5, "and follows the player")
		eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_racer_stops_behind_a_stopped_player() -> void:
	var sc := _scene(32, 0.0, 0, 1)
	sc.bot.state.s = 600.0
	sc.bot.state.v = 0.0
	sc.bot.v_target = 0.0
	var car := sc.add(100.0, 0, &"racer", &"sports", 240.0, 240.0)
	sc.run(40.0)
	near(sc.sim.state.v[car], 0.0, 0.01, "stopped")
	eq(sc.checker.player_contacts, 0)
	ge(sc.checker.min_accel, -t.traffic.max_decel_mps2 - 1e-9)
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_racer_passes_a_slower_player_telegraphed() -> void:
	# A racer from behind in the lane left of a lane-keeping player at 130 km/h comes past
	# (what the player sees and can chase), and a slower car ahead of it in its lane makes
	# it change lanes: blinker first, no ambush.
	var sc := _scene(33, 130.0, 1)
	var car := sc.add(-60.0, 0, &"racer", &"coupe", 170.0, 230.0)
	sc.add(500.0, 0, &"commuter", &"sedan", 140.0, 140.0)
	sc.run(30.0)
	gt(sc.sim.state.s[car] - sc.bot.state.s, 150.0, "the racer came past and pulled away")
	gt(sc.sim.state.v[car], _kmh(190.0), "at racer speed")
	gt(sc.checker.moves, 0, "it changed lanes around the slower car")
	eq(sc.checker.player_contacts, 0)
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_racers_in_dense_weaving_traffic() -> void:
	# Dense mixed traffic with a racer share and a weaving player: no collisions, no rule
	# violations (signal time, no ambush, clamp, brake lights).
	for seed_value: int in [41, 42]:
		var sc := TrafficScenario.new(seed_value)
		var w := PackedFloat64Array()
		w.resize(reg.profile_count())
		w.fill(0.0)
		w[reg.profile_index(&"racer")] = 0.2
		w[reg.profile_index(&"aggressive")] = 0.15
		w[reg.profile_index(&"commuter")] = 0.35
		w[reg.profile_index(&"cruiser")] = 0.1
		w[reg.profile_index(&"truck")] = 0.1
		w[reg.profile_index(&"van")] = 0.1
		sc.weights = w
		sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 160.0, 1)
		sc.populate()
		sc.run(40.0)
		eq(sc.checker.collision_pairs, 0, "seed %d: no traffic collisions" % seed_value)
		eq(sc.checker.total_violations(), 0, sc.checker.summary())
		gt(sc.checker.moves, 10, "lane changes happened")


func test_racer_trace_is_deterministic() -> void:
	var a := _racer_trace(51)
	var b := _racer_trace(51)
	eq(a.size(), b.size())
	eq(a, b, "same seed, same trace")
	ne(a, _racer_trace(52), "another seed differs")


func _racer_trace(seed_value: int) -> PackedInt64Array:
	var sc := TrafficScenario.new(seed_value)
	var w := PackedFloat64Array()
	w.resize(reg.profile_count())
	w.fill(0.0)
	w[reg.profile_index(&"racer")] = 0.3
	w[reg.profile_index(&"commuter")] = 0.5
	w[reg.profile_index(&"truck")] = 0.2
	sc.weights = w
	sc.hash_every_s = 1.0
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 150.0, 1)
	sc.populate()
	sc.run(10.0)
	return sc.hashes
