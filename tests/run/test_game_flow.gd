extends WBTest
## Game (src/core/game.gd): run flow helpers and per-mode HUD sections.

var _saved_state: StringName
var _saved_mode: StringName


func before_each() -> void:
	_saved_state = Game.state
	_saved_mode = Game.mode


func after_each() -> void:
	Game.state = _saved_state
	Game.mode = _saved_mode
	Game.paused_from = &""


func test_start_run_enters_countdown_from_anywhere() -> void:
	for from: StringName in [Game.BOOT, Game.MENU, Game.RESULTS, Game.RUNNING, Game.CRASH]:
		Game.state = from
		Game.start_run(Game.MODE_JOURNEY)
		eq(Game.state, Game.COUNTDOWN, "from %s" % from)
	eq(Game.mode, Game.MODE_JOURNEY)


func test_pause_and_resume_return_to_the_paused_state() -> void:
	var seen: Array = []
	var fn := func(p: bool) -> void: seen.append(p)
	Events.paused_changed.connect(fn)
	Game.state = Game.COUNTDOWN
	check(Game.pause())
	eq(Game.state, Game.PAUSED)
	check(Game.resume())
	eq(Game.state, Game.COUNTDOWN, "back to the countdown")
	Game.state = Game.RUNNING
	check(Game.pause())
	check(Game.resume())
	eq(Game.state, Game.RUNNING)
	Game.state = Game.RESULTS
	check(not Game.pause(), "no pause on the results")
	check(not Game.resume())
	Events.paused_changed.disconnect(fn)
	eq(seen, [true, false, true, false])


func test_the_run_flow_is_legal() -> void:
	Game.state = Game.BOOT
	for to: StringName in [Game.COUNTDOWN, Game.RUNNING, Game.CRASH, Game.RESULTS, Game.COUNTDOWN]:
		check(Game.can_change_to(to), "%s -> %s" % [Game.state, to])
		Game.change_state(to)


func test_hud_sections_per_mode() -> void:
	Game.mode = Game.MODE_JOURNEY
	for s: StringName in [Game.HUD_SCORE, Game.HUD_SUN_BAR, Game.HUD_CHAIN, Game.HUD_LIVES,
			Game.HUD_BUTTONS, Game.HUD_SPEED, Game.HUD_BOOST]:
		check(Game.shows_hud_section(s), "journey shows %s" % s)
	check(not Game.shows_hud_section(Game.HUD_GHOST), "no ghost car in Journey")
	check(Game.shows_hud_section(Game.HUD_GHOST, Game.MODE_DAILY), "Daily shows the ghost car")
	eq(Game.hud_sections(&"unknown_mode"), Game.hud_sections(Game.MODE_JOURNEY), "fallback: Journey")
