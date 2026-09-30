class_name SetPieceSource
extends SpawnSource
## The SetPiece SpawnSource and the set-piece runtime (WP6.2). Spec: Traffic → Traffic
## director (built-in sources Flow, SetPiece, Daily; "peak (often a set piece)"; "set
## piece variety grows"; the set-piece table); Fairness rules 4 ("no deceleration above
## 6 m/s² except in set pieces announced at least 300 m ahead") and 6 (no set pieces
## within 150 m after a blind crest or bend). Framework and API: docs/SET_PIECES.md.
##
## The director's ahead source: plan_batch() lays out the scheduled piece (if its batch
## is the one being planned) through the piece's Controller and fills the rest of the
## batch with Flow (Daily in Daily Drive), keeping Flow clear of every live piece. So a
## piece goes through the director's commit path (cap, ghost zone, no pop-in, live gaps,
## passability) like any batch. The director decides WHEN (wave peaks, blind windows,
## checkpoints, leg unlocks, biome mix: TrafficDirector._schedule_set_piece); this
## source decides WHAT and runs it:
##
##   1. schedule(def, s_rear, lanes, speed): an Instance (SCHEDULED) with the kind's
##      Controller. plan_batch() calls controller.plan() for its records (FLAG_SCRIPTED,
##      rec.set_piece = def.id, v = v0 = the piece's speed).
##   2. bind_committed() after the commit: every committed record's slot joins the
##      instance (RUNNING; `spawned` counts it); a piece with no vehicle left is dropped.
##   3. step(dt, player) per tick (allocation-free): warnings as the player's distance to
##      the piece's rear comes down to each warning distance (KIND_WARNING: tag = id,
##      value = the distance, points = the instance serial), KIND_STARTED when the
##      player comes within start_distance_m of the rear, the controller's behaviour,
##      and the end (the piece rolling to within clear_ahead_m of a lane-count change,
##      tunnel or fork (they merge like any traffic then), player
##      end_margin_m past the front, duration_max_s, or no vehicle left): every vehicle
##      is released to ordinary traffic (its natural desired speed, MOBIL back on) and
##      KIND_ENDED fires if the piece was announced.
##   4. Rule 4: vehicles of a piece with allows_hard_decel get the sim's hard-decel
##      permission only when its first warning came >= set_piece_min_warning_m ahead.
##
## Controllers script vehicles only through TrafficSim's hooks (set_scripted_v0,
## scripted_brake_tap, request_lane_change, set_hard_decel_allowed, release_scripted),
## and only when the sim has them (a spawn-test fake does not: pieces then just roll).
## New kinds (WP6.3): a Controller subclass + a line in controller_for() + a data file.
##
## Road-anchored pieces (WP6.3: merge zone, road works, tunnel squeeze, toll gantry;
## SetPieceDef.anchored) have a zone fixed on the road. schedule_zone() lays the zone
## out (Controller.setup_zone: seeded layout, road hooks: lane counts, rail gaps, lane
## closures, speed and headway zones) well beyond the view (schedule_lead_min_m), and
## the piece runs at once (RUNNING, `spawned` counts it) with or without vehicles. Its
## warnings count down to the zone, it starts and ends by the player's position on the
## zone, and its road hooks go at the end (Controller.on_end). Vehicles it has are
## planned later, in the batch where Controller.vehicles_rear_s() falls (the meeting
## map), through the same commit path, and bound to the running piece.
## Rolling pieces (WP6.3: slalom, convoy) work like the WP6.2 pieces; formations keep
## their shape with Controller.keep_formation().
## The pieces are in src/traffic/set_pieces/.

const KIND_WARNING := &"set_piece_warning"   ## tag = SetPieceDef id, value = distance (m), points = serial
const KIND_STARTED := &"set_piece_started"   ## tag = id, points = serial
const KIND_ENDED := &"set_piece_ended"       ## tag = id, points = serial
const STREAM := &"set_pieces"
const DEF_DIR := "res://data/set_pieces/"
## Pools (structural): instances alive at once, vehicles per instance.
const MAX_INSTANCES := 4
const MAX_VEHICLES := 24

enum Stage { FREE, SCHEDULED, RUNNING }

var tuning: DirectorTuning
var flow: SpawnSources.Flow
var waves: IntensityWaves
## Duck-typed sim (TrafficSim or a fake): `state`, and the set-piece hooks if present.
var sim: Object
## The sim when it is a TrafficSim (null for a fake): its speed zones (spawn_speed_ok).
var zone_sim: TrafficSim
var state: TrafficState
## The road (the director sets it): road-anchored pieces lay their zones out on it.
var road: RoadPath
## Loaded SetPieceDefs by id (every id of set_piece_unlock_order with a data file).
var defs: Dictionary = {}
## Where set-piece events go (null = nowhere). The run's buffer, drained by RunEvents.
var events: ScoreEventBuffer
## Draws of the pieces (layouts, open lanes, gaps): run.rng_traffic.derive(STREAM).
var rng: Rng
## Scripted speeds never go below this (minimum speed + set_piece_min_speed_margin_kmh).
var min_speed_mps: float
## WP9.6 (ACCEPTANCE F2): the player's pace a rolling piece's road fit assumes (the
## director sets it: the faster of the waves' smoothed pace and the player's cruising
## pace; 0 = the waves' pace). See meet_x().
var meet_pace: float = 0.0
## True when the sim has the scripting hooks.
var can_script: bool = false
## True when the sim has the WP6.3 zone hooks (lane closures, speed / headway zones,
## merge holds).
var can_zone: bool = false

var instances: Array[Instance] = []

# Stats (metrics, sandbox, tests).
var spawned: int = 0
var started: int = 0
var ended: int = 0
var spawned_by_kind: Dictionary = {}   ## id -> pieces spawned
## Scheduled pieces dropped: no room in live traffic in their batch / none committed.
var unplaced: int = 0
var uncommitted: int = 0
## Why pieces ended: the player passed, duration_max_s after the start, approach_max_s
## without the player reaching it, rolling into a lane drop / tunnel / fork, no vehicle left.
var ended_passed: int = 0
var ended_duration: int = 0
var ended_unmet: int = 0
var ended_zone: int = 0
var ended_empty: int = 0
## fits_road refusals by reason (dev, soak): lanes, blind windows, checkpoints, road zones.
var unfit_lanes: int = 0
var unfit_blind: int = 0
var unfit_checkpoint: int = 0
var unfit_road: int = 0
## Road-anchored pieces (WP6.3) whose zone overlapped a live piece's, and whose road
## hooks could not be set up.
var unfit_live: int = 0
var unfit_setup: int = 0

var _serial: int = 0
var _slot_serial := PackedInt32Array()   ## per slot: the instance serial it belongs to
var _slot_vid := PackedInt32Array()      ## ... valid while the slot keeps this vehicle_id
var _flow_tmp: Array[SpawnSource.Record] = []


## A scheduled or running set piece (pooled: MAX_INSTANCES, reused).
class Instance:
	extends RefCounted
	var stage: Stage = Stage.FREE
	var serial: int = -1
	var def: SetPieceDef
	var controller: Controller
	var lanes: int = 0
	var speed: float = 0.0            ## m/s, the matched speed
	var s_rear: float = 0.0           ## planned rear box edge (SCHEDULED), live (RUNNING)
	var s_front: float = 0.0          ## planned / live front box edge
	var planned: bool = false         ## plan_batch laid it out in the batch being committed
	var records: Array[SpawnSource.Record] = []
	var rec_natural_v0 := PackedFloat64Array()
	var rec_row := PackedInt32Array()
	## Bound vehicles (RUNNING): slot, vehicle id, formation lane, row, natural v0.
	var n: int = 0
	var slot := PackedInt32Array()
	var vid := PackedInt32Array()
	var lane := PackedInt32Array()
	var row := PackedInt32Array()
	var natural_v0 := PackedFloat64Array()
	var age: float = 0.0              ## since it spawned (bound)
	var run_s: float = 0.0            ## since it started
	var next_warning: int = 0
	var warned_m: float = -1.0        ## the player's distance at the first warning (-1: none)
	var announced: bool = false
	var did_start: bool = false
	## Road-anchored pieces (WP6.3): the zone on the road, where the warnings count to,
	## and whether vehicles are still to be planned (vehicles_rear_s() each batch).
	var zone_s0: float = 0.0
	var zone_s1: float = 0.0
	var warn_s: float = 0.0
	var pending_vehicles: bool = false
	## Formation keeping (Controller.keep_formation): the reference line and each bound
	## vehicle's slot offset from it.
	var ref_s: float = 0.0
	var slot_off := PackedFloat64Array()
	## The player's s at the last step (views, the prop query).
	var player_s: float = 0.0

	func _init() -> void:
		slot.resize(MAX_VEHICLES)
		vid.resize(MAX_VEHICLES)
		lane.resize(MAX_VEHICLES)
		row.resize(MAX_VEHICLES)
		natural_v0.resize(MAX_VEHICLES)
		slot_off.resize(MAX_VEHICLES)

	## True for a road-anchored piece (WP6.3).
	func is_anchored() -> bool:
		return def != null and def.anchored

	## Planned length of the piece's footprint along the road (m).
	func span() -> float:
		return s_front - s_rear


## A set piece's behaviour. plan() and on_bound() are director rate; step() and
## on_warning() run in the tick and must not allocate.
class Controller:
	extends RefCounted

	## Appends the piece's records via src.add_record() (their s from inst.s_rear on).
	func plan(_src: SetPieceSource, _ctx: SpawnSource.Context, _inst: Instance) -> void:
		pass

	func on_bound(_src: SetPieceSource, _inst: Instance) -> void:
		pass

	## The first and every later warning (index into warning_sign_distances_m).
	func on_warning(_src: SetPieceSource, _inst: Instance, _index: int) -> void:
		pass

	func step(_src: SetPieceSource, _inst: Instance, _dt: float, _player: VehicleState) -> void:
		pass

	## Road-anchored pieces (WP6.3): lays the zone out from inst.zone_s0 (inst.zone_s1,
	## the seeded layout) and puts its road hooks on the road and in the sim (tag =
	## inst.serial). False when it cannot (then nothing was changed). Director rate.
	func setup_zone(_src: SetPieceSource, _inst: Instance) -> bool:
		return true

	## Road-anchored pieces: where the rear of the piece's vehicles is planned now (the
	## meeting map to zone_s0 + zone_meet_m by default), INF when it has none. Director rate.
	func vehicles_rear_s(src: SetPieceSource, inst: Instance) -> float:
		if inst.def.vehicles_max <= 0:
			return INF
		return src.meet_plan_s(inst.speed, inst.zone_s0 + inst.def.zone_meet_m)

	## The piece ended: take its road hooks back out of the sim (the road keeps its lane
	## counts and rail gaps, which are behind the player by then). Director rate.
	func on_end(src: SetPieceSource, inst: Instance) -> void:
		src.remove_sim_hooks(inst)

	## Formation keeping (tick, allocation-free): each vehicle's desired speed is the
	## piece's speed + formation_gain_per_s x its lag behind its slot on the reference
	## line (advancing at the piece's speed), within +- formation_limit_kmh.
	func keep_formation(src: SetPieceSource, inst: Instance, dt: float) -> void:
		inst.ref_s += inst.speed * dt
		var d := inst.def
		var lim := Units.kmh_to_mps(d.formation_limit_kmh)
		for k in inst.n:
			if not src.controllable(inst, k):
				continue
			var lag := inst.ref_s + inst.slot_off[k] - src.state.s[inst.slot[k]]
			src.set_v0(inst, k, inst.speed + clampf(lag * d.formation_gain_per_s, -lim, lim))

	## Formation keeping: the current layout becomes the formation (on_bound).
	func mark_formation(src: SetPieceSource, inst: Instance) -> void:
		inst.ref_s = inst.s_rear
		for k in inst.n:
			inst.slot_off[k] = src.state.s[inst.slot[k]] - inst.ref_s


## The controller of a kind, or null while that kind is not implemented.
static func controller_for(kind: SetPieceDef.Kind) -> Controller:
	match kind:
		SetPieceDef.Kind.TRUCK_WALL:
			return TruckWall.new()
		SetPieceDef.Kind.ROLLING_ROADBLOCK:
			return RollingRoadblock.new()
		SetPieceDef.Kind.MERGE_ZONE:
			return MergeZonePiece.new()
		SetPieceDef.Kind.ROAD_WORKS:
			return RoadWorksPiece.new()
		SetPieceDef.Kind.SLALOM:
			return SlalomPiece.new()
		SetPieceDef.Kind.CONVOY:
			return ConvoyPiece.new()
		SetPieceDef.Kind.TUNNEL_SQUEEZE:
			return TunnelSqueezePiece.new()
		SetPieceDef.Kind.TOLL_GANTRY:
			return TollGantryPiece.new()
	return null


## Every SetPieceDef named in the unlock order that has a data file, by id, plus the
## checkpoint-landmark pieces (is_checkpoint_landmark: the toll gantry) in DEF_DIR.
static func load_defs(director_tuning: DirectorTuning) -> Dictionary:
	var out: Dictionary = {}
	for id in director_tuning.set_piece_unlock_order:
		var path := DEF_DIR + String(id) + ".tres"
		if ResourceLoader.exists(path):
			var d := load(path) as SetPieceDef
			if d != null:
				out[id] = d
	for f in DirAccess.get_files_at(DEF_DIR):
		var file := f.trim_suffix(".remap")
		if not file.ends_with(".tres"):
			continue
		var res := load(DEF_DIR + file)
		var d := res as SetPieceDef
		if d != null and d.is_checkpoint_landmark and not out.has(d.id):
			out[d.id] = d
	return out


func _init(run: RunContext, flow_source: SpawnSources.Flow, traffic_sim: Object, intensity: IntensityWaves,
		stream: Rng) -> void:
	tuning = run.tuning.director
	flow = flow_source
	waves = intensity
	sim = traffic_sim
	state = sim.get(&"state") as TrafficState
	rng = stream
	defs = load_defs(tuning)
	min_speed_mps = run.tuning.scoring.min_speed_mps() + Units.kmh_to_mps(tuning.set_piece_min_speed_margin_kmh)
	can_script = sim.has_method(&"set_scripted_v0") and sim.has_method(&"scripted_brake_tap") \
		and sim.has_method(&"release_scripted") and sim.has_method(&"set_hard_decel_allowed") \
		and sim.has_method(&"request_lane_change")
	can_zone = sim.has_method(&"add_lane_closure") and sim.has_method(&"add_speed_zone") \
		and sim.has_method(&"add_headway_zone") and sim.has_method(&"remove_zones") \
		and sim.has_method(&"set_merge_hold") and sim.has_method(&"set_hazards")
	zone_sim = sim as TrafficSim
	for k in MAX_INSTANCES:
		instances.append(Instance.new())
	_slot_serial.resize(state.capacity)
	_slot_serial.fill(-1)
	_slot_vid.resize(state.capacity)
	_slot_vid.fill(-1)


func source_id() -> StringName:
	return &"set_piece"


# ---------------------------------------------------------------- Choosing (director rate)

## The kind a peak gets on `leg`, in `biome`, with `lanes` lanes, from the peak's seeded
## draw `u` in [0, 1): the first set_pieces_unlocked(leg) ids of the unlock order that
## have data and a controller, allow the leg and the lanes, weighted by the biome's mix
## (an id the biome does not list is out) or, without a biome mix, by their own weight.
## Null when none qualifies.
func pick(leg: int, biome: BiomeDef, u: float, lanes: int) -> SetPieceDef:
	var cands: Array[SetPieceDef] = []
	var weights := PackedFloat64Array()
	var total := 0.0
	for i in tuning.set_pieces_unlocked(leg):
		var d: SetPieceDef = defs.get(tuning.set_piece_unlock_order[i])
		if d == null or d.is_checkpoint_landmark or d.trigger != SetPieceDef.Trigger.PEAK or not fits_lanes(d, lanes) \
				or d.min_leg > leg or controller_for(d.kind) == null:
			continue
		var w := d.weight
		if biome != null and not biome.set_piece_ids.is_empty():
			var bi := biome.set_piece_ids.find(d.id)
			w = biome.set_piece_weights[bi] if bi >= 0 and bi < biome.set_piece_weights.size() else 0.0
		if w > 0.0:
			cands.append(d)
			weights.append(w)
			total += w
	if cands.is_empty():
		return null
	var x := clampf(u, 0.0, 1.0) * total
	for k in cands.size():
		x -= weights[k]
		if x < 0.0:
			return cands[k]
	return cands[cands.size() - 1]


## True when `def` may be laid out on `lanes` lanes (min_lanes, max_lanes).
static func fits_lanes(def: SetPieceDef, lanes: int) -> bool:
	return lanes >= def.min_lanes and (def.max_lanes <= 0 or lanes <= def.max_lanes)


## A feature-triggered kind (tunnel squeeze, toll gantry) is available on `leg` in
## `biome`: its own min_leg; in the unlock order, unlocked by the leg; listed in the
## biome's mix when the biome has one (the toll gantry follows the landmark style
## instead). Director rate.
func tied_allowed(def: SetPieceDef, leg: int, biome: BiomeDef) -> bool:
	if def.min_leg > leg or controller_for(def.kind) == null:
		return false
	var at := tuning.set_piece_unlock_order.find(def.id)
	if at >= 0 and at >= tuning.set_pieces_unlocked(leg):
		return false
	if def.trigger == SetPieceDef.Trigger.TUNNEL and biome != null and not biome.set_piece_ids.is_empty():
		var bi := biome.set_piece_ids.find(def.id)
		return bi >= 0 and bi < biome.set_piece_weights.size() and biome.set_piece_weights[bi] > 0.0
	return true


## Live (scheduled or running) pieces.
func active_count() -> int:
	var n := 0
	for inst in instances:
		if inst.stage != Stage.FREE:
			n += 1
	return n


func can_schedule() -> bool:
	return active_count() < tuning.set_piece_max_active and _free_instance() != null


## WP6.3: a new piece the player faces over [x0, x1] (road positions of the player: its
## first warning to its end) may be scheduled when an instance is free and fewer than
## set_piece_max_active live pieces overlap that range (a road-anchored piece is decided
## far ahead: one the player will have passed by x0, or will only meet after x1, does
## not count). Director rate.
func can_schedule_at(x0: float, x1: float) -> bool:
	if _free_instance() == null:
		return false
	var n := 0
	for inst in instances:
		if inst.stage != Stage.FREE and end_x(inst) >= x0 and start_x(inst) <= x1:
			n += 1
	return n < tuning.set_piece_max_active


## Where the player will be when a live piece ends (its zone end + end margin; for a
## rolling piece, where the player meets its front, + end margin).
func end_x(inst: Instance) -> float:
	if inst.is_anchored():
		return inst.zone_s1 + inst.def.end_margin_m
	return waves.meet_x(inst.speed, inst.s_front) + inst.def.end_margin_m


## Where the player first hears of a live piece (its first warning, its zone or rear).
func start_x(inst: Instance) -> float:
	if inst.is_anchored():
		return minf(first_notice_s(inst.def, inst.zone_s0), inst.zone_s0)
	var x := waves.meet_x(inst.speed, inst.s_rear)
	return minf(first_notice_s(inst.def, x), x)


## Where the player first hears of a piece at `s_first` (its rear / zone start): its
## farthest warning before it.
static func first_notice_s(def: SetPieceDef, s_first: float) -> float:
	var w := 0.0
	for x in def.warning_sign_distances_m:
		w = maxf(w, x)
	return s_first + def.warning_anchor_m - w


## Road-anchored pieces (WP6.3): lays `def` out with its zone starting at `zone_s0` on
## `lanes` lanes, puts its road hooks in (Controller.setup_zone) and runs it at once.
## Null when no instance is free or the controller could not set it up. Director rate.
func schedule_zone(def: SetPieceDef, zone_s0: float, lanes: int, speed: float) -> Instance:
	var inst := schedule(def, zone_s0, lanes, speed)
	if inst == null:
		return null
	inst.zone_s0 = zone_s0
	inst.zone_s1 = zone_s0 + def.length_m
	if not inst.controller.setup_zone(self, inst):
		remove_sim_hooks(inst)
		unfit_setup += 1
		inst.stage = Stage.FREE
		inst.controller = null
		return null
	inst.warn_s = inst.zone_s0 + def.warning_anchor_m
	inst.pending_vehicles = def.vehicles_max > 0
	# No footprint until its vehicles are planned (prepare_anchored places them).
	inst.s_rear = INF if inst.pending_vehicles else inst.zone_s0
	inst.s_front = inst.s_rear
	inst.stage = Stage.RUNNING
	spawned += 1
	spawned_by_kind[def.id] = int(spawned_by_kind.get(def.id, 0)) + 1
	return inst


## Road-anchored pieces: the rear s where vehicles planned now at `v` are met by the
## player at road position x (the meeting map), INF when the player is not closing on
## them (pace within the closing floor of v). Director rate.
func meet_plan_s(v: float, x: float) -> float:
	var dv := waves.pace - v
	if dv < Units.kmh_to_mps(tuning.wave_min_closing_kmh):
		return INF
	return waves.player_s + (x - waves.player_s) * dv / waves.pace


## Road-anchored pieces: fits the road at [s0, s1] (zone and signs, from its first
## warning to its end + end_margin): lanes; rule 6 (no part just beyond a blind crest or
## bend, at rest); clear of checkpoints (unless triggered by one) and of lane-count
## changes, tunnels and forks (unless triggered by a tunnel); no other live piece's zone.
func fits_zone(def: SetPieceDef, s0: float, s1: float, lanes: int) -> bool:
	if not fits_lanes(def, lanes):
		unfit_lanes += 1
		return false
	var first := first_notice_s(def, s0)
	if waves.is_blind(0.0, s0) or waves.is_blind(0.0, (s0 + s1) * 0.5) or waves.is_blind(0.0, s1):
		unfit_blind += 1
		return false
	var x_end := s1 + def.end_margin_m
	if def.trigger != SetPieceDef.Trigger.CHECKPOINT and not waves.clear_of_checkpoints(minf(first, s0), x_end):
		unfit_checkpoint += 1
		return false
	if def.trigger != SetPieceDef.Trigger.TUNNEL and (not waves.clear_of_zones(minf(first, s0), x_end) \
			or road.lane_count(x_end) != lanes or road.lane_count(minf(first, s0)) != lanes):
		unfit_road += 1
		return false
	if not clear_of_live(minf(first, s0), x_end):
		unfit_live += 1
		return false
	if x_end > road.length_generated():
		unfit_road += 1   # beyond an unresolved fork (WP6.5): its road is not decided yet
		return false
	return true


## True when [s0, s1] overlaps no live road-anchored piece's zone (from its first
## notice to its end + end margin).
func clear_of_live(s0: float, s1: float) -> bool:
	for inst in instances:
		if inst.stage == Stage.FREE or not inst.is_anchored():
			continue
		var a := minf(first_notice_s(inst.def, inst.zone_s0), inst.zone_s0)
		var b := inst.zone_s1 + inst.def.end_margin_m
		if s1 >= a and s0 <= b:
			return false
	return true


## Takes every sim hook of the piece (closures, zones) out. Director rate.
func remove_sim_hooks(inst: Instance) -> void:
	if not can_zone:
		return
	sim.call(&"remove_lane_closures", inst.serial)
	sim.call(&"remove_zones", inst.serial)


## Schedules `def` with its rear at `s_rear` on `lanes` lanes at `speed` m/s; the next
## plan_batch covering s_rear lays it out. Returns the instance (null when the pool is
## full or the kind has no controller).
func schedule(def: SetPieceDef, s_rear: float, lanes: int, speed: float) -> Instance:
	var inst := _free_instance()
	var ctl := controller_for(def.kind)
	if inst == null or ctl == null:
		return null
	inst.stage = Stage.SCHEDULED
	inst.serial = _serial
	_serial += 1
	inst.def = def
	inst.controller = ctl
	inst.lanes = lanes
	inst.speed = speed
	inst.s_rear = s_rear
	inst.s_front = s_rear + def.length_m
	inst.planned = false
	inst.records.clear()
	inst.rec_natural_v0.clear()
	inst.rec_row.clear()
	inst.n = 0
	inst.age = 0.0
	inst.run_s = 0.0
	inst.next_warning = 0
	inst.warned_m = -1.0
	inst.announced = false
	inst.did_start = false
	return inst


## True when a scheduled piece starts in [s_from, s_to).
func has_pending_in(s_from: float, s_to: float) -> bool:
	return _pending_in(s_from, s_to) != null


## Frees every instance (no events): a director reset. Road-anchored pieces take their
## sim hooks out (the road keeps its lane counts and rail gaps).
func clear() -> void:
	for inst in instances:
		if inst.stage != Stage.FREE and inst.is_anchored():
			remove_sim_hooks(inst)
		inst.stage = Stage.FREE
		inst.n = 0
		inst.controller = null
	_slot_serial.fill(-1)
	_slot_vid.fill(-1)


# ---------------------------------------------------------------- SpawnSource (director rate)

## The scheduled piece whose rear is in [s_from, s_to) (when ctx allows set pieces),
## then Flow for the batch minus whatever would crowd a live piece.
func plan_batch(ctx: SpawnSource.Context, s_from: float, s_to: float, out_spawns: Array[SpawnSource.Record]) -> void:
	var inst := _pending_in(s_from, s_to) if ctx.set_pieces_allowed else null
	if inst != null:
		if inst.is_anchored():
			_plan_anchored(ctx, inst, s_to)
		else:
			_plan_piece(ctx, inst, s_to)
		for r in inst.records:
			out_spawns.append(r)
	if active_count() == 0:
		flow.plan_batch(ctx, s_from, s_to, out_spawns)
		return
	_flow_tmp.clear()
	flow.plan_batch(ctx, s_from, s_to, _flow_tmp)
	for r in _flow_tmp:
		if keeps_clear(r):
			out_spawns.append(r)


## Lays the piece out at its scheduled rear, or as little further as it takes (steps of
## placement_step_m, up to the batch end) for every vehicle to fit live traffic
## (fits_live) and the piece to fit the road (fits_road: rule 6, checkpoints, lane
## drops). Nothing fits: no records (the director drops the piece).
func _plan_piece(ctx: SpawnSource.Context, inst: Instance, s_to: float) -> void:
	inst.records.clear()
	inst.rec_natural_v0.clear()
	inst.rec_row.clear()
	inst.controller.plan(self, ctx, inst)
	inst.planned = false
	if inst.records.is_empty():
		return
	var lo := INF
	var hi := -INF
	for r in inst.records:
		var hl := flow.length_of(r.type_id) * 0.5
		lo = minf(lo, r.s - hl)
		hi = maxf(hi, r.s + hl)
	var shift := 0.0
	while lo + shift < s_to:
		var ok := fits_road(inst.def, inst.speed, lo + shift, hi - lo, inst.lanes, ctx.road)
		for r in inst.records:
			r.s += shift
			ok = ok and fits_live(ctx, inst, r)
			r.s -= shift
		if ok:
			for r in inst.records:
				r.s += shift
			inst.s_rear = lo + shift
			inst.s_front = hi + shift
			inst.planned = true
			return
		shift += tuning.set_piece_placement_step_m
	inst.records.clear()


## A road-anchored piece's vehicles (WP6.3), laid out by its controller from inst.s_rear
## (the rear vehicles_rear_s() gave): the ones that fit the live traffic are kept (the
## zone does not move). Director rate.
func _plan_anchored(ctx: SpawnSource.Context, inst: Instance, _s_to: float) -> void:
	inst.records.clear()
	inst.rec_natural_v0.clear()
	inst.rec_row.clear()
	inst.controller.plan(self, ctx, inst)
	inst.pending_vehicles = false
	var k := 0
	while k < inst.records.size():
		var rec := inst.records[k]
		# Its lane must exist where it spawns and keep it to the zone (no lane drop,
		# tunnel or fork on the way: a tunnel-triggered piece drives into its own).
		var road_ok := flow.lane_open_for_spawn(ctx.road, rec.lane, rec.s) and (inst.def.trigger == SetPieceDef.Trigger.TUNNEL \
			or waves.clear_of_zones(rec.s, inst.zone_s0))
		if road_ok and fits_live(ctx, inst, rec):
			k += 1
			continue
		inst.records.remove_at(k)
		inst.rec_natural_v0.remove_at(k)
		inst.rec_row.remove_at(k)
	inst.planned = not inst.records.is_empty()


## Rule 6 and the road for a piece of `def` at speed `v` (m/s), rear at `s`, `span`
## long, on `lanes` lanes: enough lanes; none of it hidden just beyond a blind crest or
## bend while the player drives it (IntensityWaves.is_blind at its rear, middle and
## front); met by the player clear of every checkpoint's range; and no lane-count change,
## tunnel or fork on the road it drives until it ends (the player passing its front
## + end_margin_m). Director rate.
func fits_road(def: SetPieceDef, v: float, s: float, span: float, lanes: int, on_road: RoadPath) -> bool:
	if not fits_lanes(def, lanes):
		unfit_lanes += 1
		return false
	if waves.is_blind(v, s) or waves.is_blind(v, s + span * 0.5) or waves.is_blind(v, s + span):
		unfit_blind += 1
		return false
	# WP9.6: the road it drives until the player passes it, at the cruising pace (a dip
	# behind slow traffic stretched it to the 4 km lookahead; a piece that does roll into
	# a lane-count change, tunnel or fork ends there: ended_zone). The checkpoints, a
	# fairness range, are checked over both estimates.
	var x_end := meet_x(v, s + span) + def.end_margin_m
	var x_end_now := waves.meet_x(v, s + span) + def.end_margin_m
	if not waves.clear_of_checkpoints(minf(meet_x(v, s), waves.meet_x(v, s)), maxf(x_end, x_end_now)):
		unfit_checkpoint += 1
		return false
	if not waves.clear_of_zones(s, x_end, true) or on_road.lane_count(x_end) < lanes:
		unfit_road += 1
		return false
	if not clear_of_live(s, x_end):
		unfit_live += 1
		return false
	return true


## WP9.6: where the player meets a vehicle at speed v planned now at s, at meet_pace
## when that is faster than the waves' pace (IntensityWaves.meet_x otherwise).
func meet_x(v: float, s: float) -> float:
	if meet_pace <= waves.pace:
		return waves.meet_x(v, s)
	var x := waves.player_s
	var look := tuning.wave_meet_lookahead_m
	var dv := maxf(meet_pace - v, Units.kmh_to_mps(tuning.wave_min_closing_kmh))
	return clampf(x + (s - x) * meet_pace / dv, x - look, x + look)


## A piece vehicle fits the live traffic: s* (closing speed included) to its live
## neighbors in its lane and to the player (Flow's check). A slower live vehicle further
## ahead may still be caught up with before the player arrives: that car then queues
## behind it (IDM) and the formation loosens in that lane; new Flow vehicles are kept
## out of that reach (keeps_clear).
func fits_live(ctx: SpawnSource.Context, _inst: Instance, rec: SpawnSource.Record) -> bool:
	return flow.fits_between_neighbors_into(ctx, rec)


## True when a Flow vehicle planned as `rec` leaves every live piece alone: not within a
## piece's clear_behind_m .. clear_ahead_m (any lane), and in a lane the piece occupies,
## behind it at least the IDM gap it would keep (closing speed included) and ahead of it
## beyond its catch_reach. Allocation-free.
func keeps_clear(rec: SpawnSource.Record) -> bool:
	if not spawn_speed_ok(rec):
		return false
	for inst in instances:
		if inst.stage == Stage.FREE or not has_footprint(inst):
			continue
		var d := inst.def
		if rec.s >= inst.s_rear - d.clear_behind_m and rec.s <= inst.s_front + d.clear_ahead_m:
			return false
		if not occupies(inst, rec.lane):
			continue
		if rec.s < inst.s_rear:
			# Behind it: at least the IDM gap it keeps behind the piece (a faster one closes).
			var ln := flow.length_of(rec.type_id)
			if inst.s_rear - rec.s < flow.min_spacing(rec.profile_id, rec.v, ln, inst.speed, ln):
				return false
		elif rec.s - inst.s_front < catch_reach(inst, rec.profile_id, rec.v, flow.length_of(rec.type_id)):
			return false
	return true


## False when `rec` would come in faster than a piece's speed zone lets it drive where it
## spawns (in a toll's booth lane, or on its braking approach: TrafficSim.speed_limit_at);
## the director also asks this of its behind spawns. Allocation-free.
func spawn_speed_ok(rec: SpawnSource.Record) -> bool:
	if zone_sim == null or zone_sim.speed_zone_count() == 0:
		return true
	return zone_sim.speed_limit_at(rec.lane, rec.s + flow.length_of(rec.type_id) * 0.5, rec.profile_id) >= rec.v


## True when a live piece has vehicles (or planned ones) Flow must keep clear of: a
## road-anchored piece only once its vehicles are planned or bound (its closures and
## zones steer traffic themselves). Allocation-free.
func has_footprint(inst: Instance) -> bool:
	return not inst.is_anchored() or inst.n > 0 or inst.planned


## True when the piece has a vehicle in `lane` (its planned records until it runs).
## Allocation-free.
func occupies(inst: Instance, lane: int) -> bool:
	if inst.stage == Stage.RUNNING and not inst.planned:
		for k in inst.n:
			if alive(inst, k) and state.lane[inst.slot[k]] == lane:
				return true
		return false
	for r in inst.records:
		if r.lane == lane:
			return true
	return inst.records.is_empty()


## How far ahead of a piece's front a vehicle (profile, speed, length) is caught up with
## before the piece ends: what the piece gains on it in remaining_s(), plus the IDM gap
## a piece car keeps behind it, plus clear_ahead_m. 0 for a vehicle at least as fast.
## Allocation-free.
func catch_reach(inst: Instance, profile_id: int, v: float, length_m: float) -> float:
	if v >= inst.speed:
		return inst.def.clear_ahead_m
	return (inst.speed - v) * remaining_s(inst) + inst.def.clear_ahead_m \
		+ flow.min_spacing(profile_id, inst.speed, length_m, v, length_m)


## How long a piece is expected to live on: until the player passes it (at the smoothed
## pace) or its time runs out, whichever is first.
func remaining_s(inst: Instance) -> float:
	var d := inst.def
	var left := maxf(d.duration_max_s - inst.run_s, 0.0) if inst.did_start \
		else maxf(d.approach_max_s - inst.age, 0.0) + d.duration_max_s
	var dv := waves.pace - inst.speed
	if dv <= 0.0:
		return left
	return minf(left, maxf(inst.s_front + inst.def.end_margin_m - waves.player_s, 0.0) / dv)


## Controllers: one piece vehicle in `lane` (profile from the def's mix), at the piece's
## speed, FLAG_SCRIPTED. False when no profile fits. Director rate.
func draw_vehicle(ctx: SpawnSource.Context, inst: Instance, lane: int, rec: SpawnSource.Record) -> bool:
	var d := inst.def
	if d.profile_ids.is_empty():
		return false
	var k := 0
	if d.profile_weights.size() == d.profile_ids.size():
		k = rng.pick_weighted(d.profile_weights)
	else:
		k = rng.int_range(0, d.profile_ids.size() - 1)
	var p := flow.profile_index(d.profile_ids[k])
	if not flow.draw_profile_into(ctx, rng, p, lane, rec):
		return false
	rec.v = inst.speed
	rec.flags = TrafficState.FLAG_SCRIPTED
	rec.set_piece = d.id
	return true


## Controllers: adds a planned record (its natural v0 is rec.v0 as drawn; the record
## drives at the piece's speed).
func add_record(inst: Instance, rec: SpawnSource.Record, row_index: int) -> void:
	inst.rec_natural_v0.append(rec.v0)
	inst.rec_row.append(row_index)
	rec.v0 = inst.speed
	inst.records.append(rec)


# ---------------------------------------------------------------- Commit (director rate)

## After the director committed a batch: binds each committed record of the planned
## piece to its slot (RUNNING), or drops a piece that was not laid out or none of whose
## vehicles made it.
func bind_committed() -> void:
	for inst in instances:
		if inst.stage == Stage.RUNNING and inst.planned:
			_bind_anchored(inst)
			continue
		if inst.stage != Stage.SCHEDULED:
			continue
		inst.n = 0
		if not inst.planned:
			unplaced += 1
			inst.stage = Stage.FREE
			inst.controller = null
			continue
		_bind_records(inst)
		if inst.n == 0:
			uncommitted += 1
			inst.stage = Stage.FREE
			inst.controller = null
			continue
		_sort_by_lane(inst)
		inst.stage = Stage.RUNNING
		inst.planned = false
		inst.records.clear()
		spawned += 1
		spawned_by_kind[inst.def.id] = int(spawned_by_kind.get(inst.def.id, 0)) + 1
		_refresh(inst)
		inst.controller.on_bound(self, inst)


## A running road-anchored piece's planned vehicles, now committed, join it.
func _bind_anchored(inst: Instance) -> void:
	inst.planned = false
	var n0 := inst.n
	_bind_records(inst)
	inst.records.clear()
	if inst.n == n0:
		uncommitted += 1
		return
	_sort_by_lane(inst)
	_refresh(inst)
	inst.controller.on_bound(self, inst)


## Binds every committed record of `inst` (FLAG_SCRIPTED, not yet in a piece, at a
## record's lane / type / s) to its slot.
func _bind_records(inst: Instance) -> void:
	for i in state.capacity:
		if inst.n >= MAX_VEHICLES:
			break
		if state.active[i] == 0 or (state.flags[i] & TrafficState.FLAG_SCRIPTED) == 0 or instance_of(i) >= 0:
			continue
		var r := _record_at(inst, i)
		if r < 0:
			continue
		var k := inst.n
		inst.slot[k] = i
		inst.vid[k] = state.vehicle_id[i]
		inst.lane[k] = inst.records[r].lane
		inst.row[k] = inst.rec_row[r]
		inst.natural_v0[k] = inst.rec_natural_v0[r]
		_slot_serial[i] = inst.serial
		_slot_vid[i] = state.vehicle_id[i]
		inst.n += 1


## The serial of the piece `slot`'s vehicle belongs to, or -1. Allocation-free.
func instance_of(slot: int) -> int:
	if slot < 0 or slot >= state.capacity or state.active[slot] == 0 or _slot_vid[slot] != state.vehicle_id[slot]:
		return -1
	return _slot_serial[slot]


## The running instance with this serial, or null.
func instance_by_serial(serial: int) -> Instance:
	for inst in instances:
		if inst.stage != Stage.FREE and inst.serial == serial:
			return inst
	return null


func _record_at(inst: Instance, slot: int) -> int:
	for r in inst.records.size():
		var rec := inst.records[r]
		if rec.lane == state.lane[slot] and rec.type_id == state.type_id[slot] and absf(rec.s - state.s[slot]) < 0.5:
			return r
	return -1


static func _sort_by_lane(inst: Instance) -> void:
	# Insertion sort on (row, lane): controllers find vehicles in formation order.
	for a in range(1, inst.n):
		var b := a
		while b > 0 and inst.row[b - 1] * MAX_VEHICLES + inst.lane[b - 1] > inst.row[b] * MAX_VEHICLES + inst.lane[b]:
			_swap(inst, b - 1, b)
			b -= 1


static func _swap(inst: Instance, a: int, b: int) -> void:
	var t_slot := inst.slot[a]
	inst.slot[a] = inst.slot[b]
	inst.slot[b] = t_slot
	var t_vid := inst.vid[a]
	inst.vid[a] = inst.vid[b]
	inst.vid[b] = t_vid
	var t_lane := inst.lane[a]
	inst.lane[a] = inst.lane[b]
	inst.lane[b] = t_lane
	var t_row := inst.row[a]
	inst.row[a] = inst.row[b]
	inst.row[b] = t_row
	var t_v0 := inst.natural_v0[a]
	inst.natural_v0[a] = inst.natural_v0[b]
	inst.natural_v0[b] = t_v0
	var t_off := inst.slot_off[a]
	inst.slot_off[a] = inst.slot_off[b]
	inst.slot_off[b] = t_off


# ---------------------------------------------------------------- Runtime (per tick, allocation-free)

## Per tick, after the director's despawn: warnings, start, behaviour, end.
func step(dt: float, player: VehicleState) -> void:
	for inst in instances:
		if inst.stage != Stage.RUNNING:
			continue
		inst.age += dt
		inst.player_s = player.s
		_refresh(inst)
		if inst.is_anchored():
			_step_anchored(inst, dt, player)
			continue
		if inst.n == 0:
			ended_empty += 1
			_end(inst)
			continue
		var dist := inst.s_rear - player.s
		var ws := inst.def.warning_sign_distances_m
		while inst.next_warning < ws.size() and dist <= ws[inst.next_warning]:
			_warn(inst, dist)
		if not inst.did_start and dist <= inst.def.start_distance_m:
			inst.did_start = true
			inst.announced = true
			started += 1
			_push(KIND_STARTED, inst, 0.0)
		inst.controller.step(self, inst, dt, player)
		if inst.did_start:
			inst.run_s += dt
		if player.s > inst.s_front + inst.def.end_margin_m:
			ended_passed += 1
		elif inst.run_s > inst.def.duration_max_s:
			ended_duration += 1
		elif not inst.did_start and inst.age > inst.def.approach_max_s:
			ended_unmet += 1
		elif not waves.clear_of_zones(inst.s_rear, inst.s_front + inst.def.clear_ahead_m, true) \
				or not clear_of_live(inst.s_rear, inst.s_front + inst.def.clear_ahead_m):
			ended_zone += 1   # rolling into a lane drop, tunnel or fork, or a road-anchored piece
		else:
			continue
		_end(inst)


## A road-anchored piece's tick (WP6.3): warnings count down to its warn_s, it starts
## start_distance_m before its zone and ends end_margin_m past it (never by time, approach
## or an empty formation: its road hooks stay until the player has passed).
func _step_anchored(inst: Instance, dt: float, player: VehicleState) -> void:
	var dist := inst.warn_s - player.s
	var ws := inst.def.warning_sign_distances_m
	while inst.next_warning < ws.size() and dist <= ws[inst.next_warning]:
		_warn(inst, dist)
	if not inst.did_start and inst.zone_s0 - player.s <= inst.def.start_distance_m:
		inst.did_start = true
		inst.announced = true
		started += 1
		_push(KIND_STARTED, inst, 0.0)
	inst.controller.step(self, inst, dt, player)
	if inst.did_start:
		inst.run_s += dt
	if player.s > inst.zone_s1 + inst.def.end_margin_m:
		ended_passed += 1
		_end(inst)


## Is this bound vehicle still the one we bound (not despawned or reused)?
func alive(inst: Instance, k: int) -> bool:
	var i := inst.slot[k]
	return i >= 0 and state.active[i] == 1 and state.vehicle_id[i] == inst.vid[k]


## Drops despawned vehicles (keeping formation order) and refreshes the live footprint.
func _refresh(inst: Instance) -> void:
	var w := 0
	var lo := INF
	var hi := -INF
	for k in inst.n:
		if not alive(inst, k):
			continue
		if w != k:
			inst.slot[w] = inst.slot[k]
			inst.vid[w] = inst.vid[k]
			inst.lane[w] = inst.lane[k]
			inst.row[w] = inst.row[k]
			inst.natural_v0[w] = inst.natural_v0[k]
			inst.slot_off[w] = inst.slot_off[k]
		var i := inst.slot[w]
		var hl := state.length[i] * 0.5
		lo = minf(lo, state.s[i] - hl)
		hi = maxf(hi, state.s[i] + hl)
		w += 1
	inst.n = w
	if w > 0:
		inst.s_rear = lo
		inst.s_front = hi


func _warn(inst: Instance, dist: float) -> void:
	var index := inst.next_warning
	inst.next_warning += 1
	inst.announced = true
	if inst.warned_m < 0.0:
		inst.warned_m = maxf(dist, 0.0)
		if inst.def.allows_hard_decel and inst.warned_m >= tuning.set_piece_min_warning_m and can_script:
			for k in inst.n:
				sim.call(&"set_hard_decel_allowed", inst.slot[k], true)
	_push(KIND_WARNING, inst, dist)
	inst.controller.on_warning(self, inst, index)


func _end(inst: Instance) -> void:
	inst.controller.on_end(self, inst)
	if can_script:
		for k in inst.n:
			if alive(inst, k):
				sim.call(&"release_scripted", inst.slot[k], inst.natural_v0[k])
	for k in inst.n:
		var i := inst.slot[k]
		if i >= 0 and _slot_serial[i] == inst.serial:
			_slot_serial[i] = -1
			_slot_vid[i] = -1
	if inst.announced:
		_push(KIND_ENDED, inst, 0.0)
	ended += 1
	inst.stage = Stage.FREE
	inst.n = 0
	inst.controller = null


func _push(kind: StringName, inst: Instance, value: float) -> void:
	if events != null:
		events.push(kind, inst.serial, 0.0, -1.0, -1, value, inst.def.id)


func _free_instance() -> Instance:
	for inst in instances:
		if inst.stage == Stage.FREE:
			return inst
	return null


func _pending_in(s_from: float, s_to: float) -> Instance:
	for inst in instances:
		if inst.s_rear < s_from or inst.s_rear >= s_to:
			continue
		if inst.stage == Stage.SCHEDULED or (inst.stage == Stage.RUNNING and inst.pending_vehicles):
			return inst
	return null


## The piece whose vehicles the batch [s_from, s_to) lays out (a scheduled rolling piece,
## or a running road-anchored piece's vehicles), or null.
func planning_in(s_from: float, s_to: float) -> Instance:
	return _pending_in(s_from, s_to)


## Before the batch [a, b) is planned (WP6.3): each running road-anchored piece whose
## vehicles are still to come gets their rear for this batch (Controller.vehicles_rear_s)
## when it falls in it, or at the batch start when the player still meets them in the
## zone from there; a piece whose vehicles the player can no longer meet gives them up.
## Director rate.
func prepare_anchored(a: float, b: float) -> void:
	for inst in instances:
		if inst.stage != Stage.RUNNING or not inst.is_anchored() or not inst.pending_vehicles:
			continue
		var r := inst.controller.vehicles_rear_s(self, inst)
		if is_inf(r):
			inst.pending_vehicles = false
		elif r >= b:
			inst.s_rear = INF
			continue
		elif r < a:
			if waves.meet_x(inst.speed, a) > inst.zone_s1:
				inst.pending_vehicles = false
			r = a
		inst.s_rear = r if inst.pending_vehicles else inst.zone_s0
		inst.s_front = inst.s_rear


# ---------------------------------------------------------------- Scripting helpers (tick)

func set_v0(inst: Instance, k: int, v0: float) -> void:
	if can_script and alive(inst, k):
		sim.call(&"set_scripted_v0", inst.slot[k], maxf(v0, min_speed_mps))


## A desired speed below the minimum-speed floor (WP6.3: ramp traffic coming off the
## on-ramp, in the acceleration lane the player need not use).
func set_v0_unfloored(inst: Instance, k: int, v0: float) -> void:
	if can_script and alive(inst, k):
		sim.call(&"set_scripted_v0", inst.slot[k], v0)


## Holds a vehicle out of the mandatory merge (WP6.3: ramp traffic waits for the player).
func merge_hold(inst: Instance, k: int, on: bool) -> void:
	if can_zone and alive(inst, k):
		sim.call(&"set_merge_hold", inst.slot[k], on)


## True while vehicle k is held out of the mandatory merge.
func is_held(inst: Instance, k: int) -> bool:
	return can_zone and alive(inst, k) and bool(sim.call(&"merge_held", inst.slot[k]))


## A vehicle's hazard lights (WP6.3: the convoy).
func hazards(inst: Instance, k: int, on: bool) -> void:
	if can_zone and alive(inst, k):
		sim.call(&"set_hazards", inst.slot[k], on)


## Sounds a vehicle's horn (WP6.3: the convoy honks).
func honk(inst: Instance, k: int) -> void:
	if alive(inst, k) and sim.has_method(&"honk"):
		sim.call(&"honk", inst.slot[k], TrafficSim.TAG_HONK)


func brake_tap(inst: Instance, k: int) -> bool:
	if not can_script or not alive(inst, k):
		return false
	return bool(sim.call(&"scripted_brake_tap", inst.slot[k]))


func request_lane(inst: Instance, k: int, target_lane: int) -> bool:
	if not can_script or not alive(inst, k):
		return false
	return bool(sim.call(&"request_lane_change", inst.slot[k], target_lane))


## Scripting may command vehicle k now (alive, not recovering from a hit).
func controllable(inst: Instance, k: int) -> bool:
	return alive(inst, k) and (state.flags[inst.slot[k]] & TrafficState.FLAG_HIT) == 0


# ================================================================ The pieces

## Truck wall: "trucks and buses roll side by side across all lanes but one; the open
## lane shifts slowly. Warning: visible from distance by silhouettes." One vehicle per
## blocked lane and row (rows row-spaced by s*), staggered a little; every
## shift_interval_s, while the player is at least shift_min_player_gap_m behind (or
## ahead), the vehicles next to the open lane on one side (random, else the other) change
## into it with the usual telegraphing (request_lane_change: MOBIL safety and no-ambush
## refuse while traffic passes through the open lane; then it retries after
## shift_retry_s), so the open lane moves by one.
class TruckWall:
	extends Controller

	var open_lane: int = 0
	var shift_t: float = 0.0
	var shift_dir: int = 0
	var movers := PackedInt32Array()   ## instance indices moving into the open lane
	var n_movers: int = 0

	func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: Instance) -> void:
		var d := inst.def
		open_lane = src.rng.int_range(0, inst.lanes - 1)
		var row_s := inst.s_rear
		for r in maxi(d.rows, 1):
			var row_len := 0.0
			var row_gap := 0.0
			var planned: Array[SpawnSource.Record] = []
			for lane in inst.lanes:
				if lane == open_lane:
					continue
				var rec := SpawnSource.Record.new()
				if not src.draw_vehicle(ctx, inst, lane, rec):
					continue
				var ln := src.flow.length_of(rec.type_id)
				row_len = maxf(row_len, ln)
				row_gap = maxf(row_gap, src.flow.min_spacing(rec.profile_id, inst.speed, ln, inst.speed, ln) - ln)
				planned.append(rec)
			for rec in planned:
				rec.s = row_s + row_len * 0.5 + src.rng.float_range(-d.row_stagger_m, d.row_stagger_m)
				src.add_record(inst, rec, r)
			row_s += row_len + row_gap + d.row_stagger_m * 2.0

	func on_bound(_src: SetPieceSource, inst: Instance) -> void:
		shift_t = inst.def.shift_interval_s
		shift_dir = 0
		movers.resize(MAX_VEHICLES)
		n_movers = 0

	func step(src: SetPieceSource, inst: Instance, dt: float, player: VehicleState) -> void:
		if shift_dir != 0:
			_follow_shift(src, inst)
			return
		shift_t -= dt
		if shift_t > 0.0:
			return
		shift_t = inst.def.shift_retry_s
		var behind := inst.s_rear - player.s
		if behind < inst.def.shift_min_player_gap_m and player.s < inst.s_front:
			return   # the player is at the wall: hold the open lane
		# One side at random, else the other: the vehicles there change into the open lane
		# (refused while traffic passes through it: retry after shift_retry_s).
		var first := 1 if src.rng.chance(0.5) else -1
		for side: int in [first, -first]:
			if _shift_from(src, inst, side):
				shift_dir = side
				shift_t = inst.def.shift_interval_s
				return

	func _shift_from(src: SetPieceSource, inst: Instance, side: int) -> bool:
		var from := open_lane + side
		if from < 0 or from >= inst.lanes:
			return false
		n_movers = 0
		for k in inst.n:
			var i := inst.slot[k]
			if not src.controllable(inst, k) or src.state.lane[i] != from \
					or src.state.lc_state[i] != TrafficState.LaneChange.NONE:
				continue
			if src.request_lane(inst, k, open_lane):
				movers[n_movers] = k
				n_movers += 1
		return n_movers > 0

	## Waits for the movers: the open lane moves once every one has finished or cancelled
	## (and at least one arrived).
	func _follow_shift(src: SetPieceSource, inst: Instance) -> void:
		var arrived := 0
		for m in n_movers:
			var k := movers[m]
			if not src.alive(inst, k):
				continue
			var i := inst.slot[k]
			if src.state.lc_state[i] != TrafficState.LaneChange.NONE:
				return
			if src.state.lane[i] == open_lane:
				arrived += 1
		if arrived > 0:
			for m in n_movers:
				inst.lane[movers[m]] = open_lane
			open_lane += shift_dir
		shift_dir = 0
		n_movers = 0


## Rolling roadblock: "cars at matched speed across all lanes; a gap opens every few
## seconds. Warning: brake lights ripple as it forms." One car per lane, side by side.
## At the first warning the row brakes lane by lane from the median (a brake tap every
## ripple_step_s). Then, gap_interval_s after the last gap closed, one car (never the
## last one's lane) brakes (brake taps, lights on) down to gap_speed_delta_kmh below the
## row and drops back until it is gap_distance_m behind it, then closes up at the same
## delta: a hole in its lane to thread. A phase held up by traffic longer than
## gap_phase_max_s ends there (the car rejoins the row). All speeds stay >=
## SetPieceSource.min_speed_mps.
class RollingRoadblock:
	extends Controller

	enum Gap { IDLE, DROPPING, CLOSING }

	var ripple_k: int = -1     ## next car to tap (-1: not started, n: done)
	var ripple_t: float = 0.0
	var gap: Gap = Gap.IDLE
	var gap_k: int = -1
	var gap_t: float = 0.0
	var phase_t: float = 0.0   ## time in the current DROPPING / CLOSING phase
	var last_lane: int = -1
	## Gaps opened (dev, tests).
	var gaps: int = 0

	func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: Instance) -> void:
		var row_s := inst.s_rear
		for r in maxi(inst.def.rows, 1):
			var row_len := 0.0
			var row_gap := 0.0
			var planned: Array[SpawnSource.Record] = []
			for lane in inst.lanes:
				var rec := SpawnSource.Record.new()
				if not src.draw_vehicle(ctx, inst, lane, rec):
					continue
				var ln := src.flow.length_of(rec.type_id)
				row_len = maxf(row_len, ln)
				row_gap = maxf(row_gap, src.flow.min_spacing(rec.profile_id, inst.speed, ln, inst.speed, ln) - ln)
				planned.append(rec)
			for rec in planned:
				rec.s = row_s + row_len * 0.5
				src.add_record(inst, rec, r)
			row_s += row_len + row_gap

	func on_bound(_src: SetPieceSource, inst: Instance) -> void:
		ripple_k = -1
		gap = Gap.IDLE
		gap_k = -1
		gap_t = inst.def.gap_interval_s
		last_lane = -1

	func on_warning(_src: SetPieceSource, _inst: Instance, index: int) -> void:
		if index == 0 and ripple_k < 0:
			ripple_k = 0
			ripple_t = 0.0

	func step(src: SetPieceSource, inst: Instance, dt: float, _player: VehicleState) -> void:
		var d := inst.def
		if ripple_k >= 0 and ripple_k < inst.n:
			ripple_t -= dt
			if ripple_t <= 0.0:
				src.brake_tap(inst, ripple_k)
				ripple_k += 1
				ripple_t = d.ripple_step_s
			return
		if ripple_k < 0 or inst.n < 2:
			return   # no gaps before the row has formed
		var dv := Units.kmh_to_mps(d.gap_speed_delta_kmh)
		if gap != Gap.IDLE:
			phase_t += dt
			if phase_t > d.gap_phase_max_s or not src.alive(inst, gap_k):
				# Held up (traffic around it): back into the row, and on to the next gap.
				src.set_v0(inst, gap_k, inst.speed)
				_close(inst)
				return
		match gap:
			Gap.IDLE:
				gap_t -= dt
				if gap_t > 0.0:
					return
				var k := src.rng.int_range(0, inst.n - 1)
				if inst.lane[k] == last_lane:
					k = (k + 1) % inst.n
				if not src.controllable(inst, k):
					gap_t = d.ripple_step_s
					return
				gap_k = k
				src.brake_tap(inst, k)
				src.set_v0(inst, k, inst.speed - dv)
				gap = Gap.DROPPING
				phase_t = 0.0
				gaps += 1
			Gap.DROPPING:
				if _row_line(src, inst) - src.state.s[inst.slot[gap_k]] >= d.gap_distance_m:
					src.set_v0(inst, gap_k, inst.speed + dv)
					gap = Gap.CLOSING
					phase_t = 0.0
				elif src.state.v[inst.slot[gap_k]] > inst.speed - dv:
					src.brake_tap(inst, gap_k)   # brake down to the drop speed (brake lights on)
			Gap.CLOSING:
				if src.state.s[inst.slot[gap_k]] >= _row_line(src, inst):
					src.set_v0(inst, gap_k, inst.speed)
					_close(inst)

	func _close(inst: Instance) -> void:
		last_lane = inst.lane[gap_k] if gap_k >= 0 else -1
		gap = Gap.IDLE
		gap_k = -1
		gap_t = inst.def.gap_interval_s

	## Mean s of the row's other cars (the line the gap car drops back from).
	func _row_line(src: SetPieceSource, inst: Instance) -> float:
		var sum := 0.0
		var n := 0
		for k in inst.n:
			if k == gap_k or inst.row[k] != inst.row[gap_k] or not src.alive(inst, k):
				continue
			sum += src.state.s[inst.slot[k]]
			n += 1
		return sum / float(n) if n > 0 else src.state.s[inst.slot[gap_k]]
