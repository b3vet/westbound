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

## Routes

| Route | Listener | What |
| --- | --- | --- |
| `GET /api/v1/health` | public `:8080` | `{"status":"ok","version":"0.1.0","build":"<sha>","db":"ok"}`. Returns 503 with `"status":"degraded"` when the database does not answer |
| `GET /ws` | public | The realtime gateway: binary protocol frames (docs/PROTOCOL.md), `Hello` first. See "Realtime gateway". Limits: 16 KB max inbound message (close 1009), a 64-frame outbound queue (a slow client is dropped), a ping every 2 s, and a close after 8 s of silence. Past 400 connections, the upgrade gets HTTP 503 |
| `GET /ws/echo` | public | Ops echo of text and binary frames, same limits and connection cap. `gateway.echo_enabled = false` turns it off (404) |
| `GET /api/v1/echo-check` | public | A small HTML page, used to check a phone (see "Verify a phone connects"): runs the echo on `/ws/echo`, then sends a token-less `Hello` to `/ws` and shows the gateway's `Error` (`map_mismatch` or `auth_failed`) |
| `GET /.well-known/apple-app-site-association`, `GET /.well-known/assetlinks.json` | public | Deep-link files, read from `deeplinks.dir`, with built-in empty placeholders |
| `/api/v1/auth/*`, `/api/v1/me`, `/api/v1/account` | public | Accounts: see "Accounts API" |
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
| `admin ban <id> <duration>` | Bans an account for `30m`, `12h`, `7d`, `2w`, or `perm`. See "Admin CLI" |
| `admin unban <id>` | Lifts a ban |
| `admin rename <id> <name>` | Force-renames an account |

Every command reads the same config: `--config` or `WB_CONFIG`, then the `WB_*` environment variables.

### Database, migrations and sqlx offline data

- **Engine:** SQLite in WAL mode, with `synchronous=NORMAL`, foreign keys on and a busy timeout.
- **Times:** stored as unix seconds.
- **Secrets and tokens:** stored only as hashes.
- **Tables:**
  - Migration `0001` creates `accounts`, `refresh_tokens` and `admin_log`.
  - `0002` adds `accounts.token_version` and rebuilds `refresh_tokens` with its rotation state (`family`, `rotated_from`, `used_at`, `revoked_at`).
  - The other data-model tables come with their milestones.

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
   - `lobby_command` → non-fatal `not_allowed` ("The lobby is not available yet") until N9.
   - `room_host_command` → non-fatal `not_in_room` until N5.
   - `player_state`, `score_claim`, `hit_report`, `run_event`, `quick_chat` → dropped quietly until N5 (no room).
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

**N3** provides `loop_v1`'s hash. Add it with `WB_GATEWAY__MAP_HASHES=<hash>` in Coolify, or in `config/`. To keep an old client build working during a map update, list both hashes. Until N3, the owner can try the live check against production by setting `WB_GATEWAY__MAP_HASHES=0000000000000000000000000000000000000000000000000000000000000000` (the all-zero hash the tool sends by default) and removing it again afterwards.

### Clock (`Pong`)

`Pong` = `client_time_ms` (echoed), `server_tick`, `tick_fraction` (1/65536 tick): `server_now = server_tick + tick_fraction / 65536`. There are no rooms yet, so the clock is **server-wide**: `tick.rs`'s `MonotonicTickClock`, at `gateway.tick_rate_hz` (20 Hz) since process start. The tick wraps at 2^32 (6.8 years). Tests inject a `ManualTickClock` (`AppState::with_clocks`).

**N5 seam:** `gateway::pong_clock(state, session)` is the one place that picks the clock. N5 returns the session's room clock while the session is in a room (PROTOCOL.md: the room tick). A client joining a room calls `NetClock.reset()` anyway.

### Sessions and the duplicate-login policy

`Sessions` (`sessions.rs`, in `AppState.sessions`) maps account id → `SessionHandle`: session id, account, token version, the connection's **bounded** outbound queue, and a kick signal. The lobby (N5/N9) finds a player's connection there.

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
- In one transaction, deletes the account and its refresh tokens.
- `accounts::delete` lists the tables later milestones add to that transaction: friends, blocks, crew memberships, leaderboard entries, runs and replays, reports, and Apple token revocation.
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
| `/me`, `/account` (and later authenticated routes) | account | 120 per minute, burst 30 |

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
```

- **`rename`:**
  - applies the name rules and the filter, but not the cooldown;
  - keeps the tag when it is free for the new name;
  - restarts the player's 30-day cooldown.
- **Bans:**
  - A ban applies from the next request: HTTP routes return `403 banned`, and the WebSocket `Hello` gets `banned`.
  - Open WebSocket sessions are dropped within `gateway.ban_recheck_ms` (30 s): the gateway re-checks every live session against the database and sends a fatal `banned` (see "Realtime gateway → Bans").

### Local runs

- `config/dev.toml` sets `server.env = "dev"`, so no secrets are needed.
- The Docker image defaults to `production`. For `deploy/local-tls.sh` and `docker compose`, pass `WB_SERVER__ENV=dev`, or real `WB_AUTH__JWT_SECRET` and `WB_AUTH__DEVICE_SECRET_PEPPER` values.

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
| `limits.max_rooms` | `WB_LIMITS__MAX_ROOMS` | `40` | Room cap (spec; enforced once rooms exist, N5) |
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
| `gateway.hello_timeout_ms` | `WB_GATEWAY__HELLO_TIMEOUT_MS` | `5000` | `Hello` must arrive within this (else `handshake_required`) |
| `gateway.tick_rate_hz` | `WB_GATEWAY__TICK_RATE_HZ` | `20` | Tick rate in `Welcome` and of the `Pong` clock (spec: 20 Hz) |
| `gateway.min_client_build` | `WB_GATEWAY__MIN_CLIENT_BUILD` | `0` | Older `Hello.client_build` gets `update_required` |
| `gateway.map_hashes` | `WB_GATEWAY__MAP_HASHES` | empty | Accepted map hashes (64 hex each, comma-separated in the env). Empty: any in dev, none in production. N3 adds `loop_v1`'s |
| `gateway.ban_recheck_ms` | `WB_GATEWAY__BAN_RECHECK_MS` | `30000` | Live sessions re-checked for bans, deletion and revoked tokens |
| `gateway.fatal_close_delay_ms` | `WB_GATEWAY__FATAL_CLOSE_DELAY_MS` | `1000` | After a fatal `Error`, wait up to this for the client's close before closing |
| `gateway.echo_enabled` | `WB_GATEWAY__ECHO_ENABLED` | `true` | Serve `/ws/echo` |
| `ws_rate_limits.enabled` | `WB_WS_RATE_LIMITS__ENABLED` | `true` | Per-connection message limits on `/ws` |
| `ws_rate_limits.<type>_per_sec` / `_burst` | `WB_WS_RATE_LIMITS__PING_PER_SEC` ... | see "Realtime gateway → Rate limits" | One bucket per client message type (`ping`, `lobby_command`, `player_state`, `score_claim`, `hit_report`, `run_event`, `quick_chat`, `room_host_command`) |
| `ws_rate_limits.violation_per_sec` / `_burst` | `WB_WS_RATE_LIMITS__VIOLATION_PER_SEC` / `__VIOLATION_BURST` | `5` / `100` | Drops allowed before a fatal `rate_limited` |
| `ws_rate_limits.notice_interval_ms` | `WB_WS_RATE_LIMITS__NOTICE_INTERVAL_MS` | `1000` | At most one non-fatal `rate_limited` notice per interval |
| `deeplinks.dir` | `WB_DEEPLINKS__DIR` | empty (image: `/data/well-known`) | Directory with `apple-app-site-association` and `assetlinks.json` |

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
2. On the phone, open `https://westbound.sipsakrandevu.com/api/v1/echo-check`. The page opens `wss://westbound.sipsakrandevu.com/ws/echo` and sends 1024 bytes. Then it sends a token-less `Hello` to `/ws` and shows **OK: echo over wss://.../ws/echo in N ms; gateway answered Error map_mismatch** (production has no map hash until N3; `auth_failed` once one is configured). Try it on Wi-Fi and on cellular.
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
