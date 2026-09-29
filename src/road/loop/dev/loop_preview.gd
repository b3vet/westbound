extends Node3D
## Look review of the multiplayer loop (N3.1 dev tool, not shipped): the real world stack
## on LoopRoadPath at a chosen point. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop
## map ("The existing road builder, props and color script are reused"), Time of day in
## multiplayer (the loop must look good at every time). docs/LOOP_MAP.md → Snaps.
##
## Stack: LoopRoadPath (data/maps/loop_v1.tres), FloatingOrigin, BiomeDirector with the
## loop's sections as its plan (LoopRoadPath.biome_plan), RoadBuilder, Roadside, Landmarks
## (the sector gantries), BiomeFeatures (sea, elevated city, fog), SkyRig. Streaming with
## wrap-around is N3.2's (the run's loop test mode); this builds one view with the same
## periodic plan and elevated zone.
##
##   tools/snap.sh src/road/loop/dev/loop_preview.tscn --at=bridge --cam=chase --sky_t=0.62
##   tools/snap.sh src/road/loop/dev/loop_preview.tscn --sweep=at:start,canyon,bridge,city,farmland
##
## snap_setup args: --at=start|desert|canyon|tunnel|crest|coast|bridge|city|ramp|farmland|seam
## (or --s=<m>), --lap=<n> (the same view n laps on: unwrapped s), --cam=chase|high|top|side|sea,
## --sky_t=<0..1>, --tier=low|medium|high, --label=false.

const SKY_SCENE := "res://src/sun/sky.tscn"
const CAM_FOV_DEG := 62.0
const CAM_NEAR_M := 0.1
## Camera presets: [lane (-1 = side offset), height, behind, look ahead, look height].
const CAMS := {
	"chase": [1, 3.6, 7.0, 12.0, 0.0],
	"high": [1, 60.0, 120.0, 320.0, 0.0],
	"top": [1, 700.0, 1.0, 2.0, 0.0],
	"side": [-1, 14.0, -40.0, 60.0, 0.0],
}
const SEA_CAM := [1, 3.2, 6.0, 90.0, 6.0]
const SIDE_CAM_D_M := 80.0
const SEA_LOOK_D_M := 220.0
## Metres ahead of the named feature the view is placed (the camera sits behind it).
const LEAD_M := 120.0
const STATS_FRAME := 4

var _args: Dictionary = {}
var _built: bool = false
var _frame: int = -1

var _tuning: Tuning
var _ctx: RunContext
var road: LoopRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _landmarks: Landmarks
var _features: BiomeFeatures
var _sky: SkyRig
var _camera: Camera3D
var _label: Label
var focus_s: float = 0.0


func _ready() -> void:
	_build.call_deferred()


func snap_setup(args: Dictionary) -> void:
	_args = args
	_built = false
	_build()
	await get_tree().process_frame


## The s of a named place on the loop (the snap's --at).
func place_s(at: String) -> float:
	var o := road.layout
	match at:
		"start":
			# Just before the start / finish line, at the end of lap 0 (the road builder
			# builds no chunk at s < 0).
			return road.length() + o.sector_s[0] - LEAD_M * 0.5
		"desert":
			return road.section_start(0) + o.section_length_m * 0.4
		"canyon":
			return road.section_start(1) + o.section_length_m * 0.25
		"tunnel":
			return o.tunnel_s0[0] - LEAD_M
		"crest":
			for f in o.features:
				if f.kind == RoadFeature.Kind.BLIND_CREST:
					return f.s_start - LEAD_M
		"coast":
			return road.section_start(2) + o.section_length_m * 0.15
		"bridge":
			return o.sector_s[road.def.bridge_sector] - LandmarkTuning.load_default().bridge_span_m * 0.5 - LEAD_M
		"city":
			return (o.elevated_s0[0] + o.elevated_s1[0]) * 0.5
		"ramp":
			return o.ramp_s[0] - LEAD_M
		"farmland":
			return road.section_start(4) + o.section_length_m * 0.35
		"seam":
			return road.length() - LEAD_M
	return float(at) if at.is_valid_float() else 0.0


func _build() -> void:
	if _built:
		return
	_built = true
	for c in get_children():
		c.free()
	_tuning = Tuning.load_default()
	road = LoopRoadPath.load_default(_tuning)
	_ctx = RunContext.new(road.def.map_seed, RunContext.MODE_JOURNEY, _tuning)
	var tier := String(_args.get("tier", "medium"))
	var ti := maxi(_tuning.quality.tier_names.find(tier), 0)
	var view_m: float = _tuning.quality.view_distance_m[ti]
	var at := String(_args.get("at", "start"))
	focus_s = float(_args["s"]) if _args.has("s") else place_s(at)
	var lap := int(_args.get("lap", 0))
	focus_s += float(lap) * road.length()

	_origin = FloatingOrigin.new()
	_origin.name = "FloatingOrigin"
	_origin.setup(_tuning.road.floating_origin_shift_km)
	add_child(_origin)
	var smp := road.sample(focus_s)
	_origin.origin_x = smp.pos_x
	_origin.origin_y = smp.pos_y
	_origin.origin_z = smp.pos_z

	_director = BiomeDirector.new()
	_director.name = "BiomeDirector"
	_director.plan = road.biome_plan(0)   # N3.2: periodic, any lap
	_director.apply_to_road = false
	add_child(_director)
	_builder = RoadBuilder.new()
	_builder.name = "RoadBuilder"
	_builder.biome_director = _director
	_builder.view_distance_override_m = view_m
	add_child(_builder)
	_roadside = Roadside.new()
	_roadside.name = "Roadside"
	_roadside.biome_director = _director
	_roadside.view_distance_override_m = view_m
	add_child(_roadside)
	_landmarks = Landmarks.new()
	_landmarks.name = "Landmarks"
	_landmarks.biome_director = _director
	_landmarks.view_distance_override_m = view_m
	add_child(_landmarks)
	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.name = "Sky"
	_sky.view_distance_override_m = view_m
	_sky.sky_t = float(_args.get("sky_t", _sky.sky_t))
	add_child(_sky)
	_features = BiomeFeatures.new()
	_features.name = "BiomeFeatures"
	_features.biome_director = _director
	add_child(_features)
	_features.bind(_builder, _sky)

	_director.setup(_ctx, road, _origin)
	_builder.setup(_ctx, road, _origin)
	_roadside.setup(_ctx, road, _origin)
	_landmarks.setup(_ctx, road, _origin)
	_features.setup(_ctx, road, _origin)
	# N3.2: the loop's elevated zone (as in the loop test mode), not the seeded cells.
	_features.elevated.plan.set_zones(road.layout.elevated_s0, road.layout.elevated_s1, road.length())
	_sky.setup(_ctx, road, _origin)
	_director.sky = _sky
	_builder.build_all_now(focus_s)
	_director.update_view(focus_s)
	_roadside.update_view(focus_s)
	_landmarks.update_view(focus_s)
	_features.update_view(focus_s)
	_sky.push_now()

	_camera = Camera3D.new()
	_camera.fov = CAM_FOV_DEG
	_camera.near = CAM_NEAR_M
	_camera.far = view_m + _tuning.quality.far_plane_margin_m
	add_child(_camera)
	_camera.make_current()
	_place_camera(String(_args.get("cam", "chase")))
	_sky.set_player_light(_camera.global_position - Vector3.UP, -_camera.global_transform.basis.z, 1.0)
	_sky.push_now()

	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	ui.add_child(_label)
	var sec := road.section_at(focus_s)
	_label.text = "loop_v1  %s  s=%.0f (lap %d)  %s  %d lanes  heading %.0f deg  cam=%s  sky_t=%.2f" % [
		at, road.wrap_s(focus_s), road.lap_of(focus_s), road.section_id(sec), road.lane_count(focus_s),
		rad_to_deg(wrapf(road.heading_at(focus_s), -PI, PI)), _args.get("cam", "chase"), _sky.sky_t]
	_label.visible = bool(_args.get("label", true))
	_frame = 0


func _process(_delta: float) -> void:
	if _frame < 0:
		return
	_frame += 1
	if _frame == STATS_FRAME:
		var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		print("snap: loop_preview %s | %d draw calls" % [_label.text, dc])


func _place_camera(cam: String) -> void:
	var p: Array = SEA_CAM if cam == "sea" else CAMS.get(cam, CAMS["chase"])
	var lane: int = p[0]
	var d := road.lane_center_d(maxi(lane, 0), focus_s) if lane >= 0 else SIDE_CAM_D_M
	var eye_s := focus_s - float(p[2])
	var look_s := focus_s + float(p[3])
	var look_d := road.lane_center_d(1, look_s)
	if cam == "side":
		look_d = 0.0
	elif cam == "sea":
		var b := _director.biome_at(focus_s)
		look_d = (float(b.water.side) if b != null and b.water != null else 1.0) * SEA_LOOK_D_M
	var eye := road.sample(eye_s)
	var look := road.sample(look_s)
	_camera.position = eye.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
		+ Vector3(0.0, float(p[1]), 0.0)
	var target := look.local_point(look_d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
		+ Vector3(0.0, float(p[4]), 0.0)
	if cam == "top":
		_camera.look_at(target, Vector3.FORWARD.rotated(Vector3.UP, -eye.heading))
	else:
		_camera.look_at(target, Vector3.UP)
