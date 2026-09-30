extends SceneTree
## Writes res://default_bus_layout.tres: Master, Music, SFX, Engine, UI and their
## effects (docs/AUDIO.md → Buses; AudioBuses documents the slots). The layout file is
## data: tweak the reverb and filter settings there or here and re-run.
##   tools/godot.sh --headless --path . --script res://tools/audio/build_bus_layout.gd

const OUT := "res://default_bus_layout.tres"
# Mirrors AudioBuses (not referenced: it reads the Settings autoload, which a --script
# run compiles too early).
const MASTER := &"Master"
const MUSIC := &"Music"
const SFX := &"SFX"
const ENGINE := &"Engine"
const UI := &"UI"
const MUSIC_LOWPASS := 0
const MUSIC_REVERB := 1
const SFX_REVERB := 0
const ENGINE_REVERB := 0


func _initialize() -> void:
	while AudioServer.bus_count > 1:
		AudioServer.remove_bus(AudioServer.bus_count - 1)
	while AudioServer.get_bus_effect_count(0) > 0:
		AudioServer.remove_bus_effect(0, 0)
	AudioServer.set_bus_name(0, MASTER)
	var limiter := AudioEffectHardLimiter.new()
	limiter.resource_name = "Limiter"
	limiter.ceiling_db = -0.3
	AudioServer.add_bus_effect(0, limiter, 0)

	var music := _bus(MUSIC)
	var lp := AudioEffectLowPassFilter.new()
	lp.resource_name = "NightLowPass"
	lp.cutoff_hz = 20000.0
	lp.resonance = 0.6
	AudioServer.add_bus_effect(music, lp, MUSIC_LOWPASS)
	AudioServer.set_bus_effect_enabled(music, MUSIC_LOWPASS, false)
	var night_rv := _reverb("NightReverb", 0.7, 0.5, 0.0)
	AudioServer.add_bus_effect(music, night_rv, MUSIC_REVERB)
	AudioServer.set_bus_effect_enabled(music, MUSIC_REVERB, false)

	var sfx := _bus(SFX)
	AudioServer.add_bus_effect(sfx, _reverb("TunnelReverb", 0.55, 0.35, 0.0), SFX_REVERB)
	AudioServer.set_bus_effect_enabled(sfx, SFX_REVERB, false)
	var engine := _bus(ENGINE)
	AudioServer.add_bus_effect(engine, _reverb("TunnelReverb", 0.55, 0.35, 0.0), ENGINE_REVERB)
	AudioServer.set_bus_effect_enabled(engine, ENGINE_REVERB, false)
	_bus(UI)

	var layout := AudioServer.generate_bus_layout()
	var err := ResourceSaver.save(layout, OUT)
	print("build_bus_layout: %s -> %s" % [error_string(err), OUT])
	quit(0 if err == OK else 1)


func _bus(bus_name: StringName) -> int:
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, MASTER)
	return i


func _reverb(label: String, room: float, damping: float, wet: float) -> AudioEffectReverb:
	var rv := AudioEffectReverb.new()
	rv.resource_name = label
	rv.room_size = room
	rv.damping = damping
	rv.wet = wet
	rv.dry = 1.0
	rv.predelay_msec = 40.0
	rv.hipass = 0.2
	return rv
