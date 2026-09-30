extends WBTest
## Flow's lane-conditioned driver mix after plan D15 (WP6.6): the racer, the fast share
## by leg (aggressive + racer, DirectorTuning), faster left lanes, slow profiles kept
## right, the per-car desired-speed jitter. Spec: Traffic → Driver types, Traffic
## director (difficulty by leg), Spawning ("at their lane's flow speed"), Fairness rule
## 7 (lane discipline). Real registry and tuning (test_spawn_sources.gd covers Flow's
## mechanics with its own fixture registry).

const SEED := 20260929
const DRAWS := 6000
const QUARTER := 1500
const EIGHTH := 750
const THIRD := 2000
const SHARE_TOLERANCE := 0.025   # absolute, over DRAWS draws

var t: Tuning
var reg: TrafficRegistry
var racer: int
var aggressive: int


func before_all() -> void:
	t = Tuning.load_default()
	reg = TrafficRegistry.load_default(t.traffic)
	racer = reg.profile_index(&"racer")
	aggressive = reg.profile_index(&"aggressive")


func _flow() -> SpawnSources.Flow:
	return SpawnSources.Flow.new(t.traffic, reg.profiles, reg.types)


func _ctx(seed_value: int, leg: int, lanes: int = 3) -> SpawnSource.Context:
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, t)
	var c := SpawnSource.Context.new()
	c.run = run
	c.rng = run.rng_traffic.derive(&"flow")
	c.road = StraightRoadPath.new(lanes, t.road)
	c.traffic = TrafficState.new(8)
	c.player = VehicleState.new()
	c.leg = leg
	c.density_per_km_lane = t.director.density_per_km_lane(leg)
	c.aggressive_share = t.director.aggressive_share_frac(leg)
	c.hesitant_allowed = leg >= t.director.hesitant_first_leg
	return c


## Profile counts over n draws for `lane` of `lanes` (index = profile id), plus v0 sums.
func _draws(c: SpawnSource.Context, lane: int, lanes: int, n: int, min_speed: float = 0.0) -> PackedInt32Array:
	var flow := _flow()
	var counts := PackedInt32Array()
	counts.resize(reg.profile_count())
	var rec := SpawnSource.Record.new()
	for k in n:
		check(flow.draw_into(c, c.rng, lane, lanes, min_speed, rec), "a vehicle fits lane %d" % lane)
		counts[rec.profile_id] += 1
	return counts


func _frac(counts: PackedInt32Array, p: int) -> float:
	var n := 0
	for x in counts:
		n += x
	return float(counts[p]) / float(maxi(n, 1))


# ---------------------------------------------------------------- Tuning

func test_fast_share_by_leg() -> void:
	# About 15 % at leg 1 -> 35 % at leg 8 (aggressive 5 -> 20 %, racer 10 -> 15 %).
	var d := t.director
	near(d.aggressive_share_frac(1) + d.racer_share_frac(1), 0.15, 1e-9, "leg 1")
	near(d.aggressive_share_frac(8) + d.racer_share_frac(8), 0.35, 1e-9, "leg 8")
	near(d.racer_share_frac(12), d.racer_share_frac(8), 1e-9, "holds after the ramp")
	for leg in range(1, 8):
		le(d.racer_share_frac(leg), d.racer_share_frac(leg + 1), "rises with the leg")


func test_lane_flows_rise_to_the_left() -> void:
	var fl := t.traffic.lane_flow_speeds_from_right_kmh
	for i in fl.size() - 1:
		lt(fl[i], fl[i + 1], "flow rises to the left")
	# Plan D15: faster left lanes than before (95 / 115 / 135 / 150 from the right), the
	# slow lane unchanged.
	var before := PackedFloat64Array([95.0, 115.0, 135.0, 150.0])
	for i in before.size():
		ge(fl[i], before[i], "lane %d from the right is not slower" % i)
	near(fl[0], before[0], 1e-9, "the slow lane stays")
	gt(Units.mps_to_kmh(t.traffic.lane_flow_speed_mps(0, 3)), before[2], "3 lanes: a faster fast lane")
	gt(Units.mps_to_kmh(t.traffic.lane_flow_speed_mps(0, 4)), before[3], "4 lanes: a faster fast lane")
	# Trucks and buses still fit the slow lane (their top speed within tolerance).
	le(fl[0] - t.traffic.spawn_lane_speed_tolerance_kmh, 90.0 + 1e-9)
	# The weights of the other profiles are percentages.
	var total := 0.0
	for w in t.traffic.spawn_profile_weights_pct:
		total += w
	near(total, 100.0, 1e-9)
	eq(t.traffic.spawn_profile_ids.size(), t.traffic.spawn_profile_weights_pct.size())
	check(not t.traffic.spawn_profile_ids.has(t.traffic.spawn_racer_profile_id), "the racer share comes from the director")


# ---------------------------------------------------------------- Mix per lane

func test_racer_share_in_the_middle_lane() -> void:
	# Lane 1 of 3: every profile class fits, so both fast shares apply as tuned.
	for leg: int in [1, 8]:
		var counts := _draws(_ctx(SEED + leg, leg), 1, 3, DRAWS)
		near(_frac(counts, racer), t.director.racer_share_frac(leg), SHARE_TOLERANCE, "racer, leg %d" % leg)
		near(_frac(counts, aggressive), t.director.aggressive_share_frac(leg), SHARE_TOLERANCE, "aggressive, leg %d" % leg)


func test_fast_lane_is_all_fast() -> void:
	# A lane that flows above every other profile's top speed (here a 3-lane road with a
	# 170 km/h fast lane) is all fast: aggressive and racer share it in proportion to
	# their shares.
	var fast_t: Tuning = t.duplicate()
	fast_t.traffic = t.traffic.duplicate() as TrafficTuning
	fast_t.traffic.lane_flow_speeds_from_right_kmh = PackedFloat64Array([95.0, 130.0, 170.0, 185.0])
	var saved := t
	t = fast_t
	for leg: int in [1, 8]:
		var counts := _draws(_ctx(SEED + 10 + leg, leg), 0, 3, DRAWS)
		near(_frac(counts, racer) + _frac(counts, aggressive), 1.0, 1e-9, "only fast profiles, leg %d" % leg)
		var want := t.director.racer_share_frac(leg) / (t.director.racer_share_frac(leg) + t.director.aggressive_share_frac(leg))
		near(_frac(counts, racer), want, SHARE_TOLERANCE, "racer : aggressive by their shares, leg %d" % leg)
	t = saved


func test_racer_never_in_the_slow_lane() -> void:
	for lanes: int in [2, 3, 4]:
		var c := _ctx(SEED + 20 + lanes, 8, lanes)
		var left := reg.profiles[racer].spawn_left_lane_count
		for lane in lanes:
			var counts := _draws(c, lane, lanes, QUARTER)
			if lane >= left or lane == lanes - 1:
				eq(counts[racer], 0, "no racer in lane %d of %d" % [lane, lanes])
			else:
				gt(counts[racer], 0, "racers in lane %d of %d" % [lane, lanes])


func test_slow_profiles_keep_right() -> void:
	# Cruisers, trucks, buses, vans and Hesitant drivers never spawn in the leftmost lane
	# of a 3- or 4-lane road; cruisers, trucks and buses only in the rightmost.
	for lanes: int in [3, 4]:
		var c := _ctx(SEED + 30 + lanes, 8, lanes)
		var left := _draws(c, 0, lanes, QUARTER)
		for id: StringName in [&"cruiser", &"truck", &"bus", &"van", &"hesitant"]:
			eq(left[reg.profile_index(id)], 0, "no %s in the fast lane of %d lanes" % [id, lanes])
		for lane in lanes - 1:
			var counts := _draws(c, lane, lanes, EIGHTH)
			for id: StringName in [&"cruiser", &"truck", &"bus"]:
				eq(counts[reg.profile_index(id)], 0, "%s keeps right (lane %d of %d)" % [id, lane, lanes])


func test_overall_fast_share_rises_by_leg() -> void:
	# Over a 3-lane road's three lanes (equal counts), the fast traffic share rises from
	# leg 1 to leg 8 (racers only in the two left lanes), to about a third at leg 8.
	var shares: Array[float] = []
	for leg: int in [1, 8]:
		var fast := 0
		var n := 0
		for lane in 3:
			var counts := _draws(_ctx(SEED + 40 + leg, leg), lane, 3, THIRD)
			fast += counts[racer] + counts[aggressive]
			for x in counts:
				n += x
		shares.append(float(fast) / float(n))
	print("      fast share of spawns (3 lanes): leg 1 %.0f%%, leg 8 %.0f%%" % [100.0 * shares[0], 100.0 * shares[1]])
	lt(shares[0], shares[1], "rises by leg")
	gt(shares[1], 0.25)


func test_behind_spawns_are_fast() -> void:
	# A behind spawn in the fast lane for a player at 120 km/h: min_speed = player + margin.
	var c := _ctx(SEED + 50, 3)
	var min_speed := Units.kmh_to_mps(120.0 + t.traffic.spawn_behind_speed_margin_kmh)
	var flow := _flow()
	var rec := SpawnSource.Record.new()
	var racers := 0
	for k in 500:
		check(flow.draw_into(c, c.rng, 0, 3, min_speed, rec))
		ge(rec.v0, min_speed - 1e-9, "v0 above the behind spawn's minimum")
		if rec.profile_id == racer:
			racers += 1
	gt(racers, 0, "racers come from behind")


func test_without_a_run_there_is_no_racer_share() -> void:
	# Contexts without a run (fixtures) keep the pre-D15 mix: no racer share.
	var c := _ctx(SEED + 60, 8)
	c.run = null
	var counts := _draws(c, 1, 3, QUARTER)
	eq(counts[racer], 0)


# ---------------------------------------------------------------- Desired-speed jitter

func test_v0_jitter_spreads_a_clipped_band() -> void:
	# Hesitant (90-120 km/h) in the middle lane (flow 130): the lane band clips its range
	# to the top, so without jitter every one would want exactly 120 km/h.
	var c := _ctx(SEED + 70, 8)
	var flow := _flow()
	var rec := SpawnSource.Record.new()
	var hes := reg.profile_index(&"hesitant")
	var lo := INF
	var hi := -INF
	for k in DRAWS:
		flow.draw_into(c, c.rng, 1, 3, 0.0, rec)
		var p := rec.profile_id
		ge(rec.v0, reg.v0_min[p] - 1e-9, "inside %s's range" % reg.profiles[p].id)
		le(rec.v0, reg.v0_max[p] + 1e-9, "inside %s's range" % reg.profiles[p].id)
		near(rec.v, t.traffic.lane_flow_speed_mps(1, 3), 1e-9, "spawns at the lane's flow speed")
		if p == hes:
			lo = minf(lo, rec.v0)
			hi = maxf(hi, rec.v0)
	gt(hi - lo, Units.kmh_to_mps(3.0), "Hesitant desired speeds are spread")
	gt(t.traffic.spawn_v0_jitter_pct, 0.0)


func test_draws_are_deterministic() -> void:
	var a := _draws(_ctx(SEED + 80, 5), 1, 3, 500)
	var b := _draws(_ctx(SEED + 80, 5), 1, 3, 500)
	eq(a, b)
