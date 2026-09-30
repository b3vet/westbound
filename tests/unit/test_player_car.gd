extends WBTest
## PlayerCar (WP2.1): controller -> physics -> road-space placement at 120 Hz.
## Spec: Car physics and feel; Architecture rules 5 and 8; docs/CONTRACTS.md §2, §4.

const SCENE_PATH := "res://src/vehicle/player_car.tscn"
const CAR_PATH := "res://data/cars/falcon_gt.tres"
## Placement tolerance (the spec asks for 1 cm).
const POS_TOL_M := 0.01
const DT := 1.0 / 120.0

var _params_cache: VehicleParams
var _nodes: Array[Node] = []
var _tuning: Tuning


class ScriptedController:
	extends VehicleController
	var steer := 0.0
	var throttle := 0.0
	var brake := 0.0
	var attached := 0
	var detached := 0
	var updates := 0

	func on_attached(_state: VehicleState) -> void:
		attached += 1

	func on_detached() -> void:
		detached += 1

	func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
		updates += 1
		out_input.steer = steer
		out_input.throttle = throttle
		out_input.brake = brake
		out_input.boost = false


func before_all() -> void:
	_tuning = Tuning.load_default()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


func _car_def() -> CarDef:
	return load(CAR_PATH) as CarDef


func _params() -> VehicleParams:
	if _params_cache == null:
		_params_cache = VehicleParams.build(_tuning, _car_def())
	return _params_cache


func _origin(shift_km: float) -> FloatingOrigin:
	var o := FloatingOrigin.new()
	tree.root.add_child(o)
	_nodes.append(o)
	o.setup(shift_km)
	return o


func _make(road: RoadPath, origin: FloatingOrigin) -> PlayerCar:
	var car := (load(SCENE_PATH) as PackedScene).instantiate() as PlayerCar
	car.self_tick = false
	tree.root.add_child(car)
	_nodes.append(car)
	car.setup(RunContext.new(1), road, origin, _car_def(), _params())
	return car


func _expected_position(road: RoadPath, car: PlayerCar, origin: FloatingOrigin) -> Vector3:
	var smp := road.sample(car.state.s)
	return smp.local_point(car.state.d, origin.origin_x, origin.origin_y, origin.origin_z)


func test_setup_loads_the_model_and_places_the_car() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _make(road, _origin(2.0))
	check(car.params != null, "params built")
	check(car.model != null and car.model.root.get_parent() == car.visual, "model under CarVisual")
	eq(car.model.missing_nodes().size(), 0, "model conforms")
	car.place_at(20.0, road.lane_center_d(1, 20.0), 30.0)
	near(car.state.s, 20.0, 1e-9, "s")
	near(car.state.v, 30.0, 1e-9, "v")
	check(car.position.distance_to(road.sample(20.0).local_point(road.lane_center_d(1, 20.0), 0, 0, 0))
		< POS_TOL_M, "placed on the lane")


func test_transform_tracks_physics_state() -> void:
	var roads: Array[RoadPath] = [
		StraightRoadPath.new(3, _tuning.road, 0.4, 0.03, Vector3(120.0, 5.0, -40.0)),
		ArcRoadPath.new(1200.0, 1, 3, _tuning.road),
		ArcRoadPath.new(1200.0, -1, 3, _tuning.road),
	]
	for road in roads:
		var origin := _origin(2.0)
		var car := _make(road, origin)
		var ctl := ScriptedController.new()
		ctl.throttle = 0.5
		car.controller = ctl
		var d0 := road.lane_center_d(1, 0.0)
		car.place_at(10.0, d0, 30.0)
		var worst := 0.0
		var nose_right_seen := false
		for i in 240:
			ctl.steer = 0.6 if i < 36 else 0.0
			car.tick(DT)
			worst = maxf(worst, car.position.distance_to(_expected_position(road, car, origin)))
			if i == 30:
				var smp := car.road_sample()
				var nose := -car.global_transform.basis.z
				gt(car.state.yaw, 0.0, "steering right yaws right (%s)" % road.get_class())
				gt(nose.dot(smp.right), 0.0, "nose turns right on screen")
				nose_right_seen = true
			# Yaw and pitch follow the road frame plus the relative yaw.
			var smp2 := car.road_sample()
			var want := Basis(Vector3.UP, smp2.godot_yaw(car.state.yaw)) \
				* Basis(Vector3.RIGHT, VehiclePhysics.surface_pitch(smp2))
			if not near((car.basis.z - want.z).length(), 0.0, 1e-4, "basis follows yaw and grade"):
				break
		le(worst, POS_TOL_M, "world position = road local_point(s, d) within 1 cm")
		check(nose_right_seen, "steer checked")
		gt(car.state.d, d0 + 0.5, "steering right moves +d")


func test_controller_swap_between_ticks_leaves_state_untouched() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _make(road, _origin(2.0))
	var a := ScriptedController.new()
	a.throttle = 1.0
	a.steer = 0.3
	car.controller = a
	eq(a.attached, 1, "first controller attached")
	car.place_at(0.0, road.lane_center_d(1, 0.0), 40.0)
	for i in 60:
		car.tick(DT)
	var before := car.state.trace_hash()
	var b := ScriptedController.new()
	b.brake = 1.0
	car.controller = b
	eq(car.state.trace_hash(), before, "swap does not touch the state")
	eq(a.detached, 1, "old controller detached")
	eq(b.attached, 1, "new controller attached before its first update")
	eq(b.updates, 0, "no update during the swap")
	var v := car.state.v
	car.tick(DT)
	eq(a.updates, 60, "old controller no longer updates")
	eq(b.updates, 1, "new controller drives the next tick")
	lt(car.state.v, v, "new controller's brake applies")
	car.controller = null
	eq(b.detached, 1, "detach on clearing")


func test_null_controller_coasts() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _make(road, _origin(2.0))
	car.place_at(0.0, road.lane_center_d(1, 0.0), 40.0)
	car.input.throttle = 1.0
	for i in 120:
		car.tick(DT)
	eq(car.input.throttle, 0.0, "zero input")
	lt(car.state.v, 40.0, "coasting slows the car")
	gt(car.state.v, 35.0, "only by coasting drag")
	near(car.state.d, road.lane_center_d(1, 0.0), 1e-9, "no steering")


func test_state_matches_pure_physics() -> void:
	# The node adapter (placement, visual, shadow) never feeds back into physics; the only
	# thing between the controller and physics is the input quantization (N8.2).
	var road := ArcRoadPath.new(1200.0, 1, 3, _tuning.road)
	var car := _make(road, _origin(2.0))
	var ctl := ScriptedController.new()
	car.controller = ctl
	car.place_at(5.0, road.lane_center_d(1, 5.0), 50.0)
	var ref := VehicleState.new()
	var inp := VehicleInput.new()
	VehiclePhysics.place(ref, _params(), 5.0, road.lane_center_d(1, 5.0), 50.0)
	for i in 600:
		ctl.steer = sin(float(i) * 0.05)
		ctl.throttle = 0.7
		ctl.brake = 1.0 if i % 150 < 20 else 0.0
		car.tick(DT)
		inp.steer = ctl.steer
		inp.throttle = ctl.throttle
		inp.brake = ctl.brake
		inp.quantize()   # N8.2: PlayerCar quantizes the controller's inputs before physics
		VehiclePhysics.step(ref, inp, DT, _params(), road)
	eq(car.state.trace_hash(), ref.trace_hash(), "PlayerCar state == VehiclePhysics trace")
	eq(car.input.steer, inp.steer, "the car took the quantized input")


func test_origin_shift_keeps_the_car_continuous() -> void:
	var road := StraightRoadPath.new(3, _tuning.road, 0.3, 0.02)
	var origin := _origin(0.05)   # shift every 50 m
	var car := _make(road, origin)
	var ctl := ScriptedController.new()
	ctl.throttle = 1.0
	car.controller = ctl
	car.place_at(0.0, road.lane_center_d(1, 0.0), 60.0)
	var prev := _absolute(car, origin)
	var worst_jump := 0.0
	var worst_local := 0.0
	var smp := RoadSample.new()
	for i in 360:
		car.tick(DT)
		road.sample_into(car.state.s, smp)
		origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
		var now := _absolute(car, origin)
		worst_jump = maxf(worst_jump, now.distance_to(prev) - car.state.v * DT)
		prev = now
		worst_local = maxf(worst_local, car.position.distance_to(_expected_position(road, car, origin)))
	ge(origin.shift_count, 3, "several origin shifts happened")
	le(worst_jump, POS_TOL_M, "absolute position continuous across shifts")
	le(worst_local, POS_TOL_M, "re-placed in the new frame")
	lt(car.position.length(), 60.0, "car stays near the render origin")
	var shadow_xz := Vector2(car.shadow.global_position.x, car.shadow.global_position.z)
	lt(shadow_xz.distance_to(Vector2(car.position.x, car.position.z)), 0.05, "shadow follows across shifts")


func _absolute(car: PlayerCar, origin: FloatingOrigin) -> Vector3:
	return Vector3(car.position.x + origin.origin_x, car.position.y + origin.origin_y,
		car.position.z + origin.origin_z)


func test_world_velocity_matches_motion() -> void:
	var road := StraightRoadPath.new(3, _tuning.road, -0.5, 0.04)
	var car := _make(road, _origin(2.0))
	var ctl := ScriptedController.new()
	ctl.throttle = 0.4
	ctl.steer = 0.5
	car.controller = ctl
	car.place_at(0.0, road.lane_center_d(1, 0.0), 35.0)
	for i in 20:
		car.tick(DT)
	var p0 := car.position
	var v0 := car.world_velocity()
	car.tick(DT)
	var v1 := car.world_velocity()
	var fd := (car.position - p0) / DT
	var mid := (v0 + v1) * 0.5
	lt((mid - fd).length(), fd.length() * 0.01, "world_velocity ~ finite difference")
	gt(absf(car.state.v_lat), 0.0, "includes slip")


func test_self_tick_runs_in_physics_process() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _make(road, _origin(2.0))
	car.self_tick = true
	car.place_at(0.0, road.lane_center_d(1, 0.0), 30.0)
	for i in 6:
		await tree.physics_frame
	gt(car.state.s, 0.5, "moves on its own")


func test_tick_creates_no_objects() -> void:
	var road := ArcRoadPath.new(1200.0, 1, 3, _tuning.road)
	var origin := _origin(0.05)
	var car := _make(road, origin)
	var ctl := ScriptedController.new()
	ctl.throttle = 1.0
	car.controller = ctl
	car.place_at(0.0, road.lane_center_d(1, 0.0), 40.0)
	for i in 30:   # warm up (first brake-light toggle, caches)
		ctl.brake = 1.0 if i % 10 < 5 else 0.0
		car.tick(DT)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 480:
		ctl.steer = 1.0 if i % 120 < 60 else -1.0
		ctl.brake = 1.0 if i % 40 < 10 else 0.0
		car.tick(DT)
	var after := Performance.get_monitor(Performance.OBJECT_COUNT)
	le(after - before, 0.0, "no objects created per tick")
