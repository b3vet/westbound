extends WBTest
## The director's commit path with passability (WP6.1). Spec: Traffic → Passability
## guarantee ("Before committing any spawn batch (the next ~300 m), the director runs
## passability.gd ... Without one, re-roll the batch (up to 5 times), then remove the
## vehicle that blocks the most paths"); Fairness rule 5 (nothing removed in view);
## Architecture rule 5 (determinism). A fake sim and scripted sources on a straight
## road; the real registry and a real car's VehicleParams. docs/PASSABILITY.md.

const SEED := 610001
const DT := 1.0 / 120.0
const LANES := 3
const CAR := "res://data/cars/falcon_gt.tres"
## Batches the start-of-run prefill plans (player s .. ahead distance, 300 m each).
const PREFILL_CALLS := 3

var tuning: Tuning
var reg: SpawnFixtureRegistry
var params: VehicleParams
var car: CarDef


## A source planning a wall (a truck in every lane but open_lane, side by side, 60 m
## into the range) on the calls listed in `wall_calls` (0-based), nothing otherwise.
class WallSource:
	extends SpawnSource
	var truck_p: int
	var semi_t: int
	var lanes: int
	var wall_calls := PackedInt32Array()
	var open_lane := -1
	var scripted := false
	var calls := 0

	func source_id() -> StringName:
		return &"wall_test"

	func plan_batch(_ctx: SpawnSource.Context, s_from: float, _s_to: float, out: Array[SpawnSource.Record]) -> void:
		var wall := wall_calls.has(calls)
		calls += 1
		if not wall:
			return
		for lane in lanes:
			if lane == open_lane:
				continue
			var r := SpawnSource.Record.new()
			r.lane = lane
			r.s = s_from + 60.0
			r.v = Units.kmh_to_mps(85.0)
			r.v0 = r.v
			r.profile_id = truck_p
			r.type_id = semi_t
			if scripted:
				r.flags = TrafficState.FLAG_SCRIPTED
				r.set_piece = &"truck_wall"
			out.append(r)


var road: StraightRoadPath
var sim: FakeTrafficSim
var dir: TrafficDirector
var player: VehicleState
var src: WallSource


func before_all() -> void:
	tuning = Tuning.load_default()
	reg = SpawnFixtureRegistry.new()
	car = load(CAR) as CarDef
	params = VehicleParams.build(tuning, car)


func _setup(seed_value: int = SEED, with_params: bool = true) -> void:
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	road = StraightRoadPath.new(LANES, tuning.road)
	sim = FakeTrafficSim.new(tuning.traffic.max_active_vehicles, road, reg.types)
	dir = TrafficDirector.new(run, road, sim, reg.profiles, reg.types, car.length_m, car.width_m)
	if with_params:
		dir.set_player_params(params)
	player = VehicleState.new()
	player.s = 0.0
	player.d = road.lane_center_d(1, 0.0)
	player.v = Units.kmh_to_mps(150.0)
	src = WallSource.new()
	src.truck_p = reg.profile_index(&"truck")
	src.lanes = LANES
	for i in reg.types.size():
		if reg.types[i].id == &"semi":
			src.semi_t = i


func _drive(seconds: float) -> void:
	for k in roundi(seconds / DT):
		player.s += player.v * DT
		sim.step(DT)
		dir.step(DT, player)


## Trucks side by side (within 1 m) across every lane anywhere on the road.
func _walls() -> int:
	var n := 0
	var ts := sim.state
	for i in ts.capacity:
		if ts.active[i] == 0 or ts.length[i] < 10.0:
			continue
		var lanes_hit := 0
		for j in ts.capacity:
			if ts.active[j] == 1 and ts.length[j] >= 10.0 and absf(ts.s[j] - ts.s[i]) < 1.0:
				lanes_hit |= 1 << ts.lane[j]
		if lanes_hit == (1 << LANES) - 1:
			n += 1
	return n


func test_without_params_the_director_commits_as_before() -> void:
	_setup(SEED, false)
	check(not dir.passability_active(), "no params, no passability")
	dir.reset(player)
	_drive(10.0)
	eq(dir.pass_checks, 0, "no checks")


func test_a_wall_batch_is_rerolled_before_it_can_be_seen() -> void:
	_setup()
	dir.source = src
	src.wall_calls = PackedInt32Array([PREFILL_CALLS])   # the first ahead batch is a wall
	dir.reset(player)
	_drive(12.0)
	ge(dir.pass_checks, 2, "the wall failed and its re-roll was checked")
	ge(dir.pass_rerolls, 1, "re-rolled")
	eq(dir.pass_unresolved, 0, "resolved")
	eq(_walls(), 0, "no wall left on the road")
	eq(dir.rejected_visible, 0, "nothing popped in")


func test_a_batch_with_one_open_lane_passes_first_time() -> void:
	_setup()
	dir.source = src
	src.wall_calls = PackedInt32Array([3, 4, 5, 6])
	src.open_lane = 0
	dir.reset(player)
	_drive(12.0)
	gt(dir.pass_checks, 0, "checked")
	eq(dir.pass_failed, 0, "one open lane is passable")
	eq(dir.pass_rerolls, 0, "no re-roll")


func test_a_persistent_wall_is_cleared_by_removing_blockers() -> void:
	# Every plan is a wall: the re-rolls cannot help, so blockers are removed (beyond the
	# fog only) until the batch passes.
	_setup()
	dir.source = src
	var calls := PackedInt32Array()
	for k in 200:
		calls.append(PREFILL_CALLS + k)
	src.wall_calls = calls
	dir.reset(player)
	_drive(12.0)
	ge(dir.pass_rerolls, tuning.passability.max_rerolls, "re-rolled the maximum")
	ge(dir.pass_removed, 1, "then removed the worst blocker")
	eq(dir.pass_unresolved, 0, "the wall was cleared")
	eq(_walls(), 0, "no wall left")


func test_scripted_batches_take_the_same_path() -> void:
	_setup()
	dir.source = src
	src.wall_calls = PackedInt32Array([PREFILL_CALLS])
	src.scripted = true
	dir.reset(player)
	_drive(8.0)
	ge(dir.pass_scripted_batches, 1, "a set-piece batch was checked")
	ge(dir.pass_rerolls, 1, "and re-rolled like any other")


func test_the_prefill_is_checked_before_anything_is_drawn() -> void:
	_setup()
	dir.source = src
	src.wall_calls = PackedInt32Array([1])   # the second prefill batch
	dir.reset(player)
	ge(dir.pass_checks, 3, "every prefill batch checked at once")
	ge(dir.pass_rerolls, 1, "the wall re-rolled during the prefill")
	eq(_walls(), 0, "no wall on the road at the start")
	check(not dir.passability_busy(), "nothing pending after reset")


func test_checks_are_spread_over_ticks() -> void:
	_setup()
	dir.reset(player)
	_drive(6.0)
	gt(dir.pass_batches, 0, "batches checked while driving")
	ge(dir.pass_ticks_max, 1, "a check spans at least one tick")


func _trace(seed_value: int) -> PackedInt64Array:
	_setup(seed_value)
	dir.source = src
	src.wall_calls = PackedInt32Array([PREFILL_CALLS, PREFILL_CALLS + 3])
	dir.reset(player)
	var h := TraceHash.SEED
	for k in 20:
		_drive(1.0)
		h = sim.state.hash_into(h)
	return PackedInt64Array([h, dir.pass_checks, dir.pass_failed, dir.pass_rerolls, dir.pass_removed,
		dir.spawned_ahead])


func test_deterministic_commit_decisions() -> void:
	var a := _trace(SEED)
	var b := _trace(SEED)
	eq(a, b, "same seed: same trace and the same commit decisions")
	gt(a[2], 0, "the trace includes failed checks")
