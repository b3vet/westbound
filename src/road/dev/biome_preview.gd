extends Node3D
## Look review of one biome (WP6.4b, biomes 4-6; works for any BiomeDef). Spec: World →
## Biomes (coastal highway, city at night, valley fog; "every biome must look good
## across the whole color script"), Sky (horizon sets), Performance budget.
## The real world stack for a chosen biome: ProceduralRoadPath, FloatingOrigin,
## BiomeDirector (the biome everywhere), RoadBuilder, Roadside, the WP6.4b features
## (WaterRibbon, ElevatedSections, FogCards), SkyRig with the biome's horizon set,
## tint offset and traffic palette, plus a few parked traffic models for readability.
##
##   tools/snap.sh src/road/dev/biome_preview.tscn --biome=coast --renderer=both \
##       --sweep=sky_t:0,0.38,0.5,0.58,0.66
##   tools/drawcalls.sh src/road/dev/biome_preview.tscn --biome=city --cam=chase
##
## snap_setup args: --biome=coast|city|valley_fog|farmland (data/biomes/<id>.tres),
## --seed=N, --s=<focus s> (default: an elevated stretch in the city, else 2600),
## --cam=chase|far|driver|high|side|sea|back (chase and far as data/tuning/camera.tres), --sky_t=<0..1>, --tier=low|medium|high,
## --traffic=false, --time=<wave clock s>, --features=false (no WP6.4b features),
## --night_lights=<player fake-light gain, default 1>, --label=false (no text),
## --horizon=false (keep the sky's default horizon instead of the biome's set),
## --lanes=<n> (default: the biome's lane_count, scheduled from s = 100),
## --ground_drop=false (keep the ground ribbon at road level: no RoadBuilder
## set_ground_drop hook; elevated stretches and sea cliffs need it).
## The road generator keeps the sun on an ocean's side (WP6.4c), so any seed shows the
## sun over the sea at the coast.
## Prints one "snap: biome_preview ..." line with the frame's draw calls/primitives
## and each part's share.

const SKY_SCENE := "res://src/sun/sky.tscn"
const BIOME_DIR := "res://data/biomes/"
const TRAFFIC_MATERIAL := "res://assets/shaders/materials/traffic.tres"
const TRAFFIC_MODELS: Array[String] = [
	"res://assets/traffic/sedan_a.res", "res://assets/traffic/suv_a.res", "res://assets/traffic/hatchback_a.res",
	"res://assets/traffic/semi_box.res", "res://assets/traffic/van_a.res", "res://assets/traffic/coupe_a.res",
]
## Parked traffic: (model, lane, s ahead of the focus, carriageway +1/-1).
const TRAFFIC_LAYOUT: Array[Vector4] = [
	Vector4(0, 1, 22.0, 1), Vector4(1, 0, 48.0, 1), Vector4(3, 2, 70.0, 1), Vector4(2, 1, 105.0, 1),
	Vector4(4, 0, 150.0, 1), Vector4(5, 2, 210.0, 1), Vector4(0, 0, 60.0, -1), Vector4(3, 1, 120.0, -1),
	Vector4(2, 0, 190.0, -1),
]
const STATS_FRAME := 4
const CAM_FOV_DEG := 62.0
const CAM_NEAR_M := 0.1
## Camera presets: [lane (-1 = side offset), height, behind, look ahead, look height].
const CAMS := {
	"chase": [1, 3.6, 7.0, 12.0, 0.0],
	"far": [1, 5.5, 11.0, 14.0, 0.0],
	"driver": [1, 1.2, 0.0, 120.0, 1.0],
	"high": [1, 45.0, 80.0, 260.0, 0.0],
	"side": [-1, 14.0, -40.0, 60.0, 0.0],
	"back": [1, 3.0, -40.0, -140.0, 1.0],
}
## The "sea" camera looks out over the water side at the sun.
const SEA_CAM := [1, 3.2, 6.0, 90.0, 6.0]
const SIDE_CAM_D_M := 80.0
const SEA_LOOK_D_M := 220.0
const DEFAULT_S_M := 2600.0

var _args: Dictionary = {}
var _built: bool = false
var _frame: int = -1

var _tuning: Tuning
var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _water: WaterRibbon
var _elevated: ElevatedSections
var _fog: FogCards
var _sky: SkyRig
var _camera: Camera3D
var _label: Label
var _traffic: Node3D
var _biome: BiomeDef
var _focus_s: float = 0.0


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
		c.free()
	_tuning = Tuning.load_default()
	var biome_id := String(_args.get("biome", "coast"))
	_biome = load(BIOME_DIR + biome_id + ".tres") as BiomeDef
	var seed_value := int(_args.get("seed", 20260928))
	_ctx = RunContext.new(seed_value, RunContext.MODE_JOURNEY, _tuning)
	_road = ProceduralRoadPath.new(_ctx)
	var lanes := int(_args.get("lanes", _biome.lane_count))
	if lanes != _tuning.road.lanes_default:
		_road.schedule_lane_count(100.0, lanes)
	var tier := String(_args.get("tier", "medium"))
	var ti := maxi(_tuning.quality.tier_names.find(tier), 0)
	var view_m: float = _tuning.quality.view_distance_m[ti]

	_director = BiomeDirector.new()
	_director.default_biome = _biome
	_director.journey = false
	add_child(_director)
	_director.setup(_ctx, _road, null)

	var features := bool(_args.get("features", true))
	if features:
		_make_features()
	_focus_s = float(_args.get("s", _default_s()))
	_road.ensure_generated_to(_focus_s + view_m + _tuning.road.chunk_length_m * 3.0)

	_origin = FloatingOrigin.new()
	_origin.setup(_tuning.road.floating_origin_shift_km)
	add_child(_origin)
	var smp := _road.sample(_focus_s)
	_origin.origin_x = smp.pos_x
	_origin.origin_y = smp.pos_y
	_origin.origin_z = smp.pos_z
	# Features first: the elevated plan lowers the road builder's ground.
	if _elevated != null:
		var clearance := LandmarkClearance.new()
		clearance.setup(_road, LandmarkTuning.load_default(), _director)
		_elevated.clearance = clearance
	for f: BiomeFeature in [_water, _elevated, _fog]:
		if f != null:
			f.view_distance_override_m = view_m
			add_child(f)
			f.setup(_ctx, _road, _origin)

	_builder = RoadBuilder.new()
	_builder.name = "RoadBuilder"
	_builder.biome_director = _director
	_builder.view_distance_override_m = view_m
	add_child(_builder)
	if bool(_args.get("ground_drop", true)):
		# The run's hook (BiomeFeatures.bind does the same).
		_builder.set_ground_drop(_elevated.ground_drop_at if _elevated != null else Callable(),
			_water.ground_drop_at if _water != null else Callable())
	_builder.setup(_ctx, _road, _origin)
	_builder.build_all_now(_focus_s)

	_roadside = Roadside.new()
	_roadside.name = "Roadside"
	_roadside.biome_director = _director
	_roadside.view_distance_override_m = view_m
	add_child(_roadside)
	_roadside.setup(_ctx, _road, _origin)
	_roadside.update_view(_focus_s)

	_camera = Camera3D.new()
	_camera.fov = CAM_FOV_DEG
	_camera.near = CAM_NEAR_M
	_camera.far = view_m + _tuning.quality.far_plane_margin_m
	add_child(_camera)
	_camera.make_current()

	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.name = "Sky"
	_sky.view_distance_override_m = view_m
	_sky.sky_t = float(_args.get("sky_t", _sky.sky_t))
	add_child(_sky)
	_sky.setup(_ctx, _road, _origin)
	# The director pushes the biome's look (tints, horizon set and its extensions) to
	# the sky, as in the run.
	_director.sky = _sky
	_director.update_view(_focus_s)
	var horizon_mat := _sky.horizon_material()
	if not bool(_args.get("horizon", true)):
		_sky.set_horizon_blend(Vector4(1, 2, 3, 3), _sky.horizon_layer_height_m, Vector4(1, 2, 3, 3),
			_sky.horizon_layer_height_m, 0.0)
		HorizonSetDef.apply_blend(horizon_mat, null, null, 0.0)
	if _water != null:
		_water.horizon_material = horizon_mat
		_water.set_time(float(_args.get("time", 0.0)))
	for f: BiomeFeature in [_water, _elevated, _fog]:
		if f != null:
			f.update_view(_focus_s)
	_sky.push_now()

	if bool(_args.get("traffic", true)):
		_make_traffic()
	_place_camera(String(_args.get("cam", "chase")))
	_sky.set_player_light(_camera.global_position - Vector3.UP, -_camera.global_transform.basis.z,
		float(_args.get("night_lights", 1.0)))
	_sky.push_now()

	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	ui.add_child(_label)
	_label.text = "%s  s=%.0f  cam=%s  sky_t=%.2f  tier=%s" % [biome_id, _focus_s, _args.get("cam", "chase"),
		_sky.sky_t, tier]
	_label.visible = bool(_args.get("label", true))
	_frame = 0


func _make_features() -> void:
	if _biome.water != null:
		_water = WaterRibbon.new()
		_water.name = "Water"
		_water.biome_director = _director
	if _biome.elevated != null:
		_elevated = ElevatedSections.new()
		_elevated.name = "Elevated"
		_elevated.biome_director = _director
	if _biome.fog_cards != null:
		_fog = FogCards.new()
		_fog.name = "FogCards"
		_fog.biome_director = _director


## The first elevated stretch's middle in the city, else DEFAULT_S_M.
func _default_s() -> float:
	if _biome.elevated == null:
		return DEFAULT_S_M
	var plan := ElevatedPlan.new(_ctx.rng_props.derive(&"elevated").get_seed(), _director.biome_at)
	var s := DEFAULT_S_M * 0.5
	while s < DEFAULT_S_M * 8.0:
		if plan.drop_at(s) >= _biome.elevated.height_m:
			return s + _biome.elevated.ramp_m
		s += _biome.elevated.row_step_m
	return DEFAULT_S_M


func _process(_delta: float) -> void:
	if _frame < 0:
		return
	_frame += 1
	if _frame != STATS_FRAME:
		return
	var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var feat := 0
	var feat_tris := 0
	for f: BiomeFeature in [_water, _elevated, _fog]:
		if f != null:
			feat += f.draw_calls()
			feat_tris += f.triangles()
	var line := "frame: %d draw calls, %d primitives | road chunks %d | roadside %d MultiMeshes, %d tris | features %d, %d tris" % [
		dc, prims, _builder.draw_call_count(), _roadside.draw_calls(), _roadside.triangles(), feat, feat_tris]
	_label.text += "\n" + line
	print("snap: biome_preview %s %s" % [_label.text.get_slice("\n", 0), line])


# ---------------------------------------------------------------- Camera

func _place_camera(cam: String) -> void:
	var p: Array = SEA_CAM if cam == "sea" else CAMS.get(cam, CAMS["chase"])
	var lane: int = p[0]
	var d := _road.lane_center_d(maxi(lane, 0), _focus_s) if lane >= 0 else SIDE_CAM_D_M
	var eye_s := _focus_s - float(p[2])
	var look_s := _focus_s + float(p[3])
	var look_d := _road.lane_center_d(1, look_s)
	if cam == "side":
		look_d = 0.0
	elif cam == "sea":
		var side := float(_biome.water.side) if _biome.water != null else -1.0
		look_d = side * SEA_LOOK_D_M
	var eye := _road.sample(eye_s)
	var look := _road.sample(look_s)
	_camera.position = eye.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
		+ Vector3(0.0, float(p[1]), 0.0)
	var target := look.local_point(look_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
		+ Vector3(0.0, float(p[4]), 0.0)
	_camera.look_at(target, Vector3.UP)


# ---------------------------------------------------------------- Parked traffic

func _make_traffic() -> void:
	_traffic = Node3D.new()
	_traffic.name = "Traffic"
	add_child(_traffic)
	var mat := (load(TRAFFIC_MATERIAL) as ShaderMaterial).duplicate() as ShaderMaterial
	var pal := PackedColorArray()
	pal.resize(TrafficLights.PALETTE_SLOTS)
	for i in pal.size():
		pal[i] = _biome.traffic_palette[i % _biome.traffic_palette.size()] if not _biome.traffic_palette.is_empty() \
			else Color.GRAY
	mat.set_shader_parameter(&"palette", TrafficView.palette_vectors(pal))
	var head := _sky.current().emissive_headlight > 0.0
	var smp := RoadSample.new()
	for m in TRAFFIC_MODELS.size():
		var xforms: Array[Transform3D] = []
		var customs: Array[Color] = []
		for k in TRAFFIC_LAYOUT.size():
			var e := TRAFFIC_LAYOUT[k]
			if int(e.x) != m:
				continue
			var dir := e.w
			var s := _focus_s + e.z
			var lane := mini(int(e.y), _road.lane_count(s) - 1)
			var d := _road.lane_center_d(lane, s) if dir > 0.0 else _road.opposite_lane_center_d(lane, s)
			_road.sample_into(s, smp)
			var yaw := 0.0 if dir > 0.0 else PI
			var up := smp.up
			var b := Basis(smp.right.rotated(up, -yaw), up, (-smp.tangent).rotated(up, -yaw))
			xforms.append(Transform3D(b, smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z)))
			var bits := TrafficLights.BIT_HEAD if head else 0
			customs.append(Color(0.0, 0.0, 0.0, TrafficLights.pack(bits, k)))
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = load(TRAFFIC_MODELS[m]) as Mesh
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
			mm.set_instance_color(i, Color.WHITE)
			mm.set_instance_custom_data(i, customs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_traffic.add_child(mmi)
