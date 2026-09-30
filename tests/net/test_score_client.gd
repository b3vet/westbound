extends WBTest
## NetScoreClient (N6.2): claims from the real scoring rules' events (pass, close pass, thread,
## cut: kind, tick, side, wire car ids, clearances, event order) through a scripted server's
## decoder; local cars never claimed; no allocation per tick; score_sync easing (equal, server
## ahead, server behind, only at banking moments, never in one jump back; syncs of the run
## before ignored; a new run starts clean); crew proximity (+0.25× per crewmate within 30 m,
## capped, across the loop's seam, other crews and stale tracks left out); trains (TRAIN ×n,
## the run's count, a crewmate's link); official sector bonuses the run did not pay.
## Spec: multiplayer handoff → Scoring in multiplayer; docs/SERVER.md → Scoring (N6.1) →
## Claims. docs/ROOMS_CLIENT.md → Scoring in a room.

const FakeScoreServer := preload("res://tests/net/fake_score_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const DT := ScoringScenario.DT
const RATE := 20.0
## The first room tick of the scripted scenes.
const T0 := 5000
## Wire ids: 100 + slot.
const ID_BASE := 100

var t: Tuning
var net: NetTuning


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


## A client without a session (tick-side tests).
func _client() -> NetScoreClient:
	var c := NetScoreClient.new(null, net, t.scoring.thread_clearance_m)
	c.wire_id = func(slot: int) -> int: return ID_BASE + slot
	c.reset_run(T0)
	return c


## The scenario's room tick at its current time (the first at or after it).
func _tick(sc: ScoringScenario) -> int:
	return T0 + ceili(sc.time * RATE - 1e-9)


## Runs the scenario like the run does: each 120 Hz tick the rules step, the client reads
## that tick's events, then they are drained.
func _drive(sc: ScoringScenario, c: NetScoreClient, seconds: float) -> void:
	for k in roundi(seconds / DT):
		sc.player.s += sc.player.v * DT
		if sc.is_steering():
			sc.player.d = move_toward(sc.player.d, sc.road.lane_center_d(2, sc.player.s), 6.0 * DT)
		for i in sc.traffic.capacity:
			if sc.traffic.active[i] == 1:
				sc.traffic.s[i] += sc.traffic.v[i] * DT
		sc.time += DT
		sc.rules.step(DT, sc.player, sc.traffic, sc.road, sc.buf)
		c.observe(sc.buf, 0, sc.buf.size(), _tick(sc), sc.player.d, sc.traffic, sc.rules.banked() + sc.rules.chain())
		sc.drain()


func _claims(c: NetScoreClient) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for q in c.queued():
		out.append(c.queued_claim(q))
	return out


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


# ---------------------------------------------------------------- Claims

func test_passes_are_claimed_with_tick_side_car_and_clearance() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	var right := sc.add_car(20.0, sc.lane_d(1) + sc.side_offset(2.0), 100.0)
	var left := sc.add_car(40.0, sc.lane_d(1) - sc.side_offset(0.4), 100.0)
	var c := _client()
	_drive(sc, c, 6.0)
	var claims := _claims(c)
	if not eq(claims.size(), 2, "one claim per scored pass"):
		return
	var e0 := sc.first(ScoreEvents.PASS)
	var e1 := sc.first(ScoreEvents.CLOSE_PASS)
	check(e0 >= 0 and e1 >= 0)
	eq(claims[0]["kind"], "pass")
	eq(claims[0]["side"], "right", "+d is right of travel")
	eq(claims[0]["cars"], [{"car_id": ID_BASE + right, "clearance_mm": roundi(sc.log_clear[e0] * 1000.0)}])
	eq(claims[0]["tick"], T0 + ceili(sc.log_time[e0] * RATE - 1e-9), "the tick it was paid")
	eq(claims[1]["kind"], "close_pass")
	eq(claims[1]["side"], "left")
	eq(claims[1]["cars"], [{"car_id": ID_BASE + left, "clearance_mm": roundi(sc.log_clear[e1] * 1000.0)}])
	near(float(claims[1]["cars"][0]["clearance_mm"]), 400.0, 2.0, "0.4 m measured")
	check(int(claims[1]["tick"]) > int(claims[0]["tick"]), "in event order")
	eq(c.claims_skipped, 0)


func test_a_thread_names_both_cars_after_its_passes() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	var a := sc.add_car(20.0, sc.lane_d(1) - sc.side_offset(0.9), 100.0)
	var b := sc.add_car(20.0 + (_kmh(150.0) - _kmh(100.0)) * 0.2, sc.lane_d(1) + sc.side_offset(1.2), 100.0)
	var c := _client()
	_drive(sc, c, 4.0)
	eq(sc.count(ScoreEvents.THREAD), 1, "the rules paid a thread")
	var claims := _claims(c)
	if not eq(claims.size(), 3, "close pass, pass, thread"):
		return
	eq(claims[0]["kind"], "close_pass")
	eq(claims[1]["kind"], "pass", "the second pass: its own claim first")
	eq(claims[2]["kind"], "thread")
	eq(claims[2]["tick"], claims[1]["tick"], "at the second pass's tick")
	eq(claims[2]["side"], "left", "the first car's side")
	var cars: Array = claims[2]["cars"]
	eq(cars.size(), 2)
	eq(cars[0]["car_id"], ID_BASE + a, "first car")
	eq(cars[1]["car_id"], ID_BASE + b, "second car")
	eq(cars[0]["clearance_mm"], claims[0]["cars"][0]["clearance_mm"], "each with its own clearance")
	eq(cars[1]["clearance_mm"], claims[1]["cars"][0]["clearance_mm"])
	eq(c.threads_unmatched, 0)


func test_a_cut_names_the_nearest_car() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	var car := sc.add_car(sc.gap_ahead(10.0), sc.lane_d(2), 150.0)
	sc.steer_to_lane(2, 6.0)
	var c := _client()
	_drive(sc, c, 1.0)
	eq(sc.count(ScoreEvents.CUT), 1)
	var claims := _claims(c)
	if eq(claims.size(), 1):
		eq(claims[0]["kind"], "cut")
		eq(claims[0]["side"], "none")
		eq(claims[0]["cars"], [{"car_id": ID_BASE + car, "clearance_mm": 0}])
		eq(claims[0]["tick"], T0 + ceili(sc.log_time[sc.first(ScoreEvents.CUT)] * RATE - 1e-9))


func test_local_cars_are_never_claimed() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	sc.add_car(20.0, sc.lane_d(1) + sc.side_offset(2.0), 100.0)
	var c := _client()
	c.wire_id = Callable()   # no network traffic yet: the local director's cars
	_drive(sc, c, 3.0)
	eq(sc.count(ScoreEvents.PASS), 1)
	eq(c.queued(), 0, "nothing claimed")
	eq(c.claims_skipped, 1)


func test_claims_reach_the_server_in_order() -> void:
	var time := NetVirtualTime.new(1_000_000)
	var link := NetLoopbackLink.new(time, Rng.new(7))
	link.latency_s = 0.03
	link.ordered = true
	var server := FakeScoreServer.new(link)
	var rs := NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	rs.quick_join()
	for i in 50:
		time.advance_s(0.01)
		server.poll()
		rs.poll()
	check(rs.is_in_room())
	var c := NetScoreClient.new(rs, net, t.scoring.thread_clearance_m)
	c.wire_id = func(slot: int) -> int: return ID_BASE + slot
	c.reset_run(T0)
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	sc.add_car(20.0, sc.lane_d(1) - sc.side_offset(0.9), 100.0)
	sc.add_car(20.0 + (_kmh(150.0) - _kmh(100.0)) * 0.2, sc.lane_d(1) + sc.side_offset(1.2), 100.0)
	sc.add_car(sc.gap_ahead(60.0), sc.lane_d(1) + sc.side_offset(3.0), 100.0)
	_drive(sc, c, 6.0)
	var want := _claims(c)
	c.flush()
	eq(c.queued(), 0)
	for i in 20:
		time.advance_s(0.01)
		server.poll()
		rs.poll()
	var got: Array[Dictionary] = server.claims
	if not eq(got.size(), want.size(), "every claim decoded by the server"):
		return
	for k in got.size():
		eq(got[k]["claim_id"], k + 1, "claim ids count up")
		for key: String in ["tick", "kind", "side", "cars"]:
			eq(got[k][key], want[k][key], "claim %d %s on the wire" % [k, key])
	eq(c.claims_sent, got.size())
	rs.close()


func test_the_tick_side_allocates_nothing() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	for k in 12:
		sc.add_car(20.0 + 9.0 * k, sc.lane_d(1) + (sc.side_offset(0.6) if k % 2 == 0 else -sc.side_offset(1.1)), 100.0)
	var c := _client()
	_drive(sc, c, 0.5)   # warm up
	var obj := Performance.get_monitor(Performance.OBJECT_COUNT)
	var grown := 0
	var claims_before := c.claims_queued
	for k in roundi(8.0 / DT):
		sc.player.s += sc.player.v * DT
		for i in sc.traffic.capacity:
			if sc.traffic.active[i] == 1:
				sc.traffic.s[i] += sc.traffic.v[i] * DT
		sc.time += DT
		sc.rules.step(DT, sc.player, sc.traffic, sc.road, sc.buf)
		var m0 := OS.get_static_memory_usage()
		c.observe(sc.buf, 0, sc.buf.size(), _tick(sc), sc.player.d, sc.traffic, sc.rules.banked() + sc.rules.chain())
		grown += OS.get_static_memory_usage() - m0
		sc.buf.clear()
		if c.queued() * 2 > net.score_claim_queue:
			c.flush()   # no session: counted as dropped, the queue empties
	gt(c.claims_queued - claims_before, 10, "claims made (%d)" % (c.claims_queued - claims_before))
	eq(grown, 0, "observe() allocates nothing")
	le(Performance.get_monitor(Performance.OBJECT_COUNT) - obj, 0.0, "no objects")


func test_a_full_queue_drops_and_counts() -> void:
	var c := _client()
	var buf := ScoreEventBuffer.new(net.score_claim_queue + 4)
	var ts := TrafficState.new(4)
	var i := ts.allocate()
	for k in net.score_claim_queue + 3:
		buf.push(ScoreEvents.CUT, 10, 1.0, -1.0, i)
	c.observe(buf, 0, buf.size(), T0, 0.0, ts, 0)
	eq(c.queued(), net.score_claim_queue)
	eq(c.claims_dropped, 3)


# ---------------------------------------------------------------- Official score

func _sync(c: NetScoreClient, tick: int, run_seq: int, banked: int, chain: int, banking: bool) -> void:
	c.on_message({"type": "score_sync", "tick": tick, "run_seq": run_seq, "banked": banked, "chain": chain,
		"multiplier_milli": 2000, "lives": 2, "crew_in_range": 1, "flags": {"banking": banking, "night": false,
		"unverified": false}})


## A local history: `total` from tick `from` on.
func _history(c: NetScoreClient, from: int, to: int, total: int) -> void:
	var buf := ScoreEventBuffer.new(1)
	var ts := TrafficState.new(1)
	for k in range(from, to + 1):
		c.observe(buf, 0, 0, k, 0.0, ts, total)


func test_history_answers_per_tick() -> void:
	var c := _client()
	_history(c, T0, T0 + 10, 100)
	_history(c, T0 + 14, T0 + 14, 250)   # ticks 11..13 keep the total before
	eq(c.local_total_at(T0 + 5), 100)
	eq(c.local_total_at(T0 + 13), 100, "a skipped tick holds the total before")
	eq(c.local_total_at(T0 + 14), 250)
	eq(c.local_total_at(T0 + 40), 250, "ahead of the newest: the newest")
	_history(c, T0 + 15, T0 + 15 + ceili(net.score_history_s * RATE) + 5, 300)
	eq(c.local_total_at(T0 + 5), -1, "older than the ring")


func test_equal_scores_change_nothing() -> void:
	var c := _client()
	_history(c, T0, T0 + 60, 480)
	_sync(c, T0 + 30, 1, 400, 80, true)
	eq(c.pending_offset, 0)
	c.advance(1.0)
	eq(c.display_offset(), 0)


func test_server_ahead_eases_up_at_banking() -> void:
	var c := _client()
	_history(c, T0, T0 + 30, 300)   # the local total 300 (a chain), then banked at 30
	_history(c, T0 + 31, T0 + 80, 300)
	# Mid-chain the server is ahead (a train the client can't see): not applied yet.
	_sync(c, T0 + 20, 1, 0, 375, false)
	eq(c.pending_offset, 75)
	c.advance(0.5)
	eq(c.display_offset(), 0, "no correction mid-chain")
	# The bank: official 375 banked vs local 300 at that tick.
	_sync(c, T0 + 30, 1, 375, 0, true)
	eq(c.offset_target, 75.0)
	c.advance(net.score_ease_up_s * 0.5)
	var mid := c.display_offset()
	check(mid > 0 and mid < 75, "eases up (%d)" % mid)
	c.advance(net.score_ease_up_s * 0.5 + 0.01)
	eq(c.display_offset(), 75, "there within score_ease_up_s")


func test_server_behind_eases_down_never_in_one_jump() -> void:
	var c := _client()
	_history(c, T0, T0 + 80, 1000)
	_sync(c, T0 + 40, 1, 960, 0, true)   # a rejected claim: 40 fewer
	eq(c.offset_target, -40.0)
	var prev := c.display_offset()
	var steps := 0
	var frame := 1.0 / 60.0
	for k in roundi(net.score_ease_down_s / frame) + 2:
		c.advance(frame)
		var now := c.display_offset()
		check(now <= prev, "monotone")
		check(prev - now <= 2, "a point or so per frame, not a jump (%d -> %d)" % [prev, now])
		if now != prev:
			steps += 1
		prev = now
	eq(c.display_offset(), -40, "there after score_ease_down_s")
	gt(steps, 20, "many small steps")


func test_syncs_of_the_run_before_are_ignored() -> void:
	var c := _client()
	_history(c, T0, T0 + 40, 500)
	_sync(c, T0 + 20, 3, 900, 0, true)
	eq(c.offset_target, 400.0)
	# A respawn: the local run starts over at T0 + 100.
	c.reset_run(T0 + 100)
	eq(c.display_offset(), 0, "a new run starts without a correction")
	_history(c, T0 + 100, T0 + 140, 50)
	_sync(c, T0 + 90, 3, 900, 0, true)   # still the old run's timeline
	eq(c.offset_target, 0.0, "dated before the run started")
	_sync(c, T0 + 120, 2, 10, 0, true)
	eq(c.offset_target, 0.0, "an older run_seq is ignored")
	_sync(c, T0 + 120, 4, 50, 0, true)
	eq(c.offset_target, 0.0, "the new run agrees")
	eq(c.official_run_seq, 4)


# ---------------------------------------------------------------- Crew and trains

func _crew_room(slots: Array) -> NetRoomState:
	var r := NetRoomState.new()
	var members := [{"player_id": 0, "identity": {"account_id": "1", "display_name": "Me", "name_tag": 1},
		"crew_tag": "", "crew_slot": 0, "flags": {"host": true, "disconnected": false}}]
	for k in slots.size():
		members.append({"player_id": k + 1, "identity": {"account_id": str(k + 2), "display_name": "P%d" % k,
			"name_tag": k}, "crew_tag": "", "crew_slot": slots[k], "flags": {"host": false, "disconnected": false}})
	r.apply_snapshot({"room_id": 1, "code": "ABC234", "you": 0, "tick": 0, "settings": {}, "clock": {},
		"members": members, "crews": [{"crew_slot": 0, "color": 0, "session_total": 12345}]})
	return r


## Remote players at `ds` metres from `me_s` (wrapped), sampled now.
func _remotes(me_s: float, ds: Array, length: float, run_state: int = NetRoomSession.RUN_DRIVING) -> NetRemotePlayers:
	var p := NetRemotePlayers.new(net.room_max_remotes, net.room_track_samples, length, RATE, net.room_snap_distance_m)
	for k in ds.size():
		var slot := p.acquire(k + 1)
		var s := fposmod(me_s + float(ds[k]), length)
		p.tracks[slot].push(100, s, 3.5, 0.0, 40.0, 0, run_state)
		p.tracks[slot].push(101, s, 3.5, 0.0, 40.0, 0, run_state)
	p.sample_all(101.0, 5.0, 10.0)
	return p


func test_crew_factor_counts_crewmates_within_30_m() -> void:
	var c := _client()
	var l := 25000.0
	c.update_crew(_remotes(1000.0, [10.0, -25.0, 45.0, 5.0], l), _crew_room([0, 0, 0, 1]), 1000.0, l)
	eq(c.crew_in_range, 2, "10 m ahead and 25 m behind; not 45 m, not another crew")
	near(c.crew_factor, 1.5, 1e-9, "+0.25× each")
	c.update_crew(_remotes(10.0, [-20.0], l), _crew_room([0]), 10.0, l)
	eq(c.crew_in_range, 1, "across the loop's seam")
	c.update_crew(_remotes(1000.0, [1.0, 2.0, 3.0, 4.0, 5.0, 6.0], l), _crew_room([0, 0, 0, 0, 0, 0]), 1000.0, l)
	eq(c.crew_in_range, 6)
	near(c.crew_factor, net.crew_factor_cap, 1e-9, "capped at ×2")
	c.update_crew(_remotes(1000.0, [4.0], l, NetRoomSession.RUN_CRASHED), _crew_room([0]), 1000.0, l)
	eq(c.crew_in_range, 0, "a crashed crewmate's run is not going")
	near(NetScoreClient.factor_for(3, net), 1.75, 1e-9)


func test_trains_count_and_signal() -> void:
	var time := NetVirtualTime.new(1_000_000)
	var link := NetLoopbackLink.new(time, Rng.new(8))
	var rs := NetRoomSession.new(link.client, net, 25000.0, time)
	rs.enter_demo({"room_id": 1, "code": "ABC234", "you": 1, "tick": 10, "settings": {}, "clock": {},
		"members": [{"player_id": 1, "identity": {"account_id": "1", "display_name": "Me", "name_tag": 1},
			"crew_tag": "", "crew_slot": 0, "flags": {"host": true, "disconnected": false}}],
		"crews": [{"crew_slot": 0, "color": 0, "session_total": 777}]}, 10.0)
	var c := NetScoreClient.new(rs, net)
	var links: Array[int] = []
	var crew: Array[int] = []
	c.train.connect(func(l: int, _p: int) -> void: links.append(l))
	c.crew_train.connect(func(pid: int, l: int) -> void: crew.append(pid * 100 + l))
	for l: int in [2, 3]:
		c.on_message({"type": "score_event", "tick": 50, "player_id": 1, "kind": "train", "points": 25 * l,
			"multiplier_gain_milli": 2000, "link": l, "sector": 0, "ref_id": 41})
	c.on_message({"type": "score_event", "tick": 50, "player_id": 4, "kind": "train", "points": 50,
		"multiplier_gain_milli": 2000, "link": 4, "sector": 0, "ref_id": 41})
	eq(links, [2, 3] as Array[int])
	eq(crew, [404] as Array[int], "a crewmate's link")
	eq(c.run_trains, 2, "the run's trains")
	eq(c.last_link, 3)
	check(c.train_shown())
	c.advance(net.train_show_s + 0.01)
	check(not c.train_shown(), "the badge goes after train_show_s")
	eq(c.crew_total(), 777, "the session crew total")
	c.reset_run(60)
	eq(c.run_trains, 0, "a new run counts again")
	var rejected: Array[int] = []
	c.claim_rejected.connect(func(id: int) -> void: rejected.append(id))
	c.on_message({"type": "score_event", "tick": 70, "player_id": 1, "kind": "claim_rejected", "points": 0,
		"multiplier_gain_milli": 0, "link": 0, "sector": 0, "ref_id": 17})
	eq(rejected, [17] as Array[int])
	eq(c.claims_rejected, 1)
	c.detach()


func test_official_sector_bonuses_the_run_did_not_pay() -> void:
	var time := NetVirtualTime.new(1_000_000)
	var link := NetLoopbackLink.new(time, Rng.new(9))
	var rs := NetRoomSession.new(link.client, net, 25000.0, time)
	rs.enter_demo({"room_id": 1, "code": "ABC234", "you": 1, "tick": 10, "settings": {}, "clock": {},
		"members": [], "crews": []}, 10.0)
	var c := NetScoreClient.new(rs, net)
	c.reset_run(0)
	var shown: Array[StringName] = []
	c.sector_bonus.connect(func(k: StringName, _p: int, _s: int) -> void: shown.append(k))
	# The local run paid CLEAN at tick 1000 (its sector toast showed it).
	var buf := ScoreEventBuffer.new(4)
	buf.push(ScoringRuleSet.KIND_BONUS, 5000, 0.0, -1.0, -1, 5000.0, LegTracker.BONUS_CLEAN)
	c.observe(buf, 0, 1, 1000, 0.0, TrafficState.new(1), 5000)
	for kind: String in ["sector_clean", "sector_pace"]:
		c.on_message({"type": "score_event", "tick": 1030, "player_id": 1, "kind": kind, "points": 3000,
			"multiplier_gain_milli": 0, "link": 0, "sector": 2, "ref_id": 0})
	eq(shown, [LegTracker.BONUS_PACE] as Array[StringName], "only the one the run did not pay")
	c.on_message({"type": "score_event", "tick": 1030, "player_id": 3, "kind": "sector_heat", "points": 3000,
		"multiplier_gain_milli": 0, "link": 0, "sector": 2, "ref_id": 0})
	eq(shown.size(), 1, "another player's bonus is theirs")
	c.detach()
