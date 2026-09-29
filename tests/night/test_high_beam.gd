extends WBTest
## Manual high beams (WP5.4, plan decision D8): PlayerInput.toggle_high_beam() /
## set_high_beam(), the H key and gamepad X, the high_beam_changed signal, and that
## the toggle changes nothing in the run's simulation (scoring, traffic, car).
## Spec: World → Night lighting (player headlights); Core loop → Night.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 11
const BOT_SPEED_MPS := 52.0
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2

var _hub: PlayerInput
var _runs: Array[Run] = []
var _changes: Array[bool] = []


func before_each() -> void:
	_changes.clear()
	_hub = PlayerInput.new()
	_hub.auto_advance = false
	tree.root.add_child(_hub)
	_hub.high_beam_changed.connect(func(on: bool) -> void: _changes.append(on))


func after_each() -> void:
	if is_instance_valid(_hub):
		_hub.free()
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame


static func _key(code: Key, pressed: bool, echo: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	ev.echo = echo
	return ev


func test_api_toggles_and_signals_once_per_change() -> void:
	check(not _hub.high_beam, "low beams by default")
	_hub.toggle_high_beam()
	check(_hub.high_beam, "toggled on")
	_hub.set_high_beam(true)
	_hub.toggle_high_beam()
	check(not _hub.high_beam, "toggled off")
	eq(_changes, [true, false] as Array[bool], "one signal per change; set to the same value is silent")


func test_h_key_toggles_on_press_only() -> void:
	_hub.handle_key_event(_key(KEY_H, true))
	check(_hub.high_beam, "H pressed: on")
	_hub.handle_key_event(_key(KEY_H, true, true))
	check(_hub.high_beam, "key repeat (echo) does not toggle")
	_hub.handle_key_event(_key(KEY_H, false))
	check(_hub.high_beam, "release does not toggle: manual, stays on")
	_hub.handle_key_event(_key(KEY_H, true))
	check(not _hub.high_beam, "H again: off")
	eq(_changes.size(), 2)


func test_gamepad_x_toggles() -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = JOY_BUTTON_X
	ev.pressed = true
	_hub.handle_key_event(ev)
	check(_hub.high_beam, "gamepad X: on")


func test_high_beam_survives_release_all() -> void:
	_hub.set_high_beam(true)
	_hub.release_all()
	check(_hub.high_beam, "a manual toggle: kept until toggled (no auto-off)")


func test_keys_report_the_high_beam_edge() -> void:
	KeysGamepad.register_actions()
	var keys := KeysGamepad.new()
	eq(keys.handle_event(_key(KEY_H, true)), KeysGamepad.EDGE_HIGH_BEAM)
	eq(keys.handle_event(_key(KEY_H, false)), 0)
	check(InputMap.has_action(KeysGamepad.HIGH_BEAM))


# ---------------------------------------------------------------- Run: visual only (D8)

func _make() -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	return r


func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func test_high_beams_change_nothing_in_the_run() -> void:
	var t := Tuning.load_default()
	var second := roundi(float(t.vehicle.physics_tick_hz))
	var traces: Array[PackedInt64Array] = []
	for pass_i in 2:
		var r := _make()
		r.sun.sky_t = t.sun.sky_t_night
		r.sun.phase = SunClock.Phase.NIGHT
		r.go()
		var trace := PackedInt64Array()
		for sec in 6:
			if pass_i == 1 and sec % 2 == 1:
				r.hub.toggle_high_beam()
			_run_ticks(r, second)
			trace.append(r.trace_hash())
		if pass_i == 1:
			check(r.headlights.high_beam == r.hub.high_beam, "the headlights follow the hub")
		check(r.sim.headlights(), "night: traffic headlights on")
		traces.append(trace)
		r.queue_free()
		_runs.erase(r)
		await tree.process_frame
	eq(traces[0], traces[1], "identical traces with and without high beams")
