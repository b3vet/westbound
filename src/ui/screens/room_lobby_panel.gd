class_name RoomLobbyPanel
extends Control
## The online hub's room flows: PRIVATE ROOM (host options), JOIN BY CODE, the ROOM
## BROWSER and the joining status (QUICK JOIN and every join); N9.3: the PARTY (create,
## join by code, members, kick, invite friends, share the link, leave), a PARTY INVITE
## (accept, decline) and invite links (a room or a party code); protocol 2: a ROOM INVITE
## (a friend's or crewmate's room: JOIN by its code, DECLINE). Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and matchmaking (Private rooms: "The
## creator gets a code and an invite link ... can change density or time mode"; Time of
## day: "the host can pick the cycle, a fixed time of day, or permanent night"; Public
## rooms: Quick Join, "The room browser lists public rooms with player count, density, day
## or night, and your ping"; Parties: "Up to 8 players, led by one player. The leader
## invites online friends, or shares a party code"); Client changes (Online hub; Party
## panel). docs/SCREENS.md → Online hub → Rooms (N5.2), Party (N9.3). WP N5.2, N9.3.
##
## A panel over the hub, one view at a time. It calls the rooms service and shows where the
## join is; when the room's snapshot arrives it emits `joined(session)` (the hub hands it
## to the run) and closes. Every button is a ScreenButton at least touch_target_px tall.

signal joined(session: NetRoomSession)
signal closed()
## N9.3: INVITE FRIENDS (the hub opens the friends list).
signal friends_requested()

enum View { STATUS, CREATE, CODE, BROWSER, PARTY, INVITE, ROOM_INVITE }

const TEXT_QUICK := "QUICK JOIN"
const TEXT_PRIVATE := "PRIVATE ROOM"
const TEXT_CODE := "JOIN BY CODE"
const TEXT_BROWSER := "ROOM BROWSER"
const TEXT_BACK := "BACK"
const TEXT_CANCEL := "CANCEL"
const TEXT_RETRY := "TRY AGAIN"
const TEXT_CREATE := "CREATE ROOM"
const TEXT_JOIN := "JOIN"
const TEXT_REFRESH := "REFRESH"
const TEXT_DENSITY := "TRAFFIC"
const TEXT_TIME := "TIME OF DAY"
const DENSITY_LABELS: Array[String] = ["LIGHT", "NORMAL", "RUSH HOUR"]
const TIME_LABELS: Array[String] = ["CYCLE", "MORNING", "GOLDEN", "NIGHT"]
const TIME_CYCLE := 0
const TIME_MORNING := 1
const TIME_GOLDEN := 2
const TIME_NIGHT := 3
const TEXT_CONNECTING := "CONNECTING..."
const TEXT_FINDING := "FINDING A ROOM..."
const TEXT_CREATING := "CREATING YOUR ROOM..."
const TEXT_JOINING := "JOINING %s..."
const TEXT_JOINING_ROOM := "JOINING ROOM %d..."
const TEXT_CODE_PH := "ROOM CODE"
const TEXT_CODE_PROMPT := "Room code (6 characters)"
const TEXT_CODE_BAD := "A code is 6 letters and digits."
const TEXT_CODE_NOTE := "ASK THE HOST FOR THE 6-CHARACTER CODE"
const TEXT_EMPTY := "NO PUBLIC ROOMS YET  ·  QUICK JOIN STARTS ONE"
const TEXT_LOADING := "LOOKING FOR ROOMS..."
const TEXT_ROW := "%d/%d  ·  %s  ·  %s  ·  %d MS"
const TEXT_DAY := "DAY"
const TEXT_NIGHT := "NIGHT ×2"
const TEXT_CREATE_NOTE := "PRIVATE: ONLY PLAYERS WITH THE CODE CAN JOIN"
# N9.3: party, invites, links.
const TEXT_PARTY := "PARTY"
const TEXT_PARTY_CODE := "PARTY  %s"
const TEXT_CREATE_PARTY := "CREATE PARTY"
const TEXT_JOIN_PARTY := "JOIN PARTY"
const TEXT_INVITE_FRIENDS := "INVITE FRIENDS"
const TEXT_SHARE_LINK := "SHARE LINK"
const TEXT_COPY_LINK := "COPY LINK"
const TEXT_LEAVE_PARTY := "LEAVE PARTY"
const TEXT_PARTY_NONE := "PLAY TOGETHER: A PARTY MOVES BETWEEN ROOMS AS ONE CREW"
const TEXT_PARTY_LEAD := "QUICK JOIN AND ROOMS YOU PICK TAKE THE WHOLE PARTY"
const TEXT_PARTY_MEMBER := "%s PICKS THE ROOM  ·  YOU FOLLOW"
const TEXT_PARTY_ALONE := "INVITE FRIENDS OR SHARE THE LINK"
const TEXT_PARTY_CODE_PH := "PARTY CODE"
const TEXT_PARTY_CODE_PROMPT := "Party code (6 characters)"
const TEXT_PARTY_CODE_NOTE := "ASK THE PARTY LEADER FOR THE CODE OR THE LINK"
const TEXT_CREATING_PARTY := "MAKING YOUR PARTY..."
const TEXT_JOINING_PARTY := "JOINING PARTY %s..."
const TEXT_LEADER := "LEADER"
const TEXT_YOU := "YOU"
const TEXT_KICK := "TAP AGAIN TO REMOVE"
const TEXT_COPIED := "LINK COPIED"
const TEXT_COPY_FAILED := "COULDN'T COPY  ·  CODE %s"
const TEXT_SHARE_TITLE := "Westbound"
const TEXT_SHARE_BODY := "Drive the Westbound loop with me: %s"
const TEXT_INVITE := "PARTY INVITE"
const TEXT_INVITE_FROM := "%s INVITES YOU"
const TEXT_INVITE_NOTE := "JOIN THEIR PARTY: YOU MOVE BETWEEN ROOMS TOGETHER"
const TEXT_ACCEPT := "ACCEPT"
const TEXT_DECLINE := "DECLINE"
const TEXT_LINK := "INVITE LINK"
const TEXT_LINK_NONE := "No room or party with that code."
# Protocol 2: a room invite.
const TEXT_ROOM_INVITE := "ROOM INVITE"
const TEXT_ROOM_INVITE_FROM := "%s INVITES YOU TO THEIR ROOM"
const TEXT_ROOM_INVITE_NOTE := "%s ROOM %s  ·  %d/%d PLAYERS"
const TEXT_ROOM_PRIVATE := "PRIVATE"
const TEXT_ROOM_PUBLIC := "PUBLIC"
## Browser rows shown at most (the list is fullest first).
const BROWSER_ROWS := 4
## Party member rows: two columns.
const PARTY_COLS := 2
const MS_PER_MIN := 60000.0   # lint: allow-number unit conversion
const MS_PER_S := 1000.0   # lint: allow-number unit conversion
const USEC_PER_S := 1000000.0   # lint: allow-number unit conversion

var style: HudStyle
var tuning: HudTuning
var net: NetTuning
var rooms: NetRooms
var hub: PlayerInput
var view: View = View.STATUS
var density: int = 1
var time_choice: int = TIME_CYCLE
## The request the STATUS view shows (TRY AGAIN repeats it).
var request_title: String = TEXT_QUICK
## The CODE view asks for a party code (N9.3) instead of a room code.
var code_for_party: bool = false
## The invite the INVITE view shows (its code).
var invite_code: String = ""
## Protocol 2: the room invite the ROOM_INVITE view shows (its room code).
var room_invite_code: String = ""
## An invite link being followed: tried as a room code, then as a party code.
var link_code: String = ""
## Web glue for copy / share (tests swap in a mock).
var bridge := NetJsBridge.new()

## Dims the hub behind the panel (the whole canvas).
var backdrop: ColorRect
var panel: ScreenPanel
var title: ScreenText
var status: ScreenText
var note: ScreenText
var back_button: ScreenButton
var action_button: ScreenButton
var density_label: ScreenText
var time_label: ScreenText
var density_buttons: Array[ScreenButton] = []
var time_buttons: Array[ScreenButton] = []
var code_field: SocialField
var row_buttons: Array[ScreenButton] = []
var row_ids := PackedInt32Array()
## N9.3: the party's members (account ids per button, "" = unused).
var member_buttons: Array[ScreenButton] = []
var member_ids: PackedStringArray = []
var join_party_button: ScreenButton
var invite_button: ScreenButton
var share_button: ScreenButton
var leave_party_button: ScreenButton

var _retry: Callable
var _area: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var _browse_left_s: float = 0.0
var _session: NetRoomSession
## The member a first tap armed for removal, and until when (usec).
var _kick_armed: String = ""
var _kick_until_us: int = 0
var _party_version: int = -1


func _init() -> void:
	name = "RoomLobby"
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	visible = false
	backdrop = ColorRect.new()
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	panel = ScreenPanel.new()
	panel.edge = ScreenPanel.Edge.ACCENT
	add_child(panel)
	title = _text("", ScreenText.Face.DISPLAY, 36, ScreenText.Ink.TEXT)
	status = _text("", ScreenText.Face.LABEL, 20, ScreenText.Ink.ACCENT)
	note = _text("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	density_label = _text(TEXT_DENSITY, ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	time_label = _text(TEXT_TIME, ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	for i in DENSITY_LABELS.size():
		var k := i
		density_buttons.append(_button(DENSITY_LABELS[i], ScreenButton.Kind.OPTION, func() -> void: _pick_density(k)))
	for i in TIME_LABELS.size():
		var k := i
		time_buttons.append(_button(TIME_LABELS[i], ScreenButton.Kind.OPTION, func() -> void: _pick_time(k)))
	code_field = SocialField.new()
	code_field.name = "CodeField"
	code_field.placeholder_text = TEXT_CODE_PH
	code_field.prompt_message = TEXT_CODE_PROMPT
	code_field.max_length = NetCodec.CODE_LEN + 2
	code_field.text_submitted.connect(func(_t: String) -> void: _join_code())
	panel.add_child(code_field)
	for i in BROWSER_ROWS:
		var k := i
		var b := _button("", ScreenButton.Kind.NORMAL, func() -> void: _join_row(k))
		row_buttons.append(b)
	row_ids.resize(BROWSER_ROWS)
	row_ids.fill(-1)
	for i in NetCodec.MAX_ROOM_PLAYERS:
		var k := i
		var b := _button("", ScreenButton.Kind.OPTION, func() -> void: _tap_member(k))
		b.name = "Member%d" % i
		member_buttons.append(b)
	member_ids.resize(NetCodec.MAX_ROOM_PLAYERS)
	join_party_button = _button(TEXT_JOIN_PARTY, ScreenButton.Kind.NORMAL, open_party_code)
	invite_button = _button(TEXT_INVITE_FRIENDS, ScreenButton.Kind.NORMAL, friends_requested.emit)
	share_button = _button(TEXT_SHARE_LINK, ScreenButton.Kind.NORMAL, share_link)
	leave_party_button = _button(TEXT_LEAVE_PARTY, ScreenButton.Kind.DANGER, leave_party)
	action_button = _button(TEXT_JOIN, ScreenButton.Kind.PRIMARY, func() -> void: _action())
	back_button = _button(TEXT_BACK, ScreenButton.Kind.NORMAL, _back)


func _text(t: String, face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var s := ScreenText.make(t, face, px, ink)
	panel.add_child(s)
	return s


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 22)
	b.name = label.capitalize().replace(" ", "") if not label.is_empty() else "Row"
	if kind == ScreenButton.Kind.OPTION:
		b.align = HORIZONTAL_ALIGNMENT_CENTER
	b.pressed.connect(action)
	panel.add_child(b)
	return b


func setup(s: HudStyle, t: HudTuning, net_tuning: NetTuning) -> void:
	style = s
	tuning = t
	net = net_tuning
	panel.fill_alpha = 1.0 / maxf(s.panel_fill.a, 0.01)   # opaque: nothing reads through it
	panel.setup(s)
	backdrop.color = Color(s.ink, Units.pct_to_frac(t.screen_dim_pct))
	for c in panel.get_children():
		if c is ScreenButton:
			(c as ScreenButton).setup(s)
		elif c is ScreenText:
			(c as ScreenText).setup(s)
	for b in member_buttons:
		b.align = HORIZONTAL_ALIGNMENT_LEFT
	SocialUi.style_edit(code_field, s, t)
	code_field.net_tuning = net
	code_field.hub = hub
	_layout()


## Canvas rect the panel centres in.
func place(area: Rect2) -> void:
	_area = area
	position = Vector2.ZERO
	size = area.end + area.position
	backdrop.position = Vector2.ZERO
	backdrop.size = size
	_layout()


# ---------------------------------------------------------------- Flows

func quick_join() -> void:
	_start(TEXT_QUICK, TEXT_FINDING, func() -> void: rooms.quick_join())


func open_create() -> void:
	_open(View.CREATE, TEXT_PRIVATE)


func open_code() -> void:
	code_for_party = false
	code_field.text = ""
	code_field.placeholder_text = TEXT_CODE_PH
	code_field.prompt_message = TEXT_CODE_PROMPT
	_open(View.CODE, TEXT_CODE)


func open_browser() -> void:
	_open(View.BROWSER, TEXT_BROWSER)
	_browse()


## N9.3: a friend's JOIN (the friends list): straight to the joining status.
func join_room(room_id: int, heading: String) -> void:
	_start(heading, TEXT_JOINING_ROOM % room_id, func() -> void: rooms.join_id(room_id))


## N9.3: an invite link's code: the room with that code, else the party with it.
func follow_link(code: String) -> void:
	link_code = code
	_start(TEXT_LINK, TEXT_JOINING % code, func() -> void: rooms.join_code(code))


# ---------------------------------------------------------------- Party (N9.3)

## The PARTY view: the members and what you can do (CREATE / JOIN without a party).
func open_party() -> void:
	_kick_armed = ""
	_open(View.PARTY, TEXT_PARTY)


func open_party_code() -> void:
	code_for_party = true
	code_field.text = ""
	code_field.placeholder_text = TEXT_PARTY_CODE_PH
	code_field.prompt_message = TEXT_PARTY_CODE_PROMPT
	_open(View.CODE, TEXT_JOIN_PARTY)


## The INVITE view for the newest invite (or `code`'s).
func open_invite(code: String = "") -> void:
	var inv := _invite(code)
	if inv == null:
		return
	invite_code = inv.code
	_open(View.INVITE, TEXT_INVITE)


## Protocol 2: the ROOM_INVITE view for the newest room invite (or `code`'s).
func open_room_invite(code: String = "") -> void:
	var inv := _room_invite(code)
	if inv == null:
		return
	inv.hub_card = true
	room_invite_code = inv.code
	_open(View.ROOM_INVITE, TEXT_ROOM_INVITE)


## JOIN on a room invite: the join by its code (refusals such as a full room show on the
## joining status, as for any join by code).
func accept_room_invite() -> void:
	join_room_invite(room_invite_code)


## Joins the room an invite is for (also the title toast's JOIN, through the hub).
func join_room_invite(code: String) -> void:
	if code.is_empty() or rooms == null:
		return
	room_invite_code = ""
	rooms.session.decline_room_invite(code)
	_start(TEXT_ROOM_INVITE, TEXT_JOINING % code, func() -> void: rooms.join_code(code))


## DECLINE: forgotten here (declining needs no message).
func decline_room_invite() -> void:
	if not room_invite_code.is_empty() and rooms != null:
		rooms.session.decline_room_invite(room_invite_code)
	room_invite_code = ""
	close()


func _room_invite(code: String) -> NetRoomInvites.Invite:
	if rooms == null or rooms.session == null:
		return null
	var list := rooms.session.room_invites
	return list.newest() if code.is_empty() else list.find(code)


func create_party() -> void:
	status.text = TEXT_CREATING_PARTY
	status.set_ink(ScreenText.Ink.ACCENT)
	rooms.party_create()
	_refresh()


func leave_party() -> void:
	if rooms == null or not _party().in_party():
		return
	rooms.party_leave()


func accept_invite() -> void:
	var c := invite_code
	if c.is_empty():
		return
	invite_code = ""
	_open(View.PARTY, TEXT_PARTY)
	status.text = TEXT_JOINING_PARTY % c
	status.set_ink(ScreenText.Ink.ACCENT)
	rooms.party_join(c)
	_refresh()


func decline_invite() -> void:
	if not invite_code.is_empty() and rooms != null:
		rooms.session.decline_invite(invite_code)
	invite_code = ""
	close()


## SHARE LINK: the system share sheet where the browser has one, else the clipboard.
func share_link() -> void:
	var p := _party()
	if not p.in_party():
		return
	var url := rooms.invite_url(p.code) if rooms != null else ""
	if url.is_empty():
		url = p.code
	if SocialUi.share(bridge, TEXT_SHARE_TITLE, TEXT_SHARE_BODY % url):
		return
	var ok := SocialUi.copy_text(bridge, url)
	status.text = TEXT_COPIED if ok else TEXT_COPY_FAILED % p.code
	status.set_ink(ScreenText.Ink.ACCENT if ok else ScreenText.Ink.HOT)
	_refresh()


func _tap_member(k: int) -> void:
	var id := member_ids[k] if k < member_ids.size() else ""
	var p := _party()
	if id.is_empty() or not p.is_leader() or id == p.me:
		return
	var now := Time.get_ticks_usec()
	if _kick_armed == id and now < _kick_until_us:
		_kick_armed = ""
		rooms.party_kick(id)
	else:
		_kick_armed = id
		_kick_until_us = now + roundi(net.confirm_tap_s * USEC_PER_S)
	_refresh()


func _party() -> NetParty:
	if rooms != null and rooms.session != null:
		return rooms.session.party
	return NetParty.new()


func _invite(code: String) -> NetParty.Invite:
	var p := _party()
	if code.is_empty():
		return p.newest_invite()
	for inv in p.invites:
		if inv.code == code:
			return inv
	return null


func create() -> void:
	var tm := "cycle"
	var fixed := 0
	match time_choice:
		TIME_MORNING:
			tm = "fixed"
			fixed = roundi(net.room_fixed_morning_min * MS_PER_MIN)
		TIME_GOLDEN:
			tm = "fixed"
			fixed = roundi(net.room_fixed_golden_min * MS_PER_MIN)
		TIME_NIGHT:
			tm = "night"
	var d := String(NetCodec.DENSITY[clampi(density, 0, NetCodec.DENSITY.size() - 1)])
	_start(TEXT_PRIVATE, TEXT_CREATING, func() -> void: rooms.create_room(d, tm, fixed))


func close() -> void:
	if not visible:
		return
	_bind(false)
	if rooms != null and rooms.session != null:
		var st := rooms.session.state
		if st == NetRoomSession.State.JOINING or (st == NetRoomSession.State.CONNECTING
				and view == View.STATUS):
			rooms.session.leave()
	link_code = ""
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


## BACK: from JOIN PARTY back to the party view; otherwise closes.
func _back() -> void:
	if view == View.CODE and code_for_party:
		open_party()
		return
	if view == View.INVITE:
		decline_invite()
		return
	if view == View.ROOM_INVITE:
		decline_room_invite()
		return
	close()


func _open(v: View, heading: String) -> void:
	view = v
	title.text = heading
	status.text = ""
	visible = true
	_bind(true)
	_refresh()


func _start(heading: String, working: String, request: Callable) -> void:
	_open(View.STATUS, heading)
	request_title = heading
	_retry = request
	_working(working)
	request.call()


func _working(text: String) -> void:
	status.text = text if rooms.session.client.is_ready() else TEXT_CONNECTING
	status.set_ink(ScreenText.Ink.ACCENT)
	_refresh()


func _action() -> void:
	match view:
		View.CREATE:
			create()
		View.CODE:
			_join_code()
		View.BROWSER:
			_browse()
		View.STATUS:
			if _retry.is_valid():
				_start(request_title, status_for(request_title), _retry)
		View.PARTY:
			if not _party().in_party():
				create_party()
		View.INVITE:
			accept_invite()
		View.ROOM_INVITE:
			accept_room_invite()


static func status_for(heading: String) -> String:
	return TEXT_CREATING if heading == TEXT_PRIVATE else TEXT_FINDING


func _join_code() -> void:
	var code := NetRoomSession.normalize_code(code_field.text)
	if not NetRoomSession.is_valid_code(code):
		status.text = TEXT_CODE_BAD
		status.set_ink(ScreenText.Ink.HOT)
		_layout()
		return
	if code_for_party:
		_open(View.PARTY, TEXT_PARTY)
		status.text = TEXT_JOINING_PARTY % code
		status.set_ink(ScreenText.Ink.ACCENT)
		rooms.party_join(code)
		_refresh()
		return
	_start(TEXT_CODE, TEXT_JOINING % code, func() -> void: rooms.join_code(code))


func _join_row(k: int) -> void:
	var id := row_ids[k]
	if id > 0:
		_start(TEXT_BROWSER, TEXT_JOINING_ROOM % id, func() -> void: rooms.join_id(id))


func _browse() -> void:
	_browse_left_s = net.room_browse_refresh_s
	if rooms.session.rooms_listed.is_empty():
		status.text = TEXT_LOADING
		status.set_ink(ScreenText.Ink.MUTED)
	rooms.browse()
	_refresh()


func _pick_density(k: int) -> void:
	density = k
	_refresh()


func _pick_time(k: int) -> void:
	time_choice = k
	_refresh()


func _process(delta: float) -> void:
	if not visible or rooms == null:
		return
	if view == View.PARTY and not _kick_armed.is_empty() and Time.get_ticks_usec() >= _kick_until_us:
		_kick_armed = ""
		_refresh()
	if view != View.BROWSER:
		return
	_browse_left_s -= delta
	if _browse_left_s <= 0.0:
		_browse()


# ---------------------------------------------------------------- Session

func _bind(on: bool) -> void:
	var s := rooms.session if rooms != null else null
	if _session != null and _session != s or not on:
		_connect(_session, false)
		_session = null
	if on and s != null and _session == null:
		_session = s
		_connect(s, true)


func _connect(s: NetRoomSession, on: bool) -> void:
	if s == null:
		return
	var pairs: Array = [[s.joined, _on_joined], [s.join_failed, _on_failed], [s.room_list, _on_list],
		[s.state_changed, _on_state], [s.party_changed, _on_party], [s.lobby_error, _on_lobby_error],
		[s.party_left, _on_party_left], [s.room_invites_changed, _on_room_invites]]
	for p: Array in pairs:
		var sig: Signal = p[0]
		var c: Callable = p[1]
		if on and not sig.is_connected(c):
			sig.connect(c)
		elif not on and sig.is_connected(c):
			sig.disconnect(c)


func _on_joined(_r: NetRoomState) -> void:
	var s := _session
	link_code = ""
	_bind(false)
	visible = false
	joined.emit(s)


## Shows a failure on the STATUS view (a refused join; previews).
func show_error(message: String) -> void:
	_on_failed("", message)


func _on_failed(code: String, message: String) -> void:
	if not link_code.is_empty() and code == "room_not_found":
		# An invite link's code that is no room's: a party's then (N9.3).
		var c := link_code
		_open(View.PARTY, TEXT_PARTY)
		link_code = c
		status.text = TEXT_JOINING_PARTY % c
		status.set_ink(ScreenText.Ink.ACCENT)
		rooms.party_join(c)
		_refresh()
		return
	if view != View.STATUS:
		view = View.STATUS
	status.text = message
	status.set_ink(ScreenText.Ink.HOT)
	_refresh()


func _on_list(_list: Array[Dictionary]) -> void:
	if view == View.BROWSER:
		status.text = ""
		_refresh()


func _on_state(st: NetRoomSession.State) -> void:
	if view == View.STATUS and st == NetRoomSession.State.JOINING and status.text == TEXT_CONNECTING:
		status.text = status_for(request_title) if request_title != TEXT_CODE else status.text
		_layout()


func _on_party() -> void:
	var p := _party()
	if view == View.PARTY and p.in_party():
		if status.ink != ScreenText.Ink.HOT:
			status.text = ""
		link_code = ""
	elif view == View.INVITE and _invite(invite_code) == null:
		invite_code = ""
		open_party()
		return
	if view == View.PARTY:
		_refresh()


## A room invite on show expired: the panel closes.
func _on_room_invites() -> void:
	if view == View.ROOM_INVITE and _room_invite(room_invite_code) == null:
		room_invite_code = ""
		close()


func _on_party_left(_reason: String, message: String) -> void:
	if view == View.PARTY:
		status.text = message
		status.set_ink(ScreenText.Ink.HOT)
		_refresh()


func _on_lobby_error(code: String, message: String) -> void:
	if not visible:
		return
	if not link_code.is_empty() and code == "party_not_found":
		link_code = ""
		message = TEXT_LINK_NONE
	if view == View.PARTY or view == View.STATUS or view == View.CODE:
		status.text = message
		status.set_ink(ScreenText.Ink.HOT)
		_refresh()


# ---------------------------------------------------------------- Look

func _refresh() -> void:
	for i in density_buttons.size():
		density_buttons[i].selected = i == density
		density_buttons[i].visible = view == View.CREATE
	for i in time_buttons.size():
		time_buttons[i].selected = i == time_choice
		time_buttons[i].visible = view == View.CREATE
	density_label.visible = view == View.CREATE
	time_label.visible = view == View.CREATE
	code_field.visible = view == View.CODE
	note.visible = true
	var p := _party()
	var in_party := p.in_party()
	join_party_button.visible = view == View.PARTY and not in_party
	for b: ScreenButton in [invite_button, share_button, leave_party_button]:
		b.visible = view == View.PARTY and in_party
	match view:
		View.CREATE:
			note.text = TEXT_CREATE_NOTE
			action_button.text = TEXT_CREATE
		View.CODE:
			note.text = TEXT_PARTY_CODE_NOTE if code_for_party else TEXT_CODE_NOTE
			action_button.text = TEXT_JOIN
		View.BROWSER:
			action_button.text = TEXT_REFRESH
			note.text = ""
		View.STATUS:
			note.text = ""
			action_button.text = TEXT_RETRY
		View.PARTY:
			title.text = TEXT_PARTY_CODE % p.code if in_party else TEXT_PARTY
			action_button.text = TEXT_CREATE_PARTY
			if not in_party:
				note.text = TEXT_PARTY_NONE
			elif not p.is_group():
				note.text = TEXT_PARTY_ALONE
			elif p.is_leader():
				note.text = TEXT_PARTY_LEAD
			else:
				note.text = TEXT_PARTY_MEMBER % p.leader_name()
			var url := rooms.invite_url(p.code) if rooms != null and in_party else ""
			share_button.text = TEXT_SHARE_LINK if SocialUi.can_share(bridge) or url.is_empty() else TEXT_COPY_LINK
		View.INVITE:
			var inv := _invite(invite_code)
			status.text = TEXT_INVITE_FROM % (inv.from_name if inv != null else "")
			status.set_ink(ScreenText.Ink.GOLD)
			note.text = TEXT_INVITE_NOTE
			action_button.text = TEXT_ACCEPT
		View.ROOM_INVITE:
			var rinv := _room_invite(room_invite_code)
			if rinv != null:
				status.text = TEXT_ROOM_INVITE_FROM % rinv.from_name
				note.text = TEXT_ROOM_INVITE_NOTE % [TEXT_ROOM_PUBLIC if rinv.is_public() else TEXT_ROOM_PRIVATE,
					rinv.code, rinv.players, rinv.max_players]
			status.set_ink(ScreenText.Ink.GOLD)
			action_button.text = TEXT_JOIN
	var failed := view == View.STATUS and status.ink == ScreenText.Ink.HOT
	action_button.visible = (view != View.STATUS or failed) and not (view == View.PARTY and in_party)
	back_button.text = TEXT_CANCEL if view == View.STATUS and not failed else (
			TEXT_DECLINE if view == View.INVITE or view == View.ROOM_INVITE else TEXT_BACK)
	_fill_rows()
	_fill_members()
	_layout()


func _fill_rows() -> void:
	row_ids.fill(-1)
	var list: Array[Dictionary] = rooms.session.rooms_listed if rooms != null and rooms.session != null else []
	var ping := roundi(rooms.session.ping_ms()) if rooms != null and rooms.session != null else 0
	for i in row_buttons.size():
		var b := row_buttons[i]
		b.visible = view == View.BROWSER and i < list.size()
		if i >= list.size():
			continue
		var r := list[i]
		row_ids[i] = int(r.get("room_id", 0))
		var full := int(r.get("players", 0)) >= int(r.get("max_players", 1))
		b.text = TEXT_ROW % [int(r.get("players", 0)), int(r.get("max_players", 0)),
			String(r.get("density", "")).to_upper(), TEXT_NIGHT if bool(r.get("night", false)) else TEXT_DAY, ping]
		b.disabled = full
	if view == View.BROWSER and list.is_empty() and status.text.is_empty():
		note.text = TEXT_EMPTY


## The party's members on the PARTY view: `name#1234`, LEADER / YOU; the leader's first tap
## on a member arms the removal (TAP AGAIN TO REMOVE), the second removes.
func _fill_members() -> void:
	var p := _party()
	_party_version = p.version
	for i in member_buttons.size():
		var b := member_buttons[i]
		var shown := view == View.PARTY and i < p.members.size()
		b.visible = shown
		member_ids[i] = ""
		if not shown:
			continue
		var m := p.members[i]
		member_ids[i] = m.account_id
		b.text = m.full_name()
		var notes: Array[String] = []
		if m.account_id == p.leader:
			notes.append(TEXT_LEADER)
		if m.account_id == p.me:
			notes.append(TEXT_YOU)
		var armed := m.account_id == _kick_armed
		if armed:
			notes = [TEXT_KICK]
		b.note = "  ·  ".join(notes)
		b.selected = armed
		b.disabled = not p.is_leader() or m.account_id == p.me


func _layout() -> void:
	if style == null:
		return
	var ts := style.ts
	var g := tuning.spacing_grid_px
	var pad := tuning.panel_padding_px * ts
	var th := tuning.touch_target_px
	var w := minf(net.room_panel_width_px * ts * WIDTH_SCALE, _area.size.x)
	var inner := w - pad * 2.0
	var y := _put(title, pad, pad, g)
	status.visible = not status.text.is_empty()
	if status.visible:
		y = _put(status, pad, y, g)
	if view == View.CREATE:
		y = _put(density_label, pad, y, g)
		y = _row(density_buttons, pad, y, inner, th, g)
		y = _put(time_label, pad, y, g)
		y = _row(time_buttons, pad, y, inner, th, g)
	elif view == View.CODE:
		code_field.position = Vector2(pad, y)
		code_field.size = Vector2(inner, th)
		y += th + g
	elif view == View.BROWSER:
		for b in row_buttons:
			if b.visible:
				b.position = Vector2(pad, y)
				b.size = Vector2(inner, th)
				y += th + g
	elif view == View.PARTY:
		var cw := (inner - g * float(PARTY_COLS - 1)) / float(PARTY_COLS)
		var k := 0
		for b in member_buttons:
			if not b.visible:
				continue
			@warning_ignore("integer_division")
			var row := k / PARTY_COLS
			b.position = Vector2(pad + float(k % PARTY_COLS) * (cw + g), y + float(row) * (th + g))
			b.size = Vector2(cw, th)
			var p := _party()
			if k < p.members.size():
				SocialUi.fit_button(b, p.members[k].full_name(), tuning)
			k += 1
		if k > 0:
			@warning_ignore("integer_division")
			y += float((k + PARTY_COLS - 1) / PARTY_COLS) * (th + g)
	if not note.text.is_empty():
		y = _put(note, pad, y, g)
	if view == View.PARTY and _party().in_party():
		var tw := (inner - g * 2.0) / 3.0
		invite_button.position = Vector2(pad, y)
		invite_button.size = Vector2(tw, th)
		share_button.position = Vector2(pad + tw + g, y)
		share_button.size = Vector2(tw, th)
		leave_party_button.position = Vector2(pad + (tw + g) * 2.0, y)
		leave_party_button.size = Vector2(tw, th)
		y += th + g
	var bw := (inner - g) * 0.5
	back_button.size = Vector2(bw, th)
	back_button.position = Vector2(pad, y)
	action_button.size = Vector2(bw, th)
	action_button.position = Vector2(pad + bw + g, y)
	if join_party_button.visible:
		# Without a party: BACK, JOIN PARTY, CREATE PARTY in one row.
		var tw := (inner - g * 2.0) / 3.0
		back_button.size = Vector2(tw, th)
		join_party_button.position = Vector2(pad + tw + g, y)
		join_party_button.size = Vector2(tw, th)
		action_button.position = Vector2(pad + (tw + g) * 2.0, y)
		action_button.size = Vector2(tw, th)
	y += th + pad
	panel.size = Vector2(w, y)
	panel.position = _area.position + (_area.size - panel.size) * 0.5


## Places a text at (x, y) at its size; returns the y under it.
static func _put(t: ScreenText, x: float, y: float, g: float) -> float:
	t.size = t.get_combined_minimum_size()
	t.position = Vector2(x, y)
	return y + t.size.y + g


static func _row(buttons: Array[ScreenButton], x: float, y: float, inner: float, th: float, g: float) -> float:
	var n := buttons.size()
	var bw := (inner - g * float(n - 1)) / float(n)
	for i in n:
		buttons[i].position = Vector2(x + float(i) * (bw + g), y)
		buttons[i].size = Vector2(bw, th)
	return y + th + g


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_back()


## The panel's width against the room menu's (room_panel_width_px).
const WIDTH_SCALE := 1.15   # lint: allow-number layout proportion
