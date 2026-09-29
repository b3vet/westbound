extends WBTest
## NetRunsClient against the in-memory boards server (NetFakeBoards): a run is submitted
## on Events.run_over with exactly the server's body (built from the real RunStats
## output), the receipt is recorded, the offline queue survives a relaunch and retries
## with the same idempotency key, a duplicate answer is taken as the receipt, 429s wait,
## `build_unsupported` is the update prompt, refused and stale runs are dropped, Loop
## practice and scoreless crashes are not sent, and the legacy upload happens once per
## account. Spec: multiplayer handoff → Leaderboards (single-player runs, migration of
## local bests); docs/SERVER.md → POST /runs, POST /runs/legacy. WP N7.2.

const BASE := "https://runs.test/api/v1"
const START_USEC := 7_000_000
const SEED := 2538700399935769545
const CAR := "night_viper"
## The documented body (docs/SERVER.md → POST /runs), every key.
const CONTRACT_KEYS: Array[String] = ["idempotency_key", "mode", "seed", "date", "car", "client_build",
		"score", "distance_m", "duration_s", "legs_completed", "coast_reached", "best_chain",
		"best_multiplier", "passes", "close_passes", "threads", "cuts", "top_speed_kmh", "night_time_s",
		"hits", "journey_complete", "journey_time_s", "journey_distance_m"]
const INT_KEYS: Array[String] = ["client_build", "score", "legs_completed", "best_chain", "passes",
		"close_passes", "threads", "cuts", "hits"]
const RETRY_AFTER_LONG := 120
## 2026-09-29 00:10 UTC.
const JUST_AFTER_MIDNIGHT := 1790640600.0

var tuning: NetTuning
var fake: NetFakeBoards
var store: NetSessionStore
var queue_store: JsonStore
var time: NetVirtualTime
var session: NetSession
var _nodes: Array[Node] = []
var changes: Array[NetRunSubmission.State] = []


## A store that keeps the document as JSON text, like the file and web stores do (so
## integers come back as floats).
class JsonStore:
	extends NetSessionStore
	var text: String = ""

	func load_data() -> Dictionary:
		if text.is_empty():
			return {}
		var d: Variant = JSON.parse_string(text)
		return d if d is Dictionary else {}

	func save_data(doc: Dictionary) -> bool:
		text = JSON.stringify(doc)
		writes += 1
		return true

	func clear() -> bool:
		text = ""
		return true

	func is_persistent() -> bool:
		return true


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0


func before_each() -> void:
	fake = NetFakeBoards.new()
	store = NetSessionStore.new()
	queue_store = JsonStore.new()
	time = NetVirtualTime.new(START_USEC)
	changes.clear()
	session = null


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	await tree.process_frame


func _session() -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, store, tuning, time, BASE, 5)
	s.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(s)
	_nodes.append(s)
	return s


## A client on `s` ("a launch"), optionally with the local bests for the legacy upload.
func _client(s: NetSession, bests: Dictionary = {}) -> NetRunsClient:
	var c := NetRunsClient.new()
	c.configure(s, queue_store, tuning, time)
	c.unix_clock = func() -> float: return fake.now_s
	c.car_of = func(_r: Dictionary) -> String: return CAR
	c.local_bests = func() -> Dictionary: return bests
	c.submission_changed.connect(func(sub: NetRunSubmission) -> void: changes.append(sub.state))
	s.add_child(c)
	return c


## The run_over payload the run emits: RunStats.results plus the three best keys.
static func _payload(mode: StringName = RunContext.MODE_JOURNEY, score: int = 183_200,
		run_seed: int = SEED) -> Dictionary:
	var st := RunStats.new(0.0)
	st.distance_m = 24_018.4
	st.duration_s = 512.3
	st.legs_completed = 6
	st.best_chain = 41_200
	st.best_multiplier = 23.5
	st.passes = 212
	st.close_passes = 61
	st.threads = 9
	st.cuts = 34
	st.top_speed_mps = Units.kmh_to_mps(287.1)
	st.night_time_s = 94.0
	st.hits = 1
	var p := st.results(score, run_seed, mode)
	p[&"personal_best"] = score
	p[&"new_best"] = true
	p[&"previous_best"] = 150_000
	return p


func _online() -> NetRunsClient:
	session = _session()
	await session.start()
	return _client(session)


func _runs_requests() -> int:
	return fake.count(NetRunsClient.PATH_RUNS, HTTPClient.METHOD_POST)


# ---------------------------------------------------------------- Submission

func test_run_over_submits_the_contract_body() -> void:
	var c := await _online()
	var payload := _payload()
	Events.run_over.emit(payload)
	eq(_runs_requests(), 1, "one POST /runs")
	if not eq(fake.runs_received.size(), 1, "the server took the body"):
		return
	var text := fake.run_texts[0]
	var body: Dictionary = JSON.parse_string(text)
	var keys: Array[String] = []
	for k: Variant in body:
		keys.append(String(k))
	keys.sort()
	var want := CONTRACT_KEYS.duplicate()
	want.sort()
	eq(keys, want, "exactly the documented keys (no personal_best / new_best / previous_best)")
	for k in INT_KEYS:
		check(RegEx.create_from_string("\"%s\":-?[0-9]+[,}]" % k).search(text) != null, "%s is a JSON integer" % k)
	check(body["seed"] is String, "the seed is a decimal string")
	eq(body["seed"], "2538700399935769545", "the seed's digits survive (above 2^53)")
	eq(body["mode"], "journey")
	eq(body["date"], NetRunPayload.utc_date(fake.now_s), "the UTC date played")
	eq(body["car"], CAR)
	eq(int(body["client_build"]), tuning.client_build)
	var key := String(body["idempotency_key"])
	check(RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").search(key) != null,
			"a v4 UUID: %s" % key)
	# Every RunStats value goes through unchanged.
	for k: StringName in [RunStats.SCORE, RunStats.LEGS_COMPLETED, RunStats.BEST_CHAIN, RunStats.PASSES,
			RunStats.CLOSE_PASSES, RunStats.THREADS, RunStats.CUTS, RunStats.HITS]:
		eq(int(body[String(k)]), int(payload[k]), String(k))
	for k: StringName in [RunStats.DISTANCE_M, RunStats.DURATION_S, RunStats.BEST_MULTIPLIER,
			RunStats.TOP_SPEED_KMH, RunStats.NIGHT_TIME_S, RunStats.JOURNEY_TIME_S, RunStats.JOURNEY_DISTANCE_M]:
		near(float(body[String(k)]), float(payload[k]), 1e-3, String(k))
	for k: StringName in [RunStats.COAST_REACHED, RunStats.JOURNEY_COMPLETE]:
		eq(body[String(k)], payload[k], String(k))
	# The receipt.
	var sub := c.submission_for(payload)
	if not check(sub != null and sub == c.last, "the run has a submission"):
		return
	eq(sub.state, NetRunSubmission.State.DONE)
	eq(sub.key, key)
	check(not sub.run_id.is_empty(), "run id recorded")
	eq(sub.placements.size(), 3, "Journey feeds the week, all time and Distance")
	eq(String(sub.placements[0]["board"]), NetBoards.JOURNEY)
	eq(NetRunSubmission.rank_of(sub.placements[0]), 1)
	check(sub.new_pb(), "a first run is a personal best")
	check(sub.verifying and sub.replay_required, "a personal best needs a replay: verifying")
	eq(c.queued_count(), 0, "the queue is empty")
	eq(changes, [NetRunSubmission.State.QUEUED, NetRunSubmission.State.SENDING, NetRunSubmission.State.DONE],
			"queued first (stored before sending), then sent")
	check(fake.requests[-1]["auth"] != "", "sent with the bearer token")


func test_daily_run_sends_its_seeds_date() -> void:
	fake.now_s = JUST_AFTER_MIDNIGHT
	var c := await _online()
	var yesterday := NetRunPayload.utc_date(fake.now_s - 86400.0)
	var ys := NetRunPayload.daily_seed_of(yesterday)
	# A Daily run started before midnight and finished after: yesterday's seed.
	var payload := _payload(RunContext.MODE_DAILY, 90_000, ys)
	Events.run_over.emit(payload)
	if not eq(fake.runs_received.size(), 1):
		return
	eq(fake.runs_received[0]["date"], yesterday)
	eq(fake.runs_received[0]["mode"], "daily")
	eq(fake.runs_received[0]["seed"], String.num_int64(ys))
	var sub := c.submission_for(payload)
	eq(String(sub.placements[0]["board"]), NetBoards.DAILY)
	eq(String(sub.placements[0]["period"]), yesterday)
	eq(NetRunPayload.run_date("daily", NetRunPayload.daily_seed_of(NetRunPayload.utc_date(fake.now_s)), fake.now_s),
			NetRunPayload.utc_date(fake.now_s), "today's seed: today")


func test_loop_practice_and_scoreless_crashes_are_not_submitted() -> void:
	var c := await _online()
	var loop := _payload(&"loop")
	Events.run_over.emit(loop)
	check(c.last == null and c.submission_for(loop) == null, "Loop practice stays local")
	var crash := _payload()
	crash[RunStats.SCORE] = 0
	crash[RunStats.DISTANCE_M] = tuning.runs_min_distance_m * 0.5
	Events.run_over.emit(crash)
	check(c.last == null, "a scoreless crash at the start is not sent")
	eq(_runs_requests(), 0)
	var far := _payload()
	far[RunStats.SCORE] = 0
	far[RunStats.DISTANCE_M] = tuning.runs_min_distance_m * 2.0
	Events.run_over.emit(far)
	eq(_runs_requests(), 1, "a scoreless long drive still counts for Distance")


# ---------------------------------------------------------------- Offline queue

func test_offline_run_is_queued_and_sent_later_with_the_same_key() -> void:
	session = _session()
	fake.offline = true
	await session.start()
	eq(session.status, NetSession.Status.OFFLINE)
	var c := _client(session)
	var payload := _payload()
	Events.run_over.emit(payload)
	var sub := c.submission_for(payload)
	if not check(sub != null):
		return
	eq(sub.state, NetRunSubmission.State.QUEUED)
	eq(sub.waiting, NetRunSubmission.WAIT_OFFLINE, "OFFLINE — WILL SUBMIT")
	eq(_runs_requests(), 0, "nothing sent while offline")
	eq(c.queued_count(), 1)
	var key := sub.key
	check(queue_store.text.contains(key), "stored before anything is sent")
	# The app closes; the next launch is online.
	c.free()
	session.free()
	_nodes.clear()
	fake.offline = false
	fake.requests.clear()
	session = _session()
	var c2 := _client(session)
	eq(c2.queued_count(), 1, "the queue survived the relaunch")
	await session.start()
	await tree.process_frame
	eq(_runs_requests(), 1, "sent once back online")
	if eq(fake.runs_received.size(), 1):
		eq(fake.runs_received[0]["idempotency_key"], key, "with the same idempotency key")
	eq(c2.queued_count(), 0)
	eq(c2.sub_for(key).state, NetRunSubmission.State.DONE)


func test_network_failure_retries_with_the_same_key_and_a_duplicate_is_a_receipt() -> void:
	var c := await _online()
	fake.offline = true   # the session is online, the network drops
	var payload := _payload()
	Events.run_over.emit(payload)
	var sub := c.submission_for(payload)
	eq(sub.state, NetRunSubmission.State.QUEUED, "a network failure keeps it")
	eq(sub.error, NetApiResult.NETWORK)
	eq(fake.count(NetRunsClient.PATH_RUNS), tuning.api_max_retries + 1, "NetApi's own retries, then queued")
	near(c.retry_in_s(), tuning.runs_retry_s, 1e-6, "the next try is planned")
	var first_key := {}
	for req in fake.requests:
		if req["path"] == NetRunsClient.PATH_RUNS:
			first_key = JSON.parse_string(String(req["body"])) as Dictionary
			break
	# The server got it after all (the answer was lost): same key again = a duplicate.
	fake.offline = false
	var r: NetApiResult = await session.api.request(HTTPClient.METHOD_POST, NetRunsClient.PATH_RUNS,
			NetRunPayload.normalize(first_key), NetApi.AUTH)
	eq(r.status, 201, "the lost attempt")
	var received := fake.runs_received.size()
	time.advance_s(tuning.runs_retry_s)
	c._process(0.0)
	await tree.process_frame
	eq(sub.state, NetRunSubmission.State.DONE, "the duplicate answer is the receipt")
	check(sub.duplicate, "duplicate: true")
	eq(sub.run_id, r.str_field("run_id"), "the stored receipt's run")
	eq(sub.placements.size(), 3)
	eq(fake.runs_received.size(), received, "not stored twice")
	var attempts := 0
	for req in fake.requests:
		if req["path"] == NetRunsClient.PATH_RUNS:
			attempts += 1
			eq(String((JSON.parse_string(String(req["body"])) as Dictionary)["idempotency_key"]), sub.key,
					"every attempt carried the same key")
	eq(attempts, tuning.api_max_retries + 3, "the offline tries, the lost one, the duplicate")
	eq(c.queued_count(), 0)


func test_rate_limit_waits_for_retry_after() -> void:
	var c := await _online()
	fake.script(HTTPClient.METHOD_POST, NetRunsClient.PATH_RUNS, 429,
			{"error": "rate_limited", "message": "slow down", "retry_after_secs": RETRY_AFTER_LONG},
			PackedStringArray(["Retry-After: %d" % RETRY_AFTER_LONG]))
	var payload := _payload()
	Events.run_over.emit(payload)
	var sub := c.submission_for(payload)
	eq(sub.state, NetRunSubmission.State.QUEUED)
	eq(sub.waiting, NetRunSubmission.WAIT_RATE_LIMITED)
	near(c.retry_in_s(), float(RETRY_AFTER_LONG), 1e-6, "waits the Retry-After (longer than the backoff)")
	time.advance_s(RETRY_AFTER_LONG - 1.0)
	c._process(0.0)
	eq(_runs_requests(), 1, "not before")
	time.advance_s(1.0)
	c._process(0.0)
	await tree.process_frame
	eq(_runs_requests(), 2, "after it")
	eq(sub.state, NetRunSubmission.State.DONE)


func test_build_unsupported_is_the_update_prompt() -> void:
	var c := await _online()
	fake.min_build = tuning.client_build + 1
	var payload := _payload()
	Events.run_over.emit(payload)
	var sub := c.submission_for(payload)
	eq(sub.state, NetRunSubmission.State.REJECTED)
	eq(sub.reason, NetRunSubmission.REASON_BUILD)
	check(sub.update_required(), "UPDATE REQUIRED")
	eq(c.queued_count(), 0, "a rejected run is not retried")


func test_refused_body_is_dropped_and_stale_runs_expire() -> void:
	var c := await _online()
	fake.script(HTTPClient.METHOD_POST, NetRunsClient.PATH_RUNS, 400, {"error": "invalid_body", "message": "no"})
	var a := _payload()
	Events.run_over.emit(a)
	eq(c.submission_for(a).state, NetRunSubmission.State.FAILED)
	eq(c.queued_count(), 0, "never retried")
	eq(_runs_requests(), 1)
	# Offline for three days: past the server's date window.
	fake.offline = true
	var b := _payload()
	Events.run_over.emit(b)
	eq(c.queued_count(), 1)
	fake.offline = false
	fake.now_s += 3.0 * 86400.0
	var before := _runs_requests()
	c.flush()
	await tree.process_frame
	eq(c.submission_for(b).state, NetRunSubmission.State.EXPIRED)
	eq(c.queued_count(), 0)
	eq(_runs_requests(), before, "not sent")


func test_another_accounts_run_waits_for_it() -> void:
	var c := await _online()
	queue_store.text = ""
	c._doc = {NetRunsClient.K_QUEUE: [{NetRunsClient.I_KEY: "other-account-run-1", NetRunsClient.I_ACCOUNT: "9999",
			NetRunsClient.I_BODY: NetRunPayload.build(_payload(), "other-account-run-1",
			NetRunPayload.utc_date(fake.now_s), CAR, 1), NetRunsClient.I_CREATED: fake.now_s}]}
	c.flush()
	await tree.process_frame
	eq(_runs_requests(), 0, "not sent under this account")
	eq(c.queued_count(), 1, "kept")


# ---------------------------------------------------------------- Legacy

func test_legacy_upload_happens_once_per_account() -> void:
	session = _session()
	var c := _client(session, {"journey": 77_000})
	await session.start()
	await tree.process_frame
	eq(fake.count(NetRunsClient.PATH_LEGACY), 1, "uploaded on first connection")
	var body := JSON.parse_string(String(fake.requests[fake.requests.size() - 1]["body"])) as Dictionary
	for r in fake.requests:
		if r["path"] == NetRunsClient.PATH_LEGACY:
			body = JSON.parse_string(String(r["body"])) as Dictionary
	eq(body, {"entries": [{"board": "journey", "score": 77000.0}]}, "the journey best only (no Daily, no distance kept)")
	check(c.legacy_done(), "marked done")
	var page_entries: Array = fake.entries_of(NetBoards.JOURNEY, NetBoards.PERIOD_ALL)
	eq(String((page_entries[0] as Dictionary)["verification"]), "legacy")
	# Relaunch: never again for this account.
	c.free()
	session.free()
	_nodes.clear()
	session = _session()
	var c2 := _client(session, {"journey": 90_000})
	await session.start()
	await tree.process_frame
	eq(fake.count(NetRunsClient.PATH_LEGACY), 1, "not uploaded twice")
	check(c2.legacy_done())


func test_legacy_already_uploaded_or_nothing_to_send_settles_it() -> void:
	session = _session()
	await session.start()
	fake.script(HTTPClient.METHOD_POST, NetRunsClient.PATH_LEGACY, 200, {"results": [
			{"board": "journey", "status": "already_uploaded", "run_id": null, "placement": null}]})
	var c := _client(session, {"journey": 5_000})
	await tree.process_frame
	check(c.legacy_done(), "already_uploaded counts as done")
	# A network failure leaves it for the next connection.
	store = NetSessionStore.new()
	queue_store = JsonStore.new()
	fake.requests.clear()
	var s2 := NetSession.new()
	s2.auto_start = false
	s2.configure(fake, store, tuning, time, BASE, 6)
	tree.root.add_child(s2)
	_nodes.append(s2)
	await s2.start()
	fake.offline = true
	var c2 := _client(s2, {"journey": 5_000})
	await tree.process_frame
	check(not c2.legacy_done(), "a network failure retries later")
	var c3_bests := {}
	var s3_store := JsonStore.new()
	queue_store = s3_store
	fake.offline = false
	var c3 := _client(s2, c3_bests)
	await tree.process_frame
	check(c3.legacy_done(), "no local best: nothing to send, done")
	eq(fake.count(NetRunsClient.PATH_LEGACY), tuning.api_max_retries + 1, "only the failed attempt (and its retries) went out")


# ---------------------------------------------------------------- Payload

func test_payload_after_the_queue_round_trip_keeps_integers() -> void:
	var body := NetRunPayload.build(_payload(), NetRunPayload.uuid4(), "2026-09-29", "Falcon GT!", 42)
	eq(body["car"], "falcongt", "car ids are cleaned to a–z 0–9 _ -")
	var back := NetRunPayload.normalize(JSON.parse_string(JSON.stringify(body)) as Dictionary)
	var text := JSON.stringify(back)
	for k in INT_KEYS:
		check(RegEx.create_from_string("\"%s\":-?[0-9]+[,}]" % k).search(text) != null, "%s stays an integer" % k)
	eq(back.keys().size(), CONTRACT_KEYS.size())
	var weird := _payload()
	weird[RunStats.DISTANCE_M] = NAN
	weird[&"future_key"] = 3
	var b2 := NetRunPayload.build(weird, "k-12345678", "2026-09-29", "a", 1)
	eq(float(b2["distance_m"]), 0.0, "a non-finite number goes as 0")
	check(not b2.has("future_key"), "unknown keys never go")
	eq(NetRunPayload.run_date("journey", 1, 1790640000.0), "2026-09-29")
	eq(NetRunPayload.date_start("2026-09-29"), 1790640000)
