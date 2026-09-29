extends WBTest
## ProceduralRoadPath (WP1.1). Spec: World → Road (radius >= 1,200 m, grades <= 5%,
## occasional blind crests), Traffic fairness rule 6, Cameras → Glare rule (sun
## 15-30 deg off the camera axis), Legs and checkpoints, Architecture rules 2 and 7.
## Contract: docs/CONTRACTS.md §2-§3, §9, §12.

const SEED := 20260928
const LONG_KM := 200.0
const EPS := 1e-9

var t: Tuning
var rt: RoadTuning
## One long road shared by the read-only tests (generated once in before_all).
var road: ProceduralRoadPath
var long_m: float


func before_all() -> void:
	t = Tuning.load_default()
	rt = t.road
	long_m = Units.km_to_m(LONG_KM)
	road = _make(SEED)
	road.ensure_generated_to(long_m)


func _make(seed_value: int, tuning: Tuning = null) -> ProceduralRoadPath:
	return ProceduralRoadPath.new(RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning))


func _features(r: RoadPath, s0: float, s1: float) -> Array[RoadFeature]:
	var out: Array[RoadFeature] = []
	r.features_in(s0, s1, out)
	return out


func _of_kind(list: Array[RoadFeature], kind: RoadFeature.Kind) -> Array[RoadFeature]:
	var out: Array[RoadFeature] = []
	for f in list:
		if f.kind == kind:
			out.append(f)
	return out


## Hash of every sample field every `step` m over [s0, s1] plus every feature there.
func _trace(r: ProceduralRoadPath, s0: float, s1: float, step: float) -> int:
	var h := TraceHash.SEED
	var smp := RoadSample.new()
	var s := s0
	while s <= s1:
		r.sample_into(s, smp)
		for v: float in [smp.pos_x, smp.pos_y, smp.pos_z, smp.heading, smp.curvature, smp.elevation, smp.grade]:
			h = TraceHash.mix_float(h, v)
		h = TraceHash.mix_int(h, r.lane_count(s))
		s += step
	for f in _features(r, s0, s1):
		h = TraceHash.mix_int(h, f.kind)
		h = TraceHash.mix_float(h, f.s_start)
		h = TraceHash.mix_float(h, f.s_end)
		h = TraceHash.mix_float(h, f.value)
		h = TraceHash.mix_int(h, Rng.fnv1a32(String(f.tag)))
	return h


# ---------------------------------------------------------------- Tuning

func test_generator_tuning_fields() -> void:
	# The generator's fields exist in data/tuning/road.tres with their documented
	# defaults (none of these are in the spec's table; the spec limits are).
	near(rt.sample_spacing_m, 2.0, EPS)
	near(rt.generation_block_m, 1000.0, EPS)
	eq(rt.generation_block_samples(), 500)
	near(rt.start_straight_m, 1000.0, EPS)
	near(rt.straight_min_m, 300.0, EPS)
	near(rt.straight_max_m, 1500.0, EPS)
	near(rt.curve_radius_max_m, 4000.0, EPS)
	near(rt.curve_deflection_min_deg, 4.0, EPS)
	near(rt.curve_deflection_max_deg, 15.0, EPS)
	near(rt.transition_min_m, 100.0, EPS)
	near(rt.transition_max_m, 250.0, EPS)
	near(rt.sun_side_switch_min_km, 15.0, EPS)
	near(rt.sun_side_switch_max_km, 40.0, EPS)
	near(rt.sun_side_switch_radius_m, 1200.0, EPS)
	near(rt.grade_typical_pct, 3.0, EPS)
	near(rt.grade_length_min_m, 200.0, EPS)
	near(rt.grade_length_max_m, 1000.0, EPS)
	near(rt.vertical_radius_min_m, 20000.0, EPS)
	near(rt.vertical_radius_max_m, 60000.0, EPS)
	near(rt.elevation_soft_limit_m, 40.0, EPS)
	near(rt.crest_chance_frac, 0.3, EPS)
	near(rt.crest_grade_min_pct, 3.0, EPS)
	near(rt.crest_vertical_radius_min_m, 3000.0, EPS)
	near(rt.crest_vertical_radius_max_m, 6000.0, EPS)
	near(rt.sight_eye_height_m, 1.1, EPS)
	near(rt.sight_object_height_m, 0.5, EPS)
	near(rt.blind_sight_distance_m, 250.0, EPS)
	near(rt.bend_sight_clearance_m, 15.0, EPS)
	near(rt.sharp_bend_radius_m, 1300.0, EPS)
	near(rt.hazard_sign_distance_m, 300.0, EPS)
	near(rt.lane_taper_length_m, 200.0, EPS)


func test_generator_tuning_is_consistent() -> void:
	# Relations the generator relies on.
	near(rt.generation_block_m / rt.sample_spacing_m, float(rt.generation_block_samples()), EPS,
		"block is a whole number of samples")
	ge(rt.curve_radius_max_m, rt.min_curve_radius_m)
	ge(rt.sun_side_switch_radius_m, rt.min_curve_radius_m)
	ge(rt.sun_offset_max_deg - rt.sun_offset_min_deg, 2.0 * rt.curve_deflection_min_deg,
		"a bend always fits in the sun band")
	lt(rt.sun_offset_min_deg + rad_to_deg(rt.transition_max_m / (2.0 * rt.sun_side_switch_radius_m)),
		rt.sun_offset_max_deg, "a side switch's transitions fit in the band")
	le(rt.grade_typical_pct, rt.max_grade_pct)
	le(rt.crest_grade_min_pct, rt.max_grade_pct)
	# Normal vertical curves are never blind; deliberate crests always are (S <= L case).
	var c := pow(sqrt(rt.sight_eye_height_m) + sqrt(rt.sight_object_height_m), 2.0)
	ge(2.0 * c * rt.vertical_radius_min_m, pow(rt.blind_sight_distance_m, 2.0), "normal curves see far enough")
	lt(2.0 * c * rt.crest_vertical_radius_max_m, pow(rt.blind_sight_distance_m, 2.0), "crests are blind")


# ---------------------------------------------------------------- Determinism

func test_same_seed_same_road() -> void:
	var a := _make(777)
	var b := _make(777)
	a.ensure_generated_to(20000.0)
	b.ensure_generated_to(20000.0)
	eq(_trace(a, 0.0, 20000.0, 7.3), _trace(b, 0.0, 20000.0, 7.3))


func test_same_seed_matches_shared_road() -> void:
	var other := _make(SEED)
	other.ensure_generated_to(20000.0)
	eq(_trace(other, 0.0, 20000.0, 11.0), _trace(road, 0.0, 20000.0, 11.0))


func test_different_seeds_differ() -> void:
	var a := _make(1)
	var b := _make(2)
	a.ensure_generated_to(10000.0)
	b.ensure_generated_to(10000.0)
	ne(_trace(a, 0.0, 10000.0, 7.3), _trace(b, 0.0, 10000.0, 7.3))
	# The road stream is used, not the other streams: a context whose other streams
	# were drawn from first still gives the same road.
	var ctx := RunContext.new(1)
	for i in 10:
		ctx.rng_traffic.unit()
		ctx.rng_road.unit()
	var c := ProceduralRoadPath.new(ctx)
	c.ensure_generated_to(10000.0)
	eq(_trace(c, 0.0, 10000.0, 7.3), _trace(a, 0.0, 10000.0, 7.3))


func test_generation_order_independent() -> void:
	var end_m := 50000.0
	var one_call := _make(4242)
	one_call.ensure_generated_to(end_m)
	var small_steps := _make(4242)
	var forgetful := _make(4242)
	var s := 0.0
	var i := 0
	while s < end_m:
		s = minf(s + 123.4, end_m)
		small_steps.ensure_generated_to(s)
		forgetful.ensure_generated_to(s + 777.0)
		forgetful.forget_before(s - 5000.0)
		if i % 7 == 0:
			_features(small_steps, s, s + 3000.0)   # extends the element streams ahead
		i += 1
	eq(_trace(small_steps, 0.0, end_m, 7.3), _trace(one_call, 0.0, end_m, 7.3), "increments")
	var tail := forgetful.first_retained_s()
	gt(tail, 0.0, "the forgetful road dropped its start")
	eq(_trace(forgetful, tail, end_m, 7.3), _trace(one_call, tail, end_m, 7.3), "after forgetting")


# ---------------------------------------------------------------- Geometry bounds and continuity

func test_bounds_and_continuity_200km() -> void:
	var kmax := rt.max_curvature()
	var gmax := rt.max_grade_frac()
	var step := 1.3   # not a divisor of the grid: hits every phase between samples
	var dk_max := kmax / rt.transition_min_m * step * (1.0 + 1e-6)
	var dg_max := step / minf(rt.crest_vertical_radius_min_m, rt.vertical_radius_min_m) * (1.0 + 1e-6)
	var a := RoadSample.new()
	var b := RoadSample.new()
	road.sample_into(0.0, a)
	var worst := {"k": 0.0, "g": 0.0, "dk": 0.0, "dg": 0.0, "dh": 0.0, "dp": 0.0, "de": 0.0}
	var s := step
	while s <= long_m:
		road.sample_into(s, b)
		worst.k = maxf(worst.k, absf(b.curvature))
		worst.g = maxf(worst.g, absf(b.grade))
		worst.dk = maxf(worst.dk, absf(b.curvature - a.curvature))
		worst.dg = maxf(worst.dg, absf(b.grade - a.grade))
		# Heading changes by the integral of curvature (C1: no kink in the tangent).
		worst.dh = maxf(worst.dh, absf(b.heading - a.heading - step * (a.curvature + b.curvature) * 0.5))
		# Plan position moves `step` along the mean heading (no jump, s is plan arc length).
		var hm := (a.heading + b.heading) * 0.5
		worst.dp = maxf(worst.dp, Vector2(b.pos_x - a.pos_x - step * sin(hm), b.pos_z - a.pos_z + step * cos(hm)).length())
		worst.de = maxf(worst.de, absf(b.elevation - a.elevation - step * (a.grade + b.grade) * 0.5))
		var tmp := a
		a = b
		b = tmp
		s += step
	print("      200 km: min radius %.0f m, max |grade| %.4f, max dk %s, max dg %s, heading err %s, pos err %s m, elev err %s m" % [
		1.0 / worst.k, worst.g, worst.dk, worst.dg, worst.dh, worst.dp, worst.de])
	le(worst.k, kmax * (1.0 + 1e-9), "radius >= min_curve_radius_m")
	gt(worst.k, kmax * 0.99, "the tightest legal radius is used somewhere")
	le(worst.g, gmax + 1e-12, "grade <= max_grade_pct")
	gt(worst.g, gmax * 0.9, "steep grades exist (crests)")
	le(worst.dk, dk_max, "curvature is continuous (clothoid transitions)")
	le(worst.dg, dg_max, "grade is continuous (vertical curves)")
	# Heading and elevation integrate curvature and grade up to the interpolation
	# error at element joints inside a grid cell (~1e-5 rad, ~1e-4 m): no kinks, no jumps.
	le(worst.dh, 5e-5, "heading is C1 with the curvature")
	le(worst.dp, 1e-3, "positions follow the heading")
	le(worst.de, 1e-3, "elevation follows the grade")


func test_continuity_at_block_and_grid_boundaries() -> void:
	var a := RoadSample.new()
	var b := RoadSample.new()
	var d := 1e-6
	for s: float in [2.0, 998.0, 1000.0, 2000.0, 13000.0, 57002.0, 99000.0, 150000.0]:
		road.sample_into(s - d, a)
		road.sample_into(s + d, b)
		near(b.pos_x, a.pos_x, 1e-5, "x at %s" % s)
		near(b.pos_y, a.pos_y, 1e-5, "y at %s" % s)
		near(b.pos_z, a.pos_z, 1e-5, "z at %s" % s)
		near(b.heading, a.heading, 1e-8, "heading at %s" % s)
		near(b.curvature, a.curvature, 1e-9, "curvature at %s" % s)
		near(b.grade, a.grade, 1e-8, "grade at %s" % s)
		check(b.tangent.is_equal_approx(a.tangent), "tangent at %s" % s)


func test_run_starts_at_origin_on_a_straight() -> void:
	var smp := road.sample(0.0)
	near(smp.pos_x, 0.0, EPS)
	near(smp.pos_y, 0.0, EPS)
	near(smp.pos_z, 0.0, EPS)
	var s := 0.0
	while s < rt.start_straight_m:
		near(road.curvature_at(s), 0.0, EPS, "start straight at %s" % s)
		near(road.grade_at(s), 0.0, EPS, "start is flat at %s" % s)
		s += 10.0


func test_frame_is_orthonormal_and_matches_heading() -> void:
	var smp := RoadSample.new()
	var s := 0.0
	while s < 30000.0:
		road.sample_into(s, smp)
		near(smp.tangent.length(), 1.0, 1e-5)
		near(smp.right.length(), 1.0, 1e-5)
		near(smp.tangent.dot(smp.right), 0.0, 1e-5)
		near(smp.up.dot(smp.tangent), 0.0, 1e-5)
		gt(smp.up.y, 0.99, "up points up")
		near(smp.heading, road.heading_at(s), EPS)
		near(smp.elevation, road.elevation_at(s), EPS)
		near(smp.grade, road.grade_at(s), EPS)
		near(smp.curvature, road.curvature_at(s), EPS)
		s += 97.0


# ---------------------------------------------------------------- Sun band

## Returns {outside_frac, max_zone_run_m, max_abs_deg, switches} over [0, len_m] on the grid.
func _sun_stats(r: ProceduralRoadPath, len_m: float) -> Dictionary:
	var lo := deg_to_rad(rt.sun_offset_min_deg)
	var hi := deg_to_rad(rt.sun_offset_max_deg)
	var step := rt.sample_spacing_m
	var outside := 0.0
	var run := 0.0
	var max_run := 0.0
	var max_abs := 0.0
	var switches := 0
	var prev_sign := signf(r.heading_at(0.0))
	var s := 0.0
	while s < len_m:
		var h := r.heading_at(s)
		max_abs = maxf(max_abs, absf(h))
		if absf(h) < lo - EPS or absf(h) > hi + EPS:
			outside += step
		if absf(h) < lo - EPS:
			run += step
			max_run = maxf(max_run, run)
		else:
			run = 0.0
		if signf(h) != prev_sign and h != 0.0:
			switches += 1
			prev_sign = signf(h)
		s += step
	return {"outside_frac": outside / len_m, "max_zone_run_m": max_run, "max_abs_deg": rad_to_deg(max_abs),
		"switches": switches}


func test_sun_band() -> void:
	# The sun sits at world heading 0: the road heading stays 15-30 deg off it,
	# except while switching sides through one arc at sun_side_switch_radius_m.
	var st := _sun_stats(road, long_m)
	var zone_len := 2.0 * deg_to_rad(rt.sun_offset_min_deg) * rt.sun_side_switch_radius_m
	print("      sun band over %d km: %.2f%% of distance outside 15-30 deg, longest inside +-15 deg %.0f m (rule %.0f m), %d side switches, max |heading| %.2f deg" % [
		LONG_KM, st.outside_frac * 100.0, st.max_zone_run_m, zone_len, st.switches, st.max_abs_deg])
	le(st.max_abs_deg, rt.sun_offset_max_deg + 1e-6, "never more than 30 deg off")
	le(st.max_zone_run_m, zone_len + 2.0 * rt.sample_spacing_m, "each crossing of the zone is one switch arc")
	# Bound: at most one switch per sun_side_switch_min_km, zone_len each.
	le(st.outside_frac, zone_len / Units.km_to_m(rt.sun_side_switch_min_km) + 0.001, "outside-band fraction")
	le(st.outside_frac, 0.05, "outside-band fraction <= 5%")
	ge(st.switches, int(LONG_KM / rt.sun_side_switch_max_km) - 1, "the sun changes sides now and then")
	le(st.switches, int(LONG_KM / rt.sun_side_switch_min_km) + 1, "but rarely")


func test_sun_band_other_seeds() -> void:
	for sd: int in [3, 99, 123456789]:
		var r := _make(sd)
		r.ensure_generated_to(60000.0)
		var st := _sun_stats(r, 60000.0)
		le(st.max_abs_deg, rt.sun_offset_max_deg + 1e-6, "seed %d max offset" % sd)
		le(st.max_zone_run_m, 2.0 * deg_to_rad(rt.sun_offset_min_deg) * rt.sun_side_switch_radius_m
			+ 2.0 * rt.sample_spacing_m, "seed %d zone run" % sd)
		le(st.outside_frac, 0.05, "seed %d outside fraction" % sd)


# ---------------------------------------------------------------- Bends

func test_bend_features() -> void:
	var feats := _features(road, 0.0, long_m)
	var bends := _of_kind(feats, RoadFeature.Kind.BEND)
	gt(bends.size(), int(LONG_KM / 3.0), "a bend every few km at most")
	lt(bends.size(), int(LONG_KM), "mostly straights and sweepers")
	var signs := _of_kind(feats, RoadFeature.Kind.SIGN)
	var sharp := 0
	var prev_end := 0.0
	for f in bends:
		ge(f.s_start, prev_end - EPS, "bends do not overlap")
		prev_end = f.s_end
		le(absf(f.value), rt.max_curvature() * (1.0 + 1e-9), "bend radius >= 1200 m")
		ge(f.s_end - f.s_start, 2.0 * rt.transition_min_m - EPS, "two transitions of at least transition_min_m")
		# value = apex curvature: the peak |curvature| inside the bend, same sign.
		var peak := 0.0
		var s := f.s_start
		while s <= f.s_end:
			var k := road.curvature_at(s)
			if absf(k) > absf(peak):
				peak = k
			check(k * f.value >= 0.0, "bend curvature keeps its sign")
			s += rt.sample_spacing_m
		within_pct(peak, f.value, 0.02, "apex curvature at %s" % f.s_start)
		if absf(f.value) >= 1.0 / rt.sharp_bend_radius_m - EPS:
			sharp += 1
			var found := false
			for g in signs:
				if g.tag == ProceduralRoadPath.SIGN_BEND and absf(g.s_start - (f.s_start - rt.hazard_sign_distance_m)) < EPS:
					found = true
					near(g.value, rt.hazard_sign_distance_m, EPS)
			check(found, "sharp bend at %s has a warning sign" % f.s_start)
	gt(sharp, 0, "some bends are sharp enough to be signed")
	# Straights between bends are straight (away from the transitions' grid cells).
	for i in range(1, bends.size()):
		var s := bends[i - 1].s_end + 2.0 * rt.sample_spacing_m
		while s < bends[i].s_start - 2.0 * rt.sample_spacing_m:
			near(road.curvature_at(s), 0.0, EPS, "straight at %s" % s)
			s += 25.0
	eq(_of_kind(feats, RoadFeature.Kind.BLIND_BEND).size(), 0, "farmland bends are never blind")


func test_blind_bend_hook() -> void:
	# With a close sight obstruction (clearance m) a bend of radius R is blind when
	# sqrt(8 R m) < blind_sight_distance_m: the hook fires for exactly those bends.
	var tuned: Tuning = Tuning.load_default().duplicate(true)
	# duplicate(true) keeps external sub-resources (data/tuning/road.tres) shared: copy it,
	# or every later test sees blind bends (WP6.2).
	tuned.road = tuned.road.duplicate() as RoadTuning
	tuned.road.bend_sight_clearance_m = 1.0
	var r := _make(SEED, tuned)
	r.ensure_generated_to(20000.0)
	var feats := _features(r, 0.0, 20000.0)
	var expected: Array[RoadFeature] = []
	for f in _of_kind(feats, RoadFeature.Kind.BEND):
		if 8.0 * tuned.road.bend_sight_clearance_m / absf(f.value) < pow(rt.blind_sight_distance_m, 2.0):
			expected.append(f)
	var blind := _of_kind(feats, RoadFeature.Kind.BLIND_BEND)
	gt(expected.size(), 0)
	eq(blind.size(), expected.size())
	for i in mini(blind.size(), expected.size()):
		near(blind[i].s_start, expected[i].s_start, EPS)
		near(blind[i].s_end, expected[i].s_end, EPS)
		lt(blind[i].value, rt.blind_sight_distance_m, "value = sight distance")
		near(blind[i].value, sqrt(8.0 * tuned.road.bend_sight_clearance_m / absf(expected[i].value)), 1e-6)


# ---------------------------------------------------------------- Blind crests

## Distance to the nearest point ahead of the eye at `eye_s` where an object
## sight_object_height_m tall is hidden by the road surface, sampled every `step`
## (INF if visible up to max_d). Independent of the analytic rule.
func _numeric_sight(r: ProceduralRoadPath, eye_s: float, max_d: float, step: float) -> float:
	var eye_y := r.elevation_at(eye_s) + rt.sight_eye_height_m
	var horizon := -INF   # steepest slope from the eye to the road surface so far
	var d := step
	while d <= max_d:
		var y := r.elevation_at(eye_s + d)
		if (y + rt.sight_object_height_m - eye_y) / d < horizon:
			return d
		horizon = maxf(horizon, (y - eye_y) / d)
		d += step
	return INF


func test_blind_crests_flagged_and_real() -> void:
	var feats := _features(road, 0.0, long_m)
	var crests := _of_kind(feats, RoadFeature.Kind.BLIND_CREST)
	var signs := _of_kind(feats, RoadFeature.Kind.SIGN)
	var sight := rt.blind_sight_distance_m
	print("      %d blind crests in %d km (one per %.1f km)" % [crests.size(), LONG_KM, LONG_KM / maxf(crests.size(), 1.0)])
	ge(crests.size(), int(LONG_KM / 10.0), "occasional blind crests: at least one per 10 km")
	le(crests.size(), int(LONG_KM / 2.0), "but not more than one per 2 km")
	for f in crests:
		lt(f.value, sight, "flagged sight distance under the threshold")
		# The crest is a convex vertical curve: grade falls from + to -.
		gt(road.grade_at(f.s_start + EPS), 0.0, "climbs into the crest")
		lt(road.grade_at(f.s_end - EPS), 0.0, "descends out of it")
		# Numerically: an eye somewhere before the top cannot see an object within the threshold.
		var worst := INF
		var eye := maxf(0.0, f.s_start - sight)
		while eye <= f.s_end:
			worst = minf(worst, _numeric_sight(road, eye, sight * 1.5, rt.sample_spacing_m))
			eye += 5.0
		lt(worst, sight, "crest at %.0f really hides traffic (numeric %.0f m)" % [f.s_start, worst])
		within_pct(worst, f.value, 0.1, "numeric sight matches the rule at %.0f" % f.s_start)
		var signed := false
		for g in signs:
			if g.tag == ProceduralRoadPath.SIGN_CREST and absf(g.s_start - (f.s_start - rt.hazard_sign_distance_m)) < EPS:
				signed = true
		check(signed or f.s_start < rt.hazard_sign_distance_m, "crest at %.0f has a warning sign" % f.s_start)


func test_no_unflagged_blind_crests() -> void:
	# Scan eyes every 10 m over 60 km: wherever an object within the threshold is
	# hidden, a flagged crest is right there.
	var scan_m := 60000.0
	var sight := rt.blind_sight_distance_m
	var crests := _of_kind(_features(road, 0.0, scan_m + sight), RoadFeature.Kind.BLIND_CREST)
	var hidden := 0
	var eye := 0.0
	while eye < scan_m:
		var d := _numeric_sight(road, eye, sight * 0.97, rt.sample_spacing_m)
		if d < INF:
			hidden += 1
			var near_crest := false
			for f in crests:
				if eye >= f.s_start - sight and eye <= f.s_end + sight:
					near_crest = true
					break
			check(near_crest, "hidden object %.0f m ahead of %.0f with no BLIND_CREST flagged" % [d, eye])
		eye += 10.0
	gt(hidden, 0, "the scan does find the flagged crests")


# ---------------------------------------------------------------- Legs

func test_checkpoints_and_warning_signs() -> void:
	var leg := t.legs.leg_length_m()
	var legs := 12
	var feats := _features(road, 0.0, leg * legs + 1.0)
	var cps := _of_kind(feats, RoadFeature.Kind.CHECKPOINT)
	eq(cps.size(), legs)
	for i in cps.size():
		near(cps[i].s_start, leg * (i + 1), EPS, "checkpoint %d at the leg end" % (i + 1))
		near(cps[i].s_end, cps[i].s_start, EPS)
		eq(int(cps[i].value), i + 1, "value = leg index, 1-based")
	var cp_signs: Array[RoadFeature] = []
	for f in _of_kind(feats, RoadFeature.Kind.SIGN):
		if f.tag == ProceduralRoadPath.SIGN_CHECKPOINT:
			cp_signs.append(f)
	eq(cp_signs.size(), legs * t.legs.checkpoint_warning_distances_m.size())
	for k in range(1, legs + 1):
		for w in t.legs.checkpoint_warning_distances_m:
			var found := false
			for f in cp_signs:
				if absf(f.s_start - (leg * k - w)) < EPS:
					found = true
					near(f.value, w, EPS, "announces the distance")
			check(found, "sign %s m before checkpoint %d" % [w, k])
	# 1000 m and 500 m (the spec's warning distances).
	eq(t.legs.checkpoint_warning_distances_m, PackedFloat64Array([1000.0, 500.0]))


func test_features_sorted_and_windowed() -> void:
	var s0 := 12345.0
	var s1 := 31000.0
	var feats := _features(road, s0, s1)
	gt(feats.size(), 0)
	for i in feats.size():
		check(feats[i].overlaps(s0, s1), "feature %d overlaps the window" % i)
		if i > 0:
			ge(feats[i].s_start, feats[i - 1].s_start, "sorted by s_start")
	# Windows partition: [a, b) + [b, c) = [a, c) for point features.
	var left := _features(road, s0, 20000.0)
	var right := _features(road, 20000.0, s1)
	var points := 0
	for f in feats:
		if f.s_end == f.s_start:
			points += 1
	var split_points := 0
	for f: RoadFeature in left + right:
		if f.s_end == f.s_start:
			split_points += 1
	eq(split_points, points, "point features are counted once across windows")
	# Nothing beyond the generated range.
	var fresh := _make(SEED)
	for f in _features(fresh, 0.0, INF):
		lt(f.s_start, fresh.length_generated())


# ---------------------------------------------------------------- Sampling

func test_sample_into_matches_sample_and_reuses_out() -> void:
	var out := RoadSample.new()
	var id := out.get_instance_id()
	for s: float in [0.0, 1.0, 999.9, 4321.5, 77777.7, long_m]:
		road.sample_into(s, out)
		var fresh := road.sample(s)
		eq(out.get_instance_id(), id)
		near(out.s, s, EPS)
		eq(out.pos_x, fresh.pos_x)
		eq(out.pos_y, fresh.pos_y)
		eq(out.pos_z, fresh.pos_z)
		eq(out.heading, fresh.heading)
		eq(out.curvature, fresh.curvature)
		eq(out.grade, fresh.grade)
		eq(out.tangent, fresh.tangent)
		eq(out.up, fresh.up)
		near(out.elevation, out.pos_y, EPS)


func test_sample_into_allocates_nothing() -> void:
	var out := RoadSample.new()
	road.sample_into(10.0, out)
	var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
	var s := 0.0
	for i in 2000:
		road.sample_into(s, out)
		road.curvature_at(s)
		road.lane_count(s)
		road.lane_center_d(1, s)
		s += 51.7
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects_before)


var _bench_out := RoadSample.new()
var _bench_s := 0.0


func _bench_batch() -> void:
	for i in 100:
		_bench_s += 173.3
		if _bench_s > long_m:
			_bench_s -= long_m
		road.sample_into(_bench_s, _bench_out)


func test_sample_into_budget() -> void:
	var usec := WBBench.usec_per_call(_bench_batch, 20) / 100.0
	WBBench.report("ProceduralRoadPath.sample_into", usec, 15.0)
	le(usec, WBBench.budget(15.0), "sample_into usec per call")


# ---------------------------------------------------------------- Lanes

func test_lane_queries_follow_the_contract() -> void:
	var left := rt.median_half_width_m + rt.inner_shoulder_m
	for s: float in [0.0, 5000.0, 123456.0]:
		eq(road.lane_count(s), rt.lanes_default)
		for i in rt.lanes_default:
			var expected := left + (i + 0.5) * rt.lane_width_m
			near(road.lane_center_d(i, s), expected, EPS)
			near(road.lane_center_d(i, s), rt.lane_center_d(i), EPS)
			near(road.opposite_lane_center_d(i, s), -expected, EPS)
			eq(road.lane_index_at(expected, s), i)
		near(road.lanes_right_edge_d(s), left + rt.lanes_default * rt.lane_width_m, EPS)
		near(road.guardrail_d(s), left + rt.lanes_default * rt.lane_width_m + rt.shoulder_m + rt.guardrail_offset_m, EPS)
		check(road.is_on_shoulder(left - 0.1, s))
		eq(road.lane_index_at(road.lanes_right_edge_d(s) + 0.1, s), -1)


func test_lane_count_schedule() -> void:
	var r := _make(5)
	r.ensure_generated_to(12000.0)
	check(r.schedule_lane_count(4000.0, 2))
	check(r.schedule_lane_count(9000.0, 4, 150.0))
	eq(r.lane_count(3999.0), rt.lanes_default)
	eq(r.lane_count(4000.0), 2)
	eq(r.lane_count(8999.0), 2)
	eq(r.lane_count(9000.0), 4)
	near(r.lanes_right_edge_d(5000.0), rt.lane_center_d(0) - 0.5 * rt.lane_width_m + 2.0 * rt.lane_width_m, EPS)
	var changes := _of_kind(_features(r, 0.0, 12000.0), RoadFeature.Kind.LANE_COUNT_CHANGE)
	eq(changes.size(), 2)
	near(changes[0].s_start, 4000.0, EPS)
	near(changes[0].s_end, 4000.0 + rt.lane_taper_length_m, EPS)
	eq(int(changes[0].value), 2)
	near(changes[1].s_end, 9150.0, EPS)
	eq(int(changes[1].value), 4)
	# Counts outside the tuning range are clamped.
	check(r.schedule_lane_count(11000.0, 9))
	eq(r.lane_count(11500.0), rt.lanes_max)
	# The count in force survives forgetting the change point.
	r.forget_before(10000.0)
	eq(r.lane_count(10500.0), 4)


# ---------------------------------------------------------------- Endless generation and memory

func test_forget_before_keeps_memory_bounded() -> void:
	var r := _make(31337)
	var ahead := 3000.0
	var behind := 1000.0
	var peak_samples := 0
	var peak_elements := 0
	var peak_features := 0
	var s := 0.0
	while s < 100000.0:
		s += 250.0
		r.ensure_generated_to(s + ahead)
		r.forget_before(s - behind)
		_features(r, s, s + ahead)
		peak_samples = maxi(peak_samples, r.retained_sample_count())
		peak_elements = maxi(peak_elements, r.retained_element_count())
		peak_features = maxi(peak_features, r.retained_feature_count())
	var block := rt.generation_block_m
	le(peak_samples, int((ahead + behind + 2.0 * block) / rt.sample_spacing_m) + 1, "table bounded")
	le(peak_elements, 60, "elements bounded")
	le(peak_features, 30, "features bounded")
	var smp := r.sample(s - behind)
	finite(smp.pos_x)
	ge(r.first_retained_s(), s - behind - block - EPS)
	le(r.first_retained_s(), s - behind + EPS)


func soak_10000km_with_forgetting() -> void:
	# The director's pattern for 10,000 km: generate ahead, forget behind, and the
	# road stays inside the limits all the way.
	var r := _make(8675309)
	var kmax := rt.max_curvature() * (1.0 + 1e-9)
	var gmax := rt.max_grade_frac() + 1e-12
	var hi := deg_to_rad(rt.sun_offset_max_deg) + 1e-9
	var ahead := 3000.0
	var step := 7.1
	var smp := RoadSample.new()
	var s := 0.0
	var checked := 0.0
	var bad := 0
	var peak_samples := 0
	var crests := 0
	var total := Units.km_to_m(10000.0)
	while s < total:
		s += 1000.0
		r.ensure_generated_to(s + ahead)
		r.forget_before(s - 500.0)
		peak_samples = maxi(peak_samples, r.retained_sample_count())
		crests += _of_kind(_features(r, s - 1000.0, s), RoadFeature.Kind.BLIND_CREST).filter(
			func(f: RoadFeature) -> bool: return f.s_start >= s - 1000.0).size()
		while checked < s:
			r.sample_into(checked, smp)
			if absf(smp.curvature) > kmax or absf(smp.grade) > gmax or absf(smp.heading) > hi \
					or not is_finite(smp.pos_x) or not is_finite(smp.pos_z):
				bad += 1
			checked += step
	eq(bad, 0, "samples outside the limits over 10,000 km")
	le(peak_samples, int((ahead + 500.0 + 2.0 * rt.generation_block_m) / rt.sample_spacing_m) + 1)
	print("      10,000 km: %d blind crests (one per %.1f km), peak table %d samples, end at x %.0f z %.0f elev %.1f" % [
		crests, 10000.0 / maxf(crests, 1.0), peak_samples, smp.pos_x, smp.pos_z, smp.elevation])


func soak_sun_band_and_crests_many_seeds() -> void:
	for sd: int in range(1, 11):
		var r := _make(sd * 7919)
		r.ensure_generated_to(500000.0)
		var st := _sun_stats(r, 500000.0)
		var crests := _of_kind(_features(r, 0.0, 500000.0), RoadFeature.Kind.BLIND_CREST).size()
		print("      seed %d: outside band %.2f%%, zone run %.0f m, %d switches, crest every %.1f km" % [
			sd * 7919, st.outside_frac * 100.0, st.max_zone_run_m, st.switches, 500.0 / maxf(crests, 1.0)])
		le(st.outside_frac, 0.05)
		le(st.max_abs_deg, rt.sun_offset_max_deg + 1e-6)
		le(st.max_zone_run_m, 2.0 * deg_to_rad(rt.sun_offset_min_deg) * rt.sun_side_switch_radius_m
			+ 2.0 * rt.sample_spacing_m)
