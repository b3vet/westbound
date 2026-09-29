class_name SetPieceRig
extends RefCounted
## Set-piece test rig (WP6.3; not a test suite: the runner skips tests/fixtures). The
## real stack of a run's traffic on the procedural road: ProceduralRoadPath (a lane
## count, or a biome's road: its tunnels), TrafficRegistry, TrafficSim, TrafficDirector
## (set pieces only when forced: peak chance 0), a TrafficBotPlayer (closure-aware), the
## independent TrafficRuleChecker, HitDetection with the road works' prop query, and
## the run's event buffer. Deterministic by seed.
##
##   var r := SetPieceRig.new(seed_value, 3)
##   var inst := r.force(&"road_works")      # runs until it is live
##   r.run_until_passed(inst, 90.0)
##   eq(r.checker.total_violations(), 0)

const DT := 1.0 / 120.0

var tuning: Tuning
var ctx: RunContext
var road: ProceduralRoadPath
var registry: TrafficRegistry
var sim: TrafficSim
var dir: TrafficDirector
var bot: TrafficBotPlayer
var checker: TrafficRuleChecker
var hits: HitDetection
var works: WorksPropQuery
var ev: ScoreEventBuffer
var contact := HitDetection.Contact.new()
var time := 0.0
## Every set-piece event: [time, kind, tag, value, serial]; every horn: [time, slot].
var piece_log: Array = []
var horns: Array = []
## Prop hits (road works), and vehicle-in-a-closed-area ticks (road works' cone line).
var prop_hits := 0
var closed_area_ticks := 0
## Ticks the bot spent below the minimum speed (stuck).
var slow_ticks := 0


## `lanes` <= 0 keeps the road's default; `biome` lays the whole road out as that biome
## (BiomePlan.uniform: its lanes and tunnels); the bot starts at `start_s`.
func _init(seed_value: int, lanes: int = 3, biome: BiomeDef = null, t: Tuning = null, v_kmh: float = 170.0,
		lane: int = 1, start_s: float = 0.0, leg: int = 5) -> void:
	var base := t if t != null else Tuning.load_default()
	tuning = base.duplicate() as Tuning
	tuning.road = base.road.duplicate() as RoadTuning
	tuning.director = base.director.duplicate() as DirectorTuning
	tuning.director.set_piece_chance_first_pct = 0.0
	tuning.director.set_piece_chance_last_pct = 0.0
	if lanes > 0:
		tuning.road.lanes_default = lanes
	ctx = RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	road = ProceduralRoadPath.new(ctx)
	if biome != null:
		road.set_biome_plan(BiomePlan.uniform(biome, tuning.legs.leg_length_m()))
	registry = TrafficRegistry.load_default(tuning.traffic)
	sim = TrafficSim.new(ctx, road, registry)
	bot = TrafficBotPlayer.new(road, lane, Units.kmh_to_mps(v_kmh), TrafficBotPlayer.Mode.WEAVE, seed_value + 7)
	bot.closures = sim
	bot.set_weave(6.0, 10.0)
	bot.state.s = start_s
	bot.state.d = road.lane_center_d(lane, start_s)
	sim.set_player_body(bot.length_m, bot.width_m)
	dir = TrafficDirector.new(ctx, road, sim, registry.profiles, registry.types, bot.length_m, bot.width_m)
	ev = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity)
	dir.events = ev
	checker = TrafficRuleChecker.new(tuning, registry, road, bot.length_m, bot.width_m)
	checker.set_piece_of = dir.set_pieces.instance_of
	hits = HitDetection.new(tuning.lives, tuning.traffic.max_active_vehicles)
	hits.set_player_body(bot.length_m, bot.width_m)
	works = WorksPropQuery.new(dir.set_pieces, tuning.lives)
	hits.set_prop_query(works)
	dir.set_leg(leg, start_s)
	road.ensure_generated_to(start_s + dir.ahead_distance() * 2.0)
	dir.reset(bot.state)
	hits.reset(bot.state, null)


## Every checkpoint is a toll gantry (the run gets the style from its BiomeDirector).
func all_tolls() -> void:
	dir.checkpoint_style = func(_leg: int, _s: float) -> StringName: return BiomeDef.LANDMARK_TOLL_GANTRY


func tick() -> void:
	bot.update(DT, sim.state)
	sim.step(DT, bot.state, null, ev)
	time += DT
	checker.observe(time, sim.state, bot.state)
	for slot in checker.contacts_started:
		sim.notify_hit(slot)
	if hits.step(DT, bot.state, null, null, contact) and contact.source == HitDetection.HIT_PROP:
		prop_hits += 1
	dir.step(DT, bot.state)
	if bot.state.v < tuning.scoring.min_speed_mps() - 0.5:
		slow_ticks += 1
	_check_closed_areas()
	for k in ev.size():
		var kind := ev.kind[k]
		if kind == SetPieceSource.KIND_WARNING or kind == SetPieceSource.KIND_STARTED or kind == SetPieceSource.KIND_ENDED:
			piece_log.append([time, kind, ev.tag[k], ev.value[k], ev.points[k]])
			if kind == SetPieceSource.KIND_WARNING:
				checker.note_set_piece_warning(ev.points[k], sim.state, bot.state)
		elif kind == TrafficSim.KIND_HORN:
			horns.append([time, ev.slot[k]])
	ev.clear()


func run(seconds: float) -> void:
	for k in roundi(seconds / DT):
		tick()


## Forces `id` and runs until it is live (null after `limit_s`).
func force(id: StringName, limit_s: float = 40.0) -> SetPieceSource.Instance:
	if not dir.force_set_piece(id):
		return null
	for k in roundi(limit_s / DT):
		tick()
		var inst := running(id)
		if inst != null:
			return inst
	return null


func running(id: StringName) -> SetPieceSource.Instance:
	for inst in dir.set_pieces.instances:
		if inst.stage == SetPieceSource.Stage.RUNNING and inst.def.id == id:
			return inst
	return null


## Runs until the piece has ended (or `limit_s`). True when it ended.
func run_until_ended(inst: SetPieceSource.Instance, limit_s: float) -> bool:
	var serial := inst.serial
	for k in roundi(limit_s / DT):
		tick()
		if dir.set_pieces.instance_by_serial(serial) == null:
			return true
	return false


func events(kind: StringName) -> Array:
	var out: Array = []
	for e: Array in piece_log:
		if e[1] == kind:
			out.append(e)
	return out


## Everything but the piece off the road, and nothing new.
func only_the_piece(inst: SetPieceSource.Instance) -> void:
	dir.set_density_scale(0.0)
	for i in sim.state.capacity:
		if sim.state.active[i] == 1 and dir.set_pieces.instance_of(i) != inst.serial:
			sim.despawn(i)


## The first feature of `kind` of at least `min_len` from s on (NAN: none in 3 legs).
func feature_s(kind: RoadFeature.Kind, from_s: float, min_len: float = 0.0) -> float:
	var end := from_s + tuning.legs.leg_length_m() * 3.0
	road.ensure_generated_to(end)
	var found: Array[RoadFeature] = []
	road.features_in(from_s, end, found)
	for f in found:
		if f.kind == kind and f.s_start >= from_s and f.s_end - f.s_start >= min_len:
			return f.s_start
	return NAN


func _check_closed_areas() -> void:
	var sp := dir.set_pieces
	var ts := sim.state
	for inst in sp.instances:
		if inst.stage != SetPieceSource.Stage.RUNNING:
			continue
		var w := inst.controller as RoadWorksPiece
		if w == null:
			continue
		for i in ts.capacity:
			if ts.active[i] == 0 or ts.s[i] < inst.zone_s0 - ts.length[i] or ts.s[i] > inst.zone_s1 + ts.length[i]:
				continue
			var hl := ts.length[i] * 0.5
			var hw := ts.width[i] * 0.5
			for s: float in [ts.s[i] - hl, ts.s[i], ts.s[i] + hl]:
				if w.in_closed_area(inst, s, ts.d[i] - hw, ts.d[i] + hw):
					closed_area_ticks += 1
					break
