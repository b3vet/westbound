extends "res://tests/integration/run_harness.gd"
## WP4.5: hits in the full loop. Spec: Lives, hits and crashes → Tests ("a scripted
## first hit leaves the player drivable and above minimum speed within 1 s"; "a second
## contact during the 2.0 s ghost does not count"), First hit (the chain is lost, 2 s
## ghost: cannot be hit, cannot score), Second hit (slow-motion crash, the car it hit
## becomes a body, surrounding traffic brakes, results after the cinematic), Run end
## ("Retry puts the player back on the road within 2 seconds"); Scoring → Anti-exploit
## ("Nothing scores during the 2-second ghost after a hit").

const FAST_MPS := 45.0
const SLOW_MPS := 30.0
## Speeds the first hit is checked at: just above the minimum, cruising, flat out.
const HIT_SPEEDS_KMH: Array[float] = [110.0, 170.0, 240.0]


func test_nothing_scores_during_the_ghost() -> void:
	var r := _make()
	var drv := _go_quiet(r, FAST_MPS)
	# A chain to lose.
	_spawn(r, 30.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 4.0), "a chain")
	var chain := r.scoring.chain()
	# Cars the player will pass inside the ghost: two in lane 0 (one leaning in for a
	# close pass) and one in lane 2 just behind, which the player cuts in front of.
	var hit_tick := r.tick_count + 1
	var lean := _d_for_clearance(r, _lane_d(r, 1), 0.6, -1.0) - _lane_d(r, 0)
	_spawn(r, 7.0, 0, SLOW_MPS)
	_spawn(r, 14.0, 0, SLOW_MPS, lean)
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(_last("hit")[2], Events.HIT_BARRIER, "first hit")
	eq(_last("hit")[3], 1, "one life left")
	eq(_entries_with("chain_lost", chain).size(), 1, "the chain is lost")
	eq(_last("chain_lost")[3], Events.REASON_HIT)
	eq(r.scoring.multiplier(), 1.0, "the multiplier drops to 1.0x")
	check(r.scoring.is_ghost(), "scoring follows the ghost")
	_spawn(r, -10.0, 2, r.car.state.v)
	drv.target_d = _lane_d(r, 2)
	var meter := r.car.state.boost_meter
	check(_run_until(r, func() -> bool: return _count("ghost_ended") > 0, 3.0), "ghost over")
	var ghost_end: int = _last("ghost_ended")[0]
	near(float(ghost_end - hit_tick) * _dt(), t.lives.ghost_period_s, 0.05, "a 2.0 s ghost")
	eq(r.road.lane_index_at(r.car.state.d, r.car.state.s), 2, "the player cut into lane 2 during the ghost")
	eq(_scored_between(hit_tick, ghost_end).size(), 0, "nothing scored in the ghost")
	eq(r.car.state.boost_meter, meter, "no boost fill in the ghost")
	eq(r.lives.lives, 1)
	eq(r.lives.hits, 1, "no contact counted")
	# After the ghost, scoring is back: a slow car ahead in lane 1 is passed. The cars
	# whose pass overlapped the ghost never score, even if they complete after it.
	check(not r.scoring.is_ghost())
	_spawn(r, 80.0, 1, SLOW_MPS - 5.0)
	check(_run_until(r, func() -> bool: return _scored_between(hit_tick, r.tick_count).size() > 0, 8.0),
		"a pass scores again after the ghost")
	_run_s(r, 0.5)
	var behind := 0
	for i in r.sim.state.capacity:
		if r.sim.state.active[i] != 0 and r.sim.state.s[i] < r.car.state.s - r.car.car.length_m:
			behind += 1
	ge(behind, 5, "every car was passed")
	var after := _scored_between(hit_tick, r.tick_count)
	eq(after.size(), 1, "only the car passed after the ghost scored")
	if not after.is_empty():
		eq(after[0][2], ScoreEvents.PASS)
		gt(int(after[0][0]), ghost_end)


## The spec's first-hit test, for each car: at 110, 170 and 240 km/h (a barrier from
## either side, and a real rear-end into traffic), the car is still RUNNING, in a lane,
## at or above the minimum speed 1 s after the hit, and steers into the next lane.
func test_first_hit_drivable_falcon() -> void:
	_first_hit_cases(0)


func test_first_hit_drivable_viper() -> void:
	_first_hit_cases(1)


func test_first_hit_drivable_brute() -> void:
	_first_hit_cases(2)


func _first_hit_cases(car_index: int) -> void:
	var r := _make(SEED, false, car_index)
	var min_v := t.scoring.min_speed_mps()
	var window := _ticks_for(t.lives.first_hit_recovery_max_s)
	for k in HIT_SPEEDS_KMH.size():
		if k > 0:
			r.retry()
		var v0 := minf(Units.kmh_to_mps(HIT_SPEEDS_KMH[k]), r.car.params.top_speed_mps * 0.95)
		var drv := _go_quiet(r, v0)
		drv.full_throttle = true
		_run_ticks(r, TICKS_PER_FRAME)
		var what := "%s at %.0f km/h" % [r.car.car.id, Units.mps_to_kmh(v0)]
		var hits0 := r.lives.hits
		if k == 1:
			# A real contact: the player drives into a slow car in its lane.
			_spawn(r, 12.0, 1, v0 * 0.55)
			check(_run_until(r, func() -> bool: return r.lives.hits > hits0, 2.0), "%s: ran into the car" % what)
			eq(_last("hit")[2], Events.HIT_TRAFFIC, what)
		else:
			r.force_hit(HitDetection.HIT_BARRIER, -1, 1 if k == 0 else -1)
			_run_ticks(r, 1)
		eq(r.lives.hits, hits0 + 1, "%s: the first hit counted" % what)
		var v_hit := r.car.state.v
		lt(v_hit, v0, "%s: the hit costs speed" % what)
		var on_road := true
		for i in window:
			_run_ticks(r, 1)
			on_road = on_road and r.road.lane_index_at(r.car.state.d, r.car.state.s) >= 0
		eq(r.state, Game.RUNNING, "%s: still driving" % what)
		check(on_road, "%s: stayed in the lanes" % what)
		ge(r.car.state.v, min_v, "%s: above minimum speed within %.1f s" % [what, t.lives.first_hit_recovery_max_s])
		check(not r.scoring.is_too_slow(), "%s: no TOO SLOW" % what)
		# Drivable: it answers the wheel (one lane over and settled).
		var lane := r.road.lane_index_at(r.car.state.d, r.car.state.s)
		var target := lane + 1 if lane + 1 < r.road.lane_count(r.car.state.s) else lane - 1
		drv.target_d = _lane_d(r, target)
		check(_run_until(r, func() -> bool: return absf(r.car.state.d - drv.target_d) < 0.3, 2.5),
			"%s: steers into lane %d after the hit" % [what, target])


## Ghost: a real overlapping car during the ghost is ignored; after it, a real contact
## ends the run through the Jolt cinematic; the results come after its duration;
## retry puts the player back on the road inside hud.retry_max_s.
func test_second_hit_crash_results_retry() -> void:
	var r := _make(SEED, true)
	var cs := r.crash_sequence as CrashSequence
	if not check(cs != null, "the cinematic is installed"):
		return
	var drv := _go_quiet(r, FAST_MPS)
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.lives.lives, 1)
	check(r.lives.is_ghost())
	# A car right on top of the player, a little slower: a contact for a few ticks,
	# inside the ghost. It does not count and the car is not "hit".
	var st := r.car.state
	var ghost_car := _spawn(r, 0.0, 1, st.v - 10.0, st.d - _lane_d(r, 1))
	_run_s(r, 0.5)
	eq(r.lives.lives, 1, "a contact in the ghost does not count")
	eq(r.lives.hits, 1)
	eq(_count("hit"), 1, "no second hit on the bus")
	check(not r.sim.state.has_flag(ghost_car, TrafficState.FLAG_HIT), "the car was not hit")
	eq(r.state, Game.RUNNING)
	check(_run_until(r, func() -> bool: return _count("ghost_ended") > 0, 2.0), "ghost over")
	# Second hit: a slow car ahead in the player's lane, a real contact.
	drv.target_d = _lane_d(r, 1)
	_run_s(r, 0.5)
	_spawn(r, 25.0, 1, SLOW_MPS - 10.0)
	_spawn(r, 50.0, 2, SLOW_MPS)   # nearby traffic: brakes when the run ends
	check(_run_until(r, func() -> bool: return r.state == Game.CRASH, 3.0), "the second contact crashes")
	eq(_count("hit"), 2)
	eq(_last("hit")[2], Events.HIT_TRAFFIC)
	eq(_last("hit")[3], 0, "no lives left")
	eq(_count("crash_started"), 1)
	check(cs.is_running(), "the cinematic took the car")
	check(cs.has_traffic_body(), "the car it hit became a body")
	check(r.scoring.is_ended(), "scoring ended")
	var braking := 0
	for i in r.sim.state.capacity:
		if r.sim.state.active[i] != 0 and absf(r.sim.state.s[i] - r.car.state.s) <= t.lives.crash_brake_radius_m \
				and r.sim.state.has_flag(i, TrafficState.FLAG_HIT):
			braking += 1
	ge(braking, 2, "surrounding traffic brakes")
	# The cinematic runs its course in real (unscaled) frame time.
	var frames := 0
	while r.state == Game.CRASH and frames < ceili(cs.duration_s() / FRAME_S) + 10:
		_run_ticks(r, TICKS_PER_FRAME)
		frames += 1
	eq(r.state, Game.RESULTS, "results after the cinematic")
	near(float(frames) * FRAME_S, cs.duration_s(), FRAME_S * 2.0, "after its duration")
	eq(_count("crash_finished"), 1)
	var over := _last("run_over")
	if check(not over.is_empty(), "run_over on the bus"):
		var res: Dictionary = over[2]
		eq(res[&"hits"], 2)
		eq(res[&"score"], r.scoring.banked())
	check(r.screens.results_screen.visible, "the results screen")
	# Retry: the rebuild plus the retry countdown fit in hud.retry_max_s.
	var t0 := Time.get_ticks_usec()
	r.retry()
	var rebuild_s := float(Time.get_ticks_usec() - t0) / 1e6
	eq(r.state, Game.COUNTDOWN)
	check(not cs.is_running(), "the bodies are back in the pool")
	var s0 := r.car.state.s
	var ticks := 0
	while r.state != Game.RUNNING and ticks < _ticks_for(t.hud.retry_max_s * 2.0):
		_run_ticks(r, 1)
		ticks += 1
	eq(r.state, Game.RUNNING)
	var back_s := rebuild_s + float(ticks) * _dt()
	print("      retry: rebuild %.0f ms + countdown %.2f s = %.2f s (budget %.1f s)" % [
		rebuild_s * 1000.0, float(ticks) * _dt(), back_s, t.hud.retry_max_s])
	le(back_s, t.hud.retry_max_s, "back driving within hud.retry_max_s")
	_run_s(r, 0.25)
	gt(r.car.state.s, s0 + 5.0, "and moving")
	eq(r.lives.lives, t.lives.lives)
	eq(r.lives.hits, 0)
