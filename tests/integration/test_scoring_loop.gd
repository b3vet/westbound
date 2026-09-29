extends "res://tests/integration/run_harness.gd"
## WP4.5: every scoring event fires on the Events bus in a real run (Run scene, real
## VehiclePhysics, TrafficSim, HitDetection, Lives, Scoring, SunClock, LegTracker and
## the RunEvents adapter), each from a targeted scripted scenario on a quiet road.
## Spec: Scoring → Scoring events (pass, close pass, cut, thread, slipstream),
## Multiplier (minimum speed / TOO SLOW, hesitation, shoulder penalty), Chain and
## banking (cash-out, checkpoint, bonuses), Boost (fills from close passes, threads,
## slipstream). docs/SCORING.md has the rules as implemented.

## The player's cruising speed in the passing scenarios (162 km/h) and the traffic's.
const FAST_MPS := 45.0
const SLOW_MPS := 30.0


func test_pass_then_cash_out() -> void:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	_spawn(r, 40.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return not _scored(ScoreEvents.PASS).is_empty(), 6.0), "passed")
	var passes := _scored(ScoreEvents.PASS)
	eq(passes.size(), 1, "one pass")
	eq(_scored(ScoreEvents.CLOSE_PASS).size(), 0, "a lane apart is not close")
	var pass_e: Array = passes[0]
	eq(pass_e[4], 1.0, "paid at 1.0x (before its own gain)")
	var sf := t.scoring.speed_factor(r.car.state.v)
	near(float(pass_e[3]), float(t.scoring.pass_points) * sf, 1.0, "10 x 1.0 x speed factor")
	gt(float(pass_e[5]), t.scoring.close_pass_clearance_m, "clearance on the bus")
	eq(r.scoring.chain(), pass_e[3])
	# Holding speed above the minimum: the multiplier decays back to 1.0x and the chain banks.
	check(_run_until(r, func() -> bool: return not _entries("chain_banked").is_empty(), 8.0), "cashed out")
	var bank: Array = _last("chain_banked")
	eq(bank[2], pass_e[3], "the whole chain banks")
	eq(bank[3], Events.REASON_CASH_OUT)
	eq(bank[4], pass_e[3], "banked total")
	eq(r.scoring.banked(), pass_e[3])
	eq(r.scoring.chain(), 0)


func test_close_pass_fills_the_boost_meter() -> void:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	var car_d := _lane_d(r, 0)
	drv.target_d = _d_for_clearance(r, car_d, 0.6, 1.0)
	_spawn(r, 60.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return not _scored(ScoreEvents.CLOSE_PASS).is_empty(), 6.0), "close pass")
	_run_ticks(r, TICKS_PER_FRAME)
	var close: Array = _scored(ScoreEvents.CLOSE_PASS)
	eq(close.size(), 1)
	eq(_scored(ScoreEvents.PASS).size(), 0, "a close pass replaces the pass")
	lt(float(close[0][5]), t.scoring.close_pass_clearance_m, "under 1.0 m")
	near(float(close[0][3]), float(t.scoring.close_pass_points) * t.scoring.speed_factor(r.car.state.v), 1.5,
		"30 x 1.0 x speed factor")
	near(r.scoring.multiplier(), 1.0 + t.scoring.close_pass_multiplier_gain, 0.05, "+3")
	near(r.car.state.boost_meter, Units.pct_to_frac(t.scoring.boost_fill_close_pass_pct), 1e-9, "boost +10%")
	near(float(_last("boost_meter_changed")[2]), r.car.state.boost_meter, 1e-9, "the meter on the bus")
	eq(_count("slipstream_changed"), 0, "not in the car's lane: no slipstream")


func test_thread_between_two_cars() -> void:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	# One car each side, both leaning toward the player's lane: 1.2 m clearance each.
	var left_d := _d_for_clearance(r, _lane_d(r, 1), 1.2, -1.0) - _lane_d(r, 0)
	var right_d := _d_for_clearance(r, _lane_d(r, 1), 1.2, 1.0) - _lane_d(r, 2)
	_spawn(r, 60.0, 0, SLOW_MPS, left_d)
	_spawn(r, 60.0, 2, SLOW_MPS, right_d)
	check(_run_until(r, func() -> bool: return not _scored(ScoreEvents.THREAD).is_empty(), 6.0), "thread")
	_run_ticks(r, TICKS_PER_FRAME)
	eq(_scored(ScoreEvents.PASS).size(), 2, "the two passes")
	var thread: Array = _scored(ScoreEvents.THREAD)
	eq(thread.size(), 1)
	# Passes at 1.0x and 2.0x, then the thread at 3.0x.
	eq(thread[0][4], 1.0 + 2.0 * t.scoring.pass_multiplier_gain, "paid on top of both passes")
	near(float(thread[0][3]), float(t.scoring.thread_points) * thread[0][4] * t.scoring.speed_factor(r.car.state.v),
		3.0, "50 x multiplier x speed factor")
	lt(float(thread[0][5]), t.scoring.thread_clearance_m)
	near(r.car.state.boost_meter, Units.pct_to_frac(t.scoring.boost_fill_thread_pct), 1e-9, "boost +25%")
	var lifted := _entries("sun_lifted")
	eq(lifted.size(), 1, "a thread lifts the sun")
	near(float(lifted[0][2]), Units.pct_to_frac(t.sun.thread_nudge_pct), 1e-9, "1% of the day span")


func test_slipstream_on_and_off() -> void:
	var r := _make()
	var v := Units.kmh_to_mps(135.0)
	var drv := _go_quiet(r, v)
	# A car 12 m ahead (boxes' centers) in the player's lane at the same speed.
	_spawn(r, 12.0, 1, v)
	check(_run_until(r, func() -> bool: return not _entries("slipstream_changed").is_empty(), 1.0), "slipstream on")
	eq(_last("slipstream_changed")[2], true)
	check(r.scoring.is_slipstreaming())
	var meter0 := r.car.state.boost_meter
	_run_s(r, 2.0)
	near(r.car.state.boost_meter - meter0, 2.0 * Units.pct_to_frac(t.scoring.boost_fill_slipstream_pct_per_s),
		0.01, "+20% per second")
	eq(r.scoring.chain(), 0, "slipstream scores no points")
	eq(r.scoring.multiplier(), 1.0, "and no multiplier")
	# Pull out into the next lane: it ends.
	drv.target_d = _lane_d(r, 2)
	check(_run_until(r, func() -> bool: return _last("slipstream_changed")[2] == false, 2.0), "slipstream off")
	eq(_count("slipstream_changed"), 2)


func test_cut_scores_once_per_car_per_three_seconds() -> void:
	var r := _make()
	var v := Units.kmh_to_mps(155.0)
	var drv := _go_quiet(r, v)
	# A car in lane 1 a short gap ahead at the player's speed: every crossing of the
	# lane 1 / lane 2 line has it in the lane left or entered.
	var slot := _spawn(r, 13.0, 1, v)
	var crossings := 0
	var lane := r.road.lane_index_at(r.car.state.d, r.car.state.s)
	var flip := _ticks_for(1.6)
	var total := _ticks_for(9.0)
	for i in total:
		if i % flip == flip - 1:
			drv.target_d = _lane_d(r, 2) if drv.target_d < _lane_d(r, 2) - 0.1 else _lane_d(r, 1)
		_run_ticks(r, 1)
		var now := r.road.lane_index_at(r.car.state.d, r.car.state.s)
		if now >= 0 and now != lane:
			crossings += 1
			lane = now
	_run_ticks(r, TICKS_PER_FRAME)
	var cuts := _scored(ScoreEvents.CUT)
	ge(cuts.size(), 2, "cuts scored with the car nearby")
	gt(crossings, cuts.size(), "more lane crossings than cuts: the per-car cooldown held")
	var gap := r.sim.state.s[slot] - r.car.state.s - (r.sim.state.length[slot] + r.car.car.length_m) * 0.5
	lt(gap, t.scoring.cut_traffic_window_m, "the car stayed within the cut window")
	for k in range(1, cuts.size()):
		ge(float(cuts[k][0] - cuts[k - 1][0]) * _dt() + _dt(), t.scoring.cut_per_car_cooldown_s,
			"at most one cut per car per 3 s")
	eq(r.lives.hits, 0, "no contact")


func test_weaving_on_an_empty_road_scores_nothing() -> void:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = Units.kmh_to_mps(170.0)
	drv.target_d = _lane_d(r, 1)
	# Traffic only far away (outside the 15 m window) or two lanes over.
	_spawn(r, 60.0, 1, drv.v_target)
	var crossings := 0
	var lane := r.road.lane_index_at(r.car.state.d, r.car.state.s)
	var flip := _ticks_for(1.5)
	for i in _ticks_for(8.0):
		if i % flip == flip - 1:
			drv.target_d = _lane_d(r, 2) if drv.target_d < _lane_d(r, 2) - 0.1 else _lane_d(r, 1)
		_run_ticks(r, 1)
		var now := r.road.lane_index_at(r.car.state.d, r.car.state.s)
		if now >= 0 and now != lane:
			crossings += 1
			lane = now
	_run_ticks(r, TICKS_PER_FRAME)
	ge(crossings, 4, "the player weaved")
	eq(_scored(ScoreEvents.CUT).size(), 0, "no traffic nearby: no cut")
	eq(r.scoring.chain(), 0)
	eq(r.scoring.multiplier(), 1.0)


func test_too_slow_and_hesitation_lose_the_chain() -> void:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	_spawn(r, 30.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 5.0), "a chain")
	var chain := r.scoring.chain()
	# Brake under the minimum speed and stay there.
	drv.v_target = Units.kmh_to_mps(80.0)
	check(_run_until(r, func() -> bool: return not _entries("too_slow_changed").is_empty(), 4.0), "TOO SLOW")
	eq(_last("too_slow_changed")[2], true)
	var slow_tick: int = _last("too_slow_changed")[0]
	var sky0 := r.sun.sky_t
	check(_run_until(r, func() -> bool: return _count("hesitated") > 0, 5.0), "HESITATED")
	var hes_tick: int = _last("hesitated")[0]
	near(float(hes_tick - slow_tick) * _dt(), t.scoring.hesitation_timeout_s, 0.05, "after 3 s below the minimum")
	eq(_entries_with("chain_lost", chain).size(), 1, "the chain is lost")
	eq(_last("chain_lost")[3], Events.REASON_HESITATED)
	eq(r.scoring.chain(), 0)
	eq(r.scoring.banked(), 0, "nothing banked: the dip below the minimum blocks the cash-out")
	eq(r.scoring.multiplier(), 1.0)
	gt(r.sun.sky_t - sky0, 0.0)
	# Back above the minimum: TOO SLOW clears.
	drv.v_target = FAST_MPS
	check(_run_until(r, func() -> bool: return _last("too_slow_changed")[2] == false, 5.0), "TOO SLOW off")
	eq(_count("hesitated"), 1, "once per slow stretch")


func test_passing_on_the_shoulder_scores_nothing_and_penalizes() -> void:
	var r := _make()
	var drv := _go_quiet(r)
	var lanes := r.road.lane_count(r.car.state.s)
	var s := r.car.state.s
	var shoulder_d := (r.road.lanes_right_edge_d(s) + r.road.shoulder_outer_d(s)) * 0.5
	drv.v_target = Units.kmh_to_mps(150.0)
	drv.target_d = shoulder_d
	# A slow car in the slow lane, passed while on the outer shoulder (well inside the
	# 5.4 m pass window).
	_spawn(r, 90.0, lanes - 1, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.is_on_shoulder(), 4.0), "on the shoulder")
	check(_run_until(r, func() -> bool: return _count("shoulder_penalty_changed") > 0, 3.0), "the shoulder penalty")
	eq(_last("shoulder_penalty_changed")[2], true, "after 2 s on the shoulder")
	var slot_passed := func() -> bool:
		for i in r.sim.state.capacity:
			if r.sim.state.active[i] != 0 and r.sim.state.s[i] < r.car.state.s - r.car.car.length_m * 2.0:
				return true
		return false
	check(_run_until(r, slot_passed, 8.0), "the car was passed")
	_run_ticks(r, TICKS_PER_FRAME)
	eq(_count("scored"), 0, "passing on the shoulder scores nothing")
	eq(r.lives.hits, 0)
	# Back in lane: the penalty holds 3 s more, then clears.
	drv.target_d = _lane_d(r, 1)
	check(_run_until(r, func() -> bool: return not r.scoring.is_on_shoulder(), 4.0), "off the shoulder")
	var off_tick := r.tick_count
	check(_run_until(r, func() -> bool: return _last("shoulder_penalty_changed")[2] == false, 5.0), "penalty over")
	near(float(_last("shoulder_penalty_changed")[0] - off_tick) * _dt(), t.scoring.shoulder_penalty_block_s, 0.05,
		"3 s after leaving the shoulder")


func test_checkpoint_banks_the_chain_and_pays_the_bonus() -> void:
	var r := _make()
	var v := Units.kmh_to_mps(220.0)
	_go_quiet(r, v)
	_spawn(r, 25.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 3.0), "a chain")
	var chain := r.scoring.chain()
	# To just before the checkpoint (the leg keeps counting from its start); the
	# multiplier barely decays at this speed, so the chain is still held at the line.
	var cp := r.legs.distance_to_checkpoint(r.car.state.s)
	r.dev_teleport(r.car.state.s + cp - 15.0, v)
	check(_run_until(r, func() -> bool: return r.legs.legs_completed == 1, 2.0), "crossed")
	_run_ticks(r, TICKS_PER_FRAME)
	var banks := _entries_with("chain_banked", chain)
	eq(banks.size(), 1, "the chain banks at the line")
	if not banks.is_empty():
		eq(banks[0][3], Events.REASON_CHECKPOINT)
	var clean := _entries_with("bonus_awarded", LegTracker.BONUS_CLEAN)
	eq(clean.size(), 1, "the clean-leg bonus")
	if not clean.is_empty():
		eq(clean[0][3], t.legs.bonus_clean_points, "day: x1")
	eq(_count("checkpoint_crossed"), 1)
	ge(r.scoring.banked(), chain + t.legs.bonus_clean_points)
