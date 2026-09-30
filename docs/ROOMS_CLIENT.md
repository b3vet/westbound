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
| `src/core/tuning/net_tuning.gd`, `data/tuning/net.tres` | `NetTuning` | The "Rooms (N5.2)" group (below) |

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
| `snap_setup` / `_snap_menu` | `--room=demo`, `--title=rooms*` (below) |

- **Placements.** The first one starts the run; a placement while crashed out (or during the held countdown) is the respawn: a fresh run there. Any other (REJOIN CREW, a reconnect) teleports and keeps the run; a rejoin forfeits the unbanked chain (`scoring.notify_hit`: chain lost, and the minimum-speed rule paused for its 3 s grace). Every placement gives `room_protection_s` (3 s) of protection: no traffic hits (the run skips contacts; the minimum-speed rule waits until the speed is reached after a fresh run) and the ghost flicker.
- **Upload.** Once per room tick (`floor(server_now())`) from the frame: the car's state moved back to the tick's instant along its velocity (s − v cos(yaw) · frac / 20, the same for d), so consecutive states agree with their ticks within centimetres (the server's `distance` check). `run_state`: protected, driving, or crashed (CRASH / RESULTS). Flags: brake (input), boost, headlights (night), ghost (hit ghost or protection). While crashed the speed is sent as 0.
- **Crash-out.** `hit_report` lives_left 0 at the crash; the cinematic (or the fallback skid) plays, then RESULTS waits. The server's `run_result` for this player shows the toast for 3 s ("CRASHED OUT", SCORE (the server's, or the local banked score until N6 scores), distance, time, RESPAWNING, UNVERIFIED when flagged); the respawn placement 3 s after the report starts a fresh run with 3 s protection. Other players' crash-outs go to the feed.
- **REJOIN CREW** (HUD button, pause RETRY): `run_event.rejoin`; the server places the car 40 m behind the crew leader.
- **Room clock.** Every frame `loop.clock.set_time(epoch + room.cycle_ms_at(server_now()) / 1000)`: `cycle` advances with the room clock (public rooms and private `cycle` rooms are UTC-derived, MP-D7), `fixed` and `night` hold the server's value. The loop's RoomClock then gives the sky, night ×2 and the HUD clock that replaces the sun bar (HudLoopFeed). The server's cycle shape (32 / 22 min) equals `loop.tuning` (tested).
- **Traffic seam (N4.3).** `NetTuning.room_local_traffic` (true) keeps the local traffic director as in loop practice. `RunRoom.use_local_traffic(false)` is where N4.3's network traffic source replaces it; hit reports send `car_id` 0 until the network car ids exist.

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
| `room_local_traffic` | true | the N4.3 seam |
| `room_strip_width_px` / `_height_px` / `_dot_px`, `room_font_px`, `room_button_width_px`, `room_panel_width_px` | 520 / 6 / 6, 16, 200, 680 | not in spec |

## Tests

| File | Covers |
| --- | --- |
| `tests/net/test_room_track.gd` | Interpolation, 100 ms behind, extrapolation to 250 ms then the fade, lateral dead reckoning (+ heading = + d), the seam both ways and `unwrap_near` across laps, late / repeated states, a placement jump restarting the track, the ring, no allocation; the pool: 7 slots, your id skipped, overflow, track objects reused with no allocation |
| `tests/net/test_room_session.gd` | Quick Join through every state, the room state (members, host, crews, `name#1234 [TAG]`), create / code (normalized) / id commands, refusals and the join timeout, `already_in_room` retry, the browser, placements taken once per tick, states stamped with room ticks once per tick (s wrapped, d unchanged), nothing sent outside a room, hits / run events / chat and its rate limit, room events (join, connection, host change, leave frees the slot), run results, chat and mute, a kick, reconnect within the hold (rejoin by code, same seat, placed), the hold running out, a ban not retried, the room clock (cycle advances with ticks and wraps, night ×2, night mode holds, the server's cycle = the loop's) |
| `tests/net/test_room_run.gd` | A real Run in a room against the scripted server: the first placement starts the run there (s, d, speed) with 3 s protection (no hits, then hits reported), about 20 states a second one per tick and consistent with their ticks, remote cars drawn with nametags and strip dots, translucent within 15 m, gone after the extrapolation and fade; the crash-out reported, RESULTS without a results screen, the toast, the respawn placement starting a fresh run; REJOIN CREW teleporting and keeping the run (chain forfeit); the room clock driving the sky and night; LEAVE ROOM and a kick back to the hub; a dropped socket (driving on, the banner, the seat back, a teleport not a new run); a lost seat back to the hub |
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

**Play it** against the local server: `tools/godot.sh --path . -- --server=http://127.0.0.1:18652` (native: the title → ONLINE → a room button; start a second copy to see each other), or the web build with `?server=http://127.0.0.1:18652`.

## Snaps

```
tools/snap.sh src/run/run.tscn --renderer=both --mode=loop --at=desert --room=demo --remotes=4 --speed_kmh=150 --tag=room
tools/snap.sh src/run/run.tscn --mode=loop --at=desert --room=demo --remotes=3 --room_menu=chat --tag=room_menu     # or players
tools/snap.sh src/run/run.tscn --mode=loop --at=city --room=demo --remotes=3 --room_toast=1 --clock_min=26 --tag=room_night
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --sweep=title:rooms,rooms_off,rooms_create,rooms_code,rooms_browser,rooms_joining,rooms_failed
```

`--room=demo` (RunRoom.snap_room) drives the run in a room with no server: `--remotes=N` players around the car (the nearest within 15 m, translucent), a chat on a nametag and in the feed; `--title=rooms*` (RunRoom.snap_hub) opens the hub's room flows with a server-less rooms service.

## Deviations and open questions

- **Pause in a room** still pauses the local run (the tree): no states go up, so the others see the car fade after 250 ms; the seat is kept (the socket stays up). A room-aware pause (the car keeps driving under the menu) is left open.
- **Host settings in the room** (kick, density, time mode after creation) are wired in `NetRoomSession.send_host` but have no UI yet; the host picks density and time when creating the room (PRIVATE ROOM).
- **Invite links / party** (N9), **crew proximity and train counter** (N6) and **network traffic** (N4.3) are not here. With local traffic the room's density does not change the local director yet.
- **Presence over the room socket:** `NetSocialClient.attach_lobby(rooms.session.client)` would move presence onto this connection; not wired (the friends list keeps polling).
