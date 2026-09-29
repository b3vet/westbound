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
##
## Checkpoint landmark styles (WP5.5, CONTRACTS §3: "the biome director fills the
## CHECKPOINT tag"): `checkpoint_style(leg, s)` is the style of the biome whose leg ends
## at s (BiomeDef.checkpoint_style, seeded from the run's props stream), and
## `tag_checkpoints(features)` writes it into the untagged CHECKPOINT features a
## consumer got from RoadPath.features_in (Landmarks, LandmarkClearance). The road
## creates its features per query, so every consumer tags its own copies.

const DEFAULT_BIOME_PATH := "res://data/biomes/farmland.tres"
## World systems that need the director but are not handed one (StreetLampPools)
## find it in this group.
const GROUP := &"wb_biome_director"
## Props sub-stream that seeds the per-biome landmark style cycle.
const STYLE_STREAM := &"landmark_styles"
## The biome of the leg ending at a checkpoint is the one just before the line.
const LEG_END_EPS_M := 0.5   # lint: allow-number tolerance on the checkpoint position, not tuning

## The biome at s = 0 (loaded from DEFAULT_BIOME_PATH when left null).
var default_biome: BiomeDef

## Bumped whenever the plan changes (set_biome_from): caches of biome-derived data
## (LandmarkClearance) refill when it moves.
var plan_version: int = 0

var _span_start_s := PackedFloat64Array()
var _span_biome: Array[BiomeDef] = []
var _current: BiomeDef
var _style_seed: int = 0


func _enter_tree() -> void:
	add_to_group(GROUP)


func setup(ctx: RunContext, _road: RoadPath, _origin: FloatingOrigin) -> void:
	if default_biome == null:
		default_biome = load(DEFAULT_BIOME_PATH) as BiomeDef
	_style_seed = ctx.rng_props.derive(STYLE_STREAM).get_seed() if ctx != null else 0
	plan_version += 1
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
	plan_version += 1
	while _span_start_s.size() > 1 and _span_start_s[_span_start_s.size() - 1] >= s:
		_span_start_s.resize(_span_start_s.size() - 1)
		_span_biome.pop_back()
	if _span_start_s.size() == 1 and s <= _span_start_s[0]:
		_span_biome[0] = biome
		return
	_span_start_s.append(s)
	_span_biome.append(biome)


## The landmark style of the checkpoint at `checkpoint_s` ending leg `leg_index`: the
## style of the biome whose leg ends there ("" without a biome). Deterministic by seed.
func checkpoint_style(leg_index: int, checkpoint_s: float) -> StringName:
	var b := biome_at(checkpoint_s - LEG_END_EPS_M)
	return b.checkpoint_style(leg_index, _style_seed) if b != null else &""


## Fills the tag (landmark style) of every untagged CHECKPOINT feature in `features`.
## Director rate (a consumer's feature query).
func tag_checkpoints(features: Array[RoadFeature]) -> void:
	for f in features:
		if f.kind == RoadFeature.Kind.CHECKPOINT and f.tag == &"":
			f.tag = checkpoint_style(int(f.value), f.s_start)


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
