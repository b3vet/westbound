extends "res://tests/integration/run_harness.gd"
## WP8.2, the M8 gate "a fresh install progresses to its first unlock" (spec:
## Implementation milestones → M8), through the real path: the Run with a weaving,
## boosting bot in real traffic, the real scoring and banking, the crash, the results,
## Garage.award_run into the (in-memory) save, the unlock. Spec: Garage and progression
## ("Lifetime banked score feeds a driver level. Levels unlock cars, paint colors and
## rims").
##
## Fast tier: one short run from a fresh save: its XP is exactly its banked score, and
## the save's stats and the results payload carry it. Soak tier (the gate): three fresh
## installs play beginner-length runs, one after another, until the first unlock arrives,
## within FIRST_UNLOCK_MAX_RUNS runs. Banking is lumpy (the chain banks at the first
## checkpoint, about 70 s in), so the gate needs the full-length runs of the soak.

## A beginner's run (s of driving before the crash), and how many of them the first
## unlock may take (the gate's "plausible"). WP9.6 (orchestrator, PL-4): 3 -> 4, XP
## unchanged: N8.2's traces put one install's first unlock on run 4 (runs 1-3 missed the
## first checkpoint's bank); D27's proposal reads "after 1-4 runs".
const BEGINNER_RUN_S := 90.0
const FIRST_UNLOCK_MAX_RUNS := 4
## The fast tier's run (s).
const FAST_RUN_S := 30.0
## Fresh installs the soak plays (each its own seeds).
const FRESH_INSTALLS := 3

var _saved: Dictionary


func before_each() -> void:
	super.before_each()
	_saved = Save.data.duplicate(true)
	Save.data = SaveMigrations.fresh()   # a fresh install (in memory under the runner)


func after_each() -> void:
	Save.data = _saved
	Save.dirty = false
	await super.after_each()


## One run from the start line: the bot drives `seconds`, then two hits end it and the
## results come up. Returns the run_over payload.
func _bot_run(run_seed: int, seconds: float) -> Dictionary:
	var r := _make(run_seed)
	r.record_best = true   # the game's path: bests, journeys and the XP award at run end
	var bot := BoostingBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	r.go()
	_run_until(r, func() -> bool: return r.state != Game.RUNNING, seconds)
	if r.state == Game.RUNNING:
		r.lives.lives = 1
		r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
		_run_ticks(r, TICKS_PER_FRAME)
	if r.state == Game.CRASH:
		r.skip()
	var res := r.last_results
	eq(r.state, Game.RESULTS, "the run reached its results")
	await _drop(r)
	return res


func _first_unlock_xp() -> int:
	var p := Garage.profile()
	var lo := t.progression.max_level
	for id in p.catalog.unlock_ids():
		if p.is_unlocked(id):
			continue
		if id.begins_with(GarageCatalog.PAINT):
			lo = mini(lo, p.catalog.paint(StringName(id.trim_prefix(GarageCatalog.PAINT))).unlock_level)
		elif id.begins_with(GarageCatalog.RIM):
			lo = mini(lo, p.catalog.rim(StringName(id.trim_prefix(GarageCatalog.RIM))).unlock_level)
		else:
			var s := p.catalog.slot(StringName(id.trim_prefix(GarageCatalog.CAR)))
			if s.unlock == GarageSlot.UNLOCK_LEVEL:
				lo = mini(lo, s.unlock_level)
	return Progression.xp_to_reach(lo, t.progression)


func test_a_real_run_earns_its_banked_score_as_xp() -> void:
	var p := Garage.profile()
	var start := p.unlocks.size()
	eq(p.xp(), 0, "a fresh install")
	var res := await _bot_run(SEED, FAST_RUN_S)
	var score := int(res.get(RunStats.SCORE, -1))
	gt(score, 0, "the bot banked points")
	eq(int(res.get(MetaProfile.R_XP_GAINED, -1)), score, "XP = the banked score")
	eq(int(res.get(MetaProfile.R_XP_TOTAL, -1)), score)
	eq(Garage.profile().xp(), score, "in the save's stats")
	eq(Garage.profile().runs(), 1)
	eq(int(res.get(MetaProfile.R_LEVEL, 0)), Progression.level_for_xp(score, t.progression))
	eq(Save.best_score(RunContext.MODE_JOURNEY), score, "the same run's personal best")
	ge(Garage.profile().unlocks.size(), start)
	eq(_first_unlock_xp(), Progression.xp_to_reach(2, t.progression), "the first level-up unlocks something")


func soak_fresh_install_reaches_its_first_unlock() -> void:
	for install in FRESH_INSTALLS:
		Save.data = SaveMigrations.fresh()
		var start := Garage.profile().unlocks.size()
		var runs := 0
		var unlocked: Array = []
		while unlocked.is_empty() and runs < FIRST_UNLOCK_MAX_RUNS * 2:
			var res := await _bot_run(Rng.derive_seed(SEED, "first_unlock/%d/%d" % [install, runs]), BEGINNER_RUN_S)
			runs += 1
			unlocked = res.get(MetaProfile.R_UNLOCKED, [])
			print("    install %d run %d: +%d XP (total %d, level %d) unlocked %s" % [install, runs,
					int(res.get(MetaProfile.R_XP_GAINED, 0)), int(res.get(MetaProfile.R_XP_TOTAL, 0)),
					int(res.get(MetaProfile.R_LEVEL, 0)), unlocked])
		check(not unlocked.is_empty(), "install %d reaches its first unlock" % install)
		le(runs, FIRST_UNLOCK_MAX_RUNS, "install %d: within %d beginner runs" % [install, FIRST_UNLOCK_MAX_RUNS])
		gt(Garage.profile().unlocks.size(), start)
		for id: String in unlocked:
			check(Garage.profile().is_unlocked(id))
