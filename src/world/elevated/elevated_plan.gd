class_name ElevatedPlan
extends RefCounted
## Where the road runs elevated: per cell of ElevatedDef.cell_length_m along absolute
## s, at most one stretch (chance, length and position from the props seed and the
## cell index only), kept whole inside one biome span and clear of checkpoint
## landmarks (LandmarkClearance, when given). Spec: World → Biomes (city: elevated
## highway sections), Checkpoint landmarks (landmarks stand on the ground).
##
## `drop_at(s)` is how far the ground lies below the road at s: 0 outside stretches,
## rising with a smoothstep over `ramp_m` to `height_m`. Deterministic by seed,
## allocation-free (it is called per row by the road mesher hook and the feature).

const _MASK31 := 0x7FFFFFFF
const _INV_2_31 := 1.0 / 2147483648.0  # lint: allow-number 2^-31, maps a 31-bit hash to [0, 1)
const _SALT_CHANCE := 1
const _SALT_LENGTH := 2
const _SALT_START := 3
## A zone query reaching this high counts every landmark part.
const _ANY_HEIGHT_M := 1.0e9  # lint: allow-number "any height" sentinel for LandmarkClearance.blocks
## Lateral reach of the stretch for the landmark query (both carriageways and more).
const _ANY_D_M := 1.0e4  # lint: allow-number "any lateral offset" sentinel

var props_seed: int = 0
## (s: float) -> BiomeDef. Null callable = every s is `fallback_biome`.
var biome_lookup: Callable
var fallback_biome: BiomeDef
## Optional: no stretch may overlap a checkpoint landmark's or warning sign's zone.
var clearance: LandmarkClearance


func _init(seed_value: int, lookup: Callable = Callable(), fallback: BiomeDef = null) -> void:
	props_seed = seed_value
	biome_lookup = lookup
	fallback_biome = fallback


func biome_at(s: float) -> BiomeDef:
	if biome_lookup.is_valid():
		return biome_lookup.call(s) as BiomeDef
	return fallback_biome


func def_at(s: float) -> ElevatedDef:
	var b := biome_at(s)
	return b.elevated if b != null else null


## Ground drop below the road at s (m, >= 0).
func drop_at(s: float) -> float:
	var def := def_at(s)
	if def == null or def.cell_length_m <= 0.0:
		return 0.0
	var c := int(floor(s / def.cell_length_m))
	var x := s - stretch_start(c, def)
	var length := stretch_length(c, def)
	if x <= 0.0 or x >= length or not cell_has_stretch(c, def):
		return 0.0
	var ramp := maxf(def.ramp_m, 0.001)
	var t := clampf(minf(x, length - x) / ramp, 0.0, 1.0)
	return def.height_m * smoothstep(0.0, 1.0, t)


## True when s lies in a stretch (drop > 0).
func is_elevated(s: float) -> bool:
	return drop_at(s) > 0.0


## Whether cell `c` holds a stretch: the chance, the whole cell in this def's biome
## span, and no landmark zone over it.
func cell_has_stretch(c: int, def: ElevatedDef) -> bool:
	if unit_hash(c, _SALT_CHANCE) >= def.chance_frac:
		return false
	var c0 := float(c) * def.cell_length_m
	var c1 := c0 + def.cell_length_m
	if c0 < 0.0 or def_at(c0) != def or def_at(c1 - def.ramp_m * 0.5) != def:
		return false
	if clearance != null:
		var a := stretch_start(c, def)
		if clearance.blocks(a, a + stretch_length(c, def), -_ANY_D_M, _ANY_D_M, _ANY_HEIGHT_M):
			return false
	return true


func stretch_length(c: int, def: ElevatedDef) -> float:
	var hi := minf(def.length_max_m, def.cell_length_m)
	var lo := minf(def.length_min_m, hi)
	return lerpf(lo, hi, unit_hash(c, _SALT_LENGTH))


func stretch_start(c: int, def: ElevatedDef) -> float:
	var free := maxf(def.cell_length_m - stretch_length(c, def), 0.0)
	return float(c) * def.cell_length_m + free * unit_hash(c, _SALT_START)


## A stable value in [0, 1) for (cell, salt) of this plan.
func unit_hash(c: int, salt: int) -> float:
	var h := TraceHash.mix_int(TraceHash.mix_int(TraceHash.mix_int(TraceHash.SEED, props_seed), c), salt)
	return float(h & _MASK31) * _INV_2_31
