class_name NetCodec
extends RefCounted
## Binary codec for the realtime protocol. Spec: multiplayer handoff → Networking protocol
## (Encoding, quantization, messages, golden vectors). Contract: docs/PROTOCOL.md; reference
## implementation: westbound-server/crates/protocol (this file mirrors it). WP N2.2.
##
## Two representations (docs/NET_CLIENT.md → Codec):
##   - **Dictionaries** mirroring the golden-vector JSON (PROTOCOL.md §8): `{"type": ..., ...}`,
##     unions flattened next to `"kind"`, enums as snake_case Strings, flag sets as
##     Dictionaries of bools, account ids as decimal Strings, the map hash as 64 hex chars.
##     Every message in both directions goes through `push()` / `decode_frame()`. Used for
##     the lobby, handshake and other rare messages, and by the golden-vector tests.
##   - **Hot paths without Dictionaries:** `push_player_state()` writes a NetPlayerState
##     (typed ints) straight into the frame buffer (20 Hz up), and
##     `decode_server_frame_into()` decodes `player_states` and the four traffic batches into
##     the pre-sized structure-of-arrays NetServerFrame (20 Hz down); other messages in the
##     same frame land in its `messages` as Dictionaries, in order.
##
## Framing: a frame is one or more `[u8 type][u16 len LE][payload]`; at most 16,384 bytes
## and 64 messages. Any error rejects the whole frame: `decode_*` return the error kind (the
## `error` field of vectors/invalid.json) and no messages. Error precedence mirrors Rust:
## structural errors (truncated, invalid_enum/bool/utf8, reserved_bits) are reported at the
## first byte that fails, then `trailing_bytes`, then the first range/count/string rule in
## field order (a list's items before its count).
##
## One NetCodec per connection: it owns one reusable 16 KB output buffer (like the Rust
## FrameBuilder: `push*` validate and append, writing nothing on failure; `finish()` hands
## out the frame) and the decode cursor. Not thread-safe.

const PROTOCOL_VERSION := 1
const MAX_FRAME_LEN := 16384
const MSG_HEADER_LEN := 3
const MAX_MESSAGES_PER_FRAME := 64
const MAP_HASH_LEN := 32
const MAX_ACCOUNT_ID := 9223372036854775807
const MAX_ACCOUNT_ID_DIV10 := 922337203685477580
const PLAYER_STATE_LEN := 22

enum Direction { CLIENT_TO_SERVER, SERVER_TO_CLIENT }

# ---------------------------------------------------------------- Type ids (PROTOCOL.md §2)

const MSG_HELLO := 0x01
const MSG_PING := 0x02
const MSG_LOBBY_COMMAND := 0x03
const MSG_PLAYER_STATE := 0x04
const MSG_SCORE_CLAIM := 0x05
const MSG_HIT_REPORT := 0x06
const MSG_RUN_EVENT := 0x07
const MSG_QUICK_CHAT := 0x08
const MSG_ROOM_HOST_COMMAND := 0x09

const MSG_WELCOME := 0x40
const MSG_PONG := 0x41
const MSG_ERROR := 0x42
const MSG_LOBBY_EVENT := 0x43
const MSG_ROOM_SNAPSHOT := 0x44
const MSG_PLAYER_STATES := 0x45
const MSG_TRAFFIC_SPAWN := 0x46
const MSG_TRAFFIC_DESPAWN := 0x47
const MSG_TRAFFIC_INTENT := 0x48
const MSG_TRAFFIC_CORRECTION := 0x49
const MSG_SCORE_SYNC := 0x4A
const MSG_SCORE_EVENT := 0x4B
const MSG_RUN_RESULT := 0x4C
const MSG_ROOM_EVENT := 0x4D
const MSG_QUICK_CHAT_RELAY := 0x4E
const MSG_SERVER_NOTICE := 0x4F

# ---------------------------------------------------------------- Error kinds (PROTOCOL.md §10)

const E_EMPTY_FRAME := "empty_frame"
const E_FRAME_TOO_LARGE := "frame_too_large"
const E_TOO_MANY_MESSAGES := "too_many_messages"
const E_TRUNCATED := "truncated"
const E_TRAILING_BYTES := "trailing_bytes"
const E_UNKNOWN_TYPE := "unknown_type"
const E_INVALID_ENUM := "invalid_enum"
const E_INVALID_BOOL := "invalid_bool"
const E_RESERVED_BITS := "reserved_bits"
const E_INVALID_UTF8 := "invalid_utf8"
const E_OUT_OF_RANGE := "out_of_range"
const E_BAD_COUNT := "bad_count"
const E_STRING_TOO_LONG := "string_too_long"
const E_BAD_CHAR_COUNT := "bad_char_count"
const E_BAD_CHAR := "bad_char"
## Quantization only: NaN or ±inf.
const E_NOT_FINITE := "not_finite"
## Encoder only: the frame has no room for the message (defer it to the next frame).
const E_FRAME_FULL := "frame_full"
## Encoder only: a required field is missing from the Dictionary.
const E_MISSING_FIELD := "missing_field"
## Encoder only: a field has the wrong Variant type (e.g. a String for an integer).
const E_INVALID_VALUE := "invalid_value"

# ---------------------------------------------------------------- Enums (PROTOCOL.md §7)

const RUN_STATE := ["not_running", "protected", "driving", "crashed"]
const LC_PHASE := ["none", "signaling", "moving"]
const INTENT_KIND := ["lane_change", "cancel", "hazard", "horn", "hard_brake"]
const CLAIM_KIND := ["pass", "close_pass", "cut", "thread"]
const SIDE := ["none", "left", "right"]
const HIT_TARGET := ["traffic", "barrier", "roadside"]
const RUN_EVENT_KIND := ["start", "end", "rejoin"]
const PHRASE := ["nice_thread", "follow_me", "slow_down", "regroup", "gg", "one_more_lap"]
const DENSITY := ["light", "normal", "rush"]
const TIME_MODE := ["cycle", "fixed", "night"]
const VISIBILITY := ["private", "public"]
const PRESENCE_STATUS := ["offline", "online", "in_room"]
const PARTY_LEFT_REASON := ["left", "kicked", "disbanded"]
const ROOM_LEFT_REASON := ["left", "kicked", "closed", "timed_out"]
const LEAVE_REASON := ["left", "timed_out"]
const ERROR_CODE := [
	"update_required", "server_outdated", "map_mismatch", "auth_failed", "banned",
	"handshake_required", "malformed", "rate_limited", "server_full", "room_not_found",
	"room_full", "party_not_found", "party_full", "not_host", "not_party_leader",
	"not_in_room", "already_in_room", "blocked", "not_allowed", "internal",
]
const SCORE_EVENT_KIND := [
	"train", "sector_clean", "sector_pace", "sector_threads", "sector_heat", "claim_rejected",
]
const RUN_END_REASON := ["crashed", "quit", "disconnected", "room_closed"]
const NOTICE_KIND := ["info", "restart", "maintenance"]

# Flag sets: bit i = name i.
const PLAYER_FLAGS := ["brake", "boost", "headlights", "ghost"]
const TRAFFIC_FLAGS := ["hazard", "braking"]
const MEMBER_FLAGS := ["host", "disconnected"]
const SCORE_FLAGS := ["banking", "night", "unverified"]
const RUN_RESULT_FLAGS := ["verified", "leaderboard_eligible"]

const PLAYER_FLAG_BRAKE := 1 << 0
const PLAYER_FLAG_BOOST := 1 << 1
const PLAYER_FLAG_HEADLIGHTS := 1 << 2
const PLAYER_FLAG_GHOST := 1 << 3
const PLAYER_FLAGS_MASK := 0x0F
const TRAFFIC_FLAGS_MASK := 0x03

# ---------------------------------------------------------------- Protocol bounds (messages.rs)

const MAX_LANE := 7
const MAX_ABS_D_CM := 10000
const MAX_SPEED_CMS := 20000
const MAX_HEADING_E4 := 31416
const MAX_STEER_E4 := 10000
const MAX_ABS_I16 := 32767
const MAX_NAME_TAG := 9999
const MAX_ROOM_PLAYERS := 16
const MAX_CREW_SLOT := 15
const MAX_CREWS := 16
const MAX_PARTY_MEMBERS := 16
const MAX_TRAFFIC_BATCH := 128
const MAX_INTENT_BATCH := 64
const MAX_CLAIM_CARS := 2
const MAX_PRESENCE_BATCH := 128
const MAX_ROOM_LIST := 64
const MAX_EMOTE := 31
const MAX_TICK_RATE_HZ := 120

# ---------------------------------------------------------------- Quantization (quant.rs)

## Wire units per physical unit.
const S_PER_M := 1000.0   # lint: allow-number mm per m
const D_PER_M := 100.0   # lint: allow-number cm per m
const SPEED_PER_MPS := 100.0   # lint: allow-number cm/s per m/s
const HEADING_PER_RAD := 10000.0   # lint: allow-number 1e-4 rad
const LAT_VEL_PER_MPS := 100.0   # lint: allow-number cm/s per m/s
const YAW_RATE_PER_RAD_S := 1000.0   # lint: allow-number mrad/s per rad/s
const STEER_PER_UNIT := 10000.0   # lint: allow-number 1e-4
const CLEARANCE_PER_M := 1000.0   # lint: allow-number mm per m
const MULTIPLIER_PER_UNIT := 1000.0   # lint: allow-number x1e-3
## `wire = round(value × scale)` for tick_fraction (1/65536 tick).
const TICK_FRACTION_SCALE := 65536.0   # lint: allow-number fraction units per tick
const U32_MAX := 4294967295
const U16_MAX := 65535
## Returned by the `*_to_wire` helpers when the value cannot be quantized (outside every
## wire range). `quant_error()` says why.
const QUANT_INVALID := 9223372036854775807

# ---------------------------------------------------------------- Schema

enum K { U8, U16, U32, I16, BOOL, ACCOUNT, HASH, ENUM, FLAGS, STR, STRUCT, LIST, UNION }
enum Str { NAME, CREW_TAG, CODE, TOKEN, TEXT }

const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const CODE_LEN := 6

## Per string kind: [wide (u16) prefix, max bytes, min chars, max chars].
const STR_RULES := [
	[false, 64, 1, 16],
	[false, 16, 0, 4],
	[false, 6, 6, 6],
	[true, 2048, 0, 2048],
	[false, 255, 0, 255],
]

## type id → [name, schema] per direction; name → type id per direction.
static var _c2s: Dictionary = {}
static var _s2c: Dictionary = {}
static var _c2s_ids: Dictionary = {}
static var _s2c_ids: Dictionary = {}

## Error kind of the last decode/encode call ("" = none).
var error: String = ""

# Decode cursor (one message payload at a time).
var _buf: PackedByteArray
var _pos: int = 0
var _end: int = 0
var _err: String = ""
var _verr: String = ""

# Output frame (reused).
var _out := PackedByteArray()
var _out_len: int = 0
var _out_count: int = 0
var _werr: String = ""


func _init() -> void:
	_ensure_schema()
	_out.resize(MAX_FRAME_LEN)


# ================================================================ Encoding

## Bytes and messages in the frame being built.
func frame_len() -> int:
	return _out_len


func frame_message_count() -> int:
	return _out_count


## Discards the frame being built.
func clear_frame() -> void:
	_out_len = 0
	_out_count = 0


## Takes the frame built so far (possibly empty) and starts a new one.
func finish_frame() -> PackedByteArray:
	var frame := _out.slice(0, _out_len)
	_out_len = 0
	_out_count = 0
	return frame


## Validates and appends one message (a vector-JSON Dictionary). Returns "" or the error
## kind; on failure nothing is written, so the caller can send the rest next frame.
func push(msg: Dictionary, direction: Direction) -> String:
	if _out_count >= MAX_MESSAGES_PER_FRAME:
		return E_TOO_MANY_MESSAGES
	var ids := _c2s_ids if direction == Direction.CLIENT_TO_SERVER else _s2c_ids
	var tname: Variant = msg.get("type")
	if not (tname is String) or not ids.has(tname):
		return E_UNKNOWN_TYPE
	var type_id: int = ids[tname]
	var table := _c2s if direction == Direction.CLIENT_TO_SERVER else _s2c
	var entry: Array = table[type_id]
	var start := _out_len
	_werr = ""
	if not _room(MSG_HEADER_LEN):
		return _werr
	_out[start] = type_id
	_out_len += MSG_HEADER_LEN
	_write_struct(entry[1], msg)
	if _werr != "":
		_out_len = start
		return _werr
	_out.encode_u16(start + 1, _out_len - start - MSG_HEADER_LEN)
	_out_count += 1
	return ""


## Hot path: appends a client `player_state` without building a Dictionary.
func push_player_state(st: NetPlayerState) -> String:
	if _out_count >= MAX_MESSAGES_PER_FRAME:
		return E_TOO_MANY_MESSAGES
	var bad := st.validate()
	if bad != "":
		return bad
	var n := MSG_HEADER_LEN + PLAYER_STATE_LEN
	if _out_len + n > MAX_FRAME_LEN:
		return E_FRAME_FULL
	var p := _out_len
	_out[p] = MSG_PLAYER_STATE
	_out.encode_u16(p + 1, PLAYER_STATE_LEN)
	_write_player_state_at(p + MSG_HEADER_LEN, st)
	_out_len += n
	_out_count += 1
	return ""


## Encodes `msgs` (vector-JSON Dictionaries) as one frame. Empty on error (see `error`).
func encode_frame(msgs: Array, direction: Direction) -> PackedByteArray:
	clear_frame()
	error = ""
	for m: Variant in msgs:
		if not (m is Dictionary):
			error = E_INVALID_VALUE
			break
		error = push(m, direction)
		if error != "":
			break
	if error == "" and _out_count == 0:
		error = E_EMPTY_FRAME
	if error != "":
		clear_frame()
		return PackedByteArray()
	return finish_frame()


func _write_player_state_at(p: int, st: NetPlayerState) -> void:
	_out.encode_u32(p, st.tick)
	_out.encode_u32(p + 4, st.s_mm)
	_out.encode_s16(p + 8, st.d_cm)
	_out.encode_s16(p + 10, st.heading_e4)
	_out.encode_u16(p + 12, st.speed_cms)
	_out.encode_s16(p + 14, st.lat_vel_cms)
	_out.encode_s16(p + 16, st.yaw_rate_mrad_s)
	_out.encode_s16(p + 18, st.steer_e4)
	_out[p + 20] = st.flags
	_out[p + 21] = st.run_state


func _room(n: int) -> bool:
	if _werr != "":
		return false
	if _out_len + n > MAX_FRAME_LEN:
		_werr = E_FRAME_FULL
		return false
	return true


func _wfail(kind: String) -> void:
	if _werr == "":
		_werr = kind


func _write_struct(schema: Array, d: Dictionary) -> void:
	for f: Array in schema:
		if _werr != "":
			return
		var kind: int = f[1]
		var fname: String = f[0]
		if kind == K.UNION and fname == "":
			_write_union(f[2], d)
		elif not d.has(fname):
			_wfail(E_MISSING_FIELD)
		else:
			_write_value(f, d[fname])


func _write_union(variants: Array, d: Dictionary) -> void:
	var kind_name: Variant = d.get("kind")
	if not (kind_name is String):
		_wfail(E_MISSING_FIELD)
		return
	for tag in variants.size():
		var v: Array = variants[tag]
		if v[0] == kind_name:
			if _room(1):
				_out[_out_len] = tag
				_out_len += 1
				_write_struct(v[1], d)
			return
	_wfail(E_INVALID_ENUM)


func _write_value(f: Array, v: Variant) -> void:
	var kind: int = f[1]
	match kind:
		K.U8, K.U16, K.U32, K.I16:
			_write_int(f, v)
		K.BOOL:
			if not (v is bool):
				_wfail(E_INVALID_VALUE)
			elif _room(1):
				_out[_out_len] = 1 if v else 0
				_out_len += 1
		K.ACCOUNT:
			var id := parse_account_id(v)
			if id == -1:
				_wfail(E_INVALID_VALUE)
			elif id == -2:
				_wfail(E_OUT_OF_RANGE)
			elif _room(8):
				_out.encode_s64(_out_len, id)
				_out_len += 8
		K.HASH:
			var raw := map_hash_bytes(v)
			if raw.size() != MAP_HASH_LEN:
				_wfail(E_INVALID_VALUE)
			elif _room(MAP_HASH_LEN):
				for i in MAP_HASH_LEN:
					_out[_out_len + i] = raw[i]
				_out_len += MAP_HASH_LEN
		K.ENUM:
			var names: Array = f[2]
			var idx := names.find(v) if v is String else -1
			if idx < 0:
				_wfail(E_INVALID_ENUM)
			elif _room(1):
				_out[_out_len] = idx
				_out_len += 1
		K.FLAGS:
			if not (v is Dictionary):
				_wfail(E_INVALID_VALUE)
				return
			var bits := flags_to_bits(v, f[2])
			if bits < 0:
				_wfail(E_INVALID_VALUE)
			elif _room(1):
				_out[_out_len] = bits
				_out_len += 1
		K.STR:
			if not (v is String):
				_wfail(E_INVALID_VALUE)
			else:
				_write_str(f[2], v)
		K.STRUCT:
			if not (v is Dictionary):
				_wfail(E_INVALID_VALUE)
			else:
				_write_struct(f[2], v)
		K.UNION:
			if not (v is Dictionary):
				_wfail(E_INVALID_VALUE)
			else:
				_write_union(f[2], v)
		K.LIST:
			if not (v is Array):
				_wfail(E_INVALID_VALUE)
				return
			var items: Array = v
			if items.size() < int(f[3]) or items.size() > int(f[4]):
				_wfail(E_BAD_COUNT)
				return
			if not _room(1):
				return
			_out[_out_len] = items.size()
			_out_len += 1
			var item_spec: Array = f[2]
			for item: Variant in items:
				_write_value(item_spec, item)
				if _werr != "":
					return


func _write_int(f: Array, v: Variant) -> void:
	var n: int
	if v is int:
		n = v
	elif v is float and is_finite(v) and float(v) == floorf(v) and absf(v) < 1.0e18:   # lint: allow-number int64-safe bound
		n = int(v)
	else:
		_wfail(E_INVALID_VALUE)
		return
	var kind: int = f[1]
	var lo := 0
	var hi := 0
	var size := 0
	match kind:
		K.U8:
			hi = 0xFF
			size = 1
		K.U16:
			hi = U16_MAX
			size = 2
		K.U32:
			hi = U32_MAX
			size = 4
		K.I16:
			lo = -32768
			hi = 32767
			size = 2
	if n < lo or n > hi:
		_wfail(E_OUT_OF_RANGE)
		return
	if f[2] != null and (n < int(f[2]) or n > int(f[3])):
		_wfail(E_OUT_OF_RANGE)
		return
	if not _room(size):
		return
	match size:
		1:
			_out[_out_len] = n
		2:
			if kind == K.I16:
				_out.encode_s16(_out_len, n)
			else:
				_out.encode_u16(_out_len, n)
		4:
			_out.encode_u32(_out_len, n)
	_out_len += size


func _write_str(rule_id: int, s: String) -> void:
	var rule: Array = STR_RULES[rule_id]
	var wide: bool = rule[0]
	var nbytes := 0
	var nchars := s.length()
	var bad_char := false
	for i in nchars:
		var c := s.unicode_at(i)
		if c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF):
			_wfail(E_INVALID_UTF8)
			return
		nbytes += _utf8_len(c)
		if not bad_char and not _char_allowed(rule_id, c):
			bad_char = true
	var prefix_max := U16_MAX if wide else 0xFF
	if nbytes > mini(int(rule[1]), prefix_max):
		_wfail(E_STRING_TOO_LONG)
		return
	if nchars < int(rule[2]) or nchars > int(rule[3]):
		_wfail(E_BAD_CHAR_COUNT)
		return
	if bad_char:
		_wfail(E_BAD_CHAR)
		return
	var prefix := 2 if wide else 1
	if not _room(prefix + nbytes):
		return
	if wide:
		_out.encode_u16(_out_len, nbytes)
	else:
		_out[_out_len] = nbytes
	_out_len += prefix
	for i in nchars:
		_put_utf8(s.unicode_at(i))


func _put_utf8(c: int) -> void:
	if c < 0x80:
		_out[_out_len] = c
		_out_len += 1
	elif c < 0x800:
		_out[_out_len] = 0xC0 | (c >> 6)
		_out[_out_len + 1] = 0x80 | (c & 0x3F)
		_out_len += 2
	elif c < 0x10000:
		_out[_out_len] = 0xE0 | (c >> 12)
		_out[_out_len + 1] = 0x80 | ((c >> 6) & 0x3F)
		_out[_out_len + 2] = 0x80 | (c & 0x3F)
		_out_len += 3
	else:
		_out[_out_len] = 0xF0 | (c >> 18)
		_out[_out_len + 1] = 0x80 | ((c >> 12) & 0x3F)
		_out[_out_len + 2] = 0x80 | ((c >> 6) & 0x3F)
		_out[_out_len + 3] = 0x80 | (c & 0x3F)
		_out_len += 4


static func _utf8_len(c: int) -> int:
	if c < 0x80:
		return 1
	if c < 0x800:
		return 2
	if c < 0x10000:
		return 3
	return 4


# ================================================================ Decoding (Dictionaries)

## Decodes a whole frame into vector-JSON Dictionaries. On any error returns [] and sets
## `error` to the kind.
func decode_frame(frame: PackedByteArray, direction: Direction) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	error = _check_frame(frame)
	if error != "":
		return out
	var table := _c2s if direction == Direction.CLIENT_TO_SERVER else _s2c
	var size := frame.size()
	var pos := 0
	var count := 0
	while pos < size:
		var header := _read_header(frame, pos, count)
		if error != "":
			out.clear()
			return out
		var type_id := header & 0xFF
		var plen := header >> 8
		pos += MSG_HEADER_LEN
		count += 1
		if not table.has(type_id):
			error = E_UNKNOWN_TYPE
			out.clear()
			return out
		var entry: Array = table[type_id]
		var msg := _decode_payload(frame, pos, plen, entry)
		if error != "":
			out.clear()
			return out
		out.append(msg)
		pos += plen
	return out


func _check_frame(frame: PackedByteArray) -> String:
	if frame.is_empty():
		return E_EMPTY_FRAME
	if frame.size() > MAX_FRAME_LEN:
		return E_FRAME_TOO_LARGE
	return ""


## Reads the header at `pos`; returns `type | len << 8`, or sets `error`.
func _read_header(frame: PackedByteArray, pos: int, count: int) -> int:
	if count >= MAX_MESSAGES_PER_FRAME:
		error = E_TOO_MANY_MESSAGES
		return 0
	if frame.size() - pos < MSG_HEADER_LEN:
		error = E_TRUNCATED
		return 0
	var plen := frame.decode_u16(pos + 1)
	if frame.size() - pos - MSG_HEADER_LEN < plen:
		error = E_TRUNCATED
		return 0
	return frame[pos] | (plen << 8)


## Generic payload decode (sets `error`).
func _decode_payload(frame: PackedByteArray, start: int, plen: int, entry: Array) -> Dictionary:
	_buf = frame
	_pos = start
	_end = start + plen
	_err = ""
	_verr = ""
	var msg := {"type": entry[0]}
	_read_struct(entry[1], msg)
	if _err != "":
		error = _err
	elif _pos != _end:
		error = E_TRAILING_BYTES
	elif _verr != "":
		error = _verr
	return msg


func _fail(kind: String) -> void:
	if _err == "":
		_err = kind


func _invalid(kind: String) -> void:
	if _verr == "":
		_verr = kind


func _need(n: int) -> bool:
	if _err != "":
		return false
	if _end - _pos < n:
		_err = E_TRUNCATED
		return false
	return true


func _u8() -> int:
	if not _need(1):
		return 0
	_pos += 1
	return _buf[_pos - 1]


func _u16() -> int:
	if not _need(2):
		return 0
	_pos += 2
	return _buf.decode_u16(_pos - 2)


func _u32() -> int:
	if not _need(4):
		return 0
	_pos += 4
	return _buf.decode_u32(_pos - 4)


func _i16() -> int:
	if not _need(2):
		return 0
	_pos += 2
	return _buf.decode_s16(_pos - 2)


func _read_struct(schema: Array, out: Dictionary) -> void:
	for f: Array in schema:
		var kind: int = f[1]
		var fname: String = f[0]
		if kind == K.UNION and fname == "":
			_read_union(f[2], out)
		else:
			out[fname] = _read_value(f)
		if _err != "":
			return


func _read_union(variants: Array, out: Dictionary) -> void:
	var tag := _u8()
	if _err != "":
		return
	if tag >= variants.size():
		_fail(E_INVALID_ENUM)
		return
	var v: Array = variants[tag]
	out["kind"] = v[0]
	_read_struct(v[1], out)


func _read_value(f: Array) -> Variant:
	var kind: int = f[1]
	match kind:
		K.U8, K.U16, K.U32, K.I16:
			var n := 0
			match kind:
				K.U8:
					n = _u8()
				K.U16:
					n = _u16()
				K.U32:
					n = _u32()
				K.I16:
					n = _i16()
			if f[2] != null and (n < int(f[2]) or n > int(f[3])):
				_invalid(E_OUT_OF_RANGE)
			return n
		K.BOOL:
			var b := _u8()
			if b > 1:
				_fail(E_INVALID_BOOL)
			return b == 1
		K.ACCOUNT:
			if not _need(8):
				return "0"
			var id := _buf.decode_s64(_pos)   # u64 above i64::MAX reads negative
			_pos += 8
			if id < 0:
				_invalid(E_OUT_OF_RANGE)
			return str(id)
		K.HASH:
			if not _need(MAP_HASH_LEN):
				return ""
			_pos += MAP_HASH_LEN
			return _buf.slice(_pos - MAP_HASH_LEN, _pos).hex_encode()
		K.ENUM:
			var e := _u8()
			var names: Array = f[2]
			if e >= names.size():
				_fail(E_INVALID_ENUM)
				return ""
			return names[e]
		K.FLAGS:
			var bits := _u8()
			var fnames: Array = f[2]
			if bits >> fnames.size() != 0:
				_fail(E_RESERVED_BITS)
			return bits_to_flags(bits, fnames)
		K.STR:
			return _read_str(f[2])
		K.STRUCT:
			var d := {}
			_read_struct(f[2], d)
			return d
		K.UNION:
			var u := {}
			_read_union(f[2], u)
			return u
		K.LIST:
			var count := _u8()
			var items := []
			var item_spec: Array = f[2]
			for i in count:
				if _err != "":
					break
				items.append(_read_value(item_spec))
			if count < int(f[3]) or count > int(f[4]):
				_invalid(E_BAD_COUNT)
			return items
	_fail(E_INVALID_ENUM)
	return null


func _read_str(rule_id: int) -> String:
	var rule: Array = STR_RULES[rule_id]
	var wide: bool = rule[0]
	var n := _u16() if wide else _u8()
	if not _need(n):
		return ""
	var start := _pos
	_pos += n
	# Structural: strict UTF-8 (Rust std::str::from_utf8), counting code points on the way.
	var i := start
	var nchars := 0
	var ascii := true
	var bad_char := false
	while i < _pos:
		var b0 := _buf[i]
		var c := 0
		var seq_len := 1
		if b0 < 0x80:
			c = b0
		else:
			ascii = false
			c = _utf8_decode_at(i, _pos)
			if c < 0:
				_fail(E_INVALID_UTF8)
				return ""
			seq_len = _utf8_len(c)
		if not bad_char and not _char_allowed(rule_id, c):
			bad_char = true
		nchars += 1
		i += seq_len
	# Validation, in Rust's order: bytes, characters, allowed set.
	if n > int(rule[1]):
		_invalid(E_STRING_TOO_LONG)
	elif nchars < int(rule[2]) or nchars > int(rule[3]):
		_invalid(E_BAD_CHAR_COUNT)
	elif bad_char:
		_invalid(E_BAD_CHAR)
	if ascii:
		return _buf.slice(start, _pos).get_string_from_ascii()
	# Built code point by code point: Godot's UTF-8 parser drops a leading BOM.
	var s := ""
	i = start
	while i < _pos:
		var c := _buf[i] if _buf[i] < 0x80 else _utf8_decode_at(i, _pos)
		s += String.chr(c)
		i += _utf8_len(c)
	return s


## Decodes one multi-byte UTF-8 sequence at `i` (strict: no overlongs, surrogates or code
## points above U+10FFFF). Returns the code point or -1.
func _utf8_decode_at(i: int, end: int) -> int:
	var b0 := _buf[i]
	var extra := 0
	var lo := 0x80
	var hi := 0xBF
	var c := 0
	if b0 >= 0xC2 and b0 <= 0xDF:
		extra = 1
		c = b0 & 0x1F
	elif b0 >= 0xE0 and b0 <= 0xEF:
		extra = 2
		c = b0 & 0x0F
		if b0 == 0xE0:
			lo = 0xA0
		elif b0 == 0xED:
			hi = 0x9F
	elif b0 >= 0xF0 and b0 <= 0xF4:
		extra = 3
		c = b0 & 0x07
		if b0 == 0xF0:
			lo = 0x90
		elif b0 == 0xF4:
			hi = 0x8F
	else:
		return -1
	if end - i <= extra:
		return -1
	for k in range(1, extra + 1):
		var b := _buf[i + k]
		if k == 1:
			if b < lo or b > hi:
				return -1
		elif b < 0x80 or b > 0xBF:
			return -1
		c = (c << 6) | (b & 0x3F)
	return c


## Rust char rules (types.rs): `is_control` is Unicode category Cc.
static func _char_allowed(rule_id: int, c: int) -> bool:
	var control := c < 0x20 or (c >= 0x7F and c <= 0x9F)
	match rule_id:
		Str.NAME, Str.CREW_TAG:
			return not control and not ((c >= 0x200B and c <= 0x200F)
				or (c >= 0x202A and c <= 0x202E) or (c >= 0x2066 and c <= 0x2069) or c == 0xFEFF)
		Str.CODE:
			return c < 0x80 and CODE_ALPHABET.contains(String.chr(c))
		Str.TOKEN:
			return c >= 0x21 and c <= 0x7E
		Str.TEXT:
			return c == 0x0A or not control
	return false


# ================================================================ Decoding (hot path)

## Decodes a server → client frame into `sink` (cleared first): player_states and traffic
## batches into its arrays, everything else into `sink.messages`, with the message order in
## `sink.order_*`. Returns "" or the error kind (the sink's contents are then undefined).
func decode_server_frame_into(frame: PackedByteArray, sink: NetServerFrame) -> String:
	sink.clear()
	error = _check_frame(frame)
	if error != "":
		return error
	var size := frame.size()
	var pos := 0
	var count := 0
	while pos < size:
		var header := _read_header(frame, pos, count)
		if error != "":
			return error
		var type_id := header & 0xFF
		var plen := header >> 8
		pos += MSG_HEADER_LEN
		count += 1
		if not _s2c.has(type_id):
			error = E_UNKNOWN_TYPE
			return error
		var first := 0
		var n := 1
		match type_id:
			MSG_PLAYER_STATES:
				first = sink.ps_count
				n = _fast_player_states(frame, pos, plen, sink)
			MSG_TRAFFIC_SPAWN:
				first = sink.sp_count
				n = _fast_spawns(frame, pos, plen, sink)
			MSG_TRAFFIC_DESPAWN:
				first = sink.ds_count
				n = _fast_despawns(frame, pos, plen, sink)
			MSG_TRAFFIC_INTENT:
				first = sink.in_count
				n = _fast_intents(frame, pos, plen, sink)
			MSG_TRAFFIC_CORRECTION:
				first = sink.co_count
				n = _fast_corrections(frame, pos, plen, sink)
			_:
				first = sink.messages.size()
				var msg := _decode_payload(frame, pos, plen, _s2c[type_id])
				if error == "":
					sink.messages.append(msg)
		if error != "":
			return error
		sink.push_order(type_id, first, n)
		pos += plen
	return ""


## Exact-length check for a fixed-size batch; when it fails the generic decoder produces
## the precise error (Rust reports the first failing byte, which may be an enum before the
## truncation). Returns the entry count, or -1 with `error` set.
func _batch_count(frame: PackedByteArray, pos: int, plen: int, header: int, entry: int,
		type_id: int) -> int:
	if plen >= header + 1:
		var n := frame[pos + header]
		if plen == header + 1 + n * entry:
			return n
	_decode_payload(frame, pos, plen, _s2c[type_id])
	if error == "":
		error = E_TRUNCATED   # unreachable: a length mismatch always fails
	return -1


func _fast_player_states(f: PackedByteArray, pos: int, plen: int, sink: NetServerFrame) -> int:
	var n := _batch_count(f, pos, plen, 0, 2 + PLAYER_STATE_LEN, MSG_PLAYER_STATES)
	if n < 0:
		return 0
	var verr := ""
	var p := pos + 1
	var k := sink.ps_count
	for i in n:
		var flags := f[p + 22]
		if flags & ~PLAYER_FLAGS_MASK != 0:
			error = E_RESERVED_BITS
			return 0
		var rs := f[p + 23]
		if rs >= RUN_STATE.size():
			error = E_INVALID_ENUM
			return 0
		var d := f.decode_s16(p + 10)
		var hd := f.decode_s16(p + 12)
		var sp := f.decode_u16(p + 14)
		var lv := f.decode_s16(p + 16)
		var yr := f.decode_s16(p + 18)
		var st := f.decode_s16(p + 20)
		if verr == "" and (absi(d) > MAX_ABS_D_CM or absi(hd) > MAX_HEADING_E4
				or sp > MAX_SPEED_CMS or absi(lv) > MAX_ABS_I16 or absi(yr) > MAX_ABS_I16
				or absi(st) > MAX_STEER_E4):
			verr = E_OUT_OF_RANGE
		sink.ps_player_id[k] = f.decode_u16(p)
		sink.ps_tick[k] = f.decode_u32(p + 2)
		sink.ps_s_mm[k] = f.decode_u32(p + 6)
		sink.ps_d_cm[k] = d
		sink.ps_heading_e4[k] = hd
		sink.ps_speed_cms[k] = sp
		sink.ps_lat_vel_cms[k] = lv
		sink.ps_yaw_rate_mrad_s[k] = yr
		sink.ps_steer_e4[k] = st
		sink.ps_flags[k] = flags
		sink.ps_run_state[k] = rs
		p += 2 + PLAYER_STATE_LEN
		k += 1
	if verr == "" and (n < 1 or n > MAX_ROOM_PLAYERS):
		verr = E_BAD_COUNT
	error = verr
	sink.ps_count = k
	return n


func _fast_spawns(f: PackedByteArray, pos: int, plen: int, sink: NetServerFrame) -> int:
	var n := _batch_count(f, pos, plen, 0, NetServerFrame.SPAWN_LEN, MSG_TRAFFIC_SPAWN)
	if n < 0:
		return 0
	var verr := ""
	var p := pos + 1
	var k := sink.sp_count
	for i in n:
		var phase := f[p + 14]
		if phase >= LC_PHASE.size():
			error = E_INVALID_ENUM
			return 0
		var flags := f[p + 22]
		if flags & ~TRAFFIC_FLAGS_MASK != 0:
			error = E_RESERVED_BITS
			return 0
		var lane := f[p + 5]
		var d := f.decode_s16(p + 10)
		var sp := f.decode_u16(p + 12)
		var target := f[p + 15]
		if verr == "" and (lane > MAX_LANE or absi(d) > MAX_ABS_D_CM or sp > MAX_SPEED_CMS
				or target > MAX_LANE):
			verr = E_OUT_OF_RANGE
		sink.sp_car_id[k] = f.decode_u16(p)
		sink.sp_vehicle[k] = f[p + 2]
		sink.sp_color[k] = f[p + 3]
		sink.sp_profile[k] = f[p + 4]
		sink.sp_lane[k] = lane
		sink.sp_s_mm[k] = f.decode_u32(p + 6)
		sink.sp_d_cm[k] = d
		sink.sp_speed_cms[k] = sp
		sink.sp_lc_phase[k] = phase
		sink.sp_lc_target_lane[k] = target
		sink.sp_lc_move_start_tick[k] = f.decode_u32(p + 16)
		sink.sp_lc_duration_ms[k] = f.decode_u16(p + 20)
		sink.sp_flags[k] = flags
		p += NetServerFrame.SPAWN_LEN
		k += 1
	if verr == "" and (n < 1 or n > MAX_TRAFFIC_BATCH):
		verr = E_BAD_COUNT
	error = verr
	sink.sp_count = k
	return n


func _fast_despawns(f: PackedByteArray, pos: int, plen: int, sink: NetServerFrame) -> int:
	var n := _batch_count(f, pos, plen, 0, 2, MSG_TRAFFIC_DESPAWN)
	if n < 0:
		return 0
	var p := pos + 1
	var k := sink.ds_count
	for i in n:
		sink.ds_car_id[k] = f.decode_u16(p)
		p += 2
		k += 1
	error = E_BAD_COUNT if n < 1 or n > MAX_TRAFFIC_BATCH else ""
	sink.ds_count = k
	return n


func _fast_intents(f: PackedByteArray, pos: int, plen: int, sink: NetServerFrame) -> int:
	var n := _batch_count(f, pos, plen, 0, NetServerFrame.INTENT_LEN, MSG_TRAFFIC_INTENT)
	if n < 0:
		return 0
	var verr := ""
	var p := pos + 1
	var k := sink.in_count
	for i in n:
		var kind := f[p + 2]
		if kind >= INTENT_KIND.size():
			error = E_INVALID_ENUM
			return 0
		var target := f[p + 11]
		if verr == "" and target > MAX_LANE:
			verr = E_OUT_OF_RANGE
		sink.in_car_id[k] = f.decode_u16(p)
		sink.in_kind[k] = kind
		sink.in_start_tick[k] = f.decode_u32(p + 3)
		sink.in_move_start_tick[k] = f.decode_u32(p + 7)
		sink.in_target_lane[k] = target
		sink.in_duration_ms[k] = f.decode_u16(p + 12)
		p += NetServerFrame.INTENT_LEN
		k += 1
	if verr == "" and (n < 1 or n > MAX_INTENT_BATCH):
		verr = E_BAD_COUNT
	error = verr
	sink.in_count = k
	return n


func _fast_corrections(f: PackedByteArray, pos: int, plen: int, sink: NetServerFrame) -> int:
	var n := _batch_count(f, pos, plen, 4, NetServerFrame.CORRECTION_LEN,
		MSG_TRAFFIC_CORRECTION)
	if n < 0:
		return 0
	var verr := ""
	var tick := f.decode_u32(pos)
	var p := pos + 5
	var k := sink.co_count
	for i in n:
		var d := f.decode_s16(p + 6)
		var sp := f.decode_u16(p + 8)
		if verr == "" and (absi(d) > MAX_ABS_D_CM or sp > MAX_SPEED_CMS):
			verr = E_OUT_OF_RANGE
		sink.co_tick[k] = tick
		sink.co_car_id[k] = f.decode_u16(p)
		sink.co_s_mm[k] = f.decode_u32(p + 2)
		sink.co_d_cm[k] = d
		sink.co_speed_cms[k] = sp
		p += NetServerFrame.CORRECTION_LEN
		k += 1
	if verr == "" and (n < 1 or n > MAX_TRAFFIC_BATCH):
		verr = E_BAD_COUNT
	error = verr
	sink.co_count = k
	return n


# ================================================================ Field helpers

## Account id from a decimal String (or a non-negative int). Returns the id, -1 when the
## value is not a decimal integer, -2 when it exceeds 2^63 − 1 (out_of_range).
static func parse_account_id(v: Variant) -> int:
	if v is int:
		return v if int(v) >= 0 else -1
	if not (v is String):
		return -1
	var s: String = v
	if s.is_empty() or s.length() > 20:   # lint: allow-number digits of u64::MAX
		return -1
	var limit_div := MAX_ACCOUNT_ID_DIV10
	var limit_mod := MAX_ACCOUNT_ID % 10   # lint: allow-number decimal
	var n := 0
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 0x30 or c > 0x39:
			return -1
		var digit := c - 0x30
		if n > limit_div or (n == limit_div and digit > limit_mod):
			# Still a valid decimal: finish checking the syntax before saying "too large".
			for j in range(i + 1, s.length()):
				if s.unicode_at(j) < 0x30 or s.unicode_at(j) > 0x39:
					return -1
			return -2
		n = n * 10 + digit   # lint: allow-number decimal
	return n


## The 32 raw bytes of a map hash given as 64 hex characters (either case) or as bytes.
## Empty when invalid.
static func map_hash_bytes(v: Variant) -> PackedByteArray:
	if v is PackedByteArray:
		return v if (v as PackedByteArray).size() == MAP_HASH_LEN else PackedByteArray()
	if not (v is String):
		return PackedByteArray()
	return hex_to_bytes(v, MAP_HASH_LEN)


## Parses hex text (even length, no separators). Empty when invalid or not `expect_len`
## bytes long (`expect_len` < 0: any length).
static func hex_to_bytes(text: String, expect_len: int = -1) -> PackedByteArray:
	var out := PackedByteArray()
	if text.length() % 2 != 0:
		return out
	var n := text.length() >> 1
	if expect_len >= 0 and n != expect_len:
		return out
	out.resize(n)
	for i in n:
		var hi := _hex_digit(text.unicode_at(2 * i))
		var lo := _hex_digit(text.unicode_at(2 * i + 1))
		if hi < 0 or lo < 0:
			return PackedByteArray()
		out[i] = (hi << 4) | lo
	return out


static func _hex_digit(c: int) -> int:
	if c >= 0x30 and c <= 0x39:
		return c - 0x30
	if c >= 0x61 and c <= 0x66:
		return c - 0x61 + 10   # lint: allow-number hex digit value
	if c >= 0x41 and c <= 0x46:
		return c - 0x41 + 10   # lint: allow-number hex digit value
	return -1


## Flag Dictionary → bits (missing names are false). -1 when a value is not a bool.
static func flags_to_bits(d: Dictionary, names: Array) -> int:
	var bits := 0
	for i in names.size():
		var v: Variant = d.get(names[i], false)
		if not (v is bool):
			return -1
		if v:
			bits |= 1 << i
	return bits


static func bits_to_flags(bits: int, names: Array) -> Dictionary:
	var d := {}
	for i in names.size():
		d[names[i]] = bits & (1 << i) != 0
	return d


# ================================================================ Quantization (quant.rs)
# `wire = round(value × scale)` (half away from zero), then the field's range rule.
# Non-finite input → QUANT_INVALID ("not_finite"); `s` outside u32 → QUANT_INVALID.

## `s` (m) → mm. Rejects values that round outside 0..=u32::MAX (wrap s into [0, L) first).
static func s_to_wire(s_m: float) -> int:
	if not is_finite(s_m):
		return QUANT_INVALID
	var q := roundf(s_m * S_PER_M)
	if q < 0.0 or q > float(U32_MAX):
		return QUANT_INVALID
	return int(q)


static func s_from_wire(mm: int) -> float:
	return mm / S_PER_M


## `d` (m, + = left) → cm, clamped to ±100 m.
static func d_to_wire(d_m: float) -> int:
	return _clamp_round(d_m, D_PER_M, -MAX_ABS_D_CM, MAX_ABS_D_CM)


static func d_from_wire(cm: int) -> float:
	return cm / D_PER_M


## Speed (m/s) → cm/s, clamped to 0..=200 m/s.
static func speed_to_wire(v_mps: float) -> int:
	return _clamp_round(v_mps, SPEED_PER_MPS, 0, MAX_SPEED_CMS)


static func speed_from_wire(cms: int) -> float:
	return cms / SPEED_PER_MPS


## Heading vs road (rad) → 1e-4 rad. Values beyond ±3.14165 wrap by whole turns into
## [-π, π], then clamp to ±31,416 (every wire value round-trips).
static func heading_to_wire(rad: float) -> int:
	if not is_finite(rad):
		return QUANT_INVALID
	var keep := (MAX_HEADING_E4 + 0.5) / HEADING_PER_RAD
	var wrapped := rad
	if absf(rad) >= keep:
		wrapped = rad - TAU * roundf(rad / TAU)
	return int(clampf(roundf(wrapped * HEADING_PER_RAD), -MAX_HEADING_E4, MAX_HEADING_E4))


static func heading_from_wire(e4: int) -> float:
	return e4 / HEADING_PER_RAD


## Lateral velocity (m/s) → cm/s, clamped to ±327.67 m/s.
static func lat_vel_to_wire(v_mps: float) -> int:
	return _clamp_round(v_mps, LAT_VEL_PER_MPS, -MAX_ABS_I16, MAX_ABS_I16)


static func lat_vel_from_wire(cms: int) -> float:
	return cms / LAT_VEL_PER_MPS


## Yaw rate (rad/s) → mrad/s, clamped to ±32.767 rad/s.
static func yaw_rate_to_wire(rad_s: float) -> int:
	return _clamp_round(rad_s, YAW_RATE_PER_RAD_S, -MAX_ABS_I16, MAX_ABS_I16)


static func yaw_rate_from_wire(mrad_s: int) -> float:
	return mrad_s / YAW_RATE_PER_RAD_S


## Steering input (-1..1) → 1e-4, clamped to ±1.0.
static func steer_to_wire(steer: float) -> int:
	return _clamp_round(steer, STEER_PER_UNIT, -MAX_STEER_E4, MAX_STEER_E4)


static func steer_from_wire(e4: int) -> float:
	return e4 / STEER_PER_UNIT


## Clearance (m) → mm, clamped to 0..=65.535 m.
static func clearance_to_wire(m: float) -> int:
	return _clamp_round(m, CLEARANCE_PER_M, 0, U16_MAX)


static func clearance_from_wire(mm: int) -> float:
	return mm / CLEARANCE_PER_M


## Multiplier (×) → ×1e-3, clamped to 0..=u32::MAX.
static func multiplier_to_wire(x: float) -> int:
	return _clamp_round(x, MULTIPLIER_PER_UNIT, 0, U32_MAX)


static func multiplier_from_wire(milli: int) -> float:
	return milli / MULTIPLIER_PER_UNIT


static func _clamp_round(v: float, scale: float, lo: int, hi: int) -> int:
	if not is_finite(v):
		return QUANT_INVALID
	return int(clampf(roundf(v * scale), float(lo), float(hi)))


## Field-name dispatch for table-driven tests (names as in vectors/quantization.json).
static func quantize(field: String, value: float) -> int:
	match field:
		"s":
			return s_to_wire(value)
		"d":
			return d_to_wire(value)
		"speed":
			return speed_to_wire(value)
		"heading":
			return heading_to_wire(value)
		"lat_vel":
			return lat_vel_to_wire(value)
		"yaw_rate":
			return yaw_rate_to_wire(value)
		"steer":
			return steer_to_wire(value)
		"clearance":
			return clearance_to_wire(value)
		"multiplier":
			return multiplier_to_wire(value)
	return QUANT_INVALID


static func dequantize(field: String, wire: int) -> float:
	match field:
		"s":
			return s_from_wire(wire)
		"d":
			return d_from_wire(wire)
		"speed":
			return speed_from_wire(wire)
		"heading":
			return heading_from_wire(wire)
		"lat_vel":
			return lat_vel_from_wire(wire)
		"yaw_rate":
			return yaw_rate_from_wire(wire)
		"steer":
			return steer_from_wire(wire)
		"clearance":
			return clearance_from_wire(wire)
		"multiplier":
			return multiplier_from_wire(wire)
	return NAN


## Why `quantize(field, value)` failed: "not_finite", "out_of_range", or "".
static func quant_error(field: String, value: float) -> String:
	if not is_finite(value):
		return E_NOT_FINITE
	if quantize(field, value) == QUANT_INVALID:
		return E_OUT_OF_RANGE
	return ""


# ================================================================ Schema tables

static func type_name(type_id: int, direction: Direction) -> String:
	_ensure_schema()
	var table := _c2s if direction == Direction.CLIENT_TO_SERVER else _s2c
	return String((table[type_id] as Array)[0]) if table.has(type_id) else ""


static func type_id_of(type_name_: String, direction: Direction) -> int:
	_ensure_schema()
	var ids := _c2s_ids if direction == Direction.CLIENT_TO_SERVER else _s2c_ids
	return int(ids.get(type_name_, -1))


static func _f(fname: String, kind: int, a: Variant = null, b: Variant = null,
		c: Variant = null) -> Array:
	return [fname, kind, a, b, c]


static func _list(fname: String, item: Array, lo: int, hi: int) -> Array:
	return [fname, K.LIST, item, lo, hi]


static func _ensure_schema() -> void:
	if not _c2s.is_empty():
		return
	var account := _f("account_id", K.ACCOUNT)
	var code := _f("code", K.STR, Str.CODE)
	var player_ref: Array = [_f("player_id", K.U16)]
	var identity: Array = [account, _f("display_name", K.STR, Str.NAME),
		_f("name_tag", K.U16, 0, MAX_NAME_TAG)]
	var settings: Array = [
		_f("visibility", K.ENUM, VISIBILITY), _f("max_players", K.U8, 1, MAX_ROOM_PLAYERS),
		_f("density", K.ENUM, DENSITY), _f("time_mode", K.ENUM, TIME_MODE),
		_f("fixed_cycle_ms", K.U32),
	]
	var clock: Array = [_f("cycle_ms", K.U32), _f("cycle_len_ms", K.U32),
		_f("day_len_ms", K.U32)]
	var player_state: Array = [
		_f("tick", K.U32), _f("s_mm", K.U32), _f("d_cm", K.I16, -MAX_ABS_D_CM, MAX_ABS_D_CM),
		_f("heading_e4", K.I16, -MAX_HEADING_E4, MAX_HEADING_E4),
		_f("speed_cms", K.U16, 0, MAX_SPEED_CMS),
		_f("lat_vel_cms", K.I16, -MAX_ABS_I16, MAX_ABS_I16),
		_f("yaw_rate_mrad_s", K.I16, -MAX_ABS_I16, MAX_ABS_I16),
		_f("steer_e4", K.I16, -MAX_STEER_E4, MAX_STEER_E4),
		_f("flags", K.FLAGS, PLAYER_FLAGS), _f("run_state", K.ENUM, RUN_STATE),
	]
	var chat_item: Array = [
		["phrase", [_f("phrase", K.ENUM, PHRASE)]],
		["horn", []],
		["emote", [_f("emote", K.U8, 0, MAX_EMOTE)]],
	]
	var member: Array = [
		_f("player_id", K.U16), _f("identity", K.STRUCT, identity),
		_f("crew_tag", K.STR, Str.CREW_TAG), _f("crew_slot", K.U8, 0, MAX_CREW_SLOT),
		_f("flags", K.FLAGS, MEMBER_FLAGS),
	]
	var crew: Array = [_f("crew_slot", K.U8, 0, MAX_CREW_SLOT), _f("color", K.U8),
		_f("session_total", K.U32)]

	# ------------------------------------------------ Client → server
	_add(_c2s, _c2s_ids, MSG_HELLO, "hello", [
		_f("protocol_version", K.U16), _f("client_build", K.U32), _f("map_hash", K.HASH),
		_f("access_token", K.STR, Str.TOKEN),
	])
	_add(_c2s, _c2s_ids, MSG_PING, "ping", [_f("client_time_ms", K.U32)])
	_add(_c2s, _c2s_ids, MSG_LOBBY_COMMAND, "lobby_command", [_f("", K.UNION, [
		["party_create", []],
		["party_invite", [account]],
		["party_join", [code]],
		["party_leave", []],
		["party_kick", [account]],
		["presence_subscribe", [_f("enabled", K.BOOL)]],
		["room_create", settings],
		["room_join_code", [code]],
		["room_join_id", [_f("room_id", K.U32)]],
		["room_leave", []],
		["quick_join", []],
		["room_browse", []],
	])])
	_add(_c2s, _c2s_ids, MSG_PLAYER_STATE, "player_state", player_state)
	_add(_c2s, _c2s_ids, MSG_SCORE_CLAIM, "score_claim", [
		_f("claim_id", K.U16), _f("tick", K.U32), _f("kind", K.ENUM, CLAIM_KIND),
		_f("side", K.ENUM, SIDE),
		_list("cars", _f("", K.STRUCT, [_f("car_id", K.U16), _f("clearance_mm", K.U16)]),
			1, MAX_CLAIM_CARS),
	])
	_add(_c2s, _c2s_ids, MSG_HIT_REPORT, "hit_report", [
		_f("tick", K.U32), _f("target", K.ENUM, HIT_TARGET), _f("car_id", K.U16),
		_f("lives_left", K.U8),
	])
	_add(_c2s, _c2s_ids, MSG_RUN_EVENT, "run_event", [
		_f("kind", K.ENUM, RUN_EVENT_KIND), _f("tick", K.U32),
	])
	_add(_c2s, _c2s_ids, MSG_QUICK_CHAT, "quick_chat", [_f("item", K.UNION, chat_item)])
	_add(_c2s, _c2s_ids, MSG_ROOM_HOST_COMMAND, "room_host_command", [_f("", K.UNION, [
		["kick", player_ref],
		["set_density", [_f("density", K.ENUM, DENSITY)]],
		["set_time_mode", [_f("time_mode", K.ENUM, TIME_MODE), _f("fixed_cycle_ms", K.U32)]],
	])])

	# ------------------------------------------------ Server → client
	_add(_s2c, _s2c_ids, MSG_WELCOME, "welcome", [
		_f("protocol_version", K.U16), _f("server_build", K.U32), account,
		_f("tick_rate_hz", K.U8, 1, MAX_TICK_RATE_HZ), _f("ping_interval_ms", K.U16),
		_f("timeout_ms", K.U16), _f("max_frame_bytes", K.U16),
	])
	_add(_s2c, _s2c_ids, MSG_PONG, "pong", [
		_f("client_time_ms", K.U32), _f("server_tick", K.U32), _f("tick_fraction", K.U16),
	])
	_add(_s2c, _s2c_ids, MSG_ERROR, "error", [
		_f("code", K.ENUM, ERROR_CODE), _f("fatal", K.BOOL), _f("detail", K.STR, Str.TEXT),
	])
	_add(_s2c, _s2c_ids, MSG_LOBBY_EVENT, "lobby_event", [_f("", K.UNION, [
		["party_state", [code, _f("leader", K.ACCOUNT),
			_list("members", _f("", K.STRUCT, identity), 1, MAX_PARTY_MEMBERS)]],
		["party_left", [_f("reason", K.ENUM, PARTY_LEFT_REASON)]],
		["party_invite", [_f("from", K.STRUCT, identity), code]],
		["presence", [_list("friends", _f("", K.STRUCT, [
			account, _f("status", K.ENUM, PRESENCE_STATUS), _f("room_id", K.U32),
			_f("joinable", K.BOOL)]), 0, MAX_PRESENCE_BATCH)]],
		["room_list", [_list("rooms", _f("", K.STRUCT, [
			_f("room_id", K.U32), _f("players", K.U8, 0, MAX_ROOM_PLAYERS),
			_f("max_players", K.U8, 1, MAX_ROOM_PLAYERS), _f("density", K.ENUM, DENSITY),
			_f("night", K.BOOL)]), 0, MAX_ROOM_LIST)]],
		["room_left", [_f("reason", K.ENUM, ROOM_LEFT_REASON)]],
	])])
	_add(_s2c, _s2c_ids, MSG_ROOM_SNAPSHOT, "room_snapshot", [
		_f("room_id", K.U32), code, _f("settings", K.STRUCT, settings), _f("tick", K.U32),
		_f("clock", K.STRUCT, clock), _f("you", K.U16),
		_list("members", _f("", K.STRUCT, member), 1, MAX_ROOM_PLAYERS),
		_list("crews", _f("", K.STRUCT, crew), 0, MAX_CREWS),
	])
	_add(_s2c, _s2c_ids, MSG_PLAYER_STATES, "player_states", [
		_list("players", _f("", K.STRUCT, [_f("player_id", K.U16),
			_f("state", K.STRUCT, player_state)]), 1, MAX_ROOM_PLAYERS),
	])
	_add(_s2c, _s2c_ids, MSG_TRAFFIC_SPAWN, "traffic_spawn", [
		_list("cars", _f("", K.STRUCT, [
			_f("car_id", K.U16), _f("vehicle", K.U8), _f("color", K.U8), _f("profile", K.U8),
			_f("lane", K.U8, 0, MAX_LANE), _f("s_mm", K.U32),
			_f("d_cm", K.I16, -MAX_ABS_D_CM, MAX_ABS_D_CM),
			_f("speed_cms", K.U16, 0, MAX_SPEED_CMS), _f("lc_phase", K.ENUM, LC_PHASE),
			_f("lc_target_lane", K.U8, 0, MAX_LANE), _f("lc_move_start_tick", K.U32),
			_f("lc_duration_ms", K.U16), _f("flags", K.FLAGS, TRAFFIC_FLAGS),
		]), 1, MAX_TRAFFIC_BATCH),
	])
	_add(_s2c, _s2c_ids, MSG_TRAFFIC_DESPAWN, "traffic_despawn", [
		_list("car_ids", _f("", K.U16), 1, MAX_TRAFFIC_BATCH),
	])
	_add(_s2c, _s2c_ids, MSG_TRAFFIC_INTENT, "traffic_intent", [
		_list("intents", _f("", K.STRUCT, [
			_f("car_id", K.U16), _f("kind", K.ENUM, INTENT_KIND), _f("start_tick", K.U32),
			_f("move_start_tick", K.U32), _f("target_lane", K.U8, 0, MAX_LANE),
			_f("duration_ms", K.U16),
		]), 1, MAX_INTENT_BATCH),
	])
	_add(_s2c, _s2c_ids, MSG_TRAFFIC_CORRECTION, "traffic_correction", [
		_f("tick", K.U32),
		_list("cars", _f("", K.STRUCT, [
			_f("car_id", K.U16), _f("s_mm", K.U32),
			_f("d_cm", K.I16, -MAX_ABS_D_CM, MAX_ABS_D_CM),
			_f("speed_cms", K.U16, 0, MAX_SPEED_CMS),
		]), 1, MAX_TRAFFIC_BATCH),
	])
	_add(_s2c, _s2c_ids, MSG_SCORE_SYNC, "score_sync", [
		_f("tick", K.U32), _f("run_seq", K.U16), _f("banked", K.U32), _f("chain", K.U32),
		_f("multiplier_milli", K.U32), _f("lives", K.U8),
		_f("crew_in_range", K.U8, 0, MAX_ROOM_PLAYERS), _f("flags", K.FLAGS, SCORE_FLAGS),
	])
	_add(_s2c, _s2c_ids, MSG_SCORE_EVENT, "score_event", [
		_f("tick", K.U32), _f("player_id", K.U16), _f("kind", K.ENUM, SCORE_EVENT_KIND),
		_f("points", K.U32), _f("multiplier_gain_milli", K.U32), _f("link", K.U8),
		_f("sector", K.U8), _f("ref_id", K.U16),
	])
	_add(_s2c, _s2c_ids, MSG_RUN_RESULT, "run_result", [
		_f("player_id", K.U16), _f("run_seq", K.U16), _f("end_reason", K.ENUM, RUN_END_REASON),
		_f("flags", K.FLAGS, RUN_RESULT_FLAGS), _f("score", K.U32), _f("duration_ms", K.U32),
		_f("distance_m", K.U32), _f("passes", K.U16), _f("close_passes", K.U16),
		_f("cuts", K.U16), _f("threads", K.U16), _f("trains", K.U16),
		_f("max_multiplier_milli", K.U32),
	])
	_add(_s2c, _s2c_ids, MSG_ROOM_EVENT, "room_event", [_f("", K.UNION, [
		["join", member],
		["leave", [_f("player_id", K.U16), _f("reason", K.ENUM, LEAVE_REASON)]],
		["host_change", player_ref],
		["kick", player_ref],
		["settings", [_f("tick", K.U32), _f("settings", K.STRUCT, settings),
			_f("clock", K.STRUCT, clock)]],
		["crew", crew],
		["connection", [_f("player_id", K.U16), _f("connected", K.BOOL)]],
	])])
	_add(_s2c, _s2c_ids, MSG_QUICK_CHAT_RELAY, "quick_chat", [
		_f("player_id", K.U16), _f("item", K.UNION, chat_item),
	])
	_add(_s2c, _s2c_ids, MSG_SERVER_NOTICE, "server_notice", [
		_f("kind", K.ENUM, NOTICE_KIND), _f("seconds", K.U16), _f("text", K.STR, Str.TEXT),
	])


static func _add(table: Dictionary, ids: Dictionary, type_id: int, type_name_: String,
		schema: Array) -> void:
	table[type_id] = [type_name_, schema]
	ids[type_name_] = type_id
