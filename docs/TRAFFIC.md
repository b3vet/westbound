# Traffic simulation (WP2.4)

Traffic on the player's carriageway: IDM car following, MOBIL lane changes, the fairness rules, near/far ticks and reactions to the player. It implements the spec's *Traffic* sections (road-space simulation, IDM, MOBIL, fairness rules, driver types, traffic reacts to the player) and *Lives → Fairness rules*.

- **Code:** `src/traffic/traffic_sim.gd` (`TrafficSim`), `idm.gd` (`Idm`), `mobil.gd` (`Mobil`), `no_ambush.gd` (`NoAmbush`), `traffic_registry.gd` (`TrafficRegistry`). All pure `RefCounted`, allocation-free per tick.
- **Data:** `data/driver_profiles/*.tres` (8 `DriverProfile`s), `data/vehicle_types/*.tres` (10 `VehicleType`s), `data/tuning/traffic.tres` (`TrafficTuning`).
- **Tests:** `tests/unit/test_idm.gd`, `test_mobil.gd`, `test_traffic_sim.gd`; fixtures in `tests/fixtures/traffic/` (`TrafficScenario`, `TrafficBotPlayer`, `TrafficRuleChecker`).
- **Out of scope:** spawning policy and the director (WP2.5, WP6.x), rendering (WP3.1), scoring.

## API

```gdscript
var registry := TrafficRegistry.load_default(ctx.tuning.traffic)   # once per run
var sim := TrafficSim.new(ctx, road, registry)
sim.set_player_body(car.length_m, car.width_m)   # CarDef body; default TrafficTuning.player_length_m/width_m
sim.spawn(record) -> int                         # slot, or -1 only when full (no gap re-check: the director owns spacing)
sim.despawn(slot)
sim.step(dt, player_state, player_params, events) # 120 Hz, after vehicle physics (CONTRACTS §4 tick order)
sim.notify_hit(slot)                             # run.gd after collisions: swerve, hard brake, hazards, ~4 s recovery
sim.set_headlights(on)                           # follows the sun clock; spawns inherit it
sim.honk(slot, tag = TAG_HONK)                   # horn at the next step
sim.notify_close_pass(slot) -> bool              # scoring: honks close_pass_horn_pct (30%) of the time
sim.request_lane_change(slot, lane) -> bool      # scripted (set pieces, sandbox): same checks + telegraphing
sim.state                                        # the TrafficState (one stable instance, capacity = max_active_vehicles)
sim.leader_of(slot) / leader_gap(slot) / idm_accel(slot) / is_lane_splitting(slot) / player_index()   # sandbox overlays
sim.stat_*                                       # counters: signals, moves, completions, cancels by cause, model updates
```

- `spawn` copies the record: `s`, `lane`, `target_lane = lane`, `d` (NAN = lane center), `v`, `v0` (≤ 0 = middle of the profile's range), `type_id`, `profile_id`, `model_variant`, `color_index`, and `flags` (minus the state-derived bits `FLAG_FAR/HIT/BLINKER_*/BRAKE*`). `length`/`width` come from the vehicle type.
- `step`'s `player_params` is accepted for the frozen signature but unused: `VehicleParams` has no body size, so `set_player_body` supplies it.
- `registry.profiles` / `registry.types` are the stable-ordered resource lists (index = `profile_id` / `type_id`). The order is `TrafficRegistry.PROFILE_IDS` / `TYPE_IDS`; append only.

## Model

### One tick

`step` runs three passes over the vehicles, ordered by `s` (a persistent insertion-sorted index that includes the player):

1. **Integrate** every vehicle over `dt` with the acceleration decided at its last model tick (ballistic update; a vehicle never reverses).
2. **Accelerations** for the vehicles due this tick. Each finds its leader, gets the IDM acceleration, then reaction modifiers (brake tap, hit brake), then the clamp, then brake lights. Everyone, the player included, is at the same instant (the player has already moved this tick), so the steady gap behind the player is exactly IDM's.
3. **Lateral** for the vehicles due this tick: the lane-change state machine, hit recovery and reactions to the player.

**Near/far.** A vehicle more than `near_radius_m` (200 m) from the player is far: `FLAG_FAR` is set and steps 2 and 3 run at `far_tick_hz` (30 Hz) with the accumulated time. Step 1 still runs every tick, holding the last acceleration, so far vehicles move smoothly. The first 30 Hz update of each vehicle is staggered by `vehicle_id` to spread the load. Against a 120 Hz reference (free flow, 12 cars, 20 s), positions differ by at most 0.14 m and speeds by 0.016 m/s. Almost all of that comes from the stagger: up to 3 ticks at the spawn's zero acceleration.

### Lateral occupancy (the core idea)

Leaders are found by **lateral overlap in road space**, not by lane index:

- **Physical interval:** the body `[d - w/2, d + w/2]`. While MOVING it is widened to span to the move's target, so a car changing lanes is in both lanes and followers in both react to it.
- **Claim interval:** the physical interval, plus the target while SIGNALING. MOBIL's gap search uses claims, so two cars never pick the same gap. A lane-splitting motorbike claims half a lane on each side.
- **Player:** its body, stretched in the direction of its lateral velocity by `player_lateral_anticipation_s` (0.3 s). Traffic starts treating the player as its leader as soon as the player heads into the lane.
- **Overlap test:** two intervals count as the same path when they are closer than `lateral_margin_m` (0.2 m). That is below lane width minus the widest body (3.6 - 2.55 = 1.05 m), so trucks side by side don't follow each other.

**Leader search.** The search walks the sorted order ahead of the vehicle and stops at the first vehicle whose interval overlaps, or at `idm_lookahead_m` (400 m, which covers `s*` at the largest closing speeds). The typical cost is 1–3 steps.

**Lane geometry** (left edge, lane width) is read once per tick at the player's `s`. This is exact for fixture roads and the procedural road, whose cross-section is constant. Tapers (lane drops, WP6.3) will need per-`s` lane centers. That is a hook, not built yet.

### IDM (`Idm`)

The spec formula: `a = a_max [1 - (v/v0)^δ - (s*/s)^2]`, `s* = s0 + max(0, vT + vΔv / (2√(a_max b)))`, with δ = 4.

- **Determinism:** `(v/v0)^δ` is computed by repeated multiplication (`pow_int`), so it is bit-identical on every platform with no libm. `sqrt` is IEEE-exact.
- **Gap floor:** the gap is floored at `idm_gap_floor_m` (0.1 m) so contact never divides by zero.
- **Clamp (fairness rule 4):** the sim clamps deceleration to `max_decel_mps2` (6 m/s²). `FLAG_SCRIPTED` vehicles (set pieces, which must be warned 300 m or more ahead) use `scripted_max_decel_mps2` (9 m/s²) instead.
- **Brake lights (fairness rule 3):** `FLAG_BRAKE` when deceleration > `brake_light_decel_mps2` (1 m/s²), and `FLAG_BRAKE_STRONG` when > 4 m/s². The thresholds are exact, with no hysteresis. They reflect the acceleration applied from the next tick.

### MOBIL (`Mobil`)

Each vehicle evaluates MOBIL every `mobil_eval_interval_s` / `lane_change_frequency_scale` seconds (base 1 s; timers are staggered at spawn). A vehicle skips evaluation while signaling, moving, hit or scripted. After a lane change completes or is cancelled, it waits `lane_change_cooldown_s` (3 s) before evaluating again.

- **Incentive:** `(ã_c - a_c) + p[(ã_n - a_n) + (ã_o - a_o)] > Δa_th + a_bias`. Here `a_c` is the car's current IDM acceleration, `ã_c` is its IDM behind the new leader, `n` is the new follower (IDM with and without the car) and `o` is the old follower.
- **Keep-right bias (asymmetric):** the threshold is `Δa_th + a_bias` to the left and `Δa_th - a_bias` to the right. With `a_bias > Δa_th`, a free driver drifts back right.
- **Lane discipline (fairness rule 7):** the bias grows by `lane_discipline_bias_mps2` (0.3) in two cases: toward the right when the driver keeps right or its `v0` is below its lane's flow speed, and against a move left into a lane that flows faster than it wants. Lane flow speeds come from `lane_flow_speeds_from_right_kmh`. Keep-right profiles with `keep_right_lane_count > 0` (truck, bus: 2) never move left of their allowed lanes.
- **Safety:** the move is refused when any of these holds:
    - the new leader or new follower overlaps longitudinally (gap ≤ 0);
    - `ã_n < -b_safe`;
    - the car's own `ã_c < -b_safe`.
- **Player safety:** when the new follower is the player, `b_safe = min(profile b_safe, player_b_safe_mps2 = 2)`. The player's `ã_n` is IDM's interaction term with `player_idm_*` parameters (a = 2, b = 3, T = 1 s, s0 = 2 m), judged as if the player holds its speed.
- **No ambush:** checked on top of everything else; see below.

### Telegraphing and execution (fairness rule 1)

`NONE → SIGNALING → MOVING → NONE`:

1. **SIGNALING:** the blinker is on for the profile's signal time, floored at `signal_time_floor_s` (1.0 s; aggressive 0.6 s). Every model tick the move is re-checked:
    - If it fails because of the player (the player entered the target gap, or its predicted space), the car cancels immediately. The blinker goes off and the car stays in its lane (`stat_cancel_player`).
    - At the end of the signal time, a Hesitant car that rolled a cancel at signal start (`cancel_probability`, 0.2) cancels (`stat_cancel_hesitant`).
    - At the end of the signal time, a car whose move is unsafe because of traffic also cancels (`stat_cancel_unsafe`).
    - Otherwise the move starts (`lc_start_d` = d).
2. **MOVING:** `d = d0 + Δ·smoothstep(t/T)` over the profile's move time (2.0–3.0 s, aggressive 1.5 s). `v_lat = Δ·6u(1-u)/T` is set so the view can yaw the car (`atan2(v_lat, v)`). Lateral motion starts on the model tick *after* the transition, so blinker-to-motion is always at least the signal time. At 120 Hz it is the signal time plus up to 2 ticks; far away, plus up to 2/30 s. The final step lands exactly on the target with the blinker still on. The next model tick switches `lane` and turns the blinker off.
3. `lane` stays the origin lane until the move completes, and `target_lane` names the destination.

### No ambush (fairness rule 2, `NoAmbush`)

A car may not start a lane change into space the player is predicted to occupy within `no_ambush_window_s` (1.5 s). The definition used:

- **The car's target space:** its own body at the target `d`, moving along the road at its current speed.
- **The player's predicted space:** its body moving at its current road-frame velocity. That velocity is `s_dot` and `d_dot` from `v`, `v_lat` and `yaw`, with the curvature factor. The box is grown by `no_ambush_margin_m` (1.0 m) on every side.
- **Violation:** the two boxes overlap at some `t` in [0, 1.5 s]. Both move linearly, so each axis gives an exact open interval of `t`, and the predicate is their intersection with the window.

The check runs when signaling starts, on every model tick while signaling (a failure cancels the change), and at the start of the lateral motion. The test checker re-derives the rule independently. It samples `t` every 5 ms, uses the move's actual final `d`, and snapshots the states when motion starts.

### Driver profiles

These values are not in the spec except the desired speeds, signal times and move times; they are tuned in the sandbox. Motorbikes and Hesitant drivers are described in their own sections.

| Profile | Vehicles | v0 km/h | a_max | b | T s | s0 m | p | Δa_th | a_bias | b_safe | Signal s | Move s | Freq | Other |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| cruiser | sedan, hatchback | 80–100 | 1.2 | 2.0 | 1.6 | 2.5 | 0.6 | 0.3 | 0.5 | 3.0 | 1.0 | 2.5–3.0 | 0.5 | keep right |
| commuter | sedan, SUV, pickup | 100–130 | 1.5 | 2.0 | 1.3 | 2.0 | 0.3 | 0.2 | 0.3 | 3.5 | 1.0 | 2.0–3.0 | 1.0 | |
| aggressive | sports, coupe | 150–190 | 2.5 | 3.0 | 1.0 | 1.5 | 0.05 | 0.1 | 0.1 | 4.0 | **0.6** | **1.5** | 2.0 | |
| truck | semi (16 m) | 80–90 | 0.6 | 1.5 | 1.8 | 3.0 | 0.5 | 0.3 | 0.6 | 2.5 | 1.0 | 3.0 | 0.3 | keep right, right 2 lanes |
| bus | coach (12 m) | 85–95 | 0.8 | 1.5 | 1.6 | 3.0 | 0.5 | 0.3 | 0.5 | 2.5 | 1.0 | 2.5–3.0 | 0.4 | keep right, right 2 lanes |
| van | delivery van | 95–110 | 1.2 | 2.0 | 1.4 | 2.0 | 0.3 | 0.2 | 0.3 | 3.0 | 1.0 | 2.0–3.0 | 0.8 | |
| motorbike | motorbike | 110–150 | 2.5 | 3.0 | 1.0 | 1.5 | 0.2 | 0.1 | 0.2 | 3.5 | 1.0 | 2.0–2.5 | 1.5 | lane splitting |
| hesitant | any car | 90–120 | 1.2 | 2.0 | 1.5 | 2.5 | 0.5 | 0.2 | 0.3 | 3.0 | 1.0 | 2.0–3.0 | 1.0 | cancels 20%, `min_leg` 3 |

Units: accelerations in m/s², δ = 4 for all.

- **Vehicle types** (placeholders, no models yet): sedan 4.8 × 1.85, hatchback 4.2 × 1.8, SUV 4.9 × 1.95, pickup 5.4 × 2.0, van 5.9 × 2.05 (blocks sightlines), semi 16.0 × 2.55 (blocks), coach 12.0 × 2.55 (blocks), motorbike 2.2 × 0.8, sports 4.5 × 1.95, coupe 4.6 × 1.9 m. `allowed_profiles` follows the spec table, and Hesitant is allowed on every car.
- **Move times** are not scaled by `VehicleType.lane_change_time_scale`, which stays a player and Car Hopper physics knob, so traffic always meets the spec's 2.0–3.0 s.
- **Hesitant:** the sim honours `cancel_probability`. `min_leg` (3) is the director's concern.

### Motorbike lane splitting (implemented)

A `lane_split` profile can start a split only when MOBIL found no lane change and all of these hold:

- its leader is slower than `lane_split_max_traffic_kmh` (60 km/h) and within `lane_split_scan_m` (60 m);
- its own `v0` is higher than that;
- the player is **not** changing lanes nearby (`|d_dot| > lane_split_player_lateral_mps` (0.5 m/s) within `lane_split_player_range_m` (100 m) blocks it).

The split itself:

- **Entering:** the bike signals and moves (normal telegraphing) onto the lane boundary, the left one first.
- **While splitting:** its desired speed is capped at `lane_split_max_speed_kmh` (85 km/h). Its leader search uses `lane_split_clearance_m` (0.3 m), so it filters past cars, vans and pickups and follows anything wider (trucks, buses) or anything crossing its line (lane changers, the player).
- **Claims:** a splitting bike claims half a lane on each side, so no car changes lanes across it without a safety check against it.
- **Leaving:** when nothing within the scan range ahead in the two lanes is slower than 60 km/h, the bike returns (signaled) to its lane's center or the other lane's.
- **Readers:** `lane` stays the lane it came from, and `sim.is_lane_splitting(slot)` tells readers it is on the boundary.

### Reactions to the player (events)

The sim writes these into the caller's `ScoreEventBuffer` (`slot` = the car). The kind names equal the `Events` signal names, so the adapter maps each one directly:

| kind | tag | value | When | Adapter emits |
| --- | --- | --- | --- | --- |
| `&"traffic_brake_tap"` | `cut_in` | bumper gap (m) | The player becomes the car's leader less than `cut_in_brake_tap_distance_m` (10 m) ahead. The car brakes at `brake_tap_decel_mps2` (2 m/s², brake lights on) for `brake_tap_s` (0.5 s). | `traffic_brake_tap(slot)` |
| `&"traffic_horn"` | `blind_spot` | 0 | The player lingers one lane over, its center up to `blind_spot_behind_m` (6 m) behind the car's, for `blind_spot_horn_s` (3 s). Honks with `blind_spot_horn_pct` (50%, "occasional"). | `traffic_horn(slot, world_pos)` |
| `&"traffic_horn"` | `close_pass` / `honk` | 0 | `notify_close_pass(slot)` (rolls 30%) or `honk(slot)`, at the next step. | `traffic_horn(slot, world_pos)` |
| `&"traffic_hazards"` | `hit` | 1 on / 0 off | `notify_hit(slot)` (on, at the next step); recovery after `hit_recover_s` (off). | `traffic_hazards(slot, value == 1)` |

- **No night-tailgating high beams (plan D8, owner decision):** the spec's "high beams flash when the player tailgates" was a grammar slip. The reaction, its tuning (`tailgate_high_beam_*`, `high_beam_flash_s`) and its test were removed in WP3.3. The player gets a manual high-beam control in WP5.4. `FLAG_HIGH_BEAM` stays defined; the sim never sets it (a spawn record's own flag is kept), and `test_no_automatic_high_beams_at_night` pins that.
- **Re-arming:** each reaction re-arms on the same car after `reaction_cooldown_s` (6 s).
- **Hit reaction:** the car swerves `hit_swerve_m` (0.5 m) away from the player and back over `hit_swerve_s` (1.2 s). This is a smoothstep out-and-back, so the checker does not count it as a lane change. The car also brakes at least `hit_brake_decel_mps2` (5 m/s², strong brake lights) for `hit_brake_s` (1 s), shows `FLAG_HIT | FLAG_HAZARD`, and recovers after 4 s. A car already moving between lanes finishes its move instead of swerving.

### Flags set by the sim

| Flag | Set by |
| --- | --- |
| `FLAG_BRAKE`, `FLAG_BRAKE_STRONG` | Every model tick, from the acceleration |
| `FLAG_BLINKER_LEFT`, `FLAG_BLINKER_RIGHT` | SIGNALING and MOVING (lane changes and split moves) |
| `FLAG_HAZARD` | Hits (only cleared on recovery if the hit switched it on; a record's own hazards, e.g. a convoy, stay on) |
| `FLAG_HEADLIGHTS` | `set_headlights` |
| `FLAG_HIGH_BEAM` | Never set by the sim (D8); kept from a spawn record, reserved for later use |
| `FLAG_HIT` | `notify_hit` until recovery |
| `FLAG_FAR` | Every tick, from the distance to the player |
| `FLAG_SCRIPTED` | Never set by the sim; it only reads it (from the spawn record) |

### Determinism

All randomness uses streams derived from `ctx.rng_traffic`:

- `&"sim_lane_change"`: Hesitant cancels and move times;
- `&"sim_react"`: horn chances;
- `&"sim_spawn"`: MOBIL timer stagger at spawn.

Iteration order is the sorted-by-`s` order, with stable ties. The IDM power is multiplication-only. `TrafficState.trace_hash()` covers every published field.

## Tests

| Test | What it proves |
| --- | --- |
| `test_idm.gd` | The spec formula; free road reaches v0 monotonically; steady-state gap = IDM equilibrium ≈ s0 + vT; approach to a stopped leader from 20–45 m/s without contact, comfortably (never near the clamp); raw IDM exceeds the clamp in impossible cases |
| `test_mobil.gd` | Incentive math; asymmetric keep-right bias; b_safe and the player tightening to 2 (pure, and in the sim: a traffic follower at −3 m/s² allows the change, the player at the same geometry refuses it); the no-ambush predicate (closing speed, lateral drift, time-disjoint overlaps); overtaking a slow truck; cruisers drift right; trucks stay in their lanes |
| `test_traffic_sim.gd` | Profile data vs the spec table; spawn API; equilibrium gaps behind traffic and behind the player; free road → v0; stops behind a stopped player (single lane) without contact; impossible cut-in → exactly −6 m/s² and never beyond; brake-light thresholds every tick; signal, then smoothstep with v_lat; cancel when the player enters the gap; dense weaving rule checks; no rear-ending of a lane-keeping player; the Hesitant ratio; lane splitting (filters, stops behind trucks, never during the player's lane change, returns when traffic flows); every reaction; near/far vs a 120 Hz reference; the determinism trace; tick budget; no memory growth |
| `soak_*` | 3 × 10 min dense weaving (3 lanes, 150 km/h player), 10 min on 4 lanes with a 190 km/h player, 9 × 3 min lane-keeping players (3 lanes × 95/120/150 km/h), the Hesitant ratio over about 7,300 requested signals plus an organic run, and the tick-cost report |
| `test_traffic_integration.gd` | The real director + sim + bot on the procedural road (1 min fast, 3 × 10 min soak); the WP3.3 spawn hardening (lane changers and lane-splitting bikes occupy lanes, `s*` with the closing term, the commit re-check, behind-spawn back-off) |
| `tests/soak/`, `test_traffic_metrics.gd` | WP3.3: the 10,000 km soak harness (tiny version in the fast tier, one run per lane count in the soak tier, the full distance with `tools/soak.sh`), the impossible-window oracle, cross-shard determinism, the metrics baseline and the D7 cap runs. See [SOAK.md](SOAK.md) |

**The independent checker** (`TrafficRuleChecker`) reads only `TrafficState` and the player each tick. It checks:

- the signal time: blinker-on to first lateral motion ≥ the profile's signal time, and no unsignaled lateral motion;
- no-ambush, sampled against the move's final `d`;
- traffic-to-traffic collisions, with oriented boxes (yaw = `atan2(v_lat, v)`) inset by `lives.collision_inset_m` and a separating-axis test;
- the deceleration clamp;
- the brake-light flags against the acceleration;
- player contacts, including rear-ends by traffic: per tick, and per contact episode (WP3.3), where a rear-end counts against traffic only when the player neither moved sideways nor braked beyond the 6 m/s² clamp for `soak_normal_driving_quiet_s` (3 s) before it ("a player driving normally").

**The scenario spawner** (`TrafficScenario`) stands in for WP2.5. It keeps a target density (16 vehicles/km/lane) in [−200, +750] m, spawning ahead at lane flow speed with IDM spacing, and faster cars 150 m behind in the left lanes. It treats a car signaling or moving into a lane as already in it.

## Measured numbers

Measured in the headless dev container: Godot 4.7, Intel Xeon @ 2.10 GHz, one thread.

**Tick cost** (`WBBench`, the median µs per 120 Hz `step`, the player moving at 130 km/h; `soak_tick_cost_report` and `test_tick_cost_60_vehicles`):

| Vehicles | Lanes | Layout | Median µs/tick | Spread over runs |
| --- | --- | --- | --- | --- |
| 60 | 3 | spread −200..+750 m (about 35 far) | **~190** | 185–279 |
| 60 | 3 | all within ±190 m (jam, all near) | ~175 | 153–262 |
| 60 | 4 | spread | ~195 | 190–196 |
| 90 | 3 | spread | ~290 | 263–314 |
| 90 | 4 | spread | ~280 | 276–294 |
| 90 | 4 | all near | ~230 | 210–249 |

- **Scaling:** cost is roughly linear in vehicle count, about 3.2 µs per vehicle per tick.
- **Budget test:** 600 µs for 60 spread and 900 µs for all near, about 3× the median. `WB_BENCH_SCALE` scales both on slow runners.
- **Frame cost:** at 120 Hz, two ticks per 60 fps frame cost about 0.4 ms (60 vehicles) or 0.6 ms (90 vehicles) of a 16.7 ms frame on this CPU.
- **Phones:** a phone runs GDScript roughly 2–4× slower, which is about 0.8–1.6 ms (60) or 1.2–2.4 ms (90) per frame. This is sane, but it is not free; confirm it with the dev HUD on the iPhone 13-class device.
- **Plan §8 risk:** the budget is met; no GDExtension is needed.
- **D7 (cap 60 vs ~90):** resolved at 90 (D11, WP4.8). 90 vehicles cost about 1.5× the 60-vehicle tick: ~0.21 ms on the phone at the cap (extrapolated from 0.10 ms at 45 cars). See docs/SPAWNING.md, "Density (D11)".
- **Headroom, if phones need it** (no architecture change):
    1. integrate far vehicles only at their 30 Hz model tick and let the view extrapolate (step 1 is about a third of the tick);
    2. inline `Idm.accel` in step 2 (static calls are about 0.15 µs each);
    3. raise `far_tick_hz` spacing (15 Hz beyond 400 m).

**Memory:** `OS.get_static_memory_usage()` is unchanged over 600 ticks with 60 vehicles (`test_ticks_do_not_grow_memory`). The tick paths contain no allocating constructs (lint WB104 is clean).

**Rules and collisions** (independent checker; soak tier):

| Run | Lane moves | Signals / cancels | Violations (signal, unsignaled, ambush, clamp, brake flags) | Traffic collisions | Player rear-ended |
| --- | --- | --- | --- | --- | --- |
| 3 lanes, weaving player 150 km/h, 16 veh/km/lane, 3 × 10 min | 851 | 922 / 48 | 0 | 0 | 0 |
| 4 lanes, weaving player 190 km/h, 10 min | 524 | 569 / 34 | 0 | 0 | 0 |
| 3 lanes, lane-keeping player at 95/120/150 km/h in each lane, 9 × 3 min | 834 | 889 / 33 | 0 | 0 | 0 |
| Fast tier: 2 × 45 s dense weaving | 72 | | 0 | 0 | |
| **WP3.3: 10,000 km soak** (real director, procedural road, 2-4 lanes, legs 1-8, weaving and lane-keeping bot at 110-250 km/h; [SOAK.md](SOAK.md)) | 152,789 | 166,579 / 5,513 | 0 | 0 | 0 (of a normally driving player) |

**Other measured numbers:**

- **Hesitant cancels:**
    - requested lane changes, 10 min: 1468 / 7283 = **0.202** (spec about 0.2);
    - organic MOBIL signals in mixed traffic, 5 min: 5 / 42 = 0.12 (a small sample; the bound there is loose).
- **Near/far:** after 20 s of free flow, positions are within 0.14 m and speeds within 0.016 m/s of an all-120 Hz reference. The model runs exactly 4× less often for far vehicles.
- **Following:** the steady gap behind a traffic car and behind the player equals IDM's `(s0 + vT)/sqrt(1 - (v/v0)^4)` within 5 cm, about 3% above `s0 + vT` at v = v0/2.
- **Impossible cut-in** (player 3 m ahead at −50 km/h relative): raw IDM is more than 12 m/s², and the applied deceleration is exactly 6.00 m/s².

**Lessons from the soak, for the director (WP2.5).** The first soak found traffic-to-traffic crashes. Every one was caused by the test's own spawner, not the sim:

1. A car was spawned into a lane that another car was already *moving* into.
2. A fast car was spawned behind a slower one with a gap below the braking distance at the 6 m/s² clamp. The IDM gap `s0 + vT` ignores the closing speed.

After the spawner (a) treated `lc_state != NONE` cars as occupying their `target_lane` and (b) required IDM's `s*` including `vΔv/(2√(ab))` in both directions, the soak has run clean. The director needs the same two rules.

**WP3.3 status (director spawn hardening).** Both rules hold in the director, on both spawn paths (Flow's `plan_batch` / `plan_single` and the director's final `keeps_live_gaps` check in `_commit`), with tests in `tests/unit/test_traffic_integration.gd`:

- (a) WP2.5's Flow already counted `target_lane`, which covers a signaled or running lane change (`target_lane` is set when the blinker comes on). It missed a **lane-splitting motorbike**: a split keeps `lane == target_lane` (the lane it came from) while the bike rides, or signals toward, the lane line, so the other lane looked empty. `SpawnSources.occupies_lane(ts, i, lane, road)` now decides occupancy from the lateral span: the body, widened while a lateral move is signaled or running to the target lane's center and half a lane toward the blinker. `test_spawn_gap_counts_a_lane_splitting_motorbike` fails without it.
- (b) Flow's `min_spacing` already used `s*` with the closing term (`test_spawn_gap_behind_a_slower_leader_includes_closing_speed` pins it: behind a 60 km/h truck at 135 km/h, `s*` is 276 m against `s0 + vT` = 51 m; spawned at `s*`, the follower closes in at −1.7 m/s² at worst).
- (c) The director's `_commit` now re-checks every spawn against every live vehicle occupying its lane (`keeps_live_gaps`, IDM `s*` in whichever order they drive), whatever the source planned; refusals count in `rejected_overlap`. Flow checks only the nearest neighbors, so this also catches a second live vehicle in the lane (e.g. a closing car behind a slow one).
- **Behind-spawn retries:** a behind spawn that fails (the point is visible, or its gaps don't fit) is retried after `spawn_behind_retry_s` (0.5 s) instead of every tick. Before, a slow player in dense traffic cost the director ~40 µs per tick (a vehicle drawn and the lane scanned every tick) and burned the traffic stream; now ~4 µs (`test_failed_behind_spawns_back_off`).

The 10,000 km soak (docs/SOAK.md) runs the real director with all of this.

## Hooks and open points

- **Lane geometry tapers:** see *Lateral occupancy* above. Lane-count changes (a right lane ending) need a mandatory lane change, and so do per-`s` lane centers. WP6.3 set pieces are the hook.
- **Set pieces:** `FLAG_SCRIPTED` vehicles skip MOBIL and may brake up to `scripted_max_decel_mps2`. `request_lane_change` drives scripted lane changes through the same telegraphing.
- **Night tailgating:** resolved by plan D8 (no automatic high beams; see *Reactions to the player*).
- **Lateral move start:** traffic starts its lateral move from its current `d` (usually the lane center). After a hit swerve, the car returns to its pre-hit line.

