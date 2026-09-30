class_name MusicPlayer
extends Node
## The music: a small playlist on the Music bus, with the night filter. Spec: Audio
## ("Music: v1 ships a small set of tracks. Night applies a low-pass filter and reverb
## to the music bus"); Hooks ("a music clock the sim can read"). docs/AUDIO.md → Music.
##
## Tracks (AudioTuning.music_tracks) play in order and loop around, with music_gap_s
## between them and a short fade-in. Only the playing track is loaded. Night fades the
## Music bus low-pass + reverb in over night_fade_s (set_night(true)) and out again
## (set_night(false, over_s), e.g. over the dawn). The clock follows the playing track.
## On the web the player uses stream playback (AudioTuning.music_stream_on_web) so bus
## effects apply and a long track is never decoded whole into memory.

var tuning: AudioTuning
var player: AudioStreamPlayer
var clock := MusicClock.new()
## Index into music_tracks of the current (or next) track.
var track: int = -1
## 0 = day .. 1 = full night (drives the bus effects).
var night: float = 0.0
var night_target: float = 0.0
var enabled: bool = true
var tracks_started: int = 0

var _night_rate: float = 0.0
var _gap_left: float = 0.0
var _fade: float = 1.0


func setup(t: AudioTuning) -> void:
	tuning = t
	if player != null:
		return
	player = AudioStreamPlayer.new()
	player.name = "Music"
	player.bus = AudioBuses.MUSIC
	if OS.has_feature("web") and t.music_stream_on_web:
		player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	player.finished.connect(_on_finished)
	add_child(player)
	AudioBuses.set_night(0.0, t)


## Starts the next track now (or keeps the current one playing).
func start() -> void:
	if not enabled or tuning == null or tuning.music_tracks.is_empty():
		return
	if player.playing:
		return
	_next()


func stop() -> void:
	if player != null:
		player.stop()
	clock.stop()
	_gap_left = 0.0


func is_playing() -> bool:
	return player != null and player.playing


## Night on (fade in over night_fade_s) or off (over `over_s`, at most night_fade_s;
## 0 = at once).
func set_night(on: bool, over_s: float = -1.0) -> void:
	night_target = 1.0 if on else 0.0
	var fade_s := tuning.night_fade_s
	if not on and over_s >= 0.0:
		fade_s = minf(over_s, tuning.night_fade_s)
	_night_rate = 1.0 / fade_s if fade_s > 0.0 else INF
	if is_inf(_night_rate):
		night = night_target
		AudioBuses.set_night(night, tuning)


## Per frame (real time).
func update(dt: float) -> void:
	if tuning == null:
		return
	if night != night_target:
		night = move_toward(night, night_target, _night_rate * dt)
		AudioBuses.set_night(night, tuning)
	if _gap_left > 0.0:
		_gap_left -= dt
		if _gap_left <= 0.0:
			_next()
	if player.playing:
		if _fade < 1.0:
			_fade = minf(_fade + dt / maxf(tuning.music_fade_in_s, dt), 1.0)
			player.volume_db = linear_to_db(maxf(_fade, tuning.silent_gain))
		var bpm := tuning.music_bpm[track] if track >= 0 and track < tuning.music_bpm.size() else 0.0
		clock.sync(player.get_playback_position(), bpm, tuning.music_beats_per_bar)
	else:
		clock.stop()


func _next() -> void:
	var n := tuning.music_tracks.size()
	if n == 0:
		return
	track = (track + 1) % n
	var stream := AudioBank.load_track(tuning.music_tracks[track])
	if stream == null:
		return
	player.stream = stream
	_fade = 0.0
	player.volume_db = linear_to_db(tuning.silent_gain)
	player.play()
	tracks_started += 1


func _on_finished() -> void:
	_gap_left = maxf(tuning.music_gap_s, get_process_delta_time())
