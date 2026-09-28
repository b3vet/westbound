extends WBTest
## IDM suite (pure model, src/traffic/idm.gd). Spec: Traffic → Longitudinal model: IDM
## (formula, delta = 4); Fairness rule 3 (brake lights) and 4 (6 m/s^2 clamp) are
## checked through TrafficSim here and in test_traffic_sim.gd.

const DT := 1.0 / 120.0
# A commuter-like driver for the pure-model tests.
const A_MAX := 1.5
const B := 2.0
const T := 1.3
const S0 := 2.0
const DELTA := 4
const FLOOR := 0.1

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


func _a(v: float, v0: float, gap: float, dv: float) -> float:
	return Idm.accel(v, v0, gap, dv, A_MAX, B, T, S0, DELTA, FLOOR)


func test_formula_matches_spec() -> void:
	var v := 25.0
	var v0 := 33.0
	var gap := 40.0
	var dv := 3.0
	var s_star := S0 + maxf(0.0, v * T + v * dv / (2.0 * sqrt(A_MAX * B)))
	var expected := A_MAX * (1.0 - pow(v / v0, 4.0) - pow(s_star / gap, 2.0))
	near(_a(v, v0, gap, dv), expected, 1e-12, "a = a_max [1 - (v/v0)^4 - (s*/s)^2]")
	near(Idm.desired_gap(v, dv, A_MAX, B, T, S0), s_star, 1e-12, "s*")
	# s* never drops below s0 + 0 (max(0, ...)): a fast-receding leader.
	near(Idm.desired_gap(v, -40.0, A_MAX, B, T, S0), S0, 1e-12, "s* floor is s0")
	near(Idm.free_accel(v, v0, A_MAX, DELTA), A_MAX * (1.0 - pow(v / v0, 4.0)), 1e-12)
	near(Idm.interaction_accel(v, gap, dv, A_MAX, B, T, S0, FLOOR), -A_MAX * pow(s_star / gap, 2.0), 1e-12)
	eq(Idm.interaction_accel(v, INF, dv, A_MAX, B, T, S0, FLOOR), 0.0, "free road: no interaction")
	eq(_a(v, v0, INF, 0.0), Idm.free_accel(v, v0, A_MAX, DELTA), "INF gap = free road")
	near(Idm.pow_int(1.3, 4), 1.3 * 1.3 * 1.3 * 1.3, 1e-12)
	eq(Idm.pow_int(2.0, 0), 1.0)
	eq(Idm.pow_int(2.0, 5), 32.0)
	near(t.traffic.idm_delta, 4.0, 0.0, "spec: delta = 4")


func test_free_road_accelerates_to_v0() -> void:
	var v := 0.0
	var v0 := 30.0
	var time := 0.0
	var prev_a := INF
	while time < 120.0:
		var a := _a(v, v0, INF, 0.0)
		check(a <= prev_a + 1e-12, "free-road acceleration decreases monotonically")
		prev_a = a
		v += a * DT
		time += DT
	near(_a(0.0, v0, INF, 0.0), A_MAX, 1e-12, "starts at a_max")
	near(v, v0, 0.02 * v0, "reaches v0 within 2% after 2 min")
	le(v, v0, "never overshoots v0")


func test_equilibrium_gap_at_steady_state() -> void:
	# Leader at a constant speed well below the follower's v0: the follower settles at
	# s_e = (s0 + vT) / sqrt(1 - (v/v0)^4), close to s0 + vT.
	var vl := 20.0
	var v0 := 40.0
	var v := 25.0
	var gap := 80.0
	for k in roundi(300.0 / DT):
		var a := _a(v, v0, gap, v - vl)
		v += a * DT
		gap += (vl - v) * DT
	var se := Idm.equilibrium_gap(vl, v0, T, S0, DELTA)
	near(v, vl, 1e-3, "follower matches the leader's speed")
	near(gap, se, 0.01, "gap settles at the IDM equilibrium")
	within_pct(gap, S0 + vl * T, 0.04, "≈ s0 + vT when v << v0")
	near(_a(vl, v0, se, 0.0), 0.0, 1e-9, "zero acceleration at the equilibrium gap")
	eq(Idm.equilibrium_gap(v0, v0, T, S0, DELTA), INF, "no equilibrium at v >= v0")


func test_approach_stopped_leader_without_collision() -> void:
	for start_v: float in [20.0, 33.0, 45.0]:
		var v := start_v
		var gap := 400.0
		var min_gap := INF
		var min_a := 0.0
		for k in roundi(120.0 / DT):
			var a := maxf(_a(v, 50.0, gap, v), -t.traffic.max_decel_mps2)
			min_a = minf(min_a, a)
			var nv := maxf(0.0, v + a * DT)
			gap -= (v + nv) * 0.5 * DT
			v = nv
			min_gap = minf(min_gap, gap)
		gt(min_gap, 0.0, "no collision from %.0f m/s" % start_v)
		near(v, 0.0, 0.05, "stopped behind the leader from %.0f m/s" % start_v)
		ge(gap, S0 * 0.9, "stops about s0 behind (from %.0f m/s)" % start_v)
		le(-min_a, B * 2.0, "comfortable approach: planned early, never near the clamp (from %.0f m/s)" % start_v)


func test_tight_gap_demands_more_than_the_clamp() -> void:
	# A leader 3 m ahead and 15 m/s slower: raw IDM asks for far more than 6 m/s^2.
	var a := _a(40.0, 45.0, 3.0, 15.0)
	lt(a, -t.traffic.max_decel_mps2 * 5.0, "raw IDM is unclamped")
	# Gap floor: contact does not divide by zero.
	finite(_a(40.0, 45.0, 0.0, 15.0))
	finite(_a(40.0, 45.0, -2.0, 15.0))
