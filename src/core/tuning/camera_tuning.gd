class_name CameraTuning
extends Resource
## Camera modes and shared behaviors. Spec: Cameras; Game feel (shake, FOV punch);
## Accessibility -> Reduced motion. Saved as data/tuning/camera.tres. Used by CameraRig
## (src/camera/camera_rig.gd).
##
## Per-mode values are parallel arrays indexed like `modes` (the QualityTuning tier
## pattern): adding a mode (e.g. cockpit, once cars have interiors) means appending one
## entry to `modes` and to every `mode_*` array. `mode_arrays_error()` checks the sizes.

@export var modes: PackedStringArray = ["chase", "far", "hood", "overhead"]
@export var default_mode: String = "chase"

@export_group("Speed response")
@export var fov_min_deg: float = 62.0
@export var fov_min_speed_kmh: float = 100.0
## Reached at the car's top speed.
@export var fov_max_deg: float = 78.0
@export var distance_pullback_max_pct: float = 15.0

@export_group("Look-ahead and roll")
@export var look_ahead_max_m: float = 1.2
@export var roll_max_deg: float = 1.5
## Road-relative lateral speed (m/s, d_dot) at which the look-ahead reaches look_ahead_max_m.
@export var look_ahead_full_lat_mps: float = 4.0   # not in spec: a lane change peaks at ~4-6 m/s
## Spring on the look-ahead shift.
@export var look_ahead_hz: float = 2.0   # not in spec
@export var look_ahead_damping_ratio: float = 1.0   # not in spec
## Lateral acceleration (m/s^2, + right) at which the roll reaches roll_max_deg.
@export var roll_full_accel_mps2: float = 6.0   # not in spec: a brisk lane change peaks near 5-8 m/s^2
@export var roll_hz: float = 2.0   # not in spec
@export var roll_damping_ratio: float = 1.0   # not in spec

@export_group("Per-mode placement (indexed like modes)")
## Camera distance behind the target origin along the (smoothed) heading; negative = ahead.
@export var mode_behind_m: PackedFloat64Array = [7.0, 11.0, -0.6, 10.0]   # not in spec: framed from snaps
## Camera height above the target origin (the car's ground point).
@export var mode_height_m: PackedFloat64Array = [3.6, 5.5, 1.15, 18.0]   # not in spec
## Look point ahead of the target origin along the heading.
@export var mode_look_ahead_m: PackedFloat64Array = [12.0, 14.0, 30.0, 12.0]   # not in spec
## Look point height above the target origin.
@export var mode_look_height_m: PackedFloat64Array = [0.0, 0.0, 0.9, 0.0]   # not in spec
## Added to the speed FOV (62 -> 78 deg).
@export var mode_fov_offset_deg: PackedFloat64Array = [0.0, 0.0, 0.0, 0.0]   # not in spec
## How much of the speed pull-back (distance_pullback_max_pct) the mode gets: 0..1.
@export var mode_pullback_factor: PackedFloat64Array = [1.0, 1.0, 0.0, 1.0]   # not in spec: a mounted camera does not pull back
## Node path under the target that places the camera, when the model has it (modular
## car convention: Markers/cam_hood, later Markers/cam_cockpit). Empty = use the offsets.
@export var mode_marker: PackedStringArray = ["", "", "Markers/cam_hood", ""]

@export_group("Per-mode springs (indexed like modes; 0 Hz = rigid)")
## Position spring natural frequency. Forward and vertical target motion is fed forward
## (no lag at constant speed or on grades); lateral motion and accelerations lag.
@export var mode_position_hz: PackedFloat64Array = [1.6, 1.3, 0.0, 1.2]   # not in spec: cool_drive-like looseness
@export var mode_position_damping_ratio: PackedFloat64Array = [0.9, 1.0, 1.0, 1.0]   # not in spec: slightly under or critical
## Heading (yaw) spring natural frequency.
@export var mode_heading_hz: PackedFloat64Array = [1.4, 1.2, 0.0, 1.0]   # not in spec
@export var mode_heading_damping_ratio: PackedFloat64Array = [1.0, 1.0, 1.0, 1.0]   # not in spec

@export_group("Shake and FOV punch")
## Shake translation per unit strength (Events.camera_shake_requested strength 1 = a hit).
@export var shake_offset_m: float = 0.12   # not in spec
## Shake rotation per unit strength.
@export var shake_rotation_deg: float = 0.9   # not in spec
## Base frequency of the shake noise.
@export var shake_frequency_hz: float = 14.0   # not in spec
## Fraction of a FOV punch spent widening; the rest eases back.
@export var fov_punch_attack_frac: float = 0.25   # not in spec
## Camera near plane (the far plane comes from Quality).
@export var near_plane_m: float = 0.15   # not in spec: hood view clears the bonnet

@export_group("Scripted cameras")
@export var finale_swing_s: float = 3.0   # journey finale wide swing onto the ocean


## Index of `mode` in `modes`, or -1.
func mode_index(mode: StringName) -> int:
	return modes.find(String(mode))


## Empty when every per-mode array has one entry per mode, else a description.
func mode_arrays_error() -> String:
	var n := modes.size()
	var sizes := {
		"mode_behind_m": mode_behind_m.size(),
		"mode_height_m": mode_height_m.size(),
		"mode_look_ahead_m": mode_look_ahead_m.size(),
		"mode_look_height_m": mode_look_height_m.size(),
		"mode_fov_offset_deg": mode_fov_offset_deg.size(),
		"mode_pullback_factor": mode_pullback_factor.size(),
		"mode_marker": mode_marker.size(),
		"mode_position_hz": mode_position_hz.size(),
		"mode_position_damping_ratio": mode_position_damping_ratio.size(),
		"mode_heading_hz": mode_heading_hz.size(),
		"mode_heading_damping_ratio": mode_heading_damping_ratio.size(),
	}
	for key: String in sizes:
		if int(sizes[key]) != n:
			return "%s has %d entries for %d modes" % [key, sizes[key], n]
	if mode_index(StringName(default_mode)) < 0:
		return "default_mode %s is not a mode" % default_mode
	return ""


## Speed-response progress: 0 at or below fov_min_speed_kmh, 1 at `top_speed_mps` and above.
func speed_frac(v_mps: float, top_speed_mps: float) -> float:
	var v0 := Units.kmh_to_mps(fov_min_speed_kmh)
	if top_speed_mps <= v0:
		return 1.0 if v_mps > v0 else 0.0
	return clampf((v_mps - v0) / (top_speed_mps - v0), 0.0, 1.0)


## Speed field of view (deg): 62 at 100 km/h -> 78 at top speed, clamped both ends.
func fov_deg(v_mps: float, top_speed_mps: float) -> float:
	return lerpf(fov_min_deg, fov_max_deg, speed_frac(v_mps, top_speed_mps))


## Scale on the mode's camera offsets: 1 up to 100 km/h, 1 + 15% x pullback factor at top speed.
func pullback_scale(v_mps: float, top_speed_mps: float, mode_i: int) -> float:
	var full := Units.pct_to_frac(distance_pullback_max_pct) * mode_pullback_factor[mode_i]
	return 1.0 + full * speed_frac(v_mps, top_speed_mps)


## Look-target lateral shift (m, + right) for a road-relative lateral speed (m/s, + right).
func look_ahead_lateral_m(lat_speed_mps: float) -> float:
	return clampf(lat_speed_mps / look_ahead_full_lat_mps, -1.0, 1.0) * look_ahead_max_m


## Camera roll (rad, + = right side down, banking into a right turn) for accel_lat (+ right).
func roll_rad(accel_lat_mps2: float) -> float:
	return clampf(accel_lat_mps2 / roll_full_accel_mps2, -1.0, 1.0) * deg_to_rad(roll_max_deg)
