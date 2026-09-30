extends WBTest
## NetRoomSession against a scripted room server on the loopback link: joins, the room
## state, placements (each placement tick once), the 20 Hz upload stamped with room ticks,
## refusals, room events, run results, quick chat and mute, the reconnect state machine
## (seat kept within 15 s, lost after), and the room clock. Spec: multiplayer handoff →
## Players, Rooms, parties and matchmaking, Time of day in multiplayer; docs/PROTOCOL.md
## §12 (placement); docs/SERVER.md → Rooms → For the client. WP N5.2.

const FakeRoomServer := preload("res://tests/net/fake_room_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const STEP_S := 0.01
const L := 25000.0

var tuning: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var token: String = "token"
var log: Array[String] = []
var results: Array[Dictionary] = []
var chats: Array[String] = []


func before_all() -> void:
	tuning = NetTuning.load_default()


func before_each() -> void:
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(11))
	link.latency_s = 0.04
	link.ordered = true
	server = FakeRoomServer.new(link)
	rs = NetRoomSession.new(link.client, tuning, L, time)
	rs.configure("loop://rooms", 3, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return token)
	token = "token"
	log.clear()
	results.clear()
	chats.clear()
	rs.joined.connect(func(r: NetRoomState) -> void: log.append("joined %s" % r.code))
	rs.rejoined.connect(func(r: NetRoomState) -> void: log.append("rejoined %s" % r.code))
	rs.join_failed.connect(func(c: String, _m: String) -> void: log.append("join_failed %s" % c))
	rs.left.connect(func(r: String, _m: String) -> void: log.append("left %s" % r))
	rs.reconnecting.connect(func(on: bool) -> void: log.append("reconnecting %s" % on))
	rs.run_result.connect(func(r: Dictionary) -> void: results.append(r))
	rs.chat.connect(func(_p: int, text: String) -> void: chats.append(text))


func after_each() -> void:
	rs = null
	server = null
	link = null
	time = null


func _run(seconds: float) -> void:
	for i in roundi(seconds / STEP_S):
		time.advance_s(STEP_S)
		server.call("poll")
		rs.poll()


func _join() -> void:
	rs.quick_join()
	_run(0.5)


func _send(msgs: Array) -> void:
	server.call("send", msgs)


# ---------------------------------------------------------------- Join

func test_quick_join_enters_the_room() -> void:
	var seen: Array[NetRoomSession.State] = []
	rs.state_changed.connect(func(s: NetRoomSession.State) -> void: seen.append(s))
	rs.quick_join()
	eq(rs.state, NetRoomSession.State.CONNECTING)
	_run(0.5)
	eq(rs.state, NetRoomSession.State.IN_ROOM)
	eq(seen, [NetRoomSession.State.CONNECTING, NetRoomSession.State.LOBBY, NetRoomSession.State.JOINING,
		NetRoomSession.State.IN_ROOM] as Array[NetRoomSession.State])
	eq(log, ["joined ABC234"] as Array[String])
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins.size(), 1, "one quick_join")
	eq(joins[0]["kind"], "quick_join")
	var r := rs.room
	eq(r.code, "ABC234")
	eq(r.room_id, 12)
	eq(r.you, 1)
	eq(r.host_id, 0)
	check(not r.is_host())
	eq(r.members.size(), 2)
	eq(r.me().full_name(), "Zoe#0007")
	eq(r.member(0).nametag(), "Dusty#1234 [WB]")
	eq(r.member(0).crew_color, 3, "the crew's color index")
	eq(r.players_text(), "2/8")


func test_create_code_and_id_send_their_commands() -> void:
	rs.create_room("rush", "fixed", 1_140_000)
	_run(0.5)
	rs.leave()
	_run(0.3)
	rs.join_code(" abc-234 ")
	_run(0.5)
	rs.leave()
	_run(0.3)
	rs.join_id(77)
	_run(0.5)
	var joins: Array[Dictionary] = server.get("joins")
	if not eq(joins.size(), 3):
		return
	eq(joins[0], {"type": "lobby_command", "kind": "room_create", "visibility": "private", "max_players": 8,
		"density": "rush", "time_mode": "fixed", "fixed_cycle_ms": 1_140_000})
	eq(joins[1]["code"], "ABC234", "normalized code")
	eq(joins[2]["room_id"], 77)
	eq(server.get("leaves"), 2)
	check(NetRoomSession.is_valid_code("ABC234"))
	check(not NetRoomSession.is_valid_code("ABC23O"), "no O")
	check(not NetRoomSession.is_valid_code("ABC23"))


func test_refusals_and_timeouts_come_back_to_the_lobby() -> void:
	server.set("refuse_join", "room_not_found")
	rs.join_code("ZZZ999")
	_run(0.5)
	eq(rs.state, NetRoomSession.State.LOBBY)
	eq(log, ["join_failed room_not_found"] as Array[String])
	eq(rs.last_message, "No room with that code.")
	server.set("answer_joins", false)
	rs.quick_join()
	_run(tuning.room_join_timeout_s + 0.5)
	eq(log.back(), "join_failed join_timeout")
	eq(rs.state, NetRoomSession.State.LOBBY)


func test_already_in_room_leaves_and_retries_once() -> void:
	server.set("refuse_join", "already_in_room")
	rs.quick_join()
	_run(0.5)
	eq(rs.state, NetRoomSession.State.IN_ROOM, "joined on the second try")
	var cmds: Array[Dictionary] = server.get("lobby_commands")
	var kinds: Array[String] = []
	for c in cmds:
		kinds.append(String(c["kind"]))
	eq(kinds, ["quick_join", "room_leave", "quick_join"] as Array[String])


func test_browse_lists_rooms() -> void:
	var got: Array[int] = []
	rs.room_list.connect(func(rooms: Array[Dictionary]) -> void:
		for r in rooms:
			got.append(int(r["room_id"])))
	rs.browse()
	_run(0.5)
	eq(got, [7, 9] as Array[int])
	eq(rs.state, NetRoomSession.State.LOBBY, "browsing stays in the lobby")


# ---------------------------------------------------------------- Placement and upload

func test_placement_is_taken_once_per_tick() -> void:
	_join()
	check(rs.has_placement(), "the join frame places us")
	var t0 := rs.placement_tick
	near(rs.placement_s, 1000.0, 1e-9)
	near(rs.placement_d, 3.5, 1e-9, "d unchanged: + right of travel")
	near(rs.placement_speed, 30.0, 1e-9)
	check(rs.take_placement())
	check(not rs.take_placement(), "taken")
	# The server repeats it every tick until answered: not a new placement.
	_send([server.call("placement", t0)])
	_run(0.2)
	check(not rs.has_placement(), "the same placement tick is applied once")
	# A respawn later: a new placement tick.
	_send([server.call("placement", t0 + 60, 2_000_000)])
	_run(0.2)
	check(rs.has_placement())
	eq(rs.placement_tick, t0 + 60)
	near(rs.placement_s, 2000.0, 1e-9)


func test_states_are_stamped_with_room_ticks_once_per_tick() -> void:
	_join()
	_run(0.3)   # the clock sample after the join ping
	var now := rs.server_tick()
	check(now > 0.0, "the room clock is synced")
	near(now, float(server.call("server_ticks")), 0.1, "server_now() tracks the room tick")
	var tick := floori(now)
	check(rs.send_state(tick, L * 2.0 + 1234.5, -2.25, 0.01, 40.0, 0.2, 0.0, 0.1, 0, NetRoomSession.RUN_DRIVING))
	check(not rs.send_state(tick, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 2), "one state per tick")
	check(rs.send_state(tick + 1, 1236.5, -2.25, 0.01, 40.0, 0.2, 0.0, 0.1, 0, NetRoomSession.RUN_DRIVING))
	_run(0.2)
	var states: Array[Dictionary] = server.get("states")
	if not eq(states.size(), 2):
		return
	eq(states[0]["tick"], tick)
	eq(states[0]["s_mm"], 1234500, "s wrapped into [0, L) before quantizing")
	eq(states[0]["d_cm"], -225, "d as the contract's")
	eq(states[0]["run_state"], "driving")
	eq(states[1]["tick"], tick + 1)


func test_nothing_is_sent_outside_a_room() -> void:
	check(not rs.send_state(5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 2))
	check(not rs.send_hit(5, "traffic", 1, 0))
	check(not rs.send_chat(NetRoomChat.horn_item()))


func test_hits_run_events_and_chat_reach_the_server() -> void:
	_join()
	check(rs.send_hit(500, "traffic", 412, 0))
	check(rs.send_run_event("rejoin", 510))
	check(rs.send_chat(NetRoomChat.phrase_item(3)))
	check(not rs.send_chat(NetRoomChat.horn_item()), "rate-limited on the device")
	_run(tuning.room_chat_interval_s)
	check(rs.send_chat(NetRoomChat.emote_item(1)))
	_run(0.2)
	var hits: Array[Dictionary] = server.get("hits")
	eq(hits, [{"type": "hit_report", "tick": 500, "target": "traffic", "car_id": 412, "lives_left": 0}] as Array[Dictionary])
	var ev: Array[Dictionary] = server.get("run_events")
	eq(ev[0]["kind"], "rejoin")
	var ch: Array[Dictionary] = server.get("chats")
	eq(ch.size(), 2)
	eq(ch[0]["item"], {"kind": "phrase", "phrase": "regroup"})
	eq(ch[1]["item"], {"kind": "emote", "emote": 1})


# ---------------------------------------------------------------- Room traffic

func test_room_events_results_and_chat() -> void:
	_join()
	_send([{"type": "room_event", "kind": "join", "player_id": 2, "identity": {"account_id": "78",
		"display_name": "Kai", "name_tag": 55}, "crew_tag": "JDM", "crew_slot": 1,
		"flags": {"host": false, "disconnected": false}},
		server.call("other_state", 2, 10, 5000, 350, 3000)])
	_run(0.2)
	eq(rs.room.members.size(), 3)
	check(rs.remotes.slot_of(2) >= 0, "Kai has a track")
	check(rs.remotes.slot_of(0) < 0, "Dusty sent nothing yet")
	_send([{"type": "room_event", "kind": "connection", "player_id": 2, "connected": false}])
	_run(0.2)
	check(rs.room.member(2).disconnected)
	_send([{"type": "room_event", "kind": "host_change", "player_id": 1}])
	_run(0.2)
	check(rs.room.is_host(), "the host passed to us")
	_send([{"type": "room_event", "kind": "leave", "player_id": 2, "reason": "timed_out"}])
	_run(0.2)
	eq(rs.room.members.size(), 2)
	eq(rs.remotes.slot_of(2), -1, "the slot is free again")
	_send([{"type": "run_result", "player_id": 1, "run_seq": 1, "end_reason": "crashed",
		"flags": {"verified": true, "leaderboard_eligible": true}, "score": 0, "duration_ms": 30000,
		"distance_m": 1500, "passes": 0, "close_passes": 0, "cuts": 0, "threads": 0, "trains": 0,
		"max_multiplier_milli": 1000}])
	_send([{"type": "quick_chat", "player_id": 0, "item": {"kind": "phrase", "phrase": "gg"}}])
	_run(0.2)
	eq(results.size(), 1)
	eq(results[0]["distance_m"], 1500)
	eq(chats, ["GG"] as Array[String])
	eq(rs.room.member(0).chat_text, "GG", "shown on the nametag")
	rs.set_muted(0, true)
	_send([{"type": "quick_chat", "player_id": 0, "item": {"kind": "horn"}}])
	_run(0.2)
	eq(chats.size(), 1, "a muted player's chat is not shown")


func test_kick_sends_back_to_the_hub() -> void:
	_join()
	_send([{"type": "lobby_event", "kind": "room_left", "reason": "kicked"}])
	_run(0.2)
	eq(rs.state, NetRoomSession.State.LOBBY)
	eq(log.back(), "left kicked")
	eq(rs.last_message, "The host removed you from the room.")


# ---------------------------------------------------------------- Reconnect

func test_reconnect_within_the_hold_keeps_the_seat() -> void:
	_join()
	rs.take_placement()
	server.call("drop")
	_run(0.2)
	eq(rs.state, NetRoomSession.State.RECONNECTING)
	eq(log.back(), "reconnecting true")
	check(rs.has_room(), "the run keeps driving")
	check(rs.reconnect_left_s() > tuning.room_reconnect_window_s - 1.0)
	_run(1.5)
	eq(rs.state, NetRoomSession.State.IN_ROOM, "back in")
	eq(log.slice(-2), ["reconnecting false", "rejoined ABC234"])
	var joins: Array[Dictionary] = server.get("joins")
	eq(joins.back()["kind"], "room_join_code", "rejoin by code")
	eq(joins.back()["code"], "ABC234")
	check(rs.has_placement(), "placed where the car was")


func test_reconnect_gives_up_after_the_hold() -> void:
	_join()
	link.refuse = true
	server.call("drop")
	_run(tuning.room_reconnect_window_s - 1.0)
	eq(rs.state, NetRoomSession.State.RECONNECTING, "still trying")
	check(rs.reconnect_left_s() <= 1.1, "the hold counts down")
	_run(1.5)
	eq(rs.state, NetRoomSession.State.IDLE)
	eq(log.back(), "left seat_lost")
	eq(rs.last_message, "Lost the connection to the room.")
	check(not rs.has_room())


func test_a_ban_is_not_retried() -> void:
	_join()
	token = "banned-token"
	server.call("drop")
	_run(2.0)
	eq(rs.state, NetRoomSession.State.FAILED)
	eq(log.back(), "left banned")


# ---------------------------------------------------------------- The room clock

func test_room_clock_follows_the_server() -> void:
	var r := NetRoomState.new()
	r.tick_rate = 20.0
	r.apply_snapshot({"room_id": 1, "code": "ABC234", "you": 0, "tick": 1000,
		"settings": {"visibility": "public", "max_players": 8, "density": "normal", "time_mode": "cycle", "fixed_cycle_ms": 0},
		"clock": {"cycle_ms": 1_319_000, "cycle_len_ms": 1_920_000, "day_len_ms": 1_320_000}, "members": [], "crews": []})
	near(r.cycle_ms_at(1000.0), 1_319_000.0, 1e-6)
	near(r.cycle_ms_at(1010.0), 1_319_500.0, 1e-6, "20 ticks per second")
	check(not r.is_night_at(1019.0))
	check(r.is_night_at(1021.0), "night x2 when cycle_ms >= day_len_ms")
	near(r.cycle_ms_at(1000.0 + 20.0 * 602.0), 1_000.0, 1e-6, "wraps at the cycle length")
	r.apply_event({"type": "room_event", "kind": "settings", "tick": 2000,
		"settings": {"visibility": "private", "max_players": 8, "density": "rush", "time_mode": "night", "fixed_cycle_ms": 0},
		"clock": {"cycle_ms": 1_620_000, "cycle_len_ms": 1_920_000, "day_len_ms": 1_320_000}})
	near(r.cycle_ms_at(9000.0), 1_620_000.0, 1e-6, "night mode holds")
	eq(r.density, "rush")
	var loop_t := LoopTuning.load_default()
	near(loop_t.room_cycle_s() * 1000.0, 1_920_000.0, 1e-6, "the loop's cycle is the server's")
	near(loop_t.room_day_s() * 1000.0, 1_320_000.0, 1e-6)
