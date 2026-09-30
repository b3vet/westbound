extends WBTest
## WP8.2: the profile over the save sections (MetaProfile): XP per run, level unlocks,
## the four milestone unlocks, the Daily Drive streak, selection rules (locked items can't
## be selected), the backfill for older saves, and a JSON round trip. Spec: Garage and
## progression; Save data. Thresholds come from tuning and the catalog. docs/GARAGE.md.

var t: ProgressionTuning
var cat: GarageCatalog


func before_all() -> void:
	t = Tuning.load_default().progression
	cat = GarageCatalog.load_path(t.garage_catalog_path)


func _fresh() -> MetaProfile:
	var p := MetaProfile.new({}, {}, {}, cat, t)
	p.refresh_unlocks()
	return p


func _res(mode: StringName, score: int, legs: int = 0, threads: int = 0, coast: bool = false) -> Dictionary:
	return {RunStats.MODE: mode, RunStats.SCORE: score, RunStats.LEGS_COMPLETED: legs, RunStats.THREADS: threads,
			RunStats.COAST_REACHED: coast}


func _slot(kind: StringName) -> GarageSlot:
	for s in cat.slots:
		if s.unlock == kind:
			return s
	return null


## The lowest unlock level of a level-gated item (car, paint or rim) above level 1.
func _first_level() -> int:
	var lo := t.max_level + 1
	for s in cat.slots:
		if s.unlock == GarageSlot.UNLOCK_LEVEL:
			lo = mini(lo, s.unlock_level)
	for p in cat.paints:
		if p.unlock_level > 1:
			lo = mini(lo, p.unlock_level)
	for r in cat.rims:
		if r.unlock_level > 1:
			lo = mini(lo, r.unlock_level)
	return lo


func test_a_fresh_profile_has_only_the_start_items() -> void:
	var p := _fresh()
	eq(p.level(), 1)
	eq(p.xp(), 0)
	for s in cat.slots:
		eq(p.car_unlocked(s), s.unlock == GarageSlot.UNLOCK_START, "car %s" % s.id)
	for pa in cat.paints:
		eq(p.paint_unlocked(pa), pa.unlock_level <= 1, "paint %s" % pa.id)
	for r in cat.rims:
		eq(p.rim_unlocked(r), r.unlock_level <= 1, "rim %s" % r.id)
	var sel := p.selected_slot()
	eq(sel.unlock, GarageSlot.UNLOCK_START, "the start car is selected")
	check(p.paint_for(sel.id).factory, "in its factory paint")
	check(p.rim_for(sel.id).model_default, "on its own rims")


func test_a_run_earns_its_banked_score_and_levels_up() -> void:
	var p := _fresh()
	var first := _first_level()
	var need := Progression.xp_to_reach(first, t)
	var a := p.record_run(_res(&"journey", need - 1))
	eq(int(a[MetaProfile.R_XP_GAINED]), need - 1)
	eq(int(a[MetaProfile.R_LEVEL]), first - 1)
	eq((a[MetaProfile.R_UNLOCKED] as Array).size(), 0, "nothing before the first threshold")
	a = p.record_run(_res(&"daily", 1))
	eq(int(a[MetaProfile.R_XP_TOTAL]), need)
	eq(int(a[MetaProfile.R_LEVEL_BEFORE]), first - 1)
	eq(int(a[MetaProfile.R_LEVEL]), first, "level up")
	var fresh: Array = a[MetaProfile.R_UNLOCKED]
	gt(fresh.size(), 0, "the first level unlock arrives")
	for id: String in fresh:
		check(p.is_unlocked(id))
	eq(p.runs(), 2)


func test_every_level_item_unlocks_at_its_level() -> void:
	var p := _fresh()
	for level in range(2, t.max_level + 1):
		var need := Progression.xp_to_reach(level, t) - p.xp()
		p.record_run(_res(&"journey", roundi(float(need) / t.xp_per_point)))
		eq(p.level(), level)
		for s in cat.slots:
			if s.unlock == GarageSlot.UNLOCK_LEVEL:
				eq(p.car_unlocked(s), level >= s.unlock_level, "car %s at level %d" % [s.id, level])
		for pa in cat.paints:
			eq(p.paint_unlocked(pa), level >= pa.unlock_level, "paint %s at level %d" % [pa.id, level])
		for r in cat.rims:
			eq(p.rim_unlocked(r), level >= r.unlock_level, "rim %s at level %d" % [r.id, level])
	for s in cat.slots:
		if s.unlock != GarageSlot.UNLOCK_LEVEL and s.unlock != GarageSlot.UNLOCK_START:
			check(not p.car_unlocked(s), "%s needs its milestone, not XP" % s.id)


func test_leg_and_coast_milestones() -> void:
	var p := _fresh()
	var leg := _slot(GarageSlot.UNLOCK_LEG)
	var coast := _slot(GarageSlot.UNLOCK_COAST)
	p.record_run(_res(&"journey", 10, t.unlock_leg_milestone - 2))
	check(not p.car_unlocked(leg), "one leg short")
	p.record_run(_res(&"loop", 10, 20))
	check(not p.car_unlocked(leg), "loop practice's sectors are not legs")
	var a := p.record_run(_res(&"daily", 10, t.unlock_leg_milestone - 1))
	check(p.car_unlocked(leg), "reach leg %d" % t.unlock_leg_milestone)
	check((a[MetaProfile.R_UNLOCKED] as Array).has(GarageCatalog.CAR + String(leg.id)), "announced")
	check(not p.car_unlocked(coast))
	p.record_run(_res(&"journey", 10, 8, 0, true))
	check(p.car_unlocked(coast), "reach the coast")
	eq(p.best_leg(), 9)


func test_lifetime_threads_milestone() -> void:
	var p := _fresh()
	var s := _slot(GarageSlot.UNLOCK_THREADS)
	var per := 7
	var n := 0
	while not p.car_unlocked(s):
		p.record_run(_res(&"journey", 100, 0, per))
		n += 1
		if n > t.unlock_lifetime_threads:
			break
	eq(n, ceili(float(t.unlock_lifetime_threads) / float(per)), "threads add up across runs")
	ge(p.threads(), t.unlock_lifetime_threads)
	p.record_run(_res(&"sandbox", 100, 0, 50))
	eq(p.threads(), n * per, "runs outside the XP modes do not count")


func test_daily_streak_milestone() -> void:
	var p := _fresh()
	var s := _slot(GarageSlot.UNLOCK_DAILY_STREAK)
	var day := 20000
	for i in t.unlock_daily_streak_days - 1:
		p.record_run(_res(&"daily", 10), day + i)
		p.record_run(_res(&"daily", 10), day + i)   # twice on a day: still one day
	eq(p.daily_streak(), t.unlock_daily_streak_days - 1)
	check(not p.car_unlocked(s), "one day short")
	p.record_run(_res(&"journey", 10), day + t.unlock_daily_streak_days)
	eq(p.daily_streak(), t.unlock_daily_streak_days - 1, "Journey runs don't touch the streak")
	p.record_run(_res(&"daily", 10), day + t.unlock_daily_streak_days + 1)
	eq(p.daily_streak(), 1, "a missed day starts over")
	check(not p.car_unlocked(s))
	var p2 := _fresh()
	for i in t.unlock_daily_streak_days:
		p2.record_run(_res(&"daily", 10), day + i)
	check(p2.car_unlocked(s), "%d days in a row" % t.unlock_daily_streak_days)
	eq(p2.daily_best_streak(), t.unlock_daily_streak_days)


func test_locked_items_cannot_be_selected() -> void:
	var p := _fresh()
	var start := p.selected_slot()
	for s in cat.slots:
		if not p.car_unlocked(s):
			check(not p.select_car(s.id), "locked %s can't be selected" % s.id)
	eq(p.selected_slot(), start, "the selection stays")
	for pa in cat.paints:
		if not p.paint_unlocked(pa):
			check(not p.select_paint(start.id, pa.id), "locked paint %s" % pa.id)
	for r in cat.rims:
		if not p.rim_unlocked(r):
			check(not p.select_rim(start.id, r.id), "locked rim %s" % r.id)
	check(p.paint_for(start.id).factory and p.rim_for(start.id).model_default, "still the factory look")
	check(not p.select_car(&"no_such_car"))
	check(not p.select_paint(start.id, &"no_such_paint"))


func test_placeholders_never_drive_even_when_unlocked() -> void:
	var p := _fresh()
	p.record_run(_res(&"journey", Progression.xp_to_reach(t.max_level, t) * 2, 20, t.unlock_lifetime_threads, true))
	for s in cat.slots:
		if s.has_car():
			continue
		if s.unlock == GarageSlot.UNLOCK_DAILY_STREAK:
			continue
		check(p.car_unlocked(s), "%s's unlock is recorded" % s.id)
		check(not p.select_car(s.id), "but a placeholder can't be driven")
	check(p.selected_slot().has_car())


func test_selection_per_car_and_its_look() -> void:
	var p := _fresh()
	p.record_run(_res(&"journey", Progression.xp_to_reach(t.max_level, t), 20, 0, true))
	var a := cat.slots[0]
	var b: GarageSlot = null
	for s in cat.slots:
		if s != a and p.drivable(s):
			b = s
			break
	if not check(b != null, "a second drivable car"):
		return
	var paint := cat.paints[cat.paints.size() - 1]
	var rim := cat.rims[cat.rims.size() - 1]
	check(p.select_paint(a.id, paint.id))
	check(p.select_rim(a.id, rim.id))
	check(p.select_car(b.id))
	eq(p.selected_slot(), b)
	check(p.paint_for(b.id).factory, "each car keeps its own paint")
	eq(p.paint_for(a.id), paint)
	eq(p.rim_for(a.id), rim)
	var look := p.look_for(a.id)
	check(look.paint.is_equal_approx(paint.color_for(a.car())))
	eq(look.rim, rim)
	var fl := p.look_for(b.id)
	check(fl.paint.is_equal_approx(b.car().default_paint), "FACTORY is the car's own colour")
	check(not fl.swaps_rims())


func test_saved_choices_that_are_not_unlocked_fall_back() -> void:
	var garage := {MetaProfile.CAR: "night_viper", MetaProfile.LOOKS: {"falcon_gt": {"paint": "obsidian", "rim": "gold"}}}
	var p := MetaProfile.new({}, {}, garage, cat, t)
	p.refresh_unlocks()
	eq(p.selected_slot().unlock, GarageSlot.UNLOCK_START, "a locked saved car falls back to the start car")
	check(p.paint_for(&"falcon_gt").factory and p.rim_for(&"falcon_gt").model_default, "and a locked look to factory")
	var junk := MetaProfile.new({MetaProfile.XP: "lots"}, {}, {MetaProfile.LOOKS: 5}, cat, t)
	junk.refresh_unlocks()
	eq(junk.xp(), 0, "a damaged value reads as 0")
	check(junk.paint_for(&"falcon_gt").factory)


func test_unlocks_are_never_revoked() -> void:
	var p := _fresh()
	p.record_run(_res(&"journey", Progression.xp_to_reach(_first_level(), t)))
	var had := p.unlocks.size()
	var harder := t.duplicate() as ProgressionTuning
	harder.level_xp_base *= 100
	var q := MetaProfile.new(p.stats, p.unlocks, p.garage, cat, harder)
	q.refresh_unlocks()
	eq(q.unlocks.size(), had, "a retune never takes an unlock away")


func test_backfill_from_an_older_save() -> void:
	var p := MetaProfile.new({}, {}, {}, cat, t)
	check(p.backfill({"journey": 40000.0, "daily": 9000, "bad": "x"}, {"journey": {"count": 2.0}}))
	eq(p.xp(), roundi(49000.0 * t.xp_per_point), "the personal bests are a lower bound of the banked score")
	check(p.coast_reached(), "a recorded journey reached the coast")
	check(not p.backfill({"journey": 1e9}, {}), "once per save")
	eq(p.xp(), roundi(49000.0 * t.xp_per_point))
	var q := MetaProfile.new({MetaProfile.XP: 5}, {}, {}, cat, t)
	q.backfill({"journey": 40000}, {})
	eq(q.xp(), 5, "never over existing XP")


func test_json_round_trip() -> void:
	var p := _fresh()
	p.record_run(_res(&"journey", Progression.xp_to_reach(t.max_level, t), 20, 3, true))
	p.record_run(_res(&"daily", 10), 777)
	var s := cat.slots[1]
	p.select_car(s.id)
	p.select_paint(s.id, cat.paints[3].id)
	p.select_rim(s.id, cat.rims[2].id)
	var doc := {"stats": p.stats, "unlocks": p.unlocks, "garage": p.garage}
	var back: Dictionary = JSON.parse_string(JSON.stringify(doc))
	var q := MetaProfile.new(back["stats"], back["unlocks"], back["garage"], cat, t)
	eq(q.xp(), p.xp())
	eq(q.level(), p.level())
	eq(q.threads(), 3)
	eq(q.best_leg(), 21)
	check(q.coast_reached())
	eq(q.daily_streak(), 1)
	eq(q.selected_slot(), s)
	eq(q.paint_for(s.id), cat.paints[3])
	eq(q.rim_for(s.id), cat.rims[2])
	eq(q.refresh_unlocks().size(), 0, "nothing new after the round trip")
	eq(q.unlocks.size(), p.unlocks.size())
