class_name AudioBuses
extends RefCounted
## The bus layout and its controls. Spec: Audio ("Buses: Master, Music, SFX, Engine and
## UI, each with a volume setting"; "Night applies a low-pass filter and reverb to the
## music bus"; "Tunnel sections switch the bus to a reverb"). docs/AUDIO.md → Buses.
##
## The layout is res://default_bus_layout.tres (Godot loads it at startup; built by
## tools/audio/build_bus_layout.gd):
##   Master  [0] HardLimiter (always on)
##   Music   [0] LowPassFilter (night), [1] Reverb (night)    -> Master
##   SFX     [0] Reverb (tunnels)                              -> Master
##   Engine  [0] Reverb (tunnels)                              -> Master
##   UI                                                        -> Master
## Effects are off unless needed (a disabled effect costs nothing). On the web, sounds
## played as samples (every effect voice) skip bus effects; music uses stream playback
## so the night filter still applies (AudioTuning.music_stream_on_web).

const LAYOUT_PATH := "res://default_bus_layout.tres"

const MASTER := &"Master"
const MUSIC := &"Music"
const SFX := &"SFX"
const ENGINE := &"Engine"
const UI := &"UI"
const NAMES: Array[StringName] = [MASTER, MUSIC, SFX, ENGINE, UI]

## Settings keys of each bus's volume (same order as NAMES).
const VOLUME_KEYS: Array[StringName] = [
	&"volume_master", &"volume_music", &"volume_sfx", &"volume_engine", &"volume_ui"]
const MUTE_KEY := &"audio_muted"

## Effect slots.
const MUSIC_LOWPASS := 0
const MUSIC_REVERB := 1
const SFX_REVERB := 0
const ENGINE_REVERB := 0


## True when every bus of NAMES exists.
static func has_layout() -> bool:
	for n in NAMES:
		if AudioServer.get_bus_index(n) < 0:
			return false
	return true


## Applies the project's layout if the running AudioServer doesn't have it yet (a
## script run, or a test that replaced the layout). Returns true when it's in place.
static func ensure_layout() -> bool:
	if has_layout():
		return true
	var layout := load(LAYOUT_PATH) as AudioBusLayout
	if layout == null:
		push_error("AudioBuses: cannot load %s" % LAYOUT_PATH)
		return false
	AudioServer.set_bus_layout(layout)
	return has_layout()


static func index(bus: StringName) -> int:
	return AudioServer.get_bus_index(bus)


## Base level of each bus from the tuning (same order as NAMES).
static func base_db(bus_index_in_names: int, t: AudioTuning) -> float:
	match bus_index_in_names:
		0:
			return t.master_db
		1:
			return t.music_db
		2:
			return t.sfx_db
		3:
			return t.engine_db
		_:
			return t.ui_db


## Target level (dB) of a bus for a player volume setting (0..1 linear), or -INF.
static func target_db(base: float, volume: float) -> float:
	if volume <= 0.0:
		return -INF
	return base + linear_to_db(volume)


## The volume setting of a bus from Settings (1.0 when the key is unknown).
static func setting_volume(bus_index_in_names: int) -> float:
	var key := VOLUME_KEYS[bus_index_in_names]
	if not Settings.DEFAULTS.has(key):
		return 1.0
	return clampf(float(Settings.get_value(key)), 0.0, 1.0)


static func setting_muted() -> bool:
	return Settings.DEFAULTS.has(MUTE_KEY) and bool(Settings.get_value(MUTE_KEY))


## Night on the Music bus: `amount` 0 (day, effects off) .. 1 (full night).
static func set_night(amount: float, t: AudioTuning) -> void:
	var b := index(MUSIC)
	if b < 0:
		return
	var on := amount > 0.0
	var lp := AudioServer.get_bus_effect(b, MUSIC_LOWPASS) as AudioEffectLowPassFilter
	if lp != null:
		# Exponential sweep sounds even (octaves per second).
		lp.cutoff_hz = t.day_lowpass_hz * pow(t.night_lowpass_hz / t.day_lowpass_hz, amount)
		AudioServer.set_bus_effect_enabled(b, MUSIC_LOWPASS, on)
	var rv := AudioServer.get_bus_effect(b, MUSIC_REVERB) as AudioEffectReverb
	if rv != null:
		rv.wet = t.night_reverb_wet * amount
		AudioServer.set_bus_effect_enabled(b, MUSIC_REVERB, on)


static func night_enabled() -> bool:
	var b := index(MUSIC)
	return b >= 0 and AudioServer.is_bus_effect_enabled(b, MUSIC_LOWPASS)


## Tunnel reverb on the SFX and Engine buses for a tunnel factor 0..1.
static func set_tunnel(factor: float, t: AudioTuning) -> void:
	var on := factor >= t.tunnel_reverb_min_factor
	var wet := t.tunnel_reverb_wet * clampf(factor, 0.0, 1.0)
	_set_reverb(index(SFX), SFX_REVERB, wet, on)
	_set_reverb(index(ENGINE), ENGINE_REVERB, wet, on)


static func _set_reverb(bus: int, slot: int, wet: float, on: bool) -> void:
	if bus < 0 or AudioServer.get_bus_effect_count(bus) <= slot:
		return
	var rv := AudioServer.get_bus_effect(bus, slot) as AudioEffectReverb
	if rv != null:
		rv.wet = wet
	if AudioServer.is_bus_effect_enabled(bus, slot) != on:
		AudioServer.set_bus_effect_enabled(bus, slot, on)


static func tunnel_enabled() -> bool:
	var b := index(SFX)
	return b >= 0 and AudioServer.get_bus_effect_count(b) > SFX_REVERB \
		and AudioServer.is_bus_effect_enabled(b, SFX_REVERB)
