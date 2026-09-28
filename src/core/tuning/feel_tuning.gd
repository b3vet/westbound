class_name FeelTuning
extends Resource
## Slow motion, haptics, shake and speed effects. Spec: Audio, haptics and game feel;
## Lives (first hit, crash); Cameras (shake, FOV punch). Saved as data/tuning/feel.tres.
## Reduced motion disables slow motion, shake, camera roll and the FOV punch.

@export_group("Slow motion (time scale, duration)")
@export var slowmo_thread_scale: float = 0.6
@export var slowmo_thread_s: float = 0.25
@export var slowmo_first_hit_scale: float = 0.5
@export var slowmo_first_hit_s: float = 0.3
@export var slowmo_crash_scale: float = 0.25
@export var slowmo_crash_s: float = 2.5

@export_group("Haptics")
@export var haptic_hit_ms: float = 150.0
@export var haptic_crash_ms: float = 400.0

@export_group("Speed effects")
@export var speed_lines_min_kmh: float = 180.0
@export var boost_fov_punch_deg: float = 6.0   # not in spec: "a field-of-view punch on boost"
@export var boost_fov_punch_s: float = 0.35   # not in spec

@export_group("Camera shake")
@export var hit_shake_strength: float = 1.0   # not in spec: normalized strength for Events.camera_shake_requested
@export var hit_shake_s: float = 0.4   # not in spec
@export var close_pass_shake_strength: float = 0.15   # not in spec: "a tiny shake on close passes"
@export var close_pass_shake_s: float = 0.15   # not in spec
