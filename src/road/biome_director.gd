class_name BiomeDirector
extends Node
## Which biome is active at a given s. Spec: World → Biomes ("Each leg is one
## biome. Default order ...; forks swap the next biome"), Core loop → Legs and
## checkpoints. Skeleton (WP1.4): farmland everywhere. The leg/fork system
## (Phase 5/6) later calls `set_biome_from(s, biome)` at each leg start or fork.
##
## World-system node (docs/CONTRACTS.md §13): `setup(ctx, road, origin)`, then
## `update_view(focus_s)` once per frame. Emits `Events.biome_changed(id)` once
## at setup and whenever the focus crosses into a different biome.

const DEFAULT_BIOME_PATH := "res://data/biomes/farmland.tres"

## The biome at s = 0 (loaded from DEFAULT_BIOME_PATH when left null).
var default_biome: BiomeDef

var _span_start_s := PackedFloat64Array()
var _span_biome: Array[BiomeDef] = []
var _current: BiomeDef


func setup(_ctx: RunContext, _road: RoadPath, _origin: FloatingOrigin) -> void:
	if default_biome == null:
		default_biome = load(DEFAULT_BIOME_PATH) as BiomeDef
	_span_start_s = PackedFloat64Array([0.0])
	_span_biome = [default_biome]
	_current = null
	_set_current(biome_at(0.0))


func update_view(focus_s: float) -> void:
	var b := biome_at(focus_s)
	if b != _current:
		_set_current(b)


## The biome whose span contains s (spans are few: one per leg).
func biome_at(s: float) -> BiomeDef:
	var i := _span_start_s.size() - 1
	while i > 0 and s < _span_start_s[i]:
		i -= 1
	return _span_biome[i] if i >= 0 and i < _span_biome.size() else default_biome


func current() -> BiomeDef:
	return _current


## `biome` from `s` on, replacing whatever was planned after s (legs, forks).
func set_biome_from(s: float, biome: BiomeDef) -> void:
	while _span_start_s.size() > 1 and _span_start_s[_span_start_s.size() - 1] >= s:
		_span_start_s.resize(_span_start_s.size() - 1)
		_span_biome.pop_back()
	if _span_start_s.size() == 1 and s <= _span_start_s[0]:
		_span_biome[0] = biome
		return
	_span_start_s.append(s)
	_span_biome.append(biome)


## Every biome with a span (roadside builds prop layers for each).
func biomes() -> Array[BiomeDef]:
	var out: Array[BiomeDef] = []
	for b in _span_biome:
		if not out.has(b):
			out.append(b)
	return out


func _set_current(b: BiomeDef) -> void:
	_current = b
	Events.biome_changed.emit(b.id)
