class_name SaveMerge
extends RefCounted
## Cloud sync's merge rules for the save document (WP N11; docs/SAVE.md → Cloud sync). Pure
## functions over plain dictionaries: no nodes, no autoloads, no clock. The server stores
## the cloud copy whole and never merges; every rule lives here.
##
##   var cloud_doc := SaveMerge.to_cloud(local)                   # what goes up
##   var new_local := SaveMerge.merge(local, cloud, SaveMerge.Mode.MERGE)
##
## Per section (`merge`, Mode.MERGE):
##   bests          max per mode
##   journeys       per mode: count max, best_time_s min, best_distance_m min
##   stats          per counter: numbers max, booleans or (xp, runs, threads, best_leg,
##                  coast, the Daily streak counters, backfilled)
##   unlocks        union; the earliest run count when both have one
##   achievements   unlocked: union (the earliest day); progress: max per metric;
##                  mirrored (platform mirror state) stays on the device, never uploaded
##   first_run      done anywhere = done
##   garage         the whole selection (car, looks) from whichever side changed it last
##                  (`sync.garage_at`, unix seconds; a tie keeps this device's)
##   settings       this device wins. Only SYNCED_SETTINGS go up (preferences that follow
##                  the player); a device that never changed a setting (`sync.settings_at`
##                  0: a fresh install) takes the cloud's. Device-specific ones (graphics
##                  tier, battery saver, controls size, text size, steering mode, haptics,
##                  volumes, mute) never leave the device
##   daily, dev     device-only (ghost files live on the device)
##   other sections a newer build's: kept, this device's copy first
## Mode.KEEP_LOCAL (the conflict chooser's "keep this device's progress"): the same merge,
## but this device's garage and settings win. Mode.USE_CLOUD ("use the cloud progress"):
## the cloud's progress replaces this device's (a local backup is kept by the caller);
## device-specific settings and sections stay.

enum Mode { MERGE, KEEP_LOCAL, USE_CLOUD }

const KEY_SYNC := "sync"
## sync.garage_at / sync.settings_at: unix seconds of this device's last garage / settings
## change (Save stamps them); 0 = never.
const SYNC_GARAGE_AT := "garage_at"
const SYNC_SETTINGS_AT := "settings_at"
const KEY_GARAGE := "garage"
const KEY_ACHIEVEMENTS := "achievements"
const KEY_DAILY := "daily"
const KEY_DEV := "dev"
const ACH_UNLOCKED := "unlocked"
const ACH_PROGRESS := "progress"
const ACH_MIRRORED := "mirrored"
const JOURNEY_COUNT := "count"
const JOURNEY_BEST_TIME := "best_time_s"
const JOURNEY_BEST_DISTANCE := "best_distance_m"
const STAT_XP := "xp"
const STAT_RUNS := "runs"

## Settings that follow the player across devices (docs/SAVE.md → Cloud sync).
const SYNCED_SETTINGS: Array[String] = ["throttle_mode", "left_handed", "steer_sensitivity",
	"steer_dead_zone", "steer_curve", "drag_visual", "units", "camera_mode", "reduced_motion"]
## Sections that never leave the device (`sync` goes up rebuilt: its timestamps only).
const LOCAL_ONLY: Array[String] = [KEY_DAILY, KEY_DEV, KEY_SYNC]
## Progress sections USE_CLOUD replaces (absent in the cloud copy = empty).
const PROGRESS: Array[String] = [SaveMigrations.KEY_BESTS, SaveMigrations.KEY_JOURNEYS,
	SaveMigrations.KEY_STATS, SaveMigrations.KEY_UNLOCKS, KEY_ACHIEVEMENTS, KEY_GARAGE,
	SaveMigrations.KEY_FIRST_RUN]
## JSON numbers come back as floats; whole ones within this are stored as ints again.
const MAX_EXACT_INT := 9007199254740992.0   # lint: allow-number 2^53, the exact-integer range of a double


## The cloud copy of a local document: everything but the device-only parts.
static func to_cloud(local: Dictionary) -> Dictionary:
	var out := {}
	for key: Variant in local:
		var k := str(key)
		if LOCAL_ONLY.has(k):
			continue
		out[k] = _copy(local[key])
	var s: Variant = local.get(SaveMigrations.KEY_SETTINGS)
	var settings := {}
	if s is Dictionary:
		for k: String in SYNCED_SETTINGS:
			if (s as Dictionary).has(k):
				settings[k] = _copy((s as Dictionary)[k])
	out[SaveMigrations.KEY_SETTINGS] = settings
	var a: Variant = out.get(KEY_ACHIEVEMENTS)
	if a is Dictionary:
		(a as Dictionary).erase(ACH_MIRRORED)
	out[KEY_SYNC] = {SYNC_GARAGE_AT: stamp(local, SYNC_GARAGE_AT),
			SYNC_SETTINGS_AT: stamp(local, SYNC_SETTINGS_AT)}
	return out


## The new local document: `local` merged with the cloud copy (see the class docs). Never
## changes its arguments. An empty `cloud` (no save on the server yet) gives `local`.
static func merge(local: Dictionary, cloud: Dictionary, mode: Mode = Mode.MERGE) -> Dictionary:
	if cloud.is_empty():
		return local.duplicate(true)
	if mode == Mode.USE_CLOUD:
		return adopt(local, cloud)
	var out := local.duplicate(true)
	# A section neither side has stays absent (merging never invents empty sections).
	var sec := SaveMigrations.KEY_FIRST_RUN
	if _has(local, cloud, sec):
		out[sec] = _merge_flags(_dict(local, sec), _dict(cloud, sec))
	sec = SaveMigrations.KEY_BESTS
	if _has(local, cloud, sec):
		out[sec] = _merge_max(_dict(local, sec), _dict(cloud, sec))
	sec = SaveMigrations.KEY_JOURNEYS
	if _has(local, cloud, sec):
		out[sec] = _merge_journeys(_dict(local, sec), _dict(cloud, sec))
	sec = SaveMigrations.KEY_STATS
	if _has(local, cloud, sec):
		out[sec] = _merge_max(_dict(local, sec), _dict(cloud, sec))
	sec = SaveMigrations.KEY_UNLOCKS
	if _has(local, cloud, sec):
		out[sec] = _merge_min(_dict(local, sec), _dict(cloud, sec))
	if _has(local, cloud, KEY_ACHIEVEMENTS):
		out[KEY_ACHIEVEMENTS] = _merge_achievements(_dict(local, KEY_ACHIEVEMENTS), _dict(cloud, KEY_ACHIEVEMENTS))
	var lg := stamp(local, SYNC_GARAGE_AT)
	var cg := stamp(cloud, SYNC_GARAGE_AT)
	var sync := _dict(local, KEY_SYNC).duplicate(true)
	if mode != Mode.KEEP_LOCAL and cg > lg:
		out[KEY_GARAGE] = _copy(_dict(cloud, KEY_GARAGE))
		sync[SYNC_GARAGE_AT] = cg
	var settings := _dict(local, SaveMigrations.KEY_SETTINGS).duplicate(true)
	if mode != Mode.KEEP_LOCAL and stamp(local, SYNC_SETTINGS_AT) <= 0:
		var cs := _dict(cloud, SaveMigrations.KEY_SETTINGS)
		for k: String in SYNCED_SETTINGS:
			if cs.has(k):
				settings[k] = _copy(cs[k])
	out[SaveMigrations.KEY_SETTINGS] = settings
	if local.has(KEY_SYNC) or not sync.is_empty():
		out[KEY_SYNC] = sync
	for key: Variant in cloud:
		var k := str(key)
		if not out.has(k) and not LOCAL_ONLY.has(k):
			out[k] = _copy(cloud[key])
	return out


## Mode.USE_CLOUD: the cloud's progress and synced settings over this device's
## device-only parts.
static func adopt(local: Dictionary, cloud: Dictionary) -> Dictionary:
	var out := local.duplicate(true)
	for k: String in PROGRESS:
		if _has(local, cloud, k):
			out[k] = _copy(_dict(cloud, k))
	for key: Variant in cloud:
		var k := str(key)
		if not PROGRESS.has(k) and not LOCAL_ONLY.has(k) and k != SaveMigrations.KEY_SETTINGS \
				and k != SaveMigrations.KEY_VERSION:
			out[k] = _copy(cloud[key])
	var mirrored: Variant = _dict(local, KEY_ACHIEVEMENTS).get(ACH_MIRRORED)
	if mirrored is Dictionary and out.get(KEY_ACHIEVEMENTS) is Dictionary:
		(out[KEY_ACHIEVEMENTS] as Dictionary)[ACH_MIRRORED] = _copy(mirrored)
	var settings := _dict(local, SaveMigrations.KEY_SETTINGS).duplicate(true)
	var cs := _dict(cloud, SaveMigrations.KEY_SETTINGS)
	for k: String in SYNCED_SETTINGS:
		if cs.has(k):
			settings[k] = _copy(cs[k])
	out[SaveMigrations.KEY_SETTINGS] = settings
	var sync := _dict(local, KEY_SYNC).duplicate(true)
	sync[SYNC_GARAGE_AT] = stamp(cloud, SYNC_GARAGE_AT)
	out[KEY_SYNC] = sync
	return out


## Whether two documents have the same cloud copy (nothing to upload or apply).
static func same_cloud(a: Dictionary, b: Dictionary) -> bool:
	return canonical(to_cloud(a)) == canonical(to_cloud(b))


## Whether merging changed what the game reads on this device.
static func same_local(a: Dictionary, b: Dictionary) -> bool:
	return canonical(a) == canonical(b)


## A stable text form: sorted keys, whole numbers as integers.
static func canonical(v: Variant) -> String:
	return JSON.stringify(_norm(v), "", true)


## sync.<key> of a document (0 when none).
static func stamp(doc: Dictionary, key: String) -> int:
	var v: Variant = _dict(doc, KEY_SYNC).get(key, 0)
	return int(v) if (v is int or v is float) and is_finite(float(v)) else 0


## For the conflict chooser: {xp, runs} of a document (0 when absent).
static func summary(doc: Dictionary) -> Dictionary:
	var st := _dict(doc, SaveMigrations.KEY_STATS)
	return {STAT_XP: _int(st.get(STAT_XP, 0)), STAT_RUNS: _int(st.get(STAT_RUNS, 0))}


# ---------------------------------------------------------------- Rules

static func _merge_flags(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(true)
	for k: Variant in b:
		var bv: Variant = b[k]
		if bv is bool:
			out[k] = bool(out.get(k, false)) or bv
		elif not out.has(k):
			out[k] = _copy(bv)
	return out


## Numbers: the larger; booleans: or; anything else: this device's when it has one.
static func _merge_max(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in a:
		out[k] = _num(a[k])
	for k: Variant in b:
		var bv: Variant = _num(b[k])
		if not out.has(k):
			out[k] = _copy(bv)
			continue
		var av: Variant = out[k]
		if _is_num(av) and _is_num(bv):
			out[k] = bv if float(bv) > float(av) else av
		elif av is bool and bv is bool:
			out[k] = av or bv
	return out


## Union; numbers: the smaller (an unlock's earliest run, an achievement's earliest day).
static func _merge_min(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in a:
		out[k] = _num(a[k])
	for k: Variant in b:
		var bv: Variant = _num(b[k])
		if not out.has(k):
			out[k] = _copy(bv)
		elif _is_num(out[k]) and _is_num(bv) and float(bv) < float(out[k]):
			out[k] = bv
	return out


static func _merge_journeys(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(true)
	for mode: Variant in b:
		var bv: Variant = b[mode]
		if not (bv is Dictionary):
			continue
		var be := bv as Dictionary
		var av: Variant = out.get(mode)
		if not (av is Dictionary):
			out[mode] = _copy(be)
			continue
		var e := (av as Dictionary).duplicate(true)
		e[JOURNEY_COUNT] = _num(maxf(_float(e.get(JOURNEY_COUNT, 0)), _float(be.get(JOURNEY_COUNT, 0))))
		for k: String in [JOURNEY_BEST_TIME, JOURNEY_BEST_DISTANCE]:
			if _is_num(be.get(k)) and (not _is_num(e.get(k)) or float(be[k]) < float(e[k])):
				e[k] = _num(be[k])
		out[mode] = e
	return out


static func _merge_achievements(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(true)
	if _has(a, b, ACH_UNLOCKED):
		out[ACH_UNLOCKED] = _merge_min(_dict(a, ACH_UNLOCKED), _dict(b, ACH_UNLOCKED))
	if _has(a, b, ACH_PROGRESS):
		out[ACH_PROGRESS] = _merge_max(_dict(a, ACH_PROGRESS), _dict(b, ACH_PROGRESS))
	for k: Variant in b:
		if not out.has(k) and str(k) != ACH_MIRRORED:
			out[k] = _copy(b[k])
	return out


# ---------------------------------------------------------------- Helpers

static func _has(a: Dictionary, b: Dictionary, key: String) -> bool:
	return a.has(key) or b.has(key)


static func _dict(d: Dictionary, key: String) -> Dictionary:
	var v: Variant = d.get(key)
	return v if v is Dictionary else {}


static func _is_num(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))


static func _float(v: Variant) -> float:
	return float(v) if _is_num(v) else 0.0


static func _int(v: Variant) -> int:
	return int(v) if _is_num(v) else 0


## A whole JSON number back as an int.
static func _num(v: Variant) -> Variant:
	if v is float and is_finite(v as float) and (v as float) == floorf(v as float) \
			and absf(v as float) <= MAX_EXACT_INT:
		return int(v)
	return v


static func _copy(v: Variant) -> Variant:
	if v is Dictionary:
		return (v as Dictionary).duplicate(true)
	if v is Array:
		return (v as Array).duplicate(true)
	return _num(v)


static func _norm(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k: Variant in v:
			out[str(k)] = _norm((v as Dictionary)[k])
		return out
	if v is Array:
		var a: Array = []
		for x: Variant in v:
			a.append(_norm(x))
		return a
	if v is StringName:
		return String(v)
	return _num(v)
