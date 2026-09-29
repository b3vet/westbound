class_name PauseScreen
extends RunScreen
## The pause menu. Spec: UI → Screens ("pause menu (resume, recalibrate, settings,
## quit)"); Controls → Gyro steering ("A Recalibrate button sits in the pause menu");
## Design system (faceted controls, left-anchored layout); Accessibility (text size).
## docs/SCREENS.md → Pause.
##
## Emits intents only (resume, recalibrate, quit); the run acts on them. The run pauses
## the tree, so this screen always processes. Layout: the title and a short run summary
## top-left; the buttons in one column on the thumb side (right, or left when
## left-handed), stacked bottom-up from the thumb: RESUME (primary, nearest the thumb),
## RECALIBRATE (gyro only), SETTINGS, and QUIT furthest away. Every target is at least
## touch_target_px tall. SETTINGS swaps the menu for the SettingsPanel; DONE comes back.

signal resume()
signal recalibrate()
signal quit()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_PAUSED := "PAUSED"
const TEXT_SETTINGS := "SETTINGS"
const TEXT_RESUME := "RESUME"
const TEXT_RECALIBRATE := "RECALIBRATE"
const TEXT_RECALIBRATED := "CALIBRATED"
const TEXT_QUIT := "QUIT"
const TEXT_DONE := "DONE"
const TEXT_LEG := "LEG %d OF %d"
const TEXT_BANKED := "BANKED  %s"
const TEXT_DISTANCE := "%s %s DRIVEN"
const UNIT_KM := "KM"
const UNIT_MI := "MI"

## Gyro in use: RECALIBRATE shows.
var gyro: bool = false
var settings_open: bool = false
## Settings written while the panel was open (the run may save them).
var settings_dirty: bool = false

var dim: ColorRect
var title: ScreenText
var summary_leg: ScreenText
var summary_distance: ScreenText
var summary_banked: ScreenText
var resume_button: ScreenButton
var recalibrate_button: ScreenButton
var settings_button: ScreenButton
var quit_button: ScreenButton
var done_button: ScreenButton
var settings: SettingsPanel

var _note_left: float = 0.0


func _init() -> void:
	super._init()
	name = "Pause"
	modal = true
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	title = ScreenText.make(TEXT_PAUSED, ScreenText.Face.DISPLAY, 60, ScreenText.Ink.TEXT)
	add_child(title)
	summary_leg = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.ACCENT)
	add_child(summary_leg)
	summary_distance = ScreenText.make("", ScreenText.Face.BODY, 20, ScreenText.Ink.TEXT)
	add_child(summary_distance)
	summary_banked = ScreenText.make("", ScreenText.Face.BODY, 20, ScreenText.Ink.MUTED)
	summary_banked.tabular = true
	add_child(summary_banked)
	quit_button = _button(TEXT_QUIT, ScreenButton.Kind.DANGER, quit.emit)
	settings_button = _button(TEXT_SETTINGS, ScreenButton.Kind.NORMAL, open_settings)
	recalibrate_button = _button(TEXT_RECALIBRATE, ScreenButton.Kind.NORMAL, _on_recalibrate)
	resume_button = _button(TEXT_RESUME, ScreenButton.Kind.PRIMARY, resume.emit)
	settings = SettingsPanel.new()
	settings.visible = false
	settings.changed.connect(func(_k: StringName) -> void: settings_dirty = true)
	add_child(settings)
	done_button = _button(TEXT_DONE, ScreenButton.Kind.PRIMARY, close_settings)
	done_button.visible = false


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 24)
	b.name = label.capitalize().replace(" ", "")
	b.pressed.connect(action)
	add_child(b)
	return b


func _restyled() -> void:
	if settings.rows.is_empty():
		settings.build(tuning)
	settings.setup(style)
	title.size_px = tuning.font_title_px
	title.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	for b: ScreenButton in [quit_button, settings_button, recalibrate_button, resume_button, done_button]:
		b.size_px = tuning.font_screen_button_px
	summary_distance.size_px = tuning.font_screen_body_px
	summary_banked.size_px = tuning.font_screen_body_px
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))


## The run summary under the title.
func set_summary(feed: HudFeed, legs_total: int, miles: bool) -> void:
	if feed == null:
		return
	summary_leg.text = TEXT_LEG % [feed.leg_index, legs_total]
	var km := feed.distance_m / Units.M_PER_KM
	var d := Units.kmh_to_mph(km) if miles else km
	summary_distance.text = TEXT_DISTANCE % [HudFormat.tenths_text(roundi(d * HudFormat.TENTHS)),
			UNIT_MI if miles else UNIT_KM]
	summary_banked.text = TEXT_BANKED % HudFormat.thousands(feed.banked)
	_layout()


func set_gyro(on: bool) -> void:
	gyro = on
	_apply_mode()
	_layout()


func open() -> void:
	settings_open = false
	settings_dirty = false
	_note_left = 0.0
	recalibrate_button.text = TEXT_RECALIBRATE
	_apply_mode()
	_layout()
	super.open()
	var dx := -tuning.screen_slide_px if mirrored else tuning.screen_slide_px
	var i := 0
	for b: ScreenButton in [resume_button, recalibrate_button, settings_button, quit_button]:
		if b.visible:
			slide_in(b, dx, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)
			i += 1


func open_settings() -> void:
	settings_open = true
	settings.refresh()
	_apply_mode()
	_layout()
	slide_in(settings, 0.0, tuning.screen_fade_in_s, 0.0)


func close_settings() -> void:
	settings_open = false
	_apply_mode()
	_layout()
	# The gyro may have been switched on or off in the settings.
	slide_in(resume_button, 0.0, tuning.screen_fade_in_s, 0.0)


func _apply_mode() -> void:
	var menu := not settings_open
	title.text = TEXT_SETTINGS if settings_open else TEXT_PAUSED
	for c: CanvasItem in [summary_leg, summary_distance, summary_banked, resume_button, settings_button, quit_button]:
		c.visible = menu
	recalibrate_button.visible = menu and gyro
	settings.visible = settings_open
	done_button.visible = settings_open


func _on_recalibrate() -> void:
	recalibrate.emit()
	recalibrate_button.text = TEXT_RECALIBRATED
	_note_left = tuning.recalibrated_note_s
	set_process(true)


func _process(delta: float) -> void:
	if _note_left <= 0.0:
		set_process(false)
		return
	_note_left -= delta
	if _note_left <= 0.0:
		recalibrate_button.text = TEXT_RECALIBRATE
		set_process(false)


func _ready() -> void:
	set_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or settings_open:
		return
	if event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		resume.emit()


func _layout() -> void:
	if style == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	dim.position = Vector2.ZERO
	dim.size = full.size
	var bw := tuning.menu_button_width_px
	var th := tuning.touch_target_px
	var ts := title.get_combined_minimum_size()
	if settings_open:
		# Title and DONE on the top row, the settings grid under them.
		title.position = a.position
		title.size = ts
		var dw := maxf(bw * DONE_WIDTH, done_button.get_combined_minimum_size().x)
		done_button.size = Vector2(dw, th)
		done_button.position = Vector2(a.end.x - dw, a.position.y + (ts.y - th) * 0.5)
		var top := a.position.y + maxf(ts.y, th) + g * 2.0
		settings.position = Vector2.ZERO
		settings.size = full.size
		settings.layout(Rect2(Vector2(a.position.x, top), Vector2(a.size.x, a.end.y - top)))
		return
	# Menu column on the thumb side, bottom-up from the thumb.
	var x := a.position.x if mirrored else a.end.x - bw
	var y := a.end.y
	var ph := tuning.primary_button_size_px.y
	for b: ScreenButton in [resume_button, recalibrate_button, settings_button, quit_button]:
		if not b.visible and b != recalibrate_button:
			continue
		if b == recalibrate_button and not gyro:
			continue
		var h := ph if b == resume_button else th
		y -= h
		b.position = Vector2(x, y)
		b.size = Vector2(bw, h)
		y -= g
	# Title block on the other side, left-anchored.
	var tx := a.end.x - maxf(ts.x, bw) if mirrored else a.position.x
	title.position = Vector2(tx, a.position.y)
	title.size = ts
	var ly := a.position.y + ts.y + g
	for t: ScreenText in [summary_leg, summary_distance, summary_banked]:
		var s := t.get_combined_minimum_size()
		t.position = Vector2(tx, ly)
		t.size = s
		ly += s.y


## DONE: a share of the menu button width.
const DONE_WIDTH := 0.6   # lint: allow-number layout proportion
