class_name RunStats
extends RefCounted
# lint: sim
## The run's result stats. Spec: Run end ("total score, distance, legs completed,
## whether the coast was reached, best chain, best multiplier, threads, close passes,
## top speed, time spent at night and hits").
##
## Pure and headless. The run feeds it once per 120 Hz tick: observe_tick() with the
## player's speed, position and the night flag, and consume() over the event records
## the sims wrote this tick (the same ScoreEventBuffer the RunEvents adapter drains).
## Both are allocation-free. results() builds the Events.run_over payload (run end
## only; it allocates).
##
## Best chain: a chain only grows until it is banked or lost, so the largest banked or
## lost amount (checkpoint, cash-out, hit, hesitation, run end) is the best chain.

const KIND_HIT := &"hit"
const KIND_CHECKPOINT_CROSSED := &"checkpoint_crossed"
const KIND_COAST_REACHED := &"coast_reached"
## WP6.5 (RunFinale.KIND_JOURNEY_COMPLETE).
const KIND_JOURNEY_COMPLETE := &"journey_complete"

## Result keys (Events.run_over payload).
const SCORE := &"score"
const DISTANCE_M := &"distance_m"
const LEGS_COMPLETED := &"legs_completed"
const COAST_REACHED := &"coast_reached"
const BEST_CHAIN := &"best_chain"
const BEST_MULTIPLIER := &"best_multiplier"
const THREADS := &"threads"
const CLOSE_PASSES := &"close_passes"
const TOP_SPEED_KMH := &"top_speed_kmh"
const NIGHT_TIME_S := &"night_time_s"
const HITS := &"hits"
const SEED := &"seed"
const MODE := &"mode"
## Extra keys (not in the spec list, useful for the results screen).
const PASSES := &"passes"
const CUTS := &"cuts"
const DURATION_S := &"duration_s"
## WP6.5: "Journey complete" was recorded, and the run time / distance to it.
const JOURNEY_COMPLETE := &"journey_complete"
const JOURNEY_TIME_S := &"journey_time_s"
const JOURNEY_DISTANCE_M := &"journey_distance_m"

var start_s: float = 0.0
var distance_m: float = 0.0
var duration_s: float = 0.0
var legs_completed: int = 0
var coast_reached: bool = false
var journey_complete: bool = false
var journey_time_s: float = 0.0
var journey_distance_m: float = 0.0
var best_chain: int = 0
var best_multiplier: float = 1.0
## Scored passes (pass + close pass), close passes, threads and cuts.
var passes: int = 0
var close_passes: int = 0
var threads: int = 0
var cuts: int = 0
var top_speed_mps: float = 0.0
var night_time_s: float = 0.0
## Hits that counted (the hit events; the ghost ignores contacts, so none repeat).
var hits: int = 0


func _init(run_start_s: float = 0.0) -> void:
	reset(run_start_s)


func reset(run_start_s: float = 0.0) -> void:
	start_s = run_start_s
	distance_m = 0.0
	duration_s = 0.0
	legs_completed = 0
	coast_reached = false
	journey_complete = false
	journey_time_s = 0.0
	journey_distance_m = 0.0
	best_chain = 0
	best_multiplier = 1.0
	passes = 0
	close_passes = 0
	threads = 0
	cuts = 0
	top_speed_mps = 0.0
	night_time_s = 0.0
	hits = 0


## Once per tick: the player's forward speed and position, the sun clock's night flag
## and the scoring multiplier after this tick.
func observe_tick(dt: float, speed_mps: float, player_s: float, is_night: bool, multiplier: float) -> void:
	duration_s += dt
	distance_m = maxf(distance_m, player_s - start_s)
	top_speed_mps = maxf(top_speed_mps, speed_mps)
	best_multiplier = maxf(best_multiplier, multiplier)
	if is_night:
		night_time_s += dt


## The records [from, to) of `buf` (written this tick). Allocation-free.
func consume(buf: ScoreEventBuffer, from: int, to: int) -> void:
	for i in range(from, to):
		var k := buf.kind[i]
		if k == ScoreEvents.PASS:
			passes += 1
		elif k == ScoreEvents.CLOSE_PASS:
			passes += 1
			close_passes += 1
		elif k == ScoreEvents.THREAD:
			threads += 1
		elif k == ScoreEvents.CUT:
			cuts += 1
		elif k == ScoringRuleSet.KIND_BANKED or k == ScoringRuleSet.KIND_CHAIN_LOST:
			best_chain = maxi(best_chain, buf.points[i])
		elif k == KIND_HIT:
			hits += 1
		elif k == KIND_CHECKPOINT_CROSSED:
			legs_completed += 1
		elif k == KIND_COAST_REACHED:
			coast_reached = true
		elif k == KIND_JOURNEY_COMPLETE and not journey_complete:
			journey_complete = true
			journey_time_s = duration_s
			journey_distance_m = distance_m


## The Events.run_over payload (allocates; run end only).
func results(score: int, run_seed: int, run_mode: StringName) -> Dictionary:
	return {
		SCORE: score,
		DISTANCE_M: distance_m,
		LEGS_COMPLETED: legs_completed,
		COAST_REACHED: coast_reached,
		BEST_CHAIN: best_chain,
		BEST_MULTIPLIER: best_multiplier,
		THREADS: threads,
		CLOSE_PASSES: close_passes,
		TOP_SPEED_KMH: Units.mps_to_kmh(top_speed_mps),
		NIGHT_TIME_S: night_time_s,
		HITS: hits,
		SEED: run_seed,
		MODE: run_mode,
		PASSES: passes,
		CUTS: cuts,
		DURATION_S: duration_s,
		JOURNEY_COMPLETE: journey_complete,
		JOURNEY_TIME_S: journey_time_s,
		JOURNEY_DISTANCE_M: journey_distance_m,
	}


## Mixes the stats into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_float(h, distance_m)
	h = TraceHash.mix_int(h, legs_completed)
	h = TraceHash.mix_int(h, best_chain)
	h = TraceHash.mix_float(h, best_multiplier)
	h = TraceHash.mix_int(h, passes)
	h = TraceHash.mix_int(h, close_passes)
	h = TraceHash.mix_int(h, threads)
	h = TraceHash.mix_int(h, cuts)
	h = TraceHash.mix_float(h, top_speed_mps)
	h = TraceHash.mix_float(h, night_time_s)
	h = TraceHash.mix_bool(h, journey_complete)
	return TraceHash.mix_int(h, hits)
