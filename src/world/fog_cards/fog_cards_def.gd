class_name FogCardsDef
extends Resource
## Low fog layers of a biome (valley fog: "low fog layers in valleys (cards), forests,
## dawn-friendly palette"). Spec: World → Biomes, Color script (the mist takes the
## fog color and the sun's in-scatter, so it reads at dawn, noon and night), Performance
## budget (one draw call). Drawn by FogCards (src/world/fog_cards/).
##
## Per cell along absolute s and per side, a bank of `layer_count` horizontal
## translucent cards stacked above the ground, set back from the scenery line (never
## over the road), each faded at its edges, broken up by noise and faded out near the
## camera. Banks are denser where the road runs through a dip (the valley floor).

## Placement cell along s; a bank's length is `length_factor` x the cell (> 1 overlaps
## the neighbours, so banks join into long layers).
@export var cell_length_m: float = 320.0
@export var chance_frac: float = 0.7
@export var length_factor_min: float = 1.1
@export var length_factor_max: float = 1.8
## Scenery line to the bank's near edge, and the bank's depth across.
@export var setback_min_m: float = 18.0
@export var setback_max_m: float = 90.0
@export var depth_min_m: float = 180.0
@export var depth_max_m: float = 480.0

@export_group("Layers")
@export var layer_count: int = 3
@export var base_height_m: float = 0.5
@export var layer_spacing_m: float = 1.1
## Peak opacity of one layer (linear-light coverage).
@export var alpha: float = 0.3
## Edge fade as a fraction of the card (across and along).
@export var edge_softness_frac: float = 0.3
## Brightness of the mist relative to the fog color (lighter than the air around it).
@export var brightness_factor: float = 1.06
## Opacity factor with a high sun (the mist burns off toward midday), reached at sun
## elevation sine `midday_sun_y`; 1 at and below the horizon.
@export var midday_factor: float = 0.5
@export var midday_sun_y: float = 0.5
## Noise breakup: feature size (m) and how much of the opacity it removes at most.
@export var noise_scale_m: float = 70.0
@export var noise_depth_frac: float = 0.55
## Fully transparent within `near_clear_m` of the camera, full after + `near_fade_m`.
@export var near_clear_m: float = 25.0
@export var near_fade_m: float = 70.0

## Vertical mist curtains per bank (0-2), evenly across its depth ending at the far edge,
## seen face-on from the road: fog banks between the forests. Height and opacity.
@export var curtain_count: int = 1
@export var curtain_height_m: float = 9.0
@export var curtain_alpha: float = 0.35

@export_group("Valleys")
## Dips: the road's elevation at s against the mean at s +- valley_probe_m. A dip of
## `valley_depth_m` or more gives full opacity and chance; none gives `ridge_factor`.
@export var valley_probe_m: float = 600.0
@export var valley_depth_m: float = 6.0
@export var ridge_factor: float = 0.45

@export_group("Mesh")
## Rows along s (cards bend with the road).
@export var row_step_m: float = 40.0
## Background build budget of the next window: banks per frame.
@export var build_units_per_frame: int = 2
@export var rebuild_step_m: float = 100.0
