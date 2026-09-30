extends WBTest
## TrafficRuleChecker's collision criterion (WP9.6, ACCEPTANCE F1 / O10; the Rust soak's
## N4.1 criterion, docs/SERVER.md): traffic pairs are gated on the sim's un-yawed bodies
## and on the heading clients render (TrafficViewTuning), while WP6.8's +-0.28 rad box
## heading is reported (yaw_only_pairs), not gated.

var tuning: Tuning
var reg: TrafficRegistry


func before_all() -> void:
	tuning = Tuning.load_default()
	reg = TrafficRegistry.load_default(tuning.traffic)


## A two-vehicle TrafficState: slot a at (s_a, d_a) with v_a / v_lat_a, slot b at (s_b, d_b) with v_b.
func _pair(type_a: StringName, s_a: float, d_a: float, v_a: float, v_lat_a: float,
		type_b: StringName, s_b: float, d_b: float, v_b: float) -> TrafficState:
	var ts := TrafficState.new(4)
	var ss := PackedFloat64Array([s_a, s_b])
	var dd := PackedFloat64Array([d_a, d_b])
	var vv := PackedFloat64Array([v_a, v_b])
	var types: Array[StringName] = [type_a, type_b]
	for k in 2:
		var i := ts.allocate()
		var t := reg.types[reg.type_index(types[k])]
		ts.s[i] = ss[k]
		ts.d[i] = dd[k]
		ts.v[i] = vv[k]
		ts.length[i] = t.length_m
		ts.width[i] = t.width_m
		ts.profile_id[i] = reg.profile_index(&"commuter")
		ts.type_id[i] = reg.type_index(types[k])
		ts.flags[i] = TrafficState.FLAG_BLINKER_LEFT
	ts.v_lat[0] = v_lat_a
	return ts


func _checker() -> TrafficRuleChecker:
	return TrafficRuleChecker.new(tuning, reg, StraightRoadPath.new(3, tuning.road), 4.5, 1.9)


func _observe(ts: TrafficState) -> TrafficRuleChecker:
	var c := _checker()
	var player := VehicleState.new()
	player.s = -1000.0
	c.observe(0.0, ts, player)
	return c


func test_view_yaw_follows_traffic_view_tuning() -> void:
	var c := _checker()
	var floor_v := tuning.traffic_view.yaw_min_speed_mps()
	var cap := deg_to_rad(tuning.traffic_view.yaw_max_deg)
	near(c.view_yaw(0.0, 0.9), atan2(0.9, floor_v), 1e-12, "a crawling car: the speed is floored")
	near(c.view_yaw(30.0, -1.5), atan2(-1.5, 30.0), 1e-12, "at traffic speeds: the path's heading")
	near(c.view_yaw(0.0, 50.0), cap, 1e-12, "clamped to yaw_max")
	eq(c.view_yaw(0.0, 0.0), 0.0, "standing still")
	lt(c.view_yaw(2.5, 0.9), TrafficRuleChecker.box_yaw(2.5, 0.9), "a crawling car renders straighter than the old box")


func test_crawling_semi_beside_a_fast_lane_is_reported_not_gated() -> void:
	# ACCEPTANCE F1 (soak run 1, t = 97.8 s): a 16 m semi merging lane 2 -> 1 at 9 km/h
	# near the end of its move (v_lat ~0.9 m/s, center d 7.30), a pickup passing in lane 0
	# (d 3.50) at 95 km/h beside the semi's front half. The bodies are 1.5 m apart; the
	# old box heading (clamped at 0.28 rad) swings the cab corner into lane 0.
	var v_semi := Units.kmh_to_mps(9.0)
	var ts := _pair(&"semi", 100.0, 7.30, v_semi, -0.9, &"pickup", 106.0, 3.50, Units.kmh_to_mps(95.0))
	var c := _checker()
	check(c._overlap(100.0, 7.30, 16.0, 2.55, TrafficRuleChecker.box_yaw(v_semi, -0.9),
		106.0, 3.50, 5.4, 2.0, 0.0), "the +-0.28 rad box heading overlaps (the F1 count)")
	var seen := _observe(ts)
	eq(seen.collision_pairs, 0, "gated: no body overlap, and the rendered heading clears lane 0")
	eq(seen.collisions, 0)
	eq(seen.body_overlap_pairs, 0)
	eq(seen.yaw_only_pairs, 1, "reported: one heading-only pair-tick")
	near(seen.yaw_only_max_speed, Units.kmh_to_mps(95.0), 1e-9, "the faster car's speed")
	eq(seen.total_violations(), 0, "heading-only pair-ticks are not violations")


func test_real_contacts_still_count() -> void:
	# A coach's body moving sideways into a car beside it.
	var beside := _observe(_pair(&"coach", 100.0, 8.9, 0.0, -1.8, &"sedan", 100.0, 7.1, 0.0))
	eq(beside.collision_pairs, 1, "a body overlap beside it is a collision")
	eq(beside.body_overlap_pairs, 1)
	eq(beside.yaw_only_pairs, 0)
	# A rear-end at speed.
	var rear := _observe(_pair(&"sedan", 100.0, 7.1, 30.0, 0.0, &"sedan", 104.5, 7.1, 20.0))
	eq(rear.collision_pairs, 1, "a rear-end is a collision")
	eq(rear.collisions, 1)


func test_rendered_heading_overlap_counts() -> void:
	# A sedan at 60 km/h cutting across hard (v_lat 4 m/s: drawn at 13.5 degrees), its
	# front corner over a car 5 cm beside it whose body it does not touch: clients would
	# draw the touch, so it is gated.
	var v := Units.kmh_to_mps(60.0)
	var c := _checker()
	var yaw := c.view_yaw(v, -4.0)
	var d_b := 7.1 - (1.85 + 1.85) * 0.5 - 0.05
	check(not c._overlap(100.0, 7.1, 4.8, 1.85, 0.0, 104.2, d_b, 4.8, 1.85, 0.0), "bodies apart")
	if check(c._overlap(100.0, 7.1, 4.8, 1.85, yaw, 104.2, d_b, 4.8, 1.85, 0.0), "the drawn boxes overlap"):
		var seen := _observe(_pair(&"sedan", 100.0, 7.1, v, -4.0, &"sedan", 104.2, d_b, v))
		eq(seen.collision_pairs, 1, "a rendered overlap is a collision")
		eq(seen.body_overlap_pairs, 0)
