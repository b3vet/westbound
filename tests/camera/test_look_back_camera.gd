extends WBTest
## Look back (owner request, 2026-10-03; docs/CONTROLS.md → Look back): while held, every
## camera mode shows the rear view (the eye ahead of and above the car, looking back past
## it, CameraTuning.look_back_*); release returns to the mode's pose exactly (a cut, or a
## blend over look_back_blend_s); the cockpit steps aside and the body shows meanwhile;
## the rig follows Events.look_back_changed; the menu attract ignores it.

const RIG_SCENE := "res://src/camera/camera_rig.tscn"
const TOP_KMH := 280.0
const DT := 1.0 / 120.0

var ct: CameraTuning
var _nodes: Array[Node] = []
var _saved_mode: Variant
var _saved_reduced: Variant
var _saved_blend: float = 0.0


## A target with a body the cockpit hides.
class FakeCar:
	extends Node3D
	var body_visible: bool = true

	func set_body_visible(on: bool) -> void:
		body_visible = on


func before_all() -> void:
	ct = Tuning.load_default().camera
	_saved_blend = ct.look_back_blend_s


func before_each() -> void:
	_saved_mode = Settings.get_value(&"camera_mode")
	_saved_reduced = Settings.get_value(&"reduced_motion")
	Settings.set_value(&"camera_mode", &"chase")
	Settings.set_value(&"reduced_motion", false)


func after_each() -> void:
	ct.look_back_blend_s = _saved_blend
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	Settings.set_value(&"camera_mode", _saved_mode)
	Settings.set_value(&"reduced_motion", _saved_reduced)
	await tree.process_frame


func _rig(mode: StringName) -> Array:
	var car := FakeCar.new()
	tree.root.add_child(car)
	_nodes.append(car)
	var st := VehicleState.new()
	st.v = Units.kmh_to_mps(150.0)
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_mode(mode)
	rig.set_target(car, st, Units.kmh_to_mps(TOP_KMH))
	return [rig, car, st]


func _drive(rig: CameraRig, car: Node3D, st: VehicleState, ticks: int) -> void:
	for i in ticks:
		car.position += Vector3.FORWARD * (st.v * DT)
		rig.advance(DT)


## The camera's view direction (world) and position.
func _view(rig: CameraRig) -> Transform3D:
	return rig.camera().global_transform


func test_every_mode_looks_back_and_returns_exactly() -> void:
	for m: String in ct.modes:
		var parts := _rig(StringName(m))
		var rig: CameraRig = parts[0]
		var car: FakeCar = parts[1]
		var st: VehicleState = parts[2]
		_drive(rig, car, st, 30)
		var before := _view(rig)
		var fov_before := rig.camera().fov
		rig.set_look_back(true)
		check(rig.is_look_back(), m)
		eq(rig.look_back_weight(), 1.0, "%s: a cut" % m)
		var v := _view(rig)
		# Heading 0 faces -Z: looking back is +Z.
		gt(-v.basis.z.z, 0.8, "%s: the camera faces backwards" % m)
		lt(v.origin.z, car.position.z, "%s: the eye is ahead of the car" % m)
		gt(v.origin.y, car.position.y + 1.0, "%s: and above it" % m)
		near(rig.camera().fov, ct.look_back_fov_deg, 1e-4, "%s: the rear view's FOV" % m)
		check(car.body_visible, "%s: the body shows while looking back" % m)
		var unproj := rig.camera().is_position_behind(car.position + Vector3.BACK * 15.0)
		check(not unproj, "%s: a car 15 m behind is in front of the camera (nametags project)" % m)
		rig.set_look_back(false)
		check((_view(rig).origin - before.origin).length() < 1e-4, "%s: back at the mode's eye" % m)
		check(_view(rig).basis.z.is_equal_approx(before.basis.z), "%s: and its view" % m)
		near(rig.camera().fov, fov_before, 1e-4, "%s: and its FOV" % m)
		if m == ct.cockpit_mode:
			check(not car.body_visible, "cockpit: the body hides again")
			check(rig.cockpit() != null and rig.cockpit().visible, "cockpit: the cockpit is back")


func test_follows_the_car_while_held() -> void:
	var parts := _rig(&"chase")
	var rig: CameraRig = parts[0]
	var car: FakeCar = parts[1]
	var st: VehicleState = parts[2]
	rig.set_look_back(true)
	_drive(rig, car, st, 120)
	var v := _view(rig)
	near(v.origin.z, car.position.z - ct.look_back_ahead_m, 0.05, "still ahead of the car after 1 s")
	gt(-v.basis.z.z, 0.8, "still looking back")
	rig.set_look_back(false)
	_drive(rig, car, st, 1)
	lt(-rig.camera().global_basis.z.z, 0.0, "the chase view again")


func test_listens_to_the_events_bus() -> void:
	var rig: CameraRig = _rig(&"hood")[0]
	Events.look_back_changed.emit(true)
	check(rig.is_look_back(), "Events.look_back_changed(true)")
	Events.look_back_changed.emit(false)
	check(not rig.is_look_back(), "and false")


func test_blend_when_tuned() -> void:
	ct.look_back_blend_s = 0.1
	var parts := _rig(&"chase")
	var rig: CameraRig = parts[0]
	rig.set_look_back(true)
	eq(rig.look_back_weight(), 0.0, "a blend starts at the mode's view")
	_drive(rig, parts[1], parts[2], 6)
	near(rig.look_back_weight(), 0.5, 1e-6, "half way at 0.05 s")
	_drive(rig, parts[1], parts[2], 6)
	eq(rig.look_back_weight(), 1.0, "all the way at 0.1 s")
	rig.set_look_back(false)
	_drive(rig, parts[1], parts[2], 12)
	eq(rig.look_back_weight(), 0.0, "and back")


func test_menu_attract_ignores_it() -> void:
	var parts := _rig(&"chase")
	var rig: CameraRig = parts[0]
	rig.start_attract()
	rig.set_look_back(true)
	eq(rig.look_back_weight(), 0.0, "no rear view over the title")
	rig.stop_attract()
	_drive(rig, parts[1], parts[2], 1)
	eq(rig.look_back_weight(), 1.0, "held into the run: it shows")
	rig.set_look_back(false)
