class_name FriendsPanel
extends Control
## The friends screen (pause → SETTINGS → ACCOUNT → FRIENDS). Spec: multiplayer handoff →
## Rooms, parties and matchmaking → Friends and presence (friend codes name#1234, requests
## accepted by the other side, online status, a Join button when a friend is in a room
## with space, blocking), Moderation → Report, Client changes (party panel and friends
## list); docs/SERVER.md → Social API. WP N9.2; docs/SCREENS.md → Social.
##
## Left: the list, paged (PREV / NEXT in the header row): requests waiting for you
## (ACCEPT, MORE), your friends by presence (a dot and ONLINE / IN A ROOM / OFFLINE; JOIN
## for a room with space, disabled as SOON until N5 sets NetSocialClient.join_handler;
## N9.3: INVITE (to your party) for other online friends while the online hub sets
## NetSocialClient.invite_handler; MORE), then your requests (CANCEL). BLOCKED switches the list to blocked players
## (UNBLOCK). Right: ADD FRIEND (the code field and SEND, the server's answer inline),
## your own code with COPY, and the list switch; or, after MORE, the player's sheet:
## REMOVE FRIEND / DECLINE and BLOCK (each with a confirm step), REPORT (the report
## dialog, via report_requested) and BACK.
##
## Presence: the NetSocialClient polls GET /presence while this panel is visible, unless a
## lobby WebSocket feeds it (NetSocialClient → Presence). Nothing here blocks the game;
## every answer lands in the note line.

signal report_requested(player: NetSocialPlayer, context: Dictionary)

enum Mode { FRIENDS, BLOCKED }

const TEXT_ADD := "ADD FRIEND"
const TEXT_PLACEHOLDER := "NAME#1234"
const TEXT_PROMPT := "Friend code (Name#1234)"
const TEXT_SEND := "SEND"
const TEXT_YOUR_CODE := "YOUR FRIEND CODE"
const TEXT_COPY := "COPY CODE"
const TEXT_COPIED := "Your code is copied."
const TEXT_COPY_FAILED := "Couldn't copy. Tell them your code."
const TEXT_BLOCKED := "BLOCKED %d"
const TEXT_FRIENDS := "FRIENDS"
const TEXT_LIST := "FRIENDS %d/%d · %d ONLINE"
const TEXT_LIST_BLOCKED := "BLOCKED PLAYERS %d"
const TEXT_EMPTY := "No friends yet. Add a code or share yours."
const TEXT_EMPTY_BLOCKED := "You haven't blocked anyone."
const TEXT_LOADING := "Loading..."
const TEXT_SENDING := "Sending..."
const TEXT_SENT := "Request sent."
const TEXT_NOW_FRIENDS := "You're friends now."
const TEXT_REMOVED := "Removed."
const TEXT_BLOCKED_DONE := "Blocked."
const TEXT_UNBLOCKED := "Unblocked."
const TEXT_DECLINED := "Request declined."
const TEXT_CANCELLED := "Request cancelled."
## N9.3: a party invite went out.
const TEXT_INVITED := "Invite sent to %s."
const LABEL_INVITE := "INVITE"
const A_INVITE := &"invite"
const TEXT_PAGE := "%d/%d"
const TEXT_PREV := "PREV"
const TEXT_NEXT := "NEXT"
const SUB_ONLINE := "ONLINE"
const SUB_IN_ROOM := "IN A ROOM"
const SUB_OFFLINE := "OFFLINE"
const SUB_INCOMING := "WANTS TO BE FRIENDS"
const SUB_OUTGOING := "REQUEST SENT"
const SUB_BLOCKED := "BLOCKED"
const LABEL_ACCEPT := "ACCEPT"
const LABEL_MORE := "MORE"
const LABEL_JOIN := "JOIN"
const LABEL_SOON := "SOON"
const LABEL_CANCEL := "CANCEL"
const LABEL_UNBLOCK := "UNBLOCK"
const SHEET_FRIEND := "FRIEND"
const SHEET_REQUEST := "FRIEND REQUEST"
const LABEL_REMOVE := "REMOVE FRIEND"
const LABEL_DECLINE := "DECLINE"
const LABEL_BLOCK := "BLOCK"
const LABEL_REPORT := "REPORT"
const LABEL_BACK := "BACK"
const ASK_REMOVE := "Remove %s from your friends?"
const ASK_BLOCK := "Block %s? They can't add or invite you."
const CONFIRM_REMOVE := "REMOVE"
const CONFIRM_BLOCK := "BLOCK"

const A_ACCEPT := &"accept"
const A_MORE := &"more"
const A_JOIN := &"join"
const A_CANCEL := &"cancel"
const A_UNBLOCK := &"unblock"
const A_REMOVE := &"remove"
const A_DECLINE := &"decline"
const A_BLOCK := &"block"
const A_REPORT := &"report"
const A_BACK := &"back"
const K_FRIEND := &"friend"
const K_INCOMING := &"incoming"
const K_OUTGOING := &"outgoing"
const K_BLOCKED := &"blocked"
const REPORT_SOURCE := {"source": "friends"}

## The list's share of the width (the rest is the add / sheet column).
const LIST_SHARE := 0.58   # lint: allow-number layout proportion
const LABEL_PX := 16
const BODY_PX := 16
const CODE_PX := 20

var style: HudStyle
var tuning: HudTuning
var client: NetSocialClient
## The run's input hub (the field mutes its keys).
var hub: PlayerInput:
	set(value):
		hub = value
		if field != null:
			field.hub = value
var mode: Mode = Mode.FRIENDS
var page: int = 0
## Rows that fit a page (from the last layout).
var page_size: int = 1
var busy: bool = false
## The player the sheet is about (null: the add column shows).
var selected: NetSocialPlayer
var selected_kind: StringName = &""

var list_caption: ScreenText
var empty_text: ScreenText
var rows: Array[SocialRow] = []
var page_text: ScreenText
var prev_button: ScreenButton
var next_button: ScreenButton
var add_caption: ScreenText
var field: SocialField
var send_button: ScreenButton
var note: ScreenText
var code_caption: ScreenText
var code_text: ScreenText
var copy_button: ScreenButton
var mode_button: ScreenButton
var sheet: SocialActions

var _body: Rect2 = Rect2()
var _header: Rect2 = Rect2()
var _entries: Array[NetSocialPlayer] = []
var _kinds: Array[StringName] = []
var _note_left: float = 0.0


func _init() -> void:
	name = "Friends"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	process_mode = Node.PROCESS_MODE_ALWAYS
	list_caption = _text(ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	empty_text = _text(ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	page_text = _text(ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	page_text.tabular = true
	prev_button = _button(TEXT_PREV, ScreenButton.Kind.NORMAL, func() -> void: turn(-1))
	next_button = _button(TEXT_NEXT, ScreenButton.Kind.NORMAL, func() -> void: turn(1))
	add_caption = _text(ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	add_caption.text = TEXT_ADD
	field = SocialField.new()
	field.name = "CodeField"
	field.placeholder_text = TEXT_PLACEHOLDER
	field.prompt_message = TEXT_PROMPT
	field.text_submitted.connect(func(_t: String) -> void: send())
	add_child(field)
	send_button = _button(TEXT_SEND, ScreenButton.Kind.PRIMARY, send)
	note = _text(ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	code_caption = _text(ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	code_caption.text = TEXT_YOUR_CODE
	code_text = _text(ScreenText.Face.BODY, CODE_PX, ScreenText.Ink.TEXT)
	copy_button = _button(TEXT_COPY, ScreenButton.Kind.NORMAL, copy_code)
	mode_button = _button(TEXT_BLOCKED % 0, ScreenButton.Kind.NORMAL, toggle_mode)
	sheet = SocialActions.new()
	sheet.name = "Sheet"
	sheet.chosen.connect(_on_sheet)
	add_child(sheet)


func _text(face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var t := ScreenText.make("", face, px, ink)
	add_child(t)
	return t


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, BODY_PX)
	b.name = label.capitalize().replace(" ", "")
	b.pressed.connect(action)
	add_child(b)
	return b


func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	for c in get_children():
		if c is ScreenText:
			(c as ScreenText).setup(s)
		elif c is ScreenButton:
			(c as ScreenButton).setup(s)
			(c as ScreenButton).size_px = t.font_screen_body_px
	for r in rows:
		r.setup(s, t)
	sheet.setup(s, t)
	SocialUi.style_edit(field, s, t)
	refresh()


## Follows `c` (the session's NetSocialClient).
func bind(c: NetSocialClient) -> void:
	if client == c:
		return
	_connect(false)
	client = c
	_connect(true)
	if client != null:
		field.net_tuning = client.tuning
		field.max_length = client.tuning.friend_code_max_chars
	refresh()


func _connect(on: bool) -> void:
	if client == null:
		return
	var sigs: Array[Signal] = [client.friends_changed, client.blocks_changed]
	for sig in sigs:
		if on and not sig.is_connected(refresh):
			sig.connect(refresh)
		elif not on and sig.is_connected(refresh):
			sig.disconnect(refresh)
	if on and not client.presence_changed.is_connected(_on_presence):
		client.presence_changed.connect(_on_presence)
	elif not on and client.presence_changed.is_connected(_on_presence):
		client.presence_changed.disconnect(_on_presence)


func _on_presence(_id: String) -> void:
	refresh()


## Shows the screen fresh: the friends list from the server, no sheet, no old notes.
func open() -> void:
	mode = Mode.FRIENDS
	page = 0
	selected = null
	busy = false
	note.text = ""
	field.text = ""
	sheet.begin("", "", "")
	if client != null:
		client.watch(is_visible_in_tree())
		client.refresh_friends()
		client.refresh_blocks()
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and client != null:
		client.watch(is_visible_in_tree())
	elif what == NOTIFICATION_EXIT_TREE and client != null:
		client.watch(false)


func _process(delta: float) -> void:
	if client != null and is_visible_in_tree():
		client.poll()
	if _note_left > 0.0:
		_note_left -= delta
		if _note_left <= 0.0:
			note.text = ""


func _exit_tree() -> void:
	_connect(false)


# ---------------------------------------------------------------- Actions

func send() -> void:
	if client == null or busy:
		return
	field.release_focus()
	busy = true
	_note(TEXT_SENDING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await client.send_request(field.text)
	busy = false
	if r.ok:
		field.text = ""
		_note(TEXT_NOW_FRIENDS if r.str_field("status") == "accepted" else TEXT_SENT, ScreenText.Ink.ACCENT)
	else:
		_note(NetSocialClient.error_text(r), ScreenText.Ink.HOT)
	refresh()


func toggle_mode() -> void:
	mode = Mode.BLOCKED if mode == Mode.FRIENDS else Mode.FRIENDS
	page = 0
	selected = null
	if mode == Mode.BLOCKED and client != null and not client.blocks_loaded:
		client.refresh_blocks()
	refresh()


func turn(dir: int) -> void:
	page = clampi(page + dir, 0, maxi(_pages() - 1, 0))
	refresh()


func copy_code() -> void:
	var ok := SocialUi.copy_text(field.bridge, _my_code())
	_note(TEXT_COPIED if ok else TEXT_COPY_FAILED, ScreenText.Ink.ACCENT if ok else ScreenText.Ink.HOT)
	_note_left = client.tuning.social_note_s if client != null else 0.0


## A row button (tests call it with the row's action id).
func act(p: NetSocialPlayer, kind: StringName, action: StringName) -> void:
	if client == null or busy or p == null:
		return
	match action:
		A_MORE:
			_select(p, kind)
			return
		A_JOIN:
			if NetSocialClient.join_handler.is_valid():
				NetSocialClient.join_handler.call(p)
			return
		A_INVITE:
			# N9.3: a party invite (the online hub's seam).
			if NetSocialClient.invite_handler.is_valid():
				NetSocialClient.invite_handler.call(p)
				_note(TEXT_INVITED % p.display_name, ScreenText.Ink.ACCENT)
				_note_left = client.tuning.social_note_s
			return
	var r: NetApiResult
	var ok_text := ""
	busy = true
	match action:
		A_ACCEPT:
			r = await client.accept(p.request_id)
			ok_text = TEXT_NOW_FRIENDS
		A_CANCEL:
			r = await client.cancel_request(p.request_id)
			ok_text = TEXT_CANCELLED
		A_UNBLOCK:
			r = await client.unblock(p.account_id)
			ok_text = TEXT_UNBLOCKED
	busy = false
	if r != null:
		_result(r, ok_text)


func _on_row_button(row: SocialRow, index: int) -> void:
	if index < row.actions.size():
		act(row.player, row.kind, row.actions[index])


func _select(p: NetSocialPlayer, kind: StringName) -> void:
	selected = p
	selected_kind = kind
	var incoming := kind == K_INCOMING
	sheet.begin(SHEET_REQUEST if incoming else SHEET_FRIEND, p.full_name, _status_text(p, kind))
	if incoming:
		sheet.add(A_DECLINE, LABEL_DECLINE)
	else:
		sheet.add(A_REMOVE, LABEL_REMOVE, ScreenButton.Kind.DANGER, ASK_REMOVE, CONFIRM_REMOVE, p.display_name)
	sheet.add(A_BLOCK, LABEL_BLOCK, ScreenButton.Kind.DANGER, ASK_BLOCK, CONFIRM_BLOCK, p.display_name)
	sheet.add(A_REPORT, LABEL_REPORT)
	sheet.add(A_BACK, LABEL_BACK)
	note.text = ""
	refresh()


func _on_sheet(id: StringName) -> void:
	var p := selected
	if p == null or client == null:
		return
	match id:
		A_BACK:
			selected = null
			refresh()
			return
		A_REPORT:
			report_requested.emit(p, REPORT_SOURCE.duplicate())
			return
	if busy:
		return
	busy = true
	var r: NetApiResult
	var ok_text := ""
	match id:
		A_REMOVE:
			r = await client.remove_friend(p.account_id)
			ok_text = TEXT_REMOVED
		A_DECLINE:
			r = await client.decline(p.request_id)
			ok_text = TEXT_DECLINED
		A_BLOCK:
			r = await client.block(p.account_id)
			ok_text = TEXT_BLOCKED_DONE
	busy = false
	if r == null:
		return
	if r.ok:
		selected = null
	_result(r, ok_text)


func _result(r: NetApiResult, ok_text: String) -> void:
	if r.ok:
		_note(ok_text, ScreenText.Ink.ACCENT)
	else:
		_note(NetSocialClient.error_text(r), ScreenText.Ink.HOT)
	refresh()


func _note(value: String, ink: ScreenText.Ink) -> void:
	note.text = value
	note.set_ink(ink)
	_note_left = 0.0
	_layout()


# ---------------------------------------------------------------- View

## Re-reads the client into the widgets.
func refresh() -> void:
	_entries.clear()
	_kinds.clear()
	var loaded := false
	if client != null:
		if mode == Mode.FRIENDS:
			loaded = client.friends_loaded
			_add_entries(client.incoming, K_INCOMING)
			_add_entries(client.friends, K_FRIEND)
			_add_entries(client.outgoing, K_OUTGOING)
		else:
			loaded = client.blocks_loaded
			_add_entries(client.blocks, K_BLOCKED)
	if selected != null and _index_of(selected.account_id) < 0:
		selected = null
	var available := client != null and client.available()
	if mode == Mode.FRIENDS:
		var online := client.online_count() if client != null else 0
		var cap := client.max_friends if client != null and client.max_friends > 0 else 0
		list_caption.text = TEXT_LIST % [client.friends.size() if client != null else 0, cap, online]
	else:
		list_caption.text = TEXT_LIST_BLOCKED % _entries.size()
	if not available:
		empty_text.text = unavailable_text(client)
	elif not loaded:
		empty_text.text = TEXT_LOADING
	else:
		empty_text.text = TEXT_EMPTY if mode == Mode.FRIENDS else TEXT_EMPTY_BLOCKED
	empty_text.visible = _entries.is_empty()
	field.editable = available and not busy
	send_button.disabled = not available or busy
	var code := _my_code()
	code_text.text = code
	for c: CanvasItem in [code_caption, code_text, copy_button]:
		c.visible = not code.is_empty()
	var nb := client.blocks.size() if client != null else 0
	mode_button.text = TEXT_BLOCKED % nb if mode == Mode.FRIENDS else TEXT_FRIENDS
	var sheet_on := selected != null
	sheet.visible = sheet_on
	for c: CanvasItem in [add_caption, field, send_button]:
		c.visible = not sheet_on and mode == Mode.FRIENDS
	for c: CanvasItem in [code_caption, code_text, copy_button]:
		c.visible = c.visible and not sheet_on
	mode_button.visible = not sheet_on
	_layout()


## Why a social screen shows nothing: online features off, or not signed in.
static func unavailable_text(c: NetSocialClient) -> String:
	var off := c == null or c.api == null or c.api.base_url.is_empty()
	return NetSocialClient.error_text(NetApiResult.failure(0,
			NetApiResult.OFFLINE if off else NetSession.ERR_NOT_SIGNED_IN))


func _add_entries(list: Array[NetSocialPlayer], kind: StringName) -> void:
	for p in list:
		_entries.append(p)
		_kinds.append(kind)


func _index_of(account_id: String) -> int:
	for i in _entries.size():
		if _entries[i].account_id == account_id:
			return i
	return -1


func _my_code() -> String:
	if client == null or client.session == null or not is_instance_valid(client.session):
		return ""
	var p := client.session.profile
	return p.full_name if p != null else ""


func _pages() -> int:
	return maxi(1, ceili(float(_entries.size()) / float(maxi(page_size, 1))))


static func _status_text(p: NetSocialPlayer, kind: StringName) -> String:
	match kind:
		K_INCOMING:
			return SUB_INCOMING
		K_OUTGOING:
			return SUB_OUTGOING
		K_BLOCKED:
			return SUB_BLOCKED
	match p.status:
		NetSocialPlayer.ONLINE:
			return SUB_ONLINE
		NetSocialPlayer.IN_ROOM:
			return SUB_IN_ROOM
	return SUB_OFFLINE


## The row shown for `p`: texts, dot and buttons.
func _fill_row(row: SocialRow, p: NetSocialPlayer, kind: StringName) -> void:
	row.player = p
	row.kind = kind
	row.selected = selected != null and selected.account_id == p.account_id
	var ink := ScreenText.Ink.MUTED
	var dot := SocialRow.Dot.NONE
	if kind == K_FRIEND:
		dot = SocialRow.Dot.OFFLINE
		if p.status == NetSocialPlayer.ONLINE:
			ink = ScreenText.Ink.ACCENT
			dot = SocialRow.Dot.ONLINE
		elif p.status == NetSocialPlayer.IN_ROOM:
			ink = ScreenText.Ink.GOLD
			dot = SocialRow.Dot.IN_ROOM
	elif kind == K_INCOMING:
		ink = ScreenText.Ink.ACCENT
	row.dot = dot
	row.set_texts(p.display_name, p.tag_text(), p.crew_tag, _status_text(p, kind), ink)
	match kind:
		K_INCOMING:
			row.set_buttons([LABEL_MORE, LABEL_ACCEPT], [A_MORE, A_ACCEPT],
					[ScreenButton.Kind.NORMAL, ScreenButton.Kind.PRIMARY])
		K_OUTGOING:
			row.set_buttons([LABEL_CANCEL], [A_CANCEL])
		K_BLOCKED:
			row.set_buttons([LABEL_UNBLOCK], [A_UNBLOCK])
		_:
			if p.in_room() and p.joinable:
				row.set_buttons([LABEL_MORE, LABEL_JOIN], [A_MORE, A_JOIN],
						[ScreenButton.Kind.NORMAL, ScreenButton.Kind.PRIMARY])
				var join := row.buttons[1]
				if not NetSocialClient.join_handler.is_valid():
					join.disabled = true
					join.note = LABEL_SOON
			elif p.status != NetSocialPlayer.OFFLINE and NetSocialClient.invite_handler.is_valid():
				# N9.3: an online friend can be invited to your party.
				row.set_buttons([LABEL_MORE, LABEL_INVITE], [A_MORE, A_INVITE])
			else:
				row.set_buttons([LABEL_MORE], [A_MORE])
	for b in row.buttons:
		if b.visible and busy:
			b.disabled = true


func _row(i: int) -> SocialRow:
	while rows.size() <= i:
		var r := SocialRow.new()
		r.name = "Row%d" % rows.size()
		r.button_pressed.connect(_on_row_button)
		add_child(r)
		if style != null:
			r.setup(style, tuning)
		rows.append(r)
	return rows[i]


## Lays the panel out: `body` holds the list and the side column, `header` (the free
## right end of the tab row) the page controls. Parent-local px.
func layout(body: Rect2, header: Rect2) -> void:
	_body = body
	_header = header
	_layout()


func _layout() -> void:
	if style == null or _body.size.x <= 0.0:
		return
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var gap := g * 2.0
	var lw := floorf((_body.size.x - gap * 2.0) * LIST_SHARE)
	var lx := _body.position.x
	var rx := lx + lw + gap * 2.0
	var rw := _body.end.x - rx
	var y := _body.position.y
	# The list.
	var cs := list_caption.get_combined_minimum_size()
	SocialUi.fit_text(list_caption, list_caption.text, lw)
	SocialUi.place(list_caption, Vector2(lx, y), list_caption.get_combined_minimum_size())
	y += cs.y
	page_size = maxi(1, floori((_body.end.y - y + g) / (th + g)))
	page = clampi(page, 0, _pages() - 1)
	var first := page * page_size
	for i in maxi(rows.size(), page_size):
		var k := first + i
		if i >= page_size or k >= _entries.size():
			if i < rows.size():
				rows[i].visible = false
			continue
		var row := _row(i)
		row.visible = true
		_fill_row(row, _entries[k], _kinds[k])
		row.layout(Rect2(lx, y + float(i) * (th + g), lw, th))
	if empty_text.visible:
		SocialUi.fit_text(empty_text, empty_text.text, lw)
		SocialUi.place(empty_text, Vector2(lx, y), empty_text.get_combined_minimum_size())
	# Page controls in the header row.
	var paged := _pages() > 1
	for c: CanvasItem in [page_text, prev_button, next_button]:
		c.visible = paged
	if paged:
		page_text.text = TEXT_PAGE % [page + 1, _pages()]
		var nw := SocialUi.button_width(next_button, tuning)
		var pw := SocialUi.button_width(prev_button, tuning)
		var hx := _header.end.x - nw
		SocialUi.place(next_button, Vector2(hx, _header.position.y), Vector2(nw, th))
		hx -= pw + g
		SocialUi.place(prev_button, Vector2(hx, _header.position.y), Vector2(pw, th))
		var ps := page_text.get_combined_minimum_size()
		SocialUi.place(page_text, Vector2(hx - g - ps.x, _header.position.y + (th - ps.y) * 0.5), ps)
		prev_button.disabled = page <= 0
		next_button.disabled = page >= _pages() - 1
	# The side column: the add form, or the sheet.
	var ry := _body.position.y
	if sheet.visible:
		ry += sheet.layout(Rect2(rx, ry, rw, _body.end.y - ry)) + g
	if add_caption.visible:
		var ac := add_caption.get_combined_minimum_size()
		SocialUi.place(add_caption, Vector2(rx, ry), ac)
		ry += ac.y
		var sw := SocialUi.button_width(send_button, tuning)
		SocialUi.place(field, Vector2(rx, ry), Vector2(rw - sw - g, th))
		SocialUi.place(send_button, Vector2(rx + rw - sw, ry), Vector2(sw, th))
		ry += th
	SocialUi.fit_text(note, note.text, rw)
	var nh := maxf(note.get_combined_minimum_size().y, float(roundi(float(BODY_PX) * style.ts * ScreenText.LINE_EM)))
	SocialUi.place(note, Vector2(rx, ry), note.get_combined_minimum_size())
	ry += nh + g
	if code_caption.visible:
		var cc := code_caption.get_combined_minimum_size()
		SocialUi.place(code_caption, Vector2(rx, ry), cc)
		ry += cc.y
		SocialUi.fit_text(code_text, code_text.text, rw)
		SocialUi.place(code_text, Vector2(rx, ry), code_text.get_combined_minimum_size())
		ry += code_text.get_combined_minimum_size().y + g
	if mode_button.visible:
		var bw := (rw - g) * 0.5
		if copy_button.visible:
			SocialUi.place(copy_button, Vector2(rx, ry), Vector2(bw, th))
			SocialUi.place(mode_button, Vector2(rx + bw + g, ry), Vector2(bw, th))
		else:
			SocialUi.place(mode_button, Vector2(rx, ry), Vector2(rw, th))
