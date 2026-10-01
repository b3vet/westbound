class_name AudioTuning
extends Resource
## Every audio number: bus levels, the engine, wind, pass and traffic sounds, stingers,
## music, the voice budget. Spec: Audio, haptics and game feel (Audio). Saved as
## data/tuning/audio.tres. docs/AUDIO.md.
##
## Until the orchestrator adds `Tuning.audio`, load it with AudioTuning.load_default()
## (GameAudio prefers Tuning.audio when it exists). Levels are in dB, rates in Hz, times
## in s; nothing here feeds the simulation.

const PATH := "res://data/tuning/audio.tres"

@export_group("Buses")
## Base level of each bus (dB) before the player's volume setting (a 0..1 linear
## factor from Settings). Master, Music, SFX, Engine, UI.
@export var master_db: float = 0.0   # not in spec
@export var music_db: float = -9.0   # not in spec
@export var sfx_db: float = -2.0   # not in spec
@export var engine_db: float = -5.0   # not in spec
@export var ui_db: float = -4.0   # not in spec
## The in-run settings panel's volume steps (linear; 0 = the bus is muted).
@export var volume_steps: PackedFloat64Array = [0.0, 0.5, 0.75, 1.0]   # not in spec
## Bus volume changes glide over this time (s) so steps don't click.
@export var volume_glide_s: float = 0.08   # not in spec

@export_group("Night and tunnels")
## Night: the Music bus low-pass cutoff (Hz) and reverb wet level, faded in over
## night_fade_s on night_started and out again over dawn (at most night_fade_s).
@export var night_lowpass_hz: float = 1400.0   # not in spec
@export var day_lowpass_hz: float = 20000.0   # not in spec
@export var night_reverb_wet: float = 0.22   # not in spec
@export var night_fade_s: float = 4.0   # not in spec
## Tunnels: SFX and Engine reverb wet level at full tunnel factor (TunnelLight 0..1).
@export var tunnel_reverb_wet: float = 0.35   # not in spec
## Below this tunnel factor the reverb effects are switched off (costs nothing).
@export var tunnel_reverb_min_factor: float = 0.01   # not in spec

@export_group("Engine")
## RPM of each engine loop (on and off throttle), low to high. Must match the files
## tools/audio/gen_audio.py writes (engine_on_<rpm>.ogg, engine_off_<rpm>.ogg).
@export var engine_step_rpm: PackedFloat64Array = [900.0, 1575.0, 2450.0, 3500.0, 4900.0, 7000.0]   # not in spec
## Pitch clamp for a loop played away from its step rpm.
@export var engine_pitch_min: float = 0.5   # not in spec
@export var engine_pitch_max: float = 2.0   # not in spec
## Smoothing time constants: rpm and throttle (s).
@export var engine_rpm_smooth_s: float = 0.04   # not in spec
@export var engine_throttle_smooth_s: float = 0.1   # not in spec
## Off-throttle loops sit this far below the on-throttle ones (dB).
@export var engine_off_db: float = -5.0   # not in spec
## Level rises with rpm: this much quieter at idle than at redline (dB).
@export var engine_idle_db: float = -7.0   # not in spec
## RPM range the level ramp spans (the gearbox's idle and redline).
@export var engine_idle_rpm: float = 900.0   # not in spec
@export var engine_redline_rpm: float = 7000.0   # not in spec
## Gear-shift dip: the level drops by this much on an upshift and recovers over the time.
@export var engine_shift_dip_db: float = -7.0   # not in spec
@export var engine_shift_dip_s: float = 0.16   # not in spec
## Throttle below this counts as off-throttle for the blend (brake also lifts it).
@export var engine_throttle_deadband: float = 0.05   # not in spec
## Fade times (s): in at the countdown, out on the crash and at the results.
@export var engine_fade_in_s: float = 0.6   # not in spec
@export var engine_fade_out_s: float = 0.8   # not in spec
## Voices below this linear gain are paused (they cost nothing), or stopped on the web.
@export var silent_gain: float = 0.001   # not in spec
## The web plays the loops (engine, intake, wind, tire hum) as Web Audio samples, and
## Godot 4.7's sample pause/unpause can restart a loop past its end, where WebKit never
## plays or ends it: the loop goes silent for good (docs/AUDIO.md → Loops on the web).
## So on the web a silent loop is stopped instead of paused, once it has been silent
## this long (s; so a gain hovering at silence doesn't restart it every frame), and
## play() starts it again when it is heard.
@export var loop_stop_on_web: bool = true   # not in spec
@export var loop_stop_hold_s: float = 0.5   # not in spec

@export_group("Boost and intake")
@export var intake_db: float = -3.0   # not in spec
@export var intake_fade_s: float = 0.25   # not in spec
## Intake pitch over the rpm range (idle .. redline).
@export var intake_pitch_idle: float = 0.8   # not in spec
@export var intake_pitch_redline: float = 1.35   # not in spec
@export var boost_whoosh_db: float = -2.0   # not in spec

@export_group("Wind")
## Wind rises with speed: silent below wind_min_kmh, wind_max_db at wind_full_kmh.
@export var wind_min_kmh: float = 40.0   # not in spec
@export var wind_full_kmh: float = 280.0   # not in spec
@export var wind_min_db: float = -36.0   # not in spec
@export var wind_max_db: float = -5.0   # not in spec
@export var wind_pitch_min: float = 0.75   # not in spec
@export var wind_pitch_max: float = 1.45   # not in spec
## Boosting adds this much wind (dB).
@export var wind_boost_db: float = 3.0   # not in spec
@export var wind_smooth_s: float = 0.2   # not in spec

@export_group("Pass whoosh, zip, thump")
## Clearance range (m) the whoosh scales over: at or below near it is loudest and
## shortest (highest pitch), at or above far it is quietest and longest.
@export var whoosh_near_m: float = 0.2   # not in spec
@export var whoosh_far_m: float = 3.0   # not in spec
@export var whoosh_near_db: float = 0.0   # not in spec
@export var whoosh_far_db: float = -12.0   # not in spec
## Pitch scale = playback speed: higher is shorter and sharper.
@export var whoosh_near_pitch: float = 1.45   # not in spec
@export var whoosh_far_pitch: float = 0.85   # not in spec
## Close-pass zip layer (dB) and its pitch range over the same clearance range.
@export var zip_db: float = -3.0   # not in spec
@export var zip_near_pitch: float = 1.25   # not in spec
@export var zip_far_pitch: float = 1.0   # not in spec
## Thread thump (dB).
@export var thump_db: float = 0.0   # not in spec
## Finding the passed car for the whoosh's side: the car nearest the player's tail
## within this window behind (and this far ahead) of the player (m).
@export var pass_search_behind_m: float = 30.0   # not in spec
@export var pass_search_ahead_m: float = 4.0   # not in spec
## Where a whoosh sits when no car is found: this far to the side (m), behind (m).
@export var pass_fallback_side_m: float = 2.5   # not in spec
@export var pass_fallback_behind_m: float = 3.0   # not in spec

@export_group("Traffic")
## Vehicles at least this heavy are trucks and buses: lower horns, air-brake hiss.
@export var heavy_mass_kg: float = 7000.0   # not in spec
@export var horn_db: float = -3.0   # not in spec
@export var horn_heavy_pitch: float = 0.62   # not in spec
## Per-car horn variety: pitch spreads over this many steps of horn_pitch_step.
@export var horn_pitch_variants: int = 5   # not in spec
@export var horn_pitch_step: float = 0.04   # not in spec
@export var air_brake_db: float = -4.0   # not in spec
## Air-brake hiss: a heavy vehicle within this distance that starts braking hard.
@export var air_brake_radius_m: float = 60.0   # not in spec
@export var air_brake_cooldown_s: float = 4.0   # not in spec
## Tire hum of the nearest cars: how many, within what distance (m).
@export var tire_hum_voices: int = 3   # not in spec
@export var tire_hum_radius_m: float = 45.0   # not in spec
@export var tire_hum_db: float = -8.0   # not in spec
@export var tire_hum_heavy_db: float = 3.0   # not in spec
## Hum pitch over the car's speed (0 .. tire_hum_full_kmh).
@export var tire_hum_full_kmh: float = 160.0   # not in spec
@export var tire_hum_pitch_min: float = 0.6   # not in spec
@export var tire_hum_pitch_max: float = 1.25   # not in spec
@export var tire_hum_heavy_pitch: float = 0.75   # not in spec
@export var tire_hum_fade_s: float = 0.25   # not in spec
## Barrier scrape: at most one every this many seconds (dB).
@export var scrape_db: float = -4.0   # not in spec
@export var scrape_min_interval_s: float = 0.12   # not in spec

@export_group("Doppler and 3D")
## Doppler on traffic sounds (horns, whooshes, hum): speed of sound (m/s), an
## exaggeration factor and the pitch clamp.
@export var doppler_speed_of_sound_mps: float = 343.0   # not in spec
@export var doppler_scale: float = 1.5   # not in spec
@export var doppler_pitch_min: float = 0.7   # not in spec
@export var doppler_pitch_max: float = 1.4   # not in spec
## AudioStreamPlayer3D: unit size (m), max distance (m), panning strength.
@export var positional_unit_size_m: float = 6.0   # not in spec
@export var positional_max_distance_m: float = 150.0   # not in spec
@export var positional_panning: float = 1.0   # not in spec

@export_group("Stingers")
## Stingers are pitched up with the multiplier: the note index is
## floor(log2(multiplier) * stinger_steps_per_doubling), clamped to this scale
## (semitones above the base note; a major pentatonic).
@export var stinger_scale_semitones: PackedFloat64Array = [0.0, 2.0, 4.0, 7.0, 9.0, 12.0, 14.0, 16.0, 19.0, 21.0, 24.0]   # not in spec
@export var stinger_steps_per_doubling: float = 2.0   # not in spec
@export var sting_pass_db: float = -8.0   # not in spec
@export var sting_close_db: float = -5.0   # not in spec
@export var sting_cut_db: float = -9.0   # not in spec
@export var sting_thread_db: float = -3.0   # not in spec
@export var sting_hesitated_db: float = -2.0   # not in spec
@export var sting_hit_db: float = -2.0   # not in spec
@export var hit_impact_db: float = 0.0   # not in spec
@export var crash_db: float = 0.0   # not in spec
## Banking count-up: one tick per chime_points_per_tick banked, clamped, then the chime.
@export var chime_points_per_tick: float = 400.0   # not in spec
@export var chime_ticks_min: int = 3   # not in spec
@export var chime_ticks_max: int = 12   # not in spec
@export var chime_tick_s: float = 0.055   # not in spec
@export var chime_tick_db: float = -10.0   # not in spec
@export var chime_bank_db: float = -4.0   # not in spec
## Leg bonuses and objectives: the bank chime, quieter.
@export var bonus_chime_db: float = -9.0   # not in spec

@export_group("Music")
## The playlist (played in order, looping). Swap in licensed tracks here (docs/AUDIO.md).
@export var music_tracks: PackedStringArray = [
	"res://assets/audio/music_midnight_drive.ogg",
	"res://assets/audio/music_cyber_runner.ogg",
	"res://assets/audio/music_slampe.ogg",
]   # not in spec
## Each track's tempo for the music clock (0 = unknown: the clock stays stopped).
@export var music_bpm: PackedFloat64Array = [0.0, 0.0, 0.0]   # not in spec
@export var music_beats_per_bar: int = 4   # not in spec
## Silence between tracks (s) and the fade at the start of a track (s).
@export var music_gap_s: float = 1.5   # not in spec
@export var music_fade_in_s: float = 1.5   # not in spec
## The web export mixes music in the engine (stream playback) so the night filter works
## and a long track isn't decoded whole into memory; effects use web samples.
@export var music_stream_on_web: bool = true   # not in spec

@export_group("Voice budget")
## One-shot voices: flat (stingers, UI, impacts) and positional (whooshes, horns,
## hiss, scrapes). max_voices caps how many play at once across both; a new sound
## steals the lowest-priority oldest voice at or below its own priority, else it drops.
@export var voices_flat: int = 10   # not in spec
@export var voices_positional: int = 6   # not in spec
@export var max_voices: int = 16   # not in spec
## Priorities (higher wins).
@export var priority_stinger: int = 9   # not in spec
@export var priority_hit: int = 10   # not in spec
@export var priority_whoosh: int = 8   # not in spec
@export var priority_zip: int = 7   # not in spec
@export var priority_thump: int = 8   # not in spec
@export var priority_chime: int = 6   # not in spec
@export var priority_boost: int = 5   # not in spec
@export var priority_horn: int = 4   # not in spec
@export var priority_hiss: int = 3   # not in spec
@export var priority_scrape: int = 5   # not in spec


func wind_min_mps() -> float:
	return Units.kmh_to_mps(wind_min_kmh)


func wind_full_mps() -> float:
	return Units.kmh_to_mps(wind_full_kmh)


func tire_hum_full_mps() -> float:
	return Units.kmh_to_mps(tire_hum_full_kmh)


## True where silent loops are stopped rather than paused (the web; loop_stop_on_web).
func stops_silent_loops() -> bool:
	return loop_stop_on_web and OS.has_feature("web")


static func load_default() -> AudioTuning:
	return load(PATH) as AudioTuning


## Tuning.audio when the root tuning has it (orchestrator request), else the file.
static func resolve() -> AudioTuning:
	var root := Tuning.load_default()
	if &"audio" in root and root.get(&"audio") is AudioTuning:
		return root.get(&"audio") as AudioTuning
	return load_default()
