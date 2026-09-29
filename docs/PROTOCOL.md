# Westbound Online: realtime protocol

The wire contract between the Godot client (`src/net/codec.gd`) and the server (`westbound-server/crates/protocol`). It implements [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Networking protocol. **Protocol version 1.** This document and `crates/protocol/src/messages.rs` freeze after N2: changes need an orchestrator decision, a `PROTOCOL_VERSION` bump and regenerated golden vectors.

## 1. Connection

- One `wss://<domain>/ws` connection per client, carrying binary WebSocket messages only.
- The first message must be `Hello`. The server answers `Welcome` or a fatal `Error` and closes (§5).
- **Keepalive:** the client sends `Ping` every 2 s (`Welcome.ping_interval_ms`). Either side treats 8 s without receiving anything (`Welcome.timeout_ms`) as a dead connection.
- **Clock sync:** `Ping.client_time_ms` is echoed in `Pong` with the room tick in progress and the fraction of that tick elapsed: `server_now = server_tick + tick_fraction / 65536`. The client keeps the 8 most recent samples, takes the offset from the lowest-RTT sample, and slews (never jumps backward).
- Only the lobby may rely on TCP ordering. Room traffic must tolerate a later UDP transport (every state carries its tick; intents carry absolute ticks).

## 2. Framing

A **frame** is one WebSocket binary message. It holds one or more messages back to back:

```
frame   = message+
message = type:u8  length:u16  payload:[length bytes]
```

- All integers are **little-endian**. Signed integers are two's complement.
- A frame is at most **16,384 bytes** (`MAX_FRAME_LEN`) in both directions and holds at most **64 messages** (`MAX_MESSAGES_PER_FRAME`). An empty frame is invalid.
- The server sends **one frame per tick per client**, bundling everything for that tick. A frame may hold several messages of the same type (for example two `TrafficSpawn` batches when one is full).
- Each payload must be consumed exactly: a payload shorter than its message is `truncated`, a longer one is `trailing_bytes`.
- **Any error rejects the whole frame.** The server answers a fatal `Error{malformed}` and closes.

### Type ids

Client → server ids are `0x01`–`0x3F`; server → client ids are `0x40`–`0x7F`. A type from the other direction is `unknown_type`.

| Id | Client → server | Id | Server → client |
| --- | --- | --- | --- |
| `0x01` | `hello` | `0x40` | `welcome` |
| `0x02` | `ping` | `0x41` | `pong` |
| `0x03` | `lobby_command` | `0x42` | `error` |
| `0x04` | `player_state` | `0x43` | `lobby_event` |
| `0x05` | `score_claim` | `0x44` | `room_snapshot` |
| `0x06` | `hit_report` | `0x45` | `player_states` |
| `0x07` | `run_event` | `0x46` | `traffic_spawn` |
| `0x08` | `quick_chat` | `0x47` | `traffic_despawn` |
| `0x09` | `room_host_command` | `0x48` | `traffic_intent` |
| | | `0x49` | `traffic_correction` |
| | | `0x4A` | `score_sync` |
| | | `0x4B` | `score_event` |
| | | `0x4C` | `run_result` |
| | | `0x4D` | `room_event` |
| | | `0x4E` | `quick_chat` (relay) |
| | | `0x4F` | `server_notice` |

## 3. Field encodings

| Notation | Bytes | Encoding |
| --- | --- | --- |
| `u8` `u16` `u32` `u64` `i16` | 1 / 2 / 4 / 8 / 2 | little-endian |
| `bool` | 1 | exactly `0` or `1`; anything else is `invalid_bool` |
| `enum` | 1 | u8 discriminant from the tables in §7; unknown values are `invalid_enum` |
| `flags` | 1 | bit 0 = first flag; unused bits must be 0 (`reserved_bits`) |
| `union` | 1 + body | u8 kind, then that kind's fields; unknown kinds are `invalid_enum` |
| `list<T>` | 1 + n·T | u8 item count, then the items; each list has a min..max count (`bad_count`) |
| `str8` / `str16` | 1 / 2 + n | byte length (u8 / u16), then UTF-8 bytes (`invalid_utf8`); per-field byte, character-count and character rules |
| `account_id` | 8 | u64, at most `2^63 − 1` (fits SQLite rowids and GDScript `int`) |
| `map_hash` | 32 | raw SHA-256 of the road-space file |

### Quantization

Physical values are converted once at the edge (`crates/protocol/src/quant.rs`, mirrored by `codec.gd`): `wire = round(value × scale)` with **round half away from zero** (Rust `f64::round`, GDScript `round()`), then the range rule. Non-finite values are always rejected.

| Field | Wire | Scale | Valid wire range | Out of range |
| --- | --- | --- | --- | --- |
| Tick | u32 | 20 Hz room ticks since room start | 0..=4,294,967,295 | — |
| `s` (along the loop) | u32 | 1 mm | 0..=4,294,967,295 (4,294 km) | **reject**: wrap into [0, L) first |
| `d` (lateral, + = left) | i16 | 1 cm | ±10,000 (±100 m) | clamp |
| Speed | u16 | 1 cm/s | 0..=20,000 (200 m/s) | clamp |
| Heading vs road | i16 | 1e-4 rad | ±31,416 (±π) | wrap by whole turns beyond ±3.14165, then clamp |
| Lateral velocity | i16 | 1 cm/s | ±32,767 (±327.67 m/s) | clamp |
| Yaw rate | i16 | 1 mrad/s | ±32,767 (±32.767 rad/s) | clamp |
| Steer | i16 | 1e-4 | ±10,000 (±1.0) | clamp |
| Clearance | u16 | 1 mm | 0..=65,535 (65.535 m) | clamp |
| Multiplier | u32 | 1e-3 (1.0× = 1000) | 0..=4,294,967,295 | clamp |
| Durations | u16 / u32 | 1 ms | full range | — |
| Car / player ids | u16 | per room | full range | — |

The decoder enforces the "valid wire range" column (`out_of_range`), so `i16::MIN` is rejected for the symmetric fields. The d, speed and heading bounds are protocol sanity limits, not tuning; plausibility against a car's real limits is the server's job.

### Strings

| Type | Prefix | Max bytes | Characters | Allowed |
| --- | --- | --- | --- | --- |
| `display_name` | u8 | 64 | 1–16 | no control characters, no zero-width or bidi controls (U+200B–U+200F, U+202A–U+202E, U+2066–U+2069, U+FEFF). The server applies its 3-character minimum and profanity filter |
| `crew_tag` | u8 | 16 | 0–4 (empty = no crew) | as `display_name` |
| `code` (room and party) | u8 | 6 | exactly 6 | `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no 0/O, 1/I/L) |
| `access_token` | **u16** | 2048 | 0–2048 | printable ASCII, no spaces |
| `text` (server detail, notice) | u8 | 255 | 0–255 | no control characters except `\n` |

Errors: `string_too_long` (bytes), `bad_char_count` (characters), `bad_char`.

## 4. Message catalogue

Sizes are payload bytes (add 3 for the header). Field order is wire order.

### Shared structures

**PlayerState** (22 bytes): client `player_state` and each entry of `player_states`.

| Field | Wire | Notes |
| --- | --- | --- |
| `tick` | u32 | room tick of this state (from `server_now()`) |
| `s_mm` | u32 | mm |
| `d_cm` | i16 | cm, ±10,000 |
| `heading_e4` | i16 | 1e-4 rad relative to the road, ±31,416 |
| `speed_cms` | u16 | cm/s, ≤ 20,000 |
| `lat_vel_cms` | i16 | cm/s, ±32,767 |
| `yaw_rate_mrad_s` | i16 | mrad/s, ±32,767 |
| `steer_e4` | i16 | 1e-4, ±10,000 |
| `flags` | flags | `brake`, `boost`, `headlights`, `ghost` (bits 0–3) |
| `run_state` | enum | `run_state` |

**Identity** (11 + name): `account_id` account_id, `display_name` str8, `name_tag` u16 (0–9999, the `#1234` suffix).

**RoomSettings** (8): `visibility` enum, `max_players` u8 (1–16), `density` enum, `time_mode` enum, `fixed_cycle_ms` u32 (clock position used when `time_mode` is `fixed`).

**RoomClock** (12): `cycle_ms` u32 (position in the day/night cycle at the reference tick; 0 = start of morning), `cycle_len_ms` u32 (32 min), `day_len_ms` u32 (22 min; night is the rest). The server owns the cycle shape; clients advance `cycle_ms` with `server_now()` when `time_mode` is `cycle` and hold it otherwise. Public rooms derive `cycle_ms` from UTC on the server.

**Member** (16 + name + tag): `player_id` u16, `identity` Identity, `crew_tag` str8, `crew_slot` u8 (0–15, the room's scoring crew), `flags` (`host`, `disconnected`).

**RoomCrew** (6): `crew_slot` u8 (0–15), `color` u8 (crew palette index for nametags), `session_total` u32 (combined banked score this room session).

### Client → server

| Message | Fields | Size |
| --- | --- | --- |
| `hello` | `protocol_version` u16 · `client_build` u32 · `map_hash` map_hash · `access_token` str16 | 40 + token |
| `ping` | `client_time_ms` u32 (client monotonic clock, wrapping) | 4 |
| `lobby_command` | union, see below | 1 + body |
| `player_state` | PlayerState, 20 Hz | 22 |
| `score_claim` | `claim_id` u16 (client counter, wrapping) · `tick` u32 · `kind` enum `claim_kind` · `side` enum · `cars` list 1–2 of {`car_id` u16, `clearance_mm` u16 (measured minimum hull-to-hull)} | 9 + 4n |
| `hit_report` | `tick` u32 · `target` enum `hit_target` · `car_id` u16 (0 unless traffic) · `lives_left` u8 | 8 |
| `run_event` | `kind` enum (`start`, `end`, `rejoin`) · `tick` u32 | 5 |
| `quick_chat` | `item` chat union | 1–2 |
| `room_host_command` | union, see below | 1 + body |

`lobby_command` kinds:

| Kind | Name | Body |
| --- | --- | --- |
| 0 | `party_create` | — |
| 1 | `party_invite` | `account_id` (an online friend) |
| 2 | `party_join` | `code` (also how an invite is accepted) |
| 3 | `party_leave` | — |
| 4 | `party_kick` | `account_id` (leader only) |
| 5 | `presence_subscribe` | `enabled` bool (true: snapshot now, then updates; false: stop) |
| 6 | `room_create` | RoomSettings (private rooms; the server rejects `public`) |
| 7 | `room_join_code` | `code` |
| 8 | `room_join_id` | `room_id` u32 (room browser, a friend's Join button) |
| 9 | `room_leave` | — |
| 10 | `quick_join` | — (the whole party moves together) |
| 11 | `room_browse` | — (answered by `lobby_event.room_list`) |

`room_host_command` kinds: 0 `kick` {`player_id` u16}, 1 `set_density` {`density` enum}, 2 `set_time_mode` {`time_mode` enum, `fixed_cycle_ms` u32}.

Chat item kinds: 0 `phrase` {`phrase` enum}, 1 `horn` {}, 2 `emote` {`emote` u8, 0–31}.

### Server → client

| Message | Fields | Size |
| --- | --- | --- |
| `welcome` | `protocol_version` u16 · `server_build` u32 · `account_id` · `tick_rate_hz` u8 (1–120) · `ping_interval_ms` u16 · `timeout_ms` u16 · `max_frame_bytes` u16 | 21 |
| `pong` | `client_time_ms` u32 (echo) · `server_tick` u32 (0 outside a room) · `tick_fraction` u16 (1/65536 tick) | 10 |
| `error` | `code` enum `error_code` · `fatal` bool (the server closes after a fatal error) · `detail` text | 3 + text |
| `lobby_event` | union, see below | 1 + body |
| `room_snapshot` | `room_id` u32 · `code` · `settings` RoomSettings · `tick` u32 · `clock` RoomClock (at `tick`) · `you` u16 (your player id) · `members` list 1–16 of Member · `crews` list 0–16 of RoomCrew | 39 + lists |
| `player_states` | `players` list 1–16 of {`player_id` u16, `state` PlayerState} (24 bytes each), every tick | 1 + 24n |
| `traffic_spawn` | `cars` list 1–128 of TrafficSpawnEntry (below) | 1 + 23n |
| `traffic_despawn` | `car_ids` list 1–128 of u16 | 1 + 2n |
| `traffic_intent` | `intents` list 1–64 of TrafficIntentEntry (below) | 1 + 14n |
| `traffic_correction` | `tick` u32 (shared by the batch) · `cars` list 1–128 of {`car_id` u16, `s_mm` u32, `d_cm` i16, `speed_cms` u16} | 5 + 10n |
| `score_sync` | `tick` u32 · `run_seq` u16 · `banked` u32 · `chain` u32 · `multiplier_milli` u32 · `lives` u8 · `crew_in_range` u8 (0–16) · `flags` (`banking`, `night`, `unverified`) | 21 |
| `score_event` | `tick` u32 · `player_id` u16 · `kind` enum `score_event_kind` · `points` u32 · `multiplier_gain_milli` u32 · `link` u8 (TRAIN ×n, else 0) · `sector` u8 (sector bonuses, else 0) · `ref_id` u16 (car id for trains, claim id for `claim_rejected`, else 0) | 19 |
| `run_result` | `player_id` u16 · `run_seq` u16 · `end_reason` enum · `flags` (`verified`, `leaderboard_eligible`) · `score` u32 · `duration_ms` u32 · `distance_m` u32 · `passes` `close_passes` `cuts` `threads` `trains` u16 · `max_multiplier_milli` u32 | 32 |
| `room_event` | union, see below | 1 + body |
| `quick_chat` | `player_id` u16 · `item` chat union | 3–4 |
| `server_notice` | `kind` enum (`info`, `restart`, `maintenance`) · `seconds` u16 (until the event) · `text` | 4 + text |

**TrafficSpawnEntry** (23): `car_id` u16 · `vehicle` u8 (index into the exported roster) · `color` u8 (biome palette index) · `profile` u8 (index into the exported driver profiles) · `lane` u8 (0–7, 0 = rightmost) · `s_mm` u32 · `d_cm` i16 · `speed_cms` u16 · lane-change state: `lc_phase` enum (`none`, `signaling`, `moving`), `lc_target_lane` u8 (0–7), `lc_move_start_tick` u32, `lc_duration_ms` u16 (all zero when `none`) · `flags` (`hazard`, `braking`).

**TrafficIntentEntry** (14): `car_id` u16 · `kind` enum `intent_kind` · `start_tick` u32 (blinker / effect start) · `move_start_tick` u32 (lane changes: lateral move start, ≥ 1.0 s after `start_tick`; other kinds: equal to `start_tick`) · `target_lane` u8 (0–7; lane changes only, else 0) · `duration_ms` u16 (move duration, or the effect's duration for hazard, horn and hard brake).

`lobby_event` kinds: 0 `party_state` {`code`, `leader` account_id, `members` list 1–16 of Identity} · 1 `party_left` {`reason` enum} · 2 `party_invite` {`from` Identity, `code`} · 3 `presence` {`friends` list 0–128 of {`account_id`, `status` enum, `room_id` u32 (0 = none), `joinable` bool}} · 4 `room_list` {`rooms` list 0–64 of {`room_id` u32, `players` u8 (0–16), `max_players` u8 (1–16), `density` enum, `night` bool}} · 5 `room_left` {`reason` enum}.

`room_event` kinds: 0 `join` {Member} · 1 `leave` {`player_id` u16, `reason` enum} · 2 `host_change` {`player_id` u16} · 3 `kick` {`player_id` u16} · 4 `settings` {`tick` u32, `settings` RoomSettings, `clock` RoomClock} · 5 `crew` {RoomCrew: a crew was added or its session total changed} · 6 `connection` {`player_id` u16, `connected` bool: seat held / reconnected}.

## 5. Handshake

`crates/protocol/src/handshake.rs` is a pure state machine (`AwaitingHello → Established | Closed`); the gateway feeds it decoded messages, or the raw frame when decoding failed, plus a token verifier.

Checks on `Hello`, first failure wins; every handshake error is fatal:

1. `protocol_version` below the server's supported range → `update_required` ("please update"); above it → `server_outdated` (the store build is ahead of the server deploy; retry later).
2. `client_build` below the configured minimum → `update_required`.
3. `map_hash` differs from the server's loaded map → `map_mismatch` ("please update"). Checked before authentication.
4. Empty or rejected token → `auth_failed`; banned account → `banned`.
5. Otherwise → `welcome` with the account id, tick rate (20 Hz), ping interval (2 s), timeout (8 s) and max frame size.

Any other message before `Hello` → `handshake_required`. A second `Hello`, or an undecodable frame after the handshake → `malformed`. An undecodable first frame whose first message is a `Hello` still gets the version errors from its version prefix (see §6), otherwise `malformed`.

## 6. Versioning rules

- `PROTOCOL_VERSION` (u16, currently **1**) is bumped for **any** wire change: a new message or union kind, a new enum value or flag bit, a new or reordered field, a changed scale, cap or string rule. Adding an enum value is a breaking change, because old decoders reject unknown values.
- The server accepts `MIN_SUPPORTED_PROTOCOL_VERSION ..= PROTOCOL_VERSION` (both 1 today: an exact match). Supporting two versions at once is out of scope for v1; deploy the server first, then release clients.
- **Frozen forever**, so any client and server can always say "please update" to each other:
  - the framing (`[u8 type][u16 length][payload]`, little-endian);
  - `hello` = `0x01` with `protocol_version` u16 as its first two payload bytes;
  - `welcome` = `0x40` with `protocol_version` u16 first;
  - `error` = `0x42` with the layout `code` u8, `fatal` bool, `detail` str8, and error codes 0–2 (`update_required`, `server_outdated`, `map_mismatch`).
- Every version change regenerates the golden vectors; both codecs must pass them before merge.

## 7. Enums

Wire value = position in the list (0-based). JSON uses the snake_case name.

| Enum | Values |
| --- | --- |
| `run_state` | `not_running`, `protected` (spawn/rejoin protection), `driving`, `crashed` |
| `lc_phase` | `none`, `signaling`, `moving` |
| `intent_kind` | `lane_change`, `cancel`, `hazard`, `horn`, `hard_brake` |
| `claim_kind` | `pass`, `close_pass`, `cut`, `thread` |
| `side` | `none`, `left`, `right` |
| `hit_target` | `traffic`, `barrier`, `roadside` |
| `run_event.kind` | `start`, `end`, `rejoin` |
| `phrase` | `nice_thread`, `follow_me`, `slow_down`, `regroup`, `gg`, `one_more_lap` |
| `density` | `light`, `normal`, `rush` |
| `time_mode` | `cycle`, `fixed`, `night` |
| `visibility` | `private`, `public` |
| `presence.status` | `offline`, `online`, `in_room` |
| `party_left.reason` | `left`, `kicked`, `disbanded` |
| `room_left.reason` | `left`, `kicked`, `closed`, `timed_out` |
| `room_event.leave.reason` | `left`, `timed_out` |
| `error_code` | `update_required`, `server_outdated`, `map_mismatch`, `auth_failed`, `banned`, `handshake_required`, `malformed`, `rate_limited`, `server_full`, `room_not_found`, `room_full`, `party_not_found`, `party_full`, `not_host`, `not_party_leader`, `not_in_room`, `already_in_room`, `blocked`, `not_allowed`, `internal` |
| `score_event_kind` | `train`, `sector_clean`, `sector_pace`, `sector_threads`, `sector_heat`, `claim_rejected` |
| `run_result.end_reason` | `crashed`, `quit`, `disconnected`, `room_closed` |
| `server_notice.kind` | `info`, `restart`, `maintenance` |

## 8. JSON form (golden vectors)

The JSON form is what `codec.gd` decodes into (a Dictionary) and encodes from:

- A message is an object with `"type"` (the snake_case name from §2) plus its fields by name.
- Union bodies are flattened next to a `"kind"` tag: `{"type": "lobby_command", "kind": "room_join_code", "code": "ABC234"}`.
- Nested structures (`state`, `identity`, `settings`, `clock`, `item`, list entries) are nested objects.
- Enums are snake_case strings; flag sets are objects of booleans (`"flags": {"brake": false, ...}`); `bool` is a JSON boolean.
- `account_id` is a **decimal string** (`"42"`), because JSON numbers above 2^53 lose precision in GDScript. `map_hash` is 64 lowercase hex characters. All other integers are JSON numbers.

## 9. Golden vectors

`westbound-server/crates/protocol/vectors/`:

| File | Contents |
| --- | --- |
| `c2s_<type>.json`, `s2c_<type>.json` | per message type: `direction`, `type`, `type_id`, and `vectors` of `{name, message, hex}` where `hex` is the framed message (`[type][len][payload]`). Typical values, both range edges, and every union kind |
| `frames.json` | multi-message frames: `{name, direction, messages[], hex}` |
| `invalid.json` | frames the decoder must reject: `{name, direction, hex, error}` where `error` is the kind from §10 |
| `quantization.json` | the per-field rules and `{field, physical, wire, back, error}` samples, including halves, clamps, wraps and rejections |

Totals: 87 message vectors (39 client → server, 48 server → client), 3 frames, 36 invalid frames, 69 quantization samples.

**Regenerate:** `cd westbound-server && cargo run -p protocol --bin gen_vectors`. The `golden_vectors` test fails if the committed files drift from the generator, and independently checks that every vector's bytes decode to its JSON and its JSON encodes to its bytes. The GDScript codec must do the same for every vector.

## 10. Validation and errors

The decoder never panics (property-tested with random and mutated input). Error kinds, as named in `invalid.json`:

| Kind | Meaning |
| --- | --- |
| `empty_frame` | zero-length frame |
| `frame_too_large` | over 16,384 bytes (checked before parsing) |
| `too_many_messages` | over 64 messages |
| `truncated` | a header or payload runs past its end |
| `trailing_bytes` | payload longer than its message |
| `unknown_type` | type id unknown for this direction |
| `invalid_enum` | unknown enum value or union kind |
| `invalid_bool` | bool other than 0/1 |
| `reserved_bits` | an unused flag bit is set |
| `invalid_utf8` | a string is not UTF-8 |
| `out_of_range` | an integer outside its valid range |
| `bad_count` | a list outside its min..max count |
| `string_too_long` / `bad_char_count` / `bad_char` | string rules (§3) |

The encoder validates too: `FrameBuilder` refuses invalid messages instead of writing them. Because every field maps one-to-one onto its bytes (strict bools, zero reserved bits, known enums), anything that decodes re-encodes to identical bytes.

## 11. Frame building and bandwidth

`FrameBuilder` reuses one buffer per connection: `push` validates and appends a message if it fits (nothing is written on failure, so the caller can defer the rest to the next tick) and `finish` hands out the frame. List messages stream entries straight into the frame (`player_states()`, `traffic_spawns()`, `traffic_despawns()`, `traffic_intents()`, `traffic_corrections(tick)`), so the server builds no per-tick `Vec`s; an empty batch leaves no trace, and a full one (`BatchFull`) is continued in a second message of the same type.

Budget (`crates/protocol/src/budget.rs`, pinned by tests). On-wire bytes add the WebSocket header (2 bytes up to 125, else 4; +4 mask client → server) and one TLS 1.3 record (22 bytes) per frame.

| Scenario (20 Hz) | Avg frame | Max frame | Protocol | + WS + TLS | + TCP/IP (52 B/frame) |
| --- | --- | --- | --- | --- | --- |
| Typical: 7 remote players, 40 cars in the area, 7 within 100 m at 5 Hz, 33 at 1 Hz, 1 spawn + 1 despawn + 2 intents + 1 score sync per second | 219 B | 295 B | 4,373 B/s | **4,893 B/s** | 5,933 B/s |
| Rush hour: 67 cars, 11 within 100 m, 3 spawns + 3 despawns + 5 intents + 2 score syncs per second | 247 B | 315 B | 4,947 B/s | **5,467 B/s** | 6,507 B/s |

Both stay under the 10 KB/s downstream budget. A typical tick is `player_states` 172 B (7 × 24 + 4), `traffic_correction` about 42 B (3.4 entries), plus a share of the 1 Hz and event traffic. Upstream is one 25-byte `player_state` frame per tick plus a ping every 2 s and about two claims a second: **1,099 B/s** with WebSocket and TLS framing (the spec's "about 1 KB/s").

## 12. Choices made where the spec was open

- **Batching.** All four traffic messages are lists (spec: corrections batched); a correction batch shares one `tick`, saving 4 bytes per car. `player_states` batches every other member per tick.
- **Lane-change state at spawn** is carried inline (phase, target, move-start tick, duration), so a car that appears mid-maneuver needs no extra message.
- **Hit reaction** (swerve, brake, hazards) is expressed with the existing intents (`hard_brake`, `hazard`) plus corrections; no separate kind.
- **Lobby sub-payloads** (§4) are minimal: invites are accepted by `party_join` with the invite's code; declining needs no message; presence is a subscription; the room browser is a request/response.
- **Ids.** Room ids are u32 (0 = none in presence); player and car ids are u16 per room; account ids are u64 capped at `i64::MAX`.
- **Map hash** is a 32-byte SHA-256, checked in `Hello` (before auth) rather than on each room join: one server, one map.
- **Clock sync** uses the room tick plus a 1/65536 fraction instead of wall time.
- **Protocol sanity bounds** (|d| ≤ 100 m, speed ≤ 200 m/s, heading ±π, lanes 0–7, lists and strings capped) are rejected by the decoder; real plausibility checks stay in the server.
