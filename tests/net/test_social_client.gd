extends WBTest
## NetSocialClient against the in-memory Social API (NetFakeSocial): every action calls
## the right endpoint with the right JSON, the server's errors map to player text, presence
## arrives from both GET /presence polling and WebSocket `lobby_event.presence`, crews
## follow the role table, reports are rate-limited, and everything is offline-safe. Spec:
## multiplayer handoff → Friends and presence, Crews (persistent), Moderation → Report;
## docs/SERVER.md → Social API; docs/PROTOCOL.md §4. WP N9.2.

const FakeServer := preload("res://tests/net/fake_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const STEP_S := 0.01
const ME := "41"

var tuning: NetTuning
var fake: NetFakeSocial
var session: NetSession
var social: NetSocialClient
var clock: NetVirtualTime
var _nodes: Array[Node] = []


func before_all() -> void:
	tuning = NetTuning.load_default()


func before_each() -> void:
	fake = NetFakeSocial.new()
	clock = NetVirtualTime.new(1_000_000)
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), tuning, clock, "https://social.test/api/v1", 3)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	await session.start()
	eq(session.account_id(), ME)
	social = NetSocialClient.of(session)
	fake.requests.clear()


func after_each() -> void:
	if social != null:
		social.detach_lobby()
	social = null
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	session = null
	await tree.process_frame


## The last request's JSON body.
func _body() -> Dictionary:
	var r: Dictionary = fake.requests[fake.requests.size() - 1]
	return NetFakeAccounts._json(String(r["body"]))


func _last() -> Dictionary:
	return fake.requests[fake.requests.size() - 1]


## The first request to `path` with `method`.
func _sent(method: int, path: String) -> Dictionary:
	for r in fake.requests:
		if r["path"] == path and r["method"] == method:
			return r
	return {}


func _friends_setup() -> Dictionary:
	var ids := {
		"b": fake.add_player("Bravo", 7), "c": fake.add_player("charlie", 12),
		"d": fake.add_player("Delta", 3), "e": fake.add_player("Echo", 44), "f": fake.add_player("Foxtrot", 5),
	}
	fake.befriend(ME, ids["b"])
	fake.befriend(ids["c"], ME)
	fake.befriend(ME, ids["d"])
	fake.set_presence(ids["b"], "online")
	fake.set_presence(ids["c"], "in_room", 12, true)
	fake.add_request(ids["e"], ME)
	fake.add_request(ME, ids["f"])
	return ids


# ---------------------------------------------------------------- Friends

func test_of_session_is_shared() -> void:
	check(social != null)
	check(NetSocialClient.of(session) == social, "one client per session")
	check(NetSocialClient.of(null) == null)
	check(social.available())


func test_friends_list_parsed_and_sorted() -> void:
	var ids := _friends_setup()
	var fired := [0]
	social.friends_changed.connect(func() -> void: fired[0] += 1)
	var r := await social.refresh_friends()
	check(r.ok, r.error)
	var req := _last()
	eq(req["method"], HTTPClient.METHOD_GET)
	eq(req["path"], "/friends")
	check(String(req["auth"]).length() > 0, "bearer sent")
	eq(fired[0], 1)
	eq(social.friends.size(), 3)
	eq(social.friends[0].account_id, ids["c"], "in a room first")
	eq(social.friends[0].status, NetSocialPlayer.IN_ROOM)
	eq(social.friends[0].room_id, 12)
	check(social.friends[0].joinable)
	eq(social.friends[1].display_name, "Bravo", "then online")
	eq(social.friends[1].full_name, "Bravo#0007")
	eq(social.friends[1].tag_text(), "#0007")
	eq(social.friends[2].display_name, "Delta", "then offline")
	eq(social.friends[2].room_id, 0, "null room reads as 0")
	eq(social.incoming.size(), 1)
	eq(social.incoming[0].account_id, ids["e"])
	check(not social.incoming[0].request_id.is_empty())
	eq(social.outgoing.size(), 1)
	eq(social.outgoing[0].account_id, ids["f"])
	eq(social.max_friends, 100)
	eq(social.online_count(), 2)


func test_send_request_sends_the_code() -> void:
	var b := fake.add_player("LoneWolf", 7)
	var r := await social.send_request("  lonewolf#0007 ")
	check(r.ok, r.error)
	var sent := _sent(HTTPClient.METHOD_POST, "/friends/requests")
	eq(NetFakeAccounts._json(String(sent["body"])), {"full_name": "lonewolf#0007"})
	eq(r.str_field("status"), "pending")
	eq(social.outgoing.size(), 1, "the list refreshed")
	eq(social.outgoing[0].account_id, b)
	# They had asked us: sending accepts.
	var c := fake.add_player("Charlie", 1)
	fake.add_request(c, ME)
	r = await social.send_request("Charlie#1")
	eq(r.status, 200)
	eq(r.str_field("status"), "accepted")
	check(social.friend(c) != null)


func test_friend_request_errors_are_mapped() -> void:
	var b := fake.add_player("Bravo", 7)
	var blocker := fake.add_player("Grumpy", 99)
	fake.block_pair(blocker, ME)
	var cases := [
		["nohash", "invalid_full_name", false],
		["Name#12345", "invalid_full_name", false],
		["#0042", "invalid_full_name", false],
		["Nobody#0001", "player_not_found", true],
		["Grumpy#0099", "player_not_found", true],
		[session.profile.full_name, "cannot_friend_self", true],
	]
	for c: Array in cases:
		var before := fake.requests.size()
		var r := await social.send_request(String(c[0]))
		eq(r.error, String(c[1]), String(c[0]))
		eq(fake.requests.size() > before, bool(c[2]), "%s reaches the server" % c[0])
		eq(NetSocialClient.error_text(r), String(NetSocialClient.TEXT[c[1]]))
	# A block reads exactly like an unknown name.
	var unknown := await social.send_request("Nobody#0001")
	var blocked := await social.send_request("Grumpy#0099")
	eq(NetSocialClient.error_text(blocked), NetSocialClient.error_text(unknown))
	eq(blocked.status, unknown.status)
	eq((await social.send_request("Bravo#0007")).status, 201)
	eq((await social.send_request("Bravo#0007")).error, "request_exists")
	fake.befriend(ME, fake.add_player("Old", 2))
	eq((await social.send_request("Old#0002")).error, "already_friends")
	var d := fake.add_player("Delta", 3)
	fake.max_friends = 1
	eq((await social.send_request("Delta#0003")).error, "friends_limit", "we have one friend")
	fake.max_friends = 100
	for i in 3:
		fake.befriend(d, fake.add_player("Pal", 100 + i))
	fake.max_friends = 3
	eq((await social.send_request("Delta#0003")).error, "target_friends_limit")
	fake.max_friends = 100
	fake.max_outgoing_requests = 1
	eq((await social.send_request("Delta#0003")).error, "requests_limit")
	fake.max_outgoing_requests = 50
	fake.max_incoming_requests = 0
	eq((await social.send_request("Delta#0003")).error, "target_requests_limit")
	for code: String in ["friends_limit", "target_friends_limit", "requests_limit", "target_requests_limit",
			"already_friends", "request_exists"]:
		check(NetSocialClient.TEXT.has(code), code)
	check(not b.is_empty())


func test_rate_limit_is_mapped_with_the_wait() -> void:
	fake.add_player("Bravo", 7)
	fake.script(HTTPClient.METHOD_POST, "/friends/requests", 429,
			{"error": "rate_limited", "message": "slow down", "retry_after_secs": 1790},
			PackedStringArray(["Retry-After: 1790"]))
	var r := await social.send_request("Bravo#0007")
	eq(r.error, NetApiResult.RATE_LIMITED)
	near(r.retry_after_s, 1790.0, 0.001)
	eq(r.attempts, 1, "a long wait is not retried")
	eq(NetSocialClient.error_text(r), "Too many tries. Try again in 30 min.")
	eq(NetSocialClient.wait_text(10.0), "a moment")
	eq(NetSocialClient.wait_text(7200.0), "2 h")


func test_accept_decline_cancel_remove() -> void:
	var ids := _friends_setup()
	await social.refresh_friends()
	var inc := social.incoming[0]
	var r := await social.accept(inc.request_id)
	check(r.ok, r.error)
	check(not _sent(HTTPClient.METHOD_POST, "/friends/requests/%s/accept" % inc.request_id).is_empty())
	check(social.friend(ids["e"]) != null, "now a friend")
	eq(social.incoming.size(), 0)
	eq((await social.accept(inc.request_id)).error, "request_not_found")
	# Cancel our own request.
	var out := social.outgoing[0]
	r = await social.cancel_request(out.request_id)
	check(r.ok, r.error)
	eq(_last()["path"], "/friends/requests/%s/decline" % out.request_id)
	eq(social.outgoing.size(), 0, "gone locally")
	# Decline an incoming one.
	var g := fake.add_player("Golf", 8)
	fake.add_request(g, ME)
	await social.refresh_friends()
	r = await social.decline(social.incoming[0].request_id)
	check(r.ok and social.incoming.is_empty())
	# Remove a friend.
	r = await social.remove_friend(ids["b"])
	check(r.ok, r.error)
	eq(_last()["method"], HTTPClient.METHOD_DELETE)
	eq(_last()["path"], "/friends/%s" % ids["b"])
	check(social.friend(ids["b"]) == null)
	r = await social.remove_friend(ids["b"])
	eq(r.error, "friend_not_found")
	eq(NetSocialClient.error_text(r), NetSocialClient.TEXT["friend_not_found"])


# ---------------------------------------------------------------- Blocks

func test_block_and_unblock() -> void:
	var ids := _friends_setup()
	await social.refresh_friends()
	var fired := [0]
	social.blocks_changed.connect(func() -> void: fired[0] += 1)
	var r := await social.block(ids["b"])
	check(r.ok, r.error)
	var sent := _sent(HTTPClient.METHOD_POST, "/blocks")
	eq(NetFakeAccounts._json(String(sent["body"])), {"account_id": ids["b"]})
	check(social.friend(ids["b"]) == null, "blocking ends the friendship")
	eq(social.blocks.size(), 1)
	eq(social.blocks[0].account_id, ids["b"])
	check(social.blocks[0].blocked_at > 0)
	eq(social.max_blocks, 500)
	check(fired[0] >= 1)
	eq((await social.block(ME)).error, "cannot_block_self")
	eq((await social.send_request("Bravo#0007")).error, "player_not_found", "a blocked player looks unknown")
	r = await social.unblock(ids["b"])
	check(r.ok, r.error)
	eq(_last()["method"], HTTPClient.METHOD_DELETE)
	eq(_last()["path"], "/blocks/%s" % ids["b"])
	eq(social.blocks.size(), 0)
	eq((await social.unblock(ids["b"])).error, "block_not_found")
	fake.max_blocks = 0
	eq(NetSocialClient.error_text(await social.block(ids["c"])), NetSocialClient.TEXT["blocks_limit"])


# ---------------------------------------------------------------- Presence

func test_presence_by_polling_while_watched() -> void:
	var ids := _friends_setup()
	await social.refresh_friends()
	var changed: Array[String] = []
	social.presence_changed.connect(func(id: String) -> void: changed.append(id))
	social.poll()
	eq(fake.count("/presence"), 0, "not watching: no polls")
	social.watch(true)
	social.poll()
	eq(fake.count("/presence"), 0, "the screen just loaded the list")
	clock.advance_s(tuning.social_presence_poll_s - 0.5)
	social.poll()
	eq(fake.count("/presence"), 0)
	fake.set_presence(ids["d"], "online")
	fake.set_presence(ids["c"], "offline")
	clock.advance_s(1.0)
	social.poll()
	eq(fake.count("/presence"), 1)
	eq(social.friend(ids["d"]).status, NetSocialPlayer.ONLINE)
	eq(social.friend(ids["c"]).status, NetSocialPlayer.OFFLINE)
	eq(social.friend(ids["c"]).room_id, 0)
	check(changed.has(ids["d"]) and changed.has(ids["c"]))
	eq(social.friends[social.friends.size() - 1].account_id, ids["c"], "re-sorted: offline last")
	social.poll()
	eq(fake.count("/presence"), 1, "one poll per interval")
	social.watch(false)
	clock.advance_s(tuning.social_presence_poll_s * 4.0)
	social.poll()
	eq(fake.count("/presence"), 1, "closed screen: no polls")


func test_presence_poll_backs_off_on_429() -> void:
	_friends_setup()
	await social.refresh_friends()
	social.watch(true)
	fake.script(HTTPClient.METHOD_GET, "/presence", 429,
			{"error": "rate_limited", "message": "x", "retry_after_secs": 120}, PackedStringArray(["Retry-After: 120"]))
	clock.advance_s(tuning.social_presence_poll_s)
	social.poll()
	eq(fake.count("/presence"), 1)
	clock.advance_s(tuning.social_presence_poll_s)
	social.poll()
	eq(fake.count("/presence"), 1, "waits out the Retry-After")
	clock.advance_s(120.0)
	social.poll()
	eq(fake.count("/presence"), 2)


func _run(link: NetLoopbackLink, server: RefCounted, client: NetClient, seconds: float) -> void:
	for i in roundi(seconds / STEP_S):
		link.time.call("advance_s", STEP_S)
		server.call("poll")
		client.poll()


func test_presence_over_websocket() -> void:
	var ids := _friends_setup()
	await social.refresh_friends()
	social.watch(true)
	var wtime := NetVirtualTime.new(5_000_000)
	var link := NetLoopbackLink.new(wtime, Rng.new(11))
	link.latency_s = 0.03
	link.ordered = true
	var server := FakeServer.new(link)
	var client := NetClient.new(link.client, tuning, wtime)
	social.attach_lobby(client)
	check(not social.ws_live(), "not connected yet")
	eq(client.start("loop://test", 1, NetCodec.hex_to_bytes(MAP_HASH), "token"), OK)
	_run(link, server, client, 0.5)
	check(client.is_ready())
	var cmds: Array[Dictionary] = server.get("lobby_commands")
	eq(cmds.size(), 1, "subscribed after Welcome")
	eq(cmds[0], {"type": "lobby_command", "kind": "presence_subscribe", "enabled": true})
	check(social.ws_live())
	# The snapshot, then single updates.
	server.call("send", [{"type": "lobby_event", "kind": "presence", "friends": [
		{"account_id": ids["b"], "status": "in_room", "room_id": 77, "joinable": false},
		{"account_id": ids["c"], "status": "offline", "room_id": 0, "joinable": false},
		{"account_id": ids["d"], "status": "online", "room_id": 0, "joinable": false}]}])
	_run(link, server, client, 0.2)
	eq(social.ws_presence_events, 1)
	eq(social.friend(ids["b"]).status, NetSocialPlayer.IN_ROOM)
	eq(social.friend(ids["b"]).room_id, 77)
	check(not social.friend(ids["b"]).joinable)
	eq(social.friend(ids["c"]).status, NetSocialPlayer.OFFLINE)
	eq(social.friend(ids["d"]).status, NetSocialPlayer.ONLINE)
	eq(social.friends[0].account_id, ids["b"])
	server.call("send", [{"type": "lobby_event", "kind": "presence", "friends": [
		{"account_id": ids["b"], "status": "in_room", "room_id": 77, "joinable": true}]}])
	_run(link, server, client, 0.2)
	check(social.friend(ids["b"]).joinable, "a later entry replaces the earlier one")
	# No HTTP polling while the subscription is live.
	clock.advance_s(tuning.social_presence_poll_s * 3.0)
	social.poll()
	eq(fake.count("/presence"), 0, "the WebSocket feeds presence")
	# A friend we don't know yet (a request accepted elsewhere): the list refreshes.
	var n := fake.count("/friends")
	server.call("send", [{"type": "lobby_event", "kind": "presence", "friends": [
		{"account_id": "999", "status": "online", "room_id": 0, "joinable": false}]}])
	_run(link, server, client, 0.2)
	social.poll()
	eq(fake.count("/friends"), n + 1, "unknown friend: refreshed the list")
	# The gateway can't subscribe: poll until the next Welcome.
	server.call("send", [{"type": "error", "code": "internal", "fatal": false, "detail": "x"}])
	_run(link, server, client, 0.2)
	check(not social.ws_live())
	social.poll()
	eq(fake.count("/presence"), 1, "fell back to polling")
	# Attaching again subscribes; detaching unsubscribes.
	social.detach_lobby()
	social.attach_lobby(client)
	check(social.ws_live())
	social.detach_lobby()
	social.attach_lobby(client)
	_run(link, server, client, 0.2)
	cmds = server.get("lobby_commands")
	eq(cmds.size(), 4)
	eq(cmds[2], {"type": "lobby_command", "kind": "presence_subscribe", "enabled": false})
	eq(cmds[3]["enabled"], true)
	# The socket dies: polling resumes at once.
	var polls := fake.count("/presence")
	link.down = true
	_run(link, server, client, 9.0)
	check(not client.is_ready())
	check(not social.ws_live())
	social.poll()
	eq(fake.count("/presence"), polls + 1, "lost socket: polled at once")
	social.detach_lobby()


func test_presence_resubscribes_after_reconnect() -> void:
	_friends_setup()
	await social.refresh_friends()
	var wtime := NetVirtualTime.new(5_000_000)
	var link := NetLoopbackLink.new(wtime, Rng.new(12))
	var server := FakeServer.new(link)
	var client := NetClient.new(link.client, tuning, wtime)
	client.start("loop://test", 1, NetCodec.hex_to_bytes(MAP_HASH), "token")
	_run(link, server, client, 0.3)
	check(client.is_ready())
	social.attach_lobby(client)
	check(social.ws_live())
	_run(link, server, client, 0.2)
	eq((server.get("lobby_commands") as Array).size(), 1, "attached to a ready client: subscribed at once")
	client.close()
	check(not social.ws_live())
	_run(link, server, client, 0.5)
	server.set("established", false)
	eq(client.start("loop://test", 1, NetCodec.hex_to_bytes(MAP_HASH), "token"), OK)
	_run(link, server, client, 1.0)
	check(client.is_ready(), "reconnected")
	eq((server.get("lobby_commands") as Array).size(), 2, "subscribed again after the new Welcome")
	check(social.ws_live())


# ---------------------------------------------------------------- Crews

func test_create_crew_and_errors() -> void:
	var fired := [0]
	social.crew_changed.connect(func() -> void: fired[0] += 1)
	var r := await social.refresh_crew()
	eq(r.error, "not_in_crew")
	check(social.crew_loaded and social.crew == null, "no crew is a normal answer")
	eq((await social.create_crew("ab", "NR")).error, "invalid_crew_name")
	eq((await social.create_crew("Night Riders", "N")).error, "invalid_crew_tag")
	eq((await social.create_crew("Night Riders", "NRXYZ")).error, "invalid_crew_tag")
	eq(fake.count("/crews"), 0, "obviously bad input never leaves the device")
	eq((await social.create_crew("Rude Boys", "NR")).error, "crew_name_not_allowed")
	eq(NetSocialClient.error_text(await social.create_crew("Rude Boys", "NR")), "That crew name isn't allowed.")
	eq((await social.create_crew("Night Riders", "rude")).error, "crew_tag_not_allowed")
	eq((await social.create_crew("Night--Riders", "NR")).error, "invalid_crew_name")
	var other := fake.add_player("Owner", 1)
	fake.make_crew(other, "Taken Name", "TK")
	eq((await social.create_crew("taken name", "AB")).error, "crew_name_taken")
	eq((await social.create_crew("Fresh", "tk")).error, "crew_tag_taken")
	r = await social.create_crew("  Night Riders ", "nr")
	check(r.ok, r.error)
	eq(r.status, 201)
	eq(_body(), {"name": "Night Riders", "tag": "NR"}, "trimmed, tag upper case")
	eq(_last()["path"], "/crews")
	eq(social.crew.name, "Night Riders")
	eq(social.crew.tag, "NR")
	eq(social.crew.your_role, NetCrew.OWNER)
	eq(social.crew.members.size(), 1)
	eq(social.crew.members[0].account_id, ME)
	eq(social.crew.invite_code.length(), 8)
	eq(social.crew.max_members, 16)
	check(fired[0] >= 2)
	eq((await social.create_crew("Second", "SC")).error, "already_in_crew")
	for code: String in ["invalid_crew_name", "crew_name_not_allowed", "invalid_crew_tag", "crew_tag_not_allowed",
			"crew_name_taken", "crew_tag_taken", "already_in_crew"]:
		check(NetSocialClient.error_text(NetApiResult.failure(400, code)) == String(NetSocialClient.TEXT[code]), code)


func test_join_crew_by_code() -> void:
	var owner := fake.add_player("Owner", 1)
	var cid := fake.make_crew(owner, "Night Riders", "NR")
	var code := String((fake.crews[cid] as Dictionary)["code"])
	eq((await social.join_crew("abc")).error, "invalid_invite_code", "too short: not sent")
	eq(fake.count("/crews/join"), 0)
	eq((await social.join_crew("ZZZZ-ZZZZ")).error, "invalid_invite_code")
	fake.crew_max_members = 1
	eq((await social.join_crew(code)).error, "crew_full")
	eq(NetSocialClient.error_text(NetApiResult.failure(409, "crew_full")), "That crew is full.")
	fake.crew_max_members = 16
	var typed := code.to_lower().insert(4, "-")
	var r := await social.join_crew(" %s " % typed)
	check(r.ok, r.error)
	eq(_body(), {"invite_code": code}, "normalized code")
	eq(social.crew.crew_id, cid)
	eq(social.crew.your_role, NetCrew.MEMBER)
	eq(social.crew.members.size(), 2)
	eq(social.crew.members[0].role, NetCrew.OWNER, "owner first")


func test_crew_member_actions() -> void:
	var cid := fake.make_crew(ME, "Night Riders", "NR")
	var b := fake.add_player("Bravo", 7)
	var c := fake.add_player("Charlie", 8)
	fake.add_member(cid, b)
	fake.add_member(cid, c, NetCrew.OFFICER)
	await social.refresh_crew()
	eq(social.crew.members.size(), 3)
	eq(social.crew.members[1].account_id, c, "officers before members")
	var r := await social.promote(b)
	check(r.ok, r.error)
	eq(_last()["path"], "/crews/%s/promote" % cid)
	eq(_body(), {"account_id": b})
	eq(social.crew.member(b).role, NetCrew.OFFICER)
	r = await social.demote(c)
	eq(_last()["path"], "/crews/%s/demote" % cid)
	eq(social.crew.member(c).role, NetCrew.MEMBER)
	var old := social.crew.invite_code
	r = await social.rotate_invite_code()
	check(r.ok, r.error)
	eq(_last()["path"], "/crews/%s/invite-code" % cid)
	ne(social.crew.invite_code, old)
	r = await social.kick(c)
	eq(_last()["path"], "/crews/%s/kick" % cid)
	eq(_body(), {"account_id": c})
	check(social.crew.member(c) == null)
	eq((await social.kick(ME)).error, "cannot_kick_self")
	eq((await social.promote(ME)).error, "cannot_change_own_role")
	eq((await social.transfer(ME)).error, "cannot_transfer_to_self")
	r = await social.transfer(b)
	check(r.ok, r.error)
	eq(_last()["path"], "/crews/%s/transfer" % cid)
	eq(social.crew.your_role, NetCrew.OFFICER, "the old owner becomes an officer")
	eq(social.crew.owner_id, b)
	# Now an officer: the server refuses owner actions.
	r = await social.promote(b)
	eq(r.error, "not_permitted")
	eq(NetSocialClient.error_text(r), "Your role can't do that.")
	r = await social.disband()
	eq(r.error, "not_permitted")
	# Leave.
	r = await social.leave_crew()
	check(r.ok, r.error)
	eq(_last()["path"], "/crews/%s/leave" % cid)
	check(social.crew == null)
	eq((await social.kick(b)).error, "not_in_crew", "no crew: nothing sent")


func test_disband() -> void:
	var cid := fake.make_crew(ME, "Night Riders", "NR")
	await social.refresh_crew()
	var r := await social.disband()
	check(r.ok, r.error)
	eq(_last()["method"], HTTPClient.METHOD_DELETE)
	eq(_last()["path"], "/crews/%s" % cid)
	check(social.crew == null)
	check(not fake.crews.has(cid))


func test_crew_standing() -> void:
	var cid := fake.make_crew(ME, "Night Riders", "NR")
	await social.refresh_crew()
	var r := await social.refresh_standing()
	check(r.ok, r.error)
	eq(_last()["path"], "/boards/loop_crew?view=around_me&limit=1")
	check(social.standing_loaded)
	eq(social.standing_rank, 0, "not on the board yet")
	fake.crew_scores["99"] = 900000
	fake.crew_scores[cid] = 183200
	r = await social.refresh_standing()
	eq(social.standing_rank, 2)
	eq(social.standing_score, 183200)
	eq(social.standing_period, NetFakeSocial.PERIOD)


func test_role_table() -> void:
	var o := NetCrew.OWNER
	var f := NetCrew.OFFICER
	var m := NetCrew.MEMBER
	eq(NetCrew.allowed_actions(o, m, false), [NetCrew.PROMOTE, NetCrew.TRANSFER, NetCrew.KICK])
	eq(NetCrew.allowed_actions(o, f, false), [NetCrew.DEMOTE, NetCrew.TRANSFER, NetCrew.KICK])
	eq(NetCrew.allowed_actions(o, o, true), [])
	eq(NetCrew.allowed_actions(f, m, false), [NetCrew.KICK])
	eq(NetCrew.allowed_actions(f, f, false), [], "officers can't kick officers")
	eq(NetCrew.allowed_actions(f, o, false), [])
	eq(NetCrew.allowed_actions(m, m, false), [])
	eq(NetCrew.allowed_actions(f, f, true), [], "nobody acts on themselves")
	check(NetCrew.can_rotate_code(o) and NetCrew.can_rotate_code(f) and not NetCrew.can_rotate_code(m))
	check(NetCrew.can_disband(o) and not NetCrew.can_disband(f) and not NetCrew.can_disband(m))


# ---------------------------------------------------------------- Reports

func test_report_sends_reason_and_context() -> void:
	var b := fake.add_player("Bravo", 7)
	var r := await social.report(b, "cheating", {"source": "leaderboard", "board": "loop", "run_id": "917"})
	check(r.ok, r.error)
	eq(r.status, 201)
	eq(_last()["path"], "/reports")
	eq(_body(), {"target_account_id": b, "reason": "cheating",
			"context": {"source": "leaderboard", "board": "loop", "run_id": "917"}})
	check(not r.str_field("report_id").is_empty())
	r = await social.report(b, "griefing")
	eq(_body(), {"target_account_id": b, "reason": "griefing"}, "no context: left out")
	var before := fake.requests.size()
	eq((await social.report(b, "rude")).error, "invalid_reason")
	eq(fake.requests.size(), before, "a bad reason is not sent")
	eq((await social.report(ME, "other")).error, "cannot_report_self")
	eq(NetSocialClient.REPORT_REASONS, ["cheating", "offensive_name", "offensive_crew", "harassment", "griefing", "other"] as Array[String])


func test_report_rate_limit() -> void:
	var b := fake.add_player("Bravo", 7)
	fake.reports_per_day = 2
	check((await social.report(b, "cheating")).ok)
	check((await social.report(b, "other")).ok)
	eq(social.report_wait_s(), 0.0)
	var r := await social.report(b, "other")
	eq(r.error, NetApiResult.RATE_LIMITED)
	gt(r.retry_after_s, 3600.0, "hours, not retried")
	eq(r.attempts, 1)
	eq(NetSocialClient.error_text(r, true), "Report limit reached. Try again in 24 h.")
	gt(social.report_wait_s(), 3600.0)
	clock.advance_s(r.retry_after_s)
	eq(social.report_wait_s(), 0.0)


# ---------------------------------------------------------------- Offline and accounts

func test_offline_is_safe() -> void:
	var off := NetSession.new()
	off.auto_start = false
	off.configure_disabled(tuning)
	tree.root.add_child(off)
	_nodes.append(off)
	var s := NetSocialClient.of(off)
	check(s != null)
	check(not s.available())
	eq((await s.refresh_friends()).error, NetApiResult.OFFLINE)
	eq((await s.send_request("Bravo#0007")).error, NetApiResult.OFFLINE)
	eq((await s.report("42", "other")).error, NetApiResult.OFFLINE)
	var bare := NetSocialClient.new(null, tuning)
	eq((await bare.refresh_crew()).error, NetApiResult.OFFLINE)
	bare.watch(true)
	bare.poll()
	eq(NetSocialClient.error_text(NetApiResult.failure(0, NetApiResult.OFFLINE)), NetSession.TEXT["offline"])
	# Signed out: nothing is sent.
	await session.logout()
	var n := fake.requests.size()
	social = NetSocialClient.of(session)
	eq((await social.refresh_friends()).error, NetSession.ERR_NOT_SIGNED_IN)
	eq(fake.requests.size(), n)
	# Network down.
	await session.retry()
	fake.offline = true
	var r := await social.refresh_friends()
	eq(r.error, NetApiResult.NETWORK)
	eq(NetSocialClient.error_text(r), NetSession.TEXT["network"])


func test_another_account_clears_the_lists() -> void:
	_friends_setup()
	fake.make_crew(ME, "Night Riders", "NR")
	await social.refresh_friends()
	await social.refresh_crew()
	check(social.friends.size() > 0 and social.crew != null)
	# The stored account is refused and the player starts a new one.
	(fake.accounts[ME] as Dictionary)["secret"] = "rotated"
	for t: String in fake.refresh_tokens:
		(fake.refresh_tokens[t] as Dictionary)["revoked"] = true
	await session.retry()
	await session.create_new_account()
	ne(session.account_id(), ME)
	await social.refresh_friends()
	eq(social.friends.size(), 0, "the new account's (empty) list")
	check(social.crew == null)


func test_friend_code_validation() -> void:
	for ok: String in ["Name#1", "Name#0042", "Şahin 34#0042", "a b#9999"]:
		check(NetSocialClient.valid_friend_code(ok, tuning), ok)
	for bad: String in ["", "Name", "#1234", "Name#", "Name#12345", "Name#12a", "Name#-1", "Name#+1",
			"ThisNameIsWayTooLong#0001"]:
		check(not NetSocialClient.valid_friend_code(bad, tuning), bad)
	eq(NetSocialClient.normalize_code(" k7qx-2m9p "), "K7QX2M9P")
