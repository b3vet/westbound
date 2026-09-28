extends Node3D
## Dev scene for the road build (WP1.2). Spec: World → Road; Performance budget →
## Shadows. Shows RoadBuilder chunks on a fixture or the procedural road, a proxy car
## with a BlobShadow, and the chunk/triangle/draw-call numbers.
##
##   tools/snap.sh src/road/dev/road_preview.tscn --renderer=both --fixture=arc_left --cam=high
##   tools/snap.sh src/road/dev/road_preview.tscn --fixture=procedural --seed=7 --s=12000
##   tools/snap.sh src/road/dev/road_preview.tscn --fixture=taper --s=380 --cam=high
##   tools/snap.sh src/road/dev/road_preview.tscn --speed_kmh=250 --seconds=3   # drives
##
## Options (snap_setup args): fixture = straight | arc_left | arc_right | taper |
## procedural; seed (procedural); s (focus, m); cam = near | high | driver | top; lanes;
## grade (straight, rise/run); radius (arcs, m); view (view distance, m);
## speed_kmh (drive along the road every frame, time-sliced building + origin shifts);
## roadside=true (adds WP1.4's Roadside props, to check the combined look).
## Ground colors come from a BiomeDirector (farmland). The label shows the road's own
## numbers and, a few frames in, the renderer's draw calls and primitives for the frame.

const FIXTURES := ["straight", "arc_left", "arc_right", "taper", "procedural"]
const CAMS := ["near", "high", "driver", "top"]
## Proxy car body (m): width, height, length, and ride height of the body.
const CAR_SIZE := Vector3(1.9, 1.25, 4.6)
const CAR_RIDE_M := 0.3
## Camera rigs: (behind, height, look ahead, look height) in meters.
const CAM_NEAR := Vector4(8.0, 2.6, 30.0, 0.9)
const CAM_DRIVER := Vector4(-1.0, 1.15, 60.0, 1.0)
const CAM_HIGH := Vector4(40.0, 55.0, 140.0, 0.0)
## Top-down: (ahead of the focus, height) in meters.
const CAM_TOP := Vector2(40.0, 45.0)
## The proxy car and a lone shadow sit this far ahead of the focus (m).
const CAR_AHEAD_M := 16.0
const SHADOW_AHEAD_M := 24.0
const FAR_MARGIN_M := 20.0
## Frames after setup before the renderer monitors are read.
const STATS_FRAME := 3

@onready var _origin: FloatingOrigin = $FloatingOrigin
@onready var _builder: RoadBuilder = $RoadBuilder
@onready var _camera: Camera3D = $Camera3D
@onready var _car: MeshInstance3D = $Car
@onready var _car_shadow: BlobShadow = $CarShadow
@onready var _lone_shadow: BlobShadow = $LoneShadow
@onready var _label: Label = $UI/Label

var _tuning: Tuning
var _road: RoadPath
var _fixture: String = "straight"
var _cam: String = "near"
var _s: float = 0.0
var _speed_mps: float = 0.0
var _smp := RoadSample.new()
var _director: BiomeDirector
var _roadside: Roadside
var _frames: int = 0
var _info: String = ""


func _ready() -> void:
	_tuning = Tuning.load_default()
	_configure({})


func snap_setup(args: Dictionary) -> void:
	_configure(args)


func _configure(args: Dictionary) -> void:
	_fixture = String(args.get("fixture", "straight"))
	if not FIXTURES.has(_fixture):
		push_warning("road_preview: unknown fixture %s (%s)" % [_fixture, ", ".join(FIXTURES)])
		_fixture = "straight"
	_cam = String(args.get("cam", "near"))
	if not CAMS.has(_cam):
		push_warning("road_preview: unknown cam %s (%s)" % [_cam, ", ".join(CAMS)])
		_cam = "near"
	var rt := _tuning.road
	var lanes := int(args.get("lanes", rt.lanes_default))
	var ctx := RunContext.new(int(args.get("seed", 1)))
	match _fixture:
		"arc_left", "arc_right":
			var bend := -1 if _fixture == "arc_left" else 1
			_road = ArcRoadPath.new(float(args.get("radius", rt.min_curve_radius_m)), bend, lanes, rt)
		"taper":
			_road = LaneChangeRoadPath.new(lanes, maxi(lanes - 1, rt.lanes_min), 400.0, rt.lane_taper_length_m, true, rt)
		"procedural":
			_road = ProceduralRoadPath.new(ctx)
		_:
			_road = StraightRoadPath.new(lanes, rt, 0.0, float(args.get("grade", 0.0)))
	_s = float(args.get("s", 0.0))
	_speed_mps = Units.kmh_to_mps(float(args.get("speed_kmh", 0.0)))
	_builder.view_distance_override_m = float(args.get("view", -1.0))
	_origin.setup(rt.floating_origin_shift_km)
	_road.ensure_generated_to(_s + _builder.view_distance_m() + rt.chunk_length_m * 2.0)
	_road.sample_into(_s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	if _director != null:
		_director.free()
	_director = BiomeDirector.new()
	add_child(_director)
	_director.setup(ctx, _road, _origin)
	if _roadside != null:
		_roadside.free()
		_roadside = null
	if bool(args.get("roadside", false)):
		_roadside = Roadside.new()
		_roadside.biome_director = _director
		if _builder.view_distance_override_m >= 0.0:
			_roadside.view_distance_override_m = _builder.view_distance_override_m
		add_child(_roadside)
		_roadside.setup(ctx, _road, _origin)
		_roadside.update_view(_s)
	_builder.biome_director = _director
	_builder.setup(ctx, _road, _origin)
	_builder.build_all_now(_s)
	_frames = 0
	_camera.far = _builder.view_distance_m() + FAR_MARGIN_M
	_place_view()


func _process(delta: float) -> void:
	if _road == null:
		return
	_frames += 1
	if _speed_mps > 0.0:
		_s += _speed_mps * delta
		_road.ensure_generated_to(_s + _builder.view_distance_m() + _tuning.road.chunk_length_m * 2.0)
		_road.sample_into(_s, _smp)
		_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
		_director.update_view(_s)
		_builder.update_view(_s)
		if _roadside != null:
			_roadside.update_view(_s)
		_place_view()
	if _frames >= STATS_FRAME:
		_label.text = "%s\nframe: %d draw calls, %d primitives (road chunks: %d draw calls before culling)" % [
			_info, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			_builder.draw_call_count()]


func _place_view() -> void:
	var lane_d := _road.lane_center_d(mini(1, _road.lane_count(_s) - 1), _s)
	var rig := CAM_NEAR
	var cam_d := lane_d
	var look_d := lane_d
	if _cam == "driver":
		rig = CAM_DRIVER
	elif _cam == "high":
		rig = CAM_HIGH
		cam_d = 0.0
	if _cam == "top":
		var centre := _local(_s + CAM_TOP.x, lane_d, 0.0)
		_camera.look_at_from_position(centre + Vector3.UP * CAM_TOP.y, centre,
				Vector3(_smp.tangent.x, 0.0, _smp.tangent.z).normalized())
	else:
		var eye := _local(_s - rig.x, cam_d, rig.y)
		var target := _local(_s + rig.z, look_d, rig.w)
		_camera.look_at_from_position(eye, target, Vector3.UP)
	_camera.reset_physics_interpolation()

	var car_s := _s + CAR_AHEAD_M
	_road.sample_into(car_s, _smp)
	var frame := Basis(_smp.right, _smp.up, -_smp.tangent)
	var body := _smp.local_point(lane_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
			+ _smp.up * (CAR_RIDE_M + 0.5 * CAR_SIZE.y)
	_car.transform = Transform3D(frame, body)
	(_car.mesh as BoxMesh).size = CAR_SIZE
	_car_shadow.place(_smp, lane_d, 0.0, CAR_SIZE.z, CAR_SIZE.x, _origin)
	_road.sample_into(_s + SHADOW_AHEAD_M, _smp)
	_lone_shadow.place(_smp, _road.lane_center_d(0, _s), 0.0, CAR_SIZE.z, CAR_SIZE.x, _origin)

	_info = "%s  s=%.0f m  cam=%s  lanes=%d  view=%.0f m  |  chunks %d (pool %d)  draw calls %d  tris %d  shifts %d" % [
		_fixture, _s, _cam, _road.lane_count(_s), _builder.view_distance_m(),
		_builder.active_chunk_count(), _builder.pool_size(), _builder.draw_call_count(),
		_builder.triangle_count(), _origin.shift_count]
	_label.text = _info


func _local(s: float, d: float, h: float) -> Vector3:
	_road.sample_into(s, _smp)
	return _smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z) + _smp.up * h
