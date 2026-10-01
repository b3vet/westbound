extends SceneTree
## WP9.9 (docs/WEB.md → Slim engine): which engine classes the game uses, for the web
## template's class build profile (tools/web_template/westbound.gdbuild).
##
## Godot 4.7 detects this only from the editor GUI (Project → Tools → Engine Compilation
## Configuration Editor → Detect from Project; editor/settings/editor_build_profile.cpp),
## so this script does the same headless, and more conservatively:
##   used = every identifier in the game's text files (scripts, scenes, resources, shaders,
##          .import files, project.godot; comments too) that names a class
##        + the class of every object reached by loading every game resource (scene node
##          types, sub-resources, imported files)
##        + the editor's always-kept classes and the dependencies the engine declares
##        + the ancestors of all of these
## and the profile disables, like the editor, every core Node or Resource class outside
## `used` whose parent is in `used` (a disabled class disables its descendants at compile
## time). Game files = everything but tests/, tools/, docs/, build/ and .gdignore'd dirs
## (a superset of the Web export).
##
##   tools/godot.sh --headless --path . --script res://tools/web_template/detect_classes.gd -- --write
##   ... -- --check   exit 1 if the game uses a class the template lacks: one the profile
##                    disables, or one tools/web_template/removed_classes.txt lists (the
##                    classes of the disabled modules, written by tools/web_template/verify.sh).
##                    Whole-line comments do not count as a use here.

const PROFILE_PATH := "res://tools/web_template/westbound.gdbuild"
const REMOVED_PATH := "res://tools/web_template/removed_classes.txt"
const SKIP_DIRS: Array[String] = [".godot", ".git", ".github", ".claude", "build", "docs", "tests", "tools", "node_modules"]
const TEXT_EXT: Array[String] = ["gd", "tscn", "tres", "gdshader", "gdshaderinc", "import", "cfg", "godot", "json"]
const RESOURCE_EXT: Array[String] = ["tscn", "tres", "res", "scn", "gd"]
## The editor's "necessary for the engine" classes (kept with their inheriters).
const EDITOR_KEEP: Array[String] = ["Font", "InputEvent", "ShaderInclude", "StyleBox", "Window"]
## Objects the engine creates and hands to the game without a type name in its files
## (duplicate() re-creates them by class name).
## TLSOptions (net layer) takes X509Certificate and CryptoKey.
const ENGINE_KEEP: Array[String] = [
	"World2D", "World3D", "ImageTexture", "ViewportTexture", "Theme", "Image", "X509Certificate", "CryptoKey",
]
## ADD_CLASS_DEPENDENCY() in the 4.7 sources (scene/gui/*.cpp): classes they create inside.
const DEPENDENCIES := {
	"AcceptDialog": ["Button"],
	"ColorPicker": ["LineEdit", "MenuButton", "PopupMenu"],
	"ConfirmationDialog": ["Button"],
	"FileDialog": ["Button", "ConfirmationDialog", "LineEdit", "OptionButton", "Tree"],
	"GraphEdit": ["Button", "GraphFrame", "GraphNode", "HScrollBar", "SpinBox", "VScrollBar"],
	"LineEdit": ["PopupMenu"],
	"MenuBar": ["PopupMenu"],
	"MenuButton": ["PopupMenu"],
	"OptionButton": ["PopupMenu"],
	"RichTextLabel": ["PopupMenu", "RegEx"],
	"SpinBox": ["LineEdit"],
	"TabContainer": ["TabBar", "Button"],
	"TextEdit": ["HScrollBar", "PopupMenu", "Timer", "VScrollBar"],
	"Tree": ["HScrollBar", "HSlider", "LineEdit", "Popup", "TextEdit", "Timer", "VScrollBar"],
}

var _words := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
var _used := {}
var _skip_comments := false
var _seen := {}
var _files := 0
var _loaded := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var write := args.has("--write")
	var check := args.has("--check")
	# --write keeps a class even when only a comment names it (errs toward keeping);
	# --check ignores whole-line comments (no false alarm from a doc comment's "Noise").
	_skip_comments = check and not write
	if not write and not check:
		printerr("detect_classes: pass --write or --check")
		quit(2)
		return
	_scan_dir("res://")
	var used := _close(_used)
	var disabled := _disabled(used)
	print("detect_classes: %d files, %d resources loaded, %d classes used, %d disabled (compact)" % [
			_files, _loaded, used.size(), disabled.size()])
	if write:
		_write(disabled)
		quit(0)
		return
	quit(_check(used))


func _scan_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null or dir.file_exists(".gdignore"):
		return
	dir.include_hidden = false
	for sub in dir.get_directories():
		if dir_path == "res://" and SKIP_DIRS.has(sub):
			continue
		if sub == ".godot" or sub == "node_modules":
			continue
		_scan_dir(dir_path.path_join(sub))
	for f in dir.get_files():
		var path := dir_path.path_join(f)
		var ext := f.get_extension()
		if ext == "md" or ext == "uid":
			continue
		_files += 1
		if TEXT_EXT.has(ext) or f == "project.godot":
			_scan_text(path)
		if RESOURCE_EXT.has(ext):
			_load(path)
		elif ext == "import":
			_load(path.get_basename())


func _scan_text(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if _skip_comments:
		var kept := PackedStringArray()
		for line in text.split("\n"):
			var t := line.strip_edges()
			if not (t.begins_with("#") or t.begins_with("//")):
				kept.append(line)
		text = "\n".join(kept)
	for m in _words.search_all(text):
		var word := m.get_string()
		if not _used.has(word) and ClassDB.class_exists(word):
			_used[word] = true


func _load(path: String) -> void:
	if not ResourceLoader.exists(path):
		return
	var res := ResourceLoader.load(path)
	if res == null:
		printerr("detect_classes: cannot load %s" % path)
		return
	_loaded += 1
	_walk(res)


func _walk(v: Variant) -> void:
	if v is Array:
		for e: Variant in v:
			_walk(e)
		return
	if v is Dictionary:
		for k: Variant in v:
			_walk(k)
			_walk(v[k])
		return
	if not (v is Object):
		return
	var obj := v as Object
	if obj == null or _seen.has(obj.get_instance_id()):
		return
	_seen[obj.get_instance_id()] = true
	_used[obj.get_class()] = true
	if obj is PackedScene:
		var st := (obj as PackedScene).get_state()
		for i in st.get_node_count():
			var t := String(st.get_node_type(i))
			if not t.is_empty():
				_used[t] = true
			_walk(st.get_node_instance(i))
			for j in st.get_node_property_count(i):
				_walk(st.get_node_property_value(i, j))
		return
	if obj is Script:
		return  # scripts: the text scan
	if obj is Resource:
		for p: Dictionary in obj.get_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_STORAGE:
				_walk(obj.get(StringName(p["name"])))


## Adds the always-kept classes, the declared dependencies and every ancestor.
func _close(found: Dictionary) -> Dictionary:
	var todo: Array[String] = []
	for c: String in found:
		todo.append(c)
	for c in EDITOR_KEEP:
		todo.append(c)
		for sub in ClassDB.get_inheriters_from_class(c):
			todo.append(String(sub))
	todo.append_array(ENGINE_KEEP)
	var used := {}
	while not todo.is_empty():
		var c: String = todo.pop_back()
		if used.has(c) or not ClassDB.class_exists(c):
			continue
		used[c] = true
		var parent := String(ClassDB.get_parent_class(c))
		if not parent.is_empty():
			todo.append(parent)
		for dep: String in DEPENDENCIES.get(c, []):
			todo.append(dep)
	return used


func _disabled(used: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for c in ClassDB.get_class_list():
		if ClassDB.class_get_api_type(c) != ClassDB.API_CORE or used.has(String(c)):
			continue
		if not (ClassDB.is_parent_class(c, &"Resource") or ClassDB.is_parent_class(c, &"Node")):
			continue
		var parent := String(ClassDB.get_parent_class(c))
		if parent.is_empty() or used.has(parent):
			out.append(String(c))
	out.sort()
	return out


func _write(disabled: Array[String]) -> void:
	var doc := {
		"type": "build_profile",
		"generated_by": "tools/web_template/detect_classes.gd --write (WP9.9, docs/WEB.md)",
		"disabled_classes": disabled,
	}
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc, "\t", false) + "\n")
	f.close()
	print("detect_classes: wrote %s" % PROFILE_PATH)


## 0 when every used class is in the template, 1 otherwise (each missing one printed).
func _check(used: Dictionary) -> int:
	var missing: Array[String] = []
	var profile: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	if not (profile is Dictionary):
		printerr("detect_classes: cannot read %s" % PROFILE_PATH)
		return 1
	for c: String in (profile as Dictionary).get("disabled_classes", []):
		for u: String in used:
			if u == c or ClassDB.is_parent_class(u, c):
				missing.append("%s (profile disables %s)" % [u, c])
	if FileAccess.file_exists(REMOVED_PATH):
		for line in FileAccess.get_file_as_string(REMOVED_PATH).split("\n", false):
			var c := line.strip_edges()
			if not c.is_empty() and not c.begins_with("#") and used.has(c):
				missing.append("%s (not in the slim template: a disabled module or feature)" % c)
	for m in missing:
		printerr("detect_classes: the game uses %s" % m)
	if missing.is_empty():
		print("detect_classes: ok, the slim template has every class the game uses")
		return 0
	printerr("detect_classes: %d class(es) missing from the slim web template" % missing.size())
	return 1
