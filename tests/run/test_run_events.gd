extends WBTest
## RunEvents (src/run/run_events.gd): every CONTRACTS §7 kind becomes its Events
## signal with the right arguments; multiplier / chain / boost only on change.

var _log: Array = []
var _conns: Array = []
var _adapter: RunEvents


class FakeRules:
	extends ScoringRuleSet
	var m: float = 1.0
	var c: int = 0

	func multiplier() -> float:
		return m

	func chain() -> int:
		return c


func before_each() -> void:
	_log.clear()
	_adapter = RunEvents.new()
	tree.root.add_child(_adapter)
	_listen(Events.scored, func(k: StringName, p: int, m: float, c: float) -> void: _log.append(["scored", k, p, m, c]))
	_listen(Events.chain_banked, func(a: int, r: StringName, t: int) -> void: _log.append(["chain_banked", a, r, t]))
	_listen(Events.chain_lost, func(a: int, r: StringName) -> void: _log.append(["chain_lost", a, r]))
	_listen(Events.hesitated, func() -> void: _log.append(["hesitated"]))
	_listen(Events.too_slow_changed, func(on: bool) -> void: _log.append(["too_slow_changed", on]))
	_listen(Events.shoulder_penalty_changed, func(on: bool) -> void: _log.append(["shoulder_penalty_changed", on]))
	_listen(Events.slipstream_changed, func(on: bool) -> void: _log.append(["slipstream_changed", on]))
	_listen(Events.bonus_awarded, func(k: StringName, p: int, t: int) -> void: _log.append(["bonus_awarded", k, p, t]))
	_listen(Events.night_started, func() -> void: _log.append(["night_started"]))
	_listen(Events.dawn_started, func(d: float) -> void: _log.append(["dawn_started", d]))
	_listen(Events.morning_reached, func() -> void: _log.append(["morning_reached"]))
	_listen(Events.sun_lifted, func(f: float) -> void: _log.append(["sun_lifted", f]))
	_listen(Events.hit, func(src: StringName, left: int) -> void: _log.append(["hit", src, left]))
	_listen(Events.ghost_started, func(d: float) -> void: _log.append(["ghost_started", d]))
	_listen(Events.ghost_ended, func() -> void: _log.append(["ghost_ended"]))
	_listen(Events.life_restored, func(n: int) -> void: _log.append(["life_restored", n]))
	_listen(Events.checkpoint_warning, func(d: float) -> void: _log.append(["checkpoint_warning", d]))
	_listen(Events.checkpoint_crossed, func(leg: int, summary: Dictionary) -> void: _log.append(["checkpoint_crossed", leg, summary]))
	_listen(Events.leg_started, func(leg: int, b: StringName, o: StringName) -> void: _log.append(["leg_started", leg, b, o]))
	_listen(Events.coast_reached, func() -> void: _log.append(["coast_reached"]))
	_listen(Events.traffic_horn, func(slot: int, pos: Vector3) -> void: _log.append(["traffic_horn", slot, pos]))
	_listen(Events.traffic_brake_tap, func(slot: int) -> void: _log.append(["traffic_brake_tap", slot]))
	_listen(Events.traffic_hazards, func(slot: int, on: bool) -> void: _log.append(["traffic_hazards", slot, on]))
	_listen(Events.multiplier_changed, func(v: float) -> void: _log.append(["multiplier_changed", v]))
	_listen(Events.chain_changed, func(v: int) -> void: _log.append(["chain_changed", v]))
	_listen(Events.boost_started, func() -> void: _log.append(["boost_started"]))
	_listen(Events.boost_ended, func() -> void: _log.append(["boost_ended"]))
	_listen(Events.boost_meter_changed, func(f: float) -> void: _log.append(["boost_meter_changed", f]))


func after_each() -> void:
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	_adapter.queue_free()
	await tree.process_frame


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _buffer() -> ScoreEventBuffer:
	var buf := ScoreEventBuffer.new(64)
	_adapter.add_buffer(buf)
	return buf


func test_scoring_kinds_map_to_their_signals() -> void:
	var buf := _buffer()
	buf.push(ScoreEvents.PASS, 15, 1.0, 2.5, 3)
	buf.push(ScoreEvents.CLOSE_PASS, 90, 2.0, 0.8, 4)
	buf.push(ScoreEvents.CUT, 30, 5.0, -1.0, 5)
	buf.push(ScoreEvents.THREAD, 200, 3.0, 1.4, 6)
	buf.push(ScoringRuleSet.KIND_BANKED, 335, 1.0, -1.0, -1, 1335.0, ScoreEvents.REASON_CASH_OUT)
	buf.push(ScoringRuleSet.KIND_CHAIN_LOST, 120, 4.0, -1.0, -1, 0.0, ScoreEvents.REASON_HIT)
	buf.push(ScoringRuleSet.KIND_HESITATED)
	buf.push(ScoringRuleSet.KIND_TOO_SLOW, 0, 0.0, -1.0, -1, 1.0)
	buf.push(ScoringRuleSet.KIND_SHOULDER, 0, 0.0, -1.0, -1, 0.0)
	buf.push(ScoringRuleSet.KIND_SLIPSTREAM, 0, 0.0, -1.0, -1, 1.0)
	buf.push(ScoringRuleSet.KIND_BONUS, 5000, 0.0, -1.0, -1, 6335.0, LegTracker.BONUS_CLEAN)
	buf.push(ScoringRuleSet.KIND_SUN_NUDGE, 0, 0.0, -1.0, -1, 0.01)
	buf.push(Scoring.KIND_NEAR_MISS, 0, 0.0, 0.7, 4)
	_adapter.drain()
	eq(_log, [
		["scored", Events.PASS, 15, 1.0, 2.5],
		["scored", Events.CLOSE_PASS, 90, 2.0, 0.8],
		["scored", Events.CUT, 30, 5.0, -1.0],
		["scored", Events.THREAD, 200, 3.0, 1.4],
		["chain_banked", 335, Events.REASON_CASH_OUT, 1335],
		["chain_lost", 120, Events.REASON_HIT],
		["hesitated"],
		["too_slow_changed", true],
		["shoulder_penalty_changed", false],
		["slipstream_changed", true],
		["bonus_awarded", &"clean", 5000, 6335],
	], "scoring records in order; sun nudge and near miss are tick-time kinds, not signals")
	eq(_adapter.emitted_last, 11)
	eq(buf.size(), 0, "drained buffer is cleared")


func test_sun_and_lives_kinds() -> void:
	var buf := _buffer()
	buf.push(SunClock.KIND_NIGHT_STARTED)
	buf.push(SunClock.KIND_DAWN_STARTED, 0, 0.0, -1.0, -1, 6.0)
	buf.push(SunClock.KIND_MORNING_REACHED)
	buf.push(SunClock.KIND_SUN_LIFTED, 0, 0.0, -1.0, -1, 0.4)
	buf.push(Lives.KIND_HIT, 0, 0.0, -1.0, 7, 1.0, HitDetection.HIT_TRAFFIC)
	buf.push(Lives.KIND_GHOST_STARTED, 0, 0.0, -1.0, -1, 2.0)
	buf.push(Lives.KIND_GHOST_ENDED)
	buf.push(Lives.KIND_LIFE_RESTORED, 0, 0.0, -1.0, -1, 2.0)
	buf.push(Lives.KIND_HIT, 0, 0.0, -1.0, -1, 0.0, HitDetection.HIT_BARRIER)
	_adapter.drain()
	eq(_log, [
		["night_started"],
		["dawn_started", 6.0],
		["morning_reached"],
		["sun_lifted", 0.4],
		["hit", Events.HIT_TRAFFIC, 1],
		["ghost_started", 2.0],
		["ghost_ended"],
		["life_restored", 2],
		["hit", Events.HIT_BARRIER, 0],
	])


func test_leg_kinds_and_crossing_summary() -> void:
	var t := Tuning.load_default()
	var legs := LegTracker.new(t.legs)
	var c := legs.crossing
	c.leg_index = 3
	c.clean = true
	c.pace = false
	c.threads = 4
	c.threads_bonus = true
	c.heat = true
	c.heat_best_s = 16.5
	c.objective = &"close_passes"
	c.objective_done = true
	c.at_night = true
	c.avg_speed_mps = 50.0
	c.s = 10500.0
	legs.objective = &"thread_twice"
	_adapter.legs = legs
	var buf := _buffer()
	buf.push(LegTracker.KIND_CHECKPOINT_WARNING, 0, 0.0, -1.0, -1, 1000.0)
	buf.push(LegTracker.KIND_CHECKPOINT_CROSSED, 0, 0.0, -1.0, -1, 3.0)
	buf.push(LegTracker.KIND_COAST_REACHED)
	buf.push(LegTracker.KIND_LEG_STARTED, 0, 0.0, -1.0, -1, 4.0)
	buf.push(ScoringRuleSet.KIND_BANKED, 800, 3.0, -1.0, -1, 900.0, ScoreEvents.REASON_CHECKPOINT)
	buf.push(ScoringRuleSet.KIND_SUN_NUDGE)   # not a bonus: ignored in the sum
	buf.push(ScoringRuleSet.KIND_BONUS, 10000, 0.0, -1.0, -1, 10900.0, LegTracker.BONUS_CLEAN)
	buf.push(ScoringRuleSet.KIND_BONUS, 6000, 0.0, -1.0, -1, 16900.0, LegTracker.BONUS_THREADS)
	_adapter.drain()
	eq(_log[0], ["checkpoint_warning", 1000.0])
	eq(_log[1][0], "checkpoint_crossed")
	eq(_log[1][1], 3)
	var summary: Dictionary = _log[1][2]
	for key: StringName in [&"leg_index", &"clean", &"pace", &"threads", &"heat", &"objective_done",
			&"bonus_points", &"at_night"]:
		check(summary.has(key), "summary has %s (events.gd)" % key)
	eq(summary[&"leg_index"], 3)
	eq(summary[&"clean"], true)
	eq(summary[&"pace"], false)
	eq(summary[&"threads"], 4)
	eq(summary[&"heat"], true)
	eq(summary[&"objective_done"], true)
	eq(summary[&"at_night"], true)
	eq(summary[&"bonus_points"], 16000, "the bonus records after the crossing")
	eq(_log[2], ["coast_reached"])
	eq(_log[3], ["leg_started", 4, &"", &"thread_twice"], "no biome director: empty biome; objective from the tracker")


func test_leg_started_names_the_biome() -> void:
	var bd := BiomeDirector.new()
	tree.root.add_child(bd)
	bd.setup(null, null, null)
	_adapter.biome_director = bd
	var buf := _buffer()
	buf.push(LegTracker.KIND_LEG_STARTED, 0, 0.0, -1.0, -1, 2.0)
	_adapter.drain()
	eq(_log, [["leg_started", 2, bd.current().id, &""]])
	bd.queue_free()


func test_traffic_kinds() -> void:
	var buf := _buffer()
	buf.push(TrafficSim.KIND_HORN, 0, 0.0, -1.0, 12, 0.0, TrafficSim.TAG_CLOSE_PASS)
	buf.push(TrafficSim.KIND_BRAKE_TAP, 0, 0.0, -1.0, 5)
	buf.push(TrafficSim.KIND_HAZARDS, 0, 0.0, -1.0, 9, 1.0)
	buf.push(TrafficSim.KIND_HAZARDS, 0, 0.0, -1.0, 9, 0.0)
	_adapter.drain()
	eq(_log, [
		["traffic_horn", 12, Vector3.ZERO],
		["traffic_brake_tap", 5],
		["traffic_hazards", 9, true],
		["traffic_hazards", 9, false],
	])


func test_horn_position_is_the_car_in_render_space() -> void:
	var t := Tuning.load_default()
	var road := StraightRoadPath.new(3, t.road)
	var origin := FloatingOrigin.new()
	tree.root.add_child(origin)
	origin.setup(t.road.floating_origin_shift_km)
	var ts := TrafficState.new(4)
	var slot := ts.allocate()
	ts.s[slot] = 120.0
	ts.d[slot] = 7.1
	_adapter.road = road
	_adapter.origin = origin
	_adapter.traffic = ts
	var buf := _buffer()
	buf.push(TrafficSim.KIND_HORN, 0, 0.0, -1.0, slot)
	_adapter.drain()
	var expected := road.sample(120.0).local_point(7.1, 0.0, 0.0, 0.0)
	check((_log[0][2] as Vector3).is_equal_approx(expected), "horn at the car: %s vs %s" % [_log[0][2], expected])
	origin.queue_free()


func test_multiplier_and_chain_only_on_change() -> void:
	var rules := FakeRules.new()
	_adapter.scoring = rules
	_adapter.drain()
	eq(_log, [["multiplier_changed", 1.0], ["chain_changed", 0]], "first drain announces the state")
	_log.clear()
	_adapter.drain()
	_adapter.drain()
	eq(_log, [], "nothing changed, nothing emitted")
	rules.m = 2.5
	_adapter.drain()
	eq(_log, [["multiplier_changed", 2.5]])
	_log.clear()
	rules.c = 45
	_adapter.drain()
	eq(_log, [["chain_changed", 45]])
	_log.clear()
	_adapter.reset()
	_adapter.drain()
	eq(_log, [["multiplier_changed", 2.5], ["chain_changed", 45]], "reset re-announces")


func test_boost_edges_and_meter_on_change() -> void:
	var st := VehicleState.new()
	_adapter.player = st
	_adapter.drain()
	eq(_log, [["boost_meter_changed", 0.0]])
	_log.clear()
	st.boost_meter = 0.3
	_adapter.drain()
	eq(_log, [["boost_meter_changed", 0.3]])
	_log.clear()
	st.boost_active = true
	_adapter.drain()
	eq(_log, [["boost_started"]])
	_log.clear()
	_adapter.drain()
	eq(_log, [])
	st.boost_active = false
	st.boost_meter = 0.0
	_adapter.drain()
	eq(_log, [["boost_ended"], ["boost_meter_changed", 0.0]])


func test_buffers_drain_in_registration_order() -> void:
	var a := _buffer()
	var b := _buffer()
	b.push(SunClock.KIND_NIGHT_STARTED)
	a.push(ScoringRuleSet.KIND_HESITATED)
	_adapter.drain()
	eq(_log, [["hesitated"], ["night_started"]])
	eq(a.size() + b.size(), 0)


func test_every_contract_kind_is_handled() -> void:
	# CONTRACTS §7: each kind the sims write, except the two tick-time ones.
	var kinds: Array[StringName] = [
		ScoreEvents.PASS, ScoreEvents.CLOSE_PASS, ScoreEvents.CUT, ScoreEvents.THREAD,
		ScoringRuleSet.KIND_BANKED, ScoringRuleSet.KIND_CHAIN_LOST, ScoringRuleSet.KIND_HESITATED,
		ScoringRuleSet.KIND_TOO_SLOW, ScoringRuleSet.KIND_SHOULDER, ScoringRuleSet.KIND_SLIPSTREAM,
		ScoringRuleSet.KIND_BONUS, SunClock.KIND_NIGHT_STARTED, SunClock.KIND_DAWN_STARTED,
		SunClock.KIND_MORNING_REACHED, SunClock.KIND_SUN_LIFTED, Lives.KIND_HIT,
		Lives.KIND_GHOST_STARTED, Lives.KIND_GHOST_ENDED, Lives.KIND_LIFE_RESTORED,
		LegTracker.KIND_CHECKPOINT_WARNING, LegTracker.KIND_CHECKPOINT_CROSSED,
		LegTracker.KIND_LEG_STARTED, LegTracker.KIND_COAST_REACHED,
		TrafficSim.KIND_HORN, TrafficSim.KIND_BRAKE_TAP, TrafficSim.KIND_HAZARDS,
	]
	var buf := _buffer()
	for k in kinds:
		buf.push(k)
	_adapter.drain()
	eq(_adapter.emitted_last, kinds.size(), "one signal per record")
	eq(_log.size(), kinds.size())
