# Run loop (WP4.1)

`src/run/run.tscn` / `run.gd` (`class_name Run`) is one run of the game: the world stack, the player car, traffic, the pure sims and their event buffer. It becomes the main scene at the M4 merge. Spec: "Core loop: Chase the Sun", "Scoring", "Lives, hits and crashes", "Run end". Contracts: [CONTRACTS.md](CONTRACTS.md) §4, §7, §8, §14.

| File | Class | Role |
| --- | --- | --- |
| `src/run/run.gd`, `run.tscn` | `Run` | flow, the 120 Hz tick, the frame update, retry, dev hooks |
| `src/run/run_events.gd` | `RunEvents` | the §7 adapter: buffers → `Events`, once per frame |
| `src/run/run_stats.gd` | `RunStats` | pure: the `run_over` stats from ticks and event records |
| `src/run/time_scale.gd` | `TimeScale` | slow motion (`Events.slowmo_requested`), reduced motion |
| `src/run/player_fx.gd`, `damage_fx.gdshader` | `PlayerFx` | ghost flicker, hood smoke, the flickering headlight |
| `src/run/run_ui.gd` | `RunUi` | minimal countdown, pause, results + RETRY, fallback readouts |
| `src/run/run_dev.gd` | `RunDevPanel` | the DEV rows (rule 10) |
| `src/core/game.gd` | `Game` | states, `start_run`, `pause`/`resume`, per-mode HUD sections |

## Flow

```
boot -> COUNTDOWN (hud.countdown_from x 1 s, car waiting on the line) -> RUNNING
RUNNING -- first hit --> RUNNING (ghost 2 s, 0.5x for 0.3 s, damage look)
RUNNING -- second hit --> CRASH (0.25x, feel.slowmo_crash_s real seconds or a tap) -> RESULTS
RESULTS -- RETRY --> COUNTDOWN (same frame: no scene reload)
COUNTDOWN / RUNNING <-> PAUSED (tree paused; pause() / resume() / toggle_pause())
```

- **Countdown hook (WP4.4):** set `auto_countdown = false` and call `go()` when the countdown screen (gyro calibration) is done. `Events.countdown_tick(n)` fires for 3, 2, 1 and 0 (GO).
- **Retry:** `retry()` builds a new `RunContext` and road, re-runs every world node's `setup()`, recreates `TrafficSim`/`TrafficDirector` (their RNG streams come from the context), resets the sims, and keeps the car node, its model and the camera. Measured ~25 ms headless; the budget is `hud.retry_max_s`.
- **Seeds:** run k uses `run_seed` for k = 0, then `Rng.derive_seed(run_seed, "retry/k")`. `run_seed = 0` draws `Rng.random_seed()` once at boot. Daily Drive keeps the day's seed.
- **Start line:** the road starts at s = 0 (the road builder's first chunk), so the car waits at `s = road.roadside_behind_m` (60 m): the chase camera never looks past the road's start. Leg 1 is that much shorter.

## Per tick (120 Hz, fixed dt)

The run ticks the car itself (`PlayerCar.self_tick = false`, the mode PlayerCar documents for this), so every tick integrates `VehicleTuning.physics_dt()` whatever the time scale. Order (CONTRACTS §4):

1. `car.tick(dt)`: controller, `VehiclePhysics.step`
2. `traffic_sim.step`, `director.step`
3. `lives.step`, `hit_detection.step`, `lives.on_contact`. A counted hit forwards `scoring.notify_hit`, `leg_tracker.notify_hit` and `traffic_sim.notify_hit(slot)`; then `scoring.set_ghost(lives.is_ghost())`
4. `scoring.step`; the boost fill goes into `boost_meter` (clamped to 1); the new records are scanned: `KIND_SUN_NUDGE` → `sun.lift`, `KIND_NEAR_MISS` → `traffic_sim.notify_close_pass`, thread / close pass → the leg tracker
5. `sun.advance(dt, scoring.is_too_slow())`, `scoring.set_night(sun.is_night())`, traffic headlights
6. `legs.observe_multiplier`, `legs.step`. A crossing runs the spec's order: `notify_checkpoint`, `sun.on_checkpoint(avg speed)`, the leg bonuses (+ objective, + journey bonus at the coast), `lives.restore_life` on a clean leg, then `set_night` again (a leg finished at night pays ×2)
7. `RunStats.observe_tick` / `consume`

All sims write into one `ScoreEventBuffer` (capacity `scoring.event_buffer_capacity × 5`); `RunEvents.drain()` publishes it once per frame. The director's leg follows `legs.leg_index` (the DEV LEG button can pin it).

**Traffic headlights** follow the sky: on while the color script's `emissive_headlight` ramp at the sun clock's `sky_t` is above 0.3 (the M3 drive scene's threshold). The ramp is sampled once into a 1024-entry table, so the tick only indexes it (deterministic and free). This reads right: lights come on in the golden hour before the sunset flips `is_night()`, and go off during the dawn, exactly as the sky darkens and brightens. `director.set_night` follows the same flag, so spawns match.

## Frame-rate reactions

- **First hit:** `Events.hit` (CameraRig already shakes on it), `slowmo_requested(0.5, 0.3, &"first_hit")`, `PlayerFx` (listens to `hit` / `ghost_started` / `ghost_ended` / `run_started`): the car's `CarVisual` blinks at 12 Hz for the ghost; after the first hit, one `CPUParticles3D` puff stream at the `smoke_hood` marker (count × `Quality.particle_scale`) and a quad over `Lights/headlight_L` flickering between a dead and a sputtering lamp. Both are unlit (`damage_fx.gdshader`, `wb_output`), 1 draw call each, hidden until damaged.
- **Crash (fallback until WP4.2):** `crash_started`, `slowmo_requested(0.25, 2.5, &"crash")`, a braking controller on the car, `traffic_sim.notify_hit` on every car within 80 m (hard brake, hazards), then after `feel.slowmo_crash_s` real seconds or a tap: `crash_finished`, RESULTS.
- **Slow motion keeps the sim exact:** `TimeScale` sets `Engine.time_scale = s` *and* `physics_ticks_per_second = round(120 × s)`, so there are fewer ticks per real second but each is still 1/120 s of simulated time. A test checks that a run with slow motion and one with reduced motion (none) give the same trace.
- **Results:** `scoring.notify_run_end`, then `Events.run_over(results)` with the spec's keys (`RunStats.results`) plus `personal_best` and `new_best`. The best score is stored with `Save.submit_best_score(mode, score)`.

## Seams

- **CrashSequence (WP4.2):** `Run._start_crash_sequence()` returns false today. The orchestrator replaces its body with `crash_sequence.start(...)`, connects `finished` to `_end_crash`, and returns true; `skip()` then forwards to `crash_sequence.skip()` and `retry()` calls `crash_sequence.reset()`.
- **HUD (WP4.3):** installed when `res://src/ui/hud/hud.tscn` exists: `hud.bind(feed)`, `pause_pressed` → `toggle_pause`, `camera_pressed` → the camera cycle. The run fills `feed` (a `HudFeed`) every frame. Without it, `RunUi` shows fallback readouts.
- **Screens (WP4.4):** `go()`, `pause()`, `resume()`, `retry()`, `skip()`, `last_results`, `Game.paused_from`.

## Dev (rule 10)

DEV (top-left, under the score block): CAM, the dev HUD, STEER, THR, MIRROR, CAR, RECAL, RESET (car back in a lane), RETRY, RING/WHEEL, SIZE, LIVES INF, LEG AUTO/1–8, SANDBOX, DRIVE (the M3 drive scene). Web: `?scene=drive` opens `src/dev/car_drive.tscn`, `?scene=sandbox` the traffic sandbox. Snaps: `tools/snap.sh src/run/run.tscn --state=countdown|running|paused|results --damaged --ghost --sky_t=… --s=… --cam=… --seed=…`.

## Pending tuning

Numbers with no tuning field yet, kept as `const`s in a marked block: `Run.START_SPEED_KMH` (120, rolling start), `START_LANE` (1), `COUNTDOWN_STEP_S` (1 s), `HEADLIGHTS_ON_RAMP` (0.3), `CRASH_BRAKE_RADIUS_M` (80); `PlayerFx` ghost flicker 12 Hz, smoke count / lifetime / speed / size, lamp flicker 14 Hz and lit share.
