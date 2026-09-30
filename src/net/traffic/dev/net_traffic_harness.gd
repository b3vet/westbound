class_name NetTrafficHarness
extends RefCounted
## The client's network traffic against the fake authority over a simulated link, on a
## virtual clock: the netcode harness of the traffic sandbox's network mode and of
## tests/net/test_network_traffic.gd. Spec: multiplayer handoff → Client network traffic,
## Networking protocol (Clock sync, one frame per tick), Testing (Netcode harness; client:
## "a recorded server stream replayed through it keeps error within the thresholds").
## docs/NET_TRAFFIC.md → The harness. WP N4.3. Dev and test fixture only.
##
##   var h := NetTrafficHarness.new(tuning, road, car_state, 4.5, 1.9, seed)
##   # every 120 Hz tick, after the caller moved `player`:
##   h.advance(1.0 / 120.0)            # server ticks, the link, the clock, the client step
##   h.client_state                     # what the client shows (TrafficState)
##   h.source.stats / h.truth           # corrections, teleports / error against the server
##
## Events are processed in time order at their exact virtual time: uplink frames reaching
## the server (pings answered at once with a Pong; PlayerStates become the authority's
## view of the player), the server's 20 Hz ticks (one frame each), downlink frames reaching
## the client (Pongs feed NetClock; traffic goes to NetworkTrafficSource.apply_frame at
## server_now()). The client sends a PlayerState every server tick and a Ping every
## ping_interval_s, and joins (traffic starts) after `join_s` so the clock has a sample.
## `record`: every apply_frame / step call is logged (bytes, times, the player) for replay.

const TICKS_PER_SAMPLE := 6   # truth samples every 6th client tick (20 Hz at 120 Hz)
const RUN_STATE_DRIVING := 2

var net: NetTuning
var road: RoadPath
var time: NetVirtualTime
var authority: FakeTrafficAuthority
var down: NetDelayLink
var up: NetDelayLink
var clock: NetClock
var source: NetworkTrafficSource
var registry: TrafficRegistry
var client_state: TrafficState
var player: VehicleState
var events: ScoreEventBuffer
## What the client shows against the server's truth at the same true time (cars within
## the near radius): the visual error including the clock's.
var truth: NetTrafficStats
var join_s: float = 1.0
var record: bool = false
## [["frame", bytes, player_s, now, one_way], ["step", now, s, d, v, v_lat, yaw], ...]
var trace_log: Array = []
var frame := NetServerFrame.new()
var client_frames: int = 0
var client_frame_errors: int = 0

var _codec := NetCodec.new()
var _up_codec := NetCodec.new()
var _srv_codec := NetCodec.new()
var _ps := NetPlayerState.new()
var _start_usec: int
var _tick_usec: int
var _next_tick_usec: int
var _next_state_usec: int
var _next_ping_usec: int
var _ping_usec: int
var _join_usec: int
var _client_ticks: int = 0
var _near_m: float
var _gen_ahead: float


func _init(base: Tuning, road_path: RoadPath, player_state: VehicleState, player_length_m: float,
		player_width_m: float, seed_value: int, mode: NetDelayLink.Mode = NetDelayLink.Mode.STREAM,
		with_loss: bool = true, published: TrafficState = null) -> void:
	net = base.net
	road = road_path
	player = player_state
	_near_m = net.traffic_correction_near_m
	# The client's lane-drop zones look this far ahead (an open road generates as it goes).
	var t := base.traffic
	_gen_ahead = net.traffic_aoi_ahead_m + t.lane_drop_view_m + t.lane_drop_merge_zone_m * 2.0 \
		+ t.lane_drop_narrow_max_m
	_start_usec = 1_000_000_000
	time = NetVirtualTime.new(_start_usec)
	var root := Rng.new(seed_value)
	down = NetDelayLink.new(root.derive(&"down"))
	up = NetDelayLink.new(root.derive(&"up"))
	down.configure(net, mode, with_loss)
	up.configure(net, mode, with_loss)
	authority = FakeTrafficAuthority.new(base, road, seed_value, player.s, player_length_m, player_width_m)
	clock = NetClock.new(net, time)
	registry = TrafficRegistry.load_default(base.traffic)
	client_state = published if published != null else TrafficState.new(base.traffic.max_active_vehicles)
	source = NetworkTrafficSource.new(net, base.traffic, road, registry, client_state)
	source.set_headway_scale(authority.headway_scale())
	source.set_player_body(player_length_m, player_width_m)
	events = ScoreEventBuffer.new(base.scoring.event_buffer_capacity)
	truth = NetTrafficStats.new(net.traffic_metrics_window_s)
	_tick_usec = roundi(NetClock.USEC_PER_S / net.tick_rate_hz)
	_next_tick_usec = _start_usec + _tick_usec
	_next_state_usec = _start_usec
	_ping_usec = roundi(net.ping_interval_s * NetClock.USEC_PER_S)
	_next_ping_usec = _start_usec
	_join_usec = _start_usec + roundi(join_s * NetClock.USEC_PER_S)


## Seconds since the room started (virtual).
func elapsed_s() -> float:
	return float(time.usec - _start_usec) / NetClock.USEC_PER_S


## The server's true clock now (ticks).
func true_server_ticks() -> float:
	return elapsed_s() * net.tick_rate_hz


## One client tick of `dt_s`: every server and link event up to then in time order, the
## client's uplink, then the client's step (the caller moved `player` before).
func advance(dt_s: float) -> void:
	road.ensure_generated_to(player.s + _gen_ahead)
	var target := time.usec + roundi(dt_s * NetClock.USEC_PER_S)
	while true:
		var t_up := up.next_due()
		var t_down := down.next_due()
		var t_tick := _next_tick_usec
		var t := mini(mini(t_up, t_down), t_tick)
		if t > target:
			break
		time.usec = t
		if t == t_tick:
			_server_tick()
		elif t == t_up:
			_server_receive(up.take())
		else:
			_client_receive(down.take())
	time.usec = target
	if not authority.joined and target >= _join_usec and clock.has_sync():
		authority.joined = true
	if target >= _next_state_usec:
		_send_player_state()
		_next_state_usec += _tick_usec
	if target >= _next_ping_usec:
		_up_codec.clear_frame()
		_up_codec.push({"type": "ping", "client_time_ms": clock.ping_time_ms()}, NetCodec.Direction.CLIENT_TO_SERVER)
		up.send(_up_codec.finish_frame(), time.usec)
		_next_ping_usec += _ping_usec
	if clock.has_sync():
		var now := clock.server_now()
		if record:
			trace_log.append(["step", now, player.s, player.d, player.v, player.v_lat, player.yaw])
		source.step(now, player, events)
		events.clear()
		_client_ticks += 1
		if authority.joined and _client_ticks % TICKS_PER_SAMPLE == 0:
			_sample_truth()


func _server_tick() -> void:
	_next_tick_usec += _tick_usec
	var f := authority.step()
	if not f.is_empty():
		down.send(f, time.usec)


func _server_receive(bytes: PackedByteArray) -> void:
	var msgs := _srv_codec.decode_frame(bytes, NetCodec.Direction.CLIENT_TO_SERVER)
	for m in msgs:
		match String(m["type"]):
			"ping":
				down.send(authority.pong_frame(int(m["client_time_ms"]), elapsed_s()), time.usec)
			"player_state":
				if _ps.from_dict(m) == "":
					authority.receive_player_state(_ps)


func _client_receive(bytes: PackedByteArray) -> void:
	var err := _codec.decode_server_frame_into(bytes, frame)
	client_frames += 1
	if err != "":
		client_frame_errors += 1
		return
	for m in frame.messages:
		if String(m["type"]) == "pong":
			clock.on_pong(int(m["client_time_ms"]), int(m["server_tick"]), int(m["tick_fraction"]))
	if frame.order_count_total == frame.messages.size() or not clock.has_sync():
		return
	var now := clock.server_now()
	var one_way := clock.best_rtt_s * 0.5 * clock.tick_rate()
	if record:
		trace_log.append(["frame", bytes, player.s, now, one_way])
	source.note_frame_bytes(bytes.size())
	source.apply_frame(frame, player.s, now, one_way)


func _send_player_state() -> void:
	if not clock.has_sync():
		return
	var err := _ps.set_physical(floori(clock.server_now()), NetTrafficWire.s_wrap(road, player.s), player.d,
		player.yaw, player.v, player.v_lat, player.yaw_rate, 0.0, 0, RUN_STATE_DRIVING)
	if err != "":
		return
	_up_codec.clear_frame()
	_up_codec.push_player_state(_ps)
	up.send(_up_codec.finish_frame(), time.usec)


## Every client car near the player against the server's car at the same true time.
func _sample_truth() -> void:
	var st := client_state
	var srv := authority.sim.state
	var t_true := true_server_ticks()
	var lag := (t_true - float(authority.tick)) / net.tick_rate_hz
	for i in st.capacity:
		if st.active[i] == 0 or absf(st.s[i] - player.s) > _near_m:
			continue
		var j := authority.slot_of_car(source.car_id(i))
		if j < 0:
			continue
		var ts := NetTrafficWire.s_unwrap(road, srv.s[j] + srv.v[j] * lag + 0.5 * srv.accel[j] * lag * lag, player.s)
		var es := st.s[i] - ts
		var ed := st.d[i] - (srv.d[j] + srv.v_lat[j] * lag)
		truth.add_correction(sqrt(es * es + ed * ed), ed, true)
