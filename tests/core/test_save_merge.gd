extends WBTest
## Cloud sync's merge rules (SaveMerge, WP N11; docs/SAVE.md → Cloud sync): every section's
## rule, what goes up (device-only settings and sections stay home), the modes of the
## conflict chooser, JSON round trips (numbers come back as floats), idempotence, and that
## a merge never loses progress from either side.


static func _doc(xp: int, extra: Dictionary = {}) -> Dictionary:
	var d := SaveMigrations.fresh()
	d["settings"] = {"steering_mode": "drag", "throttle_mode": "manual", "units": "kmh",
		"quality_tier": "medium", "text_scale": 1.0, "volume_music": 1.0, "camera_mode": "chase",
		"future_key": "kept"}
	d["stats"] = {"xp": xp, "runs": 3, "threads": 5, "best_leg": 2, "coast": false,
		"daily_streak": 1, "daily_best_streak": 2, "daily_last_day": 20000, "backfilled": true}
	d["bests"] = {"journey": 1000, "daily": 400}
	d["journeys"] = {"journey": {"count": 1, "best_time_s": 1900.5, "best_distance_m": 60000.0}}
	d["unlocks"] = {"car/falcon_gt": 0, "paint/sunset": 2}
	d["garage"] = {"car": "falcon_gt", "looks": {"falcon_gt": {"paint": "sunset", "rim": "stock"}}}
	d["achievements"] = {"unlocked": {"first_pass": 20000}, "progress": {"passes": 40},
		"mirrored": {"first_pass": true}}
	d["daily"] = {"ghosts": {"2026-09-30": {"score": 5}}}
	d["first_run"] = {"chooser_done": true, "warmup_done": false}
	d["sync"] = {"garage_at": 100, "settings_at": 50}
	d.merge(extra, true)
	return d


## The document after a trip through JSON (what the server hands back).
static func _json(d: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(d)) as Dictionary


func _same(a: Variant, b: Variant, what: String) -> void:
	eq(SaveMerge.canonical(a), SaveMerge.canonical(b), what)


func test_to_cloud_keeps_device_things_home() -> void:
	var c := SaveMerge.to_cloud(_doc(500))
	check(not c.has("daily"), "Daily ghosts are files on the device")
	check(not c.has("dev"))
	eq((c["settings"] as Dictionary).keys().size(), 3, "only synced settings: throttle, units, camera")
	for k: String in ["steering_mode", "quality_tier", "text_scale", "volume_music", "future_key"]:
		check(not (c["settings"] as Dictionary).has(k), "%s stays on the device" % k)
	check(not (c["achievements"] as Dictionary).has("mirrored"), "platform mirror state stays")
	_same(c["sync"], {"garage_at": 100, "settings_at": 50}, "stamps go up")
	_same(c["stats"], _doc(500)["stats"], "progress goes up whole")
	for k: String in SaveMerge.SYNCED_SETTINGS:
		check(Settings.DEFAULTS.has(StringName(k)), "%s is a real setting" % k)


func test_progress_sections_merge_to_the_best_of_both() -> void:
	var local := _doc(500)
	var cloud := _doc(900)
	(cloud["stats"] as Dictionary)["runs"] = 2
	(cloud["stats"] as Dictionary)["coast"] = true
	(cloud["stats"] as Dictionary)["best_leg"] = 5
	cloud["bests"] = {"journey": 800, "daily": 900, "loop": 70}
	cloud["journeys"] = {"journey": {"count": 4, "best_time_s": 2100.0, "best_distance_m": 59000.0},
		"daily": {"count": 1, "best_time_s": 1500.0, "best_distance_m": 61000.0}}
	cloud["unlocks"] = {"car/falcon_gt": 0, "paint/sunset": 1, "car/night_viper": 9}
	cloud["achievements"] = {"unlocked": {"first_pass": 19990, "coast": 20001}, "progress": {"passes": 10, "threads": 3}}
	cloud["first_run"] = {"chooser_done": false, "warmup_done": true}
	var m := SaveMerge.merge(local, SaveMerge.to_cloud(_json(cloud)))
	_same(m["stats"], {"xp": 900, "runs": 3, "threads": 5, "best_leg": 5, "coast": true,
		"daily_streak": 1, "daily_best_streak": 2, "daily_last_day": 20000, "backfilled": true}, "stats: max / or")
	_same(m["bests"], {"journey": 1000, "daily": 900, "loop": 70}, "bests: max")
	_same(m["journeys"], {"journey": {"count": 4, "best_time_s": 1900.5, "best_distance_m": 59000},
		"daily": {"count": 1, "best_time_s": 1500, "best_distance_m": 61000}}, "journeys: count max, bests min")
	_same(m["unlocks"], {"car/falcon_gt": 0, "paint/sunset": 1, "car/night_viper": 9}, "unlocks: union, earliest")
	_same(m["achievements"], {"unlocked": {"first_pass": 19990, "coast": 20001},
		"progress": {"passes": 40, "threads": 3}, "mirrored": {"first_pass": true}}, "achievements")
	_same(m["first_run"], {"chooser_done": true, "warmup_done": true}, "first run: done anywhere")
	_same(m["daily"], local["daily"], "daily stays the device's")
	check(m["bests"]["daily"] is int, "whole JSON numbers come back as ints")
	check(m["stats"]["xp"] is int)


func test_garage_latest_wins_and_settings_follow_the_device() -> void:
	var local := _doc(1)
	var cloud := _doc(1)
	cloud["garage"] = {"car": "night_viper", "looks": {"night_viper": {"paint": "teal", "rim": "mesh"}}}
	(cloud["sync"] as Dictionary)["garage_at"] = 200
	(cloud["settings"] as Dictionary)["units"] = "mph"
	(cloud["settings"] as Dictionary)["quality_tier"] = "low"
	var m := SaveMerge.merge(local, SaveMerge.to_cloud(cloud))
	eq(m["garage"]["car"], "night_viper", "the newer garage choice wins")
	eq(SaveMerge.stamp(m, "garage_at"), 200, "and its stamp")
	eq(m["settings"]["units"], "kmh", "a device that changed settings keeps them")
	# Older cloud garage: the device's stays.
	(local["sync"] as Dictionary)["garage_at"] = 300
	m = SaveMerge.merge(local, SaveMerge.to_cloud(cloud))
	eq(m["garage"]["car"], "falcon_gt")
	# A fresh device (settings never touched) takes the synced settings, never the device ones.
	(local["sync"] as Dictionary)["settings_at"] = 0
	m = SaveMerge.merge(local, SaveMerge.to_cloud(cloud))
	eq(m["settings"]["units"], "mph")
	eq(m["settings"]["quality_tier"], "medium", "graphics tier is the device's")
	eq(m["settings"]["future_key"], "kept", "unknown local keys kept")


func test_keep_local_and_use_cloud_modes() -> void:
	var local := _doc(500)
	var cloud := _doc(900)
	cloud["garage"] = {"car": "night_viper"}
	(cloud["sync"] as Dictionary)["garage_at"] = 999
	(cloud["settings"] as Dictionary)["units"] = "mph"
	(local["sync"] as Dictionary)["settings_at"] = 0
	var keep := SaveMerge.merge(local, SaveMerge.to_cloud(cloud), SaveMerge.Mode.KEEP_LOCAL)
	eq(keep["garage"]["car"], "falcon_gt", "keep: this device's car")
	eq(keep["settings"]["units"], "kmh", "keep: this device's settings")
	eq(keep["stats"]["xp"], 900, "keep: progress still merged (nothing lost)")
	var use := SaveMerge.merge(local, SaveMerge.to_cloud(_json(cloud)), SaveMerge.Mode.USE_CLOUD)
	eq(use["garage"]["car"], "night_viper", "cloud: its car")
	eq(use["stats"]["xp"], 900)
	eq(use["settings"]["units"], "mph", "cloud: its synced settings")
	eq(use["settings"]["quality_tier"], "medium", "device settings stay")
	_same(use["daily"], local["daily"], "device sections stay")
	_same(use["achievements"]["mirrored"], local["achievements"]["mirrored"], "mirror state stays")
	# The cloud's progress replaces the device's: a best only the device had is gone (a
	# backup keeps it).
	var only_local := _doc(500, {"bests": {"journey": 5000}})
	var c2 := _doc(10, {"bests": {}})
	eq(SaveMerge.merge(only_local, SaveMerge.to_cloud(c2), SaveMerge.Mode.USE_CLOUD)["bests"], {})


func test_empty_cloud_and_idempotence() -> void:
	var local := _doc(500)
	_same(SaveMerge.merge(local, {}), local, "no cloud save yet: unchanged")
	var cloud := SaveMerge.to_cloud(_json(_doc(900)))
	var once := SaveMerge.merge(local, cloud)
	var twice := SaveMerge.merge(once, cloud)
	_same(twice, once, "merging the same cloud again changes nothing")
	check(SaveMerge.same_cloud(once, SaveMerge.merge(once, SaveMerge.to_cloud(_json(once)))), "a round trip is stable")
	check(SaveMerge.same_cloud(SaveMerge.to_cloud(_json(once)), once), "a cloud copy compares with its local")
	check(not SaveMerge.same_cloud(local, once))
	# Arguments untouched.
	eq(local["stats"]["xp"], 500)


func test_never_loses_progress_either_way() -> void:
	var rng := Rng.new(1234)
	for i in 50:
		var a := _doc(rng.int_range(0, 100000))
		var b := _doc(rng.int_range(0, 100000))
		(a["bests"] as Dictionary)["journey"] = rng.int_range(0, 9999)
		(b["bests"] as Dictionary)["journey"] = rng.int_range(0, 9999)
		(b["unlocks"] as Dictionary)["rim/mesh_%d" % i] = rng.int_range(0, 20)
		var m := SaveMerge.merge(a, SaveMerge.to_cloud(_json(b)))
		var n := SaveMerge.merge(b, SaveMerge.to_cloud(_json(a)))
		for side: Dictionary in [a, b]:
			check(int(m["stats"]["xp"]) >= int(side["stats"]["xp"]), "xp kept")
			check(int(m["bests"]["journey"]) >= int(side["bests"]["journey"]), "best kept")
			for k: Variant in side["unlocks"]:
				check((m["unlocks"] as Dictionary).has(k), "unlock %s kept" % k)
		_same(m["stats"], n["stats"], "symmetric for progress")
		_same(m["bests"], n["bests"], "symmetric for bests")


func test_unknown_sections_and_summary() -> void:
	var local := _doc(1)
	var cloud := SaveMerge.to_cloud(_doc(1, {"liveries": {"owned": ["x"]}}))
	var m := SaveMerge.merge(local, cloud)
	_same(m["liveries"], {"owned": ["x"]}, "a newer build's section rides along")
	local["liveries"] = {"owned": ["y"]}
	_same(SaveMerge.merge(local, cloud)["liveries"], {"owned": ["y"]}, "the device's copy first")
	eq(SaveMerge.summary(_doc(36123)), {"xp": 36123, "runs": 3})
	eq(SaveMerge.summary({}), {"xp": 0, "runs": 0})
	eq(SaveMerge.stamp({"sync": {"garage_at": "x"}}, "garage_at"), 0)
