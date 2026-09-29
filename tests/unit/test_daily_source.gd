extends WBTest
## Daily Drive's traffic (WP6.2). Spec: Traffic → Traffic director ("Built-in sources:
## Flow (default), SetPiece, and Daily (Flow seeded by date)"); Core loop → Modes at
## launch ("Daily Drive: the seed is a hash of the UTC date, so route, forks, traffic and
## set pieces are the same for everyone that day"); Architecture rule 2.
##
## Daily is Flow on the date-seeded run context (RunContext.daily -> run.rng_traffic);
## the SetPiece source wraps it, and the waves and set pieces draw from the same
## date-seeded streams. So two players on the same date driving the same inputs get the
## same road, traffic and set pieces; another date gives others.

const DT := 1.0 / 120.0
const DRIVE_S := 25.0

var tuning: Tuning


func before_all() -> void:
	tuning = Tuning.load_default()


func test_daily_mode_runs_the_daily_source() -> void:
	var ctx := RunContext.daily(2026, 9, 29)
	eq(ctx.mode, RunContext.MODE_DAILY)
	eq(ctx.run_seed, Rng.daily_seed(2026, 9, 29), "seeded by the date")
	var road := ProceduralRoadPath.new(ctx)
	var reg := TrafficRegistry.load_default(ctx.tuning.traffic)
	var sim := TrafficSim.new(ctx, road, reg)
	var dir := TrafficDirector.new(ctx, road, sim, reg.profiles, reg.types, 4.5, 1.9)
	eq(dir.flow.source_id(), &"daily", "Daily is the director's flow")
	eq(dir.source.source_id(), &"set_piece", "set pieces wrap it")
	check(dir.set_pieces.flow == dir.flow, "the set-piece source fills its batches with Daily")
	var journey := RunContext.new(ctx.run_seed, RunContext.MODE_JOURNEY)
	var dir_j := TrafficDirector.new(journey, ProceduralRoadPath.new(journey),
		TrafficSim.new(journey, road, reg), reg.profiles, reg.types, 4.5, 1.9)
	eq(dir_j.flow.source_id(), &"flow", "Journey runs Flow")


## One daily drive: the procedural road, the real sim and director, a weaving bot (its
## own seed from the run's events stream: the same inputs for the same date). Every set
## peak gets a set piece (chance 100%) so one shows within the drive. Returns [trace hash
## of both carriageways and the player every second, the set pieces, a road sample].
func _drive(y: int, m: int, d: int, seconds: float) -> Array:
	var t: Tuning = tuning.duplicate()
	t.director = tuning.director.duplicate() as DirectorTuning
	t.director.set_piece_chance_first_pct = 100.0
	t.director.set_piece_chance_last_pct = 100.0
	var ctx := RunContext.daily(y, m, d, t)
	var road := ProceduralRoadPath.new(ctx)
	var reg := TrafficRegistry.load_default(t.traffic)
	var sim := TrafficSim.new(ctx, road, reg)
	var bot_rng := ctx.rng_events.derive(&"daily_test_bot")
	var bot := TrafficBotPlayer.new(road, 1, Units.kmh_to_mps(210.0), TrafficBotPlayer.Mode.WEAVE, bot_rng.int_range(1, 1 << 30))
	bot.set_weave(2.0, 5.0)
	sim.set_player_body(bot.length_m, bot.width_m)
	var dir := TrafficDirector.new(ctx, road, sim, reg.profiles, reg.types, bot.length_m, bot.width_m)
	var ev := ScoreEventBuffer.new(256)
	dir.events = ev
	dir.set_leg(2, 0.0)
	dir.reset(bot.state)
	check(dir.force_set_piece(&"truck_wall"), "a truck wall in the first batch")
	var trace: int = TraceHash.SEED
	var pieces := ""
	var next_hash := 1.0
	var time := 0.0
	for k in roundi(seconds / DT):
		bot.update(DT, sim.state)
		sim.step(DT, bot.state, null, ev)
		dir.step(DT, bot.state)
		for e in ev.size():
			if ev.kind[e] == SetPieceSource.KIND_WARNING or ev.kind[e] == SetPieceSource.KIND_STARTED:
				pieces += "%s:%s@%.2f " % [ev.kind[e], ev.tag[e], time]
		ev.clear()
		time += DT
		if time >= next_hash:
			next_hash += 1.0
			trace = sim.state.hash_into(trace)
			trace = dir.opposite.state.hash_into(trace)
			trace = bot.state.hash_into(trace)
	for inst in dir.set_pieces.instances:
		if inst.stage != SetPieceSource.Stage.FREE:
			pieces += "%s@%.3f" % [inst.def.id, inst.s_rear]
	var smp := road.sample(1500.0)
	return [trace, pieces, "%.6f %.6f %.6f" % [smp.pos_x, smp.pos_y, smp.pos_z], dir.set_pieces.spawned]


func test_same_date_same_road_traffic_and_set_pieces() -> void:
	var a := _drive(2026, 9, 29, DRIVE_S)
	var b := _drive(2026, 9, 29, DRIVE_S)
	gt(int(a[3]), 0, "a set piece spawned")
	print("      daily 2026-09-29: trace %d, pieces: %s" % [a[0], a[1]])
	eq(a[2], b[2], "same route")
	eq(a[0], b[0], "same traffic trace")
	eq(a[1], b[1], "same set pieces")
	var c := _drive(2026, 9, 30, DRIVE_S * 0.4)
	var a_short := _drive(2026, 9, 29, DRIVE_S * 0.4)
	ne(c[0], a_short[0], "another date: other traffic")
	ne(c[2], a_short[2], "and another route")
