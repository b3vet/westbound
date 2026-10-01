class_name NetFakeAccounts
extends NetHttpBackend
## An in-memory Accounts API behind the NetHttpBackend interface, for headless tests and
## offline previews. Mirrors docs/SERVER.md → Accounts API: device accounts, refresh
## rotation with reuse detection (the whole family is revoked), device login, GET/PATCH
## /me with the name rules and the 30-day cooldown, logout, deletion and bans. Spec:
## multiplayer handoff → Accounts and authentication; Testing → Client. WP N1.2.
## N11: Sign in with Apple / Google (GET /auth/providers, POST /auth/nonce, sign-in, link
## with the `identity_in_use` conflict and both summaries, unlink with its last-method
## rule, per-device credentials) and the cloud save (GET/PUT /save with If-Match and the
## 409 carrying the server copy). ID tokens are NetFakeIdentity's
## `fake.<provider>.<sub>.<nonce>`; the nonce must be one this fake issued.
##
## Test hooks:
##   offline = true                    every request fails with RESULT_CANT_CONNECT
##   hold = true ... release()         requests wait until released (a slow network)
##   script(method, path, status, body, headers)   the next matching request gets this
##   script_failure(method, path, result)          ... or this transport failure
##   ban(id, until), expire_access_tokens(), now_s (the server's unix clock)
##   N11: providers_enabled[p], cloud_save_enabled, save_max_bytes, put_save_direct(id, data)
##   (another device wrote), link_direct(id, provider, sub)
##   requests (each: method, path, auth, body, content_type; `bytes` for binary bodies),
##   waits (backoff seconds asked for)
## `wait()` returns at once and advances `now_s`, so retries cost no real time.

signal released()

const ACCESS_TTL_S := 3600
const REFRESH_TTL_S := 2592000
const RENAME_COOLDOWN_S := 2592000
const NAME_MIN := 3
const NAME_MAX := 16
const TAGS := 10000
const FIRST_ID := 41
const TOKEN_CHARS := 43
const GENERATED_NAMES: Array[String] = ["SwiftFalcon", "DustyComet", "NeonCoyote", "Sundowner"]
## Letters beyond ASCII the server allows (the Turkish ones).
const EXTRA_LETTERS := "ÇçĞğİıÖöŞşÜü"
const SEPARATORS := " _-."

var now_s: float = 1790000000.0
var offline: bool = false
var hold: bool = false
## Substrings the fake's "profanity filter" rejects (lowercase).
var blocked: PackedStringArray = PackedStringArray(["rude"])
## Lowercase `name` values whose every tag is taken.
var full_names: PackedStringArray = PackedStringArray()

var requests: Array[Dictionary] = []
var waits: Array[float] = []
## id -> {secret, name, tag, created_at, name_changed_at, renamed (bool), banned_until, ver}
var accounts: Dictionary = {}
## refresh token -> {account, family, used, revoked, expires_at}
var refresh_tokens: Dictionary = {}
## access token -> {account, exp, ver}
var access_tokens: Dictionary = {}

## N11: provider sign-in and cloud save.
var providers_enabled: Dictionary = {"apple": true, "google": true}
var cloud_save_enabled: bool = true
var save_max_bytes: int = 65536
## nonce -> expiry (unix seconds)
var nonces: Dictionary = {}
## "provider:sub" -> account id
var subs: Dictionary = {}
## account id -> {revision, updated_at, data}
var saves: Dictionary = {}

var _scripted: Array[Dictionary] = []
var _headers: PackedStringArray = PackedStringArray()
var _next_id: int = FIRST_ID
var _serial: int = 0


# ---------------------------------------------------------------- Test hooks

func script(method: int, path: String, status: int, body: Variant = null,
		headers: PackedStringArray = PackedStringArray()) -> void:
	_scripted.append({"method": method, "path": path, "status": status,
			"body": "" if body == null else JSON.stringify(body), "headers": headers, "result": -1})


## Like script(), with a raw body (not JSON: proxies' HTML pages).
func script_raw(method: int, path: String, status: int, body_text: String) -> void:
	_scripted.append({"method": method, "path": path, "status": status, "body": body_text,
			"headers": PackedStringArray(), "result": -1})


func script_failure(method: int, path: String, transport_result: int) -> void:
	_scripted.append({"method": method, "path": path, "result": transport_result})


func release() -> void:
	hold = false
	released.emit()


func ban(id: String, until_unix: int) -> void:
	if accounts.has(id):
		(accounts[id] as Dictionary)["banned_until"] = until_unix


func expire_access_tokens() -> void:
	for t: String in access_tokens:
		(access_tokens[t] as Dictionary)["exp"] = now_s - 1.0


## Requests to `path` (any method when `method` < 0).
func count(path: String, method: int = -1) -> int:
	var n := 0
	for r in requests:
		if r["path"] == path and (method < 0 or r["method"] == method):
			n += 1
	return n


func paths() -> PackedStringArray:
	var out := PackedStringArray()
	for r in requests:
		out.append(String(r["path"]))
	return out


# ---------------------------------------------------------------- Backend

func request(method: int, url: String, headers: PackedStringArray, body: String,
		_timeout_s: float) -> NetHttpResponse:
	return await _dispatch(method, url, headers, body)


## Binary bodies (N8.1 replay uploads): recorded with `bytes` and the content type, routed
## to _route_raw().
func request_raw(method: int, url: String, headers: PackedStringArray, body: PackedByteArray,
		_timeout_s: float) -> NetHttpResponse:
	return await _dispatch(method, url, headers, body)


func _dispatch(method: int, url: String, headers: PackedStringArray, body: Variant) -> NetHttpResponse:
	var path := _path(url)
	var auth := ""
	var content_type := ""
	for h in headers:
		if h.to_lower().begins_with("authorization: bearer "):
			auth = h.substr("authorization: bearer ".length())
		elif h.to_lower().begins_with("content-type: "):
			content_type = h.substr("content-type: ".length())
	var raw := body is PackedByteArray
	var if_match := ""
	for h in headers:
		if h.to_lower().begins_with("if-match: "):
			if_match = h.substr("if-match: ".length())
	_headers = headers
	var rec := {"method": method, "path": path, "auth": auth, "body": "" if raw else String(body),
			"content_type": content_type, "if_match": if_match}
	if raw:
		rec["bytes"] = body
	requests.append(rec)
	if hold:
		await released
	if offline:
		return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)
	for i in _scripted.size():
		var s := _scripted[i]
		if int(s["method"]) == method and String(s["path"]) == path:
			_scripted.remove_at(i)
			if int(s["result"]) >= 0:
				return NetHttpResponse.failed(int(s["result"]))
			return NetHttpResponse.make(int(s["status"]), String(s["body"]), s["headers"] as PackedStringArray)
	if raw:
		return _route_raw(method, path, auth, body as PackedByteArray)
	return _route(method, path, auth, String(body))


func wait(seconds: float) -> void:
	waits.append(seconds)
	now_s += seconds


static func _path(url: String) -> String:
	var i := url.find(NetSession.API_PATH + "/")
	if i >= 0:
		return url.substr(i + NetSession.API_PATH.length())
	var scheme := url.find("//")
	var slash := url.find("/", scheme + 2 if scheme >= 0 else 0)
	return url.substr(slash) if slash >= 0 else "/"


# ---------------------------------------------------------------- Routes

func _route(method: int, path: String, auth: String, body: String) -> NetHttpResponse:
	var b := _json(body)
	var post := method == HTTPClient.METHOD_POST
	if post and path == NetApi.PATH_DEVICE:
		return _create()
	if post and path == NetApi.PATH_DEVICE_LOGIN:
		return _login(b)
	if post and path == NetApi.PATH_REFRESH:
		return _refresh(b)
	if post and path == NetApi.PATH_LOGOUT:
		return _logout(b)
	if path == NetApi.PATH_ME and (method == HTTPClient.METHOD_GET or method == HTTPClient.METHOD_PATCH):
		var who: Variant = _authed(auth, false)
		if who is NetHttpResponse:
			return who as NetHttpResponse
		if method == HTTPClient.METHOD_GET:
			return _ok(200, _profile(String(who)))
		return _rename(String(who), b)
	if path == NetApi.PATH_ACCOUNT and method == HTTPClient.METHOD_DELETE:
		var who: Variant = _authed(auth, true)
		if who is NetHttpResponse:
			return who as NetHttpResponse
		_delete(String(who))
		return NetHttpResponse.make(204)
	var n11 := _route_identity(method, path, auth, b)
	if n11 != null:
		return n11
	return _err(404, "not_found")


## Binary-body routes (none here; NetFakeBoards adds the replay upload).
func _route_raw(_method: int, _url_path: String, _auth: String, _body: PackedByteArray) -> NetHttpResponse:
	return _err(404, "not_found")


func _create() -> NetHttpResponse:
	var id := str(_next_id)
	_next_id += 1
	_serial += 1
	var acc := {
		"secret": _token("sec"),
		"name": GENERATED_NAMES[_serial % GENERATED_NAMES.size()],
		"tag": (_serial * 37) % TAGS,
		"created_at": int(now_s),
		"name_changed_at": int(now_s),
		"renamed": false,
		"banned_until": 0,
		"ver": 0,
	}
	accounts[id] = acc
	var out := _session(id, _token("fam"))
	out["device_secret"] = acc["secret"]
	out["profile"] = _profile(id)
	return _ok(201, out)


func _login(b: Dictionary) -> NetHttpResponse:
	var id: Variant = b.get("account_id")
	var secret: Variant = b.get("device_secret")
	if not (id is String) or not (secret is String):
		return _err(400, "invalid_body")
	if not accounts.has(id):
		return _err(401, "invalid_credentials")
	var acc_rec: Dictionary = accounts[id]
	if acc_rec["secret"] != secret and not (acc_rec.get("secrets", []) as Array).has(secret):
		return _err(401, "invalid_credentials")
	var banned := _banned(String(id))
	if banned != null:
		return banned
	var out := _session(String(id), _token("fam"))
	out["profile"] = _profile(String(id))
	return _ok(200, out)


func _refresh(b: Dictionary) -> NetHttpResponse:
	var t: Variant = b.get("refresh_token")
	if not (t is String):
		return _err(400, "invalid_body")
	if not refresh_tokens.has(t):
		return _err(401, "invalid_token")
	var rec: Dictionary = refresh_tokens[t]
	if bool(rec["revoked"]) or not accounts.has(rec["account"]):
		return _err(401, "token_revoked")
	if bool(rec["used"]):
		_revoke_family(String(rec["family"]))
		return _err(401, "token_reused")
	if float(rec["expires_at"]) <= now_s:
		return _err(401, "token_expired")
	var banned := _banned(String(rec["account"]))
	if banned != null:
		return banned   # not consumed: works again after the ban
	rec["used"] = true
	return _ok(200, _session(String(rec["account"]), String(rec["family"])))


func _logout(b: Dictionary) -> NetHttpResponse:
	var t: Variant = b.get("refresh_token")
	if t is String and refresh_tokens.has(t):
		var rec: Dictionary = refresh_tokens[t]
		_revoke_family(String(rec["family"]))
		if bool(b.get("all_devices", false)) and accounts.has(rec["account"]):
			var acc: Dictionary = accounts[rec["account"]]
			acc["ver"] = int(acc["ver"]) + 1
			for k: String in refresh_tokens:
				if (refresh_tokens[k] as Dictionary)["account"] == rec["account"]:
					(refresh_tokens[k] as Dictionary)["revoked"] = true
	return NetHttpResponse.make(204)


func _rename(id: String, b: Dictionary) -> NetHttpResponse:
	var v: Variant = b.get("display_name")
	if not (v is String):
		return _err(400, "invalid_body")
	var n := (v as String).strip_edges()
	if not valid_name(n):
		return _err(400, "invalid_name")
	for w in blocked:
		if n.to_lower().contains(w):
			return _err(400, "name_not_allowed")
	var acc: Dictionary = accounts[id]
	if n == acc["name"]:
		return _err(400, "name_unchanged")
	var next := int(acc["name_changed_at"]) + RENAME_COOLDOWN_S
	if bool(acc["renamed"]) and float(next) > now_s:
		var e := _err_body("rename_cooldown")
		e["next_rename_at"] = next
		return _ok(409, e)
	if full_names.has(n.to_lower()):
		return _err(409, "name_unavailable")
	acc["name"] = n
	acc["renamed"] = true
	acc["name_changed_at"] = int(now_s)
	return _ok(200, _profile(id))


func _delete(id: String) -> void:
	accounts.erase(id)
	saves.erase(id)
	for k: String in subs.keys():
		if subs[k] == id:
			subs.erase(k)
	for k: String in refresh_tokens.keys():
		if (refresh_tokens[k] as Dictionary)["account"] == id:
			refresh_tokens.erase(k)


## The account id for a bearer token, or the 401 / 403 response.
func _authed(token: String, allow_banned: bool) -> Variant:
	if token.is_empty():
		return _err(401, "unauthorized")
	if not access_tokens.has(token):
		return _err(401, "invalid_token")
	var rec: Dictionary = access_tokens[token]
	if float(rec["exp"]) <= now_s:
		return _err(401, "token_expired")
	var id := String(rec["account"])
	if not accounts.has(id) or int((accounts[id] as Dictionary)["ver"]) != int(rec["ver"]):
		return _err(401, "token_revoked")
	if not allow_banned:
		var banned := _banned(id)
		if banned != null:
			return banned
	return id


func _banned(id: String) -> NetHttpResponse:
	var until := int((accounts[id] as Dictionary)["banned_until"])
	if until > int(now_s):
		var e := _err_body("banned")
		e["banned_until"] = until
		return _ok(403, e)
	return null


func _session(id: String, family: String) -> Dictionary:
	var access := _token("at")
	access_tokens[access] = {"account": id, "exp": now_s + ACCESS_TTL_S,
			"ver": int((accounts[id] as Dictionary)["ver"])}
	var refresh := _token("rt")
	refresh_tokens[refresh] = {"account": id, "family": family, "used": false, "revoked": false,
			"expires_at": now_s + REFRESH_TTL_S}
	return {
		"account_id": id,
		"access_token": access, "token_type": "Bearer", "expires_in": ACCESS_TTL_S,
		"expires_at": int(now_s) + ACCESS_TTL_S,
		"refresh_token": refresh, "refresh_expires_at": int(now_s) + REFRESH_TTL_S,
	}


func _profile(id: String) -> Dictionary:
	var acc: Dictionary = accounts[id]
	var next: Variant = null
	if bool(acc["renamed"]) and float(int(acc["name_changed_at"]) + RENAME_COOLDOWN_S) > now_s:
		next = int(acc["name_changed_at"]) + RENAME_COOLDOWN_S
	return {
		"account_id": id, "display_name": acc["name"], "name_tag": acc["tag"],
		"full_name": "%s#%04d" % [acc["name"], acc["tag"]],
		"created_at": acc["created_at"], "name_changed_at": acc["name_changed_at"],
		"next_rename_at": next, "linked": {"apple": subs_of(id).has("apple"), "google": subs_of(id).has("google")},
		"identities": _identities(id),
	}


func _revoke_family(family: String) -> void:
	for k: String in refresh_tokens:
		var rec: Dictionary = refresh_tokens[k]
		if rec["family"] == family:
			rec["revoked"] = true


## The server's display-name rules (docs/SERVER.md → PATCH /me), without the filter.
static func valid_name(n: String) -> bool:
	if n.length() < NAME_MIN or n.length() > NAME_MAX:
		return false
	var letter := false
	var prev_sep := false
	for i in n.length():
		var c := n[i]
		var is_letter := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or EXTRA_LETTERS.contains(c)
		var is_digit := c >= "0" and c <= "9"
		var is_sep := SEPARATORS.contains(c)
		if not (is_letter or is_digit or is_sep):
			return false
		if is_sep and (i == 0 or i == n.length() - 1 or prev_sep):
			return false
		letter = letter or is_letter
		prev_sep = is_sep
	return letter


func _token(prefix: String) -> String:
	_serial += 1
	var core := ("%s-%d-%d" % [prefix, _serial, int(now_s)]).sha256_text()
	return (prefix + "_" + core).left(TOKEN_CHARS)


func _ok(status: int, body: Dictionary) -> NetHttpResponse:
	return NetHttpResponse.make(status, JSON.stringify(body), PackedStringArray(["Content-Type: application/json"]))


func _err(status: int, code: String) -> NetHttpResponse:
	return _ok(status, _err_body(code))


func _err_body(code: String) -> Dictionary:
	return {"error": code, "message": code.replace("_", " ")}


static func _json(text: String) -> Dictionary:
	if text.is_empty():
		return {}
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		return {}
	return j.data as Dictionary


# ---------------------------------------------------------------- N11: identity, cloud save

## Puts a save on the server as if another device wrote it.
func put_save_direct(id: String, data: Dictionary) -> int:
	var cur: Dictionary = saves.get(id, {"revision": 0})
	var rev := int(cur["revision"]) + 1
	saves[id] = {"revision": rev, "updated_at": int(now_s), "data": data.duplicate(true)}
	return rev


## An account nobody signs in to here (another device's), named `display_name#tag`.
func add_account(display_name: String, tag: int) -> String:
	var id := str(_next_id)
	_next_id += 1
	accounts[id] = {"secret": _token("sec"), "name": display_name, "tag": tag, "created_at": int(now_s),
		"name_changed_at": int(now_s), "renamed": false, "banned_until": 0, "ver": 0}
	return id


## Links an identity without a token (test setup).
func link_direct(id: String, provider: String, sub: String) -> void:
	subs["%s:%s" % [provider, sub]] = id


## provider -> sub of an account's identities.
func subs_of(id: String) -> Dictionary:
	var out := {}
	for k: String in subs:
		if subs[k] == id:
			var parts := k.split(":", true, 1)
			out[parts[0]] = parts[1]
	return out


func _identities(id: String) -> Array:
	var out: Array = []
	var linked := subs_of(id)
	for p: String in NetIdentityProvider.ALL:
		if linked.has(p):
			var hint: Variant = null
			if p == "google":
				hint = "p***@gmail.com"
			out.append({"provider": p, "email_hint": hint, "private_email": p == "apple",
					"linked_at": int(now_s)})
	return out


func _route_identity(method: int, path: String, auth: String, b: Dictionary) -> NetHttpResponse:
	var post := method == HTTPClient.METHOD_POST
	if method == HTTPClient.METHOD_GET and path == NetApi.PATH_PROVIDERS:
		return _ok(200, {
			"apple": {"enabled": bool(providers_enabled.get("apple", false)), "client_id": "com.fake.web",
				"redirect_uri": "https://fake.test/"},
			"google": {"enabled": bool(providers_enabled.get("google", false)), "client_id": "fake.apps.googleusercontent.com"},
			"nonce_required": true,
			"cloud_save": {"enabled": cloud_save_enabled, "max_bytes": save_max_bytes},
		})
	if post and path == NetApi.PATH_NONCE:
		_serial += 1
		var n := "n-%d" % _serial
		nonces[n] = int(now_s) + 600
		return _ok(200, {"nonce": n, "expires_at": nonces[n]})
	for prefix: String in [NetApi.PATH_SIGNIN, NetApi.PATH_LINK, NetApi.PATH_UNLINK]:
		if post and path.begins_with(prefix):
			var p := path.substr(prefix.length())
			if not NetIdentityProvider.ALL.has(p):
				return _err(404, "not_found")
			match prefix:
				NetApi.PATH_SIGNIN:
					return _provider_sign_in(p, b)
				NetApi.PATH_LINK:
					return _link(p, auth, b)
				_:
					return _unlink(p, auth)
	if path == NetApi.PATH_SAVE and (method == HTTPClient.METHOD_GET or method == HTTPClient.METHOD_PUT):
		var who: Variant = _authed(auth, false)
		if who is NetHttpResponse:
			return who as NetHttpResponse
		if not cloud_save_enabled:
			return _err(501, "cloud_save_not_enabled")
		if method == HTTPClient.METHOD_GET:
			return _ok(200, _save_body(String(who)))
		return _put_save(String(who), b)
	return null


## The verified identity {sub} of a fake token, or the error response.
func _verify(p: String, b: Dictionary) -> Variant:
	if not bool(providers_enabled.get(p, false)):
		return _err(501, "provider_not_enabled")
	var t: Variant = b.get("id_token")
	var n: Variant = b.get("nonce")
	if not (t is String):
		return _err(400, "invalid_body")
	var parts := (t as String).split(".")
	if parts.size() != 4 or parts[0] != "fake" or parts[1] != p or parts[2].is_empty():
		return _err(401, "invalid_id_token")
	if not (n is String) or parts[3] != n or not nonces.has(n) or int(nonces[n]) <= int(now_s):
		return _err(400, "invalid_nonce")
	return parts[2]


func _provider_sign_in(p: String, b: Dictionary) -> NetHttpResponse:
	var sub: Variant = _verify(p, b)
	if sub is NetHttpResponse:
		return sub as NetHttpResponse
	var key := "%s:%s" % [p, sub]
	var created := not subs.has(key)
	var id := ""
	var secret := _token("sec")
	if created:
		var made := _create()
		id = str(JSON.parse_string(made.text())["account_id"])
		(accounts[id] as Dictionary)["secret"] = secret
		subs[key] = id
	else:
		id = String(subs[key])
		var banned := _banned(id)
		if banned != null:
			return banned
		var acc: Dictionary = accounts[id]
		var extra: Array = acc.get("secrets", [])
		extra.append(secret)
		acc["secrets"] = extra
	var out := _session(id, _token("fam"))
	out["device_secret"] = secret
	out["profile"] = _profile(id)
	out["created"] = created
	return _ok(201 if created else 200, out)


func _link(p: String, auth: String, b: Dictionary) -> NetHttpResponse:
	var who: Variant = _authed(auth, false)
	if who is NetHttpResponse:
		return who as NetHttpResponse
	var me := String(who)
	var sub: Variant = _verify(p, b)
	if sub is NetHttpResponse:
		return sub as NetHttpResponse
	var key := "%s:%s" % [p, sub]
	if subs.has(key) and subs[key] != me:
		var e := _err_body("identity_in_use")
		e["conflict"] = {"provider": p, "current": _summary(me), "other": _summary(String(subs[key]))}
		return _ok(409, e)
	if not subs.has(key) and subs_of(me).has(p):
		return _err(409, "provider_already_linked")
	subs[key] = me
	return _ok(200, _profile(me))


func _unlink(p: String, auth: String) -> NetHttpResponse:
	var who: Variant = _authed(auth, false)
	if who is NetHttpResponse:
		return who as NetHttpResponse
	var me := String(who)
	var linked := subs_of(me)
	if not linked.has(p):
		return _err(404, "not_linked")
	subs.erase("%s:%s" % [p, linked[p]])
	return _ok(200, _profile(me))


func _summary(id: String) -> Dictionary:
	var acc: Dictionary = accounts[id]
	var cs: Variant = null
	if saves.has(id):
		var sv: Dictionary = saves[id]
		var data: Dictionary = sv["data"]
		var st: Variant = data.get("stats", {})
		var stats: Dictionary = st if st is Dictionary else {}
		cs = {"revision": sv["revision"], "updated_at": sv["updated_at"], "bytes": JSON.stringify(data).length(),
			"xp": stats.get("xp"), "runs": stats.get("runs")}
	return {"account_id": id, "full_name": "%s#%04d" % [acc["name"], acc["tag"]],
		"created_at": acc["created_at"], "last_seen": int(now_s),
		"linked": {"apple": subs_of(id).has("apple"), "google": subs_of(id).has("google")},
		"runs": 0, "best_score": 0, "cloud_save": cs}


func _save_body(id: String) -> Dictionary:
	if not saves.has(id):
		return {"revision": 0, "updated_at": null, "bytes": 0, "data": null}
	var sv: Dictionary = saves[id]
	return {"revision": sv["revision"], "updated_at": sv["updated_at"],
		"bytes": JSON.stringify(sv["data"]).length(), "data": (sv["data"] as Dictionary).duplicate(true)}


func _put_save(id: String, b: Dictionary) -> NetHttpResponse:
	var m := ""
	for h in _headers:
		if h.to_lower().begins_with("if-match: "):
			m = h.substr("if-match: ".length()).strip_edges().trim_prefix("\"").trim_suffix("\"")
	if not m.is_valid_int():
		return _err(428, "precondition_required")
	var data: Variant = b.get("data")
	if not (data is Dictionary):
		return _err(400, "invalid_body")
	if JSON.stringify(data).length() > save_max_bytes:
		var e := _err_body("save_too_large")
		e["max_bytes"] = save_max_bytes
		return _ok(413, e)
	var cur := _save_body(id)
	if int(cur["revision"]) != m.to_int():
		var c := _err_body("revision_conflict")
		c["save"] = cur
		return _ok(409, c)
	var rev := put_save_direct(id, data as Dictionary)
	return _ok(200, {"revision": rev, "updated_at": int(now_s), "bytes": JSON.stringify(data).length()})
