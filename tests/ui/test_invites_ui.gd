extends WBTest
## Room and crew invites on screen (protocol 2), through iOS-style touch ids: the room
## menu's INVITE tab (online friends and crewmates, deduplicated, without the room's
## members; a tap sends room_invite and shows INVITED; the server's refusal in hot text;
## the link row stays; text fit at 100 % / 125 % on 1280x720 and a notched 1560x720); the
## online hub's ROOM INVITE card (JOIN by its code, DECLINE sends nothing, the gold note)
## and its gold crew invite line; the invite toast on the title (JOIN goes through the hub's
## join by code; LATER leaves it for the hub) and in a single-player run (a note, no
## buttons, gone after invite_toast_s); the crew page's INVITE FRIENDS (INVITE, INVITED) and
## the invites waiting for you (JOIN, DECLINE, "leave your crew first"). Spec: multiplayer
## handoff → Rooms, parties and matchmaking (Private rooms, Friends and presence, Crews);
## the owner's requests. docs/ROOMS_CLIENT.md → Room invites; NET_CLIENT.md → Crew invites.

const FakeInviteServer := preload("res://tests/net/fake_invite_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const AREA := Rect2(46.0, 150.0, 1188.0, 524.0)
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
const IOS_ID := 1_893_457_201
const ME := "41"
const WIDE := "WWWWWWWWWWWWWWWW"

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var rooms: NetRooms
var fake: NetFakeSocial
var session: NetSession
var social: NetSocialClient
var hud: RoomHud
var ts: TitleScreens
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	fake = NetFakeSocial.new()
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), net, NetVirtualTime.new(1_000_000),
			"https://invites.test/api/v1", 6)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	await session.start()
	social = NetSocialClient.of(session)
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(7))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeInviteServer.new(link)


func after_each() -> void:
	HudDraw.probe = null
	for n: Node in [hud, ts, rooms]:
		if n != null and is_instance_valid(n):
			n.free()
	hud = null
	ts = null
	rooms = null
	rs = null
	server = null
	link = null
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	session = null
	social = null
	NetInviteLink.set_pending("")
	Settings.reset_to_defaults()
	await tree.process_frame


func _net(seconds: float) -> void:
	for i in roundi(seconds / 0.01):
		time.advance_s(0.01)
		server.call("poll")
		if rooms != null:
			rooms.session.poll()
		elif rs != null:
			rs.poll()


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


## Friends A (online), B (offline), C (online, also a crewmate), crewmate D (online) and
## crewmate E (offline); Dusty#1234 (the room's other member, a friend, online).
func _people() -> Dictionary:
	# The room snapshot's other member is account 42 (fake_room_server.gd): the first account
	# made after this player's (41).
	var dusty := fake.add_player("Dusty", 1234)
	eq(dusty, "42")
	var ids := {
		"a": fake.add_player("Alpha", 1), "b": fake.add_player("Bravo", 2), "c": fake.add_player("Charlie", 3),
		"d": fake.add_player("Delta", 4), "e": fake.add_player("Echo", 5), "dusty": dusty,
	}
	for k: String in ["a", "b", "c", "dusty"]:
		fake.befriend(ME, ids[k])
	var crew := fake.make_crew(ME, "My Crew", "MY")
	for k: String in ["c", "d", "e"]:
		fake.add_member(crew, ids[k])
	for k: String in ["a", "c", "d", "dusty"]:
		fake.set_presence(ids[k], "online")
	return ids


# ---------------------------------------------------------------- Room menu INVITE

func _seated_hud(full: Rect2 = SCREEN, safe: Rect2 = SCREEN) -> void:
	if rs == null:
		rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
		rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
		rs.join_code("ABC234")
		_net(0.5)
		eq(rs.state, NetRoomSession.State.IN_ROOM)
	if hud != null and is_instance_valid(hud):
		hud.free()
	hud = RoomHud.new()
	tree.root.add_child(hud)
	hud.setup(net, rs)
	hud.set_screen(full, safe)
	hud.menu.social = social
	hud.menu.invite_url = "https://westbound.sipsakrandevu.com/r/ABC234"
	hud.advance(0.0)


func _invite_tab() -> RoomMenu:
	_tap(hud.room_button)
	_tap(hud.menu.invite_tab)
	hud.menu.refresh()
	return hud.menu


func _shown_ids(m: RoomMenu) -> Array[String]:
	var out: Array[String] = []
	for i in m.invite_buttons.size():
		if m.invite_buttons[i].visible:
			out.append(m.invite_ids[i])
	return out


func test_the_invite_tab_lists_online_friends_and_crew_once() -> void:
	var ids := _people()
	_seated_hud()
	var m := _invite_tab()
	eq(m.tab, RoomMenu.Tab.INVITE)
	check(m.link_text.visible and m.copy_button.visible, "the link row stays for anyone else")
	eq(_shown_ids(m), [ids["a"], ids["c"], ids["d"]] as Array[String],
		"online friends, then online crewmates; C once; offline and room members left out")
	eq(m.invite_buttons[0].text, "Alpha#0001")
	check(m.invite_buttons[0].note.begins_with(RoomMenu.TEXT_FRIEND))
	check(m.invite_buttons[2].note.begins_with(RoomMenu.TEXT_CREWMATE), m.invite_buttons[2].note)
	eq(m.invite_note.text, RoomMenu.TEXT_INVITE_HINT)
	# A tap invites: room_invite with the account, then INVITED (not sent twice).
	_tap(m.invite_buttons[1])
	_net(0.2)
	var sent: Array[Dictionary] = server.get("room_invites")
	eq(sent.size(), 1)
	eq(sent[0], {"type": "lobby_command", "kind": "room_invite", "account_id": ids["c"]})
	check(m.invite_buttons[1].note.ends_with(RoomMenu.TEXT_INVITED), m.invite_buttons[1].note)
	check(m.invite_buttons[1].disabled)
	eq(m.invite_note.text, RoomMenu.TEXT_INVITE_SENT % "Charlie#0003")
	_tap(m.invite_buttons[1])
	_net(0.2)
	eq((server.get("room_invites") as Array).size(), 1, "INVITED does not send again")
	# The server refuses the next one: its reason in hot text, and the player can be tried
	# again.
	server.set("refuse_invite", "not_allowed")
	server.set("refuse_detail", "That player is offline.")
	_tap(m.invite_buttons[0])
	_net(0.2)
	eq(m.invite_note.text, "THAT PLAYER IS OFFLINE.")
	eq(m.invite_note.ink, ScreenText.Ink.HOT)
	m.refresh()
	check(not m.invite_buttons[0].disabled, "a refused invite can be tried again")
	# Presence: A goes offline and leaves the list.
	social.apply_presence([{"account_id": ids["a"], "status": "offline", "room_id": 0, "joinable": false}])
	m.refresh()
	check(not _shown_ids(m).has(ids["a"]))


func test_the_invite_tab_without_anyone_online_or_signed_out() -> void:
	_seated_hud()
	var m := _invite_tab()
	eq(_shown_ids(m), [] as Array[String])
	eq(m.invite_note.text, RoomMenu.TEXT_INVITE_NONE)
	m.social = NetSocialClient.new(null, net)
	m.close()
	m.open(RoomMenu.Tab.INVITE)
	m.refresh()
	eq(m.invite_note.text, RoomMenu.TEXT_INVITE_OFFLINE)


func test_the_invite_tab_fits() -> void:
	for i in RoomMenu.INVITE_SLOTS + 2:
		var id := fake.add_player(WIDE, 9000 + i)
		fake.befriend(ME, id)
		fake.set_presence(id, "online")
	HudDraw.probe = probe
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for scale in t.hud.text_scales:
			Settings.set_value(&"text_scale", float(scale))
			_seated_hud(full, safe)
			hud.menu.open(RoomMenu.Tab.INVITE)
			hud.menu.refresh()
			eq(_shown_ids(hud.menu).size(), RoomMenu.INVITE_SLOTS)
			await _check_fit(hud.menu, safe, "%dx%d text %d%%" % [size.x, size.y, roundi(scale * 100.0)])
			hud.menu.close()


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


func _check_fit(root: Control, safe: Rect2, what: String) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame
	var buttons: Array[ScreenButton] = []
	_buttons(root, buttons)
	for b in buttons:
		ge(b.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
		check(_inside(b.get_global_rect(), safe), "%s: %s outside the safe area" % [what, b.name])
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
		check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
				"%s: '%s' runs out of %s" % [what, probe.texts[i], ci.name])
		check(_inside(probe.global_rect(i), safe), "%s: '%s' outside the safe area" % [what, probe.texts[i]])
		if ci is ScreenText:
			for b in buttons:
				check(not _overlap(probe.global_rect(i), b.get_global_rect()),
						"%s: '%s' runs under %s" % [what, probe.texts[i], b.name])
	gt(n, 3, "%s: texts drawn" % what)


# ---------------------------------------------------------------- Hub, title and run

## The title screens with a rooms service on the scripted invite server; the lobby up.
func _titles() -> void:
	ts = TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	ts.set_screen(SCREEN, SCREEN)
	ts.show_state(Game.MENU)
	rooms = NetRooms.new()
	rooms.standalone = true
	rooms.setup(null, link.client, net, time, RunLoop.loop_road(t).length())
	rooms.session.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rooms.set_process(false)
	tree.root.add_child(rooms)
	ts.online_hub.rooms = rooms
	ts.invite_toast.rooms = rooms
	ts.invite_toast.social = social
	ts.online_hub.social_client = social
	rooms.session.connect_lobby()
	_net(0.3)
	eq(rooms.session.state, NetRoomSession.State.LOBBY)


func _joins() -> Array[Dictionary]:
	return server.get("joins")


func test_the_hub_opens_a_room_invites_card() -> void:
	_titles()
	ts.open_hub()
	ts.finish_animations()
	var hub := ts.online_hub
	server.call("push_room_invite", "42", "Dusty", 1234, "K7QX2M", 3)
	_net(0.1)
	hub._process(0.0)
	check(hub.lobby_open(), "the card opens on the hub")
	eq(hub.lobby.view, RoomLobbyPanel.View.ROOM_INVITE)
	eq(hub.lobby.status.text, RoomLobbyPanel.TEXT_ROOM_INVITE_FROM % "Dusty#1234")
	eq(hub.lobby.status.ink, ScreenText.Ink.GOLD)
	eq(hub.lobby.note.text, RoomLobbyPanel.TEXT_ROOM_INVITE_NOTE % ["PRIVATE", "K7QX2M", 3, 8])
	eq(hub.lobby.back_button.text, RoomLobbyPanel.TEXT_DECLINE)
	# DECLINE: nothing sent, the card closes and does not come back.
	var cmds: int = (server.get("lobby_commands") as Array).size()
	_tap(hub.lobby.back_button)
	_net(0.1)
	hub._process(0.0)
	check(not hub.lobby_open())
	eq((server.get("lobby_commands") as Array).size(), cmds, "declining sends nothing")
	# Another one: the ROOMS note says who invites while it waits; JOIN joins by its code.
	server.call("push_room_invite", "77", "Zoe", 7, "PQRS23", 5)
	_net(0.1)
	hub.refresh()
	eq(hub.rooms_note.text, OnlineHubScreen.TEXT_ROOM_INVITES % "Zoe#0007")
	eq(hub.rooms_note.ink, ScreenText.Ink.GOLD)
	hub._process(0.0)
	check(hub.lobby_open())
	var ready: Array[NetRoomSession] = []
	hub.room_ready.connect(func(s: NetRoomSession) -> void: ready.append(s))
	_tap(hub.lobby.action_button)
	_net(0.5)
	eq(_joins().back(), {"type": "lobby_command", "kind": "room_join_code", "code": "PQRS23"})
	eq(ready.size(), 1, "the run drives in the room")


func test_the_title_toast_joins_through_the_hub() -> void:
	_titles()
	var toast := ts.invite_toast
	toast.advance(0.0)
	check(not toast.showing())
	server.call("push_room_invite", "42", "Dusty", 1234, "K7QX2M", 3)
	_net(0.1)
	toast.advance(0.0)
	check(toast.showing(), "on the title")
	eq(toast.shown_at, InviteToast.Place.TITLE)
	eq(toast.line.text, InviteToast.TEXT_ROOM % "Dusty#1234")
	eq(toast.line.ink, ScreenText.Ink.GOLD)
	check(toast.join_button.visible and toast.later_button.visible)
	ge(toast.join_button.size.y, t.hud.touch_target_px)
	check(SCREEN.encloses(toast.panel.get_global_rect()), "on screen")
	var ready: Array[NetRoomSession] = []
	ts.online_hub.room_ready.connect(func(s: NetRoomSession) -> void: ready.append(s))
	_tap(toast.join_button)
	check(not toast.showing())
	check(ts.online_hub.visible, "JOIN opens the hub")
	_net(0.5)
	eq(_joins().back(), {"type": "lobby_command", "kind": "room_join_code", "code": "K7QX2M"})
	eq(ready.size(), 1)


func test_later_leaves_the_invite_for_the_hub() -> void:
	_titles()
	var toast := ts.invite_toast
	server.call("push_room_invite", "42", "Dusty", 1234, "K7QX2M", 3)
	_net(0.1)
	toast.advance(0.0)
	_tap(toast.later_button)
	check(not toast.showing())
	toast.advance(0.0)
	check(not toast.showing(), "the title toasts it once")
	ts.open_hub()
	ts.online_hub._process(0.0)
	eq(ts.online_hub.lobby.view, RoomLobbyPanel.View.ROOM_INVITE, "the hub's card")


func test_a_run_gets_a_note_and_is_never_interrupted() -> void:
	_titles()
	ts.show_state(Game.RUNNING)
	var toast := ts.invite_toast
	server.call("push_room_invite", "42", "Dusty", 1234, "K7QX2M", 3)
	_net(0.1)
	toast.advance(0.0)
	check(toast.showing())
	eq(toast.shown_at, InviteToast.Place.RUN)
	check(not toast.join_button.visible and not toast.later_button.visible, "no buttons in a run")
	eq(toast.panel.mouse_filter, Control.MOUSE_FILTER_IGNORE, "takes no touches")
	eq(toast.sub.text, InviteToast.TEXT_ROOM_RUN)
	eq(_joins().size(), 0)
	toast.advance(net.invite_toast_s + 0.1)
	check(not toast.showing(), "gone after invite_toast_s")
	# Back on the title the same invite gets its JOIN toast.
	ts.show_state(Game.MENU)
	toast.advance(0.0)
	check(toast.showing() and toast.join_button.visible)
	# A crew invite toasts as a note.
	toast.later()
	server.call("push_crew_invite", "9", "NR", "Night Riders", "42", "Dusty", 1234)
	social.attach_lobby(rooms.session.client)
	server.call("push_crew_invite", "9", "NR", "Night Riders", "42", "Dusty", 1234)
	_net(0.1)
	toast.advance(0.0)
	check(toast.showing())
	eq(toast.line.text, InviteToast.TEXT_CREW % "Night Riders [NR]")
	check(not toast.join_button.visible)
	social.detach_lobby()


func test_the_hub_shows_crew_invites_waiting() -> void:
	var dusty := fake.add_player("Dusty", 1234)
	var nr := fake.make_crew(dusty, "Night Riders", "NR")
	fake.add_crew_invite(nr, ME, dusty)
	_titles()
	ts.open_hub()
	ts.finish_animations()
	var hub := ts.online_hub
	check(hub.crew_line.visible, "the gold line over CREW")
	eq(hub.crew_line.text, OnlineHubScreen.TEXT_CREW_INVITES % "Night Riders [NR]")
	eq(hub.crew_line.ink, ScreenText.Ink.GOLD)
	check(SCREEN.encloses(hub.crew_line.get_global_rect()))
	check(not hub.crew_line.get_global_rect().intersects(hub.friends_button.get_global_rect()))


# ---------------------------------------------------------------- Crew page

func _crew() -> CrewPanel:
	var root := Control.new()
	root.size = SCREEN.size
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.root.add_child(root)
	_nodes.append(root)
	var p := ProfilePanel.new()
	p.size = SCREEN.size
	root.add_child(p)
	var style := HudStyle.new()
	style.setup(UiTheme.load_theme(), t.hud, 1.0)
	p.setup(style, t.hud)
	p.bind(session)
	p.layout(AREA)
	p.open()
	_tap(p.tabs[ProfilePanel.View.CREW])
	return p.crew


func test_invite_friends_to_the_crew() -> void:
	var ids := _people()
	var f := fake.add_player("Foxtrot", 6)
	fake.befriend(ME, f)
	var cp := _crew()
	check(cp.invite_toggle.visible, "any member can invite")
	_tap(cp.invite_toggle)
	await tree.process_frame
	check(cp.inviting)
	eq(cp.members_caption.text, CrewPanel.TEXT_INVITE_CAPTION)
	eq(cp.invite_toggle.text, CrewPanel.TEXT_SHOW_MEMBERS)
	var row := cp.row_of(ids["a"])
	check(row != null, "a friend not in the crew")
	check(cp.row_of(ids["c"]) == null, "a friend already in the crew is not listed")
	check(cp.row_of(ids["d"]) == null, "a crewmate who is no friend neither")
	_tap(row.button(CrewPanel.A_INVITE))
	await tree.process_frame
	var last: Dictionary = fake.requests[fake.requests.size() - 1]
	eq(last["path"], "/crews/%s/invites" % social.crew.crew_id)
	eq(NetFakeAccounts._json(String(last["body"])), {"account_id": ids["a"]})
	eq(cp.note.text, CrewPanel.TEXT_INVITE_SENT % "Alpha#0001")
	row = cp.row_of(ids["a"])
	eq(row.buttons[0].text, CrewPanel.LABEL_INVITED)
	check(row.buttons[0].disabled)
	# Back to the members.
	_tap(cp.invite_toggle)
	check(not cp.inviting)
	check(cp.row_of(ids["c"]) != null)


func test_crew_invites_waiting_join_and_decline() -> void:
	var dusty := fake.add_player("Dusty", 1234)
	var zoe := fake.add_player("Zoe", 7)
	var nr := fake.make_crew(dusty, "Night Riders", "NR")
	var dr := fake.make_crew(zoe, "Day Riders", "DR")
	fake.add_crew_invite(nr, ME, dusty)
	fake.add_crew_invite(dr, ME, zoe)
	var cp := _crew()
	await tree.process_frame
	check(cp.invites_caption.visible, "no crew: the invites under JOIN A CREW")
	var dr_row := cp.invite_row_of(dr)
	var nr_row := cp.invite_row_of(nr)
	check(dr_row != null and nr_row != null)
	eq(dr_row.title.text, "Day Riders")
	eq(dr_row.badge.text, "[DR]")
	eq(dr_row.sub.text, CrewPanel.TEXT_INVITE_FROM % "Zoe#0007")
	ge(dr_row.size.y, t.hud.touch_target_px)
	check(AREA.grow(1.0).encloses(dr_row.get_rect()), "inside the area")
	_tap(dr_row.button(CrewPanel.A_DECLINE_INVITE))
	await tree.process_frame
	eq(cp.join_note.text, CrewPanel.TEXT_INVITE_DECLINED)
	check(cp.invite_row_of(dr) == null)
	nr_row = cp.invite_row_of(nr)
	_tap(nr_row.button(CrewPanel.A_ACCEPT_INVITE))
	await tree.process_frame
	check(social.crew != null and social.crew.crew_id == nr, "joined Night Riders")
	eq(cp.note.text, CrewPanel.TEXT_JOINED)
	check(not cp.invites_caption.visible)


func test_in_a_crew_an_invite_says_leave_first() -> void:
	var dusty := fake.add_player("Dusty", 1234)
	var nr := fake.make_crew(dusty, "Night Riders", "NR")
	fake.make_crew(ME, "My Crew", "MY")
	fake.add_crew_invite(nr, ME, dusty)
	var cp := _crew()
	await tree.process_frame
	check(cp.pending_line.visible, "the gold line in a crew")
	eq(cp.pending_line.text, CrewPanel.TEXT_PENDING_ONE % "Night Riders [NR]")
	check(cp.invite_row_of(nr) == null, "no JOIN while in a crew")
	# Accepting anyway (another device) answers leave first.
	await cp.accept_invite(social.crew_invites[0].invite_id)
	eq(cp.join_note.text, CrewPanel.TEXT_LEAVE_FIRST)
