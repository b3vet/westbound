extends WBTest
## The save document's migration chain (v0 -> v1 -> v2) and normalize(). Spec: Save data
## ("versioned"). WP8.1; docs/SAVE.md → Migrations. The fixtures are the shapes older
## builds really wrote (v1: WP0.1-WP7, including the web build's players).

## What the WP4-WP7 builds wrote (Save.save_to_disk: JSON.stringify of the document with
## Settings.to_dict(); StringName values become strings, every number a JSON number).
const V1_TEXT := """{"bests":{"journey":2010000,"daily":48200.0},"journeys":{"journey":{"best_distance_m":61234.5,"best_time_s":1843.25,"count":2}},"settings":{"audio_muted":false,"battery_saver":true,"camera_mode":"hood","controls_scale":1.2,"drag_visual":"wheel","haptics":false,"left_handed":true,"quality_tier":"low","reduced_motion":true,"steer_curve":1.0,"steer_dead_zone":1.0,"steer_sensitivity":1.35,"steering_mode":"drag","text_scale":1.25,"throttle_mode":"manual","units":"mph","volume_engine":1.0,"volume_master":0.75,"volume_music":0.5,"volume_sfx":1.0,"volume_ui":1.0},"version":1}"""
## The M0 skeleton's shape (no version key).
const V0_TEXT := """{"settings":{"units":"mph"},"bests":{"journey":5000}}"""


func _parse(text: String) -> Dictionary:
	var j := JSON.new()
	check(j.parse(text) == OK, "fixture parses")
	return j.data


func test_fresh_document_has_every_section() -> void:
	var doc := SaveMigrations.fresh()
	eq(int(doc["version"]), SaveMigrations.VERSION)
	for key in SaveMigrations.OBJECT_SECTIONS:
		check(doc[key] is Dictionary, "section %s" % key)
	eq(doc["first_run"]["chooser_done"], false, "a fresh install sees the chooser")
	eq(doc["first_run"]["warmup_done"], false, "and the warm-up")


func test_version_of() -> void:
	eq(SaveMigrations.version_of({}), 0, "no key: v0")
	eq(SaveMigrations.version_of({"version": 1}), 1)
	eq(SaveMigrations.version_of({"version": 2.0}), 2, "JSON numbers are floats")
	eq(SaveMigrations.version_of({"version": "2"}), -1, "a string is not a version")
	eq(SaveMigrations.version_of({"version": 1.5}), -1)
	eq(SaveMigrations.version_of({"version": -3}), -1)


func test_v1_to_v2_keeps_settings_bests_and_journeys() -> void:
	var doc := SaveMigrations.migrate(_parse(V1_TEXT))
	eq(int(doc["version"]), 2)
	eq(doc["bests"]["journey"], 2010000, "the personal best survives, as an int")
	eq(doc["bests"]["daily"], 48200, "float bests become ints")
	eq(int(doc["journeys"]["journey"]["count"]), 2)
	near(float(doc["journeys"]["journey"]["best_time_s"]), 1843.25, 1e-9)
	eq(str(doc["settings"]["camera_mode"]), "hood")
	eq(str(doc["settings"]["units"]), "mph")
	eq(doc["first_run"]["chooser_done"], true, "an existing player skips the chooser")
	eq(doc["first_run"]["warmup_done"], true, "and the warm-up")
	for key: String in ["stats", "unlocks", "daily"]:
		check(doc[key] is Dictionary and (doc[key] as Dictionary).is_empty(), "new empty section %s" % key)


func test_v0_to_v2() -> void:
	var doc := SaveMigrations.migrate(_parse(V0_TEXT))
	eq(int(doc["version"]), SaveMigrations.VERSION)
	eq(doc["bests"]["journey"], 5000)
	eq(str(doc["settings"]["units"]), "mph")
	eq(doc["first_run"]["chooser_done"], true)


func test_v1_bad_bests_are_dropped() -> void:
	var doc := SaveMigrations.migrate({"version": 1, "bests": {"journey": "lots", "daily": -5, "loop": 7.9}})
	check(not (doc["bests"] as Dictionary).has("journey"), "not a number: dropped")
	eq(doc["bests"]["daily"], 0, "negative: clamped")
	eq(doc["bests"]["loop"], 7)
	var doc2 := SaveMigrations.migrate({"version": 1, "bests": [1, 2]})
	check(doc2["bests"] is Dictionary and (doc2["bests"] as Dictionary).is_empty(), "wrong type: empty")


func test_unknown_keys_ride_along() -> void:
	var doc := SaveMigrations.migrate({"version": 1, "future_thing": {"a": 1}})
	eq(int(doc["future_thing"]["a"]), 1)


func test_normalize_repairs_shapes() -> void:
	var doc := SaveMigrations.migrate({"version": 2, "settings": "oops", "first_run": {"chooser_done": 1},
		"journeys": {"journey": 3, "daily": {"count": 1}}, "stats": null})
	check(doc["settings"] is Dictionary)
	eq(doc["first_run"]["chooser_done"], false, "a non-bool flag is not done")
	eq(doc["first_run"]["warmup_done"], false)
	check(not (doc["journeys"] as Dictionary).has("journey"), "a broken journey entry is dropped")
	eq(int(doc["journeys"]["daily"]["count"]), 1)
	check(doc["stats"] is Dictionary)


func test_newer_or_invalid_versions_are_left_alone() -> void:
	var newer := {"version": SaveMigrations.VERSION + 1, "x": 1}
	eq(SaveMigrations.migrate(newer.duplicate()), newer, "a newer build's document is untouched")
	var bad := {"version": "abc"}
	eq(SaveMigrations.migrate(bad.duplicate()), bad)


func test_every_version_below_current_migrates() -> void:
	for v in SaveMigrations.VERSION:
		var doc := {"settings": {}}
		if v > 0:
			doc["version"] = v
		var out := SaveMigrations.migrate(doc)
		eq(int(out["version"]), SaveMigrations.VERSION, "v%d reaches the current version" % v)
