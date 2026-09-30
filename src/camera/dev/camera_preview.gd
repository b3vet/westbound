extends Node3D
## Camera preview (dev only). Spec: Cameras. Drives a stand-in car along the real world
## stack (ProceduralRoadPath, FloatingOrigin, RoadBuilder, Roadside, BiomeDirector, sky)
## with the real VehiclePhysics and scripted steering/speed, so the CameraRig can be
## judged in every mode, at any speed, mid lane change.
##
## The stand-in car follows the modular convention's origin (ground, between the axles,
## facing -Z), carries a Markers/cam_hood node, like the real models will, and hides
## its body in the cockpit view (set_body_visible, as PlayerCar).
##
## Keys: C cycle camera (saved) | Up/Down speed | Left/Right lane change | B boost punch
##       H hit shake | P close-pass shake | R reduced motion | A auto lane changes
##
## Snap hook (tools/snap.sh): --mode=chase|far|hood|overhead|cockpit  --speed_kmh=  --steer=-1..1
## (starts a lane change at once, holding that input for the physics' one-lane hold time,
## or --steer_hold_s=)  --lane=  --s=  --sky_t=  --boost  --shake=strength.
## --seconds= is consumed by snap.sh itself (extra simulated time before the capture);
## the capture lands --frames (default 30 = 0.5 s) + seconds after the setup, so
## --frames picks the moment within the lane change.

const CAR_DEF := "res://data/cars/falcon_gt.tres"
const SPEEDS_KMH: Array[float] = [100.0, 160.0, 200.0, 250.0, 280.0]
## Dev stand-in look (not gameplay numbers).
const BODY_SIZE := Vector3(1.9, 0.6, 4.5)
const BODY_LIFT := 0.2
const CABIN_SIZE := Vector3(1.6, 0.45, 2.1)
const CABIN_BACK := 0.35
const HOOD_MARKER := Vector3(0.0, 1.12, -1.7)
const PAINT := Color(0.85, 0.18, 0.12)
const GLASS := Color(0.12, 0.14, 0.2)
const SPEED_RAMP_MPS2 := 6.0
const AUTO_PERIOD_S := 3.0

@export var run_seed: int = 20260928
@export var start_lane: int = 1
@export var start_speed_kmh: float = 200.0
@export var auto_lane_changes: bool = true

var _tuning: Tuning
var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _sky: SkyRig
var _rig: CameraRig
var _car: Node3D
var _shadow: BlobShadow
var _car_def: CarDef
var _params: VehicleParams
var _state := VehicleState.new()
var _input := VehicleInput.new()
var _smp := RoadSample.new()

var _target_v: float = 0.0
var _steer: float = 0.0
var _steer_left_s: float = 0.0
var _auto_t: float = 0.0
var _auto_dir: int = 1
var _next_forget_s: float = 0.0


func _ready() -> void:
	_tuning = Tuning.load_default()
	_ctx = RunContext.new(run_seed)
	_road = ProceduralRoadPath.new(_ctx)
	_car_def = load(CAR_DEF) as CarDef
	_params = VehicleParams.build(_tuning, _car_def)

	_origin = FloatingOrigin.new()
	_origin.name = "FloatingOrigin"
	add_child(_origin)
	_origin.setup(_tuning.road.floating_origin_shift_km)
	_director = BiomeDirector.new()
	_director.name = "BiomeDirector"
	add_child(_director)
	_builder = RoadBuilder.new()
	_builder.name = "RoadBuilder"
	_builder.biome_director = _director
	add_child(_builder)
	_roadside = Roadside.new()
	_roadside.name = "Roadside"
	_roadside.biome_director = _director
	add_child(_roadside)

	_sky = $Sky
	_rig = $CameraRig
	_car = _make_car()
	add_child(_car)
	_shadow = (load("res://src/vehicle/blob_shadow.tscn") as PackedScene).instantiate()
	add_child(_shadow)

	_target_v = Units.kmh_to_mps(start_speed_kmh)
	VehiclePhysics.place(_state, _params, 0.0, _road.lane_center_d(start_lane, 0.0), _target_v)
	_road.ensure_generated_to(_view_ahead())
	_road.sample_into(_state.s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_director.setup(_ctx, _road, _origin)
	_builder.setup(_ctx, _road, _origin)
	_roadside.setup(_ctx, _road, _origin)
	_sky.setup(_ctx, _road, _origin)
	_builder.build_all_now(_state.s)
	Events.origin_shifted.connect(_on_origin_shifted)

	if Game.can_change_to(Game.COUNTDOWN):
		Game.change_state(Game.COUNTDOWN)
	if Game.can_change_to(Game.RUNNING):
		Game.change_state(Game.RUNNING)
	_place_car()
	_car.reset_physics_interpolation()
	_rig.set_target(_car, _state, _car_def.top_speed_mps(), _car_def)


func _physics_process(dt: float) -> void:
	if auto_lane_changes:
		_auto_t += dt
		if _auto_t >= AUTO_PERIOD_S:
			_auto_t = 0.0
			if not _lane_change(_auto_dir):
				_auto_dir = -_auto_dir
				_lane_change(_auto_dir)
	_input.clear()
	if _steer_left_s > 0.0:
		_input.steer = _steer
		_steer_left_s -= dt
	var v_before := _state.v
	VehiclePhysics.step(_state, _input, dt, _params, _road)
	# Cruise: hold the scripted speed (ramped); accel_long follows the scripted speed.
	_state.v = move_toward(v_before, _target_v, SPEED_RAMP_MPS2 * dt)
	_state.accel_long = (_state.v - v_before) / dt

	_road.ensure_generated_to(_view_ahead())
	if _state.s >= _next_forget_s:
		_road.forget_before(_state.s - _roadside.reach_behind_m() - _tuning.road.chunk_length_m)
		_next_forget_s = _state.s + _tuning.road.chunk_length_m
	_road.sample_into(_state.s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_place_car()


func _process(_delta: float) -> void:
	_director.update_view(_state.s)
	_builder.update_view(_state.s)
	_roadside.update_view(_state.s)
	_sky.update_view(_state.s)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_C:
			_rig.cycle_mode(true)   # dev: every mode, the hidden cockpit included
		KEY_UP:
			_step_speed(1)
		KEY_DOWN:
			_step_speed(-1)
		KEY_LEFT:
			_lane_change(-1)
		KEY_RIGHT:
			_lane_change(1)
		KEY_B:
			Events.boost_started.emit()
		KEY_H:
			Events.hit.emit(Events.HIT_TRAFFIC, 1)
		KEY_P:
			Events.scored.emit(Events.CLOSE_PASS, 0, 1.0, 0.0)
		KEY_R:
			Settings.set_value(&"reduced_motion", not bool(Settings.get_value(&"reduced_motion")))
		KEY_A:
			auto_lane_changes = not auto_lane_changes


func snap_setup(args: Dictionary) -> void:
	auto_lane_changes = false
	if args.has("sky_t"):
		_sky.sky_t = float(args["sky_t"])
	var lane := int(args.get("lane", start_lane))
	var s := float(args.get("s", _state.s))
	_target_v = Units.kmh_to_mps(float(args.get("speed_kmh", Units.mps_to_kmh(_target_v))))
	VehiclePhysics.place(_state, _params, s, _road.lane_center_d(lane, s), _target_v)
	_road.ensure_generated_to(_view_ahead())
	_road.sample_into(_state.s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_builder.build_all_now(_state.s)
	_roadside.update_view(_state.s)
	_director.update_view(_state.s)
	_sky.update_view(_state.s)
	_place_car()
	_car.reset_physics_interpolation()
	if args.has("mode"):
		_rig.set_mode(StringName(str(args["mode"])))
	_rig.snap_to_target()
	var steer := float(args.get("steer", 0.0))
	if steer != 0.0:
		var hold := float(args.get("steer_hold_s", _lane_hold_s()))
		_steer = clampf(steer, -1.0, 1.0)
		_steer_left_s = hold
	if args.get("boost", false):
		Events.boost_started.emit()
	if args.has("shake"):
		Events.camera_shake_requested.emit(float(args["shake"]), 1.0)


## Starts a one-lane change in `dir` (-1 left, +1 right). False at the road edge.
func _lane_change(dir: int) -> bool:
	var cur := _road.lane_index_at(_state.d, _state.s)
	var lane := cur + dir
	if cur < 0 or lane < 0 or lane >= _road.lane_count(_state.s) or _steer_left_s > 0.0:
		return false
	_steer = float(dir)
	_steer_left_s = _lane_hold_s()
	return true


## Full-input hold time that moves the car one lane at the current speed (physics'
## own capability measurement; allocates, dev only).
func _lane_hold_s() -> float:
	return _params.measure_lateral_move(maxf(_state.v, 1.0), _road.lane_width(_state.s)).hold_s


func _step_speed(dir: int) -> void:
	var kmh := Units.mps_to_kmh(_target_v)
	var i := 0
	while i < SPEEDS_KMH.size() - 1 and SPEEDS_KMH[i] < kmh - 1.0:
		i += 1
	_target_v = Units.kmh_to_mps(SPEEDS_KMH[clampi(i + dir, 0, SPEEDS_KMH.size() - 1)])


func _view_ahead() -> float:
	return _state.s + _builder.view_distance_m() + _tuning.road.chunk_length_m * 2.0


func _place_car() -> void:
	var p := _smp.local_point(_state.d, _origin.origin_x, _origin.origin_y, _origin.origin_z)
	var b := Basis(Vector3.UP, _smp.godot_yaw(_state.yaw))
	b = b * Basis(Vector3.RIGHT, VehiclePhysics.surface_pitch(_smp))
	_car.transform = Transform3D(b, p)
	_shadow.place(_smp, _state.d, _state.yaw, _car_def.length_m, _car_def.width_m, _origin)


func _on_origin_shifted(_offset: Vector3) -> void:
	_place_car()
	_car.reset_physics_interpolation()


## The stand-in body: hidden by the camera rig in the cockpit view.
class StandInCar:
	extends Node3D

	func set_body_visible(on: bool) -> void:
		for n in get_children():
			if n is MeshInstance3D:
				(n as MeshInstance3D).visible = on


func _make_car() -> Node3D:
	var car := StandInCar.new()
	car.name = "StandInCar"
	car.add_child(_box("Body", BODY_SIZE, Vector3(0.0, BODY_LIFT + BODY_SIZE.y * 0.5, 0.0), PAINT))
	var cabin_y := BODY_LIFT + BODY_SIZE.y + CABIN_SIZE.y * 0.5
	car.add_child(_box("Cabin", CABIN_SIZE, Vector3(0.0, cabin_y, CABIN_BACK), GLASS))
	var markers := Node3D.new()
	markers.name = "Markers"
	car.add_child(markers)
	var hood := Node3D.new()
	hood.name = "cam_hood"
	hood.position = HOOD_MARKER
	markers.add_child(hood)
	return car


func _box(node_name: String, size: Vector3, at: Vector3, color: Color) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var cols := PackedColorArray()
	cols.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	cols.fill(color)
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.position = at
	mi.material_override = load("res://assets/shaders/materials/world.tres")
	return mi
