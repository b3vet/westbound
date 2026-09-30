class_name RoomMenu
extends Control
## The room menu over the drive: quick chat (phrases, horn, emotes) and the players (mute
## each one; leave the room). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and
## matchmaking → Quick chat ("A small wheel of preset phrases ... Plus a horn and a few
## emotes shown on the nametag. Rate-limited, and muted per player from the room menu"),
## Client changes (Room menu: invite, crew total, mute players, host settings, leave).
## docs/ROOMS_CLIENT.md → Room HUD. WP N5.2.
##
## Two tabs on one panel: CHAT (a 3 x 3 grid: the six phrases, HONK, two emotes) and
## PLAYERS (a button per other player, a tap mutes / unmutes them; LEAVE ROOM; N6.2: the
## session crew total beside it, spec: "shown in the room menu"). Every
## button is a ScreenButton at least touch_target_px tall: emulated mouse events, never a
## raw touch index. Emits intents only; RoomHud forwards them. Built once; hidden =
## `visible = false`.

signal chat_pressed(item: Dictionary)
signal mute_pressed(player_id: int)
signal leave_pressed()
signal closed()

enum Tab { CHAT, PLAYERS }

const TEXT_CHAT := "CHAT"
const TEXT_PLAYERS := "PLAYERS"
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
## Grid columns (chat) and player columns.
const CHAT_COLS := 3
const PLAYER_COLS := 2
## The emotes offered on the chat grid (NetRoomChat.EMOTE_TEXT ids).
const CHAT_EMOTES: Array[int] = [0, 1]

var style: HudStyle
var hud: HudTuning
var net: NetTuning
var session: NetRoomSession
var tab: Tab = Tab.CHAT

var panel: ScreenPanel
var title: ScreenText
var sub: ScreenText
var chat_tab: ScreenButton
var players_tab: ScreenButton
var close_button: ScreenButton
var leave_button: ScreenButton
## N6.2: the session crew total (PLAYERS, beside LEAVE ROOM).
var crew_total: ScreenText
var chat_buttons: Array[ScreenButton] = []
var player_buttons: Array[ScreenButton] = []
## Player id per player button (-1 = unused).
var player_ids := PackedInt32Array()

var _items: Array[Dictionary] = []
var _version: int = -1


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


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 20)
	b.name = label.capitalize().replace(" ", "") if not label.is_empty() else "Player"
	b.pressed.connect(action)
	panel.add_child(b)
	return b


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
	refresh()
	show_tab(which)


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func is_open() -> bool:
	return visible


func show_tab(which: Tab) -> void:
	tab = which
	chat_tab.selected = which == Tab.CHAT
	players_tab.selected = which == Tab.PLAYERS
	for b in chat_buttons:
		b.visible = which == Tab.CHAT
	for i in player_buttons.size():
		player_buttons[i].visible = which == Tab.PLAYERS and player_ids[i] >= 0
	leave_button.visible = which == Tab.PLAYERS
	crew_total.visible = which == Tab.PLAYERS
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
			notes.append(TEXT_MUTED if m.muted else TEXT_MUTE)
		b.note = "  ·  ".join(notes)
		b.selected = m.muted
		b.disabled = m.player_id == r.you
		k += 1
	show_tab(tab)


func _chat(item: Dictionary) -> void:
	chat_pressed.emit(item)
	refresh()


func _player(k: int) -> void:
	var pid := player_ids[k]
	if pid >= 0:
		mute_pressed.emit(pid)


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
	var h := pad * 2.0 + head + g + float(rows) * (th + g)
	if tab == Tab.PLAYERS:
		h += th + g
	h = minf(h, _area.size.y)
	panel.size = Vector2(w, h)
	panel.position = _area.position + (_area.size - panel.size) * 0.5
	# Header: the title left; CHAT, PLAYERS, CLOSE right.
	var tw := (w - pad * 2.0) * TAB_SHARE
	close_button.size = Vector2(tw, th)
	close_button.position = Vector2(w - pad - tw, pad)
	players_tab.size = Vector2(tw, th)
	players_tab.position = close_button.position - Vector2(tw + g, 0.0)
	chat_tab.size = Vector2(tw, th)
	chat_tab.position = players_tab.position - Vector2(tw + g, 0.0)
	title.position = Vector2(pad, pad)
	title.size = title.get_combined_minimum_size()
	sub.position = Vector2(pad, pad + title.size.y)
	sub.size = sub.get_combined_minimum_size()
	var top := pad + head + g
	var cw := (w - pad * 2.0 - g * float(cols - 1)) / float(cols)
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


## The header's tab and close buttons: a share of the panel's inner width each.
const TAB_SHARE := 0.18   # lint: allow-number layout proportion
