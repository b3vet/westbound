class_name RoadsideProp
extends Resource
## One scattered roadside prop set of a biome (trees, turbines, lone buildings).
## Spec: World → Biomes ("Biome data: prop sets and densities"), Road
## (roadside rhythm, all MultiMeshInstance3D). Used by BiomeDef.scatter_props
## and placed by roadside.gd (one MultiMesh per mesh variant).
##
## Placement is per cell of `cell_length_m` along absolute s and per side, from
## the props Rng stream seeded by (run seed, prop id, cell index), so it never
## depends on how the player drove. Setbacks are measured outward from the
## scenery line (guardrail face + RoadTuning.prop_clearance_m) to the nearest
## edge of the mesh's footprint, so nothing ever enters the road.

enum Pattern {
	SCATTER,  ## single instances
	ROW,      ## rows of instances parallel to the road (tree lines, turbine rows)
}
enum Sides { BOTH, RIGHT, LEFT }
enum Facing {
	ROAD,     ## aligned with the road (+ yaw_jitter_deg)
	RANDOM,   ## any yaw
}

@export var id: StringName = &""
## Mesh variants (ArrayMesh .res paths); each is one MultiMesh (one draw call).
@export var mesh_paths: PackedStringArray = []
## Relative weights of the variants (empty = equal).
@export var variant_weights: PackedFloat64Array = []
@export var pattern: Pattern = Pattern.SCATTER
@export var sides: Sides = Sides.BOTH
## Instances (SCATTER) or rows (ROW) per km per side.
@export var density_per_km: float = 0.0
## Placement cell; a ROW must fit inside one cell.
@export var cell_length_m: float = 200.0
@export var setback_min_m: float = 0.0
@export var setback_max_m: float = 0.0
@export var facing: Facing = Facing.ROAD
## Fixed turn toward the road for Facing.ROAD (billboards toe in to face drivers).
@export var yaw_offset_deg: float = 0.0
@export var yaw_jitter_deg: float = 0.0
@export var scale_min_factor: float = 1.0
@export var scale_max_factor: float = 1.0
@export_group("Row")
@export var row_count_min: int = 1
@export var row_count_max: int = 1
@export var row_spacing_m: float = 10.0


## Expected instances (SCATTER) or rows (ROW) per cell per side.
func per_cell_mean() -> float:
	return density_per_km * cell_length_m / Units.km_to_m(1.0)


## Upper bound of instances per cell per side (sizes the MultiMesh pools).
func per_cell_max() -> int:
	var n := int(floor(per_cell_mean())) + 1
	return n * (row_count_max if pattern == Pattern.ROW else 1)
