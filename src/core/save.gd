extends Node
## Local versioned save in user:// (autoload `Save`). Spec: Save data ("A local,
## versioned save in user:// holds settings, unlocks, stats, personal bests and Daily
## Drive ghosts"); Controls → Settings and first run (the chooser shows once, then the
## 20 s warm-up). WP8.1; docs/SAVE.md.
##
## One JSON document (`data`, SaveMigrations.VERSION) in PATH, written atomically with a
## backup by SaveStore and upgraded from any older version by SaveMigrations. Sections:
## settings (Settings.to_dict), bests, journeys, first_run, and stats / unlocks / daily
## for the progression, achievements and Daily Drive (section()).
##
## When it writes (docs/SAVE.md → When it writes): at once for records (a personal best,
## a journey, the first-run steps) and explicit save_to_disk() calls; a settings change
## marks the save dirty and it is written at the end of that frame, or, while a run is
## RUNNING, when the run leaves RUNNING (pause, crash, results, title), so a camera
## cycle mid-run never touches the disk during gameplay. The app being paused,
## backgrounded or closed flushes it too.
##
## Tests and tools (docs/SAVE.md → Tests and tools): under a `--script` main loop (the
## headless test runner, soaks, tools) the save is in memory only (`persistent` false:
## nothing is read or written, the player's own save is never touched) and the first
## run is off (`first_run_enabled` false), so no test sees the chooser unless it turns
## it on. The boot parameter `first_run` (`?first_run=` on the web, `--first_run=` on the
## command line) overrides that for the game: 0 = off, 1 = a fresh first run in memory
## (snaps and demos: the chooser and the warm-up, nothing written).

signal loaded()

const PATH := "user://save.json"
const VERSION := SaveMigrations.VERSION
## data["bests"][mode] = best score (int). Mode ids as in RunContext.MODE_*.
const KEY_BESTS := SaveMigrations.KEY_BESTS
## WP6.5: data["journeys"][mode] = {"count": journeys completed, "best_time_s": the
## fastest run time to the coast, "best_distance_m": the shortest distance driven to it}.
const KEY_JOURNEYS := SaveMigrations.KEY_JOURNEYS
const KEY_JOURNEY_COUNT := "count"
const KEY_JOURNEY_BEST_TIME := "best_time_s"
const KEY_JOURNEY_BEST_DISTANCE := "best_distance_m"
const KEY_SETTINGS := SaveMigrations.KEY_SETTINGS
const KEY_FIRST_RUN := SaveMigrations.KEY_FIRST_RUN
## The boot parameter for the first run (see above).
const BOOT_FIRST_RUN := "first_run"
## `?save_probe=1` (the web smoke's persistence check, docs/SAVE.md → Web): prints how
## many boots this save has seen, then counts this one and writes at once.
const BOOT_SAVE_PROBE := "save_probe"
const KEY_DEV := "dev"
const KEY_PROBE := "probe_boots"

## The save document (always at VERSION after a load).
var data := {}
## False: in memory only (tests, tools, `first_run=1`); save_to_disk() writes nothing.
var persistent: bool = true
## False: chooser_pending() and warmup_pending() are always false (tests, tools,
## `first_run=0`).
var first_run_enabled: bool = true
## True after loading a document from a newer build: it is used as far as this build
## understands it but never overwritten (a downgrade must not lose the newer data).
var read_only: bool = false
## The file store (null when not persistent).
var store: SaveStore
## What the last load found (SaveStore.Status; FRESH when not persistent).
var load_status: SaveStore.Status = SaveStore.Status.FRESH
## The version the loaded file had before migrating (VERSION for a fresh save).
var loaded_version: int = VERSION
## Unsaved changes (flushed at the next safe point).
var dirty: bool = false
## Documents written (tests).
var writes: int = 0

var _loading: bool = false
var _flush_queued: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	configure(PATH, not _is_script_main_loop())
	match boot_param(BOOT_FIRST_RUN):
		"0":
			first_run_enabled = false
		"1":
			persistent = false
			first_run_enabled = true
	load_from_disk()
	if boot_param(BOOT_SAVE_PROBE) == "1":
		_save_probe()
	if not Events.settings_changed.is_connected(_on_setting_changed):
		Events.settings_changed.connect(_on_setting_changed)
	if not Events.game_state_changed.is_connected(_on_game_state_changed):
		Events.game_state_changed.connect(_on_game_state_changed)


## Points the save at `path` (tests use their own). `disk` false = in memory only. The
## first run follows `disk` (on for the game, off for tests and tools).
func configure(path: String, disk: bool) -> void:
	persistent = disk
	first_run_enabled = disk
	store = SaveStore.new(path)


# ---------------------------------------------------------------- Load and save

## Reads the save (in memory only: a fresh document), migrates it to VERSION and applies
## its settings. Never fails: a damaged file falls back to its backup, then to defaults.
func load_from_disk() -> void:
	_loading = true
	read_only = false
	dirty = false
	var doc := {}
	load_status = SaveStore.Status.FRESH
	if persistent and store != null:
		doc = store.load_doc()
		load_status = store.status
	if load_status == SaveStore.Status.FRESH or load_status == SaveStore.Status.CORRUPT or doc.is_empty():
		loaded_version = VERSION
		data = SaveMigrations.fresh()
		if load_status == SaveStore.Status.CORRUPT:
			# Nothing could be read: this player has played before, so no first run again.
			_mark_first_run_done()
	else:
		loaded_version = SaveMigrations.version_of(doc)
		if loaded_version > VERSION:
			push_warning("Save: version %d is newer than %d; loading what this build knows, read-only"
					% [loaded_version, VERSION])
			read_only = true
			data = SaveMigrations.normalize(doc.duplicate(true))
		elif loaded_version < 0:
			push_warning("Save: the version is not a number; starting fresh")
			data = SaveMigrations.fresh()
			_mark_first_run_done()
		else:
			data = SaveMigrations.migrate(doc)
	Settings.from_dict(data[KEY_SETTINGS], true)
	_loading = false
	# A migrated or recovered document is written back at once in its new shape.
	if persistent and not read_only and (loaded_version < VERSION or load_status == SaveStore.Status.BACKUP):
		save_to_disk()
	loaded.emit()


## Writes the save now (settings included). Returns true when it reached the disk (false
## in memory only, read-only, or when the file system refused: the old file stays).
func save_to_disk() -> bool:
	data[SaveMigrations.KEY_VERSION] = VERSION
	var s: Variant = data.get(KEY_SETTINGS, {})
	var merged: Dictionary = s if s is Dictionary else {}
	merged.merge(Settings.to_dict(), true)
	data[KEY_SETTINGS] = merged
	dirty = false
	if not persistent or read_only or store == null:
		return false
	var ok := store.save_doc(data)
	if ok:
		writes += 1
	return ok


## Marks unsaved changes; they are written at the end of this frame, or when the run
## leaves RUNNING.
func request_save() -> void:
	dirty = true
	if _in_gameplay() or _flush_queued:
		return
	_flush_queued = true
	_flush.call_deferred()


## Writes pending changes now (the app closing, tests).
func flush() -> void:
	if dirty:
		save_to_disk()


## A fresh document in memory (defaults, the first run pending again); not written
## until the next save. Tests and `first_run=1`.
func reset_fresh() -> void:
	_loading = true
	data = SaveMigrations.fresh()
	Settings.from_dict({}, true)
	_loading = false
	dirty = false
	read_only = false


func _flush() -> void:
	_flush_queued = false
	if not _in_gameplay():
		flush()


func _in_gameplay() -> bool:
	return Game.state == Game.RUNNING


func _on_setting_changed(_key: StringName) -> void:
	if not _loading:
		request_save()


func _on_game_state_changed(_from: StringName, to: StringName) -> void:
	if dirty and to != Game.RUNNING:
		flush()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		flush()


## The web smoke's persistence probe (see BOOT_SAVE_PROBE).
func _save_probe() -> void:
	var dev := section(KEY_DEV)
	var n := int(dev.get(KEY_PROBE, 0))
	print("Save probe: loaded %d boot(s), status %s, persistent %s" % [n,
			SaveStore.Status.keys()[load_status], persistent])
	dev[KEY_PROBE] = n + 1
	print("Save probe: wrote %d boot(s): %s" % [n + 1, save_to_disk()])


# ---------------------------------------------------------------- Sections

## The section `key` of the save (created empty if missing): a live dictionary, so a
## caller changes it in place and then calls request_save() or save_to_disk(). For the
## progression (stats, unlocks), achievements and Daily Drive (daily); see
## docs/SAVE.md → Sections for who owns which.
func section(key: String) -> Dictionary:
	var v: Variant = data.get(key)
	if not (v is Dictionary):
		v = {}
		data[key] = v
	return v


# ---------------------------------------------------------------- First run

## The first-run chooser should show before the next run (a fresh save).
func chooser_pending() -> bool:
	return first_run_enabled and not bool(section(KEY_FIRST_RUN).get(SaveMigrations.KEY_CHOOSER_DONE, false))


## The next Journey run starts with the empty-road warm-up (a fresh save).
func warmup_pending() -> bool:
	return first_run_enabled and not bool(section(KEY_FIRST_RUN).get(SaveMigrations.KEY_WARMUP_DONE, false))


## The chooser was answered (or skipped): it never shows again by itself.
func mark_chooser_done() -> void:
	section(KEY_FIRST_RUN)[SaveMigrations.KEY_CHOOSER_DONE] = true
	save_to_disk()


## The warm-up ran to its end (or was skipped). `now` false: written when the run leaves
## RUNNING (it ends mid-run).
func mark_warmup_done(now: bool = true) -> void:
	section(KEY_FIRST_RUN)[SaveMigrations.KEY_WARMUP_DONE] = true
	if now:
		save_to_disk()
	else:
		request_save()


func _mark_first_run_done() -> void:
	var fr := section(KEY_FIRST_RUN)
	fr[SaveMigrations.KEY_CHOOSER_DONE] = true
	fr[SaveMigrations.KEY_WARMUP_DONE] = true


# ---------------------------------------------------------------- Personal bests

## Personal best score in `run_mode` (0 when none yet).
func best_score(run_mode: StringName) -> int:
	var bests: Variant = data.get(KEY_BESTS, {})
	if not (bests is Dictionary):
		return 0
	return int((bests as Dictionary).get(String(run_mode), 0))


## Records `score` as the best in `run_mode` if it beats the stored one, and writes the
## save to disk. Returns true for a new best.
func submit_best_score(run_mode: StringName, score: int) -> bool:
	if score <= best_score(run_mode):
		return false
	section(KEY_BESTS)[String(run_mode)] = score
	save_to_disk()
	return true


## "Journey complete" is recorded (spec: The journey goal): one more journey in
## `run_mode`, and the best (lowest) time and distance to the coast. Writes the save.
func record_journey(run_mode: StringName, time_s: float, distance_m: float) -> void:
	var d := section(KEY_JOURNEYS)
	var entry: Variant = d.get(String(run_mode), {})
	var e: Dictionary = entry if entry is Dictionary else {}
	e[KEY_JOURNEY_COUNT] = int(e.get(KEY_JOURNEY_COUNT, 0)) + 1
	var best_t := float(e.get(KEY_JOURNEY_BEST_TIME, INF))
	e[KEY_JOURNEY_BEST_TIME] = minf(best_t, time_s)
	var best_d := float(e.get(KEY_JOURNEY_BEST_DISTANCE, INF))
	e[KEY_JOURNEY_BEST_DISTANCE] = minf(best_d, distance_m)
	d[String(run_mode)] = e
	save_to_disk()


## Journeys completed in `run_mode` (0 when none).
func journey_count(run_mode: StringName) -> int:
	return int(_journey(run_mode).get(KEY_JOURNEY_COUNT, 0))


## Fastest time to the coast in `run_mode` (INF when none).
func journey_best_time_s(run_mode: StringName) -> float:
	return float(_journey(run_mode).get(KEY_JOURNEY_BEST_TIME, INF))


func journey_best_distance_m(run_mode: StringName) -> float:
	return float(_journey(run_mode).get(KEY_JOURNEY_BEST_DISTANCE, INF))


func _journey(run_mode: StringName) -> Dictionary:
	var e: Variant = section(KEY_JOURNEYS).get(String(run_mode), {})
	return e if e is Dictionary else {}


# ---------------------------------------------------------------- Boot

## True when the main loop is a script (`godot --script ...`: the test runner, soaks,
## tools) rather than the game's scene tree.
static func _is_script_main_loop() -> bool:
	var ml := Engine.get_main_loop()
	return ml != null and ml.get_script() != null


## A boot parameter: `?key=value` on the web, `--key=value` on the command line (as
## Run.boot_param; kept here so the autoload does not load the run's scripts).
static func boot_param(key: String) -> String:
	var prefix := "%s=" % key
	if OS.has_feature("web"):
		var query: Variant = JavaScriptBridge.eval("window.location.search", true)
		if query is String:
			for part: String in (query as String).trim_prefix("?").split("&"):
				if part.begins_with(prefix):
					return part.trim_prefix(prefix).uri_decode()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + prefix):
			return a.trim_prefix("--" + prefix)
	for a in OS.get_cmdline_args():
		if a.begins_with("--" + prefix):
			return a.trim_prefix("--" + prefix)
	return ""
