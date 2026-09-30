extends Node3D
# lint: not-sim dev scene (Node): it drives the real TrafficSim and TrafficDirector and times their ticks
## Traffic sandbox: where traffic quality gets tuned. Spec: Traffic → Traffic sandbox
## (debug scene) ("a free camera, time scale control and pause/step; spawn controls;
## overlays for each vehicle's IDM gap and target speed, MOBIL decisions with
## incentive values, blinker timers, the player's predicted occupancy, and the
## passability paths the director found"); Tech stack → dev HUD; plan WP3.2.
##
## The real stack of a run: ProceduralRoadPath (or road_override), FloatingOrigin, RoadBuilder, Roadside,
## BiomeDirector, SkyRig; TrafficSim + TrafficDirector (+ opposite carriageway); the
## real PlayerCar, driven either by PlayerInput (touch / keys, PlayerController) or by
## SandboxBot (lane keeping or weaving). The player takes part in the sim as in a run
## (tick order: car physics, traffic_sim.step, director.step; CONTRACTS §4) and hits
## are reported with notify_hit. Traffic is drawn by TrafficView (TrafficDebugView
## remains available at _make_traffic_view()); overlays by TrafficOverlay; the camera by SandboxCamera.
##
## Time: an accumulator runs 120 Hz ticks at time_scale (0.1x..4x), capped per frame.
## Pause holds the sim; STEP runs exactly one tick, +1 S runs 120.
## Traffic has its own seed (SEED re-seeds it); the road keeps the scene's run_seed.
##
## Controls (touch buttons, tabs at the top right, the tab's buttons at the bottom
## right; tap the open tab again to fold it):
##   TIME    PAUSE/PLAY, STEP (one 120 Hz tick), +1 S (120 ticks), time scale - / +
##   SPAWN   LEG 1-8 (density, mix), SEED (re-seed traffic), CLEAR, FILL, AUTO (director
##           spawning on/off), OPP (opposite carriageway); PROFILE, TYPE, LANE,
##           AHEAD/BEHIND, SPAWN (one specific vehicle)
##   DRIVE   BOT KEEP / BOT WEAVE / MANUAL, BOT speed, CAR RESET, STEER, THR
##   VIEW    CAM FOLLOW / TOP / FREE, RIG (gameplay camera mode), RE-FRAME, LABELS
##           (cap), SEL < / SEL > (ask the selected car to change lanes)
##   LAYERS  IDM, MOBIL, BLINK, OCC, PASS
##   HUD     dev HUD (COPY report)
##   WALL / BLOCK / SLALOM / CONVOY / MERGE / WORKS / TUNNEL / TOLL / WAVES (top right,
##           second row; SetPieceControls, WP6.2 + WP6.3): force a set piece (the next
##           batch; a road-anchored one beyond the view, a feature-triggered one at its
##           next tunnel / toll-gantry checkpoint); show the intensity curve (IntensityPlot).
##           The pieces' props are drawn by SetPieceView (WP6.3).
##   FAST xK / RACER (top right, below the set pieces; FastTrafficControls, WP6.6): scale
##           the fast shares (aggressive + racer); spawn a racer behind the player; below
##           them ARR ON/OFF and ARRIVE: the director's racer arrivals from behind (WP6.7)
##   NET ON/OFF / LINK (below them; NetTrafficControls, N4.3): network mode, the traffic
##           from a fake server over a simulated link through NetworkTrafficSource, with
##           the network overlays (NetTrafficOverlay); the local sim and director stop
## Tap a vehicle to select it (all MOBIL terms in a side panel).
## Keys: Space pause, . step, N +1 s, [ ] time scale, V camera mode, B driver,
## X clear, 1-5 layers (IDM, MOBIL, BLINK, OCC, PASS), backtick dev HUD, C rig camera.
## Stats go to the top-left panel and to DevStats (the dev HUD's COPY report).

const CAR_PATH := "res://data/cars/falcon_gt.tres"
const PLAYER_CAR_SCENE := "res://src/vehicle/player_car.tscn"
const START_LANE := 1
const START_SPEED_KMH := 130.0
const START_LEG := 3
const DT := 1.0 / 120.0
## Sim ticks per rendered frame at most (4x at 30 fps = 16; beyond that time slows).
const MAX_TICKS_PER_FRAME := 24
const TICKS_PER_SECOND := 120
const TIME_SCALES: Array[float] = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0]
const BOT_SPEEDS_KMH: Array[float] = [80.0, 100.0, 120.0, 130.0, 150.0, 170.0, 190.0]
const LABEL_CAPS: Array[int] = [0, 6, 14, 24]
const LEGS := 8
## Spawn-specific placement: distance ahead / behind the player, search step and tries,
## and the free space kept to other vehicles (bumper to bumper).
const SPAWN_AHEAD_M := 70.0
const SPAWN_BEHIND_M := 45.0
const SPAWN_STEP_M := 6.0
const SPAWN_TRIES := 40
const SPAWN_CLEAR_M := 12.0
const HEADLIGHTS_ON := 0.3
## The PASS overlay re-checks the player's own window this often (a check costs a few ms).
const PASS_REFRESH_S := 0.5
const STATS_INTERVAL_S := 0.25
const LC_WINDOW_S := 60
const FORGET_EVERY_M := 500.0
const TAB_BUTTON := Vector2(100.0, 56.0)
const BUTTON := Vector2(124.0, 56.0)
const WIDE_BUTTON := Vector2(168.0, 56.0)
const STATS_FONT_SIZE := 14
## Overlay and stats text scales (TEXT button); touch screens start at the second.
const TEXT_SCALES: Array[float] = [1.0, 1.3, 1.6]
const STATS_WIDTH_PX := 470.0
const EDGE_PX := 16.0
const SLIDER_WIDTH_PX := 400.0

enum Driver { BOT_KEEP, BOT_WEAVE, MANUAL }
const DRIVER_NAMES: Array[String] = ["BOT KEEP", "BOT WEAVE", "MANUAL"]
enum Tab { NONE, TIME, SPAWN, DRIVE, VIEW, LAYERS }
const TAB_NAMES: Array[String] = ["", "TIME", "SPAWN", "DRIVE", "VIEW", "LAYERS"]

@export var run_seed: int = 20260928
@export var traffic_seed: int = 1

var time_scale: float = 1.0
var paused: bool = false
var leg: int = START_LEG
var driver: Driver = Driver.BOT_WEAVE
var auto_spawn: bool = true
var sim_time: float = 0.0
var ticks: int = 0
var hits: int = 0
var spawn_profile: int = 0
var spawn_type_pick: int = 0     ## index into the profile's allowed types
var spawn_lane: int = 1
var spawn_ahead: bool = true

var tuning: Tuning
var road: RoadPath
## Road injection (N3.1, the loop editor's PREVIEW TRAFFIC): set before the node enters
## the tree to run the sandbox on another RoadPath (e.g. LoopRoadPath) instead of the
## procedural road; with biome_plan_override the look follows that plan. start_s: where
## the car starts.
var road_override: RoadPath
var biome_plan_override: BiomePlan
var start_s: float = 0.0
var origin: FloatingOrigin
var sky: SkyRig
var car: PlayerCar
var registry: TrafficRegistry
var traffic_ctx: RunContext
var sim: TrafficSim
var director: TrafficDirector
var probe: MobilProbe
## The traffic renderer, duck-typed: TrafficDebugView now, WP3.1's TrafficView later
## (both: setup(ctx, road, origin, registry, state, opposite), capture_tick(),
## set_palette()). Optional extras are set with Object.set (ignored when missing):
## show_opposite, blink_time.
var view: Node3D
var show_opposite: bool = true
var overlay: TrafficOverlay
var cam: SandboxCamera
var rig: CameraRig
var hub: PlayerInput
var bot: SandboxBot
var events: ScoreEventBuffer
## Set-piece triggers and the intensity curve (WP6.2).
var set_piece_controls: SetPieceControls
## The fast-traffic controls (plan D15, WP6.6).
var fast_controls: FastTrafficControls
## Network mode (N4.3).
var net_controls: NetTrafficControls
## The set pieces' props (WP6.3).
var set_piece_view: SetPieceView

var _ctx: RunContext
var _biome: BiomeDirector
var _builder: RoadBuilder
var _roadside: Roadside
var _player_ctl: PlayerController
var _acc: float = 0.0
var _pending_steps: int = 0
var _next_forget_s: float = 0.0
var _night: bool = false
var _smp := RoadSample.new()
var _inset: float = 0.0
var _last_tick_usec: int = 0
var _lc_ring := PackedInt32Array()       ## stat_completed at each of the last LC_WINDOW_S sim seconds
var _lc_ring_t := PackedFloat64Array()   ## ... and the sim time of each sample
var _lc_ring_n: int = 0
var _lc_next_t: float = 1.0
var _stats_t: float = 0.0
var _pass: Passability
var _pass_res := Passability.Result.new()
var _pass_t: float = 0.0
var _pass_usec: int = 0
var _lane_sum := PackedFloat64Array()
var _lane_n := PackedInt32Array()

# UI
var _tab: Tab = Tab.TIME
var _tabs_bar: DriveControls
var _panels: Dictionary = {}      ## Tab -> DriveControls
var _tab_buttons: Dictionary = {} ## Tab -> Button
var _buttons: Dictionary = {}     ## StringName -> Button
var _stats_label: Label
var _controls_overlay: Control


func _ready() -> void:
	process_physics_priority = 50   # after PlayerInput (-100), before the CameraRig (100)
	tuning = Tuning.load_default()
	_ctx = RunContext.new(run_seed, RunContext.MODE_JOURNEY, tuning)
	_inset = tuning.lives.collision_inset_m
	road = road_override if road_override != null else ProceduralRoadPath.new(_ctx)
	registry = TrafficRegistry.load_default(tuning.traffic)
	events = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity)
	_lc_ring.resize(LC_WINDOW_S + 1)
	_lc_ring_t.resize(LC_WINDOW_S + 1)
	_lane_sum.resize(tuning.traffic.lane_flow_speeds_from_right_kmh.size())
	_lane_n.resize(_lane_sum.size())

	origin = FloatingOrigin.new()
	origin.name = "FloatingOrigin"
	add_child(origin)
	origin.setup(tuning.road.floating_origin_shift_km)
	_biome = BiomeDirector.new()
	_biome.name = "BiomeDirector"
	add_child(_biome)
	_builder = RoadBuilder.new()
	_builder.name = "RoadBuilder"
	_builder.biome_director = _biome
	add_child(_builder)
	_roadside = Roadside.new()
	_roadside.name = "Roadside"
	_roadside.biome_director = _biome
	add_child(_roadside)

	sky = $Sky
	hub = $PlayerInput
	rig = $CameraRig
	hub.camera_cycle_requested.connect(rig.cycle_mode)
	road.ensure_generated_to(_view_ahead(start_s))
	road.sample_into(start_s, _smp)
	origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_biome.plan = biome_plan_override
	_biome.setup(_ctx, road, origin)
	_builder.setup(_ctx, road, origin)
	_roadside.setup(_ctx, road, origin)
	sky.setup(_ctx, road, origin)
	_builder.build_all_now(start_s)

	_spawn_car()
	_player_ctl = PlayerController.new(hub)
	view = _make_traffic_view()
	set_piece_view = SetPieceView.new()
	set_piece_view.name = "SetPieceView"
	add_child(set_piece_view)
	set_piece_view.setup(_ctx, road, origin)
	cam = SandboxCamera.new()
	cam.name = "SandboxCamera"
	add_child(cam)
	cam.rig = rig
	cam.road = road
	cam.target = car
	cam.target_state = car.state
	cam.tapped.connect(_on_tapped)
	overlay = TrafficOverlay.new()
	overlay.name = "TrafficOverlay"
	$Overlay.add_child(overlay)
	$Overlay.move_child(overlay, 0)
	overlay.player = car.state
	overlay.player_length_m = car.car.length_m
	overlay.player_width_m = car.car.width_m
	_controls_overlay = $Overlay/ControlsOverlay
	reseed(traffic_seed)
	set_driver(driver)
	_build_ui()
	set_piece_controls = SetPieceControls.new()
	set_piece_controls.name = "SetPieceControls"
	set_piece_controls.sandbox = self
	add_child(set_piece_controls)
	_place_slider()
	get_viewport().size_changed.connect(_place_slider)
	fast_controls = FastTrafficControls.new()
	fast_controls.name = "FastTrafficControls"
	fast_controls.sandbox = self
	add_child(fast_controls)
	net_controls = NetTrafficControls.new()
	net_controls.name = "NetTrafficControls"
	net_controls.sandbox = self
	add_child(net_controls)
	if Game.can_change_to(Game.COUNTDOWN):
		Game.change_state(Game.COUNTDOWN)
	if Game.can_change_to(Game.RUNNING):
		Game.change_state(Game.RUNNING)


## The traffic renderer. Swap point for WP3.1: replace the first line with
##   var v: Node3D = (load("res://src/traffic/traffic_view.tscn") as PackedScene).instantiate()
## (or TrafficView.new()); everything else talks to it through setup / capture_tick.
func _make_traffic_view() -> Node3D:
	var v: Node3D = TrafficView.new()
	v.name = "TrafficView"
	add_child(v)
	return v


# ---------------------------------------------------------------- Simulation

func _physics_process(delta: float) -> void:
	advance_frame(delta)


## One physics frame: snapshot for interpolation, then as many 120 Hz ticks as the
## time scale asks for (or the queued steps while paused), then the world upkeep.
func advance_frame(delta: float) -> void:
	var n := 0
	if paused:
		n = _pending_steps
		_pending_steps = 0
		_acc = 0.0
	else:
		_acc += delta * time_scale
		n = floori(_acc / DT)
		_acc -= float(n) * DT
		if n > MAX_TICKS_PER_FRAME:
			n = MAX_TICKS_PER_FRAME
			_acc = 0.0
	advance_ticks(n)
	_upkeep()


## Runs n ticks right now (tests, snaps). The buttons queue steps with step_ticks().
func advance_ticks(n: int) -> void:
	for k in n:
		_tick()


## Queues n ticks for the next physics frame (STEP = 1, +1 S = 120). Pauses.
func step_ticks(n: int) -> void:
	paused = true
	_pending_steps += n
	_refresh_buttons()


func _tick() -> void:
	var st := car.state
	road.ensure_generated_to(st.s + _view_ahead(0.0))
	car.tick(DT)
	var t0 := Time.get_ticks_usec()
	var net := is_network()
	if net:
		net_controls.tick(DT)   # N4.3: the fake server, the link and NetworkTrafficSource
	else:
		sim.step(DT, st, car.params, events)
	var us := Time.get_ticks_usec() - t0
	DevStats.report_sim_tick_usec(us)
	_last_tick_usec = us
	if net:
		director.opposite.step(DT, st.s)   # local-only in multiplayer too
	elif auto_spawn:
		director.step(DT, st)
	else:
		director.step_despawn(st.s)
	# TrafficView interpolates between the last two captured ticks: capture every tick.
	view.call(&"capture_tick")
	_check_contacts()
	_forward_events()
	events.clear()
	if not net:
		overlay.observe_tick()
	sim_time += DT
	ticks += 1
	view.set(&"blink_time", sim_time)
	if sim_time >= _lc_next_t:
		_lc_next_t += 1.0
		_lc_sample()
	# No barriers until Phase 4: leaving the carriageway puts the car back in a lane.
	if st.d < road.median_barrier_d(st.s) or st.d > road.guardrail_d(st.s):
		reset_car()


func _upkeep() -> void:
	var st := car.state
	if st.s >= _next_forget_s:
		var behind := maxf(_roadside.reach_behind_m(), tuning.traffic.despawn_behind_m)
		if is_network():
			behind = maxf(behind, NetTrafficControls.REACH_BEHIND_M)
		road.forget_before(st.s - behind - tuning.road.chunk_length_m)
		_next_forget_s = st.s + FORGET_EVERY_M
	var smp := car.road_sample()
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	var night := sky.current().emissive_headlight > HEADLIGHTS_ON
	if night != _night:
		_night = night
		sim.set_headlights(night)
		director.set_night(night)
		if net_controls != null:
			net_controls.set_headlights(night)


## True while network mode (N4.3) drives the traffic.
func is_network() -> bool:
	return net_controls != null and net_controls.active


## Player vs traffic boxes in road space (inset like a run's collisions): the car gets
## notify_hit (swerve, hazards, recovery), as run.gd does. No lives here.
func _check_contacts() -> void:
	var st := sim.state
	var p := car.state
	var hl := car.car.length_m * 0.5 - _inset
	var hw := car.car.width_m * 0.5 - _inset
	for i in st.capacity:
		if st.active[i] == 0 or st.has_flag(i, TrafficState.FLAG_HIT):
			continue
		if absf(st.s[i] - p.s) < st.length[i] * 0.5 - _inset + hl and absf(st.d[i] - p.d) < st.width[i] * 0.5 - _inset + hw:
			if is_network():
				net_controls.notify_hit(i)
			else:
				sim.notify_hit(i)
			overlay.note_event(i, TrafficOverlay.Mark.HIT)
			hits += 1


func _forward_events() -> void:
	for k in events.size():
		var mark := TrafficOverlay.Mark.NONE
		match events.kind[k]:
			TrafficSim.KIND_HORN:
				mark = TrafficOverlay.Mark.HORN
			TrafficSim.KIND_BRAKE_TAP:
				mark = TrafficOverlay.Mark.BRAKE_TAP
			TrafficSim.KIND_HAZARDS:
				if events.value[k] > 0.0:
					mark = TrafficOverlay.Mark.HAZARDS
		if mark != TrafficOverlay.Mark.NONE:
			overlay.note_event(events.slot[k], mark)


func _process(delta: float) -> void:
	var st := car.state
	_biome.update_view(st.s)
	_builder.update_view(st.s)
	_roadside.update_view(st.s)
	set_piece_view.update_view(st.s)
	sky.update_view(st.s)
	view.call(&"update_view", st.s)
	cam.view_distance_m = _builder.view_distance_m()
	overlay.camera = cam.current_camera()
	_stats_t -= delta
	if _stats_t <= 0.0:
		_stats_t = STATS_INTERVAL_S
		refresh_stats()
	if overlay.show_passability:
		_pass_t -= delta
		if _pass_t <= 0.0:
			_pass_t = PASS_REFRESH_S
			refresh_passability()


## PASS overlay: the director's batch paths and the player's own path from now
## (Passability.check_player on the live traffic). Dev rate, allocates.
func refresh_passability() -> void:
	var paths: Array[PackedVector2Array] = []
	for i in director.pass_paths_s.size():
		var ps := director.pass_paths_s[i]
		var pd := director.pass_paths_d[i]
		var line := PackedVector2Array()
		for k in ps.size():
			line.append(Vector2(ps[k], pd[k]))
		paths.append(line)
	overlay.passability_paths = paths
	if _pass == null:
		_pass = Passability.new(tuning, registry, road)
		_pass.set_player_body(car.car.length_m, car.car.width_m)
	_pass.set_headway_scale(tuning.director.headway_scale(leg))
	var t0 := Time.get_ticks_usec()
	var ok := _pass.check_player(sim.state, car.state, car.params, road, _pass_res)
	_pass_usec = Time.get_ticks_usec() - t0
	overlay.player_path_ok = ok
	var mine := PackedVector2Array()
	for k in _pass_res.path_n:
		mine.append(Vector2(_pass_res.path_s[k], _pass_res.path_d[k]))
	overlay.player_path = mine
	overlay.player_path_note = "%d vehicles, %.1f ms%s" % [_pass_res.vehicles, float(_pass_usec) / 1000.0,
		"" if ok else ", blocked after %.2f s" % _pass_res.fail_t]


# ---------------------------------------------------------------- Actions

## New traffic seed: a fresh TrafficSim + TrafficDirector (streams derive from the
## seed), refilled around the player at the current leg.
func reseed(seed_value: int) -> void:
	traffic_seed = seed_value
	traffic_ctx = RunContext.new(traffic_seed, RunContext.MODE_JOURNEY, tuning)
	sim = TrafficSim.new(traffic_ctx, road, registry)
	sim.set_player_body(car.car.length_m, car.car.width_m)
	director = TrafficDirector.new(traffic_ctx, road, sim, registry.profiles, registry.types,
		car.car.length_m, car.car.width_m)
	director.set_fog_end(tuning.road.sim_horizon_m)   # as the run (N8.2: tier-independent)
	director.set_player_params(car.params)   # passability (WP6.1)
	director.record_pass_paths = true
	director.set_leg(leg, car.state.s)
	director.set_biome(_biome.current())
	director.checkpoint_style = _biome.checkpoint_style   # WP6.3: toll gantries
	_night = sky.current().emissive_headlight > HEADLIGHTS_ON
	sim.set_headlights(_night)
	director.set_night(_night)
	road.ensure_generated_to(car.state.s + director.ahead_distance() + _view_ahead(0.0))
	director.reset(car.state)
	probe = MobilProbe.new(sim, road)
	probe.set_player_body(car.car.length_m, car.car.width_m)
	probe.set_player(car.state)
	view.call(&"setup", traffic_ctx, road, origin, registry, sim.state, director.opposite.state)
	view.set(&"show_opposite", show_opposite)
	set_piece_view.bind(director.set_pieces)
	overlay.bind(sim, road, origin, probe)
	if bot != null:
		bot.traffic = sim.state
	if fast_controls != null:
		fast_controls.apply_to(director)   # racer arrivals on / off (WP6.7)
	if net_controls != null:
		net_controls.restart()   # N4.3: network mode on the new sim's TrafficState
	_lc_ring_n = 0
	_lc_sample()
	_lc_next_t = sim_time + 1.0
	hits = 0
	_refresh_buttons()


func set_leg(value: int) -> void:
	leg = clampi(value, 1, LEGS)
	director.set_leg(leg, car.state.s)
	_refresh_buttons()


## Removes every vehicle on the player's carriageway (the director keeps planning
## ahead, beyond the fog, unless AUTO is off).
func clear_traffic() -> void:
	if is_network():
		return   # the server owns the cars
	for i in sim.state.capacity:
		if sim.state.active[i] == 1:
			sim.despawn(i)
	overlay.selected_slot = -1


## Refills the road from the player to the ahead distance (director.reset).
func fill_traffic() -> void:
	if not is_network():
		director.reset(car.state)


## Spawns one vehicle of `profile_id` (type: the profile's allowed type number
## `type_pick`, wrapped) in `lane`, ahead of or behind the player, at the first spot
## with SPAWN_CLEAR_M free to every vehicle in that lane. Returns the slot, or -1.
func spawn_vehicle(profile_id: int, type_pick: int, lane: int, ahead: bool) -> int:
	if is_network():
		return -1   # the server owns the cars
	var st := car.state
	var lanes := road.lane_count(st.s)
	lane = clampi(lane, 0, lanes - 1)
	var types := registry.types_for_profile(profile_id)
	if types.is_empty():
		return -1
	var tid := types[posmod(type_pick, types.size())]
	var rec := SpawnSource.Record.new()
	rec.lane = lane
	rec.d = NAN
	rec.type_id = tid
	rec.profile_id = profile_id
	rec.v0 = 0.0
	var v0_mid := (registry.v0_min[profile_id] + registry.v0_max[profile_id]) * 0.5
	rec.v = minf(tuning.traffic.lane_flow_speed_mps(lane, lanes), v0_mid)
	rec.color_index = sim.state.next_vehicle_id
	var ln := registry.length[tid]
	var wd := registry.width[tid]
	var ld := road.lane_center_d(lane, st.s)
	var dir := 1.0 if ahead else -1.0
	var s := st.s + dir * (SPAWN_AHEAD_M if ahead else SPAWN_BEHIND_M)
	for k in SPAWN_TRIES:
		if _spot_free(s, ld, ln, wd):
			rec.s = s
			var slot := sim.spawn(rec)
			return slot
		s += dir * SPAWN_STEP_M
	return -1


func _spot_free(s: float, d: float, ln: float, wd: float) -> bool:
	var st := sim.state
	for j in st.capacity:
		if st.active[j] == 0:
			continue
		var jd_lo := minf(st.d[j], probe.move_target_d(j)) if st.lc_state[j] != TrafficState.LaneChange.NONE else st.d[j]
		var jd_hi := maxf(st.d[j], probe.move_target_d(j)) if st.lc_state[j] != TrafficState.LaneChange.NONE else st.d[j]
		if jd_hi + st.width[j] * 0.5 <= d - wd * 0.5 or jd_lo - st.width[j] * 0.5 >= d + wd * 0.5:
			continue
		if absf(st.s[j] - s) < (st.length[j] + ln) * 0.5 + SPAWN_CLEAR_M:
			return false
	var p := car.state
	if absf(p.d - d) < (car.car.width_m + wd) * 0.5 and absf(p.s - s) < (car.car.length_m + ln) * 0.5 + SPAWN_CLEAR_M:
		return false
	return true


## Asks the nearest car ahead of the player (within max_ahead_m) that can change lanes
## now to signal into an adjacent lane (TrafficSim.request_lane_change: the normal
## safety checks and telegraphing). For snaps and quick checks. Returns the slot or -1.
func request_nearby_lane_change(max_ahead_m: float) -> int:
	if is_network():
		return -1   # lane changes come from the server
	var st := sim.state
	var after := 0.0
	for attempt in st.capacity:
		var best := -1
		var best_ds := max_ahead_m
		for i in st.capacity:
			if st.active[i] == 0 or st.lc_state[i] != TrafficState.LaneChange.NONE:
				continue
			var ds := st.s[i] - car.state.s
			if ds > after and ds < best_ds:
				best = i
				best_ds = ds
		if best < 0:
			return -1
		for t: int in [st.lane[best] - 1, st.lane[best] + 1]:
			if sim.request_lane_change(best, t):
				overlay.note_request(best)
				return best
		after = best_ds
	return -1


## Asks the selected car (tap one first) to change lanes left (-1) or right (+1):
## TrafficSim.request_lane_change, the normal safety checks and telegraphing.
func request_selected_lane_change(dir: int) -> bool:
	if is_network():
		return false   # lane changes come from the server
	var i := overlay.selected_slot
	if i < 0 or sim.state.active[i] == 0:
		return false
	var ok := sim.request_lane_change(i, sim.state.lane[i] + dir)
	if ok:
		overlay.note_request(i)
	return ok


## Runs the sim until a car within max_ahead_m ahead of the player has just started
## signaling (organic MOBIL, or a request when none comes), at most max_s. For snaps.
## Returns the slot or -1.
func run_until_signal(max_ahead_m: float, max_s: float) -> int:
	var st := sim.state
	for k in ceili(max_s * float(TICKS_PER_SECOND)):
		for i in st.capacity:
			if st.active[i] == 1 and st.lc_state[i] == TrafficState.LaneChange.SIGNALING \
					and st.lc_timer[i] > st.lc_duration[i] * 0.5 and st.s[i] - car.state.s > 0.0 \
					and st.s[i] - car.state.s < max_ahead_m:
				return i
		_tick()
		if k % TICKS_PER_SECOND == 0:
			_upkeep()
	var slot := request_nearby_lane_change(max_ahead_m)
	if slot >= 0:
		advance_ticks(floori(float(TICKS_PER_SECOND) * 0.5))
	return slot


func set_driver(d: Driver) -> void:
	driver = d
	if driver == Driver.MANUAL:
		car.controller = _player_ctl
	else:
		if bot == null:
			bot = SandboxBot.new(road, sim.state, car.params, traffic_seed)
			bot.length_m = car.car.length_m
			bot.width_m = car.car.width_m
			bot.v_target = Units.kmh_to_mps(START_SPEED_KMH)
		bot.mode = SandboxBot.Mode.WEAVE if driver == Driver.BOT_WEAVE else SandboxBot.Mode.KEEP
		bot.traffic = sim.state
		car.controller = bot
		bot.on_attached(car.state)
	if _controls_overlay != null:
		_controls_overlay.visible = driver == Driver.MANUAL
	_refresh_buttons()


func reset_car() -> void:
	var st := car.state
	var lanes := road.lane_count(st.s)
	var lane := clampi(road.lane_index_at(st.d, st.s), 0, lanes - 1)
	car.place_at(st.s, road.lane_center_d(lane, st.s), maxf(st.v, 0.0))
	if bot != null:
		bot.on_attached(car.state)
	rig.snap_to_target()


## Moves the car to `s` (its lane and speed kept), refills traffic around it and builds
## the road there at once (set-piece snaps, WP6.3).
func teleport(s: float) -> void:
	road.ensure_generated_to(s + _view_ahead(0.0))
	car.state.s = s
	reset_car()
	var smp := road.sample(s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	director.reset(car.state)
	_builder.build_all_now(s)
	_next_forget_s = s


func _spawn_car() -> void:
	var car_def: CarDef = load(CAR_PATH)
	car = (load(PLAYER_CAR_SCENE) as PackedScene).instantiate()
	car.name = "PlayerCar"
	car.self_tick = false
	add_child(car)
	car.setup(_ctx, road, origin, car_def)
	car.place_at(start_s, road.lane_center_d(START_LANE, start_s), Units.kmh_to_mps(START_SPEED_KMH))
	rig.set_target(car, car.state, car.params.top_speed_mps)
	rig.snap_to_target()


func _view_ahead(s: float) -> float:
	return s + _builder.view_distance_m() + tuning.road.chunk_length_m * 2.0


func _on_tapped(pos: Vector2) -> void:
	overlay.select_at(pos)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_SPACE:
			toggle_pause()
		KEY_PERIOD:
			step_ticks(1)
		KEY_N:
			step_ticks(TICKS_PER_SECOND)
		KEY_BRACKETLEFT:
			_scale_step(-1)
		KEY_BRACKETRIGHT:
			_scale_step(1)
		KEY_V:
			_cycle_cam()
		KEY_B:
			set_driver(((driver + 1) % DRIVER_NAMES.size()) as Driver)
		KEY_X:
			clear_traffic()
		KEY_1:
			overlay.show_idm = not overlay.show_idm
		KEY_2:
			overlay.show_mobil = not overlay.show_mobil
		KEY_3:
			overlay.show_blink = not overlay.show_blink
		KEY_4:
			overlay.show_occupancy = not overlay.show_occupancy
		KEY_5:
			overlay.show_passability = not overlay.show_passability
		_:
			return
	_refresh_buttons()
	get_viewport().set_input_as_handled()


func toggle_pause() -> void:
	paused = not paused
	_pending_steps = 0
	_refresh_buttons()


func _scale_step(dir: int) -> void:
	var i := TIME_SCALES.find(time_scale)
	if i < 0:
		i = TIME_SCALES.find(1.0)
	time_scale = TIME_SCALES[clampi(i + dir, 0, TIME_SCALES.size() - 1)]
	_refresh_buttons()


func _cycle_cam() -> void:
	cam.cycle_mode()
	_refresh_buttons()


# ---------------------------------------------------------------- Stats

## Recomputes the stats panel and reports to DevStats (4 Hz from _process).
func refresh_stats() -> void:
	var st := sim.state
	var p := car.state
	var lanes := road.lane_count(p.s)
	_lane_sum.fill(0.0)
	_lane_n.fill(0)
	for i in st.capacity:
		if st.active[i] == 1 and st.lane[i] < _lane_sum.size():
			_lane_sum[st.lane[i]] += st.v[i]
			_lane_n[st.lane[i]] += 1
	var lane_txt := ""
	for l in lanes:
		var kmh := Units.mps_to_kmh(_lane_sum[l] / float(_lane_n[l])) if _lane_n[l] > 0 else 0.0
		lane_txt += "  L%d %s (%d)" % [l, "%.0f" % kmh if _lane_n[l] > 0 else "-", _lane_n[l]]
	var lc_min := lane_changes_per_min()
	var tick_avg := DevStats.get_sim_tick_avg_usec()
	var dens := tuning.director.density_per_km_lane(leg)
	var lines := PackedStringArray()
	lines.append("t %.1f s  x%s%s  seed %d  leg %d (%.1f veh/km/lane)" % [sim_time, _scale_text(),
		"  PAUSED" if paused else "", traffic_seed, leg, dens])
	lines.append("vehicles %d/%d  opposite %d  spawned %d+%d  despawned %d  hits %d" % [st.count,
		tuning.traffic.max_active_vehicles, director.opposite.state.count, director.spawned_ahead,
		director.spawned_behind, director.despawned, hits])
	lines.append("lane changes %.1f/min  signals %d  cancels P%d H%d U%d" % [lc_min, sim.stat_signals,
		sim.stat_cancel_player, sim.stat_cancel_hesitant, sim.stat_cancel_unsafe])
	lines.append("mean km/h" + lane_txt)
	lines.append("speeds " + DevReport.traffic_line(sim))
	lines.append("racers " + DevReport.racers_line(director))
	lines.append("sim tick %.0f us avg 1 s (max %d)  frame %.1f ms" % [tick_avg,
		DevStats.get_sim_tick_max_usec(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)])
	lines.append("player %.0f km/h  lane %d  %s" % [Units.mps_to_kmh(p.v), road.lane_index_at(p.d, p.s),
		DRIVER_NAMES[driver]])
	if is_network():
		lines.append(net_controls.stats_line())
		net_controls.report_dev_stats()
	var text := "\n".join(lines)
	if _stats_label != null and _stats_label.text != text:
		_stats_label.text = text
	DevStats.report(DevStats.VEHICLES, st.count)
	DevStats.report(&"sandbox_seed", traffic_seed)
	DevStats.report(&"sandbox_leg", leg)
	DevStats.report(&"sandbox_time_s", snappedf(sim_time, 0.1))
	DevStats.report(&"sandbox_time_scale", time_scale)
	DevStats.report(&"sandbox_opposite", director.opposite.state.count)
	DevStats.report(&"sandbox_lc_per_min", snappedf(lc_min, 0.1))
	DevStats.report(&"sandbox_signals", sim.stat_signals)
	DevStats.report(&"sandbox_cancels", "P%d H%d U%d" % [sim.stat_cancel_player, sim.stat_cancel_hesitant,
		sim.stat_cancel_unsafe])
	DevStats.report(&"sandbox_lane_kmh", lane_txt.strip_edges())
	DevStats.report(&"sandbox_tick_us", roundi(tick_avg))
	DevStats.report(&"sandbox_driver", DRIVER_NAMES[driver])
	DevStats.report(&"sandbox_player_kmh", roundi(Units.mps_to_kmh(p.v)))
	DevStats.report(&"sandbox_hits", hits)
	DevStats.report(&"racers_passed_you", director.racers_passed_player)
	DevStats.report(&"racers_overtaken", director.racers_overtaken)
	DevStats.report(&"racer_arrivals", director.racer_arrivals)


## Completed lane changes per minute over the last LC_WINDOW_S sim seconds (or since
## the last re-seed).
func lane_changes_per_min() -> float:
	if _lc_ring_n == 0:
		return 0.0
	var oldest := maxi(_lc_ring_n - 1 - LC_WINDOW_S, 0) % _lc_ring.size()
	var elapsed := sim_time - _lc_ring_t[oldest]
	if elapsed <= 0.0:
		return 0.0
	return float(sim.stat_completed - _lc_ring[oldest]) * Units.S_PER_MIN / elapsed


func _lc_sample() -> void:
	var k := _lc_ring_n % _lc_ring.size()
	_lc_ring[k] = sim.stat_completed
	_lc_ring_t[k] = sim_time
	_lc_ring_n += 1


func _scale_text() -> String:
	return ("%.2f" % time_scale).rstrip("0").rstrip(".")


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	_tabs_bar = DriveControls.new()
	_tabs_bar.name = "SandboxTabs"
	for tab: Tab in [Tab.TIME, Tab.SPAWN, Tab.DRIVE, Tab.VIEW, Tab.LAYERS]:
		_tab_buttons[tab] = _tabs_bar.add_button(DriveControls.Corner.TOP_RIGHT, 0, TAB_NAMES[tab], TAB_BUTTON,
			func() -> void: _open_tab(tab), true)
	_tabs_bar.add_button(DriveControls.Corner.TOP_RIGHT, 0, "HUD", TAB_BUTTON, Callable($DevHud, &"toggle"), true)
	add_child(_tabs_bar)
	var br := DriveControls.Corner.BOTTOM_RIGHT
	var p := _panel(Tab.TIME)
	_add(p, br, 0, &"pause", BUTTON, toggle_pause)
	_add(p, br, 0, &"step", BUTTON, func() -> void: step_ticks(1))
	_add(p, br, 0, &"step_s", BUTTON, func() -> void: step_ticks(TICKS_PER_SECOND))
	_add(p, br, 0, &"slower", BUTTON, func() -> void: _scale_step(-1))
	_add(p, br, 0, &"faster", BUTTON, func() -> void: _scale_step(1))
	p = _panel(Tab.SPAWN)
	_add(p, br, 1, &"leg", BUTTON, func() -> void: set_leg(leg % LEGS + 1))
	_add(p, br, 1, &"seed", BUTTON, func() -> void: reseed(traffic_seed + 1))
	_add(p, br, 1, &"clear", BUTTON, clear_traffic)
	_add(p, br, 1, &"fill", BUTTON, fill_traffic)
	_add(p, br, 1, &"auto", BUTTON, func() -> void:
		auto_spawn = not auto_spawn
		_refresh_buttons())
	_add(p, br, 1, &"opp", BUTTON, func() -> void:
		show_opposite = not show_opposite
		view.set(&"show_opposite", show_opposite)
		_refresh_buttons())
	_add(p, br, 0, &"profile", WIDE_BUTTON, func() -> void:
		spawn_profile = (spawn_profile + 1) % registry.profile_count()
		spawn_type_pick = 0
		_refresh_buttons())
	_add(p, br, 0, &"type", WIDE_BUTTON, func() -> void:
		spawn_type_pick += 1
		_refresh_buttons())
	_add(p, br, 0, &"lane", BUTTON, func() -> void:
		spawn_lane = (spawn_lane + 1) % maxi(road.lane_count(car.state.s), 1)
		_refresh_buttons())
	_add(p, br, 0, &"where", BUTTON, func() -> void:
		spawn_ahead = not spawn_ahead
		_refresh_buttons())
	_add(p, br, 0, &"spawn", BUTTON, func() -> void: spawn_vehicle(spawn_profile, spawn_type_pick, spawn_lane, spawn_ahead))
	p = _panel(Tab.DRIVE)
	_add(p, br, 0, &"driver", WIDE_BUTTON, func() -> void: set_driver(((driver + 1) % DRIVER_NAMES.size()) as Driver))
	_add(p, br, 0, &"bot_speed", BUTTON, _next_bot_speed)
	_add(p, br, 0, &"car_reset", BUTTON, reset_car)
	_add(p, br, 0, &"steer", BUTTON, _toggle_steering)
	_add(p, br, 0, &"throttle", BUTTON, _toggle_throttle)
	p = _panel(Tab.VIEW)
	_add(p, br, 0, &"cam", WIDE_BUTTON, _cycle_cam)
	_add(p, br, 0, &"rig", WIDE_BUTTON, func() -> void:
		rig.cycle_mode(true)   # dev: every mode, the hidden cockpit included (plan D11)
		_refresh_buttons())
	_add(p, br, 0, &"view_reset", BUTTON, func() -> void: cam.reset_view())
	_add(p, br, 0, &"labels", BUTTON, func() -> void:
		overlay.label_cap = LABEL_CAPS[(LABEL_CAPS.find(overlay.label_cap) + 1) % LABEL_CAPS.size()]
		_refresh_buttons())
	_add(p, br, 1, &"text", BUTTON, func() -> void:
		set_text_scale(TEXT_SCALES[(TEXT_SCALES.find(overlay.text_scale) + 1) % TEXT_SCALES.size()]))
	_add(p, br, 1, &"req_left", BUTTON, func() -> void: request_selected_lane_change(-1))
	_add(p, br, 1, &"req_right", BUTTON, func() -> void: request_selected_lane_change(1))
	p = _panel(Tab.LAYERS)
	_add(p, br, 0, &"idm", BUTTON, func() -> void:
		overlay.show_idm = not overlay.show_idm
		_refresh_buttons())
	_add(p, br, 0, &"mobil", BUTTON, func() -> void:
		overlay.show_mobil = not overlay.show_mobil
		_refresh_buttons())
	_add(p, br, 0, &"blink", BUTTON, func() -> void:
		overlay.show_blink = not overlay.show_blink
		_refresh_buttons())
	_add(p, br, 0, &"occ", BUTTON, func() -> void:
		overlay.show_occupancy = not overlay.show_occupancy
		_refresh_buttons())
	_add(p, br, 0, &"pass", BUTTON, func() -> void:
		overlay.show_passability = not overlay.show_passability
		_refresh_buttons())

	var stats := DriveControls.new()
	stats.name = "SandboxStats"
	add_child(stats)
	_stats_label = stats.add_label(DriveControls.Corner.TOP_LEFT, 0, STATS_WIDTH_PX)
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_stats_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_stats_label.add_theme_font_size_override(&"font_size", STATS_FONT_SIZE)
	var bg := StyleBoxFlat.new()
	bg.bg_color = DriveControls.PANEL
	bg.set_content_margin_all(8.0)
	bg.set_corner_radius_all(DriveControls.BEVEL_PX)
	bg.corner_detail = 1
	_stats_label.add_theme_stylebox_override(&"normal", bg)
	var first := _tab
	_tab = Tab.NONE
	_open_tab(first)
	set_text_scale(TEXT_SCALES[1] if DisplayServer.is_touchscreen_available() else TEXT_SCALES[0])
	refresh_stats()


## Overlay and stats text size (phones need the larger ones).
func set_text_scale(k: float) -> void:
	overlay.text_scale = k
	if _stats_label != null:
		_stats_label.add_theme_font_size_override(&"font_size", roundi(float(STATS_FONT_SIZE) * k))
		_stats_label.custom_minimum_size.x = STATS_WIDTH_PX * k
	_refresh_buttons()


func _panel(tab: Tab) -> DriveControls:
	var p := DriveControls.new()
	p.name = "Sandbox%s" % TAB_NAMES[tab].capitalize()
	add_child(p)
	_panels[tab] = p
	return p


func _add(p: DriveControls, corner: int, row: int, key: StringName, sz: Vector2, fn: Callable) -> void:
	_buttons[key] = p.add_button(corner, row, String(key).to_upper(), sz, fn, true)


func _open_tab(tab: Tab) -> void:
	_tab = Tab.NONE if tab == _tab and _panels.has(tab) and (_panels[tab] as DriveControls).visible else tab
	for t: Tab in _panels:
		(_panels[t] as DriveControls).visible = t == _tab
	_refresh_buttons()


func _refresh_buttons() -> void:
	if _buttons.is_empty():
		return
	for t: Tab in _tab_buttons:
		DriveControls.set_text(_tab_buttons[t], ("[%s]" if t == _tab else "%s") % TAB_NAMES[t])
	_set_text(&"pause", "PLAY" if paused else "PAUSE")
	_set_text(&"step", "STEP")
	_set_text(&"step_s", "+1 S")
	_set_text(&"slower", "x%s -" % _scale_text())
	_set_text(&"faster", "x%s +" % _scale_text())
	_set_text(&"leg", "LEG %d" % leg)
	_set_text(&"seed", "SEED %d" % traffic_seed)
	_set_text(&"clear", "CLEAR")
	_set_text(&"fill", "FILL")
	_set_text(&"auto", "AUTO %s" % ("ON" if auto_spawn else "OFF"))
	_set_text(&"opp", "OPP %s" % ("ON" if show_opposite else "OFF"))
	var types := registry.types_for_profile(spawn_profile)
	var type_name := String(registry.types[types[posmod(spawn_type_pick, types.size())]].id) if not types.is_empty() else "-"
	_set_text(&"profile", String(registry.profiles[spawn_profile].id).to_upper())
	_set_text(&"type", type_name.to_upper())
	_set_text(&"lane", "LANE %d" % spawn_lane)
	_set_text(&"where", "AHEAD" if spawn_ahead else "BEHIND")
	_set_text(&"spawn", "SPAWN")
	_set_text(&"driver", DRIVER_NAMES[driver])
	_set_text(&"bot_speed", "BOT %d" % roundi(Units.mps_to_kmh(bot.v_target)) if bot != null else "BOT -")
	_set_text(&"car_reset", "CAR RESET")
	_set_text(&"steer", "STEER %s" % String(hub.effective_steering).to_upper())
	_set_text(&"throttle", "THR %s" % String(Settings.get_value(&"throttle_mode")).to_upper())
	_set_text(&"cam", "CAM %s" % SandboxCamera.MODE_NAMES[cam.mode])
	_set_text(&"rig", "RIG %s" % String(rig.mode).to_upper())
	_set_text(&"view_reset", "RE-FRAME")
	_set_text(&"labels", "LABELS %d" % overlay.label_cap)
	_set_text(&"text", "TEXT x%s" % ("%.1f" % overlay.text_scale))
	_set_text(&"req_left", "SEL <")
	_set_text(&"req_right", "SEL >")
	_set_text(&"idm", _onoff("IDM", overlay.show_idm))
	_set_text(&"mobil", _onoff("MOBIL", overlay.show_mobil))
	_set_text(&"blink", _onoff("BLINK", overlay.show_blink))
	_set_text(&"occ", _onoff("OCC", overlay.show_occupancy))
	_set_text(&"pass", _onoff("PASS", overlay.show_passability))


func _set_text(key: StringName, text: String) -> void:
	if _buttons.has(key):
		DriveControls.set_text(_buttons[key], text)


static func _onoff(label: String, on: bool) -> String:
	return "%s %s" % [label, "ON" if on else "off"]


func _next_bot_speed() -> void:
	if bot == null:
		return
	var kmh := Units.mps_to_kmh(bot.v_target)
	var next := BOT_SPEEDS_KMH[0]
	for v in BOT_SPEEDS_KMH:
		if v > kmh + 1.0:
			next = v
			break
	bot.v_target = Units.kmh_to_mps(next)
	_refresh_buttons()


func _toggle_steering() -> void:
	var gyro: bool = Settings.get_value(&"steering_mode") != &"gyro"
	Settings.set_value(&"steering_mode", &"gyro" if gyro else &"drag")
	if gyro:
		hub.gyro.source.activate()
		hub.recalibrate_gyro()
	_refresh_buttons()


func _toggle_throttle() -> void:
	var manual: bool = Settings.get_value(&"throttle_mode") != &"manual"
	Settings.set_value(&"throttle_mode", &"manual" if manual else &"auto")
	_refresh_buttons()


## The display safe area in canvas pixels (notch, rounded corners), as DriveControls
## computes it.
func safe_rect() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	var safe := Rect2(Vector2.ZERO, vp)
	var screen_safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if screen_safe.size.x > 0 and win.x > 0 and DisplayServer.get_name() != "headless":
		var k := vp / Vector2(win)
		safe = Rect2(Vector2(screen_safe.position) * k, Vector2(screen_safe.size) * k).intersection(safe)
	return safe


## The sky_t slider moves to the bottom left (the tab buttons use the bottom right);
## the overlay's side panel keeps to the safe area too.
func _place_slider() -> void:
	var safe := safe_rect()
	overlay.safe_rect = safe
	var panel := get_node_or_null(^"SkyTSlider/Panel") as Control
	if panel == null:
		return
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.offset_left = safe.position.x + EDGE_PX
	panel.offset_right = safe.position.x + EDGE_PX + SLIDER_WIDTH_PX


# ---------------------------------------------------------------- Snaps

## Snap hook (tools/snap.sh). Options: cam=follow|top|free, rig=<CameraRig mode>,
## warm_s (sim seconds run before the capture), leg, seed, sky_t, driver=keep|weave|
## manual, speed_kmh (bot), zoom (TOP height / FREE distance, m), yaw_deg / pitch_deg
## (FREE), signal=true (ask a car ahead to change lanes, then run until it signals),
## select=true (select the nearest labeled car), labels, layers=idm,mobil,blink,occ,pass
## (the ones to show; default all but pass), text (overlay text scale), run=true (keep running; default: paused
## after the warm-up so the frame is exact); set_piece=<id> (+ piece_dist_m, piece_wait_s)
## and waves=true: SetPieceControls.snap_run; net=true (+ link=tcp|clean|udp, truth=false):
## network mode (NetTrafficControls.snap_run, N4.3).
func snap_setup(args: Dictionary) -> void:
	if args.has("sky_t"):
		sky.sky_t = float(args["sky_t"])
		sky.push_now()
	if args.has("leg"):
		leg = clampi(int(args["leg"]), 1, LEGS)
	if args.has("seed"):
		traffic_seed = int(args["seed"])
	var dname := String(args.get("driver", "weave"))
	set_driver(Driver.BOT_KEEP if dname == "keep" else (Driver.MANUAL if dname == "manual" else Driver.BOT_WEAVE))
	if bot != null and args.has("speed_kmh"):
		bot.v_target = Units.kmh_to_mps(float(args["speed_kmh"]))
	reseed(traffic_seed)
	net_controls.snap_run(args)   # net=true, link=tcp|clean|udp (N4.3)
	var warm := float(args.get("warm_s", 20.0))
	for k in ceili(warm * float(TICKS_PER_SECOND)):
		_tick()
		if k % TICKS_PER_SECOND == 0:
			_upkeep()
	_upkeep()
	if bool(args.get("signal", false)):
		var slot := run_until_signal(float(args.get("signal_range_m", 80.0)), float(args.get("signal_wait_s", 30.0)))
		print("snap: signaling car slot %d at %.0f m" % [slot, sim.state.s[slot] - car.state.s if slot >= 0 else NAN])
	set_piece_controls.snap_run(args)   # set_piece=<id>, piece_dist_m, waves=true (WP6.2)
	if args.has("layers"):
		var on := String(args["layers"]).split(",")
		overlay.show_idm = on.has("idm")
		overlay.show_mobil = on.has("mobil")
		overlay.show_blink = on.has("blink")
		overlay.show_occupancy = on.has("occ")
		overlay.show_passability = on.has("pass")
		if overlay.show_passability:
			refresh_passability()
	if args.has("labels"):
		overlay.label_cap = int(args["labels"])
	if args.has("text"):
		set_text_scale(float(args["text"]))
	var cm := String(args.get("cam", "follow"))
	cam.set_mode(SandboxCamera.Mode.TOP if cm == "top" else (SandboxCamera.Mode.FREE if cm == "free" else SandboxCamera.Mode.FOLLOW))
	if args.has("rig"):
		rig.set_mode(StringName(str(args["rig"])))
	if args.has("zoom"):
		cam.top_height_m = float(args["zoom"])
		cam.orbit_dist_m = float(args["zoom"])
	if args.has("yaw_deg"):
		cam.orbit_yaw = deg_to_rad(float(args["yaw_deg"]))
	if args.has("pitch_deg"):
		cam.orbit_pitch = deg_to_rad(float(args["pitch_deg"]))
	if args.has("tab"):
		var ti := TAB_NAMES.find(String(args["tab"]).to_upper())
		_tab = Tab.NONE
		_open_tab(maxi(ti, 0) as Tab)
	fast_controls.snap_run(args)   # racer=true, fast=K (WP6.6); arrival=true (WP6.7)
	paused = not bool(args.get("run", false))
	view.call(&"capture_tick")
	rig.snap_to_target()
	car.reset_physics_interpolation()
	overlay.camera = cam.current_camera()
	await get_tree().process_frame
	if bool(args.get("select", false)):
		overlay._pick_labels()
		if overlay._n_labels > 0:
			overlay.selected_slot = overlay._labels[0]
	_refresh_buttons()
	refresh_stats()
