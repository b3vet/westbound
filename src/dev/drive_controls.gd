class_name DriveControls
extends CanvasLayer
## Visible touch buttons for the dev drive scenes (M1 playtest feedback: tap
## zones were hard to find, three-finger taps don't reach the web build).
## Dev-only: scenes add the buttons they need per corner with `add_button()`;
## rows stack inward from each corner inside the display safe area.
## Safe area (WP9.10): ScreenInsets.canvas_safe_rect, the same source as the HUD and
## the menus (WP9.7: the web shell's insets, the phone's minimum left inset for the
## camera cutout), so dev buttons never sit under the Dynamic Island.
## Faceted panels per the design system (chamfered StyleBoxFlat, thin edge),
## no animation when idle.

enum Corner { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT }

## Design-system values (spec UI → Design system). Dev scene, not tuning.
const PANEL := Color(0.067, 0.102, 0.188, 0.82)
const EDGE := Color(0.54, 0.576, 0.678, 0.9)
const TEXT := Color(0.957, 0.969, 1.0)
## Canvas px on the 720 px tall canvas (a phone in landscape: ~106 px per cm). Owner
## M2 feedback: smaller buttons; kept at 44 px tall or more so they stay tappable.
const BEVEL_PX := 7
const SQUARE := Vector2(64.0, 52.0)
const WIDE := Vector2(96.0, 44.0)
const MARGIN_PX := 12.0
const GAP_PX := 8.0
const FONT_SIZE := 19
const SMALL_FONT_SIZE := 15

var _root: Control
## Rows keyed by corner * 16 + row (row 0 = nearest the corner edge).
var _rows: Dictionary = {}


func _init() -> void:
	layer = 50
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)


func _ready() -> void:
	get_viewport().size_changed.connect(_layout)
	_layout.call_deferred()


## Adds a button to `row` of `corner` (a Corner value) (0 = at the corner, 1 = the next row inward).
func add_button(corner: int, row: int, text: String, size: Vector2, on_press: Callable,
		small: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.add_theme_font_size_override(&"font_size", SMALL_FONT_SIZE if small else FONT_SIZE)
	for state: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		b.add_theme_stylebox_override(state, _style(state == &"pressed"))
	for col: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color"]:
		b.add_theme_color_override(col, TEXT)
	b.pressed.connect(on_press)
	_row(corner, row).add_child(b)
	if is_inside_tree():
		_layout.call_deferred()
	return b


## Adds a read-only label to a row (e.g. the speed readout).
func add_label(corner: int, row: int, min_width: float) -> Label:
	var l := Label.new()
	l.custom_minimum_size = Vector2(min_width, SQUARE.y)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override(&"font_size", FONT_SIZE)
	l.add_theme_color_override(&"font_color", TEXT)
	l.add_theme_color_override(&"font_outline_color", Color.BLACK)
	l.add_theme_constant_override(&"outline_size", 4)
	_row(corner, row).add_child(l)
	if is_inside_tree():
		_layout.call_deferred()
	return l


## Shows or hides every row of `corner` from `min_row` inward (hidden rows take no
## space and cost no draw calls).
func set_rows_visible(corner: int, min_row: int, on: bool) -> void:
	for key: int in _rows:
		if (key >> 4) == corner and (key & 15) >= min_row:   # key = corner * 16 + row
			(_rows[key] as HBoxContainer).visible = on
	if is_inside_tree():
		_layout.call_deferred()


## Set a button's or label's text only when it changed (HUD update rule).
static func set_text(control: Control, text: String) -> void:
	if control is Button and (control as Button).text != text:
		(control as Button).text = text
	elif control is Label and (control as Label).text != text:
		(control as Label).text = text


func _row(corner: int, row: int) -> HBoxContainer:
	var key := corner * 16 + row
	if _rows.has(key):
		return _rows[key]
	var box := HBoxContainer.new()
	box.add_theme_constant_override(&"separation", int(GAP_PX))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_meta(&"corner", corner)
	_root.add_child(box)
	_rows[key] = box
	return box


func _style(pressed: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL.lightened(0.25) if pressed else PANEL
	s.border_color = EDGE
	s.set_border_width_all(2)
	s.set_corner_radius_all(BEVEL_PX)
	s.corner_detail = 1
	return s


## The display safe area in canvas pixels (ScreenInsets: notch, camera cutout, rounded
## corners; the whole canvas headless).
func safe_rect() -> Rect2:
	return ScreenInsets.canvas_safe_rect(get_viewport().get_visible_rect())


## Place each row in its corner inside the display safe area, stacking inward.
func _layout() -> void:
	layout_in(safe_rect())


## Place each row in its corner inside `safe` (canvas px), stacking inward.
func layout_in(safe: Rect2) -> void:
	var stacked_by_corner := {}
	var keys := _rows.keys()
	keys.sort()
	for key: int in keys:
		var box: HBoxContainer = _rows[key]
		if not box.visible:
			continue
		box.reset_size()
		var sz := box.get_combined_minimum_size()
		var corner: int = box.get_meta(&"corner")
		var stacked: float = stacked_by_corner.get(corner, 0.0)
		var x := safe.position.x + MARGIN_PX
		if corner == Corner.TOP_RIGHT or corner == Corner.BOTTOM_RIGHT:
			x = safe.end.x - MARGIN_PX - sz.x
		var y := safe.position.y + MARGIN_PX + stacked
		if corner == Corner.BOTTOM_LEFT or corner == Corner.BOTTOM_RIGHT:
			y = safe.end.y - MARGIN_PX - stacked - sz.y
		box.position = Vector2(x, y)
		stacked_by_corner[corner] = stacked + sz.y + GAP_PX
