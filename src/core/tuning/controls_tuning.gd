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

@export_group("Gyro steering")
@export var gyro_max_angle_deg: float = 25.0
@export var gyro_dead_zone_deg: float = 2.0
@export var gyro_smoothing_ms: float = 60.0

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
