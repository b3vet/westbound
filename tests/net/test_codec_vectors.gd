extends WBTest
## NetCodec against the protocol crate's golden vectors. Spec: multiplayer handoff →
## Networking protocol → Golden vectors ("The GDScript codec must encode and decode every
## vector identically. Both sides run these tests in CI"); docs/PROTOCOL.md §9–10. WP N2.2.
##
## Reads westbound-server/crates/protocol/vectors/*.json straight from disk (the server tree
## has a .gdignore, so it is not a Godot resource). A missing directory fails every test.

const VECTOR_DIR := "westbound-server/crates/protocol/vectors/"
const EXPECTED_MESSAGE_VECTORS := 87
const EXPECTED_C2S := 39
const EXPECTED_S2C := 48
const EXPECTED_FRAMES := 3
const EXPECTED_INVALID := 36
const EXPECTED_QUANT := 69
const FUZZ_SEED := 20260929
const FUZZ_ROUNDS := 12

var _dir := ""
## Per message file: {"direction": Direction, "type": String, "vectors": Array}.
var _files: Array[Dictionary] = []
var _frames: Dictionary = {}
var _invalid: Dictionary = {}
var _quant: Dictionary = {}
var _load_error := ""


func before_all() -> void:
	_dir = ProjectSettings.globalize_path("res://").path_join(VECTOR_DIR)
	if not DirAccess.dir_exists_absolute(_dir):
		_load_error = "golden vector directory missing: %s" % _dir
		return
	var names := DirAccess.get_files_at(_dir)
	names.sort()
	for fname in names:
		if not fname.ends_with(".json"):
			continue
		var data: Variant = _read_json(_dir.path_join(fname))
		if not (data is Dictionary):
			_load_error = "cannot parse %s" % fname
			return
		if fname.begins_with("c2s_") or fname.begins_with("s2c_"):
			var d: Dictionary = data
			var dir := NetCodec.Direction.CLIENT_TO_SERVER if fname.begins_with("c2s_") \
				else NetCodec.Direction.SERVER_TO_CLIENT
			_files.append({"file": fname, "direction": dir, "type": d["type"],
				"type_id": int(d["type_id"]), "vectors": d["vectors"]})
		elif fname == "frames.json":
			_frames = data
		elif fname == "invalid.json":
			_invalid = data
		elif fname == "quantization.json":
			_quant = data


func _ready_or_fail() -> bool:
	if _load_error != "":
		fail(_load_error)
		return false
	if _files.is_empty() or _frames.is_empty() or _invalid.is_empty() or _quant.is_empty():
		fail("golden vectors incomplete in %s" % _dir)
		return false
	return true


# ---------------------------------------------------------------- Inventory

func test_vector_files_are_present_and_complete() -> void:
	if not _ready_or_fail():
		return
	var c2s := 0
	var s2c := 0
	for f in _files:
		var n := (f["vectors"] as Array).size()
		if f["direction"] == NetCodec.Direction.CLIENT_TO_SERVER:
			c2s += n
		else:
			s2c += n
		eq(NetCodec.type_id_of(f["type"], f["direction"]), f["type_id"],
			"%s: type id matches the codec" % f["file"])
	eq(c2s + s2c, EXPECTED_MESSAGE_VECTORS, "message vectors")
	eq(c2s, EXPECTED_C2S, "client → server vectors")
	eq(s2c, EXPECTED_S2C, "server → client vectors")
	eq((_frames["frames"] as Array).size(), EXPECTED_FRAMES, "frames")
	eq((_invalid["vectors"] as Array).size(), EXPECTED_INVALID, "invalid frames")
	eq((_quant["vectors"] as Array).size(), EXPECTED_QUANT, "quantization samples")
	eq(int(_invalid["max_frame_len"]), NetCodec.MAX_FRAME_LEN, "frame cap")
	eq(int(_invalid["max_messages_per_frame"]), NetCodec.MAX_MESSAGES_PER_FRAME, "message cap")
	eq(int(_frames["protocol_version"]), NetCodec.PROTOCOL_VERSION, "protocol version")
	# Every message type of both directions has a vector file.
	for dir: NetCodec.Direction in [NetCodec.Direction.CLIENT_TO_SERVER,
			NetCodec.Direction.SERVER_TO_CLIENT]:
		for type_id in range(0, 0x80):
			var tname := NetCodec.type_name(type_id, dir)
			if tname == "":
				continue
			var found := false
			for f in _files:
				found = found or (f["direction"] == dir and f["type"] == tname)
			check(found, "vector file for %s" % tname)


# ---------------------------------------------------------------- Message vectors

func test_every_vector_decodes_to_its_json() -> void:
	if not _ready_or_fail():
		return
	var codec := NetCodec.new()
	var sink := NetServerFrame.new()
	var n := 0
	for f in _files:
		for v: Dictionary in f["vectors"]:
			var label := "%s/%s" % [f["file"], v["name"]]
			var bytes := _hex(v["hex"])
			var expected: Dictionary = _normalize(v["message"])
			var got := codec.decode_frame(bytes, f["direction"])
			if not eq(codec.error, "", label + " decodes") or not eq(got.size(), 1, label):
				continue
			_same(got[0], expected, label)
			if f["direction"] == NetCodec.Direction.SERVER_TO_CLIENT:
				var err := codec.decode_server_frame_into(bytes, sink)
				if eq(err, "", label + " fast decode"):
					var fast := sink.to_dicts()
					if eq(fast.size(), 1, label + " fast"):
						_same(fast[0], expected, label + " (fast path)")
			n += 1
	eq(n, EXPECTED_MESSAGE_VECTORS, "vectors checked")


func test_every_vector_encodes_to_its_bytes() -> void:
	if not _ready_or_fail():
		return
	var codec := NetCodec.new()
	var st := NetPlayerState.new()
	for f in _files:
		for v: Dictionary in f["vectors"]:
			var label := "%s/%s" % [f["file"], v["name"]]
			var msg: Dictionary = _normalize(v["message"])
			var bytes := codec.encode_frame([msg], f["direction"])
			if eq(codec.error, "", label + " encodes"):
				eq(bytes.hex_encode(), v["hex"], label + " bytes")
			if f["type"] == "player_state":
				if eq(st.from_dict(msg), "", label + " NetPlayerState.from_dict"):
					eq(codec.push_player_state(st), "", label + " push_player_state")
					eq(codec.finish_frame().hex_encode(), v["hex"], label + " (fast path)")
					_same(st.to_dict(), msg, label + " to_dict")


func test_multi_message_frames_match() -> void:
	if not _ready_or_fail():
		return
	var codec := NetCodec.new()
	var sink := NetServerFrame.new()
	for fr: Dictionary in _frames["frames"]:
		var label: String = fr["name"]
		var dir := _direction(fr["direction"])
		var msgs: Array = _normalize(fr["messages"])
		var bytes := _hex(fr["hex"])
		var got := codec.decode_frame(bytes, dir)
		if eq(codec.error, "", label + " decodes") and eq(got.size(), msgs.size(), label):
			for i in msgs.size():
				_same(got[i], msgs[i], "%s[%d]" % [label, i])
		eq(codec.encode_frame(msgs, dir).hex_encode(), fr["hex"], label + " encodes")
		if dir == NetCodec.Direction.SERVER_TO_CLIENT:
			if eq(codec.decode_server_frame_into(bytes, sink), "", label + " fast decode"):
				var fast := sink.to_dicts()
				if eq(fast.size(), msgs.size(), label + " fast"):
					for i in msgs.size():
						_same(fast[i], msgs[i], "%s[%d] (fast path)" % [label, i])


func test_every_invalid_frame_is_rejected_with_its_kind() -> void:
	if not _ready_or_fail():
		return
	var codec := NetCodec.new()
	var sink := NetServerFrame.new()
	for v: Dictionary in _invalid["vectors"]:
		var label := "invalid/%s (%s)" % [v["name"], v["direction"]]
		var dir := _direction(v["direction"])
		var bytes := _hex(v["hex"])
		var got := codec.decode_frame(bytes, dir)
		eq(codec.error, v["error"], label)
		eq(got.size(), 0, label + " yields no messages")
		if dir == NetCodec.Direction.SERVER_TO_CLIENT:
			eq(codec.decode_server_frame_into(bytes, sink), v["error"], label + " (fast path)")


func test_every_quantization_sample_matches() -> void:
	if not _ready_or_fail():
		return
	for v: Dictionary in _quant["vectors"]:
		var field: String = v["field"]
		var physical := float(v["physical"])
		var label := "quant %s(%s)" % [field, physical]
		var wire := NetCodec.quantize(field, physical)
		if v["error"] != null:
			eq(wire, NetCodec.QUANT_INVALID, label + " rejected")
			eq(NetCodec.quant_error(field, physical), v["error"], label + " error kind")
			continue
		eq(NetCodec.quant_error(field, physical), "", label + " accepted")
		eq(wire, int(v["wire"]), label + " wire")
		eq(NetCodec.dequantize(field, wire), float(v["back"]), label + " back")
	# The field table agrees with the codec's bounds.
	for f: Dictionary in _quant["fields"]:
		var field: String = f["field"]
		var lo := int(f["wire_min"])
		var hi := int(f["wire_max"])
		var scale := float(f["scale"])
		eq(NetCodec.quantize(field, lo / scale), lo, field + " min round-trips")
		eq(NetCodec.quantize(field, hi / scale), hi, field + " max round-trips")


# ---------------------------------------------------------------- Beyond the vectors

func test_non_finite_values_are_rejected_for_every_field() -> void:
	for field: String in ["s", "d", "speed", "heading", "lat_vel", "yaw_rate", "steer", "clearance",
			"multiplier"]:
		for bad: float in [NAN, INF, -INF]:
			eq(NetCodec.quantize(field, bad), NetCodec.QUANT_INVALID, "%s(%s)" % [field, bad])
			eq(NetCodec.quant_error(field, bad), NetCodec.E_NOT_FINITE, "%s(%s)" % [field, bad])
	var st := NetPlayerState.new()
	eq(st.set_physical(1, 10.0, NAN, 0.0, 30.0, 0.0, 0.0, 0.0, 0, 2), NetCodec.E_NOT_FINITE)
	eq(st.set_physical(1, -1.0, 0.0, 0.0, 30.0, 0.0, 0.0, 0.0, 0, 2), NetCodec.E_OUT_OF_RANGE)
	eq(st.set_physical(7, 12345.678, -1.75, 0.0873, 69.44, -0.42, 0.118, -0.125,
		NetCodec.PLAYER_FLAG_BOOST | NetCodec.PLAYER_FLAG_HEADLIGHTS, 2), "")
	eq([st.s_mm, st.d_cm, st.heading_e4, st.speed_cms, st.lat_vel_cms, st.yaw_rate_mrad_s,
		st.steer_e4], [12345678, -175, 873, 6944, -42, 118, -1250], "quantized state")


func test_account_ids_keep_all_64_bits() -> void:
	var codec := NetCodec.new()
	for id: String in ["0", "1", "9007199254740993", "9223372036854775807"]:
		var bytes := codec.encode_frame([{"type": "lobby_command", "kind": "party_invite",
			"account_id": id}], NetCodec.Direction.CLIENT_TO_SERVER)
		eq(codec.error, "", id)
		var back := codec.decode_frame(bytes, NetCodec.Direction.CLIENT_TO_SERVER)
		if eq(back.size(), 1, id):
			eq(back[0]["account_id"], id, "round trip " + id)
	for bad: String in ["9223372036854775808", "18446744073709551615"]:
		codec.encode_frame([{"type": "lobby_command", "kind": "party_invite", "account_id": bad}],
			NetCodec.Direction.CLIENT_TO_SERVER)
		eq(codec.error, NetCodec.E_OUT_OF_RANGE, bad)
	for bad: String in ["", "-1", "12a", "1.5", " 1"]:
		codec.encode_frame([{"type": "lobby_command", "kind": "party_invite", "account_id": bad}],
			NetCodec.Direction.CLIENT_TO_SERVER)
		eq(codec.error, NetCodec.E_INVALID_VALUE, "'%s'" % bad)


func test_encoder_validates_and_writes_nothing_on_failure() -> void:
	var codec := NetCodec.new()
	var c2s := NetCodec.Direction.CLIENT_TO_SERVER
	var s2c := NetCodec.Direction.SERVER_TO_CLIENT
	eq(codec.push({"type": "ping", "client_time_ms": 5}, c2s), "")
	var len_before := codec.frame_len()
	var cases := [
		[{"type": "ping", "client_time_ms": -1}, c2s, NetCodec.E_OUT_OF_RANGE],
		[{"type": "ping", "client_time_ms": 4294967296}, c2s, NetCodec.E_OUT_OF_RANGE],
		[{"type": "ping"}, c2s, NetCodec.E_MISSING_FIELD],
		[{"type": "ping", "client_time_ms": "5"}, c2s, NetCodec.E_INVALID_VALUE],
		[{"type": "pong", "client_time_ms": 1, "server_tick": 2, "tick_fraction": 3}, c2s,
			NetCodec.E_UNKNOWN_TYPE],
		[{"type": "nope"}, c2s, NetCodec.E_UNKNOWN_TYPE],
		[{"type": "run_event", "kind": "restart", "tick": 1}, c2s, NetCodec.E_INVALID_ENUM],
		[{"type": "lobby_command", "kind": "fly"}, c2s, NetCodec.E_INVALID_ENUM],
		[{"type": "lobby_command", "kind": "room_join_code", "code": "ABC23"}, c2s,
			NetCodec.E_BAD_CHAR_COUNT],
		[{"type": "lobby_command", "kind": "room_join_code", "code": "ABC230"}, c2s,
			NetCodec.E_BAD_CHAR],
		[{"type": "score_claim", "claim_id": 1, "tick": 1, "kind": "pass", "side": "left",
			"cars": []}, c2s, NetCodec.E_BAD_COUNT],
		[{"type": "quick_chat", "item": {"kind": "emote", "emote": 32}}, c2s,
			NetCodec.E_OUT_OF_RANGE],
		[{"type": "error", "code": "internal", "fatal": 1, "detail": ""}, s2c,
			NetCodec.E_INVALID_VALUE],
		[{"type": "error", "code": "internal", "fatal": true, "detail": "x".repeat(256)}, s2c,
			NetCodec.E_STRING_TOO_LONG],
		[{"type": "error", "code": "internal", "fatal": true, "detail": "tab\there"}, s2c,
			NetCodec.E_BAD_CHAR],
		[{"type": "welcome", "protocol_version": 1, "server_build": 1, "account_id": "1",
			"tick_rate_hz": 0, "ping_interval_ms": 1, "timeout_ms": 1, "max_frame_bytes": 1},
			s2c, NetCodec.E_OUT_OF_RANGE],
	]
	for c: Array in cases:
		eq(codec.push(c[0], c[1]), c[2], str(c[0]))
		eq(codec.frame_len(), len_before, "nothing written for %s" % str(c[0]))
	var names := {"type": "lobby_event", "kind": "party_state", "code": "ABC234", "leader": "1",
		"members": [{"account_id": "1", "display_name": "zero​width", "name_tag": 1}]}
	eq(codec.push(names, s2c), NetCodec.E_BAD_CHAR, "zero-width space in a name")
	var st := NetPlayerState.new()
	st.d_cm = 10001
	eq(codec.push_player_state(st), NetCodec.E_OUT_OF_RANGE, "player state d")
	st.d_cm = 0
	st.flags = 0x10
	eq(codec.push_player_state(st), NetCodec.E_RESERVED_BITS, "player state flags")
	st.flags = 0
	st.run_state = 4
	eq(codec.push_player_state(st), NetCodec.E_INVALID_ENUM, "player state run_state")
	eq(codec.frame_len(), len_before, "nothing written by rejected player states")


func test_frame_builder_limits() -> void:
	var codec := NetCodec.new()
	var c2s := NetCodec.Direction.CLIENT_TO_SERVER
	for i in NetCodec.MAX_MESSAGES_PER_FRAME:
		eq(codec.push({"type": "ping", "client_time_ms": i}, c2s), "")
	eq(codec.push({"type": "ping", "client_time_ms": 1}, c2s), NetCodec.E_TOO_MANY_MESSAGES)
	var frame := codec.finish_frame()
	eq(frame.size(), NetCodec.MAX_MESSAGES_PER_FRAME * 7, "64 pings")
	eq(codec.decode_frame(frame, c2s).size(), NetCodec.MAX_MESSAGES_PER_FRAME, "decodes")
	eq(codec.frame_len(), 0, "finish resets")
	# Byte cap: 2091-byte hellos until the 16 KB frame is full.
	var hello := {"type": "hello", "protocol_version": 1, "client_build": 1,
		"map_hash": "00".repeat(32), "access_token": "e".repeat(2048)}
	var pushed := 0
	while codec.push(hello, c2s) == "":
		pushed += 1
	eq(pushed, 7, "hellos that fit (16384 / 2091)")
	eq(codec.push(hello, c2s), NetCodec.E_FRAME_FULL)
	le(codec.frame_len(), NetCodec.MAX_FRAME_LEN)
	eq(codec.encode_frame([], c2s).size(), 0, "no messages")
	eq(codec.error, NetCodec.E_EMPTY_FRAME)


func test_server_frame_capacities_cover_a_full_frame() -> void:
	var cap := NetCodec.MAX_FRAME_LEN
	gt(NetServerFrame.PS_CAP * NetServerFrame.PLAYER_ENTRY_LEN, cap, "player entries")
	gt(NetServerFrame.SP_CAP * NetServerFrame.SPAWN_LEN, cap, "spawns")
	gt(NetServerFrame.DS_CAP * NetServerFrame.DESPAWN_LEN, cap, "despawns")
	gt(NetServerFrame.IN_CAP * NetServerFrame.INTENT_LEN, cap, "intents")
	gt(NetServerFrame.CO_CAP * NetServerFrame.CORRECTION_LEN, cap, "corrections")
	# A frame packed with despawn ids (63 full batches of 260 bytes = 16,380) decodes
	# without overflowing the arrays; a 64th batch does not fit the frame.
	var codec := NetCodec.new()
	var ids := []
	for i in NetCodec.MAX_TRAFFIC_BATCH:
		ids.append(i)
	var batch := {"type": "traffic_despawn", "car_ids": ids}
	var batches := 0
	while codec.push(batch, NetCodec.Direction.SERVER_TO_CLIENT) == "":
		batches += 1
	eq(batches, 63, "full despawn batches per frame")
	var frame := codec.finish_frame()
	var sink := NetServerFrame.new()
	eq(codec.decode_server_frame_into(frame, sink), "")
	eq(sink.ds_count, batches * NetCodec.MAX_TRAFFIC_BATCH)
	le(sink.ds_count, NetServerFrame.DS_CAP)


func test_utf8_rules_match_rust() -> void:
	var codec := NetCodec.new()
	var s2c := NetCodec.Direction.SERVER_TO_CLIENT
	# `detail` is server text: [42][len][code, fatal, str8]. Invalid UTF-8 sequences.
	for bad: String in ["c0af", "e080af", "eda080", "f4908080", "f8", "80", "e282", "c3"]:
		var raw := _hex(bad)
		var frame := _hex("42") + _u16le(3 + raw.size()) + _hex("1301") \
			+ PackedByteArray([raw.size()]) + raw
		codec.decode_frame(frame, s2c)
		eq(codec.error, NetCodec.E_INVALID_UTF8, "bytes %s" % bad)
	# Valid edge sequences, including a leading BOM (text allows it) and U+10FFFF.
	for good: String in ["efbbbf41", "f48fbfbf", "ed9fbf", "e0a080", "c280"]:
		var raw := _hex(good)
		var frame := _hex("42") + _u16le(3 + raw.size()) + _hex("1301") \
			+ PackedByteArray([raw.size()]) + raw
		var got := codec.decode_frame(frame, s2c)
		if not eq(codec.error, "" if good != "c280" else NetCodec.E_BAD_CHAR, "bytes %s" % good):
			continue
		if good == "c280":
			continue   # U+0080 is a C1 control: valid UTF-8, rejected by the text rule
		var again := codec.encode_frame(got, s2c)
		eq(again.hex_encode(), frame.hex_encode(), "re-encodes %s" % good)


## Mutated vectors: the Dictionary decoder and the hot-path decoder agree on every frame
## (same error kind, or the same messages), nothing raises an engine error, and anything
## that decodes re-encodes to the identical bytes (PROTOCOL.md §10).
func test_mutated_frames_decode_consistently() -> void:
	if not _ready_or_fail():
		return
	var rng := Rng.new(FUZZ_SEED)
	var codec := NetCodec.new()
	var sink := NetServerFrame.new()
	var frames: Array[PackedByteArray] = []
	for f in _files:
		if f["direction"] != NetCodec.Direction.SERVER_TO_CLIENT:
			continue
		for v: Dictionary in f["vectors"]:
			frames.append(_hex(v["hex"]))
	for fr: Dictionary in _frames["frames"]:
		if _direction(fr["direction"]) == NetCodec.Direction.SERVER_TO_CLIENT:
			frames.append(_hex(fr["hex"]))
	var decoded := 0
	var rejected := 0
	for round_i in FUZZ_ROUNDS:
		for base in frames:
			var m := base.duplicate()
			match rng.int_range(0, 3):
				0:   # flip one byte
					var i := rng.int_range(0, m.size() - 1)
					m[i] = rng.int_range(0, 255)
				1:   # truncate
					m.resize(rng.int_range(0, m.size() - 1))
				2:   # append junk
					m.append(rng.int_range(0, 255))
				3:   # corrupt a payload byte but keep the header
					if m.size() > NetCodec.MSG_HEADER_LEN:
						var j := rng.int_range(NetCodec.MSG_HEADER_LEN, m.size() - 1)
						m[j] = m[j] ^ (1 << rng.int_range(0, 7))
			var slow := codec.decode_frame(m, NetCodec.Direction.SERVER_TO_CLIENT)
			var slow_err := codec.error
			var fast_err := codec.decode_server_frame_into(m, sink)
			if not eq(fast_err, slow_err, "round %d: both decoders agree on %s" % [round_i,
					m.hex_encode().left(64)]):
				continue
			if slow_err != "":
				rejected += 1
				continue
			decoded += 1
			var fast := sink.to_dicts()
			if eq(fast.size(), slow.size()):
				for i in slow.size():
					_same(fast[i], slow[i], "fuzz fast == slow")
			eq(codec.encode_frame(slow, NetCodec.Direction.SERVER_TO_CLIENT).hex_encode(),
				m.hex_encode(), "decoded frame re-encodes identically")
	gt(decoded, 0, "some mutations still decode")
	gt(rejected, 0, "some mutations are rejected")


# ---------------------------------------------------------------- Helpers

func _read_json(path: String) -> Variant:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _direction(text: String) -> NetCodec.Direction:
	return NetCodec.Direction.CLIENT_TO_SERVER if text == "client_to_server" \
		else NetCodec.Direction.SERVER_TO_CLIENT


func _hex(text: String) -> PackedByteArray:
	var out := NetCodec.hex_to_bytes(text)
	if out.size() * 2 != text.length():
		fail("bad hex in vector: %s" % text.left(40))
	return out


func _u16le(v: int) -> PackedByteArray:
	return PackedByteArray([v & 0xFF, v >> 8])


## JSON numbers parse as floats; integral values become ints (every wire number is an
## integer, and every one fits a float exactly: u32 at most).
func _normalize(v: Variant) -> Variant:
	if v is float and float(v) == floorf(v):
		return int(v)
	if v is Dictionary:
		var d := {}
		for k: Variant in v:
			d[k] = _normalize(v[k])
		return d
	if v is Array:
		var a := []
		for x: Variant in v:
			a.append(_normalize(x))
		return a
	return v


## Deep equality with a readable path to the first difference.
func _same(actual: Variant, expected: Variant, label: String) -> bool:
	var diff := _diff(actual, expected, "")
	if diff != "":
		fail("%s: %s" % [label, diff])
		return false
	return true


func _diff(a: Variant, b: Variant, path: String) -> String:
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		for k: Variant in db:
			if not da.has(k):
				return "%s.%s missing" % [path, k]
			var d := _diff(da[k], db[k], "%s.%s" % [path, k])
			if d != "":
				return d
		for k: Variant in da:
			if not db.has(k):
				return "%s.%s unexpected" % [path, k]
		return ""
	if a is Array and b is Array:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			return "%s size %d != %d" % [path, aa.size(), ab.size()]
		for i in aa.size():
			var d := _diff(aa[i], ab[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if typeof(a) != typeof(b) or a != b:
		return "%s: got %s (%s), expected %s (%s)" % [path, var_to_str(a),
			type_string(typeof(a)), var_to_str(b), type_string(typeof(b))]
	return ""
