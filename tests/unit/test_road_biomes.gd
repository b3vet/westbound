extends WBTest
## ProceduralRoadPath with a biome plan (WP6.4a): per-leg curve / crest frequency,
## lane counts with tapers after the checkpoint, road tunnels (2 lanes inside, the
## taper before the portal), determinism. Spec: World → Road ("3 lanes per direction
## by default. Some biomes use 4; tunnels and road works drop to 2"; radius >= 1,200 m,
## grades <= 5%, occasional blind crests), Biomes (desert: long straights; canyon:
## tunnels, more curves and crests), Architecture rule 2. docs/BIOMES.md.

const SEED := 6400
const EPS := 1e-9

var _t: Tuning
var _rt: RoadTuning
var _leg: float


func before_each() -> void:
	_t = Tuning.load_default()
	_rt = _t.road
	_leg = _t.legs.leg_length_m()


func _biome(id: StringName, lanes: int, curve: float, crest: float, tunnel: float) -> BiomeDef:
	var b := BiomeDef.new()
	b.id = id
	b.lane_count = lanes
	b.curve_frequency_scale = curve
	b.crest_frequency_scale = crest
	b.tunnel_frequency_scale = tunnel
	return b


func _road(seed_value: int, plan: BiomePlan) -> ProceduralRoadPath:
	var r := ProceduralRoadPath.new(RunContext.new(seed_value, RunContext.MODE_JOURNEY, _t))
	if plan != null:
		r.set_biome_plan(plan)
	return r


func _features(r: RoadPath, s0: float, s1: float, kind: int = -1) -> Array[RoadFeature]:
	var all: Array[RoadFeature] = []
	r.features_in(s0, s1, all)
	if kind < 0:
		return all
	var out: Array[RoadFeature] = []
	for f in all:
		if f.kind == kind:
			out.append(f)
	return out


func _trace(r: ProceduralRoadPath, s1: float) -> int:
	var h := TraceHash.SEED
	var smp := RoadSample.new()
	var s := 0.0
	while s <= s1:
		r.sample_into(s, smp)
		for v: float in [smp.pos_x, smp.pos_y, smp.pos_z, smp.heading, smp.curvature, smp.grade]:
			h = TraceHash.mix_float(h, v)
		h = TraceHash.mix_int(h, r.lane_count(s))
		h = TraceHash.mix_float(h, r.guardrail_d(s))
		s += 7.0
	for f in _features(r, 0.0, s1):
		h = TraceHash.mix_int(h, f.kind)
		h = TraceHash.mix_float(h, f.s_start)
		h = TraceHash.mix_float(h, f.s_end)
		h = TraceHash.mix_float(h, f.value)
	return h


## A plan of neutral biomes (scales 1, 3 lanes, no tunnels) leaves the road exactly the
## plain generator's: every existing seeded result stays valid.
func test_neutral_plan_is_bit_identical_to_no_plan() -> void:
	var n := _biome(&"n", _rt.lanes_default, 1.0, 1.0, 0.0)
	var plain := _road(SEED, null)
	var planned := _road(SEED, BiomePlan.uniform(n, _leg))
	var end := _leg * 6.0
	plain.ensure_generated_to(end)
	planned.ensure_generated_to(end)
	eq(_trace(planned, end), _trace(plain, end), "same road")


## set_biome_plan restarts generation: the result does not depend on how far the road
## was generated before it.
func test_set_plan_after_generation_matches_fresh() -> void:
	var plan := BiomePlan.from_tuning(_t.legs)
	var a := _road(SEED, null)
	a.ensure_generated_to(5000.0)
	a.set_biome_plan(plan)
	var b := _road(SEED, BiomePlan.from_tuning(_t.legs))
	var end := _leg * 6.0
	a.ensure_generated_to(end)
	b.ensure_generated_to(end)
	eq(_trace(a, end), _trace(b, end))


## Same seed + same plan = same road, generated in any increments (determinism).
func test_journey_road_is_deterministic_and_order_independent() -> void:
	var end := _leg * 8.0
	var a := _road(SEED, BiomePlan.from_tuning(_t.legs))
	a.ensure_generated_to(end)
	var b := _road(SEED, BiomePlan.from_tuning(_t.legs))
	var s := 0.0
	while s < end:
		s += 777.0
		b.ensure_generated_to(s)
		_features(b, maxf(s - 1500.0, 0.0), s)
	b.ensure_generated_to(end)
	eq(_trace(b, end), _trace(a, end), "stepwise == at once")
	var c := _road(SEED + 1, BiomePlan.from_tuning(_t.legs))
	c.ensure_generated_to(end)
	ne(_trace(c, end), _trace(a, end), "another seed, another road")


## Long straights in the desert, more bends in the canyon; the limits hold everywhere.
func test_curve_and_crest_frequency_scales() -> void:
	var desert := _biome(&"d", 3, 0.45, 0.6, 0.0)
	var canyon := _biome(&"c", 3, 1.8, 1.8, 0.0)
	var km := 120.0
	var end := Units.km_to_m(km)
	var counts := {}
	for b: BiomeDef in [desert, canyon]:
		var r := _road(SEED, BiomePlan.uniform(b, _leg))
		r.ensure_generated_to(end)
		counts[b.id] = [_features(r, 0.0, end, RoadFeature.Kind.BEND).size(),
			_features(r, 0.0, end, RoadFeature.Kind.BLIND_CREST).size()]
		var smp := RoadSample.new()
		var s := 0.0
		var kmax := _rt.max_curvature() * (1.0 + 1e-9)
		while s < end:
			r.sample_into(s, smp)
			if absf(smp.curvature) > kmax or absf(smp.grade) > _rt.max_grade_frac() + 1e-9:
				fail("%s: limits broken at %.0f (k %.6f, grade %.4f)" % [b.id, s, smp.curvature, smp.grade])
				return
			s += 10.0
	var plain := _road(SEED, null)
	plain.ensure_generated_to(end)
	var bends := _features(plain, 0.0, end, RoadFeature.Kind.BEND).size()
	var crests := _features(plain, 0.0, end, RoadFeature.Kind.BLIND_CREST).size()
	print("      bends / blind crests in %d km: desert %s, plain %d / %d, canyon %s" % [km, counts[&"d"],
		bends, crests, counts[&"c"]])
	lt(counts[&"d"][0], bends, "desert: fewer bends (long straights)")
	gt(counts[&"c"][0], bends, "canyon: more bends")
	gt(counts[&"c"][1], crests, "canyon: more blind crests")


## Cliffs lower the bend sight clearance: more BLIND_BENDs on the same bends.
func test_biome_bend_sight_clearance_flags_more_blind_bends() -> void:
	var open := _biome(&"o", 3, 1.8, 1.0, 0.0)
	var walled := _biome(&"w", 3, 1.8, 1.0, 0.0)
	walled.bend_sight_clearance_m = 6.0
	var end := 80000.0
	var a := _road(SEED, BiomePlan.uniform(open, _leg))
	var b := _road(SEED, BiomePlan.uniform(walled, _leg))
	a.ensure_generated_to(end)
	b.ensure_generated_to(end)
	eq(_features(a, 0.0, end, RoadFeature.Kind.BEND).size(), _features(b, 0.0, end, RoadFeature.Kind.BEND).size(),
		"same bends")
	gt(_features(b, 0.0, end, RoadFeature.Kind.BLIND_BEND).size(),
		_features(a, 0.0, end, RoadFeature.Kind.BLIND_BEND).size(), "more blind bends between walls")


## A 4-lane leg after a 3-lane one: the change starts biome_lane_change_after_m past
## the checkpoint and tapers; the edge (and the guardrail) move smoothly.
func test_biome_lane_count_changes_after_the_checkpoint_with_a_taper() -> void:
	var three := _biome(&"three", 3, 1.0, 1.0, 0.0)
	var four := _biome(&"four", 4, 1.0, 1.0, 0.0)
	var legs: Array[BiomeDef] = [three, four, four, three]
	var r := _road(SEED, BiomePlan.new(_leg, legs, three))
	r.ensure_generated_to(_leg * 5.0)
	var changes := _features(r, 0.0, _leg * 5.0, RoadFeature.Kind.LANE_COUNT_CHANGE)
	eq(changes.size(), 2, "3 -> 4 after checkpoint 1, 4 -> 3 after checkpoint 3")
	if changes.size() < 2:
		return
	near(changes[0].s_start, _leg + _rt.biome_lane_change_after_m, EPS)
	near(changes[0].s_end - changes[0].s_start, _rt.biome_lane_taper_m, EPS)
	eq(int(changes[0].value), 4)
	near(changes[1].s_start, 3.0 * _leg + _rt.biome_lane_change_after_m, EPS)
	eq(int(changes[1].value), 3)
	eq(r.lane_count(_leg + 10.0), 3, "the landmark stands on the old cross-section")
	eq(r.lane_count(changes[0].s_end + 1.0), 4)
	var w := _rt.lane_width_m
	var left := r.lanes_left_edge_d(0.0)
	near(r.lanes_right_edge_d(changes[0].s_start), left + 3.0 * w, 1e-6, "taper starts at 3 lanes")
	near(r.lanes_right_edge_d(changes[0].s_end), left + 4.0 * w, 1e-6, "ends at 4")
	near(r.lanes_right_edge_d(0.5 * (changes[0].s_start + changes[0].s_end)), left + 3.5 * w, 1e-6, "half-way")
	var prev := r.guardrail_d(changes[0].s_start - 1.0)
	var s := changes[0].s_start - 1.0
	while s < changes[0].s_end + 1.0:
		s += 0.5
		var g := r.guardrail_d(s)
		le(absf(g - prev), w * 0.5 * 0.5 / _rt.biome_lane_taper_m * 3.0 + 1e-6, "guardrail moves smoothly at %.1f" % s)
		prev = g
	# The mesher draws the same edge.
	var m := RoadChunkMesher.new(_rt)
	for f: float in [0.1, 0.3, 0.5, 0.9]:
		var sf := lerpf(changes[0].s_start, changes[0].s_end, f)
		near(m.lanes_right_edge_at(r, sf), r.lanes_right_edge_d(sf), 1e-6, "mesh edge == road edge at %.0f" % sf)


## Tunnels: only in a biome with tunnel_frequency_scale > 0, inside the leg's window
## (clear of the checkpoint's landmark and warning signs), 300-800 m long, 2 lanes from
## before the portal (taper done tunnel_lane_lead_m earlier) to after the exit, a
## "lane ends" sign before the drop.
func test_tunnels_drop_to_two_lanes_before_the_portal() -> void:
	var farm := _biome(&"farm", 3, 1.0, 1.0, 0.0)
	var canyon := _biome(&"canyon", 3, 1.8, 1.8, 1.6)
	var legs: Array[BiomeDef] = [farm, canyon, canyon, canyon, canyon, canyon, farm]
	var end := _leg * 7.0
	var r := _road(SEED, BiomePlan.new(_leg, legs, farm))
	r.ensure_generated_to(end)
	var tunnels := _features(r, 0.0, end, RoadFeature.Kind.TUNNEL)
	ge(tunnels.size(), 4, "canyon legs have tunnels")
	var max_warning := 0.0
	for wd in _t.legs.checkpoint_warning_distances_m:
		max_warning = maxf(max_warning, wd)
	var signs := _features(r, 0.0, end, RoadFeature.Kind.SIGN)
	for f in tunnels:
		var leg := int(floor(f.s_start / _leg)) + 1
		check(leg >= 2 and leg <= 6, "tunnel at %.0f is in a canyon leg" % f.s_start)
		var len_m := f.s_end - f.s_start
		ge(len_m, _rt.tunnel_length_min_m - EPS)
		le(len_m, _rt.tunnel_length_max_m + EPS)
		near(f.value, len_m, 1e-6, "value = length")
		var s0 := float(leg - 1) * _leg
		ge(f.s_start, s0 + _rt.tunnel_leg_margin_after_m, "clear of the checkpoint behind")
		le(f.s_end, s0 + _leg - max_warning - _rt.tunnel_leg_margin_before_m, "clear of the warning signs ahead")
		var s := f.s_start - _rt.tunnel_lane_lead_m
		while s <= f.s_end + _rt.tunnel_lane_trail_m:
			if r.lane_count(s) != _rt.tunnel_lanes:
				fail("%d lanes at %.0f in the narrowed section" % [r.lane_count(s), s])
				return
			near(r.lanes_right_edge_d(s), r.lanes_left_edge_d(s) + float(_rt.tunnel_lanes) * _rt.lane_width_m, 1e-6)
			s += 5.0
		eq(r.lane_count(f.s_start - _rt.tunnel_lane_lead_m - _rt.lane_taper_length_m - 1.0), 3, "3 lanes before")
		eq(r.lane_count(f.s_end + _rt.tunnel_lane_trail_m + 1.0), 3, "3 lanes after")
		var sign_s := f.s_start - _rt.tunnel_lane_lead_m - _rt.lane_taper_length_m - _rt.lane_ends_sign_distance_m
		var found := false
		for g in signs:
			if g.tag == ProceduralRoadPath.SIGN_LANE_ENDS and absf(g.s_start - sign_s) < 1e-6:
				found = true
		check(found, "lane-ends sign before the tunnel at %.0f" % f.s_start)
	for f in _features(r, 0.0, _leg, RoadFeature.Kind.TUNNEL):
		fail("tunnel in farmland at %.0f" % f.s_start)


func test_no_plan_no_tunnels() -> void:
	var r := _road(SEED, null)
	r.ensure_generated_to(40000.0)
	eq(_features(r, 0.0, 40000.0, RoadFeature.Kind.TUNNEL).size(), 0)
	eq(_features(r, 0.0, 40000.0, RoadFeature.Kind.LANE_COUNT_CHANGE).size(), 0)


## Forgetting behind keeps the lanes and taper in force, and memory bounded.
func test_forget_before_keeps_lanes_and_bounds_memory() -> void:
	var r := _road(SEED, BiomePlan.from_tuning(_t.legs))
	var s := 0.0
	var peak := 0
	var ahead := 2500.0
	while s < 60000.0:
		s += 250.0
		r.ensure_generated_to(s + ahead)
		var lanes := r.lane_count(s + 10.0)
		var edge := r.lanes_right_edge_d(s + 10.0)
		r.forget_before(s - 1000.0)
		eq(r.lane_count(s + 10.0), lanes, "lane count kept at %.0f" % s)
		near(r.lanes_right_edge_d(s + 10.0), edge, 1e-9, "edge kept at %.0f" % s)
		peak = maxi(peak, r.retained_feature_count())
	le(peak, 40, "features bounded")


## Scheduling out of order (set pieces between the biome's own changes) keeps the
## schedule sorted.
func test_schedule_lane_count_in_any_order() -> void:
	var r := _road(SEED, null)
	r.ensure_generated_to(12000.0)
	check(r.schedule_lane_count(9000.0, 4, 100.0))
	check(r.schedule_lane_count(4000.0, 2))
	check(r.schedule_lane_count(6000.0, 3))
	eq(r.lane_count(3999.0), 3)
	eq(r.lane_count(5000.0), 2)
	eq(r.lane_count(7000.0), 3)
	eq(r.lane_count(9500.0), 4)
	var ch := _features(r, 0.0, 12000.0, RoadFeature.Kind.LANE_COUNT_CHANGE)
	eq(ch.size(), 3)
	for i in range(1, ch.size()):
		gt(ch[i].s_start, ch[i - 1].s_start, "sorted")
	check(r.schedule_lane_count(6000.0, 4), "same s replaces")
	eq(r.lane_count(7000.0), 4)
	r.forget_before(8000.0)
	expect_errors(1)
	check(not r.schedule_lane_count(100.0, 2), "behind the retained road")
