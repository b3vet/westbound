class_name LivesTuning
extends Resource
## Lives, hits, ghost period and collision boxes. Spec: Lives, hits and crashes.
## Saved as data/tuning/lives.tres. Slow motion for hits/crash is in FeelTuning.

@export var lives: int = 2   # start and maximum
@export var ghost_period_s: float = 2.0
@export var clean_leg_restore: bool = true

@export_group("First hit")
@export var first_hit_speed_loss_pct: float = 20.0
@export var first_hit_wobble_s: float = 0.6
@export var first_hit_deflect_mps: float = 2.0   # not in spec: lateral deflection speed away from the contact
## The deflection is a heading kick of atan(deflect / speed), capped at this (low speeds).
@export var first_hit_deflect_max_deg: float = 10.0   # not in spec: keeps a slow car from turning sideways
## Wobble: a decaying yaw oscillation over first_hit_wobble_s (net zero heading change).
@export var first_hit_wobble_amplitude_deg: float = 2.0   # not in spec: wobble strength
@export var first_hit_wobble_hz: float = 3.0   # not in spec: wobble frequency
## Test target: drivable and above minimum speed within this time.
@export var first_hit_recovery_max_s: float = 1.0

@export_group("Collision")
## Collision boxes are inset from the visual body on each side.
@export var collision_inset_m: float = 0.08
## Broad phase: traffic whose center is farther than this along s is not swept (and
## not tracked) this tick. Must exceed the largest box reach (semi: ~12 m) plus the
## largest relative move in one tick (2 x 350 km/h at 120 Hz: 1.6 m).
@export var collision_broadphase_m: float = 40.0   # not in spec: performance window
## Test target: no tunnelling between 120 Hz ticks up to this speed.
@export var collision_test_max_speed_kmh: float = 350.0


func first_hit_deflect_max_rad() -> float:
	return deg_to_rad(first_hit_deflect_max_deg)


func first_hit_wobble_amplitude_rad() -> float:
	return deg_to_rad(first_hit_wobble_amplitude_deg)


func first_hit_speed_keep_frac() -> float:
	return 1.0 - Units.pct_to_frac(first_hit_speed_loss_pct)
