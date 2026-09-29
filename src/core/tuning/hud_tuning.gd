class_name HudTuning
extends Resource
## HUD, design-system metrics and run screens. Spec: Scoring → Score feedback;
## UI, HUD and design system; Legs (leg toast); Run end (retry); Accessibility (text size).
## Saved as data/tuning/hud.tres. Colors live in the Theme (src/ui/theme/theme.tres,
## built by UiTheme), not here. docs/HUD.md.
##
## Pixel values are canvas pixels (the 720 px tall stretched canvas) at 100% text
## size; the HUD multiplies sizes (not margins) by the text-size setting.

@export_group("Readouts")
@export var event_stack_lines: int = 4
@export var multiplier_display_max: float = 999.0
@export var multiplier_wobble_above: float = 20.0
@export var glitter_min_multiplier: float = 10.0   # not in spec: "at high multipliers"
## The minimum-speed bar appears when speed nears or drops below the minimum speed.
@export var min_speed_bar_show_below_kmh: float = 120.0   # not in spec: "nears"
## ...and hides again this far above the show threshold (no flicker at the edge).
@export var min_speed_bar_hysteresis_kmh: float = 4.0   # not in spec
## "12.4×" below this multiplier, whole numbers ("124×") from it.
@export var multiplier_decimals_below: float = 100.0   # not in spec
## Speedometer bar: slanted segments; their height ramps from this share to full.
@export var speed_bar_segments: int = 26
@export var speed_bar_ramp_min_pct: float = 38.0
@export var boost_bar_segments: int = 12
## Segments lean like the speed-tilted type (horizontal shift of a segment's top, as a
## share of its height).
@export var segment_lean_pct: float = 22.0

@export_group("Animation")
## Event lines: pop-in slide, time fully shown, fade-out.
@export var event_slide_s: float = 0.14
@export var event_pop_px: float = 28.0
@export var event_hold_s: float = 1.8
@export var event_fade_s: float = 0.5
## Older lines dim so the newest reads first (alpha per step down the stack).
@export var event_age_dim_pct: float = 14.0
## The chain readout pulses on every scored event.
@export var chain_pulse_s: float = 0.22
@export var chain_pulse_scale_pct: float = 16.0
## Banking: the chain flies into the banked total, then the total counts up.
@export var bank_fly_s: float = 0.45
@export var bank_count_s: float = 0.9
## Life icons: breaking on a hit, popping back on life_restored.
@export var life_break_s: float = 0.6
@export var life_restore_s: float = 0.35
@export var ghost_pulse_hz: float = 2.0
@export var boost_pulse_hz: float = 4.0
@export var too_slow_pulse_hz: float = 2.5
## Multiplier hue cycle: turns per second = base + per_x × (multiplier − 1), capped.
@export var mult_hue_hz_base: float = 0.08
@export var mult_hue_hz_per_x: float = 0.025
@export var mult_hue_hz_max: float = 1.2
@export var mult_hue_saturation_pct: float = 50.0
## Wobble above multiplier_wobble_above: amplitude ramps to full at mult_wobble_full_at.
@export var mult_wobble_deg: float = 5.0
@export var mult_wobble_hz: float = 3.2
@export var mult_wobble_full_at: float = 60.0
## Glitter burst on close passes and threads at high multipliers.
@export var glitter_count: int = 14
@export var glitter_max: int = 32
@export var glitter_s: float = 0.75
@export var glitter_speed_px_s: float = 320.0
@export var glitter_gravity_px_s2: float = 520.0
@export var glitter_size_px: float = 6.0

@export_group("Layout")
## Gap between the HUD and the safe-area edge (not scaled by text size).
@export var edge_margin_px: float = 16.0
## Minimum gap between HUD panels and the touch controls (not scaled).
@export var pedal_clearance_px: float = 16.0
@export var score_size_px: Vector2 = Vector2(244.0, 96.0)
@export var sun_bar_size_px: Vector2 = Vector2(392.0, 50.0)
@export var chain_row_size_px: Vector2 = Vector2(360.0, 44.0)
@export var event_line_height_px: float = 29.0
@export var lives_icon_px: float = 30.0
@export var button_size_px: Vector2 = Vector2(58.0, 46.0)
@export var speedo_size_px: Vector2 = Vector2(276.0, 110.0)
## The minimum-speed strip that appears above the speedometer.
@export var min_speed_row_px: float = 34.0
@export var boost_size_px: Vector2 = Vector2(232.0, 72.0)
## Inside the panels: padding, bar sizes, the accent tab on each panel's top edge.
@export var panel_padding_px: float = 12.0
@export var sun_track_px: float = 6.0
@export var sun_marker_px: float = 7.0
@export var speed_bar_height_px: float = 30.0
@export var boost_bar_height_px: float = 20.0
@export var segment_gap_px: float = 3.0
@export var accent_tab_size_px: Vector2 = Vector2(34.0, 3.0)
## Panel fill opacity (the world shows faintly through; the neon edge stays solid).
@export var panel_alpha_pct: float = 90.0
## Idle panel edge: the muted line color at this opacity (active edges are solid).
@export var panel_edge_alpha_pct: float = 70.0
## Readout outline for text drawn straight over the world (chain, events).
@export var text_outline_px: float = 4.0
@export var text_outline_alpha_pct: float = 80.0
## ...and its drop shadow, straight down, as a share of the font size (same atlas as
## the fill, so no extra draw call).
@export var text_shadow_em_pct: float = 11.0

@export_group("Type")
## Font sizes (Chakra Petch; theme font sizes are built from these).
@export var font_label_px: int = 13
@export var font_small_px: int = 16
@export var font_score_px: int = 36
@export var font_readout_px: int = 32
@export var font_event_px: int = 22
@export var font_speed_px: int = 62
@export var font_button_px: int = 16
## Letter spacing of the uppercase tracked labels.
@export var label_tracking_px: int = 2

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


## The text-size setting clamped to the offered range (100%..125%).
func clamp_text_scale(value: float) -> float:
	if text_scales.is_empty():
		return 1.0
	var lo := text_scales[0]
	var hi := text_scales[0]
	for s in text_scales:
		lo = minf(lo, s)
		hi = maxf(hi, s)
	return clampf(value, lo, hi)


func speed_tilt_rad() -> float:
	return deg_to_rad(speed_tilt_deg)
