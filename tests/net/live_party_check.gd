extends SceneTree
## Manual live check of parties against a running server (not part of the test tiers: no
## `test_` prefix). Throwaway device accounts over real WebSockets: A and B become friends
## (HTTP), A invites B (the invite reaches B, B accepts with its code), C joins by the party
## code and the server's invite page for it answers; A (the leader) Quick Joins and B and C
## follow into the same public room as one crew; a solo player D Quick Joins the fullest
## room that fits and gets a crew of their own; presence rides on the room socket. Spec:
## multiplayer handoff → Rooms, parties and matchmaking (Parties, Quick Join, Crew
## mechanics: "in a public room, the party you joined with"). WP N9.3; docs/ROOMS_CLIENT.md
## → Parties → Live check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_party_check.gd -- http://127.0.0.1:18652
##
## Refuses the production host. The last line is `LIVE_PARTY ok (0 failed)` or
## `LIVE_PARTY FAIL (n failed)`. Tokens are never printed.

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
	var invites: Array[String] = []

	func _init(name_: String) -> void:
		label = name_

	func start(t: NetTuning, url: String, l: float) -> void:
		rs = NetRoomSession.new(NetWsTransport.new(t), t, l)
		var tok := token
		rs.configure(url, t.client_build, MapInfo.loop_hash(), func() -> String: return tok)
		rs.accept_follows = true   # as while the hub shows
		rs.party_invited.connect(func(inv: NetParty.Invite) -> void: invites.append(inv.code))

	func crew() -> int:
		var m := rs.room.me()
		return m.crew_slot if m != null else -1


var _api := ""
var _failed := 0
var _players: Array[Player] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args[0].contains(PRODUCTION):
		printerr("usage: live_party_check.gd -- http://127.0.0.1:PORT   (never the production host)")
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


func _main() -> void:
	await process_frame
	var t := NetTuning.load_default()
	var l := _loop_length()
	var ws := _api.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
	var a := Player.new("A")
	var b := Player.new("B")
	var c := Player.new("C")
	var d := Player.new("D")
	_players = [a, b, c, d]
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
	# A and B become friends (the invite is for online friends).
	var req := _call(HTTPClient.METHOD_POST, "/api/v1/friends/requests", a.token, {"full_name": b.full_name})
	var rid := String((req.get("json", {}) as Dictionary).get("request_id", ""))
	var acc := _call(HTTPClient.METHOD_POST, "/api/v1/friends/requests/%s/accept" % rid, b.token, null)
	_row("friends", req.get("code", 0) == 201 and acc.get("code", 0) == 200, "%s + %s" % [a.full_name, b.full_name])
	for p in _players:
		p.start(t, ws, l)
		p.rs.connect_lobby()
	_row("lobby connections", await _wait(func() -> bool:
		return _players.all(func(p: Player) -> bool: return p.rs.client.is_ready())), "4 sockets")

	# Invite: A → B; B accepts with the invite's code.
	a.rs.party_invite(b.account_id)
	_row("invite reaches B", await _wait(func() -> bool: return not b.invites.is_empty()),
		"from %s" % (b.rs.party.newest_invite().from_name if b.rs.party.newest_invite() != null else "?"))
	_row("A leads a party", a.rs.party.in_party() and a.rs.party.is_leader(), "code %s" % a.rs.party.code)
	if b.invites.is_empty():
		_finish()
		return
	b.rs.party_join(b.invites[0])
	_row("B accepts", await _wait(func() -> bool: return b.rs.party.members.size() == 2 and a.rs.party.members.size() == 2),
		"%d members, leader %s" % [b.rs.party.members.size(), b.rs.party.leader_name()])
	# C joins with the code (a shared link); the server's page for the link answers.
	var code := a.rs.party.code
	c.rs.party_join(code)
	_row("C joins by code", await _wait(func() -> bool: return a.rs.party.members.size() == 3 and c.rs.party.in_party()),
		"%d members" % a.rs.party.members.size())
	var page := _call(HTTPClient.METHOD_GET, "/r/" + code.to_lower(), "", null)
	var link := NetRoomSession.invite_url(_api + "/api/v1", code, t.invite_path)
	_row("invite page", page.get("code", 0) == 200 and String(page.get("text", "")).contains("room=" + code),
		"%s -> 200, opens the web build with ?room=%s" % [link, code])

	# The leader Quick Joins: the party follows into the same public room as one crew.
	a.rs.quick_join()
	var together := func() -> bool:
		return a.rs.is_in_room() and b.rs.is_in_room() and c.rs.is_in_room() \
			and b.rs.room.room_id == a.rs.room.room_id and c.rs.room.room_id == a.rs.room.room_id
	_row("party quick join", await _wait(together),
		"room %d (%s), %s" % [a.rs.room.room_id, a.rs.room.visibility, a.rs.room.players_text()])
	_row("one crew", a.crew() >= 0 and b.crew() == a.crew() and c.crew() == a.crew(),
		"crew slots A %d B %d C %d" % [a.crew(), b.crew(), c.crew()])
	# A solo player: the fullest public room that fits, a crew of their own.
	d.rs.quick_join()
	_row("solo quick join", await _wait(func() -> bool: return d.rs.is_in_room()),
		"room %d, %s" % [d.rs.room.room_id, d.rs.room.players_text()])
	_row("solo crew", d.rs.room.room_id != a.rs.room.room_id or d.crew() != a.crew(),
		"D %d vs party %d" % [d.crew(), a.crew()])
	# Everyone leaves; the party closes as its members go.
	for p in _players:
		p.rs.leave()
	a.rs.party_leave()
	_row("party left", await _wait(func() -> bool: return not a.rs.party.in_party() and b.rs.party.leader == b.account_id),
		"B leads now")
	_finish()


func _finish() -> void:
	for p in _players:
		if p.rs != null:
			p.rs.close()
	print("LIVE_PARTY %s (%d failed)" % ["ok" if _failed == 0 else "FAIL", _failed])
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
