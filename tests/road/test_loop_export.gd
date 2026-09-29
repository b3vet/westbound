extends WBTest
## The loop's road-space export (N3.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop
## map (road-space JSON with a version and a content hash, shared by client and server;
## hash check on join), Rules for the server code 5; docs/PROTOCOL.md (map_hash = SHA-256
## of the road-space file). docs/LOOP_MAP.md → Road-space file.
##
## Regenerate the committed files after changing the loop:
##   tools/godot.sh --headless --path . res://src/road/loop/dev/loop_editor.tscn -- --export

const CLIENT_JSON := "res://data/maps/loop_v1.json"
const SERVER_JSON := "res://westbound-server/data/maps/loop_v1.json"
const CLIENT_HASH := "res://data/maps/loop_v1.sha256"
const SERVER_HASH := "res://westbound-server/data/maps/loop_v1.sha256"
const EXPORT_HINT := "run: tools/godot.sh --headless --path . res://src/road/loop/dev/loop_editor.tscn -- --export"

var t: Tuning
var road: LoopRoadPath


func before_all() -> void:
	t = Tuning.load_default()
	road = LoopRoadPath.load_default(t)


func _def() -> LoopMapDef:
	return LoopMapDef.load_default().duplicate(true) as LoopMapDef


func test_export_is_deterministic() -> void:
	var a := LoopExport.to_json(LoopRoadPath.new(_def(), t))
	var b := LoopExport.to_json(LoopRoadPath.new(_def(), t))
	eq(a, b, "same seed + edits = same bytes")
	var h := LoopExport.sha256_hex(a)
	eq(h, LoopExport.sha256_hex(b), "same hash")
	eq(h.length(), 64, "64 hex characters (PROTOCOL.md map_hash)")
	check(a.ends_with("}\n"), "one final newline")
	check(not a.contains("\r"), "LF line endings")


func test_committed_files_are_current() -> void:
	var diffs := LoopExport.check_current(road)
	eq(diffs.size(), 0, "\n".join(diffs) + "\n" + EXPORT_HINT)


func test_client_and_server_copies_and_sidecars() -> void:
	var client := FileAccess.get_file_as_bytes(CLIENT_JSON)
	var server := FileAccess.get_file_as_bytes(SERVER_JSON)
	gt(client.size(), 0, "client copy exists")
	eq(client, server, "the server's copy has the same bytes")
	var hex := FileAccess.get_sha256(CLIENT_JSON)
	eq(FileAccess.get_file_as_string(CLIENT_HASH), "%s  loop_v1.json\n" % hex, "client sidecar = sha256sum format")
	eq(FileAccess.get_file_as_string(SERVER_HASH), "%s  loop_v1.json\n" % hex, "server sidecar")
	print("      loop_v1 map hash %s" % hex)


func test_json_content() -> void:
	var data: Variant = JSON.parse_string(LoopExport.to_json(road))
	if not check(data is Dictionary, "parses"):
		return
	var d: Dictionary = data
	eq(int(d["format_version"]), 1)
	eq(d["map_id"], "loop_v1")
	var L := int(d["length_mm"])
	eq(L, LoopExport.mm(road.length()), "length in mm")
	eq(int(d["generator"]["seed"]), road.def.map_seed)
	eq((d["sections"] as Array).size(), 5)
	# Lane ranges tile [0, L) and every range has a count and a width.
	var lanes: Array = d["lanes"]
	var cursor := 0
	for r: Dictionary in lanes:
		eq(int(r["s_start_mm"]), cursor, "contiguous lane ranges")
		gt(int(r["s_end_mm"]), int(r["s_start_mm"]))
		check(int(r["count"]) >= 2 and int(r["count"]) <= 4, "2..4 lanes")
		eq(int(r["lane_width_mm"]), 3600)
		cursor = int(r["s_end_mm"])
	eq(cursor, L, "lane ranges reach L")
	var ramps: Array = d["ramps"]
	eq(ramps.size(), 4, "two ramp pairs")
	eq(ramps[0]["kind"], "off")
	eq(ramps[1]["kind"], "on")
	eq((d["closure_zones"] as Array).size(), 5)
	var sectors: Array = d["sectors"]
	eq(sectors.size(), 6)
	eq(sectors[0]["start_finish"], true)
	eq(int(sectors[0]["s_mm"]), 0, "the start / finish line is s = 0")
	eq(sectors[3]["style"], "suspension_bridge")
	gt((d["spawn_points"] as Array).size(), 0)
	eq((d["tunnels"] as Array).size(), 2)
	# Every position is a whole number of millimetres in the file text.
	var text := LoopExport.to_json(road)
	var rx := RegEx.create_from_string("\"(s_mm|s_start_mm|s_end_mm|length_mm|taper_mm)\": (-?[0-9.]+)")
	for m in rx.search_all(text):
		check(not m.get_string(2).contains("."), "%s is an integer" % m.get_string(1))


func test_an_edit_changes_the_hash() -> void:
	var d := _def()
	d.edits["bend/2/0/radius_m"] = 2650.0
	var text := LoopExport.to_json(LoopRoadPath.new(d, t))
	ne(LoopExport.sha256_hex(text), LoopExport.sha256_hex(LoopExport.to_json(road)))
	check(text.contains("\"bend/2/0/radius_m\": 2650.0"), "the edit is in the generator block")


func test_invalid_loop_is_not_exported() -> void:
	var d := _def()
	d.edits["tunnel/0/portal_m"] = -800.0
	var before := FileAccess.get_file_as_string(CLIENT_JSON)
	var errors := LoopExport.write_all(LoopRoadPath.new(d, t), t)
	gt(errors.size(), 0, "refused")
	eq(FileAccess.get_file_as_string(CLIENT_JSON), before, "nothing written")


func test_float_format() -> void:
	eq(LoopExport.format_float(95.0), "95.0")
	eq(LoopExport.format_float(1.5), "1.5")
	eq(LoopExport.format_float(0.1), "0.1")
	eq(LoopExport.format_float(-2.25), "-2.25")
	eq(LoopExport.format_float(0.0), "0.0")
	eq(LoopExport.format_float(-0.0), "0.0")
	eq(LoopExport.format_float(2650.0), "2650.0")
	eq(LoopExport.format_float(1.0 / 3.0), "0.333333")
