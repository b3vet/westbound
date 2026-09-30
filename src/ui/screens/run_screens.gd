class_name RunScreens
extends CanvasLayer
## The in-run screens and which one shows. Spec: UI → Screens ("In run: countdown
## (gyro calibration happens here), pause menu (resume, recalibrate, settings, quit)";
## "Results: stats, personal-best comparison, Retry and Garage"); Run end; Controls →
## Gyro steering (calibration, web motion permission). CONTRACTS §14. docs/SCREENS.md.
##
##   screens.bind(hub, feed)                   # the run's PlayerInput and HudFeed
##   screens.resume / recalibrate / retry / quit / skip / countdown_hold(on)
##
## Listens to `Events` (game_state_changed, run_started, countdown_tick, run_over,
## settings_changed) and shows the screen for the state:
##   COUNTDOWN -> CountdownScreen    RUNNING -> none (GO fades out)
##   PAUSED    -> PauseScreen        CRASH   -> CrashScreen (TAP TO SKIP)
##   RESULTS   -> ResultsScreen (opens on run_over)
## It only emits intents; the run acts on them (it never touches gameplay). Screens
## that are not showing are `visible = false`, so gameplay frames draw nothing here.
## Always processes (the pause menu works while the tree is paused).

signal resume()
signal recalibrate()
signal retry()
signal quit()
signal skip()
## The countdown waits (true) for the web motion-permission tap, then runs (false).
signal countdown_hold(on: bool)

const GROUP := &"wb_run_screens"
const LAYER := 60

## Settings are saved to disk when the pause menu closes after a change (off in tests).
@export var persist_settings: bool = true

var hub: PlayerInput
var feed: HudFeed
var tuning: HudTuning
var style := HudStyle.new()
var state: StringName = &""
var legs_total: int = 8
## The countdown's leg chip: the leg's biome (display name) and objective id, from
## Events.leg_started (the run announces leg 1 during the countdown).
var leg_place: String = ""
var leg_objective: StringName = &""
var leg_index: int = 0

var countdown: CountdownScreen
var pause_screen: PauseScreen
var results_screen: ResultsScreen
var crash_screen: CrashScreen
var screens: Array[RunScreen] = []

var _theme: Theme
var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()
var _sky: SkyRig
var _accent_rgba: int = 0
var _legs: LegsTuning
var _hud_layout := HudLayout.new()


func _init() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	add_to_group(GROUP)
	var t := Tuning.load_default()
	tuning = t.hud
	legs_total = t.legs.legs_to_coast
	_legs = t.legs
	_theme = UiTheme.load_theme()
	countdown = $Countdown as CountdownScreen
	crash_screen = $Crash as CrashScreen
	results_screen = $Results as ResultsScreen
	pause_screen = $Pause as PauseScreen
	screens = [countdown, crash_screen, results_screen, pause_screen]
	countdown.steps_total = tuning.countdown_from
	countdown.recalibrate.connect(recalibrate.emit)
	countdown.motion_tap.connect(_on_motion_tap)
	pause_screen.resume.connect(_on_resume)
	pause_screen.recalibrate.connect(recalibrate.emit)
	pause_screen.quit.connect(_on_quit)
	pause_screen.settings.hub = hub
	results_screen.retry.connect(retry.emit)
	crash_screen.skip.connect(skip.emit)
	_restyle()
	get_viewport().size_changed.connect(_relayout)
	_connect_events(true)
	_poll_accent()


func _exit_tree() -> void:
	_connect_events(false)


# ---------------------------------------------------------------- API

## The run's input hub (gyro, calibration) and HUD feed (leg, summary). Either may be null.
func bind(input_hub: PlayerInput, hud_feed: HudFeed) -> void:
	hub = input_hub
	feed = hud_feed
	if pause_screen != null:
		pause_screen.settings.hub = hub


## Pins the canvas and safe rects (tests, previews); otherwise the viewport and the
## display safe area are used.
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe
	if is_node_ready():
		_relayout()


## The design system's accent (the sky's neon).
func set_accent(color: Color) -> void:
	var rgba := color.to_rgba32()
	if rgba == _accent_rgba:
		return
	_accent_rgba = rgba
	style.accent = color
	for s in screens:
		if s.visible:
			_redraw_tree(s)


## Shows the screens for Game state `to` (the Events listener calls this).
func show_state(to: StringName, from: StringName = &"") -> void:
	state = to
	_poll_accent()
	match to:
		Game.COUNTDOWN:
			pause_screen.close(false)
			crash_screen.close(false)
			results_screen.close(false)
			if from == Game.PAUSED:
				countdown.show_still()
		Game.RUNNING:
			pause_screen.close()
			crash_screen.close(false)
			results_screen.close(false)
			if countdown.step != 0:
				countdown.close(false)
		Game.PAUSED:
			countdown.visible = false   # keeps its step; comes back on resume
			pause_screen.mirrored = _left_handed()
			pause_screen.reduced_motion = _reduced_motion()
			pause_screen.set_gyro(gyro_active())
			pause_screen.set_summary(feed, legs_total, _miles())
			pause_screen.open()
		Game.CRASH:
			countdown.close(false)
			pause_screen.close(false)
			crash_screen.reduced_motion = _reduced_motion()
			crash_screen.open()
		Game.RESULTS:
			crash_screen.close(false)
			pause_screen.close(false)
		_:
			for s in screens:
				s.close(false)


## A new run (first start or retry): the countdown is prepared (leg line, gyro card,
## the web motion-permission hold).
func prepare_countdown() -> void:
	for s: RunScreen in [pause_screen, crash_screen, results_screen]:
		s.close(false)
	_relayout()   # the touch controls may have moved since (the HUD's panels follow them)
	countdown.kill_tweens()
	countdown.reduced_motion = _reduced_motion()
	_refresh_leg()
	countdown.set_gyro(gyro_active())
	var hold := needs_motion_tap()
	countdown.set_hold(hold)
	if hold:
		countdown.show_step(tuning.countdown_from)
		countdown_hold.emit(true)


## The results payload (Events.run_over): fills and opens the results screen.
func show_results(results: Dictionary) -> void:
	crash_screen.close(false)
	results_screen.mirrored = _left_handed()
	results_screen.reduced_motion = _reduced_motion()
	results_screen.set_results(results, legs_total, _miles())
	results_screen.open()


## Gyro steering is what the hub steers with now.
func gyro_active() -> bool:
	return hub != null and hub.effective_steering == PlayerInput.GYRO


## Web + gyro before the motion permission: the countdown waits for a tap (iOS asks
## for the permission inside a user gesture; WebMotionSource arms it on the next tap).
func needs_motion_tap() -> bool:
	if not gyro_active():
		return false
	var src := hub.gyro.source
	if src == null or not src.has_method(&"permission_state"):
		return false
	var st := StringName(str(src.call(&"permission_state")))
	return st == &"idle" or st == &"armed"


## Every screen's transitions to their end (tests, snaps).
func finish_animations() -> void:
	for s in screens:
		s.finish_animations()


## Screens showing now.
func visible_screen_count() -> int:
	var n := 0
	for s in screens:
		if s.visible:
			n += 1
	return n


## Canvas items that draw this frame under this layer (0 in gameplay).
func visible_item_count() -> int:
	var n := 0
	for s in screens:
		n += _count_visible(s)
	return n


# ---------------------------------------------------------------- Events

func _connect_events(on: bool) -> void:
	var pairs: Array[Array] = [
		[Events.game_state_changed, _on_state],
		[Events.run_started, _on_run_started],
		[Events.countdown_tick, _on_countdown_tick],
		[Events.leg_started, _on_leg_started],
		[Events.run_over, _on_run_over],
		[Events.settings_changed, _on_setting_changed],
	]
	for p in pairs:
		var sig: Signal = p[0]
		var cb: Callable = p[1]
		if on and not sig.is_connected(cb):
			sig.connect(cb)
		elif not on and sig.is_connected(cb):
			sig.disconnect(cb)


func _on_state(from: StringName, to: StringName) -> void:
	show_state(to, from)


func _on_run_started(_mode: StringName, _seed: int) -> void:
	state = Game.COUNTDOWN
	leg_index = 0
	leg_place = ""
	leg_objective = &""
	prepare_countdown()


## The run announces leg 1 (its biome and objective) in the countdown's first frame
## (WP5.6: the countdown names the biome).
func _on_leg_started(index: int, biome: StringName, objective: StringName) -> void:
	leg_index = index
	leg_place = Hud.biome_name(biome)
	leg_objective = objective
	if state == Game.COUNTDOWN:
		_refresh_leg()


## The countdown's leg chip from what is known now: the leg_started of this run, else
## the feed (its leg and objective; no biome).
func _refresh_leg() -> void:
	var index := leg_index
	var objective := leg_objective
	if index <= 0 and feed != null:
		index = feed.leg_index
		objective = feed.objective
	if index <= 0:
		countdown.set_leg(0, legs_total, "")
		return
	countdown.set_leg(index, legs_total, _objective_text(objective), leg_place if index == leg_index else "")


func _on_countdown_tick(n: int) -> void:
	if n == 0:
		countdown.show_step(0)
		_gyro_fallback()
	elif state == Game.COUNTDOWN or state == &"":
		countdown.show_step(n)


func _on_run_over(results: Dictionary) -> void:
	show_results(results)


func _on_motion_tap() -> void:
	countdown.set_hold(false)
	countdown_hold.emit(false)
	countdown.show_step(tuning.countdown_from)


func _on_resume() -> void:
	_save_settings()
	resume.emit()


func _on_quit() -> void:
	_save_settings()
	quit.emit()


func _save_settings() -> void:
	if persist_settings and pause_screen.settings_dirty:
		pause_screen.settings_dirty = false
		Save.save_to_disk()


## GO with gyro chosen but the permission refused (web): steer with drag instead.
func _gyro_fallback() -> void:
	if hub != null and hub.follows_settings and hub.effective_steering == PlayerInput.GYRO \
			and not hub.is_gyro_supported():
		hub.use_settings()


func _on_setting_changed(key: StringName) -> void:
	if key == &"text_scale":
		_restyle()
	elif key == &"units" and state == Game.COUNTDOWN:
		_refresh_leg()
	elif key == &"left_handed":
		pause_screen.mirrored = _left_handed()
		results_screen.mirrored = _left_handed()
		_relayout()
	elif key == &"steering_mode" and state == Game.PAUSED:
		pause_screen.set_gyro(gyro_active())


# ---------------------------------------------------------------- Style and layout

func _restyle() -> void:
	var ts := tuning.clamp_text_scale(float(Settings.get_value(&"text_scale")))
	style.setup(_theme, tuning, ts)
	for s in screens:
		s.setup(style, tuning)
	_relayout()


func _relayout() -> void:
	var full := _pinned_full if _pinned else Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var safe := _pinned_safe if _pinned else HudLayout.canvas_safe_rect(full)
	_update_hud_rects(full, safe)
	for s in screens:
		s.place(full, safe)


## Where the HUD's panels are (the countdown's info column stays clear of them): the
## HUD's own layout for this canvas, text size and the hub's touch controls.
func _update_hud_rects(full: Rect2, safe: Rect2) -> void:
	if countdown == null or tuning == null:
		return
	_hud_layout.build(tuning, full, safe, hub.layout if hub != null else null, style.ts)
	countdown.hud_rects = _hud_layout.rects()


func _poll_accent() -> void:
	if _sky != null and is_instance_valid(_sky):
		return
	_sky = get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig
	if _sky == null:
		if _accent_rgba == 0:
			set_accent(_theme.get_color(UiTheme.C_ACCENT, UiTheme.TYPE))
		return
	if not _sky.accent_changed.is_connected(set_accent):
		_sky.accent_changed.connect(set_accent)
	set_accent(_sky.get_accent())


static func _redraw_tree(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for c in n.get_children():
		_redraw_tree(c)


static func _count_visible(n: Node) -> int:
	var k := 0
	if n is CanvasItem:
		if not (n as CanvasItem).is_visible_in_tree():
			return 0
		k = 1
	for c in n.get_children():
		k += _count_visible(c)
	return k


## The objective's HUD label ("5 CLOSE PASSES", "HIT 155 MPH"), in the units setting.
func _objective_text(objective: StringName) -> String:
	if objective == &"":
		return ""
	return LegObjectives.label(objective, _legs if _legs != null else Tuning.load_default().legs, _miles())


static func _left_handed() -> bool:
	return bool(Settings.get_value(&"left_handed"))


static func _reduced_motion() -> bool:
	return bool(Settings.get_value(&"reduced_motion"))


static func _miles() -> bool:
	return StringName(str(Settings.get_value(&"units"))) == &"mph"
