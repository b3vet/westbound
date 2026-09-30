# Determinism: identical runs on every platform and in the verifier (N8.2)

WP N8.2. Spec: Architecture rule 2 (deterministic by seed: "This powers Daily Drive, ghosts and reproducible bug reports"), Implementation milestones → **M8** ("Daily Drive gives identical runs on two devices for the same date"); multiplayer handoff → Leaderboards (single-player runs: the verifier), **N8** ("determinism audit of the single-player sim (seeded RNG only; no `pow`/`sin`/`cos`/`exp` in sim paths; fixed tick; no iteration-order dependence) ... honest replays 100 % accepted"). Before: [DAILY.md → Findings](DAILY.md) (WP8.4: native and wasm agree for 18–19 s, then the math libraries differ by an ulp), [QUALITY.md → Simulation safety](QUALITY.md) (WP9.1: the view distance fed the simulation), [REPLAY_FORMAT.md → Honest replays](REPLAY_FORMAT.md) (N8.1: honest replays diverged after 12–140 s).

| File | What |
| --- | --- |
| `src/core/det_math.gd` | `DetMath`: deterministic `sin`, `cos`, `sin_cos`, `tan`, `atan`, `atan2`, `asin`, `exp`, `log`, `pow`, `scalbn` |
| `westbound-server/crates/sim/src/detmath.rs` | The Rust port, bit for bit (`sim::detmath`) |
| `westbound-server/crates/sim/vectors/detmath.json` | 3,504 cases (edge cases, branch boundaries, seeded inputs), written by `tools/server_data/export_sim_data.gd` (`--only=detmath`), checked by both languages |
| `tools/server_data/det_math_vectors.gd` | `DetMathVectors`: the cases |
| `tools/lint` WB105 | The platform math library in simulation code is an error (docs/TOOLS.md) |
| `RoadTuning.sim_horizon_m` | The simulation's view of the road ahead (800 m), never the quality tier's view distance |
| `VehicleInput.quantize()` | The car's inputs as multiples of 1e-4 before physics: what a replay records |
| `src/net/replay_file.gd`, `replay_recorder.gd` | The replay's input stream (REPLAY_FORMAT.md) |
| `tools/verifier/replay_verifier.gd` | Re-simulation from the input stream |
| `tools/verifier/export_verifier.sh`, `westbound-server/verifier/` | The verifier's export, Docker image and compose override |
| `tools/determinism/compare.sh --replay`, `tick_cost.gd` | Cross-platform replays; the tick cost measurement |

## What makes two runs identical

Same seed + same inputs = same run, on any machine, to the bit:

1. **A fixed tick.** The simulation runs per 120 Hz tick with a fixed `dt`; frames never drive it (`Run.frame()` every 1, 2 or 4 ticks gives the same trace).
2. **Seeded randomness.** `Rng` streams (PCG32, integer-exact) derived from the run seed; WB102.
3. **Correctly rounded arithmetic only.** GDScript evaluates every `+ − × ÷` as its own IEEE-754 double operation (the VM calls one evaluator per operator, so nothing can be fused), and `sqrt`, `floor`, `round`, comparisons and int conversions are exact everywhere. The transcendentals are not: glibc, Emscripten's musl, Apple's and Android's libm round `sin`, `cos`, `tan`, `asin`, `atan`, `atan2`, `exp` and `pow` differently in the last bit (the `DT libm` probe below). **Every simulation path calls `DetMath` instead** (below), enforced by WB105.
4. **No fused multiply-add in Godot's builtins.** `lerpf`, `move_toward`, `smoothstep`, `snappedf` and friends are C++ inside the engine; on ARM a compiler that contracts `a + (b − a) t` into an FMA would round differently from x86-64 and wasm. The official 4.7 templates are built without contraction: `llvm-objdump -d` counts 135 `fmadd`/`fmsub` in the whole 71 MB Android arm64 `libgodot_android.so`, 110 in the 188 MB iOS `libgodot.a` and 0 in the Linux arm64 template (a contracting build has tens of thousands). Re-check with a new engine version.
5. **Inputs on a grid.** `PlayerCar.tick` quantizes the controller's steer, throttle and brake to multiples of 1e-4 (`VehicleInput.quantize`) before physics. The replay records exactly those values (REPLAY_FORMAT.md → Inputs), so the verifier's car gets the same inputs bit for bit.
6. **No device setting in the simulation.** The quality tier's view distance is rendering only; the simulation reads `RoadTuning.sim_horizon_m` (QUALITY.md → Simulation safety).

Iteration order: the simulation's containers are structure-of-arrays (`Packed*Array`) walked in slot order; no simulation path iterates a Dictionary. Time: no `Time`/`OS` clock in simulation code (WB102). The N8.1 exact-state check still holds: fed the original's exact car states, a playback reproduces every tick's traffic, scoring, lives, legs, sun, forks and stats for minutes.

## DetMath

fdlibm's algorithms and coefficients (the musl kernels), with the bit tricks replaced by comparisons against constants, so they need only correctly rounded operations: Cody-Waite reduction by π/2 in three 33-bit parts (always all three rounds), the sine, cosine and tangent kernels, the atan argument reduction with its four breakpoints, `exp` with `k ln 2` reduction and the Remez rational, `log` with a binary search for the exponent in an exact table of powers of two, and `scalbn` by exact powers of two (musl's steps). `asin(x) = atan2(x, √((1 − x)(1 + x)))`; `pow` squares for integer exponents (|y| ≤ 1024), takes `√` for y = ½, else `exp(y log x)`. A negative zero is treated as zero. No `fma` (neither GDScript nor the port uses one).

**Two GDScript traps found on the way** (both handled in `det_math.gd`, worth knowing elsewhere):

- **Godot's float literal parser is not correctly rounded.** 17 of fdlibm's 87 constants came out 1 ulp off; literals below about 1e-307 become 0, and `-0.0` becomes `0.0`. Every DetMath constant is therefore written as an integer mantissa times exact powers of two (`7074237752028440 * TWO_M52 / 2` for π/4), with the decimal value and the IEEE bits in a comment; `detmath.rs` uses the bits (`f64::from_bits`).
- **Inside a class, an unqualified `atan(...)` is Godot's global function**, not the class's own static `atan`. DetMath calls itself as `DetMath.atan(...)`.

Accuracy against this machine's glibc (`tests/unit/test_det_math.gd`, 20,000 inputs each):

| Function | Range | Max error vs libm |
| --- | --- | --- |
| `sin`, `cos` | [−4, 4]; ±1e-6 … 1e4 | 1 ulp |
| `tan` | [−1.5, 1.5]; wide | 2 ulp |
| `atan` | ±1e-8 … 1e8 | 1 ulp |
| `atan2` | both ±1e-3 … 1e3 | 1 ulp |
| `asin` | [−1, 1] | 2 ulp |
| `exp` | [−740, 705] | 1 ulp |
| `log` | 1e-300 … 1e300; [0.5, 2] | 1 ulp |
| `pow` | x 0.05…3, y −4…4 | 12 ulp (≈ 1 ulp per unit of \|y log x\|; load time only) |

sin, cos and tan are accurate for |x| < 2^20·π/2; beyond that the reduction loses bits but stays deterministic. **Parity:** the GDScript and Rust ports agree on all 3,504 vector cases bit for bit (a NaN matches any NaN), and `sin_cos` equals (`sin`, `cos`).

**Cost** (GDScript, this 4-core dev box, per call in a loop): `sin` 0.28 µs, `sin_cos` 0.66 µs (both values), `exp` 0.51 µs, `atan2` 0.3–0.7 µs, `tan` 0.53 µs; the libm builtin is 0.04 µs. The per-tick sites are few (below), so the whole tick barely moves (Cost).

### Where it replaced the platform library

| Site | Before | Now |
| --- | --- | --- |
| `VehiclePhysics.step` | `cos`/`sin(yaw)` twice, `exp(−dt / yaw_lag)`, `exp(−dt · grip rate)` | `DetMath.sin_cos` twice, `DetMath.exp`; the grip decay is constant per `dt`: `VehicleParams.lateral_grip_decay(dt)` (cached, DetMath) |
| `VehiclePhysics.steer_yaw_rate` | `tan(steer_angle)` | `DetMath.tan` |
| `VehiclePhysics.slip_angle` | `atan2` | `DetMath.atan2` (the capability table's peak slip) |
| `VehiclePhysics.surface_pitch` | `atan(grade)` | unchanged, `allow-libm`: the body's rendered pitch, never fed back |
| `VehicleParams.build` | `tan` (slip cap), `pow` (gear ratios), `sin`/`cos` (the lane-change capability table: `cap_time_s`, which WP8.4 found differing), `atan` (`predicted_brake_time`) | DetMath |
| `Lives` | `sin` (first-hit wobble), `atan2` (heading kick) | DetMath |
| `HitDetection.step`, `sweep_static_box` | `cos`/`sin(player yaw)`; per nearby car `atan2(v_lat, v)` then `cos`/`sin` | `DetMath.sin_cos` once; a car's heading as its velocity direction `(v, v_lat) / √(v² + v_lat²)`: no transcendental at all |
| `TrafficSim._read_player` | `cos`/`sin(player yaw)` | `DetMath.sin_cos` |
| `Scoring.step`, `RoadHull` | `atan2` per overlapping car, then `cos`/`sin` of both headings in `RoadHull.clearance` | the player's `DetMath.sin_cos` once per tick; a car's heading as its velocity direction; new `RoadHull.clearance_cs` takes (cos, sin); `clearance(yaw)` uses DetMath |
| `RunFinale` hold driver | `asin` | `DetMath.asin` |
| `SandboxBot` (the determinism check's bot, the sandbox) | `asin` | `DetMath.asin` |
| `MobilProbe` (sandbox readout) | `cos`/`sin` | `DetMath.sin_cos` (reads what the sim reads) |
| `ReplayVerifier`, `VerifierLimits` | `cos`/`sin` | DetMath (the same verdict on any machine) |
| Road generation, forks' world frame, loop world positions, `RunForks` branch origin | `sin`/`cos` of headings | unchanged, `allow-libm`: world positions (rendering). The road's s/d table (curvature, lanes, features) never reads them |
| `LoopGen` closure solve | `sin`/`cos` | unchanged, `allow-libm` (open item below) |
| `src/net/` (network traffic, remote players) | | not covered: follows the server's authority, never replayed |

Rust: `sim::traffic::sim::PlayerInput::from_vehicle` (the player's velocity), `sim::scoring::hull` (`clearance`, new `clearance_cs`, `penetration`) and `sim::scoring::rules` (the player's heading once per tick, a car's from its velocity) use `sim::detmath` the same way. The traffic traces did not change (their scripted players drive at yaw 0); the scoring vectors were regenerated, and `scoring_hull.json` (2,000 pairs) and `player_velocity.json` are now bit-exact (they were within 1e-12). `cargo test -p sim` (parity, scoring parity, detmath) passes.

## Tier-independent simulation

WP9.1's three couplings (spawn distance, leg planner horizon, fork candidates) read `RoadTuning.sim_horizon_m` = 800 m (the high tier's view distance; every tier's must be ≤ it, fairness rule 5). The same Daily run at 500 m and 800 m view distance is bit-identical (`tests/run/test_sim_horizon.gd`). `QualityTuning.governor_view_distance_between_runs` is now **false**: the governor's view-distance rung applies live; `tests/platform/test_governor_run.gd` walks the real run through all four rungs and back with the rung live, and the trace and the planner horizon are an ungoverned run's (details: QUALITY.md → Simulation safety).

## Replays: re-simulation instead of playback

N8.1's verifier played the recorded 30 Hz path back kinematically; the path is interpolated between samples, 0.1–0.2 mm off mid-segment, and the director's knife-edge decisions flipped on it (REPLAY_FORMAT.md). With the simulation bit-identical everywhere, N8.2 records the car's exact inputs instead and **re-simulates**: the verifier drives the real `Run.tick` (controller → `VehiclePhysics` → traffic, director, lives, hits, scoring, sun, legs, stats) from GO with the recorded inputs and the run's own lives, and every 30 Hz sample must equal the re-simulated state in wire units, exactly (`path_mismatch` otherwise). The traffic sees the client's car to the bit, so every knife edge falls the same way; nothing in the director needed to change. The kinematic playback stays for replays without inputs (an N8.1 client). This is a spec change (inputs every tick, the verifier re-simulating instead of "playing the recorded path back kinematically"): **requested as deviation MP-D11** (handoff).

Honest runs (`soak_long_honest_runs_are_all_accepted`, verified on this machine; each run ends at its crash or at 11 minutes):

| Driver | Seed | Car | Driven | Hits | Input rows | Replay | Per 10 min | Verdict | Score (recomputed = claimed) | Verify |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| weaving, boosting bot | 20260929 | falcon_gt | 639 s (crash) | 2 | 76,395 | 86.9 KB | 79.7 KB | accepted | 51,762 | 66 s |
| PassabilityDriver | 20260929 | night_viper | 660 s | 0 | 79,053 | 86.0 KB | 76.4 KB | accepted | 54,757 | 63 s |
| weaving, boosting bot | 424242 | night_viper | 660 s | 0 | 77,912 | 97.3 KB | 86.4 KB | accepted | 49,327 | 58 s |
| PassabilityDriver | 424242 | brute_v8 | 660 s | 0 | 35,783 | 42.3 KB | 37.6 KB | accepted | 51,977 | 64 s |
| weaving, boosting bot | 9001 | brute_v8 | 660 s | 0 | 44,715 | 65.1 KB | 57.8 KB | accepted | 43,776 | 63 s |
| PassabilityDriver | 9001 | falcon_gt | 660 s | 0 | 79,200 | 77.3 KB | 68.6 KB | accepted | 45,960 | 63 s |

**6 of 6 honest runs accepted** (N8.1: 0 of 5), every sample re-simulated exactly, every traffic fingerprint matched, the score exactly the client's. `PassabilityDriver` (`tests/verifier/passability_driver.gd`) is the reacting driver: every 0.5 s it runs `Passability.check_player` from the car's exact state, takes the path toward a random preferred lane and steers the real car along it (SandboxBot's cascade), so a 1-ulp difference anywhere would flip its decisions within seconds. The five N8.1 soak runs (`soak_five_honest_bot_runs`) are also all accepted re-simulated. Tampering: edited samples (teleport, lane jump) and edited inputs are `path_mismatch`; inputs out of range `malformed`; the kinematic playback still catches the teleport and the lateral speed by its physics limits. A Daily replay is now verified on its own date's seed (the N8.1 verifier left `daily_date` empty, so a Daily replay would have been re-run on the verifier's today); a date that does not give the run's seed is `seed_mismatch`.

## Cross-platform (native vs wasm)

`tools/determinism/compare.sh --seconds=300` (Linux x86-64 headless debug build vs the web release build in headless Chromium, Emscripten 4.0.20; date 2026-09-30, seed 2754025057311364035, Falcon GT):

| Driver | Result | WP8.4 before |
| --- | --- | --- |
| `script` (open-loop inputs) | **IDENTICAL, 300 of 300 s** bit for bit (score 17,088, 64 hits, 27 cars at 300 s) | 18 s, then the car's bits drifted |
| `bot` (SandboxBot, closed loop) | RESULT_BOT | 19 s, traffic another traffic from 26 s |
| `bot --replay` (each side records its replay; the **native verifier re-simulates the web client's replay**) | RESULT_REPLAY | (no replays) |

The `DT libm` probe still differs on 8 of 10 functions (the platform libraries are what they were); the new `DT detmath` probe is identical on all 10, and the car's `VehicleParams` are identical (46 of 46; `cap_time_s` differed before). Wall time: 4 min 8 s for the 300 s script run without the export on a loaded 4-core box (load 7–8); CI_TIMING.

## Cost

Tick cost before and after, this dev box (4 cores shared with other work: medians of repeated runs, noisy):

COST_TABLE

## Verifier deploy

The verifier is the game's own headless build (build parity): the Godot Linux release template plus this build's pack, exported with a verifier preset, run by `westbound-server verify-worker` in a sidecar container. Nothing here is enabled in production.

1. **Export preset** (requested, `export_presets.cfg` is orchestrator-owned; the diff is in the handoff): `Verifier (Linux headless)`, platform Linux x86_64, every resource plus `tools/verifier/*` (the other presets exclude all of `tools/`), no tests, docs or dev tools, pack separate (`binary_format/embed_pck=false`).
2. **`tools/verifier/export_verifier.sh`**: exports into `build/verifier/` as `westbound` (the template) and `<client_build>.pck` (`NetTuning.client_build`: the server command's `{build}`), then records a sample replay with the editor binary and verifies it with the exported binary and pack exactly as the worker will (fresh `HOME`, `nice -n 10`): SMOKE_RESULT.
3. **`westbound-server/verifier/Dockerfile`**: `debian:bookworm-slim` (glibc, coreutils' `nice`, CA certificates) + the `westbound-server` binary copied from the server image of the same commit + `build/verifier/`. Entrypoint `westbound-server verify-worker`; `WB_REPLAYS__VERIFIER_COMMAND=nice,-n,10,/verifier/westbound,--headless,--main-pack,/verifier/{build}.pck,--script,res://tools/verifier/verify_replay.gd,--,--server=off,...`; `HOME=/home/verifier` (Godot's user dir; nothing is saved), non-root 65532. DOCKER_RESULT
4. **`westbound-server/verifier/docker-compose.verifier.yml`**: an override that adds the `westbound-verifier` service on the server's `/data` volume with `mem_limit: 1g`, `memswap_limit: 1g`, `cpus: 1` (the spec's budget: one job at a time, `nice 10`, 1 GB) and the same auth secrets (the config loader validates them), and turns the server's own worker off (`WB_REPLAYS__WORKER_ENABLED=false`).
5. **CI** (requested workflow change, handoff): after the server image is pushed, a `verifier-image` job installs Godot and the Linux templates, runs `tools/verifier/export_verifier.sh`, and builds and pushes `ghcr.io/<owner>/westbound-verifier:{edge,<branch>-<sha>}` with `--build-arg SERVER_IMAGE=<the image just pushed>` and `-f westbound-server/verifier/Dockerfile build/verifier`.

**Enabling it in production** (owner): deploy the compose override in Coolify next to the server (same project and volume), with the same `WB_AUTH__*` secrets; the server then leaves the queue to the sidecar. The backlog of stored replays is verified oldest first. Replays recorded by N8.1 clients (no input stream) fall back to the kinematic playback and may be rejected when their traffic diverges: set `runs.supported_builds` to the N8.2 build(s) first, or requeue only N8.2 replays (`admin replay-requeue`). Keep one pack per supported client build in the image.

## Open items

- **Loop map generation** (`LoopGen`'s closure solve) still uses the platform `sin`/`cos`: the client regenerates `loop_v1` at run time, so a web client's loop geometry may differ from the exported file in the last bit (curvature included). Loop runs are multiplayer, server-authoritative and never replayed, but the map hash is of the exported file. Moving LoopGen to DetMath changes `loop_v1.json` and its hash (a new map version for the server): a follow-up with the loop's owner.
- **The server's claim checks** (`crates/server/src/rooms/car_history.rs`: a traffic car's heading by `f64::atan2`) are within tolerance of the client's (±0.35 m), not bit-exact; they could use `sim::detmath` and the velocity-direction form like the client (server crate, not this WP).
- **Phones are not measured.** iOS and Android are expected to match (no FMA contraction in the templates, DetMath everywhere in the simulation), but no device run was compared. The `DT detmath` line of a device's determinism check (`?determinism=daily` also works in a native build with `--determinism=daily`) answers it.
- The N8.1 knife edges (the director's density controller, `keeps_live_gaps` on its boundary) are unchanged: exact re-simulation makes them fall the same way; the kinematic fallback still diverges on them.
