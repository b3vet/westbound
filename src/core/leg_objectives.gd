class_name LegObjectives
extends RefCounted
# lint: sim
## The leg objective: one optional goal per leg, shown on entry, paying a bonus when
## completed. Spec: Core loop -> Legs and checkpoints ("Each leg shows one optional
## objective on entry, such as '5 close passes', 'thread twice' or 'no braking'.
## Completing it pays a bonus."); Scoring -> Chain and banking ("Bonuses. Leg bonuses,
## objectives and the journey bonus go straight into the banked total").
## docs/CORE_LOOP.md -> Leg objectives.
##
## Pure, headless, deterministic by seed and allocation-free per tick. It owns only the
## objective's state; the run pays the bonus and tells the LegTracker:
##
##   objectives.reset(ctx)                              # run start (derives its Rng stream)
##   legs.set_objective(objectives.start_leg(legs.leg_index))   # every leg start
##   if objectives.notify_scored(kind): pay               # ScoreEvents.CLOSE_PASS/THREAD/CUT
##   if objectives.step(dt, brake, v, slipstream, shoulder): pay   # once per tick
##   if objectives.finish_leg(): pay                    # at the crossing ("no X" objectives)
##
## Each of those returns true exactly once per leg, on the tick the objective completes,
## so the bonus is paid exactly once: when it is reached for the counting, reaching and
## holding objectives, at the checkpoint for the "no X" ones (they can only be judged
## there). The catalog's numbers are LegsTuning.objective_*.
##
## Choice: one draw per leg from `ctx.rng_events.derive(STREAM)`, uniform over
## LegsTuning.objective_pool minus the previous leg's objective (never twice in a row).
## Legs before objective_first_leg get none (and draw nothing).

## The run's event kind for a completion: tag = objective id, points = bonus paid
## (after the night factor). The adapter emits Events.objective_completed.
const KIND_OBJECTIVE_COMPLETED := &"objective_completed"
## Rng stream under ctx.rng_events.
const STREAM := &"objectives"

## Catalog ids.
const CLOSE_PASSES := &"close_passes"   ## N close passes (scored)
const THREADS := &"threads"             ## N threads
const CUTS := &"cuts"                   ## N cuts
const TOP_SPEED := &"top_speed"         ## reach the speed once
const SLIPSTREAM := &"slipstream"       ## N seconds of slipstream in the leg (added up)
const NO_BRAKING := &"no_braking"       ## no brake input for the whole leg
const NO_SHOULDER := &"no_shoulder"     ## no wheel on the shoulder for the whole leg

## How an objective is judged.
enum Rule {
	NONE,
	COUNT,   ## a counter reaches a target; completes at once
	REACH,   ## a value reaches a target once; completes at once
	HOLD,    ## time with a flag on adds up to a target; completes at once
	AVOID,   ## never do X after the grace; completes at the checkpoint
}

## Absorbs float accumulation of dt in the slipstream total (600 x 1/120 s == 5 s).
const TIME_EPS_S := 1e-9   # lint: allow-number float accumulation tolerance, not tuning

const _WORD_CLOSE := "CLOSE PASSES"
const _WORD_THREAD_TWICE := "THREAD TWICE"
const _WORD_THREADS := "THREADS"
const _WORD_CUTS := "CUTS"
const _WORD_HIT := "HIT"
const _WORD_KMH := "KM/H"
const _WORD_MPH := "MPH"
const _WORD_SLIP := "S OF SLIPSTREAM"
const _WORD_NO_BRAKING := "NO BRAKING"
const _WORD_NO_SHOULDER := "NO SHOULDER"

var _legs: LegsTuning
var _pool: Array[StringName] = []
var _rng: Rng

var _id: StringName = &""
var _last: StringName = &""
var _rule: Rule = Rule.NONE
var _target: int = 0
var _count: int = 0
var _held_s: float = 0.0
var _leg_s: float = 0.0
var _done: bool = false
var _failed: bool = false
var _top_speed_mps: float = 0.0


func _init(legs: LegsTuning) -> void:
	_legs = legs
	_top_speed_mps = legs.objective_top_speed_mps()
	for id in legs.objective_pool:
		if rule_of(id) != Rule.NONE and not _pool.has(id):
			_pool.append(id)
	_rng = Rng.new(0)


## New run: the choice stream restarts from the run seed. No objective until start_leg().
func reset(ctx: RunContext) -> void:
	_rng = ctx.rng_events.derive(STREAM)
	_last = &""
	_clear(&"")


## The ids that can be drawn (the tuning pool, known ids only, in pool order).
func pool() -> Array[StringName]:
	return _pool


## Leg start: draws the leg's objective (&"" before objective_first_leg or with an empty
## pool) and returns it. Call once per leg, in leg order.
func start_leg(leg_index: int) -> StringName:
	var id := &""
	if leg_index >= _legs.objective_first_leg and not _pool.is_empty():
		id = _pick()
		_last = id
	_clear(id)
	return id


## Dev and tests: replaces the current objective (progress restarts). The next draw
## still avoids the drawn one, so the seeded sequence is unchanged.
func force(id: StringName) -> void:
	_clear(id if rule_of(id) != Rule.NONE else &"")


## A scored event (ScoreEvents.PASS / CLOSE_PASS / CUT / THREAD). True when it completes
## the objective.
func notify_scored(kind: StringName) -> bool:
	if _rule != Rule.COUNT or _done:
		return false
	if (_id == CLOSE_PASSES and kind == ScoreEvents.CLOSE_PASS) \
			or (_id == THREADS and kind == ScoreEvents.THREAD) \
			or (_id == CUTS and kind == ScoreEvents.CUT):
		_count += 1
		if _count >= _target:
			_done = true
			return true
	return false


## One tick (RUNNING). `brake` is the controller's brake input (0..1), `speed_mps` the
## player's speed, `slipstream` / `on_shoulder` the scoring flags this tick. True when
## this tick completes the objective. Allocation-free.
func step(dt: float, brake: float, speed_mps: float, slipstream: bool, on_shoulder: bool) -> bool:
	if _rule == Rule.NONE or _done or _failed:
		return false
	_leg_s += dt
	match _rule:
		Rule.REACH:
			if speed_mps >= _top_speed_mps:
				_done = true
				return true
		Rule.HOLD:
			if slipstream:
				_held_s += dt
				_count = mini(floori(_held_s + TIME_EPS_S), _target)
				if _held_s >= _legs.objective_slipstream_s - TIME_EPS_S:
					_count = _target
					_done = true
					return true
		Rule.AVOID:
			if _leg_s > _legs.objective_avoid_grace_s:
				if (_id == NO_BRAKING and brake > _legs.objective_brake_threshold) \
						or (_id == NO_SHOULDER and on_shoulder):
					_failed = true
	return false


## The checkpoint line: a "no X" objective that never failed completes here. True when
## it does (the run pays it with the leg bonuses).
func finish_leg() -> bool:
	if _rule != Rule.AVOID or _done or _failed:
		return false
	_done = true
	return true


func current() -> StringName:
	return _id


func is_done() -> bool:
	return _done


func is_failed() -> bool:
	return _failed


## HUD progress: `progress() / target()` ("3/5"); target 0 = no count to show.
func progress() -> int:
	return _count


func target() -> int:
	return _target


## Mixes the objective state into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_int(h, _pool.find(_id))
	h = TraceHash.mix_int(h, _pool.find(_last))
	h = TraceHash.mix_int(h, _count)
	h = TraceHash.mix_float(h, _held_s)
	h = TraceHash.mix_float(h, _leg_s)
	h = TraceHash.mix_bool(h, _done)
	return TraceHash.mix_bool(h, _failed)


## How `id` is judged (Rule.NONE for an unknown id).
static func rule_of(id: StringName) -> Rule:
	match id:
		CLOSE_PASSES, THREADS, CUTS:
			return Rule.COUNT
		TOP_SPEED:
			return Rule.REACH
		SLIPSTREAM:
			return Rule.HOLD
		NO_BRAKING, NO_SHOULDER:
			return Rule.AVOID
	return Rule.NONE


## Every catalog id.
static func catalog() -> Array[StringName]:
	return [CLOSE_PASSES, THREADS, CUTS, TOP_SPEED, SLIPSTREAM, NO_BRAKING, NO_SHOULDER]


## Completes at the checkpoint (a "no X" objective) rather than when reached.
static func completes_at_checkpoint(id: StringName) -> bool:
	return rule_of(id) == Rule.AVOID


## The count shown as progress (0 = none: reach and avoid objectives).
static func target_of(id: StringName, legs: LegsTuning) -> int:
	match id:
		CLOSE_PASSES:
			return legs.objective_close_passes_count
		THREADS:
			return legs.objective_threads_count
		CUTS:
			return legs.objective_cuts_count
		SLIPSTREAM:
			return ceili(legs.objective_slipstream_s - TIME_EPS_S)
	return 0


## The HUD text ("5 CLOSE PASSES", "THREAD TWICE", "HIT 250 KM/H"). UI rate: builds a
## String, so never call it per tick.
static func label(id: StringName, legs: LegsTuning, miles: bool = false) -> String:
	match id:
		CLOSE_PASSES:
			return "%d %s" % [legs.objective_close_passes_count, _WORD_CLOSE]
		THREADS:
			if legs.objective_threads_count == 2:
				return _WORD_THREAD_TWICE
			return "%d %s" % [legs.objective_threads_count, _WORD_THREADS]
		CUTS:
			return "%d %s" % [legs.objective_cuts_count, _WORD_CUTS]
		TOP_SPEED:
			var v := legs.objective_top_speed_kmh
			if miles:
				return "%s %d %s" % [_WORD_HIT, roundi(Units.kmh_to_mph(v)), _WORD_MPH]
			return "%s %d %s" % [_WORD_HIT, roundi(v), _WORD_KMH]
		SLIPSTREAM:
			return "%s %s" % [_fmt_s(legs.objective_slipstream_s), _WORD_SLIP]
		NO_BRAKING:
			return _WORD_NO_BRAKING
		NO_SHOULDER:
			return _WORD_NO_SHOULDER
	return String(id).to_upper().replace("_", " ")


static func _fmt_s(s: float) -> String:
	if is_equal_approx(s, roundf(s)):
		return str(roundi(s))
	return str(snappedf(s, 0.1))   # lint: allow-number one decimal for display


func _pick() -> StringName:
	var n := _pool.size()
	var skip := _pool.find(_last)
	if n == 1:
		return _pool[0]
	var k := _rng.int_range(0, n - 1 if skip < 0 else n - 2)
	if skip >= 0 and k >= skip:
		k += 1
	return _pool[k]


func _clear(id: StringName) -> void:
	_id = id
	_rule = rule_of(id)
	_target = target_of(id, _legs)
	_count = 0
	_held_s = 0.0
	_leg_s = 0.0
	_done = false
	_failed = false
