# Traffic soak, metrics and the impossible-window oracle (WP3.3)

Spec: *Traffic → Tests (headless)*: "Soak: 10,000 simulated km with a bot driver produce zero impossible windows and zero traffic-to-traffic collisions. Rule checks: zero lane changes shorter than the minimum signal time, and zero no-ambush violations. Determinism: the same seed gives an identical traffic trace (hash of all vehicle states every second). Logged metrics per build: gaps per km, lane changes per vehicle per minute, mean speed per lane, set pieces per leg. A regression beyond ±15% on any of them fails the test." Also *Passability guarantee* (the impossible-window definition), *Lives → Fairness rules* (rear-end prevention) and plan §6 (test tiers), D7 (cap) and D8 (no automatic high beams).

| File | What it is |
| --- | --- |
| `tools/soak.sh` | Sharded multi-process soak runner, summary, gate, baseline update |
| `tests/soak/soak_main.gd` | One shard (a `SceneTree` script), or the metrics reference (`--metrics=`) |
| `tests/soak/traffic_soak_run.gd` | `TrafficSoakRun`: one self-contained, seeded run |
| `tests/soak/traffic_metrics_reference.gd` | `TrafficMetricsReference`: the fixed-seed metrics reference and the baseline file |
| `tests/fixtures/traffic/impossible_window_checker.gd` | `ImpossibleWindowChecker`: the impossible-window oracle (reusable) |
| `tests/fixtures/traffic/traffic_metrics.gd` | `TrafficMetrics`: metric accumulators, definitions and the ±15% compare |
| `tests/fixtures/traffic/traffic_rule_checker.gd` | `TrafficRuleChecker` (WP2.4) + contact episodes and the "normal driving" rear-end rule |
| `tests/baselines/traffic_metrics.json` | The committed metrics baseline |
| `tests/soak/test_traffic_soak.gd` | Tiny soak (fast), cross-shard determinism (fast), one run per lane count (soak) |
| `tests/soak/test_impossible_window_checker.gd` | The oracle on hand-built layouts (fast) |
| `tests/unit/test_traffic_metrics.gd` | Metric definitions and compare (fast), the ±15% regression and D7 (soak) |

## Commands

```
tools/soak.sh                                  # the full 10,000 km, 4 shards (~1 h on 4 cores)
tools/soak.sh --km=500 --shards=4              # a shorter one
tools/soak.sh --km=100 --shards=3 --compare-with=tests/out/soak/summary.json --out=tests/out/soak3
                                               # same per-run traces with another sharding?
tools/soak.sh --merge --out=DIR                # re-summarize shard files (e.g. after a kill)
tools/soak.sh --update-baseline                # rewrite tests/baselines/traffic_metrics.json (review the diff)
tools/test.sh --tier=soak --filter=soak        # soak tier: short soak, metrics regression, D7, WP2.4 soaks
```

`tools/soak.sh` options: `--km` (default `traffic.soak_distance_km` = 10,000), `--shards` (4), `--seed`, `--legs` (runs' legs, default `soak_run_legs` = 8), `--leg-km` (default the legs tuning's 3.5 km), `--no-windows` (skip the oracle), `--out` (default `tests/out/soak`). Shard *i* of *N* runs every run *r* with (*r* + ⌊*r* / *N*⌋) mod *N* = *i*: round robin, rotated by one every *N* runs, so the 3/3/2/4-lane cycle spreads over the shards (plain round robin gave one shard every 4-lane run, the slowest). Each shard writes `shard_i.json` after every run and a progress line to `shard_i.log` every minute; the runner echoes those every minute and finally writes `summary.json` and prints the summary. **Exit status 1** when any gate counter is not zero, a run did not finish, a shard failed, the engine logged an error, or `--compare-with` found a trace mismatch.

## A soak run

`TrafficSoakRun.new(index, base_seed)` is one journey, seeded by its index alone (`Rng.derive_seed(base_seed, "soak_run_<i>")`). It builds everything fresh, so its trace does not depend on the shard that runs it or on what ran before:

- **Road:** the procedural road (`ProceduralRoadPath`) with `lanes_default` from `traffic.soak_lane_counts`, cycled by run index: 3, 3, 2, 4 (farmland has 3 lanes; biomes 2-4).
- **Traffic:** the real `TrafficRegistry`, `TrafficSim`, `TrafficDirector` (Flow batches ahead, behind spawns, despawn, the cap, the ghost zone) and `OppositeTraffic`.
- **Legs:** legs 1 to `soak_run_legs` (8) of the legs tuning's length (3.5 km): leg *k* runs at leg *k*'s density and aggressive share (Hesitant from leg 3), night from the second half (headlights on both carriageways).
- **Player:** a `TrafficBotPlayer`, sized like one of the three `data/cars` (by run index), as the sim's participant. Per leg it draws a target speed in [`soak_bot_min_kmh`, `soak_bot_max_kmh`] = [110, 250] km/h and either weaves (`soak_bot_weave_pct` = 60%: IDM following, a lane change every 2-6 s into the lane with the longest free gap, no care for the car behind) or keeps its lane (IDM following only).
- **Tick order** (CONTRACTS §4): bot, `TrafficSim.step`, the rule checker (collisions), `notify_hit` for every new contact with the player (like run.gd), `TrafficDirector.step`.
- **Distance:** a run ends when the bot has driven its legs (28 km); a stuck run times out at 3× its distance at the bot's minimum speed and counts as unfinished.

### Checks and gate counters

Per tick, by the independent `TrafficRuleChecker` (it reads only `TrafficState` and the player):

| Counter | Gate | Meaning |
| --- | --- | --- |
| `collision_pairs` | 0 | Traffic-to-traffic overlaps (oriented boxes inset by `lives.collision_inset_m`, SAT) |
| `signal_violations` | 0 | Lateral motion less than the profile's signal time after the blinker came on |
| `unsignaled_moves` | 0 | Lateral motion without a blinker (hit swerves excepted) |
| `ambush_violations` | 0 | A lateral move started into the player's predicted space (1.5 s, 1.0 m margin) |
| `decel_violations` | 0 | Deceleration beyond 6 m/s² outside set pieces |
| `brake_flag_violations` | 0 | Brake-light flags not matching the deceleration (1 and 4 m/s²) |
| `rear_end_normal` | 0 | A traffic car touching the player from behind when the player had neither moved sideways nor braked beyond 6 m/s² for `soak_normal_driving_quiet_s` (3 s): "a player driving normally" |
| `impossible_traffic` | 0 | Impossible windows not caused by the player (below) |

Reported, not gated: `contact_episodes` / `rear_end_episodes` (contacts the weaving bot causes by cutting in with an impossible gap: "the resulting contact counts as a hit, because the player caused it"), `impossible_player_induced`, lane moves checked, signals, cancels, director counters, peak and mean active vehicles, tick cost.

### Impossible windows (the pre-director oracle)

Every `soak_window_check_interval_s` (1 s) the run asks `ImpossibleWindowChecker.is_passable(state, player, road)`. The definition follows the spec's passability guarantee in simplified form; Phase 6's `passability.gd` is the director's own guarantee and this stays the test oracle.

**A window is impossible** when, looking `passability.horizon_s` (8 s) ahead with the traffic's forward prediction, no path exists for the player that:

1. moves over the lateral grid of lane centers and half-lanes (`passability.lateral_step_lanes`), deciding every `passability.step_s` (0.25 s). A half-lane move takes the car's lane-change time for half a lane at its current speed (`VehicleTuning.lane_change_target_s(v) / 2`, rounded to whole steps, at least one: two steps at every speed, so a full lane takes 1.0 s), and the car occupies both grid positions while it moves;
2. keeps its speed in [minimum speed (`scoring.min_speed_kmh`, 100 km/h), current speed + the car's mean 0-200 km/h acceleration × t], capped at its top speed. Any speed in the range is allowed at any moment (a relaxation of the braking and acceleration limits). A player already below the minimum speed may hold its current speed instead: the lower bound is min(minimum speed, current speed). The spec's range ("from minimum speed to current speed plus possible acceleration") is empty at t = 0 for such a player; demanding 100 km/h at once turned every lane-keeping bot stuck behind a truck in the slow lane, with a car beside it, into an "impossible window" it had put itself in (23 in the first 1,540 km; `test_a_player_below_minimum_speed_may_hold_its_speed`);
3. stays on the driving lanes (no shoulders);
4. never comes within `passability.clearance_m` (0.3 m) of a predicted hull (full body boxes in road space, grown by the clearance).

**Traffic prediction** (simplified; `passability.gd` will forward-simulate the real models at 10 Hz):

- Vehicles fully behind the player are ignored: they follow the player (IDM with the player as leader) rather than drive into it.
- Every other vehicle keeps its speed, but never drives through the vehicle ahead of it on its lateral path: it queues behind it.
- A running lane change continues its smoothstep to its final `d`. A signaled one is assumed to happen: it starts when the signal time ends and takes the profile's longest move time. A lane-splitting bike keeps riding the line.

**No tunneling:** positions propagate in sub-steps short enough that neither the player nor any vehicle can cross the shortest hull-plus-clearance block (a motorbike's) within one (`SUB_STEP_BLOCK_FRAC` = 0.9 of it); `test_no_tunneling_through_short_hulls` fails with coarse sub-steps.

**Player-induced windows:** a failed check where the player is already within the clearance of a hull at t0 (its own cut-in in progress) counts in `impossible_player_induced`, not in the gate. Windows are counted once per episode: consecutive failed checks are one window. For each of the first windows the run records where and why: run, seed, time, s, leg, lane count, the player's speed and lane, when the last path ended, and per lane the vehicles within 250 m ahead with those below the minimum speed (profile, distance, speed, lane-change state). "Slow wall" means every lane has one.

Cost: about 6 ms per check (GDScript, 3 lanes, leg 1), so at 1 Hz it is roughly a fifth of a run's CPU time. Each window example also records `player_moved_s_ago`, the time since the player's last lateral motion (added after the 10,000 km run below, which was diagnosed by replaying the runs).

## Determinism

`TrafficSoakRun.trace` chains, every `trace_hash_interval_s` (1 s), `TrafficState.hash_into` of the player's carriageway, the opposite carriageway's state, and the player's `VehicleState`. The summary lists every run's trace.

- `test_trace_is_deterministic_across_runs_and_shards` (fast): run 1 alone (shard 1 of 2) equals run 1 after run 0 (shard 0 of 1) equals a repeat; different runs and a different base seed differ.
- `tools/soak.sh --compare-with=`: a small soak with `--shards=2` and one with `--shards=3` give identical traces for every run (checked: 8 runs, 0 mismatches).

## Metrics

`TrafficMetrics` (fixture) observes `TrafficState`, the player and the sim's completed lane changes:

| Metric | Definition |
| --- | --- |
| `gaps_per_km` | Bumper-to-bumper gaps of at least `metrics_gap_min_m` (15 m, a gap the player can enter) between consecutive vehicles in the same lane, per km of lane, over [player s, player s + 750 m], sampled every `metrics_sample_interval_s` (1 s) |
| `lane_changes_per_vehicle_min` | Completed lane moves / vehicle-minutes simulated |
| `mean_speed_kmh_lane_<i>` | Sampled mean speed of vehicles in lane *i* (0 = next to the median), not counting vehicles changing lanes |
| `set_pieces_per_leg` | Set pieces spawned / legs driven: 0 until WP6.3 (the field is kept) |
| `density_per_km_lane` | (context) Vehicles per km per lane in the same window |

**Reference and baseline.** One run is chaotic: from seed to seed its lane changes per vehicle-minute vary by about 17% (coefficient of variation), gaps per km by 8-11%, lane speeds by 1-3%. A ±15% gate on one run would trip on butterfly effects (moving the behind-spawn retries changed one 28 km run's lane-change rate by 24%). So the reference (`TrafficMetricsReference`, `reference`) sums 16 runs on the 3-lane road, legs 1-8 of 1.5 km each (192 km, about 3 minutes), which brings the noise to about 4-5%. It runs in the soak tier (`soak_metrics_reference_matches_baseline`, plan §6); the fast tier checks the pipeline on one short run (`test_metrics_pipeline_on_a_short_run`: every metric present, finite and plausible). A metric beyond `traffic.metrics_tolerance_pct` (15%) of the baseline, or any change from an exact 0, fails. After a deliberate traffic change, rewrite the baseline with `tools/soak.sh --update-baseline` and commit it with the change.

Baseline (`tests/baselines/traffic_metrics.json`, seed 3303, 16 runs, 3 lanes):

| Metric | Baseline |
| --- | --- |
| `gaps_per_km` | 8.34 |
| `lane_changes_per_vehicle_min` | 0.709 |
| `mean_speed_kmh_lane_0` / `_1` / `_2` | 124.6 / 115.4 / 103.4 |
| `set_pieces_per_leg` | 0 |
| `density_per_km_lane` | 9.67 |

(192 km, 5,583 simulated seconds, flow speeds 135 / 115 / 95 km/h.)

## Results: the 10,000 km soak

`tools/soak.sh --km=10000 --shards=4` on the 4-core dev container (Godot 4.7 headless, Xeon @ 2.1 GHz), with this WP's traffic code (only the reporting field `player_moved_s_ago` came later):

| | |
| --- | --- |
| Distance | **10,024 km** in 358 runs of 28 km (legs 1-8 × 3.5 km): 5,040 km on 3 lanes, 2,492 km on 2 lanes, 2,492 km on 4 lanes |
| Simulated time | 82.5 h (297,000 s at 120 Hz, 35.6 M ticks) |
| Wall time | **3,605 s (60 min)** on 4 shards (3,576-3,604 s each); 14,341 CPU-s in runs |
| Throughput | 10,010 km per wall hour; 20.7× real time per process, everything included (sim, director, opposite side, bot, per-tick checker, the oracle at 1 Hz) |
| Traffic tick | 134 µs per 120 Hz `TrafficSim.step` on average (mean 40.8 active vehicles, peak 60) |

| Counter | Total | Gate |
| --- | --- | --- |
| Traffic-to-traffic collisions (pairs / ticks) | 0 / 0 | ✅ 0 |
| Signal-time violations | 0 (of 152,789 completed lane moves; 166,579 signals, 5,513 cancels) | ✅ 0 |
| Unsignaled lateral moves | 0 | ✅ 0 |
| No-ambush violations | 0 (152,789 moves checked) | ✅ 0 |
| Deceleration beyond 6 m/s² | 0 (min accel exactly −6.00) | ✅ 0 |
| Brake-light flag mismatches | 0 | ✅ 0 |
| Rear-ends of a normally driving player | 0 | ✅ 0 |
| Impossible windows (traffic) | **3**, all on 2-lane roads (0 on 3 and 4 lanes) | ❌ 3 |
| Impossible windows (player-induced) | 75 (the player already inside a hull's clearance: its own cut-in) | reported |
| Impossible checks failed | 95 of 296,803 | reported |
| Contacts with the player | 110 episodes (12,333 ticks): 93 from behind, every one within 3 s of the bot's own lateral move or hard braking; 17 the bot touching a car ahead or beside | reported |
| Unfinished runs / engine errors | 0 / 0 | ✅ |

Director: 61,078 ahead and 7,179 behind spawns, 51,712 despawns; refused: 4,821 at the cap (4,780 of them on 4 lanes), 68 in the ghost zone, 5,063 by the commit re-check (`rejected_overlap`); sim cancels: 869 for the player, 491 Hesitant, 4,153 unsafe.

Metrics over the whole soak, by lane count:

| Lanes | gaps/km | lane changes / vehicle-min | mean speed per lane (km/h, lane 0 first) | density /km/lane |
| --- | --- | --- | --- | --- |
| 2 | 10.30 | 0.452 | 109.5, 97.0 | 11.64 |
| 3 | 9.21 | 0.691 | 125.0, 114.8, 104.2 | 10.54 |
| 4 | 8.54 | 1.090 | 140.4, 132.9, 120.8, 111.6 | 9.87 |

**The three traffic windows** (replayed from their run seeds). In every one the weaving bot had changed lanes 1.5-2.9 s earlier, into lane 1 of a 2-lane road right behind a vehicle slower than the minimum speed:

| Run | Player | What blocks | Why no path |
| --- | --- | --- | --- |
| 350 (leg 2) | 99.8 km/h, 2.9 s after its lane change | a van at 94 km/h 7 m ahead (center), moving from lane 1 to lane 0 | During the van's 2.9 s move it spans both lanes; the player, closing at 1.7 m/s from 1.5 m, may not drop below its own 99.8 km/h |
| 2 (leg 4) | 104.3 km/h, 2.0 s after its lane change | a bus at 86 km/h 13 m ahead, its signal to lane 0 ending | Its predicted move spans both lanes; the player may not go below 100 km/h |
| 338 (leg 4) | 133.4 km/h, 1.5 s after its lane change | a truck at 86 km/h, 1.75 m bumper gap ahead in the new lane; lane 0 busy | The bot's own cut-in at 13 m/s closing speed; any path needs braking below 100 km/h |

So none is a wall that Flow built: two are a slow vehicle moving out of (or across) the lane the player has just entered on a 2-lane road, one is the bot's reckless cut-in. All three need the player to drop below 100 km/h for a second or two, which the strict definition forbids. See *Findings*.

**Cross-shard determinism** was checked separately: the same 8 runs sharded 2 and 3 ways gave identical traces (`--compare-with`, 0 mismatches); every run's trace is in `summary.json`.

## D7: cap 60 vs 90

`soak_d7_cap_60_vs_90` (soak tier): leg-8 density and mix, 2 × 3.5 km, 3 seeds per row, the same bot, windows off. Tick cost is the mean µs per 120 Hz `TrafficSim.step` / `TrafficDirector.step` in the run (single process, dev container).

| Lanes | Cap | Sim µs/tick | Director µs/tick | Mean active | Peak | Ticks at the cap | Density shown (/km/lane, target 16) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 60 | 138 | 38 | 53.5 | 60 | 2% | 14.64 |
| 3 | 90 | 136 | 40 | 53.5 | 62 | 0% | 14.63 |
| 4 | 60 | 153 | 45 | 57.1 | 60 | 21% | 11.64 |
| 4 | 90 | 167 | 48 | 63.7 | 74 | 0% | 12.37 |

WP2.4's fixed-count bench for comparison (`soak_tick_cost_report`): 60 vehicles ≈ 159-181 µs, 90 vehicles ≈ 230-253 µs per tick (spread layouts).

**Reading for D7:**

- **3 lanes (farmland, the only biome today):** the cap barely matters. The director keeps ~53 vehicles at leg 8 and touches 60 in 2% of ticks; cap 90 changes nothing measurable.
- **4 lanes:** cap 60 binds 21% of the time. The director keeps 57 on average instead of 64 (−10%) and shows 11.6 instead of 12.4 vehicles/km/lane (−6%); it dropped 4,780 planned vehicles over the 2,492 km of 4-lane soak. Cap 90 costs ~9% more sim time per tick (167 vs 153 µs), since the director never actually wanted more than ~75.
- **Why the realized density is below 16 even uncapped:** Flow fills each new 300 m batch at the leg's density in the road's frame, but vehicles faster than the player leave the window ahead (despawned beyond ahead + batch + 100 m) and slower ones fall behind (despawned at −200 m), and only the left lanes get behind spawns. The window around the player therefore holds 73-92% of the target at leg 8 (3 lanes: 14.6 of 16). That is a WP2.5/Phase 6 director property, not the cap.
- **Suggestion:** keep 60 for 3-lane biomes; if 4-lane biomes must show the full leg-8 density, raise the cap to ~75-80 (what the director asks for) rather than 90, and decide with the on-device sim tick from the dev HUD as planned.

## Findings and open points

1. **Gate status.** Zero collisions and zero rule violations over 10,024 km. Impossible windows: 0 on 3 and 4 lanes, **3 on 2-lane roads** (above). The gate "zero impossible windows" is met for the current road (farmland, 3 lanes) and for 4 lanes; it is not met on 2 lanes. For the orchestrator:
    - The 2-lane windows are short (1-2 checks each) and each follows the player's own lane change into a lane with a slow vehicle close ahead. Counting a window as player-induced when it starts within `soak_normal_driving_quiet_s` (3 s) of the player's lateral move, like rear-ends, would make all three player-induced. That was **not** applied: it would redefine the gate after seeing the result. `player_moved_s_ago` is now recorded so the decision can be made with data.
    - The underlying 2-lane issue is real: on a 2-lane road the right lane flows at 95 km/h (below the 100 km/h minimum), trucks and buses (keep-right, right 2 lanes) may use both lanes, and a slow vehicle overtaking or changing lanes spans both lanes for 2.5-3 s. Phase 6's `passability.gd` should treat that (e.g. no slow-profile lane change into the fast lane of a 2-lane road while the player is close behind, or spawn keep-right profiles only in the right lane and forbid them the left lane on 2 lanes). Not changed here (driver profiles are not in WP3.3's paths, and the brief asked for a report, not a workaround).
    - Alternatively, scope the M3 gate to the lane counts in use (`traffic.soak_lane_counts = [3]`) until 2-lane biomes arrive (WP6.x).
2. **Player-caused contacts.** The weaving bot cuts in with no regard for the car behind; all 93 rear-end contacts came within 3 s of its own lateral move or hard braking ("the player caused it", spec). No rear-end of a normally driving player in 82.5 simulated hours.
3. **The strict minimum speed.** The oracle lets a player already below 100 km/h hold its speed (see the definition). Without that, lane-keeping behind a truck in the slow lane produced 23 "impossible windows" in the first 1,540 km (all the player's own situation). Phase 6's passability needs the same rule, or an explicit "the player may brake briefly" allowance.
4. **Realized density** is 73-92% of the leg's target at leg 8 (see D7). The director keeps density in the road frame at spawn time; traffic faster than the player drains out of the window ahead. If the spec's "8 to 16 vehicles per km per lane" is meant around the player, Phase 6 needs a re-fill for the ahead window (spawning at the fog end in lanes that thinned).
5. **Director tick cost.** ~40-48 µs per tick at leg 8 (after the behind-spawn back-off, which removed ~40 µs). The rest is mostly `OppositeTraffic.step` (~26 µs for 25 vehicles, a road query per vehicle per tick) and the despawn scan (~13 µs). Worth trimming for phones (e.g. step the opposite side at 30 Hz); not in WP3.3's paths.
6. **Metric noise.** One 28 km run's lane-change rate varies ~17% from seed to seed, so the ±15% regression runs on a 16-run reference (soak tier). A change that moves any 16-run metric by >15% is a real behavior change: update the baseline deliberately.
