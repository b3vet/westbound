class_name LoopGen
extends RefCounted
# lint: sim
## Generates the multiplayer loop (N3.1) from a LoopMapDef (seed + section templates +
## hand edits) into a LoopLayout. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map;
## docs/MULTIPLAYER_PLAN.md MP-D3 (a closed-loop generator); World → Road (radius >=
## 1,200 m, grades <= 5 %, blind crests), Traffic fairness rule 6. docs/LOOP_MAP.md.
##
##   var layout := LoopGen.generate(LoopMapDef.load_default(), Tuning.load_default())
##
## Same primitives as the procedural road, no second road math: the plan view is laid
## out by RoadPlanGen (begin_alignment / add_straight / add_bend: straights, clothoid
## transitions and arcs, with its BEND / BLIND_BEND / SIGN features) and the profile by
## RoadProfileGen (begin_profile / add_element: grade tangents and parabolic vertical
## curves; is_blind_crest / crest_sight_distance flag the crests). The dense table is
## sampled and integrated with ProceduralRoadPath's rule (Hermite heading, positions
## along the mid-cell heading).
##
## Closure (docs/LOOP_MAP.md → Closure):
##  - heading: the last bend's deflection is total_turn minus every other bend's, so the
##    elements turn exactly -TAU (the loop turns left);
##  - position: two sections (def.closure_sections) move length from their last straight
##    to their first (their lengths stay exact). A transfer d moves the end point by
##    d (u(h_first) - u(h_last)), so Newton on the integrated table with that Jacobian
##    converges in two or three steps to below closure_solve_tolerance_m; the last
##    rounding (~1e-12 m) is spread over the lap so entry N equals entry 0 exactly;
##  - profile: PVIs are periodic (the last grade tangent runs into PVI 0 at s = 0), so
##    elevation and grade close by construction;
##  - every section starts and ends on a straight: curvature is 0 at the seam (C2 plan).
##
## Determinism: every random value comes from streams derived from def.map_seed and is
## drawn in a fixed order whatever the edits (an edit replaces the drawn value after the
## draw). Positions of features are whole millimetres (the road-space file is exact).

const STREAM := &"loop"
const MM_PER_M := 1000

var _def: LoopMapDef
var _t: Tuning
var _rt: RoadTuning
var _out: LoopLayout
var _root: Rng
var _rules: BiomeRoadRules
var _plan_rng: Rng

# Plan design per bend / straight (flattened; per section ranges below).
var _sec_bend0 := PackedInt32Array()
var _sec_straight0 := PackedInt32Array()
var _dh := PackedFloat64Array()
var _radius := PackedFloat64Array()
var _ramp := PackedFloat64Array()
var _straight := PackedFloat64Array()
var _h_section_start := PackedFloat64Array()
var _h_section_end := PackedFloat64Array()
## Busy zones (tunnels, lane-change tapers, ramps, the bridge, gantries) for placement.
var _busy0 := PackedFloat64Array()
var _busy1 := PackedFloat64Array()
var _busy_margin := PackedFloat64Array()


static func generate(def: LoopMapDef, tuning: Tuning) -> LoopLayout:
	return LoopGen.new(def, tuning)._run()


func _init(def: LoopMapDef, tuning: Tuning) -> void:
	_def = def
	_t = tuning
	_rt = tuning.road
	_root = Rng.new(def.map_seed).derive(STREAM)


func _run() -> LoopLayout:
	_out = LoopLayout.new()
	var o := _out
	o.def = _def
	o.section_length_m = _def.section_length_m
	for sec in _def.sections:
		o.section_ids.append(sec.biome_id)
		o.section_lanes.append(clampi(sec.lanes, _rt.lanes_min, _rt.lanes_max))
	o.length_m = _def.section_length_m * float(_def.sections.size())
	o.n = maxi(roundi(o.length_m / _rt.sample_spacing_m), 2)
	o.dx = o.length_m / float(o.n)
	var ids: Array[StringName] = o.section_ids.duplicate()
	var biomes := BiomePlan.from_ids(ids, ids[ids.size() - 1], _def.section_length_m)
	_rules = BiomeRoadRules.new(biomes, _rt)
	_design_plan()
	_close_plan()
	var features := _root.derive(&"features")
	_place_tunnels(features.derive(&"tunnels"), _def.section_length_m)
	_design_profile()
	_place_features(features)
	o.features.sort_custom(ProceduralRoadPath._feature_before)
	return o


# ---------------------------------------------------------------- Parameters

## The value in use for `key`: the edit if there is one, else `generated`. Records it for
## the editor (range lo..hi; `s` = where the generated value acts, so an s-like
## parameter acts at s - generated + value).
func _param(key: String, generated: float, lo: float, hi: float, s: float) -> float:
	var v: float = _def.edits.get(key, generated)
	var o := _out
	o.param_key.append(key)
	o.param_default.append(generated)
	o.param_value.append(v)
	o.param_min.append(lo)
	o.param_max.append(hi)
	o.param_s.append(s)
	return v


static func q_mm(s: float) -> float:
	return roundf(s * float(MM_PER_M)) / float(MM_PER_M)


func _issue(text: String) -> void:
	_out.issues.append(text)


# ---------------------------------------------------------------- Plan view

## Bends (deflection, radius, transition) and straights of every section, drawn from the
## plan stream then edited; the last bend closes the heading.
func _design_plan() -> void:
	var rng := _root.derive(&"plan")
	_plan_rng = rng.derive(&"elements")
	var s_len := _def.section_length_m
	var nominal := 0.0
	for sec in _def.sections:
		for d in sec.bend_deflection_deg:
			nominal += d
	_out.total_turn = TAU if nominal > 0.0 else -TAU
	var turned := 0.0
	var last_sec := _def.sections.size() - 1
	for j in _def.sections.size():
		var sec := _def.sections[j]
		var sec_s := s_len * float(j)
		_sec_bend0.append(_dh.size())
		var nb := sec.bend_deflection_deg.size()
		var bend_total := 0.0
		for i in nb:
			var r_lo := sec.bend_radius_min_m[i]
			var r_hi := sec.bend_radius_max_m[i]
			var r_draw := rng.float_range(r_lo, r_hi)
			var ramp_draw := rng.float_range(_rt.transition_min_m, _rt.transition_max_m)
			var base := "bend/%d/%d/" % [j, i]
			var radius := _param(base + "radius_m", r_draw, _rt.min_curve_radius_m, _rt.curve_radius_max_m, sec_s)
			var ramp := _param(base + "transition_m", ramp_draw, _rt.transition_min_m, _rt.transition_max_m, sec_s)
			var dh: float
			if j == last_sec and i == nb - 1:
				dh = _out.total_turn - turned   # the closing bend
			else:
				var defl := sec.bend_deflection_deg[i]
				dh = deg_to_rad(_param(base + "deflection_deg", defl, defl - absf(defl), defl + absf(defl), sec_s))
			turned += dh
			_dh.append(dh)
			_radius.append(radius)
			_ramp.append(ramp)
			bend_total += RoadPlanGen.bend_length(dh, radius, ramp, _rt.transition_min_m)
		_sec_straight0.append(_straight.size())
		var weights := PackedFloat64Array()
		var w_sum := 0.0
		for i in nb + 1:
			var w_def := sec.straight_weights[i] if i < sec.straight_weights.size() else 1.0
			var jit := _def.straight_weight_jitter_frac
			var w_draw := w_def * rng.float_range(1.0 - jit, 1.0 + jit)
			var w := maxf(_param("straight/%d/%d/weight" % [j, i], w_draw, 0.0, w_def * 2.0, sec_s), 0.0)
			weights.append(w)
			w_sum += w
		var room := s_len - bend_total
		if room < 0.0:
			_issue("section %d: its bends (%.0f m) are longer than the section" % [j, bend_total])
		for i in nb + 1:
			_straight.append(room * weights[i] / w_sum if w_sum > 0.0 else room / float(nb + 1))
	_sec_bend0.append(_dh.size())
	_sec_straight0.append(_straight.size())


## Lays the elements out with `transfer[c]` metres moved from the last to the first
## straight of closure section c; integrates the table. Returns the plan.
func _lay_plan(transfer: PackedFloat64Array) -> RoadPlanGen:
	var o := _out
	var plan := RoadPlanGen.new(_plan_rng, _rt)
	plan.biome_rules = _rules
	var h0 := deg_to_rad(_def.start_heading_deg)
	plan.begin_alignment(h0)
	_h_section_start.clear()
	_h_section_end.clear()
	o.bend_section.clear()
	o.bend_s0.clear()
	o.bend_s1.clear()
	o.bend_dh.clear()
	o.bend_radius.clear()
	o.bend_transition.clear()
	o.straight_section.clear()
	o.straight_s0.clear()
	o.straight_len.clear()
	for j in _def.sections.size():
		_h_section_start.append(plan.heading_end())
		var b0 := _sec_bend0[j]
		var nb := _sec_bend0[j + 1] - b0
		var st0 := _sec_straight0[j]
		var sec_end := _def.section_length_m * float(j + 1)
		for i in nb + 1:
			var st := _straight[st0 + i]
			var c := _def.closure_sections.find(j)
			if c >= 0 and i == 0:
				st += transfer[c]
			if i == nb:
				st = sec_end - plan.end_s   # the remainder: the section length stays exact
			o.straight_section.append(j)
			o.straight_s0.append(plan.end_s)
			o.straight_len.append(st)
			if st > 0.0:
				plan.add_straight(st)
			if i < nb:
				var b := b0 + i
				o.bend_section.append(j)
				o.bend_s0.append(plan.end_s)
				o.bend_dh.append(_dh[b])
				o.bend_radius.append(_radius[b])
				o.bend_transition.append(_ramp[b])
				plan.add_bend(_dh[b], _radius[b], _ramp[b])
				o.bend_s1.append(plan.end_s)
		_h_section_end.append(plan.heading_end())
	_integrate(plan)
	return plan


## Heading / curvature table from the plan, positions integrated with
## ProceduralRoadPath's rule (Hermite heading at the cell's midpoint).
func _integrate(plan: RoadPlanGen) -> void:
	var o := _out
	var size := o.n + 1
	o.h.resize(size)
	o.k.resize(size)
	o.x.resize(size)
	o.z.resize(size)
	for i in size:
		plan.eval(float(i) * o.dx)
		o.h[i] = plan.out_heading
		o.k[i] = plan.out_curvature
		if i == 0:
			o.x[i] = 0.0
			o.z[i] = 0.0
		else:
			var mid_h := (o.h[i - 1] + o.h[i]) * 0.5 + o.dx * (o.k[i - 1] - o.k[i]) * 0.5 * 0.5 * 0.5
			o.x[i] = o.x[i - 1] + o.dx * sin(mid_h)
			o.z[i] = o.z[i - 1] - o.dx * cos(mid_h)


## Newton on the two closure transfers (see the header), then the seam made exact.
func _close_plan() -> void:
	var o := _out
	var transfer := PackedFloat64Array()
	transfer.resize(_def.closure_sections.size())
	var plan := _lay_plan(transfer)
	var it := 0
	var rx := o.x[o.n] - o.x[0]
	var rz := o.z[o.n] - o.z[0]
	while it < _def.closure_max_iterations and Vector2(rx, rz).length() > _def.closure_solve_tolerance_m:
		if transfer.size() < 2:
			break
		var a := _def.closure_sections[0]
		var b := _def.closure_sections[1]
		# Columns: d(end point) / d(transfer) = u(h_first) - u(h_last), u(h) = (sin h, -cos h).
		var ax := sin(_h_section_start[a]) - sin(_h_section_end[a])
		var az := -cos(_h_section_start[a]) + cos(_h_section_end[a])
		var bx := sin(_h_section_start[b]) - sin(_h_section_end[b])
		var bz := -cos(_h_section_start[b]) + cos(_h_section_end[b])
		var det := ax * bz - az * bx
		if absf(det) <= 0.0:
			_issue("closure sections %d and %d cannot close the loop (parallel)" % [a, b])
			break
		transfer[0] += (-rx * bz + rz * bx) / det
		transfer[1] += (-ax * rz + az * rx) / det
		plan = _lay_plan(transfer)
		rx = o.x[o.n] - o.x[0]
		rz = o.z[o.n] - o.z[0]
		it += 1
	o.closure_iterations = it
	o.closure_residual_m = Vector2(rx, rz).length()
	o.closure_heading_error = absf(o.h[o.n] - o.h[0] - o.total_turn)
	# Spread the last rounding over the lap; the seam entry repeats entry 0.
	for i in o.n + 1:
		var f := float(i) / float(o.n)
		o.x[i] -= rx * f
		o.z[i] -= rz * f
	o.x[o.n] = o.x[0]
	o.z[o.n] = o.z[0]
	o.h[o.n] = o.h[0] + o.total_turn
	o.k[o.n] = o.k[0]
	o.plan = plan
	for i in o.straight_len.size():
		if o.straight_len[i] < _def.straight_min_m:
			_issue("straight %d (section %d) is %.0f m, under straight_min_m" % [i, o.straight_section[i], o.straight_len[i]])


# ---------------------------------------------------------------- Profile

## Periodic PVIs (PVI 0 at s = 0), grades drawn per section, deliberate crests, the
## mean grade removed so the lap closes, edits (raise a PVI), then vertical curves that
## fit between their neighbours; laid out as RoadProfileGen elements from s = 0.
func _design_profile() -> void:
	var o := _out
	var rng := _root.derive(&"profile")
	var L := o.length_m
	var ps := PackedFloat64Array([0.0])
	var cursor := 0.0
	while true:
		var sec := _def.sections[o.section_at(cursor)]
		var nxt := cursor + rng.float_range(sec.pvi_spacing_min_m, sec.pvi_spacing_max_m)
		var last := _def.sections[o.section_at(L - sec.pvi_spacing_min_m)]
		if nxt > L - last.pvi_spacing_min_m:
			break
		ps.append(nxt)
		cursor = nxt
	var m := ps.size()
	var span := PackedFloat64Array()
	var gr := PackedFloat64Array()
	for i in m:
		var s1 := ps[i + 1] if i + 1 < m else L
		span.append(s1 - ps[i])
		var sec := _def.sections[o.section_at(ps[i] + span[i] * 0.5)]
		var gmax := Units.pct_to_frac(sec.grade_max_pct)
		gr.append(rng.float_range(-gmax, gmax))
	# Crests: per section, crest_count PVIs spread over its interior PVIs.
	var crest := PackedInt32Array()
	crest.resize(m)
	var crest_lo := Units.pct_to_frac(_rt.crest_grade_min_pct)
	var crest_hi := minf(Units.pct_to_frac(_def.crest_grade_max_pct), _rt.max_grade_frac())
	# The longest crest curve reaches this far either side of its PVI (grade change 2 crest_hi).
	var crest_half := _rt.crest_vertical_radius_max_m * crest_hi
	for j in _def.sections.size():
		var sec := _def.sections[j]
		var cand := PackedInt32Array()
		for i in range(1, m):
			if o.section_at(ps[i] - crest_half) == j and o.section_at(ps[i] + crest_half) == j \
					and not _in_tunnel(ps[i] - crest_half, ps[i] + crest_half):
				cand.append(i)
		var nc := mini(sec.crest_count, cand.size())
		for c in nc:
			var lo := floori(float(c * cand.size()) / float(nc))
			var hi := floori(float((c + 1) * cand.size()) / float(nc)) - 1
			var p := cand[rng.int_range(lo, hi)]
			if crest[p - 1] != 0 or (p + 1 < m and crest[p + 1] != 0):
				continue
			crest[p] = 1
			gr[p - 1] = rng.float_range(crest_lo, crest_hi)
			gr[p] = -rng.float_range(crest_lo, crest_hi)
	# Close the lap: remove the mean grade.
	var rise := 0.0
	for i in m:
		rise += gr[i] * span[i]
	var shift := -rise / L
	var el := PackedFloat64Array()
	el.resize(m)
	var ecur := 0.0
	for i in m:
		el[i] = ecur
		gr[i] += shift
		ecur += gr[i] * span[i]
	# Edits: raise a PVI (crest heights), then grades from the elevations.
	for i in m:
		var sec := _def.sections[o.section_at(ps[i])]
		var reach := Units.pct_to_frac(sec.grade_max_pct) * span[i]
		el[i] += _param("pvi/%d/raise_m" % i, 0.0, -reach, reach, ps[i])
	for i in m:
		var e1 := el[i + 1] if i + 1 < m else el[0]
		gr[i] = (e1 - el[i]) / span[i]
	# Vertical curves.
	var vl := PackedFloat64Array()
	var vr := PackedFloat64Array()
	for i in m:
		var g_in := gr[i - 1] if i > 0 else gr[m - 1]
		var a := gr[i] - g_in
		var s_in := span[i - 1] if i > 0 else span[m - 1]
		var r_draw: float
		if crest[i] != 0:
			r_draw = rng.float_range(_rt.crest_vertical_radius_min_m, _rt.crest_vertical_radius_max_m)
		else:
			r_draw = rng.float_range(_rt.vertical_radius_min_m, _rt.vertical_radius_max_m)
		var r := _param("pvi/%d/radius_m" % i, r_draw, _rt.crest_vertical_radius_min_m, _rt.vertical_radius_max_m, ps[i])
		var length := absf(a) * r
		var fit := _def.vertical_curve_fit_frac * minf(s_in, span[i])
		if length > fit:
			length = fit
		vl.append(length)
		vr.append(length / absf(a) if absf(a) > 0.0 else INF)
	o.pvi_s = ps
	o.pvi_e = el
	o.pvi_vc_len = vl
	o.pvi_radius = vr
	o.pvi_crest = crest
	# Elements from s = 0: the second half of PVI 0's curve, then per PVI tangent + curve,
	# ending with the first half of PVI 0's curve.
	var prof := RoadProfileGen.new(rng.derive(&"elements"), _rt)
	var a0 := gr[0] - gr[m - 1]
	var half0 := vl[0] * 0.5
	prof.begin_profile(el[0] + (a0 * vl[0] * 0.5 * 0.5 * 0.5 if vl[0] > 0.0 else 0.0))
	if half0 > 0.0:
		prof.add_element(half0, (gr[0] + gr[m - 1]) * 0.5, a0 / vl[0])
	for i in m:
		var j := i + 1
		var vj := vl[j] if j < m else vl[0]
		var s_next := ps[j] if j < m else L
		var tangent := s_next - vj * 0.5 - prof.end_s
		if tangent > 0.0:
			prof.add_element(tangent, gr[i], 0.0)
		if vj > 0.0:
			var g_out := gr[j] if j < m else gr[0]
			var dg := (g_out - gr[i]) / vj
			prof.add_element(vj if j < m else vj * 0.5, gr[i], dg)
		# Crest flags from the geometry (RoadProfileGen's rule).
		var p := j if j < m else 0
		var ac := gr[i] - (gr[j] if j < m else gr[0])
		if ac > 0.0 and vj > 0.0 and prof.is_blind_crest(ac, vj):
			var c0 := q_mm(ps[p] - vj * 0.5) if j < m else q_mm(L - vj * 0.5)
			var c1 := q_mm(c0 + vj)
			o.features.append(RoadFeature.make(RoadFeature.Kind.BLIND_CREST, c0, c1, prof.crest_sight_distance(ac, vj)))
			var sign_s := o.wrap_s(q_mm(c0 - _rt.hazard_sign_distance_m))
			o.features.append(RoadFeature.make(RoadFeature.Kind.SIGN, sign_s, sign_s, _rt.hazard_sign_distance_m,
				ProceduralRoadPath.SIGN_CREST))
			# Ramps and road works stay off a blind crest, its approach and its far side.
			_busy(c0 - _rt.hazard_sign_distance_m, c1 + _rt.blind_sight_distance_m, _def.feature_margin_m)
	o.profile = prof
	var size := o.n + 1
	o.e.resize(size)
	o.g.resize(size)
	for i in size:
		prof.eval(float(i) * o.dx)
		o.e[i] = prof.out_elevation
		o.g[i] = prof.out_grade
	o.closure_elevation_error = absf(o.e[o.n] - o.e[0])
	o.closure_grade_error = absf(o.g[o.n] - o.g[0])
	o.e[o.n] = o.e[0]
	o.g[o.n] = o.g[0]


# ---------------------------------------------------------------- Features

func _place_features(rng: Rng) -> void:
	var o := _out
	var S := _def.section_length_m
	var L := o.length_m
	# Plan features (bends, blind bends, their signs).
	for list: Array[RoadFeature] in [o.plan.bends, o.plan.blind_bends, o.plan.signs]:
		for f in list:
			o.features.append(RoadFeature.make(f.kind, q_mm(f.s_start), q_mm(f.s_end), f.value, f.tag, f.tag2))
	# Sector gantries (sector 0 = start / finish) and their warning signs.
	for sk in _def.sector_count:
		var nominal := q_mm(_def.start_finish_s_m + L * float(sk) / float(_def.sector_count))
		var spacing := L / float(_def.sector_count)
		var tol := spacing * _def.sector_spacing_tolerance_frac
		var s := o.wrap_s(q_mm(nominal + _param("sector/%d/offset_m" % sk, 0.0, -tol, tol, nominal)))
		o.sector_s.append(s)
		var style: StringName = _def.sector_styles[sk] if sk < _def.sector_styles.size() else BiomeDef.LANDMARK_SIGN_GANTRY
		o.sector_style.append(style)
		o.features.append(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, s, s, float(sk + 1), style))
		for w in _t.legs.checkpoint_warning_distances_m:
			var ws := o.wrap_s(s - w)
			o.features.append(RoadFeature.make(RoadFeature.Kind.SIGN, ws, ws, w, ProceduralRoadPath.SIGN_CHECKPOINT))
		_busy(s, s, _def.gantry_clearance_m)
	# The bridge: the bridge sector's landmark, backstays included.
	var lt := _t.landmarks
	var half := lt.bridge_span_m * 0.5 + lt.bridge_backstay_m
	if _def.bridge_sector >= 0 and _def.bridge_sector < o.sector_s.size():
		var bs := o.sector_s[_def.bridge_sector]
		o.bridge_s0 = q_mm(bs - half)
		o.bridge_s1 = q_mm(bs + half)
		_busy(o.bridge_s0, o.bridge_s1, _def.feature_margin_m)
	_place_lanes()
	_place_ramps(rng.derive(&"ramps"), S)
	_place_closures(rng.derive(&"closures"), S)
	# Spawn points: every lane, spawn_after_gantry_m past each sector gantry.
	for sk in o.sector_s.size():
		var s := o.wrap_s(q_mm(o.sector_s[sk] + _def.spawn_after_gantry_m))
		for lane in _lanes_at(s):
			o.spawn_s.append(s)
			o.spawn_lane.append(lane)
	# Elevated city.
	var es := S * float(_def.elevated_section)
	o.elevated_s0.append(q_mm(es + _def.elevated_start_m))
	o.elevated_s1.append(q_mm(es + _def.elevated_end_m))


## True when [s0, s1] meets a tunnel (crest curves stay out of them).
func _in_tunnel(s0: float, s1: float) -> bool:
	for i in _out.tunnel_s0.size():
		if _out.zones_meet(s0, s1, _out.tunnel_s0[i], _out.tunnel_s1[i], _def.feature_margin_m):
			return true
	return false


func _busy(s0: float, s1: float, margin: float) -> void:
	_busy0.append(s0)
	_busy1.append(s1)
	_busy_margin.append(margin)


func _is_free(s0: float, s1: float) -> bool:
	for i in _busy0.size():
		if _out.zones_meet(s0, s1, _busy0[i], _busy1[i], _busy_margin[i]):
			return false
	return true


func _place_tunnels(rng: Rng, S: float) -> void:
	var o := _out
	var sec_s := S * float(_def.tunnel_section)
	for i in _def.tunnel_portal_min_m.size():
		var p_draw := rng.float_range(_def.tunnel_portal_min_m[i], _def.tunnel_portal_max_m[i])
		var l_draw := rng.float_range(_def.tunnel_length_min_m[i], _def.tunnel_length_max_m[i])
		var portal := _param("tunnel/%d/portal_m" % i, p_draw, 0.0, S, sec_s + p_draw)
		var length := _param("tunnel/%d/length_m" % i, l_draw, _rt.tunnel_length_min_m, _rt.tunnel_length_max_m,
			sec_s + portal)
		var s0 := q_mm(sec_s + portal)
		var s1 := q_mm(s0 + length)
		var lanes := _def.tunnel_lanes[i] if i < _def.tunnel_lanes.size() else 0
		if lanes <= 0:
			lanes = o.section_lanes[_def.tunnel_section]
		o.tunnel_s0.append(s0)
		o.tunnel_s1.append(s1)
		o.tunnel_lanes.append(lanes)
		o.features.append(RoadFeature.make(RoadFeature.Kind.TUNNEL, s0, s1, s1 - s0))
		_busy(s0, s1, _def.feature_margin_m)


## Section lane counts (changed lanes/<j>/change_m after the section start, tapered) and
## the tunnel narrowings (the drop's taper ends tunnel_lane_lead_m before the portal, the
## lanes come back tunnel_lane_trail_m after the exit), like ProceduralRoadPath's.
func _place_lanes() -> void:
	var o := _out
	var cs := PackedFloat64Array()
	var cn := PackedInt32Array()
	var ct := PackedFloat64Array()
	var S := _def.section_length_m
	var nsec := o.section_lanes.size()
	for j in nsec:
		var prev := o.section_lanes[(j + nsec - 1) % nsec]
		var lanes := o.section_lanes[j]
		if lanes == prev:
			continue
		var sec := _def.sections[j]
		var s := q_mm(S * float(j) + _param("lanes/%d/change_m" % j, sec.lane_change_offset_m, -S * 0.5,
			S * 0.5, S * float(j) + sec.lane_change_offset_m))
		cs.append(s)
		cn.append(lanes)
		ct.append(_rt.biome_lane_taper_m)
		if lanes < prev:
			_lane_ends_sign(s)
	for i in o.tunnel_s0.size():
		var sec_lanes := o.section_lanes[o.section_at(o.tunnel_s0[i])]
		var tl := o.tunnel_lanes[i]
		if tl >= sec_lanes:
			continue
		var taper := _rt.lane_taper_length_m
		var drop := q_mm(o.tunnel_s0[i] - _rt.tunnel_lane_lead_m - taper)
		cs.append(drop)
		cn.append(tl)
		ct.append(taper)
		_lane_ends_sign(drop)
		cs.append(q_mm(o.tunnel_s1[i] + _rt.tunnel_lane_trail_m))
		cn.append(sec_lanes)
		ct.append(taper)
	# Sorted by s.
	for i in cs.size():
		cs[i] = o.wrap_s(cs[i])
	var order := range(cs.size())
	order.sort_custom(func(a: int, b: int) -> bool: return cs[a] < cs[b])
	for i: int in order:
		o.lane_s.append(cs[i])
		o.lane_n.append(cn[i])
		o.lane_taper.append(ct[i])
		o.features.append(RoadFeature.make(RoadFeature.Kind.LANE_COUNT_CHANGE, cs[i], cs[i] + ct[i], float(cn[i])))
		_busy(cs[i], cs[i] + ct[i], _def.feature_margin_m)
	o.lanes_base = o.lane_n[o.lane_n.size() - 1] if o.lane_n.size() > 0 else o.section_lanes[0]


func _lane_ends_sign(s: float) -> void:
	var ss := _out.wrap_s(q_mm(s - _rt.lane_ends_sign_distance_m))
	_out.features.append(RoadFeature.make(RoadFeature.Kind.SIGN, ss, ss, _rt.lane_ends_sign_distance_m,
		ProceduralRoadPath.SIGN_LANE_ENDS))


func _lanes_at(s: float) -> PackedInt32Array:
	var o := _out
	var i := o.lane_s.bsearch(o.wrap_s(s), false)
	var count := o.lanes_base if i == 0 else o.lane_n[i - 1]
	var out := PackedInt32Array()
	for lane in count:
		out.append(lane)
	return out


## On / off ramp pairs: the off-ramp, then pair_gap_m later the on-ramp, both on
## straight-ish road (radius >= ramp_min_radius_m) clear of gantries, tunnels, the bridge
## and lane changes (the gap between them is ordinary road and may hold a gantry). The search starts at a seeded point of the window and steps along
## it (wrapping inside it); an edit pins the off-ramp.
func _place_ramps(rng: Rng, S: float) -> void:
	var o := _out
	var need := _def.off_ramp_length_m + _def.ramp_pair_gap_m + _def.on_ramp_length_m
	var k_max := 1.0 / _def.ramp_min_radius_m
	for p in _def.ramp_sections.size():
		var sec := _def.ramp_sections[p]
		var w0 := S * float(sec) + _def.ramp_window_start_m[p]
		var w1 := S * float(sec) + _def.ramp_window_end_m[p]
		var room := w1 - w0 - need
		var u := rng.unit()
		var found := -1.0
		if room >= 0.0:
			var steps := int(floor(room / _def.placement_step_m)) + 1
			var first := int(floor(u * float(steps)))
			for t in steps:
				var c := w0 + float((first + t) % steps) * _def.placement_step_m
				var c_on := c + _def.off_ramp_length_m + _def.ramp_pair_gap_m
				if o.max_abs_curvature(c, c + _def.off_ramp_length_m) <= k_max \
						and o.max_abs_curvature(c_on, c_on + _def.on_ramp_length_m) <= k_max \
						and _is_free(c, c + _def.off_ramp_length_m) and _is_free(c_on, c_on + _def.on_ramp_length_m):
					found = c
					break
		var generated := found - S * float(sec) if found >= 0.0 else _def.ramp_window_start_m[p]
		if found < 0.0:
			_issue("ramp pair %d: no straight-ish free stretch in its window" % p)
		var rel := _param("ramp/%d/off_m" % p, generated, _def.ramp_window_start_m[p], _def.ramp_window_end_m[p] - need,
			S * float(sec) + generated)
		var off_s := q_mm(S * float(sec) + rel)
		var on_s := q_mm(off_s + _def.off_ramp_length_m + _def.ramp_pair_gap_m)
		for kind: int in [LoopLayout.RAMP_OFF, LoopLayout.RAMP_ON]:
			o.ramp_s.append(off_s if kind == LoopLayout.RAMP_OFF else on_s)
			o.ramp_len.append(_def.off_ramp_length_m if kind == LoopLayout.RAMP_OFF else _def.on_ramp_length_m)
			o.ramp_kind.append(kind)
			o.ramp_pair.append(p)
			o.ramp_section.append(sec)
		_busy(off_s, off_s + _def.off_ramp_length_m, _def.feature_margin_m)
		_busy(on_s, on_s + _def.on_ramp_length_m, _def.feature_margin_m)


## One road works zone per section (taper, closed stretch, taper), placed like the ramps.
func _place_closures(rng: Rng, S: float) -> void:
	var o := _out
	var need := _def.closure_taper_m * 2.0 + _def.closure_length_m
	for j in _def.sections.size():
		var w0 := S * float(j) + _def.closure_window_start_m
		var w1 := S * float(j) + _def.closure_window_end_m
		var room := w1 - w0 - need
		var u := rng.unit()
		var found := -1.0
		if room >= 0.0:
			var steps := int(floor(room / _def.placement_step_m)) + 1
			var first := int(floor(u * float(steps)))
			for t in steps:
				var c := w0 + float((first + t) % steps) * _def.placement_step_m
				if _is_free(c, c + need):
					found = c
					break
		var generated := found - S * float(j) if found >= 0.0 else _def.closure_window_start_m
		if found < 0.0:
			_issue("road works %d: no free stretch in its window" % j)
		var rel := _param("closure/%d/start_m" % j, generated, 0.0, S - need, S * float(j) + generated)
		var s0 := q_mm(S * float(j) + rel)
		o.closure_s0.append(s0)
		o.closure_s1.append(q_mm(s0 + need))
		o.closure_section.append(j)
		_busy(s0, s0 + need, _def.feature_margin_m)
