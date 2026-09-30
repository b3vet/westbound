# Westbound Online: client networking (`src/net/`)

WP N2.2. The Godot side of the realtime protocol: codec, transports, clock sync, and the handshake and keepalive client. It implements [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Networking protocol and Client changes → `src/net/`. The wire contract is [`PROTOCOL.md`](PROTOCOL.md), and `westbound-server/crates/protocol` is the reference implementation.

| File | Class | What it is |
| --- | --- | --- |
| `src/net/codec.gd` | `NetCodec` | Encoding and decoding of every message, framing, validation, quantization |
| `src/net/player_state.gd` | `NetPlayerState` | One PlayerState in wire units (typed ints), the 20 Hz upload |
| `src/net/server_frame.gd` | `NetServerFrame` | A decoded downstream frame: batches as structure-of-arrays |
| `src/net/transport.gd` | `NetTransport` | Transport interface: `connect_to_url`, `send`, `poll`, `close`, state |
| `src/net/ws_transport.gd` | `NetWsTransport` | WebSocket implementation (`WebSocketPeer`) |
| `src/net/loopback_link.gd`, `loopback_transport.gd` | `NetLoopbackLink`, `NetLoopbackTransport` | In-process link with latency, jitter, loss and ordering, on a virtual clock |
| `src/net/time_source.gd`, `virtual_time.gd` | `NetTimeSource`, `NetVirtualTime` | Injectable monotonic time (µs) |
| `src/net/clock.gd` | `NetClock` | Ping/Pong clock sync and `server_now()` |
| `src/net/net_client.gd` | `NetClient` | Connection: Hello → Welcome/Error, keepalive, clock, frame hand-out |
| `src/core/tuning/net_tuning.gd`, `data/tuning/net.tres` | `NetTuning` | Client numbers: URL, keepalive, clock, WebSocket buffers |

Everything is `RefCounted`, driven by `poll()`, with time injected, so all of it runs headless. A Node adapter (`room_client.gd`, later) owns a `NetClient` and polls it once per frame.

## Codec

### Two representations

- **Dictionaries mirroring the golden-vector JSON** (PROTOCOL.md §8). A message is `{"type": ..., fields...}`. Union bodies are flattened next to `"kind"`, enums are snake_case Strings and flag sets are Dictionaries of bools. Account ids are decimal Strings, because a JSON float or `str_to_var` would lose bits above 2^53 while GDScript's `int` holds the full `i64`. The map hash is 64 lowercase hex characters. `push(msg, direction)` and `decode_frame(bytes, direction)` cover every message in both directions. This path serves the lobby, the handshake, rare room messages, the fake server in tests, and the vector tests.
- **Typed hot paths without Dictionaries.**
  - **Up, 20 Hz:** `NetPlayerState` (ints) is filled with `set_physical(...)`, which quantizes, and written by `push_player_state(st)` straight into the reused frame buffer.
  - **Down, 20 Hz:** `decode_server_frame_into(bytes, sink)` decodes `player_states` and the four traffic batches into a pre-sized `NetServerFrame` (`ps_*`, `sp_*`, `ds_*`, `in_*`, `co_*` packed arrays, sized for a full 16 KB frame). Every other message in the frame lands in `sink.messages` as a Dictionary. `order_type/first/count` keep the frame's message order.

Why this split: GDScript Dictionaries cost about 1–2 µs each to build. A typical downstream tick has 11 entries plus nested flag and state objects, which comes to about 50 Dictionaries a tick. Everything that is not a 20 Hz batch is rare, and the Dictionary form keeps it compact and readable and lets tests compare it 1:1 with the vectors. Both decoders are checked against every vector, and a differential fuzz test checks that they agree on mutated frames.

### Validation and errors

The codec mirrors `frame.rs` and `wire.rs` exactly, and the vectors pin the error kinds:

- **Frame:** `empty_frame`, `frame_too_large` (over 16,384 bytes), `too_many_messages` (over 64), `truncated` (header or payload), `unknown_type` (including the other direction's ids).
- **Precedence as in Rust.** Structural errors (`truncated`, `invalid_enum`, `invalid_bool`, `reserved_bits`, `invalid_utf8`) win at the first failing byte. Then comes `trailing_bytes`. Then comes the first range, count or string rule in field order, where a list's items come before its count.
- **Strings:** strict UTF-8, as `std::str::from_utf8` (no overlongs, surrogates or code points above U+10FFFF). Then byte length, then character count, then the per-type character rules (`is_control` = Unicode Cc, zero-width and bidi controls in names, the code alphabet, printable ASCII tokens). Non-ASCII strings are rebuilt code point by code point, because Godot's UTF-8 parser drops a leading BOM, which `text` fields allow.
- **Encoder:** `push()` validates every rule and writes nothing on failure, like the Rust `FrameBuilder`. It adds four encoder-only kinds: `frame_full` (defer the message to the next frame), `missing_field`, `invalid_value` (wrong Variant type) and `out_of_range` for integers outside their wire type. Missing flags count as `false`.
- **Any error rejects the whole frame.** `NetClient` treats a bad server frame as fatal (`malformed`), as the server does.

### Quantization

`NetCodec.s_to_wire`, `d_to_wire`, `speed_to_wire`, `heading_to_wire`, `lat_vel_to_wire`, `yaw_rate_to_wire`, `steer_to_wire`, `clearance_to_wire`, `multiplier_to_wire` and the matching `*_from_wire` mirror `quant.rs`: `roundf(value × scale)` (half away from zero), then clamp. `s` rejects values outside u32, and the caller wraps `s` into [0, L) first. Heading wraps by whole turns beyond ±3.14165, then clamps to ±31,416. A value that cannot be quantized returns `QUANT_INVALID`, and `quant_error(field, value)` says why (`not_finite` or `out_of_range`).

### Performance

Measured by `tests/net/test_codec_perf.gd` (headless, dev container; budgets are about 3× these):

| Operation | µs |
| --- | --- |
| PlayerState encode into a frame + `finish_frame()` (typed path) | **1.6–1.8** |
| PlayerState quantize (`set_physical`) | 2.1 |
| PlayerState encode via Dictionary (reference) | 24 |
| Typical 20 Hz downstream frame decode: 7 players + 4 corrections, 215 B (`decode_server_frame_into`) | **12.7–13.4** |
| Busy frame: + spawn, despawn, 2 intents, score sync (the score sync is a Dictionary) | 36–41 |
| Typical frame via Dictionaries (reference) | 217–227 |

Together that is well under 1 % of a 16.7 ms frame. Decoding the hot messages allocates nothing. `finish_frame()` allocates the one `PackedByteArray` handed to the socket.

## Golden vectors

`tests/net/test_codec_vectors.gd` reads `westbound-server/crates/protocol/vectors/*.json` from disk. The server tree has a `.gdignore`, so the test uses `FileAccess` on `ProjectSettings.globalize_path("res://")`. It runs in the normal fast tier (`tools/test.sh`), so the existing Godot CI covers the "both sides run the vectors" rule. If the directory is missing, or any count differs from 87 / 39 / 48 / 3 / 36 / 69, every test fails.

What it checks:

- For every message vector, the bytes decode to the JSON, on both the Dictionary path and the fast path.
- The JSON encodes to the exact bytes (for `player_state`, also through `NetPlayerState`).
- Multi-message frames decode and encode, on both paths.
- Every invalid frame fails with its `error` kind, on both paths.
- Every quantization sample matches in wire value, back value and error kind.

Extra tests cover:

- non-finite input, 64-bit account ids, and encoder validation that writes nothing on failure;
- the 64-message and 16 KB limits, and `NetServerFrame` capacities;
- UTF-8 edge sequences;
- the differential fuzz of mutated frames: both decoders agree, there are no engine errors, and every frame that decodes re-encodes byte-identically.

Result: **all 87 message vectors, 3 frames, 36 invalid frames and 69 quantization samples pass.** No mismatch with the Rust side was found.

## Transports

`NetTransport` is `connect_to_url(url)` (named so as not to clash with `Object.connect`), `send(bytes) -> Error`, `poll() -> Array[PackedByteArray]` (reused, valid until the next poll), `close(code, reason)`, `get_state()` (`CLOSED`, `CONNECTING`, `OPEN`, `CLOSING`), `state_changed`, `close_code` and `close_reason`.

**Ordering contract.** A frame arrives whole or not at all. Nothing above the transport may assume in-order, exactly-once or guaranteed delivery, except the lobby (party and room commands and events), which may rely on the WebSocket's TCP ordering. Room traffic carries ticks (states) and absolute ticks (intents), so a later UDP transport can replace the WebSocket for room traffic.

**`NetWsTransport`** wraps `WebSocketPeer`:

- Binary frames only. A text frame closes the connection with 1003, and an inbound frame over 16 KB closes it with 1009 before it reaches the codec.
- Buffers come from tuning (`ws_inbound_buffer_kb`, `ws_outbound_buffer_kb`, `ws_max_queued_packets`).
- `send` returns `ERR_BUSY` instead of overflowing the outbound buffer. Room traffic is simply sent again next tick.
- TLS uses the platform trust store for `wss://`. Pass `TLSOptions` to the constructor to pin a CA, or `TLSOptions.client_unsafe()` for a local dev server only.

`tests/net/test_transport.gd` round-trips real codec frames through a WebSocket server running in the test process (`TCPServer` + `WebSocketPeer.accept_stream`). It also covers the 1003 close on a text frame, a client-side close and reconnect, and a refused connection.

**`NetLoopbackLink`** joins two `NetLoopbackTransport` endpoints (`link.client`, `link.server`) on a `NetTimeSource`:

- Each frame gets a one-way delay of `latency_s ± jitter_s` (uniform) and is lost with probability `loss`.
- Frames may be reordered unless `ordered` is set (TCP-like).
- `down` cuts the link, and `refuse` rejects connections.
- It is deterministic for a given `Rng` seed.
- The link owns its endpoints, which point back through weak references, so keep the link alive while the endpoints are in use.

Tests use it, and it can back a later offline mode.

## Clock sync

`NetClock` implements PROTOCOL.md §1:

- `ping_time_ms()` gives `Ping.client_time_ms` (local monotonic ms, wrapping u32) and remembers the exact send time in µs.
- `on_pong(echo, server_tick, tick_fraction)` makes one sample:
  - RTT = receive − send.
  - The server clock `tick + fraction / 65536` is assigned to the midpoint `send + RTT/2`, which gives offset = `server_ticks − local_s × tick_rate`.
  - The 8 newest samples are kept, and the lowest-RTT one is the target offset.
  - A Pong with tick 0 and fraction 0 (outside a room) is not a sample, and RTTs over `clock_max_rtt_ms` are ignored.
- Slewing:
  - The first sample sets the estimate directly.
  - After that the estimate moves toward the target with a time constant: `clock_settle_smoothing_s` (1 s) while the window fills, then `clock_smoothing_s` (30 s). The long time constant averages the jitter asymmetry of successive lowest-RTT picks.
  - The correction speed is capped at `clock_slew_max_rate` (5 % of real time), so `server_now()` never runs backward.
  - A target more than `clock_snap_forward_ms` (250 ms) ahead is jumped to. The jump is forward only.
- `server_now()` returns the fractional room tick at 20 Hz, and is also clamped to be non-decreasing.
- `reset()` is for joining another room.

**Convergence** (`tests/net/test_clock.gd`): NetClient + NetLoopbackLink + scripted server. Each direction takes 75 ± 15 ms (so RTT is 150 ± 30 ms) with 2 % loss per frame and direction, and the client pings every 2 s. Over 3 seeds, the clock is within ±5 ms after 0.2–36 s. From 60 s to 660 s, the **worst error is 3.2–3.8 ms and the mean is 0.9 ms**, and `server_now()` never goes backward. A 200 ms backward server step is absorbed without running backward, slowing by at most 5 %, and is back within ±5 ms in 180 s. A 1 s forward step is followed within one sample window.

Why smoothing matters: with the lowest-RTT sample alone, a window of 8 samples still leaves up to ±12–15 ms of asymmetric-jitter error on this link (simulated). The 30 s time constant brings that below ±5 ms. This keeps the spec's rule (offset from the lowest-RTT of 8 samples) and adds a smoother to the slew; it does not change the spec.

## NetClient: handshake and keepalive

```gdscript
var client := NetClient.new(NetWsTransport.new(tuning), tuning)   # time: Time.get_ticks_usec
client.failed.connect(func(reason, message): show_error(message))
client.start(tuning.server_url, CLIENT_BUILD, map_sha256, access_token)
# every frame:
client.poll()
if client.is_ready():
	client.send_player_state(my_state)            # 20 Hz
	var tick := client.clock.server_now()
```

- **States:** `IDLE → CONNECTING → HANDSHAKING → READY`, ending in `FAILED` (with `failure_reason` and `failure_message`) or `CLOSED` (after `close()`, which is quiet).
- **Hello** carries `protocol_version = NetCodec.PROTOCOL_VERSION`, `client_build`, the 32-byte `map_hash` and the `access_token`.
- **Welcome** sets `account_id` (a decimal String), the tick rate, the ping interval and the timeout (Welcome's values win when non-zero). The first Ping goes out at once for a quick clock sync.
- **Fatal Error:** `failed(code, message)`. `NetClient.user_message(code)` gives the player text:
  - `update_required`: "A new version of Westbound is out. Please update to play online."
  - `server_outdated`: "Westbound Online is being updated. Please try again in a few minutes."
  - `map_mismatch`: "Your map data is out of date. Please update Westbound to play online."
  - `not_allowed` (fatal: the gateway keeps the newest login per account): "This account signed in on another device." (N1.2)
  - There are also texts for `auth_failed`, `banned`, `server_full`, `rate_limited`, `connect_failed`, `handshake_timeout`, `timeout` and `closed`, plus a generic fallback.
  - `needs_update(code)` is true for the "please update" family.
- **Non-fatal Error:** `server_error` fires and the connection stays up.
- **Keepalive:** a Ping every `ping_interval_s` (2 s). The connection is dead after `dead_timeout_s` (8 s) without receiving anything (`timeout`). A socket still not open after `connect_timeout_s` fails with `connect_failed`, and no Welcome within `handshake_timeout_s` fails with `handshake_timeout`.
- **Frames after Welcome** reach `frame_received(frame: NetServerFrame)`. The frame object is reused, so consume it in the handler. Any message other than Welcome or Error before Welcome is a `protocol_error`.

`tests/net/test_net_client.gd` runs against `tests/net/fake_server.gd`, a scripted server with the crate's handshake rules on the loopback link. It covers:

- Welcome, and a full 64-bit account id
- pings every 2 s, and a minute with no timeout
- dead exactly 8 s after the last Pong; a cut link
- `update_required` (protocol and build), `server_outdated`, `map_mismatch`, `auth_failed`, `banned`
- non-fatal errors, a malformed frame, a hung server, a refused connection, a server close
- a quiet close and a reconnect
- sending, and bad `start` arguments

## Tuning (`data/tuning/net.tres`)

| Field | Default | Spec |
| --- | --- | --- |
| `server_url` | `wss://westbound.sipsakrandevu.com/ws` | MP plan (domain) |
| `ping_interval_s` / `dead_timeout_s` | 2.0 / 8.0 | Connection: ping every 2 s, dead after 8 s |
| `handshake_timeout_s` / `connect_timeout_s` | 10 / 10 | not in spec |
| `tick_rate_hz` | 20 | Server tick (until Welcome) |
| `clock_samples` | 8 | Clock sync |
| `clock_slew_max_rate` | 0.05 | not in spec (slew speed) |
| `clock_smoothing_s` / `clock_settle_smoothing_s` | 30 / 1 | not in spec (tuned by `test_clock`) |
| `clock_snap_forward_ms` | 250 | not in spec |
| `clock_max_rtt_ms` | 2000 | not in spec |
| `ws_inbound_buffer_kb` / `ws_outbound_buffer_kb` / `ws_max_queued_packets` | 64 / 64 / 256 | not in spec (16 KB max frame) |

Load with `NetTuning.load_default()` until `Tuning.net` exists (the orchestrator adds it to `data/tuning.tres`).

## Live check

`tests/net/live_ws_check.gd` is a dev tool, not part of the test tiers. It runs the client stack against a running server:

```
tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws [--duration=20]    # session: account, NetClient, clock, keepalive
tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws --raw              # one Hello, print the decoded answer
tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws/echo --echo        # echo route: bytes come back identical
```

- **Session mode** (the default):
  - Creates a device account with `POST <api>/api/v1/auth/device`, through `HTTPClient` (no dependency on `session.gd`). The API origin defaults to the socket's. `--api=URL` overrides it, and `--token=T` skips account creation.
  - Runs `NetClient` over `NetWsTransport`: `Hello` → `Welcome`, then Ping/Pong for `--duration` seconds (default 20, past the 8 s dead window).
  - Prints one line per Pong: the RTT, the Pong's server tick, `server_now()`, and `err`, which is how far `server_now()` is from the tick that Pong implies (its tick + RTT/2).
  - Passes (exit 0, last line `LIVE_SESSION ok`) when every ping interval got its Pong, the connection stayed up, and the last `err` is within ±5 ms.
- **Other options:**
  - `--map=<64 hex>` sets the map hash (default all zeros, which a dev server accepts);
  - `--build=N` sets the client build;
  - `--insecure` accepts a self-signed certificate on local `wss://`.
- **Tokens are never printed.**

**Run for N2.3.** The gateway server was built from this branch and run in dev mode (`cargo run -p server -- --config config/dev.toml`, here with `WB_SERVER__BIND=127.0.0.1:18233` and a scratch database):

```
$ tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:18233/ws --duration=20
account 1 created via POST http://127.0.0.1:18233/api/v1/auth/device (token not shown, 247 chars)
connecting ws://127.0.0.1:18233/ws (client_build 1, map 00000000...)
welcome {"account_id":"1","max_frame_bytes":16384,"ping_interval_ms":2000,"protocol_version":1,"server_build":0,"tick_rate_hz":20,"timeout_ms":8000,"type":"welcome"}
pong 1  rtt 16.62 ms  server_tick 409.615  server_now 409.782  err +0.032 ms  slew +0.000 ms
pong 2  rtt 16.90 ms  server_tick 449.775  server_now 449.928  err -0.809 ms  slew +0.000 ms
pong 3  rtt 16.08 ms  server_tick 489.702  server_now 489.922  err +2.963 ms  slew +2.922 ms
pong 4  rtt 24.11 ms  server_tick 530.020  server_now 530.344  err +4.134 ms  slew +0.000 ms
pong 5  rtt 17.04 ms  server_tick 570.026  server_now 570.209  err +0.617 ms  slew +0.000 ms
pong 6  rtt 16.75 ms  server_tick 610.358  server_now 610.536  err +0.508 ms  slew +0.000 ms
pong 7  rtt 16.77 ms  server_tick 650.692  server_now 650.868  err +0.417 ms  slew +0.000 ms
pong 8  rtt 16.74 ms  server_tick 691.024  server_now 691.199  err +0.390 ms  slew +0.000 ms
pong 9  rtt 17.43 ms  server_tick 731.356  server_now 731.545  err +0.721 ms  slew +0.000 ms
pong 10  rtt 16.92 ms  server_tick 771.355  server_now 771.536  err +0.563 ms  slew +0.000 ms
LIVE_SESSION ok account=1 pings=10 pongs=10 (expected >= 10 over 20.0 s) best_rtt_ms=16.08 clock_err_ms=+0.563 worst_err_ms=4.134
```

- The **RTT of about 16 ms on loopback** is the SceneTree frame: the headless loop polls once per 60 Hz frame, so a Pong waits up to one frame to be read.
- The **clock** agrees with every Pong within ±5 ms from the first sample, and the slew stays under 3 ms.
- **Keepalive:** 10 pings and 10 pongs over 20 s, with no timeout on either side.
- The server log shows `session established ... account=1 session=1 client_build=1` and, after the tool's `close()`, `websocket closed ... reason=ClientClosed`.

The same run against the other paths (commands in docs/SERVER.md → "Realtime gateway → Live cross-side check"):

| Scenario | `NetClient` result |
| --- | --- |
| `--token=bogus` | `LIVE_SESSION FAIL auth_failed (Sign-in failed. Please try again.)` |
| Production-mode server, map `abab…` configured, tool sends zeros | `LIVE_SESSION FAIL map_mismatch (Your map data is out of date. Please update Westbound to play online.)` |
| Same server, `--map=abab…`, then `westbound-server admin ban 2 1h` from another process (`gateway.ban_recheck_ms = 2000`) | `Welcome`, 4 pongs, then `LIVE_SESSION FAIL banned (This account can't play online.)` |
| Two tools with one token, the second 4 s later | the first: `LIVE_SESSION FAIL not_allowed`; the second: `LIVE_SESSION ok` |
| `--raw` without a token | `{"code":"auth_failed","detail":"Sign-in failed. Please try again.","fatal":true,"type":"error"}` |
| `ws://…/ws/echo --echo` | `echo matches` |

**A client-side finding.** When a fatal `Error` and the close frame arrive in the same `WebSocketPeer.poll()`, Godot goes straight to `STATE_CLOSED` with `get_available_packet_count() == 0`, so the error is lost. `NetClient` then reports `closed` instead of, say, `update_required`. The server works around this by holding its close until the client has closed, up to `gateway.fatal_close_delay_ms`. `NetClient` closes as soon as it reads a fatal error, so it sees every error. `NetWsTransport.poll()` also reads packets only in `OPEN` or `CLOSING`, which is harmless given the engine behavior.

## Accounts client (N1.2)

WP N1.2: the device account, token refresh, the profile and the account panel. It implements [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Accounts and authentication and Client changes (`session.gd`, `api.gd`, the profile and account screen), with plan **MP-D2** (device accounts only). The server side is [`SERVER.md`](SERVER.md) → Accounts API.

| File | Class | What it is |
| --- | --- | --- |
| `src/net/api.gd` | `NetApi` | HTTP client: JSON in and out, retries, 429, typed errors, bearer token, refresh-and-retry once |
| `src/net/api_result.gd` | `NetApiResult` | The typed outcome of a call (`ok`, `status`, `error`, `data`, `retry_after_s`, `banned_until`, `next_rename_at`) |
| `src/net/http_backend.gd`, `http_node.gd`, `http_response.gd` | `NetHttpBackend`, `NetHttpNode`, `NetHttpResponse` | The injectable transport: `request()` and `wait()` coroutines; the real one uses one `HTTPRequest` node per request, its timeout and `wait()` on the monotonic `NetTimeSource` (not `HTTPRequest.timeout`, which a long frame fires early) |
| `src/net/fake_accounts.gd` | `NetFakeAccounts` | An in-memory Accounts API behind the same interface (tests, the panel preview) |
| `src/net/session.gd` | `NetSession` | The session Node (autoload candidate): state machine, storage, signals, rename, delete, logout |
| `src/net/profile.gd` | `NetProfile` | `GET /me` as a typed object |
| `src/net/session_store.gd`, `file_store.gd`, `web_store.gd`, `js_bridge.gd` | `NetSessionStore`, `NetFileStore`, `NetWebStore`, `NetJsBridge` | Storage per platform |
| `src/ui/screens/profile_panel.gd` | `ProfilePanel` | The account panel (pause → SETTINGS → ACCOUNT) |
| `src/ui/screens/dev/profile_preview.tscn` | | Snap scene for the panel |

### NetApi

```gdscript
var api := NetApi.new(NetHttpNode.new(host_node), tuning, "https://westbound.sipsakrandevu.com/api/v1")
api.bearer = func() -> String: return token          # NetSession wires these two
api.refresh_access = session.refresh_for_api         # coroutine -> bool
var r: NetApiResult = await api.get_me()
```

- Routes: `create_device()`, `device_login(id, secret)`, `refresh(rt)`, `logout(rt, all)`, `get_me()`, `patch_me(name)`, `delete_account()`, or `request(method, path, body, flags)` for later routes.
- **Retries** (`api_max_retries`, 3): a network failure (no response, DNS, TLS, timeout) or a 5xx waits `api_backoff_base_s × 2^attempt` (0.5, 1, 2 s; capped at `api_backoff_max_s`, ± `api_backoff_jitter`). A 429 waits its `Retry-After` header (or `retry_after_secs`) when that is at most `api_retry_after_max_s` (30 s), otherwise the call returns `rate_limited` with `retry_after_s`. **Any other 4xx returns at once.** `logout` is one attempt (best effort).
- **Errors:** `ok` false with `error` = the server's code (`invalid_name`, `rename_cooldown`, `banned`, ...) or a client code: `network`, `server_unavailable` (5xx), `bad_response` (not JSON), `offline` (no server). `is_transient()` is true for those four plus `rate_limited`.
- **Ids:** account ids stay decimal Strings everywhere (`NetApiResult.as_id()` also turns a numeric id into its digits).
- **Auth:** calls with `AUTH` send `Authorization: Bearer <token>`. On a 401 `token_expired` (also `token_revoked` or `invalid_token`: a "log out everywhere" killed it) the API calls `refresh_access` once and repeats the call once.
- The timeout is `api_timeout_s` (10 s) per attempt. Tokens, secrets and bodies are never logged.

### NetSession

A Node (`process_mode` always, so requests finish under the pause menu). `NetSession.current` is the live one. Nothing in the single-player game waits for it: `start()` is a coroutine that nobody needs to await, every failure is a state, and nothing calls `push_error`.

```
IDLE --start()--> CONNECTING --> ONLINE | OFFLINE | BANNED | FAILED
DISABLED (no server)     SIGNED_OUT (after logout() or delete_account())
```

| Launch finds | Does | Ends |
| --- | --- | --- |
| no account | `POST /auth/device`; stores `account_id`, `device_secret` (returned once), `refresh_token`, the profile | ONLINE |
| an account | `POST /auth/refresh` (the rotated token is stored at once), then `GET /me` | ONLINE |
| refresh rejected (`token_reused`, `token_revoked`, `token_expired`, `invalid_token`, any 400/401) | `POST /auth/device/login` with the stored secret | ONLINE |
| secret refused (`invalid_credentials`) | nothing more: **the stored account is kept and never silently replaced**; the panel offers TRY AGAIN and NEW ACCOUNT (`create_new_account()`) | FAILED |
| `403 banned` | `banned(until)` | BANNED |
| no network, 5xx, a long 429 | keeps the cached profile; retries after `session_retry_s` (15 s), doubling to `session_retry_max_s` (300 s), or the 429's Retry-After | OFFLINE |
| `signed_out` flag (after `logout()`) | nothing until SIGN IN (`retry()`) | SIGNED_OUT |

- **While ONLINE:** the access token is refreshed `session_refresh_margin_s` (120 s) before it expires. A failed proactive refresh keeps the session online while the token lasts and tries again after `session_retry_s`. Renewal is single flight: concurrent 401s share one refresh (a refresh token is single use).
- **API:** `access_token()` ("" unless ONLINE; for `NetClient.start()`), `fresh_access_token()` (renews first when near expiry), `ws_url()`, `profile`, `status`, `last_error`, `storage_ok`, `rename(name)`, `delete_account()`, `logout(all_devices)`, `retry()`, `create_new_account()`.
- **Signals:** `signed_in(profile)`, `signed_out()`, `profile_changed(profile)`, `banned(until_unix)`, `status_changed(status)`.
- **Deletion** (`DELETE /account`, allowed while banned when a token is still held) clears everything stored on the device. The next launch is a first launch.
- **Logout** revokes the refresh family on the server and keeps the secret, so SIGN IN restores the same account.
- **Player texts:** `NetSession.error_text(result, now)` maps every code to a short line (≤ about 50 characters, the panel does not wrap): `rename_cooldown` → "You can rename again in N days.", `banned` → "... suspended until YYYY-MM-DD.".

**Server selection.** `NetTuning.api_base_url` (production) unless overridden for local dev:

- web: `?server=http://127.0.0.1:8080` on the page URL (a bare origin gets `/api/v1`);
- native / editor: the user argument `--server=http://127.0.0.1:8080` (Project Settings → Run → Main Run Args, or `-- --server=...` on the command line);
- `server=off` disables online features (DISABLED).

Credentials are stored **per server** (`NetSession.store_name()`): a `?server=` link can never send this device's production secret to another host.

### Storage

| Platform | Store | Where |
| --- | --- | --- |
| Web | `NetWebStore` | `localStorage["westbound.net.v1"]` (other servers: `westbound.net.v1.session_<hash>`) |
| Native | `NetFileStore` | `user://net/session.dat`, `FileAccess.open_encrypted_with_pass` (AES-256) |

- **Web:** every access goes through a small page helper that catches everything and answers with a tagged string, so Safari private mode (`QuotaExceededError` on write) or blocked storage (`SecurityError`) never throws into Godot. When a write fails the document stays in memory for this launch, `storage_ok` turns false and the panel says "Not saved on this device".
- **Native:** the key is per install: SHA-256 of a random salt made on first use (`user://net/install.salt`) plus `OS.get_unique_id()` on phones, so a copied file does not open elsewhere. Writes go to a temporary file renamed over the old one. This is obfuscation, not protection from someone holding the unlocked device: **MP-D2 replaces `NetFileStore` with the iOS Keychain and Android Keystore plugins** behind the same `NetSessionStore` interface.
- Nothing stored is ever printed.

### Profile panel

Pause → SETTINGS → **ACCOUNT** (the button sits left of DONE, and only shows when a `NetSession` exists; it reads SETTINGS while the panel is open). Apple requires account deletion to be reachable in the app; this is that path.

- **Player card:** `name` + `#tag`, the status (ONLINE in the accent; SUSPENDED and ACCOUNT ERROR hot; CONNECTING, OFFLINE, SIGNED OUT muted) and one line saying what it means.
- **Rename:** a text field (max `display_name_max_chars`), SAVE (Enter works too), and the server's answer inline in hot text; the hint line shows the rules or the cooldown. While the field has focus the run's `PlayerInput` stops reading keys (typing "P" must not unpause).
- When not signed in: TRY AGAIN (SIGN IN after logout or deletion), plus NEW ACCOUNT when the stored account was refused.
- **Link account:** SIGN IN WITH APPLE / GOOGLE, disabled, COMING SOON (MP-D2).
- **Delete account:** DELETE ACCOUNT → the warning, DELETE FOREVER and CANCEL.
- Every button and the field are at least `touch_target_px` (88) tall; buttons are `ScreenButton`s, so raw touch ids never index anything.

```
tools/snap.sh src/ui/screens/dev/profile_preview.tscn --sweep=net:online,error,confirm,offline,failed,banned,deleted
tools/snap.sh src/ui/screens/dev/profile_preview.tscn --size=2496x1320 --text_scale=1.25 --net=error
```

### Tests

| File | Covers |
| --- | --- |
| `tests/net/test_api.gd` | Parsing, ids as Strings, typed errors, network and 5xx backoff, no retry on 4xx, 429 Retry-After (header and body; long waits returned), bearer + one refresh-and-retry, and `NetHttpNode` round trips against an HTTP server in the test process |
| `tests/net/test_session.gd` | First launch, resume by refresh, reuse → device login, every rejected refresh code, a refused secret surfaced, bans (launch and mid-session), rename success and every error mapped, delete (clears storage), logout, 401 renewal, proactive refresh, single-flight renewal, offline launch (does not block, backs off, recovers), server resolution |
| `tests/net/test_session_storage.gd` | Native encrypted round trip (not plaintext, per-install key, atomic write, clear), the session resuming from the file, the web path through a mock JS bridge (round trip, per-server keys, private mode, blocked storage, garbage) |
| `tests/net/test_session_profile_panel.gd` | The panel's states, rename errors inline, delete confirm, coming soon, touch targets, key muting, and the pause menu's ACCOUNT view |

### Tuning (`data/tuning/net.tres`, N1.2 fields)

| Field | Default | Spec |
| --- | --- | --- |
| `api_base_url` | `https://westbound.sipsakrandevu.com/api/v1` | MP plan (domain) |
| `api_timeout_s` / `api_max_retries` | 10 / 3 | not in spec |
| `api_backoff_base_s` / `api_backoff_max_s` / `api_backoff_jitter` | 0.5 / 8 / 0.25 | not in spec |
| `api_retry_after_max_s` / `api_retry_after_default_s` | 30 / 5 | not in spec |
| `session_refresh_margin_s` | 120 | not in spec (token is 1 h) |
| `session_retry_s` / `session_retry_max_s` | 15 / 300 | not in spec |
| `display_name_min_chars` / `display_name_max_chars` | 3 / 16 | Display names (3–16) |

### Live session check

`tests/net/live_session_check.gd` runs the session against a running server with a throwaway store (`user://live_session_check/`): create → resume → rename (+ cooldown and invalid name) → refresh-token reuse fallback → logout + sign in → a `NetClient` Hello on `ws_url()` with the session's token → delete (and device login refused afterwards). It refuses the production host.

```sh
# the server, from a scratch directory (DB in ./dev-data), on free ports
cd westbound-server && cargo build -p server          # or CARGO_TARGET_DIR=... to build elsewhere
cp westbound-server/config/dev.toml /tmp/wb/ && cd /tmp/wb
WB_SERVER__ENV=dev WB_SERVER__BIND=127.0.0.1:18480 WB_METRICS__BIND=127.0.0.1:19490 \
    <target>/debug/westbound-server --config dev.toml &
# the check, from the repo
tools/godot.sh --headless --path . --script res://tests/net/live_session_check.gd -- http://127.0.0.1:18480 [--name="Road Runner"] [--keep]
```

**Run for N1.2** against the server with the N2.3 gateway (`westbound-server` at `2d1cb38`, dev env), 2026-09-29:

```
server http://127.0.0.1:18480/api/v1
create             ok    account 1 ChromePilot#5192
stored             ok    id, secret and refresh token in user://live_session_check
resume             ok    refresh + /me, same account ChromePilot#5192
rotation           ok    a new refresh token was stored
rename             ok    Road Runner#5192
rename again       ok    rename_cooldown: You can rename again in 30 days.
invalid name       ok    invalid_name: Use 3–16 letters, digits, spaces, _ - or .
reuse fallback     ok    token_reused -> device login, same account
logout + sign in   ok
ws hello           ok    ws://127.0.0.1:18480/ws Welcome account 1
delete             ok    204, local storage cleared
deleted on server  ok    device login -> invalid_credentials
LIVE_SESSION ok (0 failed)
```

The server logged `refresh token reuse detected; session family revoked` for the reuse step, as designed. A `SceneTree` script must `await process_frame` before its first request: the root is not in the tree during `_initialize`, and `NetHttpNode` answers "cannot connect" for a host outside the tree.

### Wiring (next)

- The orchestrator adds the autoload `NetSession` (`res://src/net/session.gd`). Until then the pause menu hides ACCOUNT, and nothing touches the network.
- Once it is an autoload, the game signs in silently at launch. The web smoke test serves no API, so run it with `?server=off` or accept the failed request, or point it at a local server.
- `NetClient.start(session.ws_url(), build, map_hash, await session.fresh_access_token())`; `test_session.gd::test_access_token_plugs_into_net_client` checks that the Hello carries the session's token, and that a fatal `not_allowed` (a newer login elsewhere) shows "This account signed in on another device."

## Runs and leaderboards client (N7.2)

WP N7.2: single-player run submission, the offline queue, the one-time legacy upload, the leaderboard reads, and report / block from a board entry. Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Leaderboards, Client changes → Leaderboards screen, Rooms → Moderation. Server side: [`SERVER.md`](SERVER.md) → Leaderboards & runs API, Social API. The screens are in [`SCREENS.md`](SCREENS.md) → Leaderboards (N7.2).

| File | Class | What it is |
| --- | --- | --- |
| `src/net/runs_client.gd` | `NetRunsClient` | Node under the session: listens to `Events.run_over`, queues and submits runs, the legacy upload, owns a `NetBoards` |
| `src/net/run_payload.gd` | `NetRunPayload` | The `POST /runs` body from the `run_over` results; UUIDs, UTC dates, the Daily date |
| `src/net/run_submission.gd` | `NetRunSubmission` | One run on its way: state (QUEUED, SENDING, DONE, REJECTED, FAILED, EXPIRED), why it waits, the receipt |
| `src/net/boards_client.gd` | `NetBoards` | `GET /boards/{board}` with a short cache, single flight per page; `POST /reports`, `POST /blocks` |
| `src/net/board_page.gd` | `NetBoardPage` (+ `Entry`) | A board read as typed data (entries, `me`, markers, crew rows) |
| `src/net/fake_boards.gd` | `NetFakeBoards` | `NetFakeAccounts` plus the boards, runs, replay upload, reports and blocks routes (tests, the preview) |
| `src/net/replay_recorder.gd` | `NetReplayRecorder` | N8.1: records Journey / Daily runs (a child of `NetRunsClient`); see Replays |
| `src/net/replay_file.gd` | `NetReplayFile` | N8.1: the `.wbr` format ([`REPLAY_FORMAT.md`](REPLAY_FORMAT.md)) |

### Wiring

- **The game's client.** `NetRunsClient.ensure()` attaches one to the game's session (the `Net` autoload, `auto_start`) the first time a screen needs it (the results screen's `_ready`, the pause menu). It is a child of the session (`/root/Net/RunsClient`), lives for the whole launch and listens to `Events.run_over` from then on. No session (native dev runs without `--server=`, `?server=off`): no client, no online line, no LEADERBOARDS button.
- **Tests and previews** configure their own: `NetRunsClient.new().configure(session, store, tuning, clock)`, then bind it (`ResultsScreen.bind_runs()`, `PauseScreen.runs`, `LeaderboardsScreen.bind()`). Hooks: `unix_clock`, `local_bests`, `car_of`.
- **Needs from the orchestrator (optional):** an autoload would make the client exist before any screen does; today the results screen creates it when the run scene loads, which is before any `run_over`.

### Submission

On `run_over` a **Journey or Daily Drive** run is submitted (`NetRunPayload.eligible`): Loop practice and any other mode stay local, and so does a scoreless crash at the start (score 0 and less than `runs_min_distance_m`), which could place on no board and would spend the 30-per-hour limit.

1. A `NetRunSubmission` with a fresh UUID v4 idempotency key.
2. The body is stored in the queue (its own document next to the session's: `user://net/runs[_<server hash>].dat`, or `localStorage["westbound.net.v1.runs…"]`) **before** anything is sent, so a closed app keeps the run.
3. While the session is online the queue is sent in order, one request at a time (`POST /runs`, bearer).

| Answer | Then |
| --- | --- |
| 201, or 200 `duplicate: true` | The receipt goes on the submission (run id, verification, `verifying`, `replay_required`, placements); the run leaves the queue. `rejected` + `build_unsupported` is UPDATE REQUIRED |
| network, 5xx, 429 | Stays queued **with the same key**. Next try after `runs_retry_s` (20 s), doubling to `runs_retry_max_s` (600 s), or the 429's Retry-After when longer. NetApi's own retries (3, backoff; a 429 up to 30 s) come first |
| 401 / not signed in / `banned` | Stays queued: the run is fine, the session is not. Coming back online (the session's `status_changed`) sends at once |
| any other 4xx (`invalid_body`, 413, 415) | Dropped: the server will never take it (FAILED) |

- A queued run remembers the account that played it: another account's runs wait for that account; a run queued before the first sign-in (no account yet) goes with the first account.
- A run past the server's date window (the end of its UTC day + `runs_date_late_s`, 6 h) is dropped without a request (EXPIRED). The queue keeps at most `runs_queue_max` (50) runs.
- `replay_required` / `verification: pending` shows as VERIFYING; the replay goes up after the receipt (Replays, below).

**Payload mapping** (`NetRunPayload.build`; docs/RUN.md → `run_over`):

| Body field | From |
| --- | --- |
| `idempotency_key` | UUID v4 (`Crypto.generate_random_bytes`), one per run, kept through retries |
| `mode` | `mode` (`journey` / `daily`) |
| `seed` | `seed` as a decimal String (`String.num_int64`; 63-bit seeds lose nothing) |
| `date` | Journey: the UTC date when `run_over` fired. Daily: the date whose `Rng.daily_seed` equals the seed (today or yesterday: a run that crosses midnight), else today |
| `car` | `car` in the payload when run.gd adds it; until then the `PlayerCar` node's `CarDef.id` (`falcon_gt`), cleaned to `a–z 0–9 _ -` |
| `client_build` | `NetTuning.client_build` (u32; bump per release) |
| `score`, `legs_completed`, `best_chain`, `passes`, `close_passes`, `threads`, `cuts`, `hits` | the same keys, JSON integers (re-typed after the queue's JSON round trip) |
| `distance_m`, `duration_s`, `best_multiplier`, `top_speed_kmh`, `night_time_s`, `journey_time_s`, `journey_distance_m` | the same keys (≥ 0; a non-finite value goes as 0) |
| `coast_reached`, `journey_complete` | the same keys |
| — | `personal_best`, `new_best`, `previous_best` and any other key are left out (the server refuses unknown fields) |

### Legacy upload

Once per account, the first time it is online: `POST /runs/legacy` with the local Journey best (`Save.best_score("journey")`). The save keeps no longest distance and Daily bests have no date (the server refuses them), so Journey is the only entry; with no best there is nothing to send. Accepted, `already_uploaded`, `over_cap` or any non-transient refusal marks it done for that account (in the queue's document); a network failure tries again at the next connection.

### Replays (N8.1)

Spec: multiplayer handoff → Leaderboards (single-player runs, step 3). The format and the verifier: [`REPLAY_FORMAT.md`](REPLAY_FORMAT.md); the server: [`SERVER.md`](SERVER.md) → Replays and verification.

- **Recording.** `configure()` gives the client a `NetReplayRecorder` child (`/root/Net/RunsClient/ReplayRecorder`). It attaches to each Journey and Daily run on `Events.run_started` and records it (30 Hz path and inputs, exact boost edges and discontinuities, the event log, a traffic fingerprint a second). No online session, no client, no recording.
- **Stored with the run.** At `run_over` the client finishes the recording (`finish(results, date)`: the header gets the claims and the submission's date) and stores the bytes in their own document, `replay_<key>` (base64 in the encrypted `user://net/replay_<key>.dat`, or `localStorage["westbound.net.v1.replay_<key>"]`), before anything is sent; the queued run gets `replay: true`. At most `replay_keep_max` (10) replays wait on the device (the oldest go); an expired or dropped run takes its replay with it. `NetRunSubmission.replay_state` says where it is: `stored`, `queued`, `uploading`, `uploaded`, `not_needed`, `refused`.
- **The receipt decides.** `replay_required` on a `pending` run: an upload (key, run id, account) joins the `uploads` list in the queue document. Otherwise the replay is deleted (`not_needed`).
- **Upload.** After the runs, in the same pass, one at a time: `POST /runs/{run_id}/replay` with the file (`NetApi.request` with a `PackedByteArray` body: `application/octet-stream`, `HTTPRequest.request_raw`, which the web export supports), the receipt's run id patched into the header (`NetReplayFile.patch_run_id`). Another account's upload waits for that account.

| Answer | Then |
| --- | --- |
| 201, or 200 `duplicate: true` | Uploaded: the local copy is deleted (`uploaded`) |
| network, 5xx, 429, 401 / not signed in / banned | Kept (`queued`), on the runs' retry schedule (`runs_retry_s` doubling to `runs_retry_max_s`, or Retry-After) |
| any other 4xx (`replay_not_required`, `not_owner`, `body_too_large`, `invalid_replay`, `replay_mismatch`) | Dropped and deleted (`refused`) |

### Leaderboards (`NetBoards`)

- `fetch(board, period, view, force)`: `GET /boards/{board}?period=&view=&limit=` (`limit` = `boards_global_limit` 100 for `global`, `boards_around_me_limit` 10 for `around_me`, none for `friends`). `period` is `current` (the season, the week, today), `all`, or a date on Daily Drive.
- `global` works signed out (the token, when there is one, adds `me`); `around_me` and `friends` need the session online and answer `not_signed_in` without a request.
- Pages are cached for `boards_cache_s` (30 s; the server caches 60 s); failures are not cached. One request per page is out at a time. Pull to refresh forces a read at most every `boards_refresh_min_s`.
- `report(account_id, reason, board, period, run_id)`: `POST /reports` with `reason` `cheating` or `offensive_name` and `context {"source": "leaderboard", board, period, run_id}`. `block(account_id)`: `POST /blocks`, then the cached friends views are dropped (the friendship goes with the block). Both answer through `action_done`.

### Tuning (`data/tuning/net.tres`, N7.2 fields)

| Field | Default | Spec |
| --- | --- | --- |
| `client_build` | 1 | the u32 build of `POST /runs` and `Hello` |
| `runs_retry_s` / `runs_retry_max_s` | 20 / 600 | not in spec |
| `runs_queue_max` | 50 | not in spec |
| `runs_date_late_s` | 21600 | the server's `runs.date_late_secs` |
| `runs_min_distance_m` | 500 | not in spec |
| `replay_sample_ticks` | 4 | the spec's 30 Hz at the 120 Hz tick |
| `replay_fingerprint_ticks` | 120 | not in spec (the traffic fingerprint, once a second) |
| `replay_reserve_s` | 900 | not in spec (the recorder's first allocation) |
| `replay_max_bytes` | 4194304 | the server's `replays.max_bytes` |
| `replay_keep_max` | 10 | not in spec |
| `verify_*` | see REPLAY_FORMAT.md → Verification | the verifier's thresholds: `verify_score_pct` 3 (the spec), `verify_limit_factor` 1.2 |
| `boards_global_limit` / `boards_around_me_limit` | 100 / 10 | views: global top 100, around me |
| `boards_cache_s` / `boards_refresh_min_s` | 30 / 3 | not in spec |
| `boards_daily_days_back` | 14 | not in spec |
| `boards_row_px`, `boards_tab_width_px`, `boards_back_width_px`, `boards_option_min_px`, `boards_title_px`, `boards_row_font_px`, `boards_chip_font_px`, `boards_pull_refresh_px`, `boards_tap_slop_px`, `boards_fling_decay`, `boards_reveal_s` | see the file | the screen (not in spec) |

### Live check

`tests/net/live_boards_check.tscn` runs three throwaway device accounts (memory stores) against a running server: renames, the legacy upload (and a second one: `already_uploaded`), a friendship and a crew, a Journey run each through `Events.run_over`, a Daily run on today's seed, a duplicate, a run queued while the network is down and sent later with its key, optionally an unsupported build, every view of the Journey board and the other boards, report and block. It is a scene (it needs the autoloads) and refuses the production host.

```sh
# the server (dev env: no secrets), from a scratch directory, on free ports; N7.2 used westbound-server at 10907bd
CARGO_TARGET_DIR=$SCRATCH/target cargo build -p server             # in westbound-server/
cp westbound-server/config/dev.toml $SCRATCH/run/ && cd $SCRATCH/run
WB_SERVER__ENV=dev WB_SERVER__BIND=127.0.0.1:18480 WB_METRICS__BIND=127.0.0.1:19490 \
    WB_RUNS__SUPPORTED_BUILDS=1 $SCRATCH/target/debug/westbound-server --config dev.toml &
# the check, from the repo (--unsupported-build needs WB_RUNS__SUPPORTED_BUILDS without it)
tools/godot.sh --headless --path . res://tests/net/live_boards_check.tscn -- http://127.0.0.1:18480 --unsupported-build=7
# the screens on the same server: the game's own Net session and NetRunsClient.ensure()
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --server=http://127.0.0.1:18480 --screen=results --tag=live_results
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --server=http://127.0.0.1:18480 --from=results --view=global --tag=live_global
```

**Run for N7.2** (2026-09-29, fresh database):

```
server http://127.0.0.1:18480/api/v1
account 1          ok    Road Runner#1295
account 2          ok    Şahin 34#0386
account 3          ok    Night Owl#5336
legacy upload      ok    journey 77000 as a legacy entry
legacy once        ok    a second upload: already_uploaded
friends            ok    Road Runner#1295 + Şahin 34#0386
crew               ok    NR created
run 1              ok    run 2 pending: #1 THIS WEEK  ·  #1 ALL TIME  #1 DISTANCE NEW PB
run 2              ok    run 3 pending: #1 THIS WEEK  ·  #1 ALL TIME  #2 DISTANCE NEW PB
run 3              ok    run 4 pending: #3 THIS WEEK  ·  #3 ALL TIME  #3 DISTANCE NEW PB
daily run          ok    run 5 pending: #1 TODAY  #2 DISTANCE NEW PB
duplicate          ok    200 duplicate: true, run 2
offline queued     ok    OFFLINE — WILL SUBMIT, key 96a191b7...
offline sent       ok    same key, run 6 pending: #3 THIS WEEK  ·  #3 ALL TIME  #3 DISTANCE NEW PB
unsupported build  ok    UPDATE REQUIRED: build_unsupported
journey global     ok    2026-W40: #1 Şahin 34#0386 240,600 VERIFYING, #2 Road Runner#1295 [NR] 183,200 VERIFYING, #3 Night Owl#5336 122,900 VERIFYING
journey around_me  ok    2026-W40: #1 Şahin 34#0386 240,600 VERIFYING, #2 Road Runner#1295 [NR] 183,200 VERIFYING, #3 Night Owl#5336 122,900 VERIFYING
journey friends    ok    2026-W40: #1 Şahin 34#0386 240,600 VERIFYING, #2 Road Runner#1295 [NR] 183,200 VERIFYING
journey all time   ok    3 entries, legacy marker replaced by a better run
daily              ok    2026-09-29: 1 entries
distance           ok    all: 3 entries
loop               ok    2026-09: 0 entries
loop_crew          ok    2026-09: 0 entries
report             ok    201 report 1
block              ok    Night Owl#5336 blocked
LIVE_BOARDS ok (0 failed)
```

Every first run is a personal best on some all-time board, so the server asks for its replay and shows it as VERIFYING (`pending`) until N8 verifies it. The preview's live snaps then added a fourth (the preview's own `Net` account): its results read `#1 THIS WEEK · #1 ALL TIME / #4 DISTANCE`, and the Journey board showed the four drivers with the player's row highlighted and Road Runner's `NR` crew tag. The snap run's account files (`user://net/session_<hash>.dat`, `runs_<hash>.dat`) are per server; delete them after.

| `tests/net/test_social_client.gd` | Every call's route and JSON; request errors (unknown and blocked read the same, self, caps, duplicates) and 429 mapping; accept / decline / cancel / remove; blocks; presence by polling (interval, watch on/off, 429 back-off) and over a WebSocket (`tests/net/fake_server.gd` on the loopback link: subscribe after Welcome, snapshot and updates, no polling while live, unknown friend → list refresh, `internal` and a dead link → polling, detach unsubscribes, resubscribe after reconnect); crew create / join / member actions / disband / leave with errors; the standing; the role table; reports and their rate limit; offline and signed-out safety; an account change clearing the lists; friend-code validation |
| `tests/ui/test_social_screens.gd`, `tests/ui/test_social_text_fit.gd` | The screens (docs/SCREENS.md → Social) |

## Social client (N9.2)

WP N9.2: friends, requests, blocks, presence, crews, the crew's Loop season standing and reports, and their screens. It implements [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Rooms, parties and matchmaking (Friends and presence, Crews (persistent)), Moderation → Report and Client changes (friends list, crew page). The server side is [`SERVER.md`](SERVER.md) → Social API; the screens are [`SCREENS.md`](SCREENS.md) → Social.

| File | Class | What it is |
| --- | --- | --- |
| `src/net/social_client.gd` | `NetSocialClient` | Every Social API call over `NetApi`, the cached lists, presence (WebSocket and polling), player texts |
| `src/net/social_player.gd` | `NetSocialPlayer` | A friend / request / blocked player / crew member, with presence |
| `src/net/social_crew.gd` | `NetCrew` | A crew (`GET /crews/mine`) and the role table (`allowed_actions`) |
| `src/net/fake_social.gd` | `NetFakeSocial` | `NetFakeAccounts` plus an in-memory Social API (tests, the snap preview) |
| `tests/net/live_social_check.gd` | | Two accounts against a running server (below) |

### NetSocialClient

```gdscript
var social := NetSocialClient.of(NetSession.current)   # one per session; null without one
social.friends_changed.connect(redraw)                 # also presence_changed(id), blocks_changed, crew_changed, standing_changed
var r: NetApiResult = await social.send_request("LoneWolf#0007")
if not r.ok: note.text = NetSocialClient.error_text(r)
```

| Call | Route | Body |
| --- | --- | --- |
| `refresh_friends()` | `GET /friends` | (single flight; a call during a refresh runs it once more) |
| `send_request(code)` | `POST /friends/requests` | `{"full_name": "name#1234"}` (trimmed; a malformed code fails locally with `invalid_full_name`) |
| `accept(request_id)` / `decline(request_id)` / `cancel_request(request_id)` | `POST /friends/requests/{id}/accept` / `/decline` | none |
| `remove_friend(account_id)` | `DELETE /friends/{account_id}` | |
| `refresh_blocks()` / `block(id)` / `unblock(id)` | `GET /blocks` / `POST /blocks` / `DELETE /blocks/{id}` | `{"account_id": "42"}` |
| `refresh_presence()` | `GET /presence` | |
| `refresh_crew()` / `get_crew(id)` | `GET /crews/mine` (`not_in_crew` = no crew) / `GET /crews/{id}` | |
| `create_crew(name, tag)` | `POST /crews` | `{"name", "tag"}` (trimmed, tag upper case; lengths checked locally) |
| `join_crew(code)` | `POST /crews/join` | `{"invite_code"}` (spaces and dashes dropped, upper case) |
| `leave_crew()`, `disband()`, `rotate_invite_code()` | `POST /crews/{id}/leave`, `DELETE /crews/{id}`, `POST /crews/{id}/invite-code` | |
| `kick` / `promote` / `demote` / `transfer(account_id)` | `POST /crews/{id}/kick` ... | `{"account_id"}` |
| `refresh_standing()` | `GET /boards/loop_crew?view=around_me&limit=1` | `me` → `standing_rank` / `standing_score` / `standing_period` |
| `report(target, reason, context)` | `POST /reports` | `{"target_account_id", "reason", "context"}` (context left out when empty; reasons: `REPORT_REASONS`, the server's six) |

- **Offline-safe.** Without a server every call returns `offline`, without a signed-in session `not_signed_in`, both without a request; failures are values, never errors. A different account on the session clears the cached lists.
- **Errors.** `error_text(r)` maps every Social API code to a short line (`player_not_found` → "No player with that code.", the same when a block stands either way; the caps; the crew name / tag filter and rule codes; `not_permitted` → "Your role can't do that."), a 429 to "Too many tries. Try again in 10 min." (`error_text(r, true)`: "Report limit reached. Try again in 24 h."), and the rest to `NetSession.error_text`. `NetApi` itself retries a 429 whose Retry-After is at most 30 s.
- **Reports.** A 429 is remembered: `report_wait_s()` counts down to the Retry-After, and the dialog keeps SEND off until then.
- **Join seam (N5).** `NetSocialClient.join_handler: Callable` (`func(friend: NetSocialPlayer)`). The friends list shows JOIN for a friend `in_room` and `joinable`, disabled (SOON) until it is set.

### Presence

Both sources merge the same way: later entries replace earlier ones (`apply_presence`), the list re-sorts (in a room, online, offline; by name), and an entry for someone not on the list (a request just accepted elsewhere) refreshes the list on the next `poll()`.

- **WebSocket.** `attach_lobby(client: NetClient)` sends `lobby_command.presence_subscribe {enabled: true}` whenever that client is READY (at once, and again after every Welcome, so a reconnect resubscribes), and applies every `lobby_event.presence` (the snapshot, then single updates; `room_id` 0 = none). `detach_lobby()` sends `enabled: false`. The gateway's non-fatal `internal` (it could not read the friends) and a lost socket drop back to polling at once. **N5's always-on lobby connection plugs in with one `attach_lobby` call**; the game has no connection outside rooms yet, so today presence comes from polling.
- **Polling.** While a screen watches (`watch(true)`: the friends list while it is visible) and no subscription is live, `poll()` (every frame from the panel) calls `GET /presence` every `social_presence_poll_s` (15 s); a 429 waits its Retry-After. Hidden screen: no polls.

### On-screen keyboards

`SocialField` (the friend code, crew name, tag and invite code, and now the rename field): native iOS / Android open the OS keyboard from `LineEdit` (`virtual_keyboard_enabled`). The web export has `html/experimental_virtual_keyboard=false`, so `DisplayServer` has no virtual keyboard there; and even with it on, Godot focuses its hidden input a frame after the tap, outside the gesture, which iOS Safari ignores. So on a touch-screen web page (`NetTuning.web_text_prompt`) a tap on the field opens the browser's `window.prompt` (through `NetJsBridge`; always shows the keyboard, including iOS Safari) and fills the field; SEND / CREATE / JOIN then work as usual. Desktop web and native type in place. While a field has focus the run's `PlayerInput` reads no keys. COPY uses `navigator.clipboard` (with an `execCommand('copy')` fallback) inside the tap on the web, `DisplayServer.clipboard_set` natively; SHARE shows only where `navigator.share` exists (mobile browsers). Native share sheets need a plugin (not in v1).

### Tuning (`data/tuning/net.tres`, N9.2 fields)

| Field | Default | Spec |
| --- | --- | --- |
| `social_presence_poll_s` | 15 | not in spec |
| `friend_code_max_chars` | 21 | name (16) + `#` + 4 digits |
| `crew_name_min_chars` / `crew_name_max_chars` | 3 / 24 | SERVER.md → Crews |
| `crew_tag_min_chars` / `crew_tag_max_chars` | 2 / 4 | Crews: a 2–4 character tag |
| `crew_code_min_chars` / `crew_code_max_chars` | 6 / 16 | the server's `crew_invite_code_len` range |
| `crew_board_around` | 1 | not in spec (the standing's `limit`) |
| `social_note_s` | 3 | not in spec ("Code copied." note) |
| `web_text_prompt` | true | not in spec |

### Tests

| File | Covers |
| --- | --- |
| `tests/net/test_runs_client.gd` | The body from the real `RunStats.results` has exactly the documented keys (integers as integers, the seed's digits, the date, car, build, UUID); the receipt; Daily's date across midnight; Loop and scoreless crashes not sent; the offline queue across a relaunch with the same key; a network failure then a duplicate answer; 429 Retry-After; `build_unsupported`; refused and expired runs dropped; another account's run kept; the legacy upload once (and `already_uploaded`, network failure, nothing to send). N8.1: the replay uploaded after a receipt that asks (binary, the run id patched in, deleted after), deleted when not needed, kept through an offline relaunch, kept and retried through 503s, dropped on a 409, the oldest dropped past `replay_keep_max` |
| `tests/net/test_replay_recorder.gd` | N8.1: the format and the recorder on a real Run (REPLAY_FORMAT.md → Tests) |
| `tests/net/test_boards_client.gd` | The path of every board × period × view; parsing (markers, `me`, crew rows); signed out; cache, force and single flight; report and block bodies |
| `tests/ui/test_leaderboards_screen.gd` | The screens (SCREENS.md → Leaderboards → Tests) |

### Live check

`tests/net/live_social_check.gd` runs two throwaway device accounts (memory stores) against a running server; it refuses the production host.

```sh
# the server (dev env), from a scratch directory, on free ports
WB_SERVER__ENV=dev WB_SERVER__BIND=127.0.0.1:18592 WB_METRICS__BIND=127.0.0.1:19592 \
    <target>/debug/westbound-server --config dev.toml &
tools/godot.sh --headless --path . --script res://tests/net/live_social_check.gd -- http://127.0.0.1:18592 [--keep]
```

**Run for N9.2** against `westbound-server` at `5ba93fe` (N9.1 social server), dev env, 2026-09-29:

```
server http://127.0.0.1:18592/api/v1
accounts             ok    A WildMirage#2741, B DesertRover#8919
request              ok    A -> DesertRover#8919: pending
incoming             ok    B sees WildMirage#2741
accept               ok    friends both ways
unknown code         ok    No player with that code.
ws subscribe         ok    snapshot: B offline
ws online            ok    A saw B come online (2 presence events)
poll presence        ok    B's GET /presence: A online
ws offline           ok    A saw B go offline
create crew          ok    Live Crew 6759 [L59] code QSCY4SXT
second crew refused  ok    You're already in a crew.
bad invite code      ok    That invite code doesn't work.
join crew            ok    B is a member of Live Crew 6759
member can't kick    ok    Your role can't do that.
promote + demote     ok
rotate code          ok    QSCY4SXT -> KW89P24S
crew tag on a board  ok    journey/all: WildMirage#2741 [L59]
season standing      ok    loop_crew 2026-09: not on the board yet
report               ok    report 1
block                ok    A's request now reads: No player with that code.
unblock              ok
leave crew           ok
delete               ok    both accounts deleted
LIVE_SOCIAL ok (0 failed)
```

- A's WebSocket subscription got the snapshot (B offline: an HTTP-only account has no gateway session), then B's `online` when B's gateway session started, then `offline` when B closed it; the server logged `session established ... account=2` and `websocket closed ... reason=ClientClosed`.
- The crew tag reached a board through A's legacy Journey best (`POST /runs/legacy`); Loop crew entries need multiplayer runs (N6), so the standing reads "not on the board yet".
- The server logged `crew created account_id=1 crew_id=1` and `player reported report_id=1 reason="other"`.
