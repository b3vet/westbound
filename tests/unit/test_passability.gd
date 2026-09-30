extends WBTest
## Passability (src/traffic/passability.gd). Spec: Traffic → Passability guarantee
## ("forward-simulate traffic at 10 Hz for 8 s; search player moves over a grid of
## lateral positions (lane centers and half-lanes) in 0.25 s steps, limited by the
## player car's real lane-change capability at its current speed; speed anywhere from
## minimum speed to current speed plus possible acceleration; require a path that stays
## at or above minimum speed and never comes within 0.3 m of a hull"); Architecture rules
## 4-6 (pure, deterministic, no allocations per call). Hand-built traffic on a straight
## road with the real registry and a real car's VehicleParams. docs/PASSABILITY.md.

const LANES := 3
const CAR := "res://data/cars/falcon_gt.tres"
## Lane drops: the procedural road's seed and where lane 2 ends (3 -> 2 lanes).
const DROP_SEED := 620411
const DROP_S := 20.0   # lane 2 center closes ~62 m into the 200 m taper

var tuning: Tuning
var reg: TrafficRegistry
var car: CarDef
var params: VehicleParams
var road: RoadPath
var pas: Passability
var res: Passability.Result
var traffic: TrafficState
var player: VehicleState

var truck_p: int
var semi_t: int
var bike_p: int
var bike_t: int
var commuter_p: int
var sedan_t: int
var aggressive_p: int
var sports_t: int


func before_all() -> void:
	tuning = Tuning.load_default()
	reg = TrafficRegistry.load_default(tuning.traffic)
	car = load(CAR) as CarDef
	params = VehicleParams.build(tuning, car)
	truck_p = reg.profile_index(&"truck")
	semi_t = reg.type_index(&"semi")
	bike_p = reg.profile_index(&"motorbike")
	bike_t = reg.type_index(&"motorbike")
	commuter_p = reg.profile_index(&"commuter")
	sedan_t = reg.type_index(&"sedan")
	aggressive_p = reg.profile_index(&"aggressive")
	sports_t = reg.type_index(&"sports")


func _setup(lanes: int = LANES, t: Tuning = null) -> void:
	var tun := t if t != null else tuning
	road = StraightRoadPath.new(lanes, tun.road)
	pas = Passability.new(tun, reg, road)
	pas.set_player_body(car.length_m, car.width_m)
	res = Passability.Result.new()
	traffic = TrafficState.new(tun.traffic.max_active_vehicles)
	player = VehicleState.new()


func _kmh(v: float) -> float:
	return Units.kmh_to_mps(v)


func _place_player(lane: int, s: float, v_kmh: float) -> void:
	player.reset()
	player.s = s
	player.d = road.lane_center_d(lane, s)
	player.v = _kmh(v_kmh)


## A vehicle cruising in `lane` (desired speed = its speed), or at d when given.
func _add(profile: int, type: int, lane: int, s: float, v_kmh: float, d: float = NAN) -> int:
	var i := traffic.allocate()
	traffic.s[i] = s
	traffic.d[i] = road.lane_center_d(lane, s) if is_nan(d) else d
	traffic.v[i] = _kmh(v_kmh)
	traffic.v0[i] = _kmh(v_kmh)
	traffic.length[i] = reg.length[type]
	traffic.width[i] = reg.width[type]
	traffic.lane[i] = lane
	traffic.target_lane[i] = lane
	traffic.profile_id[i] = profile
	traffic.type_id[i] = type
	return i


func _truck(lane: int, s: float, v_kmh: float = 85.0) -> int:
	return _add(truck_p, semi_t, lane, s, v_kmh)


func _record(profile: int, type: int, lane: int, s: float, v_kmh: float) -> SpawnSource.Record:
	var r := SpawnSource.Record.new()
	r.s = s
	r.lane = lane
	r.v = _kmh(v_kmh)
	r.v0 = _kmh(v_kmh)
	r.profile_id = profile
	r.type_id = type
	return r


## Minimum clearance (m) of the path to the traffic's predicted bodies is not checked
## here; the path's own consistency is: points at step_s, speeds in range, positions
## on the grid.
func _check_path_shape(what: String) -> void:
	eq(res.path_n, pas.steps() + 1, "%s: the path covers the horizon" % what)
	var min_v := minf(tuning.scoring.min_speed_mps(), player.v)
	for k in range(1, res.path_n):
		var v := (res.path_s[k] - res.path_s[k - 1]) / pas.step_s()
		if not ge(v, min_v - 1e-6, "%s: speed at step %d stays >= the minimum" % [what, k]):
			return


# ---------------------------------------------------------------- The player check

func test_empty_road_is_passable_and_the_path_drives_on() -> void:
	_setup()
	_place_player(1, 0.0, 150.0)
	check(pas.check_player(traffic, player, params, road, res), "an empty road is passable")
	_check_path_shape("empty road")
	gt(res.path_s[res.path_n - 1], player.s + tuning.scoring.min_speed_mps() * tuning.passability.horizon_s - 1.0,
		"the path moves at least at the minimum speed")
	eq(res.positions, 2 * LANES - 1, "lane centers and half-lanes: 2 x lanes - 1 positions")


func test_truck_wall_across_every_lane_is_impossible() -> void:
	_setup()
	_place_player(1, 0.0, 150.0)
	for lane in LANES:
		_truck(lane, 35.0)
	check(not pas.check_player(traffic, player, params, road, res), "trucks side by side in every lane block")
	lt(res.fail_t, tuning.passability.horizon_s, "every path ends within the horizon")
	var cut := 0.0
	for o in res.obstacles:
		cut += res.blocker_cut[o]
		check(res.blocker_src[o] >= 0, "blockers are live slots")
	gt(cut, 0.0, "the trucks are credited with the paths they cut")


func test_one_open_lane_is_passable() -> void:
	_setup()
	_place_player(1, 0.0, 150.0)
	_truck(1, 35.0)
	_truck(2, 35.0)
	check(pas.check_player(traffic, player, params, road, res), "lane 0 stays open")
	_check_path_shape("open lane")
	near(res.path_d[res.path_n - 1], road.lane_center_d(0, 0.0), 1e-6, "the path ends in the open lane")


func test_half_lane_threading_gap_is_found() -> void:
	# Slow bikes at the centers of lanes 0 and 1, a truck in lane 2: every lane is blocked,
	# but the half-lane position between lanes 0 and 1 clears both bikes.
	_setup()
	_place_player(0, 0.0, 120.0)
	_add(bike_p, bike_t, 0, 30.0, 60.0)
	_add(bike_p, bike_t, 1, 30.0, 60.0)
	_truck(2, 30.0, 60.0)
	check(pas.check_player(traffic, player, params, road, res), "the threading gap is a path")
	var half := road.lane_center_d(0, 0.0) + road.lane_width(0.0) * 0.5
	var threads := false
	for k in res.path_n:
		if absf(res.path_d[k] - half) < 1e-6 and res.path_s[k] > 30.0 and res.path_s[k] < 60.0:
			threads = true
	check(threads, "the path passes the bikes on the half-lane position")
	# Without half-lanes (lane centers only) the same traffic is a wall.
	var t: Tuning = tuning.duplicate()
	t.passability = tuning.passability.duplicate() as PassabilityTuning
	t.passability.lateral_step_lanes = 1.0
	var saved := traffic
	_setup(LANES, t)
	traffic = saved
	_place_player(0, 0.0, 120.0)
	check(not pas.check_player(traffic, player, params, road, res), "lane centers alone: no path")


func test_lane_change_capability_limits_the_moves() -> void:
	_setup()
	_place_player(0, 0.0, 150.0)
	# A slow wall close ahead in lanes 0 and 1: lane 2 is two lanes away (four half-lane
	# moves), too far at this car's capability before contact even at the minimum speed.
	_truck(0, 20.0)
	_truck(1, 20.0)
	check(not pas.check_player(traffic, player, params, road, res), "two lanes away is out of reach")
	var mt := params.move_time(player.v, road.lane_width(0.0) * 0.5)
	eq(res.move_steps, ceili(mt / tuning.passability.step_s - 1e-9),
		"a half-lane move takes the car's move time rounded up to whole steps")
	# The same wall with the open lane next door: one lane away is reachable.
	_setup()
	_place_player(0, 0.0, 150.0)
	_truck(0, 20.0)
	_truck(2, 20.0)
	check(pas.check_player(traffic, player, params, road, res), "one lane away is reachable")


func test_minimum_speed_and_the_player_below_it() -> void:
	_setup()
	# A player at 110 km/h stuck in lane 0 behind a truck at 85, the other lanes walled:
	# it may not drop below the minimum speed.
	_place_player(0, 0.0, 110.0)
	_truck(0, 30.0)
	_truck(1, 20.0)
	_truck(2, 20.0)
	check(not pas.check_player(traffic, player, params, road, res), "at the minimum speed it still closes in")
	# A player already at the truck's speed may hold it (the rule of the soak oracle).
	_place_player(0, 0.0, 85.0)
	check(pas.check_player(traffic, player, params, road, res), "holding its own speed behind the truck")


func test_cars_behind_in_the_players_lane_follow_it() -> void:
	# A fast car right behind the player in its lane brakes for it (rear-end prevention):
	# not an obstacle while the player keeps its lane. Walls on both sides.
	_setup()
	_place_player(1, 0.0, 110.0)
	_add(aggressive_p, sports_t, 1, -9.0, 160.0)
	_truck(0, 0.0, 110.0)
	_truck(2, 0.0, 110.0)
	check(pas.check_player(traffic, player, params, road, res), "the follower yields")


func test_a_cut_in_needs_a_gap_the_faster_car_behind_can_use() -> void:
	# Lane 1 is blocked ahead by a slow truck; lane 0 has a fast car just behind the
	# player: cutting in front of it must leave it room (its hull, the clearance).
	_setup()
	_place_player(1, 0.0, 110.0)
	_truck(1, 22.0)
	_truck(2, 22.0)
	_add(aggressive_p, sports_t, 0, -6.0, 190.0)
	check(pas.check_player(traffic, player, params, road, res), "there is time to let the fast car by")
	var lane1 := road.lane_center_d(1, 0.0)
	var h := (reg.length[sports_t] + car.length_m) * 0.5 + tuning.passability.clearance_m
	var moved := false
	for k in res.path_n:
		if res.path_d[k] < lane1 - 1e-6:
			# The first step off lane 1: the fast car (free road, ~190 km/h) is clear of it.
			var car_s := -6.0 + _kmh(190.0) * float(k - 1) * pas.step_s()
			check(absf(car_s - res.path_s[k - 1]) >= h, "the move starts clear of the fast car (%.1f m)" % (car_s - res.path_s[k - 1]))
			moved = true
			break
	check(moved, "the path leaves the blocked lane")



func test_a_player_between_positions_is_followed_only_by_its_own_lane() -> void:
	# An interrupted lane change: the player stopped between lane 1's center and the
	# lane 1/2 half-lane, below the minimum speed, a fast car close behind in lane 2.
	# Its start at the half-lane must not count that car as a follower braking for it
	# (it has not been driving in front of it); the start in lane 1 does keep a path.
	_setup()
	_place_player(1, 0.0, 92.0)
	player.d = road.lane_center_d(1, 0.0) + road.lane_width(0.0) * 0.37
	_add(aggressive_p, sports_t, 2, -7.5, 117.0)
	check(pas.check_player(traffic, player, params, road, res), "back into lane 1 is a path")
	var half := pas.start_state(3)
	var own := pas.start_state(2)
	near(pas.state_d(half), road.lane_center_d(1, 0.0) + road.lane_width(0.0) * 0.5, 1e-6, "start 3 is the half-lane")
	check(not pas.has_path_from(0, half, player.s), "the lane-2 car is not exempt at the half-lane start")
	check(pas.has_path_from(0, own, player.s), "the lane-1 start has a path")
	eq(pas.state_position(res.path_state[0]), 2, "the path starts in lane 1")


# ---------------------------------------------------------------- The batch (arrival) check

func test_batch_wall_fails_and_one_open_lane_passes() -> void:
	_setup()
	_place_player(1, 0.0, 150.0)
	var wall: Array[SpawnSource.Record] = []
	for lane in LANES:
		wall.append(_record(truck_p, semi_t, lane, 900.0, 85.0))
	pas.set_planned(wall)
	check(not pas.check(traffic, player, params, road, 800.0, 1100.0, res), "a planned wall across every lane fails")
	ge(res.probes, 1, "probes behind the slow trucks")
	ge(res.failed_probes, 1, "a failing probe")
	var planned_blamed := false
	for o in res.obstacles:
		if res.blocker_src[o] < 0 and res.blocker_cut[o] > 0.0:
			planned_blamed = true
	check(planned_blamed, "planned records are credited as blockers (src < 0)")
	wall.remove_at(0)
	pas.set_planned(wall)
	check(pas.check(traffic, player, params, road, 800.0, 1100.0, res), "one open lane passes")
	pas.clear_planned()


func test_batch_without_slow_vehicles_passes_without_probes() -> void:
	_setup()
	_place_player(1, 0.0, 150.0)
	var batch: Array[SpawnSource.Record] = []
	for lane in LANES:
		batch.append(_record(commuter_p, sedan_t, lane, 900.0, 120.0))
	pas.set_planned(batch)
	check(pas.check(traffic, player, params, road, 800.0, 1100.0, res), "traffic at or above the minimum speed")
	eq(res.probes, 0, "nothing slower than the minimum speed: no probe")


func test_batch_wall_across_a_boundary_with_live_traffic() -> void:
	# Live trucks just before the batch start plus a planned truck: still a wall.
	_setup()
	_place_player(1, 0.0, 150.0)
	_truck(0, 790.0)
	_truck(1, 790.0)
	var batch: Array[SpawnSource.Record] = [_record(truck_p, semi_t, 2, 790.0, 85.0)]
	pas.set_planned(batch)
	check(not pas.check(traffic, player, params, road, 780.0, 1080.0, res), "a wall straddling the start fails")
	pas.clear_planned()


# ---------------------------------------------------------------- Lanes that end (WP6.2 lane drops)

## A procedural road of 3 lanes (or 2 if `drop`) from DROP_S on, the default taper.
func _setup_drop(drop: bool) -> bool:
	var r := ProceduralRoadPath.new(RunContext.new(DROP_SEED, RunContext.MODE_JOURNEY, tuning))
	if not eq(r.lane_count(0.0), LANES, "the procedural road starts with 3 lanes"):
		return false
	if drop:
		r.schedule_lane_count(DROP_S, LANES - 1, tuning.road.lane_taper_length_m)
	r.ensure_generated_to(DROP_S + 2000.0)
	_setup()
	road = r
	pas = Passability.new(tuning, reg, road)
	pas.set_player_body(car.length_m, car.width_m)
	return true


func test_a_lane_that_ends_is_left_in_time() -> void:
	# The player alone in lane 2, which ends ahead: the path leaves it before its body
	# would leave the driving lanes (the edge follows the taper), and ends in lane 0 or 1.
	if not _setup_drop(true):
		return
	_place_player(2, 0.0, 110.0)
	check(pas.check_player(traffic, player, params, road, res), "an ending lane with room beside it is passable")
	_check_path_shape("lane end")
	var hw := car.width_m * 0.5
	for k in res.path_n:
		if not le(res.path_d[k] + hw, road.lanes_right_edge_d(res.path_s[k]) + 1e-6,
				"the body stays on the driving lanes at step %d (s %.1f)" % [k, res.path_s[k]]):
			return
	le(res.path_d[res.path_n - 1], road.lane_center_d(1, res.path_s[res.path_n - 1]) + 1e-6, "ends out of lane 2")


func test_the_only_open_lane_ending_is_impossible() -> void:
	# Trucks side by side in lanes 0 and 1 below the minimum speed; lane 2 is the way
	# past them. Without the drop it passes; when lane 2 ends before the trucks are
	# passed it does not, the lane end is credited but never offered for removal.
	for drop: bool in [false, true]:
		if not _setup_drop(drop):
			return
		_place_player(2, 0.0, 110.0)
		_truck(0, 35.0, 80.0)
		_truck(1, 35.0, 80.0)
		var ok := pas.check_player(traffic, player, params, road, res)
		if not drop:
			check(ok, "lane 2 open all along: passable")
			continue
		check(not ok, "lane 2 ends before the trucks are passed: impossible")
		var road_cut := 0.0
		for o in res.obstacles:
			if res.blocker_src[o] == Passability.SRC_ROAD:
				road_cut += res.blocker_cut[o]
		gt(road_cut, 0.0, "the lane end is credited with the paths it cuts")
		eq(res.vehicles, 2, "road obstacles are not counted as vehicles")
		var o := res.worst_blocker(func(src: int) -> bool: return src >= 0)
		check(o >= 0 and res.blocker_src[o] >= 0, "a truck is the removable blocker")


## A TrafficSim on the test road as the zone source (WP6.3 closures and speed zones).
func _zone_sim() -> TrafficSim:
	var sim := TrafficSim.new(RunContext.new(DROP_SEED, RunContext.MODE_JOURNEY, tuning), road, reg)
	pas.zones = sim
	return sim


func test_a_lane_the_sim_closes_is_not_a_path() -> void:
	# Road works close lane 2 from 60 m: with slow trucks side by side in lanes 0 and 1,
	# lane 2 was the way past them. Open: passable; closed: impossible, the closure is
	# credited and never offered for removal.
	for closed: bool in [false, true]:
		_setup()
		var sim := _zone_sim()
		if closed:
			sim.add_lane_closure(2, 60.0, 600.0, 1)
		_place_player(2, 0.0, 110.0)
		_truck(0, 35.0, 80.0)
		_truck(1, 35.0, 80.0)
		var ok := pas.check_player(traffic, player, params, road, res)
		if not closed:
			check(ok, "lane 2 open: passable")
			continue
		check(not ok, "lane 2 closed ahead of the trucks: impossible")
		var road_cut := 0.0
		for o in res.obstacles:
			if res.blocker_src[o] == Passability.SRC_ROAD:
				road_cut += res.blocker_cut[o]
		gt(road_cut, 0.0, "the closure is credited with the paths it cuts")


func test_a_closure_blocks_its_lane_and_half_lanes_only() -> void:
	# Lane 1 closed ahead, the player in lane 1: the path leaves it before the closure,
	# and lanes 0 and 2 stay open (the path ends in one of them).
	_setup()
	var sim := _zone_sim()
	sim.add_lane_closure(1, 80.0, 600.0, 1)
	_place_player(1, 0.0, 110.0)
	check(pas.check_player(traffic, player, params, road, res), "a closed lane with open neighbours is passable")
	var c := road.lane_center_d(1, 0.0)
	var half := road.lane_width(0.0) * 0.5
	for k in res.path_n:
		if res.path_s[k] + car.length_m * 0.5 + tuning.passability.clearance_m >= 80.0:
			if not check(absf(res.path_d[k] - c) > half, "out of lane 1 and its half-lanes at s %.1f" % res.path_s[k]):
				return


func test_speed_zones_slow_the_predicted_traffic() -> void:
	# A car ahead in lane 2 at 110 km/h is the way past slow trucks in lanes 0 and 1;
	# a 60 km/h zone on lane 2 (a toll's booth lane) turns it into a wall.
	for zone: bool in [false, true]:
		_setup()
		var sim := _zone_sim()
		if zone:
			sim.add_speed_zone(2, 90.0, 800.0, _kmh(60.0), 1)
		_place_player(2, 0.0, 100.0)
		_truck(0, 45.0, 80.0)
		_truck(1, 45.0, 80.0)
		_add(commuter_p, sedan_t, 2, 30.0, 110.0)
		var ok := pas.check_player(traffic, player, params, road, res)
		if zone:
			check(not ok, "the car slows to 60 km/h in the zone: impossible")
		else:
			check(ok, "following the car past the trucks")


# ---------------------------------------------------------------- Slicing, determinism, cost

func _dense(lanes: int, n: int, seed_value: int) -> void:
	# n vehicles over [-200, 1100] m at their lanes' flow speeds (a leg-8 like road).
	var rng := Rng.new(seed_value)
	var profiles := [commuter_p, truck_p, aggressive_p]
	var types := [sedan_t, semi_t, sports_t]
	var k := 0
	var tries := 0
	while k < n and tries < 10 * n:
		tries += 1
		var lane := rng.int_range(0, lanes - 1)
		var s := rng.float_range(-200.0, 1100.0)
		var pick := 0 if lane < lanes - 1 else rng.int_range(0, 1)
		if lane == 0 and rng.chance(0.3):
			pick = 2
		var body_len: float = reg.length[types[pick]]
		var ok := absf(s - player.s) > 30.0
		for i in traffic.capacity:
			if traffic.active[i] == 1 and traffic.lane[i] == lane and absf(traffic.s[i] - s) < body_len + 25.0:
				ok = false
				break
		if not ok:
			continue
		var v := tuning.traffic.lane_flow_speed_mps(lane, lanes) / Units.kmh_to_mps(1.0)
		_add(profiles[pick], types[pick], lane, s, v)
		k += 1


func test_time_sliced_equals_synchronous() -> void:
	_setup(4)
	_place_player(2, 0.0, 140.0)
	_dense(4, 80, 11)
	pas.check_player(traffic, player, params, road, res)
	var sync_pass := res.passable
	var sync_s := res.path_s.duplicate()
	var r2 := Passability.Result.new()
	pas.begin_check(traffic, player, params, road, Passability.MODE_PLAYER, player.s, player.s, r2)
	var slices := 0
	while not pas.advance(1):
		slices += 1
	gt(slices, 5, "the check spans several slices")
	eq(r2.passable, sync_pass, "same verdict")
	eq(r2.path_n, res.path_n, "same path length")
	for k in mini(r2.path_n, res.path_n):
		if not near(r2.path_s[k], sync_s[k], 0.0, "same path at %d" % k):
			break


func test_deterministic_and_independent_of_history() -> void:
	_setup(3)
	_place_player(1, 0.0, 160.0)
	_dense(3, 70, 5)
	pas.check_player(traffic, player, params, road, res)
	var h := _result_hash(res)
	# Other checks in between, then the same inputs again, and a fresh instance.
	var other := VehicleState.new()
	other.copy_from(player)
	other.s += 100.0
	pas.check_player(traffic, other, params, road, Passability.Result.new())
	pas.check_player(traffic, player, params, road, res)
	eq(_result_hash(res), h, "same inputs, same result")
	var fresh := Passability.new(tuning, reg, road)
	fresh.set_player_body(car.length_m, car.width_m)
	fresh.check_player(traffic, player, params, road, res)
	eq(_result_hash(res), h, "a fresh instance agrees")


func _result_hash(r: Passability.Result) -> int:
	var h := TraceHash.SEED
	h = TraceHash.mix_bool(h, r.passable)
	h = TraceHash.mix_int(h, r.path_n)
	for k in r.path_n:
		h = TraceHash.mix_float(h, r.path_s[k])
		h = TraceHash.mix_float(h, r.path_d[k])
	return h


func test_checks_allocate_nothing() -> void:
	_setup(4)
	_place_player(2, 0.0, 140.0)
	_dense(4, 80, 3)
	var batch: Array[SpawnSource.Record] = [_record(truck_p, semi_t, 3, 900.0, 85.0)]
	pas.set_planned(batch)
	pas.check_player(traffic, player, params, road, res)   # warm-up (Result paths sized)
	pas.check(traffic, player, params, road, 800.0, 1100.0, res)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for k in 3:
		pas.check_player(traffic, player, params, road, res)
		pas.check(traffic, player, params, road, 800.0, 1100.0, res)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before, "no objects created by checks")


## Cost at the cap (90 vehicles) on 3 and 4 lanes, for docs/PASSABILITY.md. Budgets are
## generous (a desktop-class machine does a player check in a few ms); the director
## spreads its checks over ticks (director_slices_per_tick).
func test_check_cost_at_the_cap() -> void:
	for lanes: int in [3, 4]:
		_setup(lanes)
		_place_player(1, 0.0, 150.0)
		_dense(lanes, tuning.traffic.max_active_vehicles, 7 + lanes)
		var usec := WBBench.usec_per_call(pas.check_player.bind(traffic, player, params, road, res), 3, 1, 3)
		WBBench.report("passability player check, %d vehicles, %d lanes" % [traffic.count, lanes], usec, 40000.0)
		le(usec, WBBench.budget(40000.0), "player check usec")
		var batch: Array[SpawnSource.Record] = []
		for lane: int in lanes:
			batch.append(_record(truck_p, semi_t, lane, 900.0 + 60.0 * float(lane), 85.0))
		pas.set_planned(batch)
		usec = WBBench.usec_per_call(pas.check.bind(traffic, player, params, road, 800.0, 1100.0, res), 3, 1, 3)
		WBBench.report("passability batch check (%d probes), %d lanes" % [res.probes, lanes], usec, 60000.0)
		le(usec, WBBench.budget(60000.0), "batch check usec")
		# The largest slice a director tick does.
		var worst := 0
		pas.begin_check(traffic, player, params, road, Passability.MODE_ARRIVAL, 800.0, 1100.0, res)
		var done := false
		while not done:
			var t0 := Time.get_ticks_usec()
			done = pas.advance(1)
			worst = maxi(worst, Time.get_ticks_usec() - t0)
		WBBench.report("passability largest slice, %d lanes" % lanes, float(worst), 8000.0)
		pas.clear_planned()
