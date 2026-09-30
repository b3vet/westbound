extends WBTest
## Remote players' interpolation and extrapolation (NetRemoteTrack) and the remote pool
## (NetRemotePlayers). Spec: multiplayer handoff → Players ("Clients show remote cars 100 ms
## behind with interpolation and extrapolate up to 250 ms, then fade the car until data
## arrives"; "at most 7 others"), The loop map (s wraps modulo L; wrapped signed
## difference). docs/ROOMS_CLIENT.md → Remote players. WP N5.2.

const L := 25000.0
const RATE := 20.0
const SNAP := 40.0

var tuning: NetTuning


func before_all() -> void:
	tuning = NetTuning.load_default()


func _track(loop_length: float = L) -> NetRemoteTrack:
	return NetRemoteTrack.new(16, loop_length, RATE, SNAP)


func test_spec_numbers_in_tuning() -> void:
	eq(tuning.room_interp_delay_ms, 100.0, "100 ms behind")
	eq(tuning.room_extrap_max_ms, 250.0, "extrapolate up to 250 ms")
	eq(tuning.room_max_remotes, 7, "at most 7 others")
	eq(tuning.room_protection_s, 3.0, "3 s protection")
	eq(tuning.room_reconnect_window_s, 15.0, "15 s seat hold")
	eq(tuning.room_ghost_near_m, 15.0, "translucent within 15 m")


func test_interpolates_between_states() -> void:
	var t := _track()
	check(t.push(100, 1000.0, 3.5, 0.0, 40.0, 0, 2))
	check(t.push(101, 1002.0, 3.0, 0.02, 42.0, 1, 2))
	eq(t.sample(100.5, 5.0, 10.0), NetRemoteTrack.Mode.INTERPOLATED)
	near(t.s, 1001.0, 1e-9, "s halfway")
	near(t.d, 3.25, 1e-9, "d halfway")
	near(t.heading, 0.01, 1e-9)
	near(t.speed, 41.0, 1e-9)
	eq(t.flags, 1, "flags of the newer state")
	eq(t.alpha, 1.0)
	t.sample(99.0, 5.0, 10.0)
	near(t.s, 1000.0, 1e-9, "before the oldest: the oldest")


func test_100ms_behind_is_between_the_last_two_states() -> void:
	var t := _track()
	for k in 10:
		t.push(200 + k, 500.0 + float(k) * 2.0, 3.5, 0.0, 40.0, 0, 2)
	# server_now = 209.4: render at 209.4 - 100 ms (2 ticks) = 207.4.
	var render := 209.4 - tuning.room_interp_delay_ms / 1000.0 * RATE
	eq(t.sample(render, 5.0, 10.0), NetRemoteTrack.Mode.INTERPOLATED)
	near(t.s, 500.0 + 7.4 * 2.0, 1e-9)


func test_extrapolates_up_to_250ms_then_fades() -> void:
	var t := _track()
	t.push(10, 100.0, 3.5, 0.0, 40.0, 0, 2)
	t.push(11, 102.0, 3.5, 0.0, 40.0, 0, 2)
	var ext := tuning.room_extrap_max_ms / 1000.0 * RATE   # 5 ticks
	var fade := tuning.room_fade_out_s * RATE
	eq(t.sample(13.0, ext, fade), NetRemoteTrack.Mode.EXTRAPOLATED)
	near(t.s, 102.0 + 40.0 * 0.1, 1e-9, "dead reckoning: 2 ticks at 40 m/s")
	eq(t.alpha, 1.0)
	eq(t.sample(11.0 + ext, ext, fade), NetRemoteTrack.Mode.EXTRAPOLATED, "exactly 250 ms ahead")
	near(t.s, 102.0 + 40.0 * 0.25, 1e-9)
	eq(t.sample(11.0 + ext + fade * 0.5, ext, fade), NetRemoteTrack.Mode.STALE)
	near(t.s, 102.0 + 40.0 * 0.25, 1e-9, "holds where the extrapolation stopped")
	near(t.alpha, 0.5, 1e-9, "fading")
	t.sample(11.0 + ext + fade * 2.0, ext, fade)
	eq(t.alpha, 0.0, "gone until data arrives")
	t.push(30, 130.0, 3.5, 0.0, 40.0, 0, 2)
	t.sample(30.0, ext, fade)
	eq(t.alpha, 1.0, "back with new data")


func test_extrapolates_lateral_motion_along_the_heading() -> void:
	var t := _track()
	t.push(10, 100.0, 3.5, 0.1, 30.0, 0, 2)
	t.sample(12.0, 5.0, 10.0)
	near(t.s, 100.0 + 30.0 * cos(0.1) * 0.1, 1e-9)
	near(t.d, 3.5 + 30.0 * sin(0.1) * 0.1, 1e-9, "+ heading = moving right (+ d)")


func test_seam_wrap_is_continuous() -> void:
	var t := _track()
	t.push(1, L - 3.0, 3.5, 0.0, 40.0, 0, 2)
	t.push(2, L - 1.0, 3.5, 0.0, 40.0, 0, 2)
	t.push(3, 1.0, 3.5, 0.0, 40.0, 0, 2)   # wrapped on the wire
	t.push(4, 3.0, 3.5, 0.0, 40.0, 0, 2)
	eq(t.restarts, 0, "the seam is not a teleport")
	t.sample(2.5, 5.0, 10.0)
	near(t.s, L, 1e-9, "halfway across the line: exactly L")
	t.sample(3.5, 5.0, 10.0)
	near(t.s, L + 2.0, 1e-9, "past the line keeps counting")
	# The consumer maps it next to its own unwrapped s (lap 3 here).
	var road := RunLoop.loop_road(Tuning.load_default())
	var mine := road.length() * 3.0 + 10.0
	var theirs := road.unwrap_near(mine, t.s - L + road.length())
	near(theirs - mine, 2.0 - 10.0, 1e-6, "8 m behind me across laps")
	# And backward across the seam.
	var b := _track()
	b.push(1, 2.0, 3.5, 0.0, 40.0, 0, 2)
	b.push(2, L - 1.0, 3.5, 0.0, 40.0, 0, 2)
	near(b.newest_s(), -1.0, 1e-9, "backward across the seam: below 0, continuous")


func test_late_and_repeated_states_are_dropped() -> void:
	var t := _track()
	check(t.push(10, 100.0, 3.5, 0.0, 40.0, 0, 2))
	check(t.push(12, 104.0, 3.5, 0.0, 40.0, 0, 2))
	check(not t.push(11, 102.0, 3.5, 0.0, 40.0, 0, 2), "older tick")
	check(not t.push(12, 104.0, 3.5, 0.0, 40.0, 0, 2), "same tick")
	eq(t.dropped, 2)
	eq(t.count, 2)
	t.sample(11.0, 5.0, 10.0)
	near(t.s, 102.0, 1e-9, "a lost state is bridged by interpolation")


func test_placement_jump_restarts_instead_of_sliding() -> void:
	var t := _track()
	t.push(10, 1000.0, 3.5, 0.0, 40.0, 0, 2)
	t.push(11, 1002.0, 3.5, 0.0, 40.0, 0, 2)
	t.push(12, 5000.0, 7.0, 0.0, 30.0, 0, 1)   # respawned elsewhere
	eq(t.restarts, 1)
	eq(t.count, 1)
	t.sample(11.5, 5.0, 10.0)
	near(t.s, 5000.0, 1e-9, "no slide from the old spot")


func test_ring_keeps_the_newest_states() -> void:
	var t := _track()
	for k in 40:
		t.push(k, float(k) * 2.0, 3.5, 0.0, 40.0, 0, 2)
	eq(t.count, 16)
	t.sample(0.0, 5.0, 10.0)
	near(t.s, 24.0 * 2.0, 1e-9, "the oldest kept is tick 24")
	t.sample(38.5, 5.0, 10.0)
	near(t.s, 77.0, 1e-9)


func test_sampling_allocates_nothing() -> void:
	var t := _track()
	for k in 16:
		t.push(k, float(k) * 2.0, 3.5, 0.0, 40.0, 0, 2)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for k in 1000:
		t.sample(float(k % 20), 5.0, 10.0)
		t.push(16 + k, float(16 + k) * 2.0, 3.5, 0.0, 40.0, 0, 2)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before, "no objects per push or sample")


# ---------------------------------------------------------------- The pool

func _frame(entries: Array) -> NetServerFrame:
	var codec := NetCodec.new()
	var players := []
	for e: Array in entries:
		players.append({"player_id": e[0], "state": {"tick": e[1], "s_mm": e[2], "d_cm": 350,
			"heading_e4": 0, "speed_cms": 4000, "lat_vel_cms": 0, "yaw_rate_mrad_s": 0, "steer_e4": 0,
			"flags": {"brake": false, "boost": false, "headlights": false, "ghost": false},
			"run_state": "driving"}})
	var bytes := codec.encode_frame([{"type": "player_states", "players": players}], NetCodec.Direction.SERVER_TO_CLIENT)
	var f := NetServerFrame.new()
	eq(codec.decode_server_frame_into(bytes, f), "")
	return f


func test_pool_holds_seven_and_skips_you() -> void:
	var p := NetRemotePlayers.new(7, 16, L, RATE, SNAP)
	var entries := []
	for pid in 9:
		entries.append([pid, 100, 1000 * (pid + 1)])
	p.ingest_into(_frame(entries), 3)
	eq(p.active_count(), 7, "seven others fit")
	eq(p.slot_of(3), -1, "your own id is never a remote")
	eq(p.overflow, 1, "the ninth player found no slot")
	var i := p.slot_of(5)
	check(i >= 0)
	near(p.tracks[i].newest_s(), 6.0, 1e-9, "wire mm to m")


func test_pool_reuses_tracks_without_allocating() -> void:
	var p := NetRemotePlayers.new(7, 16, L, RATE, SNAP)
	var first := p.tracks.duplicate()
	var f := _frame([[4, 10, 1000], [6, 10, 2000]])
	var g := _frame([[9, 11, 5000]])
	p.ingest_into(f, 0)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for k in 200:
		p.release(4)
		p.release(6)
		p.release(9)
		p.ingest_into(f, 0)
		p.ingest_into(g, 0)
		p.sample_all(10.5, 5.0, 10.0)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before, "joins and leaves allocate nothing")
	for k in 7:
		check(p.tracks[k] == first[k], "slot %d keeps its track object" % k)
	eq(p.active_count(), 3)
	p.release(6)
	eq(p.slot_of(6), -1)
	var j := p.acquire(11)
	eq(p.tracks[j].count, 0, "a reused slot starts empty")
