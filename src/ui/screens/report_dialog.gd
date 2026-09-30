class_name ReportDialog
extends Control
## The report dialog, reusable from any screen: a friend row, a crew member, a leaderboard
## entry (N7.2), a room's player list (N5). Spec: multiplayer handoff → Moderation →
## Report ("a player button (from the room menu or a leaderboard entry), rate-limited per
## account"); docs/SERVER.md → Social API → Reports (the reasons, `context`, 10 a day).
## WP N9.2; docs/SCREENS.md → Social.
##
##   var dialog := ReportDialog.new()
##   host.add_child(dialog); dialog.setup(style, hud_tuning); dialog.layout(area)
##   dialog.open_for(NetSocialClient.of(NetSession.current), entry.account_id,
##       entry.full_name, {"source": "leaderboard", "board": "loop", "run_id": entry.run_id})
##   dialog.closed.connect(func(sent: bool) -> void: ...)   # hides itself
##
## Steps: pick a reason (the API's six, as big option buttons) → SEND REPORT → the
## confirm line with REPORT / BACK → "Report sent. Thank you." with DONE. A rate-limited
## account (429) sees when it may report again, and SEND stays off until then.

signal closed(sent: bool)

enum Step { PICK, CONFIRM, SENT }

const TEXT_CAPTION := "REPORT PLAYER"
const TEXT_REASON := "REASON"
const REASON_LABELS := {
	"cheating": "CHEATING", "offensive_name": "OFFENSIVE NAME", "offensive_crew": "OFFENSIVE CREW",
	"harassment": "HARASSMENT", "griefing": "GRIEFING", "other": "OTHER",
}
const TEXT_HINT := "Reports go to the moderators."
const TEXT_PICK := "Pick a reason first."
const TEXT_SEND := "SEND REPORT"
const TEXT_CANCEL := "CANCEL"
const TEXT_ASK := "Report for %s?"
const TEXT_CONFIRM := "REPORT"
const TEXT_BACK := "BACK"
const TEXT_SENDING := "Sending..."
const TEXT_SENT := "Report sent. Thank you."
const TEXT_DONE := "DONE"
const CAPTION_PX := 16
const NAME_PX := 32
const BODY_PX := 16
const COLUMNS := 2

var style: HudStyle
var tuning: HudTuning
var client: NetSocialClient
var step: Step = Step.PICK
var reason: String = ""
var target_id: String = ""
var target_name: String = ""
var context: Dictionary = {}
var busy: bool = false
## The last server answer (tests).
var last_result: NetApiResult

var card: ScreenPanel
var caption: ScreenText
var name_text: ScreenText
var note: ScreenText
var question: ScreenText
var reason_caption: ScreenText
var reason_buttons: Array[ScreenButton] = []
var send_button: ScreenButton
var cancel_button: ScreenButton
var confirm_button: ScreenButton
var back_button: ScreenButton
var done_button: ScreenButton

var _area: Rect2 = Rect2()


func _init() -> void:
	name = "Report"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	card = ScreenPanel.new()
	card.edge = ScreenPanel.Edge.ACCENT
	add_child(card)
	caption = _text(TEXT_CAPTION, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.MUTED)
	name_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.TEXT)
	note = _text(TEXT_HINT, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	question = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.HOT)
	reason_caption = _text(TEXT_REASON, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.MUTED)
	for r: String in NetSocialClient.REPORT_REASONS:
		var b := ScreenButton.make(String(REASON_LABELS.get(r, r.to_upper())), ScreenButton.Kind.OPTION, BODY_PX)
		b.name = "Reason_" + r
		b.pressed.connect(choose.bind(r))
		add_child(b)
		reason_buttons.append(b)
	send_button = _button(TEXT_SEND, ScreenButton.Kind.DANGER, send)
	cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, cancel)
	confirm_button = _button(TEXT_CONFIRM, ScreenButton.Kind.DANGER, confirm)
	back_button = _button(TEXT_BACK, ScreenButton.Kind.NORMAL, back)
	done_button = _button(TEXT_DONE, ScreenButton.Kind.PRIMARY, done)


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
	_refresh()


## Opens the dialog about `account_id` (`display` is its name#tag), with `ctx` saying
## where the report comes from.
func open_for(c: NetSocialClient, account_id: String, display: String, ctx: Dictionary = {}) -> void:
	client = c
	target_id = account_id
	target_name = display
	context = ctx
	reason = ""
	step = Step.PICK
	busy = false
	last_result = null
	_set_note(TEXT_HINT, ScreenText.Ink.MUTED)
	if client != null and client.report_wait_s() > 0.0:
		var r := NetApiResult.failure(NetApi.HTTP_TOO_MANY, NetApiResult.RATE_LIMITED)
		r.retry_after_s = client.report_wait_s()
		_set_note(NetSocialClient.error_text(r, true), ScreenText.Ink.HOT)
	visible = true
	_refresh()


func is_open() -> bool:
	return visible


func choose(r: String) -> void:
	if step != Step.PICK or busy:
		return
	reason = r
	if not rate_limited():
		_set_note(TEXT_HINT, ScreenText.Ink.MUTED)
	_refresh()


## SEND REPORT: the confirm step (a reason is needed first).
func send() -> void:
	if step != Step.PICK or busy or rate_limited():
		return
	if reason.is_empty():
		_set_note(TEXT_PICK, ScreenText.Ink.HOT)
		return
	step = Step.CONFIRM
	question.text = TEXT_ASK % String(REASON_LABELS.get(reason, reason)).to_lower()
	_refresh()


func back() -> void:
	if busy:
		return
	step = Step.PICK
	_refresh()


func confirm() -> void:
	if step != Step.CONFIRM or busy:
		return
	if client == null:
		_set_note(FriendsPanel.unavailable_text(null), ScreenText.Ink.HOT)
		step = Step.PICK
		_refresh()
		return
	busy = true
	_set_note(TEXT_SENDING, ScreenText.Ink.MUTED)
	_refresh()
	var r: NetApiResult = await client.report(target_id, reason, context)
	busy = false
	last_result = r
	if r.ok:
		step = Step.SENT
		_set_note(TEXT_SENT, ScreenText.Ink.ACCENT)
	else:
		step = Step.PICK
		_set_note(NetSocialClient.error_text(r, true), ScreenText.Ink.HOT)
	_refresh()


func cancel() -> void:
	if busy:
		return
	_close(false)


func done() -> void:
	_close(true)


func _close(sent: bool) -> void:
	visible = false
	closed.emit(sent)


## Reports are refused until the server's Retry-After passes.
func rate_limited() -> bool:
	return client != null and client.report_wait_s() > 0.0


func _set_note(value: String, ink: ScreenText.Ink) -> void:
	note.text = value
	note.set_ink(ink)


func _refresh() -> void:
	name_text.text = target_name
	var picking := step == Step.PICK
	for i in reason_buttons.size():
		var b := reason_buttons[i]
		b.selected = NetSocialClient.REPORT_REASONS[i] == reason
		b.disabled = not picking or busy
	send_button.visible = picking
	send_button.disabled = busy or rate_limited()
	cancel_button.visible = picking
	question.visible = step == Step.CONFIRM
	confirm_button.visible = step == Step.CONFIRM
	confirm_button.disabled = busy
	back_button.visible = step == Step.CONFIRM
	back_button.disabled = busy
	done_button.visible = step == Step.SENT
	_layout()


## Lays the dialog out over `area` (parent-local px).
func layout(area: Rect2) -> void:
	_area = area
	_layout()


func _layout() -> void:
	if style == null or _area.size.x <= 0.0:
		return
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var gap := g * 2.0
	SocialUi.place(card, _area.position, _area.size)
	var inner := _area.grow(-gap)
	var cw := floorf((inner.size.x - gap) * 0.5)
	var lx := inner.position.x
	var rx := lx + cw + gap
	var y := inner.position.y
	for t: ScreenText in [caption, name_text, note, question]:
		if not t.visible:
			continue
		SocialUi.fit_text(t, t.text if t != name_text else target_name, cw)
		SocialUi.place(t, Vector2(lx, y), t.get_combined_minimum_size())
		y += t.get_combined_minimum_size().y
	var by := inner.end.y - th
	var bw := (cw - g) * 0.5
	for pair: Array in [[send_button, cancel_button], [confirm_button, back_button]]:
		SocialUi.place(pair[0] as Control, Vector2(lx, by), Vector2(bw, th))
		SocialUi.place(pair[1] as Control, Vector2(lx + bw + g, by), Vector2(bw, th))
	SocialUi.place(done_button, Vector2(lx, by), Vector2(bw, th))
	var ry := inner.position.y
	var rs := reason_caption.get_combined_minimum_size()
	SocialUi.place(reason_caption, Vector2(rx, ry), rs)
	ry += rs.y
	var ow := (inner.end.x - rx - g * float(COLUMNS - 1)) / float(COLUMNS)
	for i in reason_buttons.size():
		var col := i % COLUMNS
		var row := floori(float(i) / float(COLUMNS))
		SocialUi.place(reason_buttons[i], Vector2(rx + float(col) * (ow + g), ry + float(row) * (th + g)), Vector2(ow, th))
