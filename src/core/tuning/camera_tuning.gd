class_name CameraTuning
extends Resource
## Camera modes and shared behaviors. Spec: Cameras. Saved as data/tuning/camera.tres.
## Per-mode offsets and spring constants are added by WP2.3.

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

@export_group("Scripted cameras")
@export var finale_swing_s: float = 3.0   # journey finale wide swing onto the ocean
