extends "res://tests/integration/run_harness.gd"
## WP4.5: what the player sees and how they steer never changes the run. Spec: Scoring
## → Leaderboards ("Fairness: camera, control scheme and throttle mode never affect
## scoring"); Controls ("Every layout outputs the same signals ... Physics and scoring
## cannot tell them apart"); plan D8 (high beams change only visuals); Architecture
## rule 8 (HUD, camera, audio only listen). Each variant replays the same seed and the
## same driving (a weaving bot that also boosts, plus a scripted first hit) in real
## traffic, and the whole run state is hashed every second (Run.trace_hash: car,
## traffic, scoring, lives, legs, objective, sun, stats).

const DRIVE_S := 7
const HIT_AT_S := 3


## Records every VehicleInput the bot produced (for the replays through the hub).
class Recorder:
	extends VehicleController
	var inner: VehicleController
	var steer := PackedFloat64Array()
	var throttle := PackedFloat64Array()
	var brake := PackedFloat64Array()
	var boost := PackedByteArray()

	func _init(wrapped: VehicleController) -> void:
		inner = wrapped

	func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		inner.update(dt, state, out_input)
		steer.append(out_input.steer)
		throttle.append(out_input.throttle)
		brake.append(out_input.brake)
		boost.append(1 if out_input.boost else 0)


## Replays a recording through the input hub, as the layouts deliver it: the hub's
## combined signals each tick (what drag, gyro, pedals or keys produce after their
## filters) and the boost as a gamepad A press, then the real PlayerController.
class HubReplay:
	extends PlayerController
	var rec: Recorder
	var i: int = 0
	var _press := InputEventJoypadButton.new()
	var _release := InputEventJoypadButton.new()

	func _init(input_hub: PlayerInput, recording: Recorder) -> void:
		super(input_hub)
		rec = recording
		_press.button_index = JOY_BUTTON_A
		_press.pressed = true
		_release.button_index = JOY_BUTTON_A
		_release.pressed = false

	func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		var k := mini(i, rec.steer.size() - 1)
		hub.steer = rec.steer[k]
		hub.throttle = rec.throttle[k]
		hub.brake = rec.brake[k]
		if rec.boost[k] != 0:
			hub.handle_key_event(_press)
			hub.handle_key_event(_release)
		i += 1
		super.update(dt, state, out_input)


func test_camera_mode_and_hud_never_change_the_run() -> void:
	var base := await _drive(func(_r: Run) -> void: pass)
	var cockpit := await _drive(func(r: Run) -> void:
		r.rig.set_mode(&"cockpit")
		r.remove_child(r.hud)
		r.hud.queue_free()
		r.hud = null)
	var far := await _drive(func(r: Run) -> void:
		r.rig.set_mode(&"far"))
	eq(cockpit, base, "cockpit camera, no HUD: the same run")
	eq(far, base, "far camera: the same run")
	_check_eventful()


func test_high_beams_never_change_the_run() -> void:
	var base := await _drive(func(_r: Run) -> void: pass)
	var beams := await _drive(func(r: Run) -> void:
		r.hub.set_high_beam(true))
	eq(beams, base, "high beams on: the same run")
	# Toggled mid-run (the frame applies it to the headlights, never to the sim).
	var toggled := await _drive(func(r: Run) -> void:
		r.hub.set_high_beam(true), 2.0)
	eq(toggled, base, "high beams toggled mid-run: the same run")


func test_control_layout_and_throttle_mode_never_change_the_run() -> void:
	var held: Array[Recorder] = []   # lambdas capture locals by value: collect through an array
	var base := await _drive(func(r: Run) -> void:
		held.append(Recorder.new(r.drive_controller))
		r.drive_controller = held[0])
	if not check(held.size() == 1 and held[0].steer.size() > 0, "recorded"):
		return
	var recorder := held[0]
	var layouts: Array = [
		[PlayerInput.DRAG, PlayerInput.AUTO, false],
		[PlayerInput.GYRO, PlayerInput.MANUAL, true],
		[PlayerInput.DRAG, PlayerInput.MANUAL, true],
	]
	for layout: Array in layouts:
		var trace := await _drive(func(r: Run) -> void:
			r.hub.auto_advance = false
			r.hub.set_layout(layout[0], layout[1], layout[2])
			r.drive_controller = HubReplay.new(r.hub, recorder))
		eq(trace, base, "layout %s / %s / mirrored %s: the same run" % layout)


## One run: the seed, the boosting weaving bot on real traffic, `setup` applied after
## GO (or `at_s` seconds in), a scripted first hit at HIT_AT_S. Returns the per-second
## trace hashes.
func _drive(setup: Callable, at_s: float = 0.0) -> PackedInt64Array:
	_log.clear()
	var r := _make()
	var bot := BoostingBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	r.infinite_lives = false
	r.go()
	r.car.state.boost_meter = 1.0   # so the bot boosts early, then again when it refills
	if at_s <= 0.0:
		setup.call(r)
	var trace := PackedInt64Array()
	for sec in DRIVE_S:
		if at_s > 0.0 and sec == int(at_s):
			setup.call(r)
		if sec == HIT_AT_S:
			r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
		_run_s(r, 1.0)
		trace.append(r.trace_hash())
	await _drop(r)
	return trace


## The fairness runs are not trivially equal: the bot scored, boosted and was hit.
func _check_eventful() -> void:
	gt(_count("scored"), 0, "the run scored")
	gt(_count("boost_started"), 0, "the bot boosted")
	eq(_count("hit"), 1, "the scripted hit")
