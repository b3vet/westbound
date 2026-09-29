extends WBTest
## NetClock: Ping/Pong clock sync and `server_now()`. Spec: multiplayer handoff →
## Networking protocol → Clock sync (8 samples, lowest RTT, slewing, never backward) and
## Testing → Client ("Clock sync: converges within ±5 ms on a simulated link"; the link of
## the netcode acceptance: 150 ms RTT, ±30 ms jitter, 2 % loss). WP N2.2.
##
## The link: each direction 75 ms ± 15 ms (uniform), so the round trip is 150 ± 30 ms, with
## 2 % loss per frame and direction, through NetClient + NetLoopbackLink + a scripted
## server, all on a virtual clock.

const FakeServer := preload("res://tests/net/fake_server.gd")

const STEP_S := 0.01
const WARMUP_S := 60.0
const MEASURE_S := 600.0
const TOLERANCE_MS := 5.0
const SEEDS := [11, 22, 33]
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"

var tuning: NetTuning


func before_all() -> void:
	tuning = NetTuning.load_default()


## A connected client/server pair on a lossless link; the acceptance link is set afterwards.
func _pair(seed_value: int, offset_s: float = 1234.5) -> Dictionary:
	var time := NetVirtualTime.new(5_000_000_000)
	var link := NetLoopbackLink.new(time, Rng.new(seed_value))
	link.latency_s = 0.075
	var server := FakeServer.new(link)
	server.offset_s = offset_s
	var client := NetClient.new(link.client, tuning, time)
	client.start("loop://test", 1, NetCodec.hex_to_bytes(MAP_HASH), "token")
	var p := {"time": time, "link": link, "server": server, "client": client}
	for i in 100:
		_step(p)
		if client.is_ready():
			break
	link.jitter_s = 0.015
	link.loss = 0.02
	return p


func _step(p: Dictionary) -> void:
	var time: NetVirtualTime = p["time"]
	var server: RefCounted = p["server"]
	var client: NetClient = p["client"]
	time.advance_s(STEP_S)
	server.call("poll")
	client.poll()


func _error_ms(p: Dictionary) -> float:
	var client: NetClient = p["client"]
	var server: RefCounted = p["server"]
	var truth: float = server.call("server_ticks")
	return (client.clock.server_now() - truth) / client.clock.tick_rate() * 1000.0


func test_converges_within_5ms_on_the_acceptance_link() -> void:
	for seed_value: int in SEEDS:
		var p := _pair(seed_value)
		var client: NetClient = p["client"]
		if not check(client.is_ready(), "seed %d: handshake" % seed_value):
			continue
		var steps_warm := roundi(WARMUP_S / STEP_S)
		var steps := roundi(MEASURE_S / STEP_S)
		var prev := -INF
		var backward := 0
		var converged_at := -1.0
		for i in steps_warm:
			_step(p)
			var now := client.clock.server_now()
			if now < prev:
				backward += 1
			prev = now
			if converged_at < 0.0 and absf(_error_ms(p)) <= TOLERANCE_MS:
				converged_at = (i + 1) * STEP_S
			elif absf(_error_ms(p)) > TOLERANCE_MS:
				converged_at = -1.0
		var worst := 0.0
		var sum := 0.0
		for i in steps:
			_step(p)
			var now := client.clock.server_now()
			if now < prev:
				backward += 1
			prev = now
			var e := absf(_error_ms(p))
			worst = maxf(worst, e)
			sum += e
		eq(backward, 0, "seed %d: server_now never goes backward" % seed_value)
		le(worst, TOLERANCE_MS, "seed %d: worst error after %ds (ms)" % [seed_value, WARMUP_S])
		var link: NetLoopbackLink = p["link"]
		print("      clock seed %d: within ±%.0f ms from %.1f s; then worst %.2f ms, mean %.2f ms "
			% [seed_value, TOLERANCE_MS, converged_at, worst, sum / steps]
			+ "over %d s; %d pongs, %d/%d frames lost, best rtt %.1f ms"
			% [MEASURE_S, client.pongs_received, link.lost_frames, link.sent_frames,
				client.clock.best_rtt_s * 1000.0])
		check(client.is_ready(), "seed %d: still connected" % seed_value)


func test_same_seed_same_clock_trace() -> void:
	var hashes := PackedInt64Array()
	for run in 2:
		var p := _pair(SEEDS[0])
		var client: NetClient = p["client"]
		var h := TraceHash.SEED
		for i in roundi(60.0 / STEP_S):
			_step(p)
			h = TraceHash.mix_float(h, client.clock.server_now())
		hashes.append(h)
	eq(hashes[0], hashes[1], "identical server_now trace for the same link seed")


func test_backward_correction_slews_without_going_backward() -> void:
	var p := _pair(SEEDS[1])
	var client: NetClient = p["client"]
	var server: RefCounted = p["server"]
	for i in roundi(WARMUP_S / STEP_S):
		_step(p)
	le(absf(_error_ms(p)), TOLERANCE_MS, "synced before the step")
	# The server clock steps 200 ms back (e.g. a room clock correction).
	server.set("offset_s", float(server.get("offset_s")) - 0.2)
	var prev := client.clock.server_now()
	var backward := 0
	var min_rate := INF
	for i in roundi(180.0 / STEP_S):
		_step(p)
		var now := client.clock.server_now()
		if now < prev:
			backward += 1
		min_rate = minf(min_rate, (now - prev) / STEP_S / client.clock.tick_rate())
		prev = now
	eq(backward, 0, "never backward while correcting 200 ms")
	ge(min_rate, 1.0 - tuning.clock_slew_max_rate - 1.0e-6, "slows by at most the slew rate")
	le(absf(_error_ms(p)), TOLERANCE_MS, "caught up after 180 s")


func test_forward_jump_is_taken_within_the_sample_window() -> void:
	var p := _pair(SEEDS[2])
	var server: RefCounted = p["server"]
	for i in roundi(WARMUP_S / STEP_S):
		_step(p)
	server.set("offset_s", float(server.get("offset_s")) + 1.0)
	# Once every sample in the window postdates the jump, the target is the new offset.
	var window_s := tuning.clock_samples * tuning.ping_interval_s * 2.0
	for i in roundi(window_s / STEP_S):
		_step(p)
	le(absf(_error_ms(p)), TOLERANCE_MS * 4.0, "a 1 s forward jump is followed at once")


func test_unit_behaviour() -> void:
	# Pongs outside a room (tick 0, fraction 0) are not samples.
	var time := NetVirtualTime.new(1_000_000)
	var clock := NetClock.new(tuning, time)
	var echo := clock.ping_time_ms()
	time.advance_s(0.1)
	check(not clock.on_pong(echo, 0, 0), "outside a room")
	check(not clock.has_sync())
	eq(clock.server_now(), 0.0, "0 before the first sample")
	# The first sample sets the estimate: server at 1000.5 ticks at the midpoint.
	echo = clock.ping_time_ms()
	time.advance_s(0.1)
	check(clock.on_pong(echo, 1000, 32768), "first sample")
	near(clock.last_rtt_s, 0.1, 1.0e-9, "rtt from the exact send time")
	# server_now = 1000.5 ticks at the midpoint (50 ms ago) + 1 tick since.
	near(clock.server_now(), 1001.5, 1.0e-6, "server_now at receive")
	time.advance_s(1.0)
	near(clock.server_now(), 1021.5, 1.0e-6, "advances at the tick rate")
	# A later, higher-RTT sample does not replace the lowest-RTT one.
	echo = clock.ping_time_ms()
	time.advance_s(0.3)
	check(clock.on_pong(echo, 1040, 0), "a slower sample")
	near(clock.last_rtt_s, 0.3, 1.0e-9)
	near(clock.best_rtt_s, 0.1, 1.0e-9, "best stays the 100 ms sample")


func test_u32_wrap_of_client_time() -> void:
	# Local ms just below 2^32: the echo wraps, and an unknown echo falls back to ms.
	var start_us := (4294967296 - 50) * 1000
	var time := NetVirtualTime.new(start_us)
	var clock := NetClock.new(tuning, time)
	var echo := clock.ping_time_ms()
	eq(echo, 4294967296 - 50, "client_time_ms before the wrap")
	time.advance_s(0.12)
	check(clock.on_pong(echo, 500, 0), "sample across the wrap")
	near(clock.last_rtt_s, 0.12, 1.0e-9, "exact rtt across the wrap")
	# An echo the clock never sent (e.g. remembered slots overwritten): ms fallback.
	@warning_ignore("integer_division")
	var now_ms := (time.usec / 1000) % 4294967296
	var fake_echo := (now_ms - 200 + 4294967296) % 4294967296
	time.advance_s(0.0)
	check(clock.on_pong(fake_echo, 510, 0), "fallback sample")
	near(clock.last_rtt_s, 0.2, 0.001, "rtt from the millisecond echo")
	# Stale echoes (older than clock_max_rtt_ms) are ignored.
	var stale := (now_ms - roundi(tuning.clock_max_rtt_ms) - 10 + 4294967296) % 4294967296
	check(not clock.on_pong(stale, 520, 0), "stale pong ignored")
