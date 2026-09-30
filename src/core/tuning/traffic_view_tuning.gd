class_name TrafficViewTuning
extends Resource
# lint: not-sim render-side tuning resource for the traffic view (no simulation)
## Traffic rendering numbers (WP3.1). Spec: Traffic → Visuals (lights, motion,
## rendering), Cameras → Glare rule, World → Night lighting. Saved as
## data/tuning/traffic_view.tres, reachable as `Tuning.traffic_view`. Visual only:
## nothing here feeds back into the simulation.
##
## Lamp brightness and glow looks live in the materials (assets/shaders/materials/
## traffic.tres, glow.tres); the numbers here drive the CPU side of the view.

const PATH := "res://data/tuning/traffic_view.tres"

@export_group("Blinkers")
## Blinker flash rate (cycles per second). Regulations allow 1-2 Hz (60-120 per minute).
@export var blinker_hz: float = 1.5   # not in spec: typical 90 flashes per minute
## Share of each cycle the lamp is lit. The first flash starts the moment the flag rises.
@export var blinker_duty_pct: float = 55.0   # not in spec

@export_group("Heading")
## Lane-change yaw is atan2(v_lat, v); below this speed the denominator is floored so a
## (near) stopped car moving sideways in a jam never turns broadside.
@export var yaw_min_speed_kmh: float = 20.0   # not in spec
## Visual yaw is clamped to this (the sim's smoothstep peaks near 4-8 deg at speed).
@export var yaw_max_deg: float = 20.0   # not in spec

@export_group("Body motion (visual only)")
## Body roll (lean out of a lane change) at body_roll_full_accel_mps2 of lateral acceleration.
@export var body_roll_max_deg: float = 2.5   # not in spec: "bodies roll slightly"
@export var body_roll_full_accel_mps2: float = 4.0   # not in spec: a brisk lane change peaks near 2 m/s^2
## Body pitch (nose dive when braking, squat when accelerating).
@export var body_pitch_max_deg: float = 1.5   # not in spec: "and pitch slightly"
@export var body_pitch_full_accel_mps2: float = 6.0   # not in spec: the sim's decel clamp
## First-order smoothing of roll and pitch (the sim's accel changes in steps).
@export var body_motion_time_constant_s: float = 0.25   # not in spec

@export_group("Interpolation and culling")
## A slot whose s jumps more than this between two ticks (a recycle, a reposition) is
## drawn at its new position without interpolating across the jump.
@export var teleport_distance_m: float = 20.0   # not in spec
## Vehicles further than this from the camera are not drawn (fully fogged). <= 0 = the
## quality tier's view distance.
@export var cull_distance_m: float = 0.0
## Vehicles whose center is this far behind the camera plane are not drawn.
@export var cull_behind_m: float = 20.0   # not in spec: longer than the longest vehicle
## With update_view(focus_s): vehicles this far behind the player's s are skipped before
## any math (behind the far chase camera plus the longest vehicle).
@export var cull_behind_focus_m: float = 40.0   # not in spec
## Blob shadows only within this distance of the camera (a few pixels beyond).
@export var shadow_distance_m: float = 250.0   # not in spec
## G8 (docs/ART_PRODUCTION.md §3.5): models that bring a LOD1 mesh (mesh meta
## `lod1_path`, written by tools/art/convert.gd) are drawn with it beyond this distance
## from the camera: a car is ~14 px wide there on the owner's phone (§2.3: ~450/D px per
## metre). Each such model costs one more draw call while it has both near and far
## instances. <= 0 = never (LOD0 at every distance). The procedural models have no LOD1.
@export var lod1_distance_m: float = 60.0   # not in spec

@export_group("Glow sprites")
## Rear lamps glow at night only when the vehicle has its headlights on (FLAG_HEADLIGHTS).
## By day only brake lights, blinkers and hazards get glow sprites.
@export var glow_day_tail: bool = false
## Headlight pool on the road ahead of a lit front pair (glow MultiMesh, night only):
## from pool_start_m to pool_length_m ahead of the lamps, widening across.
@export var pool_start_m: float = 0.5   # not in spec
@export var pool_length_m: float = 16.0   # not in spec
@export var pool_near_width_m: float = 1.8   # not in spec
@export var pool_far_width_m: float = 5.5   # not in spec


func blinker_duty_frac() -> float:
	return Units.pct_to_frac(blinker_duty_pct)


func yaw_min_speed_mps() -> float:
	return Units.kmh_to_mps(yaw_min_speed_kmh)


static func load_default() -> TrafficViewTuning:
	return load(PATH) as TrafficViewTuning
