class_name RoadsideContext
extends RefCounted
## Shared state for the roadside layers (road, tuning, scratch sample, the
## reseedable props stream and the biome lookup). Spec: World → Road (roadside
## rhythm); Architecture rule 2 (deterministic by seed). Built by roadside.gd.

var road: RoadPath
var tuning: RoadTuning
## Scratch samples, reused (no allocation per placement).
var sample := RoadSample.new()
var sample_b := RoadSample.new()
## Reseeded per (layer, cell, side) with `seed_cell`; never drawn from across cells.
var rng := Rng.new(0)
## Seed of the run's roadside stream (`RunContext.rng_props.derive(&"roadside")`).
var props_seed: int = 0
## Null outside a run: every cell then belongs to `fallback_biome`.
var biome_director: BiomeDirector
var fallback_biome: BiomeDef
## Landmark and warning-sign zones to keep clear (WP5.5); null = none.
var clearance: LandmarkClearance
## Where the biome water lies (WP6.4c; the WaterRibbon's plan from the same seed and
## biome lookup); null = no water check. See water_blocks().
var water: WaterPlan

const _MASK31 := 0x7FFFFFFF


func _init(road_path: RoadPath, road_tuning: RoadTuning, seed_value: int, director: BiomeDirector,
		fallback: BiomeDef) -> void:
	road = road_path
	tuning = road_tuning
	props_seed = seed_value
	biome_director = director
	fallback_biome = fallback


func biome_at(s: float) -> BiomeDef:
	if biome_director != null:
		return biome_director.biome_at(s)
	return fallback_biome


## A per-layer base seed: the run's roadside seed mixed with the layer id.
func layer_seed(layer_id: StringName) -> int:
	return TraceHash.mix_int(TraceHash.mix_int(TraceHash.SEED, props_seed), Rng.fnv1a32(String(layer_id)))


## Reseeds `rng` from (layer seed, cell index, salt) only: allocation-free, and
## independent of the order cells are visited or how the window moved.
func seed_cell(layer_seed_value: int, cell: int, salt: int) -> void:
	var h := TraceHash.mix_int(TraceHash.mix_int(layer_seed_value, cell), salt)
	var lo := TraceHash.mix_int(h, cell)
	rng.set_state(((h & _MASK31) << 32) | lo)


## True when a footprint spanning d_lo..d_hi at s reaches over water on the water's
## side: beyond the road-level strip of a sea slope (WaterDef.drop_m > 0: the coast,
## where the ground falls away to the sea), or onto a river's water surface (its banks
## are fine). No billboard, gantry or prop stands there (WP6.4c). Allocation-free; the
## shoreline is only computed for footprints reaching past the nearest it can be.
func water_blocks(s: float, d_lo: float, d_hi: float) -> bool:
	if water == null:
		return false
	var def := water.def_at(s)
	if def == null:
		return false
	var side := signi(def.side)
	# Outer and inner |d| of the footprint's part on the water side.
	var far := d_hi if side > 0 else -d_lo
	var line := road.guardrail_d(s) + tuning.prop_clearance_m
	if far <= line + def.shore_offset_m - def.meander_amplitude_m:
		return false
	var off := water.shore_offset_at(s)
	if off < 0.0:
		return false
	var shore := line + off
	if def.drop_m > 0.0:
		return far > shore
	var near := d_lo if side > 0 else -d_hi
	var waterline := shore + def.shore_width_m
	return far > waterline and near < waterline + def.width_m
