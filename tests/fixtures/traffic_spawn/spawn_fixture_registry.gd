class_name SpawnFixtureRegistry
extends RefCounted
## Stand-in for WP2.4's TrafficRegistry in the spawning tests (not a test suite: the
## runner skips tests/fixtures). The eight spec driver types (desired speeds from the
## spec's table; IDM values are plausible placeholders) and a small vehicle roster,
## built in code. Index in `profiles` = profile_id, index in `types` = type_id, exactly
## as the real registry's stable order.

var profiles: Array[DriverProfile] = []
var types: Array[VehicleType] = []


func _init() -> void:
	#          id           vmin   vmax   T    s0   a    b    keep_right min_leg
	_profile(&"cruiser", 80.0, 100.0, 1.6, 2.5, 1.2, 2.0, true, 1)
	_profile(&"commuter", 100.0, 130.0, 1.3, 2.0, 1.4, 2.0, false, 1)
	_profile(&"aggressive", 150.0, 190.0, 0.9, 1.5, 2.2, 3.0, false, 1)
	_profile(&"truck", 80.0, 90.0, 1.8, 3.0, 0.6, 1.5, true, 1)
	_profile(&"bus", 85.0, 95.0, 1.7, 3.0, 0.8, 1.6, true, 1)
	_profile(&"van", 95.0, 110.0, 1.4, 2.0, 1.2, 2.0, false, 1)
	_profile(&"motorbike", 110.0, 150.0, 1.1, 1.5, 2.0, 2.5, false, 1)
	_profile(&"hesitant", 90.0, 120.0, 1.5, 2.0, 1.2, 2.0, false, 3)
	#       id          len   width  profiles                                   variants
	_type(&"sedan", 4.6, 1.85, [&"cruiser", &"commuter", &"hesitant"], 3)
	_type(&"hatchback", 4.1, 1.8, [&"cruiser", &"hesitant"], 2)
	_type(&"suv", 4.8, 1.95, [&"commuter", &"hesitant"], 2)
	_type(&"sports", 4.4, 1.9, [&"aggressive", &"hesitant"], 2)
	_type(&"semi", 16.0, 2.5, [&"truck"], 1)
	_type(&"coach", 12.0, 2.55, [&"bus"], 1)
	_type(&"delivery_van", 5.5, 2.0, [&"van"], 1)
	_type(&"bike", 2.2, 0.8, [&"motorbike"], 2)


func profile_index(id: StringName) -> int:
	for i in profiles.size():
		if profiles[i].id == id:
			return i
	return -1


func _profile(id: StringName, vmin: float, vmax: float, headway: float, s0: float, a: float, b: float,
		keep_right: bool, min_leg: int) -> void:
	var p := DriverProfile.new()
	p.id = id
	p.desired_speed_min_kmh = vmin
	p.desired_speed_max_kmh = vmax
	p.idm_headway_s = headway
	p.idm_s0_m = s0
	p.idm_a_max_mps2 = a
	p.idm_b_comfort_mps2 = b
	p.keep_right = keep_right
	p.min_leg = min_leg
	profiles.append(p)


func _type(id: StringName, length: float, width: float, allowed: Array[StringName], variants: int) -> void:
	var t := VehicleType.new()
	t.id = id
	t.length_m = length
	t.width_m = width
	t.allowed_profiles = allowed
	var paths := PackedStringArray()
	for i in variants:
		paths.append("res://fixture/%s_%d.tscn" % [id, i])
	t.model_scene_paths = paths
	types.append(t)
