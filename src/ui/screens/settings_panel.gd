class_name SettingsPanel
extends Control
## The settings grid, in the pause menu and on the title (SETTINGS). Spec: UI → Screens
## ("Settings: controls (steering mode, throttle mode, sensitivity, dead zone, curve,
## left-handed); graphics tier and battery saver; audio buses; haptics, units, camera,
## reduced motion"); Controls → Settings and first run ("The chooser can be revisited
## from settings"); Accessibility (text size 100% / 125%, reduced motion); Performance
## budget (quality tiers, battery saver); plan D9 / D10 (controls size, drag look).
## docs/SCREENS.md → Settings; docs/SAVE.md → Settings.
##
## Three pages, switched by a row of tabs at the top of the panel's area:
##   GAME      CAMERA (a full-width row: the modes players can pick,
##             CameraTuning.player_modes(); the cockpit is hidden, plan D11),
##             GRAPHICS (quality tier), BATTERY SAVER, TEXT SIZE, UNITS, REDUCED MOTION, HAPTICS
##   CONTROLS  STEERING, THROTTLE, HAND, DRAG LOOK, CONTROLS SIZE, SENSITIVITY, DEAD ZONE,
##             CURVE; CHOOSE LAYOUT (right end of the tab row) swaps the rows for the
##             first-run chooser (FirstRunChooser) and BACK brings them back; DEFAULTS
##             (left of it) puts every CONTROLS row back to Settings.DEFAULTS
##   AUDIO     a volume row per bus (Master, Music, SFX, Engine, UI) and SOUND (mute)
## Each row is a label and a segmented choice of big OPTION buttons (touch_target_px
## tall), laid out in two columns (full-width rows first). A press writes the value
## straight into Settings (Settings.set_value), which every system applies live from
## Events.settings_changed (and Save writes soon after); the rows follow that signal
## too, so a change made elsewhere (the dev rows, the keyboard, the chooser) shows at
## once. Only keys in Settings.DEFAULTS appear. Gyro (TILT) is disabled where the
## platform has no tilt (PlayerInput.is_gyro_supported()). Only the shown page's rows
## are visible and laid out.

signal changed(key: StringName)

const TEXT_GYRO := "TILT"
const TEXT_CHOOSE := "CHOOSE LAYOUT"
const TEXT_BACK := "BACK"
const TEXT_DEFAULTS := "DEFAULTS"
const PCT_FMT := "%d%%"
const PAGE_GAME := 0
const PAGE_CONTROLS := 1
const PAGE_AUDIO := 2
const PAGE_CAPTIONS: Array[String] = ["GAME", "CONTROLS", "AUDIO"]
## Camera captions where the mode id is not the word (default: the id upper-cased).
const CAMERA_CAPTIONS := {"far": "FAR CHASE"}

## key, label, values, option labels ([] = percent labels from the values).
var rows: Array[Row] = []
var style: HudStyle
var tuning: HudTuning
## The input hub (gyro support); null = assume supported.
var hub: PlayerInput:
	set(value):
		hub = value
		if chooser != null:
			chooser.hub = value
## Settings writes made from this panel (tests).
var writes: int = 0
## The page shown (PAGE_GAME / PAGE_CONTROLS / PAGE_AUDIO) and its tabs.
var page: int = PAGE_GAME
var tabs: Array[ScreenButton] = []
## CHOOSE LAYOUT / BACK (CONTROLS page) and the chooser it shows.
var chooser_button: ScreenButton
var chooser: FirstRunChooser
var chooser_open: bool = false
## DEFAULTS (CONTROLS page): every CONTROLS row back to its default.
var defaults_button: ScreenButton
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
	## A full-width row (many options: the camera).
	var wide: bool = false


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
	if chooser_button == null:
		chooser_button = ScreenButton.make(TEXT_CHOOSE, ScreenButton.Kind.NORMAL, 20)
		chooser_button.name = "ChooseLayout"
		chooser_button.pressed.connect(toggle_chooser)
		add_child(chooser_button)
		chooser = FirstRunChooser.new()
		chooser.visible = false
		chooser.hub = hub
		chooser.changed.connect(func(k: StringName) -> void:
			writes += 1
			changed.emit(k))
		add_child(chooser)
		defaults_button = ScreenButton.make(TEXT_DEFAULTS, ScreenButton.Kind.NORMAL, 20)
		defaults_button.name = "Defaults"
		defaults_button.pressed.connect(restore_page_defaults.bind(PAGE_CONTROLS))
		add_child(defaults_button)
	var meta := MetaTuning.resolve()
	_building_page = PAGE_GAME
	var cam := Tuning.load_default().camera
	var cam_captions: Array[String] = []
	var cam_values: Array = []
	for m in cam.player_modes():
		cam_captions.append(String(CAMERA_CAPTIONS.get(m, m.to_upper())))
		cam_values.append(StringName(m))
	_add(&"camera_mode", "CAMERA", cam_values, cam_captions).wide = true
	var tiers: Array = []
	var tier_captions: Array[String] = []
	for tier in Tuning.load_default().quality.tier_names:
		tiers.append(StringName(tier))
		tier_captions.append(tier.to_upper())
	_add(&"quality_tier", "GRAPHICS", tiers, tier_captions)
	_add(&"battery_saver", "BATTERY SAVER", [false, true], ["OFF", "ON"])
	_add(&"text_scale", "TEXT SIZE", Array(t.text_scales), [])
	_add(&"units", "UNITS", [&"kmh", &"mph"], ["KM/H", "MPH"])
	_add(&"reduced_motion", "REDUCED MOTION", [false, true], ["OFF", "ON"])
	_add(&"haptics", "HAPTICS", [true, false], ["ON", "OFF"])
	_building_page = PAGE_CONTROLS
	_add(&"steering_mode", "STEERING", [&"drag", &"gyro"], ["DRAG", TEXT_GYRO])
	_add(&"throttle_mode", "THROTTLE", [&"auto", &"manual"], ["AUTO", "MANUAL"])
	_add(&"left_handed", "HAND", [false, true], ["RIGHT", "LEFT"])
	_add(&"drag_visual", "DRAG LOOK", [&"ring", &"wheel"], ["RING", "WHEEL"])
	_add(&"controls_scale", "CONTROLS SIZE", Array(t.settings_controls_scales), [])
	_add(&"steer_sensitivity", "SENSITIVITY", Array(t.settings_sensitivities), [])
	_add(&"steer_dead_zone", "DEAD ZONE", Array(meta.settings_dead_zones), ["SMALL", "NORMAL", "LARGE"])
	_add(&"steer_curve", "CURVE", Array(meta.settings_curves), ["GENTLE", "NORMAL", "SHARP"])
	_building_page = PAGE_AUDIO
	var steps := Array(AudioTuning.resolve().volume_steps)
	var labels: Array[String] = ["MASTER", "MUSIC", "EFFECTS", "ENGINE", "INTERFACE"]
	for i in AudioBuses.VOLUME_KEYS.size():
		_add(AudioBuses.VOLUME_KEYS[i], labels[i], steps, ["OFF"] if not steps.is_empty() and float(steps[0]) <= 0.0 else [])
	_add(AudioBuses.MUTE_KEY, "SOUND", [false, true], ["ON", "MUTED"])
	refresh()


func _add(key: StringName, label: String, values: Array, captions: Array) -> Row:
	var r := Row.new()
	if not Settings.DEFAULTS.has(key):
		return r
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
	return r


func setup(s: HudStyle) -> void:
	style = s
	for b in tabs:
		b.setup(s)
	for r in rows:
		r.title.setup(s)
		for b in r.buttons:
			b.setup(s)
	if chooser_button != null:
		chooser_button.setup(s)
		chooser.setup(s, tuning)
		defaults_button.setup(s)


func _enter_tree() -> void:
	if not Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)


func _notification(what: int) -> void:
	# Closed (DONE, ACCOUNT): the next open shows the rows again, not the chooser.
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible and chooser_open:
		chooser_open = false
		refresh()


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


## Shows a page (GAME / CONTROLS / AUDIO) and lays it out again in the last area.
func show_page(p: int) -> void:
	page = clampi(p, PAGE_GAME, PAGE_CAPTIONS.size() - 1)
	chooser_open = false
	refresh()
	_relayout()


## DEFAULTS: every row of page `p` back to Settings.DEFAULTS (each change announced, so
## every system and the chooser follow at once).
func restore_page_defaults(p: int) -> void:
	for r in rows:
		if r.page == p and Settings.get_value(r.key) != Settings.DEFAULTS[r.key]:
			writes += 1
			Settings.set_value(r.key, Settings.DEFAULTS[r.key])
			changed.emit(r.key)
	refresh()


## CHOOSE LAYOUT <-> BACK: the first-run chooser in place of the CONTROLS rows.
func toggle_chooser() -> void:
	page = PAGE_CONTROLS
	chooser_open = not chooser_open
	if chooser_open:
		chooser.refresh()
	refresh()
	_relayout()


func refresh() -> void:
	for i in tabs.size():
		tabs[i].selected = i == page
	if chooser_button != null:
		chooser_button.text = TEXT_BACK if chooser_open else TEXT_CHOOSE
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


func _relayout() -> void:
	if _last_area.size != Vector2.ZERO:
		layout(_last_area)


## Lays the panel out inside `area` (panel-local px): the tab row on top, then the shown
## page's rows (full-width rows first, then two columns) or the chooser. Returns the
## height used.
func layout(area: Rect2) -> float:
	if style == null or tuning == null:
		return 0.0
	_last_area = area
	var g := tuning.spacing_grid_px
	var rh := tuning.touch_target_px
	var col_gap := g * 2.0
	var cols := 2
	# The tab row: the page tabs left, CHOOSE LAYOUT at the right end (CONTROLS only).
	var tw := tuning.settings_label_width_px * style.ts
	for t in tabs.size():
		tabs[t].position = Vector2(area.position.x + float(t) * (tw + g), area.position.y)
		tabs[t].size = Vector2(tw, rh)
	var tabs_end := area.position.x + float(tabs.size()) * (tw + g)
	if chooser_button != null:
		var cw := maxf(tw, SocialUi.button_width(chooser_button, tuning))
		cw = minf(cw, area.end.x - tabs_end - col_gap)
		chooser_button.visible = page == PAGE_CONTROLS
		chooser_button.position = Vector2(area.end.x - cw, area.position.y)
		chooser_button.size = Vector2(cw, rh)
		var dw := maxf(tw, SocialUi.button_width(defaults_button, tuning))
		dw = minf(dw, chooser_button.position.x - tabs_end - g)
		defaults_button.visible = page == PAGE_CONTROLS and dw > 0.0
		defaults_button.position = Vector2(chooser_button.position.x - g - dw, area.position.y)
		defaults_button.size = Vector2(maxf(dw, 0.0), rh)
		chooser.visible = chooser_open and page == PAGE_CONTROLS
	var top := area.position.y + rh + g * 2.0
	var body := Rect2(Vector2(area.position.x, top), Vector2(area.size.x, area.end.y - top))
	var shown: Array[Row] = []
	for r in rows:
		var on := r.page == page and not (chooser_open and page == PAGE_CONTROLS)
		r.title.visible = on
		for b in r.buttons:
			b.visible = on
		if on:
			shown.append(r)
	if chooser != null and chooser.visible:
		chooser.position = Vector2.ZERO
		chooser.size = size
		return rh + g * 2.0 + chooser.layout(body)
	var lw := label_width(shown)
	var y := body.position.y
	var narrow: Array[Row] = []
	for r in shown:
		if r.wide:
			_place_row(r, body.position.x, y, body.size.x, lw, rh, g)
			y += rh + g
		else:
			narrow.append(r)
	var per_col := maxi(ceili(float(narrow.size()) / float(cols)), 1)
	var cw2 := (body.size.x - col_gap * float(cols - 1)) / float(cols)
	for i in narrow.size():
		@warning_ignore("integer_division")
		var c := i / per_col
		var k := i % per_col
		_place_row(narrow[i], body.position.x + float(c) * (cw2 + col_gap), y + float(k) * (rh + g), cw2, lw, rh, g)
	if not narrow.is_empty():
		y += float(per_col) * (rh + g)
	return y - g - area.position.y


## The label column: as wide as the page's longest label (plus a grid step), at most
## settings_label_width_px (text size applied), so 3-option rows keep their captions.
func label_width(shown: Array[Row]) -> float:
	var most := 0.0
	for r in shown:
		most = maxf(most, r.title.get_combined_minimum_size().x)
	return minf(tuning.settings_label_width_px * style.ts, most + tuning.spacing_grid_px * 2.0)


func _place_row(r: Row, x: float, y: float, w: float, lw: float, rh: float, g: float) -> void:
	var ts := r.title.get_combined_minimum_size()
	r.title.position = Vector2(x, y + (rh - ts.y) * 0.5)
	r.title.size = Vector2(lw - g, ts.y)
	var n := r.buttons.size()
	var bw := (w - lw - g * float(n - 1)) / float(n)
	for j in n:
		var b := r.buttons[j]
		b.position = Vector2(x + lw + float(j) * (bw + g), y)
		b.size = Vector2(bw, rh)
