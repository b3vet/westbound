class_name MusicMood
extends RefCounted
## Which music the moment wants: MENU, DAY, GOLDEN, NIGHT or RUSH. Spec: Audio
## ("Music: v1 ships a small set of tracks"); Core loop → Sky timeline and sun clock
## (the phases it reads). Not in spec: the moods themselves (owner decision).
## docs/AUDIO.md → Music.
##
## Pure and headless: no Node, no autoload; GameAudio feeds it the game's state each
## frame and hands the result to MusicPlayer.want_mood(). Allocation-free per update.
##
##   MENU    not in a run (title, garage, results, room lobby: Game state MENU/RESULTS)
##   RUSH    in a room whose density is RUSH HOUR, or a solo run (not in a room) in a
##           biome listed in AudioTuning.music_rush_biomes (the city legs)
##   NIGHT   sun phase NIGHTFALL or NIGHT
##   GOLDEN  sun phase DAY with sky_t in [sky_t_golden_hour, sky_t_sunset); latched:
##           a checkpoint's sun lift back below the golden hour keeps GOLDEN until the
##           night or a new run (reset())
##   DAY     the rest of the day, and the dawn
## Priority when several apply: MENU > RUSH > NIGHT > GOLDEN > DAY.

enum Mood { MENU, DAY, GOLDEN, NIGHT, RUSH }

const COUNT := 5
## Console and doc names, by Mood.
const NAMES: Array[String] = ["menu", "day", "golden", "night", "rush"]

var golden_t: float
var sunset_t: float
var rush_biomes: Array[StringName] = []
## The last update's mood.
var mood: Mood = Mood.MENU
## The last update's time-of-day mood (DAY, GOLDEN or NIGHT), menu and rush aside.
var time_mood: Mood = Mood.DAY
## GOLDEN reached in this run (cleared by the night, reset() and leaving the run).
var golden_latched: bool = false


func _init(audio: AudioTuning, sun: SunTuning) -> void:
	golden_t = sun.sky_t_golden_hour
	sunset_t = sun.sky_t_sunset
	rush_biomes = audio.music_rush_biomes


## A new run: the golden latch clears.
func reset() -> void:
	golden_latched = false


## The wanted mood for this moment. `in_run`: a run is being driven (countdown,
## running, crash); `in_room`: the run is in a multiplayer room, `room_rush`: on RUSH
## HOUR density; `biome`: the BiomeDef.id at the player (solo runs); `phase`, `sky_t`:
## the run's SunClock.
func update(in_run: bool, in_room: bool, room_rush: bool, biome: StringName, phase: SunClock.Phase,
		sky_t: float) -> Mood:
	if not in_run:
		golden_latched = false
		time_mood = Mood.DAY
		mood = Mood.MENU
		return mood
	match phase:
		SunClock.Phase.NIGHTFALL, SunClock.Phase.NIGHT:
			golden_latched = false
			time_mood = Mood.NIGHT
		SunClock.Phase.DAY:
			if sky_t >= golden_t and sky_t < sunset_t:
				golden_latched = true
			time_mood = Mood.GOLDEN if golden_latched else Mood.DAY
		_:
			golden_latched = false
			time_mood = Mood.DAY
	var rush := room_rush if in_room else rush_biomes.has(biome)
	mood = Mood.RUSH if rush else time_mood
	return mood


## The mood likely to follow `m` (what MusicPlayer prefetches): MENU → DAY,
## DAY → GOLDEN, GOLDEN → NIGHT, NIGHT → DAY, RUSH → the time-of-day mood.
func likely_next(m: Mood) -> Mood:
	match m:
		Mood.MENU:
			return Mood.DAY
		Mood.DAY:
			return Mood.GOLDEN
		Mood.GOLDEN:
			return Mood.NIGHT
		Mood.NIGHT:
			return Mood.DAY
	return time_mood
