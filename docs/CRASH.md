# Crash sequence (as implemented)

WP4.2. Spec: "Lives, hits and crashes → Second hit (run over)", "Cameras → Scripted cameras (Crash)", "Audio, haptics and game feel" (crash slow motion). Contract: [CONTRACTS.md §14](CONTRACTS.md#14-run-hud-and-screens-phase-4).

| File | What |
| --- | --- |
| `src/run/crash_sequence.gd` | `CrashSequence` (Node3D): the pool, the hand-off, the orbit camera, the clock |
| `src/core/tuning/crash_tuning.gd`, `data/tuning/crash.tres` | `CrashTuning` (impulse, bodies, arena, camera, timing) |
| `src/run/crash/dev/crash_preview.tscn` | Review scene (loops; `snap_setup --t=`) |
| `src/traffic/traffic_view.gd` | `set_slot_hidden(slot, hidden, opposite = false)` |

## How the run uses it

```gdscript
# Load time (once per run scene; setup() again on a new run is cheap and builds nothing):
crash = CrashSequence.new()
add_child(crash)                        # at the world root (identity transform)
crash.setup(ctx, registry)
crash.finished.connect(_on_crash_finished)   # show results (skipped: bool)

# Tick step 4, when lives.on_contact(...) returns Lives.Outcome.RUN_OVER:
if contact.slot >= 0:
	traffic_sim.notify_hit(contact.slot)
crash.start(player_car, contact, traffic_sim.state, traffic_view, road, origin, camera_rig)
Game.change_state(Game.CRASH)
# From here: stop ticking the player (start() turns its physics process off; a run
# with self_tick = false must stop calling PlayerCar.tick()), stop hit detection and
# scoring. Traffic may keep ticking (it should brake: see "Needs").

# Retry (before place_at and rig.snap_to_target):
crash.reset()
```

- **Skip:** a tap, click or key press after `skip_grace_s` (0.3 s) calls `skip()`. Turn `tap_to_skip` off to route input through the run or the results screen, and call `skip()` yourself.
- **Events:** `Events.crash_started` and `Events.slowmo_requested(0.25, 2.5, &"crash")` in `start()`; `finished(skipped)` and `Events.crash_finished` once, at the end or on `skip()`. `reset()` emits nothing.

## Hand-off

- **Player body:** a box of the car's `CarDef` length × width (inset by `lives.collision_inset_m`, like hit detection) × height, `CarDef.mass_kg`, centred half the height above the PlayerCar's road-level origin, with `PlayerCar.world_velocity()` and the car's world yaw rate. The PlayerCar node follows the body every physics tick (`global_transform = body × offset`), so its `CarVisual` is reused untouched. Its blob shadow hides until `reset()`.
- **Hit car body** (traffic contacts only): a box of the slot's length × width and the `VehicleType` height and mass, at the pose the `TrafficView` drew it (`slot_transform(slot, false, 1.0)`), with velocity `tangent·v + right·v_lat`. It draws the registry's model mesh through a one-instance MultiMesh with the traffic material, the slot's paint and its lamp bits at the moment of the hit. The view hides the slot until `reset()`.
- **Impulse** at the contact point (road `(s, d)` from `HitDetection.Contact`, at `contact_height_frac` of the car height), from the contact's relative velocity `rel` (player minus other) and normal `n`:
  - normal: `(1 + restitution) · μ · max(rel·n, min_approach)`, with `μ` the reduced mass (the player's mass for barriers and props)
  - tangential (scraping): `tangential_frac · μ · rel_t`
  - opposite on the two bodies; each gets an upward hop of `lift_frac` of its normal speed change (at most `lift_max_kmh`)
  - spin: `I⁻¹ (r × J)` for a solid box, plus a deterministic tumble (roll away from the contact, yaw in the impulse's sense) scaled by the approach speed and each body's share of the reduced mass, capped at `spin_max_deg_per_s`. No randomness.
- **Arena:** invisible static boxes along the road from 40 m behind to 320 m ahead of the contact, one set per 20 m segment: a ground slab (road surface, reaching 40 m past each guardrail), the median barrier (`median_barrier_d`, `median_barrier_height_m`) and both guardrails (`guardrail_d`, `guardrail_top_m`). Built from road samples at `start()`; segments past `length_generated()` are disabled.

## Time and camera

- **Clock:** real, unscaled seconds (`delta / Engine.time_scale`). `finished` fires after `feel.slowmo_crash_s + crash.cinematic_tail_s` (2.5 + 0.4 s). The sequence only requests slow motion; it never sets `Engine.time_scale`, and it works the same when nobody honours the request (the tumble then runs at 1×).
- **Orbit camera:** its own `Camera3D`, made current in `start()`, restored to the rig's camera in `reset()` (not on `finished`: the results fade in over the still-orbiting crash). It orbits the midpoint of the bodies at `orbit_speed_deg_per_s` (real time), starting just round from the gameplay camera's direction, with the radius growing as the bodies separate. Reduced motion slows the orbit to `orbit_reduced_motion_frac`.
- **Floating origin:** an `origin_shifted` during the crash moves the bodies, the arena and the camera with the world.

## Pool

Built once in `setup()`: two `RigidBody3D`s with box shapes, the hit car's `MultiMeshInstance3D`, one `StaticBody3D` with 18 × 4 arena boxes, and the camera. `start()` and `reset()` create and free no nodes. Parked bodies are frozen (`FREEZE_MODE_KINEMATIC`), hidden, at the origin, with collision layer and mask 0; arena shapes are disabled.

## Limits

- Other traffic has no physics bodies: the tumbling cars pass through them. Until the run brakes the surrounding traffic, cars behind drive through the wreck.
- `reset()` during the cinematic aborts it without `finished` or `crash_finished`.
