class_name ElevatedDef
extends Resource
## Elevated highway stretches of a biome (city at night: "skyline, elevated highway
## sections, neon billboards"). Spec: World → Biomes, Road (cross-section, guardrails),
## Performance budget. Drawn by ElevatedSections (src/world/elevated/); the stretches
## come from ElevatedPlan. The road keeps its level: the *ground* drops away beneath
## it (ElevatedPlan.drop_at) and piers, deck edges, parapets and the deck's underside
## appear. Lowering the ground ribbon is RoadChunkMesher's job (GroundDropMesher
## shows the hook; docs/BIOMES.md).

@export_group("Plan")
## Stretches are planned per cell of this length along absolute s: each cell holds at
## most one stretch, with `chance_frac`, entirely inside the biome's span.
@export var cell_length_m: float = 1400.0
@export var chance_frac: float = 0.6
## Stretch length including both ramps.
@export var length_min_m: float = 700.0
@export var length_max_m: float = 1250.0
## Length over which the ground falls from road level to `height_m` (and back).
@export var ramp_m: float = 220.0
## Road deck above the ground at full height.
@export var height_m: float = 10.0

@export_group("Structure")
## Girder depth under the deck (the fascia band) and the deck's overhang beyond the
## guardrail face.
@export var girder_depth_m: float = 1.6
@export var deck_overhang_m: float = 0.9
## Concrete parapet on the deck edge.
@export var parapet_height_m: float = 1.0
@export var parapet_width_m: float = 0.35
## Piers: one hammerhead pier under each carriageway every `pier_spacing_m`.
@export var pier_spacing_m: float = 40.0
@export var pier_width_m: float = 1.8
@export var cap_depth_m: float = 1.3
@export var cap_length_m: float = 2.4
## Piers stand only where the column (below girder and cap) is at least this tall.
@export var pier_min_height_m: float = 2.0
## Rows of the deck edge and underside along s.
@export var row_step_m: float = 20.0
## Background build budget of the next window: row intervals or pier positions per frame.
@export var build_units_per_frame: int = 4
@export var rebuild_step_m: float = 100.0

@export_group("Colors (sRGB)")
@export var concrete_color: Color = Color(0.66, 0.66, 0.64)
@export var fascia_color: Color = Color(0.56, 0.57, 0.58)
@export var underside_color: Color = Color(0.3, 0.31, 0.33)
@export var pier_color: Color = Color(0.6, 0.6, 0.6)
## Ground under the road between the two lowered ground ribbons.
@export var under_ground_color: Color = Color(0.33, 0.34, 0.35)
