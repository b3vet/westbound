class_name SocialField
extends LineEdit
## A text field for the social screens (friend code, crew name and tag, invite code) that
## works with on-screen keyboards. Spec: UI → Accessibility, Controls (touch); multiplayer
## handoff → Client changes (friends list, crew page). WP N9.2; docs/SCREENS.md → Social.
##
## - Native iOS / Android: LineEdit opens the OS keyboard itself (virtual_keyboard_enabled).
## - Web on a touch screen: Godot's keyboard helper is off in the export
##   (`html/experimental_virtual_keyboard=false`), and even on, it focuses a hidden input
##   a frame after the tap, outside the gesture, which iOS Safari ignores. So a tap opens
##   the browser's own text prompt (`window.prompt`, NetTuning.web_text_prompt) and the
##   answer fills the field; the player then taps the action button as usual.
## - Desktop web and native: typed as usual.
## While the field has focus the run's PlayerInput stops reading keys (typing "P" must not
## unpause); it reads them again on focus loss or when the field hides.

## The prompt filled the field (tests; the field's text_changed also fires).
signal prompted(text: String)

## The run's input hub (null: none to mute).
var hub: PlayerInput
var bridge: NetJsBridge
## -1: automatic (web + touch screen + tuning), 0: never, 1: always (tests).
var prompt_mode: int = -1
## The prompt's question (defaults to the placeholder).
var prompt_message: String = ""
## Prompts shown (tests).
var prompts: int = 0
var net_tuning: NetTuning

var _muted: bool = false


func _init() -> void:
	context_menu_enabled = false
	select_all_on_focus = true
	virtual_keyboard_enabled = true
	caret_blink = true
	bridge = NetJsBridge.new()
	focus_entered.connect(_mute.bind(true))
	focus_exited.connect(_mute.bind(false))


## The tap opens the browser prompt instead of focusing the field.
func uses_prompt() -> bool:
	if prompt_mode >= 0:
		return prompt_mode == 1
	var t := net_tuning if net_tuning != null else NetTuning.load_default()
	return t.web_text_prompt and bridge != null and bridge.available() \
			and DisplayServer.is_touchscreen_available()


func _gui_input(event: InputEvent) -> void:
	if not editable or not uses_prompt():
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if not mb.pressed:
		ask()


## Opens the browser prompt now and takes its answer (nothing on cancel).
func ask() -> void:
	prompts += 1
	var question := prompt_message if not prompt_message.is_empty() else placeholder_text
	var v: Variant = SocialUi.prompt(bridge, question, text)
	if not (v is String):
		return
	var s := (v as String).strip_edges()
	if max_length > 0:
		s = s.left(max_length)
	text = s
	caret_column = s.length()
	text_changed.emit(s)
	prompted.emit(s)
	release_focus()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if has_focus():
			release_focus()
		_mute(false)
	elif what == NOTIFICATION_EXIT_TREE:
		_mute(false)


func _mute(on: bool) -> void:
	if on == _muted:
		return
	_muted = on
	if hub != null and is_instance_valid(hub):
		hub.set_process_input(not on)
