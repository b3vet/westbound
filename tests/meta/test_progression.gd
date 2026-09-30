extends WBTest
## WP8.2: the driver level math and the garage catalog. Spec: Garage and progression
## ("Roster. 8 player cars at launch; 1 unlocked at start"; "Driver level. Lifetime banked
## score feeds a driver level. Levels unlock cars, paint colors and rims"; "Milestone
## unlocks ... reach leg 4, reach the coast, a 7-day Daily Drive streak, 100 lifetime
## threads"); Modular car convention (rim budget). Every number comes from tuning and the
## catalog data, never from the test. docs/GARAGE.md.

var t: ProgressionTuning
var cat: GarageCatalog


func before_all() -> void:
	t = Tuning.load_default().progression
	cat = GarageCatalog.load_path(t.garage_catalog_path)


func _run(mode: StringName, score: int) -> Dictionary:
	return {RunStats.MODE: mode, RunStats.SCORE: score}


# ---------------------------------------------------------------- XP

func test_xp_is_the_banked_score() -> void:
	eq(Progression.xp_for_run(_run(&"journey", 12345), t), roundi(12345.0 * t.xp_per_point))
	eq(Progression.xp_for_run(_run(&"daily", 800), t), roundi(800.0 * t.xp_per_point))
	for m in t.xp_modes:
		gt(Progression.xp_for_run(_run(m, 1000), t), 0, "%s earns XP" % m)
	eq(Progression.xp_for_run(_run(&"sandbox", 5000), t), 0, "other modes earn nothing")
	eq(Progression.xp_for_run(_run(&"journey", -40), t), 0, "never negative")
	eq(Progression.xp_for_run({}, t), 0, "no mode, no XP")
	var tt := t.duplicate() as ProgressionTuning
	tt.xp_per_point = 2.0
	eq(Progression.xp_for_run(_run(&"journey", 100), tt), 200, "xp_per_point scales it")


func test_level_curve() -> void:
	eq(Progression.xp_to_reach(1, t), 0)
	eq(Progression.xp_to_reach(0, t), 0)
	eq(Progression.xp_to_reach(2, t), t.level_xp_base, "level 2 costs the base")
	eq(Progression.level_for_xp(0, t), 1, "everyone starts at level 1")
	var prev_step := 0
	for level in range(2, t.max_level + 1):
		var need := Progression.xp_to_reach(level, t)
		var step := need - Progression.xp_to_reach(level - 1, t)
		gt(step, 0, "level %d costs more XP than %d" % [level, level - 1])
		ge(step, prev_step, "each level costs at least as much as the last (%d)" % level)
		prev_step = step
		eq(Progression.level_for_xp(need, t), level, "exactly the threshold reaches %d" % level)
		eq(Progression.level_for_xp(need - 1, t), level - 1, "one XP short stays at %d" % (level - 1))
	eq(Progression.level_for_xp(Progression.xp_to_reach(t.max_level, t) * 10, t), t.max_level, "capped")
	eq(Progression.xp_to_next(Progression.xp_to_reach(t.max_level, t), t), 0)
	near(Progression.level_progress(Progression.xp_to_reach(t.max_level, t), t), 1.0, 1e-9)


func test_level_progress_and_xp_to_next() -> void:
	var lo := Progression.xp_to_reach(3, t)
	var hi := Progression.xp_to_reach(4, t)
	near(Progression.level_progress(lo, t), 0.0, 1e-9)
	near(Progression.level_progress(roundi(float(lo + hi) * 0.5), t), 0.5, 0.01)
	eq(Progression.xp_to_next(lo, t), hi - lo)
	eq(Progression.xp_to_next(hi - 1, t), 1)


# ---------------------------------------------------------------- Catalog

func test_roster_has_the_spec_slots_and_rules() -> void:
	eq(cat.slots.size(), t.roster_size, "8 roster slots")
	var start := 0
	var kinds := {}
	var ids := {}
	for s in cat.slots:
		check(GarageSlot.UNLOCKS.has(s.unlock), "%s: a known unlock rule" % s.id)
		check(not ids.has(s.id), "%s: unique id" % s.id)
		ids[s.id] = true
		kinds[s.unlock] = int(kinds.get(s.unlock, 0)) + 1
		if s.unlock == GarageSlot.UNLOCK_START:
			start += 1
			check(s.has_car(), "the start car is a real car")
		if s.unlock == GarageSlot.UNLOCK_LEVEL:
			check(s.unlock_level > 1 and s.unlock_level <= t.max_level, "%s: a reachable level" % s.id)
	eq(start, t.cars_unlocked_at_start, "1 unlocked at start")
	for k: StringName in [GarageSlot.UNLOCK_LEG, GarageSlot.UNLOCK_COAST, GarageSlot.UNLOCK_DAILY_STREAK,
			GarageSlot.UNLOCK_THREADS]:
		eq(int(kinds.get(k, 0)), 1, "one car unlocks from the %s milestone" % k)
	ge(int(kinds.get(GarageSlot.UNLOCK_LEVEL, 0)), 1, "levels unlock cars too")


func test_every_real_car_is_drivable_and_verifiable() -> void:
	var seen := {}
	for s in cat.slots:
		if not s.has_car():
			continue
		var c := s.car()
		if not check(c != null, "%s loads" % s.car_path):
			continue
		eq(s.id, c.id, "the slot id is the CarDef id (the save and the leaderboard car)")
		check(Run.CAR_PATHS.has(s.car_path), "%s is in Run.CAR_PATHS (the replay verifier finds it)" % s.id)
		seen[s.car_path] = true
	for p in Run.CAR_PATHS:
		check(seen.has(p), "%s has a roster slot" % p)


func test_paints_and_rims() -> void:
	var factory := 0
	var ids := {}
	for p in cat.paints:
		check(not ids.has(p.id), "paint %s unique" % p.id)
		ids[p.id] = true
		check(not p.display_name.is_empty(), "paint %s named (never colour alone)" % p.id)
		check(p.unlock_level >= 1 and p.unlock_level <= t.max_level)
		if p.factory:
			factory += 1
			eq(p.unlock_level, 1, "the factory paint is there from the start")
	eq(factory, 1, "one FACTORY paint")
	var stock := 0
	ids.clear()
	for r in cat.rims:
		check(not ids.has(r.id), "rim %s unique" % r.id)
		ids[r.id] = true
		check(r.unlock_level >= 1 and r.unlock_level <= t.max_level)
		if r.model_default:
			stock += 1
			eq(r.unlock_level, 1, "the stock rims are there from the start")
		else:
			var mesh := CarModel.build_styled_rim_mesh(0.3, 0.25, r)
			le(CarModel.triangle_count(mesh), t.rim_tris, "rim %s within the 800-triangle budget" % r.id)
	eq(stock, 1, "one stock rim (the model's own)")
	gt(cat.paints.size(), 1, "paint colours to unlock")
	gt(cat.rims.size(), 1, "rims to unlock")


func test_item_names() -> void:
	eq(cat.item_name("car/falcon_gt"), "FALCON GT")
	for s in cat.slots:
		if not s.has_car():
			eq(cat.item_name(GarageCatalog.CAR + String(s.id)), GarageCatalog.TEXT_COMING_SOON, "placeholders are marked")
	check(cat.item_name("paint/" + String(cat.paints[1].id)).ends_with(" PAINT"))
	check(cat.item_name("rim/" + String(cat.rims[1].id)).ends_with(" RIMS"))
	eq(cat.item_name("nothing/x"), "")
