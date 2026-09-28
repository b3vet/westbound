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
## Test target: drivable and above minimum speed within this time.
@export var first_hit_recovery_max_s: float = 1.0

@export_group("Collision")
## Collision boxes are inset from the visual body on each side.
@export var collision_inset_m: float = 0.08
## Test target: no tunnelling between 120 Hz ticks up to this speed.
@export var collision_test_max_speed_kmh: float = 350.0


func first_hit_speed_keep_frac() -> float:
	return 1.0 - Units.pct_to_frac(first_hit_speed_loss_pct)
