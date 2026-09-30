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
- **Driver mix:** each lane draws from its own mix (`Flow.draw_into`).
    - The racer share (10 → 15 %, plan D15) and the aggressive share (5 → 20 %) apply wherever each may drive: together the fast share rises from 15 % at leg 1 to 35 % at leg 8.
    - A lane that only fast profiles fit (none of the others reaches its flow band) is all fast; the racer and the aggressive driver share it in proportion to their shares.
    - Hesitant appears only from `hesitant_first_leg` and the profile's own `min_leg`.
    - The other profiles are weighted by `traffic.spawn_profile_weights_pct` (cruiser 22, commuter 40, truck 12, bus 4, van 10, motorbike 6, Hesitant 6; D15 moved 4 points from cruisers and 4 from Hesitant drivers to commuters and motorbikes).
- **Which lanes a profile may use:** a profile may spawn in a lane only if its top desired speed reaches the lane's flow speed minus `spawn_lane_speed_tolerance_kmh`. `keep_right` profiles use only the rightmost `spawn_keep_right_lane_count` lanes. A profile with `spawn_left_lane_count` N (the racer: 2) uses only the leftmost N lanes and never the rightmost one.
- **Speeds:** `v0` is drawn inside the profile's range, clipped to the lane's band, then jittered by up to ±`spawn_v0_jitter_pct` (5 %, D15) inside the profile's range and above a behind spawn's minimum, so a lane whose band clipped a range (Hesitant drivers in the middle lane) does not want one speed. Every vehicle spawns at its lane's flow speed (`v` = flow).
- **Type and looks:** the vehicle type is any type whose `allowed_profiles` lists the profile. The model variant is uniform. `color_index` indexes the biome's `traffic_palette`, or `spawn_palette_fallback_count` if the biome has none.
- **Randomness:** everything comes from `ctx.rng`. A re-roll calls `plan_batch` again and draws new numbers. `draw_into` and `plan_single` allocate nothing.

## Director

- **Ahead.** The director keeps batches (`spawn_batch_length_m`, 300 m) planned out to `max(spawn_ahead_m, fog_end + spawn_fog_margin_m)`. Each batch starts at `max(planned end, player s + fog_end + margin)`, so nothing appears inside the fog end. The run sets the fog end with `set_fog_end()`; it defaults to the default tier's view distance.
    - A batch is committed nearest-first.
    - Near the cap, the batch is thinned evenly. Dropping vehicles only widens gaps.
- **Behind.** For each lane from the median (`spawn_behind_lane_count`, and never the slow lane), a lane builds up an arrival debt of `density × (v_lane − v_player)` while the player is slower than that lane by more than `spawn_behind_speed_margin_kmh`.
    - When one arrival is owed, the director spawns a vehicle `spawn_behind_m` (150 m) behind the player. The spawn point must be out of view. The view test is `TrafficDirector.is_visible(s, d)`, a fixed virtual view volume: anything ahead of `player s − behind_spawn_view_margin_m` (25 m, `DirectorTuning`) is in view. Every camera mode sits ≤ 11 m behind the car and looks forward, so a spawn 150 m behind is never visible, and camera mode and screen aspect never change traffic (leaderboards, Daily Drive; orchestrator decision in WP4.8). The `frustum_check(s, d) -> bool` Callable is only an optional dev/test override. The run, the drive scene, the sandbox and the soak no longer set it.
    - The vehicle's IDM gaps must also fit, and the player counts as the leader.
    - **Racer arrivals** (plan D17, WP6.7) come on top of these: fast cars that arrive on their *own* speed, also when the player is faster than every lane. See *Racers from behind (WP6.7)* below.
- **Despawn.** A vehicle despawns when it is more than 200 m behind the player, or ahead of the player's `s` by more than the ahead distance + one batch + `spawn_despawn_ahead_margin_m`.
- **Every spawn** goes through `_commit` in this order:
    1. the cap (`max_active_vehicles`)
    2. the ghost zone (the player's box plus `spawn_ghost_margin_long_m` / `_lat_m`; the run may widen it with `set_ghost_zone`)
    3. no pop-in (ahead beyond the fog, or behind and out of view: `is_visible`)
    4. `sim.spawn(rec)`
- **Start of run.** `reset(player)` fills the road from the player to the ahead distance before anything is drawn. It still keeps out of the ghost zone and places nothing behind the player.
- **Per tick.** `step(dt, player)` runs after `traffic_sim.step`. The despawn scan, the behind bookkeeping and the opposite side allocate nothing. Only batch planning allocates, at director rate.

## Opposite carriageway

- **Density:** `opposite_density_pct` of the leg's density over the window from `opposite_recycle_behind_m` behind the player to the ahead distance, capped at `opposite_max_vehicles`.
- **Speed:** each lane has one constant speed, `opposite_speed_kmh` plus `opposite_lane_speed_step_kmh` for each lane toward the median. Vehicles never close on each other, and there are no collisions.
- **Recycling:** a vehicle that passes behind the camera is re-placed beyond the ahead line. It goes past the front-most vehicle of the lane with the most room, by a jittered mean spacing, so the count stays stable. `FLAG_HEADLIGHTS` follows `set_night()`.

## Growing it (Phase 6)

- Intensity waves and blind-window caps: WP6.2, below (*Intensity waves*, *Blind crests and bends*).
- Passability and re-rolls go between `plan_batch` and the commit in `_plan_range()` (WP6.1).
- Set pieces: `source` is `SetPieceSource` (WP6.2, [SET_PIECES.md](SET_PIECES.md)), which plans Flow around its pieces. Flow stays in charge of behind spawns and the opposite side's mix.


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
| **Density gain** (`density_gain_*`, `density_control_interval_s`) | Every 0.25 s, the relative shortfall of the window's effective density is integrated into a planning gain (0.05 per s per unit error, clamped to [0.7, 1.5]; plan D17: [0.7, 1.8]). Batches, top-ups and behind arrivals use target × gain. It corrects slow drifts both ways: 0.8-0.9 at legs 1-2, where the window runs over target, and 1.2-1.45 at legs 5-8. It is allocation-free (one capacity scan every 0.25 s). |
| **Closer following in late legs** (`headway_scale_first` 1.0 → `headway_scale_last` 0.8; plan D17: 0.55) | This is the only lever that raises the IDM ceiling (cause 2). It is ramped like the density: at leg 8 every driver profile's time headway T is 0.8 × its value (commuter 1.3 → 1.04 s, truck 1.8 → 1.44 s, aggressive 1.0 → 0.8 s). The director applies it on each leg change through `TrafficSim.set_headway_scale()` (director rate, three lines in the sim), and uses the same scale for Flow's spawn s*. With it the leg-8 ceiling rises from ~13 to ~16.5/km. Measured alternatives at leg 8 with target 20 on 3 lanes: T × 0.75 → 17.3, T × 0.6 → 18.4, and lane flow speeds 10-15 km/h lower → only 14.5-14.7. |
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


## Intensity waves (WP6.2)

Spec: *Traffic director*: "Intensity waves. Tension and release in cycles of 45–90 s: build, peak (often a set piece), then a 10–15 s breather. Every leg ends with a short breather before the checkpoint." `src/traffic/intensity_waves.gd` (`IntensityWaves`, owned by the director as `waves`); numbers in `DirectorTuning`, group *Intensity waves*.

### The curve: timed by distance at a reference pace

The waves are laid out **along the road**, as the intensity (0 breather … 1 peak) at the **player's** road position `x`:

- Each leg (checkpoint to checkpoint; on a road without CHECKPOINT features, `LegsTuning`'s grid of `leg_length_m`) is filled with *n* whole cycles. A cycle lasts `wave_period_min_s`–`wave_period_max_s` (45–90 s) and its seconds become meters at `wave_reference_pace_kmh` (160 km/h, a typical sun-chasing speed). *n* is drawn among the counts that fit the leg; the durations are drawn and scaled to fill it exactly.
- A cycle is a **build** (intensity rising linearly from `wave_build_start_intensity`, 0.5, to 1), a **peak** (1; `wave_peak_min_pct`–`wave_peak_max_pct`, 25–40 %, of the build + peak) and a **breather** (0; `breather_min_s`–`breather_max_s`, 10–15 s).
- The leg's last breather is the **checkpoint breather** (`checkpoint_breather_min_s`–`_max_s`, 10–15 s) and ends exactly at the checkpoint; the next leg starts with a build. At the reference pace a 3.5 km leg (79 s) holds one cycle: build ~45 s, peak ~20 s, breather ~12 s; a longer leg holds two.
- Everything is drawn in road order from one stream, `run.rng_traffic.derive(&"waves")`, so the curve depends only on the seed and the checkpoints: the same for every player (Daily Drive). Each peak also carries its two set-piece draws (chance, kind).
- **Why distance:** the checkpoint breather has to end at the checkpoint whatever the player's speed, and a curve along the road is the same for everyone. A slower player takes longer to drive a cycle (a 60 s cycle at 160 km/h is 74 s at 130 km/h), a faster one less.
- Density multiplier at intensity *I*: `lerp(wave_breather_density_pct, wave_peak_density_pct, I)` = 70 % … 125 % of the leg's target (build 97.5 % → 125 %; WP6.2 had 50 % breathers, plan D17 raised them, see *Fast traffic and density*). A cycle plans ~107 % on average; at leg 8 the peaks are capped by IDM.

### The meeting map: what traffic belongs to which part of the wave

Traffic is planned ~780 m ahead, beyond the fog, and the player meets a vehicle of a slower lane only when it catches up with it. A vehicle planned now at `s` in a lane of speed `v` is met at

```
x_meet = player s + (s − player s) · pace / max(pace − v, wave_min_closing_kmh)     (clamped to wave_meet_lookahead_m, 4 km)
```

with `pace` the player's speed smoothed over `wave_pace_smoothing_s` (5 s). Flow plans every vehicle at the wave's density **where the player will meet it**, so the density the player meets follows the curve in every lane, whatever the lane's speed (a batch spans 14–30 s of meeting time in the slow lanes, far more in the fast ones). For a vehicle holding its speed `x_meet` does not change as time passes, which the tests use as a check.

### How the director uses it

- **Flow** (`SpawnSources.Flow.shaper`): each spacing is the wave's where the next vehicle will be (`1000 / (ctx density × density_mult / ref_mult)`, taken half a spacing on). `ctx.density_per_km_lane` and `ctx.intensity` are the batch's representative (its middle, the middle lane's flow speed): other sources can read the level from the context as the contract says.
- **Overlapping batches:** each batch overlaps traffic of earlier batches that drove into it, and Flow used to fill any gap between live vehicles that the renewal draw fit into. That kept lanes full as IDM stretched them (D11), but it also filled every breather. Now Flow puts a vehicle between live ones only where the wave's multiplier is at least `wave_fill_min_mult` (0.75): builds and peaks stay topped up, breathers and blind windows stay thin. The band top-up follows the same rule, fills lanes to the wave's integral over the band (`_band_want`), and takes the largest gap weighted by the wave's multiplier there.
- **Behind arrivals** use the wave at the player (`mult_at(player s)`); they pass the player now.
- **The density gain (D11)** tracks the **wave-shaped** target: the flat target × `window_mult`, the mean multiplier the window's traffic was planned at (for lanes the player is not catching: the wave at the player). Its error is low-passed over `wave_gain_smoothing_s` (20 s) before it is integrated, because the window follows the waves with a lag and the gain must not swing with them. `TrafficDirector.window_target` is the target.
- **Night:** the same density as day (`set_night` changes nothing else).

Measured (fast tier, `test_traffic_director_waves.gd`, leg 4, the player at 170 km/h past traffic that holds its speed): the player meets **14 vehicles per km in peaks, 13 in builds, 6.6 in breathers**.

## Difficulty by leg (WP6.2)

| | Leg 1 | Leg 8 and on | Where |
| --- | --- | --- | --- |
| Density | 8 | 18 (D11) vehicles per km per lane | `density_*_per_km_lane` |
| Aggressive share | 5 % | 20 % | `aggressive_share_*_pct` |
| Racer share (D15) | 10 % | 15 % | `racer_share_*_pct` (block *Fast traffic*) |
| Hesitant | no | from leg 3 | `hesitant_first_leg` (and the profile's `min_leg`) |
| Set-piece kinds unlocked | 1 | 7 | `set_piece_unlock_order`, `set_pieces_unlocked_by_leg` = 1, 2, 3, 4, 5, 6, 7, 7 |
| Chance a peak gets a set piece | 50 % | 80 % | `set_piece_chance_*_pct` |

All ramp linearly from leg 1 to leg 8 and hold (`leg_ramp`); `test_difficulty_ramps_by_leg` and `test_flow_mix_follows_the_leg` pin them.

## Blind crests and bends (WP6.2, fairness rule 6)

"Within 150 m after a blind crest or bend, the director caps density at 60% and allows no set pieces." IntensityWaves keeps the BLIND_CREST and BLIND_BEND features ahead (`[start, end]`). The traffic hidden by a blind feature `[a, b]` is what is within `[p, b + blind_window_m]` ahead of the player at some moment while it drives `p ∈ [a, b]`. In the meeting map that is exactly the vehicles met at

```
a ≤ x_meet ≤ a + (b − a + blind_window_m) · pace / closing speed
```

so `density_mult` caps them at `blind_density_cap_pct` (60 %), in every lane at its own closing speed, and no fill or top-up goes there. A set piece is only scheduled where none of it (rear, middle, front) is in such a window (`SetPieceSource.fits_road`). Tests on real procedural roads (`test_blind_windows_cap_density_on_real_roads`, 8 crests): every vehicle in a blind window was planned at ≤ 60 %, and the density there is 0.59 of the density elsewhere; `test_no_set_pieces_in_blind_windows_or_at_checkpoints`: none of 9 set pieces is in one.

## Lane drops and lane closures (WP6.2)

WP6.4a's canyon tunnels drop the road from 3 to 2 lanes (a LANE_COUNT_CHANGE with a 250 m taper; `lane_count` steps at its start, `lanes_right_edge_d` follows the taper) and add the lane back after. Traffic merges before the drop instead of riding the shoulder:

- **Closures** (`TrafficSim`, block *Lane closures and mandatory merges*): lane *l* cannot be driven over `[s0, s1]`. The director turns the road's lane-count changes ahead into closures (`sync_road_closures`, director rate; the dropped lanes over the change's start and taper, and a widening's new lane while its taper runs) and forgets them behind. WP6.3's merge zone and road works add their own by tag: `add_lane_closure(lane, s0, s1, tag)`, `remove_lane_closures(tag)`.
- **Mandatory merge:** a vehicle in a lane that closes within `merge_zone_m` (600 m) evaluates, every model tick, MOBIL for the lanes beside it with an incentive bonus ramping from 0 to `merge_urgency_mps2` (2 m/s²) at the closure. Safety and no-ambush apply as always, the blinker runs the profile's signal time, and a Hesitant driver never cancels it. Set-piece vehicles merge too.
- **Waiting at the end of the lane:** until it has started moving out, the vehicle brakes (IDM) for a standing obstacle `merge_stop_margin_m` (15 m) before the closure. One that finds no gap stops there and waits for one.
- **Nobody moves into** a lane that closes within `merge_zone_m`, and no motorbike lane-splits next to one.
- **Spawns** (`Flow.lane_open_for_spawn`): never in a lane that ends within `merge_spawn_clear_m` (400 m) ahead, is being narrowed by a taper, or has a closure within that distance. Behind spawns and the band top-up check the same.
- **Density:** the effective density divides by the lane count along the window, not at the player.
- **Set pieces** are never scheduled across a lane-count change, tunnel or fork, and end (merging like any traffic) if they roll within `clear_ahead_m` of one.

Tests: `tests/unit/test_traffic_director_lane_drops.gd` (merging, waiting, no moves into a closing lane, no ambush, spawns, determinism, and a canyon tunnel with the soak's director, sim and bot) and the soak tier's `soak_canyon_lane_drops` (two canyon journeys). The rule checker now fails any tick where a car's body leaves the driving lanes (`offroad_violations`, a soak gate).

## Daily Drive (WP6.2)

Daily is Flow on the date-seeded run context (`RunContext.daily(y, m, d)` → `run.rng_traffic`); `SetPieceSource` wraps it like Flow, and the waves, set-piece draws and piece layouts derive from the same stream. Two players on the same date driving the same inputs get the same road, traffic and set pieces (`test_daily_source.gd`: identical traces and set pieces for the same date, different for another).

## Density at leg 8 with waves, rule 6 and set pieces (WP6.2)

The D11 survey (`--density --lanes=3 --legs=8 --profile=scripted`, 3 seeds × 7 km):

| Configuration | Leg 8, 3 lanes | Per lane (left → right) |
| --- | --- | --- |
| D11 (flat, before WP6.2) | 16.3 (91 %) | 14.8 / 16.7 / 17.4 |
| WP6.2, flat waves, no set pieces, no blind cap | 16.3 (91 %) | same (bit-identical) |
| WP6.2, waves, no set pieces | 14.9 (83 %) | 13.8 / 15.2 / 15.6 |
| WP6.2, waves and set pieces (default) | 13.2–13.4 (73–74 %) | 11.8 / 13.6 / 14.6 |

At leg 8 the lanes sit at IDM's ceiling (T × 0.8), so peaks cannot go above it: the waves take density away in breathers and early builds, and set pieces clear their zone (and, in their lanes, the slower traffic they would catch up with). Leg 4 delivers 92–94 % of its target. See the WP6.2 handoff for the open question to the owner. Plan D17 (WP6.6) rebalanced it: *Fast traffic and density* below.

## Fast traffic and density (D15, D17; WP6.6)

Plan D15 (owner, M5: "the traffic is quite slow ... a variety of fast cars") and D17 (WP6.2's waves and set-piece clearing brought leg 8 down to 74 % of its target; the owner wants late legs crowded). The driver side is in docs/TRAFFIC.md, *Fast traffic (D15)*.

### What changed

| | Before | After | Where |
| --- | --- | --- | --- |
| Lane flows (from the right) | 95 / 115 / 135 / 150 km/h | **95 / 120 / 145 / 160** | `traffic.lane_flow_speeds_from_right_kmh` |
| Racer share (new, 190-250 km/h) | – | **10 → 15 %** (two left lanes) | `director.racer_share_*_pct` |
| Aggressive share | 5 → 20 % (spec) | unchanged; fast total **15 → 35 %** | `director.aggressive_share_*_pct` |
| Commuter / aggressive speeds | 100–130 / 150–190 km/h | **95–145 / 140–200** | `data/driver_profiles/` |
| Desired-speed jitter | – | **±5 %** | `traffic.spawn_v0_jitter_pct` |
| Mix of the others | cruiser 26, commuter 34, truck 12, bus 4, van 10, motorbike 4, Hesitant 10 | **22, 40, 12, 4, 10, 6, 6** | `traffic.spawn_profile_weights_pct` |
| Breather density | 50 % | **70 %** (peak stays 125 %) | `director.wave_breather_density_pct` |
| Late-leg headway (T ×, leg 8) | 0.8 | **0.55** | `director.headway_scale_last` |
| Density gain range | 0.7–1.5 | **0.7–1.8** | `director.density_gain_max` |

Why the density levers: at leg 8 the lanes sit at IDM's ceiling (the equilibrium gap `(s0 + vT) / √(1 − (v/v0)⁴)`), so the waves' peaks cannot rise above it and deep breathers only took density away; faster lanes lower the ceiling further (a lane at 145 km/h holds fewer cars at the same headway than one at 135). Closer following in late legs raises the ceiling (commuters 1.3 s → 0.72 s at leg 8, trucks 1.8 → 1.0 s, racers 0.9 → 0.5 s), shallower breathers lose less, and the gain may go higher where the window still falls short. Raising the leg-8 target instead made it worse (target 22: 12.6 per km per lane, more vehicles packed at s* brake and stretch their lanes); `wave_fill_min_mult` below the breather (refilling breathers) erased the waves.

### Before / after

`--density --profile=scripted --seeds=4 --run-legs=4` (4 runs × 14 km per cell at one fixed leg; the observer at 150–250 km/h, redrawn every 15 s). "Before" is the integration branch with WP6.2 (6e486c7). The survey's procedural road has no forks and asks for no breathers (WP6.5's hooks stay idle), so neither is in these numbers. Effective density in the window [−150, +600 m], vehicles per km per lane:

| Lanes | Leg | Target | Before | After |
| --- | --- | --- | --- | --- |
| 3 | 1 | 8.0 | 7.75 (97 %) | **7.93 (99 %)** |
| 3 | 4 | 12.3 | 11.42 (93 %) | **12.11 (99 %)** |
| 3 | 8 | 18.0 | 13.36 (74 %) | **14.94 (83 %)** |
| 4 | 1 | 8.0 | 7.91 (99 %) | **8.10 (101 %)** |
| 4 | 4 | 12.3 | 11.67 (95 %) | **12.16 (99 %)** |
| 4 | 8 | 18.0 | 14.66 (81 %) | **15.99 (89 %)** |

(D11, before WP6.2: 16.3 and 16.8 at leg 8.) Zero rule violations in every cell; peak active 90 at leg 8 on 4 lanes, at the cap under 1 % of the time.

Speeds of the traffic in the window (same cells; lane means from the median):

| Lanes, leg | Before: mean, per lane | Before: > 150 / 180 / 200 | After: mean, per lane | After: > 150 / 180 / 200 |
| --- | --- | --- | --- | --- |
| 3, leg 1 | 112; 126 / 117 / 102 | 1 / 0 / 0 % | **121; 138 / 127 / 106** | 4 / 0 / 0 % |
| 3, leg 4 | 111; 123 / 113 / 101 | 0 / 0 / 0 % | **122; 134 / 127 / 108** | 3 / 1 / 0 % |
| 3, leg 8 | 112; 122 / 115 / 101 | 0 / 0 / 0 % | **123; 136 / 127 / 110** | 5 / 1 / 0 % |
| 4, leg 8 | 120; 135 / 128 / 117 / 103 | 2 / 0 / 0 % | **128; 147 / 140 / 127 / 104** | 10 / 1 / 0 % |

The window undercounts fast traffic: what is faster than the observer leaves it ahead and only comes back from behind when the player is slower than the lane. Over every active vehicle, racers average **186 km/h at leg 1** and 143 km/h at leg 8 (crowded, they weave), aggressive drivers 138 and 144 km/h (3 lanes).

### The waves at the player (D17)

Density within [−100, +200 m] of the player by the phase it is in, and vehicles it passes per km driven per lane (WP6.2's "met per km"), 3 lanes:

| Leg | | Build | Peak | Breather |
| --- | --- | --- | --- | --- |
| 4 | before: at the player / passed | 12.5 / 4.9 | 10.3 / 4.5 | 9.8 / 4.2 |
| 4 | after | **12.9 / 4.2** | **11.0 / 4.6** | **10.1 / 3.7** |
| 8 | before | 14.5 / 5.6 | 11.6 / 5.1 | 12.8 / 5.4 |
| 8 | after | **16.3 / 5.6** | **12.9 / 5.5** | **11.4 / 4.4** |

4 lanes after: leg 4 12.9 / 11.6 / 10.6 (passed 4.1 / 4.6 / 3.4), leg 8 15.4 / 16.9 / 15.9 (4.9 / 6.8 / 6.0). Breathers stay the thinnest phase and are more distinct at leg 8 than before (the D17 levers put the density back into builds and peaks).

**Finding (open, for the director's owner):** with the real sim, peaks at the player are *thinner* than builds (before and after, 3 lanes). A peak planned above IDM's ceiling places its vehicles at s*, where IDM brakes (`s*` at Δv = 0 is below the equilibrium gap). They slow down and the player meets them earlier, in the build: the peak slides into the build. Planning each lane at no more than its equilibrium density at its speed (the gap `(s0 + vT) / √(1 − (v/v0)⁴)` instead of `s*`) would keep peaks where they are planned. The meeting map also uses the lane's flow speed, while fast profiles run above it and platoons below it. Not changed here (Flow's shaping and the meeting map are WP6.2's code).

### The trade-off (what the owner may want to decide)

Faster lanes hold fewer cars at the same headways. Measured at leg 8, 3 lanes, before the D17 levers: flows 95 / 115 / 135 → 16.5 per km per lane (flat waves), 95 / 130 / 165 → 12.7 (−23 %; traffic 148 km/h, 42 % above 150 km/h, racers 174 km/h at leg 8, 196 at leg 1). With every D17 lever, 95 / 120 / 145 gives 83 % of the target and the pre-D15 flows 86 %. So the fast lane gained +10 km/h, not the +35-45 km/h of a 170-180 km/h fast lane, and the extra speed comes from the racers and the wider spreads. A fast lane at 165+ km/h needs either a lower late-leg density or closer following than T × 0.55.

### Tools

`tests/soak/density_survey.gd` also reports the speed distribution (share above 150 / 180 / 200 km/h, mean per lane, racer and aggressive means), the density by wave phase (window, at the player, passed per km), the director's refused and behind shares; profile `steady` holds the observer at 200 km/h. `soak_main.gd -- --density` what-ifs: `--racer=`, `--aggressive=`, `--jitter=`, `--tolerance=`, `--lookahead=`, `--breather=`, `--peak=`, `--fill=`, `--set-pieces=`, `--set=profile.field=X;...`.

## Racers from behind (plan D17, WP6.7)

Owner (D17): *"Yes, pass me at speed."* The owner usually drives at 170-230 km/h. Behind spawns (above) need the player to be at least `spawn_behind_speed_margin_kmh` slower than a lane's flow (95-160 km/h), so at those speeds racers (D15, 190-250 km/h) only ever appeared ahead. Spec: *Spawning* ("faster vehicles spawn about 150 m behind in the left lanes, only when the player is slower than them and the spawn point is outside the camera frustum"; "them" is now the arriving car, not the lane), *Driver types* (Aggressive "passes the player from behind"), the fairness rules and rear-end prevention.

Code: `TrafficDirector` (block *Racers from behind*: `_step_arrivals`, `_arrival_window_open`, `_try_arrival`, `_arrival_fits`, `_step_passes`; neither `_commit` nor the WP6.5 hook changed), `SpawnSources.Flow` (*Arrival records*: `draw_arrival_into`, `arrival_lane_ok`, `max_speed_behind`, `braking_spacing`). Numbers: `DirectorTuning`, group *Racers from behind*. Tests: `tests/unit/test_racer_arrivals.gd`.

### The arrival process

- **Clock.** Arrivals come every `racer_arrival_interval_s(leg)`: a uniform draw in 20-40 s at leg 1, ramped like the density to 10-20 s at leg 8 (`racer_arrival_interval_*`). The clock runs at the wave's density multiplier where the player is (97.5-125 % in builds and peaks) and stops:
    - in wave breathers and the checkpoint breather (the player's phase is BREATHER),
    - while a requested breather (WP6.5: an unresolved fork's approach, the journey finale) overlaps [spawn point, player + `racer_arrival_clear_ahead_m` (2 km)]: a racer passing now would reach the fork guard and be removed in view,
    - while a live set piece's zone (scheduled or running, its clear-behind and clear-ahead included; a road-anchored piece's zone on the road, WP6.3) overlaps the same range: a faster car would drive into it.
- **Who.** A racer, or with `racer_arrival_aggressive_pct` (25 %) an aggressive driver when its profile can be fast enough. Its desired speed is drawn in the profile's range **at least `racer_arrival_speed_margin_kmh` (15 km/h) above the player's speed**. A player faster than 235 km/h gets none (nothing is fast enough to pass it). Randomness: its own stream, `run.rng_traffic.derive(&"racer_arrivals")`, so Flow's draws are untouched.
- **Where.** Out of view behind the player: `spawn_behind_m` (150 m), else 130, 110 or 90 m (`racer_arrival_behind_min_m`, `_step_m`), all far beyond the camera-independent view volume (`behind_spawn_view_margin_m`, 25 m; the cockpit mirror is a static gradient). Lanes: the racer's own (`spawn_left_lane_count`, never the rightmost), the aggressive driver the behind lanes (`spawn_behind_lane_count`); lanes without the player first, leftmost first; never a lane that feeds ordinary behind spawns right now (so a slow player does not get both).
- **Only where it passes legally** (`_arrival_fits`):
    - *No hard braking at spawn:* its spawn speed is the highest in [player + margin, its desired speed] that keeps IDM's s* (closing speed included) to every vehicle ahead in its lane and to the player when the player is in it (`Flow.max_speed_behind` inverts s*). At s* the IDM braking is at most its comfortable deceleration.
    - *A clear run:* holding that speed it gets `racer_arrival_pass_clear_m` (40 m) past the player (the player and the lane's traffic predicted at their own speeds) before any car ahead in its lane that is slower than the player makes it brake below the player's speed (`Flow.braking_spacing`: the comfortable stop from the player's speed to the car's, plus its equilibrium gap). So it reaches the player and gets by instead of queueing, out of view, behind a car the player is passing.
    - The player itself is no obstacle: an arrival in the player's lane (only when no other lane fits; on a 2-lane road the racer's only lane) comes up behind it braking comfortably, IDM with the player as its leader, and pulls out with its blinker (MOBIL) to pass.
    - Then Flow's neighbor check, clear of set pieces and of a toll gantry's speed zone (`spawn_speed_ok`, WP6.3), and the usual `_commit` (cap, ghost zone, view, live gaps, breathers). A due arrival that fits nowhere retries every `racer_arrival_retry_s` (0.5 s).
- **After the spawn** it is ordinary traffic: IDM, MOBIL with blinkers, no-ambush when it cuts back in front of the player, the 6 m/s² clamp, rear-end prevention. It counts toward the cap and the window density.
- **Counters** (per run): `racer_arrivals`, `arrivals_passed_player`, and for every racer (Flow's or an arrival) `racers_passed_player` / `racers_overtaken` (side changes around the player with hysteresis, every `racer_pass_check_interval_s`). The dev report (COPY) prints them as `racers    passed you N, you overtook M, arrivals K (J passed you)` (`DevReport.racers_line`, from the scene's `director`: the run and the sandbox); the sandbox also reports `racers_passed_you`, `racers_overtaken` and `racer_arrivals` to DevStats and shows the line in its stats panel.
- **Sandbox:** the fifth row at the top right (under FAST / RACER; the MOBIL side panel moved below it), `ARR ON/OFF` (kept across re-seeds) and `ARRIVE` (the next arrival is due now; it is selected when it spawns). Snap: `tools/snap.sh src/traffic/dev/traffic_sandbox.tscn --driver=keep --speed_kmh=200 --leg=2 --arrival=true` (clears the traffic near the player and runs until the arrival passes).
- **Cost:** allocation-free; a try scans the capacity once per candidate lane; the pass counter runs at 10 Hz. The director's tick in the density survey is unchanged (below).

### Measured

**Passes per km** (arrivals that got past the player, per km the player drove; 3 lanes, `tests/unit/test_racer_arrivals.gd` and a measurement run of the same setups):

| Player | Leg | 170 km/h | 200 km/h | 230 km/h |
| --- | --- | --- | --- | --- |
| Holding its speed, no other traffic (the process alone; 10 km per cell) | 1 | 0.60 | 0.50 | 0.30 |
| | 4 | 0.70 | 0.60 | 0.40 |
| | 8 | 1.30 | 1.00 | 0.70 |
| Holding its speed through full traffic (the density survey's observer, which traffic neither follows nor yields to; 30 km per cell; before WP6.3's merge) | 1 | 0.03 | 0.03 | 0 |
| | 4 | 0.03 | 0.03 | 0 |
| | 8 | 0.07 | 0.07 | 0 |

- On a free road the first arrival passes a 170 / 200 / 230 km/h player after 1.1-1.8 / 1.6-2.3 / 2.8-3.7 km (leg 8 ... leg 1; `test_racers_arrive_and_pass_a_*_kmh_player_on_every_leg`, gate 7 km). A 230 km/h player is passed by 245-250 km/h cars only, closing at 4-6 m/s.
- The soak's weaving bot (it follows traffic, 130 km/h on average whatever speed it aims for; 2,016 km): **0.44 arrivals and 0.39 passes per km** (88 % of the arrivals passed it). Before WP6.7 nothing passed a player faster than the lanes' flow + 10 km/h.

**Why so few in full traffic at 170-230 km/h (finding, for the owner):** a player that fast overtakes every lane (flows 95-160 km/h), so the lanes behind it are full of cars it has just passed, and the lanes ahead of it hold cars it is about to pass. A racer can only get by legally if it has a clear run: IDM starts braking for a slower car ahead at s* (closing term included: ~200-290 m for a 215-250 km/h racer behind a 145 km/h car), and MOBIL only changes lanes into gaps that are safe for the new follower, so a racer cannot weave through leg-8 traffic faster than a player cutting gaps (racers average 143 km/h at leg 8, D15). An arrival that queues behind a passed car stays out of view and is useless, so `_arrival_fits` only spawns ones with a clear run, and those are rare in dense traffic at these speeds (at 230 km/h none in 90 km). Ways to get more passes at speed, each an owner / orchestrator decision outside WP6.7: a sparser "passing lane" (the leftmost lane below the leg's density, slow profiles out of it: costs D17 density), racers that weave harder (shorter MOBIL gaps, b_safe, T for the racer profile), or more arrivals in breathers (the brief keeps breathers free of them).

**Density (D11 / D17):** the survey (`--density --lanes=3,4 --legs=8 --profile=scripted --seeds=4 --run-legs=4`), arrivals off → on, zero violations in every cell:

| Tree | 3 lanes, leg 8 | 4 lanes, leg 8 |
| --- | --- | --- |
| WP6.6 integration (before WP6.3) | 14.94 → **15.25** (83 → 85 %) | 15.99 → **15.99** (89 %) |
| Merged with WP6.3 (set pieces) | 15.18 → **15.05** (84 %) | 15.92 → **15.92** (88 %) |

Per seed the cells move by chaos only (8 seeds each, before WP6.3: 3 lanes +0.9 %, 4 lanes −0.9 %); the director's tick is unchanged (51 / 57 µs before, 51 / 58 without arrivals). `soak_density_survey_with_arrivals` (soak tier) checks ±3 % against the same survey with arrivals off.

**Soak** (`tools/soak.sh --km=2000 --shards=4` on the tree merged with WP6.3: 2,016 km in 72 runs, 15.6 simulated hours, wall 3,581 s on a shared container): collisions 0, signal 0, unsignaled 0, no-ambush 0 (43,852 lane moves checked), decel 0 (min −6.00 m/s²), brake flags 0, **rear-ends of a normally driving player 0** (148 contact episodes, 137 from behind, all after the bot's own move or hard braking), impossible windows (traffic) 0 (114, all player-induced), off-road 0, closed areas 0: **GATE PASSED**. **892 arrivals (0.44 per km), 787 passed the bot (0.39 per km, 88 %)**; racers of any origin passed it 0.76 times per km and it overtook them 0.19 times per km. The same soak before the merge: 878 arrivals, 781 passed, every gate 0. The bot spends 4.8 % of its time at 170-230 km/h (it aims there in ~43 % of its legs, `soak_bot_min_kmh`-`_max_kmh` = 110-250, but follows traffic: 130 km/h on average); the free-road and rear-end tests hold the player at 170, 200 and 230 km/h instead (`TrafficBotPlayer` is a shared fixture). `TrafficSoakRun.result()` now carries `racer_arrivals`, `arrivals_passed_player`, `racers_passed_player`, `racers_overtaken`, `ticks_fast` and `ticks_170_230` (per run, in the shard files).

**Rear-end prevention:** a 250 km/h racer in the player's lane 150, 300 or 560 m (the IDM lookahead) behind a 170 km/h player that brakes to 120 km/h at 6 m/s² at 0-14 s: no contact (closest bumper gap 108 m), the racer brakes at most at the 6 m/s² clamp. An arrival that comes up behind a 170-230 km/h player in its lane (2-lane road) and meets it braking to 120 km/h: no contact, within the clamp; coming up behind the player it brakes at most 1.7 m/s².

**Metrics baseline** (`tests/baselines/traffic_metrics.json`, rewritten deliberately on the tree merged with WP6.3), against WP6.3's: lane changes per vehicle-minute 1.040 → **1.146** (+10 %: arrivals are racers and aggressive drivers, which change lanes twice as often, and they pull out to pass), mean speed lane 0/1/2 140.4 / 127.6 / 116.6 → **142.8 / 128.1 / 113.9** (fast arrivals in the left lanes), density 9.90 → 10.05, gaps per km 8.55 → 8.70, set pieces per leg 0.023 → **0.031** (3 → 4 pieces in 128 legs: the only metric beyond ±15 %; a count of a few pieces that any traffic change moves, see docs/SOAK.md). (On the tree before WP6.3 the same change was 4 → 7 pieces, lane changes +12 %.)

## Racers weave harder (plan D17, WP6.9)

Owner (D17), after WP6.7's finding above: *racers weave harder*, density unchanged. The driver side (the racer's new *Weaving* fields: T 0.5 s, s0 1.0 m and b_safe 4.5 m/s² toward traffic, a 300 m lookahead lane choice, at most 2 lane changes per 10 s; nothing relaxed toward the player) is in docs/TRAFFIC.md, *Racers weave harder*. Nothing in the director changed.

### Measured: passes per km through full traffic

`RacerPassSurvey` (`tests/soak/racer_pass_survey.gd`; `soak_main.gd -- --passes [--lanes=3] [--legs=4,8] [--speeds=170,200,230] [--seeds=8] [--set=...]`; soak tier `test_racer_weave.gd::soak_racers_pass_through_traffic`): WP6.7's harness, the density survey's observer held at 170 / 200 / 230 km/h off the carriageway (traffic neither follows nor yields to it) through full traffic at one fixed leg, 8 runs × 2 × 3.75 km per cell (~50 km after a 20 s warm-up), the rule checker on every tick. "Passes" are arrivals that got past the observer (WP6.7's number); "racers passed" counts every racer, from behind or from ahead, that came past it. Before = the WP6.7 tree (weaving off), after = this WP.

| 3 lanes | | 170 km/h | 200 km/h | 230 km/h |
| --- | --- | --- | --- | --- |
| Leg 4 | passes / km, before → after | 0.00 → **0.10** | 0.02 → **0.00** | 0.00 → **0.00** |
| | racers passed / km | 0.02 → 0.13 | 0.02 → 0.00 | 0 → 0 |
| | racers the observer overtook / km | 0.46 → 0.53 | 0.65 → 0.70 | 1.23 → 1.41 |
| | racer mean speed, km/h | 153 → 157 | 165 → 165 | 164 → 155 |
| | racer lane moves (per ~50 km) | 108 → 210 | 133 → 174 | 111 → 190 |
| Leg 8 | passes / km | 0.11 → **0.08** | 0.02 → **0.02** | 0.00 → **0.00** |
| | racers passed / km | 0.13 → 0.08 | 0.02 → 0.02 | 0 → 0 |
| | racers the observer overtook / km | 0.78 → 0.76 | 0.88 → 1.02 | 2.03 → 2.17 |
| | racer mean speed, km/h | 154 → 155 | 167 → 169 | 147 → 157 |
| | racer lane moves (per ~50 km) | 244 → 347 | 150 → 221 | 176 → 281 |

4 lanes, leg 8 (170 / 200 km/h): passes 0.15 / 0.04 → 0.13 / 0.02 per km, racers passed 0.19 / 0.04 → 0.23 / 0.02, racer mean speed 159 / 165 → 161 / 166 km/h. Every cell: 0 violations, 0 collisions; the hardest raw IDM braking of a car a racer cut in front of −3.75 to −4.04 m/s² before, −4.19 to −5.56 after (never the 6 m/s² clamp); at most 2 lane changes by one racer in any 10 s. (WP6.7's 0.07 at leg 8 came from 4 × 3.5 km per cell; with 8 × 7.5 km the same tree measures 0.02–0.11, so single cells move by ±0.05 per km by chance.)

**Target not met: 0.3–0.5 passes per km at leg 8 at 200 km/h is not reachable by weaving within the fairness rules.** Racers now change lanes 30–95 % more often, but their mean speed in leg-8 traffic stays at 155–169 km/h, well below a 200 km/h player, so they cannot come past it; passes stay at 0–0.1 per km (noise level). The limit is the lanes, not MOBIL: a racer is behind a slower car 70 % of the time, and then both neighbouring lanes are unsafe 78 % of the time, mostly because the gap beside it is too short for its *own* braking (a car 0–15 m ahead going 10–30 km/h slower). Even an extreme racer (T 0.25 s, s0 0.5 m, b_safe 6, b 6, a 4, cooldown 0.5 s, MOBIL at 8 Hz, a cap of 6) stays at 169–174 km/h with 0 passes at 200 km/h, and its cut-ins need the clamp (−6.03 m/s²). An arrival still needs a clear run in its own lane (`_arrival_fits`), which weaving does not change; they stay at 0–0.02 per km at 200–230 km/h.

What would give passes at 170–230 km/h (owner / orchestrator decisions, beyond WP6.9's scope):
1. **A passing lane:** the leftmost lane at a lower density with slow profiles out of it (costs leg-8 density; WP6.7's first option).
2. **Arrivals in breathers** (70 % density, the waves' quiet phase; the brief keeps them free of arrivals) and near a clear stretch.
3. **Racers as scripted "chases"** (a set piece: a racer that the director gives a lane, like the convoy), announced like other set pieces.

### Density (D11 / D17)

The leg-8 survey (`--density --lanes=3,4 --legs=8 --seeds=8 --run-legs=4`, scripted observer): 3 lanes 15.48 → **15.45** per km per lane (−0.2 %), 4 lanes 15.51 → **15.20** (−2.0 %); the chaos between otherwise identical runs is about ±1.5 % (three no-op perturbations of the racer: 15.00–15.38 on 3 lanes). The levers that cost density are off in the data (docs/TRAFFIC.md). `soak_density_with_weaving_racers` gates ±3 % (weaving on vs off, 8 × 14 km per cell; with 4 × 14 km the 4-lane cell read −3.04 %, within the chaos).

### Soak and metrics baseline

`tools/soak.sh --km=2000 --shards=4 --all-pieces` (2,016 km in 72 runs, 15.3 simulated hours, wall 4,554 s on a shared container): signal 0, unsignaled 0, no-ambush 0 (49,110 lane moves checked, 54,127 signals, 2,463 cancels), decel 0 (min −6.00 m/s²), brake flags 0, rear-ends of a normally driving player 0 (132 contact episodes, 115 from behind, all after the bot's own move or hard braking), off-road 0, closed areas 0; 103 player-induced impossible windows. **Not all zero:** 78 collision pairs in two canyon runs (1 and 17, 3 lanes) and 1 traffic impossible window (run 61). Both collisions are the known lane-drop pattern of docs/SET_PIECES.md (*Canyon runs*: 195 pairs in 3 runs before this WP): a truck stopped at the end of a dropping lane merges at 0–3 km/h and the checker's box, turned by its heading atan2(v_lat, v), lies across the lanes next to a car in lane 0 (d 3.5 vs the truck's centre at 8.9 / 10.5 m). No racer took part in run 1's collision (an aggressive driver and a truck); in run 17 the other car was a racer holding its lane. The same two runs with the racer's weaving off are clean, i.e. the traffic's chaos moved the pattern, not the weaving. WP6.8 (lane-drop safety, in progress in parallel) fixes this pattern; the gate is to be re-run on the merge with WP6.8. Every 2- and 4-lane run and every non-canyon 3-lane run: 0 collisions. Arrivals 0.36 per km, 98 % of them passed the bot; racers of any origin passed it 0.56 per km and it overtook them 0.27 per km.

**Metrics baseline** (`tests/baselines/traffic_metrics.json`, rewritten deliberately), against WP6.7's: lane changes per vehicle-minute 1.146 → **1.336** (+16.6 %, beyond the ±15 % tolerance: racers change lanes more often, which is the point), density 10.05 → 10.33 (+2.8 %), gaps per km 8.70 → 8.70, mean speed lane 0/1/2 142.8 / 128.1 / 113.9 → 140.9 / 129.2 / 114.1, set pieces per leg 0.031 → 0.031.
