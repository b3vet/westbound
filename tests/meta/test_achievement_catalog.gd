extends WBTest
## WP8.3: the achievement catalog (data/achievements/catalog.tres). About 25 achievements
## (ProgressionTuning.achievement_count), the spec's examples among them (first thread, 50×
## multiplier, a clean journey, a full night survived, 300 km/h), every one with a known
## metric, a tab, readable text in upper case with its numbers filled in, a platform id
## for Game Center and Play Games, and board ids for the optional mirror. Spec: Garage and
## progression (Achievements). docs/ACHIEVEMENTS.md.

var at: AchievementTuning
var cat: AchievementCatalog


func before_all() -> void:
	at = AchievementTuning.load_default()
	cat = AchievementCatalog.load_path(at.catalog_path)


func test_about_twenty_five() -> void:
	if not check(cat != null, "the catalog loads"):
		return
	eq(cat.achievements.size(), Tuning.load_default().progression.achievement_count, "the spec's 'about 25'")


func test_the_spec_examples_are_there() -> void:
	# "first thread, 50× multiplier, a clean journey, a full night survived, 300 km/h"
	var first := cat.find(&"first_thread")
	check(first != null and first.metric == &"threads_total" and first.threshold == 1.0, "first thread")
	var fifty := cat.find(&"multiplier_50")
	check(fifty != null and fifty.metric == &"multiplier_run" and fifty.threshold == 50.0, "50× multiplier")
	var clean := cat.find(&"clean_journey")
	check(clean != null and clean.metric == &"clean_coast_run", "a clean journey")
	var night := cat.find(&"night_survived")
	check(night != null and night.metric == &"nights_run", "a full night survived")
	var speed := cat.find(&"top_speed_300")
	check(speed != null and speed.metric == &"top_speed_run" and speed.threshold == 300.0
			and speed.unit == AchievementDef.Unit.SPEED, "300 km/h (km/h in data)")


func test_every_achievement_is_well_formed() -> void:
	var ids := {}
	var gc := {}
	var gp := {}
	for a in cat.achievements:
		var what := String(a.id)
		check(not ids.has(a.id), "%s: unique id" % what)
		ids[a.id] = true
		check(AchievementTracker.metric_index(a.metric) >= 0, "%s: known metric %s" % [what, a.metric])
		check(cat.groups.has(a.group), "%s: a tab (%s)" % [what, a.group])
		gt(a.threshold, 0.0, "%s: a threshold" % what)
		check(not a.title.is_empty() and a.title == a.title.to_upper(), "%s: an upper-case title" % what)
		var line := AchievementText.description(a, cat, false)
		check(not line.is_empty() and line == line.to_upper(), "%s: an upper-case line (%s)" % [what, line])
		check(not a.game_center_id.is_empty() and not gc.has(a.game_center_id), "%s: a unique Game Center id" % what)
		check(not a.play_games_id.is_empty() and not gp.has(a.play_games_id), "%s: a unique Play Games id" % what)
		gc[a.game_center_id] = true
		gp[a.play_games_id] = true
		for miles: bool in [false, true]:
			var d := AchievementText.description(a, cat, miles)
			check(not d.contains("{") and not d.contains("}"), "%s: every placeholder filled (%s)" % [what, d])


func test_tabs_fit_the_grid() -> void:
	eq(cat.group_titles.size(), cat.groups.size(), "a title per tab")
	var per_tab := at.screen_columns * at.screen_rows
	var total := 0
	for g in cat.groups:
		var n := cat.in_group(g).size()
		gt(n, 0, "tab %s has achievements" % g)
		le(n, per_tab, "tab %s fits one grid (%d)" % [g, per_tab])
		total += n
	eq(total, cat.achievements.size(), "every achievement is on a tab")


func test_some_are_hidden_and_most_are_not() -> void:
	var hidden := 0
	for a in cat.achievements:
		if a.hidden:
			hidden += 1
	gt(hidden, 0, "a few hidden ones")
	lt(float(hidden), float(cat.achievements.size()) * 0.5, "most are visible")


func test_numbers_in_the_players_units() -> void:
	var speed := cat.find(&"top_speed_300")
	eq(AchievementText.description(speed, cat, false), "REACH 300 KM/H.")
	eq(AchievementText.description(speed, cat, true), "REACH 186 MPH.")
	near(AchievementCatalog.internal_threshold(speed), Units.kmh_to_mps(300.0), 1e-9, "m/s in the tracker")
	var hair := cat.find(&"hairline")
	eq(AchievementText.description(hair, cat, false), "A CLOSE PASS UNDER 25 CM.")
	eq(AchievementText.description(hair, cat, true), "A CLOSE PASS UNDER 10 IN.")
	eq(AchievementText.description(cat.find(&"big_bank"), cat, false), "BANK A 50,000 CHAIN.")
	eq(AchievementText.description(cat.find(&"multiplier_50"), cat, false), "REACH A 50× MULTIPLIER.")
	eq(AchievementText.description(hair, cat, false, false), AchievementText.DESC_HIDDEN, "hidden while locked")
	eq(AchievementText.title(hair, false), AchievementText.TITLE_HIDDEN)
	eq(AchievementText.title(hair, true), "HAIRLINE")


func test_state_lines() -> void:
	var close := cat.find(&"close_passes_run")
	eq(AchievementText.state(close, 17.0, 25.0, false, false), "17 / 25")
	eq(AchievementText.state(close, 40.0, 25.0, false, false), "25 / 25", "never past the goal")
	eq(AchievementText.state(close, 25.0, 25.0, true, false), AchievementText.STATE_UNLOCKED)
	var speed := cat.find(&"top_speed_300")
	var th := AchievementCatalog.internal_threshold(speed)
	eq(AchievementText.state(speed, Units.kmh_to_mps(287.0), th, false, false), "287 / 300 KM/H")
	eq(AchievementText.state(speed, Units.kmh_to_mps(287.0), th, false, true), "178 / 186 MPH")
	eq(AchievementText.state(cat.find(&"coast"), 0.0, 1.0, false, false), AchievementText.STATE_LOCKED, "a one-off")
	eq(AchievementText.state(cat.find(&"first_leg"), 1.0, 2.0, false, false), AchievementText.STATE_LOCKED,
			"no '1 / 2' for the first checkpoint")
	eq(AchievementText.state(cat.find(&"hairline"), 0.0, 1.0, false, false), AchievementText.STATE_HIDDEN)
	eq(AchievementText.state(cat.find(&"multiplier_50"), 32.7, 50.0, false, false), "32× / 50×")
	check(not AchievementText.has_bar(cat.find(&"hairline"), 1.0, false), "no bar on a hidden one")
	check(AchievementText.has_bar(close, 25.0, false), "a bar with progress")


func test_platform_board_ids() -> void:
	check(not cat.mirror_boards, "the platform boards are retired (multiplayer handoff): off by default")
	check(cat.mirror_achievements, "achievements stay on the platform services")
	for b: StringName in [AchievementCatalog.BOARD_JOURNEY, AchievementCatalog.BOARD_DAILY, AchievementCatalog.BOARD_DISTANCE]:
		check(not String(cat.game_center_boards.get(b, "")).is_empty(), "Game Center board %s" % b)
		check(not String(cat.play_games_boards.get(b, "")).is_empty(), "Play Games board %s" % b)
