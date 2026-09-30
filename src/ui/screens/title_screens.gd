class_name TitleScreens
extends CanvasLayer
## The title and the online hub, over the run's attract drive (WP8.5). Spec: UI →
## Screens (Title); Accessibility (text size 100% / 125%, safe areas); multiplayer
## handoff → Client changes (Online hub). CONTRACTS §14 (screens emit intents; the run
## acts on them). docs/SCREENS.md → Title, Online hub.
##
##   title = TitleScreens.new()
##   run.add_child(title)
##   title.bind(hub)                        # the run's PlayerInput (settings, text fields)
##   title.start.connect(run.start_mode)    # PLAY (journey), DAILY DRIVE, LOOP PRACTICE
##   title.show_state(state)                # the run: open in MENU, closed otherwise
##
## Built on first use (the screens do not exist until the game first shows the title, so
## runs that never do, tests and tools, pay nothing) and hidden with `visible = false`:
## no canvas item draws in gameplay (visible_item_count() == 0). Always processes. The
## layer is RunScreens' (60): above the dev rows (50), below the dev HUD (100); the two
## never show together (RunScreens shows nothing in MENU).

signal start(mode: StringName)

const LAYER := 60
## The online hub's LOOP PRACTICE starts this mode (Run.MODE_LOOP).
const MODE_LOOP := &"loop"

## Settings changed on the title are saved when its settings view closes or a run
## starts (off in tests).
@export var persist_settings: bool = true

var hub: PlayerInput
var tuning: HudTuning
var style := HudStyle.new()
var title: TitleScreen
var online_hub: OnlineHubScreen
var screens: Array[RunScreen] = []
## The runs client for the leaderboards (null: NetRunsClient.ensure()).
var runs: NetRunsClient

var _theme: Theme
var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()
var _sky: SkyRig
var _accent_rgba: int = 0


func _init() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	if Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.disconnect(_on_setting_changed)


# ---------------------------------------------------------------- API

func bind(input_hub: PlayerInput) -> void:
	hub = input_hub
	if title != null:
		title.hub = hub


## Pins the canvas and safe rects (tests, previews).
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe
	if is_built():
		_relayout()


func is_built() -> bool:
	return title != null


## The run's state: the title opens in MENU; everything closes otherwise.
func show_state(to: StringName) -> void:
	if to == Game.MENU:
		open_title()
	elif is_built():
		_save_settings()
		for s in screens:
			s.close(false)


func open_title() -> void:
	_build()
	_poll_accent()
	online_hub.close(false)
	title.open()


func open_hub() -> void:
	_build()
	title.close(false)
	online_hub.open()


func is_open() -> bool:
	return is_built() and (title.visible or online_hub.visible)


## Every screen's transitions to their end (tests, snaps).
func finish_animations() -> void:
	for s in screens:
		s.finish_animations()


## Canvas items that draw this frame under this layer (0 outside the title).
func visible_item_count() -> int:
	var n := 0
	for s in screens:
		n += _count_visible(s)
	return n


## The design system's accent (the sky's neon).
func set_accent(color: Color) -> void:
	var rgba := color.to_rgba32()
	if rgba == _accent_rgba:
		return
	_accent_rgba = rgba
	style.accent = color
	for s in screens:
		if s.visible:
			s.redraw_all()


# ---------------------------------------------------------------- Build

func _build() -> void:
	if is_built():
		return
	tuning = Tuning.load_default().hud
	_theme = UiTheme.load_theme()
	title = TitleScreen.new()
	title.hub = hub
	title.runs = runs
	add_child(title)
	online_hub = OnlineHubScreen.new()
	online_hub.runs = runs
	add_child(online_hub)
	screens = [title, online_hub]
	title.play.connect(_on_play)
	title.online.connect(open_hub)
	title.settings_closed.connect(_on_settings_closed)
	online_hub.back.connect(open_title)
	online_hub.loop_practice.connect(func() -> void: _on_play(MODE_LOOP))
	online_hub.social.connect(_on_social)
	get_viewport().size_changed.connect(_relayout)
	Events.settings_changed.connect(_on_setting_changed)
	_restyle()


func _on_play(mode: StringName) -> void:
	_save_settings()
	start.emit(mode)


## FRIENDS / CREW from the hub: the title's account view on that tab (DONE comes back).
func _on_social(view: int) -> void:
	online_hub.close(false)
	title.open()
	title.finish_animations()
	title.open_account(view, true)


func _on_settings_closed(to_hub: bool) -> void:
	_save_settings()
	if to_hub:
		open_hub()


func _save_settings() -> void:
	if title != null and title.settings_dirty:
		title.settings_dirty = false
		if persist_settings:
			Save.save_to_disk()


func _on_setting_changed(key: StringName) -> void:
	if key == &"text_scale":
		_restyle()


func _restyle() -> void:
	if not is_built():
		return
	var ts := tuning.clamp_text_scale(float(Settings.get_value(&"text_scale")))
	style.setup(_theme, tuning, ts)
	for s in screens:
		s.setup(style, tuning)
	_relayout()


func _relayout() -> void:
	if not is_built():
		return
	var full := _pinned_full if _pinned else Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var safe := _pinned_safe if _pinned else HudLayout.canvas_safe_rect(full)
	for s in screens:
		s.place(full, safe)


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


static func _count_visible(n: Node) -> int:
	var k := 0
	if n is CanvasItem:
		if not (n as CanvasItem).is_visible_in_tree():
			return 0
		k = 1
	for c in n.get_children():
		k += _count_visible(c)
	return k
