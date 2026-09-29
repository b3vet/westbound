extends WBTest
## WP6.5 Journey mode end to end: legs through the planned biomes (with forks), the
## coast, the finale, the endless coastal highway, results. Spec: The journey goal ("The
## coast is the destination, reached after 8 legs. Arriving plays a finale ... A journey
## bonus is paid and 'Journey complete' is recorded. The road continues as an endless
## coastal highway"), Cameras → Scripted cameras (the 3 s finale swing in a traffic-free
## breather while the car holds its lane), Run end (results: whether the coast was
## reached), Modes (Daily Drive: same route and forks for the same date).
##
## The real Run, ticked manually by a lane-keeping bot; each leg is shortened by
## teleporting to just before its checkpoint (forks: before the split, in the lane that
## picks the side the test wants).

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 3
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const APPROACH_M := 60.0
const APPROACH_KMH := 180.0

var t: Tuning
var _runs: Array[Run] = []
var _conns: Array = []
var _log: Array = []
var _saved_rm: Variant


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	_log.clear()
	_saved_rm = Settings.get_value(&"reduced_motion")
	Settings.set_value(&"reduced_motion", false)
	_listen(Events.fork_announced, func(l: StringName, r: StringName) -> void: _log.append(["fork_announced", l, r]))
	_listen(Events.fork_taken, func(b: StringName) -> void: _log.append(["fork_taken", b]))
	_listen(Events.checkpoint_crossed, func(leg: int, _s: Dictionary) -> void: _log.append(["checkpoint_crossed", leg]))
	_listen(Events.leg_started, func(leg: int, b: StringName, _o: StringName) -> void: _log.append(["leg_started", leg, b]))
	_listen(Events.coast_reached, func() -> void: _log.append(["coast_reached"]))
	_listen(Events.journey_complete, func() -> void: _log.append(["journey_complete"]))
	_listen(Events.bonus_awarded, func(k: StringName, p: int, _tot: int) -> void: _log.append(["bonus_awarded", k, p]))
	_listen(Events.run_over, func(res: Dictionary) -> void: _log.append(["run_over", res]))


func after_each() -> void:
	Settings.set_value(&"reduced_motion", _saved_rm)
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _make(run_seed: int = SEED, run_mode: StringName = RunContext.MODE_JOURNEY) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.mode = run_mode
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.infinite_lives = true
	tree.root.add_child(r)
	_runs.append(r)
	r.go()
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.KEEP
	bot.v_target = Units.kmh_to_mps(APPROACH_KMH)
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	return r


func _bot(r: Run) -> SandboxBot:
	return r.drive_controller as SandboxBot


func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


## Teleports before the next checkpoint (a fork: into the lane of `side`) and crosses.
func _cross(r: Run, side: int) -> void:
	var done := r.legs.legs_completed
	var cp := r.car.state.s + r.legs.distance_to_checkpoint(r.car.state.s)
	check(is_finite(cp), "a checkpoint is queued")
	var s := cp - APPROACH_M
	r.dev_teleport(s, Units.kmh_to_mps(APPROACH_KMH))
	var lane := 1
	var fork := r.forks.active >= 0 and absf(r.forks.split_s(r.forks.active) - cp) < 1.0
	if fork:
		lane = 0 if side == ForkPlan.LEFT else r.road.lane_count(s) - 1
	r.car.place_at(s, r.road.lane_center_d(lane, s), Units.kmh_to_mps(APPROACH_KMH))
	r.hits.reset(r.car.state, r.sim.state)
	_bot(r).target_lane = lane
	var ticks := 0
	while r.legs.legs_completed == done and ticks < 120 * 4:
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	eq(r.legs.legs_completed, done + 1, "crossed checkpoint %d" % (done + 1))
	_run_ticks(r, TICKS_PER_FRAME * 4)


func _entries(kind: String) -> Array:
	var out: Array = []
	for e: Array in _log:
		if e[0] == kind:
			out.append(e)
	return out


func _index(entry: Array) -> int:
	for i in _log.size():
		var e: Array = _log[i]
		if e.size() >= entry.size() and e.slice(0, entry.size()) == entry:
			return i
	return -1


## Drives the whole journey, taking the forks by `sides` (per fork in order; missing =
## left). Returns the run after the coast crossing.
func _journey(r: Run, sides: Array[int]) -> void:
	for leg in t.legs.legs_to_coast:
		var side := ForkPlan.LEFT
		var cp := r.car.state.s + r.legs.distance_to_checkpoint(r.car.state.s)
		var i := r.forks.active
		if i >= 0 and absf(r.forks.split_s(i) - cp) < 1.0:
			side = sides[i] if i < sides.size() else ForkPlan.LEFT
		_cross(r, side)


## Arms the finale 10 m ahead and clears the traffic the way a crossing would (the
## director refills around the car outside the breather).
func _arm_here(r: Run) -> void:
	r.finale.arm(r.car.state.s + 10.0 - t.legs.finale_after_m)
	r.dev_teleport(r.car.state.s, r.car.state.v)


func test_full_journey_through_forks_to_the_coast_finale() -> void:
	var r := _make()
	var plan := r.forks.plan
	check(plan.count() >= 1, "the journey has forks")
	var sides: Array[int] = [ForkPlan.RIGHT, ForkPlan.LEFT, ForkPlan.RIGHT]
	_journey(r, sides)
	# The biomes per leg follow the route of the choices made.
	var route := plan.route(r.forks.choices)
	var starts := _entries("leg_started")
	for e: Array in starts:
		var leg: int = e[1]
		if leg >= 2 and leg <= t.legs.legs_to_coast:
			eq(e[2], route[leg - 1], "leg %d is %s" % [leg, route[leg - 1]])
		elif leg > t.legs.legs_to_coast:
			eq(e[2], t.legs.endless_biome_id, "the coast after the journey")
	# Each fork: announced, then taken, before its leg starts; the side is the lane's.
	var real := 0
	for i in plan.count():
		if plan.is_real(i, r.forks.choices):
			real += 1
	eq(_entries("fork_taken").size(), real, "every fork taken once")
	for i in plan.count():
		if not plan.is_real(i, r.forks.choices):
			continue
		var want := sides[i] if i < sides.size() else ForkPlan.LEFT
		eq(r.forks.choices[i], want, "fork %d went the lane's way" % i)
		var leg := plan.checkpoints[i] + 1
		var taken := _index(["fork_taken", route[leg - 1]])
		check(taken >= 0 and taken < _index(["leg_started", leg]), "fork %d taken before leg %d starts" % [i, leg])
	eq(_entries("coast_reached").size(), 1, "the coast once")
	check(_log.has(["bonus_awarded", Run.BONUS_JOURNEY, t.legs.journey_bonus_points])
		or _entries("bonus_awarded").any(func(e: Array) -> bool: return e[1] == Run.BONUS_JOURNEY), "journey bonus paid")
	# The finale: drive to its point; it swings, holds the lane, completes once.
	check(r.finale.phase == RunFinale.Phase.ARMED, "armed at the coast crossing")
	r.dev_teleport(r.finale.finale_s - 80.0, Units.kmh_to_mps(APPROACH_KMH))
	_bot(r).target_lane = 1
	r.car.place_at(r.car.state.s, r.road.lane_center_d(1, r.car.state.s), Units.kmh_to_mps(APPROACH_KMH))
	var ticks := 0
	while not r.finale.is_swinging() and ticks < 120 * 4:
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	check(r.finale.is_swinging(), "the finale swing started")
	check(r.rig.is_finale_active(), "the camera swings")
	eq(r.car.controller, r.finale.controller, "the car holds its lane (input ignored)")
	var d0 := r.car.state.d
	var swing_ticks := 0
	var max_w := 0.0
	while r.finale.is_swinging() and swing_ticks < 120 * 5:
		_run_ticks(r, 1)
		r.rig.advance(1.0 / float(t.vehicle.physics_tick_hz))
		max_w = maxf(max_w, r.rig.finale_weight())
		swing_ticks += 1
	near(float(swing_ticks) / float(t.vehicle.physics_tick_hz), t.camera.finale_swing_s, 0.05, "the swing lasts 3 s")
	near(max_w, 1.0, 1e-6, "all the way out to the wide pose")
	near(r.car.state.d, d0, 0.3, "the car held its lane")
	check(not r.rig.is_finale_active(), "the camera is back on its mode")
	eq(r.car.controller, r.drive_controller, "control is back")
	_run_ticks(r, TICKS_PER_FRAME * 4)
	eq(_entries("journey_complete").size(), 1, "journey complete once")
	check(r.stats.journey_complete, "recorded in the run stats")
	# The endless coastal highway goes on.
	var s_end := r.car.state.s
	_run_ticks(r, 120 * 2)
	check(r.car.state.s > s_end + 50.0, "the road goes on")
	eq(r.biome_director.biome_at(r.car.state.s).id, t.legs.endless_biome_id, "on the coast")
	# Results show the coast reached.
	r.infinite_lives = false
	r.lives.lives = 1
	r.force_hit()
	_run_ticks(r, 4)
	r.skip()
	r.frame(FRAME_S)
	var over := _entries("run_over")
	check(not over.is_empty(), "results")
	if not over.is_empty():
		var res: Dictionary = over[0][1]
		check(bool(res.get(RunStats.COAST_REACHED, false)), "results: coast reached")
		check(bool(res.get(RunStats.JOURNEY_COMPLETE, false)), "results: journey complete")


func test_finale_waits_for_a_clear_breather() -> void:
	var r := _make()
	_arm_here(r)
	var fs := r.finale.finale_s
	# A car just ahead of the player keeps the breather from being clear.
	var rec := SpawnSource.Record.new()
	rec.s = r.car.state.s + 120.0
	rec.lane = 1
	rec.d = NAN
	rec.v = Units.kmh_to_mps(80.0)
	rec.v0 = rec.v
	var slot := r.sim.spawn(rec)
	check(slot >= 0, "a car ahead")
	_run_ticks(r, 60)
	check(r.car.state.s > fs, "past the finale point")
	check(not r.finale.is_swinging(), "no swing while a car can reach the player")
	check(not r.rig.is_finale_active(), "the camera stays")
	r.sim.despawn(slot)
	_run_ticks(r, 4)
	check(r.finale.is_swinging(), "the swing starts once clear")


func test_reduced_motion_keeps_the_toast_but_not_the_swing() -> void:
	Settings.set_value(&"reduced_motion", true)
	var r := _make()
	_arm_here(r)
	_run_ticks(r, 60)
	check(not r.rig.is_finale_active(), "no swing with reduced motion")
	eq(r.finale.phase, RunFinale.Phase.DONE)
	eq(_entries("journey_complete").size(), 1, "journey complete still shows")


func test_journey_complete_is_recorded_once_in_the_save() -> void:
	var r := _make()
	r.record_best = true
	var saved: Dictionary = Save.data.duplicate(true)
	var before := Save.journey_count(RunContext.MODE_JOURNEY)
	_arm_here(r)
	_run_ticks(r, 120 * 5)
	eq(Save.journey_count(RunContext.MODE_JOURNEY), before + 1, "one journey recorded")
	check(is_finite(Save.journey_best_time_s(RunContext.MODE_JOURNEY)), "with a time")
	_run_ticks(r, 120)
	eq(Save.journey_count(RunContext.MODE_JOURNEY), before + 1, "not again")
	Save.data = saved
	Save.save_to_disk()


func test_daily_drive_same_date_same_forks_and_route() -> void:
	var seed_a := Rng.daily_seed(2026, 9, 29)
	var a := _make(seed_a, RunContext.MODE_DAILY)
	var b := _make(seed_a, RunContext.MODE_DAILY)
	eq(a.forks.plan.checkpoints, b.forks.plan.checkpoints, "same forks")
	eq(a.forks.plan.route(PackedInt32Array()), b.forks.plan.route(PackedInt32Array()), "same route")
	for i in a.forks.plan.count():
		eq(a.forks.left_id(i), b.forks.left_id(i))
		eq(a.forks.right_id(i), b.forks.right_id(i))
	a.retry()
	eq(a.forks.plan.checkpoints, b.forks.plan.checkpoints, "a daily retry keeps the day's forks")


func soak_full_journey_without_teleports() -> void:
	var r := _make()
	_bot(r).v_target = Units.kmh_to_mps(250.0)
	_bot(r).mode = SandboxBot.Mode.WEAVE
	var target := float(t.legs.legs_to_coast) * t.legs.leg_length_m() + t.legs.finale_after_m \
		+ t.legs.finale_give_up_m + 200.0
	var ticks := 0
	while r.car.state.s < target and ticks < 120 * 60 * 25:
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	check(r.car.state.s >= target, "drove the whole journey (%.0f m)" % r.car.state.s)
	var real := 0
	for i in r.forks.plan.count():
		if r.forks.plan.is_real(i, r.forks.choices):
			real += 1
	eq(_entries("fork_taken").size(), real, "every fork taken")
	eq(_entries("coast_reached").size(), 1, "the coast")
	eq(_entries("journey_complete").size(), 1, "journey complete (swung: %s)" % r.finale.swung)


func test_forked_journey_is_deterministic() -> void:
	var hashes: Array[int] = []
	var sides: Array[int] = [ForkPlan.RIGHT, ForkPlan.RIGHT]
	for n in 2:
		var r := _make()
		for leg in 4:
			var side := ForkPlan.LEFT
			var cp := r.car.state.s + r.legs.distance_to_checkpoint(r.car.state.s)
			var i := r.forks.active
			if i >= 0 and absf(r.forks.split_s(i) - cp) < 1.0:
				side = sides[i] if i < sides.size() else ForkPlan.LEFT
			_cross(r, side)
		hashes.append(r.trace_hash())
		_runs.erase(r)
		r.queue_free()
		await tree.process_frame
	eq(hashes[0], hashes[1], "same seed and choices: the same run through its forks")
