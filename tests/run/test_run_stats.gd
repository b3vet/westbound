extends WBTest
## RunStats (src/run/run_stats.gd): the results payload from ticks and event records.


func test_aggregates_events_and_ticks() -> void:
	var stats := RunStats.new(100.0)
	var buf := ScoreEventBuffer.new(32)
	buf.push(ScoreEvents.PASS, 15)
	buf.push(ScoreEvents.CLOSE_PASS, 60)
	buf.push(ScoreEvents.CLOSE_PASS, 90)
	buf.push(ScoreEvents.THREAD, 200)
	buf.push(ScoreEvents.CUT, 30)
	buf.push(ScoringRuleSet.KIND_BANKED, 395, 1.0, -1.0, -1, 395.0, ScoreEvents.REASON_CASH_OUT)
	buf.push(ScoringRuleSet.KIND_CHAIN_LOST, 1200, 1.0, -1.0, -1, 0.0, ScoreEvents.REASON_HIT)
	buf.push(ScoringRuleSet.KIND_BANKED, 800, 1.0, -1.0, -1, 1195.0, ScoreEvents.REASON_CHECKPOINT)
	buf.push(Lives.KIND_HIT, 0, 0.0, -1.0, -1, 1.0, HitDetection.HIT_TRAFFIC)
	buf.push(LegTracker.KIND_CHECKPOINT_CROSSED, 0, 0.0, -1.0, -1, 1.0)
	buf.push(LegTracker.KIND_CHECKPOINT_CROSSED, 0, 0.0, -1.0, -1, 2.0)
	buf.push(LegTracker.KIND_COAST_REACHED)
	stats.consume(buf, 0, 4)
	eq(stats.passes, 3)
	eq(stats.close_passes, 2)
	eq(stats.threads, 1)
	eq(stats.cuts, 0, "only records [0, 4) so far")
	stats.consume(buf, 4, buf.size())
	eq(stats.cuts, 1)
	eq(stats.best_chain, 1200, "largest banked or lost chain")
	eq(stats.hits, 1)
	eq(stats.legs_completed, 2)
	eq(stats.coast_reached, true)

	var dt := 1.0 / 120.0
	for i in 240:
		var night := i >= 120
		stats.observe_tick(dt, 50.0 + float(i) * 0.1, 100.0 + float(i), night, 1.0 + float(i) * 0.05)
	near(stats.night_time_s, 1.0, 1e-9, "120 ticks at night")
	near(stats.duration_s, 2.0, 1e-9)
	near(stats.distance_m, 239.0, 1e-9, "from the start s")
	near(stats.top_speed_mps, 73.9, 1e-9)
	near(stats.best_multiplier, 12.95, 1e-9)

	var r := stats.results(4321, 77, &"journey")
	for key: StringName in [&"score", &"distance_m", &"legs_completed", &"coast_reached", &"best_chain",
			&"best_multiplier", &"threads", &"close_passes", &"top_speed_kmh", &"night_time_s", &"hits",
			&"seed", &"mode"]:
		check(r.has(key), "results has %s" % key)
	eq(r[&"score"], 4321)
	eq(r[&"seed"], 77)
	eq(r[&"mode"], &"journey")
	near(float(r[&"top_speed_kmh"]), 73.9 * 3.6, 1e-6)
	eq(r[&"threads"], 1)
	eq(r[&"close_passes"], 2)
	eq(r[&"hits"], 1)


func test_reset_clears_everything() -> void:
	var stats := RunStats.new()
	var buf := ScoreEventBuffer.new(4)
	buf.push(ScoreEvents.THREAD, 50)
	stats.consume(buf, 0, 1)
	stats.observe_tick(0.5, 80.0, 40.0, true, 6.0)
	var h0 := stats.hash_into(0)
	stats.reset(10.0)
	eq(stats.threads, 0)
	eq(stats.night_time_s, 0.0)
	eq(stats.best_multiplier, 1.0)
	eq(stats.start_s, 10.0)
	ne(stats.hash_into(0), h0)
	eq(stats.hash_into(0), RunStats.new(10.0).hash_into(0))


func test_distance_never_goes_backwards() -> void:
	var stats := RunStats.new(0.0)
	stats.observe_tick(0.1, 10.0, 50.0, false, 1.0)
	stats.observe_tick(0.1, 10.0, 49.0, false, 1.0)
	eq(stats.distance_m, 50.0)
