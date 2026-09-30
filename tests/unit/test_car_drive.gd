extends WBTest
## M2 integration scene smoke test: the physics car drives itself forward on auto
## throttle through the full world stack, and the camera follows. Auto throttle is set
## here: the default is manual since 2026-10-01 (plan D22).

var _scene: Node3D


func before_each() -> void:
	Settings.set_value(&"throttle_mode", &"auto")


func after_each() -> void:
	if _scene != null:
		_scene.queue_free()
		await tree.process_frame
		_scene = null
	Settings.set_value(&"throttle_mode", Settings.DEFAULTS[&"throttle_mode"])


func test_car_accelerates_and_camera_follows() -> void:
	_scene = (load("res://src/dev/car_drive.tscn") as PackedScene).instantiate()
	tree.root.add_child(_scene)
	await tree.process_frame
	var car: PlayerCar = _scene.get_node("PlayerCar")
	var s0 := car.state.s
	var v0 := car.state.v
	for i in 120:
		await tree.physics_frame
	gt(car.state.s - s0, 10.0, "car moved forward")
	gt(car.state.v, v0, "auto throttle accelerates")
	var rig: CameraRig = _scene.get_node("CameraRig")
	lt(rig.camera().global_position.distance_to(car.global_position), 40.0, "camera near the car")
	gt(_scene.get_node("RoadBuilder").active_chunk_count(), 0, "road is built")
