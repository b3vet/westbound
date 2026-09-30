@warning_ignore_start("integer_division")
extends WBTest
## The adaptive governor's state machine (src/platform/governor.gd). Spec: Performance
## budget → Adaptive governor (serious thermal or more than 10% of frames missing vsync over
## a 10 s window: one rung down every 10 s; one rung up after 60 s of nominal state; never
## above the user's tier). WP9.1, docs/QUALITY.md → Governor.
##
## Synthetic frames at 60 fps; a "missed" frame takes 2.5 frame intervals (over the 1.5x
## miss factor). Timings are checked to within a frame.

const FRAME := 1.0 / 60.0
const SLOW := FRAME * 2.5
const NOMINAL := 0
const FAIR := 1
const SERIOUS := 2
const CRITICAL := 3
## One frame, plus float slack.
const TOL := FRAME * 1.5

var t: QualityTuning
var _time: float = 0.0
## [time, rung] per change during the last _drive().
var _changes: Array = []


func before_each() -> void:
	t = Tuning.load_default().quality
	_time = 0.0
	_changes.clear()


func _gov() -> Governor:
	var g := Governor.new()
	g.configure(t)
	return g


## Drives `seconds` of frames: every `miss_every`-th frame (0: none) is slow. Records
## rung changes with their times in _changes.
func _drive(g: Governor, seconds: float, level: int, miss_every: int = 0, sampling: bool = true) -> void:
	var end := _time + seconds
	var i := 0
	while _time < end - 1e-9:
		i += 1
		var f := SLOW if miss_every > 0 and i % miss_every == 0 else FRAME
		_time += f
		if g.tick(f, FRAME, level, sampling):
			_changes.append([_time, g.rung])


func _rungs() -> Array[int]:
	var out: Array[int] = []
	for c: Array in _changes:
		out.append(int(c[1]))
	return out


func _at(i: int) -> float:
	return float(_changes[i][0])


func test_spec_timings_come_from_tuning() -> void:
	near(t.governor_window_s, 10.0, 1e-9, "10-second window")
	near(t.governor_miss_frac, 0.10, 1e-9, "more than 10% of frames")
	near(t.governor_step_down_interval_s, 10.0, 1e-9, "one rung every 10 seconds")
	near(t.governor_step_up_after_s, 60.0, 1e-9, "back up after 60 seconds")
	lt(t.governor_up_miss_frac, t.governor_miss_frac, "a hysteresis band between up and down")
	gt(t.governor_miss_factor, 1.0, "a miss is a frame past its vsync")


func test_serious_thermal_steps_down_every_interval_to_the_last_rung() -> void:
	var g := _gov()
	_drive(g, 45.0, SERIOUS)
	eq(_rungs(), [1, 2, 3, 4] as Array[int], "four rungs, then it holds")
	near(_at(0), FRAME, TOL, "the first step comes at once")
	for i in range(1, 4):
		near(_at(i) - _at(i - 1), t.governor_step_down_interval_s, TOL, "then one every 10 s (%d)" % i)
	eq(g.rung, Governor.RUNG_MAX)
	eq(g.last_reason, Governor.Reason.THERMAL)
	check(g.thermal_throttled and g.cooling(false), "thermal: the cooling icon shows")
	eq(g.pressure_name(), "thermal")


func test_critical_counts_as_serious() -> void:
	var g := _gov()
	_drive(g, 1.0, CRITICAL)
	eq(g.rung, 1)


func test_nominal_state_steps_back_up_one_rung_per_minute() -> void:
	var g := _gov()
	_drive(g, 35.0, SERIOUS)
	eq(g.rung, 4)
	_changes.clear()
	var calm_from := _time
	_drive(g, 300.0, NOMINAL)
	eq(_rungs(), [3, 2, 1, 0] as Array[int], "one rung at a time back to the user's tier")
	near(_at(0) - calm_from, t.governor_step_up_after_s, TOL, "60 s of nominal state")
	for i in range(1, 4):
		near(_at(i) - _at(i - 1), t.governor_step_up_after_s, TOL, "each step up waits 60 s (%d)" % i)
	eq(g.rung, Governor.RUNG_NONE)
	check(not g.thermal_throttled and not g.cooling(false), "cooling ends at the user's tier")
	eq(g.last_reason, Governor.Reason.NONE)
	_drive(g, 120.0, NOMINAL)
	eq(g.rung, Governor.RUNG_NONE, "never above the user's tier")


func test_missed_frames_step_down_over_a_full_window() -> void:
	var g := _gov()
	_drive(g, 45.0, NOMINAL, 8)   # 12.5% of frames miss vsync
	eq(_rungs(), [1, 2, 3, 4] as Array[int])
	near(_at(0), t.governor_window_s, TOL * 3.0, "not before the 10 s window is full")
	near(_at(1) - _at(0), t.governor_step_down_interval_s, TOL, "then one rung every 10 s")
	eq(g.last_reason, Governor.Reason.FRAMES)
	check(not g.cooling(false), "frame time alone is not cooling")
	check(g.cooling(true), "unless any reason counts (QualityTuning.cooling_icon_any_reason)")
	eq(g.pressure_name(), "frames")


func test_misses_at_or_under_the_threshold_do_not_step_down() -> void:
	var g := _gov()
	_drive(g, 120.0, NOMINAL, 12)   # 8.3%
	eq(g.rung, 0, "10% or fewer: no step")
	eq(g.pressure_name(), "hold", "in the band: holds")


func test_the_hysteresis_band_holds_a_rung() -> void:
	var g := _gov()
	g.set_rung(2)
	_drive(g, 300.0, NOMINAL, 20)   # 5%: under the down share, over the up share
	eq(_changes.size(), 0, "neither down nor up in the band")
	_drive(g, 5.0 * 60.0, NOMINAL, 100)   # 1%: headroom
	eq(_rungs(), [1, 0] as Array[int], "headroom: back up")


func test_fair_thermal_holds_and_restarts_the_calm_time() -> void:
	var g := _gov()
	g.set_rung(2)
	_drive(g, 50.0, NOMINAL)
	gt(g.calm_s(), 30.0, "calm time building")
	_drive(g, 200.0, FAIR)
	eq(_changes.size(), 0, "fair: no step either way")
	eq(g.calm_s(), 0.0, "fair breaks the nominal streak")
	var from := _time
	_drive(g, 61.0, NOMINAL)
	eq(_rungs(), [1] as Array[int])
	near(_at(0) - from, t.governor_step_up_after_s, TOL, "a fresh 60 s")


func test_outside_gameplay_frames_are_ignored_and_calm_time_holds() -> void:
	var g := _gov()
	g.set_rung(2)
	_drive(g, 50.0, NOMINAL)
	var calm := g.calm_s()
	gt(calm, 30.0)
	_drive(g, 200.0, NOMINAL, 2, false)   # menus / pause: slow frames do not count
	eq(_changes.size(), 0, "no step while not sampling")
	near(g.calm_s(), calm, 1e-9, "calm time holds")
	eq(g.pressure_name(), "idle")
	eq(g.frames_in_window(), 0, "nothing sampled")
	var resume := _time
	_drive(g, 60.0, NOMINAL)
	eq(_rungs(), [1] as Array[int])
	# The window refills (10 s), then the remaining calm time runs.
	near(_at(0) - resume, t.governor_window_s + (t.governor_step_up_after_s - calm), TOL * 3.0)


func test_thermal_steps_down_outside_gameplay_too() -> void:
	var g := _gov()
	_drive(g, 12.0, SERIOUS, 0, false)
	eq(_rungs(), [1, 2] as Array[int], "a hot phone cools in the menus as well")


func test_long_frames_are_not_sampled() -> void:
	var g := _gov()
	for i in 20:
		g.tick(2.0, FRAME, NOMINAL, true)   # loading hitches, the app in the background
	eq(g.frames_in_window(), 0, "not sampled")
	eq(g.rung, 0)
	g.set_rung(1)
	var calm_before := g.calm_s()
	_drive(g, 11.0, NOMINAL)
	for i in 3:
		g.tick(30.0, FRAME, NOMINAL, true)
	le(g.calm_s() - calm_before, 11.0 + 3.0 * t.governor_ignore_frame_s + TOL,
		"timers advance at most governor_ignore_frame_s per frame")


func test_a_relapse_doubles_the_wait_to_step_up() -> void:
	var g := _gov()
	var base := t.governor_step_up_after_s
	_drive(g, 1.0, SERIOUS)
	eq(g.rung, 1)
	_drive(g, 75.0, NOMINAL)
	eq(g.rung, 0, "back up after 60 s")
	_drive(g, 20.0, NOMINAL)
	_drive(g, 1.0, SERIOUS)   # relapse inside the window
	eq(g.rung, 1)
	near(g.up_wait_s(), base * t.governor_up_backoff_factor, 1e-9, "the next wait is longer")
	_changes.clear()
	var from := _time
	_drive(g, 200.0, NOMINAL)
	eq(_rungs(), [0] as Array[int])
	near(_at(0) - from, base * t.governor_up_backoff_factor, TOL * 3.0, "it waited the doubled time")
	_drive(g, t.governor_relapse_window_s + 1.0, NOMINAL)
	near(g.up_wait_s(), base, 1e-9, "a clean relapse window resets the wait")
	for i in 6:   # repeated relapses: capped
		g.set_rung(0)
		g._last_up = true
		g._since_change_s = t.governor_step_down_interval_s
		g.tick(FRAME, FRAME, SERIOUS, true)
		eq(g.rung, 1)
	near(g.up_wait_s(), t.governor_step_up_max_s, 1e-9, "capped")


func test_rungs_that_change_nothing_are_skipped() -> void:
	var g := _gov()
	g.set_useful(1, false)   # e.g. the render scale is already at the floor
	g.set_useful(4, false)   # e.g. battery saver already caps at 30 fps
	_drive(g, 40.0, SERIOUS)
	eq(_rungs(), [2, 3] as Array[int])
	_changes.clear()
	_drive(g, 200.0, NOMINAL)
	eq(_rungs(), [2, 0] as Array[int])


func test_set_rung_restarts_the_timers() -> void:
	var g := _gov()
	g.set_rung(9)
	eq(g.rung, Governor.RUNG_MAX, "clamped")
	g.set_rung(-3)
	eq(g.rung, Governor.RUNG_NONE, "never above the user's tier")


func test_frame_percentile_and_window() -> void:
	var g := _gov()
	for i in 100:
		g.tick(0.040 if i % 20 == 0 else 0.010, FRAME, NOMINAL, true)
	var bin := t.governor_hist_bin_ms / 1000.0
	near(g.frame_percentile_s(0.95), 0.010, bin + 1e-9, "p95 of 95 x 10 ms, 5 x 40 ms")
	near(g.frame_percentile_s(0.99), 0.040, bin + 1e-9, "p99")
	near(g.frame_report_s(), g.frame_percentile_s(t.governor_report_percentile), 1e-12)
	near(g.miss_fraction(), 0.05, 1e-9)
	# The window keeps just the last 10 s.
	for i in 2000:
		g.tick(FRAME, FRAME, NOMINAL, true)
	check(g.window_full())
	ge(g.window_seconds(), t.governor_window_s)
	lt(g.window_seconds(), t.governor_window_s + FRAME * 1.01)
	eq(g.miss_fraction(), 0.0, "old misses dropped")
	le(g.frame_percentile_s(0.95), FRAME + bin + 1e-9)


func _trace(seed_value: int, bias: float) -> int:
	var g := _gov()
	var rng := Rng.new(seed_value)
	var h := TraceHash.SEED
	for i in 60 * 400:
		var f := FRAME * (1.0 + rng.unit() * bias)
		var level := 2 if (i / 3000) % 4 == 1 else 0
		g.tick(f, FRAME, level, (i / 5000) % 5 != 3)
		h = TraceHash.mix_int(h, g.rung)
	return h


func test_same_inputs_give_the_same_rungs() -> void:
	eq(_trace(7, 2.0), _trace(7, 2.0), "deterministic in its inputs")
	ne(_trace(7, 2.0), _trace(8, 0.2), "and the trace sees a difference")


func test_tick_allocates_nothing() -> void:
	var g := _gov()
	for i in 3000:
		g.tick(SLOW if i % 7 == 0 else FRAME, FRAME, i % 4, i % 11 != 0)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC)
	var p := 0.0
	for i in 20000:
		g.tick(SLOW if i % 7 == 0 else FRAME, FRAME, (i / 900) % 4, i % 11 != 0)
		p += g.frame_report_s() + g.miss_fraction()
	finite(p)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects per tick")
	eq(Performance.get_monitor(Performance.MEMORY_STATIC), mem, "no memory per tick")


func test_a_tuning_double_takes_the_missing_defaults() -> void:
	var fixture: Resource = (load("res://tests/fixtures/quality/quality_tuning_fixture.gd") as GDScript).new()
	var g := Governor.new()
	g.configure(fixture)
	near(g.window_s, 10.0, 1e-9, "from the double")
	near(g.miss_factor, QualityTuning.new().governor_miss_factor, 1e-9, "the schema default")
	_drive(g, 1.0, SERIOUS)
	eq(g.rung, 1)
