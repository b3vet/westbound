class_name LoopValidator
extends RefCounted
# lint: sim
## Checks a generated loop against the loop map's rules (N3.1). Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map; World → Road (radius >= 1,200 m,
## grades <= 5 %); Cameras → Glare rule (relaxed for the loop, docs/LOOP_MAP.md).
## The loop editor shows the list after every edit, the export refuses a loop with
## errors, and tests/road/test_loop_road_path.gd asserts it is empty for loop_v1.
##
##   var errors := LoopValidator.validate(road, tuning)   # [] = valid
##
## Each check is also its own static function (tests name what failed).

## Relative slack on the tuning limits (float noise of the table, not tuning).
const LIMIT_SLACK := 1e-9   # lint: allow-number numeric tolerance, not tuning


static func validate(road: LoopRoadPath, tuning: Tuning) -> PackedStringArray:
	var out := PackedStringArray()
	out.append_array(road.layout.issues)
	out.append_array(check_closure(road))
	out.append_array(check_limits(road, tuning.road))
	out.append_array(check_lengths(road))
	out.append_array(check_lanes(road, tuning.road))
	out.append_array(check_tunnels_and_bridge(road))
	out.append_array(check_ramps(road))
	out.append_array(check_sectors(road))
	out.append_array(check_closures(road))
	out.append_array(check_glare(road, tuning.road))
	return out


## Position, heading, curvature, elevation and grade continuity at the seam.
static func check_closure(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	var d := road.def
	if o.closure_residual_m >= d.closure_max_error_m:
		out.append("closure: position error %s m (limit %s)" % [String.num_scientific(o.closure_residual_m), String.num_scientific(d.closure_max_error_m)])
	if o.closure_heading_error >= d.heading_max_error_rad:
		out.append("closure: heading error %s rad" % String.num_scientific(o.closure_heading_error))
	if absf(o.k[o.n] - o.k[0]) > 0.0 or absf(o.k[0]) > 0.0:
		out.append("closure: curvature at the seam %s / %s (must be a straight)" % [o.k[0], o.k[o.n]])
	if o.closure_elevation_error >= d.closure_max_error_m:
		out.append("closure: elevation error %s m" % String.num_scientific(o.closure_elevation_error))
	if o.closure_grade_error >= d.heading_max_error_rad:
		out.append("closure: grade error %s" % String.num_scientific(o.closure_grade_error))
	if absf(absf(o.total_turn) - TAU) > 0.0:
		out.append("closure: the loop turns %.6f rad, not one full turn" % o.total_turn)
	return out


## Radius, grade, vertical curves and straights against the road tuning.
static func check_limits(road: LoopRoadPath, rt: RoadTuning) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	var k_max := rt.max_curvature() * (1.0 + LIMIT_SLACK)
	var g_max := rt.max_grade_frac() * (1.0 + LIMIT_SLACK)
	for i in o.n + 1:
		if absf(o.k[i]) > k_max:
			out.append("radius %.0f m < %.0f m at s %.0f" % [1.0 / absf(o.k[i]), rt.min_curve_radius_m, float(i) * o.dx])
			break
	for i in o.n + 1:
		if absf(o.g[i]) > g_max:
			out.append("grade %.2f %% > %.2f %% at s %.0f" % [o.g[i] * Units.PCT, rt.max_grade_pct, float(i) * o.dx])
			break
	for i in o.pvi_s.size():
		if o.pvi_radius[i] < rt.crest_vertical_radius_min_m:
			out.append("vertical curve at s %.0f: radius %.0f m < %.0f m" % [o.pvi_s[i], o.pvi_radius[i],
				rt.crest_vertical_radius_min_m])
	for i in o.straight_len.size():
		if o.straight_len[i] < road.def.straight_min_m:
			out.append("straight at s %.0f is %.0f m (< %.0f m)" % [o.straight_s0[i], o.straight_len[i],
				road.def.straight_min_m])
	return out


## Loop length and section lengths against the handoff (about 25 km; 5 x 5 km).
static func check_lengths(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var d := road.def
	var L := road.length()
	if L < d.length_min_m or L > d.length_max_m:
		out.append("loop length %.0f m outside %.0f..%.0f m" % [L, d.length_min_m, d.length_max_m])
	for j in road.section_count():
		var len_j := road.layout.section_length_m
		if absf(len_j - d.spec_section_length_m) > d.spec_section_length_m * d.section_length_tolerance_frac:
			out.append("section %d is %.0f m (spec %.0f m +- %.0f %%)" % [j, len_j, d.spec_section_length_m,
				d.section_length_tolerance_frac * Units.PCT])
	return out


## Lane changes are tapered and stay out of tunnels and off the bridge; a narrowed
## tunnel's drop tapers before its portal and its lanes come back after its exit.
static func check_lanes(road: LoopRoadPath, rt: RoadTuning) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	for i in o.lane_s.size():
		var s0 := o.lane_s[i]
		var s1 := s0 + o.lane_taper[i]
		if o.lane_taper[i] <= 0.0:
			out.append("lane change at s %.0f has no taper" % s0)
		if o.zones_meet(s0, s1, o.bridge_s0, o.bridge_s1, 0.0):
			out.append("lane change at s %.0f is on the bridge" % s0)
		for t in o.tunnel_s0.size():
			if o.zones_meet(s0, s1, o.tunnel_s0[t], o.tunnel_s1[t], 0.0):
				out.append("lane change at s %.0f is inside tunnel %d" % [s0, t])
	for t in o.tunnel_s0.size():
		var t0 := o.tunnel_s0[t]
		var t1 := o.tunnel_s1[t]
		for s: float in [t0, (t0 + t1) * 0.5, t1 - rt.sample_spacing_m]:
			if road.lane_count(s) != o.tunnel_lanes[t]:
				out.append("tunnel %d has %d lanes at s %.0f, not %d" % [t, road.lane_count(s), s, o.tunnel_lanes[t]])
				break
		var outside := o.section_lanes[o.section_at(t0)]
		if o.tunnel_lanes[t] < outside:
			# The narrowing must be complete (full taper) tunnel_lane_lead_m before the portal.
			var edge := road.lanes_right_edge_d(t0 - rt.tunnel_lane_lead_m)
			var want := road.lanes_left_edge_d(t0) + float(o.tunnel_lanes[t]) * road.lane_width(t0)
			if absf(edge - want) > LIMIT_SLACK:
				out.append("tunnel %d: the lane drop has not finished %.0f m before the portal" % [t, rt.tunnel_lane_lead_m])
	return out


static func check_tunnels_and_bridge(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	var d := road.def
	for t in o.tunnel_s0.size():
		if o.section_at(o.tunnel_s0[t]) != d.tunnel_section or o.section_at(o.tunnel_s1[t]) != d.tunnel_section:
			out.append("tunnel %d is not inside section %d" % [t, d.tunnel_section])
		for k in o.sector_s.size():
			if o.zones_meet(o.tunnel_s0[t], o.tunnel_s1[t], o.sector_s[k], o.sector_s[k], d.gantry_clearance_m):
				out.append("tunnel %d is within %.0f m of sector gantry %d" % [t, d.gantry_clearance_m, k])
		if o.zones_meet(o.tunnel_s0[t], o.tunnel_s1[t], o.bridge_s0, o.bridge_s1, 0.0):
			out.append("tunnel %d meets the bridge" % t)
	if o.section_at(o.bridge_s0) != d.bridge_section or o.section_at(o.bridge_s1) != d.bridge_section:
		out.append("the bridge (%.0f..%.0f) is not inside section %d" % [o.bridge_s0, o.bridge_s1, d.bridge_section])
	if d.bridge_sector < o.sector_style.size() and o.sector_style[d.bridge_sector] != BiomeDef.LANDMARK_SUSPENSION_BRIDGE:
		out.append("sector %d (the bridge) is not a suspension bridge" % d.bridge_sector)
	return out


## Ramps: on straight-ish road, clear of tunnels, the bridge, lane tapers and gantries.
static func check_ramps(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	var d := road.def
	var k_max := 1.0 / d.ramp_min_radius_m
	for i in o.ramp_s.size():
		var s0 := o.ramp_s[i]
		var s1 := s0 + o.ramp_len[i]
		var label := "ramp %d (%s, s %.0f)" % [i, "off" if o.ramp_kind[i] == LoopLayout.RAMP_OFF else "on", s0]
		var k := o.max_abs_curvature(s0, s1)
		if k > k_max:
			out.append("%s is on a bend (radius %.0f m < %.0f m)" % [label, 1.0 / k, d.ramp_min_radius_m])
		for t in o.tunnel_s0.size():
			if o.zones_meet(s0, s1, o.tunnel_s0[t], o.tunnel_s1[t], 0.0):
				out.append("%s is in tunnel %d" % [label, t])
		if o.zones_meet(s0, s1, o.bridge_s0, o.bridge_s1, 0.0):
			out.append("%s is on the bridge" % label)
		for c in o.lane_s.size():
			if o.zones_meet(s0, s1, o.lane_s[c], o.lane_s[c] + o.lane_taper[c], 0.0):
				out.append("%s meets the lane change at s %.0f" % [label, o.lane_s[c]])
		for k2 in o.sector_s.size():
			if o.zones_meet(s0, s1, o.sector_s[k2], o.sector_s[k2], d.gantry_clearance_m):
				out.append("%s is within %.0f m of sector gantry %d" % [label, d.gantry_clearance_m, k2])
	return out


## Sector gantries: the count, even spacing (+-tolerance), the start / finish in section 0.
static func check_sectors(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	var d := road.def
	var n := o.sector_s.size()
	if n != d.sector_count:
		out.append("%d sector gantries, not %d" % [n, d.sector_count])
		return out
	var even := road.length() / float(n)
	for k in n:
		var gap := road.wrap_s(o.sector_s[(k + 1) % n] - o.sector_s[k])
		if absf(gap - even) > even * d.sector_spacing_tolerance_frac:
			out.append("sectors %d -> %d are %.0f m apart (even %.0f m +- %.0f %%)" % [k, (k + 1) % n, gap, even,
				d.sector_spacing_tolerance_frac * Units.PCT])
	if n > 0 and o.section_at(o.sector_s[0]) != 0:
		out.append("the start / finish gantry is not in section 0")
	return out


## Road works: one per section, clear of tunnels, the bridge, ramps and lane changes.
static func check_closures(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	if o.closure_s0.size() != road.section_count():
		out.append("%d road works zones for %d sections" % [o.closure_s0.size(), road.section_count()])
	for i in o.closure_s0.size():
		var s0 := o.closure_s0[i]
		var s1 := o.closure_s1[i]
		for t in o.tunnel_s0.size():
			if o.zones_meet(s0, s1, o.tunnel_s0[t], o.tunnel_s1[t], 0.0):
				out.append("road works %d is in tunnel %d" % [i, t])
		if o.zones_meet(s0, s1, o.bridge_s0, o.bridge_s1, 0.0):
			out.append("road works %d is on the bridge" % i)
		for r in o.ramp_s.size():
			if o.zones_meet(s0, s1, o.ramp_s[r], o.ramp_s[r] + o.ramp_len[r], 0.0):
				out.append("road works %d meets ramp %d" % [i, r])
		for c in o.lane_s.size():
			if o.zones_meet(s0, s1, o.lane_s[c], o.lane_s[c] + o.lane_taper[c], 0.0):
				out.append("road works %d meets the lane change at s %.0f" % [i, o.lane_s[c]])
	return out


## The loop's glare rule (docs/LOOP_MAP.md): no straight heads within
## sun_offset_min_deg of due west, and a section with a sea keeps its straights up to
## its last bend in the 15-30 deg band on the sea's (the sun's) side.
static func check_glare(road: LoopRoadPath, rt: RoadTuning) -> PackedStringArray:
	var out := PackedStringArray()
	var o := road.layout
	var lo := deg_to_rad(rt.sun_offset_min_deg)
	var hi := deg_to_rad(rt.sun_offset_max_deg)
	for i in o.n:
		if o.k[i] != 0.0:
			continue
		var off := wrapf(o.h[i], -PI, PI)
		if absf(off) < lo:
			out.append("straight at s %.0f heads %.1f deg from the sun (glare)" % [float(i) * o.dx, rad_to_deg(off)])
			break
	for j in road.section_count():
		var b := BiomePlan.load_biome(o.section_ids[j])
		var side := b.water.road_sun_side() if b != null and b.water != null else 0
		if side == 0:
			continue
		var s0 := road.section_start(j)
		var s1 := s0 + o.section_length_m
		for bi in o.bend_s0.size():
			if o.bend_section[bi] == j:
				s1 = o.bend_s0[bi]   # the last bend of the section starts here
		for i in range(int(ceil(s0 / o.dx)), int(floor(s1 / o.dx))):
			if o.k[i] != 0.0:
				continue
			var off := wrapf(o.h[i], -PI, PI) * float(side)
			if off < lo or off > hi:
				out.append("section %d: straight at s %.0f is %.1f deg off the sun (band %.0f..%.0f on its sea side)" % [
					j, float(i) * o.dx, rad_to_deg(off), rt.sun_offset_min_deg, rt.sun_offset_max_deg])
				break
	return out
