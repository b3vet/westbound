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
## Look back from the right stick: pushed down (back) past this share of its travel looks
## back; it lets go below the release share (hysteresis, no flicker at the threshold).
@export var gamepad_look_back_stick_pct: float = 60.0   # not in spec
@export var gamepad_look_back_release_pct: float = 40.0   # not in spec
## Menus: the left stick moves the focus like the D-pad once past this share of its
## travel, and counts as released below the release share.
@export var pad_nav_stick_pct: float = 50.0   # not in spec
@export var pad_nav_release_pct: float = 30.0   # not in spec
## Menus: a held D-pad direction or stick repeats after this delay, then at this period.
@export var pad_nav_repeat_delay_s: float = 0.4   # not in spec
@export var pad_nav_repeat_s: float = 0.12   # not in spec

@export_group("Screen")
## When the screen DPI is unknown (web, desktop, bogus value), the canvas height is
## taken to be this many cm: a phone held in landscape. Converts drag distance and
## pedal sizes from cm to canvas pixels.
@export var fallback_screen_height_cm: float = 6.8   # not in spec: typical phone landscape height
## WP9.7: on a phone, the HUD, the menus and the touch controls keep at least this far
## from the left edge (the 3D view stays full-bleed) when the platform reports a smaller
## left safe-area inset (Safari may report 0). The Dynamic Island's far edge in
## landscape is 11 pt + 37 pt = 48 pt ≈ 0.8 cm on a 460 ppi, 3x iPhone; the HUD adds its
## edge margin (16 px ≈ 0.15 cm) on top, so its panels start ≈ 0.85 cm in. Most players
## hold the phone with its camera on the left; the right side only gets a reported inset.
## 0.7 still fits the whole HUD at 125 % text on a 16:9 canvas (tests/ui/test_hud_layout.gd).
@export var min_left_inset_cm: float = 0.7   # not in spec: owner request (WP9.7)

@export_group("Touch layout")
## Manual layouts, in physical cm (converted via DPI), all multiplied by the
## controls_scale setting. One thumb per side (plan D9): the gas pedal carries the
## boost cap directly above it (one joined control), the brake is its own pedal.
@export var pedal_width_cm: float = 1.3   # not in spec: gas pedal and boost cap width
@export var pedal_height_cm: float = 1.6   # not in spec: gas pedal (below the cap)
@export var boost_cap_height_cm: float = 0.8   # not in spec: boost cap on top of the gas pedal
@export var brake_width_cm: float = 1.2   # not in spec
@export var brake_height_cm: float = 1.8   # not in spec
@export var controls_margin_cm: float = 0.4   # not in spec: gap to the safe-area edge (not scaled)
@export var controls_gap_cm: float = 0.3   # not in spec: gap between the gas column and the brake
## A pedal finger is captured until it lifts: it only switches to the other pedal once
## it is on that pedal and this far outside its own control.
@export var pedal_capture_cm: float = 0.6   # not in spec: a moving thumb doesn't drop gas
## After a boost, the thumb must come back this far below the cap before sliding up
## boosts again (the joint line can't jitter out a second boost).
@export var boost_cap_rearm_cm: float = 0.25   # not in spec
## Brake pedal: a touch at the pedal's bottom edge brakes this much, rising to 100% at
## the top ("proportional to how far up the pedal the thumb sits").
@export var pedal_brake_min_pct: float = 20.0   # not in spec: the bottom edge still brakes
## The LOOK BACK hold button (owner request, 2026-10-03): just above the gas column, the
## same width, this gap above the boost cap (in every layout: where the gas column sits
## in the manual layouts, the same spot in the auto ones). Held = the rear view.
@export var look_back_width_cm: float = 1.3   # not in spec: as wide as the gas column
@export var look_back_height_cm: float = 0.9   # not in spec
@export var look_back_gap_cm: float = 0.35   # not in spec: clear of a thumb on the boost cap
## The button never grows past its 100 % size, and with large controls it gets shorter
## (down to look_back_min_height_cm), then closer to the cap (down to
## look_back_min_gap_cm), rather than start closer than look_back_top_clear_cm
## to the safe area's top: the HUD's lives and buttons up there and the achievement
## toast under them (125 % text: 2.42 cm on a 6.8 cm canvas, with the pedal clearance).
@export var look_back_top_clear_cm: float = 2.45   # not in spec: the HUD's top-right block
@export var look_back_min_height_cm: float = 0.6   # not in spec
@export var look_back_min_gap_cm: float = 0.15   # not in spec

@export_group("Player settings")
## Sensitivity, dead zone and curve settings are multipliers of the tuned values,
## clamped to this range (1 = the spec's numbers).
@export var setting_scale_min_factor: float = 0.5   # not in spec: settings slider range
@export var setting_scale_max_factor: float = 2.0   # not in spec: settings slider range
## The controls_scale setting (size of every touch control and the drag visuals).
@export var controls_scale_min_factor: float = 0.6   # not in spec: settings slider range
@export var controls_scale_max_factor: float = 1.6   # not in spec: settings slider range

@export_group("Overlay")
@export var overlay_ring_alpha_pct: float = 40.0   # not in spec: "faint ring"
@export var overlay_ring_radius_px: float = 30.0   # not in spec: the anchor ring
@export var overlay_dot_radius_px: float = 12.0   # not in spec
@export var overlay_idle_alpha_pct: float = 55.0   # not in spec: pedals at rest
@export var overlay_label_px: float = 15.0   # not in spec
## Drag visual "wheel" (plan D10): a faceted steering wheel on the anchor, turning with
## the steer value. Visual only.
@export var wheel_visual_diameter_cm: float = 2.4   # not in spec
@export var wheel_visual_max_deg: float = 135.0   # not in spec: wheel angle at full steer
@export var wheel_facets: int = 12   # not in spec: low-poly rim
@export var wheel_rim_inner_pct: float = 76.0   # not in spec: inner rim radius, % of outer
@export var wheel_hub_pct: float = 26.0   # not in spec: hub radius, % of outer
@export var wheel_spoke_width_pct: float = 18.0   # not in spec: spoke width, % of outer radius
@export var wheel_edge_alpha_pct: float = 85.0   # not in spec: rim and spoke edges

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


func wheel_visual_max_rad() -> float:
	return deg_to_rad(wheel_visual_max_deg)


func gamepad_look_back_frac() -> float:
	return Units.pct_to_frac(gamepad_look_back_stick_pct)


func gamepad_look_back_release_frac() -> float:
	return Units.pct_to_frac(gamepad_look_back_release_pct)


func pad_nav_stick_frac() -> float:
	return Units.pct_to_frac(pad_nav_stick_pct)


func pad_nav_release_frac() -> float:
	return Units.pct_to_frac(pad_nav_release_pct)
