extends WBTest
## Room and crew invites on the client (protocol 2): the codec's new kinds round trip, the
## room session sends `room_invite` only from a room and takes a refusal within
## `room_invite_answer_s` as its answer (the server's detail), incoming room invites are kept
## (newest first, one per code, capped, expired by their `expires_in_s`), accepted by the
## join by code and declined without a message; NetSocialClient's crew invites against the
## fake Social API (list, accept with the join checks, decline, invite a friend, INVITED,
## the live `lobby_event.crew_invite`) and the room invite list (online friends and
## crewmates, deduplicated, without the room's members). Spec: multiplayer handoff → Rooms,
## parties and matchmaking (Private rooms, Friends and presence, Crews); docs/PROTOCOL.md
## §4; docs/SERVER.md → Room invites, Crew invites; docs/ROOMS_CLIENT.md → Room invites.

const FakeInviteServer := preload("res://tests/net/fake_invite_server.gd")
const FakeServer := preload("res://tests/net/fake_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const STEP_S := 0.01
const ME := "41"
const BIG_ID := "9007199254740993"

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var failures: Array[String] = []
var errors: Array[String] = []
var invited: Array[String] = []
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(5))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeInviteServer.new(link)
	rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	failures.clear()
	errors.clear()
	invited.clear()
	rs.room_invite_failed.connect(func(code: String, m: String) -> void: failures.append(code + ": " + m))
	rs.lobby_error.connect(func(code: String, _m: String) -> void: errors.append(code))
	rs.room_invited.connect(func(inv: NetRoomInvites.Invite) -> void: invited.append(inv.code))


func after_each() -> void:
	rs = null
	server = null
	link = null
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


func _net(seconds: float) -> void:
	for i in roundi(seconds / STEP_S):
		time.advance_s(STEP_S)
		server.call("poll")
		rs.poll()


func _in_room() -> void:
	rs.join_code("ABC234")
	_net(0.4)
	eq(rs.state, NetRoomSession.State.IN_ROOM, "seated")


func _sent() -> Array[Dictionary]:
	return server.get("room_invites")


# ---------------------------------------------------------------- Codec

func test_the_codec_round_trips_the_invite_kinds() -> void:
	var codec := NetCodec.new()
	eq(NetCodec.PROTOCOL_VERSION, 2, "protocol 2: invites")
	var cmd := {"type": "lobby_command", "kind": "room_invite", "account_id": BIG_ID}
	var frame := codec.encode_frame([cmd], NetCodec.Direction.CLIENT_TO_SERVER)
	eq(codec.error, "")
	eq(codec.decode_frame(frame, NetCodec.Direction.CLIENT_TO_SERVER), [cmd])
	var from := {"account_id": "42", "display_name": "Zoë", "name_tag": 7}
	var events: Array[Dictionary] = [
		{"type": "lobby_event", "kind": "room_invite", "from": from, "room_id": 4294967295,
			"code": "K7QX2M", "visibility": "public", "players": 16, "max_players": 16,
			"expires_in_s": 65535},
		{"type": "lobby_event", "kind": "crew_invite", "invite_id": BIG_ID, "crew_tag": "NR",
			"crew_name": "Gece Sürücüleri", "from": from, "expires_in_s": 604800},
	]
	for e in events:
		frame = codec.encode_frame([e], NetCodec.Direction.SERVER_TO_CLIENT)
		if eq(codec.error, "", String(e["kind"]) + " encodes"):
			eq(codec.decode_frame(frame, NetCodec.Direction.SERVER_TO_CLIENT), [e], String(e["kind"]))
	# Ranges hold: 17 players is refused, and writes nothing.
	var bad := (events[0] as Dictionary).duplicate(true)
	bad["players"] = 17
	codec.encode_frame([bad], NetCodec.Direction.SERVER_TO_CLIENT)
	eq(codec.error, NetCodec.E_OUT_OF_RANGE)


# ---------------------------------------------------------------- Room invites

func test_room_invite_is_sent_only_from_a_room() -> void:
	check(not rs.room_invite("77"), "not connected")
	rs.connect_lobby()
	_net(0.3)
	check(not rs.room_invite("77"), "in the lobby: nothing to invite to")
	eq(_sent().size(), 0)
	_in_room()
	check(rs.room_invite("77"))
	_net(0.2)
	eq(_sent().size(), 1)
	eq(_sent()[0], {"type": "lobby_command", "kind": "room_invite", "account_id": "77"})
	eq(rs.room_invites_sent, 1)
	eq(failures, [] as Array[String], "accepted: no answer")
	eq(errors, [] as Array[String])


func test_a_refusal_is_the_invites_answer_with_the_servers_reason() -> void:
	_in_room()
	server.set("refuse_invite", "not_allowed")
	server.set("refuse_detail", "That player is offline.")
	rs.room_invite("77")
	_net(0.2)
	eq(failures, ["not_allowed: That player is offline."] as Array[String])
	eq(errors, [] as Array[String], "not a lobby error")
	# Past room_invite_answer_s an error is not the invite's.
	rs.room_invite("78")
	time.advance_s(net.room_invite_answer_s + 1.0)
	server.call("send", [{"type": "error", "code": "not_allowed", "fatal": false, "detail": "x"}])
	_net(0.2)
	eq(failures.size(), 1)
	eq(errors, ["not_allowed"] as Array[String])
	# Without a detail, the client's text.
	server.set("refuse_invite", "rate_limited")
	server.set("refuse_detail", "")
	rs.room_invite("79")
	_net(0.2)
	eq(failures[1], "rate_limited: " + NetRoomSession.text_for("rate_limited"))


func test_incoming_room_invites_are_kept_expired_accepted_and_declined() -> void:
	rs.connect_lobby()
	_net(0.3)
	server.call("push_room_invite", "42", "Dusty", 1234, "K7QX2M", 3, 60)
	_net(0.1)
	eq(invited, ["K7QX2M"] as Array[String])
	var inv := rs.room_invites.newest()
	eq(inv.from_name, "Dusty#1234")
	eq(inv.code, "K7QX2M")
	eq([inv.players, inv.max_players, inv.room_id], [3, 8, 33])
	check(not inv.is_public())
	# Newest first, one per code, at most room_invites_max.
	for i in net.room_invites_max + 1:
		server.call("push_room_invite", str(50 + i), "Rider", i, "AAAAA%d" % (i + 2), 1, 600)
	server.call("push_room_invite", "42", "Dusty", 1234, "K7QX2M", 4, 60)
	_net(0.1)
	eq(rs.room_invites.invites.size(), net.room_invites_max)
	eq(rs.room_invites.newest().code, "K7QX2M")
	eq(rs.room_invites.newest().players, 4, "the newer one replaces it")
	# Expired after its expires_in_s.
	_net(61.0)
	check(rs.room_invites.find("K7QX2M") == null, "expired")
	# Decline: nothing sent. Accept: the join by its code.
	var code := rs.room_invites.newest().code
	var cmds_before: int = (server.get("lobby_commands") as Array).size()
	rs.decline_room_invite(code)
	check(rs.room_invites.find(code) == null)
	_net(0.1)
	eq((server.get("lobby_commands") as Array).size(), cmds_before, "declining sends nothing")
	code = rs.room_invites.newest().code
	rs.accept_room_invite(code)
	_net(0.4)
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins[joins.size() - 1], {"type": "lobby_command", "kind": "room_join_code", "code": code})
	eq(rs.state, NetRoomSession.State.IN_ROOM)
	check(rs.room_invites.find(code) == null)


func test_the_invite_list_helpers() -> void:
	var list := NetRoomInvites.new()
	var msg := {"from": {"account_id": "1", "display_name": "A", "name_tag": 1}, "code": "AAAAAA",
		"room_id": 1, "visibility": "private", "players": 1, "max_players": 8, "expires_in_s": 10}
	var inv := list.add(msg, 100.0, 4)
	check(list.next_for_hub() == inv and list.next_for_toast(true) == inv and list.next_for_toast(false) == inv)
	inv.toast_run = true
	check(list.next_for_toast(false) == null, "the run toasted it")
	check(list.next_for_toast(true) == inv, "the title still does")
	inv.hub_card = true
	check(list.next_for_hub() == null)
	check(not list.expire(109.9))
	check(list.expire(110.0))
	check(list.is_empty())


# ---------------------------------------------------------------- Crew invites (social client)

func _social() -> Array:
	var fake := NetFakeSocial.new()
	var session := NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), net, NetVirtualTime.new(1_000_000),
			"https://invites.test/api/v1", 3)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	await session.start()
	eq(session.account_id(), ME)
	return [fake, NetSocialClient.of(session)]


func test_crew_invites_list_accept_and_decline() -> void:
	var pair: Array = await _social()
	var fake: NetFakeSocial = pair[0]
	var social: NetSocialClient = pair[1]
	var dusty := fake.add_player("Dusty", 1234)
	var zoe := fake.add_player("Zoe", 7)
	var nr := fake.make_crew(dusty, "Night Riders", "NR")
	var dr := fake.make_crew(zoe, "Day Riders", "DR")
	fake.add_crew_invite(nr, ME, dusty)
	fake.add_crew_invite(dr, ME, zoe)
	var changed := [0]
	social.crew_invites_changed.connect(func() -> void: changed[0] += 1)
	var r: NetApiResult = await social.refresh_crew_invites()
	check(r.ok)
	check(social.crew_invites_loaded)
	eq(social.crew_invites.size(), 2)
	var first := social.crew_invites[0]
	eq(first.crew_text(), "Day Riders [DR]", "newest first")
	eq(first.from_name, "Zoe#0007")
	eq(first.member_count, 1)
	eq(first.max_members, 16)
	# Decline one; accept the other: you're in the crew.
	r = await social.decline_crew_invite(first.invite_id)
	check(r.ok)
	eq(social.crew_invites.size(), 1)
	r = await social.accept_crew_invite(social.crew_invites[0].invite_id)
	check(r.ok, "joined")
	check(social.crew != null and social.crew.crew_id == nr)
	eq(social.crew.your_role, NetCrew.MEMBER)
	check(social.crew_invites.is_empty())
	ge(changed[0], 3)
	# Gone: no longer valid (answered once already).
	var gone: NetApiResult = await social.decline_crew_invite("999")
	eq(gone.error, "invite_not_found")
	eq(NetSocialClient.error_text(gone), "That invite is no longer valid.")


func test_accepting_while_in_a_crew_asks_to_leave_first() -> void:
	var pair: Array = await _social()
	var fake: NetFakeSocial = pair[0]
	var social: NetSocialClient = pair[1]
	var dusty := fake.add_player("Dusty", 1234)
	var nr := fake.make_crew(dusty, "Night Riders", "NR")
	fake.make_crew(ME, "My Crew", "MY")
	var id := fake.add_crew_invite(nr, ME, dusty)
	await social.refresh_crew_invites()
	var r: NetApiResult = await social.accept_crew_invite(id)
	eq(r.error, "already_in_crew")
	eq(social.crew_invites.size(), 1, "still waiting")


func test_inviting_a_friend_to_the_crew() -> void:
	var pair: Array = await _social()
	var fake: NetFakeSocial = pair[0]
	var social: NetSocialClient = pair[1]
	var b := fake.add_player("Bravo", 7)
	var c := fake.add_player("Charlie", 12)
	var stranger := fake.add_player("Stranger", 1)
	fake.befriend(ME, b)
	fake.befriend(ME, c)
	fake.make_crew(ME, "My Crew", "MY")
	await social.refresh_crew()
	await social.refresh_friends()
	eq(social.crew_invitable().size(), 2, "friends not in the crew")
	var r: NetApiResult = await social.invite_to_crew(b)
	check(r.ok)
	eq(fake.requests[fake.requests.size() - 1]["path"], "/crews/%s/invites" % social.crew.crew_id)
	check(social.crew_invited_ids.has(b), "INVITED")
	r = await social.invite_to_crew(stranger)
	eq(r.error, "not_friends")
	eq(NetSocialClient.error_text(r), "You can only invite friends.")
	# The crew's sent invites from the server (another member's too).
	fake.add_crew_invite(social.crew.crew_id, c, ME)
	social.crew_invited_ids.clear()
	r = await social.refresh_crew_sent()
	check(r.ok)
	check(social.crew_invited_ids.has(b) and social.crew_invited_ids.has(c))
	# C joins: no longer invitable.
	fake.add_member(social.crew.crew_id, c)
	await social.refresh_crew()
	eq(social.crew_invitable().size(), 1)


func test_a_live_crew_invite_arrives_on_the_lobby_connection() -> void:
	var pair: Array = await _social()
	var social: NetSocialClient = pair[1]
	var wtime := NetVirtualTime.new(5_000_000)
	var wlink := NetLoopbackLink.new(wtime, Rng.new(11))
	wlink.latency_s = 0.03
	wlink.ordered = true
	var ws := FakeInviteServer.new(wlink)
	var client := NetClient.new(wlink.client, net, wtime)
	social.attach_lobby(client)
	var got: Array[NetCrew.Invite] = []
	social.crew_invited.connect(func(x: NetCrew.Invite) -> void: got.append(x))
	eq(client.start("loop://test", 1, NetCodec.hex_to_bytes(MAP_HASH), "token"), OK)
	for i in 50:
		wtime.advance_s(STEP_S)
		ws.poll()
		client.poll()
	ws.push_crew_invite("17", "NR", "Night Riders", "42", "Dusty", 1234)
	for i in 20:
		wtime.advance_s(STEP_S)
		ws.poll()
		client.poll()
	eq(got.size(), 1)
	eq(social.crew_invites.size(), 1)
	var inv := social.crew_invites[0]
	eq([inv.invite_id, inv.crew_text(), inv.from_name], ["17", "Night Riders [NR]", "Dusty#1234"])
	gt(inv.expires_at, 0)
	social.detach_lobby()


func test_room_invitees_are_online_friends_and_crewmates_deduplicated() -> void:
	var pair: Array = await _social()
	var fake: NetFakeSocial = pair[0]
	var social: NetSocialClient = pair[1]
	var ids := {
		"friend_on": fake.add_player("Alpha", 1), "friend_off": fake.add_player("Bravo", 2),
		"both": fake.add_player("Charlie", 3), "crew_on": fake.add_player("Delta", 4),
		"crew_off": fake.add_player("Echo", 5), "in_room": fake.add_player("Foxtrot", 6),
	}
	for k: String in ["friend_on", "friend_off", "both", "in_room"]:
		fake.befriend(ME, ids[k])
	var crew := fake.make_crew(ME, "My Crew", "MY")
	for k: String in ["both", "crew_on", "crew_off"]:
		fake.add_member(crew, ids[k])
	for k: String in ["friend_on", "both", "crew_on", "in_room"]:
		fake.set_presence(ids[k], "online")
	await social.refresh_friends()
	await social.refresh_crew()
	var list := social.room_invitees({ids["in_room"]: true})
	var got: Array[String] = []
	for p in list:
		got.append(p.account_id)
	eq(got, [ids["friend_on"], ids["both"], ids["crew_on"]] as Array[String],
		"friends first, the crewmate who is also a friend once, offline and room members left out")
	check(not got.has(ME))
