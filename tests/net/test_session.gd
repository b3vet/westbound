extends WBTest
## NetSession against the in-memory accounts server: silent device account on first
## launch, resume by refresh, refresh-token reuse falling back to device login, a refused
## secret surfaced (never silently replaced), bans, rename errors, deletion, logout, the
## access-token renewal (proactive and on 401, single flight), and an offline launch that
## neither blocks nor errors. Spec: multiplayer handoff → Accounts and authentication;
## plan MP-D2; docs/SERVER.md → Accounts API. WP N1.2.

const FakeServer := preload("res://tests/net/fake_server.gd")
const BASE := "https://accounts.test/api/v1"
const START_USEC := 5_000_000

var tuning: NetTuning
var fake: NetFakeAccounts
var store: NetSessionStore
var time: NetVirtualTime
var _sessions: Array[NetSession] = []
var events: Array[String] = []


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0


func before_each() -> void:
	fake = NetFakeAccounts.new()
	store = NetSessionStore.new()
	time = NetVirtualTime.new(START_USEC)
	events.clear()


func after_each() -> void:
	for s in _sessions:
		if is_instance_valid(s):
			s.queue_free()
	_sessions.clear()
	await tree.process_frame


## A session on the shared fake server and store ("a launch").
func _launch(auto: bool = false) -> NetSession:
	var s := NetSession.new()
	s.auto_start = auto
	s.configure(fake, store, tuning, time, BASE, 3)
	s.signed_in.connect(func(_p: NetProfile) -> void: events.append("signed_in"))
	s.signed_out.connect(func() -> void: events.append("signed_out"))
	s.banned.connect(func(until: int) -> void: events.append("banned:%d" % until))
	s.profile_changed.connect(func(_p: NetProfile) -> void: events.append("profile"))
	tree.root.add_child(s)
	_sessions.append(s)
	return s


## Ends a launch (the app closes).
func _close(s: NetSession) -> void:
	s.queue_free()
	events.clear()
	fake.requests.clear()


func test_first_launch_creates_and_stores_the_account() -> void:
	var s := _launch()
	await s.start()
	eq(s.status, NetSession.Status.ONLINE)
	var doc := store.load_data()
	check(doc[NetSession.K_ACCOUNT] is String, "account id stored as a String")
	eq(doc[NetSession.K_ACCOUNT], "41")
	eq(String(doc[NetSession.K_SECRET]).length(), NetFakeAccounts.TOKEN_CHARS, "device secret stored")
	check(not String(doc[NetSession.K_REFRESH]).is_empty(), "refresh token stored")
	check(doc[NetSession.K_PROFILE] is Dictionary, "profile cached")
	eq(fake.paths(), PackedStringArray([NetApi.PATH_DEVICE]), "one create, no extra /me")
	if check(s.profile != null):
		eq(s.profile.account_id, "41")
		check(s.profile.full_name.contains("#"), "name#tag")
	check(not s.access_token().is_empty())
	eq(events.count("signed_in"), 1)
	eq(s.account_id(), "41")
	check(s.storage_ok == false, "the memory store is not persistent")


func test_relaunch_resumes_via_refresh() -> void:
	var s := _launch()
	await s.start()
	var rt := String(store.load_data()[NetSession.K_REFRESH])
	_close(s)
	var s2 := _launch()
	await s2.start()
	eq(s2.status, NetSession.Status.ONLINE)
	eq(fake.paths(), PackedStringArray([NetApi.PATH_REFRESH, NetApi.PATH_ME]), "refresh, then the profile")
	eq(fake.count(NetApi.PATH_DEVICE), 0, "no new account")
	var rt2 := String(store.load_data()[NetSession.K_REFRESH])
	ne(rt2, rt, "the rotated refresh token is stored")
	eq(s2.account_id(), "41")
	eq(fake.accounts.size(), 1)


func test_refresh_token_reuse_falls_back_to_device_login() -> void:
	var s := _launch()
	await s.start()
	var rt := String(store.load_data()[NetSession.K_REFRESH])
	_close(s)
	# The last refresh reached the server but its answer was lost: the stored token is used.
	var stolen := await NetApi.new(fake, tuning, BASE).refresh(rt)
	check(stolen.ok)
	fake.requests.clear()
	var s2 := _launch()
	await s2.start()
	eq(s2.status, NetSession.Status.ONLINE, "signed in with the device secret")
	eq(fake.paths(), PackedStringArray([NetApi.PATH_REFRESH, NetApi.PATH_DEVICE_LOGIN]))
	eq(s2.account_id(), "41", "same account")
	eq(fake.accounts.size(), 1, "no orphan account")
	ne(String(store.load_data()[NetSession.K_REFRESH]), rt)


func test_every_rejected_refresh_falls_back_to_device_login() -> void:
	var s := _launch()
	await s.start()
	_close(s)
	for code: String in ["token_reused", "token_revoked", "token_expired", "invalid_token"]:
		fake.script(HTTPClient.METHOD_POST, NetApi.PATH_REFRESH, 401, {"error": code})
		var s2 := _launch()
		await s2.start()
		eq(s2.status, NetSession.Status.ONLINE, code)
		eq(fake.count(NetApi.PATH_DEVICE_LOGIN), 1, "%s: device login" % code)
		_close(s2)


func test_a_refused_secret_is_surfaced_not_replaced() -> void:
	var s := _launch()
	await s.start()
	_close(s)
	var doc := store.load_data()
	doc[NetSession.K_SECRET] = "not-the-secret"
	doc[NetSession.K_REFRESH] = "unknown-token"
	store.save_data(doc)
	var s2 := _launch()
	await s2.start()
	eq(s2.status, NetSession.Status.FAILED)
	eq(s2.last_error.error, NetApiResult.INVALID_CREDENTIALS)
	eq(fake.count(NetApi.PATH_DEVICE), 0, "no silent new account")
	eq(store.load_data()[NetSession.K_ACCOUNT], "41", "the stored account is kept")
	eq(s2.access_token(), "")
	ne(NetSession.error_text(s2.last_error, 0.0), NetSession.TEXT_FALLBACK)
	# The player chooses to start over.
	await s2.create_new_account()
	eq(s2.status, NetSession.Status.ONLINE)
	ne(s2.account_id(), "41")
	eq(fake.count(NetApi.PATH_DEVICE), 1)


func test_ban_surfaces_on_launch_and_mid_session() -> void:
	var s := _launch()
	await s.start()
	var until := int(fake.now_s) + 7 * 86400
	fake.ban("41", until)
	var r := await s.rename("Road Runner")
	eq(r.error, NetApiResult.BANNED)
	eq(s.status, NetSession.Status.BANNED, "a 403 banned mid-session")
	check(events.has("banned:%d" % until))
	eq(s.banned_until, until)
	check(NetSession.error_text(r, 0.0).contains("suspended until"), NetSession.error_text(r, 0.0))
	_close(s)
	var s2 := _launch()
	await s2.start()
	eq(s2.status, NetSession.Status.BANNED, "refresh answers banned")
	check(events.has("banned:%d" % until))
	eq(fake.count(NetApi.PATH_DEVICE_LOGIN), 0, "a ban is not a rejected token")
	eq(s2.access_token(), "")
	eq(NetSession.banned_text(NetApiResult.BANNED_FOREVER), NetSession.TEXT_BANNED_FOREVER)
	# The ban ends: RETRY signs in with the same (unconsumed) refresh token.
	fake.ban("41", 0)
	await s2.retry()
	eq(s2.status, NetSession.Status.ONLINE)
	eq(s2.account_id(), "41")


func test_rename_success_updates_profile() -> void:
	var s := _launch()
	await s.start()
	events.clear()
	var r := await s.rename("  Road Runner ")
	check(r.ok, r.error)
	eq(s.profile.display_name, "Road Runner")
	check(s.profile.full_name.begins_with("Road Runner#"))
	check(events.has("profile"))
	var cached := store.load_data()[NetSession.K_PROFILE] as Dictionary
	eq(cached["display_name"], "Road Runner", "cached for offline")
	gt(float(s.profile.next_rename_at), fake.now_s, "cooldown known")


func test_rename_errors_are_mapped() -> void:
	var s := _launch()
	await s.start()
	fake.full_names.append("taken name")
	var cases := {
		"ab": NetSession.ERR_INVALID_NAME,                 # too short: never sent
		"a__b": "invalid_name",                            # the server's rules
		"Rude Rider": "name_not_allowed",
		"Taken Name": "name_unavailable",
		s.profile.display_name: "name_unchanged",
	}
	var texts := {}
	for n: String in cases:
		var before := fake.requests.size()
		var r := await s.rename(n)
		eq(r.error, cases[n], n)
		var t := NetSession.error_text(r, fake.now_s)
		ne(t, NetSession.TEXT_FALLBACK, "%s has its own text" % n)
		texts[r.error] = t
		if n == "ab":
			eq(fake.requests.size(), before, "short names are not sent")
	eq(texts.size(), 4, "four codes (a short name is the client-side invalid_name)")
	var ok := await s.rename("Road Runner")
	check(ok.ok)
	var r2 := await s.rename("Other Name")
	eq(r2.error, "rename_cooldown")
	gt(float(r2.next_rename_at), fake.now_s)
	eq(NetSession.error_text(r2, fake.now_s), NetSession.TEXT_COOLDOWN % 30)
	eq(NetSession.cooldown_text(int(fake.now_s) + 3600, fake.now_s), NetSession.TEXT_COOLDOWN_SOON)
	eq(NetSession.cooldown_text(int(fake.now_s) + 86000, fake.now_s), NetSession.TEXT_COOLDOWN_ONE)
	fake.script(HTTPClient.METHOD_PATCH, NetApi.PATH_ME, 429, {"error": "rate_limited", "retry_after_secs": 900})
	var r3 := await s.rename("Third Name")
	eq(r3.error, NetApiResult.RATE_LIMITED)
	eq(s.status, NetSession.Status.ONLINE, "a rename error does not sign out")


func test_delete_clears_storage() -> void:
	var s := _launch()
	await s.start()
	events.clear()
	var r := await s.delete_account()
	check(r.ok, r.error)
	eq(store.load_data(), {}, "nothing left on the device")
	eq(s.status, NetSession.Status.SIGNED_OUT)
	eq(events, ["signed_out"])
	check(not fake.accounts.has("41"), "gone on the server")
	check(s.profile == null)
	eq(s.access_token(), "")
	_close(s)
	# The next launch is a first launch.
	var s2 := _launch()
	await s2.start()
	eq(fake.paths(), PackedStringArray([NetApi.PATH_DEVICE]))
	eq(s2.status, NetSession.Status.ONLINE)


func test_delete_failure_keeps_everything() -> void:
	var s := _launch()
	await s.start()
	fake.offline = true
	var r := await s.delete_account()
	eq(r.error, NetApiResult.NETWORK)
	eq(store.load_data()[NetSession.K_ACCOUNT], "41")
	check(fake.accounts.has("41"))
	eq(s.status, NetSession.Status.ONLINE)


func test_logout_then_sign_in() -> void:
	var s := _launch()
	await s.start()
	events.clear()
	var r := await s.logout()
	check(r.ok)
	eq(s.status, NetSession.Status.SIGNED_OUT)
	eq(events, ["signed_out"])
	var doc := store.load_data()
	check(not doc.has(NetSession.K_REFRESH), "refresh token dropped")
	eq(doc[NetSession.K_SECRET], fake.accounts["41"]["secret"], "the secret stays")
	_close(s)
	var s2 := _launch()
	await s2.start()
	eq(s2.status, NetSession.Status.SIGNED_OUT, "stays signed out")
	eq(fake.requests.size(), 0)
	await s2.retry()
	eq(s2.status, NetSession.Status.ONLINE)
	eq(fake.paths(), PackedStringArray([NetApi.PATH_DEVICE_LOGIN]))
	check(not store.load_data().has(NetSession.K_SIGNED_OUT))


func test_expired_access_token_is_renewed_and_the_call_repeated() -> void:
	var s := _launch()
	await s.start()
	fake.expire_access_tokens()
	fake.requests.clear()
	var r := await s.rename("Road Runner")
	check(r.ok, r.error)
	eq(fake.paths(), PackedStringArray([NetApi.PATH_ME, NetApi.PATH_REFRESH, NetApi.PATH_ME]))


func test_proactive_refresh_before_expiry() -> void:
	var s := _launch()
	await s.start()
	fake.requests.clear()
	s.poll()
	eq(fake.requests.size(), 0, "fresh token: nothing to do")
	time.advance_s(float(NetFakeAccounts.ACCESS_TTL_S) - tuning.session_refresh_margin_s + 1.0)
	var old := s.access_token()
	s.poll()
	eq(fake.paths(), PackedStringArray([NetApi.PATH_REFRESH]))
	ne(s.access_token(), old)
	eq(s.status, NetSession.Status.ONLINE)
	# A failed proactive refresh keeps the session online and waits before the next try.
	time.advance_s(float(NetFakeAccounts.ACCESS_TTL_S) - tuning.session_refresh_margin_s + 1.0)
	fake.offline = true
	fake.requests.clear()
	s.poll()
	eq(s.status, NetSession.Status.ONLINE, "the token still works")
	var n := fake.requests.size()
	s.poll()
	eq(fake.requests.size(), n, "no retry storm")


func test_concurrent_renewals_share_one_refresh() -> void:
	var s := _launch()
	await s.start()
	fake.expire_access_tokens()
	fake.requests.clear()
	fake.hold = true
	var done := {"a": false, "b": false}
	var call_a := func() -> void:
		var r: NetApiResult = await s.api.get_me()
		done["a"] = r.ok
	var call_b := func() -> void:
		var r: NetApiResult = await s.rename("Road Runner")
		done["b"] = r.ok
	call_a.call()
	call_b.call()
	eq(fake.requests.size(), 2, "both calls in flight")
	fake.released.emit()     # both get 401; one refresh starts and waits (still holding)
	eq(fake.count(NetApi.PATH_REFRESH), 1)
	fake.release()           # the refresh answers; both calls repeat
	for i in 3:
		await tree.process_frame
	eq(fake.count(NetApi.PATH_REFRESH), 1, "one refresh for two callers")
	check(bool(done["a"]) and bool(done["b"]), "both calls succeeded: %s" % done)


func test_offline_launch_neither_blocks_nor_errors() -> void:
	fake.hold = true
	var s := _launch()
	var returned := false
	s.start()
	returned = true
	check(returned, "start() returned while the network hangs")
	eq(s.status, NetSession.Status.CONNECTING)
	eq(s.access_token(), "")
	fake.offline = true
	fake.release()
	await tree.process_frame
	eq(s.status, NetSession.Status.OFFLINE)
	eq(fake.count(NetApi.PATH_DEVICE), tuning.api_max_retries + 1, "retried with backoff")
	near(s.retry_in_s(), tuning.session_retry_s, 1e-6)
	check(s.profile == null)
	# The network comes back: the scheduled retry signs in.
	fake.offline = false
	s.poll()
	eq(s.status, NetSession.Status.OFFLINE, "not before the retry time")
	time.advance_s(tuning.session_retry_s)
	s.poll()
	eq(s.status, NetSession.Status.ONLINE)
	eq(fake.accounts.size(), 1)


func test_offline_relaunch_keeps_the_cached_profile_and_backs_off() -> void:
	var s := _launch()
	await s.start()
	var name_before := s.profile.full_name
	_close(s)
	fake.offline = true
	var s2 := _launch()
	await s2.start()
	eq(s2.status, NetSession.Status.OFFLINE)
	if check(s2.profile != null, "cached profile"):
		eq(s2.profile.full_name, name_before)
	eq(store.load_data()[NetSession.K_ACCOUNT], "41", "nothing forgotten")
	var first := s2.retry_in_s()
	time.advance_s(first)
	s2.poll()
	near(s2.retry_in_s(), minf(first * 2.0, tuning.session_retry_max_s), 1e-6, "doubling")
	for i in 12:
		time.advance_s(s2.retry_in_s())
		s2.poll()
	near(s2.retry_in_s(), tuning.session_retry_max_s, 1e-6, "capped")


func test_long_rate_limit_is_offline_with_its_retry_after() -> void:
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, 429,
			{"error": "rate_limited", "retry_after_secs": 1800}, PackedStringArray(["Retry-After: 1800"]))
	var s := _launch()
	await s.start()
	eq(s.status, NetSession.Status.OFFLINE)
	near(s.retry_in_s(), 1800.0, 1e-6)


func test_auto_start_in_the_tree_does_not_block() -> void:
	fake.hold = true
	var s := _launch(true)
	eq(s.status, NetSession.Status.CONNECTING, "started on entering the tree")
	check(NetSession.current == s)
	fake.release()
	await tree.process_frame
	eq(s.status, NetSession.Status.ONLINE)


func test_disabled_without_a_server() -> void:
	var s := NetSession.new()
	s.auto_start = false
	s.configure_disabled(tuning)
	tree.root.add_child(s)
	_sessions.append(s)
	await s.start()
	eq(s.status, NetSession.Status.DISABLED)
	eq(s.access_token(), "")
	eq(s.ws_url(), "")
	var r := await s.rename("Road Runner")
	eq(r.error, NetSession.ERR_NOT_SIGNED_IN)


func test_server_resolution() -> void:
	var none := PackedStringArray()
	eq(NetSession.resolve_base_url(tuning, null, none), tuning.api_base_url)
	eq(NetSession.resolve_base_url(tuning, null, PackedStringArray(["--server=http://127.0.0.1:8080"])),
			"http://127.0.0.1:8080/api/v1")
	eq(NetSession.resolve_base_url(tuning, null, PackedStringArray(["--server=https://x.test/api/v1/"])),
			"https://x.test/api/v1")
	eq(NetSession.resolve_base_url(tuning, null, PackedStringArray(["--server=off"])), "")
	eq(NetSession.normalize_server("ftp://x", tuning.api_base_url), tuning.api_base_url, "bad scheme ignored")
	var js := QueryBridge.new()
	js.params["server"] = "http://localhost:8080"
	eq(NetSession.resolve_base_url(tuning, js, none), "http://localhost:8080/api/v1", "?server= on the web")
	# Credentials never cross servers.
	eq(NetSession.store_name(tuning.api_base_url, tuning), NetSession.STORE_DEFAULT)
	ne(NetSession.store_name("http://127.0.0.1:8080/api/v1", tuning), NetSession.STORE_DEFAULT)
	ne(NetSession.store_name("http://127.0.0.1:8080/api/v1", tuning),
			NetSession.store_name("http://127.0.0.1:9090/api/v1", tuning))


func test_ws_url_follows_the_server() -> void:
	var s := _launch()
	eq(s.ws_url(), "wss://accounts.test/ws")
	var d := NetSession.new()
	d.configure(fake, store, tuning, time)
	eq(d.ws_url(), tuning.server_url, "the default server's WebSocket")
	d.base_url = "http://127.0.0.1:8080/api/v1"
	eq(d.ws_url(), "ws://127.0.0.1:8080/ws")
	d.free()


func test_secrets_never_printed_in_errors_or_texts() -> void:
	var s := _launch()
	await s.start()
	var secret := String(store.load_data()[NetSession.K_SECRET])
	for code: String in NetSession.TEXT:
		check(not String(NetSession.TEXT[code]).contains(secret))
	check(not s.to_string().contains(secret))


## The session's token is what NetClient's Hello carries; a newer login elsewhere kicks
## this one with a fatal `not_allowed`, which has its own player text.
func test_access_token_plugs_into_net_client() -> void:
	var s := _launch()
	await s.start()
	var token := await s.fresh_access_token()
	check(not token.is_empty())
	var link := NetLoopbackLink.new(time, Rng.new(9))
	link.latency_s = 0.02
	var server := FakeServer.new(link)
	server.set("account_id", s.account_id())
	var client := NetClient.new(link.client, tuning, time)
	var failed: Array[String] = []
	client.failed.connect(func(reason: String, _m: String) -> void: failed.append(reason))
	eq(client.start(s.ws_url(), 1, NetCodec.hex_to_bytes(String(server.get("map_hash_hex"))),
			s.access_token()), OK)
	for i in 100:
		time.advance_s(0.01)
		server.call("poll")
		client.poll()
	if not eq(client.get_state(), NetClient.State.READY, "Welcome"):
		return
	var hellos: Array[Dictionary] = server.get("hellos")
	eq(hellos[0]["access_token"], token, "Hello carries the session's access token")
	eq(client.account_id, s.account_id())
	server.call("send", [{"type": "error", "code": "not_allowed", "fatal": true,
			"detail": "This account signed in on another device."}])
	for i in 20:
		time.advance_s(0.01)
		server.call("poll")
		client.poll()
	eq(failed, ["not_allowed"] as Array[String])
	eq(client.failure_message, "This account signed in on another device.")
	eq(NetClient.user_message("not_allowed"), "This account signed in on another device.")


## A web bridge answering only URL parameters.
class QueryBridge:
	extends NetJsBridge
	var params := {}

	func available() -> bool:
		return true

	func query_param(param_name: String) -> String:
		return String(params.get(param_name, ""))
