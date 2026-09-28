class_name TraceHash
extends RefCounted
## Allocation-free 32-bit FNV-1a-style hashing of sim state for determinism tests.
## Spec: Architecture rule 2; Traffic tests (hash of all vehicle states every second);
## Car physics tests (identical state trace).
##
##   var h := TraceHash.SEED
##   h = TraceHash.mix_float(h, state.s)
##   h = TraceHash.mix_int(h, state.gear)
##
## Floats are hashed by their exact IEEE-754 bits, so any difference (even 1 ulp)
## changes the hash. Every step is a bijection of h for a fixed input word, so a
## change in any single field always changes the result. Arithmetic stays below
## 2^57, so nothing relies on integer overflow (same rule as Rng).

const SEED := 2166136261
const _PRIME := 16777619
const _MASK32 := 0xFFFFFFFF

static var _bits := PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])


static func mix_int(h: int, x: int) -> int:
	h = ((h ^ (x & _MASK32)) * _PRIME) & _MASK32
	return ((h ^ ((x >> 32) & _MASK32)) * _PRIME) & _MASK32


static func mix_float(h: int, x: float) -> int:
	_bits.encode_double(0, x)
	return mix_int(h, _bits.decode_s64(0))


static func mix_bool(h: int, x: bool) -> int:
	return mix_int(h, 1 if x else 0)


## Mixes the first `count` entries.
static func mix_f64_array(h: int, a: PackedFloat64Array, count: int) -> int:
	for i in count:
		h = mix_float(h, a[i])
	return h


static func mix_i32_array(h: int, a: PackedInt32Array, count: int) -> int:
	for i in count:
		h = mix_int(h, a[i])
	return h
