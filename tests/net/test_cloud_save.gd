extends WBTest
## Cloud save sync (NetCloudSave, WP N11; docs/SAVE.md → Cloud sync) against the fake
## server with in-memory saves: off without a provider, the first upload, a second device
## merging the cloud in (and adding its own progress), the conflict chooser's two modes, a
## 409 from another device merged and retried, offline retries with backoff, never mid-run
## (a download waits for the run's end), a newer build's cloud copy and an oversized save
## refused, and the triggers (a run's end, coming back to the app).

const BASE := "https://cloud.test/api/v1"

var tuning: NetTuning
var fake: NetFakeAccounts
var _nodes: Array[Node] = []


class MemTarget:
	extends NetCloudSaveTarget
	var doc: Dictionary = SaveMigrations.fresh()
	var running: bool = false
	var ro: bool = false
	var applied: int = 0

	func snapshot() -> Dictionary:
		return doc.duplicate(true)

	func can_apply() -> bool:
		return not running and not ro

	func apply(d: Dictionary) -> bool:
		if not can_apply():
			return false
		doc = d.duplicate(true)
		applied += 1
		return true

	func read_only() -> bool:
		return ro

	func idle() -> bool:
		return not running


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0
	tuning.api_max_retries = 0


func before_each() -> void:
	fake = NetFakeAccounts.new()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


static func _local(xp: int, extra: Dictionary = {}) -> Dictionary:
	var d := SaveMigrations.fresh()
	d["settings"] = {"units": "kmh", "quality_tier": "high", "throttle_mode": "manual"}
	d["stats"] = {"xp": xp, "runs": 2}
	d["bests"] = {"journey": xp * 2}
	d["unlocks"] = {"car/falcon_gt": 0}
	d["garage"] = {"car": "falcon_gt"}
	d["sync"] = {"garage_at": 10, "settings_at": 10}
	d.merge(extra, true)
	return d


func _device(target: MemTarget, store: NetSessionStore = null) -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, store if store != null else NetSessionStore.new(), tuning, NetVirtualTime.new(1), BASE, 3)
	s.unix_clock = func() -> float: return fake.now_s
	for p: String in NetIdentityProvider.ALL:
		var f := NetFakeIdentity.new(p)
		f.wait = func(_sec: float) -> void: await tree.process_frame
		s.identity[p] = f
	tree.root.add_child(s)
	_nodes.append(s)
	s.cloud.setup(s, target)
	s.cloud.set_process(false)   # the tests drive poll() and sync()
	return s


## A device signed in with Google `sub`.
func _linked(target: MemTarget, sub: String) -> NetSession:
	var s := _device(target)
	await s.start()
	(s.identity["google"] as NetFakeIdentity).sub = sub
	var r: NetApiResult = await s.sign_in_with("google")
	check(r.ok, "link: %s" % r.error)
	return s


func _vt(s: NetSession) -> NetVirtualTime:
	return s.time as NetVirtualTime


func test_off_without_a_provider() -> void:
	var t := MemTarget.new()
	var s := _device(t)
	await s.start()
	check(not s.cloud.enabled())
	eq(s.cloud.status, NetCloudSave.Status.OFF)
	s.cloud.request_sync()
	eq(s.cloud.due_in_s(), -1.0)
	check(not await s.cloud.sync())
	eq(fake.count(NetApi.PATH_SAVE), 0, "a device account has nothing to sync with")


func test_first_sync_uploads_then_stays_quiet() -> void:
	var t := MemTarget.new()
	t.doc = _local(5000)
	var s := await _linked(t, "g-1")
	ge(s.cloud.due_in_s(), 0.0, "linking asks for a sync")
	check(await s.cloud.sync())
	eq(s.cloud.status, NetCloudSave.Status.SYNCED)
	eq(s.cloud.revision, 1)
	eq(s.cloud.uploads, 1)
	var up: Dictionary = (fake.saves[s.account_id()] as Dictionary)["data"]
	eq(int(up["stats"]["xp"]), 5000)
	check(not (up["settings"] as Dictionary).has("quality_tier"), "device settings stay home")
	check(not up.has("daily"))
	var put: Dictionary = fake.requests.filter(func(q: Dictionary) -> bool: return q["method"] == HTTPClient.METHOD_PUT)[0]
	eq(put["if_match"], "\"0\"", "the first write names revision 0")
	check(await s.cloud.sync())
	eq(s.cloud.uploads, 1, "nothing changed: no upload")
	eq(t.applied, 0, "nothing to apply")


func test_second_device_merges_both_ways() -> void:
	var ta := MemTarget.new()
	ta.doc = _local(5000, {"unlocks": {"car/falcon_gt": 0, "paint/teal": 5}})
	(ta.doc["settings"] as Dictionary)["units"] = "mph"
	var a := await _linked(ta, "g-2")
	check(await a.cloud.sync())
	# Device B: a fresh install (settings never changed) with a little progress of its own.
	var tb := MemTarget.new()
	tb.doc = _local(100, {"unlocks": {"rim/mesh": 1}, "sync": {}})
	var b := _device(tb)
	await b.start()
	await b.logout()
	(b.identity["google"] as NetFakeIdentity).sub = "g-2"
	var r: NetApiResult = await b.sign_in_with("google")
	check(r.ok, r.error)
	eq(b.account_id(), a.account_id())
	check(await b.cloud.sync())
	eq(int(tb.doc["stats"]["xp"]), 5000, "the cloud's progress came down")
	check((tb.doc["unlocks"] as Dictionary).has("paint/teal") and (tb.doc["unlocks"] as Dictionary).has("rim/mesh"))
	eq(tb.doc["settings"]["units"], "mph", "a fresh device takes the synced settings")
	eq(tb.doc["settings"]["quality_tier"], "high", "never the device ones")
	var cloud: Dictionary = (fake.saves[a.account_id()] as Dictionary)["data"]
	check((cloud["unlocks"] as Dictionary).has("rim/mesh"), "B's own progress went up")
	eq(b.cloud.revision, 2)
	# A picks it up on its next sync.
	check(await a.cloud.sync())
	check((ta.doc["unlocks"] as Dictionary).has("rim/mesh"))


func test_conflict_modes() -> void:
	var ta := MemTarget.new()
	ta.doc = _local(9000, {"garage": {"car": "night_viper"}, "sync": {"garage_at": 50, "settings_at": 50}})
	var a := await _linked(ta, "g-3")
	check(await a.cloud.sync())
	# B keeps its own progress: merged, its car wins.
	var tb := MemTarget.new()
	tb.doc = _local(300, {"bests": {"journey": 99999}, "garage": {"car": "brute_v8"}, "sync": {"garage_at": 1}})
	var b := _device(tb)
	await b.start()
	(b.identity["google"] as NetFakeIdentity).sub = "g-3"
	eq((await b.sign_in_with("google")).error, NetSession.ERR_IDENTITY_IN_USE)
	check((await b.resolve_conflict(true)).ok)
	check(await b.cloud.sync())
	eq(int(tb.doc["stats"]["xp"]), 9000)
	eq(int(tb.doc["bests"]["journey"]), 99999)
	eq(tb.doc["garage"]["car"], "brute_v8", "keep: this device's car")
	var cloud: Dictionary = (fake.saves[a.account_id()] as Dictionary)["data"]
	eq(cloud["garage"]["car"], "brute_v8")
	eq(int(cloud["bests"]["journey"]), 99999)
	eq(b.cloud.next_mode, SaveMerge.Mode.MERGE, "the mode is used once")
	# C uses the cloud's progress: its own best is replaced.
	var tc := MemTarget.new()
	tc.doc = _local(50, {"bests": {"journey": 123456}})
	var c := _device(tc)
	await c.start()
	(c.identity["google"] as NetFakeIdentity).sub = "g-3"
	eq((await c.sign_in_with("google")).error, NetSession.ERR_IDENTITY_IN_USE)
	check((await c.resolve_conflict(false)).ok)
	check(await c.cloud.sync())
	eq(int(tc.doc["bests"]["journey"]), 99999, "the cloud's best")
	eq(int(tc.doc["stats"]["xp"]), 9000)
	eq(tc.doc["settings"]["quality_tier"], "high", "device settings stay")
	eq(int(((fake.saves[a.account_id()] as Dictionary)["data"] as Dictionary)["bests"]["journey"]), 99999,
			"the cloud did not take the replaced best")


func test_another_device_wrote_first() -> void:
	var t := MemTarget.new()
	t.doc = _local(1000)
	var s := await _linked(t, "g-4")
	check(await s.cloud.sync())
	var stale := {"revision": 1, "updated_at": 1, "bytes": 10,
		"data": (fake.saves[s.account_id()] as Dictionary)["data"]}
	fake.put_save_direct(s.account_id(), _local(7000, {"unlocks": {"car/night_viper": 3}}))
	(t.doc["stats"] as Dictionary)["runs"] = 9
	fake.script(HTTPClient.METHOD_GET, NetApi.PATH_SAVE, 200, stale)
	check(await s.cloud.sync())
	eq(s.cloud.revision, 3, "merged with the 409's copy and written on revision 2")
	var cloud: Dictionary = (fake.saves[s.account_id()] as Dictionary)["data"]
	eq(int(cloud["stats"]["xp"]), 7000)
	eq(int(cloud["stats"]["runs"]), 9)
	check((t.doc["unlocks"] as Dictionary).has("car/night_viper"))
	var matches: Array = fake.requests.filter(func(q: Dictionary) -> bool: return q["method"] == HTTPClient.METHOD_PUT)
	eq(matches[-2]["if_match"], "\"1\"")
	eq(matches[-1]["if_match"], "\"2\"")


func test_offline_retries_with_backoff() -> void:
	var t := MemTarget.new()
	t.doc = _local(10)
	var s := await _linked(t, "g-5")
	fake.offline = true
	check(not await s.cloud.sync())
	eq(s.cloud.status, NetCloudSave.Status.OFFLINE)
	near(s.cloud.due_in_s(), tuning.cloud_retry_s, 0.01)
	_vt(s).advance_s(tuning.cloud_retry_s)
	s.cloud.poll()
	await tree.process_frame
	near(s.cloud.due_in_s(), tuning.cloud_retry_s * 2.0, 0.01, "doubles")
	fake.offline = false
	_vt(s).advance_s(tuning.cloud_retry_s * 2.0)
	s.cloud.poll()
	for i in 10:
		await tree.process_frame
	eq(s.cloud.status, NetCloudSave.Status.SYNCED)
	eq(s.cloud.last_error, "")


func test_never_mid_run() -> void:
	var ta := MemTarget.new()
	ta.doc = _local(8000)
	var a := await _linked(ta, "g-6")
	check(await a.cloud.sync())
	var tb := MemTarget.new()
	tb.doc = _local(10)
	var b := _device(tb)
	await b.start()
	await b.logout()
	(b.identity["google"] as NetFakeIdentity).sub = "g-6"
	tb.running = true
	check((await b.sign_in_with("google")).ok)
	var before := fake.count(NetApi.PATH_SAVE)
	b.cloud.poll()
	await tree.process_frame
	eq(fake.count(NetApi.PATH_SAVE), before, "a due sync waits for the run")
	ge(b.cloud.due_in_s(), 0.0)
	# A sync started anyway (or one that was running when the run began) never applies.
	check(await b.cloud.sync())
	eq(b.cloud.status, NetCloudSave.Status.WAITING)
	eq(int(tb.doc["stats"]["xp"]), 10, "not applied mid-run")
	tb.running = false
	b.cloud.poll()
	eq(int(tb.doc["stats"]["xp"]), 8000, "applied when the run is over")


func test_newer_cloud_and_oversized_saves_are_refused() -> void:
	var t := MemTarget.new()
	t.doc = _local(10)
	var s := await _linked(t, "g-7")
	fake.put_save_direct(s.account_id(), {"version": SaveMigrations.VERSION + 1, "stats": {"xp": 99}})
	check(not await s.cloud.sync())
	eq(s.cloud.status, NetCloudSave.Status.ERROR)
	eq(s.cloud.last_error, NetCloudSave.ERR_NEWER)
	eq(int(t.doc["stats"]["xp"]), 10, "untouched")
	eq(fake.count(NetApi.PATH_SAVE, HTTPClient.METHOD_PUT), 0, "never overwritten")
	var t2 := MemTarget.new()
	t2.doc = _local(10, {"unlocks": {"blob": "x".repeat(400)}})
	fake.save_max_bytes = 256
	var s2 := await _linked(t2, "g-8")
	await s2.load_providers(true)
	check(not await s2.cloud.sync())
	eq(s2.cloud.last_error, NetCloudSave.ERR_TOO_LARGE)
	eq(NetSession.error_text(NetApiResult.failure(0, s2.cloud.last_error), 0.0), NetSession.TEXT["save_too_large"])


func test_triggers() -> void:
	var t := MemTarget.new()
	t.doc = _local(10)
	var s := await _linked(t, "g-9")
	check(await s.cloud.sync())
	eq(s.cloud.due_in_s(), -1.0)
	Events.run_over.emit({})
	near(s.cloud.due_in_s(), tuning.cloud_after_run_delay_s, 0.01, "a run's end syncs a little later")
	_vt(s).advance_s(5.0)
	Events.run_over.emit({})
	near(s.cloud.due_in_s(), tuning.cloud_after_run_delay_s - 5.0, 0.01, "debounced: the earliest stays")
	_vt(s).advance_s(tuning.cloud_after_run_delay_s)
	s.cloud.poll()
	for i in 5:
		await tree.process_frame
	eq(s.cloud.due_in_s(), -1.0)
	s.cloud.on_resume()
	eq(s.cloud.due_in_s(), -1.0, "a recent sync: resume does nothing")
	_vt(s).advance_s(tuning.cloud_resume_min_s)
	s.cloud.on_resume()
	near(s.cloud.due_in_s(), 0.0, 0.01, "an old one: sync now")
