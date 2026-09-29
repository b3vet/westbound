class_name QualityTuning
extends Resource
## Quality tiers, frame caps and the adaptive governor. Spec: Performance budget
## (quality tiers table, frame rate, adaptive governor, draw-call and triangle budget).
## Saved as data/tuning/quality.tres. Per-tier arrays are indexed like `tier_names`.
## Schema frozen in WP0.2 (WP0.3 codes against it).

@export var tier_names: PackedStringArray = ["low", "medium", "high"]
@export var default_tier: String = "medium"
@export var render_scale: PackedFloat64Array = [0.6, 0.75, 0.9]
@export var msaa_samples: PackedInt32Array = [0, 0, 2]   # 0 = off, 2 = 2x
@export var view_distance_m: PackedFloat64Array = [500.0, 700.0, 800.0]
@export var particle_scale: PackedFloat64Array = [0.5, 1.0, 1.0]
@export var web_msaa_samples: int = 0
@export var gameplay_fps: int = 60
@export var menu_fps: int = 30
@export var battery_saver_fps: int = 30
@export var governor_window_s: float = 10.0
@export var governor_miss_frac: float = 0.10
@export var governor_step_down_interval_s: float = 10.0
@export var governor_step_up_after_s: float = 60.0
@export var governor_render_scale_step: float = 0.1
@export var governor_render_scale_floor: float = 0.5
@export var governor_particle_step_frac: float = 0.5
@export var governor_view_distance_step_m: float = 150.0
@export var governor_fps_floor: int = 30
@export var draw_call_budget: int = 100
@export var triangle_budget: int = 150000
@export var far_plane_margin_m: float = 20.0   # not in spec: "far plane just past the fog end"
## Dev HUD quality row (WP4.6): render scale and MSAA steps it cycles through, live,
## for the session (Quality.set_dev_override). Ascending.
@export var dev_render_scale_steps: PackedFloat64Array = [0.6, 0.75, 0.85, 1.0]   # not in spec: dev tool
@export var dev_msaa_steps: PackedInt32Array = [0, 2, 4]   # not in spec: dev tool


## Index of `tier` in tier_names, or -1.
func tier_index(tier: String) -> int:
	return tier_names.find(tier)
