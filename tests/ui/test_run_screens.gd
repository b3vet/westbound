extends WBTest
## The in-run screens (WP4.4): which screen shows per Game state, the countdown and gyro
## calibration, the web motion-permission hold, the pause menu's intents while the tree
## is paused, the in-run settings, the results (every payload key, the personal-best
## comparison), retry back on the road within hud.retry_max_s of sim time, and nothing
## drawn when hidden. Spec: UI → Screens; Run end; Controls → Gyro steering. CONTRACTS §14.
## Touches go through Input.parse_input_event with iOS-style ids (the buttons take the
## mouse events Godot emulates from them).

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const RUN_SCENE := preload("res://src/run/run.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201
const SEED := 20260929
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
## A steering-wheel tilt (rad) for the fake gravity source.
const TILT_A := 0.05
const TILT_B := 0.21

var hud: HudTuning
var _nodes: Array[Node] = []
var _intents: Array[StringName] = []
var _conns: Array = []


## A tilt source the test controls (screen frame; supported; web permission state).
class FakeGravity:
	extends GravitySource
	var g := Vector3(0.0, -9.81, 0.0)
	var permission: StringName = &"granted"

	func read_gravity() -> Vector3:
		return g

	func is_supported() -> bool:
		return true

	func permission_state() -> StringName:
		return permission

	func tilt(rad: float) -> void:
		g = Vector3(sin(rad), -cos(rad), 0.0) * 9.81


func before_all() -> void:
	hud = Tuning.load_default().hud


func before_each() -> void:
	Settings.reset_to_defaults()
	_intents.clear()


func after_each() -> void:
	for c: Array in _conns:
		if (c[0] as Signal).is_connected(c[1]):
			(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	tree.paused = false
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame
	Settings.reset_to_defaults()
	Engine.time_scale = 1.0


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


## RunScreens alone (no run): pinned to the 1280x720 canvas.
func _screens(feed: HudFeed = null) -> RunScreens:
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, feed if feed != null else HudFeed.new())
	s.set_screen(SCREEN, SCREEN)
	for sig: StringName in [&"resume", &"recalibrate", &"retry", &"quit", &"skip"]:
		var name_copy := sig
		_listen(Signal(s, sig), func() -> void: _intents.append(name_copy))
	return s


func _run(gravity: FakeGravity = null) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_nodes.append(r)
	r.screens.persist_settings = false
	if gravity != null:
		r.hub.set_gravity_source(gravity)
		r.hub.set_layout(PlayerInput.GYRO, PlayerInput.AUTO, false)
		r.retry()   # a fresh countdown with gyro steering
	return r


func _ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(Tuning.load_default().vehicle.physics_tick_hz))


## A tap with an iOS-style touch id at the centre of `c`, through the engine's input
## path (the button gets the emulated mouse press and release).
func _tap(c: Control) -> void:
	var to_window := tree.root.get_final_transform()
	var ev := InputEventScreenTouch.new()
	ev.index = IOS_ID
	ev.position = to_window * c.get_global_rect().get_center()
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var up := ev.duplicate() as InputEventScreenTouch
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


func _crash_to_results(r: Run) -> void:
	r.go()
	_ticks(r, _ticks_for(1.0))
	r.lives.lives = 1
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_ticks(r, TICKS_PER_FRAME)
	r.skip()


func _payload(score: int, best_before: int) -> Dictionary:
	var new_best := score > best_before
	return {
		RunStats.SCORE: score,
		RunStats.DISTANCE_M: 14_380.0,
		RunStats.LEGS_COMPLETED: 4,
		RunStats.COAST_REACHED: false,
		RunStats.BEST_CHAIN: 186_400,
		RunStats.BEST_MULTIPLIER: 24.6,
		RunStats.THREADS: 7,
		RunStats.CLOSE_PASSES: 58,
		RunStats.TOP_SPEED_KMH: 287.4,
		RunStats.NIGHT_TIME_S: 96.0,
		RunStats.HITS: 2,
		RunStats.SEED: SEED,
		RunStats.MODE: RunContext.MODE_JOURNEY,
		&"personal_best": maxi(score, best_before),
		&"new_best": new_best,
		&"previous_best": best_before,
	}


func _shown(s: RunScreens) -> Array[String]:
	var out: Array[String] = []
	for sc in s.screens:
		if sc.visible:
			out.append(String(sc.name))
	return out


# ---------------------------------------------------------------- Visibility

func test_one_screen_per_game_state() -> void:
	var s := _screens()
	eq(_shown(s), [] as Array[String], "nothing before a run")
	Events.game_state_changed.emit(Game.BOOT, Game.COUNTDOWN)
	Events.run_started.emit(Game.MODE_JOURNEY, SEED)
	Events.countdown_tick.emit(3)
	eq(_shown(s), ["Countdown"] as Array[String], "COUNTDOWN")
	Events.game_state_changed.emit(Game.COUNTDOWN, Game.RUNNING)
	Events.countdown_tick.emit(0)
	eq(s.countdown.number_text(), "GO", "GO shows as RUNNING starts")
	s.finish_animations()
	eq(_shown(s), [] as Array[String], "RUNNING: GO faded, nothing shows")
	eq(s.visible_item_count(), 0, "no canvas item draws in gameplay")
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	eq(_shown(s), ["Pause"] as Array[String], "PAUSED")
	Events.game_state_changed.emit(Game.PAUSED, Game.RUNNING)
	s.finish_animations()
	eq(_shown(s), [] as Array[String], "resumed")
	Events.game_state_changed.emit(Game.RUNNING, Game.CRASH)
	eq(_shown(s), ["Crash"] as Array[String], "CRASH")
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	Events.run_over.emit(_payload(1000, 0))
	eq(_shown(s), ["Results"] as Array[String], "RESULTS")
	Events.game_state_changed.emit(Game.RESULTS, Game.COUNTDOWN)
	Events.run_started.emit(Game.MODE_JOURNEY, SEED + 1)
	Events.countdown_tick.emit(3)
	eq(_shown(s), ["Countdown"] as Array[String], "retry: the countdown again")
	Events.game_state_changed.emit(Game.COUNTDOWN, Game.MENU)
	eq(_shown(s), [] as Array[String], "MENU: none")


func test_hidden_screens_are_invisible_not_transparent() -> void:
	var s := _screens()
	for sc in s.screens:
		check(not sc.visible, "%s hidden at rest" % sc.name)
		check(sc.process_mode == Node.PROCESS_MODE_ALWAYS or sc.can_process(), "%s processes while paused" % sc.name)
	eq(s.process_mode, Node.PROCESS_MODE_ALWAYS, "the layer always processes")
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	Events.game_state_changed.emit(Game.PAUSED, Game.RUNNING)
	s.finish_animations()
	check(not s.pause_screen.visible, "closed = visible false")
	eq(s.pause_screen.modulate.a, 1.0, "and not left at alpha 0")
	eq(s.visible_item_count(), 0)


# ---------------------------------------------------------------- Countdown

func test_countdown_steps_and_go() -> void:
	var s := _screens()
	Events.run_started.emit(Game.MODE_JOURNEY, SEED)
	for n: int in [3, 2, 1]:
		Events.countdown_tick.emit(n)
		eq(s.countdown.number_text(), str(n))
		eq(s.countdown.step, n)
		s.finish_animations()
		near(s.countdown.get_node(^".").modulate.a, 1.0, 1e-6, "a step stays fully shown")
	Events.game_state_changed.emit(Game.COUNTDOWN, Game.RUNNING)
	Events.countdown_tick.emit(0)
	eq(s.countdown.number_text(), "GO")
	check(s.countdown.visible)
	s.finish_animations()
	check(not s.countdown.visible, "GO fades and the screen hides itself")
	eq(s.countdown.step, -1)
	check(not s.countdown.card_visible() or not s.countdown.visible, "no calibration card in drag mode")


func test_run_countdown_screen_follows_the_run() -> void:
	var r := _run()
	var t := Tuning.load_default().hud
	check(r.screens.countdown.visible, "the run's countdown shows at boot")
	eq(r.screens.countdown.number_text(), str(t.countdown_from))
	_ticks(r, _ticks_for(t.countdown_step_s) + 1)
	eq(r.screens.countdown.number_text(), str(t.countdown_from - 1), "the next step on the run's tick")
	check(not r.screens.countdown.card_visible(), "drag steering: no calibration card")


## WP5.6: the countdown's leg chip names the leg's biome and shows its objective the
## way the HUD does ("5 CLOSE PASSES", in the units setting), from the run's leg 1
## announcement in the countdown's first frame; a retry announces its own.
func test_countdown_names_the_biome_and_the_objective() -> void:
	var r := _run()
	var legs := Tuning.load_default().legs
	_ticks(r, TICKS_PER_FRAME)
	check(r.state == Game.COUNTDOWN, "still counting down")
	var place := Hud.biome_name(r.biome_director.biome_at(r.legs.leg_start_s()).id)
	eq(place, "FARMLAND PLAINS")
	var lines := r.screens.countdown.leg_lines()
	eq(lines, PackedStringArray(["LEG 1 OF %d" % legs.legs_to_coast, place,
			LegObjectives.label(r.objectives.current(), legs)]), "leg, biome and objective")
	Settings.set_value(&"units", &"mph")
	eq(r.screens.countdown.leg_lines()[2], LegObjectives.label(r.objectives.current(), legs, true), "units follow")
	r.retry()
	eq(r.screens.countdown.leg_lines()[1], "", "a retry forgets the old run's biome until its own leg 1")
	_ticks(r, TICKS_PER_FRAME)
	eq(r.screens.countdown.leg_lines()[1], place, "...which comes in the first frame")
	eq(r.screens.countdown.leg_lines()[2], LegObjectives.label(r.objectives.current(), legs, true))


func test_gyro_recalibrates_through_the_countdown_and_locks_at_go() -> void:
	var fake := FakeGravity.new()
	fake.tilt(TILT_A)
	var r := _run(fake)
	var calls := [0]
	_listen(r.screens.recalibrate, func() -> void: calls[0] += 1)
	check(r.screens.gyro_active(), "the hub steers with the (fake) tilt")
	check(r.screens.countdown.card_visible(), "HOLD YOUR PHONE IN DRIVING POSITION card")
	var t := Tuning.load_default().hud
	var steps := t.countdown_from
	# The phone settles into its driving hold during the countdown (a retry: the quick one).
	_ticks(r, _ticks_for(t.retry_countdown_step_s * float(steps - 1)) + 1)
	eq(r.state, Game.COUNTDOWN)
	fake.tilt(TILT_B)
	while r.state == Game.COUNTDOWN:
		_ticks(r, 1)
	eq(r.state, Game.RUNNING)
	eq(calls[0], steps, "one recalibration per remaining step and one at GO (3 was before the spy)")
	near(r.hub.gyro.neutral_rad, TILT_B, 1e-6, "the neutral is the hold at GO")
	check(r.hub.gyro.calibrated)
	eq(r.screens.countdown.number_text(), "GO")


func test_drag_mode_never_recalibrates() -> void:
	var s := _screens()
	Events.run_started.emit(Game.MODE_JOURNEY, SEED)
	for n: int in [3, 2, 1, 0]:
		Events.countdown_tick.emit(n)
	eq(s.countdown.recalibrations, 0)
	check(not _intents.has(&"recalibrate"))


func test_web_motion_permission_holds_the_countdown_until_a_tap() -> void:
	var fake := FakeGravity.new()
	fake.permission = &"armed"
	var r := _run(fake)
	var t := Tuning.load_default().hud
	check(r.screens.countdown.tap_visible(), "TAP TO ENABLE TILT STEERING")
	_ticks(r, _ticks_for(t.countdown_step_s * float(t.countdown_from) * 2.0))
	eq(r.state, Game.COUNTDOWN, "the countdown waits for the tap")
	fake.permission = &"pending"   # the browser asks inside the tap
	_tap(r.screens.countdown)
	check(not r.screens.countdown.tap_visible(), "the prompt goes")
	eq(r.screens.countdown.number_text(), str(t.countdown_from), "the full countdown starts")
	_ticks(r, _ticks_for(t.countdown_step_s * float(t.countdown_from)) + 2)
	eq(r.state, Game.RUNNING)


func test_pause_from_the_countdown_keeps_the_step() -> void:
	var r := _run()
	_ticks(r, _ticks_for(hud.countdown_step_s) + 1)
	var shown := r.screens.countdown.number_text()
	r.pause()
	check(not r.screens.countdown.visible, "hidden under the pause menu")
	check(r.screens.pause_screen.visible)
	r.resume()
	check(r.screens.countdown.visible, "back with the countdown")
	eq(r.screens.countdown.number_text(), shown)


# ---------------------------------------------------------------- Pause

func test_pause_buttons_work_while_the_tree_is_paused() -> void:
	var fake := FakeGravity.new()
	var r := _run(fake)
	r.go()
	_ticks(r, 10)
	var recal := [0]
	_listen(r.screens.recalibrate, func() -> void: recal[0] += 1)
	r.pause()
	check(tree.paused, "the tree is paused")
	var p := r.screens.pause_screen
	check(p.visible)
	eq(p.resume_button.modulate.a, 0.0, "the menu slides in...")
	for i in 3:
		await tree.process_frame
	gt(p.resume_button.modulate.a, 0.0, "...and its transition runs while the tree is paused")
	check(r.hud != null and not (r.hud as CanvasLayer).visible, "the HUD steps aside")
	for b: ScreenButton in [p.resume_button, p.recalibrate_button, p.settings_button, p.quit_button]:
		check(b.visible, "%s shows (gyro)" % b.text)
		ge(b.size.y, hud.touch_target_px, "%s is a big touch target" % b.text)
	fake.tilt(TILT_B)
	_tap(p.recalibrate_button)
	eq(recal[0], 1, "RECALIBRATE while paused")
	near(r.hub.gyro.neutral_rad, TILT_B, 1e-6, "the hub recalibrated")
	_tap(p.settings_button)
	check(p.settings_open and p.settings.visible, "SETTINGS opens the panel")
	_tap(p.done_button)
	check(not p.settings_open, "DONE comes back")
	_tap(p.resume_button)
	eq(r.state, Game.RUNNING, "RESUME")
	check(not tree.paused)
	check((r.hud as CanvasLayer).visible, "HUD back")
	r.pause()
	_tap(p.quit_button)
	eq(r.state, Game.MENU, "QUIT: back to the title (WP8.5)")
	eq(Game.state, Game.MENU)
	check(r.title.is_open(), "the title shows")
	check(not tree.paused)


func test_recalibrate_hidden_without_gyro_and_menu_on_the_thumb_side() -> void:
	var r := _run()
	r.go()
	r.pause()
	var p := r.screens.pause_screen
	check(not p.recalibrate_button.visible, "drag steering: no RECALIBRATE")
	gt(p.resume_button.get_global_rect().get_center().x, SCREEN.size.x * 0.5, "right-handed: menu on the right")
	gt(p.resume_button.position.y, p.quit_button.position.y, "RESUME nearest the thumb, QUIT furthest")
	r.resume()
	Settings.set_value(&"left_handed", true)
	r.pause()
	lt(p.resume_button.get_global_rect().get_center().x, SCREEN.size.x * 0.5, "left-handed: mirrored")


func test_settings_write_settings() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	var p := s.pause_screen
	p.open_settings()
	var sp := p.settings
	var keys: Array[StringName] = [&"steering_mode", &"throttle_mode", &"left_handed", &"drag_visual",
			&"controls_scale", &"steer_sensitivity", &"units", &"text_scale", &"reduced_motion", &"haptics"]
	for k in keys:
		check(sp.row(k) != null, "row %s" % k)
		check(Settings.DEFAULTS.has(k))
	eq(sp.selected_index(&"throttle_mode"), 0, "AUTO selected")
	sp.show_page(SettingsPanel.PAGE_CONTROLS)   # WP8.1: the controls rows have their own page
	_tap(sp.option(&"throttle_mode", 1))
	eq(Settings.get_value(&"throttle_mode"), &"manual", "MANUAL written")
	eq(sp.selected_index(&"throttle_mode"), 1)
	_tap(sp.option(&"left_handed", 1))
	eq(Settings.get_value(&"left_handed"), true)
	_tap(sp.option(&"drag_visual", 1))
	eq(Settings.get_value(&"drag_visual"), &"wheel")
	sp.show_page(SettingsPanel.PAGE_GAME)
	_tap(sp.option(&"units", 1))
	eq(Settings.get_value(&"units"), &"mph")
	_tap(sp.option(&"reduced_motion", 1))
	eq(Settings.get_value(&"reduced_motion"), true)
	_tap(sp.option(&"haptics", 1))
	eq(Settings.get_value(&"haptics"), false)
	sp.option(&"controls_scale", 2).pressed.emit()
	near(float(Settings.get_value(&"controls_scale")), hud.settings_controls_scales[2], 1e-9)
	sp.option(&"steer_sensitivity", 0).pressed.emit()
	near(float(Settings.get_value(&"steer_sensitivity")), hud.settings_sensitivities[0], 1e-9)
	var before := p.title.font_px()
	sp.option(&"text_scale", 1).pressed.emit()
	near(float(Settings.get_value(&"text_scale")), hud.text_scales[1], 1e-9, "125%")
	gt(p.title.font_px(), before, "the screens follow the text size")
	check(p.settings_dirty, "a change marks the settings for saving")
	# A change made elsewhere shows at once.
	Settings.set_value(&"units", &"kmh")
	eq(sp.selected_index(&"units"), 0)


func test_gyro_option_disabled_where_there_is_no_tilt() -> void:
	var r := _run()
	r.go()
	r.pause()
	var sp := r.screens.pause_screen.settings
	r.screens.pause_screen.open_settings()
	var gyro_button := sp.option(&"steering_mode", 1)
	eq(gyro_button.disabled, not r.hub.is_gyro_supported(), "TILT only where the platform has tilt")


# ---------------------------------------------------------------- Results

func test_results_show_every_payload_key() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	var res := _payload(1_284_500, 2_010_000)
	Events.run_over.emit(res)
	var rs := s.results_screen
	check(rs.visible)
	eq(rs.shown_score(), 0, "the score counts up from 0")
	s.finish_animations()
	eq(rs.shown_score(), 1_284_500, "...to the total")
	eq(rs.score_text.text, "1,284,500")
	eq(rs.stat_text(&"distance_m"), "14.4")
	eq(rs.stat_text(&"legs_completed"), "4")
	eq(rs.stat_text(&"coast_reached"), "NO")
	eq(rs.stat_text(&"best_chain"), "186,400")
	eq(rs.stat_text(&"best_multiplier"), "24.6×")
	eq(rs.stat_text(&"threads"), "7")
	eq(rs.stat_text(&"close_passes"), "58")
	eq(rs.stat_text(&"top_speed_kmh"), "287")
	eq(rs.stat_text(&"night_time_s"), "1:36")
	eq(rs.stat_text(&"hits"), "2")
	check(rs.tile_text(&"distance_m").contains("KM"), "distance tile with its unit")
	check(rs.tile_text(&"top_speed_kmh").contains("KM/H"))
	check(rs.tile_text(&"legs_completed").contains("TO THE COAST"))
	check(not rs.badge_visible(), "no NEW BEST")
	check(rs.compare_text().contains("2,010,000"), "the personal best: %s" % rs.compare_text())
	check(rs.compare_text().contains("725,500"), "and how far off it is")
	Settings.set_value(&"units", &"mph")
	Events.run_over.emit(res)
	eq(rs.stat_text(&"top_speed_kmh"), str(roundi(Units.kmh_to_mph(287.4))), "mph")
	check(rs.tile_text(&"distance_m").contains("MI"))


func test_results_new_best_badge_and_comparison() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	Events.run_over.emit(_payload(2_346_900, 2_010_000))
	var rs := s.results_screen
	check(not rs.badge_visible(), "the badge waits for the count")
	s.finish_animations()
	check(rs.badge_visible(), "NEW BEST")
	eq(rs.compare_text(), "+336,900 OVER YOUR BEST")
	Events.run_over.emit(_payload(5000, 0))
	s.finish_animations()
	check(rs.badge_visible(), "a first run is a best")
	eq(rs.compare_text(), "FIRST RECORD")


func test_results_ignore_the_skip_tap_then_retry() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	Events.run_over.emit(_payload(1000, 0))
	var rs := s.results_screen
	check(not rs.accepting, "guarded right after the crash")
	_tap(rs.retry_button)
	check(not _intents.has(&"retry"), "the skip tap's follow-up is ignored")
	s.finish_animations()
	check(rs.accepting)
	check(not rs.garage_button.disabled, "GARAGE (WP8.2; the run opens the garage)")
	_tap(rs.garage_button)
	_tap(rs.retry_button)
	eq(_intents, [&"retry"] as Array[StringName], "RETRY")
	var sw := SCREEN.size.x * 0.5
	gt(rs.retry_button.get_global_rect().get_center().x, sw, "bottom-right thumb reach")
	gt(rs.retry_button.get_global_rect().get_center().y, SCREEN.size.y * 0.5)


func test_retry_is_back_on_the_road_within_budget() -> void:
	var r := _run()
	var t := Tuning.load_default()
	_crash_to_results(r)
	eq(r.state, Game.RESULTS)
	var rs := r.screens.results_screen
	check(rs.visible, "results after the crash")
	rs.accept_input_now()
	var frames_before := Engine.get_process_frames()
	_tap(rs.retry_button)
	eq(r.state, Game.COUNTDOWN, "RETRY: on the road in the same frame")
	eq(Engine.get_process_frames(), frames_before, "no frame needed")
	check(not rs.visible, "results gone")
	check(r.screens.countdown.visible, "countdown shows")
	var ticks := 0
	while r.state == Game.COUNTDOWN and ticks < _ticks_for(t.hud.retry_max_s * 4.0):
		_ticks(r, 1)
		ticks += 1
	eq(r.state, Game.RUNNING)
	var sim_s := float(ticks) * t.vehicle.physics_dt()
	print("      retry to driving: %.2f s of sim time (budget %.1f s)" % [sim_s, t.hud.retry_max_s])
	le(sim_s, t.hud.retry_max_s, "driving again within hud.retry_max_s")
	gt(sim_s, 0.0, "the quick countdown still runs (gyro calibration)")


# ---------------------------------------------------------------- Crash

func test_crash_hint_and_tap_to_skip() -> void:
	var r := _run()
	r.go()
	_ticks(r, _ticks_for(1.0))
	r.lives.lives = 1
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_ticks(r, TICKS_PER_FRAME)
	eq(r.state, Game.CRASH)
	var c := r.screens.crash_screen
	check(c.visible)
	check(not c.hint_visible(), "the impact reads first")
	c.show_hint_now()
	check(c.hint_visible(), "TAP TO SKIP")
	_tap(c)
	eq(r.state, Game.RESULTS, "a tap skips to the results")
	check(not c.visible)
	check(r.screens.results_screen.visible)
