class_name RoadPalette
extends Resource
## Authored base albedos (vertex COLOR, sRGB) of the road build. Spec: World → Road,
## World → Color script. See docs/CONTRACTS.md §13 (vertex conventions).
##
## These play the role of a model's vertex colors, not of the color script: the
## time of day comes from the global uniforms. Asphalt and lines are white because
## their tint classes (1 road surface, 2 lane line) multiply them by `wb_road_tone`
## and `wb_lane_line_tint`. The ground colors are neutral placeholders; the biome
## sets them through RoadBuilder.set_ground_colors().

## Driving lanes (tint class 1: x wb_road_tone).
@export var asphalt: Color = Color(1.0, 1.0, 1.0)
## Inner and outer shoulders (tint class 1), a touch lighter than the lanes.
@export var shoulder: Color = Color(1.12, 1.12, 1.12)
## Lane and edge lines (tint class 2: x wb_lane_line_tint).
@export var line: Color = Color(1.0, 1.0, 1.0)
## Raised reflectors on the lane lines (emissive class 1).
@export var reflector: Color = Color(1.0, 0.92, 0.75)
@export var barrier: Color = Color(0.72, 0.71, 0.68)
@export var guardrail: Color = Color(0.66, 0.68, 0.7)
## Ground ribbon: the verge strip next to the road, then the field out to the fog.
@export var ground_verge: Color = Color(0.5, 0.47, 0.4)
@export var ground_field: Color = Color(0.55, 0.53, 0.42)
