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
