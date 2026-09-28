extends Resource
## Test double for `QualityTuning` (src/core/tuning/quality_tuning.gd, WP0.2).
## Same exported fields and spec values; used duck-typed by src/platform/quality.gd.

@export var tier_names: PackedStringArray = ["low", "medium", "high"]
@export var default_tier: String = "medium"
@export var render_scale: PackedFloat64Array = [0.6, 0.75, 0.9]
@export var msaa_samples: PackedInt32Array = [0, 0, 2]
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
@export var far_plane_margin_m: float = 20.0
