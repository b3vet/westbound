class_name Lives
extends RefCounted
# lint: sim
## Lives, the ghost period and the player's scripted first-hit response. Spec: Lives,
## hits and crashes (2 lives; the first touch costs a life, 2.0 s ghost that cannot be
## hit; the car deflects away from the contact, loses 20% speed and wobbles for 0.6 s;
## the second touch ends the run; a clean leg restores a life up to 2, a tuning switch).
## See docs/CORE_LOOP.md for the run's hit sequence.
##
## Pure and headless; on_contact(), step() and restore_life() are allocation-free.
## Lives only decides and applies the player side. The run forwards the other facts:
## ScoringRuleSet.notify_hit() (chain lost, multiplier reset, the 3 s minimum-speed
## grace, which scoring owns) and set_ghost(is_ghost()), TrafficSim.notify_hit(slot)
## for a traffic contact, LegTracker.notify_hit() (the leg is no longer clean), and the
## crash hand-off (Phase 4) on RUN_OVER.
##
## Per tick (order step 4, after physics): lives.step(dt, player, events), then
## hit_detection.step(...) and, on a contact, lives.on_contact(contact, player, events).

enum Outcome {
	NONE,       ## no contact
	IGNORED,    ## contact during the ghost period, or after the run ended
	FIRST_HIT,  ## a life lost, the run continues (the spec's "first hit")
	RUN_OVER,   ## the last life lost: crash hand-off
}

const KIND_HIT := &"hit"                      ## tag = Events.HIT_*, slot, value = lives left
const KIND_GHOST_STARTED := &"ghost_started"  ## value = duration (s)
const KIND_GHOST_ENDED := &"ghost_ended"
const KIND_LIFE_RESTORED := &"life_restored"  ## value = lives now

## Absorbs float accumulation of dt (240 x 1/120 s == 2.0 s).
const TIME_EPS_S := 1e-9   # lint: allow-number float accumulation tolerance, not tuning

var lives: int = 0
var max_lives: int = 0
## Hits that counted this run (the results screen's "hits").
var hits: int = 0

var _t: LivesTuning
var _ghost_s: float
var _wobble_s: float
var _wobble_amp: float
var _wobble_w: float
var _keep: float
var _deflect_mps: float
var _deflect_max: float

var _run_over: bool = false
var _ghost_left: float = 0.0
var _wobble_t: float = 0.0
var _wobbling: bool = false


func _init(t: LivesTuning) -> void:
	_t = t
	max_lives = t.lives
	_ghost_s = t.ghost_period_s
	_wobble_s = t.first_hit_wobble_s
	_wobble_amp = t.first_hit_wobble_amplitude_rad()
	_wobble_w = TAU * t.first_hit_wobble_hz
	_keep = t.first_hit_speed_keep_frac()
	_deflect_mps = t.first_hit_deflect_mps
	_deflect_max = t.first_hit_deflect_max_rad()
	reset()


## New run: full lives, no ghost.
func reset() -> void:
	lives = max_lives
	hits = 0
	_run_over = false
	_ghost_left = 0.0
	_wobble_t = 0.0
	_wobbling = false


## Per tick: counts down the ghost (emits ghost_ended) and applies the wobble to
## `player` (after VehiclePhysics.step).
func step(dt: float, player: VehicleState, out: ScoreEventBuffer) -> void:
	if _ghost_left > 0.0:
		_ghost_left -= dt
		if _ghost_left <= TIME_EPS_S:
			_ghost_left = 0.0
			out.push(KIND_GHOST_ENDED)
	if _wobbling:
		var t0 := _wobble_t
		var t1 := t0 + dt
		if t1 >= _wobble_s - TIME_EPS_S:
			t1 = _wobble_s
			_wobbling = false
		_wobble_t = t1
		player.yaw += _wobble_offset(t1) - _wobble_offset(t0)


## A contact from HitDetection. Decides whether it counts, emits hit (and
## ghost_started), applies the first-hit response to `player`, returns the Outcome.
func on_contact(contact: HitDetection.Contact, player: VehicleState, out: ScoreEventBuffer) -> Outcome:
	if not contact.hit:
		return Outcome.NONE
	if _run_over or _ghost_left > 0.0:
		return Outcome.IGNORED
	hits += 1
	lives -= 1
	if lives <= 0:
		lives = 0
		_run_over = true
		out.push(KIND_HIT, 0, 0.0, -1.0, contact.slot, 0.0, contact.source)
		return Outcome.RUN_OVER
	out.push(KIND_HIT, 0, 0.0, -1.0, contact.slot, float(lives), contact.source)
	_ghost_left = _ghost_s
	out.push(KIND_GHOST_STARTED, 0, 0.0, -1.0, -1, _ghost_s)
	apply_hit_response(player, contact.away_side)
	return Outcome.FIRST_HIT


## A clean leg restores a lost life, never above the maximum; only when the tuning
## switch is on and the run is not over. Emits life_restored(lives). Returns true if
## a life came back.
func restore_life(out: ScoreEventBuffer) -> bool:
	if not _t.clean_leg_restore or _run_over or lives >= max_lives:
		return false
	lives += 1
	out.push(KIND_LIFE_RESTORED, 0, 0.0, -1.0, -1, float(lives))
	return true


## The scripted first-hit response on the player car (no physics engine): speed x
## (1 - first_hit_speed_loss), a heading kick toward `away_side` (+1 right, -1 left,
## 0 none) giving about first_hit_deflect_mps of lateral speed, and the wobble.
## VehiclePhysics' heading return then brings the car back to the lane direction.
func apply_hit_response(player: VehicleState, away_side: int) -> void:
	player.v *= _keep
	if away_side != 0:
		var kick := minf(atan2(_deflect_mps, player.v), _deflect_max)
		player.yaw += kick * float(away_side)
	_wobble_t = 0.0
	_wobbling = _wobble_s > 0.0


func is_ghost() -> bool:
	return _ghost_left > 0.0


func ghost_remaining() -> float:
	return _ghost_left


func is_wobbling() -> bool:
	return _wobbling


func is_run_over() -> bool:
	return _run_over


## Mixes the state into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_int(h, lives)
	h = TraceHash.mix_int(h, hits)
	h = TraceHash.mix_bool(h, _run_over)
	h = TraceHash.mix_float(h, _ghost_left)
	h = TraceHash.mix_bool(h, _wobbling)
	return TraceHash.mix_float(h, _wobble_t)


## Yaw offset of the wobble at time t: a sine decaying linearly to 0 at the end, so
## the wobble adds no net heading.
func _wobble_offset(t: float) -> float:
	return _wobble_amp * sin(_wobble_w * t) * (1.0 - t / _wobble_s)
