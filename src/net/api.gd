class_name NetApi
extends RefCounted
## HTTP client for the Westbound Online API: JSON in and out, timeouts, retries with
## backoff, 429 with Retry-After, typed errors, the bearer token and one refresh-and-retry
## on `token_expired`. Spec: multiplayer handoff → Client changes (`api.gd`: HTTP client
## using HTTPRequest), Accounts and authentication; docs/SERVER.md → Accounts API.
## WP N1.2; docs/NET_CLIENT.md → Accounts client.
##
##   var api := NetApi.new(NetHttpNode.new(host), tuning, base_url)
##   api.bearer = session.access_token              # Callable -> String
##   api.refresh_access = session.refresh_for_api   # coroutine Callable -> bool
##   var r: NetApiResult = await api.get_me()
##   if r.ok: print(r.data["full_name"]) else: show(NetSession.error_text(r))
##
## Retries (up to `api_max_retries`): a network failure or a 5xx waits
## `api_backoff_base_s` × 2^attempt (capped at `api_backoff_max_s`, ± `api_backoff_jitter`);
## a 429 waits its Retry-After when that is at most `api_retry_after_max_s`, otherwise it
## returns `rate_limited` with `retry_after_s`. Any other 4xx returns at once. Calls with
## AUTH send `Authorization: Bearer <token>` and, on a 401 `token_expired` (or
## `token_revoked` / `invalid_token`), call `refresh_access` once and repeat the request
## with the new token. Tokens and secrets
## are never logged.

## Request flags.
const AUTH := 1
const NO_RETRY := 2

const PATH_DEVICE := "/auth/device"
const PATH_DEVICE_LOGIN := "/auth/device/login"
const PATH_REFRESH := "/auth/refresh"
const PATH_LOGOUT := "/auth/logout"
const PATH_ME := "/me"
const PATH_ACCOUNT := "/account"
## N11: Sign in with Apple / Google, cloud save (docs/SERVER.md).
const PATH_PROVIDERS := "/auth/providers"
const PATH_NONCE := "/auth/nonce"
const PATH_SIGNIN := "/auth/signin/"
const PATH_LINK := "/auth/link/"
const PATH_UNLINK := "/auth/unlink/"
const PATH_SAVE := "/save"

const HTTP_BAD_REQUEST := 400
const HTTP_UNAUTHORIZED := 401
const HTTP_CONFLICT := 409
const HTTP_TOO_MANY := 429
const HTTP_SERVER_ERROR := 500
const HTTP_OK_MIN := 200
const HTTP_OK_END := 300
const UNAUTHORIZED := "unauthorized"
## 401 codes after which the access token is renewed and the call repeated once:
## `token_expired` (the 1 h token ran out), and `token_revoked` / `invalid_token` (a
## "log out everywhere" or a server key change killed it; the renewal falls back to the
## device secret).
const RENEWABLE: Array[String] = ["token_expired", "token_revoked", "invalid_token"]

var backend: NetHttpBackend
var tuning: NetTuning
## e.g. https://westbound.sipsakrandevu.com/api/v1 (no trailing slash); "" = offline.
var base_url: String
## () -> String: the current access token ("" = none).
var bearer: Callable
## () -> bool coroutine: gets a fresh access token after `token_expired`.
var refresh_access: Callable
## HTTP attempts made (tests, dev stats).
var attempts_sent: int = 0

var _rng: Rng


func _init(http: NetHttpBackend, net_tuning: NetTuning, url: String, jitter_seed: int = 0) -> void:
	backend = http
	tuning = net_tuning
	base_url = url.trim_suffix("/")
	_rng = Rng.new(jitter_seed if jitter_seed != 0 else Time.get_ticks_usec())


# ---------------------------------------------------------------- Accounts routes

## POST /auth/device (201): a new device account, its tokens, its secret and profile.
func create_device() -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_DEVICE)


## POST /auth/device/login: tokens and profile for a stored account id and secret.
func device_login(account_id: String, device_secret: String) -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_DEVICE_LOGIN,
			{"account_id": account_id, "device_secret": device_secret})


## POST /auth/refresh: rotates the refresh token (single use).
func refresh(refresh_token: String) -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_REFRESH, {"refresh_token": refresh_token})


## POST /auth/logout (204, best effort: one attempt).
func logout(refresh_token: String, all_devices: bool = false) -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_LOGOUT,
			{"refresh_token": refresh_token, "all_devices": all_devices}, NO_RETRY)


func get_me() -> NetApiResult:
	return await request(HTTPClient.METHOD_GET, PATH_ME, null, AUTH)


## PATCH /me {display_name}: the new profile, or invalid_name / name_not_allowed /
## name_unchanged / rename_cooldown / name_unavailable.
func patch_me(display_name: String) -> NetApiResult:
	return await request(HTTPClient.METHOD_PATCH, PATH_ME, {"display_name": display_name}, AUTH)


## DELETE /account (204).
func delete_account() -> NetApiResult:
	return await request(HTTPClient.METHOD_DELETE, PATH_ACCOUNT, null, AUTH)


# ---------------------------------------------------------------- Identity and cloud save (N11)

## GET /auth/providers: {apple: {enabled, client_id, redirect_uri}, google: {enabled,
## client_id}, nonce_required, cloud_save: {enabled, max_bytes}}.
func get_providers() -> NetApiResult:
	return await request(HTTPClient.METHOD_GET, PATH_PROVIDERS)


## POST /auth/nonce: {nonce, expires_at}.
func get_nonce() -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_NONCE)


## The body of a sign-in or link: the provider's ID token, the nonce, Apple's code.
static func identity_body(id_token: String, nonce: String, authorization_code: String = "") -> Dictionary:
	var b := {"id_token": id_token, "nonce": nonce}
	if not authorization_code.is_empty():
		b["authorization_code"] = authorization_code
	return b


## POST /auth/signin/{provider}: the session fields, `device_secret`, `profile`, `created`.
## One attempt: an ID token is single-purpose and the player is waiting.
func provider_sign_in(provider: String, body: Dictionary) -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_SIGNIN + provider, body, NO_RETRY)


## POST /auth/link/{provider} (bearer): the profile, or 409 `identity_in_use` with
## `conflict` {provider, current, other}.
func link_provider(provider: String, body: Dictionary) -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_LINK + provider, body, AUTH | NO_RETRY)


## POST /auth/unlink/{provider} (bearer): the profile, or `last_sign_in_method` / `not_linked`.
func unlink_provider(provider: String) -> NetApiResult:
	return await request(HTTPClient.METHOD_POST, PATH_UNLINK + provider, null, AUTH)


## GET /save (bearer): {revision (0 = none), updated_at, bytes, data}.
func get_save() -> NetApiResult:
	return await request(HTTPClient.METHOD_GET, PATH_SAVE, null, AUTH)


## PUT /save (bearer) with If-Match: {revision, updated_at, bytes}, or 409
## `revision_conflict` with the server's copy in `save`.
func put_save(data: Dictionary, revision: int) -> NetApiResult:
	return await request(HTTPClient.METHOD_PUT, PATH_SAVE, {"data": data}, AUTH,
			PackedStringArray(["If-Match: \"%d\"" % revision]))


# ---------------------------------------------------------------- Core

## One API call: `body` (a Dictionary, or null for none) is sent as JSON; a
## PackedByteArray is sent as is, `application/octet-stream` (the replay upload, N8.1).
func request(method: int, path: String, body: Variant = null, flags: int = 0,
		extra_headers: PackedStringArray = PackedStringArray()) -> NetApiResult:
	if base_url.is_empty():
		return NetApiResult.failure(0, NetApiResult.OFFLINE, "online features are off")
	var r := await _send(method, path, body, flags, extra_headers)
	if (flags & AUTH) != 0 and not r.ok and r.status == HTTP_UNAUTHORIZED \
			and RENEWABLE.has(r.error) and refresh_access.is_valid():
		var refreshed: bool = await refresh_access.call()
		if refreshed:
			var again := await _send(method, path, body, flags, extra_headers)
			again.attempts += r.attempts
			return again
	return r


func _send(method: int, path: String, body: Variant, flags: int,
		extra_headers: PackedStringArray = PackedStringArray()) -> NetApiResult:
	var url := base_url + path
	var raw := body is PackedByteArray
	var body_text := "" if body == null or raw else JSON.stringify(body)
	var max_retries := 0 if (flags & NO_RETRY) != 0 else maxi(tuning.api_max_retries, 0)
	var attempt := 0
	while true:
		var headers := PackedStringArray(["Accept: application/json"])
		headers.append_array(extra_headers)
		if raw:
			headers.append("Content-Type: application/octet-stream")
		elif body != null:
			headers.append("Content-Type: application/json")
		if (flags & AUTH) != 0:
			var token: String = bearer.call() if bearer.is_valid() else ""
			if token.is_empty():
				return NetApiResult.failure(HTTP_UNAUTHORIZED, UNAUTHORIZED, "not signed in")
			headers.append("Authorization: Bearer " + token)
		attempt += 1
		attempts_sent += 1
		var resp: NetHttpResponse
		if raw:
			resp = await backend.request_raw(method, url, headers, body as PackedByteArray, tuning.api_timeout_s)
		else:
			resp = await backend.request(method, url, headers, body_text, tuning.api_timeout_s)
		var r := parse(resp, tuning)
		r.attempts = attempt
		if r.ok or attempt > max_retries:
			return r
		var wait_s := -1.0
		if not resp.arrived() or resp.status >= HTTP_SERVER_ERROR:
			wait_s = backoff_s(attempt - 1)
		elif resp.status == HTTP_TOO_MANY and r.retry_after_s <= tuning.api_retry_after_max_s:
			wait_s = r.retry_after_s
		if wait_s < 0.0:
			return r
		await backend.wait(wait_s)
	return NetApiResult.failure(0, NetApiResult.NETWORK)


## Wait before retry number `attempt` + 1 (0-based): exponential, capped, jittered.
func backoff_s(attempt: int) -> float:
	var s := minf(tuning.api_backoff_max_s, tuning.api_backoff_base_s * pow(2.0, float(attempt)))
	return maxf(0.0, s * (1.0 + tuning.api_backoff_jitter * (_rng.unit() * 2.0 - 1.0)))


## A NetHttpResponse as a NetApiResult (pure; tests).
static func parse(resp: NetHttpResponse, net_tuning: NetTuning) -> NetApiResult:
	if not resp.arrived():
		var n := NetApiResult.failure(0, NetApiResult.NETWORK, "no response (%d)" % resp.result)
		n.transport_result = resp.result
		return n
	var text := resp.text()
	var parsed: Variant = null
	if not text.strip_edges().is_empty():
		var j := JSON.new()
		if j.parse(text) == OK:
			parsed = j.data
	var dict: Dictionary = parsed if parsed is Dictionary else {}
	if resp.status >= HTTP_OK_MIN and resp.status < HTTP_OK_END:
		if not text.strip_edges().is_empty() and not (parsed is Dictionary):
			return NetApiResult.failure(resp.status, NetApiResult.BAD_RESPONSE, "body is not a JSON object")
		return NetApiResult.success(resp.status, dict)
	var code := NetApiResult.as_id(dict.get("error", ""))
	if resp.status >= HTTP_SERVER_ERROR:
		code = NetApiResult.SERVER
	elif resp.status == HTTP_TOO_MANY:
		code = NetApiResult.RATE_LIMITED
	elif code.is_empty():
		code = NetApiResult.BAD_RESPONSE
	var msg: Variant = dict.get("message", "")
	var r := NetApiResult.failure(resp.status, code, msg if msg is String else "")
	r.data = dict
	r.banned_until = r.int_field("banned_until")
	r.next_rename_at = r.int_field("next_rename_at")
	if resp.status == HTTP_TOO_MANY:
		r.retry_after_s = net_tuning.api_retry_after_default_s
		var h := resp.header("Retry-After")
		if h.is_valid_float():
			r.retry_after_s = maxf(0.0, h.to_float())
		elif dict.has("retry_after_secs"):
			r.retry_after_s = maxf(0.0, float(r.int_field("retry_after_secs")))
	return r
