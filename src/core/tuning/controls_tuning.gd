class_name ControlsTuning
extends Resource
## Drag, gyro, keyboard and first-run settings. Spec: Controls.
## Saved as data/tuning/controls.tres.

@export_group("Drag steering")
@export var drag_max_cm: float = 2.5   # physical screen distance, via DPI
@export var drag_dead_zone_pct: float = 4.0
## Shared by drag and gyro ("same response curve exponent as drag").
@export var response_curve_exponent: float = 1.6
@export var drag_release_ms: float = 80.0
## Auto mode: dragging down more than this share of max_drag brakes, proportionally.
@export var drag_brake_threshold_pct: float = 30.0
## Auto mode: an upward flick faster than this (finger speed) fires boost.
@export var flick_boost_min_mps: float = 0.6
## Finger speed is measured over at least this span, so event jitter can't fake a flick.
@export var flick_window_ms: float = 40.0   # not in spec: measurement window for "finger speed"
## After a flick, the upward speed must fall below this share of the threshold before
## the same finger can fire again (one boost per flick).
@export var flick_rearm_pct: float = 50.0   # not in spec: one boost per flick

@export_group("Gyro steering")
@export var gyro_max_angle_deg: float = 25.0
@export var gyro_dead_zone_deg: float = 2.0
@export var gyro_smoothing_ms: float = 60.0
## Below this gravity magnitude the sensor counts as absent (desktop, no data yet).
@export var gyro_min_gravity_mps2: float = 2.0   # not in spec: sensor-present check

@export_group("Gamepad")
## Stick and trigger dead zone; the stick then uses the shared response curve.
@export var gamepad_dead_zone_pct: float = 12.0   # not in spec: typical stick rest noise

@export_group("Screen")
## When the screen DPI is unknown (web, desktop, bogus value), the canvas height is
## taken to be this many cm: a phone held in landscape. Converts drag distance and
## pedal sizes from cm to canvas pixels.
@export var fallback_screen_height_cm: float = 6.8   # not in spec: typical phone landscape height

@export_group("Touch layout")
## Manual layouts: pedals and buttons, in physical cm (converted via DPI).
@export var pedal_width_cm: float = 2.2   # not in spec: thumb-sized pedal
@export var pedal_height_cm: float = 2.6   # not in spec: leaves the top HUD band clear
@export var button_size_cm: float = 1.3   # not in spec: boost button (and drag-manual brake width)
@export var controls_margin_cm: float = 0.5   # not in spec: gap to the safe-area edge
@export var controls_gap_cm: float = 0.3   # not in spec: gap between pedals and buttons
## Brake pedal: a touch at the pedal's bottom edge brakes this much, rising to 100% at
## the top ("proportional to how far up the pedal the thumb sits").
@export var pedal_brake_min_pct: float = 20.0   # not in spec: the bottom edge still brakes

@export_group("Player settings")
## Sensitivity, dead zone and curve settings are multipliers of the tuned values,
## clamped to this range (1 = the spec's numbers).
@export var setting_scale_min_factor: float = 0.5   # not in spec: settings slider range
@export var setting_scale_max_factor: float = 2.0   # not in spec: settings slider range

@export_group("Overlay")
@export var overlay_ring_alpha_pct: float = 40.0   # not in spec: "faint ring"
@export var overlay_ring_radius_px: float = 30.0   # not in spec: the anchor ring
@export var overlay_dot_radius_px: float = 12.0   # not in spec
@export var overlay_idle_alpha_pct: float = 55.0   # not in spec: pedals at rest
@export var overlay_label_px: float = 15.0   # not in spec

@export_group("Keyboard")
@export var keyboard_steer_ramp_s: float = 0.15

@export_group("First run")
@export var first_run_warmup_s: float = 20.0   # empty-road warm-up before traffic


func drag_max_m() -> float:
	return Units.cm_to_m(drag_max_cm)


func drag_dead_zone_frac() -> float:
	return Units.pct_to_frac(drag_dead_zone_pct)


func drag_release_s() -> float:
	return Units.ms_to_s(drag_release_ms)


func drag_brake_threshold_frac() -> float:
	return Units.pct_to_frac(drag_brake_threshold_pct)


func gyro_smoothing_s() -> float:
	return Units.ms_to_s(gyro_smoothing_ms)


## Gyro dead zone as a share of the max angle (the curve's normalized dead zone).
func gyro_dead_zone_frac() -> float:
	return gyro_dead_zone_deg / gyro_max_angle_deg


func flick_window_s() -> float:
	return Units.ms_to_s(flick_window_ms)


func flick_rearm_frac() -> float:
	return Units.pct_to_frac(flick_rearm_pct)


func gamepad_dead_zone_frac() -> float:
	return Units.pct_to_frac(gamepad_dead_zone_pct)


func pedal_brake_min_frac() -> float:
	return Units.pct_to_frac(pedal_brake_min_pct)
