extends WBTest
## Model interiors in the cockpit view (G4) and the hood camera on the model's
## Markers/cam_hood (G6): WP-ART-G, docs/ART_PRODUCTION.md §3.6.5, §3.6.6, §3.11. Uses the
## calibration car (tests/art/fixtures/calib_car, tests only). These drive the mode
## directly (set_mode), as the dev tools do.

const RIG_SCENE := "res://src/camera/camera_rig.tscn"
const CAR_SCENE := "res://src/vehicle/player_car.tscn"
const CALIB_DEF := "res://tests/art/fixtures/calib_car/calib_car.tres"
## A car on the old placeholder bake (no interior, stubbed markers): the roster is modular now.
const PLACEHOLDER_DEF := "res://tests/fixtures/placeholder_car/placeholder_car.tres"
const DT := 1.0 / 120.0

var _tuning: Tuning
var ct: CameraTuning
var _nodes: Array[Node] = []
var _params := {}
var _saved_mode: Variant


func before_all() -> void:
	_tuning = Tuning.load_default()
	ct = _tuning.camera


func before_each() -> void:
	_saved_mode = Settings.get_value(&"camera_mode")
	Settings.set_value(&"camera_mode", &"chase")


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	Settings.set_value(&"camera_mode", _saved_mode)
	await tree.process_frame


func _car(def_path: String, road: RoadPath) -> PlayerCar:
	var def := load(def_path) as CarDef
	if not _params.has(def_path):
		_params[def_path] = VehicleParams.build(_tuning, def)
	var origin := FloatingOrigin.new()
	tree.root.add_child(origin)
	_nodes.append(origin)
	origin.setup(_tuning.road.floating_origin_shift_km)
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as PlayerCar
	car.self_tick = false
	tree.root.add_child(car)
	_nodes.append(car)
	car.setup(RunContext.new(1), road, origin, def, _params[def_path])
	car.place_at(10.0, road.lane_center_d(1, 10.0), 30.0)
	return car


func _rig(car: PlayerCar, mode: StringName) -> CameraRig:
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	tree.root.add_child(rig)
	_nodes.append(rig)
	rig.set_physics_process(false)
	rig.set_mode(mode)
	rig.set_target(car, car.state, car.params.top_speed_mps)
	return rig


# ---------------------------------------------------------------- G4

func test_model_interior_replaces_the_procedural_cockpit() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _car(CALIB_DEF, road)
	var m := car.model
	check(m.has_authored_interior(), "the calibration car brings an interior")
	var rig := _rig(car, &"chase")
	check(not m.interior.visible, "interior hidden in chase")
	le(m.draw_surface_count(), CarModel.MERGED_DRAW_SURFACES_MAX, "5-draw budget outside the cockpit")
	rig.set_mode(&"cockpit")
	check(m.interior.visible, "interior shown in cockpit")
	check(car.visual.visible, "the body stays (its hood shows through the windscreen)")
	check(rig.cockpit() == null or not rig.cockpit().visible, "no procedural cockpit")
	eq(rig.model_interior(), m, "the rig shows this model's interior")
	check(rig.cockpit_eye_from_marker(), "eye from the authored cam_cockpit")
	near((rig.cockpit_eye_local() - ArtCalib.EYE).length(), 0.0, 1e-4, "at the marker")
	# Gauges follow speed and rpm; the steering wheel turns in CarVisual.
	car.state.v = Units.kmh_to_mps(ct.cockpit_speedo_max_kmh) * 0.5
	car.state.rpm = ct.cockpit_tach_max_rpm * 0.25
	rig.advance(DT)
	check(m.gauge_material != null, "the car's own gauges material")
	near(float(m.gauge_material.get_shader_parameter(&"speed_frac")), 0.5, 1e-4, "speedometer")
	near(float(m.gauge_material.get_shader_parameter(&"rpm_frac")), 0.25, 1e-4, "tachometer")
	var shared := (m.gauges.mesh.surface_get_material(0) as ShaderMaterial)
	ne(shared, m.gauge_material, "the imported material stays untouched")
	var redline := _tuning.vehicle.engine_redline_rpm / ct.cockpit_tach_max_rpm
	near(float(m.gauge_material.get_shader_parameter(&"redline_frac")), clampf(redline, 0.0, 1.0), 1e-4, "red band")
	var sw_rest := m.steering_wheel.transform
	car.state.steer_angle = 0.05
	car.visual.tick(DT, car.state, car.input)
	check(not m.steering_wheel.transform.is_equal_approx(sw_rest), "steering wheel turns")
	# Leaving hides it again.
	rig.set_mode(&"hood")
	check(not m.interior.visible, "hidden outside cockpit")
	check(car.visual.visible, "body shown")
	eq(rig.model_interior(), null, "released")
	rig.set_mode(&"cockpit")
	check(m.interior.visible, "shown again")
	# A rebuilt model (a car or look change) gets the view on the next tick.
	car.setup(RunContext.new(1), road, car.origin, car.car, car.params)
	var m2 := car.model
	ne(m2, m, "rebuilt")
	rig.advance(DT)
	check(m2.interior.visible, "the new model's interior is shown")
	eq(rig.model_interior(), m2, "and tracked")
	rig.free()
	check(not m2.interior.visible, "hidden when the rig leaves")


func test_placeholder_keeps_the_procedural_cockpit() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _car(PLACEHOLDER_DEF, road)
	check(not car.model.has_authored_interior(), "no interior on the placeholder")
	var rig := _rig(car, &"cockpit")
	check(rig.cockpit() != null and rig.cockpit().visible, "procedural cockpit")
	check(not car.visual.visible, "body hidden")
	eq(rig.model_interior(), null, "no model interior")


func test_target_change_moves_the_interior() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var calib := _car(CALIB_DEF, road)
	var placeholder := _car(PLACEHOLDER_DEF, road)
	var rig := _rig(calib, &"cockpit")
	check(calib.model.interior.visible, "calib interior shown")
	rig.set_target(placeholder, placeholder.state, placeholder.params.top_speed_mps)
	check(not calib.model.interior.visible, "the old target's interior is hidden")
	check(calib.visual.visible, "and its body shown")
	check(not placeholder.visual.visible, "the placeholder gets the procedural cockpit")
	rig.set_target(calib, calib.state, calib.params.top_speed_mps)
	check(calib.model.interior.visible and calib.visual.visible, "back to the model interior")
	check(placeholder.visual.visible, "placeholder body restored")


# ---------------------------------------------------------------- G6

func test_hood_camera_mounts_on_the_models_cam_hood() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _car(CALIB_DEF, road)
	var rig := _rig(car, &"hood")
	rig.advance(DT)
	var mk := car.model.marker(&"cam_hood")
	near((rig.global_position - mk.global_position).length(), 0.0, 1e-3, "rigid at Markers/cam_hood")
	car.place_at(200.0, road.lane_center_d(0, 200.0), 40.0)
	rig.snap_to_target()
	rig.advance(DT)
	near((rig.global_position - mk.global_position).length(), 0.0, 1e-3, "follows the marker")


func test_hood_camera_ignores_a_stubbed_marker() -> void:
	var road := StraightRoadPath.new(3, _tuning.road)
	var car := _car(PLACEHOLDER_DEF, road)
	var stubs: PackedStringArray = car.model.root.get_meta(&"car_import_stubbed", PackedStringArray())
	check(stubs.has("Markers/cam_hood"), "the placeholder's hood marker is a stub")
	var rig := _rig(car, &"hood")
	rig.advance(DT)
	var mi := ct.mode_index(&"hood")
	var tp := car.global_transform
	var fwd := -tp.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var want := tp.origin - fwd * ct.mode_behind_m[mi] + Vector3.UP * ct.mode_height_m[mi]
	near((rig.global_position - want).length(), 0.0, 0.05, "camera.tres hood offsets (unchanged)")
