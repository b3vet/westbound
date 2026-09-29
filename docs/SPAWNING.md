# Traffic spawning (WP2.5)

Spec: Traffic → Spawning and the opposite carriageway, Traffic director, fairness rules 5 to 7, and Lives → No unfair spawns. Contracts: `docs/CONTRACTS.md` §5 and §6.

| File | What it is |
| --- | --- |
| `src/traffic/spawn_sources.gd` | `SpawnSources.Flow` (the default source), `SpawnSources.Daily` (Flow on the date-seeded stream), and `SpawnSources.for_run(run, profiles, types)` |
| `src/traffic/traffic_director.gd` | `TrafficDirector` skeleton: ahead batches, behind spawns, despawn, cap, ghost zone, opposite side |
| `src/traffic/opposite_traffic.gd` | `OppositeTraffic`: visual-only opposite carriageway with its own `TrafficState` (`d < 0`, moving toward −s) |

## Flow

Each lane is planned as a renewal process at `DirectorTuning.density_per_km_lane(leg)`. Every vehicle is placed at its minimum spacing plus a uniform extra, and the extra's mean makes the lane's mean spacing `1000 / density`.

- **Minimum spacing:** half the two lengths plus the follower's IDM desired gap, `s* = s0 + max(0, vT + v·Δv / 2√(ab))`. At `s*` the IDM interaction term is 1, so no vehicle is placed where it would have to brake harder than its comfortable deceleration.
- **Live traffic:** vehicles already on the road (in the lane or changing into it) act as renewal points, so every new vehicle also keeps `s*` to its live leader and follower.
- **Driver mix:** each lane draws from its own mix.
    - The aggressive share (5 → 20 %) applies wherever the aggressive profile may drive.
    - Hesitant appears only from `hesitant_first_leg` and the profile's own `min_leg`.
    - The other profiles are weighted by `traffic.spawn_profile_weights_pct`.
- **Which lanes a profile may use:** a profile may spawn in a lane only if its top desired speed reaches the lane's flow speed minus `spawn_lane_speed_tolerance_kmh`. `keep_right` profiles use only the rightmost `spawn_keep_right_lane_count` lanes.
- **Speeds:** `v0` is drawn inside the profile's range, clipped to the lane's band. Every vehicle spawns at its lane's flow speed (`v` = flow).
- **Type and looks:** the vehicle type is any type whose `allowed_profiles` lists the profile. The model variant is uniform. `color_index` indexes the biome's `traffic_palette`, or `spawn_palette_fallback_count` if the biome has none.
- **Randomness:** everything comes from `ctx.rng`. A re-roll calls `plan_batch` again and draws new numbers. `draw_into` and `plan_single` allocate nothing.

## Director

- **Ahead.** The director keeps batches (`spawn_batch_length_m`, 300 m) planned out to `max(spawn_ahead_m, fog_end + spawn_fog_margin_m)`. Each batch starts at `max(planned end, player s + fog_end + margin)`, so nothing appears inside the fog end. The run sets the fog end with `set_fog_end()`; it defaults to the default tier's view distance.
    - A batch is committed nearest-first.
    - Near the cap, the batch is thinned evenly. Dropping vehicles only widens gaps.
- **Behind.** For each lane from the median (`spawn_behind_lane_count`, and never the slow lane), a lane builds up an arrival debt of `density × (v_lane − v_player)` while the player is slower than that lane by more than `spawn_behind_speed_margin_kmh`.
    - When one arrival is owed, the director spawns a vehicle `spawn_behind_m` (150 m) behind the player. The spawn needs the point to be outside the frustum (the `frustum_check(s, d) -> bool` Callable; if it is unset, the point counts as visible and nothing spawns behind).
    - The vehicle's IDM gaps must also fit, and the player counts as the leader.
- **Despawn.** A vehicle despawns when it is more than 200 m behind the player, or ahead of the player's `s` by more than the ahead distance + one batch + `spawn_despawn_ahead_margin_m`.
- **Every spawn** goes through `_commit` in this order:
    1. the cap (`max_active_vehicles`)
    2. the ghost zone (the player's box plus `spawn_ghost_margin_long_m` / `_lat_m`; the run may widen it with `set_ghost_zone`)
    3. no pop-in (ahead beyond the fog, or behind and out of the frustum)
    4. `sim.spawn(rec)`
- **Start of run.** `reset(player)` fills the road from the player to the ahead distance before anything is drawn. It still keeps out of the ghost zone and places nothing behind the player.
- **Per tick.** `step(dt, player)` runs after `traffic_sim.step`. The despawn scan, the behind bookkeeping and the opposite side allocate nothing. Only batch planning allocates, at director rate.

## Opposite carriageway

- **Density:** `opposite_density_pct` of the leg's density over the window from `opposite_recycle_behind_m` behind the player to the ahead distance, capped at `opposite_max_vehicles`.
- **Speed:** each lane has one constant speed, `opposite_speed_kmh` plus `opposite_lane_speed_step_kmh` for each lane toward the median. Vehicles never close on each other, and there are no collisions.
- **Recycling:** a vehicle that passes behind the camera is re-placed beyond the ahead line. It goes past the front-most vehicle of the lane with the most room, by a jittered mean spacing, so the count stays stable. `FLAG_HEADLIGHTS` follows `set_night()`.

## Growing it (Phase 6)

- Intensity waves and blind-window caps go in `_refresh_ctx()`.
- Passability and re-rolls go between `plan_batch` and the commit in `_plan_range()`.
- Set pieces become further sources assigned to `source`. Flow stays in charge of behind spawns and the opposite side's mix.


## Hardening (WP3.3)

- `SpawnSources.occupies_lane()` decides lane occupancy from the lateral span, so lane-splitting motorbikes and cars mid lane change count in both lanes.
- `TrafficDirector.keeps_live_gaps()` re-checks every committed spawn against live vehicles using `s*` including the closing term. Refusals are counted in `rejected_overlap`.
- A failed behind-spawn waits `spawn_behind_retry_s` before retrying.

Details are in `docs/TRAFFIC.md` and `docs/SOAK.md`.


## Density (D11, WP4.8)

Owner, M3 (iPhone web build, leg 8): "not even crowded enough, easily passable". The phone showed 45 vehicles, a 0.10 ms average sim tick and 60 fps. Plan D7 and D11.

### Measuring it

**Effective density** is the number of vehicles per km per lane inside the director's **density window**, `[player s − density_window_behind_m, player s + density_window_ahead_m]` = [−150 m, +600 m] (`DirectorTuning`). That is the stretch the player sees and weaves through.

- `TrafficDirector.window_density_per_km_lane(s)` measures it inside the game. The run's DEV panel reports it (below).
- `DensitySurvey` (`tests/soak/density_survey.gd`) measures it headless. It drives the real registry, `TrafficSim`, `TrafficDirector` and procedural road through `TrafficSoakRun`, at one fixed leg per cell. Each cell is 3 seeds × 7 km, sampled every 0.5 s after a 20 s warm-up.

```
tools/godot.sh --headless --path . --script res://tests/soak/soak_main.gd -- --density \
    [--lanes=3,4] [--legs=1,...,8] [--profile=scripted|bot|soak] [--seeds=3] [--out=res://tests/out/density/x.json]
    [--before]                    # the WP3.3 director: no gain, no top-up, 16/km at leg 8, cap 60
    [--cap=N] [--density-last=X] [--headway-last=X] [--gain-min=X] [--gain-max=X] [--flows=...] [--weights=...]
```

About 6 minutes for 8 legs on one core. `tests/soak/test_density.gd` checks the pipeline in the fast tier. In the soak tier, `soak_effective_density_tracks_target` checks legs 1, 4 and 8 on 3 and 4 lanes, within ±10%.

**Player profiles:**

- **`scripted`** is the headline number. An observer drives at a speed redrawn every 15 s in [150, 250] km/h, two lanes to the right of the carriageway. Traffic neither follows it nor yields to it, so its speed is exactly the "typical speed", and the director alone decides what it meets.
- **`bot`** is the soak's weaving bot aiming for 150-250 km/h. It follows traffic, so from leg 4 on it averages only 117-136 km/h, whatever it wants. It rides along with the left lanes, and what it meets depends on how fast it can get through.

### Why the director fell short (before)

Before D11, a player at 150-250 km/h met 67-68% of the target at leg 8 on both 3 and 4 lanes (table below). There were three causes:

1. **Batch renewal behind fast vehicles.** A fast player plans a new 300 m batch every ~5 s. Meanwhile the previous batch's vehicles have driven 140-200 m into the new range. Flow renews each lane from the front-most live vehicle, which is usually the fastest one. Its s* to a new vehicle at the lane's flow speed includes the closing term (a commuter at 115 km/h behind a new car at 95 km/h needs ~90 m). Only ~150 m of each batch is new road, so the band beyond the fog was already 10-25% short at planning time.
2. **IDM's equilibrium gaps.** A vehicle cruising near its desired speed keeps s*/√(1 − (v/v0)⁴), well above s*. Spawned lanes stretch out before the player reaches them. With the profiles' own headways (1.0-1.8 s), a lane holds about 13-14 vehicles per km at 95-135 km/h, whatever the director plans. Raising the target alone does nothing: target 20 gave 12.8/km around the fast player, and 2× gain gave 13.1/km.
3. **The cap on 4 lanes.** Cap 60 bound 6-21% of the ticks at legs 5-8.

A slower player (the bot) also loses the lanes it keeps pace with: nothing arrives from the front or from behind in a lane moving at the player's speed.

### What changed

All knobs live in `DirectorTuning` (`data/tuning/director.tres`), groups *Density around the player* and *Closer following in late legs*. All are marked "not in spec".

| Change | What it does |
| --- | --- |
| **Band top-up** (`density_topup_*`) | After each batch, every lane the player is catching (flow speed + 10 km/h below the player) is topped up to target × gain in the planned band beyond the fog, `[player + fog end + margin, spawned_to)`. Vehicles go in one at a time, into the largest gaps: in the middle of the stretch where Flow's drawn vehicle keeps s* (closing speed included) to both live neighbors. Every top-up goes through `_commit`: cap, ghost zone, beyond the fog, live gaps. At most 16 per batch. 6-22% of the ahead spawns are top-ups. Director rate. |
| **Density gain** (`density_gain_*`, `density_control_interval_s`) | Every 0.25 s, the relative shortfall of the window's effective density is integrated into a planning gain (0.05 per s per unit error, clamped to [0.7, 1.5]). Batches, top-ups and behind arrivals use target × gain. It corrects slow drifts both ways: 0.8-0.9 at legs 1-2, where the window runs over target, and 1.2-1.45 at legs 5-8. It is allocation-free (one capacity scan every 0.25 s). |
| **Closer following in late legs** (`headway_scale_first` 1.0 → `headway_scale_last` 0.8) | This is the only lever that raises the IDM ceiling (cause 2). It is ramped like the density: at leg 8 every driver profile's time headway T is 0.8 × its value (commuter 1.3 → 1.04 s, truck 1.8 → 1.44 s, aggressive 1.0 → 0.8 s). The director applies it on each leg change through `TrafficSim.set_headway_scale()` (director rate, three lines in the sim), and uses the same scale for Flow's spawn s*. With it the leg-8 ceiling rises from ~13 to ~16.5/km. Measured alternatives at leg 8 with target 20 on 3 lanes: T × 0.75 → 17.3, T × 0.6 → 18.4, and lane flow speeds 10-15 km/h lower → only 14.5-14.7. |
| **Leg ramp** | `density_last_per_km_lane` goes from 16 to **18** (leg 1 stays 8). |
| **Cap** | `max_active_vehicles` goes from 60 to **90**, sized from the 4-lane leg-8 need (80 active on average, peak 90). |
| **Dev knob** | `TrafficDirector.set_density_scale(f)` multiplies the target for batches, top-ups, behind arrivals and the opposite side. The run's DEV row 5 **DENS** cycles ×1.0 / ×1.25 / ×1.5 / ×0.75 and survives RETRY. DevStats gets `density` (effective, in the window), `density_target`, `density_scale` and `density_gain`. |

A platoon knob was tried and dropped: a share of the spawns placed right at s* behind the previous vehicle. At leg 8 it lowered the effective density from 81% to 71%, because the tight spawns brake, the lane stretches, and the band has to absorb it.

### Before / after (effective density, vehicles per km per lane)

`scripted` player (150-250 km/h, redrawn every 15 s):

| Lanes | Leg | Before: target | Before: effective | After: target | After: effective | After: in window / active (peak) |
| --- | --- | --- | --- | --- | --- | --- |
| 3 | 1 | 8.0 | 9.1 (114%) | 8.0 | **8.6 (107%)** | 19 / 30 (37) |
| 3 | 2 | 9.1 | 9.6 (105%) | 9.4 | **9.6 (102%)** | 22 / 34 (43) |
| 3 | 3 | 10.3 | 9.5 (93%) | 10.9 | **11.0 (101%)** | 25 / 39 (48) |
| 3 | 4 | 11.4 | 9.7 (85%) | 12.3 | **12.1 (99%)** | 27 / 43 (59) |
| 3 | 5 | 12.6 | 11.0 (87%) | 13.7 | **13.0 (95%)** | 29 / 46 (63) |
| 3 | 6 | 13.7 | 11.7 (85%) | 15.1 | **13.4 (89%)** | 30 / 49 (65) |
| 3 | 7 | 14.9 | 11.7 (78%) | 16.6 | **15.6 (94%)** | 35 / 56 (67) |
| 3 | 8 | 16.0 | 10.7 (67%) | 18.0 | **16.3 (91%)** | 37 / 59 (77) |
| 4 | 1 | 8.0 | 9.3 (116%) | 8.0 | **8.3 (103%)** | 25 / 39 (47) |
| 4 | 2 | 9.1 | 9.6 (105%) | 9.4 | **10.0 (106%)** | 30 / 46 (56) |
| 4 | 3 | 10.3 | 10.6 (103%) | 10.9 | **11.3 (104%)** | 34 / 53 (64) |
| 4 | 4 | 11.4 | 10.7 (94%) | 12.3 | **12.3 (100%)** | 37 / 58 (70) |
| 4 | 5 | 12.6 | 10.6 (84%) | 13.7 | **13.0 (95%)** | 39 / 63 (75) |
| 4 | 6 | 13.7 | 11.2 (82%) | 15.1 | **14.4 (95%)** | 43 / 69 (81) |
| 4 | 7 | 14.9 | 10.9 (73%) | 16.6 | **15.3 (93%)** | 46 / 75 (87) |
| 4 | 8 | 16.0 | 10.8 (68%) | 18.0 | **16.8 (93%)** | 50 / 80 (90) |

At leg 8, the fast player now meets **16.3 / 16.8 vehicles per km per lane instead of 10.7 / 10.8** (+52% / +55%): 37 instead of 24 vehicles in the window on 3 lanes, and 50 instead of 33 on 4 lanes. Every leg is within 89-107% of its target (before: 67-116%). The cells vary by about ±4% from seed to seed.

`bot` player (the soak's weaving bot aiming for 150-250 km/h; it averages 117-148 km/h):

| Lanes | Leg | Before: target | Before: effective | After: target | After: effective | After: in window / active (peak) |
| --- | --- | --- | --- | --- | --- | --- |
| 3 | 1 | 8.0 | 8.0 (100%) | 8.0 | **8.4 (105%)** | 19 / 34 (41) |
| 3 | 2 | 9.1 | 9.4 (103%) | 9.4 | **9.7 (103%)** | 22 / 39 (47) |
| 3 | 3 | 10.3 | 8.9 (86%) | 10.9 | **10.9 (101%)** | 25 / 43 (54) |
| 3 | 4 | 11.4 | 11.4 (100%) | 12.3 | **12.1 (98%)** | 27 / 48 (55) |
| 3 | 5 | 12.6 | 11.1 (89%) | 13.7 | **13.1 (96%)** | 29 / 53 (61) |
| 3 | 6 | 13.7 | 12.2 (89%) | 15.1 | **13.9 (92%)** | 31 / 56 (66) |
| 3 | 7 | 14.9 | 11.6 (78%) | 16.6 | **14.0 (84%)** | 31 / 59 (73) |
| 3 | 8 | 16.0 | 13.1 (82%) | 18.0 | **14.6 (81%)** | 33 / 60 (70) |
| 4 | 1 | 8.0 | 7.9 (99%) | 8.0 | **8.5 (107%)** | 26 / 45 (57) |
| 4 | 2 | 9.1 | 8.2 (89%) | 9.4 | **9.4 (100%)** | 28 / 52 (65) |
| 4 | 3 | 10.3 | 9.2 (89%) | 10.9 | **10.0 (92%)** | 30 / 56 (68) |
| 4 | 4 | 11.4 | 9.7 (85%) | 12.3 | **11.8 (96%)** | 35 / 63 (78) |
| 4 | 5 | 12.6 | 10.0 (80%) | 13.7 | **13.1 (96%)** | 39 / 70 (82) |
| 4 | 6 | 13.7 | 10.8 (79%) | 15.1 | **14.1 (93%)** | 42 / 75 (85) |
| 4 | 7 | 14.9 | 11.0 (74%) | 16.6 | **14.6 (88%)** | 44 / 77 (89) |
| 4 | 8 | 16.0 | 10.5 (66%) | 18.0 | **15.6 (86%)** | 47 / 80 (90) |

The bot at legs 7-8 stays at 81-88%, because it keeps pace with the left lanes. The spawn rules offer no fix: nothing may appear inside the fog, and behind spawns need the lane to be faster than the player. The gain sits at its maximum there. It still meets 12-48% more vehicles than before.

The lane profile follows lane discipline: the right lanes are denser (e.g. 14.8 / 16.7 / 17.4 per km, left to right, at leg 8 on 3 lanes). Zero rule violations in every cell.

### Cap and tick cost

- **Need:** at leg 8 on 4 lanes the director keeps 80 vehicles on average, with a peak of 90 (at the cap in about 1% of the ticks). On 3 lanes it is 59-60 on average, peak 70-77.
- **Tick cost:** the sim tick grows roughly linearly with the vehicle count, about 2.6-2.9 µs per vehicle on the dev container.
    - `soak_tick_cost_report` (one process, Xeon @ 2.1 GHz), median µs per 120 Hz `TrafficSim.step`:

      | Vehicles | 45, 3 lanes | 60, 3 lanes | 60, 4 lanes | 90, 3 lanes | 90, 4 lanes | 90, 4 lanes, all within 200 m | 110, 4 lanes |
      | --- | --- | --- | --- | --- | --- | --- | --- |
      | µs per tick | 126 | 199 | 166 | 234 | 260 | 182 | 292 |

      The fast tier's `test_tick_cost_at_the_cap` now benches at the tuning's cap (90, 4 lanes), with a budget of 10 µs per vehicle (15 µs when all are near). The director's step stays at 40-60 µs per tick in the survey.
    - **Phone:** the owner's iPhone measured 0.10 ms at 45 vehicles, where this container measures 126 µs, so the phone runs at about 0.8× the container's time. That extrapolates to about 0.14 ms at leg 8 on 3 lanes (~60 active), 0.18 ms on 4 lanes (~80 active) and at most 0.21 ms at the cap. At 60 fps that is about 0.4 ms of the 16.7 ms frame (two 120 Hz ticks per frame).
- **View:** `TrafficView` sizes every MultiMesh from the two states' capacities (`state.capacity`, and the cap follows `max_active_vehicles`), so nothing is hard-coded to 60. Draw calls are per model, not per vehicle, so they do not grow. `test_traffic_view` already benches 120 vehicles at 0.65 ms (day) and 0.73 ms (night) per render.

### Fairness

The top-up is an ahead spawn like any other. Soak results are in docs/SOAK.md, *D11 soak*.
