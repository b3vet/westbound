extends WBTest
## MOBIL suite (pure criteria in src/traffic/mobil.gd, the no-ambush predicate in
## src/traffic/no_ambush.gd, and MOBIL decisions through TrafficSim). Spec: Traffic →
## Lane changes: MOBIL (incentive, safety, politeness, keep-right bias, player b_safe
## of 2 m/s^2); Fairness rules 2 and 7.

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


# ---------------------------------------------------------------- Pure criteria

func test_incentive_math() -> void:
	# (a~c - ac) + p [(a~n - an) + (a~o - ao)]
	near(Mobil.incentive(1.0, -0.5, -0.4, 0.2, 0.3, -0.1, 0.5), 1.5 + 0.5 * (-0.6 + 0.4), 1e-12)
	near(Mobil.incentive(1.0, -0.5, -0.4, 0.2, 0.3, -0.1, 0.0), 1.5, 1e-12, "p = 0: selfish")
	near(Mobil.incentive(0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0), -1.0, 1e-12, "p = 1: counts others fully")


func test_keep_right_bias_is_asymmetric() -> void:
	var a_th := 0.2
	var bias := 0.3
	near(Mobil.threshold(a_th, bias, false), 0.5, 1e-12, "left: a_th + a_bias")
	near(Mobil.threshold(a_th, bias, true), -0.1, 1e-12, "right: a_th - a_bias")
	# With a_bias > a_th a driver moves right even with zero advantage...
	check(Mobil.accepts(0.0, a_th, bias, true), "drifts right when it costs nothing")
	check(not Mobil.accepts(0.0, a_th, bias, false), "...but never left without a gain")
	check(Mobil.accepts(0.6, a_th, bias, false), "overtakes when the gain beats a_th + a_bias")
	check(not Mobil.accepts(0.5, a_th, bias, false), "strictly greater")


func test_safety_and_player_b_safe() -> void:
	var pb := t.traffic.player_b_safe_mps2
	near(pb, 2.0, 1e-12, "spec: player b_safe 2 m/s^2")
	check(Mobil.is_safe(-3.0, 4.0))
	check(Mobil.is_safe(-4.0, 4.0), "boundary counts as safe (a~n >= -b_safe)")
	check(not Mobil.is_safe(-4.01, 4.0))
	near(Mobil.b_safe_for(4.0, false, pb), 4.0, 0.0, "traffic follower: profile b_safe")
	near(Mobil.b_safe_for(4.0, true, pb), 2.0, 0.0, "player follower: tightened to 2")
	near(Mobil.b_safe_for(1.5, true, pb), 1.5, 0.0, "never loosened")
	check(Mobil.is_safe(-3.0, Mobil.b_safe_for(4.0, false, pb)), "3 m/s^2 is fine for traffic")
	check(not Mobil.is_safe(-3.0, Mobil.b_safe_for(4.0, true, pb)), "...but not for the player")


func test_no_ambush_predicate() -> void:
	var w := t.traffic.no_ambush_window_s
	var m := t.traffic.no_ambush_margin_m
	# Car at s=0, 25 m/s, target lane center d=3.5. Player in the target lane.
	# Player 20 m behind at the same speed: 20 - 4.7 = 15.3 m apart > margin -> clear.
	check(not NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 3.5, -20.0, 25.0, 3.5, 0.0, 4.5, 1.9, w, m))
	# Closing at 10 m/s from 20 m: within 1.5 s the gap 15.3 m shrinks to 0.3 m < 1 m -> ambush.
	check(NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 3.5, -20.0, 35.0, 3.5, 0.0, 4.5, 1.9, w, m))
	# Closing at 9 m/s: 15.3 - 13.5 = 1.8 m > 1 m margin -> clear.
	check(not NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 3.5, -20.0, 34.0, 3.5, 0.0, 4.5, 1.9, w, m))
	# Player alongside one lane further (d=7.1): clear while it holds its lane...
	check(not NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 7.1, 0.0, 25.0, 10.7, 0.0, 4.5, 1.9, w, m))
	# ...but not while it moves toward the target lane at 1 m/s (3.6 - 1.5 < 2.875).
	check(NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 7.1, 0.0, 25.0, 10.7, -1.0, 4.5, 1.9, w, m))
	# Moving away: clear.
	check(not NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 7.1, 0.0, 25.0, 10.7, 1.0, 4.5, 1.9, w, m))
	# Player already in the target space: violation at t = 0.
	check(NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 3.5, 2.0, 25.0, 3.6, 0.0, 4.5, 1.9, w, m))
	# Lateral and longitudinal overlap at different times does not count.
	check(not NoAmbush.violates(0.0, 25.0, 4.8, 1.85, 3.5, -30.0, 35.0, 7.1, -2.0, 4.5, 1.9, w, m),
		"reaches the lane early but the car's s late")


# ---------------------------------------------------------------- Decisions in the sim

## A 3-lane scene with the player parked far behind (no interaction).
func _scene(seed_value: int = 11) -> TrafficScenario:
	var sc := TrafficScenario.new(seed_value)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 100.0, 2)
	sc.bot.state.s = -5000.0
	return sc


func test_overtakes_a_slow_truck() -> void:
	var sc := _scene()
	var truck := sc.add(300.0, 2, &"truck", &"semi", 85.0)
	var car := sc.add(200.0, 2, &"commuter", &"sedan", 120.0)
	check(truck >= 0 and car >= 0)
	var left := false
	for k in roundi(40.0 / TrafficScenario.DT):
		sc.tick()
		if sc.sim.state.lane[car] < 2:
			left = true
			break
	check(left, "commuter pulls out behind a truck")
	eq(sc.checker.total_violations(), 0, sc.checker.summary())


func test_keep_right_drift_and_truck_lanes() -> void:
	var sc := _scene()
	var car := sc.add(100.0, 0, &"cruiser", &"sedan", 90.0)
	var truck := sc.add(400.0, 0, &"truck", &"semi", 85.0)
	sc.run(60.0)
	eq(sc.sim.state.lane[car], 2, "a lone cruiser drifts back to the right lane")
	ge(sc.sim.state.lane[truck], 1, "a truck spawned in lane 0 moves into the right two lanes")
	# A truck never moves left of its allowed lanes, even behind a slower truck.
	var sc2 := _scene()
	sc2.add(300.0, 1, &"truck", &"semi", 70.0, 70.0)
	var t2 := sc2.add(200.0, 1, &"truck", &"semi", 88.0)
	sc2.run(40.0)
	ge(sc2.sim.state.lane[t2], 1, "trucks stay in the right two lanes")
	eq(sc.checker.total_violations() + sc2.checker.total_violations(), 0)


func test_player_follower_tightens_b_safe() -> void:
	# A commuter (b_safe 3.5) in lane 1 asks for lane 0. In lane 0 a follower at the same
	# speed sits GAP_M behind: accepting the change makes it brake 2..3.5 m/s^2. That is
	# fine for a traffic follower, but not for the player (b_safe tightens to 2).
	const GAP_M := 29.0
	var v := Units.kmh_to_mps(108.0)
	var results: Array[bool] = []
	for use_player: bool in [false, true]:
		var sc := TrafficScenario.new(5)
		sc.spawner_enabled = false
		sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 108.0, 0)
		sc.bot.follow = false
		var car_s := 1000.0
		var a_n: float
		if use_player:
			sc.bot.state.s = car_s - GAP_M - (4.8 + sc.bot.length_m) * 0.5
			a_n = Idm.interaction_accel(v, GAP_M, 0.0, t.traffic.player_idm_a_max_mps2,
				t.traffic.player_idm_b_comfort_mps2, t.traffic.player_idm_headway_s, t.traffic.player_idm_s0_m, 0.1)
		else:
			sc.bot.state.s = -5000.0
			sc.add(car_s - GAP_M - 4.8, 0, &"commuter", &"sedan", 108.0, 108.0)
			a_n = Idm.accel(v, v, GAP_M, 0.0, 1.5, 2.0, 1.3, 2.0, 4, 0.1)
		check(a_n < -t.traffic.player_b_safe_mps2 and a_n > -3.5,
			"geometry: the follower would brake between 2 and 3.5 m/s^2 (%.2f, player=%s)" % [a_n, use_player])
		var car := sc.add(car_s, 1, &"commuter", &"sedan", 108.0, 130.0)
		sc.sim.step(0.0, sc.bot.state, null, sc.events)   # refresh the order and the player
		results.append(sc.sim.request_lane_change(car, 0))
	check(results[0], "traffic follower: b_safe 3.5 allows the change")
	check(not results[1], "player follower: b_safe tightens to 2 and refuses it")


func test_no_ambush_refuses_in_the_sim() -> void:
	# 1) The player closes fast in lane 0 behind a car that asks for lane 0.
	var sc := TrafficScenario.new(9)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 160.0, 0)
	sc.bot.state.s = 975.0
	var car := sc.add(1000.0, 1, &"commuter", &"sedan", 100.0, 130.0)
	sc.sim.step(0.0, sc.bot.state, null, sc.events)
	check(not sc.sim.request_lane_change(car, 0), "refused: the player will be there within 1.5 s")
	sc.bot.state.s = 700.0
	sc.sim.step(0.0, sc.bot.state, null, sc.events)
	check(sc.sim.request_lane_change(car, 0), "allowed once the player is far enough back")
	# 2) The player one lane beyond the target lane, alongside, drifting toward it: MOBIL's
	# gap search does not see it in the target lane, only the no-ambush prediction does.
	var sc2 := TrafficScenario.new(9)
	sc2.spawner_enabled = false
	sc2.make_bot(TrafficBotPlayer.Mode.CRUISE, 110.0, 0)
	sc2.bot.state.s = 1000.0
	sc2.bot.state.v_lat = 1.5
	var car2 := sc2.add(1000.0, 2, &"commuter", &"sedan", 110.0, 130.0)
	sc2.sim.step(0.0, sc2.bot.state, null, sc2.events)
	check(not sc2.sim.request_lane_change(car2, 1), "refused: the player drifts into the target space")
	sc2.bot.state.v_lat = 0.0
	sc2.sim.step(0.0, sc2.bot.state, null, sc2.events)
	check(sc2.sim.request_lane_change(car2, 1), "allowed while the player holds its lane")
