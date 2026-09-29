class_name BiomePlan
extends RefCounted
# lint: sim
## The journey's biome per leg (WP6.4a). Spec: World → Biomes ("Each leg is one
## biome. Default order below; forks swap the next biome"), Core loop → Legs and
## checkpoints (legs of ~3.5 km ending at a checkpoint), The journey goal (the coast
## after 8 legs, then an endless coastal highway). docs/BIOMES.md.
##
## Pure data, no Node: ProceduralRoadPath reads it while it generates (lane counts,
## curve / crest / tunnel frequency per leg) and BiomeDirector reads it for the look
## (props, ground, tints, horizon). Leg k (1-based) covers [(k - 1) L, k L): the next
## leg's biome takes over exactly at the checkpoint line. Legs past the list use the
## endless biome.
##
##   var plan := BiomePlan.from_tuning(ctx.tuning.legs)    # the default journey
##   plan.biome_at(s); plan.biome_for_leg(3)
##   plan.plan_next(4, canyon)                              # a fork swaps leg 4
##
## Deterministic: the plan is data (LegsTuning.leg_biome_ids) plus the player's fork
## choices; nothing here draws random numbers. `version` moves on every change so
## caches (LandmarkClearance, RoadBuilder colors) refill.

const PATH_FORMAT := "res://data/biomes/%s.tres"
## Leg 1's fallback when its id has no data file.
const DEFAULT_ID := &"farmland"


## The biomes either side of the nearest checkpoint and how far the look has blended
## from `from` to `to` at an s (blend_into). `t` = 0: all `from`.
class Blend:
	extends RefCounted
	var from: BiomeDef
	var to: BiomeDef
	var t: float = 0.0


var leg_length_m: float = 1.0
## Moves on every change of the plan.
var version: int = 0
## Ids asked for whose data file does not exist (they fell back to the leg before).
var missing_ids: Array[StringName] = []

var _legs: Array[BiomeDef] = []
var _endless: BiomeDef
var _candidates: Array[BiomeDef] = []


func _init(leg_len_m: float, legs: Array[BiomeDef], endless_def: BiomeDef) -> void:
	leg_length_m = maxf(leg_len_m, 1.0)
	_legs = legs.duplicate()
	_endless = endless_def
	if _endless == null and not _legs.is_empty():
		_endless = _legs[_legs.size() - 1]


## The default journey from tuning: LegsTuning.leg_biome_ids, then endless_biome_id.
## An id without a data file falls back to the leg before it (the first to farmland).
static func from_tuning(legs: LegsTuning) -> BiomePlan:
	var list: Array[BiomeDef] = []
	var missing: Array[StringName] = []
	var prev: BiomeDef = null
	for id in legs.leg_biome_ids:
		var b := load_biome(id)
		if b == null:
			missing.append(id)
			b = prev if prev != null else load_biome(DEFAULT_ID)
		list.append(b)
		prev = b
	var endless := load_biome(legs.endless_biome_id)
	if endless == null:
		missing.append(legs.endless_biome_id)
		endless = prev
	var plan := BiomePlan.new(legs.leg_length_m(), list, endless)
	plan.missing_ids = missing
	return plan


## One biome everywhere (tests, previews, the sandbox).
static func uniform(biome: BiomeDef, leg_len_m: float) -> BiomePlan:
	var none: Array[BiomeDef] = []
	return BiomePlan.new(leg_len_m, none, biome)


## data/biomes/<id>.tres, or null when there is no such file.
static func load_biome(id: StringName) -> BiomeDef:
	var path := PATH_FORMAT % id
	if id == &"" or not ResourceLoader.exists(path):
		return null
	return load(path) as BiomeDef


# ---------------------------------------------------------------- Queries

## The leg containing s (1-based; s < 0 is leg 1).
func leg_at(s: float) -> int:
	return maxi(int(floor(s / leg_length_m)), 0) + 1


## Where leg `leg` starts (its previous checkpoint; 0 for leg 1).
func leg_start_s(leg: int) -> float:
	return float(maxi(leg, 1) - 1) * leg_length_m


func biome_for_leg(leg: int) -> BiomeDef:
	var i := maxi(leg, 1) - 1
	if i < _legs.size():
		return _legs[i]
	return _endless


func biome_at(s: float) -> BiomeDef:
	return biome_for_leg(leg_at(s))


## Legs with their own entry (the rest are the endless biome).
func legs_planned() -> int:
	return _legs.size()


func endless_biome() -> BiomeDef:
	return _endless


## Every biome the run may show: the plan's, then registered fork candidates. World
## systems build their per-biome parts (roadside layers) for all of them at setup.
func catalog() -> Array[BiomeDef]:
	var out: Array[BiomeDef] = []
	for b in _legs:
		if b != null and not out.has(b):
			out.append(b)
	if _endless != null and not out.has(_endless):
		out.append(_endless)
	for b in _candidates:
		if not out.has(b):
			out.append(b)
	return out


# ---------------------------------------------------------------- Changes (forks)

## Leg `leg` becomes `biome` ("forks swap the next biome"). Call before the road has
## generated that leg's start if its road rules (lanes, curves, tunnels) should apply:
## ProceduralRoadPath latches a leg's road rules when it first generates into it.
func plan_next(leg: int, biome: BiomeDef) -> void:
	if biome == null or leg < 1:
		return
	while _legs.size() < leg:
		_legs.append(_endless)
	if _legs[leg - 1] == biome:
		return
	_legs[leg - 1] = biome
	_note(biome)


## Every leg from `leg` on (and the endless road) becomes `biome`.
func set_biome_from_leg(leg: int, biome: BiomeDef) -> void:
	if biome == null or leg < 1:
		return
	while _legs.size() < leg - 1:
		_legs.append(_endless)
	if _legs.size() > leg - 1:
		_legs.resize(leg - 1)
	_endless = biome
	_note(biome)


## A biome a fork may pick later: its world parts are built at setup too.
func add_candidate(biome: BiomeDef) -> void:
	if biome != null and not _candidates.has(biome):
		_candidates.append(biome)
		version += 1


func _note(biome: BiomeDef) -> void:
	add_candidate(biome)
	version += 1


# ---------------------------------------------------------------- Road rules (generator rate)

## BiomeDef.curve_frequency_scale of the leg at s (1 = the generator's defaults).
func curve_scale_at(s: float) -> float:
	var b := biome_at(s)
	return b.curve_frequency_scale if b != null else 1.0


func crest_scale_at(s: float) -> float:
	var b := biome_at(s)
	return b.crest_frequency_scale if b != null else 1.0


## The biome's bend sight clearance at s, else `fallback_m` (RoadTuning's).
func bend_sight_clearance_at(s: float, fallback_m: float) -> float:
	var b := biome_at(s)
	if b == null or b.bend_sight_clearance_m <= 0.0:
		return fallback_m
	return b.bend_sight_clearance_m


# ---------------------------------------------------------------- Look blending

## Fills `out` with the blend at s: near a checkpoint k L where the biome changes,
## over [k L - before_m, k L + after_m], `from` is leg k's biome, `to` leg k + 1's and
## `t` a smoothstep from 0 to 1; elsewhere from = to = the biome at s, t = 0.
## Allocation-free.
func blend_into(s: float, before_m: float, after_m: float, out: Blend) -> void:
	var k := int(round(s / leg_length_m))
	var here := biome_at(s)
	out.from = here
	out.to = here
	out.t = 0.0
	if k < 1:
		return
	var line := float(k) * leg_length_m
	var a := biome_for_leg(k)
	var b := biome_for_leg(k + 1)
	if a == b or s < line - before_m or s > line + after_m:
		return
	out.from = a
	out.to = b
	var span := before_m + after_m
	out.t = smoothstep(0.0, 1.0, (s - (line - before_m)) / span) if span > 0.0 else (1.0 if s >= line else 0.0)
