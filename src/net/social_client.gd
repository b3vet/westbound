class_name NetSocialClient
extends RefCounted
## The Social API client: friends, requests, blocks, presence, crews, the crew's Loop
## season standing and reports, over NetApi. Spec: multiplayer handoff → Rooms, parties
## and matchmaking (Friends and presence, Crews (persistent)), Moderation → Report,
## Client changes (`lobby.gd`: presence); docs/SERVER.md → Social API; docs/PROTOCOL.md
## §4 (`lobby_command.presence_subscribe`, `lobby_event.presence`). WP N9.2;
## docs/NET_CLIENT.md → Social client.
##
##   var social := NetSocialClient.of(NetSession.current)   # one per session
##   social.friends_changed.connect(redraw)
##   var r: NetApiResult = await social.send_request("LoneWolf#0007")
##   if not r.ok: show(NetSocialClient.error_text(r))
##
## Every call is a coroutine returning a NetApiResult; failures are values, never errors,
## and nothing here blocks the game. Offline (no server, not signed in) calls return at
## once with `offline` / `not_signed_in`. State is cached here (`friends`, `incoming`,
## `outgoing`, `blocks`, `crew`, the standing) and the signals say what changed.
##
## Presence has two sources, merged the same way (later entries replace earlier ones):
##   - WebSocket: attach_lobby(client) subscribes (`presence_subscribe {enabled: true}`)
##     whenever that NetClient is READY (again after each Welcome) and applies every
##     `lobby_event.presence`. N5's always-on lobby connection plugs in here; until then
##     only a room's connection could.
##   - Polling: while a screen watches (watch(true)) and no subscribed WebSocket is live,
##     poll() calls GET /presence every `social_presence_poll_s`. A lost socket falls
##     back to polling at once.
## A presence entry for someone not on the list (a request just accepted) refreshes the
## list on the next poll().

signal friends_changed()
## One friend's presence changed (the list may also have been re-sorted).
signal presence_changed(account_id: String)
signal blocks_changed()
signal crew_changed()
signal standing_changed()
signal _refreshed()

const PATH_FRIENDS := "/friends"
const PATH_REQUESTS := "/friends/requests"
const PATH_PRESENCE := "/presence"
const PATH_BLOCKS := "/blocks"
const PATH_CREWS := "/crews"
const PATH_CREW_MINE := "/crews/mine"
const PATH_CREW_JOIN := "/crews/join"
const PATH_REPORTS := "/reports"
const PATH_CREW_BOARD := "/boards/loop_crew"
const CREW_BOARD_QUERY := "?view=around_me&limit=%d"

## POST /reports `reason` values (docs/SERVER.md → Reports), in the dialog's order.
const REPORT_REASONS: Array[String] = ["cheating", "offensive_name", "offensive_crew",
		"harassment", "griefing", "other"]

## Client-side codes (NetApiResult.error) besides NetApiResult's and the server's.
const ERR_BUSY := "busy"
const ERR_NO_CREW := "not_in_crew"
const ERR_FRIEND_CODE := "invalid_full_name"
const ERR_CREW_NAME := "invalid_crew_name"
const ERR_CREW_TAG := "invalid_crew_tag"
const ERR_INVITE := "invalid_invite_code"
const ERR_REASON := "invalid_reason"
## The gateway's non-fatal answer when it cannot subscribe (docs/SERVER.md → Presence).
const WS_INTERNAL := "internal"

const USEC_PER_S := 1000000.0
const TAG_DIGITS_MAX := 4

## N5's Join seam: `func(friend: NetSocialPlayer) -> void`. The friends screen shows JOIN
## for a friend in a room with space, enabled only while this is set.
static var join_handler: Callable
static var _shared: NetSocialClient

var api: NetApi
var tuning: NetTuning
var time: NetTimeSource
## The session this client follows (null in tests that drive NetApi directly).
var session: NetSession

## Accepted friends: in a room first, then online, then offline, by name within each.
var friends: Array[NetSocialPlayer] = []
## Requests waiting for you / yours waiting for them, newest first.
var incoming: Array[NetSocialPlayer] = []
var outgoing: Array[NetSocialPlayer] = []
var blocks: Array[NetSocialPlayer] = []
var max_friends: int = 0
var max_blocks: int = 0
var friends_loaded: bool = false
var blocks_loaded: bool = false
## null without a crew (or before crew_loaded).
var crew: NetCrew
var crew_loaded: bool = false
## The crew's Loop crew season entry: rank 0 = not on the board yet.
var standing_rank: int = 0
var standing_score: int = 0
var standing_period: String = ""
var standing_loaded: bool = false
## A screen shows the friends list (presence polling on).
var watching: bool = false
## Stats (tests, dev HUD).
var presence_polls: int = 0
var ws_presence_events: int = 0

var _lobby: NetClient
var _ws_subscribed: bool = false
var _next_poll_usec: int = -1
var _refreshing: bool = false
var _refresh_again: bool = false
var _last_refresh: NetApiResult
var _stale: bool = false
var _polling: bool = false
var _report_wait_until_usec: int = 0
var _account: String = ""


func _init(net_api: NetApi, net_tuning: NetTuning, clock: NetTimeSource = null) -> void:
	api = net_api
	tuning = net_tuning if net_tuning != null else NetTuning.load_default()
	time = clock if clock != null else NetTimeSource.new()


## The shared client of `s` (made on first use; a new session gets a new one). Null when
## there is no session.
static func of(s: NetSession) -> NetSocialClient:
	if s == null or not is_instance_valid(s) or s.api == null:
		return null
	if _shared == null or _shared.session != s or _shared.api != s.api:
		if _shared != null:
			_shared.detach_lobby()
		_shared = NetSocialClient.new(s.api, s.tuning, s.time)
		_shared.session = s
	return _shared


# ---------------------------------------------------------------- Friends

## GET /friends: friends (with presence), incoming and outgoing requests. Concurrent
## callers share one request; a call made during a refresh runs it once more.
func refresh_friends() -> NetApiResult:
	if _refreshing:
		_refresh_again = true
		await _refreshed
		return _last_refresh
	_refreshing = true
	var r: NetApiResult
	while true:
		_refresh_again = false
		r = await _call(HTTPClient.METHOD_GET, PATH_FRIENDS)
		if r.ok:
			_read_friends(r.data)
		if not _refresh_again:
			break
	_refreshing = false
	_last_refresh = r
	_refreshed.emit()
	return r


## POST /friends/requests {full_name}. `pending`, or `accepted` when they had asked you.
## A malformed code fails here (invalid_full_name) without a request.
func send_request(code: String) -> NetApiResult:
	var c := code.strip_edges()
	if not valid_friend_code(c, tuning):
		return NetApiResult.failure(0, ERR_FRIEND_CODE)
	var r := await _call(HTTPClient.METHOD_POST, PATH_REQUESTS, {"full_name": c})
	if r.ok:
		await refresh_friends()
	return r


## POST /friends/requests/{id}/accept.
func accept(request_id: String) -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_POST, "%s/%s/accept" % [PATH_REQUESTS, request_id.uri_encode()])
	if r.ok:
		await refresh_friends()
	return r


## POST /friends/requests/{id}/decline: the recipient declines, the requester cancels.
func decline(request_id: String) -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_POST, "%s/%s/decline" % [PATH_REQUESTS, request_id.uri_encode()])
	if r.ok and (_drop_request(incoming, request_id) or _drop_request(outgoing, request_id)):
		friends_changed.emit()
	return r


## Cancels your own pending request (the same route as decline).
func cancel_request(request_id: String) -> NetApiResult:
	return await decline(request_id)


## DELETE /friends/{account_id}: removes a friend (or a pending request either way).
func remove_friend(account_id: String) -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_DELETE, "%s/%s" % [PATH_FRIENDS, account_id.uri_encode()])
	if r.ok and _drop_player(account_id):
		friends_changed.emit()
	return r


func friend(account_id: String) -> NetSocialPlayer:
	return _find(friends, account_id)


func online_count() -> int:
	var n := 0
	for f in friends:
		if f.is_online():
			n += 1
	return n


# ---------------------------------------------------------------- Blocks

## GET /blocks.
func refresh_blocks() -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_GET, PATH_BLOCKS)
	if r.ok:
		blocks = _players(r.data.get("blocks"))
		max_blocks = r.int_field("max_blocks")
		blocks_loaded = true
		blocks_changed.emit()
	return r


## POST /blocks {account_id}: also ends the friendship or request with them.
func block(account_id: String) -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_POST, PATH_BLOCKS, {"account_id": account_id})
	if r.ok:
		if _drop_player(account_id):
			friends_changed.emit()
		await refresh_blocks()
	return r


## DELETE /blocks/{account_id}.
func unblock(account_id: String) -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_DELETE, "%s/%s" % [PATH_BLOCKS, account_id.uri_encode()])
	if r.ok or r.error == "block_not_found":
		var i := _index(blocks, account_id)
		if i >= 0:
			blocks.remove_at(i)
			blocks_changed.emit()
	return r


# ---------------------------------------------------------------- Presence

## A screen shows presence: poll while no WebSocket subscription is live.
func watch(on: bool) -> void:
	if on == watching:
		return
	watching = on
	_next_poll_usec = time.now_usec() + _poll_usec() if on else -1


## Time-driven work while watching: the presence poll and list refreshes after an
## unknown friend's presence. Call every frame (cheap when idle).
func poll() -> void:
	if not watching:
		return
	if _stale and not _refreshing:
		_stale = false
		refresh_friends()
	if ws_live() or _polling:
		return
	var now := time.now_usec()
	if _next_poll_usec >= 0 and now < _next_poll_usec:
		return
	_next_poll_usec = now + _poll_usec()
	_poll_presence()


func _poll_presence() -> void:
	_polling = true
	var r := await refresh_presence()
	_polling = false
	if not r.ok and r.error == NetApiResult.RATE_LIMITED:
		_next_poll_usec = maxi(_next_poll_usec, time.now_usec() + roundi(r.retry_after_s * USEC_PER_S))


## GET /presence: every friend's status.
func refresh_presence() -> NetApiResult:
	presence_polls += 1
	var r := await _call(HTTPClient.METHOD_GET, PATH_PRESENCE)
	if r.ok and r.data.get("friends") is Array:
		apply_presence(r.data["friends"] as Array)
	return r


## Merges presence entries ({account_id, status, room_id, joinable}) from either source.
func apply_presence(entries: Array) -> void:
	var any := false
	for e: Variant in entries:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		var id := NetApiResult.as_id(d.get("account_id"))
		var p := friend(id)
		if p == null:
			if String(d.get("status", "")) != NetSocialPlayer.OFFLINE:
				_stale = true
			continue
		if p.set_presence(d.get("status"), d.get("room_id"), d.get("joinable")):
			any = true
			presence_changed.emit(id)
	if any:
		_sort_friends()
		friends_changed.emit()


## Follows presence on a lobby connection (N5's always-on one, or a room's). Subscribes
## whenever it is READY; polling pauses while the subscription is live.
func attach_lobby(client: NetClient) -> void:
	if client == _lobby:
		return
	detach_lobby()
	_lobby = client
	if client == null:
		return
	client.welcomed.connect(_on_lobby_welcome)
	client.frame_received.connect(_on_lobby_frame)
	client.state_changed.connect(_on_lobby_state)
	client.server_error.connect(_on_lobby_error)
	if client.is_ready():
		_subscribe(true)


## Stops following the lobby connection (unsubscribes when it is still up).
func detach_lobby() -> void:
	if _lobby == null:
		return
	if _lobby.is_ready() and _ws_subscribed:
		_subscribe(false)
	for pair: Array in [[_lobby.welcomed, _on_lobby_welcome], [_lobby.frame_received, _on_lobby_frame],
			[_lobby.state_changed, _on_lobby_state], [_lobby.server_error, _on_lobby_error]]:
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if sig.is_connected(fn):
			sig.disconnect(fn)
	_lobby = null
	_ws_subscribed = false


## Presence arrives over a live WebSocket subscription (no polling needed).
func ws_live() -> bool:
	return _lobby != null and _ws_subscribed and _lobby.is_ready()


func _subscribe(on: bool) -> void:
	var err := _lobby.send_messages([{"type": "lobby_command", "kind": "presence_subscribe", "enabled": on}])
	_ws_subscribed = on and err.is_empty()


func _on_lobby_welcome(_w: Dictionary) -> void:
	_subscribe(true)


func _on_lobby_state(s: NetClient.State) -> void:
	if s != NetClient.State.READY and _ws_subscribed:
		_ws_subscribed = false
		_next_poll_usec = time.now_usec()


func _on_lobby_error(code: String, fatal: bool, _detail: String) -> void:
	if code == WS_INTERNAL and not fatal and _ws_subscribed:
		# "Friends presence is unavailable": poll until the next Welcome.
		_ws_subscribed = false
		_next_poll_usec = time.now_usec()


func _on_lobby_frame(frame: NetServerFrame) -> void:
	for msg: Dictionary in frame.messages:
		if msg.get("type") == "lobby_event" and msg.get("kind") == "presence" and msg.get("friends") is Array:
			ws_presence_events += 1
			apply_presence(msg["friends"] as Array)


# ---------------------------------------------------------------- Crews

## GET /crews/mine (`not_in_crew` is a normal answer: no crew).
func refresh_crew() -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_GET, PATH_CREW_MINE)
	if r.ok:
		_set_crew(NetCrew.from_dict(r.data))
	elif r.error == ERR_NO_CREW:
		_set_crew(null)
	return r


## GET /crews/{id}: any crew (no invite code unless you are a member). Not cached.
func get_crew(crew_id: String) -> NetApiResult:
	return await _call(HTTPClient.METHOD_GET, "%s/%s" % [PATH_CREWS, crew_id.uri_encode()])


## POST /crews {name, tag}: you become its owner. Obviously bad lengths fail here.
func create_crew(crew_name: String, crew_tag: String) -> NetApiResult:
	var n := crew_name.strip_edges()
	var t := crew_tag.strip_edges().to_upper()
	if n.length() < tuning.crew_name_min_chars or n.length() > tuning.crew_name_max_chars:
		return NetApiResult.failure(0, ERR_CREW_NAME)
	if t.length() < tuning.crew_tag_min_chars or t.length() > tuning.crew_tag_max_chars:
		return NetApiResult.failure(0, ERR_CREW_TAG)
	var r := await _call(HTTPClient.METHOD_POST, PATH_CREWS, {"name": n, "tag": t})
	if r.ok:
		_set_crew(NetCrew.from_dict(r.data))
	return r


## POST /crews/join {invite_code} (spaces and dashes dropped, upper case).
func join_crew(code: String) -> NetApiResult:
	var c := normalize_code(code)
	if c.length() < tuning.crew_code_min_chars or c.length() > tuning.crew_code_max_chars:
		return NetApiResult.failure(0, ERR_INVITE)
	var r := await _call(HTTPClient.METHOD_POST, PATH_CREW_JOIN, {"invite_code": c})
	if r.ok:
		_set_crew(NetCrew.from_dict(r.data))
	return r


## POST /crews/{id}/leave. An owner leaving hands the crew on (or disbands it when empty).
func leave_crew() -> NetApiResult:
	var r := await _crew_call(HTTPClient.METHOD_POST, "/leave")
	if r.ok or r.error == ERR_NO_CREW:
		_set_crew(null)
	return r


func kick(account_id: String) -> NetApiResult:
	return await _member_call("/kick", account_id)


func promote(account_id: String) -> NetApiResult:
	return await _member_call("/promote", account_id)


func demote(account_id: String) -> NetApiResult:
	return await _member_call("/demote", account_id)


## Makes them the owner (you become an officer).
func transfer(account_id: String) -> NetApiResult:
	return await _member_call("/transfer", account_id)


## POST /crews/{id}/invite-code: a new code; the old one stops working.
func rotate_invite_code() -> NetApiResult:
	var r := await _crew_call(HTTPClient.METHOD_POST, "/invite-code")
	if r.ok:
		_set_crew(NetCrew.from_dict(r.data))
	return r


## DELETE /crews/{id}.
func disband() -> NetApiResult:
	var r := await _crew_call(HTTPClient.METHOD_DELETE, "")
	if r.ok or r.error == ERR_NO_CREW:
		_set_crew(null)
	return r


func _member_call(action: String, account_id: String) -> NetApiResult:
	var r := await _crew_call(HTTPClient.METHOD_POST, action, {"account_id": account_id})
	if r.ok:
		_set_crew(NetCrew.from_dict(r.data))
	elif r.error == ERR_NO_CREW:
		_set_crew(null)
	return r


func _crew_call(method: int, suffix: String, body: Variant = null) -> NetApiResult:
	if crew == null:
		return NetApiResult.failure(0, ERR_NO_CREW)
	return await _call(method, "%s/%s%s" % [PATH_CREWS, crew.crew_id.uri_encode(), suffix], body)


func _set_crew(c: NetCrew) -> void:
	var was := crew.crew_id if crew != null else ""
	crew = c
	crew_loaded = true
	if c == null or c.crew_id != was:
		standing_rank = 0
		standing_score = 0
		standing_loaded = false
	crew_changed.emit()


## GET /boards/loop_crew?view=around_me: the crew's current-season Loop crew entry.
func refresh_standing() -> NetApiResult:
	var r := await _call(HTTPClient.METHOD_GET, PATH_CREW_BOARD + CREW_BOARD_QUERY % maxi(tuning.crew_board_around, 1))
	if r.ok:
		var me: Variant = r.data.get("me")
		standing_period = r.str_field("period")
		standing_rank = 0
		standing_score = 0
		if me is Dictionary:
			standing_rank = NetSocialPlayer._int((me as Dictionary).get("rank"))
			standing_score = NetSocialPlayer._int((me as Dictionary).get("score"))
		standing_loaded = true
		standing_changed.emit()
	return r


# ---------------------------------------------------------------- Reports

## POST /reports {target_account_id, reason, context}. `context` (optional) says where the
## report came from ({"source": "friends"}, a board entry, a room). A 429 is remembered:
## report_wait_s() counts it down.
func report(target_account_id: String, reason: String, context: Dictionary = {}) -> NetApiResult:
	if not REPORT_REASONS.has(reason):
		return NetApiResult.failure(0, ERR_REASON)
	var body := {"target_account_id": target_account_id, "reason": reason}
	if not context.is_empty():
		body["context"] = context
	var r := await _call(HTTPClient.METHOD_POST, PATH_REPORTS, body)
	if not r.ok and r.error == NetApiResult.RATE_LIMITED:
		_report_wait_until_usec = time.now_usec() + roundi(r.retry_after_s * USEC_PER_S)
	return r


## Seconds until another report may go out (0: now), after a rate-limited one.
func report_wait_s() -> float:
	return maxf(0.0, float(_report_wait_until_usec - time.now_usec()) / USEC_PER_S)


# ---------------------------------------------------------------- Core

## The signed-in account ("" without a session).
func my_account_id() -> String:
	if session != null and is_instance_valid(session):
		return session.account_id()
	return _account


## Online features are reachable: a server and a signed-in session.
func available() -> bool:
	if api == null or api.base_url.is_empty():
		return false
	if session != null and is_instance_valid(session):
		return session.is_online()
	return true


func _call(method: int, path: String, body: Variant = null) -> NetApiResult:
	if api == null or api.base_url.is_empty():
		return NetApiResult.failure(0, NetApiResult.OFFLINE)
	if session != null and is_instance_valid(session):
		if not session.is_online():
			return NetApiResult.failure(0, NetSession.ERR_NOT_SIGNED_IN)
		_follow_account(session.account_id())
	var r := await api.request(method, path, body, NetApi.AUTH)
	if not r.ok and r.error == NetApiResult.BANNED and session != null and is_instance_valid(session):
		session.retry()
	return r


## A different account signed in on this session: forget the old one's lists.
func _follow_account(id: String) -> void:
	if id == _account:
		return
	var had := not _account.is_empty()
	_account = id
	if not had:
		return
	friends.clear()
	incoming.clear()
	outgoing.clear()
	blocks.clear()
	friends_loaded = false
	blocks_loaded = false
	crew = null
	crew_loaded = false
	standing_loaded = false
	friends_changed.emit()
	blocks_changed.emit()
	crew_changed.emit()


func _read_friends(d: Dictionary) -> void:
	friends = _players(d.get("friends"))
	incoming = _players(d.get("incoming"))
	outgoing = _players(d.get("outgoing"))
	max_friends = NetSocialPlayer._int(d.get("max_friends"))
	friends_loaded = true
	_sort_friends()
	friends_changed.emit()


func _sort_friends() -> void:
	friends.sort_custom(_friend_before)


static func _friend_before(a: NetSocialPlayer, b: NetSocialPlayer) -> bool:
	var ra := a.presence_rank()
	var rb := b.presence_rank()
	if ra != rb:
		return ra < rb
	var na := a.display_name.to_lower()
	var nb := b.display_name.to_lower()
	if na != nb:
		return na < nb
	return a.tag < b.tag


static func _players(v: Variant) -> Array[NetSocialPlayer]:
	var out: Array[NetSocialPlayer] = []
	if v is Array:
		for e: Variant in v as Array:
			var p := NetSocialPlayer.from_dict(e)
			if p != null:
				out.append(p)
	return out


static func _find(list: Array[NetSocialPlayer], account_id: String) -> NetSocialPlayer:
	var i := _index(list, account_id)
	return list[i] if i >= 0 else null


static func _index(list: Array[NetSocialPlayer], account_id: String) -> int:
	for i in list.size():
		if list[i].account_id == account_id:
			return i
	return -1


static func _drop_request(list: Array[NetSocialPlayer], request_id: String) -> bool:
	for i in list.size():
		if list[i].request_id == request_id:
			list.remove_at(i)
			return true
	return false


## Removes `account_id` from the friends and both request lists.
func _drop_player(account_id: String) -> bool:
	var any := false
	for list: Array[NetSocialPlayer] in [friends, incoming, outgoing]:
		var i := _index(list, account_id)
		if i >= 0:
			list.remove_at(i)
			any = true
	return any


func _poll_usec() -> int:
	return roundi(maxf(tuning.social_presence_poll_s, 1.0) * USEC_PER_S)


# ---------------------------------------------------------------- Validation

## `name#1234`: a name, `#`, 1–4 digits (the server's parse_full_name).
static func valid_friend_code(code: String, t: NetTuning) -> bool:
	var c := code.strip_edges()
	var hash_at := c.rfind("#")
	if hash_at <= 0 or c.length() > t.friend_code_max_chars:
		return false
	var digits := c.substr(hash_at + 1)
	if digits.is_empty() or digits.length() > TAG_DIGITS_MAX or not digits.is_valid_int():
		return false
	for ch in digits:
		if ch < "0" or ch > "9":
			return false
	return not c.left(hash_at).strip_edges().is_empty()


## An invite code as typed: spaces and dashes dropped, upper case.
static func normalize_code(code: String) -> String:
	return code.strip_edges().replace(" ", "").replace("-", "").to_upper()


# ---------------------------------------------------------------- Player text

## Player texts for the social errors (under about 50 characters: screen text does not
## wrap). `player_not_found` is the same whether the name is unknown or a block stands
## in either direction (the server does not reveal blocks).
const TEXT := {
	"player_not_found": "No player with that code.",
	"invalid_full_name": "Enter a friend code like Name#1234.",
	"cannot_friend_self": "That's your own code.",
	"already_friends": "You're already friends.",
	"request_exists": "You already sent them a request.",
	"friends_limit": "Your friends list is full.",
	"target_friends_limit": "Their friends list is full.",
	"requests_limit": "Too many requests waiting. Cancel some.",
	"target_requests_limit": "They have too many requests waiting.",
	"request_not_found": "That request is no longer there.",
	"friend_not_found": "They're no longer on your list.",
	"cannot_block_self": "You can't block yourself.",
	"blocks_limit": "Your block list is full.",
	"block_not_found": "They're no longer blocked.",
	"invalid_crew_name": "Crew names: 3–24 letters, digits or spaces.",
	"crew_name_not_allowed": "That crew name isn't allowed.",
	"invalid_crew_tag": "Tags: 2–4 letters or digits.",
	"crew_tag_not_allowed": "That tag isn't allowed.",
	"crew_name_taken": "That crew name is taken.",
	"crew_tag_taken": "That tag is taken.",
	"already_in_crew": "You're already in a crew.",
	"not_in_crew": "You're not in a crew.",
	"crew_not_found": "That crew no longer exists.",
	"invalid_invite_code": "That invite code doesn't work.",
	"crew_full": "That crew is full.",
	"cannot_kick_self": "You can't kick yourself.",
	"not_permitted": "Your role can't do that.",
	"member_not_found": "They're no longer in the crew.",
	"cannot_change_own_role": "You can't change your own role.",
	"cannot_transfer_to_self": "You already own the crew.",
	"invalid_reason": "Pick a reason.",
	"invalid_context": "Something went wrong. Try again.",
	"cannot_report_self": "You can't report yourself.",
	"busy": "One moment...",
}
const TEXT_RATE := "Too many tries. Try again in %s."
const TEXT_REPORT_RATE := "Report limit reached. Try again in %s."
const WAIT_SECONDS := "a moment"
const WAIT_MINUTES := "%d min"
const WAIT_HOURS := "%d h"
const S_PER_MIN := 60.0
const S_PER_HOUR := 3600.0


## What to tell the player about a failed social call (falls back to the session texts).
static func error_text(r: NetApiResult, reporting: bool = false) -> String:
	if r == null or r.ok:
		return ""
	if r.error == NetApiResult.RATE_LIMITED:
		return (TEXT_REPORT_RATE if reporting else TEXT_RATE) % wait_text(r.retry_after_s)
	if TEXT.has(r.error):
		return String(TEXT[r.error])
	return NetSession.error_text(r, Time.get_unix_time_from_system())


## "a moment", "5 min", "3 h" (rounded up).
static func wait_text(seconds: float) -> String:
	if seconds < S_PER_MIN:
		return WAIT_SECONDS
	if seconds < S_PER_HOUR:
		return WAIT_MINUTES % ceili(seconds / S_PER_MIN)
	return WAIT_HOURS % ceili(seconds / S_PER_HOUR)
