# Set pieces (WP6.2 framework; WP6.3 adds the other six)

Spec: *Traffic → Traffic director*: the SetPiece `SpawnSource`, "peak (often a set piece)", "set piece variety grows", and the set-piece table. Also *Fairness rules* 4 ("no deceleration above 6 m/s² except in set pieces announced at least 300 m ahead") and 6 ("within 150 m after a blind crest or bend … allows no set pieces"). Contracts §6 (SpawnSource, `Record.set_piece`).

| File | What it is |
| --- | --- |
| `src/traffic/set_piece_def.gd` | `SetPieceDef`: one piece's data (`data/set_pieces/<id>.tres`) |
| `src/traffic/set_piece_source.gd` | `SetPieceSource`: the SpawnSource, the runtime (instances, warnings, start, end), the `Controller` base, and the pieces `TruckWall` and `RollingRoadblock` |
| `src/traffic/traffic_director.gd` | Scheduling at wave peaks (`_schedule_set_piece`), clearing a piece's zone (`_clear_for_set_piece`), `force_set_piece` (dev) |
| `src/traffic/traffic_sim.gd` | The scripting hooks (below), and lane closures for road-dependent pieces |
| `src/core/tuning/director_tuning.gd` | Group *Set pieces*: unlocks by leg, chance, max live, clearances |
| `src/traffic/dev/set_piece_controls.gd`, `intensity_plot.gd` | Sandbox: WALL / BLOCK / WAVES buttons, the curve panel, the snap hook |

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
