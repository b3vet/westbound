extends WBTest
## TrafficDirector (skeleton) against a fake sim. Spec: Traffic → Spawning and the
## opposite carriageway (ahead ~750 m past the fog end; behind ~150 m in the left lanes
## only when the player is slower and out of the frustum; despawn 200 m behind or
## beyond the active window); Road-space simulation (cap 60); Fairness rule 5 (no
## visible pop-in); Lives → No unfair spawns (never overlapping the player or the
## ghost zone); Architecture rule 2 (determinism).

const SEED := 777001
const DT := 1.0 / 120.0
const PLAYER_LEN := 4.5
const PLAYER_WIDTH := 1.9
const LANES := 3

var reg: SpawnFixtureRegistry
var tuning: Tuning

# Per-scenario handles (rebuilt by _setup).
var road: StraightRoadPath
var sim: FakeTrafficSim
var dir: TrafficDirector
var player: VehicleState
var _logged := 0
## Spawns seen by _drive, relative to the player at spawn time.
var ahead_rel := PackedFloat64Array()
var behind_rel := PackedFloat64Array()
var behind_lane := PackedInt32Array()
var behind_v_margin := PackedFloat64Array()
var ghost_violations := 0
var max_count := 0


func before_all() -> void:
	reg = SpawnFixtureRegistry.new()
	tuning = Tuning.load_default()


func _setup(seed_value: int = SEED, lanes: int = LANES, t: Tuning = null, sim_capacity: int = -1,
		player_lane: int = 1, v_kmh: float = 150.0) -> void:
	var tun := t if t != null else tuning
	var run := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tun)
	road = StraightRoadPath.new(lanes, tun.road)
	var cap := sim_capacity if sim_capacity > 0 else tun.traffic.max_active_vehicles
	sim = FakeTrafficSim.new(cap, road, reg.types)
	dir = TrafficDirector.new(run, road, sim, reg.profiles, reg.types, PLAYER_LEN, PLAYER_WIDTH)
	player = VehicleState.new()
	player.s = 0.0
	player.d = road.lane_center_d(player_lane, 0.0)
	player.v = Units.kmh_to_mps(v_kmh)
	_logged = 0
	ahead_rel.clear()
	behind_rel.clear()
	behind_lane.clear()
	behind_v_margin.clear()
	ghost_violations = 0
	max_count = 0


func _reset() -> void:
	dir.reset(player)
	_logged = sim.spawn_count()


## Drives the player at constant speed; after each director step, checks every new
## spawn against the player's position at that moment.
func _drive(seconds: float, dt: float = DT) -> void:
	var ticks := roundi(seconds / dt)
	for k in ticks:
		player.s += player.v * dt
		sim.step(dt)
		dir.step(dt, player)
		max_count = maxi(max_count, sim.state.count)
		while _logged < sim.spawn_count():
			var rel := sim.log_s[_logged] - player.s
			if dir.overlaps_ghost_zone(sim.log_s[_logged], sim.log_d[_logged], sim.log_length[_logged], sim.log_width[_logged], player):
				ghost_violations += 1
			if rel >= 0.0:
				ahead_rel.append(rel)
			else:
				behind_rel.append(rel)
				behind_lane.append(sim.log_lane[_logged])
				behind_v_margin.append(sim.log_v[_logged] - player.v)
			_logged += 1


func _tuning_copy() -> Tuning:
	var t: Tuning = tuning.duplicate()
	t.traffic = tuning.traffic.duplicate() as TrafficTuning
	t.director = tuning.director.duplicate() as DirectorTuning
	return t


static func _never_visible(_s: float, _d: float) -> bool:
	return false


static func _always_visible(_s: float, _d: float) -> bool:
	return true


# ---------------------------------------------------------------- Ahead: no pop-in

func test_prefill_populates_the_road_ahead() -> void:
	_setup()
	_reset()
	gt(sim.state.count, 10, "road ahead populated at the start")
	ge(dir.spawned_to(), player.s + dir.ahead_distance())
	for i in sim.state.capacity:
		if sim.state.active[i] == 1:
			ge(sim.state.s[i], player.s - PLAYER_LEN, "prefill never behind the player")
			le(sim.state.s[i], dir.spawned_to())


func test_ahead_spawns_land_beyond_the_fog_end() -> void:
	# Default fog end (medium tier view distance) and the High tier's longer one.
	for fog: float in [-1.0, 800.0]:
		_setup()
		if fog > 0.0:
			dir.set_fog_end(fog)
		_reset()
		_drive(60.0)
		gt(ahead_rel.size(), 20, "ahead batches spawned (fog %s)" % fog)
		var min_rel := INF
		for r in ahead_rel:
			min_rel = minf(min_rel, r)
		ge(min_rel, dir.fog_end_m + tuning.traffic.spawn_fog_margin_m, "never inside the fog end (fog %s)" % fog)
		ge(min_rel, tuning.traffic.spawn_ahead_m - player.v * DT, "around 750 m ahead")
		le(min_rel, dir.ahead_distance() + tuning.director.spawn_batch_length_m, "within one batch of the ahead line")
		ge(dir.ahead_distance(), dir.fog_end_m + tuning.traffic.spawn_fog_margin_m)
		eq(behind_rel.size(), 0, "no frustum check set: nothing behind")
		eq(ghost_violations, 0)


func test_batches_are_contiguous() -> void:
	_setup()
	_reset()
	var prev := dir.spawned_to()
	var batch := tuning.director.spawn_batch_length_m
	var batches := 0
	for k in 4000:
		player.s += player.v * DT
		dir.step(DT, player)
		var now := dir.spawned_to()
		if now != prev:
			near(now - prev, batch, 1e-6, "one batch at a time, no holes")
			prev = now
			batches += 1
	gt(batches, 3)


# ---------------------------------------------------------------- Behind spawns

func test_behind_spawns_only_when_player_slower_and_out_of_frustum() -> void:
	# Slow player in the right lane, camera frustum never covers the spawn point.
	_setup(SEED, LANES, null, -1, 2, 60.0)
	dir.frustum_check = _never_visible
	_reset()
	_drive(40.0)
	gt(behind_rel.size(), 3, "faster traffic arrives from behind")
	var left_lanes := mini(tuning.traffic.spawn_behind_lane_count, LANES - 1)
	for k in behind_rel.size():
		near(behind_rel[k], -tuning.traffic.spawn_behind_m, player.v * DT + 1e-6, "~150 m behind")
		lt(behind_lane[k], left_lanes, "left lanes only")
		ge(behind_v_margin[k], Units.kmh_to_mps(tuning.traffic.spawn_behind_speed_margin_kmh) - 1e-9, "faster than the player")
	eq(dir.spawned_behind, behind_rel.size())
	eq(ghost_violations, 0)

	# Same, but the spawn point is inside the frustum (e.g. overhead camera): none.
	_setup(SEED, LANES, null, -1, 2, 60.0)
	dir.frustum_check = _always_visible
	_reset()
	_drive(40.0)
	eq(behind_rel.size(), 0, "never behind while visible")
	gt(dir.rejected_visible, 0)

	# Fast player (faster than every lane's flow): none.
	_setup(SEED, LANES, null, -1, 2, 200.0)
	dir.frustum_check = _never_visible
	_reset()
	_drive(40.0)
	eq(behind_rel.size(), 0, "never behind a faster player")


func test_behind_rate_follows_speed_difference() -> void:
	var counts := PackedInt32Array()
	for v_kmh: float in [40.0, 90.0]:
		_setup(SEED, LANES, null, 200, 2, v_kmh)
		dir.frustum_check = _never_visible
		_reset()
		_drive(60.0, 1.0 / 60.0)
		counts.append(behind_rel.size())
	gt(counts[0], counts[1], "a slower player is overtaken more often")


# ---------------------------------------------------------------- Despawn

func test_despawn_200m_behind_and_beyond_the_window() -> void:
	_setup()
	_reset()
	_drive(30.0)
	gt(dir.despawned, 0)
	var front := player.s + dir.ahead_distance() + tuning.director.spawn_batch_length_m \
		+ tuning.traffic.spawn_despawn_ahead_margin_m
	for i in sim.state.capacity:
		if sim.state.active[i] == 1:
			ge(sim.state.s[i], player.s - tuning.traffic.despawn_behind_m, "nothing kept past 200 m behind")
			le(sim.state.s[i], front, "nothing kept beyond the window")
	# Exact boundary: 199 m behind stays, 201 m behind goes; far ahead goes.
	var keep := _manual_vehicle(player.s - tuning.traffic.despawn_behind_m + 1.0)
	var gone := _manual_vehicle(player.s - tuning.traffic.despawn_behind_m - 1.0)
	var far := _manual_vehicle(front + 1.0)
	dir.step_despawn(player.s)
	check(sim.state.is_active(keep), "199 m behind is kept")
	check(not sim.state.is_active(gone), "201 m behind is despawned")
	check(not sim.state.is_active(far), "beyond the active window is despawned")


func _manual_vehicle(s: float) -> int:
	var i := sim.state.allocate()
	sim.state.s[i] = s
	sim.state.lane[i] = 0
	return i


# ---------------------------------------------------------------- Cap

func test_cap_60_on_the_player_carriageway() -> void:
	# Very dense traffic on four lanes, a slow player (behind spawns too), and a sim with
	# more room than the cap: the director alone must hold 60.
	var t := _tuning_copy()
	t.director.density_first_per_km_lane = 40.0
	t.director.density_last_per_km_lane = 40.0
	_setup(SEED, 4, t, 120, 3, 50.0)
	dir.frustum_check = _never_visible
	_reset()
	le(sim.state.count, t.traffic.max_active_vehicles, "prefill respects the cap")
	_drive(30.0, 1.0 / 60.0)
	le(max_count, t.traffic.max_active_vehicles, "never above the cap")
	eq(max_count, t.traffic.max_active_vehicles, "the cap is reached")
	gt(dir.rejected_cap, 0)


# ---------------------------------------------------------------- Player / ghost zone

func test_never_spawns_overlapping_the_player_or_ghost_zone() -> void:
	# Default zone (player box + margins), player in every lane, slow (behind spawns).
	for lane in LANES:
		_setup(SEED + lane, LANES, null, -1, lane, 70.0)
		dir.frustum_check = _never_visible
		_reset()
		_check_nothing_in_zone("after prefill, lane %d" % lane)
		_drive(30.0, 1.0 / 60.0)
		eq(ghost_violations, 0, "lane %d" % lane)
	# A large custom zone (e.g. the 2 s ghost period's reach) is honored too.
	_setup(SEED, LANES, null, -1, 1, 70.0)
	dir.set_ghost_zone(200.0, 300.0, 6.0)
	dir.frustum_check = _never_visible
	_reset()
	gt(dir.rejected_ghost, 0, "prefill hit the zone")
	_check_nothing_in_zone("custom zone after prefill")
	_drive(30.0, 1.0 / 60.0)
	eq(ghost_violations, 0, "custom zone")


func _check_nothing_in_zone(what: String) -> void:
	for i in sim.state.capacity:
		if sim.state.active[i] == 1:
			check(not dir.overlaps_ghost_zone(sim.state.s[i], sim.state.d[i], sim.state.length[i], sim.state.width[i], player),
				"%s: slot %d at s=%.1f d=%.1f" % [what, i, sim.state.s[i] - player.s, sim.state.d[i]])


func test_ghost_zone_default_is_player_box_plus_margins() -> void:
	_setup()
	near(dir.ghost_ahead_m, PLAYER_LEN * 0.5 + tuning.traffic.spawn_ghost_margin_long_m, 1e-9)
	near(dir.ghost_behind_m, PLAYER_LEN * 0.5 + tuning.traffic.spawn_ghost_margin_long_m, 1e-9)
	near(dir.ghost_half_width_m, PLAYER_WIDTH * 0.5 + tuning.traffic.spawn_ghost_margin_lat_m, 1e-9)
	check(dir.overlaps_ghost_zone(player.s, player.d, 4.0, 1.8, player), "the player's own spot")
	check(not dir.overlaps_ghost_zone(player.s + 100.0, player.d, 4.0, 1.8, player), "100 m ahead")
	check(not dir.overlaps_ghost_zone(player.s, road.lane_center_d(0, 0.0), 4.0, 1.8, player), "the next lane")


# ---------------------------------------------------------------- Legs, opposite side

func test_leg_raises_density() -> void:
	var counts := PackedInt32Array()
	for leg: int in [1, 8]:
		_setup()
		dir.set_leg(leg, player.s)
		_reset()
		counts.append(sim.state.count)
	gt(counts[1], counts[0], "leg 8 is denser than leg 1")
	# Opposite side follows the leg too.
	_setup()
	dir.set_leg(1, player.s)
	_reset()
	var opp_1 := dir.opposite.target_count()
	dir.set_leg(8, player.s)
	gt(dir.opposite.target_count(), opp_1)


func test_opposite_carriageway_is_kept_populated() -> void:
	_setup()
	_reset()
	var target := dir.opposite.target_count()
	gt(target, 0)
	_drive(30.0, 1.0 / 60.0)
	eq(dir.opposite.state.count, target, "count held")
	gt(dir.opposite.recycled, 0, "recycled as the player drives")
	lt(dir.opposite.density_per_km_lane(), tuning.director.density_per_km_lane(dir.leg), "lower density than the player side")


func test_night_turns_on_opposite_headlights() -> void:
	_setup()
	_reset()
	dir.set_night(true)
	for i in dir.opposite.state.capacity:
		if dir.opposite.state.active[i] == 1:
			check(dir.opposite.state.has_flag(i, TrafficState.FLAG_HEADLIGHTS))
	check(dir.ctx.is_night)


# ---------------------------------------------------------------- Determinism, allocations

func _trace(seed_value: int) -> int:
	_setup(seed_value, LANES, null, -1, 1, 120.0)
	dir.frustum_check = _never_visible
	_reset()
	var h := TraceHash.SEED
	var dt := 1.0 / 60.0
	for sec in 60:
		# A varying but scripted speed trace (slow phases trigger behind spawns).
		player.v = Units.kmh_to_mps(80.0 + 120.0 * float(sec % 20) / 20.0)
		for k in 60:
			player.s += player.v * dt
			sim.step(dt)
			dir.step(dt, player)
		h = sim.state.hash_into(h)
		h = dir.opposite.state.hash_into(h)
	return h


func test_deterministic_given_seed_and_trace() -> void:
	var a := _trace(SEED)
	var b := _trace(SEED)
	var c := _trace(SEED + 1)
	eq(a, b, "same seed and player trace, same traffic")
	ne(a, c, "different seeds differ")


func test_despawn_scan_allocates_nothing() -> void:
	_setup()
	_reset()
	_drive(5.0)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for k in 1000:
		dir.step_despawn(player.s)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before)


func test_step_between_batches_allocates_nothing() -> void:
	# Player faster than every lane (no behind spawns); run ticks that plan no batch.
	_setup(SEED, LANES, null, -1, 1, 200.0)
	_reset()
	_drive(2.0)
	var ticks := 0
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	var planned := dir.batches_planned
	while ticks < 200:
		if player.s + player.v * DT + dir.ahead_distance() >= dir.spawned_to():
			break
		player.s += player.v * DT
		dir.step(DT, player)
		ticks += 1
	eq(dir.batches_planned, planned)
	gt(ticks, 50)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before)


# ---------------------------------------------------------------- Soak

## 30 simulated minutes over every leg, a scripted speed trace swinging from crawling
## to flat out and lane hopping: no pop-in, no ghost-zone spawn, cap held, nothing kept
## past 200 m behind, the opposite count held.
func soak_director_invariants() -> void:
	_setup(SEED, 4, null, 100, 1, 100.0)
	dir.frustum_check = _never_visible
	_reset()
	var dt := 1.0 / 60.0
	var min_ahead := INF
	var bad_behind := 0
	var opposite_off := 0
	for sec in 30 * 60:
		if sec % 200 == 0:
			dir.set_leg(1 + floori(sec / 200.0) % 10, player.s)
		player.v = Units.kmh_to_mps(30.0 + 250.0 * float((sec * 7) % 40) / 40.0)
		player.d = road.lane_center_d(floori(sec / 13.0) % 4, player.s)
		_drive(1.0, dt)
		for r in ahead_rel:
			min_ahead = minf(min_ahead, r)
		for k in behind_rel.size():
			if behind_lane[k] >= tuning.traffic.spawn_behind_lane_count or behind_v_margin[k] <= 0.0:
				bad_behind += 1
		ahead_rel.clear()
		behind_rel.clear()
		behind_lane.clear()
		behind_v_margin.clear()
		if dir.opposite.state.count != dir.opposite.target_count():
			opposite_off += 1
		for i in sim.state.capacity:
			if sim.state.active[i] == 1:
				ge(sim.state.s[i], player.s - tuning.traffic.despawn_behind_m)
	ge(min_ahead, dir.fog_end_m + tuning.traffic.spawn_fog_margin_m, "no pop-in ahead")
	eq(bad_behind, 0, "behind spawns: left lanes, faster than the player")
	eq(ghost_violations, 0)
	le(max_count, tuning.traffic.max_active_vehicles)
	eq(opposite_off, 0)
	gt(dir.spawned_behind, 0)
	gt(dir.spawned_ahead, 500)
	print("      soak: ahead=%d behind=%d despawned=%d rej cap=%d ghost=%d visible=%d" % [
		dir.spawned_ahead, dir.spawned_behind, dir.despawned, dir.rejected_cap, dir.rejected_ghost, dir.rejected_visible])
