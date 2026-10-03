class_name InviteToast
extends CanvasLayer
## Invites where the player is (protocol 2): a small, non-blocking toast for a room invite
## or a crew invite while the title shows or a single-player run is on, and the lobby
## connection kept open on the title so invites reach a player who never opened the online
## hub. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and matchmaking (Friends
## and presence; "Push notifications for invites while the app is closed are out of scope
## for v1": invites reach a running game only), UI → Screens (toasts never pause play);
## the owner's requests (invite friends or crew into a private room; invite friends to the
## crew). docs/ROOMS_CLIENT.md → Room invites.
##
##   ┌──────────────────────────────────────┐
##   │ DUSTY#1234 INVITES YOU TO A ROOM     │   gold
##   │ PRIVATE ROOM K7QX2M  ·  3/8 PLAYERS  │
##   │                     [LATER] [JOIN]   │   title only
##   └──────────────────────────────────────┘
##
## - **Title:** JOIN (`join_requested(code)`: TitleScreens opens the hub and joins by the
##   code) and LATER (the invite waits: the hub shows its card). Top-right, under the
##   profile chip.
## - **Single-player run:** the same lines without buttons, for `invite_toast_s`, where the
##   achievement toast goes (HudAchievementLayer.place): a run is never interrupted; the
##   invite waits for the title (its own toast with JOIN) and the hub (its card).
## - **Online hub / a room run:** nothing here (the hub shows the card; in a room the
##   invite waits for the hub).
## - **Crew invites** (`lobby_event.crew_invite`): the same toast, text only, everywhere but
##   the hub (the hub has its gold line; the crew page answers).
## Each invite toasts once per place (`NetRoomInvites.Invite.toast_title` / `toast_run`).
## Processes always (cheap checks per frame; a toast shows in real time). Hidden, nothing
## draws.

signal join_requested(code: String)

enum Place { NONE, TITLE, HUB, RUN }

const TEXT_ROOM := "%s INVITES YOU TO A ROOM"
const TEXT_ROOM_SUB := "%s ROOM %s  ·  %d/%d PLAYERS"
const TEXT_ROOM_RUN := "OPEN ONLINE AFTER THIS RUN TO JOIN"
const TEXT_PRIVATE := "PRIVATE"
const TEXT_PUBLIC := "PUBLIC"
const TEXT_CREW := "%s INVITES YOU TO THEIR CREW"
const TEXT_CREW_SUB := "FROM %s  ·  ANSWER ON THE CREW PAGE"
const TEXT_JOIN := "JOIN"
const TEXT_LATER := "LATER"
const LINE_PX := 20
const SUB_PX := 16
const LAYER_ABOVE := 1
const USEC_PER_S := 1000000.0   # lint: allow-number unit conversion
## The toast's width on the title: at most this share of the safe width.
const MAX_WIDTH_SHARE := 0.5   # lint: allow-number layout proportion

## The title screens this toast serves (where the player is; the layout's style).
var titles: TitleScreens
var net: NetTuning
var style: HudStyle
var tuning: HudTuning
## The rooms service (null: NetRooms.current) and social client (null:
## NetSocialClient.of(NetSession.current)); tests set both.
var rooms: NetRooms
var social: NetSocialClient

var root: Control
var panel: ScreenPanel
var line: ScreenText
var sub: ScreenText
var join_button: ScreenButton
var later_button: ScreenButton
## The room invite on show ("" = a crew invite, or nothing).
var room_code: String = ""
## Where the toast on show belongs.
var shown_at: Place = Place.NONE

var _left_s: float = 0.0
var _crew_queue: Array[NetCrew.Invite] = []
var _bound_social: NetSocialClient
var _next_lobby_us: int = 0
var _line_full: String = ""
var _sub_full: String = ""
var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()


func _init() -> void:
	name = "InviteToast"
	process_mode = Node.PROCESS_MODE_ALWAYS
	root = Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	panel = ScreenPanel.new()
	panel.name = "Panel"
	panel.edge = ScreenPanel.Edge.ACCENT
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	line = ScreenText.make("", ScreenText.Face.LABEL, LINE_PX, ScreenText.Ink.GOLD)
	line.name = "Line"
	panel.add_child(line)
	sub = ScreenText.make("", ScreenText.Face.LABEL, SUB_PX, ScreenText.Ink.MUTED)
	sub.name = "Sub"
	panel.add_child(sub)
	later_button = ScreenButton.make(TEXT_LATER, ScreenButton.Kind.NORMAL, LINE_PX)
	later_button.name = "Later"
	later_button.pressed.connect(later)
	panel.add_child(later_button)
	join_button = ScreenButton.make(TEXT_JOIN, ScreenButton.Kind.PRIMARY, LINE_PX)
	join_button.name = "Join"
	join_button.pressed.connect(join)
	panel.add_child(join_button)
	panel.visible = false


func setup(s: HudStyle, t: HudTuning, net_tuning: NetTuning) -> void:
	style = s
	tuning = t
	net = net_tuning
	layer = TitleScreens.LAYER + LAYER_ABOVE
	panel.fill_alpha = 1.0 / maxf(s.panel_fill.a, 0.01)   # opaque
	panel.setup(s)
	for c: ScreenText in [line, sub]:
		c.setup(s)
	for b: ScreenButton in [join_button, later_button]:
		b.setup(s)
	if showing():
		_layout()


## Pins the canvas and safe rects (tests, previews); otherwise the viewport's.
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe
	if showing():
		_layout()


func showing() -> bool:
	return panel.visible


## Canvas items drawing now (0 when no toast shows).
func visible_item_count() -> int:
	return TitleScreens._count_visible(panel) if panel.visible else 0


func _rooms() -> NetRooms:
	if rooms != null and is_instance_valid(rooms):
		return rooms
	return NetRooms.current if NetRooms.current != null and is_instance_valid(NetRooms.current) else null


func _social() -> NetSocialClient:
	if social != null:
		return social
	return NetSocialClient.of(NetSession.current)


## Where the player is: the title (or its other screens), the hub, a run, or nowhere yet.
func place() -> Place:
	if titles == null or not titles.is_built():
		return Place.NONE
	if titles.online_hub.visible:
		return Place.HUB
	if titles.is_open():
		return Place.TITLE
	return Place.RUN


func _process(delta: float) -> void:
	advance(delta / Engine.time_scale if Engine.time_scale > 0.0 else delta)


## One step (tests call it directly with their own `dt`).
func advance(real_dt: float) -> void:
	if style == null:
		return
	var where := place()
	_follow_social()
	if where == Place.TITLE:
		_keep_lobby()
	if showing():
		if where != shown_at or (not room_code.is_empty() and _room_session() != null
				and _room_session().room_invites.find(room_code) == null):
			hide_toast()
		elif shown_at == Place.RUN or room_code.is_empty():
			_left_s -= real_dt
			if _left_s <= 0.0:
				hide_toast()
		return
	if where == Place.TITLE or where == Place.RUN:
		_show_next(where)


## The lobby connection on the title (signed in), so invites arrive (and friends see the
## player online); a failed one is tried again every `lobby_title_retry_s`.
func _keep_lobby() -> void:
	if net == null or not net.lobby_on_title:
		return
	var now := Time.get_ticks_usec()
	if now < _next_lobby_us:
		return
	_next_lobby_us = now + roundi(net.lobby_title_retry_s * USEC_PER_S)
	var r := rooms if rooms != null and is_instance_valid(rooms) else NetRooms.ensure()
	if r == null or not r.available() or r.session == null:
		return
	var st := r.session.state
	if st == NetRoomSession.State.IDLE or st == NetRoomSession.State.FAILED:
		r.connect_lobby()


func _room_session() -> NetRoomSession:
	var r := _rooms()
	return r.session if r != null else null


func _follow_social() -> void:
	var c := _social()
	if c == _bound_social:
		return
	if _bound_social != null and _bound_social.crew_invited.is_connected(_on_crew_invited):
		_bound_social.crew_invited.disconnect(_on_crew_invited)
	_bound_social = c
	if c != null:
		c.crew_invited.connect(_on_crew_invited)


func _on_crew_invited(inv: NetCrew.Invite) -> void:
	_crew_queue.append(inv)


## The next room invite this place has not toasted, else the next crew invite (not on
## the hub, not in a room run).
func _show_next(where: Place) -> void:
	var s := _room_session()
	if s != null and s.is_in_room():
		_crew_queue.clear()
		return
	var title := where == Place.TITLE
	var inv := s.room_invites.next_for_toast(title) if s != null else null
	if inv != null:
		if title:
			inv.toast_title = true
		else:
			inv.toast_run = true
		room_code = inv.code
		_line_full = TEXT_ROOM % inv.from_name
		_sub_full = TEXT_ROOM_SUB % [TEXT_PUBLIC if inv.is_public() else TEXT_PRIVATE, inv.code,
			inv.players, inv.max_players] if title else TEXT_ROOM_RUN
		_show(where, title)
		return
	if not _crew_queue.is_empty():
		var c: NetCrew.Invite = _crew_queue.pop_front()
		room_code = ""
		_line_full = TEXT_CREW % c.crew_text()
		_sub_full = TEXT_CREW_SUB % c.from_name
		_show(where, false)


func _show(where: Place, buttons: bool) -> void:
	shown_at = where
	_left_s = net.invite_toast_s
	join_button.visible = buttons
	later_button.visible = buttons
	panel.mouse_filter = Control.MOUSE_FILTER_STOP if buttons else Control.MOUSE_FILTER_IGNORE
	panel.visible = true
	_layout()


func hide_toast() -> void:
	panel.visible = false
	room_code = ""
	shown_at = Place.NONE


## JOIN (title): the hub joins the room by the invite's code.
func join() -> void:
	var code := room_code
	hide_toast()
	if not code.is_empty():
		join_requested.emit(code)


## LATER (title): the invite waits for the hub's card.
func later() -> void:
	hide_toast()


func _layout() -> void:
	if style == null:
		return
	var full := _pinned_full
	var safe := _pinned_safe
	if not _pinned:
		full = Rect2(Vector2.ZERO, root.get_viewport_rect().size) if root.is_inside_tree() \
				else Rect2(0.0, 0.0, 1280.0, 720.0)
		safe = HudLayout.canvas_safe_rect(full)
	root.position = Vector2.ZERO
	root.size = full.size
	var ts := style.ts
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var pad := tuning.panel_padding_px * ts
	var m := tuning.edge_margin_px
	var a := safe.grow(-m)
	var w := minf(net.invite_toast_width_px * ts, a.size.x * MAX_WIDTH_SHARE)
	var pos := Vector2(a.end.x - w, a.position.y + th + g)
	if shown_at == Place.RUN:
		var hud := root.get_tree().get_first_node_in_group(Hud.GROUP) as Hud if root.is_inside_tree() else null
		if hud != null and hud.visible and hud.layout.full == full:
			var r := HudAchievementLayer.place(hud.layout, AchievementTuning.load_default(), tuning, ts)
			pos = r.position
			w = r.size.x
	var inner := w - pad * 2.0
	SocialUi.fit_text(line, _line_full, inner)
	SocialUi.fit_text(sub, _sub_full, inner)
	var ls := line.get_combined_minimum_size()
	var ss := sub.get_combined_minimum_size()
	line.position = Vector2(pad, pad)
	line.size = ls
	sub.position = Vector2(pad, pad + ls.y)
	sub.size = ss
	var h := pad * 2.0 + ls.y + ss.y
	if join_button.visible:
		var bw := maxf(SocialUi.button_width(join_button, tuning), SocialUi.button_width(later_button, tuning))
		var y := pad + ls.y + ss.y + g
		join_button.size = Vector2(bw, th)
		join_button.position = Vector2(w - pad - bw, y)
		later_button.size = Vector2(bw, th)
		later_button.position = Vector2(w - pad - bw * 2.0 - g, y)
		h = y + th + pad
	panel.position = pos
	panel.size = Vector2(w, h)
