class_name NetReplayFile
extends RefCounted
## One single-player run replay (`.wbr`): the header, the 30 Hz path and inputs, the exact
## boost edges and discontinuities, and the client's event log. Spec: multiplayer handoff
## → Leaderboards (single-player runs, step 3: "the player's path (s, d, speed, heading at
## 30 Hz), inputs at 30 Hz, the client's event log; about 100 KB compressed for a 10-minute
## run"), Tuning reference (replay sample rate 30 Hz). WP N8.1. The byte layout is
## specified in docs/REPLAY_FORMAT.md (the verifier and the server read it); this class
## is its only GDScript reader and writer.
##
## Values are quantized once, when appended (the columns hold wire integers), so what the
## recorder keeps in memory is exactly what the file holds:
##   s, d 10 µm · yaw (heading vs road) 1e-6 rad · v, v_lat 0.1 mm/s · steer, throttle,
##   brake 1e-4 · event clearance 1 mm.
## (Finer than the protocol's: playback interpolates between samples and traffic reacts
## to the result, so every micrometre of error is a chance for a traffic decision to flip.)
## The body is column-major (every sample's tick, then every s, ...), each column delta or
## delta-of-delta coded as zigzag varints, then gzip (PackedByteArray.compress,
## COMPRESSION_GZIP; Godot's gzip is in every export, the web included, and the format
## stays readable with standard tools). The header stays uncompressed so the server can
## check it and the client can patch `run_id` in place (RUN_ID_OFFSET) once the receipt
## names the run.

const MAGIC := "WBR1"
const VERSION := 1
## Fixed header bytes before the car id (docs/REPLAY_FORMAT.md → Header).
const FIXED_HEADER := 77
const RUN_ID_OFFSET := 8
const DATE_LEN := 10
const CAR_MAX := 32
const COMPRESSION_GZIP := 1

const MODE_JOURNEY := 1
const MODE_DAILY := 2

## Quantization scales (wire = round(value × scale)).
const Q_POS := 100000.0     ## 10 µm
const Q_YAW := 1000000.0    ## 1e-6 rad
const Q_SPEED := 10000.0    ## 0.1 mm/s
const Q_INPUT := 10000.0    ## 1e-4
const Q_CLEARANCE := 1000.0 ## 1 mm
const Q_MULTIPLIER := 1000.0

## Sample flags.
const FLAG_BOOST_ACTIVE := 1        ## boost running after this tick
const FLAG_BOOST_REQUEST := 2       ## a boost was requested in the window ending here
const FLAG_RESET := 4               ## the run put the car back in a lane this tick (safety net)
const FLAG_FORK_SWAP := 8           ## the road swapped to a fork's right branch this tick (d moved)
const FLAG_FINAL := 16              ## the last sample (the run-ending tick)

## Event kinds (u8 on the wire). Tags go through the file's string table.
enum Kind {
	SCORED = 1,        ## tag = pass/close_pass/cut/thread, points, value = multiplier × 1000, clearance
	HIT = 2,           ## tag = source, value = lives left
	BANKED = 3,        ## tag = reason, points = amount, value = banked total
	CHAIN_LOST = 4,    ## tag = reason, points = amount
	BONUS = 5,         ## tag = bonus kind, points, value = banked total
	CHECKPOINT = 6,    ## value = leg index
	BOOST_ON = 7,      ## exact tick the boost started
	BOOST_OFF = 8,     ## exact tick it ended
	FORK_SWAP = 9,     ## value = the lateral shift (d moved by −shift), 0.1 mm
	RESET = 10,        ## the safety net put the car back in a lane
	TRAFFIC = 11,      ## value = traffic_fingerprint() after this tick (once a second)
}

const ZIGZAG_SHIFT := 63
const VARINT_MASK := 0x7F
const VARINT_MORE := 0x80
const VARINT_BITS := 7
const BYTE_MASK := 0xFF
const U16 := 2
const U32 := 4
const U64 := 8

# ---- header ----
var run_id: int = 0
var seed_value: int = 0
var client_build: int = 0
var tuning_hash: int = 0
## MODE_JOURNEY / MODE_DAILY.
var mode: int = MODE_JOURNEY
var tick_hz: int = 120
var sample_ticks: int = 4
## The UTC date the run was played ("YYYY-MM-DD"; Daily: the seed's date).
var date: String = ""
var car: String = ""
## Summary (the client's claims): RUNNING ticks, banked score, counted hits, distance.
var ticks: int = 0
var score: int = 0
var hits: int = 0
var distance_mm: int = 0

# ---- samples (wire integers) ----
var sample_count: int = 0
var tick := PackedInt64Array()
var s_q := PackedInt64Array()
var d_q := PackedInt64Array()
var yaw_q := PackedInt64Array()
var v_q := PackedInt64Array()
var vlat_q := PackedInt64Array()
var steer_q := PackedInt64Array()
var throttle_q := PackedInt64Array()
var brake_q := PackedInt64Array()
var flags := PackedInt64Array()

# ---- events ----
var event_count: int = 0
var ev_tick := PackedInt64Array()
var ev_kind := PackedInt64Array()
var ev_tag := PackedInt64Array()
var ev_points := PackedInt64Array()
var ev_clearance := PackedInt64Array()
var ev_value := PackedInt64Array()
var tags := PackedStringArray()

var _tag_index: Dictionary[String, int] = {}


# ---------------------------------------------------------------- Building

## Reserves room for `samples` samples and `events` events (grows by doubling after).
func reserve(samples: int, events: int) -> void:
	_grow_samples(maxi(samples, 1))
	_grow_events(maxi(events, 1))


## Appends one sample (physical units in, quantized here). `brake` is the window's largest.
func add_sample(t: int, s: float, d: float, yaw: float, v: float, v_lat: float, steer: float,
		throttle: float, brake: float, sample_flags: int) -> void:
	if sample_count >= tick.size():
		_grow_samples(maxi(tick.size() * 2, 1))
	var i := sample_count
	tick[i] = t
	s_q[i] = roundi(s * Q_POS)
	d_q[i] = roundi(d * Q_POS)
	yaw_q[i] = roundi(yaw * Q_YAW)
	v_q[i] = roundi(v * Q_SPEED)
	vlat_q[i] = roundi(v_lat * Q_SPEED)
	steer_q[i] = roundi(clampf(steer, -1.0, 1.0) * Q_INPUT)
	throttle_q[i] = roundi(clampf(throttle, 0.0, 1.0) * Q_INPUT)
	brake_q[i] = roundi(clampf(brake, 0.0, 1.0) * Q_INPUT)
	flags[i] = sample_flags
	sample_count += 1


## Appends one event. `clearance_m` < 0 = none.
func add_event(t: int, kind: Kind, tag: String, points: int, value: int, clearance_m: float = -1.0) -> void:
	if event_count >= ev_tick.size():
		_grow_events(maxi(ev_tick.size() * 2, 1))
	var i := event_count
	ev_tick[i] = t
	ev_kind[i] = kind
	ev_tag[i] = tag_id(tag)
	ev_points[i] = points
	ev_value[i] = value
	ev_clearance[i] = roundi(clearance_m * Q_CLEARANCE) if clearance_m >= 0.0 else -1
	event_count += 1


## The string table index of `tag` (added on first use).
func tag_id(tag: String) -> int:
	if _tag_index.has(tag):
		return _tag_index[tag]
	var id := tags.size()
	tags.append(tag)
	_tag_index[tag] = id
	return id


func tag_of(event: int) -> String:
	var id := int(ev_tag[event])
	return tags[id] if id >= 0 and id < tags.size() else ""


## Removes event `i` (tests: tampering).
func remove_event(i: int) -> void:
	for col: PackedInt64Array in [ev_tick, ev_kind, ev_tag, ev_points, ev_clearance, ev_value]:
		col.remove_at(i)
		col.append(0)
	event_count -= 1


func mode_name() -> StringName:
	return RunContext.MODE_DAILY if mode == MODE_DAILY else RunContext.MODE_JOURNEY


static func mode_id(run_mode: StringName) -> int:
	return MODE_DAILY if run_mode == RunContext.MODE_DAILY else MODE_JOURNEY


# ---- physical accessors (verifier) ----

func s_at(i: int) -> float:
	return float(s_q[i]) / Q_POS


func d_at(i: int) -> float:
	return float(d_q[i]) / Q_POS


func yaw_at(i: int) -> float:
	return float(yaw_q[i]) / Q_YAW


func v_at(i: int) -> float:
	return float(v_q[i]) / Q_SPEED


func vlat_at(i: int) -> float:
	return float(vlat_q[i]) / Q_SPEED


func steer_at(i: int) -> float:
	return float(steer_q[i]) / Q_INPUT


func throttle_at(i: int) -> float:
	return float(throttle_q[i]) / Q_INPUT


func brake_at(i: int) -> float:
	return float(brake_q[i]) / Q_INPUT


# ---------------------------------------------------------------- Encoding

## The whole file: the header, then the gzip'd body.
func encode() -> PackedByteArray:
	var body := _encode_body()
	var packed := body.compress(FileAccess.COMPRESSION_GZIP)
	var car_bytes := car.to_ascii_buffer()
	if car_bytes.size() > CAR_MAX:
		car_bytes = car_bytes.slice(0, CAR_MAX)
	var header_len := FIXED_HEADER + car_bytes.size()
	var out := PackedByteArray()
	out.resize(header_len)
	var m := MAGIC.to_ascii_buffer()
	for i in m.size():
		out[i] = m[i]
	out.encode_u16(4, VERSION)
	out.encode_u16(6, header_len)
	out.encode_s64(RUN_ID_OFFSET, run_id)
	out.encode_s64(16, seed_value)
	out.encode_u32(24, client_build)
	out.encode_u32(28, tuning_hash & 0xFFFFFFFF)
	out[32] = mode
	out[33] = COMPRESSION_GZIP
	out.encode_u16(34, tick_hz)
	out.encode_u16(36, sample_ticks)
	var db := date.to_ascii_buffer()
	for i in DATE_LEN:
		out[38 + i] = db[i] if i < db.size() else 0
	out.encode_u32(48, ticks)
	out.encode_s64(52, score)
	out.encode_u32(60, hits)
	out.encode_u32(64, clampi(distance_mm, 0, 0xFFFFFFFF))
	out.encode_u32(68, body.size())
	out.encode_u32(72, packed.size())
	out[76] = car_bytes.size()
	for i in car_bytes.size():
		out[FIXED_HEADER + i] = car_bytes[i]
	out.append_array(packed)
	return out


## Writes `id` into an encoded file's header (the receipt names the run after the fact).
static func patch_run_id(bytes: PackedByteArray, id: int) -> bool:
	if bytes.size() < FIXED_HEADER or bytes.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		return false
	bytes.encode_s64(RUN_ID_OFFSET, id)
	return true


static func read_run_id(bytes: PackedByteArray) -> int:
	if bytes.size() < FIXED_HEADER:
		return -1
	return bytes.decode_s64(RUN_ID_OFFSET)


## Parses a file. Null when it is not a valid replay (`error` says why).
static func decode(bytes: PackedByteArray, out_error: Array[String] = []) -> NetReplayFile:
	var err := func(msg: String) -> NetReplayFile:
		out_error.append(msg)
		return null
	if bytes.size() < FIXED_HEADER:
		return err.call("too short")
	if bytes.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		return err.call("bad magic")
	if bytes.decode_u16(4) != VERSION:
		return err.call("unsupported version %d" % bytes.decode_u16(4))
	var header_len := bytes.decode_u16(6)
	var car_len := bytes[76]
	if car_len > CAR_MAX or header_len != FIXED_HEADER + car_len or header_len > bytes.size():
		return err.call("bad header length")
	if bytes[33] != COMPRESSION_GZIP:
		return err.call("unknown compression")
	var r := NetReplayFile.new()
	r.run_id = bytes.decode_s64(RUN_ID_OFFSET)
	r.seed_value = bytes.decode_s64(16)
	r.client_build = bytes.decode_u32(24)
	r.tuning_hash = bytes.decode_u32(28)
	r.mode = bytes[32]
	if r.mode != MODE_JOURNEY and r.mode != MODE_DAILY:
		return err.call("bad mode")
	r.tick_hz = bytes.decode_u16(34)
	r.sample_ticks = bytes.decode_u16(36)
	r.date = bytes.slice(38, 38 + DATE_LEN).get_string_from_ascii()
	r.ticks = bytes.decode_u32(48)
	r.score = bytes.decode_s64(52)
	r.hits = bytes.decode_u32(60)
	r.distance_mm = bytes.decode_u32(64)
	var raw_len := bytes.decode_u32(68)
	var packed_len := bytes.decode_u32(72)
	r.car = bytes.slice(FIXED_HEADER, header_len).get_string_from_ascii()
	if header_len + packed_len != bytes.size():
		return err.call("payload length does not match the file")
	if r.tick_hz <= 0 or r.sample_ticks <= 0:
		return err.call("bad rates")
	var body := bytes.slice(header_len).decompress(raw_len, FileAccess.COMPRESSION_GZIP)
	if body.size() != raw_len:
		return err.call("payload does not decompress")
	if not r._decode_body(body):
		return err.call("malformed payload")
	return r


func _encode_body() -> PackedByteArray:
	var w := _Writer.new(sample_count * 16 + event_count * 12 + 64)
	w.varint(sample_count)
	for col: PackedInt64Array in [tick, s_q, d_q, yaw_q, v_q, vlat_q]:
		w.delta2(col, sample_count)
	for col: PackedInt64Array in [steer_q, throttle_q, brake_q]:
		w.delta(col, sample_count)
	w.raw(flags, sample_count)
	w.varint(tags.size())
	for t in tags:
		var b := t.to_utf8_buffer()
		w.varint(b.size())
		w.bytes(b)
	w.varint(event_count)
	w.delta(ev_tick, event_count)
	w.raw(ev_kind, event_count)
	w.raw(ev_tag, event_count)
	w.zigzag_raw(ev_points, event_count)
	w.zigzag_raw(ev_clearance, event_count)
	w.zigzag_raw(ev_value, event_count)
	return w.finish()


func _decode_body(body: PackedByteArray) -> bool:
	var rd := _Reader.new(body)
	var n := rd.varint()
	if rd.bad or n < 0 or n > body.size():
		return false
	sample_count = n
	_resize_samples(n)
	for col: PackedInt64Array in [tick, s_q, d_q, yaw_q, v_q, vlat_q]:
		rd.delta2(col, n)
	for col: PackedInt64Array in [steer_q, throttle_q, brake_q]:
		rd.delta(col, n)
	rd.raw(flags, n)
	var nt := rd.varint()
	if rd.bad or nt < 0 or nt > body.size():
		return false
	tags.clear()
	_tag_index.clear()
	for i in nt:
		var n_bytes := rd.varint()
		var t := rd.bytes(n_bytes).get_string_from_utf8()
		tags.append(t)
		_tag_index[t] = i
	var ne := rd.varint()
	if rd.bad or ne < 0 or ne > body.size():
		return false
	event_count = ne
	_resize_events(ne)
	rd.delta(ev_tick, ne)
	rd.raw(ev_kind, ne)
	rd.raw(ev_tag, ne)
	rd.zigzag_raw(ev_points, ne)
	rd.zigzag_raw(ev_clearance, ne)
	rd.zigzag_raw(ev_value, ne)
	return not rd.bad and rd.pos == body.size()


func _grow_samples(n: int) -> void:
	if n > tick.size():
		_resize_samples(n)


func _resize_samples(n: int) -> void:
	tick.resize(n)
	s_q.resize(n)
	d_q.resize(n)
	yaw_q.resize(n)
	v_q.resize(n)
	vlat_q.resize(n)
	steer_q.resize(n)
	throttle_q.resize(n)
	brake_q.resize(n)
	flags.resize(n)


func _grow_events(n: int) -> void:
	if n > ev_tick.size():
		_resize_events(n)


func _resize_events(n: int) -> void:
	ev_tick.resize(n)
	ev_kind.resize(n)
	ev_tag.resize(n)
	ev_points.resize(n)
	ev_clearance.resize(n)
	ev_value.resize(n)


# ---------------------------------------------------------------- Varints

static func zigzag(n: int) -> int:
	return (n << 1) ^ (n >> ZIGZAG_SHIFT)


static func unzigzag(z: int) -> int:
	return (z >> 1) ^ -(z & 1)


## Writes into a pre-sized buffer (grows by doubling).
class _Writer:
	var buf := PackedByteArray()
	var pos: int = 0

	func _init(capacity: int) -> void:
		buf.resize(maxi(capacity, 16))

	func _room(n: int) -> void:
		if pos + n > buf.size():
			buf.resize(maxi(buf.size() * 2, pos + n))

	## Unsigned varint (n ≥ 0).
	func varint(n: int) -> void:
		_room(10)
		var v := n
		while v >= VARINT_MORE or v < 0:
			buf[pos] = (v & VARINT_MASK) | VARINT_MORE
			pos += 1
			v = (v >> VARINT_BITS) & 0x01FFFFFFFFFFFFFF
		buf[pos] = v
		pos += 1

	func bytes(b: PackedByteArray) -> void:
		_room(b.size())
		for i in b.size():
			buf[pos + i] = b[i]
		pos += b.size()

	func raw(col: PackedInt64Array, n: int) -> void:
		for i in n:
			varint(col[i])

	func zigzag_raw(col: PackedInt64Array, n: int) -> void:
		for i in n:
			varint(NetReplayFile.zigzag(col[i]))

	func delta(col: PackedInt64Array, n: int) -> void:
		var prev := 0
		for i in n:
			varint(NetReplayFile.zigzag(col[i] - prev))
			prev = col[i]

	func delta2(col: PackedInt64Array, n: int) -> void:
		var prev := 0
		var prev_d := 0
		for i in n:
			var d := col[i] - prev
			varint(NetReplayFile.zigzag(d - prev_d))
			prev = col[i]
			prev_d = d

	func finish() -> PackedByteArray:
		buf.resize(pos)
		return buf


class _Reader:
	var buf: PackedByteArray
	var pos: int = 0
	var bad: bool = false

	func _init(b: PackedByteArray) -> void:
		buf = b

	func varint() -> int:
		var v := 0
		var shift := 0
		while true:
			if pos >= buf.size() or shift > ZIGZAG_SHIFT:
				bad = true
				return 0
			var b := buf[pos]
			pos += 1
			v |= (b & VARINT_MASK) << shift
			if b < VARINT_MORE:
				return v
			shift += VARINT_BITS
		return v

	func bytes(n: int) -> PackedByteArray:
		if n < 0 or pos + n > buf.size():
			bad = true
			return PackedByteArray()
		var out := buf.slice(pos, pos + n)
		pos += n
		return out

	func raw(col: PackedInt64Array, n: int) -> void:
		for i in n:
			col[i] = varint()

	func zigzag_raw(col: PackedInt64Array, n: int) -> void:
		for i in n:
			col[i] = NetReplayFile.unzigzag(varint())

	func delta(col: PackedInt64Array, n: int) -> void:
		var prev := 0
		for i in n:
			prev += NetReplayFile.unzigzag(varint())
			col[i] = prev

	func delta2(col: PackedInt64Array, n: int) -> void:
		var prev := 0
		var prev_d := 0
		for i in n:
			prev_d += NetReplayFile.unzigzag(varint())
			prev += prev_d
			col[i] = prev


# ---------------------------------------------------------------- Traffic fingerprint

const U32_MASK := 0xFFFFFFFF


## u32 of the traffic's discrete state: how many cars, the next vehicle id, and each live
## car's id, lane, target lane and lane-change state, in slot order. Positions are left
## out (playback reproduces them to micrometres, not bits); a spawn, despawn or lane
## change that went another way shows. The verifier compares it once a second to find
## where its traffic stopped being the client's.
static func traffic_fingerprint(ts: TrafficState) -> int:
	var h := TraceHash.mix_int(TraceHash.SEED, ts.count)
	h = TraceHash.mix_int(h, ts.next_vehicle_id)
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		h = TraceHash.mix_int(h, ts.vehicle_id[i])
		h = TraceHash.mix_int(h, ts.lane[i])
		h = TraceHash.mix_int(h, ts.target_lane[i])
		h = TraceHash.mix_int(h, ts.lc_state[i])
	return h & U32_MASK


# ---------------------------------------------------------------- Tuning hash

## Sections of Tuning that the run's simulation reads (the verifier refuses a replay made
## with other values: a build mismatch, not cheating).
const SIM_SECTIONS: Array[String] = ["road", "vehicle", "traffic", "director", "passability", "scoring",
		"lives", "sun", "legs", "progression"]


## u32 of SHA-256 over every stored property of the simulation's tuning sections.
static func tuning_hash_of(t: Tuning) -> int:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for section in SIM_SECTIONS:
		ctx.update(section.to_utf8_buffer())
		var r: Variant = t.get(section)
		if r is Resource:
			_hash_resource(ctx, r as Resource, 0)
	var digest := ctx.finish()
	return digest.decode_u32(0)


const _MAX_DEPTH := 4


static func _hash_resource(ctx: HashingContext, r: Resource, depth: int) -> void:
	if depth > _MAX_DEPTH:
		return
	for p: Dictionary in r.get_property_list():
		var usage: int = p.get("usage", 0)
		if (usage & PROPERTY_USAGE_STORAGE) == 0 or (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var pname: String = p.get("name", "")
		ctx.update(pname.to_utf8_buffer())
		var v: Variant = r.get(pname)
		if v is Resource:
			_hash_resource(ctx, v as Resource, depth + 1)
		elif v is Object:
			continue
		else:
			ctx.update(var_to_bytes(v))
