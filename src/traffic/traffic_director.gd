class_name TrafficDirector
extends RefCounted
## Traffic director (skeleton): plans spawn batches ahead, spawns faster traffic from
## behind, despawns, caps the player's carriageway and keeps the opposite carriageway
## populated. Spec: Traffic → Spawning and the opposite carriageway; Traffic director
## (difficulty by leg, pluggable SpawnSource); Fairness rules 5 (no visible pop-in)
## and 6; Lives → No unfair spawns. See docs/SPAWNING.md and docs/CONTRACTS.md §6.
##
## Pure and headless (RefCounted, no Node). Deterministic given the run seed and the
## player's trace: all randomness comes from streams derived from run.rng_traffic.
##
## The sim is duck-typed (WP2.4's TrafficSim, or a test fake) and must provide:
##   var state: TrafficState                      # the player carriageway, capacity >= the cap
##   func spawn(rec: SpawnSource.Record) -> int   # copies the record into a slot; -1 if full
##   func despawn(slot: int) -> void
## `profiles` / `types` are the traffic registry's stable-ordered lists (index =
## profile_id / type_id). The director never writes TrafficState itself.
##
## Per tick (after traffic_sim.step): step(dt, player). The despawn scan, behind-spawn
## bookkeeping and opposite traffic allocate nothing; planning a batch (~every 300 m)
## is director rate and may allocate. Phase 6 grows this: intensity waves and blind
## caps in _refresh_ctx(), passability and re-rolls in _plan_range(), set pieces as
## further sources.

var run: RunContext
var road: RoadPath
var traffic_tuning: TrafficTuning
var director_tuning: DirectorTuning
var sim: Object
var state: TrafficState
## Default source (Flow, or Daily in Daily Drive); also draws behind spawns and the
## opposite carriageway's mix.
var flow: SpawnSources.Flow
## Source of ahead batches (Flow by default; later set pieces, Beatmap, HopTargets).
var source: SpawnSource
var opposite: OppositeTraffic
## Shared, reused planning context (refreshed before each plan).
var ctx := SpawnSource.Context.new()

var leg: int = 1
var is_night: bool = false
var biome: BiomeDef
## Fog end distance at the current view distance (m). Ahead spawns land beyond it.
var fog_end_m: float
## (s: float, d: float) -> bool: true when the road point is inside the camera
## frustum. Behind spawns need false. Unset = always visible = no behind spawns.
var frustum_check: Callable

## No-spawn zone around the player, relative to its (s, d): [s - behind, s + ahead] x
## [d - half_width, d + half_width]. Default: the player's box + tuning margins.
var ghost_behind_m: float
var ghost_ahead_m: float
var ghost_half_width_m: float

# Stats (metrics, sandbox, tests).
var spawned_ahead: int = 0
var spawned_behind: int = 0
var despawned: int = 0
var rejected_cap: int = 0
var rejected_ghost: int = 0
var rejected_visible: int = 0
var batches_planned: int = 0

var _rng: Rng
var _spawned_to: float = 0.0
var _behind_debt := PackedFloat64Array()   ## per lane, expected behind arrivals owed (0..1)
var _batch: Array[SpawnSource.Record] = []
var _behind_rec := SpawnSource.Record.new()
var _prefilling: bool = false


func _init(run_ctx: RunContext, road_path: RoadPath, traffic_sim: Object, profiles: Array[DriverProfile],
		types: Array[VehicleType], player_length_m: float, player_width_m: float) -> void:
	run = run_ctx
	road = road_path
	traffic_tuning = run.tuning.traffic
	director_tuning = run.tuning.director
	sim = traffic_sim
	state = sim.get(&"state") as TrafficState
	assert(state != null, "TrafficDirector: the sim must expose `state: TrafficState`")
	_rng = run.rng_traffic.derive(&"flow")
	flow = SpawnSources.for_run(run, profiles, types)
	flow.player_length_m = player_length_m
	flow.player_width_m = player_width_m
	source = flow
	var q := run.tuning.quality
	fog_end_m = q.view_distance_m[maxi(q.tier_index(q.default_tier), 0)]
	set_player_box(player_length_m, player_width_m)
	_behind_debt.resize(traffic_tuning.lane_flow_speeds_from_right_kmh.size())
	_refresh_ctx(null)
	opposite = OppositeTraffic.new(traffic_tuning, road, flow, ctx, run.rng_traffic.derive(&"opposite"), ahead_distance())


## Ghost zone = the player's box grown by the tuning margins.
func set_player_box(length_m: float, width_m: float) -> void:
	set_ghost_zone(length_m * 0.5 + traffic_tuning.spawn_ghost_margin_long_m,
		length_m * 0.5 + traffic_tuning.spawn_ghost_margin_long_m,
		width_m * 0.5 + traffic_tuning.spawn_ghost_margin_lat_m)


func set_ghost_zone(behind_m: float, ahead_m: float, half_width_m: float) -> void:
	ghost_behind_m = behind_m
	ghost_ahead_m = ahead_m
	ghost_half_width_m = half_width_m


## The run passes the fog end at the current view distance (quality tier x the color
## script's fog_end_frac, or just the view distance to be conservative).
func set_fog_end(meters: float) -> void:
	fog_end_m = meters
	opposite.ahead_m = ahead_distance()


func set_leg(leg_index: int, player_s: float) -> void:
	leg = leg_index
	_refresh_ctx(null)
	opposite.set_density(ctx.density_per_km_lane, player_s)


func set_night(on: bool) -> void:
	is_night = on
	ctx.is_night = on
	opposite.set_night(on)


func set_biome(b: BiomeDef) -> void:
	biome = b
	ctx.biome = b


## Where ahead batches start: past the fog end (fairness rule 5).
func min_ahead_m() -> float:
	return fog_end_m + traffic_tuning.spawn_fog_margin_m


## How far ahead batches are kept planned (~750 m, never inside the fog end).
func ahead_distance() -> float:
	return maxf(traffic_tuning.spawn_ahead_m, min_ahead_m())


## Planned up to here (s); the next batch starts at max(this, player s + min_ahead_m()).
func spawned_to() -> float:
	return _spawned_to


## Start of a run (or a reset): clears both carriageways and fills the road from the
## player to the ahead distance (outside the ghost zone) before anything is drawn, then
## the opposite side. Director rate.
func reset(player: VehicleState) -> void:
	for i in state.capacity:
		if state.active[i] == 1:
			sim.despawn(i)
	_behind_debt.fill(0.0)
	spawned_ahead = 0
	spawned_behind = 0
	despawned = 0
	rejected_cap = 0
	rejected_ghost = 0
	rejected_visible = 0
	batches_planned = 0
	_prefilling = true
	var batch := director_tuning.spawn_batch_length_m
	var a := player.s
	while a < player.s + ahead_distance():
		_plan_range(a, a + batch, player)
		a += batch
	_spawned_to = a
	_prefilling = false
	_refresh_ctx(player)
	opposite.ahead_m = ahead_distance()
	opposite.reset(player.s, ctx.density_per_km_lane)


## Per tick, after traffic_sim.step. Allocation-free except when a batch is due.
func step(dt: float, player: VehicleState) -> void:
	step_despawn(player.s)
	if player.s + ahead_distance() >= _spawned_to:
		_plan_ahead(player)
	_step_behind(dt, player)
	opposite.step(dt, player.s)


## Despawns everything 200 m behind the player or beyond the active window ahead.
## Allocation-free.
func step_despawn(player_s: float) -> void:
	var back := player_s - traffic_tuning.despawn_behind_m
	var front := player_s + ahead_distance() + director_tuning.spawn_batch_length_m \
		+ traffic_tuning.spawn_despawn_ahead_margin_m
	for i in state.capacity:
		if state.active[i] == 1 and (state.s[i] < back or state.s[i] > front):
			sim.despawn(i)
			despawned += 1


# ---------------------------------------------------------------- Ahead batches (director rate)

func _plan_ahead(player: VehicleState) -> void:
	var batch := director_tuning.spawn_batch_length_m
	while player.s + ahead_distance() >= _spawned_to:
		var a := maxf(_spawned_to, player.s + min_ahead_m())
		_plan_range(a, a + batch, player)
		_spawned_to = a + batch


## Plans [a, b) with the current source and commits it nearest-first. Phase 6 runs
## passability (and re-rolls) between plan and commit.
func _plan_range(a: float, b: float, player: VehicleState) -> void:
	road.ensure_generated_to(b + traffic_tuning.spawn_despawn_ahead_margin_m)
	_refresh_ctx(player)
	_batch.clear()
	source.plan_batch(ctx, a, b, _batch)
	_batch.sort_custom(func(x: SpawnSource.Record, y: SpawnSource.Record) -> bool: return x.s < y.s)
	batches_planned += 1
	# Near the cap, thin the batch evenly (dropping vehicles only widens gaps) rather
	# than committing its near end and leaving the far end empty.
	var room := traffic_tuning.max_active_vehicles - state.count
	var n := _batch.size()
	if n > room:
		rejected_cap += n - maxi(room, 0)
		for k in maxi(room, 0):
			if _commit(_batch[floori((float(k) + 0.5) * float(n) / float(room))], player):
				spawned_ahead += 1
		return
	for rec in _batch:
		if _commit(rec, player):
			spawned_ahead += 1


# ---------------------------------------------------------------- Behind spawns (per tick)

## Faster traffic arriving from behind while the player is slower than a left lane:
## each lane owes density x (v_lane - v_player) arrivals per second; one is spawned at
## spawn_behind_m behind when owed, the point is out of the frustum and the gaps fit.
## Allocation-free.
func _step_behind(dt: float, player: VehicleState) -> void:
	var lanes := mini(road.lane_count(player.s), _behind_debt.size())
	var left_lanes := maxi(mini(traffic_tuning.spawn_behind_lane_count, lanes - 1), 1)
	var margin := Units.kmh_to_mps(traffic_tuning.spawn_behind_speed_margin_kmh)
	var rate := ctx.density_per_km_lane / Units.M_PER_KM
	for lane in _behind_debt.size():
		if lane >= left_lanes:
			_behind_debt[lane] = 0.0
			continue
		var v_lane := traffic_tuning.lane_flow_speed_mps(lane, lanes)
		if v_lane <= player.v + margin:
			_behind_debt[lane] = 0.0
			continue
		_behind_debt[lane] = minf(_behind_debt[lane] + rate * (v_lane - player.v) * dt, 1.0)
		if _behind_debt[lane] >= 1.0 and _step_try_behind(lane, player, player.v + margin):
			_behind_debt[lane] = 0.0


func _step_try_behind(lane: int, player: VehicleState, min_speed: float) -> bool:
	var s := player.s - traffic_tuning.spawn_behind_m
	if is_visible(s, road.lane_center_d(lane, s)):
		rejected_visible += 1
		return false
	_refresh_ctx(player)
	if not flow.plan_single(ctx, s, lane, min_speed, _behind_rec):
		return false
	if not _commit(_behind_rec, player):
		return false
	spawned_behind += 1
	return true


# ---------------------------------------------------------------- Commit rules

## True when (s, d) is inside the camera frustum (or no check is set).
func is_visible(s: float, d: float) -> bool:
	if not frustum_check.is_valid():
		return true
	return bool(frustum_check.call(s, d))


## True when a box at (s, d) with the given size overlaps the ghost zone.
func overlaps_ghost_zone(s: float, d: float, length_m: float, width_m: float, player: VehicleState) -> bool:
	return s + length_m * 0.5 > player.s - ghost_behind_m and s - length_m * 0.5 < player.s + ghost_ahead_m \
		and d + width_m * 0.5 > player.d - ghost_half_width_m and d - width_m * 0.5 < player.d + ghost_half_width_m


## Every spawn goes through here: cap, ghost zone, no pop-in, then the sim. Allocation-free.
func _commit(rec: SpawnSource.Record, player: VehicleState) -> bool:
	if state.count >= traffic_tuning.max_active_vehicles or state.is_full():
		rejected_cap += 1
		return false
	var d := road.lane_center_d(rec.lane, rec.s) if is_nan(rec.d) else rec.d
	if overlaps_ghost_zone(rec.s, d, flow.length_of(rec.type_id), flow.width_of(rec.type_id), player):
		rejected_ghost += 1
		return false
	if not _prefilling:
		var ahead_ok := rec.s - player.s >= min_ahead_m()
		var behind_ok := rec.s < player.s and not is_visible(rec.s, d)
		if not (ahead_ok or behind_ok):
			rejected_visible += 1
			return false
	var slot: int = sim.spawn(rec)
	return slot >= 0


## Refreshes the shared planning context for the current leg. Phase 6: intensity waves
## scale density_per_km_lane, blind windows cap it and gate set_pieces_allowed.
## Allocation-free.
func _refresh_ctx(player: VehicleState) -> void:
	ctx.run = run
	ctx.rng = _rng
	ctx.road = road
	ctx.traffic = state
	if player != null:
		ctx.player = player
	ctx.leg = leg
	ctx.density_per_km_lane = director_tuning.density_per_km_lane(leg)
	ctx.aggressive_share = director_tuning.aggressive_share_frac(leg)
	ctx.hesitant_allowed = leg >= director_tuning.hesitant_first_leg
	ctx.intensity = 0.0
	ctx.set_pieces_allowed = false
	ctx.is_night = is_night
	ctx.biome = biome
