class_name FirstRunWarmupHint
extends CanvasLayer
## The warm-up's hint during the first run: WARM-UP · EMPTY ROAD, the seconds until
## traffic, and SKIP; then TRAFFIC AHEAD for a moment. Spec: Controls → Settings and
## first run ("a 20-second empty-road warm-up so players feel it before traffic");
## Design system (faceted panel, accent tab, chamfered button); Accessibility (text
## size; the line says it in words). WP8.1; docs/SCREENS.md → First run.
##
## Top-right under the HUD's lives, pause, camera and high-beam slots (HudLayout), clear
## of the top-centre readouts, the leg toast and the dev rows on the left. RunWarmup
## drives it (set_seconds, set_ending, hide_now); SKIP emits `skip` and the warm-up
## ends. A layer above the HUD (5) and below the touch overlay and the screens, so the
## pause menu's dim covers it. Labels change only when the second changes. Nothing
## exists outside the first run.

signal skip()

const LAYER := 6
const TEXT_HEAD := "WARM-UP · EMPTY ROAD"
const TEXT_COUNT := "TRAFFIC IN %d S"
const TEXT_AHEAD := "TRAFFIC AHEAD"
const TEXT_SKIP := "SKIP"

var style := HudStyle.new()
var tuning: HudTuning
var root: Control
var panel: ScreenPanel
var head: ScreenText
var count: ScreenText
var skip_button: ScreenButton
var seconds: int = -1
var ending: bool = false

var _theme: Theme
var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()
var _sky: SkyRig


func _init() -> void:
	layer = LAYER
	name = "WarmupHint"
	root = Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	panel = ScreenPanel.new()
	panel.edge = ScreenPanel.Edge.ACCENT
	root.add_child(panel)
	head = ScreenText.make(TEXT_HEAD, ScreenText.Face.LABEL, 16, ScreenText.Ink.ACCENT)
	root.add_child(head)
	count = ScreenText.make("", ScreenText.Face.BODY, 20, ScreenText.Ink.TEXT)
	count.tabular = true
	root.add_child(count)
	skip_button = ScreenButton.make(TEXT_SKIP, ScreenButton.Kind.NORMAL, 20)
	skip_button.name = "Skip"
	skip_button.pressed.connect(func() -> void: skip.emit())
	root.add_child(skip_button)


func _ready() -> void:
	tuning = Tuning.load_default().hud
	_theme = UiTheme.load_theme()
	get_viewport().size_changed.connect(_layout)
	Events.settings_changed.connect(_on_setting_changed)
	_restyle()


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)
	if _sky != null and is_instance_valid(_sky) and _sky.accent_changed.is_connected(_set_accent):
		_sky.accent_changed.disconnect(_set_accent)


## Pins the canvas and safe rects (tests).
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe
	_layout()


## The seconds left of the empty road (the line changes only when the number does).
func set_seconds(s: int) -> void:
	visible = true
	ending = false
	skip_button.visible = true
	if s == seconds:
		return
	seconds = s
	count.text = TEXT_COUNT % s
	_layout()


## The warm-up is over: TRAFFIC AHEAD, no SKIP (RunWarmup hides it after a moment).
func set_ending() -> void:
	if ending:
		return
	ending = true
	skip_button.visible = false
	count.text = TEXT_AHEAD
	_layout()


func hide_now() -> void:
	visible = false


func _on_setting_changed(key: StringName) -> void:
	if key == &"text_scale":
		_restyle()


func _restyle() -> void:
	if tuning == null:
		return
	style.setup(_theme, tuning, tuning.clamp_text_scale(float(Settings.get_value(&"text_scale"))))
	_poll_accent()
	for c: Node in [panel, head, count, skip_button]:
		if c is ScreenText:
			(c as ScreenText).setup(style)
		elif c is ScreenButton:
			(c as ScreenButton).setup(style)
		elif c is ScreenPanel:
			(c as ScreenPanel).setup(style)
	count.size_px = tuning.font_screen_body_px
	_layout()


func _poll_accent() -> void:
	if _sky == null or not is_instance_valid(_sky):
		_sky = get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig if is_inside_tree() else null
		if _sky != null and not _sky.accent_changed.is_connected(_set_accent):
			_sky.accent_changed.connect(_set_accent)
	style.accent = _sky.get_accent() if _sky != null else _theme.get_color(UiTheme.C_ACCENT, UiTheme.TYPE)


func _set_accent(c: Color) -> void:
	style.accent = c
	for n: CanvasItem in [panel, head, count, skip_button]:
		n.queue_redraw()


## Canvas-rect layout: a panel right-aligned under the HUD's top-right buttons (and the
## high-beam slot), holding the two lines and SKIP on its right.
func _layout() -> void:
	if tuning == null or not is_inside_tree():
		return
	var full := _pinned_full if _pinned else Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var safe := _pinned_safe if _pinned else HudLayout.canvas_safe_rect(full)
	var hl := HudLayout.new()
	hl.build(tuning, full, safe, null, style.ts)
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var hs := head.get_combined_minimum_size()
	var cs := count.get_combined_minimum_size()
	var fs := count.font_px()
	var widest := HudDraw.number_width(style.body, TEXT_COUNT % WIDEST_SECONDS, fs, style.digit_cell(style.body, fs))
	var text_w := ceilf(maxf(maxf(hs.x, cs.x), widest))
	var sw := SocialUi.button_width(skip_button, tuning) if skip_button.visible else 0.0
	var pad := g * 2.0
	var w := pad + text_w + (g * 2.0 + sw if sw > 0.0 else 0.0) + pad
	var h := maxf(th, hs.y + cs.y) + g * 2.0
	var right := hl.camera.end.x
	var top := hl.high_beam.end.y + g
	panel.position = Vector2(right - w, top)
	panel.size = Vector2(w, h)
	var ty := top + (h - hs.y - cs.y) * 0.5
	head.position = Vector2(right - w + pad, ty)
	head.size = hs
	count.position = Vector2(right - w + pad, ty + hs.y)
	count.size = Vector2(text_w, cs.y)
	skip_button.position = Vector2(right - pad - sw, top + (h - th) * 0.5)
	skip_button.size = Vector2(sw, th)


## Rect of the panel (tests).
func panel_rect() -> Rect2:
	return Rect2(panel.position, panel.size)


## The widest count line the panel is sized for (two digits).
const WIDEST_SECONDS := 88
