class_name LoopSectionDef
extends Resource
## One section of the multiplayer loop (N3.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## The loop map (sections: desert straight, canyon, coast, city, farmland; lanes 3 by
## default, 4 in the desert and city). docs/LOOP_MAP.md. Part of LoopMapDef
## (data/maps/loop_v1.tres); LoopGen reads it.
##
## Plan view: the section is straight, bend, straight, ..., bend, straight. Bend i turns
## by bend_deflection_deg[i] (+ = right; the loop's last bend is recomputed so the heading
## closes) at a radius drawn in [bend_radius_min_m[i], bend_radius_max_m[i]]; the straights
## share what the bends leave of the section length by straight_weights (jittered by
## LoopMapDef.straight_weight_jitter_frac). Profile: PVIs every pvi_spacing_min..max_m,
## grades drawn within +-grade_max_pct, crest_count deliberate crests.

## BiomeDef id (data/biomes/<id>.tres): the look, props, landmarks, bend sight clearance.
@export var biome_id: StringName = &""
## Driving lanes per direction (the handoff's lane table; tunnels may narrow it).
@export var lanes: int = 3
## Where the lane count changes to `lanes` when it differs from the previous section's,
## relative to this section's start (negative: before it, in the previous section). The
## right edge tapers over RoadTuning.biome_lane_taper_m. Default: RoadTuning's
## biome_lane_change_after_m.
@export var lane_change_offset_m: float = 320.0

@export_group("Plan")
@export var bend_deflection_deg: PackedFloat64Array = []
@export var bend_radius_min_m: PackedFloat64Array = []
@export var bend_radius_max_m: PackedFloat64Array = []
## One more entry than bends: the straights before, between and after them.
@export var straight_weights: PackedFloat64Array = []

@export_group("Profile")
@export var grade_max_pct: float = 2.0
@export var pvi_spacing_min_m: float = 800.0
@export var pvi_spacing_max_m: float = 1400.0
## Deliberate crests (+g then -g over a sharp vertical curve; blind if the geometry says so).
@export var crest_count: int = 0

@export_group("Traffic")
## Lane flow speeds in this section, like TrafficTuning.lane_flow_speeds_from_right_kmh
## (lane i of n uses entry [n - 1 - i]). Exported to the road-space file.
@export var lane_flow_speeds_from_right_kmh: PackedFloat64Array = []
