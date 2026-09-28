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

@export_group("Props (roadside MultiMesh sets)")
## Parallel arrays: prop scene path and its density (instances per km, per side).
@export var prop_scenes: PackedStringArray = []
@export var prop_densities_per_km: PackedFloat64Array = []
## Typed prop sets placed by roadside.gd (WP1.4): scattered props and rows.
## The parallel arrays above predate it and stay empty for now.
@export var scatter_props: Array[RoadsideProp] = []
## Field grid (farmland); null = none.
@export var field_grid: FieldGridDef
## Right-of-way fence segment (ArrayMesh .res with a `length_m` meta); "" = none.
@export var fence_mesh_path: String = ""
## Scenery line (guardrail face + prop clearance) to the fence line.
@export var fence_setback_m: float = 0.0

@export_group("Look")
## Additive tint offsets applied over the color script (desert warmer, coast cooler).
@export var world_tint_offset: Color = Color(0, 0, 0, 0)
@export var fog_tint_offset: Color = Color(0, 0, 0, 0)
## Horizon silhouette cards, nearest first (3-4 layers).
@export var horizon_cards: PackedStringArray = []
## Horizon silhouette set id (the sky WP maps it to its cards).
@export var horizon_set: StringName = &""
## Ground albedo (sRGB) for the ground ribbon beyond the verge, and the verge strip.
@export var ground_color: Color = Color(0.5, 0.5, 0.5)
@export var verge_color: Color = Color(0.5, 0.5, 0.5)
## Per-instance traffic colors ("colors come from the biome palette").
@export var traffic_palette: PackedColorArray = []

@export_group("Traffic")
## Parallel arrays: SetPieceDef ids and their relative weights in this biome.
@export var set_piece_ids: Array[StringName] = []
@export var set_piece_weights: PackedFloat64Array = []

@export_group("Checkpoint")
@export var landmark_style: StringName = LANDMARK_SIGN_GANTRY
