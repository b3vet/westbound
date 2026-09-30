# Client network traffic (N4.3)

The client's copy of the server's traffic: every car the server streams runs the server's own longitudinal model on the phone at server time, lane changes come only from intents, and corrections are compared against the prediction at their tick and blended out. Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Traffic: server-authoritative with intents (What the server sends, Area of interest, Correction schedule, Client network traffic), Networking protocol (Clock sync), Testing (client traffic corrector; netcode harness), Tuning reference. Plan: [MULTIPLAYER_PLAN.md](MULTIPLAYER_PLAN.md) N4.3, MP-D5, MP-D6. Wire: [PROTOCOL.md](PROTOCOL.md) §4, §12. Server side: [SERVER.md](SERVER.md) → Traffic simulation (N4.1).

| Path | Class | Role |
| --- | --- | --- |
| `src/net/traffic/network_traffic_source.gd` | `NetworkTrafficSource` (a `SpawnSource`) | Car ids, the model at server time, intents, frames in, `TrafficState` out (`# lint: sim`) |
| `src/net/traffic/traffic_corrector.gd` | `TrafficCorrector` | Per-car history, correction offsets and the blend rules, late-intent timing (`# lint: sim`) |
| `src/net/traffic/net_traffic_wire.gd` | `NetTrafficWire` | Wire ↔ road space: lanes, d, s wrap, durations (`# lint: sim`) |
| `src/net/traffic/net_traffic_stats.gd` | `NetTrafficStats` | Counters, correction-size histograms, rates, DevStats keys (`# lint: sim`) |
| `src/net/traffic/dev/fake_traffic_authority.gd` | `FakeTrafficAuthority` | Stand-in for N4.2: the real TrafficSim + director at 20 Hz, the stream for one client |
| `src/net/traffic/dev/net_delay_link.gd` | `NetDelayLink` | One direction of a simulated path (latency, jitter, loss; stream or datagram) |
| `src/net/traffic/dev/net_traffic_harness.gd` | `NetTrafficHarness` | Authority + links + `NetClock` + source on a virtual clock (tests, sandbox) |
| `src/traffic/dev/net_traffic_controls.gd`, `net_traffic_overlay.gd` | `NetTrafficControls`, `NetTrafficOverlay` | The sandbox's network mode and overlays |
| `src/ui/dev_hud.gd` | | Rows `net corr` and `net link` |
| `tests/net/test_network_traffic.gd`, `test_net_traffic_sandbox.gd`, `tests/fixtures/net/net_traffic_rig.gd` | | Tests (below) |
| `src/core/tuning/net_tuning.gd`, `data/tuning/net.tres` | `NetTuning` | Groups *Network traffic* and *Netcode test link* |

## Integration

```gdscript
var src := NetworkTrafficSource.new(tuning.net, tuning.traffic, road, registry, sim.state)
src.set_headway_scale(tuning.director.headway_scale(loop_tuning.director_leg))   # the server's leg
src.set_player_body(car_def.length_m, car_def.width_m)
# every decoded server frame (NetCodec.decode_server_frame_into → NetServerFrame):
src.note_frame_bytes(bytes.size())
src.apply_frame(frame, car.state.s, clock.server_now(), clock.best_rtt_s * 0.5 * clock.tick_rate())
# every 120 Hz tick, in place of sim.step + director.step (the opposite carriageway keeps running):
src.step(clock.server_now(), car.state, events)
src.notify_hit(slot)        # after collisions, in place of sim.notify_hit (the hit report goes up too)
src.set_headlights(night)   # the room clock
```

- **It plugs in where the director's spawn source goes:** it extends `SpawnSource` (`source_id() == &"network"`, `plan_batch` plans nothing: the director is off) and publishes into the `TrafficState` the run already hands to `TrafficView`, `HitDetection`, the scoring adapter, headlight cones and the sandbox. So network cars are exactly like local ones: road space, SoA, slots, `vehicle_id` unique per spawn. The run simply stops calling `sim.step` / `director.step` (MOBIL, lane splitting and the director never run on the client).
- `run.gd` is not in N4.3's paths: the network loop mode wiring (N5.2's room client) needs the four calls above. See *Requests*.
- Events: `step` writes `traffic_hazards` (a local hit, on and off), `traffic_brake_tap` (a cut-in, mirrored) and `traffic_horn` (a `horn` intent) into the caller's buffer, with TrafficSim's kinds and tags, so the Events adapter is unchanged.

## Wire conventions (`NetTrafficWire`)

| Field | Wire | Client |
| --- | --- | --- |
| `s_mm` | wrapped into [0, L) on the loop (u32 mm) | unwrapped: the lap nearest the player (`s_unwrap`, LoopRoadPath.unwrap_near's rule for any `RoadPath.period_m()`) |
| `d_cm` | cm, **+ = right of travel** (PROTOCOL.md §12) | m, unchanged sign |
| `lane`, `lc_target_lane`, `target_lane` | 0 = rightmost; **7 = ramp** (MP-D6) | median-first: `lane = n − 1 − wire` with n = `road.lane_count(s)` at the car; 7 → n (the ramp pseudo-lane) |
| `duration_ms` | whole ms | seconds; ticks = s × tick rate |
| `car_id` | u16, server-allocated, never reused within 30 s (MP-D6) | `slot_of(car_id)`; `TrafficState.vehicle_id` is the client's own per-spawn id |
| `vehicle`, `profile`, `color` | indices into `TrafficRegistry.types` / `.profiles` and the palette | `type_id`, `profile_id`, `color_index`; `model_variant = car_id` (not on the wire; the view wraps it, the same on every client) |
| ticks | u32 room ticks, 20 Hz | the state stamped tick N is the car at server time N.0 (`server_now()`) |

## Time and the model

- **Server time.** `step(now)` takes `NetClock.server_now()` (fractional ticks). The model steps whole ticks up to `floor(now)`, exactly like the server: integrate over one tick with the acceleration held from the previous tick (TrafficSim's ballistic step, never reversing), then compute every car's acceleration at the new tick with everyone (the local player included) at the same instant. The published state is that tick's state carried ballistically to `now`. When the model's inputs match the server's, the prediction equals the server's trajectory to the bit before quantization.
- **The acceleration** (TrafficSim `_step_accel`'s parts the client can know): leaders by lateral overlap (physical intervals; a moving car spans to its target; the player stretched by its lateral velocity × `player_lateral_anticipation_s`), IDM with the profile's a, b, T × the leg's headway scale, s0, δ = 4, the racers' weaving T / s0 / b toward traffic (WP6.9), the lane-drop harmonisation zones (WP6.8, below), the player's cut-in brake tap (with its cooldown), hard brakes (intents, a local hit), then the per-car bias, then the 6 m/s² clamp, then the brake lights.
- **Lane-drop zones (WP6.8), mirrored.** The road's drops become zones exactly as `TrafficSim.sync_road_closures` makes them (from the lane-ends sign through the narrowed section to `lane_drop_slow_after_m` past the lanes coming back), synced every ~1 km of the player's travel (`sync_road`, director rate); each car gets the zone's speed cap, the eased braking into it and the speed matching of slow profiles (`_drop_accel` = `_drop_tick`'s harmonisation part). Merge zones, the zipper and the closure wall are not mirrored: the bias and the corrections cover them.
- **What the client does not know** (corrections cover it): each car's desired speed (not on the wire), MOBIL's decisions before their intents, remote players as leaders (N5.2 can add them as participants), the zipper and closure wall, the server's MP-D5 safety extensions (not yet in `traffic_sim.gd`), cars beyond the area of interest as leaders.
- **Estimation.** At each correction of a car (tick n, the previous at n0): if it drove free since (IDM's interaction term under `traffic_v0_free_accel_mps2` on average, no hard brake), its desired speed is IDM's free term inverted with the server's own mean acceleration `(v_n − v_n0) / Δt` (the zone's speed matching inverted too), eased in by `traffic_v0_gain` and kept within the profile's range ± `traffic_v0_margin_frac` (up to the merge-lane speed); otherwise the unexplained acceleration `e_v / Δt` goes into a per-car bias (`traffic_bias_gain`, ± `traffic_bias_max_mps2`, fading with `traffic_bias_fade_s`). The first guess at a spawn is the spawn speed, at least the profile's mid speed.

## Corrections (`TrafficCorrector`)

1. **History:** every model tick records each car's model state (s, v, d without blending offsets) in a ring of `traffic_history_s` (64 ticks).
2. **Compare at the tick:** a correction for tick N is compared with the history at N (or, outside the history, the model extrapolated to N; counted `no_history`). Error = `(e_s, e_v, e_d)`. A correction older than the car's last one is ignored (`old_corrections`).
3. **Carry forward:** the model at its tick K moves by `e_s + e_v (K − N) dt`, `v += e_v`; the recorded ticks N..K move onto the corrected trajectory (so the next correction is not compared against the same error twice); the accelerations are re-evaluated at K. A lateral error moves the car's lane position; during a lane change a small one is ignored (it ends with the move), an unexplained one of at least `traffic_unsignaled_lateral_m` abandons the move and follows the server's d.
4. **Blend:** the published position would jump by the model change; an offset takes it back and runs out linearly over the spec's time for the size of the offset still to run: under 0.5 m over 0.3 s, 0.5–5 m over 0.15 s. Over 5 m it **snaps** (logged in `snaps`) when the car is out of view; **in view** (from `traffic_visible_behind_m` behind to `traffic_visible_ahead_m` ahead of the player) it never snaps: it slides at up to `traffic_blend_max_speed_mps` (30 m/s) on top of the car's motion (`large_in_view`). The slide's lateral speed goes into `v_lat`, so the view yaws the car with it.
5. **Unsignaled lateral slides** (a lost intent, a cancel that came after the move began) are shown like a lane change: the lateral offset holds for `traffic_late_min_blinker_s` with the blinker on toward where the car will go, then slides, blinker on until it is done (`unsignaled_lateral`).
6. **Teleport metric:** a car in view whose published position moves more than `traffic_teleport_speed_mps` × dt beyond its own motion within one tick counts as a visible teleport (`teleports`; the soak gates 0).

## Intents

| Kind | Client |
| --- | --- |
| `lane_change` | Blinker from `max(start_tick, arrival)`; the lateral move is the server's curve `d = d0 + (target − d0) · smoothstep((t − move_start_tick) / duration)` (TrafficSim's `_tick_moving` sampled continuously; `d0` = the car's lane position), lane and blinker switched one tick after the move ends. The target d is `road.lane_center_d(target, s)` (the ramp: lane n) |
| late `lane_change` | **Arrives after `move_start_tick − traffic_late_min_blinker_s`:** the car holds its lane until the blinker has shown `traffic_late_min_blinker_s` (0.25 s), then catches up with the server's curve over `traffic_late_catchup_s` (0.2 s, the spec's number) with a smoothstep blend; after that it is on the curve. Counted `late_intents` (after the move start: also `very_late_intents`). See *Deviations* |
| `cancel` | Before the lateral move: blinker off, no move. **Dated ahead** (`start_tick` in the future: a Hesitant's cancel, known when its blinker comes on): the blinker goes off at `start_tick` and the move never starts. After the client began moving (the server cancels at the end of the signal time when the gap is unsafe, which reaches the client after the move tick): back into the lane as an unsignaled slide with the blinker (`late_cancels`; ~1–2 cm) |
| `hazard` | Hazards from `start_tick` for `duration_ms` |
| `hard_brake` | The hit brake (`hit_brake_decel_mps2`) from `start_tick` for `duration_ms` |
| `horn` | A `traffic_horn` event (the handoff keeps horns client-side; the server does not need to send them) |

A local hit (`notify_hit`) starts the hit reaction at once (hazards, the hard brake, `FLAG_HIT` for `hit_recover_s`, a `traffic_hazards` event) and cancels a signal that has not started moving, as TrafficSim does; the server's hazard / hard-brake intents that follow change nothing visible. There is no swerve: the server's corrections bring its reaction.

## Spawns, despawns, stale cars

- A spawn's state is at the tick of the frame's correction batch (the checklist below makes the server include every spawned car in it); without one, `round(now − one_way)` (the clock's best round trip / 2). A car spawned mid lane change gets its plan (signaling: blinker now, hold rules as a late intent; moving: the move's start d recovered from its d and the curve, no hold).
- A repeated spawn replaces the car. A despawn or correction for an unknown id is counted (`unknown_car`).
- A car nothing is heard of for `traffic_stale_car_s` (3 s; every car in the area is corrected at least once a second) is dropped (`stale_despawns`): a lost despawn on a datagram path, an area-edge disagreement.

## Metrics and the dev HUD

`NetTrafficStats`: corrections (all and near the player), size histograms (5 mm bins to 2 m: median, p99), mean / max, blends by rule, snaps, large in view, teleports, intents (late, very late), cancels (late), unsignaled lateral slides, spawns / despawns / stale / unknown / reordered / no history / full / bad values, frames and bytes, per-second rates over `traffic_metrics_window_s`. `report_dev_stats()` (a few times per second) and `report_link(clock)` feed DevStats; the dev HUD's **net corr** row shows corrections/s, mean/max and p99 (red on a teleport) and **net link** late intents/min, kB/s, RTT and the clock's remaining slew; `-` outside network mode.

## The fake authority and the harness

`FakeTrafficAuthority` runs the real `TrafficSim` + `TrafficDirector` at 20 Hz, on the loop with `RunLoop`'s population (the loop's director leg, per-section density and flow speeds), with the multiplayer rules where the GDScript sim has them: every car's model every tick (`near_radius_m = INF`), the 1.0 s signal floor for every profile, no lane splitting, no set pieces, the move time decided when the blinker comes on (it draws a duration from the profile's range in whole ms and makes the sim use exactly that when the move starts; the move tick comes from the same float accumulation as `_tick_signaling`, checked every move: `move_tick_mismatches` stays 0), a Hesitant's cancel sent with its signal, dated at the signal's end. It knows every lane drop the client's area can see (the real server has the whole ring). Its director keeps traffic `test_authority_margin_m` (200 m) beyond both edges of the area, so cars enter and leave the area by driving, like on the server's ring. Not here: the Rust server's ring population and ramps, the MP-D5 extensions, remote players. It extrapolates the client's reported player (PlayerState over the uplink) to the tick, at most 0.5 s.

`NetDelayLink`: latency ± jitter per frame; **stream** mode (the WebSocket over TCP): a lost frame is retransmitted after `test_link_rto_ms` (200 ms) and everything behind it waits (in-order); **datagram** mode (a later UDP transport): lost frames are gone, jitter reorders. `NetTrafficHarness` processes every uplink delivery, server tick and downlink delivery at its exact virtual time: pings answered at once, one frame per server tick, `NetClock` fed by Pongs, frames applied at `server_now()`; the client sends a PlayerState every server tick and a Ping every 2 s, and joins after 1 s. It also measures the **truth error**: what the client shows against the server's car at the same true time (includes the clock's error).

## Sandbox

`NET ON` (top right, under the fast-traffic rows) switches the traffic sandbox to network mode: a fake server over the chosen link (`2% TCP` = the acceptance link, `NO LOSS`, `2% UDP`) feeds the sandbox's own `TrafficState`; the local sim and director stop (the opposite carriageway runs on), contacts call `notify_hit` on both sides, the IDM / MOBIL layers (they describe the local model) turn off, local spawns and lane-change requests are refused. Overlays (`NetTrafficOverlay`): per car near the player the last correction carried to now (cyan box and link), the server's true car at the same true time (magenta), a label (`#car_id`, last correction size, offset still blending, v0 estimate) and the lane change's timeline (blinker amber, move green, now white, the server's move tick red when a late intent holds past it); a panel bottom left with the link and the metrics; the stats panel's `net` line.

```sh
tools/snap.sh src/road/loop/dev/loop_traffic_preview.tscn --net=true --at=desert --warm_s=25 --labels=0 --layers=blink --tag=net_follow
tools/snap.sh src/road/loop/dev/loop_traffic_preview.tscn --net=true --at=city --warm_s=30 --labels=0 --layers=blink --cam=top --zoom=70 --tag=net_top
```

## Tests

`tests/net/test_network_traffic.gd` (fast tier unless noted):

| Test | What |
| --- | --- |
| `test_tuning_holds_the_traffic_spec_numbers` | The handoff's numbers in NetTuning (area, correction rates, blending, signal floor, catch-up, the acceptance link) |
| `test_wire_lanes_d_and_s` | Lane numbering both ways (2–4 lanes, ramp 7), d sign, s wrap and unwrap across the seam, open roads unwrapped |
| `test_traffic_messages_round_trip_through_the_codec` | 400 ticks of the authority's stream across the seam: every frame decodes (generic and hot path agree), re-encodes to the same bytes, s wrapped, d > 0, car id ≠ 0, every move at its announced tick |
| `test_small_and_medium_errors_blend_out_over_their_times` | 0.3 m over 0.3 s, 2 m over 0.15 s, no jump |
| `test_large_errors_snap_out_of_view_and_slide_in_view` | 20 m: snap at 2 km, slide at 30 m/s at 300 m (done after 0.67 s, never faster) |
| `test_corrections_compare_against_the_history` | The error at tick N is against the prediction at N; a repeated tick is ignored; carried forward |
| `test_desired_speed_estimate_converges` | A free car faster than the guess: v0 within 0.3 m/s, corrections at mm level after |
| `test_intent_on_time_moves_at_its_tick` | No lateral motion before the move tick, the server's curve to 1e-9 m, lane switched, blinker off |
| `test_late_intents_show_the_blinker_then_catch_up` | Arrival 0.1 s before and 0.5 s after the move tick: blinker at once, ≥ 0.25 s of blinker before any lateral motion, on the curve within 0.2 s after |
| `test_cancels_before_and_after_the_move` | Blinker off / back into the lane with the blinker |
| `test_hazard_hard_brake_and_local_hit` | Hazard and hard-brake intents; a local hit: flags, brakes at once, the event |
| `test_stale_cars_and_unknown_ids` | Dropped after 3 s of silence; unknown ids counted |
| `test_prediction_error_without_loss_stays_under_the_bounds` | 35 s on the loop, 150 ± 30 ms, no loss: median < 0.15 m, p99 < 0.6 m, near p99 < 0.1 m, 0 teleports, 0 snaps, 0 late intents, no unsignaled lateral motion, blinker ≥ 0.25 s before every move |
| `test_loss_on_the_stream` | The same at 2 % loss (retransmissions): bounds hold, nothing unknown |
| `test_loss_on_a_datagram_path_degrades_gracefully` | 10 % datagram loss: no teleport, stale cars dropped, median bound holds |
| `test_spawns_and_despawns_at_the_area_edges` | After the join every spawn appears out of view; the client's cars lie in the area; every server car well inside it is known |
| `test_loop_seam_wrap` | Across s = k L: cars ahead on the next lap, no jump, bounds hold |
| `test_client_is_deterministic_given_the_same_stream` | A recorded stream replayed twice: identical state hashes every tick, equal to the live run's |
| `test_no_allocation_per_tick` | decode + `apply_frame` and `step` measured around each call: 0 bytes, 0 objects (the ~1 km zone sync excluded) |
| `test_client_tick_cost` | WBBench: `step` and a frame (decode + apply) in the city, 600 µs budgets |
| `soak_network_traffic_ten_minutes` (soak) | 2 × 10.5 min on the loop, 150 ± 30 ms, 2 % loss, a weaving player at 170 km/h: 0 visible teleports, the spec's bounds, late intents < 1 per 10 min, no unsignaled lateral motion, no full state |

`tests/net/test_net_traffic_sandbox.gd`: network mode on the loop sandbox (the server's cars in the sandbox's state, the local sim off, overlays draw, DevStats keys, link cycling, back to local traffic), the snap hook, the dev HUD rows.

## Measured numbers

Headless dev container (Godot 4.7, Xeon @ 2.10 GHz shared with other agents' soaks).

**Soak** (`soak_network_traffic_ten_minutes`: loop_v1 from the desert, normal density, a weaving player at 170 km/h through the client's own view of traffic, 150 ms RTT ± 30 ms, 2 % loss on the stream, 630 s each):

| | Seed 31 | Seed 32 |
| --- | --- | --- |
| Corrections (near the player) | 48,775 (23,371) | 49,092 (24,103) |
| Correction size: median / p99 / max | **5 mm / 22 cm** / 1.55 m | **5 mm / 21.5 cm** / 1.64 m |
| Near (≤ 100 m): p99 / max | 2.0 cm / 27 cm | 1.5 cm / 21 cm |
| Blends small / medium; snaps; large in view | 48,207 / 217; 0; 0 | 48,652 / 172; 0; 0 |
| Visible teleports; the rig's largest per-tick jump in view beyond the car's motion | **0**; 7.9 cm | **0**; 7.9 cm |
| Lane-change intents, late, very late | 841, **0**, 0 | 879, **0**, 0 |
| Cancels (arrived after the move tick) | 94 (87) | 73 (68) |
| Shortest blinker before lateral motion; unsignaled lateral motion ticks | 0.77 s; 0 | 0.77 s; 0 |
| Spawns / despawns (stale, unknown) | 179 / 120 (0, 0) | 215 / 167 (0, 0) |
| Traffic stream (protocol bytes) | 968 B/s | 975 B/s |
| What the client shows vs the server's car at the same true time, near, after 60 s: median / p99 | 10.5 cm / 36 cm | 12 cm / 38 cm |
| Wall time (client + fake server) | 43 s | 42 s |

The spec's netcode bounds (median < 0.15 m, p99 < 0.6 m, late intents < 1 per 10 min) hold with room to spare; the soak gates them. Where the rest comes from (instrumented runs): the largest errors are far cars (1 Hz, 800–900 m out) braking for things the client cannot see (a leader beyond the area's front edge, the zipper at the canyon's tunnel drop). Mirroring the lane-drop harmonisation zones cut the 10-minute p99 from 0.61 m to 0.22 m and the near maximum from 1.86 m to 0.27 m; the bias gain was swept over three seeds × 200 s (gain 0 / 0.5 / 1.0 / 1.5, fade 1.5–6 s): 1.0 with a 6 s fade is best (p99 0.17–0.26 m against 0.37–0.84 m with no bias).

**Cancels after the move tick** are the server's own: a car whose gap turns unsafe cancels at the end of its signal time, the tick it would have started moving, so the cancel reaches the client one way later. The car has begun its move by then (~1–3 cm at 75 ms, ~20 cm after a retransmission) and slides back into its lane with the blinker on.

**The visual error** (last row) is the clock's: the model's own error near the player is millimetres, but `server_now()` is 3–4 ms off the server's true clock (MP-D4), and traffic moves 30–40 m/s.

**Cost** (`test_client_tick_cost`, the city, a replayed stream, the container shared with a soak): `step` ~200 µs per 120 Hz tick with 48 cars (the publish pass every tick, the 20 Hz IDM pass every 6th), about the local `TrafficSim.step`'s cost for the same count (docs/TRAFFIC.md: ~190 µs for 60); a frame (decode + apply + the accelerations re-evaluated) ~190 µs, 20 times a second. Budgets 600 µs each (WBBench). The fake server and the client together run 10.5 simulated minutes in ~43 s; the fast tier's network tests take ~20 s in all. Headroom if phones need it: publish only the cars within the view distance every tick (the rest at 20 Hz), and skip the re-evaluation after frames that carry only far cars.

## Deviations and open questions

- **Late intents (needs a plan row).** Spec: "If an intent arrives after its start tick, the blinker starts late but the move still begins at the specified tick. If it arrives after the move-start tick (very rare), the car catches up along the move curve within 0.2 s." The client also never moves a car sideways before its blinker has shown `traffic_late_min_blinker_s` (0.25 s; the orchestrator's brief: "never a lateral move without a visible blinker for at least a short minimum"): an intent arriving later than 0.25 s before its move tick starts moving 0.25 s after arrival and catches up within 0.2 s after that. At the acceptance link this never happens (intents arrive ~75–300 ms after decision, ≥ 1.0 s before the move).
- **Blend rule on the offset, not the single error:** the spec's times are applied to the size of the offset still running (several corrections can overlap). **Large errors in view never snap**: they slide at ≤ 30 m/s (the brief: "never teleport visibly"); out of view they snap as the spec says.
- **d on the wire** is right-positive (PROTOCOL.md §12). PlayerState's lateral quantities (heading, lateral velocity, yaw rate, steer) are taken right-positive too (CONTRACTS §2) by the harness; §12 does not say so explicitly: please confirm for N5.2.
- **Capacity:** the client's `TrafficState` holds `max_active_vehicles` (90). The area (1.2 km) at rush density in the city (14 × 1.3 per km per lane × 4 lanes) is ~87 cars plus hysteresis: at the limit. Spawns beyond it are dropped and counted (`dropped_full`). Raise the capacity in network mode, or narrow the area at rush.
- **The visual error is the clock's:** with the model matching, what the client shows is off the server's truth by about the car's speed × the clock error (MP-D4: 3–4 ms after convergence, ~0.1–0.15 m at 30–40 m/s). Everyone shares it for all traffic, so the gaps between cars are right; between the player and traffic it is at most that.
- **Cancels at the move tick** (above): if they look bad in playtests, the server could decide a car's end-of-signal safety one round trip early, or the client could delay the lateral start by a tick; both change the model's timing, so neither is done.
- **The MP-D5 safety extensions** are not in `traffic_sim.gd` yet, so neither the fake authority nor the client model has them; when they are ported, mirror `anticipate_leader_braking` in the client's acceleration pass (it is IDM-side and cheap) and `look_through_leaving_leaders` in its leader search.
- **Remote players** (N5.2) are leaders on the server; the client model can take them as participants (the same interval as the local player) when their states are known.

## Checklist for N4.2 (what the server must send)

Per client, per room tick, in that tick's one frame (docs/PROTOCOL.md §2), in this order (the client applies despawns, spawns, intents, corrections in that order whatever the order):

1. **Area of interest:** every car whose wrapped signed distance from the client's player (its latest state extrapolated to the tick) is in [−300 m, +900 m] (`traffic_aoi_behind_m` / `_ahead_m`). A car leaves the area only 20 m beyond an edge (`traffic_aoi_hysteresis_m`), so a car on the edge does not flicker. On `joined` (the room snapshot tick): the whole area.
2. **`traffic_despawn`** for every car that left the area or the ring (an off-ramp exit: when its move into lane 7 completes) since the last frame. Batches of ≤ 128.
3. **`traffic_spawn`** for every car that entered the area (or the ring: an on-ramp car, lane 7), ≤ 128 per batch:
    - `car_id`: from a free list, never reused within 30 s of its despawn, never 0 (MP-D6; 0 is the hit report's "not traffic");
    - `vehicle` = the sim's `type_id`, `profile` = `profile_id`, `color` = `color_index` (u8);
    - `lane`: wire numbering (`n − 1 − lane`, n = lane count at the car's s; 7 for the ramp pseudo-lane);
    - `s_mm`: s wrapped into [0, L), rounded to mm; `d_cm`: the sim's d (+ right), cm; `speed_cms`: v;
    - lane-change state: `signaling` with the intent's `lc_move_start_tick` and `lc_duration_ms` and wire `lc_target_lane`; `moving` with the tick the move started, its duration and target; else all zero;
    - flags: `hazard` (FLAG_HAZARD), `braking` (FLAG_BRAKE).
4. **Every spawned car is also in this frame's `traffic_correction` batch** (same tick): that dates the spawn (spawn entries carry no tick).
5. **`traffic_intent`** (≤ 64 per batch) for cars in the client's area, the tick they are decided:
    - `lane_change`: `start_tick` = the tick the blinker comes on; `move_start_tick` = the tick `tick_signaling`'s accumulation reaches the signal time (the sim's `lc_move_tick`, ≥ 1.0 s later); wire `target_lane` (7 for an off-ramp exit); `duration_ms` = the move time drawn at the signal (`move_time_at_signal`), **rounded to whole ms, and the sim should use the rounded value** (the fake does; else ≤ 0.5 ms of drift);
    - `cancel` when a signal is cancelled (`start_tick = move_start_tick =` that tick). **A Hesitant's cancel is known when its blinker comes on (`will_cancel`): send it in the same frame as the lane change, dated `start_tick = move_start_tick =` the signal's end tick**; the client then never starts the move (otherwise the cancel lands after the move tick and the car starts to move for one round trip);
    - a hit reaction: `hazard` (`hit_recover_s`) and `hard_brake` (`hit_brake_s`, the client brakes at `hit_brake_decel_mps2`) at the hit's tick;
    - no `horn` (client-side).
    A car that enters the area mid-maneuver gets its state in the spawn instead.
6. **`traffic_correction`** (one `tick` per batch = this room tick, ≤ 128 per batch): the state after the room tick's step, i.e. the car at `server_now = tick` (Pong's clock: room tick + fraction since the room started, so the state stamped N is produced at N.0): `car_id`, `s_mm` wrapped, `d_cm`, `speed_cms`. Cars within 100 m of the client's player every 4th tick (5 Hz), every other car in the area every 20th tick (1 Hz), staggered by car id (`(tick + car_id) % period == 0`), plus the spawned cars (item 4).
7. **Order and reliability:** over the WebSocket nothing is lost; the client still tolerates reordering (a correction older than the car's last is ignored), unknown ids (counted) and silence (a car not heard of for 3 s is dropped).
8. **Ramps:** an exit is a `lane_change` to wire lane 7 (the car moves onto the shoulder on the client; there is no ramp geometry yet), then a despawn when it completes; an entry spawns on lane 7 and merges with a `lane_change` intent. The client does not fade them yet.
9. **Budget:** the fake's stream is ~0.7–1.0 kB/s of traffic messages per client at normal density (PROTOCOL.md §11 budgets ~4.4 kB/s for everything).

## Requests (shared files and other WPs)

- **run.gd** (not in N4.3's paths): the network loop mode (N5.2) calls the four lines of *Integration* in place of `sim.step` / `director.step` / `sim.notify_hit`, keeps the opposite carriageway's `director.opposite.step`, and feeds `NetTrafficStats.report_dev_stats()` / `report_link(clock)` to DevStats a few times per second.
- **Plan §2:** a row for the late-intent minimum blinker and the in-view no-snap rule (above).
- **traffic_sim.gd:** nothing needed; the fake authority works through its public API plus reading `_will_cancel` (a test fixture). When MP-D5 is ported, the client mirror (above).
