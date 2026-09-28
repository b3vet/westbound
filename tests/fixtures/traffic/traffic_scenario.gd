class_name TrafficScenario
extends RefCounted
## A traffic scenario for tests (not a test suite): a straight road fixture, the real
## registry and TrafficSim, a scripted player (TrafficBotPlayer), the independent
## TrafficRuleChecker, and a simple "treadmill" spawner that keeps a target density in
## a window around the player (a stand-in for WP2.5's director: ahead spawns at
## spawn_ahead_m in any lane, faster cars behind in the left lanes when the player is
## slower, despawn despawn_behind_m behind). Deterministic by seed.
##
##   var sc := TrafficScenario.new(1234)
##   sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 150.0)
##   sc.populate()
##   sc.run(60.0)
##   check(sc.checker.total_violations() == 0, sc.checker.summary())

const DT := 1.0 / 120.0
const SPAWN_EVERY_S := 0.25
## Profile mix (index = TrafficRegistry.PROFILE_IDS order).
const DEFAULT_WEIGHTS: Array[float] = [0.15, 0.33, 0.12, 0.1, 0.05, 0.08, 0.05, 0.12]
## Chance per spawn attempt to try a fast car from behind (when the player is slower).
const BEHIND_CHANCE := 0.35

var ctx: RunContext
var tuning: Tuning
var road: StraightRoadPath
var registry: TrafficRegistry
var sim: TrafficSim
var bot: TrafficBotPlayer
var checker: TrafficRuleChecker
var events: ScoreEventBuffer
var time := 0.0
var lanes: int
var density_per_km_lane := 16.0
var weights := PackedFloat64Array()
var ahead_m: float
var behind_m: float
var despawn_m: float
var spawner_enabled := true
var observe := true
var event_counts := {}
var hashes := PackedInt64Array()
var hash_every_s := 0.0
var ticks := 0

var _rng: Rng
var _spawn_clock := 0.0
var _next_hash := 0.0
var _rec := SpawnSource.Record.new()


func _init(seed_value: int, lane_count: int = 3, t: Tuning = null) -> void:
	tuning = t if t != null else Tuning.load_default()
	ctx = RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	lanes = lane_count
	road = StraightRoadPath.new(lanes, tuning.road)
	registry = TrafficRegistry.load_default(tuning.traffic)
	sim = TrafficSim.new(ctx, road, registry)
	events = ScoreEventBuffer.new(256)
	ahead_m = tuning.traffic.spawn_ahead_m
	behind_m = tuning.traffic.spawn_behind_m
	despawn_m = tuning.traffic.despawn_behind_m
	_rng = ctx.rng_traffic.derive(&"test_spawner")
	for w in DEFAULT_WEIGHTS:
		weights.append(w)


func make_bot(mode: TrafficBotPlayer.Mode, speed_kmh: float, lane: int = 1) -> TrafficBotPlayer:
	bot = TrafficBotPlayer.new(road, lane, Units.kmh_to_mps(speed_kmh), mode, ctx.run_seed + 7)
	sim.set_player_body(bot.length_m, bot.width_m)
	checker = TrafficRuleChecker.new(tuning, registry, road, bot.length_m, bot.width_m)
	return bot


## Fills the window around the player with traffic at IDM-consistent gaps.
func populate() -> void:
	var s := bot.state.s - despawn_m + 20.0
	var target := int(density_per_km_lane * lanes * (ahead_m + despawn_m) / 1000.0)
	var tries := 0
	while sim.state.count < mini(target, sim.state.capacity) and tries < target * 20:
		tries += 1
		s = _rng.float_range(bot.state.s - despawn_m + 20.0, bot.state.s + ahead_m)
		if absf(s - bot.state.s) < 40.0:
			continue
		_try_spawn(s, -1, -1)


## Adds one vehicle (tests that build exact layouts). NAN d = lane center.
func add(s: float, lane: int, profile: StringName, type: StringName, v_kmh: float, v0_kmh: float = -1.0,
		d: float = NAN) -> int:
	_rec.s = s
	_rec.lane = lane
	_rec.d = d
	_rec.v = Units.kmh_to_mps(v_kmh)
	_rec.v0 = Units.kmh_to_mps(v0_kmh if v0_kmh > 0.0 else v_kmh)
	_rec.profile_id = registry.profile_index(profile)
	_rec.type_id = registry.type_index(type)
	_rec.flags = 0
	return sim.spawn(_rec)


func run(seconds: float) -> void:
	var n := roundi(seconds / DT)
	for k in n:
		tick()


func tick() -> void:
	bot.update(DT, sim.state)
	sim.step(DT, bot.state, null, events)
	time += DT
	ticks += 1
	if observe:
		checker.observe(time, sim.state, bot.state)
	for e in events.size():
		event_counts[events.kind[e]] = int(event_counts.get(events.kind[e], 0)) + 1
	events.clear()
	if spawner_enabled:
		_spawn_clock += DT
		if _spawn_clock >= SPAWN_EVERY_S:
			_spawn_clock -= SPAWN_EVERY_S
			_maintain()
	if hash_every_s > 0.0 and time >= _next_hash:
		_next_hash += hash_every_s
		var h := sim.state.trace_hash()
		h = bot.state.hash_into(h)
		hashes.append(h)


## Benchmark tick: the player holds its speed and lane (no bot logic, no checker).
func tick_sim_only() -> void:
	bot.state.s += bot.state.v * DT
	sim.step(DT, bot.state, null, events)
	events.clear()


## Places n vehicles evenly over [s_lo, s_hi] relative to the player, round-robin over
## the lanes, at the lane flow speed, with profiles from `weights` (benchmarks).
func fill_grid(n: int, s_lo: float, s_hi: float) -> void:
	var per_lane := ceili(float(n) / lanes)
	var step := (s_hi - s_lo) / per_lane
	var k := 0
	while sim.state.count < n and k < n * 4:
		var ln := k % lanes
		var s := bot.state.s + s_lo + step * (floorf(float(k) / lanes) + 0.5 * float(ln) / lanes)
		k += 1
		if absf(s - bot.state.s) < 12.0 and ln == bot.lane:
			continue
		var pid := _rng.pick_weighted(weights)
		var krl := registry.keep_right_lanes[pid]
		if krl > 0 and ln < lanes - krl:
			pid = registry.profile_index(&"commuter")
		var tids := registry.types_for_profile(pid)
		_rec.s = s
		_rec.lane = ln
		_rec.d = NAN
		_rec.v0 = _rng.float_range(registry.v0_min[pid], registry.v0_max[pid])
		_rec.v = minf(_rec.v0, tuning.traffic.lane_flow_speed_mps(ln, lanes))
		_rec.profile_id = pid
		_rec.type_id = tids[0]
		_rec.flags = 0
		sim.spawn(_rec)


func _maintain() -> void:
	var ps := bot.state.s
	var ts := sim.state
	for i in ts.capacity:
		if ts.active[i] == 1 and (ts.s[i] < ps - despawn_m or ts.s[i] > ps + ahead_m + 100.0):
			sim.despawn(i)
	var target := int(density_per_km_lane * lanes * (ahead_m + despawn_m) / 1000.0)
	if ts.count >= mini(target, ts.capacity):
		return
	if _rng.chance(BEHIND_CHANCE):
		_try_spawn(ps - behind_m, -1, 0)
	else:
		_try_spawn(ps + ahead_m - _rng.float_range(0.0, 50.0), -1, -1)


## lane < 0: random (keep-right profiles in their lanes). behind: 0 = fast profile from behind.
func _try_spawn(s: float, lane: int, behind: int) -> int:
	var pid := _rng.pick_weighted(weights)
	if behind == 0:
		pid = registry.profile_index(&"aggressive") if _rng.chance(0.5) else registry.profile_index(&"commuter")
	var krl := registry.keep_right_lanes[pid]
	var ln := lane
	if ln < 0:
		ln = _rng.int_range(lanes - krl if krl > 0 else 0, lanes - 1)
		if behind == 0:
			ln = _rng.int_range(0, mini(1, lanes - 1))
	var v0 := _rng.float_range(registry.v0_min[pid], registry.v0_max[pid])
	var v := minf(v0, tuning.traffic.lane_flow_speed_mps(ln, lanes))
	if behind == 0:
		v = v0
		if v <= bot.state.v + 1.0:
			return -1
	var tids := registry.types_for_profile(pid)
	var tid := tids[_rng.int_range(0, tids.size() - 1)]
	# IDM-consistent spacing against every vehicle in that lane, and the player.
	var d := road.lane_center_d(ln, s)
	var hl := registry.length[tid] * 0.5
	var ts := sim.state
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		# A car signaling or moving into this lane already counts as in it.
		var in_lane := ts.lane[i] == ln or (ts.lc_state[i] != TrafficState.LaneChange.NONE and ts.target_lane[i] == ln) \
			or absf(ts.d[i] - d) < (ts.width[i] + registry.width[tid]) * 0.5 + 0.5
		if not in_lane:
			continue
		# IDM-consistent gap including the closing speed (s*), for whichever follows.
		var need: float
		if ts.s[i] > s:
			need = Idm.desired_gap(v, v - ts.v[i], registry.a_max[pid], registry.b_comfort[pid],
				registry.headway[pid], registry.s0[pid])
		else:
			var q := ts.profile_id[i]
			need = Idm.desired_gap(ts.v[i], ts.v[i] - v, registry.a_max[q], registry.b_comfort[q],
				registry.headway[q], registry.s0[q])
		if absf(ts.s[i] - s) < hl + ts.length[i] * 0.5 + need:
			return -1
	var need_p := registry.s0[pid] + v * registry.headway[pid]
	if s < bot.state.s:
		need_p = Idm.desired_gap(v, v - bot.state.v, registry.a_max[pid], registry.b_comfort[pid],
			registry.headway[pid], registry.s0[pid])
	if absf(bot.state.s - s) < hl + bot.length_m * 0.5 + need_p + 20.0:
		return -1
	_rec.s = s
	_rec.lane = ln
	_rec.d = NAN
	_rec.v = v
	_rec.v0 = v0
	_rec.profile_id = pid
	_rec.type_id = tid
	_rec.model_variant = 0
	_rec.color_index = _rng.int_range(0, 7)
	_rec.flags = 0
	return sim.spawn(_rec)
