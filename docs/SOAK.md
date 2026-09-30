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

`tools/soak.sh` options: `--km` (default `traffic.soak_distance_km` = 10,000), `--shards` (4), `--seed`, `--legs` (runs' legs, default `soak_run_legs` = 8), `--leg-km` (default the legs tuning's 3.5 km), `--no-windows` (skip the oracle), `--out` (default `tests/out/soak`). Shard *i* of *N* runs every run *r* with (*r* + ⌊*r* / *N*⌋) mod *N* = *i*: round robin, rotated by one every *N* runs, so the 3/3/2/4-lane cycle spreads over the shards (plain round robin gave one shard every 4-lane run, the slowest). Each shard writes `shard_i.json` after every run and a progress line to `shard_i.log` every minute; the runner echoes those every minute and finally writes `summary.json` and prints the summary. **Exit status 1** when any gate counter is not zero, a run did not finish, a shard failed, the engine logged an error, or `--compare-with` found a trace mismatch. WP6.10: the summary (and `summary.json`, in `totals` and per lane count in `by_lanes`) also sums the counters that were only in the per-run JSON: `standstill_beside_fast`, `impossible_player_cut_in`, `impossible_in_closure`, `player_offroad_ticks`, the bot's checks, checks without a path and ms per check, the director's passability stats (`pass_batches`, `pass_scripted_batches`, `pass_checks`, `pass_probes`, `pass_failed`, `pass_rerolls`, `pass_removed`, `pass_unresolved`, the longest check `pass_ticks_max`) and the oracle's ms per check; each lane count gets every gate counter and these on their own lines. **Resuming** after a kill: run the missing indices with `tools/godot.sh --headless --path . --script res://tests/soak/soak_main.gd -- --runs=I,J,... --out=res://DIR/shard_N.json` (plus the soak's `--all-pieces` etc.) into a new shard file, then `tools/soak.sh --merge --out=DIR`.

## A soak run

`TrafficSoakRun.new(index, base_seed)` is one journey, seeded by its index alone (`Rng.derive_seed(base_seed, "soak_run_<i>")`). It builds everything fresh, so its trace does not depend on the shard that runs it or on what ran before:

- **Road:** the procedural road (`ProceduralRoadPath`) with `lanes_default` from `traffic.soak_lane_counts`, cycled by run index: 3, 3, 2, 4 (farmland has 3 lanes; biomes 2-4).
- **Traffic:** the real `TrafficRegistry`, `TrafficSim`, `TrafficDirector` (Flow batches ahead, behind spawns, despawn, the cap, the ghost zone) and `OppositeTraffic`.
- **Legs:** legs 1 to `soak_run_legs` (8) of the legs tuning's length (3.5 km): leg *k* runs at leg *k*'s density and aggressive share (Hesitant from leg 3), night from the second half (headlights on both carriageways).
- **Player:** a `TrafficBotPlayer`, sized like one of the three `data/cars` (by run index), as the sim's participant. Per leg it draws a target speed in [`soak_bot_min_kmh`, `soak_bot_max_kmh`] = [110, 250] km/h and either weaves (`soak_bot_weave_pct` = 60%: IDM following, a lane change every 2-6 s into the lane with the longest free gap, no care for the car behind) or keeps its lane (IDM following only). WP6.8: like a player reading the LANE ENDS sign, it leaves a lane the road drops within 800 m as soon as the lane beside it is clear beside it with at least 1.5 s (30 m) of free road ahead, and never weaves into one; if it is still there 350 m out, it waits for 0.5 s (10 m) of free road ahead beside it until 150 m out, then takes any gap clear beside it (before, it left only 350 m out, into any gap beside it: a 140 km/h cut-in 11 m behind a bus at 86 km/h is a window no traffic rule could prevent). It also counts a car that is already moving into a lane as in that lane, so it no longer swerves into a lane beside an early lane-drop merger entering it 5 m ahead (two cars converging on one lane: a window flagged "other" on the tree merged with WP6.7).
- **Tick order** (CONTRACTS §4): bot, `TrafficSim.step`, the rule checker (collisions), `notify_hit` for every new contact with the player (like run.gd), `TrafficDirector.step`.
- **Distance:** a run ends when the bot has driven its legs (28 km); a stuck run times out at 3× its distance at the bot's minimum speed and counts as unfinished.

### Checks and gate counters

Per tick, by the independent `TrafficRuleChecker` (it reads only `TrafficState` and the player):

| Counter | Gate | Meaning |
| --- | --- | --- |
| `collision_pairs` | 0 | Traffic-to-traffic overlaps (oriented boxes inset by `lives.collision_inset_m`, SAT; WP6.8: a box's heading `atan2(v_lat, v)` is clamped to ±0.28 rad, see *WP6.8*) |
| `signal_violations` | 0 | Lateral motion less than the profile's signal time after the blinker came on |
| `unsignaled_moves` | 0 | Lateral motion without a blinker (hit swerves excepted) |
| `ambush_violations` | 0 | A lateral move started into the player's predicted space (1.5 s, 1.0 m margin) |
| `decel_violations` | 0 | Deceleration beyond 6 m/s², except a scripted set-piece vehicle whose piece the checker itself saw first warned ≥ 300 m ahead (rule 4, WP6.2; those count in `set_piece_hard_decels`) |
| `brake_flag_violations` | 0 | Brake-light flags not matching the deceleration (1 and 4 m/s²) |
| `rear_end_normal` | 0 | A traffic car touching the player from behind when the player had neither moved sideways nor braked beyond 6 m/s² for `soak_normal_driving_quiet_s` (3 s): "a player driving normally" |
| `impossible_traffic` | 0 | Impossible windows not caused by the player (below) |
| `offroad_violations` | 0 | A traffic vehicle's box beyond the drivable lanes (`lanes_left_edge_d` / `lanes_right_edge_d` at its `s`) by more than 0.05 m: e.g. still in a lane that has ended (WP6.2, lane drops) |

Reported, not gated: `standstill_beside_fast` (WP6.8, per-run JSON: once a second, a vehicle below 15 km/h with one above 60 km/h in the next lane within 40 m), `contact_episodes` / `rear_end_episodes` (contacts the weaving bot causes by cutting in with an impossible gap: "the resulting contact counts as a hit, because the player caused it"), `impossible_player_induced`, lane moves checked, signals, cancels, director counters, peak and mean active vehicles, tick cost.

### Impossible windows (the pre-director oracle)

Every `soak_window_check_interval_s` (1 s) the run asks `ImpossibleWindowChecker.is_passable(state, player, road)`. The definition follows the spec's passability guarantee in simplified form; Phase 6's `passability.gd` is the director's own guarantee and this stays the test oracle.

**A window is impossible** when, looking `passability.horizon_s` (8 s) ahead with the traffic's forward prediction, no path exists for the player that:

1. moves over the lateral grid of lane centers and half-lanes (`passability.lateral_step_lanes`), deciding every `passability.step_s` (0.25 s). A half-lane move takes the car's lane-change time for half a lane at its current speed (`VehicleTuning.lane_change_target_s(v) / 2`, rounded to whole steps, at least one: two steps at every speed, so a full lane takes 1.0 s), and the car occupies both grid positions while it moves;
2. keeps its speed in [minimum speed (`scoring.min_speed_kmh`, 100 km/h), current speed + the car's mean 0-200 km/h acceleration × t], capped at its top speed. Any speed in the range is allowed at any moment (a relaxation of the braking and acceleration limits). A player already below the minimum speed may hold its current speed instead: the lower bound is min(minimum speed, current speed). The spec's range ("from minimum speed to current speed plus possible acceleration") is empty at t = 0 for such a player; demanding 100 km/h at once turned every lane-keeping bot stuck behind a truck in the slow lane, with a car beside it, into an "impossible window" it had put itself in (23 in the first 1,540 km; `test_a_player_below_minimum_speed_may_hold_its_speed`);
3. stays on the driving lanes (no shoulders) where they exist. WP6.10: a lane that ends (the road's right edge, `lanes_right_edge_d`, sampled every 2 m and one sample wider at both ends) and a lane the traffic sim closes (road works, a merge zone's lane end, the road's drops synced into the sim: `ImpossibleWindowChecker.zones`, the run's `TrafficSim`) are static obstacles for every grid position whose body would overlap them (a closed lane blocks its center and both half-lanes). The grid spans every lane in the corridor: one still tapering away at the start, and one that opens ahead (blocked until it exists). Before WP6.10 the grid had the start's lane count for the whole horizon, so a path through an ending lane counted (under-reporting at lane drops);
4. never comes within `passability.clearance_m` (0.3 m) of a predicted hull (full body boxes in road space, grown by the clearance).

**Traffic prediction** (simplified; `passability.gd` forward-simulates the real models at 10 Hz):

- Vehicles fully behind the player are ignored: they follow the player (IDM with the player as leader) rather than drive into it.
- Every other vehicle drives with **bounded acceleration toward its desired speed** (WP6.10: IDM's free-road term a_max (1 − (v / v0)^δ) of its profile, braking at most at `max_decel_mps2`; v0 capped by the sim's speed zones and lane-drop harmonisation, `speed_limit_at` / `lane_drop_limit_at`), but never drives through the vehicle ahead of it on its lateral path: it queues behind it. Before WP6.10 every vehicle kept its speed, so a platoon accelerating back to its desired speed was a wall (the WP6.1 4-lane false positive, run 247). No IDM interaction term: a follower closes up to its queue floor instead of keeping its time headway (as before), and no new MOBIL decisions. Lane-splitting motorbikes keep their speed.
- A vehicle whose lane the sim closes ahead stops `merge_stop_margin_m` before the closure (or where it is, inside one) until its lane change out of the lane starts.
- A running lane change continues its smoothstep to its final `d`. A signaled one is assumed to happen: it starts when the signal time ends and takes the profile's longest move time. A lane-splitting bike keeps riding the line.

**No tunneling:** positions propagate in sub-steps short enough that neither the player nor any vehicle can cross the shortest hull-plus-clearance block (a motorbike's) within one (`SUB_STEP_BLOCK_FRAC` = 0.9 of it); `test_no_tunneling_through_short_hulls` fails with coarse sub-steps.

**Player-induced windows:** a failed check where the player is already within the clearance of a hull at t0 (its own cut-in in progress) counts in `impossible_player_induced`, not in the gate. WP6.10: so does one where the player's body is already in a closed lane or beyond the right edge at t0 (a static obstacle it is inside: `impossible_in_closure`, a subset). Windows are counted once per episode: consecutive failed checks are one window. For each of the first windows the run records where and why: run, seed, time, s, leg, lane count, the player's speed and lane, when the last path ended, and per lane the vehicles within 250 m ahead with those below the minimum speed (profile, distance, speed, lane-change state). "Slow wall" means every lane has one.

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
| `set_pieces_per_leg` | Set pieces spawned (bound to committed vehicles, `SetPieceSource.spawned`) / legs driven (WP6.2) |
| `density_per_km_lane` | (context) Vehicles per km per lane in the same window |

**Reference and baseline.** One run is chaotic: from seed to seed its lane changes per vehicle-minute vary by about 17% (coefficient of variation), gaps per km by 8-11%, lane speeds by 1-3%. A ±15% gate on one run would trip on butterfly effects (moving the behind-spawn retries changed one 28 km run's lane-change rate by 24%). So the reference (`TrafficMetricsReference`, `reference`) sums 16 runs on the 3-lane road, legs 1-8 of 1.5 km each (192 km, about 3 minutes), which brings the noise to about 4-5%. It runs in the soak tier (`soak_metrics_reference_matches_baseline`, plan §6); the fast tier checks the pipeline on one short run (`test_metrics_pipeline_on_a_short_run`: every metric present, finite and plausible). A metric beyond `traffic.metrics_tolerance_pct` (15%) of the baseline, or any change from an exact 0, fails. After a deliberate traffic change, rewrite the baseline with `tools/soak.sh --update-baseline` and commit it with the change.

Baseline (`tests/baselines/traffic_metrics.json`, seed 3303, 16 runs, 3 lanes):

| Metric | Baseline |
| --- | --- |
| `gaps_per_km` | 8.65 (WP6.2: 8.36, WP4.8: 10.53, WP3.3: 8.34) |
| `lane_changes_per_vehicle_min` | 1.029 (0.766, 0.677, 0.709) |
| `mean_speed_kmh_lane_0` / `_1` / `_2` | 139.2 / 127.1 / 115.6 (125.7 / 116.5 / 106.4; 123.8 / 113.2 / 101.8; 124.6 / 115.4 / 103.4) |
| `set_pieces_per_leg` | 0.031 (0.023, 0, 0) |
| `density_per_km_lane` | 10.00 (9.70, 11.87, 9.67) |

(192 km, flow speeds 145 / 120 / 95 km/h.) **WP6.6 rewrote the baseline** (plans D15 and D17, deliberate; see *D15 / D17 soak (WP6.6)* below); the earlier values are in brackets. WP6.2 rewrote it before (see *WP6.2: the director*), and WP4.8 (plan D11) before that: the density ramp ends at 18 per km per lane, the director tops up and tracks the window, and late legs drive closer. See docs/SPAWNING.md, *Density (D11)* and *Fast traffic and density*.

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

## D11 soak (WP4.8: density)

`tools/soak.sh --km=10000 --shards=4` with WP4.8's traffic: density 8 → 18 per km per lane, the band top-up and the density gain, IDM T × 0.8 at leg 8, cap 90, and the camera-independent behind-spawn view test. Same seed, bot and oracle as above. A later `--km=224 --compare-with` run on the final tree (WP4.5 merged, the camera-independent view test) gave identical traces for all 8 common runs, so these results hold for it.

| | |
| --- | --- |
| Distance | **10,024 km** in 358 runs (5,040 km on 3 lanes, 2,492 km on 2 lanes, 2,492 km on 4 lanes), 83.7 simulated hours |
| Wall time | 4,278 s (71 min) on 4 shards, 8,435 km per wall hour |
| Active vehicles | Mean 48.5 (before: 40.8). By lane count: 34 / 49 / 64 on 2 / 3 / 4 lanes. Peak 90, at the cap in 0.44% of the 4-lane ticks (321 planned vehicles thinned). |
| Traffic tick (4 processes in parallel) | 153 µs per `TrafficSim.step` on average (109 / 154 / 206 µs on 2 / 3 / 4 lanes). The director takes 28-41 µs. |

| Counter | Total | Gate |
| --- | --- | --- |
| Traffic-to-traffic collisions | 0 | ✅ 0 |
| Signal-time violations | 0 (of 180,171 lane moves, 191,795 signals, 8,128 cancels) | ✅ 0 |
| Unsignaled lateral moves | 0 | ✅ 0 |
| No-ambush violations | 0 (173,166 moves checked) | ✅ 0 |
| Deceleration beyond 6 m/s² | 0 (min accel −6.00) | ✅ 0 |
| Brake-light flag mismatches | 0 | ✅ 0 |
| Rear-ends of a normally driving player | 0 (136 rear-end contacts, all after the bot's own move or hard braking) | ✅ 0 |
| Impossible windows (traffic) | **2**: one on 3 lanes, one on 2 lanes (0 on 4 lanes). Details below. | ❌ 1 on 3 lanes |
| Impossible windows (player-induced) | 100 | reported |
| Unfinished runs / engine errors | 0 / 0 | ✅ |

Director: 74,311 ahead spawns (top-ups included), 9,200 behind spawns and 61,300 despawns. Refused: 321 at the cap, 73 in the ghost zone and 8,779 by the commit re-check; no ahead or behind spawn was refused as visible. Sim cancels: 839 for the player, 626 Hesitant, 6,663 unsafe.

Metrics by lane count (whole soak): gaps per km 11.9 / 11.1 / 10.8, density 13.2 / 12.4 / 12.2 per km per lane, lane changes per vehicle-minute 0.45 / 0.66 / 0.97, on 2 / 3 / 4 lanes.

**The two traffic windows** (replayed from their run seeds):

| Run | Lanes | Situation | Why no path |
| --- | --- | --- | --- |
| 325 (leg 4, t = 390 s) | 3 | The weaving bot, at 125 km/h, is **in the middle of its own lane change** from lane 0 to lane 1 (lateral speed 5.3 m/s, `player_moved_s_ago` = 0.008 s). A commuter at 101 km/h, 1.2 m ahead (centers), is already moving from lane 2 into lane 1: it has been moving since about 0.9 s before the bot started. Its lane change was legal: it started first, so no-ambush was satisfied. The bot's lane choice only looks at vehicles' current `d`, not at a car already merging into its target lane. | Both converge on lane 1 side by side. The lateral clearance is 0.68 m (above the 0.3 m clearance, so the oracle does not count it as the player's own cut-in), and every path touches a hull within 0.33 s |
| 146 (leg 1) | 2 | The bot is at 101 km/h, 1.0 s after its own lane change, behind a cruiser at 87 km/h that is signaling into the other lane | The 2-lane "slow wall" of D12: the player may not drop below 100 km/h |

Both follow the bot's own lateral move, like the three 2-lane windows of the WP3.3 soak. The 3-lane one is a cut-in into the path of a car that was already merging: the contact would be the player's doing ("the player caused it"). Under the oracle's pre-registered rule it still counts as a traffic window, because the player was not yet within 0.3 m of the car at t0. **This was not reclassified here** (it would redefine the gate after seeing the result). See *Findings* point 1 for the option already on the table: counting windows that start during or right after the player's own lateral move as player-induced. For this window, the narrower "the player's lateral move is in progress and the other car's lane change started first" would also apply. The orchestrator decides.

## WP6.1: passability, the bot driver and the gate (pre-registered before the run)

Written before the WP6.1 soak was run; the results section below was added afterwards.

**The bot driver.** The soak's player is now `PassabilityBot` (`tests/soak/passability_bot.gd`), "the same module ... with a bot driver" (spec, *Passability guarantee*). Every 0.5 s it runs `Passability.check_player` from its exact state and drives the path it found (re-extracted with its own target speed and target lane: weaving legs pick a random target lane every 2-6 s, lane-keeping legs keep theirs). Without a path it holds its lateral position and follows the car ahead with IDM, and counts `bot_no_path_checks`. The director checks every committed batch (`TrafficDirector.set_player_params`). The metrics reference and the density survey keep the WP3.3 weaving bot (`TrafficSoakRun.BOT_WEAVE`), so their baselines stay comparable. The impossible-window checker is unchanged and shares no code with `passability.gd`.

**Classification rule (pre-registered).** A window stays a *traffic* window (the gate) unless one of these holds at the failed check that starts it:

1. *Contact* (unchanged since WP3.3): the player is already within the clearance of a hull.
2. *Player cut-in* (new): the player entered its current lane less than `CUT_IN_WINDOW_S` = 2.0 s earlier (its body started overlapping that lane; a half-lane move included), and at that entry either
    - the bumper gap to the vehicle ahead in that lane was under `CUT_IN_HEADWAY_S` = 0.8 s at the player's speed, closer than any traffic driver follows (the shortest IDM time headway in play: aggressive 1.0 s × the leg-8 headway scale 0.8), or
    - the vehicle behind in that lane was closing faster than it can brake away within the gap at the traffic's 6 m/s² clamp: closing² / (2 × 6) > gap.

Justification: the spec's fairness rule "If the player cuts in front of a faster car with an impossible gap, the resulting contact counts as a hit, because the player caused it" puts the consequences of an impossible cut-in on the player. The second bullet is that rule, measured the way the traffic's own model would fail (IDM braking is clamped at 6 m/s²). The first bullet is its mirror image: entering behind a car closer than any traffic driver would follow it is also a gap no driver would accept. 2.0 s = the longest player lane change (~1.2 s) plus the shortest traffic headway (0.8 s): the window must follow directly from that entry. Windows under rule 2 are reported as `impossible_player_cut_in`, not gated. The raw count is reported too.

### Trial runs (before the full soak)

A first 252 km trial (4 shards) found 5 traffic and 4 player-induced windows on 2 lanes: the bot rode 0.3 m behind the car ahead (the search's relaxation allows any speed down to the minimum at once), and one leader braking left it without a path. The bot now keeps a 1.0 s headway in its path choice (`PassabilityBot.HEADWAY_S`, `Passability.extract_path(..., headway_s)`); the second 252 km trial had 0 windows and 0 contacts. The full soak below was run after that and not tuned on.

### Results: the WP6.1 10,000 km soak (before the WP6.2 merge)

`tools/soak.sh --km=10000 --shards=4`, the passability bot, the director checking every batch. The shards were killed twice by container restarts (after 274 and 336 runs); the missing runs were run again with `soak_main.gd --runs=...` into extra shard files and merged with `tools/soak.sh --merge`. 22 runs happened to be run twice, once before and once after merging the integration branch (WP6.4 biomes, road generation): **all 22 traces identical**, so the results hold for the merged tree.

| | |
| --- | --- |
| Distance | **10,024 km** in 358 runs (5,040 km on 3 lanes, 2,492 km on 2 lanes, 2,492 km on 4 lanes), 78.3 simulated hours |
| Throughput | ~9× real time per process (the container was shared with other agents: 1.6-2.4× slower than the D11 soak's 20.7×; the bot's checks add ~20%) |
| Active vehicles | mean 48.4 (34 / 49 / 65 on 2 / 3 / 4 lanes), peak 90 |

| Counter | Total | Gate |
| --- | --- | --- |
| Traffic-to-traffic collisions | 0 | ✅ 0 |
| Signal-time violations / unsignaled moves / no-ambush violations | 0 / 0 / 0 (168,070 lane moves, 162,024 checked for ambush) | ✅ |
| Deceleration beyond 6 m/s², brake-light mismatches | 0, 0 (min accel −6.00) | ✅ |
| Rear-ends of a normally driving player | 0 | ✅ 0 |
| Contacts with the player | **0** (D11 soak: 136 rear-end contacts, all after the weaving bot's own cut-ins) | reported |
| Impossible windows (traffic) | **0 on 3 lanes, 0 on 4 lanes, 4 on 2 lanes** | ❌ 2 lanes |
| Impossible windows (contact / pre-registered cut-in rule) | 0 / 0 | reported |
| Impossible checks failed | 12 of 281,756 | reported |

Bot: 597,637 passability checks (6.4 / 9.0 / 13.1 ms average on 2 / 3 / 4 lanes, in the shared container), 13 without a path (10 on 2 lanes); mean speed 116 / 129 / 140 km/h on 2 / 3 / 4 lanes. Director: 36,480 ranges checked (21,524 probes), 42 checks failed, 36 re-rolls, 2 removals, 4 ranges unresolved (all on 2 lanes: the failing probe lay before the range, behind vehicles already within min_ahead, so nothing could be removed); 0 spawns refused as visible; the longest check took 51 ticks (a re-roll storm), 9-10 otherwise. Metrics per lane count are within 1% of the D11 soak (gaps per km 12.0 / 11.2 / 11.1, density 13.3 / 12.5 / 12.4).

**The D11 3-lane window** (the bot cutting into a lane a commuter was merging into) and the **D12 2-lane cut-ins** do not occur: the passability bot never enters a gap its prediction shows closing (moving and signaled lane changes occupy both lanes), and keeps a headway. The pre-registered cut-in rule classified nothing.

**The four 2-lane windows** (runs 134, 158, 206, 338; legs 6-8) are all the same situation: the bot is at exactly 100 km/h in lane 0, behind lane-0 traffic at 92-98 km/h (commuters, aggressives, a hesitant: desired speeds 105-160 km/h), with lane 1 at 85-95 km/h; the oracle's path ends 7-8 s ahead (the bot closing at 1-3 km/h). On a 2-lane road the right lane flows at 95 km/h, below the minimum speed, so lane 0 is the only lane at or above it; at leg 6-8 densities (18 per km per lane, IDM headway × 0.8) lane 0's braking waves and cut-ins from lane 1 carry it below 100 km/h for a while. Replaying run 206: every lane-0 vehicle in the 800 m ahead has a desired speed ≥ 105 km/h (no slow vehicle had moved into lane 0); the platoon is simply compressed. This is not the player's doing, and neither the director nor the bot can prevent it: it forms in view, long after the batches were checked, and the bot is already at the minimum speed.

A local experiment (not committed) forbidding vehicles with a desired speed below the minimum from entering the only lane at or above it (a traffic_sim MOBIL rule, the D12 suggestion) did not help: 2 windows in 1,428 km of 2-lane runs, the same compressed platoons. The fix is a 2-lane traffic decision for the orchestrator (not in WP6.1's paths), e.g. a lower density cap or a higher right-lane flow speed on 2-lane roads, or a lower minimum speed there. See docs/PASSABILITY.md, *Open*.

## WP6.2: the director (waves, rule 6, set pieces, lane drops)

**What changed in the soak.**

- `TrafficSoakRun` hands the director the run's event buffer, feeds every `set_piece_warning` to the rule checker (rule 4 exception, see *Checks*), and records set pieces: spawned (`set_pieces`, the metric), started, how they ended (`set_pieces_passed`, `_unmet`, `_ended_zone`, `_ended_duration`, `_ended_empty`) and the director's peak counters (`peaks_seen`, `peaks_no_chance`, `peaks_no_kind`, `peaks_missed`, `peaks_unfit`). `tools/soak.sh` prints them on one line.
- New gate `offroad_violations` (no vehicle outside the driving lanes, which follow a lane drop's taper) and `merges` (mandatory merges out of ending lanes, reported).
- `soak_canyon_lane_drops` (soak tier): two 28 km journeys on the canyon biome, whose tunnels drop 3 → 2 lanes; every gate, and at least one merge.

**Why the baseline moved** (16-run reference, WP4.8 → WP6.2):

| Metric | WP4.8 | WP6.2 | Change |
| --- | --- | --- | --- |
| `density_per_km_lane` | 11.87 | 9.70 | −18 % |
| `gaps_per_km` | 10.53 | 8.36 | −21 % |
| `lane_changes_per_vehicle_min` | 0.677 | 0.766 | +13 % |
| `mean_speed_kmh_lane_0/1/2` | 123.8 / 113.2 / 101.8 | 125.7 / 116.5 / 106.4 | +1.5 / +2.9 / +4.5 % |
| `set_pieces_per_leg` | 0 | 0.023 (3 pieces in 128 legs) | new |

- **Waves.** Density follows the intensity curve: breathers at `wave_breather_density_pct` (50 %), builds from 87.5 %, peaks at 125 % (capped by IDM at the late legs). The reference drives 1.5 km legs, and every leg ends with a 10-15 s checkpoint breather (440-670 m at the 160 km/h reference pace), so about a third of each reference leg is breather: the reference sees more breather than a real 3.5 km+ leg does.
- **Rule 6.** Density is capped at 60 % where the player meets traffic just beyond a blind crest or bend (small on the reference's 3-lane road).
- **Set pieces** clear their zone of hidden traffic (and, in their lanes, of slower traffic they would catch up with).
- Fewer vehicles give fewer enterable gaps per km and faster lanes; with more room, MOBIL finds more worthwhile lane changes per vehicle.
- **Set pieces per leg is low in the soak** because the bot is slow for them: pieces run at 105 (truck wall) and 125 km/h (rolling roadblock), and a peak only gets a piece the player would reach within 75 % of its `approach_max_s` at the smoothed pace. The bot's pace in traffic is mostly 100-140 km/h, so most peaks are `peaks_missed`. A player at 170-200 km/h meets one at most peaks (`test_no_set_pieces_in_blind_windows_or_at_checkpoints`, `test_no_set_piece_the_player_would_not_meet`). Before the meet-time check, the soak spawned 5× as many pieces (0.117 per leg) and most were never reached (8 of the first 9 in a 1,000 km soak never started): they only took traffic away.
- The metric is a count of a few pieces over 128 legs, so ±15 % is one piece: any change that moves one piece fails the comparison. That is deliberate (it is deterministic), but the baseline update will be routine whenever the director changes.

**The 1,000 km soak** (`tools/soak.sh --km=1000 --shards=4`, the final WP6.2 tree merged with the integration branch; a later `--km=112 --shards=2 --compare-with` after the last merge gave identical traces for the 4 common runs):

| | |
| --- | --- |
| Distance | **1,008 km** in 36 runs (504 km on 3 lanes, 252 km on 2, 252 km on 4), 8.25 simulated hours, 0 unfinished |
| Wall time | 1,499 s on 4 shards, on a container shared with other agents (2,421 km per wall hour) |
| Gates | collisions 0, signal 0, unsignaled 0, no-ambush 0 (16,075 moves checked), decel 0 (min −6.00 m/s²), brake flags 0, rear-end of a normal player 0, impossible (traffic) 0, **offroad 0**: **GATE PASSED** |
| Reported | 3 impossible windows, all player-induced; 10 contact episodes, all caused by the bot; peak 88 active |
| Set pieces | 324 peaks: 137 lost the chance roll, 173 missed (the bot too slow to meet a piece), 2 did not fit the road; **11 spawned** (9 truck walls, 2 rolling roadblocks), 3 started, 1 passed, 4 unmet, 2 timed out after starting (the lane-keeping bot stays behind the wall), the rest still live when their runs ended. 0 hard decelerations (neither piece asks for them; rule 4's exception is covered by `test_set_piece_source.gd`). |

`soak_canyon_lane_drops` (2 × 28 km on the canyon road): 91 and 93 mandatory merges, every gate 0, offroad 0, one player-induced window. Cars that find no gap wait at the end of the lane (seen at 0-5 km/h in that window's snapshot, lane 2, 230-250 m ahead of the player).

## D15 / D17 soak (WP6.6: fast traffic, density rebalance)

`tools/soak.sh --km=2000 --shards=4` with WP6.6's traffic (the racer, wider spreads, flows 95 / 120 / 145 / 160, jitter; D17: breathers 70 %, T × 0.55 at leg 8, gain up to 1.8) on the integration branch with WP6.2 (before WP6.5's merge; WP6.5 adds no forks to the soak's road). Container shared with other agents (load 6-9 on 4 cores). After merging WP6.5, `tools/soak.sh --km=500 --shards=4` passed every gate (504 km, 18 runs: 0 traffic windows, 9 player-induced) and its 18 traces are identical to the same runs of the 2,000 km soak, so the results below hold for the merged tree.

| | |
| --- | --- |
| Distance | **2,016 km** in 72 runs (1,008 km on 3 lanes, 504 km on 2, 504 km on 4), 15.4 simulated hours, 0 unfinished |
| Wall time | 1,988 s on 4 shards (3,651 km per wall hour) |
| Active vehicles | mean 42.3, peak 90 (the cap) |

| Counter | Total | Gate |
| --- | --- | --- |
| Traffic-to-traffic collisions | 0 | ✅ 0 |
| Signal-time violations | 0 (39,890 lane moves checked, 43,566 signals, 1,768 cancels) | ✅ 0 |
| Unsignaled lateral moves | 0 | ✅ 0 |
| No-ambush violations | 0 | ✅ 0 |
| Deceleration beyond 6 m/s² | 0 (min −6.00) | ✅ 0 |
| Brake-light flag mismatches | 0 | ✅ 0 |
| Rear-ends of a normally driving player | 0 (67 rear-end contacts of 73 episodes, all after the bot's own move or hard braking) | ✅ 0 |
| Off-road | 0 | ✅ 0 |
| Impossible windows (traffic) | **1**, on a 2-lane road (0 on 3 and 4 lanes) | ❌ reported (WP6.1) |
| Impossible windows (player-induced) | 60 | reported |

Set pieces: 33 spawned (652 peaks: 265 lost the chance roll, 329 missed, 16 unfit), 15 started, 14 passed; 0 hard decelerations. Director: 13,388 ahead and 2,326 behind spawns, 2,043 refused by the live-gap re-check; sim cancels 1,525 unsafe, 160 for the player, 83 Hesitant.

**The traffic window** (run 26, leg 3, 2 lanes, t = 279 s): the weaving bot at 93 km/h (below the 100 km/h minimum), 0.008 s after starting its own lane change into lane 1, with a cruiser at 86 km/h 7 m ahead moving between the two lanes and another at 95 km/h 126 m ahead: the 2-lane "slow wall" of D12 (a slow car's lane change spans both lanes while the player may not drop below 100 km/h). Not a fast-traffic pattern; WP6.1's passability owns it (the brief: report, don't fix here).

Metrics by lane count (whole soak): mean speed per lane 120.6 / 105.7 (2 lanes), 139.5 / 127.5 / 116.0 (3 lanes), 147.6 / 139.9 / 127.7 / 120.4 (4 lanes); density 11.6 / 10.9 / 11.0; lane changes per vehicle-minute 0.72 / 1.02 / 1.22.

**Why the baseline moved** (16-run reference, WP6.2 → WP6.6):

| Metric | WP6.2 | WP6.6 | Change |
| --- | --- | --- | --- |
| `mean_speed_kmh_lane_0/1/2` | 125.7 / 116.5 / 106.4 | 139.2 / 127.1 / 115.6 | +10.7 / +9.1 / +8.7 % |
| `lane_changes_per_vehicle_min` | 0.766 | 1.029 | +34 % |
| `density_per_km_lane` | 9.70 | 10.00 | +3 % |
| `gaps_per_km` | 8.36 | 8.65 | +3 % |
| `set_pieces_per_leg` | 0.023 (3 pieces) | 0.031 (4 pieces) | one piece more |

- **Speeds:** faster left lanes (145 and 120 km/h instead of 135 and 115 on 3 lanes), the racer, the wider commuter and aggressive ranges. The bot drives the reference 5 % faster (5,171 instead of 5,463 simulated seconds for the same 192 km).
- **Lane changes:** racers and aggressive drivers change lanes twice as often as a commuter, and the fast share grew (15 → 35 % where they may drive), so more vehicle-minutes belong to frequent changers; wider speed spreads also give MOBIL more worthwhile moves.
- **Density and gaps:** D17's shallower breathers and closer late-leg following bring back what the faster lanes cost (docs/SPAWNING.md, *Fast traffic and density*).

## WP6.8: lane-drop safety (the canyon's 3 → 2 drops)

WP6.3's all-pieces soak found traffic-to-traffic collisions at the canyon's lane drops before tunnels, with no set piece involved (docs/SET_PIECES.md, *Soak (WP6.3)*): cars queued at a standstill at the end of the dropping lane and merged from 0 km/h beside lanes at 130–190 km/h, MOBIL's safety check saw only the nearest follower, and the checker turned a nearly stopped car's box sideways. WP6.8's fixes are in docs/TRAFFIC.md, *Lane drops (WP6.8)*. The checker's box heading is now clamped to ±0.28 rad (`TrafficRuleChecker.box_yaw`); the boxes still move with `d`, so a body overlap still counts (`test_rule_checker_box_heading_for_slow_lateral_movers`).

**Before** (the integration branch at WP6.8's start, same seeds, the same checker as before the clamp): `--canyon` runs 0–17 (504 km): **53 collision pairs** (runs 1 and 12, both at the end of a dropping lane: a stopped queue merging at once, and a coach merging at 3 km/h next to a racer). The all-pieces canyon runs 49 and 53: **132 and 55 pairs**. WP6.3 measured 136 (`--km=500 --canyon`) and 195 (all-pieces) before the unlock-order change it made last.

**After:** `tools/soak.sh --km=1000 --shards=4 --canyon` on the final tree (merged with the integration branch):

| | |
| --- | --- |
| Distance | **1,008 km** in 36 runs (all canyon, 3 lanes), 7.9 simulated hours, 0 unfinished; wall 1,064 s (container load 10–14) |
| Gates | collisions **0**, signal 0, unsignaled 0, no-ambush 0 (23,544 moves checked), decel 0 (min −6.00 m/s², 0 hard set-piece decelerations), brake flags 0, rear-end of a normal player 0, off-road 0, closed areas 0, impossible (traffic) **0**: **GATE PASSED** |
| Reported | 16 impossible windows, all player-induced (the weaving bot's own cut-ins); 24 contact episodes, none with a normally driving player; 4,307 mandatory merges; 74 tunnel squeezes, 0 collision pairs at a live piece; peak 72 active |
| Standstills | `standstill_beside_fast` **71** samples in 1,008 km (a vehicle below 15 km/h with one above 60 km/h in the next lane within 40 m, once a second). The four runs with the most before (28, 35, 4, 20; 112 km): **931 → 0**. What is left is the last resort: a platoon of the dropping lane reaching the end together beside a dense through lane, which then slows for them (the zipper) |

On the way (each a full 1,000 km canyon soak or a 2,000 km all-pieces soak, the traffic windows traced run by run): standstill queues and the rotated boxes gone, 0 collisions from the first run on; then the windows that were left, each a slow wall at a drop: a bus dropping back behind car after car to 66 km/h (the merge floor), booth traffic of a toll gantry pulling out at 50 km/h into a drop 650 m on (the hold behind booth speed zones), tunnel sections where trucks and cruisers fell back to 80–100 km/h in two lanes (the harmonisation now holds through the narrowed section), and the soak bot's own forced exit from a dropping lane 11 m behind a bus (it now leaves early, into a real gap). On the tree merged with WP6.7, two more windows, both the bot's: it swerved into a lane beside a lane-drop merger already moving into it 5 m ahead, and, where the dropping lane's early exit found no 1.5 s gap beside a dense through lane (at 80 km/h behind a truck and the zipper), its forced exit cut in 1.5 m behind a car 30 km/h slower; the bot now treats a moving car as in its target lane and waits for a 0.5 s gap on the forced exit (*Player* above). A zipper floor at 100 km/h for the through lane was tried and dropped: through lanes then stopped yielding, and the queues at the end of the lane came back (several times the standstill samples).

**Density at leg 8** (the D11 survey, `--density --lanes=3,4 --legs=8 --profile=scripted --seeds=4 --run-legs=4`; its procedural road has no lane drops), the integration branch with WP6.7 before and after WP6.8: identical, bit for bit, **15.05 per km per lane (84 %) on 3 lanes, 15.92 (88 %) on 4 lanes** (before WP6.7's merge, also identical: 15.18 / 15.92). The changes that reach roads without drops (the hidden-follower check, the zipper at set-piece closures) changed no decision there.

**Metrics baseline: updated, deliberately, for the soak bot.** WP6.7 had refreshed it (set pieces per leg 0.031 since the tunnel squeeze unlocks at leg 4; the racers from behind). WP6.8's traffic changes alone moved one of the 16 reference traces (run 4; the reference road has no lane drops, only set-piece closures) and every metric by less than 0.01 % (lane-1 speed 128.142 → 128.141 km/h). The bot's last change (it no longer weaves into a lane a car is already moving into, see *Player* above) changes where the weaving player goes in every run, so 9 of the 16 traces change and the metrics move by up to 2.3 %, all well inside the test's tolerances: density 10.05 → 10.24 per km per lane, gaps 8.70 → 8.89 per km, lane changes per vehicle-minute 1.146 → 1.120, lane speeds 142.8 / 128.1 / 113.9 → 142.9 / 128.0 / 115.3 km/h. The baseline was rewritten with `--metrics=all` on the final tree so the traces match it.

**Tick cost:** docs/TRAFFIC.md, *Lane drops (WP6.8)* (canyon +0 to +45 % per step, partly more vehicles near drops; farmland within the noise).

**The all-pieces gate** (`tools/soak.sh --km=2000 --shards=4 --all-pieces`). On the final traffic code and soak bot, two container restarts cut the runs short:

| | |
| --- | --- |
| Final tree (merged with the integration branch up to N3.2) | **1,904 km** of 2,016 (the soak was killed near its end), all runs finished before that counted: **all 0**: collisions, signal, unsignaled, no-ambush, decel, brake flags, rear-end of a normal player, impossible (traffic), off-road, closed areas. 91 impossible windows, all player-induced; `standstill_beside_fast` 111 |
| The same traffic code, merged up to Phase 7 audio | 756 km (27 runs) before the second restart: all 0 as above; 33 windows, all player-induced; `standstill_beside_fast` 21 |
| Before the WP6.7 merge and the last two bot changes | **2,016 km** in 72 runs (1,008 km on 3 lanes, a quarter of them the canyon's; 504 km on 2; 504 km on 4), 15.4 simulated hours, 0 unfinished: **all 0, GATE PASSED**. 59 windows, all player-induced; 82 contact episodes, none with a normally driving player; 2,046 mandatory merges; set pieces 313 spawned (toll gantry 235, tunnel squeeze 60, truck wall 8, merge zone 4, road works 2, slalom 2, convoy 1, rolling roadblock 1), 301 started, 240 passed, 0 unmet; 0 collision pairs at a live piece; `standstill_beside_fast` 31 |

WP6.3's all-pieces soak had 195 collision pairs and 1 impossible window in its canyon runs (docs/SET_PIECES.md); the intermediate WP6.8 all-pieces soaks had 0 collisions and 1–3 traffic windows (a toll's booth traffic merging into a drop, a two-lane tunnel slow wall, the bot's forced exit), fixed as above.

## WP6.1 after the WP6.2 merge (the final soak)

WP6.2 changed the traffic (intensity waves, set pieces, lane drops), so the WP6.1 gate was run again on the merged tree, same seed (20260928) and `tools/soak.sh --km=10000 --shards=4`. The classification rule is unchanged (pre-registered above).

**First run (soak b, merged tree).** 10,024 km: 3 lanes 0 windows, 4 lanes 1, 2 lanes 3, one window under the player cut-in rule, 2 rear-end contacts (none of a normally driving player), 1 signal violation. Replaying run 299 (the cut-in and one contact) found a passability bug. The bot lost its path mid-lane-change and froze astride two lanes. The next check snapped its start to the neighbouring grid positions and **exempted a fast car of the lane it had not entered** as a "follower" (vehicle 259, +26 km/h, 0.4 m behind), then drove into it. Fixes:

- a start state exempts only followers that overlap the player's **actual** body;
- the bot aborts a lost move to the lane holding its center instead of freezing.

A test fails without the first fix.

**Second run (soak c).** Also added TrafficSim's lateral anticipation of the player to the prediction. It produced a 3-lane window (run 112): the prediction had a lane-1 car braking for the player's move, the path then reversed the move, and the car never braked. That is an optimistic model error, so it was reverted: follower braking that depends on the path is not assumed.

**Final run (soak d, commit 86bcc9d), the reported result:**

| | |
| --- | --- |
| Distance | **10,024 km** in 358 runs (5,040 km on 3 lanes, 2,492 km on 2 lanes, 2,492 km on 4 lanes), 76.2 simulated hours, 5.2× real time per process (the container at load ~20 on 4 cores) |
| Gates | collisions 0, unsignaled 0, no-ambush 0 (153,676 moves checked), decel 0 (min −6.00 m/s²), brake flags 0, rear-end of a normal player 0, offroad 0; **signal 1** (below); **impossible (traffic) 5** (below) |
| Windows per lane count | **3 lanes: 0**, **4 lanes: 1**, **2 lanes: 4**; the cut-in rule classified none (0 player-induced) |
| Contacts with the player | 1 episode (rear-end, not normal driving) |
| Bot | 548,649 checks, 31 without a path (0.006%), never off the driving lanes (`player_offroad_ticks` 0) |
| Director | 34,368 ranges checked (172 with set-piece vehicles), 13 failed checks, 10 re-rolls, 3 removals, **0 unresolved** |
| Set pieces | 176 spawned, 81 started, 20 passed |

The failures:

- **2 lanes (runs 10, 18, 118, 258; legs 5-8): the D12 platoons.** "Slow wall" windows, the same situation as before the merge. Lane 0's compressed platoon runs at 95-98 km/h, and lane 1 flows at 82-88 km/h below the minimum speed. See the WP6.1 results above and docs/PASSABILITY.md *Open*: a 2-lane traffic decision.
- **4 lanes (run 247, leg 8): an oracle false positive.**
    - **The window:** the player is at 100 km/h in lane 0, 13 m behind a motorbike at 91 km/h, with lanes 1-2 busy.
    - **Why the oracle flags it:** it assumes every vehicle ahead keeps its speed, so the bike is a wall.
    - **What happened:** the bike's platoon (every vehicle in it desiring ≥ 140 km/h) was accelerating (91 → 97 km/h in 3 s). Passability's forward simulation (IDM) predicted that. Replay: the bot drove the whole window in lane 0 at exactly 100 km/h, with a path at every check and no contact.
    - **Status:** it still counts under the pre-registered rule (not reclassified). It is evidence for making the oracle's traffic prediction model acceleration.
- **Signal violation (run 113, t = 95.4 s): not WP6.1.** A set-piece truck (FLAG_SCRIPTED) began signalling while ticking at the far rate (FLAG_FAR), became near mid-signal, and moved after 0.983 s < 1.0 s. No passability check failed in that run, so the director did exactly what it does without passability. For WP6.2 / TrafficSim: the signal timer across the far → near tick change.
- **Contact (run 99): the bot's own braking.** The search allows any speed down to the minimum at once (the spec's "anywhere from minimum speed to current speed plus acceleration", a relaxation). The bot drove a path that dropped from 117 to 100 km/h within one 0.25 s step, and a motorbike braking at −6 m/s² behind it touched it. Not normal driving (`rear_end_normal` 0).

The canyon soak (lane drops, 2 × 28 km) on the merged tree: 0 windows, 0 contacts, 0 bot checks without a path, the player never off the driving lanes, 0 failed batch checks.

## WP6.1 after the WP6.3 / WP6.6 merges (the gate result)

The integration branch brought WP6.3's set pieces (road works, merge zones, tolls, tunnel squeezes, with sim lane closures and speed zones) and WP6.6's faster traffic (racers, D17). Passability now reads the sim's closures and speed zones (docs/PASSABILITY.md). The gate soak ran on 3753cf9 (`tools/soak.sh --km=10000 --shards=4`, seed 20260928). Container restarts cut it three times, so the missing runs were resumed with `soak_main.gd --runs=...` (tests/out/soak_wp61e, _f, _g). The later merges (to e371593, then 007448c) changed no traffic, road, soak or tuning code that the soak runs (audio, net, loop, run.gd and server only), so the per-run traces are the same on the final tree. The last segment was capped at 30 minutes (orchestrator), which left 41 of the 358 runs unrun.

| | |
| --- | --- |
| Distance | **8,876 km** in 317 of 358 runs: 4,424 km on 3 lanes, 2,324 km on 2 lanes, 2,128 km on 4 lanes; 64.2 simulated hours |
| Gates | collisions 0, signal 0, unsignaled 0, no-ambush 0 (175,942 moves checked), decel 0, brake flags 0, rear-end of a normal player 0, offroad 0, closed areas 0; **impossible (traffic) 1** |
| Traffic windows per lane count | **3 lanes: 0** (4,424 km), **4 lanes: 0** (2,128 km), **2 lanes: 1** (run 10, leg 6: the D12 slow wall, every lane below the minimum speed ahead) |
| Other windows | 4 that start in contact with the player (runs 7, 113, 128, 241): the oracle's pre-registered rule 1, player-induced. The cut-in rule classified none |
| Contacts with the player | 6 episodes (5 rear-end), **0 of a normally driving player** |
| Bot | 462,227 checks, 99 without a path (0.02%), never off the driving lanes, 0 prop hits |
| Director | 30,432 ranges checked (167 with set-piece vehicles), 0 failed checks, 0 re-rolls, 0 removals, 0 unresolved |

Not counted: run 334 (2 lanes, leg 2) was running when the 30-minute segment was stopped. Its shard log showed one window, which was lost with the unfinished run and not classified.

The contacts and the in-contact windows follow the bot's own driving at the WP6.6 / D17 speeds (up to ~250 km/h). The search's braking relaxation lets a path drop to the minimum speed within one step (docs/PASSABILITY.md, *Open*), and racers arrive from behind at up to +60 km/h. None involves a normally driving player.

Spot checks on the merged tree (reported, not gated):

- Canyon, 2 × 28 km of lane drops: 0 windows, 0 contacts, the player never off the lanes.
- `--all-pieces`, 3 runs, 84 km: 1 window at a toll gantry. The bot at 246 km/h braked 238 → 100 km/h in 0.3 s under the relaxation, drove a 50 km/h booth lane, and lost its path moving to the express lane.


## WP6.10: Phase 6 cleanup and the M6 gate soak

**What changed** (all before the gate soak unless marked):

- **TrafficSim signal timer** (the WP6.1 soak's signal violation, run 113): a lane change a set piece requests between ticks on a far vehicle no longer counts the 30 Hz accumulation from before the blinker as blinker time (docs/TRAFFIC.md, *Telegraphing and execution*).
- **The oracle** models lane ends, the sim's closures, speed and lane-drop zones, and bounded traffic acceleration (definition above). The classification is unchanged (contact at t0, the pre-registered cut-in rule); a player whose body is already in a closed lane or beyond the right edge at t0 is "in contact" with that static obstacle (`impossible_in_closure`, a subset of `impossible_player_induced`). New tests in `test_impossible_window_checker.gd` (lane end, lane opening ahead, sim closure and its half-lanes, a player inside a closure, speed zones, the accelerating platoon of the WP6.1 false positive, a queue never passing its leader); each fails on the old oracle. Cost: 13-31 ms per check in the gate soak (2, 3, 4 lanes, the container at load 6-10), about twice the constant-speed oracle; at 1 Hz it is a few percent of a run.
- **`tools/soak.sh`** sums and prints the per-run counters (see *Commands*).
- **The soak bot at toll gantries** (after the gate soak, below): `PassabilityBot` reads a toll's booth lanes as closed from 250 m before their traffic falls below the minimum speed (`PassabilityBot.BoothClosures`, like a player reading the TOLL legends), and leaves a lane that ends, closes or turns into a booth lane early: it first tries a check pinned one step into the half-lane move toward the open lane (a one-step lateral head start) and prefers that lane's pace. `test_passability_bot_booths.gd`.

### The gate soak (`tools/soak.sh --km=2000 --shards=4 --all-pieces`, commit efc4644)

Seed 20260928, the passability bot (`soak_main.gd` always runs `BOT_PASSABILITY`), 2,016 km in 72 runs, 14.8 simulated hours, wall 2,321 s (the container shared with other agents, load 6-10).

| Counter | 2 lanes (504 km) | 3 lanes (1,008 km) | 4 lanes (504 km) | Gate |
| --- | --- | --- | --- | --- |
| collision pairs, signal, unsignaled, no-ambush, decel, brake flags, rear-end of a normal player, off-road, closed areas | all 0 | all 0 | all 0 | ✅ |
| **impossible (traffic)** | 0 | **3** | 0 | ❌ |
| impossible windows (player-induced / in a closed lane / cut-in rule) | 0 (0 / 0 / 0) | 8 (5 / 1 / 0) | 2 (1 / 0 / 1) | reported |
| contacts with the player (rear-end) | 0 | 5 (4) | 2 (1) | reported |
| `standstill_beside_fast` | 0 | 47 | 6 | reported |
| `player_offroad_ticks` | 0 | 0 | 0 | reported |
| bot checks / without a path / ms | 27,991 / 3 / 8.5 | 53,677 / 161 / 11.9 | 24,762 / 71 / 17.7 | reported |
| director: checks, probes, failed, re-rolls, removals, unresolved, longest (ticks) | 1,733, 1,334, 6, 5, 0, **1**, 87 | 3,456, 2,682, 0, 0, 0, 0, 23 | 1,728, 925, 0, 0, 0, 0, 20 | reported |
| set pieces spawned / passed; merges; peak active | 67 / 48; 2; 67 | 176 / 138; 1,930; 82 | 78 / 53; 12; 90 | |

Min accel −6.00 m/s², 0 unfinished runs, 0 engine errors. Set pieces: 321 spawned (toll gantry 237, tunnel squeeze 60, truck wall 8, convoy 4, merge zone 4, slalom 4, road works 2, rolling roadblock 2), 303 started, 239 passed, 7 unmet, 0 hard decelerations, 0 collision pairs at a live piece.

**The three traffic windows** (runs 36, 44, 64; 3 lanes; legs 2, 4, 6; all at a toll gantry): the bot, 0.9-3.9 s after entering lane 0, at 68-84 km/h behind booth traffic at 50-62 km/h, with the express lane beside it at 110-130 km/h. Replayed (run 44): the bot drove booth lane 0 at 135 km/h with the express lane open beside it for 10 s (130 m gaps), because passability's path is extracted greedily (speed first; a lane change costs as much lateral preference at its first step as it gains, so the path stays in its lane until the last feasible step) and the search may brake to the minimum speed at once. At the booths it braked 135 → 100 km/h in 0.5 s, started for the express lane, lost its path and fell back behind the booth traffic. Both oracles (with and without the WP6.10 zone model) fail from that state. So the windows are the soak bot's driving at a toll (a player reading the TOLL legends takes the express lane), not a wall Flow built and not an oracle artefact; the pre-registered rules classify them as traffic windows and they were **not reclassified**.

**Fix (the bot, `tests/soak/passability_bot.gd`)** and re-run: all 36 three-lane runs of the gate soak with the fixed bot (`soak_main.gd --all-pieces --runs=...`, 1,008 km, 7.4 simulated hours): **every gate 0, impossible (traffic) 0**; 3 windows, all player-induced (contact at t0; runs 12, 44, 52); 4 rear-end contacts, none of a normally driving player; `standstill_beside_fast` 41; `player_offroad_ticks` 0; bot 53,349 checks, 39 without a path (was 161); director 3,456 checks, 0 failed. The 2- and 4-lane runs were not re-run (the 75-minute soak cap; the soak took 39 min, the diagnosis re-runs and the 3-lane re-run another ~40): their results above are from the gate commit, and the bot change can alter their traces (it acts wherever a lane ends, closes or has booths).

Before the bot fix, two intermediate versions were measured on runs 33, 36, 44, 64 (not committed): the booth closure alone removed the windows but left the bot in the booth lanes' fallback for 13 % of its checks (the path could only leave a lane at the last step, so it rarely got out); the pinned early move fixed that.

**Other nonzero counters:**

- `standstill_beside_fast` (47 + 6): the canyon runs (13, 17, 37, 5: tunnel lane drops, the WP6.8 zipper at the end of a dropping lane) and run 63 (4 lanes, road works). The WP6.8 residual (71 per 1,008 km of canyon soak); TrafficSim's lane drops, not in WP6.10's paths.
- The director's 1 unresolved range (run 62, 2 lanes, leg 7, s 23,944, player 130 km/h: 3 probes, 1 failed, 5 re-rolls, 87 ticks): the WP6.1 pattern, a failing probe starting before the range behind vehicles already within `min_ahead_m()`, which the director may not remove. No window followed.
- The D12 2-lane slow wall did not occur in these 504 km of 2-lane runs (0 traffic windows on 2 lanes). It is still open (docs/PASSABILITY.md, *Open*).
- The `impossible_in_closure` window (run 33, 3 lanes on the canyon road, leg 1, t = 19 s): the bot, mid lane change, with its body still in a lane the road drops (inside its closed taper). Player-induced under the new rule.
