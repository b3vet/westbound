extends Node3D
## M2 integration scene: drive the real car (plan Phase 2, Gate M2; spec M2
## "the drag and gyro layouts both feel precise on device"). Dev-only, replaced
## by the real run loop in Phase 4.
##
## World stack as in the M1 drive scene (ProceduralRoadPath, FloatingOrigin,
## RoadBuilder, Roadside, BiomeDirector, SkyRig) plus the physics PlayerCar driven
## by PlayerInput through a PlayerController, the ControlsOverlay and the CameraRig.
## M3: traffic (TrafficSim + TrafficDirector + TrafficView, you as a participant) and
## hits with the lives rules (ghost, deflection; infinite lives until Phase 4). No
## scoring HUD yet. Leaving the carriageway resets the car.
##
## Dev buttons (DriveControls), top-right: CAM, HUD; STEER (drag/gyro),
## THROTTLE (auto/manual), MIRROR; CAR, RECAL (gyro neutral), RESET; top-left SANDBOX
## (the traffic sandbox; on web also `?scene=sandbox` in the URL, reload to come back).
## Keys: A/D steer, W gas (manual), S brake, Shift boost, C camera, backtick HUD.

const CAR_PATHS: Array[String] = [
	"res://data/cars/falcon_gt.tres",
	"res://data/cars/night_viper.tres",
	"res://data/cars/brute_v8.tres",
]
const START_LANE := 1
const START_SPEED_KMH := 120.0
const START_LEG := 3
const LEG_COUNT := 8
## Headlights on when the color script's headlight ramp passes this (dev scene value).
const HEADLIGHTS_ON := 0.3
## Dev scene sizes (canvas px).
const LAYOUT_BUTTON := Vector2(150.0, 48.0)
const CAM_BUTTON := Vector2(190.0, 48.0)
const FORGET_EVERY_M := 500.0
const SANDBOX_SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"

@export var run_seed: int = 20260928

var _tuning: Tuning
var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _sky: SkyRig
var _hub: PlayerInput
var _rig: CameraRig
var _car: PlayerCar
var _controls: DriveControls
var _car_index: int = 0

# Traffic (M3): sim + director + view, hits with the lives rules (infinite lives here).
var _registry: TrafficRegistry
var _sim: TrafficSim
var _tdir: TrafficDirector
var _traffic_view: TrafficView
var _events: ScoreEventBuffer
var _hits: HitDetection
var _contact := HitDetection.Contact.new()
var _lives: Lives
var _frustum_smp := RoadSample.new()
var _leg: int = START_LEG
var _night: bool = false
var _leg_button: Button
var _params_cache: Dictionary = {}
var _next_forget_s: float = 0.0
var _resets: int = 0

var _cam_button: Button
var _steer_button: Button
var _throttle_button: Button
var _mirror_button: Button
var _car_button: Button
var _speed_label: Label


func _ready() -> void:
	# Web: `?scene=sandbox` in the page URL opens the traffic sandbox instead
	# (browsers can't pass scene paths on the command line).
	if OS.has_feature("web") and _url_scene() == "sandbox":
		set_physics_process(false)
		set_process(false)
		_open_sandbox.call_deferred()
		return
	# After the car (0), before the camera rig (100): follow the car's new position.
	process_physics_priority = 50
	_tuning = Tuning.load_default()
	_ctx = RunContext.new(run_seed)
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

	_sky = $Sky
	_hub = $PlayerInput
	_rig = $CameraRig
	_hub.camera_cycle_requested.connect(_rig.cycle_mode)
	Events.camera_mode_changed.connect(func(_m: StringName) -> void: _refresh_buttons())
	Events.settings_changed.connect(func(_k: StringName) -> void: _refresh_buttons())

	_road.ensure_generated_to(_view_ahead(0.0))
	var smp := _road.sample(0.0)
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	_director.setup(_ctx, _road, _origin)
	_builder.setup(_ctx, _road, _origin)
	_roadside.setup(_ctx, _road, _origin)
	_sky.setup(_ctx, _road, _origin)
	_builder.build_all_now(0.0)

	_setup_traffic()
	_spawn_car(0, 0.0)
	_build_controls()
	_build_traffic_controls()

	if Game.can_change_to(Game.COUNTDOWN):
		Game.change_state(Game.COUNTDOWN)
	if Game.can_change_to(Game.RUNNING):
		Game.change_state(Game.RUNNING)


func _physics_process(_delta: float) -> void:
	var st := _car.state
	_road.ensure_generated_to(_view_ahead(st.s))
	if st.s >= _next_forget_s:
		_road.forget_before(st.s - _roadside.reach_behind_m() - _tuning.road.chunk_length_m)
		_next_forget_s = st.s + FORGET_EVERY_M
	_traffic_tick(1.0 / float(Engine.physics_ticks_per_second))
	var smp := _car.road_sample()
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	# Crash hand-off is Phase 4: leaving the carriageway puts the car back.
	if st.d < _road.median_barrier_d(st.s) or st.d > _road.guardrail_d(st.s):
		_reset_car(st.v * 0.5)


func _process(_delta: float) -> void:
	var st := _car.state
	_director.update_view(st.s)
	_builder.update_view(st.s)
	_roadside.update_view(st.s)
	_sky.update_view(st.s)
	_traffic_view.update_view(st.s)
	var night := _sky.current().emissive_headlight > HEADLIGHTS_ON
	if night != _night:
		_night = night
		_sim.set_headlights(night)
		_tdir.set_night(night)
	DevStats.report(DevStats.VEHICLES, _sim.state.count)
	DevStats.report(&"opposite", _tdir.opposite.state.count)
	DevStats.report(&"leg", _leg)
	DevStats.report(&"hits", _lives.hits)
	DevStats.report(&"ghost", _lives.is_ghost())
	var kmh := st.v * 3.6
	DriveControls.set_text(_speed_label, "%d km/h  G%d" % [roundi(kmh), st.gear])
	DevStats.report(&"car", _car.car.id)
	DevStats.report(&"speed_kmh", roundi(kmh))
	DevStats.report(&"gear", st.gear)
	DevStats.report(&"rpm", roundi(st.rpm))
	DevStats.report(&"s_m", roundi(st.s))
	DevStats.report(&"d_m", snappedf(st.d, 0.01))
	DevStats.report(&"lane", _road.lane_index_at(st.d, st.s))
	DevStats.report(&"yaw_deg", snappedf(rad_to_deg(st.yaw), 0.1))
	DevStats.report(&"lat_g", snappedf(st.accel_lat / 9.81, 0.01))
	DevStats.report(&"in_steer", snappedf(_car.input.steer, 0.01))
	DevStats.report(&"in_throttle", snappedf(_car.input.throttle, 0.01))
	DevStats.report(&"in_brake", snappedf(_car.input.brake, 0.01))
	DevStats.report(&"boost", snappedf(st.boost_meter, 0.01))
	DevStats.report(&"layout", "%s/%s%s" % [_hub.effective_steering, _hub.throttle_mode,
		" mirrored" if _hub.left_handed else ""])
	DevStats.report(&"camera", _rig.mode)
	DevStats.report(&"sky_t", snappedf(_sky.sky_t, 0.001))
	DevStats.report(&"resets", _resets)
	DevStats.report(&"seed", run_seed)


## Snap hook (tools/snap.sh): --s=, --sky_t=, --car=0..2, --cam=, --speed_kmh=.
func snap_setup(args: Dictionary) -> void:
	if args.has("sky_t"):
		_sky.sky_t = float(args["sky_t"])
	if args.has("car"):
		_car_index = int(args["car"]) % CAR_PATHS.size()
	var s := float(args.get("s", 0.0))
	var v := Units.kmh_to_mps(float(args.get("speed_kmh", START_SPEED_KMH)))
	_road.ensure_generated_to(_view_ahead(s))
	var smp := _road.sample(s)
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	_builder.build_all_now(s)
	_spawn_car(_car_index, s, v)
	# Teleported: respawn traffic around the new position.
	for i in _sim.state.capacity:
		if _sim.state.active[i] != 0:
			_sim.despawn(i)
	_tdir.set_leg(_leg, s)
	_tdir.reset(_car.state)
	_hits.reset(_car.state, _sim.state)
	if args.has("cam"):
		_rig.set_mode(StringName(str(args["cam"])))
	_rig.snap_to_target()


func _spawn_car(index: int, s: float, v_mps: float = -1.0) -> void:
	var car_def: CarDef = load(CAR_PATHS[index])
	if not _params_cache.has(index):
		_params_cache[index] = VehicleParams.build(_tuning, car_def)
	if _car != null:
		remove_child(_car)
		_car.queue_free()
	_car = (load("res://src/vehicle/player_car.tscn") as PackedScene).instantiate()
	_car.name = "PlayerCar"
	add_child(_car)
	_car.setup(_ctx, _road, _origin, car_def, _params_cache[index])
	_car.controller = PlayerController.new(_hub)
	var v := v_mps if v_mps >= 0.0 else Units.kmh_to_mps(START_SPEED_KMH)
	_car.place_at(s, _road.lane_center_d(START_LANE, s), v)
	_rig.set_target(_car, _car.state, _car.params.top_speed_mps)
	_rig.snap_to_target()
	if _sim != null:
		_sim.set_player_body(car_def.length_m, car_def.width_m)
		_hits.set_player_body(car_def.length_m, car_def.width_m)
		_hits.reset(_car.state, _sim.state)
		_tdir.set_player_box(car_def.length_m, car_def.width_m)
		if _sim.state.count == 0:
			_tdir.set_leg(_leg, s)
			_tdir.reset(_car.state)


func _reset_car(v_mps: float) -> void:
	_resets += 1
	var s := _car.state.s
	var lane := clampi(_road.lane_index_at(_car.state.d, s), 0, _road.lane_count(s) - 1)
	if lane < 0:
		lane = START_LANE
	_car.place_at(s, _road.lane_center_d(lane, s), maxf(v_mps, 0.0))
	_rig.snap_to_target()
	if _hits != null:
		_hits.reset(_car.state, _sim.state)


func _view_ahead(s: float) -> float:
	return s + _builder.view_distance_m() + _tuning.road.chunk_length_m * 2.0


# ---------------------------------------------------------------- Traffic (M3)

func _setup_traffic() -> void:
	_registry = TrafficRegistry.load_default(_tuning.traffic)
	_sim = TrafficSim.new(_ctx, _road, _registry)
	_events = ScoreEventBuffer.new(_tuning.scoring.event_buffer_capacity)
	var car_def: CarDef = load(CAR_PATHS[_car_index])
	_tdir = TrafficDirector.new(_ctx, _road, _sim, _registry.profiles, _registry.types,
		car_def.length_m, car_def.width_m)
	_tdir.frustum_check = _in_frustum
	_tdir.set_fog_end(_builder.view_distance_m())
	_hits = HitDetection.new(_tuning.lives, _tuning.traffic.max_active_vehicles)
	_lives = Lives.new(_tuning.lives)
	_traffic_view = TrafficView.new()
	_traffic_view.name = "TrafficView"
	add_child(_traffic_view)
	_traffic_view.setup(_ctx, _road, _origin, _registry, _sim.state, _tdir.opposite.state)
	var biome := _director.current()
	if biome != null and not biome.traffic_palette.is_empty():
		_traffic_view.set_palette(biome.traffic_palette)


## One 120 Hz traffic tick after the car's physics (contract order: car, traffic,
## director, collisions). Hits use the lives rules; this dev scene never ends a run.
func _traffic_tick(dt: float) -> void:
	var st := _car.state
	var t0 := Time.get_ticks_usec()
	_sim.step(dt, st, _car.params, _events)
	DevStats.report_sim_tick_usec(Time.get_ticks_usec() - t0)
	_tdir.step(dt, st)
	_traffic_view.capture_tick()
	if _hits.step(dt, st, _sim.state, _road, _contact):
		var outcome := _lives.on_contact(_contact, st, _events)
		if outcome != Lives.Outcome.NONE and outcome != Lives.Outcome.IGNORED and _contact.slot >= 0:
			_sim.notify_hit(_contact.slot)
		if outcome == Lives.Outcome.RUN_OVER:
			_lives.reset()   # infinite lives until the Phase 4 crash hand-off
	_lives.step(dt, st, _events)
	_events.clear()


func _in_frustum(s: float, d: float) -> bool:
	_road.sample_into(s, _frustum_smp)
	var p := _frustum_smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z)
	return _rig.camera().is_position_in_frustum(p)


func _build_traffic_controls() -> void:
	_leg_button = _controls.add_button(DriveControls.Corner.TOP_LEFT, 2, "LEG", LAYOUT_BUTTON, _next_leg, true)
	DriveControls.set_text(_leg_button, "LEG %d" % _leg)


func _next_leg() -> void:
	_leg = _leg % LEG_COUNT + 1
	_tdir.set_leg(_leg, _car.state.s)
	DriveControls.set_text(_leg_button, "LEG %d" % _leg)


# ---------------------------------------------------------------- Dev buttons

func _build_controls() -> void:
	_controls = DriveControls.new()
	_controls.name = "DriveControls"
	var top_right := DriveControls.Corner.TOP_RIGHT
	_cam_button = _controls.add_button(top_right, 0, "CAM", CAM_BUTTON, _hub.request_camera_cycle)
	_controls.add_button(top_right, 0, "HUD", DriveControls.WIDE, Callable($DevHud, &"toggle"))
	_steer_button = _controls.add_button(top_right, 1, "STEER", LAYOUT_BUTTON, _toggle_steering, true)
	_throttle_button = _controls.add_button(top_right, 1, "THR", LAYOUT_BUTTON, _toggle_throttle, true)
	_mirror_button = _controls.add_button(top_right, 1, "MIRROR", LAYOUT_BUTTON, _toggle_mirror, true)
	_car_button = _controls.add_button(top_right, 2, "CAR", LAYOUT_BUTTON, _next_car, true)
	_controls.add_button(top_right, 2, "RECAL", LAYOUT_BUTTON, _hub.recalibrate_gyro, true)
	_controls.add_button(top_right, 2, "RESET", LAYOUT_BUTTON, func() -> void: _reset_car(_car.state.v), true)
	_controls.add_button(DriveControls.Corner.TOP_LEFT, 1, "SANDBOX", LAYOUT_BUTTON, _open_sandbox, true)
	_speed_label = _controls.add_label(DriveControls.Corner.TOP_LEFT, 0, 200.0)
	add_child(_controls)
	_refresh_buttons()


func _open_sandbox() -> void:
	get_tree().change_scene_to_file(SANDBOX_SCENE)


static func _url_scene() -> String:
	var query: Variant = JavaScriptBridge.eval("window.location.search", true)
	if not (query is String):
		return ""
	for part: String in (query as String).trim_prefix("?").split("&"):
		if part.begins_with("scene="):
			return part.trim_prefix("scene=").to_lower()
	return ""


func _toggle_steering() -> void:
	var gyro: bool = Settings.get_value(&"steering_mode") != &"gyro"
	Settings.set_value(&"steering_mode", &"gyro" if gyro else &"drag")
	if gyro:
		# Web: arms the one-shot motion-permission request on the next tap (iOS Safari).
		_hub.gyro.source.activate()
		_hub.recalibrate_gyro()


func _toggle_throttle() -> void:
	var manual: bool = Settings.get_value(&"throttle_mode") != &"manual"
	Settings.set_value(&"throttle_mode", &"manual" if manual else &"auto")


func _toggle_mirror() -> void:
	Settings.set_value(&"left_handed", not bool(Settings.get_value(&"left_handed")))


func _next_car() -> void:
	_car_index = (_car_index + 1) % CAR_PATHS.size()
	var st := _car.state
	_spawn_car(_car_index, st.s, st.v)
	_refresh_buttons()


func _refresh_buttons() -> void:
	if _controls == null:
		return
	DriveControls.set_text(_cam_button, "CAM %s" % String(_rig.mode).to_upper())
	var steering := String(_hub.effective_steering).to_upper()
	if Settings.get_value(&"steering_mode") == &"gyro" and _hub.effective_steering != &"gyro":
		steering = "GYRO N/A"
	DriveControls.set_text(_steer_button, "STEER %s" % steering)
	DriveControls.set_text(_throttle_button, "THR %s" % String(Settings.get_value(&"throttle_mode")).to_upper())
	DriveControls.set_text(_mirror_button, "LEFT-H" if Settings.get_value(&"left_handed") else "RIGHT-H")
	DriveControls.set_text(_car_button, String(_car.car.id).to_upper() if _car != null else "CAR")
