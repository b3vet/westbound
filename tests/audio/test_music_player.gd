extends WBTest
## MusicPlayer (src/audio/music_player.gd): mood pools in rotation, the minimum play,
## crossfades, and tracks that must be fetched first (a scripted WebMusicPack). Spec:
## Audio ("Music"); not in spec: the moods (owner decision). docs/AUDIO.md → Music,
## docs/WEB.md → Music packs. Short test tuning keeps every wait well under a second.

const M := MusicMood.Mood
const DT := 1.0 / 60.0
const MIN_PLAY_S := 0.5
const CROSSFADE_S := 0.2
const GAP_S := 0.05


## Tracks arrive when the test says so (land()); fetches are only recorded.
class FakePack:
	extends WebMusicPack
	var fetched: Array[String] = []

	func _download(_from: String) -> void:
		fetched.append(current)

	func is_loaded(track_path: String) -> bool:
		return _loaded.has(track_path)

	## The current download arrives (as finish() would after mounting it).
	func land() -> void:
		var track_path := current
		current = ""
		_loaded[track_path] = true
		_next()
		track_loaded.emit(track_path)


var t: AudioTuning
var _nodes: Array[Node] = []


func before_all() -> void:
	t = AudioTuning.resolve().duplicate() as AudioTuning
	t.music_min_play_s = MIN_PLAY_S
	t.music_crossfade_s = CROSSFADE_S
	t.music_gap_s = GAP_S
	t.music_fade_in_s = GAP_S


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	AudioBuses.set_night(0.0, t)


func _music(pack: WebMusicPack = null) -> MusicPlayer:
	var m := MusicPlayer.new()
	tree.root.add_child(m)
	_nodes.append(m)
	m.setup(t)
	if pack != null:
		pack.verbose = false
		m.add_child(pack)
		m.bind_pack(pack)
	return m


func _run(m: MusicPlayer, seconds: float) -> void:
	for i in ceili(seconds / DT):
		m.update(DT)


## The current track ends; the next one starts after the gap.
func _end_track(m: MusicPlayer) -> void:
	m.player.stop()
	m.player.finished.emit()
	_run(m, GAP_S + DT * 2.0)


func _name(m: MusicPlayer) -> String:
	return WebMusicPack.pack_name(m.track_path())


func test_starts_the_wanted_mood_from_the_top() -> void:
	var m := _music()
	m.start()
	check(m.is_playing())
	eq(m.playing_mood, M.MENU, "the default mood is the title's")
	eq(m.track_path(), t.music_pool_menu[0], "the pool's first track")
	le(m.player.get_playback_position(), DT, "from the top (within a mix buffer)")
	eq(m.player.bus, AudioBuses.MUSIC)
	eq(m.tracks_started, 1)
	m.start()
	eq(m.tracks_started, 1, "start() keeps a playing track")


func test_mood_change_waits_for_the_minimum_play() -> void:
	var m := _music()
	m.want_mood(M.DAY)
	m.start()
	eq(m.playing_mood, M.DAY)
	var first := m.track_path()
	m.want_mood(M.GOLDEN)
	_run(m, MIN_PLAY_S * 0.5)
	eq(m.track_path(), first, "too early: the day track plays on")
	eq(m.crossfades, 0)
	_run(m, MIN_PLAY_S * 0.5 + DT * 2.0)
	eq(m.playing_mood, M.GOLDEN, "the minimum reached: golden")
	eq(m.track_path(), t.music_pool_golden[0])
	eq(m.crossfades, 1)
	check(m.fading_out() != null and m.fading_out() != m.player, "the old track fades out on the other player")
	le(m.played_s, DT * 3.0, "the minimum counts from the new track's start")


func test_a_mood_flip_back_cancels_the_change() -> void:
	var m := _music()
	m.want_mood(M.DAY)
	m.start()
	var first := m.track_path()
	m.want_mood(M.GOLDEN)
	_run(m, MIN_PLAY_S * 0.5)
	m.want_mood(M.DAY)
	_run(m, MIN_PLAY_S)
	eq(m.track_path(), first, "back to the playing mood: nothing changes")
	eq(m.crossfades, 0)
	eq(m.tracks_started, 1)


func test_crossfade_completes_and_stops_the_old_player() -> void:
	var m := _music()
	m.want_mood(M.DAY)
	m.start()
	_run(m, GAP_S * 2.0)
	near(m.player.volume_db, 0.0, 1e-3, "faded in")
	var old := m.player
	m.want_mood(M.NIGHT)
	_run(m, MIN_PLAY_S + DT * 2.0)
	eq(m.crossfades, 1)
	check(m.player != old, "the new track on the other player")
	check(old.playing, "the old track still fades")
	lt(m.player.volume_db, 0.0, "the new one is fading in")
	_run(m, CROSSFADE_S + DT * 2.0)
	check(m.fading_out() == null, "the crossfade is over")
	check(not old.playing, "the old player stopped")
	check(old.stream == null, "and let its track go")
	check(m.player.playing)
	near(m.player.volume_db, 0.0, 1e-3, "the new track at full level")
	eq(m.playing_mood, M.NIGHT)


func test_rotation_never_repeats_back_to_back() -> void:
	var m := _music()
	m.want_mood(M.DAY)
	m.start()
	var played: Array[String] = [m.track_path()]
	for i in 6:
		_end_track(m)
		check(m.is_playing(), "the next track plays after the gap")
		played.append(m.track_path())
	for i in range(1, played.size()):
		ne(played[i], played[i - 1], "no repeat at %d" % i)
	for path in t.music_pool_day:
		check(played.has(path), "%s played" % path.get_file())
	eq(played[3], played[0], "a full rotation of the three day tracks")
	eq(m.crossfades, 0, "track ends are not crossfades")


func test_rotation_carries_across_moods() -> void:
	var m := _music()
	m.want_mood(M.DAY)
	m.start()
	eq(m.track_path(), t.music_pool_day[0])
	m.want_mood(M.GOLDEN)
	_run(m, MIN_PLAY_S + DT * 2.0)
	eq(m.track_path(), t.music_pool_golden[0])
	m.want_mood(M.DAY)
	_run(m, MIN_PLAY_S + DT * 2.0)
	eq(m.track_path(), t.music_pool_day[1], "back by day: the next day track, not the first again")
	m.want_mood(M.GOLDEN)
	_run(m, MIN_PLAY_S + DT * 2.0)
	eq(m.track_path(), t.music_pool_golden[1])


func test_menu_switches_at_once_both_ways() -> void:
	var m := _music()
	m.want_mood(M.DAY)
	m.start()
	m.want_mood(M.MENU)
	m.update(DT)
	eq(m.playing_mood, M.MENU, "quit to the title: no minimum play")
	eq(m.crossfades, 1, "still crossfaded")
	m.want_mood(M.DAY)
	m.update(DT)
	eq(m.playing_mood, M.DAY, "a run from the title: at once")
	eq(m.crossfades, 2)
	_run(m, CROSSFADE_S + DT * 2.0)
	check(m.fading_out() == null)
	var playing := 0
	for p in m.players:
		playing += 1 if p.playing else 0
	eq(playing, 1, "one player left")


func test_hold_defers_the_start_and_stop_resets() -> void:
	var m := _music()
	m.hold = true
	m.start()
	check(not m.is_playing())
	m.release()
	check(m.is_playing())
	eq(m.tracks_started, 1)
	m.stop()
	check(not m.is_playing())
	m.want_mood(M.NIGHT)
	_run(m, MIN_PLAY_S)
	check(not m.is_playing(), "stopped: no mood change starts it again")
	m.start()
	eq(m.playing_mood, M.NIGHT)


func test_waits_for_a_track_to_arrive() -> void:
	var pack := FakePack.new()
	var m := _music(pack)
	m.start()
	check(not m.is_playing(), "the title's track is not here yet: silence")
	eq(pack.current, t.music_pool_menu[0], "and it is fetched")
	eq(m.pending_track(), t.music_pool_menu[0])
	_run(m, MIN_PLAY_S)
	eq(pack.started, 1, "asked for once")
	pack.land()
	check(m.is_playing(), "it plays when it lands")
	eq(m.track_path(), t.music_pool_menu[0])
	eq(m.crossfades, 0, "from silence: a fade-in")
	eq(pack.current, t.music_pool_menu[1], "prefetch: the next of the pool first")
	eq(pack.queue, PackedStringArray([t.music_pool_day[0]]), "then the first of the likely next mood (DAY)")


func test_mood_change_keeps_the_music_until_the_new_track_lands() -> void:
	var pack := FakePack.new()
	var m := _music(pack)
	m.start()
	pack.land()   # menu 1 (plays), then menu 2 and day 1 are fetched in turn
	m.want_mood(M.NIGHT, M.DAY)
	m.update(DT)
	eq(m.playing_mood, M.MENU, "leaving the title, the night track is not here: the menu track plays on")
	eq(m.pending_track(), t.music_pool_night[0])
	check(pack.queue.has(t.music_pool_night[0]), "the night track is queued behind the prefetches")
	pack.land()   # menu 2
	eq(m.playing_mood, M.MENU)
	pack.land()   # day 1
	eq(m.playing_mood, M.MENU, "only the wanted track starts it")
	eq(pack.current, t.music_pool_night[0])
	_run(m, MIN_PLAY_S * 2.0)
	pack.land()   # night 1
	eq(m.playing_mood, M.NIGHT, "it crossfades in when it lands")
	eq(m.crossfades, 1)
	le(m.played_s, DT, "its minimum play counts from now")


func test_a_failed_track_is_skipped() -> void:
	var pack := FakePack.new()
	var m := _music(pack)
	m.want_mood(M.GOLDEN)
	m.start()
	eq(pack.current, t.music_pool_golden[0])
	pack.finish(false, "", "download failed (result 4, HTTP 404)")
	check(pack.has_failed(t.music_pool_golden[0]))
	eq(pack.current, t.music_pool_golden[1], "the next track of the pool is tried")
	pack.land()
	check(m.is_playing())
	eq(m.track_path(), t.music_pool_golden[1])
