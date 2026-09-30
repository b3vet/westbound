class_name CrashTuning
extends Resource
# lint: not-sim tuning resource for the crash cinematic (Node-side, no simulation)
## Crash cinematic numbers (WP4.2). Spec: Lives, hits and crashes → Second hit (run
## over): Jolt RigidBody3D hand-off with an impulse from the relative velocity at the
## contact point, orbit crash camera; Cameras → Scripted cameras (Crash). Saved as
## data/tuning/crash.tres. The spec's slow motion (0.25× for 2.5 s) lives in
## FeelTuning (slowmo_crash_scale, slowmo_crash_s); the cinematic lasts that long.
## Visual only: nothing here feeds back into scoring or the run's simulation.
##
## Until the orchestrator adds `Tuning.crash`, load it with CrashTuning.load_default().

const PATH := "res://data/tuning/crash.tres"

@export_group("Timing")
## Real (unscaled) seconds after the slow motion ends before `finished` fires and the
## results screen fades in.
@export var cinematic_tail_s: float = 0.4   # not in spec: a beat after the slow motion
## Taps in the first moments of the crash don't skip it (a finger already on the
## pedals or the steering area when the crash begins).
@export var skip_grace_s: float = 0.3   # not in spec: guards against accidental skips

@export_group("Impulse (from the relative velocity at the contact point)")
## Normal impulse = (1 + restitution) × reduced mass × approach speed along the normal.
@export var restitution_frac: float = 0.35   # not in spec: a crumpling, slightly bouncy hit
## The approach speed along the normal is at least this, so glancing hits still kick.
@export var min_approach_kmh: float = 18.0   # not in spec
## Share of the tangential relative velocity the contact removes (scraping friction).
@export var tangential_frac: float = 0.25   # not in spec
## Upward kick on each body: this share of its change of speed along the normal,
## capped at lift_max_kmh (a hop, not a launch).
@export var lift_frac: float = 0.3   # not in spec
@export var lift_max_kmh: float = 12.0   # not in spec: ~0.6 m hop
## The impulse acts at this share of the player body's height above the road. Below
## the centre of mass (0.5) it tips the car toward the contact (over a guardrail);
## at 0.5 the roll comes from the tumble below, away from the contact.
@export var contact_height_frac: float = 0.5   # not in spec
## Deterministic extra tumble, added to both bodies: roll toward the side away from the
## contact, and a yaw spin in the sense the contact pushes the car.
@export var tumble_roll_deg_per_s: float = 160.0   # not in spec
@export var tumble_yaw_deg_per_s: float = 70.0   # not in spec
## The extra tumble scales with the approach speed up to this speed.
@export var tumble_full_kmh: float = 60.0   # not in spec
## The spin a body gets from the hit (impulse lever arm plus tumble) is capped at this:
## a fast-spinning box that meets the ground bounces meters high.
@export var spin_max_deg_per_s: float = 200.0   # not in spec

@export_group("Bodies")
@export var body_friction_frac: float = 0.7   # not in spec: rubber and steel on asphalt
@export var body_bounce_frac: float = 0.15   # not in spec
@export var body_linear_damp_factor: float = 0.05   # not in spec
@export var body_angular_damp_factor: float = 0.35   # not in spec: the tumble settles within seconds

@export_group("Crash arena (invisible collision near the crash)")
## Ground slabs and barrier walls built from road samples along the road around the
## contact point, one set per segment.
@export var arena_segment_m: float = 20.0   # not in spec: chord error < 5 cm at R 1,200 m
## Covers the tumble at 1× time too (in case nobody honours the slow motion).
@export var arena_ahead_m: float = 320.0   # not in spec: 2.9 s at 400 km/h
@export var arena_behind_m: float = 40.0   # not in spec
## Ground reaches this far past each guardrail (cars that clear the rail land on it).
@export var arena_ground_margin_m: float = 40.0   # not in spec
@export var arena_ground_thickness_m: float = 2.0   # not in spec: no tunnelling at 120 Hz
## Barrier walls extend this far away from the road behind their face.
@export var arena_wall_thickness_m: float = 1.0   # not in spec: no tunnelling at 120 Hz

@export_group("Orbit camera")
## Real (unscaled) time drives the orbit, so it keeps moving while the world is slowed.
@export var orbit_speed_deg_per_s: float = 38.0   # not in spec
## Reduced motion: the orbit turns this much slower.
@export var orbit_reduced_motion_frac: float = 0.35   # not in spec: "gentler orbit"
@export var orbit_radius_m: float = 9.0   # not in spec
## The radius grows by this share of the distance between the two bodies.
@export var orbit_radius_per_separation_frac: float = 0.6   # not in spec
@export var orbit_radius_max_m: float = 30.0   # not in spec
@export var orbit_height_m: float = 3.2   # not in spec
## The camera looks this far above the midpoint of the bodies.
@export var look_height_m: float = 0.4   # not in spec
## The look target follows the midpoint with this time constant (real time).
@export var look_follow_s: float = 0.08   # not in spec
## The orbit starts this far round from the gameplay camera's direction.
@export var orbit_start_offset_deg: float = 25.0   # not in spec
@export var fov_deg: float = 60.0   # not in spec


func min_approach_mps() -> float:
	return Units.kmh_to_mps(min_approach_kmh)


func lift_max_mps() -> float:
	return Units.kmh_to_mps(lift_max_kmh)


func tumble_full_mps() -> float:
	return Units.kmh_to_mps(tumble_full_kmh)


static func load_default() -> CrashTuning:
	return load(PATH) as CrashTuning
