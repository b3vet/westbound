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
##   7.   leg tracker (observe_multiplier, step); a crossing runs the spec's order:
##        bank, sun lift or dawn, leg bonuses, clean-leg life, then set_night again
## Every sim writes into one ScoreEventBuffer; RunEvents drains it once per frame.
## Slow motion, camera shake, the crash cue and screens react at frame rate.

const PLAYER_CAR_SCENE := preload("res://src/vehicle/player_car.tscn")
const CAR_PATHS: Array[String] = [
	"res://data/cars/falcon_gt.tres",
	"res://data/cars/night_viper.tres",
	"res://data/cars/brute_v8.tres",
]
## WP4.3's HUD: installed only if the scene exists (built in parallel).
const HUD_SCENE_PATH := "res://src/ui/hud/hud.tscn"
const DRIVE_SCENE := "res://src/dev/car_drive.tscn"
const SANDBOX_SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
## The journey bonus kind (paid on the crossing that reaches the coast).
const BONUS_JOURNEY := &"journey"
## Sims sharing the run's event buffer: traffic, lives, scoring, sun clock, legs.
const EVENT_SOURCES := 5
## Headlight lookup over sky_t (built once from the color script).
const HEADLIGHT_LUT_SIZE := 1024
## Road memory is trimmed at most this often (m).
const FORGET_EVERY_M := 500.0
## tools/snap.sh runs use this seed unless --seed is given.
const SNAP_SEED := 20260929
## After the physics car (tick) and before the camera rig (100).
const PHYSICS_PRIORITY := 50

# ---- pending tuning (not in any tuning file yet; see docs/RUN.md and the handoff) ----
## Rolling start: lane and speed at the start line (car_drive's values).
const START_LANE := 1
const START_SPEED_KMH := 120.0   # lint: allow-number pending tuning (hud/legs)
## One countdown step (hud.countdown_from steps).
const COUNTDOWN_STEP_S := 1.0
## Traffic headlights on while the color script's headlight ramp is above this.
const HEADLIGHTS_ON_RAMP := 0.3   # lint: allow-number pending tuning (sun)
## Crash: traffic within this distance (along s) of the player brakes (hit reaction).
const CRASH_BRAKE_RADIUS_M := 80.0   # lint: allow-number pending tuning (lives)
# ----

## The first run's seed; 0 = a random seed at boot (Journey). Retries derive theirs
## from it and the run counter (Rng.derive_seed), so a test that sets it replays.
@export var run_seed: int = 0
@export var mode: StringName = RunContext.MODE_JOURNEY
@export var car_index: int = 0
## Off: the countdown waits for go() (WP4.4's countdown screen, gyro calibration).
@export var auto_countdown: bool = true
## Store the personal best in Save at run end.
@export var record_best: bool = true
## Tests: tick() and frame() are called by the test instead of the engine.
@export var manual_ticks: bool = false

## StringName of Game.* (BOOT, COUNTDOWN, RUNNING, PAUSED, CRASH, RESULTS).
var state: StringName = &"boot"
var run_count: int = 0
var current_seed: int = 0
var tick_count: int = 0

var tuning: Tuning
var ctx: RunContext
var road: ProceduralRoadPath
var origin: FloatingOrigin
var biome_director: BiomeDirector
var builder: RoadBuilder
var roadside: Roadside
var sky: SkyRig
var hub: PlayerInput
var rig: CameraRig
var car: PlayerCar
var registry: TrafficRegistry
var sim: TrafficSim
var director: TrafficDirector
var traffic_view: TrafficView
var scoring: Scoring
var sun: SunClock
var legs: LegTracker
var hits: HitDetection
var lives: Lives
var stats := RunStats.new()
var events: ScoreEventBuffer
var feed := HudFeed.new()
var adapter: RunEvents
var time_scale: TimeScale
var fx: PlayerFx
var ui: RunUi
## WP4.3's Hud (null until src/ui/hud/hud.tscn exists).
var hud: Node
var dev: RunDevPanel
## The Events.run_over payload of the last finished run.
var last_results: Dictionary = {}
## The controller while driving (PlayerController on the input hub by default;
## tests put a scripted bot here). Swapped for the braking one during the crash.
var drive_controller: VehicleController:
	set(value):
		drive_controller = value
		if car != null and state != Game.CRASH:
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
var _go_flash_s: float = 0.0
var _crash_left_s: float = 0.0
var _crash_by_sequence: bool = false
var _pending_first_hit_fx: bool = false
var _pending_crash_fx: bool = false
var _paused_from: StringName = &""
var _headlight_lut := PackedByteArray()
var _headlights: bool = false
var _director_leg: int = 1
var _next_forget_s: float = 0.0
var _frustum_smp := RoadSample.new()
var _resets: int = 0
var _best_before: int = 0


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
	process_physics_priority = PHYSICS_PRIORITY
	tuning = Tuning.load_default()
	_dt = tuning.vehicle.physics_dt()
	_countdown_step_ticks = maxi(roundi(COUNTDOWN_STEP_S / _dt), 1)
	events = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity * EVENT_SOURCES)
	_base_seed = run_seed if run_seed != 0 else Rng.random_seed()

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
	roadside = Roadside.new()
	roadside.name = "Roadside"
	roadside.biome_director = biome_director
	add_child(roadside)
	traffic_view = TrafficView.new()
	traffic_view.name = "TrafficView"
	add_child(traffic_view)
	registry = TrafficRegistry.load_default(tuning.traffic)
	scoring = Scoring.new()
	sun = SunClock.new(tuning.sun, tuning.legs)
	legs = LegTracker.new(tuning.legs)
	hits = HitDetection.new(tuning.lives, tuning.traffic.max_active_vehicles)
	lives = Lives.new(tuning.lives)
	fx = PlayerFx.new()
	fx.name = "PlayerFx"
	add_child(fx)
	ui = RunUi.new()
	ui.name = "RunUi"
	add_child(ui)
	ui.retry_pressed.connect(retry)
	ui.pause_pressed.connect(toggle_pause)
	ui.resume_pressed.connect(resume)
	_build_headlight_lut()
	_install_hud()
	dev = RunDevPanel.new()
	dev.name = "RunDev"
	add_child(dev)

	_start_run()
	dev.setup(self)
	if manual_ticks:
		set_physics_process(false)
		set_process(false)


func _exit_tree() -> void:
	if get_tree() != null and get_tree().paused and state == Game.PAUSED:
		get_tree().paused = false


# ---------------------------------------------------------------- Flow API

## Start (or restart) a run: new seed, world rebuilt around s = 0, sims reset, COUNTDOWN.
## Retry takes this path; no scene reload (the world nodes re-run their setup()).
func retry() -> void:
	if state == Game.PAUSED:
		get_tree().paused = false
		ui.show_paused(false)
	if crash_sequence != null and crash_sequence.has_method(&"reset"):
		crash_sequence.call(&"reset")
	_start_run()


## Ends the countdown now (WP4.4's countdown screen calls this when auto_countdown is off).
func go() -> void:
	if state != Game.COUNTDOWN:
		return
	_enter(Game.RUNNING)
	_countdown_ticks = 0
	_go_flash_s = COUNTDOWN_STEP_S
	Events.countdown_tick.emit(0)


func pause() -> void:
	if state != Game.COUNTDOWN and state != Game.RUNNING:
		return
	_paused_from = state
	state = Game.PAUSED
	Game.pause()
	get_tree().paused = true
	ui.show_paused(true)


func resume() -> void:
	if state != Game.PAUSED:
		return
	get_tree().paused = false
	state = _paused_from
	Game.resume()
	ui.show_paused(false)


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


## Director leg: 0 follows the leg tracker (dev LEG button).
func set_leg_override(leg: int) -> void:
	leg_override = maxi(leg, 0)
	_director_leg = leg_override if leg_override > 0 else legs.leg_index
	director.set_leg(_director_leg, car.state.s)


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
			car.tick(dt)
			_crash_tick(dt)
	tick_count += 1
	var smp := car.road_sample()
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)


func _countdown_tick() -> void:
	if not auto_countdown:
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
	# 3. traffic, the player as participant, then the director.
	sim.step(dt, st, car.params, events)
	director.step(dt, st)
	traffic_view.capture_tick()
	# 4. collisions and hits.
	lives.step(dt, st, events)
	var contact := hits.step(dt, st, sim.state, road, _contact)
	if _force_pending:
		_force_pending = false
		_contact.copy_from(_forced)
		contact = true
	if contact:
		match lives.on_contact(_contact, st, events):
			Lives.Outcome.FIRST_HIT:
				_count_hit()
				_pending_first_hit_fx = true
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
	# 6. the sun clock.
	sun.advance(dt, scoring.is_too_slow(), events)
	scoring.set_night(sun.is_night())
	_update_headlights()
	# 7. legs and checkpoints.
	legs.observe_multiplier(dt, scoring.multiplier())
	if legs.step(dt, st.s, sun.is_night(), events):
		_dispatch_crossing()
	if leg_override <= 0 and legs.leg_index != _director_leg:
		_director_leg = legs.leg_index
		director.set_leg(_director_leg, st.s)
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
			sun.lift(events.value[i], events)
		elif k == Scoring.KIND_NEAR_MISS:
			sim.notify_close_pass(events.slot[i])
		elif k == ScoreEvents.THREAD:
			legs.notify_thread()
		elif k == ScoreEvents.CLOSE_PASS:
			legs.notify_close_pass()


## The spec's crossing sequence (Legs and checkpoints, steps 1-4; 5 is the HUD toast).
func _dispatch_crossing() -> void:
	var c := legs.crossing
	scoring.notify_checkpoint(events)
	sun.on_checkpoint(c.avg_speed_mps, events)
	for i in c.bonus_count():
		scoring.award_bonus(c.bonus_kind(i), c.bonus_base_points(i, tuning.legs), events)
	if c.objective_done:
		scoring.award_bonus(LegTracker.BONUS_OBJECTIVE, tuning.legs.objective_bonus_points, events)
	if c.coast:
		scoring.award_bonus(BONUS_JOURNEY, tuning.legs.journey_bonus_points, events)
	if c.clean:
		lives.restore_life(events)
	# After the bonuses: a leg finished at night pays x2, then the dawn clears the night.
	scoring.set_night(sun.is_night())
	_update_headlights()


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
		road.forget_before(s - roadside.reach_behind_m() - tuning.road.chunk_length_m)
		_next_forget_s = s + FORGET_EVERY_M


# ---------------------------------------------------------------- Crash and results

func _begin_crash() -> void:
	_count_hit()
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
	return false


## Surrounding traffic brakes (TrafficSim.notify_hit: hard brake, hazards, a small
## swerve away from the player). Crash only; allocation-free.
func _brake_surrounding_traffic() -> void:
	var ts := sim.state
	var ps := car.state.s
	for i in ts.capacity:
		if ts.active[i] != 0 and absf(ts.s[i] - ps) <= CRASH_BRAKE_RADIUS_M:
			sim.notify_hit(i)


func _end_crash() -> void:
	if state != Game.CRASH:
		return
	_crash_by_sequence = false
	Events.crash_finished.emit()
	time_scale.restore()
	_show_results()


func _show_results() -> void:
	_enter(Game.RESULTS)
	var score := scoring.banked()
	last_results = stats.results(score, current_seed, mode)
	var best := _best_before
	var new_best := score > best
	if record_best:
		Save.submit_best_score(mode, score)
	last_results[&"personal_best"] = maxi(best, score)
	last_results[&"new_best"] = new_best
	Events.run_over.emit(last_results)
	ui.show_hint("")
	ui.show_results(last_results, best, new_best)


# ---------------------------------------------------------------- Frame

## Once per rendered frame with the real (unscaled) frame time: drains the events,
## plays the frame-rate reactions, updates the views, the sky and the HUD feed.
func frame(real_dt: float) -> void:
	if state == Game.CRASH and not _crash_by_sequence:
		_crash_left_s -= real_dt
		if _crash_left_s <= 0.0:
			_end_crash()
	adapter.drain()
	var feel := tuning.feel
	if _pending_first_hit_fx:
		_pending_first_hit_fx = false
		# The camera shakes on Events.hit (CameraRig listens); slow motion is asked here.
		Events.slowmo_requested.emit(feel.slowmo_first_hit_scale, feel.slowmo_first_hit_s, TimeScale.REASON_FIRST_HIT)
	if _pending_crash_fx:
		_pending_crash_fx = false
		Events.crash_started.emit()
		if not _crash_by_sequence:
			Events.slowmo_requested.emit(feel.slowmo_crash_scale, feel.slowmo_crash_s, TimeScale.REASON_CRASH)
		if state == Game.CRASH:
			ui.show_hint("TAP TO SKIP")
	if _go_flash_s > 0.0:
		_go_flash_s -= real_dt
		ui.show_countdown(0 if _go_flash_s > 0.0 else -1)
	elif state == Game.COUNTDOWN and auto_countdown:
		ui.show_countdown(maxi(_countdown_shown, 1))
	else:
		ui.show_countdown(-1)
	var s := car.state.s
	sky.sky_t = sun.sky_t
	biome_director.update_view(s)
	builder.update_view(s)
	roadside.update_view(s)
	sky.update_view(s)
	traffic_view.update_view(s)
	_fill_feed()
	ui.update_readouts(feed, Settings.get_value(&"units") != &"mph")
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
	feed.lives = lives.lives
	feed.max_lives = lives.max_lives
	feed.ghost = lives.is_ghost()
	feed.banked = scoring.banked()
	feed.best = maxi(_best_before, feed.banked) if state == Game.RESULTS else _best_before
	feed.chain = scoring.chain()
	feed.multiplier = scoring.multiplier()
	feed.distance_m = stats.distance_m


# ---------------------------------------------------------------- Run setup

func _start_run() -> void:
	if state == Game.PAUSED:
		get_tree().paused = false
	current_seed = _seed_for(run_count)
	run_count += 1
	tick_count = 0
	ctx = RunContext.new(current_seed, mode, tuning)
	road = ProceduralRoadPath.new(ctx)
	var start_s := start_s_m()
	origin.setup(tuning.road.floating_origin_shift_km)
	road.ensure_generated_to(_view_ahead(start_s))
	var smp := road.sample(start_s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	biome_director.setup(ctx, road, origin)
	builder.setup(ctx, road, origin)
	roadside.setup(ctx, road, origin)
	sky.setup(ctx, road, origin)
	builder.build_all_now(start_s)
	_next_forget_s = start_s + FORGET_EVERY_M

	var car_def: CarDef = load(CAR_PATHS[car_index % CAR_PATHS.size()])
	sim = TrafficSim.new(ctx, road, registry)
	director = TrafficDirector.new(ctx, road, sim, registry.profiles, registry.types,
		car_def.length_m, car_def.width_m)
	director.frustum_check = _in_frustum
	director.set_fog_end(builder.view_distance_m())
	traffic_view.setup(ctx, road, origin, registry, sim.state, director.opposite.state)
	var biome := biome_director.current()
	if biome != null and not biome.traffic_palette.is_empty():
		traffic_view.set_palette(biome.traffic_palette)

	scoring.reset(ctx)
	sun.reset()
	legs.reset(start_s)
	lives.reset()
	events.reset()
	_force_pending = false
	_pending_first_hit_fx = false
	_pending_crash_fx = false
	_crash_by_sequence = false
	_go_flash_s = 0.0
	_place_car(car_def, start_s, Units.kmh_to_mps(START_SPEED_KMH))
	legs.plan_ahead(road, _plan_ahead_to(start_s))
	_director_leg = leg_override if leg_override > 0 else legs.leg_index
	director.set_leg(_director_leg, start_s)
	_headlights = false
	sim.set_headlights(false)
	director.set_night(false)
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

	_best_before = Save.best_score(mode)
	feed.reset()
	feed.max_lives = lives.max_lives
	feed.lives = lives.lives
	time_scale.restore()
	fx.reset()
	ui.show_paused(false)
	ui.hide_results()
	ui.show_hint("")
	last_results = {}
	sky.sky_t = sun.sky_t

	_countdown_ticks = tuning.hud.countdown_from * _countdown_step_ticks
	_countdown_shown = tuning.hud.countdown_from
	_enter(Game.COUNTDOWN)
	Events.run_started.emit(mode, current_seed)
	Events.countdown_tick.emit(_countdown_shown)
	ui.show_countdown(_countdown_shown)
	_fill_feed()


## Where the car waits for the countdown: the road starts at s = 0 (RoadBuilder's
## first chunk), so the run starts as far in as the roadside is kept behind the
## player, and the chase camera never looks past the road's start.
func start_s_m() -> float:
	return tuning.road.roadside_behind_m


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
	car.place_at(s, road.lane_center_d(START_LANE, s), v_mps)
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
	elif Game.state != to:
		Game.change_state(to)


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
	ui.set_fallback_visible(hud == null)


## Headlights by sky_t, the same ramp the sky shows (ColorScript.emissive_headlight),
## sampled once so the tick only indexes a table (deterministic, allocation-free).
func _build_headlight_lut() -> void:
	_headlight_lut.resize(HEADLIGHT_LUT_SIZE)
	var cs := sky.color_script if sky.color_script != null else ColorScript.load_default()
	var key := ColorKey.new()
	for i in HEADLIGHT_LUT_SIZE:
		cs.sample_into((float(i) + 0.5) / float(HEADLIGHT_LUT_SIZE), key)
		var ramp := key.emissive_headlight
		_headlight_lut[i] = 1 if is_finite(ramp) and ramp > HEADLIGHTS_ON_RAMP else 0


func _view_ahead(s: float) -> float:
	return s + builder.view_distance_m() + tuning.road.chunk_length_m * 2.0


## Legs are planned a whole leg past the view, so the next checkpoint (the HUD's sun
## bar distance) is always queued. Director rate: allocates only when the road grows.
func _plan_ahead_to(s: float) -> float:
	return _view_ahead(s) + tuning.legs.leg_length_m()


func _in_frustum(s: float, d: float) -> bool:
	road.sample_into(s, _frustum_smp)
	var p := _frustum_smp.local_point(d, origin.origin_x, origin.origin_y, origin.origin_z)
	return rig.camera().is_position_in_frustum(p)


# ---------------------------------------------------------------- Determinism

## Hash of the whole run state (car, traffic, scoring, lives, legs, sun, stats).
func trace_hash() -> int:
	var h := car.state.trace_hash()
	h = sim.state.hash_into(h)
	h = scoring.hash_into(h)
	h = lives.hash_into(h)
	h = legs.hash_into(h)
	h = TraceHash.mix_float(h, sun.sky_t)
	return stats.hash_into(h)


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


## Moves the car to `s` (lane START_LANE) at `v_mps` and respawns traffic around it
## (snaps, tests, dev). The leg keeps counting from its start.
func dev_teleport(s: float, v_mps: float) -> void:
	road.ensure_generated_to(_view_ahead(s))
	legs.plan_ahead(road, _plan_ahead_to(s))
	car.place_at(s, road.lane_center_d(START_LANE, s), v_mps)
	var smp := road.sample(s)
	origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
	builder.build_all_now(s)
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
## --s=, --speed_kmh=, --car=0..2, --cam=, --damaged, --ghost, --seed= (default SNAP_SEED).
func snap_setup(args: Dictionary) -> void:
	# Reproducible snaps: a fixed seed unless --seed is given.
	if args.has("car"):
		car_index = int(args["car"]) % CAR_PATHS.size()
	run_seed = int(args.get("seed", SNAP_SEED))
	_base_seed = run_seed
	run_count = 0
	_start_run()
	var s := float(args.get("s", 0.0))
	if s > 0.0 or args.has("speed_kmh"):
		dev_teleport(s, Units.kmh_to_mps(float(args.get("speed_kmh", START_SPEED_KMH))))
	if args.has("sky_t"):
		sun.sky_t = float(args["sky_t"])
		var sun_t := tuning.sun
		sun.phase = SunClock.Phase.NIGHT if sun.sky_t >= sun_t.sky_t_sunset and sun.sky_t < sun_t.sky_t_dawn \
			else SunClock.Phase.DAY
		sky.sky_t = sun.sky_t
		_update_headlights()
	if args.has("cam"):
		rig.set_mode(StringName(str(args["cam"])))
	match str(args.get("state", "running")):
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
	_go_flash_s = 0.0
	rig.snap_to_target()


func _report_dev_stats() -> void:
	var st := car.state
	DevStats.report(DevStats.VEHICLES, sim.state.count)
	DevStats.report(&"opposite", director.opposite.state.count)
	DevStats.report(&"state", state)
	DevStats.report(&"seed", current_seed)
	DevStats.report(&"leg", legs.leg_index)
	DevStats.report(&"director_leg", _director_leg)
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
	var query: Variant = JavaScriptBridge.eval("window.location.search", true)
	if not (query is String):
		return ""
	for part: String in (query as String).trim_prefix("?").split("&"):
		if part.begins_with("scene="):
			return part.trim_prefix("scene=").to_lower()
	return ""
