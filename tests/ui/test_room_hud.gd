extends WBTest
## The room HUD (N5.2): ROOM and REJOIN CREW through iOS-style touch ids, quick chat and mute
## in the room menu, the loop strip (no redraw when still), nametags, the crash-out toast
## (3 s), the chat feed, the reconnecting banner, and the layout (touch targets, clear of the
## thumb zones and the middle third). Spec: multiplayer handoff → Players (loop strip,
## nametags, crash-out toast, rejoin crew, reconnect), Rooms → Quick chat; Client changes
## (In-room HUD additions, Room menu). docs/ROOMS_CLIENT.md → Room HUD.

const FakeRoomServer := preload("res://tests/net/fake_room_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var hud: RoomHud
var rejoins: int = 0
var leaves: int = 0


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeRoomServer.new(link)
	rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rs.quick_join()
	_net(0.5)
	hud = RoomHud.new()
	tree.root.add_child(hud)
	hud.setup(net, rs)
	hud.set_screen(SCREEN, SCREEN)
	rejoins = 0
	leaves = 0
	hud.rejoin_pressed.connect(func() -> void: rejoins += 1)
	hud.leave_pressed.connect(func() -> void: leaves += 1)
	hud.chat_pressed.connect(func(item: Dictionary) -> void: rs.send_chat(item))
	hud.mute_pressed.connect(func(pid: int) -> void: rs.set_muted(pid, not rs.room.member(pid).muted))
	hud.advance(0.0)


func after_each() -> void:
	if hud != null and is_instance_valid(hud):
		hud.free()
	hud = null
	rs = null
	server = null
	link = null
	Settings.reset_to_defaults()


func _net(seconds: float) -> void:
	for i in roundi(seconds / 0.01):
		time.advance_s(0.01)
		server.call("poll")
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


func test_room_line() -> void:
	check(hud.line.text.begins_with("ROOM ABC234  ·  2/8  ·  "), hud.line.text)
	check(hud.line.text.ends_with(" MS"))


func test_quick_chat_and_mute_by_touch() -> void:
	_tap(hud.room_button)
	check(hud.menu.visible, "ROOM opens the menu")
	eq(hud.menu.tab, RoomMenu.Tab.CHAT)
	var gg := hud.menu.chat_buttons[4]
	eq(gg.text, "GG")
	ge(gg.size.y, t.hud.touch_target_px)
	_tap(gg)
	check(not hud.menu.visible, "a chat closes the menu")
	_net(0.2)
	var chats: Array[Dictionary] = server.get("chats")
	eq(chats.size(), 1)
	eq(chats[0]["item"], {"kind": "phrase", "phrase": "gg"})
	_tap(hud.room_button)
	check(hud.menu.chat_buttons[0].disabled, "rate-limited: WAIT")
	_tap(hud.menu.players_tab)
	eq(hud.menu.tab, RoomMenu.Tab.PLAYERS)
	check(hud.menu.player_buttons[0].visible and hud.menu.player_buttons[1].visible)
	eq(hud.menu.player_buttons[0].text, "Dusty#1234 [WB]")
	check(hud.menu.player_buttons[1].disabled, "you can't mute yourself")
	_tap(hud.menu.player_buttons[0])
	check(rs.room.member(0).muted, "Dusty muted")
	check(hud.menu.player_buttons[0].selected)
	eq(hud.menu.player_buttons[0].note, "HOST  ·  " + RoomMenu.TEXT_MUTED)
	_tap(hud.menu.leave_button)
	eq(leaves, 1, "LEAVE ROOM")
	_tap(hud.menu.close_button)
	check(not hud.menu.visible)


func test_rejoin_crew_by_touch() -> void:
	ge(hud.rejoin_button.size.y, t.hud.touch_target_px)
	check(not hud.rejoin_button.disabled)
	_tap(hud.rejoin_button)
	eq(rejoins, 1)


func test_loop_strip_dots_and_idle() -> void:
	var st := hud.strip
	st.set_me(0.25)
	st.set_dot(0, 0.5, Color.RED)
	st.set_dot(1, -1.0, Color.TRANSPARENT)
	eq(st.dots_shown(), 1)
	check(st.dot_x(0) > st.me_x(), "half way round is right of a quarter")
	near(float(st.dot_x(0)), st.x_of(0.5), 0.5)
	st.queue_redraw()
	await tree.process_frame
	var n := st.redraws
	for k in 10:
		st.set_me(0.25)
		st.set_dot(0, 0.5, Color.RED)
		await tree.process_frame
	eq(st.redraws, n, "a still strip does not redraw")
	st.set_dot(0, 0.6, Color.RED)
	await tree.process_frame
	eq(st.redraws, n + 1, "a moving dot redraws")
	# In the top margin, over the sun bar, never in the middle third.
	lt(st.get_global_rect().end.y, SCREEN.size.y / 3.0)


func test_crash_out_toast_lasts_3s() -> void:
	hud.show_result({"player_id": 1, "score": 12500, "distance_m": 2345, "duration_ms": 95000,
		"flags": {"verified": false, "leaderboard_eligible": false}})   # N6.2: the official score
	check(hud.is_toast_shown())
	eq(hud.toast_title.text, RoomHud.TEXT_CRASHED_OUT)
	eq(hud.toast_sub.text, "SCORE 12,500  ·  2.3 KM  ·  1:35  ·  RESPAWNING  ·  UNVERIFIED")
	hud.advance(net.room_result_toast_s - 0.1)
	check(hud.is_toast_shown())
	hud.advance(0.2)
	check(not hud.is_toast_shown(), "gone after 3 s")


func test_chat_feed_and_banner() -> void:
	hud.add_feed("Dusty#1234", "GG", Color.RED)
	hud.add_feed("Kai#0055", "HONK!", Color.BLUE)
	eq(hud.feed_text(0), "Kai#0055  HONK!", "newest first")
	eq(hud.feed_text(1), "Dusty#1234  GG")
	hud.advance(net.room_chat_show_s + 0.1)
	eq(hud.feed_text(0), "", "lines fade after room_chat_show_s")
	server.call("drop")
	_net(0.2)
	hud.set_reconnecting(true)
	check(hud.banner.visible)
	eq(hud.banner.text, RoomHud.TEXT_RECONNECTING % ceili(rs.reconnect_left_s()))
	hud.set_reconnecting(false)
	check(not hud.banner.visible)


func test_layout_clear_of_the_thumbs() -> void:
	var zones := HudLayout.thumb_zone_rects(t.hud, SCREEN, HudLayout.fallback_px_per_cm(SCREEN))
	for c: Control in [hud.room_button, hud.rejoin_button, hud.line]:
		for z in zones:
			check(not c.get_global_rect().intersects(z), "%s clear of the thumb zones" % c.name)
	for c: Control in [hud.room_button, hud.rejoin_button]:
		check(c.get_global_rect().position.x > SCREEN.size.x * 2.0 / 3.0, "%s in the right third" % c.name)
		check(c.get_global_rect().end.y < SCREEN.size.y * 0.5, "%s in the top half" % c.name)
