class_name HudTuning
extends Resource
## HUD, design-system metrics and run screens. Spec: Scoring → Score feedback;
## UI, HUD and design system; Legs (leg toast); Run end (retry); Accessibility (text size).
## Saved as data/tuning/hud.tres. Colors live in the Theme (ui/theme.tres), not here.

@export_group("Readouts")
@export var event_stack_lines: int = 4
@export var multiplier_display_max: float = 999.0
@export var multiplier_wobble_above: float = 20.0
@export var glitter_min_multiplier: float = 10.0   # not in spec: "at high multipliers"
## The minimum-speed bar appears when speed nears or drops below the minimum speed.
@export var min_speed_bar_show_below_kmh: float = 120.0   # not in spec: "nears"

@export_group("Screens")
@export var leg_toast_s: float = 2.5
@export var countdown_from: int = 3
@export var retry_max_s: float = 2.0
@export var text_scales: PackedFloat64Array = [1.0, 1.25]

@export_group("Design system")
@export var panel_bevel_px: float = 13.0
@export var control_bevel_px: float = 7.0
@export var neon_border_px: float = 1.5
@export var speed_tilt_deg: float = -7.0
@export var layout_grid_px: float = 46.0
@export var spacing_grid_px: float = 8.0
