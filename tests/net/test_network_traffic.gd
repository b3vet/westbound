extends WBTest
## Client network traffic (N4.3): NetworkTrafficSource and TrafficCorrector, alone with
## scripted frames and against the fake authority (the real TrafficSim + director at 20 Hz
## on loop_v1, the real codec) over the acceptance link (150 ms RTT ± 30 ms, 2 % loss).
## Spec: multiplayer handoff → Traffic: server-authoritative with intents (What the server
## sends, Client network traffic: corrections, late intents), Networking protocol, Testing
## (client: "Traffic corrector: a recorded server stream replayed through it keeps error
## within the thresholds above"; netcode harness: median correction < 0.15 m, 99th
## percentile < 0.6 m, late intents < 1 per 10 minutes), Tuning reference. docs/NET_TRAFFIC.md.

const S2C := NetCodec.Direction.SERVER_TO_CLIENT
const TICK_SUB := 6            # client ticks per server tick (120 Hz / 20 Hz)
const CRUISER_V := 25.0        # m/s: the middle of the cruiser's desired speeds (free, no accel)
## The spec's bounds (Testing → Netcode harness).
const MEDIAN_BOUND_M := 0.15
const P99_BOUND_M := 0.6
## A car moving sideways faster than this without a blinker counts as unsignaled.
const LATERAL_SIGNAL_MPS := 0.5
const EPS := 1e-6

var tuning: Tuning


func before_all() -> void:
	tuning = Tuning.load_default()


# ---------------------------------------------------------------- Scripted-frame helpers

class Rig:
	var src: NetworkTrafficSource
	var road: RoadPath
	var player := VehicleState.new()
	var now: float = 100.0
	var codec := NetCodec.new()
	var frame := NetServerFrame.new()


## A source on a straight 3-lane road; `stale_s`: its traffic_stale_car_s (long by
## default: the scripted streams send no keep-alive corrections).
func _rig(stale_s: float = 1000.0) -> Rig:
	var r := Rig.new()
	r.road = StraightRoadPath.new(3)
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var st := TrafficState.new(tuning.traffic.max_active_vehicles)
	var net := tuning.net.duplicate() as NetTuning
	net.traffic_stale_car_s = stale_s
	r.src = NetworkTrafficSource.new(net, tuning.traffic, r.road, reg, st)
	r.player.reset()
	r.player.s = 0.0
	r.player.d = r.road.lane_center_d(2, 0.0)
	return r


func _apply(r: Rig, msgs: Array) -> void:
	var bytes := r.codec.encode_frame(msgs, S2C)
	if not eq(r.codec.error, "", "encode %s" % [msgs]):
		return
	eq(r.codec.decode_server_frame_into(bytes, r.frame), "")
	r.src.apply_frame(r.frame, r.player.s, r.now, 1.5)


## One client tick (1/6 of a server tick).
func _tick(r: Rig) -> void:
	r.now += 1.0 / TICK_SUB
	r.src.step(r.now, r.player, null)


func _spawn_msg(car_id: int, s: float, lane_sim: int, v: float, profile: int, r: Rig) -> Dictionary:
	return {"car_id": car_id, "vehicle": 0, "color": 3, "profile": profile,
		"lane": NetTrafficWire.lane_to_wire(lane_sim, 3), "s_mm": NetCodec.s_to_wire(s),
		"d_cm": NetTrafficWire.d_to_wire(r.road.lane_center_d(lane_sim, s)), "speed_cms": NetCodec.speed_to_wire(v),
		"lc_phase": "none", "lc_target_lane": 0, "lc_move_start_tick": 0, "lc_duration_ms": 0,
		"flags": {"hazard": false, "braking": false}}


## A cruiser at `s` (lane 1) at tick `tick`, with its correction in the same frame.
func _spawn_cruiser(r: Rig, car_id: int, s: float, tick: int) -> int:
	var cruiser := r.src.registry.profile_index(&"cruiser")
	_apply(r, [{"type": "traffic_spawn", "cars": [_spawn_msg(car_id, s, 1, CRUISER_V, cruiser, r)]},
		{"type": "traffic_correction", "tick": tick, "cars": [_corr_msg(car_id, s, r.road.lane_center_d(1, s), CRUISER_V)]}])
	r.src.step(r.now, r.player, null)
	return r.src.slot_of(car_id)


func _corr_msg(car_id: int, s: float, d: float, v: float) -> Dictionary:
	return {"car_id": car_id, "s_mm": NetCodec.s_to_wire(s), "d_cm": NetTrafficWire.d_to_wire(d),
		"speed_cms": NetCodec.speed_to_wire(v)}


# ---------------------------------------------------------------- Wire conventions

func test_wire_lanes_d_and_s() -> void:
	# MP-D6: wire 0 = rightmost; 7 = the ramp pseudo-lane (the sim's lane n).
	eq(NetTrafficWire.lane_to_wire(0, 3), 2, "leftmost of 3 is wire 2")
	eq(NetTrafficWire.lane_to_wire(2, 3), 0, "rightmost of 3 is wire 0")
	eq(NetTrafficWire.lane_to_wire(3, 3), NetTrafficWire.RAMP_LANE, "the ramp")
	eq(NetTrafficWire.lane_to_wire(3, 4), 0, "rightmost of 4")
	for n: int in [2, 3, 4]:
		for lane: int in n + 1:
			eq(NetTrafficWire.lane_from_wire(NetTrafficWire.lane_to_wire(lane, n), n), lane, "round trip %d/%d" % [lane, n])
	# d: right-positive on both sides (PROTOCOL.md §12), cm on the wire.
	eq(NetTrafficWire.d_to_wire(5.3), 530)
	near(NetTrafficWire.d_from_wire(530), 5.3, 1e-12)
	# s: wrapped on the loop, placed at the lap nearest the player.
	var road := RunLoop.loop_road(tuning)
	var L := road.length()
	near(NetTrafficWire.s_wrap(road, 2.0 * L + 12.5), 12.5, 1e-6)
	near(NetTrafficWire.s_unwrap(road, 30.0, 2.0 * L - 50.0), 2.0 * L + 30.0, 1e-6, "ahead across the seam")
	near(NetTrafficWire.s_unwrap(road, L - 30.0, 2.0 * L + 50.0), 2.0 * L - 30.0, 1e-6, "behind across the seam")
	var open := StraightRoadPath.new(3)
	near(NetTrafficWire.s_unwrap(open, 123456.0, 5.0), 123456.0, 0.0, "an open road does not wrap")


## The handoff's numbers live in NetTuning (Tuning reference: area of interest, correction
## rate and blending, multiplayer signal time; Client network traffic: 0.2 s catch-up).
func test_tuning_holds_the_traffic_spec_numbers() -> void:
	var n := tuning.net
	eq(n.traffic_aoi_behind_m, 300.0)
	eq(n.traffic_aoi_ahead_m, 900.0)
	eq(n.traffic_correction_near_m, 100.0)
	eq(n.traffic_correction_near_hz, 5.0)
	eq(n.traffic_correction_far_hz, 1.0)
	eq(n.traffic_blend_small_m, 0.5)
	eq(n.traffic_blend_small_s, 0.3)
	eq(n.traffic_blend_medium_m, 5.0)
	eq(n.traffic_blend_medium_s, 0.15)
	eq(n.traffic_signal_floor_s, 1.0)
	eq(n.traffic_late_catchup_s, 0.2)
	eq(n.traffic_car_id_reuse_s, 30.0)
	eq(n.test_link_rtt_ms, 150.0)
	eq(n.test_link_jitter_ms, 30.0)
	eq(n.test_link_loss, 0.02)
	lt(n.traffic_late_min_blinker_s, n.traffic_signal_floor_s, "the late minimum is well inside the 1 s lead")


# ---------------------------------------------------------------- The stream through the codec

## Every frame the fake authority sends decodes (generic and hot path agree), re-encodes to
## the same bytes, and carries the wire conventions.
func test_traffic_messages_round_trip_through_the_codec() -> void:
	var road := RunLoop.loop_road(tuning)
	var L := road.length()
	var player := VehicleState.new()
	player.reset()
	player.s = 2.0 * L - 400.0   # crosses the seam
	player.v = 42.0
	player.d = road.lane_center_d(1, player.s)
	var auth := FakeTrafficAuthority.new(tuning, road, 3, player.s, 4.5, 1.9)
	auth.joined = true
	var codec := NetCodec.new()
	var sink := NetServerFrame.new()
	var ps := NetPlayerState.new()
	var kinds := {}
	var frames := 0
	for k in 400:
		player.s += player.v * auth.dt
		ps.set_physical(auth.tick, NetTrafficWire.s_wrap(road, player.s), player.d, 0.0, player.v, 0.0, 0.0, 0.0, 0, 2)
		auth.receive_player_state(ps)
		var bytes := auth.step()
		if bytes.is_empty():
			continue
		frames += 1
		var dicts := codec.decode_frame(bytes, S2C)
		if not eq(codec.error, "", "frame %d decodes" % k):
			return
		eq(codec.encode_frame(dicts, S2C), bytes, "re-encodes to the same bytes")
		eq(codec.decode_server_frame_into(bytes, sink), "")
		eq(sink.to_dicts(), dicts, "the hot path decodes the same messages")
		for m in dicts:
			kinds[m["type"]] = true
			if m["type"] == "traffic_spawn":
				for c: Dictionary in m["cars"]:
					lt(float(c["s_mm"]), L * 1000.0, "s is wrapped")
					gt(float(c["d_cm"]), 0.0, "lanes are right of the reference line: d > 0")
					le(int(c["lane"]), 3)
					ne(int(c["car_id"]), 0, "car id 0 is never used")
	gt(frames, 300, "a frame nearly every tick")
	for t: String in ["traffic_spawn", "traffic_correction", "traffic_intent"]:
		check(kinds.has(t), "the stream has %s" % t)
	eq(auth.move_tick_mismatches, 0, "every move started at its announced tick")


# ---------------------------------------------------------------- Corrections

func test_small_and_medium_errors_blend_out_over_their_times() -> void:
	for err_m: float in [0.3, 2.0]:
		var r := _rig()
		var slot := _spawn_cruiser(r, 11, 200.0, 100)
		if not check(slot >= 0, "spawned"):
			return
		for k in TICK_SUB * 10:
			_tick(r)
		var st := r.src.state
		var s_true := 200.0 + CRUISER_V * (110.0 - 100.0) * r.src.tick_dt
		near(st.s[slot] - CRUISER_V * (r.now - 110.0) * r.src.tick_dt, s_true, 1e-6, "on the server's trajectory")
		var before := st.s[slot]
		_apply(r, [{"type": "traffic_correction", "tick": 110, "cars": [_corr_msg(11, s_true + err_m, r.road.lane_center_d(1, s_true), CRUISER_V)]}])
		_tick(r)
		var blend_s := tuning.net.traffic_blend_small_s if err_m < tuning.net.traffic_blend_small_m else tuning.net.traffic_blend_medium_s
		le(st.s[slot] - before, CRUISER_V * r.src.tick_dt / TICK_SUB + err_m / blend_s / 120.0 + EPS, "no jump (%.1f m)" % err_m)
		var ticks := ceili(blend_s * 120.0)
		for k in ticks - 2:
			_tick(r)
		var server := s_true + err_m + CRUISER_V * (r.now - 110.0) * r.src.tick_dt
		gt(server - st.s[slot], EPS, "still blending just before %.2f s (%.1f m)" % [blend_s, err_m])
		for k in 2:
			_tick(r)
		server = s_true + err_m + CRUISER_V * (r.now - 110.0) * r.src.tick_dt
		near(st.s[slot], server, 1e-6, "blended out after %.2f s (%.1f m)" % [blend_s, err_m])
		eq(r.src.stats.blends_small + r.src.stats.blends_medium, 1)


func test_large_errors_snap_out_of_view_and_slide_in_view() -> void:
	for visible: bool in [false, true]:
		var r := _rig()
		var s0 := 300.0 if visible else 2000.0
		var slot := _spawn_cruiser(r, 12, s0, 100)
		for k in TICK_SUB * 4:
			_tick(r)
		var st := r.src.state
		var s_true := s0 + CRUISER_V * 4.0 * r.src.tick_dt
		_apply(r, [{"type": "traffic_correction", "tick": 104, "cars": [_corr_msg(12, s_true + 20.0, r.road.lane_center_d(1, s_true), CRUISER_V)]}])
		var prev := st.s[slot]
		_tick(r)
		var server := s_true + 20.0 + CRUISER_V * (r.now - 104.0) * r.src.tick_dt
		if not visible:
			near(st.s[slot], server, 1e-6, "snapped out of view")
			eq(r.src.stats.snaps, 1)
			continue
		eq(r.src.stats.snaps, 0, "never a snap in view")
		eq(r.src.stats.large_in_view, 1)
		var worst := st.s[slot] - prev - CRUISER_V / 120.0
		var ticks := 0
		while absf(st.s[slot] - server) > EPS and ticks < 240:
			prev = st.s[slot]
			_tick(r)
			server = s_true + 20.0 + CRUISER_V * (r.now - 104.0) * r.src.tick_dt
			worst = maxf(worst, st.s[slot] - prev - CRUISER_V / 120.0)
			ticks += 1
		le(worst, tuning.net.traffic_blend_max_speed_mps / 120.0 + EPS, "slides at most blend_max_speed_mps")
		near(float(ticks + 1) / 120.0, 20.0 / tuning.net.traffic_blend_max_speed_mps, 0.02, "done after 20 m / 30 m/s")
		eq(r.src.stats.teleports, 0)


## A correction for tick N is compared against the prediction at tick N (the history), not
## the state now, and a second identical one changes nothing.
func test_corrections_compare_against_the_history() -> void:
	var r := _rig()
	var slot := _spawn_cruiser(r, 13, 500.0, 100)
	for k in TICK_SUB * 8:
		_tick(r)
	var s_n := 500.0 + CRUISER_V * 3.0 * r.src.tick_dt
	_apply(r, [{"type": "traffic_correction", "tick": 103, "cars": [_corr_msg(13, s_n, r.road.lane_center_d(1, s_n), CRUISER_V)]}])
	eq(r.src.stats.corrections, 2)
	le(r.src.stats.err_max, 0.001, "the prediction at tick 103 was right (only mm quantization)")
	_apply(r, [{"type": "traffic_correction", "tick": 103, "cars": [_corr_msg(13, s_n, r.road.lane_center_d(1, s_n), CRUISER_V)]}])
	eq(r.src.stats.old_corrections, 1, "a repeated tick is ignored")
	var s_srv := 500.0 + CRUISER_V * 5.0 * r.src.tick_dt + 0.4
	_apply(r, [{"type": "traffic_correction", "tick": 105, "cars": [_corr_msg(13, s_srv, r.road.lane_center_d(1, s_srv), CRUISER_V)]}])
	near(r.src.stats.err_max, 0.4, 0.002, "the error at tick 105")
	for k in TICK_SUB * 8:
		_tick(r)
	near(r.src.state.s[slot], s_srv + CRUISER_V * (r.now - 105.0) * r.src.tick_dt, 1e-6, "carried forward")


## A car that drives faster than the spawn guess: the desired-speed estimate converges and
## the correction sizes shrink.
func test_desired_speed_estimate_converges() -> void:
	var r := _rig()
	var slot := _spawn_cruiser(r, 14, 800.0, 100)
	var v0_true := 27.0
	var a_max: float = r.src.registry.a_max[r.src.state.profile_id[slot]]
	# The "server": the free IDM at v0_true, 20 Hz ballistic like TrafficSim.
	var s := 800.0
	var v := CRUISER_V
	var errs := PackedFloat64Array()
	for tick in range(101, 101 + 20 * 30):
		var a := a_max * (1.0 - Idm.pow_int(v / v0_true, 4))
		var nv := v + a * r.src.tick_dt
		s += (v + nv) * 0.5 * r.src.tick_dt
		v = nv
		for k in TICK_SUB:
			_tick(r)
		if tick % 4 == 0:
			var e0 := r.src.stats.err_max
			r.src.stats.err_max = 0.0
			_apply(r, [{"type": "traffic_correction", "tick": tick, "cars": [_corr_msg(14, s, r.road.lane_center_d(1, s), v)]}])
			errs.append(r.src.stats.err_max)
			r.src.stats.err_max = maxf(e0, r.src.stats.err_max)
	near(r.src.v0_estimate(slot), v0_true, 0.3, "v0 estimated")
	var late_max := 0.0
	for k in range(errs.size() - 20, errs.size()):
		late_max = maxf(late_max, errs[k])
	le(late_max, 0.005, "corrections are mm once the estimate converged")


# ---------------------------------------------------------------- Intents

## Blinker and lateral position of `slot` per client tick while `ticks` run.
func _watch(r: Rig, slot: int, ticks: int) -> Array:
	var out := []
	for k in ticks:
		_tick(r)
		var st := r.src.state
		out.append([r.now, st.d[slot], (st.flags[slot] & (TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BLINKER_RIGHT)) != 0])
	return out


func _curve(from: float, to: float, move_t: float, dur_t: float, t: float) -> float:
	var u := clampf((t - move_t) / dur_t, 0.0, 1.0)
	return from + (to - from) * u * u * (3.0 - 2.0 * u)


func test_intent_on_time_moves_at_its_tick() -> void:
	var r := _rig()
	var slot := _spawn_cruiser(r, 20, 400.0, 100)
	var from := r.road.lane_center_d(1, 400.0)
	var to := r.road.lane_center_d(2, 400.0)
	r.now = 101.5
	_apply(r, [{"type": "traffic_intent", "intents": [{"car_id": 20, "kind": "lane_change", "start_tick": 100,
		"move_start_tick": 120, "target_lane": NetTrafficWire.lane_to_wire(2, 3), "duration_ms": 2500}]}])
	var rows := _watch(r, slot, TICK_SUB * 75)
	for row: Array in rows:
		var t: float = row[0]
		if t < 120.0:
			near(row[1], from, EPS, "no lateral motion before the move tick (%.2f)" % t)
			check(row[2], "blinker on from the arrival (%.2f)" % t)
		elif t < 170.0:
			near(row[1], _curve(from, to, 120.0, 50.0, t), 1e-9, "on the server's curve (%.2f)" % t)
			check(row[2], "blinker on while moving")
		elif t >= 172.0:
			near(row[1], to, EPS)
			check(not row[2], "blinker off after the move")
	eq(r.src.state.lane[slot], 2, "in its new lane")
	eq(r.src.stats.late_intents, 0)


func test_late_intents_show_the_blinker_then_catch_up() -> void:
	var min_blink := tuning.net.traffic_late_min_blinker_s * 20.0
	var catchup := tuning.net.traffic_late_catchup_s * 20.0
	for arrival: float in [118.0, 130.0]:
		var r := _rig()
		var slot := _spawn_cruiser(r, 21, 400.0, 100)
		var from := r.road.lane_center_d(1, 400.0)
		var to := r.road.lane_center_d(0, 400.0)
		while r.now < arrival - 1e-9:
			_tick(r)
		r.now = arrival
		_apply(r, [{"type": "traffic_intent", "intents": [{"car_id": 21, "kind": "lane_change", "start_tick": 100,
			"move_start_tick": 120, "target_lane": NetTrafficWire.lane_to_wire(0, 3), "duration_ms": 2500}]}])
		var rows := _watch(r, slot, TICK_SUB * 60)
		var blink_on := INF
		var first_move := INF
		for row: Array in rows:
			var t: float = row[0]
			if row[2] and is_inf(blink_on):
				blink_on = t
			if absf(row[1] - from) > EPS and is_inf(first_move):
				first_move = t
				check(row[2], "the blinker is on when it starts moving")
			if t >= arrival + min_blink + catchup + EPS and t < 170.0:
				near(row[1], _curve(from, to, 120.0, 50.0, t), 1e-9, "caught up with the curve (%.2f, arrival %.0f)" % [t, arrival])
		le(blink_on - arrival, 1.0 / TICK_SUB + EPS, "blinker at once (arrival %.0f)" % arrival)
		ge(first_move - blink_on, min_blink - EPS, "blinker shown at least late_min_blinker_s first")
		eq(r.src.stats.late_intents, 1)
		eq(r.src.stats.very_late_intents, 1 if arrival > 120.0 else 0)


func test_cancels_before_and_after_the_move() -> void:
	# Before the move: blinker off, no lateral motion.
	var r := _rig()
	var slot := _spawn_cruiser(r, 22, 400.0, 100)
	var from := r.road.lane_center_d(1, 400.0)
	r.now = 101.5
	_apply(r, [{"type": "traffic_intent", "intents": [{"car_id": 22, "kind": "lane_change", "start_tick": 100,
		"move_start_tick": 120, "target_lane": NetTrafficWire.lane_to_wire(2, 3), "duration_ms": 2500}]}])
	_watch(r, slot, TICK_SUB * 8)
	_apply(r, [{"type": "traffic_intent", "intents": [{"car_id": 22, "kind": "cancel", "start_tick": 108,
		"move_start_tick": 108, "target_lane": 0, "duration_ms": 0}]}])
	for row: Array in _watch(r, slot, TICK_SUB * 40):
		near(row[1], from, EPS, "stays in its lane")
		check(not row[2], "blinker off")
	# A cancel that arrives after the client began the move: back into the lane, blinker
	# on while it slides back.
	r = _rig()
	slot = _spawn_cruiser(r, 23, 400.0, 100)
	r.now = 101.5
	_apply(r, [{"type": "traffic_intent", "intents": [{"car_id": 23, "kind": "lane_change", "start_tick": 100,
		"move_start_tick": 120, "target_lane": NetTrafficWire.lane_to_wire(2, 3), "duration_ms": 2500}]}])
	while r.now < 128.0:
		_tick(r)
	gt(absf(r.src.state.d[slot] - from), 0.05, "moving")
	_apply(r, [{"type": "traffic_intent", "intents": [{"car_id": 23, "kind": "cancel", "start_tick": 119,
		"move_start_tick": 119, "target_lane": 0, "duration_ms": 0}]}])
	var rows := _watch(r, slot, TICK_SUB * 40)
	var prev_d: float = r.src.state.d[slot]
	for row: Array in rows:
		if absf(row[1] - prev_d) > EPS:
			check(row[2], "blinker on while sliding back (%.2f)" % row[0])
		prev_d = row[1]
	near(r.src.state.d[slot], from, EPS, "back in its lane")
	eq(r.src.stats.late_cancels, 1)
	# WP6.11: a correction dated after the cancel (the server's car on its line all along)
	# must not read the abandoned move as a lateral error: the car stays on its line, no
	# unsignaled slide.
	check(r.src.corrector.lookup(slot, 125), "tick 125 in the history")
	near(r.src.corrector.q_d, from, EPS, "the history holds the car's line after the cancel")
	_apply(r, [{"type": "traffic_correction", "tick": 125, "cars": [_corr_msg(23, r.src.corrector.q_s, from,
		r.src.corrector.q_v)]}])
	var unsignaled := r.src.stats.unsignaled_lateral
	for row: Array in _watch(r, slot, TICK_SUB * 20):
		near(row[1], from, 0.01, "no lateral shift after the correction (%.2f)" % row[0])
	eq(r.src.stats.unsignaled_lateral, unsignaled, "no new unsignaled slide")


func test_hazard_hard_brake_and_local_hit() -> void:
	var r := _rig()
	var slot := _spawn_cruiser(r, 24, 400.0, 100)
	_apply(r, [{"type": "traffic_intent", "intents": [
		{"car_id": 24, "kind": "hazard", "start_tick": 100, "move_start_tick": 100, "target_lane": 0, "duration_ms": 4000},
		{"car_id": 24, "kind": "hard_brake", "start_tick": 101, "move_start_tick": 101, "target_lane": 0, "duration_ms": 1000}]}])
	_watch(r, slot, TICK_SUB * 4)
	var st := r.src.state
	check(st.has_flag(slot, TrafficState.FLAG_HAZARD), "hazards on")
	check(st.has_flag(slot, TrafficState.FLAG_BRAKE_STRONG), "hard brake: strong brake lights")
	near(st.accel[slot], -tuning.traffic.hit_brake_decel_mps2, 1e-9)
	_watch(r, slot, TICK_SUB * 90)
	check(not st.has_flag(slot, TrafficState.FLAG_HAZARD), "hazards off after 4 s")
	# A local hit: hazards and FLAG_HIT at once, the events like TrafficSim's.
	var ev := ScoreEventBuffer.new(8)
	r.src.notify_hit(slot)
	r.now += 1.0 / TICK_SUB
	r.src.step(r.now, r.player, ev)
	check(st.has_flag(slot, TrafficState.FLAG_HIT) and st.has_flag(slot, TrafficState.FLAG_HAZARD))
	lt(st.accel[slot], -tuning.traffic.brake_light_strong_decel_mps2, "brakes at once")
	eq(ev.size(), 1)
	eq(ev.kind[0], TrafficSim.KIND_HAZARDS)


## A car nothing is heard of is dropped; a correction for a car the client does not know is
## counted, not applied.
func test_stale_cars_and_unknown_ids() -> void:
	var r := _rig(tuning.net.traffic_stale_car_s)
	var slot := _spawn_cruiser(r, 25, 400.0, 100)
	ge(slot, 0)
	_apply(r, [{"type": "traffic_correction", "tick": 101, "cars": [_corr_msg(999, 10.0, 5.0, 20.0)]}])
	eq(r.src.stats.unknown_car, 1)
	var n := ceili(tuning.net.traffic_stale_car_s * 20.0 * TICK_SUB) + TICK_SUB
	for k in n:
		_tick(r)
	eq(r.src.state.count, 0, "dropped after traffic_stale_car_s of silence")
	eq(r.src.stats.stale_despawns, 1)
	eq(r.src.slot_of(25), NetworkTrafficSource.NO_SLOT)


# ---------------------------------------------------------------- Against the fake authority

## The spec's bounds with no loss (150 ± 30 ms): median correction < 0.15 m, p99 < 0.6 m;
## no teleport; every lane change signalled before it moves.
func test_prediction_error_without_loss_stays_under_the_bounds() -> void:
	var r := NetTrafficRig.on_loop(21, 1500.0, 150.0, true, NetDelayLink.Mode.STREAM, false)
	r.run(35.0)
	print("  no loss: ", r.summary())
	var s := r.stats()
	gt(s.corrections, 800)
	lt(s.percentile(NetTrafficStats.P50), MEDIAN_BOUND_M, "median correction")
	lt(s.percentile(NetTrafficStats.P99), P99_BOUND_M, "99th percentile")
	lt(s.percentile(NetTrafficStats.P99, true), 0.1, "near the player: p99 under 10 cm")
	eq(s.teleports, 0)
	eq(s.snaps, 0)
	eq(s.late_intents, 0)
	gt(s.intents, 5, "lane changes happened")
	eq(r.unsignaled_ticks, 0, "no lateral motion without a blinker")
	ge(r.blinker_lead_min_s, tuning.net.traffic_late_min_blinker_s - EPS, "blinker before motion")
	eq(r.harness.authority.move_tick_mismatches, 0)
	lt(r.jump_max_m, tuning.net.traffic_teleport_speed_mps / 120.0, "no jump in view (rig's own measure)")


## 2 % loss on the WebSocket (retransmissions, head-of-line bursts): still inside the bounds.
func test_loss_on_the_stream() -> void:
	var r := NetTrafficRig.on_loop(22, 6000.0, 160.0, true)
	r.run(35.0)
	print("  stream 2%% loss: ", r.summary())
	var s := r.stats()
	gt(r.harness.down.lost, 5, "frames were lost and retransmitted")
	lt(s.percentile(NetTrafficStats.P50), MEDIAN_BOUND_M)
	lt(s.percentile(NetTrafficStats.P99), P99_BOUND_M)
	eq(s.teleports, 0)
	eq(s.unknown_car, 0, "nothing is lost on a stream")
	eq(r.unsignaled_ticks, 0)


## A datagram path (a later UDP transport) loses frames for good: spawns, intents and
## despawns go missing. The client still never teleports a car in view, drops the cars it
## stops hearing about, and shows unexplained lateral moves with a blinker.
func test_loss_on_a_datagram_path_degrades_gracefully() -> void:
	var r := NetTrafficRig.on_loop(23, 11000.0, 150.0, true, NetDelayLink.Mode.DATAGRAM, true)
	r.harness.down.loss = 0.1
	r.run(35.0)
	print("  datagram 10%% loss: ", r.summary())
	var s := r.stats()
	gt(r.harness.down.lost, 50)
	eq(s.teleports, 0)
	gt(s.corrections, 500)
	lt(s.percentile(NetTrafficStats.P50), MEDIAN_BOUND_M)


## Cars come and go at the area's edges by driving (not in view), and the client's cars
## are the server's area.
func test_spawns_and_despawns_at_the_area_edges() -> void:
	var r := NetTrafficRig.on_loop(24, 1000.0, 200.0, true)
	r.run(4.0)
	var join_spawns := r.stats().spawns
	r.spawn_ds.clear()
	r.run(30.0)
	var net := tuning.net
	print("  area edges: ", r.summary())
	ge(r.stats().despawns, 3, "cars left the area")
	gt(r.stats().spawns - join_spawns, 10, "cars entered the area")
	var edge := 0
	for ds in r.spawn_ds:
		if ds > net.traffic_visible_ahead_m or ds < -net.traffic_visible_behind_m:
			edge += 1
	eq(edge, r.spawn_ds.size(), "every spawn after the join appears out of view (%s)" % [r.spawn_ds])
	# The client's cars lie in the area (plus hysteresis and the latency's travel).
	var st := r.harness.client_state
	var slack := net.traffic_aoi_hysteresis_m + 20.0
	var p := r.bot.state.s
	for i in st.capacity:
		if st.active[i] == 1:
			ge(st.s[i] - p, -net.traffic_aoi_behind_m - slack)
			le(st.s[i] - p, net.traffic_aoi_ahead_m + slack)
	# ... and every server car well inside the area is known to the client.
	var auth := r.harness.authority
	var srv := auth.sim.state
	for j in srv.capacity:
		if srv.active[j] == 0:
			continue
		var ds := srv.s[j] - auth.player.s
		if ds > -net.traffic_aoi_behind_m + slack and ds < net.traffic_aoi_ahead_m - slack:
			ne(r.harness.source.slot_of(auth.car_id_of_slot(j)), NetworkTrafficSource.NO_SLOT, "server car at %.0f m known" % ds)


## Across the loop's seam (s = k L): wire s wraps, the client keeps s unwrapped and
## continuous, nothing jumps.
func test_loop_seam_wrap() -> void:
	var road := RunLoop.loop_road(tuning)
	var r := NetTrafficRig.on_loop(25, road.length() - 700.0, 150.0, false)
	r.run(6.0)
	var st := r.harness.client_state
	var across := 0
	for i in st.capacity:
		if st.active[i] == 1 and st.s[i] > 2.0 * road.length():
			across += 1
	gt(across, 3, "cars ahead across the seam are on the next lap")
	r.run(20.0)
	gt(r.bot.state.s, 2.0 * road.length() + 50.0, "the player crossed the seam")
	eq(r.stats().teleports, 0)
	lt(r.jump_max_m, tuning.net.traffic_teleport_speed_mps / 120.0)
	lt(r.stats().percentile(NetTrafficStats.P99), P99_BOUND_M)
	eq(r.stats().snaps, 0)
	for i in st.capacity:
		if st.active[i] == 1:
			lt(absf(st.s[i] - r.bot.state.s), 1000.0, "every car near the player's lap")


# ---------------------------------------------------------------- Determinism, allocation

## The same message stream (frames at the same server times, the same player) gives the
## same client state, tick for tick.
func test_client_is_deterministic_given_the_same_stream() -> void:
	var r := NetTrafficRig.on_loop(26, 2000.0, 150.0, true)
	r.harness.record = true
	r.run(12.0)
	var trace := r.harness.trace_log
	var a := _replay(trace)
	var b := _replay(trace)
	eq(a, b, "two replays agree")
	eq(a[a.size() - 1], r.harness.client_state.trace_hash(), "and match the live run")
	gt(a.size(), 1000)


func _replay(trace: Array) -> PackedInt64Array:
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var road := RunLoop.loop_road(tuning)
	var st := TrafficState.new(tuning.traffic.max_active_vehicles)
	var src := NetworkTrafficSource.new(tuning.net, tuning.traffic, road, reg, st)
	src.set_headway_scale(tuning.director.headway_scale(LoopTuning.load_default().director_leg))
	src.set_player_body(4.5, 1.9)
	var codec := NetCodec.new()
	var frame := NetServerFrame.new()
	var p := VehicleState.new()
	var hashes := PackedInt64Array()
	for e: Array in trace:
		if e[0] == "frame":
			codec.decode_server_frame_into(e[1], frame)
			src.apply_frame(frame, e[2], e[3], e[4])
		else:
			p.s = e[2]
			p.d = e[3]
			p.v = e[4]
			p.v_lat = e[5]
			p.yaw = e[6]
			src.step(e[1], p, null)
			hashes.append(st.trace_hash())
	return hashes


## Per tick the source and its corrector allocate nothing: decode + apply_frame and step
## over a recorded stream, measured tightly around each call after warm-up (the heap
## around them is not ours to measure); the lane-drop zone sync every ~1 km of travel
## (director rate) is excluded.
func test_no_allocation_per_tick() -> void:
	var r := NetTrafficRig.on_loop(27, 3000.0, 150.0, true)
	r.harness.record = true
	r.run(8.0)
	var trace := r.harness.trace_log
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var st := TrafficState.new(tuning.traffic.max_active_vehicles)
	var src := NetworkTrafficSource.new(tuning.net, tuning.traffic, r.road, reg, st)
	var codec := NetCodec.new()
	var frame := NetServerFrame.new()
	var p := VehicleState.new()
	var ev := ScoreEventBuffer.new(64)
	var half := trace.size() >> 1
	var grow_frames := 0
	var grow_steps := 0
	var calls := 0
	var obj0 := 0.0
	for k in trace.size():
		if k == half:
			obj0 = Performance.get_monitor(Performance.OBJECT_COUNT)
		var e: Array = trace[k]
		var syncs := src.zone_syncs
		var m0 := OS.get_static_memory_usage()
		if e[0] == "frame":
			codec.decode_server_frame_into(e[1], frame)
			src.apply_frame(frame, e[2], e[3], e[4])
			if k > half:
				grow_frames += OS.get_static_memory_usage() - m0
		else:
			p.s = e[2]
			p.d = e[3]
			src.step(e[1], p, ev)
			ev.clear()
			# The lane-drop zone sync (every ~1 km, road features) allocates by design.
			if k > half and src.zone_syncs == syncs:
				grow_steps += OS.get_static_memory_usage() - m0
		if k > half:
			calls += 1
	gt(calls, 400)
	eq(grow_frames, 0, "decode + apply_frame allocate nothing")
	eq(grow_steps, 0, "step allocates nothing")
	le(Performance.get_monitor(Performance.OBJECT_COUNT) - obj0, 0.0, "no objects")


## Cost per 120 Hz client tick (step: the 20 Hz model pass every 6th tick, the publish
## pass every tick) and per applied frame, replaying a recorded stream in the city (the
## loop's densest section). Budgets ~3x the local median (WBBench).
func test_client_tick_cost() -> void:
	var road := RunLoop.loop_road(tuning)
	var r := NetTrafficRig.on_loop(28, (road as LoopRoadPath).layout.elevated_s0[0] + 200.0, 130.0, true)
	r.harness.record = true
	r.run(10.0)
	var trace := r.harness.trace_log
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var st := TrafficState.new(tuning.traffic.max_active_vehicles)
	var src := NetworkTrafficSource.new(tuning.net, tuning.traffic, road, reg, st)
	var codec := NetCodec.new()
	var frame := NetServerFrame.new()
	var p := VehicleState.new()
	var step_us := 0
	var steps := 0
	var frame_us := 0
	var frames := 0
	var cars := 0
	for k in trace.size():
		var e: Array = trace[k]
		if e[0] == "frame":
			var t0 := Time.get_ticks_usec()
			codec.decode_server_frame_into(e[1], frame)
			src.apply_frame(frame, e[2], e[3], e[4])
			frame_us += Time.get_ticks_usec() - t0
			frames += 1
		else:
			p.s = e[2]
			p.d = e[3]
			var syncs := src.zone_syncs
			var t0 := Time.get_ticks_usec()
			src.step(e[1], p, null)
			if src.zone_syncs == syncs and k > trace.size() >> 1:
				step_us += Time.get_ticks_usec() - t0
				steps += 1
				cars += st.count
	var per_step := float(step_us) / float(maxi(steps, 1))
	var per_frame := float(frame_us) / float(maxi(frames, 1))
	WBBench.report("network traffic step, %.0f cars" % (float(cars) / float(maxi(steps, 1))), per_step, 600.0)
	WBBench.report("network traffic frame (decode + apply)", per_frame, 600.0)
	le(per_step, WBBench.budget(600.0), "step usec")
	le(per_frame, WBBench.budget(600.0), "frame usec")


# ---------------------------------------------------------------- Soak

## 10+ simulated minutes of the loop at the acceptance link (150 ± 30 ms, 2 % loss on the
## stream), a weaving player at 150–190 km/h: 0 visible teleports; correction sizes reported
## and held to the spec's bounds; late intents under 1 per 10 minutes. No spawn dropped for
## the client's capacity while the fake's area holds no more cars than that (MP-D8: beyond
## it they are dropped and counted; the fake's single-player director can overfill the
## city's area, which the server's ring at normal density does not: docs/NET_TRAFFIC.md).
func soak_network_traffic_ten_minutes() -> void:
	for seed_value: int in [31, 32]:
		var r := NetTrafficRig.on_loop(seed_value, 500.0, 170.0, true)
		r.bot.set_weave(3.0, 8.0)
		var t0 := Time.get_ticks_msec()
		var area_max := 0
		for k in 630:
			r.run(1.0)
			area_max = maxi(area_max, _authority_area_count(r))
		print("  soak seed %d (%d ms wall): %s" % [seed_value, Time.get_ticks_msec() - t0, r.summary()])
		print("  soak seed %d: the fake's area held at most %d cars (client capacity %d), %d spawns dropped" % [
			seed_value, area_max, r.harness.client_state.capacity, r.stats().dropped_full])
		print("  soak seed %d: blinker lead min %.3f s, unsignaled ticks %d, rig jump max %.4f m, truth after 60 s: median %.3f p99 %.3f" % [
			seed_value, r.blinker_lead_min_s, r.unsignaled_ticks, r.jump_max_m,
			r.truth_late.percentile(NetTrafficStats.P50), r.truth_late.percentile(NetTrafficStats.P99)])
		var s := r.stats()
		eq(s.teleports, 0, "no visible teleport")
		lt(r.jump_max_m, tuning.net.traffic_teleport_speed_mps / 120.0)
		lt(s.percentile(NetTrafficStats.P50), MEDIAN_BOUND_M)
		lt(s.percentile(NetTrafficStats.P99), P99_BOUND_M)
		lt(float(s.late_intents), 1.0, "late intents under 1 per 10 minutes")
		eq(r.unsignaled_ticks, 0)
		eq(r.harness.authority.move_tick_mismatches, 0)
		if area_max <= r.harness.client_state.capacity:
			eq(s.dropped_full, 0, "nothing dropped while the area fits the client")


## Cars the fake authority has in the client's area (with the hysteresis), sampled.
func _authority_area_count(r: NetTrafficRig) -> int:
	var a := r.harness.authority
	var ts := a.sim.state
	var p := a.player.s
	var net := tuning.net
	var lo := p - net.traffic_aoi_behind_m - net.traffic_aoi_hysteresis_m
	var hi := p + net.traffic_aoi_ahead_m + net.traffic_aoi_hysteresis_m
	var n := 0
	for i in ts.capacity:
		if ts.active[i] == 1 and ts.s[i] >= lo and ts.s[i] <= hi:
			n += 1
	return n
