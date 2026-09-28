class_name SunClock
extends RefCounted
## The sun clock: one cyclic value, sky_t, that the run advances every tick and the
## sky, color script and HUD read. Spec: Core loop -> Sky timeline and sun clock,
## Night (no timer; 6 s dawn at the next checkpoint); Tuning reference ("Sunset time
## from full day", "Checkpoint sun lift"). Contract: docs/CONTRACTS.md section 8.
## Timeline math: docs/CORE_LOOP.md.
##
## Pure and headless: no Node, no autoload, no randomness, no allocation per call.
## Events go into a caller-provided ScoreEventBuffer (kinds below, value as noted);
## the run's Node adapter publishes them as the Events signals of the same name.
##
## Phases:
##   DAY        sky_t sinks toward sunset at base_sink_per_s() (x too_slow_sink_factor).
##   NIGHTFALL  after crossing sunset: is_night(); sky_t runs to sky_t_night over
##              nightfall_s (visual only).
##   NIGHT      sky_t holds at sky_t_night. No timer: only a checkpoint ends it.
##   DAWN       after a night checkpoint: sky_t runs linearly from where it was to
##              1.0 (== morning) over dawn_transition_s while play continues, then
##              lands exactly on sky_t_morning and DAY resumes.
## Lifts (lift(), day checkpoints) only act by DAY and never move sky_t earlier than
## the run start (nor earlier than it already is, e.g. at morning after a dawn).

enum Phase { DAY, NIGHTFALL, NIGHT, DAWN }

const KIND_NIGHT_STARTED := &"night_started"
const KIND_DAWN_STARTED := &"dawn_started"      ## value = dawn duration (s)
const KIND_MORNING_REACHED := &"morning_reached"
const KIND_SUN_LIFTED := &"sun_lifted"          ## value = fraction of the day span applied

## Absorbs float accumulation of dt (e.g. 720 x 1/120 s) so a 6 s dawn ends on the
## 720th tick, not the 721st. Far below any tick length.
const TIME_EPS_S := 1e-9   # lint: allow-number float accumulation tolerance, not tuning

## Cyclic in [0, 1). Read-only outside this class.
var sky_t: float = 0.0
var phase: Phase = Phase.DAY

var _sun: SunTuning
var _day_span: float
var _base_rate: float
var _nightfall_rate: float
var _run_start: float
var _sunset: float
var _night: float
var _morning: float
var _dawn_s: float
var _lift_frac: float
var _pace_lift_frac: float
var _pace_target_mps: float
var _pace_margin_mps: float

var _dawn_left_s: float = 0.0
var _dawn_from: float = 0.0


func _init(sun: SunTuning, legs: LegsTuning) -> void:
	_sun = sun
	_day_span = sun.day_span()
	_base_rate = sun.base_sink_per_s()
	_run_start = sun.sky_t_run_start
	_sunset = sun.sky_t_sunset
	_night = sun.sky_t_night
	_morning = sun.sky_t_morning
	_nightfall_rate = (_night - _sunset) / sun.nightfall_s
	_dawn_s = sun.dawn_transition_s
	_lift_frac = Units.pct_to_frac(sun.checkpoint_lift_pct)
	_pace_lift_frac = Units.pct_to_frac(sun.checkpoint_pace_lift_max_pct)
	_pace_target_mps = legs.pace_target_mps()
	_pace_margin_mps = legs.pace_full_lift_margin_mps()
	reset()


## New run: sky_t at the run's starting afternoon, day.
func reset() -> void:
	sky_t = _run_start
	phase = Phase.DAY
	_dawn_left_s = 0.0
	_dawn_from = 0.0


## One tick. `too_slow`: the player is below minimum speed (the sun sinks faster).
func advance(dt: float, too_slow: bool, out: ScoreEventBuffer) -> void:
	match phase:
		Phase.DAY:
			var rate := _base_rate * (_sun.too_slow_sink_factor if too_slow else 1.0)
			sky_t += rate * dt
			if sky_t >= _sunset:
				# The part of the tick after sunset already runs the nightfall.
				var after_s := (sky_t - _sunset) / rate
				sky_t = minf(_sunset + after_s * _nightfall_rate, _night)
				phase = Phase.NIGHT if sky_t >= _night else Phase.NIGHTFALL
				out.push(KIND_NIGHT_STARTED)
		Phase.NIGHTFALL:
			sky_t += _nightfall_rate * dt
			if sky_t >= _night:
				sky_t = _night
				phase = Phase.NIGHT
		Phase.NIGHT:
			pass
		Phase.DAWN:
			_dawn_left_s -= dt
			if _dawn_left_s <= TIME_EPS_S:
				sky_t = _morning
				phase = Phase.DAY
				_dawn_left_s = 0.0
				out.push(KIND_MORNING_REACHED)
			else:
				var k := 1.0 - _dawn_left_s / _dawn_s
				sky_t = _dawn_from + (1.0 + _morning - _dawn_from) * k
				if sky_t >= 1.0:
					sky_t -= 1.0


## Moves sky_t back by `fraction_of_day_span` x day span (a thread or close-pass
## nudge, run.gd forwards ScoringRuleSet.KIND_SUN_NUDGE here). Day only; never
## earlier than the run start. Emits sun_lifted with the fraction actually applied
## (nothing when it had no effect).
func lift(fraction_of_day_span: float, out: ScoreEventBuffer) -> void:
	if phase != Phase.DAY or fraction_of_day_span <= 0.0:
		return
	var floor_t := minf(_run_start, sky_t)
	var target := maxf(sky_t - fraction_of_day_span * _day_span, floor_t)
	var applied := (sky_t - target) / _day_span
	if applied <= 0.0:
		return
	sky_t = target
	out.push(KIND_SUN_LIFTED, 0, 0.0, -1.0, -1, applied)


## The player crossed a checkpoint. By day: lift by checkpoint_lift_pct plus up to
## checkpoint_pace_lift_max_pct for pace (linear from the pace target to target +
## pace_full_lift_margin). At night: start the dawn transition. While dawning: nothing.
func on_checkpoint(leg_avg_speed_mps: float, out: ScoreEventBuffer) -> void:
	match phase:
		Phase.DAY:
			lift(checkpoint_lift_fraction(leg_avg_speed_mps), out)
		Phase.NIGHTFALL, Phase.NIGHT:
			phase = Phase.DAWN
			_dawn_from = sky_t
			_dawn_left_s = _dawn_s
			out.push(KIND_DAWN_STARTED, 0, 0.0, -1.0, -1, _dawn_s)
		Phase.DAWN:
			pass


## Day-checkpoint lift (fraction of the day span) for a leg average speed.
func checkpoint_lift_fraction(leg_avg_speed_mps: float) -> float:
	var pace := clampf((leg_avg_speed_mps - _pace_target_mps) / _pace_margin_mps, 0.0, 1.0)
	return _lift_frac + _pace_lift_frac * pace


## True from crossing sunset until a checkpoint starts the dawn.
func is_night() -> bool:
	return phase == Phase.NIGHTFALL or phase == Phase.NIGHT


## True during the dawn transition (not night; play continues).
func is_dawning() -> bool:
	return phase == Phase.DAWN


## 0..1 for the HUD bar: 1 at the run start (and earlier, e.g. morning), 0 at sunset
## and all night; during the dawn it rises with the transition's progress.
func sun_height() -> float:
	match phase:
		Phase.DAY:
			return clampf((_sunset - sky_t) / _day_span, 0.0, 1.0)
		Phase.DAWN:
			return clampf(1.0 - _dawn_left_s / _dawn_s, 0.0, 1.0)
	return 0.0


## Mixes the clock state into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_float(h, sky_t)
	h = TraceHash.mix_int(h, phase)
	h = TraceHash.mix_float(h, _dawn_left_s)
	return TraceHash.mix_float(h, _dawn_from)
