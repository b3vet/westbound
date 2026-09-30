extends WBTest
## The title and the online hub on their own (WP8.5): the intents each button emits
## (iOS-id taps), the left-anchored thumb layout and touch targets, the profile chip
## (name#tag and the online status from the session), FRIENDS / CREW from the hub into the
## account view and back, the keys (Enter plays, Esc leaves the hub), the text size, the
## sky's accent, and nothing drawn when hidden. Spec: UI → Screens (Title); Design system;
## Accessibility; multiplayer handoff → Client changes (Online hub). docs/SCREENS.md →
## Title, Online hub.

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201

var t: Tuning
var fake: NetFakeSocial
var _nodes: Array[Node] = []
var _started: Array[StringName] = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	_started.clear()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.reset_to_defaults()


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


func _session() -> NetSession:
	fake = NetFakeSocial.new()
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, NetSessionStore.new(), NetTuning.load_default(), NetVirtualTime.new(1),
			"https://title.test/api/v1", 5)
	s.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(s)
	_nodes.append(s)
	await s.start()
	return s


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _key(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


# ---------------------------------------------------------------- Intents

func test_each_button_emits_its_intent() -> void:
	var ts := _title()
	var tt := ts.title
	_tap(tt.play_button)
	_tap(tt.daily_button)
	eq(_started, [RunContext.MODE_JOURNEY, RunContext.MODE_DAILY] as Array[StringName], "PLAY, DAILY DRIVE")
	_tap(tt.online_button)
	check(ts.online_hub.visible and not tt.visible, "ONLINE opens the hub")
	_tap(ts.online_hub.loop_button)
	eq(_started.back(), Run.MODE_LOOP, "LOOP PRACTICE: loop mode")
	eq(TitleScreens.MODE_LOOP, Run.MODE_LOOP)
	_tap(ts.online_hub.back_button)
	check(tt.visible and not ts.online_hub.visible, "BACK")
	_tap(tt.garage_button)
	eq(_started.size(), 3, "GARAGE starts no run")
	check(ts.garage != null and ts.garage.visible and not tt.visible, "GARAGE opens the garage (WP8.2)")
	_tap(ts.garage.done_button)
	check(tt.visible and not ts.garage.visible, "DONE: back to the title")


func test_keys_play_and_leave_the_hub() -> void:
	var ts := _title()
	_key(&"ui_accept")
	eq(_started, [RunContext.MODE_JOURNEY] as Array[StringName], "Enter plays")
	ts.open_hub()
	_key(&"ui_cancel")
	check(ts.title.visible and not ts.online_hub.visible, "Esc leaves the hub")


func test_left_anchored_thumb_layout_and_touch_targets() -> void:
	var ts := _title()
	var tt := ts.title
	var left := SCREEN.position.x + t.hud.layout_grid_px
	for b: ScreenButton in [tt.play_button, tt.daily_button, tt.online_button, tt.boards_button]:
		near(b.position.x, left, 0.5, "%s is left-anchored on the grid" % b.text)
	for b: ScreenButton in [tt.play_button, tt.daily_button, tt.online_button, tt.boards_button, tt.settings_button,
			tt.garage_button, tt.chip]:
		ge(b.size.y, t.hud.touch_target_px, "%s is a touch target" % b.name)
	near(tt.play_button.size.y, t.hud.primary_button_size_px.y, 0.5, "PLAY is the primary size")
	gt(tt.play_button.position.y, tt.online_button.position.y, "PLAY nearest the thumb in the column")
	gt(tt.boards_button.position.y, tt.play_button.position.y, "the row along the bottom")
	lt(tt.logo.position.y, tt.online_button.position.y, "the logo on top")
	near(tt.chip.get_global_rect().end.x, SCREEN.end.x - t.hud.layout_grid_px, 0.5, "the chip top-right")
	check(tt.logo.material != null, "the logo is speed-tilted")
	eq(tt.logo.face, ScreenText.Face.DISPLAY, "in Chakra Petch (the display face)")


func test_settings_and_account_views() -> void:
	var ts := _title()
	var tt := ts.title
	tt.open_settings()
	check(tt.settings.visible and tt.done_button.visible, "the settings grid and DONE")
	check(not tt.account_button.visible, "no ACCOUNT without a session")
	eq(tt.logo.text, TitleScreen.TEXT_SETTINGS)
	_tap(tt.settings.tabs[SettingsPanel.PAGE_AUDIO])
	eq(tt.settings.page, SettingsPanel.PAGE_AUDIO, "the AUDIO page")
	var writes := tt.settings.writes
	var tapped := false
	for row in tt.settings.rows:
		for b in row.buttons:
			if not tapped and b.is_visible_in_tree() and not b.selected and not b.disabled:
				_tap(b)
				tapped = true
	check(tapped, "an option to tap")
	gt(tt.settings.writes, writes, "a row writes Settings")
	check(tt.settings_dirty)
	_tap(tt.done_button)
	check(not tt.settings_open and tt.play_button.visible, "DONE: the menu")
	eq(tt.logo.text, TitleScreen.TEXT_LOGO)
	check(not tt.settings_dirty, "saved on DONE")


func test_profile_chip_follows_the_session() -> void:
	var ts := _title()
	var chip := ts.title.chip
	eq(chip.full_name, TitleProfileChip.TEXT_PLAYER)
	eq(chip.status_text, TitleProfileChip.TEXT_NO_SESSION, "no session: ONLINE OFF")
	var s: NetSession = await _session()
	ts.show_state(Game.MENU)
	check(s.is_online(), "the fake server signs in")
	eq(chip.full_name, s.profile.full_name, "name#tag")
	check(chip.full_name.contains("#"))
	eq(chip.status_text, "ONLINE")
	eq(chip.status_color(), ts.style.accent)
	s.profile.full_name = "WWWWWWWWWWWWWWWW#8888"
	s.profile_changed.emit(s.profile)
	eq(chip.full_name, "WWWWWWWWWWWWWWWW#8888", "follows profile_changed")
	le(chip.size.x, t.hud.title_chip_max_width_px + 0.5)
	s.status = NetSession.Status.OFFLINE
	s.status_changed.emit(s.status)
	eq(chip.status_text, "OFFLINE", "follows status_changed")
	_tap(chip)
	check(ts.title.settings_open and ts.title.account_open and ts.title.profile.visible, "a tap opens ACCOUNT")


func test_hub_friends_and_crew_open_the_account_tabs_and_come_back() -> void:
	var ts := _title()
	ts.open_hub()
	var hub := ts.online_hub
	check(hub.friends_button.disabled and hub.crew_button.disabled, "no session: FRIENDS / CREW off")
	eq(hub.status.text, OnlineHubScreen.TEXT_NO_SESSION)
	check(not hub.loop_button.disabled, "LOOP PRACTICE works offline")
	await _session()
	ts.open_title()
	ts.open_hub()
	ts.finish_animations()
	check(not hub.friends_button.disabled, "a session: FRIENDS")
	_tap(hub.friends_button)
	var tt := ts.title
	check(tt.visible and tt.account_open and not hub.visible, "the account view")
	eq(tt.profile.view, ProfilePanel.View.FRIENDS, "on the FRIENDS tab")
	_tap(tt.done_button)
	check(hub.visible and not tt.visible, "DONE: back to the hub")
	_tap(hub.crew_button)
	eq(tt.profile.view, ProfilePanel.View.CREW, "CREW")
	_tap(tt.done_button)
	_tap(hub.boards_button)
	check(hub.leaderboards_open(), "LEADERBOARDS from the hub")
	eq(hub.leaderboards.board, NetBoards.LOOP, "on the Loop board")
	hub.leaderboards.close_by_player()
	check(hub.loop_button.visible, "BACK: the hub")


func test_text_size_restyles_and_accent_follows() -> void:
	var ts := _title()
	var h100 := ts.title.logo.get_combined_minimum_size().y
	Settings.set_value(&"text_scale", 1.25)
	var h125 := ts.title.logo.get_combined_minimum_size().y
	within_pct(h125 / h100, 1.25, 0.05, "the logo grows with the text size")
	near(ts.title.play_button.size.y, t.hud.primary_button_size_px.y, 0.5, "touch targets do not")
	ts.set_accent(Color(1.0, 0.4, 0.2))
	eq(ts.style.accent, Color(1.0, 0.4, 0.2))


func test_hidden_title_draws_nothing() -> void:
	var ts := _title()
	gt(ts.visible_item_count(), 0)
	ts.show_state(Game.COUNTDOWN)
	eq(ts.visible_item_count(), 0, "outside MENU nothing draws")
	for s in ts.screens:
		check(not s.visible)
		eq(s.modulate.a, 1.0, "hidden, not transparent")
	check(not ts.is_open())
