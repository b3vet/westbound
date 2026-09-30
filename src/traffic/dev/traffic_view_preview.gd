extends Node3D
# lint: not-sim dev scene (Node): drives a TrafficView for visual review
## Traffic view review scene (WP3.1). Spec: Traffic → Visuals (lights, motion,
## rendering), Cameras → Glare rule, World → Night lighting, Performance budget (draw
## calls, triangles). The real world stack (procedural road, roadside, farmland
## biome, sky) with a TrafficView over:
##   static   scripted traffic around a virtual player in lane 1: a car mid lane change
##            with its blinker, a braking car, a strong-braking car, hazards, a semi, a
##            coach, motorbikes, plus opposite traffic (the default)
##   drive    the real TrafficSim + TrafficDirector (and its opposite carriageway)
##            around a constant-speed virtual player; --seconds lets traffic develop
##   lineup   every model side by side across the road, for model review
##   full     the budget case: both carriageways at capacity (60 + 30), every model,
##            spread from just behind the player to 700 m ahead
##
##   tools/snap.sh src/traffic/dev/traffic_view_preview.tscn --renderer=both \
##       --sweep=sky_t:0.2,0.38,0.66 --cam=chase
##   tools/snap.sh src/traffic/dev/traffic_view_preview.tscn --scenario=drive --seconds=20
##   tools/snap.sh src/traffic/dev/traffic_view_preview.tscn --scenario=lineup --cam=quarter
##
## snap_setup options: --scenario=static|drive|lineup, --sky_t=<0..1>,
## --cam=chase|far|high|front|side|quarter|rear, --s=<player s, m>, --seed=<road seed>,
## --speed_kmh=<drive speed>, --animate=true (let static blinkers flash), --traffic=false
## (hide the traffic view: the world-only baseline for parity), --pick=<model
## index> (lineup: only that model, for close-ups with --cam=side|quarter|fquarter|front|rear).
## Each capture prints the frame's draw calls and primitives and the view's share.

const SCENARIOS := ["static", "drive", "lineup", "full"]
const CAMS := ["chase", "far", "high", "front", "side", "quarter", "fquarter", "rear"]
const PLAYER_LANE := 1
const PLAYER_MODEL := "res://assets/traffic/coupe_a.tscn"
## The stand-in player car's paint (sRGB; the style palette's brand_orange).
const PLAYER_PAINT := Color(0.96, 0.46, 0.13)
## Camera rigs relative to the player: (back, height, look ahead, look height), meters.
const CAM_CHASE := Vector4(7.5, 2.7, 22.0, 1.0)
const CAM_FAR := Vector4(13.0, 5.0, 30.0, 1.0)
const CAM_HIGH := Vector4(22.0, 26.0, 45.0, 0.0)
const CAM_FRONT := Vector4(-45.0, 3.0, -10.0, 1.0)
const CAM_REAR := Vector4(-9.0, 1.6, 30.0, 1.2)
## Close-ups around one vehicle: (side distance, quarter offset, eye height, look height).
const CLOSE_UP := Vector4(9.0, 6.0, 2.2, 0.9)
## Close-ups scale with the vehicle length (relative to a sedan), within these bounds.
const CLOSE_UP_REF_LENGTH_M := 4.8
const CLOSE_UP_MIN_SCALE := 0.55
const CLOSE_UP_MAX_SCALE := 3.0
const LINEUP_SPACING_M := 3.4
const LINEUP_AHEAD_M := 14.0
## The full scenario spreads vehicles over [player - behind, player + ahead] and keeps
## this gap around the player in its lane.
const FULL_AHEAD_M := 700.0
const FULL_BEHIND_M := 30.0
const FULL_GAP_M := 12.0
const STATS_FRAMES := 3
const FORGET_EVERY_M := 500.0

@export var run_seed: int = 20260928
@export var start_s_m: float = 2400.0
@export var drive_speed_kmh: float = 120.0

@onready var _sky: SkyRig = $Sky
@onready var _camera: Camera3D = $Camera3D
@onready var _label: Label = $UI/Label

var _tuning: Tuning
var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _view: TrafficView
var _registry: TrafficRegistry
var _state: TrafficState
var _opposite: TrafficState
var _sim: TrafficSim
var _traffic: TrafficDirector
var _events: ScoreEventBuffer
var _player := VehicleState.new()
var _player_prev_s: float = 0.0
var _player_car: MeshInstance3D
var _smp := RoadSample.new()
var _scenario: String = "static"
var _cam: String = "chase"
var _animate: bool = true
var _night: bool = false
var _next_forget_s: float = 0.0
var _pick: int = -1
var _focus_s: float = 0.0
var _focus_d: float = 0.0


func _ready() -> void:
	_tuning = Tuning.load_default()
	_configure({})


func snap_setup(args: Dictionary) -> void:
	args = args.duplicate()
	if not args.has("animate"):
		args["animate"] = false
	_configure(args)
	for i in STATS_FRAMES:
		await get_tree().process_frame
	var line := "snap: traffic_view_preview %s sky_t=%.2f cam=%s draw calls %d, primitives %d; traffic view: %d vehicles, %d draw calls, %d tris, %d glows" % [
		_scenario, _sky.sky_t, _cam,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		_view.visible_count(), _view.draw_calls(), _view.triangles(), _view.glow_count()]
	print(line)


func _configure(args: Dictionary) -> void:
	_scenario = str(args.get("scenario", "static"))
	if not SCENARIOS.has(_scenario):
		push_warning("traffic_view_preview: unknown scenario %s (%s)" % [_scenario, ", ".join(SCENARIOS)])
		_scenario = "static"
	_cam = str(args.get("cam", "quarter" if _scenario == "lineup" else "chase"))
	if not CAMS.has(_cam):
		push_warning("traffic_view_preview: unknown cam %s (%s)" % [_cam, ", ".join(CAMS)])
		_cam = "chase"
	_animate = bool(args.get("animate", true))
	_pick = int(args.get("pick", -1))
	_sky.sky_t = float(args.get("sky_t", _sky.sky_t))
	_night = _sky.sky_t >= _tuning.sun.sky_t_sunset
	var start_s := float(args.get("s", start_s_m))
	_build_world(int(args.get("seed", run_seed)), start_s)
	_player.reset()
	_player.s = start_s
	_player.d = _road.lane_center_d(PLAYER_LANE, start_s)
	_player.v = Units.kmh_to_mps(float(args.get("speed_kmh", drive_speed_kmh)))
	_player_prev_s = _player.s
	_registry = TrafficRegistry.load_default(_tuning.traffic)
	_sim = null
	_traffic = null
	match _scenario:
		"drive":
			_setup_drive()
		"lineup":
			_setup_lineup()
		"full":
			_setup_full()
		_:
			_setup_static()
	if _view != null:
		_view.free()
	_view = TrafficView.new()
	_view.name = "TrafficView"
	add_child(_view)
	_view.setup(_ctx, _road, _origin, _registry, _state, _opposite)
	_view.set_palette((load("res://data/biomes/farmland.tres") as BiomeDef).traffic_palette)
	_view.capture_tick()
	_view.capture_tick()
	_view.visible = bool(args.get("traffic", true))
	_place_player()
	_place_camera()
	_view.render(1.0)


# ---------------------------------------------------------------- World

func _build_world(seed_value: int, s: float) -> void:
	for n: Node in [_origin, _director, _builder, _roadside]:
		if n != null:
			n.free()
	_ctx = RunContext.new(seed_value)
	_road = ProceduralRoadPath.new(_ctx)
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
	_road.ensure_generated_to(_view_ahead(s))
	_road.sample_into(s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_director.setup(_ctx, _road, _origin)
	_builder.setup(_ctx, _road, _origin)
	_roadside.setup(_ctx, _road, _origin)
	_sky.setup(_ctx, _road, _origin)
	_builder.build_all_now(s)
	_roadside.update_view(s)
	_next_forget_s = s + FORGET_EVERY_M
	_camera.far = _builder.view_distance_m() + _tuning.quality.far_plane_margin_m


func _view_ahead(s: float) -> float:
	return s + _builder.view_distance_m() + _tuning.road.chunk_length_m * 2.0


# ---------------------------------------------------------------- Scenarios

## Scripted snapshot around the player. Offsets are meters ahead of the player.
func _setup_static() -> void:
	_state = TrafficState.new(_tuning.traffic.max_active_vehicles)
	_opposite = TrafficState.new(_tuning.traffic.opposite_max_vehicles)
	var s := _player.s
	var kmh := 110.0
	var head := TrafficState.FLAG_HEADLIGHTS if _night else 0
	# A braking sedan straight ahead in the player's lane.
	_put(_state, &"sedan", 0, 1, s + 13.0, kmh, TrafficState.FLAG_BRAKE | head, 3, -2.5)
	# A hatchback mid lane change from lane 0 into lane 1, blinker right, nose right.
	var d0 := _road.lane_center_d(0, s)
	var d1 := _road.lane_center_d(1, s)
	var i := _put(_state, &"hatchback", 0, 0, s + 26.0, kmh, TrafficState.FLAG_BLINKER_RIGHT | head, 5)
	_state.d[i] = lerpf(d0, d1, 0.45)
	_state.v_lat[i] = 1.8
	_state.lc_state[i] = TrafficState.LaneChange.MOVING
	_state.target_lane[i] = 1
	# A semi in the slow lane; an SUV with hazards; motorbikes; a coach; a strong braker.
	_put(_state, &"semi", 0, 2, s + 22.0, 90.0, head, 1)
	_put(_state, &"suv", 1, 0, s + 10.0, 95.0, TrafficState.FLAG_HAZARD | head, 7)
	_put(_state, &"motorbike", 0, 0, s + 42.0, 130.0, head, 1)
	_put(_state, &"sports", 1, 1, s + 40.0, 150.0, TrafficState.FLAG_BRAKE | TrafficState.FLAG_BRAKE_STRONG | head, 3,
		-5.0)
	_put(_state, &"coach", 0, 2, s + 52.0, 95.0, head, 2)
	_put(_state, &"pickup", 0, 1, s + 62.0, 105.0, TrafficState.FLAG_BLINKER_LEFT | head, 6)
	_put(_state, &"van", 0, 0, s + 75.0, 100.0, head, 0)
	_put(_state, &"coupe", 0, 1, s + 95.0, 115.0, head, 4)
	_put(_state, &"sedan", 1, 0, s + 120.0, 125.0, head, 1)
	_put(_state, &"motorbike", 1, 1, s + 140.0, 120.0, TrafficState.FLAG_BLINKER_RIGHT | head, 2)
	_put(_state, &"semi", 1, 2, s + 160.0, 88.0, head, 5)
	_put(_state, &"hatchback", 1, 0, s + 190.0, 130.0, head, 7)
	_put(_state, &"suv", 0, 1, s + 230.0, 112.0, head, 2)
	_put(_state, &"sedan", 2, 2, s + 270.0, 100.0, head, 6)
	_put(_state, &"sports", 0, 0, s + 320.0, 140.0, head, 0)
	_put(_state, &"sedan", 0, 1, s - 18.0, 115.0, head, 4)
	# Opposite carriageway (d < 0, toward -s).
	var op_types: Array[StringName] = [&"sedan", &"semi", &"suv", &"hatchback", &"van", &"coach", &"sedan",
		&"pickup", &"motorbike", &"coupe"]
	for k in op_types.size():
		var lane := k % 3
		var j := _put(_opposite, op_types[k], k % 2, lane, s + 20.0 + 38.0 * float(k), 110.0, head, k)
		_opposite.d[j] = _road.opposite_lane_center_d(lane, _opposite.s[j])


func _put(st: TrafficState, type_id: StringName, variant: int, lane: int, s: float, kmh: float, flags: int,
		color: int, accel: float = 0.0) -> int:
	var i := st.allocate()
	var t := _registry.type_index(type_id)
	st.s[i] = s
	st.d[i] = _road.lane_center_d(lane, s)
	st.v[i] = Units.kmh_to_mps(kmh)
	st.v0[i] = st.v[i]
	st.accel[i] = accel
	st.length[i] = _registry.length[t]
	st.width[i] = _registry.width[t]
	st.lane[i] = lane
	st.target_lane[i] = lane
	st.type_id[i] = t
	st.model_variant[i] = variant
	st.color_index[i] = color
	st.flags[i] = flags
	return i


func _setup_drive() -> void:
	_events = ScoreEventBuffer.new(_tuning.scoring.event_buffer_capacity)
	_sim = TrafficSim.new(_ctx, _road, _registry)
	_sim.set_player_body(_tuning.traffic.player_length_m, _tuning.traffic.player_width_m)
	_traffic = TrafficDirector.new(_ctx, _road, _sim, _registry.profiles, _registry.types,
		_tuning.traffic.player_length_m, _tuning.traffic.player_width_m)
	_traffic.set_biome(load("res://data/biomes/farmland.tres") as BiomeDef)
	_traffic.set_leg(3, _player.s)
	_traffic.set_night(_night)
	_sim.set_headlights(_night)
	_road.ensure_generated_to(_view_ahead(_player.s) + _traffic.ahead_distance())
	_traffic.reset(_player)
	_state = _sim.state
	_opposite = _traffic.opposite.state


## Both carriageways filled to capacity with every model, lanes and flags cycling.
func _setup_full() -> void:
	_state = TrafficState.new(_tuning.traffic.max_active_vehicles)
	_opposite = TrafficState.new(_tuning.traffic.opposite_max_vehicles)
	var head := TrafficState.FLAG_HEADLIGHTS if _night else 0
	var spread := FULL_AHEAD_M + FULL_BEHIND_M
	var k := 0
	while not _state.is_full():
		for t in _registry.types.size():
			for v in _registry.types[t].model_scene_paths.size():
				if _state.is_full():
					break
				var s := _player.s - FULL_BEHIND_M + spread * float(k) / float(_state.capacity)
				var lane := k % 3
				if lane == PLAYER_LANE and absf(s - _player.s) < FULL_GAP_M:
					lane = (lane + 1) % 3
				var flags := head | (TrafficState.FLAG_BRAKE if k % 5 == 0 else 0)
				_put(_state, _registry.types[t].id, v, lane, s, 100.0, flags, k)
				k += 1
	for j in _opposite.capacity:
		var t := j % _registry.types.size()
		var i := _put(_opposite, _registry.types[t].id, j, j % 3, _player.s + spread * float(j) / float(_opposite.capacity),
			110.0, head, j)
		_opposite.d[i] = _road.opposite_lane_center_d(j % 3, _opposite.s[i])


## Every model across the road, side by side, facing the travel direction (or only
## model `--pick` in lane 1).
func _setup_lineup() -> void:
	_state = TrafficState.new(_tuning.traffic.max_active_vehicles)
	_opposite = null
	var n := 0
	for t in _registry.types.size():
		n += _registry.types[t].model_scene_paths.size()
	var k := 0
	var head := TrafficState.FLAG_HEADLIGHTS if _night else 0
	_focus_s = _player.s + LINEUP_AHEAD_M
	_focus_d = _road.lane_center_d(PLAYER_LANE, _focus_s)
	for t in _registry.types.size():
		for v in _registry.types[t].model_scene_paths.size():
			if _pick < 0 or _pick == k:
				var i := _put(_state, _registry.types[t].id, v, 0, _focus_s, 0.0, head, k)
				_state.d[i] = _focus_d if _pick >= 0 else (float(k) - float(n - 1) * 0.5) * LINEUP_SPACING_M + _focus_d
			k += 1


# ---------------------------------------------------------------- Per frame

func _physics_process(delta: float) -> void:
	if _view == null:
		return
	if _scenario == "drive":
		_player_prev_s = _player.s
		_player.s += _player.v * delta
		_road.ensure_generated_to(_view_ahead(_player.s) + _traffic.ahead_distance())
		if _player.s >= _next_forget_s:
			_road.forget_before(_player.s - _roadside.reach_behind_m() - _tuning.road.chunk_length_m)
			_next_forget_s = _player.s + FORGET_EVERY_M
		_sim.step(delta, _player, null, _events)
		_traffic.step(delta, _player)
		_events.clear()
		_road.sample_into(_player.s, _smp)
		_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
		_view.capture_tick()
	elif _animate:
		_view.capture_tick()


func _process(_delta: float) -> void:
	if _view == null:
		return
	var s := _player_s()
	_director.update_view(s)
	_builder.update_view(s)
	_roadside.update_view(s)
	if _scenario != "lineup":
		_view.update_view(s)
	_place_player()
	_place_camera()
	_label.text = "%s  %d vehicles  view: %d draws, %d tris, %d glows  frame: %d draws" % [
		_scenario, _view.visible_count(), _view.draw_calls(), _view.triangles(), _view.glow_count(),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)]


func _player_s() -> float:
	if _scenario != "drive":
		return _player.s
	return lerpf(_player_prev_s, _player.s, Engine.get_physics_interpolation_fraction())


func _place_player() -> void:
	if _player_car == null:
		_player_car = MeshInstance3D.new()
		_player_car.name = "PlayerStandIn"
		_player_car.mesh = TrafficView.load_model_mesh(PLAYER_MODEL)
		var mat := (load("res://assets/shaders/materials/traffic.tres") as ShaderMaterial).duplicate() as ShaderMaterial
		var pal := PackedColorArray()
		pal.resize(TrafficLights.PALETTE_SLOTS)
		pal.fill(PLAYER_PAINT)
		mat.set_shader_parameter(&"palette", TrafficView.palette_vectors(pal))
		_player_car.material_override = mat
		_player_car.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(_player_car)
	_player_car.visible = _scenario != "lineup"
	var s := _player_s()
	_road.sample_into(s, _smp)
	var p := _smp.local_point(_player.d, _origin.origin_x, _origin.origin_y, _origin.origin_z)
	_player_car.global_transform = Transform3D(Basis(_smp.right, _smp.up, -_smp.tangent), p)
	if _night:
		_sky.set_player_light(p + _smp.up, _smp.tangent, 1.0)
	else:
		_sky.set_player_light(p, _smp.tangent, 0.0)


func _place_camera() -> void:
	var s := _player_s()
	var d := _player.d
	if _scenario == "lineup":
		s = _focus_s
		d = _focus_d
	var rig := CAM_CHASE
	match _cam:
		"far":
			rig = CAM_FAR
		"high":
			rig = CAM_HIGH
		"front":
			rig = CAM_FRONT
		"rear":
			rig = CAM_REAR
	var eye: Vector3
	var target: Vector3
	var cu := CLOSE_UP
	if _scenario == "lineup" and _pick >= 0:
		var k := clampf(_state.length[0] / CLOSE_UP_REF_LENGTH_M, CLOSE_UP_MIN_SCALE, CLOSE_UP_MAX_SCALE)
		cu = Vector4(CLOSE_UP.x * k, CLOSE_UP.y * k, CLOSE_UP.z * sqrt(k), CLOSE_UP.w * sqrt(k))
	match _cam:
		"side":
			eye = _pt(s, d - cu.x, cu.z)
			target = _pt(s, d, cu.w)
		"quarter":
			eye = _pt(s - cu.y, d - cu.y, cu.z)
			target = _pt(s, d, cu.w)
		"fquarter":
			eye = _pt(s + cu.y, d - cu.y, cu.z)
			target = _pt(s, d, cu.w)
		_:
			if _scenario == "lineup" and _pick >= 0:
				var dir := -1.0 if _cam == "front" else 1.0
				eye = _pt(s - dir * cu.x, d, cu.z)
				target = _pt(s, d, cu.w)
			else:
				eye = _pt(s - rig.x, d, rig.y)
				target = _pt(s + rig.z, d, rig.w)
	_camera.look_at_from_position(eye, target, Vector3.UP)


func _pt(s: float, d: float, h: float) -> Vector3:
	_road.sample_into(s, _smp)
	return _smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z) + _smp.up * h
