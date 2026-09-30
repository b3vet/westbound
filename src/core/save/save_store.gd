class_name SaveStore
extends RefCounted
## One JSON document file with atomic writes, a backup and corrupt-file recovery.
## Spec: Save data ("A local, versioned save in user://"). WP8.1; docs/SAVE.md → Files.
##
##   var store := SaveStore.new("user://save.json")
##   var doc := store.load_doc()      # {} when fresh or unrecoverable; see `status`
##   store.save_doc(doc)              # atomic: never leaves a half-written file behind
##
## Files next to `path`:
##   <path>          the document (JSON object)
##   <path>.tmp      a write in progress: written, flushed, closed and read back, then
##                   renamed over <path> (a crash at any point keeps the old <path>)
##   <path>.bak      the previous good <path>, copied before each replace
##   <path>.corrupt  a <path> that failed to parse, moved aside at load (kept for a
##                   bug report; the next corrupt file replaces it)
## Load order: <path>, else <path>.bak (status BACKUP), else {} (FRESH when neither
## exists, CORRUPT when something existed but nothing parsed). Never pushes an error:
## a damaged save is a warning and the game goes on with what it could recover.
##
## Web: user:// is Godot's IndexedDB-backed /userfs. Closing a file opened for writing
## flags the file system for a sync, and the engine syncs it on its next main-loop
## iteration, so every write here closes its file explicitly.

enum Status { FRESH, OK, BACKUP, CORRUPT }

const TMP_SUFFIX := ".tmp"
const BAK_SUFFIX := ".bak"
const CORRUPT_SUFFIX := ".corrupt"

var path: String
## What the last load_doc() found.
var status: Status = Status.FRESH
## The last problem in words ("" = none), for the dev HUD and tests.
var last_error: String = ""
## Writes done by this store (tests).
var writes: int = 0

## <path> holds a document this store read or wrote (so it may become the backup).
var _main_good: bool = false


func _init(file_path: String) -> void:
	path = file_path


func backup_path() -> String:
	return path + BAK_SUFFIX


func tmp_path() -> String:
	return path + TMP_SUFFIX


func corrupt_path() -> String:
	return path + CORRUPT_SUFFIX


## Reads the document (see the load order above). Returns {} when there is nothing to
## recover; `status` says which case it was.
func load_doc() -> Dictionary:
	last_error = ""
	_main_good = false
	var main: Variant = read_json(path)
	if main is Dictionary:
		status = Status.OK
		_main_good = true
		return main
	var main_existed := FileAccess.file_exists(path)
	if main_existed:
		last_error = "%s is not a JSON object" % path.get_file()
		push_warning("SaveStore: %s; trying the backup" % last_error)
		_quarantine()
	var bak: Variant = read_json(backup_path())
	if bak is Dictionary:
		status = Status.BACKUP
		if last_error.is_empty():
			last_error = "%s was missing" % path.get_file()
		return bak
	if main_existed or FileAccess.file_exists(backup_path()):
		status = Status.CORRUPT
		last_error = "no readable save (%s)" % path.get_file()
		push_warning("SaveStore: %s; starting fresh" % last_error)
		return {}
	status = Status.FRESH
	return {}


## Writes `doc` atomically (temp file, read back, backup, rename). Returns false (and
## sets last_error) when the file system refused; the old file is then untouched.
func save_doc(doc: Dictionary) -> bool:
	var text := JSON.stringify(doc, "\t")
	if not _ensure_dir():
		return false
	var tmp := tmp_path()
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return _fail("cannot write %s (%s)" % [tmp.get_file(), error_string(FileAccess.get_open_error())])
	f.store_string(text)
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK:
		return _fail("write failed (%s)" % error_string(werr))
	# Read it back: a full disk can truncate a write without an error on some platforms.
	if FileAccess.get_file_as_string(tmp) != text:
		DirAccess.remove_absolute(tmp)
		return _fail("%s did not read back" % tmp.get_file())
	if _main_good and FileAccess.file_exists(path):
		var cerr := DirAccess.copy_absolute(path, backup_path())
		if cerr != OK:
			push_warning("SaveStore: no backup this time (%s)" % error_string(cerr))
	var rerr := DirAccess.rename_absolute(tmp, path)
	if rerr != OK:
		# Some platforms refuse to rename over an existing file: the backup holds it now.
		DirAccess.remove_absolute(path)
		rerr = DirAccess.rename_absolute(tmp, path)
	if rerr != OK:
		return _fail("cannot replace %s (%s)" % [path.get_file(), error_string(rerr)])
	_main_good = true
	writes += 1
	last_error = ""
	return true


## Deletes the document and its companions (tests; a "reset save" tool).
func erase() -> void:
	for p: String in [path, tmp_path(), backup_path(), corrupt_path()]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_main_good = false
	status = Status.FRESH


## The JSON object in `file` (null when missing, unreadable, not UTF-8, not JSON or
## not an object). Quiet: parse failures are expected on damaged files.
static func read_json(file: String) -> Variant:
	if not FileAccess.file_exists(file):
		return null
	var bytes := FileAccess.get_file_as_bytes(file)
	if bytes.is_empty() or not is_utf8(bytes):
		return null
	var j := JSON.new()
	if j.parse(bytes.get_string_from_utf8()) != OK:
		return null
	return j.data if j.data is Dictionary else null


## True when `bytes` is well-formed UTF-8 without NUL bytes (decoding anything else
## would log an engine error).
static func is_utf8(bytes: PackedByteArray) -> bool:
	var i := 0
	var n := bytes.size()
	while i < n:
		var b := bytes[i]
		var extra := 0
		if b == 0:
			return false
		elif b < 0x80:
			extra = 0
		elif b >= 0xC2 and b <= 0xDF:
			extra = 1
		elif b >= 0xE0 and b <= 0xEF:
			extra = 2
		elif b >= 0xF0 and b <= 0xF4:
			extra = 3
		else:
			return false
		if i + extra >= n and extra > 0:
			return false
		for k in extra:
			var c := bytes[i + 1 + k]
			if c < 0x80 or c > 0xBF:
				return false
		# No overlong forms, no surrogates, nothing past U+10FFFF.
		if extra > 0:
			var c1 := bytes[i + 1]
			if (b == 0xE0 and c1 < 0xA0) or (b == 0xED and c1 > 0x9F) \
					or (b == 0xF0 and c1 < 0x90) or (b == 0xF4 and c1 > 0x8F):
				return false
		i += 1 + extra
	return true


func _quarantine() -> void:
	var dest := corrupt_path()
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(path, dest) != OK:
		DirAccess.remove_absolute(path)


func _ensure_dir() -> bool:
	var dir := path.get_base_dir()
	if dir.is_empty() or dir.ends_with("://") or DirAccess.dir_exists_absolute(dir):
		return true
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return _fail("cannot create %s (%s)" % [dir, error_string(err)])
	return true


func _fail(why: String) -> bool:
	last_error = why
	push_warning("SaveStore: %s" % why)
	return false
