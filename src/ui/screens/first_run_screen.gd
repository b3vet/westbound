class_name FirstRunScreen
extends RunScreen
## The first-run chooser screen: shown once, on a fresh save, when the title's PLAY (or
## DAILY DRIVE, LOOP PRACTICE) is pressed before any run. Spec: Controls → Settings and
## first run ("First launch. A one-screen chooser for steering and throttle (default:
## drag + auto), then a 20-second empty-road warm-up so players feel it before traffic.
## The chooser can be revisited from settings"); Design system; Accessibility (text
## size). WP8.1; docs/SCREENS.md → First run.
##
## Over the title's attract drive, behind a dim: HOW DO YOU DRIVE? (speed-tilted) and a
## line under it top-left, the FirstRunChooser (steering, throttle, hand and the
## sketch), and at the bottom on the thumb side DRIVE (primary: keep these controls and
## start) with SKIP beside it (the default layout, drag + auto, right hand, and start).
## Esc goes back to the title (the chooser stays pending); Enter drives. Emits intents
## only (done, back); TitleScreens records the choice (Save.mark_chooser_done) and starts
## the run.

## DRIVE (skipped = false) or SKIP (skipped = true).
signal done(skipped: bool)
## Esc: back to the title without choosing.
signal back()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_TITLE := "HOW DO YOU DRIVE?"
const TEXT_LINE := "PICK YOUR CONTROLS · CHANGE THEM ANY TIME IN SETTINGS"
const TEXT_DRIVE := "DRIVE"
const TEXT_SKIP := "SKIP"
const TEXT_SKIP_NOTE := "DRAG + AUTO"

var dim: ColorRect
var title: ScreenText
var line: ScreenText
var chooser: FirstRunChooser
var drive_button: ScreenButton
var skip_button: ScreenButton
## The input hub (gyro support); null = assume supported.
var hub: PlayerInput:
	set(value):
		hub = value
		if chooser != null:
			chooser.hub = value
			chooser.refresh()


func _init() -> void:
	super._init()
	name = "FirstRun"
	modal = true
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	title = ScreenText.make(TEXT_TITLE, ScreenText.Face.DISPLAY, 60, ScreenText.Ink.TEXT)
	title.name = "Title"
	add_child(title)
	line = ScreenText.make(TEXT_LINE, ScreenText.Face.LABEL, 16, ScreenText.Ink.ACCENT)
	line.name = "Line"
	add_child(line)
	chooser = FirstRunChooser.new()
	# LEFT mirrors DRIVE and SKIP at once.
	chooser.changed.connect(func(_k: StringName) -> void: _layout())
	add_child(chooser)
	skip_button = ScreenButton.make(TEXT_SKIP, ScreenButton.Kind.NORMAL, 24)
	skip_button.name = "Skip"
	skip_button.note = TEXT_SKIP_NOTE
	skip_button.pressed.connect(skip)
	add_child(skip_button)
	drive_button = ScreenButton.make(TEXT_DRIVE, ScreenButton.Kind.PRIMARY, 24)
	drive_button.name = "Drive"
	drive_button.pressed.connect(drive)
	add_child(drive_button)


func _ready() -> void:
	set_process(false)


func _restyled() -> void:
	chooser.setup(style, tuning)
	chooser.hub = hub
	title.size_px = tuning.font_title_px
	title.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	for b: ScreenButton in [drive_button, skip_button]:
		b.size_px = tuning.font_screen_button_px
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	_layout()


func open() -> void:
	mirrored = bool(Settings.get_value(&"left_handed"))
	chooser.refresh()
	_layout()
	super.open()
	var i := 0
	for c: Control in [title, line, chooser, drive_button, skip_button]:
		slide_in(c, -tuning.screen_slide_px, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)
		i += 1


## DRIVE: keep the chosen controls.
func drive() -> void:
	if not is_open():
		return
	done.emit(false)


## SKIP: the default layout (drag + auto, right hand).
func skip() -> void:
	if not is_open():
		return
	FirstRunChooser.apply_defaults()
	done.emit(true)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not is_open():
		return
	if event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		drive()
	elif event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		back.emit()


func _layout() -> void:
	if style == null:
		return
	mirrored = bool(Settings.get_value(&"left_handed"))
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	dim.position = Vector2.ZERO
	dim.size = full.size
	var ts := title.get_combined_minimum_size()
	title.position = a.position
	title.size = ts
	var ls := line.get_combined_minimum_size()
	line.position = Vector2(a.position.x, a.position.y + ts.y)
	line.size = ls
	var top := line.position.y + ls.y + g * 2.0
	# The buttons along the bottom, DRIVE nearest the thumb.
	var ph := tuning.primary_button_size_px
	var th := tuning.touch_target_px
	var sw := maxf(tuning.menu_button_width_px * SKIP_WIDTH, skip_button.get_combined_minimum_size().x)
	var y := a.end.y - ph.y
	var dx := a.position.x if mirrored else a.end.x - ph.x
	drive_button.position = Vector2(dx, y)
	drive_button.size = ph
	var sx := dx + ph.x + g * 2.0 if mirrored else dx - g * 2.0 - sw
	skip_button.position = Vector2(sx, a.end.y - th)
	skip_button.size = Vector2(sw, th)
	chooser.position = Vector2.ZERO
	chooser.size = full.size
	chooser.layout(Rect2(Vector2(a.position.x, top), Vector2(a.size.x, y - g * 2.0 - top)))


## SKIP's share of the menu button width.
const SKIP_WIDTH := 0.6   # lint: allow-number layout proportion
