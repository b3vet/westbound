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

N9.3 adds the room-dependent social parts: parties (create, join by code, invites to online friends, leave, kick; the leader moves the party into rooms, Quick Join fits the whole party, a party is one crew in public rooms), blocked players kept out of Quick Join, the `/r/<code>` invite page and generated deep-link files. See "Parties (N9.3)" and "Invite links and deep links".

N4.4 + N10.1 add the netcode and load acceptance (see "Load test, shadow collisions and admin stats (N4.4, N10.1)" and [LOADTEST.md](LOADTEST.md)):

- the `bots` crate's full delay layer (per-direction delay, jitter and loss; TCP or datagram), the client's traffic model on bots (correction sizes, late intents) and the `loadtest` binary;
- shadow collision logging: contacts between players (with the disagreement of their views) to `shadow_contacts` and the metrics, sampled logs of those and of unreported / refused traffic contacts;
- the admin stats view: `GET /admin/stats` on the metrics listener, and `GET /admin/v1/stats/full` behind the admin token (N10.2's admin API); the peak memory on `/metrics`;
- 20 rooms × 8 bots in Docker at 1 vCPU: 38 % of the core, tick p99 ≤ 3 ms, 100 MB, 5.1 KB/s per player.

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

N10.2 adds operations (see "Operations (N10.2)" and the owner's runbook [`OPERATIONS.md`](OPERATIONS.md)):

- the admin API (loopback, token) and the full admin CLI: player lookup by `name#tag`, ban reasons, player deletion, live rooms and room close, notices, kicks, board recompute, stats, the admin log;
- the planned restart: a 60 s `server_notice{restart}`, draining, the room handover (runs end with their banked score, rooms come back by code on the next instance), close 1012, and the client's countdown and rejoin;
- backups verified after writing, `restore` and `verify-backup`, an optional off-site hook;
- a rate-limit review (per IP on every route and upgrade, `room_create` per account) with the full table;
- request ids, JSON logs in the image, and metrics for the database, queues, backups, restarts, errors and the process.

N10.3 adds housekeeping for the small data volume (see "Housekeeping (N10.3)" and OPERATIONS.md → Disk space):

- at most **3 daily backups** (`backup.retention_days` is now a count), a stale-backup check (`backup.max_age_hours`, 26 h), manual backups and restore leftovers aged out, and backups that skip instead of filling the disk;
- a disk check every 5 minutes: free space and what the database, WAL, replays and backups take (`wb_disk_*`, the `disk` section of the admin stats, `admin stats`), a low-space floor (`housekeeping.min_free_mb`, 500 MB), and a WAL checkpoint;
- a daily pass: `shadow_contacts` (30 days), `admin_log` (365 days), handled reports (365 days), past Daily Drive days and Journey weeks (90 days), runs holding no board entry (90 days), the expired handover file, and a `VACUUM` when a large share of the file is free;
- replay files: set-aside jobs get their own status (`set_aside`, migration `0007`) and lose their file after 30 days (`admin replay-purge-set-aside` by hand); only a **current** top 100 keeps a verified replay.

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
| `GET /api/v1/health` | public `:8080` | `{"status":"ok","version":"0.1.0","build":"<sha>","db":"ok"}`. Returns 503 with `"status":"degraded"` when the database does not answer, and (N10.2) with `"status":"draining"` during a planned restart's notice |
| `GET /ws` | public | The realtime gateway: binary protocol frames (docs/PROTOCOL.md), `Hello` first. See "Realtime gateway". Limits: 16 KB max inbound message (close 1009), a 64-frame outbound queue (a slow client is dropped), a ping every 2 s, and a close after 8 s of silence. Past 400 connections, the upgrade gets HTTP 503 |
| `GET /ws/echo` | public | Ops echo of text and binary frames, same limits and connection cap. `gateway.echo_enabled = false` turns it off (404) |
| `GET /api/v1/echo-check` | public | A small HTML page, used to check a phone (see "Verify a phone connects"): runs the echo on `/ws/echo`, then sends a token-less `Hello` to `/ws` and shows the gateway's `Error` (`map_mismatch` or `auth_failed`) |
| `GET /.well-known/apple-app-site-association`, `GET /.well-known/assetlinks.json` | public | Deep-link files: `deeplinks.dir` wins, else generated from the configured app ids (N9.3), else built-in empty placeholders. See "Invite links and deep links" |
| `GET /r/{code}` | public | N9.3: the invite page for a room or party code (opens the web build with `?room=<code>`; store links). See "Invite links and deep links" |
| `/api/v1/auth/*`, `/api/v1/me`, `/api/v1/account` | public | Accounts: see "Accounts API"; N11 Apple / Google: see "Sign in with Apple / Google" |
| `GET /api/v1/save`, `PUT /api/v1/save` | public | N11 cloud save: see "Cloud save" |
| `GET /api/v1/boards/{board}`, `POST /api/v1/runs`, `POST /api/v1/runs/legacy` | public | Leaderboards and run submissions: see "Leaderboards & runs API" |
| `POST /api/v1/runs/{run_id}/replay` | public | The replay upload (binary body): see "Replays and verification" |
| `/api/v1/friends*`, `/api/v1/blocks*`, `/api/v1/presence`, `/api/v1/crews*`, `/api/v1/reports` | public | Friends, blocks, presence, crews (and crew invites: `/api/v1/crews/invites*`, `/api/v1/crews/{id}/invites`), reports: see "Social API" |
| `GET /metrics` | **localhost only** `127.0.0.1:9090` | Prometheus text: `wb_ws_connections`, `wb_ws_frames_in_total` / `_out_total`, bytes, close reasons, the gateway's `wb_ws_sessions`, `wb_ws_handshakes_total{result}`, `wb_ws_messages_in_total{type}`, `wb_ws_rate_limited_total{type}`, `wb_ws_kicks_total{reason}` (see "Realtime gateway → Metrics"), `wb_http_requests_total{class}`, `wb_http_rate_limited_total`, `wb_accounts_created_total`, `wb_auth_logins_total`, `wb_auth_refreshes_total`, `wb_auth_refresh_reuse_total`, backups, `wb_build_info`; the rooms' metrics; N10.2's database, queue, backup, restart, admin, log and process metrics (see "Operations (N10.2) → Metrics added"); N10.1: `process_resident_memory_peak_bytes`, the shadow contacts (see "Rooms → Metrics") |
| `/admin/v1/*` | **localhost only** `127.0.0.1:9091`, only with `WB_ADMIN__TOKEN` | N10.2: the admin API (bearer token): stats, live rooms, room close, notices, kicks. See "Operations (N10.2) → Admin API" |
| `GET /admin/stats` | **localhost only** (the metrics listener) | N10.1: the admin stats view, JSON (see "Load test, shadow collisions and admin stats"); the same as `GET /admin/v1/stats/full` on the admin API |

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
| `admin replay-purge-set-aside [--older-than 30d]` | N10.3: deletes the files of `set_aside` jobs uploaded longer ago; their runs stay "verifying" |
| `admin housekeeping` | N10.3: runs the daily housekeeping pass and the replay sweep now and prints what they did |
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
  - `0006` (N10.1) creates `shadow_contacts` (see "Load test, shadow collisions and admin stats → Shadow collisions").
  - `0007` (N10.3) moves set-aside replay jobs (`failed` with `"unverifiable": true`) to the new status `set_aside` (see "Replays and verification → The queue").
  - `0008` (N11) creates `identity_links`, `device_secrets` and `cloud_saves` (see "Sign in with Apple / Google → Tables" and "Cloud save").
  - `0009` creates `crew_invites` (see "Social API → Crew invites").

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

`deploy/Caddyfile` runs Caddy with `tls internal` on `https://localhost:8443`. It proxies `/api/*`, `/ws`, `/.well-known/*` and `/r/*` (N9.3 invite links) to the server. `deploy/local-tls.sh` starts both:

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
   | 1 | `protocol_version` below / above `1..=2` (protocol 2 added room and crew invites; a version 1 client is still welcome but never sent a version 2 kind: PROTOCOL.md §6) | `update_required` / `server_outdated` |
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
   - Protocol 2: `room_invite` → the seated player's room invite (see "Room invites").
   - A seated session's `player_state`, `run_event`, `hit_report`, `quick_chat` and `room_host_command` → its room task (a non-blocking `try_send` into the room's bounded queue; a full queue drops the message, `wb_room_dropped_total{reason="queue_full"}`). Outside a room: `room_host_command` and `room_leave` answer a non-fatal `not_in_room`, the rest is dropped quietly.
   - `score_claim` → dropped until N6.
   - A second `Hello`, or an undecodable frame → fatal `malformed`.
6. **Replies.** Everything one inbound frame causes goes out as one outbound frame.
7. **Fatal errors.** The gateway sends the `Error`, then waits for the client to close, up to `gateway.fatal_close_delay_ms` (1 s), and then sends a close frame (1008 with the error code as the reason; 1011 for `internal`). Without the wait, a client that reads the error and the close in the same socket read can lose the error. Godot's `WebSocketPeer` does: it goes straight to `STATE_CLOSED` with no packet available, so the player would see "connection closed" instead of "please update". `NetClient` closes as soon as it reads a fatal error, so it never waits.
8. **Keepalive.** The protocol crate's `Keepalive`: the server sends a WebSocket ping every `limits.ping_interval_ms` (keeps proxies and NATs open; clients answer on their own) and closes with 1001 after `limits.dead_after_ms` without receiving anything. Clients send protocol `Ping`s every 2 s (`Welcome.ping_interval_ms`).
9. **Shutdown.** After a planned restart's notice and handover (N10.2, see "Operations (N10.2) → The planned restart") every socket gets its queued frames and then close **1012** (service restart: reconnect); a shutdown without the restart sequence (tests) closes with 1001.

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
| `lobby_command` | 5 | 10 | room invites have their own per-sender limit too (`social.room_invites_per_minute`) |
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

N1.1 implemented device accounts (MP-D2); N11 adds Sign in with Apple / Google (next section) and per-device credentials. All routes are under `/api/v1`, take and return JSON, and are covered by CORS for the web build.

### Tokens and secrets

| Thing | Form | Lifetime | Stored as |
| --- | --- | --- | --- |
| Device secret | 32 random bytes, base64url (43 chars) | Forever (per account) | HMAC-SHA256 with the server pepper. Returned once, by `POST /auth/device`; N11: a provider sign-in returns one for that device (`device_secrets`, at most `identity.max_device_secrets` per account, the least recently used dropped) |
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
| 501 | `provider_not_enabled` | Apple / Google routes while that provider has no client ids (N11) |
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
- N11, in the same transaction: the cloud save, `identity_links` and `device_secrets`. After the commit, the player's Sign in with Apple grant is **revoked** with Apple when one is stored and the Apple key is configured (best effort, logged; see "Sign in with Apple / Google → Apple revocation"). The admin CLI's `admin delete` does not revoke yet (it has no HTTP client): an open item.
- Logs `account_delete` to `admin_log` with the account id and row counts only.

**`POST /api/v1/auth/device/login`** also accepts a device secret from `device_secrets` (N11: a provider sign-in on another device).

**Apple / Google** (`/auth/providers`, `/auth/nonce`, `/auth/signin/{provider}`, `/auth/link/{provider}`, `/auth/unlink/{provider}`): see the next section.

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
| other `/auth/*` (incl. N11 `providers`, `nonce`, `signin/*`) | client IP | 30 per minute, burst 10 |
| N11 `POST /auth/link/*`, `/auth/unlink/*`, `GET /save` | account | under the account limit below |
| N11 `PUT /save` (also) | account | `cloud_save.writes_per_hour` 120, burst 30 |
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

Admin commands run inside the container against the live database, from Coolify's **Terminal** or `docker exec`. Each prints one line, exits non-zero on failure, and is logged to `admin_log` with actor `cli`. N10.2 accepts `name#1234` wherever an account id is taken, adds `--reason` to `ban` and many more commands: see "Operations (N10.2) → Admin CLI (full)".

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
  - Open WebSocket sessions are dropped within `gateway.ban_recheck_ms` (30 s): the gateway re-checks every live session against the database and sends a fatal `banned` (see "Realtime gateway → Bans"). N10.2: with the admin API on, `admin ban` ends the session at once.

### Local runs

- `config/dev.toml` sets `server.env = "dev"`, so no secrets are needed.
- The Docker image defaults to `production`. For `deploy/local-tls.sh` and `docker compose`, pass `WB_SERVER__ENV=dev`, or real `WB_AUTH__JWT_SECRET` and `WB_AUTH__DEVICE_SECRET_PEPPER` values.

## Sign in with Apple / Google (N11)

WP N11, in `crates/server/src/identity/`: `mod.rs` (the verifier, `Identity`), `jwks.rs` (the providers' keys), `nonce.rs`, `apple.rs` (client secret, code exchange, revocation), `seal.rs` (tokens at rest), `store.rs` (the tables), `routes.rs`. Spec: multiplayer handoff → "Accounts and authentication" (Sign in with Apple / Google; account deletion with Apple revocation); plan MP-D2. The owner's setup: OPERATIONS.md → "Sign in with Apple / Google". Tests: `tests/identity.rs` (a fake provider on loopback: a JWKS issuer signing with test-only keys in `tests/data/idp_rsa_{a,b}.der`, Apple's token and revoke endpoints checking the client secret against `apple_test_key.p8`).

**Off until configured.** A provider is enabled when its client ids are set (`identity.google_client_ids`, `identity.apple_client_ids`). Without them every route for it answers `501 provider_not_enabled` (MP-D2's shape), and `GET /auth/providers` says `enabled: false`.

### ID tokens

The client gets an ID token (a JWT) from the provider's own sheet and sends it with the nonce. The server accepts it only when:

- it is RS256-signed by a key in the provider's JWKS (`identity.google_jwks_url`, `identity.apple_jwks_url`; see "Keys");
- `iss` is the provider (`identity.google_issuers`: both `https://accounts.google.com` and `accounts.google.com`; `identity.apple_issuer`);
- `aud` is one of that provider's client ids (web, iOS, Android); a list `aud` needs one of them;
- `exp` is in the future and `iat` not in the future, on the server clock with `identity.clock_skew_secs` (60 s) of leeway;
- `nonce` is a nonce this server issued (`POST /auth/nonce`), unexpired (`identity.nonce_ttl_secs`, 600 s), and the token's `nonce` claim is it or its SHA-256 (hex or base64url: Apple's native convention). Required unless `identity.require_nonce = false`;
- `sub` is non-empty (at most 255 bytes) and the token at most `identity.max_id_token_bytes`.

**Email.** Neither the address nor the name is stored. A masked hint (`j***@gmail.com`) is kept for the account screen when the address is verified; Apple's `email_verified` / `is_private_email` may arrive as booleans or as `"true"` / `"false"`, and a Hide My Email address (`…@privaterelay.appleid.com` or `is_private_email`) shows as "private email" with no hint.

**Nonces** are stateless: `base64url(16 random bytes ‖ expiry ‖ 16-byte HMAC)` under a key derived from the pepper. They are not single-use: the conflict flow sends the same token to `/link` and then `/signin`.

### Keys (JWKS)

Fetched with `reqwest` (rustls, bundled roots), cached for the response's `Cache-Control: max-age` clamped to `identity.jwks_cache_min_secs ..= jwks_cache_max_secs` (5 min to 24 h). An unknown `kid` (key rotation) refetches at most once per `identity.jwks_refetch_min_secs` (60 s), so made-up kids cannot become a stream of fetches. When a fetch fails, the old keys keep working (stale-if-error) and the next try waits the same interval; with no usable key the answer is `503 provider_unavailable`, never "invalid token". Outbound calls time out after `identity.http_timeout_ms` and never follow redirects.

### Routes

**`GET /api/v1/auth/providers`** (public): what the client may offer; no secrets.

```json
{"apple": {"enabled": true, "client_id": "com.b3vet.westbound.web", "redirect_uri": "https://b3vet.github.io/westbound/"},
 "google": {"enabled": true, "client_id": "1234-abc.apps.googleusercontent.com"},
 "nonce_required": true,
 "cloud_save": {"enabled": true, "max_bytes": 65536}}
```

**`POST /api/v1/auth/nonce`**: `{"nonce": "…", "expires_at": 1790000600}`.

**`POST /api/v1/auth/signin/{apple,google}`** (no bearer). Body: `{"id_token": "…", "nonce": "…", "authorization_code": "…"}` (the code: Apple only, optional; see "Apple revocation").

- The identity's account, or a **new account** with a generated name when the identity has none (`201`, `"created": true`; else `200`).
- The answer is a device sign-in's (`account_id`, the access and refresh tokens, `profile`) plus `device_secret` for **this device** (shown once; stored hashed in `device_secrets`, or as the new account's first secret) and `created`. The device then renews exactly like a device account (`/auth/device/login`).
- A banned account: `403 banned`. The lookup and the creation run in one `BEGIN IMMEDIATE` transaction: two first sign-ins with one identity cannot make two accounts.

**`POST /api/v1/auth/link/{apple,google}`** (bearer; same body): adds the identity to the caller's account, so its progress is kept. Answers the profile.

- Already linked to the caller: `200` (idempotent; the hint is refreshed).
- The identity belongs to **another account**: `409 identity_in_use` with both accounts' summaries, so the client can ask which to keep:

```json
{"error": "identity_in_use", "message": "…",
 "conflict": {"provider": "google",
   "current": {"account_id": "57", "full_name": "DustyComet#0311", "created_at": …, "last_seen": …,
               "linked": {"apple": false, "google": false}, "runs": 3, "best_score": 41000, "cloud_save": null},
   "other":   {"account_id": "42", "full_name": "Şahin 34#0042", …, "runs": 120, "best_score": 2010000,
               "cloud_save": {"revision": 7, "updated_at": …, "bytes": 3120, "xp": 374522, "runs": 57}}}}
```

  To switch, the client calls sign-in with the same token (accounts are never merged: the spec's "merging accounts is out of scope for v1"; the *save* is merged by the client, SAVE.md → Cloud sync). `cloud_save.xp` / `runs` are `stats.xp` / `stats.runs` of the stored document (read with SQLite's `json_extract`; the server does not otherwise look inside saves).
- The caller already has a different identity of that provider: `409 provider_already_linked`.

**`POST /api/v1/auth/unlink/{apple,google}`** (bearer, no body): removes it; answers the profile. `404 not_linked`; `409 last_sign_in_method` when it would leave the account no way in (no other provider and no device credential on the server). Unlinking Apple revokes the stored Apple grant.

**Profile.** `GET /me` and every answer carrying a profile now include `identities`: `[{"provider": "google", "email_hint": "j***@gmail.com", "private_email": false, "linked_at": …}]` (`linked` stays as it was).

**Errors** (all `{error, message}`): `400 invalid_nonce`, `401 invalid_id_token` (signature, issuer, audience, claims, malformed), `401 id_token_expired`, `403 banned`, `404 not_found` (an unknown provider) / `not_linked`, `409 identity_in_use` / `provider_already_linked` / `last_sign_in_method`, `501 provider_not_enabled`, `503 provider_unavailable`.

### Apple revocation

Apple requires apps that support account creation and deletion to revoke the user's Sign in with Apple tokens on deletion. Revocation needs a token Apple issued to us (the ID token is not one), so:

- At sign-in or link with Apple, when the client sends `authorization_code` and the key is configured (`identity.apple_team_id`, `apple_key_id`, `apple_private_key` or `apple_private_key_file`), the server exchanges the code at `identity.apple_token_url` (with the web Services ID's `apple_web_redirect_uri` for the web client) and keeps the **refresh token sealed** in `identity_links.apple_refresh_sealed` with the `aud` it was issued to (`apple_client_id`). A refused exchange is logged and the sign-in goes on.
- `DELETE /account` and `POST /auth/unlink/apple` post it to `identity.apple_revoke_url` (`token_type_hint=refresh_token`).
- Both calls authenticate with a **client secret**: an ES256 JWT signed with the `.p8` key, `kid` = key id, `iss` = team id, `aud` = Apple's issuer, `sub` = the client id, valid 5 minutes, made per call.
- Without the key both steps are skipped: sign-in works, revocation is a logged no-op (`Apple grant not revoked: no Apple key configured`). The key is checked at startup (a test signature), so a bad one stops the server rather than failing at the first deletion.
- **Sealing:** `version ‖ 16-byte nonce ‖ ciphertext ‖ 16-byte tag`; the keystream is HMAC-SHA256 in counter mode, the tag an HMAC over the rest (encrypt-then-MAC), both keys derived from the pepper. A leaked database alone does not reveal the tokens.

### Tables

| Table | Columns | Notes |
| --- | --- | --- |
| `accounts` | `apple_sub`, `google_sub` (0001, `UNIQUE`) | The identity's subject: one Apple and one Google identity per account, each on at most one account |
| `identity_links` | `account_id`, `provider`, `email_hint`, `private_email`, `linked_at`, `last_used_at`, `apple_client_id`, `apple_refresh_sealed` | One row per linked identity; deleted with the account |
| `device_secrets` | `secret_hash` (HMAC like `device_secret_hash`), `account_id`, `created_at`, `last_used_at` | Per-device credentials from provider sign-ins |

### Configuration (`[identity]`)

| Key | Env | Default | |
| --- | --- | --- | --- |
| `identity.google_client_ids` | `WB_IDENTITY__GOOGLE_CLIENT_IDS` (comma-separated) | `[]` (off) | Accepted `aud`s: Web, iOS, Android OAuth clients |
| `identity.google_web_client_id` | `WB_IDENTITY__GOOGLE_WEB_CLIENT_ID` | `""` = the first | The web build's |
| `identity.google_issuers`, `google_jwks_url` | | Google's | |
| `identity.apple_client_ids` | `WB_IDENTITY__APPLE_CLIENT_IDS` | `[]` (off) | The Services ID (web) and the bundle id (iOS) |
| `identity.apple_web_client_id`, `apple_web_redirect_uri` | `WB_IDENTITY__APPLE_WEB_…` | `""` | The web build's Services ID (default the first) and its registered return URL |
| `identity.apple_issuer`, `apple_jwks_url`, `apple_token_url`, `apple_revoke_url` | | Apple's | https only (http on a loopback host, for tests) |
| `identity.apple_team_id`, `apple_key_id` | `WB_IDENTITY__APPLE_TEAM_ID`, `…_KEY_ID` | `""` | 10-character Apple ids |
| `identity.apple_private_key` | `WB_IDENTITY__APPLE_PRIVATE_KEY` (**secret**, redacted in `check-config`) | `""` | The `.p8` PEM; literal `\n` read as newlines |
| `identity.apple_private_key_file` | `WB_IDENTITY__APPLE_PRIVATE_KEY_FILE` | `""` | Or a path to the `.p8` |
| `identity.require_nonce` | | `true` | |
| `identity.nonce_ttl_secs` | | 600 | |
| `identity.clock_skew_secs` | | 60 | |
| `identity.jwks_cache_min_secs`, `jwks_cache_max_secs`, `jwks_refetch_min_secs` | | 300, 86400, 60 | |
| `identity.http_timeout_ms` | | 5000 | JWKS, Apple token / revoke |
| `identity.max_device_secrets` | | 10 | Per account |
| `identity.max_id_token_bytes` | | 4096 | |

## Cloud save (N11)

WP N11, `crates/server/src/save.rs`. The local save follows the player between devices; the merge rules are the client's (SAVE.md → Cloud sync): the server stores the document it is given, whole, and never merges. Tests: `tests/cloud_save.rs`.

**`GET /api/v1/save`** (bearer): `{"revision": 7, "updated_at": 1790000000, "bytes": 3120, "data": {…}}`, or `{"revision": 0, "updated_at": null, "bytes": 0, "data": null}` when the account has none. `ETag: "7"`, `Cache-Control: no-store`.

**`PUT /api/v1/save`** (bearer) with `If-Match: "<the revision it replaces>"` (`"0"` for the first) and `{"data": {…}}`:

- `200 {"revision": 8, "updated_at": …, "bytes": …}` and `ETag: "8"`;
- `409 revision_conflict` when the revision moved on (another device wrote first), with the server's copy in `save` (`{revision, updated_at, bytes, data}`) so the client merges and tries again;
- `428 precondition_required` without `If-Match`; `400 invalid_body` when `data` is not an object; `413 save_too_large` (with `max_bytes`) over `cloud_save.max_bytes`;
- `501 cloud_save_not_enabled` when `cloud_save.enabled = false`.

The read and the write run in one `BEGIN IMMEDIATE` transaction, so two devices writing on the same revision cannot both win. CORS allows `PUT` and `If-Match` and exposes `ETag` for the web build.

**Storage and disk.** `cloud_saves (account_id PRIMARY KEY, revision, data TEXT, bytes, updated_at)`: one row per account, replaced on each write; old revisions are not kept. The size cap (64 KB; the local save is a few KB) is also the per-account disk cap. Same database: the nightly backups, restores and `DELETE /account` cover it.

| Key | Env | Default | |
| --- | --- | --- | --- |
| `cloud_save.enabled` | `WB_CLOUD_SAVE__ENABLED` | `true` | |
| `cloud_save.max_bytes` | `WB_CLOUD_SAVE__MAX_BYTES` | 65536 | 1 KB to 1 MB |
| `cloud_save.writes_per_hour`, `writes_burst` | `WB_CLOUD_SAVE__WRITES_PER_HOUR`, `…_BURST` | 120, 30 | `PUT` per account, on top of the account limit |

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

- **N6, multiplayer runs** (called since N6.1 through `leaderboards::mp_runs::run_sink` for every verified run; see "Scoring (N6.1) → Run results and the boards"): `state.boards.record_multiplayer_run(&MultiplayerRun { account_id, map_id, room: Public | PrivateDefault | PrivateCustom, score, duration_s, distance_m, stats, car, client_build, ended_at, crew })`. It stores the run as `verified`. For a ranked room it writes Loop (the season of `ended_at`, and all-time), and with `crew: Some(CrewSnapshot { crew_id, member_ids })` the crew's Loop crew score: the sum of the best `crew_top_members` members' season entries, rewritten when it changes. It returns the run id, `ranked`, the placements and the new crew score.
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
5. **N8.3, set aside** (build parity): a job this worker cannot verify is not retried against the same verifier. It becomes `set_aside` (N10.3; before, `failed`) at once with `{"error": ..., "unverifiable": true, "build": N}` as its result (a `replay cannot be verified by this verifier; set aside` warning), the run stays "verifying" and the file is kept. That is: (a) the command names a per-build file that is not there: an argv entry made from a `{build}` template that is an absolute path (`/verifier/{build}/westbound`) and does not exist; nothing is run; (b) the verifier's "cannot verify" (exit 3 with a result `error`: another tuning under the same build number, a replay without inputs under `--require-inputs=1`, an unknown car). **Every worker start** (`run`) puts those jobs back to `pending` with their attempts reset (a `replay jobs set aside as unverifiable were requeued` line): a new verifier image may have their build. Other `failed` jobs wait for `admin replay-requeue`. (Exit 3 without a result stays an ordinary failed attempt.)

An upload wakes the worker at once; otherwise it looks every `poll_interval_secs` (30 s). On start, jobs a stopped worker left `running` go back to `pending` (the lost attempt counts). Exactly one worker may run against a database: either the in-server one or one `verify-worker`.

**No verifier configured** (`verifier_command = []`, the default and the server image's): the worker is not started (the log says so once at startup), uploads are stored, jobs stay `pending` and their runs stay `pending` ("verifying") on the boards. Configure a verifier later and the backlog is verified oldest first. N8.2 made honest replays verifiable (the verifier re-simulates from the recorded inputs: 6 of 6 honest 11-minute runs accepted, REPLAY_FORMAT.md → Honest replays). N8.3 ships the sidecar image from CI (below) with `--require-inputs=1`: replays from N8.1 clients (no input stream; their kinematic playback rejects long honest runs) are set aside, never judged, so `runs.supported_builds` need not exclude them (N8.1 and N8.2 clients share build 1). Production enablement: OPERATIONS.md → Replay verification.

### Retention

- **After a verdict:** a `done` job's file is deleted unless its run ranks within `keep_top_n` (100) on some board in a **current** period right now (N10.3: the day, ISO week or season containing now, or all-time; a past Daily Drive day no longer keeps its top 100's files, so the kept files stay bounded); a rejected run holds no entries, so its file always goes. The row stays with `file_deleted_at`.
- **Every `cleanup_interval_secs` (1 h):** kept files are checked again (a run that fell out of every current top 100 loses its file), and files in `replays.dir` and its `work/` older than an hour that no job needs are deleted (stray `.wbr`, temporary uploads, result files).
- **N10.3, set aside:** a `set_aside` job keeps its file for `set_aside_retention_days` (30) after the upload; then the sweep deletes the file, sets `file_deleted_at` and adds `purged_at` to the result. The row stays `set_aside` (no worker start requeues it) and the run stays "verifying". `admin replay-purge-set-aside --older-than 7d` does the same by hand.
- `pending`, `running` and `failed` jobs keep their files. Deleting a run (`admin remove-run`) or an account deletes its replays and files.
- Uploads answer **503 `storage_low`** (with `Retry-After`) while the data volume is below `housekeeping.min_free_mb`; the game keeps the replay and retries.

### Tables

`replays` (0003, queue columns from 0005):

| Column | |
| --- | --- |
| `run_id` | primary key, the run (cascade on delete) |
| `file_path` | `<replays.dir>/<run_id>.wbr` |
| `status` | `pending`, `running`, `done`, `failed`, `set_aside` (N10.3: no verifier here has the job's build; requeued at every worker start) |
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
| `keep_top_n` | `100` | Verified replays of runs ranked within this in a current period keep their files |
| `cleanup_interval_secs` | `3600` | The retention sweep |
| `set_aside_retention_days` | `30` | N10.3: set-aside replays lose their file this long after the upload (runs stay "verifying"); 0 keeps them |

### Running the verifier (build parity, the 1 GB cap, Coolify)

The verifier is a headless build of the **same game build** as the client whose runs it checks (spec: build parity): `tools/verifier/verify_replay.gd` run by that build's Godot binary and pack. It checks the replay's tuning hash against its own and answers "cannot verify" (exit 3, never a verdict; N8.3: the job is set aside, see "The queue") when they differ. With several builds accepted (`runs.supported_builds`), keep one exported verifier per build and let the command pick it: `/verifier/{build}/westbound` (N8.2); a build without its directory is set aside without running anything (N8.3).

**N8.3: the image in CI** (`.github/workflows/verifier.yml`, on pushes to the integration branch that touch the game, `tools/verifier/` or the server): `tools/verifier/export_verifier.sh` exports this commit's verifier for `NetTuning.client_build` and verifies a fresh 20 s replay with it; `tools/verifier/carry_builds.sh` adds the older client builds' verifiers from the previous `:edge` image (the newest three build numbers in all; `/verifier/BUILDS.txt`) and warns when the previous verifier of the same build number rejects this commit's replay (a simulation change without a `client_build` bump); the `westbound-server` binary is built from the same commit's source (not pulled as `:edge`: the server image only rebuilds on `westbound-server/` changes and may not be pushed yet when both change in one push); `tools/verifier/smoke_image.py` then runs the server image and the verifier image on one volume and uploads four replays through the API (honest → verified, teleported → rejected `path_mismatch`, an inflated claim → rejected `score_mismatch`, an unknown build → set aside, the run still verifying) before `ghcr.io/<owner>/westbound-verifier:{edge,<branch>-<sha7>}` is pushed. The image also carries `verify-backlog`, a read-only dry run over `/data/replays` (OPERATIONS.md → Replay verification).

Locally (from `westbound-server/`, with the editor binary):

```sh
WB_REPLAYS__VERIFIER_COMMAND='nice,-n,10,../tools/godot.sh,--headless,--path,..,--script,res://tools/verifier/verify_replay.gd,--,--replay={replay},--out={out},--seed={seed},--claimed-score={claimed_score},--claimed-hits={claimed_hits}' \
    cargo run -p server -- --config config/dev.toml
cargo test -p server --test replays -- --ignored end_to_end   # records a run with Godot, verifies it through a real server
```

The server image is distroless and static (no shell, no `nice`, no glibc), and a Godot export needs glibc, so the verifier cannot run inside today's image. **N8.2 built option 1** (DETERMINISM.md → Verifier deploy): `tools/verifier/export_verifier.sh` (the `Verifier (Linux headless)` export preset, requested in the N8.2 handoff; a smoke test that verifies a fresh replay with the exported binary exactly as the worker will), `westbound-server/verifier/Dockerfile` (the image) and `westbound-server/verifier/docker-compose.verifier.yml` (the sidecar service with `mem_limit: 1g`, `cpus: 1`, the server's worker off). N8.3 builds it in CI (above), adds `docker-compose.coolify.yml` (server and sidecar in one Compose resource) and the production steps (OPERATIONS.md → Replay verification: recommended, a second Coolify Docker Image resource on the server's volume). The options as N8.1 described them:

1. **Sidecar (recommended, built in N8.2).** A second image, `westbound-verifier:<build>`: `debian:bookworm-slim` + the Godot Linux export template + the game's `.pck` per supported build + the `westbound-server` binary. In the Coolify compose it runs `westbound-server verify-worker` on the **same `/data` volume** (SQLite in WAL mode works across containers on one host), with `mem_limit: 1g` (the cgroup `memory.max`, the spec's systemd `MemoryMax`) and `cpus: 1`, and `WB_REPLAYS__VERIFIER_COMMAND=nice,-n,10,/verifier/{build}/westbound,--headless,--,--verifier=1,--server=off,--replay={replay},--out={out},--seed={seed},--claimed-score={claimed_score},--claimed-hits={claimed_hits},--require-inputs=1` (N8.3 added `--require-inputs=1`; N8.2: export templates ignore `--script` and `--main-pack`, so the pack sits next to the binary and `--verifier=1` hands the main scene over to the verifier; the debug template, the 4.7 release template crashes booting the project headless). The server gets `WB_REPLAYS__WORKER_ENABLED=false`. The cap covers only the verifier; an OOM kill is a failed attempt, retried. Board caches in the server pick up verdicts within `leaderboards.cache_ttl_secs` (60 s), as with the admin CLI.
2. **Same container.** Rebase the server image on `debian:bookworm-slim` with the template and packs, and let the in-server worker run `nice -n 10 prlimit --data=1073741824 ...`. One container to deploy, but the image grows from about 4 MB to about 100 MB, and the memory cap is either the whole container's (server and verifier together) or an rlimit (`--data`; `--as` would break Godot's address-space reservations).

Measured on this dev box: a 4-minute replay verifies in 10–20 s and peaks at about 225 MB resident, so a 10-minute run takes under a minute and the 1 GB cap leaves room.

### Tests

`tests/replays.rs`: the upload (auth, not the owner, unknown run, stored once and idempotent with no temp files left, only when the receipt asked (a lower second run, a plausibility-rejected run), header checks (garbage, truncated, run id, seed, mode, date, build), the size cap and the large default); the queue with a stand-in verifier script: an accepted verdict (run and entries `verified`, the placeholders, a top-1 replay kept), a rejected one (off the board, file deleted), a verifier that runs over (killed at the timeout, retried after the delay, then `failed` with the run still verifying), a failed attempt retried (exit status and output tail in the error), a result that contradicts the exit status, restart recovery, N8.3's set-aside jobs (a build without its verifier directory: nothing run, no retry loop, back to pending when a worker starts; exit 3 with a result: set aside at once, not retried against the same verifier; other failed jobs stay failed), the real server's worker running three jobs strictly one at a time and oldest first, the no-verifier mode; retention (top N keeps, a run pushed out loses its file, orphans older than an hour); account deletion; `end_to_end_with_the_godot_verifier` (`#[ignore]`, about 15 s: needs Godot). `tests/cli.rs`: `admin replays`, `admin replay-requeue`. `tests/config.rs` keeps `server.example.toml` equal to the defaults.

## Social API

WP N9.1, in `crates/server/src/`: `social/` (`mod.rs`: the shared reads `friend_ids`, `crew_of`, `crew_snapshot`, `is_blocked`, player summaries and the account-deletion hook; `friends.rs`: requests, the friends list, blocks, presence reads; `crews.rs`: crews, roles, invite codes; `reports.rs`), `presence.rs` (the presence registry), and the gateway's `presence_subscribe` handling. Spec: multiplayer handoff → "Rooms, parties and matchmaking → Friends and presence", "Crews (persistent)", "Moderation", "Leaderboards → Loop crew", "Data model (SQLite)", "Accounts → Account deletion". Tests: `tests/social.rs` (every route and error, blocking, caps, crews, boards, deletion, reports, admin), `tests/presence.rs` (real WebSockets), `tests/cli.rs` (the admin binary), `tests/crew_invites.rs` (crew invites: every route and error, renewal, the pending cap, any member inviting friends only, blocks, crew full, already in a crew, expiry and the housekeeping pass, removal on join / disband / account deletion of either side, the live event to protocol 2 sessions only, member presence).

Public rooms, Quick Join, the room browser and quick chat came with N5.1. Parties, invites, blocked players kept out of Quick Join and the invite links are N9.3: see "Parties (N9.3)" and "Invite links and deep links".

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
4. A database error while subscribing answers a non-fatal `internal` ("Friends presence is unavailable. Try again."). Party commands go to the parties (N9.3); room commands go to the rooms (N5.1).

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

Members are listed owner first, then officers, then members, each by join time. `invite_code` and `your_role` are `null` for non-members. Each member also carries `status` (`offline`, `online`, `in_room`, from the gateway's sessions and the rooms) when you are a member of that crew (the client's room invite list shows online crewmates), else `null`.

### Crew invites

The owner's request "there is no way to invite my friends to my crew". A crew member invites a **friend**; the invite waits (persistent, so an offline friend sees it later) until it is accepted, declined or expires. Spec: Crews (persistent) ("You join by an invite code": an invite brings the crew to the friend instead of the code), Friends and presence (blocking).

- **Who may invite: any member.** Every member already sees and shares the invite code (above), so an invite gives no new power; restricting invites to the owner and officers would only make members share the code by hand instead.
- **Whom:** an accepted friend of the sender, not blocked either way (blocking ends the friendship; the refusal is the same `not_friends` and does not reveal a block), not already in this crew. Someone in another crew can be invited; accepting asks them to leave theirs first (`already_in_crew`, as the join by code).
- **One invite per crew and player.** Inviting again renews it (`200`, a fresh expiry, the new sender); a new one answers `201`. A crew has at most `social.crew_max_pending_invites` (32) unexpired invites out.
- **Expiry:** `social.crew_invite_ttl_hours` (168, 7 days) after the (last) invite. Every read ignores expired rows; the daily housekeeping pass deletes them.
- **Accepting** joins with the join-by-code checks (`already_in_crew`, `crew_full`, the Loop crew recompute) and deletes the invite. Accepting an invite to the crew you are already in just clears it. An invite whose sender is blocked either way is hidden from the list and refused (`invite_not_found`).
- **Removed** on accept, decline, a join by code to that crew, disbanding (also `ON DELETE CASCADE`), and account deletion of either the invitee or the sender (`social::on_account_delete`).
- **Live:** when the invitee has a gateway session on a protocol 2 client, they get `lobby_event.crew_invite {invite_id, crew_tag, crew_name, from, expires_in_s}` at once (PROTOCOL.md §4); otherwise they see it in `GET /crews/invites` (the crew page, the online hub).
- **Limits:** `POST /crews/{id}/invites` and `/crews/invites/{id}/accept` are social writes (`rate_limits.social_per_hour`), on top of the account limit. `wb_crew_invites_total` counts invites sent.

| Route | Answer | Errors |
| --- | --- | --- |
| `POST /crews/{id}/invites` `{"account_id"}` | `201` (new) / `200` (renewed) `{"invite_id", "player", "from", "created_at", "expires_at"}` | 400 `cannot_invite_self`, `invalid_body`; 403 `not_friends`; 404 `not_in_crew` (you), `player_not_found`; 409 `already_member`, `crew_full`, `crew_invites_limit` |
| `GET /crews/{id}/invites` | `{"invites": [{"invite_id", "player", "from", "created_at", "expires_at"}]}`: the crew's unexpired invites, newest first (members only: INVITED in the client) | 404 `not_in_crew` |
| `GET /crews/invites` | `{"invites": [{"invite_id", "crew_id", "crew_name", "crew_tag", "member_count", "max_members", "from", "created_at", "expires_at"}]}`: the invites waiting for you, newest first | |
| `POST /crews/invites/{invite_id}/accept` | the crew (you joined) | 404 `invite_not_found` (unknown, expired, not yours, or the sender is blocked either way); 409 `already_in_crew`, `crew_full` |
| `POST /crews/invites/{invite_id}/decline` | `204` | 404 `invite_not_found` |

`player` and `from` are the player objects of "Friends" (`from` is `null` only in a race with the sender's account deletion).

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
- It deletes the `crew_invites` to the account and the ones it sent (`admin_log` detail `crew_invites=`).
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

Migration `0009_crew_invites.sql`:

- `crew_invites`: `id` (the invite id; AUTOINCREMENT: an answered invite's id is never reused), `crew_id` (cascades with the crew), `account_id` (the invitee; cascades), `inviter_id` (`ON DELETE SET NULL`; the account deletion deletes the row first), `created_at`, `expires_at`. UNIQUE (`crew_id`, `account_id`): one invite per crew and player. Indexed by (`account_id`, `expires_at`) for the invitee's list, `inviter_id` for the deletion, and `expires_at` for the housekeeping pass.

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
| `party_max_members` | `8` | N9.3: members per party, the leader included (spec: up to 8; ≤ 16 on the wire) |
| `party_member_hold_ms` | `15000` | N9.3: a member whose connection ended keeps their place this long (not in spec) |
| `room_invite_ttl_secs` | `120` | Room invites: how long an invite shows on the invitee's screen, and how long a repeat invite of the same player to the same room is refused (10–3600; not in spec) |
| `room_invites_per_minute` | `10` | Room invites one player may send in any rolling minute (refused ones don't count; spec: rate-limited) |
| `crew_invite_ttl_hours` | `168` | Crew invites expire this long after the (last) invite (1–8760; not in spec) |
| `crew_max_pending_invites` | `32` | Unexpired invites one crew may have out at once (not in spec) |

`[rate_limits]`: `social_per_hour` / `social_burst` (`60` / `20`), the social writes per account.

## Parties (N9.3)

WP N9.3, in `crates/server/src/social/parties.rs` (the registry), the gateway's party commands and follow orders (`gateway.rs`), and the party-aware joins of `rooms/mod.rs` (`JoinOpts`) and `rooms/room.rs` (crew slots). Spec: multiplayer handoff → Rooms, parties and matchmaking → Parties ("Up to 8 players, led by one player. The leader invites online friends, or shares a party code. The party moves between rooms together, and its members are each other's crew in public rooms"), Public rooms (Quick Join "fits your whole party"), Friends and presence (blocking), Crew mechanics. Wire: PROTOCOL.md §4 and §12, unchanged. Parties live only in memory.

**Commands** (`lobby_command`; refusals are non-fatal `error`s):

| Command | What happens | Refusals |
| --- | --- | --- |
| `party_create` | A new party with you as leader and a 6-character code (the room-code alphabet, unique among parties and live rooms). You leave any party you were in. Alone in a party already: its state again | |
| `party_join {code}` | You join (also how an invite is accepted); every member gets `party_state`. You leave any other party first. **If the leader is seated in a room, you follow into it** (a joined invite is an invite to the leader's room) | `party_not_found`, `party_full` (`social.party_max_members`, 8), `blocked` (you and a member blocked each other) |
| `party_invite {account_id}` | The leader invites an **online friend**: they get `lobby_event.party_invite {from, code}`. Without a party one is made for you first. Declining needs no message | `not_allowed` (not a friend, offline, already a member, yourself; blocking removes the friendship, so a blocked player lands here too), `not_party_leader`, `party_full` |
| `party_leave` | `party_left {left}` to you; the others get `party_state`. The leader's role passes to the longest-present connected member. An empty party closes | `party_not_found` |
| `party_kick {account_id}` | Leader only: `party_left {kicked}` to them | `not_party_leader`, `not_allowed` (yourself, not a member) |

`party_state` (code, leader, members in join order) goes to every connected member after every change, and to a member's new session right after `Welcome` (in the same frame). `party_left {disbanded}` is not sent (a party only closes when empty).

**Moving together** (a party of two or more):

- **The leader's joins move the party.** Quick Join needs a free seat for every connected member not already in that room (and never picks a room with an account blocked either way with one of them); a join by code or id refuses a room without those seats (`room_full`, "That room can't fit your whole party."); `room_create` makes the room. Once the leader is seated, every other connected member's connection gets a **follow order**: it leaves its room if it has one (`room_left {left}`) and takes a seat in the leader's room by id, as if it had sent `room_join_id` (errors, e.g. a full room, go to that member as non-fatal errors).
- **A member's Quick Join** goes to the leader's room; while the leader has none it is refused (`not_party_leader`, "Your party leader picks the room."). A member who creates or joins **any other** room (by code or id, not the leader's and not their own held seat) **leaves the party** (`party_left {left}`) and goes alone. Reconnects (joining the held seat's room by code) are not affected.
- **Crews.** In a public room a party is one crew: a join carries the party id and takes the crew slot of a seat of the same party, else a free slot (a player alone is a crew of one). Private rooms stay one crew. The slot is kept for the seat's life (leaving the party later does not change it).
- **Quick Join for everyone** (party or not) now skips rooms where an account blocked either way with the joiner (or a mover) is seated: spec, "a blocked player is never matched into your room through Quick Join". One query (`social::blocked_either`).

**Connections.** Each session gets a follow channel (4 orders) when it starts. When a member's connection ends their place is held for `social.party_member_hold_ms` (15 s): they stay in the party (not moved), a new session takes the place back and gets the state; after the hold they leave as with `party_leave` (the leader's role passes on). A replaced session (second login) never touches its successor.

**Concurrency.** One `std::sync::Mutex` over parties, codes, account → party and the follow channels; held for map updates and non-blocking `try_send`s (session queues, follow channels), never across an `.await`. Lock order: parties, then the session registry. The rooms registry and the presence hub are never taken under it (the gateway reads the leader's seat before or after).

**Tests:** `social::parties::tests` (lifecycle, leader passing, refusals, invites, the follow orders, holds), `rooms::tests::a_party_is_one_crew_in_a_public_room`, `tests/parties.rs` (real sockets: create / join / kick / leave and refusals; invites to online friends only, blocks for party joins and Quick Join; **Quick Join fitting a party of three**: a public room with 2 free seats is skipped and a new one made, the party one crew, a solo player then joins the fullest room with a crew of their own; the leader moving the party into a private room and on to a public one, a member joining the party while the leader is seated following at once, a member going alone leaving the party; a dropped member's place held and the state after the reconnect's `Welcome`), `tests/gateway.rs` (a party command outside a party).

## Room invites (protocol 2)

The owner's request "there is no way to invite my friends or crew into a private room in online mode". In `crates/server/src/gateway.rs` (`room_invite`), `social/room_invites.rs` (the in-memory limit and the invites still showing) and `social::can_invite`. Spec: Rooms, parties and matchmaking (Private rooms: "The creator gets a code and an invite link"; Friends and presence: "a blocked player ... cannot invite you"; Crews). Wire: `lobby_command.room_invite {account_id}` → the target's `lobby_event.room_invite {from, room_id, code, visibility, players, max_players, expires_in_s}` (PROTOCOL.md §4, version 2).

- **Who:** any player **seated** in a room (host or not; private or public: an invite is only the room's code, the same key as the link) invites an **online friend or member of their crew**. The invitee accepts with `room_join_code` and the code (so `room_full`, `room_not_found` and the party rules of a join by code apply); declining needs no message. The sender gets no acknowledgement; refusals are non-fatal `error`s with the reason as `detail` (the client shows it).
- **Checks, in order** (nothing about a stranger's presence leaks: the relationship comes before online):

  | Check | Refusal (`code`, `detail`) |
  | --- | --- |
  | seated in a room | `not_in_room`, "Join a room before inviting players to it." |
  | not yourself | `not_allowed`, "You can't invite yourself." |
  | an accepted friend or in the same crew, and no block either way (a crewmate who blocked you stays in the crew) | `not_allowed`, "You can only invite friends and crew members." |
  | online (a live gateway session) | `not_allowed`, "That player is offline." |
  | their client speaks protocol 2 | `not_allowed`, "That player's game needs an update to get room invites." |
  | not already in this room | `not_allowed`, "That player is already in this room." |
  | the room has a free seat | `room_full`, "Your room is full." |
  | not invited to this room within `social.room_invite_ttl_secs` (120 s) | `not_allowed`, "You already invited that player. Give them a moment." |
  | at most `social.room_invites_per_minute` (10) sent in any rolling minute | `rate_limited`, "Too many invites. Wait a minute and try again." |
  | (a database error) | `internal`, "Invites are unavailable right now. Try again." |

- **Expiry:** the event carries `expires_in_s` = `room_invite_ttl_secs`; the client drops the invite after it. The server forgets the pair after it (a repeat is then allowed). Nothing to delete: invites live in memory only (the registry drops expired entries on every call).
- **Concurrency:** one `std::sync::Mutex` in `RoomInvites`, held for the map updates only. The event goes to the target's bounded outbound queue (`SessionHandle::send_frame`; a full queue kicks that client, as for every lobby push).
- **Metrics / logs:** `wb_room_invites_total` (delivered); `room invite` INFO line (account, target, room).
- **Tests:** `social::room_invites::tests` (the repeat window, the rolling minute, expiry), `tests/room_invites.rs` (real sockets: a friend and a crewmate get the invite and join by its code, any seated player may invite; every refusal above, a protocol 1 client welcomed but never sent the event; the per-minute limit; a repeat allowed once expired, with a manual clock).

## Invite links and deep links

N9.3. Spec: "The creator gets a code and an invite link `https://<domain>/r/<code>`. The link opens the app through Universal Links (iOS) and App Links (Android), or the web build directly." MP-D1: the server serves the deep-link files itself.

- **`GET /r/{code}`** answers a small HTML page (no scripts): "JOIN K7QX2M", **PLAY IN THE BROWSER** (`deeplinks.web_join_url` with `{code}`, default `https://b3vet.github.io/westbound/?room={code}`; `{origin}` is `server.public_origin`, for a web build on another host that needs `&server=`), **OPEN THE APP** (`<deeplinks.app_scheme>://r/<code>`, only when a scheme is configured), and the App Store / Google Play links (`deeplinks.app_store_url`, `play_store_url`; "COMING SOON" while empty). The code is case-insensitive, dashes and spaces forgiven; any other path answers 404 with the same page saying the link is not valid. Everything configured is HTML-escaped; `Cache-Control: public, max-age=300`, `X-Robots-Tag: noindex`.
- The code can be a **room's or a party's** (party codes never equal a live room's). The client tries the room first, then the party (docs/ROOMS_CLIENT.md → Parties → Invite links).
- **Association files.** A file in `deeplinks.dir` wins. Without one, the file is generated from the config: `apple-app-site-association` from `deeplinks.apple_app_ids` (`TEAMID.bundle.id`; `components: [{"/": "/r/*"}]` plus the older `appID` / `paths` form), `assetlinks.json` from `deeplinks.android_package` and `deeplinks.android_cert_sha256`. Without ids, the built-in empty placeholders. `config/dev.toml` sets placeholder ids so the shapes show locally.
- **Proxies.** `deploy/Caddyfile` routes `/r/*`; on Coolify route `/r/*` and `/.well-known/*` to the container too (see "Coolify setup").
- **Tests:** `tests/http.rs` (`invite_links_serve_the_join_page`, `deep_link_files_come_from_the_configured_app_ids`, `deep_link_config_is_validated`).

**Owner steps** (can't be tested here):

1. iOS: set `WB_DEEPLINKS__APPLE_APP_IDS=<TEAMID>.<bundle id>`; in Xcode add the Associated Domains entitlement `applinks:westbound.sipsakrandevu.com`. Apple fetches `https://westbound.sipsakrandevu.com/.well-known/apple-app-site-association` (served as `application/json`, no redirect).
2. Android: set `WB_DEEPLINKS__ANDROID_PACKAGE` and `WB_DEEPLINKS__ANDROID_CERT_SHA256` (the Play app-signing certificate's SHA-256, `AA:BB:...`); the export's manifest needs an `intent-filter` with `android:autoVerify="true"`, scheme `https`, host `westbound.sipsakrandevu.com`, path prefix `/r/`.
3. The game gets the URL from the OS (a Godot plugin or the export's launch arguments) and passes it to `NetInviteLink.set_pending(NetInviteLink.from_url(url))`; a custom scheme (`WB_DEEPLINKS__APP_SCHEME=westbound`) is the fallback for when Universal Links don't fire (in-app browsers).
4. Store links: `WB_DEEPLINKS__APP_STORE_URL`, `WB_DEEPLINKS__PLAY_STORE_URL` once the apps are listed.

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
- **Events** (`SimEvent`, fixed-capacity buffer, cleared by `tick`): `Signal` is the intent: `tick` (blinker on), `move_start_tick` (the tick the lateral move starts: the curve's u = 0 there, so d(t) = d0 + (target - d0) · smoothstep((t - move_start) / duration)), `target_lane`, `target_d` and `duration_s` (the move time, drawn when the blinker comes on and rounded to whole ms since N4.2, so the wire's `duration_ms` is exactly the sim's; MP only: the parity configs draw it at the move). `will_cancel(slot)` (N4.2): a hesitant signal that will cancel at its end. `Cancel` ends a signal. `Hazards` (value 1 on / 0 off, tag `Hit`), `Horn` (blind spot, close pass) and `BrakeTap` (cut-in) are the client model's reactions; the handoff keeps horns client-side. `Spawned` / `Despawned` carry the slot and `vehicle_id`; tags `Ramp` (an on-ramp entry) and `Exit` (an off-ramp exit).
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
| `sim.rs` (`TrafficSim`) | `traffic_sim.gd` at the integration branch's `4b33c6c` (WP6.8 lane drops `aac617e`, WP6.9 weaving racers), plus WP6.10's `_sig_pre` and WP6.11's MP-D5 extensions (synced at WP6.11) | Same fields without the `_`, same functions in the same order: `spawn`, `despawn`, `notify_hit`, `honk`, `notify_close_pass`, `set_headlights`, `request_lane_change`, the set-piece hooks, closures (`add_lane_closure`, `merge_zone_frac`, `closure_ahead`, `_closure_wall_accel`, `_consider_merge`), lane-drop zones (`add_lane_drop_zone`, `lane_drop_limit_at`, `_drop_brake`, `_drop_tick`, `_update_drop_reach`, `_yield_accel`, `_zone_held`, `_collect_yield_candidates`, `_merge_gap_accel`), set-piece zones, `step`, `_step_accel`, `_step_lateral`, `_tick_signaling`, `_tick_moving`, `_tick_hit`, `_tick_reactions`, `_consider_lane_change`, `_consider_split`, `_consider_split_exit`, `_start_signal`, `_cancel`, `_eval_target`, `_eval_move`, the MP-D5 block (`_look_through_accel`, `_predicted_leaders_safe`, `_anticipation_accel`, `_leaving_path`), `_follower_accel`, the weaving block (`_init_weave`, `_cooldown_of`, `_weave_bonus`, `_weave_pace`, `_weave_cap_ok`, `_weave_note_change`), `_read_player`, `_sort`, `_refresh_interval`, `_emit_pending`. Not ported: WP6.1's passability (single-player only) |
| `population.rs` | `SpawnSources.Flow.draw_into` / `_eligible` / `_pick` | The server's own fill, ramps and density upkeep |
| `checker.rs` | `tests/fixtures/traffic/traffic_rule_checker.gd` (the rules) | Plus the intents |
| `rng.rs`, `trace_hash.rs` | `src/core/rng.gd` (Godot's PCG32 `RandomNumberGenerator`), `src/core/trace_hash.gd` | Bit-exact |
| `road.rs` | the `RoadPath` subset | Open road (parity) and the loop (wrap) |

**When `traffic_sim.gd` changes** (after WP6.11): diff it from the WP6.11 merge (the last sync: WP6.10's `_sig_pre` and the MP-D5 extensions are in both), apply the same change to the same function in `sim.rs` (mind the MP generalisations below: `self.is_player(j)` for `== _P`, `road.signed_delta(a, b)` for `b - a` between positions, the `next_k` / `prev_k` walks for `kk += 1` / `kk -= 1`), export new parameters in `tools/server_data/export_sim_data.gd` (and `TuningParams` / `ProfileParams`), re-run the exporter, then `cargo test -p sim --test parity`. The traces fail at the first tick where the two models differ.

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

### The MP-D5 safety extensions (in both models since WP6.11)

At rush-hour density the loop's lane drops (desert and city 4 → 3, canyon 3 → 2) queue up, and the client model then collides: over one simulated hour at rush, **11,622 ticks with traffic-to-traffic contacts** (33,162 pair-ticks, all real body overlaps; `soak_hour_rush_without_mp_extensions`). Light and normal hours were clean without them. Three mechanisms, each traced to a contact:

1. **Cut-out.** A car's new leader in the target lane is itself signalling out of it; once it leaves, a stopped queue is revealed that needs more than the 6 m/s² clamp.
2. **Stale lane-change decision.** MOBIL judges the new leader as if it holds its speed; by the time the car is in the lane (1.0 s signal on the server, 0.6 s for racers in single-player, plus the move) the leader, braking into the queue, has slowed too much.
3. **Late IDM reaction.** A racer at 180 km/h follows a car braking at the clamp into the queue; stock IDM ignores the leader's deceleration and reacts too late for 6 m/s².

The fixes (MP-D5). N4.1 built them here; WP6.11 ported them to `traffic_sim.gd` (`TrafficTuning.look_through_leaving_leaders`, `predict_leader_braking`, `anticipate_leader_braking`, all on; docs/TRAFFIC.md, *Lane-drop queue safety*), so the parity config (`SimConfig::single_player`, from `traffic_params.json`) runs them too and the traces check them. The server's own switches stay in `mp_traffic.json` (on):

| Flag | What |
| --- | --- |
| `look_through_leaving_leaders` | A leader signalling or moving to a target off the path does not hide what is ahead of it: following (IDM) and MOBIL's own safety also judge the next vehicle on the path (`look_through_accel`) |
| `predict_leader_braking` | MOBIL's own safety also judges each new leader extrapolated with its current deceleration to when the car is in the lane (signal time + half the minimum move time), against the car holding its speed (`predicted_leaders_safe`) |
| `anticipate_leader_braking` | When stopping s0 behind the leader's own stopping point (at its current deceleration) needs more than the profile's comfortable b, the follower brakes for it now (`anticipation_accel`); never beyond the clamp |

With them: **0 contacts at every density** and 0 clamp violations. The client's network model mirrors the look-through and the anticipation (docs/NET_TRAFFIC.md).

**WP6.11 changes to N4.1's version** (both models; docs/TRAFFIC.md, *Lane-drop queue safety*): `predicted_leaders_safe` judges only a **braking** leader (a leader holding its speed is what MOBIL's own check judged; the extrapolated approach alone refused every gap a car closed on, e.g. a racer within its WP6.9 traffic b_safe), and the prediction and `look_through_accel` use the car's own IDM toward that vehicle (a weaving profile's T / s0 / b toward traffic, WP6.9) instead of the ordinary parameters. Re-run on the WP6.11 tree (merged with N4.2): `soak_hour_{light,normal,rush}` **0 contacts, 0 violations** (rush: 94,882 signals, 83,984 moves, 10,872 cancels, 4,967 merges, 385 exits = entries; min blinker → motion 1.05 s); `soak_hour_rush_without_mp_extensions` (the three `MpTrafficRules` switches cleared explicitly) 30,329 contact ticks (N4.1 measured 11,622 before N4.2's whole-ms move times changed the traces). A variant that extrapolated only the leader's loss (not the car's approach) had 2,509 contact ticks at rush, so the approach term stays for braking leaders.

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

N8.2: the sim crate's transcendentals are `sim::detmath`, the port of the client's `DetMath` (DETERMINISM.md): the player's velocity (`PlayerInput::from_vehicle`), the hull clearance (`hull::clearance`, new `clearance_cs`, `penetration`) and the scoring rules (the player's heading once per tick, a traffic car's heading as its velocity direction, as `src/scoring/` does now). The scoring vectors were regenerated; all traces stay tick-identical.

`crates/sim/tests/parity.rs`, vectors in `crates/sim/vectors/`:

| Vectors | Result |
| --- | --- |
| `rng.json`: 7 seeds × 24 draws of each kind, `derive_seed`, the traffic stream chain | bit-exact (Godot's PCG32 with its `randf` / `randi_range`) |
| `idm.json`: 1,200 cases × `accel`, `free_accel`, `interaction_accel`, `desired_gap`, `equilibrium_gap`, `pow_int` | 7,200 / 7,200 bit-exact |
| `mobil.json`: 600 cases, `incentive`, `threshold`, `accepts`, `is_safe`, `b_safe_for` | bit-exact |
| `no_ambush.json`: 1,500 cases (287 violations) | identical |
| `player_velocity.json`: 300 cases of `_read_player`'s road velocity | bit-exact (N8.2: DetMath's `sin_cos` on both sides; was within 1e-9 with libm) |
| `detmath.json` (N8.2): 3,504 cases of `DetMath` (`sin`, `cos`, `tan`, `atan`, `atan2`, `asin`, `exp`, `log`, `pow`; edge cases, branch boundaries, seeded inputs) against `sim::detmath` (`tests/detmath.rs`) | 3,504 / 3,504 bit-exact (a NaN matches any NaN) |
| `loop_closures.json`: the client's closures and drop zones on loop_v1, per lane every 50 m | within 1e-8 m |
| `trace_*.json`: the whole sim, per-tick state hash and every event (since WP6.11 with the MP-D5 extensions on: the traces first differ from the old ones at ticks 119 / 9 / 22 / 1336) | **tick-identical**: `sp_weave_120hz` 4,800 / 4,800 ticks (single-player rules, near / far ticks, hits, close passes), `sp_closure_120hz` 3,600 / 3,600 (set-piece closure), `mp_weave_20hz` 2,400 / 2,400 (20 Hz, all near, 1.0 s floor, 4 lanes, headway scale), `mp_lane_drop_20hz` 1,800 / 1,800 (a WP6.8 road drop with its zone) |

The traces run the GDScript `TrafficSim` on the `StraightRoadPath` fixture with a scripted player and a tool-local spawner; the Rust replay applies the same ops. They exercise every profile including WP6.9's weaving racers, lane changes and cancels (player, hesitant, unsafe), mandatory merges, the zipper and harmonisation, hits and horns. The server config differs from them only in the MP flags (move time at the signal, no lane splitting).

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
- **Public rooms** are created by Quick Join with the spec's settings: normal density, the UTC `cycle` clock, 8 seats, no host. A party is one crew there (N9.3: a seat of the same party gives its `crew_slot`); a player alone is a crew of one.
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

**Placements.** The protocol has no spawn message, so the server places a player by putting **the player's own id** in its `player_states`: a `PlayerState` with the placement tick, `s`, `d` (the lane centre), the speed, heading 0 and `run_state = protected`. It is repeated every tick until the client sends a state near it (within `rooms.placement_radius_m`, 30 m, plus what the speed cap covers since the placement), and apply each placement tick once. **Since N6.1** the answering state must also be the placed car: `run_state = protected` (what a client sends once it applied a placement: **clients must send `protected` during the placement's protection**), or at the placement's speed (± 3 m/s plus the acceleration cap since the placement) and lateral offset (± 1 m plus the lateral cap since). A crashed car's stopped states near a respawn "where the car is" are in flight, not an answer (they used to be, and the client's jump to the placement then counted as a teleport). States far from it are dropped as in flight for `rooms.placement_grace_ms` (2 s); after that the next state is taken with a `teleport` offence. Others see the car at its new place at once. **This is a semantic proposal for PROTOCOL.md** (no wire change; see the N5.1 handoff). Placements come with `rooms.protection_ms` (3 s) of protection (`PlayerView.protected_until` for traffic and N6).

| When | Where |
| --- | --- |
| A new seat | 40 m (`rooms.spawn_behind_leader_m`) behind the **crew leader**, in the leader's lane; with no crewmate driving, at the start gantry (the spawn points 150 m past sector 0, one lane per player id in turn) |
| Crash-out respawn, `run_event.start` after a run ended, `run_event.rejoin` | Behind the crew leader; with no crewmate driving, where the car is |
| Reconnect (a held seat taken back) | Where the car was, run intact |

- The **crew leader** is the longest-present connected crewmate whose run is active and who has answered their own placement (seats are in join order). Every placement passes through `RoomTraffic::free_gap` (a real gap with `rooms.traffic = "sim"`: the wanted lane, then its neighbours, ±`spawn_search_m` in `spawn_step_m` steps with `spawn_clear_m` to the nearest car). The speed is the lane's flow speed at that s (the section's `lane_flow_speeds_from_right_kmh`).
- **Runs.** A seat starts a run at once (`run_seq` 1, then counting). `run_event.start` starts a new run only when none is active; `end` ends it (`quit`); `rejoin` places the player behind the crew (the chain forfeit is N6's).
- **Crash-out.** `hit_report` with `lives_left = 0`, or a `player_state` with `run_state = crashed`, ends the run (`run_result {crashed}` to the room) and schedules the respawn `rooms.crash_respawn_ms` (3 s, the results toast) later, with a fresh run. Leftovers of the run before (a crashed state in flight, a hit stamped before the new run started) are ignored.
- **`run_result`** goes to everyone in the room: `player_id`, `run_seq`, `end_reason`, `verified` (no offence), `leaderboard_eligible`, `duration_ms`, `distance_m` (forward distance from accepted states, teleports left out), and since N6.1 the official score and event counts (see "Scoring (N6.1)", which also records verified runs on the boards).
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
- `hit_car(player_id, car_id)` (default: nothing) applies an accepted hit's scripted reaction; N6.1's scoring calls it once it confirms a reported traffic hit (see "Scoring (N6.1) → Hits").
- N6.1: `car_history()` (the `sim` ring records every car after each step, for scoring) and `client_has(player_id, car_id)` (the car was streamed to that client).

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
| `wb_room_tick_max_seconds` | N10.1: the longest room tick since the start (gauge) |
| `wb_room_shadow_player_ticks_total`, `wb_room_shadow_contact_ticks_total` | N10.1: player states the shadow check looked at (player-ticks driven); pair-ticks two players overlapped |
| `wb_room_shadow_contact_disagreement_meters`, `wb_room_shadow_contact_speed_kmh` (histograms) | N10.1: contacts between players by the disagreement of the two views (0.1 … 16 m) and the pair's speed (50 … 300 km/h); `_count` = contacts |
| `wb_room_shadow_rows_written_total`, `_dropped_total` | N10.1: `shadow_contacts` rows |

Logs at INFO: `room created` (id, code, settings), `room seat taken` / `taken back` / `held` / `released`, `run ended` (reason, verified, distance), `implausible player state; run unverified` (once per kind per run), `joined room` (gateway), `room closed (empty)`; N10.2: `room closed` (mode `Admin` / `Restart`), `handed-over room restored`.

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
| `max_speed_kmh` / `speed_tolerance_pct` | `315.36` / `10.0` | The fastest car with boost; spec × 1.1 |
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
| **N4.2** `sim` + streaming, normal (≈ 43 cars per player) | 9,595 | 496 µs | ≤ 500 µs | ≤ 4 ms | 18.7 ms | 17.3 % of a core | 29 % | 3.6 KB/s on the wire (3.2 KB/s payload) | 1,731 B | 0 |
| **N4.2** `sim` + streaming, rush (1,200 cars per room, ≈ 59 per player) | 9,599 | 605 µs | ≤ 500 µs | ≤ 4 ms | 15.7 ms | 21.0 % of a core | 32 % | 3.8 KB/s on the wire (3.4 KB/s payload) | 2,482 B | 0 |
| **N6.1** `sim` + streaming + scoring, normal; bots through traffic with honest claims (`ROOMS_BENCH_CLAIMS`, default on) | 9,606 | 609 µs (scoring 28.5 µs of it) | ≤ 500 µs | ≤ 4 ms | 18.1 ms | 21.2 % of a core (scoring 1.0 %) | 42 % | 3.6 KB/s on the wire | 1,798 B | 0 |

- **Per room tick:** 57 µs for rooms alone (8 seats: take the tick's states, build and queue 8 frames); about 370 µs more with the traffic ring. The N10 target (20 full rooms ≤ 50 % of one vCPU, tick p99 < 5 ms) holds with room to spare for streaming (N4.2) and scoring (N6); the bench asserts p99 ≤ 5 ms in release. The maxima are scheduler stalls on the loaded box (the tick is wall time).
- **Downstream** (N5.1 rows) was `player_states` only (7 × 24 B + headers each tick): 2.5 KB/s per player at the socket payload level.
- **N4.2 rows** (2026-09-30, same box, load average 6–7; at load 12 the same bench missed the p99 bound with 337 offences from starved bots, so compare like with like): streaming to 8 clients costs about 50 µs per room tick (`tests/traffic_stream.rs` `bench_streaming_cost_per_room_tick`, release, one thread: 8 clients' writes mean 51 µs / p50 40 µs / p99 74 µs at normal, 55 / 47 / 110 µs at rush; the ring's step with the stream's bookkeeping 234 / 307 µs mean). The join frames are the largest, 1.7–2.5 KB. Traffic messages average 0.7 KB/s (normal) and 0.9 KB/s (rush) per player; the "down per player" column divides by the whole run including the 160 sequential joins, so it understates the steady state: with 8 bots driving at rush in one room, `rush_hour_downstream_stays_in_budget_with_8_bots` measures **5.0–5.2 KB/s per player on the wire** (framing included) against the 10 KB/s budget. Every bot's traffic mirror ended with 0 violations. p99 stays within the 5 ms target.
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

WP N4.2, in `crates/server/src/rooms/`. Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Traffic: server-authoritative with intents → What the server sends (area of interest, correction schedule), Resource budget (≤ 10 KB/s down per player); [PROTOCOL.md](PROTOCOL.md) §4 (`traffic_*`), §11 (streaming batches), §12 (lanes, car ids); MP-D6. The client side is N4.3 ([NET_TRAFFIC.md](NET_TRAFFIC.md)); this section is what the server sends, item for item against its "Checklist for N4.2".

| File | What |
| --- | --- |
| `sim_traffic.rs` | `SimTraffic`: the room's `TrafficWorld` (N4.1) + its `TrafficStream`; `write_client` streams; `notify_hit` for N6 |
| `traffic_stream.rs` | `TrafficStream`: sim slot ↔ `car_id`, the tick's intents, each car's wire state once per tick, hit reactions; per client the cars it has |
| `car_ids.rs` | `CarIds`: the u16 id free list (MP-D6) |
| `bots/src/traffic.rs` | `TrafficMirror`: a bot's copy of what it was told, with the client-side checks |

`rooms.traffic = "sim"` is the default now (`"none"` still turns traffic off).

### Every tick, in each client's frame

After `player_states`, the client's tick frame carries up to four kinds of traffic message, **in this order**, each only when it has entries. A list that passes 128 entries (64 for intents) continues in a second message of the same type.

| # | Message | Entries |
| --- | --- | --- |
| 1 | `traffic_despawn` | Cars the client has that left its area (past the hysteresis) or left the ring (an off-ramp exit whose move into lane 7 completed, or any sim despawn) |
| 2 | `traffic_spawn` | Every car inside the area that the client does not have, with its full state (below) |
| 3 | `traffic_intent` | This tick's decisions for cars the client had **before** this frame; then, for cars spawned in this frame, what they bring along: a hesitant signal's dated cancel, and a running hit reaction's `hazard` (and `hard_brake` while it lasts) with the hit's own ticks. Other intents for a car spawned in this frame are not sent: the spawn carries its state |
| 4 | `traffic_correction` | `tick` = this frame's room tick. First every car spawned in this frame and every car given an intent in this frame, then every car the schedule has due (below) |

**The frame's tick** is the `traffic_correction.tick`: the state after the room tick's step, i.e. the car at `server_now = tick`. Every frame that carries a spawn or an intent also carries a correction for each of those cars, so a spawn's `s_mm`, `d_cm` and `speed_cms` are the car's state at that tick. A decision's intent has `start_tick` = that tick (after a stalled room catches up, a few ticks older: late).

A tick with nothing to say sends no traffic message; there is no traffic keepalive.

### Area of interest

- **Centre:** the player's latest accepted state extrapolated to the tick, as the sim uses it (`TrafficSim::state_player_s`: linear, at most `player_max_extrapolation_s` 0.5 s); the reported `s` before the player is in the sim. **Δ** = the car's `s` minus the centre, the wrapped signed difference on the loop (`LoopMap::signed_delta_mm`, in `[-L/2, L/2)`).
- **Spawned** when −300 m ≤ Δ ≤ +900 m (`traffic_aoi_behind_m`, `traffic_aoi_ahead_m`).
- **Despawned** when Δ < −320 m or Δ > +920 m (`traffic_aoi_hysteresis_m` = 20 m), so a car at the edge does not flap. At normal density a player has about 40 cars, at rush 45–95 (the city and the 4-lane stretches; NET_TRAFFIC.md's client capacity is 90).
- **Joining and reconnecting:** on the tick the client gets its `room_snapshot` (a join, a reconnect, a seat taken over), the server forgets what it had sent it: every car in the area is spawned in that frame, and nothing is despawned. **A client clears its traffic on every `room_snapshot`**, before reading the rest of the frame.
- A placement (respawn, rejoin) moves the centre: cars out of the new area are despawned, new ones spawned, in the next frame.

### Spawn entries

| Field | Value |
| --- | --- |
| `car_id` | See "Car ids" |
| `vehicle` | The sim's `type_id`: index into `types` of the exported `traffic_params.json` (`TrafficRegistry` type order) |
| `color` | `color_index`: the palette index the car was drawn with |
| `profile` | `profile_id`: index into `profiles` (driver profile) |
| `lane` | The current lane on the wire (see "Lanes") |
| `s_mm`, `d_cm`, `speed_cms` | Position (wrapped into `[0, L)`, rounded to mm), lateral offset (+ right of travel, the sim's d), speed along the road, at the frame's tick |
| `lc_phase` | `none`, `signaling` (blinker on, not moving yet) or `moving` |
| `lc_target_lane` | The lane-change target on the wire; 0 when `none` |
| `lc_move_start_tick` | The sim's `lc_move_tick`: the room tick the lateral move starts (`signaling`) or started (`moving`); 0 when `none` |
| `lc_duration_ms` | The move time (whole ms, exactly the sim's; see "Intents"); 0 when `none` |
| `flags.hazard` | `FLAG_HAZARD` (a hit reaction; the intents after the spawns say from when and for how long) |
| `flags.braking` | `FLAG_BRAKE`: brake lights (decelerating harder than `brake_light_decel_mps2`) |

Not sent: the model variant (the client uses `car_id`), headlights (the room clock's night turns them on for every car), the blinker side (it follows from `d` and the target lane).

### Intents

| `kind` | When | `start_tick` | `move_start_tick` | `target_lane` | `duration_ms` |
| --- | --- | --- | --- | --- | --- |
| `lane_change` | A car signals (MOBIL, a merge, a ramp exit, an on-ramp car merging) | Blinker on: this tick | The sim's `lc_move_tick`: the tick `tick_signaling`'s accumulation reaches the signal time, **≥ `start_tick` + 20** (the 1.0 s floor; 21 ticks in practice) | Target on the wire, with n at the car's s at `start_tick` (7 = the off-ramp) | The move time, drawn when the blinker comes on and **rounded to whole ms in the sim** (`start_signal`, MP only), so the client's curve uses exactly the server's |
| `cancel` (hesitant) | A hesitant driver's signal is decided to cancel when its blinker comes on (the sim's `will_cancel`): sent **in the same batch, right after its `lane_change`**, dated ahead. The sim's own cancel at that tick is not sent again | The signal's end: the lane change's `move_start_tick` | = `start_tick` | 0 | 0 |
| `cancel` | Any other cancel while signalling (a player entered the gap, the move became unsafe at the signal's end, a hit): it can arrive with `start_tick` = the change's `move_start_tick` (the last check failed): the car never moved on the server | This tick | = `start_tick` | 0 | 0 |
| `hazard` | A hit reaction starts (first hit, or hit again while recovering) | The hit's tick | = `start_tick` | 0 | `hit_recover_s` (4000) |
| `hard_brake` | With the hit's `hazard` (same car, same batch): the hit's hard brake, `hit_brake_decel_mps2`. Alone: a cut-in brake tap (a player cut in closer than `cut_in_brake_tap_distance_m`), `brake_tap_decel_mps2` | This tick (the hit's) | = `start_tick` | 0 | `hit_brake_s` (1000) or `brake_tap_s` (500) |
| `horn` | Never sent: horns stay client-side (spec) | | | | |

**The lane-change curve** (the sim's `tick_moving`): no lateral motion before `move_start_tick` M. At room tick t ≥ M, u = min(1, (t − M) × 0.05 s / duration); d(t) = d0 + (d_target − d0) × u² (3 − 2u), with d0 = the car's `d` at M and d_target the target lane's centre. From the first tick with u ≥ 1 the car is at d_target; its lane becomes the target one tick later and the blinker goes off.

**Hit reactions** (the sim's `notify_hit`, called by N6 through `RoomTraffic::hit_car` once it accepts a hit; nothing calls it before N6): the car swerves away from the hitting player (`hit_swerve_m` 0.5 m out and back over `hit_swerve_s` 1.2 s), brakes hard and shows hazards. The protocol has no swerve kind (PROTOCOL.md §12), so the swerve reaches clients as **corrections every tick** for the first 25 ticks after the hit, to every client that has the car.

**Ramps:** an exit is a `lane_change` to wire lane 7, then a despawn when the move completes; an entry spawns on lane 7 and merges with a `lane_change` (to wire lane 0) when it finds its gap.

### Corrections

Each entry is `{car_id, s_mm, d_cm, speed_cms}` at the batch's tick (d rounded to 1 cm and clamped to ±100 m, speed to 1 cm/s, PROTOCOL.md §3). A car the client has is in the tick's batch when:

- it was spawned or given an intent in this frame (always, see above);
- **near** the player (|Δ| ≤ 100 m, `traffic_near_m`) and `(tick + car_id) % 4 == 0` (**5 Hz**, `traffic_near_hz`);
- otherwise `(tick + car_id) % 20 == 0` (**1 Hz**, `traffic_far_hz`);
- it is in the first 25 ticks of a hit reaction.

So no car goes more than 20 ticks without a correction, a car within 100 m no more than 4 once it is near, and the stagger by car id spreads the 1 Hz corrections over the second (a joined client's 40–90 cars do not all land on one tick).

### Lanes

On the wire, `lane`, `lc_target_lane` and `target_lane` count from the right: **wire = n − 1 − sim lane**, where the sim lane counts from the median (0 = the fast lane, as the client's `TrafficSim`) and **n = the road-space lane count at the car's `s_mm` in this frame** (the spawn entry's; for an intent the car's s at `start_tick`, which is also its correction's in the same frame; lane ranges step at each range's `s_start_mm`, `LoopMap::lane_count_at`). A sim lane ≥ n is **7** (MP-D6): an on-ramp car, an exit's target (the off-ramp pseudo-lane `lane_count(s)`), and a car still in a dropping lane where the range already counts one lane fewer. Back on the client: **7 → n**, else n − 1 − wire. The round trip is exact for every sim lane ≤ n.

### Car ids

`car_id` is allocated per room when a car enters the ring (the fill, an on-ramp), from 1 (never 0: `hit_report.car_id` 0 means "not traffic"), and stays with that car while it is in the ring: a car that leaves a client's area and comes back is spawned again with the same id. When the car leaves the ring its id is released and **not handed out again for 30 s** (`traffic_car_id_hold_ms`; MP-D6); released ids come back oldest first, else a fresh id. The room maps the sim's `(slot, vehicle_id)` to the id after every step, so a slot reused by a new car always gets a new id.

### Bytes

Measured (8 bots in one rush-hour room over real sockets, `rush_hour_downstream_stays_in_budget_with_8_bots`; every frame counted with its WebSocket header and a TLS record, PROTOCOL.md §11):

| Per player | Bytes/s |
| --- | --- |
| Everything on the wire (7 remote players' states, traffic, framing) | **5.0–5.2 KB/s** (budget 10 KB/s) |
| Traffic messages alone | about 1.4 KB/s: corrections ~1.15 KB/s (≈ 100 entries/s), spawns and despawns ~0.18 KB/s, intents ~0.05 KB/s |

Without sockets (`tests/traffic_stream.rs`, 8 players spread round the loop at 25–70 m/s, rush): 0.8–1.7 KB/s of traffic messages per player, 36–90 cars each. The first frame after a join carries the whole area: about 60 × (23 + 10) B ≈ 2 KB.

### Guarantees the tests pin

| Test | What |
| --- | --- |
| `tests/traffic_stream.rs` | No sockets: a rush ring with 8 players, every frame decoded into a `bots::TrafficMirror` every tick for 60 s: the mirror equals the server's set for that client, every car in the area is there, nothing past the hysteresis stays, every car due by the stagger is corrected on its tick and none goes 20 ticks without one, corrections carry the server's `s`, no violation (message order, unknown ids, missing same-frame corrections, intent leads < 20 ticks); spawns' lanes, lane-change state and indices against the sim; intents reach every client that has the car at decision time, hesitant cancels ahead with their lane change and never twice, the car never moving at that tick; a hit streams `hazard` (4000) + `hard_brake` (1000) and per-tick corrections through the swerve, and a client joining mid-reaction gets the same hazard; a reconnect resends the whole area; ids never reused within the hold while the ramps churn; determinism (same seed, same frames) |
| `tests/traffic_alloc.rs` | A counting allocator: 400 ticks of a rush room with 8 players, a hit and the ramps, streaming to all 8 frames: **0 allocations** |
| `tests/rooms.rs` | Over sockets: `traffic_mirrors_match_the_server_at_quiescent_points` (3 bots; the room's traffic wrapped in a probe that can pause it; at two quiescent points every bot's mirror equals the server's set, no violation, gaps ≤ 20 ticks, leads ≥ 20); `rush_hour_downstream_stays_in_budget_with_8_bots` (≤ 10 KB/s each, framing included); the bench |
| `rooms::car_ids::tests`, `rooms::traffic_stream::tests` | The 30 s hold under churn and across the tick wrap; wire lanes and their inverse; the stagger; the fast wrapped distance against the map's |
| `tests/config.rs` | The `rooms.traffic_*` defaults, their conversion to ticks and their validation |

### Configuration

`[rooms]`:

| Key | Default | Meaning |
| --- | --- | --- |
| `traffic` | `sim` | `sim`: the ring runs and streams; `none`: no traffic |
| `traffic_aoi_behind_m` / `traffic_aoi_ahead_m` | `300.0` / `900.0` | The area of interest (spec) |
| `traffic_aoi_hysteresis_m` | `20.0` | A sent car stays until it is this much further out (not in spec; N4.3's contract) |
| `traffic_near_m` / `traffic_near_hz` / `traffic_far_hz` | `100.0` / `5` / `1` | Correction rates (spec); the periods are `tick_rate_hz / hz` ticks |
| `traffic_car_id_hold_ms` | `30000` | A released car id is not reused for this long (MP-D6) |

## Scoring (N6.1)

WP N6.1 (server side). Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Scoring in multiplayer (crew mechanics, server-authoritative scoring), Time of day in multiplayer (night ×2), Leaderboards ("Multiplayer runs go on the boards automatically"), Testing (scoring; the bots' > 99 % claim acceptance), Tuning reference; [PROTOCOL.md](PROTOCOL.md) §4 (`score_claim`, `hit_report`, `score_sync`, `score_event`, `run_result`, `room_event.crew`, used as frozen); [SCORING.md](SCORING.md) (the rules). The client side (`score_client.gd`, the HUD) is N6.2.

| Where | What |
| --- | --- |
| `crates/sim/src/scoring/` | `sim::scoring`: the port of `src/scoring/` (rules, hull, events, params) plus sector facts and the loop road; parity-tested |
| `crates/sim/data/scoring_params.json` | The scoring tuning, exported from Godot (`export_sim_data.gd --only=scoring`) |
| `crates/server/src/rooms/car_history.rs` | The room's traffic for the last ticks |
| `crates/server/src/rooms/scoring/` | `RoomScoring`: states, claims, verification (`claims.rs`), the server's own pass and contact view (`tracker.rs`), the official score (`official.rs`), trains, crew totals, `ScoreSync` / `ScoreEvent` |
| `crates/server/src/leaderboards/mp_runs.rs` | The board write path for finished multiplayer runs |
| `crates/bots/src/driver.rs`, `link.rs` | Bots that drive through traffic and claim (honest or cheating); a minimal link simulation |

### `sim::scoring`: the rules, ported

`rules.rs` is `scoring.gd` function for function (same fields, same float expressions, same order), `hull.rs` is `road_hull.gd`, `events.rs` the event buffer with the same kind and tag names. Traffic and road are traits (`ScoringCars`, `ScoringRoad`), so one implementation scores a `TrafficState`, a parity trace's cars and a bot's mirror. `sectors.rs` keeps `LegTracker`'s per-leg facts for the loop's sectors (time, hits, threads, close passes, the Heat hold; Clean, Pace, Threads, Heat in that order), and `road.rs` answers `lane_index_at` / `is_on_shoulder` on the loop map (lane-count tapers included).

Multiplayer additions, none of which changes what the port computes when unused: `begin_tick` / `end_tick` split `step` around its detection and `award` pays one event as the detection would (the official score pays **verified claims** there); `set_crew_factor` multiplies every scored event's points (1.0 by default: `x × 1.0 == x`); `forfeit_chain` (Rejoin crew, tag `rejoin`); the `train` kind.

**Parity** (`crates/sim/tests/scoring_parity.rs`; vectors from `tools/server_data/export_sim_data.gd --only=scoring`): the exporter runs the real `Scoring` on a `StraightRoadPath` with cars on scripted lines (no traffic model: the Rust replay repeats the motion arithmetic exactly) and a scripted player (speed changes and dips below the minimum, lane changes with yaw, shoulder visits, boost), with hits and the ghost, checkpoints, bonuses, night and run end as ops. Results:

| Vectors | Result |
| --- | --- |
| `scoring_hull.json`: 2,000 box pairs | 2,000 / 2,000 bit-exact (N8.2: DetMath's `sin_cos` on both sides; asserted) |
| `scoring_weave_120hz.json` (3 lanes, 75 s at 120 Hz), `scoring_weave_20hz.json` (4 lanes, 150 s at 20 Hz), `scoring_edges_120hz.json` (shoulders, dips, 60 s) | **tick-identical**: 9,000 / 3,000 / 7,200 ticks, every event (kind, tag, points, multiplier, clearance, slot, value: 102 / 191 / 84 events) and `take_boost_fill()` bit-exact, `Scoring.trace_hash()` equal every tick. Every event kind and loss reason occurs |

**When `src/scoring/` changes:** apply the same change to `rules.rs`, re-export (`tools/godot.sh --headless --path . --script res://tools/server_data/export_sim_data.gd -- --only=scoring`), run `cargo test -p sim --test scoring_parity`. The traces fail at the first tick that differs.

### Claims (the contract for the client, N6.2)

The client detects events with its own rules for instant feedback and claims each one: `score_claim {claim_id, tick, kind, side, cars}`. **All ticks are room ticks from `server_now()`.**

| `kind` | `tick` | `cars` (id, clearance mm) | `side` |
| --- | --- | --- | --- |
| `pass`, `close_pass` | the tick the client paid it (`Scoring` wrote the event: the car fully behind) | the car, its minimum hull-to-hull clearance over the pass | the car's side at the crossing (`left`/`right`) |
| `thread` | the tick of the second pass (the one that completed it; send its own `pass` / `close_pass` claim too, first) | first car, second car, each with its clearance | the first car's side |
| `cut` | the tick the player's centre crossed into the new lane | the nearest eligible car (clearance 0) | `none` |

- Send claims in the order the events happened (the server pays claims of one tick in arrival order), right away. A claim names only cars the client was streamed.
- **`PlayerState.tick` must describe the car at that tick** (the first physics step at or after it), not a later instant: the server pairs each state with the traffic at its tick. 50 ms off at a 30 m/s closing speed is 1.5 m.
- Report every hit (`hit_report`, with `car_id` for traffic and the lives left). The client stays authoritative for its lives.
- Rejected claims come back as `score_event {kind: claim_rejected, ref_id: claim_id, tick: the claim's tick}` (dev HUD). There is no acceptance message: the official score is the answer.

### Verification

Every accepted `PlayerState` of a run goes into the player's state ring (64 ticks). Once the traffic history holds its tick, the **tracker** pairs it with the room's cars at that tick (`car_history.rs`: every live car after each world step, 28 bytes each, for `rooms.stale_state_ms` + 2 ticks) and runs the client's pass rule on the server's data: a car fully ahead enters the longitudinal overlap window and leaves it fully behind; the tick the centres cross, their lateral offset then, the minimum clearance over the window (`RoadHull.clearance`) and the tick it completes. It tracks the cars from `track_ahead_m` ahead to 10 m past the window behind, with a player hull of the game's largest car (`player_length_m` × `player_width_m`: 4.8 × 1.95 m, inset 8 cm), so the server's clearance is never larger than the client's for its body.

| Claim | Accepted when (defaults) | Else |
| --- | --- | --- |
| any | every car was streamed to this client (`RoomTraffic::client_has`); the run is in progress and the tick is not before it | `unknown_car`, `no_run` |
| `pass` | the server saw the pass complete within **±300 ms** (`claim_timing_ms`) of the tick (a claim may also be earlier by the pass's body slack: half the difference between the server's hull and the shortest car over the closing speed, at most 2 s; a client in a shorter car completes first), not claimed yet; the centres' lateral offset ≤ 5.4 m (+ 0.35 m); the claimed side (checked when the offset is over 1 m) | `no_pass`, `timing`, `duplicate`, `lateral`, `side` |
| `close_pass` | as a pass, and the server's clearance < 1.0 m **+ 0.35 m** and ≤ the claimed clearance **+ 0.35 m** (`claim_clearance_tolerance_m`) | `clearance` |
| `thread` | the second car's pass completed within ±300 ms; the first car's centres crossed within the thread window (0.5 s) + 300 ms of the second's; opposite sides; each clearance < 1.5 m + 0.35 m and ≤ its claim + 0.35 m; neither pass in another thread | `thread`, `side`, `clearance`, `lateral` |
| `cut` | the player's states show a lane change (two driving lanes) within ±300 ms; the speed ≥ 140 km/h − `cut_speed_tolerance_kmh` (5); the named car in the lane left or entered, its hull gap ≤ 15 m + `cut_gap_tolerance_m` (2 m); the car not named in an accepted cut in the last 3 s (− 300 ms) | `cut`, `cooldown` |

A claim that matches accepts at once; one that does not waits until the tracker has seen the player's states up to its tick + 300 ms, or `claim_max_wait_ms` (1 s) passed, then it is rejected. `claim_queue` (32) undecided claims per player; more are `queue_full`. Nobody is kicked for rejections (as for plausibility offences). Metrics: `wb_room_claims_total{verdict, reason}`.

### The official score

"The server runs the same scoring rules on accepted claims only" (`official.rs`): one `sim::scoring::Scoring` per run, stepped once per accepted state in tick order, **`official_lag_ms` (1.5 s) behind the room clock** so that every claim, hit report and crewmate pass of a tick is decided before the tick is paid (a claim decided later is paid at the next step and counted in `wb_room_claims_late_total`). A step at tick T after the state before at P, in the client's order:

1. hits and rejoins reported for (P, T]: `notify_hit` (the chain is lost; the lives are the client's `lives_left`), `forfeit_chain`;
2. night ×2 from the **room clock** at T (`RoomTime::is_night`), the crew factor at T; `begin_tick(T − P)`: the shoulder from the reported `d` (any wheel, with the default body), minimum speed and hesitation from the reported speed;
3. the accepted claims of (P, T] in arrival order, each paid like the client's detection pays it (base × multiplier before the gain × speed factor × night × crew; the gain unless the shoulder blocks it), each pass or thread then offered to the train log;
4. `end_tick`: the multiplier decays (boost from the state's flag, the shoulder ×3), a cash-out banks;
5. the sector: its time and Heat hold. A gantry crossed between P and T (`LoopMap::sector_crossed`) banks the chain (`notify_checkpoint`), pays the earned bonuses (Clean 5,000, Pace 3,000 at ≥ 170 km/h average, Threads 3,000 for 3+, Heat 5,000 for 15 s at ≥ 10×; × night) as `score_event {sector_clean | sector_pace | sector_threads | sector_heat, points, sector}` (`sector` = the sector completed, 1-based: gantry k − 1 → k), and a clean sector gives a life back (up to 2). A run's first sector starts where the run was placed; a placement restarts it.

Points differ from the client's only by the 20 Hz sampling (the multiplier's decay between the client's 120 Hz event and the server's tick, speed read from the state): at most a point or so per event, which the banking-moment easing absorbs.

**Crew proximity** (spec): every crewmate (same `crew_slot`, run in progress) whose state within 2 ticks of T is within **30 m** along the loop (`crew_range_m`) adds **+0.25×** (`crew_bonus_per_mate`) to the factor on each scored event's points, capped at **×2.0** (`crew_factor_cap`). `score_sync.crew_in_range` carries the count.

**Trains** (spec): a pass (same car, same side) or a thread (the same two cars) that a crewmate made **within 1.0 s before** (`train_window_ms`, by the server's crossing ticks) is a train link: it pays **25 base points and +2 multiplier** (`train_points`, `train_multiplier_gain`) right after the pass, like any scored event (× speed, night, crew). Links count up: the crewmate's link + 1 (the first follower is TRAIN ×2). `score_event {train, points, multiplier_gain_milli: 2000, link, ref_id: the car}` goes to every member of the crew.

**`score_sync`** (private): at every banking moment (a bank or a bonus: `flags.banking`) and at least once a second (`sync_interval_ms`), with the official tick it describes (`tick`: the official timeline's, about 1.5 s behind the room), `run_seq`, `banked`, `chain`, `multiplier_milli`, `lives`, `crew_in_range`, `night` (the room clock at that tick) and `unverified`. **The client eases its display to the server's values at banking moments** (spec), comparing with its own history at `tick`, so a correction never takes score away mid-chain.

**Session crew total:** the banked scores of the crew's finished runs this room session plus its members' banked scores so far, in `room_snapshot.crews` and as `room_event.crew` whenever it changes (at most once a second per crew, `crew_total_interval_ms`; at once when a run ends).

### Hits

- **The client is authoritative for its lives.** A `hit_report` (any target) loses the chain at its tick in the official timeline; its `lives_left` is the run's lives; `lives_left = 0` ends the run (N5.1's crash-out).
- **Accepted traffic hits:** a `hit_report {traffic, car_id}` is confirmed when the tracker saw that car within `hit_confirm_clearance_m` (1 m) of the player within ±300 ms of the hit's tick; then `RoomTraffic::hit_car` applies the scripted reaction (swerve, hard brake, hazards, streamed as N4.2 describes). Metrics `wb_room_hits_confirmed_total` / `_refused_total`.
- **Server hit detection** (spec): the player's reported hull and a car's overlapping deeper than **0.3 m** (`hit_overlap_m`, the separating-axis penetration, `sim::scoring::hull::penetration`) on **2+ consecutive states** (`hit_overlap_ticks`) is a contact. One the client did not report (no hit report within `hit_match_ms`, 1.5 s, of it, nor a ghost period after one), outside spawn / rejoin protection and the ghost flag, **marks the run unverified** (`wb_room_hits_unreported_total`; logged once per run; `score_sync.flags.unverified`). The run goes on. N10.1: each one, and each reported traffic hit the server saw no contact for (`hits_refused`), is also a shadow record, sampled into the `wb::shadow` log (see "Shadow collisions").

### Run results and the boards

`run_result` now carries the official score (the banked total: the run's end loses the held chain, as in single-player; a disconnect keeps the banked score) and the counts (`passes`, `close_passes`, `cuts`, `threads`, `trains`, `max_multiplier_milli`). `verified` = no plausibility offence (N5.1) **and** no unreported server-detected hit **and** the claim acceptance above `verify_min_acceptance_pct` (90 %) once the run has `verify_min_claims` (20) decided claims (**deviation MP-D9**, see below). `leaderboard_eligible` = verified and a ranked room (MP-D7: public, or private on normal density and the `cycle` clock for the whole run).

Every **verified** run goes to the boards: the room hands it to the rooms' run sink (`Rooms::set_run_sink`; the app's is `leaderboards::mp_runs::run_sink`), which, off the room task, takes the player's crew snapshot and calls `record_multiplayer_run` (N7.1): stored as `verified` with the room kind (`public`, `private`, `private_custom`: stats only), Loop season and all-time for ranked rooms, the crew's Loop crew sum. `car` is stored as `unknown` and `build` as 0 (the protocol carries neither). Unverified runs are not written.

### Allocation and cost

Nothing allocates per tick: rings and queues are sized when a player joins (states 64, observed passes 64, contacts 16, near misses 128, claims 32, pending hits 16), the outbox and the seats' private queues keep their capacity. `tests/scoring_alloc.rs` (a counting allocator): 600 ticks of a rush room, 8 players, ~250 honest claims (the client's rules on the same traffic, all accepted), bogus ones, hits, a rejoin and a run ended and restarted: **0 allocations**.

**Cost** (the 20 rooms × 8 bots bench, `bench_20_rooms_of_8_bots`, release, 2026-09-30 on the shared 4-vCPU box at load average 5–12; see "Rooms → Bench"): scoring (`RoomScoring::tick`, timed separately into `wb_room_scoring_seconds_total`) costs **28.5 µs per room tick** with 8 bots driving through normal traffic and claiming (309 claims in 20 s, all accepted, 191 trains, 3,300 syncs): **1.0 % of a core for 20 rooms** (42 µs before the tracker's distance cut; the same with lane bots that claim nothing: the pass tracker and the official timelines run for every state either way). Recording the traffic history adds a copy of the live cars per world step inside the traffic's tick. The whole room tick stays at p99 ≤ 4 ms (≤ 3 ms in the run before), room CPU 19–21 % of a core against N4.2's 17.3 % (different bots: through traffic now, and a busier box), 3.6 KB/s down per player on the wire (`score_sync` once a second and at banking moments: 24 B each).

### Bots

`bots::driver`: `DriveMode::Traffic` bots drive through the traffic they are streamed (a simple IDM behind a slower car, an overtake through a clear neighbouring lane, leaving a lane that ends, wandering ±1.3 m in the lane so some passes are close), report their own hits (hull contact on their mirror, 2 lives, a 2 s ghost, the placement's 3 s protection), and with `ClaimMode::Honest` run the client's rules (`sim::scoring`, the parity-tested port) on their traffic mirror carried to each state's tick (the last correction at its speed, lane changes on their intent's curve), turning its events into claims exactly as above. `ClaimMode::Cheat` bends every claim: `InflateClearance` (plain passes claimed close at 0.3 m), `FabricateCars` (cars ahead never passed, or ids never sent), `WrongTiming` (1.5 s early). `bots::link` is the delay layer (N4.4: per-direction delay and jitter; a lost frame retransmitted after 200 ms, in order, as over TCP; see [LOADTEST.md](LOADTEST.md)); the acceptance numbers below predate it (they used a retransmission of one RTT).

**Acceptance** (`tests/scoring.rs → acceptance_run_long`, release, 8 honest bots in one private room, the mobile link: 150 ms RTT, ±30 ms jitter, 2 % of frames retransmitted an RTT late):

| Run | Claims (pass / close / cut) | Accepted | Rejected | Other |
| --- | --- | --- | --- | --- |
| normal density, 300 s | 337 (275 / 53 / 9) | **337 (100 %)** | 0 | 181 trains, 8 reported traffic hits all confirmed (the cars reacted), 0 unreported contacts. (This run predates the placement fix above: 3 runs after a crash-out respawn went unverified by a `teleport`; fixed, `rooms::tests::a_respawn_where_the_car_stopped_is_no_teleport`) |
| rush, 150 s | 218 (179 / 39 / 0) | **218 (100 %)** | 0 | 81 trains, 0 offences, 0 unreported contacts |

Cheating bots (`cheating_bots_claims_are_rejected`, 3 cheats among 5 honest bots, rush, 30 s): every fabricated claim is refused (`unknown_car` / `no_pass`), every claim 1.5 s early (`timing`), inflated clearances (`clearance`) unless the pass really was close within 0.35 m; the honest bots in the same room: all accepted. Threads are rare with this driver (none in these runs); the parity traces and the room tests cover them.

### Tests

| Test | What |
| --- | --- |
| `sim/tests/scoring_parity.rs` | The parity table above |
| `sim::scoring::*::tests` | Params (the spec's numbers), the event buffer, hull and penetration, the loop road against its lane ranges, sector bonuses |
| `rooms::scoring::tests` | Without sockets, a scripted traffic with a history: an honest pass accepted and paid at its tick (the sync's chain, the banking sync, at least one a second); fabricated, never-passed, late, inflated and duplicate claims each rejected for their reason; close passes and a thread paid on one tick (and a one-sided thread refused); cuts (window, cooldown, too slow); crew proximity ×1.25 and a train (TRAIN ×2, to the crew only), the session crew total; night ×2; sectors (bank, Clean + Pace, a hit spoils Clean and costs a life until a clean sector); an unreported contact (unverified) vs a reported hit (confirmed: the car reacts); rejoin forfeits the chain; claims after the run are `no_run`; acceptance below the threshold |
| `rooms::scoring::{tracker, ring}::tests`, `rooms::car_history::tests` | The server's pass view (crossing tick, side, clearance), contacts, the ring, the history |
| `rooms::tests` | Through the room: a claim routed and its rejection in the player's frame, score syncs, `run_result` with the official score, verified runs to the sink (and an unverified one not); a respawn where the car stopped is answered by the protected state, not the crashed one (no teleport) |
| `rooms::plausibility::tests` | Placements: a crashed or unrelated car near the placement is in flight; the protected one answers it |
| `tests/scoring.rs` | Over real sockets with the mobile link: 8 honest bots in a rush room for 30 s (every claim decided, none rejected); 3 cheats (one per kind) among 5 honest bots (every fabricated and mistimed claim refused, inflated ones refused unless genuinely close, the honest bots' all accepted); `acceptance_run_long` (ignored) |
| `tests/scoring_alloc.rs` | 0 allocations (above) |
| `tests/config.rs` | `[scoring]` in the example file equals the defaults |

### Configuration

`[scoring]` (spec values unless marked):

| Key | Default | Meaning |
| --- | --- | --- |
| `claim_timing_ms` | `300` | A claim's tick within this of the server's view (spec: ±300 ms) |
| `claim_clearance_tolerance_m` | `0.35` | Clearance tolerance (spec: +0.35 m) |
| `cut_gap_tolerance_m` / `cut_speed_tolerance_kmh` | `2.0` / `5.0` | Cut checks on 20 Hz states (not in spec) |
| `claim_max_wait_ms` / `claim_queue` | `1000` / `32` | The longest a claim waits for its evidence; undecided claims per player (not in spec) |
| `official_lag_ms` | `1500` | The official timeline's lag behind the room (not in spec; ≤ 2500) |
| `sync_interval_ms` | `1000` | `score_sync` at least this often (spec: once a second) |
| `crew_range_m` / `crew_bonus_per_mate` / `crew_factor_cap` | `30.0` / `0.25` / `2.0` | Crew proximity (spec) |
| `train_window_ms` / `train_points` / `train_multiplier_gain` | `1000` / `25` / `2.0` | Trains (spec) |
| `hit_overlap_m` / `hit_overlap_ticks` | `0.3` / `2` | Server hit detection (spec) |
| `hit_match_ms` / `hit_confirm_clearance_m` | `1500` / `1.0` | A report accounts for a contact this close in time; a reported traffic hit is confirmed this close (not in spec) |
| `verify_min_acceptance_pct` / `verify_min_claims` | `90.0` / `20` | Leaderboard verification (MP-D9, not in spec) |
| `player_length_m` / `player_width_m` | `4.8` / `1.95` | The hull the server measures with (the largest car; not in spec) |
| `track_ahead_m` / `crew_total_interval_ms` | `60.0` / `1000` | Tracking range; crew total pacing (not in spec) |
| `shadow_view_delay_ms` / `shadow_log_every` | `100` / `10` | N10.1 shadow collisions: the views' age for the disagreement estimate (spec: remote cars shown 100 ms behind; at most 500); one in this many of a room's shadow records is logged, the first always (not in spec) |

### Deviations and open questions

- **MP-D9 (needs an orchestrator row):** `run_result.verified` also requires no unreported server-detected hit (spec) **and a claim acceptance of at least 90 % once a run has 20 decided claims** (not in spec: a client whose claims keep failing is either cheating or broken). Rejected claims still never kick.
- **Claim semantics** (the table above) are this WP's reading of PROTOCOL.md's `score_claim` fields; N6.2 implements them. The claim's tick for passes is the completion (when the client pays), which the server matches against its own completion ±300 ms; a car body up to 0.3 m shorter than the server's hull completes a pass earlier, so the window extends earlier by that body slack at the pass's closing speed (capped at 2 s); the server's own hull is the longest (`player_length_m`).
- **The official score runs 1.5 s behind the room;** `score_sync.tick` says which tick it describes. The client compares against its own state at that tick.
- **No car or build on the wire:** multiplayer runs are stored with `car = unknown`, `build = 0`.
- **`hit_report` for barriers and the roadside** is taken as reported (no server check: the server has no roadside model).

## Load test, shadow collisions and admin stats (N4.4, N10.1)

WPs N4.4 (bots and the delay layer) and N10.1 (the load part of N10). Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Testing → Netcode harness, Load test; Players → shadow collision logging; Resource budget; Data model (`shadow_contacts`). The runbook, the options and the full results are in [LOADTEST.md](LOADTEST.md).

| Where | What |
| --- | --- |
| `crates/bots/src/link.rs` | The delay layer: per-direction delay, jitter and loss; TCP (a lost frame late by the 200 ms RTO, in order) or datagram (gone, reordered); statistics |
| `crates/bots/src/predict.rs` | The client's traffic model on a bot (NET_TRAFFIC.md's, IDM at room ticks, v0 estimate and bias, drop zones): correction sizes and late intents as the client measures them |
| `crates/bots/src/load.rs`, `src/bin/loadtest.rs` | The load test: N rooms × M bots against a running server; `/metrics`, `/admin/stats` and `/proc` read before and after the window |
| `crates/server/src/rooms/scoring/shadow.rs` | Contacts between players |
| `crates/server/src/rooms/shadow_log.rs` | `shadow_contacts` rows (the sink) and their aggregates |
| `crates/server/src/metrics_admin.rs` | `GET /admin/stats` |
| `crates/server/tests/netcode.rs`, `tests/admin_stats.rs` | The acceptance test (normal suite, and the long one ignored); the admin view and the table |

### Results (2026-09-30)

20 private rooms × 8 bots through normal traffic with honest claims, every bot on its own 150 ms / ±30 ms / 2 % TCP link, against the release image under `docker run --cpus=1 --memory=512m` (production mode), 600 s after a 15 s warm-up, on the shared 4-vCPU dev box (load average 6–8 from other work, so the wall-time numbers are pessimistic; the container was never throttled):

| Target | Budget | Measured |
| --- | --- | --- |
| Server CPU | ≤ 50 % of one vCPU | **38.1 %** (room ticks 25.8 %) |
| Room tick p99 | < 5 ms | **≤ 3 ms** (mean 0.64 ms; max 105 ms: host stalls) |
| Memory | < 300 MB | **99.6 MB** RSS |
| Down per player (wire, worst bot) | ≤ 10 KB/s | **5.09 KB/s** (mean 4.69) |
| Claim acceptance | > 99 % | **99.92 %** (13,161 / 13,171) |
| False server-detected hits | < 1 per hour | **0** in 27.5 bot-hours |
| Traffic correction median / p99 | < 0.15 / < 0.6 m | **5 mm / 0.285 m** |
| Late intents | < 1 per 10 min | **0.06** per 10 bot-minutes |
| Plausibility offences (honest bots) | | 0 |

At rush (300 s): 42.8 % of the core, tick p99 ≤ 2 ms, 100.9 MB, 5.61 KB/s worst player, 99.95 % of claims, correction p99 0.39 m, 0 offences, 0 false hits.

### Shadow collisions

"For every pair of players, the server records each moment their collision boxes would have overlapped, using both reported states at the same tick" (`rooms::scoring::shadow`). Players are ghosted in v1; nothing here changes play.

- **When:** every room tick checks the tick at the official timeline's horizon (`scoring.official_lag_ms` behind the room: every state of it has arrived). Each pair of players with a run in progress, their states at that tick (interpolated across a missing one, at most 2 ticks each side; none across a placement), the scoring hull (`scoring.player_length_m` × `player_width_m`, inset), the separating-axis depth. Pairs more than two hull diagonals apart along the loop are skipped. Nothing allocates per tick (`tests/scoring_alloc.rs` covers it).
- **A contact** runs from the first overlapping tick to the last. It records the pair, its first tick and length, the deepest overlap, the pair's mean speed at the start, the largest speed difference and the largest **disagreement**.
- **Disagreement** ("how much the two players' views disagreed"): each player sees the other as the other's state `scoring.shadow_view_delay_ms` (100 ms) earlier carried on to the contact tick at its reported forward and lateral speeds (the soft-solid proposal resolves contact against extrapolated positions). The two views of the pair's relative position differ by `|e_a + e_b|`, `e` being each car's extrapolation error. Straight driving disagrees by centimetres; a lane change or hard braking during the contact by metres. Across a placement the old state gives no error.
- **Where it goes:** `wb_room_shadow_*` metrics (contacts, pair-ticks, player-ticks, disagreement and speed histograms); one row per contact in **`shadow_contacts`** (room, tick, the two accounts ordered, speed, disagreement, closing speed, depth, ticks, time; written off the room task, at most 64 writes in flight, the rest dropped and counted); a sample in the log.
- **Traffic contacts:** each server-detected contact nobody reported (`hits_unreported`, N6.1) and each reported traffic hit the server saw nothing for (`hits_refused`, "the reverse") is a shadow record too, logged with its numbers (car, tick, depth, speeds).
- **Log sampling:** a room logs its first shadow record and then one in `scoring.shadow_log_every` (10), at INFO with target `wb::shadow` (`kind` = `player_contact`, `unreported_contact` or `refused_hit`, plus `sample`, the room's record count). `RUST_LOG=info,wb::shadow=off` silences them; the counters and the table keep everything.
- **Retention:** N10.3: rows older than `housekeeping.shadow_contacts_days` (30) are deleted by the daily housekeeping pass, in batches (the load test wrote 6,569 rows for 27 bot-hours, about 240 per player-hour).

### Admin stats

`GET /admin/stats` on the metrics listener (localhost only, like `/metrics`: the listener's address is the gate; the load test reads it there), and the same document at `GET /admin/v1/stats/full` on N10.2's admin API (its bearer token; `/admin/v1/stats` stays the short live counts the CLI prints). The distroless image has no curl, so read it from a process sharing the container's network (a sidecar, `docker run --network container:<name> curlimages/curl …`, or the host with `--network host`). One JSON document:

| Key | What |
| --- | --- |
| `process` | uptime, CPU seconds, `cpu_pct_of_core` over `window_s` (the time since the previous call; the uptime on the first), RSS and peak (MB), threads |
| `gateway` | connections, sessions, bytes out / in per second over the window, and per session |
| `rooms` | rooms, seats, ticks, tick mean over the window, p50 / p99 (bucket bounds since the start), max, the ticks' share of a core |
| `netcode` | claims accepted / rejected and the acceptance, offences by kind, hits confirmed / refused / unreported (and per player-hour), placements, crash-outs |
| `shadow` | player-hours covered, contacts and contacts per player-hour, pair-ticks, the disagreement and speed histograms (`[bound, count]`, the last bound `null`), rows written / dropped, and `last_day` / `last_week` from `shadow_contacts` (contacts, pairs, mean speed km/h, mean and max disagreement, contacts over 1 m, mean length in ticks) |
| `disk` | N10.3: `data_dir`, `free_bytes`, `total_bytes`, `min_free_bytes`, `low`, `db_bytes`, `wal_bytes`, `shm_bytes`, `replays_bytes`, `replays_files`, `backups_bytes`, `data_bytes`, `other_bytes`, `backup_files`, `backups_kept_max`, `backup_newest`, `backup_newest_age_s`, `backup_stale` (`null` if the walk failed) |

The load test prints it at the end of a run; `westbound-server admin stats` could print it with a `--full` flag (not added: the CLI is N10.2's).

### Tests

| Test | What |
| --- | --- |
| `rooms::scoring::tests` | A player driving through another is one contact (its length, speed, closing speed, depth, no disagreement); neighbouring lanes never touch; a lane change into the other car during a contact is a 3.6 m disagreement |
| `rooms::metrics::tests` | The shadow histograms and their Prometheus text; the tick max |
| `metrics_admin::tests` | `/proc` numbers; the view's counters, rates and windows |
| `tests/admin_stats.rs` | `/admin/stats` on the metrics listener only (404 on the public one); the process metrics on `/metrics`; rows written, ordered and summarised; the sink |
| `tests/netcode.rs`, `bots::{link, predict, load}::tests` | See [LOADTEST.md](LOADTEST.md) → Tests |
| `tests/config.rs` | The two new `[scoring]` keys in the example file |
## Operations (N10.2)

WP N10.2 hardens the server for running it: the admin API and the full admin CLI, the planned restart (notice, drain, room handover, close 1012), backups with verification, restore and an off-site hook, a rate-limit review, request ids, and the operational metrics. The owner's runbook (deploy, restart, backup and restore, bans, logs, metrics, alerts) is [`OPERATIONS.md`](OPERATIONS.md). Code: `shutdown.rs` (drain and restart), `handover.rs`, `admin_api.rs`, `admin_client.rs`, `admin.rs` + `main.rs` (CLI), `backup.rs`, `ops.rs` (probes), `account_limits.rs`, `ratelimit.rs`, `http.rs` (request ids, draining health), `telemetry.rs`. Tests: `tests/ops.rs`, `tests/cli.rs` (the N10.2 part: `serve` on SIGTERM with a connected player), `tests/config.rs`, unit tests in the modules. Against a built image: run the container with `WB_GATEWAY__MAP_HASHES=abab…ab` (64 hex) and `WB_SERVER__RESTART_NOTICE_SECS=3`, then `WB_CONTAINER=<name> WB_CONTAINER_ADDR=127.0.0.1:<port> cargo test -p server --test ops -- --ignored container` (joins a room, `docker kill --signal TERM`, expects the notice, `run_result{room_closed}` and close 1012; measured on the N10.2 image: notice at once, handover and exit 0 after 3.05 s; an idle `docker stop` exits in 0.3 s).

### The planned restart

Spec: "the server broadcasts a notice 60 seconds before a planned restart. Clients reconnect automatically and rejoin the same private room by code, or Quick Join again". Room state lives in memory, so a restart ends it; the rule we implement (proposed as MP-D13):

1. **SIGTERM** (a Coolify redeploy or stop, `docker stop`) starts the drain:
   - `server_notice{kind: restart, seconds: 60, text}` goes to every live session, reminders at 30 and 10 s left (`server.restart_notice_reminders_secs`), and a session that signs in during the drain gets it right after its `Welcome` with the seconds left;
   - no new rooms and no new seats: `room_create`, Quick Join and joins answer a non-fatal `server_full` ("The server is restarting. Try again in a minute."); a **held** seat can still be taken back (a player whose connection blipped);
   - `/api/v1/health` answers **503 `{"status":"draining"}`**, so a proxy that watches health (and Docker's `HEALTHCHECK`) stops sending new players here;
   - the notice ends early once nobody is connected (an idle server exits at once), or on a second SIGTERM / Ctrl-C.
2. **Handover.** Every room closes at its next tick: each active run ends as `run_result{end_reason: room_closed}` with its official banked score (verified runs are written to the boards, and `Server::run` waits for those writes); the result goes out in that tick's frame; the seats end **without** `room_left` (that would send the client to the hub). The rooms' codes and settings are written to `room-handover.json` beside the database (on the volume), valid for `server.handover_ttl_secs` (600).
3. **Close.** Every socket gets its queued frames, then close **1012** (service restart). The WAL is checkpointed and the process exits 0.
4. **The next instance** recreates a handed-over room when a player sends `room_join_code` with its code (read from the file when the join arrives, so it works whether the new container starts after the old one exits or alongside it). The first player back becomes the host of a private room; everyone gets a fresh seat and a fresh run (3 s protection) where the room places them.

What does not survive a restart: seats and runs (a run ends with its banked score kept, as after a reconnect past the 15 s hold), the host, the kick list, and parties (in memory; members rejoin the room by code without the party). Public rooms come back the same way (the client rejoins by the code it has); a player whose room is gone gets `room_not_found` and goes back to the hub, where Quick Join works as usual.

**The client** (N10.2, `src/net/rooms/room_session.gd`, `src/ui/hud/room_hud.gd`, `src/run/run_room.gd`): a `server_notice{restart}` shows a **SERVER RESTART · n S** countdown in the room banner; when the socket drops, the reconnect window is `NetTuning.room_restart_rejoin_window_s` (90 s) instead of 15 s; the rejoin by code lands in the recreated room and its placement starts a fresh run; the `room_closed` result shows as a RUN ENDED toast with the score. A hub (lobby) connection dropped by a restart reconnects quietly. Other notices (`info`, `maintenance`) show their text in the banner.

**Stop timeout.** The container must be given longer than the notice to stop: `docker-compose.yml` sets `stop_grace_period: 75s` (notice 60 s + handover + `server.shutdown_grace_ms` 5 s). If the platform stops containers with a shorter timeout (see OPERATIONS.md → Coolify stop timeout), set `WB_SERVER__RESTART_NOTICE_SECS` below it; a SIGKILL mid-notice loses the handover (players go back to the hub) and the runs in progress (unrecorded).

### Admin API

A second loopback listener, `admin.bind` (`127.0.0.1:9091`), **on only when `admin.token` is set** (`WB_ADMIN__TOKEN`, 32+ bytes; the CLI inside the container reads the same variable). Every request needs `Authorization: Bearer <token>` (constant-time check); refusals are counted (`wb_admin_denied_total`) and logged without the token.

| Route | What |
| --- | --- |
| `GET /admin/v1/stats` | `{"version","build","uptime_secs","draining","restart_in_secs","sessions","connections","rooms","seats","public_rooms","private_rooms"}` |
| `GET /admin/v1/rooms` | `[{"room_id","code","visibility","players","max_players","density","night","accounts":[...]}]` |
| `POST /admin/v1/rooms/{code or id}/close` `{"message"}` | Closes the room at its next tick: runs end `room_closed` (scores kept), the message goes out as `server_notice{info}`, then `room_left{closed}`. 404 for an unknown room. Logged to `admin_log` (actor `api`, `room_close`) |
| `POST /admin/v1/notice` `{"kind":"info|maintenance|restart","seconds","text"}` | A `server_notice` to every live session; `{"sessions": n}`. Logged (`notice`) |
| `POST /admin/v1/kick/{account_id}` `{"reason":"banned|revoked|closed"}` | Ends the account's session now (a fatal `banned` / `auth_failed`, or a close); `{"kicked": bool}` |
| `POST /admin/v1/boards/invalidate` | Drops the cached board tops (the CLI calls it after board changes) |

### Admin CLI (full)

`westbound-server admin <command>` inside the container (Coolify **Terminal**, or `docker exec <container> westbound-server admin ...`). PLAYER is an account id or `name#1234` (case-insensitive). Every change is logged to `admin_log` (actor `cli`); `admin log` shows it. Commands marked *live* need the admin API (the running server); the rest work on the database alone (also with the server stopped).

| Command | What |
| --- | --- |
| `player PLAYER` | Account, name, created / last seen, linked providers, ban (and the last ban's reason), crew, friends, runs, reports against / by, leaderboard entries |
| `ban PLAYER 7d [--reason "..."]` | `30m`, `12h`, `7d`, `2w` or `perm`; the live session ends at once when the API is on (else within `gateway.ban_recheck_ms`) |
| `unban PLAYER`, `rename PLAYER "Name"` | As before (N1.1) |
| `delete-player PLAYER --yes` | Deletes the account and all its data, like the in-game deletion; ends the live session |
| `kick PLAYER` | *live*: ends the session now (they can sign in again unless banned) |
| `reports [--unhandled] [--limit N]`, `report-handle ID` (alias `report-resolve`) | The reports queue (N9.1) |
| `crew-rename`, `crew-disband` | As before (N9.1) |
| `remove-run RUN`, `remove-entry BOARD PERIOD ID` | As before (N7.1); the running server's cached tops are dropped at once when the API is on |
| `recompute BOARD PERIOD` | Rebuilds a board period from the runs (each player's best eligible run; on `loop_crew` each crew's sum), in one transaction |
| `replays`, `replay-requeue [RUN]` | The replay queue (N8.1); N10.3: `set_aside` jobs are counted and listed apart (build, upload time, reason), purged ones as `set_aside_purged` |
| `replay-purge-set-aside [--older-than 30d]` | N10.3: deletes the files of set-aside jobs uploaded longer ago (`30m`, `12h`, `7d`, `2w`); their runs stay "verifying" |
| `housekeeping` | N10.3: the daily housekeeping pass and the replay sweep, now; prints the counts |
| `rooms` | *live*: one line per room: id, code, visibility, players, density, night, accounts |
| `room-close CODE [-m "message"]` | *live*: closes a room with a message |
| `notice "text" [--kind maintenance] [--seconds 600]` | *live*: a notice to every connected player |
| `stats` | Database stats (accounts, new / seen in 24 h and 7 d, bans, runs by mode, entries, crews, friendships, reports, replay queue, DB size, the last backup), N10.3's `disk_*` and `backup_*` lines, plus the live ones when the server answers |
| `log [--limit N]` | The admin log, newest first |
| `backups` | The dated backups in `backup.dir` with sizes and ages; N10.3: how many are kept, `newest: <file> <h> h old: ok` or `STALE`, the volume's free space |

Top-level: `backup PATH` (now verified), `verify-backup PATH` (integrity check and the migrations it holds), `restore BACKUP [--force]` (below).

### Rate limits: every route and message type

The review found the public pages, the health route and the WebSocket upgrades without any limit, and `room_create` limited only per connection (a client reconnecting in a loop could create a room every few hundred milliseconds, and empty rooms live 60 s, so one account could fill the 40-room cap). Both are fixed; every limit is in the config.

**HTTP** (`tower_governor`; IPv6 keyed by /64; the client IP behind the proxy as in "Client IPs behind the proxy"; `429 rate_limited` with `Retry-After`):

| Routes | Key | Default | Config | Test |
| --- | --- | --- | --- | --- |
| **every route** (API, upgrades, health, `/.well-known/*`, `/r/*`, 404s), on top of the rows below | IP | 600 / min, burst 200 | `rate_limits.ip_per_minute`, `ip_burst` | `ops.rs` `every_route_is_limited_per_ip_and_upgrades_too` |
| `GET /ws`, `GET /ws/echo` (upgrades) | IP | 60 / min, burst 30 | `rate_limits.ws_connect_*` | same |
| `POST /auth/device` | IP | 5 / h, burst 5 | `rate_limits.device_create_*` | `tests/ratelimit.rs` |
| other `/auth/*` | IP | 30 / min, burst 10 | `rate_limits.auth_*` | `tests/ratelimit.rs` |
| `/me`, `/account`, `/boards/*`, `/runs*`, `/runs/{id}/replay`, friends, blocks, presence, crews, reports | account (IP without a valid token) | 120 / min, burst 30 | `rate_limits.account_*` | `tests/ratelimit.rs` |
| `POST /runs`, `/runs/legacy`, `/runs/{id}/replay` (also) | account | 30 / h, burst 10 | `rate_limits.runs_*` | `tests/runs.rs` |
| `POST /friends/requests`, `/blocks`, `/crews`, `/crews/join`, `/reports` (also) | account | 60 / h, burst 20 | `rate_limits.social_*` | `tests/social.rs` |
| `POST /reports` (also) | account, counted in the DB | 10 per rolling 24 h | `social.reports_per_day` | `tests/social.rs` |
| `/metrics`, `/admin/v1/*` | loopback listeners (token for admin) | none: not reachable from outside | `metrics.bind`, `admin.bind` | `tests/config.rs` (loopback only), `tests/ops.rs` (token) |

Also: JSON bodies are capped at `http.max_body_bytes` (4 KB; replay uploads at `replays.max_bytes`), and connections at 400 (`limits.max_connections`, HTTP 503 past it).

**WebSocket, per connection** (token buckets, `ws_rate_limits.*`; an over-limit message is dropped and counted, a non-fatal `rate_limited` at most once a second, and a flood that empties the violation bucket gets a fatal `rate_limited`):

| Message type | Per second | Burst | Test |
| --- | --- | --- | --- |
| `hello` | not limited: a second one is a fatal `malformed` | | `tests/gateway.rs` |
| `ping` | 2 | 5 | every type: `msg_limits.rs` `every_type_has_its_configured_bucket` (own bucket, burst, refill, independent); over real sockets: `tests/gateway.rs` `rate_limits_drop_then_disconnect` |
| `lobby_command` (rooms, parties, presence, browse) | 5 | 10 | as above |
| `player_state` | 25 | 40 | as above |
| `score_claim` | 10 | 20 | as above |
| `hit_report` | 5 | 10 | as above |
| `run_event` | 2 | 5 | as above |
| `quick_chat` | 1 | 3 | as above |
| `room_host_command` | 2 | 5 | as above |
| violation bucket | 5 | 100 | `msg_limits.rs` `drops_then_disconnects`, `tests/gateway.rs` (flood → fatal) |
| **`room_create`, per account** (survives reconnects) | 30 / h | 5 | `ops.rs` `room_create_is_limited_per_account_across_reconnects` |

Plus the per-message size cap (16 KB, close 1009), the 64-frame outbound queue (a slow client is dropped), and the room cap (40, `server_full`).

### Backups

- **Nightly** (as before): `VACUUM INTO` a `.tmp` file, then (N10.2, `backup.verify`) the copy is opened read-only and `PRAGMA integrity_check` must say `ok`, then it is renamed to `westbound-YYYY-MM-DD.db`; N10.3: only the newest `backup.retention_days` (3) dated files stay (a count, newest kept, the new one never deleted; a failed or skipped run deletes nothing). A copy that fails the check is deleted and the run counts as failed (`wb_backups_failed_total`, `wb_backup_verify_failed_total`).
- **Metrics:** `wb_backup_last_success_timestamp_seconds`, `wb_backup_last_size_bytes`, `wb_backup_last_duration_seconds` (since the process started).
- **Off-site hook** (optional, `backup.upload_command`): after each good backup the server runs this argv, `{file}` replaced by the backup's path, no shell, killed after `backup.upload_timeout_secs`; exit 0 counts in `wb_backup_uploads_ok_total`, anything else in `_failed_total` and an ERROR log. The runtime image has no shell or tools, so the command must be a static binary on the volume (for example `rclone`); OPERATIONS.md has the recipe. No cloud credentials are in the repository.
- **Restore** (`westbound-server restore BACKUP`): refuses while anything answers on `server.bind` (stop the server first; `--force` overrides), verifies the backup, moves the current database and its `-wal` / `-shm` aside to `<db>.before-restore-<unix secs>` (nothing is deleted), copies the backup into place, applies newer migrations and logs `restore` to `admin_log`. Tested: `backup.rs` (backup → change → restore brings the old rows back), `ops.rs` `a_backup_restores_into_a_fresh_server` (a device account signs in on a fresh server restored from the backup), `cli.rs` (refusals).

### Logs

- **Format:** JSON lines on stderr in the image (`WB_LOG__FORMAT=json` is set in the Dockerfile; `text` for a terminal): `timestamp`, `level`, `target`, the event's fields flattened, and the current span.
- **Request ids:** every HTTP request gets an id (`X-Request-Id` from the client when it is 1–64 characters of `[A-Za-z0-9._-]`, else a new `<8 hex>-<12 hex>`); it is in the request's span (`req_id`) and echoed in the response's `X-Request-Id`. WebSocket lines carry `client` (a keyed IP hash), `account` and `session`.
- **Never logged:** tokens, secrets, IPs (only keyed hashes), request bodies, query strings.
- **New lines:** `restart: draining`, `restart notice sent`, `restart reminder sent`, `rooms handed over`, `handed-over room restored`, `room closed` (mode), `admin API request` (method, path, status), `admin API request refused (token)`, `backup copied off-site`, `off-site backup hook failed`.

### Metrics added

| Metric | What |
| --- | --- |
| `wb_server_draining` | 1 during a restart's notice |
| `wb_server_notices_total` | Notice broadcasts (restart notices, reminders, admin notices) |
| `wb_rooms_handed_over_total`, `wb_rooms_restored_total` | Rooms handed to the next instance; recreated by a rejoin |
| `wb_room_create_limited_total` | `room_create` refused by the per-account limit |
| `wb_admin_requests_total`, `wb_admin_denied_total` | Admin API requests served / refused |
| `wb_backup_last_success_timestamp_seconds`, `wb_backup_last_size_bytes`, `wb_backup_last_duration_seconds`, `wb_backup_verify_failed_total`, `wb_backup_uploads_ok_total`, `wb_backup_uploads_failed_total` | Backups |
| `wb_db_probe_seconds`, `wb_db_probe_failures_total` | A timed query through the pool every `metrics.db_probe_interval_secs` (15 s): database latency |
| `wb_db_file_bytes`, `wb_db_wal_bytes`, `wb_db_pool_connections`, `wb_db_pool_idle` | Database sizes and pool |
| `wb_replay_jobs{status}` | Replay queue depth (`pending`) and the other states; N10.3 adds `set_aside` (parked jobs still holding their file) |
| `wb_reports_unhandled` | The moderation queue |
| `wb_log_events_total{level}` | Every WARN and ERROR logged (one alert covers every logged failure) |
| `wb_disk_free_bytes`, `wb_disk_total_bytes`, `wb_disk_low` | N10.3: the data volume and the low-space flag (`housekeeping.min_free_mb`) |
| `wb_disk_data_bytes`, `wb_disk_replays_bytes`, `wb_disk_replays_files`, `wb_disk_backups_bytes`, `wb_disk_other_bytes` | N10.3: what the data directory holds (the database is `wb_db_file_bytes` + `wb_db_wal_bytes`) |
| `wb_backup_files`, `wb_backup_newest_timestamp_seconds`, `wb_backup_newest_age_seconds`, `wb_backup_stale`, `wb_backups_skipped_total` | N10.3: the dated backups on the volume (survives restarts, unlike `wb_backup_last_success_timestamp_seconds`), staleness past `backup.max_age_hours`, backups skipped for want of space (also in `wb_backups_failed_total`) |
| `wb_housekeeping_rows_deleted_total{table}`, `wb_housekeeping_last_run_timestamp_seconds`, `wb_housekeeping_failures_total`, `wb_db_wal_checkpoints_total`, `wb_db_vacuums_total` | N10.3: the housekeeping (tables `shadow_contacts`, `admin_log`, `reports`, `leaderboard_entries`, `runs`, `replays_set_aside`) |
| `process_cpu_seconds_total`, `process_resident_memory_bytes`, `process_threads`, `process_open_fds`, `process_start_time_seconds` | The process (from `/proc`) |

Coverage by area: rooms (`wb_rooms`, `wb_room_seats`, joins, reconnects, placements), ticks (`wb_room_tick_seconds` histogram), bytes (`wb_ws_bytes_in_total` / `_out_total`, frames), claims (`wb_room_claims_total{verdict,reason}`), offences (`wb_room_offences_total{kind}`), DB latency (above), queue depths (replays, reports, `wb_room_dropped_total{reason="queue_full"}`), errors (`wb_log_events_total`, `wb_http_requests_total{class="5xx"}`, `wb_ws_handshakes_total{result="internal"}`).

## Housekeeping (N10.3)

WP N10.3, `crates/server/src/housekeeping.rs` (with `backup.rs`, `replays/retention.rs`, `metrics.rs`, `metrics_admin.rs`, `admin.rs`). The owner's server has a small disk ("keep at most 3 daily backups"), so everything the server writes under `/data` is capped. The owner's view, with the expected sizes: [OPERATIONS.md → Disk space](OPERATIONS.md#disk-space). Tests: `tests/housekeeping.rs`, `tests/replays.rs` (set aside, current periods, 503), `tests/cli.rs` (the N10.3 part), `tests/config.rs`, unit tests in `backup.rs`.

What lives on the volume and what caps it:

| What | Cap |
| --- | --- |
| `westbound.db` | The row retentions below; a `VACUUM` when worth it |
| `westbound.db-wal`, `-shm` | `PRAGMA wal_checkpoint(TRUNCATE)` at every disk check (5 min) and at shutdown |
| `backups/westbound-YYYY-MM-DD.db` | `backup.retention_days` (3) files, a count |
| `backups/*.db` (manual, pre-deploy), `westbound.db.before-restore-*` | `backup.other_retention_days` (7 days); stray `backups/*.tmp` after a day |
| `replays/*.wbr` | Verified: only while in a current top 100. Set aside: `replays.set_aside_retention_days` (30). Pending: until verified (needs the verifier running). Uploads wait (503) below the floor |
| `replays/work/`, stray uploads | The hourly sweep (an hour) |
| `room-handover.json` | Overwritten at each restart; deleted once expired (daily pass) |
| `well-known/`, `bin/` (an off-site `rclone`) | The owner's files, counted in `wb_disk_other_bytes` |
| Logs | Not on the volume: stdout, kept by Docker on the host (OPERATIONS.md → Disk space) |

**The disk check** (every `check_interval_secs`, 300; the first at startup, with the file prunes so a lower `backup.retention_days` takes effect at the deploy): walks the data directory (and the replay and backup directories when they are elsewhere) and reads the volume's free space (`statvfs`, for the server's user) into the `wb_disk_*` gauges; below `min_free_mb` it sets `wb_disk_low` and logs `disk space low on the data volume` (repeated every 6 h while it holds); then the backups' freshness (`wb_backup_*`; `the newest backup is stale` past `backup.max_age_hours`, repeated every 6 h; a volume with no backup at all only once the server has been up that long); then a WAL checkpoint.

**The daily pass** (`time_utc`, 03:47 UTC, after the 03:17 backup so the backup still holds what it deletes; `admin housekeeping` by hand). Each step runs even if another failed; failures are logged and counted (`wb_housekeeping_failures_total`); a `housekeeping pass` INFO line and an `admin_log` row (`system housekeeping`) carry the counts. Deletes go in batches of `batch_rows` (500) with `batch_pause_ms` (50) between full batches, so other writers get the database in between:

1. `shadow_contacts` older than `shadow_contacts_days` (30);
2. `admin_log` older than `admin_log_days` (365);
3. handled `reports` older than `reports_days` (365); unhandled ones stay;
4. `leaderboard_entries` of Daily Drive days and Journey weeks older than `board_periods_days` (90; the period containing that day stays); Loop seasons and all-time boards stay. The running server drops its board cache after;
4b. expired `crew_invites` (no retention to configure: every read ignores them already; `wb_housekeeping_rows_deleted_total{table="crew_invites"}`);
5. `runs` older than `runs_days` (90) that hold no board entry, walking the table by id. Kept whatever their age: legacy uploads (their row is the once-per-board rule), runs still `pending` (waiting for their replay), runs whose replay file is still there. A run's idempotent answer is only needed for minutes. Consequence: after a removal (`admin remove-run`) or a `recompute`, a board can only fall back to runs from the last 90 days or ones that hold another entry;
6. the dated backups down to their count, other copies past their age (as at startup);
7. `room-handover.json` once it has expired;
8. `VACUUM` when at least `vacuum_min_free_pct` (25 %) of the file is free pages, the file is at most `vacuum_max_mb` (1024) and the volume has room for two copies plus `min_free_mb`; then a WAL checkpoint (`wb_db_vacuums_total`). After pruning, freed pages are reused by new rows anyway, so the file stops growing even without a VACUUM; the VACUUM only gives space back after a large prune.

Expired refresh tokens are deleted hourly (`app::maintenance`, as before); accounts are never deleted by age.

**Low space** (free below `min_free_mb`): the nightly backup is skipped with an ERROR `nightly backup skipped: not enough disk space` (`wb_backups_skipped_total` and `wb_backups_failed_total`; nothing is deleted), and it also skips when the free space minus a copy of the database (file + WAL) would fall below the floor; replay uploads answer 503 `storage_low` (`Retry-After: 3600`; the game retries). Everything else keeps working.

### Configuration

`[housekeeping]` (env `WB_HOUSEKEEPING__<KEY>`); retentions in days, 0 keeps the rows:

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | The disk check and the daily pass inside `serve` (`admin housekeeping` works either way) |
| `time_utc` | `03:47` | The daily pass, UTC `HH:MM` |
| `check_interval_secs` | `300` | The disk check |
| `min_free_mb` | `500` | The low-space floor (backups skip, replay uploads wait, `wb_disk_low`) |
| `shadow_contacts_days` | `30` | `shadow_contacts` rows |
| `admin_log_days` | `365` | `admin_log` rows (0, or at least 30) |
| `reports_days` | `365` | Handled reports |
| `board_periods_days` | `90` | Past Daily Drive days and Journey weeks (0, or at least 8) |
| `runs_days` | `90` | Runs holding no board entry (0, or at least 30) |
| `batch_rows` / `batch_pause_ms` | `500` / `50` | Rows per delete (1..=10000), the pause between full batches |
| `vacuum_min_free_pct` / `vacuum_max_mb` | `25` / `1024` | When a `VACUUM` is worth it (0 % = never) and the largest file it rewrites |

With `backup.retention_days`, `backup.max_age_hours`, `backup.other_retention_days` (Configuration reference) and `replays.set_aside_retention_days` (Replays → Configuration).

## Configuration reference

Configuration is layered: defaults, then the TOML file (`--config` / `WB_CONFIG`), then environment variables named `WB_<SECTION>__<KEY>` (double underscore). Each environment value is parsed as the key's type. Lists are comma-separated. Unknown keys or bad values in the file or the environment stop startup with every error listed. `RUST_LOG` overrides `log.level`. The defaults are production values: `config/server.example.toml` lists them all, and a test keeps it in sync.

| Key | Env | Default | Meaning |
| --- | --- | --- | --- |
| `server.env` | `WB_SERVER__ENV` | `production` | `production` or `dev`. Outside `dev` the two auth secrets are required; `dev` falls back to public development values when they are empty |
| `server.bind` | `WB_SERVER__BIND` | `0.0.0.0:8080` | Public listener (API, `/ws`, deep links) |
| `server.public_origin` | `WB_SERVER__PUBLIC_ORIGIN` | `https://westbound.sipsakrandevu.com` | Public https origin behind the proxy (invite links from N9) |
| `server.worker_threads` | `WB_SERVER__WORKER_THREADS` | `2` | tokio workers (spec: 2) |
| `server.shutdown_grace_ms` | `WB_SERVER__SHUTDOWN_GRACE_MS` | `5000` | On SIGTERM, time for in-flight requests and close frames |
| `server.restart_notice_secs` | `WB_SERVER__RESTART_NOTICE_SECS` | `60` | N10.2: on SIGTERM, seconds of `server_notice{restart}` before the room handover and close 1012 (ends early when nobody is connected). 0 = no notice. Keep it below the platform's stop timeout |
| `server.restart_notice_reminders_secs` | `WB_SERVER__RESTART_NOTICE_REMINDERS_SECS` | `30,10` | Reminders, as seconds left |
| `server.handover_ttl_secs` | `WB_SERVER__HANDOVER_TTL_SECS` | `600` | The next instance recreates a handed-over room on a rejoin by code within this long |
| `log.level` | `WB_LOG__LEVEL` | `info` | tracing filter (`info,westbound_server=debug`) |
| `log.format` | `WB_LOG__FORMAT` | `text` (image: `json`) | `text` or `json` |
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
| `metrics.db_probe_interval_secs` | `WB_METRICS__DB_PROBE_INTERVAL_SECS` | `15` | N10.2: the database probe (latency, sizes, pool, queue depths) |
| `admin.enabled` | `WB_ADMIN__ENABLED` | `true` | N10.2: serve the admin API (it also needs a token) |
| `admin.bind` | `WB_ADMIN__BIND` | `127.0.0.1:9091` | Must be a loopback address |
| `admin.token` | `WB_ADMIN__TOKEN` | empty | N10.2: bearer token (32+ bytes, environment only, redacted). Empty: the admin API is off and the live admin commands are unavailable |
| `admin.request_timeout_ms` | `WB_ADMIN__REQUEST_TIMEOUT_MS` | `10000` | How long an `admin` command waits for the server |
| `backup.enabled` | `WB_BACKUP__ENABLED` | `true` | Nightly backup task |
| `backup.dir` | `WB_BACKUP__DIR` | `/data/backups` | Where dated backups go |
| `backup.time_utc` | `WB_BACKUP__TIME_UTC` | `03:17` | Nightly run time, UTC `HH:MM` |
| `backup.retention_days` | `WB_BACKUP__RETENTION_DAYS` | `3` | N10.3: **how many** dated daily backups stay (1..=31): after each good backup the older ones beyond this go, newest first kept, the new one never deleted; a failed or skipped backup deletes nothing (was: days, 7) |
| `backup.max_age_hours` | `WB_BACKUP__MAX_AGE_HOURS` | `26` | N10.3: the newest dated backup older than this is stale (`wb_backup_stale`, a warning, `admin backups`) |
| `backup.other_retention_days` | `WB_BACKUP__OTHER_RETENTION_DAYS` | `7` | N10.3: other `.db` files in `backup.dir` (manual, pre-deploy) and `<db>.before-restore-*` are deleted this long after they were written; 0 keeps them. Stray `.tmp` files go after a day |
| `backup.verify` | `WB_BACKUP__VERIFY` | `true` | N10.2: integrity check of each backup before it replaces anything |
| `backup.upload_command` | `WB_BACKUP__UPLOAD_COMMAND` | empty | N10.2: off-site hook after each good backup: argv (comma-separated in the env), `{file}` = the backup |
| `backup.upload_timeout_secs` | `WB_BACKUP__UPLOAD_TIMEOUT_SECS` | `600` | The hook is killed after this long |
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
| `rate_limits.ip_per_minute` / `_burst` | `WB_RATE_LIMITS__IP_PER_MINUTE` / `__IP_BURST` | `600` / `200` | N10.2: every route per client IP, on top of the route's own limit |
| `rate_limits.ws_connect_per_minute` / `_burst` | `WB_RATE_LIMITS__WS_CONNECT_PER_MINUTE` / `__WS_CONNECT_BURST` | `60` / `30` | N10.2: WebSocket upgrades per client IP |
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
| `deeplinks.web_join_url` | `WB_DEEPLINKS__WEB_JOIN_URL` | `https://b3vet.github.io/westbound/?room={code}` | N9.3: the invite page's PLAY IN THE BROWSER (`{code}`; `{origin}` = `server.public_origin`) |
| `deeplinks.apple_app_ids` / `android_package` / `android_cert_sha256` | `WB_DEEPLINKS__APPLE_APP_IDS` (comma-separated), `…__ANDROID_PACKAGE`, `…__ANDROID_CERT_SHA256` | empty | N9.3: generate the association files (a file in `deeplinks.dir` wins) |
| `deeplinks.app_store_url` / `play_store_url` / `app_scheme` | `WB_DEEPLINKS__APP_STORE_URL`, `…__PLAY_STORE_URL`, `…__APP_SCHEME` | empty | N9.3: the invite page's store links ("coming soon" while empty) and OPEN THE APP |
| `leaderboards.*`, `runs.*` | `WB_LEADERBOARDS__…`, `WB_RUNS__…` | see "Leaderboards & runs API → Configuration" | Views, cache, replay trigger, legacy caps; plausibility thresholds |
| `replays.*` | `WB_REPLAYS__…` | see "Replays and verification → Configuration" | Replay files, size cap, the verifier command, the queue, retention |
| `housekeeping.*` | `WB_HOUSEKEEPING__…` | see "Housekeeping (N10.3) → Configuration" | Disk check, low-space floor, row retention, batches, VACUUM |
| `rate_limits.social_per_hour` / `_burst` | `WB_RATE_LIMITS__SOCIAL_PER_HOUR` / `__SOCIAL_BURST` | `60` / `20` | Social writes per account, on top of the account limit (see "Social API") |
| `social.*` | `WB_SOCIAL__…` | see "Social API → Configuration" | Friend, request and block caps; crew size and invite codes; the report limit |
| `rooms.*` | `WB_ROOMS__…` | see "Rooms → Configuration" | Seats, holds and delays, spawns, the room clock, room queues, plausibility limits, room traffic |
| `rooms.create_per_hour` / `create_burst` | `WB_ROOMS__CREATE_PER_HOUR` / `__CREATE_BURST` | `30` / `5` | N10.2: `room_create` per account (survives reconnects) |
| `scoring.*` | `WB_SCORING__…` | see "Scoring (N6.1) → Configuration" | Claim tolerances, the official lag, score syncs, crew proximity, trains, hit detection, verification |

The image sets `WB_SERVER__BIND`, `WB_DB__PATH`, `WB_BACKUP__DIR` and `WB_DEEPLINKS__DIR` to the values above, and `WB_LOG__FORMAT=json` (N10.2). It needs no config file.

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
   - On pushes to `main` only (merged pull requests), logs in to GHCR with `GITHUB_TOKEN` (`packages: write`) and pushes these tags:
     - `ghcr.io/<owner, lowercased>/westbound-server:edge`
     - `:main-<sha7>`

## Coolify setup

Coolify already has a GHCR registry token for the owner's other projects, so private pulls from `ghcr.io/b3vet/...` work. CI must have pushed the image at least once: see the Actions tab, workflow "Server".

1. **DNS.** Point an `A` (and `AAAA`, if the VPS has IPv6) record for `westbound.sipsakrandevu.com` at the VPS, before the first deploy, so the proxy can get a certificate.
2. **New resource.** Go to Project, then **+ New**, then **Docker Image**. Image: `ghcr.io/b3vet/westbound-server`, tag `edge`. Pick the server or destination that has the GHCR credentials.
3. **Domain and port.** Under General:
   - Set **Domains** to `https://westbound.sipsakrandevu.com`.
   - Set **Ports Exposes** to `8080`.
   - Leave **Ports Mappings** empty. The proxy reaches the container over Coolify's network.
4. **WebSockets.** No extra setting. Coolify's proxy, Traefik or Caddy, passes `Upgrade` requests through, so `wss://westbound.sipsakrandevu.com/ws` reaches the container on the same domain. Don't add path rules: the server answers `/api/*`, `/ws`, `/.well-known/*` and `/r/*` (invite links, N9.3) itself, and returns 404 for everything else. **N9.3: if the proxy only routes `/api/*` and `/ws` to the container (MP-D1's wording), add `/r/*` and `/.well-known/*` too**, or route the whole domain to it.
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
8. **Stop grace.** Coolify stops containers with SIGTERM. N10.2: the server then sends players the 60 s restart notice (ends at once when nobody is connected), hands the rooms over, closes every socket with 1012, checkpoints the WAL and exits. The stop timeout must be longer than the notice: the compose file sets `stop_grace_period: 75s`. For a "Docker Image" resource see OPERATIONS.md → "Coolify stop timeout" (lower `WB_SERVER__RESTART_NOTICE_SECS` if Coolify's timeout is shorter).
9. **Admin token.** Set `WB_ADMIN__TOKEN=<openssl rand -hex 32>` (a secret) to turn on the admin API for the live admin commands (rooms, notices, kicks, immediate ban kicks).
10. **Deploy.** Check the logs for a `listening` line with the version and build. Open `https://westbound.sipsakrandevu.com/api/v1/health`.
11. **Updates.** Each CI push moves the `edge` tag. Redeploy in Coolify, or enable its webhook / auto-update, to pull the new image. Roll back by deploying a `claude-game-implementation-phases-asl5jz-<sha7>` tag.

Deploying with Docker Compose works too: create the resource from `westbound-server/docker-compose.yml` (service `westbound-server`, same domain and port). The compose file carries the volume, environment, health check and stop grace. Its `caddy` service is in the `local-tls` profile and is not started.

## Backups and restore

- **Nightly:** at `backup.time_utc` (UTC), the server writes `/data/backups/westbound-YYYY-MM-DD.db`.
  - The copy is taken online with `VACUUM INTO`, written to a `.tmp` file and then renamed.
  - Only the newest `backup.retention_days` (3, N10.3: a count) dated files stay; manual copies go after `backup.other_retention_days` (7). A backup is skipped (an error, `wb_backups_skipped_total`) when the volume has no room for a copy of the database plus `housekeeping.min_free_mb`.
  - Each run is logged, recorded in `admin_log` and counted in `wb_backups_ok_total` / `wb_backups_failed_total`.
- **Verified** (N10.2): each copy passes `PRAGMA integrity_check` before it replaces anything.
- **Off the machine:** add Coolify's volume backups (Persistent Storage, then Backups), copy `/data/backups` elsewhere, or (N10.2) set the off-site hook `WB_BACKUP__UPLOAD_COMMAND` (OPERATIONS.md → Off-site copies).
- **Manual:** `docker exec <container> westbound-server backup /data/backups/manual-$(date +%F).db` (from Coolify: the resource's **Terminal**, or the host shell). `westbound-server verify-backup <file>` checks one; `westbound-server admin backups` lists them.

To restore (N10.2: the `restore` command; OPERATIONS.md → Restore has the full procedure):

1. Stop the resource in Coolify.
2. Run the image's `restore` against the volume (it keeps the current database as `westbound.db.before-restore-<time>`, verifies the backup, applies newer migrations):

   ```sh
   docker run --rm -v <volume>:/data ghcr.io/b3vet/westbound-server:edge restore /data/backups/westbound-2026-09-28.db
   ```
3. Start the resource and check `/api/v1/health`.

By hand (the pre-N10.2 way, still valid):

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
