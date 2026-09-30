# Westbound Online: operations runbook

For the owner running `westbound-server` on Coolify. The technical reference is [`SERVER.md`](SERVER.md) (config keys, routes, the admin API, rate limits, metrics); this page is what to do. Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → "Resource budget and deployment", "Moderation". WP N10.2.

## At a glance

| What | Where |
| --- | --- |
| Image | `ghcr.io/b3vet/westbound-server:edge` (CI pushes it from the `claude/game-implementation-phases-asl5jz` branch); rollback tags `claude-game-implementation-phases-asl5jz-<sha7>` |
| Public | `https://westbound.sipsakrandevu.com` → container port 8080 (`/api/*`, `/ws`, `/r/*`, `/.well-known/*`) |
| Volume | `/data`: `westbound.db` (+ `-wal`, `-shm`), `backups/`, `well-known/`, `replays/`, `room-handover.json` |
| Inside the container only | `/metrics` on `127.0.0.1:9090`; the admin API on `127.0.0.1:9091` (needs `WB_ADMIN__TOKEN`) |
| Logs | stdout/stderr, JSON lines: Coolify → the resource → **Logs**, or `docker logs <container>` |
| Admin | On the VPS host: `docker exec <container> westbound-server admin ...` (`docker ps` shows the container name). The image has no shell, so Coolify's **Terminal** may not open; when it does, run `westbound-server admin ...` there. The examples below leave out the `docker exec <container>` prefix |

## Environment variables (Coolify → Environment Variables)

| Variable | Value | Why |
| --- | --- | --- |
| `WB_AUTH__JWT_SECRET` | `openssl rand -hex 32`, **secret** | Required; access tokens |
| `WB_AUTH__DEVICE_SECRET_PEPPER` | another `openssl rand -hex 32`, **secret** | Required; **never change it** (device accounts stop verifying). Back it up with the database |
| `WB_ADMIN__TOKEN` | a third `openssl rand -hex 32`, **secret** | N10.2: turns on the admin API for the live commands (rooms, notices, kicks, instant ban kicks). Without it those commands say "admin API is off"; everything else works |
| `WB_SERVER__RESTART_NOTICE_SECS` | `60` (default) | The restart notice. Must be shorter than the stop timeout (below) |
| `WB_LOG__FORMAT` | `json` (the image's default) | Structured logs |
| `WB_BACKUP__UPLOAD_COMMAND` | optional | Off-site copy after each nightly backup (below) |

## Deploy, update, roll back

- **Update:** push to the branch → CI builds and pushes `:edge` → Coolify **Redeploy** (or its webhook / auto-update).
- **Roll back:** in Coolify set the image tag to a `claude-game-implementation-phases-asl5jz-<sha7>` tag and redeploy. Database migrations only add things, so an older build runs on a newer database unless a release note says otherwise; when in doubt restore the backup taken before the update (below).
- **After every deploy:** `https://westbound.sipsakrandevu.com/api/v1/health` shows `"status":"ok"` and the new `build`; the logs show `listening` with the version and build.
- **Before a risky update:** take a manual backup: `docker exec <container> westbound-server backup /data/backups/pre-deploy-$(date +%F).db` (the host's shell fills in the date).

## Restarts: what players see

A redeploy, a Coolify **Restart** or **Stop**, and `docker stop` all send SIGTERM. The server then:

1. tells every connected player **SERVER RESTART · 60 S** (a countdown in the room HUD, reminders at 30 and 10 s), stops taking new rooms and joins, and answers health checks with 503 `draining`;
2. at 0: ends every run in progress with its **banked score kept** (verified runs go on the boards), writes each room's code and settings to `/data/room-handover.json`;
3. closes every connection with code 1012 ("restarting") and exits.

The game reconnects on its own for up to 90 s and rejoins **the same room by its code** on the new server, with a fresh run; lobby players reconnect quietly. Parties do not survive (players rejoin the room without the party); the first player back becomes a private room's host. With nobody connected the server exits at once (no 60 s wait). A second SIGTERM cuts the notice short.

### Coolify stop timeout (check once)

The container must get longer than the notice to stop: notice (60 s) + about 10 s.

- **Docker Compose resource** (from `westbound-server/docker-compose.yml`): `stop_grace_period: 75s` is set.
- **Docker Image resource** (the current setup): Coolify stops the old container with its own `docker stop` timeout, which may be shorter than 75 s and is not the image's. Check it once:
  1. Open the game in a browser and join a room (so a session is connected).
  2. Redeploy. Watch the old container's logs: you should see `restart: draining`, `restart notice sent`, the reminders, then `rooms handed over` and `database closed`.
  3. If the logs stop before `rooms handed over`, or `docker inspect <old container>` shows exit code 137 (killed), the timeout is shorter than the notice: set `WB_SERVER__RESTART_NOTICE_SECS=20` (or whatever fits under the timeout minus 10 s) and redeploy, or move to the Compose resource.
- Coolify may start the new container **before** stopping the old one (a rolling update). That is fine: the old one drains and hands over, and the new one recreates rooms from the handover file when players rejoin. Both use the same volume.

### Announcing maintenance

```sh
westbound-server admin notice "Maintenance tonight at 20:00 UTC, about 5 minutes" --kind maintenance --seconds 3600
```

Every connected player sees the text in the room banner.

## Moderation (admin CLI)

On the host with `docker exec <container>` in front (see "At a glance"). PLAYER is an account id (`42`) or the full name (`Road Runner#0042`, any case). Every change lands in the admin log.

```sh
westbound-server admin reports --unhandled                  # the queue, newest first
westbound-server admin player "Road Runner#0042"            # everything about one player
westbound-server admin ban "Road Runner#0042" 7d --reason "wallriding exploit"   # 30m 12h 7d 2w perm
westbound-server admin report-resolve 12                    # (= report-handle)
westbound-server admin unban 42
westbound-server admin rename 42 "Driver"                   # force-rename (filter applies, no cooldown)
westbound-server admin delete-player 42 --yes               # account + all data, cannot be undone
westbound-server admin kick 42                              # end the live session now
westbound-server admin rooms                                # live rooms: id code visibility players density accounts
westbound-server admin room-close ABC234 -m "Closed by a moderator"
westbound-server admin remove-run 1234                      # a cheated run; the entry falls back
westbound-server admin remove-entry loop 2026-10 42         # one board entry
westbound-server admin recompute loop 2026-10               # rebuild a board period from the runs
westbound-server admin crew-rename 5 "Day Riders" --tag DR
westbound-server admin crew-disband 5
westbound-server admin stats                                # database + live numbers
westbound-server admin log --limit 20                       # who did what
westbound-server admin replays                              # the replay verification queue
```

- A ban ends the player's session at once with the admin token set, else within 30 s; the reason stays in the admin log and shows in `admin player`.
- Board changes show at once with the admin token set, else within the board cache TTL (a minute).
- `rooms`, `room-close`, `notice` and `kick` need the running server and the admin token.

## Backups

- **Nightly** at 03:17 UTC: `/data/backups/westbound-YYYY-MM-DD.db`, integrity-checked, 7 kept.
- **List:** `westbound-server admin backups`. **Check one:** `westbound-server verify-backup /data/backups/westbound-2026-09-28.db`. **Manual:** `westbound-server backup /data/backups/manual-2026-10-01.db`.
- **Watch:** the logs say `nightly backup written` every night; `admin stats` shows `last_backup`; the metric `wb_backups_failed_total` stays at 0.
- **Keep the secrets with the backups:** a restored database needs the same `WB_AUTH__DEVICE_SECRET_PEPPER` (and the same JWT secret, or players simply refresh their tokens).

### Off-site copies

Pick one:

1. **Coolify volume backups** (Persistent Storage → the volume → Backups, to S3-compatible storage). Simplest; copies the whole volume including `backups/`.
2. **Host cron:** on the VPS, copy the volume's `backups/` directory elsewhere nightly (after 03:30 UTC), for example `rsync -a /var/lib/docker/volumes/<volume>/_data/backups/ user@elsewhere:westbound-backups/`.
3. **The server's hook** (`WB_BACKUP__UPLOAD_COMMAND`): runs after each good nightly backup, `{file}` is the new backup, no shell. The image has no tools, so put a static binary on the volume. With rclone:
   - on the host: download the Linux rclone release, then `cp rclone <volume>/_data/bin/rclone` and write its config to `<volume>/_data/bin/rclone.conf` (`rclone config` on your machine; it holds the storage credentials, so keep it off the repository), `chown -R 65532:65532 <volume>/_data/bin`;
   - in Coolify: `WB_BACKUP__UPLOAD_COMMAND=/data/bin/rclone,--config,/data/bin/rclone.conf,copyto,{file},offsite:westbound-backups/latest.db` (or `copy,{file},offsite:westbound-backups` to keep every day);
   - the logs say `backup copied off-site`; failures are `off-site backup hook failed` and `wb_backup_uploads_failed_total`.

### Restore

1. Coolify → the resource → **Stop** (players get the restart notice first).
2. On the host, find the volume (`docker volume ls`, the one ending in `westbound-data`), then run the image's `restore` against it:

   ```sh
   docker run --rm -v <volume>:/data ghcr.io/b3vet/westbound-server:edge verify-backup /data/backups/westbound-2026-09-28.db
   docker run --rm -v <volume>:/data \
     -e WB_AUTH__JWT_SECRET=x... -e WB_AUTH__DEVICE_SECRET_PEPPER=y... \
     ghcr.io/b3vet/westbound-server:edge restore /data/backups/westbound-2026-09-28.db
   ```

   (`restore` needs the config to load, so pass the two secrets, or `-e WB_SERVER__ENV=dev` for the restore run only.) It verifies the backup, moves the current database aside as `westbound.db.before-restore-<unix time>` (nothing is deleted), copies the backup in, applies newer migrations and records the restore in the admin log. It refuses while a server answers on the port.
3. **Start** the resource; check `/api/v1/health` and `westbound-server admin stats`.
4. **Undo a restore:** stop, then `docker run --rm -v <volume>:/data busybox sh -c 'mv /data/westbound.db /data/westbound.db.bad; mv /data/westbound.db.before-restore-<time> /data/westbound.db'`, start.

A restore loses everything written after the backup (accounts created since, runs, friends). Players whose accounts were created after it get "please sign in again" and a new account.

## Logs

- One JSON object per line: `timestamp`, `level`, `target`, `message` and the event's fields; HTTP lines carry `span.req_id`, `span.method`, `span.path`; WebSocket lines `client` (a hashed IP), `account`, `session`. Tokens, secrets and IPs never appear.
- Every HTTP response has `X-Request-Id`: when a player reports an error, the id finds the request's lines.
- On the host: `docker logs --since 1h <container> 2>&1 | jq -c 'select(.level=="ERROR" or .level=="WARN")'`, or `... | grep '"req_id":"<id>"'`.
- Worth knowing: `session kicked`, `handshake refused`, `run ended` (with `verified`), `implausible player state; run unverified`, `nightly backup written` / `failed`, `restart: draining` … `rooms handed over`, `admin API request`.

## Metrics and alerts (optional)

`/metrics` listens only inside the container. To look at it once: on the host, `docker run --rm --network container:<container> curlimages/curl -s localhost:9090/metrics | grep -v '^#'`.

What to watch (SERVER.md → "Operations (N10.2) → Metrics added" has the full list):

| Question | Metric |
| --- | --- |
| Up and healthy? | `/api/v1/health` from outside (below) |
| Players now | `wb_ws_sessions`, `wb_rooms`, `wb_room_seats` |
| Room performance (spec: p99 under 5 ms) | `wb_room_tick_seconds` histogram |
| Bandwidth | `rate(wb_ws_bytes_out_total[5m])` |
| Errors | `wb_log_events_total{level="error"}`, `wb_http_requests_total{class="5xx"}` |
| Database | `wb_db_probe_seconds`, `wb_db_file_bytes`, `wb_db_wal_bytes` |
| Queues | `wb_replay_jobs{status="pending"}`, `wb_reports_unhandled` |
| Backups | `wb_backups_failed_total`, `wb_backup_last_success_timestamp_seconds` |
| Cheating signals | `wb_room_offences_total{kind}`, `wb_room_claims_total{verdict="rejected"}` |
| Memory (spec: under 300 MB) | `process_resident_memory_bytes` |

**Minimal setup:**

1. **Uptime:** an HTTP monitor on `https://westbound.sipsakrandevu.com/api/v1/health` every minute, alert after 3 failures. Uptime Kuma (a one-click Coolify service) or any uptime service. Expect short 503 `draining` blips during redeploys.
2. **Metrics (optional):** deploy the server as a Docker Compose resource and add a Grafana Alloy (or Prometheus agent) service with `network_mode: "service:westbound-server"`, scraping `127.0.0.1:9090` every 30 s and `remote_write`-ing to a free Grafana Cloud stack. Minimal Alloy config:

   ```river
   prometheus.scrape "westbound" {
     targets         = [{"__address__" = "127.0.0.1:9090"}]
     scrape_interval = "30s"
     forward_to      = [prometheus.remote_write.cloud.receiver]
   }
   prometheus.remote_write "cloud" {
     endpoint {
       url = env("PROM_URL")
       basic_auth { username = env("PROM_USER")  password = env("PROM_TOKEN") }
     }
   }
   ```
3. **Alerts:** `westbound-server/deploy/alerts.example.yml` has Prometheus rules for the table above (server down, errors, 5xx, room tick p99, database latency, failed backups, memory, near the connection cap, replay backlog). Grafana Cloud imports them.

## Rate limits (what players can hit)

Everything is per client IP or per account and configurable (SERVER.md → "Rate limits: every route and message type"). Players behind one mobile carrier NAT share an IP: the per-IP limits are generous (600 requests and 60 connections a minute). If many players report "too many requests", check `wb_http_rate_limited_total` and `wb_ws_rate_limited_total{type}`, and raise the matching `WB_RATE_LIMITS__...` value.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| Players dropped at every deploy and land in the hub | The stop timeout is shorter than the notice (see "Coolify stop timeout"); the logs lack `rooms handed over` |
| "admin API is off" | `WB_ADMIN__TOKEN` not set (32+ characters) on the resource; redeploy after setting it |
| Health shows `draining` | A restart is in progress; it ends with the container exiting |
| `nightly backup failed` | The log line's error; disk space on the volume; `verify-backup` the last good file |
| Everyone gets `map_mismatch` | A client build with another map; see SERVER.md → "Map hashes" |
| A player can't sign in after a restore | Their account was created after the backup: they get a new one |
