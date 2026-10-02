class_name WebMusicPack
extends Node
## The web build's music, one pack per track, fetched when the music needs it (WP9.2;
## per-track streaming for the music moods). Spec: Platform (web export second); Audio
## ("Music"); Implementation order, Phase 9 ("load time"). docs/WEB.md → Music packs.
##
## The page downloads the whole main pack before the engine starts, so the Web preset's
## exclude filter leaves the music out of index.pck and tools/export_web.sh writes each
## track as music/<track>.pck beside it (platform/web/pack_music.gd). MusicPlayer asks
## for a track with request() before it plays it:
##
## - a track already present (native builds, a web build that still packs the music, a
##   pack mounted before) is_loaded() at once: nothing is fetched;
## - otherwise the request is queued (first in, first out, once per track) and fetched
##   one at a time: music/<track>.pck?v=<build> (the custom shell's window.wbBuild) with
##   an HTTPRequest, written to the page's memory file system (/tmp, never user://,
##   which is the save's IndexedDB), mounted with ProjectSettings.load_resource_pack
##   and checked: `track_loaded`. A failed download or mount prints why (a network
##   failure is not an engine error) and emits `track_failed`; that track is skipped.
## Nothing on the boot path waits for it: the title comes up and the music fades in
## when its first track lands.

signal track_loaded(track_path: String)
signal track_failed(track_path: String)

## The packs' directory beside index.html.
const DIR := "music"
## The page's memory file system (Emscripten MEMFS): gone with the page.
const LOCAL_FMT := "/tmp/wb_music_%s.pck"
## Bytes read per frame from the finished download (HTTPRequest's default is 64 KiB).
const CHUNK_BYTES := 1 << 20

## Print progress to the console (the smoke harness reads it). On on the web.
var verbose: bool = OS.has_feature("web")
## The track being fetched ("" when idle) and the ones waiting, in order.
var current: String = ""
var queue := PackedStringArray()
## Why each failed track failed.
var failures: Dictionary[String, String] = {}
## Downloads started.
var started: int = 0

var _loaded: Dictionary[String, bool] = {}
var _http: HTTPRequest


## The pack name of a track: res://assets/audio/music_menu_1.ogg -> music_menu_1.
static func pack_name(track_path: String) -> String:
	return track_path.get_file().get_basename()


## The pack's path beside index.html (music/music_menu_1.pck).
static func pack_file(track_path: String) -> String:
	return DIR.path_join(pack_name(track_path) + ".pck")


## True when the track can be loaded now (present, or its pack is mounted).
func is_loaded(track_path: String) -> bool:
	if _loaded.has(track_path):
		return true
	if failures.has(track_path) or track_path == current:
		return false
	if ResourceLoader.exists(track_path):
		_loaded[track_path] = true
		return true
	return false


func has_failed(track_path: String) -> bool:
	return failures.has(track_path)


## Fetches the track's pack unless it is loaded, failed, being fetched or queued.
func request(track_path: String) -> void:
	if track_path.is_empty() or track_path == current or queue.has(track_path) \
			or failures.has(track_path) or is_loaded(track_path):
		return
	queue.append(track_path)
	_next()


## The pack's absolute URL beside the page, with the build id (web only; "" elsewhere).
func url(track_path: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var js := "new URL('%s' + (window.wbBuild ? '?v=' + window.wbBuild : ''), document.baseURI).href" \
		% pack_file(track_path)
	return str(JavaScriptBridge.eval(js, true))


## Mounts the current download's pack at `path` (ok = the download succeeded), settles
## that track and starts the next download. The download calls it; tests call it with
## a pack they wrote.
func finish(ok: bool, path: String, why: String = "") -> void:
	if current.is_empty():
		return
	var track_path := current
	current = ""
	if ok and not ProjectSettings.load_resource_pack(path, false):
		ok = false
		why = "could not mount %s" % path
	if ok and not ResourceLoader.exists(track_path):
		ok = false
		why = "%s does not hold %s" % [pack_file(track_path), track_path]
	if ok:
		_loaded[track_path] = true
	else:
		failures[track_path] = why
	# The next download first: a listener's requests (prefetch) queue behind it.
	_next()
	if ok:
		_say("loaded %s" % pack_name(track_path))
		track_loaded.emit(track_path)
	else:
		_say("failed %s: %s" % [pack_name(track_path), why])
		track_failed.emit(track_path)


func _next() -> void:
	if queue.is_empty() or not current.is_empty():
		return
	current = queue[0]
	queue.remove_at(0)
	started += 1
	_say("downloading %s" % pack_name(current))
	_download(url(current))


func _download(from: String) -> void:
	if from.is_empty():
		finish(false, "", "no page URL (not the web)")
		return
	_http = HTTPRequest.new()
	_http.name = "MusicRequest"
	# The browser's fetch already decodes gzip (Pages serves the pack gzip-encoded)
	# but leaves the Content-Encoding header: Godot must not gunzip it again.
	_http.accept_gzip = false
	# One read per frame: 64 KiB reads would take ~50 frames for a 3 MiB track.
	_http.download_chunk_size = CHUNK_BYTES
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	var err := _http.request(from)
	if err != OK:
		_drop_http()
		finish(false, "", "request refused (%s)" % error_string(err))


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_drop_http()
	var local := LOCAL_FMT % pack_name(current)
	var ok := result == HTTPRequest.RESULT_SUCCESS and code == HTTPClient.RESPONSE_OK and not body.is_empty()
	var why := "" if ok else "download failed (result %d, HTTP %d)" % [result, code]
	if ok:
		# The body is written out here: in the 4.7 web build HTTPRequest.download_file
		# reported success but left no file behind.
		var f := FileAccess.open(local, FileAccess.WRITE)
		if f == null:
			ok = false
			why = "cannot write %s (%s)" % [local, error_string(FileAccess.get_open_error())]
		else:
			f.store_buffer(body)
			f.close()
	finish(ok, local, why)


func _drop_http() -> void:
	if _http != null:
		_http.queue_free()
		_http = null


func _say(text: String) -> void:
	if verbose:
		print("web music: " + text)
