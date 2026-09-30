# Westbound — Phased Implementation Plan

Sep 28, 2026 · companion to [`WESTBOUND HANDOFF.md`](../WESTBOUND%20HANDOFF.md) (the **spec**)

The spec is the source of truth for *what* to build. This plan covers only *how and in what order*: phases, parallel work packages, gates and orchestration. Where the two disagree, the spec wins. Any deviation must be listed in [§2](#2-deviations-from-the-spec-flagged) before it is built.

---

## 1. Kickoff decisions

| Topic | Decision |
| --- | --- |
| Build order | **Parallel tracks.** The pure headless systems (`vehicle_physics`, `traffic_sim`/IDM/MOBIL, `scoring`, `sun_clock`, `passability`) start early, alongside the rendering milestones. Milestone *done* gates stay exactly as the spec defines them, in M0→M9 order. |
| Team shape | One orchestrator (plans, briefs, reviews, merges, pushes) plus up to **5 parallel subagents** per wave. |
| Git | All work lands on `claude/game-implementation-phases-asl5jz`. Each subagent works in its own git worktree. The orchestrator reviews and merges each work package, runs the full suite, then pushes. No PRs unless requested. |
| Gates | We **pause for the owner's device playtest at M1 (look/thermal), M2 (car feel) and M3 (traffic)**. At every other gate we continue, and device feedback is folded in asynchronously. |
| Playtest vehicle | **Web builds on the iPhone's mobile browser** are the everyday loop. Native iOS builds (owner's Mac + iPhone) are for thermal and performance acceptance, gyro, haptics and platform services. |
| Interim assets | Generated placeholders (code or Blender scripts), cool_drive's 3 cars, Chakra Petch (OFL), and **clearly CC0-licensed packs** (e.g. Kenney, CC0 on Freesound). Every third-party file is logged in `assets/LICENSES.md`. |

## 2. Deviations from the spec (flagged)

| # | Spec says | Plan does | Why |
| --- | --- | --- | --- |
| D1 | "Build in this order" (M0→M9) | Pure sim systems are pulled forward as parallel tracks; the gates stay in order | Keeps 5 agents busy. The sim systems have no rendering dependencies. |
| D2 | All assets made in-house | CC0 packs allowed as **interim** placeholders, logged with licenses | Owner decision. In-house art replaces them on the art track. |
| D3 | `data/tuning.tres` holds every constant | `data/tuning.tres` is the root `Tuning` resource. It references one sub-resource per system (`data/tuning/vehicle.tres`, `traffic.tres`, `scoring.tres`, …) | Parallel agents editing one `.tres` would conflict on every merge. All constants still live in data, reachable from one root. |
| D4 | Acceptance is on device | Web (Compatibility renderer) is the everyday playtest path. Thermal and fps acceptance numbers count **only from native iOS** | Owner decision. A web build on Safari is a feel check, not a thermal proxy. |
| D5 | M0 done needs an Android phone | Android is exported and CI-built, but device verification is **pending an Android device** | Only an iPhone is confirmed. See [§10](#10-open-items-for-the-owner). |
| D6 | Braking 9 m/s² *and* 250→100 km/h in ~1.3 s (contradictory: 9 m/s² alone gives ~4.6 s) | **Owner decision:** 9 m/s² stands; the 1.3 s feel target becomes the model's measured time (≈ 3.5–3.8 s: drag, engine braking and rolling resistance add to the 9 m/s²) | Heavy, committed braking; rewards reading traffic early |
| D7 | Density 16 vehicles/km/lane at leg 8+ **and** max 60 active vehicles | Measured: desktop ~3.2 µs per car per tick; **owner's iPhone (web): 0.10 ms average tick with 45 cars at 60 fps**. 3 lanes barely reach the cap; 4 lanes hold about 10% below target at 60. The owner finds leg 8 not crowded enough (M3), so density and cap were raised: **cap 90** (D11) | Resolved with measured sim cost + owner feel |
| D8 | Night tailgating: "high beams flash when the player tailgates within 10 m for over 1 s" | **Owner decision:** removed as a traffic reaction; the line was a grammar slip. The player gets a manual high-beam control in Phase 5 (WP5.4) instead | Owner, 2026-09-28 |
| D9 | Manual layouts: "a gas pedal, with brake and boost buttons beside it" | **Owner request (M2):** one thumb per side, so the gas pedal is much smaller and joined to boost. Hold for gas, slide up onto the attached boost cap (or flick up) for boost while gas stays on. All touch controls are smaller, and the `controls_scale` setting adjusts them | Owner, 2026-09-28 |
| D10 | Drag steering shows a floating anchor ring and thumb dot | **Owner request (M2):** option to show a steering wheel that turns with the drag (visual only; the input math is unchanged). Setting `drag_visual` = ring or wheel | Owner, 2026-09-28 |
| D11 | Cockpit camera "later", once cars have interiors; leg 8+ density 16 vehicles/km/lane with 60 active | **Owner request (M3):** an in-cabin camera now. A generic procedural cockpit (dash, A-pillars, roof edge, a wheel that turns with the steering) is drawn around a driver's-eye camera, and the car body is hidden in that mode. Per-car interiors replace it when the models have them (ART5). **Density:** the owner found leg 8 "not crowded enough, easily passable". WP4.8: the director delivered only 67% of target at leg 8 (spawn gaps behind fast cars; IDM's own cruising gaps cap a lane at ~13–14/km). Now: a band top-up and a slow density gain, late-leg car-following headways ramping ×1.0 → ×0.8, leg-8 target **18** vehicles/km/lane (was 16), cap **90**. Measured in the −150/+600 m window around the player: leg 8 went from 10.7 to 16.3 (3 lanes) and 16.8 (4 lanes), +52–55%. Phone cost ≈ 0.14–0.21 ms per tick. A DEV "DENS" button scales density live for feel checks. All numbers in tuning | Owner, 2026-09-29 |
| D12 | M3 gate: "zero impossible windows" over the 10,000 km soak | Gated on the lane counts in use (3 lanes: zero). The 3 windows found on 2-lane roads (the player cut in behind a vehicle under 100 km/h; the 2-lane right lane flows at 95 km/h) go to Phase 6, where 2-lane sections and `passability.gd` arrive. The D11 10,000 km soak found 1 window on 3 lanes (the bot's own lane change into a lane a commuter was legally merging into, 0.68 m clearance); it also goes to WP6.1 passability rather than redefining the gate after the result | Orchestrator, M3 / WP4.8 |
| D13 | Retry: "a countdown" at run start and "Retry puts the player back on the road within 2 seconds" | The 3-2-1 countdown (with gyro calibration) runs at 0.5 s per step on a retry (`hud.retry_countdown_step_s`): driving again 1.5 s after RETRY. The first run keeps 1 s steps | Orchestrator, WP4.4 |
| D14 | HUD: speed bottom-left, boost bottom-right | **Owner request (M4 playtest):** the speedometer sat exactly where the left thumb drags the steering. Speed, the minimum-speed bar and boost move to a compact bottom-centre cluster under the car, and HUD readouts stay out of tuned thumb zones (the lower outer corners) in every control layout | Owner, 2026-09-29 |
| D15 | Driver types: fastest is Aggressive at 150–190 km/h (5→20 % share); lane flows 95–150 km/h | **Owner request (M5 playtest):** traffic feels slow and samey. Add fast, decisive traffic with more variety: a new fast profile (e.g. "Racer", ~190–250 km/h, sports cars) fast enough for the player to follow and try to overtake; wider speed spreads; a higher fast share; faster left-lane flow. Fairness rules unchanged (telegraphing, no ambush, rear-end prevention) and passability still guaranteed. **WP6.6:** racer 190–250 km/h (sports/coupe, left lanes), commuter 95–145, aggressive 140–200, ±5 % jitter; fast share 15 % → 35 % by leg; lane flows 95/120/145/160 | Owner, 2026-09-29 |
| D16 | Damage: "smoke from the hood" after the first hit | **Owner request:** the hood smoke hid the road in the hood camera. It no longer shows in the hood and cockpit cameras (`feel.smoke_hidden_camera_modes`); the flickering headlight and the smoke in outside cameras remain | Owner, 2026-09-29 |
| D17 | Intensity waves (spec) vs D11 leg-8 density | WP6.2's waves (50 % breathers) and set-piece zone clearing brought leg-8 delivered density to 73–74 % of target (D11 had 91 %). The soak metrics baseline was rewritten (density −18 %). WP6.6 rebalanced: breathers 70 %, late-leg headway ×0.55, gain cap 1.8 → leg 8 meets 83 % (3 lanes) / 89 % (4 lanes). Faster lanes trade against density. **Owner decision:** keep late legs crowded for now (may pivot later); racers should also arrive from behind and pass the player at speed (WP6.7). WP6.7 found legal racers rarely get past a 170–230 km/h player in dense traffic (0.07 passes/km at leg 8); **owner: racers weave harder** (WP6.9: tighter racer gaps and more willing lane changes, still signalled, no ambush, rear-end safe) | Orchestrator, WP6.2 / WP6.6 |
| D18 | Forks: "traffic heading to either branch picks its branch by lane" | No car is ever on a branch before the player picks: a breather and a spawn guard keep the approach to a split quiet, and traffic resumes on the chosen branch. Also: forks choose between staying in the current biome (left) or advancing (right), always 8 legs to the coast; the branch not taken narrows away in the fog; the opposite carriageway is out of view ~3 km around a fork (WP6.5, docs/FORKS.md §8) | Orchestrator, WP6.5 |
| D19 | Haptics table has no entry for a cut | A cut plays the pass light tick, so every scoring event has a haptic (the one-frame rule, WP7.5) | Orchestrator, WP7B |
| D20 | Driver table: trucks, buses and cruisers at 80–95 km/h everywhere | Inside a lane-drop zone (LANE ENDS sign through the narrowing + 150 m) all lanes are harmonised to 120 km/h (dropping lane 110) and slow vehicles are sped up toward 110 km/h, so nobody merges at a standstill beside 130–190 km/h lanes (canyon soak: 53 collision pairs per 504 km → 0 per 1,008 km) | Orchestrator, WP6.8 |
| D21 | Passability checks "the next ~300 m" before a batch is committed | The director commits a batch beyond the fog (as before) and checks it while still invisible, time-sliced (1 slice per 120 Hz tick); a failing batch is re-rolled (≤ 5) then its worst blockers removed (≤ 8) before the player can see it. The check reads the batch as an arriving player meets it. Braking in the search is unlimited, as the spec words it (open: a braking-limited bound is stricter but re-rolls more at D15 speeds) | Orchestrator, WP6.1 |
| D22 | First-run chooser: steering and throttle | It also asks for the hand (left-handed mirror); SKIP keeps the defaults (drag + auto, right hand) | Orchestrator, WP8.1 |
| D23 | Warm-up: 20 s of empty road on the first run | Also skippable (hint panel with SKIP); density comes back over 12 s in 4 steps; only on the first Journey started from the title | Orchestrator, WP8.1 |
| D24 | Every run can go on the boards | A run with the first-run warm-up is not submitted: the replay verifier rebuilds runs from the seed without the empty road | Orchestrator, WP8.1 |
| D25 | Settings: one screen | Three pages (GAME, CONTROLS, AUDIO) plus ACCOUNT; they no longer fit on two at 125 % text | Orchestrator, WP8.1 |
| D26 | Final car roster (open spec question) | 8 slots: Falcon GT, Night Viper, Brute V8 drivable; slots 4–8 "COMING SOON" placeholders showing their unlock rule (the unlock is recorded) until ART delivers cars | Orchestrator, WP8.2 |
| D27 | XP from runs (loop practice not mentioned) | Journey, Daily and Loop practice earn XP (`xp_modes` in tuning); XP = banked score × 1.0; level L needs 5,000 × (L−1)^1.8; first unlock (SUNSET paint, level 2) after 1–3 runs | Orchestrator, WP8.2 |
| D28 | Progression for existing players | A save with bests but no XP starts once at the sum of its personal bests; a recorded journey counts as reaching the coast | Orchestrator, WP8.2 |
| D29 | Leaderboards via Game Center / Play Games (`platform/leaderboards.gd`: Journey all-time and weekly, Daily, distance) | The boards are our server's (N7, shown in-game; the MP handoff retires platform boards). `platform/leaderboards.gd` is a thin optional mirror, off by default (`mirror_boards`). Achievements stay on the platforms, mirrored on unlock; the 25 are designed from the spec's five examples and its systems (docs/ACHIEVEMENTS.md) | Orchestrator, WP8.3 |
| D30 | Cooling icon shows while the governor is active | Shown only while a thermal step is part of the offset (a weak device throttled for frame time alone would otherwise show a hot-phone icon all the time); `cooling_icon_any_reason = true` restores the literal rule | Orchestrator, WP9.1 |
| D31 | Governor rungs apply live | The view-distance rung (−150 m) is held until the run ends: the view distance still feeds the simulation (spawn distance, leg-planner horizon, fork candidates; docs/QUALITY.md audit). After N8.2 decouples it, `governor_view_distance_between_runs = false` | Orchestrator, WP9.1 |
| D32 | Reduced motion: camera shake, roll, FOV punch, slow motion | Also HUD pops/slides/pulses (fades only), screens, the title's attract camera (holds the chase pose), ghost and dead-headlight flicker (2 Hz, under WCAG 2.3.1's 3 flashes/s), the web loading bar (system `prefers-reduced-motion`). Speed lines stay on (open: owner decision) | Orchestrator, WP9.3 |

New deviations get a row here before they are built.

## 3. Environment and tooling (verified Sep 28)

- **Godot 4.7-stable** (`4.7.stable.official.5b4e0cb0f`): the Linux binary downloads from the GitHub release and runs headless. `tools/godot.sh` pins the version and fetches the binary plus web export templates.
- **Headless tests:** `godot --headless --script tests/run_all.gd`. It exits non-zero on failure.
- **Visual review in the container:** Xvfb + Mesa llvmpipe render both renderers to PNG: **Compatibility** (llvmpipe) and **Mobile** (Vulkan on lavapipe via `mesa-vulkan-drivers`). `tools/snap.sh <scene> [--renderer=both] [--sky_t=…] [--cam=…]` gives screenshots for look reviews, and `tools/parity.sh` checks that the two renderers produce the same pixels. Thermal and fps are still checked on device.
- **Web smoke test:** Chromium and Playwright are available. `tools/web_smoke` loads the web export headless, fails on console errors and saves a screenshot.
- **Reference project:** `b3vet/cool_drive` is cloned read-only for porting (camera spring follow, DESIGN.md system, the physics *approach*, the 3 placeholder `.glb` cars and the music MP3s). cool_drive is a drift game, so its constants are **not** carried over. The spec's grip-driving targets are.
- **CI (GitHub Actions):** fast test tier on every push; web export; deploy to GitHub Pages for phone playtesting (see [§10](#10-open-items-for-the-owner)). The soak tier runs on demand and before every gate.
- **Native builds:** iOS is exported locally on the owner's Mac. Android is exported via CI once an SDK is set up. Signing keys never enter the repo.

## 4. Orchestration model

### Roles

- **Orchestrator:** writes work-package briefs, owns the shared files, reviews every diff against the spec, merges, runs the full suite and snapshots, pushes, keeps the [status tracker](#9-status-tracker) current, and flags spec deviations.
- **Subagents (≤5 at once):** each takes one work package (WP) in an isolated worktree, writes the tests first, implements, and returns a handoff note.

### Work-package brief template

Every WP brief handed to an agent has these fields:

1. **Goal** and the **spec sections** it implements (quoted numbers, not paraphrased).
2. **Owned paths:** the only files the agent may create or modify.
3. **Read-only dependencies:** the contracts and modules it builds against.
4. **Tests to write first:** the headless tests that define done.
5. **Acceptance:** tests green, lint clean, a snapshot if visual, and a handoff note.
6. **Out of scope:** explicitly listed, to stop scope creep between parallel agents.

### Shared-file rules (merge safety)

- **Orchestrator-owned:** `project.godot`, the autoload list, `src/core/events.gd`, the root `data/tuning.tres`, `export_presets.cfg` and CI workflows. An agent that needs a change there writes it into its handoff note ("needs: signal `close_pass(clearance, points)`"), and the orchestrator applies it at merge.
- **Per-system tuning sub-resources** (D3) are owned by the WP that owns the system.
- **Tests are auto-discovered** (`tests/**/test_*.gd`), so no test registry causes conflicts.
- **Contracts are frozen** after Phase 0. Changing one requires an orchestrator decision and a note in `docs/CONTRACTS.md`.

### Merge gate (every WP)

1. The full fast tier is green, not just the WP's own tests.
2. `tools/lint` is clean. It enforces the budget by construction:
    - no `StandardMaterial3D`/`ORMMaterial3D` in gameplay scenes
    - no `OmniLight3D`/`SpotLight3D`
    - no shadows enabled
    - no post effects beyond the color grade
    - no numeric literals in sim code outside an allow-list (0, 1, 0.5, …)
3. **No allocations in sim ticks:** sim code uses pre-sized `Packed*Array` structure-of-arrays storage and no per-tick `Array`/`Dictionary`/object creation. This is a review check, backed by a tick-cost benchmark test.
4. **Determinism:** any seeded system has a trace-hash test.
5. Visual WPs attach `tools/snap.sh` screenshots across the color-script keyframes.

### Cadence

- A **wave** is a set of ≤5 WPs that can run concurrently. The next WP starts as soon as its dependencies are merged; we don't wait for the whole wave.
- **Art-track WPs** take a slot from the current wave when scheduled.
- **Playtest notes** go in `docs/playtests/Mx.md`, one per gate: device, build, dev-HUD numbers and feel notes.

## 5. Architecture contracts (frozen in Phase 0)

Phase 0 writes these as GDScript interfaces or stubs plus `docs/CONTRACTS.md`, so the parallel tracks can build against them before the real implementations exist.

| Contract | Shape (sketch) | Consumers |
| --- | --- | --- |
| **Coordinates** | Road space (`s` along the centerline in meters, `d` lateral). Sign conventions and lane indexing (right-hand traffic, flow speed rising toward the left) are fixed once. Cars face −Z, Y up, meters. | everything |
| **`RoadPath`** (pure) | `sample(s) -> {pos, tangent, up, curvature, elevation, grade}`; `lane_count(s)`, `lane_center(lane, s)`, `shoulder/barrier edges(s)`; `features(s0, s1)` for crests, bends and forks; seeded; the sun-heading constraint (15–30° off the camera axis) | road_builder, vehicle_physics, traffic_sim, passability, director |
| **`VehicleState` / `VehicleInput`** | Player state in road space plus world yaw. Input is `{steer −1..1, throttle 0..1, brake 0..1, boost}` | physics, controllers, scoring, camera |
| **Controller** | `PlayerController`, `AIController` (later `HopController`), switchable at runtime without respawn | player_car, traffic (future Car Hopper) |
| **`VehicleType` / `DriverProfile` / `CarDef`** | Data resources: dimensions, physics profile (mass, grip, lane-change time, shove strength), IDM/MOBIL parameters | physics, traffic, garage |
| **`TrafficSim` state** | Structure of arrays: `s, d, v, v0, len, width, lane, lc_state, lc_timer, flags…`, fixed capacity 60 | traffic_view, scoring, passability, sandbox |
| **`SpawnSource`** | `plan_batch(ctx, s_from, s_to) -> spawns`; Flow, SetPiece and Daily now, Beatmap and HopTargets later | traffic_director |
| **`ScoringRuleSet`** | `step(ctx, dt)` → emits score events; swappable per mode | run.gd, HUD |
| **`SunClock`** | `sky_t`, `advance(dt, speed_ctx)`, `lift(fraction)`, `is_night`, dawn transition | run.gd, color_script, HUD |
| **`Events` bus** | The full signal catalog from the spec, declared up front (pass, close_pass, cut, thread, slipstream, bank, hesitated, hit, crash, checkpoint, leg_start, night, dawn, boost, lives, …) | HUD, audio, haptics, camera, particles (listen only) |
| **`RunContext`** | Run seed → derived RNG streams (road, traffic, props, events) through a stable hash (our own FNV/PCG, never `String.hash()`) | all seeded systems |
| **Music clock** | `beat_phase`, `bar`: stub only in v1 | future Tempo Highway |

## 6. Test tiers

| Tier | When | Contents |
| --- | --- | --- |
| **fast** | every commit, CI on every push; target < 3 min | unit tests for every system, short determinism traces, mapping and settling tests, lint |
| **soak** | before every gate, and on demand | 10,000 simulated km of traffic with the bot, 10-minute physics fuzz, passability soak, metrics regression (±15% vs `tests/baselines/`) |
| **visual** | visual WPs and every gate | `snap.sh` across color-script keyframes; web smoke test in Chromium |
| **device** | M1, M2, M3 pauses; async otherwise | owner: 20-minute native soak at Medium (dev-HUD numbers), feel playtest on web and native |

---

## 7. Phases

Each phase maps to one spec milestone. **Tracks A–C** are the pulled-forward headless systems (D1). Its gate is the spec's *done when* plus the automated checks above.

### Phase 0 — Foundation (M0)

**Wave 0a (sequential, critical path):**

- **WP0.1 Skeleton.**
    - `project.godot`: 120 Hz physics ticks, physics interpolation, landscape, stretch mode, Mobile renderer with a Compatibility override for web, 60 fps cap.
    - The spec's folder tree.
    - Autoloads: `Events`, `Game`, `Settings`, `Save` stubs.
    - `src/core/rng.gd` with derived streams.
    - `tests/run_all.gd` with auto-discovery, tiers, an assertion helper library and the exit code.
    - `tools/godot.sh`.
    - A root `CLAUDE.md` holding the spec's working rules plus this plan's merge gate.
    - CI for the fast tier.

**Wave 0b (4 parallel):**

| WP | Scope | Tests / acceptance |
| --- | --- | --- |
| WP0.2 Contracts & tuning | Everything in [§5](#5-architecture-contracts-frozen-in-phase-0) as stubs; `docs/CONTRACTS.md`; the `Tuning` classes with every value from the spec's Tuning reference; resource scripts for VehicleType, DriverProfile, CarDef, BiomeDef and SetPieceDef | RNG stream independence and determinism; tuning loads, and every reference value is present |
| WP0.3 Dev HUD & frame pacing | Dev HUD (fps, frame time, draw calls, primitives, render scale, vehicles, sim time per tick, thermal); three-finger tap and backtick toggles; quality-tier plumbing (render scale, MSAA, max fps 60/30, far plane) | Tier table applied correctly (headless) |
| WP0.4 Exports & web pipeline | `export_presets.cfg` (iOS, Android, Web); `tools/export_web.sh`; CI web export and Pages deploy; Playwright smoke test | Web build loads in headless Chromium with no console errors |
| WP0.5 Review tooling | `tools/snap.sh`; `tools/lint` (perf-budget and magic-number rules); tick-cost benchmark harness | Lint catches seeded violations |

**Gate M0 (continue, async device check):** `run_all.gd` green in CI; the web build loads on desktop Chrome and iPhone Safari; the empty scene runs natively on the iPhone (owner); Android pending (D5).

### Phase 1 — Road and look (M1) + Track A kickoff · ⏸ **PAUSE GATE**

| WP | Scope | Tests / acceptance |
| --- | --- | --- |
| WP1.1 RoadPath | Pure seeded centerline: radius ≥ 1,200 m; grade ≤ 5%; blind crests flagged; lane-count sections; sun-heading constraint | Curvature and grade bounds, C1 continuity, determinism, lane queries, sun angle kept within 15–30° |
| WP1.2 Road build | `road_builder` (pooled 200 m ribbon chunks: lanes, shoulders, median barrier, guardrails, dashed and edge lines, reflectors); `floating_origin` (every 2 km, one frame); blob shadow decal | Origin shift leaves no hitch or seam (positions continuous across the shift); pool never allocates after warm-up |
| WP1.3 Look | Shared world shader (single-light vertex-lit, fog, fake-headlight uniform), road shader, sky dome (gradient, sun disc, glow, stars), cloud cards, horizon silhouette cards, `color_script.tres` with global uniforms pushed once per frame, color grade, live `sky_t` debug slider | Pure color-script interpolation tests; snaps at all 7 keyframes |
| WP1.4 Roadside & farmland | `roadside.gd` MultiMesh rhythm (poles every 50 m, reflector posts every 25 m, guardrail posts, gantries, billboards, fences); `biome_director` skeleton; `data/biomes/farmland.tres`; placeholder or CC0 props; view distance per tier | Draw calls ≤ 100 and triangles ≤ 150k in the M1 scene (measured headless via the Compatibility renderer) |
| WP1.5 **Track A: vehicle physics** | Pure bicycle model `step(state, input, dt, params)`; the steering pipeline; road curvature feed-forward; `CarDef` for the 3 placeholder cars | **The spec's full physics suite:** lane-change times at 100/200/280 km/h ±5% for each car; settling; 60 s straight-line stability on a curve; top speed and 0–200 km/h within 2%; 250→100 km/h braking per D6 (measured ≈ 3.6 s); determinism; 10-minute fuzz with no NaN |

The orchestrator then integrates `scenes/dev/road_drive.tscn`: an auto-driven empty-road drive at speed with the `sky_t` slider and the dev HUD. This is the M1 soak scene.

**Gate M1 ⏸:** tests and lint green; snapshots reviewed across the whole color script; **owner** runs the native iPhone 20-minute drive at Medium (no throttling, 60 fps, dev-HUD numbers recorded) and checks the look on web and native; playtest note written.

### Phase 2 — Car, controls, cameras (M2) + Track B · ⏸ **PAUSE GATE**

| WP | Scope | Tests / acceptance |
| --- | --- | --- |
| WP2.1 Player car | `player_car.gd` (controller → physics at 120 Hz → world transform, interpolated); `car_visual.gd` (roll and pitch springs, wheels, steer, brake lights, simulated gearbox); modular-convention post-import script that stubs missing nodes for the cool_drive `.glb`s; car shader (vertex-lit + matcap) | `tests/check_car_assets.gd`; visual motion never feeds back into physics |
| WP2.2 Input | Steering and throttle abstraction; `drag_control`; `gyro_control`; `throttle_input`; `keys_gamepad`; controls overlay (anchor ring, pedals, buttons, left-hand mirror); **web gyro investigation** (iOS Safari motion permission) | The spec's control tests: mapping, gyro sign in both orientations, anchor follow, keyboard ramp, four-layout equivalence |
| WP2.3 Cameras | `camera_rig.gd` with chase, far, hood and overhead; spring follow; FOV 62°→78°; distance pull-back; look-ahead; roll; shake API; reduced motion; cycling and saved choice | Spring stability; FOV mapping; reduced motion disables shake, roll and punch |
| WP2.4 **Track B: traffic core** | `traffic_sim` structure of arrays; `idm.gd`; `mobil.gd`; the player as participant; 120/30 Hz near/far ticks; telegraphing; no-ambush; the 6 m/s² clamp; brake-light thresholds; hesitant cancels; the 8 driver profiles and vehicle types as data | Rule checks (signal time, no-ambush, deceleration); determinism hash; no traffic-to-traffic collisions over a short soak; **tick-cost benchmark for 60 vehicles** (GDScript performance risk, see [§8](#8-risks)) |
| WP2.5 Track B: spawning | Spawn ahead (~750 m) and behind (~150 m, outside the frustum); despawn; the Flow `SpawnSource`; lane flow speeds; opposite-carriageway state (visual-only) | No spawn overlapping the player or the ghost zone; no pop-in (spawn beyond fog or behind the frustum) |

**Gate M2 ⏸:** lane-change, settling and stability tests green; **owner** plays the web build (and native for gyro) with drag and gyro in both throttle modes and all four cameras; the web-gyro decision is recorded (open question 4); playtest note written.

### Phase 3 — Traffic (M3) + Track C · ⏸ **PAUSE GATE**

| WP | Scope | Tests / acceptance |
| --- | --- | --- |
| WP3.1 Traffic view | Rendering pooled per model with per-instance color; emissive lights (brake, blinker, hazard, head, tail) and glow sprites; wheel spin, roll and pitch, lane-change yaw; sun rim light; opposite-carriageway visuals; placeholder traffic models | Draw calls stay in budget at 60 vehicles |
| WP3.2 Traffic sandbox | Free cam, time scale, pause and step, spawn controls; overlays (IDM gap and target speed, MOBIL incentives, blinker timers, predicted player occupancy, passability-path slot) | Opens and runs in the web build |
| WP3.3 Soak & metrics | Bot driver; **10,000 km soak** (sharded, soak tier); determinism trace (hash of all states every second); logged metrics with a ±15% baseline; traffic reactions to the player (high-beam flash, horn, brake tap, blind-spot horn) emitted as events | Zero impossible windows (pre-director definition), zero traffic collisions, zero rule violations |
| WP3.4 **Track C: scoring** | Pure `scoring.gd` rule set: pass, close pass, cut, thread, slipstream; speed and night factors; multiplier decay, shoulder penalty, minimum speed, hesitation and grace periods; chain and banking; boost meter; anti-exploit rules | **The spec's scoring suite:** every event, every anti-exploit rule, banking, every loss case |
| WP3.5 **Track C: sun, legs, hits** | Pure `sun_clock.gd` (sinking, ×3 when too slow, checkpoint lift + pace bonus, nudges, night, 6 s dawn); leg and checkpoint bookkeeping in `run.gd` (headless); road-space oriented-box collision with swept checks | Sun timing (5 min to sunset); lift never earlier than run start; collision boxes agree up to 350 km/h with no tunnelling at 120 Hz; the ghost-period and life-cap tests |

**Gate M3 ⏸:** soak, determinism and fairness tests green; **owner** does a 10-minute sandbox review (web) and confirms traffic reads as readable and alive; playtest note written.

### Phase 4 — Scoring and lives (M4)

| WP | Scope |
| --- | --- |
| WP4.1 Run loop | `game.gd` mode state machine (with per-mode HUD sections), `run.gd` wiring; first hit (deflection, −20% speed, 0.6 s wobble, 0.5× for 0.3 s, traffic swerve and hazards); ghost period; lives; damage look (hood smoke, flickering headlight) |
| WP4.2 Crash | Jolt `RigidBody3D` hand-off with a contact impulse; 0.25× for 2.5 s; orbit crash cam; surrounding traffic brakes; tap to skip; pooled bodies return to kinematic |
| WP4.3 HUD & theme | `ui/theme.tres` design system (chamfered `StyleBoxFlat`, neon edges, speed-tilt shader, Chakra Petch); full HUD layout; 4-line event stack; multiplier hue cycle and wobble; banking count-up; TOO SLOW bar; lives; boost meter; safe areas; labels update only on change |
| WP4.4 Screens | Countdown (gyro calibration), pause menu, results screen (all stats, PB comparison), retry within 2 s |
| WP4.5 Integration tests | End-to-end scripted bot runs through the event bus: every scoring event fires; anti-exploit rules hold in the full loop; the first hit leaves the car drivable above minimum speed within 1 s; boost hooked into physics |
| WP4.6 Draw-call budget | M3 frame with traffic measured 98 of 100 draw calls with dev overlays (~25). Merge the player car's surfaces (~15 → ~4); draw road + markings as one surface per chunk (road and world shaders are identical, ~12 → ~6); keep the gameplay HUD cheap. Target at most ~70 in gameplay with the real HUD. Plus a dev quality toggle (render scale, MSAA) for the owner's "a bit low res" note |
| WP4.7 Cockpit camera (D11) | Driver's-eye camera mode with a generic procedural cockpit (dash, pillars, roof edge, wheel turning with steer, simple gauges); car body hidden in that mode; same look on both renderers |
| WP6.6 Traffic speed variety (D15) | Fast "Racer" profile, wider speed spreads and mix, faster left lanes, traffic you can follow and overtake at 200+ km/h; soak and fairness green |
| WP4.8 Density (D11) | Fix the director's density shortfall around the player; raise late-leg density and the vehicle cap within the phone budget; soak and fairness still green |

**Gate M4 (continue):** the scoring suite passes; a full playable loop works in the web build.

### Phase 5 — Sun loop and legs (M5)

| WP | Scope |
| --- | --- |
| WP5.1 Sun gameplay | `sun_clock` drives the run and the sky; night ×2 on everything scored; dawn transition while play continues; HUD sun bar with checkpoint distance |
| WP5.2 Legs & checkpoints | Legs (~3.5 km); warning signs at 1 km and 500 m; the 5-step crossing sequence; leg bonuses (Clean, Pace, Threads, Heat); objectives; clean-leg life restore; non-blocking leg toast |
| WP5.3 Landmarks | Express toll gantry, suspension bridge, sign gantry, tunnel portal (placeholder builds) |
| WP5.4 Night lighting | Head and tail glow sprites, cone decals, street-lamp pools, the player's fake-light uniform, retro-reflective material; night keyframes tuned |

**Gate M5 (continue):** a headless scripted run cycles day → night → dawn correctly across legs; snaps show the sun bar and leg toasts reading clearly.

### Phase 6 — Director, biomes, journey (M6)

| WP | Scope |
| --- | --- |
| WP6.1 Passability | `passability.gd`: 10 Hz forward-sim over 8 s; lateral grid search using the vehicle's lane-change curve; re-roll up to 5 times, then remove the worst blocker; bot-driver tests |
| WP6.2 Director | Intensity waves (45–90 s cycles with a breather), difficulty by leg (density 8→16, aggressive share 5→20%, hesitant from leg 3), density cap after blind crests, the SetPiece and Daily `SpawnSource`s |
| WP6.3 Set pieces | All 8 set pieces with their warnings (signs, arrow board, brake-light ripple) |
| WP6.4 Biomes & forks | Biomes 2–6 (data, props, horizon sets, tints, lane counts); forks (road split, signs 1 km ahead, branch chosen by road side) |
| WP6.5 Coast & Journey | Coast finale (ocean opening, 3 s wide camera swing in a traffic-free breather, journey bonus); endless coastal highway; the Journey mode loop |

**Gate M6 (continue):** passability tests show zero impossible windows; a full journey trace shows every biome and set piece; snaps per biome.

### Phase 7 — Audio and feel (M7)

| WP | Scope |
| --- | --- |
| WP7.1 Engine & wind | RPM-stepped loops (on and off throttle) crossfaded with the gearbox; wind rising with speed; boost whoosh and intake roar |
| WP7.2 Pass & traffic audio | Doppler whoosh scaled by clearance, zip layer (close), thump (thread); horns, air-brake hiss, tire hum; tunnel reverb |
| WP7.3 Music & stingers | Buses (Master, Music, SFX, Engine, UI); stingers pitched by multiplier; banking chime; night low-pass and reverb; music-clock hook |
| WP7.4 Haptics & juice | `platform/haptics.gd` patterns; slow-motion service; particles (tire smoke, sparks, speed lines, glitter) clamped per tier; FOV punch; reduced motion |
| WP7.5 One-frame check | Automated test: every scoring event produces a sound, a haptic and a visual response in the same frame |

Audio comes from CC0 packs (logged) until the owner supplies licensed or recorded audio.

**Gate M7 (continue):** WP7.5 green; owner feel check on native (haptics).

### Phase 8 — Meta (M8)

| WP | Scope |
| --- | --- |
| WP8.1 Save & settings | Versioned `user://` save with migrations; every setting from the spec; first-run chooser and 20 s empty-road warm-up |
| WP8.2 Garage & progression | Turntable with the live sky palette; paint and rims; 8 roster slots; driver level; level and milestone unlocks |
| WP8.3 Achievements & leaderboards | About 25 achievements; `platform/leaderboards.gd` (Game Center, Play Games, no-op on web); boards: Journey (all-time and weekly), Daily, distance |
| WP8.4 Daily Drive | UTC-date seed; 20 Hz ghost record and playback; cross-platform determinism check (Linux headless vs web/wasm trace hash) |
| WP8.5 Title & menus | Attract camera; title, leaderboards and settings screens; 100%/125% text size |

**Gate M8 (continue):** a fresh install progresses to its first unlock; Daily Drive gives identical runs on two platforms for the same date.

### Phase 9 — Hardening and release (M9)

| WP | Scope |
| --- | --- |
| WP9.1 Governor & thermal | Adaptive governor (the 4 rungs, 10 s down, 60 s up, never above the user's tier, cooling icon); native thermal plugins (iOS `ProcessInfo.thermalState`, Android `PowerManager`) |
| WP9.2 Web polish | Load time and pack size; audio unlock on first gesture; web-gyro decision applied |
| WP9.3 Accessibility | Reduced motion everywhere; color-independence audit; text size |
| WP9.4 Store builds | TestFlight and Play internal configs, icons, splash (owner holds the signing keys) |
| WP9.5 Acceptance sweep | Every acceptance test in the spec, as a checklist, run and recorded |

**Gate M9:** the governor steps down and back up under a forced thermal state; every acceptance test passes.

### Parallel art track

| When | WP | Scope |
| --- | --- | --- |
| From Phase 1 | ART1 | Style guide sheet (~30-color palette, 256² atlas); farmland props, horizon cards |
| From Phase 2 | ART2 | `tools/blender/` batch scripts (normalize, decimate, flat-shade, bake or atlas, rename, export) and a Godot `EditorScenePostImport` (shaders by material name, collision box inset 8 cm, markers, LOD1) |
| From Phase 3 | ART3 | 14 traffic models (placeholder or CC0 first, in-house later) |
| From Phase 5 | ART4 | Landmarks and biome props for biomes 2–6 |
| Owner-led | ART5 | 8 in-house player cars (AI generators + Blender, done by the owner), then the cockpit camera once interiors exist |

## 8. Risks

| Risk | Mitigation |
| --- | --- |
| **GDScript performance:** 60 vehicles at 120 Hz, plus passability forward-sim, plus no allocations | Structure-of-arrays with Packed arrays; a tick-cost benchmark in WP2.4 before building on it. If the budget can't be met, **flag it**: GDExtension/C++ would be a spec change. |
| **Cross-platform determinism** (Daily Drive: "identical on two devices") | Sim math in 64-bit scalars; avoid platform-dependent transcendentals in hot paths or use our own approximations; test trace hashes Linux-headless vs web/wasm in CI |
| Web on iPhone Safari (WebGL 2, Compatibility renderer) performs or looks different from native Mobile | Every shader checked on both renderers from M1 (spec rule); thermal numbers only from native (D4) |
| Web gyro on iOS Safari (motion permission from a user gesture) | Investigated in WP2.2; if not reliable, gyro is native-only in v1 and hidden on web (spec fallback) |
| 10,000 km soak runtime | Headless sim well above real-time; far ticks at 30 Hz; sharded across processes and seeds; soak tier kept off the per-push CI |
| Merge conflicts with 5 agents | Frozen contracts, path ownership, orchestrator-owned shared files, auto-discovered tests, split tuning (D3) |
| Placeholder art drifts from the final look | Everything goes through the modular convention and project shaders, so swapping models never touches code |

## 9. Status tracker

Updated by the orchestrator at every merge.

| Phase | Milestone | Status | Gate |
| --- | --- | --- | --- |
| 0 | M0 Foundation | ✅ merged; owner device check folded into M1 | continue |
| 1 | M1 Road & look (+ Track A) | ✅ web playtest passed (owner); native thermal soak still open (D4) | ⏸ pause |
| 2 | M2 Car, controls, cameras (+ Track B) | ✅ owner playtests (controls revised: D9, D10) | ⏸ pause |
| 3 | M3 Traffic (+ Track C) | ✅ owner review passed ("traffic really good"); 10,024 km soak: 0 collisions and 0 rule violations; impossible windows 0 on 3 lanes (D12) | ⏸ pause |
| 4 | M4 Scoring & lives | ✅ WP4.1–4.7 merged: run loop, crash cinematic, HUD & theme, screens, integration suite (858 tests), draw calls 85 → 70 with dev overlays, cockpit camera (D11). WP4.8 density merged (D11) | continue |
| 5 | M5 Sun loop & legs | ✅ sun drives the run and sky, night ×2, dawn, legs + objectives + toast, landmarks + warning signs, night lighting + manual high beams (D8); M5 gate test green; WP5.5/5.6 follow-ups and HUD polish merged | continue |
| 6 | M6 Director, biomes, journey | ✅ director + set pieces, biomes, journey, D15/D17 fast traffic and racers, passability (D21), lane-drop safety (D20). Gate soak 2,016 km all-pieces with the passability bot: collisions, rule violations, off-road 0 on every lane count; traffic windows 0 on 2 and 4 lanes, 3 on 3 lanes (toll booths, the bot's own lane choice) → 0 in a 1,008 km re-run after the bot fix. Open: D12 two-lane slow wall (not seen in this soak), greedy passability paths, standstills beside fast lanes at canyon drops (~4 per 100 km) | continue |
| 7 | M7 Audio & feel | 🟨 WP7A audio (engine, wind, pass/traffic, music, stingers, buses) + WP7B haptics/juice merged; WP7.5 one-frame check green (every scoring event sounds, pulses and shows in its frame; slipstream has none per spec). WP7.6 running: one-shot SFX from OGG to WAV (each OGG voice costs ~0.6 ms decoder setup). Owner feel check on native pending | continue |
| 8 | M8 Meta | 🟨 WP8.5 title, attract drive and online hub; WP8.1 versioned save (migrations keep existing players' settings and bests), settings in 3 pages, first-run chooser + 20 s warm-up (D22–D25). WP8.2 garage (8 slots, 12 paints, 6 rims, turntable on the live sky), driver level and milestone unlocks (D26–D28; M8 soak: first unlock in 1–3 runs). WP8.3 25 achievements (toast, screen, platform mirror; D29). WP8.4 Daily Drive ghost (20 Hz, best per date, one-draw ghost car) + native-vs-wasm check (in web CI at 15 s). **M8 gate met:** native vs wasm Daily Drive bit-identical for 300 s with a script driver and a reacting bot (N8.2 DetMath + tier-independent sim horizon) | continue |
| 9 | M9 Hardening & release | 🟨 WP9.2 web polish: branded loading shell (first paint 10 s → 0.16 s), music in its own pack after the title (12.9 MiB to the title, −21 %), audio starts on the first gesture, versioned asset URLs + one stale-page reload; gyro stays on for web (owner iPhone check pending); next lever: a custom web template (the engine wasm is 59 % of the download). WP9.1 governor (4 rungs, thermal forcing via `?thermal=` / dev HUD, cooling icon; native thermal plugins written, untested on device; D30, D31). Owner on device: build/install the plugins, M9 governor check, D4 20-min soak. WP9.3 accessibility (D32; colour-independence fixes, text sweep incl. 4:3 tablet; open: warning tone/haptic for TOO SLOW, set-piece warning, shoulder penalty, HESITATED haptic — owner decision) WP9.5 acceptance sweep (docs/ACCEPTANCE.md: 205 rows, 134 ✅ / 40 ⚠️ / 8 ❌ / 18 📱 / 5 👤); ❌ being fixed in WP9.6: soak collision definition for crawling long vehicles, set pieces rarely reach the player in real journeys, four soak thresholds (bot fallback, cap binding, weaving density, runs to first unlock) | final |

## 10. Open items for the owner

**Deferred to the owner's playtest (2026-09-30; current behaviour stays):** O1 how racers get past the player (current weaving); O2 traffic spawn distance 800 vs 700 m (800 m, N8.2's sim horizon); O3 speed lines under reduced motion (on); O4 warning sound/haptic for TOO SLOW, set-piece warnings, shoulder penalty, HESITATED haptic (none). **Still open:** O5 web gyro on iPhone (on; native-only is a one-line switch); O6 cockpit camera improvements; O7 roadside props repeating per loop lap; O8 the D12 two-lane slow wall. The 📱 device checklist is in docs/ACCEPTANCE.md.

- **Cockpit camera** (D11): works, but the owner wants improvements at some point (feel and look). Per-car interiors come with ART5.

1. **Web playtest hosting:** GitHub Pages is enabled (owner, M1). Every push to this branch deploys the web build to `https://b3vet.github.io/westbound/`.
2. **Android:** no device testing for now (D5 stands). Presets and CI builds are kept working.
3. **iOS export:** handled by the owner when the time comes. Team ID and bundle ID are set locally, never committed.
4. **Spec open questions** (final car roster, music direction, two-way stretches, web gyro, cloud save) stay open. The web-gyro one gets answered at the M2 gate.
