extends Node
## WP9.9 (docs/WEB.md → Slim engine): runs inside a web build and checks what the engine
## can do with the game's pack. tools/web_template/probe.mjs puts this script, a scene
## holding it and an override.cfg making that scene the main scene into the page's file
## system (export templates ignore `--script`), so the game's autoloads start but its
## main scene never does. Prints:
##   PROBE classes <n> <every ClassDB class, comma separated>
##   PROBE fail <path> <why>        a resource that does not load or a script that does not compile
##   PROBE done files=<n> loaded=<n> failed=<n>
## Every script in the pack is loaded (compiled), every scene, resource and imported file too.
## Run with both templates, the failures must match (tools/web_template/verify.sh).

## probe.mjs preloads the export's music packs (music/<track>.pck) here, when there are any.
const MUSIC_DIR := "/tmp/music"

var _files := 0
var _loaded := 0
var _failed := 0


func _ready() -> void:
	var classes := ClassDB.get_class_list()
	classes.sort()
	print("PROBE classes %d %s" % [classes.size(), ",".join(classes)])
	var packs := DirAccess.get_files_at(MUSIC_DIR) if DirAccess.dir_exists_absolute(MUSIC_DIR) else PackedStringArray()
	for f in packs:
		var pck := MUSIC_DIR.path_join(f)
		if f.ends_with(".pck") and not ProjectSettings.load_resource_pack(pck):
			_fail(pck, "mount")
	var paths := PackedStringArray()
	_collect("res://", paths)
	paths.sort()
	for p in paths:
		_check(p)
	print("PROBE done files=%d loaded=%d failed=%d" % [_files, _loaded, _failed])
	get_tree().quit(0)


func _collect(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect(dir_path.path_join(sub), out)
	for f in dir.get_files():
		_files += 1
		var path := dir_path.path_join(f)
		if f.ends_with(".remap") or f.ends_with(".import"):
			path = path.get_basename()
		elif not (f.get_extension() in ["tscn", "tres", "res", "scn", "gd"]):
			continue
		if not out.has(path):
			out.append(path)


func _check(path: String) -> void:
	if not ResourceLoader.exists(path):
		return
	var res := ResourceLoader.load(path)
	if res == null:
		_fail(path, "load")
		return
	if res is Script and not (res as Script).can_instantiate():
		_fail(path, "script does not compile")
		return
	_loaded += 1


func _fail(path: String, why: String) -> void:
	_failed += 1
	print("PROBE fail %s %s" % [path, why])
