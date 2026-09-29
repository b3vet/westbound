class_name LegTracker
extends RefCounted
# lint: sim
## Leg and checkpoint bookkeeping. Spec: Core loop -> Legs and checkpoints (legs
## ~3.5 km, warning signs at 1 km and 500 m, the crossing sequence, leg bonuses
## Clean / Pace / Threads / Heat, the leg objective), The journey goal (the coast
## after 8 legs, then the endless coastal highway). See docs/CORE_LOOP.md.
##
## Pure and headless. It owns no score and no sun: it turns the road's CHECKPOINT and
## SIGN features plus the facts the run forwards (hits, threads, close passes, the
## multiplier) into per-leg facts. When step() reports a crossing, `crossing` holds
## the summary and run.gd dispatches the spec's order:
##   1. scoring.notify_checkpoint()            (bank the chain)
##   2. sun_clock.on_checkpoint(avg_speed)     (lift, or dawn at night)
##   3. scoring.award_bonus() per earned bonus (crossing.bonus_kind / bonus_base_points)
##   4. lives.restore_life() if crossing.clean
##   5. the 2.5 s toast (HUD, from the checkpoint_crossed signal)
##
## Rates: plan_ahead() is director rate (it queries road features and may allocate);
## step(), observe_multiplier() and the notify_* calls are tick-safe and
## allocation-free. Checkpoints and signs come only from features, so leg lengths are
## whatever the road generated (ProceduralRoadPath: every legs.leg_length_km).

const KIND_CHECKPOINT_WARNING := &"checkpoint_warning"   ## value = distance announced (m)
const KIND_CHECKPOINT_CROSSED := &"checkpoint_crossed"   ## value = leg index (1-based); details in `crossing`
const KIND_LEG_STARTED := &"leg_started"                 ## value = the new leg's index
const KIND_COAST_REACHED := &"coast_reached"

const BONUS_CLEAN := &"clean"
const BONUS_PACE := &"pace"
const BONUS_THREADS := &"threads"
const BONUS_HEAT := &"heat"
const BONUS_OBJECTIVE := &"objective"

## Upcoming checkpoints and checkpoint signs held at once (a few legs of look-ahead).
const QUEUE_CAPACITY := 16
## Absorbs float accumulation of dt in the heat hold (1800 x 1/120 s == 15 s).
const TIME_EPS_S := 1e-9   # lint: allow-number float accumulation tolerance, not tuning


## The facts of one checkpoint crossing (preallocated, overwritten per crossing).
class Crossing:
	extends RefCounted
	var leg_index: int = 0          ## the leg that ended here (1-based, from the feature)
	var s: float = 0.0              ## checkpoint line
	var landmark: StringName = &""  ## feature tag (BiomeDef.LANDMARK_*)
	var distance_m: float = 0.0     ## leg length driven (from the previous line or the run start)
	var duration_s: float = 0.0
	var avg_speed_mps: float = 0.0
	var clean: bool = false         ## no hit during the leg
	var pace: bool = false          ## avg speed >= the pace target
	var threads: int = 0
	var threads_bonus: bool = false ## threads >= bonus_threads_min_count
	var close_passes: int = 0
	var heat_best_s: float = 0.0    ## longest continuous hold at >= bonus_heat_multiplier
	var heat: bool = false          ## heat_best_s >= bonus_heat_hold_s
	var objective: StringName = &""
	var objective_done: bool = false
	var objective_points: int = 0   ## the objective bonus paid for this leg (after the night factor)
	var at_night: bool = false      ## finished at night (leg bonuses x2)
	var coast: bool = false         ## this crossing reached the coast

	## Earned leg bonuses (Clean, Pace, Threads, Heat order; the objective is separate).
	func bonus_count() -> int:
		return int(clean) + int(pace) + int(threads_bonus) + int(heat)

	## Kind of the i-th earned bonus (0 <= i < bonus_count()).
	func bonus_kind(i: int) -> StringName:
		var k := -1
		if clean:
			k += 1
			if k == i:
				return BONUS_CLEAN
		if pace:
			k += 1
			if k == i:
				return BONUS_PACE
		if threads_bonus:
			k += 1
			if k == i:
				return BONUS_THREADS
		if heat:
			k += 1
			if k == i:
				return BONUS_HEAT
		return &""

	## Base points (before the night factor, which scoring applies) of the i-th bonus.
	func bonus_base_points(i: int, legs: LegsTuning) -> int:
		match bonus_kind(i):
			BONUS_CLEAN:
				return legs.bonus_clean_points
			BONUS_PACE:
				return legs.bonus_pace_points
			BONUS_THREADS:
				return legs.bonus_threads_points
			BONUS_HEAT:
				return legs.bonus_heat_points
		return 0


## Summary of the last crossing (valid after step() returned true).
var crossing := Crossing.new()
## The leg being driven (1-based).
var leg_index: int = 1
var legs_completed: int = 0
var coast_reached: bool = false
## The current leg's objective (&"" = none). Set by the run at leg start (Phase 5).
var objective: StringName = &""

var _legs: LegsTuning
var _pace_target_mps: float

var _leg_start_s: float = 0.0
var _leg_time_s: float = 0.0
var _hit: bool = false
var _threads: int = 0
var _close_passes: int = 0
var _heat_run_s: float = 0.0
var _heat_best_s: float = 0.0
var _objective_done: bool = false
var _objective_points: int = 0

var _planned_to: float = 0.0
var _cp_s := PackedFloat64Array()
var _cp_leg := PackedInt32Array()
var _cp_tag: Array[StringName] = []
var _cp_head: int = 0
var _cp_count: int = 0
var _sign_s := PackedFloat64Array()
var _sign_dist := PackedFloat64Array()
var _sign_head: int = 0
var _sign_count: int = 0


func _init(legs: LegsTuning) -> void:
	_legs = legs
	_pace_target_mps = legs.pace_target_mps()
	_cp_s.resize(QUEUE_CAPACITY)
	_cp_leg.resize(QUEUE_CAPACITY)
	_cp_tag.resize(QUEUE_CAPACITY)
	_cp_tag.fill(&"")
	_sign_s.resize(QUEUE_CAPACITY)
	_sign_dist.resize(QUEUE_CAPACITY)
	reset(0.0)


## New run starting at `start_s` (leg 1 begins there).
func reset(start_s: float) -> void:
	leg_index = 1
	legs_completed = 0
	coast_reached = false
	_planned_to = start_s
	_cp_head = 0
	_cp_count = 0
	_sign_head = 0
	_sign_count = 0
	_start_leg(start_s)


## Director rate: queues the CHECKPOINT features and checkpoint SIGN features up to
## `s_to` (generating the road that far). Call it well ahead of the player, e.g. with
## each traffic batch; repeated or overlapping calls never queue a feature twice.
func plan_ahead(road: RoadPath, s_to: float) -> void:
	road.ensure_generated_to(s_to)
	var hi := minf(s_to, road.length_generated())
	if hi <= _planned_to:
		return
	_compact()
	var found: Array[RoadFeature] = []
	road.features_in(_planned_to, hi, found)
	for f in found:
		if f.s_start < _planned_to:
			continue   # an extended feature that started before the planned range
		if f.kind == RoadFeature.Kind.CHECKPOINT:
			if _cp_count >= QUEUE_CAPACITY:
				hi = f.s_start   # full: plan the rest next time
				break
			_cp_s[_cp_count] = f.s_start
			_cp_leg[_cp_count] = int(f.value)
			_cp_tag[_cp_count] = f.tag
			_cp_count += 1
		elif f.kind == RoadFeature.Kind.SIGN and f.tag == ProceduralRoadPath.SIGN_CHECKPOINT:
			if _sign_count >= QUEUE_CAPACITY:
				hi = f.s_start
				break
			_sign_s[_sign_count] = f.s_start
			_sign_dist[_sign_count] = f.value
			_sign_count += 1
	_planned_to = hi


## One tick, after the player moved to `player_s`. Emits checkpoint warnings as the
## player passes each sign, and on crossing a checkpoint fills `crossing`, emits
## checkpoint_crossed (+ coast_reached once) and leg_started, and returns true.
## `is_night`: the sun clock's is_night() before the crossing is dispatched.
func step(dt: float, player_s: float, is_night: bool, out: ScoreEventBuffer) -> bool:
	_leg_time_s += dt
	while _sign_head < _sign_count and player_s >= _sign_s[_sign_head]:
		out.push(KIND_CHECKPOINT_WARNING, 0, 0.0, -1.0, -1, _sign_dist[_sign_head])
		_sign_head += 1
	if _cp_head >= _cp_count or player_s < _cp_s[_cp_head]:
		return false
	var cp_s := _cp_s[_cp_head]
	var c := crossing
	c.leg_index = _cp_leg[_cp_head]
	c.s = cp_s
	c.landmark = _cp_tag[_cp_head]
	_cp_head += 1
	c.distance_m = cp_s - _leg_start_s
	c.duration_s = _leg_time_s
	c.avg_speed_mps = c.distance_m / _leg_time_s if _leg_time_s > 0.0 else 0.0
	c.clean = not _hit
	c.pace = c.avg_speed_mps >= _pace_target_mps
	c.threads = _threads
	c.threads_bonus = _threads >= _legs.bonus_threads_min_count
	c.close_passes = _close_passes
	c.heat_best_s = _heat_best_s
	c.heat = _heat_best_s >= _legs.bonus_heat_hold_s - TIME_EPS_S
	c.objective = objective
	c.objective_done = _objective_done
	c.objective_points = _objective_points
	c.at_night = is_night
	c.coast = not coast_reached and c.leg_index >= _legs.legs_to_coast
	legs_completed += 1
	out.push(KIND_CHECKPOINT_CROSSED, 0, 0.0, -1.0, -1, float(c.leg_index))
	if c.coast:
		coast_reached = true
		out.push(KIND_COAST_REACHED)
	leg_index = c.leg_index + 1
	_start_leg(cp_s)
	out.push(KIND_LEG_STARTED, 0, 0.0, -1.0, -1, float(leg_index))
	return true


## The multiplier this tick (Heat: held at >= bonus_heat_multiplier for bonus_heat_hold_s).
func observe_multiplier(dt: float, multiplier: float) -> void:
	if multiplier >= _legs.bonus_heat_multiplier:
		_heat_run_s += dt
		if _heat_run_s > _heat_best_s:
			_heat_best_s = _heat_run_s
	else:
		_heat_run_s = 0.0


## A hit that counted (not during the ghost): the leg is no longer clean.
func notify_hit() -> void:
	_hit = true


func notify_thread() -> void:
	_threads += 1


func notify_close_pass() -> void:
	_close_passes += 1


## Objective hook: the run sets the leg's objective at leg start (LegObjectives)...
func set_objective(id: StringName) -> void:
	objective = id
	_objective_done = false
	_objective_points = 0


## ...and marks it done when its condition is met (evaluated by LegObjectives), with the
## bonus paid for it (after the night factor; carried into the crossing summary).
func complete_objective(points: int = 0) -> void:
	if objective != &"":
		_objective_done = true
		_objective_points = points


## A "no X" objective is judged at the line, after step() already filled `crossing`
## (and started the next leg): the run marks the crossing's objective done here.
func complete_crossing_objective(points: int) -> void:
	if crossing.objective != &"":
		crossing.objective_done = true
		crossing.objective_points = points


func is_objective_done() -> bool:
	return _objective_done


## Where the current leg began (the last checkpoint line, or the run start).
func leg_start_s() -> float:
	return _leg_start_s


func threads_in_leg() -> int:
	return _threads


func close_passes_in_leg() -> int:
	return _close_passes


func is_leg_clean() -> bool:
	return not _hit


## Distance from `player_s` to the next queued checkpoint (HUD sun bar), or INF.
func distance_to_checkpoint(player_s: float) -> float:
	if _cp_head >= _cp_count:
		return INF
	return _cp_s[_cp_head] - player_s


## Mixes the tracker state into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_int(h, leg_index)
	h = TraceHash.mix_int(h, legs_completed)
	h = TraceHash.mix_bool(h, coast_reached)
	h = TraceHash.mix_float(h, _leg_start_s)
	h = TraceHash.mix_float(h, _leg_time_s)
	h = TraceHash.mix_bool(h, _hit)
	h = TraceHash.mix_int(h, _threads)
	h = TraceHash.mix_int(h, _close_passes)
	h = TraceHash.mix_float(h, _heat_run_s)
	h = TraceHash.mix_float(h, _heat_best_s)
	h = TraceHash.mix_int(h, _cp_count - _cp_head)
	return TraceHash.mix_int(h, _sign_count - _sign_head)


func _start_leg(start_s: float) -> void:
	_leg_start_s = start_s
	_leg_time_s = 0.0
	_hit = false
	_threads = 0
	_close_passes = 0
	_heat_run_s = 0.0
	_heat_best_s = 0.0
	objective = &""
	_objective_done = false
	_objective_points = 0


## Drops consumed queue entries (director rate).
func _compact() -> void:
	var n := 0
	for i in range(_cp_head, _cp_count):
		_cp_s[n] = _cp_s[i]
		_cp_leg[n] = _cp_leg[i]
		_cp_tag[n] = _cp_tag[i]
		n += 1
	_cp_count = n
	_cp_head = 0
	n = 0
	for i in range(_sign_head, _sign_count):
		_sign_s[n] = _sign_s[i]
		_sign_dist[n] = _sign_dist[i]
		n += 1
	_sign_count = n
	_sign_head = 0
