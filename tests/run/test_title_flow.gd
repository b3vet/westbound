extends WBTest
## The title and the run (WP8.5): the game boots into the title (MENU) over the attract
## drive; PLAY, DAILY DRIVE and the online hub's LOOP PRACTICE start their runs from a full
## countdown in the same frame; the pause menu's QUIT and the results' MENU come back;
## RETRY keeps the mode; the attract car cannot be hit; the title draws nothing in
## gameplay; a run from the title is the run a direct boot gives. Spec: UI → Screens
## (Title); Cameras → Scripted cameras → Menu ("No scripted camera ever takes control while
## traffic can still hit the player"); Modes at launch (Daily Drive: the UTC date's seed);
## Run end (Retry). docs/RUN.md → Title and attract. Taps use iOS-style touch ids.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const IOS_ID := 1_893_457_201
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const CAR_TYPE := &"sedan"
const CAR_PROFILE := &"commuter"

var t: Tuning
var _nodes: Array[Node] = []
var _conns: Array = []
var _hits: int = 0
var _scored: int = 0
var _started: Array = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	_hits = 0
	_scored = 0
	_started.clear()
	_listen(Events.hit, func(_s: StringName, _l: int) -> void: _hits += 1)
	_listen(Events.scored, func(_k: StringName, _p: int, _m: float, _c: float) -> void: _scored += 1)
	_listen(Events.run_started, func(m: StringName, s: int) -> void: _started.append([m, s]))


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


func _run(title: bool = true) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.title_on_boot = title
	tree.root.add_child(r)
	_nodes.append(r)
	r.screens.persist_settings = false
	r.title.persist_settings = false
	r.title.set_screen(Rect2(0.0, 0.0, 1280.0, 720.0), Rect2(0.0, 0.0, 1280.0, 720.0))
	return r


func _ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(t.vehicle.physics_tick_hz))


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _crash_to_results(r: Run) -> void:
	if r.state == Game.COUNTDOWN:
		r.go()
	_ticks(r, _ticks_for(0.5))
	r.lives.lives = 1
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_ticks(r, TICKS_PER_FRAME)
	r.skip()
	r.screens.results_screen.accept_input_now()


func _spawn_on_player(r: Run, ds: float) -> int:
	var rec := SpawnSource.Record.new()
	rec.s = r.car.state.s + ds
	rec.lane = r.road.lane_index_at(r.car.state.d, r.car.state.s)
	rec.d = r.car.state.d
	rec.v = r.car.state.v
	rec.v0 = rec.v
	rec.type_id = r.registry.type_index(CAR_TYPE)
	rec.profile_id = r.registry.profile_index(CAR_PROFILE)
	rec.flags = TrafficState.FLAG_SCRIPTED
	return r.sim.spawn(rec)


# ---------------------------------------------------------------- Boot

func test_the_title_shows_on_boot_over_the_attract_drive() -> void:
	var r := _run()
	eq(r.state, Game.MENU, "the run boots into MENU")
	eq(Game.state, Game.MENU)
	check(r.title.is_open() and r.title.title.visible, "the title shows")
	check(not r.title.online_hub.visible, "the hub waits")
	eq(r.screens.visible_screen_count(), 0, "no in-run screen on the title")
	check(r.hud != null and not (r.hud as CanvasLayer).visible, "no HUD on the title")
	check(not (r.get_node(^"Overlay") as CanvasLayer).visible, "no touch controls")
	check(not r.dev.controls.visible, "the dev rows step aside")
	check(r.rig.is_attract(), "the attract camera has the pose")
	check(r.car.controller == r.attract.bot, "the car drives itself")
	eq(_started.size(), 0, "no run started")
	eq(r.run_count, 0, "the title's world is not a run")
	check(r.wants_title(), "title_on_boot")


func test_a_run_without_the_title_boots_as_before() -> void:
	var r := _run(false)
	eq(r.state, Game.COUNTDOWN, "tests and tools still boot into the countdown")
	check(not r.title.is_built(), "the title is never built when unused")
	eq(r.title.visible_item_count(), 0)
	check(not r.rig.is_attract())


func test_the_attract_car_drives_and_cannot_be_hit() -> void:
	var r := _run()
	var s0 := r.car.state.s
	var lives := r.lives.lives
	_ticks(r, _ticks_for(3.0))
	gt(r.car.state.s - s0, Units.kmh_to_mps(t.camera.attract_speed_kmh) * 3.0 * 0.5, "the car drives on")
	near(r.car.state.v, Units.kmh_to_mps(t.camera.attract_speed_kmh), Units.kmh_to_mps(t.camera.attract_speed_kmh) * 0.35,
			"at the attract speed (or following traffic)")
	# A car right on top of it, and a forced contact: nothing counts on the title.
	check(_spawn_on_player(r, 0.0) >= 0, "a scripted car overlaps the attract car")
	r.force_hit(HitDetection.HIT_TRAFFIC, -1, 1)
	_ticks(r, _ticks_for(2.0))
	eq(_hits, 0, "no hit on the title")
	eq(r.lives.lives, lives, "no life lost")
	eq(r.lives.hits, 0)
	eq(_scored, 0, "nothing scores on the title")
	eq(r.state, Game.MENU, "still on the title")
	eq(r.scoring.banked(), 0)
	check(r.rig.is_attract(), "the scripted camera only runs where nothing can hit")
	# The same overlap in a run is a hit (the check above is meaningful).
	_tap(r.title.title.play_button)
	r.go()
	r.lives.lives = r.lives.max_lives
	check(_spawn_on_player(r, 0.0) >= 0)
	_ticks(r, TICKS_PER_FRAME * 4)
	gt(_hits, 0, "in a run the same overlap hits")


func test_the_attract_camera_cuts_between_shots() -> void:
	var r := _run()
	eq(r.attract.kind, RunAttract.Shot.ORBIT, "the first shot orbits the car")
	eq(r.attract.shots, 1)
	var ticks := 0
	while r.attract.shots == 1 and ticks < _ticks_for(t.camera.attract_orbit_s + 0.1):
		_ticks(r, 1)
		ticks += 1
	eq(r.attract.shots, 2, "a cut within the orbit's length")
	eq(r.attract.kind, RunAttract.Shot.PASS, "then a camera on the shoulder")
	var road := r.road
	var s := r.attract.pass_s
	check(r.attract.pass_d >= road.median_barrier_d(s) and r.attract.pass_d <= road.guardrail_d(s),
			"inside the carriageway's barriers")
	# The rig shows what the director asks for.
	r.rig.advance(r.tuning.vehicle.physics_dt())
	near(r.rig.global_position.distance_to(r.attract.eye), 0.0, 1e-3, "the camera stands at the shot's eye")
	near(r.rig.camera().fov, t.camera.attract_fov_deg, 1e-3)
	# Traffic across the line of sight cuts the shot (once it ran attract_min_shot_s).
	_ticks(r, _ticks_for(t.camera.attract_min_shot_s))
	var shots := r.attract.shots
	var rec := SpawnSource.Record.new()
	var st := r.car.state
	rec.s = (st.s + r.attract.pass_s) * 0.5
	rec.lane = r.road.lane_index_at(st.d, rec.s)
	rec.d = (st.d + r.attract.pass_d) * 0.5
	rec.v = st.v
	rec.v0 = rec.v
	rec.type_id = r.registry.type_index(CAR_TYPE)
	rec.profile_id = r.registry.profile_index(CAR_PROFILE)
	rec.flags = TrafficState.FLAG_SCRIPTED
	check(r.sim.spawn(rec) >= 0, "a car between the camera and the attract car")
	check(r.attract.is_blocked(r.attract.pass_s, r.attract.pass_d), "blocks the line of sight")
	_ticks(r, 2)
	gt(r.attract.shots, shots, "the blocked shot cuts")
	eq(r.attract.kind, RunAttract.Shot.ORBIT, "to the other kind")


# ---------------------------------------------------------------- Title -> run

func test_play_starts_the_journey_countdown_in_the_same_frame() -> void:
	var r := _run()
	var frames := Engine.get_process_frames()
	var t0 := Time.get_ticks_usec()
	_tap(r.title.title.play_button)
	var dt_s := float(Time.get_ticks_usec() - t0) / 1e6
	eq(r.state, Game.COUNTDOWN, "PLAY: the countdown")
	eq(Engine.get_process_frames(), frames, "in the same frame (no scene load)")
	print("      title -> countdown: %.0f ms" % (dt_s * 1000.0))
	lt(dt_s, t.hud.retry_max_s, "title -> countdown inside the retry budget")
	eq(r.mode, RunContext.MODE_JOURNEY)
	eq(r.current_seed, SEED, "the first Journey run has the run seed")
	eq(_started, [[RunContext.MODE_JOURNEY, SEED]])
	check(not r.rig.is_attract(), "the chase camera is back")
	check(r.car.controller == r.drive_controller, "the player drives")
	check(r.car.controller is PlayerController)
	eq(r.title.visible_item_count(), 0, "the title is gone")
	check(r.screens.countdown.visible, "the countdown shows")
	check((r.hud as CanvasLayer).visible, "the HUD is back")
	check((r.get_node(^"Overlay") as CanvasLayer).visible, "and the touch controls")
	check(r.dev.controls.visible, "and the dev rows")
	var ticks := 0
	while r.state == Game.COUNTDOWN and ticks < _ticks_for(10.0):
		_ticks(r, 1)
		ticks += 1
	near(float(ticks) * r.tuning.vehicle.physics_dt(), float(t.hud.countdown_from) * t.hud.countdown_step_s, 0.05,
			"a run from the title counts in full")


func test_daily_drive_uses_todays_utc_seed_and_retry_keeps_it() -> void:
	var r := _run()
	var d := Time.get_date_dict_from_system(true)
	var seed_today := Rng.daily_seed(int(d["year"]), int(d["month"]), int(d["day"]))
	var tt := r.title.title
	eq(tt.daily_button.note, TitleScreen.date_text(d), "DAILY DRIVE shows today's date")
	_tap(tt.daily_button)
	eq(r.state, Game.COUNTDOWN)
	eq(r.mode, RunContext.MODE_DAILY)
	eq(r.current_seed, seed_today, "the UTC date's seed")
	eq(r.current_seed, RunContext.daily(int(d["year"]), int(d["month"]), int(d["day"])).run_seed)
	eq(r.ctx.mode, RunContext.MODE_DAILY)
	_crash_to_results(r)
	eq(r.state, Game.RESULTS)
	_tap(r.screens.results_screen.retry_button)
	eq(r.state, Game.COUNTDOWN, "RETRY")
	eq(r.mode, RunContext.MODE_DAILY, "RETRY keeps Daily Drive")
	eq(r.current_seed, seed_today, "and the day's seed")


func test_retry_keeps_the_journey_and_menu_goes_back_to_the_title() -> void:
	var r := _run()
	_tap(r.title.title.play_button)
	_crash_to_results(r)
	var rs := r.screens.results_screen
	check(rs.menu_button.visible, "MENU on the results")
	ge(rs.menu_button.size.y, t.hud.touch_target_px)
	var seed_1 := r.current_seed
	_tap(rs.retry_button)
	eq(r.mode, RunContext.MODE_JOURNEY, "RETRY keeps the Journey")
	ne(r.current_seed, seed_1, "with a new seed")
	_crash_to_results(r)
	_tap(rs.menu_button)
	eq(r.state, Game.MENU, "MENU: the title")
	check(r.title.title.visible)
	check(not rs.visible, "the results are gone")
	check(r.rig.is_attract())
	# PLAY again: a new Journey seed (the title never repeats a run).
	_tap(r.title.title.play_button)
	eq(r.state, Game.COUNTDOWN)
	ne(r.current_seed, seed_1)


func test_quit_from_the_pause_menu_goes_back_to_the_title() -> void:
	var r := _run()
	_tap(r.title.title.play_button)
	r.go()
	_ticks(r, 10)
	r.pause()
	check(tree.paused)
	_tap(r.screens.pause_screen.quit_button)
	eq(r.state, Game.MENU, "QUIT: the title")
	eq(Game.state, Game.MENU)
	check(not tree.paused, "the tree runs again")
	check(r.title.title.visible)
	eq(r.screens.visible_screen_count(), 0, "the pause menu is gone")
	_ticks(r, _ticks_for(1.0))
	eq(r.state, Game.MENU, "the attract drive runs")


func test_loop_practice_from_the_online_hub() -> void:
	var r := _run()
	_tap(r.title.title.online_button)
	var hub := r.title.online_hub
	check(hub.visible and not r.title.title.visible, "ONLINE: the hub")
	for b in hub.room_buttons:
		check(b.disabled and b.note == OnlineHubScreen.TEXT_SOON, "%s: rooms are coming" % b.text)
	_tap(hub.back_button)
	check(r.title.title.visible and not hub.visible, "BACK: the title")
	_tap(r.title.title.online_button)
	_tap(hub.loop_button)
	eq(r.state, Game.COUNTDOWN, "LOOP PRACTICE: a run")
	check(r.is_loop(), "in loop mode")
	eq(r.mode, Run.MODE_LOOP)
	eq(r.title.visible_item_count(), 0)
	_crash_to_results(r)
	_tap(r.screens.results_screen.retry_button)
	check(r.is_loop(), "RETRY keeps the loop")
	_crash_to_results(r)
	_tap(r.screens.results_screen.menu_button)
	eq(r.state, Game.MENU)
	check(not r.is_loop(), "the title's world is the Journey road")


func test_settings_and_leaderboards_from_the_title() -> void:
	var r := _run()
	var tt := r.title.title
	_tap(tt.settings_button)
	check(tt.settings_open and tt.settings.visible, "SETTINGS: the settings grid")
	check(not tt.play_button.visible, "the menu steps aside")
	_tap(tt.done_button)
	check(not tt.settings_open and tt.play_button.visible, "DONE: the menu")
	_tap(tt.boards_button)
	check(tt.leaderboards_open(), "LEADERBOARDS: the existing screen")
	check(not tt.play_button.visible, "over the title")
	tt.leaderboards.close_by_player()
	check(not tt.leaderboards_open() and tt.play_button.visible, "BACK: the title")
	check(not tt.garage_button.disabled, "GARAGE (WP8.2)")
	_tap(tt.chip)
	check(tt.settings_open, "the profile chip opens the settings / account")


func test_the_title_draws_nothing_in_gameplay() -> void:
	var r := _run()
	gt(r.title.visible_item_count(), 0, "the title draws on the title")
	_tap(r.title.title.online_button)
	_tap(r.title.online_hub.loop_button)
	r.go()
	_ticks(r, TICKS_PER_FRAME)
	eq(r.title.visible_item_count(), 0, "nothing under the title's layer in gameplay")
	r.screens.finish_animations()
	eq(r.screens.visible_item_count(), 0)
	for s in r.title.screens:
		check(not s.visible, "%s hidden (visible = false)" % s.name)
		eq(s.modulate.a, 1.0, "not left transparent")


# ---------------------------------------------------------------- Determinism

## The title changes nothing in the run: PLAY gives the run a direct boot gives.
func test_a_run_from_the_title_matches_a_direct_boot() -> void:
	var a := _run()
	_ticks(a, _ticks_for(2.0))   # the attract drive first
	a.start_mode(RunContext.MODE_JOURNEY)
	var b := _run(false)
	for r: Run in [a, b]:
		r.go()
	for k in _ticks_for(3.0):
		a.tick()
		b.tick()
	eq(a.current_seed, b.current_seed)
	eq(a.trace_hash(), b.trace_hash(), "same seed + same inputs = same run")


# ---------------------------------------------------------------- Game

func test_game_enter_menu_from_anywhere() -> void:
	var saved := Game.state
	for from: StringName in [Game.BOOT, Game.PAUSED, Game.RESULTS, Game.RUNNING, Game.CRASH]:
		Game.state = from
		Game.enter_menu()
		eq(Game.state, Game.MENU, "from %s" % from)
	var seen: Array = []
	var fn := func(a: StringName, b: StringName) -> void: seen.append([a, b])
	Events.game_state_changed.connect(fn)
	Game.enter_menu()
	Events.game_state_changed.disconnect(fn)
	eq(seen.size(), 0, "nothing announced when already there")
	Game.state = saved
