extends WBTest
## Flow / Daily SpawnSources. Spec: Traffic → Spawning ("at their lane's flow speed,
## with IDM-consistent gaps"), Traffic director (density 8 -> 16 per km per lane over
## legs 1-8, aggressive share 5% -> 20%, Hesitant from leg 3, Daily = Flow seeded by
## date), Fairness rule 7 (flow speeds rise to the left, slow profiles keep right).

const SEED := 20260928
const RUN_KM := 30.0
const LANES := 3
const DENSITY_TOLERANCE := 0.10
const SHARE_TOLERANCE := 0.02   # absolute, over ~2-4k vehicles
const LIVE_CAPACITY := 4000

var reg: SpawnFixtureRegistry
var tuning: Tuning


func before_all() -> void:
	reg = SpawnFixtureRegistry.new()
	tuning = Tuning.load_default().duplicate() as Tuning
	# The fixture registry has the spec's driver table, so its lanes keep the flow speeds
	# and mix it was written for. Plan D15 (WP6.6) raised the real left-lane flows and
	# added the racer; tests/unit/test_spawn_mix.gd covers the real data.
	tuning.traffic = tuning.traffic.duplicate() as TrafficTuning
	tuning.traffic.lane_flow_speeds_from_right_kmh = PackedFloat64Array([95.0, 115.0, 135.0, 150.0])
	tuning.traffic.spawn_v0_jitter_pct = 0.0
	tuning.traffic.spawn_profile_weights_pct = PackedFloat64Array([26.0, 34.0, 12.0, 4.0, 10.0, 4.0, 10.0])


# ---------------------------------------------------------------- Helpers

func _flow() -> SpawnSources.Flow:
	return SpawnSources.Flow.new(tuning.traffic, reg.profiles, reg.types)


func _ctx(seed_value: int, leg: int, lanes: int = LANES) -> SpawnSource.Context:
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	var c := SpawnSource.Context.new()
	c.run = run
	c.rng = run.rng_traffic.derive(&"flow")
	c.road = StraightRoadPath.new(lanes, tuning.road)
	c.traffic = TrafficState.new(LIVE_CAPACITY)
	c.player = VehicleState.new()
	c.player.s = -INF
	c.leg = leg
	c.density_per_km_lane = tuning.director.density_per_km_lane(leg)
	c.aggressive_share = tuning.director.aggressive_share_frac(leg)
	c.hesitant_allowed = leg >= tuning.director.hesitant_first_leg
	return c


## Plans consecutive batches over `km`, committing each into ctx.traffic (static, as
## the director would just before the next batch) when `commit` is set.
func _run(flow: SpawnSources.Flow, c: SpawnSource.Context, km: float, commit: bool = true) -> Array[SpawnSource.Record]:
	var all: Array[SpawnSource.Record] = []
	var batch := tuning.director.spawn_batch_length_m
	var a := 0.0
	while a < km * Units.M_PER_KM:
		var out: Array[SpawnSource.Record] = []
		flow.plan_batch(c, a, a + batch, out)
		for rec in out:
			check(rec.s >= a and rec.s < a + batch, "record inside its batch")
			all.append(rec)
			if commit:
				_commit(c.traffic, rec)
		a += batch
	return all


func _commit(ts: TrafficState, rec: SpawnSource.Record) -> void:
	var i := ts.allocate()
	ts.s[i] = rec.s
	ts.v[i] = rec.v
	ts.v0[i] = rec.v0
	ts.lane[i] = rec.lane
	ts.target_lane[i] = rec.lane
	ts.length[i] = reg.types[rec.type_id].length_m
	ts.width[i] = reg.types[rec.type_id].width_m
	ts.type_id[i] = rec.type_id
	ts.profile_id[i] = rec.profile_id


func _share(recs: Array[SpawnSource.Record], id: StringName) -> float:
	var p := reg.profile_index(id)
	var n := 0
	for r in recs:
		if r.profile_id == p:
			n += 1
	return float(n) / float(maxi(recs.size(), 1))


func _hash(recs: Array[SpawnSource.Record]) -> int:
	var h := TraceHash.SEED
	for r in recs:
		h = TraceHash.mix_float(h, r.s)
		h = TraceHash.mix_int(h, r.lane)
		h = TraceHash.mix_float(h, r.v)
		h = TraceHash.mix_float(h, r.v0)
		h = TraceHash.mix_int(h, r.type_id)
		h = TraceHash.mix_int(h, r.profile_id)
		h = TraceHash.mix_int(h, r.model_variant)
		h = TraceHash.mix_int(h, r.color_index)
	return h


## Minimum center spacing a follower record needs behind a leader record.
func _needed(flow: SpawnSources.Flow, f: SpawnSource.Record, l: SpawnSource.Record) -> float:
	return flow.min_spacing(f.profile_id, f.v, flow.length_of(f.type_id), l.v, flow.length_of(l.type_id))


# ---------------------------------------------------------------- Density

func test_density_matches_leg_target() -> void:
	for leg: int in [1, 4, 8, 12]:
		var c := _ctx(SEED + leg, leg)
		var recs := _run(_flow(), c, RUN_KM)
		var per_km_lane := float(recs.size()) / (RUN_KM * LANES)
		within_pct(per_km_lane, tuning.director.density_per_km_lane(leg), DENSITY_TOLERANCE, "leg %d density" % leg)


func test_density_without_live_traffic_is_close() -> void:
	# Stateless planning (nothing committed between batches) restarts each lane at a
	# random phase; still within tolerance.
	var c := _ctx(SEED, 1)
	var recs := _run(_flow(), c, RUN_KM, false)
	within_pct(float(recs.size()) / (RUN_KM * LANES), tuning.director.density_per_km_lane(1), DENSITY_TOLERANCE)


func test_density_is_per_lane() -> void:
	var c := _ctx(SEED, 8)
	var recs := _run(_flow(), c, RUN_KM)
	var counts := PackedInt32Array([0, 0, 0])
	for r in recs:
		counts[r.lane] += 1
	for lane in LANES:
		within_pct(float(counts[lane]) / RUN_KM, tuning.director.density_per_km_lane(8), DENSITY_TOLERANCE,
			"lane %d" % lane)


func test_zero_density_plans_nothing() -> void:
	var c := _ctx(SEED, 1)
	c.density_per_km_lane = 0.0
	var out: Array[SpawnSource.Record] = []
	_flow().plan_batch(c, 0.0, 300.0, out)
	eq(out.size(), 0)


# ---------------------------------------------------------------- Lane discipline

func test_lane_flow_speed_ordering() -> void:
	var c := _ctx(SEED, 5, 4)
	var recs := _run(_flow(), c, RUN_KM)
	var lanes := 4
	var sum_v := PackedFloat64Array([0, 0, 0, 0])
	var sum_v0 := PackedFloat64Array([0, 0, 0, 0])
	var n := PackedInt32Array([0, 0, 0, 0])
	for r in recs:
		near(r.v, tuning.traffic.lane_flow_speed_mps(r.lane, lanes), 1e-9, "spawns at its lane's flow speed")
		sum_v[r.lane] += r.v
		sum_v0[r.lane] += r.v0
		n[r.lane] += 1
	for lane in lanes - 1:
		gt(sum_v[lane] / n[lane], sum_v[lane + 1] / n[lane + 1], "flow speed rises to the left (lane %d)" % lane)
		gt(sum_v0[lane] / n[lane], sum_v0[lane + 1] / n[lane + 1], "desired speed rises to the left (lane %d)" % lane)


func test_slow_profiles_keep_right() -> void:
	var c := _ctx(SEED, 8)
	var recs := _run(_flow(), c, RUN_KM)
	var right_first := LANES - tuning.traffic.spawn_keep_right_lane_count
	var keep_right := 0
	for r in recs:
		if reg.profiles[r.profile_id].keep_right:
			keep_right += 1
			ge(r.lane, right_first, "%s spawned in lane %d" % [reg.profiles[r.profile_id].id, r.lane])
	gt(keep_right, 0, "keep-right profiles do spawn")
	gt(_share(recs, &"truck"), 0.0, "trucks spawn")


func test_desired_speed_within_profile_range() -> void:
	var c := _ctx(SEED, 8)
	for r in _run(_flow(), c, RUN_KM * 0.5):
		var p := reg.profiles[r.profile_id]
		ge(r.v0, p.desired_speed_min_mps() - 1e-9)
		le(r.v0, p.desired_speed_max_mps() + 1e-9)


func test_types_variants_and_colors() -> void:
	var c := _ctx(SEED, 8)
	var palette := tuning.traffic.spawn_palette_fallback_count
	var colors := {}
	for r in _run(_flow(), c, RUN_KM * 0.5):
		var t := reg.types[r.type_id]
		check(t.allowed_profiles.has(reg.profiles[r.profile_id].id), "type %s allows %s" % [t.id, reg.profiles[r.profile_id].id])
		check(r.model_variant >= 0 and r.model_variant < t.model_scene_paths.size(), "model variant in range")
		check(r.color_index >= 0 and r.color_index < palette, "color index in range")
		check(is_nan(r.d), "d = lane center")
		eq(r.flags, 0)
		colors[r.color_index] = true
	eq(colors.size(), palette, "every palette entry used")
	# A biome palette sets the range.
	var farmland := load("res://data/biomes/farmland.tres") as BiomeDef
	c.biome = farmland
	for r in _run(_flow(), c, 3.0):
		check(r.color_index < farmland.traffic_palette.size())


# ---------------------------------------------------------------- Driver mix by leg

func test_aggressive_share_by_leg() -> void:
	for leg: int in [1, 8, 12]:
		var c := _ctx(SEED + 100 + leg, leg)
		var recs := _run(_flow(), c, RUN_KM)
		near(_share(recs, &"aggressive"), tuning.director.aggressive_share_frac(leg), SHARE_TOLERANCE, "leg %d" % leg)


func test_hesitant_only_from_leg_3() -> void:
	for leg: int in [1, 2]:
		var recs := _run(_flow(), _ctx(SEED + leg, leg), RUN_KM * 0.5)
		eq(_share(recs, &"hesitant"), 0.0, "no Hesitant on leg %d" % leg)
	gt(_share(_run(_flow(), _ctx(SEED + 3, 3), RUN_KM * 0.5), &"hesitant"), 0.0, "Hesitant from leg 3")
	# The profile's own min_leg also gates it, even if the context allowed it.
	var c := _ctx(SEED, 2)
	c.hesitant_allowed = true
	eq(_share(_run(_flow(), c, RUN_KM * 0.5), &"hesitant"), 0.0, "profile min_leg")


# ---------------------------------------------------------------- IDM-consistent gaps

func test_idm_consistent_gaps_within_plan() -> void:
	var flow := _flow()
	var c := _ctx(SEED, 8)
	var recs := _run(flow, c, RUN_KM)
	recs.sort_custom(func(a: SpawnSource.Record, b: SpawnSource.Record) -> bool: return a.s < b.s)
	var prev: Array[SpawnSource.Record] = [null, null, null]
	var checked := 0
	for r in recs:
		var f := prev[r.lane]
		if f != null:
			ge(r.s - f.s, _needed(flow, f, r) - 1e-9, "gap in lane %d at s=%.1f" % [r.lane, r.s])
			checked += 1
		prev[r.lane] = r
	gt(checked, 1000)


func test_headway_scale_scales_spawn_gaps() -> void:
	# Plan D11: Flow's s* uses the same headway scale as the sim (late legs drive closer).
	var flow := _flow()
	var v := Units.kmh_to_mps(110.0)
	for p in reg.profiles.size():
		var base := flow.desired_gap(p, v, 0.0)
		flow.headway_scale = 0.8
		near(flow.desired_gap(p, v, 0.0), base - 0.2 * v * reg.profiles[p].idm_headway_s, 1e-9, reg.profiles[p].id)
		flow.headway_scale = 1.0


func test_headway_scale_ramps_by_leg() -> void:
	var d := tuning.director
	near(d.headway_scale(1), d.headway_scale_first, 1e-9)
	near(d.headway_scale(d.ramp_last_leg), d.headway_scale_last, 1e-9)
	near(d.headway_scale(d.ramp_last_leg + 4), d.headway_scale_last, 1e-9, "holds after the last leg")
	le(d.headway_scale_last, d.headway_scale_first, "late legs drive closer, never looser")
	gt(d.headway_scale_last, 0.5, "still IDM-safe headways")


func test_idm_consistent_gaps_to_live_traffic() -> void:
	# Live traffic already in the batch range (e.g. it drifted in faster than the
	# player advanced), some of it changing lanes: new vehicles keep s* both ways.
	var flow := _flow()
	var c := _ctx(SEED, 8)
	var rng := Rng.new(SEED).derive(&"live")
	var commuter := reg.profile_index(&"commuter")
	for i in 60:
		var lane := rng.int_range(0, LANES - 1)
		var j := c.traffic.allocate()
		c.traffic.s[j] = rng.float_range(0.0, 3000.0)
		c.traffic.lane[j] = lane
		c.traffic.target_lane[j] = clampi(lane + rng.int_range(-1, 1), 0, LANES - 1)
		c.traffic.v[j] = rng.float_range(20.0, 40.0)
		c.traffic.length[j] = 4.6
		c.traffic.profile_id[j] = commuter
	var ts := c.traffic
	var live := ts.count   # live slots are 0..live-1 (allocation order); new ones follow
	var recs: Array[SpawnSource.Record] = []
	var a := 0.0
	while a < 3000.0:
		var out: Array[SpawnSource.Record] = []
		flow.plan_batch(c, a, a + 300.0, out)
		for r in out:
			recs.append(r)
		# The director commits each batch before planning the next.
		for r in out:
			_commit(ts, r)
		a += 300.0
	gt(recs.size(), 50)
	# IDM couples immediate neighbors: in each lane, sort live (current or target lane)
	# and new vehicles together; every pair involving a new vehicle keeps s*.
	var checked := 0
	for lane in LANES:
		var s_arr := PackedFloat64Array()
		var v_arr := PackedFloat64Array()
		var len_arr := PackedFloat64Array()
		var p_arr := PackedInt32Array()
		var is_new := PackedByteArray()
		var order: Array[int] = []
		for i in live:
			if ts.lane[i] == lane or ts.target_lane[i] == lane:
				order.append(s_arr.size())
				s_arr.append(ts.s[i])
				v_arr.append(ts.v[i])
				len_arr.append(ts.length[i])
				p_arr.append(ts.profile_id[i])
				is_new.append(0)
		for r in recs:
			if r.lane == lane:
				order.append(s_arr.size())
				s_arr.append(r.s)
				v_arr.append(r.v)
				len_arr.append(flow.length_of(r.type_id))
				p_arr.append(r.profile_id)
				is_new.append(1)
		order.sort_custom(func(x: int, y: int) -> bool: return s_arr[x] < s_arr[y])
		for k in order.size() - 1:
			var f := order[k]
			var l := order[k + 1]
			if is_new[f] == 0 and is_new[l] == 0:
				continue
			checked += 1
			ge(s_arr[l] - s_arr[f], flow.min_spacing(p_arr[f], v_arr[f], len_arr[f], v_arr[l], len_arr[l]) - 1e-9,
				"lane %d gap at s=%.1f (new follower %d, new leader %d)" % [lane, s_arr[f], is_new[f], is_new[l]])
	gt(checked, 50)


func test_desired_gap_formula() -> void:
	# s* = s0 + max(0, vT + v dv / (2 sqrt(a b)))
	near(SpawnSources.idm_desired_gap(30.0, 0.0, 1.5, 2.0, 1.0, 4.0), 47.0, 1e-9)
	near(SpawnSources.idm_desired_gap(30.0, 10.0, 1.5, 2.0, 1.0, 4.0), 2.0 + 45.0 + 300.0 / 4.0, 1e-9)
	near(SpawnSources.idm_desired_gap(10.0, -100.0, 1.5, 2.0, 1.0, 4.0), 2.0, 1e-9, "never below s0")


# ---------------------------------------------------------------- Single (behind) spawns

func test_plan_single_respects_speed_floor_and_neighbors() -> void:
	var flow := _flow()
	flow.player_length_m = 4.5
	flow.player_width_m = 1.9
	var c := _ctx(SEED, 8)
	var rec := SpawnSource.Record.new()
	var min_speed := Units.kmh_to_mps(120.0)
	var ok := 0
	for i in 200:
		if flow.plan_single(c, 0.0, 0, min_speed, rec):
			ok += 1
			ge(rec.v, min_speed)
			ge(rec.v0, min_speed)
			eq(rec.lane, 0)
	eq(ok, 200, "empty lane always fits")
	# Nothing in lane 2 (95 km/h flow) can be 140 km/h fast... the draw still succeeds for
	# fast profiles, but flow speed is the lane's: the director only asks when the lane is faster.
	# A slow player just ahead in the lane blocks it (IDM gap with the closing speed).
	c.player.s = 60.0
	c.player.d = c.road.lane_center_d(0, 60.0)
	c.player.v = Units.kmh_to_mps(60.0)
	check(not flow.plan_single(c, 0.0, 0, min_speed, rec), "too close behind a slow player")
	# ...but the next lane over is fine.
	check(flow.plan_single(c, 0.0, 1, 0.0, rec), "adjacent lane free")
	# A live car right behind the spawn point blocks it too.
	c.player.s = -INF
	var j := c.traffic.allocate()
	c.traffic.s[j] = -10.0
	c.traffic.lane[j] = 0
	c.traffic.target_lane[j] = 0
	c.traffic.v[j] = Units.kmh_to_mps(150.0)
	c.traffic.length[j] = 4.6
	c.traffic.profile_id[j] = reg.profile_index(&"aggressive")
	check(not flow.plan_single(c, 0.0, 0, min_speed, rec), "too close ahead of a live car")


func test_draw_into_allocates_nothing() -> void:
	var flow := _flow()
	var c := _ctx(SEED, 8)
	var rec := SpawnSource.Record.new()
	flow.draw_into(c, c.rng, 0, LANES, 0.0, rec)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 500:
		flow.draw_into(c, c.rng, i % LANES, LANES, 0.0, rec)
		rec.s = float(i)
		flow.fits_between_neighbors_into(c, rec)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before)


# ---------------------------------------------------------------- Determinism, Daily

func test_deterministic_per_seed() -> void:
	var a := _hash(_run(_flow(), _ctx(SEED, 6), 5.0))
	var b := _hash(_run(_flow(), _ctx(SEED, 6), 5.0))
	var other := _hash(_run(_flow(), _ctx(SEED + 1, 6), 5.0))
	eq(a, b, "same seed, same plan")
	ne(a, other, "different seeds differ")


func test_rerolls_draw_new_numbers() -> void:
	# A re-roll calls plan_batch again on the same range: new draws from the same stream.
	var flow := _flow()
	var c := _ctx(SEED, 4)
	var first: Array[SpawnSource.Record] = []
	var second: Array[SpawnSource.Record] = []
	flow.plan_batch(c, 0.0, 300.0, first)
	flow.plan_batch(c, 0.0, 300.0, second)
	ne(_hash(first), _hash(second))


func test_daily_is_flow_seeded_by_date() -> void:
	var day := RunContext.daily(2026, 9, 28, tuning)
	var src := SpawnSources.for_run(day, reg.profiles, reg.types)
	check(src is SpawnSources.Daily, "Daily Drive uses the Daily source")
	eq(src.source_id(), &"daily")
	eq(SpawnSources.for_run(RunContext.new(SEED, RunContext.MODE_JOURNEY, tuning), reg.profiles, reg.types).source_id(), &"flow")
	var h1 := _hash(_run(src, _daily_ctx(2026, 9, 28), 3.0))
	var h2 := _hash(_run(SpawnSources.for_run(day, reg.profiles, reg.types), _daily_ctx(2026, 9, 28), 3.0))
	var h3 := _hash(_run(src, _daily_ctx(2026, 9, 29), 3.0))
	eq(h1, h2, "same date, same traffic")
	ne(h1, h3, "another date differs")


func _daily_ctx(y: int, m: int, d: int) -> SpawnSource.Context:
	var c := _ctx(0, 3)
	c.run = RunContext.daily(y, m, d, tuning)
	c.rng = c.run.rng_traffic.derive(&"flow")
	return c


# ---------------------------------------------------------------- Tuning (Spawning group)

func test_spawning_tuning_loaded_from_data() -> void:
	var tt := tuning.traffic
	near(tt.spawn_fog_margin_m, 30.0, 0.0)
	near(tt.spawn_despawn_ahead_margin_m, 100.0, 0.0)
	eq(tt.spawn_behind_lane_count, 2)
	near(tt.spawn_behind_speed_margin_kmh, 10.0, 0.0)
	near(tt.spawn_ghost_margin_long_m, 20.0, 0.0)
	near(tt.spawn_ghost_margin_lat_m, 1.0, 0.0)
	near(tt.spawn_lane_speed_tolerance_kmh, 10.0, 0.0)
	eq(tt.spawn_keep_right_lane_count, 1)
	eq(tt.spawn_profile_ids.size(), tt.spawn_profile_weights_pct.size(), "one weight per profile id")
	check(not tt.spawn_profile_ids.has(tt.spawn_aggressive_profile_id), "aggressive share comes from the director")
	check(tt.spawn_profile_ids.has(tt.spawn_hesitant_profile_id))
	var total := 0.0
	for w in tt.spawn_profile_weights_pct:
		total += w
	near(total, 100.0, 1e-9, "weights are percentages of the non-aggressive traffic")
	eq(tt.spawn_palette_fallback_count, 8)
	near(tt.opposite_lane_speed_step_kmh, 15.0, 0.0)
	near(tt.opposite_spacing_jitter_pct, 50.0, 0.0)
	near(tt.opposite_recycle_behind_m, 30.0, 0.0)
	# Every spec driver type is covered by the mix (ids as the registry will name them).
	for p in reg.profiles:
		check(tt.spawn_profile_ids.has(p.id) or p.id == tt.spawn_aggressive_profile_id, "%s in the mix" % p.id)
