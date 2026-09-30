extends WBTest
## WP8.4: the Daily Drive ghost's playback (DailyGhostPlayback: interpolation in road
## space, jumps, forks) and its mapping onto the player's road across forks
## (DailyDrive.path_for). Spec: Core loop → Modes at launch ("shown as a translucent ghost
## car on later attempts"). docs/DAILY.md → Playback.

const RUN_SCENE := preload("res://src/run/run.tscn")
const HZ := 120
const EVERY := 6
const V := 36.0
const SHIFT := 5.4
const FORK_K := 60
const ALLOC_CALLS := 5000

var _free: Array[Object] = []


func after_each() -> void:
	for o in _free:
		if is_instance_valid(o):
			o.free()
	_free.clear()


## s = 100 + V t, d = 3.5 (after the fork at FORK_K: 3.5 - SHIFT), 2 s.
func _ghost(fork_side: int = ForkPlan.RIGHT) -> DailyGhost:
	var rec := DailyGhostRecorder.new()
	rec.begin("2026-09-30", 1, "falcon_gt", HZ, EVERY, 64)
	var d := 3.5
	for k in range(1, 2 * HZ + 1):
		if k == FORK_K:
			rec.note_fork(k, 0, fork_side)
			if fork_side == ForkPlan.RIGHT:
				d -= SHIFT
		rec.step(k, 100.0 + V * float(k) / HZ, d, 0.02 * float(k % 7), V + float(k) * 0.01,
			DailyGhost.FLAG_BRAKE if k >= HZ else 0, false)
	return rec.finish(100)


func test_interpolates_between_samples() -> void:
	var g := _ghost()
	var pb := DailyGhostPlayback.new()
	pb.setup(g)
	var p := DailyGhostPlayback.Pose.new()
	check(pb.pose_into(1.0, p), "at the first sample")
	near(p.s, 100.0 + V / HZ, 1e-3)
	check(pb.pose_into(0.0, p), "before GO the ghost waits at its first sample")
	near(p.s, g.s_at(0), 1e-9)
	# Between samples 7 and 13 (both regular): linear.
	check(pb.pose_into(10.0, p))
	near(p.s, 100.0 + V * 10.0 / HZ, 1e-3, "s halfway")
	near(p.v, V + 0.1, 1e-2, "speed halfway")
	near(p.yaw, lerpf(g.yaw_at(1), g.yaw_at(2), 0.5), 1e-4, "heading halfway")
	check(pb.pose_into(13.0, p))
	near(p.s, g.s_at(2), 1e-9, "exact on a sample")
	check(pb.pose_into(float(HZ + 1), p))
	check((p.flags & DailyGhost.FLAG_BRAKE) != 0, "the flags of the sample at or before")
	check(pb.pose_into(float(g.last_tick()), p), "the last tick")
	check(not pb.pose_into(float(g.last_tick()) + 0.5, p), "then the ghost's run is over")
	check(pb.pose_into(10.0, p), "rewinds (a retry)")
	near(p.s, 100.0 + V * 10.0 / HZ, 1e-3)


func test_never_interpolates_across_a_jump() -> void:
	var g := _ghost()
	var pb := DailyGhostPlayback.new()
	pb.setup(g)
	var p := DailyGhostPlayback.Pose.new()
	check(pb.pose_into(float(FORK_K) - 0.5, p))
	near(p.d, 3.5, 1e-9, "just before the swap: the old frame's d, no blend")
	eq(p.forks_done, 0, "the fork is not resolved yet")
	check(pb.pose_into(float(FORK_K), p))
	near(p.d, 3.5 - SHIFT, 1e-9, "at the swap: the new frame")
	eq(p.forks_done, 1)
	check(pb.pose_into(float(FORK_K) + 3.0, p))
	near(p.d, 3.5 - SHIFT, 1e-9, "after it, interpolation again (same frame)")
	check(pb.pose_into(10.0, p))
	eq(p.forks_done, 0, "rewinding un-resolves it")


func test_no_ghost_draws_nothing() -> void:
	var pb := DailyGhostPlayback.new()
	var p := DailyGhostPlayback.Pose.new()
	check(not pb.has_ghost())
	check(not pb.pose_into(10.0, p), "no ghost, no pose")
	pb.setup(DailyGhost.new())
	check(not pb.pose_into(10.0, p), "an empty ghost, no pose")


func test_pose_into_allocates_nothing() -> void:
	var pb := DailyGhostPlayback.new()
	pb.setup(_ghost())
	var p := DailyGhostPlayback.Pose.new()
	pb.pose_into(0.0, p)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in ALLOC_CALLS:
		pb.pose_into(float(i % (2 * HZ)) + 0.25, p)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects")
	eq(Performance.get_monitor(Performance.MEMORY_STATIC), mem, "no memory")


# ---------------------------------------------------------------- Forks: which road

## A Run that is never added to the tree (no _ready): just its forks and roads for
## DailyDrive.path_for.
func _drive(ghost: DailyGhost, player_choice: int, active: int = 0) -> DailyDrive:
	var r := RUN_SCENE.instantiate() as Run
	_free.append(r)
	var ctx := RunContext.new(1, RunContext.MODE_DAILY, Tuning.load_default())
	r.road = ProceduralRoadPath.new(ctx)
	r.forks.choices = PackedInt32Array([player_choice, ForkPlan.UNRESOLVED])
	r.forks.active = active
	r.forks._shifts = PackedFloat64Array([SHIFT, SHIFT])
	r.forks.candidate = ProceduralRoadPath.new(ctx)
	r.forks.ready = true
	var dd := DailyDrive.new()
	_free.append(dd)
	dd.run = r
	dd.playback.setup(ghost)
	return dd


func test_the_ghost_follows_the_forks() -> void:
	var right := _ghost(ForkPlan.RIGHT)
	var left := _ghost(ForkPlan.LEFT)
	# Player still before the split (the fork is active and unresolved).
	var dd := _drive(right, ForkPlan.UNRESOLVED)
	check(dd.path_for(0) == dd.run.road, "before its split: the main road")
	check(dd.path_for(1) == dd.run.forks.candidate, "past it on the right: the right branch's path")
	dd.run.forks.ready = false
	check(dd.path_for(1) == null, "a right branch not made yet: hidden")
	dd = _drive(left, ForkPlan.UNRESOLVED)
	check(dd.path_for(1) == dd.run.road, "past it on the left: the main road (the left branch)")
	# Player went the same way: the main road, no shift.
	dd = _drive(right, ForkPlan.RIGHT)
	check(dd.path_for(1) == dd.run.road, "same branch: the main road")
	near(dd._shift_d, 0.0, 1e-12, "the ghost's d is already in that frame")
	# Player went right, the ghost is still before the split: the road's d frame moved.
	check(dd.path_for(0) == dd.run.road, "behind the split: the (swapped) main road")
	near(dd._shift_d, -SHIFT, 1e-12, "its old-frame d moves by the shift")
	# Different branches: the ghost is on a road the player does not have.
	dd = _drive(right, ForkPlan.LEFT)
	check(dd.path_for(1) == null, "the other branch: hidden")
	dd = _drive(left, ForkPlan.RIGHT)
	check(dd.path_for(1) == null, "the other branch: hidden")
	# A fork the player has not reached, beyond the active one: hidden.
	dd = _drive(right, ForkPlan.UNRESOLVED, 1)
	check(dd.path_for(1) == null, "beyond the next split: hidden")
