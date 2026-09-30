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
## WP7.4 (src/platform/haptics.gd). The spec names the patterns (light tick, medium
## tick, heavy thump, double light tick, strong burst, long rumble) and the hit and
## crash durations; the tick lengths and every amplitude (0..1, native only: the web's
## navigator.vibrate has no amplitude) are ours.
@export var haptic_hit_amp: float = 1.0   # not in spec
@export var haptic_crash_amp: float = 0.8   # not in spec
@export var haptic_pass_ms: float = 12.0   # not in spec: "light tick"
@export var haptic_pass_amp: float = 0.3   # not in spec
@export var haptic_close_ms: float = 20.0   # not in spec: "medium tick"
@export var haptic_close_amp: float = 0.6   # not in spec
@export var haptic_thread_ms: float = 45.0   # not in spec: "heavy thump"
@export var haptic_thread_amp: float = 1.0   # not in spec
## Banking: "double light tick" = two pulses this far apart (start to start).
@export var haptic_bank_ms: float = 12.0   # not in spec
@export var haptic_bank_amp: float = 0.35   # not in spec
@export var haptic_bank_gap_ms: float = 90.0   # not in spec
## Shortest pulse sent to a device (many Android vibrators skip shorter ones).
@export var haptic_min_ms: float = 10.0   # not in spec

@export_group("Speed effects")
@export var speed_lines_min_kmh: float = 180.0
## WP7.4 speed lines and wind streaks (src/fx/speed_lines.gd): one camera-space mesh of
## streak quads (1 draw call, hidden at or below speed_lines_min_kmh). Intensity ramps
## from speed_lines_min_intensity just above the minimum to 1 at speed_lines_full_kmh;
## boosting adds speed_lines_boost_gain.
@export var speed_lines_full_kmh: float = 260.0   # not in spec
## Intensity just above the threshold (the ramp runs from here to 1).
@export var speed_lines_min_intensity: float = 0.3   # not in spec
@export var speed_lines_boost_gain: float = 0.35   # not in spec
## Streak count at 100 % particles (x Quality.particle_scale); every
## speed_lines_wind_every-th streak is a wind streak (shorter, fainter, slower).
@export var speed_lines_count: int = 28   # not in spec
@export var speed_lines_wind_every: int = 3   # not in spec
## Screen radius (0 centre, 1 edge, per axis) where streaks start in the outside cameras
## and in the edge-only cameras (hood, cockpit: D16, never over the road ahead), and
## where they leave the screen.
@export var speed_lines_inner: float = 0.55   # not in spec
@export var speed_lines_inner_edge: float = 0.8   # not in spec
@export var speed_lines_outer: float = 1.45   # not in spec
@export var speed_lines_edge_camera_modes: Array[StringName] = [&"hood", &"cockpit"]   # not in spec
## Streak length (screen radius units) and width (pixels at 720 p, scaled with the
## viewport height), streak passes per second at the minimum and full speed.
@export var speed_lines_length: float = 0.35   # not in spec
@export var speed_lines_width_px: float = 3.0   # not in spec
@export var speed_lines_rate_min_hz: float = 1.2   # not in spec
@export var speed_lines_rate_max_hz: float = 2.6   # not in spec
## Streak color (sRGB), peak additive strength, and its night factor.
@export var speed_lines_color: Color = Color(0.92, 0.95, 1.0)   # not in spec
@export var speed_lines_strength: float = 0.35   # not in spec
@export var speed_lines_night_gain: float = 0.45   # not in spec
## View depth the streaks sit at (m): the cockpit's dash and pillars, closer than this,
## hide them (D16); the car in the outside cameras is farther.
@export var speed_lines_depth_m: float = 2.5   # not in spec
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
## Reduced motion (WP9.3): the ghost flicker slows to this rate, under the 3 flashes per
## second of WCAG 2.3.1 (the HUD's GHOST says it too).
@export var ghost_flicker_reduced_motion_hz: float = 2.0   # not in spec
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
## Reduced motion (WP9.3): the lamp's flicker steps per second (under 3 flashes a second).
@export var lamp_flicker_reduced_motion_hz: float = 2.0   # not in spec
@export var lamp_lit_share: float = 0.35   # not in spec
## Quad size when the lamp has no mesh (width, height; the height is also the minimum
## side), and its offset in front of the lamp face.
@export var lamp_fallback_size_m: Vector2 = Vector2(0.34, 0.16)   # not in spec
@export var lamp_offset_m: float = 0.02   # not in spec

@export_group("Particles")
## WP7.4 tire smoke and barrier sparks (src/fx/fx_particles.gd): one pooled MultiMesh
## (1 draw call, hidden when no particle is alive). Pool size at 100 % particles; the
## live cap is pool x Quality.particle_scale.
@export var particles_pool: int = 96   # not in spec
## Tire smoke while braking hard (CarVisual.tire_smoke): puffs per second per rear
## wheel, lifetime, the share of the car's velocity a puff keeps, rise, drag, random
## speed, puff size at birth and death (m), peak opacity, color (sRGB).
@export var tire_smoke_rate_hz: float = 22.0   # not in spec
@export var tire_smoke_lifetime_s: float = 1.1   # not in spec
@export var tire_smoke_carry: float = 0.6   # not in spec
@export var tire_smoke_rise_mps2: float = 0.8   # not in spec
@export var tire_smoke_drag_per_s: float = 2.5   # not in spec
@export var tire_smoke_spread_mps: float = 1.2   # not in spec
@export var tire_smoke_size_birth_m: float = 0.6   # not in spec
@export var tire_smoke_size_death_m: float = 2.8   # not in spec
@export var tire_smoke_alpha: float = 0.6   # not in spec
@export var tire_smoke_color: Color = Color(0.78, 0.78, 0.8)   # not in spec
## Sparks on a barrier scrape: sparks per burst, lifetime range, the share of the car's
## velocity they keep, random speed range, gravity, drag, streak length (s of travel),
## width (m), height of the contact above the road (m), hot and cool colors (sRGB).
@export var sparks_count: int = 48   # not in spec
@export var sparks_lifetime_min_s: float = 0.25   # not in spec
@export var sparks_lifetime_max_s: float = 0.55   # not in spec
@export var sparks_carry: float = 0.75   # not in spec
@export var sparks_speed_min_mps: float = 3.0   # not in spec
@export var sparks_speed_max_mps: float = 14.0   # not in spec
@export var sparks_gravity_mps2: float = 9.8   # not in spec: about g
@export var sparks_drag_per_s: float = 1.5   # not in spec
@export var sparks_streak_s: float = 0.06   # not in spec
@export var sparks_width_m: float = 0.07   # not in spec
@export var sparks_height_m: float = 0.45   # not in spec
@export var sparks_hot_color: Color = Color(1.0, 0.93, 0.62)   # not in spec
@export var sparks_cool_color: Color = Color(1.0, 0.45, 0.12)   # not in spec
