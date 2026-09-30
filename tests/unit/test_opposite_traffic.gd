extends WBTest
## OppositeTraffic. Spec: Traffic → Spawning and the opposite carriageway ("visual-only
## traffic across the median. It runs at constant speed with no collision and at lower
## density, and shows headlights at night"); CONTRACTS §5 (own TrafficState, d < 0,
## moving toward -s); no allocations per tick.

const SEED := 4242
const DT := 1.0 / 120.0
const LANES := 3
const AHEAD_M := 750.0

var reg: SpawnFixtureRegistry
var tuning: Tuning
var road: StraightRoadPath
var opp: OppositeTraffic
var ctx: SpawnSource.Context


func before_all() -> void:
	reg = SpawnFixtureRegistry.new()
	tuning = Tuning.load_default()


func _setup(seed_value: int = SEED, leg: int = 1) -> void:
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	road = StraightRoadPath.new(LANES, tuning.road)
	var flow := SpawnSources.Flow.new(tuning.traffic, reg.profiles, reg.types)
	ctx = SpawnSource.Context.new()
	ctx.run = run
	ctx.road = road
	ctx.leg = leg
	ctx.density_per_km_lane = tuning.director.density_per_km_lane(leg)
	ctx.aggressive_share = tuning.director.aggressive_share_frac(leg)
	opp = OppositeTraffic.new(tuning.traffic, road, flow, ctx, run.rng_traffic.derive(&"opposite"), AHEAD_M)
	opp.reset(0.0, ctx.density_per_km_lane)


func test_fills_the_window_on_the_opposite_side() -> void:
	_setup()
	eq(opp.state.count, opp.target_count())
	gt(opp.target_count(), 0)
	var back := -tuning.traffic.opposite_recycle_behind_m
	for i in opp.state.capacity:
		if opp.state.active[i] == 0:
			continue
		lt(opp.state.d[i], 0.0, "d < 0 (opposite carriageway)")
		near(opp.state.d[i], road.opposite_lane_center_d(opp.state.lane[i], opp.state.s[i]), 1e-9, "lane center")
		ge(opp.state.s[i], back)
		le(opp.state.s[i], AHEAD_M)
		gt(opp.state.length[i], 0.0)


func test_density_lower_than_player_side() -> void:
	for leg: int in [1, 8]:
		_setup(SEED, leg)
		var window_km := (AHEAD_M + tuning.traffic.opposite_recycle_behind_m) / Units.M_PER_KM
		var shown := float(opp.state.count) / (window_km * LANES)
		lt(shown, tuning.director.density_per_km_lane(leg), "leg %d" % leg)
		near(opp.density_per_km_lane(),
			tuning.director.density_per_km_lane(leg) * Units.pct_to_frac(tuning.traffic.opposite_density_pct), 1e-9)
		le(opp.state.count, tuning.traffic.opposite_max_vehicles)


func test_constant_speed_toward_minus_s() -> void:
	_setup()
	var player_s := 0.0
	var v_player := Units.kmh_to_mps(180.0)
	var s_prev := PackedFloat64Array()
	var v_prev := PackedFloat64Array()
	var id_prev := PackedInt32Array()
	s_prev.resize(opp.state.capacity)
	v_prev.resize(opp.state.capacity)
	id_prev.resize(opp.state.capacity)
	var moved := 0
	for k in 1200:
		for i in opp.state.capacity:
			s_prev[i] = opp.state.s[i]
			v_prev[i] = opp.state.v[i]
			id_prev[i] = opp.state.vehicle_id[i] if opp.state.active[i] == 1 else 0
		player_s += v_player * DT
		opp.step(DT, player_s)
		for i in opp.state.capacity:
			if opp.state.active[i] == 0 or opp.state.vehicle_id[i] != id_prev[i]:
				continue   # recycled this tick
			near(opp.state.v[i], v_prev[i], 0.0, "constant speed")
			near(s_prev[i] - opp.state.s[i], opp.state.v[i] * DT, 1e-9, "moves toward -s at v")
			gt(opp.state.v[i], 0.0)
			moved += 1
	gt(moved, 1000)


func test_lanes_run_faster_toward_the_median() -> void:
	_setup()
	var v_by_lane := PackedFloat64Array([0, 0, 0])
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			if v_by_lane[opp.state.lane[i]] == 0.0:
				v_by_lane[opp.state.lane[i]] = opp.state.v[i]
			near(opp.state.v[i], v_by_lane[opp.state.lane[i]], 0.0, "one speed per lane: no closing, no overlaps")
	gt(v_by_lane[0], v_by_lane[1])
	gt(v_by_lane[1], v_by_lane[2])
	near(v_by_lane[2], Units.kmh_to_mps(tuning.traffic.opposite_speed_kmh), 1e-9)


func test_recycling_keeps_count_stable_and_hidden() -> void:
	_setup()
	var target := opp.target_count()
	var player_s := 0.0
	var v_player := Units.kmh_to_mps(200.0)
	var known := {}
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			known[opp.state.vehicle_id[i]] = true
	var appeared := 0
	var off_count := 0
	for k in 120 * 60:
		player_s += v_player * DT
		opp.step(DT, player_s)
		if opp.state.count != target:
			off_count += 1
		for i in opp.state.capacity:
			if opp.state.active[i] == 1 and not known.has(opp.state.vehicle_id[i]):
				known[opp.state.vehicle_id[i]] = true
				appeared += 1
				ge(opp.state.s[i] - player_s, AHEAD_M - 1e-6, "recycled beyond the fog (no pop-in)")
	eq(off_count, 0, "count stable every tick")
	gt(opp.recycled, 50)
	eq(appeared, opp.recycled)


func test_recycling_with_a_stopped_player() -> void:
	# Opposite traffic keeps coming toward a stopped player; nothing appears in view.
	_setup()
	var target := opp.target_count()
	var known := {}
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			known[opp.state.vehicle_id[i]] = true
	for k in 120 * 30:
		opp.step(DT, 0.0)
		for i in opp.state.capacity:
			if opp.state.active[i] == 1 and not known.has(opp.state.vehicle_id[i]):
				known[opp.state.vehicle_id[i]] = true
				ge(opp.state.s[i], AHEAD_M - 1e-6, "appears beyond the fog")
	eq(opp.state.count, target)
	gt(opp.recycled, 0)


func test_density_change_follows_through_recycling() -> void:
	_setup(SEED, 1)
	var low := opp.target_count()
	opp.set_density(tuning.director.density_per_km_lane(8), 0.0)
	var high := opp.target_count()
	gt(high, low)
	opp.step(DT, 0.0)
	eq(opp.state.count, high, "topped up (beyond the fog)")
	opp.set_density(tuning.director.density_per_km_lane(1), 0.0)
	opp.step(DT, 0.0)
	eq(opp.state.count, low, "trimmed from the far end")


func test_headlights_at_night() -> void:
	_setup()
	opp.set_night(true)
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			check(opp.state.has_flag(i, TrafficState.FLAG_HEADLIGHTS))
	var player_s := 0.0
	for k in 120 * 10:
		player_s += 50.0 * DT
		opp.step(DT, player_s)
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			check(opp.state.has_flag(i, TrafficState.FLAG_HEADLIGHTS), "recycled vehicles too")
	opp.set_night(false)
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			check(not opp.state.has_flag(i, TrafficState.FLAG_HEADLIGHTS))


func test_zero_allocations_per_tick_after_warmup() -> void:
	_setup()
	var player_s := 0.0
	for k in 600:
		player_s += 60.0 * DT
		opp.step(DT, player_s)
	var recycled := opp.recycled
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for k in 6000:
		player_s += 60.0 * DT
		opp.step(DT, player_s)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before)
	gt(opp.recycled, recycled, "recycling happened during the measured ticks")


func test_deterministic() -> void:
	var hashes := PackedInt64Array()
	for seed_value: int in [SEED, SEED, SEED + 1]:
		_setup(seed_value)
		var player_s := 0.0
		for k in 120 * 20:
			player_s += 45.0 * DT
			opp.step(DT, player_s)
		hashes.append(opp.state.trace_hash())
	eq(hashes[0], hashes[1])
	ne(hashes[0], hashes[2])


## One tick of the opposite side at leg 8 (the densest), with the player at 200 km/h.
## WP4.6: it is visual-only but runs every 120 Hz tick; the owner's iPhone web build
## measured ~26 us per tick before the far-tick split.
func test_step_tick_budget() -> void:
	_setup(SEED, 8)
	var st := {"s": 0.0}
	var v_player := Units.kmh_to_mps(200.0)
	var tick := func() -> void:
		st["s"] = float(st["s"]) + v_player * DT
		opp.step(DT, float(st["s"]))
	for k in 240:
		tick.call()
	var usec := WBBench.usec_per_call(tick, 2000)
	WBBench.report("opposite traffic step, %d vehicles" % opp.state.count, usec, 20.0)
	le(usec, WBBench.budget(20.0), "opposite step usec")


func test_lane_centers_refresh_at_the_far_rate() -> void:
	# d is re-read from the road for every vehicle within one far tick (30 Hz).
	_setup()
	for i in opp.state.capacity:
		opp.state.d[i] = 0.0
	var ratio := tuning.traffic.far_tick_ratio()
	gt(ratio, 1, "far rate below the tick rate")
	for k in ratio:
		opp.step(DT, 0.0)
	for i in opp.state.capacity:
		if opp.state.active[i] == 1:
			near(opp.state.d[i], road.opposite_lane_center_d(opp.state.lane[i], opp.state.s[i]), 1e-9,
				"slot %d back on its lane center" % i)
