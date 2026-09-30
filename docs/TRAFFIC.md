# Traffic simulation (WP2.4)

Traffic on the player's carriageway: IDM car following, MOBIL lane changes, the fairness rules, near/far ticks and reactions to the player. It implements the spec's *Traffic* sections (road-space simulation, IDM, MOBIL, fairness rules, driver types, traffic reacts to the player) and *Lives → Fairness rules*.

- **Code:** `src/traffic/traffic_sim.gd` (`TrafficSim`), `idm.gd` (`Idm`), `mobil.gd` (`Mobil`), `no_ambush.gd` (`NoAmbush`), `traffic_registry.gd` (`TrafficRegistry`). All pure `RefCounted`, allocation-free per tick.
- **Data:** `data/driver_profiles/*.tres` (9 `DriverProfile`s: the spec's 8 and the Racer, plan D15), `data/vehicle_types/*.tres` (10 `VehicleType`s), `data/tuning/traffic.tres` (`TrafficTuning`).
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
2. **Accelerations** for the vehicles due this tick. Each finds its leader, gets the IDM acceleration (and, since WP6.11, the look-through and the anticipation of *Lane-drop queue safety*), then reaction modifiers (brake tap, hit brake), then the clamp, then brake lights. Everyone, the player included, is at the same instant (the player has already moved this tick), so the steady gap behind the player is exactly IDM's.
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
    - (WP6.8) `ã < -b_safe` for any vehicle behind the new follower on the target path that is faster than the car and would close the distance within `mobil_follower_horizon_s` (5 s: signal, move and a margin), whenever the new follower does not shield the lane behind it: a lane-splitting motorbike (it claims half of each lane), a vehicle signalling or moving laterally, or the player. A vehicle driving in the lane shields it: whatever comes up behind it has to brake for it first. So a bike can no longer hide a fast car further back (see *Lane drops (WP6.8)*);
    - the car's own `ã_c < -b_safe`;
    - (WP6.11, MP-D5) the same for the vehicle beyond a new leader that is itself leaving the target lane, and the new leader(s) predicted to when the car will be in the lane (*Lane-drop queue safety*).
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

   **Scripted requests on far vehicles (WP6.10).** `request_lane_change` runs between ticks (set pieces, the sandbox). A far vehicle may then already hold up to 3 ticks of accumulated dt from *before* the blinker came on, and its next model tick used to add all of it to the signal timer. When the vehicle then turned near mid-signal (next model tick one tick later) it moved early: the WP6.1 soak saw a set-piece truck move after 0.983 s of a 1.0 s signal (seed 20260928, run 113, t = 95.4 s). `_start_signal` now records the pre-signal accumulation (`_sig_pre`) and the first signaling tick subtracts it, so the timer counts only blinker time. `test_scripted_signal_on_a_far_vehicle_lasts_the_full_signal_time` covers every 30 Hz phase and fails without the fix (0.992 s). MOBIL's own signals start inside a model tick, where the accumulation is always 0, so organic lane changes and every trace without scripted requests are unchanged.
3. `lane` stays the origin lane until the move completes, and `target_lane` names the destination.

### No ambush (fairness rule 2, `NoAmbush`)

A car may not start a lane change into space the player is predicted to occupy within `no_ambush_window_s` (1.5 s). The definition used:

- **The car's target space:** its own body at the target `d`, moving along the road at its current speed.
- **The player's predicted space:** its body moving at its current road-frame velocity. That velocity is `s_dot` and `d_dot` from `v`, `v_lat` and `yaw`, with the curvature factor. The box is grown by `no_ambush_margin_m` (1.0 m) on every side.
- **Violation:** the two boxes overlap at some `t` in [0, 1.5 s]. Both move linearly, so each axis gives an exact open interval of `t`, and the predicate is their intersection with the window.

The check runs when signaling starts, on every model tick while signaling (a failure cancels the change), and at the start of the lateral motion. The test checker re-derives the rule independently. It samples `t` every 5 ms, uses the move's actual final `d`, and snapshots the states when motion starts.

### Driver profiles

These values are not in the spec except the desired speeds, signal times and move times; they are tuned in the sandbox. Motorbikes and Hesitant drivers are described in their own sections. Plan D15 (WP6.6, owner M5 playtest: "a variety of fast cars") widened the commuter (spec 100–130) and aggressive (spec 150–190) speeds and added the **racer**; see *Fast traffic (D15)* below.

| Profile | Vehicles | v0 km/h | a_max | b | T s | s0 m | p | Δa_th | a_bias | b_safe | Signal s | Move s | Freq | Other |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| cruiser | sedan, hatchback | 80–100 | 1.2 | 2.0 | 1.6 | 2.5 | 0.6 | 0.3 | 0.5 | 3.0 | 1.0 | 2.5–3.0 | 0.5 | keep right |
| commuter | sedan, SUV, pickup | **95–145** (D15) | 1.5 | 2.0 | 1.3 | 2.0 | 0.3 | 0.2 | 0.3 | 3.5 | 1.0 | 2.0–3.0 | 1.0 | |
| aggressive | sports, coupe | **140–200** (D15) | 2.5 | 3.0 | 1.0 | 1.5 | 0.05 | 0.1 | 0.1 | 4.0 | **0.6** | **1.5** | 2.0 | |
| truck | semi (16 m) | 80–90 | 0.6 | 1.5 | 1.8 | 3.0 | 0.5 | 0.3 | 0.6 | 2.5 | 1.0 | 3.0 | 0.3 | keep right, right 2 lanes |
| bus | coach (12 m) | 85–95 | 0.8 | 1.5 | 1.6 | 3.0 | 0.5 | 0.3 | 0.5 | 2.5 | 1.0 | 2.5–3.0 | 0.4 | keep right, right 2 lanes |
| van | delivery van | 95–110 | 1.2 | 2.0 | 1.4 | 2.0 | 0.3 | 0.2 | 0.3 | 3.0 | 1.0 | 2.0–3.0 | 0.8 | |
| motorbike | motorbike | 110–150 | 2.5 | 3.0 | 1.0 | 1.5 | 0.2 | 0.1 | 0.2 | 3.5 | 1.0 | 2.0–2.5 | 1.5 | lane splitting |
| hesitant | any car | 90–120 | 1.2 | 2.0 | 1.5 | 2.5 | 0.5 | 0.2 | 0.3 | 3.0 | 1.0 | 2.0–3.0 | 1.0 | cancels 20%, `min_leg` 3 |
| **racer** (D15) | sports, coupe | **190–250** | 3.0 | 4.0 | 0.9 | 1.5 | 0.02 | 0.1 | 0.05 | 4.0 | **0.6** | **1.5** | 2.0 | fast lanes: `spawn_left_lane_count` 2; **weaves** (D17, WP6.9): toward traffic T 0.5 s, s0 1.0 m, b_safe 4.5; lookahead 300 m; at most 2 lane changes per 10 s |

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
| `test_racer_weave.gd` | WP6.9 (plan D17): only the racer weaves (every other profile's weaving fields at their defaults, so its path is unchanged); the racer's data (tighter toward traffic, well below the clamp, the 0.6 s blinker, the player's b_safe unchanged); b_safe toward traffic never above the clamp; behind a traffic car the IDM equilibrium with the traffic T and s0, behind the player the ordinary one; a gap in front of a traffic car the WP6.6 racer refused is taken, the player at the same place still refuses it (2 m/s²), and its own braking behind the player keeps the ordinary b_safe; the lookahead pace; leaving a blocked lane no later than MOBIL alone; the lane-change cap; dense weaving traffic with 30 % racers: no collisions, no violations, every car a racer cuts in front of needs less than the clamp (raw IDM), no racer beyond its cap; determinism; no allocation. Soak tier: the pass survey (`RacerPassSurvey`) and leg-8 density with weaving on vs off (±3 %) |
| `test_mobil.gd` | Incentive math; asymmetric keep-right bias; b_safe and the player tightening to 2 (pure, and in the sim: a traffic follower at −3 m/s² allows the change, the player at the same geometry refuses it); the no-ambush predicate (closing speed, lateral drift, time-disjoint overlaps); overtaking a slow truck; cruisers drift right; trucks stay in their lanes |
| `test_traffic_sim.gd` | Profile data vs the spec table; spawn API; equilibrium gaps behind traffic and behind the player; free road → v0; stops behind a stopped player (single lane) without contact; impossible cut-in → exactly −6 m/s² and never beyond; brake-light thresholds every tick; signal, then smoothstep with v_lat; cancel when the player enters the gap; dense weaving rule checks; no rear-ending of a lane-keeping player; the Hesitant ratio; lane splitting (filters, stops behind trucks, never during the player's lane change, returns when traffic flows); every reaction; near/far vs a 120 Hz reference; the determinism trace; tick budget; no memory growth |
| `soak_*` | 3 × 10 min dense weaving (3 lanes, 150 km/h player), 10 min on 4 lanes with a 190 km/h player, 9 × 3 min lane-keeping players (3 lanes × 95/120/150 km/h), the Hesitant ratio over about 7,300 requested signals plus an organic run, and the tick-cost report |
| `test_traffic_integration.gd` | The real director + sim + bot on the procedural road (1 min fast, 3 × 10 min soak); the WP3.3 spawn hardening (lane changers and lane-splitting bikes occupy lanes, `s*` with the closing term, the commit re-check, behind-spawn back-off) |
| `test_lane_drop_safety.gd` (WP6.8, WP6.11) | A fast car hidden behind a lane-splitting bike; the zipper beside fast lanes; the harmonisation zone's braking; nobody stopped beside a fast lane at a canyon drop; canyon determinism; the checker's box heading (see *Lane drops (WP6.8)*). WP6.11: the three MP-D5 extensions each against its flag off (see *Lane-drop queue safety*) |
| `tests/soak/`, `test_traffic_metrics.gd` | WP3.3: the 10,000 km soak harness (tiny version in the fast tier, one run per lane count in the soak tier, the full distance with `tools/soak.sh`), the impossible-window oracle, cross-shard determinism, the metrics baseline and the D7 cap runs. See [SOAK.md](SOAK.md) |

**The independent checker** (`TrafficRuleChecker`) reads only `TrafficState` and the player each tick. It checks:

- the signal time: blinker-on to first lateral motion ≥ the profile's signal time, and no unsignaled lateral motion;
- no-ambush, sampled against the move's final `d`;
- traffic-to-traffic collisions, with oriented boxes (yaw = `atan2(v_lat, v)`, clamped to ±`MAX_BOX_YAW_RAD` since WP6.8) inset by `lives.collision_inset_m` and a separating-axis test;
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

## Fast traffic (D15, WP6.6)

Owner, M5 playtest (iPhone): "the traffic is quite slow ... I want to have a variety of fast cars during the runs ... cars that actually don't hesitate and move fast, even fast enough for me to follow for a bit and try to overtake." Plan D15. Fairness rules unchanged.

- **Racer** (`data/driver_profiles/racer.tres`, `profile_id` 8, appended to `TrafficRegistry.PROFILE_IDS`): sports cars and coupes (the existing models; no new vehicle type), desired speed **190–250 km/h**, a = 3.0, b = 4.0, T = 0.9 s, s0 = 1.5 m, politeness 0.02, Δa_th 0.1, keep-right bias 0.05 (below Δa_th: a free racer does not drift right), b_safe 4.0, **0.6 s blinker, 1.5 s move** (the aggressive telegraphing; the 0.5 s floor holds), MOBIL twice as often. `spawn_left_lane_count` = 2: Flow spawns it only in the two left lanes, never in the slow lane. Its share comes from `DirectorTuning.racer_share_*_pct` (10 → 15 %, see docs/SPAWNING.md).
- **Wider spreads:** commuter 100–130 → **95–145** km/h, aggressive 150–190 → **140–200** km/h; per-car desired-speed jitter ±5 % (`spawn_v0_jitter_pct`).
- **Faster left lanes:** `lane_flow_speeds_from_right_kmh` 95 / 115 / 135 / 150 → **95 / 120 / 145 / 160** (3 lanes: 95 / 120 / 145; 4 lanes: 95 / 120 / 145 / 160). Faster flows cost density (below and docs/SPAWNING.md), which capped this at +10 km/h in the fast lane.
- **Leader search:** `idm_lookahead_m` 400 → **560 m**. A racer at 250 km/h closing on an 80 km/h truck needs s* = 537 m (`test_registry_profiles_match_spec` / `test_lookahead_covers_the_racer` check the worst case). The cost is small: the search stops at the first vehicle on the path.
- **Fairness:** the racer goes through the same sim as everyone: IDM with the 6 m/s² clamp, MOBIL safety with the player's b_safe of 2 m/s², no ambush, rear-end prevention with the player as leader. `tests/unit/test_driver_profiles.gd`: a racer at 250 km/h behind a player at 100 km/h in a single lane, and behind a stopped player, brakes within the clamp and never touches it; a racer from behind comes past a lane-keeping player, changes lanes around a slower car with the blinker first; dense weaving traffic with 20 % racers has no collisions and no rule violations; the trace is deterministic. The soak results are in docs/SOAK.md, *D15 soak*.
- **What a player sees** (density survey, scripted player at 150–250 km/h, 3 lanes): racers average **186 km/h at leg 1** and 143 km/h at leg 8, where the lanes are crowded (D17) and they weave through; lane means 138 / 127 / 106 km/h at leg 1 (before: 128 / 116 / 101).
- **Sandbox:** the profile cycles like the others (`RACE` tag, pink in the debug view); FAST ×1 / ×1.5 / ×2 / ×0 scales both fast shares (a private copy of the tuning, then a re-seed); RACER spawns one behind the player, a lane to its left, and selects it; the stats panel's `speeds` line and the dev report's `traffic` line (also in a run: `DevReport.traffic_line`) give the live speed distribution: mean, the share above 150 / 180 / 200 km/h (`dev_speed_bands_kmh`), the mean per lane and the fast count. Snap: `tools/snap.sh src/traffic/dev/traffic_sandbox.tscn --racer=true --driver=keep --speed_kmh=130 --leg=3 --warm_s=12 --labels=6 --layers=blink --racer_ahead_m=8 --tag=racer`.

## Lane drops (WP6.8)

WP6.3's all-pieces soak found traffic-to-traffic collisions at the canyon's 3 → 2 lane drops before tunnels (136–195 collision pairs per ~500 km of canyon road, plus an impossible window), with no set piece involved. Three causes:

1. **Standstill merges beside fast lanes.** WP6.2's mandatory merge let a car that found no gap wait at a standstill 15 m before the end of its lane, then merge from 0 km/h into lanes that WP6.6 made fast (130–190 km/h, racers 190–250). Queues formed at the end of the lane; the follower in the target lane braked at the 6 m/s² clamp and could still hit it (worse after the bot had touched the merging car).
2. **One follower.** MOBIL's safety check judged the nearest follower in the target lane only. A lane-splitting motorbike (it claims half of each lane) or a slow car close behind the gap hid a fast car behind it.
3. **The checker's box heading.** The rule checker turned a traffic box to `atan2(v_lat, max(v, 0.1))`. A nearly stopped car moving sideways got a heading of up to ~87°: a 12 m coach at the end of lane 2 reached across lane 1 into lane 0 and "hit" cars it never touched.

**What traffic does now** (`TrafficSim`, block *Lane closures and mandatory merges*; tuning group *Lane drops* in `TrafficTuning`). It is what real traffic does at an announced lane drop, and it applies to the road's lane drops (`sync_road_closures`; a closure with a base urgency). Set-piece closures keep WP6.2/6.3's behaviour, except that they get the zipper yield and the MOBIL follower check too.

| | What | Tuning |
| --- | --- | --- |
| Early, graded merging | A road drop's merge zone is 1 km long (set pieces keep `merge_zone_m`, 600 m). The urgency ramps from `lane_drop_urgency_min_mps2` (0.6) at its start to `merge_urgency_mps2` (2) at the taper. The decision is the car's own advantage `ã_c − a_c` plus the urgency: no politeness or keep-right threshold holds a car in a lane that ends. Safety and no-ambush apply as always. Beyond `merge_zone_m` it is evaluated at the profile's MOBIL interval, within it every model tick. Nobody moves into the lane within the zone | `lane_drop_merge_zone_m` 1000, `lane_drop_urgency_min_mps2` 0.6 |
| Harmonisation | A drop zone caps every lane from the `lane_ends` sign (400 m before the taper; `lane_drop_slow_zone_m` when the road has none) through the narrowed section (a tunnel's two lanes) to 150 m past the end of the taper where the lanes come back (within `lane_drop_narrow_max_m`; else 150 m past the drop's taper): through lanes 120 km/h, the dropping lane 110 km/h, so gaps slide past a merging car instead of riding beside it. Vehicles see it `lane_drop_view_m` (1 km) ahead and brake into it at their comfortable deceleration. The braking eases in: none while the constant deceleration still needed is below half of `b`, all of it from `b` on, never more than `b` (a racer at 250 km/h starts gently about 930 m out and reaches its `b` of 4 m/s² near the zone). Brake lights ripple down the lanes. Racers and aggressive drivers obey it too; the player is never slowed by it | `lane_drop_through_kmh` 120, `lane_drop_merge_lane_kmh` 110, `lane_drop_slow_after_m` 150, `lane_drop_narrow_max_m` 3000, `lane_drop_brake_onset_frac` 0.5, `lane_drop_view_m` 1000 |
| Speed matching | Inside a drop zone, and in the dropping lane within its merge zone, slower vehicles (trucks, buses, cruisers) drive at least the dropping lane's 110 km/h, so a merge needs an ordinary gap instead of one sized for a 30 km/h speed difference, and the two lanes of a tunnel never become a slow wall the player cannot pass at 100 km/h (the soak's remaining impossible windows before this). Past the zone they give the speed back over `lane_drop_release_m` (no brake lights for it). Scripted vehicles are left alone. A deviation from the driver table's truck and bus speeds (80–95 km/h) for 1–3 km per drop: see the handoff | `lane_drop_merge_lane_kmh`, `lane_drop_release_m` 400 |
| Zipper, the through lane | A vehicle beside a lane that closes within its merge zone treats the nearest car still in that lane ahead of it (within 400 m, in the last 60 % of its zone, not held, not splitting, not signalling away) as its leader, braking no harder than 1.5 m/s² (or its `b`, if lower). When it is faster than that car, only if it can fall back behind it at that rate (`Δv² / 2(gap − s0)` ≤ 1.5); otherwise it passes and the car merges behind it. Beside it (the car's centre ahead) and not faster, it always eases off | `lane_drop_yield_range_m` 400, `lane_drop_yield_frac` 0.6, `lane_drop_yield_decel_mps2` 1.5 |
| Zipper, the merging car | A car still in the dropping lane (last 60 % of its zone, not yet moving) lines up behind the nearest vehicle ahead of it in the lane it merges into, braking no harder than 1.5 m/s², and drops back behind one beside it that is at least as fast (a slower one it passes). So nobody rides side by side to the end of the lane. It does not drop below 90 km/h while more than 250 m from the closure (a bus falling behind car after car in a dense lane would be a slow wall); there the through lane's yield opens the gap | same, `lane_drop_merge_floor_kmh` 90, `lane_drop_merge_floor_until_m` 250 |
| No standstill | With both sides of the zipper, matched speeds and the early merge, a car rarely runs out of lane: at the test's canyon drop at leg-8 density the slowest vehicle stays above 80 km/h, and over the 1,008 km canyon soak vehicles stood beside a lane faster than 60 km/h for 94 one-second samples; the four runs that had the most before went from 931 to 0 (SOAK.md, *WP6.8*). The standing obstacle 15 m before the closure stays as the last resort (a platoon of the dropping lane reaching the end together beside a dense through lane); the lane beside it is at the harmonised speed at most, and its cars ease off for it | `merge_stop_margin_m` |
| Set-piece slow zones | Where a drop's merge zone reaches back over a toll's booth lane (a tunnel just after a toll gantry checkpoint), booth traffic still kept in its lane (`kept_by_zone`) starts no merge out of the dropping lane, and nobody yields to it, until it is back up to 90 km/h or within `lane_drop_merge_floor_until_m` of the closure: otherwise it pulled out into the express lane at booth speed (a slow wall in the all-pieces soak) | `lane_drop_merge_floor_kmh`, `lane_drop_merge_floor_until_m` |
| MOBIL safety | Besides the nearest follower, every vehicle behind it on the target path (claims) that is faster than the changing car and would close the distance within `mobil_follower_horizon_s` must stay above `−b_safe` (the player's 2 m/s² for the player), whenever the nearest follower does not shield the lane: a lane-splitting motorbike, a vehicle changing lanes, or the player. The scan is bounded by the fastest vehicle this step. Everywhere, not only at drops | `mobil_follower_horizon_s` 5 |

**Tick cost** (`TrafficSoakRun` canyon runs 2 and 6, 4 legs each, against the integration branch on the same container, alternating and concurrently; the container was shared with other agents' soaks, so single numbers vary by ±15 %): canyon **+0 to +45 %** per 120 Hz step (run 6: about equal; run 2: +30–45 %, of which +17 % is more vehicles in the window, as traffic near a drop is slower and denser: mean active 28 → 33), farmland within the noise (+0–5 %). Vehicles outside every closure's merge zone and every drop zone's reach skip the drop logic (`_drop_tick`, one pass over the closures and zones per model tick), the zipper scans a per-step candidate list (`_collect_yield_candidates`, usually 0–5 cars), and the hidden-follower scan runs only behind a follower that does not shield its lane. On a phone (2–4× slower) the worst case is about +0.1–0.3 ms per frame, on drop legs only.

**Fairness.** Nothing brakes beyond a profile's comfortable deceleration for a drop, so rule 4 holds with margin (the drop is announced by its `lane_ends` sign anyway). Merges are telegraphed and pass no-ambush as before. The player is never slowed by a zone; the harmonised traffic is what the player meets, and the passability oracle judges it in the soak.

**The rule checker** (`TrafficRuleChecker.box_yaw`) clamps a traffic box's heading to ±`MAX_BOX_YAW_RAD` (0.28 rad). That is the steepest heading of the quickest lane change (1.5 s over a 3.6 m lane, peak `v_lat` 3.6 m/s) at 45 km/h, so nothing changes above that speed. It does not hide real contacts: the boxes still move with `d`, so a car that moves sideways into another still overlaps it. `test_rule_checker_box_heading_for_slow_lateral_movers` pins both cases: the WP6.3 coach no longer "hits" a car two lanes over, and a sideways overlap or a rear-end still counts.

**Tests** (`tests/unit/test_lane_drop_safety.gd`): a fast car hidden behind a lane-splitting bike (the request is refused, and allowed once the racer is gone) and the same scene with MOBIL deciding (no racer brakes beyond its `b_safe`); the drop zone taken from the road; a zipper merge beside lanes at 130–210 km/h (no contact, nobody near the clamp, nobody stops, everyone out of the dropping lane); the harmonisation zone's braking (at most `b`, no step at the onset, the zone's speed at its start and inside); nobody stopped beside a lane faster than 60 km/h at a canyon drop at leg-8 density; canyon determinism; the checker's box heading. `tests/unit/test_traffic_director_lane_drops.gd` keeps WP6.2's cases. The soak numbers are in [SOAK.md](SOAK.md), *WP6.8*.

## Racers weave harder (D17, WP6.9)

Owner (plan D17): WP6.7 found that legal racers rarely get past a player at 170–230 km/h in dense late-leg traffic (0.07 passes per km at leg 8). The owner chose "racers weave harder": tighter gaps and more willing lane changes toward traffic, still signalled, no ambush, rear-end safe; density unchanged.

**What changed.** New `DriverProfile` fields (group *Weaving*), all off by default, so only the racer sets them and every other profile takes exactly its WP6.6 path in the sim (`TrafficSim.weaves(p)` gates every branch):

| Field | Racer | Where it acts |
| --- | --- | --- |
| `idm_headway_vs_traffic_s` | **0.5 s** (T 0.9 s otherwise; × the director's leg scale: 0.28 s at leg 8) | IDM behind a traffic car (`_step_accel`), and MOBIL's prediction of its IDM (`_eval_move`, `_follower_accel`) |
| `idm_s0_vs_traffic_m` | **1.0 m** (1.5) | the same |
| `idm_b_comfort_vs_traffic_mps2` | off (4.0) | the same; a higher b cost leg-8 density (below) |
| `mobil_b_safe_vs_traffic_mps2` | **4.5 m/s²** (4.0), never above the 6 m/s² clamp | MOBIL safety when the new follower is a traffic car, and its own braking behind a traffic new leader |
| `lookahead_lane_choice_m`, `lookahead_gain_per_s`, `lookahead_incentive_max_mps2` | **300 m, 0.2 /s, ±2.0 m/s²** | MOBIL's incentive gains 0.2 × (target lane's pace − own lane's pace). A lane's pace (`_weave_pace`) is the mean speed the racer could make there over H = 300 m / v0: each vehicle in it within 300 m bounds it to (gap + v_j H − s0 − v_j T) / H, its v0 when none does |
| `lane_change_cooldown_s` | off (the global 3 s) | a shorter one cost density (below) |
| `lane_change_cap_count`, `lane_change_cap_window_s` | **2 per 10 s** | at most 2 discretionary lane changes started in any 10 s (readability; a per-slot ring of start times on the sim's clock) |

Code: `src/traffic/traffic_sim.gd`, block *Racers weave harder* at the end of the file, plus the hooks it needs: `_init` (`_init_weave`), `step` (the cap's clock), `_step_accel` (IDM behind traffic), `_eval_move` (b_safe toward traffic; its own IDM behind a traffic new leader), `_follower_accel` (a weaving follower's IDM; `lead_is_player`), `_consider_lane_change` (lookahead and cap), `_tick_moving` / `_cancel` (`_cooldown_of`). `weave_lane_pace(slot, lane)`, `weave_b_safe(p)`, `weave_idm_accel(...)` and `weave_bonus(slot, lane)` are queries for tests and the sandbox: the sandbox's MOBIL readout (`MobilProbe`) uses them so it keeps agreeing with the sim (48 of 48 organic signal starts in `test_mobil_readout_agrees_with_sim_decisions`), and its panel shows the lookahead term (`look`). No change to `idm.gd`, `mobil.gd`, `no_ambush.gd`.

**Toward the player nothing changes:** behind the player the racer keeps its ordinary T, s0 and b (rear-end prevention); the player as its new follower keeps b_safe = min(4.5, `player_b_safe_mps2`) = 2 m/s²; behind the player as new leader it keeps its ordinary b_safe 4.0; no-ambush and the 0.6 s blinker (floor 0.5 s) as before. `test_racer_weave.gd` pins each of these; `test_driver_profiles.gd`'s racer-behind-a-braking/stopped-player tests and WP6.7's rear-end tests pass unchanged.

**Bounded cut-ins.** b_safe 4.5 bounds the new follower's IDM braking at the moment of the move; the braking can still grow a little afterwards (IDM overreacts in a closing approach). `RacerPassSurvey` watches every car a racer cuts in front of for the move and 5 s after it, while the racer leads it: the hardest raw IDM braking (before the clamp) in 300 km of leg-4/8 traffic was **−5.56 m/s²** (before WP6.9: −4.04 with b_safe 4.0), never the 6 m/s² clamp. An explicit "peak IDM braking" guard (b_kin = Δv² / 2(gap − s0), IDM ≈ b_kin² / b beyond b) was tried and dropped: IDM's own instantaneous term is stricter in every case that occurs.

**What it bought, and what it did not.** Racers change lanes 30–95 % more often (leg 8, 3 lanes: 150 → 221 moves per 51 km at 200 km/h, 244 → 347 at 170), always within the cap. But their mean speed in leg-8 traffic stays at 155–169 km/h (before 147–167), and passes of a 200 km/h player do not rise (docs/SPAWNING.md, *Racers weave harder*). The reason, measured with a diagnostic of blocked racers at leg 8 (200 km/h observer): a racer is blocked (a slower leader within 200 m) 70 % of the time, and then in 78 % of the cases both neighbouring lanes are unsafe: the gap beside it is too short for **its own** braking (a car 0–15 m ahead in a lane 10–30 km/h slower) or overlaps a car. That is the lanes' density (15 vehicles per km per lane at T × 0.55), not MOBIL's caution: even an extreme setting (T 0.25 s, s0 0.5 m, b_safe 6, b 6, a 4, cooldown 0.5 s, MOBIL 8 Hz, cap 6) left racers at 169–174 km/h, 0 passes of a 200 km/h player at leg 8, and cut-ins at the clamp (−6.03).

**Density.** Weaving costs density when it adds lane changes: at leg 8 (3 lanes, 8 seeds × 14 km, the survey's chaos between seeds about ±1.5 %), before 15.48 per km per lane; T/s0 toward traffic + lookahead 15.33; + b_safe 4.5 **15.50**, and the shipped data (the cap at 2 per 10 s) **15.45** (−0.2 %); adding b 5.0 toward traffic and/or a 2 s cooldown 14.28–14.76 (−5 to −8 %); a lookahead by the slowest car within 300 m instead of the pace above (with b 5.0 and the 2 s cooldown) 13.77 (−11 %). So those levers stay off. On 4 lanes the shipped setting reads 15.51 → 15.20 (−2.0 %; variants with b_safe 4.25, T 0.6 s, a lookahead gain of 0.1 or no lookahead 15.50–15.86, i.e. within the chaos). `soak_density_with_weaving_racers` gates ±3 % (weaving on vs off, 3 and 4 lanes, 8 × 14 km per cell).

## Lane-drop queue safety (MP-D5, WP6.11)

The server's traffic (N4.1, `westbound-server/crates/sim`) found that at the loop's rush-hour density the lane-drop queues make this model collide: one simulated hour at rush had **11,622 ticks with traffic-to-traffic contacts** (33,162 pair-ticks, all real body overlaps). It added three extensions there, each traced to a contact; the orchestrator decided (MP-D5) that single-player gets them too, so the game, the server and the client's network model run one model. WP6.11 ported them function for function (the Rust port keeps the GDScript's shape, so parity stays line for line).

| Tuning flag (`TrafficTuning`, group *Lane-drop queue safety*, all on) | The contact it prevents | What the model does |
| --- | --- | --- |
| `look_through_leaving_leaders` | **Cut-out.** The car's leader signals or moves out of the lane; once it leaves, a stopped queue ahead of it needs more than the 6 m/s² clamp | A leader signalling or moving to a target that does not overlap the car's path hides nothing: following (IDM, `_step_accel`) and MOBIL's own safety (`_eval_move`, by claims) also judge the next vehicle on the path beyond it, and beyond that one while it leaves too (`_look_through_accel`, `_leaving_path`) |
| `predict_leader_braking` | **Stale decision.** MOBIL judges the new leader as if it holds its speed; by the time the car is in the lane (the blinker, 0.6 s for racers, plus the move) the leader, braking into the queue, is much slower and closer | MOBIL's own safety also judges each new leader extrapolated with its current acceleration to signal time + half the minimum move time, against the car holding its speed: the gap must stay open and IDM there must not ask for more than `b_safe` (`_predicted_leaders_safe`; the player as leader holds its speed) |
| `anticipate_leader_braking` | **Late reaction.** A racer at 180 km/h follows a car braking at the clamp into the queue; stock IDM ignores the leader's deceleration and reacts too late for 6 m/s² | When stopping `s0` behind the leader's own stopping point (at its current deceleration) needs more than the profile's comfortable `b`, the follower brakes for it now: `a = -v² / 2(gap - s0 + v_l² / 2 b_l)`, never beyond the clamp (`_anticipation_accel`; the player as leader holds its speed) |

- **Where they act.** Everywhere, not only at drops: the look-through only while a leader leaves the path, the prediction in MOBIL's own-safety check, the anticipation only when the leader brakes hard enough that stopping behind it needs more than `b` (a leader braking at 1 m/s², or accelerating, changes nothing: `test_follower_anticipation_leaves_ordinary_following_alone`). Allocation-free (index walks over the sorted order).
- **Off** gives the model before WP6.11 exactly (the parity vectors were regenerated with them on; with them off the old vectors reproduce).
- **What changes for a car cut in front of.** MOBIL still judges the new follower's stock IDM with the car holding its speed. With the anticipation on, a follower whose new leader then brakes hard (a racer cutting back into the fast lane and braking for the column ahead) brakes early and harder than its `b_safe`, never beyond the clamp: in `test_organic_lane_changes_never_cut_off_a_fast_car_behind_a_bike` the racers' hardest braking is −4.68 m/s² with the extensions (b_safe 4.0) and −2.16 without; that test now holds the `b_safe` bound with the extensions off (WP6.8's MOBIL property) and the clamp with them on.
- **Server and client.** The server's switches are its own (`mp_traffic.json`, on); the client's network model (`NetworkTrafficSource`) mirrors the look-through (from the car's intent) and the anticipation (docs/NET_TRAFFIC.md). Parity: docs/SERVER.md, *Traffic simulation (N4.1)*.
- **Tests** (`test_lane_drop_safety.gd`): each extension against its flag off: a racer 200 m behind a car braking at the clamp (off −1.16 m/s², on −5.08, exactly the stopping deceleration); a follower behind a leader signalling out of a lane blocked by a stopped truck (off −0.28, on −5.26); a lane change behind a leader braking at 5 m/s² (off allowed, on refused; a leader holding its speed: allowed both ways); the flags default on. The soak numbers are in SOAK.md, *WP6.11*.

## Hooks and open points

- **Lane geometry tapers:** see *Lateral occupancy* above. Lane-count changes (a right lane ending) are mandatory merges (WP6.2) with early merging, harmonisation and a zipper (WP6.8, *Lane drops*); per-`s` lane centers are still a hook.
- **Set pieces:** `FLAG_SCRIPTED` vehicles skip MOBIL and may brake up to `scripted_max_decel_mps2`. `request_lane_change` drives scripted lane changes through the same telegraphing.
- **Night tailgating:** resolved by plan D8 (no automatic high beams; see *Reactions to the player*).
- **Lateral move start:** traffic starts its lateral move from its current `d` (usually the lane center). After a hit swerve, the car returns to its pre-hit line.

