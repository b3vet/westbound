extends WBTest
## Web audio unlock (WP9.2): src/platform/web_audio_unlock.gd (the state machine),
## web_audio.gd (the node), the MusicPlayer hold and the GameAudio hook. Spec: Platform
## (web export); Audio (music). docs/WEB.md → Audio unlock. Headless runs are not the
## web: a scripted bridge stands in for the page's AudioContext. The real page side is
## covered by `node tools/web_smoke/smoke.mjs --audio-unlock` (headless Chromium, the
## browser's default autoplay policy).

const S := WebAudioUnlock.State
const C := WebAudioUnlock.Change
const DT := 1.0 / 60.0


## The page's AudioContext, scripted.
class FakeBridge:
	extends WebAudioBridge
	var ctx_state: String = "suspended"
	var installs: int = 0

	func install() -> bool:
		installs += 1
		return true

	func state() -> String:
		return ctx_state

	func source() -> String:
		return "test"


var _nodes: Array[Node] = []


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _web(ctx_state: String) -> WebAudio:
	var w := WebAudio.new()
	var b := FakeBridge.new()
	b.ctx_state = ctx_state
	w.bridge = b
	w.verbose = false
	return w


func _music() -> MusicPlayer:
	var m := MusicPlayer.new()
	tree.root.add_child(m)
	_nodes.append(m)
	m.setup(AudioTuning.resolve())
	return m


# ---------------------------------------------------------------- State machine

func test_locked_start_holds_music_until_running() -> void:
	var u := WebAudioUnlock.new()
	eq(u.observe("suspended", 0.0), C.LOCKED, "a suspended context at boot locks")
	check(u.holds_music(), "the music waits")
	check(u.is_locked())
	eq(u.observe("suspended", 1.0), C.NONE, "still waiting: no change")
	eq(u.observe("running", 2.5), C.UNLOCKED, "the first gesture unlocks")
	check(not u.holds_music(), "the music may start")
	check(not u.is_locked())
	eq(u.state, S.UNLOCKED)
	near(u.wait_s(), 2.5, 1e-9, "waited from the first look to the unlock")
	eq(u.observe("running", 3.0), C.NONE, "unlocked once")


func test_autoplay_allowed_or_unknown_holds_nothing() -> void:
	var u := WebAudioUnlock.new()
	eq(u.observe("running", 0.0), C.NONE, "already running: nothing to wait for")
	check(not u.holds_music())
	near(u.wait_s(), 0.0, 1e-9)
	var v := WebAudioUnlock.new()
	eq(v.observe("", 0.0), C.NONE, "unknowable (no context, no userActivation): never hold")
	check(not v.holds_music())
	check(not v.is_locked())
	var w := WebAudioUnlock.new()
	w.observe("closed", 0.0)
	check(not w.holds_music(), "a closed context never plays: holding would wait forever")


func test_ios_interrupted_counts_as_locked() -> void:
	var u := WebAudioUnlock.new()
	eq(u.observe("interrupted", 0.0), C.LOCKED)
	check(u.holds_music())
	eq(u.observe("running", 0.4), C.UNLOCKED)


func test_closed_while_locked_releases_the_music() -> void:
	var u := WebAudioUnlock.new()
	u.observe("suspended", 0.0)
	eq(u.observe("closed", 1.0), C.UNLOCKED, "released rather than held forever")
	check(not u.holds_music())


func test_relock_after_unlock_does_not_hold_music() -> void:
	var u := WebAudioUnlock.new()
	u.observe("suspended", 0.0)
	u.observe("running", 1.0)
	eq(u.observe("interrupted", 5.0), C.RELOCKED, "iOS interrupts a hidden tab")
	check(u.is_locked())
	check(not u.holds_music(), "the music already plays; it resumes with the context")
	eq(u.relocks, 1)
	eq(u.observe("interrupted", 6.0), C.NONE)
	eq(u.observe("running", 7.0), C.RESUMED)
	check(not u.is_locked())
	near(u.wait_s(), 1.0, 1e-9, "the first unlock's wait is kept")
	eq(u.observe("suspended", 8.0), C.RELOCKED)
	eq(u.relocks, 2)


# ---------------------------------------------------------------- Music hold

func test_music_hold_defers_start_until_release() -> void:
	var m := _music()
	m.hold = true
	m.start()
	check(not m.is_playing(), "held: nothing plays yet")
	eq(m.tracks_started, 0)
	m.release()
	check(m.is_playing(), "released: the held start plays")
	eq(m.tracks_started, 1)
	near(m.player.volume_db, linear_to_db(m.tuning.silent_gain), 1e-3, "from silence: the fade-in runs from the unlock")
	m.release()
	eq(m.tracks_started, 1, "a second release starts nothing new")
	m.stop()


func test_music_release_without_a_request_stays_quiet() -> void:
	var m := _music()
	m.hold = true
	m.release()
	check(not m.is_playing(), "no start was asked for")
	m.hold = true
	m.start()
	m.stop()
	m.release()
	check(not m.is_playing(), "stop() drops a held start")


# ---------------------------------------------------------------- The node

func test_node_holds_then_starts_music_on_the_first_unlock() -> void:
	var m := _music()
	var w := _web("suspended")
	tree.root.add_child(w)
	_nodes.append(w)
	w.bind_music(m)
	var fired: Array[int] = [0]
	w.unlocked.connect(func() -> void: fired[0] += 1)
	check(w.is_locked(), "boot: locked")
	check(m.hold, "the music is held")
	m.start()
	check(not m.is_playing(), "the title asked for music: held")
	w._process(WebAudio.POLL_LOCKED_S * 3.0)
	check(not m.is_playing(), "no gesture yet")
	(w.bridge as FakeBridge).ctx_state = "running"
	w._process(WebAudio.POLL_LOCKED_S)
	check(not w.is_locked(), "unlocked within one locked poll period")
	check(m.is_playing(), "the music starts on the unlock")
	eq(m.tracks_started, 1)
	eq(fired[0], 1, "unlocked emitted once")
	(w.bridge as FakeBridge).ctx_state = "interrupted"
	w._process(WebAudio.POLL_UNLOCKED_S)
	check(w.is_locked(), "a relock is seen at the slow poll")
	(w.bridge as FakeBridge).ctx_state = "running"
	w._process(WebAudio.POLL_LOCKED_S)
	eq(fired[0], 1, "resuming after a relock is not a new unlock")
	eq(m.tracks_started, 1, "and does not restart the music")
	m.stop()


func test_node_with_audio_already_running_holds_nothing() -> void:
	var m := _music()
	var w := _web("running")
	tree.root.add_child(w)
	_nodes.append(w)
	w.bind_music(m)
	check(not m.hold, "autoplay allowed: no hold")
	m.start()
	check(m.is_playing())
	eq((w.bridge as FakeBridge).installs, 1, "the page side is installed once")
	m.stop()


func test_game_audio_hook_starts_title_music_on_unlock() -> void:
	var w := _web("suspended")
	var a := GameAudio.new()
	a.web_audio = w
	tree.root.add_child(a)
	_nodes.append(a)
	check(w.get_parent() == a, "the hook adopts the web audio node")
	check(a.music.hold, "locked at boot: held")
	check(not a.music.is_playing(), "autoplay music asked for but waiting")
	await tree.process_frame
	check(not a.music.is_playing())
	(w.bridge as FakeBridge).ctx_state = "running"
	w._process(WebAudio.POLL_LOCKED_S)
	check(a.music.is_playing(), "the first gesture starts the title's music")
	eq(a.music.tracks_started, 1)
	a.music.stop()


func test_off_the_web_nothing_changes() -> void:
	check(not WebAudio.wanted(), "headless tests are not the web")
	var a := GameAudio.new()
	a.autoplay_music = false
	tree.root.add_child(a)
	_nodes.append(a)
	check(a.web_audio == null, "native and desktop: no web audio node")
	check(not a.music.hold)
	var b := WebAudioBridge.new()
	check(not b.install(), "the bridge is inert")
	eq(b.state(), "")
	eq(b.source(), "none")
	near(WebBoot.mark(WebBoot.TITLE), -1.0, 1e-9, "boot marks are web only")
	check(not WebBoot.is_marked(WebBoot.TITLE))


# ---------------------------------------------------------------- Music packs

## A pack whose download is scripted (records the URLs; the test calls finish()).
class FakePack:
	extends WebMusicPack
	var downloads: Array[String] = []

	func _download(_from: String) -> void:
		downloads.append(current)


const PROBE_DIR := "res://wb_test_web_music_pack"


## Writes a .pck holding one resource at `res_path` (the stand-in "track"; `res`, else
## a plain Resource).
func _write_pack(res_path: String, res: Resource = null) -> String:
	var src := "user://wb_test_web_music_probe.tres"
	var pck := "user://wb_test_web_music_%s.pck" % res_path.get_file().get_basename()
	eq(ResourceSaver.save(res if res != null else Resource.new(), src), OK, "probe resource saved")
	var packer := PCKPacker.new()
	eq(packer.pck_start(pck), OK)
	eq(packer.add_file(res_path, src), OK)
	eq(packer.flush(), OK)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
	return pck


func _pack() -> FakePack:
	var p := FakePack.new()
	p.verbose = false
	tree.root.add_child(p)
	_nodes.append(p)
	return p


func test_pack_present_tracks_need_no_fetch() -> void:
	var p := _pack()
	for path in AudioTuning.resolve().music_tracks:
		p.request(path)
		check(p.is_loaded(path), "native and a web build that packs the music: %s" % path.get_file())
	eq(p.downloads.size(), 0, "nothing fetched")
	eq(WebMusicPack.pack_file("res://assets/audio/music_menu_1.ogg"), "music/music_menu_1.pck", "one pack per track")


func test_pack_queues_once_per_track_in_order() -> void:
	var p := _pack()
	var a := PROBE_DIR + "/track_a.tres"
	var b := PROBE_DIR + "/track_b.tres"
	var c := PROBE_DIR + "/track_c.tres"
	p.request(a)
	p.request(b)
	p.request(a)
	p.request(c)
	p.request(b)
	eq(p.downloads, [a] as Array[String], "one download at a time")
	eq(p.current, a)
	eq(p.queue, PackedStringArray([b, c]), "first in, first out, each once")
	check(not p.is_loaded(a), "not before it lands")
	p.finish(false, "", "download failed (result 4, HTTP 404)")
	eq(p.downloads, [a, b] as Array[String], "the next one starts")
	p.finish(false, "", "download failed (result 4, HTTP 404)")
	eq(p.current, c)
	p.request(a)
	eq(p.queue.size(), 0, "a failed track is not fetched again")
	p.finish(false, "", "download failed (result 4, HTTP 404)")
	eq(p.current, "", "idle")


func test_pack_mounts_a_track_and_signals() -> void:
	var track := PROBE_DIR + "/loaded_track.tres"
	var p := _pack()
	var fired: Array[String] = []
	p.track_loaded.connect(func(path: String) -> void: fired.append(path))
	p.request(track)
	eq(p.downloads.size(), 1, "a missing track: fetch its pack")
	var pck := _write_pack(track)
	p.finish(true, ProjectSettings.globalize_path(pck))
	check(p.is_loaded(track), "mounted: " + str(p.failures.get(track, "")))
	check(ResourceLoader.exists(track), "the track loads from the mounted pack")
	eq(fired, [track] as Array[String], "track_loaded once")
	p.request(track)
	eq(p.downloads.size(), 1, "a loaded track is not fetched again")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pck))


func test_pack_failures_skip_the_track_without_errors() -> void:
	var p := _pack()
	var failed: Array[String] = []
	p.track_failed.connect(func(path: String) -> void: failed.append(path))
	var never := PROBE_DIR + "/never.tres"
	p.request(never)
	p.finish(false, "", "download failed (result 4, HTTP 404)")
	check(p.has_failed(never))
	check(not p.is_loaded(never), "no music rather than a missing-file error")
	check(p.failures[never].contains("404"))
	eq(failed, [never] as Array[String])
	var other := _write_pack(PROBE_DIR + "/other.tres")
	var missing := PROBE_DIR + "/still_missing.tres"
	p.request(missing)
	p.finish(true, ProjectSettings.globalize_path(other))
	check(p.has_failed(missing), "a pack without its track does not count")
	eq(failed.size(), 2)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(other))


## Tracks stand-ins: a test tuning whose pools name probe resources.
func _probe_tuning(menu: String, day: String) -> AudioTuning:
	var t := AudioTuning.resolve().duplicate() as AudioTuning
	t.music_tracks = PackedStringArray([menu, day])
	t.music_bpm = PackedFloat64Array([0.0, 0.0])
	t.music_pool_menu = PackedStringArray([menu])
	t.music_pool_day = PackedStringArray([day])
	return t


func test_music_waits_for_the_unlock_and_its_track() -> void:
	var menu := "res://assets/audio/music_menu_1.ogg"
	var m := MusicPlayer.new()
	tree.root.add_child(m)
	_nodes.append(m)
	m.setup(_probe_tuning(menu, "res://assets/audio/music_day_cruise_1.ogg"))
	var w := _web("suspended")
	var p := FakePack.new()
	p.verbose = false
	w.music_pack = p
	tree.root.add_child(w)
	_nodes.append(w)
	w.bind_music(m)
	check(p.get_parent() == w, "the node adopts its pack")
	check(m.pack == p, "the music asks the pack for its tracks")
	m.start()
	check(not m.is_playing(), "locked")
	eq(p.downloads.size(), 0, "a present track is never fetched")
	(w.bridge as FakeBridge).ctx_state = "running"
	w._process(WebAudio.POLL_LOCKED_S)
	check(not w.is_locked(), "unlocked")
	check(not m.hold, "the title no longer waits for any download")
	check(m.is_playing(), "a present track plays on the unlock")
	eq(m.tracks_started, 1)
	m.stop()


func test_music_starts_when_its_pack_lands_after_the_unlock() -> void:
	var menu := PROBE_DIR + "/late_menu.tres"
	var m := MusicPlayer.new()
	tree.root.add_child(m)
	_nodes.append(m)
	m.setup(_probe_tuning(menu, PROBE_DIR + "/late_day.tres"))
	var w := _web("suspended")
	var p := FakePack.new()
	p.verbose = false
	w.music_pack = p
	tree.root.add_child(w)
	_nodes.append(w)
	w.bind_music(m)
	m.start()
	eq(p.downloads, [menu] as Array[String], "held by the lock, the title's track is already on its way")
	(w.bridge as FakeBridge).ctx_state = "running"
	w._process(WebAudio.POLL_LOCKED_S)
	check(not w.is_locked(), "unlocked")
	check(not m.is_playing(), "no track loaded before its pack")
	eq(m.pending_track(), menu, "waiting for it")
	eq(p.downloads.size(), 1, "asked for once")
	var pck := _write_pack(menu, _probe_stream())
	p.finish(true, ProjectSettings.globalize_path(pck))
	check(m.is_playing(), "its pack arrived after the unlock: the music starts then")
	eq(m.track_path(), menu)
	eq(m.tracks_started, 1)
	m.stop()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pck))


## A tiny real AudioStream (a few silent samples) to stand in for a track.
func _probe_stream() -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var data := PackedByteArray()
	data.resize(4410)
	wav.data = data
	return wav
