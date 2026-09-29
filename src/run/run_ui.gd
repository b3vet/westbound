class_name RunUi
extends CanvasLayer
## Minimal in-run screens until WP4.3 (HUD) and WP4.4 (screens) replace them. Spec:
## UI → Screens (countdown, pause, results with Retry), HUD elements (fallback
## readouts only), Run end ("Retry puts the player back on the road within 2 seconds").
##
## Pure view: it shows what the run tells it and emits intent signals (retry,
## pause_toggled, skip); the run acts on them. Layout follows the spec's HUD corners:
## the fallback score top-left, pause top-right, speed bottom-left; the countdown,
## crash hint and results sit in the middle, where nothing else is during those states.
## Labels change only when their text changes.

signal retry_pressed()
signal pause_pressed()
signal resume_pressed()

## Design-system colors (spec: UI → Design system). WP4.3's theme replaces these.
const INK := Color("#0b1020")
const PANEL := Color("#111a30")
const TEXT := Color("#f4f7ff")
const MUTED := Color("#8a93ad")
const GOLD := Color("#ffd24a")
const HOT := Color("#ff5a4d")
## Canvas px on the 720 px tall canvas (design-system grid: 46 px, spacing 8 px).
const MARGIN_PX := 16.0
const BEVEL_PX := 13
const BEVEL_SMALL_PX := 7
const BORDER_PX := 2
const FONT_SMALL := 18
const FONT_BODY := 22
const FONT_BIG := 120
const FONT_TITLE := 60
const BUTTON_SIZE := Vector2(184.0, 56.0)
const PAUSE_SIZE := Vector2(64.0, 52.0)
const RESULTS_WIDTH := 460.0

var countdown_label: Label
var hint_label: Label
var score_label: Label
var speed_label: Label
var pause_button: Button
var paused_panel: PanelContainer
var results_panel: PanelContainer
var results_label: Label
var retry_button: Button

var _root: Control


func _init() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	countdown_label = _label(FONT_BIG, TEXT)
	countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	countdown_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	countdown_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.visible = false

	hint_label = _label(FONT_BODY, MUTED)
	hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint_label.position.y -= MARGIN_PX * 8.0
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.visible = false

	score_label = _label(FONT_BODY, TEXT)
	score_label.position = Vector2(MARGIN_PX, MARGIN_PX)

	speed_label = _label(FONT_BODY, TEXT)
	speed_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	speed_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	speed_label.position += Vector2(MARGIN_PX, -MARGIN_PX)

	pause_button = _button("II", PAUSE_SIZE)
	pause_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pause_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	pause_button.position += Vector2(-MARGIN_PX, MARGIN_PX)
	pause_button.pressed.connect(func() -> void: pause_pressed.emit())

	paused_panel = _panel()
	var pbox := VBoxContainer.new()
	pbox.add_theme_constant_override(&"separation", int(MARGIN_PX))
	paused_panel.add_child(pbox)
	var ptitle := _label(FONT_TITLE, TEXT, false)
	ptitle.text = "PAUSED"
	ptitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pbox.add_child(ptitle)
	var resume := _button("RESUME", BUTTON_SIZE, false)
	resume.pressed.connect(func() -> void: resume_pressed.emit())
	pbox.add_child(resume)
	paused_panel.visible = false

	results_panel = _panel()
	results_panel.custom_minimum_size.x = RESULTS_WIDTH
	var rbox := VBoxContainer.new()
	rbox.add_theme_constant_override(&"separation", int(MARGIN_PX))
	results_panel.add_child(rbox)
	results_label = _label(FONT_BODY, TEXT, false)
	rbox.add_child(results_label)
	retry_button = _button("RETRY", BUTTON_SIZE, false)
	retry_button.pressed.connect(func() -> void: retry_pressed.emit())
	rbox.add_child(retry_button)
	results_panel.visible = false


## The countdown number (0 shows GO); a negative value hides it.
func show_countdown(remaining: int) -> void:
	if remaining < 0:
		countdown_label.visible = false
		return
	countdown_label.visible = true
	_set_text(countdown_label, "GO" if remaining == 0 else str(remaining))


func show_hint(text: String) -> void:
	hint_label.visible = not text.is_empty()
	_set_text(hint_label, text)


## Fallback readouts while no HUD is installed.
func set_fallback_visible(on: bool) -> void:
	score_label.visible = on
	speed_label.visible = on
	pause_button.visible = on


func update_readouts(feed: HudFeed, kmh: bool) -> void:
	if not score_label.visible:
		return
	var lives := ""
	for i in feed.max_lives:
		lives += "#" if i < feed.lives else "-"
	var text := "%d   BEST %d\nCHAIN %d  x%.1f\n%s%s  LEG %d" % [feed.banked, feed.best, feed.chain,
		feed.multiplier, lives, "  GHOST" if feed.ghost else "", feed.leg_index]
	if feed.night:
		text += "  NIGHT"
	_set_text(score_label, text)
	var speed := Units.mps_to_kmh(feed.speed_mps)
	var unit := "km/h"
	if not kmh:
		speed = Units.kmh_to_mph(speed)
		unit = "mph"
	var cp := ""
	if feed.checkpoint_distance_m >= 0.0:
		cp = "   CP %.1f km" % (feed.checkpoint_distance_m / Units.M_PER_KM)
	_set_text(speed_label, "%d %s%s   BOOST %d%%%s" % [roundi(speed), unit,
		"  TOO SLOW" if feed.too_slow else "", roundi(feed.boost_fill * Units.PCT), cp])


func show_paused(on: bool) -> void:
	paused_panel.visible = on


func show_results(results: Dictionary, best_before: int, new_best: bool) -> void:
	var lines := PackedStringArray()
	lines.append("NEW BEST  %d" % results[RunStats.SCORE] if new_best else "SCORE  %d" % results[RunStats.SCORE])
	lines.append("BEST  %d" % maxi(best_before, int(results[RunStats.SCORE])))
	lines.append("DISTANCE  %.2f km" % (float(results[RunStats.DISTANCE_M]) / Units.M_PER_KM))
	lines.append("LEGS  %d%s" % [results[RunStats.LEGS_COMPLETED], "  COAST" if results[RunStats.COAST_REACHED] else ""])
	lines.append("BEST CHAIN  %d   BEST x%.1f" % [results[RunStats.BEST_CHAIN], results[RunStats.BEST_MULTIPLIER]])
	lines.append("THREADS  %d   CLOSE  %d" % [results[RunStats.THREADS], results[RunStats.CLOSE_PASSES]])
	lines.append("TOP  %d km/h   NIGHT  %d s   HITS  %d" % [roundi(float(results[RunStats.TOP_SPEED_KMH])),
		roundi(float(results[RunStats.NIGHT_TIME_S])), results[RunStats.HITS]])
	_set_text(results_label, "\n".join(lines))
	results_label.add_theme_color_override(&"font_color", GOLD if new_best else TEXT)
	results_panel.visible = true


func hide_results() -> void:
	results_panel.visible = false


func _label(size: int, color: Color, add: bool = true) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_color_override(&"font_outline_color", INK)
	l.add_theme_constant_override(&"outline_size", BORDER_PX * 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if add:
		_root.add_child(l)
	return l


func _button(text: String, size: Vector2, add: bool = true) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override(&"font_size", FONT_BODY)
	for state: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		b.add_theme_stylebox_override(state, _style(state == &"pressed", BEVEL_SMALL_PX))
	for col: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color"]:
		b.add_theme_color_override(col, TEXT)
	if add:
		_root.add_child(b)
	return b


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override(&"panel", _style(false, BEVEL_PX))
	p.set_anchors_preset(Control.PRESET_CENTER)
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_child(p)
	return p


func _style(pressed: bool, bevel: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL.lightened(0.25) if pressed else PANEL
	s.border_color = MUTED
	s.set_border_width_all(BORDER_PX)
	s.set_corner_radius_all(bevel)
	s.corner_detail = 1
	s.set_content_margin_all(MARGIN_PX)
	return s


static func _set_text(l: Label, text: String) -> void:
	if l.text != text:
		l.text = text
