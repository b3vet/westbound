class_name EngineAudio
extends Node
## The player car's sound: engine loops, boost intake, wind. Spec: Audio ("Engine:
## loops at several RPM steps, on- and off-throttle, crossfaded and pitched by the
## simulated RPM, with gear-shift dips"; "Wind: noise rising with speed; boost adds a
## whoosh and an intake roar"). docs/AUDIO.md → Engine and wind.
##
## One looping AudioStreamPlayer per rpm step and throttle side (Engine bus), all
## started once; per frame (update()) each gets
##   gain = step weight (AudioMath.engine_step_weights, equal power between the two
##          steps around the rpm) x on/off weight (equal power over the smoothed
##          throttle) x the rpm level ramp x the shift dip x the fade
##   pitch = rpm / step rpm (clamped).
## Voices with no gain are paused, so at most 4 engine loops mix at a time. On the web
## (`stop_silent`) a silent loop is stopped instead, after `loop_stop_hold_s` of
## silence, and play() starts it again: Godot 4.7's web sample pause/unpause can leave a
## loop silent for good (docs/AUDIO.md → Loops on the web). The gear comes from
## VehicleState (an upshift starts the dip; the gearbox itself drops the rpm).
## Intake (boosting) and wind (speed) are loops on the Engine and SFX buses.
## Reads the state only; allocation-free per frame.

var tuning: AudioTuning
var on_players: Array[AudioStreamPlayer] = []
var off_players: Array[AudioStreamPlayer] = []
var intake: AudioStreamPlayer
var wind: AudioStreamPlayer
## Every loop above, in one list (on 0..n-1, off n..2n-1, intake, wind).
var loops: Array[AudioStreamPlayer] = []
## Silent loops are stopped (after the hold) instead of paused: the web, where they
## play as Web Audio samples (AudioTuning.stops_silent_loops; tests set it).
var stop_silent: bool = false

## Smoothed inputs (tests read them).
var rpm: float = 0.0
var throttle: float = 0.0
## 0..1: the engine fades in when driving and out on the crash and at the results.
var fade: float = 0.0
var fade_target: float = 0.0
var boost: float = 0.0
var wind_gain: float = 0.0
## Remaining shift-dip time (s).
var dip_left: float = 0.0
var shifts: int = 0

var _weights := PackedFloat64Array()
## Seconds each loop of `loops` has been silent while still playing (stop_silent).
var _silent_s := PackedFloat64Array()
var _floor_db: float = 0.0
var _dt: float = 0.0
var _gear: int = 0
var _primed: bool = false


func setup(t: AudioTuning, bank: AudioBank) -> void:
	tuning = t
	_floor_db = linear_to_db(t.silent_gain)
	stop_silent = t.stops_silent_loops()
	if not on_players.is_empty():
		return
	var n := t.engine_step_rpm.size()
	_weights.resize(n)
	for i in n:
		on_players.append(_loop("On%d" % i, bank.engine_on[i], AudioBuses.ENGINE))
	for i in n:
		off_players.append(_loop("Off%d" % i, bank.engine_off[i], AudioBuses.ENGINE))
	intake = _loop("Intake", bank.intake_loop, AudioBuses.ENGINE)
	wind = _loop("Wind", bank.wind_loop, AudioBuses.SFX)
	_silent_s.resize(loops.size())


func _loop(label: String, stream: AudioStream, bus: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = label
	p.stream = stream
	p.bus = bus
	p.volume_db = _floor_db
	add_child(p)
	loops.append(p)
	return p


## Forget the gear and snap the smoothing (run start).
func reset() -> void:
	_primed = false
	dip_left = 0.0
	boost = 0.0
	wind_gain = 0.0
	fade = 0.0


## Per frame. `driving` = the engine should be heard (countdown, running); off fades out.
## `dt` is real time (not slowed by slow motion).
func update(dt: float, state: VehicleState, input: VehicleInput, driving: bool) -> void:
	_dt = dt
	if tuning == null or state == null:
		_silence_all()
		return
	var t := tuning
	var thr := 0.0
	if input != null:
		thr = clampf(input.throttle - input.brake, 0.0, 1.0)
		if thr < t.engine_throttle_deadband:
			thr = 0.0
	var target_rpm := maxf(state.rpm, t.engine_idle_rpm)
	if not _primed:
		_primed = true
		rpm = target_rpm
		throttle = thr
		_gear = state.gear
	rpm += (target_rpm - rpm) * AudioMath.smooth(dt, t.engine_rpm_smooth_s)
	throttle += (thr - throttle) * AudioMath.smooth(dt, t.engine_throttle_smooth_s)
	if state.gear > _gear:
		dip_left = t.engine_shift_dip_s
		shifts += 1
	_gear = state.gear
	dip_left = maxf(dip_left - dt, 0.0)
	fade_target = 1.0 if driving else 0.0
	var fade_s := t.engine_fade_in_s if fade_target > fade else t.engine_fade_out_s
	fade = move_toward(fade, fade_target, dt / maxf(fade_s, dt))

	AudioMath.engine_step_weights(rpm, t.engine_step_rpm, _weights)
	var on_w := AudioMath.on_throttle_weight(throttle)
	var off_w := AudioMath.on_throttle_weight(1.0 - throttle)
	var level := db_to_linear(t.engine_idle_db * (1.0 - AudioMath.ramp(rpm, t.engine_idle_rpm, t.engine_redline_rpm)))
	var dip := 1.0
	if dip_left > 0.0 and t.engine_shift_dip_s > 0.0:
		dip = lerpf(1.0, db_to_linear(t.engine_shift_dip_db), dip_left / t.engine_shift_dip_s)
	var common := level * dip * fade
	var off_trim := db_to_linear(t.engine_off_db)
	var n := _weights.size()
	for i in n:
		var pitch := AudioMath.engine_pitch(rpm, t.engine_step_rpm[i], t.engine_pitch_min, t.engine_pitch_max)
		_drive(i, _weights[i] * on_w * common, pitch)
		_drive(n + i, _weights[i] * off_w * common * off_trim, pitch)

	var boosting := 1.0 if state.boost_active and driving else 0.0
	boost = move_toward(boost, boosting, dt / maxf(t.intake_fade_s, dt))
	var rpm01 := AudioMath.ramp(rpm, t.engine_idle_rpm, t.engine_redline_rpm)
	_drive(2 * n, boost * fade * db_to_linear(t.intake_db), lerpf(t.intake_pitch_idle, t.intake_pitch_redline, rpm01))

	var v := absf(state.v)
	var w := 0.0
	if v > t.wind_min_mps() and fade_target > 0.0:
		w = db_to_linear(AudioMath.wind_db(v, t) + t.wind_boost_db * boost)
	wind_gain += (w - wind_gain) * AudioMath.smooth(dt, t.wind_smooth_s)
	_drive(2 * n + 1, wind_gain, AudioMath.wind_pitch(v, t))


## Current linear gain of the on-throttle loop of step i (tests).
func on_gain(i: int) -> float:
	return _gain_of(on_players[i])


func off_gain(i: int) -> float:
	return _gain_of(off_players[i])


## Engine loops mixing now (heard: playing, not paused, above silence).
func audible_loops() -> int:
	var n := 0
	for p in on_players:
		if _gain_of(p) > 0.0:
			n += 1
	for p in off_players:
		if _gain_of(p) > 0.0:
			n += 1
	return n


## True when loop k (of `loops`) should be heard: its level is above silence.
func wants(k: int) -> bool:
	return loops[k].volume_db > _floor_db + AudioMath.DB_SNAP


## True when loop k is mixing: playing, not paused.
func sounding(k: int) -> bool:
	var p := loops[k]
	return p.playing and not p.stream_paused


## Pause every loop (the game is paused, or the node is going away). Where silent loops
## are stopped (the web), a pause stops them all; update() starts them again.
func set_paused(paused: bool) -> void:
	for k in loops.size():
		var p := loops[k]
		if stop_silent:
			if paused and p.playing:
				p.stop()
			_silent_s[k] = 0.0
			continue
		p.stream_paused = paused or _gain_of(p) <= 0.0


## Linear gain a loop mixes at (0 = silent, paused or stopped).
func _gain_of(p: AudioStreamPlayer) -> float:
	if p.stream_paused or not p.playing or p.volume_db <= _floor_db + AudioMath.DB_SNAP:
		return 0.0
	return db_to_linear(p.volume_db)


func _silence_all() -> void:
	for k in loops.size():
		_drive(k, 0.0, 1.0)


## Sets loop k's gain and pitch. A silent loop is paused, or on the web kept playing at
## silence for loop_stop_hold_s and then stopped; a heard loop is (re)started.
func _drive(k: int, gain: float, pitch: float) -> void:
	var p := loops[k]
	if p.stream == null:
		return
	if gain <= tuning.silent_gain:
		p.volume_db = _floor_db
		if not p.playing:
			_silent_s[k] = 0.0
		elif stop_silent:
			_silent_s[k] += _dt
			if _silent_s[k] >= tuning.loop_stop_hold_s:
				p.stop()
				_silent_s[k] = 0.0
		elif not p.stream_paused:
			p.stream_paused = true
		return
	_silent_s[k] = 0.0
	p.volume_db = linear_to_db(gain)
	p.pitch_scale = pitch
	if not p.playing:
		p.play()
	if p.stream_paused:
		p.stream_paused = false
