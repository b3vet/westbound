extends WBTest
## The profile panel on a NetSession (fake accounts server): name#tag and status, rename
## with the server's errors inline, delete with a confirm step, Apple / Google as coming
## soon, the retry actions, touch targets, gameplay keys muted while typing, and the
## pause menu's ACCOUNT view. Touches go through Input.parse_input_event with an iOS-style
## id. Spec: multiplayer handoff → Client changes (Profile and account), Accounts
## (deletion reachable from the profile screen); plan MP-D2. WP N1.2.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const AREA := Rect2(46.0, 140.0, 1188.0, 534.0)
const IOS_ID := 1_893_457_201

var hud: HudTuning
var fake: NetFakeAccounts
var store: NetSessionStore
var session: NetSession
var panel: ProfilePanel
var _nodes: Array[Node] = []


func before_all() -> void:
	hud = Tuning.load_default().hud


func before_each() -> void:
	tree.paused = false
	fake = NetFakeAccounts.new()
	store = NetSessionStore.new()


func after_each() -> void:
	tree.paused = false
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	session = null
	panel = null
	await tree.process_frame


func _session() -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, store, NetTuning.load_default(), NetVirtualTime.new(1), "https://panel.test/api/v1", 2)
	s.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(s)
	_nodes.append(s)
	return s


func _panel(s: NetSession) -> ProfilePanel:
	var root := Control.new()
	root.size = SCREEN.size
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.root.add_child(root)
	_nodes.append(root)
	var p := ProfilePanel.new()
	p.size = SCREEN.size
	root.add_child(p)
	var style := HudStyle.new()
	style.setup(UiTheme.load_theme(), hud, 1.0)
	p.setup(style, hud)
	p.bind(s)
	p.layout(AREA)
	p.open()
	return p


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


func _online() -> void:
	session = _session()
	await session.start()
	panel = _panel(session)


func test_shows_name_tag_and_status() -> void:
	await _online()
	eq(panel.name_text.text, session.profile.display_name)
	eq(panel.tag_text.text, session.profile.tag_text())
	check(panel.tag_text.text.begins_with("#") and panel.tag_text.text.length() == 5, "#1234")
	eq(panel.status_text.text, "ONLINE")
	eq(panel.status_text.ink, ScreenText.Ink.ACCENT)
	check(panel.name_edit.visible and panel.save_button.visible, "rename row")
	check(not panel.retry_button.visible)
	check(panel.delete_button.visible)
	eq(panel.name_edit.max_length, session.tuning.display_name_max_chars)


func test_touch_targets_and_provider_states() -> void:
	await _online()
	for c: Control in [panel.name_edit, panel.save_button, panel.apple_button, panel.google_button,
			panel.delete_button]:
		ge(c.size.y, hud.touch_target_px, "%s touch target" % c.name)
		check(AREA.grow(1.0).encloses(c.get_rect()), "%s inside the area" % c.name)
	# N11: a native build without the sign-in plugins (headless tests): NOT IN THIS BUILD.
	for b: ScreenButton in [panel.apple_button, panel.google_button]:
		check(b.disabled, "%s disabled without a plugin" % b.text)
		eq(b.note, ProfilePanel.TEXT_NOT_HERE)
	var before := fake.requests.size()
	_tap(panel.apple_button)
	eq(fake.requests.size(), before, "a disabled provider: tapping does nothing")
	# A server without the providers set up: NOT SET UP.
	fake.providers_enabled = {"apple": false, "google": false}
	await session.load_providers(true)
	panel.refresh()
	for b: ScreenButton in [panel.apple_button, panel.google_button]:
		eq(b.note, ProfilePanel.TEXT_NOT_SET_UP)
		check(b.disabled)


func test_rename_shows_server_errors_inline_and_succeeds() -> void:
	await _online()
	panel.name_edit.text = "Rude Rider"
	_tap(panel.save_button)
	eq(panel.rename_note.text, NetSession.TEXT["name_not_allowed"])
	eq(panel.rename_note.ink, ScreenText.Ink.HOT)
	panel.name_edit.text = "a"
	_tap(panel.save_button)
	eq(panel.rename_note.text, NetSession.TEXT["invalid_name"])
	panel.name_edit.text = "Road Runner"
	_tap(panel.save_button)
	eq(panel.rename_note.text, ProfilePanel.TEXT_SAVED)
	eq(panel.name_text.text, "Road Runner")
	eq(panel.name_edit.text, "", "the field clears")
	panel.name_edit.text = "Another One"
	panel.name_edit.text_submitted.emit(panel.name_edit.text)   # Enter on the keyboard
	eq(panel.rename_note.text, NetSession.TEXT_COOLDOWN % 30)
	panel.open()
	eq(panel.rename_note.text, NetSession.TEXT_COOLDOWN % 30, "the hint shows the cooldown")
	eq(panel.rename_note.ink, ScreenText.Ink.MUTED)


func test_delete_needs_a_confirm_step() -> void:
	await _online()
	_tap(panel.delete_button)
	check(panel.confirming)
	check(panel.confirm_button.visible and panel.cancel_button.visible)
	check(not panel.delete_button.visible)
	ge(panel.confirm_button.size.y, hud.touch_target_px)
	_tap(panel.cancel_button)
	check(not panel.confirming)
	check(fake.accounts.has("41"), "cancel keeps the account")
	_tap(panel.delete_button)
	_tap(panel.confirm_button)
	check(not fake.accounts.has("41"), "deleted on the server")
	eq(store.load_data(), {}, "and on the device")
	eq(session.status, NetSession.Status.SIGNED_OUT)
	eq(panel.delete_note.text, ProfilePanel.TEXT_DELETED)
	eq(panel.status_text.text, "SIGNED OUT")
	eq(panel.name_text.text, ProfilePanel.TEXT_NO_ACCOUNT)
	check(panel.retry_button.visible)
	eq(panel.retry_button.text, ProfilePanel.TEXT_SIGN_IN)
	check(not panel.name_edit.visible)
	_tap(panel.retry_button)
	eq(session.status, NetSession.Status.ONLINE, "SIGN IN makes a new device account")
	ne(session.account_id(), "41")


func test_delete_error_is_shown() -> void:
	await _online()
	fake.offline = true
	_tap(panel.delete_button)
	_tap(panel.confirm_button)
	eq(panel.delete_note.text, NetSession.TEXT["network"])
	eq(panel.delete_note.ink, ScreenText.Ink.HOT)
	check(fake.accounts.has("41"))


func test_offline_and_failed_states() -> void:
	fake.offline = true
	session = _session()
	await session.start()
	panel = _panel(session)
	eq(panel.status_text.text, "OFFLINE")
	eq(panel.status_note.text, ProfilePanel.NOTE_OFFLINE)
	check(panel.retry_button.visible)
	check(not panel.new_account_button.visible)
	check(not panel.name_edit.visible, "no rename offline")
	check(not panel.delete_button.visible, "no delete offline")
	fake.offline = false
	_tap(panel.retry_button)
	eq(panel.status_text.text, "ONLINE", "TRY AGAIN signs in")
	# A stored account the server refuses: the error, TRY AGAIN and NEW ACCOUNT.
	(fake.accounts["41"] as Dictionary)["secret"] = "rotated-elsewhere"
	for t: String in fake.refresh_tokens:
		(fake.refresh_tokens[t] as Dictionary)["revoked"] = true
	await session.retry()
	eq(panel.status_text.text, "ACCOUNT ERROR")
	eq(panel.status_text.ink, ScreenText.Ink.HOT)
	eq(panel.status_note.text, NetSession.TEXT["invalid_credentials"])
	check(panel.retry_button.visible and panel.new_account_button.visible)
	ge(panel.new_account_button.size.y, hud.touch_target_px)
	_tap(panel.new_account_button)
	eq(session.status, NetSession.Status.ONLINE)


func test_banned_state() -> void:
	await _online()
	fake.ban("41", NetApiResult.BANNED_FOREVER)
	await session.retry()
	eq(panel.status_text.text, "SUSPENDED")
	eq(panel.status_note.text, NetSession.TEXT_BANNED_FOREVER)
	check(panel.delete_button.visible, "a banned player can still delete the account")


func test_no_session_says_so() -> void:
	check(NetSession.current == null, "no session left over")
	var p := _panel(null)
	check(not p.has_session())
	eq(p.status_note.text, ProfilePanel.NOTE_NO_SESSION)
	check(not p.delete_button.visible and not p.name_edit.visible)
	# The pause menu's ACCOUNT button only shows with a session.
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(SCREEN, SCREEN)
	s.show_state(Game.PAUSED)
	s.pause_screen.open_settings()
	check(not s.pause_screen.account_button.visible)


func test_typing_mutes_gameplay_keys() -> void:
	await _online()
	var hub := PlayerInput.new()
	tree.root.add_child(hub)
	_nodes.append(hub)
	panel.hub = hub
	check(hub.is_processing_input())
	panel.name_edit.grab_focus()
	check(not hub.is_processing_input(), "keys go to the text field only")
	panel.name_edit.release_focus()
	check(hub.is_processing_input())
	panel.name_edit.grab_focus()
	panel.visible = false
	check(hub.is_processing_input(), "hiding the panel gives the keys back")


func test_pause_menu_account_view() -> void:
	session = _session()
	await session.start()
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(SCREEN, SCREEN)
	s.show_state(Game.PAUSED)
	var pause := s.pause_screen
	pause.finish_animations()
	check(not pause.account_button.visible, "not in the pause menu itself")
	_tap(pause.settings_button)
	check(pause.account_button.visible, "ACCOUNT next to DONE")
	ge(pause.account_button.size.y, hud.touch_target_px)
	_tap(pause.account_button)
	pause.finish_animations()
	check(pause.profile.visible and not pause.settings.visible)
	eq(pause.title.text, PauseScreen.TEXT_ACCOUNT)
	eq(pause.profile.name_text.text, session.profile.display_name)
	eq(pause.account_button.text, PauseScreen.TEXT_SETTINGS)
	_tap(pause.account_button)
	check(pause.settings.visible and not pause.profile.visible, "back to the settings")
	_tap(pause.account_button)
	_tap(pause.done_button)
	check(not pause.profile.visible and not pause.settings_open, "DONE closes both")
	check(pause.resume_button.visible)
