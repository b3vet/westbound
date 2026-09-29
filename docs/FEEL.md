# Feel: haptics, slow motion and juice (WP7.4)

Spec: *Audio, haptics and game feel* (Haptics, Game feel), *Accessibility → Reduced motion*, *Performance budget* (particles per tier). Plan: WP7.4, D16. Every number lives in `FeelTuning` (`data/tuning/feel.tres`).

## Haptics — `src/platform/haptics.gd`

A listener service, meant to be the autoload `Haptics` (no `class_name`). It reacts to `Events` only and sends nothing while the `haptics` setting is off (Settings → HAPTICS).

| Event | Pattern | Duration | Amplitude |
| --- | --- | --- | --- |
| `scored(pass)` | light tick | 12 ms | 0.3 |
| `scored(cut)` (not in the spec table) | light tick, as a pass | 12 ms | 0.3 |
| `scored(close_pass)` | medium tick | 20 ms | 0.6 |
| `scored(thread)` | heavy thump | 45 ms | 1.0 |
| `chain_banked` (amount > 0) | double light tick | 2 × 12 ms, 90 ms apart | 0.35 |
| `hit` (lives left > 0) | strong burst | **150 ms** (spec) | 1.0 |
| `crash_started` | long rumble | **400 ms** (spec) | 0.8 |

A cut gets the pass tick so that every scoring event has a haptic (spec: "every scoring event gets sound, haptics and a visual response within one frame"; WP7.5). The run-ending hit plays only the crash rumble.

**Overlap.** A pulse never cuts a stronger one that is still playing (priority crash > hit > thread > close = bank > pass); Android and the web cancel a running vibration on a new call. A hit or crash cancels a pending second bank tick. Pulses are at least `haptic_min_ms` (10 ms), since many Android vibrators skip shorter ones.

**Platforms.**

| Platform | Call | Notes |
| --- | --- | --- |
| Android | `Input.vibrate_handheld(ms, amplitude)` | One-shot `VibrationEffect` with amplitude (API 26+, devices with amplitude control; others vibrate at full strength). `permissions/vibrate=true` is in the export preset. |
| iOS | `Input.vibrate_handheld(ms, amplitude)` | Core Haptics continuous event with that intensity and length (iPhone 8 and later). Older devices play the fixed system buzz, so ticks would be long there. |
| Web | `navigator.vibrate(ms)` via `JavaScriptBridge` | Duration only. Detected once; iOS Safari has no Vibration API and is skipped silently (Godot's own `vibrate_handheld` would print "This browser does not support vibration." on every call). Calls wait for the page's first user activation (`navigator.userActivation.hasBeenActive`), so Chrome logs no blocked-call intervention. |
| Desktop, headless | none | Tests use the `RECORD` backend: pulses go to a fixed ring log. |

The double tick's second pulse is a countdown advanced in `_process` with real time (it keeps its gap in slow motion and while paused: `PROCESS_MODE_ALWAYS`). No timers or other objects are created per event.

## Slow motion — `src/run/time_scale.gd`

| Cause | Scale | Real seconds | Asked by |
| --- | --- | --- | --- |
| Thread | 0.6× | 0.25 | `TimeScale` itself, on `Events.scored(thread)` (WP7.4) |
| First hit | 0.5× | 0.3 | the run, on `Events.slowmo_requested` |
| Crash | 0.25× | 2.5 | the run / `CrashSequence`, on `Events.slowmo_requested` |

A request replaces a weaker (higher-scale) one that is running, never a stronger one; an equal one restarts its duration. So crash > first hit > thread, and back-to-back threads extend the slow motion. The sim always steps its fixed dt: slow motion lowers the physics tick rate with the time scale (see the script header). Reduced motion ignores every request.

## Reduced motion

Turns off camera shake, camera roll and the FOV punch (`CameraRig`) and slow motion (`TimeScale`). Speed lines, smoke and sparks are not motion of the camera and stay on.

## Camera

`CameraRig` already listens: shake on `Events.hit` (`feel.hit_shake_*`), a tiny shake on close passes, the FOV punch on `Events.boost_started` (`feel.boost_fov_punch_*`). WP7.4 only verifies them (`tests/fx/test_slowmo_table.gd`).

## Juice — `src/fx/`

`PlayerFx` (the run's damage look) creates `JuiceFx` and `CarFxEvents` as children and binds them to the player car, so the run needs no extra wiring.

| Effect | Node | Trigger | Draws |
| --- | --- | --- | --- |
| Speed lines and wind streaks | `SpeedLines` (one static `ArrayMesh`, `assets/shaders/speed_lines.gdshader`) | speed above 180 km/h (intensity 0.3 → 1 at 260 km/h, + boost) | 1 |
| Tire smoke | `FxParticles` (one pooled `MultiMesh`, `assets/shaders/fx_particles.gdshader`) | `Events.hard_braking_changed(true)`: puffs at the rear wheels' contact points | 1 (shared) |
| Sparks | same `FxParticles` | `Events.barrier_scrape(world_pos)`: a burst thrown off the barrier | shared |
| Glitter | `HudGlitter` (HUD, WP4.3) | close passes and threads at high multipliers | (HUD) |

**Draw calls:** idle 0 (both nodes hidden, never alpha 0); at most 2 while active (speed lines + particles).

**Speed lines.** Screen-space radial streaks, placed in clip space by the vertex shader at view depth `speed_lines_depth_m` (2.5 m) with the depth test on: the cockpit's dash, pillars and roof and the hood hide them, while the car in the outside cameras (farther away) stays under them. In the hood and cockpit cameras (`speed_lines_edge_camera_modes`) they start at 80 % of the way to the screen edge instead of 55 % (D16: nothing covers the road). The mode is read from the active `CameraRig`, so snaps and dev mode changes count. Every third streak is a wind streak (shorter, wider, fainter, slower). The streak phase is integrated on the CPU from the speed, so slow motion slows them. Hidden from `crash_started` to the next `run_started`.

**Particles.** One structure-of-arrays pool of `particles_pool` (96) quads allocated at load; the live cap is pool × `Quality.particle_scale`; a full pool drops new particles. Smoke puffs are camera-facing, lit by the sun like a horizontal surface, and grow and fade. Sparks are camera-facing ribbons along their motion relative to the car that threw them (the viewer rides along), hot white to orange, not lit. Both fade in fog. Positions are world space and follow `Events.origin_shifted`. The randomness is the node's own fixed-seed generator (visual only, never a gameplay stream).

**Tier clamps.** `Quality.particle_scale` (Low 50 %, Medium and High 100 %, halved again by governor rung 2) scales the streak count, the particle cap, the smoke rate and the spark count. It is re-read on `quality_changed` and `governor_changed`.

**Parity.** Both shaders end with `wb_output()`. The speed lines are additive and use the glow shader's background estimate on Compatibility (additive layers are judged by eye, CONTRACTS.md §13). Particles blend with mix.

### `CarFxEvents` (the missing emitters)

No sim emitted `hard_braking_changed` or `barrier_scrape`. `CarFxEvents` is a thin adapter that publishes them from the player car:

- `hard_braking_changed(active)` when `CarVisual.tire_smoke` changes (brake input, deceleration ≥ `vehicle.tire_smoke_min_decel_mps2`, speed ≥ `vehicle.tire_smoke_min_speed_kmh`), polled once per frame; off on a new run and a crash.
- `barrier_scrape(world_pos)` on `hit(barrier)` (every barrier touch is a hit, spec), at the barrier face the car is nearer (the median barrier or the guardrail, as `HitDetection` tests them), at the car's `s`, `sparks_height_m` above the road.

`RunEvents` is the natural owner of both; if it grows them, `CarFxEvents` goes away. Audio (tire squeal, scrape) can listen to the same signals.

## Review

- Snaps: `tools/snap.sh src/fx/dev/fx_preview.tscn --fx=lines|smoke|sparks --speed_kmh=220 --cam=chase|hood|cockpit --sky_t=… --hud=false` (the full run with the effect forced; see the script header).
- Tests: `tests/platform/test_haptics.gd`, `tests/fx/test_juice_fx.gd`, `tests/fx/test_slowmo_table.gd`.
