class_name TitleScreen
extends RunScreen
## The title screen (WP8.5). Spec: UI → Screens ("Title: the attract camera drives the
## selected car; Play, Daily Drive, Garage, Leaderboards, Settings"); Design system
## (the logo in Chakra Petch, speed-tilted; faceted controls; left-anchored layouts on
## the 46 px grid, never centred); Accessibility (text size 100% / 125%); Modes at launch
## (Journey, Daily Drive); multiplayer handoff → Client changes (the online hub, the
## profile). docs/SCREENS.md → Title.
##
## Over the run's attract drive (Run in MENU: the car drives itself and cannot be hit).
## Left-anchored, stacked up from the bottom-left thumb:
##   - a row of LEADERBOARDS, SETTINGS, GARAGE (WP8.2: emits `garage`) and ACHIEVEMENTS
##     (WP8.3: emits `achievements`);
##   - PLAY (primary: Journey), DAILY DRIVE (today's UTC date under it), ONLINE (the hub);
##   - the WESTBOUND logo and CHASE THE SUN top-left, on a slanted ink band.
## Top-right: the profile chip (name#tag, online status; a tap opens ACCOUNT).
## SETTINGS swaps the menu for the in-run SettingsPanel (GAME / AUDIO pages) with DONE
## and ACCOUNT (the ProfilePanel with FRIENDS / CREW, shown when a session exists), laid
## out like the pause menu's. LEADERBOARDS opens the LeaderboardsScreen over the title.
## Emits intents only (play, online, garage, achievements); TitleScreens and the run act on them. Buttons are
## ScreenButtons (emulated mouse events: raw touch ids never index anything).

signal play(mode: StringName)
signal online()
## WP8.2: GARAGE (TitleScreens opens the GarageScreen).
signal garage()
## WP8.3: ACHIEVEMENTS (TitleScreens opens the AchievementsScreen).
signal achievements()
## The settings view closed (DONE); `to_hub`: it was opened from the online hub.
signal settings_closed(to_hub: bool)

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const MODE_JOURNEY := &"journey"
const MODE_DAILY := &"daily"
const TEXT_LOGO := "WESTBOUND"
const TEXT_TAGLINE := "CHASE THE SUN"
const TEXT_PLAY := "PLAY"
const TEXT_DAILY := "DAILY DRIVE"
const TEXT_ONLINE := "ONLINE"
const TEXT_ONLINE_NOTE := "LOOP PRACTICE · ROOMS SOON"
const TEXT_LEADERBOARDS := "LEADERBOARDS"
const TEXT_GARAGE := "GARAGE"
const TEXT_ACHIEVEMENTS := "ACHIEVEMENTS"
const TEXT_SOON := "SOON"
const TEXT_SETTINGS := "SETTINGS"
const TEXT_ACCOUNT := "ACCOUNT"
const TEXT_DONE := "DONE"
const TEXT_DATE := "%s %s %d"
const MONTHS: Array[String] = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
const WEEKDAYS: Array[String] = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
## Base sizes (canvas px at 100% text size).
const TAGLINE_PX := 18

var dim: ColorRect
var band: TitleBand
var logo: ScreenText
var tagline: ScreenText
var play_button: ScreenButton
var daily_button: ScreenButton
var online_button: ScreenButton
var boards_button: ScreenButton
var garage_button: ScreenButton
var achievements_button: ScreenButton
var settings_button: ScreenButton
var chip: TitleProfileChip
var settings: SettingsPanel
var profile: ProfilePanel
var done_button: ScreenButton
var account_button: ScreenButton
var leaderboards: LeaderboardsScreen
## The runs client for the leaderboards (null: the game's, NetRunsClient.ensure()).
var runs: NetRunsClient
## The run's input hub (gyro support in the settings, key muting in text fields).
var hub: PlayerInput:
	set(value):
		hub = value
		if settings != null:
			settings.hub = value
var settings_open: bool = false
var account_open: bool = false
## Settings written while the view was open (TitleScreens saves them).
var settings_dirty: bool = false
## The settings view came from the online hub (DONE goes back there).
var from_hub: bool = false
## Today's UTC date (year, month, day), set by open() or a test.
var date := {}

var _session: NetSession


func _init() -> void:
	super._init()
	name = "Title"
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.visible = false
	add_child(dim)
	band = TitleBand.new()
	band.name = "Band"
	add_child(band)
	logo = ScreenText.make(TEXT_LOGO, ScreenText.Face.DISPLAY, 96, ScreenText.Ink.TEXT)
	logo.name = "Logo"
	logo.outline = true
	add_child(logo)
	tagline = ScreenText.make(TEXT_TAGLINE, ScreenText.Face.LABEL, TAGLINE_PX, ScreenText.Ink.ACCENT)
	tagline.name = "Tagline"
	add_child(tagline)
	online_button = _button(TEXT_ONLINE, ScreenButton.Kind.NORMAL, online.emit)
	online_button.note = TEXT_ONLINE_NOTE
	daily_button = _button(TEXT_DAILY, ScreenButton.Kind.NORMAL, func() -> void: play.emit(MODE_DAILY))
	play_button = _button(TEXT_PLAY, ScreenButton.Kind.PRIMARY, func() -> void: play.emit(MODE_JOURNEY))
	boards_button = _button(TEXT_LEADERBOARDS, ScreenButton.Kind.NORMAL, open_leaderboards)
	settings_button = _button(TEXT_SETTINGS, ScreenButton.Kind.NORMAL, open_settings)
	garage_button = _button(TEXT_GARAGE, ScreenButton.Kind.NORMAL, garage.emit)
	achievements_button = _button(TEXT_ACHIEVEMENTS, ScreenButton.Kind.NORMAL, achievements.emit)
	chip = TitleProfileChip.new()
	chip.pressed.connect(func() -> void: open_account())
	add_child(chip)
	settings = SettingsPanel.new()
	settings.visible = false
	settings.changed.connect(func(_k: StringName) -> void: settings_dirty = true)
	add_child(settings)
	profile = ProfilePanel.new()
	profile.visible = false
	add_child(profile)
	account_button = _button(TEXT_ACCOUNT, ScreenButton.Kind.NORMAL, toggle_account)
	account_button.visible = false
	done_button = _button(TEXT_DONE, ScreenButton.Kind.PRIMARY, close_settings)
	done_button.visible = false


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 24)
	b.name = label.capitalize().replace(" ", "")
	b.pressed.connect(action)
	add_child(b)
	return b


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	_watch_session(null)


func _restyled() -> void:
	if settings.rows.is_empty():
		settings.build(tuning)
	settings.setup(style)
	settings.hub = hub
	profile.setup(style, tuning)
	band.setup(style)
	logo.size_px = tuning.font_logo_px
	logo.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	tagline.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	for b: ScreenButton in _buttons():
		b.size_px = tuning.font_screen_button_px
	if leaderboards != null:
		leaderboards.setup(style, tuning)
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	chip.refresh()
	_layout()


func _buttons() -> Array[ScreenButton]:
	return [play_button, daily_button, online_button, boards_button, settings_button, garage_button,
			achievements_button, done_button, account_button]


## The menu (from the top: the logo, then the column and the row, staggered in).
func open() -> void:
	if leaderboards != null:
		leaderboards.close(false)
	if date.is_empty():
		date = today_utc()
	daily_button.note = date_text(date)
	settings_open = false
	account_open = false
	from_hub = false
	_watch_session(NetSession.current)
	chip.refresh()
	_apply_mode()
	_layout()
	super.open()
	_slide_menu()


func _slide_menu() -> void:
	var dx := -tuning.screen_slide_px
	var i := 0
	for c: Control in [logo, tagline, online_button, daily_button, play_button, boards_button, settings_button,
			garage_button, achievements_button]:
		slide_in(c, dx, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)
		i += 1


func _closed() -> void:
	_watch_session(null)


## SETTINGS: the settings grid (GAME / AUDIO) with DONE and ACCOUNT.
func open_settings(to_hub: bool = false) -> void:
	from_hub = to_hub
	settings_open = true
	account_open = false
	settings.refresh()
	_apply_mode()
	_layout()
	slide_in(settings, 0.0, tuning.screen_fade_in_s, 0.0)


## The profile chip, or FRIENDS / CREW from the online hub: the account view (the
## ProfilePanel on `view`), or the settings when there is no session.
func open_account(view: int = ProfilePanel.View.ACCOUNT, to_hub: bool = false) -> void:
	open_settings(to_hub)
	if not profile.has_session():
		return
	toggle_account()
	if view != ProfilePanel.View.ACCOUNT:
		profile.show_view(view)
		_layout()


func close_settings() -> void:
	var to_hub := from_hub
	settings_open = false
	account_open = false
	from_hub = false
	_apply_mode()
	_layout()
	settings_closed.emit(to_hub)


## ACCOUNT <-> SETTINGS inside the settings view.
func toggle_account() -> void:
	account_open = not account_open
	if account_open:
		profile.hub = hub
		profile.open()
	_apply_mode()
	_layout()
	var shown: Control = settings
	if account_open:
		shown = profile
	slide_in(shown, 0.0, tuning.screen_fade_in_s, 0.0)


## LEADERBOARDS: the boards over the title (BACK comes back).
func open_leaderboards() -> void:
	var first := leaderboards == null
	leaderboards = LeaderboardsScreen.attach(self, leaderboards, _runs())
	if first:
		leaderboards.closed_by_player.connect(func() -> void:
			_apply_mode()
			_layout())
	dim.visible = true
	leaderboards.open_over(self)


func leaderboards_open() -> bool:
	return leaderboards != null and leaderboards.is_open()


func _runs() -> NetRunsClient:
	return runs if runs != null and is_instance_valid(runs) else NetRunsClient.ensure()


func _apply_mode() -> void:
	var menu := not settings_open
	for c: CanvasItem in [band, logo, tagline, play_button, daily_button, online_button, boards_button,
			settings_button, garage_button, achievements_button, chip]:
		c.visible = menu
	dim.visible = settings_open
	logo.text = TEXT_LOGO
	settings.visible = settings_open and not account_open
	profile.visible = settings_open and account_open
	account_button.visible = settings_open and (account_open or profile.has_session())
	account_button.text = TEXT_SETTINGS if account_open else TEXT_ACCOUNT
	done_button.visible = settings_open
	# The settings view's title: the logo's slot shows SETTINGS / ACCOUNT.
	logo.size_px = tuning.font_logo_px
	if settings_open:
		logo.visible = true
		logo.text = TEXT_ACCOUNT if account_open else TEXT_SETTINGS
		logo.size_px = tuning.font_title_px
	logo.update_minimum_size()
	logo.queue_redraw()


# ---------------------------------------------------------------- Session

func _watch_session(s: NetSession) -> void:
	if _session != null and is_instance_valid(_session):
		for sig: Signal in [_session.status_changed, _session.profile_changed]:
			if sig.is_connected(_on_session):
				sig.disconnect(_on_session)
	_session = s
	if s != null:
		s.status_changed.connect(_on_session)
		s.profile_changed.connect(_on_session)


func _on_session(_v: Variant = null) -> void:
	chip.refresh()
	_layout()


# ---------------------------------------------------------------- Input

func _unhandled_input(event: InputEvent) -> void:
	if not visible or leaderboards_open():
		return
	if settings_open:
		if event.is_action_pressed(&"ui_cancel") and not account_open:
			get_viewport().set_input_as_handled()
			close_settings()
		return
	if event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		play.emit(MODE_JOURNEY)


# ---------------------------------------------------------------- Date

## Today's UTC date: {year, month, day, weekday} (the Daily Drive's day).
static func today_utc() -> Dictionary:
	return Time.get_date_dict_from_system(true)


## "TUE SEP 29" for a date dictionary (Time's keys).
static func date_text(d: Dictionary) -> String:
	var m := clampi(int(d.get("month", 1)), 1, MONTHS.size()) - 1
	var w := clampi(int(d.get("weekday", 0)), 0, WEEKDAYS.size() - 1)
	return TEXT_DATE % [WEEKDAYS[w], MONTHS[m], int(d.get("day", 1))]


# ---------------------------------------------------------------- Layout

func _layout() -> void:
	if style == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	var bw := tuning.menu_button_width_px
	dim.position = Vector2.ZERO
	dim.size = full.size
	var ls := logo.get_combined_minimum_size()
	logo.position = a.position
	logo.size = ls
	if settings_open:
		# Like the pause menu's settings: the title and DONE / ACCOUNT on the top row.
		var dw := maxf(bw * DONE_WIDTH, done_button.get_combined_minimum_size().x)
		done_button.size = Vector2(dw, th)
		done_button.position = Vector2(a.end.x - dw, a.position.y + (ls.y - th) * 0.5)
		account_button.size = Vector2(dw, th)
		account_button.position = done_button.position - Vector2(dw + g, 0.0)
		var top := a.position.y + maxf(ls.y, th) + g * 2.0
		var body := Rect2(Vector2(a.position.x, top), Vector2(a.size.x, a.end.y - top))
		settings.position = Vector2.ZERO
		settings.size = full.size
		settings.layout(body)
		profile.position = Vector2.ZERO
		profile.size = full.size
		profile.layout(body)
		return
	var ts := tagline.get_combined_minimum_size()
	tagline.position = Vector2(a.position.x + g * TAGLINE_INDENT, a.position.y + ls.y - g)
	tagline.size = ts
	# The row along the bottom, left to right.
	var x := a.position.x
	var y := a.end.y - th
	var row_min := bw * ROW_MIN_WIDTH
	for b: ScreenButton in [boards_button, settings_button, garage_button, achievements_button]:
		var w := maxf(SocialUi.button_width(b, tuning), row_min)
		b.position = Vector2(x, y)
		b.size = Vector2(w, th)
		x += w + g
	# The column above it, up from the thumb: PLAY, DAILY DRIVE, ONLINE.
	var ph := tuning.primary_button_size_px.y
	y -= g * 2.0 + ph
	play_button.position = Vector2(a.position.x, y)
	play_button.size = Vector2(bw, ph)
	for b: ScreenButton in [daily_button, online_button]:
		y -= g + th
		b.position = Vector2(a.position.x, y)
		b.size = Vector2(bw, th)
	# The band: behind the logo and the column (the row may reach past it).
	band.position = Vector2.ZERO
	band.size = full.size
	band.width = maxf(tuning.title_band_width_px, a.position.x + maxf(bw, ls.x) + m)
	# The profile chip, top-right.
	var cw := chip.fit_width(a.end.x - (logo.position.x + ls.x + logo.size.y * tan(absf(style.tilt_rad)) + g * 2.0))
	chip.size = Vector2(cw, th)
	chip.position = Vector2(a.end.x - cw, a.position.y)


## Layout proportions: DONE's share of the menu width, the row's minimum share, the
## tagline's indent in spacing cells (it sits under the tilted logo's lean).
const DONE_WIDTH := 0.6   # lint: allow-number layout proportion
const ROW_MIN_WIDTH := 0.5   # lint: allow-number layout proportion
const TAGLINE_INDENT := 1.0
