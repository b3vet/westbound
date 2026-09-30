class_name RoomMenu
extends Control
## The room menu over the drive: quick chat (phrases, horn, emotes), the players (mute
## each one; leave the room) and N9.3's ROOM tab (the invite link, and for the host the
## room's settings and removing a player). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms,
## parties and matchmaking → Private rooms ("The creator gets a code and an invite link
## ... The creator is host: they can kick players and change density or time mode"),
## Quick chat ("A small wheel of preset phrases ... Plus a horn and a few emotes shown on
## the nametag. Rate-limited, and muted per player from the room menu"), Client changes
## (Room menu: invite, crew total, mute players, host settings, leave).
## docs/ROOMS_CLIENT.md → Room HUD, Host settings (N9.3). WP N5.2, N9.3.
##
## Three tabs on one panel: CHAT (a 3 x 3 grid: the six phrases, HONK, two emotes),
## PLAYERS (a button per player, a tap mutes / unmutes them; LEAVE ROOM; N6.2: the session
## crew total beside it, spec: "shown in the room menu") and ROOM (INVITE: the link with
## COPY LINK and SHARE; the host of a private room: TRAFFIC and TIME OF DAY, sent as
## `room_host_command`s, and REMOVE A PLAYER: PLAYERS then takes a tap, and a second tap
## within `confirm_tap_s`, to kick). Every button is a ScreenButton at least
## touch_target_px tall: emulated mouse events, never a raw touch index. Chat, mute and
## leave are intents RoomHud forwards; host commands go to the session. Built once; hidden
## = `visible = false`.

signal chat_pressed(item: Dictionary)
signal mute_pressed(player_id: int)
signal leave_pressed()
signal closed()

enum Tab { CHAT, PLAYERS, ROOM }

const TEXT_CHAT := "CHAT"
const TEXT_PLAYERS := "PLAYERS"
const TEXT_ROOM_TAB := "ROOM"
const TEXT_CLOSE := "CLOSE"
const TEXT_LEAVE := "LEAVE ROOM"
const TEXT_MUTED := "MUTED · TAP TO UNMUTE"
const TEXT_MUTE := "TAP TO MUTE"
const TEXT_YOU := "YOU"
const TEXT_HOST := "HOST"
const TEXT_ROOM := "ROOM %s"
const TEXT_SUB := "%s  ·  %s  ·  %s"
const TEXT_PRIVATE := "PRIVATE"
const TEXT_PUBLIC := "PUBLIC"
const TEXT_WAIT := "WAIT"
const TEXT_CREW_TOTAL := "CREW TOTAL %s"
# N9.3: the ROOM tab.
const TEXT_INVITE := "INVITE"
const TEXT_COPY_LINK := "COPY LINK"
const TEXT_SHARE := "SHARE"
const TEXT_COPIED := "LINK COPIED"
const TEXT_COPY_FAILED := "COULDN'T COPY  ·  THE CODE IS %s"
const TEXT_SHARE_TITLE := "Westbound"
const TEXT_SHARE_BODY := "Drive the Westbound loop with me: %s"
const TEXT_DENSITY := "TRAFFIC"
const TEXT_TIME := "TIME OF DAY"
const TEXT_HOST_ONLY := "ONLY THE HOST CHANGES TRAFFIC AND TIME"
const TEXT_PUBLIC_RULES := "PUBLIC ROOM  ·  NORMAL TRAFFIC ON THE WORLD CLOCK"
const TEXT_KICK_MODE := "REMOVE A PLAYER"
const TEXT_TAP_KICK := "TAP TO REMOVE"
const TEXT_TAP_AGAIN := "TAP AGAIN TO REMOVE"
const DENSITY_LABELS: Array[String] = ["LIGHT", "NORMAL", "RUSH HOUR"]
const TIME_LABELS: Array[String] = ["CYCLE", "MORNING", "GOLDEN", "NIGHT"]
const TIME_CYCLE := 0
const TIME_MORNING := 1
const TIME_GOLDEN := 2
const TIME_NIGHT := 3
## Grid columns (chat) and player columns.
const CHAT_COLS := 3
const PLAYER_COLS := 2
## The emotes offered on the chat grid (NetRoomChat.EMOTE_TEXT ids).
const CHAT_EMOTES: Array[int] = [0, 1]
const MS_PER_MIN := 60000.0   # lint: allow-number unit conversion
const USEC_PER_S := 1000000.0   # lint: allow-number unit conversion

var style: HudStyle
var hud: HudTuning
var net: NetTuning
var session: NetRoomSession
var tab: Tab = Tab.CHAT
## The invite link shown on ROOM ("" = the code alone; NetRooms.invite_url by default).
var invite_url: String = ""
## Web glue for copy / share (tests swap in a mock).
var bridge := NetJsBridge.new()
## PLAYERS removes instead of muting (the host's REMOVE A PLAYER).
var kick_mode: bool = false

var panel: ScreenPanel
var title: ScreenText
var sub: ScreenText
var chat_tab: ScreenButton
var players_tab: ScreenButton
var room_tab: ScreenButton
var close_button: ScreenButton
var leave_button: ScreenButton
## N6.2: the session crew total (PLAYERS, beside LEAVE ROOM).
var crew_total: ScreenText
var chat_buttons: Array[ScreenButton] = []
var player_buttons: Array[ScreenButton] = []
## Player id per player button (-1 = unused).
var player_ids := PackedInt32Array()
## N9.3: the ROOM tab.
var link_text: ScreenText
var link_note: ScreenText
var copy_button: ScreenButton
var share_button: ScreenButton
var host_note: ScreenText
var density_label: ScreenText
var time_label: ScreenText
var density_buttons: Array[ScreenButton] = []
var time_buttons: Array[ScreenButton] = []
var kick_button: ScreenButton

var _items: Array[Dictionary] = []
var _version: int = -1
var _kick_armed: int = -1
var _kick_until_us: int = 0


func _init() -> void:
	name = "RoomMenu"
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	visible = false
	panel = ScreenPanel.new()
	panel.edge = ScreenPanel.Edge.ACCENT
	add_child(panel)
	title = ScreenText.make("", ScreenText.Face.LABEL, 24, ScreenText.Ink.TEXT)
	panel.add_child(title)
	sub = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	panel.add_child(sub)
	chat_tab = _button(TEXT_CHAT, ScreenButton.Kind.OPTION, func() -> void: show_tab(Tab.CHAT))
	players_tab = _button(TEXT_PLAYERS, ScreenButton.Kind.OPTION, func() -> void: show_tab(Tab.PLAYERS))
	room_tab = _button(TEXT_ROOM_TAB, ScreenButton.Kind.OPTION, func() -> void: show_tab(Tab.ROOM))
	close_button = _button(TEXT_CLOSE, ScreenButton.Kind.NORMAL, close)
	for i in NetRoomChat.PHRASE_TEXT.size():
		_items.append(NetRoomChat.phrase_item(i))
	_items.append(NetRoomChat.horn_item())
	for e in CHAT_EMOTES:
		_items.append(NetRoomChat.emote_item(e))
	for item in _items:
		var it := item
		var b := _button(NetRoomChat.text_of(it), ScreenButton.Kind.NORMAL, func() -> void: _chat(it))
		b.align = HORIZONTAL_ALIGNMENT_CENTER
		chat_buttons.append(b)
	for i in NetCodec.MAX_ROOM_PLAYERS:
		var k := i
		var b := _button("", ScreenButton.Kind.OPTION, func() -> void: _player(k))
		b.align = HORIZONTAL_ALIGNMENT_LEFT
		player_buttons.append(b)
	player_ids.resize(NetCodec.MAX_ROOM_PLAYERS)
	player_ids.fill(-1)
	leave_button = _button(TEXT_LEAVE, ScreenButton.Kind.DANGER, leave_pressed.emit)
	crew_total = ScreenText.make("", ScreenText.Face.LABEL, 20, ScreenText.Ink.GOLD)
	crew_total.name = "CrewTotal"
	panel.add_child(crew_total)
	# N9.3: ROOM.
	link_text = _label("", 18, ScreenText.Ink.TEXT)
	link_note = _label("", 16, ScreenText.Ink.ACCENT)
	copy_button = _button(TEXT_COPY_LINK, ScreenButton.Kind.NORMAL, copy_link)
	share_button = _button(TEXT_SHARE, ScreenButton.Kind.NORMAL, share_link)
	host_note = _label("", 16, ScreenText.Ink.MUTED)
	density_label = _label(TEXT_DENSITY, 16, ScreenText.Ink.MUTED)
	time_label = _label(TEXT_TIME, 16, ScreenText.Ink.MUTED)
	for i in DENSITY_LABELS.size():
		var k := i
		var b := _button(DENSITY_LABELS[i], ScreenButton.Kind.OPTION, func() -> void: set_density(k))
		b.align = HORIZONTAL_ALIGNMENT_CENTER
		density_buttons.append(b)
	for i in TIME_LABELS.size():
		var k := i
		var b := _button(TIME_LABELS[i], ScreenButton.Kind.OPTION, func() -> void: set_time(k))
		b.align = HORIZONTAL_ALIGNMENT_CENTER
		time_buttons.append(b)
	kick_button = _button(TEXT_KICK_MODE, ScreenButton.Kind.DANGER, start_kick)


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 20)
	b.name = label.capitalize().replace(" ", "") if not label.is_empty() else "Player"
	b.pressed.connect(action)
	panel.add_child(b)
	return b


func _label(t: String, px: int, ink: ScreenText.Ink) -> ScreenText:
	var s := ScreenText.make(t, ScreenText.Face.LABEL, px, ink)
	panel.add_child(s)
	return s


func setup(s: HudStyle, hud_tuning: HudTuning, net_tuning: NetTuning, room_session: NetRoomSession) -> void:
	style = s
	hud = hud_tuning
	net = net_tuning
	session = room_session
	panel.fill_alpha = 1.0 / maxf(s.panel_fill.a, 0.01)   # opaque: nothing reads through it
	panel.setup(s)
	for c in panel.get_children():
		if c is ScreenButton:
			(c as ScreenButton).setup(s)
		elif c is ScreenText:
			(c as ScreenText).setup(s)
	refresh()


func open(which: Tab = Tab.CHAT) -> void:
	visible = true
	link_note.text = ""
	refresh()
	show_tab(which)


func close() -> void:
	kick_mode = false
	_kick_armed = -1
	if visible:
		visible = false
		closed.emit()


func is_open() -> bool:
	return visible


func show_tab(which: Tab) -> void:
	if which != Tab.PLAYERS and kick_mode:
		kick_mode = false
		_kick_armed = -1
		_version = -1
		refresh()
	tab = which
	chat_tab.selected = which == Tab.CHAT
	players_tab.selected = which == Tab.PLAYERS
	room_tab.selected = which == Tab.ROOM
	for b in chat_buttons:
		b.visible = which == Tab.CHAT
	for i in player_buttons.size():
		player_buttons[i].visible = which == Tab.PLAYERS and player_ids[i] >= 0
	leave_button.visible = which == Tab.PLAYERS
	crew_total.visible = which == Tab.PLAYERS
	var room := which == Tab.ROOM
	var host := room and _can_host()
	for c: CanvasItem in [link_text, link_note, copy_button, host_note]:
		c.visible = room
	share_button.visible = room and SocialUi.can_share(bridge)
	for c: CanvasItem in [density_label, time_label, kick_button]:
		c.visible = host
	for b: ScreenButton in density_buttons + time_buttons:
		b.visible = host
	host_note.visible = room and not host
	_layout()


## The title, the players and the chat buttons' state from the room (on open, on a room
## change, and while the chat rate limit runs).
func refresh() -> void:
	if session == null:
		return
	var r := session.room
	var can_chat := session.chat_ready()
	for b in chat_buttons:
		b.disabled = not can_chat
		b.note = "" if can_chat else TEXT_WAIT
	if _kick_armed >= 0 and Time.get_ticks_usec() >= _kick_until_us:
		_kick_armed = -1
		_version = -1
	if r.version == _version:
		return
	_version = r.version
	var me := r.me()
	crew_total.text = TEXT_CREW_TOTAL % HudFormat.thousands(int(r.crew_totals.get(me.crew_slot, 0)) if me != null else 0)
	title.text = TEXT_ROOM % r.code
	sub.text = TEXT_SUB % [TEXT_PUBLIC if r.is_public() else TEXT_PRIVATE, r.density.to_upper(),
		r.time_mode.to_upper()]
	player_ids.fill(-1)
	var k := 0
	for m in r.members:
		if k >= player_buttons.size():
			break
		var b := player_buttons[k]
		player_ids[k] = m.player_id
		b.text = m.nametag()
		var notes: Array[String] = []
		if m.player_id == r.you:
			notes.append(TEXT_YOU)
		if m.host:
			notes.append(TEXT_HOST)
		if m.player_id != r.you:
			if kick_mode:
				notes.append(TEXT_TAP_AGAIN if m.player_id == _kick_armed else TEXT_TAP_KICK)
			else:
				notes.append(TEXT_MUTED if m.muted else TEXT_MUTE)
		b.note = "  ·  ".join(notes)
		b.selected = m.player_id == _kick_armed if kick_mode else m.muted
		b.disabled = m.player_id == r.you
		k += 1
	_refresh_room()
	show_tab(tab)


## The ROOM tab from the room: the link, the settings selected, why they are locked.
func _refresh_room() -> void:
	var r := session.room
	var url := _invite_url()
	link_text.text = "%s  %s" % [TEXT_INVITE, url if not url.is_empty() else r.code]
	copy_button.text = TEXT_COPY_LINK
	var d := NetCodec.DENSITY.find(r.density)
	for i in density_buttons.size():
		density_buttons[i].selected = i == d
	var tc := _time_choice()
	for i in time_buttons.size():
		time_buttons[i].selected = i == tc
	host_note.text = TEXT_PUBLIC_RULES if r.is_public() else TEXT_HOST_ONLY


func _invite_url() -> String:
	if not invite_url.is_empty():
		return invite_url
	var rooms := NetRooms.current
	if rooms != null and is_instance_valid(rooms) and session != null:
		return rooms.invite_url(session.room.code)
	return ""


## The host of a private room changes it (public rooms have no host).
func _can_host() -> bool:
	return session != null and session.room.is_host() and not session.room.is_public()


## The TIME OF DAY choice the room's settings match (fixed times: the nearer preset).
func _time_choice() -> int:
	var r := session.room
	match r.time_mode:
		"night":
			return TIME_NIGHT
		"fixed":
			var morning := net.room_fixed_morning_min * MS_PER_MIN
			var golden := net.room_fixed_golden_min * MS_PER_MIN
			var f := float(r.fixed_cycle_ms)
			return TIME_MORNING if absf(f - morning) <= absf(f - golden) else TIME_GOLDEN
	return TIME_CYCLE


## TRAFFIC (host): `room_host_command.set_density`.
func set_density(k: int) -> void:
	if not _can_host():
		return
	session.send_host({"kind": "set_density",
		"density": String(NetCodec.DENSITY[clampi(k, 0, NetCodec.DENSITY.size() - 1)])})


## TIME OF DAY (host): `room_host_command.set_time_mode` (MORNING / GOLDEN are fixed times).
func set_time(k: int) -> void:
	if not _can_host():
		return
	var tm := "cycle"
	var fixed := 0
	match k:
		TIME_MORNING:
			tm = "fixed"
			fixed = roundi(net.room_fixed_morning_min * MS_PER_MIN)
		TIME_GOLDEN:
			tm = "fixed"
			fixed = roundi(net.room_fixed_golden_min * MS_PER_MIN)
		TIME_NIGHT:
			tm = "night"
	session.send_host({"kind": "set_time_mode", "time_mode": tm, "fixed_cycle_ms": fixed})


## REMOVE A PLAYER (host): PLAYERS, where a tap arms and a second tap kicks.
func start_kick() -> void:
	if not _can_host():
		return
	kick_mode = true
	_kick_armed = -1
	_version = -1
	tab = Tab.PLAYERS
	refresh()


func copy_link() -> void:
	var url := _invite_url()
	var code := session.room.code if session != null else ""
	var ok := SocialUi.copy_text(bridge, url if not url.is_empty() else code)
	link_note.text = TEXT_COPIED if ok else TEXT_COPY_FAILED % code
	link_note.set_ink(ScreenText.Ink.ACCENT if ok else ScreenText.Ink.HOT)
	_layout()


func share_link() -> void:
	var url := _invite_url()
	if url.is_empty() and session != null:
		url = session.room.code
	SocialUi.share(bridge, TEXT_SHARE_TITLE, TEXT_SHARE_BODY % url)


func _chat(item: Dictionary) -> void:
	chat_pressed.emit(item)
	refresh()


func _player(k: int) -> void:
	var pid := player_ids[k]
	if pid < 0:
		return
	if not kick_mode:
		mute_pressed.emit(pid)
		return
	var now := Time.get_ticks_usec()
	if _kick_armed == pid and now < _kick_until_us:
		session.send_host({"kind": "kick", "player_id": pid})
		kick_mode = false
		_kick_armed = -1
	else:
		_kick_armed = pid
		_kick_until_us = now + roundi(net.confirm_tap_s * USEC_PER_S)
	_version = -1
	refresh()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


## The panel centred in `area` (canvas px).
func place(area: Rect2) -> void:
	position = Vector2.ZERO
	size = area.end
	_area = area
	_layout()


var _area: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)


func _layout() -> void:
	if style == null:
		return
	var ts := style.ts
	var g := hud.spacing_grid_px
	var pad := hud.panel_padding_px * ts
	var th := hud.touch_target_px
	var w := minf(net.room_panel_width_px * ts, _area.size.x)
	var inner := w - pad * 2.0
	var cols := CHAT_COLS if tab == Tab.CHAT else PLAYER_COLS
	var n := chat_buttons.size()
	if tab == Tab.PLAYERS:
		n = 0
		for pid in player_ids:
			if pid >= 0:
				n += 1
	@warning_ignore("integer_division")
	var rows := (n + cols - 1) / cols
	var ts_h := title.get_combined_minimum_size().y + sub.get_combined_minimum_size().y
	var head := maxf(th, ts_h)
	# Header: the title left; CHAT, PLAYERS, ROOM, CLOSE right, each as wide as it needs.
	var x := w - pad
	for b: ScreenButton in [close_button, room_tab, players_tab, chat_tab]:
		var bw := maxf(SocialUi.button_width(b, hud), inner * TAB_SHARE)
		x -= bw
		b.size = Vector2(bw, th)
		b.position = Vector2(x, pad)
		x -= g
	title.position = Vector2(pad, pad)
	title.size = title.get_combined_minimum_size()
	sub.position = Vector2(pad, pad + title.size.y)
	sub.size = sub.get_combined_minimum_size()
	var top := pad + head + g
	var h := top
	if tab == Tab.ROOM:
		h = _layout_room(pad, top, inner, th, g)
	else:
		var cw := (inner - g * float(cols - 1)) / float(cols)
		var list: Array[ScreenButton] = chat_buttons if tab == Tab.CHAT else player_buttons
		var k := 0
		for b in list:
			if not b.visible:
				continue
			@warning_ignore("integer_division")
			var row := k / cols
			b.position = Vector2(pad + float(k % cols) * (cw + g), top + float(row) * (th + g))
			b.size = Vector2(cw, th)
			k += 1
		leave_button.size = Vector2(cw, th)
		leave_button.position = Vector2(pad, top + float(rows) * (th + g))
		var cs := crew_total.get_combined_minimum_size()
		crew_total.size = cs
		crew_total.position = Vector2(pad + cw + g, leave_button.position.y + (th - cs.y) * 0.5)
		h = top + float(rows) * (th + g)
		if tab == Tab.PLAYERS:
			h += th + g
	h = minf(h - g + pad, _area.size.y)
	panel.size = Vector2(w, h)
	panel.position = _area.position + (_area.size - panel.size) * 0.5


## The ROOM tab from `top`: the link line with COPY LINK (and SHARE), then the host's
## TRAFFIC and TIME OF DAY rows and REMOVE A PLAYER, or why they are locked. Returns the
## bottom (with a grid gap).
func _layout_room(pad: float, top: float, inner: float, th: float, g: float) -> float:
	var y := top
	var bw := maxf(SocialUi.button_width(copy_button, hud), inner * TAB_SHARE)
	var sw := maxf(SocialUi.button_width(share_button, hud), inner * TAB_SHARE) if share_button.visible else 0.0
	copy_button.size = Vector2(bw, th)
	copy_button.position = Vector2(pad + inner - bw - (sw + g if sw > 0.0 else 0.0), y)
	share_button.size = Vector2(sw, th)
	share_button.position = Vector2(pad + inner - sw, y)
	var room_w := copy_button.position.x - pad - g
	var full := link_text.text
	SocialUi.fit_text(link_text, full, room_w)
	var ls := link_text.get_combined_minimum_size()
	link_text.size = ls
	link_text.position = Vector2(pad, y + (th - ls.y) * 0.5)
	y += th + g
	if not link_note.text.is_empty():
		link_note.size = link_note.get_combined_minimum_size()
		link_note.position = Vector2(pad, y)
		y += link_note.size.y + g
	if host_note.visible:
		host_note.size = host_note.get_combined_minimum_size()
		host_note.position = Vector2(pad, y)
		return y + host_note.size.y + g
	for pair: Array in [[density_label, density_buttons], [time_label, time_buttons]]:
		var label := pair[0] as ScreenText
		var buttons: Array[ScreenButton] = []
		buttons.assign(pair[1])
		label.size = label.get_combined_minimum_size()
		label.position = Vector2(pad, y)
		y += label.size.y + g * 0.5
		var cw := (inner - g * float(buttons.size() - 1)) / float(buttons.size())
		for i in buttons.size():
			buttons[i].position = Vector2(pad + float(i) * (cw + g), y)
			buttons[i].size = Vector2(cw, th)
		y += th + g
	var kw := maxf(SocialUi.button_width(kick_button, hud), inner * KICK_SHARE)
	kick_button.size = Vector2(kw, th)
	kick_button.position = Vector2(pad, y)
	return y + th + g


## The header's tab and close buttons: at least this share of the panel's inner width.
const TAB_SHARE := 0.15   # lint: allow-number layout proportion
## REMOVE A PLAYER: at least this share of the inner width.
const KICK_SHARE := 0.35   # lint: allow-number layout proportion
