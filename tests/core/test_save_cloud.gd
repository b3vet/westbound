extends WBTest
## Save's side of cloud sync (WP N11; docs/SAVE.md → Cloud sync): the `sync` stamps a
## settings change and a garage change leave, apply_cloud() putting a merged document in
## place (backup first, in place so live sections stay live, settings applied, `loaded`
## fired) and refusing mid-run or on a read-only save, and the backup file next to the save.

const SAVE_SCRIPT := preload("res://src/core/save.gd")

var dir: String
var path: String
var _nodes: Array[Node] = []
var _saved_state: StringName
var now: int = 1790000000


func before_each() -> void:
	dir = "user://test_save_cloud_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(dir)
	path = dir + "/save.json"
	Settings.restore_defaults()
	Save.reset_fresh()
	Save.unix_clock = func() -> float: return float(now)
	_saved_state = Game.state
	Game.state = Game.RESULTS   # not mid-run, whatever an earlier test left
	Save.read_only = false


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	SaveStore.new(path).erase()
	SaveStore.new(dir + "/save" + SAVE_SCRIPT.CLOUD_BACKUP_SUFFIX).erase()
	DirAccess.remove_absolute(dir)
	Game.state = _saved_state
	Save.unix_clock = Callable()
	Save.reset_fresh()
	Settings.restore_defaults()


func test_settings_change_stamps_settings_at() -> void:
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_SETTINGS_AT), 0, "fresh: never")
	Settings.set_value(&"units", &"mph")
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_SETTINGS_AT), now)
	now += 10
	Save.load_from_disk()   # loading never stamps (in memory here: a fresh document)
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_SETTINGS_AT), 0)


func test_garage_change_stamps_garage_at_on_write() -> void:
	Save.save_to_disk()
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_GARAGE_AT), 0, "nothing chosen")
	Save.section("garage")["car"] = "night_viper"
	now += 5
	Save.save_to_disk()
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_GARAGE_AT), now)
	var first := now
	now += 5
	Save.save_to_disk()
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_GARAGE_AT), first, "no change, no new stamp")


func test_apply_cloud_in_place_with_backup() -> void:
	var daily := Save.section("daily")
	daily["ghosts"] = {"2026-09-30": {"score": 1}}
	Save.section("bests")["journey"] = 100
	var doc := Save.snapshot()
	doc["bests"] = {"journey": 500}
	(doc["settings"] as Dictionary)["units"] = "mph"
	doc["daily"] = {"ghosts": {"2026-10-01": {"score": 2}}}
	var fired := [0]
	var on_loaded := func() -> void: fired[0] += 1
	Save.loaded.connect(on_loaded)
	check(Save.can_apply_cloud())
	check(Save.apply_cloud(doc))
	Save.loaded.disconnect(on_loaded)
	eq(fired[0], 1, "loaded fires: achievements and garage read it again")
	eq(Save.best_score(&"journey"), 500)
	eq(Settings.get_value(&"units"), &"mph", "settings applied live")
	check(Save.section("daily") == daily, "the same dictionary: a holder of the section stays live")
	check((daily["ghosts"] as Dictionary).has("2026-10-01"))
	eq(int((Save.cloud_backup["bests"] as Dictionary)["journey"]), 100, "the backup is the old document")
	eq(SaveMerge.stamp(Save.data, SaveMerge.SYNC_SETTINGS_AT), 0, "applying is not a local change")


func test_apply_cloud_waits_for_the_run_and_respects_read_only() -> void:
	Game.state = Game.RUNNING
	check(not Save.can_apply_cloud())
	check(not Save.apply_cloud(Save.snapshot()), "never mid-run")
	Game.state = Game.RESULTS
	check(Save.apply_cloud(Save.snapshot()))
	Save.read_only = true
	check(not Save.can_apply_cloud(), "a newer build's save is never replaced")
	Save.read_only = false


func test_backup_file_next_to_the_save() -> void:
	var s: Node = SAVE_SCRIPT.new()
	_nodes.append(s)
	s.configure(path, true)
	s.load_from_disk()
	s.section("bests")["journey"] = 42
	s.save_to_disk()
	var doc: Dictionary = s.snapshot()
	doc["bests"] = {"journey": 900}
	check(s.apply_cloud(doc))
	eq(s.cloud_backup_path(), dir + "/save_before_cloud.json")
	var backup := SaveStore.new(s.cloud_backup_path()).load_doc()
	eq(int((backup["bests"] as Dictionary)["journey"]), 42, "the old document on disk")
	var main := SaveStore.new(path).load_doc()
	eq(int((main["bests"] as Dictionary)["journey"]), 900, "the new one written")
	eq(Save.cloud_backup_path(), "user://save_before_cloud.json")
