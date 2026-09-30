extends WBTest
## The social screens on a NetSession backed by the in-memory Social API (NetFakeSocial):
## the ACCOUNT panel's tabs, the friends list (presence, requests, JOIN seam, add with
## errors inline, remove / block with confirm steps, the blocked list), the crew screen
## (create / join errors, the role UI showing only allowed actions, confirm steps, the
## invite code, the season standing), the report dialog (reasons, confirm, rate limit),
## the web text prompt, key muting, touch targets, the pause-menu path and zero draw
## items when hidden. Touches go through Input.parse_input_event with an iOS-style id.
## Spec: multiplayer handoff → Friends and presence, Crews (persistent), Moderation →
## Report, Client changes (friends list, crew page). WP N9.2.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const AREA := Rect2(46.0, 150.0, 1188.0, 524.0)
const IOS_ID := 1_893_457_201
const ME := "41"

var hud: HudTuning
var ntuning: NetTuning
var fake: NetFakeSocial
var clock: NetVirtualTime
var session: NetSession
var panel: ProfilePanel
var _nodes: Array[Node] = []


class MockBridge:
	extends NetJsBridge
	var answer: Variant = null
	var evals: PackedStringArray = PackedStringArray()

	func available() -> bool:
		return true

	func eval(code: String) -> Variant:
		evals.append(code)
		return answer


func before_all() -> void:
	hud = Tuning.load_default().hud
	ntuning = NetTuning.load_default()


func before_each() -> void:
	tree.paused = false
	NetSocialClient.join_handler = Callable()
	NetSocialClient.invite_handler = Callable()
	fake = NetFakeSocial.new()
	clock = NetVirtualTime.new(1_000_000)
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), ntuning, clock, "https://social.test/api/v1", 4)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	await session.start()


func after_each() -> void:
	tree.paused = false
	NetSocialClient.join_handler = Callable()
	NetSocialClient.invite_handler = Callable()
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	session = null
	panel = null
	await tree.process_frame


func _panel() -> ProfilePanel:
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
	p.bind(session)
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


func _setup_friends() -> Dictionary:
	var ids := {
		"b": fake.add_player("Bravo", 7), "c": fake.add_player("Charlie", 12), "d": fake.add_player("Delta", 3),
		"e": fake.add_player("Echo", 44), "f": fake.add_player("Foxtrot", 5),
	}
	fake.befriend(ME, ids["b"])
	fake.befriend(ME, ids["c"])
	fake.befriend(ME, ids["d"])
	fake.set_presence(ids["b"], "online")
	fake.set_presence(ids["c"], "in_room", 12, true)
	fake.add_request(ids["e"], ME)
	fake.add_request(ME, ids["f"])
	return ids


func _friends() -> FriendsPanel:
	panel = _panel()
	_tap(panel.tabs[ProfilePanel.View.FRIENDS])
	return panel.friends


## The row of `account_id`, turning pages until it shows (null when on none).
func _row(fp: FriendsPanel, account_id: String) -> SocialRow:
	for pass_i in 2:
		for pg in fp._pages():
			if pass_i == 1:
				fp.page = pg
				fp.refresh()
			for r in fp.rows:
				if r.visible and r.player != null and r.player.account_id == account_id:
					return r
	return null


func _body(i: int = -1) -> Dictionary:
	var r: Dictionary = fake.requests[fake.requests.size() - 1 if i < 0 else i]
	return NetFakeAccounts._json(String(r["body"]))


## The last request to `path` with `method` ({} when none).
func _last_to(method: int, path: String) -> Dictionary:
	for i in range(fake.requests.size() - 1, -1, -1):
		var r: Dictionary = fake.requests[i]
		if r["path"] == path and r["method"] == method:
			return r
	return {}


# ---------------------------------------------------------------- Tabs

func test_tabs_switch_views() -> void:
	panel = _panel()
	for t in panel.tabs:
		check(t.visible, "%s tab" % t.text)
		ge(t.size.y, hud.touch_target_px)
		check(AREA.grow(1.0).encloses(t.get_rect()), "%s inside the area" % t.text)
	check(panel.tabs[0].selected)
	check(panel.name_text.visible and not panel.friends.visible)
	var n := fake.requests.size()
	_tap(panel.tabs[ProfilePanel.View.FRIENDS])
	eq(panel.view, ProfilePanel.View.FRIENDS)
	check(panel.friends.visible and not panel.crew.visible)
	check(not panel.name_text.visible and not panel.delete_button.visible and not panel.card.visible,
			"the account view hides")
	check(panel.tabs[1].selected and not panel.tabs[0].selected)
	eq(fake.count("/friends"), 1, "the list loads as the tab opens")
	eq(fake.count("/blocks"), 1)
	gt(fake.requests.size(), n)
	_tap(panel.tabs[ProfilePanel.View.CREW])
	check(panel.crew.visible and not panel.friends.visible)
	eq(fake.count("/crews/mine"), 1)
	_tap(panel.tabs[ProfilePanel.View.ACCOUNT])
	check(panel.name_text.visible and panel.delete_button.visible and not panel.crew.visible)
	# The profile's own layout moved under the tabs and still fits.
	for c: Control in [panel.name_edit, panel.save_button, panel.apple_button, panel.delete_button]:
		check(AREA.grow(1.0).encloses(c.get_rect()), "%s inside the area" % c.name)
		gt(c.position.y, panel.tabs[0].get_rect().end.y, "%s under the tabs" % c.name)
	panel.open()
	eq(panel.view, ProfilePanel.View.ACCOUNT, "reopening starts on ACCOUNT")


func test_no_session_has_no_tabs() -> void:
	var dead := session
	_nodes.erase(dead)
	dead.free()
	session = null
	check(NetSession.current == null)
	var root := Control.new()
	tree.root.add_child(root)
	_nodes.append(root)
	var p := ProfilePanel.new()
	root.add_child(p)
	var style := HudStyle.new()
	style.setup(UiTheme.load_theme(), hud, 1.0)
	p.setup(style, hud)
	p.layout(AREA)
	p.open()
	for t in p.tabs:
		check(not t.visible)
	eq(p.status_note.text, ProfilePanel.NOTE_NO_SESSION)


# ---------------------------------------------------------------- Friends

func test_friends_rows_show_presence_and_requests() -> void:
	var ids := _setup_friends()
	var fp := _friends()
	eq(fp.list_caption.text, "FRIENDS 3/100 · 2 ONLINE")
	var e := _row(fp, ids["e"])
	check(e != null, "incoming request row")
	eq(e.kind, FriendsPanel.K_INCOMING)
	eq(e.sub.text, FriendsPanel.SUB_INCOMING)
	check(e.button(FriendsPanel.A_ACCEPT) != null and e.button(FriendsPanel.A_MORE) != null)
	eq(fp.rows[0].player.account_id, ids["e"], "requests first")
	var c := _row(fp, ids["c"])
	eq(c.sub.text, FriendsPanel.SUB_IN_ROOM)
	eq(c.dot, SocialRow.Dot.IN_ROOM)
	eq(c.sub.ink, ScreenText.Ink.GOLD)
	var join := c.button(FriendsPanel.A_JOIN)
	check(join != null, "JOIN for a room with space")
	check(join.disabled, "no N5 yet: disabled")
	eq(join.note, FriendsPanel.LABEL_SOON)
	var b := _row(fp, ids["b"])
	eq(b.sub.text, FriendsPanel.SUB_ONLINE)
	eq(b.dot, SocialRow.Dot.ONLINE)
	check(b.button(FriendsPanel.A_JOIN) == null, "online, not in a room: no JOIN")
	var d := _row(fp, ids["d"])
	eq(d.sub.text, FriendsPanel.SUB_OFFLINE)
	eq(d.dot, SocialRow.Dot.OFFLINE)
	eq(d.title.text, "Delta")
	eq(d.tag.text, "#0003")
	var f := _row(fp, ids["f"])
	eq(f.sub.text, FriendsPanel.SUB_OUTGOING)
	check(f.button(FriendsPanel.A_CANCEL) != null)
	eq(panel.tabs[ProfilePanel.View.FRIENDS].note, "1 NEW", "the tab counts waiting requests")
	eq(fp.code_text.text, session.profile.full_name, "your own code shows")
	for r in fp.rows:
		if r.visible:
			ge(r.size.y, hud.touch_target_px)
			for btn in r.buttons:
				if btn.visible:
					ge(btn.size.y, hud.touch_target_px, "%s touch target" % btn.text)
					le(btn.get_global_rect().end.x, AREA.end.x + 1.0)


func test_join_seam_calls_the_handler() -> void:
	var ids := _setup_friends()
	var joined: Array[String] = []
	NetSocialClient.join_handler = func(p: NetSocialPlayer) -> void: joined.append("%s@%d" % [p.account_id, p.room_id])
	var fp := _friends()
	var join := _row(fp, ids["c"]).button(FriendsPanel.A_JOIN)
	check(not join.disabled and join.note.is_empty(), "enabled once N5 plugs in")
	_tap(join)
	eq(joined, ["%s@12" % ids["c"]] as Array[String])


## N9.3: INVITE on an online friend (not an offline one) while the hub's seam is set.
func test_invite_seam_calls_the_handler() -> void:
	var ids := _setup_friends()
	var fp := _friends()
	check(_row(fp, ids["b"]).button(FriendsPanel.A_INVITE) == null, "no INVITE without the seam")
	var invited: Array[String] = []
	NetSocialClient.invite_handler = func(p: NetSocialPlayer) -> void: invited.append(p.account_id)
	fp.refresh()
	var invite := _row(fp, ids["b"]).button(FriendsPanel.A_INVITE)
	if not check(invite != null, "an online friend can be invited"):
		return
	check(_row(fp, ids["d"]).button(FriendsPanel.A_INVITE) == null, "not an offline one")
	check(_row(fp, ids["c"]).button(FriendsPanel.A_JOIN) != null, "a friend in a joinable room: JOIN")
	ge(invite.size.y, hud.touch_target_px)
	_tap(invite)
	eq(invited, [ids["b"]] as Array[String])
	eq(fp.note.text, FriendsPanel.TEXT_INVITED % "Bravo")


func test_accept_cancel_and_add_friend_errors() -> void:
	var ids := _setup_friends()
	var fp := _friends()
	_tap(_row(fp, ids["e"]).button(FriendsPanel.A_ACCEPT))
	eq(fp.note.text, FriendsPanel.TEXT_NOW_FRIENDS)
	eq(_row(fp, ids["e"]).kind, FriendsPanel.K_FRIEND)
	_tap(_row(fp, ids["f"]).button(FriendsPanel.A_CANCEL))
	eq(fp.note.text, FriendsPanel.TEXT_CANCELLED)
	check(_row(fp, ids["f"]) == null)
	# Add a friend, with the server's answers inline.
	fp.field.text = "Nobody#0001"
	_tap(fp.send_button)
	eq(fp.note.text, NetSocialClient.TEXT["player_not_found"])
	eq(fp.note.ink, ScreenText.Ink.HOT)
	fp.field.text = "not a code"
	_tap(fp.send_button)
	eq(fp.note.text, NetSocialClient.TEXT["invalid_full_name"])
	fake.add_player("LoneWolf", 7)
	fp.field.text = "lonewolf#0007"
	fp.field.text_submitted.emit(fp.field.text)   # Enter on the keyboard
	eq(fp.note.text, FriendsPanel.TEXT_SENT)
	eq(fp.note.ink, ScreenText.Ink.ACCENT)
	eq(fp.field.text, "", "the field clears")
	fake.add_player("Rate", 1)
	fake.script(HTTPClient.METHOD_POST, "/friends/requests", 429,
			{"error": "rate_limited", "message": "x", "retry_after_secs": 600}, PackedStringArray(["Retry-After: 600"]))
	fp.field.text = "Rate#0001"
	_tap(fp.send_button)
	eq(fp.note.text, "Too many tries. Try again in 10 min.")


func test_remove_and_block_need_confirm() -> void:
	var ids := _setup_friends()
	var fp := _friends()
	_tap(_row(fp, ids["b"]).button(FriendsPanel.A_MORE))
	check(fp.sheet.visible, "the player's sheet")
	check(not fp.field.visible, "in place of the add form")
	eq(fp.sheet.ids(), [FriendsPanel.A_REMOVE, FriendsPanel.A_BLOCK, FriendsPanel.A_REPORT, FriendsPanel.A_BACK] as Array[StringName])
	eq(fp.sheet.title.text, "Bravo#0007")
	check(_row(fp, ids["b"]).selected)
	var n := fake.requests.size()
	_tap(fp.sheet.button(FriendsPanel.A_REMOVE))
	eq(fake.requests.size(), n, "asks first")
	check(fp.sheet.confirm_button.visible and fp.sheet.cancel_button.visible)
	eq(fp.sheet.question.text, FriendsPanel.ASK_REMOVE % "Bravo")
	ge(fp.sheet.confirm_button.size.y, hud.touch_target_px)
	_tap(fp.sheet.cancel_button)
	eq(fake.requests.size(), n, "cancel sends nothing")
	_tap(fp.sheet.button(FriendsPanel.A_REMOVE))
	_tap(fp.sheet.confirm_button)
	eq(fake.requests[n]["method"], HTTPClient.METHOD_DELETE)
	eq(fake.requests[n]["path"], "/friends/%s" % ids["b"])
	check(_row(fp, ids["b"]) == null)
	check(not fp.sheet.visible, "back to the add form")
	eq(fp.note.text, FriendsPanel.TEXT_REMOVED)
	# Block from the incoming request's sheet.
	_tap(_row(fp, ids["e"]).button(FriendsPanel.A_MORE))
	eq(fp.sheet.ids(), [FriendsPanel.A_DECLINE, FriendsPanel.A_BLOCK, FriendsPanel.A_REPORT, FriendsPanel.A_BACK] as Array[StringName])
	_tap(fp.sheet.button(FriendsPanel.A_BLOCK))
	_tap(fp.sheet.confirm_button)
	eq(NetFakeAccounts._json(String(_last_to(HTTPClient.METHOD_POST, "/blocks")["body"])), {"account_id": ids["e"]})
	check(_row(fp, ids["e"]) == null)
	eq(fp.mode_button.text, FriendsPanel.TEXT_BLOCKED % 1)
	# The blocked list, and unblocking.
	_tap(fp.mode_button)
	eq(fp.mode, FriendsPanel.Mode.BLOCKED)
	eq(fp.list_caption.text, FriendsPanel.TEXT_LIST_BLOCKED % 1)
	var br := _row(fp, ids["e"])
	check(br != null and br.button(FriendsPanel.A_UNBLOCK) != null)
	check(not fp.field.visible, "no add form on the blocked list")
	_tap(br.button(FriendsPanel.A_UNBLOCK))
	eq(fake.requests[fake.requests.size() - 1]["path"], "/blocks/%s" % ids["e"])
	eq(fp.empty_text.text, FriendsPanel.TEXT_EMPTY_BLOCKED)
	check(fp.empty_text.visible)
	_tap(fp.mode_button)
	eq(fp.mode, FriendsPanel.Mode.FRIENDS)


func test_presence_updates_the_rows() -> void:
	var ids := _setup_friends()
	var fp := _friends()
	check(session != null and NetSocialClient.of(session).watching, "the visible list watches presence")
	fake.set_presence(ids["d"], "online")
	clock.advance_s(ntuning.social_presence_poll_s + 0.1)
	fp._process(0.016)
	eq(fake.count("/presence"), 1)
	eq(_row(fp, ids["d"]).sub.text, FriendsPanel.SUB_ONLINE)
	eq(fp.list_caption.text, "FRIENDS 3/100 · 3 ONLINE")
	_tap(panel.tabs[ProfilePanel.View.ACCOUNT])
	check(not NetSocialClient.of(session).watching, "hidden: no polling")


func test_paging() -> void:
	for i in 12:
		fake.befriend(ME, fake.add_player("Pal%02d" % i, i))
	var fp := _friends()
	gt(fp.page_size, 2)
	check(fp.next_button.visible and fp.prev_button.visible)
	check(fp.prev_button.disabled)
	eq(fp.page_text.text, "1/%d" % ceili(12.0 / fp.page_size))
	var first := fp.rows[0].player.display_name
	_tap(fp.next_button)
	eq(fp.page, 1)
	ne(fp.rows[0].player.display_name, first)
	ge(fp.next_button.size.y, hud.touch_target_px)
	for r in fp.rows:
		if r.visible:
			check(AREA.grow(1.0).encloses(r.get_rect()), "%s inside the area" % r.name)


func test_friends_offline_says_so() -> void:
	await session.logout()
	var fp := _friends()
	check(fp.empty_text.visible)
	eq(fp.empty_text.text, NetSession.TEXT["not_signed_in"])
	check(fp.send_button.disabled)
	check(not fp.field.editable)


# ---------------------------------------------------------------- Report

func test_report_from_a_friend() -> void:
	var ids := _setup_friends()
	var fp := _friends()
	_tap(_row(fp, ids["b"]).button(FriendsPanel.A_MORE))
	_tap(fp.sheet.button(FriendsPanel.A_REPORT))
	var rd := panel.report
	check(rd.visible and not fp.visible, "the dialog over the list")
	eq(rd.name_text.text, "Bravo#0007")
	eq(rd.reason_buttons.size(), NetSocialClient.REPORT_REASONS.size())
	for b in rd.reason_buttons:
		ge(b.size.y, hud.touch_target_px)
	_tap(rd.send_button)
	eq(rd.note.text, ReportDialog.TEXT_PICK, "a reason first")
	eq(rd.step, ReportDialog.Step.PICK)
	_tap(rd.reason_buttons[0])
	check(rd.reason_buttons[0].selected)
	eq(rd.reason, "cheating")
	var n := fake.requests.size()
	_tap(rd.send_button)
	eq(rd.step, ReportDialog.Step.CONFIRM)
	eq(fake.requests.size(), n, "asks first")
	check(rd.confirm_button.visible and rd.back_button.visible)
	_tap(rd.back_button)
	eq(rd.step, ReportDialog.Step.PICK)
	_tap(rd.reason_buttons[3])
	_tap(rd.send_button)
	_tap(rd.confirm_button)
	eq(fake.requests[n]["path"], "/reports")
	eq(_body(n), {"target_account_id": ids["b"], "reason": "harassment", "context": {"source": "friends"}})
	eq(rd.step, ReportDialog.Step.SENT)
	eq(rd.note.text, ReportDialog.TEXT_SENT)
	check(rd.done_button.visible)
	_tap(rd.done_button)
	check(not rd.visible and fp.visible, "back to the list")


func test_report_rate_limit_feedback() -> void:
	var b := fake.add_player("Bravo", 7)
	fake.reports_per_day = 0
	panel = _panel()
	var rd := panel.report
	var social := NetSocialClient.of(session)
	rd.open_for(social, b, "Bravo#0007", {"source": "leaderboard", "board": "loop", "run_id": "9"})
	rd.choose("other")
	rd.send()
	await rd.confirm()
	eq(rd.last_result.error, NetApiResult.RATE_LIMITED)
	eq(rd.note.text, "Report limit reached. Try again in 24 h.")
	eq(rd.note.ink, ScreenText.Ink.HOT)
	eq(rd.step, ReportDialog.Step.PICK)
	check(rd.send_button.disabled, "no more tries until the wait ends")
	var n := fake.requests.size()
	rd.send()
	eq(fake.requests.size(), n)
	rd.cancel()
	check(not rd.visible)
	rd.open_for(social, b, "Bravo#0007")
	eq(rd.note.text, "Report limit reached. Try again in 24 h.", "reopening shows the wait")
	check(rd.send_button.disabled)
	clock.advance_s(social.report_wait_s() + 1.0)
	rd.open_for(social, b, "Bravo#0007")
	eq(rd.note.text, ReportDialog.TEXT_HINT)
	check(not rd.send_button.disabled)


# ---------------------------------------------------------------- Crew

func _crew() -> CrewPanel:
	panel = _panel()
	_tap(panel.tabs[ProfilePanel.View.CREW])
	return panel.crew


func test_crew_create_errors_and_success() -> void:
	var cp := _crew()
	check(cp.create_caption.visible and cp.join_caption.visible, "no crew: both forms")
	for c: Control in [cp.name_field, cp.tag_field, cp.create_button, cp.code_field, cp.join_button]:
		ge(c.size.y, hud.touch_target_px, "%s touch target" % c.name)
		check(AREA.grow(1.0).encloses(c.get_rect()), "%s inside the area" % c.name)
	cp.name_field.text = "Rude Boys"
	cp.tag_field.text = "RB"
	_tap(cp.create_button)
	eq(cp.create_note.text, "That crew name isn't allowed.")
	eq(cp.create_note.ink, ScreenText.Ink.HOT)
	cp.name_field.text = "Night Riders"
	cp.tag_field.text = "rude"
	_tap(cp.create_button)
	eq(cp.create_note.text, "That tag isn't allowed.")
	cp.tag_field.text = "N"
	_tap(cp.create_button)
	eq(cp.create_note.text, NetSocialClient.TEXT["invalid_crew_tag"])
	cp.tag_field.text = "nr"
	_tap(cp.create_button)
	check(not cp.create_caption.visible, "in a crew now")
	eq(cp.tag_text.text, "[NR]")
	eq(cp.name_text.text, "Night Riders")
	eq(cp.members_text.text, "1/16 MEMBERS · YOU: OWNER")
	eq(cp.code_text.text.length(), 8)
	eq(cp.season_text.text, CrewPanel.TEXT_SEASON_NONE % NetFakeSocial.PERIOD)
	check(cp.rotate_button.visible, "owner: NEW CODE")
	eq(cp.crew_actions.ids(), [CrewPanel.A_LEAVE, CrewPanel.A_DISBAND] as Array[StringName])
	eq(cp.note.text, CrewPanel.TEXT_CREATED)


func test_crew_join_by_code() -> void:
	var owner := fake.add_player("Owner", 1)
	var cid := fake.make_crew(owner, "Night Riders", "NR")
	fake.crew_scores[cid] = 183200
	var cp := _crew()
	cp.code_field.text = "WRONGCODE"
	_tap(cp.join_button)
	eq(cp.join_note.text, NetSocialClient.TEXT["invalid_invite_code"])
	cp.code_field.text = String((fake.crews[cid] as Dictionary)["code"]).to_lower()
	cp.code_field.text_submitted.emit(cp.code_field.text)
	eq(cp.members_text.text, "2/16 MEMBERS · YOU: MEMBER")
	eq(cp.season_text.text, "SEASON %s: #1 · 183,200" % NetFakeSocial.PERIOD, "the Loop crew standing")
	check(not cp.rotate_button.visible, "members can't rotate the code")
	eq(cp.crew_actions.ids(), [CrewPanel.A_LEAVE] as Array[StringName], "members can't disband")
	check(cp.row_of(owner) != null)
	eq(cp.row_of(owner).sub.text, "OWNER")
	eq(cp.row_of(ME).sub.text, "MEMBER · YOU")
	check(cp.row_of(ME).button(CrewPanel.A_MORE) == null, "no actions on yourself")


func test_crew_role_ui_shows_only_allowed_actions() -> void:
	var cid := fake.make_crew(ME, "Night Riders", "NR")
	var b := fake.add_player("Bravo", 7)
	var c := fake.add_player("Charlie", 8)
	var o := fake.add_player("Oscar", 9)
	fake.add_member(cid, b)
	fake.add_member(cid, c, NetCrew.OFFICER)
	var cp := _crew()
	var report := CrewPanel.A_REPORT
	var back := CrewPanel.A_BACK
	# Owner.
	_tap(cp.row_of(b).button(CrewPanel.A_MORE))
	eq(cp.sheet_actions(), [NetCrew.PROMOTE, NetCrew.TRANSFER, NetCrew.KICK, report, back] as Array[StringName])
	check(not cp.card.visible, "the sheet replaces the crew card")
	_tap(cp.sheet.button(back))
	_tap(cp.row_of(c).button(CrewPanel.A_MORE))
	eq(cp.sheet_actions(), [NetCrew.DEMOTE, NetCrew.TRANSFER, NetCrew.KICK, report, back] as Array[StringName])
	cp.sheet.press(back)
	# Officer.
	(fake.crew_members[ME] as Dictionary)["role"] = NetCrew.OFFICER
	fake.add_member(cid, o, NetCrew.OWNER)
	(fake.crews[cid] as Dictionary)["owner"] = o
	await cp.load_crew()
	eq(cp.members_text.text, "4/16 MEMBERS · YOU: OFFICER")
	check(cp.rotate_button.visible, "officers rotate the code")
	eq(cp.crew_actions.ids(), [CrewPanel.A_LEAVE] as Array[StringName])
	cp.select(cp.client.crew.member(b))
	eq(cp.sheet_actions(), [NetCrew.KICK, report, back] as Array[StringName])
	cp.select(cp.client.crew.member(c))
	eq(cp.sheet_actions(), [report, back] as Array[StringName], "officers can't touch officers")
	cp.select(cp.client.crew.member(o))
	eq(cp.sheet_actions(), [report, back] as Array[StringName])
	cp.sheet.press(back)
	# Member.
	(fake.crew_members[ME] as Dictionary)["role"] = NetCrew.MEMBER
	await cp.load_crew()
	check(not cp.rotate_button.visible)
	cp.select(cp.client.crew.member(b))
	eq(cp.sheet_actions(), [report, back] as Array[StringName])


func test_crew_actions_confirm_and_call() -> void:
	var cid := fake.make_crew(ME, "Night Riders", "NR")
	var b := fake.add_player("Bravo", 7)
	fake.add_member(cid, b)
	var cp := _crew()
	_tap(cp.row_of(b).button(CrewPanel.A_MORE))
	var n := fake.requests.size()
	_tap(cp.sheet.button(NetCrew.PROMOTE))
	eq(fake.requests.size(), n, "asks first")
	eq(cp.sheet.question.text, CrewPanel.ASK_PROMOTE % "Bravo")
	_tap(cp.sheet.confirm_button)
	eq(fake.requests[n]["path"], "/crews/%s/promote" % cid)
	eq(_body(n), {"account_id": b})
	eq(cp.row_of(b).sub.text, "OFFICER")
	check(not cp.sheet.visible and cp.card.visible)
	# Rotate the code.
	var old := cp.code_text.text
	_tap(cp.rotate_button)
	ne(cp.code_text.text, old)
	eq(cp.note.text, CrewPanel.TEXT_ROTATED)
	# Copy: the clipboard, with a note.
	var mb := MockBridge.new()
	mb.answer = "ok"
	cp.bridge = mb
	_tap(cp.copy_button)
	eq(cp.note.text, CrewPanel.TEXT_COPIED)
	check(mb.evals.size() > 0 and mb.evals[mb.evals.size() - 1].contains(cp.code_text.text), "the code goes to the page's clipboard")
	# Disband, confirmed.
	_tap(cp.crew_actions.button(CrewPanel.A_DISBAND))
	eq(cp.crew_actions.question.text, CrewPanel.ASK_DISBAND % "Night Riders")
	cp.client.crew_changed.emit()   # a refresh must not drop the pending confirm
	check(cp.crew_actions.confirm_button.visible)
	_tap(cp.crew_actions.confirm_button)
	eq(fake.requests[fake.requests.size() - 1]["method"], HTTPClient.METHOD_DELETE)
	check(cp.create_caption.visible, "no crew again")
	eq(cp.note.text, CrewPanel.TEXT_DISBANDED)


func test_leave_crew() -> void:
	var owner := fake.add_player("Owner", 1)
	var cid := fake.make_crew(owner, "Night Riders", "NR")
	fake.add_member(cid, ME)
	var cp := _crew()
	_tap(cp.crew_actions.button(CrewPanel.A_LEAVE))
	eq(cp.crew_actions.question.text, CrewPanel.ASK_LEAVE % "Night Riders")
	_tap(cp.crew_actions.confirm_button)
	eq(fake.requests[fake.requests.size() - 1]["path"], "/crews/%s/leave" % cid)
	check(cp.join_caption.visible)


func test_report_a_crew_member() -> void:
	var cid := fake.make_crew(ME, "Night Riders", "NR")
	var b := fake.add_player("Bravo", 7)
	fake.add_member(cid, b)
	var cp := _crew()
	_tap(cp.row_of(b).button(CrewPanel.A_MORE))
	_tap(cp.sheet.button(CrewPanel.A_REPORT))
	check(panel.report.visible and not cp.visible)
	panel.report.choose("offensive_name")
	panel.report.send()
	await panel.report.confirm()
	eq(_body(), {"target_account_id": b, "reason": "offensive_name", "context": {"source": "crew", "crew_id": cid}})
	panel.report.done()
	check(cp.visible)


# ---------------------------------------------------------------- Fields and keys

func test_web_prompt_fills_the_field() -> void:
	var fp := _friends()
	var mb := MockBridge.new()
	mb.answer = "  LoneWolf#0007 "
	fp.field.bridge = mb
	fp.field.prompt_mode = 1
	_tap(fp.field)
	eq(fp.field.prompts, 1, "one tap, one prompt")
	eq(fp.field.text, "LoneWolf#0007")
	check(mb.evals[0].contains("prompt") and mb.evals[0].contains(FriendsPanel.TEXT_PROMPT))
	check(not fp.field.has_focus())
	mb.answer = null
	_tap(fp.field)
	eq(fp.field.text, "LoneWolf#0007", "cancel keeps the text")
	fp.field.prompt_mode = 0
	check(not fp.field.uses_prompt())
	fp.field.prompt_mode = -1
	fp.field.bridge = NetJsBridge.new()
	check(not fp.field.uses_prompt(), "not on the web: typed as usual")


func test_typing_mutes_gameplay_keys() -> void:
	var hub := PlayerInput.new()
	tree.root.add_child(hub)
	_nodes.append(hub)
	var fp := _friends()
	panel.hub = hub
	fp.field.grab_focus()
	check(not hub.is_processing_input(), "keys go to the field only")
	fp.field.release_focus()
	check(hub.is_processing_input())
	_tap(panel.tabs[ProfilePanel.View.CREW])
	panel.crew.name_field.grab_focus()
	check(not hub.is_processing_input())
	panel.crew.visible = false
	check(hub.is_processing_input(), "hiding gives the keys back")


# ---------------------------------------------------------------- Pause menu

func test_pause_menu_path_and_nothing_drawn_when_hidden() -> void:
	_setup_friends()
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(SCREEN, SCREEN)
	s.show_state(Game.PAUSED)
	var pause := s.pause_screen
	pause.finish_animations()
	_tap(pause.settings_button)
	_tap(pause.account_button)
	pause.finish_animations()
	_tap(pause.profile.tabs[ProfilePanel.View.FRIENDS])
	pause.finish_animations()
	check(pause.profile.friends.is_visible_in_tree(), "pause → SETTINGS → ACCOUNT → FRIENDS")
	gt(pause.profile.friends.rows.size(), 0)
	check(pause.profile.friends.rows[0].is_visible_in_tree())
	_tap(pause.profile.tabs[ProfilePanel.View.CREW])
	check(pause.profile.crew.is_visible_in_tree())
	s.show_state(Game.RUNNING, Game.PAUSED)
	s.finish_animations()
	await tree.process_frame
	eq(s.visible_item_count(), 0, "gameplay: no screen item draws")
	check(not NetSocialClient.of(session).watching, "and presence polling stops")
