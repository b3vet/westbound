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

@export_group("Look")
## Additive tint offsets applied over the color script (desert warmer, coast cooler).
@export var world_tint_offset: Color = Color(0, 0, 0, 0)
@export var fog_tint_offset: Color = Color(0, 0, 0, 0)
## Horizon silhouette cards, nearest first (3-4 layers).
@export var horizon_cards: PackedStringArray = []
## Per-instance traffic colors ("colors come from the biome palette").
@export var traffic_palette: PackedColorArray = []

@export_group("Traffic")
## Parallel arrays: SetPieceDef ids and their relative weights in this biome.
@export var set_piece_ids: Array[StringName] = []
@export var set_piece_weights: PackedFloat64Array = []

@export_group("Checkpoint")
@export var landmark_style: StringName = LANDMARK_SIGN_GANTRY
