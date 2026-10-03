class_name RunScreen
extends Control
## Base of the in-run screens (countdown, pause, results, crash hint). Spec: UI, HUD
## and design system → Screens, Design system (left-anchored layouts on the 46 px
## grid, 8 px spacing), Accessibility (text size); CONTRACTS §14 (screens are Control
## scenes under src/ui/screens/ that emit intent signals; the run acts on them).
## docs/SCREENS.md.
##
## - Always processes (the pause menu works while the tree is paused).
## - Inactive = `visible = false` (not alpha 0): no draw calls during gameplay.
## - Transitions are cheap tweens on modulate / scale / position (no blur, no
##   full-screen shaders) that ignore Engine.time_scale (slow motion).
## - Laid out in canvas pixels inside the safe area: place(full, safe).

## Completes every running tween at once (finish_animations; tests and snaps).
const FINISH_S := 60.0

var style: HudStyle
var tuning: HudTuning
var full: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var safe: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
## Left-handed: the thumb-side blocks (menu, primary buttons) mirror.
var mirrored: bool = false
## Reduced motion: fades only, no punches or slides. The live setting counts too
## (motion_reduced()), so every screen honours it, the title's included (WP9.3).
var reduced_motion: bool = false
## Modal screens (pause, results, crash) take every touch while open, so nothing reaches
## the game under them; they let go the moment they start closing.
var modal: bool = false
## Gamepad / keys (PadNav, docs/CONTROLS.md → Menus with a gamepad): false for a screen
## that takes the arrows itself (the garage steps items, the achievements switch tabs), so
## no focus moves there; its own ui_* handling does it all.
var pad_focus: bool = true

var _tweens: Array[Tween] = []
var _open: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visible = false


## Styles every ScreenText / ScreenButton / ScreenPanel under this screen.
func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	_setup_tree(self)
	_restyled()


func _setup_tree(n: Node) -> void:
	for c in n.get_children():
		if c is ScreenText:
			(c as ScreenText).setup(style)
		elif c is ScreenButton:
			(c as ScreenButton).setup(style)
		elif c is ScreenPanel:
			(c as ScreenPanel).setup(style)
		_setup_tree(c)


## Called after setup (text size or theme changed).
func _restyled() -> void:
	pass


## The canvas and its safe area (canvas px). Lays the screen out.
func place(full_rect: Rect2, safe_rect: Rect2) -> void:
	# Stored in the screen's own coordinates (the screen covers the canvas).
	position = full_rect.position
	size = full_rect.size
	full = Rect2(Vector2.ZERO, full_rect.size)
	safe = Rect2(safe_rect.position - full_rect.position, safe_rect.size)
	if style != null:
		_layout()


func _layout() -> void:
	pass


func is_open() -> bool:
	return _open


## The button the pad's focus starts on when this screen is the scope (null: PadNav picks
## the PRIMARY button, else the top-left one).
func pad_default_focus() -> Control:
	return null


## Shows the screen with its entry transition.
func open() -> void:
	_open = true
	_show()
	_entered()


## Visible (and input-blocking when modal), redrawn with the current style: a hidden
## screen kept its old draw commands (the accent may have moved since).
func _show() -> void:
	if not visible:
		redraw_all()
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP if modal else Control.MOUSE_FILTER_IGNORE


func _entered() -> void:
	var tw := new_tween()
	modulate.a = 0.0
	tw.tween_property(self, ^"modulate:a", 1.0, tuning.screen_fade_in_s)


## Hides the screen (after a short fade when `animated`).
func close(animated: bool = true) -> void:
	_open = false
	kill_tweens()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not visible:
		return
	if not animated or tuning == null or not is_inside_tree():
		visible = false
		modulate.a = 1.0
		_closed()
		return
	var tw := new_tween()
	tw.tween_property(self, ^"modulate:a", 0.0, tuning.screen_fade_out_s)
	tw.tween_callback(_hide_now)


func _hide_now() -> void:
	visible = false
	modulate.a = 1.0
	_closed()


func _closed() -> void:
	pass


## Queues a redraw of every canvas item of the screen.
func redraw_all() -> void:
	_redraw(self)


static func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for c in n.get_children():
		_redraw(c)


## A tween bound to this screen that ignores slow motion (tracked for finish_animations).
func new_tween() -> Tween:
	var tw := create_tween()
	tw.set_ignore_time_scale(true)
	for i in range(_tweens.size() - 1, -1, -1):
		if not _tweens[i].is_valid():
			_tweens.remove_at(i)
	_tweens.append(tw)
	return tw


func kill_tweens() -> void:
	for tw in _tweens:
		if tw.is_valid():
			tw.kill()
	_tweens.clear()


## Runs every transition to its end now (tests, snaps).
func finish_animations() -> void:
	# A finishing tween may start another (a callback chain): loop until none run.
	for pass_i in MAX_FINISH_PASSES:
		var any := false
		for tw: Tween in _tweens.duplicate():
			if tw.is_valid() and tw.is_running():
				any = true
				tw.custom_step(FINISH_S)
		if not any:
			return


## Font size in canvas px for a base size (text size applied).
func fpx(base: int) -> int:
	return maxi(1, roundi(float(base) * (style.ts if style != null else 1.0)))


## Outer margin of the screens: the design grid's 46 px, inside the safe area.
func margin() -> float:
	return tuning.layout_grid_px * MARGIN_GRIDS


## True when this screen moves nothing but opacity: its own flag or the setting (WP9.3).
func motion_reduced() -> bool:
	return reduced_motion or bool(Settings.get_value(&"reduced_motion"))


## A punch-in (scale down from `from_scale` with a fade) on `c`, unless reduced motion.
func punch(c: Control, from_scale: float, dur: float) -> Tween:
	var tw := new_tween()
	c.pivot_offset = c.size * 0.5
	c.modulate.a = 0.0
	tw.set_parallel(true)
	tw.tween_property(c, ^"modulate:a", 1.0, dur * PUNCH_FADE_SHARE)
	if motion_reduced():
		c.scale = Vector2.ONE
	else:
		c.scale = Vector2(from_scale, from_scale)
		tw.tween_property(c, ^"scale", Vector2.ONE, dur).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tw


## Slides `c` in from `dx` px to the side while fading it in, after `delay`.
func slide_in(c: Control, dx: float, dur: float, delay: float) -> void:
	var tw := new_tween()
	var to := c.position
	c.modulate.a = 0.0
	if not motion_reduced():
		c.position = to + Vector2(dx, 0.0)
	tw.set_parallel(true)
	tw.tween_property(c, ^"modulate:a", 1.0, dur).set_delay(delay)
	tw.tween_property(c, ^"position", to, dur).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


const MAX_FINISH_PASSES := 8
## The screens' outer margin in grid cells (a 32 px frame at the 46 px grid would crowd
## the chamfers; one cell reads as the design system's generous left anchor).
const MARGIN_GRIDS := 1.0
const PUNCH_FADE_SHARE := 0.4   # lint: allow-number animation shape
