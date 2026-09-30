class_name Run
extends Node3D
## One run of the game: the world stack, the player car, traffic, the pure sims and
## their event buffer, the flow COUNTDOWN -> RUNNING -> CRASH -> RESULTS -> retry.
## Spec: Core loop: Chase the Sun (sky timeline and sun clock, night, legs and
## checkpoints, the journey goal, modes, run end); Scoring; Lives, hits and crashes;
## Audio, haptics and game feel (slow motion); UI → Screens. Contracts: CONTRACTS.md
## §4 (per-tick order), §7 (event kinds and the adapter), §8, §13, §14. docs/RUN.md.
##
## Per 120 Hz tick (tick(), RUNNING), always with the fixed dt VehicleTuning.physics_dt():
##   1-2. car.tick(dt): controller.update + VehiclePhysics.step (the run ticks the car
##        itself, PlayerCar.self_tick off, so slow motion never changes the sim dt:
##        see TimeScale)
##   3.   traffic_sim.step (the player as participant), then the director
##   4.   lives.step, hit_detection.step, lives.on_contact (+ scoring.notify_hit,
##        leg_tracker.notify_hit, traffic_sim.notify_hit), scoring.set_ghost
##   5.   scoring.step; boost fill into the meter; sun nudges -> sun.lift, near misses
##        -> traffic_sim.notify_close_pass, threads / close passes -> leg tracker
##   6.   sun_clock.advance(dt, scoring.is_too_slow()); scoring.set_night; headlights
##   7.   leg objective (LegObjectives.step: brake, speed, slipstream, shoulder), leg
##        tracker (observe_multiplier, step); a crossing runs the spec's order: bank,
##        sun lift or dawn, leg bonuses (+ a "no X" objective), clean-leg life, then
##        set_night again, then the next leg's objective
## Every sim writes into one ScoreEventBuffer; RunEvents drains it once per frame.
## Slow motion, camera shake, the crash cue and screens react at frame rate.
##
## Loop test mode (N3.2, mode MODE_LOOP: `?mode=loop` on the web, `--mode=loop` or the
## dev LOOP button natively): the multiplayer loop instead of the procedural road, s
## unwrapped lap after lap, sectors as the legs, the room clock instead of the sun clock;
## forks, the finale, the leg objectives and Chase the Sun are off. See RunLoop.
##
## Title and attract (WP8.5, MENU; docs/RUN.md → Title and attract): the game boots into
## the title (the run is the tree's main scene, or `title_on_boot`; `?title=0` /
## `--title=0` or `?mode=` skip it). MENU builds the same world stack as a run (no second
## world) and drives the car with RunAttract's bot: traffic runs, but hit detection,
## lives, scoring, the sun clock and the legs are never stepped, so nothing can hit it.
## start_mode() (PLAY, DAILY DRIVE, LOOP PRACTICE) rebuilds for the run in the same
## frame; the pause menu's QUIT and the results' MENU call enter_menu().
##
## Rooms (N5.2, docs/ROOMS_CLIENT.md): start_room() drives loop mode in a room. RunRoom
## (`room`) holds the logic; the hooks here are the start placement (start_s_m and the
## car's d and speed), protection (contacts skipped), hit reports, the crash-out without a
## results screen, room_respawn / room_teleport for placements, and leave_room.

const PLAYER_CAR_SCENE := preload("res://src/vehicle/player_car.tscn")
const CAR_PATHS: Array[String] = [
	"res://data/cars/falcon_gt.tres",
	"res://data/cars/night_viper.tres",
	"res://data/cars/brute_v8.tres",
]
## WP4.3's HUD: installed only if the scene exists (built in parallel).
const HUD_SCENE_PATH := "res://src/ui/hud/hud.tscn"
## WP4.4's in-run screens: countdown (gyro calibration), pause menu, crash hint, results.
const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const DRIVE_SCENE := "res://src/dev/car_drive.tscn"
const SANDBOX_SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
## The journey bonus kind (paid on the crossing that reaches the coast).
const BONUS_JOURNEY := &"journey"
## Sims sharing the run's event buffer: traffic, lives, scoring, sun clock, legs, the
## traffic director (set pieces).
const EVENT_SOURCES := 6
## Headlight lookup over sky_t (built once from the color script).
const HEADLIGHT_LUT_SIZE := 1024
## Road memory is trimmed at most this often (m).
const FORGET_EVERY_M := 500.0
## Where --leg=N snaps start inside the leg (clear of the checkpoint's landmark).
const SNAP_LEG_S_M := 600.0   # lint: allow-number dev snap position, not tuning
## --at=lane_ends snaps stop this far before the sign.
const SNAP_AT_M := 150.0   # lint: allow-number dev snap position, not tuning
## --at=fork snaps stop this far before the next fork's split (the 1 km sign).
const SNAP_FORK_M := 1000.0   # lint: allow-number dev snap position, not tuning
## --at=finale snaps start this far before the finale point.
const SNAP_FINALE_M := 5.0   # lint: allow-number dev snap position, not tuning
## --set_piece snaps (WP6.3) search this many legs for a feature-triggered piece's feature.
const SNAP_FEATURE_LEGS := 8
## tools/snap.sh runs use this seed unless --seed is given.
const SNAP_SEED := 20260929
## After the physics car (tick) and before the camera rig (100).
const PHYSICS_PRIORITY := 50
## N3.2: the loop test mode (RunLoop).
const MODE_LOOP := &"loop"

## The first run's seed; 0 = a random seed at boot (Journey). Retries derive theirs
## from it and the run counter (Rng.derive_seed), so a test that sets it replays.
@export var run_seed: int = 0
@export var mode: StringName = RunContext.MODE_JOURNEY
@export var car_index: int = 0
## Off: the countdown waits for go(). On (the game), the run counts hud.countdown_from
## steps of hud.countdown_step_s (a retry: retry_countdown_step_s) and the countdown
## screen shows them and calibrates the gyro; the screen can hold it (hold_countdown).
@export var auto_countdown: bool = true
## Store the personal best in Save at run end.
@export var record_best: bool = true
## The Jolt crash cinematic (CrashSequence, WP4.2); off = the fallback skid to a stop.
@export var crash_cinematic: bool = true
## Tests: tick() and frame() are called by the test instead of the engine.
@export var manual_ticks: bool = false
## WP6.5: some checkpoints fork (ForkPlan from the seed). Off: the plain journey.
@export var forks_enabled: bool = true
## WP8.5: boot into the title (MENU) even when the run is not the main scene (tests).
@export var title_on_boot: bool = false

## StringName of Game.* (BOOT, COUNTDOWN, RUNNING, PAUSED, CRASH, RESULTS).
var state: StringName = &"boot"
var run_count: int = 0
var current_seed: int = 0
var tick_count: int = 0

var tuning: Tuning
var ctx: RunContext
## ProceduralRoadPath (the journey), or LoopRoadPath in loop mode (N3.2).
var road: RoadPath
## N3.2: the loop test mode's state (null outside loop mode).
var loop: RunLoop
## N5.2: the room this run drives in (loop mode), null outside rooms.
var room: RunRoom
var origin: FloatingOrigin
var biome_director: BiomeDirector
var builder: RoadBuilder
var roadside: Roadside
var landmarks: Landmarks
## WP6.4b's biome features (water, elevated stretches, fog cards), wired in WP6.4c.
var features: BiomeFeatures
## WP6.5: the forks (plan, candidates, choices) and the view of both branches.
var forks := RunForks.new()
var fork_view: ForkView
## WP6.5: the journey finale at the coast (breather, camera swing, journey complete).
var finale := RunFinale.new()
var sky: SkyRig
var hub: PlayerInput
var rig: CameraRig
var car: PlayerCar
var registry: TrafficRegistry
var sim: TrafficSim
var director: TrafficDirector
var traffic_view: TrafficView
## Set pieces (WP6.3): their props (signs, cones, barriers, the arrow board, the on-ramp,
## the toll legends), hits on the road works' props, and the light change in tunnels.
var set_piece_view: SetPieceView
var works_query: WorksPropQuery
var tunnel_light: TunnelLight
## Night lighting (WP5.4): the player's headlights, traffic cones, street-lamp pools.
var headlights: PlayerHeadlights
var headlight_cones: HeadlightCones
var lamp_pools: StreetLampPools
var scoring: Scoring
var sun: SunClock
var legs: LegTracker
## The leg objective (WP5.2): chosen at each leg start, judged per tick, paid once.
var objectives: LegObjectives
var hits: HitDetection
var lives: Lives
var stats := RunStats.new()
var events: ScoreEventBuffer
var feed := HudFeed.new()
var adapter: RunEvents
var time_scale: TimeScale
var fx: PlayerFx
## WP4.4's RunScreens (countdown, pause, crash hint, results): intents in, flow calls out.
var screens: RunScreens
## WP4.3's Hud (null until src/ui/hud/hud.tscn exists).
var hud: Node
var dev: RunDevPanel
## WP8.5: the title and the online hub (intents in: start_mode), and the attract drive.
var title: TitleScreens
var attract := RunAttract.new()
## The Events.run_over payload of the last finished run.
var last_results: Dictionary = {}
## The controller while driving (PlayerController on the input hub by default;
## tests put a scripted bot here). Swapped for the braking one during the crash.
var drive_controller: VehicleController:
	set(value):
		drive_controller = value
		if car != null and state != Game.CRASH and state != Game.MENU:
			car.controller = value
## Dev: lives never run out (LIVES INF).
var infinite_lives: bool = false
## Dev: 0 = the director follows the leg tracker, else this leg.
var leg_override: int = 0
## WP4.2's CrashSequence (null = the fallback crash below). See _start_crash_sequence().
var crash_sequence: Node

var _dt: float
var _base_seed: int = 0
var _params_cache: Dictionary = {}
var _contact := HitDetection.Contact.new()
var _forced := HitDetection.Contact.new()
var _force_pending: bool = false
var _crash_controller := CrashController.new()
var _countdown_ticks: int = 0
var _countdown_step_ticks: int = 1
var _countdown_shown: int = -1
var _countdown_held: bool = false
var _crash_left_s: float = 0.0
var _crash_by_sequence: bool = false
var _pending_first_hit_fx: bool = false
var _pending_crash_fx: bool = false
var _paused_from: StringName = &""
var _headlight_lut := PackedByteArray()
var _headlights: bool = false
var _director_leg: int = 1
var _next_forget_s: float = 0.0
var _resets: int = 0
var _best_before: int = 0
var _pending_journey_save: bool = false
var _legs_for_loop: bool = false
# WP8.5: the Journey's base seed (Daily Drive swaps _base_seed for the day's), the MENU
# world build in progress, titles shown, and a full countdown for a run from the title.
var _journey_seed: int = 0
var _menu_build: bool = false
var _menu_count: int = 0
var _full_countdown: bool = false
var _dev_hud_stepped_aside: bool = false
var _dev_hud_was_visible: bool = false


## Full brake, wheel straight: the fallback crash (the car skids to a stop).
class CrashController:
	extends VehicleController

	func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
		out_input.steer = 0.0
		out_input.throttle = 0.0
		out_input.brake = 1.0
		out_input.boost = false


func _ready() -> void:
	# Web: `?scene=drive` opens the M3 drive scene, `?scene=sandbox` the traffic
	# sandbox (browsers can't pass scene paths on the command line).
	if OS.has_feature("web"):
		var target := _url_scene()
		if target == "drive" or target == "sandbox":
			set_physics_process(false)
			set_process(false)
			get_tree().change_scene_to_file.call_deferred(DRIVE_SCENE if target == "drive" else SANDBOX_SCENE)
			return
	# N3.2: `?mode=loop` (web) or `--mode=loop` (native) opens the loop test mode.
	var boot_mode := boot_param("mode")
	if boot_mode == String(MODE_LOOP) or boot_mode == String(RunContext.MODE_DAILY) \
			or boot_mode == String(RunContext.MODE_JOURNEY):
		mode = StringName(boot_mode)
	process_physics_priority = PHYSICS_PRIORITY
	tuning = Tuning.load_default()
	_dt = tuning.vehicle.physics_dt()
	events = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity * EVENT_SOURCES)
	_base_seed = run_seed if run_seed != 0 else Rng.random_seed()
	_journey_seed = _base_seed
	if mode == RunContext.MODE_DAILY:
		_base_seed = daily_seed_today()

	sky = $Sky
	hub = $PlayerInput
	rig = $CameraRig
	time_scale = $TimeScale
	adapter = $RunEvents
	hub.camera_cycle_requested.connect(rig.cycle_mode)
	hub.pause_requested.connect(toggle_pause)

	origin = FloatingOrigin.new()
	origin.name = "FloatingOrigin"
	add_child(origin)
	biome_director = BiomeDirector.new()
	biome_director.name = "BiomeDirector"
	add_child(biome_director)
	builder = RoadBuilder.new()
	builder.name = "RoadBuilder"
	builder.biome_director = biome_director
	add_child(builder)
	fork_view = ForkView.new()
	fork_view.name = "ForkView"
	add_child(fork_view)
	# The forks give the road its route plan (RunForks.setup); the director keeps the look.
	biome_director.apply_to_road = false
	roadside = Roadside.new()
	roadside.name = "Roadside"
	roadside.biome_director = biome_director
	add_child(roadside)
	landmarks = Landmarks.new()
	landmarks.name = "Landmarks"
	landmarks.biome_director = biome_director
	add_child(landmarks)
	features = BiomeFeatures.new()
	features.name = "BiomeFeatures"
	features.biome_director = biome_director
	add_child(features)
	# The road mesher lowers its ground under viaducts and the sea slope; the water
	# feeds the horizon's sea mask. Both hooks go through the nodes (valid on retry).
	features.bind(builder, sky)
	traffic_view = TrafficView.new()
	traffic_view.name = "TrafficView"
	traffic_view.headlight_pools = false   # HeadlightCones draws them
	# Each new car wears the palette of the biome where it appears (WP6.4c).
	traffic_view.biome_director = biome_director
	add_child(traffic_view)
	set_piece_view = SetPieceView.new()
	set_piece_view.name = "SetPieceView"
	add_child(set_piece_view)
	_add_night_lights()
	registry = TrafficRegistry.load_default(tuning.traffic)
	scoring = Scoring.new()
	sun = SunClock.new(tuning.sun, tuning.legs)
	legs = LegTracker.new(tuning.legs)
	objectives = LegObjectives.new(tuning.legs)
	hits = HitDetection.new(tuning.lives, tuning.traffic.max_active_vehicles)
	lives = Lives.new(tuning.lives)
	fx = PlayerFx.new()
	fx.name = "PlayerFx"
	add_child(fx)
	_install_screens()
	_install_title()
	_build_headlight_lut()
	_install_hud()
	dev = RunDevPanel.new()
	dev.name = "RunDev"
	add_child(dev)
	if crash_cinematic:
		var cs := CrashSequence.new()
		cs.name = "CrashSequence"
		cs.tap_to_skip = false   # the run owns the tap (skip())
		cs.auto_advance = false  # advanced from frame() with the real frame time
		add_child(cs)
		crash_sequence = cs
	GameAudio.attach(self)   # WP7A: audio listens to Events and reads the run (the Audio autoload if present)

	if wants_title():
		enter_menu()
	else:
		_start_run()
	dev.setup(self)
	_sync_hud()
	if manual_ticks:
		set_physics_process(false)
		set_process(false)
	elif is_loop() and OS.has_feature("web"):
		_apply_url_dev_args()


func _exit_tree() -> void:
	if get_tree() != null and get_tree().paused and state == Game.PAUSED:
		get_tree().paused = false
	if room != null:
		room.session.leave()


# ---------------------------------------------------------------- Flow API

## Start (or restart) a run: new seed, world rebuilt around s = 0, sims reset, COUNTDOWN.
## Retry takes this path; no scene reload (the world nodes re-run their setup()).
func retry() -> void:
	if state == Game.PAUSED:
		get_tree().paused = false
	if crash_sequence != null and crash_sequence.has_method(&"reset"):
		crash_sequence.call(&"reset")
	_start_run()


# ---------------------------------------------------------------- Title (WP8.5)

## Boot into the title: the run is the main scene (the game) or `title_on_boot`, and
## neither `?title=0` / `--title=0` nor a `?mode=` jump says otherwise.
func wants_title() -> bool:
	if boot_param("title") == "0" or not boot_param("mode").is_empty():
		return false
	return title_on_boot or (is_inside_tree() and get_tree().current_scene == self)


## The title (MENU): the world stack is rebuilt around a fresh Journey road and the car
## drives itself (RunAttract) with hit detection off; the title opens over it. The pause
## menu's QUIT, the results' MENU and the boot call this.
func enter_menu() -> void:
	if room != null:
		room.leave()   # N5.2: out of the room first; leave_room() comes back here
		return
	if state == Game.PAUSED:
		get_tree().paused = false
	if crash_sequence != null and crash_sequence.has_method(&"reset"):
		crash_sequence.call(&"reset")
	mode = RunContext.MODE_JOURNEY
	_base_seed = _journey_seed
	_menu_build = true
	_start_run()
	_menu_build = false


## PLAY (Journey), DAILY DRIVE (today's UTC date seed) and LOOP PRACTICE: a run of
## `run_mode` from a full countdown, in the same frame (no scene load). RETRY keeps it.
func start_mode(run_mode: StringName) -> void:
	mode = run_mode
	_base_seed = daily_seed_today() if run_mode == RunContext.MODE_DAILY else _journey_seed
	_full_countdown = true
	retry()


## N5.2: drive in the room `room_session` has joined (the online hub's joins): loop mode,
## started at the room's placement (RunRoom).
func start_room(room_session: NetRoomSession) -> void:
	if room != null:
		room.uninstall()
	mode = MODE_LOOP
	room = RunRoom.new(self, room_session)
	_full_countdown = true
	retry()


## N5.2: a respawn placement (after a crash-out): a fresh run where the room placed us.
func room_respawn() -> void:
	retry()


## N5.2: a rejoin or reconnect placement: the car moves, the run goes on.
func room_teleport(s: float, d: float, v_mps: float) -> void:
	dev_teleport(s, v_mps)
	legs.skip_to(s)
	car.place_at(s, d, v_mps)
	hits.reset(car.state, sim.state)
	rig.snap_to_target()


## N5.2: out of the room (left, kicked, closed, the seat lost): back to the online hub
## with `message` ("" after the player's own leave).
func leave_room(message: String) -> void:
	if room == null:
		return
	var r := room
	room = null
	r.uninstall()
	enter_menu()
	title.open_hub()
	title.online_hub.show_room_message(message)


## The pause menu's RETRY: in a room, REJOIN CREW (a run restart would leave the room's
## timeline).
func _on_screen_retry() -> void:
	if room != null:
		resume()
		room.request_rejoin()
		return
	retry()


## True on the title.
func is_menu() -> bool:
	return state == Game.MENU


## The Daily Drive's seed for today's UTC date (identical for everyone that day).
static func daily_seed_today() -> int:
	var d := Time.get_date_dict_from_system(true)
	return Rng.daily_seed(int(d["year"]), int(d["month"]), int(d["day"]))


## MENU: the attract drive. The car (its bot) and traffic as in RUNNING, the forks (the
## road holds at an unresolved split); never hit detection, lives, scoring, the sun or the
## legs. Allocation-free except where RUNNING allocates (the director, the road).
func _attract_tick(dt: float) -> void:
	var st := car.state
	if loop == null:
		forks.tick(st)
	car.tick(dt)
	sim.step(dt, st, car.params, events)
	director.step(dt, st)
	if loop == null:
		forks.guard_traffic()
	traffic_view.capture_tick()
	_safety_net()
	attract.tick(dt)


func _install_title() -> void:
	title = TitleScreens.new()
	title.name = "TitleScreens"
	add_child(title)
	title.bind(hub)
	title.start.connect(start_mode)


## Ends the countdown now (WP4.4's countdown screen calls this when auto_countdown is off).
func go() -> void:
	if state != Game.COUNTDOWN:
		return
	_enter(Game.RUNNING)
	_countdown_ticks = 0
	Events.countdown_tick.emit(0)


## The countdown screen holds the countdown (web + gyro: until the tap that grants the
## motion permission) and lets it run again.
func hold_countdown(on: bool) -> void:
	_countdown_held = on


func pause() -> void:
	if state != Game.COUNTDOWN and state != Game.RUNNING:
		return
	_paused_from = state
	state = Game.PAUSED
	Game.pause()
	get_tree().paused = true
	_sync_hud()


func resume() -> void:
	if state != Game.PAUSED:
		return
	get_tree().paused = false
	state = _paused_from
	Game.resume()
	_sync_hud()


func toggle_pause() -> void:
	if state == Game.PAUSED:
		resume()
	else:
		pause()


func is_paused() -> bool:
	return state == Game.PAUSED


## Tap during the crash: straight to the results.
func skip() -> void:
	if state != Game.CRASH:
		return
	if _crash_by_sequence and crash_sequence != null and crash_sequence.has_method(&"skip"):
		crash_sequence.call(&"skip")   # its `finished` ends the crash
		return
	_end_crash()


## Tests and tools: a contact at the next tick's collision step (tick order kept).
func force_hit(source: StringName = HitDetection.HIT_BARRIER, slot: int = -1, away_side: int = -1) -> void:
	_forced.clear()
	_forced.hit = true
	_forced.source = source
	_forced.slot = slot
	_forced.vehicle_id = sim.state.vehicle_id[slot] if slot >= 0 else -1
	_forced.s = car.state.s
	_forced.d = car.state.d
	_forced.away_side = away_side
	_forced.side = -away_side
	_force_pending = true


## Director leg: 0 follows the leg tracker (dev LEG button; loop mode: the loop's leg).
func set_leg_override(leg: int) -> void:
	leg_override = maxi(leg, 0)
	_director_leg = leg_override if leg_override > 0 else _auto_director_leg()
	director.set_leg(_director_leg, car.state.s)


## The dev DENS knob: the director's density scale (loop mode: times the loop's own).
func set_dev_density_scale(x: float) -> void:
	if loop != null:
		if loop.dev_density_scale == x and director.density_scale == loop.density_scale(loop.section):
			return
		loop.dev_density_scale = x
		director.set_density_scale(loop.density_scale(loop.section))
	elif director.density_scale != x:
		director.set_density_scale(x)


## True in the loop test mode (N3.2).
func is_loop() -> bool:
	return mode == MODE_LOOP


## Dev LOOP button: switches between the journey and the loop test mode (a new run).
func dev_toggle_loop() -> void:
	mode = RunContext.MODE_JOURNEY if is_loop() else MODE_LOOP
	retry()


# ---------------------------------------------------------------- Engine callbacks

func _physics_process(_delta: float) -> void:
	tick()


func _process(delta: float) -> void:
	frame(delta / Engine.time_scale)


func _unhandled_input(event: InputEvent) -> void:
	if state != Game.CRASH:
		return
	var tap := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
		or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventKey and (event as InputEventKey).pressed)
	if tap:
		skip()


# ---------------------------------------------------------------- Tick (120 Hz)

## One fixed tick. Allocation-free except when the road generator or the director
## plans ahead (director rate).
func tick() -> void:
	var dt := _dt
	_road_ahead()
	match state:
		Game.COUNTDOWN:
			_countdown_tick()
		Game.RUNNING:
			car.tick(dt)
			_sim_tick(dt)
		Game.CRASH:
			if not _crash_by_sequence:
				car.tick(dt)   # the fallback skid; the cinematic's body carries the car
			_crash_tick(dt)
		Game.MENU:
			_attract_tick(dt)
	tick_count += 1
	var smp := car.road_sample()
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)


func _countdown_tick() -> void:
	if not auto_countdown or _countdown_held:
		return
	_countdown_ticks -= 1
	if _countdown_ticks <= 0:
		go()
		return
	var remaining := ceili(float(_countdown_ticks) / float(_countdown_step_ticks))
	if remaining != _countdown_shown:
		_countdown_shown = remaining
		Events.countdown_tick.emit(remaining)


func _sim_tick(dt: float) -> void:
	var st := car.state
	var from := events.size()
	# The fork at the split (WP6.5): may swap the road's branch and move the car's d.
	if loop == null:
		forks.tick(st)
	# 3. traffic, the player as participant, then the director.
	sim.step(dt, st, car.params, events)
	director.step(dt, st)
	if loop == null:
		forks.guard_traffic()
		finale.tick(dt, st)
	traffic_view.capture_tick()
	# 4. collisions and hits.
	lives.step(dt, st, events)
	var contact := hits.step(dt, st, sim.state, road, _contact)
	if _force_pending:
		_force_pending = false
		_contact.copy_from(_forced)
		contact = true
	if room != null:
		room.tick(dt)
		if room.is_protected():
			contact = false   # N5.2: spawn / rejoin protection
	if contact:
		match lives.on_contact(_contact, st, events):
			Lives.Outcome.FIRST_HIT:
				_count_hit()
				_pending_first_hit_fx = true
				if room != null:
					room.on_hit(_contact, lives.lives)
			Lives.Outcome.RUN_OVER:
				if infinite_lives:
					_count_hit()
					lives.reset()
					lives.apply_hit_response(st, _contact.away_side)
				else:
					_begin_crash()
					stats.consume(events, from, events.size())
					return
	if infinite_lives and not lives.is_ghost() and lives.lives < lives.max_lives:
		lives.lives = lives.max_lives
	scoring.set_ghost(lives.is_ghost())
	# 5. scoring, boost fill, forwarded kinds.
	var score_from := events.size()
	scoring.step(dt, st, sim.state, road, events)
	st.boost_meter = minf(1.0, st.boost_meter + scoring.take_boost_fill())
	_forward_scoring(score_from, events.size())
	# 6. the sun clock (loop mode: the room clock and the section).
	if loop != null:
		_loop_clock_tick(dt, st.s)
	else:
		sun.advance(dt, scoring.is_too_slow(), events)
	scoring.set_night(sun.is_night())
	_update_headlights()
	# 7. the leg objective, legs and checkpoints (loop mode: sectors, no objective).
	if loop == null and objectives.step(dt, car.input.brake, st.v, scoring.is_slipstreaming(), scoring.is_on_shoulder()):
		legs.complete_objective(_pay_objective())
	legs.observe_multiplier(dt, scoring.multiplier())
	if legs.step(dt, st.s, sun.is_night(), events):
		_dispatch_crossing()
	if loop == null and leg_override <= 0 and legs.leg_index != _director_leg:
		_director_leg = legs.leg_index
		director.set_leg(_director_leg, st.s)
		director.set_biome(biome_director.biome_at(st.s))
	stats.observe_tick(dt, st.v, st.s, sun.is_night(), scoring.multiplier())
	stats.consume(events, from, events.size())
	_safety_net()


## A counted hit: the chain, the leg's clean flag and the hit car's reaction.
func _count_hit() -> void:
	scoring.notify_hit(events)
	legs.notify_hit()
	if _contact.source == HitDetection.HIT_TRAFFIC and _contact.slot >= 0:
		sim.notify_hit(_contact.slot)


func _forward_scoring(from: int, to: int) -> void:
	for i in range(from, to):
		var k := events.kind[i]
		if k == ScoringRuleSet.KIND_SUN_NUDGE:
			if loop == null:   # loop mode: no sun meter
				sun.lift(events.value[i], events)
		elif k == Scoring.KIND_NEAR_MISS:
			sim.notify_close_pass(events.slot[i])
		elif k == ScoreEvents.THREAD:
			legs.notify_thread()
			_objective_scored(k)
		elif k == ScoreEvents.CLOSE_PASS:
			legs.notify_close_pass()
			_objective_scored(k)
		elif k == ScoreEvents.CUT:
			_objective_scored(k)


## A scored kind the objective counts; a completion is paid at once.
func _objective_scored(kind: StringName) -> void:
	if loop == null and objectives.notify_scored(kind):
		legs.complete_objective(_pay_objective())


## The objective bonus, straight into the banked total (x2 at night), and
## objective_completed with the points actually paid. Called exactly once per completed
## objective: LegObjectives reports each completion once. Returns the points.
func _pay_objective() -> int:
	var before := scoring.banked()
	scoring.award_bonus(LegTracker.BONUS_OBJECTIVE, tuning.legs.objective_bonus_points, events)
	var paid := scoring.banked() - before
	events.push(LegObjectives.KIND_OBJECTIVE_COMPLETED, paid, 0.0, -1.0, -1, 0.0, objectives.current())
	return paid


## The leg's objective, drawn at its start (LegObjectives, seeded) and set on the tracker.
func _start_leg_objective() -> void:
	legs.set_objective(objectives.start_leg(legs.leg_index))


## The spec's crossing sequence (Legs and checkpoints, steps 1-4; 5 is the HUD toast).
## Loop mode (a sector gantry, "Sectors replace checkpoints"): bank, the sector bonuses,
## a clean sector's life; no sun lift or dawn, no objective, no journey.
func _dispatch_crossing() -> void:
	var c := legs.crossing
	scoring.notify_checkpoint(events)
	if loop != null:
		for i in c.bonus_count():
			scoring.award_bonus(c.bonus_kind(i), c.bonus_base_points(i, tuning.legs), events)
		if c.clean:
			lives.restore_life(events)
		scoring.set_night(sun.is_night())
		return
	sun.on_checkpoint(c.avg_speed_mps, events)
	for i in c.bonus_count():
		scoring.award_bonus(c.bonus_kind(i), c.bonus_base_points(i, tuning.legs), events)
	# A "no X" objective is judged at the line and paid with the leg bonuses; the others
	# were paid when completed (c.objective_done, c.objective_points), never again here.
	if objectives.finish_leg():
		legs.complete_crossing_objective(_pay_objective())
	if c.coast:
		scoring.award_bonus(BONUS_JOURNEY, tuning.legs.journey_bonus_points, events)
		finale.arm(c.s)
	if c.clean:
		lives.restore_life(events)
	# After the bonuses: a leg finished at night pays x2, then the dawn clears the night.
	scoring.set_night(sun.is_night())
	_update_headlights()
	# The new leg's objective (leg_started is already in the buffer; the adapter reads
	# the objective when it drains).
	_start_leg_objective()


func _update_headlights() -> void:
	var i := clampi(int(sun.sky_t * float(HEADLIGHT_LUT_SIZE)), 0, HEADLIGHT_LUT_SIZE - 1)
	var on := _headlight_lut[i] != 0
	if on != _headlights:
		_headlights = on
		sim.set_headlights(on)
		director.set_night(on)


## Crash (fallback): traffic keeps moving and brakes, the car skids; no hits, no score.
func _crash_tick(dt: float) -> void:
	var st := car.state
	sim.step(dt, st, car.params, events)
	director.step(dt, st)
	if loop == null:
		forks.guard_traffic()
	traffic_view.capture_tick()
	_safety_net()


## Leaving the carriageway (possible only through a barrier during the ghost, when
## contacts are ignored) puts the car back in a lane at half speed.
func _safety_net() -> void:
	var st := car.state
	if st.d < road.median_barrier_d(st.s) or st.d > road.guardrail_d(st.s):
		dev_reset_car()


func _road_ahead() -> void:
	var s := car.state.s
	road.ensure_generated_to(_view_ahead(s))
	legs.plan_ahead(road, _plan_ahead_to(s))
	if s >= _next_forget_s:
		road.forget_before(s - reach_behind_m() - tuning.road.chunk_length_m)
		if loop == null:
			forks.forget_before(s - reach_behind_m() - tuning.road.chunk_length_m)
		_next_forget_s = s + FORGET_EVERY_M


## How far behind the car the world nodes sample the road (the roadside's cells, the
## features' windows and the sea level's smoothing).
func reach_behind_m() -> float:
	return maxf(roadside.reach_behind_m(), features.reach_behind_m())


# ---------------------------------------------------------------- Crash and results

func _begin_crash() -> void:
	_count_hit()
	if room != null:
		room.on_crash(_contact)
	scoring.notify_run_end(events)
	_brake_surrounding_traffic()
	car.controller = _crash_controller
	_enter(Game.CRASH)
	_crash_left_s = tuning.feel.slowmo_crash_s
	_pending_crash_fx = true
	_crash_by_sequence = _start_crash_sequence()


## ---- ORCHESTRATOR SEAM: WP4.2 CrashSequence (docs/CONTRACTS.md §14) ----
## Replace the body with the hand-off, e.g.
##     crash_sequence.start(car, _contact, sim, traffic_view)   # WP4.2's signature
##     crash_sequence.finished.connect(_end_crash, CONNECT_ONE_SHOT)
##     return true
## (CrashSequence requests its own slow motion; drop the fallback's request in frame()
## then.) Returning false keeps the fallback: the car brakes to a stop, surrounding
## traffic brakes, and the results come after feel.slowmo_crash_s real seconds or a tap.
func _start_crash_sequence() -> bool:
	var cs := crash_sequence as CrashSequence
	if cs == null:
		return false
	cs.start(car, _contact, sim.state, traffic_view, road, origin, rig)
	if not cs.is_running():
		return false
	cs.finished.connect(func(_skipped: bool) -> void: _end_crash(), CONNECT_ONE_SHOT)
	return true


## Surrounding traffic brakes (TrafficSim.notify_hit: hard brake, hazards, a small
## swerve away from the player) within lives.crash_brake_radius_m. Crash only;
## allocation-free.
func _brake_surrounding_traffic() -> void:
	var ts := sim.state
	var ps := car.state.s
	var radius := tuning.lives.crash_brake_radius_m
	for i in ts.capacity:
		if ts.active[i] != 0 and absf(ts.s[i] - ps) <= radius:
			sim.notify_hit(i)


func _end_crash() -> void:
	if state != Game.CRASH:
		return
	if not _crash_by_sequence:
		Events.crash_finished.emit()   # CrashSequence emits its own
	_crash_by_sequence = false
	time_scale.restore()
	_show_results()


func _show_results() -> void:
	if room != null:
		# N5.2: no results screen in a room; the room HUD shows the server's run_result and
		# the respawn placement starts the next run (RunRoom).
		_enter(Game.RESULTS)
		return
	_enter(Game.RESULTS)
	var score := scoring.banked()
	last_results = stats.results(score, current_seed, mode)
	var best := _best_before
	var new_best := score > best
	if record_best:
		Save.submit_best_score(mode, score)
	last_results[&"personal_best"] = maxi(best, score)
	last_results[&"new_best"] = new_best
	last_results[&"previous_best"] = best
	last_results[&"car"] = String(car.car.id) if car != null and car.car != null else ""   # N7.2 run submission
	Events.run_over.emit(last_results)   # the results screen opens on it


# ---------------------------------------------------------------- Frame

## Once per rendered frame with the real (unscaled) frame time: drains the events,
## plays the frame-rate reactions, updates the views, the sky and the HUD feed.
func frame(real_dt: float) -> void:
	if room != null:
		room.frame(real_dt)
	if state == Game.CRASH and _crash_by_sequence:
		(crash_sequence as CrashSequence).advance(real_dt)
	if state == Game.CRASH and not _crash_by_sequence:
		_crash_left_s -= real_dt
		if _crash_left_s <= 0.0:
			_end_crash()
	adapter.drain()
	if _pending_journey_save:
		_pending_journey_save = false
		if record_best:
			Save.record_journey(mode, stats.journey_time_s, stats.journey_distance_m)
	var feel := tuning.feel
	if _pending_first_hit_fx:
		_pending_first_hit_fx = false
		# The camera shakes on Events.hit (CameraRig listens); slow motion is asked here.
		Events.slowmo_requested.emit(feel.slowmo_first_hit_scale, feel.slowmo_first_hit_s, TimeScale.REASON_FIRST_HIT)
	if _pending_crash_fx:
		_pending_crash_fx = false
		if not _crash_by_sequence:
			Events.crash_started.emit()   # CrashSequence emits its own
			Events.slowmo_requested.emit(feel.slowmo_crash_scale, feel.slowmo_crash_s, TimeScale.REASON_CRASH)
	var s := car.state.s
	sky.sky_t = sun.sky_t
	biome_director.update_view(s)
	builder.update_view(s)
	fork_view.update_view(s)
	roadside.update_view(s)
	landmarks.update_view(s)
	features.update_view(s)
	set_piece_view.update_view(s)
	var tl := tunnel_light.def
	sky.set_tunnel_light(tunnel_light.factor_at(s), tl.tunnel_dark_frac, tl.tunnel_lamp_on)
	sky.update_view(s)
	traffic_view.update_view(s)
	_update_night_lights(s)
	_fill_feed()
	_report_dev_stats()


func _fill_feed() -> void:
	var st := car.state
	feed.speed_mps = st.v
	feed.min_speed_mps = tuning.scoring.min_speed_mps()
	feed.top_speed_mps = car.params.top_speed_mps
	feed.too_slow = scoring.is_too_slow()
	feed.boost_fill = st.boost_meter
	feed.boosting = st.boost_active
	feed.sun_height = sun.sun_height()
	feed.night = sun.is_night()
	feed.dawning = sun.is_dawning()
	var cp := legs.distance_to_checkpoint(st.s)
	feed.checkpoint_distance_m = cp if is_finite(cp) else -1.0
	feed.leg_index = legs.leg_index
	feed.objective = legs.objective
	feed.objective_done = legs.is_objective_done()
	feed.objective_failed = objectives.is_failed()
	feed.objective_progress = objectives.progress()
	feed.objective_target = objectives.target()
	feed.lives = lives.lives
	feed.max_lives = lives.max_lives
	feed.ghost = lives.is_ghost()
	feed.banked = scoring.banked()
	feed.best = maxi(_best_before, feed.banked) if state == Game.RESULTS else _best_before
	feed.chain = scoring.chain()
	feed.multiplier = scoring.multiplier()
	feed.distance_m = stats.distance_m
	if loop != null:
		loop.fill_feed(st.s, feed.checkpoint_distance_m)


# ---------------------------------------------------------------- Run setup

func _start_run() -> void:
	if state == Game.PAUSED:
		get_tree().paused = false
	if not _menu_build:
		attract.end()
	if _menu_build:
		# WP8.5: the title's world (a Journey road of its own seed; no run counted).
		current_seed = Rng.derive_seed(_journey_seed, "menu/%d" % _menu_count)
		_menu_count += 1
	else:
		current_seed = _seed_for(run_count)
		run_count += 1
	tick_count = 0
	if is_loop():
		_setup_loop()
	else:
		loop = null
		ctx = RunContext.new(current_seed, mode, tuning)
		road = ProceduralRoadPath.new(ctx)
		forks.setup(self, forks_enabled)
	var start_s := start_s_m()
	origin.setup(tuning.road.floating_origin_shift_km)
	road.ensure_generated_to(_view_ahead(start_s))
	var smp := road.sample(start_s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	biome_director.setup(ctx, road, origin)
	builder.setup(ctx, road, origin)
	fork_view.setup(ctx, origin)
	roadside.setup(ctx, road, origin)
	landmarks.setup(ctx, road, origin)
	# Before the builder's first build: its ground-drop hook reads the features' plans.
	features.setup(ctx, road, origin)
	if loop != null:
		loop.apply_features(features)
	sky.setup(ctx, road, origin)
	builder.build_all_now(start_s)
	_next_forget_s = start_s + FORGET_EVERY_M

	var car_def: CarDef = load(CAR_PATHS[car_index % CAR_PATHS.size()])
	sim = TrafficSim.new(ctx, road, registry)
	director = TrafficDirector.new(ctx, road, sim, registry.profiles, registry.types,
		car_def.length_m, car_def.width_m)
	director.set_fog_end(builder.view_distance_m())
	director.events = events
	director.set_biome(biome_director.current())
	if loop == null:
		forks.start()
	director.checkpoint_style = biome_director.checkpoint_style   # WP6.3: toll gantries
	traffic_view.setup(ctx, road, origin, registry, sim.state, director.opposite.state)
	set_piece_view.setup(ctx, road, origin)
	set_piece_view.bind(director.set_pieces)
	works_query = WorksPropQuery.new(director.set_pieces, tuning.lives)
	hits.set_prop_query(works_query)
	tunnel_light = TunnelLight.new(road)

	headlights.setup(ctx, road, origin)
	headlight_cones.setup(ctx, road, origin)
	headlight_cones.bind(traffic_view, sim.state, director.opposite.state)
	lamp_pools.setup(ctx, road, origin)
	if crash_sequence != null:
		(crash_sequence as CrashSequence).setup(ctx, registry)
	scoring.reset(ctx)
	sun.reset()
	if (loop != null) != _legs_for_loop:
		# Loop mode's legs (sectors) never reach the coast: its own LegsTuning copy.
		_legs_for_loop = loop != null
		legs = LegTracker.new(ctx.tuning.legs)
	legs.reset(start_s)
	lives.reset()
	events.reset()
	objectives.reset(ctx)
	if loop != null:
		legs.set_objective(&"")   # sectors have no objective
	else:
		_start_leg_objective()
	# Leg 1 is announced like every other leg (its objective "on entry").
	events.push(LegTracker.KIND_LEG_STARTED, 0, 0.0, -1.0, -1, float(legs.leg_index))
	_force_pending = false
	_pending_journey_save = false
	finale.reset(self)
	_pending_first_hit_fx = false
	_pending_crash_fx = false
	_crash_by_sequence = false
	_place_car(car_def, start_s, tuning.legs.start_speed_mps())
	if room != null and room.start_valid:
		car.place_at(start_s, room.start_d, room.start_v)   # N5.2: the room's placement
	legs.plan_ahead(road, _plan_ahead_to(start_s))
	_director_leg = leg_override if leg_override > 0 else _auto_director_leg()
	if loop != null:
		loop.bind_director(director, start_s)   # the loop's leg, density and flow speeds
		sun.sky_t = loop.clock.sky_t()
		sun.phase = SunClock.Phase.NIGHT if loop.night else SunClock.Phase.DAY
	director.set_leg(_director_leg, start_s)
	_headlights = false
	sim.set_headlights(false)
	director.set_night(false)
	director.set_player_params(car.params)   # WP6.1: passability checks against this car
	director.reset(car.state)
	_update_headlights()
	hits.reset(car.state, sim.state)
	stats.reset(car.state.s)

	adapter.reset()
	adapter.clear_buffers()
	adapter.add_buffer(events)
	adapter.scoring = scoring
	adapter.player = car.state
	adapter.legs = legs
	adapter.biome_director = biome_director
	adapter.road = road
	adapter.origin = origin
	adapter.traffic = sim.state
	adapter.forks = forks if loop == null else null
	if hud != null and hud.has_method(&"bind_loop"):
		hud.call(&"bind_loop", loop.feed if loop != null else null)

	_best_before = Save.best_score(mode)
	feed.reset()
	feed.max_lives = lives.max_lives
	feed.lives = lives.lives
	time_scale.restore()
	fx.reset()
	last_results = {}
	sky.sky_t = sun.sky_t
	if _menu_build:
		# WP8.5: the title over the attract drive (no countdown, no run_started), under
		# its own held sky.
		_countdown_ticks = 0
		sun.sky_t = tuning.camera.attract_sky_t
		sky.sky_t = sun.sky_t
		_update_headlights()
		_enter(Game.MENU)
		attract.begin(self)
		_fill_feed()
		return

	# A retry counts faster: back driving inside hud.retry_max_s (Run end). A run started
	# from the title (start_mode) counts in full.
	var step_s := tuning.hud.countdown_step_s if run_count <= 1 or _full_countdown \
			else tuning.hud.retry_countdown_step_s
	_full_countdown = false
	_countdown_step_ticks = maxi(roundi(step_s / _dt), 1)
	_countdown_ticks = tuning.hud.countdown_from * _countdown_step_ticks
	_countdown_shown = tuning.hud.countdown_from
	_countdown_held = false
	_enter(Game.COUNTDOWN)
	Events.run_started.emit(mode, current_seed)   # the countdown screen prepares (and may hold)
	Events.countdown_tick.emit(_countdown_shown)
	if room != null:
		room.on_run_started()   # N5.2: drives from the placement at once, or holds for it
	_fill_feed()


## Where the car waits for the countdown: the road starts at s = 0 (RoadBuilder's
## first chunk), so the run starts as far in as the roadside is kept behind the
## player, and the chase camera never looks past the road's start. Loop mode: lap 1's
## first spawn point (RunLoop.start_s: s = L + 150 m, so nothing ever builds at s < 0).
func start_s_m() -> float:
	if room != null and room.start_valid:
		return room.start_s
	if loop != null:
		return loop.start_s()
	return tuning.road.roadside_behind_m


## N3.2: the loop test mode's run setup (instead of the procedural road and the forks):
## the loop's tuning copy, road, periodic look plan and room clock.
func _setup_loop() -> void:
	if loop == null:
		loop = RunLoop.new()
		# The build's map hash (the web export smoke checks it against the committed one).
		print("loop: %s map_hash=%s" % [MapInfo.LOOP_V1_ID, MapInfo.hash_hex()])
	var t := loop.run_tuning(tuning)
	ctx = RunContext.new(current_seed, mode, t)
	if is_nan(loop.clock_start_unix_s):
		# The room clock is UTC-derived: read once here (the Node layer), then advanced
		# by the sim's dt, so the run replays from its start time.
		loop.setup(t)
		loop.clock.set_time(Time.get_unix_time_from_system())
		loop.night = loop.clock.is_night()
	else:
		loop.setup(t)
	road = loop.road
	builder.clear_skip_range()
	fork_view.end()
	biome_director.plan = loop.biome_plan()
	biome_director.apply_to_road = false


## The director's leg without the dev override: the leg tracker's, or the loop's.
func _auto_director_leg() -> int:
	return loop.tuning.director_leg if loop != null else legs.leg_index


## Loop mode, step 6: the room clock sets the sky and the night (x2), the sections the
## traffic's flow speeds and density.
func _loop_clock_tick(dt: float, s: float) -> void:
	sun.sky_t = loop.tick(dt, s, events)
	sun.phase = SunClock.Phase.NIGHT if loop.night else SunClock.Phase.DAY


## Seed of run k: the base seed first, then derived from it and the counter (Journey);
## Daily Drive keeps the day's seed for every attempt.
func _seed_for(k: int) -> int:
	if k == 0 or mode == RunContext.MODE_DAILY:
		return _base_seed
	return Rng.derive_seed(_base_seed, "retry/%d" % k)


func _place_car(car_def: CarDef, s: float, v_mps: float) -> void:
	var index := car_index % CAR_PATHS.size()
	if not _params_cache.has(index):
		_params_cache[index] = VehicleParams.build(tuning, car_def)
	if car == null or car.car != car_def:
		if car != null:
			remove_child(car)
			car.queue_free()
		car = PLAYER_CAR_SCENE.instantiate() as PlayerCar
		car.name = "PlayerCar"
		car.self_tick = false
		add_child(car)
		car.setup(ctx, road, origin, car_def, _params_cache[index])
		rig.set_target(car, car.state, car.params.top_speed_mps)
		fx.bind(car)
	else:
		car.road = road
		car.origin = origin
	if drive_controller == null:
		drive_controller = PlayerController.new(hub)
	car.controller = drive_controller
	car.place_at(s, road.lane_center_d(tuning.legs.start_lane, s), v_mps)
	car.visual.visible = true
	sim.set_player_body(car_def.length_m, car_def.width_m)
	scoring.set_player_body(car_def.length_m, car_def.width_m)
	hits.set_player_body(car_def.length_m, car_def.width_m)
	director.set_player_box(car_def.length_m, car_def.width_m)
	rig.snap_to_target()


func _enter(to: StringName) -> void:
	state = to
	if to == Game.COUNTDOWN:
		Game.start_run(mode)
	elif to == Game.MENU:
		Game.enter_menu()
	elif Game.state != to:
		Game.change_state(to)
	if title != null:
		title.show_state(to)
		if title.online_hub != null and not title.online_hub.room_ready.is_connected(start_room):
			title.online_hub.room_ready.connect(start_room)   # N5.2: the hub's joins
	_sync_hud()


## The gameplay HUD steps aside for the pause menu, the crash cinematic and the results.
## WP8.5: on the title (MENU) the HUD, the touch controls and the dev rows step aside too
## (the dev HUD stays on its key).
func _sync_hud() -> void:
	var menu := state == Game.MENU
	if hud != null:
		(hud as CanvasLayer).visible = state != Game.CRASH and state != Game.RESULTS and state != Game.PAUSED \
				and not menu
	var overlay := get_node_or_null(^"Overlay") as CanvasLayer
	if overlay != null:
		overlay.visible = not menu
	if dev != null and dev.controls != null:
		dev.controls.visible = not menu
	if room != null and room.hud != null:
		room.hud.visible = not menu and state != Game.PAUSED
	# The dev HUD (a diagnostic overlay) would cover the title's menu: it steps aside on
	# the title and comes back after; its key (`) still toggles it there.
	var dev_hud := get_node_or_null(^"DevHud")
	if dev_hud != null and dev_hud.has_method(&"set_hud_visible"):
		if menu and not _dev_hud_stepped_aside:
			_dev_hud_stepped_aside = true
			_dev_hud_was_visible = bool(dev_hud.call(&"is_hud_visible"))
			dev_hud.call(&"set_hud_visible", false)
		elif not menu and _dev_hud_stepped_aside:
			_dev_hud_stepped_aside = false
			if _dev_hud_was_visible:
				dev_hud.call(&"set_hud_visible", true)


func _install_hud() -> void:
	if ResourceLoader.exists(HUD_SCENE_PATH):
		var scene := load(HUD_SCENE_PATH) as PackedScene
		if scene != null:
			hud = scene.instantiate()
			hud.name = "Hud"
			add_child(hud)
			if hud.has_method(&"bind"):
				hud.call(&"bind", feed)
			if hud.has_signal(&"pause_pressed"):
				hud.connect(&"pause_pressed", toggle_pause)
			if hud.has_signal(&"camera_pressed"):
				hud.connect(&"camera_pressed", hub.request_camera_cycle)
			if hud.has_signal(&"high_beam_pressed"):
				hud.connect(&"high_beam_pressed", hub.toggle_high_beam)


## The in-run screens: they emit intents, the run acts on them (CONTRACTS §14).
func _install_screens() -> void:
	screens = SCREENS_SCENE.instantiate() as RunScreens
	screens.name = "RunScreens"
	add_child(screens)
	screens.bind(hub, feed)
	screens.resume.connect(resume)
	screens.recalibrate.connect(hub.recalibrate_gyro)
	screens.retry.connect(_on_screen_retry)   # N5.2: REJOIN CREW in a room
	screens.quit.connect(enter_menu)   # WP8.5: QUIT goes back to the title
	screens.results_screen.menu.connect(enter_menu)   # WP8.5: the results' MENU
	screens.skip.connect(skip)
	screens.countdown_hold.connect(hold_countdown)


## Headlights by sky_t, the same ramp the sky shows (ColorScript.emissive_headlight,
## on above sun.traffic_headlights_on_ramp), sampled once so the tick only indexes a
## table (deterministic, allocation-free).
func _build_headlight_lut() -> void:
	_headlight_lut.resize(HEADLIGHT_LUT_SIZE)
	var cs := sky.color_script if sky.color_script != null else ColorScript.load_default()
	var key := ColorKey.new()
	var on_above := tuning.sun.traffic_headlights_on_ramp
	for i in HEADLIGHT_LUT_SIZE:
		cs.sample_into((float(i) + 0.5) / float(HEADLIGHT_LUT_SIZE), key)
		var ramp := key.emissive_headlight
		_headlight_lut[i] = 1 if is_finite(ramp) and ramp > on_above else 0


func _view_ahead(s: float) -> float:
	return s + builder.view_distance_m() + tuning.road.chunk_length_m * 2.0


## Night lighting nodes (WP5.4, docs/NIGHT.md): visual only, fed by the sky's ramps.
func _add_night_lights() -> void:
	headlights = PlayerHeadlights.new()
	headlights.name = "PlayerHeadlights"
	headlight_cones = HeadlightCones.new()
	headlight_cones.name = "HeadlightCones"
	lamp_pools = StreetLampPools.new()
	lamp_pools.name = "StreetLampPools"
	for n: Node3D in [headlights, headlight_cones, lamp_pools]:
		n.set(&"sky", sky)
		add_child(n)


## Per frame, before the sky pushes the globals (it is a child: it processes after us).
func _update_night_lights(s: float) -> void:
	if not is_instance_valid(headlights.car) or headlights.car != car:
		headlights.bind(car)
	headlights.high_beam = hub.high_beam
	headlights.enabled = state != Game.CRASH
	headlights.update_view(s)
	headlight_cones.update_view(s)
	lamp_pools.update_view(s)


## Legs are planned a whole leg past the view, so the next checkpoint (the HUD's sun
## bar distance) is always queued. Director rate: allocates only when the road grows.
func _plan_ahead_to(s: float) -> float:
	return _view_ahead(s) + tuning.legs.leg_length_m()


# ---------------------------------------------------------------- Determinism

## Hash of the whole run state (car, traffic, scoring, lives, legs, sun, stats).
func trace_hash() -> int:
	var h := car.state.trace_hash()
	h = sim.state.hash_into(h)
	h = scoring.hash_into(h)
	h = lives.hash_into(h)
	h = legs.hash_into(h)
	h = objectives.hash_into(h)
	h = TraceHash.mix_float(h, sun.sky_t)
	h = loop.hash_into(h) if loop != null else forks.hash_into(h)
	h = TraceHash.mix_int(h, finale.phase)
	return stats.hash_into(h)


## RunFinale: "Journey complete" (the save is written at frame time).
func on_journey_complete() -> void:
	_pending_journey_save = true


## RunForks swapped the road's branch (the right branch was taken; the car's d moved):
## the hit sweep restarts from the new position.
func on_fork_swapped() -> void:
	hits.reset(car.state, sim.state)
	if state == Game.MENU:
		attract.next_shot()   # the pass camera's spot moved with the branch


# ---------------------------------------------------------------- Dev

## Puts the car back in the nearest lane at half speed (dev RESET, safety net).
func dev_reset_car() -> void:
	_resets += 1
	var st := car.state
	var s := st.s
	var lane := clampi(road.lane_index_at(st.d, s), 0, road.lane_count(s) - 1)
	car.place_at(s, road.lane_center_d(lane, s), maxf(st.v * 0.5, 0.0))
	rig.snap_to_target()
	hits.reset(car.state, sim.state)


## Moves the car to `s` (lane legs.start_lane) at `v_mps` and respawns traffic around it
## (snaps, tests, dev). The leg keeps counting from its start.
func dev_teleport(s: float, v_mps: float) -> void:
	road.ensure_generated_to(_view_ahead(s))
	# Forks jumped past take their left branch (and release the road's hold) first.
	if loop == null:
		forks.sync(s)
	legs.plan_ahead(road, _plan_ahead_to(s))
	car.place_at(s, road.lane_center_d(tuning.legs.start_lane, s), v_mps)
	var smp := road.sample(s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	builder.build_all_now(s)
	fork_view.build_all_now(s)
	director.set_player_params(car.params)
	director.reset(car.state)
	hits.reset(car.state, sim.state)
	rig.snap_to_target()


func dev_next_car() -> void:
	car_index = (car_index + 1) % CAR_PATHS.size()
	var st := car.state
	var s := st.s
	var d := st.d
	var v := st.v
	var car_def: CarDef = load(CAR_PATHS[car_index])
	_place_car(car_def, s, v)
	car.place_at(s, d, v)
	hits.reset(car.state, sim.state)
	adapter.player = car.state


func open_sandbox() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(SANDBOX_SCENE)


func open_drive_scene() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(DRIVE_SCENE)


## Snap hook (tools/snap.sh): --state=countdown|running|results|paused, --sky_t=,
## --s=, --speed_kmh=, --car=0..2, --cam=, --damaged, --ghost, --high_beam, --seed= (default SNAP_SEED),
## --leg=N (start --leg_s= metres into leg N, default 600: look at a biome; WP6.4a),
## --at=elevated|lane_ends (WP6.4c: from there, the middle of the next elevated stretch,
## or --at_m= metres, default 150, before the next lane-ends sign), --at=fork (WP6.5:
## --at_m= metres, default 1000, before the next fork's split), --lane=N, --bot=keep
## (a lane-keeping bot drives through --seconds),
## --hud=false (hide the HUD, the dev HUD and the touch overlay: clean look reviews),
## --set_piece=<id> (WP6.3: _snap_set_piece: force that piece, drive up to it).
func snap_setup(args: Dictionary) -> void:
	# Reproducible snaps: a fixed seed unless --seed is given.
	if args.has("car"):
		car_index = int(args["car"]) % CAR_PATHS.size()
	# N3.2: --mode=loop, --clock_min=<minutes into the room cycle> (the sky), --at=<place>.
	if args.has("mode"):
		mode = StringName(str(args["mode"]))
	if is_loop():
		if loop == null:
			loop = RunLoop.new()
		var epoch := loop.tuning.room_clock_epoch_unix_s
		loop.clock_start_unix_s = epoch + Units.min_to_s(float(args.get("clock_min", 0.0)))
	run_seed = int(args.get("seed", SNAP_SEED))
	_base_seed = run_seed
	_journey_seed = run_seed
	run_count = 0
	# WP8.5: --state=menu (the title over the attract drive), --title=hub|settings|account|
	# boards (a title view), --shot=orbit|pass and --attract_s= (seconds of attract drive).
	var menu := str(args.get("state", "")) == "menu"
	if menu:
		_menu_count = 0
		enter_menu()
	else:
		_start_run()
	var s := float(args.get("s", 0.0))
	if loop != null and args.has("at"):
		s = loop.place_s(str(args["at"]))
	elif args.has("leg"):
		s = float(maxi(int(args["leg"]), 1) - 1) * tuning.legs.leg_length_m() + float(args.get("leg_s", SNAP_LEG_S_M))
	if str(args.get("at", "")) == "elevated":
		s = _snap_elevated_s(s)
	elif str(args.get("at", "")) == "lane_ends":
		s = _snap_sign_s(s, ProceduralRoadPath.SIGN_LANE_ENDS) - float(args.get("at_m", SNAP_AT_M))
	elif str(args.get("at", "")) == "fork":
		s = forks.split_s(forks.active) - float(args.get("at_m", SNAP_FORK_M))
	elif str(args.get("at", "")) == "finale":
		# --at_m before the coast finale's point (WP6.5): arm it as the crossing would.
		var coast := float(tuning.legs.legs_to_coast) * tuning.legs.leg_length_m()
		s = coast + tuning.legs.finale_after_m - float(args.get("at_m", SNAP_FINALE_M))
		dev_teleport(s, Units.kmh_to_mps(float(args.get("speed_kmh", tuning.legs.start_speed_kmh))))
		finale.arm(coast)
	if s > 0.0 or args.has("speed_kmh"):
		dev_teleport(s, Units.kmh_to_mps(float(args.get("speed_kmh", tuning.legs.start_speed_kmh))))
		if args.has("at") or loop != null:
			# The legs jumped over are not crossed (no sun lift: --sky_t holds).
			legs.skip_to(s)
	if args.has("lane"):
		car.place_at(car.state.s, road.lane_center_d(int(args["lane"]), car.state.s), car.state.v)
		hits.reset(car.state, sim.state)
	if str(args.get("bot", "")) == "keep":
		# Snaps that drive (--seconds): a lane-keeping bot at the current speed (WP6.5).
		var bot := SandboxBot.new(road, sim.state, car.params, SNAP_SEED)
		bot.mode = SandboxBot.Mode.KEEP
		bot.v_target = car.state.v
		bot.length_m = car.car.length_m
		bot.width_m = car.car.width_m
		drive_controller = bot
	if args.has("sky_t"):
		sun.sky_t = float(args["sky_t"])
		var sun_t := tuning.sun
		sun.phase = SunClock.Phase.NIGHT if sun.sky_t >= sun_t.sky_t_sunset and sun.sky_t < sun_t.sky_t_dawn \
			else SunClock.Phase.DAY
		sky.sky_t = sun.sky_t
		_update_headlights()
	if args.has("cam"):
		rig.set_mode(StringName(str(args["cam"])))
	if menu:
		_snap_menu(args)
	match str(args.get("state", "running")):
		"menu":
			pass
		"running":
			go()
		"results":
			go()
			_contact.clear()
			_begin_crash()
			skip()
		"paused":
			go()
			pause()
	if args.get("damaged", false):
		fx.set_damaged(true)
	if args.get("ghost", false):
		fx.start_ghost(tuning.lives.ghost_period_s)
	hub.set_high_beam(bool(args.get("high_beam", false)))
	if args.has("set_piece") and state == Game.RUNNING:
		_snap_set_piece(args)
	if str(args.get("room", "")) == "demo" and loop != null:
		RunRoom.snap_room(self, args)   # N5.2: the in-room HUD without a server
	if not bool(args.get("hud", true)):
		for n: Node in [hud, get_node_or_null(^"DevHud"), get_node_or_null(^"Overlay"), screens, dev.controls, title]:
			if n != null:
				n.set(&"visible", false)
	rig.snap_to_target()


## Dev (snaps, WP8.5): the title's attract drive after --s / --sky_t: --shot=orbit|pass
## (cut to that shot), --attract_s= seconds of it (ticked here), --title=hub|settings|
## account|boards (a title view, settled) or play (PLAY pressed: title -> countdown).
func _snap_menu(args: Dictionary) -> void:
	attract.begin(self)
	if str(args.get("shot", "orbit")) == "pass":
		attract.next_shot()
	var n := roundi(float(args.get("attract_s", 0.0)) / _dt)
	for k in n:
		tick()
		if k % 2 == 0:
			frame(_dt * 2.0)
	match str(args.get("title", "")):
		"play":
			title.title.play.emit(RunContext.MODE_JOURNEY)   # PLAY: the run's countdown
			screens.finish_animations()
		"hub":
			title.open_hub()
		"settings":
			title.title.open_settings()
		"account":
			title.title.open_account()
		"boards":
			title.title.open_leaderboards()
		var v when v.begins_with("rooms"):
			RunRoom.snap_hub(self, v)   # N5.2: the hub's room flows without a server
	title.finish_animations()


## Dev (snaps, WP6.3): --set_piece=<id> forces that set piece and drives up to it with a
## lane-keeping bot (SandboxBot) at --speed_kmh: a feature-triggered piece (tunnel
## squeeze, toll gantry) from --piece_lead_m (default 500) before its lead distance from its next feature (a road tunnel, a
## toll-gantry checkpoint; lives infinite), any other from where the snap stands. It stops
## --piece_dist_m (default 60) before the piece (its zone start, or its rear), in
## --piece_lane (default the start lane), and hands the car back to the player's input.
func _snap_set_piece(args: Dictionary) -> void:
	var id := StringName(str(args["set_piece"]))
	var def: SetPieceDef = director.set_pieces.defs.get(id)
	if def == null:
		print("snap: no set piece %s" % id)
		return
	infinite_lives = true
	var v := car.state.v
	var bot := SandboxBot.new(road, sim.state, car.params, current_seed)
	bot.v_target = v
	bot.length_m = car.car.length_m
	bot.width_m = car.car.width_m
	var human := drive_controller
	drive_controller = bot
	bot.target_lane = int(args.get("piece_lane", tuning.legs.start_lane))   # after on_attached
	var inst: SetPieceSource.Instance = null
	var tries := SNAP_FEATURE_LEGS if def.trigger != SetPieceDef.Trigger.PEAK else 1
	for attempt in tries:
		if def.trigger != SetPieceDef.Trigger.PEAK:
			# Leg by leg (a teleport resolves the forks it jumps, WP6.5) to the next feature.
			var f := NAN
			for k in SNAP_FEATURE_LEGS:
				f = _snap_feature_s(def, car.state.s)
				if not is_nan(f):
					break
				dev_teleport(car.state.s + tuning.legs.leg_length_m(), v)
			if is_nan(f):
				break
			dev_teleport(f - def.schedule_lead_min_m - float(args.get("piece_lead_m", 500.0)), v)
			bot.traffic = sim.state
		if not director.force_set_piece(id):
			print("snap: %s refused" % id)
		inst = _snap_drive_to(id, args)
		if inst != null:
			break
		if def.trigger != SetPieceDef.Trigger.PEAK:
			dev_teleport(car.state.s + def.schedule_lead_min_m, v)   # that feature did not fit: the next
	drive_controller = human
	builder.build_all_now(car.state.s)
	if inst == null:
		print("snap: %s did not run" % id)
	else:
		print("snap: %s, player %.0f m before it, %d vehicles" % [id,
			(inst.zone_s0 if inst.is_anchored() else inst.s_rear) - car.state.s, inst.n])


## Dev (snaps): ticks until the forced piece `id` runs and the car is --piece_dist_m
## before it (null when it did not run within the lead distance at the car's speed, or
## --piece_wait_s).
func _snap_drive_to(id: StringName, args: Dictionary) -> SetPieceSource.Instance:
	var dist := float(args.get("piece_dist_m", 60.0))
	var limit := roundi(float(args.get("piece_wait_s", 240.0)) / _dt)
	var give_up := roundi(director_tuning_lead(id) / maxf(car.state.v, 1.0) / _dt)
	var inst: SetPieceSource.Instance = null
	for k in limit:
		tick()
		if k % 2 == 0:
			frame(_dt * 2.0)
		inst = null
		for x in director.set_pieces.instances:
			if x.stage == SetPieceSource.Stage.RUNNING and x.def.id == id:
				inst = x
		if inst == null:
			if k > give_up:
				return null
			continue
		var at := inst.zone_s0 if inst.is_anchored() else inst.s_rear
		if car.state.s >= at - dist:
			return inst
	return inst


## Dev (snaps): how far a piece is decided ahead (its lead, or two batches).
func director_tuning_lead(id: StringName) -> float:
	var def: SetPieceDef = director.set_pieces.defs.get(id)
	return maxf(def.schedule_lead_max_m if def.anchored else 0.0, tuning.director.spawn_batch_length_m * 4.0)


## Dev (snaps): the zone start of the next feature a feature-triggered piece belongs to
## from s on (within a leg, on the road generated so far), NAN when none.
func _snap_feature_s(def: SetPieceDef, from_s: float) -> float:
	var end := from_s + tuning.legs.leg_length_m() + def.schedule_lead_min_m
	forks.sync(end)   # forks up to there take their left branch (the road holds at them)
	road.ensure_generated_to(end)
	var found: Array[RoadFeature] = []
	road.features_in(from_s + def.schedule_lead_min_m, end, found)
	biome_director.tag_checkpoints(found)
	for f in found:
		if def.trigger == SetPieceDef.Trigger.TUNNEL and f.kind == RoadFeature.Kind.TUNNEL \
				and f.s_end - f.s_start >= def.tunnel_min_length_m:
			return f.s_start
		if def.trigger == SetPieceDef.Trigger.CHECKPOINT and f.kind == RoadFeature.Kind.CHECKPOINT \
				and f.tag == def.checkpoint_style:
			return f.s_start - def.booth_before_m
	return NAN


## Dev (snaps): the first SIGN tagged `tag` from s on (within two legs), else s.
func _snap_sign_s(from_s: float, tag: StringName) -> float:
	var end := from_s + tuning.legs.leg_length_m() * 2.0
	road.ensure_generated_to(end)
	var found: Array[RoadFeature] = []
	road.features_in(from_s, end, found)
	for f in found:
		if f.kind == RoadFeature.Kind.SIGN and f.tag == tag:
			return f.s_start
	return from_s


## Dev (snaps): the middle of the first full-height elevated stretch from s on (within
## two legs), else s.
func _snap_elevated_s(from_s: float) -> float:
	road.ensure_generated_to(from_s + tuning.legs.leg_length_m() * 2.0)
	var plan := features.elevated.plan
	var s := from_s
	var end := from_s + tuning.legs.leg_length_m() * 2.0
	while s < end:
		var def := plan.def_at(s)
		if def != null and plan.drop_at(s) >= def.height_m:
			var a := s
			while s < end and plan.drop_at(s) >= def.height_m:
				s += def.row_step_m
			return (a + s) * 0.5
		s += def.row_step_m if def != null else tuning.road.chunk_length_m
	return from_s


func _report_dev_stats() -> void:
	var st := car.state
	DevStats.report(DevStats.VEHICLES, sim.state.count)
	DevStats.report(&"opposite", director.opposite.state.count)
	DevStats.report(&"state", state)
	DevStats.report(&"seed", current_seed)
	DevStats.report(&"leg", legs.leg_index)
	DevStats.report(&"director_leg", _director_leg)
	DevStats.report(&"objective", legs.objective)
	DevStats.report(&"objective_progress", objectives.progress())
	DevStats.report(&"lives", lives.lives)
	DevStats.report(&"hits", lives.hits)
	DevStats.report(&"ghost", lives.is_ghost())
	DevStats.report(&"banked", scoring.banked())
	DevStats.report(&"chain", scoring.chain())
	DevStats.report(&"mult", snappedf(scoring.multiplier(), 0.01))
	DevStats.report(&"sky_t", snappedf(sun.sky_t, 0.001))
	DevStats.report(&"night", sun.is_night())
	DevStats.report(&"car", car.car.id)
	DevStats.report(&"speed_kmh", roundi(Units.mps_to_kmh(st.v)))
	DevStats.report(&"gear", st.gear)
	DevStats.report(&"s_m", roundi(st.s))
	DevStats.report(&"d_m", snappedf(st.d, 0.01))
	DevStats.report(&"lane", road.lane_index_at(st.d, st.s))
	DevStats.report(&"boost", snappedf(st.boost_meter, 0.01))
	DevStats.report(&"camera", rig.mode)
	DevStats.report(&"time_scale", snappedf(Engine.time_scale, 0.01))
	DevStats.report(&"resets", _resets)
	DevStats.report(&"events_dropped", events.dropped)


static func _url_scene() -> String:
	return url_param("scene").to_lower()


## The web page's `?key=value` (lower-case key; "" when absent or not on the web).
static func url_param(key: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var query: Variant = JavaScriptBridge.eval("window.location.search", true)
	if not (query is String):
		return ""
	for part: String in (query as String).trim_prefix("?").split("&"):
		if part.begins_with(key + "="):
			return part.trim_prefix(key + "=").uri_decode()
	return ""


## A boot parameter: `?key=value` on the web, `--key=value` on the command line
## (user arguments after `--`, or engine arguments Godot passes through).
static func boot_param(key: String) -> String:
	var v := url_param(key)
	if not v.is_empty():
		return v
	var prefix := "--%s=" % key
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.trim_prefix(prefix)
	for a in OS.get_cmdline_args():
		if a.begins_with(prefix):
			return a.trim_prefix(prefix)
	return ""


## Loop mode on the web (dev and the export smoke): `&at=<place>` (RunLoop.place_s:
## desert, tunnel, coast, bridge, city, farmland, seam, ... or metres), `&clock_min=<min
## into the room cycle>`, `&bot=keep`, `&lane=`, `&speed_kmh=`, `&cam=`, `&hud=false` go
## through snap_setup (a fresh run standing there). Nothing to do without them.
func _apply_url_dev_args() -> void:
	var args := {}
	for key: String in ["at", "clock_min", "bot", "lane", "speed_kmh", "cam", "hud", "seed"]:
		var v := url_param(key)
		if not v.is_empty():
			args[key] = v
	if args.is_empty():
		return
	args["mode"] = String(MODE_LOOP)
	if args.get("hud", "") == "false":
		args["hud"] = false
	snap_setup(args)
