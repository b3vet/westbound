extends WBTest
## Parties on the room connection (N9.3): NetRoomSession + NetParty against a scripted
## server: create (connecting first), join by code, invites (kept, accepted with
## party_join, declined without a message, expired, capped), leave and kick, refusals as
## lobby errors, a party move (an unrequested snapshot) taken only while the hub shows, the
## party kept across a lobby reconnect and dropped when the server no longer has it, the
## invite link URL, and invite links from the page URL and the command line. Spec:
## multiplayer handoff → Rooms, parties and matchmaking → Parties, Private rooms (invite
## links). docs/ROOMS_CLIENT.md → Parties; docs/PROTOCOL.md §4, §12.

const FakePartyServer := preload("res://tests/net/fake_party_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var events: Array[String] = []
var errors: Array[String] = []


class WebBridge:
	extends NetJsBridge

	var query := {}

	func available() -> bool:
		return true

	func query_param(param_name: String) -> String:
		return String(query.get(param_name, ""))


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakePartyServer.new(link)
	rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	events.clear()
	errors.clear()
	rs.party_changed.connect(func() -> void: events.append("changed"))
	rs.party_invited.connect(func(inv: NetParty.Invite) -> void: events.append("invite " + inv.code))
	rs.party_left.connect(func(reason: String, _m: String) -> void: events.append("left " + reason))
	rs.lobby_error.connect(func(code: String, _m: String) -> void: errors.append(code))


func after_each() -> void:
	rs = null
	server = null
	link = null
	NetInviteLink.set_pending("")


func _net(seconds: float) -> void:
	for i in roundi(seconds / 0.01):
		time.advance_s(0.01)
		server.call("poll")
		rs.poll()


func _party_cmds() -> Array[Dictionary]:
	return server.get("party_commands")


func test_create_connects_first_and_leads_the_party() -> void:
	eq(rs.state, NetRoomSession.State.IDLE)
	rs.party_create()
	eq(rs.state, NetRoomSession.State.CONNECTING, "the party needs the lobby connection")
	_net(0.3)
	eq(rs.state, NetRoomSession.State.LOBBY)
	eq(_party_cmds().size(), 1, "sent once the Welcome came")
	eq(_party_cmds()[0]["kind"], "party_create")
	check(rs.party.in_party())
	eq(rs.party.code, FakePartyServer.PARTY_CODE)
	eq(rs.party.me, server.get("account_id"), "me from the Welcome")
	check(rs.party.is_leader(), "the creator leads")
	check(not rs.party.is_group(), "a party of one")
	check(events.has("changed"))
	# Leaving: party_left {left}, no message for the player's own leave.
	rs.party_leave()
	_net(0.2)
	check(not rs.party.in_party())
	check(events.has("left left"))


func test_join_by_code_normalizes_and_shows_the_members() -> void:
	rs.party_join(" pq7-k2m ")
	_net(0.3)
	eq(_party_cmds()[0], {"type": "lobby_command", "kind": "party_join", "code": "PQ7K2M"})
	eq(rs.party.members.size(), 2)
	eq(rs.party.leader_name(), "Dusty#1234")
	check(rs.party.is_group() and not rs.party.is_leader())
	eq(rs.party.members[1].full_name(), "Zoe#0007")


func test_refusals_are_lobby_errors_not_join_failures() -> void:
	var failed: Array[String] = []
	rs.join_failed.connect(func(code: String, _m: String) -> void: failed.append(code))
	server.set("refuse_party", "party_full")
	rs.party_join("ABC234")
	_net(0.3)
	eq(errors, ["party_full"] as Array[String])
	eq(NetRoomSession.text_for("party_full"), "That party is full.")
	check(failed.is_empty(), "no join was running")
	# While a join runs, a party refusal still is a party refusal.
	server.set("answer_joins", false)
	rs.quick_join()
	_net(0.1)
	server.set("refuse_party", "party_not_found")
	rs.party_join("ZZZZZZ")
	_net(0.2)
	eq(errors.back(), "party_not_found")
	eq(rs.state, NetRoomSession.State.JOINING, "the join goes on")


func test_invites_are_kept_accepted_declined_and_expire() -> void:
	rs.connect_lobby()
	_net(0.3)
	server.call("push_invite", "42", "Dusty", 1234, "AAAAAA")
	_net(0.2)
	check(events.has("invite AAAAAA"))
	eq(rs.party.invites.size(), 1)
	eq(rs.party.newest_invite().from_name, "Dusty#1234")
	# Declining sends nothing and forgets it.
	rs.decline_invite("AAAAAA")
	eq(rs.party.invites.size(), 0)
	check(_party_cmds().is_empty(), "declining needs no message")
	# Kept at most party_invites_max, newest first; the same code once.
	for i in net.party_invites_max + 2:
		server.call("push_invite", str(50 + i), "P%d" % i, i, "BBBBB%d" % (i + 2))
	server.call("push_invite", "50", "P0", 0, "BBBBB2")
	_net(0.2)
	eq(rs.party.invites.size(), net.party_invites_max)
	eq(rs.party.newest_invite().code, "BBBBB2")
	# Accepting is party_join with its code; the invite goes.
	rs.party_join("BBBBB2")
	_net(0.2)
	eq(_party_cmds().back()["kind"], "party_join")
	eq(_party_cmds().back()["code"], "BBBBB2")
	check(rs.party.in_party())
	for inv in rs.party.invites:
		ne(inv.code, "BBBBB2")
	# Old invites expire.
	rs.party.expire_invites(float(time.now_usec()) / 1.0e6 + net.party_invite_show_s + 1.0, net.party_invite_show_s)
	eq(rs.party.invites.size(), 0)


func test_kicked_from_the_party() -> void:
	rs.connect_lobby()
	_net(0.3)
	server.call("put_in_party", 3)
	_net(0.2)
	eq(rs.party.members.size(), 3)
	server.call("kick_from_party")
	_net(0.2)
	check(not rs.party.in_party())
	check(events.has("left kicked"))
	eq(NetRoomSession.text_for("party_kicked"), "The party leader removed you from the party.")


func test_a_party_move_is_taken_only_while_the_hub_shows() -> void:
	var joined: Array[int] = []
	rs.joined.connect(func(r: NetRoomState) -> void: joined.append(r.room_id))
	rs.connect_lobby()
	_net(0.3)
	server.call("put_in_party", 2)
	_net(0.2)
	# Not on the hub (a single-player run): the seat is left again.
	rs.accept_follows = false
	server.call("move_party")
	_net(0.2)
	check(joined.is_empty())
	eq(server.get("leaves"), 1, "room_leave for the unwanted seat")
	eq(rs.state, NetRoomSession.State.LOBBY)
	# On the hub: the move is a join.
	rs.accept_follows = true
	server.call("move_party")
	_net(0.2)
	eq(joined, [FakePartyServer.ROOM_ID] as Array[int])
	eq(rs.state, NetRoomSession.State.IN_ROOM)
	check(rs.has_placement(), "placed like any join")
	# Without a party an unasked snapshot is still left.
	rs.leave()
	_net(0.2)
	server.call("kick_from_party")
	_net(0.2)
	server.call("move_party")
	_net(0.2)
	eq(joined.size(), 1)


func test_the_party_survives_a_lobby_reconnect_and_goes_when_the_server_forgot_it() -> void:
	rs.connect_lobby()
	_net(0.3)
	server.call("put_in_party", 2)
	_net(0.2)
	server.call("drop")
	_net(0.5)
	ne(rs.state, NetRoomSession.State.FAILED, "reconnecting, not failed")
	eq(server.get("hellos").size(), 2, "a second Hello at once")
	check(rs.party.in_party(), "kept while the server holds the place")
	_net(net.party_reconnect_retry_s + 0.5)
	eq(rs.state, NetRoomSession.State.LOBBY, "reconnected")
	check(rs.party.in_party(), "the Welcome's frame carried the state")
	check(not events.has("left lost"))
	# The server let the place go: a Welcome without the state drops the party.
	server.call("drop")
	server.set("party_code", "")
	_net(net.party_reconnect_retry_s + 0.5)
	eq(rs.state, NetRoomSession.State.LOBBY)
	check(not rs.party.in_party())
	check(events.has("left lost"))


func test_the_party_goes_when_the_reconnect_window_ends() -> void:
	rs.connect_lobby()
	_net(0.3)
	server.call("put_in_party", 2)
	_net(0.2)
	server.set("silent", true)
	server.call("drop")
	_net(net.party_reconnect_window_s + 1.0)
	check(not rs.party.in_party())
	check(events.has("left lost"))


func test_invite_urls_and_links() -> void:
	eq(NetRoomSession.invite_url("https://westbound.sipsakrandevu.com/api/v1", "K7QX2M", net.invite_path),
			"https://westbound.sipsakrandevu.com/r/K7QX2M", "spec: https://<domain>/r/<code>")
	eq(NetRoomSession.invite_url("http://127.0.0.1:18652/api/v1", "K7QX2M", net.invite_path),
			"http://127.0.0.1:18652/r/K7QX2M")
	# The web page's ?room= (normalized), else --room=; demo (the snap room) is no code.
	var web := WebBridge.new()
	web.query = {"room": "k7qx-2m"}
	eq(NetInviteLink.from_boot(web, PackedStringArray(), PackedStringArray()), "K7QX2M")
	eq(NetInviteLink.from_boot(null, PackedStringArray(["--room=abc234"]), PackedStringArray()), "ABC234")
	eq(NetInviteLink.from_boot(null, PackedStringArray(), PackedStringArray(["--room=ABC234"])), "ABC234")
	eq(NetInviteLink.from_boot(null, PackedStringArray(["--room=demo"]), PackedStringArray()), "")
	eq(NetInviteLink.from_boot(null, PackedStringArray(["--room=ABC0O1"]), PackedStringArray()), "", "no 0/O/1")
	# A link the OS hands the app (Universal Links / App Links / the scheme).
	eq(NetInviteLink.from_url("https://westbound.sipsakrandevu.com/r/K7QX2M"), "K7QX2M")
	eq(NetInviteLink.from_url("https://westbound.sipsakrandevu.com/r/k7qx2m/?utm=x"), "K7QX2M")
	eq(NetInviteLink.from_url("westbound://r/K7QX2M"), "K7QX2M")
	eq(NetInviteLink.from_url("https://westbound.sipsakrandevu.com/api/v1/health"), "")
	# Taken once.
	NetInviteLink.set_pending("abc-234")
	eq(NetInviteLink.peek(), "ABC234")
	eq(NetInviteLink.take(), "ABC234")
	eq(NetInviteLink.take(), "")


func test_party_state_bookkeeping() -> void:
	var p := NetParty.new()
	p.me = "7"
	check(not p.in_party() and not p.is_leader())
	var v := p.version
	p.apply_state({"code": "PQ7K2M", "leader": "7", "members": [
		{"account_id": "7", "display_name": "Zoe", "name_tag": 7},
		{"account_id": "9", "display_name": "Ali", "name_tag": 12}]})
	check(p.version > v)
	check(p.is_leader() and p.is_group())
	eq(p.member("9").full_name(), "Ali#0012")
	p.clear()
	check(not p.in_party() and p.members.is_empty())
