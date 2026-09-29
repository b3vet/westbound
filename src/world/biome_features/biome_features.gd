class_name BiomeFeatures
extends Node3D
## The biome world features of a run (WP6.4c wiring of WP6.4b's nodes): the coast's
## ocean and the valley's river (WaterRibbon), the city's elevated stretches
## (ElevatedSections) and the valley's low fog (FogCards), with the hooks they need
## elsewhere: the road mesher's ground drop, the horizon's sea mask and a landmark
## clearance for the viaducts. Spec: World → Biomes (coastal highway, city at night,
## valley fog), Road (floating origin, pooling), Performance budget (one draw call per
## feature with geometry). docs/BIOMES.md → Wiring.
##
## World-system node (docs/CONTRACTS.md §13), used by the run and the drive scene:
##   features.biome_director = director      # before setup
##   features.bind(builder, sky)              # once: builder.set_ground_drop, sea mask
##   features.setup(ctx, road, origin)        # per run (and retry), before the builder's
##                                            # first build: the plans must exist
##   features.update_view(player_s)           # once per frame
##   road.forget_before(s - features.reach_behind_m() - ...)   # keep what they sample
##
## The three feature nodes are made once (here, in _init) and kept for every run: a
## retry re-runs their setup, which reuses each node's mesh and material, so nothing is
## created or freed after the first setup. Floating-origin shifts move the mesh nodes
## (BiomeFeature: builds are anchor-relative); nothing is rebuilt for a shift.
##
## ElevatedSections gets its own LandmarkClearance (the same inputs as the Roadside's
## and the Landmarks': the run's road, biome director and LandmarkTuning, so the same
## zones), set up per run before the features: the road mesher's hook queries it for
## every row, and a clearance shared with the Roadside would refill back and forth
## between the two windows.

var biome_director: BiomeDirector
## > 0 overrides the quality view distance of every feature (previews, tests).
var view_distance_override_m: float = 0.0

var water: WaterRibbon
var elevated: ElevatedSections
var fog: FogCards
## The viaducts' landmark and road-tunnel zones (set up per run).
var clearance := LandmarkClearance.new()

var _sky: SkyRig


func _init() -> void:
	water = WaterRibbon.new()
	water.name = "Water"
	elevated = ElevatedSections.new()
	elevated.name = "Elevated"
	fog = FogCards.new()
	fog.name = "FogCards"
	for f: BiomeFeature in features():
		add_child(f)


## The feature nodes (water, elevated, fog).
func features() -> Array[BiomeFeature]:
	var out: Array[BiomeFeature] = [water, elevated, fog]
	return out


## Once, before the first setup: the road builder lowers its ground ribbon where the
## features need it (the city's viaducts, the coast's sea slope), and the water feeds
## the sky's Horizon material the sea direction. Both hooks go through the nodes, so
## they stay valid across retries. Either argument may be null.
func bind(builder: RoadBuilder, sky: SkyRig) -> void:
	if builder != null:
		builder.set_ground_drop(elevated.ground_drop_at, water.ground_drop_at)
	_sky = sky


func setup(ctx: RunContext, road: RoadPath, origin: FloatingOrigin) -> void:
	var lt: Variant = ctx.tuning.get(&"landmarks")
	clearance.setup(road, lt as LandmarkTuning if lt is LandmarkTuning else LandmarkTuning.load_default(),
		biome_director)
	elevated.clearance = clearance
	water.horizon_material = _sky.horizon_material() if _sky != null else null
	for f in features():
		f.biome_director = biome_director
		f.view_distance_override_m = view_distance_override_m
		f.setup(ctx, road, origin)


func update_view(focus_s: float) -> void:
	water.update_view(focus_s)
	elevated.update_view(focus_s)
	fog.update_view(focus_s)


## How far behind the focus the features and the ground-drop hook sample the road.
func reach_behind_m() -> float:
	var m := 0.0
	for f in features():
		if f.road != null:
			m = maxf(m, f.reach_behind_m())
	return m


## Draw calls of the features with geometry (one each).
func draw_calls() -> int:
	var n := 0
	for f in features():
		n += f.draw_calls()
	return n


func triangles() -> int:
	var n := 0
	for f in features():
		n += f.triangles()
	return n
