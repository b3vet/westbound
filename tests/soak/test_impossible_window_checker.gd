extends WBTest
## The impossible-window oracle (ImpossibleWindowChecker) on hand-built layouts. Spec:
## Traffic → Passability guarantee (8 s, 0.25 s steps, lane centers and half-lanes,
## minimum speed, 0.3 m hull clearance); Tests (headless): "zero impossible windows".
## Definition: tests/fixtures/traffic/impossible_window_checker.gd and docs/SOAK.md.

var t: Tuning
var reg: TrafficRegistry
var car: CarDef


func before_all() -> void:
	t = Tuning.load_default()
	reg = TrafficRegistry.load_default(t.traffic)
	car = load("res://data/cars/falcon_gt.tres") as CarDef


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


func _road(lanes: int) -> StraightRoadPath:
	return StraightRoadPath.new(lanes, t.road)


func _player(road: RoadPath, lane: int, kmh: float) -> VehicleState:
	var p := VehicleState.new()
	p.s = 0.0
	p.d = road.lane_center_d(lane, 0.0)
	p.v = _kmh(kmh)
	return p


func _add(ts: TrafficState, road: RoadPath, s: float, lane: int, kmh: float, type: StringName = &"semi",
		profile: StringName = &"truck") -> int:
	var i := ts.allocate()
	var tid := reg.type_index(type)
	ts.s[i] = s
	ts.d[i] = road.lane_center_d(lane, s)
	ts.v[i] = _kmh(kmh)
	ts.v0[i] = _kmh(kmh)
	ts.length[i] = reg.length[tid]
	ts.width[i] = reg.width[tid]
	ts.lane[i] = lane
	ts.target_lane[i] = lane
	ts.type_id[i] = tid
	ts.profile_id[i] = reg.profile_index(profile)
	return i


func _check(ts: TrafficState, road: RoadPath, player: VehicleState) -> bool:
	return ImpossibleWindowChecker.new(t, reg, car).is_passable(ts, player, road)


func test_open_road_is_passable() -> void:
	var road := _road(3)
	check(_check(TrafficState.new(60), road, _player(road, 1, 150.0)))


func test_slow_wall_across_every_lane_is_impossible() -> void:
	var road := _road(3)
	var ts := TrafficState.new(60)
	for l in 3:
		_add(ts, road, 30.0, l, 85.0)
	var iw := ImpossibleWindowChecker.new(t, reg, car)
	check(not iw.is_passable(ts, _player(road, 1, 150.0), road), "85 km/h across all lanes: below the minimum speed")
	lt(iw.fail_t, t.passability.horizon_s)
	eq(iw.impossible, 1)
	check(not iw.started_in_contact)


func test_wall_above_minimum_speed_is_passable() -> void:
	var road := _road(3)
	var ts := TrafficState.new(60)
	for l in 3:
		_add(ts, road, 80.0, l, 105.0)
	check(_check(ts, road, _player(road, 1, 150.0)), "the player may slow to 105 km/h behind it")


func test_one_open_lane_is_enough() -> void:
	var road := _road(3)
	for open_lane in 3:
		var ts := TrafficState.new(60)
		for l in 3:
			if l != open_lane:
				_add(ts, road, 60.0, l, 85.0)
		check(_check(ts, road, _player(road, 1, 150.0)), "lane %d open" % open_lane)


func test_a_gap_too_short_for_the_car_is_closed() -> void:
	# Two slow walls 12 m apart (bumper to bumper) in the only lane beside the player's
	# blocked one: the car (4.5 m + 2 x 0.3 m) can't use a gap it can't reach in time.
	var road := _road(2)
	var ts := TrafficState.new(60)
	_add(ts, road, 40.0, 0, 85.0)
	_add(ts, road, 40.0, 1, 85.0)
	_add(ts, road, 40.0 + 16.0 + 3.0, 0, 85.0)
	_add(ts, road, 40.0 + 16.0 + 3.0, 1, 85.0)
	check(not _check(ts, road, _player(road, 1, 150.0)))


func test_no_tunneling_through_short_hulls() -> void:
	# Motorbikes (2.2 m) across both lanes and on the lane line at 250 km/h: the search
	# must not jump over them between sub-steps.
	var road := _road(2)
	for kmh: float in [0.0, 60.0, 101.0]:
		var ts := TrafficState.new(60)
		_add(ts, road, 60.0, 0, kmh, &"motorbike", &"motorbike")
		_add(ts, road, 60.0, 1, kmh, &"motorbike", &"motorbike")
		var b := _add(ts, road, 60.0, 0, kmh, &"motorbike", &"motorbike")
		ts.d[b] = road.lane_center_d(0, 0.0) + road.lane_width(0.0) * 0.5
		eq(_check(ts, road, _player(road, 0, 250.0)), kmh > 100.0, "bikes at %.0f km/h" % kmh)


func test_two_bikes_side_by_side_leave_room_on_the_line() -> void:
	# Lane centers 3.6 m apart, bikes 0.8 m wide: 2.8 m between them > 1.9 m + 2 x 0.3 m.
	var road := _road(2)
	var ts := TrafficState.new(60)
	_add(ts, road, 60.0, 0, 60.0, &"motorbike", &"motorbike")
	_add(ts, road, 60.0, 1, 60.0, &"motorbike", &"motorbike")
	check(_check(ts, road, _player(road, 0, 150.0)))


func test_staggered_slow_vehicles_leave_a_weave() -> void:
	# Slow trucks staggered 60 m apart, alternating lanes: a lane change every gap.
	var road := _road(2)
	var ts := TrafficState.new(60)
	for k in 5:
		_add(ts, road, 60.0 + 70.0 * float(k), k % 2, 85.0)
	check(_check(ts, road, _player(road, 1, 150.0)))


func test_vehicles_behind_the_player_are_ignored() -> void:
	# A fast car right behind follows the player (IDM, rear-end prevention).
	var road := _road(2)
	var ts := TrafficState.new(60)
	_add(ts, road, -8.0, 1, 200.0, &"sedan", &"aggressive")
	check(_check(ts, road, _player(road, 1, 110.0)))


func test_signaled_lane_change_is_predicted() -> void:
	# Lane 1: a slow truck ahead. Lane 0: open, but a slow car in lane 1 beside the gap
	# signals into lane 0 and its signal ends now: it will close lane 0 too.
	var road := _road(2)
	for signaling: bool in [false, true]:
		var ts := TrafficState.new(60)
		_add(ts, road, 40.0, 1, 85.0)
		var c := _add(ts, road, 20.0, 1, 85.0, &"sedan", &"cruiser")
		ts.s[c] = 40.0 - 16.0 * 0.5 - 4.8 * 0.5 - 3.0
		if signaling:
			ts.lc_state[c] = TrafficState.LaneChange.SIGNALING
			ts.target_lane[c] = 0
			ts.lc_duration[c] = 1.0
			ts.lc_timer[c] = 1.0
			ts.flags[c] = TrafficState.FLAG_BLINKER_LEFT
		eq(_check(ts, road, _player(road, 1, 150.0)), not signaling,
			"signaling slow car closes the open lane" if signaling else "lane 0 open")


func test_moving_lane_change_spans_both_lanes() -> void:
	var road := _road(2)
	var ts := TrafficState.new(60)
	_add(ts, road, 60.0, 1, 85.0)
	var c := _add(ts, road, 60.0, 1, 85.0, &"coach", &"bus")
	# Halfway through a move from lane 0 into lane 1 (the lane change lasts well past the horizon's start).
	ts.lane[c] = 0
	ts.target_lane[c] = 1
	ts.lc_state[c] = TrafficState.LaneChange.MOVING
	ts.lc_start_d[c] = road.lane_center_d(0, 0.0)
	ts.lc_duration[c] = 3.0
	ts.lc_timer[c] = 0.3
	var u := 0.1
	ts.d[c] = road.lane_center_d(0, 0.0) + road.lane_width(0.0) * u * u * (3.0 - 2.0 * u)
	ts.s[c] = 60.0 + 30.0
	ts.s[0] = 60.0
	check(_check(ts, road, _player(road, 0, 150.0)), "the bus ends in lane 1: lane 0 opens")


func test_player_already_in_contact_is_flagged() -> void:
	var road := _road(2)
	var ts := TrafficState.new(60)
	_add(ts, road, 3.0, 1, 85.0, &"sedan", &"cruiser")
	_add(ts, road, 40.0, 0, 85.0)
	var iw := ImpossibleWindowChecker.new(t, reg, car)
	iw.is_passable(ts, _player(road, 1, 150.0), road)
	check(iw.started_in_contact)


func test_a_player_below_minimum_speed_may_hold_its_speed() -> void:
	# The soak's typical case: keeping its lane behind an 86 km/h truck in the slow lane
	# (so at 86 km/h), a 95 km/h coach right beside it in lane 1. Holding 86 km/h lets
	# the coach pull away, then lane 1 is open. Demanding 100 km/h at once would make it
	# a wall: the player can neither drop back behind the coach nor pass it before
	# reaching the truck.
	var road := _road(3)
	var ts := TrafficState.new(60)
	_add(ts, road, 25.0, 2, 86.0)
	_add(ts, road, 0.0, 1, 95.0, &"coach", &"bus")
	check(_check(ts, road, _player(road, 2, 86.0)), "at 86 km/h it may hold 86 km/h")
	check(not _check(ts, road, _player(road, 2, 100.0)), "at 100 km/h (the minimum) it is a wall")


# ---------------------------------------------------------------- WP6.10: lane ends, closures, acceleration

## Lane drops: the procedural road's seed and where lane 2 ends (3 -> 2 lanes), as in
## test_passability.gd.
const DROP_SEED := 620411
const DROP_S := 20.0


func _drop_road(drop: bool) -> ProceduralRoadPath:
	var r := ProceduralRoadPath.new(RunContext.new(DROP_SEED, RunContext.MODE_JOURNEY, t))
	if drop:
		r.schedule_lane_count(DROP_S, 2, t.road.lane_taper_length_m)
	r.ensure_generated_to(DROP_S + 2000.0)
	return r


func _zone_sim(road: RoadPath) -> TrafficSim:
	return TrafficSim.new(RunContext.new(DROP_SEED, RunContext.MODE_JOURNEY, t), road, reg)


func test_the_only_open_lane_ending_is_impossible() -> void:
	# Trucks side by side in lanes 0 and 1 below the minimum speed; lane 2 is the way
	# past them. Without the drop it passes; when lane 2 ends before the trucks are
	# passed it does not (before WP6.10 the grid kept lane 2 for the whole horizon).
	for drop: bool in [false, true]:
		var road := _drop_road(drop)
		eq(road.lane_count(0.0), 3)
		var ts := TrafficState.new(60)
		_add(ts, road, 35.0, 0, 80.0)
		_add(ts, road, 35.0, 1, 80.0)
		var iw := ImpossibleWindowChecker.new(t, reg, car)
		eq(iw.is_passable(ts, _player(road, 2, 110.0), road), not drop,
			"lane 2 ends before the trucks are passed" if drop else "lane 2 open all along")
		check(not iw.started_in_contact, "the player starts clear of the lane end")
		if drop:
			gt(iw.road_obstacles, 0, "the lane end is a road obstacle")


func test_an_ending_lane_with_room_beside_it_is_passable() -> void:
	var road := _drop_road(true)
	check(_check(TrafficState.new(60), road, _player(road, 2, 110.0)), "the player leaves lane 2 in time")


func test_a_lane_that_opens_ahead_is_on_the_grid() -> void:
	# 2 lanes widening to 3 ahead: trucks side by side in lanes 0 and 1 far enough ahead
	# for the new lane 2 to exist before the player reaches them.
	var taper := t.road.lane_taper_length_m
	var road := ProceduralRoadPath.new(RunContext.new(DROP_SEED, RunContext.MODE_JOURNEY, t))
	road.schedule_lane_count(0.0, 2, taper)
	var s_p := taper + 50.0
	road.schedule_lane_count(s_p + DROP_S, 3, taper)
	road.ensure_generated_to(s_p + 2000.0)
	eq(road.lane_count(s_p), 2)
	var ts := TrafficState.new(60)
	var at := s_p + DROP_S + taper + 40.0
	_add(ts, road, at, 0, 80.0)
	_add(ts, road, at, 1, 80.0)
	var p := _player(road, 1, 150.0)
	p.s = s_p
	var iw := ImpossibleWindowChecker.new(t, reg, car)
	check(iw.is_passable(ts, p, road), "the new lane 2 is the way past")
	eq(iw.positions, 5, "3 lanes on the grid")


func test_a_lane_the_sim_closes_is_not_a_path() -> void:
	# Road works close lane 2 from 60 m (the sim's closures): lane 2 was the way past
	# slow trucks side by side in lanes 0 and 1.
	for closed: bool in [false, true]:
		var road := _road(3)
		var sim := _zone_sim(road)
		if closed:
			sim.add_lane_closure(2, 60.0, 600.0, 1)
		var ts := TrafficState.new(60)
		_add(ts, road, 35.0, 0, 80.0)
		_add(ts, road, 35.0, 1, 80.0)
		var iw := ImpossibleWindowChecker.new(t, reg, car)
		iw.zones = sim
		eq(iw.is_passable(ts, _player(road, 2, 110.0), road), not closed,
			"lane 2 closed ahead of the trucks" if closed else "lane 2 open")


func test_a_closure_blocks_its_lane_and_half_lanes_only() -> void:
	# Lane 1 closed ahead with slow trucks ahead in lanes 0 and 2 beyond the closure's
	# start: the half-lanes beside lane 1 are closed too, so the player can't squeeze
	# between the trucks along the lane lines; with lane 0 free it passes.
	var road := _road(3)
	var sim := _zone_sim(road)
	sim.add_lane_closure(1, 80.0, 600.0, 1)
	var iw := ImpossibleWindowChecker.new(t, reg, car)
	iw.zones = sim
	check(iw.is_passable(TrafficState.new(60), _player(road, 1, 110.0), road), "a closed lane with open neighbours")
	var ts := TrafficState.new(60)
	_add(ts, road, 30.0, 0, 80.0, &"motorbike", &"motorbike")
	_add(ts, road, 30.0, 2, 80.0, &"motorbike", &"motorbike")
	check(not iw.is_passable(ts, _player(road, 1, 110.0), road),
		"slow bikes in lanes 0 and 2, lane 1 closed: the lane lines beside it are closed too")
	sim.remove_lane_closures(1)
	check(iw.is_passable(ts, _player(road, 1, 110.0), road), "lane 1 open again: passable")


func test_a_player_already_in_a_closed_lane_is_flagged() -> void:
	var road := _road(3)
	var sim := _zone_sim(road)
	sim.add_lane_closure(2, -50.0, 600.0, 1)
	var iw := ImpossibleWindowChecker.new(t, reg, car)
	iw.zones = sim
	iw.is_passable(TrafficState.new(60), _player(road, 2, 110.0), road)
	check(iw.started_in_closure and iw.started_in_contact, "inside the closure at t0: the player's own doing")
	iw.is_passable(TrafficState.new(60), _player(road, 1, 110.0), road)
	check(not iw.started_in_closure, "lane 1 is open")


func test_speed_zones_slow_the_predicted_traffic() -> void:
	# A car ahead in lane 2 at 110 km/h is the way past slow trucks in lanes 0 and 1; a
	# 60 km/h zone on lane 2 (a toll's booth lane) turns it into a wall.
	for zone: bool in [false, true]:
		var road := _road(3)
		var sim := _zone_sim(road)
		if zone:
			sim.add_speed_zone(2, 90.0, 800.0, _kmh(60.0), 1)
		var ts := TrafficState.new(60)
		_add(ts, road, 45.0, 0, 80.0)
		_add(ts, road, 45.0, 1, 80.0)
		_add(ts, road, 30.0, 2, 110.0, &"sedan", &"commuter")
		var iw := ImpossibleWindowChecker.new(t, reg, car)
		iw.zones = sim
		eq(iw.is_passable(ts, _player(road, 2, 100.0), road), not zone,
			"the car slows to 60 km/h in the zone" if zone else "following the car past the trucks")


func test_traffic_accelerates_toward_its_desired_speed() -> void:
	# The WP6.1 soak's 4-lane false positive (run 247): the player at 100 km/h 13 m
	# behind a motorbike at 91 km/h whose platoon was accelerating (desired >= 140 km/h),
	# the other lanes busy. Constant speeds made it a wall; bounded acceleration toward
	# the desired speed lets it pull away. At its desired speed it stays a wall.
	var road := _road(3)
	for v0_kmh: float in [140.0, 91.0]:
		var ts := TrafficState.new(60)
		for l: int in [1, 2]:
			for k in 8:
				_add(ts, road, 6.0 + 20.0 * float(k), l, 85.0)
		var b := _add(ts, road, 13.0 + (2.2 + car.length_m) * 0.5, 0, 91.0, &"motorbike", &"motorbike")
		ts.v0[b] = _kmh(v0_kmh)
		eq(_check(ts, road, _player(road, 0, 100.0)), v0_kmh > 100.0, "bike desiring %.0f km/h" % v0_kmh)


func test_a_follower_never_drives_through_its_leader() -> void:
	# A fast car (desired 200 km/h) right behind a slow truck in lane 1, a slow truck in
	# lane 0: the fast car queues behind the truck, both lanes stay walls.
	var road := _road(2)
	var ts := TrafficState.new(60)
	_add(ts, road, 40.0, 0, 85.0)
	_add(ts, road, 40.0, 1, 85.0)
	var c := _add(ts, road, 40.0 - 16.0 * 0.5 - 4.8 * 0.5 - 4.0, 1, 85.0, &"sedan", &"aggressive")
	ts.v0[c] = _kmh(200.0)
	check(not _check(ts, road, _player(road, 0, 150.0)), "the queue stays behind the truck")
