extends WBTest
## The online hub's party (N9.3) through iOS-style touch ids against a scripted server:
## PARTY → CREATE PARTY (the members, the hub's party line), JOIN PARTY by code, SHARE /
## COPY LINK, LEAVE PARTY, the leader removing a member with two taps, an invite arriving
## on the hub (ACCEPT joins with its code, DECLINE sends nothing), a party move handed to
## the run, the friends list's JOIN and INVITE seams, an invite link (`?room=`) joining the
## room or, when no room has that code, the party; and text fit: the party view with eight
## 16-W names and the hub's party line at 100 % / 125 % on 1280x720 and a notched 1560x720.
## Spec: multiplayer handoff → Rooms, parties and matchmaking (Parties, Friends and
## presence: Join button, Private rooms: invite links), Client changes (Party panel and
## friends list). docs/SCREENS.md → Online hub → Party (N9.3).

const FakePartyServer := preload("res://tests/net/fake_party_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
const IOS_ID := 1_893_457_201
const WIDE_NAME := "WWWWWWWWWWWWWWWW"

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rooms: NetRooms
var ts: TitleScreens
var ready_sessions: Array[NetRoomSession] = []
var social_views: Array[int] = []
var probe := HudTextProbe.new()


## Records what the page was asked to do: copy answers "ok", no share sheet.
class CopyBridge:
	extends NetJsBridge

	var copied: Array[String] = []

	func available() -> bool:
		return true

	func eval(code: String) -> Variant:
		if code.begins_with(SocialUi.JS_COPY.left(12)):
			copied.append(code)
			return SocialUi.JS_OK
		return false


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	ready_sessions.clear()
	social_views.clear()
	NetInviteLink.set_pending("")
	ts = TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	ts.set_screen(SCREEN, SCREEN)
	ts.show_state(Game.MENU)
	ts.online_hub.room_ready.connect(func(s: NetRoomSession) -> void: ready_sessions.append(s))
	ts.online_hub.social.connect(func(v: int) -> void: social_views.append(v))


func after_each() -> void:
	HudDraw.probe = null
	if ts != null and is_instance_valid(ts):
		ts.free()
	ts = null
	if rooms != null and is_instance_valid(rooms):
		rooms.free()
	rooms = null
	server = null
	link = null
	NetInviteLink.set_pending("")
	Settings.reset_to_defaults()


## A rooms service on the loopback link to the scripted party server; the hub open (its
## lobby connection up).
func _rooms() -> void:
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakePartyServer.new(link)
	rooms = NetRooms.new()
	rooms.standalone = true
	rooms.setup(null, link.client, net, time, RunLoop.loop_road(t).length())
	rooms.session.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rooms.set_process(false)
	tree.root.add_child(rooms)
	ts.online_hub.rooms = rooms
	ts.open_hub()
	ts.finish_animations()
	_net(0.3)


func _net(seconds: float) -> void:
	for i in roundi(seconds / 0.01):
		time.advance_s(0.01)
		server.call("poll")
		rooms.session.poll()


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _hub() -> OnlineHubScreen:
	return ts.online_hub


func _cmds() -> Array[Dictionary]:
	return server.get("party_commands")


func test_the_hub_opens_the_lobby_connection() -> void:
	_rooms()
	eq(rooms.session.state, NetRoomSession.State.LOBBY, "presence, party and invites need it")
	check(rooms.session.accept_follows, "party moves are taken while the hub shows")
	eq(_hub().party_line.text, OnlineHubScreen.TEXT_PARTY_NONE)
	ge(_hub().party_button.size.y, t.hud.touch_target_px)
	ts.open_title()
	check(not rooms.session.accept_follows, "not on the title")


func test_create_a_party_by_touch() -> void:
	_rooms()
	var hub := _hub()
	_tap(hub.party_button)
	var lp := hub.lobby
	check(lp.visible)
	eq(lp.view, RoomLobbyPanel.View.PARTY)
	eq(lp.note.text, RoomLobbyPanel.TEXT_PARTY_NONE)
	check(lp.join_party_button.visible and lp.action_button.visible)
	eq(lp.action_button.text, RoomLobbyPanel.TEXT_CREATE_PARTY)
	check(not lp.leave_party_button.visible)
	_tap(lp.action_button)
	eq(lp.status.text, RoomLobbyPanel.TEXT_CREATING_PARTY)
	_net(0.3)
	eq(_cmds().back()["kind"], "party_create")
	eq(lp.title.text, "PARTY  PQ7K2M")
	eq(lp.status.text, "", "the working line goes")
	check(lp.member_buttons[0].visible)
	eq(lp.member_buttons[0].text, "Zoe#0007")
	eq(lp.member_buttons[0].note, "LEADER  ·  YOU")
	check(not lp.member_buttons[1].visible)
	eq(lp.note.text, RoomLobbyPanel.TEXT_PARTY_ALONE)
	for b: ScreenButton in [lp.invite_button, lp.share_button, lp.leave_party_button]:
		check(b.visible, b.text)
	check(not lp.action_button.visible and not lp.join_party_button.visible)
	_tap(lp.back_button)
	check(not lp.visible)
	eq(hub.party_line.text, "1/8  ·  YOU LEAD")
	eq(hub.party_line.ink, ScreenText.Ink.ACCENT)


func test_join_a_party_by_code_and_leave_it() -> void:
	_rooms()
	var hub := _hub()
	var lp := hub.lobby
	_tap(hub.party_button)
	_tap(lp.join_party_button)
	eq(lp.view, RoomLobbyPanel.View.CODE)
	eq(lp.note.text, RoomLobbyPanel.TEXT_PARTY_CODE_NOTE)
	eq(lp.code_field.placeholder_text, RoomLobbyPanel.TEXT_PARTY_CODE_PH)
	_tap(lp.back_button)
	eq(lp.view, RoomLobbyPanel.View.PARTY, "BACK returns to the party view")
	_tap(lp.join_party_button)
	lp.code_field.text = "xy"
	_tap(lp.action_button)
	eq(lp.status.text, RoomLobbyPanel.TEXT_CODE_BAD)
	lp.code_field.text = "pq7-k2m"
	_tap(lp.action_button)
	_net(0.3)
	eq(_cmds().back(), {"type": "lobby_command", "kind": "party_join", "code": "PQ7K2M"})
	eq(lp.view, RoomLobbyPanel.View.PARTY)
	eq(lp.note.text, RoomLobbyPanel.TEXT_PARTY_MEMBER % "Dusty#1234")
	eq(lp.member_buttons[0].note, RoomLobbyPanel.TEXT_LEADER)
	check(lp.member_buttons[0].disabled, "only the leader removes members")
	_tap(lp.leave_party_button)
	_net(0.3)
	eq(_cmds().back()["kind"], "party_leave")
	check(not rooms.session.party.in_party())
	check(lp.join_party_button.visible, "CREATE / JOIN again")


func test_share_link_copies_the_invite_link() -> void:
	_rooms()
	var lp := _hub().lobby
	var bridge := CopyBridge.new()
	lp.bridge = bridge
	_tap(_hub().party_button)
	_tap(lp.action_button)
	_net(0.3)
	eq(lp.share_button.text, RoomLobbyPanel.TEXT_SHARE_LINK, "no server URL here: the code")
	_tap(lp.share_button)
	eq(bridge.copied.size(), 1)
	check(bridge.copied[0].contains("PQ7K2M"))
	eq(lp.status.text, RoomLobbyPanel.TEXT_COPIED)


func test_the_leader_removes_a_member_with_two_taps() -> void:
	_rooms()
	server.call("put_in_party", 3, true)
	_net(0.2)
	var lp := _hub().lobby
	_tap(_hub().party_button)
	eq(lp.note.text, RoomLobbyPanel.TEXT_PARTY_LEAD)
	var dusty := lp.member_buttons[0]
	eq(dusty.text, "Dusty#1234")
	check(not dusty.disabled)
	check(lp.member_buttons[1].disabled, "not yourself")
	_tap(dusty)
	eq(dusty.note, RoomLobbyPanel.TEXT_KICK)
	check(dusty.selected)
	check(_cmds().is_empty(), "one tap only arms it")
	_tap(dusty)
	_net(0.2)
	eq(_cmds().back(), {"type": "lobby_command", "kind": "party_kick", "account_id": FakePartyServer.LEADER_ID})
	eq(rooms.session.party.members.size(), 2)


func test_an_invite_on_the_hub_accept_and_decline() -> void:
	_rooms()
	var hub := _hub()
	var lp := hub.lobby
	server.call("push_invite", "42", "Dusty", 1234, "AAAAAA")
	_net(0.2)
	check(lp.visible, "the invite opens its card")
	eq(lp.view, RoomLobbyPanel.View.INVITE)
	eq(lp.status.text, "Dusty#1234 INVITES YOU")
	eq(lp.action_button.text, RoomLobbyPanel.TEXT_ACCEPT)
	eq(lp.back_button.text, RoomLobbyPanel.TEXT_DECLINE)
	_tap(lp.back_button)
	check(not lp.visible)
	check(_cmds().is_empty(), "declining sends nothing")
	eq(rooms.session.party.invites.size(), 0)
	server.call("push_invite", "42", "Dusty", 1234, "BBBBBB")
	_net(0.2)
	_tap(lp.action_button)
	_net(0.3)
	eq(_cmds().back(), {"type": "lobby_command", "kind": "party_join", "code": "BBBBBB"})
	eq(lp.view, RoomLobbyPanel.View.PARTY)
	check(rooms.session.party.in_party())
	# An invite that waited (the hub was not showing) is behind PARTY.
	lp.close()
	rooms.session.party_leave()
	_net(0.2)
	ts.open_title()
	server.call("push_invite", "57", "Ali", 12, "CCCCCC")
	_net(0.2)
	check(not lp.visible, "not on the hub: kept")
	ts.open_hub()
	ts.finish_animations()
	eq(hub.party_line.text, "Ali#0012 INVITES YOU")
	eq(hub.party_line.ink, ScreenText.Ink.GOLD)
	_tap(hub.party_button)
	eq(lp.view, RoomLobbyPanel.View.INVITE)


func test_a_party_move_goes_to_the_run() -> void:
	_rooms()
	server.call("put_in_party", 2)
	_net(0.2)
	server.call("move_party")
	_net(0.3)
	eq(ready_sessions.size(), 1, "the leader's room: room_ready")
	check(ready_sessions[0] == rooms.session)


func test_friends_join_and_invite_seams() -> void:
	_rooms()
	check(NetSocialClient.join_handler.is_valid(), "JOIN is live while the hub exists")
	check(NetSocialClient.invite_handler.is_valid())
	var f := NetSocialPlayer.new()
	f.account_id = "57"
	f.display_name = "Ali"
	f.status = NetSocialPlayer.IN_ROOM
	f.room_id = 12
	f.joinable = true
	ts.open_title()
	NetSocialClient.join_handler.call(f)
	check(_hub().visible, "JOIN brings the hub")
	var lp := _hub().lobby
	eq(lp.view, RoomLobbyPanel.View.STATUS)
	eq(lp.title.text, OnlineHubScreen.TEXT_FRIEND_ROOM)
	_net(0.3)
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins.back(), {"type": "lobby_command", "kind": "room_join_id", "room_id": 12})
	eq(ready_sessions.size(), 1)
	NetSocialClient.invite_handler.call(f)
	_net(0.2)
	eq(_cmds().back(), {"type": "lobby_command", "kind": "party_invite", "account_id": "57"})
	# The hub gone: the seams close.
	ts.free()
	check(not NetSocialClient.join_handler.is_valid())
	check(not NetSocialClient.invite_handler.is_valid())


func test_an_invite_link_joins_the_room_or_else_the_party() -> void:
	_rooms()
	ts.open_title()
	NetInviteLink.set_pending("abc-234")
	var hub := _hub()
	hub._process(0.0)
	check(hub.visible, "the link opens the hub")
	eq(hub.lobby.title.text, RoomLobbyPanel.TEXT_LINK)
	_net(0.3)
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins.back(), {"type": "lobby_command", "kind": "room_join_code", "code": "ABC234"})
	eq(ready_sessions.size(), 1)
	eq(NetInviteLink.peek(), "", "taken once")
	# No room with that code: the party's.
	rooms.session.leave()
	_net(0.2)
	server.set("refuse_join", "room_not_found")
	NetInviteLink.set_pending("PQ7K2M")
	hub._process(0.0)
	_net(0.5)
	eq(_cmds().back(), {"type": "lobby_command", "kind": "party_join", "code": "PQ7K2M"})
	eq(hub.lobby.view, RoomLobbyPanel.View.PARTY)
	check(rooms.session.party.in_party())
	# Neither: says so.
	rooms.session.party_leave()
	_net(0.2)
	server.set("refuse_join", "room_not_found")
	server.set("refuse_party", "party_not_found")
	NetInviteLink.set_pending("ZZZZZZ")
	hub._process(0.0)
	_net(0.5)
	eq(hub.lobby.status.text, RoomLobbyPanel.TEXT_LINK_NONE)
	eq(hub.lobby.status.ink, ScreenText.Ink.HOT)


func test_invite_friends_opens_the_friends_list() -> void:
	_rooms()
	server.call("put_in_party", 2, true)
	_net(0.2)
	_tap(_hub().party_button)
	_tap(_hub().lobby.invite_button)
	eq(social_views, [ProfilePanel.View.FRIENDS] as Array[int])
	check(not _hub().lobby.visible)


# ---------------------------------------------------------------- Text fit

func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for scale in t.hud.text_scales:
			out.append([full, safe, scale, "%dx%d text %d%%" % [size.x, size.y, roundi(scale * 100.0)]])
	return out


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


static func _buttons(n: Node, out: Array[ScreenButton]) -> void:
	if n is ScreenButton and (n as ScreenButton).is_visible_in_tree():
		out.append(n as ScreenButton)
	for ch in n.get_children():
		_buttons(ch, out)


static func _inside(inner: Rect2, outer: Rect2) -> bool:
	return outer.grow(TOL).encloses(inner)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TOL).intersects(b.grow(-TOL))


## Every visible text inside its box (its button or panel) and the safe area; every visible
## button a touch target inside the safe area; no two buttons overlap.
func _check_fit(root: Control, safe: Rect2, what: String) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame
	var buttons: Array[ScreenButton] = []
	_buttons(root, buttons)
	for b in buttons:
		ge(b.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
		check(_inside(b.get_global_rect(), safe), "%s: %s %s outside the safe area" % [what, b.name, b.get_global_rect()])
	for a in buttons.size():
		for c in range(a + 1, buttons.size()):
			check(not _overlap(buttons[a].get_global_rect(), buttons[c].get_global_rect()),
					"%s: %s overlaps %s" % [what, buttons[a].name, buttons[c].name])
	var n := 0
	for i in probe.size():
		var ci := probe.items[i] as Control
		if ci == null or not is_instance_valid(ci) or not ci.is_visible_in_tree() or not root.is_ancestor_of(ci):
			continue
		n += 1
		var g := probe.global_rect(i)
		check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
				"%s: '%s' runs out of %s" % [what, probe.texts[i], ci.name])
		check(_inside(g, safe), "%s: '%s' outside the safe area" % [what, probe.texts[i]])
	gt(n, 3, "%s: texts drawn" % what)


func test_party_views_fit_every_setting() -> void:
	HudDraw.probe = probe
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		if ts != null and is_instance_valid(ts):
			ts.free()
		if rooms != null and is_instance_valid(rooms):
			rooms.free()
		ts = TitleScreens.new()
		ts.persist_settings = false
		tree.root.add_child(ts)
		ts.set_screen(c[0], c[1])
		ts.show_state(Game.MENU)
		_rooms()
		ts.set_screen(c[0], c[1])
		var p := rooms.session.party
		p.me = "7"
		var members: Array[Dictionary] = []
		for i in net.party_max_members:
			members.append({"account_id": str(7 + i), "display_name": WIDE_NAME, "name_tag": 8888 - i})
		p.apply_state({"code": "WWWWWW", "leader": "8", "members": members})
		rooms.session.party.invites.clear()
		_hub().refresh()
		await _check_fit(_hub(), c[1], "%s hub" % c[3])
		var line := _hub().party_line
		check(line.text.ends_with(SocialUi.ELLIPSIS) or line.text.contains(WIDE_NAME), line.text)
		_hub().open_party()
		await _check_fit(_hub().lobby.panel, c[1], "%s party" % c[3])
		p.leader = "7"
		_hub().lobby._tap_member(1)
		await _check_fit(_hub().lobby.panel, c[1], "%s party leader" % c[3])
		_hub().lobby.close()
		p.add_invite({"from": {"account_id": "99", "display_name": WIDE_NAME, "name_tag": 9999}, "code": "WWWWWW"},
				0.0, net.party_invites_max)
		_hub().lobby.open_invite()
		await _check_fit(_hub().lobby.panel, c[1], "%s invite" % c[3])
		_hub().lobby.close()
