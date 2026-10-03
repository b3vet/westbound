class_name CrewPanel
extends Control
## The crew screen (pause → SETTINGS → ACCOUNT → CREW). Spec: multiplayer handoff → Crews
## (persistent) (a named crew with a 2–4 character tag, up to 16 members, joined by an
## invite code; an owner and officers can kick; the tag shows on nametags and boards),
## Leaderboards (Loop crew: the season standing), Moderation (profanity-filtered crew
## names; Report), Client changes (crew page: members, invite code, season standing);
## docs/SERVER.md → Social API → Crews (the role table). WP N9.2; docs/SCREENS.md → Social.
##
## Without a crew: CREATE A CREW (name, tag, CREATE; the filter's answers inline) and JOIN
## A CREW (invite code, JOIN). In a crew: the card (tag, name, members and your role, the
## Loop crew season standing), the invite code with COPY (the clipboard; SHARE opens the
## system share sheet where the browser has one) and NEW CODE (owner, officers), then
## LEAVE CREW and DISBAND (owner), each with a confirm step. Right: the members with their
## roles, paged; MORE on a member opens their sheet with only the actions your role allows
## (NetCrew.allowed_actions: MAKE OFFICER / MAKE MEMBER / MAKE OWNER / KICK, each
## confirmed) plus REPORT and BACK.
##
## Crew invites (the owner's request "there is no way to invite my friends to my crew";
## docs/NET_CLIENT.md → Crew invites): in a crew, INVITE FRIENDS (any member: every member
## shares the code already) turns the right column into your friends who are not in the
## crew, each with INVITE (INVITED once the crew's invite waits; MEMBERS goes back).
## Without a crew, the invites waiting for you list under JOIN A CREW: "<crew> [TAG]", who
## sent it, JOIN and DECLINE. In a crew they show as a gold line (leave your crew to take
## one).

signal report_requested(player: NetSocialPlayer, context: Dictionary)

const TEXT_CREATE := "CREATE A CREW"
const TEXT_NAME_PH := "CREW NAME"
const TEXT_TAG_PH := "TAG"
const TEXT_NAME_PROMPT := "Crew name (3–24 characters)"
const TEXT_TAG_PROMPT := "Crew tag (2–4 letters or digits)"
const TEXT_CODE_PROMPT := "Crew invite code"
const TEXT_CREATE_BUTTON := "CREATE"
const TEXT_CREATE_HINT := "Names 3–24 characters, tags 2–4."
const TEXT_JOIN := "JOIN A CREW"
const TEXT_CODE_PH := "INVITE CODE"
const TEXT_JOIN_BUTTON := "JOIN"
const TEXT_JOIN_HINT := "Ask a member for the invite code."
const TEXT_CREW := "YOUR CREW"
const TEXT_TAG := "[%s]"
const TEXT_MEMBERS := "%d/%d MEMBERS · YOU: %s"
const TEXT_SEASON := "SEASON %s: #%d · %s"
const TEXT_SEASON_NONE := "SEASON %s: NOT ON THE BOARD YET"
const TEXT_SEASON_LOADING := "SEASON: ..."
const TEXT_CODE := "INVITE CODE"
const TEXT_COPY := "COPY"
const TEXT_SHARE := "SHARE"
const TEXT_ROTATE := "NEW CODE"
const TEXT_COPIED := "Code copied."
const TEXT_COPY_FAILED := "Couldn't copy. Read the code out."
const TEXT_SHARE_TITLE := "Westbound crew"
const TEXT_SHARE_BODY := "Join my crew %s [%s] in Westbound. Invite code: %s"
const TEXT_ROTATED := "New code. The old one no longer works."
const TEXT_MEMBERS_CAPTION := "MEMBERS %d/%d"
const TEXT_LOADING := "Loading..."
const TEXT_WORKING := "One moment..."
const TEXT_CREATED := "Crew created."
const TEXT_JOINED := "Welcome to the crew."
const TEXT_LEFT := "You left the crew."
const TEXT_DISBANDED := "Crew disbanded."
const TEXT_DONE := "Done."
const TEXT_PAGE := "%d/%d"
const TEXT_PREV := "PREV"
const TEXT_NEXT := "NEXT"
const LABEL_LEAVE := "LEAVE CREW"
const LABEL_DISBAND := "DISBAND"
const ASK_LEAVE := "Leave %s?"
const ASK_DISBAND := "Disband %s for everyone?"
const CONFIRM_LEAVE := "LEAVE"
const CONFIRM_DISBAND := "DISBAND"
const LABEL_MORE := "MORE"
const SHEET_MEMBER := "CREW MEMBER"
const LABEL_PROMOTE := "MAKE OFFICER"
const LABEL_DEMOTE := "MAKE MEMBER"
const LABEL_TRANSFER := "MAKE OWNER"
const LABEL_KICK := "KICK"
const LABEL_REPORT := "REPORT"
const LABEL_BACK := "BACK"
const ASK_PROMOTE := "Make %s an officer?"
const ASK_DEMOTE := "Make %s a member?"
const ASK_TRANSFER := "Hand the crew to %s?"
const ASK_KICK := "Kick %s from the crew?"
const ROLE_TEXT := {"owner": "OWNER", "officer": "OFFICER", "member": "MEMBER"}
const TEXT_YOU := "%s · YOU"

const A_LEAVE := &"leave"
const A_DISBAND := &"disband"
const A_MORE := &"more"
const A_REPORT := &"report"
const A_BACK := &"back"
const A_INVITE := &"invite"
const A_ACCEPT_INVITE := &"accept_invite"
const A_DECLINE_INVITE := &"decline_invite"
# Crew invites.
const TEXT_INVITE_FRIENDS := "INVITE FRIENDS"
const TEXT_SHOW_MEMBERS := "MEMBERS"
const TEXT_INVITE_CAPTION := "INVITE FRIENDS"
const TEXT_INVITE_NONE := "NO FRIENDS TO INVITE YET"
const LABEL_INVITE := "INVITE"
const LABEL_INVITED := "INVITED"
const TEXT_INVITE_SENT := "Invite sent to %s."
const TEXT_INVITES_CAPTION := "CREW INVITES"
const TEXT_INVITE_FROM := "FROM %s"
const TEXT_INVITE_FROM_NONE := "AN INVITE FOR YOU"
const LABEL_JOIN_INVITE := "JOIN"
const LABEL_DECLINE := "DECLINE"
const TEXT_INVITE_DECLINED := "Invite declined."
const TEXT_LEAVE_FIRST := "Leave your crew first to join another."
const TEXT_PENDING_ONE := "%s INVITES YOU  ·  LEAVE YOUR CREW TO JOIN"
const TEXT_PENDING_MANY := "%d CREW INVITES  ·  LEAVE YOUR CREW TO JOIN"
## Incoming invite rows shown at most (no crew).
const INVITE_ROWS_MAX := 3

const LABEL_PX := 16
const BODY_PX := 16
const NAME_PX := 28
const CODE_PX := 28
## The tag field's share of the create row.
const TAG_SHARE := 0.34   # lint: allow-number layout proportion

var style: HudStyle
var tuning: HudTuning
var client: NetSocialClient
var hub: PlayerInput:
	set(value):
		hub = value
		for f: SocialField in [name_field, tag_field, code_field]:
			if f != null:
				f.hub = value
var busy: bool = false
var page: int = 0
var page_size: int = 1
## The member the sheet is about (null: the crew info shows).
var selected: NetSocialPlayer
var bridge: NetJsBridge = NetJsBridge.new()

# No crew.
var create_caption: ScreenText
var name_field: SocialField
var tag_field: SocialField
var create_button: ScreenButton
var create_note: ScreenText
var join_caption: ScreenText
var code_field: SocialField
var join_button: ScreenButton
var join_note: ScreenText
var status_text: ScreenText
# In a crew.
var card: ScreenPanel
var crew_caption: ScreenText
var tag_text: ScreenText
var name_text: ScreenText
var members_text: ScreenText
var season_text: ScreenText
var code_caption: ScreenText
var code_text: ScreenText
var copy_button: ScreenButton
var share_button: ScreenButton
var rotate_button: ScreenButton
var note: ScreenText
var crew_actions: SocialActions
var members_caption: ScreenText
var rows: Array[SocialRow] = []
var page_text: ScreenText
var prev_button: ScreenButton
var next_button: ScreenButton
var sheet: SocialActions
## Crew invites: the right column lists friends to invite (in a crew).
var inviting: bool = false
var invite_toggle: ScreenButton
var invites_caption: ScreenText
var pending_line: ScreenText
## The invites waiting for you (no crew): one row each.
var invite_rows: Array[SocialRow] = []
var invite_row_ids: Array[String] = []

var _body: Rect2 = Rect2()
var _header: Rect2 = Rect2()
var _note_left: float = 0.0
var _sheet_crew: String = ""
## Crew id + role the crew actions were built for (rebuilt only when that changes, so a
## refresh never drops a pending confirm).
var _actions_key: String = ""


func _init() -> void:
	name = "Crew"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	process_mode = Node.PROCESS_MODE_ALWAYS
	create_caption = _text(TEXT_CREATE, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	name_field = _field("NameField", TEXT_NAME_PH, TEXT_NAME_PROMPT)
	tag_field = _field("TagField", TEXT_TAG_PH, TEXT_TAG_PROMPT)
	create_button = _button(TEXT_CREATE_BUTTON, ScreenButton.Kind.PRIMARY, create)
	create_note = _text(TEXT_CREATE_HINT, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	join_caption = _text(TEXT_JOIN, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	code_field = _field("CodeField", TEXT_CODE_PH, TEXT_CODE_PROMPT)
	join_button = _button(TEXT_JOIN_BUTTON, ScreenButton.Kind.PRIMARY, join)
	join_note = _text(TEXT_JOIN_HINT, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	status_text = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	card = ScreenPanel.new()
	card.name = "Card"
	add_child(card)
	crew_caption = _text(TEXT_CREW, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	tag_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.ACCENT)
	name_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.TEXT)
	members_text = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	season_text = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.TEXT)
	season_text.tabular = true
	code_caption = _text(TEXT_CODE, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	code_text = _text("", ScreenText.Face.DISPLAY, CODE_PX, ScreenText.Ink.TEXT)
	code_text.tabular = true
	copy_button = _button(TEXT_COPY, ScreenButton.Kind.NORMAL, copy_code)
	share_button = _button(TEXT_SHARE, ScreenButton.Kind.NORMAL, share_code)
	rotate_button = _button(TEXT_ROTATE, ScreenButton.Kind.NORMAL, rotate_code)
	note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	crew_actions = SocialActions.new()
	crew_actions.name = "CrewActions"
	crew_actions.chosen.connect(_on_crew_action)
	add_child(crew_actions)
	members_caption = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	page_text = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	page_text.tabular = true
	prev_button = _button(TEXT_PREV, ScreenButton.Kind.NORMAL, func() -> void: turn(-1))
	next_button = _button(TEXT_NEXT, ScreenButton.Kind.NORMAL, func() -> void: turn(1))
	invite_toggle = _button(TEXT_INVITE_FRIENDS, ScreenButton.Kind.NORMAL, toggle_inviting)
	invite_toggle.name = "InviteFriends"
	invites_caption = _text(TEXT_INVITES_CAPTION, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.GOLD)
	pending_line = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.GOLD)
	pending_line.name = "PendingInvites"
	sheet = SocialActions.new()
	sheet.name = "MemberSheet"
	sheet.chosen.connect(_on_member_action)
	add_child(sheet)


func _text(value: String, face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var t := ScreenText.make(value, face, px, ink)
	add_child(t)
	return t


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, BODY_PX)
	b.name = label.capitalize().replace(" ", "")
	b.pressed.connect(action)
	add_child(b)
	return b


func _field(node_name: String, placeholder: String, question: String) -> SocialField:
	var f := SocialField.new()
	f.name = node_name
	f.placeholder_text = placeholder
	f.prompt_message = question
	f.text_submitted.connect(_on_submitted.bind(f))
	add_child(f)
	return f


func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	for c in get_children():
		if c is ScreenText:
			(c as ScreenText).setup(s)
		elif c is ScreenButton:
			(c as ScreenButton).setup(s)
			(c as ScreenButton).size_px = t.font_screen_body_px
		elif c is ScreenPanel:
			(c as ScreenPanel).setup(s)
		elif c is SocialField:
			SocialUi.style_edit(c as SocialField, s, t)
	for r in rows + invite_rows:
		r.setup(s, t)
	sheet.setup(s, t)
	crew_actions.setup(s, t)
	refresh()


func bind(c: NetSocialClient) -> void:
	if client == c:
		return
	_connect(false)
	client = c
	_connect(true)
	if client != null:
		var nt := client.tuning
		name_field.max_length = nt.crew_name_max_chars
		tag_field.max_length = nt.crew_tag_max_chars
		code_field.max_length = nt.crew_code_max_chars
		for f: SocialField in [name_field, tag_field, code_field]:
			f.net_tuning = nt
	refresh()


func _connect(on: bool) -> void:
	if client == null:
		return
	var sigs: Array[Signal] = [client.crew_changed, client.standing_changed, client.crew_invites_changed,
		client.friends_changed]
	for sig in sigs:
		if on and not sig.is_connected(refresh):
			sig.connect(refresh)
		elif not on and sig.is_connected(refresh):
			sig.disconnect(refresh)


## Shows the screen fresh and loads the crew and its standing.
func open() -> void:
	page = 0
	selected = null
	inviting = false
	_actions_key = ""
	busy = false
	_note_left = 0.0
	note.text = ""
	create_note.text = TEXT_CREATE_HINT
	create_note.set_ink(ScreenText.Ink.MUTED)
	join_note.text = TEXT_JOIN_HINT
	join_note.set_ink(ScreenText.Ink.MUTED)
	for f: SocialField in [name_field, tag_field, code_field]:
		f.text = ""
	refresh()
	load_crew()


## GET /crews/mine, then the season standing; the crew invites waiting for you.
func load_crew() -> void:
	if client == null or not client.available():
		return
	client.refresh_crew_invites()
	await client.refresh_crew()
	if client.crew != null:
		await client.refresh_standing()


# ---------------------------------------------------------------- Crew invites

## INVITE FRIENDS / MEMBERS: the right column's two lists (in a crew).
func toggle_inviting() -> void:
	inviting = not inviting
	page = 0
	selected = null
	if inviting and client != null and client.available():
		client.refresh_friends()
		client.refresh_crew_sent()
	refresh()


## INVITE on a friend: the crew's invite (any member).
func invite_friend(p: NetSocialPlayer) -> void:
	if client == null or busy or p == null:
		return
	busy = true
	var r: NetApiResult = await client.invite_to_crew(p.account_id)
	busy = false
	if r.ok:
		_set_note(note, TEXT_INVITE_SENT % p.full_name, ScreenText.Ink.ACCENT)
		_note_left = client.tuning.social_note_s
	else:
		_set_note(note, NetSocialClient.error_text(r), ScreenText.Ink.HOT)
		_note_left = 0.0
	refresh()


## JOIN on an invite waiting for you: joins that crew.
func accept_invite(invite_id: String) -> void:
	if client == null or busy:
		return
	busy = true
	_set_note(join_note, TEXT_WORKING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await client.accept_crew_invite(invite_id)
	busy = false
	if r.ok:
		join_note.text = TEXT_JOIN_HINT
		join_note.set_ink(ScreenText.Ink.MUTED)
		_set_note(note, TEXT_JOINED, ScreenText.Ink.ACCENT)
		await client.refresh_standing()
	else:
		var t := TEXT_LEAVE_FIRST if r.error == "already_in_crew" else NetSocialClient.error_text(r)
		_set_note(join_note, t, ScreenText.Ink.HOT)
	refresh()


## DECLINE on an invite waiting for you.
func decline_invite(invite_id: String) -> void:
	if client == null or busy:
		return
	busy = true
	var r: NetApiResult = await client.decline_crew_invite(invite_id)
	busy = false
	if r.ok:
		_set_note(join_note, TEXT_INVITE_DECLINED, ScreenText.Ink.MUTED)
	else:
		_set_note(join_note, NetSocialClient.error_text(r), ScreenText.Ink.HOT)
	refresh()


func _invite_row(i: int) -> SocialRow:
	while invite_rows.size() <= i:
		var r := SocialRow.new()
		r.name = "Invite%d" % invite_rows.size()
		r.button_pressed.connect(_on_invite_row_button)
		add_child(r)
		if style != null:
			r.setup(style, tuning)
		invite_rows.append(r)
		invite_row_ids.append("")
	return invite_rows[i]


func _on_invite_row_button(row: SocialRow, index: int) -> void:
	var i := invite_rows.find(row)
	if i < 0 or index >= row.actions.size():
		return
	match row.actions[index]:
		A_ACCEPT_INVITE:
			accept_invite(invite_row_ids[i])
		A_DECLINE_INVITE:
			decline_invite(invite_row_ids[i])


## The invite row for `crew_id` (tests).
func invite_row_of(crew_id: String) -> SocialRow:
	if client == null:
		return null
	for i in invite_rows.size():
		if not invite_rows[i].visible:
			continue
		for inv in client.crew_invites:
			if inv.invite_id == invite_row_ids[i] and inv.crew_id == crew_id:
				return invite_rows[i]
	return null


func _process(delta: float) -> void:
	if _note_left > 0.0:
		_note_left -= delta
		if _note_left <= 0.0:
			note.text = ""


func _exit_tree() -> void:
	_connect(false)


# ---------------------------------------------------------------- Actions

func create() -> void:
	if client == null or busy:
		return
	_release_fields()
	busy = true
	_set_note(create_note, TEXT_WORKING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await client.create_crew(name_field.text, tag_field.text)
	busy = false
	if r.ok:
		_set_note(note, TEXT_CREATED, ScreenText.Ink.ACCENT)
		await client.refresh_standing()
	else:
		_set_note(create_note, NetSocialClient.error_text(r), ScreenText.Ink.HOT)
	refresh()


func join() -> void:
	if client == null or busy:
		return
	_release_fields()
	busy = true
	_set_note(join_note, TEXT_WORKING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await client.join_crew(code_field.text)
	busy = false
	if r.ok:
		_set_note(note, TEXT_JOINED, ScreenText.Ink.ACCENT)
		await client.refresh_standing()
	else:
		_set_note(join_note, NetSocialClient.error_text(r), ScreenText.Ink.HOT)
	refresh()


func _on_submitted(_t: String, f: SocialField) -> void:
	if f == code_field:
		join()
	else:
		create()


func _release_fields() -> void:
	for f: SocialField in [name_field, tag_field, code_field]:
		f.release_focus()


func copy_code() -> void:
	if client == null or client.crew == null:
		return
	var ok := SocialUi.copy_text(bridge, client.crew.invite_code)
	_set_note(note, TEXT_COPIED if ok else TEXT_COPY_FAILED, ScreenText.Ink.ACCENT if ok else ScreenText.Ink.HOT)
	_note_left = client.tuning.social_note_s


func share_code() -> void:
	if client == null or client.crew == null:
		return
	var c := client.crew
	SocialUi.share(bridge, TEXT_SHARE_TITLE, TEXT_SHARE_BODY % [c.name, c.tag, c.invite_code])


func rotate_code() -> void:
	if client == null or busy:
		return
	busy = true
	var r: NetApiResult = await client.rotate_invite_code()
	busy = false
	_result(r, TEXT_ROTATED)


func turn(dir: int) -> void:
	page = clampi(page + dir, 0, maxi(_pages() - 1, 0))
	refresh()


func _on_crew_action(id: StringName) -> void:
	if client == null or busy:
		return
	busy = true
	var r: NetApiResult
	var ok_text := ""
	match id:
		A_LEAVE:
			r = await client.leave_crew()
			ok_text = TEXT_LEFT
		A_DISBAND:
			r = await client.disband()
			ok_text = TEXT_DISBANDED
	busy = false
	if r != null:
		_result(r, ok_text)


## A member row's button (MORE: the member's sheet); INVITE on a friend's row.
func _on_row_button(row: SocialRow, index: int) -> void:
	if index >= row.actions.size() or row.player == null:
		return
	match row.actions[index]:
		A_MORE:
			select(row.player)
		A_INVITE:
			invite_friend(row.player)


## Opens `m`'s sheet with the actions your role allows.
func select(m: NetSocialPlayer) -> void:
	if client == null or client.crew == null:
		return
	selected = m
	var c := client.crew
	var mine := m.account_id == client.my_account_id()
	sheet.begin(SHEET_MEMBER, m.full_name, _role_text(m, mine))
	for a in NetCrew.allowed_actions(c.your_role, m.role, mine):
		match a:
			NetCrew.PROMOTE:
				sheet.add(a, LABEL_PROMOTE, ScreenButton.Kind.NORMAL, ASK_PROMOTE, LABEL_PROMOTE, m.display_name)
			NetCrew.DEMOTE:
				sheet.add(a, LABEL_DEMOTE, ScreenButton.Kind.NORMAL, ASK_DEMOTE, LABEL_DEMOTE, m.display_name)
			NetCrew.TRANSFER:
				sheet.add(a, LABEL_TRANSFER, ScreenButton.Kind.DANGER, ASK_TRANSFER, LABEL_TRANSFER, m.display_name)
			NetCrew.KICK:
				sheet.add(a, LABEL_KICK, ScreenButton.Kind.DANGER, ASK_KICK, LABEL_KICK, m.display_name)
	if not mine:
		sheet.add(A_REPORT, LABEL_REPORT)
	sheet.add(A_BACK, LABEL_BACK)
	note.text = ""
	refresh()


func _on_member_action(id: StringName) -> void:
	var m := selected
	if client == null or m == null:
		return
	match id:
		A_BACK:
			selected = null
			refresh()
			return
		A_REPORT:
			report_requested.emit(m, {"source": "crew", "crew_id": client.crew.crew_id if client.crew != null else ""})
			return
	if busy:
		return
	busy = true
	var r: NetApiResult
	match id:
		NetCrew.PROMOTE:
			r = await client.promote(m.account_id)
		NetCrew.DEMOTE:
			r = await client.demote(m.account_id)
		NetCrew.TRANSFER:
			r = await client.transfer(m.account_id)
		NetCrew.KICK:
			r = await client.kick(m.account_id)
	busy = false
	if r == null:
		return
	if r.ok:
		selected = null
	_result(r, TEXT_DONE)


func _result(r: NetApiResult, ok_text: String) -> void:
	if r.ok:
		_set_note(note, ok_text, ScreenText.Ink.ACCENT)
	else:
		_set_note(note, NetSocialClient.error_text(r), ScreenText.Ink.HOT)
	_note_left = 0.0
	refresh()


func _set_note(t: ScreenText, value: String, ink: ScreenText.Ink) -> void:
	t.text = value
	t.set_ink(ink)
	_layout()


# ---------------------------------------------------------------- View

## The member sheet's actions (tests: what the role UI offers).
func sheet_actions() -> Array[StringName]:
	return sheet.ids() if sheet.visible else ([] as Array[StringName])


func refresh() -> void:
	var available := client != null and client.available()
	var c: NetCrew = client.crew if client != null else null
	var loaded := client != null and client.crew_loaded
	var in_crew := available and c != null
	var no_crew := available and loaded and c == null
	if selected != null and (c == null or c.member(selected.account_id) == null or c.crew_id != _sheet_crew):
		selected = null
	_sheet_crew = c.crew_id if c != null else ""
	status_text.visible = not in_crew and not no_crew
	status_text.text = TEXT_LOADING if available else FriendsPanel.unavailable_text(client)
	for x: CanvasItem in [create_caption, name_field, tag_field, create_button, create_note, join_caption,
			code_field, join_button, join_note]:
		x.visible = no_crew
	for f: SocialField in [name_field, tag_field, code_field]:
		f.editable = not busy
	create_button.disabled = busy
	join_button.disabled = busy
	var sheet_on := in_crew and selected != null
	sheet.visible = sheet_on
	for x: CanvasItem in [card, crew_caption, tag_text, name_text, members_text, season_text, code_caption,
			code_text, copy_button, rotate_button, crew_actions]:
		x.visible = in_crew and not sheet_on
	share_button.visible = in_crew and not sheet_on and SocialUi.can_share(bridge)
	members_caption.visible = in_crew
	invite_toggle.visible = in_crew
	invite_toggle.text = TEXT_SHOW_MEMBERS if inviting else TEXT_INVITE_FRIENDS
	invite_toggle.disabled = busy
	if not in_crew:
		inviting = false
	var waiting := client.crew_invites.size() if client != null else 0
	invites_caption.visible = no_crew and waiting > 0
	pending_line.visible = in_crew and not sheet_on and waiting > 0
	if waiting == 1:
		pending_line.text = TEXT_PENDING_ONE % client.crew_invites[0].crew_text()
	elif waiting > 1:
		pending_line.text = TEXT_PENDING_MANY % waiting
	if not no_crew:
		for r in invite_rows:
			r.visible = false
	note.visible = in_crew or not note.text.is_empty()
	if in_crew:
		tag_text.text = TEXT_TAG % c.tag
		members_text.text = TEXT_MEMBERS % [c.member_count, c.max_members, String(ROLE_TEXT.get(c.your_role, ""))]
		season_text.text = _season_text()
		code_text.text = c.invite_code
		rotate_button.visible = rotate_button.visible and NetCrew.can_rotate_code(c.your_role)
		if inviting:
			members_caption.text = TEXT_INVITE_NONE if client.crew_invitable().is_empty() else TEXT_INVITE_CAPTION
		else:
			members_caption.text = TEXT_MEMBERS_CAPTION % [c.member_count, c.max_members]
		var key := "%s/%s/%s" % [c.crew_id, c.your_role, c.name]
		if key != _actions_key:
			_actions_key = key
			crew_actions.begin("", "", "")
			crew_actions.add(A_LEAVE, LABEL_LEAVE, ScreenButton.Kind.DANGER, ASK_LEAVE, CONFIRM_LEAVE, c.name)
			if NetCrew.can_disband(c.your_role):
				crew_actions.add(A_DISBAND, LABEL_DISBAND, ScreenButton.Kind.DANGER, ASK_DISBAND, CONFIRM_DISBAND, c.name)
	else:
		_actions_key = ""
		for r in rows:
			r.visible = false
		for x: CanvasItem in [page_text, prev_button, next_button]:
			x.visible = false
	_layout()


func _season_text() -> String:
	if client == null or not client.standing_loaded:
		return TEXT_SEASON_LOADING
	if client.standing_rank <= 0:
		return TEXT_SEASON_NONE % client.standing_period
	return TEXT_SEASON % [client.standing_period, client.standing_rank, HudFormat.thousands(client.standing_score)]


static func _role_text(m: NetSocialPlayer, mine: bool) -> String:
	var r := String(ROLE_TEXT.get(m.role, ""))
	return TEXT_YOU % r if mine else r


func _members() -> Array[NetSocialPlayer]:
	if client == null or client.crew == null:
		return []
	if inviting:
		return client.crew_invitable()
	return client.crew.members


func _pages() -> int:
	return maxi(1, ceili(float(_members().size()) / float(maxi(page_size, 1))))


func _row(i: int) -> SocialRow:
	while rows.size() <= i:
		var r := SocialRow.new()
		r.name = "Member%d" % rows.size()
		r.button_pressed.connect(_on_row_button)
		add_child(r)
		if style != null:
			r.setup(style, tuning)
		rows.append(r)
	return rows[i]


## A friend's row on INVITE FRIENDS: presence, INVITE or INVITED.
func _fill_friend_row(row: SocialRow, p: NetSocialPlayer) -> void:
	row.kind = &"invite_friend"
	row.selected = false
	row.dot = SocialRow.Dot.IN_ROOM if p.in_room() else (SocialRow.Dot.ONLINE if p.is_online() else SocialRow.Dot.OFFLINE)
	var invited := client != null and client.crew_invited_ids.has(p.account_id)
	var status := FriendsPanel.SUB_IN_ROOM if p.in_room() else (FriendsPanel.SUB_ONLINE if p.is_online() else FriendsPanel.SUB_OFFLINE)
	row.set_texts(p.display_name, p.tag_text(), p.crew_tag, status)
	if invited:
		row.set_buttons([LABEL_INVITED], [A_INVITE])
		row.buttons[0].disabled = true
	else:
		row.set_buttons([LABEL_INVITE], [A_INVITE], [ScreenButton.Kind.PRIMARY])
		row.buttons[0].disabled = busy


## The member row for `account_id` on this page (tests).
func row_of(account_id: String) -> SocialRow:
	for r in rows:
		if r.visible and r.player != null and r.player.account_id == account_id:
			return r
	return null


func layout(body: Rect2, header: Rect2) -> void:
	_body = body
	_header = header
	_layout()


func _layout() -> void:
	if style == null or _body.size.x <= 0.0:
		return
	var gap := tuning.spacing_grid_px * 2.0
	var cw := floorf((_body.size.x - gap * 2.0) * 0.5)
	var lx := _body.position.x
	var rx := lx + cw + gap * 2.0
	var y := _body.position.y
	if status_text.visible:
		SocialUi.fit_text(status_text, status_text.text, cw)
		SocialUi.place(status_text, Vector2(lx, y), status_text.get_combined_minimum_size())
	if create_caption.visible:
		_layout_forms(lx, rx, cw, y)
	_layout_crew(lx, rx, cw, y)


func _layout_forms(lx: float, rx: float, cw: float, top: float) -> void:
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var y := top
	var cs := create_caption.get_combined_minimum_size()
	SocialUi.place(create_caption, Vector2(lx, y), cs)
	y += cs.y
	SocialUi.place(name_field, Vector2(lx, y), Vector2(cw, th))
	y += th + g
	var tw := floorf(cw * TAG_SHARE)
	SocialUi.place(tag_field, Vector2(lx, y), Vector2(tw, th))
	SocialUi.place(create_button, Vector2(lx + tw + g, y), Vector2(cw - tw - g, th))
	y += th
	SocialUi.fit_text(create_note, create_note.text, cw)
	SocialUi.place(create_note, Vector2(lx, y), create_note.get_combined_minimum_size())
	y = top
	var js := join_caption.get_combined_minimum_size()
	SocialUi.place(join_caption, Vector2(rx, y), js)
	y += js.y
	var jw := SocialUi.button_width(join_button, tuning)
	SocialUi.place(code_field, Vector2(rx, y), Vector2(cw - jw - g, th))
	SocialUi.place(join_button, Vector2(rx + cw - jw, y), Vector2(jw, th))
	y += th
	SocialUi.fit_text(join_note, join_note.text, cw)
	SocialUi.place(join_note, Vector2(rx, y), join_note.get_combined_minimum_size())
	y += join_note.get_combined_minimum_size().y
	if note.visible:
		SocialUi.fit_text(note, note.text, cw)
		SocialUi.place(note, Vector2(rx, y), note.get_combined_minimum_size())
		y += note.get_combined_minimum_size().y
	_layout_invites(rx, cw, y + g)


## The invites waiting for you under JOIN A CREW: "<crew> [TAG]", FROM name, JOIN, DECLINE.
func _layout_invites(x: float, w: float, top: float) -> void:
	var list: Array[NetCrew.Invite] = client.crew_invites if client != null else []
	var y := top
	if invites_caption.visible:
		var cs := invites_caption.get_combined_minimum_size()
		SocialUi.place(invites_caption, Vector2(x, y), cs)
		y += cs.y
	var th := tuning.touch_target_px
	var g := tuning.spacing_grid_px
	var fit := maxi(floori((_body.end.y - y + g) / (th + g)), 0)
	var n := mini(mini(list.size(), INVITE_ROWS_MAX), fit) if invites_caption.visible else 0
	for i in maxi(invite_rows.size(), n):
		if i >= n:
			if i < invite_rows.size():
				invite_rows[i].visible = false
			continue
		var row := _invite_row(i)
		var inv := list[i]
		invite_row_ids[i] = inv.invite_id
		row.visible = true
		row.kind = &"crew_invite"
		row.dot = SocialRow.Dot.NONE
		row.set_texts(inv.crew_name, "", inv.crew_tag,
				TEXT_INVITE_FROM % inv.from_name if not inv.from_name.is_empty() else TEXT_INVITE_FROM_NONE,
				ScreenText.Ink.GOLD)
		row.set_buttons([LABEL_JOIN_INVITE, LABEL_DECLINE], [A_ACCEPT_INVITE, A_DECLINE_INVITE],
				[ScreenButton.Kind.PRIMARY, ScreenButton.Kind.NORMAL])
		for b in row.buttons:
			b.disabled = busy
		row.layout(Rect2(x, y + float(i) * (th + g), w, th))


func _layout_crew(lx: float, rx: float, cw: float, top: float) -> void:
	if not members_caption.visible:
		return
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var gap := g * 2.0
	var y := top
	if sheet.visible:
		y += sheet.layout(Rect2(lx, y, cw, _body.end.y - y)) + g
	else:
		# The card.
		var inner := lx + gap
		var iw := cw - gap * 2.0
		var cy := y + gap
		var cs := crew_caption.get_combined_minimum_size()
		SocialUi.place(crew_caption, Vector2(inner, cy), cs)
		cy += cs.y
		var ts := tag_text.get_combined_minimum_size()
		SocialUi.place(tag_text, Vector2(inner, cy), ts)
		SocialUi.fit_text(name_text, client.crew.name if client != null and client.crew != null else "", iw - ts.x - g)
		SocialUi.place(name_text, Vector2(inner + ts.x + g, cy), name_text.get_combined_minimum_size())
		cy += ts.y
		for t: ScreenText in [members_text, season_text]:
			SocialUi.fit_text(t, t.text, iw)
			SocialUi.place(t, Vector2(inner, cy), t.get_combined_minimum_size())
			cy += t.get_combined_minimum_size().y
		cy += gap
		SocialUi.place(card, Vector2(lx, y), Vector2(cw, cy - y))
		y = cy + g
		# The invite code and its buttons.
		var ks := code_caption.get_combined_minimum_size()
		SocialUi.place(code_caption, Vector2(lx, y), ks)
		y += ks.y
		var buttons: Array[ScreenButton] = []
		for b: ScreenButton in [copy_button, share_button, rotate_button]:
			if b.visible:
				buttons.append(b)
		var bx := lx + cw
		for i in range(buttons.size() - 1, -1, -1):
			var w := SocialUi.button_width(buttons[i], tuning)
			bx -= w
			SocialUi.place(buttons[i], Vector2(bx, y), Vector2(w, th))
			bx -= g
		SocialUi.fit_text(code_text, code_text.text, bx - lx)
		var cts := code_text.get_combined_minimum_size()
		SocialUi.place(code_text, Vector2(lx, y + (th - cts.y) * 0.5), cts)
		y += th
	var nh := float(roundi(float(BODY_PX) * style.ts * ScreenText.LINE_EM))
	SocialUi.fit_text(note, note.text, cw)
	SocialUi.place(note, Vector2(lx, y), note.get_combined_minimum_size())
	y += nh + g
	if pending_line.visible:
		SocialUi.fit_text(pending_line, pending_line.text, cw)
		SocialUi.place(pending_line, Vector2(lx, y), pending_line.get_combined_minimum_size())
		y += pending_line.get_combined_minimum_size().y + g
	if crew_actions.visible:
		crew_actions.layout(Rect2(lx, y, cw, _body.end.y - y))
	# Members, paged.
	var my := top
	# The caption with INVITE FRIENDS / MEMBERS at the row's right end.
	var tw := SocialUi.button_width(invite_toggle, tuning)
	SocialUi.place(invite_toggle, Vector2(rx + cw - tw, my), Vector2(tw, th))
	SocialUi.fit_text(members_caption, members_caption.text, cw - tw - g)
	var mcs := members_caption.get_combined_minimum_size()
	SocialUi.place(members_caption, Vector2(rx, my + (th - mcs.y) * 0.5), mcs)
	my += th + g
	page_size = maxi(1, floori((_body.end.y - my + g) / (th + g)))
	var list := _members()
	page = clampi(page, 0, _pages() - 1)
	var first := page * page_size
	var me := client.my_account_id() if client != null else ""
	for i in maxi(rows.size(), page_size):
		var k := first + i
		if i >= page_size or k >= list.size():
			if i < rows.size():
				rows[i].visible = false
			continue
		var row := _row(i)
		var m := list[k]
		var mine := m.account_id == me
		row.visible = true
		row.player = m
		if inviting:
			_fill_friend_row(row, m)
			row.layout(Rect2(rx, my + float(i) * (th + g), cw, th))
			continue
		row.kind = &"member"
		row.selected = selected != null and selected.account_id == m.account_id
		row.dot = SocialRow.Dot.NONE
		row.set_texts(m.display_name, m.tag_text(), "", _role_text(m, mine),
				ScreenText.Ink.ACCENT if m.role == NetCrew.OWNER else ScreenText.Ink.MUTED)
		if mine:
			row.set_buttons([])
		else:
			row.set_buttons([LABEL_MORE], [A_MORE])
		row.layout(Rect2(rx, my + float(i) * (th + g), cw, th))
	var paged := _pages() > 1
	for x: CanvasItem in [page_text, prev_button, next_button]:
		x.visible = paged
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
