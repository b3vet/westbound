class_name ScoringRuleSet
extends RefCounted
## Scoring rules for one mode, swappable per mode. Base contract (pure, headless).
## Spec: Scoring; Hooks to build in v1 ("scoring rules as a swappable rule set per
## mode"). WP3.4 implements the Chase-the-Sun rules (src/scoring/scoring.gd); future
## modes (Car Hopper, Tempo Highway) subclass this. See docs/CONTRACTS.md "Scoring".
##
## Flow per physics tick (120 Hz), after vehicle physics and traffic_sim:
##   rules.step(dt, player, traffic, road, events)
## run.gd forwards game facts through the notify_* / set_* methods. The rule set owns
## the multiplier, the unbanked chain, the banked total and scoring timers; it reads
## everything else. step() and the notify methods must not allocate.
##
## Event kinds written to out_events besides the Events score kinds
## (Events.PASS / CLOSE_PASS / CUT / THREAD: points, multiplier, clearance_m, slot):

const KIND_BANKED := &"banked"            ## points = amount, tag = Events.REASON_*, value = banked total
const KIND_CHAIN_LOST := &"chain_lost"    ## points = amount, tag = Events.REASON_*
const KIND_HESITATED := &"hesitated"
const KIND_TOO_SLOW := &"too_slow"        ## value = 1 on, 0 off
const KIND_SHOULDER := &"shoulder_penalty"   ## value = 1 on, 0 off
const KIND_SLIPSTREAM := &"slipstream"    ## value = 1 on, 0 off
const KIND_BONUS := &"bonus"              ## tag = bonus kind, points, value = banked total
## Sun nudges earned by play (thread; N close passes within a window). value = fraction
## of the day span. Consumed by run.gd, which calls SunClock.lift(); not an Events signal.
const KIND_SUN_NUDGE := &"sun_nudge"


## New run. Reads its params from ctx.tuning (scoring, legs, sun).
func reset(_ctx: RunContext) -> void:
	pass


## Advances timers (multiplier decay, minimum speed, hesitation, shoulder, slipstream,
## thread window) and detects events for this tick.
func step(_dt: float, _player: VehicleState, _traffic: TrafficState, _road: RoadPath,
		_out_events: ScoreEventBuffer) -> void:
	push_error("ScoringRuleSet.step not implemented")


## Night doubles everything scored (Core loop → Night).
func set_night(_on: bool) -> void:
	pass


## While true (the ghost period after a hit), nothing scores.
func set_ghost(_on: bool) -> void:
	pass


## The player was hit: the chain is lost, the multiplier resets, grace starts.
func notify_hit(_out_events: ScoreEventBuffer) -> void:
	pass


## The player crossed a checkpoint: the chain banks.
func notify_checkpoint(_out_events: ScoreEventBuffer) -> void:
	pass


## Pays a bonus (leg bonus, objective, journey) straight into the banked total,
## applying the night factor when on.
func award_bonus(_bonus_kind: StringName, _base_points: int, _out_events: ScoreEventBuffer) -> void:
	pass


## The run ended: the unbanked chain is lost (Final score = banked total).
func notify_run_end(_out_events: ScoreEventBuffer) -> void:
	pass


func multiplier() -> float:
	return 1.0


func chain() -> int:
	return 0


func banked() -> int:
	return 0


## Boost meter fill (0..1 of a full meter) earned since the last call; the caller adds
## it to VehicleState.boost_meter (clamped). Slipstream, close passes and threads.
func take_boost_fill() -> float:
	return 0.0
