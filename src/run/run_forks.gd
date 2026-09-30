class_name RunForks
extends RefCounted
## The run's forks (WP6.5). Spec: Core loop → Legs and checkpoints → Forks ("Signs name
## both 1 km ahead; you pick by the side of the road you are on at the split"), Modes
## (Daily Drive: the same forks for everyone that day), Traffic fairness (no ambushes).
## docs/FORKS.md.
##
##   forks.setup(run, enabled)       # _start_run, right after the road is made
##   forks.tick(player)              # every RUNNING tick, before traffic
##   forks.guard_traffic()           # every tick, after the traffic director
##   forks.forget_before(s)          # with the road's
##
## The ForkPlan (from the run seed) fixes which checkpoints fork; the main road is made
## with every unresolved fork's LEFT branch and holds its generation at the next
## unresolved split (ProceduralRoadPath.hold_at_forks). For the next fork a candidate
## path is made with the RIGHT branch (same seed, the route through that choice, shifted
## by the left lanes' width) and generated up to the main road in the background; then
## the ForkView draws both branches and the RoadBuilder leaves them the zone. At the
## split (when the car's nose reaches it) the side of the car's centre picks: RIGHT swaps
## the main road's state with the candidate's (the player's d moves by the shift; every
## car on the player's carriageway, all behind the split, is removed), LEFT keeps it.
## The branch not taken narrows away in the ForkView. The biome plans follow the route
## (BiomePlan.set_leg_ids) and fork_taken is pushed; the checkpoint crossing at the same
## line then names the chosen biome.
##
## Traffic: the director gets a breather around an unresolved split (no spawns) and any
## car at split - fork_traffic_guard_m or beyond is removed, so no car reaches a branch
## before the player picks, nothing drives in the gore and nothing changes lanes across
## it. Deterministic: plans, candidate paths and choices are functions of the seed and the
## player's trace. Candidate generation is director rate (a few blocks per tick).

const KIND_FORK_ANNOUNCED := &"fork_announced"   ## value = fork index
const KIND_FORK_TAKEN := &"fork_taken"           ## tag = the chosen biome, value = side
## Candidate generation per tick while catching up (table blocks).
const CATCH_UP_BLOCKS_PER_TICK := 2

var plan: ForkPlan
## Per fork: ForkPlan.LEFT / RIGHT once picked, else UNRESOLVED.
var choices := PackedInt32Array()
## The fork being approached or driven through (-1: none left).
var active: int = -1
## The active fork's RIGHT branch path (null until made) and whether it has caught up
## (the ForkView draws both branches).
var candidate: ProceduralRoadPath
var ready: bool = false
var announced: bool = false
## Forks resolved this run, and how many went right (tests, dev).
var resolved_count: int = 0
var right_count: int = 0

var _run: Run
var _ctx: RunContext
var _t: Tuning
var _road: ProceduralRoadPath
var _cand_plan: BiomePlan
var _main_plan: BiomePlan
var _shifts := PackedFloat64Array()
var _breather: bool = false
var _enabled: bool = true


## A new run: the plan, the main road's route and forks, the look plan (handed to the
## biome director before its setup), the first fork. `enabled` false = no forks.
func setup(run: Run, enabled: bool = true) -> void:
	_run = run
	_ctx = run.ctx
	_t = run.tuning
	_road = run.road as ProceduralRoadPath
	_enabled = enabled
	var legs := _t.legs
	plan = ForkPlan.build(legs, _ctx.rng_road.derive(ForkPlan.STREAM)) if enabled else ForkPlan.none(legs)
	choices = PackedInt32Array()
	choices.resize(plan.count())
	choices.fill(ForkPlan.UNRESOLVED)
	_shifts = PackedFloat64Array()
	_shifts.resize(plan.count())
	active = -1
	candidate = null
	ready = false
	announced = false
	resolved_count = 0
	right_count = 0
	_breather = false
	run.builder.clear_skip_range()
	run.fork_view.end()
	_main_plan = BiomePlan.from_ids(plan.route(choices), plan.endless_id, legs.leg_length_m())
	_road.hold_at_forks = true
	_road.set_biome_plan(_main_plan)
	_road.set_forks(_forks_for(-1), 0.0, 0.0)
	var look := BiomePlan.from_ids(plan.look_route(choices), plan.endless_id, legs.leg_length_m())
	_mark_blend(look)
	run.biome_director.plan = look
	run.biome_director.apply_to_road = false


## After the world nodes' setup: the first fork's zone and breather.
func start() -> void:
	_next_fork()


## Candidates advance, the fork is announced, traffic is kept off the branches, and the
## split resolves the fork. Every RUNNING tick, before the traffic sim.
func tick(player: VehicleState) -> void:
	if active < 0:
		return
	var f := _main_fork()
	if f == null:
		return
	if choices[active] == ForkPlan.UNRESOLVED:
		_advance_candidate(player.s)
		if not announced and player.s >= f.split_s - _t.legs.fork_sign_distance_m:
			announced = true
			_run.events.push(KIND_FORK_ANNOUNCED, 0, 0.0, -1.0, -1, float(active))
		if player.s + _run.car.car.length_m * 0.5 >= f.split_s:
			_resolve(f, player)
	elif player.s > f.gore_end_s() + _t.road.chunk_keep_behind_m:
		_finish()


## Keeps the candidate's memory in step with the main road's.
func forget_before(s: float) -> void:
	if candidate != null:
		candidate.forget_before(s)


## Teleports and warm-ups: forks the car jumped past take their left branch (the route
## as planned, like a player who never left it), the next one's candidate catches up at
## once. Dev and tests only (a drive never skips a split).
func sync(player_s: float) -> void:
	while active >= 0:
		var f := _main_fork()
		if f == null:
			return
		if choices[active] != ForkPlan.UNRESOLVED:
			if player_s > f.split_s:
				_finish()
				continue
			return
		if player_s < f.split_s:
			break
		_skip(f)
	if active >= 0:
		_advance_candidate(player_s, true)


## The biome the left / right branch of fork i leads to on the current route.
func left_id(i: int) -> StringName:
	return plan.left_id(i, choices)


func right_id(i: int) -> StringName:
	return plan.right_id(i, choices)


## The split of fork i (INF when it is not a fork on this route).
func split_s(i: int) -> float:
	for f in _road.forks:
		if f.index == i:
			return f.split_s
	return INF


## d of the lane line the split divides (the gore nose), on the main road's trunk.
func gore_line_d(f: RoadFork) -> float:
	var q := f.split_s - RoadBuilder.SPLIT_PROBE_M
	return _road.lanes_left_edge_d(q) + float(f.lanes_left) * _road.lane_width(q)


func hash_into(h: int) -> int:
	h = plan.hash_into(h)
	for c in choices:
		h = TraceHash.mix_int(h, c)
	return h


# ---------------------------------------------------------------- Internals

## The main road's record of the active fork.
func _main_fork() -> RoadFork:
	for f in _road.forks:
		if f.index == active:
			return f
	return null


## The forks a path meets: resolved ones as chosen, fork `right_at` RIGHT, the rest LEFT.
func _forks_for(right_at: int) -> Array[RoadFork]:
	var out: Array[RoadFork] = []
	var cs := choices if right_at < 0 else plan.with_choice(choices, right_at, ForkPlan.RIGHT)
	for i in plan.count():
		if not plan.is_real(i, cs):
			continue
		var f := RoadFork.new(_t.road)
		f.index = i
		f.checkpoint = plan.checkpoints[i]
		f.split_s = float(f.checkpoint) * _t.legs.leg_length_m()
		f.left_id = plan.left_id(i, cs)
		f.right_id = plan.right_id(i, cs)
		var c := cs[i] if i < cs.size() else ForkPlan.UNRESOLVED
		f.side = ForkPlan.RIGHT if c == ForkPlan.RIGHT else ForkPlan.LEFT
		f.resolved = choices[i] != ForkPlan.UNRESOLVED
		f.shift_m = _shifts[i] if f.side == ForkPlan.RIGHT else 0.0
		out.append(f)
	return out


## Look plan: every fork checkpoint blends from its line (the split).
func _mark_blend(p: BiomePlan) -> void:
	for i in plan.count():
		p.set_blend_from_line(plan.checkpoints[i])


func _next_fork() -> void:
	active = -1
	candidate = null
	ready = false
	announced = false
	_run.builder.clear_skip_range()
	for f in _road.forks:
		if not f.resolved:
			active = f.index
			break
	if active < 0:
		return
	var f := _main_fork()
	_run.builder.set_skip_range(f.split_s, f.split_s + f.draw_m)
	var rt := _t.road
	_run.director.request_breather(f.split_s - rt.fork_breather_before_m, f.split_s + rt.fork_breather_after_m)
	_breather = true


## Makes the candidate once the main road's table covers the split (its heading there
## gives the shift), then generates it toward the main road's table end, a few blocks per
## tick, or at once (`now`, or when the player is close enough to see past the split).
func _advance_candidate(player_s: float, now: bool = false) -> void:
	var f := _main_fork()
	if f == null or ready:
		return
	var rt := _t.road
	var near := player_s >= f.split_s - _run.sim_horizon_m() - rt.chunk_prefetch_m \
		- rt.chunk_length_m * 2.0 - rt.fork_approach_straight_m
	if candidate == null:
		_road.ensure_generated_to(f.split_s + rt.sample_spacing_m)
		if _road.table_end() < f.split_s + rt.sample_spacing_m:
			return
		_make_candidate(f)
	var target := maxf(_road.table_end(), f.split_s + f.draw_m + rt.chunk_length_m)
	if now or near:
		candidate.ensure_generated_to(target)
	else:
		for b in CATCH_UP_BLOCKS_PER_TICK:
			if candidate.table_end() >= target:
				break
			candidate.ensure_generated_to(candidate.table_end() + rt.generation_block_m)
			candidate.forget_before(_road.first_retained_s())
	if candidate.table_end() >= target:
		_become_ready(f)


func _make_candidate(f: RoadFork) -> void:
	var legs := _t.legs
	var cs := plan.with_choice(choices, active, ForkPlan.RIGHT)
	_cand_plan = BiomePlan.from_ids(plan.route(cs), plan.endless_id, legs.leg_length_m())
	var shift := float(f.lanes_left) * _road.lane_width(f.split_s - RoadBuilder.SPLIT_PROBE_M)
	_shifts[active] = shift
	var h := _road.heading_at(f.split_s)
	candidate = ProceduralRoadPath.new(_ctx)
	candidate.set_biome_plan(_cand_plan)
	candidate.set_forks(_forks_for(active), _road.origin_offset_x() + cos(h) * shift,   # lint: allow-libm the branch's world origin (rendering)
		_road.origin_offset_z() + sin(h) * shift)   # lint: allow-libm the branch's world origin (rendering)


func _become_ready(f: RoadFork) -> void:
	ready = true
	var cf := _cand_fork()
	f.sibling = candidate
	if cf != null:
		cf.sibling = _road
	var look := BiomePlan.from_ids(plan.route(choices), plan.endless_id, _t.legs.leg_length_m())
	_mark_blend(look)
	_mark_blend(_cand_plan)
	_run.fork_view.begin(f, _road, candidate, look, _cand_plan)
	_run.fork_view.update_view(_run.car.state.s)


func _cand_fork() -> RoadFork:
	if candidate == null:
		return null
	for cf in candidate.forks:
		if cf.index == active:
			return cf
	return null


## Removes player-carriageway traffic at or past an unresolved fork's guard line, after
## the traffic moved and the director spawned (so no such car is ever drawn or scored).
## Allocation-free.
func guard_traffic() -> void:
	if active < 0:
		return
	var f := _main_fork()
	if f == null:
		return
	var ts := _run.sim.state
	if choices[active] == ForkPlan.UNRESOLVED:
		var line := f.split_s - _t.road.fork_traffic_guard_m
		for i in ts.capacity:
			if ts.active[i] != 0 and ts.s[i] >= line:
				_run.sim.despawn(i)
		return
	# Left branch taken: a car still behind the split in the right lanes (a behind spawn)
	# would drive into the gore. Right branch: the road space before the split has only
	# the right lanes, so there is nothing to do.
	if f.side != ForkPlan.LEFT:
		return
	var gore := gore_line_d(f)
	for i in ts.capacity:
		if ts.active[i] != 0 and ts.s[i] < f.split_s and ts.d[i] > gore:
			_run.sim.despawn(i)


func _resolve(f: RoadFork, player: VehicleState) -> void:
	if not ready:
		_advance_candidate(player.s, true)
	var side := ForkPlan.LEFT if player.d < gore_line_d(f) else ForkPlan.RIGHT
	choices[active] = side
	resolved_count += 1
	var left_path := _road
	var right_path := candidate
	if side == ForkPlan.RIGHT:
		right_count += 1
		# Every car on the player's carriageway is behind the split (the guard): gone.
		var ts := _run.sim.state
		for i in ts.capacity:
			if ts.active[i] != 0:
				_run.sim.despawn(i)
		_road.swap_state(candidate)
		player.d -= _shifts[active]
		left_path = candidate
		right_path = _road
		var mf := _main_fork()
		var cf := _cand_fork()
		if mf != null:
			mf.sibling = candidate
		if cf != null:
			cf.sibling = _road
		_run.on_fork_swapped()
	var mf2 := _main_fork()
	if mf2 != null:
		mf2.resolved = true
	var other := candidate
	if other != null:
		other.vanish_from(active, f.split_s + f.draw_m + _t.road.fork_vanish_start_m)
		for cf in other.forks:
			if cf.index == active:
				cf.resolved = true
	_run.fork_view.resolve(side, left_path, right_path)
	_run.biome_director.plan.set_leg_ids(plan.look_route(choices))
	if _breather:
		_run.director.clear_breathers()
		_breather = false
	var chosen := plan.route(choices)[f.checkpoint] if f.checkpoint < plan.legs_to_coast else plan.endless_id
	_run.events.push(KIND_FORK_TAKEN, 0, 0.0, -1.0, -1, float(side), chosen)


## A teleport past an unresolved split: the left branch, as planned.
func _skip(f: RoadFork) -> void:
	choices[active] = ForkPlan.LEFT
	resolved_count += 1
	f.resolved = true
	_run.biome_director.plan.set_leg_ids(plan.look_route(choices))
	if _breather:
		_run.director.clear_breathers()
		_breather = false
	_run.events.push(KIND_FORK_TAKEN, 0, 0.0, -1.0, -1, float(ForkPlan.LEFT), f.left_id)
	_finish()


## The gore is behind: drop the candidate and the zone, then the next fork.
func _finish() -> void:
	_run.fork_view.end()
	_run.builder.clear_skip_range()
	var mf := _main_fork()
	if mf != null:
		mf.sibling = null
	candidate = null
	_next_fork()
