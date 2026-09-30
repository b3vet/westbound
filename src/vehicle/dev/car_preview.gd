extends Node3D
## Car preview (WP2.1 review scene; dev only). Spec: Cars → Modular car convention,
## Car shader; Car physics and feel → Visual body motion. The PlayerCar on the
## procedural road under the real sky and color script: a turntable (the camera
## orbits the parked car) or a drive-by (the car drives at a set speed, with steer and
## brake inputs to show roll, pitch, wheels and brake lights).
##
##   tools/snap.sh src/vehicle/dev/car_preview.tscn --renderer=both \
##       --car=falcon_gt --cam=chase3q --speed_kmh=120 --steer=0.3 --sweep=sky_t:0.2,0.38,0.66
##   tools/parity.sh src/vehicle/dev/car_preview.tscn --cam=chase3q --sky_t=0.38
##
## snap_setup options: --car=falcon_gt|night_viper|brute_v8, --cam=chase|chase3q|
## front3q|side|front|rear|top|orbit|hood, --angle_deg=<orbit angle, 0 = behind>,
## --speed_kmh=<0 parks the car>, --steer=<-1..1>, --brake=<0..1>, --sky_t=<0..1>,
## --lane=<index>, --paint=<#rrggbb>, --hide_car=true (world-only baseline).
## WP-ART-G: --car_def=<res path to a CarDef> (a car outside data/cars, e.g. the
## calibration car tests/art/fixtures/calib_car/calib_car.tres), --cam=cockpit (the eye
## at the model's authored Markers/cam_cockpit, else CameraTuning's default, with the
## model's own Interior shown as the cockpit view shows it, G4), --blinkers=left|right|
## hazard (G1 signal lights).
## Keys: C camera, 1/2/3 car, Up/Down speed, Left/Right steer, Space brake, T spin.

const CARS: Array[StringName] = [&"falcon_gt", &"night_viper", &"brute_v8"]
const CAMS: Array[StringName] = [&"chase", &"chase3q", &"front3q", &"side", &"front", &"rear", &"top", &"orbit", &"hood",
	&"cockpit"]
## Cockpit view: look this far ahead and this high (the rig's cockpit mode_look_* are the
## tuned numbers; a preview approximation).
const COCKPIT_LOOK := Vector3(0.0, 0.3, -40.0)
## Camera rigs in the car's frame (x right, y up, z back): [eye, look-at]. Dev values.
const RIGS := {
	&"chase": [Vector3(0.0, 2.3, 7.5), Vector3(0.0, 0.9, -8.0)],
	&"chase3q": [Vector3(-3.4, 1.9, 6.2), Vector3(0.0, 0.7, -0.5)],
	&"front3q": [Vector3(3.2, 1.6, -6.4), Vector3(0.0, 0.6, 0.0)],
	&"side": [Vector3(-6.8, 1.2, 0.0), Vector3(0.0, 0.6, 0.0)],
	&"front": [Vector3(0.0, 1.3, -7.0), Vector3(0.0, 0.6, 0.0)],
	&"rear": [Vector3(0.0, 1.4, 6.8), Vector3(0.0, 0.7, 0.0)],
	&"top": [Vector3(0.0, 9.0, 0.5), Vector3(0.0, 0.0, 0.0)],
}
const ORBIT_RADIUS_M := 7.0
const ORBIT_HEIGHT_M := 1.9
const ORBIT_DEG_PER_S := 20.0
const SPEEDS_KMH: Array[float] = [0.0, 60.0, 120.0, 200.0, 280.0]
const START_S := 300.0
const PLAYER_CAR_SCENE := preload("res://src/vehicle/player_car.tscn")

@export var run_seed: int = 20260928
@export var start_car: StringName = &"falcon_gt"
@export var start_lane: int = 1

## Holds a speed with throttle (P control) and passes steer and brake through.
class CruiseController:
	extends VehicleController
	var target_mps := 0.0
	var steer := 0.0
	var brake := 0.0
	## Throttle per m/s below the target (dev value).
	var gain := 1.5

	func update(_dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		out_input.steer = steer
		out_input.brake = brake
		out_input.throttle = 0.0 if brake > 0.0 else clampf((target_mps - state.v) * gain, 0.0, 1.0)
		out_input.boost = false


var car: PlayerCar
var cruise := CruiseController.new()
var cam_mode: StringName = &"chase3q"
var orbit_deg: float = 0.0
var spin: bool = true

var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _builder: RoadBuilder
var _car_id: StringName
var _speed_index: int = 2
var _snapping: bool = false

@onready var _sky: SkyRig = $Sky
@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_ctx = RunContext.new(run_seed)
	_road = ProceduralRoadPath.new(_ctx)
	_origin = FloatingOrigin.new()
	_origin.name = "FloatingOrigin"
	add_child(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_builder = RoadBuilder.new()
	_builder.name = "RoadBuilder"
	add_child(_builder)
	_builder.setup(_ctx, _road, _origin)
	_sky.setup(_ctx, _road, _origin)
	car = PLAYER_CAR_SCENE.instantiate() as PlayerCar
	car.self_tick = false
	add_child(car)
	car.controller = cruise
	_load_car(start_car)
	cruise.target_mps = Units.kmh_to_mps(SPEEDS_KMH[_speed_index])
	_respawn(START_S, start_lane)


func _load_car(id: StringName) -> void:
	_load_def("res://data/cars/%s.tres" % id)


func _load_def(path: String) -> void:
	var def := load(path) as CarDef if ResourceLoader.exists(path) else null
	if def == null:
		push_warning("car_preview: no car %s" % path)
		return
	_car_id = def.id
	car.setup(_ctx, _road, _origin, def)


func _respawn(s: float, lane: int) -> void:
	_road.ensure_generated_to(s + _builder.view_distance_m() + _ctx.tuning.road.chunk_length_m * 2.0)
	var smp := _road.sample(s)
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	car.place_at(s, _road.lane_center_d(clampi(lane, 0, _road.lane_count(s) - 1), s), cruise.target_mps)
	_builder.build_all_now(s)
	_place_camera(0.0)
	_camera.reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	car.tick(delta)
	var smp := car.road_sample()
	_road.ensure_generated_to(car.state.s + _builder.view_distance_m() + _ctx.tuning.road.chunk_length_m * 2.0)
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	_place_camera(delta)


func _process(_delta: float) -> void:
	_builder.update_view(car.state.s)
	_sky.update_view(car.state.s)
	var fwd := -car.global_transform.basis.z
	_sky.set_player_light(car.global_position + fwd * 2.0 + Vector3.UP * 0.7, fwd, 1.0)


func _place_camera(delta: float) -> void:
	var eye: Vector3
	var at: Vector3
	if cam_mode == &"orbit":
		if spin and not _snapping:
			orbit_deg = fposmod(orbit_deg + ORBIT_DEG_PER_S * delta, 360.0)
		var a := deg_to_rad(orbit_deg)
		eye = Vector3(sin(a) * ORBIT_RADIUS_M, ORBIT_HEIGHT_M, cos(a) * ORBIT_RADIUS_M)
		at = Vector3(0.0, 0.6, 0.0)
	elif cam_mode == &"cockpit":
		# The model's authored eye, as CameraRig's cockpit mode takes it (else the
		# CarDef-proportional default); the model's Interior shows (G4).
		var mk := car.model.marker(&"cam_cockpit")
		var stubs: PackedStringArray = car.model.root.get_meta(&"car_import_stubbed", PackedStringArray())
		if mk != null and not stubs.has("Markers/cam_cockpit") and not car.model.stubbed.has("Markers/cam_cockpit"):
			eye = mk.position
		else:
			eye = _ctx.tuning.camera.cockpit_eye_default(car.car.length_m, car.car.width_m, car.car.height_m)
		at = COCKPIT_LOOK
	elif cam_mode == &"hood":
		# As the camera rig mounts it: rigidly on Markers/cam_hood, looking along -Z.
		var mk := car.model.marker(&"cam_hood")
		eye = mk.position if mk != null else Vector3.UP
		at = eye + Vector3.FORWARD * ORBIT_RADIUS_M
	else:
		var rig: Array = RIGS.get(cam_mode, RIGS[&"chase3q"])
		eye = rig[0]
		at = rig[1]
	# The car's yaw frame without its grade pitch keeps the horizon level.
	var xf := Transform3D(Basis(Vector3.UP, car.road_sample().godot_yaw(car.state.yaw)), car.position)
	_camera.look_at_from_position(xf * eye, xf * at, Vector3.UP)
	Quality.apply_far_plane(_camera)


## Snap hook (tools/snap.sh).
func snap_setup(args: Dictionary) -> void:
	_snapping = true
	if args.has("car_def"):
		_load_def(str(args["car_def"]))
	elif args.has("car") and StringName(str(args["car"])) != _car_id:
		_load_car(StringName(str(args["car"])))
	if args.has("paint"):
		car.model.apply_paint(Color(str(args["paint"])))
	_sky.sky_t = float(args.get("sky_t", _sky.sky_t))
	cam_mode = StringName(str(args.get("cam", cam_mode)))
	orbit_deg = float(args.get("angle_deg", orbit_deg))
	cruise.target_mps = Units.kmh_to_mps(float(args.get("speed_kmh", 120.0)))
	cruise.steer = float(args.get("steer", 0.0))
	cruise.brake = float(args.get("brake", 0.0))
	_respawn(START_S, int(args.get("lane", start_lane)))
	# --hide_car=true: the same frame without the car (parity baseline of the world).
	car.visible = not bool(args.get("hide_car", false))
	car.model.set_interior_visible(cam_mode == &"cockpit")
	var blink := str(args.get("blinkers", ""))
	car.visual.set_blinkers(blink == "left" or blink == "hazard", blink == "right" or blink == "hazard")
	_sky.push_now()
	for i in 2:
		await get_tree().process_frame
	print("snap: car_preview car=%s cam=%s sky_t=%.2f draw calls %d, primitives %d" % [
		_car_id, cam_mode, _sky.sky_t,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.echo:
		return
	match key.keycode:
		KEY_LEFT, KEY_RIGHT:
			var dir := -1.0 if key.keycode == KEY_LEFT else 1.0
			cruise.steer = dir if key.pressed else 0.0
		KEY_SPACE:
			cruise.brake = 1.0 if key.pressed else 0.0
	if not key.pressed:
		return
	match key.keycode:
		KEY_C:
			cam_mode = CAMS[(CAMS.find(cam_mode) + 1) % CAMS.size()]
		KEY_T:
			spin = not spin
		KEY_UP, KEY_DOWN:
			_speed_index = clampi(_speed_index + (1 if key.keycode == KEY_UP else -1), 0, SPEEDS_KMH.size() - 1)
			cruise.target_mps = Units.kmh_to_mps(SPEEDS_KMH[_speed_index])
		KEY_1, KEY_2, KEY_3:
			_load_car(CARS[key.keycode - KEY_1])
			_respawn(car.state.s, _road.lane_index_at(car.state.d, car.state.s))
