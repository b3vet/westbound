extends "res://tests/integration/run_harness.gd"
## Look back is view only (owner request, 2026-10-03; docs/CONTROLS.md → Look back): the
## real Run with a weaving, boosting bot in traffic, a hit included, gives the same
## Run.trace_hash trace whether the player holds look back (B, gamepad B, the touch
## button, every other second, with the camera stepped every tick) or never does. No
## NetTuning.client_build bump: nothing the simulation reads changed.

const SECONDS := 6


func test_look_back_never_changes_the_run() -> void:
	var plain := await _trace(false)
	var looking := await _trace(true)
	eq(plain.size(), SECONDS)
	eq(looking, plain, "identical traces with and without looking back")


func _trace(look: bool) -> PackedInt64Array:
	_log.clear()
	var r := _make()
	var bot := BoostingBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	r.go()
	var trace := PackedInt64Array()
	var looked := 0
	for k in SECONDS:
		if look:
			var on := k % 2 == 0
			match k % 3:
				0:
					r.hub.handle_key_event(_key_b(on))
				1:
					r.hub.handle_key_event(_pad_b(on))
				2:
					_touch(r, on)
			if r.hub.look_back:
				looked += 1
				check(r.rig.is_look_back(), "the rig follows the hub")
		for i in _ticks_for(1.0):
			_run_ticks(r, 1)
			r.rig.advance(_dt())
		if k == 2 and r.state == Game.RUNNING:
			r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
		trace.append(r.trace_hash())
	if look:
		gt(looked, 0, "looked back during the run")
	r.hub.release_all()
	await _drop(r)
	return trace


func _key_b(pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_B
	ev.pressed = pressed
	return ev


func _pad_b(pressed: bool) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = JOY_BUTTON_B
	ev.pressed = pressed
	ev.device = 1
	return ev


func _touch(r: Run, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = 1_893_457_201
	ev.position = r.hub.layout.look_rect.get_center()
	ev.pressed = pressed
	r.hub.handle_pointer(ev, 0.0)
