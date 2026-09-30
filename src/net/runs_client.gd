class_name NetRunsClient
extends Node
## Single-player run submission, the offline queue, the one-time legacy upload, and the
## leaderboard reads (NetBoards) for the screens. Spec: multiplayer handoff →
## Leaderboards (single-player runs submitted when a run ends; "verifying"; migration of
## local personal bests as legacy entries), Client changes (`api.gd`: boards and runs);
## docs/SERVER.md → Leaderboards & runs API. WP N7.2; docs/NET_CLIENT.md → Runs client.
##
## Listens to `Events.run_over`. A Journey or Daily Drive run (NetRunPayload.eligible)
## becomes a NetRunSubmission with a fresh idempotency key and is stored in the queue
## (its own document next to the session's: NetFileStore / NetWebStore) before anything
## is sent, so a run survives a closed app. Then, while the session is online, the queue
## is sent in order, one request at a time:
##   - 201 / 200 `duplicate`: the receipt (run id, verification, placements) goes on the
##     submission, the run leaves the queue. `rejected` with `build_unsupported` is the
##     results screen's UPDATE REQUIRED.
##   - network, 5xx, 429: it stays, with the same key; the next try is after
##     `runs_retry_s` (doubling to `runs_retry_max_s`) or the 429's Retry-After. Back
##     online (the session's status) tries at once.
##   - any other 4xx: dropped (the server will never take it).
## A queued run from another account stays for that account; one past the server's date
## window is dropped. Loop practice runs are never submitted.
##
## Replays (N8.1; docs/NET_CLIENT.md → Replays): a NetReplayRecorder child records every
## Journey and Daily run. At run_over the replay is stored on the device next to the queued
## run (its own document, "replay_<key>": base64 in NetFileStore / NetWebStore), before
## anything is sent. When the receipt says `replay_required` (a pending run), an upload
## (run id, key, account) joins the uploads queue; otherwise the replay is deleted. Uploads
## go after the runs in the same pass, one at a time, as `POST /runs/{run_id}/replay`
## (the .wbr bytes with the receipt's run id patched into the header): 201 / 200 (the
## server already has it) delete it; network, 5xx, 429 and session failures keep it for
## the same retry schedule; any other 4xx (not required, too large, not the owner)
## drops it. At most `replay_keep_max` replays wait on the device (the oldest go).
##
## Legacy upload (once per account): the local Journey best (Save) as a `legacy` entry,
## `POST /runs/legacy`, the first time the account is online. The save keeps no Daily
## date (the server refuses those) and no longest distance, so Journey is all there is.
##
## The game's session (the `Net` autoload, `auto_start`) gets one automatically: the
## screens call ensure(). Tests and previews configure() their own.

signal submission_changed(sub: NetRunSubmission)
## After a legacy upload attempt that settled (accepted, already uploaded, or refused).
signal legacy_finished(result: NetApiResult)

const DOC_VERSION := 1
const K_VERSION := "v"
const K_QUEUE := "queue"
const K_LEGACY := "legacy"
const I_KEY := "key"
const I_ACCOUNT := "account"
const I_BODY := "body"
const I_CREATED := "created"
const K_UPLOADS := "uploads"
const K_REPLAYS := "replays"
const I_RUN := "run_id"
const I_REPLAY := "replay"
const REPLAY_B64 := "b64"
const REPLAY_STORE_PREFIX := "replay_"
const PATH_REPLAY_SUFFIX := "/replay"

const PATH_RUNS := "/runs"
const PATH_LEGACY := "/runs/legacy"
const STORE_PREFIX := "runs"
const CAR_NODE := "PlayerCar"
const S_PER_DAY := 86400.0
const USEC_PER_S := 1000000.0

## The live client, null when none.
static var current: NetRunsClient

var session: NetSession
var tuning: NetTuning
var store: NetSessionStore
var time: NetTimeSource
var boards: NetBoards
## () -> float: unix seconds (invalid = the session's clock).
var unix_clock: Callable
## () -> Dictionary {"journey": int, "distance_m": float}: the local bests for the
## legacy upload (invalid = the Save autoload).
var local_bests: Callable
## (results: Dictionary) -> String: the car the run was driven with (invalid = the
## payload's `car`, else the PlayerCar in the tree).
var car_of: Callable
## The latest run_over's submission (null when that run was not eligible).
var last: NetRunSubmission
## N8.1: records the runs (a child; null until configured).
var recorder: NetReplayRecorder
## (results: Dictionary, date: String) -> PackedByteArray: the finished run's replay
## (invalid = the recorder's). Tests hand in a made-up replay.
var replay_source: Callable
## (key: String) -> NetSessionStore: where a replay waits (invalid = the platform's store).
var replay_store_for: Callable

var _doc: Dictionary = {}
var _subs: Dictionary[String, NetRunSubmission] = {}
var _sending: bool = false
var _legacy_busy: bool = false
var _retry_at_usec: int = -1
var _retry_delay_s: float = 0.0
var _configured: bool = false


func _init() -> void:
	name = "RunsClient"
	process_mode = Node.PROCESS_MODE_ALWAYS


## The game's client: the one attached to the game's session (created on first use), or
## null when there is no online session (native dev runs, `?server=off`, tests).
static func ensure() -> NetRunsClient:
	if current != null and is_instance_valid(current):
		return current
	var s := NetSession.current
	if s == null or not is_instance_valid(s) or not s.auto_start or not s.is_inside_tree() or s.tuning == null:
		return null
	var c := NetRunsClient.new()
	c.configure(s, platform_store(s), s.tuning)
	s.add_child(c)
	return c


## The queue's store for a session's server: `runs` next to its `session` document.
static func platform_store(s: NetSession) -> NetSessionStore:
	var doc := STORE_PREFIX + NetSession.store_name(s.base_url, s.tuning).trim_prefix(NetSession.STORE_DEFAULT)
	if OS.has_feature("web"):
		return NetWebStore.new(NetJsBridge.new(), doc)
	return NetFileStore.new(doc)


func configure(s: NetSession, queue_store: NetSessionStore, net_tuning: NetTuning, clock: NetTimeSource = null) -> void:
	session = s
	store = queue_store
	tuning = net_tuning
	time = clock if clock != null else NetTimeSource.new()
	boards = NetBoards.new(s, net_tuning, time)
	_doc = store.load_data()
	if recorder == null:
		recorder = NetReplayRecorder.new(net_tuning, net_tuning.client_build)
		add_child(recorder)
	_configured = true


func _enter_tree() -> void:
	if current == null or not is_instance_valid(current):
		current = self
	if not Events.run_over.is_connected(on_run_over):
		Events.run_over.connect(on_run_over)
	if session != null and not session.status_changed.is_connected(_on_status):
		session.status_changed.connect(_on_status)


func _exit_tree() -> void:
	if current == self:
		current = null
	if Events.run_over.is_connected(on_run_over):
		Events.run_over.disconnect(on_run_over)
	if session != null and is_instance_valid(session) and session.status_changed.is_connected(_on_status):
		session.status_changed.disconnect(_on_status)


func _ready() -> void:
	kick()


func _process(_delta: float) -> void:
	if _retry_at_usec >= 0 and time.now_usec() >= _retry_at_usec and _online():
		_retry_at_usec = -1
		flush()


# ---------------------------------------------------------------- Runs

## Events.run_over: queue the run (when eligible) and send it if online.
func on_run_over(results: Dictionary) -> void:
	if not _configured or not NetRunPayload.eligible(results, tuning):
		last = null
		if recorder != null:
			recorder.cancel()
		return
	var sub := NetRunSubmission.new()
	sub.key = NetRunPayload.uuid4()
	sub.results = results
	sub.mode = String(results.get(RunStats.MODE, ""))
	sub.date = NetRunPayload.run_date(sub.mode, int(results.get(RunStats.SEED, 0)), now_unix())
	var body := NetRunPayload.build(results, sub.key, sub.date, _car(results), tuning.client_build)
	var item := {I_KEY: sub.key, I_ACCOUNT: session.account_id() if session != null else "",
			I_BODY: body, I_CREATED: now_unix()}
	var replay := _finish_replay(results, sub.date)
	if not replay.is_empty() and _save_replay(sub.key, replay):
		item[I_REPLAY] = true
		sub.replay_state = NetRunSubmission.REPLAY_STORED
	var q := _queue()
	q.append(item)
	while q.size() > maxi(tuning.runs_queue_max, 1):
		var dropped: Dictionary = q.pop_front()
		_expire(String(dropped.get(I_KEY, "")))
		_drop_replay(String(dropped.get(I_KEY, "")))
	_persist()
	_subs[sub.key] = sub
	last = sub
	sub.state = NetRunSubmission.State.QUEUED
	sub.waiting = _wait_reason()
	submission_changed.emit(sub)
	flush()


## Sends the queue now (online only; one pass, in order). Callers never need to await it.
func flush() -> void:
	if _sending or not _online():
		_mark_waiting()
		return
	_sending = true
	var account := session.account_id()
	var i := 0
	while i < _queue().size():
		var item: Dictionary = _queue()[i]
		var key := String(item.get(I_KEY, ""))
		var played_by := String(item.get(I_ACCOUNT, ""))
		if not played_by.is_empty() and played_by != account:
			i += 1   # another account's run waits for that account
			continue
		if _expired(item):
			_remove(key)
			_expire(key)
			_drop_replay(key)
			continue
		var sub := sub_for(key, item)
		sub.state = NetRunSubmission.State.SENDING
		submission_changed.emit(sub)
		var body := NetRunPayload.normalize(item.get(I_BODY, {}) as Dictionary)
		var r: NetApiResult = await session.api.request(HTTPClient.METHOD_POST, PATH_RUNS, body, NetApi.AUTH)
		if r.ok:
			sub.apply_receipt(r.data)
			_after_receipt(sub, item, played_by if not played_by.is_empty() else account)
			_remove(key)
			_retry_delay_s = 0.0
			submission_changed.emit(sub)
			continue
		sub.error = r.error
		if _keeps(r):
			sub.state = NetRunSubmission.State.QUEUED
			sub.waiting = _wait_for(r)
			submission_changed.emit(sub)
			if r.is_transient():
				_schedule_retry(r.retry_after_s)
			break
		sub.state = NetRunSubmission.State.FAILED
		_remove(key)
		_drop_replay(key)
		submission_changed.emit(sub)
	if _retry_at_usec < 0:
		await _upload_replays(account)
	_sending = false


## Runs still waiting on this device.
func queued_count() -> int:
	return _queue().size()


func queued_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for item: Dictionary in _queue():
		out.append(String(item.get(I_KEY, "")))
	return out


## The submission for a run_over payload (the same Dictionary), or null.
func submission_for(results: Dictionary) -> NetRunSubmission:
	if last != null and is_same(last.results, results):
		return last
	for k: String in _subs:
		if is_same(_subs[k].results, results):
			return _subs[k]
	return null


## The submission of a queued item (made for runs queued in an earlier launch).
func sub_for(key: String, item: Dictionary = {}) -> NetRunSubmission:
	if _subs.has(key):
		return _subs[key]
	var sub := NetRunSubmission.new()
	sub.key = key
	var body: Variant = item.get(I_BODY, {})
	if body is Dictionary:
		sub.mode = String((body as Dictionary).get(NetRunPayload.MODE, ""))
		sub.date = String((body as Dictionary).get(NetRunPayload.DATE, ""))
	_subs[key] = sub
	return sub


## Seconds until the next automatic try (-1: none planned).
func retry_in_s() -> float:
	if _retry_at_usec < 0:
		return -1.0
	return maxf(0.0, float(_retry_at_usec - time.now_usec()) / USEC_PER_S)


## Online work: the queue and the legacy upload.
func kick() -> void:
	if not _online():
		_mark_waiting()
		return
	flush()
	upload_legacy()


func _on_status(_s: NetSession.Status) -> void:
	if _online():
		_retry_at_usec = -1
		kick()
	else:
		_mark_waiting()


# ---------------------------------------------------------------- Replays (N8.1)

## Replays waiting for their upload (after a receipt that required one).
func pending_uploads() -> int:
	return _uploads().size()


## Replays kept on this device (waiting for a receipt or an upload).
func stored_replays() -> PackedStringArray:
	var out := PackedStringArray()
	for k: Variant in _replays():
		out.append(String(k))
	return out


func _finish_replay(results: Dictionary, date: String) -> PackedByteArray:
	if replay_source.is_valid():
		return replay_source.call(results, date) as PackedByteArray
	if recorder == null:
		return PackedByteArray()
	return recorder.finish(results, date)


## The receipt decides: an upload for a pending run that needs it, else the replay goes.
func _after_receipt(sub: NetRunSubmission, item: Dictionary, account: String) -> void:
	if not bool(item.get(I_REPLAY, false)):
		return
	var key := sub.key
	if sub.replay_required and not sub.run_id.is_empty() \
			and sub.verification == NetRunSubmission.VERIFICATION_PENDING:
		for u: Dictionary in _uploads():
			if String(u.get(I_KEY, "")) == key:
				return
		_uploads().append({I_KEY: key, I_RUN: sub.run_id, I_ACCOUNT: account, I_CREATED: now_unix()})
		sub.replay_state = NetRunSubmission.REPLAY_QUEUED
		_persist()
	else:
		_drop_replay(key)
		sub.replay_state = NetRunSubmission.REPLAY_NOT_NEEDED


## Sends this account's waiting replays, in order (called from flush()).
func _upload_replays(account: String) -> void:
	var i := 0
	while i < _uploads().size():
		var u: Dictionary = _uploads()[i]
		var key := String(u.get(I_KEY, ""))
		var run_id := String(u.get(I_RUN, ""))
		if String(u.get(I_ACCOUNT, "")) != account:
			i += 1
			continue
		var bytes := _load_replay(key)
		if bytes.is_empty() or not run_id.is_valid_int() \
				or not NetReplayFile.patch_run_id(bytes, run_id.to_int()):
			_remove_upload(key)
			_drop_replay(key)
			continue
		var sub := sub_for(key)
		sub.replay_state = NetRunSubmission.REPLAY_UPLOADING
		submission_changed.emit(sub)
		var path := PATH_RUNS + "/" + run_id + PATH_REPLAY_SUFFIX
		var r: NetApiResult = await session.api.request(HTTPClient.METHOD_POST, path, bytes, NetApi.AUTH)
		if r.ok:
			_remove_upload(key)
			_drop_replay(key)
			_retry_delay_s = 0.0
			sub.replay_state = NetRunSubmission.REPLAY_UPLOADED
			submission_changed.emit(sub)
			continue
		sub.error = r.error
		if _keeps(r):
			sub.replay_state = NetRunSubmission.REPLAY_QUEUED
			submission_changed.emit(sub)
			if r.is_transient():
				_schedule_retry(r.retry_after_s)
			return
		_remove_upload(key)
		_drop_replay(key)
		sub.replay_state = NetRunSubmission.REPLAY_REFUSED
		submission_changed.emit(sub)


## Stores a replay (base64 in its own document) and records it in the queue document;
## past replay_keep_max the oldest stored replays go. False when it could not be kept.
func _save_replay(key: String, bytes: PackedByteArray) -> bool:
	if bytes.size() > tuning.replay_max_bytes:
		return false
	var st := _replay_store(key)
	if not st.save_data({REPLAY_B64: Marshalls.raw_to_base64(bytes)}):
		return false
	var list := _replays()
	list.append(key)
	while list.size() > maxi(tuning.replay_keep_max, 1):
		var old := String(list[0])
		_drop_replay(old)
		_remove_upload(old)
	_persist()
	return true


func _load_replay(key: String) -> PackedByteArray:
	var d := _replay_store(key).load_data()
	var b64: Variant = d.get(REPLAY_B64, "")
	if not (b64 is String) or (b64 as String).is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(b64 as String)


func _drop_replay(key: String) -> void:
	var list := _replays()
	var i := list.find(key)
	if i < 0:
		return
	list.remove_at(i)
	_replay_store(key).clear()
	_persist()


func _replay_store(key: String) -> NetSessionStore:
	if replay_store_for.is_valid():
		return replay_store_for.call(key) as NetSessionStore
	var doc := REPLAY_STORE_PREFIX + key
	if OS.has_feature("web"):
		return NetWebStore.new(NetJsBridge.new(), doc)
	return NetFileStore.new(doc)


func _uploads() -> Array:
	var u: Variant = _doc.get(K_UPLOADS)
	if not (u is Array):
		u = []
		_doc[K_UPLOADS] = u
	return u as Array


func _replays() -> Array:
	var r: Variant = _doc.get(K_REPLAYS)
	if not (r is Array):
		r = []
		_doc[K_REPLAYS] = r
	return r as Array


func _remove_upload(key: String) -> void:
	var u := _uploads()
	for i in u.size():
		if String((u[i] as Dictionary).get(I_KEY, "")) == key:
			u.remove_at(i)
			_persist()
			return


# ---------------------------------------------------------------- Legacy

## The account's legacy upload has been done (or had nothing to send).
func legacy_done(account_id: String = "") -> bool:
	var id := account_id if not account_id.is_empty() else (session.account_id() if session != null else "")
	var d: Variant = _doc.get(K_LEGACY, {})
	return d is Dictionary and bool((d as Dictionary).get(id, false))


## POST /runs/legacy once per account with the local personal bests (online only).
func upload_legacy() -> void:
	if _legacy_busy or not _online():
		return
	var account := session.account_id()
	if account.is_empty() or legacy_done(account):
		return
	var bests: Dictionary = local_bests.call() if local_bests.is_valid() else _save_bests()
	var entries: Array[Dictionary] = []
	var journey := int(bests.get(NetBoards.JOURNEY, 0))
	if journey > 0:
		entries.append({"board": NetBoards.JOURNEY, "score": journey})
	var distance := roundi(float(bests.get("distance_m", 0.0)))
	if distance > 0:
		entries.append({"board": NetBoards.DISTANCE, "score": distance})
	if entries.is_empty():
		_mark_legacy(account)
		legacy_finished.emit(NetApiResult.success(0, {}))
		return
	_legacy_busy = true
	var r: NetApiResult = await session.api.request(HTTPClient.METHOD_POST, PATH_LEGACY,
			{"entries": entries}, NetApi.AUTH)
	_legacy_busy = false
	if r.ok or not _keeps(r):
		# Accepted, already uploaded, over the cap, or refused for good: never again.
		_mark_legacy(account)
	legacy_finished.emit(r)


func _mark_legacy(account: String) -> void:
	var d: Variant = _doc.get(K_LEGACY, {})
	var dd: Dictionary = d if d is Dictionary else {}
	dd[account] = true
	_doc[K_LEGACY] = dd
	_persist()


static func _save_bests() -> Dictionary:
	return {NetBoards.JOURNEY: Save.best_score(RunContext.MODE_JOURNEY)}


# ---------------------------------------------------------------- Helpers

## Wall-clock unix seconds (dates, the queue's age).
func now_unix() -> float:
	if unix_clock.is_valid():
		return float(unix_clock.call())
	if session != null:
		return session.now_unix()
	return Time.get_unix_time_from_system()


func _online() -> bool:
	return _configured and session != null and is_instance_valid(session) and session.is_online()


## Failures that keep the run queued: transient ones (network, 5xx, 429), and the
## session's (not signed in, a dead token, a ban): the run is fine, the account is not.
static func _keeps(r: NetApiResult) -> bool:
	return r.is_transient() or r.status == NetApi.HTTP_UNAUTHORIZED or r.error == NetApiResult.BANNED \
			or r.error == NetSession.ERR_NOT_SIGNED_IN


static func _wait_for(r: NetApiResult) -> String:
	if r.error == NetApiResult.RATE_LIMITED:
		return NetRunSubmission.WAIT_RATE_LIMITED
	if r.error == NetApiResult.BANNED:
		return NetRunSubmission.WAIT_BANNED
	if r.status == NetApi.HTTP_UNAUTHORIZED:
		return NetRunSubmission.WAIT_SIGN_IN
	return NetRunSubmission.WAIT_OFFLINE


func _wait_reason() -> String:
	if session == null:
		return NetRunSubmission.WAIT_OFFLINE
	match session.status:
		NetSession.Status.BANNED:
			return NetRunSubmission.WAIT_BANNED
		NetSession.Status.SIGNED_OUT, NetSession.Status.FAILED:
			return NetRunSubmission.WAIT_SIGN_IN
	return NetRunSubmission.WAIT_OFFLINE


## Queued runs of this launch say why they wait (the session went offline).
func _mark_waiting() -> void:
	if _sending:
		return
	var why := _wait_reason()
	for item: Dictionary in _queue():
		var k := String(item.get(I_KEY, ""))
		if _subs.has(k):
			var sub := _subs[k]
			if sub.state == NetRunSubmission.State.QUEUED and sub.waiting != why \
					and sub.waiting != NetRunSubmission.WAIT_RATE_LIMITED:
				sub.waiting = why
				submission_changed.emit(sub)


func _schedule_retry(hint_s: float) -> void:
	if _retry_delay_s <= 0.0:
		_retry_delay_s = tuning.runs_retry_s
	else:
		_retry_delay_s = minf(tuning.runs_retry_max_s, _retry_delay_s * 2.0)
	var d := maxf(_retry_delay_s, hint_s)
	_retry_at_usec = time.now_usec() + roundi(d * USEC_PER_S)


## Past the server's window: the end of the run's UTC day + `runs_date_late_s`.
func _expired(item: Dictionary) -> bool:
	var body: Variant = item.get(I_BODY, {})
	if not (body is Dictionary):
		return true
	var start := NetRunPayload.date_start(String((body as Dictionary).get(NetRunPayload.DATE, "")))
	if start < 0:
		return true
	return now_unix() >= float(start) + S_PER_DAY + tuning.runs_date_late_s


func _expire(key: String) -> void:
	if _subs.has(key):
		_subs[key].state = NetRunSubmission.State.EXPIRED
		submission_changed.emit(_subs[key])


func _queue() -> Array:
	var q: Variant = _doc.get(K_QUEUE)
	if not (q is Array):
		q = []
		_doc[K_QUEUE] = q
	return q as Array


func _remove(key: String) -> void:
	var q := _queue()
	for i in q.size():
		if String((q[i] as Dictionary).get(I_KEY, "")) == key:
			q.remove_at(i)
			break
	_persist()


func _persist() -> void:
	_doc[K_VERSION] = DOC_VERSION
	store.save_data(_doc)


func _car(results: Dictionary) -> String:
	if car_of.is_valid():
		return String(car_of.call(results))
	var c: Variant = results.get(&"car", "")
	if c is String or c is StringName:
		if not String(c).is_empty():
			return String(c)
	if is_inside_tree():
		var n := get_tree().root.find_child(CAR_NODE, true, false)
		if n != null:
			var def: Variant = n.get(&"car")
			if def is CarDef:
				return String((def as CarDef).id)
	return NetRunPayload.CAR_FALLBACK
