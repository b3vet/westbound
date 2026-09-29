extends WBTest
## NetClient: handshake and keepalive against a scripted server on the loopback transport.
## Spec: multiplayer handoff → Networking protocol → Connection (Hello {protocol_version,
## client_build, map_hash} → Welcome or Error; "please update"; ping every 2 s, dead after
## 8 s of silence); docs/PROTOCOL.md §1, §5. WP N2.2.

const FakeServer := preload("res://tests/net/fake_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const STEP_S := 0.01
const CLIENT_BUILD := 10203

var tuning: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var client: NetClient
var failures: Array[String] = []
var server_errors: Array[String] = []
var frames_seen: int = 0


func before_all() -> void:
	tuning = NetTuning.load_default()


func before_each() -> void:
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(7))
	link.latency_s = 0.05
	server = FakeServer.new(link)
	client = NetClient.new(link.client, tuning, time)
	failures.clear()
	server_errors.clear()
	frames_seen = 0
	client.failed.connect(func(reason: String, _m: String) -> void: failures.append(reason))
	client.server_error.connect(func(code: String, _f: bool, _d: String) -> void:
		server_errors.append(code))
	client.frame_received.connect(func(_f: NetServerFrame) -> void: frames_seen += 1)


## Drops the client (its signal lambdas reference this test) and the link.
func after_each() -> void:
	client = null
	server = null
	link = null
	time = null


func _run(seconds: float) -> void:
	for i in roundi(seconds / STEP_S):
		time.advance_s(STEP_S)
		server.call("poll")
		client.poll()


func _start(token: String = "token", build: int = CLIENT_BUILD,
		hash_hex: String = MAP_HASH) -> void:
	eq(client.start("loop://test", build, NetCodec.hex_to_bytes(hash_hex), token), OK, "start")


func test_handshake_welcome() -> void:
	_start()
	eq(client.get_state(), NetClient.State.CONNECTING)
	_run(1.0)
	if not eq(client.get_state(), NetClient.State.READY, "ready after Welcome"):
		return
	var hellos: Array[Dictionary] = server.get("hellos")
	if eq(hellos.size(), 1, "one Hello"):
		var h := hellos[0]
		eq(h["protocol_version"], NetCodec.PROTOCOL_VERSION, "Hello.protocol_version")
		eq(h["client_build"], CLIENT_BUILD, "Hello.client_build")
		eq(h["map_hash"], MAP_HASH, "Hello.map_hash")
		eq(h["access_token"], "token", "Hello.access_token")
	eq(client.account_id, "9223372036854775807", "full 64-bit account id")
	eq(client.welcome["tick_rate_hz"], 20)
	check(client.clock.has_sync(), "the first Pong synced the clock")
	eq(failures.size(), 0)


func test_keepalive_pings_every_2s_and_stays_alive() -> void:
	_start()
	_run(1.0)
	var pings_at_ready := client.pings_sent
	eq(pings_at_ready, 1, "a ping right after Welcome")
	_run(20.0)
	var expected := 1 + floori(20.0 / tuning.ping_interval_s)
	check(absi(client.pings_sent - expected) <= 1, "pings every %.0f s: %d (expected ~%d)"
		% [tuning.ping_interval_s, client.pings_sent, expected])
	eq(int(server.get("pings")), client.pings_sent, "every ping reached the server")
	eq(client.pongs_received, client.pings_sent, "every ping answered")
	_run(60.0)
	eq(client.get_state(), NetClient.State.READY, "a minute later, still connected")


func test_dead_after_8s_of_silence() -> void:
	_start()
	_run(1.0)
	check(client.is_ready())
	# Right after a Pong arrives, the server stops answering but keeps the socket open.
	var pongs := client.pongs_received
	while client.pongs_received == pongs:
		_run(STEP_S)
	pongs = client.pongs_received
	var last_pong_us := time.usec
	server.set("answer_pings", false)
	var dead_us := -1
	for i in roundi((tuning.dead_timeout_s + 3.0) / STEP_S):
		_run(STEP_S)
		if client.pongs_received != pongs:
			pongs = client.pongs_received
			last_pong_us = time.usec
		if client.get_state() == NetClient.State.FAILED:
			dead_us = time.usec
			break
	if not gt(dead_us, 0, "declared dead"):
		return
	var silence_s := (dead_us - last_pong_us) / 1.0e6
	near(silence_s, tuning.dead_timeout_s, STEP_S * 1.5,
		"dead after %.0f s without receiving anything" % tuning.dead_timeout_s)
	ge(client.pings_sent, 5, "kept pinging while silent")
	eq(client.failure_reason, NetClient.REASON_TIMEOUT)
	eq(failures, [NetClient.REASON_TIMEOUT] as Array[String])
	check(client.failure_message.contains("Lost connection"), client.failure_message)


func test_dead_link_also_times_out() -> void:
	_start()
	_run(1.0)
	link.down = true
	_run(tuning.dead_timeout_s + 0.5)
	eq(client.failure_reason, NetClient.REASON_TIMEOUT, "a cut link is detected")


func test_update_required_for_an_old_protocol() -> void:
	server.set("min_protocol", NetCodec.PROTOCOL_VERSION + 1)
	server.set("max_protocol", NetCodec.PROTOCOL_VERSION + 1)
	_start()
	_run(1.0)
	eq(client.get_state(), NetClient.State.FAILED)
	eq(client.failure_reason, "update_required")
	eq(server_errors, ["update_required"] as Array[String])
	check(NetClient.needs_update(client.failure_reason))
	check(client.failure_message.contains("update"), client.failure_message)


func test_update_required_for_an_old_build() -> void:
	server.set("min_client_build", CLIENT_BUILD + 1)
	_start()
	_run(1.0)
	eq(client.failure_reason, "update_required")


func test_server_outdated_for_a_newer_client() -> void:
	server.set("max_protocol", NetCodec.PROTOCOL_VERSION - 1)
	server.set("min_protocol", NetCodec.PROTOCOL_VERSION - 1)
	_start()
	_run(1.0)
	eq(client.failure_reason, "server_outdated")
	check(not NetClient.needs_update(client.failure_reason), "not the client's fault")
	check(client.failure_message.contains("try again"), client.failure_message)


func test_map_mismatch() -> void:
	_start("token", CLIENT_BUILD, "ff".repeat(32))
	_run(1.0)
	eq(client.failure_reason, "map_mismatch")
	check(NetClient.needs_update(client.failure_reason))
	check(client.failure_message.contains("map"), client.failure_message)


func test_auth_failures() -> void:
	_start("")
	_run(1.0)
	eq(client.failure_reason, "auth_failed")
	before_each()
	_start("banned-token")
	_run(1.0)
	eq(client.failure_reason, "banned")


func test_non_fatal_error_keeps_the_connection() -> void:
	_start()
	_run(1.0)
	server.call("send", [{"type": "error", "code": "room_full", "fatal": false, "detail": ""}])
	_run(0.5)
	eq(server_errors, ["room_full"] as Array[String])
	eq(client.get_state(), NetClient.State.READY)


func test_malformed_frame_is_fatal() -> void:
	_start()
	_run(1.0)
	server.call("send_raw", NetCodec.hex_to_bytes("490f000501000000"))
	_run(0.5)
	eq(client.failure_reason, NetClient.REASON_MALFORMED)
	eq(link.server.get_state(), NetTransport.State.CLOSED, "the client closed the socket")


func test_frames_after_welcome_are_handed_out() -> void:
	_start()
	_run(1.0)
	server.call("send", [
		{"type": "traffic_despawn", "car_ids": [1, 2]},
		{"type": "server_notice", "kind": "info", "seconds": 0, "text": "hi"},
	])
	_run(0.5)
	eq(frames_seen, 1)
	eq(client.frame.ds_count, 2)
	eq(client.frame.messages.size(), 1)


func test_handshake_timeout_when_the_server_hangs() -> void:
	server.set("silent", true)
	_start()
	_run(tuning.handshake_timeout_s + 1.0)
	eq(client.failure_reason, NetClient.REASON_HANDSHAKE_TIMEOUT)


func test_connection_refused() -> void:
	link.refuse = true
	_start()
	_run(1.0)
	eq(client.failure_reason, NetClient.REASON_CONNECT_FAILED)
	check(client.failure_message.contains("Can't reach"), client.failure_message)


func test_server_close_is_reported() -> void:
	_start()
	_run(1.0)
	link.server.close(1001, "restart")
	_run(0.5)
	eq(client.failure_reason, NetClient.REASON_CLOSED)


func test_close_is_quiet_and_restart_works() -> void:
	_start()
	_run(1.0)
	client.close()
	_run(0.5)
	eq(client.get_state(), NetClient.State.CLOSED)
	eq(failures.size(), 0, "no failure for a deliberate close")
	server.set("established", false)
	_start()
	_run(1.0)
	eq(client.get_state(), NetClient.State.READY, "reconnects")


func test_sends_player_state_and_messages() -> void:
	eq(client.send_player_state(NetPlayerState.new()), NetClient.REASON_NOT_READY)
	_start()
	_run(1.0)
	var st := NetPlayerState.new()
	eq(st.set_physical(10, 100.0, 1.5, 0.01, 30.0, 0.0, 0.0, 0.0, 0, 2), "")
	eq(client.send_player_state(st), "")
	eq(client.send_messages([{"type": "run_event", "kind": "start", "tick": 10}]), "")
	eq(client.send_messages([{"type": "run_event", "kind": "nope", "tick": 10}]),
		NetCodec.E_INVALID_ENUM)
	_run(0.5)
	eq(client.get_state(), NetClient.State.READY)
	eq((server.get("decode_errors") as PackedStringArray).size(), 0)


func test_bad_start_arguments() -> void:
	eq(client.start("loop://x", 1, PackedByteArray([1, 2, 3]), "t"), ERR_INVALID_PARAMETER)
	eq(client.start("loop://x", -1, NetCodec.hex_to_bytes(MAP_HASH), "t"),
		ERR_INVALID_PARAMETER)
	eq(client.start("loop://x", 1, NetCodec.hex_to_bytes(MAP_HASH), "bad token"),
		ERR_INVALID_PARAMETER, "tokens are printable ASCII without spaces")
	eq(client.get_state(), NetClient.State.IDLE)


func test_user_messages() -> void:
	for code: String in ["update_required", "server_outdated", "map_mismatch", "auth_failed",
			"banned", NetClient.REASON_TIMEOUT, NetClient.REASON_CONNECT_FAILED]:
		check(not NetClient.user_message(code).is_empty(), code)
	eq(NetClient.user_message("internal"), NetClient.user_message("something_new"),
		"unknown codes get the generic text")


func test_tuning_holds_the_spec_numbers() -> void:
	check(tuning != null, "data/tuning/net.tres loads")
	eq(tuning.ping_interval_s, 2.0, "ping every 2 s")
	eq(tuning.dead_timeout_s, 8.0, "dead after 8 s")
	eq(tuning.clock_samples, 8, "8 clock samples")
	eq(tuning.tick_rate_hz, 20.0, "20 Hz ticks")
	eq(tuning.server_url, "wss://westbound.sipsakrandevu.com/ws")
	lt(tuning.clock_slew_max_rate, 1.0, "slewing can never run the clock backward")
	ge(tuning.ws_inbound_buffer_kb * 1024, NetCodec.MAX_FRAME_LEN, "inbound buffer fits a frame")
