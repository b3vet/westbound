class_name DailyGhostStore
extends RefCounted
## Daily Drive ghosts on the device: one file per UTC date holding that date's best run,
## an index in the save's `daily` section, old dates pruned. Spec: Save data ("A local,
## versioned save in user:// holds ... Daily Drive ghosts"); docs/SAVE.md → Sections
## (ghosts are their own files, only the index in `daily`). WP8.4; docs/DAILY.md → Storage.
##
##   var store := DailyGhostStore.new(Save.section("daily"), DailyTuning.resolve())
##   var best := store.load_ghost("2026-09-30")     # null: none yet
##   if store.offer(ghost, today): Save.request_save()   # kept when it beats the date's best
##
## Files: `<dir>/<date>.ghost` (DailyGhost bytes), written as `<file>.tmp`, read back,
## then renamed over the old one (a crash keeps the old ghost or the new one, never half).
## Index (`daily.ghosts`): {date: {score, ticks, car, bytes}}. The file is the truth: a
## missing or unreadable file drops its index entry; a file without an entry is adopted
## by prune() only if it is kept (its header has the score), else deleted.
## Prune keeps today's date and the `ghost_keep_days` - 1 days before it; everything else
## (older dates, and future dates from a wrong clock) goes. Load / run-end time only.

## The save section holding the index (docs/SAVE.md → Sections).
const SECTION := "daily"
const DIR := "user://daily"
const EXT := ".ghost"
const TMP_SUFFIX := ".tmp"
const KEY_GHOSTS := "ghosts"
const K_SCORE := "score"
const K_TICKS := "ticks"
const K_CAR := "car"
const K_BYTES := "bytes"
const DATE_LEN := 10
const SECONDS_PER_DAY := 86400

var dir: String
var tuning: DailyTuning
## The live `daily` section (Save.section("daily") in the game; a plain dictionary in tests).
var section: Dictionary
## Files written (tests).
var writes: int = 0


func _init(daily_section: Dictionary, daily_tuning: DailyTuning = null, directory: String = DIR) -> void:
	section = daily_section
	tuning = daily_tuning if daily_tuning != null else DailyTuning.resolve()
	dir = directory


## The index: {date: {score, ticks, car, bytes}} (created when missing).
func index() -> Dictionary:
	var v: Variant = section.get(KEY_GHOSTS)
	if not (v is Dictionary):
		v = {}
		section[KEY_GHOSTS] = v
	return v


func path_for(date: String) -> String:
	return dir.path_join(date + EXT)


## The best banked score stored for `date` (-1: no ghost).
func best_score(date: String) -> int:
	var e: Variant = index().get(date)
	if e is Dictionary:
		return int((e as Dictionary).get(K_SCORE, -1))
	return -1


## The stored ghost of `date` (null: none, or the file is gone or damaged: its entry is
## dropped).
func load_ghost(date: String) -> DailyGhost:
	if not valid_date(date):
		return null
	var p := path_for(date)
	if not FileAccess.file_exists(p):
		index().erase(date)
		return null
	var g := DailyGhost.decode(FileAccess.get_file_as_bytes(p))
	if g == null or g.date != date:
		push_warning("DailyGhostStore: %s is damaged; dropped" % p)
		index().erase(date)
		DirAccess.remove_absolute(p)
		return null
	return g


## Keeps `ghost` when it beats the stored best of its date (or there is none), then
## prunes against `today` ("YYYY-MM-DD", UTC). True when it was written (the caller saves
## the index: Save.request_save()).
func offer(ghost: DailyGhost, today: String) -> bool:
	if ghost == null or ghost.sample_count == 0 or not valid_date(ghost.date):
		return false
	var kept := false
	if ghost.score > best_score(ghost.date) and keeps(ghost.date, today):
		kept = write(ghost)
	prune(today)
	return kept


## Writes `ghost` as its date's file (atomically) and indexes it. False when the file
## system refused (the old ghost stays).
func write(ghost: DailyGhost) -> bool:
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		push_warning("DailyGhostStore: cannot create %s" % dir)
		return false
	var bytes := ghost.encode()
	var p := path_for(ghost.date)
	var tmp := p + TMP_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("DailyGhostStore: cannot write %s" % tmp)
		return false
	f.store_buffer(bytes)
	f.close()
	if FileAccess.get_file_as_bytes(tmp) != bytes:
		DirAccess.remove_absolute(tmp)
		push_warning("DailyGhostStore: %s did not read back" % tmp)
		return false
	var err := DirAccess.rename_absolute(tmp, p)
	if err != OK and FileAccess.file_exists(p):
		# Some platforms refuse to rename over a file.
		DirAccess.remove_absolute(p)
		err = DirAccess.rename_absolute(tmp, p)
	if err != OK:
		push_warning("DailyGhostStore: cannot rename %s (%d)" % [tmp, err])
		return false
	index()[ghost.date] = {K_SCORE: ghost.score, K_TICKS: ghost.ticks, K_CAR: ghost.car, K_BYTES: bytes.size()}
	writes += 1
	return true


## Deletes every ghost (file and entry) whose date is not kept against `today`, and any
## stray file in the directory; adopts a kept file the index lost.
func prune(today: String) -> void:
	var idx := index()
	for date: String in idx.keys():
		if not keeps(date, today):
			idx.erase(date)
			if FileAccess.file_exists(path_for(date)):
				DirAccess.remove_absolute(path_for(date))
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		var p := dir.path_join(file)
		var date := file.get_basename()
		if not file.ends_with(EXT) or not keeps(date, today):
			DirAccess.remove_absolute(p)
		elif not idx.has(date):
			var g := DailyGhost.peek(FileAccess.get_file_as_bytes(p))
			if g != null and g.date == date:
				idx[date] = {K_SCORE: g.score, K_TICKS: g.ticks, K_CAR: g.car, K_BYTES: FileAccess.get_size(p)}
			else:
				DirAccess.remove_absolute(p)


## True when a ghost of `date` is kept on `today`: today and the ghost_keep_days - 1 days
## before it.
func keeps(date: String, today: String) -> bool:
	if not valid_date(date) or not valid_date(today):
		return false
	var age := days_between(date, today)
	return age >= 0 and age < maxi(tuning.ghost_keep_days, 1)


## Whole days from `from` to `to` (both "YYYY-MM-DD").
static func days_between(from: String, to: String) -> int:
	var a := Time.get_unix_time_from_datetime_string(from + "T00:00:00")
	var b := Time.get_unix_time_from_datetime_string(to + "T00:00:00")
	return floori(float(b - a) / float(SECONDS_PER_DAY))


## "YYYY-MM-DD" with digits in the right places.
static func valid_date(date: String) -> bool:
	if date.length() != DATE_LEN or date[4] != "-" or date[7] != "-":
		return false
	return date.substr(0, 4).is_valid_int() and date.substr(5, 2).is_valid_int() and date.substr(8, 2).is_valid_int()


## Today's UTC date, "YYYY-MM-DD".
static func today_utc() -> String:
	return Time.get_date_string_from_system(true)
