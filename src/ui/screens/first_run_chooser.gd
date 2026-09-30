class_name FirstRunChooser
extends Control
## The controls chooser: steering (DRAG / TILT), throttle (AUTO / MANUAL) and the hand
## (RIGHT / LEFT, the left-handed mirror), with a sketch of the chosen layout. Spec:
## Controls ("Steering (drag or gyro) and throttle (auto or manual) are two independent
## settings, giving four layouts"; mirroring; Settings and first run: "A one-screen
## chooser for steering and throttle (default: drag + auto) ... The chooser can be
## revisited from settings"). WP8.1; docs/SCREENS.md → First run.
##
## One widget, two hosts: FirstRunScreen (the first PLAY on a fresh save, with DRIVE and
## SKIP) and SettingsPanel's CONTROLS page (CHOOSE LAYOUT). A tap writes Settings at once
## (Settings.set_value), like every settings row, and the widget follows
## Events.settings_changed. TILT is disabled (N/A) where the platform has no tilt
## (PlayerInput.is_gyro_supported()). Laid out by the host: layout(area) -> height.
## Left-anchored rows on the left, the sketch and its two lines on the right.

signal changed(key: StringName)

const KEY_STEERING := &"steering_mode"
const KEY_THROTTLE := &"throttle_mode"
const KEY_HAND := &"left_handed"
const TEXT_NA := "N/A"
const TEXT_MIRRORED := "MIRRORED"
## Row labels, option captions and notes (index = option).
const ROW_LABELS: Array[String] = ["STEERING", "THROTTLE", "HAND"]
const CAPTIONS: Array[Array] = [["DRAG", "TILT"], ["AUTO", "MANUAL"], ["RIGHT", "LEFT"]]
const NOTES: Array[Array] = [["SLIDE A THUMB", "TILT THE PHONE"], ["GAS ALWAYS ON", "GAS + BRAKE PEDALS"],
	["", TEXT_MIRRORED]]
## The sketch's two lines per layout: [steering][throttle] -> [line 1, line 2]. "%s" is
## the thumb side's word (RIGHT, or LEFT when mirrored), "%o" the other side's.
const LINES := {
	&"drag": {
		&"auto": ["ONE THUMB DOES IT ALL", "DOWN BRAKES · FLICK UP BOOSTS"],
		&"manual": ["%o THUMB STEERS", "%s THUMB: GAS, BOOST, BRAKE"],
	},
	&"gyro": {
		&"auto": ["TILT THE PHONE TO STEER", "HOLD BRAKES · SWIPE UP BOOSTS"],
		&"manual": ["TILT THE PHONE TO STEER", "BRAKE %o · GAS + BOOST %s"],
	},
}
const WORD_RIGHT := "RIGHT"
const WORD_LEFT := "LEFT"

var style: HudStyle
var tuning: HudTuning
## The input hub (gyro support); null = assume supported.
var hub: PlayerInput
var labels: Array[ScreenText] = []
## options[row][i]: the option buttons (row 0 steering, 1 throttle, 2 hand).
var options: Array[Array] = []
var sketch: FirstRunSketch
var line1: ScreenText
var line2: ScreenText
## Settings writes made from the chooser (tests).
var writes: int = 0


func _init() -> void:
	name = "Chooser"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	for row in ROW_LABELS.size():
		var t := ScreenText.make(ROW_LABELS[row], ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
		add_child(t)
		labels.append(t)
		var bs: Array[ScreenButton] = []
		for i in 2:
			var b := ScreenButton.make(String(CAPTIONS[row][i]), ScreenButton.Kind.OPTION, 24)
			b.name = "%s_%d" % [ROW_LABELS[row].to_lower(), i]
			b.note = String(NOTES[row][i])
			b.pressed.connect(_choose.bind(row, i))
			add_child(b)
			bs.append(b)
		options.append(bs)
	sketch = FirstRunSketch.new()
	add_child(sketch)
	line1 = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	add_child(line1)
	line2 = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	add_child(line2)
	refresh()


func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	for l in labels:
		l.setup(s)
	for bs: Array in options:
		for b: ScreenButton in bs:
			b.setup(s)
	sketch.setup(s)
	line1.setup(s)
	line2.setup(s)


func _enter_tree() -> void:
	if not Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.connect(_on_setting_changed)
	refresh()


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)


func _on_setting_changed(key: StringName) -> void:
	if key == KEY_STEERING or key == KEY_THROTTLE or key == KEY_HAND:
		refresh()


## The option button (row 0 steering, 1 throttle, 2 hand; i 0 or 1).
func option(row: int, i: int) -> ScreenButton:
	return options[row][i]


## The selected option of `row` (0 or 1).
func selected_index(row: int) -> int:
	return 1 if (options[row][1] as ScreenButton).selected else 0


## Current steering, throttle and hand from Settings (steering shown as drag where there
## is no tilt, as PlayerInput steers).
func refresh() -> void:
	var gyro_ok := hub == null or hub.is_gyro_supported()
	var steering := StringName(Settings.get_value(KEY_STEERING))
	var throttle := StringName(Settings.get_value(KEY_THROTTLE))
	var left := bool(Settings.get_value(KEY_HAND))
	var sel := [1 if steering == &"gyro" else 0, 1 if throttle == &"manual" else 0, 1 if left else 0]
	for row in options.size():
		for i in 2:
			(options[row][i] as ScreenButton).selected = i == int(sel[row])
	var tilt: ScreenButton = options[0][1]
	tilt.disabled = not gyro_ok and not tilt.selected
	tilt.note = String(NOTES[0][1]) if gyro_ok else TEXT_NA
	var shown := &"gyro" if steering == &"gyro" and gyro_ok else &"drag"
	var mode := &"manual" if throttle == &"manual" else &"auto"
	sketch.set_layout(shown, mode, left)
	var pair: Array = LINES[shown][mode]
	line1.text = side_words(String(pair[0]), left)
	line2.text = side_words(String(pair[1]), left)


## `%s` -> the thumb side's word, `%o` -> the other side's (swapped when mirrored).
static func side_words(s: String, left_handed: bool) -> String:
	var thumb := WORD_LEFT if left_handed else WORD_RIGHT
	var other := WORD_RIGHT if left_handed else WORD_LEFT
	return s.replace("%s", thumb).replace("%o", other)


func _choose(row: int, i: int) -> void:
	var key: StringName = [KEY_STEERING, KEY_THROTTLE, KEY_HAND][row]
	var v: Variant
	match row:
		0:
			v = &"gyro" if i == 1 else &"drag"
		1:
			v = &"manual" if i == 1 else &"auto"
		_:
			v = i == 1
	writes += 1
	Settings.set_value(key, v)
	refresh()
	changed.emit(key)


## Puts every choice back to the spec's default layout (drag + auto, right hand).
static func apply_defaults() -> void:
	for key: StringName in [KEY_STEERING, KEY_THROTTLE, KEY_HAND]:
		Settings.set_value(key, Settings.DEFAULTS[key])


## Lays the chooser out inside `area` (parent-local px): the rows on the left, the sketch
## and its lines on the right. Returns the height used.
func layout(area: Rect2) -> float:
	if style == null or tuning == null:
		return 0.0
	position = Vector2.ZERO
	var g := tuning.spacing_grid_px
	var rh := tuning.touch_target_px
	var lw := tuning.settings_label_width_px * style.ts
	var sw := area.size.x * SKETCH_SHARE
	var rows_w := area.size.x - sw - g * 4.0
	var bw := (rows_w - lw - g) * 0.5
	var y := area.position.y
	for row in options.size():
		var t := labels[row]
		var ts := t.get_combined_minimum_size()
		t.position = Vector2(area.position.x, y + (rh - ts.y) * 0.5)
		t.size = Vector2(lw - g, ts.y)
		for i in 2:
			var b: ScreenButton = options[row][i]
			b.position = Vector2(area.position.x + lw + float(i) * (bw + g), y)
			b.size = Vector2(bw, rh)
		y += rh + g
	var rows_h := y - g - area.position.y
	# The sketch: a landscape phone, as tall as the rows leave room for its two lines.
	var lh := line1.get_combined_minimum_size().y
	var sx := area.end.x - sw
	var sh := minf(sw / SKETCH_ASPECT, rows_h - lh * 2.0 - g)
	sketch.position = Vector2(sx, area.position.y)
	sketch.size = Vector2(sh * SKETCH_ASPECT, sh)
	line1.position = Vector2(sx, area.position.y + sh + g)
	line1.size = Vector2(sw, lh)
	line2.position = Vector2(sx, line1.position.y + lh)
	line2.size = Vector2(sw, lh)
	return maxf(rows_h, line2.position.y + lh - area.position.y)


## The sketch's share of the width, and its aspect (a phone in landscape).
const SKETCH_SHARE := 0.36   # lint: allow-number layout proportion
const SKETCH_ASPECT := 1.9   # lint: allow-number layout proportion
