class_name DriveControls
extends CanvasLayer
## Visible touch buttons for the dev drive scenes (M1 playtest feedback: tap
## zones were hard to find, three-finger taps don't reach the web build).
## Dev-only; the real controls overlay (WP2.2) replaces the driving buttons.
##
## Layout (safe-area aware): lane < > bottom-left, speed - + bottom-right,
## CAM and HUD top-right. Faceted panels per the design system (chamfered
## StyleBoxFlat, thin edge), no animation when idle.

signal lane_left
signal lane_right
signal speed_down
signal speed_up
signal camera_cycle
signal hud_toggle

## Design-system values (spec UI → Design system). Dev scene, not tuning.
const PANEL := Color(0.067, 0.102, 0.188, 0.82)
const EDGE := Color(0.54, 0.576, 0.678, 0.9)
const TEXT := Color(0.957, 0.969, 1.0)
const BEVEL_PX := 7
const BUTTON_SIZE := Vector2(76.0, 60.0)
const WIDE_SIZE := Vector2(116.0, 48.0)
## Fits "CAM OVERHEAD", the longest mode label, so the row never resizes.
const CAM_SIZE := Vector2(190.0, 48.0)
const MARGIN_PX := 16.0
const GAP_PX := 10.0
const FONT_SIZE := 22

var _speed_label: Label
var _cam_button: Button
var _root: Control


func _ready() -> void:
	layer = 50
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var bottom_left := _row(Control.PRESET_BOTTOM_LEFT)
	_add(bottom_left, "<", BUTTON_SIZE, lane_left.emit)
	_add(bottom_left, ">", BUTTON_SIZE, lane_right.emit)

	var bottom_right := _row(Control.PRESET_BOTTOM_RIGHT)
	_add(bottom_right, "-", BUTTON_SIZE, speed_down.emit)
	_speed_label = Label.new()
	_speed_label.custom_minimum_size = Vector2(110.0, BUTTON_SIZE.y)
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_speed_label.add_theme_font_size_override(&"font_size", FONT_SIZE)
	_speed_label.add_theme_color_override(&"font_color", TEXT)
	_speed_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_speed_label.add_theme_constant_override(&"outline_size", 4)
	bottom_right.add_child(_speed_label)
	_add(bottom_right, "+", BUTTON_SIZE, speed_up.emit)

	var top_right := _row(Control.PRESET_TOP_RIGHT)
	_cam_button = _add(top_right, "CAM", CAM_SIZE, camera_cycle.emit)
	_add(top_right, "HUD", WIDE_SIZE, hud_toggle.emit)

	get_viewport().size_changed.connect(_layout)
	_layout()


func set_speed_text(text: String) -> void:
	if _speed_label.text != text:
		_speed_label.text = text


func set_camera_text(mode: String) -> void:
	var text := "CAM %s" % mode.to_upper()
	if _cam_button.text != text:
		_cam_button.text = text


func _row(preset: Control.LayoutPreset) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", int(GAP_PX))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_meta(&"preset", preset)
	_root.add_child(row)
	return row


func _add(row: HBoxContainer, text: String, size: Vector2, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override(&"font_size", FONT_SIZE)
	for state: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		b.add_theme_stylebox_override(state, _style(state == &"pressed"))
	for col: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color"]:
		b.add_theme_color_override(col, TEXT)
	b.pressed.connect(on_press)
	row.add_child(b)
	return b


func _style(pressed: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL.lightened(0.25) if pressed else PANEL
	s.border_color = EDGE
	s.set_border_width_all(2)
	s.set_corner_radius_all(BEVEL_PX)
	s.corner_detail = 1
	return s


## Place each row in its corner inside the display safe area.
func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	var safe := Rect2(Vector2.ZERO, vp)
	var screen_safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if screen_safe.size.x > 0 and win.x > 0:
		var k := vp / Vector2(win)
		safe = Rect2(Vector2(screen_safe.position) * k, Vector2(screen_safe.size) * k)
	for row: HBoxContainer in _root.get_children().filter(func(c: Node) -> bool: return c is HBoxContainer):
		row.reset_size()
		var sz := row.get_combined_minimum_size()
		var preset: int = row.get_meta(&"preset")
		var x := safe.position.x + MARGIN_PX
		var y := safe.position.y + MARGIN_PX
		if preset == Control.PRESET_BOTTOM_RIGHT or preset == Control.PRESET_TOP_RIGHT:
			x = safe.end.x - MARGIN_PX - sz.x
		if preset == Control.PRESET_BOTTOM_LEFT or preset == Control.PRESET_BOTTOM_RIGHT:
			y = safe.end.y - MARGIN_PX - sz.y
		row.position = Vector2(x, y)
