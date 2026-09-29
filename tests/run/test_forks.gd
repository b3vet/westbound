extends WBTest
## WP6.5 forks in the real run. Spec: Core loop → Legs and checkpoints → Forks ("Some
## checkpoints split the road OutRun-style into two branches leading to different
## biomes. Signs name both 1 km ahead; you pick by the side of the road you are on at the
## split"), Lives (a barrier counts as a hit, first touch), Traffic fairness (no
## ambushes). docs/FORKS.md.
##
## The real Run (run.tscn), ticked manually; the car is teleported just before a fork's
## split and driven across it by a lane-keeping bot.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 5
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const APPROACH_KMH := 180.0
const APPROACH_M := 260.0
const PAST_SPLIT_M := 180.0

var t: Tuning
var _runs: Array[Run] = []
var _conns: Array = []
var _log: Array = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	_log.clear()
	_listen(Events.fork_taken, func(b: StringName) -> void: _log.append(["fork_taken", b]))
	_listen(Events.fork_announced, func(l: StringName, r: StringName) -> void: _log.append(["fork_announced", l, r]))
	_listen(Events.hit, func(src: StringName, left: int) -> void: _log.append(["hit", src, left]))
	_listen(Events.leg_started, func(leg: int, b: StringName, _o: StringName) -> void:
		_log.append(["leg_started", leg, b]))


func after_each() -> void:
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


func _make(run_seed: int = SEED) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	r.go()
	return r


func _keep(r: Run, lane: int) -> SandboxBot:
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.KEEP
	bot.v_target = Units.kmh_to_mps(APPROACH_KMH)
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	bot.target_lane = lane
	return bot


func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


## Teleports `before_m` ahead of the active fork's split, in `lane` (or at d when given).
func _to_fork(r: Run, before_m: float, lane: int, d: float = NAN) -> float:
	var split := r.forks.split_s(r.forks.active)
	check(is_finite(split), "the run has a fork")
	var s := split - before_m
	r.dev_teleport(s, Units.kmh_to_mps(APPROACH_KMH))
	r.car.place_at(s, r.road.lane_center_d(lane, s) if is_nan(d) else d, Units.kmh_to_mps(APPROACH_KMH))
	r.hits.reset(r.car.state, r.sim.state)
	r.rig.snap_to_target()
	return split


func _drive_past(r: Run, split: float) -> void:
	var guard := 0
	while r.car.state.s < split + PAST_SPLIT_M and guard < 60 * TICKS_PER_FRAME * 8:
		_run_ticks(r, TICKS_PER_FRAME)
		guard += TICKS_PER_FRAME


func _count(kind: String) -> int:
	var n := 0
	for e: Array in _log:
		if e[0] == kind:
			n += 1
	return n


func test_the_run_has_forks_from_its_seed() -> void:
	var r := _make()
	check(r.forks.plan.count() >= t.legs.fork_count_min, "fork_count_min forks")
	check(r.forks.active >= 0, "a fork is next")
	var f := r.road.forks[0]
	eq(f.side, ForkPlan.LEFT, "the main road follows the left branch")
	check(r.road.hold_at_forks, "the main road holds at unresolved forks")
	near(r.road.length_generated(), minf(r.road.table_end(), f.split_s + f.hold_margin_m), 1e-6,
		"nothing past the split is reported before the choice")


func test_left_side_takes_the_left_branch() -> void:
	var r := _make()
	var i := r.forks.active
	var left := r.forks.left_id(i)
	var split := _to_fork(r, APPROACH_M, 0)
	_keep(r, 0)
	_drive_past(r, split)
	eq(r.forks.choices[i], ForkPlan.LEFT, "left lane -> left branch")
	eq(_count("fork_taken"), 1, "fork_taken once")
	check(_log.has(["fork_taken", left]), "fork_taken names the left biome")
	eq(r.biome_director.biome_at(split + 10.0).id, left, "the next leg is the left biome")
	check(not _log.has(["hit", Events.HIT_BARRIER, 1]) and _count("hit") == 0, "a clean pass")
	check(r.road.length_generated() > split + PAST_SPLIT_M, "the hold is released")
	eq(r.forks.right_count, 0)


func test_right_side_takes_the_right_branch_seamlessly() -> void:
	var r := _make()
	var i := r.forks.active
	var right := r.forks.right_id(i)
	var lanes := r.road.lane_count(r.forks.split_s(i) - 10.0)
	var split := _to_fork(r, APPROACH_M, lanes - 1)
	_keep(r, lanes - 1)
	# Drive to just before the swap and remember the car's world position.
	while r.car.state.s + r.car.car.length_m * 0.5 < split - 1.0:
		_run_ticks(r, 1)
	var before := r.road.sample(r.car.state.s)
	var wx := before.pos_x + float(before.right.x) * r.car.state.d
	var wz := before.pos_z + float(before.right.z) * r.car.state.d
	var d_before := r.car.state.d
	_run_ticks(r, 4)
	eq(r.forks.choices[i], ForkPlan.RIGHT, "right lane -> right branch")
	var after := r.road.sample(r.car.state.s)
	var ax := after.pos_x + float(after.right.x) * r.car.state.d
	var az := after.pos_z + float(after.right.z) * r.car.state.d
	var lateral := (ax - wx) * float(before.right.x) + (az - wz) * float(before.right.z)
	check(absf(lateral) < 0.2, "the car does not jump sideways in the world (%.3f m)" % lateral)
	check(r.car.state.d < d_before - 1.0, "d is now on the right branch's own road space")
	_drive_past(r, split)
	eq(_count("fork_taken"), 1, "fork_taken once")
	check(_log.has(["fork_taken", right]), "fork_taken names the right biome")
	eq(r.biome_director.biome_at(split + 10.0).id, right, "the next leg is the right biome")
	eq(_count("hit"), 0, "a clean pass")
	check(r.road.lane_index_at(r.car.state.d, r.car.state.s) >= 0, "still on a lane")
	eq(r.forks.right_count, 1)


func test_fork_is_announced_at_one_km_with_both_biomes() -> void:
	var r := _make()
	var i := r.forks.active
	var split := _to_fork(r, t.legs.fork_sign_distance_m + 30.0, 1)
	_keep(r, 1)
	_run_ticks(r, 120)
	eq(_count("fork_announced"), 1, "announced once")
	check(_log.has(["fork_announced", r.forks.left_id(i), r.forks.right_id(i)]), "names both biomes")
	check(r.car.state.s < split, "before the split")


func test_the_gore_nose_counts_as_a_hit() -> void:
	var r := _make()
	var i := r.forks.active
	var f := r.road.forks[0]
	var split := r.forks.split_s(i)
	var gore := r.forks.gore_line_d(f)
	_to_fork(r, APPROACH_M, 0, gore)
	var bot := _keep(r, 0)
	bot.mode = SandboxBot.Mode.KEEP
	# Hold the car on the lane line into the nose (no steering).
	r.drive_controller = HoldLine.new(Units.kmh_to_mps(APPROACH_KMH))
	_drive_past(r, split)
	check(_count("hit") >= 1, "straddling the gore nose is a hit")
	var first: Array = []
	for e: Array in _log:
		if e[0] == "hit":
			first = e
			break
	eq(first[1] if first.size() > 1 else &"", Events.HIT_BARRIER, "a barrier hit")


func test_no_traffic_reaches_a_branch_or_the_gore() -> void:
	var r := _make()
	var split := r.forks.split_s(r.forks.active)
	_to_fork(r, 1500.0, 1)
	var bot := _keep(r, 1)
	bot.v_target = Units.kmh_to_mps(230.0)
	var guard := split - t.road.fork_traffic_guard_m
	var ticks := 0
	var violations := 0
	var gore_cars := 0
	while r.car.state.s < split + 600.0 and ticks < 120 * 60:
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
		var ts := r.sim.state
		var pending := r.forks.choices[0] == ForkPlan.UNRESOLVED
		for k in ts.capacity:
			if ts.active[k] == 0:
				continue
			if pending and ts.s[k] >= guard:
				violations += 1
			if ts.s[k] >= split and r.road.lane_index_at(ts.d[k], ts.s[k]) < 0 \
					and ts.lc_state[k] == 0:
				gore_cars += 1
	eq(violations, 0, "no car past the guard line before the choice")
	eq(gore_cars, 0, "no car off the lanes (in the gore) past the split")
	check(r.car.state.s >= split + 600.0, "drove through (%.0f m past the split)" % (r.car.state.s - split))


func test_both_branches_are_drawn_before_the_split() -> void:
	var r := _make()
	var split := _to_fork(r, 200.0, 1)
	_run_ticks(r, 60)
	var fv := r.fork_view
	check(fv.is_active(), "the fork view is drawing")
	var fog := r.builder.view_distance_m()
	check(fv.built_to(ForkPlan.LEFT) >= split + fog - 200.0, "left branch built to the fog (%.0f)" % (fv.built_to(ForkPlan.LEFT) - split))
	check(fv.built_to(ForkPlan.RIGHT) >= split + fog - 200.0, "right branch built to the fog (%.0f)" % (fv.built_to(ForkPlan.RIGHT) - split))
	check(fv.cushion_visible(), "the crash cushion stands on the nose")
	# The builder leaves the zone to the fork view.
	for k in range(r.builder.needed_range_min(), r.builder.needed_range_max() + 1):
		var c := r.builder.get_chunk(k)
		if c == null:
			continue
		var s0 := float(k) * t.road.chunk_length_m
		check(s0 + t.road.chunk_length_m <= split + 1e-6 or s0 >= split + t.road.fork_draw_m - 1e-6
			or s0 < split, "chunk %d does not overlap the fork zone" % k)
	# The branches diverge: at the fog end they are far apart.
	var cand := r.forks.candidate
	var a := r.road.sample(split + fog)
	var b := cand.sample(split + fog)
	check(Vector2(b.pos_x - a.pos_x, b.pos_z - a.pos_z).length() > 100.0, "the branches have split apart")


func test_forks_are_deterministic() -> void:
	var hashes: Array[int] = []
	for n in 2:
		var r := _make()
		var split := _to_fork(r, APPROACH_M, 2)
		_keep(r, 2)
		_drive_past(r, split)
		hashes.append(r.trace_hash())
		r.queue_free()
		_runs.erase(r)
		await tree.process_frame
	eq(hashes[0], hashes[1], "same seed, same inputs, same run through a fork")


## Straight ahead at a held speed (the gore test: no steering).
class HoldLine:
	extends VehicleController
	var v: float

	func _init(speed: float) -> void:
		v = speed

	func update(_dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		out_input.steer = clampf(-state.yaw * 4.0 - state.yaw_rate, -1.0, 1.0)
		out_input.throttle = 1.0 if state.v < v else 0.0
		out_input.brake = 0.0
		out_input.boost = false
