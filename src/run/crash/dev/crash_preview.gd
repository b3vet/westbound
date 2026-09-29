extends Node3D
## Crash review scene (WP4.2). Spec: Lives, hits and crashes → Second hit (run over);
## Cameras → Scripted cameras (Crash). The real world stack (procedural road,
## roadside, farmland biome, sky), the PlayerCar and a few traffic cars. The player
## runs into a car ahead (or scrapes the guardrail), the CrashSequence takes over, and
## the scene loops: crash, results pause, reset, drive again.
##
##   tools/snap.sh src/run/crash/dev/crash_preview.tscn --renderer=both --t=1.2
##   tools/snap.sh src/run/crash/dev/crash_preview.tscn --sweep=t:0,0.6,1.2,2.0
##   tools/snap.sh src/run/crash/dev/crash_preview.tscn --scenario=barrier --t=1.0
##
## snap_setup options: --t=<real seconds into the crash> (the scene waits for the crash,
## runs it that long and pauses the tree, so the snap shows the tumble and the orbit
## camera), --scenario=traffic|barrier, --sky_t=<0..1>, --slowmo=false (ignore the
## slow-motion request, as if no time-scale service were running).
##
## Stand-ins for run-loop services that don't exist yet: slow-motion requests set
## Engine.time_scale here, and the cars around the crash brake (the run's "surrounding
## traffic brakes" needs TrafficSim.brake_all_near). Traffic here moves at constant
## speed in its lane; there is no TrafficSim.

const CAR_PATH := "res://data/cars/falcon_gt.tres"
const PLAYER_SCENE := "res://src/vehicle/player_car.tscn"
const SCENARIOS := ["traffic", "barrier"]
## Dev scene layout (m, km/h, s): the player, the car it hits, and bystanders.
const START_S_M := 900.0
const PLAYER_LANE := 1
const PLAYER_KMH := 175.0
const TARGET_TYPE := &"sedan"
const TARGET_KMH := 105.0
## Box-to-box gap ahead of the player's nose, and the hit car's offset from its lane
## centre (a corner hit spins both cars).
const TARGET_GAP_M := 17.0
const TARGET_OFFSET_M := 1.1
const BYSTANDERS: Array[Vector3] = [Vector3(0.0, 35.0, 120.0), Vector3(2.0, 70.0, 95.0), Vector3(2.0, -30.0, 110.0)]
const BYSTANDER_TYPES: Array[StringName] = [&"hatchback", &"semi", &"suv"]
const BYSTANDER_BRAKE_MPS2 := 6.0
## Barrier scenario: start in the slow lane and steer into the guardrail.
const BARRIER_LANE := 2
const BARRIER_STEER := 0.35
## Real seconds the results would show before the loop restarts.
const RESULTS_HOLD_S := 1.5
const SNAP_TIMEOUT_FRAMES := 900

@export var run_seed: int = 20260928

@onready var _sky: SkyRig = $Sky
@onready var _rig: CameraRig = $CameraRig
@onready var _label: Label = $UI/Label

var _tuning: Tuning
var _ctx: RunContext
var _road: ProceduralRoadPath
var _origin: FloatingOrigin
var _director: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _registry: TrafficRegistry
var _state: TrafficState
var _view: TrafficView
var _car: PlayerCar
var _hits: HitDetection
var _contact := HitDetection.Contact.new()
var _crash: CrashSequence
var _scenario: String = "traffic"
var _honour_slowmo: bool = true
var _slowmo_left_s: float = 0.0
var _hold_left_s: float = -1.0
var _smp := RoadSample.new()


class HoldController:
	extends VehicleController
	var steer: float = 0.0

	func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
		out_input.clear()
		out_input.throttle = 1.0
		out_input.steer = steer


func _ready() -> void:
	# After the car (0), before the camera rig (100), like the run.
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
	_road.ensure_generated_to(_view_ahead(START_S_M))
	_road.sample_into(START_S_M, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_director.setup(_ctx, _road, _origin)
	_builder.setup(_ctx, _road, _origin)
	_roadside.setup(_ctx, _road, _origin)
	_sky.setup(_ctx, _road, _origin)
	_builder.build_all_now(START_S_M)

	_registry = TrafficRegistry.load_default(_tuning.traffic)
	_state = TrafficState.new(_tuning.traffic.max_active_vehicles)
	_view = TrafficView.new()
	_view.name = "TrafficView"
	add_child(_view)
	_view.setup(_ctx, _road, _origin, _registry, _state)
	var biome := _director.current()
	if biome != null and not biome.traffic_palette.is_empty():
		_view.set_palette(biome.traffic_palette)

	var car_def := load(CAR_PATH) as CarDef
	_car = (load(PLAYER_SCENE) as PackedScene).instantiate() as PlayerCar
	_car.name = "PlayerCar"
	add_child(_car)
	_car.setup(_ctx, _road, _origin, car_def)
	_car.controller = HoldController.new()
	_hits = HitDetection.new(_tuning.lives, _state.capacity)
	_hits.set_player_body(car_def.length_m, car_def.width_m)

	_crash = CrashSequence.new()
	_crash.name = "CrashSequence"
	add_child(_crash)
	_crash.setup(_ctx, _registry)
	_crash.finished.connect(_on_crash_finished)
	Events.slowmo_requested.connect(_on_slowmo_requested)
	_restart()


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	# snap_setup pauses the tree for the capture; the next capture starts running.
	get_tree().paused = false
	if Events.slowmo_requested.is_connected(_on_slowmo_requested):
		Events.slowmo_requested.disconnect(_on_slowmo_requested)


## Snap hook: --t, --scenario, --sky_t, --slowmo (see the header).
func snap_setup(args: Dictionary) -> void:
	if args.has("sky_t"):
		_sky.sky_t = float(args["sky_t"])
	_honour_slowmo = bool(args.get("slowmo", true))
	var scenario := str(args.get("scenario", "traffic"))
	if not SCENARIOS.has(scenario):
		push_warning("crash_preview: unknown scenario %s (%s)" % [scenario, ", ".join(SCENARIOS)])
		scenario = "traffic"
	_scenario = scenario
	_restart()
	if not args.has("t"):
		return
	var t := float(args["t"])
	var frames := 0
	while (not _crash.is_running() or _crash.elapsed_s() < t) and frames < SNAP_TIMEOUT_FRAMES:
		await get_tree().process_frame
		frames += 1
	if not _crash.is_running():
		push_warning("crash_preview: no crash within %d frames" % SNAP_TIMEOUT_FRAMES)
	# Freeze the tumble and the orbit here for the capture.
	get_tree().paused = true
	_label.text = "%s crash  t=%.2f s  time scale %.2f" % [_scenario, _crash.elapsed_s(), Engine.time_scale]


func _physics_process(dt: float) -> void:
	var braking := _crash.is_running()
	for i in _state.capacity:
		if _state.active[i] == 0:
			continue
		if braking and i != _crash.hidden_slot():
			_state.v[i] = maxf(_state.v[i] - BYSTANDER_BRAKE_MPS2 * dt, 0.0)
			_state.flags[i] |= TrafficState.FLAG_BRAKE | TrafficState.FLAG_BRAKE_STRONG
		_state.s[i] += _state.v[i] * dt
	_view.capture_tick()
	if braking:
		return
	var smp := _car.road_sample()
	_origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	if _hits.step(dt, _car.state, _state, _road, _contact):
		_crash.start(_car, _contact, _state, _view, _road, _origin, _rig)


func _process(delta: float) -> void:
	var s := _car.state.s
	_director.update_view(s)
	_builder.update_view(s)
	_roadside.update_view(s)
	_sky.update_view(s)
	_view.update_view(s)
	var real_dt := delta / Engine.time_scale if Engine.time_scale > 0.0 else delta
	if _slowmo_left_s > 0.0:
		_slowmo_left_s -= real_dt
		if _slowmo_left_s <= 0.0:
			Engine.time_scale = 1.0
	if _hold_left_s >= 0.0:
		_hold_left_s -= real_dt
		if _hold_left_s < 0.0:
			_restart()
	if not get_tree().paused:
		_label.text = "%s  %s  t=%.2f s  time scale %.2f  (tap skips)" % [_scenario,
			"CRASH" if _crash.is_running() else "driving", _crash.elapsed_s(), Engine.time_scale]


func _on_slowmo_requested(time_scale: float, duration_s: float, _reason: StringName) -> void:
	if not _honour_slowmo or bool(Settings.get_value(&"reduced_motion")):
		return
	Engine.time_scale = time_scale
	_slowmo_left_s = duration_s


func _on_crash_finished(_skipped: bool) -> void:
	Engine.time_scale = 1.0
	_slowmo_left_s = 0.0
	_hold_left_s = RESULTS_HOLD_S


## Resets the crash, the car and the traffic to the scenario's start.
func _restart() -> void:
	_crash.reset()
	Engine.time_scale = 1.0
	_slowmo_left_s = 0.0
	_hold_left_s = -1.0
	_state.clear()
	var s := START_S_M
	var controller := _car.controller as HoldController
	if _scenario == "barrier":
		var d := _road.lane_center_d(BARRIER_LANE, s)
		_car.place_at(s, d, Units.kmh_to_mps(PLAYER_KMH))
		controller.steer = BARRIER_STEER
	else:
		_car.place_at(s, _road.lane_center_d(PLAYER_LANE, s), Units.kmh_to_mps(PLAYER_KMH))
		controller.steer = 0.0
		var t := _registry.type_index(TARGET_TYPE)
		var ahead := (_car.car.length_m + _registry.length[t]) * 0.5 + TARGET_GAP_M
		_put(TARGET_TYPE, PLAYER_LANE, s + ahead, TARGET_KMH, TARGET_OFFSET_M, 2)
	for k in BYSTANDERS.size():
		var b := BYSTANDERS[k]
		# The barrier run keeps its lane clear so the guardrail is what it hits.
		if _scenario == "barrier" and int(b.x) == BARRIER_LANE:
			continue
		_put(BYSTANDER_TYPES[k], int(b.x), s + b.y, b.z, 0.0, k + 4)
	_road.sample_into(s, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_hits.reset(_car.state, _state)
	_view.capture_tick()
	_view.capture_tick()
	_rig.set_target(_car, _car.state, _car.params.top_speed_mps)
	_rig.camera().make_current()
	_rig.snap_to_target()


func _put(type_id: StringName, lane: int, s: float, kmh: float, offset_m: float, color: int) -> int:
	var i := _state.allocate()
	var t := _registry.type_index(type_id)
	_state.s[i] = s
	_state.d[i] = _road.lane_center_d(lane, s) + offset_m
	_state.v[i] = Units.kmh_to_mps(kmh)
	_state.v0[i] = _state.v[i]
	_state.length[i] = _registry.length[t]
	_state.width[i] = _registry.width[t]
	_state.lane[i] = lane
	_state.target_lane[i] = lane
	_state.type_id[i] = t
	_state.color_index[i] = color
	return i


func _view_ahead(s: float) -> float:
	return s + _builder.view_distance_m() + _tuning.road.chunk_length_m * 2.0
