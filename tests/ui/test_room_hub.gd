extends WBTest
## The online hub's rooms (N5.2): QUICK JOIN, PRIVATE ROOM (host options), JOIN BY CODE and
## the ROOM BROWSER through iOS-style touch ids, the joining status, refusals and TRY AGAIN,
## and rooms off without a server (`?server=off`). Spec: multiplayer handoff → Rooms,
## parties and matchmaking; Client changes (Online hub). docs/SCREENS.md → Online hub.

const FakeRoomServer := preload("res://tests/net/fake_room_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rooms: NetRooms
var ts: TitleScreens
var ready_sessions: Array[NetRoomSession] = []


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	ready_sessions.clear()
	ts = TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	ts.set_screen(SCREEN, SCREEN)
	ts.show_state(Game.MENU)
	ts.online_hub.room_ready.connect(func(s: NetRoomSession) -> void: ready_sessions.append(s))


func after_each() -> void:
	if ts != null and is_instance_valid(ts):
		ts.free()
	ts = null
	if rooms != null and is_instance_valid(rooms):
		rooms.free()
	rooms = null
	server = null
	link = null
	Settings.reset_to_defaults()


## A rooms service on the loopback link to the scripted room server, polled by hand.
func _rooms() -> void:
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeRoomServer.new(link)
	rooms = NetRooms.new()
	rooms.standalone = true
	rooms.setup(null, link.client, net, time, RunLoop.loop_road(t).length())
	rooms.session.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rooms.set_process(false)
	tree.root.add_child(rooms)
	ts.online_hub.rooms = rooms
	ts.open_hub()
	ts.finish_animations()


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


func test_rooms_are_off_without_a_server() -> void:
	ts.open_hub()
	ts.finish_animations()
	var hub := _hub()
	for b in hub.room_buttons:
		check(b.disabled, "%s disabled" % b.text)
		eq(b.note, OnlineHubScreen.TEXT_OFF)
	eq(hub.rooms_note.text, NetRooms.TEXT_OFF, "the panel says why")
	_tap(hub.room_buttons[0])
	check(not hub.lobby.visible, "nothing opens")
	check(hub.loop_button.visible and not hub.loop_button.disabled, "loop practice still works")


func test_quick_join_by_touch_hands_the_room_to_the_run() -> void:
	_rooms()
	var hub := _hub()
	for b in hub.room_buttons:
		check(not b.disabled, "%s enabled" % b.text)
	eq(hub.rooms_note.text, OnlineHubScreen.TEXT_ROOMS_NOTE)
	_tap(hub.room_buttons[0])
	check(hub.lobby.visible, "the joining panel")
	eq(hub.lobby.title.text, RoomLobbyPanel.TEXT_QUICK)
	eq(hub.lobby.status.text, RoomLobbyPanel.TEXT_CONNECTING)
	eq(hub.lobby.back_button.text, RoomLobbyPanel.TEXT_CANCEL)
	_net(0.5)
	eq(ready_sessions.size(), 1, "room_ready with the session")
	check(ready_sessions[0] == rooms.session)
	check(not hub.lobby.visible, "the panel closed")
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins[0]["kind"], "quick_join")


func test_private_room_host_options() -> void:
	_rooms()
	var hub := _hub()
	_tap(hub.room_buttons[2])
	var lp := hub.lobby
	eq(lp.view, RoomLobbyPanel.View.CREATE)
	check(lp.density_buttons[1].selected, "NORMAL by default")
	check(lp.time_buttons[RoomLobbyPanel.TIME_CYCLE].selected, "CYCLE by default")
	_tap(lp.density_buttons[2])
	_tap(lp.time_buttons[RoomLobbyPanel.TIME_GOLDEN])
	check(lp.density_buttons[2].selected and not lp.density_buttons[1].selected)
	_tap(lp.action_button)
	_net(0.5)
	var joins: Array[Dictionary] = server.get("joins")
	if not eq(joins.size(), 1):
		return
	eq(joins[0]["kind"], "room_create")
	eq(joins[0]["visibility"], "private")
	eq(joins[0]["density"], "rush")
	eq(joins[0]["time_mode"], "fixed")
	eq(joins[0]["fixed_cycle_ms"], roundi(net.room_fixed_golden_min * 60000.0))
	eq(ready_sessions.size(), 1)
	rooms.session.leave()
	_net(0.2)
	_tap(hub.room_buttons[2])
	_tap(lp.time_buttons[RoomLobbyPanel.TIME_NIGHT])
	_tap(lp.action_button)
	_net(0.5)
	eq(joins.back()["time_mode"], "night", "permanent night")


func test_join_by_code_checks_the_code() -> void:
	_rooms()
	var hub := _hub()
	_tap(hub.room_buttons[3])
	var lp := hub.lobby
	eq(lp.view, RoomLobbyPanel.View.CODE)
	check(lp.code_field.visible)
	lp.code_field.text = "abc"
	_tap(lp.action_button)
	eq(lp.status.text, RoomLobbyPanel.TEXT_CODE_BAD)
	eq(lp.status.ink, ScreenText.Ink.HOT)
	lp.code_field.text = "abc-234"
	_tap(lp.action_button)
	_net(0.5)
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins.back(), {"type": "lobby_command", "kind": "room_join_code", "code": "ABC234"})
	eq(ready_sessions.size(), 1)


func test_browser_lists_public_rooms_and_joins_by_id() -> void:
	_rooms()
	var hub := _hub()
	_tap(hub.room_buttons[1])
	var lp := hub.lobby
	eq(lp.view, RoomLobbyPanel.View.BROWSER)
	_net(0.5)
	check(lp.row_buttons[0].visible and lp.row_buttons[1].visible, "two rooms")
	check(not lp.row_buttons[2].visible)
	check(lp.row_buttons[0].text.begins_with("3/8  ·  NORMAL  ·  DAY"), lp.row_buttons[0].text)
	check(lp.row_buttons[1].text.contains("NIGHT ×2"), lp.row_buttons[1].text)
	_tap(lp.row_buttons[0])
	_net(0.5)
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins.back()["kind"], "room_join_id")
	eq(joins.back()["room_id"], 7)
	eq(ready_sessions.size(), 1)


func test_a_refusal_shows_why_and_tries_again() -> void:
	_rooms()
	server.set("refuse_join", "room_full")
	var hub := _hub()
	_tap(hub.room_buttons[0])
	_net(0.5)
	var lp := hub.lobby
	eq(lp.status.text, "That room is full.")
	eq(lp.status.ink, ScreenText.Ink.HOT)
	check(lp.action_button.visible, "TRY AGAIN")
	eq(lp.action_button.text, RoomLobbyPanel.TEXT_RETRY)
	eq(lp.back_button.text, RoomLobbyPanel.TEXT_BACK)
	_tap(lp.action_button)
	_net(0.5)
	eq(ready_sessions.size(), 1, "joined on the second try")
	_tap(hub.room_buttons[0])
	check(lp.visible)
	_tap(lp.back_button)
	check(not lp.visible, "CANCEL closes")


func test_touch_targets_and_the_parting_message() -> void:
	_rooms()
	var hub := _hub()
	for b in hub.room_buttons:
		ge(b.size.y, t.hud.touch_target_px, "%s is a touch target" % b.text)
	for open: Callable in [hub.open_private, hub.open_code, hub.open_browser]:
		open.call()
		_net(0.3)
		for c in hub.lobby.panel.get_children():
			var b := c as ScreenButton
			if b != null and b.visible:
				ge(b.size.y, t.hud.touch_target_px, "%s is a touch target" % b.text)
				check(Rect2(Vector2.ZERO, SCREEN.size).encloses(b.get_global_rect()), "%s on screen" % b.text)
		hub.lobby.close()
	hub.show_room_message("The room closed.")
	eq(hub.rooms_note.text, "The room closed.")
	eq(hub.rooms_note.ink, ScreenText.Ink.HOT)
