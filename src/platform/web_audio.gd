class_name WebAudio
extends Node
## The web build's audio unlock and boot marks (WP9.2). Spec: Platform (web export
## second); Audio ("Music"); Implementation order, Phase 9 ("web build polish ... load
## time"). docs/WEB.md → Audio unlock.
##
## GameAudio adds one on the web (wanted()) and binds its music to it. It polls the
## page's AudioContext through a WebAudioBridge and feeds WebAudioUnlock:
##
## - While the page's audio is locked (no user gesture yet), the music's start is held
##   (MusicPlayer.hold), so the title's music does not "start" in a suspended context
##   and lose its fade-in. The first tap, click or key anywhere unlocks (the engine and
##   the bridge both resume the context inside the gesture) and the music starts then,
##   from the top with its fade-in.
## - It never touches the context when the page could already play (autoplay allowed,
##   or nothing to read): nothing is held.
## - The music also waits for its pack (WebMusicPack: music.pck, fetched in the
##   background when the main pack leaves the music out), so no track is loaded before
##   it exists. Where the tracks are in the main pack this costs nothing.
## - Boot marks (WebBoot): "title" on the first frame after the title (Game.MENU) was
##   drawn, "run" for a direct boot into a run (`?title=0`, `?mode=`), and "start" when
##   the first run starts after the title (WP9.7).
## - `?probe=ui` (the smoke test's tap on PLAY, WP9.7): adds a WebUiProbe.
##
## It only listens and reads; it never drives gameplay (Architecture rule 8).

signal unlocked()

## Poll period while locked (the music waits on it) and once unlocked (iOS relocks).
## Platform timing, not gameplay tuning.
const POLL_LOCKED_S := 0.1
const POLL_UNLOCKED_S := 1.0

var bridge: WebAudioBridge
var unlock := WebAudioUnlock.new()
var music: MusicPlayer
## The music pack (made in start() when unset; tests set one).
var music_pack: WebMusicPack
## Print state changes to the console (the smoke harness reads them). On by default on
## the web; tests turn it off.
var verbose: bool = OS.has_feature("web")

var _poll_left: float = 0.0
var _started: bool = false
var _menu_frames: int = -1


## True where an unlock can be needed: the web build.
static func wanted() -> bool:
	return OS.has_feature("web")


func _init() -> void:
	name = "WebAudio"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	start()


## Installs the bridge and reads the state once (idempotent; bind_music calls it).
func start() -> void:
	if _started:
		return
	_started = true
	if bridge == null:
		bridge = WebAudioBridge.new()
	bridge.install()
	if music_pack == null:
		music_pack = WebMusicPack.new()
		music_pack.name = "MusicPack"
	if music_pack.get_parent() == null:
		add_child(music_pack)
	music_pack.loaded.connect(_on_pack_loaded)
	if WebUiProbe.wanted():
		add_child(WebUiProbe.new())
	poll()


## Holds `m`'s start while the audio is locked or its pack is missing; the first
## unlock with the pack present releases it. Starts the pack's download if needed.
func bind_music(m: MusicPlayer) -> void:
	start()
	music = m
	if music != null and music.tuning != null:
		music_pack.begin(music.tuning.music_tracks)
	_apply_hold()


## True while the music must not start: the page's audio is locked, or the tracks are
## not loaded yet.
func holds_music() -> bool:
	return unlock.holds_music() or (music_pack != null and not music_pack.is_ready())


func is_locked() -> bool:
	return unlock.is_locked()


## Reads the context state now and applies the transition.
func poll() -> void:
	var change := unlock.observe(bridge.state(), Time.get_ticks_msec() / 1000.0)
	_poll_left = POLL_LOCKED_S if unlock.is_locked() else POLL_UNLOCKED_S
	match change:
		WebAudioUnlock.Change.LOCKED:
			_say("locked (context from %s); music waits for the first tap, click or key" % bridge.source())
		WebAudioUnlock.Change.UNLOCKED:
			_apply_hold()
			_say("unlocked after %.1f s locked; music %s" % [unlock.wait_s(), _music_state()])
			unlocked.emit()
		WebAudioUnlock.Change.RELOCKED:
			_say("suspended again (%d)" % unlock.relocks)
		WebAudioUnlock.Change.RESUMED:
			_say("resumed")


## Holds or releases the music (bind_music, the unlock, the pack's `loaded`).
func _apply_hold() -> void:
	if music == null:
		return
	if holds_music():
		music.hold = true
	elif music.hold:
		music.release()


func _on_pack_loaded() -> void:
	_apply_hold()
	_say("music pack in; music %s" % _music_state())


func _music_state() -> String:
	if music == null:
		return "idle"
	if music.is_playing():
		return "playing"
	if unlock.holds_music():
		return "waiting for the first tap, click or key"
	if music_pack != null and not music_pack.is_ready():
		return "waiting for %s" % WebMusicPack.FILE
	return "idle"


func _process(dt: float) -> void:
	_poll_left -= dt
	if _poll_left <= 0.0:
		poll()
	_boot_marks()


func _boot_marks() -> void:
	if not wanted() or WebBoot.is_marked(WebBoot.RUN) or WebBoot.is_marked(WebBoot.START):
		return
	var st := Game.state
	if WebBoot.is_marked(WebBoot.TITLE):
		if st == Game.COUNTDOWN or st == Game.RUNNING:
			WebBoot.mark(WebBoot.START)
		return
	if st == Game.MENU:
		_menu_frames += 1
		if _menu_frames >= 1:   # the title's first frame has been drawn
			WebBoot.mark(WebBoot.TITLE)
	elif st == Game.COUNTDOWN or st == Game.RUNNING:
		WebBoot.mark(WebBoot.RUN)


func _say(text: String) -> void:
	if verbose:
		print("web audio: " + text)
