# Westbound Online: rooms client (N5.2)

WP N5.2, the client side of N5 (rooms and players). Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Players (your car is yours, other players, ghosting, loop strip, spawning, crash-out, rejoin crew, reconnect), Rooms, parties and matchmaking (rooms, Quick Join, room browser, quick chat), Time of day in multiplayer (the room clock), Client changes (`room_client.gd`, `remote_player.gd`, online hub, in-room HUD, room menu). Wire contract: [`PROTOCOL.md`](PROTOCOL.md) §4 and §12 (placements, `d` sign). Server side: [`SERVER.md`](SERVER.md) → Rooms (N5.1) → For the client. Plan: [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md) → N5, MP-D4…MP-D7.

| File | Class | What it is |
| --- | --- | --- |
| `src/net/rooms/room_session.gd` | `NetRoomSession` | The room connection: join (Quick Join, create, code, id), browse, the room state, placements, the 20 Hz upload, hits, run events, chat, host commands, reconnect. Pure RefCounted driven by `poll()` |
| `src/net/rooms/rooms_service.gd` | `NetRooms` | The Node that owns one `NetRoomSession` on a `NetWsTransport` and polls it every frame (also paused); a child of the `NetSession` autoload, `NetRooms.ensure()` / `.current` |
| `src/net/rooms/room_state.gd`, `room_member.gd` | `NetRoomState`, `NetRoomMember` | What the client knows about the room: settings, members, crews, host, the room clock (`cycle_ms_at(server_now)`), mutes |
| `src/net/rooms/remote_track.gd` | `NetRemoteTrack` | One remote player's recent states: interpolation, extrapolation, fade, the seam |
| `src/net/rooms/remote_players.gd` | `NetRemotePlayers` | A fixed pool of 7 tracks keyed by player id |
| `src/net/rooms/remote_car_view.gd` | `RemoteCarView` | The remote cars: a pool of player car models placed from road space each frame, ghosted |
| `src/net/rooms/room_chat.gd` | `NetRoomChat` | Quick chat items and texts |
| `src/run/run_room.gd` | `RunRoom` | The in-room run mode: placements, protection, upload, crash-out, rejoin, clock follow, remotes, HUD feed; snap demos |
| `src/run/run.gd` | `Run` | Thin hooks only (below) |
| `src/ui/hud/room_hud.gd` | `RoomHud` | The in-room HUD layer: loop strip, room line, REJOIN CREW, ROOM, toast, banner, chat feed, nametags |
| `src/ui/hud/widgets/hud_loop_strip.gd` | `HudLoopStrip` | The loop strip |
| `src/ui/hud/room_nametags.gd` | `RoomNametags` | Every nametag in one Control |
| `src/ui/hud/room_menu.gd` | `RoomMenu` | Quick chat and the players (mute, leave) |
| `src/ui/screens/online_hub_screen.gd` | `OnlineHubScreen` | ROOMS enabled: QUICK JOIN, ROOM BROWSER, PRIVATE ROOM, JOIN BY CODE |
| `src/ui/screens/room_lobby_panel.gd` | `RoomLobbyPanel` | The hub's room flows (host options, code, browser, joining status) |
| `src/core/tuning/net_tuning.gd`, `data/tuning/net.tres` | `NetTuning` | The "Rooms (N5.2)" group (below); "Room scoring (N6.2)" |
| `src/net/rooms/score_client.gd` | `NetScoreClient` | N6.2: claims from the run's scoring events, the official score and its easing, crew proximity, trains, official sector bonuses (below: Scoring in a room) |

## Flow

```
hub ROOMS button --> RoomLobbyPanel --> NetRooms (fresh token) --> NetRoomSession
    CONNECTING --Welcome--> LOBBY --lobby_command--> JOINING --room_snapshot--> IN_ROOM
--> RoomLobbyPanel.joined --> OnlineHubScreen.room_ready(session) --> Run.start_room(session)
--> RunRoom: the run (loop mode) built at the placement, RUNNING, protected
```

- The hub emits intents only; `Run._enter` connects `online_hub.room_ready` to `start_room` once the title is built (TitleScreens is not touched).
- **Without a server** (`?server=off`, native dev runs without `--server=`) `NetRooms.ensure()` is null: the four room buttons are disabled with ONLINE OFF and the ROOMS panel says "Rooms need the online server. Loop practice still works." While signing in or offline it says so ("Signing in...", "You're offline. Rooms need a connection.").
- **Refusals** (`room_not_found`, `room_full`, `not_allowed`, `server_full`, a join timeout) show on the panel in hot text with TRY AGAIN and BACK. `already_in_room` (a seat still held by a replaced login) leaves that seat and tries once more.
- **Leaving** (the room menu's LEAVE ROOM, the pause menu's QUIT), a **kick**, the room **closing** or the **seat lost** after a failed reconnect all go through `Run.leave_room(message)`: the title, then the online hub with the message on its ROOMS panel.

## NetRoomSession

```
IDLE --request--> CONNECTING --Welcome--> LOBBY --join sent--> JOINING --snapshot--> IN_ROOM
IN_ROOM --socket lost--> RECONNECTING --Welcome, room_join_code, snapshot--> IN_ROOM (seat kept)
RECONNECTING --room_reconnect_window_s over--> IDLE (`left` seat_lost)
IN_ROOM --leave() / lobby_event.room_left--> LOBBY (`left`) ; a fatal error --> FAILED
```

- Signals: `joined`, `rejoined`, `join_failed(code, message)`, `left(reason, message)`, `room_list`, `room_changed`, `run_result`, `chat(player_id, text)`, `notice`, `reconnecting(on)`, `state_changed`.
- **After every snapshot** `NetClock.reset()` and `NetClient.ping_now()` (additive in `net_client.gd`): Pong now carries the room tick, and the first sample arrives one round trip later instead of up to 2 s. Nothing is uploaded before the clock has a sample (`server_tick()` is -1).
- **Placements** (PROTOCOL.md §12): the client's own id in `player_states` with `run_state = protected`. The server repeats it every tick until answered; the session takes each placement tick once (`has_placement` / `take_placement`, fields `placement_tick/s/d/speed`). Everyone else's states go to `remotes`.
- **Upload:** `send_state(tick, s, d, heading, speed, lat_vel, yaw_rate, steer, flags, run_state)`: `s` is wrapped into [0, L) here; `d` passes unchanged (CONTRACTS: + right of travel); one state per tick (a tick not after the last sent is skipped). Hot path: `NetPlayerState` + `NetCodec.push_player_state`, no Dictionaries.
- `send_hit(tick, target, car_id, lives_left)`, `send_run_event(start|end|rejoin, tick)`, `send_chat(item)` (one per `room_chat_interval_s` on the device; `chat_ready()`), `send_host({kind, ...})`, `set_muted(player_id, on)` (client-side: a muted player's chat is never shown).
- **Reconnect** (spec: seat held 15 s): a dropped socket in a room turns RECONNECTING; the session reconnects every `room_reconnect_retry_s` with the current access token and joins the same room by code. The snapshot brings the same seat back (`rejoined`), and the placement "where the car was" arrives. After `room_reconnect_window_s` it gives up (`left` seat_lost, "Lost the connection to the room."). `update_required`, `server_outdated`, `map_mismatch`, `banned` and a fatal `not_allowed` (signed in elsewhere) are never retried.

## The run in a room (RunRoom)

The run drives **loop mode** (`Run.MODE_LOOP`: the loop road, sectors, the room clock HUD); `run.room` is non-null. `run.gd` keeps thin hooks and RunRoom holds the logic:

| Hook in `run.gd` | What |
| --- | --- |
| `start_room(session)` | loop mode + `RunRoom`, then `retry()` |
| `start_s_m()`, `_start_run` | a pending start placement: the run is built there (s unwrapped near the car, never before lap 1), with its `d` and speed; `room.on_run_started()` then `go()`es at once (no countdown), or holds the countdown until a placement comes |
| `_sim_tick` | `room.tick(dt)`; contacts skipped while protected; a first hit is reported (`hit_report`, lives left) |
| `_begin_crash` | the crash-out reported (`hit_report` lives_left 0) |
| `_show_results` | in a room: RESULTS without the results screen (no `run_over`); the respawn placement starts the next run |
| `frame()` | `room.frame(real_dt)` |
| `room_respawn()` / `room_teleport(s, d, v)` | a fresh run at a placement / the same run moved (`dev_teleport`, `legs.skip_to`, the car's `d`) |
| `leave_room(message)`, `enter_menu()` | out of the room, back to the hub |
| `_on_screen_retry` | the pause menu's RETRY is REJOIN CREW in a room |
| `_sim_tick`, `_crash_tick`, `_count_hit`, `_forward_scoring`, `_brake_surrounding_traffic`, `_update_headlights`, `_start_run` | with network traffic: `room.step_traffic` in place of `sim.step` + `director.step`, the source's `notify_hit`, no local close-pass / surrounding-brake reactions, the source's headlights, and the sim / director / view kept across a respawn (below) |
| `snap_setup` / `_snap_menu` | `--room=demo`, `--title=rooms*` (below) |

- **Placements.** The first one starts the run; a placement while crashed out (or during the held countdown) is the respawn: a fresh run there. Any other (REJOIN CREW, a reconnect) teleports and keeps the run; a rejoin forfeits the unbanked chain (`scoring.notify_hit`: chain lost, and the minimum-speed rule paused for its 3 s grace). Every placement gives `room_protection_s` (3 s) of protection: no traffic hits (the run skips contacts; the minimum-speed rule waits until the speed is reached after a fresh run) and the ghost flicker.
- **Upload.** Once per room tick (N6.2: `floor` of the car's clock, see Scoring in a room → The car's clock; N5.2 used `floor(server_now())`) from the frame: the car's state moved back to the tick's instant along its velocity (s − v cos(yaw) · frac / 20, the same for d), so consecutive states agree with their ticks within centimetres (the server's `distance` check). `run_state`: protected, driving, or crashed (CRASH / RESULTS). Flags: brake (input), boost, headlights (night), ghost (hit ghost or protection). While crashed the speed is sent as 0.
- **Crash-out.** `hit_report` lives_left 0 at the crash; the cinematic (or the fallback skid) plays, then RESULTS waits. The server's `run_result` for this player shows the toast for 3 s ("CRASHED OUT", SCORE (the server's, or the local banked score until N6 scores), distance, time, RESPAWNING, UNVERIFIED when flagged); the respawn placement 3 s after the report starts a fresh run with 3 s protection. Other players' crash-outs go to the feed.
- **REJOIN CREW** (HUD button, pause RETRY): `run_event.rejoin`; the server places the car 40 m behind the crew leader.
- **Room clock.** Every frame `loop.clock.set_time(epoch + room.cycle_ms_at(server_now()) / 1000)`: `cycle` advances with the room clock (public rooms and private `cycle` rooms are UTC-derived, MP-D7), `fixed` and `night` hold the server's value. The loop's RoomClock then gives the sky, night ×2 and the HUD clock that replaces the sun bar (HudLoopFeed). The server's cycle shape (32 / 22 min) equals `loop.tuning` (tested).
- **Traffic (N4.3, [NET_TRAFFIC.md](NET_TRAFFIC.md) → Integration).** Per room: the local traffic director runs as in loop practice until the server streams traffic (the room's first traffic message: `NetRoomSession.traffic_frame`, `traffic_streamed`). Then `RunRoom` builds N4.3's `NetworkTrafficSource` over the run's own `TrafficState` (its `clear()` drops the local cars; the headway scale of the loop's director leg, the car's body, the room clock's headlights) and feeds it every traffic frame (`apply_frame` with the car's unwrapped s, `server_tick()` and the one-way estimate; `note_frame_bytes`). The run then calls `RunRoom.step_traffic` in place of `sim.step` + `director.step` (the source at `server_tick()`, the player a participant; `director.opposite.step` keeps the opposite carriageway local), `net_traffic.notify_hit` in place of `sim.notify_hit`, skips the local close-pass and surrounding-brake reactions (the server's), and hit reports carry the wire `car_id` of the hit slot. The source and the TrafficState are **kept across respawns and teleports** (`_start_run` keeps the sim, director and view in that case; `room_teleport` moves the car without `director.reset`): the server sends a car once while it stays in the area. A reconnect clears the source (the new snapshot's frame brings the whole area). The join frame's signals go out after its placement and before its traffic, so a run started on `joined` gets the first traffic frame. `NetTrafficStats.report_dev_stats()` / `report_link()` feed the dev HUD every 10 frames. `NetTuning.room_network_traffic = false` keeps the local director (dev).
- **Capacity.** In a room the loop's tuning copy raises `max_active_vehicles` to `room_traffic_capacity` (128), so the TrafficState, TrafficView's pools, scoring's slots and HitDetection (re-made when the capacity changes) hold the server's whole area at rush density; single-player keeps its 90.
- **Before the first Pong** of a room `server_tick()` runs from the snapshot's tick and the time since it arrived (behind by the one-way delay; the clock then steps forward), so states, remotes and traffic work from the join frame on.

## Scoring in a room (N6.2)

WP N6.2, the client side of N6. Spec: multiplayer handoff → Scoring in multiplayer (all of it), Client changes (`score_client.gd`; in-room HUD: crew proximity indicator, train counter; room menu: crew total). Contract: [SERVER.md](SERVER.md) → Scoring (N6.1) → Claims (the client contract); [PROTOCOL.md](PROTOCOL.md) §4, §12. Plan: MP-D9 (XP), MP-D10.

**The rules stay the single-player ones.** The run's own `Scoring` (`src/scoring/`, unchanged: parity with the Rust port) scores the network cars at 120 Hz exactly as in loop practice; night ×2 comes from the loop's RoomClock, which follows the room clock every frame (`test_night_doubles_from_the_room_clock`). `NetScoreClient` reads the events the rules wrote into the run's buffer.

**Reading the events.** `RunRoom.tick()` runs inside each 120 Hz tick before that tick's scoring, so it reads the events of the tick before (stamped with that tick's room tick); `RunRoom.frame()` reads the last tick's before the run drains the buffer (`Run.frame` → `adapter.drain()`), then starts again from 0. A stamp is `ceil(room clock)` at the sim tick: the first room tick at or after the event, the tick whose uploaded state (moved back to its instant, N5.2) first shows it.

**The car's clock** (N6.2 fix to N5.2's upload; the contract: "`PlayerState.tick` must describe the car at that tick"). States, hits, run events and claims are stamped with `RunRoom._car_clock`: the room time of the car's latest simulated state, advanced by exactly each 120 Hz tick's `dt` (× 20), following the room clock at most `clock_slew_max_rate` (5 %) faster or slower, and jumping to it when the two are more than `room_stamp_max_hold_ms` (250 ms) apart (a pause, slow motion, a long hitch: a jump forward only lowers the implied speed); outside RUNNING it is the room clock. The live check found two ways the wall-clock stamps broke the server's `distance` check (the run then goes unverified):

- after a frame hitch the physics catches up in bursts (several ticks in one short frame): the car moved 50 ms of sim time while the stamps moved one tick, +2.3 m at 51 m/s (`test_states_follow_the_car_through_hitches`: +1.5 m with wall stamps, < 0.5 m now);
- the first Pong after a snapshot can land behind the snapshot's own estimate (~100 ms on the loaded box): `_room_now()` (the target the car's clock follows) never runs slower than 95 % of the wall clock across such a step back until the estimate catches up (`test_stamps_never_stall_across_a_clock_step_back`).

Every snapshot resets both.

**Claims** (`observe()` queues them in pre-sized packed arrays: no allocation per tick, `test_the_tick_side_allocates_nothing`; `flush()` sends them from the frame, one small frame each, with reused message dictionaries):

| Event | Claim |
| --- | --- |
| `pass` / `close_pass` | `tick` = the tick it was paid (the car fully behind); `cars` = [the car's wire id, `roundi(clearance × 1000)` mm: the rules' minimum hull-to-hull clearance over the pass]; `side` = `right` when the car's d ≥ the player's (+d is right of travel), else `left` |
| `thread` | at the second pass's tick, after that pass's own claim (the rules write the pass, then the thread); `cars` = [the first car (the most recent unused pass on the other side within `score_thread_match_s`, under the thread clearance), the second car], each with its own clearance; `side` = the first car's |
| `cut` | at its tick; `cars` = [the nearest eligible car (the event's slot), 0 mm]; `side` = `none` |

- Wire ids come from `NetworkTrafficSource.car_id(slot)` (`score.wire_id`). Until the server streams traffic (the local director's cars) nothing is claimed (`claims_skipped`). Claim ids count from 1 and wrap at 65,535.
- **No sector claims:** the contract has none; the server finds gantry crossings in the uploaded states.
- Claims queued while the connection is reconnecting are dropped (the server never saw those states).
- **Hit reports** (N5.2, checked against the contract): every counted hit (`hit_report` with the traffic car's wire id and `lives_left`; 0 at the crash-out), none while protected. States carry `run_state = protected` for the whole protection (the placement acknowledgement, MP-D10) and `s` wrapped into [0, L) (the server compares wrapped differences), each moved back to its tick's instant.

**The official score** (`score_sync`): the client keeps its local total (banked + chain) per room tick in a ring (`score_history_s`, 8 s). Each sync's official banked + chain is compared with the client's own total **at `sync.tick`** (the official timeline runs 1.5 s behind): the difference is the correction (`pending_offset`; dev HUD `room_score_offset`). It is applied **only at banking moments** (`flags.banking`) and eased: up within `score_ease_up_s` (0.6 s), down over `score_ease_down_s` (2 s), about a point a frame, so the HUD never takes score away mid-chain nor jumps back. The HUD shows local banked + correction (`Hud.set_score_offset`); the chain and multiplier stay local (instant feedback; trains and the crew factor reach the display at the next bank). A new local run (a respawn) starts without a correction; syncs dated before it, or of an older `run_seq`, describe the run before and are ignored. Totals are compared (not banked alone) so a bank one tick apart on the two sides does not read as a whole chain's difference.

**Crew, trains, sectors.**

- **Crew line** (room HUD, under the room line): `CREW ×1.50 · 2 NEAR` in the accent while crewmates (same crew slot, run going: driving or protected) are within `crew_range_m` (30 m) along the loop, `CREW ×1.00` muted otherwise; +`crew_bonus_per_mate` (0.25) each, capped at `crew_factor_cap` (2.0). Counted every frame from the remote tracks (the server's `crew_in_range` comes 1.5 s late; kept as `official_crew_in_range`).
- **Trains:** `score_event.train` for this player: TRAIN ×n beside the crew line for `train_show_s` (the train counter), `TRAIN ×n +pts` on the event stack (gold), the run's count (`run_trains`); a crewmate's link goes to the chat feed (`Dusty#1234  TRAIN ×3`).
- **Session crew total:** in the room menu (PLAYERS, beside LEAVE ROOM, gold: `CREW TOTAL 48,250`), from `room_snapshot.crews` / `room_event.crew` (spec: "shown in the room menu").
- **Sector bonuses:** the loop run pays its own at the gantry (the sector toast). An official one (`score_event.sector_*`) the run did not pay (same kind within `sector_match_s`) goes on the event stack (`PACE +3,000`); the total reconciles at the bank.
- **The crash-out toast** shows `run_result.score`, the official score (N5.2 showed the local one).
- **Garage XP** (MP-D9 left rooms without it): `run_result` for this player awards XP from its official score through `Garage.award_room_run` → `Garage.award_run` (mode `loop`, which `xp_modes` includes; threads counted; milestones and the Daily streak do not apply), once per `run_seq`, when the run records (`record_best`, as in single-player). Leaving mid-run (LEAVE ROOM, QUIT, a kick, the seat lost) the result never reaches the client, so the XP comes from the last official banked total (`score_sync`), unless the run had already crashed out.
- **Chat feed:** a line is kept clear of the event stack's column (a long name is shortened with an ellipsis on the feed; the nametag shows it whole). The crew row moved the feed down by one line; at 125 % text its third line still ends above the thumb zone (tested).
- Dev HUD: `room_claims_sent`, `room_claims_rejected` (`score_event.claim_rejected`), `room_score_offset`.

**Tuning** (`data/tuning/net.tres`, "Room scoring (N6.2)"):

| Field | Default | Spec |
| --- | --- | --- |
| `score_claim_queue` | 32 | not in spec (claims waiting for the frame) |
| `score_recent_passes` / `score_thread_match_s` | 8 / 1.5 | not in spec (naming a thread's first car) |
| `score_history_s` | 8 | not in spec (the local total per room tick) |
| `score_ease_up_s` / `score_ease_down_s` | 0.6 / 2.0 | "eases its display ... at banking moments"; the times are not in spec |
| `crew_range_m` / `crew_bonus_per_mate` / `crew_factor_cap` | 30 / 0.25 / 2.0 | Crew proximity |
| `train_show_s` | 2.5 | not in spec |
| `sector_match_s` | 6 | not in spec |
| `room_stamp_max_hold_ms` | 250 | not in spec (the car's clock) |

**Tests.**

| File | Covers |
| --- | --- |
| `tests/net/test_score_client.gd` | Claims from the real rules' events (ScoringScenario): pass and close pass (tick, side, wire id, clearance), a thread (after both passes; both cars, each clearance, the first car's side), a cut (nearest car, 0 mm, none); local cars never claimed; the claims decoded by a scripted server, in order, ids counting up; the tick side allocates nothing (static memory and objects over 960 ticks); a full queue; the history ring; easing: equal, server ahead (only at banking, up within 0.6 s), server behind (down, a point or so per frame, many steps), the run before and older runs ignored; crew factor (30 m, other crews, the seam, the ×2 cap, a crashed crewmate); trains and a crewmate's train; claim rejections; official sector bonuses the run did not pay |
| `tests/net/test_score_client_run.gd` | The real Run in a room (`fake_score_server.gd`): streamed cars passed by a bot become claims whose ticks the uploaded states confirm (fully behind at the tick, not 150 ms before); the local director's cars never claimed; score_sync moving the HUD's banked total only at banking, eased up, then down in small steps; the crew line with a crewmate 12 m behind, TRAIN ×3 (badge, stack, count), the crew total in the menu, the official score in the toast; night ×2 from the room clock; XP from run_result once per run, and from the last official banked total on leaving |
| `tests/ui/test_room_score_hud.gd` | The crew line's texts and ink; the TRAIN badge (counts up, restarts, fades); the crew total in the room menu through iOS-style touch ids; text fit beside the gameplay HUD (busy feed, a full stack, three wide feed lines) at 100 % and 125 % on 1280×720 and a notched 1560×720: inside its box and the safe area, no overlap with any HUD text, top half, clear of the thumb zones |

`tests/net/fake_score_server.gd` extends `fake_room_server.gd`: records `score_claim`s; builds `score_sync`, `score_event` and `run_result`.

### Live check

`tests/net/live_score_check.tscn` drives the game's Run in a private room on a local server with a weaving `SandboxBot` through the streamed traffic, and reads `wb_room_claims_total` (by verdict and reason) and the offences from `/metrics`; it also replays the server's `distance` check on the client's own uploads:

```sh
# the server (this branch, its own target dir), dev env, a scratch directory: see "Live check" above
tools/godot.sh --headless --path . res://tests/net/live_score_check.tscn -- http://127.0.0.1:18652 \
    --metrics=http://127.0.0.1:19652 --drive=300 --density=rush --speed=60
```

Against `westbound-server` at this branch's base (N6.1 merged; `rooms.traffic = "sim"`), dev env, debug build, 2026-09-30, the headless run at 60 fps on the shared box (a full fast test tier ran alongside the first):

| Run | Claims (all kinds) | Accepted | Rejected | Offences | Official vs local banked |
| --- | --- | --- | --- | --- | --- |
| normal density, bot at 62 m/s, 300 s | 38 | **38 (100 %)** | 0 | 0 (verified) | 33,699 vs 33,700 |
| rush, bot at 64 m/s, 300 s | 57 | **57 (100 %)** | 0 | 0 (verified) | 29,662 vs 29,656 |

```
account                  ok
room, the run starts     ok    code NVDM8B, normal traffic, the bot at 62 m/s
traffic streamed         ok
claims sent              ok    38 sent (skipped 0, dropped 0, unmatched threads 0); 0 rejections seen by the client; 0 respawns
official score           ok    313 syncs; official banked 33699 (run 1), local banked 33700, last correction -1, unverified false
server acceptance        ok    38 of 38 accepted (100.00 %); late 0
no offences              ok    wb_room_offences_total +0 (server plausibility); client-side distance flags 0
LIVE_SCORE ok (0 failed)
```

Over every run against that server during the WP (including the ones before the car's clock fix): **307 of 308 claims accepted (99.7 %)**, the one rejection `no_pass` in a run that also had a `distance` offence from the wall-clock stamps; 6 reported traffic hits, all confirmed; 0 unreported contacts. Before the fix, 5 of 9 development runs went unverified by a `distance` offence; after it, 0 of 2. The official score tracks the local one within a few points (the server's 20 Hz sampling of the multiplier's decay), the banking-moment easing absorbs it. The bot passes mostly in adjacent lanes (few threads or cuts); the server's parity and room tests cover those kinds.

Snaps (both renderers; `--train=N` a TRAIN link, `--sector=<kind>` an official sector bonus, N5.2's `--room=demo` otherwise):

```
tools/snap.sh src/run/run.tscn --renderer=both --mode=loop --at=desert --room=demo --remotes=4 --speed_kmh=150 --train=3 --sector=pace --tag=room_score
tools/snap.sh src/run/run.tscn --mode=loop --at=desert --room=demo --remotes=4 --room_menu=players --tag=room_score_menu
tools/snap.sh src/run/run.tscn --mode=loop --at=city --room=demo --remotes=3 --room_toast=1 --clock_min=26 --train=2 --tag=room_score_night
```

**Deviations and open points (N6.2).**

- The session crew total is in the room menu only (spec); an earlier HUD row for it pushed the chat feed into the thumb zone at 125 %.
- Room XP is awarded from the official score (MP-D9 said "no XP for now"): the orchestrator's MP-D9 row needs the update. Mode `loop` (no separate `room` mode in `xp_modes`).
- Trains and the crew factor are not in the local chain (the client's `Scoring` has no crew factor: `src/scoring/` stays at parity); they reach the display at the next banking moment.
- `tests/ui/test_room_hud.gd` (N5.2): its toast test now passes the official score (the toast no longer takes the higher of official and local).

## Remote players

- **Tracks** (`NetRemoteTrack`, pure, `# lint: sim`, allocation-free after init): a ring of 16 states in packed arrays. Late or repeated ticks are dropped. `sample(render_tick)` at `server_now() − room_interp_delay_ms` (100 ms): linear interpolation between the two states around it; past the newest, dead reckoning along the road (s += v cos(heading) t, d += v sin(heading) t, road-relative heading) for at most `room_extrap_max_ms` (250 ms); then the car holds and fades out over `room_fade_out_s` until data arrives.
- **The seam.** Each pushed `s` (wrapped on the wire) is unwrapped next to the newest stored one with the wrapped signed difference, so a track is continuous across the start / finish line (it may run past L or below 0). The run maps it next to its own unwrapped s with `LoopRoadPath.unwrap_near`. A state farther than `room_snap_distance_m` from the track's prediction (a server placement) restarts the track: the car jumps instead of sliding.
- **Pool** (`NetRemotePlayers`): 7 slots built once; a player takes a free slot on their first state and gives it back on `leave` / `kick`; the next player reuses the same track object (tested: no objects allocated by joins, leaves, pushes or samples). A full pool counts `overflow`.
- **Cars** (`RemoteCarView`): 7 player car models (`room_remote_car`, the Falcon GT), merged draws, no CarVisual (wheels at rest), interior hidden, painted in the crew color, brake lights from the state's brake flag; placed from road space each frame (`RoadSample.local_point`, floating origin), physics interpolation off. **Ghosting:** never in hit detection or the traffic sim; opacity × `room_ghost_near_opacity` within `room_ghost_near_m` (15 m), × `room_ghost_overlap_opacity` when the boxes overlap, through the engine's per-instance `transparency` on the car's own vehicle materials (the "shared translucent variant": no second material; the value snaps to 1/20 steps and is written only when it changes). Checked on both renderers (snaps). A car costs the player car's draws (about 6).
- **Nametags** (`RoomNametags`): one Control draws every tag, `name#1234 [CREW]` in the crew color, outlined, `room_nametag_lift_m` above the car, within `room_nametag_max_m` along the loop, fading with the track; the player's latest quick chat above it for `room_chat_show_s`. Tag texts are rebuilt only when the member changes.

## Room HUD

A CanvasLayer (layer 6: over the gameplay HUD, under the in-run screens), hidden on the title and while paused.

- **Loop strip** (`HudLoopStrip`): the whole loop along the top edge (in the top margin over the sun bar): a mark per sector gantry, a dot per player in the crew color, yours in the accent and larger. One draw call; redraws only when a dot moves a whole pixel.
- **Room line** under the score panel: `ROOM K7QX2M · 5/8 · 42 MS` (ping rounded to 5 ms, rebuilt only when it changes). The chat feed under it (3 lines, newest first, `name#tag  TEXT` in the crew color, `room_chat_show_s`).
- **N6.2:** the crew line (`CREW ×1.50 · 2 NEAR`) with the TRAIN ×n badge beside it sits between the room line and the feed; the room menu's PLAYERS shows the session crew total (see Scoring in a room).
- **REJOIN CREW** and **ROOM** top-right under the pause / camera / high-beam buttons (touch targets, clear of the thumb zones; REJOIN disabled unless driving in the room).
- **Room menu** (ROOM): CHAT (six phrases, HONK!, two emotes; WAIT while rate-limited; a chat closes the menu) and PLAYERS (a button per member: tap to mute / unmute; YOU and HOST marked; LEAVE ROOM). Esc closes it.
- **Toast** (crash-out results, 3 s) and **banner** ("RECONNECTING · 12 S", server notices) in the event stack's column.
- The room clock is the gameplay HUD's sun bar in clock mode (N3.2's HudLoopFeed), following the server.

## Tuning (`data/tuning/net.tres`, "Rooms (N5.2)")

| Field | Default | Spec |
| --- | --- | --- |
| `room_interp_delay_ms` / `room_extrap_max_ms` | 100 / 250 | Remote player interpolation delay / max extrapolation |
| `room_fade_out_s` | 0.5 | not in spec ("fade the car until data arrives") |
| `room_track_samples` / `room_snap_distance_m` | 16 / 40 | not in spec |
| `room_max_remotes` | 7 | up to 8 players |
| `room_protection_s` | 3 | Spawn / rejoin protection |
| `room_reconnect_window_s` / `room_reconnect_retry_s` | 15 / 1 | Reconnect seat hold / not in spec |
| `room_join_timeout_s` | 10 | not in spec |
| `room_result_toast_s` | 3 | the 3-second results toast |
| `room_ghost_near_m` / `room_ghost_near_opacity` / `room_ghost_overlap_opacity` | 15 / 0.55 / 0.2 | translucent within 15 m / not in spec |
| `room_nametag_max_m` / `room_nametag_lift_m` / `room_nametag_font_px` | 350 / 1.8 / 15 | not in spec |
| `room_crew_colors` | 8 colors | not in spec (RoomCrew.color indexes it) |
| `room_remote_car` | 0 | not in spec (the protocol carries no car) |
| `room_chat_interval_s` / `room_chat_show_s` / `room_chat_feed_lines` | 1 / 4 / 3 | "rate-limited" / not in spec |
| `room_browse_refresh_s` | 5 | not in spec |
| `room_fixed_morning_min` / `room_fixed_golden_min` | 3 / 18 | PRIVATE ROOM's fixed times (not in spec) |
| `room_network_traffic` | true | not in spec: switch to the server's traffic when it streams it (false: always local, dev) |
| `room_traffic_capacity` | 128 | not in spec: the run's TrafficState in a room holds at least this many (N4.2: 45–95 cars in the area at rush); single-player keeps 90 |
| `room_strip_width_px` / `_height_px` / `_dot_px`, `room_font_px`, `room_button_width_px`, `room_panel_width_px` | 520 / 6 / 6, 16, 200, 680 | not in spec |

## Tests

| File | Covers |
| --- | --- |
| `tests/net/test_room_track.gd` | Interpolation, 100 ms behind, extrapolation to 250 ms then the fade, lateral dead reckoning (+ heading = + d), the seam both ways and `unwrap_near` across laps, late / repeated states, a placement jump restarting the track, the ring, no allocation; the pool: 7 slots, your id skipped, overflow, track objects reused with no allocation |
| `tests/net/test_room_session.gd` | Quick Join through every state, the room state (members, host, crews, `name#1234 [TAG]`), create / code (normalized) / id commands, refusals and the join timeout, `already_in_room` retry, the browser, placements taken once per tick, states stamped with room ticks once per tick (s wrapped, d unchanged), nothing sent outside a room, hits / run events / chat and its rate limit, room events (join, connection, host change, leave frees the slot), run results, chat and mute, a kick, reconnect within the hold (rejoin by code, same seat, placed), the hold running out, a ban not retried, the room clock (cycle advances with ticks and wraps, night ×2, night mode holds, the server's cycle = the loop's) |
| `tests/net/test_room_run.gd` | A real Run in a room against the scripted server: the first placement starts the run there (s, d, speed) with 3 s protection (no hits, then hits reported), about 20 states a second one per tick and consistent with their ticks, remote cars drawn with nametags and strip dots, translucent within 15 m, gone after the extrapolation and fade; the crash-out reported, RESULTS without a results screen, the toast, the respawn placement starting a fresh run; REJOIN CREW teleporting and keeping the run (chain forfeit); the room clock driving the sky and night; LEAVE ROOM and a kick back to the hub; a dropped socket (driving on, the banner, the seat back, a teleport not a new run); a lost seat back to the hub |
| `tests/net/test_room_run.gd` (N4.3) | Network traffic taking over at the first traffic frame (the run's TrafficState, only the server's cars, the model driving them, the opposite side local, a traffic hit reporting the wire car id); kept across a respawn and a rejoin, cleared by a reconnect |
| `tests/ui/test_room_hub.gd` | Rooms off without a server; QUICK JOIN, PRIVATE ROOM (density, GOLDEN = fixed, NIGHT), JOIN BY CODE (validation, normalization) and the BROWSER (rows, join by id) through iOS-style touch ids (`1_893_457_201`); a refusal and TRY AGAIN; touch targets on screen; the parting message |
| `tests/ui/test_room_hud.gd` | The room line; ROOM → chat (GG sent), WAIT while rate-limited, PLAYERS → mute, LEAVE ROOM, CLOSE through touch ids; REJOIN CREW; the strip's dots and no redraw when still; the toast's text and 3 s; the feed; the reconnecting banner; the layout (clear of the thumb zones, top-right, top half) |

`tests/net/fake_room_server.gd` extends the N2.2 `fake_server.gd` with rooms (snapshot + placement in one frame, room lists, leaves; records states, hits, run events, chat).

## Live check

`tests/net/live_room_check.gd` drives two throwaway device accounts through a private room on a running server (it refuses the production host):

```sh
(cd westbound-server && CARGO_TARGET_DIR=$PWD/target nice cargo build -p server)
mkdir -p /tmp/wb && cp westbound-server/config/dev.toml /tmp/wb/ && cd /tmp/wb
WB_SERVER__ENV=dev WB_SERVER__BIND=127.0.0.1:18652 WB_METRICS__BIND=127.0.0.1:19652 WB_BACKUP__ENABLED=false \
    <repo>/westbound-server/target/debug/westbound-server --config dev.toml &
# from the repo:
tools/godot.sh --headless --path . --script res://tests/net/live_room_check.gd -- http://127.0.0.1:18652
```

**Run for N5.2** against `westbound-server` at `b1548ef` (N5.1 rooms, `rooms.traffic = none`), dev env, 2026-09-30:

```
accounts               ok    A 3, B 4
create                 ok    code AW3DHA, you 1, host true
placed                 ok    s 150.0 d 7.10 tick 0
join by code           ok    B is player 2; placed 41.5 m from A
members                ok    2/8
remote tracks          ok    A sees B within 0.000 m, B sees A within 0.000 m (100 ms behind); states sent 63 / 61
room clock             ok    cycle 465.8 s, UTC phase 465.8 s (err 0.009 s)
run_result             ok    crashed, distance 90 m, verified true
respawn                ok    after 3.0 s
rejoin crew            ok    placed 40.0 m behind B
reconnect              ok    reconnecting true, reconnecting false, rejoined; player 2 again
leave                  ok    1/8
LIVE_ROOM ok (0 failed)
```

The server logged `room seat taken`, `run ended ... reason=Crashed verified=true`, `room seat held` / `taken back ... was_held=true`, and `/metrics` showed `wb_room_offences_total` 0 for every kind (no implausible state) with 10 placements and 2 reconnects.

`tests/net/live_room_run_check.tscn` puts **the game's Run** in the room (RunRoom's placements, the upload from the real car, protection, the crash-out and respawn) with a lane-keeping bot, while a bare session watches it; the server's own plausibility checks judge every state (`/metrics`):

```sh
tools/godot.sh --headless --path . res://tests/net/live_room_run_check.tscn -- http://127.0.0.1:18652 --metrics=http://127.0.0.1:19652
# with a picture of the room and its streamed traffic (Compatibility renderer, virtual display):
xvfb-run -a -s "-screen 0 1280x720x24" tools/godot.sh --path . --rendering-method gl_compatibility --rendering-driver opengl3 \
    --audio-driver Dummy --resolution 1280x720 res://tests/net/live_room_run_check.tscn -- http://127.0.0.1:18652 --shot=/tmp/room.png
```

Against the server with N4.2's traffic streaming (`rooms.traffic = "sim"`, the default since N4.2; this branch after merging it), 2026-09-30:

```
accounts               ok
A creates, the run starts ok    code XBX9MX, s 25153, protected true
B joins by code        ok    2/8
B sees A drive         ok    37.9 m/s, 3.8 m behind A's car (100 ms at speed = 3.8 m); A sent 203 states
traffic streamed       ok    35 cars (28 ahead, nearest 102 m; 7 behind), capacity 128; corrections 616, mean 0.032 m, max 2.30 m; spawns 39, despawns 4, intents 12, dropped_full 0
crash-out, respawn     ok    respawns 1, lives 2
traffic after respawn  ok    35 cars (27 ahead, nearest 0 m; 8 behind), capacity 128; corrections 1024, mean 0.036 m, max 2.71 m; spawns 41, despawns 6, intents 26, dropped_full 0
no offences            ok    wb_room_offences_total = 0 (server plausibility)
LIVE_ROOM_RUN ok (0 failed)
```

(About 200 states in 11 s: the headless run on the loaded box drew under 20 frames a second at times, and the upload sends at most one state per frame, the latest tick. "nearest 0 m" after the respawn is a car beside the placement, in another lane: the server's gap search keeps the spawn lane clear.)

**Play it** against the local server (streamed traffic included):

```sh
# 1. the server (from this branch; its own target dir), dev env, a scratch directory
(cd westbound-server && CARGO_TARGET_DIR=$PWD/target nice cargo build -p server)
mkdir -p /tmp/wb && cp westbound-server/config/dev.toml /tmp/wb/ && cd /tmp/wb
WB_SERVER__ENV=dev WB_SERVER__BIND=127.0.0.1:18652 WB_METRICS__BIND=127.0.0.1:19652 WB_BACKUP__ENABLED=false \
    <repo>/westbound-server/target/debug/westbound-server --config dev.toml
# 2. player one, native (repo root): title -> ONLINE -> PRIVATE ROOM -> CREATE ROOM (the code is on the room line)
tools/godot.sh --path . -- --server=http://127.0.0.1:18652
# 3. player two, the web build in a browser (its own device account in localStorage):
tools/export_web.sh && (cd build/web && python3 -m http.server 8000)
#    open http://127.0.0.1:8000/index.html?server=http://127.0.0.1:18652 -> ONLINE -> JOIN BY CODE
```

Two native copies on one machine share the device account stored per server (`user://`), so the newer login wins and the first gets "This account signed in on another device": use a native copy and the web build (or two browser profiles / a private window) for two players on one machine. `?server=off` keeps the hub's rooms off.

## Snaps

```
tools/snap.sh src/run/run.tscn --renderer=both --mode=loop --at=desert --room=demo --remotes=4 --speed_kmh=150 --tag=room
tools/snap.sh src/run/run.tscn --mode=loop --at=desert --room=demo --remotes=3 --room_menu=chat --tag=room_menu     # or players
tools/snap.sh src/run/run.tscn --mode=loop --at=city --room=demo --remotes=3 --room_toast=1 --clock_min=26 --tag=room_night
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --sweep=title:rooms,rooms_off,rooms_create,rooms_code,rooms_browser,rooms_joining,rooms_failed
```

`--room=demo` (RunRoom.snap_room) drives the run in a room with no server: `--remotes=N` players around the car (the nearest within 15 m, translucent), a chat on a nametag and in the feed; `--title=rooms*` (RunRoom.snap_hub) opens the hub's room flows with a server-less rooms service.

## Parties (N9.3)

WP N9.3, the client side of parties, invites, invite links and the room-dependent social parts. Spec: multiplayer handoff → Rooms, parties and matchmaking (Parties, Friends and presence: the Join button, Private rooms: invite links, host rules), Client changes (`lobby.gd`: presence, parties, invites, deep-link handling; Party panel and friends list; Room menu: invite, host settings). Server contract: SERVER.md → Parties (N9.3), Invite links and deep links.

| File | Class | What |
| --- | --- | --- |
| `src/net/rooms/party.gd` | `NetParty` | The party (code, leader, members in join order, `me` from Welcome) and the invites waiting (newest first, one per code, at most `party_invites_max`, `party_invite_show_s` old at most) |
| `src/net/rooms/room_session.gd` | `NetRoomSession` | `party_create / party_join / party_invite / party_leave / party_kick`, `decline_invite`, `connect_lobby`; `party_changed`, `party_invited`, `party_left`, `lobby_error`; `accept_follows`; `invite_url()` |
| `src/net/rooms/rooms_service.gd` | `NetRooms` | The same with a fresh token; `connect_lobby()`; `invite_url(code)`; attaches `NetSocialClient` (presence) to the room connection |
| `src/net/rooms/invite_link.gd` | `NetInviteLink` | The code the game was opened with: `?room=` (web) / `--room=` (native; `demo` is the snap room, not a code); `from_url()` for links the OS hands the app |
| `src/ui/screens/online_hub_screen.gd` | `OnlineHubScreen` | PARTY (third column of the ROOMS panel) over the party's line; opens the lobby connection; invites while it shows; party moves to the run; the friends list's JOIN / INVITE seams; invite links |
| `src/ui/screens/room_lobby_panel.gd` | `RoomLobbyPanel` | PARTY, JOIN PARTY (code), PARTY INVITE views; a friend's room; invite links (room, else party) |
| `src/ui/screens/friends_panel.gd` | `FriendsPanel` | INVITE on online friends (`NetSocialClient.invite_handler`); JOIN is live (`join_handler`) |
| `src/ui/hud/room_menu.gd` | `RoomMenu` | The ROOM tab: invite link, host settings, REMOVE A PLAYER |
| `src/ui/screens/dev/party_preview.tscn` | | Snap scene |

**The lobby connection.** Parties need the WebSocket. The hub opens it when it shows (`NetRooms.connect_lobby`) and it stays up (presence rides on it: N5.2 left `attach_lobby` unwired). Party commands connect first when needed and are sent after the Welcome. A room request made while the connection is on its way waits for the Welcome instead of opening a second one. A lobby connection that drops **while in a party** reconnects every `party_reconnect_retry_s` for `party_reconnect_window_s` (the server holds the place 15 s): the server sends the state in the Welcome's frame; a Welcome without it means the server let the place go, and the party is dropped (`party_left lost`, "Lost the connection to your party.").

**Party moves.** When the leader takes a seat, the server seats the other members (SERVER.md → Parties): a member's client sees `room_left {left}` from its old room, if any, then a `room_snapshot` it did not ask for. `NetRoomSession.accept_follows` (true while the hub shows) takes it as a join (`joined`, placement, the run); otherwise (a single-player run, the title) the seat is left again. The hub hands a join nobody on it asked for to the run (`room_ready`). A member in a room going with the leader goes through the hub (`left` → the hub → `joined`). A member's QUICK JOIN goes to the leader's room (the server's rule); `not_party_leader` ("Your party leader picks the room.") shows while the leader has none.

**Refusals.** Party refusals (`party_not_found`, `party_full`, `blocked`) and anything refused outside a join (a follow that could not seat, `not_allowed` for an invite) come as `lobby_error(code, text)`, never as a join failure; the party views show them in hot text.

**The hub.** ROOMS gets a third column: PARTY over the party's line (`NO PARTY YET`; `3/8 · YOU LEAD`; `3/8 · Dusty#1234 LEADS`; gold `Dusty#1234 INVITES YOU`; shortened with "..." to the column). PARTY opens (a waiting invite first):

| View | Shows | Buttons |
| --- | --- | --- |
| PARTY (none) | "PLAY TOGETHER: A PARTY MOVES BETWEEN ROOMS AS ONE CREW" | BACK, JOIN PARTY, CREATE PARTY |
| PARTY `K7QX2M` | the members, two columns (`name#1234`, LEADER / YOU; names shortened to the button); who picks the room | INVITE FRIENDS (the friends list), SHARE LINK (the share sheet, else the clipboard: COPY LINK; "LINK COPIED"), LEAVE PARTY; BACK. The leader taps a member (TAP AGAIN TO REMOVE) and again within `confirm_tap_s` to kick |
| JOIN PARTY | the code field (normalized like room codes) | BACK (to PARTY), JOIN |
| PARTY INVITE | gold `Dusty#1234 INVITES YOU`, "JOIN THEIR PARTY: YOU MOVE BETWEEN ROOMS TOGETHER" | DECLINE (nothing sent), ACCEPT (`party_join` with the code; the leader's room follows) |

An invite that arrives while the hub shows opens its card; otherwise it waits behind PARTY (in a room it waits for the hub; the room HUD does not show it, see Deviations).

**Friends.** JOIN on a friend in a room with space opens the hub with "FRIEND'S ROOM · JOINING ROOM 12..." (`room_join_id`); INVITE on an online friend sends `party_invite` (a party is made first) and says "Invite sent to Ali.". Both seams are set while the hub exists and cleared with it.

**Invite links.** `https://<domain>/r/<code>` (SERVER.md → Invite links) opens the web build with `?room=<code>`; natively `--room=<code>`. Once signed in and on the title (or the hub), the hub opens and follows it: "INVITE LINK · JOINING K7QX2M..." by code; when no room has the code (`room_not_found`), the party with it (the PARTY view); neither: "No room or party with that code." Taken once. `NetRooms.invite_url(code)` builds the link from the session's server (`invite_path`, `/r/`).

**Host settings (room menu → ROOM).** INVITE `westbound.sipsakrandevu.com/r/K7QX2M` (the code alone when the link does not fit) with COPY LINK (and SHARE where the browser has a share sheet). The host of a private room: TRAFFIC (LIGHT / NORMAL / RUSH HOUR) and TIME OF DAY (CYCLE / MORNING / GOLDEN / NIGHT, the fixed times of PRIVATE ROOM) sent as `room_host_command`s, the room's current settings selected (from `room_event.settings`); REMOVE A PLAYER switches PLAYERS to removing (TAP TO REMOVE, TAP AGAIN TO REMOVE within `confirm_tap_s`, then `kick`; mute taps come back after, and with any other tab). Everyone else: "ONLY THE HOST CHANGES TRAFFIC AND TIME"; public rooms: "PUBLIC ROOM · NORMAL TRAFFIC ON THE WORLD CLOCK". The header is two rows now (title and settings line with CLOSE; CHAT / PLAYERS / ROOM under them).

**Ping in the room browser:** N5.2's rows already carry `· 42 MS` (the round trip to the one server; rooms share it).

**Tuning** (`data/tuning/net.tres`, "Parties (N9.3)"): `party_invite_show_s` 120, `party_invites_max` 4, `party_max_members` 8 (spec), `party_reconnect_retry_s` 2, `party_reconnect_window_s` 15, `invite_path` `/r/` (spec), `confirm_tap_s` 3 (not in spec unless marked).

**Tests.**

| File | Covers |
| --- | --- |
| `tests/net/test_room_party.gd` | create (connecting first; the creator leads), join by code (normalized; members, leader), refusals as lobby errors (also during a join), invites (kept, capped, one per code, accepted with `party_join`, declined without a message, expired), a kick, party moves taken only with `accept_follows` (else the seat is left; without a party too), the party across a lobby reconnect and dropped when the Welcome carries no state or the window ends, invite URLs, `?room=` / `--room=` / `demo` / links from the OS, presence subscribed on the room connection, `NetParty` bookkeeping |
| `tests/ui/test_party_ui.gd` | through iOS-style touch ids (`1_893_457_201`): the hub opens the lobby connection and takes party moves only while it shows; CREATE PARTY and the members; JOIN PARTY by code (validation, BACK) and LEAVE PARTY; SHARE LINK copying; the leader's two-tap removal; an invite's card (DECLINE sends nothing, ACCEPT joins), an invite waiting behind PARTY; a party move handed to the run; the friends list's JOIN (the hub, `room_join_id`, the run) and INVITE seams, gone with the hub; invite links (room, else party, else the message); INVITE FRIENDS; text fit of the hub and the party views (eight 16-W names, the leader's armed removal, an invite from a 16-W name) at 100 % / 125 % on 1280x720 and a notched 1560x720 |
| `tests/ui/test_room_menu_host.gd` | the ROOM tab: the link and COPY LINK; locked for players and public rooms; the host's TRAFFIC and TIME OF DAY commands and the settings shown; REMOVE A PLAYER with two taps; text fit at 100 % / 125 % on both canvases |
| `tests/ui/test_social_screens.gd` | INVITE on online friends only, through the seam |
| `tests/net/fake_party_server.gd` | The scripted room server plus parties (not a test file) |

### Live check

`tests/net/live_party_check.gd`: four throwaway device accounts on a running server (it refuses the production host). A and B become friends over HTTP, A invites B (the invite reaches B, B accepts with its code), C joins with the party code and the server's invite page for it answers, A Quick Joins and B and C follow into the same public room as one crew, a solo D Quick Joins the fullest room with a crew of their own, the party passes to B when A leaves.

```sh
# the server (this branch, its own target dir), dev env, a scratch directory: see "Live check" above
tools/godot.sh --headless --path . --script res://tests/net/live_party_check.gd -- http://127.0.0.1:18693
```

Against `westbound-server` at this branch (dev env, `rooms.traffic = "sim"`), 2026-09-30:

```
accounts                   ok    A 5, B 6, C 7, D 8
friends                    ok    BraveRover#8121 + BraveMustang#4848
lobby connections          ok    4 sockets
invite reaches B           ok    from BraveRover#8121
A leads a party            ok    code UBSF3E
B accepts                  ok    2 members, leader BraveRover#8121
C joins by code            ok    3 members
invite page                ok    http://127.0.0.1:18693/r/UBSF3E -> 200, opens the web build with ?room=UBSF3E
party quick join           ok    room 1 (public), 3/8
one crew                   ok    crew slots A 0 B 0 C 0
solo quick join            ok    room 1, 4/8
solo crew                  ok    D 1 vs party 0
party left                 ok    B leads now
LIVE_PARTY ok (0 failed)
```

The server logged `party created`, `party invite`, `party joined` ×2, `joined room ... party=2 follow=false`, `party moves ... followers=2`, two `joined room ... follow=true`, `party leader passed`; `/metrics` showed 0 offences.

### Snaps

```
tools/snap.sh src/ui/screens/dev/party_preview.tscn --renderer=both --sweep=party:none,lead,member,kick,invite,link,hub
tools/snap.sh src/ui/screens/dev/party_preview.tscn --renderer=both --seconds=2.5 --sweep=party:room_host,room_player
tools/snap.sh src/ui/screens/dev/party_preview.tscn --size=2496x1320 --text_scale=1.25 --party=lead
```

## Deviations and open questions

- **Pause in a room** still pauses the local run (the tree): no states go up, so the others see the car fade after 250 ms; the seat is kept (the socket stays up). A room-aware pause (the car keeps driving under the menu) is left open.
- **Host settings in the room:** done in N9.3 (the room menu's ROOM tab, see Parties → Host settings).
- **Invite links / party:** N9.3 (see Parties). Until the server streams traffic, the room's density does not change the local director.
- **Remote players as IDM leaders for network cars** (the server has them as participants): not added. N4.3's `NetworkTrafficSource` models one participant (the local player, index `_P` in its sorted order); remote players would need extra participant entries in its sort and leader search (`src/net/traffic/**`, N4.3's file). The per-car bias and the corrections cover the difference meanwhile. Hook: `RunRoom._draw_remotes` already samples every remote at the room clock.
- **Party invites inside a room** (N9.3) wait for the hub: the room HUD (`room_hud.gd`, N5.2's file, not this WP's) does not show them. A line on the chat feed ("Dusty#1234 INVITES YOU") would be a small follow-up there.
- **A party move while not on the hub** (a single-player run, the title) is declined by the client (the seat is left again); the member can QUICK JOIN later, which goes to the leader's room.
- **Presence over the room socket:** wired in N9.3 (`NetRooms.setup` attaches `NetSocialClient` to the room connection; the friends list polls only while it is down).
