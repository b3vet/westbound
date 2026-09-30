class_name MetaProfile
extends RefCounted
## The player's progression and garage choices (WP8.2) over three save sections, changed
## in place: `stats` (lifetime XP and the milestone counters), `unlocks` (what is
## unlocked) and `garage` (the selected car and each car's paint and rims). Spec: Garage
## and progression (driver level from lifetime banked score; level and milestone unlocks;
## 1 car unlocked at start); Save data ("holds settings, unlocks, stats"). No nodes and no
## autoloads: Garage (src/meta/garage.gd) hands it the Save sections; tests hand it
## plain dictionaries. docs/GARAGE.md.
##
##   var p := MetaProfile.new(stats, unlocks, garage, catalog, tuning.progression)
##   var award := p.record_run(results, day)   # XP, milestones, new unlocks
##   p.select_paint(&"falcon_gt", &"teal")     # false while locked
##
## Save shape (JSON; numbers read back as floats, so every read goes through int()):
##   stats   {xp, runs, threads, best_leg, coast, daily_streak, daily_best_streak,
##            daily_last_day, backfilled}
##   unlocks {"car/night_viper": 7, "paint/sunset": 2, ...}   (the run count it unlocked on)
##   garage  {car: "falcon_gt", looks: {"falcon_gt": {paint: "teal", rim: "mesh"}}}

const XP := "xp"
const RUNS := "runs"
const THREADS := "threads"
const BEST_LEG := "best_leg"
const COAST := "coast"
const DAILY_STREAK := "daily_streak"
const DAILY_BEST_STREAK := "daily_best_streak"
const DAILY_LAST_DAY := "daily_last_day"
const BACKFILLED := "backfilled"
const CAR := "car"
const LOOKS := "looks"
const PAINT := "paint"
const RIM := "rim"

## Keys record_run() adds to the run's results (the results screen reads them; the
## leaderboard payload leaves them out).
const R_XP_GAINED := &"xp_gained"
const R_XP_TOTAL := &"xp_total"
const R_LEVEL_BEFORE := &"level_before"
const R_LEVEL := &"level"
const R_UNLOCKED := &"unlocked"

const MODE_DAILY := &"daily"
## The journeys section's count key (Save.KEY_JOURNEY_COUNT).
const JOURNEY_COUNT := "count"

var stats: Dictionary
var unlocks: Dictionary
var garage: Dictionary
var catalog: GarageCatalog
var tuning: ProgressionTuning


func _init(stats_section: Dictionary, unlocks_section: Dictionary, garage_section: Dictionary,
		garage_catalog: GarageCatalog, t: ProgressionTuning) -> void:
	stats = stats_section
	unlocks = unlocks_section
	garage = garage_section
	catalog = garage_catalog
	tuning = t


# ---------------------------------------------------------------- Stats

func xp() -> int:
	return _int(stats, XP)


func level() -> int:
	return Progression.level_for_xp(xp(), tuning)


func runs() -> int:
	return _int(stats, RUNS)


func threads() -> int:
	return _int(stats, THREADS)


## The furthest leg reached on the journey road (1 = the first leg).
func best_leg() -> int:
	return maxi(_int(stats, BEST_LEG), 1)


func coast_reached() -> bool:
	return bool(stats.get(COAST, false))


func daily_streak() -> int:
	return _int(stats, DAILY_STREAK)


func daily_best_streak() -> int:
	return _int(stats, DAILY_BEST_STREAK)


## Records a finished run (the Events.run_over results: mode, score, legs, coast,
## threads). `day` is the UTC day number it finished on (unix seconds / 86400), for the
## Daily Drive streak (-1: no streak change). Returns the award, also the keys to merge
## into the results: xp_gained, xp_total, level_before, level, unlocked (new unlock ids).
func record_run(results: Dictionary, day: int = -1) -> Dictionary:
	var run_mode := StringName(str(results.get(RunStats.MODE, &"")))
	var before := level()
	var gained := Progression.xp_for_run(results, tuning)
	if Progression.counts_for_xp(run_mode, tuning):
		stats[XP] = xp() + gained
		stats[RUNS] = runs() + 1
		stats[THREADS] = threads() + maxi(int(results.get(RunStats.THREADS, 0)), 0)
	if Progression.counts_for_milestones(run_mode, tuning):
		var reached := maxi(int(results.get(RunStats.LEGS_COMPLETED, 0)), 0) + 1
		stats[BEST_LEG] = maxi(best_leg(), reached)
		if bool(results.get(RunStats.COAST_REACHED, false)):
			stats[COAST] = true
	if run_mode == MODE_DAILY and day >= 0:
		_count_daily(day)
	var fresh := refresh_unlocks()
	return {
		R_XP_GAINED: gained,
		R_XP_TOTAL: xp(),
		R_LEVEL_BEFORE: before,
		R_LEVEL: level(),
		R_UNLOCKED: fresh,
	}


## A Daily Drive on UTC day `day`: the streak grows on consecutive days, holds on the
## same day, and restarts after a missed day.
func _count_daily(day: int) -> void:
	var last := int(stats.get(DAILY_LAST_DAY, -1))
	var streak := daily_streak()
	if day == last:
		streak = maxi(streak, 1)
	elif last >= 0 and day == last + 1:
		streak += 1
	else:
		streak = 1
	stats[DAILY_STREAK] = streak
	stats[DAILY_BEST_STREAK] = maxi(daily_best_streak(), streak)
	stats[DAILY_LAST_DAY] = maxi(day, last)


## A save from before WP8.2 has personal bests but no lifetime XP: start from their sum
## (a lower bound of the banked score so far) and the coast from the journeys recorded.
## Once per save (stats.backfilled). Returns whether it ran.
func backfill(bests: Dictionary, journeys: Dictionary) -> bool:
	if stats.has(BACKFILLED):
		return false
	stats[BACKFILLED] = true
	if stats.has(XP):
		return false
	var sum := 0
	for k: Variant in bests:
		var v: Variant = bests[k]
		if (v is int or v is float) and is_finite(float(v)):
			sum += maxi(int(v), 0)
	stats[XP] = roundi(float(sum) * tuning.xp_per_point)
	for k: Variant in journeys:
		var e: Variant = journeys[k]
		if e is Dictionary and int((e as Dictionary).get(JOURNEY_COUNT, 0)) > 0:
			stats[COAST] = true
			stats[BEST_LEG] = maxi(best_leg(), tuning.unlock_leg_milestone)
	return true


# ---------------------------------------------------------------- Unlocks

## Unlocks everything whose rule is met now (unlocks only ever grow). Returns the new
## unlock ids in catalog order.
func refresh_unlocks() -> Array[String]:
	var fresh: Array[String] = []
	for id in catalog.unlock_ids():
		if not unlocks.has(id) and is_met(id):
			unlocks[id] = runs()
			fresh.append(id)
	return fresh


func is_unlocked(unlock_id: String) -> bool:
	return unlocks.has(unlock_id)


## Whether the item's rule holds for the stats now.
func is_met(unlock_id: String) -> bool:
	if unlock_id.begins_with(GarageCatalog.CAR):
		var s := catalog.slot(StringName(unlock_id.trim_prefix(GarageCatalog.CAR)))
		return s != null and slot_met(s)
	if unlock_id.begins_with(GarageCatalog.PAINT):
		var p := catalog.paint(StringName(unlock_id.trim_prefix(GarageCatalog.PAINT)))
		return p != null and level() >= p.unlock_level
	if unlock_id.begins_with(GarageCatalog.RIM):
		var r := catalog.rim(StringName(unlock_id.trim_prefix(GarageCatalog.RIM)))
		return r != null and level() >= r.unlock_level
	return false


func slot_met(s: GarageSlot) -> bool:
	var p := slot_progress(s)
	return p.x >= p.y


## The slot's rule as (current, target): level, leg reached, coast (0/1), best Daily
## streak, lifetime threads; start = (1, 1).
func slot_progress(s: GarageSlot) -> Vector2i:
	match s.unlock:
		GarageSlot.UNLOCK_START:
			return Vector2i(1, 1)
		GarageSlot.UNLOCK_LEG:
			return Vector2i(best_leg(), tuning.unlock_leg_milestone)
		GarageSlot.UNLOCK_COAST:
			return Vector2i(1 if coast_reached() else 0, 1)
		GarageSlot.UNLOCK_DAILY_STREAK:
			return Vector2i(daily_best_streak(), tuning.unlock_daily_streak_days)
		GarageSlot.UNLOCK_THREADS:
			return Vector2i(threads(), tuning.unlock_lifetime_threads)
	return Vector2i(level(), s.unlock_level)


func car_unlocked(s: GarageSlot) -> bool:
	return is_unlocked(GarageCatalog.CAR + String(s.id))


func paint_unlocked(p: PaintOption) -> bool:
	return is_unlocked(GarageCatalog.PAINT + String(p.id))


func rim_unlocked(r: RimStyle) -> bool:
	return is_unlocked(GarageCatalog.RIM + String(r.id))


## The slot can be driven: unlocked and a real car (not a placeholder).
func drivable(s: GarageSlot) -> bool:
	return s != null and s.has_car() and car_unlocked(s)


# ---------------------------------------------------------------- Selection

## The selected slot: the saved one while drivable, else the first drivable slot.
func selected_slot() -> GarageSlot:
	var s := catalog.slot(StringName(str(garage.get(CAR, ""))))
	if drivable(s):
		return s
	for c in catalog.slots:
		if drivable(c):
			return c
	for c in catalog.slots:
		if c.has_car():
			return c
	return null


## Selects `slot_id` for the next run. False (nothing changes) while it is locked or a
## placeholder.
func select_car(slot_id: StringName) -> bool:
	var s := catalog.slot(slot_id)
	if not drivable(s):
		return false
	garage[CAR] = String(slot_id)
	return true


## The paint `slot_id` wears: its saved paint while unlocked, else the factory paint.
func paint_for(slot_id: StringName) -> PaintOption:
	var p := catalog.paint(StringName(str(_look(slot_id).get(PAINT, ""))))
	if p != null and paint_unlocked(p):
		return p
	return _first_paint()


func rim_for(slot_id: StringName) -> RimStyle:
	var r := catalog.rim(StringName(str(_look(slot_id).get(RIM, ""))))
	if r != null and rim_unlocked(r):
		return r
	return _first_rim()


func select_paint(slot_id: StringName, paint_id: StringName) -> bool:
	var p := catalog.paint(paint_id)
	if p == null or not paint_unlocked(p) or catalog.slot(slot_id) == null:
		return false
	_own_look(slot_id)[PAINT] = String(paint_id)
	return true


func select_rim(slot_id: StringName, rim_id: StringName) -> bool:
	var r := catalog.rim(rim_id)
	if r == null or not rim_unlocked(r) or catalog.slot(slot_id) == null:
		return false
	_own_look(slot_id)[RIM] = String(rim_id)
	return true


## The look (paint colour, rims) `slot_id`'s car wears.
func look_for(slot_id: StringName) -> CarLook:
	var s := catalog.slot(slot_id)
	var car := s.car() if s != null else null
	var p := paint_for(slot_id)
	return CarLook.make(p.color_for(car) if p != null else (car.default_paint if car != null else Color.WHITE),
			rim_for(slot_id))


func _first_paint() -> PaintOption:
	for p in catalog.paints:
		if p.factory:
			return p
	return catalog.paints[0] if not catalog.paints.is_empty() else null


func _first_rim() -> RimStyle:
	for r in catalog.rims:
		if r.model_default:
			return r
	return catalog.rims[0] if not catalog.rims.is_empty() else null


func _look(slot_id: StringName) -> Dictionary:
	var looks: Variant = garage.get(LOOKS, {})
	if not (looks is Dictionary):
		return {}
	var l: Variant = (looks as Dictionary).get(String(slot_id), {})
	return l if l is Dictionary else {}


func _own_look(slot_id: StringName) -> Dictionary:
	var looks: Variant = garage.get(LOOKS)
	if not (looks is Dictionary):
		looks = {}
		garage[LOOKS] = looks
	var d := looks as Dictionary
	var l: Variant = d.get(String(slot_id))
	if not (l is Dictionary):
		l = {}
		d[String(slot_id)] = l
	return l


static func _int(d: Dictionary, key: String) -> int:
	var v: Variant = d.get(key, 0)
	if (v is int or v is float) and is_finite(float(v)):
		return int(v)
	return 0
