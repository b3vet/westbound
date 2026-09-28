class_name Rng
extends RefCounted
## Seeded, platform-stable RNG. Spec: Architecture rule 2 (deterministic by seed).
##
## One run seed derives independent per-subsystem streams by name:
##   var run_rng := Rng.new(run_seed)
##   var traffic := run_rng.derive(Rng.STREAM_TRAFFIC)
## Streams depend only on (parent seed, name), never on how many numbers another
## stream has drawn, so adding draws in one subsystem never changes another.
##
## Built on RandomNumberGenerator (PCG32, integer-exact across platforms).
## Hashing uses 32-bit FNV-1a kept below 2^56 so nothing relies on overflow.
## Do not use randfn() or other libm-dependent draws in simulation code.

const STREAM_ROAD := &"road"
const STREAM_TRAFFIC := &"traffic"
const STREAM_PROPS := &"props"
const STREAM_EVENTS := &"events"

const _FNV_OFFSET := 2166136261
const _FNV_PRIME := 16777619
const _MASK32 := 0xFFFFFFFF

var _seed: int
var _gen := RandomNumberGenerator.new()


func _init(seed_value: int) -> void:
	_seed = seed_value
	_gen.seed = seed_value


func get_seed() -> int:
	return _seed


## A new independent stream derived from this stream's seed and `name`.
func derive(name: StringName) -> Rng:
	return Rng.new(derive_seed(_seed, String(name)))


## Uniform float in [0, 1).
func unit() -> float:
	return _gen.randf()


func float_range(from: float, to: float) -> float:
	return from + (to - from) * _gen.randf()


## Uniform int in [from, to], inclusive.
func int_range(from: int, to: int) -> int:
	return _gen.randi_range(from, to)


## True with probability p.
func chance(p: float) -> bool:
	return _gen.randf() < p


## Index into `weights` chosen proportionally to its (non-negative) weight.
func pick_weighted(weights: PackedFloat64Array) -> int:
	var total := 0.0
	for w in weights:
		total += w
	var r := _gen.randf() * total
	for i in weights.size():
		r -= weights[i]
		if r < 0.0:
			return i
	return weights.size() - 1


## Opaque generator state, for save/restore within a run.
func get_state() -> int:
	return _gen.state


func set_state(state: int) -> void:
	_gen.state = state


# ---------------------------------------------------------------- Static helpers

## 32-bit FNV-1a over the UTF-8 bytes of `text`, continuing from `h`.
static func fnv1a32(text: String, h: int = _FNV_OFFSET) -> int:
	for b in text.to_utf8_buffer():
		h = ((h ^ b) * _FNV_PRIME) & _MASK32
	return h


## Stable 63-bit child seed from a parent seed and a stream name.
static func derive_seed(parent: int, name: String) -> int:
	var key := "%d/%s" % [parent, name]
	var hi := fnv1a32(key) & 0x7FFFFFFF
	var lo := fnv1a32(key + "#")
	return (hi << 32) | lo


## Daily Drive seed: identical for everyone on the same UTC date.
static func daily_seed(year: int, month: int, day: int) -> int:
	return derive_seed(0, "daily-%04d-%02d-%02d" % [year, month, day])


## A fresh random seed for Journey runs.
static func random_seed() -> int:
	var g := RandomNumberGenerator.new()
	g.randomize()
	return (g.randi() & 0x7FFFFFFF) << 32 | g.randi()
