class_name AudioBank
extends RefCounted
## Every sound file the game plays, loaded once. Spec: Audio (assets: CC0 packs and
## in-house synthesized placeholders until licensed or recorded audio arrives).
## docs/AUDIO.md → Assets lists each file, its source and licence (assets/LICENSES.md);
## tools/audio/gen_audio.py rebuilds them. To swap a sound, replace the file at the
## same path (or change the path here / the music list in AudioTuning).
##
## Loops (engine, intake, wind, tire hum) and music are OGG Vorbis, imported with loop
## on (their .import). One-shots are WAV imported with QOA compression (WP7.6): an OGG
## one-shot builds a Vorbis decoder on every play() (~0.6 ms), a WAV starts in µs.

const DIR := "res://assets/audio/"
const ENGINE_ON_FMT := "res://assets/audio/engine_on_%d.ogg"
const ENGINE_OFF_FMT := "res://assets/audio/engine_off_%d.ogg"

# Stable ids for the test hook (VoicePool records the id of each sound it starts).
const WHOOSH := &"whoosh"
const ZIP := &"zip"
const THUMP := &"thump"
const HORN := &"horn"
const AIR_BRAKE := &"air_brake"
const BOOST := &"boost_whoosh"
const STING_PASS := &"sting_pass"
const STING_CLOSE := &"sting_close"
const STING_CUT := &"sting_cut"
const STING_THREAD := &"sting_thread"
const CHIME_TICK := &"chime_tick"
const CHIME_BANK := &"chime_bank"
const STING_HESITATED := &"sting_hesitated"
const STING_HIT := &"sting_hit"
const HIT_IMPACT := &"hit_impact"
const CRASH_METAL := &"crash_metal"
const CRASH_GLASS := &"crash_glass"
const SCRAPE := &"scrape"
const UI_CLICK := &"ui_click"

var whoosh: AudioStream = preload("res://assets/audio/whoosh.wav")
var zip: AudioStream = preload("res://assets/audio/zip.wav")
var thump: AudioStream = preload("res://assets/audio/thump.wav")
var horn: AudioStream = preload("res://assets/audio/horn.wav")
var air_brake: AudioStream = preload("res://assets/audio/air_brake.wav")
var boost_whoosh: AudioStream = preload("res://assets/audio/boost_whoosh.wav")
var sting_pass: AudioStream = preload("res://assets/audio/sting_pass.wav")
var sting_close: AudioStream = preload("res://assets/audio/sting_close.wav")
var sting_cut: AudioStream = preload("res://assets/audio/sting_cut.wav")
var sting_thread: AudioStream = preload("res://assets/audio/sting_thread.wav")
var chime_tick: AudioStream = preload("res://assets/audio/chime_tick.wav")
var chime_bank: AudioStream = preload("res://assets/audio/chime_bank.wav")
var sting_hesitated: AudioStream = preload("res://assets/audio/sting_hesitated.wav")
var sting_hit: AudioStream = preload("res://assets/audio/sting_hit.wav")
var hit_impact: AudioStream = preload("res://assets/audio/hit_impact.wav")
var crash_metal: AudioStream = preload("res://assets/audio/crash_metal.wav")
var crash_glass: AudioStream = preload("res://assets/audio/crash_glass.wav")
var scrape: AudioStream = preload("res://assets/audio/scrape.wav")
var ui_click: AudioStream = preload("res://assets/audio/ui_click.wav")
var wind_loop: AudioStream = preload("res://assets/audio/wind_loop.ogg")
var tire_hum_loop: AudioStream = preload("res://assets/audio/tire_hum_loop.ogg")
var intake_loop: AudioStream = preload("res://assets/audio/intake_loop.ogg")

## Engine loops per AudioTuning.engine_step_rpm (null where a file is missing).
var engine_on: Array[AudioStream] = []
var engine_off: Array[AudioStream] = []


func _init(t: AudioTuning) -> void:
	for rpm in t.engine_step_rpm:
		engine_on.append(_load(ENGINE_ON_FMT % roundi(rpm)))
		engine_off.append(_load(ENGINE_OFF_FMT % roundi(rpm)))


static func _load(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		push_error("AudioBank: missing %s" % path)
		return null
	return load(path) as AudioStream


## A music track (loaded on demand: tracks are the big files).
static func load_track(path: String) -> AudioStream:
	return _load(path)
