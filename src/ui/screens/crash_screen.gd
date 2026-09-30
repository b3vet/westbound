class_name CrashScreen
extends RunScreen
## The crash cinematic's TAP TO SKIP hint. Spec: Lives, hits and crashes (the crash
## cinematic, tap to skip); UI → Screens. docs/SCREENS.md → Crash.
##
## The whole screen catches the tap (the cinematic has nothing else to touch) and
## emits `skip`; keys still reach the run's own handler. The hint chip appears after
## crash_hint_delay_s so the impact reads first, then pulses gently. Draws nothing
## but the chip.

signal skip()

const TEXT_SKIP := "TAP TO SKIP"

var hint: ScreenPanel
var hint_text: ScreenText
var hint_chevrons: ScreenText

var _t: float = 0.0
var _fired: bool = false


func _init() -> void:
	super._init()
	name = "Crash"
	modal = true
	gui_input.connect(_on_input)
	hint = ScreenPanel.new()
	hint.small_bevel = true
	hint.fill_alpha = HINT_FILL
	add_child(hint)
	hint_text = ScreenText.make(TEXT_SKIP, ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	hint.add_child(hint_text)
	hint_chevrons = ScreenText.make(">>", ScreenText.Face.DISPLAY, 16, ScreenText.Ink.ACCENT)
	hint.add_child(hint_chevrons)


func _ready() -> void:
	set_process(false)


func open() -> void:
	_open = true
	_show()
	modulate.a = 1.0
	_fired = false
	_t = 0.0
	hint.visible = false
	_layout()
	set_process(true)


func _closed() -> void:
	set_process(false)


func close(animated: bool = true) -> void:
	set_process(false)
	super.close(animated)


func _process(delta: float) -> void:
	_t += delta / maxf(Engine.time_scale, EPS)   # real time: the crash runs in slow motion
	var d := tuning.crash_hint_delay_s
	if _t < d:
		return
	hint.visible = true
	var k := _t - d
	var fade := clampf(k / maxf(tuning.screen_fade_in_s, EPS), 0.0, 1.0)
	var pulse := lerpf(PULSE_MIN, 1.0, 0.5 + 0.5 * cos(TAU * tuning.crash_hint_pulse_hz * k))
	hint.modulate.a = fade * (pulse if not motion_reduced() else 1.0)


## Skips the hint's delay (snaps).
func show_hint_now() -> void:
	_t = maxf(_t, tuning.crash_hint_delay_s + tuning.screen_fade_in_s)
	_process(0.0)


func hint_visible() -> bool:
	return hint.visible


func _on_input(event: InputEvent) -> void:
	var tap := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
	if tap and not _fired:
		_fired = true
		accept_event()
		skip.emit()


func _layout() -> void:
	if style == null:
		return
	var g := tuning.spacing_grid_px
	var a := safe.grow(-margin())
	var ts := hint_text.get_combined_minimum_size()
	var cs := hint_chevrons.get_combined_minimum_size()
	var pad := g * 2.0
	var w := pad * 2.0 + ts.x + g + cs.x
	var h := maxf(ts.y, cs.y) + g * 2.0
	hint.size = Vector2(w, h)
	# Bottom-centre: where both thumbs rest, clear of the cinematic's subject.
	hint.position = Vector2(a.get_center().x - w * 0.5, a.end.y - h)
	hint_text.position = Vector2(pad, (h - ts.y) * 0.5)
	hint_text.size = ts
	hint_chevrons.position = Vector2(pad + ts.x + g, (h - cs.y) * 0.5)
	hint_chevrons.size = cs


const EPS := 1e-6   # lint: allow-number divide guard
const HINT_FILL := 0.8   # lint: allow-number look
## The pulse dips to this opacity.
const PULSE_MIN := 0.55   # lint: allow-number look
