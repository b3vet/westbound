class_name MusicClock
extends RefCounted
## A music clock the simulation can read. Spec: Hooks to build in v1 ("a music clock
## the sim can read (beat phase, bar)", used by Tempo Highway).
##
## v1 stub: no music sync, every query returns 0. A later implementation drives it from
## the playing track (AudioStreamPlayer playback position + latency calibration) and
## the sim reads it through the same methods. Pure and allocation-free.


## Position within the current beat, 0..1.
func beat_phase() -> float:
	return 0.0


## Bar index since the track started.
func bar() -> int:
	return 0


## Beat index within the bar.
func beat_in_bar() -> int:
	return 0


## Tempo in beats per minute; 0 when no track is synced.
func bpm() -> float:
	return 0.0


func is_running() -> bool:
	return false
