class_name Garage
extends RefCounted
## The garage and the driver level over the save (WP8.2). Spec: Garage and progression;
## Save data. docs/GARAGE.md, docs/SAVE.md → Sections (stats, unlocks, garage).
##
##   Garage.award_run(results)        # the run's end: XP, milestones, unlocks, written now
##   Garage.selected_car_path()       # the car the next run drives (Run.CAR_PATHS entry)
##   Garage.selected_look(car_def)    # its paint and rims
##   Garage.profile().select_rim(...) # then Garage.changed() to save it soon
##
## Stateless: every call reads the live `Save` sections (so Save.reset_fresh / a load take
## effect at once). The catalog loads once.

const SECTION_STATS := SaveMigrations.KEY_STATS
const SECTION_UNLOCKS := SaveMigrations.KEY_UNLOCKS
const SECTION_GARAGE := "garage"
const S_PER_DAY := 86400

static var _catalog: GarageCatalog


static func tuning() -> ProgressionTuning:
	return Tuning.load_default().progression


static func catalog() -> GarageCatalog:
	if _catalog == null:
		_catalog = GarageCatalog.load_path(tuning().garage_catalog_path)
	return _catalog


## The player's profile over the save's sections (a save from before WP8.2 is backfilled
## once; unlocks whose rule holds are recorded).
static func profile() -> MetaProfile:
	# G7: unlocks and looks recorded under a slot's former id (a COMING SOON slot that
	# now holds a car) move to its current id.
	var renamed := SaveMigrations.rename_car_ids(Save.section(SECTION_UNLOCKS), Save.section(SECTION_GARAGE),
			catalog().car_id_renames())
	var p := MetaProfile.new(Save.section(SECTION_STATS), Save.section(SECTION_UNLOCKS),
			Save.section(SECTION_GARAGE), catalog(), tuning())
	var changed_now := p.backfill(Save.section(SaveMigrations.KEY_BESTS), Save.section(SaveMigrations.KEY_JOURNEYS))
	if not p.refresh_unlocks().is_empty() or changed_now or renamed:
		Save.request_save()
	return p


## A finished run: XP, the milestone counters and new unlocks, merged into `results` (the
## Events.run_over payload the results screen shows) and written to disk now. Returns
## the award (MetaProfile.record_run).
static func award_run(results: Dictionary) -> Dictionary:
	var award := profile().record_run(results, today())
	results.merge(award, true)
	Save.save_to_disk()
	return award


## N6.2: a run in a multiplayer room (loop mode) is over: XP from the server's official
## score (its run_result, or the last official banked total when the player left first),
## through award_run like single-player (xp_modes decides; rooms are `loop`). Milestones
## and the Daily streak do not apply. Returns the award.
static func award_room_run(official_score: int, threads: int) -> Dictionary:
	return award_run({RunStats.MODE: Run.MODE_LOOP, RunStats.SCORE: maxi(official_score, 0),
		RunStats.THREADS: maxi(threads, 0)})


## The UTC day number now (the Daily Drive streak). Meta only, never the simulation.
static func today() -> int:
	@warning_ignore("integer_division")
	return int(Time.get_unix_time_from_system()) / S_PER_DAY


## The selected car's CarDef path ("" when the catalog has none).
static func selected_car_path() -> String:
	var s := profile().selected_slot()
	return s.car_path if s != null else ""


## The selected slot's look for `car` (its paint and rims).
static func selected_look(car: CarDef) -> CarLook:
	var p := profile()
	var s := catalog().slot_for_car_path(car.resource_path) if car != null else null
	if s == null:
		return CarLook.factory(car)
	return p.look_for(s.id)


## A selection changed: saved at the end of the frame.
static func changed() -> void:
	Save.request_save()
