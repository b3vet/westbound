extends WBTest
## NetTransport implementations: the loopback link (latency, jitter, loss, ordering, close)
## and the WebSocket transport against an in-process WebSocket server (TCPServer +
## WebSocketPeer.accept_stream) carrying real codec frames. Spec: multiplayer handoff →
## Networking protocol → Client transport interface; Testing (simulated link). WP N2.2.

const WS_TIMEOUT_MS := 3000
const LOCAL_HOST := "127.0.0.1"

var tuning: NetTuning
var _tcp: TCPServer


func before_all() -> void:
	tuning = NetTuning.load_default()


func after_each() -> void:
	if _tcp != null:
		_tcp.stop()
		_tcp = null


# ---------------------------------------------------------------- Loopback

func _link(seed_value: int = 1) -> Array:
	var time := NetVirtualTime.new(1_000_000)
	var link := NetLoopbackLink.new(time, Rng.new(seed_value))
	return [time, link]


func _open(time: NetVirtualTime, link: NetLoopbackLink) -> void:
	link.client.connect_to_url("loop://server")
	time.advance_s(maxf(link.latency_s * 2.0, 0.001))
	link.client.poll()
	link.server.poll()


func test_loopback_opens_after_a_round_trip_and_delivers_after_latency() -> void:
	var l := _link()
	var time: NetVirtualTime = l[0]
	var link: NetLoopbackLink = l[1]
	link.latency_s = 0.1
	var states: Array[int] = []
	link.client.state_changed.connect(func(s: int) -> void: states.append(s))
	eq(link.client.connect_to_url("loop://server"), OK)
	eq(link.client.get_state(), NetTransport.State.CONNECTING)
	eq(link.client.send(PackedByteArray([1])), ERR_UNCONFIGURED, "no send before OPEN")
	time.advance_s(0.19)
	link.client.poll()
	eq(link.client.get_state(), NetTransport.State.CONNECTING, "not yet")
	time.advance_s(0.02)
	link.client.poll()
	link.server.poll()
	check(link.client.is_open() and link.server.is_open(), "both ends open after one RTT")
	eq(states, [NetTransport.State.CONNECTING, NetTransport.State.OPEN] as Array[int])
	eq(link.client.send(PackedByteArray([1, 2, 3])), OK)
	time.advance_s(0.099)
	eq(link.server.poll().size(), 0, "in flight")
	time.advance_s(0.002)
	var got := link.server.poll()
	if eq(got.size(), 1, "arrives after the latency"):
		eq(got[0], PackedByteArray([1, 2, 3]))
	eq(link.client.send(PackedByteArray()), ERR_INVALID_PARAMETER, "empty frame")
	var big := PackedByteArray()
	big.resize(NetCodec.MAX_FRAME_LEN + 1)
	eq(link.client.send(big), ERR_INVALID_PARAMETER, "oversized frame")


func test_loopback_loss_and_jitter_statistics() -> void:
	var l := _link(99)
	var time: NetVirtualTime = l[0]
	var link: NetLoopbackLink = l[1]
	link.latency_s = 0.075
	_open(time, link)
	link.jitter_s = 0.015
	link.loss = 0.02
	var n := 5000
	var send_us := {}
	var received := 0
	var reordered := 0
	var last := -1
	var min_d := INF
	var max_d := 0.0
	for k in n + 200:
		if k < n:
			var frame := PackedByteArray()
			frame.resize(4)
			frame.encode_u32(0, k)
			send_us[k] = time.usec
			link.client.send(frame)
		time.advance_s(0.001)
		for f in link.server.poll():
			var id := f.decode_u32(0)
			var d := (time.usec - int(send_us[id])) / 1.0e6
			min_d = minf(min_d, d)
			max_d = maxf(max_d, d)
			received += 1
			if id < last:
				reordered += 1
			last = maxi(last, id)
	var lost := n - received
	eq(lost, link.lost_frames, "lost frames are counted")
	within_pct(float(lost), n * 0.02, 0.35, "about 2 % lost")
	gt(reordered, 0, "jitter reorders a datagram link")
	ge(min_d, 0.075 - 0.015 - 0.002, "delay floor")
	le(max_d, 0.075 + 0.015 + 0.002, "delay ceiling (1 ms poll granularity)")


func test_loopback_ordered_link_keeps_send_order() -> void:
	var l := _link(5)
	var time: NetVirtualTime = l[0]
	var link: NetLoopbackLink = l[1]
	link.latency_s = 0.05
	_open(time, link)
	link.jitter_s = 0.04
	link.ordered = true
	for i in 500:
		link.client.send(PackedByteArray([i & 0xFF, i >> 8]))
		time.advance_s(0.001)
	var ids := []
	for k in 200:
		time.advance_s(0.001)
		for f in link.server.poll():
			ids.append(f[0] | (f[1] << 8))
	eq(ids.size(), 500, "nothing lost")
	var sorted := ids.duplicate()
	sorted.sort()
	eq(ids, sorted, "in send order")


func test_loopback_close_after_in_flight_frames() -> void:
	var l := _link()
	var time: NetVirtualTime = l[0]
	var link: NetLoopbackLink = l[1]
	link.latency_s = 0.05
	_open(time, link)
	link.server.send(PackedByteArray([9]))
	link.server.close(1001, "going away")
	eq(link.server.get_state(), NetTransport.State.CLOSED)
	time.advance_s(0.06)
	var got := link.client.poll()
	eq(got.size(), 1, "the frame sent before close still arrives")
	eq(link.client.get_state(), NetTransport.State.CLOSED, "then the close")
	eq(link.client.close_code, 1001)
	eq(link.client.close_reason, "going away")


func test_loopback_is_deterministic_by_seed() -> void:
	var hashes := PackedInt64Array()
	for run in 2:
		var l := _link(1234)
		var time: NetVirtualTime = l[0]
		var link: NetLoopbackLink = l[1]
		link.latency_s = 0.075
		_open(time, link)
		link.jitter_s = 0.015
		link.loss = 0.1
		var h := TraceHash.SEED
		for i in 300:
			link.client.send(PackedByteArray([i & 0xFF]))
			time.advance_s(0.003)
			for f in link.server.poll():
				h = TraceHash.mix_int(TraceHash.mix_int(h, f[0]), time.usec)
		hashes.append(h)
	eq(hashes[0], hashes[1], "same seed, same deliveries")


# ---------------------------------------------------------------- WebSocket

func _listen() -> int:
	_tcp = TCPServer.new()
	for port in range(28700, 28800):
		if _tcp.listen(port, LOCAL_HOST) == OK:
			return port
	return -1


## Pumps the client transport and the in-process server peer until `done` or timeout.
func _pump(t: NetWsTransport, server_peer: Array, done: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + WS_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		var got := t.poll()
		for f in got:
			server_peer[1].append(f)
		if server_peer[0] == null and _tcp != null and _tcp.is_listening() \
				and _tcp.is_connection_available():
			var ws := WebSocketPeer.new()
			ws.accept_stream(_tcp.take_connection())
			server_peer[0] = ws
		if server_peer[0] != null:
			var ws: WebSocketPeer = server_peer[0]
			ws.poll()
			while ws.get_available_packet_count() > 0:
				server_peer[2].append(ws.get_packet())
		if done.call():
			return true
		OS.delay_msec(1)
	return false


func test_ws_round_trips_codec_frames_with_a_local_server() -> void:
	var port := _listen()
	if not gt(port, 0, "a free local port"):
		return
	var t := NetWsTransport.new(tuning)
	eq(t.send(PackedByteArray([1])), ERR_UNCONFIGURED, "no send before connecting")
	eq(t.connect_to_url("ws://%s:%d/ws" % [LOCAL_HOST, port]), OK)
	eq(t.get_state(), NetTransport.State.CONNECTING)
	# [server WebSocketPeer, frames the client received, frames the server received]
	var peer: Array = [null, [], []]
	var opened := _pump(t, peer, func() -> bool:
		return t.is_open() and peer[0] != null \
			and (peer[0] as WebSocketPeer).get_ready_state() == WebSocketPeer.STATE_OPEN)
	if not check(opened, "WebSocket opened"):
		return
	var codec := NetCodec.new()
	var st := NetPlayerState.new()
	st.set_physical(123456, 12345.678, -1.75, 0.0873, 69.44, -0.42, 0.118, -0.125,
		NetCodec.PLAYER_FLAG_BOOST, 2)
	codec.push_player_state(st)
	codec.push({"type": "ping", "client_time_ms": 77}, NetCodec.Direction.CLIENT_TO_SERVER)
	var up := codec.finish_frame()
	eq(t.send(up), OK)
	var server_ws: WebSocketPeer = peer[0]
	check(_pump(t, peer, func() -> bool: return (peer[2] as Array).size() >= 1), "server got it")
	if (peer[2] as Array).size() >= 1:
		eq(peer[2][0], up, "byte-identical upstream frame")
		var msgs := codec.decode_frame(peer[2][0], NetCodec.Direction.CLIENT_TO_SERVER)
		eq(msgs.size(), 2)
	# Downstream: a binary frame decodes; a text frame closes the connection (1003).
	var down := codec.encode_frame([{"type": "pong", "client_time_ms": 77, "server_tick": 5,
		"tick_fraction": 0}], NetCodec.Direction.SERVER_TO_CLIENT)
	server_ws.send(down, WebSocketPeer.WRITE_MODE_BINARY)
	check(_pump(t, peer, func() -> bool: return (peer[1] as Array).size() >= 1), "client got it")
	if (peer[1] as Array).size() >= 1:
		eq(peer[1][0], down, "byte-identical downstream frame")
	server_ws.send_text("hello")
	var closed := _pump(t, peer, func() -> bool:
		return t.get_state() == NetTransport.State.CLOSED)
	check(closed, "a text frame closes the connection")
	eq(t.close_code, NetWsTransport.CLOSE_UNSUPPORTED_DATA, "closed with 1003")
	eq(t.send(down), ERR_UNCONFIGURED, "no send after close")


func test_ws_client_close() -> void:
	var port := _listen()
	if not gt(port, 0, "a free local port"):
		return
	var t := NetWsTransport.new(tuning)
	eq(t.connect_to_url("ws://%s:%d/ws" % [LOCAL_HOST, port]), OK)
	var peer: Array = [null, [], []]
	if not check(_pump(t, peer, func() -> bool: return t.is_open()), "opened"):
		return
	t.close(1000, "bye")
	check(_pump(t, peer, func() -> bool: return t.get_state() == NetTransport.State.CLOSED),
		"closed")
	eq(t.close_code, 1000)
	eq(t.connect_to_url("ws://%s:%d/ws" % [LOCAL_HOST, port]), OK, "reusable after close")
	t.close()


func test_ws_refused_connection_ends_closed() -> void:
	var port := _listen()
	if not gt(port, 0, "a free local port"):
		return
	_tcp.stop()   # nothing listens there any more
	_tcp = null
	var t := NetWsTransport.new(tuning)
	eq(t.connect_to_url("ws://%s:%d/ws" % [LOCAL_HOST, port]), OK)
	var peer: Array = [null, [], []]
	check(_pump(t, peer, func() -> bool: return t.get_state() == NetTransport.State.CLOSED),
		"refused → CLOSED")
