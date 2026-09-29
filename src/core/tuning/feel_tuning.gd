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

@export_group("Damage look")
## PlayerFx (visual only). Ghost flicker: the body toggles visible/hidden at this rate
## ("flickers translucent" during the ghost period).
@export var ghost_flicker_hz: float = 12.0   # not in spec
## Hood smoke after the first hit: particles at medium quality (x Quality.particle_scale),
## lifetime, initial speed range, direction in car space (+Z is the car's rear: up and
## back), spread, rise, puff size and its scale at birth and at death.
@export var smoke_particles: int = 10   # not in spec
@export var smoke_lifetime_s: float = 0.9   # not in spec
@export var smoke_speed_min_mps: float = 1.5   # not in spec
@export var smoke_speed_max_mps: float = 3.5   # not in spec
@export var smoke_direction: Vector3 = Vector3(0.0, 0.8, 1.0)   # not in spec
@export var smoke_spread_deg: float = 18.0   # not in spec
@export var smoke_rise_mps2: float = 1.2   # not in spec
@export var smoke_size_m: float = 0.55   # not in spec
@export var smoke_scale_birth: float = 0.6   # not in spec
@export var smoke_scale_death: float = 1.8   # not in spec
## Camera modes that never show the hood smoke: from the hood and the cockpit it covers
## the road (owner, M4/M5 playtest). The damage still shows in the other cameras.
@export var smoke_hidden_camera_modes: Array[StringName] = [&"hood", &"cockpit"]   # not in spec
## The flickering headlight: flicker steps per second and the share of steps that are lit.
@export var lamp_flicker_hz: float = 14.0   # not in spec
@export var lamp_lit_share: float = 0.35   # not in spec
## Quad size when the lamp has no mesh (width, height; the height is also the minimum
## side), and its offset in front of the lamp face.
@export var lamp_fallback_size_m: Vector2 = Vector2(0.34, 0.16)   # not in spec
@export var lamp_offset_m: float = 0.02   # not in spec
