extends WBTest
## Text fit for the social screens (WP N9.2): the friends list and its sheets, the
## blocked list, the crew page (no crew, in a crew, a member's sheet, a confirm step) and
## the report dialog, with the widest names and every player text, in the pause menu at
## both text sizes, both hands, on a 1280x720 and a notched 1560x720 canvas. Same rules as
## tests/ui/test_text_fit.gd (docs/HUD.md → Text fit): each drawn string sits inside its
## ScreenText, inside the panel or button it is drawn in, inside the safe area; no two
## overlap, and no text runs under a button. Notes and hints must also show whole (never
## shortened with "..."). Spec: UI, HUD and design system (Accessibility: text size 100% /
## 125%; safe areas); multiplayer handoff → Client changes.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
## The widest display name the rules allow (16 characters) and crew name (24).
const WIDE_NAME := "WWWWWWWWWWWWWWWW"
const WIDE_CREW := "WWWWWWWWWWWWWWWWWWWWWWWW"
const WIDE_TAG := "WWWW"

var t: Tuning
var probe := HudTextProbe.new()
var fake: NetFakeSocial
var session: NetSession
var _nodes: Array[Node] = []


class ShareBridge:
	extends NetJsBridge

	func available() -> bool:
		return true

	func eval(_code: String) -> Variant:
		return true


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	probe.clear()
	HudDraw.probe = probe
	fake = NetFakeSocial.new()
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), NetTuning.load_default(), NetVirtualTime.new(1),
			"https://fit.test/api/v1", 5)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	await session.start()


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	session = null
	Settings.reset_to_defaults()


func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in t.hud.text_scales:
			for left: bool in [false, true]:
				out.append([full, safe, ts, left, "%dx%d text %d%% %s" % [size.x, size.y, roundi(ts * 100.0),
						"left" if left else "right"]])
	return out


func _world() -> Dictionary:
	var me := session.account_id()
	var ids := {}
	for i in 5:
		ids[i] = fake.add_player(WIDE_NAME, 8888 - i)
	fake.befriend(me, ids[0])
	fake.befriend(me, ids[1])
	fake.befriend(me, ids[2])
	fake.set_presence(ids[0], "in_room", 12, true)
	fake.set_presence(ids[1], "online")
	fake.add_request(ids[3], me)
	fake.add_request(me, ids[4])
	fake.block_pair(me, fake.add_player(WIDE_NAME, 1))
	var other := fake.make_crew(ids[1], WIDE_CREW, WIDE_TAG)
	for id: String in [ids[0], ids[2], ids[3]]:
		fake.add_member(other, id)
	return ids


func _screens(c: Array) -> RunScreens:
	Settings.set_value(&"text_scale", float(c[2]))
	Settings.set_value(&"left_handed", bool(c[3]))
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(c[0], c[1])
	s.show_state(Game.PAUSED)
	s.pause_screen.open_settings()
	s.pause_screen.toggle_account()
	s.finish_animations()
	return s


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


func _capture(root: Node) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame


func _visible(root: Node) -> Array[int]:
	var out: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and root.is_ancestor_of(ci):
			out.append(i)
	return out


func _describe(i: int) -> String:
	return "'%s' (%s)" % [probe.texts[i], probe.items[i].name]


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


static func _buttons(n: Node, out: Array[ScreenButton]) -> void:
	if n is ScreenButton and (n as ScreenButton).is_visible_in_tree():
		out.append(n as ScreenButton)
	for ch in n.get_children():
		_buttons(ch, out)


## Every visible control of the screen with a rect: fields and buttons stay in the safe
## area and are at least a touch target tall.
static func _controls(n: Node, out: Array[Control]) -> void:
	if (n is ScreenButton or n is LineEdit) and (n as Control).is_visible_in_tree():
		out.append(n as Control)
	for ch in n.get_children():
		_controls(ch, out)


func _check(screen: RunScreen, safe: Rect2, what: String) -> int:
	var ids := _visible(screen)
	var buttons: Array[ScreenButton] = []
	_buttons(screen, buttons)
	for i in ids:
		var ci := probe.items[i] as Control
		var g := probe.global_rect(i)
		if ci is ScreenText:
			check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
					"%s: %s %s runs out of its box %s" % [what, _describe(i), probe.rects[i], ci.size])
		var box := _container(ci)
		if box != null:
			check(_inside(g, box.get_global_rect()),
					"%s: %s %s runs out of %s %s" % [what, _describe(i), g, box.name, box.get_global_rect()])
		else:
			for b in buttons:
				check(not _overlap(g, b.get_global_rect()), "%s: %s runs under %s" % [what, _describe(i), b.name])
		check(_inside(g, safe), "%s: %s %s outside the safe area" % [what, _describe(i), g])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			if probe.items[ids[a]] == probe.items[ids[b]] and probe.rects[ids[a]] == probe.rects[ids[b]]:
				continue   # one item drawn twice in the frame, not two texts
			check(not _overlap(probe.global_rect(ids[a]), probe.global_rect(ids[b])),
					"%s: %s overlaps %s" % [what, _describe(ids[a]), _describe(ids[b])])
	var controls: Array[Control] = []
	_controls(screen, controls)
	for c in controls:
		check(_inside(c.get_global_rect(), safe), "%s: %s %s outside the safe area" % [what, c.name, c.get_global_rect()])
		if c.get_parent() is ProfilePanel or c.get_parent() is SocialRow or c.get_parent() is FriendsPanel \
				or c.get_parent() is CrewPanel or c.get_parent() is SocialActions or c.get_parent() is ReportDialog:
			ge(c.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, c.name])
	for a in controls.size():
		for b in range(a + 1, controls.size()):
			check(not _overlap(controls[a].get_global_rect(), controls[b].get_global_rect()),
					"%s: %s overlaps %s" % [what, controls[a].name, controls[b].name])
	return ids.size()


func test_friends_text_fits_every_setting() -> void:
	var ids := _world()
	var n := 0
	for c in _configs():
		var s := _screens(c)
		var pause := s.pause_screen
		var p := pause.profile
		p.show_view(ProfilePanel.View.FRIENDS)
		var fp := p.friends
		var safe: Rect2 = c[1]
		await _capture(s)
		n += _check(pause, safe, "%s friends" % c[4])
		# Every friend-side player text shows whole in the note line.
		for code: String in ["player_not_found", "invalid_full_name", "requests_limit", "target_requests_limit",
				"request_not_found", "friend_not_found", "network", "rate_limited"]:
			var r := NetApiResult.failure(400, code)
			r.retry_after_s = 3000.0
			var text := NetSocialClient.error_text(r)
			fp._note(text, ScreenText.Ink.HOT)
			eq(fp.note.text, text, "%s: '%s' shows whole" % [c[4], text])
		await _capture(s)
		n += _check(pause, safe, "%s friends note" % c[4])
		fp._select(fp.client.friend(ids[0]), FriendsPanel.K_FRIEND)
		await _capture(s)
		n += _check(pause, safe, "%s friend sheet" % c[4])
		fp.sheet.press(FriendsPanel.A_BLOCK)
		await _capture(s)
		n += _check(pause, safe, "%s block confirm" % c[4])
		check(fp.sheet.question.text.ends_with(FriendsPanel.ASK_BLOCK.get_slice("%s", 1)),
				"%s: the question shows whole: %s" % [c[4], fp.sheet.question.text])
		fp.sheet.cancel()
		fp.sheet.press(FriendsPanel.A_BACK)
		fp.toggle_mode()
		await _capture(s)
		n += _check(pause, safe, "%s blocked list" % c[4])
		fp.toggle_mode()
		# The report dialog, each step.
		fp._select(fp.client.friend(ids[1]), FriendsPanel.K_FRIEND)
		fp.sheet.press(FriendsPanel.A_REPORT)
		var rd := p.report
		rd.choose("offensive_crew")
		await _capture(s)
		n += _check(pause, safe, "%s report" % c[4])
		rd.send()
		await _capture(s)
		n += _check(pause, safe, "%s report confirm" % c[4])
		await rd.confirm()
		await _capture(s)
		n += _check(pause, safe, "%s report sent" % c[4])
		rd.done()
		var limited := NetApiResult.failure(429, NetApiResult.RATE_LIMITED)
		limited.retry_after_s = 80000.0
		rd.open_for(fp.client, ids[1], WIDE_NAME + "#8887")
		rd._set_note(NetSocialClient.error_text(limited, true), ScreenText.Ink.HOT)
		await _capture(s)
		n += _check(pause, safe, "%s report limited" % c[4])
		eq(rd.note.text, NetSocialClient.error_text(limited, true), "%s: the limit shows whole" % c[4])
		rd.cancel()
		_free_screens(s)
	gt(n, 0)


func test_crew_text_fits_every_setting() -> void:
	var ids := _world()
	var n := 0
	for c in _configs():
		# No crew: both forms with their longest answers.
		fake.crew_members.erase(session.account_id())
		for id: String in fake.crews.keys():
			if (fake.crews[id] as Dictionary)["owner"] == session.account_id():
				fake.crews.erase(id)
		var s := _screens(c)
		var pause := s.pause_screen
		var p := pause.profile
		var safe: Rect2 = c[1]
		p.show_view(ProfilePanel.View.CREW)
		var cp := p.crew
		await cp.load_crew()
		await _capture(s)
		n += _check(pause, safe, "%s no crew" % c[4])
		for code: String in ["invalid_crew_name", "crew_name_not_allowed", "invalid_crew_tag", "crew_tag_not_allowed",
				"crew_name_taken", "crew_tag_taken", "already_in_crew"]:
			var text := NetSocialClient.error_text(NetApiResult.failure(400, code))
			cp._set_note(cp.create_note, text, ScreenText.Ink.HOT)
			eq(cp.create_note.text, text, "%s: '%s' shows whole" % [c[4], text])
		for code: String in ["invalid_invite_code", "crew_full", "already_in_crew"]:
			var text := NetSocialClient.error_text(NetApiResult.failure(400, code))
			cp._set_note(cp.join_note, text, ScreenText.Ink.HOT)
			eq(cp.join_note.text, text, "%s: '%s' shows whole" % [c[4], text])
		await _capture(s)
		n += _check(pause, safe, "%s no crew errors" % c[4])
		# In a crew, as its owner, with the widest name and tag, a share sheet and a rank.
		var cid := fake.make_crew(session.account_id(), WIDE_CREW.left(23) + "X", "QQQQ")
		for id: String in [ids[0], ids[2], ids[3], ids[4]]:
			fake.crew_members.erase(id)
			fake.add_member(cid, id, NetCrew.OFFICER if id == ids[0] else NetCrew.MEMBER)
		fake.crew_scores[cid] = 99_999_999
		cp.bridge = ShareBridge.new()
		await cp.load_crew()
		cp.refresh()
		check(cp.share_button.visible, "%s: SHARE where the browser has it" % c[4])
		await _capture(s)
		n += _check(pause, safe, "%s crew" % c[4])
		for code: String in ["not_permitted", "member_not_found", "cannot_change_own_role", "network"]:
			var text := NetSocialClient.error_text(NetApiResult.failure(400, code))
			cp._set_note(cp.note, text, ScreenText.Ink.HOT)
			eq(cp.note.text, text, "%s: '%s' shows whole" % [c[4], text])
		cp._set_note(cp.note, CrewPanel.TEXT_ROTATED, ScreenText.Ink.ACCENT)
		eq(cp.note.text, CrewPanel.TEXT_ROTATED)
		await _capture(s)
		n += _check(pause, safe, "%s crew note" % c[4])
		cp.crew_actions.press(CrewPanel.A_DISBAND)
		await _capture(s)
		n += _check(pause, safe, "%s disband confirm" % c[4])
		check(cp.crew_actions.question.text.ends_with("?"), "%s: the question ends whole" % c[4])
		cp.crew_actions.cancel()
		cp.select(cp.client.crew.member(ids[2]))
		await _capture(s)
		n += _check(pause, safe, "%s member sheet" % c[4])
		cp.sheet.press(NetCrew.TRANSFER)
		await _capture(s)
		n += _check(pause, safe, "%s transfer confirm" % c[4])
		check(cp.sheet.question.text.ends_with("?"), "%s: the question ends whole" % c[4])
		_free_screens(s)
		fake.crew_members.erase(session.account_id())
		fake.crews.erase(cid)
	gt(n, 0)


func _free_screens(s: RunScreens) -> void:
	_nodes.erase(s)
	s.free()
