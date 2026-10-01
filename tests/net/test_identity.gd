extends WBTest
## Sign in with Apple / Google on the client (WP N11; docs/NET_CLIENT.md → Sign in with
## Apple / Google) against the fake accounts server: the providers config, link keeping the
## device account, cancel / unavailable / not set up, the identity_in_use conflict and both
## choices (switching account, its own device secret, the old session logged out), a
## sign-in with no account here, unlink, renewals with the provider's device secret; the web
## shell bridge (configure only when enabled, begin / poll / timeout) and the native stub.

const BASE := "https://identity.test/api/v1"

var tuning: NetTuning
var fake: NetFakeAccounts
var _nodes: Array[Node] = []


class MemTarget:
	extends NetCloudSaveTarget
	var doc: Dictionary = SaveMigrations.fresh()

	func snapshot() -> Dictionary:
		return doc.duplicate(true)

	func can_apply() -> bool:
		return true

	func apply(d: Dictionary) -> bool:
		doc = d.duplicate(true)
		return true

	func read_only() -> bool:
		return false

	func idle() -> bool:
		return true


## A scripted page: `window.wbIdentity` answering configure / begin / poll / cancel.
class PageBridge:
	extends NetJsBridge
	var has_shell: bool = true
	var calls: PackedStringArray = PackedStringArray()
	var result: String = ""
	var polls: int = 0
	var answer_after: int = 1

	func available() -> bool:
		return true

	func eval(code: String) -> Variant:
		calls.append(code)
		if code.begins_with("!!(window.wbIdentity)"):
			return has_shell
		if code.begins_with("window.wbIdentity.configure"):
			return true
		if code.begins_with("window.wbIdentity.begin"):
			return true
		if code.begins_with("window.wbIdentity.poll"):
			polls += 1
			return result if polls >= answer_after else ""
		return null


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0


func before_each() -> void:
	fake = NetFakeAccounts.new()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


## A device: a session with fake provider sheets and an in-memory save.
func _device(store: NetSessionStore = null) -> NetSession:
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
	s.cloud.setup(s, MemTarget.new())
	return s


func _fake_id(s: NetSession, p: String) -> NetFakeIdentity:
	return s.identity[p] as NetFakeIdentity


func test_providers_config_configures_the_sheets() -> void:
	var s := _device()
	await s.start()
	await s.load_providers()
	check(s.provider_enabled("google") and s.provider_enabled("apple"))
	check(s.cloud_save_on())
	eq(s.cloud_save_max_bytes(), 65536)
	eq(_fake_id(s, "google").config.get("client_id"), "fake.apps.googleusercontent.com")
	eq(_fake_id(s, "apple").config.get("redirect_uri"), "https://fake.test/")
	var n := fake.count(NetApi.PATH_PROVIDERS)
	await s.load_providers()
	eq(fake.count(NetApi.PATH_PROVIDERS), n, "cached")
	await s.load_providers(true)
	eq(fake.count(NetApi.PATH_PROVIDERS), n + 1)


func test_link_keeps_the_device_account() -> void:
	var s := _device()
	await s.start()
	var id := s.account_id()
	_fake_id(s, "google").sub = "g-1"
	var r := await s.sign_in_with("google")
	check(r.ok, r.error)
	eq(s.account_id(), id, "same account: progress kept")
	check(s.profile.linked_google and s.profile.has_provider())
	eq(s.profile.email_hint("google"), "p***@gmail.com")
	eq(fake.subs.get("google:g-1"), id)
	var nonce := _fake_id(s, "google").nonces[0]
	check(fake.nonces.has(nonce), "the sheet got the server's nonce")
	var link_req: Dictionary = fake.requests.filter(func(q: Dictionary) -> bool: return q["path"] == NetApi.PATH_LINK + "google")[0]
	var body: Dictionary = JSON.parse_string(link_req["body"])
	eq(body["nonce"], nonce)
	check(not body.has("authorization_code"), "Google sends no code")
	# Apple with a code.
	_fake_id(s, "apple").sub = "a-1"
	_fake_id(s, "apple").code = "code-xyz"
	r = await s.sign_in_with("apple")
	check(r.ok, r.error)
	var apple_req: Dictionary = fake.requests.filter(func(q: Dictionary) -> bool: return q["path"] == NetApi.PATH_LINK + "apple")[0]
	eq((JSON.parse_string(apple_req["body"]) as Dictionary)["authorization_code"], "code-xyz")
	check(s.profile.private_email("apple"))


func test_cancel_unavailable_and_not_set_up() -> void:
	var s := _device()
	await s.start()
	_fake_id(s, "google").outcome = NetIdentityResult.CANCELLED
	var r := await s.sign_in_with("google")
	eq(r.error, NetIdentityResult.CANCELLED)
	eq(fake.count(NetApi.PATH_LINK + "google"), 0)
	_fake_id(s, "google").outcome = ""
	_fake_id(s, "google").is_available = false
	r = await s.sign_in_with("google")
	eq(r.error, NetIdentityResult.UNAVAILABLE)
	eq(NetSession.error_text(r, 0.0), NetSession.TEXT["provider_unavailable_here"])
	fake.providers_enabled["apple"] = false
	await s.load_providers(true)
	r = await s.sign_in_with("apple")
	eq(r.error, NetSession.ERR_PROVIDER_OFF)
	check(not s.identity_busy())


func test_bad_tokens_are_reported() -> void:
	var s := _device()
	await s.start()
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_LINK + "google", 401,
			{"error": "invalid_id_token", "message": "no"})
	var r := await s.sign_in_with("google")
	eq(r.error, "invalid_id_token")
	eq(s.status, NetSession.Status.ONLINE, "a refused token does not sign the device out")
	eq(fake.count(NetApi.PATH_REFRESH), 0, "not a bearer failure: no renewal")


func test_conflict_then_switch_keeping_the_device_progress() -> void:
	# Device A: account X with Google.
	var a := _device()
	await a.start()
	var x := a.account_id()
	_fake_id(a, "google").sub = "g-shared"
	check((await a.sign_in_with("google")).ok)
	fake.put_save_direct(x, {"version": 2, "stats": {"xp": 60629, "runs": 12}})
	# Device B: its own device account Y, then the same Google account.
	var b_store := NetSessionStore.new()
	var b := _device(b_store)
	await b.start()
	var y := b.account_id()
	var y_refresh := b._refresh_token()
	_fake_id(b, "google").sub = "g-shared"
	var r := await b.sign_in_with("google")
	eq(r.error, NetSession.ERR_IDENTITY_IN_USE)
	eq(b.account_id(), y, "nothing switched yet")
	var c := b.pending_conflict
	eq(c["provider"], "google")
	eq(c["current"]["account_id"], y)
	eq(c["other"]["account_id"], x)
	eq(int(c["other"]["cloud_save"]["xp"]), 60629)
	# KEEP THIS DEVICE'S PROGRESS.
	var switched: Array[String] = []
	b.account_switched.connect(func(prev: String) -> void: switched.append(prev))
	r = await b.resolve_conflict(true)
	check(r.ok, r.error)
	eq(b.account_id(), x, "switched to the identity's account")
	eq(switched, [y] as Array[String])
	check(b.pending_conflict.is_empty())
	eq(b.cloud.next_mode, SaveMerge.Mode.KEEP_LOCAL, "the next sync keeps this device's choices")
	check(b.profile.linked_google)
	# Its own device secret, stored: a renewal without the refresh token works.
	var doc := b_store.load_data()
	eq(doc[NetSession.K_ACCOUNT], x)
	check(((fake.accounts[x] as Dictionary)["secrets"] as Array).has(doc[NetSession.K_SECRET]))
	eq((fake.refresh_tokens[y_refresh] as Dictionary)["revoked"], true, "the old device session is logged out")
	doc.erase(NetSession.K_REFRESH)
	b_store.save_data(doc)
	var b2 := _device(b_store)
	await b2.start()
	eq(b2.status, NetSession.Status.ONLINE)
	eq(b2.account_id(), x)
	check(fake.count(NetApi.PATH_DEVICE_LOGIN) >= 1, "renewed with the provider's device secret")


func test_conflict_use_cloud_and_cancel() -> void:
	var a := _device()
	await a.start()
	_fake_id(a, "apple").sub = "a-shared"
	check((await a.sign_in_with("apple")).ok)
	var b := _device()
	await b.start()
	var y := b.account_id()
	_fake_id(b, "apple").sub = "a-shared"
	eq((await b.sign_in_with("apple")).error, NetSession.ERR_IDENTITY_IN_USE)
	b.cancel_conflict()
	eq(b.account_id(), y)
	eq((await b.resolve_conflict(false)).error, NetSession.ERR_NO_CONFLICT)
	eq((await b.sign_in_with("apple")).error, NetSession.ERR_IDENTITY_IN_USE)
	var r := await b.resolve_conflict(false)
	check(r.ok, r.error)
	eq(b.account_id(), a.account_id())
	eq(b.cloud.next_mode, SaveMerge.Mode.USE_CLOUD)


func test_sign_in_without_an_account_here() -> void:
	var s := _device()
	await s.start()
	await s.logout()
	eq(s.status, NetSession.Status.SIGNED_OUT)
	_fake_id(s, "google").sub = "g-new"
	var r := await s.sign_in_with("google")
	check(r.ok, r.error)
	eq(s.status, NetSession.Status.ONLINE)
	check(bool(r.data.get("created", false)), "a new account for a new identity")
	check(s.profile.linked_google)
	ne(s.account_id(), "")


func test_unlink() -> void:
	var s := _device()
	await s.start()
	_fake_id(s, "google").sub = "g-u"
	check((await s.sign_in_with("google")).ok)
	var r := await s.unlink("google")
	check(r.ok, r.error)
	check(not s.profile.linked_google)
	r = await s.unlink("google")
	eq(r.error, "not_linked")
	eq(NetSession.error_text(r, 0.0), NetSession.TEXT["not_linked"])


func test_one_sign_in_at_a_time() -> void:
	var s := _device()
	await s.start()
	fake.hold = true
	var done := {"first": false}
	var first := func() -> void:
		await s.sign_in_with("google")
		done["first"] = true
	first.call()
	check(s.identity_busy())
	var r := await s.sign_in_with("apple")
	eq(r.error, NetSession.ERR_BUSY)
	fake.release()
	for i in 30:
		if done["first"]:
			break
		fake.release()
		await tree.process_frame
	check(done["first"])
	check(not s.identity_busy())


func test_web_identity_bridge() -> void:
	var page := PageBridge.new()
	var w := NetWebIdentity.new("google", page)
	w.wait = func(_sec: float) -> void: await tree.process_frame
	check(not w.available(), "not before the server's config")
	w.configure({"enabled": false, "client_id": "x"})
	check(not w.available(), "a disabled provider loads nothing")
	for c in page.calls:
		check(not c.begins_with("window.wbIdentity.configure"), "no configure call")
	w.configure({"enabled": true, "client_id": "abc.apps.googleusercontent.com"})
	check(w.available())
	var handed := false
	for c in page.calls:
		handed = handed or (c.begins_with("window.wbIdentity.configure") and c.contains("abc.apps.googleusercontent.com"))
	check(handed, "the client id handed to the page")
	page.result = JSON.stringify({"state": "done", "id_token": "jwt.x.y", "code": ""})
	page.answer_after = 3
	var r := await w.sign_in("nonce-1")
	check(r.ok)
	eq(r.id_token, "jwt.x.y")
	check(page.calls.has("window.wbIdentity.begin(\"google\", \"nonce-1\")"))
	eq(page.polls, 3)
	page.result = JSON.stringify({"state": "cancelled"})
	page.polls = 0
	page.answer_after = 1
	check((await w.sign_in("n2")).cancelled())
	page.result = ""
	w.timeout_s = NetIdentityProvider.POLL_S * 3.0
	r = await w.sign_in("n3")
	eq(r.error, NetIdentityResult.TIMEOUT)
	check(page.calls.has("window.wbIdentity.cancel()"), "the sheet is closed on timeout")
	page.has_shell = false
	check(not w.available(), "no shell (Godot's default page): unavailable")


func test_identity_results_and_native_stub() -> void:
	eq(NetIdentityResult.from_page("{\"state\":\"error\",\"error\":\"popup_blocked\"}").error, "popup_blocked")
	eq(NetIdentityResult.from_page("nope").error, NetIdentityResult.FAILED)
	eq(NetIdentityResult.from_page("{\"state\":\"done\",\"id_token\":\"\"}").error, NetIdentityResult.FAILED)
	var n := NetNativeIdentity.new("apple")
	check(not n.available(), "no plugin in this build")
	var r := await n.sign_in("x")
	eq(r.error, NetIdentityResult.UNAVAILABLE)
	var ids := NetSession.platform_identity(tuning)
	check(ids["apple"] is NetNativeIdentity and ids["google"] is NetNativeIdentity, "native off the web")
	eq((ids["google"] as NetIdentityProvider).timeout_s, tuning.identity_sign_in_timeout_s)


func test_a_banned_device_cannot_sign_in_around_the_ban() -> void:
	var s := _device()
	await s.start()
	fake.ban(s.account_id(), int(fake.now_s) + 86400)
	await s.retry()
	eq(s.status, NetSession.Status.BANNED)
	var r := await s.sign_in_with("google")
	eq(r.error, NetApiResult.BANNED)
	eq(fake.count(NetApi.PATH_NONCE), 0, "no sheet, no new account")
