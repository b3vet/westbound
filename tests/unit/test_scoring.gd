extends WBTest
## Scoring suite (src/scoring/scoring.gd, road_hull.gd, score_events.gd). Spec:
## Scoring (scoring events, anti-exploit rules, multiplier, chain and banking, boost);
## Core loop → Sky timeline (nudges), Night (x2); Lives (ghost period, minimum-speed
## grace after a hit); Milestones M3 "scoring unit tests (every event, anti-exploit
## rules, banking, loss cases)". Rules and numbers: docs/SCORING.md.
##
## Scenarios use ScoringScenario (tests/fixtures/scoring): cars at constant speed on
## fixed lines and a scripted player, so every boundary is exact.

const DT := ScoringScenario.DT
const EPS := 1e-6
## Tick-time tolerance for measured rates (one tick of decay at most).
const RATE_TOL := 0.01
## Step budget (usec) for 60 cars around the player; ~3x the local median.
const STEP_BUDGET_USEC := 150.0

var t: Tuning
var sc_t: ScoringTuning


func before_all() -> void:
	t = Tuning.load_default()
	sc_t = t.scoring


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


func _sf(v_kmh: float) -> float:
	return sc_t.speed_factor(_kmh(v_kmh))


## Player in lane 1 at `player_kmh`; one car `ds` ahead at lateral offset `dd` from the
## player (+ right) at `car_kmh`. Runs until the car is fully behind (plus a margin).
func _pass_scene(player_kmh: float, car_kmh: float, dd: float, ds: float = 20.0,
		tuning: Tuning = null) -> ScoringScenario:
	var sc := ScoringScenario.new(tuning)
	sc.place_player(1, player_kmh)
	sc.add_car(ds, sc.lane_d(1) + dd, car_kmh)
	var rel := _kmh(player_kmh) - _kmh(car_kmh)
	sc.run((ds + sc.half_lengths()) / rel + 0.05)
	return sc


## Center offset leaving `clearance` between the player's hull and a default car's hull.
func _side(clearance: float) -> float:
	var inset := t.lives.collision_inset_m
	return t.traffic.player_width_m * 0.5 - inset + ScoringScenario.CAR_WIDTH * 0.5 - inset + clearance


## The player's hull half-width.
func _p_hw() -> float:
	return t.traffic.player_width_m * 0.5 - t.lives.collision_inset_m


func _tuning_copy() -> Tuning:
	var c := t.duplicate() as Tuning
	c.scoring = t.scoring.duplicate() as ScoringTuning
	return c


# ---------------------------------------------------------------- Plumbing

func test_event_kinds_match_events_bus() -> void:
	eq(ScoreEvents.PASS, Events.PASS)
	eq(ScoreEvents.CLOSE_PASS, Events.CLOSE_PASS)
	eq(ScoreEvents.CUT, Events.CUT)
	eq(ScoreEvents.THREAD, Events.THREAD)
	eq(ScoreEvents.REASON_CHECKPOINT, Events.REASON_CHECKPOINT)
	eq(ScoreEvents.REASON_CASH_OUT, Events.REASON_CASH_OUT)
	eq(ScoreEvents.REASON_HIT, Events.REASON_HIT)
	eq(ScoreEvents.REASON_HESITATED, Events.REASON_HESITATED)
	eq(ScoreEvents.REASON_RUN_END, Events.REASON_RUN_END)
	check(Scoring.new() is ScoringRuleSet)


func test_fresh_run_state() -> void:
	var r := Scoring.new(RunContext.new(3))
	eq(r.multiplier(), 1.0)
	eq(r.chain(), 0)
	eq(r.banked(), 0)
	eq(r.take_boost_fill(), 0.0)
	check(not r.is_too_slow())


func test_hull_clearance() -> void:
	# Side by side, parallel: the lateral gap.
	near(RoadHull.clearance(0.0, 0.0, 0.0, 2.0, 1.0, 0.0, 3.5, 0.0, 2.0, 1.0), 1.5, EPS)
	# In line: the longitudinal gap.
	near(RoadHull.clearance(0.0, 0.0, 0.0, 2.0, 1.0, 10.0, 0.0, 0.0, 2.0, 1.0), 6.0, EPS)
	# Diagonal, corner to corner: sqrt(3^2 + 4^2) = 5.
	near(RoadHull.clearance(0.0, 0.0, 0.0, 2.0, 1.0, 7.0, 6.0, 0.0, 2.0, 1.0), 5.0, EPS)
	# Overlapping and touching.
	eq(RoadHull.clearance(0.0, 0.0, 0.0, 2.0, 1.0, 1.0, 1.0, 0.0, 2.0, 1.0), 0.0)
	eq(RoadHull.clearance(0.0, 0.0, 0.0, 2.0, 1.0, 0.0, 2.0, 0.0, 2.0, 1.0), 0.0)
	# A cross: no corner inside the other box, but they overlap (SAT catches it).
	eq(RoadHull.clearance(0.0, 0.0, 0.0, 3.0, 0.5, 0.0, 0.0, PI * 0.5, 3.0, 0.5), 0.0)
	# Yawed box: nose turned toward the other car closes the gap by hl * sin(yaw).
	var yaw := deg_to_rad(5.0)
	var expect := 3.5 - 1.0 - (2.0 * sin(yaw) + 1.0 * cos(yaw))
	near(RoadHull.clearance(0.0, 0.0, yaw, 2.0, 1.0, 0.0, 3.5, 0.0, 2.0, 1.0), expect, EPS)
	# Symmetric.
	near(RoadHull.clearance(7.0, 6.0, 0.3, 2.0, 1.0, 0.0, 0.0, -0.1, 2.5, 0.9),
		RoadHull.clearance(0.0, 0.0, -0.1, 2.5, 0.9, 7.0, 6.0, 0.3, 2.0, 1.0), EPS)


# ---------------------------------------------------------------- Pass

func test_pass_scores_base_times_factors_and_adds_one() -> void:
	var sc := _pass_scene(150.0, 100.0, 3.6)
	if not eq(sc.count(ScoreEvents.PASS), 1, "one pass"):
		return
	var e := sc.first(ScoreEvents.PASS)
	eq(sc.log_points[e], roundi(10.0 * _sf(150.0)), "10 x 1.0 x speed factor")
	eq(sc.log_mult[e], 1.0, "scored at the multiplier before the gain")
	near(sc.log_clear[e], 3.6 - sc.side_offset(0.0), EPS, "hull-to-hull clearance")
	eq(sc.log_slot[e], 0)
	near(sc.log_mult_after[e], 2.0, RATE_TOL, "+1")
	eq(sc.rules.chain(), sc.log_points[e], "into the unbanked chain")
	eq(sc.rules.banked(), 0)
	eq(sc.count(ScoreEvents.CLOSE_PASS), 0)
	eq(sc.count(Scoring.KIND_NEAR_MISS), 0)
	near(sc.boost_total, 0.0, EPS, "a pass fills no boost")


func test_pass_is_paid_when_the_car_is_fully_behind() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	sc.add_car(20.0, sc.lane_d(2), 100.0)
	var rel := _kmh(150.0) - _kmh(100.0)
	# Centers crossed, hulls still overlapping: not yet.
	sc.run(20.0 / rel + 0.1)
	eq(sc.count(ScoreEvents.PASS), 0, "not while overlapping")
	sc.run((sc.half_lengths()) / rel)
	eq(sc.count(ScoreEvents.PASS), 1, "once fully behind")


func test_pass_lateral_window_boundary() -> void:
	var w := sc_t.pass_lateral_window_m
	eq(_pass_scene(150.0, 100.0, w - 0.01).count(ScoreEvents.PASS), 1, "5.39 m: pass (right)")
	eq(_pass_scene(150.0, 100.0, -(w - 0.01)).count(ScoreEvents.PASS), 1, "5.39 m: pass (left)")
	eq(_pass_scene(150.0, 100.0, w + 0.01).count(ScoreEvents.PASS), 0, "5.41 m: no pass")
	eq(_pass_scene(150.0, 100.0, -(w + 0.01)).scored_count(), 0, "5.41 m left: nothing")


func test_no_pass_when_player_drops_back_or_is_overtaken() -> void:
	# The player draws level, then brakes: the car ends up ahead again.
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	sc.add_car(10.0, sc.lane_d(2), 100.0)
	sc.run(10.0 / (_kmh(150.0) - _kmh(100.0)) + 0.1)
	sc.set_speed(60.0)
	sc.run(3.0)
	eq(sc.scored_count(), 0, "drew level then fell back")
	# A faster car overtakes the player from behind.
	var sc2 := ScoringScenario.new()
	sc2.place_player(1, 120.0)
	sc2.add_car(-20.0, sc2.lane_d(2), 170.0)
	sc2.run(3.0)
	eq(sc2.scored_count(), 0, "being overtaken is not a pass")
	# ...and the player passes it back: that one counts.
	sc2.set_speed(220.0)
	sc2.run(4.0)
	eq(sc2.count(ScoreEvents.PASS), 1, "re-passing a car that got ahead")


# ---------------------------------------------------------------- Close pass

func test_close_pass_boundary_and_rewards() -> void:
	var c := sc_t.close_pass_clearance_m
	var sc := _pass_scene(150.0, 100.0, _side(c - 0.01))
	if not eq(sc.count(ScoreEvents.CLOSE_PASS), 1, "0.99 m: close pass"):
		return
	eq(sc.count(ScoreEvents.PASS), 0, "a close pass replaces the pass (30 = 3 x 10)")
	var e := sc.first(ScoreEvents.CLOSE_PASS)
	eq(sc.log_points[e], roundi(30.0 * _sf(150.0)))
	near(sc.log_clear[e], c - 0.01, 1e-4)
	near(sc.log_mult_after[e], 4.0, RATE_TOL, "+3")
	near(sc.boost_total, 0.1, EPS, "+10% boost")
	eq(sc.count(Scoring.KIND_NEAR_MISS), 1, "horn hook")
	eq(sc.log_slot[sc.first(Scoring.KIND_NEAR_MISS)], 0, "horn hook carries the slot")
	# Left side too.
	var sc_left := _pass_scene(150.0, 100.0, -_side(c - 0.01))
	eq(sc_left.count(ScoreEvents.CLOSE_PASS), 1, "0.99 m on the left")
	var sc_far := _pass_scene(150.0, 100.0, _side(c + 0.01))
	eq(sc_far.count(ScoreEvents.CLOSE_PASS), 0, "1.01 m: not close")
	eq(sc_far.count(ScoreEvents.PASS), 1, "1.01 m: a pass")
	eq(sc_far.count(Scoring.KIND_NEAR_MISS), 0)
	near(sc_far.boost_total, 0.0, EPS)


func test_close_pass_clearance_is_minimum_during_overlap() -> void:
	# The player drifts toward the car while overlapping and away again before the
	# end: the minimum (not the final) clearance counts.
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	var base := sc.lane_d(1)
	sc.add_car(sc.half_lengths() + 0.5, base + sc.side_offset(1.3), 100.0)
	var rel := _kmh(150.0) - _kmh(100.0)
	sc.run(1.0 / rel)
	sc.steer_to(base + 0.6, 3.0)      # clearance 0.7 m
	sc.run_until_steered()
	sc.steer_to(base, 3.0)            # back out to 1.3 m
	sc.run(2.0 * sc.half_lengths() / rel)
	eq(sc.count(ScoreEvents.CLOSE_PASS), 1)
	near(sc.log_clear[sc.first(ScoreEvents.CLOSE_PASS)], 0.7, 1e-3)


# ---------------------------------------------------------------- Factors and rounding

func test_speed_factor_and_night() -> void:
	eq(_pass_scene(100.0, 50.0, 3.6).points_of(ScoreEvents.PASS), 10, "1.0 at 100 km/h")
	eq(_pass_scene(175.0, 125.0, 3.6).points_of(ScoreEvents.PASS), 15, "1.5 at 175 km/h")
	eq(_pass_scene(250.0, 200.0, 3.6).points_of(ScoreEvents.PASS), 20, "2.0 at 250 km/h")
	eq(_pass_scene(300.0, 250.0, 3.6).points_of(ScoreEvents.PASS), 20, "clamped above 250 km/h")
	var sc := ScoringScenario.new()
	sc.rules.set_night(true)
	check(sc.rules.is_night())
	sc.place_player(1, 250.0)
	sc.add_car(20.0, sc.lane_d(2), 200.0)
	sc.run(2.0)
	eq(sc.points_of(ScoreEvents.PASS), 40, "night x2")
	sc.rules.set_night(false)
	sc.add_car(20.0, sc.lane_d(0), 200.0)
	sc.run(2.0)
	var e := sc.last(ScoreEvents.PASS)
	eq(sc.log_points[e], roundi(10.0 * sc.log_mult[e] * 2.0), "day again: x1")


func test_points_round_half_away_from_zero() -> void:
	# 10 x 1.0 x 1.24 = 12.4 -> 12; 10 x 1.0 x 1.26 = 12.6 -> 13.
	eq(_pass_scene(136.0, 86.0, 3.6).points_of(ScoreEvents.PASS), 12)
	eq(_pass_scene(139.0, 89.0, 3.6).points_of(ScoreEvents.PASS), 13)
	# Non-integer multiplier: the second pass is scored at the decayed multiplier.
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	sc.add_car(20.0, sc.lane_d(2), 100.0)
	sc.add_car(40.0, sc.lane_d(0), 100.0)
	sc.run(4.0)
	if not eq(sc.count(ScoreEvents.PASS), 2):
		return
	var e := sc.last(ScoreEvents.PASS)
	check(sc.log_mult[e] > 1.0 and sc.log_mult[e] < 2.0, "decayed multiplier")
	eq(sc.log_points[e], roundi(10.0 * sc.log_mult[e] * _sf(150.0)))


# ---------------------------------------------------------------- Multiplier decay

## Multiplier lost over one second after a pass at `v_kmh` (starting from 2.0).
func _decay_over_1s(v_kmh: float, boost: bool = false) -> float:
	var sc := _pass_scene(v_kmh, v_kmh - 50.0, 3.6)
	sc.player.boost_active = boost
	var m0 := sc.rules.multiplier()
	sc.run(1.0)
	return m0 - sc.rules.multiplier()


func test_multiplier_decay_by_speed() -> void:
	near(_decay_over_1s(100.0), 0.5, RATE_TOL, "0.5/s x 1.0 at 100 km/h")
	near(_decay_over_1s(175.0), 0.5 * 0.55, RATE_TOL, "0.5/s x 0.55 at 175 km/h")
	near(_decay_over_1s(250.0), 0.05, RATE_TOL, "0.5/s x 0.1 at 250 km/h")
	near(_decay_over_1s(175.0, true), 0.5 * 0.55 * sc_t.boost_decay_factor, RATE_TOL, "boost slows decay")


func test_multiplier_has_no_cap_and_floor_is_one() -> void:
	var sc := ScoringScenario.new(null, 3, 48)
	sc.place_player(1, 250.0)
	for k in 40:
		sc.add_car(20.0 + 12.0 * k, sc.lane_d(0 if k % 2 == 0 else 2), 200.0)
	sc.run(40.0 * 12.0 / (_kmh(250.0) - _kmh(200.0)) + 1.0)
	gt(sc.rules.multiplier(), 30.0, "no cap")
	var sc2 := ScoringScenario.new()
	sc2.place_player(1, 100.0)
	sc2.run(2.0)
	eq(sc2.rules.multiplier(), 1.0, "never below 1.0")


# ---------------------------------------------------------------- Cut

## Player in lane 1 at `v_kmh` crossing into lane 2 (center line at the lane edge).
func _cut_scene(v_kmh: float) -> ScoringScenario:
	var sc := ScoringScenario.new()
	sc.place_player(1, v_kmh)
	return sc


func _do_cut(sc: ScoringScenario, lane: int) -> void:
	sc.steer_to_lane(lane, 6.0)
	sc.run_until_steered()


func test_cut_scores_with_traffic_nearby() -> void:
	var sc := _cut_scene(150.0)
	sc.add_car(sc.gap_ahead(10.0), sc.lane_d(2), 150.0)
	_do_cut(sc, 2)
	if not eq(sc.count(ScoreEvents.CUT), 1):
		return
	var e := sc.first(ScoreEvents.CUT)
	eq(sc.log_points[e], roundi(15.0 * _sf(150.0)))
	eq(sc.log_slot[e], 0)
	eq(sc.log_clear[e], -1.0)
	near(sc.log_mult_after[e], 2.0, RATE_TOL, "+1")


func test_cut_boundaries() -> void:
	var w := sc_t.cut_traffic_window_m
	var sc := _cut_scene(sc_t.cut_min_speed_kmh + 1.0)
	sc.add_car(sc.gap_ahead(10.0), sc.lane_d(2), sc_t.cut_min_speed_kmh + 1.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 1, "141 km/h")
	sc = _cut_scene(sc_t.cut_min_speed_kmh - 1.0)
	sc.add_car(sc.gap_ahead(10.0), sc.lane_d(2), sc_t.cut_min_speed_kmh - 1.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 0, "139 km/h")
	sc = _cut_scene(150.0)
	sc.add_car(sc.gap_ahead(w - 0.1), sc.lane_d(2), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 1, "14.9 m ahead in the lane entered")
	sc = _cut_scene(150.0)
	sc.add_car(sc.gap_ahead(w + 0.1), sc.lane_d(2), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 0, "15.1 m ahead")
	sc = _cut_scene(150.0)
	sc.add_car(-sc.gap_ahead(w - 0.1), sc.lane_d(1), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 1, "14.9 m behind in the lane left")
	sc = _cut_scene(150.0)
	sc.add_car(-sc.gap_ahead(w + 0.1), sc.lane_d(1), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 0, "15.1 m behind")
	sc = _cut_scene(150.0)
	sc.add_car(sc.gap_ahead(5.0), sc.lane_d(0), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 0, "a car in a lane neither left nor entered")


func test_weaving_on_an_empty_road_scores_nothing() -> void:
	var sc := _cut_scene(200.0)
	for k in 10:
		_do_cut(sc, 2 if k % 2 == 0 else 0)
	sc.run(1.0)
	eq(sc.scored_count(), 0)
	eq(sc.rules.chain(), 0)
	eq(sc.rules.multiplier(), 1.0)
	# Traffic far away in other lanes does not help either.
	sc.add_car(sc.gap_ahead(60.0), sc.lane_d(1), 200.0)
	for k in 6:
		_do_cut(sc, 2 if k % 2 == 0 else 0)
	eq(sc.scored_count(), 0, "traffic 60 m away")


func test_cut_per_car_cooldown() -> void:
	var cd := sc_t.cut_per_car_cooldown_s
	var sc := _cut_scene(150.0)
	sc.add_car(sc.gap_ahead(8.0), sc.lane_d(2), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 1, "first cut")
	var t_cut := sc.log_time[sc.first(ScoreEvents.CUT)]
	sc.run(0.4)
	_do_cut(sc, 1)
	eq(sc.count(ScoreEvents.CUT), 1, "same car within 3 s: nothing")
	# Wait until the next crossing lands just after the cooldown.
	var cross_in := 0.5 * sc.road.lane_width(0.0) / 6.0
	sc.run(cd - (sc.time - t_cut) - cross_in + 0.05)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 2, "after 3 s the car contributes again")
	gt(sc.log_time[sc.last(ScoreEvents.CUT)] - t_cut, cd)
	# Another car (not on cooldown) makes a cut within the first car's cooldown.
	sc.add_car(-sc.gap_ahead(5.0), sc.lane_d(1), 150.0)
	sc.run(0.4)
	_do_cut(sc, 1)
	eq(sc.count(ScoreEvents.CUT), 3, "a fresh car contributes")


func test_cut_cooldown_keyed_by_vehicle_id_not_slot() -> void:
	var sc := _cut_scene(150.0)
	var slot := sc.add_car(sc.gap_ahead(8.0), sc.lane_d(2), 150.0)
	_do_cut(sc, 2)
	eq(sc.count(ScoreEvents.CUT), 1)
	# The car despawns and a new one reuses its slot (new vehicle_id) at the same spot.
	var ds := sc.traffic.s[slot] - sc.player.s
	sc.remove_car(slot)
	sc.run(0.1)
	var slot2 := sc.add_car(ds, sc.lane_d(2), 150.0)
	eq(slot2, slot, "slot reused")
	sc.run(0.3)
	_do_cut(sc, 1)
	eq(sc.count(ScoreEvents.CUT), 2, "a new vehicle in a reused slot has no cooldown")


# ---------------------------------------------------------------- Thread

func _thread_scene(clear_left: float, clear_right: float, dt_s: float = 0.0) -> ScoringScenario:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	var rel := _kmh(150.0) - _kmh(100.0)
	sc.add_car(20.0, sc.lane_d(1) - sc.side_offset(clear_left), 100.0)
	sc.add_car(20.0 + rel * dt_s, sc.lane_d(1) + sc.side_offset(clear_right), 100.0)
	sc.run((20.0 + rel * absf(dt_s) + sc.half_lengths()) / rel + 0.1)
	return sc


func test_thread_pays_on_top_of_both_passes() -> void:
	var sc := _thread_scene(1.4, 1.4)
	eq(sc.count(ScoreEvents.PASS), 2, "both passes paid")
	if not eq(sc.count(ScoreEvents.THREAD), 1, "thread"):
		return
	var e := sc.first(ScoreEvents.THREAD)
	var sf := _sf(150.0)
	# Same tick, slot order: pass at x1, pass at x2, thread at x3.
	eq(sc.log_points[e], roundi(50.0 * 3.0 * sf))
	eq(sc.scored_points(), roundi(10.0 * sf) + roundi(20.0 * sf) + roundi(150.0 * sf))
	near(sc.log_clear[e], 1.4, 1e-4)
	eq(sc.log_slot[e], 1, "slot of the second car")
	near(sc.log_mult_after[e], 1.0 + 1.0 + 1.0 + 5.0, RATE_TOL, "+1 +1 +5")
	near(sc.boost_total, 0.25, EPS, "+25% boost")
	var n := sc.first(Scoring.KIND_SUN_NUDGE)
	if check(n >= 0, "thread nudges the sun"):
		near(sc.log_value[n], t.sun.thread_nudge_pct / 100.0, EPS, "1% of the day span")


func test_thread_with_close_passes() -> void:
	var sc := _thread_scene(0.5, 0.6)
	eq(sc.count(ScoreEvents.CLOSE_PASS), 2)
	eq(sc.count(ScoreEvents.THREAD), 1)
	near(sc.boost_total, 0.1 + 0.1 + 0.25, EPS)
	near(sc.log_mult_after[sc.first(ScoreEvents.THREAD)], 1.0 + 3.0 + 3.0 + 5.0, RATE_TOL)


func test_thread_window_boundary() -> void:
	var w := sc_t.thread_window_s
	eq(_thread_scene(1.4, 1.4, w - 0.05).count(ScoreEvents.THREAD), 1, "0.45 s apart")
	eq(_thread_scene(1.4, 1.4, -(w - 0.05)).count(ScoreEvents.THREAD), 1, "0.45 s apart, right first")
	eq(_thread_scene(1.4, 1.4, w + 0.05).count(ScoreEvents.THREAD), 0, "0.55 s apart")


func test_thread_clearance_boundary_and_sides() -> void:
	var c := sc_t.thread_clearance_m
	eq(_thread_scene(c - 0.01, c - 0.01).count(ScoreEvents.THREAD), 1, "1.49 m both")
	var sc := _thread_scene(c - 0.01, c + 0.01)
	eq(sc.count(ScoreEvents.THREAD), 0, "1.51 m on one side")
	eq(sc.count(ScoreEvents.PASS), 2, "still two passes")
	eq(sc.count(Scoring.KIND_SUN_NUDGE), 0)
	# Two cars on the same side 0.2 s apart: not a thread.
	var sc2 := ScoringScenario.new()
	sc2.place_player(1, 150.0)
	var rel := _kmh(150.0) - _kmh(100.0)
	sc2.add_car(20.0, sc2.lane_d(1) + _side(1.2), 100.0)
	sc2.add_car(20.0 + rel * 0.2, sc2.lane_d(1) + _side(1.2), 100.0)
	sc2.run(2.5)
	eq(sc2.count(ScoreEvents.PASS), 2)
	eq(sc2.count(ScoreEvents.THREAD), 0, "same side")


func test_each_pass_threads_once() -> void:
	# Left, right, left within 0.5 s: one thread, the third pass has no partner left.
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	var rel := _kmh(150.0) - _kmh(100.0)
	sc.add_car(20.0, sc.lane_d(1) - sc.side_offset(1.0), 100.0)
	sc.add_car(20.0 + rel * 0.1, sc.lane_d(1) + sc.side_offset(1.0), 100.0)
	sc.add_car(20.0 + rel * 0.2, sc.lane_d(1) - sc.side_offset(1.0), 100.0)
	sc.run(3.0)
	eq(sc.count(ScoreEvents.PASS), 3)
	eq(sc.count(ScoreEvents.THREAD), 1)


# ---------------------------------------------------------------- Slipstream

func _slip_scene(v_kmh: float, gap: float, car_lane: int = 1) -> ScoringScenario:
	var sc := ScoringScenario.new()
	sc.place_player(1, v_kmh)
	sc.add_car(sc.gap_ahead(gap), sc.lane_d(car_lane), v_kmh)
	sc.run(1.0)
	return sc


func test_slipstream_fills_boost() -> void:
	var sc := _slip_scene(130.0, 10.0)
	near(sc.boost_total, 0.2, 0.2 * DT + EPS, "+20% per second")
	check(sc.rules.is_slipstreaming())
	eq(sc.toggles(Scoring.KIND_SLIPSTREAM), "1")
	eq(sc.scored_count(), 0, "no points")
	eq(sc.rules.multiplier(), 1.0, "no multiplier")
	sc.set_speed(110.0)
	sc.run(0.5)
	eq(sc.toggles(Scoring.KIND_SLIPSTREAM), "10", "off below 120 km/h")
	var s := sc_t.slipstream_min_speed_kmh
	_slip_ok(_slip_scene(s + 1.0, 10.0), true, "121 km/h")
	_slip_ok(_slip_scene(s - 1.0, 10.0), false, "119 km/h")
	_slip_ok(_slip_scene(130.0, sc_t.slipstream_distance_m - 0.1), true, "14.9 m")
	_slip_ok(_slip_scene(130.0, sc_t.slipstream_distance_m + 0.1), false, "15.1 m")
	_slip_ok(_slip_scene(130.0, 5.0, 2), false, "another lane")


func _slip_ok(sc: ScoringScenario, on: bool, msg: String) -> void:
	if on:
		gt(sc.boost_total, 0.19, msg)
	else:
		eq(sc.boost_total, 0.0, msg)


func test_take_boost_fill_resets() -> void:
	var sc := ScoringScenario.new()
	sc.auto_take_boost = false
	sc.place_player(1, 150.0)
	sc.add_car(20.0, sc.lane_d(1) + sc.side_offset(0.5), 100.0)
	sc.run(2.5)
	near(sc.rules.take_boost_fill(), 0.1, EPS)
	eq(sc.rules.take_boost_fill(), 0.0, "taken")


# ---------------------------------------------------------------- Shoulder

func test_shoulder_decay_x3_and_no_gains() -> void:
	var sc := _pass_scene(100.0, 50.0, 3.6)
	# Onto the outer shoulder (one wheel over the edge line is enough).
	sc.player.d = sc.road.lanes_right_edge_d(0.0) - _p_hw() + 0.1
	var m0 := sc.rules.multiplier()
	sc.run(0.2)
	check(sc.rules.is_on_shoulder(), "any wheel on the shoulder")
	check(sc.rules.gains_blocked())
	near(m0 - sc.rules.multiplier(), 0.2 * 0.5 * sc_t.shoulder_decay_factor, RATE_TOL, "decay x3")


func test_passing_on_the_shoulder_scores_nothing() -> void:
	var sc := ScoringScenario.new()
	var edge := sc.road.lanes_right_edge_d(0.0)
	sc.place_player_d(edge + 1.5, 150.0)
	sc.add_car(20.0, sc.lane_d(2), 100.0)
	sc.run(2.5)
	eq(sc.scored_count(), 0, "fully on the shoulder")
	# Only the right wheels over the line, the car one lane left.
	var sc2 := ScoringScenario.new()
	sc2.place_player_d(edge - _p_hw() + 0.05, 150.0)
	sc2.add_car(20.0, sc2.lane_d(1), 100.0)
	sc2.run(2.5)
	eq(sc2.scored_count(), 0, "one wheel on the shoulder")
	# A close pass on the shoulder still sounds the horn hook, but scores nothing.
	var sc3 := ScoringScenario.new()
	sc3.place_player_d(edge + 0.5, 150.0)
	sc3.add_car(20.0, edge + 0.5 - sc3.side_offset(0.5), 100.0)
	sc3.run(2.5)
	eq(sc3.scored_count(), 0)
	eq(sc3.count(Scoring.KIND_NEAR_MISS), 1)
	near(sc3.boost_total, 0.0, EPS)
	# Inner shoulder too.
	var sc4 := ScoringScenario.new()
	sc4.place_player_d(sc4.road.lanes_left_edge_d(0.0), 150.0)
	sc4.add_car(20.0, sc4.lane_d(0) + 0.5, 100.0)
	sc4.run(2.5)
	eq(sc4.scored_count(), 0, "inner shoulder")
	eq(sc4.count(Scoring.KIND_NEAR_MISS), 1)


func test_shoulder_penalty_after_2s() -> void:
	var after := sc_t.shoulder_penalty_after_s
	var block := sc_t.shoulder_penalty_block_s
	var sc := ScoringScenario.new()
	sc.place_player(2, 150.0)
	var lane_d := sc.lane_d(2)
	var shoulder_d := sc.road.lanes_right_edge_d(0.0) + 1.5
	sc.player.d = shoulder_d
	sc.run(after - 0.1)
	eq(sc.toggles(Scoring.KIND_SHOULDER), "", "1.9 s: no penalty yet")
	sc.run(0.2)
	eq(sc.toggles(Scoring.KIND_SHOULDER), "1", "2.1 s: shoulder penalty")
	check(sc.rules.shoulder_penalty_active())
	sc.player.d = lane_d
	# A pass inside the block: points, but no multiplier gain.
	var rel := _kmh(150.0) - _kmh(100.0)
	sc.add_car(rel * 0.5, sc.lane_d(1), 100.0)
	sc.run(0.5 + sc.half_lengths() / rel + 0.1)
	eq(sc.count(ScoreEvents.PASS), 1, "still scores")
	eq(sc.rules.multiplier(), 1.0, "no gain during the penalty")
	check(sc.rules.shoulder_penalty_active())
	# The points at 1.0x bank straight away (the multiplier is at 1.0).
	eq(sc.count(Scoring.KIND_BANKED), 1)
	sc.run(block - (0.5 + sc.half_lengths() / rel + 0.1) + 0.1)
	eq(sc.toggles(Scoring.KIND_SHOULDER), "10", "lifted 3 s after leaving")
	check(not sc.rules.gains_blocked())
	sc.add_car(20.0, sc.lane_d(1), 100.0)
	sc.run(2.0)
	eq(sc.count(ScoreEvents.PASS), 2)
	near(sc.rules.multiplier(), 2.0, 0.1, "gains again")


func test_short_shoulder_visit_has_no_penalty() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(2, 150.0)
	var lane_d := sc.lane_d(2)
	sc.player.d = sc.road.lanes_right_edge_d(0.0) + 1.5
	sc.run(sc_t.shoulder_penalty_after_s - 0.5)
	sc.player.d = lane_d
	sc.run(0.1)
	eq(sc.toggles(Scoring.KIND_SHOULDER), "")
	check(not sc.rules.gains_blocked(), "gains right after leaving")
	sc.add_car(20.0, sc.lane_d(1), 100.0)
	sc.run(2.0)
	near(sc.rules.multiplier(), 2.0, 0.1)


# ---------------------------------------------------------------- Minimum speed, hesitation, grace

## A pass at 110 km/h (multiplier 2, chain > 0), then the player slows to `slow_kmh`.
func _slow_scene(slow_kmh: float) -> ScoringScenario:
	var sc := ScoringScenario.new()
	sc.place_player(1, 110.0)
	sc.add_car(10.0, sc.lane_d(2), 60.0)
	sc.run((10.0 + sc.half_lengths()) / (_kmh(110.0) - _kmh(60.0)) + 0.05)
	sc.set_speed(slow_kmh)
	return sc


func test_too_slow_drains_3_per_s() -> void:
	var sc := _slow_scene(90.0)
	var m0 := sc.rules.multiplier()
	gt(m0, 1.5)
	sc.run(0.2)
	check(sc.rules.is_too_slow())
	eq(sc.toggles(Scoring.KIND_TOO_SLOW), "1")
	near(m0 - sc.rules.multiplier(), 0.2 * sc_t.below_min_drain_per_s, RATE_TOL, "3/s")
	sc.run(0.5)
	eq(sc.rules.multiplier(), 1.0)
	gt(sc.rules.chain(), 0, "drained to 1.0 while slow: no cash-out")
	eq(sc.count(Scoring.KIND_BANKED), 0)
	sc.set_speed(120.0)
	sc.run(0.1)
	eq(sc.toggles(Scoring.KIND_TOO_SLOW), "10")


func test_hesitation_after_3s() -> void:
	var sc := _slow_scene(90.0)
	var chain := sc.rules.chain()
	gt(chain, 0)
	sc.run(sc_t.hesitation_timeout_s - 0.05)
	eq(sc.count(Scoring.KIND_HESITATED), 0, "2.95 s")
	eq(sc.rules.chain(), chain)
	sc.run(0.1)
	eq(sc.count(Scoring.KIND_HESITATED), 1, "3.05 s: HESITATED")
	var e := sc.first(Scoring.KIND_CHAIN_LOST)
	if check(e >= 0, "chain lost"):
		eq(sc.log_points[e], chain)
		eq(sc.log_tag[e], ScoreEvents.REASON_HESITATED)
	eq(sc.rules.chain(), 0)
	eq(sc.rules.multiplier(), 1.0)
	eq(sc.rules.banked(), 0)
	sc.run(5.0)
	eq(sc.count(Scoring.KIND_HESITATED), 1, "once per slow stretch")
	sc.set_speed(120.0)
	sc.run(0.1)
	sc.set_speed(90.0)
	sc.run(3.1)
	eq(sc.count(Scoring.KIND_HESITATED), 2, "a new stretch can hesitate again")


func test_hesitation_needs_continuous_slowness() -> void:
	var sc := _slow_scene(90.0)
	sc.run(2.0)
	sc.set_speed(105.0)
	sc.run(0.1)
	sc.set_speed(90.0)
	sc.run(2.0)
	eq(sc.count(Scoring.KIND_HESITATED), 0)


func test_grace_until_min_speed_first_reached() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 50.0)
	sc.run(5.0)
	check(not sc.rules.is_too_slow(), "inactive before 100 km/h")
	eq(sc.count(Scoring.KIND_TOO_SLOW), 0)
	eq(sc.count(Scoring.KIND_HESITATED), 0)
	sc.set_speed(100.0)
	sc.run(0.1)
	sc.set_speed(90.0)
	sc.run(0.1)
	check(sc.rules.is_too_slow(), "active once reached")
	# With the switch off the rule is active from the start.
	var tt := _tuning_copy()
	tt.scoring.min_speed_grace_until_reached = false
	var sc2 := ScoringScenario.new(tt)
	sc2.place_player(1, 50.0)
	sc2.run(0.1)
	check(sc2.rules.is_too_slow())


func test_grace_after_hit() -> void:
	var grace := sc_t.min_speed_grace_after_hit_s
	var sc := ScoringScenario.new()
	sc.place_player(1, 110.0)
	sc.run(0.1)
	sc.hit()
	sc.set_speed(90.0)
	sc.run(grace - 0.1)
	check(not sc.rules.is_too_slow(), "paused 3 s after a hit")
	eq(sc.count(Scoring.KIND_TOO_SLOW), 0)
	sc.run(0.2)
	check(sc.rules.is_too_slow(), "active again")
	sc.run(sc_t.hesitation_timeout_s - 0.3)
	eq(sc.count(Scoring.KIND_HESITATED), 0, "hesitation counts from the end of the grace")
	sc.run(0.4)
	eq(sc.count(Scoring.KIND_HESITATED), 1)
	# A hit while too slow switches TOO SLOW off.
	sc.hit()
	eq(sc.toggles(Scoring.KIND_TOO_SLOW), "10")
	check(not sc.rules.is_too_slow())


# ---------------------------------------------------------------- Chain and banking

func test_cash_out_banks_when_multiplier_returns_to_one() -> void:
	var sc := _pass_scene(150.0, 100.0, 3.6)
	var chain := sc.rules.chain()
	gt(chain, 0)
	var decay := 0.5 * sc_t.decay_term(_kmh(150.0))
	sc.run(1.0 / decay - 0.1)
	eq(sc.count(Scoring.KIND_BANKED), 0, "not yet")
	sc.run(0.2)
	var e := sc.first(Scoring.KIND_BANKED)
	if not check(e >= 0, "cashed out"):
		return
	eq(sc.log_tag[e], ScoreEvents.REASON_CASH_OUT)
	eq(sc.log_points[e], chain)
	eq(int(sc.log_value[e]), chain, "banked total")
	eq(sc.rules.banked(), chain)
	eq(sc.rules.chain(), 0)
	eq(sc.rules.multiplier(), 1.0)


func test_cash_out_takes_longer_at_high_speed() -> void:
	var slow := _pass_scene(110.0, 60.0, 3.6)
	var fast := _pass_scene(240.0, 190.0, 3.6)
	var t0 := slow.time
	slow.run(6.0)
	fast.run(6.0)
	eq(slow.count(Scoring.KIND_BANKED), 1, "110 km/h cashes out in ~2 s")
	eq(fast.count(Scoring.KIND_BANKED), 0, "240 km/h still holding after 6 s")
	lt(slow.log_time[slow.first(Scoring.KIND_BANKED)] - t0, 2.5)


func test_no_cash_out_after_dipping_below_min_speed() -> void:
	var sc := _slow_scene(95.0)
	var chain := sc.rules.chain()
	sc.run(0.6)
	eq(sc.rules.multiplier(), 1.0)
	sc.set_speed(150.0)
	sc.run(3.0)
	eq(sc.count(Scoring.KIND_BANKED), 0, "the multiplier drained while slow: chain still at risk")
	eq(sc.rules.chain(), chain)
	sc.checkpoint()
	var e := sc.first(Scoring.KIND_BANKED)
	if check(e >= 0, "checkpoint banks"):
		eq(sc.log_tag[e], ScoreEvents.REASON_CHECKPOINT)
		eq(sc.log_points[e], chain)
	# A new gain above minimum speed makes the next decay a cash-out again.
	sc.add_car(20.0, sc.lane_d(2), 100.0)
	sc.run(6.0)
	eq(sc.count(Scoring.KIND_BANKED), 2)
	eq(sc.log_tag[sc.last(Scoring.KIND_BANKED)], ScoreEvents.REASON_CASH_OUT)


func test_checkpoint_banks_and_keeps_multiplier() -> void:
	var sc := _pass_scene(200.0, 150.0, 3.6)
	var chain := sc.rules.chain()
	var m := sc.rules.multiplier()
	sc.checkpoint()
	var e := sc.first(Scoring.KIND_BANKED)
	if not check(e >= 0):
		return
	eq(sc.log_tag[e], ScoreEvents.REASON_CHECKPOINT)
	eq(sc.log_points[e], chain)
	eq(int(sc.log_value[e]), chain)
	eq(sc.rules.banked(), chain)
	eq(sc.rules.chain(), 0)
	eq(sc.rules.multiplier(), m, "the multiplier is kept")
	sc.checkpoint()
	eq(sc.count(Scoring.KIND_BANKED), 1, "nothing to bank")


func test_hit_loses_chain_but_never_banked() -> void:
	var sc := _pass_scene(200.0, 150.0, 3.6)
	sc.checkpoint()
	var banked := sc.rules.banked()
	sc.add_car(20.0, sc.lane_d(0), 150.0)
	sc.run(2.0)
	var chain := sc.rules.chain()
	gt(chain, 0)
	sc.hit()
	var e := sc.first(Scoring.KIND_CHAIN_LOST)
	if check(e >= 0):
		eq(sc.log_tag[e], ScoreEvents.REASON_HIT)
		eq(sc.log_points[e], chain)
	eq(sc.rules.chain(), 0)
	eq(sc.rules.multiplier(), 1.0, "multiplier drops to 1.0")
	eq(sc.rules.banked(), banked, "banked points are never lost")


func test_run_end_loses_held_chain() -> void:
	var sc := _pass_scene(200.0, 150.0, 3.6)
	sc.checkpoint()
	var banked := sc.rules.banked()
	sc.add_car(20.0, sc.lane_d(0), 150.0)
	sc.run(2.0)
	var chain := sc.rules.chain()
	sc.run_end()
	var e := sc.first(Scoring.KIND_CHAIN_LOST)
	if check(e >= 0):
		eq(sc.log_tag[e], ScoreEvents.REASON_RUN_END)
		eq(sc.log_points[e], chain)
	eq(sc.rules.banked(), banked, "final score = banked total")
	check(sc.rules.is_ended())
	# Nothing happens after the run ended.
	sc.add_car(20.0, sc.lane_d(2), 150.0)
	sc.run(2.0)
	sc.checkpoint()
	sc.bonus(&"clean", 500)
	eq(sc.scored_count(), 2, "no new events")
	eq(sc.rules.banked(), banked)
	# Second hit, then run end: one loss.
	var sc2 := _pass_scene(200.0, 150.0, 3.6)
	sc2.hit()
	sc2.run_end()
	eq(sc2.count(Scoring.KIND_CHAIN_LOST), 1)


func test_bonus_goes_straight_to_banked_with_night_factor() -> void:
	var sc := _pass_scene(200.0, 150.0, 3.6)
	var chain := sc.rules.chain()
	sc.bonus(&"clean", 500)
	eq(sc.rules.banked(), 500)
	eq(sc.rules.chain(), chain, "chain untouched")
	var e := sc.first(Scoring.KIND_BONUS)
	eq(sc.log_tag[e], &"clean")
	eq(sc.log_points[e], 500)
	eq(int(sc.log_value[e]), 500)
	sc.rules.set_night(true)
	sc.bonus(&"pace", 300)
	eq(sc.rules.banked(), 500 + 600, "night doubles leg bonuses")
	eq(int(sc.log_value[sc.last(Scoring.KIND_BONUS)]), 1100)


# ---------------------------------------------------------------- Ghost

func test_nothing_scores_during_the_ghost_period() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	sc.rules.set_ghost(true)
	check(sc.rules.is_ghost())
	sc.add_car(20.0, sc.lane_d(1) + sc.side_offset(0.4), 100.0)   # close pass
	sc.add_car(sc.gap_ahead(8.0), sc.lane_d(0), 150.0)              # cut target / slipstream
	sc.run(2.5)
	sc.steer_to_lane(0, 6.0)
	sc.run(1.5)
	eq(sc.scored_count(), 0, "no pass, close pass or cut")
	eq(sc.count(Scoring.KIND_NEAR_MISS), 0, "no horn hook either")
	near(sc.boost_total, 0.0, EPS, "no boost fill (slipstream included)")
	eq(sc.rules.chain(), 0)
	sc.rules.set_ghost(false)
	sc.steer_to_lane(1, 6.0)
	sc.run_until_steered()
	eq(sc.count(ScoreEvents.CUT), 1, "the cut target had no cooldown from the ghost weave")


func test_pass_overlapping_the_ghost_end_scores_nothing() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	# Fully ahead by 0.2 m; the overlap starts inside the ghost period and ends after it.
	sc.add_car(sc.half_lengths() + 0.2, sc.lane_d(2), 100.0)
	sc.rules.set_ghost(true)
	sc.run(0.1)
	sc.rules.set_ghost(false)
	sc.run(2.0)
	eq(sc.scored_count(), 0)
	# A car that was fully ahead when the ghost ended scores normally.
	sc.add_car(20.0, sc.lane_d(2), 100.0)
	sc.run(2.5)
	eq(sc.count(ScoreEvents.PASS), 1)


# ---------------------------------------------------------------- Sun nudges

func _close_pass_train(n: int, spacing_m: float) -> ScoringScenario:
	var sc := ScoringScenario.new()
	sc.place_player(1, 150.0)
	for k in n:
		sc.add_car(20.0 + spacing_m * k, sc.lane_d(1) + sc.side_offset(0.5), 100.0)
	var rel := _kmh(150.0) - _kmh(100.0)
	sc.run((20.0 + spacing_m * (n - 1) + sc.half_lengths()) / rel + 0.1)
	return sc


func test_five_close_passes_in_10s_nudge_the_sun() -> void:
	var rel := _kmh(150.0) - _kmh(100.0)
	var sc := _close_pass_train(5, rel * 2.0)            # 8 s from first to fifth
	eq(sc.count(ScoreEvents.CLOSE_PASS), 5)
	if eq(sc.count(Scoring.KIND_SUN_NUDGE), 1, "5 within 10 s"):
		near(sc.log_value[sc.first(Scoring.KIND_SUN_NUDGE)], t.sun.close_pass_nudge_pct / 100.0, EPS)
	eq(_close_pass_train(4, rel * 2.0).count(Scoring.KIND_SUN_NUDGE), 0, "only 4")
	eq(_close_pass_train(5, rel * 2.6).count(Scoring.KIND_SUN_NUDGE), 0, "5 over 10.4 s")
	eq(_close_pass_train(10, rel * 1.0).count(Scoring.KIND_SUN_NUDGE), 2, "10 in a row: two nudges")


# ---------------------------------------------------------------- Determinism and allocations

func _traffic_run(seed_value: int, seconds: float) -> PackedInt64Array:
	var sc := TrafficScenario.new(seed_value)
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 160.0, 1)
	sc.observe = false
	sc.populate()
	var rules := Scoring.new(sc.ctx)
	rules.set_player_body(sc.bot.length_m, sc.bot.width_m)
	var buf := ScoreEventBuffer.new(sc_t.event_buffer_capacity)
	var hashes := PackedInt64Array()
	var next := 1.0
	var scored := 0
	for k in roundi(seconds / TrafficScenario.DT):
		sc.tick()
		rules.step(TrafficScenario.DT, sc.bot.state, sc.sim.state, sc.road, buf)
		for e in buf.size():
			if buf.points[e] > 0:
				scored += 1
		if sc.time >= next:
			next += 1.0
			var h := rules.trace_hash()
			h = buf.hash_into(h)
			hashes.append(h)
		buf.clear()
		sc.bot.state.boost_meter = minf(1.0, sc.bot.state.boost_meter + rules.take_boost_fill())
	eq(buf.dropped, 0, "event buffer never full")
	hashes.append(scored)
	hashes.append(rules.banked() + rules.chain())
	return hashes


func test_determinism_trace() -> void:
	var a := _traffic_run(77, 30.0)
	var b := _traffic_run(77, 30.0)
	eq(a.size(), b.size())
	eq(a, b, "same seed, same inputs: same scoring trace")
	gt(float(a[a.size() - 2]), 0.0, "the weaving bot scored something")
	var c := _traffic_run(78, 30.0)
	ne(a, c, "another seed differs")


## A long scripted run with traffic recycled around the weaving player.
func _treadmill(sc: ScoringScenario, seconds: float) -> void:
	var n := roundi(seconds / DT)
	var lane := 1
	var next_weave := 1.5
	for k in n:
		sc.tick()
		for i in sc.traffic.capacity:
			if sc.traffic.active[i] == 1 and sc.traffic.s[i] < sc.player.s - 60.0:
				var ln := sc.traffic.lane[i]
				var ds := 150.0 + 7.0 * float(i)
				sc.remove_car(i)
				sc.add_car_in_lane(ds, ln, 100.0 + 5.0 * float(i % 4))
		if sc.time >= next_weave:
			next_weave += 1.5
			lane = 2 if lane != 2 else 0
			sc.steer_to_lane(lane, 5.0)
	sc.clear_log()


func test_no_allocations_over_a_long_scripted_run() -> void:
	var sc := ScoringScenario.new()
	sc.place_player(1, 170.0)
	for k in 12:
		sc.add_car_in_lane(15.0 + 13.0 * k, k % 3, 100.0 + 5.0 * float(k % 4))
	_treadmill(sc, 2.0)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	_treadmill(sc, 60.0)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "object count stable")
	eq(sc.buf.dropped, 0)
	gt(float(sc.rules.banked() + sc.rules.chain()), 0.0, "it scored")


func test_step_budget_60_cars() -> void:
	var sc := ScoringScenario.new(null, 3, 60)
	sc.place_player(1, 170.0)
	for k in 60:
		sc.add_car_in_lane(-100.0 + 8.0 * k, k % 3, 120.0)
	var rules := sc.rules
	var p := sc.player
	var ts := sc.traffic
	var road := sc.road
	var buf := sc.buf
	var fn := func() -> void:
		rules.step(DT, p, ts, road, buf)
		buf.clear()
	var usec := WBBench.usec_per_call(fn, 200)
	WBBench.report("scoring step, 60 cars", usec, STEP_BUDGET_USEC)
	le(usec, WBBench.budget(STEP_BUDGET_USEC), "scoring step usec")


# ---------------------------------------------------------------- Soak

## Ten minutes of real traffic (TrafficSim + weaving bot): the invariants hold, the
## event buffer never overflows, and every pass matches an independent count of cars
## whose center went from ahead to behind within the lateral window (no shoulder or
## ghost in this run).
func soak_dense_traffic_invariants() -> void:
	var sc := TrafficScenario.new(4242)
	sc.density_per_km_lane = 10.0
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 170.0, 1)
	sc.observe = false
	sc.populate()
	var rules := Scoring.new(sc.ctx)
	var buf := ScoreEventBuffer.new(sc_t.event_buffer_capacity)
	var last_banked := 0
	var bad := 0
	var passes := 0
	var raw := 0
	var prev_ds := PackedFloat64Array()
	var prev_id := PackedInt32Array()
	prev_ds.resize(sc.sim.state.capacity)
	prev_id.resize(sc.sim.state.capacity)
	for k in roundi(600.0 / TrafficScenario.DT):
		sc.tick()
		rules.step(TrafficScenario.DT, sc.bot.state, sc.sim.state, sc.road, buf)
		var ts := sc.sim.state
		for i in ts.capacity:
			if ts.active[i] == 0:
				prev_id[i] = 0
				continue
			var ds := ts.s[i] - sc.bot.state.s
			if prev_id[i] == ts.vehicle_id[i] and prev_ds[i] > 0.0 and ds <= 0.0 \
					and absf(ts.d[i] - sc.bot.state.d) <= sc_t.pass_lateral_window_m:
				raw += 1
			prev_id[i] = ts.vehicle_id[i]
			prev_ds[i] = ds
		for e in buf.size():
			if buf.kind[e] == ScoreEvents.PASS or buf.kind[e] == ScoreEvents.CLOSE_PASS:
				passes += 1
			if buf.points[e] < 0:
				bad += 1
		buf.clear()
		if rules.multiplier() < 1.0 or rules.chain() < 0 or rules.banked() < last_banked \
				or is_nan(rules.multiplier()) or rules.is_on_shoulder():
			bad += 1
		last_banked = rules.banked()
	eq(bad, 0, "invariants")
	eq(buf.dropped, 0)
	gt(float(passes), 40.0, "the soak scored passes")
	le(absf(float(passes - raw)), maxf(2.0, float(raw) * 0.05), "passes %d vs center crossings %d" % [passes, raw])
