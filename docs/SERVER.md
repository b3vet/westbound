# Westbound server runbook

`westbound-server` is the Westbound Online backend: one Rust binary with the HTTP API, the WebSocket gateway and SQLite. Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md). Plan: [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md). Deployment follows MP-D1: a Docker image built by GitHub Actions, pushed to GHCR and run by Coolify, whose proxy terminates TLS.

As of N0 the server has:

- the health route;
- a WebSocket echo on `/ws`, with the spec's limits;
- config, logging and metrics;
- SQLite with migrations and nightly backups;
- the deep-link files;
- graceful shutdown.

N1.1 adds device accounts (MP-D2: no Apple / Google yet):

- tokens with refresh rotation;
- profiles with display names and a profanity filter;
- account deletion and bans;
- rate limits;
- the `admin` CLI.

See "Accounts API".

N2.3 puts the realtime protocol on `/ws` (the echo moves to `/ws/echo`):

- the `Hello` → `Welcome` / `Error` handshake with the access token, versions, map hashes and bans;
- one session per account (a second login replaces the first);
- per-connection rate limits on every message type;
- `Pong` with a server-wide 20 Hz tick clock;
- live bans that drop open sockets.

See "Realtime gateway".

N7.1 adds the leaderboards:

- five boards (Loop, Loop crew, Journey, Daily Drive, Distance) with their periods, and the global, around-me and friends views;
- single-player run submissions with plausibility checks and the replay trigger;
- the one-time legacy personal-best upload;
- the hooks N6 (multiplayer runs) and N8 (replay verdicts) call;
- admin removal of runs and entries.

See "Leaderboards & runs API".

N8.1 adds replay verification (see "Replays and verification"):

- the replay upload `POST /api/v1/runs/{run_id}/replay` (owner only, only when the receipt said `replay_required`, size-capped, idempotent);
- the verification queue in `replays`: one verifier process at a time, with a timeout, retries and restart recovery; with no verifier configured (today's production) jobs wait and runs stay "verifying";
- retention: replays are deleted after their verdict unless the run is in a current top 100;
- `verify-worker` (the queue alone, for a sidecar) and `admin replays` / `admin replay-requeue`.

N9.1 adds the account-level social layer:

- friends with `name#1234` requests, a friends cap and blocking;
- presence over HTTP and the WebSocket (`presence_subscribe`), from the session registry, with the room seam for N5;
- persistent crews (tag, roles, invite codes, caps) with crew tags on the boards and Loop crew sums kept current;
- reports with a daily per-account limit, and the admin commands for reports and crews;
- the friends leaderboard view, and the social part of account deletion.

See "Social API".

N5.1 adds rooms and players behind the gateway (see "Rooms"):

- one tokio task per room at 20 Hz with a bounded command queue, one outbound frame per tick per client;
- private rooms with codes and host rules (kick, density, time mode, host passing, close 60 s after empty), public rooms (normal density, UTC clock) with Quick Join and the browser list;
- the `PlayerState` relay with plausibility checks (offences counted, run unverified, no kicks);
- server placements: spawn behind the crew leader or at the start gantry, crash-out respawn after 3 s, rejoin crew, 3 s protection, a free-gap seam for traffic;
- reconnect with a 15 s seat hold, the room clock (UTC-derived, fixed, night) in snapshots and `Pong`, presence `in_room`;
- the `bots` crate's scripted room clients, the integration tests and the 20 × 8 bench.

N4.1 adds the server's traffic simulation in the pure `sim` crate (not wired into rooms yet; N4.2 does that):

- a port of the client's traffic model (IDM, MOBIL, no-ambush, `TrafficSim` with lane drops and weaving racers), bit-exact against the GDScript model on exported vectors and tick-identical on whole-sim traces;
- the server's rules: every player as a participant, extrapolated to the current tick, the loop's wrap-around, a 1.0 s minimum signal for every profile with intents known when the blinker comes on, ramps and density upkeep (light / normal / rush), road works, hits;
- `TrafficWorld`, one room's traffic behind one call per 20 Hz tick.

See "Traffic simulation (N4.1)".

| Path | What |
| --- | --- |
| `westbound-server/crates/server/` | The binary (`westbound-server`) and its library, with integration tests in `tests/` |
| `westbound-server/migrations/` | sqlx migrations (SQLite) |
| `westbound-server/.sqlx/` | Offline query metadata for the `sqlx::query!` macros (committed) |
| `westbound-server/config/` | `server.example.toml` (every key with its default), `dev.toml`, deep-link placeholders |
| `westbound-server/data/profanity.txt` | The display-name word list (compiled into the binary; format in the file) |
| `westbound-server/Dockerfile`, `docker-compose.yml`, `deploy/` | Image, compose file (Coolify and local), local TLS (`Caddyfile`, `local-tls.sh`) |
| `.github/workflows/server.yml` | CI: fmt, clippy, tests, image build, GHCR push |
| `tools/net_echo_check.gd`, `tools/web_smoke/ws_echo.mjs` | Echo checks from Godot and from Chromium (point them at `/ws/echo`) |
| `tests/net/live_ws_check.gd` | Godot's `NetClient` against a running server: account, `Hello` → `Welcome`, clock sync, keepalive (see "Realtime gateway → Live cross-side check") |
| `tools/server_data/export_daily_seed_vectors.gd` | Exports `Rng.daily_seed` vectors to `crates/server/tests/data/daily_seed_vectors.json` for the Rust port's parity test |
| `westbound-server/crates/sim/src/traffic/`, `src/rng.rs`, `src/trace_hash.rs` | The traffic simulation (N4.1): see "Traffic simulation (N4.1)" |
| `westbound-server/crates/sim/data/traffic_params.json` | Traffic parameters **exported from the Godot tuning** (never edit by hand), compiled in |
| `westbound-server/crates/sim/data/mp_traffic.json` | The server-only traffic rules (densities, signal floor, capacity, ramps), compiled in |
| `westbound-server/crates/sim/vectors/` | Parity vectors from the GDScript models (exported) |
| `tools/server_data/export_sim_data.gd` | Writes `traffic_params.json` and the parity vectors (`--check` compares) |

## Routes

| Route | Listener | What |
| --- | --- | --- |
| `GET /api/v1/health` | public `:8080` | `{"status":"ok","version":"0.1.0","build":"<sha>","db":"ok"}`. Returns 503 with `"status":"degraded"` when the database does not answer |
| `GET /ws` | public | The realtime gateway: binary protocol frames (docs/PROTOCOL.md), `Hello` first. See "Realtime gateway". Limits: 16 KB max inbound message (close 1009), a 64-frame outbound queue (a slow client is dropped), a ping every 2 s, and a close after 8 s of silence. Past 400 connections, the upgrade gets HTTP 503 |
| `GET /ws/echo` | public | Ops echo of text and binary frames, same limits and connection cap. `gateway.echo_enabled = false` turns it off (404) |
| `GET /api/v1/echo-check` | public | A small HTML page, used to check a phone (see "Verify a phone connects"): runs the echo on `/ws/echo`, then sends a token-less `Hello` to `/ws` and shows the gateway's `Error` (`map_mismatch` or `auth_failed`) |
| `GET /.well-known/apple-app-site-association`, `GET /.well-known/assetlinks.json` | public | Deep-link files, read from `deeplinks.dir`, with built-in empty placeholders |
| `/api/v1/auth/*`, `/api/v1/me`, `/api/v1/account` | public | Accounts: see "Accounts API" |
| `GET /api/v1/boards/{board}`, `POST /api/v1/runs`, `POST /api/v1/runs/legacy` | public | Leaderboards and run submissions: see "Leaderboards & runs API" |
| `POST /api/v1/runs/{run_id}/replay` | public | The replay upload (binary body): see "Replays and verification" |
| `/api/v1/friends*`, `/api/v1/blocks*`, `/api/v1/presence`, `/api/v1/crews*`, `/api/v1/reports` | public | Friends, blocks, presence, crews, reports: see "Social API" |
| `GET /metrics` | **localhost only** `127.0.0.1:9090` | Prometheus text: `wb_ws_connections`, `wb_ws_frames_in_total` / `_out_total`, bytes, close reasons, the gateway's `wb_ws_sessions`, `wb_ws_handshakes_total{result}`, `wb_ws_messages_in_total{type}`, `wb_ws_rate_limited_total{type}`, `wb_ws_kicks_total{reason}` (see "Realtime gateway → Metrics"), `wb_http_requests_total{class}`, `wb_http_rate_limited_total`, `wb_accounts_created_total`, `wb_auth_logins_total`, `wb_auth_refreshes_total`, `wb_auth_refresh_reuse_total`, backups, `wb_build_info` |

## Local development

Rust 1.94 (`rustup`); everything runs from `westbound-server/`.

```sh
cd westbound-server
cargo run -p server -- --config config/dev.toml          # http://127.0.0.1:8080, DB in dev-data/, server.env = dev
curl http://127.0.0.1:8080/api/v1/health
cargo run -p server -- --config config/dev.toml check-config

# The merge gate (CI runs the same)
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test --workspace
```

Subcommands:

| Command | Does |
| --- | --- |
| `serve` | Runs the server. It is the default when no subcommand is given, and it applies pending migrations first unless `db.migrate_on_start = false` |
| `migrate` | Applies pending migrations and exits |
| `check-config` | Validates the config and prints the effective TOML with secrets redacted. Exits 2 on invalid config |
| `backup <path>` | Writes a consistent online copy of the live database (`VACUUM INTO`) while the server runs. Refuses an existing file |
| `healthcheck` | Probes `/api/v1/health` on the configured port on localhost. This is the image's `HEALTHCHECK` |
| `verify-worker` | Runs the replay verification queue alone against the same database (a sidecar; the server then sets `replays.worker_enabled = false`). Needs `replays.verifier_command` |
| `admin ban <id> <duration>` | Bans an account for `30m`, `12h`, `7d`, `2w`, or `perm`. See "Admin CLI" |
| `admin unban <id>` | Lifts a ban |
| `admin rename <id> <name>` | Force-renames an account |
| `admin remove-run <run_id>` | Deletes a run and its replay; the entries it held fall back to the player's next best run |
| `admin remove-entry <board> <period> <account_id>` | Deletes one leaderboard entry (crew id on `loop_crew`) |
| `admin replays` | The replay queue: jobs per status, and the failed ones with their last error |
| `admin replay-requeue [<run_id>]` | Puts every `failed` replay job (or that run's job) back to `pending` with fresh attempts |
| `admin reports [--unhandled] [--limit N]` | Lists player reports, newest first (see "Social API → Admin commands") |
| `admin report-handle <id>` | Marks a report handled |
| `admin crew-rename <crew_id> [<name>] [--tag <tag>]` | Force-renames a crew and/or changes its tag |
| `admin crew-disband <crew_id>` | Disbands a crew |

Every command reads the same config: `--config` or `WB_CONFIG`, then the `WB_*` environment variables.

### Database, migrations and sqlx offline data

- **Engine:** SQLite in WAL mode, with `synchronous=NORMAL`, foreign keys on and a busy timeout.
- **Times:** stored as unix seconds.
- **Secrets and tokens:** stored only as hashes.
- **Tables:**
  - Migration `0001` creates `accounts`, `refresh_tokens` and `admin_log`.
  - `0002` adds `accounts.token_version` and rebuilds `refresh_tokens` with its rotation state (`family`, `rotated_from`, `used_at`, `revoked_at`).
  - `0003` (N7.1) creates `runs`, `leaderboard_entries` and `replays` (see "Leaderboards & runs API → Tables").
  - `0004` (N9.1) creates `friends`, `blocks`, `crews`, `crew_members` and `reports` (see "Social API → Tables").
  - `0005` (N8.1) turns `replays` into the verification queue (see "Replays and verification → Tables").
  - The other data-model tables (`shadow_contacts`) come with their milestones.

Queries written with `sqlx::query!` are checked at compile time against `westbound-server/.sqlx/`, and CI builds with `SQLX_OFFLINE=true`. After you add or change a `query!`, or change the schema, regenerate that data:

```sh
cargo install sqlx-cli --no-default-features --features sqlite    # once
cd westbound-server
export DATABASE_URL=sqlite://target/sqlx-dev.db
sqlx database create && sqlx migrate run --source migrations
cargo sqlx prepare --workspace        # rewrites .sqlx/; commit it
```

To add a migration, run `sqlx migrate add --source migrations <name>`, or create `NNNN_name.sql` by hand. Migrations are embedded in the binary at build time.

### Local TLS (wss://) and the echo checks

`deploy/Caddyfile` runs Caddy with `tls internal` on `https://localhost:8443`. It proxies `/api/*`, `/ws` and `/.well-known/*` to the server. `deploy/local-tls.sh` starts both:

```sh
westbound-server/deploy/local-tls.sh            # Docker: builds westbound-server:local, compose --profile local-tls up
westbound-server/deploy/local-tls.sh --native   # no Docker: release binary + caddy (PATH, CADDY=, or downloaded to ~/.cache/westbound/caddy)
westbound-server/deploy/local-tls.sh down       # (add --native for the native pair)
```

Behind a TLS-intercepting proxy, the Docker build needs that proxy's CA. Pass it with `DOCKER_BUILD_ARGS="--secret id=extra_ca,src=/path/ca.crt"`.

Then check the echo from Godot, and from a browser page served on another origin (the way the web build runs):

```sh
tools/godot.sh --headless --script res://tools/net_echo_check.gd -- --url=wss://localhost:8443/ws/echo --insecure
# NET_ECHO ok wss://localhost:8443/ws/echo bytes=1024 rtt_ms=3

(cd tools/web_smoke && npm ci)    # once
node tools/web_smoke/ws_echo.mjs --server https://localhost:8443 --insecure
# WS_ECHO ok wss://localhost:8443/ws from http://127.0.0.1:41234/ rtt_ms=2 server=0.1.0 (abc1234) db=ok
```

Since N2.3 the echo lives on `/ws/echo`; `/ws` speaks the protocol. `ws_echo.mjs` still opens `<server>/ws` and `deploy/Caddyfile` only forwards the exact path `/ws`, so both need the one-line update noted in the N2.3 handoff before the Chromium echo works through local TLS again. `--insecure` accepts Caddy's self-signed certificate. It uses `TLSOptions.client_unsafe()` in Godot and `--ignore-certificate-errors` in Chromium, and exists in these dev tools only. Against the real domain, drop `--insecure`.

## Realtime gateway (`/ws`)

WP N2.3, in `crates/server/src/`: `gateway.rs` (the connection loop and the ban sweep), `sessions.rs` (the registry), `msg_limits.rs` (token buckets), `tick.rs` (the tick clock), `ws.rs` (socket plumbing shared with `/ws/echo`). Spec: multiplayer handoff → Networking protocol → Connection and "Rules for the server code". The wire contract is [`PROTOCOL.md`](PROTOCOL.md) §1 and §5; the handshake itself is the protocol crate's pure `Handshake` state machine.

### Connection lifecycle

1. **Upgrade.** Connection cap (`limits.max_connections`, HTTP 503 past it), 16 KB inbound cap (close 1009), a 64-frame outbound queue. The client IP is logged only as a keyed hash (`client=<12 hex>`).
2. **Frames.** Every binary message is decoded with the protocol crate: sizes, message counts, ranges, strings. Validation happens here, before anything reaches game logic. A frame that does not decode goes through `Handshake::on_undecodable`. Before the handshake, a `Hello` whose version prefix is readable (`peek_hello_version`) still gets `update_required` / `server_outdated`; anything else gets a fatal `malformed`. Text frames are not protocol frames (`malformed`).
3. **Handshake.** The first message must be `Hello`, within `gateway.hello_timeout_ms` (5 s; else a fatal `handshake_required`, "No Hello received in time"). Any other first message gets `handshake_required`. The checks run in the frozen PROTOCOL.md §5 order, first failure wins, every failure fatal:

   | # | Check | Error |
   | --- | --- | --- |
   | 1 | `protocol_version` below / above `1..=1` | `update_required` / `server_outdated` |
   | 2 | `client_build` below `gateway.min_client_build` | `update_required` |
   | 3 | `map_hash` not accepted (below) | `map_mismatch` |
   | 4 | `access_token` (carried in `Hello`, u16-prefixed): empty, bad signature, wrong issuer/audience, expired, account gone, or token version revoked | `auth_failed` |
   | 5 | Account banned | `banned` |

   The token is verified only when checks 1–3 pass (one primary-key read). A database error answers a fatal `internal` (close 1011). Logs name the reason (`invalid token`, `token expired`, `token revoked`, `account banned until ...`), never the token.

   > **Order note.** The N2.3 brief listed "version, auth, ban, map hash". The frozen protocol (PROTOCOL.md §5 and `handshake.rs`) checks the map hash **before** the token, so a stale client gets "please update" without a database read. The gateway follows the frozen order.

4. **Welcome.** `protocol_version`, `server_build` (the first 8 hex digits of the build sha; 0 for `dev` builds), `account_id`, `tick_rate_hz` (`gateway.tick_rate_hz`, 20), `ping_interval_ms` and `timeout_ms` (`limits.ping_interval_ms` 2000 / `limits.dead_after_ms` 8000), `max_frame_bytes` (16384). Then the session is registered (below). A `Hello` and a `Ping` in one frame get `Welcome` and `Pong` in one frame.
5. **Messages** (after `Welcome`). Each message passes its type's token bucket, then is routed:
   - `ping` → `pong` (below).
   - `lobby_command.presence_subscribe` → friends presence (N9.1; see "Social API → Presence").
   - `room_create`, `room_join_code`, `room_join_id`, `quick_join`, `room_leave`, `room_browse` → the rooms registry (N5.1; see "Rooms").
   - Party commands (`party_*`) → non-fatal `not_allowed` ("Parties are not available yet.") until N9.
   - A seated session's `player_state`, `run_event`, `hit_report`, `quick_chat` and `room_host_command` → its room task (a non-blocking `try_send` into the room's bounded queue; a full queue drops the message, `wb_room_dropped_total{reason="queue_full"}`). Outside a room: `room_host_command` and `room_leave` answer a non-fatal `not_in_room`, the rest is dropped quietly.
   - `score_claim` → dropped until N6.
   - A second `Hello`, or an undecodable frame → fatal `malformed`.
6. **Replies.** Everything one inbound frame causes goes out as one outbound frame.
7. **Fatal errors.** The gateway sends the `Error`, then waits for the client to close, up to `gateway.fatal_close_delay_ms` (1 s), and then sends a close frame (1008 with the error code as the reason; 1011 for `internal`). Without the wait, a client that reads the error and the close in the same socket read can lose the error. Godot's `WebSocketPeer` does: it goes straight to `STATE_CLOSED` with no packet available, so the player would see "connection closed" instead of "please update". `NetClient` closes as soon as it reads a fatal error, so it never waits.
8. **Keepalive.** The protocol crate's `Keepalive`: the server sends a WebSocket ping every `limits.ping_interval_ms` (keeps proxies and NATs open; clients answer on their own) and closes with 1001 after `limits.dead_after_ms` without receiving anything. Clients send protocol `Ping`s every 2 s (`Welcome.ping_interval_ms`).
9. **Shutdown.** Every socket gets close 1001 and the session is removed.

### Map hashes

`gateway.map_hashes` lists the accepted `Hello.map_hash` values, 64 hex characters each (the SHA-256 of the loop's road-space file). The handshake compares against one hash, so the gateway hands it the client's own hash when that hash is accepted, and a different one when it is not.

| `server.env` | `gateway.map_hashes` | Accepted |
| --- | --- | --- |
| `dev` | empty | any hash (`config/dev.toml`; the live check sends all zeros) |
| `production` | empty | **none**: every `Hello` gets `map_mismatch`, and a warning is logged at start |
| either | a list | exactly those |

**Built-in map (N3.2):** `loop_v1.json` is compiled into the binary; its SHA-256 (`26a4e08b8e456ec56471c7d0626ab4ed760ba7579add6e4c279e9b3faa0dd296`) is accepted automatically when `gateway.map_hashes` is empty, and logged at startup. `WB_GATEWAY__MAP_HASHES=<hash>[,<hash>]` is an explicit override (a warning is logged if it leaves the built-in hash out). To keep an old client build working during a map update, list both hashes. Until N3, the owner can try the live check against production by setting `WB_GATEWAY__MAP_HASHES=0000000000000000000000000000000000000000000000000000000000000000` (the all-zero hash the tool sends by default) and removing it again afterwards.

### Clock (`Pong`)

`Pong` = `client_time_ms` (echoed), `server_tick`, `tick_fraction` (1/65536 tick): `server_now = server_tick + tick_fraction / 65536`. Outside a room the clock is **server-wide**: `tick.rs`'s `MonotonicTickClock`, at `gateway.tick_rate_hz` (20 Hz) since process start. The tick wraps at 2^32 (6.8 years). Tests inject a `ManualTickClock` (`AppState::with_clocks`).

**Rooms (N5.1):** `gateway::pong_clock(state, room)` is the one place that picks the clock: while the session holds a seat it is **the room's tick clock** (tick 0 = the room's creation; PROTOCOL.md: the room tick), else the server-wide one. A client joining a room calls `NetClock.reset()` (the tick base changes).

### Sessions and the duplicate-login policy

`Sessions` (`sessions.rs`, in `AppState.sessions`) maps account id → `SessionHandle`: session id, account, token version, the connection's **bounded** outbound queue, and a kick signal. The lobby (N5/N9) finds a player's connection there, and presence (N9.1) reads who is online from it.

- **One session per account; the newest wins.** A second `Welcome` for the same account registers the new connection and kicks the older one with a fatal `not_allowed` ("This account signed in on another device."). The newest device wins, so a player whose old connection is half-dead (a phone that switched networks) is never locked out by it. A replaced connection's cleanup never removes its successor, because removal checks the session id.
- **Concurrency.** Each connection task owns its socket, handshake, buckets and keepalive; nothing else touches them. The only shared structure is the registry map, behind one `std::sync::Mutex`. It is held for a single insert, remove, lookup or snapshot, never across an `.await`, and only at session start and end, lobby lookups and the ban sweep, never per message. Room tasks and the lobby keep cloned handles:
  - `send_frame(bytes)` is a non-blocking `try_send` into the connection's queue. A full queue kicks that client (slow client) instead of blocking the room.
  - `kick(reason)` sets a `watch` value. It never blocks or fails, and the first kick wins. The connection task then sends the fatal error, closes and unregisters itself.

### Rate limits (per connection)

Each client → server type has a token bucket (`ws_rate_limits.<type>_per_sec`, refilled evenly, and `_burst`, available at once). A message over its limit is dropped before routing, counted, and answered with a non-fatal `rate_limited` at most every `notice_interval_ms`. Every drop also takes a token from the **violation** bucket; a client that empties it is flooding and gets a fatal `rate_limited`. `Hello` is not limited (a second one is fatal anyway).

| Type | Per second | Burst | Why |
| --- | --- | --- | --- |
| `ping` | 2 | 5 | the client pings every 2 s |
| `lobby_command` | 5 | 10 | |
| `player_state` | 25 | 40 | 20 Hz uploads plus jitter bunching |
| `score_claim` | 10 | 20 | about 2 a second, more in trains |
| `hit_report` | 5 | 10 | |
| `run_event` | 2 | 5 | |
| `quick_chat` | 1 | 3 | |
| `room_host_command` | 2 | 5 | |
| violation bucket | 5 | 100 | disconnect when empty |

### Bans

- **At `Hello`:** a banned account gets a fatal `banned`.
- **Live:** the admin CLI is a separate process that only writes the database. So `gateway::ban_sweep` runs every `gateway.ban_recheck_ms` (30 s) and does one primary-key read per live session, about 13 reads a second at 400 sessions. It kicks:
  - a banned account → fatal `banned`;
  - a deleted account, or one whose token version moved on (logout everywhere) → fatal `auth_failed` ("You were signed out. Please sign in again.").
- An access token that expires during a session does not end it. The sweep covers revocation.

### Metrics

On `/metrics` (localhost), next to the N0 connection counters:

| Metric | What |
| --- | --- |
| `wb_ws_sessions` | Live handshaken sessions (gauge) |
| `wb_ws_handshakes_total{result}` | `ok`, `update_required`, `server_outdated`, `map_mismatch`, `auth_failed`, `banned`, `handshake_required`, `malformed`, `hello_timeout`, `abandoned` (closed before an answer), `internal` |
| `wb_ws_messages_in_total{type}` | Decoded client messages by type (dropped ones included) |
| `wb_ws_rate_limited_total{type}` | Messages dropped by the rate limits |
| `wb_ws_rate_limit_closed_total` | Connections closed for flooding |
| `wb_ws_kicks_total{reason}` | `replaced`, `banned`, `revoked`, `slow_client`, `closed` |
| `wb_ws_sessions_replaced_total` | Second logins |
| `wb_ws_echo_connections_total` | `/ws/echo` connections |

### Logs

At INFO, per connection: `session established` (client hash, account, session id, client build, whether it replaced one), `handshake refused` (reason), `websocket sign-in refused` (the token failure reason), `session kicked` (reason), and `websocket closed` (route and close reason). IPs appear only as keyed hashes. Tokens never appear.

### Live cross-side check

Godot's `NetClient` (`src/net/`) against a locally running server in dev mode:

```sh
cd westbound-server
cargo run -p server -- --config config/dev.toml          # dev: any map hash, public dev secrets, 127.0.0.1:8080
# second terminal, repository root:
tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- ws://127.0.0.1:8080/ws --duration=20
```

The tool creates a device account with `POST /api/v1/auth/device`, runs `Hello` → `Welcome`, then pings for 20 s (past the 8 s dead window) and prints each clock sample. It ends with `LIVE_SESSION ok ...` and exit 0. docs/NET_CLIENT.md → "Live check" has the output and the other modes.

More live checks:

- **Error paths:** `--raw` sends one `Hello` without a token and prints the decoded `Error`; `--token=bogus` shows `NetClient` failing with `auth_failed`.
- **Map mismatch and live bans:** run a production-mode server with `WB_SERVER__ENV=production`, the two auth secrets, `WB_GATEWAY__MAP_HASHES=$(printf 'ab%.0s' {1..32})` and `WB_GATEWAY__BAN_RECHECK_MS=2000`. The tool without `--map` fails with `map_mismatch`. With `--map=abab…ab` it gets a `Welcome`, and `westbound-server admin ban <id> 1h`, run from another shell with the same environment, drops it with `banned` within 2 s.
- **Duplicate login:** two tools with the same `--token` (take it from `curl -s -X POST http://127.0.0.1:8080/api/v1/auth/device`). The first fails with `not_allowed` when the second gets its `Welcome`.

## Accounts API

N1.1 implements device accounts only (MP-D2). All routes are under `/api/v1`, take and return JSON, and are covered by CORS for the web build.

### Tokens and secrets

| Thing | Form | Lifetime | Stored as |
| --- | --- | --- | --- |
| Device secret | 32 random bytes, base64url (43 chars) | Forever (per account) | HMAC-SHA256 with the server pepper. Returned once, by `POST /auth/device` |
| Access token | JWT HS256. Claims: `sub` (account id string), `iat`, `exp`, `jti`, `ver` (token version), `iss` `westbound`, `aud` `westbound-api` | 1 h | Not stored |
| Refresh token | 32 random bytes, base64url (43 chars) | 30 days, renewed by each rotation. Single use | SHA-256 |

- **Access tokens.** Send them as `Authorization: Bearer <token>`, and in the WebSocket `Hello`.
- **Account ids.** Always decimal strings (`"42"`); see docs/PROTOCOL.md.
- **Client storage** of the device secret: the iOS Keychain, Android encrypted storage, or local storage on the web. Native builds use an encrypted `user://` file until the Keychain plugin lands (MP-D2).
- **Why HMAC and not argon2 for the device secret.**
  - The secret has 256 bits of entropy, so a slow password hash adds nothing against guessing.
  - Argon2 would cost CPU on every sign-in on a 1-vCPU budget, and hand attackers a cheap way to burn it.
  - Because the HMAC is keyed with the pepper, a leaked database alone cannot even test a guess.
  - Comparisons are constant-time.
- **Refresh tokens** are looked up by their SHA-256. A timing difference there reveals nothing usable, because nobody can choose a preimage.

**Revocation:**

- Every access token carries `ver`, which must equal `accounts.token_version`.
- "Log out everywhere" bumps it, which kills every outstanding access token at once.
- Account deletion does the same.
- Bans need no bump: every authenticated request reads `banned_until`.

### Errors

Every error is JSON:

```json
{"error": "<code>", "message": "<English text>"}
```

- Some errors add one extra field: `banned_until`, `next_rename_at` or `retry_after_secs`.
- Clients switch on `error`. `message` is for logs.
- 401s carry `WWW-Authenticate: Bearer error="invalid_token"`.
- Error responses are `Cache-Control: no-store`.

| Status | `error` | When |
| --- | --- | --- |
| 400 | `invalid_body` | Malformed JSON, missing or unknown fields, wrong types, a malformed `account_id` |
| 400 | `invalid_name` / `name_not_allowed` / `name_unchanged` | Rename: the name breaks the rules, the filter rejects it, or it is the current name |
| 401 | `unauthorized` | No `Authorization: Bearer` header |
| 401 | `invalid_token` | A bad access token, or an unknown refresh token |
| 401 | `token_expired` | Access token: refresh it. Refresh token: sign in with the device secret |
| 401 | `token_revoked` | Logged out, or the account is gone. Sign in again |
| 401 | `token_reused` | The refresh token was already used. Its whole session family is now revoked. Sign in again |
| 401 | `invalid_credentials` | Device sign-in: an unknown account or the wrong secret. The two cases are indistinguishable |
| 403 | `banned` | With `banned_until` (unix seconds; `253402300799` = permanent). Returned by sign-in, refresh and every authenticated route |
| 404 / 405 | `not_found` / `method_not_allowed` | |
| 409 | `rename_cooldown` | With `next_rename_at` |
| 409 | `name_unavailable` | All 10,000 tags of that name are taken |
| 413 | `body_too_large` | The body is over `http.max_body_bytes` (4 KB) |
| 415 | `unsupported_media_type` | The body is not `Content-Type: application/json` |
| 429 | `rate_limited` | With `retry_after_secs` and a `Retry-After` header (exposed to CORS) |
| 501 | `provider_not_enabled` | Apple / Google routes (MP-D2) |
| 500 | `internal` | Details are logged, never returned |

### Routes

**`POST /api/v1/auth/device`**

- No body. Creates an account with a generated name (e.g. `SwiftFalcon#0042`).
- Response `201`:

```json
{
  "account_id": "42",
  "access_token": "eyJ…", "token_type": "Bearer", "expires_in": 3600, "expires_at": 1790003600,
  "refresh_token": "…43 chars…", "refresh_expires_at": 1792592000,
  "device_secret": "…43 chars…",
  "profile": { …as GET /me… }
}
```

**`POST /api/v1/auth/device/login`**

- Body: `{"account_id": "42", "device_secret": "…"}`.
- Response `200`: the same session fields plus `profile`, without `device_secret`.
- Each sign-in starts a new refresh-token family: one per device session.
- This is how a reinstall that kept its secret, or a web client with its stored secret, recovers the account.
- Errors: `invalid_credentials`, `banned`.

**`POST /api/v1/auth/refresh`**

- Body: `{"refresh_token": "…"}`.
- Response `200`: the session fields (`account_id`, `access_token`, `token_type`, `expires_in`, `expires_at`, `refresh_token`, `refresh_expires_at`).
- Rotation:
  - The presented token is marked used.
  - A new one is stored with `rotated_from` = the old hash, in the same family.
  - Of two concurrent refreshes with one token, exactly one wins.
- Reuse:
  - Presenting a used token revokes the whole family (`token_reused`), so the thief and the owner are both signed out of that session.
  - The owner signs in again with the device secret.
  - A client that lost a refresh response should also do that: its next refresh gets `token_reused`.
- Banned: `403 banned`. The token is not consumed, so it works again after the ban ends.

**`POST /api/v1/auth/logout`**

- Body: `{"refresh_token": "…", "all_devices": false}`.
- Response `204`, always, even for an unknown token.
- Revokes that token's family.
- With `all_devices: true`, it revokes every refresh token of the account and bumps its token version (every access token dies).
- Access tokens of the logged-out session otherwise stay valid until they expire (at most 1 h).

**`GET /api/v1/me`** (bearer)

```json
{"account_id": "42", "display_name": "Şahin 34", "name_tag": 42, "full_name": "Şahin 34#0042",
 "created_at": 1790000000, "name_changed_at": 1790000000, "next_rename_at": 1792592000,
 "linked": {"apple": false, "google": false}}
```

`next_rename_at` is `null` when a rename is allowed now.

**`PATCH /api/v1/me`** (bearer)

- Body: `{"display_name": "New Name"}`. Returns the profile.
- The account keeps its tag when that tag is free for the new name. Otherwise it gets a random free one.
- **Display-name rules** (the part before `#`, after trimming surrounding spaces):
  - 3–16 characters.
  - Allowed: `A–Z a–z`, the Turkish letters `Ç ç Ğ ğ İ ı Ö ö Ş ş Ü ü`, digits, and the separators space, `_`, `-`, `.`. Composed characters only.
  - Starts and ends with a letter or digit, never has two separators in a row, and contains at least one letter.
  - Passes the profanity filter.
  - At most one rename per 30 days. The generated first name does not count.
  - `name#tag` is unique, case-insensitively for ASCII letters (SQLite `NOCASE`).

**`DELETE /api/v1/account`** (bearer; allowed while banned)

- Response `204`.
- In one transaction, deletes the account, its refresh tokens, its runs, its leaderboard entries and its runs' replays (the replay files go after commit).
- N9.1, in the same transaction: friendships and requests, blocks both ways, and the crew membership (see "Social API → Account deletion"). Reports are kept with the account's side nulled.
- Friends watching the account's presence see it go offline at once, and its open WebSocket session is closed (`auth_failed`) without waiting for the ban sweep.
- Still to come in `accounts::delete`: Apple token revocation (MP-D2).
- Logs `account_delete` to `admin_log` with the account id and row counts only.

**`POST /api/v1/auth/link/{apple,google}`, `POST /api/v1/auth/signin/{apple,google}`**

- Response `501 provider_not_enabled` until MP-D2.
- The `apple_sub` / `google_sub` columns are already in the schema.

### Profanity filter

`westbound-server/data/profanity.txt` is a small, curated English and Turkish list. Its format is documented in the file, and it is compiled into the binary.

**Normalization** of both the list and the name:

- lowercase;
- Turkish letters folded (`ç→c ğ→g ı/İ→i ö→o ş→s ü→u`);
- leetspeak mapped (`0→o 1→i/l 3→e 4→a 5→s 7→t 8→b 9/6→g @→a $→s !→i`);
- separators dropped;
- repeated letters tolerated (`fuuuck`).

**Entry kinds:**

- `word`: banned anywhere in the name.
- `=word`: banned only as a whole word of the name, for short words that hide inside ordinary ones. `ass` is banned in `Big Ass` and `BigAss`, but `Classic` passes.
- `!word`: an allow-list entry for Scunthorpe-style false positives (`Scunthorpe`, `Essex`, `cocktail`, `therapist`, `Nazım`, `sıkışık`).

It catches the obvious words and the usual disguises, not every insult. Moderators use `admin rename` for the rest.

### Rate limits

Rate limits use `tower_governor`. Each bucket refills evenly over its window, with the burst available at once.

| Routes | Key | Default |
| --- | --- | --- |
| `POST /auth/device` | client IP | 5 per hour, burst 5 |
| other `/auth/*` | client IP | 30 per minute, burst 10 |
| `/me`, `/account`, `/boards/*`, `/runs*`, the social routes (and later authenticated routes) | account | 120 per minute, burst 30 |
| `POST /runs`, `POST /runs/legacy` (also) | account | 30 per hour, burst 10 |
| `POST /friends/requests`, `POST /blocks`, `POST /crews`, `POST /crews/join`, `POST /reports` (also) | account | 60 per hour, burst 20 |

- **Keys:**
  - IPv6 clients are keyed by their /64.
  - The account key comes from the access token's signature alone (no database hit, expiry ignored).
  - A request without a valid token falls back to its IP key.
- **Response:** `429 rate_limited`, with `Retry-After` in whole seconds, rounded up.
- **Memory:** idle buckets are dropped every minute.
- **Logs:** IPs are never logged. The WebSocket gateway logs a keyed hash of the client IP (`client=<12 hex>`, HMAC under the pepper).

### Client IPs behind the proxy

- The TCP peer is the client, unless the peer is in `http.trusted_proxies`.
- A trusted peer is a proxy. The client is then the right-most address in `X-Forwarded-For` that is not itself a trusted proxy.
- A client that connects directly cannot choose its IP with that header.

**Coolify:**

- Coolify's proxy (Traefik or Caddy) sets `X-Forwarded-For`. It reaches the container over a Docker network in `10.0.0.0/8`, `172.16.0.0/12` or `192.168.0.0/16`.
- The container has no published port (Ports Mappings is empty). So only the proxy can connect, and the default trusted ranges are right.
- If you ever publish the port directly, set `WB_HTTP__TRUSTED_PROXIES` to the proxy's network only. Find it with `docker network inspect coolify`, for example `WB_HTTP__TRUSTED_PROXIES=10.0.1.0/24`.
- Setting it to empty makes every client share the proxy's bucket. Five device accounts per hour would then apply to everyone together.

### Admin CLI

Admin commands run inside the container against the live database, from Coolify's **Terminal** or `docker exec`. Each prints one line, exits non-zero on failure, and is logged to `admin_log` with actor `cli`.

```sh
westbound-server admin ban 42 7d           # 30m, 12h, 7d, 2w, or perm
westbound-server admin unban 42
westbound-server admin rename 42 "Road Runner"
westbound-server admin remove-run 1234              # entries fall back to the next best run
westbound-server admin remove-entry journey 2026-W40 42
```

- **`rename`:**
  - applies the name rules and the filter, but not the cooldown;
  - keeps the tag when it is free for the new name;
  - restarts the player's 30-day cooldown.
- **`remove-run` / `remove-entry`:** logged as `remove_run` (target: the run id; detail: the account and the entries rebuilt) and `remove_entry` (target: `board/period/account`). A removed entry is not rebuilt from older runs; it comes back only with a new run. The running server's cached board tops catch up within `leaderboards.cache_ttl_secs`.
- **Bans:**
  - A ban applies from the next request: HTTP routes return `403 banned`, and the WebSocket `Hello` gets `banned`.
  - Open WebSocket sessions are dropped within `gateway.ban_recheck_ms` (30 s): the gateway re-checks every live session against the database and sends a fatal `banned` (see "Realtime gateway → Bans").

### Local runs

- `config/dev.toml` sets `server.env = "dev"`, so no secrets are needed.
- The Docker image defaults to `production`. For `deploy/local-tls.sh` and `docker compose`, pass `WB_SERVER__ENV=dev`, or real `WB_AUTH__JWT_SECRET` and `WB_AUTH__DEVICE_SECRET_PEPPER` values.

## Leaderboards & runs API

WP N7.1, in `crates/server/src/`: `leaderboards/` (`mod.rs`: boards, targets, placements, the cache, the N6 and N8 hooks, admin removals; `period.rs`: period keys; `store.rs`: the SQL; `routes.rs`: `GET /boards`), `runs/` (`mod.rs`: submissions and legacy uploads; `plausibility.rs`; `daily_seed.rs`: the port of `Rng.daily_seed`; `routes.rs`), `social.rs` (the N9 seams). Spec: multiplayer handoff → "Leaderboards", "Rooms → Leaderboard eligibility", "Data model (SQLite)". Tests: `tests/runs.rs`, `tests/leaderboards.rs`.

### Boards and periods

| Board (`{board}`) | Ranks | Periods (first = default) | Written by |
| --- | --- | --- | --- |
| `loop` | Best single run in a ranked room | season `YYYY-MM`, `all` | the server (N6, `record_multiplayer_run`) |
| `loop_crew` | Sum of the crew's best 4 members' season-best Loop runs | season `YYYY-MM` | the server, when the run carries a crew (N9) |
| `journey` | Best Journey run | ISO week `YYYY-Www`, `all` | `POST /runs` (`mode: journey`), legacy uploads (`all`) |
| `daily` | Best run on the day's seed | date `YYYY-MM-DD` | `POST /runs` (`mode: daily`) |
| `distance` | Longest single-player run, in whole metres | `all` | `POST /runs` (both modes), legacy uploads |

- **Period keys** are UTC: the season is the calendar month; the week is the ISO 8601 week (Monday to Sunday, `2027-01-01` is in `2026-W53`); a period rolls over at 00:00 UTC.
- **Which period a run lands in** comes from the run's `date` (the UTC date it was played; the seed's date for Daily Drive). A run finished at 23:59 on Sunday and sent after midnight still counts for that week. Multiplayer runs use their end time.
- **Ranked rooms** (Loop): public rooms, and private rooms left on the default density and clock. A private room with a custom density or clock stores the run (`room_type = private_custom`) for personal stats only.
- **One entry per player per board and period**, holding their best run. A new run replaces it only with a strictly higher value, so a tie keeps the earlier run. A run needs a value above 0 to enter a board.
- **Ranking:** value descending, then the earlier run (`achieved_at`), then the lower id. Ranks never repeat.

### `GET /api/v1/boards/{board}?period=&view=&limit=`

- **Auth:** optional for `view=global` (a token adds `me`); required for `around_me` and `friends` (401 `unauthorized`). A token that is sent must be valid (401 `invalid_token` / `token_expired`, 403 `banned`).
- **`period`:** a key the board keeps, or left out / `current` for the board's current default period.
- **`view`:**
  - `global` (default): the top `limit` (default and max `leaderboards.global_limit_*`: 100).
  - `around_me`: `limit` ranks on each side of the caller (default 10, max 50), `2 × limit + 1` entries. At the top or bottom the window shifts so it still holds that many where the board has them. Without an entry: `entries: []`, `me: null`. On `loop_crew` the subject is the caller's crew.
  - `friends`: the caller and their accepted friends (N9.1), ranked among themselves (`rank` is the rank in that list; `me` keeps the global rank), `friends_available: true`. On `loop_crew` the friends view is empty (`friends_available: false`): crews, not players, rank there.
- **Errors:** 404 `unknown_board`; 400 `invalid_period` (not a key this board keeps), `invalid_view`, `invalid_limit`, `invalid_query` (an unknown or repeated parameter).

```json
{
  "board": "journey", "period": "2026-W40", "period_kind": "week",
  "period_start": "2026-09-28", "period_end": "2026-10-04",
  "view": "global", "total": 1234, "friends_available": false, "generated_at": 1790600000,
  "entries": [
    {"rank": 1, "account_id": "42", "crew_id": null, "display_name": "Şahin 34", "tag": 42,
     "full_name": "Şahin 34#0042", "crew_tag": "NR", "crew_name": null, "score": 183200,
     "verification": "pending", "verifying": true, "legacy": false,
     "run_id": "917", "run_date": "2026-09-29", "achieved_at": 1790640000}
  ],
  "me": { …an entry with the caller's rank, or null… }
}
```

- `period_start` / `period_end`: the period's first and last UTC date (`null` for `all`).
- `verification`: `pending` (awaiting its replay: show "verifying"), `verified`, `unverified` (plausible, needed no replay) or `legacy` (an uploaded local best: show the legacy marker, never used for rewards).
- `crew_tag`: the player's crew tag, `null` without a crew. On `loop_crew`, `crew_id`, `crew_name` and `crew_tag` are the crew's and the account fields are `null`. Crew fields are read with each request (one query, not cached), so crew changes show at once.
- `score` is points, or whole metres on `distance`.

**Cost and caching.** Every query walks the `leaderboard_rank` index `(board, period_key, score DESC, achieved_at, subject_id)`:

- The top `global_limit_max` rows and the entry count of each board and period are cached in memory. A write through the server drops that pair at once (and account deletion and renames drop all), and every pair expires after `cache_ttl_secs` (60 s): that covers the admin CLI, which runs in another process.
- A rank is 1 + a count of the entries ahead (two index ranges: higher values, and ties ahead). "Around me" walks the index outwards from the caller (keyset, no `OFFSET`).
- `tests/leaderboards.rs → performance_100k_entries` (100,000 entries on one board, release build on a busy 4-core machine): top 100 in 0.4 ms from the database and 0.03 ms from the cache; around-me in 2.5 ms at rank 50,000 and 4.3 ms at rank 100,000 (the count is linear in the rank, about 40 ns per entry ahead). Debug builds are about 4× slower. A rank is also computed for `me` on every authenticated read and for each placement of a submission.

### `POST /api/v1/runs` (bearer)

The run summary the client sends when a single-player run ends: the `Events.run_over` results (`RunStats.results`, docs/RUN.md) without `personal_best` / `new_best` / `previous_best`, plus four submission fields. Unknown fields are refused.

```json
{
  "idempotency_key": "3f0c9a7e-5b8e-4c1e-9d55-0d6c2f4e8a11",
  "mode": "daily", "seed": "2538700399935769545", "date": "2026-09-29",
  "car": "coupe", "client_build": 42,
  "score": 183200, "distance_m": 24018.4, "duration_s": 512.3,
  "legs_completed": 6, "coast_reached": false,
  "best_chain": 41200, "best_multiplier": 23.5,
  "passes": 212, "close_passes": 61, "threads": 9, "cuts": 34,
  "top_speed_kmh": 287.1, "night_time_s": 94.0, "hits": 1,
  "journey_complete": false, "journey_time_s": 0.0, "journey_distance_m": 0.0
}
```

- `idempotency_key`: 8–64 characters of `A–Z a–z 0–9 _ -`, unique per run (a UUID). A second submission with the same key answers the stored receipt with **200** and `duplicate: true`.
- `mode`: `journey` or `daily`. `seed`: a decimal string (or a JSON integer), 0..2^63−1. `date`: the UTC date the run was played (Daily: the seed's date). `car`: `a–z 0–9 _ -`, 1–32. `client_build`: the u32 build number.
- `score`, `best_chain`: at most 2^53−1. The other numbers must be finite and ≥ 0. The three `journey_*` keys may be left out.
- Malformed bodies are 400 `invalid_body`.

Response **201** (also for a rejected run):

```json
{
  "run_id": "917", "verification": "pending", "verifying": true, "reason": null,
  "replay_required": true, "duplicate": false,
  "placements": [
    {"board": "daily", "period": "2026-09-29", "score": 183200, "rank": 3,
     "improved": true, "previous_best": 150000, "on_board": true},
    {"board": "distance", "period": "all", "score": 24018, "rank": 812,
     "improved": false, "previous_best": 31000, "on_board": false}
  ]
}
```

- **`verification`:** `rejected` (a plausibility check failed; `reason` says which; stored for audit, never on a board), `pending` (a replay is required: shown as "verifying" until N8 checks it) or `unverified` (no replay needed).
- **`replay_required`:** the run improves the player's entry on some board and period and either ranks within `leaderboards.replay_top_n` (100) there, or it is a personal best: an all-time period, or the day's Daily board. (Weekly and season boards reset, so a first run there is not a personal best.) The client then uploads the replay: see "Replays and verification".
- **`placements`:** each board and period the run feeds: Journey → the week, all-time and Distance; Daily → the date and Distance. `rank` is the player's rank there after the run (the run's own rank when it improved the entry). `on_board` is false for a `pending` run while `leaderboards.show_pending = false`.

**Plausibility checks,** in this order; the first failure is the `reason`:

| `reason` | Rejected when |
| --- | --- |
| `build_unsupported` | `client_build < runs.min_build`, or `runs.supported_builds` is set and does not list it |
| `date_window` | `date` is not within [its day's start − `date_early_secs` (1 h), its end + `date_late_secs` (6 h)) of now |
| `daily_seed` | a Daily run whose `seed` is not `Rng.daily_seed` of its `date` |
| `duration` | `duration_s > max_duration_s` (6 h), or `night_time_s` / `journey_time_s` exceed it |
| `top_speed` | `top_speed_kmh > max_top_speed_kmh` (360) |
| `distance` | `distance_m > top_speed × duration × (1 + distance_slack_pct) + distance_slack_m`; `journey_distance_m > distance_m`; `legs_completed × leg_min_length_m > distance_m + distance_slack_m` |
| `score_rate` | `score × 60 / max(duration_s, min_duration_s) > max_score_per_minute` (200,000) |
| `stats` | `close_passes > passes`; `2 × threads > passes`; `coast_reached` with fewer than `legs_to_coast` legs; `journey_complete` without the coast; `hits > lives + legs_completed`; `best_multiplier` below the start or above start + the events' gains; `score` above the stats' bound (below); `best_chain` above the events' part of it |

The score bound, with the `[runs]` values that mirror `scoring.tres` and `legs.tres`: `(plain passes × 10 + close passes × 30 + threads × 50 + cuts × 15) × best_multiplier × 2 (top speed factor) × 2 (night) + 0.5 per event (rounding)`, plus `((legs_completed + 1) × 18,500 + 50,000 if the coast was reached) × 2 (night)` for the leg, objective and journey bonuses, plus `score_slack_pct` (1 %). It is a bound, not a recomputation: the replay verifier (N8) recomputes.

**Daily seed parity.** `runs/daily_seed.rs` ports `fnv1a32`, `derive_seed` and `daily_seed` from `src/core/rng.gd`. `tests/runs.rs → daily_seed_matches_gdscript_vectors` checks it against every day of 2024–2027 plus edge dates, exported from Godot. After changing `rng.gd`, re-export them:

```sh
tools/godot.sh --headless --path . --import      # once, if the project was never imported
tools/godot.sh --headless --path . --script res://tools/server_data/export_daily_seed_vectors.gd
```

### `POST /api/v1/runs/legacy` (bearer)

The one-time upload of the player's local personal bests from before online leaderboards (Game Center / Play Games are retired). Rate-limited like submissions.

```json
{"entries": [{"board": "journey", "score": 77000}, {"board": "distance", "score": 45000}]}
```

- Boards: `journey` (best score) and `distance` (longest run, metres), each at most once per request. Both go on the all-time period. Daily bests have no date and Loop is multiplayer-only. `score` is 1..2^53−1; leave out a board without a best (400 `invalid_body` otherwise).
- Each board is accepted **once per account** (`runs.legacy_board` is unique per account): later uploads answer `already_uploaded`.
- Above `leaderboards.legacy_max_journey_score` (50,000,000) / `legacy_max_distance_m` (2,000 km) an item is `over_cap`: not stored, so a fixed client may send it again.
- An accepted item is stored as a `legacy` run and written like any run (only if better than the player's entry). It shows with `legacy: true`, and a real run that beats it replaces it.

Response 200:

```json
{"results": [
  {"board": "journey", "status": "accepted", "run_id": "918",
   "placement": {"board": "journey", "period": "all", "score": 77000, "rank": 40,
                 "improved": true, "previous_best": null, "on_board": true}},
  {"board": "distance", "status": "already_uploaded", "run_id": null, "placement": null}
]}
```

### Hooks for N6, N8 and N9

- **N6, multiplayer runs:** `state.boards.record_multiplayer_run(&MultiplayerRun { account_id, map_id, room: Public | PrivateDefault | PrivateCustom, score, duration_s, distance_m, stats, car, client_build, ended_at, crew })`. It stores the run as `verified`. For a ranked room it writes Loop (the season of `ended_at`, and all-time), and with `crew: Some(CrewSnapshot { crew_id, member_ids })` the crew's Loop crew score: the sum of the best `crew_top_members` members' season entries, rewritten when it changes. It returns the run id, `ranked`, the placements and the new crew score.
- **N8, replay verdicts:** `state.boards.set_run_verification(run_id, Accepted | Rejected)`. Accepted marks the run and its entries `verified` (and writes them if `show_pending` kept them off). Rejected marks the run `rejected` (`reject_reason = replay`) and rebuilds each entry it held from the player's next best eligible run. N8.1's queue worker calls it (see "Replays and verification").
- **N9, friends and crews (done in N9.1):** `social::friend_ids` feeds the friends view (`store::of_subjects`), `social::crew_of` the crew "me". Board reads fill `crew_tag` and the crew entries' name and tag. `leaderboards::recompute_crew` rewrites a crew's current-season sum when members join, leave, are kicked or delete their account. For N6: `social::crew_snapshot(conn, account_id)` builds the `CrewSnapshot` that `record_multiplayer_run` takes.

### Tables

- `runs`: every submitted or server-recorded run, rejected ones included.
  - `mode`: `journey` | `daily` | `loop` | `legacy`.
  - `map_or_seed`: the seed (decimal) or map id.
  - `date`, `score`, `distance_m`, `duration_s`, `stats` (JSON), `car`, `build`, `room_type`.
  - `verification`, `reject_reason`, `legacy_board`, `idempotency_key`, `response` (the stored receipt), `created_at`.
  - Unique: `(account_id, idempotency_key)` and `(account_id, legacy_board)`.
- `leaderboard_entries`: `(board, period_key, subject_id)` primary key, then `account_id` (NULL on `loop_crew`), `run_id`, `score`, `achieved_at`, `verification`, `run_date`. Indexed for ranking, by account (deletion) and by run (removal, verdicts).
- `replays`: `run_id` (primary key), `file_path`, `status`, `result`, `created_at`; N8.1 adds the queue columns (see "Replays and verification → Tables").

### Configuration

`[leaderboards]`:

| Key | Default | Meaning |
| --- | --- | --- |
| `show_pending` | `true` | Pending runs (awaiting their replay) go on the boards, marked verifying. `false`: they wait until N8 verifies them |
| `global_limit_default` / `_max` | `100` / `100` | `view=global` limit |
| `around_me_default` / `_max` | `10` / `50` | `view=around_me`: ranks on each side |
| `replay_top_n` | `100` | An improving run that ranks within this needs a replay |
| `cache_ttl_secs` | `60` | Cached board tops expire after this, even without writes |
| `cache_max_boards` | `256` | Most board/period pairs cached |
| `crew_top_members` | `4` | Members summed on `loop_crew` |
| `legacy_max_journey_score` / `legacy_max_distance_m` | `50000000` / `2000000.0` | Legacy upload caps |

`[runs]` (plausibility; the scoring numbers mirror the game's tuning, keep them at or above it):

| Key | Default | Meaning |
| --- | --- | --- |
| `min_build`, `supported_builds` | `0`, `[]` | Oldest accepted build; the accepted builds (empty: all from `min_build`). Env: `WB_RUNS__SUPPORTED_BUILDS=41,42` |
| `max_score_per_minute` | `200000.0` | Score-rate cap |
| `min_duration_s` / `max_duration_s` | `10.0` / `21600.0` | Shorter runs count as this long for the rate; longer ones are refused |
| `max_top_speed_kmh` | `360.0` | Fastest car, boost and overshoot |
| `distance_slack_pct` / `distance_slack_m` | `5.0` / `200.0` | Headroom on top speed × duration |
| `leg_min_length_m`, `legs_to_coast`, `lives` | `3000.0`, `8`, `2` | Legs need distance; the coast needs 8 legs; hits ≤ lives + legs |
| `pass_points`, `close_pass_points`, `cut_points`, `thread_points` | `10`, `30`, `15`, `50` | Base points (`scoring.tres`) |
| `*_multiplier_gain`, `multiplier_start` | `1`, `3`, `1`, `5`; `1` | Multiplier gains and start |
| `speed_factor_max`, `night_factor` | `2.0`, `2.0` | Largest point factors |
| `leg_bonus_max_points`, `journey_bonus_points` | `18500.0`, `50000.0` | Bonus bound per leg; the coast's bonus (`legs.tres`) |
| `score_slack_pct` | `1.0` | Headroom on the score bound |
| `date_early_secs` / `date_late_secs` | `3600` / `21600` | The submission window around a run's date |

## Replays and verification

WP N8.1, in `crates/server/src/replays/`: `mod.rs` (the upload), `format.rs` (the `.wbr` header), `routes.rs`, `worker.rs` (the queue), `retention.rs`. Spec: multiplayer handoff → "Leaderboards" (single-player runs, steps 3–5), "Resource budget" (the verifier: one job at a time, `nice 10`, 1 GB), "Data model" (`replays`). The file format and the verifier (Godot, headless): [`REPLAY_FORMAT.md`](REPLAY_FORMAT.md). The client: [`NET_CLIENT.md`](NET_CLIENT.md) → Replays. Tests: `tests/replays.rs`, `tests/cli.rs`.

### `POST /api/v1/runs/{run_id}/replay` (bearer)

The body is the `.wbr` file itself (`Content-Type: application/octet-stream`), with the run's id in its header (the client patches it in after the receipt). Rate-limited like run submissions (`rate_limits.runs_*` on top of the account limit). The body limit is `replays.max_bytes` (4 MiB), not the JSON routes' 4 KB.

| Answer | When |
| --- | --- |
| **201** `{"run_id": "917", "status": "pending", "duplicate": false, "size_bytes": 51234}` | Stored as `<replays.dir>/917.wbr` with a `pending` job; the worker is woken |
| **200** `duplicate: true` and the job's current `status` | The run already has a replay (a retry, a lost answer): nothing is stored again, the first file stays |
| 401 `unauthorized` / `invalid_token` / ... | No or a bad bearer token |
| 404 `unknown_run` | No such run (or not a decimal id) |
| 403 `not_owner` | Another account's run |
| 409 `replay_not_required` | The run's receipt did not say `replay_required`, or its verification is no longer `pending` (rejected by plausibility, already verified) |
| 413 `body_too_large` | Over `replays.max_bytes` |
| 400 `invalid_replay` | Not a replay: magic, version, lengths, compression, mode |
| 400 `replay_mismatch` | A replay of another run: the header's run id, seed, mode, date or client build are not this run's |

The file is written to a temporary name and renamed into place under the database's write lock, so two racing uploads store one file and one row.

### The queue

`replays` is the queue, one row per uploaded replay. One worker (inside `serve` when `replays.worker_enabled` and a `verifier_command` is set; or `westbound-server verify-worker` in a sidecar) runs **one job at a time**:

1. Take the oldest `pending` job whose `not_before` has passed; mark it `running`, `attempts + 1`.
2. Run `replays.verifier_command` with its placeholders filled in: `{replay}` (the file), `{out}` (`<dir>/work/<run_id>.json`), `{run_id}`, `{seed}`, `{mode}`, `{build}`, `{claimed_score}` (the run's score), `{claimed_hits}` (the run's `stats.hits`). Standard input is closed; the output is kept for the log. Past `job_timeout_secs` (30 min) the process is killed.
3. Exit 0 with `{"accepted": true, ...}` in `{out}`, or exit 1 with `accepted: false`: the verdict. `state.boards.set_run_verification(run_id, Accepted | Rejected)`, the job becomes `done` with `verdict` and `result` (the verifier's JSON), a `replay verified` log line (run, verdict, reason, recomputed and claimed score, diff, unreported hits, violations, where traffic diverged, seconds), then retention.
4. Anything else is a failed attempt (another exit status, a missing or contradicting result, a timeout, a missing file): the job goes back to `pending` after `retry_delay_secs` (5 min), or becomes `failed` after `max_attempts` (3). A `failed` job's run stays "verifying"; `admin replays` shows why and `admin replay-requeue` retries it.

An upload wakes the worker at once; otherwise it looks every `poll_interval_secs` (30 s). On start, jobs a stopped worker left `running` go back to `pending` (the lost attempt counts). Exactly one worker may run against a database: either the in-server one or one `verify-worker`.

**No verifier configured** (`verifier_command = []`, the default and today's production): the worker is not started (the log says so once at startup), uploads are stored, jobs stay `pending` and their runs stay `pending` ("verifying") on the boards. Configure a verifier later and the backlog is verified oldest first. Do not configure one in production before the determinism audit (N8.2): today honest replays of more than a few tens of seconds of dense traffic are rejected (REPLAY_FORMAT.md → Honest replays today).

### Retention

- **After a verdict:** a `done` job's file is deleted unless its run ranks within `keep_top_n` (100) on some board and period right now; a rejected run holds no entries, so its file always goes. The row stays with `file_deleted_at`.
- **Every `cleanup_interval_secs` (1 h):** kept files are checked again (a run that fell out of every top 100 loses its file), and files in `replays.dir` and its `work/` older than an hour that no job needs are deleted (stray `.wbr`, temporary uploads, result files).
- `pending`, `running` and `failed` jobs keep their files. Deleting a run (`admin remove-run`) or an account deletes its replays and files.

### Tables

`replays` (0003, queue columns from 0005):

| Column | |
| --- | --- |
| `run_id` | primary key, the run (cascade on delete) |
| `file_path` | `<replays.dir>/<run_id>.wbr` |
| `status` | `pending`, `running`, `done`, `failed` |
| `result` | the verifier's result JSON (`done`), or `{"error": ...}` (the last failed attempt) |
| `created_at`, `size_bytes` | the upload |
| `attempts`, `not_before`, `started_at`, `finished_at` | the queue |
| `verdict` | `accepted` / `rejected` (`done`) |
| `file_deleted_at` | retention let the file go |

Index `replays_queue (status, not_before, created_at, run_id)` serves the worker's pick.

### Configuration

`[replays]` (env `WB_REPLAYS__<KEY>`; lists comma-separated):

| Key | Default | Meaning |
| --- | --- | --- |
| `dir` | `/data/replays` | Replay files (on the data volume); results go to `<dir>/work/` |
| `max_bytes` | `4194304` | Largest upload (a 6-hour run is about 2 MB; a 10-minute one about 50 KB) |
| `verifier_command` | `[]` | The verifier argv with placeholders (above). Empty: no verifier |
| `worker_enabled` | `true` | Run the worker inside `serve`; `false` when a `verify-worker` sidecar runs it |
| `job_timeout_secs` | `1800` | A verifier run is killed after this long |
| `max_attempts` / `retry_delay_secs` | `3` / `300` | Failed attempts before `failed`, and the wait between them |
| `poll_interval_secs` | `30` | The idle worker's check (uploads wake it at once) |
| `keep_top_n` | `100` | Verified replays of runs ranked within this keep their files |
| `cleanup_interval_secs` | `3600` | The retention sweep |

### Running the verifier (build parity, the 1 GB cap, Coolify)

The verifier is a headless build of the **same game build** as the client whose runs it checks (spec: build parity): `tools/verifier/verify_replay.gd` run by that build's Godot binary and pack. It checks the replay's tuning hash against its own and answers "cannot verify" (exit 3, a failed attempt, never a verdict) when they differ. With several builds accepted (`runs.supported_builds`), keep one pack per build and let the command pick it: `--main-pack /verifier/{build}.pck`.

Locally (from `westbound-server/`, with the editor binary):

```sh
WB_REPLAYS__VERIFIER_COMMAND='nice,-n,10,../tools/godot.sh,--headless,--path,..,--script,res://tools/verifier/verify_replay.gd,--,--replay={replay},--out={out},--seed={seed},--claimed-score={claimed_score},--claimed-hits={claimed_hits}' \
    cargo run -p server -- --config config/dev.toml
cargo test -p server --test replays -- --ignored end_to_end   # records a run with Godot, verifies it through a real server
```

The server image is distroless and static (no shell, no `nice`, no glibc), and a Godot export needs glibc, so the verifier cannot run inside today's image. Options for Coolify (MP-D1), none built yet:

1. **Sidecar (recommended).** A second image, `westbound-verifier:<build>`: `debian:bookworm-slim` + the Godot Linux export template + the game's `.pck` per supported build + the `westbound-server` binary. In the Coolify compose it runs `westbound-server verify-worker` on the **same `/data` volume** (SQLite in WAL mode works across containers on one host), with `mem_limit: 1g` (the cgroup `memory.max`, the spec's systemd `MemoryMax`) and `cpus: 1`, and `WB_REPLAYS__VERIFIER_COMMAND=nice,-n,10,/verifier/westbound,--headless,--main-pack,/verifier/{build}.pck,--script,res://tools/verifier/verify_replay.gd,--,--server=off,--replay={replay},--out={out},--seed={seed},--claimed-score={claimed_score},--claimed-hits={claimed_hits}`. The server gets `WB_REPLAYS__WORKER_ENABLED=false`. The cap covers only the verifier; an OOM kill is a failed attempt, retried. Board caches in the server pick up verdicts within `leaderboards.cache_ttl_secs` (60 s), as with the admin CLI.
2. **Same container.** Rebase the server image on `debian:bookworm-slim` with the template and packs, and let the in-server worker run `nice -n 10 prlimit --data=1073741824 ...`. One container to deploy, but the image grows from about 4 MB to about 100 MB, and the memory cap is either the whole container's (server and verifier together) or an rlimit (`--data`; `--as` would break Godot's address-space reservations).

Measured on this dev box: a 4-minute replay verifies in 10–20 s and peaks at about 225 MB resident, so a 10-minute run takes under a minute and the 1 GB cap leaves room.

### Tests

`tests/replays.rs`: the upload (auth, not the owner, unknown run, stored once and idempotent with no temp files left, only when the receipt asked (a lower second run, a plausibility-rejected run), header checks (garbage, truncated, run id, seed, mode, date, build), the size cap and the large default); the queue with a stand-in verifier script: an accepted verdict (run and entries `verified`, the placeholders, a top-1 replay kept), a rejected one (off the board, file deleted), a verifier that runs over (killed at the timeout, retried after the delay, then `failed` with the run still verifying), a failed attempt retried (exit status and output tail in the error), a result that contradicts the exit status, restart recovery, the real server's worker running three jobs strictly one at a time and oldest first, the no-verifier mode; retention (top N keeps, a run pushed out loses its file, orphans older than an hour); account deletion; `end_to_end_with_the_godot_verifier` (`#[ignore]`, about 15 s: needs Godot). `tests/cli.rs`: `admin replays`, `admin replay-requeue`. `tests/config.rs` keeps `server.example.toml` equal to the defaults.

## Social API

WP N9.1, in `crates/server/src/`: `social/` (`mod.rs`: the shared reads `friend_ids`, `crew_of`, `crew_snapshot`, `is_blocked`, player summaries and the account-deletion hook; `friends.rs`: requests, the friends list, blocks, presence reads; `crews.rs`: crews, roles, invite codes; `reports.rs`), `presence.rs` (the presence registry), and the gateway's `presence_subscribe` handling. Spec: multiplayer handoff → "Rooms, parties and matchmaking → Friends and presence", "Crews (persistent)", "Moderation", "Leaderboards → Loop crew", "Data model (SQLite)", "Accounts → Account deletion". Tests: `tests/social.rs` (every route and error, blocking, caps, crews, boards, deletion, reports, admin), `tests/presence.rs` (real WebSockets), `tests/cli.rs` (the admin binary).

Parties, public rooms, Quick Join, the room browser, invites and quick chat need rooms (N5) and come with N9's room work. Its hooks are here: `social::is_blocked` and `presence.set_room`.

All routes are under `/api/v1`, need `Authorization: Bearer`, and use the error format of "Accounts API → Errors". Ids are decimal strings. Every route is under the account rate limit. Social writes (`POST /friends/requests`, `/blocks`, `/crews`, `/crews/join`, `/reports`) also pass the social limit (`rate_limits.social_per_hour` 60, burst 20). A malformed id in a path answers that resource's 404.

### Friends

- **Friend codes** are `name#1234` (the `full_name` of `GET /me`). The name matches case-insensitively (ASCII), like the unique index.
- **One row per pair.** A request is pending until the other side accepts it. Asking someone who already asked you accepts their request (200).
- **Caps** (`[social]`): `max_friends` (100) accepted friends, checked on both sides when a request is sent and when it is accepted; `max_outgoing_requests` (50); `max_incoming_requests` (100).
- **Blocking is not revealed.** A block in either direction answers a request exactly like an unknown name (`404 player_not_found`, same message).

| Route | Answer | Errors |
| --- | --- | --- |
| `POST /friends/requests` `{"full_name": "name#1234"}` | `201 {"request_id", "status": "pending", "player"}`; `200` with `"status": "accepted"` when they had asked you | 400 `invalid_full_name`, `cannot_friend_self`, `invalid_body`; 404 `player_not_found` (unknown or blocked either way); 409 `already_friends`, `request_exists`, `friends_limit` (yours), `target_friends_limit`, `requests_limit` (your pending), `target_requests_limit` |
| `GET /friends` | `{"friends": [...], "incoming": [...], "outgoing": [...], "max_friends": 100}` | |
| `POST /friends/requests/{id}/accept` | `200 {"request_id", "status": "accepted", "player"}` | 404 `request_not_found` (unknown, not pending, or not addressed to you); 409 `friends_limit`, `target_friends_limit` |
| `POST /friends/requests/{id}/decline` | `204`. The recipient declines; the requester cancels | 404 `request_not_found` |
| `DELETE /friends/{account_id}` | `204`. Removes a friend, or a pending request either way | 404 `friend_not_found` |

`player` and each list entry carry the player: `account_id`, `display_name`, `tag`, `full_name`, `crew_tag` (or `null`). List entries add `request_id`, `created_at`, `since` (accepted at; friends only) and the presence fields `status` (`offline`, `online`, `in_room`), `room_id` (`null` outside a room) and `joinable`. Friends come in a room first, then online, then offline, by name within each. Requests come newest first.

### Blocks

| Route | Answer | Errors |
| --- | --- | --- |
| `POST /blocks` `{"account_id": "42"}` | `201` the entry (`200` if already blocked). Deletes the pair's friendship or pending request, and each side's presence shows the other offline | 400 `cannot_block_self`, `invalid_body`; 404 `player_not_found`; 409 `blocks_limit` (`max_blocks` 500) |
| `DELETE /blocks/{account_id}` | `204` | 404 `block_not_found` (only your own blocks) |
| `GET /blocks` | `{"blocks": [{player fields, "blocked_at"}], "max_blocks": 500}`, newest first | |

`social::is_blocked(conn, a, b)` is true when either account blocked the other; `social::has_blocked(conn, blocker, target)` is one direction. For N9's rooms: Quick Join must not match a blocked player into your room, and a blocked player cannot invite you (check `is_blocked` on `party_invite` / invites).

### Presence

**Source of truth.** A friend is `online` when the gateway's session registry (`Sessions`) holds a live session for them. They are `in_room` (with `room_id` and `joinable`: the room has space) when a room task has said so through `state.presence.set_room(account, Some(RoomPresence { room_id, joinable }))`, and `set_room(account, None)` on leave. Since N5.1 the room tasks call it (see "Rooms → Presence"). A friend holding a room seat while disconnected shows `offline`.

**`GET /presence`** → `{"friends": [{"account_id", "status", "room_id", "joinable"}]}`, one entry per accepted friend, by id. This is for polling clients.

**WebSocket** (docs/PROTOCOL.md §4, unchanged):

1. `lobby_command.presence_subscribe {enabled: true}`: the gateway reads the account's friends from the database (no lock held), sends this frame's earlier replies, then subscribes. Subscribing queues the snapshot: `lobby_event.presence` with every friend, split into messages of at most 128 friends, as its own frame. An account without friends gets one empty `presence`. Subscribing again replaces the subscription with a fresh snapshot.
2. **Updates** are single-entry `presence` events. Later entries replace earlier ones, as in the protocol. They are sent when:
   - a friend's first session starts (`online`), not when a second login replaces a session;
   - a friend's last session ends (`offline`);
   - a friend's room changes (`in_room` / `online`);
   - a request is accepted (the new friend's presence goes to both sides, if subscribed);
   - a friend is removed or blocked, or deletes their account (`offline`, and they are no longer watched).
3. `presence_subscribe {enabled: false}` ends it, as does the session's end. A friend added while the gateway reads the list may be missed until the next subscribe.
4. A database error while subscribing answers a non-fatal `internal` ("Friends presence is unavailable. Try again."). Party commands still answer `not_allowed` until N9; room commands go to the rooms (N5.1).

**Concurrency** (the registry's design). `PresenceHub` is one `std::sync::Mutex` over subscriber → (session handle, friend set), friend → watchers, and account → room. It is held for map updates, a change's lookups and non-blocking `try_send`s into the watchers' bounded 64-frame queues. It is never held across an `.await`, and never taken per game message.
- A full queue kicks that client (slow client) instead of blocking.
- Lock order: the hub, then the registry. The registry never takes the hub's lock.
- Sending under the lock keeps each subscriber's view in the order the changes happened.
- A change costs one lock, the entry's registry lookup, and one encoded frame shared by up to `max_friends` watchers.
- The gateway's `lobby_command` rate limit (5/s, burst 10) bounds resubscribes. Each one is one indexed query.

### Crews

- **Name:** the display-name character rules (letters including Turkish, digits, single separators, starts and ends with a letter or digit) with 3–24 characters. It passes the profanity filter and is unique case-insensitively.
- **Tag:** 2–4 characters `A–Z 0–9`. Any case is accepted and stored upper case. It passes the filter (`A55` is caught) and is unique. It shows on board entries (`crew_tag`), and on nametags once rooms carry it (`Member.crew_tag`).
- **Membership:** one crew per account; at most `social.crew_max_members` (16) members, owner included. You join with the crew's invite code: `social.crew_invite_code_len` (8) characters from the room-code alphabet (no 0/O, 1/I/L), case-insensitive. Every member sees the code; others get `null`.
- **Roles:**

  | Action | Owner | Officer | Member |
  | --- | --- | --- | --- |
  | Kick a member | yes | yes | no |
  | Kick an officer | yes | no | no |
  | Promote or demote | yes | no | no |
  | Transfer ownership | yes (the old owner becomes an officer) | no | no |
  | Rotate the invite code | yes | yes | no |
  | Disband | yes | no | no |

  Nobody kicks themselves or changes their own role.
- **Succession:** when the owner leaves or deletes their account, the crew passes to the longest-standing officer, else the longest-standing member (ties: the lower account id). It is disbanded when nobody is left.
- **Loop crew board:** every membership change (create, join, leave, kick, account deletion) recomputes the crew's score for the **current** season in the same transaction: the sum of the best `leaderboards.crew_top_members` (4) current members' season-best Loop entries. A sum of 0 removes the entry. Earlier seasons stay as they were. Disbanding deletes the crew's Loop crew entries for every season. Crew ids are never reused (`AUTOINCREMENT`).

| Route | Answer | Errors |
| --- | --- | --- |
| `POST /crews` `{"name", "tag"}` | `201` the crew; you are its owner | 400 `invalid_crew_name`, `crew_name_not_allowed`, `invalid_crew_tag`, `crew_tag_not_allowed`, `invalid_body`; 409 `crew_name_taken`, `crew_tag_taken`, `already_in_crew` |
| `GET /crews/mine` | the crew | 404 `not_in_crew` |
| `GET /crews/{id}` | the crew | 404 `crew_not_found` |
| `POST /crews/join` `{"invite_code"}` | the crew | 404 `invalid_invite_code`; 409 `already_in_crew`, `crew_full` |
| `POST /crews/{id}/leave` | `{"disbanded": false, "new_owner_id": "57"}` (`new_owner_id` only when the owner left) | 404 `not_in_crew` |
| `POST /crews/{id}/kick` `{"account_id"}` | the crew | 400 `cannot_kick_self`; 403 `not_permitted`; 404 `not_in_crew` (you), `member_not_found` (them) |
| `POST /crews/{id}/promote`, `/demote` `{"account_id"}` | the crew (officer / member) | 400 `cannot_change_own_role`; 403 `not_permitted`; 404 `not_in_crew`, `member_not_found` |
| `POST /crews/{id}/transfer` `{"account_id"}` | the crew | 400 `cannot_transfer_to_self`; 403 `not_permitted`; 404 as above |
| `POST /crews/{id}/invite-code` | the crew with a new code (the old one stops working) | 403 `not_permitted`; 404 `not_in_crew` |
| `DELETE /crews/{id}` | `204` | 403 `not_permitted`; 404 `not_in_crew` |

```json
{"crew_id": "5", "name": "Night Riders", "tag": "NR", "owner_id": "42", "created_at": 1790000000,
 "member_count": 2, "max_members": 16, "invite_code": "K7QX2M9P", "your_role": "owner",
 "members": [
   {"account_id": "42", "display_name": "Şahin 34", "tag": 42, "full_name": "Şahin 34#0042",
    "role": "owner", "joined_at": 1790000000},
   {"account_id": "57", "display_name": "LoneWolf", "tag": 7, "full_name": "LoneWolf#0007",
    "role": "member", "joined_at": 1790000300}]}
```

Members are listed owner first, then officers, then members, each by join time. `invite_code` and `your_role` are `null` for non-members.

### Reports

**`POST /reports`** `{"target_account_id": "42", "reason": "cheating", "context": {"source": "leaderboard", "board": "loop", "run_id": "917"}}` → `201 {"report_id": "9"}`.

- `reason`: `cheating`, `offensive_name`, `offensive_crew`, `harassment`, `griefing` or `other`.
- `context` is optional: a JSON object saying where the report came from (a room, a board entry, a run). It is stored as compact JSON of at most `social.report_context_max_bytes` (1024).
- **Limit:** `social.reports_per_day` (10) per account in any rolling 24 hours, counted in the database, so restarts and other devices don't reset it. Past it: `429 rate_limited` with `retry_after_secs` (until the oldest report leaves the window). Refused reports don't count.
- **Errors:** 400 `invalid_reason`, `invalid_context`, `cannot_report_self`, `invalid_body`; 404 `player_not_found`; 429 `rate_limited`.

### Account deletion

`accounts::delete` calls `social::on_account_delete` inside its transaction, after the account's leaderboard entries are gone:

- It deletes `friends` rows on either side (friendships and pending requests) and `blocks` both ways.
- It deletes the `crew_members` row. A crew the account owned passes on as in "Succession", or is disbanded when empty. The crew's current-season Loop crew score is recomputed without the account.
- **Reports are kept.** Their deleted side (`reporter_id` or `target_id`) is set to NULL (the foreign keys also say `ON DELETE SET NULL`). The moderation record (reason, context, time, handled) stays useful, for example to spot a pattern of reports about a player who deletes and recreates accounts, while nothing points at the deleted account. `admin reports` shows the side as `deleted`.
- `admin_log`'s `account_delete` detail adds `friends=`, `blocks=`, `crew_memberships=`, `crew_transferred=`, `crew_disbanded=` and `reports_kept=` (counts only).

### Admin commands

```sh
westbound-server admin reports --unhandled          # newest first, one line each; --limit N (50)
# #12 1790000000 reporter=42 target=57 reason=cheating unhandled context={"source":"room"}
westbound-server admin report-handle 12
westbound-server admin crew-rename 5 "Day Riders"   # name rules, filter, uniqueness
westbound-server admin crew-rename 5 --tag DR       # or both at once
westbound-server admin crew-disband 5               # members released, Loop crew entries removed
```

- `report-handle`, `crew-rename` and `crew-disband` are logged to `admin_log` (`report_handle`, `crew_rename` with from/to, `crew_disband` with the member count). `reports` only reads.
- Bans, renames and board removals are the Accounts and Leaderboards commands.
- A running server shows a crew rename at once (board reads look crews up). A disbanded crew's cached board top catches up within `leaderboards.cache_ttl_secs`.

### Tables

Migration `0004_social.sql`:

- `friends`: `id` (the request id), `account_a` < `account_b` (UNIQUE pair), `requester_id`, `status` (`pending` / `accepted`), `created_at`, `accepted_at`. Indexed by each side and status. Rows cascade with either account.
- `blocks`: (`account_id`, `blocked_id`) primary key, `created_at`. Indexed by `blocked_id`. Cascades.
- `crews`: `id` (AUTOINCREMENT), `name` (NOCASE, UNIQUE), `tag` (NOCASE, UNIQUE), `owner_id`, `invite_code` (UNIQUE), `created_at`. No cascade on the owner: deletion hands the crew on first.
- `crew_members`: `account_id` (primary key: one crew per account), `crew_id` (cascades with the crew), `role` (`owner` / `officer` / `member`), `joined_at`. Indexed by (`crew_id`, `joined_at`).
- `reports`: `id`, `reporter_id` and `target_id` (`ON DELETE SET NULL`), `reason` (checked enum), `context` (JSON), `created_at`, `handled`, `handled_at`. Indexed by (`reporter_id`, `created_at`) for the limit, (`handled`, `created_at`) for the admin list, and `target_id`.

### Configuration

`[social]`:

| Key | Default | Meaning |
| --- | --- | --- |
| `max_friends` | `100` | Accepted friends per account |
| `max_outgoing_requests` / `max_incoming_requests` | `50` / `100` | Pending requests an account may have sent / waiting on it |
| `max_blocks` | `500` | Accounts one account may block |
| `crew_max_members` | `16` | Members per crew, owner included (spec) |
| `crew_invite_code_len` | `8` | Invite code length (6–16) |
| `reports_per_day` | `10` | Reports per account per rolling 24 h |
| `report_context_max_bytes` | `1024` | Largest report `context` (compact JSON; 2–4096) |

`[rate_limits]`: `social_per_hour` / `social_burst` (`60` / `20`), the social writes per account.

## Traffic simulation (N4.1)

Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Traffic: server-authoritative with intents → Server simulation, Testing (traffic parity, traffic soak), Tuning reference. The client model it ports: [TRAFFIC.md](TRAFFIC.md). Code: `westbound-server/crates/sim/src/traffic/`. Pure: no I/O, clock or global state, allocation-free per tick.

### What the room uses

```rust
let mut world = sim::traffic::TrafficWorld::builtin(&map, Density::Normal, room_seed)?;  // filled ring
world.set_player(p, PlayerInput { s, d, s_dot, d_dot, length, width, tick });          // latest report
world.tick();                                   // one 20 Hz step: players extrapolated, sim, ramps
for e in world.sim.events.as_slice() { /* Signal, Cancel, Hazards, Horn, BrakeTap, Spawned, Despawned */ }
// world.sim.state: the SoA TrafficState (s, d, v, lane, lc_state, flags ...) for corrections and spawns
world.set_density(Density::Rush); world.set_road_works(zone, true); world.notify_hit(slot, player);
```

- **Players** are `PlayerInput`s in road space: `s` (m, wrapped or not), `d`, `s_dot`, `d_dot`, body size and the tick the state describes. `PlayerInput::from_vehicle` converts speed, lateral velocity and heading relative to the road as the client's `TrafficSim._read_player` does (the server has no curvature: pass 0; the error is under 0.5 %). The sim extrapolates each report linearly to the current tick, at most `player_max_extrapolation_s`.
- **Events** (`SimEvent`, fixed-capacity buffer, cleared by `tick`): `Signal` is the intent: `tick` (blinker on), `move_start_tick` (the tick the lateral move starts: the curve's u = 0 there, so d(t) = d0 + (target - d0) · smoothstep((t - move_start) / duration)), `target_lane`, `target_d` and `duration_s` (the move time, drawn when the blinker comes on). `Cancel` ends a signal. `Hazards` (value 1 on / 0 off, tag `Hit`), `Horn` (blind spot, close pass) and `BrakeTap` (cut-in) are the client model's reactions; the handoff keeps horns client-side. `Spawned` / `Despawned` carry the slot and `vehicle_id`; tags `Ramp` (an on-ramp entry) and `Exit` (an off-ramp exit).
- **For N4.2** (encoding decisions, not made here; N4.2 made them, see "Traffic streaming (N4.2)": wire lanes from the right, the ramp pseudo-lane as lane 7 (MP-D6), car ids from a free list held 30 s, hits as `hazard` + `hard_brake` intents plus per-tick corrections):
  - lanes in the sim count from the median (0 = leftmost, as the client and the map's spawn points); the protocol's `lane` counts from the right (`n - 1 - lane`);
  - `vehicle_id` is an `i32` that grows by one per spawn; `car_id` is `u16` (wraps after 65,536 spawns, about 18 h of churn in one room);
  - ramp cars sit in a **pseudo-lane** one right of the rightmost lane (`TrafficSim::ramp_lane(s)`, `lane == lane_count(s)`): an on-ramp car spawns there, an exit's `Signal` targets it. The protocol's `target_lane` (0 = rightmost, 0–7) has no value for it: an exit could be sent as a lane change to the rightmost lane plus a new intent kind, or `target_lane = 7` reserved (**needs a protocol decision**). `TrafficSpawn.d_cm` carries an entry's position as is;
  - hit reactions: `Hazards` on at the next tick (4 s recovery, `hit_recover_s`) with a hard brake for `hit_brake_s`: the `Hazard` and `HardBrake` intents.

### Structure: a port that keeps the GDScript's shape

| Rust | GDScript (ported at) | Notes |
| --- | --- | --- |
| `idm.rs`, `mobil.rs`, `no_ambush.rs` | `idm.gd`, `mobil.gd`, `no_ambush.gd` | Function for function; `gd.rs` has Godot's exact `maxf` / `minf` / `clampf` |
| `state.rs` | `traffic_state.gd` | Same fields, slot order and `hash_into` |
| `sim.rs` (`TrafficSim`) | `traffic_sim.gd` at the integration branch's `4b33c6c` (WP6.8 lane drops `aac617e`, WP6.9 weaving racers) | Same fields without the `_`, same functions in the same order: `spawn`, `despawn`, `notify_hit`, `honk`, `notify_close_pass`, `set_headlights`, `request_lane_change`, the set-piece hooks, closures (`add_lane_closure`, `merge_zone_frac`, `closure_ahead`, `_closure_wall_accel`, `_consider_merge`), lane-drop zones (`add_lane_drop_zone`, `lane_drop_limit_at`, `_drop_brake`, `_drop_tick`, `_update_drop_reach`, `_yield_accel`, `_zone_held`, `_collect_yield_candidates`, `_merge_gap_accel`), set-piece zones, `step`, `_step_accel`, `_step_lateral`, `_tick_signaling`, `_tick_moving`, `_tick_hit`, `_tick_reactions`, `_consider_lane_change`, `_consider_split`, `_consider_split_exit`, `_start_signal`, `_cancel`, `_eval_target`, `_eval_move`, `_follower_accel`, the weaving block (`_init_weave`, `_cooldown_of`, `_weave_bonus`, `_weave_pace`, `_weave_cap_ok`, `_weave_note_change`), `_read_player`, `_sort`, `_refresh_interval`, `_emit_pending`. Not ported: WP6.1's passability (single-player only) |
| `population.rs` | `SpawnSources.Flow.draw_into` / `_eligible` / `_pick` | The server's own fill, ramps and density upkeep |
| `checker.rs` | `tests/fixtures/traffic/traffic_rule_checker.gd` (the rules) | Plus the intents |
| `rng.rs`, `trace_hash.rs` | `src/core/rng.gd` (Godot's PCG32 `RandomNumberGenerator`), `src/core/trace_hash.gd` | Bit-exact |
| `road.rs` | the `RoadPath` subset | Open road (parity) and the loop (wrap) |

**When `traffic_sim.gd` changes** (WP6.10 and later): diff it from `4b33c6c`, apply the same change to the same function in `sim.rs` (mind the MP generalisations below: `self.is_player(j)` for `== _P`, `road.signed_delta(a, b)` for `b - a` between positions, the `next_k` / `prev_k` walks for `kk += 1` / `kk -= 1`), export new parameters in `tools/server_data/export_sim_data.gd` (and `TuningParams` / `ProfileParams`), re-run the exporter, then `cargo test -p sim --test parity`. The traces fail at the first tick where the two models differ.

### The server's rules

| Rule | How | Where |
| --- | --- | --- |
| Players are participants (up to `max_players`, 8) | Entries `capacity + p` in the sorted order: leaders by lateral overlap, MOBIL's safety with the player b_safe (2 m/s²), the hidden-follower check, cut-in brake taps, blind-spot horns, split blocking, hit swerves away from the hitting player | `set_player`, `is_player` |
| Players at the current tick | Linear extrapolation of the report to `tick`, capped at `player_max_extrapolation_s` (0.5 s, not in spec) | `read_players` |
| No-ambush against predicted players | `no_ambush::violates` against every player's extrapolated position and road velocity | `eval_move` |
| 1.0 s minimum signal time | The profile's signal time floored at `signal_time_floor_s` = 1.0 (the client floors at 0.5; aggressive and racers signal 0.6 s there) | `SimConfig::multiplayer` |
| Intents at decision time | The move time is drawn when the blinker comes on; `move_start_tick` repeats `_tick_signaling`'s float accumulation (every car is due every tick), so the move starts exactly there (checked by the soak) | `start_signal` |
| Fixed 20 Hz, no distance-based detail | `near_radius_m = INF` (every car's model every tick) | `SimConfig::multiplayer` |
| The loop | s wraps into [0, L); every distance between positions is `road.signed_delta`; the leader, follower and scan loops walk round the order; lane closures and drop zones wrap | `road.rs`, `sim.rs` |
| Lane drops | The map's lane changes become the client's closures and WP6.8 drop zones (the zone starts `lane_drop_slow_zone_m` before the taper: loop_v1's lane-ends signs stand there; checked against the client's `sync_road_closures` in `loop_closures.json`) | `add_road_closures` |
| Density upkeep through the ramps | Target = density × section share (`LoopTuning.section_density_pct`) over every lane-km: light 514, normal 857, rush 1200. Off-ramps: a rightmost-lane car passing the diverge exits with probability `exit_share_base_frac` (15 %) + `exit_share_gain` × surplus (none below target); the exit is a telegraphed move into the ramp lane, and the car despawns when it completes. On-ramps: while below target, a car every `spawn_interval_s` (1.5 s) at the ramp's start when clear; the ramp lane is closed at the ramp's end (`merge_wall_m`), so the car merges like at a lane drop (WP6.8 zone, zipper, own-advantage merge) | `population.rs` |
| The mix | The client's Flow draw per lane: weights, aggressive / racer shares and headway scale of the loop's director leg (5), keep-right and fast-lane rules, v0 in the lane's band with jitter, a type from the profile's list, a colour from the section's palette | `Population::draw` |
| Fill | Lane by lane at the density's spacing (±50 %), each car at least IDM's s* (both orders, with the closing speed) + 5 m behind the previous one, nothing within `merge_spawn_clear_m` of a closure or `spawn_player_clear_m` of a player; then gap-filling passes to the exact target | `Population::fill` |
| Road works | `set_road_works(zone, on)`: the zone's lanes from the right closed like a set-piece closure | `Population::set_road_works` |

**Not on the server:** motorbike lane splitting (`lane_split: false`): a split's move targets a lane boundary, which `TrafficIntent.target_lane` cannot express. Motorbikes still spawn and drive. Turn it on once the protocol can name a boundary target.

### Server-only safety extensions (deviation: needs an orchestrator row, MP-D5)

At rush-hour density the loop's lane drops (desert and city 4 → 3, canyon 3 → 2) queue up, and the client model then collides: over one simulated hour at rush, **11,622 ticks with traffic-to-traffic contacts** (33,162 pair-ticks, all real body overlaps; `soak_hour_rush_without_mp_extensions`). Light and normal hours were clean without them. Three mechanisms, each traced to a contact:

1. **Cut-out.** A car's new leader in the target lane is itself signalling out of it; once it leaves, a stopped queue is revealed that needs more than the 6 m/s² clamp.
2. **Stale lane-change decision.** MOBIL judges the new leader as if it holds its speed; by the time the car is in the lane (1.0 s signal on the server, 0.6 s for racers in single-player, plus the move) the leader, braking into the queue, has slowed too much.
3. **Late IDM reaction.** A racer at 180 km/h follows a car braking at the clamp into the queue; stock IDM ignores the leader's deceleration and reacts too late for 6 m/s².

The fixes (`mp_traffic.json`, each on / off; off in the parity config, so the client model's parity is untouched):

| Flag | What |
| --- | --- |
| `look_through_leaving_leaders` | A leader signalling or moving to a target off the path does not hide what is ahead of it: following (IDM) and MOBIL's own safety also judge the next vehicle on the path (`look_through_accel`) |
| `predict_leader_braking` | MOBIL's own safety also judges each new leader extrapolated with its current deceleration to when the car is in the lane (signal time + half the minimum move time), against the car holding its speed (`predicted_leaders_safe`) |
| `anticipate_leader_braking` | When stopping s0 behind the leader's own stopping point (at its current deceleration) needs more than the profile's comfortable b, the follower brakes for it now (`anticipation_accel`); never beyond the clamp |

With them: **0 contacts at every density** and 0 clamp violations. Recommended follow-up: port the three into `traffic_sim.gd` (the single-player game has the same exposure at high density, and N4.3's client-side IDM should follow the same model as the server), then turn them on in the parity config and re-export.

**Collision criterion.** The soak counts a contact when two cars' boxes overlap as clients render them: `TrafficView`'s heading atan2(v_lat, max(v, 20 km/h)) within ±20° (`view_yaw_*`, exported), and the sim's own un-yawed bodies. The single-player checker's heading (atan2(v_lat, max(v, 0)) within ±0.28 rad) is reported, not gated: it turns a 16 m semi or 12 m coach crawling through a lane change in a lane-drop queue far enough to touch a car two lanes over (365 pair-ticks in the rush hour, all with the long vehicle below 1 m/s; no body overlap). Clients never draw that.

### Data

- **`data/traffic_params.json`** is exported from the Godot tuning by `tools/server_data/export_sim_data.gd`: `TrafficTuning` (SI), the `TrafficRegistry` profile and type arrays (with the WP6.9 weaving fields), the spawn mix, `LoopTuning` with `DirectorTuning` at the loop's leg, the view's yaw rule, `NetTuning.tick_rate_hz`, `LivesTuning.collision_inset_m`. Floats are written readable and again as exact IEEE-754 bits under `exact` (Godot's JSON writer does not round-trip every double); the loader applies the bits and checks the two agree.
- **`data/mp_traffic.json`** holds the rules the Godot tuning does not: from the spec, `signal_time_floor_s` 1.0, densities 6 / 10 / 14 per km per lane; not in spec, `capacity` 1600, `max_players` 8, `player_max_extrapolation_s` 0.5, `lane_split` false, the three safety extensions, and the ramp and fill values in the table above.

```sh
tools/godot.sh --headless --path . --import      # once
tools/godot.sh --headless --path . --script res://tools/server_data/export_sim_data.gd            # write
tools/godot.sh --headless --path . --script res://tools/server_data/export_sim_data.gd -- --check # exit 1 if stale
# -- --dump=<trace>:<tick> prints every car of a trace at a tick (to diff a divergence)
```

### Parity (≤ 1e-9; bit-exact in practice)

`crates/sim/tests/parity.rs`, vectors in `crates/sim/vectors/`:

| Vectors | Result |
| --- | --- |
| `rng.json`: 7 seeds × 24 draws of each kind, `derive_seed`, the traffic stream chain | bit-exact (Godot's PCG32 with its `randf` / `randi_range`) |
| `idm.json`: 1,200 cases × `accel`, `free_accel`, `interaction_accel`, `desired_gap`, `equilibrium_gap`, `pow_int` | 7,200 / 7,200 bit-exact |
| `mobil.json`: 600 cases, `incentive`, `threshold`, `accepts`, `is_safe`, `b_safe_for` | bit-exact |
| `no_ambush.json`: 1,500 cases (287 violations) | identical |
| `player_velocity.json`: 300 cases of `_read_player`'s road velocity | within 1e-9 (libm) |
| `loop_closures.json`: the client's closures and drop zones on loop_v1, per lane every 50 m | within 1e-8 m |
| `trace_*.json`: the whole sim, per-tick state hash and every event | **tick-identical**: `sp_weave_120hz` 4,800 / 4,800 ticks (single-player rules, near / far ticks, hits, close passes), `sp_closure_120hz` 3,600 / 3,600 (set-piece closure), `mp_weave_20hz` 2,400 / 2,400 (20 Hz, all near, 1.0 s floor, 4 lanes, headway scale), `mp_lane_drop_20hz` 1,800 / 1,800 (a WP6.8 road drop with its zone) |

The traces run the GDScript `TrafficSim` on the `StraightRoadPath` fixture with a scripted player and a tool-local spawner; the Rust replay applies the same ops. They exercise every profile including WP6.9's weaving racers, lane changes and cancels (player, hesitant, unsafe), mandatory merges, the zipper and harmonisation, hits and horns. The server config differs from them only in the MP flags (move time at the signal, the safety extensions, no lane splitting).

### Tests and numbers

| Test | What |
| --- | --- |
| `tests/parity.rs` | The table above |
| `tests/mp_rules.rs` | Every profile signals ≥ 1.0 s and moves at its intent's tick with the announced time; a player (any index) as leader, never touched; a player as new follower tightens b_safe, and entering the gap cancels the signal; extrapolation (and its cap); leaders across the seam; ramp exits (signalled first) and entries (merge onto the road); density change through the ramps; a hit swerves away from the hitting player with hazards; road works; determinism by seed |
| `tests/soak.rs` | Short soaks (3 min normal, 2 min rush) in the normal suite; `soak_hour_{light,normal,rush}` (`#[ignore]`): one simulated hour each with 6 bot players (IDM, weaving, reporting 150 ms late), the rule checker every tick |
| `tests/alloc.rs` | A counting allocator: 600 ticks of a rush room with 8 players moving, joining, leaving, a hit and exits: **0 allocations** |
| `tests/bench.rs` | µs per room tick (`cargo test --release -p sim --test bench -- --nocapture`) |

**One-hour soaks** (release, `cargo test --release -p sim --test soak -- --ignored --nocapture`; the integration branch with WP6.8 and WP6.9):

| Density | Vehicles (target, min–max after 60 s) | Lane changes signalled / moved / cancelled | Shortest blinker → motion, shortest intent lead | Merges, exits = entries | Contacts, rule violations | Wall time |
| --- | --- | --- | --- | --- | --- | --- |
| Light | 514, 513–514 | 46,966 / 44,590 / 2,364 | 1.05 s, 1.00 s | 3,460, 232 | 0, 0 | 15 s (235×) |
| Normal | 857, 857–857 | 61,878 / 56,738 / 5,124 | 1.05 s, 1.00 s | 3,793, 276 | 0, 0 | 28 s (130×) |
| Rush | 1200, 1200–1200 | 82,872 / 72,473 / 10,371 | 1.05 s, 1.00 s | 4,707, 319 | 0, 0 | 42 s (87×) |

No bot driving normally was rear-ended (the bots' own cut-ins caused 13–35 contacts per hour, as a weaving player would). Rule violations cover signal time, unsignaled moves, intents (lead and move tick), the clamp, brake-light flags and off-road.

**Tick cost** (`bench.rs`, release, Intel Xeon @ 2.10 GHz shared with other jobs, one thread; 8 players; a tick = sim step + ramps and density upkeep):

| Density | Vehicles | Mean | Median | p99 | 20 rooms × 20 Hz |
| --- | --- | --- | --- | --- | --- |
| Light | 514 | 122 µs | 104 µs | 261 µs | 4.9 % of one core |
| Normal | 857 | 199 µs | 182 µs | 386 µs | 8.0 % |
| Rush | 1200 | 362 µs | 330 µs | 569 µs | 14.5 % |

The N10 target (20 rooms × 8 players ≤ 50 % of 1 vCPU, room tick p99 < 5 ms) leaves room for streaming and scoring; the bench asserts p99 < 5 ms and < 50 % in release builds.

### Open questions

- **Protocol:** lane-splitting boundary targets (see "For N4.2"). Ramp exits and entries: decided (MP-D6, lane 7; "Traffic streaming (N4.2)").
- **The three safety extensions** (MP-D5): approve, and schedule their port to `traffic_sim.gd` so the client's network IDM (N4.3) matches the server.
- **Ramps:** no ramp geometry on the client yet (docs/LOOP_MAP.md): an exiting car moves one lane right onto the shoulder and is gone; an entering car appears on the shoulder at the on-ramp. N4.3 should fade them.

## Rooms (N5.1)

WP N5.1 (server side), in `crates/server/src/rooms/`. Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Architecture (room tasks), Rooms, parties and matchmaking → Rooms, Players, Time of day in multiplayer, Resource budget; [PROTOCOL.md](PROTOCOL.md) §4 (the messages, used as frozen). The client side is N5.2; traffic streaming is N4.2; scoring is N6; parties are N9.

| File | What |
| --- | --- |
| `mod.rs` | `Rooms` (`AppState.rooms`): create, join by code / id, Quick Join, browse, the account → seat index; `RoomLink` (a connection's seat: its room queue and the room clock); `RoomParams` (`[rooms]` converted once) |
| `room.rs` | One room, synchronous: seats, host rules, runs, placements, plausibility, the relay, one frame per tick per client |
| `task.rs` | The room's tokio task: its bounded queue and its 20 Hz tick |
| `clock.rs` | The room clock |
| `plausibility.rs` | `PlayerState` checks (pure) |
| `road.rs` | Lane centres, the lane at a `d`, lateral bounds, flow speeds, the start gantry's spawn points |
| `traffic.rs`, `sim_traffic.rs` | The traffic seam `RoomTraffic` (`NoTraffic`; `SimTraffic` over `sim::traffic::TrafficWorld`) |
| `traffic_stream.rs`, `car_ids.rs` | N4.2: each client's traffic stream and the car ids (see "Traffic streaming (N4.2)") |
| `metrics.rs` | Room metrics |
| `tests.rs` | The room core without sockets (commands and ticks by hand) |

### Architecture

- **One task per room.** A `Room` owns its seats, settings, clock and traffic outright; the task hands it each command as it arrives and each 20 Hz tick of the room's clock (`advance_to`). No locks and no `.await` in the room.
- **Bounded queues.** Connections reach a room through its `mpsc` queue (`rooms.command_queue`, 256). States, run events, hits, chat and host commands use `try_send` (a full queue drops, `wb_room_dropped_total{reason="queue_full"}`). Joins, leaves and the disconnect notice wait for space (up to `rooms.join_timeout_ms`). Rooms reach connections through the session's 64-frame outbound queue (`SessionHandle::send_frame`: a full queue kicks that client as `slow_client`, it never blocks the room).
- **Timer.** The task's timer fires in the middle of each clock tick, so a boundary never races it. The clock's tick number decides which room tick runs: a late wake-up runs the latest tick once, and the room's timers compare tick numbers.
- **One frame per tick per client**, built in the seat's own reused `FrameBuilder`: the `room_snapshot` on the tick the player (re)joined, or else that tick's room events; then the seat's private replies (host-command errors); then `player_states`; then traffic (`RoomTraffic::write_client`, N4.2). A tick with nothing to say sends nothing. Only a player leaving gets a separate frame: `lobby_event.room_left`, sent at once.
- **The registry** (`Rooms`, one `std::sync::Mutex`) holds room id → queue, info and clock, code → id, and account → seat. It is locked to create, find or close a room and when a seat is taken or released; never per tick, never across an `.await`. The presence hub is called after the lock is released.
- **Allocation.** Per tick, the room reuses its buffers (the seat frames, the relay list, the traffic's player list). Snapshots, room events and log lines allocate, and they happen on joins and changes, not every tick.

### Rooms, codes and caps

| Command | What happens | Refusals (non-fatal `error`) |
| --- | --- | --- |
| `room_create {settings}` | A new **private** room; the creator gets the first seat and is host. `max_players` is clamped to `rooms.max_players` (8), `fixed_cycle_ms` is taken modulo the cycle | `not_allowed` (visibility `public`), `server_full` (`limits.max_rooms`, 40), `already_in_room` |
| `room_join_code {code}` | A seat in the room with that code | `room_not_found`, `room_full`, `not_allowed` (kicked from it), `already_in_room` |
| `room_join_id {room_id}` | The same by id (browser, a friend's Join button) | as above |
| `quick_join` | The **public** room with the most players that has a seat (ties: the oldest); a new public room when none fits | `server_full` |
| `room_leave` | Leaves: `lobby_event.room_left {left}` to the player, `room_event.leave {left}` to the room. A run in progress ends (`run_result {quit}`) | `not_in_room` |
| `room_browse` | `lobby_event.room_list`: public rooms, fullest first, at most 64 (players, max, density, night) | |

- **Room ids** are u32 from 1, never reused while the process runs. **Codes** are 6 characters from the protocol's alphabet (no 0/O, 1/I/L), random (OS RNG), unique among live rooms. Public rooms have codes too (the snapshot carries one).
- **Public rooms** are created by Quick Join with the spec's settings: normal density, the UTC `cycle` clock, 8 seats, no host. Until parties exist (N9), each public player is a crew of one (its own `crew_slot`).
- **Private rooms:** everyone is crew slot 0. The creator is host. The host passes to the longest-present player when the host's seat goes (leave, kick, seat hold running out), with `room_event.host_change`.
- **A room closes** `rooms.empty_close_ms` (60 s) after its last seat went; its code stops working. At server shutdown every seated player gets `room_left {closed}`.
- **One seat per account.** A second join while seated is `already_in_room`; `room_leave` first. A join into another room releases a seat the account still holds elsewhere (a held seat, or one of a replaced login).

### Host commands (private rooms)

| `room_host_command` | Effect | Refusals |
| --- | --- | --- |
| `kick {player_id}` | The player gets `room_left {kicked}` and cannot rejoin this room; the room gets `room_event.kick`. A run in progress ends | `not_host`; `not_allowed` (yourself, nobody by that id); `not_allowed` in public rooms ("Public rooms have no host") |
| `set_density {density}` | `room_event.settings` with the new settings and clock; the traffic gets `set_density` | as above |
| `set_time_mode {time_mode, fixed_cycle_ms}` | The same; `fixed_cycle_ms` modulo the cycle | as above |

**Leaderboard eligibility** (spec: public rooms count; private rooms left on the defaults also count): a run is `leaderboard_eligible` when it is verified and the room is public, or private with normal density and the `cycle` clock for the whole run (a host change to anything else marks every run in progress).

### Players

**Placements.** The protocol has no spawn message, so the server places a player by putting **the player's own id** in its `player_states`: a `PlayerState` with the placement tick, `s`, `d` (the lane centre), the speed, heading 0 and `run_state = protected`. It is repeated every tick until the client sends a state near it (within `rooms.placement_radius_m`, 30 m, plus what the speed cap covers since the placement), and apply each placement tick once. States far from it are dropped as in flight for `rooms.placement_grace_ms` (2 s); after that the next state is taken with a `teleport` offence. Others see the car at its new place at once. **This is a semantic proposal for PROTOCOL.md** (no wire change; see the N5.1 handoff). Placements come with `rooms.protection_ms` (3 s) of protection (`PlayerView.protected_until` for traffic and N6).

| When | Where |
| --- | --- |
| A new seat | 40 m (`rooms.spawn_behind_leader_m`) behind the **crew leader**, in the leader's lane; with no crewmate driving, at the start gantry (the spawn points 150 m past sector 0, one lane per player id in turn) |
| Crash-out respawn, `run_event.start` after a run ended, `run_event.rejoin` | Behind the crew leader; with no crewmate driving, where the car is |
| Reconnect (a held seat taken back) | Where the car was, run intact |

- The **crew leader** is the longest-present connected crewmate whose run is active and who has answered their own placement (seats are in join order). Every placement passes through `RoomTraffic::free_gap` (a real gap with `rooms.traffic = "sim"`: the wanted lane, then its neighbours, ±`spawn_search_m` in `spawn_step_m` steps with `spawn_clear_m` to the nearest car). The speed is the lane's flow speed at that s (the section's `lane_flow_speeds_from_right_kmh`).
- **Runs.** A seat starts a run at once (`run_seq` 1, then counting). `run_event.start` starts a new run only when none is active; `end` ends it (`quit`); `rejoin` places the player behind the crew (the chain forfeit is N6's).
- **Crash-out.** `hit_report` with `lives_left = 0`, or a `player_state` with `run_state = crashed`, ends the run (`run_result {crashed}` to the room) and schedules the respawn `rooms.crash_respawn_ms` (3 s, the results toast) later, with a fresh run. Leftovers of the run before (a crashed state in flight, a hit stamped before the new run started) are ignored.
- **`run_result`** goes to everyone in the room: `player_id`, `run_seq`, `end_reason`, `verified` (no offence), `leaderboard_eligible`, `duration_ms`, `distance_m` (forward distance from accepted states, teleports left out). Score and event counts are 0 until N6 (which also records multiplayer runs on the boards).
- **Reconnect.** When a seated connection ends, the room holds the seat for `rooms.seat_hold_ms` (15 s): `room_event.connection {connected: false}`, the member's `disconnected` flag, presence cleared. Joining the same room again (by code or id) within the hold takes the seat back: same `player_id`, a fresh snapshot, `connection {connected: true}`, the run intact, a placement where the car was. After the hold the run ends (`run_result {disconnected}`, the banked score kept, N6) and the seat goes (`room_event.leave {timed_out}`).
- **A second login** (newest wins, see "Sessions") that joins the room takes the seat over the same way; the old connection's link goes inactive at once.
- **Quick chat** is relayed to everyone else in the room (`quick_chat` with the sender's id); muting is the client's.

### The relay

Every tick, each client's `player_states` holds every other seated player's **new** state since the last tick (the latest accepted, clamped), plus its own placement while one is pending. A tick with no new states sends none (clients interpolate 100 ms behind and extrapolate up to 250 ms, spec). A held seat's car sends nothing; the `connection` event says why.

### Plausibility (`plausibility.rs`)

The client is authoritative for its car. Every state passes the checks below against the room clock, the previous accepted state and any pending placement. An **offence** marks the run unverified (`run_result.verified = false`, never on a board), is counted (`wb_room_offences_total{kind}`) and logged once per kind per run. The state is still relayed, clamped where a value is simply out of range. Nobody is kicked for offences (the spec has no such rule). All distances along the loop use the wrapped signed difference, so the seam is not a teleport.

| Check | Limit (defaults) | Offence | The state |
| --- | --- | --- | --- |
| Speed | the fastest car's boosted top speed × 1.1: 285 km/h × 1.08 × 1.1 = 338.6 km/h | `speed` | clamped |
| Lateral velocity | 12 m/s × 1.2 | `lateral` | clamped |
| `d` | from the median barrier's face (0.5 m) to the guardrail (lanes, shoulder, guardrail offset; the wider count inside a lane-count taper), ±1 m | `bounds` | clamped |
| Distance along the loop between two states | ≥ −2 m and ≤ speed cap × Δt + 2 m | `teleport` | taken |
| The same against the reported speeds | ≤ (max of the two speeds + a·Δt/2) × Δt + 2 m | `distance` | taken |
| Forward acceleration | 12 m/s² (engine traction 9 + boost 3) × 1.2 | `accel` | taken (braking is unlimited: hits) |
| Lateral movement | 12 m/s × 1.2 | `lateral` | taken |
| Tick ahead of the room clock | > 500 ms | `clock` | dropped |
| Tick behind the room clock | > 2 s | | dropped (`stale`) |
| Tick not after the last accepted | | | dropped (`out_of_order`) |
| Far from a pending placement | within the grace | | dropped (`in_flight`) |

The car numbers are the game's (`data/cars/*.tres`, `data/tuning/vehicle.tres`); `tests/rooms_data.rs` pins them. The lateral cap is an estimate (a lane change peaks near 8.4 m/s); N6/N8 can tighten it from the physics.

### The room clock (`clock.rs`)

- `room_snapshot.clock` and `room_event.settings.clock` give `cycle_ms` at the message's tick, with `cycle_len_ms` (32 min) and `day_len_ms` (22 min). Night ×2 is `cycle_ms ≥ day_len_ms`.
- **`cycle`** (public rooms, and private rooms by default): UTC-derived, `cycle_ms = (unix_ms − epoch) mod cycle` at the tick's UTC instant. A room reads the UTC time once when it is created (its tick 0) and every tick is 50 ms on, so every room agrees with the UTC phase to the millisecond. This is the client's loop-mode `RoomClock.phase_s()` (`fposmod(unix_s − room_clock_epoch_unix_s, cycle)` with `data/tuning/loop.tres`), in integer milliseconds (`clock::tests`, `tests/rooms_data.rs`).
- **`fixed`**: `fixed_cycle_ms` (modulo the cycle), held. **`night`**: held at the middle of the night (27 min).
- Clients advance `cycle_ms` with `server_now()` in `cycle` mode and hold it otherwise (PROTOCOL.md §4).
- `Pong` answers with the room's tick clock while seated (see "Realtime gateway → Clock").

### Traffic seam

A room owns a `Box<dyn RoomTraffic>`: `tick(tick, players)` after the tick's states (every seated player's latest state, clamped, with heading, lateral velocity and protection), `set_density`, `set_night` (headlights when night starts or ends), `write_client(player_id, s, joined, frame)` (N4.2 streams spawns, despawns, intents and corrections into the client's tick frame), `player_left`, and `free_gap(map, want)`.

- `rooms.traffic = "sim"` (default since N4.2): `SimTraffic` owns a `sim::traffic::TrafficWorld` (N4.1) seeded per room, filled at the room's density. Players go in as `PlayerInput`s (player index = a free slot of 8, body size from the exported tuning); the world steps in lock-step with the room tick (a room that missed ticks catches up, at most 20 steps, else re-anchors); spawns take real gaps; `write_client` streams each client's area (see "Traffic streaming (N4.2)"). N4.1 measured 199 µs per tick at normal density in release; streaming to 8 clients adds about 60 µs.
- `rooms.traffic = "none"`: `NoTraffic`. Nothing is simulated and every spawn spot is free.
- `hit_car(player_id, car_id)` (default: nothing) applies an accepted hit's scripted reaction; N6 calls it once it accepts a hit (N4.2 does not call it from `hit_report`: the hit cross-check is N6's).

### Presence

A seat sets the player's presence to `in_room` with `joinable` = the room has a free seat (`presence.set_room`), and every seated player's `joinable` is refreshed when the seat count changes. A held seat or a released one clears it (unless the account's seat is in another room by then).

### Metrics

On `/metrics`, after the gateway's:

| Metric | What |
| --- | --- |
| `wb_rooms`, `wb_rooms_created_total` | Live rooms, rooms created |
| `wb_room_seats` | Occupied seats (held ones included) |
| `wb_room_joins_total`, `wb_room_reconnects_total`, `wb_room_seat_timeouts_total` | New seats, seats taken back, holds run out |
| `wb_room_placements_total`, `wb_room_crash_outs_total` | Server placements, crash-outs |
| `wb_room_tick_seconds` (histogram: 25 µs … 100 ms) | Wall time of one room tick; the p99 is read off the buckets (`RoomMetrics::tick_quantile_us`) |
| `wb_room_offences_total{kind}` | `speed`, `accel`, `lateral`, `bounds`, `teleport`, `distance`, `clock` |
| `wb_room_dropped_total{reason}` | `queue_full`, `out_of_order`, `stale`, `future`, `in_flight`, `not_seated` |

Logs at INFO: `room created` (id, code, settings), `room seat taken` / `taken back` / `held` / `released`, `run ended` (reason, verified, distance), `implausible player state; run unverified` (once per kind per run), `joined room` (gateway), `room closed (empty)`.

### Configuration

`[rooms]` (the room cap is `limits.max_rooms`, the tick rate `gateway.tick_rate_hz`):

| Key | Default | Meaning |
| --- | --- | --- |
| `max_players` | `8` | Seats per room (spec) |
| `empty_close_ms` | `60000` | An empty room closes after this (spec) |
| `seat_hold_ms` | `15000` | A dropped player's seat and run are held this long (spec) |
| `protection_ms` / `crash_respawn_ms` | `3000` / `3000` | Spawn and rejoin protection; the crash-out results toast before the respawn (spec) |
| `spawn_behind_leader_m` | `40.0` | Spawns land this far behind the crew leader (spec) |
| `spawn_search_m` / `spawn_step_m` / `spawn_clear_m` | `60.0` / `5.0` / `15.0` | The free-gap search around a spawn spot (not in spec) |
| `traffic` | `sim` | `sim` or `none` (see "Traffic seam") |
| `traffic_aoi_*`, `traffic_near_*`, `traffic_far_hz`, `traffic_car_id_hold_ms` | see "Traffic streaming → Configuration" | The area of interest, correction rates and car-id hold (N4.2) |
| `cycle_len_ms` / `day_len_ms` / `clock_epoch_unix_ms` | `1920000` / `1320000` / `0` | The room clock (loop.tres; spec 32 / 22 min) |
| `command_queue` / `join_timeout_ms` | `256` / `2000` | Each room's queue; how long a join waits for the room (not in spec) |
| `max_speed_kmh` / `speed_tolerance_pct` | `307.8` / `10.0` | The fastest car with boost; spec × 1.1 |
| `max_accel_mps2` / `max_lateral_speed_mps` / `capability_tolerance_pct` | `12.0` / `12.0` / `20.0` | The car's capability; spec × 1.2 |
| `lateral_margin_m` / `position_slack_m` | `1.0` / `2.0` | Allowed overshoot of the barriers; slack on the distance checks (not in spec) |
| `future_tolerance_ms` / `stale_state_ms` | `500` / `2000` | States stamped this far ahead are refused; this far behind, dropped (not in spec) |
| `placement_grace_ms` / `placement_radius_m` | `2000` / `30.0` | Placements: in-flight window; acknowledgement radius (not in spec) |

### Tests

| Test | What |
| --- | --- |
| `rooms::tests` (unit) | Snapshot, join, leave and host passing; the relay and one frame per tick; placement acknowledgement; offences and the unverified run; reconnect within the hold (same seat, run intact, no teleport); the hold running out; crash-out and the respawn 40 m behind the leader after 3 s; rejoin across the seam; host rules (kick, density, time mode, no rejoin after a kick, eligibility); public rooms (no host, a crew each); full rooms, second logins and quick chat; closing 60 s after empty; shutdown; night from the clock |
| `rooms::{clock, plausibility, road, metrics, sim_traffic}::tests` | The UTC phase against the client's rule; every check and the seam; lane geometry and spawn points; the tick histogram; the `TrafficWorld` adapter (lock-step, catch-up, free gaps) |
| `tests/rooms.rs` | Real sockets with `bots::BotClient`s: a private room by code, the relay and the room clock, the gateway's room errors; reconnect within the hold; the hold running out; Quick Join, the browser, join by id, leave, the room cap; 4 rooms × 4 bots; rooms with the `sim` ring; the bench (ignored) |
| `tests/rooms_data.rs` | The `[rooms]` clock and car numbers against the game's data |
| `bots` (`bot::tests`) | Placements, one state per tick, the seam |

### Bench: 20 rooms × 8 bots

`cargo test --release -p server --test rooms bench_ -- --ignored --nocapture` (`ROOMS_BENCH_SECS`, `ROOMS_BENCH_TRAFFIC=sim|none` (default `sim` since N4.2), `ROOMS_BENCH_DENSITY=normal|light|rush`). 20 private rooms of 8 `BotClient`s drive for 20 s over real loopback WebSockets, **bots and server in the same process** on 2 tokio workers. The room tick time comes from `wb_room_tick_seconds`; the process CPU includes the 160 bots' own work (encoding, decoding, their sockets).

Measured 2026-09-30 (release without LTO, the 4-vCPU dev box shared with a Godot soak and other builds: load average 7–8, so wall-time numbers are pessimistic):

| Room traffic | Room ticks | Mean tick | p50 | p99 (bucket bound) | Max | Rooms' CPU (sum of tick time) | Process CPU (incl. bots) | Down per player | Largest frame | Offences |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `none` (N5.1 default) | 9,595 | 57 µs | ≤ 25 µs | ≤ 1 ms | 8.7 ms | 2.0 % of a core | 18 % | 2.5 KB/s | 300 B | 0 |
| `sim` (`TrafficWorld`, normal density, 857 cars per room) | 9,594 | 427 µs | ≤ 300 µs | ≤ 4 ms | 17.6 ms | 14.8 % of a core | 30 % | 2.5 KB/s | 301 B | 0 |
| **N4.2** `sim` + streaming, normal (≈ 44 cars per player) | 9,598 | 485 µs | ≤ 500 µs | ≤ 3 ms | 22.3 ms | 16.9 % of a core | 33 % | 3.6 KB/s on the wire (3.2 KB/s payload) | 1,760 B | 0 |
| **N4.2** `sim` + streaming, rush (1,200 cars per room, ≈ 60 per player) | 9,598 | 627 µs | ≤ 500 µs | ≤ 4 ms | 16.9 ms | 21.8 % of a core | 38 % | 3.8 KB/s on the wire (3.4 KB/s payload) | 2,282 B | 0 |

- **Per room tick:** 57 µs for rooms alone (8 seats: take the tick's states, build and queue 8 frames); about 370 µs more with the traffic ring. The N10 target (20 full rooms ≤ 50 % of one vCPU, tick p99 < 5 ms) holds with room to spare for streaming (N4.2) and scoring (N6); the bench asserts p99 ≤ 5 ms in release. The maxima are scheduler stalls on the loaded box (the tick is wall time).
- **Downstream** (N5.1 rows) was `player_states` only (7 × 24 B + headers each tick): 2.5 KB/s per player at the socket payload level.
- **N4.2 rows** (2026-09-30, same box, load average 7–10): streaming to 8 clients adds about 60 µs per room tick at normal density (485 vs 427 µs mean; the join frames are the largest, 1.8–2.3 KB). Traffic messages average 0.7 KB/s (normal) and 0.9 KB/s (rush) per player; the "down per player" column divides by the whole run including the 160 sequential joins, so it understates the steady state: with 8 bots driving at rush in one room, `rush_hour_downstream_stays_in_budget_with_8_bots` measures **5.1–5.3 KB/s per player on the wire** (framing included) against the 10 KB/s budget. Every bot's traffic mirror ended with 0 violations. p99 stays within the 5 ms target.
- 20 rooms × 20 Hz × 20 s = 8,000 ticks; the rest ran while the 160 bots were joining.

### For the client (N5.2)

- Join with `room_create` / `room_join_code` / `room_join_id` / `quick_join`; the answer is a `room_snapshot` (with `you`) in the next tick frame, or a non-fatal `error`. Call `NetClock.reset()`: `Pong` now carries the room tick.
- **Your own id in `player_states` is a placement**: teleport there (apply each placement tick once), set speed, start the 3 s protection, then keep sending states. States sent before you applied it are dropped.
- A run starts at every placement that begins a run (join, respawn); send `run_event.start` only to start again after `end`. Send `hit_report` with `lives_left = 0` (or `run_state = crashed`) on a crash-out; the respawn placement comes 3 s later. `run_event.rejoin` = the Rejoin crew button.
- Stamp every `player_state` with the room tick from `server_now()`. `d` is the contract's (+ right of travel, lane 0 next to the median; see the handoff's protocol note).
- On a dropped connection, reconnect and join the same room by code within 15 s: same seat, run intact, placed where you were.
- `room_event.connection` fades a member's car; `leave` / `kick` remove it; `host_change`, `settings` (new clock), `crew` as in PROTOCOL.md. `run_result` for everyone (your results toast when `player_id` is you).
- The room clock: `clock.cycle_ms` at the snapshot's `tick`, advanced with `server_now()` in `cycle` mode; night ×2 when `cycle_ms ≥ day_len_ms` (the loop mode's `RoomClock` with a server-given phase).
- Traffic (N4.3): clear your cars on every `room_snapshot`; then follow "Traffic streaming (N4.2)" below (message order, the frame's tick, lanes, intents, corrections).


## Traffic streaming (N4.2)

WP N4.2, in `crates/server/src/rooms/`. Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Traffic: server-authoritative with intents → What the server sends (area of interest, correction schedule), Resource budget (≤ 10 KB/s down per player); [PROTOCOL.md](PROTOCOL.md) §4 (`traffic_*`), §11 (streaming batches), §12 (lanes, car ids); MP-D6. The client side is N4.3 (`src/net/traffic/**`). **This section is the contract the client (and its fake authority) matches.**

| File | What |
| --- | --- |
| `sim_traffic.rs` | `SimTraffic`: the room's `TrafficWorld` (N4.1) + its `TrafficStream`; `write_client` streams; `notify_hit` for N6 |
| `traffic_stream.rs` | `TrafficStream`: sim slot ↔ `car_id`, the tick's intents, each car's wire state once per tick, hit reactions; per client the cars it has and its correction clock |
| `car_ids.rs` | `CarIds`: the u16 id free list (MP-D6) |
| `bots/src/traffic.rs` | `TrafficMirror`: a bot's copy of what it was told, with the client-side checks |

`rooms.traffic = "sim"` is the default now (`"none"` still turns traffic off).

### Every tick, in each client's frame

After `player_states`, the client's tick frame carries up to four kinds of traffic message, **in this order**, each only when it has entries. A list that passes 128 entries (64 for intents) continues in a second message of the same type.

| # | Message | Entries |
| --- | --- | --- |
| 1 | `traffic_despawn` | Cars the client has that left its area (past the hysteresis) or left the ring (an off-ramp exit that completed, or any sim despawn) |
| 2 | `traffic_intent` | This tick's decisions for cars the client **already has** (spawned in an earlier frame). Intents for a car the client does not have yet are not sent: its spawn carries the state |
| 3 | `traffic_spawn` | Every car inside the area that the client does not have, with its full state (below) |
| 3b | `traffic_intent` | Only when a car spawned in this frame is in the middle of a hit reaction: its `hazard` (and `hard_brake` while it still brakes) with the time left, `start_tick` = this tick |
| 4 | `traffic_correction` | `tick` = this frame's room tick. First every car spawned in this frame and every car given an intent in this frame, then every car whose correction is due (below) |

**The frame's tick** is the `traffic_correction.tick`. Every frame that carries a spawn or an intent also carries a correction for each of those cars, at that tick, so:

- a spawn's `s_mm`, `d_cm` and `speed_cms` are the car's state at the correction batch's tick;
- an intent's `start_tick` equals that tick (the decision was made on it; after a stalled room catches up, an intent can be a few ticks older: late, handle as the handoff says).

A tick with nothing to say sends no traffic message; there is no traffic keepalive.

### Area of interest

- **Centre:** the player's latest accepted `player_state.s` (or its pending placement's `s`). **Δ** = the car's `s` minus the centre, the wrapped signed difference on the loop (`LoopMap::signed_delta_mm`, in `[-L/2, L/2)`).
- **Spawned** when −300 m ≤ Δ ≤ +900 m (`traffic_aoi_behind_m`, `traffic_aoi_ahead_m`).
- **Despawned** when Δ < −350 m or Δ > +950 m (`traffic_aoi_hysteresis_m` = 50 m), so a car at the edge does not flap. At normal density a player has about 40 cars, at rush 45–95 (the city and 4-lane stretches).
- **Joining and reconnecting:** on the tick the client gets its `room_snapshot` (a join, a reconnect, a seat taken over), the server forgets what it had sent it: every car in the area is spawned in that frame, and nothing is despawned. **A client clears its traffic on every `room_snapshot`**, before reading the rest of the frame.
- A placement (respawn, rejoin) moves the centre: cars out of the new area are despawned, new ones spawned, in the next frame.

### Spawn entries

| Field | Value |
| --- | --- |
| `car_id` | See "Car ids" |
| `vehicle` | The sim's `type_id`: index into `types` of the exported `traffic_params.json` (`TrafficRegistry` type order) |
| `color` | `color_index`: the biome palette index the car was drawn with (the section's palette, as the client's `Flow` draw) |
| `profile` | `profile_id`: index into `profiles` (driver profile) |
| `lane` | The current lane on the wire (see "Lanes") |
| `s_mm`, `d_cm`, `speed_cms` | Position (wrapped into `[0, L)`), lateral offset (+ right of travel), speed along the road, at the frame's tick |
| `lc_phase` | `none`, `signaling` (blinker on, not moving yet) or `moving` |
| `lc_target_lane` | The lane-change target on the wire; 0 when `none` |
| `lc_move_start_tick` | The room tick the lateral move starts (`signaling`) or started (`moving`); 0 when `none` |
| `lc_duration_ms` | The move time; 0 when `none` |
| `flags.hazard` | Hazards on (a hit reaction; the 3b intents say for how long) |
| `flags.braking` | Brake lights (the sim's brake flag: decelerating harder than `brake_light_decel_mps2`) |

Not sent: the model variant (pick one per `car_id` on the client), headlights (the room clock's night turns them on for every car), the blinker side (it follows from `d` and the target lane).

### Intents

| `kind` | When | `start_tick` | `move_start_tick` | `target_lane` | `duration_ms` |
| --- | --- | --- | --- | --- | --- |
| `lane_change` | A car signals (MOBIL, a merge, a ramp exit) | Blinker on: this tick | The tick the lateral move starts: **≥ `start_tick` + 20** (the 1.0 s minimum signal; 21 ticks in practice) | Target on the wire (7 = the off-ramp) | The move time |
| `cancel` | The signalled change is off (a player entered the gap, a hesitant driver, the move became unsafe). Only while signalling: it can arrive with `start_tick = move_start_tick` of the change (the last check failed): the car never moved on the server, so a client that already started the move goes back (corrections follow) | This tick | = `start_tick` | 0 | 0 |
| `hazard` | A hit reaction starts (first hit, or hit again while recovering) | This tick | = `start_tick` | 0 | Hazards on for this long: the rest of the recovery (`hit_recover_s` 4 s minus one tick) |
| `hard_brake` | With a `hazard` for the same car in the same batch: the hit's hard brake. Alone: a cut-in brake tap (a player cut in closer than `cut_in_brake_tap_distance_m`) | This tick | = `start_tick` | 0 | Brake for this long: the rest of `hit_brake_s` (1 s; 950 ms) or `brake_tap_s` (500 ms). Decelerate at `hit_brake_decel_mps2` (hit) or `brake_tap_decel_mps2` (tap) |
| `horn` | Never sent: horns stay client-side (spec: "traffic reactions like horns ... are not networked") | | | | |

**The lane-change curve** (the sim's, `tick_moving`): no lateral motion before `move_start_tick` M. At room tick t ≥ M, u = min(1, (t − M) × 0.05 s / duration); d(t) = d0 + (d_target − d0) × u² (3 − 2u), with d0 = the car's `d` at M and d_target the target lane's centre. From the first tick with u ≥ 1 the car is at d_target; its lane becomes the target one tick later and the blinker goes off. A car spawned `moving` is on this curve already (back out d0 from the spawn's `d`, or blend to the curve).

**Hit reactions** (the sim's `notify_hit`, called by N6 through `RoomTraffic::hit_car` once a hit is accepted): the car swerves away from the hitting player (`hit_swerve_m` 0.5 m out and back over `hit_swerve_s` 1.2 s), brakes hard and shows hazards. The protocol has no swerve kind (PROTOCOL.md §12), so the swerve reaches clients as **corrections every tick** for the first 25 ticks after the hit, to every client that has the car.

### Corrections

Per client and car, `last_sent` is the room tick of the car's last scheduled correction. At each tick, after the frame's spawn and intent corrections:

- a car within **100 m** of the player (|Δ| ≤ `traffic_near_m`) is corrected when `now − last_sent ≥ 4` ticks (**5 Hz**, `traffic_near_hz`);
- any other car when `now − last_sent ≥ 20` ticks (**1 Hz**, `traffic_far_hz`);
- a car in the first 25 ticks of a hit reaction, every tick.

So no car goes more than 4 ticks (near) or 20 ticks (far) without a correction, and a car coming within 100 m is corrected within 4 ticks. The spawn and intent corrections come on top and do not move the schedule. **Phase spread:** a car's schedule starts at its spawn as `last_sent = spawn tick − (car_id mod 20)`, so the 1 Hz corrections of a freshly joined client's 40–90 cars spread over the second instead of landing on one tick.

An entry is `{car_id, s_mm, d_cm, speed_cms}` at the batch's tick, quantized as PROTOCOL.md §3 (d rounded to 1 cm and clamped to ±100 m, speed to 1 cm/s).

### Lanes

On the wire, `lane`, `lc_target_lane` and `target_lane` count from the right: **wire = n − 1 − sim lane**, where the sim lane counts from the median (0 = the fast lane, as the client's `TrafficSim`) and **n = `lane_count` of the road-space file at the car's `s_mm` in the same frame** (the spawn entry's, or the car's correction's for an intent; the lane ranges step at each range's `s_start_mm`, `LoopMap::lane_count_at`). A sim lane ≥ n is **7** (MP-D6): an on-ramp car, an exit's target (the off-ramp pseudo-lane `lane_count(s)`), and a car still in a dropping lane where the range already counts one lane fewer. Back on the client: **7 → n**, else n − 1 − wire; the lane's d is the road-space lane centre (left edge + (lane + 0.5) × lane width). The round trip is exact for every sim lane ≤ n.

### Car ids

`car_id` is allocated per room when a car enters the ring (the fill, an on-ramp), from 1 (never 0: `hit_report.car_id` 0 means "not traffic"), and stays with that car while it is in the ring: a car that leaves a client's area and comes back is spawned again with the same id. When the car leaves the ring its id is released and **not handed out again for 30 s** (`traffic_car_id_hold_ms`; MP-D6); released ids come back oldest first, else a fresh id. The room maps the sim's `(slot, vehicle_id)` to the id every step, so a slot reused by a new car always gets a new id.

### Bytes

Measured (8 bots in one rush-hour room over real sockets, `rush_hour_downstream_stays_in_budget_with_8_bots`; every frame counted with its WebSocket header and a TLS record, PROTOCOL.md §11):

| Per player | Bytes/s |
| --- | --- |
| Everything on the wire (7 remote players' states, traffic, framing) | **5.1–5.3 KB/s** (budget 10 KB/s) |
| Traffic messages alone | about 1.4 KB/s: corrections ~1.15 KB/s (≈ 100 entries/s), spawns and despawns ~0.18 KB/s, intents ~0.05 KB/s |

Without sockets (`tests/traffic_stream.rs`, 8 players spread round the loop at 25–70 m/s, rush): 0.8–1.7 KB/s of traffic messages per player, 36–93 cars each. The first frame after a join carries the whole area: about 60 × (23 + 10) B ≈ 2 KB.

### Guarantees the tests pin

| Test | What |
| --- | --- |
| `tests/traffic_stream.rs` | No sockets: a rush ring with 8 players, every frame decoded into a `bots::TrafficMirror` every tick for 60 s: the mirror equals the server's set for that client, every car in the area is there, nothing past the hysteresis stays, near cars corrected within 4 ticks and the rest within 20, corrections carry the server's `s`, no violation (unknown ids, missing same-frame corrections, intent leads < 20 ticks); spawns' lanes, lane-change state and indices against the sim; intents reach every client that has the car at decision time; a hit streams `hazard` + `hard_brake` and per-tick corrections through the swerve, and a client joining mid-reaction gets the hazard with the time left; a reconnect resends the whole area; ids never reused within the hold while the ramps churn; determinism (same seed, same frames) |
| `tests/traffic_alloc.rs` | A counting allocator: 400 ticks of a rush room with 8 players, a hit and the ramps, streaming to all 8 frames: **0 allocations** |
| `tests/rooms.rs` | Over sockets: `traffic_mirrors_match_the_server_at_quiescent_points` (3 bots; the room's traffic wrapped in a probe that can pause it; at two quiescent points every bot's mirror equals the server's set, no violation, gaps ≤ 20 / ≤ 4 ticks, leads ≥ 20); `rush_hour_downstream_stays_in_budget_with_8_bots` (≤ 10 KB/s each, framing included); the bench |
| `rooms::car_ids::tests`, `rooms::traffic_stream::tests` | The 30 s hold under churn and across the tick wrap; wire lanes and their inverse; the fast wrapped distance against the map's |
| `tests/config.rs` | The `rooms.traffic_*` defaults, their conversion to ticks and their validation |

### Configuration

`[rooms]`:

| Key | Default | Meaning |
| --- | --- | --- |
| `traffic` | `sim` | `sim`: the ring runs and streams; `none`: no traffic |
| `traffic_aoi_behind_m` / `traffic_aoi_ahead_m` | `300.0` / `900.0` | The area of interest (spec) |
| `traffic_aoi_hysteresis_m` | `50.0` | A sent car stays until it is this much further out (not in spec) |
| `traffic_near_m` / `traffic_near_hz` / `traffic_far_hz` | `100.0` / `5` / `1` | Correction rates (spec); the periods are `tick_rate_hz / hz` ticks |
| `traffic_car_id_hold_ms` | `30000` | A released car id is not reused for this long (MP-D6) |

## Configuration reference

Configuration is layered: defaults, then the TOML file (`--config` / `WB_CONFIG`), then environment variables named `WB_<SECTION>__<KEY>` (double underscore). Each environment value is parsed as the key's type. Lists are comma-separated. Unknown keys or bad values in the file or the environment stop startup with every error listed. `RUST_LOG` overrides `log.level`. The defaults are production values: `config/server.example.toml` lists them all, and a test keeps it in sync.

| Key | Env | Default | Meaning |
| --- | --- | --- | --- |
| `server.env` | `WB_SERVER__ENV` | `production` | `production` or `dev`. Outside `dev` the two auth secrets are required; `dev` falls back to public development values when they are empty |
| `server.bind` | `WB_SERVER__BIND` | `0.0.0.0:8080` | Public listener (API, `/ws`, deep links) |
| `server.public_origin` | `WB_SERVER__PUBLIC_ORIGIN` | `https://westbound.sipsakrandevu.com` | Public https origin behind the proxy (invite links from N9) |
| `server.worker_threads` | `WB_SERVER__WORKER_THREADS` | `2` | tokio workers (spec: 2) |
| `server.shutdown_grace_ms` | `WB_SERVER__SHUTDOWN_GRACE_MS` | `5000` | On SIGTERM, time for in-flight requests and close frames |
| `server.restart_notice_secs` | `WB_SERVER__RESTART_NOTICE_SECS` | `0` | N10 hook: wait this long after SIGTERM before closing (the 60 s notice) |
| `log.level` | `WB_LOG__LEVEL` | `info` | tracing filter (`info,westbound_server=debug`) |
| `log.format` | `WB_LOG__FORMAT` | `text` | `text` or `json` (use `json` in Coolify) |
| `db.path` | `WB_DB__PATH` | `/data/westbound.db` | SQLite file (on the volume) |
| `db.max_connections` | `WB_DB__MAX_CONNECTIONS` | `4` | Pool size |
| `db.busy_timeout_ms` | `WB_DB__BUSY_TIMEOUT_MS` | `5000` | SQLite busy timeout |
| `db.migrate_on_start` | `WB_DB__MIGRATE_ON_START` | `true` | `serve` applies migrations first |
| `limits.max_message_bytes` | `WB_LIMITS__MAX_MESSAGE_BYTES` | `16384` | Largest inbound WebSocket message (spec: 16 KB) |
| `limits.outbound_queue_frames` | `WB_LIMITS__OUTBOUND_QUEUE_FRAMES` | `64` | Per-connection outbound queue; full = disconnect (spec: 64) |
| `limits.ping_interval_ms` | `WB_LIMITS__PING_INTERVAL_MS` | `2000` | Keepalive ping (spec: 2 s) |
| `limits.dead_after_ms` | `WB_LIMITS__DEAD_AFTER_MS` | `8000` | Close after this much silence (spec: 8 s) |
| `limits.max_rooms` | `WB_LIMITS__MAX_ROOMS` | `40` | Room cap (spec): a create or Quick Join past it answers `server_full` |
| `limits.max_connections` | `WB_LIMITS__MAX_CONNECTIONS` | `400` | WebSocket cap (spec) |
| `metrics.enabled` | `WB_METRICS__ENABLED` | `true` | Serve `/metrics` |
| `metrics.bind` | `WB_METRICS__BIND` | `127.0.0.1:9090` | Must be a loopback address |
| `backup.enabled` | `WB_BACKUP__ENABLED` | `true` | Nightly backup task |
| `backup.dir` | `WB_BACKUP__DIR` | `/data/backups` | Where dated backups go |
| `backup.time_utc` | `WB_BACKUP__TIME_UTC` | `03:17` | Nightly run time, UTC `HH:MM` |
| `backup.retention_days` | `WB_BACKUP__RETENTION_DAYS` | `7` | Dated files kept |
| `auth.jwt_secret` | `WB_AUTH__JWT_SECRET` | empty | **Required** outside dev. HS256 access-token secret, at least 32 bytes. Environment only, never logged. Changing it signs everyone out of their access tokens (clients refresh) |
| `auth.device_secret_pepper` | `WB_AUTH__DEVICE_SECRET_PEPPER` | empty | **Required** outside dev. HMAC key for device-secret hashes, at least 32 bytes, different from the JWT secret. Environment only. **Never change it** once accounts exist: their device secrets would stop verifying |
| `auth.access_token_ttl_secs` | `WB_AUTH__ACCESS_TOKEN_TTL_SECS` | `3600` | Access-token lifetime (spec: 1 h) |
| `auth.refresh_token_ttl_secs` | `WB_AUTH__REFRESH_TOKEN_TTL_SECS` | `2592000` | Refresh-token lifetime (spec: 30 days), renewed by each rotation |
| `auth.rename_cooldown_secs` | `WB_AUTH__RENAME_COOLDOWN_SECS` | `2592000` | Time between renames (spec: 30 days) |
| `http.cors_allowed_origins` | `WB_HTTP__CORS_ALLOWED_ORIGINS` | `https://westbound.sipsakrandevu.com,https://b3vet.github.io` | CORS allow-list for `/api/*`; `*` = any (local dev) |
| `http.max_body_bytes` | `WB_HTTP__MAX_BODY_BYTES` | `4096` | Largest JSON request body on `/api/*` (413 `body_too_large` above it) |
| `http.trusted_proxies` | `WB_HTTP__TRUSTED_PROXIES` | `127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7` | CIDRs whose `X-Forwarded-For` is believed; see "Client IPs behind the proxy" |
| `rate_limits.enabled` | `WB_RATE_LIMITS__ENABLED` | `true` | All HTTP rate limits (keep on in production) |
| `rate_limits.device_create_per_hour` / `_burst` | `WB_RATE_LIMITS__DEVICE_CREATE_PER_HOUR` / `__DEVICE_CREATE_BURST` | `5` / `5` | `POST /auth/device` per client IP |
| `rate_limits.auth_per_minute` / `_burst` | `WB_RATE_LIMITS__AUTH_PER_MINUTE` / `__AUTH_BURST` | `30` / `10` | The other `/auth/*` routes per client IP |
| `rate_limits.account_per_minute` / `_burst` | `WB_RATE_LIMITS__ACCOUNT_PER_MINUTE` / `__ACCOUNT_BURST` | `120` / `30` | Authenticated routes per account |
| `rate_limits.runs_per_hour` / `_burst` | `WB_RATE_LIMITS__RUNS_PER_HOUR` / `__RUNS_BURST` | `30` / `10` | Run submissions per account, on top of the account limit |
| `gateway.hello_timeout_ms` | `WB_GATEWAY__HELLO_TIMEOUT_MS` | `5000` | `Hello` must arrive within this (else `handshake_required`) |
| `gateway.tick_rate_hz` | `WB_GATEWAY__TICK_RATE_HZ` | `20` | Tick rate in `Welcome` and of the `Pong` clock (spec: 20 Hz) |
| `gateway.min_client_build` | `WB_GATEWAY__MIN_CLIENT_BUILD` | `0` | Older `Hello.client_build` gets `update_required` |
| `gateway.map_hashes` | `WB_GATEWAY__MAP_HASHES` | empty | Accepted map hashes (64 hex each, comma-separated in the env). Empty: any in dev; the built-in `loop_v1` hash in production (N3.2) |
| `gateway.ban_recheck_ms` | `WB_GATEWAY__BAN_RECHECK_MS` | `30000` | Live sessions re-checked for bans, deletion and revoked tokens |
| `gateway.fatal_close_delay_ms` | `WB_GATEWAY__FATAL_CLOSE_DELAY_MS` | `1000` | After a fatal `Error`, wait up to this for the client's close before closing |
| `gateway.echo_enabled` | `WB_GATEWAY__ECHO_ENABLED` | `true` | Serve `/ws/echo` |
| `ws_rate_limits.enabled` | `WB_WS_RATE_LIMITS__ENABLED` | `true` | Per-connection message limits on `/ws` |
| `ws_rate_limits.<type>_per_sec` / `_burst` | `WB_WS_RATE_LIMITS__PING_PER_SEC` ... | see "Realtime gateway → Rate limits" | One bucket per client message type (`ping`, `lobby_command`, `player_state`, `score_claim`, `hit_report`, `run_event`, `quick_chat`, `room_host_command`) |
| `ws_rate_limits.violation_per_sec` / `_burst` | `WB_WS_RATE_LIMITS__VIOLATION_PER_SEC` / `__VIOLATION_BURST` | `5` / `100` | Drops allowed before a fatal `rate_limited` |
| `ws_rate_limits.notice_interval_ms` | `WB_WS_RATE_LIMITS__NOTICE_INTERVAL_MS` | `1000` | At most one non-fatal `rate_limited` notice per interval |
| `deeplinks.dir` | `WB_DEEPLINKS__DIR` | empty (image: `/data/well-known`) | Directory with `apple-app-site-association` and `assetlinks.json` |
| `leaderboards.*`, `runs.*` | `WB_LEADERBOARDS__…`, `WB_RUNS__…` | see "Leaderboards & runs API → Configuration" | Views, cache, replay trigger, legacy caps; plausibility thresholds |
| `replays.*` | `WB_REPLAYS__…` | see "Replays and verification → Configuration" | Replay files, size cap, the verifier command, the queue, retention |
| `rate_limits.social_per_hour` / `_burst` | `WB_RATE_LIMITS__SOCIAL_PER_HOUR` / `__SOCIAL_BURST` | `60` / `20` | Social writes per account, on top of the account limit (see "Social API") |
| `social.*` | `WB_SOCIAL__…` | see "Social API → Configuration" | Friend, request and block caps; crew size and invite codes; the report limit |
| `rooms.*` | `WB_ROOMS__…` | see "Rooms → Configuration" | Seats, holds and delays, spawns, the room clock, room queues, plausibility limits, room traffic |

The image sets `WB_SERVER__BIND`, `WB_DB__PATH`, `WB_BACKUP__DIR` and `WB_DEEPLINKS__DIR` to the values above. It needs no config file.

## Docker image

- **Base:** `gcr.io/distroless/static-debian12:nonroot`, with CA certificates, no shell and no libc.
- **Binary:** a static musl binary at `/usr/local/bin/westbound-server`, built with cargo-chef so that dependencies are cached in their own layer.
- **User:** runs as the non-root user `65532`.
- **Ports and volumes:** `EXPOSE 8080`, `VOLUME /data`.
- **Health check:** `HEALTHCHECK` runs `westbound-server healthcheck`.
- **Size** (as of N1.1): about 4 MB compressed (what a registry pull downloads), 17 MB unpacked. The stripped binary is 6.9 MB.

```sh
cd westbound-server
docker build --build-arg WB_BUILD=$(git rev-parse --short HEAD) -t westbound-server:local .
docker run --rm -p 127.0.0.1:8080:8080 -v westbound-data:/data -e WB_SERVER__ENV=dev westbound-server:local
# production-like: -e WB_AUTH__JWT_SECRET=$(openssl rand -hex 32) -e WB_AUTH__DEVICE_SECRET_PEPPER=$(openssl rand -hex 32)
docker exec <container> westbound-server backup /data/backups/manual.db
```

For a bind mount instead of a named volume, the host directory must be writable by uid 65532: `chown 65532:65532 <dir>`.

## CI (`.github/workflows/server.yml`)

The workflow runs only when `westbound-server/**` or the workflow file changes, on push and pull request, and it can be run by hand.

1. **`test`:**
   - Uses Rust 1.94 with `Swatinem/rust-cache`.
   - Runs `cargo fmt --check`, `cargo clippy --workspace --all-targets -D warnings` and `cargo test --workspace`, all with `SQLX_OFFLINE=true`.
2. **`image`** (after `test`):
   - Builds the image with buildx and the GitHub Actions layer cache.
   - Smoke-tests it: runs it, curls the health route, runs `healthcheck` inside the container, then checks that `docker stop` exits 0.
   - On pushes to `claude/game-implementation-phases-asl5jz` only, logs in to GHCR with `GITHUB_TOKEN` (`packages: write`) and pushes these tags:
     - `ghcr.io/<owner, lowercased>/westbound-server:edge`
     - `:claude-game-implementation-phases-asl5jz-<sha7>`

## Coolify setup

Coolify already has a GHCR registry token for the owner's other projects, so private pulls from `ghcr.io/b3vet/...` work. CI must have pushed the image at least once: see the Actions tab, workflow "Server".

1. **DNS.** Point an `A` (and `AAAA`, if the VPS has IPv6) record for `westbound.sipsakrandevu.com` at the VPS, before the first deploy, so the proxy can get a certificate.
2. **New resource.** Go to Project, then **+ New**, then **Docker Image**. Image: `ghcr.io/b3vet/westbound-server`, tag `edge`. Pick the server or destination that has the GHCR credentials.
3. **Domain and port.** Under General:
   - Set **Domains** to `https://westbound.sipsakrandevu.com`.
   - Set **Ports Exposes** to `8080`.
   - Leave **Ports Mappings** empty. The proxy reaches the container over Coolify's network.
4. **WebSockets.** No extra setting. Coolify's proxy, Traefik or Caddy, passes `Upgrade` requests through, so `wss://westbound.sipsakrandevu.com/ws` reaches the container on the same domain. Don't add path rules: the server answers `/api/*`, `/ws` and `/.well-known/*` itself, and returns 404 for everything else.
5. **Persistent storage.** Go to Persistent Storage, then **+ Add**, then **Volume**. Name it `westbound-data` and set the destination path to `/data`. The database, `/data/backups` and `/data/well-known` all live there. A new named volume inherits the image's ownership (uid 65532).
6. **Environment variables:**
   - `WB_LOG__FORMAT=json`
   - `WB_AUTH__JWT_SECRET=<openssl rand -hex 32>`: mark it as a secret. **Required from N1**: without it the server refuses to start (`invalid config`).
   - `WB_AUTH__DEVICE_SECRET_PEPPER=<openssl rand -hex 32>`, a different value: mark it as a secret. **Required from N1.** Back it up with the database: if it is lost or changed, no device secret verifies again. Clients could still refresh, but a reinstall could not recover its account.
   - `WB_HTTP__TRUSTED_PROXIES` can stay at its default. Coolify's proxy reaches the container from a private Docker network, which the default ranges cover. See "Client IPs behind the proxy".
   - Optionally `WB_SERVER__PUBLIC_ORIGIN` and `WB_HTTP__CORS_ALLOWED_ORIGINS` (`https://westbound.sipsakrandevu.com,https://b3vet.github.io`). Both default to these values.
7. **Health check.** The image's own `HEALTHCHECK` (`westbound-server healthcheck`, a GET of `/api/v1/health` on port 8080) is what Docker and Coolify report, and the proxy starts routing once it is healthy.
   - Coolify's UI health check runs `curl`/`wget` inside the container, and this image has neither. Leave Coolify's own health check **disabled**. If you enable it, the settings are: path `/api/v1/health`, port `8080`, scheme `http`, expected status `200`.
   - If the container shows *unhealthy* with `curl: not found` in the health log, turn Coolify's check back off.
8. **Stop grace.** Coolify stops containers with SIGTERM. The server closes every socket with a close frame (1001), checkpoints the WAL and exits well within Docker's default 10 s.
   - N10's 60 s restart notice will need a longer stop timeout.
   - The compose file already sets `stop_grace_period: 30s`.
9. **Deploy.** Check the logs for a `listening` line with the version and build. Open `https://westbound.sipsakrandevu.com/api/v1/health`.
10. **Updates.** Each CI push moves the `edge` tag. Redeploy in Coolify, or enable its webhook / auto-update, to pull the new image. Roll back by deploying a `claude-game-implementation-phases-asl5jz-<sha7>` tag.

Deploying with Docker Compose works too: create the resource from `westbound-server/docker-compose.yml` (service `westbound-server`, same domain and port). The compose file carries the volume, environment, health check and stop grace. Its `caddy` service is in the `local-tls` profile and is not started.

## Backups and restore

- **Nightly:** at `backup.time_utc` (UTC), the server writes `/data/backups/westbound-YYYY-MM-DD.db`.
  - The copy is taken online with `VACUUM INTO`, written to a `.tmp` file and then renamed.
  - Dated files older than `backup.retention_days` (7) are deleted.
  - Each run is logged, recorded in `admin_log` and counted in `wb_backups_ok_total` / `wb_backups_failed_total`.
- **Off the machine:** add Coolify's volume backups (Persistent Storage, then Backups) or copy `/data/backups` elsewhere.
- **Manual:** `docker exec <container> westbound-server backup /data/backups/manual-$(date +%F).db` (from Coolify: the resource's **Terminal**, or the host shell).

To restore:

1. Stop the resource in Coolify.
2. Replace the database from a backup. Coolify volumes are named `<resource-uuid>_westbound-data` or similar: `docker volume ls`.

   ```sh
   docker run --rm -v <volume>:/data busybox sh -c \
     'cp /data/westbound.db /data/westbound.db.before-restore 2>/dev/null; \
      cp /data/backups/westbound-2026-09-28.db /data/westbound.db; \
      rm -f /data/westbound.db-wal /data/westbound.db-shm; chown 65532:65532 /data/westbound.db'
   ```
3. Start the resource. Migrations newer than the backup are applied on start.
4. Check `/api/v1/health`.

## Verify a phone connects

1. On the phone, open `https://westbound.sipsakrandevu.com/api/v1/health`. Expect `{"status":"ok",...,"db":"ok"}` over a valid certificate.
2. On the phone, open `https://westbound.sipsakrandevu.com/api/v1/echo-check`. The page opens `wss://westbound.sipsakrandevu.com/ws/echo` and sends 1024 bytes. Then it sends a token-less `Hello` to `/ws` and shows **OK: echo over wss://.../ws/echo in N ms; gateway answered Error map_mismatch** (`auth_failed`: the page sends no token; before N3.2 it was `map_mismatch`). Try it on Wi-Fi and on cellular.
3. From a desktop, run the same echo with Godot's `WebSocketPeer` (no `--insecure` against the real certificate):

   ```sh
   tools/godot.sh --headless --script res://tools/net_echo_check.gd -- --url=wss://westbound.sipsakrandevu.com/ws/echo
   node tools/web_smoke/ws_echo.mjs --server https://westbound.sipsakrandevu.com
   ```

   `ws_echo.mjs` runs the page on a local origin, so the CORS fetch passes only if `WB_HTTP__CORS_ALLOWED_ORIGINS` allows it. Use `--server` against a local server, or set `*` temporarily.
4. Watch the server side. The logs show a `websocket closed` line per connection, with the reason. For the counters, run `docker run --rm --network container:<container> curlimages/curl -s localhost:9090/metrics` on the host; the metrics listener is on the container's loopback.

## Troubleshooting

- **`invalid config:` at start.** The message lists every bad key. Run `check-config` with the same environment.
- **502 or 404 from the proxy.** Check that the container is *healthy* (`docker ps`), that Ports Exposes is `8080`, and that the domain matches exactly.
- **WebSocket closes with 1009.** A client sent more than 16 KB in one message.
- **WebSocket closes with 1008.** The gateway sent a fatal protocol `Error` first; the close reason is its code (`map_mismatch`, `auth_failed`, `banned`, `not_allowed` for a replaced session, `rate_limited`, ...). `wb_ws_handshakes_total{result}` and `wb_ws_kicks_total{reason}` count them.
- **Every `Hello` gets `map_mismatch` in production.** `gateway.map_hashes` is empty or does not list the client's map (see "Realtime gateway → Map hashes").
- **Clients dropped under load.** Check `wb_ws_slow_client_closed_total` (outbound queue full) and `wb_ws_timeout_closed_total` (silence over 8 s).
- **Reading `/metrics`.** The endpoint listens on the container's loopback only. Share the container's network namespace to read it: `docker run --rm --network container:<c> curlimages/curl -s localhost:9090/metrics`. For health, run `docker exec <c> westbound-server healthcheck`.
