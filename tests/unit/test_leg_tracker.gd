extends WBTest
## LegTracker suite. Spec: Core loop -> Legs and checkpoints (legs ~3.5 km, warning
## signs at 1 km and 500 m, the crossing facts: Clean, Pace, Threads, Heat, the
## objective hook, night), The journey goal (coast after 8 legs, then endless).
## Checkpoints come from the road's CHECKPOINT / SIGN features, never from distances.

const ROAD_SEED := 777
## Director-rate planning cadence and look-ahead in these tests.
const PLAN_EVERY_M := 300.0
const PLAN_AHEAD_M := 2000.0

var t: Tuning
var legs: LegsTuning
var dt: float
var buf: ScoreEventBuffer


func before_all() -> void:
	t = Tuning.load_default()
	legs = t.legs
	dt = t.vehicle.physics_dt()


func before_each() -> void:
	buf = ScoreEventBuffer.new(64)


func _tracker() -> LegTracker:
	var lt_ := LegTracker.new(legs)
	lt_.reset(0.0)
	return lt_


func _fixture_road() -> StraightRoadPath:
	var road := StraightRoadPath.new(3, t.road)
	road.add_feature(RoadFeature.make(RoadFeature.Kind.SIGN, 234.0, 234.0, 1000.0, ProceduralRoadPath.SIGN_CHECKPOINT))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.SIGN, 734.0, 734.0, 500.0, ProceduralRoadPath.SIGN_CHECKPOINT))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.SIGN, 900.0, 900.0, 300.0, ProceduralRoadPath.SIGN_BEND))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.BEND, 1000.0, 1100.0, 0.0005))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 1234.0, 1234.0, 1.0, BiomeDef.LANDMARK_TOLL_GANTRY))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 2600.0, 2600.0, 2.0, BiomeDef.LANDMARK_TUNNEL_PORTAL))
	return road


func _count(kind: StringName) -> int:
	var n := 0
	for i in buf.size():
		if buf.kind[i] == kind:
			n += 1
	return n


## Drives from s0 at constant speed v until s1 (or the tracker reports `stop_after`
## crossings), planning every PLAN_EVERY_M. Returns crossings as [leg, s, player_s].
func _drive(tracker: LegTracker, road: RoadPath, s0: float, s1: float, v: float,
		is_night: bool = false) -> Array[PackedFloat64Array]:
	var out: Array[PackedFloat64Array] = []
	var s := s0
	var next_plan := s0
	while s < s1:
		if s >= next_plan:
			tracker.plan_ahead(road, s + PLAN_AHEAD_M)
			next_plan += PLAN_EVERY_M
		s += v * dt
		if tracker.step(dt, s, is_night, buf):
			out.append(PackedFloat64Array([tracker.crossing.leg_index, tracker.crossing.s, s]))
	return out


# ---------------------------------------------------------------- Checkpoints from the road

func test_checkpoints_from_procedural_road_every_leg() -> void:
	var road := ProceduralRoadPath.new(RunContext.new(ROAD_SEED, RunContext.MODE_JOURNEY, t))
	var tracker := _tracker()
	var v := Units.kmh_to_mps(250.0)
	var n := 3
	var crossings := _drive(tracker, road, 0.0, legs.leg_length_m() * n + 1.0, v)
	eq(crossings.size(), n)
	for k in crossings.size():
		var c := crossings[k]
		eq(int(c[0]), k + 1, "leg index from the feature")
		near(c[1], legs.leg_length_m() * (k + 1), 1e-6, "checkpoint at %.1f km" % legs.leg_length_km)
		ge(c[2], c[1], "crossed at or after the line")
		lt(c[2] - c[1], v * dt + 1e-9, "on the tick it was crossed")
	eq(_count(LegTracker.KIND_CHECKPOINT_CROSSED), n)
	eq(_count(LegTracker.KIND_LEG_STARTED), n)
	eq(tracker.leg_index, n + 1)
	eq(tracker.legs_completed, n)


func test_checkpoints_follow_features_not_distances() -> void:
	var road := _fixture_road()
	var tracker := _tracker()
	var crossings := _drive(tracker, road, 0.0, 3000.0, 60.0)
	eq(crossings.size(), 2)
	if crossings.size() == 2:
		near(crossings[0][1], 1234.0, 1e-9)
		near(crossings[1][1], 2600.0, 1e-9)
	eq(tracker.leg_index, 3)


func test_landmark_tag_and_leg_distance() -> void:
	var road := _fixture_road()
	var tracker := _tracker()
	var s := 0.0
	tracker.plan_ahead(road, 3000.0)
	while not tracker.step(dt, s, false, buf):
		s += 50.0 * dt
	eq(tracker.crossing.landmark, BiomeDef.LANDMARK_TOLL_GANTRY)
	near(tracker.crossing.distance_m, 1234.0, 1e-9)


# ---------------------------------------------------------------- Warnings

func test_warnings_at_1km_and_500m_once_each() -> void:
	var road := ProceduralRoadPath.new(RunContext.new(ROAD_SEED, RunContext.MODE_JOURNEY, t))
	var tracker := _tracker()
	var s := 0.0
	var v := 70.0
	var warn_s: Array[float] = []
	var warn_d: Array[float] = []
	var cp_s := legs.leg_length_m()
	while s < cp_s * 2.0 + 10.0:
		tracker.plan_ahead(road, s + PLAN_AHEAD_M)   # every tick: planning twice never duplicates
		s += v * dt
		var n0 := buf.size()
		tracker.step(dt, s, false, buf)
		for i in range(n0, buf.size()):
			if buf.kind[i] == LegTracker.KIND_CHECKPOINT_WARNING:
				warn_s.append(s)
				warn_d.append(buf.value[i])
		if buf.size() > buf.capacity - 8:
			buf.clear()
	eq(warn_d.size(), 4, "two signs per checkpoint")
	eq(buf.dropped, 0)
	var dists := legs.checkpoint_warning_distances_m
	for k in 2:
		for j in dists.size():
			var i := k * dists.size() + j
			if i >= warn_d.size():
				break
			near(warn_d[i], dists[j], 1e-9, "announced distance")
			var expected_s := cp_s * (k + 1) - dists[j]
			ge(warn_s[i], expected_s)
			lt(warn_s[i] - expected_s, v * dt + 1e-9, "at the sign")


func test_other_signs_are_not_checkpoint_warnings() -> void:
	var road := _fixture_road()
	var tracker := _tracker()
	_drive(tracker, road, 0.0, 1300.0, 60.0)
	eq(_count(LegTracker.KIND_CHECKPOINT_WARNING), 2)


# ---------------------------------------------------------------- Leg facts

func _cross_one_leg(tracker: LegTracker, v: float, setup: Callable, is_night: bool = false) -> LegTracker.Crossing:
	var road := _fixture_road()
	tracker.plan_ahead(road, 3000.0)
	var s := 0.0
	var tick := 0
	while true:
		setup.call(tracker, tick)
		s += v * dt
		tick += 1
		if tracker.step(dt, s, is_night, buf):
			return tracker.crossing
		if tick > 1000000:
			break
	fail("never crossed")
	return tracker.crossing


func _noop(_tr: LegTracker, _tick: int) -> void:
	pass


func test_clean_leg_fact() -> void:
	var c := _cross_one_leg(_tracker(), 60.0, _noop)
	check(c.clean, "no hits: clean")
	var tracker := _tracker()
	c = _cross_one_leg(tracker, 60.0, func(x: LegTracker, tick: int) -> void:
		if tick == 100:
			x.notify_hit())
	check(not c.clean, "a hit spoils the leg")
	# The next leg starts clean again.
	var s := tracker.crossing.s
	while not tracker.step(dt, s, false, buf):
		s += 60.0 * dt
	check(tracker.crossing.clean, "next leg clean")
	eq(tracker.crossing.leg_index, 2)


func test_pace_fact() -> void:
	var target := legs.pace_target_mps()
	var c := _cross_one_leg(_tracker(), target * 1.01, _noop)
	check(c.pace, "above target: pace")
	near(c.avg_speed_mps, target * 1.01, target * 0.01)
	c = _cross_one_leg(_tracker(), target * 0.97, _noop)
	check(not c.pace, "below target: no pace")
	near(c.avg_speed_mps, target * 0.97, target * 0.01)


func test_threads_fact() -> void:
	var n := legs.bonus_threads_min_count
	var c := _cross_one_leg(_tracker(), 60.0, func(x: LegTracker, tick: int) -> void:
		if tick > 0 and tick <= n - 1:
			x.notify_thread())
	eq(c.threads, n - 1)
	check(not c.threads_bonus, "fewer than 3 threads")
	c = _cross_one_leg(_tracker(), 60.0, func(x: LegTracker, tick: int) -> void:
		if tick > 0 and tick <= n:
			x.notify_thread())
	eq(c.threads, n)
	check(c.threads_bonus, "3 threads")


func test_heat_fact() -> void:
	var hold_ticks := int(round(legs.bonus_heat_hold_s / dt))
	var hot := legs.bonus_heat_multiplier
	# Held exactly 15 s at 10x.
	var c := _cross_one_leg(_tracker(), 60.0, func(x: LegTracker, tick: int) -> void:
		x.observe_multiplier(dt, hot if tick < hold_ticks else 1.0))
	check(c.heat, "10x held for 15 s")
	# One tick short.
	c = _cross_one_leg(_tracker(), 60.0, func(x: LegTracker, tick: int) -> void:
		x.observe_multiplier(dt, hot if tick < hold_ticks - 1 else 1.0))
	check(not c.heat, "held just under 15 s")
	# 2 x 10 s, broken in between: not held.
	c = _cross_one_leg(_tracker(), 60.0, func(x: LegTracker, tick: int) -> void:
		var part := int(float(hold_ticks) * 0.66)
		var in_first := tick < part
		var in_second := tick > hold_ticks and tick < hold_ticks + part
		x.observe_multiplier(dt, hot * 3.0 if in_first or in_second else hot * 0.99))
	check(not c.heat, "interrupted hold")


func test_objective_hook_and_night_flag() -> void:
	var tracker := _tracker()
	tracker.set_objective(&"close_passes_5")
	var setup := func(x: LegTracker, tick: int) -> void:
		if tick == 10:
			for i in 5:
				x.notify_close_pass()
			x.complete_objective()
	var c := _cross_one_leg(tracker, 60.0, setup, true)
	eq(c.objective, &"close_passes_5")
	check(c.objective_done)
	eq(c.close_passes, 5)
	check(c.at_night, "leg finished at night")
	# Objectives reset per leg.
	eq(tracker.objective, &"")
	tracker.complete_objective()
	check(not tracker.is_objective_done(), "no objective: nothing to complete")


func test_bonus_list_and_points() -> void:
	var target := legs.pace_target_mps()
	var tracker := _tracker()
	var hold_ticks := int(round(legs.bonus_heat_hold_s / dt))
	var c := _cross_one_leg(tracker, target * 1.1, func(x: LegTracker, tick: int) -> void:
		x.observe_multiplier(dt, legs.bonus_heat_multiplier if tick < hold_ticks else 1.0)
		if tick < legs.bonus_threads_min_count:
			x.notify_thread())
	check(c.clean and c.pace and c.threads_bonus and c.heat)
	eq(c.bonus_count(), 4)
	eq(c.bonus_kind(0), LegTracker.BONUS_CLEAN)
	eq(c.bonus_kind(3), LegTracker.BONUS_HEAT)
	eq(c.bonus_base_points(0, legs), legs.bonus_clean_points)
	eq(c.bonus_base_points(1, legs), legs.bonus_pace_points)
	eq(c.bonus_base_points(2, legs), legs.bonus_threads_points)
	eq(c.bonus_base_points(3, legs), legs.bonus_heat_points)


# ---------------------------------------------------------------- Journey

func test_coast_after_eight_legs_then_endless() -> void:
	var road := ProceduralRoadPath.new(RunContext.new(ROAD_SEED, RunContext.MODE_JOURNEY, t))
	var tracker := _tracker()
	var v := Units.kmh_to_mps(300.0)
	var n := legs.legs_to_coast + 3
	var s := 0.0
	var next_plan := 0.0
	var crossed := 0
	var coast_leg := -1
	while crossed < n:
		if s >= next_plan:
			tracker.plan_ahead(road, s + PLAN_AHEAD_M)
			next_plan += PLAN_EVERY_M
		s += v * dt
		if tracker.step(dt, s, false, buf):
			crossed += 1
			if tracker.crossing.coast:
				ne(coast_leg, tracker.crossing.leg_index, "coast once")
				coast_leg = tracker.crossing.leg_index
			check(tracker.crossing.leg_index == crossed)
			if _count(LegTracker.KIND_COAST_REACHED) > 1:
				fail("coast_reached more than once")
		if buf.size() > buf.capacity - 8:
			buf.clear()
		if s > legs.leg_length_m() * (n + 2):
			fail("ran out of road")
			break
	eq(coast_leg, legs.legs_to_coast, "coast after 8 legs")
	check(tracker.coast_reached)
	eq(tracker.legs_completed, n, "the road continues: legs 9, 10, 11")
	eq(buf.dropped, 0)


func test_reset_clears_everything() -> void:
	var road := _fixture_road()
	var tracker := _tracker()
	_drive(tracker, road, 0.0, 3000.0, 60.0)
	tracker.reset(0.0)
	eq(tracker.leg_index, 1)
	eq(tracker.legs_completed, 0)
	check(not tracker.coast_reached)
	buf.clear()
	var crossings := _drive(tracker, road, 0.0, 1300.0, 60.0)
	eq(crossings.size(), 1)
	eq(_count(LegTracker.KIND_CHECKPOINT_WARNING), 2)


func test_determinism() -> void:
	eq(_trace(), _trace())


func _trace() -> int:
	var road := ProceduralRoadPath.new(RunContext.new(ROAD_SEED, RunContext.MODE_JOURNEY, t))
	var tracker := _tracker()
	var rng := Rng.new(ROAD_SEED).derive(&"legs_test")
	var h := TraceHash.SEED
	var s := 0.0
	var next_plan := 0.0
	var b := ScoreEventBuffer.new(64)
	for i in 60000:
		if s >= next_plan:
			tracker.plan_ahead(road, s + PLAN_AHEAD_M)
			next_plan += PLAN_EVERY_M
		if rng.chance(0.001):
			tracker.notify_thread()
		if rng.chance(0.0002):
			tracker.notify_hit()
		tracker.observe_multiplier(dt, rng.float_range(8.0, 12.0))
		s += rng.float_range(40.0, 90.0) * dt
		tracker.step(dt, s, rng.chance(0.5), b)
		if i % 120 == 0:
			h = tracker.hash_into(h)
			h = b.hash_into(h)
			b.clear()
	return h


func test_step_budget() -> void:
	var road := _fixture_road()
	var tracker := _tracker()
	tracker.plan_ahead(road, 1000.0)
	var usec := WBBench.usec_per_call(tracker.step.bind(dt, 10.0, false, buf), 2000)
	WBBench.report("leg tracker step", usec, 5.0)
	le(usec, WBBench.budget(5.0))
