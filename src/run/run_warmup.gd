class_name RunWarmup
extends RefCounted
## The first run's empty-road warm-up. Spec: Controls → Settings and first run ("First
## launch. A one-screen chooser for steering and throttle (default: drag + auto), then a
## 20-second empty-road warm-up so players feel it before traffic"). WP8.1;
## docs/SAVE.md → First run.
##
##   warmup.arm(true)            # Run.start_mode: a Journey run while Save.warmup_pending()
##   warmup.begin(run)           # Run._start_run, before director.reset(): the prefill is empty
##   warmup.tick()               # Run._sim_tick, every RUNNING tick (allocation-free)
##   warmup.skip()               # the hint's SKIP
##
## While it runs the director plans no traffic: its density scale is 0 (both
## carriageways, behind spawns) and racer arrivals are off. It counts RUNNING ticks
## only (not the countdown, not the pause): warmup_s of them. Then traffic fades in: the
## density scale steps back to what it was over warmup_fade_s in warmup_fade_steps steps
## (the first at once), and arrivals come back. The director plans new traffic beyond
## the fog, so it arrives out of the distance, never pops in. Deterministic: whole ticks
## of the fixed dt, no clock. The warm-up is recorded as done (Save.mark_warmup_done)
## when it ends or is skipped; a run that ends earlier (or QUIT) leaves it pending for the
## next Journey from the title. The run's results carry `warmup` (see Run._show_results),
## so the leaderboard never gets a run the verifier cannot replay.

## The run's results carry this (true) after a warm-up: NetRunPayload.eligible() keeps
## such a run off the leaderboards (the verifier replays runs without a warm-up).
const RESULT_KEY := &"warmup"

## Seconds left changed (the hint's line); -1 = the empty part ended.
signal seconds_changed(seconds: int)

## A run started from the title will warm up (consumed by begin()).
var armed: bool = false
## The empty road is on.
var active: bool = false
## Traffic is fading back in.
var fading: bool = false
## This run warmed up (for its results).
var ran: bool = false
## Skipped by the player.
var skipped: bool = false
var ticks_left: int = 0
var hint: FirstRunWarmupHint

var _director: TrafficDirector
var _dt: float = 0.0
var _meta: MetaTuning
var _base_scale: float = 1.0
var _base_arrivals: bool = true
var _fade_ticks: int = 0
var _fade_total: int = 1
var _fade_step: int = 0
var _note_ticks: int = 0
var _shown_seconds: int = -1


func arm(on: bool) -> void:
	armed = on


## Run._start_run, after the director is built and before its reset(): an armed warm-up
## starts (and any previous one is dropped: its director is gone).
func begin(run: Run) -> void:
	stop()
	ran = false
	skipped = false
	if not armed:
		return
	armed = false
	_meta = run.tuning.meta if run.tuning.meta != null else MetaTuning.new()
	_dt = run.tuning.vehicle.physics_dt()
	_director = run.director
	_base_scale = _director.density_scale
	_base_arrivals = _director.racer_arrivals_enabled
	_director.set_density_scale(0.0)
	_director.racer_arrivals_enabled = false
	ticks_left = maxi(roundi(_meta.warmup_s / _dt), 1)
	_fade_total = maxi(roundi(_meta.warmup_fade_s / _dt), 1)
	active = true
	ran = true
	_shown_seconds = -1
	if not Events.game_state_changed.is_connected(_on_state):
		Events.game_state_changed.connect(_on_state)
	_install_hint(run)
	_update_seconds()


## Every RUNNING tick. Allocation-free (the hint's line changes once a second).
func tick() -> void:
	if active:
		ticks_left -= 1
		if ticks_left <= 0:
			_end_empty()
		else:
			_update_seconds()
	elif fading:
		_fade_ticks += 1
		var steps := maxi(_meta.warmup_fade_steps, 1)
		@warning_ignore("integer_division")
		var k := 1 + (_fade_ticks * (steps - 1)) / _fade_total
		if k > _fade_step:
			_apply_step(mini(k, steps))
	if _note_ticks > 0:
		_note_ticks -= 1
		if _note_ticks == 0 and hint != null:
			hint.hide_now()


## SKIP: traffic starts fading in now.
func skip() -> void:
	if not active:
		return
	skipped = true
	_end_empty()


## Ends everything at once without restoring the director (a new run or the title
## rebuilds it). The hint hides.
func stop() -> void:
	active = false
	fading = false
	_note_ticks = 0
	_director = null
	if Events.game_state_changed.is_connected(_on_state):
		Events.game_state_changed.disconnect(_on_state)
	if hint != null and is_instance_valid(hint):
		hint.hide_now()


## Seconds of empty road left (0 when not active).
func seconds_left() -> int:
	return ceili(float(ticks_left) * _dt) if active else 0


func _end_empty() -> void:
	active = false
	ticks_left = 0
	fading = true
	_fade_ticks = 0
	_fade_step = 0
	_director.racer_arrivals_enabled = _base_arrivals
	_apply_step(1)
	_note_ticks = maxi(roundi(_meta.warmup_end_note_s / _dt), 1)
	if hint != null:
		hint.set_ending()
	seconds_changed.emit(-1)
	Save.mark_warmup_done(false)


func _apply_step(k: int) -> void:
	var steps := maxi(_meta.warmup_fade_steps, 1)
	_fade_step = k
	_director.set_density_scale(_base_scale * float(k) / float(steps))
	if k >= steps:
		fading = false


func _update_seconds() -> void:
	var s := seconds_left()
	if s == _shown_seconds:
		return
	_shown_seconds = s
	if hint != null:
		hint.set_seconds(s)
	seconds_changed.emit(s)


func _install_hint(run: Run) -> void:
	if hint == null or not is_instance_valid(hint):
		hint = FirstRunWarmupHint.new()
		run.add_child(hint)
		hint.skip.connect(skip)
	hint.visible = true


## Leaving the run (crash, results, the title) ends the warm-up; a pause keeps it.
func _on_state(_from: StringName, to: StringName) -> void:
	if to == Game.CRASH or to == Game.RESULTS or to == Game.MENU:
		stop()
