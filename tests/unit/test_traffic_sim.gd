extends WBTest
## Traffic simulation suite (src/traffic/traffic_sim.gd, the registry and the profile
## data). Spec: Traffic → Road-space simulation (tick rates, the player as participant,
## cap 60), IDM, MOBIL, Fairness rules 1-4 and 7, Driver types, Traffic reacts to the
## player, Tests (headless: soak, rule checks, determinism); Lives → Fairness rules
## (rear-end prevention); Performance budget → CPU. Model and numbers: docs/TRAFFIC.md.
##
## Rule checks use TrafficRuleChecker (tests/fixtures/traffic), which re-derives every
## rule from the spec's wording and reads only the published TrafficState.

const DT := TrafficScenario.DT
## Per-tick budget (usec) per active vehicle (+ the player), realistic spread; ~3x the
## local median (docs/TRAFFIC.md "Measured cost"; 600 usec at the old cap of 60). The
## bench runs at the cap (traffic.max_active_vehicles, plan D7/D11). A 120 Hz tick is
## 8333 usec.
const TICK_BUDGET_USEC_PER_VEHICLE := 10.0
## Worst case: every vehicle within the near radius (a jam around the player).
const TICK_BUDGET_ALL_NEAR_USEC_PER_VEHICLE := 15.0
const FAST_DENSE_S := 45.0
const SOAK_DENSE_S := 600.0

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


## A scene with no spawner and a player that keeps its lane and follows traffic.
func _scene(seed_value: int, lanes: int = 3, player_kmh: float = 100.0, player_lane: int = 1,
		tuning: Tuning = null) -> TrafficScenario:
	var sc := TrafficScenario.new(seed_value, lanes, tuning)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, player_kmh, player_lane)
	sc.bot.keep_lane()
	return sc


func _dense(seed_value: int, mode: TrafficBotPlayer.Mode, player_kmh: float, lanes: int = 3) -> TrafficScenario:
	var sc := TrafficScenario.new(seed_value, lanes)
	sc.make_bot(mode, player_kmh, 1)
	sc.populate()
	return sc


func _tuning_copy() -> Tuning:
	var c := t.duplicate() as Tuning
	c.traffic = t.traffic.duplicate() as TrafficTuning
	return c


# ---------------------------------------------------------------- Data: profiles and types

func test_registry_profiles_match_spec() -> void:
	var reg := TrafficRegistry.load_default(t.traffic)
	eq(reg.profile_count(), 8, "eight driver profiles")
	eq(reg.type_count(), 10, "ten vehicle types")
	for i in TrafficRegistry.PROFILE_IDS.size():
		eq(reg.profiles[i].id, TrafficRegistry.PROFILE_IDS[i], "profile order = load order")
	for i in TrafficRegistry.TYPE_IDS.size():
		eq(reg.types[i].id, TrafficRegistry.TYPE_IDS[i], "type order = load order")
	# Desired speeds from the spec's driver-types table (km/h).
	var speeds := {
		&"cruiser": [80.0, 100.0], &"commuter": [100.0, 130.0], &"aggressive": [150.0, 190.0],
		&"truck": [80.0, 90.0], &"bus": [85.0, 95.0], &"van": [95.0, 110.0],
		&"motorbike": [110.0, 150.0], &"hesitant": [90.0, 120.0],
	}
	for p in reg.profiles:
		var r: Array = speeds[p.id]
		near(p.desired_speed_min_kmh, r[0], 1e-9, "%s min speed" % p.id)
		near(p.desired_speed_max_kmh, r[1], 1e-9, "%s max speed" % p.id)
		near(p.idm_delta, t.traffic.idm_delta, 0.0, "%s delta = 4" % p.id)
		ge(p.signal_time_s, t.traffic.signal_time_floor_s, "%s signal >= floor" % p.id)
		var sig := t.traffic.signal_time_aggressive_s if p.id == &"aggressive" else t.traffic.signal_time_s
		near(p.signal_time_s, sig, 1e-9, "%s signal time" % p.id)
		if p.id == &"aggressive":
			near(p.lane_change_move_min_s, t.traffic.lane_change_move_aggressive_s, 1e-9)
			near(p.lane_change_move_max_s, t.traffic.lane_change_move_aggressive_s, 1e-9)
		else:
			ge(p.lane_change_move_min_s, t.traffic.lane_change_move_min_s, "%s move time" % p.id)
			le(p.lane_change_move_max_s, t.traffic.lane_change_move_max_s, "%s move time" % p.id)
		check(not reg.types_for_profile(reg.profile_index(p.id)).is_empty(), "%s has a vehicle type" % p.id)
	var hes := reg.profiles[reg.profile_index(&"hesitant")]
	near(hes.cancel_probability, t.traffic.hesitant_cancel_frac(), 1e-9, "Hesitant cancels ~20%")
	eq(hes.min_leg, t.director.hesitant_first_leg, "Hesitant from leg 3")
	for p in reg.profiles:
		if p.id != &"hesitant":
			eq(p.cancel_probability, 0.0, "%s never cancels on purpose" % p.id)
	check(reg.profiles[reg.profile_index(&"truck")].keep_right, "trucks keep right")
	check(reg.profiles[reg.profile_index(&"cruiser")].keep_right, "cruisers keep right")
	check(reg.profiles[reg.profile_index(&"motorbike")].lane_split, "motorbikes may split lanes")
	gt(reg.profiles[reg.profile_index(&"cruiser")].mobil_politeness,
		reg.profiles[reg.profile_index(&"commuter")].mobil_politeness, "cruisers: high politeness")
	lt(reg.profiles[reg.profile_index(&"aggressive")].idm_headway_s,
		reg.profiles[reg.profile_index(&"commuter")].idm_headway_s, "aggressive: short headway")
	lt(reg.profiles[reg.profile_index(&"aggressive")].mobil_politeness,
		reg.profiles[reg.profile_index(&"commuter")].mobil_politeness, "aggressive: low politeness")
	gt(reg.profiles[reg.profile_index(&"aggressive")].lane_change_frequency_scale, 1.0, "aggressive: frequent")
	lt(reg.profiles[reg.profile_index(&"cruiser")].lane_change_frequency_scale, 1.0, "cruiser: rare")
	# Vehicle types: spec lengths and roles.
	near(reg.types[reg.type_index(&"semi")].length_m, 16.0, 1e-9, "truck 16 m")
	near(reg.types[reg.type_index(&"coach")].length_m, 12.0, 1e-9, "bus 12 m")
	for id: StringName in [&"semi", &"coach", &"van"]:
		check(reg.types[reg.type_index(id)].blocks_sightlines, "%s blocks sightlines" % id)
	check(reg.types[reg.type_index(&"motorbike")].is_motorbike)
	lt(reg.types[reg.type_index(&"motorbike")].width_m, 1.0, "motorbikes are narrow")
	var hid := reg.profile_index(&"hesitant")
	for id: StringName in [&"sedan", &"hatchback", &"suv", &"pickup", &"sports", &"coupe"]:
		check(reg.types_for_profile(hid).has(reg.type_index(id)), "Hesitant drives any car (%s)" % id)
	check(reg.types_for_profile(reg.profile_index(&"truck")) == PackedInt32Array([reg.type_index(&"semi")]))
	check(reg.types_for_profile(reg.profile_index(&"bus")) == PackedInt32Array([reg.type_index(&"coach")]))


func test_tuning_sim_fields_and_invariants() -> void:
	var tt := t.traffic
	var d := TrafficTuning.new()
	# WP2.4 fields: data file = documented class default (no silent drift).
	for f: String in ["idm_lookahead_m", "idm_gap_floor_m", "lateral_margin_m", "scripted_max_decel_mps2",
			"mobil_eval_interval_s", "lane_change_cooldown_s", "lane_discipline_bias_mps2",
			"player_lateral_anticipation_s", "player_idm_a_max_mps2", "player_idm_b_comfort_mps2",
			"player_idm_headway_s", "player_idm_s0_m", "player_length_m", "player_width_m",
			"lane_split_max_traffic_kmh", "lane_split_max_speed_kmh", "lane_split_scan_m",
			"lane_split_clearance_m", "lane_split_player_lateral_mps", "lane_split_player_range_m",
			"hit_swerve_m", "hit_swerve_s", "hit_brake_decel_mps2", "hit_brake_s", "brake_tap_decel_mps2",
			"brake_tap_s", "blind_spot_behind_m", "blind_spot_horn_pct",
			"reaction_cooldown_s"]:
		near(float(tt.get(f)), float(d.get(f)), 1e-12, "traffic.tres %s" % f)
	eq(tt.far_tick_ratio(), 4, "120 / 30 Hz")
	near(tt.close_pass_horn_frac(), 0.3, 1e-12)
	# Invariants the model relies on.
	var reg := TrafficRegistry.load_default(tt)
	var widest := 0.0
	var longest := 0.0
	for i in reg.type_count():
		widest = maxf(widest, reg.width[i])
		longest = maxf(longest, reg.length[i])
	lt(tt.lateral_margin_m * 2.0, t.road.lane_width_m - widest, "adjacent-lane trucks never follow each other")
	gt(tt.brake_tap_decel_mps2, tt.brake_light_decel_mps2, "a brake tap shows brake lights")
	lt(tt.hit_brake_decel_mps2, tt.max_decel_mps2 + 1e-9, "hit braking stays within the clamp")
	gt(tt.hit_brake_decel_mps2, tt.brake_light_strong_decel_mps2, "hit braking shows strong brake lights")
	ge(tt.scripted_max_decel_mps2, tt.max_decel_mps2)
	lt(tt.hit_swerve_m, (t.road.lane_width_m - widest) * 0.5 + 0.1, "a hit swerve stays out of the next lane's cars")
	# The leader search horizon covers IDM's s* of every profile at its top speed closing
	# on the slowest traffic in the roster.
	var slowest := INF
	for i in reg.profile_count():
		slowest = minf(slowest, reg.v0_min[i])
	var worst_s := 0.0
	for i in reg.profile_count():
		var v := reg.v0_max[i]
		worst_s = maxf(worst_s, Idm.desired_gap(v, v - slowest, reg.a_max[i], reg.b_comfort[i], reg.headway[i], reg.s0[i]))
	ge(tt.idm_lookahead_m, worst_s, "lookahead covers s* (%.0f m) at the worst closing speed" % worst_s)
	gt(tt.lane_split_max_speed_kmh, tt.lane_split_max_traffic_kmh)


# ---------------------------------------------------------------- Spawn API

func test_spawn_fills_record_and_capacity() -> void:
	var sc := _scene(3)
	var sim := sc.sim
	eq(sim.state.capacity, t.traffic.max_active_vehicles, "capacity = traffic cap (max_active_vehicles)")
	var rec := SpawnSource.Record.new()
	rec.s = 500.0
	rec.lane = 2
	rec.v = 25.0
	rec.v0 = 27.0
	rec.type_id = sc.registry.type_index(&"semi")
	rec.profile_id = sc.registry.profile_index(&"truck")
	rec.model_variant = 1
	rec.color_index = 4
	rec.flags = TrafficState.FLAG_HAZARD | TrafficState.FLAG_SCRIPTED
	var i := sim.spawn(rec)
	ge(i, 0)
	near(sim.state.d[i], sc.road.lane_center_d(2, 500.0), 1e-12, "NAN d = lane center")
	eq(sim.state.lane[i], 2)
	eq(sim.state.target_lane[i], 2)
	eq(sim.state.length[i], 16.0)
	eq(sim.state.width[i], sc.registry.types[rec.type_id].width_m)
	eq(sim.state.v0[i], 27.0)
	eq(sim.state.model_variant[i], 1)
	eq(sim.state.color_index[i], 4)
	eq(sim.state.flags[i], TrafficState.FLAG_HAZARD | TrafficState.FLAG_SCRIPTED, "record flags kept")
	rec.d = 9.0
	var j := sim.spawn(rec)
	near(sim.state.d[j], 9.0, 0.0, "explicit d kept")
	# Fill to capacity; the director owns spacing, so only "full" refuses.
	var n := sim.state.count
	for k in sim.state.capacity - n:
		rec.s = 1000.0 + 20.0 * k
		ge(sim.spawn(rec), 0)
	eq(sim.spawn(rec), -1, "full")
	sim.despawn(i)
	eq(sim.state.count, sim.state.capacity - 1)
	eq(sim.spawn(rec), i, "reuses the freed slot")
	sim.despawn(j)
	sim.despawn(j)   # inactive: ignored
	eq(sim.state.count, sim.state.capacity - 1)
	sim.set_headlights(true)
	rec.s = 50.0
	var h := sim.spawn(rec)
	check(sim.state.has_flag(h, TrafficState.FLAG_HEADLIGHTS), "spawns inherit headlights")
	check(sim.state.has_flag(i, TrafficState.FLAG_HEADLIGHTS), "set_headlights reaches every car")
	sim.set_headlights(false)
	check(not sim.state.has_flag(i, TrafficState.FLAG_HEADLIGHTS))


# ---------------------------------------------------------------- IDM in the sim

func test_following_settles_at_equilibrium_gap_and_player_is_a_leader() -> void:
	# One lane: a car behind a traffic leader, and a car behind the player.
	var sc := _scene(4, 1, 72.0, 0)
	sc.bot.follow = false
	var lead := sc.add(400.0, 0, &"commuter", &"sedan", 72.0, 72.0)
	var foll := sc.add(300.0, 0, &"commuter", &"sedan", 90.0, 144.0)
	var behind_player := sc.add(-150.0, 0, &"commuter", &"sedan", 90.0, 144.0)
	sc.run(120.0)
	var reg := sc.registry
	var pid := reg.profile_index(&"commuter")
	var v := _kmh(72.0)
	var se := Idm.equilibrium_gap(v, _kmh(144.0), reg.headway[pid], reg.s0[pid], 4)
	var gap := sc.sim.state.s[lead] - sc.sim.state.s[foll] - 4.8
	near(sc.sim.state.v[foll], v, 0.01, "follower matches its leader")
	near(gap, se, 0.05, "IDM equilibrium gap (s0 + vT)/sqrt(1 - (v/v0)^4)")
	within_pct(gap, reg.s0[pid] + v * reg.headway[pid], 0.05, "≈ s0 + vT")
	var pgap := sc.bot.state.s - sc.sim.state.s[behind_player] - (4.8 + sc.bot.length_m) * 0.5
	near(sc.sim.state.v[behind_player], v, 0.01, "car behind the player matches the player")
	near(pgap, se, 0.05, "the player is a leader like any car")
	eq(sc.sim.leader_of(behind_player), sc.sim.player_index())
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_headway_scale_shortens_the_equilibrium_gap() -> void:
	# Plan D11: late legs drive closer. set_headway_scale(k) makes every profile's T
	# k x its DriverProfile value (the director sets it per leg).
	var k := 0.8
	var sc := _scene(4, 1, 72.0, 0)
	sc.bot.follow = false
	sc.bot.state.s = -5000.0
	sc.sim.set_headway_scale(k)
	var lead := sc.add(400.0, 0, &"commuter", &"sedan", 72.0, 72.0)
	var foll := sc.add(300.0, 0, &"commuter", &"sedan", 90.0, 144.0)
	sc.run(120.0)
	var reg := sc.registry
	var pid := reg.profile_index(&"commuter")
	var v := _kmh(72.0)
	var gap := sc.sim.state.s[lead] - sc.sim.state.s[foll] - 4.8
	near(gap, Idm.equilibrium_gap(v, _kmh(144.0), reg.headway[pid] * k, reg.s0[pid], 4), 0.05, "gap with T x k")
	lt(gap, Idm.equilibrium_gap(v, _kmh(144.0), reg.headway[pid], reg.s0[pid], 4) - 1.0, "closer than with T")
	sc.sim.set_headway_scale(1.0)
	sc.run(120.0)
	gap = sc.sim.state.s[lead] - sc.sim.state.s[foll] - 4.8
	near(gap, Idm.equilibrium_gap(v, _kmh(144.0), reg.headway[pid], reg.s0[pid], 4), 0.05, "back to T")
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_free_road_reaches_v0() -> void:
	var sc := _scene(4, 1, 100.0, 0)
	sc.bot.state.s = -5000.0
	var car := sc.add(0.0, 0, &"aggressive", &"sports", 60.0, 180.0)
	sc.run(90.0)
	within_pct(sc.sim.state.v[car], _kmh(180.0), 0.02, "free road -> v0")
	le(sc.sim.state.v[car], _kmh(180.0), "never above v0")


func test_stops_behind_a_stopped_player_without_contact() -> void:
	# Single lane (no escape): a stopped player 400 m ahead of cars at 120-190 km/h.
	for pair: Array in [[&"commuter", &"sedan", 120.0], [&"aggressive", &"sports", 190.0], [&"truck", &"semi", 90.0]]:
		var sc := _scene(6, 1, 0.0, 0)
		sc.bot.state.s = 500.0
		sc.bot.state.v = 0.0
		sc.bot.v_target = 0.0
		var car := sc.add(100.0, 0, pair[0], pair[1], pair[2], pair[2])
		sc.run(60.0)
		near(sc.sim.state.v[car], 0.0, 0.01, "%s stopped" % pair[0])
		var gap := sc.bot.state.s - sc.sim.state.s[car] - (sc.sim.state.length[car] + sc.bot.length_m) * 0.5
		gt(gap, 0.0, "%s: no contact" % pair[0])
		eq(sc.checker.player_contacts, 0, "%s never touched the player" % pair[0])
		ge(sc.checker.min_accel, -t.traffic.max_decel_mps2, "%s within the clamp" % pair[0])
		eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_impossible_cut_in_brakes_at_the_clamp() -> void:
	# The player at 100 km/h cuts 3 m in front of a car at 150 km/h: IDM asks for far
	# more than 6 m/s^2; the car brakes exactly at the clamp (contact is the player's fault).
	var sc := _scene(8, 3, 100.0, 0)
	sc.bot.follow = false
	var car := sc.add(1000.0, 1, &"aggressive", &"coupe", 150.0, 150.0)
	sc.bot.state.s = 1000.0 + 3.0 + (4.6 + sc.bot.length_m) * 0.5
	sc.tick()
	sc.bot.lane = 1
	sc.bot.state.d = sc.road.lane_center_d(1, sc.bot.state.s)
	sc.tick()
	eq(sc.sim.leader_of(car), sc.sim.player_index())
	lt(sc.sim.idm_accel(car), -t.traffic.max_decel_mps2 * 2.0, "raw IDM beyond the clamp")
	near(sc.sim.state.accel[car], -t.traffic.max_decel_mps2, 1e-12, "clamped to 6 m/s^2")
	check(sc.sim.state.has_flag(car, TrafficState.FLAG_BRAKE | TrafficState.FLAG_BRAKE_STRONG),
		"strong brake lights")
	var min_a := 0.0
	for k in roundi(4.0 / DT):
		sc.tick()
		min_a = minf(min_a, sc.sim.state.accel[car])
	near(min_a, -t.traffic.max_decel_mps2, 1e-12, "never beyond the clamp")
	eq(sc.checker.decel_violations + sc.checker.brake_flag_violations, 0, sc.checker.summary())


func test_brake_light_thresholds() -> void:
	# Flags must match decel > 1 and > 4 m/s^2 exactly, on every car, every tick (the
	# checker asserts it); a dense run must show both states.
	var sc := _dense(21, TrafficBotPlayer.Mode.WEAVE, 140.0)
	sc.run(30.0)
	eq(sc.checker.brake_flag_violations, 0, sc.checker.summary())
	gt(sc.checker.brake_seen, 0, "brake lights seen")
	# Strong braking in a controlled case: the impossible cut-in above.
	var sc2 := _scene(8, 3, 100.0, 0)
	sc2.bot.follow = false
	var car := sc2.add(1000.0, 1, &"commuter", &"sedan", 120.0, 120.0)
	sc2.bot.state.s = 1000.0 + 12.0
	sc2.bot.state.d = sc2.road.lane_center_d(1, sc2.bot.state.s)
	sc2.bot.lane = 1
	var seen_mild := false
	var seen_strong := false
	for k in roundi(8.0 / DT):
		sc2.tick()
		var a := sc2.sim.state.accel[car]
		var f := sc2.sim.state.flags[car]
		eq((f & TrafficState.FLAG_BRAKE) != 0, a < -t.traffic.brake_light_decel_mps2)
		eq((f & TrafficState.FLAG_BRAKE_STRONG) != 0, a < -t.traffic.brake_light_strong_decel_mps2)
		seen_mild = seen_mild or (a < -1.0 and a > -4.0)
		seen_strong = seen_strong or a < -4.0
	check(seen_mild and seen_strong, "both brake-light levels exercised")


# ---------------------------------------------------------------- Telegraphing and no-ambush

func test_signal_then_smoothstep_move() -> void:
	var sc := _scene(10, 3, 110.0, 2)
	sc.bot.follow = false
	sc.bot.state.s = 900.0   # near (120 Hz model), far behind in lane 2
	var car := sc.add(1000.0, 2, &"commuter", &"sedan", 110.0, 130.0)
	var agg := sc.add(1000.0, 1, &"aggressive", &"sports", 110.0, 170.0)
	sc.tick()
	check(sc.sim.request_lane_change(car, 1) == false, "lane 1 is occupied beside it")
	check(sc.sim.request_lane_change(agg, 0), "free lane")
	check(sc.sim.state.has_flag(agg, TrafficState.FLAG_BLINKER_LEFT), "left blinker")
	var d0 := sc.sim.state.d[agg]
	var t0 := sc.time
	var moved_at := -1.0
	var max_vlat := 0.0
	while sc.sim.state.lane[agg] != 0 and sc.time < t0 + 10.0:
		sc.tick()
		if moved_at < 0.0 and sc.sim.state.d[agg] != d0:
			moved_at = sc.time
		max_vlat = maxf(max_vlat, absf(sc.sim.state.v_lat[agg]))
		if moved_at > 0.0 and sc.sim.state.lc_state[agg] == TrafficState.LaneChange.MOVING:
			var vl := sc.sim.state.v_lat[agg]
			le(vl, 0.0, "v_lat points into the new lane (left = -d)")
	var done_at := sc.time
	ge(moved_at - t0, t.traffic.signal_time_aggressive_s, "aggressive: 0.6 s of blinker first")
	near(moved_at - t0, t.traffic.signal_time_aggressive_s, 2.5 * DT, "...and not much more (near: 120 Hz)")
	near(done_at - moved_at, t.traffic.lane_change_move_aggressive_s, 2.0 * DT, "1.5 s smoothstep move")
	near(max_vlat, 1.5 * sc.road.lane_width(0.0) / t.traffic.lane_change_move_aggressive_s, 0.02,
		"smoothstep peak lateral speed 1.5 * width / T")
	near(sc.sim.state.d[agg], sc.road.lane_center_d(0, 0.0), 1e-12, "ends on the lane center")
	check(not sc.sim.state.has_flag(agg, TrafficState.FLAG_BLINKER_LEFT), "blinker off when done")
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_cancels_when_player_enters_the_gap() -> void:
	var sc := _scene(12, 3, 100.0, 0)
	sc.bot.follow = false
	var car := sc.add(1000.0, 1, &"commuter", &"sedan", 100.0, 130.0)
	sc.bot.state.s = 960.0
	sc.tick()
	check(sc.sim.request_lane_change(car, 0), "gap in lane 0 is fine with the player 40 m back")
	var d0 := sc.sim.state.d[car]
	for k in roundi(0.3 / DT):
		sc.tick()
	eq(sc.sim.state.lc_state[car], TrafficState.LaneChange.SIGNALING)
	# The player darts into the gap beside the car.
	sc.bot.state.s = sc.sim.state.s[car] - 6.0
	sc.tick()
	eq(sc.sim.state.lc_state[car], TrafficState.LaneChange.NONE, "cancelled")
	eq(sc.sim.state.target_lane[car], 1, "stays in its lane")
	check(not sc.sim.state.has_flag(car, TrafficState.FLAG_BLINKER_LEFT), "blinker off")
	eq(sc.sim.stat_cancel_player, 1)
	for k in roundi(3.0 / DT):
		sc.tick()
		eq(sc.sim.state.d[car], d0, "never moved laterally")
	eq(sc.checker.ambush_violations + sc.checker.signal_violations + sc.checker.unsignaled_moves, 0,
		sc.checker.summary())


func test_rule_checks_dense_weaving_short() -> void:
	# Fast-tier version of the soak: dense traffic (16 vehicles/km/lane) and a weaving
	# player; the independent checker must see zero violations of every rule and zero
	# traffic-to-traffic collisions.
	var total_moves := 0
	for seed_value: int in [101, 202]:
		var sc := _dense(seed_value, TrafficBotPlayer.Mode.WEAVE, 150.0)
		sc.run(FAST_DENSE_S)
		var c := sc.checker
		eq(c.total_violations(), 0, "seed %d: %s %s" % [seed_value, c.summary(), c.messages])
		total_moves += c.moves
		eq(sc.events.dropped, 0)
	print("      dense weaving 2 x %.0f s: %d lane moves" % [FAST_DENSE_S, total_moves])
	ge(total_moves, 60, "enough lane changes to mean something (the soak runs thousands)")


func test_never_rear_ends_a_player_driving_normally() -> void:
	# Constant target speed, lane keeping (braking for traffic ahead like a driver):
	# traffic from behind must never touch the player (Lives → rear-end prevention).
	var contacts := 0
	for cfg: Array in [[0, 110.0], [1, 100.0], [2, 95.0]]:
		var sc := TrafficScenario.new(300 + int(cfg[0]))
		sc.make_bot(TrafficBotPlayer.Mode.WEAVE, cfg[1], cfg[0])
		sc.bot.keep_lane()
		sc.populate()
		sc.run(30.0)
		contacts += sc.checker.rear_end_contacts
		eq(sc.checker.rear_end_contacts, 0, "lane %d: %s" % [cfg[0], sc.checker.summary()])
		eq(sc.checker.collisions, 0)
	eq(contacts, 0)


func test_hesitant_cancel_ratio() -> void:
	var r := _hesitant_requests(77, 60.0)
	ge(r[0], 200, "hesitant signals observed")
	near(float(r[1]) / float(r[0]), t.traffic.hesitant_cancel_frac(), 0.07, "about 20%% cancel (%d/%d)" % [r[1], r[0]])


## Many signals quickly: 40 Hesitant cars on 4 lanes asked to change lanes whenever
## they are free to (request_lane_change runs the same telegraphed sequence as a MOBIL
## decision). Returns [signals, cancels] observed by the checker (signals that end
## with no lateral motion).
func _hesitant_requests(seed_value: int, seconds: float) -> Array[int]:
	var sc := TrafficScenario.new(seed_value, 4)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 100.0, 3)
	sc.bot.state.s = -5000.0
	var cars := PackedInt32Array()
	for k in 40:
		cars.append(sc.add(200.0 + 180.0 * float(k >> 2) + 45.0 * float(k % 4), k % 4, &"hesitant", &"sedan", 100.0, 100.0))
	var rng := Rng.new(seed_value)
	for n in roundi(seconds / DT):
		sc.tick()
		if n % 30 == 0:
			for c in cars:
				if sc.sim.state.lc_state[c] == TrafficState.LaneChange.NONE:
					var ln := sc.sim.state.lane[c]
					var target := ln + (1 if (rng.chance(0.5) and ln < 3) or ln == 0 else -1)
					sc.sim.request_lane_change(c, target)
	eq(sc.checker.total_violations(), 0, sc.checker.summary())
	eq(sc.sim.stat_cancel_player + sc.sim.stat_cancel_unsafe, sc.checker.cancels - sc.sim.stat_cancel_hesitant,
		"every observed cancel is accounted for")
	return [sc.checker.hesitant_signals, sc.checker.hesitant_cancels]


## [hesitant signals, hesitant cancels] observed by the checker.
func _hesitant_run(seed_value: int, seconds: float) -> Array[int]:
	var sc := TrafficScenario.new(seed_value)
	var w := PackedFloat64Array()
	w.resize(sc.registry.profile_count())
	w.fill(0.0)
	w[sc.registry.profile_index(&"hesitant")] = 0.6
	w[sc.registry.profile_index(&"truck")] = 0.15
	w[sc.registry.profile_index(&"cruiser")] = 0.1
	w[sc.registry.profile_index(&"aggressive")] = 0.15
	sc.weights = w
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 120.0, 2)
	sc.bot.keep_lane()
	sc.populate()
	sc.run(seconds)
	eq(sc.checker.total_violations(), 0, sc.checker.summary())
	return [sc.checker.hesitant_signals, sc.checker.hesitant_cancels]


# ---------------------------------------------------------------- Motorbike lane splitting

## Two lanes jammed at 40 km/h from s = 300 m on; motorbikes behind.
func _jam(seed_value: int, bikes: int) -> Array:
	var sc := _scene(seed_value, 2, 40.0, 0)
	sc.bot.state.s = -5000.0
	var cars := PackedInt32Array()
	for k in 24:
		var ln := k % 2
		var type := &"semi" if k == 17 else &"sedan"
		var prof := &"truck" if k == 17 else &"commuter"
		cars.append(sc.add(300.0 + 28.0 * float(k >> 1) + 9.0 * ln, ln, prof, type, 40.0, 40.0))
	var bike_slots := PackedInt32Array()
	for b in bikes:
		bike_slots.append(sc.add(260.0 - 25.0 * b, 1 - (b % 2), &"motorbike", &"motorbike", 40.0, 130.0))
	return [sc, cars, bike_slots]


func test_motorbike_splits_lanes_in_slow_traffic() -> void:
	var r := _jam(50, 1)
	var sc: TrafficScenario = r[0]
	var cars: PackedInt32Array = r[1]
	var bike: int = r[2][0]
	var split_seen := false
	var on_boundary := false
	for n in roundi(40.0 / DT):
		sc.tick()
		if sc.sim.is_lane_splitting(bike):
			split_seen = true
			var bd := sc.sim.state.d[bike]
			on_boundary = on_boundary or absf(bd - (sc.road.lane_center_d(0, 0.0) + sc.road.lane_width(0.0) * 0.5)) < 1e-9
	check(split_seen and on_boundary, "the bike rides the lane boundary")
	var passed := 0
	for c in cars:
		if sc.sim.state.s[c] < sc.sim.state.s[bike]:
			passed += 1
	ge(passed, 6, "filters past slow cars")
	le(sc.sim.state.s[bike], sc.sim.state.s[cars[17]], "but not past the (wide) truck")
	gt(sc.checker.moves, 0, "signaled lateral moves")
	eq(sc.checker.total_violations(), 0, "%s %s" % [sc.checker.summary(), sc.checker.messages])
	# Traffic speeds up: the bike returns to a lane center.
	for c in cars:
		sc.sim.state.v0[c] = _kmh(110.0)
	var t_flow := sc.time
	while sc.time < t_flow + 90.0 and (sc.sim.is_lane_splitting(bike)
			or sc.sim.state.lc_state[bike] != TrafficState.LaneChange.NONE):
		sc.tick()
	check(not sc.sim.is_lane_splitting(bike), "back in a lane once traffic flows")
	var d := sc.sim.state.d[bike]
	check(absf(d - sc.road.lane_center_d(0, 0.0)) < 1e-9 or absf(d - sc.road.lane_center_d(1, 0.0)) < 1e-9,
		"on a lane center")
	eq(sc.checker.total_violations(), 0, "%s %s" % [sc.checker.summary(), sc.checker.messages])


func test_motorbike_never_starts_splitting_during_player_lane_change() -> void:
	var r := _jam(51, 1)
	var sc: TrafficScenario = r[0]
	var bike: int = r[2][0]
	sc.bot.follow = false
	sc.bot.state.s = 200.0
	sc.bot.state.v = _kmh(40.0)
	sc.bot.v_target = _kmh(40.0)
	sc.bot.state.v_lat = 1.0   # the player is changing lanes nearby
	for n in roundi(15.0 / DT):
		sc.tick()
		check(state_not_splitting(sc, bike), "no split while the player changes lanes")
		if not state_not_splitting(sc, bike):
			return
	sc.bot.state.v_lat = 0.0
	var split := false
	for n in roundi(15.0 / DT):
		sc.tick()
		split = split or sc.sim.is_lane_splitting(bike)
	check(split, "splits once the player holds its lane")


func state_not_splitting(sc: TrafficScenario, bike: int) -> bool:
	return not sc.sim.is_lane_splitting(bike) and not (
		sc.sim.state.lc_state[bike] != TrafficState.LaneChange.NONE and sc.sim.state.target_lane[bike] == sc.sim.state.lane[bike])


func test_lane_splitting_rule_checks() -> void:
	var r := _jam(52, 4)
	var sc: TrafficScenario = r[0]
	var bikes: PackedInt32Array = r[2]
	var splitting := 0
	for n in roundi(60.0 / DT):
		sc.tick()
		if n % 120 == 0:
			for b in bikes:
				if sc.sim.is_lane_splitting(b):
					splitting += 1
	gt(splitting, 0)
	eq(sc.checker.total_violations(), 0, "%s %s" % [sc.checker.summary(), sc.checker.messages])


# ---------------------------------------------------------------- Reactions to the player

## Owner decision D8: no automatic night-tailgating high beams. The player tailgating a
## car at night (8 m behind, 3 s) sets no FLAG_HIGH_BEAM and emits nothing but the
## reactions that exist; a record's own FLAG_HIGH_BEAM is kept (later: set pieces).
func test_no_automatic_high_beams_at_night() -> void:
	var sc := _scene(30, 3, 100.0, 2)
	sc.bot.follow = false
	sc.sim.set_headlights(true)
	var car := sc.add(1000.0, 2, &"commuter", &"sedan", 100.0, 100.0)
	sc.bot.state.s = 1000.0 - 8.0 - (4.8 + sc.bot.length_m) * 0.5
	var flagged := 0
	for k in roundi(3.0 / DT):
		sc.tick()
		if sc.sim.state.has_flag(car, TrafficState.FLAG_HIGH_BEAM):
			flagged += 1
	eq(flagged, 0, "the sim never sets FLAG_HIGH_BEAM")
	eq(sc.event_counts.get(&"traffic_high_beams", 0), 0, "no high-beam event")
	check(sc.sim.state.has_flag(car, TrafficState.FLAG_HEADLIGHTS), "headlights on at night")
	var lit := sc.add(1500.0, 0, &"commuter", &"sedan", 130.0, 130.0, NAN, TrafficState.FLAG_HIGH_BEAM)
	check(sc.sim.state.has_flag(lit, TrafficState.FLAG_HIGH_BEAM), "a record's own FLAG_HIGH_BEAM is kept")


func test_tight_cut_in_brake_tap() -> void:
	var sc := _scene(31, 3, 110.0, 0)
	sc.bot.follow = false
	var car := sc.add(1000.0, 1, &"commuter", &"sedan", 110.0, 110.0)
	sc.bot.state.s = 1000.0 + 8.0 + (4.8 + sc.bot.length_m) * 0.5
	sc.tick()
	eq(sc.event_counts.get(TrafficSim.KIND_BRAKE_TAP, 0), 0, "no tap while in another lane")
	sc.bot.lane = 1
	sc.bot.state.d = sc.road.lane_center_d(1, 0.0)
	sc.tick()
	eq(sc.event_counts.get(TrafficSim.KIND_BRAKE_TAP, 0), 1, "tap when the player cuts in 8 m ahead")
	le(sc.sim.state.accel[car], -t.traffic.brake_tap_decel_mps2, "taps the brakes")
	check(sc.sim.state.has_flag(car, TrafficState.FLAG_BRAKE), "visible brake lights")
	# A cut-in with room (20 m) does not tap.
	var sc2 := _scene(31, 3, 110.0, 0)
	sc2.bot.follow = false
	sc2.add(1000.0, 1, &"commuter", &"sedan", 110.0, 110.0)
	sc2.bot.state.s = 1000.0 + 20.0 + (4.8 + sc2.bot.length_m) * 0.5
	sc2.tick()
	sc2.bot.lane = 1
	sc2.bot.state.d = sc2.road.lane_center_d(1, 0.0)
	sc2.run(1.0)
	eq(sc2.event_counts.get(TrafficSim.KIND_BRAKE_TAP, 0), 0, "20 m is not a tight cut-in")


func test_blind_spot_horn() -> void:
	for pct: float in [100.0, 0.0]:
		var tt := _tuning_copy()
		tt.traffic.blind_spot_horn_pct = pct
		var sc := _scene(32, 3, 100.0, 1, tt)
		sc.bot.follow = false
		sc.add(1000.0, 2, &"commuter", &"sedan", 100.0, 100.0)
		sc.bot.state.s = 1000.0 - 3.0
		sc.run(t.traffic.blind_spot_horn_s - 0.1)
		eq(sc.event_counts.get(TrafficSim.KIND_HORN, 0), 0, "not before 3 s")
		sc.run(0.3)
		eq(sc.event_counts.get(TrafficSim.KIND_HORN, 0), 1 if pct > 0.0 else 0, "horn at %.0f%%" % pct)


func test_hit_swerve_brake_hazards_recover() -> void:
	var sc := _scene(33, 3, 100.0, 1)
	sc.bot.follow = false
	var car := sc.add(1000.0, 1, &"commuter", &"sedan", 100.0, 100.0)
	sc.bot.state.s = 1000.0 - 5.0
	sc.bot.state.d = sc.road.lane_center_d(1, 0.0) - 0.6   # contact from the left
	sc.tick()
	var d0 := sc.sim.state.d[car]
	sc.sim.notify_hit(car)
	sc.tick()
	eq(sc.event_counts.get(TrafficSim.KIND_HAZARDS, 0), 1, "hazards on")
	check(sc.sim.state.has_flag(car, TrafficState.FLAG_HIT | TrafficState.FLAG_HAZARD))
	var max_off := 0.0
	var min_a := 0.0
	var t_hit := sc.time
	while sc.sim.state.has_flag(car, TrafficState.FLAG_HIT) and sc.time < t_hit + 10.0:
		if sc.time - t_hit < t.traffic.hit_brake_s - 2.0 * DT:
			le(sc.sim.state.accel[car], -t.traffic.hit_brake_decel_mps2 + 1e-9, "brakes hard")
		max_off = maxf(max_off, sc.sim.state.d[car] - d0)
		min_a = minf(min_a, sc.sim.state.accel[car])
		sc.bot.state.s = -5000.0   # the player drives off
		sc.tick()
	near(sc.time - t_hit, t.traffic.hit_recover_s, 0.05, "recovers after ~4 s")
	near(max_off, t.traffic.hit_swerve_m, 0.01, "swerves away from the player (to the right)")
	near(sc.sim.state.d[car], d0, 1e-12, "back on its line")
	ge(min_a, -t.traffic.max_decel_mps2)
	check(not sc.sim.state.has_flag(car, TrafficState.FLAG_HAZARD), "hazards off")
	eq(sc.event_counts.get(TrafficSim.KIND_HAZARDS, 0), 2, "hazards on, then off")
	eq(sc.checker.unsignaled_moves, 0, "the swerve is not a lane change")


func test_honk_and_close_pass_horn_share() -> void:
	var sc := _scene(34)
	var car := sc.add(1000.0, 1, &"commuter", &"sedan", 100.0, 100.0)
	sc.sim.honk(car)
	sc.tick()
	eq(sc.event_counts.get(TrafficSim.KIND_HORN, 0), 1)
	var honks := 0
	var n := 2000
	for k in n:
		if sc.sim.notify_close_pass(car):
			honks += 1
	near(float(honks) / n, t.traffic.close_pass_horn_frac(), 0.04, "~30% of close passes honk")
	sc.events.clear()
	sc.sim.step(DT, sc.bot.state, null, sc.events)
	eq(sc.events.size(), 1, "honks within one tick coalesce per car")
	eq(sc.events.tag[0], TrafficSim.TAG_CLOSE_PASS)


# ---------------------------------------------------------------- Near / far ticks

func test_far_vehicles_tick_at_30_hz_close_to_reference() -> void:
	var tt := _tuning_copy()
	tt.traffic.far_tick_hz = tt.traffic.near_tick_hz   # reference: everything at 120 Hz
	var runs: Array[TrafficScenario] = []
	for tuning: Tuning in [t, tt]:
		var sc := _scene(40, 3, 0.0, 2, tuning)
		sc.bot.state.v = 0.0
		sc.bot.v_target = 0.0
		for k in 12:
			sc.add(400.0 + 60.0 * k, k % 3, &"commuter", &"sedan", 70.0 + 5.0 * k, 110.0 + 3.0 * k)
		sc.observe = false
		runs.append(sc)
	var far := runs[0]
	var ref := runs[1]
	far.run(0.5)
	ref.run(0.5)
	for i in far.sim.state.capacity:
		if far.sim.state.active[i] == 1:
			check(far.sim.state.has_flag(i, TrafficState.FLAG_FAR), "beyond 200 m -> FLAG_FAR")
	var ratio := float(ref.sim.stat_model_updates) / float(far.sim.stat_model_updates)
	near(ratio, 4.0, 0.1, "model evaluated 4x less often (30 vs 120 Hz)")
	far.run(19.5)
	ref.run(19.5)
	var max_ds := 0.0
	var max_dv := 0.0
	for i in far.sim.state.capacity:
		if far.sim.state.active[i] == 1:
			max_ds = maxf(max_ds, absf(far.sim.state.s[i] - ref.sim.state.s[i]))
			max_dv = maxf(max_dv, absf(far.sim.state.v[i] - ref.sim.state.v[i]))
	# Measured: 0.14 m / 0.016 m/s, almost all from the staggered first 30 Hz update
	# (up to 3 ticks at the spawn's zero acceleration). ~0.02% of the 600 m driven.
	lt(max_ds, 0.25, "free-flow positions within 25 cm of the 120 Hz reference after 20 s")
	lt(max_dv, 0.03, "speeds within 0.03 m/s")
	# Near vehicles clear FLAG_FAR.
	var sc_near := _scene(41)
	var near_car := sc_near.add(sc_near.bot.state.s + 50.0, 0, &"commuter", &"sedan", 100.0)
	sc_near.tick()
	check(not sc_near.sim.state.has_flag(near_car, TrafficState.FLAG_FAR))


# ---------------------------------------------------------------- Determinism

func test_determinism_trace() -> void:
	var traces: Array[PackedInt64Array] = []
	for seed_value: int in [555, 555, 556]:
		var sc := _dense(seed_value, TrafficBotPlayer.Mode.WEAVE, 150.0)
		sc.observe = false
		sc.hash_every_s = t.traffic.trace_hash_interval_s
		sc.run(20.0)
		traces.append(sc.hashes)
		gt(sc.sim.stat_signals, 0)
	eq(traces[0].size(), 20, "one hash per second")
	check(traces[0] == traces[1], "same seed + same player -> identical trace every second")
	check(traces[0][19] != traces[2][19], "a different seed diverges")


# ---------------------------------------------------------------- Budget

func test_tick_cost_at_the_cap() -> void:
	var n := t.traffic.max_active_vehicles
	var budget := TICK_BUDGET_USEC_PER_VEHICLE * float(n)
	var budget_near := TICK_BUDGET_ALL_NEAR_USEC_PER_VEHICLE * float(n)
	var sc := _bench_scene(n, 4, false)
	eq(sc.sim.state.count, n, "the cap's worth of vehicles")
	var usec := WBBench.usec_per_call(sc.tick_sim_only, 240, 240, 5)
	WBBench.report("traffic step, %d vehicles + player, 4 lanes (spread -200..+750 m)" % n, usec, budget)
	le(usec, WBBench.budget(budget), "usec per 120 Hz tick")
	var sc2 := _bench_scene(n, 4, true)
	var usec2 := WBBench.usec_per_call(sc2.tick_sim_only, 120, 120, 5)
	WBBench.report("traffic step, %d vehicles all within 200 m" % n, usec2, budget_near)
	le(usec2, WBBench.budget(budget_near), "usec per tick, worst case")


func test_ticks_do_not_grow_memory() -> void:
	var sc := _bench_scene(60, 3, false)
	for k in 240:
		sc.tick_sim_only()
	var before := OS.get_static_memory_usage()
	for k in 600:
		sc.tick_sim_only()
	eq(OS.get_static_memory_usage(), before, "no memory growth over 600 ticks")


## `n` vehicles around the player: realistic spread (-200..+750 m) or all near (+-190 m).
func _bench_scene(n: int, lanes: int, all_near: bool, cap: int = -1) -> TrafficScenario:
	var tt := t
	if cap > 0:
		tt = _tuning_copy()
		tt.traffic.max_active_vehicles = cap
	var sc := TrafficScenario.new(900 + n, lanes, tt)
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 130.0, 1)
	sc.spawner_enabled = false
	sc.observe = false
	if all_near:
		sc.fill_grid(n, -190.0, 190.0)
	else:
		sc.fill_grid(n, -200.0, 750.0)
	for k in 120:
		sc.tick_sim_only()
	return sc


# ---------------------------------------------------------------- Soak

func soak_rule_checks_dense_weaving_10_min() -> void:
	var moves := 0
	for seed_value: int in [1001, 1002, 1003]:
		var sc := _dense(seed_value, TrafficBotPlayer.Mode.WEAVE, 150.0)
		sc.run(SOAK_DENSE_S)
		var c := sc.checker
		print("      soak seed %d: %s, events %s" % [seed_value, c.summary(), sc.event_counts])
		eq(c.total_violations(), 0, "seed %d: %s %s" % [seed_value, c.summary(), c.messages])
		moves += c.moves
	ge(moves, 600, "hundreds of lane changes (3 x 10 min)")


func soak_rule_checks_four_lanes_fast_player() -> void:
	var sc := _dense(2001, TrafficBotPlayer.Mode.WEAVE, 190.0, 4)
	sc.run(SOAK_DENSE_S)
	print("      soak 4 lanes: %s" % sc.checker.summary())
	eq(sc.checker.total_violations(), 0, "%s %s" % [sc.checker.summary(), sc.checker.messages])


func soak_never_rear_ends_normal_player() -> void:
	for lane in 3:
		for kmh: float in [95.0, 120.0, 150.0]:
			var sc := TrafficScenario.new(3000 + lane * 10 + int(kmh))
			sc.make_bot(TrafficBotPlayer.Mode.WEAVE, kmh, lane)
			sc.bot.keep_lane()
			sc.populate()
			sc.run(180.0)
			print("      lane-keeping lane %d %.0f km/h: %s" % [lane, kmh, sc.checker.summary()])
			eq(sc.checker.rear_end_contacts, 0, "lane %d %.0f km/h: %s" % [lane, kmh, sc.checker.summary()])
			eq(sc.checker.total_violations(), 0, sc.checker.summary())


func soak_hesitant_cancel_ratio() -> void:
	var r := _hesitant_requests(4001, 600.0)
	ge(r[0], 1000)
	var ratio := float(r[1]) / float(r[0])
	print("      hesitant (requested): %d/%d = %.3f" % [r[1], r[0], ratio])
	near(ratio, t.traffic.hesitant_cancel_frac(), 0.04, "about 20% cancel")
	# Organic MOBIL decisions in mixed traffic (reported; fewer signals).
	var o := _hesitant_run(4002, 300.0)
	print("      hesitant (organic): %d/%d = %.3f" % [o[1], o[0], float(o[1]) / maxf(1.0, float(o[0]))])
	# Small sample (~40-70 organic signals): a loose sanity bound only.
	near(float(o[1]) / float(o[0]), t.traffic.hesitant_cancel_frac(), 0.15)


func soak_tick_cost_report() -> void:
	# Numbers for docs/TRAFFIC.md and the D7 decision (cap 60 vs ~90).
	for cfg: Array in [[45, 3, false, 60], [60, 3, false, 60], [60, 3, true, 60], [60, 4, false, 60],
			[90, 4, false, 90], [90, 3, false, 90], [90, 4, true, 90], [110, 4, false, 110], [110, 4, true, 110]]:
		var sc := _bench_scene(cfg[0], cfg[1], cfg[2], cfg[3])
		var m := WBBench.measure(sc.tick_sim_only, 600, 240, 9)
		print("      bench  %d vehicles, %d lanes, %s: median %.1f usec (min %.1f, max %.1f), count %d" % [
			cfg[0], cfg[1], "all near" if cfg[2] else "spread", m["median"], m["min"], m["max"], sc.sim.state.count])
