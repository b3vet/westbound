# Westbound server runbook

`westbound-server` is the Westbound Online backend: one Rust binary with the HTTP API, the WebSocket gateway and SQLite. Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md). Plan: [`MULTIPLAYER_PLAN.md`](MULTIPLAYER_PLAN.md). Deployment follows MP-D1: a Docker image built by GitHub Actions, pushed to GHCR and run by Coolify, whose proxy terminates TLS.

As of N0 the server has:

- the health route;
- a WebSocket echo on `/ws`, with the spec's limits;
- config, logging and metrics;
- SQLite with migrations and nightly backups;
- the deep-link files;
- graceful shutdown.

| Path | What |
| --- | --- |
| `westbound-server/crates/server/` | The binary (`westbound-server`) and its library, with integration tests in `tests/` |
| `westbound-server/migrations/` | sqlx migrations (SQLite) |
| `westbound-server/.sqlx/` | Offline query metadata for the `sqlx::query!` macros (committed) |
| `westbound-server/config/` | `server.example.toml` (every key with its default), `dev.toml`, deep-link placeholders |
| `westbound-server/Dockerfile`, `docker-compose.yml`, `deploy/` | Image, compose file (Coolify and local), local TLS (`Caddyfile`, `local-tls.sh`) |
| `.github/workflows/server.yml` | CI: fmt, clippy, tests, image build, GHCR push |
| `tools/net_echo_check.gd`, `tools/web_smoke/ws_echo.mjs` | Echo checks from Godot and from Chromium |

## Routes

| Route | Listener | What |
| --- | --- | --- |
| `GET /api/v1/health` | public `:8080` | `{"status":"ok","version":"0.1.0","build":"<sha>","db":"ok"}`. Returns 503 with `"status":"degraded"` when the database does not answer |
| `GET /ws` | public | WebSocket. N0 echoes text and binary frames. Limits: 16 KB max inbound message (close 1009), a 64-frame outbound queue (a slow client is dropped), a ping every 2 s, and a close after 8 s of silence. Past 400 connections, the upgrade gets HTTP 503 |
| `GET /api/v1/echo-check` | public | A small HTML page that runs the WebSocket echo from any browser, used to check a phone (see "Verify a phone connects") |
| `GET /.well-known/apple-app-site-association`, `GET /.well-known/assetlinks.json` | public | Deep-link files, read from `deeplinks.dir`, with built-in empty placeholders |
| `GET /metrics` | **localhost only** `127.0.0.1:9090` | Prometheus text: `wb_ws_connections`, `wb_ws_frames_in_total` / `_out_total`, bytes, close reasons, `wb_http_requests_total{class}`, backups, `wb_build_info` |

## Local development

Rust 1.94 (`rustup`); everything runs from `westbound-server/`.

```sh
cd westbound-server
cargo run -p server -- --config config/dev.toml          # http://127.0.0.1:8080, DB in dev-data/
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

Every command reads the same config: `--config` or `WB_CONFIG`, then the `WB_*` environment variables.

### Database, migrations and sqlx offline data

- **Engine:** SQLite in WAL mode, with `synchronous=NORMAL`, foreign keys on and a busy timeout.
- **Times:** stored as unix seconds.
- **Secrets and tokens:** stored only as hashes.
- **Tables:** migration `0001` creates the tables N1 needs: `accounts`, `refresh_tokens` and `admin_log`. The other data-model tables come with their milestones.

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
tools/godot.sh --headless --script res://tools/net_echo_check.gd -- --url=wss://localhost:8443/ws --insecure
# NET_ECHO ok wss://localhost:8443/ws bytes=1024 rtt_ms=3

(cd tools/web_smoke && npm ci)    # once
node tools/web_smoke/ws_echo.mjs --server https://localhost:8443 --insecure
# WS_ECHO ok wss://localhost:8443/ws from http://127.0.0.1:41234/ rtt_ms=2 server=0.1.0 (abc1234) db=ok
```

`--insecure` accepts Caddy's self-signed certificate. It uses `TLSOptions.client_unsafe()` in Godot and `--ignore-certificate-errors` in Chromium, and exists in these dev tools only. Against the real domain, drop `--insecure`.

## Configuration reference

Configuration is layered: defaults, then the TOML file (`--config` / `WB_CONFIG`), then environment variables named `WB_<SECTION>__<KEY>` (double underscore). Each environment value is parsed as the key's type. Lists are comma-separated. Unknown keys or bad values in the file or the environment stop startup with every error listed. `RUST_LOG` overrides `log.level`. The defaults are production values: `config/server.example.toml` lists them all, and a test keeps it in sync.

| Key | Env | Default | Meaning |
| --- | --- | --- | --- |
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
| `auth.jwt_secret` | `WB_AUTH__JWT_SECRET` | empty | Access-token secret from N1; at least 32 bytes when set. Environment only, never logged |
| `http.cors_allowed_origins` | `WB_HTTP__CORS_ALLOWED_ORIGINS` | `https://westbound.sipsakrandevu.com,https://b3vet.github.io` | CORS allow-list for `/api/*`; `*` = any (local dev) |
| `deeplinks.dir` | `WB_DEEPLINKS__DIR` | empty (image: `/data/well-known`) | Directory with `apple-app-site-association` and `assetlinks.json` |

The image sets `WB_SERVER__BIND`, `WB_DB__PATH`, `WB_BACKUP__DIR` and `WB_DEEPLINKS__DIR` to the values above. It needs no config file.

## Docker image

- **Base:** `gcr.io/distroless/static-debian12:nonroot`, with CA certificates, no shell and no libc.
- **Binary:** a static musl binary at `/usr/local/bin/westbound-server`, built with cargo-chef so that dependencies are cached in their own layer.
- **User:** runs as the non-root user `65532`.
- **Ports and volumes:** `EXPOSE 8080`, `VOLUME /data`.
- **Health check:** `HEALTHCHECK` runs `westbound-server healthcheck`.
- **Size:** 3.6 MB compressed (what a registry pull downloads), 15 MB unpacked. The stripped binary is 5.9 MB.

```sh
cd westbound-server
docker build --build-arg WB_BUILD=$(git rev-parse --short HEAD) -t westbound-server:local .
docker run --rm -p 127.0.0.1:8080:8080 -v westbound-data:/data westbound-server:local
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
   - `WB_AUTH__JWT_SECRET=<openssl rand -hex 32>`: mark it as a secret. It is optional in N0 and required from N1.
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
2. On the phone, open `https://westbound.sipsakrandevu.com/api/v1/echo-check`. The page opens `wss://westbound.sipsakrandevu.com/ws`, sends 1024 bytes and shows **OK: echo over wss://... in N ms**. Try it on Wi-Fi and on cellular. This is the N0 "phone connects over wss://" check until the game has network code (N1/N2).
3. From a desktop, run the same echo with Godot's `WebSocketPeer` (no `--insecure` against the real certificate):

   ```sh
   tools/godot.sh --headless --script res://tools/net_echo_check.gd -- --url=wss://westbound.sipsakrandevu.com/ws
   node tools/web_smoke/ws_echo.mjs --server https://westbound.sipsakrandevu.com
   ```

   `ws_echo.mjs` runs the page on a local origin, so the CORS fetch passes only if `WB_HTTP__CORS_ALLOWED_ORIGINS` allows it. Use `--server` against a local server, or set `*` temporarily.
4. Watch the server side. The logs show a `websocket closed` line per connection, with the reason. For the counters, run `docker run --rm --network container:<container> curlimages/curl -s localhost:9090/metrics` on the host; the metrics listener is on the container's loopback.

## Troubleshooting

- **`invalid config:` at start.** The message lists every bad key. Run `check-config` with the same environment.
- **502 or 404 from the proxy.** Check that the container is *healthy* (`docker ps`), that Ports Exposes is `8080`, and that the domain matches exactly.
- **WebSocket closes with 1009.** A client sent more than 16 KB in one message.
- **Clients dropped under load.** Check `wb_ws_slow_client_closed_total` (outbound queue full) and `wb_ws_timeout_closed_total` (silence over 8 s).
- **Reading `/metrics`.** The endpoint listens on the container's loopback only. Share the container's network namespace to read it: `docker run --rm --network container:<c> curlimages/curl -s localhost:9090/metrics`. For health, run `docker exec <c> westbound-server healthcheck`.
