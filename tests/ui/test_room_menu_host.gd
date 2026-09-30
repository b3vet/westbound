extends WBTest
## The room menu's ROOM tab (N9.3) through iOS-style touch ids: the invite link with COPY
## LINK; for the host of a private room TRAFFIC and TIME OF DAY sent as room_host_commands
## (the room's settings shown selected), and REMOVE A PLAYER (PLAYERS then removes with two
## taps; mute taps come back after); for everyone else and in public rooms the reason the
## settings are locked; and text fit at 100 % / 125 % on 1280x720 and a notched 1560x720.
## Spec: multiplayer handoff → Rooms (Private rooms: "they can kick players and change
## density or time mode"; invite links), Client changes (Room menu: invite, host settings).
## docs/ROOMS_CLIENT.md → Host settings (N9.3).

const FakePartyServer := preload("res://tests/net/fake_party_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
const IOS_ID := 1_893_457_201
const LINK := "https://westbound.sipsakrandevu.com/r/ABC234"

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var hud: RoomHud
var probe := HudTextProbe.new()


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
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakePartyServer.new(link)
	rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rs.quick_join()
	_net(0.5)
	_make_hud(SCREEN, SCREEN)


func after_each() -> void:
	HudDraw.probe = null
	if hud != null and is_instance_valid(hud):
		hud.free()
	hud = null
	rs = null
	server = null
	link = null
	Settings.reset_to_defaults()


func _make_hud(full: Rect2, safe: Rect2) -> void:
	if hud != null and is_instance_valid(hud):
		hud.free()
	hud = RoomHud.new()
	tree.root.add_child(hud)
	hud.setup(net, rs)
	hud.set_screen(full, safe)
	hud.menu.invite_url = LINK
	hud.advance(0.0)


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


## This client becomes the host (room_event.host_change, as the server sends it).
func _become_host() -> void:
	server.call("send", [{"type": "room_event", "kind": "host_change", "player_id": FakePartyServer.YOU}])
	_net(0.1)


func _host_cmds() -> Array[Dictionary]:
	return server.get("host_commands")


func _open_room_tab() -> RoomMenu:
	_tap(hud.room_button)
	_tap(hud.menu.room_tab)
	return hud.menu


func test_the_invite_link_and_copy() -> void:
	var m := _open_room_tab()
	eq(m.tab, RoomMenu.Tab.ROOM)
	check(m.link_text.visible)
	eq(m.link_text.text, "INVITE  " + LINK.trim_prefix("https://"), "the link without its scheme")
	var bridge := CopyBridge.new()
	m.bridge = bridge
	_tap(m.copy_button)
	eq(bridge.copied.size(), 1)
	check(bridge.copied[0].contains(LINK))
	eq(m.link_note.text, RoomMenu.TEXT_COPIED)
	check(not m.share_button.visible, "no share sheet here")


func test_settings_are_locked_for_players_and_public_rooms() -> void:
	var m := _open_room_tab()
	check(not rs.room.is_host())
	check(m.host_note.visible)
	eq(m.host_note.text, RoomMenu.TEXT_HOST_ONLY)
	for b: ScreenButton in m.density_buttons + m.time_buttons + [m.kick_button]:
		check(not b.visible, "%s hidden" % b.text)
	m.set_density(2)
	check(_host_cmds().is_empty(), "nothing sent without being host")
	# A public room has no host at all.
	rs.room.visibility = "public"
	rs.room.version += 1
	m.refresh()
	eq(m.host_note.text, RoomMenu.TEXT_PUBLIC_RULES)


func test_the_host_changes_traffic_and_time() -> void:
	_become_host()
	var m := _open_room_tab()
	check(not m.host_note.visible)
	check(m.density_buttons[1].selected, "NORMAL selected")
	check(m.time_buttons[RoomMenu.TIME_CYCLE].selected)
	_tap(m.density_buttons[2])
	_tap(m.time_buttons[RoomMenu.TIME_NIGHT])
	_tap(m.time_buttons[RoomMenu.TIME_GOLDEN])
	_net(0.1)
	var cmds := _host_cmds()
	if not eq(cmds.size(), 3):
		return
	eq(cmds[0], {"type": "room_host_command", "kind": "set_density", "density": "rush"})
	eq(cmds[1], {"type": "room_host_command", "kind": "set_time_mode", "time_mode": "night", "fixed_cycle_ms": 0})
	eq(cmds[2]["time_mode"], "fixed")
	eq(cmds[2]["fixed_cycle_ms"], roundi(net.room_fixed_golden_min * 60000.0))
	# The server's settings event is what the buttons show.
	server.call("send", [{"type": "room_event", "kind": "settings", "tick": 10,
		"settings": {"visibility": "private", "max_players": 8, "density": "rush", "time_mode": "fixed",
			"fixed_cycle_ms": roundi(net.room_fixed_golden_min * 60000.0)},
		"clock": {"cycle_ms": 1000, "cycle_len_ms": 1_920_000, "day_len_ms": 1_320_000}}])
	_net(0.1)
	m.refresh()
	check(m.density_buttons[2].selected, "RUSH HOUR")
	check(m.time_buttons[RoomMenu.TIME_GOLDEN].selected, "GOLDEN")
	eq(m.sub.text, "PRIVATE  ·  RUSH  ·  FIXED")


func test_the_host_removes_a_player_with_two_taps() -> void:
	_become_host()
	var m := _open_room_tab()
	_tap(m.kick_button)
	eq(m.tab, RoomMenu.Tab.PLAYERS)
	check(m.kick_mode)
	var dusty := m.player_buttons[0]
	check(dusty.note.ends_with(RoomMenu.TEXT_TAP_KICK), dusty.note)
	_tap(dusty)
	check(dusty.note.ends_with(RoomMenu.TEXT_TAP_AGAIN), dusty.note)
	check(_host_cmds().is_empty(), "one tap arms it")
	_tap(dusty)
	_net(0.1)
	eq(_host_cmds().back(), {"type": "room_host_command", "kind": "kick", "player_id": FakePartyServer.OTHER})
	check(not m.kick_mode, "back to muting")
	check(dusty.note.ends_with(RoomMenu.TEXT_MUTE), dusty.note)
	# Kick mode ends with the tab too.
	_tap(m.room_tab)
	_tap(m.kick_button)
	_tap(m.chat_tab)
	check(not m.kick_mode)


func test_room_tab_fits_every_setting() -> void:
	_become_host()
	HudDraw.probe = probe
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for scale in t.hud.text_scales:
			Settings.set_value(&"text_scale", float(scale))
			_make_hud(full, safe)
			var what := "%dx%d text %d%%" % [size.x, size.y, roundi(scale * 100.0)]
			for tab: RoomMenu.Tab in [RoomMenu.Tab.ROOM, RoomMenu.Tab.PLAYERS]:
				hud.menu.open(tab)
				if tab == RoomMenu.Tab.PLAYERS:
					hud.menu.start_kick()
				await _check_fit(hud.menu, safe, "%s %s" % [what, tab])
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


func _check_fit(menu: RoomMenu, safe: Rect2, what: String) -> void:
	_redraw(menu)
	probe.clear()
	await tree.process_frame
	var buttons: Array[ScreenButton] = []
	_buttons(menu, buttons)
	var panel := menu.panel.get_global_rect()
	for b in buttons:
		ge(b.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
		check(_inside(b.get_global_rect(), safe), "%s: %s outside the safe area" % [what, b.name])
		check(_inside(b.get_global_rect(), panel), "%s: %s outside the panel" % [what, b.name])
	for a in buttons.size():
		for c in range(a + 1, buttons.size()):
			check(not _overlap(buttons[a].get_global_rect(), buttons[c].get_global_rect()),
					"%s: %s overlaps %s" % [what, buttons[a].name, buttons[c].name])
	var texts: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i] as Control
		if ci == null or not is_instance_valid(ci) or not ci.is_visible_in_tree() or not menu.is_ancestor_of(ci):
			continue
		texts.append(i)
		var g := probe.global_rect(i)
		check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
				"%s: '%s' runs out of %s" % [what, probe.texts[i], ci.name])
		check(_inside(g, panel), "%s: '%s' outside the panel" % [what, probe.texts[i]])
		if ci is ScreenText:
			for b in buttons:
				check(not _overlap(g, b.get_global_rect()), "%s: '%s' runs under %s" % [what, probe.texts[i], b.name])
	gt(texts.size(), 3, "%s: texts drawn" % what)
