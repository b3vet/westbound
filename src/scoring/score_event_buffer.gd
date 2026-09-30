class_name ScoreEventBuffer
extends RefCounted
## Preallocated event buffer that pure systems write into and a Node adapter drains
## onto the Events bus. Spec: Architecture rule 4 (event bus); CLAUDE.md rule 4
## ("events they produce are written to a caller-provided buffer").
##
## Record: kind (StringName, usually an Events constant), tag (StringName, kind-specific:
## a reason, hit source or bonus kind), points (int), multiplier (float), clearance_m
## (float, -1 when not applicable), slot (int, TrafficState slot or -1), value (float,
## kind-specific payload). See docs/CONTRACTS.md for the kind
## table and the drain pattern.
##
## Writes are allocation-free. The buffer is filled during a frame's ticks and drained
## (read 0..size()-1, then clear()) once per frame by the adapter. When full, push()
## drops the NEW event, returns false and counts it in `dropped` (size the capacity so
## this never happens; tests assert dropped == 0).

var capacity: int
var dropped: int = 0

var kind: Array[StringName] = []
var tag: Array[StringName] = []
var points: PackedInt64Array
var multiplier: PackedFloat64Array
var clearance_m: PackedFloat64Array
var slot: PackedInt32Array
var value: PackedFloat64Array

var _size: int = 0


func _init(slots: int) -> void:
	capacity = slots
	kind.resize(slots)
	kind.fill(&"")
	tag.resize(slots)
	tag.fill(&"")
	points.resize(slots)
	multiplier.resize(slots)
	clearance_m.resize(slots)
	slot.resize(slots)
	value.resize(slots)


func size() -> int:
	return _size


func is_empty() -> bool:
	return _size == 0


## Appends one event. Returns false (and counts a drop) when full.
func push(event_kind: StringName, event_points: int = 0, event_multiplier: float = 0.0,
		event_clearance_m: float = -1.0, event_slot: int = -1, event_value: float = 0.0,
		event_tag: StringName = &"") -> bool:
	if _size >= capacity:
		dropped += 1
		return false
	kind[_size] = event_kind
	tag[_size] = event_tag
	points[_size] = event_points
	multiplier[_size] = event_multiplier
	clearance_m[_size] = event_clearance_m
	slot[_size] = event_slot
	value[_size] = event_value
	_size += 1
	return true


## Forgets the events (after draining). Keeps the `dropped` counter.
func clear() -> void:
	_size = 0


## Clears events and the drop counter (run start).
func reset() -> void:
	_size = 0
	dropped = 0


## Hash of the buffered events, for determinism traces (hashes names: trace rate only).
func hash_into(h: int) -> int:
	h = TraceHash.mix_int(h, _size)
	for i in _size:
		h = TraceHash.mix_int(h, Rng.fnv1a32(String(kind[i])))  # lint: allow-alloc trace-rate hashing, not a sim tick
		h = TraceHash.mix_int(h, Rng.fnv1a32(String(tag[i])))  # lint: allow-alloc trace-rate hashing, not a sim tick
		h = TraceHash.mix_int(h, points[i])
		h = TraceHash.mix_float(h, multiplier[i])
		h = TraceHash.mix_float(h, clearance_m[i])
		h = TraceHash.mix_int(h, slot[i])
		h = TraceHash.mix_float(h, value[i])
	return h
