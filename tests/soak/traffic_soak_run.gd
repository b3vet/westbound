class_name TrafficSoakRun
extends RefCounted
## One run of the traffic soak (spec: Traffic → Tests (headless): "10,000 simulated km
## with a bot driver produce zero impossible windows and zero traffic-to-traffic
## collisions"; rule checks; determinism; logged metrics). See docs/SOAK.md.
##
## A run is self-contained and seeded only by its index, so its trace hash does not
## depend on which shard (process) runs it or on what ran before:
##   - the procedural road (lanes_default from TrafficTuning.soak_lane_counts), the real
##     TrafficRegistry, TrafficSim, TrafficDirector (Flow, behind spawns, despawn, cap,
##     ghost zone) and the opposite carriageway;
##   - a bot player as the sim's participant: per leg it weaves or keeps its lane, at a
##     target speed drawn from [soak_bot_min_kmh, soak_bot_max_kmh]. BOT_PASSABILITY (the
##     default, the gate): PassabilityBot drives passability's path (spec: "The same
##     module runs in tests with a bot driver"). BOT_WEAVE: the WP3.3 TrafficBotPlayer
##     (the metrics reference and the density survey, for comparable baselines);
##   - the director checks every committed batch with passability (WP6.1);
##   - legs 1..soak_run_legs of LegsTuning's leg length, each at its leg's density and
##     aggressive share (night from the second half);
##   - per tick: the independent TrafficRuleChecker (collisions, signal time, unsignaled
##     moves, no-ambush, the decel clamp, brake lights, rear-ends of the player); contacts
##     with the player go to sim.notify_hit like run.gd;
##   - every soak_window_check_interval_s: the ImpossibleWindowChecker;
##   - every trace_hash_interval_s: the trace hash of all vehicle states (both
##     carriageways) and the player;
##   - TrafficMetrics throughout; set pieces per leg (WP6.2) from the director's
##     SetPieceSource (pieces that got vehicles, counted in the leg they spawned);
##   - set-piece warnings (the director writes them to the run's event buffer) go to the
##     rule checker, which allows a deceleration beyond the clamp only to a set piece
##     warned >= 300 m ahead (rule 4).
##
##   var r := TrafficSoakRun.new(index, base_seed)
##   r.run_to_end()                 # or r.advance(seconds)
##   var d := r.result()            # counters, metrics accumulators, trace hash, timing

const DT := 1.0 / 120.0
const CAR_DIR := "res://data/cars/"
## Traffic within this distance ahead of the player is summarized for an impossible window.
const WINDOW_REPORT_AHEAD_M := 250.0
const WINDOW_REPORT_BEHIND_M := 10.0
const MAX_WINDOW_EXAMPLES := 6
## Lane-change state tags in window reports (index = TrafficState.LaneChange).
const LC_TAGS: Array[String] = ["", "/signaling", "/moving"]
## A run that has not finished after this many times its distance at the minimum
## bot speed stops (a stuck bot would otherwise hang the soak).
const TIMEOUT_FACTOR := 3.0
## Which bot drives (see the class doc).
const BOT_WEAVE := 0
const BOT_PASSABILITY := 1
## Pre-registered player cut-in rule for impossible windows (docs/SOAK.md, WP6.1): a
## window within CUT_IN_WINDOW_S of the player entering its lane, when it entered closer
## than CUT_IN_HEADWAY_S behind the vehicle ahead or with a gap the vehicle behind cannot
## brake away within at the traffic's deceleration clamp.
const CUT_IN_WINDOW_S := 2.0
const CUT_IN_HEADWAY_S := 0.8

var index: int
var seed_value: int
var lanes: int
var tuning: Tuning
var ctx: RunContext
var road: ProceduralRoadPath
var registry: TrafficRegistry
var car: CarDef
var sim: TrafficSim
var director: TrafficDirector
var bot: TrafficBotPlayer
## The passability bot (BOT_PASSABILITY), the same object as `bot`; null otherwise.
var pbot: PassabilityBot
var bot_kind: int
var params: VehicleParams
var checker: TrafficRuleChecker
var windows: ImpossibleWindowChecker
var metrics: TrafficMetrics
var events: ScoreEventBuffer

var leg_length_m: float
var legs: int
var run_m: float
var check_windows := true
var time := 0.0
var ticks := 0
var trace: int = TraceHash.SEED
var finished := false
var timed_out := false
var leg := 0
var peak_active := 0
var legs_weaving := 0
var wall_usec := 0

# Impossible windows.
var window_checks := 0
var impossible_checks := 0
var impossible_windows := 0
var impossible_player_induced := 0
var impossible_player_cut_in := 0
## Ticks with the player's body outside the driving lanes (a lane that ended: WP6.2 lane
## drops), the rule checker's tolerance. Reported, not gated (the player's own driving).
var player_offroad_ticks := 0
var window_examples: Array[Dictionary] = []

var _bot_rng: Rng
# The player's lane entries (the cut-in rule): lanes its body overlapped last tick, and
# the last entry's time, headway to the car ahead and the follower verdict.
var _entry_mask := 0
var _entry_t := -INF
var _entry_headway := INF
var _entry_follower_impossible := false
var _entry_lane := -1
static var _params_cache := {}
var _next_hash := 0.0
var _next_window := 0.0
var _in_window := false
var _completed := 0
var _max_time := 0.0
var _fixed_leg := 0
var _set_pieces_counted := 0
## Wall time spent in TrafficSim.step / TrafficDirector.step (tick cost, D7).
var sim_usec := 0
var director_usec := 0
## Ticks at the vehicle cap, and the sum of active counts (mean active = sum / ticks).
var ticks_at_cap := 0
var active_sum := 0


## `run_legs` / `leg_m` <= 0 use TrafficTuning.soak_run_legs / LegsTuning's leg length.
## `fixed_leg` > 0 drives every leg at that leg's density and mix (D7 reference runs).
## `biome` (WP6.2): the road follows that biome everywhere (BiomePlan.uniform: its lane
## count, curves, crests and tunnels with their lane drops), e.g. the canyon soak.
func _init(run_index: int, base_seed: int, run_legs: int = -1, leg_m: float = -1.0, base: Tuning = null,
		fixed_leg: int = 0, biome: BiomeDef = null, which_bot: int = BOT_PASSABILITY) -> void:
	index = run_index
	bot_kind = which_bot
	_fixed_leg = fixed_leg
	seed_value = Rng.derive_seed(base_seed, "soak_run_%d" % run_index)
	var b := base if base != null else Tuning.load_default()
	var counts := b.traffic.soak_lane_counts
	lanes = counts[run_index % counts.size()]
	tuning = b.duplicate() as Tuning
	tuning.road = b.road.duplicate() as RoadTuning
	tuning.road.lanes_default = lanes
	ctx = RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	legs = run_legs if run_legs > 0 else tuning.traffic.soak_run_legs
	leg_length_m = leg_m if leg_m > 0.0 else tuning.legs.leg_length_m()
	run_m = leg_length_m * float(legs)
	_max_time = TIMEOUT_FACTOR * run_m / Units.kmh_to_mps(tuning.traffic.soak_bot_min_kmh)
	road = ProceduralRoadPath.new(ctx)
	if biome != null:
		road.set_biome_plan(BiomePlan.uniform(biome, tuning.legs.leg_length_m()))
		lanes = road.lane_count(0.0)
	registry = TrafficRegistry.load_default(tuning.traffic)
	car = _car(run_index)
	params = _params_for(car, tuning)
	_bot_rng = ctx.rng_events.derive(&"soak_bot")
	var start_lane := _bot_rng.int_range(0, lanes - 1)
	var bot_seed := _bot_rng.int_range(1, 1 << 30)
	var v_start := Units.kmh_to_mps(tuning.traffic.soak_bot_min_kmh)
	if bot_kind == BOT_PASSABILITY:
		pbot = PassabilityBot.new(road, registry, tuning, car, params, start_lane, v_start, bot_seed)
		bot = pbot
	else:
		bot = TrafficBotPlayer.new(road, start_lane, v_start, TrafficBotPlayer.Mode.WEAVE, bot_seed)
	bot.length_m = car.length_m
	bot.width_m = car.width_m
	sim = TrafficSim.new(ctx, road, registry)
	sim.set_player_body(car.length_m, car.width_m)
	director = TrafficDirector.new(ctx, road, sim, registry.profiles, registry.types, car.length_m, car.width_m)
	director.events = events
	director.set_player_params(params)
	checker = TrafficRuleChecker.new(tuning, registry, road, car.length_m, car.width_m)
	checker.set_piece_of = director.set_pieces.instance_of
	windows = ImpossibleWindowChecker.new(tuning, registry, car)
	metrics = TrafficMetrics.new(tuning)
	events = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity)
	road.ensure_generated_to(director.ahead_distance() * 2.0)
	_start_leg(1)
	director.reset(bot.state)
	_next_hash = tuning.traffic.trace_hash_interval_s
	_next_window = tuning.traffic.soak_window_check_interval_s


## Runs until the bot has driven the run's distance (or the timeout).
func run_to_end() -> void:
	while not finished:
		advance(60.0)


## Simulates up to `seconds` more (stops early when the run is finished).
func advance(seconds: float) -> void:
	var t0 := Time.get_ticks_usec()
	var n := roundi(seconds / DT)
	for k in n:
		if finished:
			break
		tick()
	wall_usec += Time.get_ticks_usec() - t0


func tick() -> void:
	# CONTRACTS §4 order: controller + physics (the bot), traffic, collisions and hits,
	# then the director.
	bot.update(DT, sim.state)
	var u0 := Time.get_ticks_usec()
	sim.step(DT, bot.state, null, events)
	var u1 := Time.get_ticks_usec()
	checker.observe(time, sim.state, bot.state)
	if bot.state.d + bot.width_m * 0.5 > road.lanes_right_edge_d(bot.state.s) + TrafficRuleChecker.OFFROAD_TOL_M:
		player_offroad_ticks += 1
	for slot in checker.contacts_started:
		sim.notify_hit(slot)
	var u2 := Time.get_ticks_usec()
	director.step(DT, bot.state)
	director_usec += Time.get_ticks_usec() - u2
	sim_usec += u1 - u0
	for k in events.size():
		if events.kind[k] == SetPieceSource.KIND_WARNING:
			checker.note_set_piece_warning(events.points[k], sim.state, bot.state)
	active_sum += sim.state.count
	if sim.state.count >= tuning.traffic.max_active_vehicles:
		ticks_at_cap += 1
	events.clear()
	metrics.sample(DT, sim.state, bot.state, road)
	metrics.add_lane_changes(sim.stat_completed - _completed)
	_completed = sim.stat_completed
	if check_windows:
		_track_lane_entry()
	peak_active = maxi(peak_active, sim.state.count)
	time += DT
	ticks += 1
	if time >= _next_hash:
		_next_hash += tuning.traffic.trace_hash_interval_s
		trace = sim.state.hash_into(trace)
		trace = director.opposite.state.hash_into(trace)
		trace = bot.state.hash_into(trace)
	if check_windows and time >= _next_window:
		_next_window += tuning.traffic.soak_window_check_interval_s
		_check_window()
	if bot.state.s >= float(leg) * leg_length_m:
		if leg >= legs:
			_count_set_pieces()
			finished = true
		else:
			_start_leg(leg + 1)
	if time > _max_time:
		timed_out = true
		finished = true


func _start_leg(k: int) -> void:
	leg = k
	director.set_leg(_fixed_leg if _fixed_leg > 0 else k, bot.state.s)
	var night := 2 * k > legs
	director.set_night(night)
	sim.set_headlights(night)
	var t := tuning.traffic
	if pbot != null:
		pbot.set_headway_scale(tuning.director.headway_scale(_fixed_leg if _fixed_leg > 0 else k))
	bot.v_target = Units.kmh_to_mps(_bot_rng.float_range(t.soak_bot_min_kmh, t.soak_bot_max_kmh))
	if _bot_rng.chance(Units.pct_to_frac(t.soak_bot_weave_pct)):
		bot.set_weave(t.soak_bot_weave_min_s, t.soak_bot_weave_max_s)
		legs_weaving += 1
	else:
		bot.keep_lane()
	_count_set_pieces()
	metrics.add_legs(1)
	road.forget_before(bot.state.s - t.despawn_behind_m - director.ahead_distance())


## Set pieces spawned since the last call go to the metrics (set_pieces_per_leg).
func _count_set_pieces() -> void:
	metrics.set_pieces += director.set_pieces.spawned - _set_pieces_counted
	_set_pieces_counted = director.set_pieces.spawned


func _check_window() -> void:
	window_checks += 1
	if windows.is_passable(sim.state, bot.state, road):
		_in_window = false
		return
	impossible_checks += 1
	if _in_window:
		return
	_in_window = true
	impossible_windows += 1
	if windows.started_in_contact:
		impossible_player_induced += 1
	elif _is_player_cut_in():
		impossible_player_cut_in += 1
	if window_examples.size() < MAX_WINDOW_EXAMPLES:
		window_examples.append(_describe_window())


## Where and why: the traffic in each lane just ahead of the player.
func _describe_window() -> Dictionary:
	var ts := sim.state
	var ps := bot.state.s
	var min_v := tuning.scoring.min_speed_mps()
	var per_lane: Array[Dictionary] = []
	var slow_lanes := 0
	for l in lanes:
		var n := 0
		var vmin := INF
		var slow: Array[String] = []
		for i in ts.capacity:
			if ts.active[i] == 0 or ts.s[i] < ps - WINDOW_REPORT_BEHIND_M or ts.s[i] > ps + WINDOW_REPORT_AHEAD_M:
				continue
			if not SpawnSources.occupies_lane(ts, i, l, road):
				continue
			n += 1
			vmin = minf(vmin, ts.v[i])
			if ts.v[i] < min_v:
				slow.append("%s@%.0fm/%.0fkmh%s" % [registry.profiles[ts.profile_id[i]].id, ts.s[i] - ps,
					ts.v[i] / Units.kmh_to_mps(1.0), LC_TAGS[ts.lc_state[i]] if ts.target_lane[i] != ts.lane[i] \
					or ts.lc_state[i] != TrafficState.LaneChange.NONE else ""])
		if not slow.is_empty():
			slow_lanes += 1
		per_lane.append({"lane": l, "vehicles": n, "min_kmh": vmin / Units.kmh_to_mps(1.0) if n > 0 else -1.0,
			"slow": slow})
	var why := "other"
	if windows.started_in_contact:
		why = "player already within clearance of a hull (its own cut-in)"
	elif _is_player_cut_in():
		why = "player cut-in (pre-registered rule)"
	elif slow_lanes == lanes:
		why = "slow wall: every lane has a vehicle below the minimum speed ahead"
	return {
		"run": index, "seed": seed_value, "t": time, "s_km": ps / Units.M_PER_KM, "leg": leg, "lanes": lanes,
		"player_kmh": bot.state.v / Units.kmh_to_mps(1.0), "player_lane": road.lane_index_at(bot.state.d, ps),
		"player_moved_s_ago": time - checker.player_last_lateral_t(),
		"fail_after_s": windows.fail_t, "why": why, "per_lane": per_lane,
		"entry_s_ago": time - _entry_t, "entry_lane": _entry_lane, "entry_headway_s": _entry_headway,
		"entry_follower_impossible": _entry_follower_impossible,
		"bot_has_path": pbot != null and pbot.result.passable,
	}


func result() -> Dictionary:
	var c := checker
	return {
		"run": index, "seed": seed_value, "lanes": lanes, "car": String(car.id), "legs": legs,
		"km": bot.state.s / Units.M_PER_KM, "sim_s": time, "ticks": ticks, "wall_s": float(wall_usec) / 1e6,
		"finished": finished and not timed_out, "timed_out": timed_out, "trace": trace,
		"legs_weaving": legs_weaving, "peak_active": peak_active,
		"mean_active": float(active_sum) / float(maxi(ticks, 1)), "ticks_at_cap": ticks_at_cap,
		"sim_usec_per_tick": float(sim_usec) / float(maxi(ticks, 1)),
		"director_usec_per_tick": float(director_usec) / float(maxi(ticks, 1)),
		"signals": c.signals, "moves": c.moves, "cancels": c.cancels,
		"signal_violations": c.signal_violations, "unsignaled_moves": c.unsignaled_moves,
		"ambush_violations": c.ambush_violations, "lane_moves_checked": c.lane_moves_checked,
		"collision_ticks": c.collisions, "collision_pairs": c.collision_pairs,
		"decel_violations": c.decel_violations, "brake_flag_violations": c.brake_flag_violations,
		"offroad_violations": c.offroad_violations, "merges": sim.stat_merges,
		"min_accel": c.min_accel,
		"player_contact_ticks": c.player_contacts, "contact_episodes": c.contact_episodes,
		"rear_end_episodes": c.rear_end_episodes, "rear_end_normal": c.rear_end_normal,
		"window_checks": window_checks, "impossible_checks": impossible_checks,
		"impossible_windows": impossible_windows, "impossible_player_induced": impossible_player_induced,
		"impossible_player_cut_in": impossible_player_cut_in, "player_offroad_ticks": player_offroad_ticks,
		"impossible_traffic": impossible_windows - impossible_player_induced - impossible_player_cut_in,
		"bot": "passability" if pbot != null else "weave",
		"bot_checks": pbot.checks if pbot != null else 0,
		"bot_no_path_checks": pbot.no_path_checks if pbot != null else 0,
		"bot_check_usec": pbot.check_usec if pbot != null else 0,
		"pass_batches": director.pass_batches, "pass_checks": director.pass_checks,
		"pass_failed": director.pass_failed, "pass_rerolls": director.pass_rerolls,
		"pass_removed": director.pass_removed, "pass_unresolved": director.pass_unresolved,
		"pass_probes": director.pass_probes, "pass_ticks_max": director.pass_ticks_max,
		"pass_scripted_batches": director.pass_scripted_batches, "pass_log": Array(director.pass_log),
		"window_examples": window_examples,
		"spawned_ahead": director.spawned_ahead, "spawned_behind": director.spawned_behind,
		"despawned": director.despawned, "rejected_cap": director.rejected_cap,
		"rejected_ghost": director.rejected_ghost, "rejected_visible": director.rejected_visible,
		"rejected_overlap": director.rejected_overlap, "batches": director.batches_planned,
		"sim_signals": sim.stat_signals, "sim_moves": sim.stat_moves, "sim_completed": sim.stat_completed,
		"sim_cancel_player": sim.stat_cancel_player, "sim_cancel_hesitant": sim.stat_cancel_hesitant,
		"sim_cancel_unsafe": sim.stat_cancel_unsafe,
		"set_pieces": director.set_pieces.spawned, "set_pieces_started": director.set_pieces.started,
		"set_pieces_by_kind": director.set_pieces.spawned_by_kind.duplicate(),
		"set_piece_hard_decels": c.set_piece_hard_decels, "peaks_seen": director.peaks_seen,
		"peaks_no_chance": director.peaks_no_chance, "peaks_no_kind": director.peaks_no_kind,
		"peaks_missed": director.peaks_missed, "peaks_unfit": director.peaks_unfit,
		"set_pieces_passed": director.set_pieces.ended_passed,
		"set_pieces_unmet": director.set_pieces.ended_unmet,
		"set_pieces_ended_zone": director.set_pieces.ended_zone,
		"set_pieces_ended_duration": director.set_pieces.ended_duration,
		"set_pieces_ended_empty": director.set_pieces.ended_empty,
		"metrics_raw": metrics_raw(), "messages": Array(c.messages),
	}


## Metric accumulators (summable across runs; TrafficMetrics.to_dict for the values).
func metrics_raw() -> Dictionary:
	var m := metrics
	return {
		"vehicle_seconds": m.vehicle_seconds, "lane_changes": m.lane_changes, "legs": m.legs,
		"set_pieces": m.set_pieces, "gap_count": m.gap_count, "gap_lane_km": m.gap_lane_km,
		"density_vehicles": m.density_vehicles, "lane_speed_sum": Array(m.lane_speed_sum),
		"lane_speed_n": Array(m.lane_speed_n),
	}


## The pre-registered cut-in rule (see CUT_IN_WINDOW_S) at the current tick.
func _is_player_cut_in() -> bool:
	return time - _entry_t <= CUT_IN_WINDOW_S and (_entry_headway < CUT_IN_HEADWAY_S or _entry_follower_impossible)


## Records the player's lane entries (its body starting to overlap a lane) with the
## headway to the vehicle ahead and whether the vehicle behind could brake for it.
func _track_lane_entry() -> void:
	var ps := bot.state
	var lo := ps.d - bot.width_m * 0.5
	var hi := ps.d + bot.width_m * 0.5
	var mask := 0
	for l in lanes:
		var c := road.lane_center_d(l, ps.s)
		var half := road.lane_width(ps.s) * 0.5
		if lo < c + half and hi > c - half:
			mask |= 1 << l
	var entered := mask & ~_entry_mask
	_entry_mask = mask
	if entered == 0:
		return
	for l in lanes:
		if (entered >> l) & 1 == 0:
			continue
		var ts := sim.state
		var gap_a := INF
		var gap_b := INF
		var v_b := 0.0
		for i in ts.capacity:
			if ts.active[i] == 0 or not SpawnSources.occupies_lane(ts, i, l, road):
				continue
			var g := absf(ts.s[i] - ps.s) - (ts.length[i] + bot.length_m) * 0.5
			if ts.s[i] >= ps.s:
				gap_a = minf(gap_a, g)
			elif g < gap_b:
				gap_b = g
				v_b = ts.v[i]
		var closing := v_b - ps.v
		_entry_t = time
		_entry_lane = l
		_entry_headway = gap_a / maxf(ps.v, 0.1)
		_entry_follower_impossible = closing > 0.0 and closing * closing / (2.0 * tuning.traffic.max_decel_mps2) > gap_b


## VehicleParams per car (VehicleParams.build takes ~0.35 s), cached per process.
static func _params_for(c: CarDef, t: Tuning) -> VehicleParams:
	var key := String(c.id)
	if not _params_cache.has(key):
		_params_cache[key] = VehicleParams.build(t, c)
	return _params_cache[key] as VehicleParams


static func _car(run_index: int) -> CarDef:
	var files := DirAccess.get_files_at(CAR_DIR)
	var names: Array[String] = []
	for f in files:
		if f.ends_with(".tres"):
			names.append(f)
	names.sort()
	return load(CAR_DIR + names[run_index % names.size()]) as CarDef
