extends WBTest
## The room scoring HUD (N6.2): the crew line (CREW ×1.50 · 2 NEAR; muted with nobody near),
## the session crew total with the run's trains, the TRAIN ×n badge (the train counter) and
## how long it shows, the crew total in the room menu (PLAYERS, opened through iOS-style
## touch ids), and text fit: with the gameplay HUD beside it at 100 % and 125 % text on a
## 1280x720 and a notched 1560x720 canvas, every room text sits in its box and the safe
## area, overlaps no other text, and stays in the top half, clear of the thumb zones.
## Spec: multiplayer handoff → Crew mechanics, Client changes (in-room HUD additions: crew
## proximity indicator, train counter; room menu: crew total); UI (Accessibility: text size
## 100% / 125%; safe areas). docs/ROOMS_CLIENT.md → Scoring in a room; docs/SCREENS.md.

const HUD_SCENE := preload("res://src/ui/hud/hud.tscn")
const FakeScoreServer := preload("res://tests/net/fake_score_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
const IOS_ID := 1_893_457_201
const DT := 1.0 / 60.0
const WIDE_NAME := "WWWWWWWWWWWWWWWW"

var t: Tuning
var net: NetTuning
var probe := HudTextProbe.new()
var time: NetVirtualTime
var link: NetLoopbackLink
var server: FakeScoreServer
var rs: NetRoomSession
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	probe.clear()
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeScoreServer.new(link)
	rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rs.quick_join()
	_net(0.5)


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	rs = null
	server = null
	link = null
	Settings.reset_to_defaults()


func _net(seconds: float) -> void:
	for i in roundi(seconds / 0.01):
		time.advance_s(0.01)
		server.poll()
		rs.poll()


func _room_hud(full: Rect2, safe: Rect2) -> RoomHud:
	var h := RoomHud.new()
	tree.root.add_child(h)
	_nodes.append(h)
	h.setup(net, rs)
	h.set_screen(full, safe)
	h.advance(0.0)
	return h


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func test_crew_line_shows_the_factor() -> void:
	var h := _room_hud(Rect2(0, 0, 1280, 720), Rect2(0, 0, 1280, 720))
	eq(h.crew_line.text, "CREW ×1.00", "nobody near")
	eq(h.crew_line.ink, ScreenText.Ink.MUTED)
	h.set_crew(2, NetScoreClient.factor_for(2, net))
	eq(h.crew_line.text, "CREW ×1.50  ·  2 NEAR")
	eq(h.crew_line.ink, ScreenText.Ink.ACCENT, "lit while crewmates are near")
	h.set_crew(6, NetScoreClient.factor_for(6, net))
	eq(h.crew_line.text, "CREW ×2.00  ·  6 NEAR", "capped at ×2")
	h.set_crew(0, 1.0)
	eq(h.crew_line.text, "CREW ×1.00")
	eq(h.crew_line.ink, ScreenText.Ink.MUTED)


func test_train_badge_counts_and_fades() -> void:
	var h := _room_hud(Rect2(0, 0, 1280, 720), Rect2(0, 0, 1280, 720))
	check(not h.is_train_shown())
	h.show_train(2)
	check(h.is_train_shown())
	eq(h.train_badge.text, "TRAIN ×2")
	h.advance(net.train_show_s * 0.5)
	h.show_train(3)
	eq(h.train_badge.text, "TRAIN ×3", "each link counts up")
	h.advance(net.train_show_s - 0.05)
	check(h.is_train_shown(), "a new link restarts the time")
	h.advance(0.1)
	check(not h.is_train_shown(), "gone after train_show_s")
	h.show_train(0)
	check(not h.is_train_shown(), "no link, no badge")


func test_room_menu_shows_the_crew_total_by_touch() -> void:
	var h := _room_hud(Rect2(0, 0, 1280, 720), Rect2(0, 0, 1280, 720))
	server.send([{"type": "room_event", "kind": "crew", "crew_slot": 0, "color": 3, "session_total": 1234567}])
	_net(0.1)
	_tap(h.room_button)
	check(h.menu.visible)
	_tap(h.menu.players_tab)
	eq(h.menu.tab, RoomMenu.Tab.PLAYERS)
	check(h.menu.crew_total.visible)
	eq(h.menu.crew_total.text, "CREW TOTAL 1,234,567")
	var r := h.menu.crew_total.get_global_rect()
	check(h.menu.panel.get_global_rect().encloses(r), "inside the panel")
	check(not r.intersects(h.menu.leave_button.get_global_rect()), "beside LEAVE ROOM")
	_tap(h.menu.chat_tab)
	check(not h.menu.crew_total.visible, "PLAYERS only")


# ---------------------------------------------------------------- Text fit

func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in t.hud.text_scales:
			out.append([full, safe, ts, "%dx%d text %d%%" % [size.x, size.y, roundi(ts * 100.0)]])
	return out


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


func _visible(root: Node) -> Array[int]:
	var out: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and root.is_ancestor_of(ci):
			out.append(i)
	return out


static func _inside(inner: Rect2, outer: Rect2) -> bool:
	return outer.grow(TOL).encloses(inner)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TOL).intersects(b.grow(-TOL))


func test_room_scoring_text_fits_beside_the_hud() -> void:
	HudDraw.probe = probe
	var n := 0
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		var hud := HUD_SCENE.instantiate() as Hud
		hud.auto_process = false
		hud.set_screen(c[0], c[1])
		tree.root.add_child(hud)
		_nodes.append(hud)
		var f := HudFeed.new()
		f.top_speed_mps = Units.kmh_to_mps(270.0)
		f.speed_mps = Units.kmh_to_mps(288.0)
		f.banked = 88_888_888
		f.best = 99_999_999
		f.chain = 8_888_888
		f.multiplier = 888.8
		hud.bind(f)
		Events.scored.emit(Events.THREAD, 88_888, 888.8, 0.2)
		for k in 3:
			hud.push_event(RoomHud.TEXT_TRAIN % (k + 7), "+88,888", HudEventStack.Role.GOLD)
		for k in 20:
			hud.advance(DT)
		var h := _room_hud(c[0], c[1])
		h.set_crew(7, NetScoreClient.factor_for(7, net))
		h.show_train(99)
		for k in net.room_chat_feed_lines:
			h.add_feed(WIDE_NAME + "#8888", "ONE MORE LAP", Color.WHITE)
		h.advance(0.0)
		_redraw(hud)
		_redraw(h)
		probe.clear()
		await tree.process_frame
		var mine := _visible(h)
		var theirs := _visible(hud)
		var zones := HudLayout.thumb_zone_rects(t.hud, c[0], HudLayout.fallback_px_per_cm(c[0]))
		var safe: Rect2 = c[1]
		for w: ScreenText in [h.crew_line, h.train_badge]:
			var drawn := false
			for i in mine:
				if probe.items[i] == w:
					drawn = true
			check(drawn, "%s: %s drawn" % [c[3], w.name])
		for i in mine:
			var ci := probe.items[i] as Control
			if ci == null or ci is RoomNametags or h.menu.is_ancestor_of(ci):
				continue
			var g := probe.global_rect(i)
			if ci is ScreenText:
				check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
					"%s: '%s' runs out of %s" % [c[3], probe.texts[i], ci.name])
			check(_inside(g, safe), "%s: '%s' outside the safe area" % [c[3], probe.texts[i]])
			check(g.end.y < c[0].size.y * 0.5, "%s: '%s' in the top half" % [c[3], probe.texts[i]])
			for z in zones:
				check(not g.intersects(z), "%s: '%s' clear of the thumb zones" % [c[3], probe.texts[i]])
			for j in theirs:
				check(not _overlap(g, probe.global_rect(j)), "%s: '%s' overlaps the HUD's '%s' (%s)" % [c[3],
					probe.texts[i], probe.texts[j], probe.items[j].name])
			for j in mine:
				if j > i and probe.items[j] != ci and not (probe.items[j] is RoomNametags):
					check(not _overlap(g, probe.global_rect(j)), "%s: '%s' overlaps '%s'" % [c[3], probe.texts[i],
						probe.texts[j]])
			n += 1
		for x in _nodes:
			if is_instance_valid(x):
				x.free()
		_nodes.clear()
	gt(n, 0, "texts were recorded")
