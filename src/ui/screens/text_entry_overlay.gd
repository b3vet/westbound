class_name TextEntryOverlay
extends CanvasLayer
## The text entry overlay: where a SocialField is typed into when an on-screen keyboard
## would cover it. Owner request (2026-10-03): "the on screen keyboard hides the text
## inputs ... use an input box that will be focused and appear somewhere on the top area
## of the screen". Spec: UI, HUD and design system → Design system, Accessibility (text
## size), Safe areas; Controls (touch). docs/SCREENS.md → Social → Text fields.
##
## A dim over everything (it takes every touch: nothing behind can be tapped) and a
## faceted bar at the top of the safe area: the field's prompt, a large LineEdit with the
## field's text (caret at the end; max_length, secret, placeholder and keyboard type
## copied from the field) and CANCEL / DONE. The LineEdit takes the focus as it opens, so
## the OS keyboard opens and types into it. When the OS reports a keyboard height, the bar
## stays above it (bar_top()).
##
## DONE writes the text back (SocialField.take_text: text_changed, as typing would); the
## keyboard's return key does the same and then submits (the field's text_submitted, what
## Enter in the field does). CANCEL, a tap on the dim, Esc, the pad's B and Android back
## close with the field untouched. One per field, made on first use (SocialField.entry).

## The field took the text (DONE / return) or not (cancel). Tests.
signal closed(committed: bool)

## Above every screen (60), the invite toast (61) and the achievement toasts (70).
const LAYER := 90
const TEXT_DONE := "DONE"
const TEXT_CANCEL := "CANCEL"
const CANCEL := &"ui_cancel"

## The field being typed for (null: closed).
var source: SocialField
var style: HudStyle
var tuning: HudTuning

var backdrop: ColorRect
var panel: ScreenPanel
var caption: ScreenText
var edit: LineEdit
var cancel_button: ScreenButton
var done_button: ScreenButton

var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()
## The OS keyboard's height (canvas px) the bar was laid out for.
var _keyboard_px: float = 0.0
## Tests: a keyboard height in canvas px instead of the OS's (negative: the OS's).
var keyboard_override_px: float = -1.0


func _init() -> void:
	name = "TextEntry"
	layer = LAYER
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	backdrop = ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.gui_input.connect(_on_backdrop_input)
	add_child(backdrop)
	panel = ScreenPanel.new()
	panel.name = "Bar"
	panel.edge = ScreenPanel.Edge.ACCENT
	panel.mouse_filter = Control.MOUSE_FILTER_STOP   # a tap on the bar is not a tap on the dim
	backdrop.add_child(panel)
	caption = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	caption.name = "Prompt"
	panel.add_child(caption)
	edit = LineEdit.new()
	edit.name = "Edit"
	edit.context_menu_enabled = false
	edit.select_all_on_focus = false
	edit.virtual_keyboard_enabled = true
	edit.caret_blink = true
	edit.text_submitted.connect(_on_submitted)
	panel.add_child(edit)
	cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, cancel)
	done_button = _button(TEXT_DONE, ScreenButton.Kind.PRIMARY, done)


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 20)
	b.name = label.capitalize()
	b.pressed.connect(action)
	panel.add_child(b)
	return b


func _ready() -> void:
	get_viewport().size_changed.connect(_layout)


func is_open() -> bool:
	return visible and source != null


## Opens over everything for `field`: its text, rules and prompt.
func open_for(field: SocialField, s: HudStyle, t: HudTuning) -> void:
	source = field
	style = s
	tuning = t
	backdrop.color = Color(s.ink, Units.pct_to_frac(t.screen_dim_pct))
	panel.fill_alpha = 1.0 / maxf(s.panel_fill.a, 0.01)   # opaque: nothing reads through the bar
	panel.setup(s)
	caption.setup(s)
	for b: ScreenButton in [cancel_button, done_button]:
		b.setup(s)
		b.size_px = t.font_screen_body_px
	SocialUi.style_edit(edit, s, t)
	edit.max_length = field.max_length
	edit.secret = field.secret
	edit.secret_character = field.secret_character
	edit.virtual_keyboard_type = field.virtual_keyboard_type
	edit.placeholder_text = field.placeholder_text
	edit.text = field.text
	edit.caret_column = edit.text.length()
	_keyboard_px = keyboard_px()
	visible = true
	_layout()
	edit.grab_focus()
	if not edit.is_editing():
		edit.edit()   # editing now: the keys (and the OS keyboard) type here at once
	edit.caret_column = edit.text.length()


## DONE: the field takes the text.
func done() -> void:
	_finish(true, false)


## CANCEL, the dim, Esc, B, Android back: the field keeps its text.
func cancel() -> void:
	_finish(false, false)


func _on_submitted(_t: String) -> void:
	_finish(true, true)


func _finish(commit: bool, submit: bool) -> void:
	if not is_open():
		return
	var f := source
	var typed := edit.text
	source = null
	if edit.has_focus():
		edit.release_focus()
	visible = false
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()
	edit.text = ""
	if is_instance_valid(f):
		f.entry_closed(typed if commit else "", commit, submit)
	closed.emit(commit)


func _on_backdrop_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and is_open():
		backdrop.accept_event()
		cancel()


## Esc and the pad's B (ui_cancel) before the LineEdit or any screen sees them.
func _input(event: InputEvent) -> void:
	if is_open() and event.is_action_pressed(CANCEL):
		get_viewport().set_input_as_handled()
		cancel()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_open():
		cancel()


## The keyboard grows and shrinks as it animates in: the bar follows.
func _process(_delta: float) -> void:
	if not is_open():
		return
	var k := keyboard_px()
	if not is_equal_approx(k, _keyboard_px):
		_keyboard_px = k
		_layout()


## The OS keyboard's height in canvas px (0: none reported).
func keyboard_px() -> float:
	if keyboard_override_px >= 0.0:
		return keyboard_override_px
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return 0.0
	var h := DisplayServer.virtual_keyboard_get_height()
	var win := DisplayServer.window_get_size()
	if h <= 0 or win.y <= 0 or not is_inside_tree():
		return 0.0
	return float(h) * get_viewport().get_visible_rect().size.y / float(win.y)


## Pins the canvas and safe rects (tests, previews); otherwise the viewport and the
## display safe area are used.
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe
	_layout()


## The bar's top: `margin` under the safe area's top, raised (never above the canvas)
## when that would put its bottom under a `keyboard`-px keyboard at the canvas bottom.
static func bar_top(full: Rect2, safe: Rect2, bar_h: float, keyboard: float, margin: float) -> float:
	var top := safe.position.y + margin
	if keyboard > 0.0:
		top = minf(top, full.end.y - keyboard - margin - bar_h)
	return maxf(top, full.position.y)


func _layout() -> void:
	if style == null or tuning == null or not is_inside_tree():
		return
	var full := _pinned_full if _pinned else Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var safe := _pinned_safe if _pinned else HudLayout.canvas_safe_rect(full)
	var t := tuning
	var g := t.spacing_grid_px
	var pad := g * 2.0
	var margin := g * 2.0
	var th := t.touch_target_px
	backdrop.position = full.position
	backdrop.size = full.size
	var w := maxf(safe.size.x - margin * 2.0, 0.0)
	var inner := maxf(w - pad * 2.0, 0.0)
	var source_prompt := ""
	if source != null:
		source_prompt = source.prompt_message if not source.prompt_message.is_empty() else source.placeholder_text
	SocialUi.fit_text(caption, source_prompt.to_upper(), inner)
	var ch := caption.get_combined_minimum_size().y
	var h := pad + ch + g + th + pad
	var top := bar_top(full, safe, h, _keyboard_px, margin)
	panel.position = Vector2(safe.position.x + margin, top) - backdrop.position
	panel.size = Vector2(w, h)
	SocialUi.place(caption, Vector2(pad, pad), Vector2(inner, ch))
	var dw := SocialUi.button_width(done_button, t)
	var cw := SocialUi.button_width(cancel_button, t)
	var y := pad + ch + g
	var ew := maxf(inner - dw - cw - g * 2.0, 0.0)
	SocialUi.place(edit, Vector2(pad, y), Vector2(ew, th))
	SocialUi.place(cancel_button, Vector2(pad + ew + g, y), Vector2(cw, th))
	SocialUi.place(done_button, Vector2(pad + ew + g + cw + g, y), Vector2(dw, th))
