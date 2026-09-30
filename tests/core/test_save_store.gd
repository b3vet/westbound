extends WBTest
## SaveStore: atomic writes, the backup, corrupt-file recovery. Spec: Save data. WP8.1;
## docs/SAVE.md → Files. Every case runs in its own user:// folder (the process id keeps
## parallel test runs apart) and never touches the game's save.

var dir: String
var path: String


func before_each() -> void:
	dir = "user://test_save_store_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(dir)
	path = dir + "/save.json"


func after_each() -> void:
	SaveStore.new(path).erase()
	DirAccess.remove_absolute(dir)


func _write_raw(file: String, text: String) -> void:
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _write_bytes(file: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func test_round_trip() -> void:
	var s := SaveStore.new(path)
	var doc := {"version": 2, "bests": {"journey": 123456}, "settings": {"units": "mph", "haptics": false}}
	check(s.save_doc(doc), "written")
	check(FileAccess.file_exists(path), "the file exists")
	check(not FileAccess.file_exists(s.tmp_path()), "no temp file left behind")
	var t := SaveStore.new(path)
	var back := t.load_doc()
	eq(t.status, SaveStore.Status.OK)
	eq(int(back["bests"]["journey"]), 123456)
	eq(str(back["settings"]["units"]), "mph")
	eq(back["settings"]["haptics"], false)


func test_fresh_when_nothing_exists() -> void:
	var s := SaveStore.new(path)
	eq(s.load_doc(), {})
	eq(s.status, SaveStore.Status.FRESH)


func test_second_write_keeps_the_first_as_backup() -> void:
	var s := SaveStore.new(path)
	s.save_doc({"n": 1})
	check(not FileAccess.file_exists(s.backup_path()), "no backup before there was a good file")
	s.save_doc({"n": 2})
	eq(int(SaveStore.read_json(s.backup_path())["n"]), 1, "the backup is the previous document")
	eq(int(SaveStore.read_json(path)["n"]), 2)
	# A store that loaded the file backs it up on its first write too.
	var t := SaveStore.new(path)
	t.load_doc()
	t.save_doc({"n": 3})
	eq(int(SaveStore.read_json(t.backup_path())["n"]), 2)


func test_corrupt_file_falls_back_to_backup() -> void:
	var s := SaveStore.new(path)
	s.save_doc({"n": 1})
	s.save_doc({"n": 2})
	_write_raw(path, "{\"n\": 3, \"bests\": {")   # a write cut short
	var t := SaveStore.new(path)
	var doc := t.load_doc()
	eq(t.status, SaveStore.Status.BACKUP)
	eq(int(doc["n"]), 1, "the backup (one write behind)")
	check(FileAccess.file_exists(t.corrupt_path()), "the damaged file is kept aside")
	check(not FileAccess.file_exists(path), "and moved out of the way")
	ne(t.last_error, "")
	# The next write does not back up the damaged file over the good backup.
	check(t.save_doc(doc))
	eq(int(SaveStore.read_json(t.backup_path())["n"]), 1, "the backup survives")


func test_every_kind_of_damage_loads_quietly() -> void:
	var cases: Array[PackedByteArray] = [
		"".to_utf8_buffer(),
		"not json at all".to_utf8_buffer(),
		"[1, 2, 3]".to_utf8_buffer(),
		"42".to_utf8_buffer(),
		PackedByteArray([0, 0, 0, 0, 0, 0]),                  # zero-filled (a lost write)
		PackedByteArray([0xFF, 0xFE, 0x7B, 0x80, 0xC3, 0x28]),  # binary garbage, bad UTF-8
		PackedByteArray([0x7B, 0x22, 0xED, 0xA0, 0x80, 0x22]),  # a UTF-8 surrogate
	]
	for bytes in cases:
		_write_bytes(path, bytes)
		var t := SaveStore.new(path)
		eq(t.load_doc(), {}, "damage %s gives nothing" % bytes.hex_encode())
		eq(t.status, SaveStore.Status.CORRUPT, "and says so")
		t.erase()


func test_missing_main_with_backup() -> void:
	var s := SaveStore.new(path)
	s.save_doc({"n": 1})
	s.save_doc({"n": 2})
	DirAccess.remove_absolute(path)
	var t := SaveStore.new(path)
	eq(int(t.load_doc()["n"]), 1)
	eq(t.status, SaveStore.Status.BACKUP)


func test_stale_temp_file_is_ignored_and_replaced() -> void:
	var s := SaveStore.new(path)
	s.save_doc({"n": 1})
	_write_raw(s.tmp_path(), "{\"n\": 99")   # a crash mid-write left this
	var t := SaveStore.new(path)
	eq(int(t.load_doc()["n"]), 1, "the temp file is never read")
	check(t.save_doc({"n": 2}))
	check(not FileAccess.file_exists(t.tmp_path()))
	eq(int(SaveStore.read_json(path)["n"]), 2)


func test_creates_its_folder() -> void:
	var nested := dir + "/deeper/save.json"
	var s := SaveStore.new(nested)
	check(s.save_doc({"n": 1}), "wrote into a folder that did not exist")
	eq(int(SaveStore.read_json(nested)["n"]), 1)
	s.erase()
	DirAccess.remove_absolute(dir + "/deeper")


func test_utf8_check() -> void:
	check(SaveStore.is_utf8("plain {\"a\": 1}".to_utf8_buffer()))
	check(SaveStore.is_utf8("Ünïcødé · 日本 🚗".to_utf8_buffer()), "multi-byte text is fine")
	check(not SaveStore.is_utf8(PackedByteArray([0x41, 0x00])), "NUL")
	check(not SaveStore.is_utf8(PackedByteArray([0xC3])), "cut short")
	check(not SaveStore.is_utf8(PackedByteArray([0xC0, 0x80])), "overlong")
	check(not SaveStore.is_utf8(PackedByteArray([0xF5, 0x80, 0x80, 0x80])), "past U+10FFFF")


func test_non_ascii_round_trip() -> void:
	var s := SaveStore.new(path)
	s.save_doc({"name": "Ünïcødé · 🚗"})
	eq(str(SaveStore.new(path).load_doc()["name"]), "Ünïcødé · 🚗")
