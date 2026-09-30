class_name WaterPlan
extends RefCounted
## Where the water's shoreline lies at each s: the WaterDef's shore offset plus the
## meander, the sweep in and out at the ends of the biome's span (and of a river
## cell), or "no water". Spec: World → Biomes (coast: ocean on one side; valley: river
## glimpses). Deterministic: a pure function of (props seed, s, the biome plan), so it
## never depends on how the player drove. Director rate (a WaterRibbon rebuild),
## allocation-free.

const NONE := -1.0
## Coarse probes toward a biome edge, then bisection steps to place it.
const EDGE_PROBES := 8
const EDGE_BISECT := 12
const _MASK31 := 0x7FFFFFFF
const _INV_2_31 := 1.0 / 2147483648.0  # lint: allow-number 2^-31, maps a 31-bit hash to [0, 1)

var props_seed: int = 0
## (s: float) -> BiomeDef. Null callable = every s is `fallback_biome`.
var biome_lookup: Callable
var fallback_biome: BiomeDef
## WP6.5: [s0, s1) pairs with no water (fork spans: the branches and the veering
## opposite carriageway cross the land beside the road). Set by the owner at setup.
var dry := PackedFloat64Array()


func _init(seed_value: int, lookup: Callable = Callable(), fallback: BiomeDef = null) -> void:
	props_seed = seed_value
	biome_lookup = lookup
	fallback_biome = fallback


func biome_at(s: float) -> BiomeDef:
	if biome_lookup.is_valid():
		return biome_lookup.call(s) as BiomeDef
	return fallback_biome


## The water definition at s (null = none).
func def_at(s: float) -> WaterDef:
	var b := biome_at(s)
	return b.water if b != null else null


## Scenery line to the shore strip at s (>= 0), or NONE where there is no water.
func shore_offset_at(s: float) -> float:
	var def := def_at(s)
	if def == null or is_dry(s):
		return NONE
	var edge := edge_distance(s, def)
	if def.span_cell_m > 0.0:
		var c := int(floor(s / def.span_cell_m))
		if not cell_present(c, def):
			return NONE
		var c0 := float(c) * def.span_cell_m
		edge = minf(edge, minf(s - c0, c0 + def.span_cell_m - s))
	var off := def.shore_offset_m
	if def.meander_amplitude_m > 0.0 and def.meander_length_m > 0.0:
		off += def.meander_amplitude_m * sin(TAU * s / def.meander_length_m + _phase())
	if def.arrive_m > 0.0:
		var t := smoothstep(0.0, 1.0, clampf(edge / def.arrive_m, 0.0, 1.0))
		off += def.arrive_offset_m * (1.0 - t)
	return off


## True inside a `dry` range (WP6.5 forks).
func is_dry(s: float) -> bool:
	for i in range(0, dry.size() - 1, 2):
		if s >= dry[i] and s < dry[i + 1]:
			return true
	return false


## Adds the spans of `road`'s forks (widened by the longest arrival sweep of `biomes`'
## water) to `dry`.
func add_fork_spans(road: RoadPath, biomes: Array[BiomeDef]) -> void:
	var pr := road as ProceduralRoadPath
	if pr == null:
		return
	var sweep_m := 0.0
	for b in biomes:
		if b != null and b.water != null:
			sweep_m = maxf(sweep_m, b.water.arrive_m)
	for f in pr.forks:
		dry.append(f.span_start_s() - sweep_m)
		dry.append(f.span_end_s() + sweep_m)


## Whether river cell `c` shows water (chance per cell, from the seed only).
func cell_present(c: int, def: WaterDef) -> bool:
	if def.span_chance_frac >= 1.0:
		return true
	return unit_hash(c) < def.span_chance_frac


## Distance from s to the nearest s (within def.arrive_m) whose water def differs,
## else def.arrive_m. The road start is not an edge.
func edge_distance(s: float, def: WaterDef) -> float:
	var reach := def.arrive_m
	if reach <= 0.0 or not biome_lookup.is_valid():
		return reach
	var best := reach
	for side in 2:
		var dir := -1.0 if side == 0 else 1.0
		var step := reach / float(EDGE_PROBES)
		var inside := 0.0
		for k in range(1, EDGE_PROBES + 1):
			var x := float(k) * step
			var sp := s + dir * x
			if sp < 0.0:
				break
			if def_at(sp) != def:
				var lo := inside
				var hi := x
				for i in EDGE_BISECT:
					var mid := (lo + hi) * 0.5
					if def_at(s + dir * mid) == def:
						lo = mid
					else:
						hi = mid
				best = minf(best, hi)
				break
			inside = x
	return best


## A stable value in [0, 1) for cell `c` of this plan.
func unit_hash(c: int) -> float:
	var h := TraceHash.mix_int(TraceHash.mix_int(TraceHash.SEED, props_seed), c)
	return float(h & _MASK31) * _INV_2_31


func _phase() -> float:
	return unit_hash(-1) * TAU
