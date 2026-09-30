extends WBTest
## LegObjectives and the LegTracker objective hooks. Spec: Core loop -> Legs and
## checkpoints ("Each leg shows one optional objective on entry, such as '5 close
## passes', 'thread twice' or 'no braking'. Completing it pays a bonus."); Architecture
## rules 2 and 6 (deterministic by seed, allocation-free ticks). docs/CORE_LOOP.md.

const SEED := 424242
const LEGS := 200

var t: Tuning
var legs: LegsTuning
var dt: float


func before_all() -> void:
	t = Tuning.load_default()
	legs = t.legs
	dt = t.vehicle.physics_dt()


func _objectives(run_seed: int = SEED, tun: LegsTuning = null) -> LegObjectives:
	var o := LegObjectives.new(tun if tun != null else legs)
	o.reset(RunContext.new(run_seed, RunContext.MODE_JOURNEY, t))
	return o


func _sequence(run_seed: int, n: int) -> Array[StringName]:
	var o := _objectives(run_seed)
	var out: Array[StringName] = []
	for leg in range(1, n + 1):
		out.append(o.start_leg(leg))
	return out


## `seconds` of ticks with fixed inputs; returns how many ticks reported a completion.
func _tick(o: LegObjectives, seconds: float, brake: float = 0.0, v: float = 50.0,
		slip: bool = false, shoulder: bool = false) -> int:
	var n := 0
	for i in roundi(seconds / dt):
		if o.step(dt, brake, v, slip, shoulder):
			n += 1
	return n


# ---------------------------------------------------------------- Catalog and tuning

func test_catalog_covers_the_spec_examples_and_the_pool() -> void:
	var cat := LegObjectives.catalog()
	for id: StringName in [LegObjectives.CLOSE_PASSES, LegObjectives.THREADS, LegObjectives.NO_BRAKING]:
		check(cat.has(id), "spec example %s in the catalog" % id)
	ge(cat.size(), 6, "the spec's three plus more in their spirit")
	for id in cat:
		ne(LegObjectives.rule_of(id), LegObjectives.Rule.NONE, "%s has a rule" % id)
		check(not LegObjectives.label(id, legs).is_empty(), "%s has HUD text" % id)
	eq(LegObjectives.rule_of(&"nope"), LegObjectives.Rule.NONE)
	var o := LegObjectives.new(legs)
	eq(o.pool(), legs.objective_pool, "the default pool is the whole tuned list")
	for id in legs.objective_pool:
		check(cat.has(id), "pool id %s is known" % id)


func test_labels_read_like_the_spec() -> void:
	eq(LegObjectives.label(LegObjectives.CLOSE_PASSES, legs), "5 CLOSE PASSES")
	eq(LegObjectives.label(LegObjectives.THREADS, legs), "THREAD TWICE")
	eq(LegObjectives.label(LegObjectives.NO_BRAKING, legs), "NO BRAKING")
	eq(LegObjectives.label(LegObjectives.TOP_SPEED, legs), "HIT 250 KM/H")
	eq(LegObjectives.label(LegObjectives.TOP_SPEED, legs, true), "HIT 155 MPH")
	eq(LegObjectives.label(LegObjectives.SLIPSTREAM, legs), "5 S OF SLIPSTREAM")
	eq(LegObjectives.label(LegObjectives.CUTS, legs), "%d CUTS" % legs.objective_cuts_count)
	var three := legs.duplicate() as LegsTuning
	three.objective_threads_count = 3
	eq(LegObjectives.label(LegObjectives.THREADS, three), "3 THREADS", "the count comes from tuning")


func test_unknown_pool_ids_are_skipped() -> void:
	var tun := legs.duplicate() as LegsTuning
	tun.objective_pool = [&"bogus", LegObjectives.CUTS, LegObjectives.CUTS] as Array[StringName]
	var o := _objectives(SEED, tun)
	eq(o.pool(), [LegObjectives.CUTS] as Array[StringName])
	eq(o.start_leg(1), LegObjectives.CUTS)
	eq(o.start_leg(2), LegObjectives.CUTS, "a pool of one repeats (nothing else to draw)")
	tun.objective_pool = [] as Array[StringName]
	o = _objectives(SEED, tun)
	eq(o.start_leg(1), &"", "empty pool: no objective")
	check(not o.step(dt, 1.0, 100.0, true, true))
	check(not o.finish_leg())


# ---------------------------------------------------------------- Choice

func test_choice_is_deterministic_by_seed() -> void:
	var a := _sequence(SEED, LEGS)
	var b := _sequence(SEED, LEGS)
	eq(a, b, "same seed, same objectives")
	var h := 0
	for id in a:
		h = TraceHash.mix_int(h, LegObjectives.catalog().find(id))
	var h2 := 0
	for id in b:
		h2 = TraceHash.mix_int(h2, LegObjectives.catalog().find(id))
	eq(h, h2, "hash of the choice trace")
	ne(_sequence(SEED + 1, LEGS), a, "another seed, another sequence")
	# Independent of anything else drawn from the events stream.
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, t)
	for i in 50:
		ctx.rng_events.unit()
	var o := LegObjectives.new(legs)
	o.reset(ctx)
	eq(o.start_leg(1), a[0], "derived stream: other events draws don't shift it")


func test_never_twice_in_a_row_and_every_pool_id_appears() -> void:
	var seq := _sequence(SEED, LEGS)
	var seen: Dictionary[StringName, int] = {}
	for i in seq.size():
		check(seq[i] != &"", "leg %d has an objective (first_leg = 1)" % (i + 1))
		if i > 0:
			ne(seq[i], seq[i - 1], "leg %d repeats leg %d" % [i + 1, i])
		seen[seq[i]] = seen.get(seq[i], 0) + 1
	for id in legs.objective_pool:
		gt(seen.get(id, 0), float(LEGS) / float(legs.objective_pool.size() * 3), "%s drawn fairly often" % id)


func test_first_leg_setting() -> void:
	var tun := legs.duplicate() as LegsTuning
	tun.objective_first_leg = 2
	var o := _objectives(SEED, tun)
	eq(o.start_leg(1), &"", "no objective before objective_first_leg")
	eq(o.start_leg(2), _sequence(SEED, 1)[0], "the first draw happens on the first leg that has one")


func test_retry_restarts_the_sequence() -> void:
	var o := _objectives()
	var first := o.start_leg(1)
	o.start_leg(2)
	o.reset(RunContext.new(SEED, RunContext.MODE_JOURNEY, t))
	eq(o.current(), &"", "reset clears the objective")
	eq(o.start_leg(1), first)


func test_force_keeps_the_seeded_sequence() -> void:
	var seq := _sequence(SEED, 4)
	var o := _objectives()
	eq(o.start_leg(1), seq[0])
	o.force(LegObjectives.TOP_SPEED)
	eq(o.current(), LegObjectives.TOP_SPEED)
	eq(o.start_leg(2), seq[1], "forcing doesn't touch the draw")
	o.force(&"bogus")
	eq(o.current(), &"", "unknown id: none")


# ---------------------------------------------------------------- Rules

func test_counting_objectives_complete_immediately_once() -> void:
	var cases := [
		[LegObjectives.CLOSE_PASSES, ScoreEvents.CLOSE_PASS, legs.objective_close_passes_count],
		[LegObjectives.THREADS, ScoreEvents.THREAD, legs.objective_threads_count],
		[LegObjectives.CUTS, ScoreEvents.CUT, legs.objective_cuts_count],
	]
	for c: Array in cases:
		var id: StringName = c[0]
		var kind: StringName = c[1]
		var n: int = c[2]
		var o := _objectives()
		o.force(id)
		eq(o.target(), n, "%s target" % id)
		check(not o.notify_scored(ScoreEvents.PASS), "plain passes don't count")
		var completions := 0
		for i in n - 1:
			if o.notify_scored(kind):
				completions += 1
		eq(completions, 0, "%s not yet" % id)
		eq(o.progress(), n - 1)
		check(o.notify_scored(kind), "%s completes on the %d-th" % [id, n])
		check(o.is_done())
		check(not o.notify_scored(kind), "and only once")
		eq(o.progress(), n)
		eq(_tick(o, 1.0), 0, "ticks never complete it again")
		check(not o.finish_leg(), "nothing more at the checkpoint")


func test_other_kinds_do_not_count() -> void:
	var o := _objectives()
	o.force(LegObjectives.THREADS)
	for i in 10:
		o.notify_scored(ScoreEvents.CLOSE_PASS)
		o.notify_scored(ScoreEvents.CUT)
	eq(o.progress(), 0)


func test_top_speed_completes_on_reaching_it() -> void:
	var o := _objectives()
	o.force(LegObjectives.TOP_SPEED)
	eq(o.target(), 0, "no count to show")
	var v := legs.objective_top_speed_mps()
	eq(_tick(o, 2.0, 0.0, v - 0.01), 0, "just under")
	check(o.step(dt, 0.0, v, false, false), "reached")
	check(o.is_done())
	eq(_tick(o, 1.0, 0.0, v + 5.0), 0, "once")


func test_slipstream_adds_up_to_its_time() -> void:
	var o := _objectives()
	o.force(LegObjectives.SLIPSTREAM)
	eq(o.target(), roundi(legs.objective_slipstream_s))
	var half := legs.objective_slipstream_s * 0.5
	eq(_tick(o, half, 0.0, 50.0, true), 0)
	eq(_tick(o, 10.0, 0.0, 50.0, false), 0, "out of the slipstream: no progress")
	eq(o.progress(), floori(half))
	var ticks_left := roundi(half / dt)
	for i in ticks_left - 1:
		check(not o.step(dt, 0.0, 50.0, true, false), "tick %d" % i)
	check(o.step(dt, 0.0, 50.0, true, false), "completes on the tick the total reaches the target")
	eq(o.progress(), o.target())


func test_no_braking_fails_after_the_grace_and_completes_at_the_line() -> void:
	var grace := legs.objective_avoid_grace_s
	var o := _objectives()
	o.force(LegObjectives.NO_BRAKING)
	eq(_tick(o, grace * 0.5, 1.0), 0, "braking in the grace period is free")
	eq(_tick(o, grace, legs.objective_brake_threshold), 0, "a feathered touch at the threshold is not braking")
	check(not o.is_failed())
	check(not o.is_done(), "never completes mid-leg")
	check(o.finish_leg(), "completes at the checkpoint")
	check(o.is_done())
	check(not o.finish_leg(), "once")
	# Braking after the grace fails it.
	o.force(LegObjectives.NO_BRAKING)
	_tick(o, grace + dt * 2.0)
	o.step(dt, legs.objective_brake_threshold + 0.01, 50.0, false, false)
	check(o.is_failed(), "brake above the threshold after the grace")
	check(not o.finish_leg(), "failed: nothing at the checkpoint")
	check(not o.is_done())


func test_no_shoulder_fails_on_the_shoulder() -> void:
	var o := _objectives()
	o.force(LegObjectives.NO_SHOULDER)
	_tick(o, legs.objective_avoid_grace_s * 0.5, 1.0, 50.0, false, true)
	check(not o.is_failed(), "grace")
	_tick(o, legs.objective_avoid_grace_s, 1.0, 50.0, false, false)
	check(not o.is_failed(), "braking doesn't matter to no_shoulder")
	o.step(dt, 0.0, 50.0, false, true)
	check(o.is_failed())
	check(not o.finish_leg())


func test_start_leg_resets_progress() -> void:
	var o := _objectives()
	o.force(LegObjectives.CLOSE_PASSES)
	o.notify_scored(ScoreEvents.CLOSE_PASS)
	o.force(LegObjectives.NO_BRAKING)
	_tick(o, legs.objective_avoid_grace_s * 2.0, 1.0)
	check(o.is_failed())
	var id := o.start_leg(2)
	check(not o.is_failed() and not o.is_done())
	eq(o.progress(), 0)
	eq(o.current(), id)


func test_hash_follows_the_state() -> void:
	var a := _objectives()
	var b := _objectives()
	a.start_leg(1)
	b.start_leg(1)
	eq(a.hash_into(7), b.hash_into(7))
	a.force(LegObjectives.CLOSE_PASSES)
	b.force(LegObjectives.CLOSE_PASSES)
	a.notify_scored(ScoreEvents.CLOSE_PASS)
	ne(a.hash_into(7), b.hash_into(7), "progress changes the hash")


func test_ticks_allocate_nothing() -> void:
	var o := _objectives()
	o.force(LegObjectives.SLIPSTREAM)
	o.step(dt, 0.0, 50.0, true, false)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 2000:
		o.step(dt, 0.3, 50.0, i % 3 == 0, false)
		o.notify_scored(ScoreEvents.CLOSE_PASS)
		o.hash_into(i)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects created by ticks")


# ---------------------------------------------------------------- LegTracker hooks

func test_tracker_carries_the_objective_and_its_points_into_the_crossing() -> void:
	var road := StraightRoadPath.new(3, t.road)
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 500.0, 500.0, 1.0, BiomeDef.LANDMARK_TOLL_GANTRY))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 1000.0, 1000.0, 2.0, BiomeDef.LANDMARK_TOLL_GANTRY))
	var tracker := LegTracker.new(legs)
	tracker.reset(0.0)
	tracker.plan_ahead(road, 1200.0)
	var buf := ScoreEventBuffer.new(32)
	eq(tracker.leg_start_s(), 0.0)
	tracker.set_objective(LegObjectives.CLOSE_PASSES)
	tracker.complete_objective(5000)
	check(tracker.step(dt, 501.0, true, buf))
	eq(tracker.crossing.objective, LegObjectives.CLOSE_PASSES)
	check(tracker.crossing.objective_done)
	eq(tracker.crossing.objective_points, 5000, "paid mid-leg, carried into the summary")
	eq(tracker.leg_start_s(), 500.0, "the new leg starts at the line")
	# The next leg: a "no X" objective is marked done at the line, after step().
	tracker.set_objective(LegObjectives.NO_BRAKING)
	check(tracker.step(dt, 1001.0, false, buf))
	check(not tracker.crossing.objective_done)
	eq(tracker.crossing.objective_points, 0)
	tracker.complete_crossing_objective(2500)
	check(tracker.crossing.objective_done)
	eq(tracker.crossing.objective_points, 2500)
	check(not tracker.is_objective_done(), "the new leg's objective is untouched")
