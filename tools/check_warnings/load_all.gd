extends SceneTree
## Loads every .gd under the given roots; exits 1 if any fails to compile.
## Run with warnings raised to errors (tools/check_warnings.sh).

const ROOTS := ["res://src", "res://tests", "res://tools"]
const SKIP_DIRS := ["out", "fixtures", "node_modules", "lint_rules"]


func _initialize() -> void:
	var files := PackedStringArray()
	for r: String in ROOTS:
		_collect(r, files)
	var bad := 0
	for f in files:
		var s: Script = ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
		if s == null or not s.can_instantiate():
			bad += 1
			print("WARN-AS-ERROR  %s" % f)
	print("check_warnings: %d scripts, %d with warnings/errors" % [files.size(), bad])
	quit(1 if bad > 0 else 0)


func _collect(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		if not SKIP_DIRS.has(sub):
			_collect(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
