class_name RoomHud
extends CanvasLayer
## The in-room HUD additions, over the gameplay HUD: the loop strip, the room line (code,
## players, ping), nametags, REJOIN CREW and ROOM (quick chat, players, leave), the
## crash-out results toast, the reconnecting banner and the chat feed. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Players (loop strip; nametags; crash-out: "a
## 3-second results toast shows the score"; rejoin crew: "a button teleports you to your
## crew at any time"; reconnect), Rooms → Quick chat, Client changes (In-room HUD
## additions: the loop strip, room clock, ping, quick-chat wheel; Room menu). The room
## clock itself is the gameplay HUD's sun bar in clock mode (HudLoopFeed). docs/ROOMS_CLIENT.md
## → Room HUD. WP N5.2.
##
## Emits intents only (rejoin_pressed, leave_pressed, chat_pressed, mute_pressed); RunRoom
## acts on them and feeds it (strip dots, nametags, results, feed, banner). Layout: the
## strip in the top margin over the sun bar; the room line, ROOM and REJOIN CREW and the
## feed under the score panel (where loop mode has no leg objective), clear of the thumb
## zones; the toast and the banner in the event stack's column. Labels change only when
## their text changes.
##
## N6.2 (multiplayer scoring): the crew line under the room line (CREW ×1.50 · 2 NEAR:
## crewmates within 30 m, the factor on every scored event) with the TRAIN ×n badge beside
## it after each link (the train counter), the session crew total in the room menu
## (PLAYERS; spec: "shown in the room menu"), and the crash-out toast with the official
## score. Train links and official sector bonuses go on the gameplay HUD's event stack
## (RunRoom). Chat feed lines are kept clear of the event stack's column (a long name is
## shortened on the feed; the nametag shows it whole).

signal rejoin_pressed()
signal leave_pressed()
signal chat_pressed(item: Dictionary)
signal mute_pressed(player_id: int)

## Above the gameplay HUD (5), below the in-run screens.
const LAYER := 6
const TEXT_ROOM := "ROOM"
const TEXT_REJOIN := "REJOIN CREW"
const TEXT_LINE := "ROOM %s  ·  %s  ·  %d MS"
const TEXT_CRASHED_OUT := "CRASHED OUT"
const TEXT_RESULT_SUB := "SCORE %s  ·  %s  ·  %s  ·  RESPAWNING"
const TEXT_UNVERIFIED := "  ·  UNVERIFIED"
const TEXT_RECONNECTING := "RECONNECTING  ·  %d S"
const TEXT_FEED := "%s  %s"
const TEXT_CREW := "CREW ×%s"
const TEXT_CREW_NEAR := "CREW ×%s  ·  %d NEAR"
const TEXT_ELLIPSIS := "…"
const TEXT_TRAIN := "TRAIN ×%d"
const TEXT_KM := "%.1f KM"
const TEXT_TIME := "%d:%02d"
const SECONDS_PER_MINUTE := 60
const M_PER_KM := 1000.0   # lint: allow-number unit conversion
const MS_PER_S := 1000.0   # lint: allow-number unit conversion
## The ping shown rounds to this many ms (the line redraws less).
const PING_STEP_MS := 5

var net: NetTuning
var hud: HudTuning
var session: NetRoomSession
var run: Run
var style := HudStyle.new()

var strip: HudLoopStrip
var nametags: RoomNametags
var line: ScreenText
var room_button: ScreenButton
var rejoin_button: ScreenButton
var menu: RoomMenu
var toast: ScreenPanel
var toast_title: ScreenText
var toast_sub: ScreenText
var banner: ScreenText
var feed: Array[ScreenText] = []
## N6.2: the crew line (factor and crewmates near) and the TRAIN ×n badge.
var crew_line: ScreenText
var train_badge: ScreenText

var _pinned: bool = false
var _full: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var _safe: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var _toast_left_s: float = 0.0
var _notice_left_s: float = 0.0
var _reconnecting: bool = false
var _line_key: int = -1
var _banner_key: int = -1
var _feed_left := PackedFloat32Array()
var _crew_key: int = -1
var _train_left_s: float = 0.0


func _init() -> void:
	layer = LAYER
	nametags = RoomNametags.new()
	nametags.name = "Nametags"
	add_child(nametags)
	strip = HudLoopStrip.new()
	strip.name = "LoopStrip"
	add_child(strip)
	line = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	line.name = "RoomLine"
	line.outline = true
	add_child(line)
	room_button = _button(TEXT_ROOM, func() -> void: menu.open())
	rejoin_button = _button(TEXT_REJOIN, rejoin_pressed.emit)
	toast = ScreenPanel.new()
	toast.name = "ResultToast"
	toast.edge = ScreenPanel.Edge.GOLD
	toast.visible = false
	add_child(toast)
	toast_title = ScreenText.make(TEXT_CRASHED_OUT, ScreenText.Face.DISPLAY, 32, ScreenText.Ink.GOLD)
	toast.add_child(toast_title)
	toast_sub = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	toast.add_child(toast_sub)
	banner = ScreenText.make("", ScreenText.Face.LABEL, 20, ScreenText.Ink.GOLD)
	banner.name = "Banner"
	banner.outline = true
	banner.visible = false
	add_child(banner)
	crew_line = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	crew_line.name = "CrewLine"
	crew_line.outline = true
	add_child(crew_line)
	train_badge = ScreenText.make("", ScreenText.Face.DISPLAY, 20, ScreenText.Ink.GOLD)
	train_badge.name = "TrainBadge"
	train_badge.outline = true
	train_badge.visible = false
	add_child(train_badge)
	menu = RoomMenu.new()
	add_child(menu)
	menu.chat_pressed.connect(func(item: Dictionary) -> void:
		chat_pressed.emit(item)
		menu.close())
	menu.mute_pressed.connect(mute_pressed.emit)
	menu.leave_pressed.connect(leave_pressed.emit)


func _button(label: String, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, ScreenButton.Kind.NORMAL, 20)
	b.name = label.capitalize().replace(" ", "")
	b.align = HORIZONTAL_ALIGNMENT_CENTER
	b.pressed.connect(action)
	add_child(b)
	return b


func setup(net_tuning: NetTuning, room_session: NetRoomSession) -> void:
	net = net_tuning
	session = room_session
	hud = Tuning.load_default().hud
	var ts := hud.clamp_text_scale(float(Settings.get_value(&"text_scale")))
	style.setup(UiTheme.load_theme(), hud, ts)
	for i in net.room_chat_feed_lines:
		var t := ScreenText.make("", ScreenText.Face.LABEL, net.room_font_px, ScreenText.Ink.TEXT)
		t.name = "Feed%d" % i
		t.outline = true
		t.visible = false
		add_child(t)
		feed.append(t)
	_feed_left.resize(feed.size())
	_feed_left.fill(0.0)
	strip.setup(style, net, net.room_max_remotes)
	nametags.setup(style, net, net.room_max_remotes)
	nametags.clock = func() -> float: return float(session.time.now_usec()) / NetRoomSession.USEC_PER_S
	for c in get_children():
		if c is ScreenButton:
			(c as ScreenButton).setup(style)
		elif c is ScreenText:
			(c as ScreenText).setup(style)
		elif c is ScreenPanel:
			(c as ScreenPanel).setup(style)
	for c in toast.get_children():
		(c as ScreenText).setup(style)
	line.size_px = net.room_font_px
	crew_line.size_px = net.room_font_px
	set_crew(0, 1.0)
	menu.setup(style, hud, net, session)
	if not session.room_changed.is_connected(refresh_room):
		session.room_changed.connect(refresh_room)
	_relayout()
	refresh_room()


func _ready() -> void:
	if not _pinned:
		get_viewport().size_changed.connect(_relayout)
	_relayout()


## The run (the strip's sector marks; REJOIN CREW only while driving).
func bind_run(r: Run) -> void:
	run = r
	var fr := PackedFloat64Array()
	if r != null and r.loop != null:
		var road := r.loop.road
		for s in road.layout.sector_s:
			fr.append(road.wrap_s(s) / road.length())
	strip.set_sectors(fr)


## Pins the canvas and safe rects (tests, previews).
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_full = full
	_safe = safe
	_relayout()


## Per frame (RunRoom.frame): toasts and the feed age, the room line and the banner.
func advance(dt: float) -> void:
	if _toast_left_s > 0.0:
		_toast_left_s -= dt
		if _toast_left_s <= 0.0:
			toast.visible = false
	if _notice_left_s > 0.0:
		_notice_left_s -= dt
		if _notice_left_s <= 0.0 and not _reconnecting:
			banner.visible = false
	if _train_left_s > 0.0:
		_train_left_s -= dt
		if _train_left_s <= 0.0:
			train_badge.visible = false
	for i in feed.size():
		if _feed_left[i] > 0.0:
			_feed_left[i] -= dt
			if _feed_left[i] <= 0.0:
				feed[i].visible = false
	if _reconnecting:
		var left := ceili(session.reconnect_left_s())
		if left != _banner_key:
			_banner_key = left
			banner.text = TEXT_RECONNECTING % left
			_place_banner()
	var ping := roundi(session.ping_ms() / float(PING_STEP_MS)) * PING_STEP_MS
	var key := ping * NetCodec.MAX_ROOM_PLAYERS * NetCodec.MAX_ROOM_PLAYERS + session.room.members.size() * NetCodec.MAX_ROOM_PLAYERS + session.room.max_players
	if key != _line_key:
		_line_key = key
		line.text = TEXT_LINE % [session.room.code, session.room.players_text(), ping]
		line.size = line.get_combined_minimum_size()
	var driving := run == null or run.state == Game.RUNNING
	rejoin_button.disabled = not driving or not session.is_in_room()
	if menu.visible:
		menu.refresh()


## The server's run_result for this player: the crash-out toast (spec: 3 s) with the
## official score (N6: the server's banked total).
func show_result(result: Dictionary) -> void:
	var score := int(result.get("score", 0))
	var dist := float(result.get("distance_m", 0)) / M_PER_KM
	var secs := roundi(float(result.get("duration_ms", 0)) / MS_PER_S)
	var sub := TEXT_RESULT_SUB % [HudFormat.thousands(score), TEXT_KM % dist,
		TEXT_TIME % [floori(secs / float(SECONDS_PER_MINUTE)), secs % SECONDS_PER_MINUTE]]
	var f: Dictionary = result.get("flags", {})
	if not bool(f.get("verified", true)):
		sub += TEXT_UNVERIFIED
	toast_sub.text = sub
	toast.visible = true
	_toast_left_s = net.room_result_toast_s
	_place_toast()


## N6.2: the crew line: `near` crewmates in range and the factor they give. The label
## changes only when a value does.
func set_crew(near: int, factor: float) -> void:
	var key := near * CREW_KEY_NEAR + roundi(factor * CREW_KEY_FACTOR)
	if key != _crew_key:
		_crew_key = key
		var f := "%.2f" % factor
		crew_line.text = TEXT_CREW_NEAR % [f, near] if near > 0 else TEXT_CREW % f
		crew_line.set_ink(ScreenText.Ink.ACCENT if near > 0 else ScreenText.Ink.MUTED)
		_place_crew()


## N6.2: TRAIN ×link for NetTuning.train_show_s (the train counter).
func show_train(link: int) -> void:
	if link <= 0:
		return
	train_badge.text = TEXT_TRAIN % link
	train_badge.visible = true
	_place_crew()
	_train_left_s = net.train_show_s


func is_train_shown() -> bool:
	return train_badge.visible


func is_toast_shown() -> bool:
	return toast.visible


## A feed line ("Dusty#1234  GG"), in the sender's crew color; the oldest goes.
func add_feed(who: String, text: String, color: Color) -> void:
	if feed.is_empty():
		return
	for i in range(feed.size() - 1, 0, -1):
		feed[i].text = feed[i - 1].text
		feed[i].modulate = feed[i - 1].modulate
		feed[i].visible = feed[i - 1].visible
		_feed_left[i] = _feed_left[i - 1]
	feed[0].text = _fit_feed(who, text)
	feed[0].modulate = color
	feed[0].visible = true
	_feed_left[0] = net.room_chat_show_s
	_place_feed()


func feed_text(i: int) -> String:
	return feed[i].text if i < feed.size() and feed[i].visible else ""


func set_reconnecting(on: bool) -> void:
	_reconnecting = on
	_banner_key = -1
	banner.visible = on
	if on:
		advance(0.0)
	_place_banner()


func show_notice(text: String) -> void:
	if text.is_empty():
		return
	banner.text = text
	banner.visible = true
	_notice_left_s = net.room_chat_show_s
	_place_banner()


## The room changed (members, host, settings): the line and the menu.
func refresh_room() -> void:
	_line_key = -1
	if menu.visible:
		menu.refresh()


func _relayout() -> void:
	if hud == null:
		return
	if not _pinned and is_inside_tree():
		_full = Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
		_safe = HudLayout.canvas_safe_rect(_full)
	var ts := style.ts
	var m := hud.edge_margin_px
	var g := hud.spacing_grid_px
	nametags.position = Vector2.ZERO
	nametags.size = _full.size
	# The strip: centred in the top margin, over the sun bar.
	var sw := minf(net.room_strip_width_px * ts, _safe.size.x - m * 2.0)
	var sh := net.room_strip_dot_px * ts * 2.0
	strip.size = Vector2(sw, sh)
	strip.position = Vector2(_safe.get_center().x - sw * 0.5, _safe.position.y + maxf((m - sh) * 0.5, 0.0))
	# Under the score panel: the room line, then the feed.
	var x := _safe.position.x + m
	var y := _safe.position.y + m + hud.score_size_px.y * ts + g
	line.position = Vector2(x, y)
	line.size = line.get_combined_minimum_size()
	# N6.2: the crew line with the train badge beside it, the crew total, then the feed.
	y += maxf(line.size.y, HudDraw.cap_height(line.font_px()) * 2.0)
	_crew_top = y
	_place_crew()
	y += maxf(crew_line.size.y, train_badge.get_combined_minimum_size().y)
	_feed_top = y + g
	# Feed lines end before the event stack's column (HudLayout's, same canvas and text size).
	var lay := HudLayout.new()
	lay.build(hud, _full, _safe, null, ts)
	_feed_max_w = maxf(lay.stack.position.x - x - g, 0.0)
	_place_feed()
	# Top-right, under the pause / camera buttons and the high-beam slot: REJOIN CREW and
	# ROOM (the right thumb reaches them; clear of its zone at the bottom).
	var bw := net.room_button_width_px * ts
	var top := _safe.position.y + m + hud.button_size_px.y * ts * 2.0 + g * 2.0
	room_button.size = Vector2(bw * ROOM_SHARE, hud.touch_target_px)
	room_button.position = Vector2(_safe.end.x - m - room_button.size.x, top)
	rejoin_button.size = Vector2(bw, hud.touch_target_px)
	rejoin_button.position = Vector2(room_button.position.x - g - bw, top)
	menu.place(_safe.grow(-m))
	_place_toast()
	_place_banner()


var _feed_top: float = 0.0
var _crew_top: float = 0.0
var _feed_max_w: float = INF


## "name#1234  TEXT", the name shortened with an ellipsis until the line fits _feed_max_w.
func _fit_feed(who: String, text: String) -> String:
	var line_text := TEXT_FEED % [who, text]
	var t := feed[0]
	if style == null or t.style == null:
		return line_text
	var f := t.font()
	var fs := t.font_px()
	var name_text := who
	while HudDraw.text_width(f, line_text, fs) > _feed_max_w and name_text.length() > 1:
		name_text = name_text.left(name_text.length() - 1)
		line_text = TEXT_FEED % [name_text + TEXT_ELLIPSIS, text]
	return line_text


## The crew line, and the train badge on its row after it (their centres level).
func _place_crew() -> void:
	if hud == null:
		return
	var x := _safe.position.x + hud.edge_margin_px
	var a := crew_line.get_combined_minimum_size()
	var b := train_badge.get_combined_minimum_size()
	var row := maxf(a.y, b.y)
	crew_line.size = a
	crew_line.position = Vector2(x, _crew_top + (row - a.y) * 0.5)
	train_badge.size = b
	train_badge.position = Vector2(x + a.x + hud.spacing_grid_px * 2.0, _crew_top + (row - b.y) * 0.5)


func _place_feed() -> void:
	var y := _feed_top
	for t in feed:
		t.position = Vector2(_safe.position.x + hud.edge_margin_px, y)
		t.size = t.get_combined_minimum_size()
		y += t.size.y + hud.spacing_grid_px * 0.5


## The toast in the event stack's column, a third down the screen.
func _place_toast() -> void:
	if hud == null:
		return
	var ts := style.ts
	var pad := hud.panel_padding_px * ts
	var a := toast_title.get_combined_minimum_size()
	var b := toast_sub.get_combined_minimum_size()
	var w := maxf(a.x, b.x) + pad * 2.0
	toast.size = Vector2(w, a.y + b.y + pad * 2.0)
	toast.position = Vector2(_safe.get_center().x - w * 0.5, _safe.position.y + _safe.size.y * TOAST_TOP)
	toast_title.position = Vector2((w - a.x) * 0.5, pad)
	toast_title.size = a
	toast_sub.position = Vector2((w - b.x) * 0.5, pad + a.y)
	toast_sub.size = b


func _place_banner() -> void:
	if hud == null:
		return
	var s := banner.get_combined_minimum_size()
	banner.size = s
	var top := _safe.position.y + hud.edge_margin_px + (hud.sun_bar_size_px.y + hud.chain_row_size_px.y) * style.ts \
		+ hud.spacing_grid_px * 2.0
	banner.position = Vector2(_safe.get_center().x - s.x * 0.5, top)


## Layout proportions: the toast's top (share of the safe height), ROOM's width (share of
## the button width).
const TOAST_TOP := 0.3   # lint: allow-number layout proportion
const ROOM_SHARE := 0.6   # lint: allow-number layout proportion
## Change keys of the crew line (packing its values into one int).
const CREW_KEY_NEAR := 100000
const CREW_KEY_FACTOR := 100.0   # lint: allow-number two decimals of the factor

