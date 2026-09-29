class_name SpawnSources
extends RefCounted
## Built-in SpawnSources: Flow (the default) and Daily (Flow seeded by date). The third
## built-in, SetPiece, is SetPieceSource (set_piece_source.gd): it wraps Flow / Daily.
## Spec: Traffic → Spawning and the opposite carriageway ("at their lane's flow speed,
## with IDM-consistent gaps"); Traffic director (Flow, Daily, difficulty by leg);
## Fairness rule 7 (lane discipline: flow speeds rise to the left, slow profiles keep
## right); Driver types; Hooks to build in v1 (SpawnSource). See docs/SPAWNING.md.
##
##   var flow := SpawnSources.for_run(run, profiles, types)   # Daily in Daily Drive mode
##
## `profiles` / `types` are the traffic registry's lists in its stable order: the index
## in each array IS the profile_id / type_id written into records.


## Flow in Journey mode, Daily in Daily Drive mode.
static func for_run(run: RunContext, profiles: Array[DriverProfile], types: Array[VehicleType]) -> Flow:
	if run.mode == RunContext.MODE_DAILY:
		return Daily.new(run.tuning.traffic, profiles, types)
	return Flow.new(run.tuning.traffic, profiles, types)


## IDM desired gap s* (bumper to bumper) of a follower at v closing on its leader at
## dv = v - v_leader: s0 + max(0, vT + v dv / (2 sqrt(a b))). At this gap the IDM
## interaction term is 1, so a vehicle placed at >= s* never starts braking harder
## than its comfortable deceleration; at dv = 0 it is the equilibrium spacing floor.
static func idm_desired_gap(v: float, dv: float, headway_s: float, s0_m: float, a_max: float, b_comfort: float) -> float:
	return s0_m + maxf(0.0, v * headway_s + v * dv / (2.0 * sqrt(a_max * b_comfort)))


## True when live vehicle `i` of `ts` occupies `lane` for spawn-gap purposes (at its
## own s): its lane or target lane is `lane`, or its lateral span overlaps the lane.
## The span is its body, widened while a lateral move is signaled or running to the
## target lane's center and half a lane toward its blinker. So a car signaling or
## moving into a lane already occupies it, a motorbike splitting lanes (riding the
## boundary, `lane` = the lane it came from) occupies both lanes, and so does one
## signaling a split. Allocation-free (spawn-gap checks run in the tick for behind
## spawns).
static func occupies_lane(ts: TrafficState, i: int, lane: int, road: RoadPath) -> bool:
	if ts.lane[i] == lane or ts.target_lane[i] == lane:
		return true
	var s := ts.s[i]
	var d := ts.d[i]
	var hw := ts.width[i] * 0.5
	var lo := d - hw
	var hi := d + hw
	if ts.lc_state[i] != TrafficState.LaneChange.NONE:
		var half_lane := road.lane_width(s) * 0.5
		var tc := road.lane_center_d(ts.target_lane[i], s)
		lo = minf(lo, tc - hw)
		hi = maxf(hi, tc + hw)
		if (ts.flags[i] & TrafficState.FLAG_BLINKER_LEFT) != 0:
			lo = minf(lo, d - half_lane - hw)
		if (ts.flags[i] & TrafficState.FLAG_BLINKER_RIGHT) != 0:
			hi = maxf(hi, d + half_lane + hw)
	var c := road.lane_center_d(lane, s)
	var half := road.lane_width(s) * 0.5
	return lo < c + half and hi > c - half


## Default traffic: per-lane renewal process at the leg's density, lane-conditioned
## driver mix, lane flow speed, IDM-consistent gaps to every neighbor (planned or live).
class Flow:
	extends SpawnSource

	var tuning: TrafficTuning
	var profiles: Array[DriverProfile]
	var types: Array[VehicleType]
	## Player box, for the behind-spawn gap check (set by the director).
	var player_length_m: float = 0.0
	var player_width_m: float = 0.0
	## Multiplies every profile's IDM time headway in the spawn gaps (s*), matching
	## TrafficSim.set_headway_scale (plan D11: late legs drive closer). Set by the
	## director from DirectorTuning.headway_scale(leg).
	var headway_scale: float = 1.0
	## Intensity waves and blind caps (WP6.2): when set, each lane and position is planned
	## at ctx.density_per_km_lane x shaper.density_mult(lane flow speed, s) /
	## shaper.ref_mult (_plan_lane), so the density the player meets follows
	## the director's wave in every lane (the meeting map, IntensityWaves). Null: flat at
	## ctx.density_per_km_lane.
	var shaper: IntensityWaves
	## Lane closures (WP6.2): a sim with closure_ahead(lane, s) -> float (TrafficSim);
	## null = only the road's lane counts and edges (lane_open_for_spawn).
	var lane_guard: Object

	var _n: int = 0
	# Per profile, SI.
	var _p_vmin := PackedFloat64Array()
	var _p_vmax := PackedFloat64Array()
	var _p_headway := PackedFloat64Array()
	var _p_s0 := PackedFloat64Array()
	var _p_a := PackedFloat64Array()
	var _p_b := PackedFloat64Array()
	var _p_weight := PackedFloat64Array()   ## base mix weight; 0 = never from Flow
	var _p_keep_right := PackedByteArray()
	var _p_min_leg := PackedInt32Array()
	var _p_types: Array[PackedInt32Array] = []   ## type ids that allow the profile
	var _aggressive: int = -1
	var _hesitant: int = -1
	var _racer: int = -1   ## plan D15
	var _p_left_lanes := PackedInt32Array()   ## spawn_left_lane_count (0 = any lane)
	# Per type.
	var _t_length := PackedFloat64Array()
	var _t_width := PackedFloat64Array()
	var _t_variants := PackedInt32Array()
	# Scratch (allocation-free draws).
	var _w := PackedFloat64Array()

	func _init(traffic_tuning: TrafficTuning, driver_profiles: Array[DriverProfile], vehicle_types: Array[VehicleType]) -> void:
		tuning = traffic_tuning
		profiles = driver_profiles
		types = vehicle_types
		_n = profiles.size()
		for t in types:
			_t_length.append(t.length_m)
			_t_width.append(t.width_m)
			_t_variants.append(t.model_scene_paths.size())
		for p in _n:
			var prof := profiles[p]
			_p_vmin.append(prof.desired_speed_min_mps())
			_p_vmax.append(prof.desired_speed_max_mps())
			_p_headway.append(prof.idm_headway_s)
			_p_s0.append(prof.idm_s0_m)
			_p_a.append(prof.idm_a_max_mps2)
			_p_b.append(prof.idm_b_comfort_mps2)
			_p_keep_right.append(1 if prof.keep_right else 0)
			_p_min_leg.append(prof.min_leg)
			var w := 0.0
			var k := tuning.spawn_profile_ids.find(prof.id)
			if k >= 0 and k < tuning.spawn_profile_weights_pct.size():
				w = Units.pct_to_frac(tuning.spawn_profile_weights_pct[k])
			if prof.id == tuning.spawn_aggressive_profile_id:
				_aggressive = p
				w = 0.0
			if prof.id == tuning.spawn_hesitant_profile_id:
				_hesitant = p
			if prof.id == tuning.spawn_racer_profile_id:
				_racer = p
				w = 0.0
			_p_left_lanes.append(prof.spawn_left_lane_count)
			_p_weight.append(w)
			var allowed := PackedInt32Array()
			for t in types.size():
				if types[t].allowed_profiles.has(prof.id):
					allowed.append(t)
			_p_types.append(allowed)
		_w.resize(_n)

	func source_id() -> StringName:
		return &"flow"

	## Index of the profile with this id in `profiles` (-1 when absent).
	func profile_index(id: StringName) -> int:
		for p in _n:
			if profiles[p].id == id:
				return p
		return -1

	func length_of(type_id: int) -> float:
		return _t_length[type_id]

	func width_of(type_id: int) -> float:
		return _t_width[type_id]

	## s* of profile `p` following at v with closing speed dv (see idm_desired_gap).
	func desired_gap(p: int, v: float, dv: float) -> float:
		return SpawnSources.idm_desired_gap(v, dv, _p_headway[p] * headway_scale, _p_s0[p], _p_a[p], _p_b[p])

	## Minimum center-to-center spacing from a follower (profile pf, speed vf, length lf)
	## to a leader (speed vl, length ll).
	func min_spacing(pf: int, vf: float, lf: float, vl: float, ll: float) -> float:
		return (lf + ll) * 0.5 + desired_gap(pf, vf, vf - vl)

	# ------------------------------------------------------------ Batches (director rate)

	func plan_batch(ctx: SpawnSource.Context, s_from: float, s_to: float, out_spawns: Array[SpawnSource.Record]) -> void:
		if ctx.density_per_km_lane <= 0.0 or s_to <= s_from:
			return
		var lanes := ctx.road.lane_count(s_from)
		var spacing := Units.M_PER_KM / ctx.density_per_km_lane
		for lane in lanes:
			_plan_lane(ctx, lane, lanes, s_from, s_to, spacing, out_spawns)

	## One lane as a renewal process: each vehicle sits its minimum IDM spacing plus a
	## uniform extra (mean = the target spacing, 1000 / density) ahead of the previous
	## one. Live traffic occupying the lane (occupies_lane: its lane, a lane change into
	## it, a lane split over it) acts as renewal points, so the lane keeps its density
	## and every new vehicle keeps s* to both neighbors.
	##
	## With a shaper (intensity waves, WP6.2) each spacing is the wave's where the next
	## vehicle will be (1000 / (ctx density x density_mult / ref_mult), taken half a
	## spacing on from the last one), and a vehicle goes between two live ones only where
	## the wave is at least shaper.fill_min_mult(): traffic of earlier batches that
	## drove into this one keeps its gaps in breathers and blind windows (the batches
	## planned over them do not fill them up), while builds and peaks are kept full as
	## IDM stretches their lanes. Where the wave asks for more than s* allows (late-leg
	## peaks), IDM's s* wins.
	func _plan_lane(ctx: SpawnSource.Context, lane: int, lanes: int, s_from: float, s_to: float,
			spacing: float, out: Array[SpawnSource.Record]) -> void:
		var shaped := shaper != null and shaper.ref_mult > 0.0
		var ts := ctx.traffic
		var live := _live_in_lane(ts, lane, ctx.road)
		var k := 0
		var has_prev := false
		var prev_s := 0.0
		var prev_len := 0.0
		var prev_v := 0.0
		var prev_p := 0
		while k < live.size() and ts.s[live[k]] < s_from:
			var j := live[k]
			has_prev = true
			prev_s = ts.s[j]
			prev_len = ts.length[j]
			prev_v = ts.v[j]
			prev_p = ts.profile_id[j]
			k += 1
		var v_lane := tuning.lane_flow_speed_mps(lane, lanes)
		var flat := spacing
		var first := true
		var rec := SpawnSource.Record.new()
		while true:
			if not draw_into(ctx, ctx.rng, lane, lanes, 0.0, rec):
				return
			var ln := _t_length[rec.type_id]
			if shaped:
				var at := prev_s if has_prev and prev_s > s_from else s_from
				spacing = _shaped_spacing(v_lane, at + _shaped_spacing(v_lane, at, flat) * 0.5, flat)
				if is_inf(spacing):
					return
			var c := s_from + ctx.rng.unit() * spacing
			if has_prev:
				var m := min_spacing(prev_p, prev_v, prev_len, rec.v, ln)
				var renewal := prev_s + m + ctx.rng.unit() * 2.0 * maxf(0.0, spacing - m)
				# A previous vehicle long gone behind s_from: restart at a random phase.
				c = renewal if (not first or renewal >= s_from) else maxf(c, prev_s + m)
			if c >= s_to:
				return
			first = false
			if k < live.size():
				var j := live[k]
				var fits := ts.s[j] - c >= min_spacing(rec.profile_id, rec.v, ln, ts.v[j], ts.length[j])
				if fits and shaped:
					fits = shaper.density_mult(v_lane, c) >= shaper.fill_min_mult()
				if not fits:
					# Doesn't fit before the next live vehicle: renew from it instead.
					has_prev = true
					prev_s = ts.s[j]
					prev_len = ts.length[j]
					prev_v = ts.v[j]
					prev_p = ts.profile_id[j]
					k += 1
					continue
			has_prev = true
			prev_s = c
			prev_len = ln
			prev_v = rec.v
			prev_p = rec.profile_id
			if not lane_open_for_spawn(ctx.road, lane, c):
				continue   # the lane ends or closes here (taper): keep the rhythm, place nothing
			rec.s = c
			out.append(rec)
			rec = SpawnSource.Record.new()

	## Target spacing at s for a lane at v_lane: `flat` (the context density's) x
	## ref_mult / density_mult (the shaper's wave and blind caps there). INF: no traffic.
	func _shaped_spacing(v_lane: float, s: float, flat: float) -> float:
		var m := shaper.density_mult(v_lane, s)
		return flat * shaper.ref_mult / m if m > 0.0 else INF

	## True when a vehicle may spawn at s in `lane` (WP6.2, lane closures): the lane
	## exists there and merge_spawn_clear_m on (a lane that won't exist when the vehicle
	## gets there is not used), the road's right edge is not cutting into it (a taper),
	## and the sim knows no closure of it within merge_spawn_clear_m ahead.
	## Allocation-free.
	func lane_open_for_spawn(road: RoadPath, lane: int, s: float) -> bool:
		var clear := tuning.merge_spawn_clear_m
		if lane >= road.lane_count(s) or lane >= road.lane_count(s + clear):
			return false
		# Inside a taper the right edge cuts into the lane (the sim's closures cover the
		# taper exactly; this half-lane test also covers roads fed to a guard-less Flow).
		if road.lanes_right_edge_d(s) - road.lane_center_d(lane, s) < road.lane_width(s) * 0.5 * 0.5:
			return false
		if lane_guard != null and float(lane_guard.call(&"closure_ahead", lane, s)) < clear:
			return false
		return true

	## Live slots occupying `lane` (SpawnSources.occupies_lane), sorted by s.
	func _live_in_lane(ts: TrafficState, lane: int, road: RoadPath) -> Array[int]:
		var out: Array[int] = []
		if ts == null:
			return out
		for i in ts.capacity:
			if ts.active[i] == 1 and SpawnSources.occupies_lane(ts, i, lane, road):
				out.append(i)
		out.sort_custom(func(a: int, b: int) -> bool: return ts.s[a] < ts.s[b])
		return out

	# ------------------------------------------------------------ Single spawns (allocation-free)

	## One vehicle at `s` in `lane`, at least `min_speed` fast (behind spawns). False when
	## no profile fits or it would sit closer than s* to a live neighbor or the player.
	## Allocation-free; draws from ctx.rng.
	func plan_single(ctx: SpawnSource.Context, s: float, lane: int, min_speed: float, rec: SpawnSource.Record) -> bool:
		var lanes := ctx.road.lane_count(s)
		if lane >= lanes or not lane_open_for_spawn(ctx.road, lane, s):
			return false
		if not draw_into(ctx, ctx.rng, lane, lanes, min_speed, rec):
			return false
		rec.s = s
		return fits_between_neighbors_into(ctx, rec)

	## True when `rec` (s, lane, v, type, profile set) keeps s* (closing speed included)
	## to its nearest live leader and follower occupying its lane (occupies_lane: lane
	## changers and lane-splitting bikes count), and to the player when the player
	## overlaps the lane.
	## Allocation-free.
	func fits_between_neighbors_into(ctx: SpawnSource.Context, rec: SpawnSource.Record) -> bool:
		var ts := ctx.traffic
		var ln := _t_length[rec.type_id]
		if ts != null:
			var lead := -1
			var follow := -1
			for i in ts.capacity:
				if ts.active[i] == 0 or not SpawnSources.occupies_lane(ts, i, rec.lane, ctx.road):
					continue
				if ts.s[i] >= rec.s:
					if lead < 0 or ts.s[i] < ts.s[lead]:
						lead = i
				elif follow < 0 or ts.s[i] > ts.s[follow]:
					follow = i
			if lead >= 0 and ts.s[lead] - rec.s < min_spacing(rec.profile_id, rec.v, ln, ts.v[lead], ts.length[lead]):
				return false
			if follow >= 0 and rec.s - ts.s[follow] < min_spacing(ts.profile_id[follow], ts.v[follow], ts.length[follow], rec.v, ln):
				return false
		var pl := ctx.player
		if pl != null and _player_in_lane(ctx, rec.lane, rec.s):
			if pl.s >= rec.s:
				# Player leads: the new car must be able to follow it comfortably.
				if pl.s - rec.s < min_spacing(rec.profile_id, rec.v, ln, pl.v, player_length_m):
					return false
			# Player follows: its own gap is the player's business; use the new car's
			# params as a stand-in so it never spawns right on the player's bumper.
			elif rec.s - pl.s < min_spacing(rec.profile_id, pl.v, player_length_m, rec.v, ln):
				return false
		return true

	func _player_in_lane(ctx: SpawnSource.Context, lane: int, s: float) -> bool:
		var half := (ctx.road.lane_width(s) + player_width_m) * 0.5
		return absf(ctx.player.d - ctx.road.lane_center_d(lane, s)) < half

	# ------------------------------------------------------------ Vehicle draw (allocation-free)

	## One vehicle of profile `p` for `lane` into `rec` (everything but s): v0 drawn in the
	## profile's range, v = v0, a type allowing the profile, a model variant, a palette
	## color, no flags. For set pieces (their own mix). False if the profile has no type.
	## Allocation-free; all randomness from `rng`.
	func draw_profile_into(ctx: SpawnSource.Context, rng: Rng, p: int, lane: int, rec: SpawnSource.Record) -> bool:
		if p < 0 or p >= _n or _p_types[p].is_empty():
			return false
		rec.profile_id = p
		rec.lane = lane
		rec.d = NAN
		rec.v0 = rng.float_range(_p_vmin[p], _p_vmax[p])
		rec.v = rec.v0
		var allowed := _p_types[p]
		var t := allowed[rng.int_range(0, allowed.size() - 1)]
		rec.type_id = t
		rec.model_variant = rng.int_range(0, _t_variants[t] - 1) if _t_variants[t] > 1 else 0
		rec.color_index = rng.int_range(0, _palette_count(ctx) - 1)
		rec.flags = 0
		rec.set_piece = &""
		return true

	## Draws one vehicle for `lane` of `lanes` into `rec` (everything but s): driver
	## profile from the lane-conditioned mix, desired speed within the profile's range
	## and the lane's band (jittered), v = the lane flow speed, a vehicle type that
	## allows the profile, a model variant and a palette color. False if nothing fits.
	## Allocation-free; all randomness from `rng`.
	##
	## The mix (plan D15): the racer takes _racer_share(ctx) and the aggressive profile
	## ctx.aggressive_share of every lane each may use; the others share the rest by
	## their weights (Hesitant only if ctx.hesitant_allowed). A lane only the fast
	## profiles fit (its flow is above every other profile's top speed) is all fast, in
	## proportion to their shares.
	func draw_into(ctx: SpawnSource.Context, rng: Rng, lane: int, lanes: int, min_speed: float, rec: SpawnSource.Record) -> bool:
		var flow_v := tuning.lane_flow_speed_mps(lane, lanes)
		var floor_v := maxf(flow_v - Units.kmh_to_mps(tuning.spawn_lane_speed_tolerance_kmh), min_speed)
		var right_first := lanes - tuning.spawn_keep_right_lane_count
		var others := 0.0
		var aggressive_ok := false
		var racer_ok := false
		for p in _n:
			_w[p] = 0.0
			if not _eligible(ctx, p, lane, lanes, right_first, floor_v):
				continue
			if p == _aggressive:
				aggressive_ok = true
			elif p == _racer:
				racer_ok = true
			else:
				_w[p] = _p_weight[p]
				others += _w[p]
		var agg := clampf(ctx.aggressive_share, 0.0, 1.0) if aggressive_ok else 0.0
		var rac := clampf(_racer_share(ctx), 0.0, 1.0) if racer_ok else 0.0
		if agg + rac > 1.0:
			var k := 1.0 / (agg + rac)
			agg *= k
			rac *= k
		if others <= 0.0:
			if not (aggressive_ok or racer_ok):
				return false
			if agg + rac <= 0.0:
				agg = 1.0 if aggressive_ok else 0.0
				rac = 1.0 - agg
			else:
				var k := 1.0 / (agg + rac)
				agg *= k
				rac *= k
		var fast := agg + rac
		var r := rng.unit()
		var p := _racer
		if r >= rac:
			p = _aggressive
			if r >= fast:
				p = _pick((r - fast) / (1.0 - fast) * others)
		rec.profile_id = p
		rec.lane = lane
		rec.d = NAN
		rec.v0 = rng.float_range(maxf(_p_vmin[p], floor_v), _p_vmax[p])
		var jitter := tuning.spawn_v0_jitter_frac()
		if jitter > 0.0:
			# Per-car jitter (plan D15): spreads a lane whose band clipped the profile's range.
			rec.v0 = clampf(rec.v0 * (1.0 + jitter * (2.0 * rng.unit() - 1.0)), maxf(_p_vmin[p], min_speed), _p_vmax[p])
		rec.v = flow_v
		var allowed := _p_types[p]
		var t := allowed[rng.int_range(0, allowed.size() - 1)]
		rec.type_id = t
		rec.model_variant = rng.int_range(0, _t_variants[t] - 1) if _t_variants[t] > 1 else 0
		rec.color_index = rng.int_range(0, _palette_count(ctx) - 1)
		rec.flags = 0
		rec.set_piece = &""
		return true

	func _eligible(ctx: SpawnSource.Context, p: int, lane: int, lanes: int, right_first: int, floor_v: float) -> bool:
		if p != _aggressive and p != _racer and _p_weight[p] <= 0.0:
			return false
		if _p_min_leg[p] > ctx.leg:
			return false
		if p == _hesitant and not ctx.hesitant_allowed:
			return false
		if _p_vmax[p] < floor_v:
			return false
		if _p_keep_right[p] == 1 and lane < right_first:
			return false
		# Fast-lane profiles (Racer): the leftmost N lanes, never the rightmost one.
		if _p_left_lanes[p] > 0 and (lane >= _p_left_lanes[p] or lane >= lanes - 1):
			return false
		return not _p_types[p].is_empty()

	## The racer's share on the context's leg (plan D15): DirectorTuning.racer_share_frac
	## of the run's tuning; 0 without a racer profile or a run.
	func _racer_share(ctx: SpawnSource.Context) -> float:
		if _racer < 0 or ctx.run == null or ctx.run.tuning == null or ctx.run.tuning.director == null:
			return 0.0
		return ctx.run.tuning.director.racer_share_frac(ctx.leg)

	## Profile whose cumulative weight covers x (x in [0, sum of _w)).
	func _pick(x: float) -> int:
		var last := -1
		for p in _n:
			if _w[p] <= 0.0:
				continue
			last = p
			x -= _w[p]
			if x < 0.0:
				return p
		return last

	func _palette_count(ctx: SpawnSource.Context) -> int:
		if ctx.biome != null and ctx.biome.traffic_palette.size() > 0:
			return ctx.biome.traffic_palette.size()
		return maxi(tuning.spawn_palette_fallback_count, 1)


## Daily Drive: Flow on a date-seeded stream. The date seeding lives in the run context
## (RunContext.daily -> run.rng_traffic), so everyone on the same UTC date gets the same
## traffic for the same player trace.
class Daily:
	extends Flow

	func _init(traffic_tuning: TrafficTuning, driver_profiles: Array[DriverProfile], vehicle_types: Array[VehicleType]) -> void:
		super(traffic_tuning, driver_profiles, vehicle_types)

	func source_id() -> StringName:
		return &"daily"
