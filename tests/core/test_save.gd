extends WBTest
## The `Save` autoload's behaviour on a private file: loading a legacy (v1) save keeps
## settings and personal bests and writes it back as v2, round trips, corrupt files,
## a newer build's file (read-only), settings sanitized on load (a saved cockpit camera
## loads as hood while it is hidden, plan D11), a save's controls kept across the
## default change (plan D22, owner 2026-10-01), the first-run flags,
## autosave after a settings change (never while RUNNING), and the test-runner
## isolation (the autoload itself is in memory here). Spec: Save data; Controls →
## Settings and first run. WP8.1; docs/SAVE.md.

const SAVE_SCRIPT := preload("res://src/core/save.gd")

var dir: String
var path: String
var _nodes: Array[Node] = []


func before_each() -> void:
	dir = "user://test_save_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(dir)
	path = dir + "/save.json"
	Settings.restore_defaults()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	SaveStore.new(path).erase()
	DirAccess.remove_absolute(dir)
	Settings.restore_defaults()


## A second Save on the private file (not in the tree: no autoload wiring).
func _save() -> Node:
	var s: Node = SAVE_SCRIPT.new()
	_nodes.append(s)
	s.configure(path, true)
	return s


func _write_raw(text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func test_autoload_is_in_memory_under_the_test_runner() -> void:
	check(not Save.persistent, "tests never read or write the player's save")
	check(not Save.first_run_enabled, "and never see the first run unless they ask")
	check(not Save.chooser_pending() and not Save.warmup_pending())
	check(not Save.save_to_disk(), "save_to_disk writes nothing")


func test_legacy_v1_save_survives() -> void:
	_write_raw(preload("res://tests/core/test_save_migrations.gd").V1_TEXT)
	var s := _save()
	s.load_from_disk()
	eq(s.loaded_version, 1)
	eq(s.load_status, SaveStore.Status.OK)
	eq(s.best_score(&"journey"), 2010000, "the personal best")
	eq(s.journey_count(&"journey"), 2)
	eq(Settings.get_value(&"units"), &"mph", "settings applied, as StringNames")
	eq(Settings.get_value(&"camera_mode"), &"hood")
	eq(Settings.get_value(&"left_handed"), true)
	near(float(Settings.get_value(&"steer_sensitivity")), 1.35, 1e-9)
	check(not s.chooser_pending() and not s.warmup_pending(), "an existing player: no first run")
	# Written back as v2 at once.
	var disk: Dictionary = SaveStore.read_json(path)
	eq(int(disk["version"]), SaveMigrations.VERSION, "migrated file written")
	eq(int(disk["bests"]["journey"]), 2010000)
	check(FileAccess.file_exists(path + SaveStore.BAK_SUFFIX), "the v1 file kept as the backup")
	eq(int(SaveStore.read_json(path + SaveStore.BAK_SUFFIX)["version"]), 1)


func test_fresh_install_then_round_trip() -> void:
	var s := _save()
	s.load_from_disk()
	eq(s.load_status, SaveStore.Status.FRESH)
	check(s.chooser_pending() and s.warmup_pending(), "a fresh install: first run pending")
	check(not FileAccess.file_exists(path), "nothing written until something happens")
	Settings.set_value(&"throttle_mode", &"auto")   # not the default
	Settings.set_value(&"volume_music", 0.25)
	s.mark_chooser_done()
	check(s.submit_best_score(&"journey", 777), "a first best")
	check(not s.submit_best_score(&"journey", 700), "not a new best")
	s.record_journey(&"journey", 1200.0, 60000.0)
	Settings.restore_defaults()
	var t := _save()
	t.load_from_disk()
	eq(Settings.get_value(&"throttle_mode"), &"auto")
	near(float(Settings.get_value(&"volume_music")), 0.25, 1e-9)
	eq(t.best_score(&"journey"), 777)
	eq(t.journey_count(&"journey"), 1)
	near(t.journey_best_time_s(&"journey"), 1200.0, 1e-9)
	check(not t.chooser_pending(), "the chooser answered")
	check(t.warmup_pending(), "the warm-up still to come")
	t.mark_warmup_done()
	var u := _save()
	u.load_from_disk()
	check(not u.warmup_pending())


func test_corrupt_save_recovers_from_backup() -> void:
	var s := _save()
	s.load_from_disk()
	s.submit_best_score(&"journey", 100)
	s.submit_best_score(&"journey", 200)
	_write_raw("{\"version\": 2, \"bests\": {\"jou")
	var t := _save()
	t.load_from_disk()
	eq(t.load_status, SaveStore.Status.BACKUP)
	eq(t.best_score(&"journey"), 100, "the backup's best")
	eq(int(SaveStore.read_json(path)["bests"]["journey"]), 100, "the recovered document written back")


func test_unreadable_save_starts_fresh_without_first_run() -> void:
	_write_raw("garbage")
	var t := _save()
	t.load_from_disk()
	eq(t.load_status, SaveStore.Status.CORRUPT)
	eq(t.best_score(&"journey"), 0)
	check(not t.chooser_pending() and not t.warmup_pending(), "a player who had a save: no first run again")
	eq(Settings.get_value(&"units"), &"kmh", "default settings")


func test_newer_version_is_read_only() -> void:
	_write_raw(JSON.stringify({"version": SaveMigrations.VERSION + 3, "settings": {"units": "mph"},
		"bests": {"journey": 9}, "hovercars": {"n": 1}}))
	var s := _save()
	s.load_from_disk()
	check(s.read_only, "read-only")
	eq(Settings.get_value(&"units"), &"mph", "what this build knows is used")
	eq(s.best_score(&"journey"), 9)
	check(not s.save_to_disk(), "never overwritten")
	eq(int(SaveStore.read_json(path)["version"]), SaveMigrations.VERSION + 3)


func test_settings_are_sanitized_on_load() -> void:
	_write_raw(JSON.stringify({"version": 2, "settings": {
		"steering_mode": "joystick", "throttle_mode": 3, "haptics": "yes", "text_scale": "big",
		"volume_sfx": 0.5, "units": "mph", "future_key": [1, 2]}}))
	var s := _save()
	s.load_from_disk()
	eq(Settings.get_value(&"steering_mode"), &"drag", "unknown choice -> default")
	eq(Settings.get_value(&"throttle_mode"), Settings.DEFAULTS[&"throttle_mode"], "wrong type -> default")
	eq(Settings.get_value(&"haptics"), true)
	eq(Settings.get_value(&"text_scale"), 1.0)
	near(float(Settings.get_value(&"volume_sfx")), 0.5, 1e-9)
	eq(Settings.get_value(&"units"), &"mph")
	s.save_to_disk()
	var disk: Dictionary = SaveStore.read_json(path)
	eq((disk["settings"] as Dictionary).get("future_key"), [1.0, 2.0], "a newer build's key is kept")


func test_a_saved_cockpit_loads_as_hood() -> void:
	var ct := Tuning.load_default().camera
	check(not ct.cockpit_player_enabled, "the cockpit is hidden (owner, 2026-10-01)")
	_write_raw(JSON.stringify({"version": 2, "settings": {"camera_mode": "cockpit"}}))
	var s := _save()
	s.load_from_disk()
	eq(Settings.get_value(&"camera_mode"), StringName(ct.cockpit_fallback_mode), "the nearest mode players can pick")
	eq(Settings.get_value(&"camera_mode"), &"hood")
	_write_raw(JSON.stringify({"version": 2, "settings": {"camera_mode": "far"}}))
	_save().load_from_disk()
	eq(Settings.get_value(&"camera_mode"), &"far", "the other modes load as saved")


func test_an_existing_save_keeps_its_controls() -> void:
	# The new defaults (drag + manual, wheel look) are for fresh saves; a save written with
	# the old ones keeps them (settings are stored whole: CHOOSE LAYOUT or DEFAULTS in the
	# settings change them).
	eq(Settings.DEFAULTS[&"throttle_mode"], &"manual", "plan D22 (owner, 2026-10-01)")
	eq(Settings.DEFAULTS[&"drag_visual"], &"wheel", "plan D10 (owner, 2026-10-01)")
	eq(Settings.DEFAULTS[&"steering_mode"], &"drag")
	_write_raw(JSON.stringify({"version": 2, "settings": {"steering_mode": "drag", "throttle_mode": "auto",
		"drag_visual": "ring"}}))
	var s := _save()
	s.load_from_disk()
	eq(Settings.get_value(&"throttle_mode"), &"auto", "kept")
	eq(Settings.get_value(&"drag_visual"), &"ring", "kept")
	Settings.restore_defaults()
	eq(Settings.get_value(&"throttle_mode"), &"manual", "restore_defaults: the new defaults")
	eq(Settings.get_value(&"drag_visual"), &"wheel")
	_write_raw(JSON.stringify({"version": 2, "settings": {"units": "mph"}}))
	_save().load_from_disk()
	eq(Settings.get_value(&"throttle_mode"), &"manual", "a save without the key: the new default")
	eq(Settings.get_value(&"drag_visual"), &"wheel")


func test_load_applies_settings_live() -> void:
	_write_raw(JSON.stringify({"version": 2, "settings": {"reduced_motion": true}}))
	var seen: Array[StringName] = []
	var on_changed := func(k: StringName) -> void: seen.append(k)
	Events.settings_changed.connect(on_changed)
	var s := _save()
	s.load_from_disk()
	Events.settings_changed.disconnect(on_changed)
	eq(seen, [&"reduced_motion"] as Array[StringName], "only the changed key is announced")


func test_autosave_after_a_settings_change() -> void:
	var was := Game.state
	Game.state = Game.MENU   # not RUNNING (an earlier test may have left a run's state)
	var s := _save()
	tree.root.add_child(s)   # wires it to Events (its _ready loads the private file)
	s.configure(path, true)
	s.load_from_disk()
	var before: int = s.writes
	Settings.set_value(&"units", &"mph")
	check(s.dirty, "dirty at once")
	eq(s.writes, before, "written at the end of the frame, not inside set_value")
	await tree.process_frame
	eq(s.writes, before + 1, "written")
	var disk: Variant = SaveStore.read_json(path)
	if check(disk is Dictionary, "on disk"):
		eq(str(disk["settings"]["units"]), "mph")
	Game.state = was


func test_no_disk_write_while_running() -> void:
	var s := _save()
	tree.root.add_child(s)
	s.configure(path, true)
	s.load_from_disk()
	var was := Game.state
	Game.state = Game.RUNNING
	var before: int = s.writes
	Settings.set_value(&"camera_mode", &"hood")   # the C key mid-run
	await tree.process_frame
	eq(s.writes, before, "nothing written during gameplay")
	check(s.dirty)
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	eq(s.writes, before + 1, "written when the run leaves RUNNING")
	Game.state = was


func test_sections_for_progression() -> void:
	var s := _save()
	s.load_from_disk()
	var stats: Dictionary = s.section(SaveMigrations.KEY_STATS)
	stats["lifetime_threads"] = 12
	s.section("brand_new")["x"] = 1
	s.save_to_disk()
	var t := _save()
	t.load_from_disk()
	eq(int(t.section(SaveMigrations.KEY_STATS)["lifetime_threads"]), 12)
	eq(int(t.section("brand_new")["x"]), 1, "unknown sections survive")


func test_reset_fresh() -> void:
	var s := _save()
	s.first_run_enabled = true
	s.load_from_disk()
	s.mark_chooser_done()
	Settings.set_value(&"units", &"mph")
	s.reset_fresh()
	check(s.chooser_pending(), "the first run again")
	eq(Settings.get_value(&"units"), &"kmh", "default settings")
