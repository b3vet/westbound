extends WBTest
## The traffic director's intensity waves, difficulty by leg and blind-window cap
## (WP6.2). Spec: Traffic → Traffic director ("Intensity waves. Tension and release in
## cycles of 45-90 s: build, peak (often a set piece), then a 10-15 s breather. Every
## leg ends with a short breather before the checkpoint."; "Difficulty by leg: density
## rises from 8 to 16 [plan D11: 18] vehicles per km per lane ...; the aggressive share
## rises from 5% to 20%; Hesitant drivers enter from leg 3; set piece variety grows";
## "Night: same density as day for that leg"); Fairness rule 6 ("Within 150 m after a
## blind crest or bend, the director caps density at 60% and allows no set pieces").
## docs/SPAWNING.md "Intensity waves".

const SEED := 620201
const DT := 1.0 / 120.0
const PLAYER_LEN := 4.5
const PLAYER_WIDTH := 1.9
const LANES := 3
const EPS := 1e-6
## Procedural roads whose first blind crest comes within 4 km (found with a probe:
## crests come every 5-7 km; bends rarely hide more than the sight distance), and the
## coarse step of the blind test (the fake sim and the director are dt-exact enough).
const BLIND_SEEDS: Array[int] = [18, 20, 24, 21, 28, 6, 25, 14]
const COARSE_DT := 1.0 / 30.0

var reg: SpawnFixtureRegistry
var tuning: Tuning
var pace_ref: float

# Drive rig (fake sim: vehicles hold their speed, so the meeting map is exact).
var road: RoadPath
var sim: FakeTrafficSim
var dir: TrafficDirector
var player: VehicleState


func before_all() -> void:
	reg = SpawnFixtureRegistry.new()
	tuning = Tuning.load_default()
	pace_ref = Units.kmh_to_mps(tuning.director.wave_reference_pace_kmh)


func _waves(seed_value: int, on_road: RoadPath, to_m: float) -> IntensityWaves:
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	var w := IntensityWaves.new(tuning.director, tuning.traffic, tuning.legs, run.rng_traffic.derive(IntensityWaves.STREAM))
	w.reset(0.0, pace_ref)
	w.plan_to(on_road, to_m)
	return w


func _rig(seed_value: int, on_road: RoadPath, v_kmh: float, leg: int, t: Tuning = null) -> void:
	var tun := t if t != null else tuning
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tun)
	road = on_road
	sim = FakeTrafficSim.new(tun.traffic.max_active_vehicles, road, reg.types)
	dir = TrafficDirector.new(run, road, sim, reg.profiles, reg.types, PLAYER_LEN, PLAYER_WIDTH)
	player = VehicleState.new()
	player.s = 0.0
	player.d = road.lane_center_d(1, 0.0)
	player.v = Units.kmh_to_mps(v_kmh)
	dir.set_leg(leg, 0.0)
	dir.reset(player)


func _step(dt: float = DT) -> void:
	player.s += player.v * dt
	sim.step(dt)
	dir.step(dt, player)


func _procedural(seed_value: int) -> ProceduralRoadPath:
	return ProceduralRoadPath.new(RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning))


# ---------------------------------------------------------------- The curve

func test_cycles_last_45_to_90_s_with_10_to_15_s_breathers() -> void:
	var d := tuning.director
	for r: RoadPath in [StraightRoadPath.new(LANES, tuning.road), _procedural(SEED)]:
		var w := _waves(SEED, r, tuning.legs.leg_length_m() * 10.0)
		var n := w.seg_x0.size()
		gt(n, 20, "ten legs of waves")
		var cycles := 0
		var k := 0
		while k + 2 < n and w.seg_x1[k + 2] <= w.planned_to:
			eq(w.seg_phase[k], IntensityWaves.Phase.BUILD, "a cycle starts with a build")
			eq(w.seg_phase[k + 1], IntensityWaves.Phase.PEAK, "then the peak")
			eq(w.seg_phase[k + 2], IntensityWaves.Phase.BREATHER, "then a breather")
			var total := (w.seg_x1[k + 2] - w.seg_x0[k]) / pace_ref
			ge(total, d.wave_period_min_s - EPS, "cycle >= 45 s at the reference pace")
			le(total, d.wave_period_max_s + EPS, "cycle <= 90 s")
			var br := (w.seg_x1[k + 2] - w.seg_x0[k + 2]) / pace_ref
			ge(br, minf(d.breather_min_s, d.checkpoint_breather_min_s) - EPS, "breather >= 10 s")
			le(br, maxf(d.breather_max_s, d.checkpoint_breather_max_s) + EPS, "breather <= 15 s")
			var active := w.seg_x1[k + 1] - w.seg_x0[k]
			var peak := w.seg_x1[k + 1] - w.seg_x0[k + 1]
			ge(peak / active, Units.pct_to_frac(d.wave_peak_min_pct) - EPS, "peak share")
			le(peak / active, Units.pct_to_frac(d.wave_peak_max_pct) + EPS)
			near(w.seg_i0[k], d.wave_build_start_intensity, EPS, "a build rises from the start intensity")
			near(w.seg_i1[k], 1.0, EPS, "to the peak")
			near(w.seg_i0[k + 1], 1.0, EPS)
			near(w.seg_i0[k + 2], 0.0, EPS, "a breather is intensity 0")
			eq(w.seg_x0[k + 1], w.seg_x1[k], "contiguous")
			k += 3
			cycles += 1
		ge(cycles, 10, "every leg holds whole cycles")


func test_every_leg_ends_with_a_breather_at_its_checkpoint() -> void:
	var d := tuning.director
	var r := _procedural(SEED)
	var w := _waves(SEED, r, tuning.legs.leg_length_m() * 8.0)
	var found: Array[RoadFeature] = []
	r.features_in(0.0, w.planned_to, found)
	var cps := 0
	for f in found:
		if f.kind != RoadFeature.Kind.CHECKPOINT:
			continue
		cps += 1
		var k := w.segment_at(f.s_start - 1.0)
		eq(w.seg_phase[k], IntensityWaves.Phase.BREATHER, "a breather before checkpoint %d" % int(f.value))
		near(w.seg_x1[k], f.s_start, EPS, "ending exactly at the checkpoint")
		var br := (w.seg_x1[k] - w.seg_x0[k]) / pace_ref
		ge(br, d.checkpoint_breather_min_s - EPS)
		le(br, d.checkpoint_breather_max_s + EPS)
		eq(w.phase_at(f.s_start + 1.0), IntensityWaves.Phase.BUILD, "the next leg starts building")
		eq(w.phase_at(f.s_start - (br + 1.0) * pace_ref), IntensityWaves.Phase.PEAK, "right after its peak")
	ge(cps, 7, "checkpoints of the procedural road")


func test_curve_is_deterministic_by_seed() -> void:
	var a := _waves(SEED, StraightRoadPath.new(LANES, tuning.road), 30000.0)
	var b := _waves(SEED, StraightRoadPath.new(LANES, tuning.road), 30000.0)
	var c := _waves(SEED + 1, StraightRoadPath.new(LANES, tuning.road), 30000.0)
	eq(a.seg_x0, b.seg_x0, "same seed, same curve")
	eq(a.seg_u_chance, b.seg_u_chance, "same set-piece draws")
	ne(a.seg_x0, c.seg_x0, "another seed differs")


func test_density_multiplier_follows_the_intensity() -> void:
	var d := tuning.director
	var w := _waves(SEED, StraightRoadPath.new(LANES, tuning.road), 8000.0)
	near(d.wave_density_mult(0.0), Units.pct_to_frac(d.wave_breather_density_pct), EPS)
	near(d.wave_density_mult(1.0), Units.pct_to_frac(d.wave_peak_density_pct), EPS)
	for k in w.seg_x0.size():
		var mid := (w.seg_x0[k] + w.seg_x1[k]) * 0.5
		match w.seg_phase[k]:
			IntensityWaves.Phase.BREATHER:
				near(w.mult_at(mid), Units.pct_to_frac(d.wave_breather_density_pct), EPS, "breather density")
			IntensityWaves.Phase.PEAK:
				near(w.mult_at(mid), Units.pct_to_frac(d.wave_peak_density_pct), EPS, "peak density")
			IntensityWaves.Phase.BUILD:
				gt(w.mult_at(w.seg_x1[k] - 1.0), w.mult_at(w.seg_x0[k] + 1.0), "a build rises")
	# A cycle averages close to the leg's target.
	var sum := 0.0
	var n := 4000
	for i in n:
		sum += w.mult_at(7000.0 * (float(i) + 0.5) / float(n))
	near(sum / float(n), 1.0, 0.1, "the waves keep the leg's density on average")


func test_meeting_map() -> void:
	var w := _waves(SEED, StraightRoadPath.new(LANES, tuning.road), 12000.0)
	w.player_s = 1000.0
	w.pace = 50.0
	# A vehicle 800 m ahead at 30 m/s: met after 800 / 20 = 40 s, 2000 m on.
	near(w.meet_x(30.0, 1800.0), 3000.0, EPS)
	near(w.meet_x(30.0, 1000.0), 1000.0, EPS, "alongside: met now")
	# Faster than the player: the closing-speed floor, clamped to the lookahead.
	near(w.meet_x(60.0, 1800.0), 1000.0 + tuning.director.wave_meet_lookahead_m, EPS)
	w.observe_player(DT, 1001.0, 20.0)
	lt(w.pace, 50.0, "the pace follows the player, smoothed")
	gt(w.pace, 45.0)


# ---------------------------------------------------------------- Waves in traffic

func test_density_the_player_meets_follows_the_waves() -> void:
	# Constant 170 km/h past traffic that holds its lanes' speeds (fake sim), leg 4: the
	# vehicles the player passes per km driven, by the phase it is in when it passes
	# them. Planned: breather 50%, build 87.5-125%, peak 125% of the leg's density. (At
	# leg 8 peaks saturate: IDM gaps cap a lane near the target, docs/SPAWNING.md.)
	_rig(SEED, StraightRoadPath.new(LANES, tuning.road), 170.0, 4)
	var met := PackedFloat64Array([0.0, 0.0, 0.0])
	var driven := PackedFloat64Array([0.0, 0.0, 0.0])
	var seen := {}
	var dt := 1.0 / 60.0
	while player.s < 13000.0:
		_step(dt)
		if player.s < 1500.0:
			continue
		var ph := dir.waves.phase_at(player.s)
		driven[ph] += player.v * dt
		for i in sim.state.capacity:
			if sim.state.active[i] == 1 and sim.state.s[i] <= player.s and sim.state.s[i] > player.s - player.v * dt * 2.0:
				var vid := sim.state.vehicle_id[i]
				if not seen.has(vid):
					seen[vid] = true
					met[ph] += 1.0
	var per_km := PackedFloat64Array()
	for ph in 3:
		gt(driven[ph], 500.0, "driven in phase %d" % ph)
		per_km.append(met[ph] / driven[ph] * Units.M_PER_KM)
	print("      vehicles met per km: build %.1f, peak %.1f, breather %.1f" % [per_km[0], per_km[1], per_km[2]])
	gt(per_km[1], per_km[2] * 1.8, "peaks meet far more traffic than breathers (planned 125% vs 50%)")
	gt(per_km[1], per_km[0], "the build leads up to the peak")
	gt(per_km[0], per_km[2] * 1.4, "and starts well above the breather")


func test_gain_tracks_the_wave_shaped_target() -> void:
	# The density gain's target is the flat target x the waves in the window (what its
	# traffic was planned at), and the window delivers it on average.
	_rig(SEED, StraightRoadPath.new(LANES, tuning.road), 170.0, 4)
	var ratio_sum := 0.0
	var n := 0
	for k in roundi(150.0 / DT):
		_step()
		if dir._control_clock == 0.0 and player.s > 1000.0:
			var w := dir.waves.window_mult(LANES, tuning.director.density_window_behind_m,
				tuning.director.density_window_ahead_m)
			near(dir.window_target, dir.target_density_per_km_lane() * w, 1e-6, "the target is the flat one x the wave")
			ratio_sum += dir.window_density / dir.window_target
			n += 1
	print("      window / wave-shaped target %.3f" % (ratio_sum / float(n)))
	near(ratio_sum / float(n), 1.0, 0.15, "the window delivers the wave-shaped target")


# ---------------------------------------------------------------- Difficulty by leg

func test_difficulty_ramps_by_leg() -> void:
	var d := tuning.director
	_rig(SEED, StraightRoadPath.new(LANES, tuning.road), 150.0, 1)
	var prev_density := 0.0
	var prev_unlocked := 0
	for leg in range(1, 10):
		dir.set_leg(leg, player.s)
		var ctx := dir.ctx
		var u := clampf(float(leg - 1) / 7.0, 0.0, 1.0)
		near(dir.target_density_per_km_lane(), lerpf(8.0, d.density_last_per_km_lane, u), EPS, "leg %d density" % leg)
		near(ctx.aggressive_share, lerpf(0.05, 0.20, u), EPS, "leg %d aggressive share 5 -> 20%%" % leg)
		eq(ctx.hesitant_allowed, leg >= 3, "Hesitant from leg 3 (leg %d)" % leg)
		ge(dir.target_density_per_km_lane(), prev_density)
		ge(d.set_pieces_unlocked(leg), prev_unlocked, "set-piece variety never shrinks")
		prev_density = dir.target_density_per_km_lane()
		prev_unlocked = d.set_pieces_unlocked(leg)
	near(d.density_per_km_lane(8), 18.0, EPS, "plan D11: 18 at leg 8")
	near(d.density_per_km_lane(12), 18.0, EPS, "then holds")
	eq(d.set_pieces_unlocked(1), 1, "one kind on leg 1")
	gt(d.set_pieces_unlocked(8), d.set_pieces_unlocked(1), "more at leg 8")


func test_flow_mix_follows_the_leg() -> void:
	# Lane 1 draws (both may drive there): the aggressive share as ramped; no Hesitant
	# before leg 3.
	var p_aggr := reg.profile_index(&"aggressive")
	var p_hes := reg.profile_index(&"hesitant")
	_rig(SEED, StraightRoadPath.new(LANES, tuning.road), 150.0, 1)
	var rec := SpawnSource.Record.new()
	var rng := Rng.new(99)
	for leg: int in [1, 2, 3, 8]:
		dir.set_leg(leg, player.s)
		var aggr := 0
		var hes := 0
		var n := 4000
		for k in n:
			check(dir.flow.draw_into(dir.ctx, rng, 1, LANES, 0.0, rec))
			if rec.profile_id == p_aggr:
				aggr += 1
			if rec.profile_id == p_hes:
				hes += 1
		near(float(aggr) / float(n), dir.ctx.aggressive_share, 0.025, "leg %d aggressive share" % leg)
		if leg < 3:
			eq(hes, 0, "no Hesitant on leg %d" % leg)
		else:
			gt(hes, 0, "Hesitant on leg %d" % leg)


func test_night_keeps_the_leg_density() -> void:
	_rig(SEED, StraightRoadPath.new(LANES, tuning.road), 150.0, 5)
	var day := dir.ctx.density_per_km_lane
	var target := dir.target_density_per_km_lane()
	dir.set_night(true)
	dir.set_leg(5, player.s)
	eq(dir.ctx.density_per_km_lane, day, "same planned density at night")
	eq(dir.target_density_per_km_lane(), target)


# ---------------------------------------------------------------- Rule 6: blind crests and bends

## The blind features of the first `to_m` of a road, as [start, end] pairs.
static func _blind_features(r: RoadPath, to_m: float) -> PackedFloat64Array:
	r.ensure_generated_to(to_m)
	var found: Array[RoadFeature] = []
	r.features_in(0.0, to_m, found)
	var out := PackedFloat64Array()
	for f in found:
		if f.kind == RoadFeature.Kind.BLIND_CREST or f.kind == RoadFeature.Kind.BLIND_BEND:
			out.append(f.s_start)
			out.append(f.s_end)
	return out


func test_blind_windows_cap_density_on_real_roads() -> void:
	# Procedural roads (their own blind crests), the player at a constant 170 km/h past
	# traffic that holds its speed (fake sim), no set pieces: while the player drives a
	# blind crest [a, b], every vehicle in [player, b + 150 m] was planned at no more
	# than 60% of the leg's density, and the density there is ~60% of what the same
	# measure finds elsewhere.
	var w_m := tuning.director.blind_window_m
	var cap := Units.pct_to_frac(tuning.director.blind_density_cap_pct)
	var blind_sum := 0.0
	var blind_n := 0
	var other_sum := 0.0
	var other_n := 0
	var features := 0
	var over_cap := 0
	var inside := 0
	for seed_value in BLIND_SEEDS:
		var r := _procedural(seed_value)
		var bf := _blind_features(r, 4500.0)
		if bf.is_empty():
			continue
		features += 1
		_rig(seed_value, r, 170.0, 4, _no_pieces())
		while player.s < bf[1] + 100.0:
			_step(COARSE_DT)
			if player.s < 1200.0:
				continue
			var in_crest := player.s >= bf[0] and player.s <= bf[1]
			var hi := bf[1] + w_m if in_crest else player.s + w_m + 150.0
			var n := 0
			for i in sim.state.capacity:
				if sim.state.active[i] == 1 and sim.state.s[i] >= player.s and sim.state.s[i] <= hi:
					n += 1
					if in_crest:
						inside += 1
						# The meeting map is invariant for a vehicle holding its speed: its
						# multiplier now is the one it was planned at.
						if dir.waves.density_mult(sim.state.v[i], sim.state.s[i]) > cap + EPS:
							over_cap += 1
			var dens := float(n) / ((hi - player.s) / Units.M_PER_KM * float(road.lane_count(player.s)))
			if in_crest:
				blind_sum += dens
				blind_n += 1
			elif _clear_of(bf, player.s, w_m + 400.0):
				other_sum += dens
				other_n += 1
	var ratio := (blind_sum / float(blind_n)) / (other_sum / float(other_n))
	print("      %d blind crests driven: density in the blind window %.2f of elsewhere (cap %.2f); %d vehicle samples inside" % [
		features, ratio, cap, inside])
	ge(features, 6, "enough blind crests in the sample")
	gt(inside, 100, "traffic was there")
	eq(over_cap, 0, "every vehicle within 150 m after a blind crest was planned at <= 60%")
	le(ratio, cap * 1.15, "~60% of the density elsewhere")


static func _clear_of(bf: PackedFloat64Array, s: float, margin: float) -> bool:
	for j in range(0, bf.size(), 2):
		if s >= bf[j] - margin and s <= bf[j + 1] + margin:
			return false
	return true


func _no_pieces() -> Tuning:
	var t: Tuning = tuning.duplicate()
	t.director = tuning.director.duplicate() as DirectorTuning
	t.director.set_piece_chance_first_pct = 0.0
	t.director.set_piece_chance_last_pct = 0.0
	return t


func _every_peak() -> Tuning:
	var t: Tuning = tuning.duplicate()
	t.director = tuning.director.duplicate() as DirectorTuning
	t.director.set_piece_chance_first_pct = 100.0
	t.director.set_piece_chance_last_pct = 100.0
	return t


func test_no_set_pieces_in_blind_windows_or_at_checkpoints() -> void:
	# Procedural roads with blind crests, every wave peak asking for a set piece, the
	# player at a constant 170 km/h past traffic that holds its speed: while the player
	# drives a blind crest [a, b], no set-piece vehicle is in [player, b + 150 m]; and
	# where the player reaches a piece (its rear), it is clear of every checkpoint's
	# range.
	var w_m := tuning.director.blind_window_m
	var d := tuning.director
	var pieces := 0
	var hidden_bad := 0
	var cp_bad := 0
	for seed_value in BLIND_SEEDS:
		var r := _procedural(seed_value)
		var bf := _blind_features(r, 7000.0)
		var found: Array[RoadFeature] = []
		r.features_in(0.0, 7000.0, found)
		var cps := PackedFloat64Array()
		for f in found:
			if f.kind == RoadFeature.Kind.CHECKPOINT:
				cps.append(f.s_start)
		_rig(seed_value, r, 170.0, 4, _every_peak())
		var met := {}
		while player.s < 6500.0:
			_step(COARSE_DT)
			for inst in dir.set_pieces.instances:
				if inst.stage != SetPieceSource.Stage.RUNNING:
					continue
				if not met.has(inst.serial) and player.s >= inst.s_rear - inst.def.start_distance_m:
					met[inst.serial] = true
					pieces += 1
					for c in cps:
						if player.s > c - d.set_piece_checkpoint_clear_before_m and player.s < c + d.set_piece_checkpoint_clear_after_m:
							cp_bad += 1
				for j in range(0, bf.size(), 2):
					if player.s >= bf[j] and player.s <= bf[j + 1] and inst.s_front >= player.s \
							and inst.s_rear <= bf[j + 1] + w_m:
						hidden_bad += 1
	print("      %d set pieces met on %d roads" % [pieces, BLIND_SEEDS.size()])
	gt(pieces, 4, "pieces were met")
	eq(hidden_bad, 0, "none within 150 m after a blind crest while the player drives it")
	eq(cp_bad, 0, "none met at a checkpoint")


func test_no_set_piece_the_player_would_not_meet() -> void:
	# Every peak asks for a piece. A player at 120 km/h would take longer than
	# set_piece_meet_max_pct of approach_max_s to reach one: none spawns (the peaks are
	# missed). At 190 km/h pieces spawn, and every one is reached.
	var slow := _drive_pieces(120.0)
	eq(slow[0], 0, "no piece for a slow player")
	gt(slow[1], 0, "its peaks were missed")
	var fast := _drive_pieces(190.0)
	gt(fast[0], 1, "pieces for a fast player")
	eq(fast[2], 0, "none left unmet")
	ge(fast[3], fast[0] - fast[4], "every piece that ended was reached")


## [spawned, peaks missed, ended unmet, started, still live] over 6 km of a straight road.
func _drive_pieces(v_kmh: float) -> Array[int]:
	_rig(SEED, StraightRoadPath.new(LANES, tuning.road), v_kmh, 4, _every_peak())
	while player.s < 6000.0:
		_step(COARSE_DT)
	var sp := dir.set_pieces
	return [sp.spawned, dir.peaks_missed, sp.ended_unmet, sp.started, sp.active_count()]


func test_blind_check_in_the_meeting_map() -> void:
	var w := _waves(SEED, StraightRoadPath.new(LANES, tuning.road), 8000.0)
	w.blind_s0.append(3000.0)
	w.blind_s1.append(3100.0)
	w.player_s = 1000.0
	w.pace = 50.0
	var v := 30.0   # met at x = 1000 + (s - 1000) * 2.5
	# Capped while met in [3000, 3000 + (100 + 150) * 2.5] = [3000, 3625].
	check(not w.is_blind(v, 1000.0 + 1990.0 / 2.5), "met just before the crest")
	check(w.is_blind(v, 1000.0 + 2010.0 / 2.5), "met on the crest")
	check(w.is_blind(v, 1000.0 + 2600.0 / 2.5), "met within the window")
	check(not w.is_blind(v, 1000.0 + 2650.0 / 2.5), "met beyond it")
	le(w.density_mult(v, 1000.0 + 2300.0 / 2.5), Units.pct_to_frac(tuning.director.blind_density_cap_pct) + EPS)
