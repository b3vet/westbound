class_name FieldGridDef
extends Resource
## Farmland's field grid: crop tiles in bands parallel to the road, with the odd
## yard (farmstead, grain bins, windpump, water tower) and windbreak tree lines
## along band edges. Spec: World → Biomes (farmland plains: golden fields,
## silos, windmills, water towers, long views). Placed by roadside.gd.
##
## Tiles are `cell_length_m` long (along s) and `band_depth_m` deep, starting
## `setback_m` beyond the scenery line (guardrail face + prop clearance). Each
## tile is a crop, bare ground, or a yard; the choice comes from the props Rng
## stream seeded per cell, so a structure never stands in a crop tile.

@export var cell_length_m: float = 120.0
@export var band_depth_m: float = 70.0
@export var band_count: int = 5
## Bare strip between tiles (tracks, verges); also absorbs curvature.
@export var gap_m: float = 6.0
@export var setback_m: float = 10.0
@export_group("Crops")
## Unit-square crop tiles (ArrayMesh .res), scaled to the tile.
@export var crop_mesh_paths: PackedStringArray = []
@export var crop_weights: PackedFloat64Array = []
## Chance a tile is left as bare ground (pasture).
@export var bare_chance_frac: float = 0.1
@export_group("Yards")
@export var yard_chance_frac: float = 0.1
## Yards only in the nearest bands (they read best close up).
@export var yard_band_count: int = 3
@export var yard_mesh_paths: PackedStringArray = []
@export var yard_weights: PackedFloat64Array = []
@export_group("Tree lines")
## Chance of a windbreak row on a band's outer edge.
@export var tree_row_chance_frac: float = 0.2
@export var tree_mesh_paths: PackedStringArray = []
@export var tree_weights: PackedFloat64Array = []
@export var tree_spacing_m: float = 9.0
@export var tree_scale_min_factor: float = 0.85
@export var tree_scale_max_factor: float = 1.15


func trees_per_row() -> int:
	return int(floor(cell_length_m / tree_spacing_m))
