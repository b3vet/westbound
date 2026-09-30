extends WBTest
## WP8.3: the achievements screen over the title (TitleScreens). ACHIEVEMENTS in the
## title's bottom row opens it and DONE (or Esc / Enter) comes back; the tabs (taps and
## Left / Right); each card's state: unlocked (gold, UNLOCKED, a full bar), in progress
## ("17 / 25" and its bar), a one-off (LOCKED), hidden (HIDDEN, ???, no bar; its name once
## unlocked); the count; mph with the units setting; it never writes the save; nothing
## draws once closed. Taps are touches with iOS-style ids (emulated mouse events). Spec:
## Garage and progression (Achievements); UI → Screens. docs/ACHIEVEMENTS.md → Screen.

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201

var t: Tuning
var cat: AchievementCatalog
var _nodes: Array[Node] = []
var _saved: Dictionary


func before_all() -> void:
	t = Tuning.load_default()
	cat = AchievementCatalog.load_path(AchievementTuning.load_default().catalog_path)


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	for k: String in [AchievementService.SECTION, Garage.SECTION_STATS, Garage.SECTION_UNLOCKS, Garage.SECTION_GARAGE]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Save.data = _saved
	Save.dirty = false
	Settings.reset_to_defaults()


func _title() -> TitleScreens:
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.append(ts)
	ts.set_screen(SCREEN, SCREEN)
	ts.show_state(Game.MENU)
	ts.finish_animations()
	return ts


func _open(ts: TitleScreens) -> AchievementsScreen:
	_tap(ts.title.achievements_button)
	ts.finish_animations()
	return ts.achievements


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _key(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _save_state() -> void:
	var sec := Save.section(AchievementService.SECTION)
	sec[AchievementTracker.KEY_UNLOCKED] = {"first_thread": 20300.0, "night_thread": 20301.0}
	sec[AchievementTracker.KEY_PROGRESS] = {"close_passes_run": 17.0, "top_speed_run": Units.kmh_to_mps(287.0),
			"multiplier_run": 32.7, "threads_total": 4.0}


# ---------------------------------------------------------------- Open and close

func test_the_title_row_has_achievements() -> void:
	var ts := _title()
	var b := ts.title.achievements_button
	check(b.visible and b.is_visible_in_tree(), "ACHIEVEMENTS on the title")
	eq(b.text, "ACHIEVEMENTS")
	near(b.position.y, ts.title.garage_button.position.y, 0.01, "in the bottom row with GARAGE")
	gt(b.position.x, ts.title.garage_button.position.x, "after GARAGE")
	check(SCREEN.encloses(b.get_global_rect()), "on screen")


func test_opens_from_the_title_and_done_comes_back() -> void:
	var ts := _title()
	check(ts.achievements == null, "nothing built before the first ACHIEVEMENTS")
	var a := _open(ts)
	if not check(a != null and a.visible, "ACHIEVEMENTS opens the screen"):
		return
	check(not ts.title.visible, "the title steps aside")
	check(ts.is_open(), "the title's layer counts it as open")
	_tap(a.done_button)
	ts.finish_animations()
	check(not a.visible, "DONE closes it")
	check(ts.title.visible, "back on the title")
	_open(ts)
	_key(&"ui_cancel")
	ts.finish_animations()
	check(not a.visible and ts.title.visible, "Esc closes it")
	_open(ts)
	_key(&"ui_accept")
	ts.finish_animations()
	check(not a.visible and ts.title.visible, "Enter closes it")
	ts.show_state(Game.COUNTDOWN)
	eq(ts.visible_item_count(), 0, "nothing draws once the run starts")


func test_tabs() -> void:
	var ts := _title()
	var a := _open(ts)
	eq(a.tab, 0)
	for i in cat.groups.size():
		_tap(a.tab_buttons[i])
		eq(a.tab, i, "tab %d by tap" % i)
		check(a.tab_buttons[i].selected, "shown selected")
		var defs := cat.in_group(cat.groups[i])
		var shown := 0
		for c in a.cards:
			if c.visible:
				shown += 1
		eq(shown, defs.size(), "tab %d shows its %d achievements" % [i, defs.size()])
		for d in defs:
			check(a.card(d.id) != null, "%s on tab %d" % [d.id, i])
	_key(&"ui_right")
	eq(a.tab, 0, "Right wraps to the first tab")
	_key(&"ui_left")
	eq(a.tab, cat.groups.size() - 1, "Left wraps to the last")


# ---------------------------------------------------------------- Card states

func test_card_states() -> void:
	_save_state()
	var ts := _title()
	var a := _open(ts)
	eq(a.count_text.text, "2 / %d UNLOCKED" % cat.achievements.size())
	var first := a.card(&"first_thread")
	eq(first.edge, ScreenPanel.Edge.GOLD, "unlocked: gold edge")
	eq(first.state_text.text, AchievementText.STATE_UNLOCKED, "unlocked: the word")
	check(first.bar.visible and first.bar.gold and first.bar.frac == 1.0, "unlocked: a full gold bar")
	eq(first.title_text.text, "NEEDLE")
	var close := a.card(&"close_passes_run")
	eq(close.state_text.text, "17 / 25", "the best run's close passes")
	near(close.bar.frac, 17.0 / 25.0, 1e-6, "its bar")
	check(not close.bar.gold, "accent while locked")
	eq(close.edge, ScreenPanel.Edge.IDLE)
	eq(a.card(&"top_speed_300").state_text.text, "287 / 300 KM/H")
	eq(a.card(&"multiplier_50").state_text.text, "32× / 50×")
	eq(a.card(&"threads_total").state_text.text, "4 / 100")
	var hair := a.card(&"hairline")
	eq(hair.title_text.text, AchievementText.TITLE_HIDDEN, "hidden: no name")
	eq(hair.desc_text.text, AchievementText.DESC_HIDDEN, "hidden: no line")
	eq(hair.state_text.text, AchievementText.STATE_HIDDEN)
	check(not hair.bar.visible, "hidden: no bar")
	a.show_tab(cat.groups.find(&"road"))
	var night := a.card(&"night_thread")
	eq(night.title_text.text, "NIGHT THREAD", "a hidden one shows its name once unlocked")
	eq(night.state_text.text, AchievementText.STATE_UNLOCKED)
	var coast := a.card(&"coast")
	eq(coast.state_text.text, AchievementText.STATE_LOCKED, "a one-off")
	check(not coast.bar.visible, "no bar for a one-off")
	eq(a.card(&"first_leg").state_text.text, AchievementText.STATE_LOCKED, "no '1 / 2' legs")


func test_mph() -> void:
	_save_state()
	Settings.set_value(&"units", &"mph")
	var ts := _title()
	var a := _open(ts)
	eq(a.card(&"top_speed_300").state_text.text, "178 / 186 MPH")
	eq(a.card(&"top_speed_300").desc_text.text, "REACH 186 MPH.")
	eq(a.card(&"hairline").desc_text.text, AchievementText.DESC_HIDDEN)


func test_profile_progress_from_the_garage() -> void:
	var s := Save.section(Garage.SECTION_STATS)
	s[MetaProfile.XP] = Progression.xp_to_reach(3, t.progression)   # below the second car (level 4)
	s[MetaProfile.DAILY_BEST_STREAK] = 3
	var ts := _title()
	var a := _open(ts)
	a.show_tab(cat.groups.find(&"career"))
	eq(a.card(&"level_10").state_text.text, "3 / 10", "the driver level")
	eq(a.card(&"daily_streak").state_text.text, "3 / 7", "the best Daily streak")
	eq(a.card(&"new_wheels").state_text.text, "1 / 2", "cars: the start car")


func test_never_writes_the_save() -> void:
	_save_state()
	Garage.profile()   # the garage's own start unlocks, recorded on its first read
	Save.dirty = false
	var before := JSON.stringify(Save.data)
	var ts := _title()
	var a := _open(ts)
	for i in cat.groups.size():
		a.show_tab(i)
	_tap(a.done_button)
	eq(JSON.stringify(Save.data), before, "read only")
	check(not Save.dirty, "nothing marked to write")
