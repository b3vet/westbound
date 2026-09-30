extends Node3D
## Dev preview of the roadside rhythm and the farmland biome (WP1.4 review
## scene). Spec: World → Road (roadside rhythm), Biomes (farmland plains),
## Performance budget (draw calls ≤ 100, triangles ≤ 150k at Medium).
##
##   tools/snap.sh src/road/dev/roadside_preview.tscn --renderer=both
##   tools/snap.sh src/road/dev/roadside_preview.tscn --fixture=procedural --seed=7 --s=4000 --cam=high
##
## snap_setup args: --fixture=straight|arc_right|arc_left|procedural, --seed=N,
## --s=<focus s>, --cam=driver|chase|high|side, --tier=low|medium|high,
## --standins=false (props only: no stand-in road or ground), --sky=false (no sky),
## --sky_t=<0..1> (position on the color-script timeline, default 0.2),
## --light=review (a high sun behind the camera and a brighter ambient, for judging
## shapes; pushed once after the sky, as linear values like every color global).
## The road and ground here are crude stand-ins drawn by this scene only (the real
## road is WP1.2's); the sky, fog and light are the real SkyRig's (WP1.3). Prints and
## shows the frame's draw calls and primitives (Performance monitors) and the
## roadside's own share.

const WORLD_MATERIAL := "res://assets/shaders/materials/world.tres"
const SKY_SCENE := "res://src/sun/sky.tscn"
const STANDIN_STEP_M := 10.0
const STANDIN_BEHIND_M := 120.0
const GROUND_HALF_WIDTH_M := 900.0
const STATS_FRAME := 4
const CAM_FOV_DEG := 68.0
const CAM_NEAR_M := 0.1
## Camera presets: lane, height, back (m behind the focus), look-ahead, look height.
const CAMS := {
	"driver": [1, 1.2, 0.0, 120.0, 0.9],
	"chase": [1, 2.6, 7.0, 60.0, 0.8],
	"high": [1, 55.0, 90.0, 320.0, 0.0],
	"side": [-1, 9.0, -30.0, 90.0, 4.0],
}
const SIDE_CAM_D_M := 70.0
const REVIEW_SUN_DIR := Vector3(-0.4, 0.7, 0.6)
## sRGB as authored; converted to linear before it is pushed (globals are linear).
const REVIEW_AMBIENT := Color(0.62, 0.6, 0.62)
const REVIEW_FOG_START_M := 300.0

var _args: Dictionary = {}
var _built: bool = false
var _frame: int = -1

var _ctx: RunContext
var _road: RoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _roadside: Roadside
var _standins: Node3D
var _camera: Camera3D
var _label: Label
var _sky: SkyRig


func _ready() -> void:
	_build.call_deferred()


func snap_setup(args: Dictionary) -> void:
	_args = args
	_built = false
	_build()
	await get_tree().process_frame


func _build() -> void:
	if _built:
		return
	_built = true
	for c in get_children():
		c.queue_free()
	var t := Tuning.load_default()
	var seed_value := int(_args.get("seed", 7))
	var focus_s := float(_args.get("s", 1500.0))
	_ctx = RunContext.new(seed_value, RunContext.MODE_JOURNEY, t)
	_road = _make_road(String(_args.get("fixture", "arc_right")), t)
	_road.ensure_generated_to(focus_s + t.quality.view_distance_m[t.quality.view_distance_m.size() - 1] + 2000.0)

	_origin = FloatingOrigin.new()
	_origin.setup(t.road.floating_origin_shift_km)
	add_child(_origin)
	var smp := _road.sample(focus_s)
	_origin.origin_x = smp.pos_x
	_origin.origin_y = smp.pos_y
	_origin.origin_z = smp.pos_z

	_director = BiomeDirector.new()
	add_child(_director)
	_director.setup(_ctx, _road, _origin)

	var tier := String(_args.get("tier", "medium"))
	var ti := maxi(t.quality.tier_names.find(tier), 0)
	var view_m: float = t.quality.view_distance_m[ti]
	_roadside = Roadside.new()
	_roadside.name = "Roadside"
	_roadside.biome_director = _director
	_roadside.view_distance_override_m = view_m
	add_child(_roadside)
	_roadside.setup(_ctx, _road, _origin)
	_roadside.update_view(focus_s)
	_director.update_view(focus_s)

	if bool(_args.get("standins", true)):
		_standins = Node3D.new()
		_standins.name = "StandIns"
		add_child(_standins)
		_build_standins(focus_s, view_m, t.road)

	_camera = Camera3D.new()
	_camera.fov = CAM_FOV_DEG
	_camera.near = CAM_NEAR_M
	_camera.far = view_m + t.quality.far_plane_margin_m
	add_child(_camera)
	_place_camera(String(_args.get("cam", "driver")), focus_s)
	_camera.make_current()
	if bool(_args.get("sky", true)):
		_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
		_sky.name = "Sky"
		_sky.view_distance_override_m = view_m
		_sky.sky_t = float(_args.get("sky_t", _sky.sky_t))
		add_child(_sky)
		_sky.setup(_ctx, _road, _origin)
		_sky.push_now()
	if String(_args.get("light", "")) == "review":
		_review_light()

	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	ui.add_child(_label)
	_label.text = "%s  s=%.0f  cam=%s  tier=%s (%.0f m)" % [_args.get("fixture", "arc_right"), focus_s,
		_args.get("cam", "driver"), tier, view_m]
	_frame = 0


func _process(_delta: float) -> void:
	if _frame < 0:
		return
	_frame += 1
	if _frame != STATS_FRAME:
		return
	var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var objs := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var line := "frame: %d draw calls, %d primitives, %d objects | roadside: %d MultiMeshes, %d instances, %d tris" % [
		dc, prims, objs, _roadside.draw_calls(), _roadside.instance_count(), _roadside.triangles()]
	line += " | ahead (m): billboards %s, gantries %s" % [_ahead(&"billboard"), _ahead(&"sign_gantry")]
	_label.text += "\n" + line
	# snap.sh echoes lines starting with "snap: " to stderr.
	print("snap: roadside_preview %s %s" % [_label.text.get_slice("\n", 0), line])


## Distances ahead of the camera of a layer's instances (to aim --s at them).
func _ahead(layer_id: StringName) -> String:
	var layer := _roadside.find_layer(layer_id)
	var fwd := -_camera.global_transform.basis.z
	var out := PackedStringArray()
	for pool in layer.pools:
		for i in pool.count:
			var p := pool.mmi.position + pool.get_transform(i).origin - _camera.position
			var along := p.dot(fwd)
			if along > 0.0:
				out.append("%.0f" % along)
	return "[%s]" % ", ".join(out)


func _make_road(fixture: String, t: Tuning) -> RoadPath:
	match fixture:
		"straight":
			return StraightRoadPath.new(t.road.lanes_default, t.road)
		"arc_left":
			return ArcRoadPath.new(t.road.min_curve_radius_m, -1, t.road.lanes_default, t.road)
		"procedural":
			return ProceduralRoadPath.new(_ctx)
	return ArcRoadPath.new(t.road.min_curve_radius_m, 1, t.road.lanes_default, t.road)


func _place_camera(cam: String, focus_s: float) -> void:
	var p: Array = CAMS.get(cam, CAMS["driver"])
	var lane: int = p[0]
	var d := _road.lane_center_d(maxi(lane, 0), focus_s) if lane >= 0 else SIDE_CAM_D_M
	var back: float = p[2]
	var eye_s := focus_s - back
	var look_s := focus_s + float(p[3])
	var eye := _road.sample(eye_s)
	var look := _road.sample(look_s)
	var eye_d := d
	var look_d := _road.lane_center_d(1, look_s) if cam != "side" else 0.0
	_camera.position = eye.local_point(eye_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
		+ Vector3(0.0, float(p[1]), 0.0)
	var target := look.local_point(look_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
		+ Vector3(0.0, float(p[4]), 0.0)
	_camera.look_at(target, Vector3.UP)


## --light=review: a high afternoon sun behind the camera and a brighter ambient,
## to judge shapes and composition (the color script, WP1.3, owns real values).
## Pushed after the SkyRig's own push; the rig only re-pushes values that change, so
## these hold while sky_t stays put.
func _review_light() -> void:
	RenderingServer.global_shader_parameter_set(&"wb_sun_dir", REVIEW_SUN_DIR.normalized())
	RenderingServer.global_shader_parameter_set(&"wb_ambient", REVIEW_AMBIENT.srgb_to_linear())
	RenderingServer.global_shader_parameter_set(&"wb_fog_start", REVIEW_FOG_START_M)


# ---------------------------------------------------------------- Stand-ins (preview only)

func _build_standins(focus_s: float, view_m: float, rt: RoadTuning) -> void:
	var biome := _director.current()
	var s0 := maxf(0.0, focus_s - STANDIN_BEHIND_M)
	var s1 := focus_s + view_m + STANDIN_STEP_M
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grail := _road.guardrail_d(focus_s)
	var asphalt := Color(0.26, 0.26, 0.28)
	var line := Color(0.92, 0.9, 0.84)
	var concrete := Color(0.66, 0.64, 0.6)
	var steel := Color(0.6, 0.63, 0.66)
	for side: float in [1.0, -1.0]:
		var lanes := _road.lane_count(focus_s)
		_strip(st, s0, s1, side, 0.0, grail + rt.prop_clearance_m, 0.0, biome.verge_color, 0.01)
		_strip(st, s0, s1, side, grail + rt.prop_clearance_m, GROUND_HALF_WIDTH_M, 0.0, biome.ground_color, 0.0)
		_strip(st, s0, s1, side, _road.median_barrier_d(focus_s), _road.shoulder_outer_d(focus_s), 0.0, asphalt, 0.05)
		_strip(st, s0, s1, side, _road.lanes_left_edge_d(focus_s) - 0.15, _road.lanes_left_edge_d(focus_s), 0.0,
			line, 0.07)
		_strip(st, s0, s1, side, _road.lanes_right_edge_d(focus_s), _road.lanes_right_edge_d(focus_s) + 0.15, 0.0,
			line, 0.07)
		for k in range(1, lanes):
			var dl := _road.lanes_left_edge_d(focus_s) + float(k) * _road.lane_width(focus_s)
			_dashes(st, s0, s1, side * dl, line)
		# Guardrail rail (vertical face) and the median barrier's side.
		_wall(st, s0, s1, side * grail, 0.5, 0.8, steel)
		_wall(st, s0, s1, side * _road.median_barrier_d(focus_s), 0.0, 0.85, concrete)
	_strip(st, s0, s1, 1.0, -_road.median_barrier_d(focus_s), _road.median_barrier_d(focus_s), 0.85, concrete, 0.0)
	st.generate_normals()
	var road_mi := MeshInstance3D.new()
	road_mi.name = "RoadStandIn"
	road_mi.mesh = st.commit()
	road_mi.material_override = load(WORLD_MATERIAL)
	_standins.add_child(road_mi)


## A flat strip from |d0| to |d1| on one side, at height h (+ lift against z-fighting).
func _strip(st: SurfaceTool, s0: float, s1: float, side: float, d0: float, d1: float, h: float, col: Color,
		lift: float) -> void:
	var s := s0
	while s < s1:
		var a := _road.sample(s)
		var b := _road.sample(s + STANDIN_STEP_M)
		var up := Vector3(0.0, h + lift, 0.0)
		var p00 := _local(a, side * d0) + up
		var p01 := _local(a, side * d1) + up
		var p10 := _local(b, side * d0) + up
		var p11 := _local(b, side * d1) + up
		_quad(st, p00, p01, p11, p10, col, Vector3.UP)
		s += STANDIN_STEP_M


func _dashes(st: SurfaceTool, s0: float, s1: float, d: float, col: Color) -> void:
	var dash := 3.0
	var gap := 9.0
	var s := floorf(s0 / (dash + gap)) * (dash + gap)
	while s < s1:
		var a := _road.sample(s)
		var b := _road.sample(s + dash)
		var up := Vector3(0.0, 0.07, 0.0)
		_quad(st, _local(a, d - 0.075) + up, _local(a, d + 0.075) + up, _local(b, d + 0.075) + up,
			_local(b, d - 0.075) + up, col, Vector3.UP)
		s += dash + gap


func _wall(st: SurfaceTool, s0: float, s1: float, d: float, h0: float, h1: float, col: Color) -> void:
	var s := s0
	var toward_road := Vector3.ZERO
	while s < s1:
		var a := _road.sample(s)
		var b := _road.sample(s + STANDIN_STEP_M)
		toward_road = -a.right * signf(d)
		var pa := _local(a, d)
		var pb := _local(b, d)
		_quad(st, pa + Vector3(0, h0, 0), pb + Vector3(0, h0, 0), pb + Vector3(0, h1, 0), pa + Vector3(0, h1, 0),
			col, toward_road)
		s += STANDIN_STEP_M


func _local(smp: RoadSample, d: float) -> Vector3:
	return smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z)


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, outward: Vector3) -> void:
	var n := (c - a).cross(b - a)
	var pts := [a, b, c, a, c, d] if n.dot(outward) >= 0.0 else [a, c, b, a, d, c]
	for p: Vector3 in pts:
		st.set_color(col)
		st.set_uv2(Vector2.ZERO)
		st.add_vertex(p)
