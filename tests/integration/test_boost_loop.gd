extends "res://tests/integration/run_harness.gd"
## WP4.5: boost hooked into physics, in the full loop. Spec: Scoring → Boost ("The
## boost meter fills from slipstream, close passes and threads. Full meter = 3 seconds
## of extra thrust and +8% top speed. Boost gives no points directly, but it raises
## the speed factor and makes the multiplier decay more slowly"); Car physics and feel
## (boost). The fills themselves are checked where they are earned (test_scoring_loop:
## close pass +10%, thread +25%, slipstream +20%/s); camera and HUD only listening is
## checked in test_fairness (the same run with and without them).

const FAST_MPS := 45.0
const SLOW_MPS := 30.0
const START_KMH := 150.0


## A full meter gives boost_full_s (x the car's capacity) of extra thrust; a meter under
## the start minimum does not start one. The boosted run gains speed on the same inputs.
func test_full_meter_gives_three_seconds_of_extra_thrust() -> void:
	var v_end := PackedFloat64Array()
	var v0 := Units.kmh_to_mps(START_KMH)
	var duration := t.scoring.boost_full_s
	for boosted: bool in [false, true]:
		_log.clear()
		var r := _make()
		var drv := _go_quiet(r, v0)
		drv.full_throttle = true
		duration = t.scoring.boost_full_s * r.car.car.boost_capacity_scale
		# Too little meter: the request is refused.
		r.car.state.boost_meter = 0.5 * Units.pct_to_frac(t.vehicle.boost_start_min_pct)
		drv.request_boost()
		_run_ticks(r, TICKS_PER_FRAME)
		check(not r.car.state.boost_active, "no boost below the start minimum")
		eq(_count("boost_started"), 0)
		# A full meter (as if earned), then the request (the controller's edge).
		r.car.state.boost_meter = 1.0
		_run_ticks(r, TICKS_PER_FRAME)
		var start_tick := r.tick_count
		if boosted:
			drv.request_boost()
		_run_s(r, duration + 0.5)
		v_end.append(r.car.state.v)
		if boosted:
			eq(_count("boost_started"), 1, "boost_started on the bus")
			eq(_count("boost_ended"), 1, "boost_ended on the bus")
			var ran_s := float(_last("boost_ended")[0] - start_tick) * _dt()
			near(ran_s, duration, 3.0 * _dt(), "a full meter lasts boost_full_s x capacity")
			eq(r.car.state.boost_meter, 0.0, "the meter is spent")
			var fills := _entries("boost_meter_changed")
			ge(fills.size(), 3, "the meter drains on the bus")
			lt(float(fills[-1][2]), float(fills[0][2]))
		else:
			eq(_count("boost_started"), 0)
			eq(r.car.state.boost_meter, 1.0, "unused")
		eq(r.scoring.chain(), 0, "boost gives no points directly")
		await _drop(r)
	# Below the car's top speed the boost adds boost_thrust_mps2 on top of the engine
	# (the gain is a little less: at the higher speed the engine pulls less, drag more).
	var gain := v_end[1] - v_end[0]
	print("      boost: +%.1f km/h over %.1f s at full throttle from %.0f km/h" % [
		Units.mps_to_kmh(gain), duration, START_KMH])
	gt(gain, 0.5 * t.vehicle.boost_thrust_mps2 * duration, "extra thrust in the real physics")
	lt(gain, t.vehicle.boost_thrust_mps2 * duration + 0.1, "no more than the boost thrust")


## +8% top speed: at the car's top speed at full throttle the car holds it; with the
## meter kept full it settles at top speed x (1 + boost_top_speed_bonus_pct).
func test_boost_raises_top_speed_by_eight_percent() -> void:
	var r := _make()
	var top := r.car.params.top_speed_mps
	var boost_top := top * (1.0 + Units.pct_to_frac(t.vehicle.boost_top_speed_bonus_pct))
	near(r.car.params.boost_top_speed_mps, boost_top, 1e-6)
	var drv := _go_quiet(r, top)
	drv.full_throttle = true
	_run_s(r, 3.0)
	near(r.car.state.v, top, top * 0.005, "no boost: the car holds its top speed")
	r.car.state.boost_meter = 1.0
	drv.request_boost()
	var v_max := 0.0
	for i in _ticks_for(20.0):
		r.car.state.boost_meter = 1.0   # kept full, so the boost never runs out
		_run_ticks(r, 1)
		v_max = maxf(v_max, r.car.state.v)
	check(r.car.state.boost_active)
	print("      boost top speed: %.1f km/h (top %.1f, x%.3f)" % [
		Units.mps_to_kmh(r.car.state.v), Units.mps_to_kmh(top), r.car.state.v / top])
	within_pct(r.car.state.v, boost_top, 0.01, "settles at +8%")
	le(v_max, boost_top * 1.001, "never beyond it")
	eq(r.lives.hits, 0)


## While boosting the multiplier decays at scoring.boost_decay_factor (0.5) of its rate
## at the same speed; measured tick by tick in the run.
func test_multiplier_decays_slower_while_boosting() -> void:
	var r := _make()
	var drv := _go_quiet(r, FAST_MPS)
	drv.full_throttle = false
	drv.v_target = FAST_MPS
	# A thread: 1.0 -> 2.0 -> 3.0 -> 8.0x.
	var left_d := _d_for_clearance(r, _lane_d(r, 1), 1.2, -1.0) - _lane_d(r, 0)
	var right_d := _d_for_clearance(r, _lane_d(r, 1), 1.2, 1.0) - _lane_d(r, 2)
	_spawn(r, 30.0, 0, SLOW_MPS, left_d)
	_spawn(r, 30.0, 2, SLOW_MPS, right_d)
	check(_run_until(r, func() -> bool: return not _scored(ScoreEvents.THREAD).is_empty(), 5.0), "thread")
	_run_s(r, 0.5)
	gt(r.scoring.multiplier(), 5.0, "a multiplier to decay")
	var sc := t.scoring
	var dt := _dt()
	var plain := _decay_tick(r)
	near(plain[0], sc.multiplier_decay_per_s * sc.decay_term(plain[1]) * dt, 1e-9, "normal decay")
	r.car.state.boost_meter = 1.0
	drv.request_boost()
	check(_run_until(r, func() -> bool: return r.car.state.boost_active, 0.5), "boosting")
	var boosted := _decay_tick(r)
	near(boosted[0], sc.multiplier_decay_per_s * sc.decay_term(boosted[1]) * sc.boost_decay_factor * dt, 1e-9,
		"boost: decay x boost_decay_factor")
	lt(boosted[0], plain[0], "slower while boosting")
	eq(_count("boost_started"), 1)


## One tick's multiplier decay and the speed scoring saw: [decay, v].
func _decay_tick(r: Run) -> PackedFloat64Array:
	var m0 := r.scoring.multiplier()
	r.tick()
	return PackedFloat64Array([m0 - r.scoring.multiplier(), r.car.state.v])
