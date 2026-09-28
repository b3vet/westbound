extends WBTest
## M1 integration scene smoke test: boots the full world stack and drives
## through a floating-origin shift without errors or unbounded growth.

var _scene: Node3D


func after_each() -> void:
	if _scene != null:
		_scene.queue_free()
		await tree.process_frame
		_scene = null


func test_drive_through_origin_shift() -> void:
	_scene = (load("res://src/dev/road_drive.tscn") as PackedScene).instantiate()
	tree.root.add_child(_scene)
	await tree.process_frame
	var shifts := [0]
	var on_shift := func(_o: Vector3) -> void: shifts[0] += 1
	Events.origin_shifted.connect(on_shift)
	# Jump close to the 2 km shift point, then drive through it.
	_scene.snap_setup({"s": 1990.0})
	for i in 30:
		await tree.physics_frame
	Events.origin_shifted.disconnect(on_shift)
	var builder: RoadBuilder = _scene.get_node("RoadBuilder")
	gt(builder.active_chunk_count(), 0, "road chunks are live")
	ge(shifts[0], 1, "an origin shift happened")
	var car: Node3D = _scene.get_node("PlaceholderCar")
	lt(car.position.length(), 100.0, "car stays near the render origin after the shift")
