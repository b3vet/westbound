extends WBTest
## The ACCOUNT page's sign-in (WP N11; docs/NET_CLIENT.md → Account screen; docs/SCREENS.md
## → Account): SIGN IN WITH APPLE / GOOGLE linking with iOS-style touch ids, the signed-in
## state and the cloud line, the unlink confirm, a cancelled sheet, and the conflict
## chooser switching accounts; then text fit of every state with the widest names in the
## pause menu at 100 / 125 % text, both hands, on 1280x720, a notched 1560x720 and the
## phone's minimum left inset only (the web build rotated, Safari reporting nothing).
## Same rules as tests/ui/test_social_text_fit.gd, and every line shows whole.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const IOS_ID := 1_893_457_201
const TOL := 0.5
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const WIDE_NAME := "WWWWWWWWWWWWWWWW"

var t: Tuning
var probe := HudTextProbe.new()
var fake: NetFakeAccounts
var session: NetSession
var target: MemTarget
var _nodes: Array[Node] = []


class MemTarget:
	extends NetCloudSaveTarget
	var doc: Dictionary = SaveMigrations.fresh()

	func snapshot() -> Dictionary:
		return doc.duplicate(true)

	func can_apply() -> bool:
		return true

	func apply(d: Dictionary) -> bool:
		doc = d.duplicate(true)
		return true

	func read_only() -> bool:
		return false

	func idle() -> bool:
		return true


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	probe.clear()
	HudDraw.probe = probe
	fake = NetFakeAccounts.new()
	session = _device()
	await session.start()
	await session.load_providers()


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	session = null
	Settings.reset_to_defaults()


func _device() -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, NetSessionStore.new(), NetTuning.load_default(), NetVirtualTime.new(1),
			"https://account.test/api/v1", 7)
	s.unix_clock = func() -> float: return fake.now_s
	for p: String in NetIdentityProvider.ALL:
		var f := NetFakeIdentity.new(p)
		f.wait = func(_sec: float) -> void: await tree.process_frame
		s.identity[p] = f
	tree.root.add_child(s)
	_nodes.append(s)
	target = MemTarget.new()
	s.cloud.setup(s, target)
	s.cloud.set_process(false)
	return s


func _gid(p: String) -> NetFakeIdentity:
	return session.identity[p] as NetFakeIdentity


func _screens(full: Rect2, safe: Rect2, ts: float, left: bool) -> RunScreens:
	Settings.set_value(&"text_scale", ts)
	Settings.set_value(&"left_handed", left)
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(full, safe)
	s.show_state(Game.PAUSED)
	s.pause_screen.open_settings()
	s.pause_screen.toggle_account()
	s.pause_screen.profile.bind(session)
	s.pause_screen.profile.open()
	s.finish_animations()
	return s


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


func _settle(p: ProfilePanel) -> void:
	for i in 20:
		await tree.process_frame
		if not p.busy:
			break


func _full() -> Array:
	var full := Rect2(0.0, 0.0, 1280.0, 720.0)
	return [full, full]


# ---------------------------------------------------------------- Flows

func test_link_signed_in_state_and_unlink_with_taps() -> void:
	var c := _full()
	var s := _screens(c[0], c[1], 1.0, false)
	var p := s.pause_screen.profile
	check(not p.google_button.disabled, "Google is ready")
	eq(p.google_button.text, ProfilePanel.TEXT_GOOGLE)
	eq(p.cloud_text.text, ProfilePanel.TEXT_CLOUD_LINE % ProfilePanel.TEXT_CLOUD_OFF)
	_gid("google").sub = "g-ui"
	_tap(p.google_button)
	await _settle(p)
	check(session.profile.linked_google, "linked by a tap")
	eq(p.google_button.text, ProfilePanel.TEXT_GOOGLE_LINKED)
	eq(p.google_button.note, "P***@GMAIL.COM")
	eq(p.identity_note.text, ProfilePanel.TEXT_SIGNED_IN)
	session.storage_ok = true   # the memory store says "not saved" otherwise
	p.refresh()
	eq(p.status_note.text, ProfilePanel.NOTE_PROVIDER % "Google")
	await session.cloud.sync()
	p.refresh()
	eq(p.cloud_text.text, ProfilePanel.TEXT_CLOUD_LINE % ProfilePanel.TEXT_CLOUD_SYNCED)
	fake.now_s += 600.0
	p.refresh()
	eq(p.cloud_text.text, ProfilePanel.TEXT_CLOUD_LINE % (ProfilePanel.TEXT_CLOUD_SYNCED_AGO % 10))
	# Unlink: the confirm, then UNLINK.
	_tap(p.google_button)
	eq(p.unlinking, "google")
	check(p.unlink_button.is_visible_in_tree() and not p.google_button.is_visible_in_tree())
	eq(p.unlink_text_2.text, ProfilePanel.TEXT_UNLINK_LAST, "the last provider warns")
	_tap(p.unlink_cancel_button)
	eq(p.unlinking, "")
	_tap(p.google_button)
	_tap(p.unlink_button)
	await _settle(p)
	check(not session.profile.linked_google)
	eq(p.identity_note.text, ProfilePanel.TEXT_UNLINKED % "Google")
	eq(p.google_button.text, ProfilePanel.TEXT_GOOGLE)


func test_cancelled_sheet_and_errors() -> void:
	var c := _full()
	var s := _screens(c[0], c[1], 1.0, false)
	var p := s.pause_screen.profile
	_gid("apple").outcome = NetIdentityResult.CANCELLED
	_tap(p.apple_button)
	await _settle(p)
	eq(p.identity_note.text, ProfilePanel.TEXT_CANCELLED)
	_gid("apple").outcome = ""
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_LINK + "apple", 503, {"error": "provider_unavailable", "message": "x"})
	_tap(p.apple_button)
	await _settle(p)
	eq(p.identity_note.text, NetSession.TEXT["server_unavailable"])
	eq(p.identity_note.ink, ScreenText.Ink.HOT)


func test_conflict_chooser_switches_accounts() -> void:
	# The identity already has an account with cloud progress.
	var other := fake.add_account(WIDE_NAME, 8888)
	fake.link_direct(other, "google", "g-taken")
	fake.put_save_direct(other, {"version": 2, "stats": {"xp": 60629, "runs": 41}})
	var c := _full()
	var s := _screens(c[0], c[1], 1.0, false)
	var p := s.pause_screen.profile
	_gid("google").sub = "g-taken"
	_tap(p.google_button)
	await _settle(p)
	check(p.choosing, "the chooser shows")
	check(p.keep_button.is_visible_in_tree() and p.use_cloud_button.is_visible_in_tree())
	check(not p.delete_button.is_visible_in_tree(), "the rest of the column hides")
	eq(p.conflict_title.text, ProfilePanel.TEXT_CONFLICT_TITLE % "GOOGLE")
	check(p.conflict_cloud.text.contains("LEVEL 5") and p.conflict_cloud.text.contains("41 RUNS"),
			p.conflict_cloud.text)
	eq(p.conflict_cloud_name.text, WIDE_NAME + "#8888")
	_tap(p.conflict_cancel_button)
	check(not p.choosing)
	eq(p.identity_note.text, ProfilePanel.TEXT_UNCHANGED)
	_tap(p.google_button)
	await _settle(p)
	check(p.choosing)
	_tap(p.keep_button)
	await _settle(p)
	check(not p.choosing)
	eq(session.account_id(), other, "switched to the identity's account")
	eq(p.identity_note.text, ProfilePanel.TEXT_SWITCHED % session.profile.full_name)
	eq(session.cloud.next_mode, SaveMerge.Mode.KEEP_LOCAL)


# ---------------------------------------------------------------- Text fit

func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size: Vector2 in [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0), Vector2(1361.0, 720.0)]:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		var kind := "full"
		if size.x == 1560.0:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
			kind = "notch"
		elif size.x == 1361.0:
			var px_cm := PlayerInput.canvas_px_per_cm(t.controls, size, Vector2i.ZERO)
			safe = ScreenInsets.safe_rect(full, ScreenInsets.with_min_left(Vector4.ZERO,
					ScreenInsets.min_left_px(t.controls, px_cm)))
			kind = "left inset"
		for ts in t.hud.text_scales:
			for left: bool in [false, true]:
				out.append([full, safe, ts, left, "%dx%d %s text %d%% %s" % [size.x, size.y, kind,
						roundi(ts * 100.0), "left" if left else "right"]])
	return out


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


func _capture(root: Node) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame


static func _inside(inner: Rect2, outer: Rect2) -> bool:
	return outer.grow(TOL).encloses(inner)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TOL).intersects(b.grow(-TOL))


static func _container(ci: CanvasItem) -> Control:
	if ci is ScreenButton:
		return ci as Control
	var n := ci.get_parent()
	while n != null and not (n is RunScreen):
		if n is ScreenPanel or n is ScreenButton:
			return n as Control
		n = n.get_parent()
	return null


static func _controls(n: Node, out: Array[Control]) -> void:
	if (n is ScreenButton or n is LineEdit) and (n as Control).is_visible_in_tree():
		out.append(n as Control)
	for ch in n.get_children():
		_controls(ch, out)


func _check(screen: RunScreen, p: ProfilePanel, safe: Rect2, what: String) -> int:
	var ids: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and screen.is_ancestor_of(ci):
			ids.append(i)
	var controls: Array[Control] = []
	_controls(screen, controls)
	for i in ids:
		var ci := probe.items[i] as Control
		var g := probe.global_rect(i)
		if ci is ScreenText:
			check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
					"%s: '%s' (%s) runs out of its box" % [what, probe.texts[i], ci.name])
		var box := _container(ci)
		if box != null:
			check(_inside(g, box.get_global_rect()), "%s: '%s' runs out of %s" % [what, probe.texts[i], box.name])
		else:
			for b in controls:
				if b is ScreenButton:
					check(not _overlap(g, b.get_global_rect()), "%s: '%s' runs under %s" % [what, probe.texts[i], b.name])
		check(_inside(g, safe), "%s: '%s' %s outside the safe area" % [what, probe.texts[i], g])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			if probe.items[ids[a]] == probe.items[ids[b]] and probe.rects[ids[a]] == probe.rects[ids[b]]:
				continue
			check(not _overlap(probe.global_rect(ids[a]), probe.global_rect(ids[b])),
					"%s: '%s' overlaps '%s'" % [what, probe.texts[ids[a]], probe.texts[ids[b]]])
	for c in controls:
		check(_inside(c.get_global_rect(), safe), "%s: %s outside the safe area" % [what, c.name])
		if c.get_parent() is ProfilePanel:
			ge(c.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, c.name])
	for a in controls.size():
		for b in range(a + 1, controls.size()):
			check(not _overlap(controls[a].get_global_rect(), controls[b].get_global_rect()),
					"%s: %s overlaps %s" % [what, controls[a].name, controls[b].name])
	# The N11 lines show whole (never shortened).
	for st: ScreenText in [p.identity_note, p.cloud_text, p.conflict_title, p.conflict_device, p.conflict_cloud,
			p.conflict_device_name, p.conflict_cloud_name, p.name_text, p.tag_text,
			p.conflict_note, p.unlink_text_1, p.unlink_text_2, p.status_note]:
		if not st.is_visible_in_tree() or st.text.is_empty():
			continue
		var drawn := false
		for i in ids:
			drawn = drawn or (probe.items[i] == st and probe.texts[i] == st.text)
		check(drawn, "%s: '%s' shows whole" % [what, st.text])
	return ids.size()


func test_account_text_fits_every_state() -> void:
	var me := session.account_id()
	(fake.accounts[me] as Dictionary)["name"] = WIDE_NAME
	(fake.accounts[me] as Dictionary)["tag"] = 8887
	await session.retry()
	var other := fake.add_account(WIDE_NAME, 8888)
	fake.link_direct(other, "apple", "a-taken")
	fake.put_save_direct(other, {"version": 2, "stats": {"xp": 5512174, "runs": 99999}})
	var n := 0
	for c in _configs():
		var s := _screens(c[0], c[1], float(c[2]), bool(c[3]))
		var pause := s.pause_screen
		var p := pause.profile
		var safe: Rect2 = c[1]
		var what: String = c[4]
		await _capture(s)
		n += _check(pause, p, safe, "%s ready" % what)
		# Linked, synced, with the longest notes.
		if not session.profile.linked_google:
			_gid("google").sub = "g-fit"
			await p.tap_provider("google")
		await session.cloud.sync()
		p.refresh()
		for text: String in [ProfilePanel.TEXT_SIGNED_IN, NetSession.TEXT["last_sign_in_method"],
				NetSession.TEXT["provider_not_enabled"], NetSession.TEXT["cloud_save_newer"]]:
			p._note(p.identity_note, text, ScreenText.Ink.HOT)
			p.refresh()
			await _capture(s)
			n += _check(pause, p, safe, "%s linked '%s'" % [what, text])
		p.identity_note.text = ""
		# Unlink confirm (the last provider: two lines).
		p.tap_provider("google")
		await _capture(s)
		n += _check(pause, p, safe, "%s unlink confirm" % what)
		p.cancel_unlink()
		# The chooser for Apple, whose account has the most progress.
		_gid("apple").sub = "a-taken"
		await p.tap_provider("apple")
		check(p.choosing, "%s: chooser" % what)
		await _capture(s)
		n += _check(pause, p, safe, "%s chooser" % what)
		p._note(p.identity_note, NetSession.TEXT["id_token_expired"], ScreenText.Ink.HOT)
		p.refresh()
		await _capture(s)
		n += _check(pause, p, safe, "%s chooser error" % what)
		p.cancel_conflict()
		p.identity_note.text = ""
		_nodes.erase(s)
		s.free()
	gt(n, 0)
