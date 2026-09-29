class_name SocialActions
extends Control
## An action sheet for one subject (a friend, a crew member, the crew): a caption, the
## subject's name and a status line, then its actions as big buttons two to a row. An
## action with a question asks first: the question in hot text with CONFIRM-style and
## CANCEL buttons in place of the actions. Spec: multiplayer handoff → Friends and
## presence (remove, blocking), Crews (kick, promote, transfer, leave, disband), Moderation
## → Report; UI, HUD and design system → Design system. WP N9.2; docs/SCREENS.md → Social.
##
##   sheet.begin("FRIEND", "LoneWolf#0007", "ONLINE")
##   sheet.add(&"remove", "REMOVE", ScreenButton.Kind.DANGER, "Remove LoneWolf?", "REMOVE")
##   sheet.add(&"back", "BACK")
##   sheet.chosen.connect(_on_action)          # after the confirm step, if any

signal chosen(id: StringName)

const MAX_ACTIONS := 6
const COLUMNS := 2
const CAPTION_PX := 16
const TITLE_PX := 28
const BODY_PX := 16
const TEXT_CANCEL := "CANCEL"

var style: HudStyle
var tuning: HudTuning
## The action waiting for its confirm (&"" = none).
var pending: StringName = &""

var caption: ScreenText
var title: ScreenText
var sub: ScreenText
var question: ScreenText
var buttons: Array[ScreenButton] = []
var confirm_button: ScreenButton
var cancel_button: ScreenButton

var _ids: Array[StringName] = []
var _asks: PackedStringArray = PackedStringArray()
var _ask_names: PackedStringArray = PackedStringArray()
var _ask_i: int = -1
var _confirm_labels: PackedStringArray = PackedStringArray()
var _title_full: String = ""
var _area: Rect2 = Rect2()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	caption = _text(ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.MUTED)
	title = _text(ScreenText.Face.DISPLAY, TITLE_PX, ScreenText.Ink.TEXT)
	sub = _text(ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	question = _text(ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.HOT)
	for i in MAX_ACTIONS:
		var b := ScreenButton.make("", ScreenButton.Kind.NORMAL, BODY_PX)
		b.name = "Action%d" % i
		b.pressed.connect(_on_pressed.bind(i))
		add_child(b)
		buttons.append(b)
	confirm_button = ScreenButton.make("", ScreenButton.Kind.DANGER, BODY_PX)
	confirm_button.name = "Confirm"
	confirm_button.pressed.connect(confirm)
	add_child(confirm_button)
	cancel_button = ScreenButton.make(TEXT_CANCEL, ScreenButton.Kind.NORMAL, BODY_PX)
	cancel_button.name = "Cancel"
	cancel_button.pressed.connect(cancel)
	add_child(cancel_button)
	begin("", "", "")


func _text(face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var t := ScreenText.make("", face, px, ink)
	add_child(t)
	return t


func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	for c: ScreenText in [caption, title, sub, question]:
		c.setup(s)
	for b: ScreenButton in buttons + [confirm_button, cancel_button]:
		b.setup(s)
		b.size_px = t.font_screen_body_px


## Starts a new sheet (no actions, no pending confirm).
func begin(caption_text: String, title_text: String, sub_text: String) -> void:
	caption.text = caption_text
	_title_full = title_text
	title.text = title_text
	sub.text = sub_text
	_ids.clear()
	_asks.clear()
	_ask_names.clear()
	_confirm_labels.clear()
	pending = &""
	_refresh()


## Adds an action button. With `ask`, tapping it asks first; `confirm_label` names the
## confirm button (default: the action's label). With `ask_name`, `ask` is a format with
## one %s for it, and a name too long for the line is shortened, never the question.
func add(id: StringName, label: String, kind: ScreenButton.Kind = ScreenButton.Kind.NORMAL,
		ask: String = "", confirm_label: String = "", ask_name: String = "") -> void:
	if _ids.size() >= MAX_ACTIONS:
		return
	var b := buttons[_ids.size()]
	b.text = label
	b.kind = kind
	b.disabled = false
	b.note = ""
	_ids.append(id)
	_asks.append(ask)
	_ask_names.append(ask_name)
	_confirm_labels.append(confirm_label if not confirm_label.is_empty() else label)
	_refresh()


## The button of action `id` (null when absent).
func button(id: StringName) -> ScreenButton:
	var i := _ids.find(id)
	return buttons[i] if i >= 0 else null


func ids() -> Array[StringName]:
	return _ids.duplicate()


## Taps action `id` (tests; the buttons call this).
func press(id: StringName) -> void:
	var i := _ids.find(id)
	if i >= 0:
		_on_pressed(i)


func _on_pressed(i: int) -> void:
	if i >= _ids.size() or buttons[i].disabled:
		return
	if _asks[i].is_empty():
		chosen.emit(_ids[i])
		return
	pending = _ids[i]
	_ask_i = i
	question.text = _question(i, -1.0)
	confirm_button.text = _confirm_labels[i]
	_refresh()


## Action i's question; with `max_w` > 0, its name shortened until the line fits.
func _question(i: int, max_w: float) -> String:
	if i < 0 or i >= _asks.size():
		return ""
	var fmt := _asks[i]
	var who := _ask_names[i]
	if who.is_empty():
		if max_w > 0.0:
			SocialUi.fit_text(question, fmt, max_w)
			return question.text
		return fmt
	var n := who.length()
	var s := fmt % who
	if max_w <= 0.0:
		return s
	question.text = s
	while n > 0 and question.text_width() > max_w:
		n -= 1
		question.text = fmt % (who.left(n).strip_edges() + SocialUi.ELLIPSIS)
	return question.text


func confirm() -> void:
	if pending == &"":
		return
	var id := pending
	pending = &""
	_refresh()
	chosen.emit(id)


func cancel() -> void:
	pending = &""
	_refresh()


func _refresh() -> void:
	var asking := pending != &""
	for i in MAX_ACTIONS:
		buttons[i].visible = i < _ids.size() and not asking
	question.visible = asking
	confirm_button.visible = asking
	cancel_button.visible = asking
	caption.visible = not caption.text.is_empty()
	title.visible = not _title_full.is_empty()
	sub.visible = not sub.text.is_empty()
	_layout()


## Lays the sheet out in `area`; returns the height used.
func layout(area: Rect2) -> float:
	_area = area
	return _layout()


func _layout() -> float:
	if style == null or _area.size.x <= 0.0:
		return 0.0
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var x := _area.position.x
	var w := _area.size.x
	var y := _area.position.y
	if caption.visible:
		SocialUi.place(caption, Vector2(x, y), caption.get_combined_minimum_size())
		y += caption.get_combined_minimum_size().y
	if title.visible:
		SocialUi.fit_text(title, _title_full, w)
		SocialUi.place(title, Vector2(x, y), title.get_combined_minimum_size())
		y += title.get_combined_minimum_size().y
	if sub.visible:
		SocialUi.fit_text(sub, sub.text, w)
		SocialUi.place(sub, Vector2(x, y), sub.get_combined_minimum_size())
		y += sub.get_combined_minimum_size().y
	if y > _area.position.y:
		y += g
	var bw := (w - g * float(COLUMNS - 1)) / float(COLUMNS)
	if pending != &"":
		question.text = _question(_ask_i, w)
		SocialUi.place(question, Vector2(x, y), question.get_combined_minimum_size())
		y += question.get_combined_minimum_size().y + g
		SocialUi.place(confirm_button, Vector2(x, y), Vector2(bw, th))
		SocialUi.place(cancel_button, Vector2(x + bw + g, y), Vector2(bw, th))
		return y + th - _area.position.y
	for i in _ids.size():
		var col := i % COLUMNS
		var row := floori(float(i) / float(COLUMNS))
		SocialUi.place(buttons[i], Vector2(x + float(col) * (bw + g), y + float(row) * (th + g)), Vector2(bw, th))
	var rows := ceili(float(_ids.size()) / float(COLUMNS))
	return y + float(rows) * (th + g) - g - _area.position.y
