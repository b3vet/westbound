extends WBTest
## FloatingOrigin: shifts every `floating_origin_shift_km`, once, with a precise offset.

var _fo: FloatingOrigin
var _offsets: Array[Vector3] = []


func _on_shift(offset: Vector3) -> void:
	_offsets.append(offset)


func before_each() -> void:
	_fo = FloatingOrigin.new()
	_fo.setup(Tuning.load_default().road.floating_origin_shift_km)
	_offsets.clear()
	Events.origin_shifted.connect(_on_shift)


func after_each() -> void:
	Events.origin_shifted.disconnect(_on_shift)
	_fo.free()


func test_no_shift_within_distance() -> void:
	check(not _fo.update_focus(0.0, 0.0, -1999.0))
	eq(_offsets.size(), 0)


func test_shifts_once_past_distance() -> void:
	check(_fo.update_focus(10.0, 5.0, -2001.0))
	check(not _fo.update_focus(10.0, 5.0, -2002.0), "no second shift right after")
	eq(_offsets.size(), 1)
	eq(_fo.last_offset, Vector3(10.0, 5.0, -2001.0))


func test_precision_far_from_start() -> void:
	# 5,000 km out: the local position stays centimetre-exact after a shift.
	var far := -5_000_000.0
	_fo.update_focus(0.0, 0.0, far)
	var local := _fo.to_local(3.6, 1.0, far - 150.25)
	near(local.x, 3.6, 1e-5)
	near(local.z, -150.25, 1e-4)


func test_shift_count_over_long_drive() -> void:
	var z := 0.0
	for i in 10000:
		z -= 1.0  # 10 km in 1 m steps
		_fo.update_focus(0.0, 0.0, z)
	eq(_fo.shift_count, 4, "10 km / 2 km = 4 shifts (the 5th is exactly at 10 km)")
