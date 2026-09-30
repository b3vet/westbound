extends WBTest
## WP9.6 (ACCEPTANCE F1): a long vehicle crawling out of a closing lane waits while a fast
## vehicle in the lane beyond its target would reach it (TrafficTuning.long_merge_*;
## TrafficSim._long_crawl_held; docs/TRAFFIC.md "Long vehicles merging from a crawl").

const SEED := 961
## The semi's crawl, the fast car's speed and where things stand (m).
const CRAWL_KMH := 5.0
const FAST_KMH := 100.0
const SEMI_S := 2080.0
const CLOSURE_S := 2100.0
const FAST_S := 1900.0

var tuning: Tuning


func before_all() -> void:
	tuning = Tuning.load_default()


## A 3-lane road, lane 2 closed ahead of a crawling semi, a car at FAST_KMH in lane 0
## (or at `other_kmh`, or a coach instead of the semi); the player far behind. Returns
## [the fast car's s when the semi's blinker came on (NAN: never within `seconds`), the
## semi's slot, the scenario].
func _run(guard: bool, other_kmh: float = FAST_KMH, long_type: StringName = &"semi",
		seconds: float = 12.0) -> Array:
	var t := tuning.duplicate() as Tuning
	t.traffic = tuning.traffic.duplicate() as TrafficTuning
	t.traffic.long_merge_guard = guard
	var sc := TrafficScenario.new(SEED, 3, t)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, 60.0, 0)
	sc.sim.add_lane_closure(2, CLOSURE_S, CLOSURE_S + 900.0, 1)
	var semi := sc.add(SEMI_S, 2, &"truck", long_type, CRAWL_KMH)
	# Scripted, so it holds lane 0 (keep-right would take it into the empty lane 1, where
	# the semi waits for it anyway).
	var car := sc.add(FAST_S, 0, &"commuter", &"sedan", other_kmh, -1.0, NAN, TrafficState.FLAG_SCRIPTED)
	var at := NAN
	var n := roundi(seconds / TrafficScenario.DT)
	for k in n:
		sc.tick()
		var f := sc.sim.state.flags[semi]
		if is_nan(at) and (f & (TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BLINKER_RIGHT)) != 0:
			at = sc.sim.state.s[car]
	return [at, semi, sc]


func test_guard_is_on_in_the_tuning() -> void:
	check(tuning.traffic.long_merge_guard, "long_merge_guard")
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var semi: float = reg.types[reg.type_index(&"semi")].length_m
	var van: float = reg.types[reg.type_index(&"van")].length_m
	lt(tuning.traffic.long_merge_min_length_m, semi, "a semi is long")
	ge(tuning.traffic.long_merge_min_length_m, van, "a van is not")


func test_crawling_semi_waits_for_a_fast_car_beyond_its_target() -> void:
	var off: Array = _run(false)
	var on: Array = _run(true)
	var semi_front := SEMI_S + 8.0
	check(not is_nan(float(off[0])), "without the guard it signals")
	lt(float(off[0]), semi_front, "... with the fast car still behind it")
	if check(not is_nan(float(on[0])), "with the guard it signals too"):
		gt(float(on[0]), semi_front, "... once the fast car is past its front")
	var sc: TrafficScenario = on[2]
	gt(sc.sim.stat_long_merge_holds, 0, "the hold is counted")
	eq(sc.checker.total_violations(), 0)


func test_guard_ignores_slow_cars_short_vehicles_and_speed() -> void:
	# A car beyond the target lane slower than long_merge_fast_kmh does not hold it.
	var slow: Array = _run(true, tuning.traffic.long_merge_fast_kmh - 10.0)
	lt(float(slow[0]), SEMI_S - 100.0, "a slow car beyond: it goes as without the guard")
	eq((slow[2] as TrafficScenario).sim.stat_long_merge_holds, 0)
	# A van (5.9 m) is not long.
	var van: Array = _run(true, FAST_KMH, &"van")
	eq((van[2] as TrafficScenario).sim.stat_long_merge_holds, 0, "a van is not held")
