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
