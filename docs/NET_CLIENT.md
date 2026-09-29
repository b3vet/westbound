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

`tests/net/live_ws_check.gd` connects `NetWsTransport` to a running server:

```
tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws           # Hello → prints Welcome or Error
tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws --echo    # echo endpoint: bytes come back identical
```

Add `--token=...` for a real token, or `--insecure` for a local `wss://` with a self-signed certificate. It exits 0 on success.

**Run for N2.2**, against the N0 server merged into the integration branch (`dc1cc17`), built and run locally with `cargo run -p server -- --config config/dev.toml` from `westbound-server/`:

```
$ tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws --echo
sent 32 bytes: 04160040e201004e61bc0051ff6903201bd6ff76001efb02020204004d000000
received 32 bytes: 04160040e201004e61bc0051ff6903201bd6ff76001efb02020204004d000000
echo matches
```

That frame is a PlayerState + Ping, the first two messages of the `client_tick` golden frame. The Hello mode needs the handshake wired into the gateway (N0's `/ws` only echoes, so it answers a Hello with the same client frame, which a client decoder reports as `unknown_type`). The in-process WebSocket round trip in `test_transport.gd` covers the same client code in CI.
