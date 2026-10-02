class_name MusicPlayer
extends Node
## The music: mood pools on the Music bus, crossfades, and the night filter. Spec: Audio
## ("Music: v1 ships a small set of tracks. Night applies a low-pass filter and reverb
## to the music bus"); Hooks ("a music clock the sim can read"). Not in spec: the moods
## (owner decision). docs/AUDIO.md → Music.
##
## - Moods: GameAudio tells it the wanted mood (want_mood(), from MusicMood). Each mood
##   has a pool (AudioTuning.music_pool_*) played in rotation: at a track's end the
##   next of the pool plays after music_gap_s with a music_fade_in_s fade-in, never the
##   same track twice in a row (pools of 2+), and each pool's place in its rotation is
##   kept across mood changes. A new track always starts from the top.
## - Mood change: a crossfade over music_crossfade_s on the second player (A/B), once
##   the playing track has played music_min_play_s; an earlier change waits for that and
##   is dropped if the mood flips back meanwhile. Entering or leaving MENU does not wait.
## - Tracks it cannot load yet (the web: `pack`, WebMusicPack, fetches each track's pack
##   on demand): it asks for the track, keeps the current music (or silence) and starts
##   it when it lands. When a track starts it prefetches the next of its pool and the
##   first of the likely next mood (`next_hint`). Without a pack every track is present.
## - Night fades the Music bus low-pass + reverb in over night_fade_s (set_night(true))
##   and out again (set_night(false, over_s), e.g. over the dawn).
## - The clock follows the current (incoming) track. On the web the players use stream
##   playback (AudioTuning.music_stream_on_web) so bus effects apply and a long track is
##   never decoded whole into memory.
## WP9.2: `hold` defers start() until release() (the web page's audio is still locked,
## WebAudio), so the music starts on the unlock with its fade-in instead of "playing"
## silently in a suspended context.

## A track started (its path and MusicMood.Mood).
signal track_started(path: String, mood: int)

const PLAYER_NAMES: Array[String] = ["MusicA", "MusicB"]

var tuning: AudioTuning
## The current (incoming) player; `players` holds both (A/B).
var player: AudioStreamPlayer
var players: Array[AudioStreamPlayer] = []
var clock := MusicClock.new()
## Index into music_tracks of the current (or last) track.
var track: int = -1
## The wanted mood (MusicMood.Mood) and the one likely after it (prefetch).
var mood: int = MusicMood.Mood.MENU
var next_hint: int = MusicMood.Mood.DAY
## The mood of the current track (-1: none).
var playing_mood: int = -1
## Seconds the current track has played.
var played_s: float = 0.0
## 0 = day .. 1 = full night (drives the bus effects).
var night: float = 0.0
var night_target: float = 0.0
var enabled: bool = true
var tracks_started: int = 0
var crossfades: int = 0
## WP9.2: while true, start() only remembers the request; release() plays it.
var hold: bool = false
## Where tracks come from when not every track is present (the web); null: all present.
var pack: WebMusicPack

var _start_held: bool = false
## start() was called (and not stop()): the music goes on from track to track.
var _active: bool = false
## The wanted change enters or leaves MENU: no minimum play.
var _urgent: bool = false
## The track waited for (its pack is on the way; -1 none), and the mood the last start
## was tried for while nothing started (-1: none; stops a retry every frame).
var _pending: int = -1
var _pending_mood: int = -1
var _night_rate: float = 0.0
var _gap_left: float = 0.0
## The current player's fade: progress 0..1, per second, equal-power (a crossfade).
var _fade: float = 1.0
var _fade_rate: float = 0.0
var _fade_eq: bool = false
## The outgoing player of a crossfade (null when none), its power (1 -> 0) and rate.
var _old: AudioStreamPlayer
var _old_power: float = 0.0
var _old_rate: float = 0.0
## Per mood: its pool as music_tracks indices, and the rotation's next slot.
var _pools: Array[PackedInt32Array] = []
var _rot := PackedInt32Array()


func setup(t: AudioTuning) -> void:
	tuning = t
	_build_pools()
	if player != null:
		return
	for n in PLAYER_NAMES:
		var p := AudioStreamPlayer.new()
		p.name = n
		p.bus = AudioBuses.MUSIC
		if OS.has_feature("web") and t.music_stream_on_web:
			p.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		p.finished.connect(_on_finished.bind(p))
		add_child(p)
		players.append(p)
	player = players[0]
	AudioBuses.set_night(0.0, t)


## Tracks come from `p` (WebMusicPack) from now on: unloaded ones are fetched first.
func bind_pack(p: WebMusicPack) -> void:
	if pack == p:
		return
	if pack != null:
		pack.track_loaded.disconnect(_on_track_loaded)
		pack.track_failed.disconnect(_on_track_failed)
	pack = p
	if pack != null:
		pack.track_loaded.connect(_on_track_loaded)
		pack.track_failed.connect(_on_track_failed)


## Starts the music now (a track of the wanted mood), or keeps the current one playing.
func start() -> void:
	if not enabled or tuning == null or tuning.music_tracks.is_empty():
		return
	if hold:
		_start_held = true
		_request(_peek(mood))   # fetch it while the page waits for its first gesture
		return
	_active = true
	if player.playing:
		return
	_gap_left = 0.0
	_begin(mood, false)


## WP9.2: ends the hold and starts the music if start() was asked for meanwhile.
func release() -> void:
	hold = false
	if _start_held:
		_start_held = false
		start()


func stop() -> void:
	_start_held = false
	_active = false
	for p in players:
		p.stop()
	_old = null
	clock.stop()
	_gap_left = 0.0
	_pending = -1
	_pending_mood = -1
	_urgent = false
	playing_mood = -1


func is_playing() -> bool:
	return player != null and player.playing


## The wanted mood (MusicMood.Mood) and the one likely after it (-1: keep). A change to
## or from MENU switches at once; the others wait for music_min_play_s (update()).
func want_mood(m: int, hint: int = -1) -> void:
	if hint >= 0:
		next_hint = hint
	if m == mood:
		return
	if m == MusicMood.Mood.MENU or mood == MusicMood.Mood.MENU:
		_urgent = true
	mood = m


## The track being waited for ("" when none).
func pending_track() -> String:
	return tuning.music_tracks[_pending] if _pending >= 0 else ""


## The current (or last) track's path ("" before the first).
func track_path() -> String:
	return tuning.music_tracks[track] if track >= 0 else ""


## The outgoing player while a crossfade runs, else null.
func fading_out() -> AudioStreamPlayer:
	return _old


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


## Per frame (real time). Allocation-free.
func update(dt: float) -> void:
	if tuning == null:
		return
	if night != night_target:
		night = move_toward(night, night_target, _night_rate * dt)
		AudioBuses.set_night(night, tuning)
	_update_fades(dt)
	if player.playing:
		played_s += dt
	if _gap_left > 0.0:
		_gap_left -= dt
		if _gap_left <= 0.0:
			_gap_left = 0.0
			if _active and not hold:
				_begin(mood, false)
	elif _active and not hold:
		_follow_mood()
	if player.playing:
		var bpm := tuning.music_bpm[track] if track >= 0 and track < tuning.music_bpm.size() else 0.0
		clock.sync(player.get_playback_position(), bpm, tuning.music_beats_per_bar)
	else:
		clock.stop()


## Moves to the wanted mood when allowed: at once from silence, else after the minimum
## play (at once when urgent).
func _follow_mood() -> void:
	if player.playing:
		if playing_mood == mood:
			_urgent = false   # flipped back: the waiting change is dropped
			_pending = -1
			_pending_mood = -1
		elif (_urgent or played_s >= tuning.music_min_play_s) and _pending_mood != mood:
			_begin(mood, true)
	elif _pending_mood != mood:
		_begin(mood, false)


func _update_fades(dt: float) -> void:
	if _fade < 1.0 and player.playing:
		_fade = minf(_fade + _fade_rate * dt, 1.0)
		player.volume_db = _db(_fade, _fade_eq)
	if _old != null:
		_old_power = maxf(_old_power - _old_rate * dt, 0.0)
		if _old_power <= 0.0:
			_end_old()
		else:
			_old.volume_db = _db(_old_power, true)


## Plays a track of mood `m` (crossfading from the current one when `xfade` and one
## plays), or asks for one and waits.
func _begin(m: int, xfade: bool) -> void:
	var pick := _choose(m)
	if pick >= 0:
		_play(pick, m, xfade and player.playing)


## The track to play for mood `m`: rotation order, skipping the current track (pools of
## 2+) and failed ones, taking the first that is loaded. None loaded: asks for the first
## candidate (_pending) and returns -1; nothing can play: -1.
func _choose(m: int) -> int:
	_pending = -1
	_pending_mood = m
	if m < 0 or m >= _pools.size():
		return -1
	var pool := _pools[m]
	var n := pool.size()
	var wait := -1
	var start_at := _rot[m]
	for k in n:
		var i := (start_at + k) % n
		var ti := pool[i]
		if (n > 1 and ti == track) or _failed(ti):
			continue
		if _loaded(ti):
			_rot[m] = (i + 1) % n
			return ti
		if wait < 0:
			wait = ti
	if wait >= 0:
		_pending = wait
		_request(wait)
		return -1
	if track >= 0 and pool.has(track) and not _failed(track) and _loaded(track):
		return track   # nothing else can play: the same track again
	return -1


## The track mood `m` would play next, loaded or not (-1: none).
func _peek(m: int) -> int:
	if m < 0 or m >= _pools.size():
		return -1
	var pool := _pools[m]
	var n := pool.size()
	for k in n:
		var ti := pool[(_rot[m] + k) % n]
		if (n > 1 and ti == track) or _failed(ti):
			continue
		return ti
	return -1


func _play(ti: int, m: int, xfade: bool) -> void:
	var path := tuning.music_tracks[ti]
	var stream := AudioBank.load_track(path)
	if stream == null:
		return
	if _old != null:
		_end_old()
	if xfade:
		var g := _gain(_fade, _fade_eq)
		_old = player
		_old_power = g * g
		_old_rate = _rate(tuning.music_crossfade_s)
		player = players[(players.find(player) + 1) % players.size()]
		_fade_rate = _old_rate
		_fade_eq = true
		crossfades += 1
	else:
		_fade_rate = _rate(tuning.music_fade_in_s)
		_fade_eq = false
	_fade = 1.0 if is_inf(_fade_rate) else 0.0
	player.stream = stream
	player.volume_db = _db(_fade, _fade_eq)
	player.play()
	if _old != null and is_inf(_old_rate):
		_end_old()
	track = ti
	playing_mood = m
	played_s = 0.0
	tracks_started += 1
	_pending = -1
	_pending_mood = -1
	_urgent = false
	_gap_left = 0.0
	track_started.emit(path, m)
	# Prefetch (the web): the next of this pool, then the first of the likely next mood.
	_request(_peek(m))
	_request(_peek(next_hint))


func _end_old() -> void:
	_old.stop()
	_old.stream = null   # only the playing track stays loaded
	_old = null


func _gain(progress: float, equal_power: bool) -> float:
	return sqrt(progress) if equal_power else progress


func _db(progress: float, equal_power: bool) -> float:
	return linear_to_db(maxf(_gain(progress, equal_power), tuning.silent_gain))


static func _rate(over_s: float) -> float:
	return 1.0 / over_s if over_s > 0.0 else INF


func _loaded(ti: int) -> bool:
	return pack == null or pack.is_loaded(tuning.music_tracks[ti])


func _failed(ti: int) -> bool:
	return pack != null and pack.has_failed(tuning.music_tracks[ti])


func _request(ti: int) -> void:
	if pack != null and ti >= 0:
		pack.request(tuning.music_tracks[ti])


func _build_pools() -> void:
	_pools.clear()
	_rot.resize(MusicMood.COUNT)
	_rot.fill(0)
	for m in MusicMood.COUNT:
		var pool := PackedInt32Array()
		for path in tuning.music_pool(m):
			var i := tuning.music_tracks.find(path)
			if i >= 0:
				pool.append(i)
		_pools.append(pool)


func _on_finished(p: AudioStreamPlayer) -> void:
	if p != player:
		if p == _old:
			_end_old()
		return
	if not _active:
		return
	if tuning.music_gap_s > 0.0:
		_gap_left = tuning.music_gap_s
	elif not hold:
		_begin(mood, false)


func _on_track_loaded(path: String) -> void:
	if _pending >= 0 and tuning.music_tracks[_pending] == path and _active and not hold:
		_begin(_pending_mood, true)


func _on_track_failed(path: String) -> void:
	if _pending >= 0 and tuning.music_tracks[_pending] == path and _active and not hold:
		_begin(_pending_mood, true)
