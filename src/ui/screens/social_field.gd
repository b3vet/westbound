class_name SocialField
extends LineEdit
## A text field for the social screens (friend code, crew name and tag, invite code, the
## room and party code, the rename field) that works with on-screen keyboards. Spec: UI →
## Accessibility, Controls (touch); multiplayer handoff → Client changes (friends list,
## crew page). WP N9.2; docs/SCREENS.md → Social → Text fields.
##
## How a tap types, first that applies:
## - Web on a touch screen (`uses_prompt()`): Godot's keyboard helper is off in the
##   export (`html/experimental_virtual_keyboard=false`), and even on, it focuses a
##   hidden input a frame after the tap, outside the gesture, which iOS Safari ignores.
##   So a tap opens the browser's own text prompt (`window.prompt`,
##   NetTuning.web_text_prompt) and the answer fills the field; the player then taps the
##   action button as usual.
## - An OS on-screen keyboard (`uses_overlay()`: a touch screen and DisplayServer's
##   virtual keyboard, i.e. native iOS / Android; NetTuning.text_entry_overlay): the
##   keyboard covers the lower half of a landscape phone, where most fields sit. So
##   focusing the field (a tap, or any other focus) opens the TextEntryOverlay instead: a
##   bar at the top of the screen with its own LineEdit, which the keyboard types into.
##   DONE writes the text back here (text_changed); the keyboard's return key also
##   submits (text_submitted, as Enter here does); cancel leaves the field as it was. In
##   that mode this field never opens the keyboard itself.
## - Otherwise (desktop, web without a touch screen): typed in place.
## While the field has focus, or its overlay is open, the run's PlayerInput stops reading
## keys (typing "P" must not unpause); it reads them again on focus loss, when the overlay
## closes or when the field hides.

## The prompt filled the field (tests; the field's text_changed also fires).
signal prompted(text: String)

## The run's input hub (null: none to mute).
var hub: PlayerInput
var bridge: NetJsBridge
## -1: automatic (web + touch screen + tuning), 0: never, 1: always (tests).
var prompt_mode: int = -1:
	set(value):
		prompt_mode = value
		_sync_keyboard()
## The text entry overlay: -1 automatic (on-screen keyboard + touch screen + tuning), 0:
## never (typed in place), 1: always (tests). The web prompt wins over it.
var entry_mode: int = -1:
	set(value):
		entry_mode = value
		_sync_keyboard()
## The prompt's question, also the overlay's caption (defaults to the placeholder).
var prompt_message: String = ""
## Prompts shown (tests).
var prompts: int = 0
var net_tuning: NetTuning:
	set(value):
		net_tuning = value
		_sync_keyboard()
## The look the overlay is drawn with (SocialUi.style_edit sets them; null: the theme at
## the text-size setting).
var style: HudStyle
var hud_tuning: HudTuning
## The overlay (made on first use) and how often it opened (tests).
var entry: TextEntryOverlay
var entries: int = 0

var _focus_muted: bool = false
var _entry_open: bool = false
var _muted: bool = false


func _init() -> void:
	context_menu_enabled = false
	select_all_on_focus = true
	virtual_keyboard_enabled = true
	caret_blink = true
	bridge = NetJsBridge.new()
	focus_entered.connect(_on_focus.bind(true))
	focus_exited.connect(_on_focus.bind(false))
	_sync_keyboard()


## The tap opens the browser prompt instead of focusing the field.
func uses_prompt() -> bool:
	if prompt_mode >= 0:
		return prompt_mode == 1
	return _net().web_text_prompt and bridge != null and bridge.available() \
			and DisplayServer.is_touchscreen_available()


## Focusing the field opens the text entry overlay (see the class comment).
func uses_overlay() -> bool:
	if uses_prompt():
		return false
	if entry_mode >= 0:
		return entry_mode == 1
	return _net().text_entry_overlay and DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD) \
			and DisplayServer.is_touchscreen_available()


func _net() -> NetTuning:
	return net_tuning if net_tuning != null else NetTuning.load_default()


## In overlay mode only the overlay's own field opens the OS keyboard.
func _sync_keyboard() -> void:
	virtual_keyboard_enabled = not uses_overlay()


func _gui_input(event: InputEvent) -> void:
	if not editable:
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if uses_prompt():
		accept_event()
		if not mb.pressed:
			ask()
	elif uses_overlay():
		accept_event()   # the focus opens the overlay: no caret or selection here


## Opens the browser prompt now and takes its answer (nothing on cancel).
func ask() -> void:
	prompts += 1
	var question := prompt_message if not prompt_message.is_empty() else placeholder_text
	var v: Variant = SocialUi.prompt(bridge, question, text)
	if not (v is String):
		return
	take_text(v as String)
	prompted.emit(text)
	release_focus()


## Fills the field with `s` as the prompt and the overlay answer: trimmed, cut to
## max_length, caret at the end, then text_changed (as typing would).
func take_text(s: String) -> void:
	var v := s.strip_edges()
	if max_length > 0:
		v = v.left(max_length)
	text = v
	caret_column = v.length()
	text_changed.emit(v)


## Opens the text entry overlay for this field now (focusing the field does it in
## overlay mode). False when the field can't be typed into or it is open already.
func open_entry() -> bool:
	if not editable or not is_visible_in_tree() or _entry_open:
		return false
	if entry == null:
		entry = TextEntryOverlay.new()
		add_child(entry, false, Node.INTERNAL_MODE_BACK)
	entries += 1
	_entry_open = true
	var t := hud_tuning if hud_tuning != null else Tuning.load_default().hud
	var s := style
	if s == null:
		s = HudStyle.new()
		s.setup(UiTheme.load_theme(), t, t.clamp_text_scale(float(Settings.get_value(&"text_scale"))))
	entry.open_for(self, s, t)
	_apply_mute()
	return true


func is_entry_open() -> bool:
	return _entry_open


## The overlay closed (TextEntryOverlay calls it): DONE and return take `typed`, return
## also submits; a cancel changes nothing.
func entry_closed(typed: String, commit: bool, submit: bool) -> void:
	_entry_open = false
	_apply_mute()
	if commit:
		take_text(typed)
		if submit:
			text_submitted.emit(text)


func _on_focus(on: bool) -> void:
	_focus_muted = on
	_apply_mute()
	if on and uses_overlay():
		_open_from_focus.call_deferred()


## The focus moves on to the overlay's field (deferred: never inside a focus change).
func _open_from_focus() -> void:
	if has_focus() and uses_overlay():
		open_entry()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if has_focus():
			release_focus()
		if _entry_open and entry != null:
			entry.cancel()
		_focus_muted = false
		_apply_mute()
	elif what == NOTIFICATION_EXIT_TREE:
		if _entry_open and entry != null:
			entry.cancel()
		_focus_muted = false
		_entry_open = false
		_apply_mute()


func _apply_mute() -> void:
	var on := _focus_muted or _entry_open
	if on == _muted:
		return
	_muted = on
	if hub != null and is_instance_valid(hub):
		hub.set_process_input(not on)
