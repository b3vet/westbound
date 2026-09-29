class_name AudioMath
extends RefCounted
## Pure audio mappings: engine crossfade weights, pass-whoosh and stinger parameters,
## doppler, wind. Spec: Audio, haptics and game feel (Audio). docs/AUDIO.md.
## Static, allocation-free (callers pass the output arrays), no Node dependencies, so
## the tests check every curve headless.

## Quarter turn: the equal-power crossfade's angle range.
const QUARTER := PI * 0.5
## Semitones per octave.
const SEMITONES := 12.0
## Bus-volume glides snap to their target inside this distance (dB).
const DB_SNAP := 0.05


## Equal-power weights of the engine loops for `rpm` over the ascending `steps` (rpm of
## each loop): the two steps around rpm share it (cos / sin of the position between
## them), everything else is 0. Below the first or above the last step that loop alone
## plays at full weight. `out` must have steps.size() entries.
static func engine_step_weights(rpm: float, steps: PackedFloat64Array, out: PackedFloat64Array) -> void:
	var n := steps.size()
	for i in n:
		out[i] = 0.0
	if n == 0:
		return
	if rpm <= steps[0]:
		out[0] = 1.0
		return
	if rpm >= steps[n - 1]:
		out[n - 1] = 1.0
		return
	for i in n - 1:
		if rpm < steps[i + 1]:
			var t := (rpm - steps[i]) / (steps[i + 1] - steps[i])
			out[i] = cos(t * QUARTER)
			out[i + 1] = sin(t * QUARTER)
			return


## Playback pitch of a loop recorded at `step_rpm` when the engine turns at `rpm`.
static func engine_pitch(rpm: float, step_rpm: float, lo: float, hi: float) -> float:
	return clampf(rpm / step_rpm, lo, hi)


## Equal-power on/off-throttle split: returns the on-throttle weight for throttle 0..1;
## the off weight is on_throttle_weight(1 - throttle).
static func on_throttle_weight(throttle: float) -> float:
	return sin(clampf(throttle, 0.0, 1.0) * QUARTER)


## 0 at `far` clearance or more, 1 at `near` or less (the "closeness" of a pass).
static func closeness(clearance_m: float, near: float, far: float) -> float:
	if clearance_m < 0.0:
		return 0.0
	return clampf((far - clearance_m) / (far - near), 0.0, 1.0)


## Whoosh level (dB) for a pass with this clearance: louder when closer.
static func whoosh_db(clearance_m: float, t: AudioTuning) -> float:
	return lerpf(t.whoosh_far_db, t.whoosh_near_db, closeness(clearance_m, t.whoosh_near_m, t.whoosh_far_m))


## Whoosh pitch (playback speed) for a pass: higher when closer, so shorter and sharper.
static func whoosh_pitch(clearance_m: float, t: AudioTuning) -> float:
	return lerpf(t.whoosh_far_pitch, t.whoosh_near_pitch, closeness(clearance_m, t.whoosh_near_m, t.whoosh_far_m))


static func zip_pitch(clearance_m: float, t: AudioTuning) -> float:
	return lerpf(t.zip_far_pitch, t.zip_near_pitch, closeness(clearance_m, t.whoosh_near_m, t.whoosh_far_m))


## Stinger pitch for a multiplier: a note of the tuning's scale, one step every
## 1 / stinger_steps_per_doubling doublings of the multiplier. Never below the base note.
static func stinger_pitch(multiplier: float, t: AudioTuning) -> float:
	var scale := t.stinger_scale_semitones
	if scale.is_empty():
		return 1.0
	var steps := log(maxf(multiplier, 1.0)) / log(2.0) * t.stinger_steps_per_doubling
	var idx := clampi(floori(steps), 0, scale.size() - 1)
	return pow(2.0, scale[idx] / SEMITONES)


## Doppler pitch for a source at road offset (ds, dd) from the listener, moving with
## relative velocity (dvs, dvd) (source minus listener, m/s). Approaching raises it.
static func doppler_pitch(ds: float, dd: float, dvs: float, dvd: float, t: AudioTuning) -> float:
	var r := sqrt(ds * ds + dd * dd)
	if r <= 0.0:
		return 1.0
	var v_away := (ds * dvs + dd * dvd) / r * t.doppler_scale
	var c := t.doppler_speed_of_sound_mps
	# The denominator floor keeps a source closing faster than sound at the top clamp.
	return clampf(c / maxf(c + v_away, c / t.doppler_pitch_max), t.doppler_pitch_min, t.doppler_pitch_max)


## 0..1 over [lo, hi] (clamped).
static func ramp(x: float, lo: float, hi: float) -> float:
	if hi <= lo:
		return 1.0 if x >= hi else 0.0
	return clampf((x - lo) / (hi - lo), 0.0, 1.0)


## Wind level (dB) at speed v (m/s); -INF-like silence below the start speed is the
## caller's job (gain 0 pauses the voice).
static func wind_db(v: float, t: AudioTuning) -> float:
	return lerpf(t.wind_min_db, t.wind_max_db, ramp(v, t.wind_min_mps(), t.wind_full_mps()))


static func wind_pitch(v: float, t: AudioTuning) -> float:
	return lerpf(t.wind_pitch_min, t.wind_pitch_max, ramp(v, t.wind_min_mps(), t.wind_full_mps()))


## Exponential smoothing factor for a time constant (0 = snap).
static func smooth(dt: float, tau: float) -> float:
	if tau <= 0.0:
		return 1.0
	return 1.0 - exp(-dt / tau)


## Linear gain -> dB for a voice, with silence below `floor_gain` mapped to the
## quietest level Godot takes (the caller pauses those voices anyway).
static func gain_db(gain: float, floor_gain: float) -> float:
	return linear_to_db(maxf(gain, floor_gain))


## Count-up chime ticks for a banked amount.
static func chime_ticks(amount: int, t: AudioTuning) -> int:
	if t.chime_points_per_tick <= 0.0:
		return t.chime_ticks_min
	return clampi(roundi(float(amount) / t.chime_points_per_tick), t.chime_ticks_min, t.chime_ticks_max)
