extends Node3D
## M1 integration scene: the empty-road drive (plan Phase 1, Gate M1; spec M1
## "an empty-road 20-minute drive holds 60 fps ... looks right across the whole
## color script"). Dev-only, replaced by the real run loop in Phase 4.
##
## A placeholder car rides a lane of the procedural road kinematically (no
## physics yet) with the real world stack: ProceduralRoadPath, FloatingOrigin,
## RoadBuilder, Roadside, BiomeDirector, the sky/color script and the dev HUD.
##
## Controls (desktop / phone):
##   C or tap the upper-right quarter  cycle camera (chase, far, hood, high)
##   Up/Down or tap the right edge     speed +/- (100 / 160 / 200 / 250 / 280 km/h)
##   Left/Right or tap the left edge   change lane
##   backtick / three-finger tap       dev HUD (and the sky_t slider when present)

const CAMERAS: Array[StringName] = [&"chase", &"far", &"hood", &"high"]
## Camera rigs: [behind_m, height_m, look_ahead_m, look_height_m]. Dev values.
const RIGS := {
	&"chase": [7.5, 2.4, 14.0, 1.0],
	&"far": [13.0, 4.2, 20.0, 1.0],
	&"hood": [-0.6, 1.15, 30.0, 1.0],
	&"high": [20.0, 16.0, 45.0, 0.0],
}
const SPEEDS_KMH: Array[float] = [100.0, 160.0, 200.0, 250.0, 280.0]
const CAR_SIZE := Vector3(1.9, 1.3, 4.5)
const LANE_CHANGE_S := 1.0

@export var run_seed: int = 20260928
@export var start_speed_index: int = 2
@export var start_lane: int = 1

var _tuning: Tuning
var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _camera: Camera3D
var _car: MeshInstance3D
var _shadow: BlobShadow
var _smp := RoadSample.new()
var _look := RoadSample.new()

var _s: float = 0.0
var _d: float = 0.0
var _lane: int = 1
var _lane_from_d: float = 0.0
var _lane_t: float = 1.0
var _speed_index: int = 2
var _cam_index: int = 0
var _forget_every_m: float = 500.0
var _next_forget_s: float = 0.0


func _ready() -> void:
	_tuning = Tuning.load_default()
	_ctx = RunContext.new(run_seed)
	_road = ProceduralRoadPath.new(_ctx)
	_speed_index = clampi(start_speed_index, 0, SPEEDS_KMH.size() - 1)

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

	_camera = $Camera3D
	_car = _make_car()
	add_child(_car)
	_shadow = (load("res://src/vehicle/blob_shadow.tscn") as PackedScene).instantiate()
	add_child(_shadow)

	_lane = start_lane
	_d = _road.lane_center_d(_lane, 0.0)
	_lane_from_d = _d
	_s = 0.0
	_road.ensure_generated_to(_view_ahead())
	_road.sample_into(_s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)

	_director.setup(_ctx, _road, _origin)
	_builder.setup(_ctx, _road, _origin)
	_roadside.setup(_ctx, _road, _origin)
	_builder.build_all_now(_s)
	Events.origin_shifted.connect(_on_origin_shifted)

	if Game.can_change_to(Game.COUNTDOWN):
		Game.change_state(Game.COUNTDOWN)
	if Game.can_change_to(Game.RUNNING):
		Game.change_state(Game.RUNNING)
	_place_all()
	_car.reset_physics_interpolation()
	_camera.reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	var v := Units.kmh_to_mps(SPEEDS_KMH[_speed_index])
	_s += v * delta
	if _lane_t < 1.0:
		_lane_t = minf(1.0, _lane_t + delta / LANE_CHANGE_S)
		var target := _road.lane_center_d(_lane, _s)
		_d = lerpf(_lane_from_d, target, smoothstep(0.0, 1.0, _lane_t))
	else:
		_d = _road.lane_center_d(_lane, _s)

	_road.ensure_generated_to(_view_ahead())
	if _s >= _next_forget_s:
		_road.forget_before(_s - _roadside.reach_behind_m() - _tuning.road.chunk_length_m)
		_next_forget_s = _s + _forget_every_m

	_road.sample_into(_s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_place_all()


func _process(_delta: float) -> void:
	_director.update_view(_s)
	_builder.update_view(_s)
	_roadside.update_view(_s)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_C:
				_cycle_camera()
			KEY_UP:
				_speed_index = mini(_speed_index + 1, SPEEDS_KMH.size() - 1)
			KEY_DOWN:
				_speed_index = maxi(_speed_index - 1, 0)
			KEY_LEFT:
				_change_lane(-1)
			KEY_RIGHT:
				_change_lane(1)
	elif event is InputEventScreenTouch and event.pressed:
		var p: Vector2 = (event as InputEventScreenTouch).position
		var size := get_viewport().get_visible_rect().size
		if p.x < size.x * 0.15:
			_change_lane(-1 if p.y < size.y * 0.5 else 1)
		elif p.x > size.x * 0.85:
			if p.y < size.y * 0.5:
				_speed_index = mini(_speed_index + 1, SPEEDS_KMH.size() - 1)
			else:
				_speed_index = maxi(_speed_index - 1, 0)
		elif p.x > size.x * 0.5 and p.y < size.y * 0.25:
			_cycle_camera()


## Snap hook (tools/snap.sh): --s=, --cam=, --speed_kmh=, --lane=.
func snap_setup(args: Dictionary) -> void:
	if args.has("cam"):
		_cam_index = maxi(CAMERAS.find(StringName(str(args["cam"]))), 0)
	if args.has("lane"):
		_lane = int(args["lane"])
	if args.has("s"):
		_s = float(args["s"])
		_road.ensure_generated_to(_view_ahead())
		_road.sample_into(_s, _smp)
		_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
		_d = _road.lane_center_d(_lane, _s)
		_builder.build_all_now(_s)
		_roadside.update_view(_s)
		_director.update_view(_s)
		_place_all()


func _change_lane(dir: int) -> void:
	var n := clampi(_lane + dir, 0, _road.lane_count(_s) - 1)
	if n == _lane:
		return
	_lane_from_d = _d
	_lane = n
	_lane_t = 0.0


func _cycle_camera() -> void:
	_cam_index = (_cam_index + 1) % CAMERAS.size()


func _view_ahead() -> float:
	return _s + _builder.view_distance_m() + _tuning.road.chunk_length_m * 2.0


func _place_all() -> void:
	var up := _smp.up
	var body := _smp.local_point(_d, _origin.origin_x, _origin.origin_y, _origin.origin_z)
	var car_basis := Basis(Vector3.UP, _smp.godot_yaw())
	_car.transform = Transform3D(car_basis, body + up * (CAR_SIZE.y * 0.5))
	_shadow.place(_smp, _d, 0.0, CAR_SIZE.z, CAR_SIZE.x, _origin)

	var rig: Array = RIGS[CAMERAS[_cam_index]]
	var eye_s := _s - float(rig[0])
	_road.sample_into(maxf(eye_s, 0.0), _look)
	var eye := _look.local_point(_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) + _look.up * float(rig[1])
	_road.sample_into(_s + float(rig[2]), _look)
	var target := _look.local_point(_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) + _look.up * float(rig[3])
	_camera.look_at_from_position(eye, target, Vector3.UP)
	Quality.apply_far_plane(_camera)


func _on_origin_shifted(_offset: Vector3) -> void:
	_place_all()
	_car.reset_physics_interpolation()
	_camera.reset_physics_interpolation()


func _make_car() -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = CAR_SIZE
	var arrays := box.get_mesh_arrays()
	var cols := PackedColorArray()
	cols.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	cols.fill(Color(0.85, 0.18, 0.12))
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "PlaceholderCar"
	mi.mesh = mesh
	mi.material_override = load("res://assets/shaders/materials/world.tres")
	return mi
