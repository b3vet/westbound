extends WBTest
## Phase-0 contracts: road-space conventions on the exact fixture roads, TrafficState
## slots and hashing, VehicleState/VehicleInput, ScoreEventBuffer, RunContext streams,
## controller swapping and the music-clock stub. Spec: Architecture rules 2, 4, 5, 7, 8;
## docs/CONTRACTS.md.

const EPS := 1e-9
const R := 1500.0

var road_t: RoadTuning


## Minimal controllers to exercise the swap contract.
class ConstSteer extends VehicleController:
	var value: float
	var attached := 0

	func _init(v: float) -> void:
		value = v

	func on_attached(_state: VehicleState) -> void:
		attached += 1

	func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
		out_input.clear()
		out_input.steer = value
		out_input.throttle = 1.0


func before_all() -> void:
	road_t = Tuning.load_default().road


# ---------------------------------------------------------------- Helpers

func _near_v(a: Vector3, b: Vector3, tol: float, msg: String) -> bool:
	return check(a.distance_to(b) <= tol, "%s: expected %s, got %s" % [msg, b, a])


## 64-bit distance (Vector2 is 32-bit).
func _hypot(x: float, z: float) -> float:
	return sqrt(x * x + z * z)


func _check_frame(smp: RoadSample, msg: String) -> void:
	near(smp.tangent.length(), 1.0, 1e-6, msg + " |tangent|")
	near(smp.right.length(), 1.0, 1e-6, msg + " |right|")
	near(smp.up.length(), 1.0, 1e-6, msg + " |up|")
	near(smp.tangent.dot(smp.right), 0.0, 1e-6, msg + " tangent.right")
	near(smp.up.dot(smp.tangent), 0.0, 1e-6, msg + " up.tangent")
	near(smp.up.dot(smp.right), 0.0, 1e-6, msg + " up.right")
	near(smp.right.y, 0.0, 1e-6, msg + " right is horizontal (no banking)")
	# right = forward x up (right-handed, Y up): the right of travel.
	_near_v(smp.tangent.cross(smp.up), smp.right, 1e-5, msg + " right = tangent x up")


# ---------------------------------------------------------------- Straight road

func test_straight_positions_and_frame() -> void:
	var road := StraightRoadPath.new(3, road_t)
	var smp := RoadSample.new()
	for s: float in [0.0, 1.0, 250.0, 12345.5]:
		road.sample_into(s, smp)
		eq(smp.s, s)
		near(smp.pos_x, 0.0, EPS)
		near(smp.pos_y, 0.0, EPS)
		near(smp.pos_z, -s, EPS, "travel is along -Z at heading 0")
		near(smp.heading, 0.0, EPS)
		near(smp.curvature, 0.0, EPS)
		near(smp.elevation, 0.0, EPS)
		near(smp.grade, 0.0, EPS)
		_near_v(smp.tangent, Vector3(0, 0, -1), 1e-6, "tangent")
		_near_v(smp.right, Vector3(1, 0, 0), 1e-6, "right")
		_near_v(smp.up, Vector3(0, 1, 0), 1e-6, "up")
		_check_frame(smp, "straight s=%s" % s)
	near(road.curvature_at(99.0), 0.0, EPS)


func test_straight_heading_is_right_positive() -> void:
	# heading +PI/2 = turned right from -Z, i.e. facing +X; its right is +Z.
	var road := StraightRoadPath.new(3, road_t, PI / 2.0)
	var smp := road.sample(100.0)
	near(smp.pos_x, 100.0, 1e-9)
	near(smp.pos_z, 0.0, 1e-9)
	_near_v(smp.tangent, Vector3(1, 0, 0), 1e-6, "tangent")
	_near_v(smp.right, Vector3(0, 0, 1), 1e-6, "right")
	near(smp.godot_yaw(), -PI / 2.0, EPS, "Godot rotation.y = -heading")


func test_straight_grade() -> void:
	var road := StraightRoadPath.new(3, road_t, 0.0, 0.05, Vector3(10, 2, -5))
	var smp := road.sample(200.0)
	near(smp.pos_x, 10.0, EPS)
	near(smp.pos_y, 12.0, EPS)
	near(smp.pos_z, -205.0, EPS)
	near(smp.elevation, 12.0, EPS)
	near(smp.grade, 0.05, EPS)
	gt(smp.tangent.y, 0.0, "tangent climbs")
	near(smp.tangent.y / -smp.tangent.z, 0.05, 1e-6, "tangent slope = grade")
	_check_frame(smp, "graded")


func test_lane_centers_and_edges() -> void:
	for lanes: int in [2, 3, 4]:
		var road := StraightRoadPath.new(lanes, road_t)
		var s := 42.0
		eq(road.lane_count(s), lanes)
		var left := road_t.median_half_width_m + road_t.inner_shoulder_m
		for i in lanes:
			var expected := road_t.median_half_width_m + road_t.inner_shoulder_m + (i + 0.5) * road_t.lane_width_m
			near(road.lane_center_d(i, s), expected, EPS, "lane %d of %d" % [i, lanes])
			near(road.lane_center_d(i, s), road_t.lane_center_d(i), EPS)
			near(road.opposite_lane_center_d(i, s), -expected, EPS)
			eq(road.lane_index_at(expected, s), i)
			check(not road.is_on_shoulder(expected, s), "lane center is not shoulder")
		# Lane 0 is next to the median (smallest d); d increases to the right.
		lt(road.lane_center_d(0, s), road.lane_center_d(lanes - 1, s))
		near(road.median_barrier_d(s), road_t.median_half_width_m, EPS)
		near(road.lanes_left_edge_d(s), left, EPS)
		near(road.lanes_right_edge_d(s), left + lanes * road_t.lane_width_m, EPS)
		near(road.shoulder_outer_d(s), left + lanes * road_t.lane_width_m + road_t.shoulder_m, EPS)
		near(road.guardrail_d(s), road.shoulder_outer_d(s) + road_t.guardrail_offset_m, EPS)
		eq(road.lane_index_at(left - 0.1, s), -1, "inner shoulder is not a lane")
		eq(road.lane_index_at(road.lanes_right_edge_d(s) + 0.1, s), -1, "outer shoulder is not a lane")
		check(road.is_on_shoulder(left - 0.1, s), "inner shoulder")
		check(road.is_on_shoulder(road.lanes_right_edge_d(s) + 1.0, s), "outer shoulder")
		check(not road.is_on_shoulder(road.guardrail_d(s) + 0.1, s), "beyond the guardrail")


func test_world_point_is_pos_plus_right_d() -> void:
	var road := StraightRoadPath.new(3, road_t)
	var smp := road.sample(500.0)
	var d := road.lane_center_d(1, 500.0)
	_near_v(smp.world_point(d), Vector3(d, 0, -500), 1e-4, "player side is +X at heading 0")
	_near_v(smp.world_point(-d), Vector3(-d, 0, -500), 1e-4, "opposite carriageway")
	# local_point subtracts a floating-origin offset in 64-bit before narrowing.
	var far_s := 3.0e6
	road.sample_into(far_s, smp)
	_near_v(smp.local_point(d, 0.0, 0.0, -far_s), Vector3(d, 0, 0), 1e-6, "far point relative to origin")


# ---------------------------------------------------------------- Arc road

func test_arc_right_bend() -> void:
	var road := ArcRoadPath.new(R, 1, 3, road_t)
	near(road.curvature_at(10.0), 1.0 / R, EPS, "right bend: curvature positive")
	check(road.center_x() > 0.0, "right bend: center to the right (+X at heading 0)")
	var smp := RoadSample.new()
	for s: float in [0.0, 100.0, 777.7, R * PI / 2.0, 5000.0]:
		road.sample_into(s, smp)
		near(smp.curvature, 1.0 / R, EPS)
		near(smp.heading, s / R, 1e-12, "heading = s / R")
		var r := _hypot(smp.pos_x - road.center_x(), smp.pos_z - road.center_z())
		near(r, R, 1e-6, "on the circle at s=%s" % s)
		_check_frame(smp, "arc s=%s" % s)
		# The right vector points at the center for a right bend.
		var to_center := Vector3(road.center_x() - smp.pos_x, 0, road.center_z() - smp.pos_z).normalized()
		_near_v(smp.right, to_center, 1e-5, "right points to the center")
	# A quarter turn to the right from -Z faces +X, at (R, 0, -R).
	road.sample_into(R * PI / 2.0, smp)
	near(smp.pos_x, R, 1e-6)
	near(smp.pos_z, -R, 1e-6)
	_near_v(smp.tangent, Vector3(1, 0, 0), 1e-6, "quarter turn tangent")


func test_arc_left_bend() -> void:
	var road := ArcRoadPath.new(R, -1, 3, road_t)
	near(road.curvature_at(0.0), -1.0 / R, EPS, "left bend: curvature negative")
	check(road.center_x() < 0.0, "left bend: center to the left")
	var smp := road.sample(R * PI / 2.0)
	near(smp.heading, -PI / 2.0, 1e-12)
	near(smp.pos_x, -R, 1e-6)
	near(smp.pos_z, -R, 1e-6)
	_near_v(smp.tangent, Vector3(-1, 0, 0), 1e-6, "quarter turn left faces -X")
	var r := _hypot(smp.pos_x - road.center_x(), smp.pos_z - road.center_z())
	near(r, R, 1e-6)
	_check_frame(smp, "left arc")


func test_arc_is_consistent_with_finite_differences() -> void:
	# tangent = d pos / ds and curvature = d heading / ds (arc length parameterization).
	for bend: int in [1, -1]:
		var road := ArcRoadPath.new(R, bend, 3, road_t, 0.3, Vector3(5, 1, 7))
		var s := 900.0
		var h := 1.0
		var a := road.sample(s - h)
		var b := road.sample(s + h)
		var mid := road.sample(s)
		var dp := Vector3(b.pos_x - a.pos_x, b.pos_y - a.pos_y, b.pos_z - a.pos_z) / (2.0 * h)
		_near_v(dp, mid.tangent, 1e-5, "tangent ~ dpos/ds (bend %d)" % bend)
		near((b.heading - a.heading) / (2.0 * h), mid.curvature, 1e-9, "curvature ~ dheading/ds")
		# Positive curvature turns the tangent toward `right`.
		var dt := Vector3(b.tangent - a.tangent) / (2.0 * h)
		near(dt.dot(mid.right), mid.curvature, 1e-5, "dT/ds . right = curvature")


# ---------------------------------------------------------------- Allocation and features

func test_sample_into_reuses_the_output() -> void:
	var road := ArcRoadPath.new(R, 1, 3, road_t)
	var smp := RoadSample.new()
	var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 1000:
		road.sample_into(float(i) * 3.0, smp)
	var objects_after := Performance.get_monitor(Performance.OBJECT_COUNT)
	eq(objects_after, objects_before, "sample_into must not create objects")
	near(smp.s, 2997.0, EPS, "the same RoadSample holds the last sample")
	# sample() is the allocating convenience: a fresh object each call.
	check(road.sample(1.0) != road.sample(1.0), "sample() returns new objects")


func test_features_in_overlap() -> void:
	var road := StraightRoadPath.new(3, road_t)
	road.add_feature(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 3500.0, 3500.0, 1.0, BiomeDef.LANDMARK_TOLL_GANTRY))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.BLIND_CREST, 800.0, 860.0))
	road.add_feature(RoadFeature.make(RoadFeature.Kind.LANE_COUNT_CHANGE, 2000.0, 2150.0, 2.0))
	var out: Array[RoadFeature] = []
	road.features_in(0.0, 1000.0, out)
	eq(out.size(), 1)
	eq(out[0].kind, RoadFeature.Kind.BLIND_CREST)
	out.clear()
	road.features_in(850.0, 4000.0, out)
	eq(out.size(), 3)
	eq(out[0].kind, RoadFeature.Kind.BLIND_CREST, "sorted by s_start")
	eq(out[2].kind, RoadFeature.Kind.CHECKPOINT)
	eq(out[2].tag, BiomeDef.LANDMARK_TOLL_GANTRY)
	eq(road.length_generated(), INF)


# ---------------------------------------------------------------- TrafficState

func test_traffic_state_slots() -> void:
	var cap := Tuning.load_default().traffic.max_active_vehicles
	var ts := TrafficState.new(cap)
	eq(ts.capacity, 60)
	eq(ts.s.size(), cap)
	eq(ts.flags.size(), cap)
	eq(ts.count, 0)
	for i in cap:
		eq(ts.allocate(), i, "allocation order is 0, 1, 2, ...")
	eq(ts.count, cap)
	check(ts.is_full())
	eq(ts.allocate(), -1, "capacity respected")
	eq(ts.count, cap)
	var old_id := ts.vehicle_id[7]
	ts.s[7] = 123.0
	ts.set_flag(7, TrafficState.FLAG_HAZARD, true)
	ts.free_slot(7)
	eq(ts.count, cap - 1)
	check(not ts.is_active(7))
	eq(ts.allocate(), 7, "freed slot is reused")
	check(ts.vehicle_id[7] > old_id, "reused slot gets a fresh vehicle_id")
	near(ts.s[7], 0.0, EPS, "allocate() zeroes the slot")
	eq(ts.flags[7], 0)
	eq(ts.lc_state[7], TrafficState.LaneChange.NONE)
	ts.clear()
	eq(ts.count, 0)
	eq(ts.allocate(), 0)


func test_traffic_state_flags() -> void:
	var ts := TrafficState.new(4)
	var i := ts.allocate()
	ts.set_flag(i, TrafficState.FLAG_BRAKE, true)
	ts.set_flag(i, TrafficState.FLAG_BLINKER_LEFT, true)
	check(ts.has_flag(i, TrafficState.FLAG_BRAKE))
	check(ts.has_flag(i, TrafficState.FLAG_BLINKER_LEFT))
	check(not ts.has_flag(i, TrafficState.FLAG_BLINKER_RIGHT))
	ts.set_flag(i, TrafficState.FLAG_BRAKE, false)
	check(not ts.has_flag(i, TrafficState.FLAG_BRAKE))
	check(ts.has_flag(i, TrafficState.FLAG_BLINKER_LEFT))


func _fill_traffic(ts: TrafficState) -> void:
	for k in 5:
		var i := ts.allocate()
		ts.s[i] = 100.0 + 37.5 * k
		ts.d[i] = 3.5 + 0.1 * k
		ts.v[i] = 30.0 + k
		ts.v0[i] = 33.0
		ts.length[i] = 4.6
		ts.width[i] = 1.85
		ts.lane[i] = k % 3
		ts.target_lane[i] = k % 3
		ts.type_id[i] = k
		ts.flags[i] = TrafficState.FLAG_HEADLIGHTS


func test_traffic_state_trace_hash() -> void:
	var a := TrafficState.new(8)
	var b := TrafficState.new(8)
	eq(a.trace_hash(), b.trace_hash(), "empty states hash equal")
	_fill_traffic(a)
	_fill_traffic(b)
	eq(a.trace_hash(), b.trace_hash(), "identical states hash equal")
	var h := a.trace_hash()
	eq(a.trace_hash(), h, "hash is stable")
	b.d[2] += 1e-12
	ne(b.trace_hash(), h, "hash sees a tiny d change")
	b.d[2] = a.d[2]
	eq(b.trace_hash(), h)
	b.set_flag(3, TrafficState.FLAG_BRAKE, true)
	ne(b.trace_hash(), h, "hash sees a flag change")
	b.set_flag(3, TrafficState.FLAG_BRAKE, false)
	b.lc_state[4] = TrafficState.LaneChange.SIGNALING
	ne(b.trace_hash(), h, "hash sees a lane-change state change")
	# Inactive slots do not contribute.
	var c := TrafficState.new(8)
	_fill_traffic(c)
	c.s[7] = 999.0
	eq(c.trace_hash(), h, "inactive slot data is ignored")
	# copy_from reproduces the state exactly.
	var d := TrafficState.new(8)
	d.copy_from(a)
	eq(d.trace_hash(), h)
	eq(d.allocate(), a.allocate(), "free list copied too")


# ---------------------------------------------------------------- VehicleState / VehicleInput

func _script_vars(o: Object) -> PackedStringArray:
	var out := PackedStringArray()
	for p in o.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out.append(p["name"])
	return out


func _sample_state() -> VehicleState:
	var st := VehicleState.new()
	st.s = 1234.5
	st.d = 5.4
	st.yaw = 0.01
	st.v = 70.0
	st.v_lat = -0.2
	st.yaw_rate = 0.03
	st.steer_angle = 0.02
	st.accel_long = 1.5
	st.accel_lat = -0.4
	st.rpm = 5200.0
	st.gear = 4
	st.boost_active = true
	st.boost_meter = 0.25
	return st


func test_vehicle_state_copy_and_hash() -> void:
	var a := _sample_state()
	var b := VehicleState.new()
	ne(b.trace_hash(), a.trace_hash())
	b.copy_from(a)
	eq(b.trace_hash(), a.trace_hash(), "copy_from copies every field")
	for p in _script_vars(a):
		eq(b.get(p), a.get(p), "copy_from field %s" % p)
	# Every field feeds the hash.
	var h := a.trace_hash()
	for p in _script_vars(a):
		var c := _sample_state()
		var val: Variant = c.get(p)
		match typeof(val):
			TYPE_FLOAT:
				c.set(p, float(val) + 1e-9)
			TYPE_INT:
				c.set(p, int(val) + 1)
			TYPE_BOOL:
				c.set(p, not bool(val))
		ne(c.trace_hash(), h, "hash ignores field %s" % p)
	a.reset()
	eq(a.trace_hash(), VehicleState.new().trace_hash(), "reset() restores defaults")


func test_vehicle_input() -> void:
	var a := VehicleInput.new()
	a.steer = 0.5
	a.throttle = 1.0
	a.brake = 0.25
	a.boost = true
	var b := VehicleInput.new()
	b.copy_from(a)
	eq(b.hash_into(TraceHash.SEED), a.hash_into(TraceHash.SEED))
	for p in _script_vars(a):
		eq(b.get(p), a.get(p), p)
	b.clear()
	eq(b.steer, 0.0)
	eq(b.throttle, 0.0)
	eq(b.brake, 0.0)
	eq(b.boost, false)


func test_controller_swap_keeps_state() -> void:
	var state := _sample_state()
	var before := state.trace_hash()
	var input := VehicleInput.new()
	var player := ConstSteer.new(1.0)
	var ai := ConstSteer.new(-0.5)
	var controller: VehicleController = player
	controller.on_attached(state)
	controller.update(1.0 / 120.0, state, input)
	eq(input.steer, 1.0)
	# Swap at runtime: the vehicle (state) is untouched; the new controller takes over.
	controller.on_detached()
	controller = ai
	controller.on_attached(state)
	controller.update(1.0 / 120.0, state, input)
	eq(input.steer, -0.5)
	eq(ai.attached, 1)
	eq(state.trace_hash(), before, "controllers never write VehicleState")


# ---------------------------------------------------------------- ScoreEventBuffer

func test_score_event_buffer_write_and_drain() -> void:
	var buf := ScoreEventBuffer.new(Tuning.load_default().scoring.event_buffer_capacity)
	check(buf.is_empty())
	check(buf.push(Events.PASS, 480, 12.4, 2.3, 5))
	check(buf.push(Events.CLOSE_PASS, 1450, 15.4, 0.6, 9, 0.0))
	check(buf.push(ScoringRuleSet.KIND_BANKED, 48200, 0.0, -1.0, -1, 1332700.0, Events.REASON_CHECKPOINT))
	eq(buf.size(), 3)
	eq(buf.kind[0], Events.PASS)
	eq(buf.points[0], 480)
	near(buf.multiplier[0], 12.4, EPS)
	near(buf.clearance_m[0], 2.3, EPS)
	eq(buf.slot[0], 5)
	eq(buf.kind[1], Events.CLOSE_PASS)
	eq(buf.tag[2], Events.REASON_CHECKPOINT)
	near(buf.value[2], 1332700.0, EPS)
	eq(buf.clearance_m[2], -1.0)
	var h := buf.hash_into(TraceHash.SEED)
	# Drain: read 0..size()-1, then clear().
	var drained := 0
	for i in buf.size():
		drained += buf.points[i]
	eq(drained, 480 + 1450 + 48200)
	buf.clear()
	eq(buf.size(), 0)
	ne(buf.hash_into(TraceHash.SEED), h)
	eq(buf.dropped, 0)


func test_score_event_buffer_overflow() -> void:
	var buf := ScoreEventBuffer.new(4)
	for i in 4:
		check(buf.push(Events.PASS, i))
	check(not buf.push(Events.THREAD, 99), "push into a full buffer fails")
	check(not buf.push(Events.CUT, 98))
	eq(buf.size(), 4)
	eq(buf.dropped, 2)
	for i in 4:
		eq(buf.points[i], i, "oldest events are kept, in order")
		eq(buf.kind[i], Events.PASS)
	buf.clear()
	eq(buf.dropped, 2, "clear() keeps the drop counter")
	check(buf.push(Events.CUT, 15))
	buf.reset()
	eq(buf.dropped, 0)
	eq(buf.size(), 0)


func test_score_event_buffer_push_allocates_nothing() -> void:
	var buf := ScoreEventBuffer.new(64)
	var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 64:
		buf.push(Events.PASS, i, 1.0, 0.5, i)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects_before)
	eq(buf.size(), 64)


# ---------------------------------------------------------------- RunContext

func _draws(rng: Rng, n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for i in n:
		out.append(rng.unit())
	return out


func test_run_context_streams() -> void:
	var a := RunContext.new(987654321)
	var b := RunContext.new(987654321)
	eq(a.run_seed, 987654321)
	eq(a.mode, RunContext.MODE_JOURNEY)
	check(a.tuning == Tuning.load_default(), "defaults to the shared tuning")
	eq(_draws(a.rng_road, 16), _draws(b.rng_road, 16), "road stream deterministic")
	eq(_draws(a.rng_traffic, 16), _draws(b.rng_traffic, 16), "traffic stream deterministic")
	eq(_draws(a.rng_props, 16), _draws(b.rng_props, 16), "props stream deterministic")
	eq(_draws(a.rng_events, 16), _draws(b.rng_events, 16), "events stream deterministic")
	# Streams are the named derivations of the run seed.
	var root := Rng.new(987654321)
	eq(a.rng_road.get_seed(), root.derive(Rng.STREAM_ROAD).get_seed())
	eq(a.rng_traffic.get_seed(), root.derive(Rng.STREAM_TRAFFIC).get_seed())
	eq(a.rng_props.get_seed(), root.derive(Rng.STREAM_PROPS).get_seed())
	eq(a.rng_events.get_seed(), root.derive(Rng.STREAM_EVENTS).get_seed())
	# Four distinct streams.
	var seeds := [a.rng_road.get_seed(), a.rng_traffic.get_seed(), a.rng_props.get_seed(), a.rng_events.get_seed()]
	for i in seeds.size():
		for j in range(i + 1, seeds.size()):
			ne(seeds[i], seeds[j], "streams %d and %d collide" % [i, j])
	# Drawing from one stream never shifts another.
	var c := RunContext.new(987654321)
	_draws(c.rng_traffic, 500)
	eq(_draws(c.rng_road, 8), _draws(RunContext.new(987654321).rng_road, 8))
	# A different seed gives different streams.
	ne(_draws(RunContext.new(1).rng_traffic, 8), _draws(RunContext.new(2).rng_traffic, 8))


func test_run_context_daily() -> void:
	var a := RunContext.daily(2026, 9, 28)
	var b := RunContext.daily(2026, 9, 28)
	eq(a.mode, RunContext.MODE_DAILY)
	eq(a.run_seed, Rng.daily_seed(2026, 9, 28))
	eq(_draws(a.rng_traffic, 8), _draws(b.rng_traffic, 8))
	ne(RunContext.daily(2026, 9, 29).run_seed, a.run_seed)


# ---------------------------------------------------------------- Stubs and resource classes

func test_music_clock_stub() -> void:
	var clock := MusicClock.new()
	eq(clock.beat_phase(), 0.0)
	eq(clock.bar(), 0)
	eq(clock.beat_in_bar(), 0)
	eq(clock.bpm(), 0.0)
	eq(clock.is_running(), false)


func test_resource_classes_instantiate() -> void:
	var car := CarDef.new()
	check(car is Resource)
	near(car.top_speed_mps(), car.top_speed_kmh / 3.6, EPS)
	var vt := VehicleType.new()
	check(vt is Resource)
	var dp := DriverProfile.new()
	near(dp.idm_delta, Tuning.load_default().traffic.idm_delta, EPS, "IDM delta = 4")
	near(dp.desired_speed_max_mps(), dp.desired_speed_max_kmh / 3.6, EPS)
	check(BiomeDef.new() is Resource)
	var sp := SetPieceDef.new()
	sp.kind = SetPieceDef.Kind.MERGE_ZONE
	eq(sp.kind, SetPieceDef.Kind.MERGE_ZONE)
	var rec := SpawnSource.Record.new()
	check(is_nan(rec.d), "Record.d defaults to NAN (= lane center)")
	var ctx := SpawnSource.Context.new()
	eq(ctx.leg, 1)
	eq(ScoringRuleSet.new().multiplier(), 1.0)
