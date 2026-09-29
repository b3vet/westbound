class_name BiomeDef
extends Resource
## One biome (one leg's look and layout). Spec: World → Biomes ("Biome data":
## prop sets and densities, tint offsets, lane count, set-piece mix, horizon
## silhouette set and checkpoint landmark style). Files: data/biomes/<id>.tres.
## Time of day comes from the sun, never from the biome.

## Checkpoint landmark styles (Legs and checkpoints).
const LANDMARK_TOLL_GANTRY := &"toll_gantry"
const LANDMARK_SUSPENSION_BRIDGE := &"suspension_bridge"
const LANDMARK_SIGN_GANTRY := &"sign_gantry"
const LANDMARK_TUNNEL_PORTAL := &"tunnel_portal"

@export var id: StringName = &""
@export var display_name: String = ""
## Default order position (1 = farmland ... 6 = valley fog); forks swap the next biome.
@export var order: int = 0

@export_group("Road")
@export var lane_count: int = 3
## Relative to the road generator's defaults (1 = default). Canyon > 1, desert < 1.
@export var curve_frequency_scale: float = 1.0
@export var crest_frequency_scale: float = 1.0
@export var tunnel_frequency_scale: float = 0.0
## Lateral clearance from the driving line to sight obstructions inside a bend for this
## biome's BLIND_BEND rule (cliffs close to the road hide traffic; 0 = the road default,
## RoadTuning.bend_sight_clearance_m).
@export var bend_sight_clearance_m: float = 0.0

@export_group("Props (roadside MultiMesh sets)")
## Typed prop sets placed by roadside.gd (WP1.4): scattered props and rows.
@export var scatter_props: Array[RoadsideProp] = []
## Field grid (farmland); null = none.
@export var field_grid: FieldGridDef
## Right-of-way fence segment (ArrayMesh .res with a `length_m` meta); "" = none.
@export var fence_mesh_path: String = ""
## Scenery line (guardrail face + prop clearance) to the fence line.
@export var fence_setback_m: float = 0.0
## Rock walls following the road (canyon), placed as roadside segments; null = none.
@export var cliffs: CliffDef

@export_group("Look")
## Additive tint offsets applied over the color script (desert warmer, coast cooler).
@export var world_tint_offset: Color = Color(0, 0, 0, 0)
@export var fog_tint_offset: Color = Color(0, 0, 0, 0)
## Horizon silhouette cards, nearest first (3-4 layers). Unused: the horizon is
## procedural (horizon_layer_style / horizon_layer_height_m below).
@export var horizon_cards: PackedStringArray = []
## Horizon silhouette set id (a name for the set below; docs and tests).
@export var horizon_set: StringName = &""
## The set: per layer (x = nearest .. w = farthest) a SkyRig.HorizonStyle and the
## silhouette height at the layer's virtual distance. The sky crossfades between the
## sets of consecutive legs (BiomeDirector, docs/BIOMES.md).
@export var horizon_layer_style: Vector4 = Vector4(1, 2, 3, 3)
@export var horizon_layer_height_m: Vector4 = Vector4(90.0, 380.0, 1000.0, 3600.0)
## Fake heat shimmer on the far horizon cards (0 = none, 1 = full; desert), faded by the
## sun's height (horizon.gdshader). No screen-space effect.
@export var heat_shimmer: float = 0.0
## Ground albedo (sRGB) for the ground ribbon beyond the verge, and the verge strip.
@export var ground_color: Color = Color(0.5, 0.5, 0.5)
@export var verge_color: Color = Color(0.5, 0.5, 0.5)
## Rock (sRGB) of road-built rock masses: the hill over a road tunnel (face, then the
## shaded slopes). Tunnel portals, walls and lamps keep the road palette.
@export var rock_color: Color = Color(0.47, 0.56, 0.25)
@export var rock_shade_color: Color = Color(0.66, 0.63, 0.35)
## Per-instance traffic colors ("colors come from the biome palette").
@export var traffic_palette: PackedColorArray = []

@export_group("Traffic")
## Parallel arrays: SetPieceDef ids and their relative weights in this biome.
@export var set_piece_ids: Array[StringName] = []
@export var set_piece_weights: PackedFloat64Array = []

@export_group("Checkpoint")
## The checkpoint landmark of a leg in this biome (when `landmark_styles` is empty).
@export var landmark_style: StringName = LANDMARK_SIGN_GANTRY
## Several styles (not in spec: variety, WP5.5): the biome's legs cycle through them in
## this order from a seeded start (`checkpoint_style`). Empty = always `landmark_style`.
@export var landmark_styles: Array[StringName] = []


## The landmark style of the checkpoint ending leg `leg_index` (1-based) in this biome:
## `landmark_style`, or, with several `landmark_styles`, the list cycled by leg index
## from a start picked by `style_seed` (the run's props stream, BiomeDirector) and the
## biome id. Deterministic; consecutive legs never repeat a style.
func checkpoint_style(leg_index: int, style_seed: int) -> StringName:
	var n := landmark_styles.size()
	if n == 0:
		return landmark_style
	var start := posmod(TraceHash.mix_int(style_seed, Rng.fnv1a32(String(id))), n)
	return landmark_styles[posmod(start + leg_index - 1, n)]


# ---------------------------------------------------------------- WP6.4b (biomes 4-6)
# Additive world features of the coast, city and valley biomes. Each is optional
# (null = the biome has no such feature) and is drawn by its own world-system node
# under src/world/ (docs/BIOMES.md). Kept in one block so parallel biome work
# on the fields above does not conflict.

@export_group("WP6.4b")
## Water beside the road (coast: the ocean; valley: river glimpses). WaterRibbon.
@export var water: WaterDef
## Elevated highway stretches (city): piers, deck edges, the ground dropped below.
## ElevatedSections.
@export var elevated: ElevatedDef
## Low fog layers (valley): translucent cards beside the road. FogCards.
@export var fog_cards: FogCardsDef
## The horizon extensions of this biome's set (`horizon_set`, over horizon_layer_style
## / _height_m): sea-side masks, mist and skyline windows (horizon_biomes.gdshader).
## HorizonSetDef.apply_blend().
@export var horizon_def: HorizonSetDef
