extends Node3D
## Dev preview of one checkpoint landmark (WP5.3 review scene). Spec: World →
## Checkpoint landmarks, Color script (every look across the whole timeline), Night
## lighting (retro-reflective signs), Performance budget. The real road (RoadBuilder),
## roadside (Roadside), sky (SkyRig) and Landmarks on the procedural road, with the
## player's car on the road `dist` metres before the first checkpoint.
##
##   tools/snap.sh src/world/landmarks/dev/landmark_preview.tscn --renderer=both \
##       --kind=suspension_bridge --dist=150 --cam=chase --sweep=sky_t:0.2,0.5,0.7
##
## snap_setup args: --kind=toll_gantry|suspension_bridge|sign_gantry|tunnel_portal,
## --dist=<m before the checkpoint> (negative: past it; the 1 km sign is at 1000),
## --cam=chase|hood|high|side, --sky_t=<0..1>, --seed=N, --lane=0..2,
## --roadside=false (no roadside props), --clear=false (the roadside ignores the
## landmark, as before WP5.5), --lights=<player fake-light gain, default 1>,
## --dump_atlas=<png path> (saves the sign-text atlas).
## Prints the frame's draw calls and the landmarks' own share ("snap: ..." lines).

const SKY_SCENE := "res://src/sun/sky.tscn"
const CAR_PATH := "res://data/cars/falcon_gt.tres"
const STATS_FRAME := 4
const FAR_MARGIN_M := 20.0
## Review cameras: (behind the car, height, look ahead, look height); chase and hood
## mirror CameraTuning's modes (the rig's springs are at rest).
const CAM_HIGH := Vector4(60.0, 40.0, 220.0, 0.0)
## Side view: this far right of the road, looking across at the checkpoint.
const SIDE_D_M := 90.0
const SIDE_HEIGHT_M := 12.0

var _args: Dictionary = {}
var _t: Tuning
var _road: RoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _landmarks: Landmarks
var _sky: SkyRig
var _camera: Camera3D
var _car: Node3D
var _label: Label
var _frame: int = -1
var _info: String = ""


func _ready() -> void:
	_build.call_deferred()


func snap_setup(args: Dictionary) -> void:
	_args = args
	_build()
	await get_tree().process_frame


func _build() -> void:
	for c in get_children():
		c.free()
	_t = Tuning.load_default()
	var kind := StringName(String(_args.get("kind", "toll_gantry")))
	var dist := float(_args.get("dist", 150.0))
	var cam := String(_args.get("cam", "chase"))
	var ctx := RunContext.new(int(_args.get("seed", 7)), RunContext.MODE_JOURNEY, _t)
	_road = ProceduralRoadPath.new(ctx)
	var cp := _t.legs.leg_length_m()
	var s := cp - dist
	var view := float(_t.quality.view_distance_m[1])
	_road.ensure_generated_to(s + view + 2.0 * _t.legs.leg_length_m())

	_origin = FloatingOrigin.new()
	_origin.name = "FloatingOrigin"
	add_child(_origin)
	_origin.setup(_t.road.floating_origin_shift_km)
	var smp := _road.sample(s)
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	_director = BiomeDirector.new()
	add_child(_director)
	_director.setup(ctx, _road, _origin)
	_builder = RoadBuilder.new()
	_builder.name = "RoadBuilder"
	_builder.biome_director = _director
	_builder.view_distance_override_m = view
	add_child(_builder)
	_builder.setup(ctx, _road, _origin)
	_builder.build_all_now(s)
	if bool(_args.get("roadside", true)):
		_roadside = Roadside.new()
		_roadside.name = "Roadside"
		_roadside.biome_director = _director
		_roadside.view_distance_override_m = view
		_roadside.landmark_style_override = kind
		_roadside.clear_landmarks = bool(_args.get("clear", true))
		add_child(_roadside)
		_roadside.setup(ctx, _road, _origin)
		_roadside.update_view(s)
	_landmarks = Landmarks.new()
	_landmarks.name = "Landmarks"
	_landmarks.biome_director = _director
	_landmarks.style_override = kind
	_landmarks.view_distance_override_m = view
	add_child(_landmarks)
	_landmarks.setup(ctx, _road, _origin)
	_landmarks.update_view(s)
	if _args.has("dump_atlas"):
		_landmarks.atlas.texture.get_image().save_png(String(_args["dump_atlas"]))

	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.name = "Sky"
	add_child(_sky)
	_sky.setup(ctx, _road, _origin)
	_sky.view_distance_override_m = view
	_sky.sky_t = float(_args.get("sky_t", 0.2))
	_sky.update_view(s)

	var lane := clampi(int(_args.get("lane", 1)), 0, _road.lane_count(s) - 1)
	var d := _road.lane_center_d(lane, s)
	_place_car(s, d)
	_camera = Camera3D.new()
	_camera.near = _t.camera.near_plane_m
	_camera.far = view + FAR_MARGIN_M
	_camera.fov = _t.camera.fov_min_deg
	add_child(_camera)
	_place_camera(cam, s, d, cp)
	_camera.make_current()
	# The player's fake headlight (the retro-reflective signs answer it at night).
	var fwd := -_camera.global_transform.basis.z
	_sky.set_player_light(_car.position + Vector3.UP * 0.7, Vector3(fwd.x, 0.0, fwd.z).normalized(),
		float(_args.get("lights", 1.0)))
	_sky.push_now()

	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	ui.add_child(_label)
	_info = "%s  %.0f m before the checkpoint  cam=%s  sky_t=%.2f" % [kind, dist, cam, _sky.sky_t]
	_label.text = _info
	_frame = 0


func _process(_delta: float) -> void:
	if _frame < 0:
		return
	_frame += 1
	if _frame != STATS_FRAME:
		return
	var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var line := "frame: %d draw calls, %d primitives | landmarks: %d instances (%d draw calls max), %d tris" % [
		dc, prims, _landmarks.live_slots().size(), _landmarks.draw_calls(), _landmarks.triangles()]
	_label.text = _info + "\n" + line
	print("snap: landmark_preview %s | %s" % [_info, line])


func _place_car(s: float, d: float) -> void:
	var car_def: CarDef = load(CAR_PATH)
	var model := CarModel.load_model(car_def.model_scene_path, car_def)
	model.apply_paint(car_def.default_paint)
	_car = model.root
	add_child(_car)
	var smp := _road.sample(s)
	_car.transform = Transform3D(Basis(smp.right, smp.up, -smp.tangent),
		smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z))


func _place_camera(cam: String, s: float, d: float, cp: float) -> void:
	var c := _t.camera
	var i := maxi(c.modes.find(cam), 0)
	var rig := Vector4(c.mode_behind_m[i], c.mode_height_m[i], c.mode_look_ahead_m[i], c.mode_look_height_m[i])
	var eye_d := d
	var look_d := d
	if cam == "high":
		rig = CAM_HIGH
		eye_d = 0.0
		look_d = 0.0
	if cam == "side":
		var eye := _local(cp - 60.0, SIDE_D_M, SIDE_HEIGHT_M)
		_camera.look_at_from_position(eye, _local(cp, 0.0, SIDE_HEIGHT_M * 0.5), Vector3.UP)
		return
	var from := _local(s - rig.x, eye_d, rig.y)
	var to := _local(s + rig.z, look_d, rig.w)
	_camera.look_at_from_position(from, to, Vector3.UP)


func _local(s: float, d: float, h: float) -> Vector3:
	var smp := _road.sample(s)
	return smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z) + Vector3.UP * h
