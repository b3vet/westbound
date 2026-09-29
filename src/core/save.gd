extends Node
## Local versioned save in user:// (autoload `Save`). Spec: Save data.
##
## M0 skeleton: versioned JSON document with a migration hook.
## Unlocks, stats, bests and ghosts are added in WP8.1. WP4.1 adds the personal best
## score per mode (Run end: "compares against personal bests"), under "bests".

const PATH := "user://save.json"
const VERSION := 1
## data["bests"][mode] = best score (int). Mode ids as in RunContext.MODE_*.
const KEY_BESTS := "bests"
## WP6.5: data["journeys"][mode] = {"count": journeys completed, "best_time_s": the
## fastest run time to the coast, "best_distance_m": the shortest distance driven to it}.
const KEY_JOURNEYS := "journeys"
const KEY_JOURNEY_COUNT := "count"
const KEY_JOURNEY_BEST_TIME := "best_time_s"
const KEY_JOURNEY_BEST_DISTANCE := "best_distance_m"

var data := {}


func _ready() -> void:
	load_from_disk()


func load_from_disk() -> void:
	data = {"version": VERSION}
	if not FileAccess.file_exists(PATH):
		return
	var text := FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		data = _migrate(parsed)
		if data.has("settings"):
			Settings.from_dict(data["settings"])


func save_to_disk() -> void:
	data["version"] = VERSION
	data["settings"] = Settings.to_dict()
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("Save: cannot write %s (%s)" % [PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(data))


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
	var bests: Variant = data.get(KEY_BESTS, {})
	var d: Dictionary = bests if bests is Dictionary else {}
	d[String(run_mode)] = score
	data[KEY_BESTS] = d
	save_to_disk()
	return true


## "Journey complete" is recorded (spec: The journey goal): one more journey in
## `run_mode`, and the best (lowest) time and distance to the coast. Writes the save.
func record_journey(run_mode: StringName, time_s: float, distance_m: float) -> void:
	var all: Variant = data.get(KEY_JOURNEYS, {})
	var d: Dictionary = all if all is Dictionary else {}
	var entry: Variant = d.get(String(run_mode), {})
	var e: Dictionary = entry if entry is Dictionary else {}
	e[KEY_JOURNEY_COUNT] = int(e.get(KEY_JOURNEY_COUNT, 0)) + 1
	var best_t := float(e.get(KEY_JOURNEY_BEST_TIME, INF))
	e[KEY_JOURNEY_BEST_TIME] = minf(best_t, time_s)
	var best_d := float(e.get(KEY_JOURNEY_BEST_DISTANCE, INF))
	e[KEY_JOURNEY_BEST_DISTANCE] = minf(best_d, distance_m)
	d[String(run_mode)] = e
	data[KEY_JOURNEYS] = d
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
	var all: Variant = data.get(KEY_JOURNEYS, {})
	if not (all is Dictionary):
		return {}
	var e: Variant = (all as Dictionary).get(String(run_mode), {})
	return e if e is Dictionary else {}


## Upgrade an older save document to VERSION, one step at a time.
func _migrate(doc: Dictionary) -> Dictionary:
	var v: int = int(doc.get("version", 0))
	if v > VERSION:
		push_warning("Save: version %d is newer than %d; loading defaults" % [v, VERSION])
		return {"version": VERSION}
	doc["version"] = VERSION
	return doc
