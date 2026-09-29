# Forks, the coast finale and the Journey loop (WP6.5)

Spec: Core loop → Legs and checkpoints → **Forks** ("Some checkpoints split the road OutRun-style into two branches leading to different biomes. Signs name both 1 km ahead; you pick by the side of the road you are on at the split"), **The journey goal** (the coast after 8 legs; the finale; the journey bonus; "Journey complete" recorded; then the endless coastal highway), Cameras → **Scripted cameras** (the 3-second finale swing in a traffic-free breather), **Modes at launch** (Daily Drive: the same route and forks for everyone that day). Contracts: [CONTRACTS.md](CONTRACTS.md) §3, §7, §13, §14. Biomes: [BIOMES.md](BIOMES.md).

## 1. Planning (`ForkPlan`, `src/road/forks/fork_plan.gd`, pure)

- **Which checkpoints fork:** `ForkPlan.build(legs, ctx.rng_road.derive(&"forks"))` draws `fork_count_min..max` (2–3) checkpoints among those where both options exist on the default journey (checkpoints 1–6; checkpoint 8 leads to the coast, the destination, and 7 never has two options), at least `fork_min_spacing_legs` (2) apart. Everything comes from the run seed, so a Daily Drive (`RunContext.daily`, the date's seed) has the same forks for everyone; a Daily retry keeps the day's seed.
- **Stages:** the journey is the stage sequence of `LegsTuning.leg_biome_ids` (farmland 1, desert 2, canyon 2, city 2, valley fog 1), then the coast.
- **The two branches** offer the only two real alternatives for the next leg: **stay** in the current stage or **advance** to the next one (a skip ahead). The chosen stage takes the legs that later stages do not need (their default lengths; shrunk from the back, never below one leg), so every route is 8 legs, visits every biome in order, and ends at the coast. A fork with a single feasible option is not a fork on that route (`is_real`).
- **Sides:** the **left** branch goes on as the route planned; the **right** branch is the other option. With no choice made, the route is exactly the default plan (`route([])` = `leg_biome_ids`), which keeps every biome test and preview valid.
- `route(choices)` (road rules), `look_route(choices)` (the look: the leg after a pending fork keeps the biome before it, so nothing hints at a branch), `left_id(i, choices)`, `right_id(i, choices)`.

## 2. Road space: one path, two branch paths

The player, traffic, scoring, collisions and passability always work on **one** `ProceduralRoadPath` (the run's `road`), in its (s, d).

- **The split is the fork checkpoint's line.** Its landmark is the sign gantry over the split (it names both branches), and the crash cushion stands on the nose just past it.
- **Every path agrees up to the split.** `RoadPlanGen` ends the section that would run into a fork's approach with a bend to the middle of the sun band and a straight of `fork_approach_straight_m`; at the split each path takes its branch (a `fork_branch_deflection_deg` bend to its side at `fork_branch_radius_m`, then `fork_straight_after_m` straight). No random draws, so both branch paths come from the same seed; both stay in the 15–30° sun band. `BiomeRoadRules.hold_rules` keeps the fork leg's curve and crest rules over the gore, so both branches share one profile while both are in sight.
- **The main road follows the left branch** until the player picks. It carries `RoadFork` records (split, side, lanes, the vanish point) and `hold_at_forks`: `length_generated()` stops at an unresolved split (+ `fork_hold_margin_m` for the gantry), so no world system, no leg plan and no spawn ever builds on a branch the player may not take. The table itself is generated beyond (the mesher and the physics sample it).
- **The right branch's path** (`RunForks.candidate`) is a second `ProceduralRoadPath` from the same seed, with the route through the right choice, whose world origin is shifted right by the left lanes' width (`shift_m`): its reference line sits at the gore nose, so its lanes are 0..b−1 of its own road space. It is made once the main table covers the split and generated in the background (a few blocks per tick; at once when the player is near or after a teleport).
- **Lanes:** the trunk's `n` lanes split at the line (`a = ceil(n/2)` left, the rest right; a branch may have one lane), with no taper, then each branch widens to its biome's count `fork_widen_after_m` later. The right path counts only its lanes over the approach too.
- **Gore:** each branch's gore-side shoulder and rail open with the gap between the branches (`gore_open`, full at `fork_gore_full_gap_m`); at the nose the faces sit `fork_cushion_width_m / 2` into each branch's lane, where the cushion stands. The left branch keeps its median; the right branch's left side is a guardrail (`median_is_rail`). **The gore counts as a hit**: its faces are the branches' `guardrail_d` / `median_barrier_d`, which `HitDetection` checks corner by corner (first touch).
- **The opposite carriageway** veers away to the left before the split (`fork_veer_*`: the carriageways separate, a grass strip widens the median, it narrows to nothing far out) and comes back after the gore (`fork_rejoin_after_m`). Opposite traffic follows `opposite_lane_center_d` (parked out of sight where the carriageway is not drawn).
- **The choice:** when the car's nose reaches the split, the side of its centre (left or right of the lane line the split divides) picks. **Left:** the main road resolves the fork (the hold is released). **Right:** the main road adopts the candidate's whole state (`swap_state`, both come from the same seed), the car's d moves by the shift (its world position does not change), and every car on the player's carriageway (all behind the split, see traffic) is removed. Then `Events.fork_taken(biome)` (once), the look plan follows the route (`BiomePlan.set_leg_ids`), and the checkpoint crossing at the same line names the chosen biome. `fork_announced(left, right)` fires when the car passes the 1 km sign.
- A **teleport** past an unresolved split (dev, tests, snaps) takes the left branch.

### Drawing (`ForkView`, `src/road/forks/fork_view.gd`)

- The `RoadBuilder` leaves `[split, split + fork_draw_m)` to the `ForkView` (`set_skip_range`; a chunk clipped at the split reads its last row's cross-section just before it). `fork_draw_m` (1.2 km) exceeds the longest view distance + prefetch + a chunk, so the player sees both branches well before the split and nothing past it is built by anyone else.
- The ForkView meshes each branch path with the road's own `RoadChunkMesher` (pooled pieces, time-sliced, floating origin), so a branch looks exactly like the road it becomes. The **ground over the gore** belongs to the left branch (up to the right branch's rail: `ground_right_limit_d`); the right branch has none on its left (`ground_left_limit_d`).
- **After the choice** the taken branch's pieces stay up to `split + fork_draw_m`, where the builder takes over from the same path (no seam). The other branch sinks `fork_other_sink_m` (its ground always under the taken one's where they overlap), is extended and **narrows to nothing** (`vanish_factor`: the whole cross-section and the barrier heights) — it curves away (14° apart, ~260 m aside at 1.2 km) and fades into the fog — and hands its ground over (`fork_ground_blend_m`).
- The cushion is one small mesh (hazard yellow, ink bands facing traffic, retro-reflective).

### The rest of the world

- **Quiet zones** (`LandmarkClearance.ZONE_FORK`, so the roadside layers, street-lamp pools and elevated stretches skip them): the left side where the opposite carriageway veers and rejoins, both sides for `fork_quiet_after_m` past the split (world systems build there only after the choice: no pop-in), and the gore side until the other branch is gone.
- **No water or fog banks** across a fork span (`WaterPlan.dry`, `FogCards`); **no cliffs** (the mesher clears every `FORK` span); **no road tunnels** on a fork's leg (the tunnel window starts after the span).
- **Look:** the look plan blends a fork checkpoint's biomes from the split on (`BiomePlan.set_blend_from_line`), so nothing blends before the player picks; the branches are coloured with their own plans.
- **Signs:** the checkpoint warning signs before a fork (`SIGN` with `tag2 = SIGN_FORK_TAG2`) read `< DESERT MESAS / CANYON PASS >`, one branch per line (at 1 km and 500 m); the gantry reads `< LEFT   RIGHT > / LEG n — PICK YOUR SIDE / CHECKPOINT` (`LandmarkText.fork_sign`, `fork_landmark`).

### Features

`RoadFeature.Kind.FORK`: `s_start..s_end` = the fork's whole span (the veer before the split to the rejoin after the gore), `value` = the split's s, `tag` / `tag2` = the left / right biome ids. (The contract said `s_start` = the split; the span is what consumers need: the split is in `value`.)

## 3. Traffic

- **Before the choice:** the director gets a breather (`TrafficDirector.request_breather(split − fork_breather_before_m, split + fork_breather_after_m)`: no spawn commits there), and `RunForks.guard_traffic()` (after the director, every tick) removes any car at `split − fork_traffic_guard_m` or beyond. So no car reaches a branch before the player picks, nothing drives in the gore, and nothing changes lanes across it; the approach is quiet by the time the player gets there.
- **After the choice:** the breather is cleared; new traffic comes on the taken branch beyond the fog. After a left choice a car still behind the split in the right lanes (a behind spawn) is removed (it would drive into the gore).
- **What the director (WP6.2) should do:** read `FORK` features (`road.features_in`) and (1) plan no set piece whose span overlaps `[s_start, s_end]`; (2) spawn nothing in `[value − fork_breather_before_m, value + fork_breather_after_m]` while `road.hold_at_forks` and `road.length_generated() < value + fork_hold_margin_m + 1` (the fork is unresolved); (3) keep `request_breather` / `clear_breathers` / `in_breather` (the WP6.5 hook in `traffic_director.gd`, between `# ---- WP6.5 hook` markers) and the `in_breather` check at the top of `_commit`. Passability sees only the main path's lanes, so the gore is outside every lane.

## 4. The coast finale (`RunFinale`, `src/run/run_finale.gd`)

- The crossing that reaches the coast (checkpoint 8) pays the journey bonus (as before) and **arms** the finale at `finale_after_m` (900 m) past the line, where the ocean has opened (the coast's water sweeps in over its `arrive_m`). It asks the director for a breather around that point (`finale_breather_lead_m` before to `finale_give_up_m + finale_breather_after_m` after).
- From the point on, cars out of view behind the player (the spawn rules' camera-independent volume) are removed, and as soon as no car on the player's carriageway is within `finale_breather_before_m` behind or `finale_breather_after_m` ahead (beyond the fog: nothing can reach the player), the **camera swings** (`CameraRig.start_finale`: out to the land side, `finale_swing_*`, looking back at the car against the sea and the low sun, then back, over `finale_swing_s` = 3 s; the springs keep following underneath, so the mode's pose is exactly restored) and **the car holds its lane and speed** (`RunFinale.FinaleController`, input ignored). At night the city and harbour lights and the lighthouse are enough as they are.
- **Journey complete** (once): `Events.journey_complete` when the swing starts (or at the point with reduced motion, which never swings, or after `finale_give_up_m` if traffic never cleared). The HUD shows the **JOURNEY COMPLETE** banner (`HudJourneyToast`: gold, "COASTAL HIGHWAY · JOURNEY BONUS +50,000", non-blocking, `journey_toast_s`), `RunStats` records it (results payload `journey_complete`, `journey_time_s`, `journey_distance_m`; "COAST REACHED" was already there), and `Save.record_journey(mode, time, distance)` keeps the count and the best time and distance per mode (written at frame time).
- Then the endless coastal highway: the ordinary loop, the director back to normal.

## 5. Tuning

`RoadTuning` "Forks" (geometry, drawing, quiet zones, traffic around a fork), `LegsTuning` "Forks" (count, first checkpoint, spacing) and "Journey" (finale point, breather, give-up, lane hold), `CameraTuning` "Scripted cameras" (`finale_swing_*`), `HudTuning` "Legs" (`journey_toast_*`).

## 6. Tests

| File | Covers |
| --- | --- |
| `tests/unit/test_forks.gd` | Plan determinism by seed and by date; counts and spacing; the unresolved journey is the default plan; every route of every choice reaches the coast through every biome, forks offer two biomes, left = as planned; look route; branch paths agree up to the split and diverge in the sun band with the minimum radius and one profile; lanes split and widen, the gore opens; the opposite carriageway veers and returns; the hold; FORK / sign / gantry features; swap_state; the mesher builds both branches and the gore ground meets the rail |
| `tests/run/test_forks.gd` | The run's forks; left lane → left branch, right lane → right branch (no sideways jump, fork_taken once, the next leg's biome); announced at 1 km with both biomes; the gore nose is a hit; no car past the guard line or in the gore; both branches drawn to the fog before the split, the builder leaves the zone; determinism |
| `tests/run/test_journey.gd` | A full journey through forks (teleports near checkpoints): biomes per leg follow the route, each fork taken once before its leg starts, the coast once, the journey bonus, the finale swing (3 s, lane held, camera and control restored), journey complete once, the endless coast, results; the finale waits for a clear breather; reduced motion; the save; Daily Drive; determinism. `soak_full_journey_without_teleports` drives it all |
| `tests/ui/test_hud_journey.gd` | The banner: text, timing, out of the middle third, fits at every canvas and text size |

## 7. Review

```
tools/snap.sh src/run/run.tscn --at=fork --at_m=1150 --lane=1 --hud=false --sky_t=0.38 --renderer=both   # the 1 km sign
tools/snap.sh src/run/run.tscn --at=fork --at_m=200 --lane=1 --hud=false --sky_t=0.38 --renderer=both
tools/snap.sh src/run/run.tscn --at=fork --at_m=25 --lane=1 --hud=false --sky_t=0.38 --renderer=both    # the split
tools/snap.sh src/run/run.tscn --at=fork --at_m=80 --lane=2 --bot=keep --seconds=6 --hud=false          # took the right branch
tools/snap.sh src/run/run.tscn --at=finale --bot=keep --lane=1 --seconds=1.0 --hud=false --sky_t=0.4 --speed_kmh=150 --renderer=both
tools/snap.sh src/run/run.tscn --at=finale --bot=keep --lane=1 --seconds=3.2 --sky_t=0.38 --speed_kmh=150   # the banner
```

`--at=fork` (`--at_m` before the next split), `--at=finale` (`--at_m` before the finale point; armed as the crossing would), `--lane=N`, `--bot=keep` (a lane-keeping bot drives through `--seconds`). Legs jumped over by `--at` are not crossed (no sun lift).

## 8. Limitations

- The opposite carriageway is away for ~3 km around a fork (it veers off and comes back); a fork's first ~1 km past the split has no roadside props (they would otherwise pop in after the choice).
- Traffic never drives onto a branch before the player picks (a quiet approach) — the spec's "traffic picks its branch by lane" is honoured as "no car is ever on the wrong branch".
- A fork's leg has no road tunnels.
- The branch not taken narrows away rather than curving off along a real road; it is ~200–300 m aside, in the fog, when it goes.
