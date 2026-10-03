class_name AchievementsScreen
extends RunScreen
## The achievements screen (WP8.3). Spec: Garage and progression ("About 25
## achievements"); UI → Screens (title: Play, Daily Drive, Garage, Leaderboards,
## Settings); Design system (left-anchored, faceted, speed-tilted titles); Accessibility
## (text size 100% / 125%; colour never the only cue). docs/ACHIEVEMENTS.md → Screen,
## docs/SCREENS.md → Achievements.
##
## Over the title's attract drive (TitleScreens builds it on the first ACHIEVEMENTS):
##   - top row: ACHIEVEMENTS (display face, speed-tilted), "12 / 25 UNLOCKED", DONE;
##   - the tabs DRIVING / THE ROAD / CAREER (AchievementCatalog.groups);
##   - the tab's achievements in a grid (achievements.screen_columns × screen_rows) of
##     AchievementsCard: title, state or progress, description, bar.
## Reads the save (the unlocked ids) and the service's tracker (the progress; a snapshot
## of the save and the garage when no service runs); never writes. Keys: Esc / Enter =
## DONE, Left / Right = the tab. Touch: ScreenButtons (emulated mouse events, never a raw
## touch index). Emits `done`; TitleScreens goes back to the title.

signal done()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_TITLE := "ACHIEVEMENTS"
const TEXT_DONE := "DONE"
const TEXT_COUNT := "%d / %d UNLOCKED"

var ach: AchievementTuning
var catalog: AchievementCatalog
var tracker: AchievementTracker
var tab: int = 0
var miles: bool = false

var dim: ColorRect
var title_text: ScreenText
var count_text: ScreenText
var done_button: ScreenButton
var tab_buttons: Array[ScreenButton] = []
## A pool of columns × rows cards, filled with the tab's achievements.
var cards: Array[AchievementsCard] = []

var _unlocked_ids: Dictionary = {}


func _init() -> void:
	super._init()
	name = "Achievements"
	modal = true
	pad_focus = false   # the arrows (D-pad, stick) switch the tabs themselves
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	title_text = ScreenText.make(TEXT_TITLE, ScreenText.Face.DISPLAY, 60, ScreenText.Ink.TEXT)
	title_text.name = "Title"
	title_text.outline = true
	add_child(title_text)
	count_text = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	count_text.name = "Count"
	count_text.tabular = true
	count_text.align = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(count_text)
	done_button = ScreenButton.make(TEXT_DONE, ScreenButton.Kind.PRIMARY, 24)
	done_button.name = "Done"
	done_button.pressed.connect(close_screen)
	add_child(done_button)


## Builds the tabs and the cards (once) and styles them.
func _restyled() -> void:
	if ach == null:
		ach = AchievementTuning.load_default()
		catalog = AchievementCatalog.load_path(ach.catalog_path)
		_build()
	title_text.size_px = tuning.font_title_px
	title_text.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	done_button.size_px = tuning.font_screen_button_px
	for b in tab_buttons:
		b.size_px = tuning.font_screen_button_px
	for c in cards:
		c.setup_card(style, ach)
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	_layout()


func _build() -> void:
	for i in catalog.groups.size():
		var b := ScreenButton.make(catalog.group_title(catalog.groups[i]), ScreenButton.Kind.OPTION, 24)
		b.name = "Tab%d" % i
		b.pressed.connect(show_tab.bind(i))
		add_child(b)
		b.setup(style)
		tab_buttons.append(b)
	for i in maxi(ach.screen_columns * ach.screen_rows, 1):
		var c := AchievementsCard.new()
		c.name = "Card%d" % i
		c.visible = false
		add_child(c)
		cards.append(c)


# ---------------------------------------------------------------- Open / close

## Opens on the first tab with the save's unlocks and the progress now.
func open() -> void:
	miles = RunScreens._miles()
	reduced_motion = RunScreens._reduced_motion()
	tab = 0
	refresh()
	super.open()
	var shown: Array[Control] = [title_text, count_text]
	for c in cards:
		if c.visible:
			shown.append(c)
	for i in shown.size():
		slide_in(shown[i], -tuning.screen_slide_px, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)


func close_screen() -> void:
	close(false)
	done.emit()


func show_tab(t: int) -> void:
	tab = clampi(t, 0, maxi(catalog.groups.size() - 1, 0))
	refresh()


## The tracker the screen reads: the running service's, else one built from the save
## and the garage (nothing is recorded from it).
static func snapshot(cat: AchievementCatalog) -> AchievementTracker:
	var svc := AchievementService.current
	if svc != null and is_instance_valid(svc) and svc.tracker != null and svc.catalog == cat:
		return svc.tracker
	var t := AchievementTracker.new(cat)
	t.bind(Save.section(AchievementService.SECTION))
	var p := Garage.profile()
	var cars := 0
	for s in p.catalog.slots:
		if s.has_car() and p.car_unlocked(s):
			cars += 1
	t.set_profile(p.level(), cars, p.daily_best_streak(), p.threads())
	t.clear_pending()
	return t


# ---------------------------------------------------------------- Refresh

## Every card of the tab, the tabs and the count from the save and the tracker.
func refresh() -> void:
	if catalog == null:
		return
	tracker = snapshot(catalog)
	var u: Variant = Save.section(AchievementService.SECTION).get(AchievementTracker.KEY_UNLOCKED)
	_unlocked_ids = u if u is Dictionary else {}
	var total := 0
	for a in catalog.achievements:
		if _unlocked_ids.has(String(a.id)):
			total += 1
	count_text.text = TEXT_COUNT % [total, catalog.achievements.size()]
	for i in tab_buttons.size():
		tab_buttons[i].selected = i == tab
	var group: StringName = catalog.groups[tab] if tab < catalog.groups.size() else &""
	var defs := catalog.in_group(group)
	for k in cards.size():
		var c := cards[k]
		c.visible = k < defs.size()
		if not c.visible:
			continue
		var d := defs[k]
		var i := catalog.index_of(d.id)
		c.show_achievement(d, _unlocked_ids.has(String(d.id)), tracker.value_of(i), tracker.threshold_of(i),
				catalog, miles)
	_layout()


## The card showing achievement `id` on the current tab (null when not on it).
func card(achievement_id: StringName) -> AchievementsCard:
	for c in cards:
		if c.visible and c.def != null and c.def.id == achievement_id:
			return c
	return null


# ---------------------------------------------------------------- Input

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not is_open():
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		close_screen()
	elif event.is_action_pressed(&"ui_left") or event.is_action_pressed(&"ui_right"):
		get_viewport().set_input_as_handled()
		show_tab(posmod(tab + (-1 if event.is_action_pressed(&"ui_left") else 1), maxi(catalog.groups.size(), 1)))
	elif event.is_action_pressed(PadNav.TAB_PREV) or event.is_action_pressed(PadNav.TAB_NEXT):
		get_viewport().set_input_as_handled()
		show_tab(posmod(tab + (-1 if event.is_action_pressed(PadNav.TAB_PREV) else 1), maxi(catalog.groups.size(), 1)))


# ---------------------------------------------------------------- Dev (snaps)

## The preview's hook: --tab=<index>, then settled.
func snap_setup(args: Dictionary) -> void:
	show_tab(int(args.get("tab", 0)))
	finish_animations()


# ---------------------------------------------------------------- Layout

func _layout() -> void:
	if style == null or ach == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	dim.position = Vector2.ZERO
	dim.size = full.size
	# Top row: ACHIEVEMENTS, the count, DONE.
	var ts := title_text.get_combined_minimum_size()
	title_text.position = a.position
	title_text.size = ts
	var dw := maxf(tuning.menu_button_width_px * DONE_WIDTH, SocialUi.button_width(done_button, tuning))
	done_button.size = Vector2(dw, th)
	done_button.position = Vector2(a.end.x - dw, a.position.y + (ts.y - th) * 0.5)
	var cs := count_text.get_combined_minimum_size()
	count_text.size = cs
	count_text.position = Vector2(done_button.position.x - g * 3.0 - cs.x, a.position.y + (ts.y - cs.y) * 0.5)
	# The tabs.
	var top := a.position.y + maxf(ts.y, th) + g * 2.0
	var tw := tuning.menu_button_width_px * TAB_WIDTH
	for b in tab_buttons:
		tw = maxf(tw, SocialUi.button_width(b, tuning))
	for i in tab_buttons.size():
		tab_buttons[i].position = Vector2(a.position.x + float(i) * (tw + g), top)
		tab_buttons[i].size = Vector2(tw, th)
	# The grid: as tall as the cards need, never past the safe area.
	var grid_top := top + th + g * 2.0
	var cols := maxi(ach.screen_columns, 1)
	var rows := maxi(ach.screen_rows, 1)
	var cw := (a.size.x - g * float(cols - 1)) / float(cols)
	var want := 0.0
	for c in cards:
		want = maxf(want, c.desired_height())
	var ch := minf(want, (a.end.y - grid_top - g * float(rows - 1)) / float(rows))
	for k in cards.size():
		@warning_ignore("integer_division")
		var row := k / cols
		cards[k].position = Vector2(a.position.x + float(k % cols) * (cw + g), grid_top + float(row) * (ch + g))
		cards[k].size = Vector2(cw, ch)
		cards[k].layout_card()


## DONE's share of the menu width; a tab's least share of it.
const DONE_WIDTH := 0.6   # lint: allow-number layout proportion
const TAB_WIDTH := 0.5
