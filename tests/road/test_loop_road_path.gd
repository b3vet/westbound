extends WBTest
## LoopRoadPath, LoopGen and LoopValidator (N3.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
## → The loop map (about 25 km in 5 sections of about 5 km; lanes 3 / 4 in the desert and
## city / 2 in one canyon tunnel; two tunnels; the coast's bridge; two ramp pairs; road
## works; 6 sector gantries; s wraps modulo L); World → Road (radius >= 1,200 m, grades
## <= 5 %); docs/MULTIPLAYER_PLAN.md MP-D3. docs/LOOP_MAP.md.

const EPS := 1e-9
## Ids of the handoff's sections, in driving order.
const SECTIONS: Array[StringName] = [&"desert", &"canyon", &"coast", &"city", &"farmland"]

var t: Tuning
var rt: RoadTuning
## The committed loop, shared by the read-only tests.
var road: LoopRoadPath
var L: float


func before_all() -> void:
	t = Tuning.load_default()
	rt = t.road
	road = LoopRoadPath.load_default(t)
	L = road.length()


func _def() -> LoopMapDef:
	return LoopMapDef.load_default().duplicate(true) as LoopMapDef


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


# ---------------------------------------------------------------- Validity

func test_loop_v1_is_valid() -> void:
	var errors := LoopValidator.validate(road, t)
	eq(errors.size(), 0, "\n".join(errors))
	eq(road.layout.issues.size(), 0, "\n".join(road.layout.issues))


func test_sections_and_lengths() -> void:
	ge(L, 24000.0, "loop at least 24 km")
	le(L, 26000.0, "loop at most 26 km")
	eq(road.section_count(), SECTIONS.size(), "five sections")
	for j in road.section_count():
		eq(road.section_id(j), SECTIONS[j], "section %d in driving order" % j)
		within_pct(road.layout.section_length_m, 5000.0, 0.1, "section %d within 10 %% of 5 km" % j)
		eq(road.section_at(road.section_start(j) + 1.0), j)
	var plan := road.biome_plan(2)
	for s: float in [10.0, 6000.0, 12000.0, 18000.0, 24000.0, L + 100.0, L + 12500.0]:
		eq(plan.biome_at(s).id, road.section_id(road.section_at(s)), "biome plan follows the sections at %s" % s)


# ---------------------------------------------------------------- Closure

func test_loop_closes() -> void:
	var o := road.layout
	lt(o.closure_residual_m, 0.001, "position closes within 1 mm before the spread")
	lt(o.closure_heading_error, 1e-6, "heading closes")
	lt(o.closure_elevation_error, 0.001, "elevation closes")
	lt(o.closure_grade_error, 1e-9, "grade closes")
	near(o.total_turn, -TAU, 0.0, "one full turn (left: counterclockwise)")
	var sum := 0.0
	for dh in o.bend_dh:
		sum += dh
	near(sum, o.total_turn, 1e-12, "the bends turn exactly one lap")
	near(road.heading_at(L) - road.heading_at(0.0), -TAU, 1e-12, "heading over one lap")
	eq(o.k[0], 0.0, "the seam is on a straight")


func test_continuity_across_the_seam() -> void:
	var a := RoadSample.new()
	var b := RoadSample.new()
	var d := 1e-6
	for k: int in [-1, 0, 1, 2]:
		var s := float(k) * L
		road.sample_into(s - d, a)
		road.sample_into(s + d, b)
		near(b.pos_x, a.pos_x, 1e-5, "x at %s" % s)
		near(b.pos_y, a.pos_y, 1e-5, "y at %s" % s)
		near(b.pos_z, a.pos_z, 1e-5, "z at %s" % s)
		near(b.heading, a.heading, 1e-8, "heading at %s" % s)
		near(b.curvature, a.curvature, 1e-9, "curvature at %s" % s)
		near(b.grade, a.grade, 1e-8, "grade at %s" % s)
		check(b.tangent.is_equal_approx(a.tangent), "tangent at %s" % s)
	road.sample_into(0.0, a)
	road.sample_into(L, b)
	near(b.pos_x, a.pos_x, EPS, "s = L is s = 0 (x)")
	near(b.pos_z, a.pos_z, EPS, "s = L is s = 0 (z)")
	near(b.elevation, a.elevation, EPS, "s = L is s = 0 (elevation)")


func test_every_lap_is_the_same_ground() -> void:
	var a := RoadSample.new()
	var b := RoadSample.new()
	for s: float in [0.0, 123.4, 5000.0, 9876.5, 12500.0, 20001.0, L - 0.5]:
		road.sample_into(s, a)
		for k: int in [-2, -1, 1, 3]:
			road.sample_into(s + float(k) * L, b)
			near(b.pos_x, a.pos_x, 1e-6, "x at %s lap %d" % [s, k])
			near(b.pos_z, a.pos_z, 1e-6, "z at %s lap %d" % [s, k])
			near(b.elevation, a.elevation, 1e-6, "elevation at %s lap %d" % [s, k])
			near(b.heading - a.heading, float(k) * road.layout.total_turn, 1e-6, "heading at %s lap %d" % [s, k])
			near(b.curvature, a.curvature, 1e-12)
			eq(road.lane_count(s + float(k) * L), road.lane_count(s))
			near(road.lanes_right_edge_d(s + float(k) * L), road.lanes_right_edge_d(s), 1e-9)


## Radius, grade and C1 continuity over two laps, straddling the seams (the procedural
## road's bounds test, same tolerances).
func test_bounds_and_continuity_over_two_laps() -> void:
	var kmax := rt.max_curvature()
	var gmax := rt.max_grade_frac()
	var step := 1.3
	var dk_max := kmax / rt.transition_min_m * step * (1.0 + 1e-6)
	var dg_max := step / minf(rt.crest_vertical_radius_min_m, rt.vertical_radius_min_m) * (1.0 + 1e-6)
	var a := RoadSample.new()
	var b := RoadSample.new()
	var s := -L * 0.5
	road.sample_into(s, a)
	var worst := {"k": 0.0, "g": 0.0, "dk": 0.0, "dg": 0.0, "dh": 0.0, "dp": 0.0, "de": 0.0}
	while s < L * 1.5:
		s += step
		road.sample_into(s, b)
		worst.k = maxf(worst.k, absf(b.curvature))
		worst.g = maxf(worst.g, absf(b.grade))
		worst.dk = maxf(worst.dk, absf(b.curvature - a.curvature))
		worst.dg = maxf(worst.dg, absf(b.grade - a.grade))
		worst.dh = maxf(worst.dh, absf(b.heading - a.heading - step * (a.curvature + b.curvature) * 0.5))
		var hm := (a.heading + b.heading) * 0.5
		worst.dp = maxf(worst.dp, Vector2(b.pos_x - a.pos_x - step * sin(hm), b.pos_z - a.pos_z + step * cos(hm)).length())
		worst.de = maxf(worst.de, absf(b.elevation - a.elevation - step * (a.grade + b.grade) * 0.5))
		var tmp := a
		a = b
		b = tmp
	print("      loop: min radius %.0f m, max |grade| %.4f, heading err %s, pos err %s m, elev err %s m" % [
		1.0 / worst.k, worst.g, worst.dh, worst.dp, worst.de])
	le(worst.k, kmax * (1.0 + 1e-9), "radius >= min_curve_radius_m")
	le(worst.g, gmax + 1e-12, "grade <= max_grade_pct")
	le(worst.dk, dk_max, "curvature is continuous (clothoid transitions)")
	le(worst.dg, dg_max, "grade is continuous (vertical curves)")
	le(worst.dh, 5e-5, "heading is C1 with the curvature")
	le(worst.dp, 1e-3, "positions follow the heading")
	le(worst.de, 1e-3, "elevation follows the grade")


# ---------------------------------------------------------------- Lanes, tunnels, bridge

func test_lanes_per_section() -> void:
	var want := {&"desert": 4, &"canyon": 3, &"coast": 3, &"city": 4, &"farmland": 3}
	for j in road.section_count():
		var mid := road.section_start(j) + road.layout.section_length_m * 0.5
		if j == 1:
			mid = (road.layout.tunnel_s1[0] + road.layout.tunnel_s0[1]) * 0.5   # between the tunnels
		eq(road.lane_count(mid), want[road.section_id(j)], "lanes in %s" % road.section_id(j))


func test_lane_changes_are_tapered_and_clear_of_tunnels_and_bridge() -> void:
	var errors := LoopValidator.check_lanes(road, rt)
	eq(errors.size(), 0, "\n".join(errors))
	var changes := _of_kind(_features(road, 0.0, L), RoadFeature.Kind.LANE_COUNT_CHANGE)
	eq(changes.size(), road.layout.lane_s.size(), "one feature per lane change")
	for f in changes:
		gt(f.s_end - f.s_start, 0.0, "taper at %s" % f.s_start)
	# The edge tapers continuously (the barrier the player can hit is the one drawn).
	for i in road.layout.lane_s.size():
		var s0 := road.layout.lane_s[i]
		var prev := road.lanes_right_edge_d(s0 - 1e-6)
		near(road.lanes_right_edge_d(s0 + 1e-6), prev, 1e-6, "edge continuous at the change at %s" % s0)


func test_tunnels_and_the_narrow_one() -> void:
	var o := road.layout
	eq(o.tunnel_s0.size(), 2, "two tunnels")
	var narrow := 0
	for i in o.tunnel_s0.size():
		eq(road.section_id(road.section_at(o.tunnel_s0[i])), &"canyon", "tunnel %d in the canyon" % i)
		if o.tunnel_lanes[i] == 2:
			narrow += 1
			var lead := rt.tunnel_lane_lead_m
			eq(road.lane_count(o.tunnel_s0[i] - lead), 2, "narrowed before the portal")
			near(road.lanes_right_edge_d(o.tunnel_s0[i] - lead),
				road.lanes_left_edge_d(0.0) + 2.0 * road.lane_width_m, 1e-9, "taper finished before the portal")
			eq(road.lane_count(o.tunnel_s1[i] + rt.tunnel_lane_trail_m + 1.0), 3, "lanes back after the exit")
	eq(narrow, 1, "one tunnel narrows to 2 lanes")
	eq(_of_kind(_features(road, 0.0, L), RoadFeature.Kind.TUNNEL).size(), 2, "two TUNNEL features")
	var signs := 0
	for f in _of_kind(_features(road, 0.0, L), RoadFeature.Kind.SIGN):
		if f.tag == ProceduralRoadPath.SIGN_LANE_ENDS:
			signs += 1
	eq(signs, 3, "a lane-ends sign before each lane drop (desert end, city end, the tunnel)")
	var errors := LoopValidator.check_tunnels_and_bridge(road)
	eq(errors.size(), 0, "\n".join(errors))


func test_bridge_on_the_coast_facing_the_sunset() -> void:
	var o := road.layout
	var bs := o.sector_s[road.def.bridge_sector]
	eq(o.sector_style[road.def.bridge_sector], BiomeDef.LANDMARK_SUSPENSION_BRIDGE)
	eq(road.section_id(road.section_at(bs)), &"coast", "the bridge is on the coast")
	# Sun on the right over the sea (the coast biome's side), 15-30 deg off the axis.
	var off := rad_to_deg(wrapf(road.heading_at(bs), -PI, PI))
	ge(off, -rt.sun_offset_max_deg, "bridge heading within the sun band")
	le(off, -rt.sun_offset_min_deg, "bridge heading within the sun band")


func test_glare_rule() -> void:
	var errors := LoopValidator.check_glare(road, rt)
	eq(errors.size(), 0, "\n".join(errors))


# ---------------------------------------------------------------- Ramps, works, sectors, spawns

func test_ramps_on_straightish_road() -> void:
	var o := road.layout
	eq(o.ramp_s.size(), 4, "two on / off ramp pairs")
	for p in 2:
		eq(o.ramp_kind[p * 2], LoopLayout.RAMP_OFF, "pair %d: off-ramp first" % p)
		eq(o.ramp_kind[p * 2 + 1], LoopLayout.RAMP_ON, "pair %d: then the on-ramp" % p)
		gt(o.ramp_s[p * 2 + 1], o.ramp_s[p * 2] + o.ramp_len[p * 2], "pair %d in order" % p)
	for i in o.ramp_s.size():
		le(o.max_abs_curvature(o.ramp_s[i], o.ramp_s[i] + o.ramp_len[i]), 1.0 / road.def.ramp_min_radius_m,
			"ramp %d on a straight-ish stretch" % i)
	var errors := LoopValidator.check_ramps(road)
	eq(errors.size(), 0, "\n".join(errors))
	eq(road.section_id(o.ramp_section[0]), &"city", "first pair in the city")
	eq(road.section_id(o.ramp_section[2]), &"farmland", "second pair in the farmland")


func test_road_works_zones() -> void:
	eq(road.layout.closure_s0.size(), road.section_count(), "one toggleable zone per section")
	var errors := LoopValidator.check_closures(road)
	eq(errors.size(), 0, "\n".join(errors))


func test_sectors_evenly_spread() -> void:
	var o := road.layout
	eq(o.sector_s.size(), 6, "six sector gantries")
	eq(road.section_id(road.section_at(o.sector_s[0])), &"desert", "start / finish in the desert")
	var even := L / 6.0
	for k in 6:
		var gap := road.wrap_s(o.sector_s[(k + 1) % 6] - o.sector_s[k])
		within_pct(gap, even, 0.15, "sector %d spacing" % k)
	var cps := _of_kind(_features(road, 0.0, L), RoadFeature.Kind.CHECKPOINT)
	eq(cps.size(), 6, "six CHECKPOINT features per lap")
	for k in cps.size():
		eq(cps[k].tag, o.sector_style[k], "sector %d landmark style" % k)
		eq(cps[k].value, float(k + 1), "sector %d value" % k)
	var warn := 0
	for f in _of_kind(_features(road, 0.0, L), RoadFeature.Kind.SIGN):
		if f.tag == ProceduralRoadPath.SIGN_CHECKPOINT:
			warn += 1
	eq(warn, 12, "warning signs at 1 km and 500 m before each gantry")


func test_spawn_points() -> void:
	var o := road.layout
	gt(o.spawn_s.size(), 0)
	for i in o.spawn_s.size():
		lt(o.spawn_lane[i], road.lane_count(o.spawn_s[i]), "spawn %d on a lane" % i)
		ge(o.spawn_lane[i], 0)


func test_blind_crests_flagged_from_the_geometry() -> void:
	var o := road.layout
	var blind := 0
	for i in o.pvi_s.size():
		var g_in := (o.pvi_e[i] - o.pvi_e[i - 1]) / (o.pvi_s[i] - o.pvi_s[i - 1]) if i > 0 \
			else (o.pvi_e[0] - o.pvi_e[o.pvi_s.size() - 1]) / (L - o.pvi_s[o.pvi_s.size() - 1])
		var s1 := o.pvi_s[i + 1] if i + 1 < o.pvi_s.size() else L
		var e1 := o.pvi_e[i + 1] if i + 1 < o.pvi_s.size() else o.pvi_e[0]
		var g_out := (e1 - o.pvi_e[i]) / (s1 - o.pvi_s[i])
		var a := g_in - g_out
		if a > 0.0 and o.pvi_vc_len[i] > 0.0 and o.profile.is_blind_crest(a, o.pvi_vc_len[i]):
			blind += 1
	var crests := _of_kind(_features(road, 0.0, L), RoadFeature.Kind.BLIND_CREST)
	eq(crests.size(), blind, "every blind crest flagged, nothing else")
	var canyon := 0
	for f in crests:
		if road.section_id(road.section_at(f.s_start)) == &"canyon":
			canyon += 1
	ge(canyon, 2, "the canyon has crests")


# ---------------------------------------------------------------- Wrap math

func test_wrap_math() -> void:
	near(road.wrap_s(-1.0), L - 1.0, EPS)
	eq(road.wrap_s(L), 0.0)
	near(road.wrap_s(2.0 * L + 5.0), 5.0, 1e-9)
	eq(road.lap_of(-1.0), -1)
	eq(road.lap_of(0.0), 0)
	eq(road.lap_of(L - 1e-3), 0)
	eq(road.lap_of(L), 1)
	eq(road.lap_of(3.0 * L + 7.0), 3)
	near(road.signed_delta(L - 10.0, 10.0), 20.0, 1e-9, "ahead across the seam")
	near(road.signed_delta(10.0, L - 10.0), -20.0, 1e-9, "behind across the seam")
	near(road.signed_delta(0.0, L * 0.5 - 1.0), L * 0.5 - 1.0, 1e-9)
	near(road.signed_delta(3.0 * L + 5.0, 5.0), 0.0, 1e-9, "laps do not count")
	near(road.curvature_at(L + 3000.0), road.curvature_at(3000.0), 1e-15)
	near(road.elevation_at(-L + 7000.0), road.elevation_at(7000.0), 1e-9)
	near(road.grade_at(2.0 * L + 7000.0), road.grade_at(7000.0), 1e-12)


func test_features_across_the_seam() -> void:
	var list := _features(road, L - 1500.0, L + 500.0)
	var cps := _of_kind(list, RoadFeature.Kind.CHECKPOINT)
	eq(cps.size(), 1, "the start / finish line of lap 1")
	if cps.size() == 1:
		near(cps[0].s_start, L, 1e-6)
		eq(cps[0].value, 7.0, "lap 1, sector 0: 6 + 1")
	var warn := 0
	for f in list:
		if f.kind == RoadFeature.Kind.SIGN and f.tag == ProceduralRoadPath.SIGN_CHECKPOINT:
			warn += 1
	eq(warn, 2, "its 1 km and 500 m signs, at the end of lap 0")
	for i in range(1, list.size()):
		ge(list[i].s_start, list[i - 1].s_start, "sorted")
	var early := _of_kind(_features(road, -100.0, 100.0), RoadFeature.Kind.CHECKPOINT)
	eq(early.size(), 1)
	# Every lap reports the same features, shifted.
	var lap0 := _features(road, 0.0, L)
	var lap2 := _features(road, 2.0 * L, 3.0 * L)
	eq(lap2.size(), lap0.size(), "same features every lap")
	for i in mini(lap0.size(), lap2.size()):
		near(lap2[i].s_start - lap0[i].s_start, 2.0 * L, 1e-6)
		eq(lap2[i].kind, lap0[i].kind)


# ---------------------------------------------------------------- Determinism and edits

func test_deterministic_by_seed_and_edits() -> void:
	var a := LoopRoadPath.new(_def(), t)
	var b := LoopRoadPath.new(_def(), t)
	eq(a.trace_hash(), b.trace_hash(), "same seed + edits = same loop")
	eq(a.trace_hash(), road.trace_hash())
	var d := _def()
	d.map_seed += 1
	ne(LoopRoadPath.new(d, t).trace_hash(), a.trace_hash(), "another seed, another loop")


func test_an_edit_changes_only_its_value() -> void:
	var d := _def()
	var key := "bend/2/0/radius_m"
	d.edits[key] = 2650.0
	var e := LoopRoadPath.new(d, t)
	var i := e.layout.param_index(key)
	eq(e.layout.param_value[i], 2650.0, "the edit is used")
	eq(e.layout.bend_radius[road.layout.bend_section.find(2)], 2650.0, "on that bend")
	ne(e.trace_hash(), road.trace_hash())
	# Every other drawn value is the same (edits never shift a draw).
	for k in road.layout.param_key.size():
		if road.layout.param_key[k] != key:
			eq(e.layout.param_default[k], road.layout.param_default[k], road.layout.param_key[k])
	eq(e.layout.pvi_s, road.layout.pvi_s, "profile stream untouched")
	eq(e.layout.tunnel_s0, road.layout.tunnel_s0, "tunnels untouched")
	var errors := LoopValidator.validate(e, t)
	eq(errors.size(), 0, "\n".join(errors))


func test_a_bad_edit_is_reported() -> void:
	var d := _def()
	# Put the 2-lane tunnel's portal right on sector gantry 1 (in the desert).
	d.edits["tunnel/0/portal_m"] = road.layout.sector_s[1] - road.section_start(road.def.tunnel_section)
	var errors := LoopValidator.validate(LoopRoadPath.new(d, t), t)
	gt(errors.size(), 0, "the validator catches it")


# ---------------------------------------------------------------- Tick safety and cost

func test_queries_allocate_nothing() -> void:
	var out := RoadSample.new()
	road.sample_into(10.0, out)
	var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
	var s := -L
	for i in 3000:
		road.sample_into(s, out)
		road.curvature_at(s)
		road.heading_at(s)
		road.lane_count(s)
		road.lane_center_d(1, s)
		road.lanes_right_edge_d(s)
		road.guardrail_d(s)
		road.signed_delta(s, 17.0)
		s += 31.7
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects_before)


var _out := RoadSample.new()
var _bench_s := 0.0
var _proc: ProceduralRoadPath


func _bench_loop() -> void:
	for i in 100:
		_bench_s += 173.3
		road.sample_into(_bench_s, _out)


func _bench_proc() -> void:
	for i in 100:
		_bench_s += 173.3
		if _bench_s > L:
			_bench_s -= L
		_proc.sample_into(_bench_s, _out)


func test_sample_into_cost_like_the_procedural_road() -> void:
	_proc = ProceduralRoadPath.new(RunContext.new(1, RunContext.MODE_JOURNEY, t))
	_proc.ensure_generated_to(L + 1000.0)
	var proc_us := WBBench.usec_per_call(_bench_proc, 20) / 100.0
	var loop_us := WBBench.usec_per_call(_bench_loop, 20) / 100.0
	WBBench.report("LoopRoadPath.sample_into (procedural %.2f usec)" % proc_us, loop_us, 15.0)
	le(loop_us, WBBench.budget(15.0), "sample_into usec per call")
	le(loop_us, proc_us * 2.0 + 0.5, "comparable to ProceduralRoadPath.sample_into")


func test_generation_time() -> void:
	var t0 := Time.get_ticks_usec()
	var r := LoopRoadPath.new(_def(), t)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("      bench  LoopRoadPath.new (generate + close + features)  %.0f ms" % ms)
	le(ms, 3000.0, "a loop generates in well under the editor's patience")
	eq(r.layout.n, road.layout.n)


func test_lane_flow_speeds_per_section() -> void:
	near(road.lane_flow_speed_mps(0, 4, 100.0), Units.kmh_to_mps(185.0), 1e-9, "desert left lane")
	near(road.lane_flow_speed_mps(3, 4, 17000.0), Units.kmh_to_mps(85.0), 1e-9, "city right lane")
