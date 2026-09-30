extends WBTest
## WP8.2: the progression in the save (docs/SAVE.md → Sections: stats, unlocks, garage).
## The award is written with the run's end; everything survives the JSON round trip and
## the load path (SaveMigrations.migrate + normalize); a WP8.1-era (v2) or legacy v1 save
## gets its XP backfilled from its personal bests once; the save's shape needs no new
## version (the sections are additive: normalize keeps unknown top-level sections).

var t: Tuning
var cat: GarageCatalog
var _saved: Dictionary


func before_all() -> void:
	t = Tuning.load_default()
	cat = Garage.catalog()


func before_each() -> void:
	_saved = Save.data.duplicate(true)
	Save.data = SaveMigrations.fresh()


func after_each() -> void:
	Save.data = _saved
	Save.dirty = false


func _reload() -> void:
	var text := JSON.stringify(Save.data, "\t")
	var parsed: Variant = JSON.parse_string(text)
	Save.data = SaveMigrations.migrate(parsed as Dictionary)


func test_award_and_selection_survive_a_reload() -> void:
	var res := {RunStats.MODE: &"journey", RunStats.SCORE: Progression.xp_to_reach(t.progression.max_level, t.progression),
			RunStats.LEGS_COMPLETED: 5, RunStats.THREADS: 12, RunStats.COAST_REACHED: false}
	var award := Garage.award_run(res)
	eq(int(res[MetaProfile.R_XP_GAINED]), int(award[MetaProfile.R_XP_GAINED]), "merged into the payload")
	var p := Garage.profile()
	var viper := cat.slot(&"night_viper")
	check(p.select_car(viper.id))
	check(p.select_paint(viper.id, cat.paints[2].id))
	check(p.select_rim(viper.id, cat.rims[3].id))
	Garage.changed()
	var xp := p.xp()
	var unlocked := p.unlocks.size()
	_reload()
	eq(SaveMigrations.version_of(Save.data), SaveMigrations.VERSION, "no new version")
	var q := Garage.profile()
	eq(q.xp(), xp)
	eq(q.threads(), 12)
	eq(q.best_leg(), 6)
	eq(q.unlocks.size(), unlocked)
	eq(q.selected_slot(), viper)
	eq(Garage.selected_car_path(), viper.car_path)
	var look := Garage.selected_look(viper.car())
	check(look.paint.is_equal_approx(cat.paints[2].color))
	eq(look.rim, cat.rims[3])


func test_a_run_before_the_garage_existed_is_backfilled_once() -> void:
	var v1 := {"version": 1, "settings": {}, "bests": {"journey": 31000.0, "daily": 4000.0},
			"journeys": {"journey": {"count": 1.0, "best_time_s": 1800.0, "best_distance_m": 28000.0}}}
	Save.data = SaveMigrations.migrate(v1)
	var p := Garage.profile()
	eq(p.xp(), roundi(35000.0 * t.progression.xp_per_point), "a legacy player starts from their bests")
	check(p.coast_reached(), "and their journey to the coast")
	check(p.car_unlocked(cat.slot(&"brute_v8")), "reach leg %d follows from the coast" % t.progression.unlock_leg_milestone)
	Save.section(SaveMigrations.KEY_BESTS)["journey"] = 9_000_000
	eq(Garage.profile().xp(), p.xp(), "only once")


func test_unknown_keys_in_the_sections_are_kept() -> void:
	var doc := SaveMigrations.fresh()
	doc["garage"] = {"car": "falcon_gt", "from_a_newer_build": [1, 2]}
	doc["stats"] = {"xp": 10.0, "newer_stat": 3.0}
	Save.data = SaveMigrations.migrate(doc)
	Garage.profile().select_car(&"falcon_gt")
	_reload()
	eq(Save.section("garage").get("from_a_newer_build"), [1.0, 2.0])
	eq(Save.section("stats").get("newer_stat"), 3.0)
	eq(Garage.profile().xp(), 10)


func test_other_modes_and_no_record_leave_the_save_alone() -> void:
	var res := {RunStats.MODE: &"sandbox", RunStats.SCORE: 50000}
	Garage.award_run(res)
	eq(int(res[MetaProfile.R_XP_GAINED]), 0)
	eq(Garage.profile().xp(), 0)
	eq(Garage.profile().runs(), 0)
