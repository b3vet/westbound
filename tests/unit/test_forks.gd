extends WBTest
## WP6.5 fork planning and fork road geometry (pure). Spec: Core loop → Legs and
## checkpoints → Forks, The journey goal (the coast after 8 legs), Modes (Daily Drive:
## the same forks for everyone that day), World → Road (radius, sun band).
## docs/FORKS.md.

const SEED := 20260929

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


func _plan(run_seed: int) -> ForkPlan:
	var ctx := RunContext.new(run_seed, RunContext.MODE_JOURNEY, t)
	return ForkPlan.build(t.legs, ctx.rng_road.derive(ForkPlan.STREAM))


func _stage_of(p: ForkPlan, id: StringName) -> int:
	return p.stage_ids.find(id)


## Every choice combination of `p` (3^n with unresolved).
func _combos(p: ForkPlan) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = [PackedInt32Array()]
	for i in p.count():
		var next: Array[PackedInt32Array] = []
		for c in out:
			for side: int in [ForkPlan.UNRESOLVED, ForkPlan.LEFT, ForkPlan.RIGHT]:
				var d := c.duplicate()
				d.append(side)
				next.append(d)
		out = next
	return out


func test_plan_is_deterministic_by_seed_and_by_date() -> void:
	var a := _plan(SEED)
	var b := _plan(SEED)
	eq(a.checkpoints, b.checkpoints, "same seed, same forks")
	eq(a.hash_into(TraceHash.SEED), b.hash_into(TraceHash.SEED))
	var d1 := RunContext.daily(2026, 9, 29, t)
	var d2 := RunContext.daily(2026, 9, 29, t)
	var pa := ForkPlan.build(t.legs, d1.rng_road.derive(ForkPlan.STREAM))
	var pb := ForkPlan.build(t.legs, d2.rng_road.derive(ForkPlan.STREAM))
	eq(pa.checkpoints, pb.checkpoints, "the same date gives everyone the same forks")
	var seen := {}
	for k in 12:
		seen[_plan(SEED + k * 7919).checkpoints] = true
	check(seen.size() > 1, "seeds vary the forks (%d plans)" % seen.size())


func test_fork_counts_positions_and_spacing() -> void:
	for k in 40:
		var p := _plan(SEED + k * 104729)
		check(p.count() >= t.legs.fork_count_min and p.count() <= t.legs.fork_count_max,
			"fork count in range (%d)" % p.count())
		for i in p.count():
			var c := p.checkpoints[i]
			check(c >= t.legs.fork_first_checkpoint and c < t.legs.legs_to_coast,
				"fork %d at a checkpoint before the coast's" % c)
			if i > 0:
				check(c - p.checkpoints[i - 1] >= t.legs.fork_min_spacing_legs, "forks apart")


func test_unresolved_journey_is_the_default_plan() -> void:
	var p := _plan(SEED)
	eq(p.route(PackedInt32Array()), t.legs.leg_biome_ids, "no choice made = LegsTuning's plan")


func test_every_route_reaches_the_coast_through_every_stage() -> void:
	for k in 25:
		var p := _plan(SEED + k * 15485863)
		for choices in _combos(p):
			var r := p.route(choices)
			eq(r.size(), t.legs.legs_to_coast, "8 legs to the coast")
			var prev := -1
			var stages := {}
			for id in r:
				var st := _stage_of(p, id)
				check(st == prev or st == prev + 1, "stages in order, none skipped (%s)" % [r])
				prev = st
				stages[st] = true
			eq(stages.size(), p.stage_ids.size(), "every biome of the journey appears")
			for i in p.count():
				if not p.is_real(i, choices):
					continue
				var l := p.left_id(i, choices)
				var rr := p.right_id(i, choices)
				ne(l, rr, "a fork offers two different biomes")
				var c := p.checkpoints[i]
				var sub := choices.slice(0, i)
				var planned := p.route(sub)[c]
				eq(l, planned, "the left branch goes on as planned")
				var side := choices[i] if i < choices.size() else ForkPlan.UNRESOLVED
				if side != ForkPlan.UNRESOLVED:
					eq(r[c], l if side == ForkPlan.LEFT else rr, "the choice sets the next leg")


func test_look_route_hides_pending_forks() -> void:
	var p := _plan(SEED)
	var look := p.look_route(PackedInt32Array())
	for i in p.count():
		var c := p.checkpoints[i]
		eq(look[c], look[c - 1], "the leg after a pending fork looks like the one before")


# ---------------------------------------------------------------- Road

## The main (left) path and the right branch path of the first fork of `p`.
func _paths(p: ForkPlan) -> Array[ProceduralRoadPath]:
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, t)
	var leg := t.legs.leg_length_m()
	var left := ProceduralRoadPath.new(ctx)
	left.set_biome_plan(BiomePlan.from_ids(p.route(PackedInt32Array()), p.endless_id, leg))
	left.set_forks(_forks(p, ForkPlan.LEFT, 0.0))
	var f0 := left.forks[0]
	left.ensure_generated_to(f0.split_s + t.road.sample_spacing_m)
	var h := left.heading_at(f0.split_s)
	var shift := float(f0.lanes_left) * t.road.lane_width_m
	var right := ProceduralRoadPath.new(ctx)
	var cs := p.with_choice(PackedInt32Array(), 0, ForkPlan.RIGHT)
	right.set_biome_plan(BiomePlan.from_ids(p.route(cs), p.endless_id, leg))
	right.set_forks(_forks(p, ForkPlan.RIGHT, shift), cos(h) * shift, sin(h) * shift)
	var out: Array[ProceduralRoadPath] = [left, right]
	for path in out:
		path.ensure_generated_to(f0.split_s + 3000.0)
	left.forks[0].sibling = right
	right.forks[0].sibling = left
	return out


func _forks(p: ForkPlan, first_side: int, shift: float) -> Array[RoadFork]:
	var out: Array[RoadFork] = []
	var cs := PackedInt32Array()
	for i in p.count():
		var f := RoadFork.new(t.road)
		f.index = i
		f.checkpoint = p.checkpoints[i]
		f.split_s = float(f.checkpoint) * t.legs.leg_length_m()
		f.side = first_side if i == 0 else ForkPlan.LEFT
		f.shift_m = shift if i == 0 else 0.0
		f.left_id = p.left_id(i, cs)
		f.right_id = p.right_id(i, cs)
		out.append(f)
	return out


func test_branch_paths_agree_up_to_the_split_then_diverge() -> void:
	var p := _plan(SEED)
	var ps := _paths(p)
	var left := ps[0]
	var right := ps[1]
	var f := left.forks[0]
	var shift := float(f.lanes_left) * t.road.lane_width_m
	var s := f.split_s - 2500.0
	while s <= f.split_s:
		var a := left.sample(s)
		var b := right.sample(s)
		check(absf(a.heading - b.heading) < 1e-9, "same heading before the split at %.0f" % (s - f.split_s))
		near(a.elevation, b.elevation, 1e-9, "same profile")
		if s >= f.split_s - f.approach_m:
			var dx := b.pos_x - a.pos_x - float(a.right.x) * shift
			var dz := b.pos_z - a.pos_z - float(a.right.z) * shift
			check(Vector2(dx, dz).length() < 1e-3, "the right path is the road shifted by its lanes' width")
			near(left.curvature_at(s), 0.0, 1e-12, "a straight approach")
		s += 25.0
	# Both branches keep one profile while both are in sight.
	s = f.split_s
	while s < f.gore_end_s():
		near(left.elevation_at(s), right.elevation_at(s), 1e-6, "one profile through the gore")
		s += 50.0
	var band_lo := deg_to_rad(t.road.sun_offset_min_deg) - 1e-6
	var band_hi := deg_to_rad(t.road.sun_offset_max_deg) + 1e-6
	for x: float in [400.0, 1000.0, 1800.0]:
		var a := left.sample(f.split_s + x)
		var b := right.sample(f.split_s + x)
		var gap := Vector2(b.pos_x - a.pos_x, b.pos_z - a.pos_z).length()
		check(gap > x * 0.15, "the branches split apart (%.0f m at %.0f m)" % [gap, x])
		check(absf(a.heading) >= band_lo and absf(a.heading) <= band_hi, "left branch in the sun band")
		check(absf(b.heading) >= band_lo and absf(b.heading) <= band_hi, "right branch in the sun band")
		check(1.0 / maxf(absf(left.curvature_at(f.split_s + x)), 1e-9) >= t.road.min_curve_radius_m - 1e-6, "radius")


func test_lanes_split_then_widen_and_the_gore_opens() -> void:
	var p := _plan(SEED)
	var ps := _paths(p)
	var left := ps[0]
	var right := ps[1]
	var f := left.forks[0]
	var n := left.lane_count(f.split_s - 1.0)
	eq(f.lanes_left + right.forks[0].lanes_right(), n, "the branches share the trunk's lanes")
	eq(left.lane_count(f.split_s + 1.0), f.lanes_left, "left branch: the left lanes")
	eq(right.lane_count(f.split_s + 1.0), n - f.lanes_left, "right branch: the rest")
	eq(right.lane_count(f.split_s - 100.0), n - f.lanes_left, "the right path's approach has its lanes only")
	var edge := left.lanes_right_edge_d(f.split_s + 1.0)
	check(left.guardrail_d(f.split_s + 0.5) < edge, "the gore face starts inside the lane (the cushion)")
	near(left.guardrail_d(f.split_s + 900.0) - left.lanes_right_edge_d(f.split_s + 900.0),
		t.road.shoulder_m + t.road.guardrail_offset_m, 1e-6, "full shoulder and rail once apart")
	check(right.median_barrier_d(f.split_s + 0.5) > right.lanes_left_edge_d(f.split_s + 0.5), "right gore face in its lane")
	near(right.median_barrier_d(f.split_s + 900.0), t.road.median_half_width_m, 1e-6, "full inner shoulder once apart")
	check(right.median_is_rail(f.split_s + 100.0), "the right branch's left side is a rail")
	check(not left.median_is_rail(f.split_s + 100.0), "the left branch keeps its median")
	var far := f.split_s + f.widen_after_m + f.widen_taper_m + 10.0
	eq(left.lane_count(far), left.biome_rules.lanes_for_leg(f.checkpoint + 1), "left widens to its biome's lanes")
	eq(right.lane_count(far), right.biome_rules.lanes_for_leg(f.checkpoint + 1), "right widens to its biome's lanes")


func test_opposite_carriageway_veers_away_and_back() -> void:
	var p := _plan(SEED)
	var left := _paths(p)[0]
	var f := left.forks[0]
	near(left.opposite_offset_d(f.veer_start_s() - 10.0), 0.0, 1e-9, "in place before the veer")
	near(left.opposite_width_frac(f.veer_start_s() - 10.0), 1.0, 1e-9)
	near(left.opposite_width_frac(f.split_s), 0.0, 1e-9, "gone at the split")
	near(left.opposite_offset_d(f.split_s), f.veer_offset_m, 1e-9, "far to the left")
	near(left.opposite_width_frac(f.rejoin_end_s() + 10.0), 1.0, 1e-9, "back after the rejoin")
	near(left.opposite_offset_d(f.rejoin_end_s() + 10.0), 0.0, 1e-9)
	check(left.opposite_lane_center_d(0, f.split_s) < -f.hide_m, "opposite traffic is parked out of sight")


func test_the_main_path_holds_at_an_unresolved_split() -> void:
	var p := _plan(SEED)
	var left := _paths(p)[0]
	var f := left.forks[0]
	left.hold_at_forks = true
	near(left.length_generated(), f.split_s + f.hold_margin_m, 1e-9, "the hold")
	var found: Array[RoadFeature] = []
	left.features_in(0.0, f.split_s + 3000.0, found)
	for x in found:
		check(x.s_start <= f.split_s + f.hold_margin_m, "no feature reported past the hold")
	left.resolve_fork(f.index)
	check(left.length_generated() > f.split_s + 2000.0, "released")


func test_fork_features_signs_and_gantry() -> void:
	var p := _plan(SEED)
	var left := _paths(p)[0]
	var f := left.forks[0]
	var found: Array[RoadFeature] = []
	left.features_in(f.split_s - 1200.0, f.split_s + 10.0, found)
	var fork: RoadFeature = null
	var signs := 0
	var gantry := false
	for x in found:
		if x.kind == RoadFeature.Kind.FORK:
			fork = x
		elif x.kind == RoadFeature.Kind.SIGN and x.tag2 == ProceduralRoadPath.SIGN_FORK_TAG2:
			signs += 1
		elif x.kind == RoadFeature.Kind.CHECKPOINT and absf(x.s_start - f.split_s) < 1e-6:
			gantry = x.tag == BiomeDef.LANDMARK_SIGN_GANTRY
	check(fork != null, "a FORK feature")
	if fork != null:
		eq(fork.tag, f.left_id)
		eq(fork.tag2, f.right_id)
		near(fork.value, f.split_s, 1e-9, "value = the split")
		check(fork.s_start < f.split_s and fork.s_end > f.gore_end_s() - 1e-6, "it spans the whole fork")
	eq(signs, t.legs.checkpoint_warning_distances_m.size(), "fork signs at 1 km and 500 m")
	check(gantry, "the fork checkpoint is a sign gantry over the split")


func test_swapping_state_adopts_the_other_branch() -> void:
	var p := _plan(SEED)
	var ps := _paths(p)
	var left := ps[0]
	var right := ps[1]
	var f := left.forks[0]
	var s := f.split_s + 700.0
	var want := right.sample(s)
	var was := left.sample(s)
	left.swap_state(right)
	var got := left.sample(s)
	near(got.pos_x, want.pos_x, 1e-9, "the main path is now the right branch")
	near(got.pos_z, want.pos_z, 1e-9)
	near(right.sample(s).pos_x, was.pos_x, 1e-9, "and the other holds the left branch")
	eq(left.forks[0].side, ForkPlan.RIGHT)


func test_mesher_builds_both_branches_with_one_gore_ground() -> void:
	var p := _plan(SEED)
	var ps := _paths(p)
	var left := ps[0]
	var right := ps[1]
	var f := left.forks[0]
	var m := RoadChunkMesher.new(t.road)
	for path in ps:
		m.build(path, f.split_s, f.split_s + 200.0)
		check(m.triangle_count() > 0, "a branch chunk")
	var s := f.split_s + 400.0
	var lim := left.ground_right_limit_d(s)
	check(is_finite(lim), "the left branch's ground stops at the right branch")
	check(lim > left.guardrail_d(s), "beyond its own rail")
	var rail_d := right.median_barrier_d(s)
	var a := left.sample(s)
	var b := right.sample(s)
	# The limit point lies on the right branch's rail line (within its heading error).
	var px := a.pos_x + float(a.right.x) * lim
	var pz := a.pos_z + float(a.right.z) * lim
	var qx := b.pos_x + float(b.right.x) * rail_d
	var qz := b.pos_z + float(b.right.z) * rail_d
	var off := (px - qx) * float(b.right.x) + (pz - qz) * float(b.right.z)
	near(off, 0.0, 0.05, "the ground meets the right branch's rail")
	near(right.ground_left_limit_d(s), rail_d, 1e-9, "no ground on the right branch's left")
