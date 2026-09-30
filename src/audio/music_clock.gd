class_name MusicClock
extends RefCounted
## A music clock the simulation can read. Spec: Hooks to build in v1 ("a music clock
## the sim can read (beat phase, bar)", used by Tempo Highway).
##
## v1: every query returns 0 until something syncs it with a known tempo. MusicPlayer
## (WP7A) calls sync() each frame with the playing track's position and its tempo from
## AudioTuning.music_bpm; the shipped placeholder tracks have no tempo (0), so the clock
## stays stopped. Tempo Highway adds latency calibration and tracks with a tempo; the
## sim reads it through the same methods. Pure and allocation-free.

var _bpm: float = 0.0
var _beats: float = 0.0
var _beats_per_bar: int = 4


## Position `position_s` into a track at `track_bpm` (<= 0 stops the clock).
func sync(position_s: float, track_bpm: float, beats_per_bar: int) -> void:
	if track_bpm <= 0.0 or beats_per_bar <= 0:
		stop()
		return
	_bpm = track_bpm
	_beats_per_bar = beats_per_bar
	_beats = maxf(position_s, 0.0) * track_bpm / Units.S_PER_MIN


func stop() -> void:
	_bpm = 0.0
	_beats = 0.0


## Position within the current beat, 0..1.
func beat_phase() -> float:
	return _beats - floorf(_beats) if _bpm > 0.0 else 0.0


## Bar index since the track started.
func bar() -> int:
	@warning_ignore("integer_division")
	return floori(_beats) / _beats_per_bar if _bpm > 0.0 else 0


## Beat index within the bar.
func beat_in_bar() -> int:
	return floori(_beats) % _beats_per_bar if _bpm > 0.0 else 0


## Tempo in beats per minute; 0 when no track is synced.
func bpm() -> float:
	return _bpm


func is_running() -> bool:
	return _bpm > 0.0
