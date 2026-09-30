# Set pieces (WP6.2 framework and two pieces; WP6.3 the other six)

Spec: *Traffic → Traffic director*: the SetPiece `SpawnSource`, "peak (often a set piece)", "set piece variety grows", and the set-piece table. Also *Fairness rules* 4 ("no deceleration above 6 m/s² except in set pieces announced at least 300 m ahead") and 6 ("within 150 m after a blind crest or bend … allows no set pieces"). Contracts §6 (SpawnSource, `Record.set_piece`).

| File | What it is |
| --- | --- |
| `src/traffic/set_piece_def.gd` | `SetPieceDef`: one piece's data (`data/set_pieces/<id>.tres`) |
| `src/traffic/set_piece_source.gd` | `SetPieceSource`: the SpawnSource, the runtime (instances, warnings, start, end), the `Controller` base, and the pieces `TruckWall` and `RollingRoadblock` |
| `src/traffic/set_pieces/*.gd` | WP6.3's pieces: `MergeZonePiece`, `RoadWorksPiece`, `SlalomPiece`, `ConvoyPiece`, `TunnelSqueezePiece`, `TollGantryPiece`; `WorksPropQuery` (hits on the works' props) |
| `src/traffic/traffic_director.gd` | Scheduling at wave peaks (`_schedule_set_piece`, `_schedule_anchored_peak`), feature-triggered pieces (`_schedule_tied`), clearing a piece's zone (`_clear_for_set_piece`), `force_set_piece` (dev) |
| `src/traffic/traffic_sim.gd` | The scripting hooks (below), lane closures, WP6.3's speed and headway zones, merge holds, hazards |
| `src/road/procedural_road_path.gd`, `road_chunk_mesher.gd` | WP6.3's road hooks: `schedule_lane_count` (existing), `add_rail_gap` / `rail_gap_at` (the mesher leaves the player-side rail out there) |
| `src/world/set_pieces/*` | `SetPieceView` (signs, cones, barrier, arrow board, on-ramp, toll legends), `set_piece.gdshader`, `SetPieceMeshBuilder`, `SetPieceLook` (`data/set_pieces/look.tres`), `TunnelLight` |
| `src/sun/sky.gd` | `SkyRig.set_tunnel_light()`: the light change in road tunnels |
| `src/vehicle/hit_detection.gd` | `sweep_static_box()` for prop queries |
| `src/core/tuning/director_tuning.gd` | Group *Set pieces*: unlocks by leg, chance, max live, clearances |
| `src/traffic/dev/set_piece_controls.gd`, `intensity_plot.gd` | Sandbox: WALL / BLOCK / SLALOM / CONVOY / MERGE / WORKS / TUNNEL / TOLL / WAVES buttons, the curve panel, the snap hook |

## How a piece happens

1. **When (the director).** The intensity waves ([SPAWNING.md](SPAWNING.md), *Intensity waves*) give every peak two seeded draws. When the batch about to be planned is where the player will meet the peak's middle (the meeting map at the piece's speed), the director:
    - rolls the peak's chance against `set_piece_chance_frac(leg)` (50 % → 80 %);
    - picks the kind with the peak's second draw (`SetPieceSource.pick`): the first `set_pieces_unlocked(leg)` ids of `set_piece_unlock_order` that have a data file and a controller, allow the leg (`min_leg`) and the lanes (`min_lanes`), weighted by the biome's `set_piece_ids` / `set_piece_weights` (an id the biome does not list is out; a biome with no list uses each def's `weight`);
    - checks the road (`fits_road`): enough lanes; no part of it hidden just beyond a blind crest or bend while the player drives it (rule 6); met clear of every checkpoint's range (`set_piece_checkpoint_clear_before_m` / `_after_m`); no lane-count change, tunnel or fork on the road it drives until it ends;
    - schedules it (`SetPieceSource.schedule`), at most `set_piece_max_active` at once, and clears its zone of hidden live traffic (beyond the fog, so the removal is invisible).
    A peak the player is too slow to meet gets none: its pace is within `wave_min_closing_kmh` of the piece's speed, or, at the smoothed pace, the player would take longer than `set_piece_meet_max_pct` (75 %) of the piece's `approach_max_s` to reach it (a piece nobody meets would only take its zone's traffic away and hold the live slot). Counters: `peaks_seen`, `peaks_no_chance`, `peaks_no_kind`, `peaks_missed`, `peaks_unfit`, and the source's `unfit_*`.
2. **What (the source).** `plan_batch` lays the piece out through its `Controller.plan()` (records with `FLAG_SCRIPTED`, `set_piece = id`, `v = v0 = speed`), shifted forward in `set_piece_placement_step_m` steps until every vehicle keeps s* to live traffic and the road still fits, and fills the rest of the batch with Flow (Daily in Daily Drive) minus what would crowd the piece (`keeps_clear`). **The batch goes through the director's commit path like any other**: cap, ghost zone, no pop-in, live gaps, and WP6.1's passability.
3. **Bind.** After the commit, `bind_committed()` binds each committed record to its slot. The piece is RUNNING; `spawned` counts it (the soak's *set pieces per leg*). A piece that got no vehicle is dropped.
4. **Run (per tick, allocation-free).** `step(dt, player)`:
    - **Warnings:** as the player's distance to the piece's rear box edge comes down to each of `warning_sign_distances_m`, `KIND_WARNING` (tag = id, value = the distance, points = the instance serial). A piece first seen closer warns at once.
    - **Rule 4:** a piece with `allows_hard_decel` gets the sim's hard-decel permission for its vehicles only if its **first warning came at least `set_piece_min_warning_m` (300 m) ahead**; otherwise its vehicles keep the 6 m/s² clamp.
    - **Start:** `KIND_STARTED` when the player is within `start_distance_m` of the rear.
    - The controller's `step()`.
    - **End:** the player `end_margin_m` past the front, `duration_max_s` after the start, `approach_max_s` without the player reaching it, no vehicle left, or the piece rolling within `clear_ahead_m` of a lane-count change, tunnel or fork (counted in `ended_passed`, `ended_duration`, `ended_unmet`, `ended_empty`, `ended_zone`; the soak prints them). Every vehicle is released (`release_scripted`: its own desired speed back, MOBIL on) and `KIND_ENDED` fires if the piece was announced.
5. **Events.** The director writes them to `TrafficDirector.events` (the run's `ScoreEventBuffer`); `RunEvents` publishes `Events.set_piece_warning(kind, distance_m)`, `set_piece_started(kind)`, `set_piece_ended(kind)` (kind = the SetPieceDef id).

## Speeds and passability

Every scripted speed is at least the minimum speed + `set_piece_min_speed_margin_kmh` (105 km/h): following a piece is always a valid path, and only threading it scores. The truck wall's open lane shifts only while the player is at least `shift_min_player_gap_m` behind it, and every scripted lane change goes through `request_lane_change` (MOBIL safety, no-ambush, telegraphing).

## The two pieces

| | Truck wall | Rolling roadblock |
| --- | --- | --- |
| Spec | "Trucks and buses roll side by side across all lanes but one; the open lane shifts slowly. Warning: visible from distance by silhouettes." | "Cars at matched speed across all lanes; a gap opens every few seconds. Warning: brake lights ripple as it forms." |
| Layout | One truck or bus (3:1) per lane but a random one, per row (`rows`, row-spaced by s*), `row_stagger_m` ±1.5 m | One car (commuter or cruiser, 2:1) per lane |
| Speed | 105 km/h | 125 km/h |
| Behaviour | Every `shift_interval_s` (8 s) the vehicles beside the open lane (a random side, else the other) change into it: the open lane moves by one. Refused while traffic passes through it or the player is at the wall; retried after `shift_retry_s` (1 s) | At the first warning the row brakes lane by lane from the median, one brake tap every `ripple_step_s` (0.25 s). Then, `gap_interval_s` (4 s) after the last gap, one car (never the last one's lane) brakes down to `gap_speed_delta_kmh` (18 km/h) below the row until it is `gap_distance_m` (22 m) behind it, and closes up again. A phase held up by traffic longer than `gap_phase_max_s` (10 s) ends there |
| Warning | 600 m ("silhouettes") | 300 m ("brake-light ripple") |
| Hard decel | no | no |

Snaps (`tools/snap.sh src/traffic/dev/traffic_sandbox.tscn --set_piece=truck_wall --driver=keep --piece_dist_m=28 [--cam=top --zoom=90]`; also `rolling_roadblock`): the piece is forced (`force_set_piece`: the first ahead batch within `FORCED_TRIES` where it fits the road and rule 6, never placed where it does not), spawns beyond the fog as in play, then the player is moved `piece_dist_m` behind it in its open lane.

## Adding a piece (WP6.3)

1. **Data:** `data/set_pieces/<id>.tres` (SetPieceDef). The id is already in `DirectorTuning.set_piece_unlock_order`: slalom, convoy, merge_zone, road_works, tunnel_squeeze. The toll gantry is a checkpoint landmark (`is_checkpoint_landmark`), not scheduled at peaks.
2. **Controller:** a `SetPieceSource.Controller` subclass with `plan(src, ctx, inst)` (lay records out from `inst.s_rear` with `src.draw_vehicle(ctx, inst, lane, rec)`, set `rec.s`, `src.add_record(inst, rec, row)`), optionally `on_bound`, `on_warning(src, inst, index)` and `step(src, inst, dt, player)` (tick: no allocation). One line in `SetPieceSource.controller_for(kind)`.
3. **Scripting API** (from a controller, only when `src.can_script`, i.e. the real TrafficSim):
    - `src.set_v0(inst, k, v0)`: desired speed, floored at `min_speed_mps`
    - `src.brake_tap(inst, k)`: a visible brake tap (brake lights)
    - `src.request_lane(inst, k, lane)`: a telegraphed lane change (MOBIL safety and no-ambush can refuse; scripted vehicles may use any lane)
    - `src.controllable(inst, k)`, `src.alive(inst, k)`, `inst.slot[k]`, `inst.lane[k]` (formation lane), `inst.row[k]`, `src.state` (read-only)
    - Hazards (convoy): set `TrafficState.FLAG_HAZARD` in `rec.flags` at plan time.
    - Hard decelerations: set `allows_hard_decel` and give the first warning ≥ 300 m; the source grants the permission (`TrafficSim.set_hard_decel_allowed`), and the rule checker verifies it.
4. **Road-dependent pieces** (merge zone, road works, tunnel squeeze) need lanes that end or are closed: use the sim's lane closures, `add_lane_closure(lane, s0, s1, tag)` / `remove_lane_closures(tag)` (tag = the instance serial), which make traffic merge out before `s0` (telegraphed, no-ambush, waiting at the end of the lane if no gap) and keep spawns out. Cones, barriers and arrow boards are rendering (a view hook, not in the sim). A change of the drawn lane count (`lane_count_override`, `drops_right_lane`) needs `ProceduralRoadPath.schedule_lane_count` at director rate, before the road there is generated (WP6.4a's hook).
5. **Warnings with signs** (merge 500/250 m, road works 400 m): `warning_sign_distances_m`; the sign props are the road side's (a SIGN feature), the events come from the source.
6. **Tests:** `tests/unit/test_set_piece_source.gd` shows the pattern: a straight road with the real sim (`_rig`), `force_set_piece(id)`, `_spawn(id)`, `_only_the_piece(inst)` to watch the behaviour alone.

## Rule 4 in the rule checker

`TrafficRuleChecker` allows a deceleration beyond 6 m/s² only for a `FLAG_SCRIPTED` car that `set_piece_of` maps to a set piece whose **first warning** it measured itself, from `TrafficState`, at ≥ `set_piece_min_warning_m` (the soak feeds it every `KIND_WARNING`). Anything else beyond the clamp is a `decel_violation`. `set_piece_hard_decels` counts the allowed ones.

## WP6.3: the other six pieces

Spec: the set-piece table (merge zone, road works, slalom, convoy, tunnel squeeze, toll gantry), *Fairness rules* 1-6, the *Passability guarantee*, *World → Road* ("tunnels and road works drop to 2"), *Checkpoint landmarks*, *Night lighting* (retro-reflective signs and reflectors), *Lives → what counts as a hit* (roadside objects).

### Road-anchored pieces

Four pieces belong to the road, not to a formation: the merge zone, road works, the tunnel squeeze and the toll gantry (`SetPieceDef.anchored`). They have a **zone** fixed on the road, `[zone_s0, zone_s1]`:

- **Decided far ahead.** Their road hooks (lane counts, rail gaps), signs, cones and closures must exist before anything there is built or seen, so the zone start is decided `schedule_lead_min_m` .. `schedule_lead_max_m` ahead of the player (1.3-3.2 km: beyond the largest view distance, the chunks being built and the piece's own farthest sign). `SetPieceSource.schedule_zone()` lays it out (`Controller.setup_zone`: seeded layout, road hooks, sim hooks tagged with the instance serial) and runs it at once (`spawned` counts it).
- **Warnings, start, end.** Warnings count down to `warn_s` (the zone start + `warning_anchor_m`: the toll gantry's count to its checkpoint), it starts `start_distance_m` before the zone and ends `end_margin_m` past it. Never by time, approach or an empty formation: the cones stay until the player has passed. `Controller.on_end` takes its sim hooks out (the road keeps its lane counts and rail gaps, behind the player by then).
- **Vehicles later.** Vehicles an anchored piece has (ramp traffic, the tunnel platoon, booth traffic) are planned in the batch where `Controller.vehicles_rear_s()` falls (`prepare_anchored`, each batch): by default the meeting map puts them where the player meets them `zone_meet_m` into the zone. A piece whose vehicles the player can no longer meet in the zone gives them up (the zone stays). Each record must fit the live traffic and keep its lane from where it spawns to the zone (no lane drop, tunnel or fork on the way). They go through the same commit path and are bound to the running piece.
- **Fit.** `fits_zone`: enough (and not too many: `max_lanes`) lanes; no part just beyond a blind crest or bend (rule 6, at rest); clear of checkpoints (except the toll gantry), of lane-count changes, tunnels and forks (except the tunnel squeeze's own tunnel), of every other live anchored zone (signs included), of the run's traffic-free breathers (WP6.5: fork approaches, the finale) and of the road not yet decided (beyond an unresolved fork).

**Scheduling.** A wave peak whose pick is anchored (merge zone, road works) puts the zone at the peak's middle on the road (a static zone is met where it is), shifted so the piece's interesting part (`zone_meet_m` in) is there (`_schedule_anchored_peak`; it waits while that is beyond the lead, and is missed when the peak is already too close). **Feature-triggered pieces** (`SetPieceDef.trigger`) are never a peak's pick: every road tunnel of at least `tunnel_min_length_m` is offered to the tunnel squeeze, every checkpoint whose landmark is the express toll gantry (`TrafficDirector.checkpoint_style`, the run's `BiomeDirector.checkpoint_style`; a fork's checkpoint is a sign gantry) to the toll gantry, once each, in the same lead window, with a chance seeded by the feature's position (`feature_chance_pct`). The toll gantry is exempt from the "clear of checkpoints" rule (it is the checkpoint). Unlocks: the peak kinds and the tunnel squeeze follow `set_piece_unlock_order`; the toll gantry (a checkpoint landmark, not in the order) only its `min_leg`; the tunnel squeeze also the biome's mix (canyon lists it).

**Live pieces.** `set_piece_max_active` now counts the pieces the player faces at once: a new piece may be scheduled when fewer than that many live pieces overlap its range of player positions (its first warning to its end; `can_schedule_at`). A road-anchored piece decided 3 km ahead no longer blocks the peaks the player meets before it. A rolling piece that rolls into a live anchored zone ends there (`ended_zone`), as it does at a lane drop.

### The six pieces

| | Merge zone | Road works | Slalom | Convoy | Tunnel squeeze | Toll gantry |
| --- | --- | --- | --- | --- | --- | --- |
| Spec | On-ramp adds traffic from the right, then the right lane ends | One or two lanes closed by cones and a barrier; traffic merges | Staggered cars across lanes forming an S-line of gaps | A slow line of same-color vehicles with hazards on, honking | Two lanes, tighter traffic, light change at entry and exit | Checkpoint landmark: booth lanes on the sides, open express lanes in the middle |
| Kind | anchored, at a peak | anchored, at a peak | rolling | rolling | anchored, every road tunnel (60 %) | anchored, every toll-gantry checkpoint |
| Road | +1 lane at the ramp nose (40 m taper), the acceleration lane; it ends 520 m later (120 m taper); rail open over the join | cones close 1-2 lanes (leaving 2 open; 70 % the right side) | | | the tunnel's own 2 lanes | |
| Sim hooks | closure of the acceleration lane at both tapers; ramp cars held out of the mandatory merge | closures of the closed lanes over the zone | | hazards on its vehicles | headway zone: IDM T x 0.7 inside | speed zone on each booth lane: 50 km/h at the booths, braking at the profile's comfortable rate before them; booth traffic keeps its lane below 110 km/h up to 400 m past the booths |
| Vehicles | 2-4 ramp cars in the acceleration lane, paced (20-60 km/h) to be 20 % in when the player is 12 s away, then sent on at the piece's speed: they speed up and merge left in front of the player (or wait at the lane's end for a gap) | none: ordinary traffic merges | 4-5 rows, a car in every lane but one; the open lane moves one lane per row (0, 1, 2, 1, 0 ...); rows 45 m apart (at least s*), 110 km/h, formation kept | 4-6 of one drawn vehicle (profile, type, model, color), one lane (the right one; the next 30 % of the time on 3+ lanes), s* + 4 m apart, 105 km/h (the slowest a piece may be), formation kept; while the player is within 120 m, one honks every 2-5 s | 5-8 cars staggered over both lanes, 18 m (and half s*) apart, met 120 m in, formation kept | 1-3 per booth lane, met at the booths |
| Warning | signs at 500 m and 250 m ("MERGING TRAFFIC") | sign at 400 m ("ROAD WORKS"), flashing arrow board | none (all visible) | visible (400 m) | the portal (400 m) | the landmark's signs, 1 km and 500 m before the checkpoint |
| Visuals | the on-ramp ribbon from the right (lines, outer rail), a hatched gore, a yellow attenuator at the nose | cones (MultiMesh), a red and white barrier line in the closed lanes, the arrow board on its trailer (amber lamps flashing 1 Hz) | traffic | hazards (traffic lamps) | the tunnel's light change (every road tunnel) | TOLL / EXPRESS painted in the lanes |

Every scripted speed of a piece is above the minimum speed except the merge zone's ramp cars and the toll gantry's booth traffic, which are in lanes the player need not use (the acceleration lane; the booth lanes beside open express lanes). No piece asks for the rule-4 exception (`allows_hard_decel` is off everywhere): every deceleration stays within 6 m/s².

### Road hooks (WP6.3)

- `ProceduralRoadPath.schedule_lane_count` (WP6.4a's hook): the merge zone's acceleration lane. The road mesh, the roadside, the barrier (`guardrail_d`) and the sim's lanes follow the tapers. The zone is decided before the chunks there are built.
- `ProceduralRoadPath.add_rail_gap(s0, s1)` / `rail_gap_at(s)` / `rail_gap_ends_in`: the player-side guardrail is left out of the chunk mesh over the ramp's join (rows fall on the gap ends; the rail panels collapse to a line). `guardrail_d` is unchanged: the barrier stays in road space (the view draws the ramp's own rail beyond it). Kept sorted; forgotten with the road.
- The merge zone needs `max_lanes` 3 (the road has at most 4 lanes).

### Sim hooks (WP6.3, all additive)

`add_speed_zone(lane, s0, s1, v_max, tag, keep_after_m = 0, keep_v = 0)` (IDM free road toward the lane's limit: v_max inside, `sqrt(v_max² + 2 b d)` before it, and once a vehicle is inside that envelope at least the constant deceleration `(v_max² - v²) / 2d` that brings it to v_max at the zone's start: IDM alone lags a falling limit by about `b v / (δ a)`, so a truck came in far too fast; MOBIL sees it in a target lane; `SetPieceSource.spawn_speed_ok` keeps Flow batches, top-ups and behind spawns from spawning into a zone lane faster than its limit there; no motorbike lane-splits in or beside a zone lane within the lookahead, and a split there ends: between a 50 km/h booth lane and a 130 km/h express lane a splitting bike was the nearest "follower" MOBIL's safety check saw, hiding the express lane's fast car from a car leaving the booth lane; with `keep_v` the zone's traffic makes no discretionary lane change from the lookahead before the zone to `keep_after_m` past it while slower than `keep_v`, `kept_by_zone`: booth traffic pulling out at 50 km/h filled the express lanes with slow cars, impossible windows in the soak), `add_headway_zone(s0, s1, scale, tag)` (IDM T x scale), `remove_zones(tag)`, `speed_limit_at`, `headway_scale_at`; `set_merge_hold(slot, on)` (no mandatory merge while held; cleared on release); `set_hazards(slot, on)`. The source's helpers: `set_v0_unfloored`, `merge_hold`, `is_held`, `hazards`, `honk`; the base `Controller.keep_formation` / `mark_formation` (each vehicle's desired speed = the piece's speed + `formation_gain_per_s` x its lag behind its slot, within `formation_limit_kmh`).

### Visuals (`SetPieceView`)

A world-system node (setup / bind / update_view). One `MeshInstance3D` per live road-anchored piece with props (pool of 2: signs, ramp, gore, barrier, arrow board or legends in one surface, built once when the piece appears, far beyond the view) and one `MultiMeshInstance3D` for the cones of the nearest road works. **Draw calls: 0 without a piece, 1 per piece in view (+1 for its cones): at most 3.** `set_piece.gdshader` is the world shader plus sign text (its own small `LandmarkTextAtlas`; painted legends cut out by coverage), retro-reflection with a day fill (emissive class 1: sign faces, cone collars, barrier, the board's frame, the attenuator; they light up in the player's headlights) and flashing lamps (class 4: the arrow, `flash_gain` per frame from the view's clock). Linear math before `wb_output`: the same on both renderers. Numbers: `data/set_pieces/look.tres` (`SetPieceLook`).

**Known limits.** The roadside does not know about the set pieces: a billboard or fence may stand in the on-ramp's path or behind a sign (the landmark clearance covers checkpoint and lane-ends signs only). From the chase camera the ramp's first metres beyond the mainline rail are hidden by the rail itself. The guardrail posts stay along `guardrail_d` over the rail gap.

### Hits (`WorksPropQuery`)

`HitDetection`'s prop hook: each tick the player's swept, inset box against every cone (a `cone_size_m` square), the barrier line and the arrow board of every live road works (`HitDetection.sweep_static_box`, the same separating-axis sweep as traffic: 350 km/h through a cone in one tick is caught). Source `HIT_PROP`, the first touch of the tick. The run and the soak install it.

### The light change (`TunnelLight`, `SkyRig.set_tunnel_light`)

Every road tunnel (the squeeze is the traffic that makes use of it): a factor 0 outside, 1 inside, smoothstep over `tunnel_light_ramp_m` centred on each portal and exit. The sky darkens the ambient and sun light by `tunnel_dark_frac` and raises the street-lamp ramp (the lamp strips) to `tunnel_lamp_on`; `sky_t` and `current()` are untouched. Numbers in `tunnel_squeeze.tres`.

### Sandbox and snaps

Buttons SLALOM / CONVOY (row 1), MERGE / WORKS / TUNNEL / TOLL (row 2; WP6.6's FAST / RACER move down to row 3). The snap hook drives up to a road-anchored piece (`piece_dist_m` before its zone start) and first teleports near a feature-triggered piece's feature. The run has its own: `tools/snap.sh src/run/run.tscn --set_piece=<id> [--seed=N] [--speed_kmh=] [--piece_dist_m=] [--piece_lane=] [--piece_lead_m=] [--sky_t=]` forces the piece and drives a lane-keeping bot up to it (a feature-triggered one leg by leg to its next feature, resolving forks on the way). Pieces never fit in a fork's span (WP6.5), so a run snap needs a stretch clear of forks, checkpoints and tunnels at the bot's meeting distance.

### Tests

- `tests/traffic/test_set_pieces_anchored.gd`: data (warning distances, leads beyond the view); road works (1-2 lanes, the cone line, the barrier and board in the closed area; traffic merges, nothing in the closed area, the bot through without a prop hit, warning at 400 m, closures removed); merge zone (lanes, rail gap, closures; ramp cars in the acceleration lane, sent on, merging; warnings at 500 and 250 m); tunnel squeeze (the zone is the tunnel, 2 lanes, the headway zone, the platoon met inside, the portal warns, hooks removed); the tunnel light; toll gantry (traffic that came in on a booth lane is at the booth speed at the booths, a car that moved in late is well on its way down, the express lane keeps its speed, warnings at 1 km and 500 m, only at toll checkpoints); a speed zone brings even a truck to its speed at its start, comfortably, and nothing spawns into it too fast. Every run gates collisions, rules 1-4, offroad and the closed areas.
- `tests/traffic/test_set_pieces_rolling.gd`: slalom (rows, the S, row gaps; formation held, a bot threads it with no contact and the impossible-window oracle finds a path all along); convoy (one line, one color and vehicle, hazards, stays in lane, honks while the player is alongside, released with hazards off); no piece brakes beyond the clamp; determinism (a slalom, a convoy and a road works at once: layouts and the traffic's state hash by seed).
- `tests/world/test_set_piece_view.gd`: props built, visible from the first sign, retro-reflective faces, flashing lamps, 0 / 2 / 1 draw calls; hits on a cone, the barrier and the board at 350 km/h and none in the open lane; the sky's tunnel light.
- `tests/unit/test_set_piece_source.gd` (updated): every kind has a controller and data; picks (feature-triggered pieces are never a peak's pick; the merge zone never on 4 lanes).

### Soak (WP6.3)

`tools/soak.sh --km=2000 --shards=4 --all-pieces`: every piece unlocked from leg 1, every run's even-leg checkpoints toll gantries, and every fourth run (index % 4 == 1) on the canyon's road for its tunnels (the tunnel squeeze). The bot keeps out of closed lanes and, like a player reading the TOLL legends, out of booth lanes. `--canyon` puts every run on the canyon's road (no pieces forced). New counters: `closed_area_violations` (a gate), `prop_hits` (the bot's), `peaks_busy`, `collisions_at_pieces` (collision pairs within 300 m of a live piece), set pieces per leg and by kind.

Result on the integration branch with WP6.5 and WP6.6 merged (2,016 km, 72 runs, load 12-16 on 4 cores):

| | |
| --- | --- |
| Set pieces | 313 spawned (0.543 per leg), 300 started, 240 passed, 0 unmet: toll gantry 234, tunnel squeeze 60, truck wall 8, merge zone 4, road works 2, slalom 2, convoy 2, rolling roadblock 1. Few merge zones / works / slaloms / convoys: the soak's roads are mostly 2-3 lanes with a lane-count change, curve or checkpoint near most peaks (`peaks_unfit` 185 of 647) |
| Signal, unsignaled, no-ambush, decel (min −6.00 m/s², 0 hard set-piece decelerations), brake flags, rear-end of a normal player, off-road, closed areas, prop hits | **0** each |
| Farmland runs (1,512 km: 504 each on 2, 3 and 4 lanes) | **0 collisions, 0 impossible windows (traffic)** |
| Canyon runs (504 km, 3 lanes) | **195 collision pairs in 3 runs, 1 impossible window**, all at the canyon's lane drops (3 → 2 before tunnels), **0 within 300 m of a live piece** |

**The canyon collisions are not the pieces'.** `tools/soak.sh --km=500 --shards=4 --canyon` (every run on the canyon's road, pieces only as the default unlock order allows: tunnel squeeze from leg 7, the only kind that spawned): 136 collision pairs in 4 runs and 1 impossible window, every collision before leg 7 (s = 4.2, 14.6, 15.1, 18.3 km): no piece was live. The pattern (runs 49 and 53 traced): traffic queues **at a standstill** at the end of a dropping lane beside WP6.6's fast lanes (racers at 130-190 km/h), then merges from 0 km/h; the fast car behind brakes at the 6 m/s² clamp too late (run 49, after the bot touched the merging car), or a stopped truck's lateral merge turns its checker box sideways (heading = atan2(v_lat, max(v, 0.1)): a 12 m box across the lanes, run 53). The WP6.6 soak did not cover the canyon (its road is farmland, WP6.5 "adds no forks to the soak's road"). For the lane drops (WP6.2) and fast traffic (WP6.6) owners.

**Fixed on the way** (the first 2,000 km all-pieces soak after merging WP6.6: 9,090 collision pairs, 31 impossible windows, nearly all at toll gantries):
- A car leaving a 50 km/h booth lane into the express lane in front of a 130 km/h car: a motorbike lane-splitting between the two lanes was the nearest follower MOBIL's safety check saw, hiding the fast car. No lane split in or beside a zone lane (TrafficSim `_slow_zone_beside`).
- Booth traffic pulling out into the express lanes at booth speed (slow walls, impossible windows): booth traffic keeps its lane below `booth_exit_kmh` (110) up to `booth_keep_after_m` (400 m) past the booths.
- Trucks came into the booths far above 50 km/h (IDM lags a falling limit): the envelope braking above; behind spawns and top-ups spawned into booth lanes at flow speed: `spawn_speed_ok`.

**Metrics baseline** (`tools/soak.sh --update-baseline`, deliberately): the 16-run reference now meets WP6.3's kinds from their unlock legs (slalom 3, convoy 4, merge zone 5, road works 6, tunnel squeeze 7; no tolls, the reference keeps the default checkpoint style). 3 of 16 traces changed; density 10.00 → 9.90 (−1.0 %), gaps per km 8.65 → 8.55 (−1.1 %), lane changes per vehicle-minute 1.029 → 1.040 (+1.1 %), mean speed per lane 139.2 / 127.1 / 115.6 → 140.4 / 127.6 / 116.6 km/h (+0.8 / +0.4 / +0.8 %), set pieces per leg 0.031 → 0.023 (4 → 3 pieces in 128 legs: the picks now include kinds that often do not fit the reference's road).

## WP9.6: set pieces in a real journey

Placement retries a peak that did not fit, was busy or could not be placed at the next batch; road-anchored pieces scan further for a place that fits; busy tunnel and toll pieces are offered again; the meet rule uses the player's 30 s cruising pace (`set_piece_meet_pace_smoothing_s`); rolling pieces may drive through a widening (`zone_widen`), while drops, tunnels and forks still stop them. Numbers and reasoning: docs/SPAWNING.md, *Set pieces in a real journey (WP9.6)*.

