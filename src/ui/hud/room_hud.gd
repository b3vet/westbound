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
## their text changes. The text size applies live (Settings `text_scale`, WP9.3: restyle()).

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

var _pinned: bool = false
var _full: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var _safe: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var _toast_left_s: float = 0.0
var _notice_left_s: float = 0.0
var _reconnecting: bool = false
var _line_key: int = -1
var _banner_key: int = -1
var _feed_left := PackedFloat32Array()
## The feed lines in full (a shown line is shortened with "..." to stop short of the event
## stack's column, where the toast and banner sit: WP9.3, 125 % text on a 16:9 canvas).
var _feed_full := PackedStringArray()
var _lay := HudLayout.new()


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
	for i in net.room_chat_feed_lines:
		var t := ScreenText.make("", ScreenText.Face.LABEL, net.room_font_px, ScreenText.Ink.TEXT)
		t.name = "Feed%d" % i
		t.outline = true
		t.visible = false
		add_child(t)
		feed.append(t)
	_feed_left.resize(feed.size())
	_feed_left.fill(0.0)
	_feed_full.resize(feed.size())
	_restyle_all()
	strip.setup(style, net, net.room_max_remotes)
	nametags.setup(style, net, net.room_max_remotes)
	nametags.clock = func() -> float: return float(session.time.now_usec()) / NetRoomSession.USEC_PER_S
	line.size_px = net.room_font_px
	if not session.room_changed.is_connected(refresh_room):
		session.room_changed.connect(refresh_room)
	_relayout()
	refresh_room()


## The text size changed (WP9.3; Accessibility → text size): every piece takes the new
## style and the layout is rebuilt.
func restyle() -> void:
	if hud == null:
		return
	_restyle_all()
	strip.queue_redraw()
	nametags.queue_redraw()
	_relayout()
	refresh_room()


func _restyle_all() -> void:
	style.setup(UiTheme.load_theme(), hud, hud.clamp_text_scale(float(Settings.get_value(&"text_scale"))))
	for c in get_children():
		if c is ScreenButton:
			(c as ScreenButton).setup(style)
		elif c is ScreenText:
			(c as ScreenText).setup(style)
		elif c is ScreenPanel:
			(c as ScreenPanel).setup(style)
	for c in toast.get_children():
		(c as ScreenText).setup(style)
	menu.setup(style, hud, net, session)


func _enter_tree() -> void:
	if not Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)


func _on_setting_changed(key: StringName) -> void:
	if key == &"text_scale":
		restyle()


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


## The server's run_result for this player: the crash-out toast (spec: 3 s). The score is
## the server's official one (0 until N6) or `local_score` when higher.
func show_result(result: Dictionary, local_score: int = 0) -> void:
	var score := maxi(int(result.get("score", 0)), local_score)
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


func is_toast_shown() -> bool:
	return toast.visible


## A feed line ("Dusty#1234  GG"), in the sender's crew color; the oldest goes.
func add_feed(who: String, text: String, color: Color) -> void:
	if feed.is_empty():
		return
	for i in range(feed.size() - 1, 0, -1):
		_feed_full[i] = _feed_full[i - 1]
		feed[i].modulate = feed[i - 1].modulate
		feed[i].visible = feed[i - 1].visible
		_feed_left[i] = _feed_left[i - 1]
	_feed_full[0] = TEXT_FEED % [who, text]
	feed[0].modulate = color
	feed[0].visible = true
	_feed_left[0] = net.room_chat_show_s
	_place_feed()


func feed_text(i: int) -> String:
	return _feed_full[i] if i < feed.size() and feed[i].visible else ""


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
	_lay.build(hud, _full, _safe, null, ts)
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
	_feed_top = y + maxf(line.size.y, HudDraw.cap_height(line.font_px()) * 2.0) + g
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


func _place_feed() -> void:
	var y := _feed_top
	var x := _safe.position.x + hud.edge_margin_px
	var max_w := maxf(_lay.stack.position.x - hud.spacing_grid_px - x, 0.0)
	for i in feed.size():
		var t := feed[i]
		SocialUi.fit_text(t, _feed_full[i], max_w)
		t.position = Vector2(x, y)
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
