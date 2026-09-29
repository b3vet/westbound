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
## Per tick (after traffic_sim.step): step(dt, player). The despawn scan, the density
## control (plan D11), behind-spawn bookkeeping and opposite traffic allocate nothing;
## planning a batch and topping up the band beyond the fog (~every 300 m) is director
## rate and may allocate.
##
## Density (plan D11, docs/SPAWNING.md "Density (D11)"): the effective density in the
## window around the player tracks the leg's target through a slow planning gain and
## the band top-up; late legs drive closer (a leg-ramped IDM headway scale passed to
## the sim and to Flow); set_density_scale() is the owner's DEV knob. Phase 6 grows this: intensity waves and blind
## caps in _refresh_ctx(), passability and re-rolls in _plan_range(), set pieces as
## further sources.
##
## Intensity waves, difficulty by leg, blind caps and set pieces (WP6.2,
## docs/SPAWNING.md "Intensity waves", docs/SET_PIECES.md): `waves` (IntensityWaves)
## holds the leg's build / peak / breather curve along the road and the meeting map;
## Flow plans every lane at the wave-shaped, blind-capped density (flow.shaper), the
## band top-up and behind arrivals follow it, and the density gain tracks the
## wave-shaped target of the window. `source` is `set_pieces` (SetPieceSource, wrapping
## Flow): at each wave peak _schedule_set_piece() may put a set piece in the batch being
## planned, which then goes through the same commit path. Set-piece events go to
## `events` (the run's buffer).

## force_set_piece(): batches tried (the first one where the piece fits the road and
## rule 6 gets it) before the request is dropped.
const FORCED_TRIES := 16

var run: RunContext
var road: RoadPath
var traffic_tuning: TrafficTuning
var director_tuning: DirectorTuning
var sim: Object
var state: TrafficState
## Default source (Flow, or Daily in Daily Drive); also draws behind spawns and the
## opposite carriageway's mix.
var flow: SpawnSources.Flow
## Source of ahead batches: set_pieces (which plans Flow around its pieces) by default;
## later Beatmap, HopTargets. Set pieces are scheduled only while it is set_pieces.
var source: SpawnSource
## Intensity waves and the blind-window cap (WP6.2).
var waves: IntensityWaves
## The SetPiece source and the set-piece runtime (WP6.2).
var set_pieces: SetPieceSource
## Where set-piece events go (the run's ScoreEventBuffer; null = nowhere).
var events: ScoreEventBuffer:
	set(buf):
		events = buf
		if set_pieces != null:
			set_pieces.events = buf
## Dev and tests: wave peaks may get set pieces.
var set_pieces_enabled: bool = true
var opposite: OppositeTraffic
## Shared, reused planning context (refreshed before each plan).
var ctx := SpawnSource.Context.new()

var leg: int = 1
## Runtime multiplier on the leg's density (plan D11: the owner's DENS dev knob). 1 =
## the tuning's leg ramp. Scales ahead batches, behind arrivals and the opposite side.
var density_scale: float = 1.0
## Density tracking (plan D11, not in spec): ahead batches and behind arrivals are
## planned at the target x this gain, which slowly integrates the shortfall of the
## effective density in the density window (traffic that drains out of the window,
## lanes the player keeps pace with). Clamped to [density_gain_min, density_gain_max].
var density_gain: float = 1.0
## Last measured effective density (vehicles per km per lane in the window).
var window_density: float = 0.0
var is_night: bool = false
var biome: BiomeDef
## Fog end distance at the current view distance (m). Ahead spawns land beyond it.
var fog_end_m: float
## Optional dev/test override of is_visible(): (s: float, d: float) -> bool, true when
## the road point is in view. Unset (the game, the soak): the pure, camera-independent
## view test (behind_spawn_view_margin_m), so traffic never depends on the camera.
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
## Spawns refused by the final live-traffic check in _commit (a source planned closer
## than s* to a vehicle occupying the lane). Flow rarely trips it (it checks only the
## nearest neighbors); set pieces and later sources may.
var rejected_overlap: int = 0
var batches_planned: int = 0
## Ahead spawns added by the band top-up (plan D11), included in spawned_ahead.
var spawned_topup: int = 0
## Wave-shaped target of the density window (vehicles per km per lane), at the last
## density control step: the flat target x IntensityWaves.window_mult.
var window_target: float = 0.0
## Set-piece scheduling (WP6.2): peaks considered, and why peaks got none.
var peaks_seen: int = 0
var peaks_no_chance: int = 0
var peaks_no_kind: int = 0
var peaks_missed: int = 0
var peaks_unfit: int = 0
## Live vehicles beyond the fog removed to make room for a set piece.
var despawned_for_set_pieces: int = 0

var _rng: Rng
var _spawned_to: float = 0.0
var _behind_debt := PackedFloat64Array()   ## per lane, expected behind arrivals owed (0..1)
var _behind_wait := PackedFloat64Array()   ## per lane, s until a failed behind spawn is retried
var _batch: Array[SpawnSource.Record] = []
var _behind_rec := SpawnSource.Record.new()
var _topup_rec := SpawnSource.Record.new()
var _prefilling: bool = false
var _player_s: float = 0.0
var _control_clock: float = 0.0
var _last_slot: int = -1   ## the slot of the last successful _commit
var _batch_a: float = 0.0   ## the batch being planned (ctx.intensity, set_pieces_allowed)
var _batch_b: float = 0.0
var _peak_done: int = -1    ## id of the last wave peak handled (IntensityWaves.seg_id)
var _forced: SetPieceDef    ## dev: the next batch gets this piece (force_set_piece)
var _forced_tries: int = 0
var _closing_floor: float
var _err_smooth: float = 0.0   ## the density error, low-passed (_step_density)


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
	waves = IntensityWaves.new(director_tuning, traffic_tuning, run.tuning.legs, run.rng_traffic.derive(IntensityWaves.STREAM))
	flow.shaper = waves
	if sim.has_method(&"closure_ahead"):
		flow.lane_guard = sim
	set_pieces = SetPieceSource.new(run, flow, sim, waves, run.rng_traffic.derive(SetPieceSource.STREAM))
	source = set_pieces
	_closing_floor = Units.kmh_to_mps(director_tuning.wave_min_closing_kmh)
	_apply_headway()
	var q := run.tuning.quality
	fog_end_m = q.view_distance_m[maxi(q.tier_index(q.default_tier), 0)]
	set_player_box(player_length_m, player_width_m)
	_behind_debt.resize(traffic_tuning.lane_flow_speeds_from_right_kmh.size())
	_behind_wait.resize(_behind_debt.size())
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
	_player_s = player_s
	_apply_headway()
	_refresh_ctx(null)
	opposite.set_density(target_density_per_km_lane(), player_s)


## Late legs drive closer (plan D11): the leg's IDM headway scale goes to the sim
## (if it has set_headway_scale) and to Flow's spawn gaps. Director rate.
func _apply_headway() -> void:
	var k := director_tuning.headway_scale(leg)
	flow.headway_scale = k
	if sim.has_method(&"set_headway_scale"):
		sim.call(&"set_headway_scale", k)


## Dev knob (plan D11): multiplies the leg's density from the next batch on (and the
## opposite side's count now).
func set_density_scale(scale: float) -> void:
	density_scale = maxf(scale, 0.0)
	_refresh_ctx(null)
	opposite.set_density(target_density_per_km_lane(), _player_s)


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


## The leg's target density around the player (vehicles per km per lane): the leg
## ramp x the runtime density scale. Batches are planned at this x density_gain.
func target_density_per_km_lane() -> float:
	return director_tuning.density_per_km_lane(leg) * density_scale


## Effective density: active vehicles per km per lane inside the density window
## [player_s - density_window_behind_m, player_s + density_window_ahead_m] (plan D11;
## dev report and density survey). Allocation-free.
func window_density_per_km_lane(player_s: float) -> float:
	var lo := player_s - director_tuning.density_window_behind_m
	var hi := player_s + director_tuning.density_window_ahead_m
	var n := 0
	for i in state.capacity:
		if state.active[i] == 1 and state.s[i] >= lo and state.s[i] <= hi:
			n += 1
	# Lane-km with the lane count at each s (lane drops, WP6.2).
	var k := maxi(director_tuning.wave_window_samples, 1)
	var lanes_sum := 0
	for j in k:
		lanes_sum += road.lane_count(lerpf(lo, hi, (float(j) + 0.5) / float(k)))
	var lane_km := (hi - lo) / Units.M_PER_KM * maxf(float(lanes_sum) / float(k), 1.0)
	return float(n) / lane_km


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
	_behind_wait.fill(0.0)
	spawned_ahead = 0
	spawned_behind = 0
	despawned = 0
	rejected_cap = 0
	rejected_ghost = 0
	rejected_visible = 0
	rejected_overlap = 0
	batches_planned = 0
	spawned_topup = 0
	peaks_seen = 0
	peaks_no_chance = 0
	peaks_no_kind = 0
	peaks_missed = 0
	peaks_unfit = 0
	despawned_for_set_pieces = 0
	_prefilling = true
	_player_s = player.s
	density_gain = 1.0
	window_density = 0.0
	_control_clock = 0.0
	_err_smooth = 0.0
	set_pieces.clear()
	waves.reset(player.s, player.v)
	waves.plan_to(road, player.s + director_tuning.wave_meet_lookahead_m)
	_peak_done = -1
	var batch := director_tuning.spawn_batch_length_m
	_sync_closures(player, player.s + ahead_distance() + batch)
	var a := player.s
	_pass_reset()   # WP6.1
	while a < player.s + ahead_distance():
		var pass_mark := state.next_vehicle_id   # WP6.1
		_batch_a = a
		_batch_b = a + batch
		_plan_range(a, a + batch, player)
		_pass_check_now(a, a + batch, pass_mark, player)   # WP6.1: before anything is drawn
		a += batch
	_spawned_to = a
	_prefilling = false
	_refresh_ctx(player)
	opposite.ahead_m = ahead_distance()
	opposite.reset(player.s, target_density_per_km_lane())


## Per tick, after traffic_sim.step. Allocation-free except when a batch is due.
func step(dt: float, player: VehicleState) -> void:
	_player_s = player.s
	waves.observe_player(dt, player.s, player.v)
	step_despawn(player.s)
	_step_density(dt, player)
	if player.s + ahead_distance() >= _spawned_to:
		var pass_mark := state.next_vehicle_id   # WP6.1: what this batch spawns is checked
		_plan_ahead(player)
		_pass_queue(player.s + min_ahead_m(), _spawned_to, pass_mark)
	_pass_step(dt, player)   # WP6.1
	_step_behind(dt, player)
	set_pieces.step(dt, player)
	opposite.step(dt, player.s)


## Despawns everything 200 m behind the player or beyond the active window ahead.
## Allocation-free.
func step_despawn(player_s: float) -> void:
	var back := player_s - traffic_tuning.despawn_behind_m
	var front := _despawn_front(player_s)
	for i in state.capacity:
		if state.active[i] == 1 and (state.s[i] < back or state.s[i] > front):
			sim.despawn(i)
			despawned += 1


## Lane closures (WP6.2): the road's lane-count changes ahead become the sim's closures
## (mandatory merges, spawn guards), and those behind the despawn line are forgotten.
## Director rate; a sim without closures (a spawn-test fake) is skipped.
func _sync_closures(player: VehicleState, s_to: float) -> void:
	if not sim.has_method(&"sync_road_closures"):
		return
	var back := player.s - traffic_tuning.despawn_behind_m
	road.ensure_generated_to(s_to + traffic_tuning.merge_spawn_clear_m)
	sim.call(&"forget_lane_closures_before", back)
	sim.call(&"sync_road_closures", back, s_to + traffic_tuning.merge_spawn_clear_m)


## Traffic beyond this is despawned (the end of the active window ahead).
func _despawn_front(player_s: float) -> float:
	return player_s + ahead_distance() + director_tuning.spawn_batch_length_m \
		+ traffic_tuning.spawn_despawn_ahead_margin_m


# ---------------------------------------------------------------- Density tracking (plan D11)

## Every density_control_interval_s: measures the effective density in the window and
## integrates its relative shortfall into density_gain (the next batches and behind
## arrivals use it). Allocation-free.
func _step_density(dt: float, player: VehicleState) -> void:
	_control_clock += dt
	var dtun := director_tuning
	if _control_clock < dtun.density_control_interval_s:
		return
	var interval := _control_clock
	_control_clock = 0.0
	window_density = window_density_per_km_lane(player.s)
	# The gain tracks the wave-shaped target (what the window's traffic was planned at),
	# not the flat one, so it never fights the waves.
	var target := target_density_per_km_lane() * waves.window_mult(road.lane_count(player.s),
		dtun.density_window_behind_m, dtun.density_window_ahead_m)
	window_target = target
	if target <= 0.0:
		return
	# The window lags the plan (its traffic was planned 10-80 s ago, in slow-closing lanes
	# longer), so its error against the wave-shaped target wiggles with the waves: only
	# the error's slow part (a low-pass over wave_gain_smoothing_s) is integrated.
	var err := (target - window_density) / target
	_err_smooth += (err - _err_smooth) * minf(interval / dtun.wave_gain_smoothing_s, 1.0)
	density_gain = clampf(density_gain + dtun.density_gain_rate_per_s * _err_smooth * interval,
		dtun.density_gain_min, dtun.density_gain_max)


# ---------------------------------------------------------------- Ahead batches (director rate)

func _plan_ahead(player: VehicleState) -> void:
	var batch := director_tuning.spawn_batch_length_m
	waves.forget_before(player.s - director_tuning.wave_meet_lookahead_m)
	waves.plan_to(road, player.s + director_tuning.wave_meet_lookahead_m)
	_sync_closures(player, player.s + ahead_distance() + batch * 2.0)
	while player.s + ahead_distance() >= _spawned_to:
		var a := maxf(_spawned_to, player.s + min_ahead_m())
		_batch_a = a
		_batch_b = a + batch
		_refresh_ctx(player)
		_schedule_set_piece(a, a + batch, player)
		_clear_for_set_piece(a, a + batch, player)
		_plan_range(a, a + batch, player)
		set_pieces.bind_committed()
		_spawned_to = a + batch
	_top_up_band(player)


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


# ---------------------------------------------------------------- Band top-up (plan D11, director rate)

## The planned band beyond the fog, [player s + min_ahead_m(), spawned_to()), is what
## a player faster than a lane meets next. Flow's renewal plans each batch around the
## live traffic that drifted into it, and a fast live follower or a truck's s* can
## leave it thinner than the target, so after each batch every lane the player is
## catching (flow speed + density_topup_speed_margin_kmh below the player's speed) is
## topped up to target x gain in the band: one vehicle at a time, largest gap first,
## where Flow's drawn vehicle keeps s* to both neighbors and the player, through the
## commit rules (cap, ghost zone, beyond the fog, live gaps). Lanes the
## player is not catching are left alone (what spawns there never reaches it; behind
## spawns feed the left lanes). Director rate: allocates.
func _top_up_band(player: VehicleState) -> void:
	var lo := player.s + min_ahead_m()
	var hi := _spawned_to
	if hi <= lo or density_gain <= 0.0:
		return
	_refresh_ctx(player)
	var lanes := road.lane_count(lo)
	var margin := Units.kmh_to_mps(director_tuning.density_topup_speed_margin_kmh)
	var budget := director_tuning.density_topup_max_per_batch
	for lane in lanes:
		if budget <= 0:
			return
		var v_lane := traffic_tuning.lane_flow_speed_mps(lane, lanes)
		if v_lane + margin > player.v:
			continue
		budget -= _top_up_lane(lane, lo, hi, _band_want(v_lane, lo, hi), budget, player)


## Vehicles a lane at `v_lane` should hold in the band [lo, hi): the wave-shaped,
## blind-capped planning density integrated over the band (WP6.2).
func _band_want(v_lane: float, lo: float, hi: float) -> float:
	var n := maxi(director_tuning.wave_window_samples, 1)
	var sum := 0.0
	for k in n:
		sum += waves.density_at(v_lane, lerpf(lo, hi, (float(k) + 0.5) / float(n)))
	return sum / float(n) * (hi - lo) / Units.M_PER_KM


## Tops `lane` up toward `want` vehicles in [lo, hi); returns how many it added. Gaps
## are tried largest first; in a gap the new vehicle goes in the middle of the stretch
## where it keeps s* to both live neighbors (closing speeds included), and a gap where
## that stretch is empty is skipped.
func _top_up_lane(lane: int, lo: float, hi: float, want: float, budget: int, player: VehicleState) -> int:
	var reach := traffic_tuning.idm_lookahead_m
	var slots: Array[int] = []
	var inside := 0
	for i in state.capacity:
		if state.active[i] == 0 or state.s[i] < lo - reach or state.s[i] > hi + reach:
			continue
		if not SpawnSources.occupies_lane(state, i, lane, road):
			continue
		slots.append(i)
		if state.s[i] >= lo and state.s[i] < hi:
			inside += 1
	var need := mini(floori(want - float(inside) + 0.5), budget)
	if need <= 0:
		return 0
	slots.sort_custom(func(x: int, y: int) -> bool: return state.s[x] < state.s[y])
	var lanes := road.lane_count(lo)
	var v_lane := traffic_tuning.lane_flow_speed_mps(lane, lanes)
	var tried: Dictionary = {}   # follower slot (-1 = the band's start) -> gap already tried
	var added := 0
	while added < need:
		# The largest untried gap overlapping the band, weighted by the wave's density
		# where it lies (a gap as large as the wave asks for there counts the same
		# everywhere), and never where the wave is below wave_fill_min_mult (WP6.2:
		# breathers and blind windows stay thin): between follower f and leader l (-1 =
		# open end, bounded by the band).
		var best := -1.0
		var bf := -2
		var bl := -1
		for k in slots.size() + 1:
			var f := slots[k - 1] if k > 0 else -1
			var l := slots[k] if k < slots.size() else -1
			var a := state.s[f] if f >= 0 else lo
			var b := state.s[l] if l >= 0 else hi
			if b <= lo or a >= hi or tried.has(f):
				continue
			var gap := minf(b, hi) - maxf(a, lo)
			var m := waves.density_mult(v_lane, (minf(b, hi) + maxf(a, lo)) * 0.5)
			if m < waves.fill_min_mult():
				continue   # never into a breather or a blind window
			gap *= m
			if gap > best:
				best = gap
				bf = f
				bl = l
		if bf == -2:
			break
		tried[bf] = true
		if not flow.draw_into(ctx, ctx.rng, lane, lanes, 0.0, _topup_rec):
			break
		var ln := flow.length_of(_topup_rec.type_id)
		var from := lo
		var to := hi
		if bf >= 0:
			from = maxf(from, state.s[bf] + flow.min_spacing(state.profile_id[bf], state.v[bf], state.length[bf],
				_topup_rec.v, ln))
		if bl >= 0:
			to = minf(to, state.s[bl] - flow.min_spacing(_topup_rec.profile_id, _topup_rec.v, ln, state.v[bl],
				state.length[bl]))
		if to <= from:
			continue
		_topup_rec.s = (from + to) * 0.5
		if not flow.lane_open_for_spawn(road, lane, _topup_rec.s) or not set_pieces.keeps_clear(_topup_rec) \
				or not flow.fits_between_neighbors_into(ctx, _topup_rec) or not _commit(_topup_rec, player):
			continue
		added += 1
		spawned_ahead += 1
		spawned_topup += 1
		# The new vehicle splits the gap: its two halves are new, untried gaps.
		var slot := _last_slot
		var at := slots.bsearch_custom(slot, func(x: int, y: int) -> bool: return state.s[x] < state.s[y])
		slots.insert(at, slot)
		tried.erase(bf)
	return added


# ---------------------------------------------------------------- Behind spawns (per tick)

## Faster traffic arriving from behind while the player is slower than a left lane:
## each lane owes density x (v_lane - v_player) arrivals per second; one is spawned at
## spawn_behind_m behind when owed, the point is out of the frustum and the gaps fit.
## Allocation-free.
func _step_behind(dt: float, player: VehicleState) -> void:
	var lanes := mini(road.lane_count(player.s), _behind_debt.size())
	var left_lanes := maxi(mini(traffic_tuning.spawn_behind_lane_count, lanes - 1), 1)
	var margin := Units.kmh_to_mps(traffic_tuning.spawn_behind_speed_margin_kmh)
	# Arrivals from behind pass the player now: the wave where the player is.
	var rate := waves.base_density * waves.mult_at(player.s) / Units.M_PER_KM
	for lane in _behind_debt.size():
		if lane >= left_lanes:
			_behind_debt[lane] = 0.0
			continue
		var v_lane := traffic_tuning.lane_flow_speed_mps(lane, lanes)
		if v_lane <= player.v + margin:
			_behind_debt[lane] = 0.0
			continue
		_behind_debt[lane] = minf(_behind_debt[lane] + rate * (v_lane - player.v) * dt, 1.0)
		if _behind_wait[lane] > 0.0:
			_behind_wait[lane] -= dt
			continue
		if _behind_debt[lane] < 1.0:
			continue
		if _step_try_behind(lane, player, player.v + margin):
			_behind_debt[lane] = 0.0
		else:
			# Visible, or the gaps don't fit: retry later, not every tick (each attempt
			# draws a vehicle and scans the lane).
			_behind_wait[lane] = traffic_tuning.spawn_behind_retry_s


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

## True when the road point (s, d) counts as in view (fairness rule 5): anything ahead
## of player s - behind_spawn_view_margin_m (a fixed virtual view volume: every camera
## mode sits <= 11 m behind the car and looks forward), unless a frustum_check
## override is set. Pure and camera-independent. Allocation-free.
func is_visible(s: float, d: float) -> bool:
	if frustum_check.is_valid():
		return bool(frustum_check.call(s, d))
	return s > _player_s - director_tuning.behind_spawn_view_margin_m


## True when a box at (s, d) with the given size overlaps the ghost zone.
func overlaps_ghost_zone(s: float, d: float, length_m: float, width_m: float, player: VehicleState) -> bool:
	return s + length_m * 0.5 > player.s - ghost_behind_m and s - length_m * 0.5 < player.s + ghost_ahead_m \
		and d + width_m * 0.5 > player.d - ghost_half_width_m and d - width_m * 0.5 < player.d + ghost_half_width_m


## Every spawn goes through here: cap, ghost zone, no pop-in, the live-traffic gap,
## then the sim. Allocation-free.
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
	if not keeps_live_gaps(rec):
		rejected_overlap += 1
		return false
	var slot: int = sim.spawn(rec)
	_last_slot = slot
	return slot >= 0


## Final spawn-gap check against live traffic, whatever the source planned: `rec` must
## keep IDM's s* (closing speed included) to every live vehicle occupying its lane
## (SpawnSources.occupies_lane: lane changers and lane-splitting bikes count), in
## whichever order they drive. Allocation-free.
func keeps_live_gaps(rec: SpawnSource.Record) -> bool:
	var ln := flow.length_of(rec.type_id)
	for i in state.capacity:
		if state.active[i] == 0 or not SpawnSources.occupies_lane(state, i, rec.lane, road):
			continue
		var ahead := state.s[i] - rec.s
		if ahead >= 0.0:
			if ahead < flow.min_spacing(rec.profile_id, rec.v, ln, state.v[i], state.length[i]):
				return false
		elif -ahead < flow.min_spacing(state.profile_id[i], state.v[i], state.length[i], rec.v, ln):
			return false
	return true


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
	# Waves and blind caps (WP6.2): the representative of the batch being planned (its
	# middle, the middle lane's flow speed); Flow plans each lane and position at the
	# shaper's own density. Set pieces only for the batch a piece was scheduled into.
	var base := target_density_per_km_lane() * density_gain
	waves.base_density = base
	var lanes := maxi(road.lane_count(_batch_a), 1)
	var v_mid := traffic_tuning.lane_flow_speed_mps(lanes >> 1, lanes)
	var s_mid := (_batch_a + _batch_b) * 0.5
	ctx.intensity = waves.intensity_at(waves.meet_x(v_mid, s_mid))
	waves.ref_mult = waves.density_mult(v_mid, s_mid)
	ctx.density_per_km_lane = base * waves.ref_mult
	ctx.aggressive_share = director_tuning.aggressive_share_frac(leg)
	ctx.hesitant_allowed = leg >= director_tuning.hesitant_first_leg
	ctx.set_pieces_allowed = set_pieces.has_pending_in(_batch_a, _batch_b)
	ctx.is_night = is_night
	ctx.biome = biome


# ---------------------------------------------------------------- Passability (WP6.1: the commit path)
#
# Spec: Traffic → Passability guarantee ("Before committing any spawn batch (the next
# ~300 m), the director runs passability.gd ... Without one, re-roll the batch (up to 5
# times), then remove the vehicle that blocks the most paths"). A batch is committed
# beyond the fog (fairness rule 5), then checked there while it is still invisible:
# the check is time-sliced (Passability.advance, director_slices_per_tick per tick), and
# a re-roll or a removal only ever despawns vehicles beyond min_ahead_m(), so the
# player never sees a batch that failed. Every source's batches take this path (Flow,
# Daily, SetPiece: scripted batches are counted in pass_scripted_batches); a re-roll
# plans the range again with the same source on the passability stream. A set piece's
# own vehicles are checked like any other but never re-rolled or removed (its
# controller owns them; every piece keeps a followable path at >= min speed + margin).
# Deterministic: fixed slices per tick, a derived stream, no wall-clock budget.

## The passability module (null until set_player_params: then the director checks).
var passability: Passability
## The player car's physics params (lane-change capability curve, acceleration).
var player_params: VehicleParams
## Result of the last finished batch check.
var pass_result := Passability.Result.new()
## Keep the arrival paths the checks found (the sandbox's PASS overlay). Off in the game.
var record_pass_paths := false
## The last PASS_PATHS_KEPT paths found: s and d per point (t = k x step_s).
var pass_paths_s: Array[PackedFloat64Array] = []
var pass_paths_d: Array[PackedFloat64Array] = []
const PASS_PATHS_KEPT := 4
## Queued ranges (a batch while another is still being checked).
const PASS_QUEUE := 8

# Stats (soak, sandbox, tests).
var pass_batches := 0          ## ranges checked
var pass_scripted_batches := 0 ## ... containing set-piece (scripted) vehicles
var pass_checks := 0           ## checks run (a range + its re-rolls and removals)
var pass_failed := 0           ## checks without a path
var pass_rerolls := 0
var pass_removed := 0          ## blockers removed
var pass_unresolved := 0       ## ranges still failing after the removals (committed as they are)
var pass_probes := 0
var pass_ticks_max := 0        ## longest range verification, in ticks
var pass_log: Array[String] = []   ## failures, for soak reports (director rate)
const PASS_LOG_MAX := 24

var _pass_rng: Rng
var _pass_busy := false
var _pass_a := 0.0
var _pass_b := 0.0
var _pass_mark := 0
var _pass_rerolls_left := 0
var _pass_removals_left := 0
var _pass_ticks := 0
var _pass_ids := PackedInt32Array()     ## vehicle_id per slot when the check began
var _pass_qa := PackedFloat64Array()
var _pass_qb := PackedFloat64Array()
var _pass_qm := PackedInt32Array()
var _pass_qn := 0


## Enables passability: the player car's params (VehicleParams.build). run.gd, the
## soak, the sandbox. null disables it again.
func set_player_params(params: VehicleParams) -> void:
	player_params = params
	if params != null and passability == null:
		var reg := TrafficRegistry.new(flow.profiles, flow.types, traffic_tuning)
		passability = Passability.new(run.tuning, reg, road)
		_pass_rng = run.rng_traffic.derive(&"passability")
		_pass_ids.resize(state.capacity)
		_pass_qa.resize(PASS_QUEUE)
		_pass_qb.resize(PASS_QUEUE)
		_pass_qm.resize(PASS_QUEUE)
	if passability != null:
		passability.set_player_body(flow.player_length_m, flow.player_width_m)


## True when committed batches are checked.
func passability_active() -> bool:
	return passability != null and player_params != null and run.tuning.passability.director_enabled


## True while a committed range is still being checked (or re-rolled).
func passability_busy() -> bool:
	return _pass_busy or _pass_qn > 0


func _pass_reset() -> void:
	_pass_busy = false
	_pass_qn = 0
	pass_batches = 0
	pass_scripted_batches = 0
	pass_checks = 0
	pass_failed = 0
	pass_rerolls = 0
	pass_removed = 0
	pass_unresolved = 0
	pass_probes = 0
	pass_ticks_max = 0
	pass_log.clear()
	pass_paths_s.clear()
	pass_paths_d.clear()


## A committed range [a, b) (its vehicles: vehicle_id >= mark) to check. Director rate.
func _pass_queue(a: float, b: float, mark: int) -> void:
	if not passability_active() or b <= a:
		return
	if _pass_qn >= PASS_QUEUE:
		# Merge into the last queued range (it only grows the checked stretch).
		_pass_qb[_pass_qn - 1] = maxf(_pass_qb[_pass_qn - 1], b)
		return
	_pass_qa[_pass_qn] = a
	_pass_qb[_pass_qn] = b
	_pass_qm[_pass_qn] = mark
	_pass_qn += 1


## Per tick: starts the next queued range and advances the running check.
func _pass_step(_dt: float, player: VehicleState) -> void:
	if not _pass_busy:
		if _pass_qn == 0 or not passability_active():
			return
		_pass_begin(_pass_qa[0], _pass_qb[0], _pass_qm[0], player)
		for i in range(1, _pass_qn):
			_pass_qa[i - 1] = _pass_qa[i]
			_pass_qb[i - 1] = _pass_qb[i]
			_pass_qm[i - 1] = _pass_qm[i]
		_pass_qn -= 1
	_pass_ticks += 1
	if passability.advance(run.tuning.passability.director_slices_per_tick):
		_pass_done(player)


## Start of run: the prefilled range is checked, re-rolled and cleared at once.
func _pass_check_now(a: float, b: float, mark: int, player: VehicleState) -> void:
	if not passability_active():
		return
	_pass_begin(a, b, mark, player)
	while _pass_busy:
		passability.advance(Passability.ALL_SLICES)
		_pass_done(player)


func _pass_begin(a: float, b: float, mark: int, player: VehicleState) -> void:
	_pass_busy = true
	_pass_a = a
	_pass_b = b
	_pass_mark = mark
	_pass_ticks = 0
	_pass_rerolls_left = run.tuning.passability.max_rerolls
	_pass_removals_left = run.tuning.passability.max_removals
	pass_batches += 1
	for i in state.capacity:
		if state.active[i] == 1 and state.vehicle_id[i] >= mark and state.s[i] >= a and state.s[i] < b \
				and state.has_flag(i, TrafficState.FLAG_SCRIPTED):
			pass_scripted_batches += 1
			break
	_pass_start_check(player)


func _pass_start_check(player: VehicleState) -> void:
	for i in state.capacity:
		_pass_ids[i] = state.vehicle_id[i] if state.active[i] == 1 else -1
	passability.clear_planned()
	passability.set_headway_scale(director_tuning.headway_scale(leg))
	passability.record_paths = record_pass_paths
	passability.begin_check(state, player, player_params, road, Passability.MODE_ARRIVAL, _pass_a, _pass_b,
		pass_result)


## A check finished: commit (keep), re-roll, remove the worst blocker, or give up.
func _pass_done(player: VehicleState) -> void:
	pass_checks += 1
	pass_probes += pass_result.probes
	if pass_result.passable:
		_pass_finish(player)
		return
	pass_failed += 1
	if _pass_rerolls_left > 0:
		_pass_rerolls_left -= 1
		pass_rerolls += 1
		_pass_reroll(player)
		_pass_start_check(player)
		return
	if _pass_removals_left > 0:
		_pass_removals_left -= 1
		var o := pass_result.worst_blocker(_pass_removable.bind(player))
		if o >= 0:
			sim.despawn(pass_result.blocker_src[o])
			pass_removed += 1
			_pass_start_check(player)
			return
	pass_unresolved += 1
	if pass_log.size() < PASS_LOG_MAX:
		pass_log.append("unresolved at s %.0f (range %.0f..%.0f, player %.0f km/h, leg %d): %d probes, %d failed" % [
			pass_result.fail_s, _pass_a, _pass_b, player.v / Units.kmh_to_mps(1.0), leg, pass_result.probes,
			pass_result.failed_probes])
	_pass_finish(player)


func _pass_finish(_player: VehicleState) -> void:
	_pass_busy = false
	pass_ticks_max = maxi(pass_ticks_max, _pass_ticks)
	if record_pass_paths and pass_result.path_n > 1:
		var ps := PackedFloat64Array()
		var pd := PackedFloat64Array()
		for k in pass_result.path_n:
			ps.append(pass_result.path_s[k])
			pd.append(pass_result.path_d[k])
		pass_paths_s.append(ps)
		pass_paths_d.append(pd)
		if pass_paths_s.size() > PASS_PATHS_KEPT:
			pass_paths_s.remove_at(0)
			pass_paths_d.remove_at(0)


## A vehicle the director may still remove: live, the one the check saw, and never
## visible (beyond min_ahead_m(), or anywhere during the prefill).
func _pass_removable(src: int, player: VehicleState) -> bool:
	if src < 0 or state.active[src] == 0 or state.vehicle_id[src] != _pass_ids[src]:
		return false
	if state.has_flag(src, TrafficState.FLAG_SCRIPTED):
		return false   # a set piece's vehicle: its controller owns it (the piece is passable by design)
	return _prefilling or state.s[src] - player.s >= min_ahead_m()


## Re-roll: the range's own vehicles still beyond the fog are despawned and the range
## planned again (same source, the passability stream), then committed through the
## usual rules. A set piece's vehicles (FLAG_SCRIPTED, already bound to its controller)
## stay: only the filler around the piece is drawn again (SetPieceSource keeps it clear).
func _pass_reroll(player: VehicleState) -> void:
	var lo := _pass_a
	for i in state.capacity:
		if state.active[i] == 1 and state.vehicle_id[i] >= _pass_mark and state.s[i] >= lo and state.s[i] < _pass_b \
				and not state.has_flag(i, TrafficState.FLAG_SCRIPTED) \
				and (_prefilling or state.s[i] - player.s >= min_ahead_m()):
			sim.despawn(i)
	var keep := _rng
	var keep_a := _batch_a
	var keep_b := _batch_b
	_rng = _pass_rng
	_batch_a = maxf(lo, player.s + (0.0 if _prefilling else min_ahead_m()))
	_batch_b = _pass_b
	_plan_range(_batch_a, _batch_b, player)
	_rng = keep
	_batch_a = keep_a
	_batch_b = keep_b


# ---------------------------------------------------------------- Set pieces (WP6.2, director rate)

## Wave peaks get set pieces here, one batch at a time, before the batch is planned.
## The next peak ahead (IntensityWaves.next_peak) is handled once:
##   - its seeded chance draw against set_piece_chance_frac(leg), then its seeded kind
##     draw through SetPieceSource.pick (leg unlocks, the biome's mix, lanes);
##   - the piece must be met by the player at the peak's middle: planned now at
##     s = player s + (x - player s) (pace - v) / pace (the meeting map at the piece's
##     speed v). While that is beyond this batch, wait; if it is already behind the
##     batch start, the batch start is used as long as the player still meets it in the
##     peak;
##   - _set_piece_fits: enough lanes, no vehicle of it hidden beyond a blind crest or bend
##     while the player drives it (rule 6), met clear of checkpoints, and no lane-count
##     change, tunnel or fork on the road it drives until it ends.
## Then SetPieceSource.schedule() and ctx.set_pieces_allowed for this batch.
func _schedule_set_piece(a: float, b: float, player: VehicleState) -> void:
	if not set_pieces_enabled or source != set_pieces or _prefilling or not set_pieces.can_schedule():
		return
	var lanes := road.lane_count(a)
	if _forced != null:
		_schedule_forced(a, b, lanes)
		return
	var k := waves.next_peak(player.s, _peak_done)
	if k < 0:
		return
	var id := waves.seg_id[k]
	if waves.seg_u_chance[k] >= director_tuning.set_piece_chance_frac(leg):
		_peak_handled(id)
		peaks_no_chance += 1
		return
	var def := set_pieces.pick(leg, biome, waves.seg_u_kind[k], lanes)
	if def == null:
		_peak_handled(id)
		peaks_no_kind += 1
		return
	var x0 := waves.seg_x0[k]
	var x1 := waves.seg_x1[k]
	var v := def.speed_mps(set_pieces.min_speed_mps)
	var pace := waves.pace
	if pace <= v + _closing_floor:
		if x1 <= player.s + ahead_distance():
			_peak_handled(id)   # the player is too slow to meet a piece in this peak
			peaks_missed += 1
		return
	var s_req := player.s + ((x0 + x1) * 0.5 - player.s) * (pace - v) / pace
	if s_req >= b:
		return   # a later batch
	_peak_handled(id)
	s_req = maxf(s_req, a)
	if waves.meet_x(v, s_req) > x1 or s_req - player.s \
			> (pace - v) * def.approach_max_s * Units.pct_to_frac(director_tuning.set_piece_meet_max_pct):
		peaks_missed += 1   # met beyond the peak, or too late at this pace
		return
	if not _set_piece_fits(def, v, s_req, lanes):
		peaks_unfit += 1
		return
	set_pieces.schedule(def, s_req, lanes, v)


## A set piece scheduled into [a, b) gets its footprint (clear_behind_m .. clear_ahead_m
## around it) cleared of live traffic that drifted into the new batch, and, ahead of it
## in its lanes, of slower traffic it would catch up with before it ends (so the
## formation holds), as long as that traffic is beyond the fog (min_ahead_m(): the same
## line no ahead spawn may cross, so the removal is as invisible as a spawn there).
## (The piece's lanes are not known before it is laid out: all of them count then.)
func _clear_for_set_piece(a: float, b: float, player: VehicleState) -> void:
	if not set_pieces.has_pending_in(a, b):
		return
	var inst: SetPieceSource.Instance = null
	for x in set_pieces.instances:
		if x.stage == SetPieceSource.Stage.SCHEDULED and x.s_rear >= a and x.s_rear < b:
			inst = x
	var lo := inst.s_rear - inst.def.clear_behind_m
	var hi := inst.s_front + inst.def.clear_ahead_m
	var hidden := player.s + min_ahead_m()
	for i in state.capacity:
		if state.active[i] == 0 or state.s[i] - state.length[i] * 0.5 < hidden or state.s[i] < lo:
			continue
		# The piece's zone in every lane; beyond it, in the piece's lanes, what it would
		# catch up with before it ends.
		if state.s[i] <= hi or (set_pieces.occupies(inst, state.lane[i]) and state.s[i] <= inst.s_front
				+ set_pieces.catch_reach(inst, state.profile_id[i], state.v[i], state.length[i])):
			sim.despawn(i)
			despawned_for_set_pieces += 1


func _peak_handled(id: int) -> void:
	_peak_done = id
	peaks_seen += 1


func _schedule_forced(a: float, b: float, lanes: int) -> void:
	var def := _forced
	var v := def.speed_mps(set_pieces.min_speed_mps)
	_forced_tries -= 1
	if lanes >= def.min_lanes and _set_piece_fits(def, v, a, lanes):
		_forced = null
		set_pieces.schedule(def, minf(a, b), lanes, v)
	elif _forced_tries <= 0:
		_forced = null   # no stretch within reach fits (e.g. blind all along at this pace)


## Rule 6 and the road for a piece of `def` at speed `v` with its rear at `s`
## (SetPieceSource.fits_road; the source checks again where it finally lays it out).
func _set_piece_fits(def: SetPieceDef, v: float, s: float, lanes: int) -> bool:
	return set_pieces.fits_road(def, v, s, def.length_m, lanes, road)


## Dev (sandbox) and tests: the next ahead batch where a `id` set piece fits the road
## and rule 6 gets one, wave or not (dropped after FORCED_TRIES batches). False when
## there is no such set piece or one is already live.
func force_set_piece(id: StringName) -> bool:
	var def: SetPieceDef = set_pieces.defs.get(id)
	if def == null or SetPieceSource.controller_for(def.kind) == null or not set_pieces.can_schedule():
		return false
	_forced = def
	_forced_tries = FORCED_TRIES
	return true


## The wave intensity the player is in now (0 breather .. 1 peak).
func intensity_now() -> float:
	return waves.intensity_at(_player_s)
