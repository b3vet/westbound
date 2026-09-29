class_name BiomeRoadRules
extends RefCounted
# lint: sim
## The road rules of each leg's biome, latched once per leg (WP6.4a). Spec: World →
## Road ("3 lanes per direction by default. Some biomes use 4; tunnels and road works
## drop to 2"; long gentle curves, occasional blind crests), Biomes (desert: long
## straights; canyon: tunnels, more curves and crests). docs/BIOMES.md.
##
## ProceduralRoadPath and its generators ask for a leg's lane count, curve / crest /
## tunnel frequency scales and bend sight clearance through this object. The first
## question about leg k copies them from the BiomePlan's biome for leg k, and they
## never change after that: a plan change (a fork) only reaches the road for legs the
## generator has not asked about yet, so the geometry already generated (and anything
## derived from it) stays valid. Legs are latched in order.

var plan: BiomePlan

var _curve := PackedFloat64Array()
var _crest := PackedFloat64Array()
var _tunnel := PackedFloat64Array()
var _clearance := PackedFloat64Array()
var _lanes := PackedInt32Array()
var _lanes_default: int
var _lanes_min: int
var _lanes_max: int


func _init(biome_plan: BiomePlan, t: RoadTuning) -> void:
	plan = biome_plan
	_lanes_default = t.lanes_default
	_lanes_min = t.lanes_min
	_lanes_max = t.lanes_max


## Legs latched so far (1..latched_legs()).
func latched_legs() -> int:
	return _lanes.size()


func leg_at(s: float) -> int:
	return plan.leg_at(s)


func curve_scale_at(s: float) -> float:
	var i := _ensure(plan.leg_at(s))
	return _curve[i]


func crest_scale_at(s: float) -> float:
	var i := _ensure(plan.leg_at(s))
	return _crest[i]


## The leg's bend sight clearance, or `fallback_m` when its biome has none.
func bend_sight_clearance_at(s: float, fallback_m: float) -> float:
	var c := _clearance[_ensure(plan.leg_at(s))]
	return c if c > 0.0 else fallback_m


## Lane count of leg `leg`'s biome (clamped to RoadTuning's range).
func lanes_for_leg(leg: int) -> int:
	return _lanes[_ensure(leg)]


func tunnel_scale_for_leg(leg: int) -> float:
	return _tunnel[_ensure(leg)]


## Index of leg `leg` (1-based) in the latched arrays, latching up to it.
func _ensure(leg: int) -> int:
	var k := maxi(leg, 1)
	while _lanes.size() < k:
		var b := plan.biome_for_leg(_lanes.size() + 1)
		if b == null:
			_curve.append(1.0)
			_crest.append(1.0)
			_tunnel.append(0.0)
			_clearance.append(0.0)
			_lanes.append(_lanes_default)
			continue
		_curve.append(b.curve_frequency_scale if b.curve_frequency_scale > 0.0 else 1.0)
		_crest.append(maxf(b.crest_frequency_scale, 0.0))
		_tunnel.append(maxf(b.tunnel_frequency_scale, 0.0))
		_clearance.append(b.bend_sight_clearance_m)
		_lanes.append(clampi(b.lane_count, _lanes_min, _lanes_max))
	return k - 1
