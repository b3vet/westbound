class_name NetCloudSave
extends Node
## Cloud save sync: the local save follows the player's Apple / Google account across
## devices. WP N11; docs/SAVE.md → Cloud sync; docs/SERVER.md → Cloud save.
##
## When: after a sign-in (app start included) and an account switch, when a provider gets
## linked, on coming back to the app (resume, a tab shown) once the last sync is older than
## `cloud_resume_min_s`, and `cloud_after_run_delay_s` after a run's results (debounced:
## quick retries make one upload). Never mid-run: a due sync waits until the run leaves
## RUNNING. Only for accounts with a provider linked (a device account cannot move between
## devices, so it has nothing to sync with).
##
## How (sync()): GET /save → merge the cloud copy into the local document (SaveMerge, the
## per-section rules) → put the result in place locally if it changed (Save.apply_cloud
## keeps the previous document as a backup first; mid-run it waits) → PUT the merged cloud
## copy with If-Match when it differs from the server's. A 409 (another device wrote first)
## carries the server's copy: merge again and retry, up to `cloud_conflict_rounds`.
##
## Offline-safe: every failure is a state, never an error. Network failures, 5xx and 429
## retry after `cloud_retry_s`, doubling up to `cloud_retry_max_s`. Nothing waits on it.
## Never loses data: the merge only adds progress (max / union), downloads keep a local
## backup, and a newer build's cloud copy or local save is never overwritten.

signal status_changed(status: Status)
## A sync finished (uploaded and / or applied).
signal synced(revision: int)

enum Status { OFF, IDLE, SYNCING, SYNCED, WAITING, OFFLINE, ERROR }

## Client-side error codes (`last_error`).
const ERR_NEWER := "cloud_save_newer"
const ERR_TOO_LARGE := "save_too_large"
const ERR_CONFLICTS := "revision_conflict"
const USEC_PER_S := 1000000.0

var session: NetSession
var tuning: NetTuning
var target: NetCloudSaveTarget
var time: NetTimeSource
var status: Status = Status.OFF
## The server's revision after the last sync (0 = none yet).
var revision: int = 0
## Unix seconds of the last successful sync (0 = never this launch).
var last_sync_unix: int = 0
## Why the last sync failed ("" after a success).
var last_error: String = ""
## How the next sync merges (the conflict chooser sets KEEP_LOCAL or USE_CLOUD once).
var next_mode: SaveMerge.Mode = SaveMerge.Mode.MERGE
## Syncs completed and uploads made (tests, the dev HUD).
var syncs: int = 0
var uploads: int = 0
var applies: int = 0

var _due_usec: int = -1
var _retry_delay_s: float = 0.0
var _busy: bool = false
## A merged document waiting for the run to end before it is put in place.
var _pending: Dictionary = {}
var _last_sync_usec: int = -1


func _init() -> void:
	name = "CloudSave"
	process_mode = Node.PROCESS_MODE_ALWAYS


## Wires the sync to `s` (its API, tuning and clock) and the local save `t` (the Save
## autoload when null).
func setup(s: NetSession, t: NetCloudSaveTarget = null) -> void:
	_connect(false)
	session = s
	tuning = s.tuning
	time = s.time
	target = t if t != null else NetCloudSaveTarget.new()
	_connect(true)
	_refresh_status()


func _connect(on: bool) -> void:
	if session == null or not is_instance_valid(session):
		return
	var pairs := [
		[session.signed_in, _on_signed_in], [session.profile_changed, _on_profile_changed],
		[session.account_switched, _on_switched], [session.status_changed, _on_session_status],
		[Events.run_over, _on_run_over],
	]
	for pair: Array in pairs:
		var sig: Signal = pair[0]
		var cb: Callable = pair[1]
		if on and not sig.is_connected(cb):
			sig.connect(cb)
		elif not on and sig.is_connected(cb):
			sig.disconnect(cb)


func _exit_tree() -> void:
	_connect(false)


func _process(_delta: float) -> void:
	poll()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		on_resume()


# ---------------------------------------------------------------- Public

## Sync is possible: online, with a provider linked, and the server's cloud save on.
func enabled() -> bool:
	return session != null and is_instance_valid(session) and session.is_online() \
			and session.profile != null and session.profile.has_provider() and session.cloud_save_on()


## Asks for a sync `delay_s` from now (the earliest request wins).
func request_sync(delay_s: float = 0.0) -> void:
	if not enabled():
		_refresh_status()
		return
	var at := time.now_usec() + roundi(maxf(delay_s, 0.0) * USEC_PER_S)
	if _due_usec < 0 or at < _due_usec:
		_due_usec = at
	if status == Status.OFF or status == Status.SYNCED or status == Status.ERROR:
		_set_status(Status.IDLE)


## Coming back to the app: sync when the last one is old.
func on_resume() -> void:
	if not enabled():
		return
	var age_s := INF if _last_sync_usec < 0 else float(time.now_usec() - _last_sync_usec) / USEC_PER_S
	if age_s >= tuning.cloud_resume_min_s:
		request_sync()


## Time-driven work: a due sync (when the game is idle) and a waiting download.
func poll() -> void:
	if target == null or _busy:
		return
	if not _pending.is_empty() and target.can_apply():
		_apply(_pending)
		_pending = {}
		_refresh_status()
	if _due_usec >= 0 and time.now_usec() >= _due_usec and target.idle():
		_due_usec = -1
		if enabled():
			sync()
		else:
			_refresh_status()


## Seconds until the next planned sync (-1: none).
func due_in_s() -> float:
	return -1.0 if _due_usec < 0 else maxf(0.0, float(_due_usec - time.now_usec()) / USEC_PER_S)


## One sync now (see the class docs). Returns true when it finished.
func sync() -> bool:
	if _busy or not enabled():
		return false
	_busy = true
	_due_usec = -1   # this sync answers every request made so far
	_set_status(Status.SYNCING)
	var mode := next_mode
	next_mode = SaveMerge.Mode.MERGE
	var r := await session.api.get_save()
	var ok := false
	if r.ok:
		ok = await _merge_and_upload(r.int_field("revision"), _data_of(r.data), mode)
	else:
		_fail(r.error, r.is_transient())
	_busy = false
	if ok:
		syncs += 1
		last_error = ""
		_retry_delay_s = 0.0
		_last_sync_usec = time.now_usec()
		last_sync_unix = int(session.now_unix())
		_set_status(Status.WAITING if not _pending.is_empty() else Status.SYNCED)
		synced.emit(revision)
	return ok


# ---------------------------------------------------------------- Flow

func _merge_and_upload(cloud_rev: int, cloud: Dictionary, mode: SaveMerge.Mode) -> bool:
	var rounds := 0
	while true:
		if SaveMigrations.version_of(cloud) > SaveMigrations.VERSION:
			# A newer build wrote it: this one would drop what it cannot read.
			_fail(ERR_NEWER, false)
			return false
		var local := target.snapshot()
		var merged := SaveMerge.merge(local, cloud, mode)
		if not SaveMerge.same_local(local, merged):
			if target.can_apply():
				_apply(merged)
			else:
				_pending = merged
		if not cloud.is_empty() and SaveMerge.same_cloud(merged, cloud):
			revision = cloud_rev
			return true
		if target.read_only():
			revision = cloud_rev
			return true
		var up := SaveMerge.to_cloud(merged)
		var max_bytes := session.cloud_save_max_bytes()
		if max_bytes > 0 and JSON.stringify(up).to_utf8_buffer().size() > max_bytes:
			_fail(ERR_TOO_LARGE, false)
			return false
		var p := await session.api.put_save(up, cloud_rev)
		if p.ok:
			revision = p.int_field("revision")
			uploads += 1
			return true
		var save: Variant = p.data.get("save")
		if p.status == NetApi.HTTP_CONFLICT and p.error == ERR_CONFLICTS and save is Dictionary:
			rounds += 1
			if rounds >= tuning.cloud_conflict_rounds:
				_fail(ERR_CONFLICTS, true)
				return false
			cloud_rev = int((save as Dictionary).get("revision", 0))
			cloud = _data_of(save as Dictionary)
			continue
		_fail(p.error, p.is_transient())
		return false
	return false


func _apply(doc: Dictionary) -> void:
	if target.apply(doc):
		applies += 1


static func _data_of(body: Dictionary) -> Dictionary:
	var d: Variant = body.get("data")
	return d if d is Dictionary else {}


func _fail(code: String, transient: bool) -> void:
	last_error = code
	if transient:
		if _retry_delay_s <= 0.0:
			_retry_delay_s = tuning.cloud_retry_s
		else:
			_retry_delay_s = minf(tuning.cloud_retry_max_s, _retry_delay_s * 2.0)
		_due_usec = time.now_usec() + roundi(_retry_delay_s * USEC_PER_S)
		_set_status(Status.OFFLINE)
	else:
		_set_status(Status.ERROR)


func _refresh_status() -> void:
	if _busy:
		return
	if not enabled():
		_set_status(Status.OFF)
	elif status == Status.OFF:
		_set_status(Status.IDLE)


func _set_status(s: Status) -> void:
	if s == status:
		return
	status = s
	status_changed.emit(s)


# ---------------------------------------------------------------- Triggers

func _on_signed_in(_p: NetProfile) -> void:
	request_sync()


func _on_profile_changed(_p: NetProfile) -> void:
	# A provider just linked (or unlinked): sync now, or turn off.
	if enabled() and (status == Status.OFF or last_sync_unix == 0):
		request_sync()
	_refresh_status()


func _on_switched(_previous: String) -> void:
	revision = 0
	last_sync_unix = 0
	_last_sync_usec = -1
	request_sync()


func _on_session_status(_s: NetSession.Status) -> void:
	_refresh_status()


func _on_run_over(_results: Dictionary) -> void:
	request_sync(tuning.cloud_after_run_delay_s)
