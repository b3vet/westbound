class_name NetSession
extends Node
## The player's online session: a silent device account, token refresh, the profile,
## rename, logout and account deletion. Spec: multiplayer handoff → Accounts and
## authentication, Client changes (`session.gd`); plan MP-D2 (device accounts only);
## docs/SERVER.md → Accounts API. WP N1.2; docs/NET_CLIENT.md → Accounts client.
##
## An autoload candidate (`NetSession`); a scene may also add its own (previews, tests).
## `NetSession.current` is the live one. Offline first: nothing in the single-player
## game waits for it. Every call is async, and failures are states, never errors.
##
## States (`status`, `status_changed`):
##   IDLE --start()--> CONNECTING --> ONLINE | OFFLINE | BANNED | FAILED
##   (DISABLED when no server is configured, SIGNED_OUT after logout() or deletion)
##
## Launch (start()):
##   - no stored account: POST /auth/device, then store the account id, the device
##     secret (returned once) and the refresh token;
##   - a stored account: POST /auth/refresh (rotation: the new refresh token is stored
##     at once). If the server rejects the refresh token (token_reused, token_revoked,
##     token_expired, invalid_token), sign in with the device secret
##     (POST /auth/device/login). If that is refused (invalid_credentials), the session
##     is FAILED with the error surfaced: it never silently replaces a stored account.
##     The player can retry, or explicitly start a new account (create_new_account()).
##   - a network failure, a 5xx or a long 429: OFFLINE, with the cached profile, and the
##     sign-in is retried after `session_retry_s`, doubling up to `session_retry_max_s`.
##   - `banned`: BANNED, `banned(until)`.
## ONLINE: the access token is refreshed `session_refresh_margin_s` before it expires,
## and NetApi renews it on a 401 and repeats the call once.
##
## Storage (NetSessionStore): web localStorage (NetWebStore), native an encrypted user://
## file (NetFileStore) until the Keychain / Keystore plugins land (MP-D2). One document
## per server, so a `?server=` link never sends this device's production secret
## anywhere else. Secrets and tokens are never printed.

signal signed_in(profile: NetProfile)
signal signed_out()
signal profile_changed(profile: NetProfile)
## `until_unix`: unix seconds (NetApiResult.BANNED_FOREVER = permanent).
signal banned(until_unix: int)
signal status_changed(status: Status)
signal _renew_done()

enum Status { IDLE, CONNECTING, ONLINE, OFFLINE, SIGNED_OUT, BANNED, FAILED, DISABLED }

## Stored document keys (never printed).
const K_VERSION := "v"
const K_ACCOUNT := "account_id"
const K_SECRET := "device_secret"
const K_REFRESH := "refresh_token"
const K_REFRESH_EXP := "refresh_expires_at"
const K_PROFILE := "profile"
const K_SIGNED_OUT := "signed_out"
const DOC_VERSION := 1

## Session-side error codes (NetApiResult.error).
const ERR_NOT_SIGNED_IN := "not_signed_in"
const ERR_BUSY := "busy"
const ERR_INVALID_NAME := "invalid_name"

const SERVER_PARAM := "server"
const SERVER_ARG := "--server="
const SERVER_OFF: Array[String] = ["off", "none", "offline"]
const API_PATH := "/api/v1"
const WS_PATH := "/ws"
const STORE_DEFAULT := "session"
const STORE_HASH_CHARS := 12
const USEC_PER_S := 1000000.0

## The live session (autoload or a scene's own), null when none.
static var current: NetSession

## Starts signing in when it enters the tree (off in tests: call start()).
@export var auto_start: bool = true

var tuning: NetTuning
var api: NetApi
var store: NetSessionStore
var time: NetTimeSource
## API base ("" = online features off).
var base_url: String = ""
var status: Status = Status.IDLE
## The profile (cached from storage while offline); null before the first sign-in.
var profile: NetProfile
## The last failure worth showing (null after a success).
var last_error: NetApiResult
## Unix seconds of the ban's end while BANNED.
var banned_until: int = 0
## False when the platform store refused the last write (Safari private mode): the
## account lasts for this launch only.
var storage_ok: bool = true
## () -> float: wall-clock unix seconds (invalid = the system clock).
var unix_clock: Callable

var _configured: bool = false
var _doc: Dictionary = {}
var _access: String = ""
var _access_expires_usec: int = 0
var _busy: bool = false
var _renewing: bool = false
var _last_renew: NetApiResult
var _retry_at_usec: int = -1
var _retry_delay_s: float = 0.0
## The profile came from the server during this launch (not the cached copy).
var _profile_fresh: bool = false
## A failed proactive refresh waits until then before the next try.
var _next_renew_usec: int = 0


func _init() -> void:
	name = "NetSession"
	process_mode = Node.PROCESS_MODE_ALWAYS


## Injects the transport, store, tuning, clock and server (tests, previews). Call before
## the node enters the tree; otherwise _ready() builds the platform defaults.
func configure(backend: NetHttpBackend, session_store: NetSessionStore, net_tuning: NetTuning,
		clock: NetTimeSource = null, api_base: String = "", jitter_seed: int = 0) -> void:
	tuning = net_tuning
	time = clock if clock != null else NetTimeSource.new()
	base_url = api_base if not api_base.is_empty() else net_tuning.api_base_url
	store = session_store
	api = NetApi.new(backend, tuning, base_url, jitter_seed)
	api.bearer = _bearer
	api.refresh_access = refresh_for_api
	_configured = true


## No server at all (`?server=off`): the session stays DISABLED.
func configure_disabled(net_tuning: NetTuning) -> void:
	configure(NetHttpBackend.new(), NetSessionStore.new(), net_tuning)
	base_url = ""
	api.base_url = ""


func _enter_tree() -> void:
	if current == null or not is_instance_valid(current):
		current = self


func _exit_tree() -> void:
	if current == self:
		current = null


func _ready() -> void:
	if not _configured:
		var t := NetTuning.load_default()
		var url := resolve_base_url(t, NetJsBridge.new(), OS.get_cmdline_user_args())
		if url.is_empty():
			configure_disabled(t)
		else:
			configure(NetHttpNode.new(self), platform_store(store_name(url, t)), t, null, url)
	if auto_start:
		start()


func _process(_delta: float) -> void:
	poll()


# ---------------------------------------------------------------- Public API

## Loads the stored account and signs in (silently creates one on first launch).
## Returns when the attempt ends; callers never need to await it.
func start() -> void:
	if _busy:
		return
	if base_url.is_empty():
		_set_status(Status.DISABLED)
		return
	_doc = store.load_data()
	profile = NetProfile.from_dict(_doc.get(K_PROFILE))
	if bool(_doc.get(K_SIGNED_OUT, false)):
		_set_status(Status.SIGNED_OUT)
		return
	await _sign_in()


## Signs in again now (the player's RETRY or SIGN IN; also after a ban ends).
func retry() -> void:
	if _busy or base_url.is_empty():
		return
	_retry_delay_s = 0.0
	_retry_at_usec = -1
	if _doc.has(K_SIGNED_OUT):
		_doc.erase(K_SIGNED_OUT)
		_persist()
	await _sign_in()


## The player chose to start over after the stored account was refused (FAILED): forgets
## it on this device and creates a new one.
func create_new_account() -> void:
	if _busy or base_url.is_empty():
		return
	_forget_local()
	await _sign_in()


## The access token for NetClient's Hello and bearer calls ("" when not signed in or
## expired). Never log it.
func access_token() -> String:
	if status != Status.ONLINE or _access.is_empty():
		return ""
	if time.now_usec() >= _access_expires_usec:
		return ""
	return _access


## A token good for at least `session_refresh_margin_s` (renews first when needed; ""
## when that fails). For NetClient.start().
func fresh_access_token() -> String:
	if status == Status.ONLINE and _expiring():
		var r := await _renew()
		if not r.ok:
			_conclude(r)
	return access_token()


## The raw access token while it lasts (bearer calls; a banned account may still delete
## itself with the token it had).
func _bearer() -> String:
	if _access.is_empty() or time.now_usec() >= _access_expires_usec:
		return ""
	return _access


func is_online() -> bool:
	return status == Status.ONLINE


func account_id() -> String:
	return _doc_str(K_ACCOUNT)


## The WebSocket URL of this session's server (NetClient.start()).
func ws_url() -> String:
	if base_url.is_empty():
		return ""
	if tuning != null and base_url == tuning.api_base_url:
		return tuning.server_url
	var u := base_url.trim_suffix(API_PATH)
	if u.begins_with("https://"):
		u = "wss://" + u.substr("https://".length())
	elif u.begins_with("http://"):
		u = "ws://" + u.substr("http://".length())
	return u + WS_PATH


## Renames the player (PATCH /me). On success the profile updates and profile_changed
## fires; otherwise the result's `error` says why (see error_text()).
func rename(display_name: String) -> NetApiResult:
	var n := display_name.strip_edges()
	if n.length() < tuning.display_name_min_chars or n.length() > tuning.display_name_max_chars:
		return NetApiResult.failure(0, ERR_INVALID_NAME, "length")
	if status != Status.ONLINE:
		return NetApiResult.failure(0, ERR_NOT_SIGNED_IN)
	var r := await api.patch_me(n)
	if r.ok:
		_set_profile(r.data)
	else:
		_note_failure(r)
	return r


## Deletes the account on the server (DELETE /account), then everything stored on this
## device. SIGNED_OUT afterwards; the next launch starts a new device account.
func delete_account() -> NetApiResult:
	if status != Status.ONLINE and status != Status.BANNED:
		return NetApiResult.failure(0, ERR_NOT_SIGNED_IN)
	var r := await api.delete_account()
	if not r.ok:
		_note_failure(r)
		return r
	_forget_local()
	_set_status(Status.SIGNED_OUT)
	signed_out.emit()
	return r


## Logs this device out (POST /auth/logout, best effort). The account stays on this
## device (secret kept) and SIGN IN (retry()) brings it back; the next launch stays
## signed out until then.
func logout(all_devices: bool = false) -> NetApiResult:
	var rt := _refresh_token()
	var r := NetApiResult.success(0, {})
	if not rt.is_empty() and not base_url.is_empty():
		r = await api.logout(rt, all_devices)
	_doc.erase(K_REFRESH)
	_doc.erase(K_REFRESH_EXP)
	_doc[K_SIGNED_OUT] = true
	_persist()
	_access = ""
	_retry_at_usec = -1
	_set_status(Status.SIGNED_OUT)
	signed_out.emit()
	return r


## NetApi's renewal hook (after a 401): true when a new access token is ready.
func refresh_for_api() -> bool:
	var r := await _renew()
	if not r.ok:
		_conclude(r)
	return r.ok


## Time-driven work: the proactive refresh and the offline retry. Called every frame.
func poll() -> void:
	if _busy or _renewing:
		return
	var now := time.now_usec()
	if status == Status.ONLINE and _expiring() and now >= _next_renew_usec:
		_renew_in_background()
	elif status == Status.OFFLINE and _retry_at_usec >= 0 and now >= _retry_at_usec:
		_retry_at_usec = -1
		_sign_in()


## Seconds until the next automatic sign-in attempt (-1: none planned).
func retry_in_s() -> float:
	if _retry_at_usec < 0:
		return -1.0
	return maxf(0.0, float(_retry_at_usec - time.now_usec()) / USEC_PER_S)


## Wall-clock unix seconds (rename cooldown and ban texts). Tests set `unix_clock`.
func now_unix() -> float:
	return float(unix_clock.call()) if unix_clock.is_valid() else Time.get_unix_time_from_system()


# ---------------------------------------------------------------- Flow

func _sign_in() -> void:
	_busy = true
	_set_status(Status.CONNECTING)
	var r := await _obtain_tokens()
	if r.ok and (profile == null or not _profile_fresh):
		var me := await api.get_me()
		if me.ok:
			_set_profile(me.data)
		elif not me.is_transient():
			r = me
	_busy = false
	_conclude(r)


func _obtain_tokens() -> NetApiResult:
	_profile_fresh = false
	if not _has_account():
		var c := await api.create_device()
		if c.ok:
			c = _adopt(c, true)
		return c
	return await _renew()


## Rotate the refresh token; when the server rejects it, sign in with the device secret.
## Single flight: concurrent callers share one renewal (a refresh token is single use).
func _renew() -> NetApiResult:
	if _renewing:
		await _renew_done
		return _last_renew
	_renewing = true
	var r := NetApiResult.failure(0, ERR_NOT_SIGNED_IN)
	var rt := _refresh_token()
	var login := rt.is_empty()
	if not login:
		r = await api.refresh(rt)
		if r.ok:
			r = _adopt(r, false)
		elif _refresh_rejected(r):
			_doc.erase(K_REFRESH)
			_doc.erase(K_REFRESH_EXP)
			_persist()
			login = true
	if login and _has_account():
		r = await api.device_login(account_id(), _doc_str(K_SECRET))
		if r.ok:
			r = _adopt(r, false)
	_last_renew = r
	_renewing = false
	_renew_done.emit()
	return r


func _renew_in_background() -> void:
	var r := await _renew()
	if r.ok:
		_next_renew_usec = 0
	elif r.is_transient() and not _bearer().is_empty():
		# The token still works for a while: stay online and try again later.
		_next_renew_usec = time.now_usec() + roundi(tuning.session_retry_s * USEC_PER_S)
	else:
		_conclude(r)


## Takes the session fields of a device / login / refresh answer. A body without them is
## a BAD_RESPONSE.
func _adopt(r: NetApiResult, created: bool) -> NetApiResult:
	var id := r.str_field("account_id")
	var access := r.str_field("access_token")
	var refresh := r.str_field("refresh_token")
	var secret := r.str_field("device_secret")
	if id.is_empty() or access.is_empty() or refresh.is_empty() or (created and secret.is_empty()):
		return NetApiResult.failure(r.status, NetApiResult.BAD_RESPONSE, "session fields missing")
	if created or id != account_id():
		_doc = {}
		profile = null
	_doc[K_VERSION] = DOC_VERSION
	_doc[K_ACCOUNT] = id
	if created:
		_doc[K_SECRET] = secret
	_doc[K_REFRESH] = refresh
	_doc[K_REFRESH_EXP] = r.int_field("refresh_expires_at")
	_doc.erase(K_SIGNED_OUT)
	_access = access
	# At least twice the refresh margin, so a bad `expires_in` cannot loop the refresh.
	var ttl := maxf(float(r.int_field("expires_in")), tuning.session_refresh_margin_s * 2.0)
	_access_expires_usec = time.now_usec() + roundi(ttl * USEC_PER_S)
	if r.data.get("profile") is Dictionary:
		_set_profile(r.data["profile"] as Dictionary, false)
	_persist()
	return r


func _set_profile(d: Dictionary, persist: bool = true) -> void:
	var p := NetProfile.from_dict(d)
	if p == null:
		return
	profile = p
	_profile_fresh = true
	_doc[K_PROFILE] = p.to_dict()
	if persist:
		_persist()
	profile_changed.emit(profile)


## The end of a sign-in attempt.
func _conclude(r: NetApiResult) -> void:
	if r.ok:
		last_error = null
		_retry_delay_s = 0.0
		_retry_at_usec = -1
		banned_until = 0
		var was := status
		_set_status(Status.ONLINE)
		if was != Status.ONLINE:
			signed_in.emit(profile)
		return
	last_error = r
	if r.error != NetApiResult.BANNED:
		_access = ""
	if r.error == NetApiResult.BANNED:
		banned_until = r.banned_until
		_set_status(Status.BANNED)
		banned.emit(banned_until)
	elif r.is_transient():
		_set_status(Status.OFFLINE)
		_schedule_retry(r.retry_after_s)
	else:
		# The server refused the stored account (invalid_credentials, ...): surface it.
		_set_status(Status.FAILED)


## A failed call made while signed in (rename, delete): bans and dead sessions change
## the state; the other errors are the caller's to show.
func _note_failure(r: NetApiResult) -> void:
	if r.error == NetApiResult.BANNED:
		_conclude(r)


func _schedule_retry(hint_s: float) -> void:
	if _retry_delay_s <= 0.0:
		_retry_delay_s = tuning.session_retry_s
	else:
		_retry_delay_s = minf(tuning.session_retry_max_s, _retry_delay_s * 2.0)
	var d := maxf(_retry_delay_s, hint_s)
	_retry_at_usec = time.now_usec() + roundi(d * USEC_PER_S)


func _expiring() -> bool:
	return time.now_usec() >= _access_expires_usec - roundi(tuning.session_refresh_margin_s * USEC_PER_S)


## The server rejected the refresh token itself (not the network, a ban or a 429).
static func _refresh_rejected(r: NetApiResult) -> bool:
	return not r.ok and (r.status == NetApi.HTTP_UNAUTHORIZED or r.status == NetApi.HTTP_BAD_REQUEST)


func _has_account() -> bool:
	return not account_id().is_empty() and not _doc_str(K_SECRET).is_empty()


func _refresh_token() -> String:
	return _doc_str(K_REFRESH)


func _doc_str(key: String) -> String:
	var v: Variant = _doc.get(key, "")
	return v if v is String else ""


func _forget_local() -> void:
	store.clear()
	_doc = {}
	profile = null
	_profile_fresh = false
	_access = ""
	_access_expires_usec = 0
	_retry_at_usec = -1
	_retry_delay_s = 0.0
	last_error = null
	storage_ok = true


func _persist() -> void:
	storage_ok = store.save_data(_doc) and store.is_persistent()


func _set_status(s: Status) -> void:
	if s == status:
		return
	status = s
	status_changed.emit(s)


# ---------------------------------------------------------------- Config helpers

## The API base: the web page's `?server=`, else a `--server=` user argument (the dev
## setting: the editor's run arguments or the command line), else the tuning. `off`
## gives "" (online features off). A bare origin gets /api/v1.
static func resolve_base_url(t: NetTuning, bridge: NetJsBridge, args: PackedStringArray) -> String:
	var v := ""
	if bridge != null and bridge.available():
		v = bridge.query_param(SERVER_PARAM)
	if v.is_empty():
		for a in args:
			if a.begins_with(SERVER_ARG):
				v = a.substr(SERVER_ARG.length())
	if v.strip_edges().is_empty():
		return t.api_base_url
	return normalize_server(v, t.api_base_url)


static func normalize_server(value: String, fallback: String) -> String:
	var v := value.strip_edges()
	if SERVER_OFF.has(v.to_lower()):
		return ""
	if not (v.begins_with("http://") or v.begins_with("https://")):
		push_warning("NetSession: ignoring server '%s' (needs http:// or https://)" % v)
		return fallback
	v = v.trim_suffix("/")
	var rest := v.substr(v.find("//") + 2)
	if rest.find("/") < 0:
		v += API_PATH
	return v


## The stored document's name for a server: the default server has its own, any other
## one a name from its URL hash (credentials never cross servers).
static func store_name(api_base: String, t: NetTuning) -> String:
	if api_base == t.api_base_url:
		return STORE_DEFAULT
	return "%s_%s" % [STORE_DEFAULT, api_base.sha256_text().left(STORE_HASH_CHARS)]


## The platform's store: localStorage on the web, an encrypted user:// file elsewhere
## (MP-D2: the Keychain / Keystore plugins later).
static func platform_store(doc_name: String) -> NetSessionStore:
	if OS.has_feature("web"):
		return NetWebStore.new(NetJsBridge.new(), "" if doc_name == STORE_DEFAULT else doc_name)
	return NetFileStore.new(doc_name)


# ---------------------------------------------------------------- Player text

const TEXT := {
	"invalid_name": "Use 3–16 letters, digits, spaces, _ - or .",
	"name_not_allowed": "That name isn't allowed. Try another.",
	"name_unchanged": "That's already your name.",
	"name_unavailable": "That name is taken. Try another.",
	"rate_limited": "Too many tries. Wait a moment.",
	"network": "Can't reach the server. Check your connection.",
	"server_unavailable": "The server is having trouble. Try again soon.",
	"bad_response": "The server is having trouble. Try again soon.",
	"offline": "Online features are off in this build.",
	"not_signed_in": "Not signed in yet.",
	"invalid_credentials": "This device's account wasn't recognised.",
	"banned": "This account is suspended.",
	"unauthorized": "Your sign-in expired. Try again.",
	"token_expired": "Your sign-in expired. Try again.",
	"token_revoked": "Your sign-in expired. Try again.",
	"token_reused": "Your sign-in expired. Try again.",
	"invalid_token": "Your sign-in expired. Try again.",
}
## Player texts stay under about 50 characters (the panel's lines do not wrap).
const TEXT_FALLBACK := "Something went wrong. Try again."
const TEXT_COOLDOWN := "You can rename again in %d days."
const TEXT_COOLDOWN_ONE := "You can rename again tomorrow."
const TEXT_COOLDOWN_SOON := "You can rename again in a few hours."
const TEXT_BANNED_UNTIL := "This account is suspended until %s."
const TEXT_BANNED_FOREVER := "This account is suspended."
const S_PER_DAY := 86400.0


## What to tell the player about a failed call (rename, delete, sign-in).
static func error_text(r: NetApiResult, now_s: float) -> String:
	if r == null or r.ok:
		return ""
	match r.error:
		"rename_cooldown":
			return cooldown_text(r.next_rename_at, now_s)
		NetApiResult.BANNED:
			return banned_text(r.banned_until)
	return String(TEXT.get(r.error, TEXT_FALLBACK))


static func cooldown_text(next_rename_at: int, now_s: float) -> String:
	var days := ceili((float(next_rename_at) - now_s) / S_PER_DAY)
	if days > 1:
		return TEXT_COOLDOWN % days
	if float(next_rename_at) - now_s > S_PER_DAY * 0.5:
		return TEXT_COOLDOWN_ONE
	return TEXT_COOLDOWN_SOON


static func banned_text(until_unix: int) -> String:
	if until_unix <= 0 or until_unix >= NetApiResult.BANNED_FOREVER:
		return TEXT_BANNED_FOREVER
	var d := Time.get_datetime_dict_from_unix_time(until_unix)
	return TEXT_BANNED_UNTIL % ("%04d-%02d-%02d" % [d["year"], d["month"], d["day"]])
