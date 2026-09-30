class_name WebMusicPack
extends Node
## The web build's music pack (WP9.2): the music tracks load after the game starts
## instead of delaying it. Spec: Platform (web export second); Audio ("Music: v1 ships
## a small set of tracks"); Implementation order, Phase 9 ("load time"). docs/WEB.md →
## Music pack.
##
## The tracks are 3.7 MiB of the 6.6 MiB (gzip) main pack, and the page downloads the
## whole main pack before the engine starts. tools/export_web.sh writes them to
## music.pck beside index.pck (platform/web/pack_music.gd), and the Web preset's
## exclude filter can leave them out of index.pck. begin() then:
##
## - finds every track already present (native builds, or a web build that still packs
##   the music): nothing to do, is_ready() at once;
## - otherwise downloads music.pck?v=<build> (the custom shell's window.wbBuild) with
##   an HTTPRequest, writes it to the page's memory file system (never user://, which
##   is the save's IndexedDB), mounts it with ProjectSettings.load_resource_pack and
##   checks the tracks are there: is_ready(), `loaded`.
## A failed download or mount leaves the game without music and prints why (a network
## failure is not an engine error). WebAudio holds the music until is_ready().

signal loaded()

enum Status { IDLE, NOT_NEEDED, DOWNLOADING, LOADED, FAILED }

const FILE := "music.pck"
## The page's memory file system (Emscripten MEMFS): gone with the page.
const LOCAL_PATH := "/tmp/wb_music.pck"
## Bytes read per frame from the finished download (HTTPRequest's default is 64 KiB).
const CHUNK_BYTES := 1 << 20

var status: Status = Status.IDLE
var tracks: PackedStringArray = PackedStringArray()
## Print progress to the console (the smoke harness reads it). On on the web.
var verbose: bool = OS.has_feature("web")
## Why it failed (FAILED only).
var failure: String = ""

var _http: HTTPRequest


## Starts once: nothing to do when every track exists, else fetches the pack.
func begin(track_paths: PackedStringArray) -> void:
	if status != Status.IDLE:
		return
	tracks = track_paths
	if all_present():
		status = Status.NOT_NEEDED
		return
	status = Status.DOWNLOADING
	_say("downloading %s" % FILE)
	_download(url())


func is_ready() -> bool:
	return status == Status.NOT_NEEDED or status == Status.LOADED


## True when every track can be loaded now.
func all_present() -> bool:
	for t in tracks:
		if not ResourceLoader.exists(t):
			return false
	return true


## The pack's absolute URL beside the page, with the build id (web only; "" elsewhere).
func url() -> String:
	if not OS.has_feature("web"):
		return ""
	var js := "new URL('%s' + (window.wbBuild ? '?v=' + window.wbBuild : ''), document.baseURI).href" % FILE
	return str(JavaScriptBridge.eval(js, true))


## Mounts the downloaded pack at `path` (ok = the download succeeded) and settles the
## status. The download calls it; tests call it with a pack they wrote.
func finish(ok: bool, path: String, why: String = "") -> void:
	if status != Status.DOWNLOADING:
		return
	if not ok:
		_fail(why)
		return
	if not ProjectSettings.load_resource_pack(path, false):
		_fail("could not mount %s" % path)
		return
	if not all_present():
		_fail("%s does not hold every music track" % FILE)
		return
	status = Status.LOADED
	_say("loaded %d tracks" % tracks.size())
	loaded.emit()


func _download(from: String) -> void:
	if from.is_empty():
		finish(false, "", "no page URL (not the web)")
		return
	_http = HTTPRequest.new()
	_http.name = "MusicPackRequest"
	# The browser's fetch already decodes gzip (Pages serves the pack gzip-encoded)
	# but leaves the Content-Encoding header: Godot must not gunzip it again.
	_http.accept_gzip = false
	# One read per frame: 64 KiB reads would take ~60 frames for the 3.7 MiB pack.
	_http.download_chunk_size = CHUNK_BYTES
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	var err := _http.request(from)
	if err != OK:
		finish(false, "", "request refused (%s)" % error_string(err))


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var ok := result == HTTPRequest.RESULT_SUCCESS and code == HTTPClient.RESPONSE_OK and not body.is_empty()
	var why := "" if ok else "download failed (result %d, HTTP %d)" % [result, code]
	if ok:
		# The body is written out here: in the 4.7 web build HTTPRequest.download_file
		# reported success but left no file behind.
		var f := FileAccess.open(LOCAL_PATH, FileAccess.WRITE)
		if f == null:
			ok = false
			why = "cannot write %s (%s)" % [LOCAL_PATH, error_string(FileAccess.get_open_error())]
		else:
			f.store_buffer(body)
			f.close()
	finish(ok, LOCAL_PATH, why)
	if _http != null:
		_http.queue_free()
		_http = null


func _fail(why: String) -> void:
	status = Status.FAILED
	failure = why
	_say("no music: %s" % why)


func _say(text: String) -> void:
	if verbose:
		print("web music: " + text)
