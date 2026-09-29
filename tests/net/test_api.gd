extends WBTest
## NetApi: JSON in and out, typed errors, retries with backoff (network, 5xx), 429 with
## Retry-After, no retry on other 4xx, the bearer header and one refresh-and-retry on a
## 401 `token_expired`; NetHttpNode against a real in-process HTTP server. Spec:
## multiplayer handoff → Client changes (`api.gd`), Accounts and authentication;
## docs/SERVER.md → Accounts API. WP N1.2.

const BASE := "https://api.test/api/v1"
const BIG_ID := "9223372036854775807"

var tuning: NetTuning
var fake: NetFakeAccounts
var api: NetApi
var _nodes: Array[Node] = []


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0


func before_each() -> void:
	fake = NetFakeAccounts.new()
	api = NetApi.new(fake, tuning, BASE, 11)


func after_each() -> void:
	api = null
	fake = null
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()


func test_create_device_parses_session_and_keeps_ids_as_strings() -> void:
	var r := await api.create_device()
	if not check(r.ok, "created: %s" % r.error):
		return
	eq(r.status, 201)
	check(r.data["account_id"] is String, "account id is a String")
	eq(r.str_field("account_id"), "41")
	eq(r.str_field("device_secret").length(), NetFakeAccounts.TOKEN_CHARS)
	eq(r.attempts, 1)
	eq(fake.requests[0]["path"], NetApi.PATH_DEVICE)
	eq(fake.requests[0]["method"], HTTPClient.METHOD_POST)
	eq(fake.requests[0]["body"], "", "no body")


func test_big_account_id_survives_as_string() -> void:
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE_LOGIN, 200, {"account_id": BIG_ID})
	var r := await api.device_login(BIG_ID, "s")
	eq(r.str_field("account_id"), BIG_ID)
	var body := NetFakeAccounts._json(String(fake.requests[0]["body"]))
	eq(body["account_id"], BIG_ID, "sent as a String")
	# A server that sent a number would still read as its digits.
	eq(NetApiResult.as_id(42.0), "42")


func test_error_body_is_typed() -> void:
	fake.script(HTTPClient.METHOD_PATCH, NetApi.PATH_ME, 409,
			{"error": "rename_cooldown", "message": "wait", "next_rename_at": 1792592000})
	api.bearer = func() -> String: return "tok"
	var r := await api.patch_me("New Name")
	check(not r.ok)
	eq(r.status, 409)
	eq(r.error, "rename_cooldown")
	eq(r.message, "wait")
	eq(r.next_rename_at, 1792592000)
	eq(r.attempts, 1, "4xx: no retry")
	check(not r.is_transient())


func test_banned_carries_until() -> void:
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_REFRESH, 403,
			{"error": "banned", "message": "banned", "banned_until": NetApiResult.BANNED_FOREVER})
	var r := await api.refresh("rt")
	eq(r.error, NetApiResult.BANNED)
	eq(r.banned_until, NetApiResult.BANNED_FOREVER)
	eq(fake.requests.size(), 1)


func test_network_errors_retry_with_backoff_then_succeed() -> void:
	fake.script_failure(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, HTTPRequest.RESULT_CANT_CONNECT)
	fake.script_failure(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, HTTPRequest.RESULT_TIMEOUT)
	var r := await api.create_device()
	check(r.ok, "third attempt succeeds")
	eq(r.attempts, 3)
	eq(fake.waits.size(), 2)
	near(fake.waits[0], tuning.api_backoff_base_s, 1e-9)
	near(fake.waits[1], tuning.api_backoff_base_s * 2.0, 1e-9)


func test_5xx_retries_until_the_limit() -> void:
	for i in tuning.api_max_retries + 2:
		fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, 503, {"error": "internal"})
	var r := await api.create_device()
	check(not r.ok)
	eq(r.error, NetApiResult.SERVER)
	check(r.is_transient())
	eq(r.attempts, tuning.api_max_retries + 1)
	eq(fake.waits.size(), tuning.api_max_retries)
	var expected := tuning.api_backoff_base_s
	for w in fake.waits:
		near(w, minf(expected, tuning.api_backoff_max_s), 1e-9)
		expected *= 2.0


func test_backoff_is_capped_and_jittered_within_bounds() -> void:
	var t := tuning.duplicate() as NetTuning
	t.api_backoff_jitter = 0.25
	var a := NetApi.new(fake, t, BASE, 5)
	for attempt in 10:
		var s := a.backoff_s(attempt)
		var nominal := minf(t.api_backoff_max_s, t.api_backoff_base_s * pow(2.0, float(attempt)))
		ge(s, nominal * 0.75 - 1e-9)
		le(s, nominal * 1.25 + 1e-9)


func test_no_retry_on_4xx() -> void:
	for code: int in [400, 401, 403, 404, 409, 413, 415]:
		fake.requests.clear()
		fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE_LOGIN, code, {"error": "x_%d" % code})
		var r := await api.device_login("1", "s")
		eq(r.error, "x_%d" % code)
		eq(fake.requests.size(), 1, "one attempt for %d" % code)
	eq(fake.waits.size(), 0, "never waited")


func test_429_waits_retry_after_then_retries() -> void:
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, 429,
			{"error": "rate_limited", "retry_after_secs": 3}, PackedStringArray(["Retry-After: 3"]))
	var r := await api.create_device()
	check(r.ok, "retried after Retry-After")
	eq(r.attempts, 2)
	eq(fake.waits.size(), 1)
	near(fake.waits[0], 3.0, 1e-9, "waited Retry-After, not the backoff")


func test_429_body_retry_after_when_no_header() -> void:
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, 429,
			{"error": "rate_limited", "retry_after_secs": 7})
	var r := await api.create_device()
	check(r.ok)
	near(fake.waits[0], 7.0, 1e-9)


func test_429_with_a_long_wait_returns_rate_limited() -> void:
	fake.script(HTTPClient.METHOD_POST, NetApi.PATH_DEVICE, 429,
			{"error": "rate_limited", "retry_after_secs": 600}, PackedStringArray(["retry-after: 600"]))
	var r := await api.create_device()
	check(not r.ok)
	eq(r.error, NetApiResult.RATE_LIMITED)
	near(r.retry_after_s, 600.0, 1e-9)
	eq(r.attempts, 1)
	eq(fake.waits.size(), 0)
	check(r.is_transient())


func test_no_retry_flag_is_one_attempt() -> void:
	fake.offline = true
	var r := await api.logout("rt")
	eq(r.error, NetApiResult.NETWORK)
	eq(r.attempts, 1)
	eq(r.transport_result, HTTPRequest.RESULT_CANT_CONNECT)


func test_bad_json_is_bad_response() -> void:
	fake.script(HTTPClient.METHOD_GET, NetApi.PATH_ME, 200, null)
	api.bearer = func() -> String: return "tok"
	var r := await api.get_me()
	check(r.ok, "an empty 200 body is fine")
	fake.script_raw(HTTPClient.METHOD_GET, NetApi.PATH_ME, 200, "<html>proxy</html>")
	r = await api.get_me()
	eq(r.error, NetApiResult.BAD_RESPONSE)
	fake.script_raw(HTTPClient.METHOD_GET, NetApi.PATH_ME, 502, "<html>bad gateway</html>")
	var t := tuning.duplicate() as NetTuning
	t.api_max_retries = 0
	api.tuning = t
	r = await api.get_me()
	eq(r.error, NetApiResult.SERVER, "a proxy's HTML 502 is a server error")


func test_bearer_header_and_refresh_retry_once() -> void:
	var c := await api.create_device()
	var token := {"t": c.str_field("access_token")}
	var refresh := {"t": c.str_field("refresh_token"), "calls": 0}
	api.bearer = func() -> String: return String(token["t"])
	api.refresh_access = func() -> bool:
		refresh["calls"] = int(refresh["calls"]) + 1
		var rr: NetApiResult = await api.refresh(String(refresh["t"]))
		if rr.ok:
			token["t"] = rr.str_field("access_token")
			refresh["t"] = rr.str_field("refresh_token")
		return rr.ok
	var r := await api.get_me()
	check(r.ok)
	eq(fake.requests[-1]["auth"], token["t"], "Authorization: Bearer <token>")
	fake.expire_access_tokens()
	fake.requests.clear()
	r = await api.get_me()
	check(r.ok, "refreshed and repeated: %s" % r.error)
	eq(refresh["calls"], 1)
	eq(fake.paths(), PackedStringArray([NetApi.PATH_ME, NetApi.PATH_REFRESH, NetApi.PATH_ME]))
	# A refresh that does not help: exactly one repeat, no loop.
	api.refresh_access = func() -> bool:
		refresh["calls"] = int(refresh["calls"]) + 1
		return true
	fake.expire_access_tokens()
	fake.requests.clear()
	r = await api.get_me()
	eq(r.error, NetApiResult.TOKEN_EXPIRED)
	eq(fake.requests.size(), 2, "the call and one repeat")


func test_auth_without_token_fails_locally() -> void:
	var r := await api.get_me()
	eq(r.error, NetApi.UNAUTHORIZED)
	eq(fake.requests.size(), 0)


func test_empty_base_url_is_offline() -> void:
	var a := NetApi.new(fake, tuning, "")
	var r := await a.create_device()
	eq(r.error, NetApiResult.OFFLINE)
	eq(fake.requests.size(), 0)


func test_response_header_lookup_is_case_insensitive() -> void:
	var resp := NetHttpResponse.make(429, "", PackedStringArray(["retry-AFTER:  12 ", "X: y"]))
	eq(resp.header("Retry-After"), "12")
	eq(resp.header("missing"), "")
	var r := NetApi.parse(resp, tuning)
	near(r.retry_after_s, 12.0, 1e-9)


## The real backend (HTTPRequest) against an HTTP server in this process: request line,
## headers and JSON body out, status, headers and JSON back, a 429's Retry-After, and a
## refused connection.
func test_http_node_round_trip_with_local_server() -> void:
	var server := TCPServer.new()
	var port := 0
	for p in range(38471, 38491):
		if server.listen(p, "127.0.0.1") == OK:
			port = p
			break
	if not check(port > 0, "listening"):
		return
	var host := Node.new()
	tree.root.add_child(host)
	_nodes.append(host)
	var t := tuning.duplicate() as NetTuning
	t.api_max_retries = 0
	t.api_timeout_s = 3.0
	var a := NetApi.new(NetHttpNode.new(host), t, "http://127.0.0.1:%d/api/v1" % port)
	a.bearer = func() -> String: return "abc"
	var seen: Array[String] = []
	var answers: Array[String] = [
		"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 42\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
	]
	var bodies: Array[String] = ['{"account_id":"9223372036854775807","display_name":"Şahin"}',
			'{"error":"rate_limited","message":"slow down","retry_after_secs":42}']
	var serve := func(i: int) -> void:
		var deadline := Time.get_ticks_msec() + 3000
		var peer: StreamPeerTCP = null
		var got := ""
		while Time.get_ticks_msec() < deadline:
			await tree.process_frame
			if peer == null and server.is_connection_available():
				peer = server.take_connection()
			if peer == null:
				continue
			peer.poll()
			var n := peer.get_available_bytes()
			if n > 0:
				got += (peer.get_data(n)[1] as PackedByteArray).get_string_from_utf8()
			var head_end := got.find("\r\n\r\n")
			if head_end >= 0:
				var cl := 0
				for line in got.substr(0, head_end).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						cl = line.substr(15).strip_edges().to_int()
				if got.to_utf8_buffer().size() >= head_end + 4 + cl:
					seen.append(got)
					var b := bodies[i].to_utf8_buffer()
					peer.put_data((answers[i] % [b.size(), bodies[i]]).to_utf8_buffer())
					for k in 5:
						await tree.process_frame
						peer.poll()
					peer.disconnect_from_host()
					return
	serve.call(0)
	var r: NetApiResult = await a.patch_me("Şahin")
	if check(r.ok, "200 via HTTPRequest: %s %d" % [r.error, r.transport_result]):
		eq(r.str_field("account_id"), BIG_ID)
		eq(r.data["display_name"], "Şahin")
	if check(seen.size() == 1, "server saw the request"):
		var req := seen[0]
		check(req.begins_with("PATCH /api/v1/me HTTP/1.1"), "request line: %s" % req.get_slice("\r\n", 0))
		check(req.contains("Authorization: Bearer abc"), "bearer header")
		check(req.contains("Content-Type: application/json"), "JSON content type")
		check(req.ends_with('{"display_name":"Şahin"}'), "JSON body, UTF-8")
	serve.call(1)
	r = await a.create_device()
	eq(r.error, NetApiResult.RATE_LIMITED)
	near(r.retry_after_s, 42.0, 1e-9, "Retry-After header through HTTPRequest")
	server.stop()
	# Nothing listens now: a network error, not an engine error.
	r = await a.create_device()
	eq(r.error, NetApiResult.NETWORK)
	eq(r.status, 0)
