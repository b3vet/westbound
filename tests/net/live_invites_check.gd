extends SceneTree
## Manual live check of room and crew invites against a running server (not part of the test
## tiers: no `test_` prefix). Throwaway device accounts over real WebSockets: A and B become
## friends, A and C share a crew (HTTP); A creates a private room and invites B (the invite
## reaches B with the room's code; B joins by it into A's room) and C (a crewmate who is no
## friend); a stranger D is refused with the server's reason; A invites B again (refused
## while it shows). Crew invites: A's friend E (online on the lobby) is invited to A's crew,
## gets `lobby_event.crew_invite` at once, lists it, accepts and is a member; B declines one;
## deleting E's account... is left to the server tests. Spec: multiplayer handoff → Rooms,
## parties and matchmaking (Private rooms, Friends and presence, Crews); the owner's requests.
## docs/ROOMS_CLIENT.md → Room invites → Live check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_invites_check.gd -- http://127.0.0.1:18652
##
## Refuses the production host. The last line is `LIVE_INVITES ok (0 failed)` or
## `LIVE_INVITES FAIL (n failed)`. Tokens are never printed.

const TIMEOUT_MS := 5000
const HTTP_POLL_MS := 10
const PRODUCTION := "westbound.sipsakrandevu.com"
const WAIT_S := 8.0
const MS_PER_S := 1000.0


class Player:
	extends RefCounted
	var label: String
	var account_id: String = ""
	var token: String = ""
	var full_name: String = ""
	var rs: NetRoomSession
	var room_invites: Array[String] = []
	var crew_invites: Array[Dictionary] = []
	var refusals: Array[String] = []

	func _init(name_: String) -> void:
		label = name_

	func start(t: NetTuning, url: String, l: float) -> void:
		rs = NetRoomSession.new(NetWsTransport.new(t), t, l)
		var tok := token
		rs.configure(url, t.client_build, MapInfo.loop_hash(), func() -> String: return tok)
		rs.room_invited.connect(func(inv: NetRoomInvites.Invite) -> void: room_invites.append(inv.code))
		rs.room_invite_failed.connect(func(_c: String, m: String) -> void: refusals.append(m))
		rs.client.frame_received.connect(func(f: NetServerFrame) -> void:
			for m: Dictionary in f.messages:
				if m.get("type") == "lobby_event" and m.get("kind") == "crew_invite":
					crew_invites.append(m))


var _api := ""
var _failed := 0
var _players: Array[Player] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args[0].contains(PRODUCTION):
		printerr("usage: live_invites_check.gd -- http://127.0.0.1:PORT   (never the production host)")
		quit(2)
		return
	_api = args[0].trim_suffix("/")
	_main.call_deferred()


func _process(_dt: float) -> bool:
	for p in _players:
		if p.rs != null:
			p.rs.poll()
	return false


func _row(step: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_failed += 1
	print("%-26s %s    %s" % [step, "ok" if ok else "FAIL", detail])


func _wait(cond: Callable, seconds: float = WAIT_S) -> bool:
	var until := Time.get_ticks_msec() + roundi(seconds * MS_PER_S)
	while Time.get_ticks_msec() < until:
		if cond.call():
			return true
		await process_frame
	return bool(cond.call())


func _befriend(a: Player, b: Player) -> bool:
	var req := _call(HTTPClient.METHOD_POST, "/api/v1/friends/requests", a.token, {"full_name": b.full_name})
	var rid := String((req.get("json", {}) as Dictionary).get("request_id", ""))
	var acc := _call(HTTPClient.METHOD_POST, "/api/v1/friends/requests/%s/accept" % rid, b.token, null)
	return req.get("code", 0) == 201 and acc.get("code", 0) == 200


func _main() -> void:
	await process_frame
	var t := NetTuning.load_default()
	var l := _loop_length()
	var ws := _api.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
	var a := Player.new("A")
	var b := Player.new("B")
	var c := Player.new("C")
	var d := Player.new("D")
	var e := Player.new("E")
	_players = [a, b, c, d, e]
	for p in _players:
		var r := _call(HTTPClient.METHOD_POST, "/api/v1/auth/device", "", null)
		if r.get("code", 0) == 201:
			var body: Dictionary = r["json"]
			p.account_id = String(body.get("account_id", ""))
			p.token = String(body.get("access_token", ""))
			var me := _call(HTTPClient.METHOD_GET, "/api/v1/me", p.token, null)
			p.full_name = String((me.get("json", {}) as Dictionary).get("full_name", ""))
	_row("accounts", _players.all(func(p: Player) -> bool: return not p.token.is_empty() and not p.full_name.is_empty()),
		", ".join(_players.map(func(p: Player) -> String: return "%s %s" % [p.label, p.account_id])))
	if _failed > 0:
		_finish()
		return
	_row("friends", _befriend(a, b) and _befriend(a, e), "%s + %s, %s" % [a.full_name, b.full_name, e.full_name])
	var tag := "L%d" % (int(a.account_id) % 1000)
	var crew := _call(HTTPClient.METHOD_POST, "/api/v1/crews", a.token, {"name": "Live Crew %s" % a.account_id, "tag": tag})
	var cj: Dictionary = crew.get("json", {})
	var crew_id := String(cj.get("crew_id", ""))
	var joined := _call(HTTPClient.METHOD_POST, "/api/v1/crews/join", c.token, {"invite_code": String(cj.get("invite_code", ""))})
	_row("crew", crew.get("code", 0) == 201 and joined.get("code", 0) == 200, "%s [%s]: A owner, C member" % [cj.get("name", "?"), tag])
	for p in _players:
		p.start(t, ws, l)
		p.rs.connect_lobby()
	_row("lobby connections", await _wait(func() -> bool:
		return _players.all(func(p: Player) -> bool: return p.rs.client.is_ready())), "5 sockets, protocol %d" % NetCodec.PROTOCOL_VERSION)

	# Room invites: A's private room.
	a.rs.create_room("normal", "cycle")
	_row("A creates a room", await _wait(func() -> bool: return a.rs.is_in_room()),
		"room %d code %s (%s)" % [a.rs.room.room_id, a.rs.room.code, a.rs.room.visibility])
	a.rs.room_invite(b.account_id)
	_row("invite reaches B", await _wait(func() -> bool: return not b.room_invites.is_empty()),
		"from %s, code %s" % [b.rs.room_invites.newest().from_name if b.rs.room_invites.newest() != null else "?",
			b.room_invites[0] if not b.room_invites.is_empty() else "?"])
	if b.room_invites.is_empty():
		_finish()
		return
	b.rs.accept_room_invite(b.room_invites[0])
	_row("B joins by its code", await _wait(func() -> bool:
		return b.rs.is_in_room() and b.rs.room.room_id == a.rs.room.room_id),
		"room %d, %s" % [b.rs.room.room_id, b.rs.room.players_text()])
	a.rs.room_invite(c.account_id)
	_row("crewmate C invited", await _wait(func() -> bool: return not c.room_invites.is_empty()),
		"%s (no friend, same crew)" % c.full_name)
	a.rs.room_invite(d.account_id)
	_row("stranger refused", await _wait(func() -> bool: return not a.refusals.is_empty()),
		a.refusals[0] if not a.refusals.is_empty() else "")
	a.rs.room_invite(c.account_id)
	_row("repeat refused", await _wait(func() -> bool: return a.refusals.size() >= 2),
		a.refusals[1] if a.refusals.size() >= 2 else "")
	a.rs.room_invite(b.account_id)
	_row("already here refused", await _wait(func() -> bool: return a.refusals.size() >= 3),
		a.refusals[2] if a.refusals.size() >= 3 else "")

	# Crew invites: A invites E (online): the live event, then E's list and JOIN.
	var inv := _call(HTTPClient.METHOD_POST, "/api/v1/crews/%s/invites" % crew_id, a.token, {"account_id": e.account_id})
	_row("crew invite sent", inv.get("code", 0) == 201, "invite %s" % (inv.get("json", {}) as Dictionary).get("invite_id", "?"))
	_row("E hears at once", await _wait(func() -> bool: return not e.crew_invites.is_empty()),
		"lobby_event.crew_invite %s [%s] from %s" % [
			e.crew_invites[0].get("crew_name", "?") if not e.crew_invites.is_empty() else "?",
			e.crew_invites[0].get("crew_tag", "?") if not e.crew_invites.is_empty() else "?",
			(e.crew_invites[0].get("from", {}) as Dictionary).get("display_name", "?") if not e.crew_invites.is_empty() else "?"])
	var list := _call(HTTPClient.METHOD_GET, "/api/v1/crews/invites", e.token, null)
	var invites: Array = (list.get("json", {}) as Dictionary).get("invites", [])
	_row("E's list", invites.size() == 1, "%d waiting" % invites.size())
	var refused := _call(HTTPClient.METHOD_POST, "/api/v1/crews/%s/invites" % crew_id, a.token, {"account_id": d.account_id})
	_row("not a friend refused", refused.get("code", 0) == 403,
		String((refused.get("json", {}) as Dictionary).get("error", "")))
	if invites.size() == 1:
		var id := String((invites[0] as Dictionary).get("invite_id", ""))
		var ok := _call(HTTPClient.METHOD_POST, "/api/v1/crews/invites/%s/accept" % id, e.token, null)
		var oj: Dictionary = ok.get("json", {})
		_row("E accepts", ok.get("code", 0) == 200 and oj.get("your_role", "") == "member",
			"%d/%d members" % [int(oj.get("member_count", 0)), int(oj.get("max_members", 0))])
	var mine := _call(HTTPClient.METHOD_GET, "/api/v1/crews/mine", a.token, null)
	var online := 0
	for m: Variant in (mine.get("json", {}) as Dictionary).get("members", []):
		if m is Dictionary and String((m as Dictionary).get("status", "offline")) != "offline":
			online += 1
	_row("crew presence", online == 3, "%d of 3 members online for A" % online)
	# B declines a crew invite.
	var inv_b := _call(HTTPClient.METHOD_POST, "/api/v1/crews/%s/invites" % crew_id, a.token, {"account_id": b.account_id})
	var bid := String((inv_b.get("json", {}) as Dictionary).get("invite_id", ""))
	var dec := _call(HTTPClient.METHOD_POST, "/api/v1/crews/invites/%s/decline" % bid, b.token, null)
	_row("B declines", dec.get("code", 0) == 204, "")
	for p in _players:
		_call(HTTPClient.METHOD_DELETE, "/api/v1/account", p.token, null)
	_finish()


func _finish() -> void:
	for p in _players:
		if p.rs != null:
			p.rs.close()
	print("LIVE_INVITES %s (%d failed)" % ["ok" if _failed == 0 else "FAIL", _failed])
	quit(0 if _failed == 0 else 1)


## One HTTP request: {code, json (Dictionary or {}), text}.
func _call(method: int, path: String, token: String, body: Variant) -> Dictionary:
	var https := _api.begins_with("https://")
	var hostport := _api.trim_prefix("https://").trim_prefix("http://")
	var host := hostport.get_slice(":", 0)
	var port := int(hostport.get_slice(":", 1)) if hostport.contains(":") else -1
	var http := HTTPClient.new()
	if http.connect_to_host(host, port, TLSOptions.client() if https else null) != OK:
		return {}
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while http.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	var text := "" if body == null else JSON.stringify(body)
	var headers := PackedStringArray(["Content-Length: %d" % text.to_utf8_buffer().size()])
	if not text.is_empty():
		headers.append("Content-Type: application/json")
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
	if http.request(method, path, headers, text) != OK:
		return {}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	if not http.has_response():
		return {}
	var out := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		out.append_array(http.read_response_body_chunk())
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			break
	var s := out.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(s) if s.begins_with("{") or s.begins_with("[") else null
	return {"code": http.get_response_code(), "json": parsed if parsed is Dictionary else {}, "text": s}


## The loop's length from the committed road-space file (no autoloads in a --script run).
static func _loop_length() -> float:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(MapInfo.LOOP_V1_PATH))
	return float((d as Dictionary).get("length_mm", 0)) / MS_PER_S if d is Dictionary else 0.0
