extends WBTest
## Menus with a gamepad (owner request, 2026-10-03: an Xbox controller on the web build):
## PadNav and the focusable ScreenButtons. The pad's bindings match every device (a
## browser's Gamepad.index is not always 0); D-pad, left stick and arrows move a visible
## focus inside the scope (never onto a covered button); A presses, B backs out; LB / RB
## switch tabs; title → online hub → back, the pause menu and its settings, the results;
## a touch or click ends the pad's focus; the garage keeps its own arrows. Events go through
## Input.parse_input_event, like a real pad. docs/CONTROLS.md → Menus with a gamepad.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201
## A pad that is not device 0 (a second pad, a reconnect, a Mac with another HID device).
const PAD := 2

var t: Tuning
var pad: PadNav
var _nodes: Array[Node] = []
var _intents: Array[StringName] = []
var _started: Array[StringName] = []


func before_all() -> void:
	t = Tuning.load_default()
	KeysGamepad.register_actions()


func before_each() -> void:
	Settings.reset_to_defaults()
	_intents.clear()
	_started.clear()
	pad = PadNav.new()
	pad.controls = t.controls
	tree.root.add_child(pad)
	_nodes.append(pad)


func after_each() -> void:
	tree.paused = false
	var f := tree.root.gui_get_focus_owner()
	if f != null:
		f.release_focus()
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.reset_to_defaults()


# ---------------------------------------------------------------- Helpers

func _press(b: JoyButton, device: int = PAD) -> void:
	for down: bool in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = b
		ev.pressed = down
		ev.pressure = 1.0 if down else 0.0
		ev.device = device
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _stick(x: float, y: float, device: int = PAD) -> void:
	for a: JoyAxis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
		var ev := InputEventJoypadMotion.new()
		ev.axis = a
		ev.axis_value = x if a == JOY_AXIS_LEFT_X else y
		ev.device = device
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
	Input.flush_buffered_events()


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _focus() -> Control:
	return tree.root.gui_get_focus_owner()


func _focused(expected: Control, message: String = "") -> bool:
	var f := _focus()
	var got := String(f.name) if f != null else "nothing"
	var want := String(expected.name) if expected != null else "nothing"
	return check(f == expected, "%s: focus on %s, expected %s" % [message, got, want])


func _title() -> TitleScreens:
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.append(ts)
	ts.set_screen(SCREEN, SCREEN)
	ts.start.connect(func(m: StringName) -> void: _started.append(m))
	ts.show_state(Game.MENU)
	ts.finish_animations()
	return ts


func _screens() -> RunScreens:
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(SCREEN, SCREEN)
	for sig: StringName in [&"resume", &"retry", &"quit"]:
		var name_copy := sig
		Signal(s, sig).connect(func() -> void: _intents.append(name_copy))
	s.results_screen.menu.connect(func() -> void: _intents.append(&"menu"))
	return s


func _results_payload() -> Dictionary:
	return {
		RunStats.SCORE: 120_000, RunStats.DISTANCE_M: 4_000.0, RunStats.LEGS_COMPLETED: 1,
		RunStats.COAST_REACHED: false, RunStats.BEST_CHAIN: 1000, RunStats.BEST_MULTIPLIER: 2.0,
		RunStats.THREADS: 1, RunStats.CLOSE_PASSES: 3, RunStats.TOP_SPEED_KMH: 200.0,
		RunStats.NIGHT_TIME_S: 0.0, RunStats.HITS: 3, RunStats.SEED: 1,
		RunStats.MODE: RunContext.MODE_JOURNEY,
		&"personal_best": 120_000, &"new_best": false, &"previous_best": 200_000,
	}


# ---------------------------------------------------------------- Bindings

func test_bindings_match_every_pad_device() -> void:
	var cases := {
		JOY_BUTTON_A: [&"ui_accept", KeysGamepad.BOOST],
		JOY_BUTTON_B: [&"ui_cancel", KeysGamepad.LOOK_BACK],
		JOY_BUTTON_DPAD_UP: [&"ui_up"],
		JOY_BUTTON_DPAD_DOWN: [&"ui_down"],
		JOY_BUTTON_DPAD_LEFT: [&"ui_left"],
		JOY_BUTTON_DPAD_RIGHT: [&"ui_right"],
		JOY_BUTTON_START: [KeysGamepad.PAUSE],
		JOY_BUTTON_Y: [KeysGamepad.CAMERA],
		JOY_BUTTON_X: [KeysGamepad.HIGH_BEAM],
		JOY_BUTTON_LEFT_SHOULDER: [PadNav.TAB_PREV],
		JOY_BUTTON_RIGHT_SHOULDER: [PadNav.TAB_NEXT],
		JOY_BUTTON_BACK: [PadNav.ROOM_MENU],
	}
	for b: JoyButton in cases:
		for device: int in [0, 1, PAD, 7]:
			var ev := InputEventJoypadButton.new()
			ev.button_index = b
			ev.pressed = true
			ev.device = device
			for action: StringName in cases[b]:
				check(ev.is_action_pressed(action), "pad %d button %d -> %s" % [device, b, action])
	var n := InputMap.action_get_events(&"ui_accept").size()
	PadNav.register_actions()
	KeysGamepad.register_actions()
	eq(InputMap.action_get_events(&"ui_accept").size(), n, "idempotent")


func test_drives_the_car_from_any_pad_device() -> void:
	var k := KeysGamepad.new()
	k.configure(t.controls, 1.0, t.controls.response_curve_exponent)
	var a := InputEventJoypadButton.new()
	a.button_index = JOY_BUTTON_A
	a.pressed = true
	a.device = PAD
	eq(k.handle_event(a), KeysGamepad.EDGE_BOOST, "A boosts from pad 2")
	var rt := InputEventJoypadMotion.new()
	rt.axis = JOY_AXIS_TRIGGER_RIGHT
	rt.axis_value = 1.0
	rt.device = PAD
	k.handle_event(rt)
	k.advance(1.0 / 120.0)
	eq(k.gas, 1.0, "RT from pad 2")


# ---------------------------------------------------------------- Title → hub

func test_title_to_online_hub_and_back_with_the_pad() -> void:
	var ts := _title()
	var tt := ts.title
	check(_focus() == null, "nothing focused before the pad is used")
	_press(JOY_BUTTON_DPAD_DOWN)
	_focused(tt.play_button, "the first press shows the focus on PLAY")
	check(tt.play_button.focus_shown(), "a visible focus ring")
	check(pad.active, "the pad drives the menus")
	_press(JOY_BUTTON_DPAD_UP)
	_focused(tt.daily_button, "up: DAILY DRIVE")
	_press(JOY_BUTTON_DPAD_UP)
	_focused(tt.online_button, "up: ONLINE")
	_press(JOY_BUTTON_DPAD_UP)
	_focused(tt.chip, "up from the column's top: the profile chip (top right)")
	_press(JOY_BUTTON_DPAD_LEFT)
	_focused(tt.online_button, "left: ONLINE again")
	_press(JOY_BUTTON_A)
	check(ts.online_hub.visible and not tt.visible, "A on ONLINE opens the hub")
	eq(_started, [] as Array[StringName], "nothing started")
	pad.refresh_focus()
	_focused(ts.online_hub.loop_button, "the hub starts on LOOP PRACTICE")
	for b in pad.scope_buttons():
		check(ts.online_hub.is_ancestor_of(b), "the scope is the hub's: %s" % b.name)
	_press(JOY_BUTTON_B)
	check(tt.visible and not ts.online_hub.visible, "B: back to the title")
	pad.refresh_focus()
	_focused(tt.play_button, "the title starts on PLAY again")
	_press(JOY_BUTTON_DPAD_RIGHT)
	_press(JOY_BUTTON_DPAD_DOWN)
	check(_focus() in [tt.boards_button, tt.settings_button, tt.garage_button, tt.achievements_button],
			"down from the column: the bottom row")
	_press(JOY_BUTTON_DPAD_UP)
	_press(JOY_BUTTON_A)
	eq(_started, [&"journey"] as Array[StringName], "A on PLAY starts the journey")


func test_left_stick_moves_once_then_repeats() -> void:
	var ts := _title()
	var tt := ts.title
	_stick(0.0, 0.9)
	_focused(tt.play_button, "pushed: the focus shows")
	_stick(0.0, 0.95)
	_focused(tt.play_button, "more of the same push: no second step")
	_stick(0.0, 0.0)
	_stick(0.0, -0.9)
	_focused(tt.daily_button, "pushed up: one step")
	pad._process(t.controls.pad_nav_repeat_delay_s + 0.01)
	Input.flush_buffered_events()
	_focused(tt.online_button, "held: repeats after the delay")
	_stick(0.0, 0.0)
	pad._process(t.controls.pad_nav_repeat_delay_s + 0.01)
	Input.flush_buffered_events()
	_focused(tt.online_button, "released: no more repeats")
	check(not Input.is_action_pressed(&"ui_up"), "the synthesized ui_up was released")


func test_a_touch_or_a_click_ends_the_pad_focus() -> void:
	var ts := _title()
	_press(JOY_BUTTON_DPAD_DOWN)
	check(_focus() != null)
	_tap(ts.title.logo)   # not a button
	check(_focus() == null, "a tap drops the pad's focus")
	check(not pad.active, "touch drives the menus again")
	_tap(ts.title.garage_button)
	check(_focus() == null, "a tapped button keeps no (hidden) focus")
	scans_stay_put(ts)


func scans_stay_put(_ts: TitleScreens) -> void:
	var n := pad.scans
	pad._process(1.0)
	eq(pad.scans, n, "no scope scans while touch drives the menus")


# ---------------------------------------------------------------- Pause, settings, results

func test_pause_menu_and_settings_with_the_pad() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	tree.paused = true
	s.finish_animations()
	var p := s.pause_screen
	pad.active = true
	pad.refresh_focus()
	_focused(p.resume_button, "the pause menu starts on RESUME")
	_press(JOY_BUTTON_DPAD_UP)
	_focused(p.settings_button, "up: SETTINGS (no RECALIBRATE without gyro)")
	_press(JOY_BUTTON_A)
	check(p.settings_open, "A opens the settings")
	pad.refresh_focus()
	check(p.is_ancestor_of(_focus()), "the focus moved into the settings view")
	var page := p.settings.page
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	eq(p.settings.page, page + 1, "RB: the next settings page")
	_press(JOY_BUTTON_LEFT_SHOULDER)
	eq(p.settings.page, page, "LB: back")
	_press(JOY_BUTTON_LEFT_SHOULDER)
	eq(p.settings.page, p.settings.tabs.size() - 1, "LB wraps to the last page")
	_press(JOY_BUTTON_B)
	check(not p.settings_open, "B closes the settings")
	pad.refresh_focus()
	_focused(p.resume_button)
	_press(JOY_BUTTON_A)
	eq(_intents, [&"resume"] as Array[StringName], "A on RESUME resumes")
	_press(JOY_BUTTON_B)
	eq(_intents, [&"resume", &"resume"] as Array[StringName], "B resumes too")


func test_results_with_the_pad() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.CRASH, Game.RESULTS)
	s.show_results(_results_payload())
	pad.active = true
	pad.refresh_focus()
	check(_focus() == null, "nothing to focus during the skip-tap guard")
	s.results_screen.accept_input_now()
	s.finish_animations()
	pad.refresh_focus()
	_focused(s.results_screen.retry_button, "RETRY first")
	_press(JOY_BUTTON_B)
	eq(_intents, [&"menu"] as Array[StringName], "B: MENU")
	_press(JOY_BUTTON_A)
	eq(_intents, [&"menu", &"retry"] as Array[StringName], "A on RETRY")


# ---------------------------------------------------------------- Scope

func test_scope_skips_covered_hidden_and_disabled_buttons() -> void:
	var root := Control.new()
	root.size = SCREEN.size
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.root.add_child(root)
	_nodes.append(root)
	var under := _plain_button(root, "UNDER", Vector2(100.0, 100.0))
	var hidden := _plain_button(root, "HIDDEN", Vector2(100.0, 300.0))
	hidden.visible = false
	var off := _plain_button(root, "OFF", Vector2(300.0, 300.0))
	off.disabled = true
	var free_b := _plain_button(root, "FREE", Vector2(100.0, 500.0))
	eq(pad.scope_buttons(), [under, free_b] as Array[ScreenButton], "visible, enabled")
	var panel := Control.new()   # a modal panel over the screen, with its own buttons
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.size = SCREEN.size
	root.add_child(panel)
	var ok := _plain_button(panel, "OK", Vector2(600.0, 300.0))
	var cancel := _plain_button(panel, "CANCEL", Vector2(600.0, 420.0))
	eq(pad.scope_buttons(), [ok, cancel] as Array[ScreenButton], "only the modal panel's")
	pad.active = true
	pad.refresh_focus()
	_focused(ok, "the top-left one first")
	_press(JOY_BUTTON_DPAD_LEFT)
	_focused(ok, "never onto a covered button")
	_press(JOY_BUTTON_DPAD_DOWN)
	_focused(cancel)
	var pressed: Array[String] = []
	cancel.pressed.connect(func() -> void: pressed.append("cancel"))
	_press(JOY_BUTTON_B)
	eq(pressed, ["cancel"] as Array[String], "B with no screen handling it: the CANCEL button")


func test_lb_rb_switch_the_top_option_row() -> void:
	var root := Control.new()   # a modal panel (takes touches over the screen)
	root.size = SCREEN.size
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	tree.root.add_child(root)
	_nodes.append(root)
	var tabs: Array[ScreenButton] = []
	for i in 3:
		var b := _plain_button(root, "TAB %d" % i, Vector2(100.0 + 200.0 * float(i), 60.0))
		b.kind = ScreenButton.Kind.OPTION
		b.selected = i == 0
		b.pressed.connect(func() -> void:
			for o in tabs:
				o.selected = o == b)
		tabs.append(b)
	var row: Array[ScreenButton] = []
	for i in 2:
		var b := _plain_button(root, "OPT %d" % i, Vector2(100.0 + 200.0 * float(i), 300.0))
		b.kind = ScreenButton.Kind.OPTION
		b.selected = i == 1
		row.append(b)
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	check(tabs[1].selected and not tabs[0].selected, "RB: the next tab of the top row")
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	check(tabs[0].selected, "wraps")
	check(row[1].selected, "a lower option row is not a tab row")


func test_garage_keeps_its_own_arrows() -> void:
	var ts := _title()
	ts.open_garage()
	ts.finish_animations()
	var g := ts.garage
	pad.active = true
	pad.refresh_focus()
	check(_focus() == null, "no focus in the garage")
	var tab := int(g.tab)
	_press(JOY_BUTTON_DPAD_DOWN)
	ne(int(g.tab), tab, "down: the garage's next tab")
	_press(JOY_BUTTON_LEFT_SHOULDER)
	eq(int(g.tab), tab, "LB: back a tab")
	_press(JOY_BUTTON_B)
	check(not g.visible and ts.title.visible, "B: DONE, back to the title")


func _plain_button(parent: Control, label: String, at: Vector2) -> ScreenButton:
	var b := ScreenButton.make(label, ScreenButton.Kind.NORMAL, 24)
	b.position = at
	b.size = Vector2(160.0, 80.0)
	parent.add_child(b)
	return b
