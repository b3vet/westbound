extends WBTest
## The soak's passability bot at a toll's booth lanes (WP6.10; tests/soak/passability_bot.gd,
## PassabilityBot.BoothClosures). Spec: Set pieces (toll gantry: booth lanes beside open
## express lanes), Passability guarantee ("the same module runs in tests with a bot
## driver"). The M6 gate soak found three windows where the bot drove a booth lane at
## full speed and had to brake to the minimum speed behind 50 km/h booth traffic.

const CAR := "res://data/cars/falcon_gt.tres"
const BOOTH_S0 := 900.0
const BOOTH_S1 := 1100.0
const BOOTH_KMH := 50.0

var t: Tuning
var reg: TrafficRegistry
var car: CarDef
var params: VehicleParams


func before_all() -> void:
	t = Tuning.load_default()
	reg = TrafficRegistry.load_default(t.traffic)
	car = load(CAR) as CarDef
	params = VehicleParams.build(t, car)


func _sim(road: RoadPath) -> TrafficSim:
	var sim := TrafficSim.new(RunContext.new(7, RunContext.MODE_JOURNEY, t), road, reg)
	sim.add_speed_zone(0, BOOTH_S0, BOOTH_S1, Units.kmh_to_mps(BOOTH_KMH), 1)
	return sim


func test_booth_lanes_are_closed_ahead_of_their_slow_traffic() -> void:
	var road := StraightRoadPath.new(3, t.road)
	var sim := _sim(road)
	var bc := PassabilityBot.BoothClosures.new()
	bc.sim = sim
	var v_min := t.scoring.min_speed_mps()
	bc.refresh(3, 0.0, PassabilityBot.BOOTH_LOOK_M, v_min, 1, 10.0)
	eq(bc.lane_closure_count(), 1, "one booth lane")
	var a := 0.0 + bc.closure_ahead(0, 0.0)
	# Booth traffic drops below the minimum speed shortly before the zone (its braking
	# envelope); the lane closes BOOTH_LEAD_M before that.
	lt(a, BOOTH_S0 - PassabilityBot.BOOTH_LEAD_M)
	gt(a, BOOTH_S0 - PassabilityBot.BOOTH_LEAD_M - 200.0)
	check(is_inf(bc.closure_ahead(1, 0.0)) and is_inf(bc.closure_ahead(2, 0.0)), "express lanes open")
	lt(float(sim.speed_limit_at(0, a + PassabilityBot.BOOTH_LEAD_M + PassabilityBot.BOOTH_SAMPLE_M, 0)), v_min + 1e-9,
		"slow from BOOTH_LEAD_M past the closure's start")
	# A bot still in the booth lane gets its closure just beyond its body: a way out as
	# soon as a gap opens, not a closure it is already inside.
	bc.refresh(3, a + 50.0, a + 50.0 + PassabilityBot.BOOTH_LOOK_M, v_min, 0, car.length_m + 10.0)
	near(bc.closure_ahead(0, a + 50.0), car.length_m + 10.0, 1e-9)
	# No speed zone: nothing closed.
	var plain := PassabilityBot.BoothClosures.new()
	plain.sim = TrafficSim.new(RunContext.new(7, RunContext.MODE_JOURNEY, t), road, reg)
	plain.refresh(3, 0.0, 900.0, v_min, 0, 10.0)
	eq(plain.lane_closure_count(), 0)


func test_the_bot_leaves_a_booth_lane_before_the_booths() -> void:
	# Empty road, the bot in the booth lane at 150 km/h: it is in an express lane before
	# its booth traffic would be below the minimum speed, and never slows below it.
	var road := StraightRoadPath.new(3, t.road)
	var sim := _sim(road)
	var bot := PassabilityBot.new(road, reg, t, car, params, 0, Units.kmh_to_mps(150.0), 11)
	bot.closures = sim
	bot.v_target = Units.kmh_to_mps(150.0)
	bot.keep_lane()
	var ts := TrafficState.new(8)
	var v_min := t.scoring.min_speed_mps()
	var min_v := INF
	var dt := 1.0 / float(t.vehicle.physics_tick_hz)
	while bot.state.s < BOOTH_S1:
		bot.update(dt, ts)
		min_v = minf(min_v, bot.state.v)
		if bot.state.s > BOOTH_S0 - PassabilityBot.BOOTH_LEAD_M:
			if not ne(road.lane_index_at(bot.state.d, bot.state.s), 0, "out of the booth lane at s %.0f" % bot.state.s):
				return
	ge(min_v, v_min - 1e-6, "never below the minimum speed")
	eq(bot.no_path_checks, 0)
