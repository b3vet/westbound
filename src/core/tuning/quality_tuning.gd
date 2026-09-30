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

## Adaptive governor details (WP9.1, src/platform/governor.gd, docs/QUALITY.md). The spec
## gives the window, the miss share, the 10 s / 60 s timings and the rungs above; these
## say how a "miss" and "headroom" are measured.
## A frame misses vsync when it takes longer than this many target frame intervals.
@export var governor_miss_factor: float = 1.5   # not in spec: miss detection
## Headroom (for stepping up): at most this share of the window's frames missed. Between
## this and governor_miss_frac the governor holds (hysteresis band).
@export var governor_up_miss_frac: float = 0.02   # not in spec: hysteresis
## Longer frames (loading, the app in the background) are not sampled, and the governor's
## timers advance at most this much per frame.
@export var governor_ignore_frame_s: float = 0.5   # not in spec
## A step down within this long of a step up multiplies the next wait to step up by
## governor_up_backoff_factor (up to governor_step_up_max_s), so a device on the edge
## does not oscillate. Staying down-free this long after a step up resets the wait.
@export var governor_relapse_window_s: float = 60.0   # not in spec: hysteresis
@export var governor_up_backoff_factor: float = 2.0   # not in spec: hysteresis
@export var governor_step_up_max_s: float = 300.0   # not in spec: hysteresis
## Dev HUD frame-time percentile and its histogram (bin width, range).
@export var governor_report_percentile: float = 0.95   # not in spec: dev tool
@export var governor_hist_bin_ms: float = 0.5   # not in spec: dev tool
@export var governor_hist_max_ms: float = 100.0   # not in spec: dev tool
## Spec: the "cooling" icon shows while the governor is active. false (WP9.1, flagged):
## only while a thermal step is part of the offset, so a device that sits one rung down for
## frame time alone does not show a hot-phone icon all the time.
@export var cooling_icon_any_reason: bool = false   # deviation switch, see docs/QUALITY.md
## The view-distance rung is held from a run's start to its end and applied between runs,
## because the view distance still feeds the simulation (docs/QUALITY.md → Simulation
## safety; N8.2). Set false once nothing in the sim reads the view distance.
@export var governor_view_distance_between_runs: bool = true   # not in spec: sim safety
## Native thermal plugins (src/platform/thermal.gd): how often the state is polled (the
## plugins also signal changes), and each platform's raw states mapped to the four levels
## (0 nominal, 1 fair, 2 serious, 3 critical). iOS ProcessInfo.ThermalState: nominal, fair,
## serious, critical. Android PowerManager THERMAL_STATUS_*: none, light, moderate, severe,
## critical, emergency, shutdown (moderate already throttles: step down there).
@export var thermal_poll_s: float = 2.0   # not in spec
@export var thermal_ios_levels: PackedInt32Array = [0, 1, 2, 3]
@export var thermal_android_levels: PackedInt32Array = [0, 1, 2, 3, 3, 3, 3]   # not in spec: mapping


## Index of `tier` in tier_names, or -1.
func tier_index(tier: String) -> int:
	return tier_names.find(tier)
