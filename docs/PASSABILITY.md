# Passability (WP6.1)

Spec: *Traffic → Passability guarantee*:

> Before committing any spawn batch (the next ~300 m), the director runs `passability.gd`:
> 1. Forward-simulate traffic at 10 Hz for 8 s.
> 2. Search player moves over a grid of lateral positions (lane centers and half-lanes) in 0.25 s steps. Moves are limited by the player car's real lane-change capability at its current speed. Speed is allowed anywhere from minimum speed to current speed plus possible acceleration.
> 3. Require a path that stays at or above minimum speed and never comes within 0.3 m of a hull. Without one, re-roll the batch (up to 5 times), then remove the vehicle that blocks the most paths.
>
> The same module runs in tests with a bot driver.

Also *Traffic sandbox* ("the passability paths the director found"), *Tests (headless)* (the 10,000 km soak), plan D7, D11, D12 and CONTRACTS §4-§6.

| File | What it is |
| --- | --- |
| `src/traffic/passability.gd` | `Passability`: the check (pure, `# lint: sim`), `Passability.Result` |
| `src/traffic/traffic_director.gd` | The last block, *Passability (WP6.1: the commit path)*, plus three hook lines in `step()` and `reset()` |
| `src/core/tuning/passability_tuning.gd`, `data/tuning/passability.tres` | Tuning (spec numbers + the WP6.1 knobs, each marked "not in spec") |
| `src/traffic/dev/traffic_overlay.gd`, `traffic_sandbox.gd` | The sandbox's PASS overlay |
| `tests/soak/passability_bot.gd` | `PassabilityBot`: the bot driver on passability's path (the soak's player) |
| `tests/unit/test_passability*.gd` | Module, director, bot and sandbox tests |

## API

```gdscript
var pass := Passability.new(run.tuning, registry, road)
pass.set_player_body(car.length_m, car.width_m)
pass.set_headway_scale(director_tuning.headway_scale(leg))   # plan D11, as the live sim
var res := Passability.Result.new()

pass.check_player(traffic, player, params, road, res)        # the player's own window, from where it is now
pass.set_planned(records)                                    # a planned, uncommitted batch (optional)
pass.check(traffic, player, params, road, s_from, s_to, res) # a batch, for a player arriving at it
pass.begin_check(...) ; while not pass.advance(n): ...       # either, time-sliced
```

`Result`: `passable`, `fail_t` (when the last path from the failing start ended), `probes` / `failed_probes` / `fail_s` (batch check), `vehicles` / `obstacles`, `positions` / `move_steps` / `steps`, `blocker_src[o]` (a `TrafficState` slot, or `-(k + 1)` for planned record k) and `blocker_cut[o]` (path space it cut, m), `worst_blocker(removable)`, the path (`path_s`, `path_d`, `path_state`, one point per 0.25 s). `extract_path(res, x0, s0, v_pref, d_pref, v_now, headway_s)` re-extracts the last player check's path with a driver's preferences (the bot).

`params` is the player car's `VehicleParams` (CONTRACTS §4: "Passability must use these"): `move_time(v, distance)` for the lateral moves and the full-throttle longitudinal model (`VehiclePhysics.engine_accel` minus rolling and drag) for "current speed plus possible acceleration".

## Algorithm

### 1. Forward simulation (10 Hz for 8 s)

A **lightweight step**, not a `TrafficSim` instance. The full sim costs about 5 µs per vehicle and step in GDScript when every vehicle runs its model (measured: 16 ms for 36 vehicles × 80 steps), 2-3× this step; a dedicated instance would also need its private bookkeeping (lane-change targets, split state) rebuilt from the published state anyway.

- **Copy.** The vehicles that can matter are copied from the published `TrafficState` (read only) into private structure-of-arrays storage: every vehicle whose hull can meet the player's reachable corridor within the horizon (a car behind counts at up to its desired speed catching a player at the minimum speed), plus `leader_margin_m` (40 m) of leader context beyond the corridor, plus the planned batch.
- **Models.** IDM exactly as `Idm.accel` (each profile's parameters, the D11 headway scale, the 6 m/s² clamp, 9 m/s² for scripted vehicles, hit braking, the lane-split speed cap), on the leader found by lateral overlap of the physical intervals like `TrafficSim` (a moving car occupies its whole span to the target). Integration order as `TrafficSim` (integrate with last step's acceleration, then new accelerations).
- **Lane changes.** A moving car continues its smoothstep (its target is rebuilt from the published state: a lane center, or the boundary a split entry's blinker points to). A signaling one is assumed to happen at the end of its signal time with the profile's *longest* move time, and occupies **both lanes for the whole move** (a cancel, or a quicker move, only frees space).
- **The player.** In the player check the player is the sim's participant on a nominal trajectory (its lane, its speed): cars behind it follow it (IDM with the player as leader, found by lateral overlap with the player's body stretched by its lateral velocity × `player_lateral_anticipation_s`, as `TrafficSim` does) and a signaled change into its predicted space is cancelled (`NoAmbush.violates`, fairness rule 2). This is how traffic yields to the player in the game. The batch check has no participant.
- **Not predicted:** new MOBIL decisions. Their timing is the live sim's own (its streams), and no-ambush keeps them out of the player's predicted space; a check is repeated often (the bot: every 0.5 s).

### 2. The search

- **Time:** decision steps of `step_s` (0.25 s), 32 over the horizon. The forward sim's samples are interpolated to decision times.
- **Lateral states:** the grid positions (lane centers and half-lanes, `lateral_step_lanes` = 0.5: 5 on 3 lanes, 7 on 4), the stages of a half-lane move, and one *start state* per position. A half-lane move takes `ceil(move_time(v, half lane) / step_s)` steps at the player's current speed (0.54-0.83 s → 3-4 steps for the three cars: never faster than the car can), and a moving car occupies both positions. A move stage may land on either end. In a start state the vehicles fully behind the start in that lane **and overlapping the player's actual body** are exempt (they brake for the player: rear-end prevention) until the player first moves sideways (a player between grid positions, e.g. an interrupted lane change, is not followed by the cars of the lane it has not entered); entering a lane in front of a car always needs the room.
- **Speed:** any speed in [v_lo, v_hi(t)] at any moment, where v_lo is the minimum speed (`scoring.min_speed_kmh`), or the player's own speed if it is already below it (the soak oracle's rule, docs/SOAK.md: a player stuck behind a truck may hold its speed), and v_hi integrates the full-throttle acceleration from the current speed (no boost). This is the spec's "anywhere from minimum speed to current speed plus possible acceleration", read literally: a relaxation of the braking limit.
- **Obstacles:** each predicted body grown by `clearance_m` (0.3 m) around the full visual body, *not* the 8 cm inset hull `HitDetection` uses, so the clearance to the real hull is 0.38 m (conservative), plus the chord deviation of a vehicle decelerating at 9 m/s² within one step (a·dt²/8 = 7 cm).
- **No tunnelling:** within a step the player and every obstacle move on straight lines in (t, s) (the obstacle's deviation is the pad above), so the relative position is linear: a step is collision-free exactly when the player is on the same side of the obstacle at both ends. The search works on these side constraints, so no speed can jump through a hull.
- **Lanes that end** (WP6.2 lane drops, tunnels, biome changes): the grid includes a lane still tapering away at the reference s. Where the right edge of the driving lanes (`RoadPath.lanes_right_edge_d`, sampled every 5 m, a closure widened by one sample at both ends) would leave the player's body at a grid position outside, a static **road obstacle** blocks that position and every position right of it (moves into it included). It is never a leader for predicted traffic, never counted in `Result.vehicles`, and is reported as `Result.blocker_src = SRC_ROAD` (so it is never offered for removal). A corridor whose lane count does not change (sampled every 50 m) and has no taper in force costs one lane-count lookup per 50 m.
- **Sets:** per lateral state, a sorted list of s intervals (at most 24; an overflow drops the new interval, which only loses paths).
- **Player check:** backward from the horizon. G_K is the corridor; G_k(x) is the union over x's successors x' of the pre-image of G_{k+1}(x'): each piece of G_{k+1}(x') between hulls (at t_{k+1}) is reached from the s at t_k that lie on the same side of every hull (prefix max / suffix min bounds) within the speed range. Only states laterally reachable from the start are computed. Passable when the player's start state holds its s in G_0. The path is extracted greedily through G (closest to the preferred speed and lane); a driver re-extracts it with its own preferences and a following headway (the search itself only needs the clearance, since it may always drop to v_lo).
- **Batch check ("arrival"):** see below. Forward reachable sets from start windows.
- **Blockers:** on a failure, the forward sets from the failing start(s), crediting each obstacle with the path space (m) it cuts: a hull splitting a set, or a side constraint cutting a successor interval. `worst_blocker()` takes the largest among the vehicles the caller may remove.

### 3. The batch check: a player arriving at the batch

A batch is planned `spawn_ahead_m` (750 m) ahead, beyond the fog (fairness rule 5). The player does not reach it within 8 s, so checking "from the player" would never see it (and re-rolling it could not fix what the check saw). The spec's "the next ~300 m" is read as: **the batch, as a player meets it**.

The minimum speed only bites behind vehicles slower than it: a player at ≥ v_lo can always follow a vehicle at ≥ v_lo. So for every vehicle V (live or planned) in `[s_from - arrival_probe_back_m, s_to)` slower than the minimum speed by more than `arrival_slow_margin_kmh` (now, or by its desired speed), a **probe** puts the arriving player anywhere in any free lane of the stretch behind V from which even the minimum speed reaches V within `arrival_reach_frac` of the horizon: `[s_V - h - (v_lo - v_V) · T · f, s_V - h]`, at the player's current speed (at least the minimum). A start further back would "pass" by just hanging back; one a hair below the minimum speed is no wall (the player closing at 1 km/h has the whole horizon to go round). The probe passes when some start keeps a path to the horizon; the batch passes when every probe passes. Probes whose windows differ by less than `arrival_probe_merge_m` (a wall side by side) are merged. A batch with nothing slower than the minimum speed passes at once (no simulation). A cheap stay-in-lane test runs first (a free lane beside V is the common case).

- A truck wall across every lane: every start closes on a truck at ≥ 100 km/h with nowhere to go: fails.
- One open lane: the starts in (or reaching) the open lane pass.
- A wall straddling the batch start: the probe back range sees the live vehicles too.

## The director (the commit path)

`TrafficDirector.set_player_params(params)` enables it (run.gd must call it, see *Open*). Then:

1. **Commit, then check while invisible.** A batch is planned and committed as before (`_plan_ahead` → `_plan_range` → `_commit`, band top-up included), beyond `min_ahead_m()` (fog end + 30 m). The range just committed, `[player s + min_ahead_m(), spawned_to)` with every vehicle spawned since (`vehicle_id >= mark`), is queued and checked by `Passability.check` (batch mode), **time-sliced**: `director_slices_per_tick` (2) slices per 120 Hz tick. A check takes 8-11 ticks (0.07-0.09 s); a re-roll storm stays well within a second.
2. **Re-roll.** Without a path: the range's own vehicles still beyond `min_ahead_m()` are despawned and the range is planned again with the same source on a derived stream (`rng_traffic.derive("passability")`), through the usual commit rules; up to `max_rerolls` (5).
3. **Remove the worst blocker.** Then the vehicle that cut the most path space among those the director may remove (live, the one the check saw, beyond `min_ahead_m()`) is despawned and the range checked again, up to `max_removals` (8). Still failing: committed as is and counted (`pass_unresolved`, `pass_log`).
4. **Start of run.** `reset()` checks each prefill batch at once (synchronously, anything may be re-rolled or removed: nothing is drawn yet).

"Before committing" in the spec means: before the player can see it. Committing first and checking while the batch is still beyond the fog is equivalent (nothing that failed is ever visible), keeps the director's existing planning, top-up and density code untouched, and checks the band top-up's vehicles too (they are live in the range). With the check passing, the traces are identical to a director without passability.

**Every source takes this path**: Flow, Daily and WP6.2's SetPiece. Batches containing `FLAG_SCRIPTED` vehicles are counted in `pass_scripted_batches`. A set piece's own vehicles are checked like any other but **never re-rolled or removed**: the piece is bound to its controller as soon as its batch is committed (`SetPieceSource.bind_committed`), and every piece keeps a followable path at ≥ minimum speed + `set_piece_min_speed_margin_kmh` (docs/SET_PIECES.md). A re-roll of such a batch re-draws only the filler around the piece (`SetPieceSource.keeps_clear`), with the batch bounds (`_batch_a`, `_batch_b`: the context's intensity and blind caps) set to the re-rolled range.

**Determinism.** Fixed slices per tick (no wall-clock budget), a derived stream, and the forward sim has no randomness: a check depends only on its inputs. `test_passability_director.gd::test_deterministic_commit_decisions` (same seed: same trace and the same check / re-roll / removal counts), `test_passability.gd::test_deterministic_and_independent_of_history`.

**Stats** (sandbox, soak): `pass_batches`, `pass_scripted_batches`, `pass_checks`, `pass_failed`, `pass_rerolls`, `pass_removed`, `pass_unresolved`, `pass_probes`, `pass_ticks_max`, `pass_log`.

## The bot driver

`PassabilityBot` (tests/soak) is a `TrafficBotPlayer` that drives passability's path: every 0.5 s (two decision steps, so its lateral state is always a grid state) it runs `check_player` from its exact state and re-extracts the path with its target speed, target lane (weaving legs: a random lane every 2-6 s) and a 1.0 s following headway; between replans it drives the path exactly (straight segments in (t, s) and d). Without a path it settles in the lane holding its center (an interrupted lane change is aborted, not frozen astride two lanes) and follows with IDM (`bot_no_path_checks`). It is the soak's player (`TrafficSoakRun.BOT_PASSABILITY`); the metrics reference and the density survey keep the WP3.3 weaving bot so their baselines stay comparable.

The headway matters: without it the bot rode 0.3 m behind the car ahead (the search's relaxation allows any speed down to the minimum at once), and one leader braking below the minimum speed left it without a path. That was the source of every player-induced window in the first 250 km trial (docs/SOAK.md).

## Costs

Desktop container (Xeon @ 2.1 GHz, shared with other agents: numbers ±30%), `test_passability.gd::test_check_cost_at_the_cap` and the soak:

| | 2 lanes | 3 lanes | 4 lanes |
| --- | --- | --- | --- |
| Player check (the bot, 10,000 km soak average) | 6.4 ms | 9.0 ms | 13.1 ms |
| Player check at the cap (90 vehicles, bench) | | 6.7-6.9 ms | 8.0-9.8 ms |
| Batch check at the cap, 3-4 probes (bench) | | 11-14 ms | 12 ms |
| Batch check, typical batch (no vehicle slower than 95 km/h) | < 0.3 ms | < 0.3 ms | < 0.3 ms |
| Largest slice (one tick of the director does ≤ 2) | | 4.3-7.4 ms | 2.0-3.7 ms |
| Director per tick, averaged over the soak (checks included) | 57 µs | 62 µs | 80 µs |

Where a player check goes (4 lanes, 40 vehicles copied, 18 obstacles): forward sim 45% (~1.2 µs per vehicle and step), backward search 35%, obstacle and relevance lists 20%.

The target of ≤ 3-4 ms per check is not met for a whole check in GDScript; the director therefore never runs one in a tick: it spreads each check over ~8-11 ticks (`director_slices_per_tick` = 2 slices per tick), so a re-roll storm costs at most the largest slice per tick. On the owner's phone (≈ 0.8× the container's time, D11) that is ~2-6 ms in the worst tick of a check, once per batch (every 4-7 s). Lower `director_slices_per_tick` to 1 to halve it at the price of a longer check.

Allocation-free per check after `_init` (`test_checks_allocate_nothing`); all storage is preallocated structure-of-arrays (`MAX_VEHICLES` 160, `MAX_IV` 24 intervals per state and step).

## Tuning

| Field | Value | |
| --- | --- | --- |
| `sim_hz`, `horizon_s`, `step_s`, `lateral_step_lanes`, `clearance_m`, `max_rerolls` | 10, 8, 0.25, 0.5, 0.3, 5 | spec |
| `director_enabled` | true | not in spec: switch |
| `director_slices_per_tick` | 2 | not in spec: CPU spreading |
| `max_removals` | 8 | not in spec: bound on "remove the vehicle that blocks the most paths" |
| `arrival_probe_back_m` | 50 | not in spec: probes reach this far before the batch |
| `arrival_slow_margin_kmh` | 5 | not in spec: probes behind vehicles below 95 km/h |
| `arrival_reach_frac` | 0.75 | not in spec: arrivals reach the slow vehicle within 6 s |
| `arrival_probe_merge_m` | 10 | not in spec: side-by-side walls are one probe |
| `leader_margin_m` | 40 | not in spec: prediction context beyond the corridor |

## Tests

- `tests/unit/test_passability.gd`: an empty road; a truck wall across every lane fails and the trucks are credited as blockers; one open lane passes and the path ends in it; **a lane that ends** is left in time (the body never leaves the driving lanes, the path ends out of it) and the only open lane ending before a slow wall is passed is impossible (the lane end is credited, a truck is the removable blocker); **half-lane threading** (slow bikes at the centers of lanes 0 and 1, a truck in lane 2: the path passes on the half-lane position; with lane centers only it fails); **the capability curve** (two lanes away is out of reach before contact, one lane away is not; the move takes `ceil(move_time / step)` steps); the minimum speed and a player already below it; cars behind in the player's lane follow it; **a player between grid positions** is not followed by the lane it has not entered (fails without the rule); the batch check (a planned wall fails and the planned trucks are blamed; one open lane passes; no slow vehicle: no probe; a wall straddling the batch start); time-sliced equals synchronous; deterministic and independent of history; no allocation per check; the cost bench.
- `tests/unit/test_passability_director.gd`: without params nothing changes; a wall batch is re-rolled before it can be seen (no wall left, nothing popped in); one open lane passes first time; a persistent wall is cleared by removing blockers after 5 re-rolls; scripted batches take the same path; the prefill is checked before anything is drawn; checks are spread over ticks; deterministic commit decisions.
- `tests/unit/test_passability_bot.gd`: the bot drives 1 km of leg-8 traffic on 3 lanes without a contact, below the minimum speed or without a path, and the oracle agrees; soak tier: one run per lane count (3, 3, 2, 4) over legs 1-8.
- `tests/unit/test_passability_sandbox.gd`: the sandbox director checks its batches; the PASS overlay gets the director's paths and the bot's own path.
- The soak: docs/SOAK.md, *WP6.1*.

## Soak

docs/SOAK.md, *WP6.1*: 10,024 km, **0 impossible windows on 3 and 4 lanes** (the D11 3-lane window is gone), 0 contacts with the player, 0 rule violations; **4 windows on 2 lanes** (legs 6-8), all compressed lane-0 platoons below the minimum speed on a road whose other lane flows below it: a 2-lane traffic decision, below.

## Open / deviations

- **2-lane roads (plan D12, still open).** On 2 lanes the right lane flows at 95 km/h, below the 100 km/h minimum, so lane 0 is the only lane at or above it, and at leg 6-8 densities its platoons dip to 92-98 km/h (braking waves, cut-ins from lane 1: every vehicle involved desires ≥ 105 km/h). The player then has to drop below the minimum speed: 4 windows in 2,492 km. Passability cannot fix what forms in view long after the batch check, and a MOBIL rule keeping slow-desired vehicles out of the only fast lane did not help (experiment, docs/SOAK.md). Options for the orchestrator: a lower density cap on 2-lane roads, a right-lane flow at or above the minimum speed there, or a lower minimum speed on 2-lane sections.
- **CONTRACTS §5** says passability "works on its own `copy_from` copy". It copies the vehicles that matter into its own structure-of-arrays storage instead (a full `copy_from` plus stepping 90 slots would cost more and the step is its own); the published state is still only read.
- **The batch check reads the spec's "the next ~300 m" as "the batch as a player arriving at it meets it"**, with probes behind the slow vehicles, and checks it after committing it beyond the fog (nothing failing is ever visible). For the plan's deviations table.

- **run.gd** (not in WP6.1's paths) must call `director.set_player_params(car.params)` after creating the director, and `src/dev/car_drive.gd` likewise; until then the game runs without the check (the soak, the sandbox and the tests have it).
- **New MOBIL decisions are not predicted** by the forward sim (above). The checks are repeated often enough (every batch; the bot every 0.5 s) for this not to matter in the soak.
- **Lane-count changes inside the horizon**: a lane that ends is modeled (road obstacles, above); a lane that *opens* inside the horizon is not added to the grid (conservative). Only the right edge moves (lane drops are on the right). Forks (WP6.5) are not modeled.
- **The soak oracle** (`tests/fixtures/traffic/impossible_window_checker.gd`, not in WP6.1's paths) uses the lane count at the window's start for the whole window, so on biome roads it would count a path through an ending lane: it under-reports windows at lane drops. It should get the same right-edge test (independently written).
- The lane-change capability is a half-lane move time with its settle, so a full lane change counts as two (1.5-2.0 s instead of the car's 0.8-1.2 s): conservative.
