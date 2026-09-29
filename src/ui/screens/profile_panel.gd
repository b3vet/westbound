class_name ProfilePanel
extends Control
## The online account panel (pause menu → SETTINGS → ACCOUNT). Spec: multiplayer handoff
## → Client changes ("Profile and account: link Apple / Google, rename, ..., delete
## account"), Accounts and authentication (names `name#1234`, account deletion reachable
## from the profile screen); plan MP-D2 (device accounts only: Apple / Google show as
## coming soon). WP N1.2; docs/NET_CLIENT.md → Profile panel.
##
## Messages are kept under about 50 characters: screen text does not wrap.
## Left: the player card (name#tag, online status and what it means), then RENAME (a
## text field, SAVE, and the server's answer inline) or, when not signed in, TRY AGAIN
## (and NEW ACCOUNT when the stored account was refused). Right: SIGN IN WITH APPLE /
## GOOGLE (disabled, COMING SOON), then DELETE ACCOUNT with a confirm step (DELETE
## FOREVER / CANCEL). Everything talks to a NetSession (NetSession.current unless
## bound) and follows its signals; nothing here blocks the game.
##
## Touch: the buttons are ScreenButtons (BaseButton: emulated mouse events, so raw touch
## ids never index anything) at least touch_target_px tall; the text field too. While
## the field has focus the run's PlayerInput stops reading keys (typing "P" must not
## unpause the game); it reads them again when the field loses focus or the panel hides.

const TEXT_PLAYER := "PLAYER"
const TEXT_RENAME := "RENAME"
const TEXT_LINK := "LINK ACCOUNT"
const TEXT_ACCOUNT := "ACCOUNT"
const TEXT_SAVE := "SAVE"
const TEXT_APPLE := "SIGN IN WITH APPLE"
const TEXT_GOOGLE := "SIGN IN WITH GOOGLE"
const TEXT_SOON := "COMING SOON"
const TEXT_DELETE := "DELETE ACCOUNT"
const TEXT_DELETE_FOREVER := "DELETE FOREVER"
const TEXT_CANCEL := "CANCEL"
const TEXT_RETRY := "TRY AGAIN"
const TEXT_SIGN_IN := "SIGN IN"
const TEXT_NEW_ACCOUNT := "NEW ACCOUNT"
const TEXT_PLACEHOLDER := "NEW NAME"
const TEXT_NO_ACCOUNT := "NO ACCOUNT YET"
const TEXT_CONFIRM_1 := "Delete your account, name and online data for good?"
const TEXT_CONFIRM_2 := "This cannot be undone. Single-player progress stays."
const TEXT_SAVING := "Saving..."
const TEXT_SAVED := "Name saved."
const TEXT_DELETING := "Deleting..."
const TEXT_DELETED := "Account deleted from the server and this device."
const TEXT_RENAME_HINT := "3–16 characters. One rename every 30 days."

## Status chip and note per NetSession.Status.
const STATUS_LABEL := {
	NetSession.Status.IDLE: "OFFLINE",
	NetSession.Status.CONNECTING: "CONNECTING",
	NetSession.Status.ONLINE: "ONLINE",
	NetSession.Status.OFFLINE: "OFFLINE",
	NetSession.Status.SIGNED_OUT: "SIGNED OUT",
	NetSession.Status.BANNED: "SUSPENDED",
	NetSession.Status.FAILED: "ACCOUNT ERROR",
	NetSession.Status.DISABLED: "ONLINE OFF",
}
const NOTE_ONLINE := "Device account, saved on this device."
const NOTE_NOT_SAVED := "Not saved on this device (private browsing?)"
const NOTE_CONNECTING := "Signing in..."
const NOTE_OFFLINE := "Can't reach the server. Retrying by itself."
const NOTE_SIGNED_OUT := "Signed out on this device."
const NOTE_DISABLED := "Online features are off in this build."
const NOTE_NO_SESSION := "Online play is not available in this build."

## Name line size (display face) and body lines, canvas px at 100% text size.
const NAME_PX := 32
const LABEL_PX := 16
const BODY_PX := 16
## The rename row: SAVE's share of the column.
const SAVE_SHARE := 0.3   # lint: allow-number layout proportion
## Selection highlight opacity in the text field.
const SELECTION_A := 0.35   # lint: allow-number look

var style: HudStyle
var tuning: HudTuning
var session: NetSession
## The run's input hub: its key reading pauses while the name field has focus.
var hub: PlayerInput
var confirming: bool = false
var busy: bool = false

var card: ScreenPanel
var caption: ScreenText
var name_text: ScreenText
var tag_text: ScreenText
var status_text: ScreenText
var status_note: ScreenText
var rename_caption: ScreenText
var name_edit: LineEdit
var save_button: ScreenButton
var rename_note: ScreenText
var retry_button: ScreenButton
var new_account_button: ScreenButton
var link_caption: ScreenText
var apple_button: ScreenButton
var google_button: ScreenButton
var account_caption: ScreenText
var delete_button: ScreenButton
var confirm_text_1: ScreenText
var confirm_text_2: ScreenText
var confirm_button: ScreenButton
var cancel_button: ScreenButton
var delete_note: ScreenText

var _keys_muted: bool = false
var _area: Rect2 = Rect2()


func _init() -> void:
	name = "Profile"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	card = ScreenPanel.new()
	add_child(card)
	caption = _text(TEXT_PLAYER, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	name_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.TEXT)
	tag_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.MUTED)
	tag_text.tabular = true
	status_text = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.ACCENT)
	status_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	rename_caption = _text(TEXT_RENAME, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	name_edit = LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.placeholder_text = TEXT_PLACEHOLDER
	name_edit.context_menu_enabled = false
	name_edit.select_all_on_focus = true
	name_edit.text_submitted.connect(func(_t: String) -> void: save())
	name_edit.focus_entered.connect(_mute_keys.bind(true))
	name_edit.focus_exited.connect(_mute_keys.bind(false))
	add_child(name_edit)
	save_button = _button(TEXT_SAVE, ScreenButton.Kind.PRIMARY, save)
	rename_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	retry_button = _button(TEXT_RETRY, ScreenButton.Kind.NORMAL, retry)
	new_account_button = _button(TEXT_NEW_ACCOUNT, ScreenButton.Kind.NORMAL, new_account)
	link_caption = _text(TEXT_LINK, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	apple_button = _button(TEXT_APPLE, ScreenButton.Kind.NORMAL, Callable())
	google_button = _button(TEXT_GOOGLE, ScreenButton.Kind.NORMAL, Callable())
	for b: ScreenButton in [apple_button, google_button]:
		b.disabled = true
		b.note = TEXT_SOON
	account_caption = _text(TEXT_ACCOUNT, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	delete_button = _button(TEXT_DELETE, ScreenButton.Kind.DANGER, ask_delete)
	confirm_text_1 = _text(TEXT_CONFIRM_1, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.HOT)
	confirm_text_2 = _text(TEXT_CONFIRM_2, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	confirm_button = _button(TEXT_DELETE_FOREVER, ScreenButton.Kind.DANGER, confirm_delete)
	cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, cancel_delete)
	delete_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)


func _text(value: String, face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var t := ScreenText.make(value, face, px, ink)
	add_child(t)
	return t


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 20)
	b.name = label.capitalize().replace(" ", "")
	if action.is_valid():
		b.pressed.connect(action)
	add_child(b)
	return b


## The design system (the pause screen's style and HUD tuning).
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
	_style_edit()
	refresh()


## Follows `s` (null: NetSession.current when the panel shows).
func bind(s: NetSession) -> void:
	_connect(false)
	session = s
	_connect(true)
	refresh()


## A session is there to show (the pause menu hides its ACCOUNT button otherwise).
func has_session() -> bool:
	return _session() != null


func _session() -> NetSession:
	if session != null and is_instance_valid(session):
		return session
	var c := NetSession.current
	return c if c != null and is_instance_valid(c) else null


func _connect(on: bool) -> void:
	if session == null or not is_instance_valid(session):
		return
	var sigs: Array[Signal] = [session.status_changed, session.profile_changed, session.signed_in,
			session.signed_out, session.banned]
	for sig in sigs:
		if on and not sig.is_connected(_on_session_signal):
			sig.connect(_on_session_signal)
		elif not on and sig.is_connected(_on_session_signal):
			sig.disconnect(_on_session_signal)


func _on_session_signal(_a: Variant = null) -> void:
	refresh()


## Shows the panel fresh (no confirm step, no old messages).
func open() -> void:
	if session == null:
		bind(_session())
	confirming = false
	rename_note.text = ""
	delete_note.text = ""
	name_edit.text = ""
	refresh()


func _exit_tree() -> void:
	_connect(false)
	_mute_keys(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if name_edit != null and name_edit.has_focus():
			name_edit.release_focus()
		_mute_keys(false)


# ---------------------------------------------------------------- Actions

func save() -> void:
	var s := _session()
	if s == null or busy:
		return
	name_edit.release_focus()
	busy = true
	_note(rename_note, TEXT_SAVING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await s.rename(name_edit.text)
	busy = false
	if r.ok:
		name_edit.text = ""
		_note(rename_note, TEXT_SAVED, ScreenText.Ink.ACCENT)
	else:
		_note(rename_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
	refresh()


func ask_delete() -> void:
	confirming = true
	delete_note.text = ""
	refresh()


func cancel_delete() -> void:
	confirming = false
	refresh()


func confirm_delete() -> void:
	var s := _session()
	if s == null or busy:
		return
	busy = true
	_note(delete_note, TEXT_DELETING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await s.delete_account()
	busy = false
	confirming = false
	if r.ok:
		rename_note.text = ""
		_note(delete_note, TEXT_DELETED, ScreenText.Ink.ACCENT)
	else:
		_note(delete_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
	refresh()


func retry() -> void:
	var s := _session()
	if s != null:
		s.retry()
	refresh()


func new_account() -> void:
	var s := _session()
	if s != null:
		s.create_new_account()
	refresh()


func _note(t: ScreenText, value: String, ink: ScreenText.Ink) -> void:
	t.text = value
	t.set_ink(ink)
	_layout()


# ---------------------------------------------------------------- View

## Re-reads the session into the widgets.
func refresh() -> void:
	var s := _session()
	var st: NetSession.Status = s.status if s != null else NetSession.Status.DISABLED
	var p: NetProfile = s.profile if s != null else null
	var shown := p != null and st != NetSession.Status.SIGNED_OUT
	name_text.text = p.display_name if shown else TEXT_NO_ACCOUNT
	name_text.set_ink(ScreenText.Ink.TEXT if shown else ScreenText.Ink.MUTED)
	tag_text.text = p.tag_text() if shown else ""
	status_text.text = String(STATUS_LABEL.get(st, ""))
	match st:
		NetSession.Status.ONLINE:
			status_text.set_ink(ScreenText.Ink.ACCENT)
		NetSession.Status.BANNED, NetSession.Status.FAILED:
			status_text.set_ink(ScreenText.Ink.HOT)
		_:
			status_text.set_ink(ScreenText.Ink.MUTED)
	status_note.text = _status_note(s, st)
	var online := st == NetSession.Status.ONLINE
	var can_retry := s != null and (st == NetSession.Status.OFFLINE or st == NetSession.Status.FAILED
			or st == NetSession.Status.BANNED or st == NetSession.Status.SIGNED_OUT)
	rename_caption.visible = online
	name_edit.visible = online
	name_edit.editable = online and not busy
	save_button.visible = online
	save_button.disabled = busy
	if online and rename_note.text.is_empty():
		_note_quiet(rename_note, _rename_hint(s, p), ScreenText.Ink.MUTED)
	rename_note.visible = online or not rename_note.text.is_empty()
	retry_button.visible = can_retry and not online
	retry_button.text = TEXT_SIGN_IN if st == NetSession.Status.SIGNED_OUT else TEXT_RETRY
	new_account_button.visible = st == NetSession.Status.FAILED
	var can_delete := s != null and (online or st == NetSession.Status.BANNED)
	delete_button.visible = can_delete and not confirming
	for c: CanvasItem in [confirm_text_1, confirm_text_2, confirm_button, cancel_button]:
		c.visible = can_delete and confirming
	confirm_button.disabled = busy
	account_caption.visible = can_delete or not delete_note.text.is_empty()
	delete_note.visible = not delete_note.text.is_empty()
	var nt: NetTuning = s.tuning if s != null else null
	name_edit.max_length = nt.display_name_max_chars if nt != null else 0
	_layout()


func _note_quiet(t: ScreenText, value: String, ink: ScreenText.Ink) -> void:
	t.text = value
	t.set_ink(ink)


static func _status_note(s: NetSession, st: NetSession.Status) -> String:
	if s == null:
		return NOTE_NO_SESSION
	match st:
		NetSession.Status.ONLINE:
			return NOTE_ONLINE if s.storage_ok else NOTE_NOT_SAVED
		NetSession.Status.CONNECTING, NetSession.Status.IDLE:
			return NOTE_CONNECTING
		NetSession.Status.OFFLINE:
			return NOTE_OFFLINE
		NetSession.Status.SIGNED_OUT:
			return NOTE_SIGNED_OUT
		NetSession.Status.BANNED:
			return NetSession.banned_text(s.banned_until)
		NetSession.Status.FAILED:
			return NetSession.error_text(s.last_error, s.now_unix())
		NetSession.Status.DISABLED:
			return NOTE_DISABLED
	return ""


static func _rename_hint(s: NetSession, p: NetProfile) -> String:
	if s != null and p != null and not p.can_rename(s.now_unix()):
		return NetSession.cooldown_text(p.next_rename_at, s.now_unix())
	return TEXT_RENAME_HINT


func _style_edit() -> void:
	if style == null or tuning == null:
		return
	var border := UiTheme.border_px(tuning)
	var pad := tuning.spacing_grid_px * 2.0
	var normal := UiTheme.box(tuning.control_bevel_px, border, style.panel_fill, style.edge_idle)
	var focus := UiTheme.box(tuning.control_bevel_px, border, Color(style.ink, 1.0), style.accent)
	var off := UiTheme.box(tuning.control_bevel_px, border, style.panel_fill, Color(style.muted, SELECTION_A))
	for b: StyleBoxFlat in [normal, focus, off]:
		b.content_margin_left = pad
		b.content_margin_right = pad
	name_edit.add_theme_stylebox_override(&"normal", normal)
	name_edit.add_theme_stylebox_override(&"focus", focus)
	name_edit.add_theme_stylebox_override(&"read_only", off)
	name_edit.add_theme_font_override(&"font", style.body)
	name_edit.add_theme_font_size_override(&"font_size", maxi(1, roundi(float(tuning.font_screen_button_px) * style.ts)))
	name_edit.add_theme_color_override(&"font_color", style.text)
	name_edit.add_theme_color_override(&"font_placeholder_color", style.muted)
	name_edit.add_theme_color_override(&"font_uneditable_color", style.muted)
	name_edit.add_theme_color_override(&"caret_color", style.accent)
	name_edit.add_theme_color_override(&"selection_color", Color(style.accent, SELECTION_A))


## Lays the panel out in `area` (panel-local px), or again in the last area.
func layout(area: Rect2) -> void:
	_area = area
	_layout()


func _layout() -> void:
	if style == null or tuning == null or _area.size.x <= 0.0:
		return
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var gap := g * 2.0
	var cw := (_area.size.x - gap * 2.0) * 0.5
	var lx := _area.position.x
	var rx := lx + cw + gap * 2.0
	var y := _area.position.y
	# Player card.
	var cs := caption.get_combined_minimum_size()
	var ns := name_text.get_combined_minimum_size()
	var ss := status_text.get_combined_minimum_size()
	var sn := status_note.get_combined_minimum_size()
	var inner := lx + gap
	var cy := y + gap
	_place(caption, Vector2(inner, cy), cs)
	cy += cs.y
	_place(name_text, Vector2(inner, cy), ns)
	_place(tag_text, Vector2(inner + ns.x + g * 0.5, cy), tag_text.get_combined_minimum_size())
	cy += ns.y
	_place(status_text, Vector2(inner, cy), ss)
	cy += ss.y
	_place(status_note, Vector2(inner, cy), Vector2(cw - gap * 2.0, sn.y))
	cy += sn.y + gap
	card.position = Vector2(lx, y)
	card.size = Vector2(cw, cy - y)
	y = cy + gap
	# Rename, or the sign-in actions.
	if name_edit.visible:
		var rs := rename_caption.get_combined_minimum_size()
		_place(rename_caption, Vector2(lx, y), rs)
		y += rs.y
		var sw := maxf(cw * SAVE_SHARE, save_button.get_combined_minimum_size().x)
		name_edit.position = Vector2(lx, y)
		name_edit.size = Vector2(cw - sw - g, th)
		save_button.position = Vector2(lx + cw - sw, y)
		save_button.size = Vector2(sw, th)
		y += th + g
	elif retry_button.visible:
		var n := 2 if new_account_button.visible else 1
		var bw := (cw - g * float(n - 1)) / float(n)
		retry_button.position = Vector2(lx, y)
		retry_button.size = Vector2(bw, th)
		new_account_button.position = Vector2(lx + bw + g, y)
		new_account_button.size = Vector2(bw, th)
		y += th + g
	_place(rename_note, Vector2(lx, y), Vector2(cw, rename_note.get_combined_minimum_size().y))
	# Right column: linking (coming soon), then the account's deletion.
	var ry := _area.position.y
	var ls := link_caption.get_combined_minimum_size()
	_place(link_caption, Vector2(rx, ry), ls)
	ry += ls.y
	for b: ScreenButton in [apple_button, google_button]:
		b.position = Vector2(rx, ry)
		b.size = Vector2(cw, th)
		ry += th + g
	ry += g
	var acs := account_caption.get_combined_minimum_size()
	_place(account_caption, Vector2(rx, ry), acs)
	ry += acs.y
	if confirming:
		for t: ScreenText in [confirm_text_1, confirm_text_2]:
			var s := t.get_combined_minimum_size()
			_place(t, Vector2(rx, ry), Vector2(cw, s.y))
			ry += s.y
		ry += g
		var bw2 := (cw - g) * 0.5
		confirm_button.position = Vector2(rx, ry)
		confirm_button.size = Vector2(bw2, th)
		cancel_button.position = Vector2(rx + bw2 + g, ry)
		cancel_button.size = Vector2(bw2, th)
		ry += th + g
	elif delete_button.visible:
		delete_button.position = Vector2(rx, ry)
		delete_button.size = Vector2(cw, th)
		ry += th + g
	_place(delete_note, Vector2(rx, ry), Vector2(cw, delete_note.get_combined_minimum_size().y))


static func _place(c: Control, at: Vector2, sz: Vector2) -> void:
	c.position = at
	c.size = sz


func _mute_keys(on: bool) -> void:
	if on == _keys_muted:
		return
	_keys_muted = on
	if hub != null and is_instance_valid(hub):
		hub.set_process_input(not on)
