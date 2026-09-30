class_name DailyGhost
extends RefCounted
## One Daily Drive ghost: the player's path at 20 Hz (s, d, heading, speed, brake and
## lights) and the forks it took, for one UTC date. Spec: Core loop → Modes at launch
## ("Your best daily run is recorded and shown as a translucent ghost car on later
## attempts (the car's s, d and heading sampled at 20 Hz)"), Save data ("Daily Drive
## ghosts"). WP8.4; docs/DAILY.md → Ghost file.
##
## Why not the N8.1 replay (`.wbr`, NetReplayFile): that one is recorded only while the
## online runs client exists (never with `?server=off` or offline builds), at 30 Hz with
## inputs, events and traffic fingerprints the ghost does not need, and it is deleted once
## uploaded. The ghost is a separate, smaller file (about a third of a replay) with the
## spec's rate and the two light flags; it reuses the replay's column coding
## (NetReplayFile.encode_columns) and its gzip.
##
## Layout (little-endian; the header is uncompressed so the store can read the score
## without inflating the body):
##   0  "WBG1"  4  u16 version  6  u16 header length  8  s64 seed  16  s64 banked score
##   24 u32 RUNNING ticks  28 u16 tick_hz  30 u16 sample_ticks  32 date (10 ASCII bytes)
##   42 u32 body bytes  46 u32 gzip bytes  50 u8 car id length  51 car id (ASCII)
##   then gzip(body): u32 length of the sample block, the sample block
##   (NetReplayFile.encode_columns of tick, s, d, yaw, v delta-of-delta | flags), the fork
##   block (fork tick delta | fork index, fork side).
## Quantized once, when appended: s, d 1 mm · yaw (heading vs road) 1e-4 rad · v 1 cm/s.

const MAGIC := "WBG1"
const VERSION := 1
const FIXED_HEADER := 51
const DATE_LEN := 10
const CAR_MAX := 32

## Quantization (wire = round(value × scale)).
const Q_POS := 1000.0
const Q_YAW := 10000.0
const Q_SPEED := 100.0

## Sample flags.
const FLAG_BRAKE := 1       ## brake lights on
const FLAG_LIGHTS := 2      ## headlights on
const FLAG_BOOST := 4       ## boost running
const FLAG_FORK_SWAP := 8   ## the road swapped to a fork's right branch this tick (d jumped)
const FLAG_RESET := 16      ## the safety net put the car back in a lane this tick
const FLAG_FINAL := 32      ## the last sample of the run
## Never interpolate into a sample with one of these.
const JUMP_FLAGS := FLAG_FORK_SWAP | FLAG_RESET

## Sample columns delta-of-delta coded (tick, s, d, yaw, v); flags raw.
const SAMPLE_DELTA2 := 5
const FORK_DELTA := 1
const U32 := 4

var seed_value: int = 0
var score: int = 0
## RUNNING ticks of the run.
var ticks: int = 0
var tick_hz: int = 120
var sample_ticks: int = 6
## "YYYY-MM-DD" (UTC), the Daily Drive's seed date.
var date: String = ""
var car: String = ""

var sample_count: int = 0
var tick := PackedInt64Array()
var s_q := PackedInt64Array()
var d_q := PackedInt64Array()
var yaw_q := PackedInt64Array()
var v_q := PackedInt64Array()
var flags := PackedInt64Array()

## Forks in the order the run resolved them: the tick, the fork index, the side
## (ForkPlan.LEFT / RIGHT).
var fork_count: int = 0
var fork_tick := PackedInt64Array()
var fork_index := PackedInt64Array()
var fork_side := PackedInt64Array()


## Room for `samples` samples and `forks` forks (they grow by doubling after).
func reserve(samples: int, forks: int) -> void:
	_resize_samples(maxi(samples, 1))
	_resize_forks(maxi(forks, 1))


## Appends one sample (physical units in). Allocation-free while within the reserve.
func add_sample(t: int, s: float, d: float, yaw: float, v: float, sample_flags: int) -> void:
	if sample_count >= tick.size():
		_resize_samples(maxi(tick.size() * 2, 1))   # lint: allow-alloc doubling past the reserve
	var i := sample_count
	tick[i] = t
	s_q[i] = roundi(s * Q_POS)
	d_q[i] = roundi(d * Q_POS)
	yaw_q[i] = roundi(yaw * Q_YAW)
	v_q[i] = roundi(v * Q_SPEED)
	flags[i] = sample_flags
	sample_count += 1


func add_fork(t: int, index: int, side: int) -> void:
	if fork_count >= fork_tick.size():
		_resize_forks(maxi(fork_tick.size() * 2, 1))
	fork_tick[fork_count] = t
	fork_index[fork_count] = index
	fork_side[fork_count] = side
	fork_count += 1


func s_at(i: int) -> float:
	return float(s_q[i]) / Q_POS


func d_at(i: int) -> float:
	return float(d_q[i]) / Q_POS


func yaw_at(i: int) -> float:
	return float(yaw_q[i]) / Q_YAW


func v_at(i: int) -> float:
	return float(v_q[i]) / Q_SPEED


func last_tick() -> int:
	return int(tick[sample_count - 1]) if sample_count > 0 else 0


# ---------------------------------------------------------------- Encoding

func encode() -> PackedByteArray:
	var samples := NetReplayFile.encode_columns(
			[_cut(tick, sample_count), _cut(s_q, sample_count), _cut(d_q, sample_count),
			_cut(yaw_q, sample_count), _cut(v_q, sample_count), _cut(flags, sample_count)],
			sample_count, SAMPLE_DELTA2, 0)
	var body := PackedByteArray()
	body.resize(U32)
	body.encode_u32(0, samples.size())
	body.append_array(samples)
	body.append_array(NetReplayFile.encode_columns(
			[_cut(fork_tick, fork_count), _cut(fork_index, fork_count), _cut(fork_side, fork_count)],
			fork_count, 0, FORK_DELTA))
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
	out.encode_s64(8, seed_value)
	out.encode_s64(16, score)
	out.encode_u32(24, ticks)
	out.encode_u16(28, tick_hz)
	out.encode_u16(30, sample_ticks)
	var db := date.to_ascii_buffer()
	for i in DATE_LEN:
		out[32 + i] = db[i] if i < db.size() else 0
	out.encode_u32(42, body.size())
	out.encode_u32(46, packed.size())
	out[50] = car_bytes.size()
	for i in car_bytes.size():
		out[FIXED_HEADER + i] = car_bytes[i]
	out.append_array(packed)
	return out


## The header only (date, score, seed, ticks, car): no samples. Null when it is not a
## ghost file.
static func peek(bytes: PackedByteArray) -> DailyGhost:
	if bytes.size() < FIXED_HEADER or bytes.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		return null
	if bytes.decode_u16(4) != VERSION:
		return null
	var header_len := bytes.decode_u16(6)
	var car_len := bytes[50]
	if car_len > CAR_MAX or header_len != FIXED_HEADER + car_len or header_len > bytes.size():
		return null
	var g := DailyGhost.new()
	g.seed_value = bytes.decode_s64(8)
	g.score = bytes.decode_s64(16)
	g.ticks = bytes.decode_u32(24)
	g.tick_hz = bytes.decode_u16(28)
	g.sample_ticks = bytes.decode_u16(30)
	g.date = bytes.slice(32, 32 + DATE_LEN).get_string_from_ascii()
	g.car = bytes.slice(FIXED_HEADER, header_len).get_string_from_ascii()
	if g.tick_hz <= 0 or g.sample_ticks <= 0:
		return null
	return g


## The whole ghost. Null when the bytes are not a valid ghost file.
static func decode(bytes: PackedByteArray) -> DailyGhost:
	var g := peek(bytes)
	if g == null:
		return null
	var header_len := bytes.decode_u16(6)
	var raw_len := bytes.decode_u32(42)
	var packed_len := bytes.decode_u32(46)
	if header_len + packed_len != bytes.size():
		return null
	var body := bytes.slice(header_len).decompress(raw_len, FileAccess.COMPRESSION_GZIP)
	if body.size() != raw_len:
		return null
	if body.size() < U32:
		return null
	var split := U32 + body.decode_u32(0)
	if split > body.size():
		return null
	var sample_cols: Array[PackedInt64Array] = [g.tick, g.s_q, g.d_q, g.yaw_q, g.v_q, g.flags]
	var fork_cols: Array[PackedInt64Array] = [g.fork_tick, g.fork_index, g.fork_side]
	g.sample_count = NetReplayFile.decode_columns(body.slice(U32, split), sample_cols, SAMPLE_DELTA2, 0)
	g.fork_count = NetReplayFile.decode_columns(body.slice(split), fork_cols, 0, FORK_DELTA)
	if g.sample_count < 0 or g.fork_count < 0:
		return null
	g.tick = sample_cols[0]
	g.s_q = sample_cols[1]
	g.d_q = sample_cols[2]
	g.yaw_q = sample_cols[3]
	g.v_q = sample_cols[4]
	g.flags = sample_cols[5]
	g.fork_tick = fork_cols[0]
	g.fork_index = fork_cols[1]
	g.fork_side = fork_cols[2]
	return g


# ---------------------------------------------------------------- Internals

## A copy of the first `n` entries (encode time).
static func _cut(col: PackedInt64Array, n: int) -> PackedInt64Array:
	return col.slice(0, n)


func _resize_samples(n: int) -> void:
	tick.resize(n)
	s_q.resize(n)
	d_q.resize(n)
	yaw_q.resize(n)
	v_q.resize(n)
	flags.resize(n)


func _resize_forks(n: int) -> void:
	fork_tick.resize(n)
	fork_index.resize(n)
	fork_side.resize(n)
