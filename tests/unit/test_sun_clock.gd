extends WBTest
## SunClock suite. Spec: Core loop -> Sky timeline and sun clock, Night; Tuning
## reference ("Sunset time from full day", "Checkpoint sun lift"). Contract:
## docs/CONTRACTS.md section 8. Timeline math: docs/CORE_LOOP.md.

const DETERMINISM_SEED := 4242
const DETERMINISM_S := 900.0
## Tolerance on sky_t positions (pure float math on keyframe values).
const T_EPS := 1e-9

var t: Tuning
var sun: SunTuning
var legs: LegsTuning
var dt: float
var buf: ScoreEventBuffer


func before_all() -> void:
	t = Tuning.load_default()
	sun = t.sun
	legs = t.legs
	dt = t.vehicle.physics_dt()


func before_each() -> void:
	buf = ScoreEventBuffer.new(64)


func _clock() -> SunClock:
	var c := SunClock.new(sun, legs)
	c.reset()
	return c


func _count(kind: StringName) -> int:
	var n := 0
	for i in buf.size():
		if buf.kind[i] == kind:
			n += 1
	return n


func _last_value(kind: StringName) -> float:
	var v := NAN
	for i in buf.size():
		if buf.kind[i] == kind:
			v = buf.value[i]
	return v


## Advances until night starts (or max_s). Returns the elapsed simulated time.
func _run_to_sunset(c: SunClock, too_slow: bool, max_s: float = 1000.0) -> float:
	var ticks := 0
	var max_ticks := int(max_s / dt)
	while not c.is_night() and ticks < max_ticks:
		c.advance(dt, too_slow, buf)
		ticks += 1
	return float(ticks) * dt


func _advance_s(c: SunClock, seconds: float, too_slow: bool = false) -> void:
	for i in int(round(seconds / dt)):
		c.advance(dt, too_slow, buf)


# ---------------------------------------------------------------- Day

func test_reset_starts_in_the_afternoon() -> void:
	var c := _clock()
	near(c.sky_t, sun.sky_t_run_start, T_EPS)
	check(not c.is_night())
	check(not c.is_dawning())
	near(c.sun_height(), 1.0, T_EPS, "full bar at the run start")


func test_five_minutes_to_sunset_at_base_rate() -> void:
	var c := _clock()
	var elapsed := _run_to_sunset(c, false)
	near(elapsed, Units.min_to_s(sun.sunset_from_start_min), dt * 1.5, "run start -> sunset")
	eq(_count(SunClock.KIND_NIGHT_STARTED), 1)


func test_too_slow_sinks_three_times_faster() -> void:
	var c := _clock()
	var elapsed := _run_to_sunset(c, true)
	near(elapsed, Units.min_to_s(sun.sunset_from_start_min) / sun.too_slow_sink_factor, dt * 1.5)
	# Mixed: half the day span too slow, the rest at base.
	c.reset()
	var half := sun.day_span() * 0.5
	var ticks := 0
	while c.sky_t < sun.sky_t_run_start + half:
		c.advance(dt, true, buf)
		ticks += 1
	near(float(ticks) * dt, Units.min_to_s(sun.sunset_from_start_min) * 0.5 / sun.too_slow_sink_factor, dt * 1.5)


func test_sun_height_tracks_the_day() -> void:
	var c := _clock()
	_advance_s(c, Units.min_to_s(sun.sunset_from_start_min) * 0.5)
	near(c.sun_height(), 0.5, 0.01, "halfway to sunset")
	_run_to_sunset(c, false)
	near(c.sun_height(), 0.0, T_EPS, "sunset")
	_advance_s(c, 60.0)
	near(c.sun_height(), 0.0, T_EPS, "night")


# ---------------------------------------------------------------- Lifts

func test_lift_never_earlier_than_run_start() -> void:
	var c := _clock()
	_advance_s(c, 10.0)
	var before := c.sky_t
	c.lift(Units.pct_to_frac(sun.checkpoint_lift_pct), buf)
	near(c.sky_t, sun.sky_t_run_start, T_EPS, "clamped at the run start")
	near(_last_value(SunClock.KIND_SUN_LIFTED), (before - sun.sky_t_run_start) / sun.day_span(), T_EPS,
		"event carries the lift actually applied")
	# Already at the run start: nothing to lift, no event.
	buf.clear()
	c.lift(Units.pct_to_frac(sun.thread_nudge_pct), buf)
	near(c.sky_t, sun.sky_t_run_start, T_EPS)
	eq(_count(SunClock.KIND_SUN_LIFTED), 0)
	# Checkpoints clamp too, at any pace.
	c.on_checkpoint(Units.kmh_to_mps(300.0), buf)
	near(c.sky_t, sun.sky_t_run_start, T_EPS)
	ge(c.sky_t, sun.sky_t_run_start - T_EPS)


func test_thread_and_close_pass_nudges_lift_one_percent() -> void:
	var c := _clock()
	_advance_s(c, 120.0)
	var before := c.sky_t
	c.lift(Units.pct_to_frac(sun.thread_nudge_pct), buf)
	near(before - c.sky_t, Units.pct_to_frac(sun.thread_nudge_pct) * sun.day_span(), T_EPS, "thread nudge")
	near(_last_value(SunClock.KIND_SUN_LIFTED), Units.pct_to_frac(sun.thread_nudge_pct), T_EPS)
	before = c.sky_t
	c.lift(Units.pct_to_frac(sun.close_pass_nudge_pct), buf)
	near(before - c.sky_t, Units.pct_to_frac(sun.close_pass_nudge_pct) * sun.day_span(), T_EPS, "close-pass nudge")
	eq(_count(SunClock.KIND_SUN_LIFTED), 2)


func test_checkpoint_lift_and_pace_bonus_bounds() -> void:
	var target := legs.pace_target_mps()
	var margin := legs.pace_full_lift_margin_mps()
	var base := Units.pct_to_frac(sun.checkpoint_lift_pct)
	var extra := Units.pct_to_frac(sun.checkpoint_pace_lift_max_pct)
	# [avg speed, expected lift fraction]
	var cases: Array[PackedFloat64Array] = [
		PackedFloat64Array([0.0, base]),
		PackedFloat64Array([target * 0.5, base]),
		PackedFloat64Array([target, base]),
		PackedFloat64Array([target + margin * 0.5, base + extra * 0.5]),
		PackedFloat64Array([target + margin, base + extra]),
		PackedFloat64Array([target + margin * 4.0, base + extra]),
	]
	for cs in cases:
		var c := _clock()
		_advance_s(c, Units.min_to_s(sun.sunset_from_start_min) - 1.0)   # near sunset: no clamp
		buf.clear()
		var before := c.sky_t
		c.on_checkpoint(cs[0], buf)
		near((before - c.sky_t) / sun.day_span(), cs[1], T_EPS, "lift at avg %.1f m/s" % cs[0])
		near(_last_value(SunClock.KIND_SUN_LIFTED), cs[1], T_EPS)
		ge(cs[1], base - T_EPS)
		le(cs[1], base + extra + T_EPS, "pace bonus capped")
		check(not c.is_night())


# ---------------------------------------------------------------- Night

func test_sunset_starts_night_once() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	check(c.is_night())
	_advance_s(c, 120.0, true)
	eq(_count(SunClock.KIND_NIGHT_STARTED), 1, "night_started exactly once")
	check(c.is_night())


func test_nightfall_runs_to_the_night_key_and_holds() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	var prev := c.sky_t
	ge(prev, sun.sky_t_sunset)
	var ticks := 0
	while c.sky_t < sun.sky_t_night and ticks < 100000:
		c.advance(dt, false, buf)
		ge(c.sky_t, prev, "nightfall moves forward")
		prev = c.sky_t
		ticks += 1
	near(float(ticks) * dt, sun.nightfall_s, dt * 1.5, "sunset -> night key over nightfall_s")
	near(c.sky_t, sun.sky_t_night, T_EPS, "holds exactly at the night key")


func test_night_has_no_timer() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	_advance_s(c, sun.nightfall_s + 1.0)
	buf.clear()
	for i in 3600 * 20:   # an hour, too slow half the time
		c.advance(0.05, i % 2 == 0, buf)
	check(c.is_night(), "still night after an hour")
	near(c.sky_t, sun.sky_t_night, T_EPS)
	eq(buf.size(), 0, "no events at night")
	# Lifts do nothing at night.
	c.lift(0.5, buf)
	near(c.sky_t, sun.sky_t_night, T_EPS)
	eq(buf.size(), 0)


# ---------------------------------------------------------------- Dawn

func test_dawn_transition_exactly_six_seconds_and_lands_at_morning() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	_advance_s(c, sun.nightfall_s + 5.0)
	buf.clear()
	c.on_checkpoint(legs.pace_target_mps(), buf)
	check(not c.is_night(), "dawn ends the night at once")
	check(c.is_dawning())
	eq(_count(SunClock.KIND_DAWN_STARTED), 1)
	near(_last_value(SunClock.KIND_DAWN_STARTED), sun.dawn_transition_s, T_EPS, "dawn_started(6)")
	eq(_count(SunClock.KIND_SUN_LIFTED), 0, "a night checkpoint does not lift")
	var ticks := 0
	var passed_dawn_key := false
	var prev := c.sky_t
	while _count(SunClock.KIND_MORNING_REACHED) == 0 and ticks < 100000:
		c.advance(dt, true, buf)   # too slow has no effect on the dawn
		ticks += 1
		if c.is_dawning():
			gt(c.sky_t, prev, "dawn moves forward")
			prev = c.sky_t
			if c.sky_t >= sun.sky_t_dawn:
				passed_dawn_key = true
	eq(ticks, int(round(sun.dawn_transition_s / dt)), "exactly 6 s of ticks")
	check(passed_dawn_key, "night -> dawn -> morning")
	check(not c.is_dawning())
	check(not c.is_night())
	near(c.sky_t, sun.sky_t_morning, T_EPS, "lands at morning")
	lt(c.sky_t, sun.sky_t_run_start, "morning is earlier than the run start")
	# Day resumes from morning; a lift there cannot go below the run start's clamp.
	_advance_s(c, 1.0)
	gt(c.sky_t, sun.sky_t_morning)
	var before := c.sky_t
	buf.clear()
	c.lift(0.4, buf)
	near(c.sky_t, before, T_EPS, "already earlier than the run start: no lift")
	# From morning, sunset comes after (sunset - morning) / base rate.
	c.reset()
	_run_to_sunset(c, false)
	_advance_s(c, sun.nightfall_s)
	c.on_checkpoint(0.0, buf)
	_advance_s(c, sun.dawn_transition_s)
	var elapsed := _run_to_sunset(c, false)
	near(elapsed, (sun.sky_t_sunset - sun.sky_t_morning) / sun.base_sink_per_s(), dt * 2.0)


func test_checkpoint_during_nightfall_brings_dawn() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	_advance_s(c, sun.nightfall_s * 0.5)
	check(c.is_night())
	lt(c.sky_t, sun.sky_t_night)
	c.on_checkpoint(0.0, buf)
	check(c.is_dawning())
	_advance_s(c, sun.dawn_transition_s)
	eq(_count(SunClock.KIND_MORNING_REACHED), 1)
	near(c.sky_t, sun.sky_t_morning, T_EPS)


func test_lifts_and_checkpoints_ignored_while_dawning() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	c.on_checkpoint(0.0, buf)
	_advance_s(c, 1.0)
	buf.clear()
	var before := c.sky_t
	c.lift(0.5, buf)
	c.on_checkpoint(0.0, buf)
	near(c.sky_t, before, T_EPS)
	eq(buf.size(), 0)
	check(c.is_dawning())


func test_sun_height_rises_through_the_dawn() -> void:
	var c := _clock()
	_run_to_sunset(c, false)
	c.on_checkpoint(0.0, buf)
	near(c.sun_height(), 0.0, T_EPS)
	_advance_s(c, sun.dawn_transition_s * 0.5)
	near(c.sun_height(), 0.5, 0.01)
	_advance_s(c, sun.dawn_transition_s * 0.5)
	near(c.sun_height(), 1.0, T_EPS)


# ---------------------------------------------------------------- Determinism and budget

func _trace(run_seed: int) -> int:
	var rng := Rng.new(run_seed).derive(&"sun_test")
	var c := _clock()
	var b := ScoreEventBuffer.new(64)
	var h := TraceHash.SEED
	var too_slow := false
	var ticks := int(DETERMINISM_S / dt)
	var per_s := int(round(1.0 / dt))
	for i in ticks:
		if rng.chance(0.002):
			too_slow = not too_slow
		if rng.chance(0.001):
			c.lift(Units.pct_to_frac(sun.thread_nudge_pct), b)
		if rng.chance(0.0003):
			c.on_checkpoint(rng.float_range(0.0, legs.pace_target_mps() * 1.5), b)
		c.advance(dt, too_slow, b)
		if i % per_s == 0:
			h = c.hash_into(h)
			h = b.hash_into(h)
			b.clear()
	eq(b.dropped, 0)
	return h


func test_determinism() -> void:
	var a := _trace(DETERMINISM_SEED)
	eq(_trace(DETERMINISM_SEED), a, "same seed, same trace")
	ne(_trace(DETERMINISM_SEED + 1), a, "different seed, different trace")


func test_advance_allocation_free_budget() -> void:
	var c := _clock()
	var usec := WBBench.usec_per_call(c.advance.bind(dt, false, buf), 2000)
	WBBench.report("sun clock advance", usec, 5.0)
	le(usec, WBBench.budget(5.0))
