class_name SettingsPanel
extends Control
## The compact in-run settings (from the pause menu). Spec: UI → Screens ("Settings:
## controls (steering mode, throttle mode, sensitivity, ..., left-handed) ... haptics,
## units, ... reduced motion"); Accessibility (text size 100% / 125%, reduced motion);
## Controls → Settings; plan D10 (drag visual, controls size). docs/SCREENS.md → Settings.
##
## Two columns of rows; each row is a label and a segmented choice of big OPTION
## buttons (touch_target_px tall). A press writes the value straight into Settings
## (Settings.set_value); the rows follow Events.settings_changed, so a change made
## elsewhere (the dev rows, the keyboard) shows at once. Only keys in Settings.DEFAULTS
## appear. Gyro (TILT) is disabled where the platform has no tilt
## (PlayerInput.is_gyro_supported()).
##
## WP7A: two pages, GAME (the rows above) and AUDIO (a volume row per bus: Master,
## Music, SFX, Engine, UI, in AudioTuning.volume_steps, and the SOUND on/muted row),
## switched by two tabs in the free span of the screen's header row (between the
## siblings drawn there, e.g. the title and ACCOUNT / DONE). Only the shown page's rows
## are visible and laid out.

signal changed(key: StringName)

const TEXT_GYRO := "TILT"
const PCT_FMT := "%d%%"
const PAGE_GAME := 0
const PAGE_AUDIO := 1
const PAGE_CAPTIONS: Array[String] = ["GAME", "AUDIO"]

## key, label, values, option labels ([] = percent labels from the values).
var rows: Array[Row] = []
var style: HudStyle
var tuning: HudTuning
## The input hub (gyro support); null = assume supported.
var hub: PlayerInput
## Settings writes made from this panel (tests).
var writes: int = 0
## The page shown (PAGE_GAME / PAGE_AUDIO) and its tabs.
var page: int = PAGE_GAME
var tabs: Array[ScreenButton] = []
var _building_page: int = PAGE_GAME
var _last_area := Rect2()


class Row:
	extends RefCounted
	var key: StringName
	var label: String
	var values: Array = []
	var captions: PackedStringArray = []
	var title: ScreenText
	var buttons: Array[ScreenButton] = []
	var page: int = 0


func _init() -> void:
	name = "Settings"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


## Builds the rows (tuning gives the size, sensitivity and text-size choices).
func build(t: HudTuning) -> void:
	tuning = t
	for r in rows:
		r.title.queue_free()
		for b in r.buttons:
			b.queue_free()
	rows.clear()
	for b in tabs:
		b.queue_free()
	tabs.clear()
	for i in PAGE_CAPTIONS.size():
		var tab := ScreenButton.make(PAGE_CAPTIONS[i], ScreenButton.Kind.OPTION, 20)
		tab.name = "page_%d" % i
		tab.pressed.connect(show_page.bind(i))
		add_child(tab)
		tabs.append(tab)
	_building_page = PAGE_GAME
	_add(&"steering_mode", "STEERING", [&"drag", &"gyro"], ["DRAG", TEXT_GYRO])
	_add(&"throttle_mode", "THROTTLE", [&"auto", &"manual"], ["AUTO", "MANUAL"])
	_add(&"left_handed", "HAND", [false, true], ["RIGHT", "LEFT"])
	_add(&"drag_visual", "DRAG LOOK", [&"ring", &"wheel"], ["RING", "WHEEL"])
	_add(&"controls_scale", "CONTROLS SIZE", Array(t.settings_controls_scales), [])
	_add(&"steer_sensitivity", "SENSITIVITY", Array(t.settings_sensitivities), [])
	_add(&"units", "UNITS", [&"kmh", &"mph"], ["KM/H", "MPH"])
	_add(&"text_scale", "TEXT SIZE", Array(t.text_scales), [])
	_add(&"reduced_motion", "REDUCED MOTION", [false, true], ["OFF", "ON"])
	_add(&"haptics", "HAPTICS", [true, false], ["ON", "OFF"])
	_building_page = PAGE_AUDIO
	var steps := Array(AudioTuning.resolve().volume_steps)
	var labels: Array[String] = ["MASTER", "MUSIC", "EFFECTS", "ENGINE", "INTERFACE"]
	for i in AudioBuses.VOLUME_KEYS.size():
		_add(AudioBuses.VOLUME_KEYS[i], labels[i], steps, ["OFF"] if not steps.is_empty() and float(steps[0]) <= 0.0 else [])
	_add(AudioBuses.MUTE_KEY, "SOUND", [false, true], ["ON", "MUTED"])
	refresh()


func _add(key: StringName, label: String, values: Array, captions: Array) -> void:
	if not Settings.DEFAULTS.has(key):
		return
	var r := Row.new()
	r.key = key
	r.label = label
	r.page = _building_page
	r.values = values
	for i in values.size():
		if i < captions.size():
			r.captions.append(String(captions[i]))
		else:
			r.captions.append(PCT_FMT % roundi(float(values[i]) * Units.PCT))
	r.title = ScreenText.make(label, ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	add_child(r.title)
	for i in values.size():
		var b := ScreenButton.make(r.captions[i], ScreenButton.Kind.OPTION, 20)
		b.name = "%s_%d" % [key, i]
		b.pressed.connect(_choose.bind(r, i))
		add_child(b)
		r.buttons.append(b)
	rows.append(r)


func setup(s: HudStyle) -> void:
	style = s
	for b in tabs:
		b.setup(s)
	for r in rows:
		r.title.setup(s)
		for b in r.buttons:
			b.setup(s)


func _enter_tree() -> void:
	if not Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)


func _on_setting_changed(_key: StringName) -> void:
	refresh()


## The row for `key` (null if absent).
func row(key: StringName) -> Row:
	for r in rows:
		if r.key == key:
			return r
	return null


## The option button for `key` = values[index] (tests).
func option(key: StringName, index: int) -> ScreenButton:
	var r := row(key)
	return r.buttons[index] if r != null and index < r.buttons.size() else null


## Which option of `key` is selected (-1 = the current value is none of them).
func selected_index(key: StringName) -> int:
	var r := row(key)
	if r == null:
		return -1
	for i in r.buttons.size():
		if r.buttons[i].selected:
			return i
	return -1


## Shows a page (GAME / AUDIO) and lays it out again in the last area.
func show_page(p: int) -> void:
	page = clampi(p, PAGE_GAME, PAGE_CAPTIONS.size() - 1)
	refresh()
	if _last_area.size != Vector2.ZERO:
		layout(_last_area)


func refresh() -> void:
	for i in tabs.size():
		tabs[i].selected = i == page
	for r in rows:
		var current: Variant = Settings.get_value(r.key)
		var best := _closest(r.values, current)
		for i in r.buttons.size():
			r.buttons[i].selected = i == best
		if r.key == &"steering_mode" and r.buttons.size() > 1:
			var gyro_ok := hub == null or hub.is_gyro_supported()
			var gb := r.buttons[1]
			gb.disabled = not gyro_ok and not gb.selected
			gb.note = "" if gyro_ok else "N/A"


## Index of the value equal to `current` (floats: the nearest one).
static func _closest(values: Array, current: Variant) -> int:
	var best := -1
	var best_d := INF
	for i in values.size():
		var v: Variant = values[i]
		if typeof(v) == TYPE_FLOAT and (typeof(current) == TYPE_FLOAT or typeof(current) == TYPE_INT):
			var d := absf(float(v) - float(current))
			if d < best_d:
				best_d = d
				best = i
		elif typeof(v) == typeof(current) and v == current:
			return i
		elif (typeof(v) == TYPE_STRING_NAME or typeof(v) == TYPE_STRING) and String(v) == str(current):
			return i
	return best


func _choose(r: Row, index: int) -> void:
	var v: Variant = r.values[index]
	writes += 1
	Settings.set_value(r.key, v)
	refresh()
	changed.emit(r.key)


## Lays the shown page's rows out in two columns inside `area` (panel-local px) and
## the page tabs in the header row above it. Returns the height used.
func layout(area: Rect2) -> float:
	if style == null or tuning == null:
		return 0.0
	_last_area = area
	var g := tuning.spacing_grid_px
	var col_gap := g * 2.0
	var cols := 2
	var shown := 0
	for r in rows:
		var on := r.page == page
		r.title.visible = on
		for b in r.buttons:
			b.visible = on
		if on:
			shown += 1
	var per_col := maxi(ceili(float(shown) / float(cols)), 1)
	var cw := (area.size.x - col_gap * float(cols - 1)) / float(cols)
	var rh := tuning.touch_target_px
	var lw := tuning.settings_label_width_px * style.ts
	var i := 0
	for r in rows:
		if r.page != page:
			continue
		@warning_ignore("integer_division")
		var c := i / per_col
		var k := i % per_col
		i += 1
		var x := area.position.x + float(c) * (cw + col_gap)
		var y := area.position.y + float(k) * (rh + g)
		var ts := r.title.get_combined_minimum_size()
		r.title.position = Vector2(x, y + (rh - ts.y) * 0.5)
		r.title.size = Vector2(lw - g, ts.y)
		var n := r.buttons.size()
		var bw := (cw - lw - g * float(n - 1)) / float(n)
		for j in n:
			var b := r.buttons[j]
			b.position = Vector2(x + lw + float(j) * (bw + g), y)
			b.size = Vector2(bw, rh)
	_layout_tabs(area, rh, g)
	return float(per_col) * rh + float(per_col - 1) * g


## The tabs: centred in the widest free span of the header row (the band of height
## `rh` ending 2 grid steps above `area`), clear of the visible siblings drawn there.
func _layout_tabs(area: Rect2, rh: float, g: float) -> void:
	if tabs.is_empty():
		return
	var band_y := area.position.y - g * 2.0 - rh
	var lo := area.position.x
	var hi := area.end.x
	# Free spans between sibling controls in the band (panel and host share one space).
	var best_lo := lo
	var best_hi := lo
	var cursor := lo
	var edges := PackedFloat64Array()
	var parent := get_parent()
	if parent != null:
		for n in parent.get_children():
			var c := n as Control
			if c == null or c == self or not c.visible:
				continue
			var rc := Rect2(c.position, c.size)
			if rc.end.y <= band_y or rc.position.y >= band_y + rh or rc.size.x >= area.size.x:
				continue
			edges.append(rc.position.x)
			edges.append(rc.end.x)
	# Sort the obstacle spans by start (few items: insertion sort on pairs).
	@warning_ignore("integer_division")
	var spans := edges.size() / 2
	for a in range(1, spans):
		var j := a
		while j > 0 and edges[(j - 1) * 2] > edges[j * 2]:
			var s0 := edges[j * 2]
			var s1 := edges[j * 2 + 1]
			edges[j * 2] = edges[(j - 1) * 2]
			edges[j * 2 + 1] = edges[(j - 1) * 2 + 1]
			edges[(j - 1) * 2] = s0
			edges[(j - 1) * 2 + 1] = s1
			j -= 1
	for a in spans:
		var start := edges[a * 2] - g * 2.0
		if start - cursor > best_hi - best_lo:
			best_lo = cursor
			best_hi = start
		cursor = maxf(cursor, edges[a * 2 + 1] + g * 2.0)
	if hi - cursor > best_hi - best_lo:
		best_lo = cursor
		best_hi = hi
	var n_tabs := tabs.size()
	var want := tuning.settings_label_width_px * style.ts
	var tw := minf(want, (best_hi - best_lo - g * float(n_tabs - 1)) / float(n_tabs))
	var total := tw * float(n_tabs) + g * float(n_tabs - 1)
	var x0 := (best_lo + best_hi - total) * 0.5
	for t in n_tabs:
		tabs[t].position = Vector2(x0 + float(t) * (tw + g), band_y)
		tabs[t].size = Vector2(tw, rh)
