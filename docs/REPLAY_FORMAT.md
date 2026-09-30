# Replays: the `.wbr` format and the verifier

WP N8.1, N8.2 (the input stream and re-simulation: [DETERMINISM.md](DETERMINISM.md)). A single-player run's replay: what the client records, the exact bytes, and how the headless verifier re-simulates (or, for an N8.1 replay, plays back) and judges it. Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Leaderboards (single-player runs, steps 3–5), Testing → Verifier, Tuning reference (30 Hz, 3 %). The upload API and the queue are in [`SERVER.md`](SERVER.md) → Replays and verification; the client side in [`NET_CLIENT.md`](NET_CLIENT.md) → Replays.

| File | Class | What it is |
| --- | --- | --- |
| `src/net/replay_file.gd` | `NetReplayFile` | The format: quantized columns, encode / decode, the header patch, the tuning hash, the traffic fingerprint |
| `src/net/replay_recorder.gd` | `NetReplayRecorder` | Records a Journey / Daily run (a child of `NetRunsClient`) |
| `tools/verifier/replay_verifier.gd` | `ReplayVerifier` | The verifier core: re-simulation from the inputs (N8.2) or kinematic playback on the real Run, physics limits, the verdict |
| `tools/verifier/verifier_limits.gd` | `VerifierLimits` | The car's measured capability (lateral speed and acceleration, yaw rate, longitudinal) |
| `tools/verifier/verify_replay.gd` | (a `--script`) | The command line the server runs |
| `tools/verifier/record_sample_replay.gd` | (a `--script`) | Records a real bot run headless (the server's end-to-end test, trying things by hand) |
| `westbound-server/crates/server/src/replays/format.rs` | `format::Header` | The server's header reader |

## What is recorded

`NetReplayRecorder` attaches to the Run on `Events.run_started` (the current scene, else the parent of the tree's `PlayerCar`) for Journey and Daily runs, never Loop practice. It is listen-only (run.gd has no hook): after every 120 Hz tick (`_physics_process` at priority 60, after the Run's 50; manual-tick tests call `capture()`), it reads the car and the run's counters.

- **Tick numbering.** k = 1 is the first RUNNING tick after GO. k is `RunStats.duration_s × 120` (RunStats observes exactly the RUNNING ticks); the run-ending tick (the second hit returns before RunStats) is the last k + 1, taken when the state is first CRASH.
- **Samples: 30 Hz.** The car's state after ticks k = 1, 5, 9, ... (`NetTuning.replay_sample_ticks` = 4): s, d, yaw (heading vs the road), v, v_lat; the inputs steer and throttle at that tick, **the largest brake** of the ticks since the previous sample (a tap between samples still fails a "no braking" objective on playback), and whether a boost was requested in them. Also sampled, with the tick before them: a **fork swap** (the road moved to the right branch: d jumps by the fork's shift), the **safety net** (`Run.dev_reset_car`) and the **last tick**.
- **Inputs (N8.2), every tick.** The car's steer, throttle, brake and boost request exactly as its physics took them: `PlayerCar.tick` quantizes the controller's values to multiples of 1e-4 (`VehicleInput.quantize`) before `VehiclePhysics.step`, so the wire integers are exact. One row per tick where any of them changed (they are piecewise constant). The ticks must follow one another; a missed capture drops the stream (the verifier then plays the samples back kinematically).
- **Exact events** from the per-tick state: boost on / off (the exact tick), the fork swap (with its shift), the reset, and once a second (`replay_fingerprint_ticks` = 120) the **traffic fingerprint**.
- **The event log** from `Events`, stamped with the last tick seen (a frame's granularity): `scored` (kind, points, multiplier, clearance), `hit` (source, lives left), `chain_banked`, `chain_lost`, `bonus_awarded`, `checkpoint_crossed`.
- **At run_over** (`finish(results, date)`): the header takes the claims (banked score, hits, distance, RUNNING ticks) and the UTC date the submission uses; the bytes go to `NetRunsClient`, which stores them until the receipt decides.

Per tick it allocates nothing (the columns are reserved for `replay_reserve_s` = 15 minutes and grow by doubling). Memory: 10 columns × 8 bytes × 30 Hz ≈ 8.6 MB per hour of driving.

## Bytes

Little-endian. A header the server reads without decompressing, then a gzip stream.

### Header

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | magic `WBR1` |
| 4 | 2 | version u16 = 1 |
| 6 | 2 | header length u16 = 77 + car length |
| 8 | 8 | **run id** i64. 0 while recording; the client writes the receipt's run id here before uploading (`NetReplayFile.patch_run_id`, Rust `format::patch_run_id`) |
| 16 | 8 | seed i64 (0 … 2^63 − 1) |
| 24 | 4 | client build u32 (`NetTuning.client_build`) |
| 28 | 4 | tuning hash u32 (below) |
| 32 | 1 | mode: 1 journey, 2 daily |
| 33 | 1 | compression: 1 gzip |
| 34 | 2 | physics tick rate u16 (120) |
| 36 | 2 | sample interval in ticks u16 (4) |
| 38 | 10 | date, ASCII `YYYY-MM-DD` (the submission's `date`) |
| 48 | 4 | RUNNING ticks u32 |
| 52 | 8 | claimed score i64 (the banked score) |
| 60 | 4 | claimed hits u32 |
| 64 | 4 | distance u32, mm |
| 68 | 4 | body length before compression u32 |
| 72 | 4 | payload length u32 (the gzip bytes; header + payload = the file) |
| 76 | 1 | car id length u8 (1–32) |
| 77 | n | car id, ASCII (`falcon_gt`) |
| 77 + n | … | payload: gzip (`PackedByteArray.compress(COMPRESSION_GZIP)`) of the body |

**Why gzip:** Godot's zstd and gzip are both in every export, the web included; gzip keeps the file readable with standard tools and any server language. **The tuning hash** is the first 4 bytes (little-endian) of SHA-256 over, for each simulation section of `Tuning` in order (`road`, `vehicle`, `traffic`, `director`, `passability`, `scoring`, `lives`, `sun`, `legs`, `progression`): the section name, then for each stored script property its name and `var_to_bytes(value)` (sub-resources recursively). A verifier with another hash cannot verify the replay (another build: build parity), which is an error, not a verdict.

### Body

Integers are varints: unsigned LEB128 (7 bits per byte, low first, high bit = more); signed values are zigzag-coded first, `(n << 1) ^ (n >> 63)`. A column is written in one of three ways:

- **raw:** each value as a varint;
- **Δ:** zigzag(x[i] − x[i−1]), with x[−1] = 0;
- **Δ²:** zigzag((x[i] − x[i−1]) − (x[i−1] − x[i−2])), with x[−1] = x[−2] = 0.

| Part | Content |
| --- | --- |
| samples | varint N, then N values of each column in this order: tick (Δ²), s (Δ²), d (Δ²), yaw (Δ²), v (Δ²), v_lat (Δ²), steer (Δ), throttle (Δ), brake (Δ), flags (raw) |
| string table | varint T, then T strings (varint byte length, UTF-8) |
| events | varint E, then E values of each column: tick (Δ), kind (raw), tag (raw: a string table index), points (zigzag), clearance (zigzag, mm; −1 = none), value (zigzag) |
| inputs (N8.2, optional) | present when bytes remain after the events: varint I (≥ 1), then I values of each column: tick (Δ², the first tick from which the row holds), steer (Δ²), throttle (Δ²), brake (Δ²), boost request (raw, 0 / 1). The first row is tick 1. **With inputs, the samples' steer, throttle and brake columns are written as zeros** (they compress to nothing) and rebuilt on decode from the stream: steer and throttle at the sample's tick, the largest brake of the ticks since the previous sample. A file without inputs is the N8.1 body byte for byte; the header version stays 1, so the server's header reader (`format.rs`) takes both |

**Quantization** (`wire = round(value × scale)`, finer than the protocol's: playback interpolates between samples and traffic reacts to the result):

| Value | Unit |
| --- | --- |
| s, d (road space, d + right) | 10 µm |
| yaw (heading vs the road, + right) | 1e-6 rad |
| v, v_lat | 0.1 mm/s |
| steer (−1…1), throttle, brake (0…1) | 1e-4 |
| clearance | 1 mm |
| multiplier | × 1000 |

**Sample flags:** 1 boost running after this tick · 2 a boost was requested in the window ending here · 4 the safety net put the car in a lane this tick · 8 a fork swap this tick · 16 the last sample.

**Event kinds:**

| Kind | Tag | Points | Value |
| --- | --- | --- | --- |
| 1 scored | `pass` / `close_pass` / `cut` / `thread` | points | multiplier × 1000 (clearance set) |
| 2 hit | source (`traffic`, `barrier`, `prop`) | — | lives left |
| 3 banked | reason | amount | banked total |
| 4 chain lost | reason | amount | — |
| 5 bonus | bonus kind | points | banked total |
| 6 checkpoint | — | — | leg index |
| 7 / 8 boost on / off | — | — | — (the exact tick) |
| 9 fork swap | — | — | the shift, 10 µm (d moved by −shift) |
| 10 reset | — | — | — |
| 11 traffic | — | — | the fingerprint (u32) |

**Traffic fingerprint** (`NetReplayFile.traffic_fingerprint`): `TraceHash` over the active count, the next vehicle id, and for each live slot in order its vehicle id, lane, target lane and lane-change state, masked to u32. It leaves positions out; a spawn, despawn or lane change that went another way shows.

### Sizes

| Run | Bytes | Per 10 minutes |
| --- | --- | --- |
| N8.1: five 4-minute weaving, boosting bot runs in real traffic (soak, no inputs) | 14–22 KB | 35–54 KB |
| N8.2: six 11-minute honest runs, the weaving bot and PassabilityDriver (both steer on every tick; 69k–79k input rows) | 41–88 KB | **36–78 KB** |
| N8.2 synthetic: 10 minutes of tilt steering as GyroControl makes it (a noisy reading per 60 Hz frame, filtered every tick: 22k input rows; fast tier) | 64 KB | 64 KB |
| N8.2 adversarial: fresh noise on every tick, unfiltered (no control produces it; soak, printed) | 151 KB | 151 KB |

The spec's budget is about 100 KB per 10 minutes. The largest shares are the smooth path columns (s, d, yaw, v_lat, about 17 KB each per 10 minutes in the worst case) and the steering input stream (1–1.5 bytes per changed tick compressed; touch and keys change it at most per frame or on a linear ramp, which costs nearly nothing).

## Verification

`ReplayVerifier.verify(host)` builds the real Run scene (`src/run/run.tscn`) under `host` with manual ticks, the replay's seed (or the server's `--seed`), mode and car (a Daily replay: its date, which must give that seed, N8.2), no crash cinematic, and presses GO.

**Re-simulation (N8.2; a replay with an input stream, the default).** The run keeps its own lives. A controller (`ReplayVerifier.ReplayInputs`) hands the car the recorded inputs, and each tick k is the real `Run.tick()`: the road ahead, the car (controller → quantize → `VehiclePhysics`), then forks, traffic with the player as participant, the director, lives and hits, scoring, the sun, legs and objectives, stats. After each tick the event buffer is read and cleared, and on every sample tick **the re-simulated state must equal the sample in wire units** (s, d, yaw, v, v_lat and the boost flag): otherwise `resim` violations and the verdict `path_mismatch`, with `resim_mismatch_at_s` and `resim_mismatches` in the result. The fork swaps, resets and boost edges must also be the recorded ones, the run must last to the last sample, and the input stream must start at tick 1, go forward and stay in range (else `malformed`). The physics limits below are checked on the samples as well. Because the simulation is bit-identical on every platform (DETERMINISM.md), an honest replay reproduces the client's run tick for tick: every event, every hit, the score. `result.playback` says `resim`.

**Kinematic playback (an N8.1 replay without inputs).** **Infinite lives** (the path goes on past the recorded crash so every hit counts; the last one ends it). Each RUNNING tick k, in `Run.tick`'s order:

1. `_road_ahead()`.
2. **The car's state from the samples** instead of `VehiclePhysics`: on a sample tick, the sample; between samples, s and d integrated like `VehiclePhysics.step` does (the speed before the tick along the heading after it, velocities interpolated between the samples, then corrected linearly to land exactly on the next sample; plain linear positions are tenths of a millimetre off mid-segment); yaw, v, v_lat and the inputs linear; the brake the window's largest; the boost from the exact edges, with the verifier's own boost meter (drain from the car's params, fill from the playback's scoring). A fork-swap tick gets its shift back (the fork code moves the car again); a reset tick restarts the hit sweep.
3. `Run._sim_tick(dt)`: forks, traffic with the player as participant, the director, lives and hit detection, scoring, the sun, legs and objectives, stats. Traffic reacts to the recorded path; every event and hit is recomputed by the real code.
4. The run's event buffer is read (hits, scored kinds) and cleared (no adapter drains it: nothing renders, `frame()` is never called).

At the end `scoring.notify_run_end` and the recomputed score is `scoring.banked()`.

**Physics limits** (between consecutive samples; skipped across a fork swap or reset):

| Check | Violation |
| --- | --- |
| v ≤ boosted top speed × (1 + `verify_speed_margin_pct` 2 %) | `speed` |
| Δs within `verify_path_tolerance_m` (0.25 m) of the recorded velocities' `(v cos yaw − v_lat sin yaw) / (1 − κ d)` × Δt (trapezoid) | `teleport` |
| Δd within 0.25 m of `(v sin yaw + v_lat cos yaw)` × Δt | `lateral_path` (an edited path that kept its speeds) |
| lateral speed Δd / Δt ≤ the car's × `verify_limit_factor` (1.2) | `lateral_speed` |
| lateral acceleration (change of the recorded lateral velocity) ≤ the car's × 1.2 | `lateral_accel` |
| yaw rate ≤ (the car's + κ v) × 1.2 | `yaw_rate` |
| speed change ≤ full throttle with boost, ≥ full brake, × 1.2 | `accel` |
| a boost starts with the meter at `boost_start_min_frac` or more; it never runs `verify_boost_meter_slack` (0.1) below empty | `boost_meter` |
| a reset only in the ghost, onto a lane centre, at half speed | `reset` |
| the playback swaps at a fork exactly where the replay did | `fork_swap` |
| the first sample is tick 1, ticks increase | `samples` |
| the header's seed is the run's (`--seed`); a Daily replay's date gives that seed (N8.2) | `seed` |
| N8.2 re-simulation: every sample equals the re-simulated state; fork swaps, resets and boost edges as recorded; the run lasts to the last sample | `resim` |
| N8.2: the input stream starts at tick 1, its ticks increase, values in range | `inputs` |

Within `verify_hit_grace_s` (0.5 s) of a hit, the lateral, yaw and speed-change limits are not judged (the deflection, the speed loss and the wobble are the run's). The car's capability comes from `VerifierLimits`: the car driven with its own `VehiclePhysics` on a straight road at every multiple of `verify_calibration_step_mps` (5 m/s) up to the boosted top speed, held at that speed through a full-lock turn and a full-lock reversal of `verify_calibration_s` (2.5 s) each; a query takes the larger of the two bins around the speed. Quantization steps are added to every bound.

**Verdict,** in this order (the first that applies is `reason`):

| `reason` | When |
| --- | --- |
| `seed_mismatch` | the header's seed is not the server's |
| `malformed` | sample ticks do not start at 1 or go backwards; the input stream is malformed (N8.2) |
| `path_mismatch` | N8.2: the re-simulated run left the recorded one (a `resim` violation: edited samples or inputs, or a determinism bug; `resim_mismatch_at_s` says where) |
| `physics` | any other violation above |
| `unreported_hits` | the playback found hits the client did not report: `max(playback hits no logged hit explains, playback hits − claimed hits)`. A logged hit explains a playback hit within `verify_hit_match_s` (0.35 s) or in the ghost after it |
| `score_mismatch` | \|recomputed − claimed\| / claimed > `verify_score_pct` (**3 %**, the spec) |
| `log_mismatch` | the playback reproduces less than `verify_log_match_pct` (80 %) of the client's scored events one to one (same kind within 0.35 s), once either side has 5 or more; or a logged hit the playback never finds (an honest replay finds every hit again; a replay of another world does not) |
| `accepted` | none of the above |

**Result JSON** (`--out`):

```json
{"accepted": true, "reason": "accepted", "recomputed_score": 183150, "claimed_score": 183200,
 "diff_pct": 0.027, "recomputed_hits": 1, "claimed_hits": 1, "logged_hits": 1, "unreported_hits": 0,
 "missing_hits": 0, "log_match_pct": 98.4, "violations": [], "violation_count": 0,
 "events": {"pass": {"logged": 212, "recomputed": 211}, "close_pass": {...}, "cut": {...}, "thread": {...}},
 "traffic_checks": 512, "traffic_matched": 512, "traffic_diverged_at_s": null,
 "run_id": "917", "seed": "2538700399935769545", "mode": "journey", "date": "2026-09-29",
 "car": "falcon_gt", "build": 42, "ticks": 61476, "samples": 15370, "elapsed_ms": 31200,
 "playback": "resim", "resim_mismatch_at_s": null, "resim_mismatches": 0}
```

`violations` lists up to 20 `{kind, tick, detail}`; `violation_count` is the total. `traffic_*` are diagnostics (not in the verdict): how many of the client's traffic fingerprints the playback matched, and when it first did not. Cannot verify (another build's tuning, an unknown car): `{"error": "tuning_mismatch: ..."}` and no `accepted`.

**Command line** (`tools/verifier/verify_replay.gd`, exit 0 accepted, 1 rejected, 2 bad arguments or an unreadable file, 3 cannot verify here):

```sh
tools/godot.sh --headless --path . --script res://tools/verifier/verify_replay.gd -- \
    --replay=/data/replays/917.wbr --out=/tmp/917.json \
    [--claimed-score=183200] [--claimed-hits=1] [--seed=2538700399935769545] [--server=off]
```

The claims and the seed are the server's (the run row); left out, the header's. `--server=off` keeps an exported build's `Net` autoload from signing in. A `--script` main loop is compiled before the autoloads exist, so the script loads the verifier at run time. Speed and memory (one core, this 4-core dev box under load): a 4-minute run verifies in 10–20 s including building the run (12–20 × real time), 25 s of driving in about 1.2 s; the process peaks at about 225 MB resident, well inside the spec's 1 GB.

## Honest replays (measured)

**N8.2: 100 % of honest replays accepted.** With the input stream the verifier re-simulates the run bit for bit (DETERMINISM.md → Replays). Six honest runs of 11 minutes (`soak_long_honest_runs_are_all_accepted`: the weaving, boosting bot and the reacting PassabilityDriver on seeds 20260929, 424242 and 9001, three cars): **6 of 6 accepted**, every sample exact, every traffic fingerprint matched, the recomputed score equal to the claim (0.000 %), 59–64 s to verify each (about 10× real time). The five N8.1 runs below are accepted too when re-simulated (`soak_five_honest_bot_runs`). A web (wasm) client's replay verified by the native verifier: DETERMINISM.md → Cross-platform.

The rest of this section is the N8.1 measurement, which still describes the **kinematic playback** (replays without inputs).

**The playback is exact:** fed the original's exact car state each tick, the playback reproduces every tick's traffic, scoring, lives, legs, sun, forks and stats hash for 4 minutes (`soak_exact_states_reproduce_long_runs`, 2 runs; `test_exact_states_reproduce_every_tick`, 25 s). Everything else about the run is rebuilt faithfully from the seed.

**The recorded path is not exact, and traffic eventually notices.** Five 4-minute runs of a weaving, boosting bot in real traffic (`soak_five_honest_bot_runs`, seeds 20260929, 424242, 9001, 31337, 123456789, the three cars):

| Seed | Traffic identical until | Recomputed / claimed | Diff | Playback hits (claimed 0) | Verdict |
| --- | --- | --- | --- | --- | --- |
| 20260929 | 20 s | 13,267 / 18,254 | 27.3 % | 4 | `unreported_hits` |
| 424242 | 116 s | 5,187 / 10,224 | 49.3 % | 4 | `unreported_hits` |
| 9001 | 140 s | 10,128 / 10,115 | 0.13 % | 1 | `unreported_hits` |
| 31337 | 39 s | 13,145 / 23,274 | 43.5 % | 4 | `unreported_hits` |
| 123456789 | 12 s | 534 / 10,693 | 95.0 % | 2 | `unreported_hits` |

No honest path broke a physics limit (0 violations in all five), so the limits and their 1.2 factor hold. Up to the divergence the playback matches the client event for event (0 % score diff, every fingerprint equal); short runs (the 25 s fast-tier run, the 20 s end-to-end run) are accepted with a 0 % diff. After it, the playback's traffic is another traffic: the recorded path drives through cars that are now somewhere else (false hits) and scores other passes. **Honest runs of a few minutes are rejected today (0 of 5).** The 3 % threshold stays (the spec's); there is nothing to fold in until the divergence is fixed, because before it the diff is 0 and after it it is noise.

**Why it diverges.** The interpolated path is off by about 0.1–0.2 mm mid-segment (gear-shift dips and steering lag inside the 33 ms between samples; quantization is 10 µm), and the traffic director makes knife-edge decisions on continuous inputs that include the player's state. The first run's divergence, traced tick by tick: the director's density controller (`waves.observe_player`, the density window around `player.s`) leaves `density_gain` different in the ninth digit; the next batch's planned positions move by micrometres; `keeps_live_gaps` compares a planned car's gap with `min_spacing` with no tolerance and the planned car sits exactly on that boundary, so one run spawns it and the other rejects it (`rejected_overlap`). Recording at 120 Hz with 1 µm (a 0.5 µm path error) diverged at the same tick. The same knife edges exist on any machine pair once the float bits differ (phone vs server), which the spec's premise ("because traffic reacts to the recorded path, tiny float differences don't compound") does not cover.

**What N8.2 did** (DETERMINISM.md): option 3 of N8.1's list. The controllers' outputs are quantized at the input boundary (1e-4, `VehicleInput.quantize`) and recorded on every tick they change; the verifier re-simulates from GO; the simulation's transcendentals are DetMath's, so phone, web and server agree to the bit. Options 1 and 2 (coarse director inputs, margins on the spawn guards) were not needed: an exact player makes every knife edge fall the same way. The spec change (inputs every tick instead of at 30 Hz, re-simulation instead of kinematic playback) is requested as deviation MP-D11. The server still runs no verifier in production (`replays.verifier_command` empty) until the owner deploys the sidecar (DETERMINISM.md → Verifier deploy).

## Tests

| File | Covers |
| --- | --- |
| `tests/net/test_replay_recorder.gd` | Round trip of every field (big seeds, negative values, tags, 2^53 − 1 points, the input stream), re-encoding byte-identical; the input stream an optional trailing section (header version 1), the samples' inputs rebuilt from it; the inputs quantized before physics on the replay's scale; the header layout at its offsets and the run id patch; refused files (short, truncated, magic, version, mode, corrupt gzip); 10 minutes of tilt steering with its input stream under 100 KB (soak: the adversarial noise case, printed); the recorder on a real Run (attaches on `run_started`, 30 Hz from tick 1, the brake window, the exact boost tick, a fingerprint a second, the header's seed, car, build, tuning hash, date, claims); Loop practice not recorded; the crash tick sampled last with the tick before it |
| `tests/verifier/test_verifier.gd` | Honest replays accepted, re-simulated (a 25 s weaving, boosting bot run: the exact score, every fingerprint, every sample; a run that rams traffic until its crash, both hits found); a Daily replay verified on its date's seed, another date `seed_mismatch`; a replay without inputs played kinematically; the kinematic exact-state playback reproduces every tick; tampered replays rejected: inflated score (`score_mismatch`), a 20 m teleport and a lane in a tenth of a second (`path_mismatch` re-simulated; `teleport` / `lateral_speed` kinematically), edited inputs (`path_mismatch`), an input out of range (`malformed`), removed hits (`unreported_hits`), a wrong seed (`seed_mismatch` with the server's seed, rejected by the evidence without it); unreadable files and another build's tuning are errors, not verdicts. Soak: six 11-minute honest runs (weaving bot and PassabilityDriver, three seeds) all accepted; the five N8.1 runs (kinematic numbers reported, all accepted re-simulated); exact-state playback of two 4-minute runs |
| `tests/verifier/passability_driver.gd` | `PassabilityDriver`: the reacting driver on Passability's path (N8.2) |
| `tests/verifier/verifier_harness.gd` | Recording real headless runs (the weaving bot, the rammer), playback, exact-state playback, `sim_hash` |
| `westbound-server/crates/server/tests/replays.rs` | The server side (SERVER.md → Replays and verification → Tests), and `end_to_end_with_the_godot_verifier` (`#[ignore]`: records a 20 s run with `record_sample_replay.gd`, submits it to a real server, uploads, the worker runs `verify_replay.gd`, the run becomes `verified`) |
