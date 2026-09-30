class_name CameraTuning
extends Resource
## Camera modes and shared behaviors. Spec: Cameras; Game feel (shake, FOV punch);
## Accessibility -> Reduced motion. Saved as data/tuning/camera.tres. Used by CameraRig
## (src/camera/camera_rig.gd).
##
## Per-mode values are parallel arrays indexed like `modes` (the QualityTuning tier
## pattern): adding a mode means appending one entry to `modes` and to every `mode_*`
## array. `mode_arrays_error()` checks the sizes.
##
## The cockpit mode (plan D11, WP4.7; docs/COCKPIT.md) is the mode named `cockpit_mode`:
## a rigid driver's-eye seat frame with the procedural cockpit around it, the car body
## hidden, and the look-ahead, head sway, shake and punch applied to the head (the
## Camera3D) so the dash moves in the view. Its numbers are the `cockpit_*` fields.

@export var modes: PackedStringArray = ["chase", "far", "hood", "overhead", "cockpit"]
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
## Unused by the cockpit (its eye comes from the marker or the cockpit_eye_* fractions).
@export var mode_behind_m: PackedFloat64Array = [7.0, 11.0, -0.6, 10.0, 0.0]   # not in spec: framed from snaps
## Camera height above the target origin (the car's ground point). Unused by the cockpit.
@export var mode_height_m: PackedFloat64Array = [3.6, 5.5, 1.15, 18.0, 0.0]   # not in spec
## Look point ahead of the target origin along the heading (cockpit: in the car's frame).
@export var mode_look_ahead_m: PackedFloat64Array = [12.0, 14.0, 30.0, 12.0, 40.0]   # not in spec
## Look point height above the target origin (cockpit: in the car's frame).
@export var mode_look_height_m: PackedFloat64Array = [0.0, 0.0, 0.9, 0.0, 0.3]   # not in spec
## Added to the speed FOV (62 -> 78 deg).
@export var mode_fov_offset_deg: PackedFloat64Array = [0.0, 0.0, 0.0, 0.0, 0.0]   # not in spec
## How much of the speed pull-back (distance_pullback_max_pct) the mode gets: 0..1.
@export var mode_pullback_factor: PackedFloat64Array = [1.0, 1.0, 0.0, 1.0, 0.0]   # not in spec: a mounted camera does not pull back
## Node path under the target that places the camera, when the model has it (modular
## car convention: Markers/cam_hood, Markers/cam_cockpit). Empty = use the offsets. The
## cockpit also looks in the target's CarModel and ignores a marker conform() stubbed.
@export var mode_marker: PackedStringArray = ["", "", "Markers/cam_hood", "", "Markers/cam_cockpit"]
## Scale on the roll (roll_max_deg into the lateral acceleration). Negative = the view
## leans out of the turn with the car body (cockpit: the seat is bolted to the body).
@export var mode_roll_factor: PackedFloat64Array = [1.0, 1.0, 1.0, 1.0, -1.0]   # not in spec
## Scale on the shake (offset and rotation) and on the FOV punch.
@export var mode_shake_scale: PackedFloat64Array = [1.0, 1.0, 1.0, 1.0, 0.6]   # not in spec: subtler from the seat
@export var mode_punch_scale: PackedFloat64Array = [1.0, 1.0, 1.0, 1.0, 0.7]   # not in spec

@export_group("Per-mode springs (indexed like modes; 0 Hz = rigid)")
## Position spring natural frequency. Forward and vertical target motion is fed forward
## (no lag at constant speed or on grades); lateral motion and accelerations lag.
@export var mode_position_hz: PackedFloat64Array = [1.6, 1.3, 0.0, 1.2, 0.0]   # not in spec: cool_drive-like looseness
@export var mode_position_damping_ratio: PackedFloat64Array = [0.9, 1.0, 1.0, 1.0, 1.0]   # not in spec: slightly under or critical
## Heading (yaw) spring natural frequency.
@export var mode_heading_hz: PackedFloat64Array = [1.4, 1.2, 0.0, 1.0, 0.0]   # not in spec
@export var mode_heading_damping_ratio: PackedFloat64Array = [1.0, 1.0, 1.0, 1.0, 1.0]   # not in spec

@export_group("Cockpit (plan D11)")
## The mode that gets the driver's-eye seat frame, the procedural cockpit and the hidden
## car body. Must be one of `modes`.
@export var cockpit_mode: String = "cockpit"
## Default eye position when the model has no authored Markers/cam_cockpit, as fractions
## of the CarDef body: + right of the centreline (left seat for right-hand traffic),
## above the ground, + behind the axle centre.
@export var cockpit_eye_right_frac: float = -0.19   # not in spec: ~0.36 m left on a 1.9 m car
@export var cockpit_eye_up_frac: float = 0.86   # not in spec: ~1.08 m on a 1.25 m sports car
@export var cockpit_eye_back_frac: float = 0.04   # not in spec
## Head sway (on the Camera3D, so the dash moves in the view): the head lags the car's
## accelerations (turning right pushes it left, braking pushes it forward), per m/s^2,
## bounded by cockpit_head_sway_max_m, through a spring. Off with reduced motion.
@export var cockpit_head_sway_lat_m_per_mps2: float = 0.006   # not in spec
@export var cockpit_head_sway_long_m_per_mps2: float = 0.004   # not in spec
@export var cockpit_head_sway_max_m: float = 0.04   # not in spec
@export var cockpit_head_sway_hz: float = 1.8   # not in spec
@export var cockpit_head_sway_damping_ratio: float = 0.75   # not in spec: a slight bob
## Binnacle gauges: speedometer and tachometer full scale (the needles' end stops).
## The tachometer's red band starts at VehicleTuning.engine_redline_rpm.
@export var cockpit_speedo_max_kmh: float = 320.0   # not in spec
@export var cockpit_tach_max_rpm: float = 8000.0   # not in spec

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
## The finale swing (WP6.5, docs/FORKS.md → Coast finale): the camera leaves the chase
## pose, swings out to the land side of the car (it turns this far around the car from
## straight behind), at this distance and height, looking back at the car against the
## sea and the low sun, holds, and comes back. The blend in and out each take
## finale_swing_ease_frac of the swing.
@export var finale_swing_angle_deg: float = 62.0   # not in spec
@export var finale_swing_distance_m: float = 17.0   # not in spec
@export var finale_swing_height_m: float = 4.0   # not in spec
@export var finale_swing_look_height_m: float = 1.0   # not in spec
## The look point leads the car along the road (the sea and the sun ahead of it).
@export var finale_swing_look_ahead_m: float = 6.0   # not in spec
@export var finale_swing_ease_frac: float = 0.3   # not in spec

@export_group("Menu attract")
## The title's attract drive (WP8.5, spec Cameras → Scripted cameras → Menu: "a slow
## drive-by of the selected car on the road"; docs/RUN.md → Title and attract). The car
## drives itself (a lane-keeping bot) at attract_speed_kmh in attract_lane with hit
## detection off, and the camera cuts between two shots, alternating the side with the
## most room: ORBIT, a slow arc around the car (from attract_orbit_from_deg off its nose
## to attract_orbit_to_deg, over attract_orbit_s), and PASS, a camera standing on the
## shoulder attract_pass_lead_m ahead that the car drives past (the shot ends
## attract_pass_past_m after it, or after attract_shot_max_s). Both look at the car at
## attract_look_height_m, with a long lens (attract_fov_deg), turned attract_frame_yaw_deg
## so the car sits right of centre, clear of the title's left-anchored menu.
@export var attract_speed_kmh: float = 96.0   # not in spec: "a slow drive-by"
## The title's sky (held; SunTuning's sky_t scale): golden hour, the sun ahead to chase.
@export var attract_sky_t: float = 0.42   # not in spec
@export var attract_lane: int = 1   # not in spec
@export var attract_fov_deg: float = 32.0   # not in spec
@export var attract_frame_yaw_deg: float = 13.0   # not in spec
@export var attract_look_height_m: float = 0.7   # not in spec
@export var attract_orbit_s: float = 9.0   # not in spec
@export var attract_orbit_from_deg: float = 22.0   # not in spec
@export var attract_orbit_to_deg: float = 64.0   # not in spec
@export var attract_orbit_distance_m: float = 18.0   # not in spec
@export var attract_orbit_height_m: float = 1.4   # not in spec
@export var attract_pass_lead_m: float = 62.0   # not in spec
@export var attract_pass_past_m: float = 22.0   # not in spec
@export var attract_pass_height_m: float = 1.1   # not in spec
@export var attract_shot_max_s: float = 9.0   # not in spec
## The camera stays this far inside the carriageway's barriers.
@export var attract_edge_margin_m: float = 0.8   # not in spec
## The car changes lanes now and then (the sandbox bot's WEAVE) instead of holding one.
@export var attract_weave: bool = true   # not in spec
## A shot that traffic blocks (a vehicle's box, grown by attract_clear_margin_m, across
## the line from the camera to the car) cuts to the next once it has run this long; a new
## shot takes the side with a clear line when there is one.
@export var attract_min_shot_s: float = 1.5   # not in spec
@export var attract_clear_margin_m: float = 0.4   # not in spec


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
		"mode_roll_factor": mode_roll_factor.size(),
		"mode_shake_scale": mode_shake_scale.size(),
		"mode_punch_scale": mode_punch_scale.size(),
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
	if not cockpit_mode.is_empty() and mode_index(StringName(cockpit_mode)) < 0:
		return "cockpit_mode %s is not a mode" % cockpit_mode
	return ""


## Index of the cockpit mode in `modes`, or -1 when there is none.
func cockpit_index() -> int:
	return mode_index(StringName(cockpit_mode)) if not cockpit_mode.is_empty() else -1


## Default driver's eye in the car's frame (m; origin on the ground between the axles,
## -Z forward) for a body of `length_m` x `width_m` x `height_m`.
func cockpit_eye_default(length_m: float, width_m: float, height_m: float) -> Vector3:
	return Vector3(width_m * cockpit_eye_right_frac, height_m * cockpit_eye_up_frac,
		length_m * cockpit_eye_back_frac)


## Head sway goal (m, in the seat frame: + right, + back) for the car's accelerations
## (m/s^2, + right / + forward). Each axis is bounded by cockpit_head_sway_max_m.
func cockpit_head_sway_m(accel_lat_mps2: float, accel_long_mps2: float) -> Vector3:
	var m := cockpit_head_sway_max_m
	return Vector3(clampf(-accel_lat_mps2 * cockpit_head_sway_lat_m_per_mps2, -m, m), 0.0,
		clampf(accel_long_mps2 * cockpit_head_sway_long_m_per_mps2, -m, m))


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
