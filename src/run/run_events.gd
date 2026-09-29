class_name RunEvents
extends Node
## The run's Events adapter (docs/CONTRACTS.md §7 table, §14). Spec: Architecture
## rules 4 and 8 (pure sims write into caller-provided buffers; a thin Node adapter
## publishes them on the `Events` bus, which HUD, audio, haptics and camera only
## listen to).
##
## drain() runs once per rendered frame: every registered ScoreEventBuffer is read in
## order, each record becomes its `Events` signal, and the buffer is cleared. Then the
## values without events are compared with the last frame: multiplier_changed and
## chain_changed (ScoringRuleSet), boost_started / boost_ended and
## boost_meter_changed (the player's VehicleState) fire only when they changed.
##
## Set pieces (WP6.2): SetPieceSource's KIND_WARNING / KIND_STARTED / KIND_ENDED (the
## director writes them; tag = the SetPieceDef id, value = the warning distance) become
## set_piece_warning / set_piece_started / set_piece_ended.
## Kinds the run handles at tick time and that are not signals (KIND_SUN_NUDGE ->
## SunClock.lift, Scoring.KIND_NEAR_MISS -> TrafficSim.notify_close_pass) are skipped.
## objective_completed (LegObjectives.KIND_OBJECTIVE_COMPLETED: tag = objective,
## points = bonus paid) is WP5.2's; the leg_started biome is the one at the leg's start.
## checkpoint_crossed's summary Dictionary is built from LegTracker.crossing; its
## bonus_points sums the KIND_BONUS records that follow it in the same frame (the
## run pays the leg bonuses right after the crossing, per the spec's order).
## Signals fire at event rate, so this adapter may allocate (Dictionary, Vector3).

## Summary keys of Events.checkpoint_crossed (events.gd lists the first eight).
const SUMMARY_LEG_INDEX := &"leg_index"
const SUMMARY_CLEAN := &"clean"
const SUMMARY_PACE := &"pace"
const SUMMARY_THREADS := &"threads"
const SUMMARY_HEAT := &"heat"
const SUMMARY_OBJECTIVE_DONE := &"objective_done"
const SUMMARY_BONUS_POINTS := &"bonus_points"
const SUMMARY_AT_NIGHT := &"at_night"
const SUMMARY_OBJECTIVE := &"objective"
const SUMMARY_THREADS_BONUS := &"threads_bonus"
const SUMMARY_CLOSE_PASSES := &"close_passes"
const SUMMARY_HEAT_BEST_S := &"heat_best_s"
const SUMMARY_AVG_SPEED_MPS := &"avg_speed_mps"
const SUMMARY_DISTANCE_M := &"distance_m"
const SUMMARY_DURATION_S := &"duration_s"
const SUMMARY_LANDMARK := &"landmark"
const SUMMARY_COAST := &"coast"
## WP5.2: the objective bonus paid for the leg (after the night factor; 0 = none).
const SUMMARY_OBJECTIVE_POINTS := &"objective_points"

## Scoring: multiplier / chain snapshots (null = none).
var scoring: ScoringRuleSet
## The player's state: boost flags and meter (null = none).
var player: VehicleState
## checkpoint_crossed summaries and the leg objective (null = empty summary).
var legs: LegTracker
## The leg's biome for leg_started (null = &"").
var biome_director: BiomeDirector
## Horn positions (traffic_horn's world_pos); any null gives Vector3.ZERO.
var road: RoadPath
var origin: FloatingOrigin
var traffic: TrafficState
## WP6.5: fork_announced names both branches' biomes (null: none).
var forks: RunForks

## Signals emitted by the last drain() (tests, dev stats).
var emitted_last: int = 0

var _buffers: Array[ScoreEventBuffer] = []
var _last_multiplier: float = NAN
var _last_chain: int = -1
var _last_boosting: bool = false
var _last_boost_fill: float = NAN
var _smp := RoadSample.new()


## Registers a buffer to drain (drained in registration order).
func add_buffer(buf: ScoreEventBuffer) -> void:
	if not _buffers.has(buf):
		_buffers.append(buf)


func clear_buffers() -> void:
	_buffers.clear()


## Forget the change trackers (run start): the next drain re-announces the current
## multiplier, chain and boost meter.
func reset() -> void:
	_last_multiplier = NAN
	_last_chain = -1
	_last_boosting = false
	_last_boost_fill = NAN
	emitted_last = 0


## Once per frame: publish every buffered record, clear the buffers, then the
## change-only values.
func drain() -> void:
	emitted_last = 0
	for buf in _buffers:
		for i in buf.size():
			_emit(buf, i)
		buf.clear()
	_emit_changes()


func _emit(buf: ScoreEventBuffer, i: int) -> void:
	var k := buf.kind[i]
	var v := buf.value[i]
	match k:
		ScoreEvents.PASS, ScoreEvents.CLOSE_PASS, ScoreEvents.CUT, ScoreEvents.THREAD:
			Events.scored.emit(k, buf.points[i], buf.multiplier[i], buf.clearance_m[i])
		ScoringRuleSet.KIND_BANKED:
			Events.chain_banked.emit(buf.points[i], buf.tag[i], int(v))
		ScoringRuleSet.KIND_CHAIN_LOST:
			Events.chain_lost.emit(buf.points[i], buf.tag[i])
		ScoringRuleSet.KIND_HESITATED:
			Events.hesitated.emit()
		ScoringRuleSet.KIND_TOO_SLOW:
			Events.too_slow_changed.emit(v != 0.0)
		ScoringRuleSet.KIND_SHOULDER:
			Events.shoulder_penalty_changed.emit(v != 0.0)
		ScoringRuleSet.KIND_SLIPSTREAM:
			Events.slipstream_changed.emit(v != 0.0)
		ScoringRuleSet.KIND_BONUS:
			Events.bonus_awarded.emit(buf.tag[i], buf.points[i], int(v))
		SunClock.KIND_NIGHT_STARTED:
			Events.night_started.emit()
		SunClock.KIND_DAWN_STARTED:
			Events.dawn_started.emit(v)
		SunClock.KIND_MORNING_REACHED:
			Events.morning_reached.emit()
		SunClock.KIND_SUN_LIFTED:
			Events.sun_lifted.emit(v)
		Lives.KIND_HIT:
			Events.hit.emit(buf.tag[i], int(v))
		Lives.KIND_GHOST_STARTED:
			Events.ghost_started.emit(v)
		Lives.KIND_GHOST_ENDED:
			Events.ghost_ended.emit()
		Lives.KIND_LIFE_RESTORED:
			Events.life_restored.emit(int(v))
		LegTracker.KIND_CHECKPOINT_WARNING:
			Events.checkpoint_warning.emit(v)
		LegTracker.KIND_CHECKPOINT_CROSSED:
			Events.checkpoint_crossed.emit(int(v), _summary(int(v), _bonus_points_after(buf, i)))
		LegTracker.KIND_LEG_STARTED:
			Events.leg_started.emit(int(v), _biome_id(), legs.objective if legs != null else &"")
		LegTracker.KIND_COAST_REACHED:
			Events.coast_reached.emit()
		RunForks.KIND_FORK_ANNOUNCED:
			if forks == null:
				return
			Events.fork_announced.emit(forks.left_id(int(v)), forks.right_id(int(v)))
		RunForks.KIND_FORK_TAKEN:
			Events.fork_taken.emit(buf.tag[i])
		RunFinale.KIND_JOURNEY_COMPLETE:
			Events.journey_complete.emit()
		LegObjectives.KIND_OBJECTIVE_COMPLETED:
			Events.objective_completed.emit(buf.tag[i], buf.points[i])
		TrafficSim.KIND_HORN:
			Events.traffic_horn.emit(buf.slot[i], _slot_position(buf.slot[i]))
		TrafficSim.KIND_BRAKE_TAP:
			Events.traffic_brake_tap.emit(buf.slot[i])
		TrafficSim.KIND_HAZARDS:
			Events.traffic_hazards.emit(buf.slot[i], v != 0.0)
		SetPieceSource.KIND_WARNING:
			Events.set_piece_warning.emit(buf.tag[i], v)
		SetPieceSource.KIND_STARTED:
			Events.set_piece_started.emit(buf.tag[i])
		SetPieceSource.KIND_ENDED:
			Events.set_piece_ended.emit(buf.tag[i])
		_:
			return   # tick-time kinds (sun nudge, near miss) and unknown kinds
	emitted_last += 1


func _emit_changes() -> void:
	if scoring != null:
		var m := scoring.multiplier()
		if m != _last_multiplier:
			_last_multiplier = m
			Events.multiplier_changed.emit(m)
			emitted_last += 1
		var c := scoring.chain()
		if c != _last_chain:
			_last_chain = c
			Events.chain_changed.emit(c)
			emitted_last += 1
	if player != null:
		if player.boost_active != _last_boosting:
			_last_boosting = player.boost_active
			if _last_boosting:
				Events.boost_started.emit()
			else:
				Events.boost_ended.emit()
			emitted_last += 1
		if player.boost_meter != _last_boost_fill:
			_last_boost_fill = player.boost_meter
			Events.boost_meter_changed.emit(player.boost_meter)
			emitted_last += 1


## Leg bonus points paid for the crossing at record i (the KIND_BONUS records up to
## the next crossing in this buffer).
func _bonus_points_after(buf: ScoreEventBuffer, i: int) -> int:
	var total := 0
	for j in range(i + 1, buf.size()):
		var k := buf.kind[j]
		if k == LegTracker.KIND_CHECKPOINT_CROSSED:
			break
		if k == ScoringRuleSet.KIND_BONUS:
			total += buf.points[j]
	return total


func _summary(leg_index: int, bonus_points: int) -> Dictionary:
	var out := {
		SUMMARY_LEG_INDEX: leg_index,
		SUMMARY_BONUS_POINTS: bonus_points,
	}
	if legs == null:
		return out
	var c := legs.crossing
	out[SUMMARY_CLEAN] = c.clean
	out[SUMMARY_PACE] = c.pace
	out[SUMMARY_THREADS] = c.threads
	out[SUMMARY_HEAT] = c.heat
	out[SUMMARY_OBJECTIVE_DONE] = c.objective_done
	out[SUMMARY_AT_NIGHT] = c.at_night
	out[SUMMARY_OBJECTIVE] = c.objective
	out[SUMMARY_THREADS_BONUS] = c.threads_bonus
	out[SUMMARY_CLOSE_PASSES] = c.close_passes
	out[SUMMARY_HEAT_BEST_S] = c.heat_best_s
	out[SUMMARY_AVG_SPEED_MPS] = c.avg_speed_mps
	out[SUMMARY_DISTANCE_M] = c.distance_m
	out[SUMMARY_DURATION_S] = c.duration_s
	out[SUMMARY_LANDMARK] = c.landmark
	out[SUMMARY_COAST] = c.coast
	out[SUMMARY_OBJECTIVE_POINTS] = c.objective_points
	return out


func _biome_id() -> StringName:
	if biome_director == null:
		return &""
	var b: BiomeDef = biome_director.biome_at(legs.leg_start_s()) if legs != null else biome_director.current()
	return b.id if b != null else &""


func _slot_position(slot: int) -> Vector3:
	if road == null or origin == null or traffic == null or slot < 0 or slot >= traffic.capacity:
		return Vector3.ZERO
	road.sample_into(traffic.s[slot], _smp)
	return _smp.local_point(traffic.d[slot], origin.origin_x, origin.origin_y, origin.origin_z)
