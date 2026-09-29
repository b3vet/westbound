class_name LoopExport
extends RefCounted
## The loop's road-space file (N3.1): canonical JSON shared by the client and the server,
## and its SHA-256 (the map hash sent in Hello). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## The loop map ("Road-space file (JSON with a version and a content hash), shared by
## client and server"; "Hash check on join"), Rules for the server code 5 ("Data shared
## with the client comes from the client"); docs/PROTOCOL.md (map_hash = raw SHA-256 of
## the road-space file). docs/LOOP_MAP.md → Road-space file.
##
##   var text := LoopExport.to_json(road)          # canonical bytes (UTF-8, LF, final newline)
##   LoopExport.sha256_hex(text)                   # the map hash (64 hex)
##   LoopExport.write_all(road, tuning)            # both copies + sidecars (refuses an invalid loop)
##   LoopExport.check_current(road)                # [] when the committed files match
##
## Canonical form: keys in a fixed order (written below, never sorted by a library),
## two-space indentation, one small object per line, every position and length a whole
## number of millimetres (LoopGen quantises them), floats (speeds, edit values) with up
## to six decimals and no trailing zeros. The hash covers every byte of the .json file;
## the sidecar <map>.sha256 holds "<hex>  <map>.json" (sha256sum -c format).
##
## Two copies with the same bytes: data/maps/<map>.json for the client and
## westbound-server/data/maps/<map>.json for the server (its Docker build context is
## westbound-server/, and Godot ignores that folder). The test suite fails when either
## differs from a fresh export.

const CLIENT_DIR := "res://data/maps/"
const SERVER_DIR := "res://westbound-server/data/maps/"
const JSON_EXT := ".json"
const HASH_EXT := ".sha256"
const MM_PER_M := 1000
const INDENT := "  "
## Decimal places of floats before trailing zeros are dropped.
const FLOAT_DECIMALS := 6


# ---------------------------------------------------------------- Content

## The road-space data as ordered Dictionaries (the key order is the file's).
static func road_space(road: LoopRoadPath) -> Dictionary:
	var o := road.layout
	var d := road.def
	var edits := {}
	var keys := d.edits.keys()
	keys.sort()
	for key: String in keys:
		edits[key] = float(d.edits[key])
	var sections: Array = []
	for j in road.section_count():
		var speeds: Array = []
		for v in d.sections[j].lane_flow_speeds_from_right_kmh:
			speeds.append(float(v))
		sections.append({
			"index": j,
			"id": String(o.section_ids[j]),
			"s_start_mm": mm(road.section_start(j)),
			"s_end_mm": mm(road.section_start(j) + o.section_length_m),
			"lanes": o.section_lanes[j],
			"lane_flow_speeds_from_right_kmh": speeds,
		})
	var lanes: Array = []
	var starts := PackedFloat64Array([0.0])
	starts.append_array(o.lane_s)
	for i in starts.size():
		var s0 := starts[i]
		var s1 := starts[i + 1] if i + 1 < starts.size() else road.length()
		if s1 <= s0:
			continue
		lanes.append({
			"s_start_mm": mm(s0),
			"s_end_mm": mm(s1),
			"count": o.lanes_base if i == 0 else o.lane_n[i - 1],
			"lane_width_mm": mm(road.lane_width(s0)),
			"taper_mm": 0 if i == 0 else mm(o.lane_taper[i - 1]),
		})
	var tunnels: Array = []
	for t in o.tunnel_s0.size():
		tunnels.append({"index": t, "s_start_mm": mm(o.tunnel_s0[t]), "s_end_mm": mm(o.tunnel_s1[t]),
			"lanes": o.tunnel_lanes[t]})
	var ramps: Array = []
	for i in o.ramp_s.size():
		ramps.append({"pair": o.ramp_pair[i], "kind": "off" if o.ramp_kind[i] == LoopLayout.RAMP_OFF else "on",
			"side": "right", "section": o.ramp_section[i], "s_mm": mm(o.ramp_s[i]), "length_mm": mm(o.ramp_len[i])})
	var closures: Array = []
	for i in o.closure_s0.size():
		closures.append({"index": i, "section": o.closure_section[i], "s_start_mm": mm(o.closure_s0[i]),
			"s_end_mm": mm(o.closure_s1[i]), "taper_mm": mm(d.closure_taper_m), "lanes_closed_from_right": d.closure_lanes,
			"default_on": false})
	var sectors: Array = []
	for k in o.sector_s.size():
		sectors.append({"index": k, "s_mm": mm(o.sector_s[k]), "style": String(o.sector_style[k]),
			"start_finish": k == 0})
	var spawns: Array = []
	for i in o.spawn_s.size():
		spawns.append({"s_mm": mm(o.spawn_s[i]), "lane": o.spawn_lane[i]})
	return {
		"format_version": d.format_version,
		"map_id": String(d.map_id),
		"units": {"length": "mm", "speed": "km/h"},
		"generator": {
			"name": "LoopGen",
			"version": d.generator_version,
			"seed": d.map_seed,
			"section_length_mm": mm(d.section_length_m),
			"edits": edits,
		},
		"length_mm": mm(road.length()),
		"cross_section": {
			"median_half_width_mm": mm(road.median_half_width_m),
			"inner_shoulder_mm": mm(road.inner_shoulder_m),
			"lane_width_mm": mm(road.lane_width_m),
			"shoulder_mm": mm(road.shoulder_m),
			"guardrail_offset_mm": mm(road.guardrail_offset_m),
		},
		"sections": sections,
		"lanes": lanes,
		"tunnels": tunnels,
		"bridge": {"sector": d.bridge_sector, "s_start_mm": mm(o.bridge_s0), "s_end_mm": mm(o.bridge_s1)},
		"ramps": ramps,
		"closure_zones": closures,
		"sectors": sectors,
		"spawn_points": spawns,
	}


static func mm(m: float) -> int:
	return roundi(m * float(MM_PER_M))


# ---------------------------------------------------------------- Canonical JSON

static func to_json(road: LoopRoadPath) -> String:
	return encode(road_space(road), 0) + "\n"


## Canonical encoding (see the header). Dictionaries keep their insertion order.
static func encode(v: Variant, depth: int) -> String:
	match typeof(v):
		TYPE_DICTIONARY:
			var dict: Dictionary = v
			if dict.is_empty():
				return "{}"
			var parts := PackedStringArray()
			for key: String in dict.keys():
				parts.append("%s: %s" % [JSON.stringify(key), encode(dict[key], depth + 1)])
			if _is_flat(dict.values()):
				return "{" + ", ".join(parts) + "}"
			var pad := INDENT.repeat(depth + 1)
			return "{\n" + pad + (",\n" + pad).join(parts) + "\n" + INDENT.repeat(depth) + "}"
		TYPE_ARRAY:
			var arr: Array = v
			if arr.is_empty():
				return "[]"
			var parts := PackedStringArray()
			for item: Variant in arr:
				parts.append(encode(item, depth + 1))
			if _is_scalar_list(arr):
				return "[" + ", ".join(parts) + "]"
			var pad := INDENT.repeat(depth + 1)
			return "[\n" + pad + (",\n" + pad).join(parts) + "\n" + INDENT.repeat(depth) + "]"
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return format_float(v)
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(String(v))
	push_error("LoopExport.encode: unsupported type %s" % type_string(typeof(v)))
	return "null"


## Up to FLOAT_DECIMALS decimals, trailing zeros dropped, at least one decimal.
static func format_float(x: float) -> String:
	var t := String.num(x, FLOAT_DECIMALS) if absf(x) > 0.0 else "0"
	if not t.contains("."):
		t += ".0"
	return t


static func _is_scalar_list(arr: Array) -> bool:
	for item: Variant in arr:
		var ty := typeof(item)
		if ty == TYPE_DICTIONARY or ty == TYPE_ARRAY:
			return false
	return true


## Values that fit one line: scalars and lists of scalars.
static func _is_flat(values: Array) -> bool:
	for item: Variant in values:
		var ty := typeof(item)
		if ty == TYPE_DICTIONARY:
			return false
		if ty == TYPE_ARRAY and not _is_scalar_list(item):
			return false
	return true


# ---------------------------------------------------------------- Hash and files

static func sha256_hex(text: String) -> String:
	return text.sha256_text()


static func sidecar_text(road: LoopRoadPath, hex: String) -> String:
	return "%s  %s%s\n" % [hex, String(road.def.map_id), JSON_EXT]


static func paths(road: LoopRoadPath) -> PackedStringArray:
	var id := String(road.def.map_id)
	return PackedStringArray([CLIENT_DIR + id + JSON_EXT, CLIENT_DIR + id + HASH_EXT,
		SERVER_DIR + id + JSON_EXT, SERVER_DIR + id + HASH_EXT])


## Writes both copies of the road-space file and their sidecars. Refuses (returns the
## validation errors) when the loop is not valid. Returns [] on success.
static func write_all(road: LoopRoadPath, tuning: Tuning) -> PackedStringArray:
	var errors := LoopValidator.validate(road, tuning)
	if not errors.is_empty():
		return errors
	var text := to_json(road)
	var side := sidecar_text(road, sha256_hex(text))
	var p := paths(road)
	for i in p.size():
		var err := _write(p[i], text if i % 2 == 0 else side)
		if err != "":
			errors.append(err)
	return errors


## Differences between the committed files and a fresh export ([] = current).
static func check_current(road: LoopRoadPath) -> PackedStringArray:
	var out := PackedStringArray()
	var text := to_json(road)
	var side := sidecar_text(road, sha256_hex(text))
	var p := paths(road)
	for i in p.size():
		var want := text if i % 2 == 0 else side
		if not FileAccess.file_exists(p[i]):
			out.append("%s is missing" % p[i])
		elif FileAccess.get_file_as_string(p[i]) != want:
			out.append("%s differs from a fresh export" % p[i])
	return out


static func _write(path: String, text: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(text)
	f.close()
	return ""
