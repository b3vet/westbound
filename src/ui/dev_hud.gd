extends CanvasLayer
## Dev HUD overlay. Spec: Tech stack → Testing (dev HUD: fps, frame time, draw
## calls, primitives, render scale, active vehicles, sim time per tick, thermal
## state; toggled by a three-finger tap or the backtick key) and Performance
## budget (HUD labels update only when their value changes; no blur).
##
## Reads engine monitors and `DevStats`; no system depends on it. Hidden by
## default in release builds. While hidden it does not process at all; only
## `_input` stays live to catch the toggle gesture.
##
## Sits on the left edge, vertically centred: the gameplay HUD owns all four
## corners and the top-centre, and the middle third stays clear for traffic.
##
## COPY (owner request, M2) puts a DevReport (build, device, renderer, scene,
## these rows, all DevStats values) on the clipboard; on web it opens an HTML
## panel with a native Copy button because iOS Safari blocks other paths.

## Refresh the readouts at most this often (4 Hz).
const REFRESH_INTERVAL_USEC := 250_000
## "Worst frame" covers the last full one-second window plus the current one.
const WORST_WINDOW_USEC := 1_000_000
## Three touches that all went down within this window toggle the HUD.
const TAP_WINDOW_MSEC := 300
const TAP_FINGERS := 3
## Touch indices tracked for the gesture (more are ignored).
const MAX_TOUCHES := 10
## Gap to the safe-area edge, in canvas pixels (8 px spacing grid).
const EDGE_MARGIN := 8.0
const USEC_PER_MSEC := 1000.0
const PLACEHOLDER := "-"
## Touch-sized COPY button (canvas px) and how long "COPIED" shows.
const COPY_BUTTON_HEIGHT := 44.0
const COPIED_FLASH_S := 1.5

const COLOR_TEXT := Color("#f4f7ff")
const COLOR_MUTED := Color("#8a93ad")
const COLOR_HOT := Color("#ff5a4d")

enum Row { FPS, FRAME, DRAWS, TRIS, SCALE, VEHICLES, SIM, THERMAL, QUALITY }
const ROW_NAMES: PackedStringArray = [
	"fps", "frame", "draws", "tris", "3d scale", "vehicles", "sim tick", "thermal", "quality",
]

## Start visible in debug builds (release builds always start hidden).
@export var start_visible_in_debug: bool = true

@onready var _panel: PanelContainer = $Panel
@onready var _grid: GridContainer = $Panel/Grid

var _value_labels: Array[Label] = []
var _copy_button: Button
var _hot: PackedByteArray = PackedByteArray()

var _last_frame_usec: int = 0
var _frame_sum_usec: int = 0
var _frame_count: int = 0
var _worst_window_usec: int = 0
var _worst_prev_usec: int = 0
var _window_start_usec: int = 0
var _last_refresh_usec: int = 0

## Press time per touch index, or -1 while that finger is up.
var _touch_down_msec: PackedInt64Array = PackedInt64Array()
var _tap_armed: bool = true


func _ready() -> void:
	_touch_down_msec.resize(MAX_TOUCHES)
	_touch_down_msec.fill(-1)
	_build_rows()
	_build_copy_button()
	get_viewport().size_changed.connect(_update_safe_area)
	_update_safe_area()
	set_hud_visible(OS.is_debug_build() and start_visible_in_debug)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo \
				and (key.physical_keycode == KEY_QUOTELEFT or key.keycode == KEY_QUOTELEFT):
			toggle()
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if handle_touch(touch.index, touch.pressed and not touch.canceled, Time.get_ticks_msec()):
			toggle()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_frame_usec > 0:
		var dt := now - _last_frame_usec
		_frame_sum_usec += dt
		_frame_count += 1
		_worst_window_usec = maxi(_worst_window_usec, dt)
	_last_frame_usec = now
	if now - _window_start_usec >= WORST_WINDOW_USEC:
		_worst_prev_usec = _worst_window_usec
		_worst_window_usec = 0
		_window_start_usec = now
	if now - _last_refresh_usec >= REFRESH_INTERVAL_USEC:
		refresh()


func is_hud_visible() -> bool:
	return visible


func toggle() -> void:
	set_hud_visible(not visible)


func set_hud_visible(on: bool) -> void:
	visible = on
	set_process(on)
	if on:
		var now := Time.get_ticks_usec()
		_last_frame_usec = 0
		_frame_sum_usec = 0
		_frame_count = 0
		_worst_window_usec = 0
		_worst_prev_usec = 0
		_window_start_usec = now
		refresh()


## Feed one touch press/release. Returns true when it completes a
## three-finger tap (the caller toggles). Exposed for tests.
func handle_touch(index: int, pressed: bool, now_msec: int) -> bool:
	if index < 0 or index >= MAX_TOUCHES:
		return false
	if not pressed:
		_touch_down_msec[index] = -1
		_tap_armed = true
		return false
	_touch_down_msec[index] = now_msec
	if not _tap_armed:
		return false
	var recent := 0
	for t in _touch_down_msec:
		if t >= 0 and now_msec - t <= TAP_WINDOW_MSEC:
			recent += 1
	if recent >= TAP_FINGERS:
		_tap_armed = false
		return true
	return false


## Re-read every value and update the labels whose text changed.
func refresh() -> void:
	_last_refresh_usec = Time.get_ticks_usec()

	var fps := int(Performance.get_monitor(Performance.TIME_FPS))
	var cap := Engine.max_fps
	_set_row(Row.FPS, "%d  cap %d" % [fps, cap] if cap > 0 else "%d" % fps)

	if _frame_count > 0:
		var avg_ms := float(_frame_sum_usec) / float(_frame_count) / USEC_PER_MSEC
		var worst_ms := float(maxi(_worst_prev_usec, _worst_window_usec)) / USEC_PER_MSEC
		_set_row(Row.FRAME, "%.1f ms  worst %.1f" % [avg_ms, worst_ms])
		_frame_sum_usec = 0
		_frame_count = 0
	elif _value_labels[Row.FRAME].text.is_empty():
		_set_row(Row.FRAME, PLACEHOLDER)

	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var draw_budget: int = DevStats.get_value(DevStats.DRAW_CALL_BUDGET, 0)
	if draw_budget > 0:
		_set_row(Row.DRAWS, "%d / %d" % [draws, draw_budget])
	else:
		_set_row(Row.DRAWS, "%d" % draws)
	_set_hot(Row.DRAWS, draw_budget > 0 and draws > draw_budget)

	var tris := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var tri_budget: int = DevStats.get_value(DevStats.TRIANGLE_BUDGET, 0)
	if tri_budget > 0:
		_set_row(Row.TRIS, "%s / %s" % [_count(tris), _count(tri_budget)])
	else:
		_set_row(Row.TRIS, _count(tris))
	_set_hot(Row.TRIS, tri_budget > 0 and tris > tri_budget)

	_set_row(Row.SCALE, "%.2f" % get_viewport().scaling_3d_scale)

	var vehicles: Variant = DevStats.get_value(DevStats.VEHICLES)
	_set_row(Row.VEHICLES, PLACEHOLDER if vehicles == null else str(vehicles))

	if DevStats.sim_tick_sample_count() > 0:
		_set_row(Row.SIM, "%.2f ms  max %.2f" % [
			DevStats.get_sim_tick_avg_usec() / USEC_PER_MSEC,
			float(DevStats.get_sim_tick_max_usec()) / USEC_PER_MSEC])
	else:
		_set_row(Row.SIM, PLACEHOLDER)

	var thermal: Variant = DevStats.get_value(DevStats.THERMAL)
	_set_row(Row.THERMAL, PLACEHOLDER if thermal == null else String(thermal))
	_set_hot(Row.THERMAL, thermal == Thermal.SERIOUS or thermal == Thermal.CRITICAL)

	var tier: Variant = DevStats.get_value(DevStats.QUALITY_TIER)
	var rung: int = DevStats.get_value(DevStats.GOVERNOR_RUNG, 0)
	_set_row(Row.QUALITY, PLACEHOLDER if tier == null else "%s  gov %d" % [tier, rung])
	_set_hot(Row.QUALITY, rung > 0)


## The rows as [[name, value], ...], refreshed now (dev report, tests).
func rows_snapshot() -> Array:
	refresh()
	var out: Array = []
	for i in ROW_NAMES.size():
		out.append([ROW_NAMES[i], _value_labels[i].text])
	return out


## Full plain-text report for playtest feedback.
func report_text() -> String:
	var scene := get_tree().current_scene
	return DevReport.compose(rows_snapshot(), scene.scene_file_path if scene != null else "?")


func copy_report() -> void:
	var copied := DevReport.share(report_text())
	if copied:
		_copy_button.text = "COPIED"
		get_tree().create_timer(COPIED_FLASH_S).timeout.connect(func() -> void: _copy_button.text = "COPY")


## Current text of a readout (tests).
func get_row_text(row: Row) -> String:
	return _value_labels[row].text


func _set_row(row: Row, text: String) -> void:
	var label := _value_labels[row]
	if label.text != text:
		label.text = text


func _set_hot(row: Row, hot: bool) -> void:
	var flag := 1 if hot else 0
	if _hot[row] == flag:
		return
	_hot[row] = flag
	_value_labels[row].add_theme_color_override(&"font_color", COLOR_HOT if hot else COLOR_TEXT)


## 12345 -> "12.3k"; below 1000 as is.
static func _count(n: int) -> String:
	if n < 1000:
		return "%d" % n
	if n % 1000 == 0:
		return "%.0fk" % (float(n) / 1000.0)
	return "%.1fk" % (float(n) / 1000.0)


func _build_rows() -> void:
	_hot.resize(ROW_NAMES.size())
	_hot.fill(0)
	for row_name in ROW_NAMES:
		var name_label := Label.new()
		name_label.text = row_name
		name_label.add_theme_color_override(&"font_color", COLOR_MUTED)
		_grid.add_child(name_label)
		var value := Label.new()
		value.add_theme_color_override(&"font_color", COLOR_TEXT)
		_grid.add_child(value)
		_value_labels.append(value)


func _build_copy_button() -> void:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.remove_child(_grid)
	box.add_child(_grid)
	_panel.add_child(box)
	_copy_button = Button.new()
	_copy_button.text = "COPY"
	_copy_button.focus_mode = Control.FOCUS_NONE
	_copy_button.custom_minimum_size = Vector2(0.0, COPY_BUTTON_HEIGHT)
	_copy_button.pressed.connect(copy_report)
	box.add_child(_copy_button)


## Keep the panel inside the display safe area (notch, rounded corners).
func _update_safe_area() -> void:
	var inset := 0.0
	if DisplayServer.get_name() != "headless":
		var safe := DisplayServer.get_display_safe_area()
		var win_pos := DisplayServer.window_get_position()
		var win_size := DisplayServer.window_get_size()
		var canvas_size := get_viewport().get_visible_rect().size
		if safe.size.x > 0 and win_size.x > 0 and canvas_size.x > 0.0:
			var px := maxf(0.0, float(safe.position.x - win_pos.x))
			inset = px * canvas_size.x / float(win_size.x)
	_panel.offset_left = inset + EDGE_MARGIN
	_panel.offset_right = _panel.offset_left
