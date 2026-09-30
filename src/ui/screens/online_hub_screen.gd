class_name OnlineHubScreen
extends RunScreen
## The online hub (WP8.5; rooms N5.2). Spec: multiplayer handoff → Client changes ("Online
## hub: Quick Join, room browser, create a private room, join by code"; "Party panel and
## friends list"; "Crew page"; "Leaderboards"), Rooms, parties and matchmaking.
## docs/SCREENS.md → Online hub.
##
## Over the title's attract drive, on the same slanted band:
##   - ONLINE (speed-tilted) top-left, the player and the online status under it; BACK
##     top-right (Esc too);
##   - a ROOMS panel: QUICK JOIN, ROOM BROWSER, PRIVATE ROOM and JOIN BY CODE (N5.2: the
##     RoomLobbyPanel over the hub; when the room's snapshot arrives the hub emits
##     room_ready(session) and the run drives in the room). Without the online server
##     (`?server=off`, native dev runs) or while offline the buttons are disabled and the
##     panel says why (NetRooms.unavailable_text); a message from the last room (kicked,
##     closed, connection lost) shows there too;
##   - LOOP PRACTICE (primary, bottom-left thumb): the run in loop mode (`?mode=loop`), solo
##     on the multiplayer loop, which works offline;
##   - FRIENDS, CREW and LEADERBOARDS up from the right thumb. FRIENDS and CREW open the
##     account view on that tab (they need a session: disabled, ONLINE OFF, without one);
##     LEADERBOARDS opens on the Loop season board.
## Emits intents only (loop_practice, social, back, room_ready).

signal loop_practice()
signal social(view: int)
signal back()
## N5.2: a room was joined; the run drives in it (Run.start_room).
signal room_ready(session: NetRoomSession)

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_TITLE := "ONLINE"
const TEXT_BACK := "BACK"
const TEXT_LOOP := "LOOP PRACTICE"
const TEXT_LOOP_NOTE := "SOLO ON THE LOOP · WORKS OFFLINE"
const TEXT_ROOMS := "ROOMS"
const TEXT_ROOMS_SOON := "UP TO 8 PLAYERS"
const TEXT_ROOMS_NOTE := "Drive the loop with friends and crews."
const TEXT_UNAVAILABLE := "OFFLINE"
const TEXT_QUICK_JOIN := "QUICK JOIN"
const TEXT_BROWSER := "ROOM BROWSER"
const TEXT_PRIVATE := "PRIVATE ROOM"
const TEXT_CODE := "JOIN BY CODE"
const TEXT_SOON := "SOON"
const TEXT_FRIENDS := "FRIENDS"
const TEXT_CREW := "CREW"
const TEXT_LEADERBOARDS := "LEADERBOARDS"
const TEXT_OFF := "ONLINE OFF"
const TEXT_STATUS := "%s  ·  %s"
const TEXT_NO_SESSION := "ONLINE IS OFF IN THIS BUILD  ·  LOOP PRACTICE STILL WORKS"
# N9.3: the party row.
const TEXT_PARTY := "PARTY"
const TEXT_PARTY_NONE := "NO PARTY  ·  PLAY WITH FRIENDS AS ONE CREW"
const TEXT_PARTY_LEAD := "%d/%d  ·  YOU LEAD"
const TEXT_PARTY_MEMBER := "%d/%d  ·  %s LEADS"
const TEXT_PARTY_INVITES := "%s INVITES YOU"
const TEXT_FRIEND_ROOM := "FRIEND'S ROOM"
## Base sizes (canvas px at 100% text size).
const STATUS_PX := 16
const CAPTION_PX := 20
const NOTE_PX := 16

var band: TitleBand
var dim: ColorRect
var title: ScreenText
var status: ScreenText
var back_button: ScreenButton
var rooms_panel: ScreenPanel
var rooms_caption: ScreenText
var rooms_soon: ScreenText
var rooms_note: ScreenText
var room_buttons: Array[ScreenButton] = []
var loop_button: ScreenButton
var loop_caption: ScreenText
var friends_button: ScreenButton
var crew_button: ScreenButton
var boards_button: ScreenButton
var leaderboards: LeaderboardsScreen
var runs: NetRunsClient
## The session shown (null: NetSession.current).
var session: NetSession
## N5.2: the rooms service (null: NetRooms.ensure()).
var rooms: NetRooms
var lobby: RoomLobbyPanel
## The run's input hub (the code field mutes it while typing).
var input_hub: PlayerInput
## The last room's parting message (kicked, closed, connection lost), "" = none.
var room_message: String = ""
## N9.3: PARTY and the party's line in the ROOMS panel.
var party_button: ScreenButton
var party_line: ScreenText
## The party line's whole text (the line shows it shortened to its room).
var party_text: String = TEXT_PARTY_NONE
## The session whose signals the hub follows (party, invites, party moves).
var _bound: NetRoomSession
var _party_version: int = -1


func _init() -> void:
	super._init()
	name = "OnlineHub"
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.visible = false
	add_child(dim)
	band = TitleBand.new()
	band.name = "Band"
	add_child(band)
	title = ScreenText.make(TEXT_TITLE, ScreenText.Face.DISPLAY, 60, ScreenText.Ink.TEXT)
	title.name = "Heading"
	add_child(title)
	status = ScreenText.make("", ScreenText.Face.LABEL, STATUS_PX, ScreenText.Ink.MUTED)
	status.name = "Status"
	add_child(status)
	back_button = _button(TEXT_BACK, ScreenButton.Kind.NORMAL, back.emit, self)
	rooms_panel = ScreenPanel.new()
	rooms_panel.name = "Rooms"
	add_child(rooms_panel)
	rooms_caption = ScreenText.make(TEXT_ROOMS, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.TEXT)
	rooms_panel.add_child(rooms_caption)
	rooms_soon = ScreenText.make(TEXT_ROOMS_SOON, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.GOLD)
	rooms_panel.add_child(rooms_soon)
	rooms_note = ScreenText.make(TEXT_ROOMS_NOTE, ScreenText.Face.BODY, NOTE_PX, ScreenText.Ink.MUTED)
	rooms_panel.add_child(rooms_note)
	var actions: Array[Callable] = [open_quick_join, open_browser, open_private, open_code]
	var labels: Array[String] = [TEXT_QUICK_JOIN, TEXT_BROWSER, TEXT_PRIVATE, TEXT_CODE]
	for i in labels.size():
		var b := _button(labels[i], ScreenButton.Kind.NORMAL, actions[i], rooms_panel)
		room_buttons.append(b)
	party_button = _button(TEXT_PARTY, ScreenButton.Kind.NORMAL, open_party, rooms_panel)
	party_line = ScreenText.make(TEXT_PARTY_NONE, ScreenText.Face.LABEL, NOTE_PX, ScreenText.Ink.MUTED)
	party_line.name = "PartyLine"
	rooms_panel.add_child(party_line)
	loop_caption = ScreenText.make(TEXT_LOOP_NOTE, ScreenText.Face.LABEL, STATUS_PX, ScreenText.Ink.ACCENT)
	loop_caption.name = "LoopCaption"
	add_child(loop_caption)
	loop_button = _button(TEXT_LOOP, ScreenButton.Kind.PRIMARY, loop_practice.emit, self)
	boards_button = _button(TEXT_LEADERBOARDS, ScreenButton.Kind.NORMAL, open_leaderboards, self)
	crew_button = _button(TEXT_CREW, ScreenButton.Kind.NORMAL,
			func() -> void: social.emit(ProfilePanel.View.CREW), self)
	friends_button = _button(TEXT_FRIENDS, ScreenButton.Kind.NORMAL,
			func() -> void: social.emit(ProfilePanel.View.FRIENDS), self)
	# N5.2: the room flows' panel, over everything else on the hub.
	lobby = RoomLobbyPanel.new()
	lobby.joined.connect(_on_room_joined)
	lobby.closed.connect(func() -> void:
		dim.visible = false
		refresh())
	lobby.friends_requested.connect(func() -> void:
		lobby.close()
		social.emit(ProfilePanel.View.FRIENDS))
	add_child(lobby)
	visibility_changed.connect(_sync_follows)


## N9.3: the friends list's JOIN (a friend in a room with space) and INVITE (an online
## friend to your party) while the hub exists.
func _enter_tree() -> void:
	NetSocialClient.join_handler = join_friend
	NetSocialClient.invite_handler = invite_friend


func _exit_tree() -> void:
	if NetSocialClient.join_handler == Callable(join_friend):
		NetSocialClient.join_handler = Callable()
	if NetSocialClient.invite_handler == Callable(invite_friend):
		NetSocialClient.invite_handler = Callable()


func _button(label: String, kind: ScreenButton.Kind, action: Callable, parent: Node) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 24)
	b.name = label.capitalize().replace(" ", "")
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _restyled() -> void:
	band.setup(style)
	title.size_px = tuning.font_title_px
	title.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	for b: ScreenButton in _buttons():
		b.size_px = tuning.font_screen_button_px
	if leaderboards != null:
		leaderboards.setup(style, tuning)
	lobby.hub = input_hub
	lobby.setup(style, tuning, NetTuning.load_default())
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	_layout()


func _buttons() -> Array[ScreenButton]:
	var out: Array[ScreenButton] = [back_button, loop_button, boards_button, crew_button, friends_button]
	out.append_array(room_buttons)
	out.append(party_button)
	return out


func open() -> void:
	if leaderboards != null:
		leaderboards.close(false)
	if lobby.is_open():
		lobby.close()
	dim.visible = false
	refresh()
	super.open()
	# N9.3: the lobby connection while the hub shows (presence, party, invites).
	var r := _rooms()
	if r != null and r.available():
		r.connect_lobby()
	_bind_session()
	var i := 0
	for c: Control in [title, status, rooms_panel, loop_caption, loop_button, friends_button, crew_button, boards_button]:
		slide_in(c, -tuning.screen_slide_px, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)
		i += 1


## The status line and the buttons that need a session.
func refresh() -> void:
	var s := _session()
	if s == null:
		status.text = TEXT_NO_SESSION
		status.set_ink(ScreenText.Ink.MUTED)
	else:
		var n := s.profile.full_name if s.profile != null and not s.profile.full_name.is_empty() \
				else TitleProfileChip.TEXT_PLAYER
		status.text = TEXT_STATUS % [n, String(ProfilePanel.STATUS_LABEL.get(s.status, TEXT_OFF))]
		status.set_ink(ScreenText.Ink.ACCENT if s.is_online() else ScreenText.Ink.MUTED)
	for b: ScreenButton in [friends_button, crew_button]:
		b.disabled = s == null
		b.note = TEXT_OFF if s == null else ""
	# N5.2: rooms need the server and a signed-in session.
	var why := _rooms_unavailable()
	for b: ScreenButton in room_buttons + [party_button]:
		b.disabled = not why.is_empty()
		b.note = "" if why.is_empty() else (TEXT_OFF if _rooms() == null else TEXT_UNAVAILABLE)
	_refresh_party()
	if not room_message.is_empty():
		rooms_note.text = room_message
		rooms_note.set_ink(ScreenText.Ink.HOT)
	elif not why.is_empty():
		rooms_note.text = why
		rooms_note.set_ink(ScreenText.Ink.MUTED)
	else:
		rooms_note.text = TEXT_ROOMS_NOTE
		rooms_note.set_ink(ScreenText.Ink.MUTED)
	_layout()


# ---------------------------------------------------------------- Rooms (N5.2)

func _rooms() -> NetRooms:
	if rooms != null and is_instance_valid(rooms):
		return rooms
	return NetRooms.ensure()


## Why rooms can't be used now ("" = they can).
func _rooms_unavailable() -> String:
	var r := _rooms()
	return NetRooms.TEXT_OFF if r == null else r.why_unavailable()


## The last room's parting message on the ROOMS panel (the run calls this on the way back).
func show_room_message(text: String) -> void:
	room_message = text
	refresh()


func open_quick_join() -> void:
	if _open_lobby():
		lobby.quick_join()


func open_browser() -> void:
	if _open_lobby():
		lobby.open_browser()


func open_private() -> void:
	if _open_lobby():
		lobby.open_create()


func open_code() -> void:
	if _open_lobby():
		lobby.open_code()


func _open_lobby() -> bool:
	var r := _rooms()
	if r == null or not r.available():
		refresh()
		return false
	room_message = ""
	lobby.rooms = r
	lobby.place(safe)
	dim.visible = true
	_bind_session()
	return true


func lobby_open() -> bool:
	return lobby != null and lobby.is_open()


func _on_room_joined(s: NetRoomSession) -> void:
	dim.visible = false
	room_ready.emit(s)


# ---------------------------------------------------------------- Party (N9.3)

## PARTY: the party view (or the newest invite first).
func open_party() -> void:
	if not _open_lobby():
		return
	var r := _rooms()
	if r.session.party.newest_invite() != null and not r.session.party.in_party():
		lobby.open_invite()
	else:
		lobby.open_party()


## The friends list's JOIN: the friend's room, through the joining status on the hub.
func join_friend(friend: NetSocialPlayer) -> void:
	if friend == null or friend.room_id <= 0:
		return
	_show_hub()
	if _open_lobby():
		lobby.join_room(friend.room_id, TEXT_FRIEND_ROOM)


## The friends list's INVITE: a party invite to an online friend (a party is made first
## when there is none).
func invite_friend(friend: NetSocialPlayer) -> void:
	var r := _rooms()
	if friend == null or r == null or not r.available():
		return
	r.party_invite(friend.account_id)


## Opens the hub over the title when it is not showing (a friend's JOIN from the account
## view, an invite link): TitleScreens owns the screens.
func _show_hub() -> void:
	if visible:
		return
	var ts := get_parent()
	if ts != null and ts.has_method(&"open_hub"):
		ts.call(&"open_hub")


## The party's line in the ROOMS panel.
func _refresh_party() -> void:
	var r := _rooms()
	var p := r.session.party if r != null and r.session != null else null
	_party_version = p.version if p != null else -1
	if p == null or (not p.in_party() and p.newest_invite() == null):
		party_text = TEXT_PARTY_NONE
		party_line.set_ink(ScreenText.Ink.MUTED)
	elif not p.in_party():
		party_text = TEXT_PARTY_INVITES % p.newest_invite().from_name
		party_line.set_ink(ScreenText.Ink.GOLD)
	elif p.is_leader():
		party_text = TEXT_PARTY_LEAD % [p.members.size(), net_party_max()]
		party_line.set_ink(ScreenText.Ink.ACCENT)
	else:
		party_text = TEXT_PARTY_MEMBER % [p.members.size(), net_party_max(), p.leader_name()]
		party_line.set_ink(ScreenText.Ink.ACCENT)


func net_party_max() -> int:
	var r := _rooms()
	return r.session.tuning.party_max_members if r != null and r.session != null else 0


## Follows the rooms session: party changes redraw the line, an invite opens its card
## while the hub shows, and a room the party moved to (a join nobody on the hub asked for)
## goes to the run.
func _bind_session() -> void:
	var r := _rooms()
	var s := r.session if r != null else null
	if s == _bound:
		_sync_follows()
		return
	if _bound != null:
		for p: Array in _signal_pairs(_bound):
			if (p[0] as Signal).is_connected(p[1]):
				(p[0] as Signal).disconnect(p[1])
	_bound = s
	if s != null:
		for p: Array in _signal_pairs(s):
			(p[0] as Signal).connect(p[1])
	_sync_follows()


func _signal_pairs(s: NetRoomSession) -> Array:
	return [[s.party_changed, _on_party_changed], [s.party_invited, _on_party_invited],
		[s.joined, _on_session_joined]]


## A room snapshot nobody asked for (the party leader moved the party) is taken while the
## hub shows.
func _sync_follows() -> void:
	if _bound != null:
		_bound.accept_follows = is_visible_in_tree()


func _on_party_changed() -> void:
	if visible:
		refresh()


func _on_party_invited(inv: NetParty.Invite) -> void:
	if visible and not lobby_open() and not leaderboards_open():
		_open_lobby()
		lobby.open_invite(inv.code)
	if visible:
		refresh()


func _on_session_joined(_room: NetRoomState) -> void:
	if lobby_open() or not visible:
		return   # the panel's own join (it emits joined), or not on the hub
	room_message = ""
	dim.visible = false
	room_ready.emit(_bound)


## An invite link (`?room=` / `--room=`): once signed in, on the title or the hub, the hub
## opens and follows it (a room code, else a party code).
func _process(_delta: float) -> void:
	if _party_version >= 0 and _bound != null and _bound.party.version != _party_version and visible:
		refresh()
	if NetInviteLink.peek().is_empty():
		return
	var r := _rooms()
	if r == null or not r.available() or not _title_showing():
		return
	var code := NetInviteLink.take()
	_show_hub()
	if _open_lobby():
		lobby.follow_link(code)


## The title screens show the title or the hub (not a run, not the first-run chooser).
func _title_showing() -> bool:
	if visible:
		return true
	var ts := get_parent()
	var title_node := ts.get(&"title") as Control if ts != null else null
	return title_node != null and title_node.is_visible_in_tree()


func _session() -> NetSession:
	if session != null and is_instance_valid(session):
		return session
	var c := NetSession.current
	return c if c != null and is_instance_valid(c) else null


## LEADERBOARDS: the boards over the hub, on the Loop season board.
func open_leaderboards() -> void:
	var first := leaderboards == null
	var c := runs if runs != null and is_instance_valid(runs) else NetRunsClient.ensure()
	leaderboards = LeaderboardsScreen.attach(self, leaderboards, c)
	if first:
		leaderboards.closed_by_player.connect(func() -> void:
			dim.visible = false
			_layout())
	dim.visible = true
	leaderboards.open_over(self, NetBoards.LOOP)


func leaderboards_open() -> bool:
	return leaderboards != null and leaderboards.is_open()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or leaderboards_open() or lobby_open():
		return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		back.emit()


func _layout() -> void:
	if style == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	var bw := tuning.menu_button_width_px
	var ts := style.ts
	dim.position = Vector2.ZERO
	dim.size = full.size
	band.position = Vector2.ZERO
	band.size = full.size
	# Header: ONLINE and the status line; BACK top-right.
	var hs := title.get_combined_minimum_size()
	title.position = a.position
	title.size = hs
	var ss := status.get_combined_minimum_size()
	status.position = Vector2(a.position.x, a.position.y + hs.y)
	status.size = ss
	var bkw := SocialUi.button_width(back_button, tuning)
	back_button.size = Vector2(maxf(bkw, bw * BACK_WIDTH), th)
	back_button.position = Vector2(a.end.x - back_button.size.x, a.position.y)
	# LOOP PRACTICE: bottom-left.
	var pb := tuning.primary_button_size_px
	var lw := maxf(bw, SocialUi.button_width(loop_button, tuning))
	loop_button.size = Vector2(lw, pb.y)
	loop_button.position = Vector2(a.position.x, a.end.y - pb.y)
	var lcs := loop_caption.get_combined_minimum_size()
	loop_caption.position = Vector2(a.position.x, loop_button.position.y - g - lcs.y)
	loop_caption.size = lcs
	# The ROOMS panel between the header and LOOP PRACTICE: two rows of two buttons.
	var pad := tuning.panel_padding_px * ts
	var rw := bw * ROOM_WIDTH
	for b in room_buttons:
		rw = maxf(rw, SocialUi.button_width(b, tuning))
	lobby.place(safe)
	var cs := rooms_caption.get_combined_minimum_size()
	var sn := rooms_soon.get_combined_minimum_size()
	var ns := rooms_note.get_combined_minimum_size()
	rw = maxf(rw, SocialUi.button_width(party_button, tuning))
	# Two rows of room buttons; N9.3: a third column with PARTY over the party's line.
	var pw := maxf(rw * 3.0 + g * 2.0 + pad * 2.0, ns.x + pad * 2.0)
	SocialUi.fit_text(party_line, party_text, rw)
	var pls := party_line.get_combined_minimum_size()
	var head := cs.y + ns.y
	var ph := pad * 2.0 + head + g + th * 2.0 + g
	var top := status.position.y + ss.y + g * 2.0
	rooms_panel.position = Vector2(a.position.x, top)
	rooms_panel.size = Vector2(pw, ph)
	rooms_caption.position = Vector2(pad, pad)
	rooms_caption.size = cs
	rooms_soon.position = Vector2(pad + cs.x + g * 2.0, pad)
	rooms_soon.size = sn
	rooms_note.position = Vector2(pad, pad + cs.y)
	rooms_note.size = ns
	for i in room_buttons.size():
		@warning_ignore("integer_division")
		var row := i / 2
		var col := i % 2
		room_buttons[i].position = Vector2(pad + float(col) * (rw + g), pad + head + g + float(row) * (th + g))
		room_buttons[i].size = Vector2(rw, th)
	var px := pad + 2.0 * (rw + g)
	var py := pad + head + g
	party_button.position = Vector2(px, py)
	party_button.size = Vector2(rw, th)
	party_line.position = Vector2(px, py + th + g + (th - pls.y) * 0.5)
	party_line.size = pls
	band.width = maxf(tuning.title_band_width_px, rooms_panel.position.x + pw + m)
	# FRIENDS, CREW, LEADERBOARDS: up from the right thumb.
	var sw := bw * SIDE_WIDTH
	for b: ScreenButton in [friends_button, crew_button, boards_button]:
		sw = maxf(sw, SocialUi.button_width(b, tuning))
	var y := a.end.y
	for b: ScreenButton in [boards_button, crew_button, friends_button]:
		y -= th
		b.position = Vector2(a.end.x - sw, y)
		b.size = Vector2(sw, th)
		y -= g


## Layout proportions of the menu width: BACK, a room button, the right column.
const BACK_WIDTH := 0.5   # lint: allow-number layout proportion
const ROOM_WIDTH := 0.75   # lint: allow-number layout proportion
const SIDE_WIDTH := 0.7   # lint: allow-number layout proportion
