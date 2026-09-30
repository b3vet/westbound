# Daily Drive: ghost and cross-platform determinism (WP8.4)

Spec: Core loop → **Modes at launch** ("Daily Drive: the seed is a hash of the UTC date, so route, forks, traffic and set pieces are the same for everyone that day. Unlimited attempts; the best score counts on the daily leaderboard. Your best daily run is recorded and shown as a translucent ghost car on later attempts (the car's `s`, `d` and heading sampled at 20 Hz)"), Architecture rule 2 (deterministic by seed: "This powers Daily Drive, ghosts and reproducible bug reports"), **Save data** ("Daily Drive ghosts"), Implementation milestones → **M8** ("Daily Drive gives identical runs on two devices for the same date"). Plan: WP8.4, gate M8, risk "cross-platform determinism" (§8). Save layout: [SAVE.md](SAVE.md). The replay it does not reuse: [REPLAY_FORMAT.md](REPLAY_FORMAT.md).

| File | Class | Role |
| --- | --- | --- |
| `src/meta/daily/daily_drive.gd` | `DailyDrive` (Node, `Run.daily`) | The glue on the run: records, keeps the day's best, plays it back |
| `src/meta/daily/daily_ghost.gd` | `DailyGhost` | The ghost file (`.ghost`): header, 20 Hz columns, forks |
| `src/meta/daily/daily_ghost_recorder.gd` | `DailyGhostRecorder` (pure, `# lint: sim`) | 20 Hz sampling, jumps, the final sample |
| `src/meta/daily/daily_ghost_playback.gd` | `DailyGhostPlayback` (pure, `# lint: sim`) | The pose at any tick, in road space |
| `src/meta/daily/daily_ghost_store.gd` | `DailyGhostStore` | `user://daily/<date>.ghost`, the index in `Save.section("daily")`, pruning |
| `src/meta/daily/daily_tuning.gd`, `data/tuning/daily.tres` | `DailyTuning` | Ghost flag, rate, retention, view window; the check's run |
| `src/world/ghost/ghost_car.gd`, `ghost_car.gdshader`, `ghost_car.tres` | `GhostCar` | The translucent car: one merged surface, one draw |
| `src/world/ghost/dev/ghost_preview.tscn` | | Snap wrapper (a Daily run with a ghost beside the player) |
| `src/meta/daily/daily_trace.gd`, `daily_trace_node.gd`, `daily_trace.tscn`, `daily_script_driver.gd` | `DailyTrace`, `DailyTraceNode`, `DailyScriptDriver` | The determinism check's scripted run (native and web) |
| `tools/determinism/daily_trace.gd`, `compare.mjs`, `compare.sh` | | The native runner, the comparison, the whole check |

## The date and the seed

`Run.daily_date` ("YYYY-MM-DD", empty = today's UTC date) fixes `Run.active_daily_date` when a Daily Drive starts (`start_mode`, or a `?mode=daily` boot); the seed is `Run.daily_seed_for(date)` = `Rng.daily_seed(y, m, d)` (unchanged from WP8.5). RETRY keeps the date and the seed, so a session that crosses UTC midnight keeps playing the day it started. No boot parameter sets the game's date (a player must not practise tomorrow's route); only tools and tests set `daily_date` on their own runs. (The web check page, `?determinism=daily&date=`, does drive any date with a bot and ships in the web build; gating it out of release builds is an orchestrator call.)

## Recording

**Decision: its own 20 Hz recorder, not the N8.1 replay.** The replay recorder (`NetReplayRecorder`, 30 Hz) exists only as a child of the online runs client, so it records nothing with `?server=off`, offline or in a build without the server; it keeps inputs, events and traffic fingerprints the ghost does not need, and its file is deleted once uploaded. The ghost needs positions at the spec's 20 Hz plus the brake and headlight flags, per date, kept on the device. So `DailyGhostRecorder` samples the car state the same way (RUNNING tick k = 1, 1 + n, …, n = `tick_hz / ghost_sample_hz` = 6; jumps sampled with the tick before them; the last tick as the FINAL sample) and `DailyGhost` reuses the replay's column coding (`NetReplayFile.encode_columns` / `decode_columns`, added for this) and its gzip. A 10-minute ghost is about 30 KB.

`DailyDrive.after_tick(true)` (from `Run.tick`, after each RUNNING tick) feeds it: `s, d, yaw` (heading vs the road), `v`, and flags `BRAKE` (the car's brake lights, `CarVisual.brake_lights_on`), `LIGHTS` (the run's headlights), `BOOST`; a fork resolved this tick (`RunForks.resolved_count` changed) adds a fork row (tick, index, side) and, for the right branch, `FORK_SWAP` (d jumps by the fork's shift); the safety net's reset adds `RESET`. Allocation-free within the reserve (`ghost_reserve_s` = 15 min, then the columns double).

## Ghost file and storage

`DailyGhost` layout (little-endian): `"WBG1"`, u16 version, u16 header length, s64 seed, s64 banked score, u32 RUNNING ticks, u16 tick rate, u16 sample ticks, the date (10 ASCII bytes), u32 body bytes, u32 gzip bytes, u8 + the car id; then gzip(u32 sample block length, the sample block (tick, s, d, yaw, v delta-of-delta; flags raw), the fork block (tick delta; index, side raw)). Quantized when appended: s, d 1 mm, yaw 1e-4 rad, v 1 cm/s. `peek()` reads the header only.

`DailyGhostStore` (docs/SAVE.md: ghosts are their own files, only the index in `daily`):

- **Files:** `user://daily/<date>.ghost`, written as `.tmp`, read back, renamed over the old one (removed first where rename cannot overwrite).
- **Index:** `Save.section("daily").ghosts = {date: {score, ticks, car, bytes}}`; written with the save (`Save.request_save()`; `Garage.award_run` writes the save at once right after).
- **Best per date:** at run end (`Run._show_results` → `DailyDrive.on_run_over`, only when the run records bests and the save is persistent) the run's ghost replaces the date's only when its banked score is higher. A run the first-run warm-up touched is never kept (Daily never warms up anyway).
- **Pruning:** every offer keeps today's date and the `ghost_keep_days − 1` days before it (2 = today and yesterday: a retry after midnight still plays yesterday's route); older dates, future dates (a wrong clock) and stray files are deleted; a kept file the index lost is adopted from its header; a missing or damaged file drops its entry.
- **Web:** `user://` is IndexedDB there; the same close-then-rename pattern as `SaveStore` (SAVE.md → Web).

## Playback

On every Daily run start (`DailyDrive.on_run_started`, from `Run._start_run`), the date's ghost is loaded (if `ghost_enabled` and its seed is the run's) and plays from GO on the **playback clock**: ticks since GO, RUNNING and then CRASH (the ghost keeps driving through the crash cinematic). Other modes turn it off.

- **Road space** (`DailyGhostPlayback.pose_into(k)`): linear between the 20 Hz samples; before the first sample it waits at the start (it overlaps the player on the grid); after the last one it is gone; never interpolated into a `FORK_SWAP` / `RESET` sample (it holds the tick before until the jump). Cursors make forward playback O(1); a retry rewinds.
- **Forks** (`DailyDrive.path_for`): the ghost's route is its fork rows. Where it matches the player's choices it drives on the player's road; at the fork the player has not reached yet, a ghost past the split on the left drives on the main road (the left branch until the pick) and on the right on the candidate path (`RunForks.candidate`, once made); a ghost on a branch the player did not take, or beyond the next unresolved split, is hidden. A fork the player took to the right that the ghost has not reached yet moved the road's d frame, so its d is shifted by that fork's shift.
- **Render space:** within `ghost_view_behind_m` / `ghost_view_ahead_m` of the player and inside the road's generated table, the pose is placed like the player's car (`RoadSample.local_point`, road heading + yaw, surface pitch) against the floating origin, at frame rate (`DailyDrive.update_view` from `Run.frame`). Brake and headlamps from the sample's flags.
- **No collisions, no scoring:** the ghost is never in the traffic state, hit detection or scoring; `test_the_ghost_changes_nothing_in_the_run` checks the run's trace hash is the same with and without it.
- **Toggle:** the spec lists no ghost setting, so it is `DailyTuning.ghost_enabled` (on); off, nothing is loaded or drawn.
- **Server ghosts:** downloading the day's top ghost would need a ghost API on the N7 boards (none exists); not done here, no server work.

## Ghost car

`GhostCar` merges the car's model (CarModel convention: body, wheels, head/tail and brake lamps; not the interior, markers, damage, blinkers) into **one surface** (lamp class in `UV.x`, the lamp's color in `COLOR`), cached per car and reused for every retry: one `MeshInstance3D`, **one draw**, none while hidden, no shadow. `ghost_car.gdshader`: unlit render mode, vertex-lit by the one sun light (`wb_light`), a pale tint partly self-lit, a view fresnel rim, alpha-blended with `depth_draw_always` (the nearest faces win: no inside showing), the world's fog (colour and fade-out), thinner within 5–14 m of the camera (a ghost on top of the player's car stays out of the way), lamps lit from the flags. Linear math through `wb_output()`; on Compatibility the alpha gets the fog cards' lift (blending in sRGB space). Parameters in `ghost_car.tres`.

```
tools/snap.sh src/world/ghost/dev/ghost_preview.tscn --renderer=both --sweep=sky_t:0.3,0.8
```

## Determinism check

The same scripted Daily run natively (Linux headless) and in the web build (wasm), with a trace line per simulated second, compared:

```
tools/determinism/compare.sh [--date=2026-09-30] [--seconds=60] [--driver=script|bot] [--no-export] [--detail]
# pieces:
tools/godot.sh --headless --path . --script res://tools/determinism/daily_trace.gd -- --date=2026-09-30 --seconds=60 --out=native.log
node tools/web_smoke/smoke.mjs --query "determinism=daily&date=2026-09-30&seconds=60" --wait-for "^DT done" --console-out web.log
node tools/determinism/compare.mjs native.log web.log
```

- **The run** (`DailyTrace`): the real Run scene, Daily mode on the date, car 0, infinite lives (so it lasts), no crash cinematic, nothing saved, GO at once, `Run.frame()` every 2 ticks as at 60 fps. The view distance is pinned to the default tier's (see Findings, 3). Driver `script` (default, `DailyScriptDriver`): open-loop inputs that depend only on the tick count (a lane change every 4 s, a brake tap every 11 s, full throttle): the determinism contract's "same inputs". Driver `bot`: the weaving `SandboxBot` (closed-loop, like a player; it adds its own `asin` and IDM).
- **Lines:** `DT info` (date, seed, driver, view distance, platform, build), `DT libm` (sin, cos, tan, atan2, exp, log, pow, sqrt, asin, atan on 4,096 fixed inputs: exact hash, hash with the low 8 mantissa bits masked, and a hash per block of 64 inputs), `DT sec=N` (the run's trace hash and each component's: car, input, traffic, opposite traffic, scoring, lives, legs, objective, sun, forks, stats; plus s, d, v, cars), `DTT k=` per tick of `--detail=<second>` (the same hashes, the car's float bits, and the libm results the next physics step takes from the state), `DT done`.
- **Web:** `?determinism=daily&date=&seconds=[&driver=][&detail=][&view_m=]` makes the main Run switch to `daily_trace.tscn` (only the main scene: the check's own run is a child), which runs 120 ticks per frame and prints to the console; at the end it frees the run and shows a note. `smoke.mjs --wait-for REGEX --console-out FILE` (new, additive) wait for `DT done` and save the console.
- **compare.mjs** prints the runs, the libm table, the seconds matching from the start, the first diverging second and each component's first diverging second, and with detail lines the first diverging tick with both sides' float bits and the libm results of the tick before (the one that differs is the cause). Exit 0 identical, 1 diverged, 2 missing traces.

### Results (2026-09-30, Linux x86_64 headless debug build vs web release build in headless Chromium, Emscripten 4.0.20)

Date 2026-09-30 (seed 2754025057311364035), car Falcon GT, view distance pinned to 700 m on both.

| Driver | Run | Bit-identical from the start | First divergence (tick, what) | Cause (the tick before: identical state, a libm result differs) | After that |
| --- | --- | --- | --- | --- | --- |
| `script` (open-loop inputs) | 300 s, 16.8 km | **18 s** (seconds 1–18) | second 19, tick 2254: the car's `yaw`, 1 ulp | `Lives` first-hit wobble: `sin(_wobble_w · t)` (`lwob`) after a hit at ~18.7 s | Only the car's float bits and `Scoring`'s per-car clearance floats drift. **Traffic, opposite traffic, lives, legs, objectives, sun, forks, stats, the banked score (14,535) and hits (60) are identical every second for all 300 s** (0 of 300 seconds differ in traffic or score) |
| `bot` (closed-loop SandboxBot) | 120 s | **19 s** | second 20, tick 2368: `yaw` 1 ulp, then `v_lat` | `VehiclePhysics.step`: `exp(-dt / yaw_lag_s(v))`, the yaw-lag blend (`lexp`) | The bot steers on the drifted state: traffic differs from second 26, stats 27, scoring 31, opposite traffic 36, sun 71, legs 94. At 120 s: score 5,067 vs 5,066, 36 vs 37 cars, 0.3 m apart; the score differs in 45 of 120 seconds (from second 76) |

Other measurements (same machine, native only):

| Comparison | Result |
| --- | --- |
| native vs native (same build, run twice) | 60 / 60 s identical |
| view distance 700 m (medium tier, the default) vs 500 m (low tier) | traffic and scoring differ from **second 10** (and the car from 31): the device's quality tier changes the Daily Drive (Findings, 3) |
| libm probe, native (glibc) vs wasm (Emscripten's musl) | `log`, `sqrt` identical; `sin`, `cos`, `tan`, `asin`, `exp`, `pow` differ in the last bits (same with the low 8 mantissa bits masked) on 52 / 58 / 55 / 48 / 2 / 1 of 64 input blocks; `atan`, `atan2` differ on 48 / 51 blocks, also beyond the low 8 bits (or a carry across them) |
| `VehicleParams` built at load time | 52 of 53 identical; `cap_time_s` (the passability capability table, from a simulated lane move) differs |

Time: the native 60 s run takes ~5 s; the web run ~60–75 s for 60 s of driving (boot 15–45 s on a loaded machine, SwiftShader); `compare.sh --seconds=60` about 2.5 min with the export.

### N8.2: identical (2026-09-30)

Everything in the Findings below is fixed (DETERMINISM.md): the simulation's transcendentals are DetMath's (bit-identical everywhere), the view distance no longer reaches the simulation (`RoadTuning.sim_horizon_m`), the car's inputs are quantized before physics. The check prints a second probe line, `DT detmath` (the same fixed inputs on DetMath); compare.mjs shows both tables. `compare.sh --replay` also records each side's replay (with the run's real lives) and has the native verifier re-simulate both.

| Driver | Seconds | Result | Wall (no export) |
| --- | --- | --- | --- |
| `script` | 300 | **IDENTICAL 300 / 300 s** (score 28,278, 47 hits, 25 cars; `DT libm` differs on 8 functions, `DT detmath` identical, `VehicleParams` 46 / 46) | 4 min 31 s |
| `bot` | 300 | **IDENTICAL 300 / 300 s** (score 12,856, 1 hit, 49 cars at 12.1 km; before the final merge) | 3 min 30 s |
| `bot --replay` | 300 | **IDENTICAL 300 / 300 s**, and the two replays are byte-identical (50,551 bytes): the native verifier accepts both (`playback=resim`, recomputed 20,948 = claimed). A web client's replay verified by the native server-side verifier | 4 min 40 s (web 112 s on a quiet box) |

(Linux x86-64 headless debug build vs the web release build in headless Chromium, on a shared 4-core box at load 7–8.) **Gate M8 is met bit for bit** for native vs wasm; phones are expected to match (no FMA contraction in the official iOS / Android templates; DETERMINISM.md) but were not measured.

### Findings (WP8.4, before N8.2)

1. **Gate M8 is not met bit for bit:** native and wasm give the same Daily Drive for 18–19 s, then the player car's state differs in the last bit. With identical inputs (the determinism contract) that difference stays in the car's float bits for at least 5 minutes: route, forks, traffic, hits and the score are the same, so a Daily Drive played with the same inputs *plays* the same on both platforms today. With a player (any closed loop) the difference is amplified within seconds and the traffic is another traffic after ~26 s, as N8.1 found between client and verifier.
2. **The causes are the platform math libraries**, not iteration order or timing: glibc and Emscripten's musl round `sin`, `cos`, `tan`, `exp`, `pow`, `asin`, `atan`, `atan2` differently in the last bit (`sqrt`, `log` and plain arithmetic agree). The first two sites hit are `Lives._wobble_offset` (`sin`) and `VehiclePhysics.step`'s yaw lag (`exp(-dt / yaw_lag_s(v))`); the others waiting in the same path: `cos`/`sin(yaw)` and `exp(-dt · lateral_grip_rate)` in `VehiclePhysics.step`, `tan(steer_angle)` in `steer_yaw_rate`, `atan2` in `Lives.apply_hit_response`, `HitDetection` (`cos`/`sin`/`atan2`), `TrafficSim` (`cos`/`sin(player.yaw)`), `Scoring` (`atan2`), `RoadHull`, and at load time `VehicleParams` (`tan`, `pow`, `atan`: `cap_time_s` already differs). The road table is safe by design (its s/d math never depends on trig results). For N8.2: replace these with our own deterministic approximations (polynomial `sin`/`cos`/`atan`, `exp` via a fixed series or a per-speed table built from exact operations), or precompute the speed-dependent factors (the yaw lag blend) as tuning tables; the check's `DT libm` line and `lwob`/`lexp`/… per-tick fields show whether a fix took.
3. **The quality tier changes the Daily Drive** (independent of floats): `Run._start_run` gives the director `builder.view_distance_m()` as its fog end, which is where traffic spawns (`TrafficDirector.set_fog_end`), and the road is generated to the view distance. LOW (500 m) and MEDIUM (700 m) runs of the same date and inputs differ from second 10. Two devices on different tiers (or a governor rung that lowered the view distance) play different traffic on the same day. Fix (N8.2 or the director's owner): spawn at a fixed, tier-independent distance (the HIGH tier's fog end + margin, or a tuning value) and let far cars stay hidden by fog on lower tiers; the check pins 700 m meanwhile (`view_m_device` in `DT info` shows what the device would have used).
4. **Closed-loop amplification is the N8.1 knife-edge problem** seen from another angle: once the car's state differs by an ulp, anything that thresholds on it (the bot's lane choice here; the director's density controller and spawn guards per REPLAY_FORMAT.md) flips. Fixing the libm sites removes the seed of the divergence; N8.1's items 1–2 (coarse director inputs, no exact-boundary spawn checks) remove the amplifier.
5. **CI (N8.2: see the handoff; the step can now run `--seconds=180`):** reliable and under 3 minutes for `--seconds=15` (`IDENTICAL`, 51 s here including the export; inside the identical window: it guards against new platform divergence before second 15, such as a trig call at run start or a params difference that matters). A 60 s identical gate needs the N8.2 fixes first. See the handoff for the requested `ci.yml` step.

## Tests

| File | Covers |
| --- | --- |
| `tests/meta/test_daily_ghost.gd` | File round trip (every field, forks incl. LEFT = −1, byte-identical re-encode, header peek); 10 minutes < 40 KB; bad files refused; 20 Hz sampling from tick 1 with the final sample; fork and reset jumps sampled with the tick before; recorder step allocates nothing (objects, static memory); store: best per date, restart, prune (old, future, stray; the next day), index repair (adopt, damaged, missing); dates and the date's seed |
| `tests/meta/test_daily_run.gd` | A real Daily run records, the best is kept, a retry plays it and the ghost sits on the car within 5 mm at every sample (same seed, same inputs); a worse run is not kept; the ghost changes nothing in the run (trace hash); disabled or Journey: nothing loaded, kept or drawn; the per-tick and per-frame hooks allocate no objects; the determinism check's run twice gives the same lines |
| `tests/world/test_ghost_playback.gd` | Interpolation, exact on samples, waiting before GO, gone after the end, rewinding; no interpolation across a fork swap and fork counting; no ghost, no pose; `pose_into` allocates nothing; which road the ghost drives on across forks (unresolved left/right, candidate not ready, same branch, behind a right swap: shifted, other branch: hidden, beyond the next split: hidden) |
| `tests/world/test_ghost_car.gd` | Every car merges into one surface with body, lamps and brake lamps tagged, about the car's length; one draw shown, none hidden, no shadow, the ghost shader (no StandardMaterial3D), lamp parameters; the mesh is built once per car |
