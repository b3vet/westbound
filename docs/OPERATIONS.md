# Westbound Online: operations runbook

For the owner running `westbound-server` on Coolify. The technical reference is [`SERVER.md`](SERVER.md) (config keys, routes, the admin API, rate limits, metrics); this page is what to do. Spec: [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → "Resource budget and deployment", "Moderation". WP N10.2.

## At a glance

| What | Where |
| --- | --- |
| Image | `ghcr.io/b3vet/westbound-server:edge` (CI pushes it from the `claude/game-implementation-phases-asl5jz` branch); rollback tags `claude-game-implementation-phases-asl5jz-<sha7>` |
| Replay verifier (N8.3) | `ghcr.io/b3vet/westbound-verifier:edge`, a second resource on the same volume: see "Replay verification" |
| Public | `https://westbound.sipsakrandevu.com` → container port 8080 (`/api/*`, `/ws`, `/r/*`, `/.well-known/*`) |
| Volume | `/data`: `westbound.db` (+ `-wal`, `-shm`), `backups/`, `well-known/`, `replays/`, `room-handover.json`. Small disk: everything the server writes there is capped (see "Disk space") |
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
| `WB_REPLAYS__WORKER_ENABLED` | `false` | N8.3: the verifier resource runs the replay queue, never the server (see "Replay verification") |
| `WB_IDENTITY__GOOGLE_CLIENT_IDS`, `WB_IDENTITY__APPLE_*` | see "Sign in with Apple / Google" | N11: turn the providers on (off until set; cloud save needs one of them) |

## Deploy, update, roll back

- **Update:** push to the branch → CI builds and pushes `:edge` → Coolify **Redeploy** (or its webhook / auto-update).
- **Roll back:** in Coolify set the image tag to a `claude-game-implementation-phases-asl5jz-<sha7>` tag and redeploy. Database migrations only add things, so an older build runs on a newer database unless a release note says otherwise; when in doubt restore the backup taken before the update (below).
- **After every deploy:** `https://westbound.sipsakrandevu.com/api/v1/health` shows `"status":"ok"` and the new `build`; the logs show `listening` with the version and build.
- **Before a risky update:** take a manual backup: `docker exec <container> westbound-server backup /data/backups/pre-deploy-$(date +%F).db` (the host's shell fills in the date).

### Automatic deploys (Coolify webhooks)

Both workflows can redeploy their Coolify resource right after pushing a new image. They skip this step when the secrets below are missing.

1. **Coolify: create an API token.** Go to Keys & Tokens → API tokens → create one with the **deploy** permission. Copy it; it is shown once.
2. **Coolify: copy each resource's deploy webhook.** For the server resource and the verifier resource, open the resource → Webhooks. Copy the Deploy Webhook URL, which looks like `https://<coolify>/api/v1/deploy?uuid=<uuid>&force=false`. Change `force=false` to `force=true`, so Coolify pulls the image again even though the tag (`:edge`) didn't change.
3. **GitHub: add the secrets.** In the repository, go to Settings → Secrets and variables → Actions → New repository secret:
   - `COOLIFY_TOKEN`: the API token;
   - `COOLIFY_SERVER_WEBHOOK`: the server resource's URL;
   - `COOLIFY_VERIFIER_WEBHOOK`: the verifier resource's URL.
4. **Check it works.** After the next push that touches `westbound-server/`, the **Server** workflow's last step, "Redeploy the server on Coolify", prints Coolify's answer. Coolify's Deployments tab shows a new deployment, and `/api/v1/health` reports the new `build`. The **Verifier** workflow's last step does the same for the verifier; it runs after pushes that touch the game or the server.

The Coolify URL must be reachable from GitHub's runners (the public internet). A planned restart (60 s notice, room handover) happens on every automatic server deploy, exactly as with a manual one.

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
westbound-server admin replay-purge-set-aside --older-than 7d   # drop parked replays' files
westbound-server admin backups                              # the backups, the newest one's age, free space
westbound-server admin housekeeping                         # run the daily cleanup now
```

- A ban ends the player's session at once with the admin token set, else within 30 s; the reason stays in the admin log and shows in `admin player`.
- Board changes show at once with the admin token set, else within the board cache TTL (a minute).
- `rooms`, `room-close`, `notice` and `kick` need the running server and the admin token.

## Replay verification

WP N8.3. A single-player run that makes a top 100 or a personal best uploads its replay and shows as **verifying** on the boards. The verifier re-simulates the run from the replay (the game's own simulation, headless) and settles it: **accepted** → verified; **rejected** → off the boards. Until the verifier runs, such runs simply stay "verifying" (the state before N8.3). Technical reference: SERVER.md → "Replays and verification"; how the image is built: DETERMINISM.md → Verifier deploy.

| What | |
| --- | --- |
| Image | `ghcr.io/b3vet/westbound-verifier:edge`; rollback tags `claude-game-implementation-phases-asl5jz-<sha7>`. The **Verifier** workflow builds it on every push to the branch that changes the game or the server, tests it end to end (an honest replay verified, tampered ones rejected) and pushes it |
| What is in it | `westbound-server verify-worker` + one headless game build per recent client build (the current one and up to two older; `/verifier/BUILDS.txt` lists them with their commit) + `verify-backlog` (a dry run) |
| How it runs | Next to the server on the **same `/data` volume** (same host): one replay at a time, each under `nice 10`, the container capped at 1 CPU and 1 GB. It picks up new uploads within 10 s |
| A build it does not have | The replay is set aside: its run stays "verifying", `admin replays` shows `set_aside N` and `set aside run N (build 7, uploaded ...): no verifier for build 7 here ...` (N10.3; before, these showed as `failed`). Every verifier start retries those, so a newer image that has the build picks them up. The same for replays it cannot verify (recorded before N8.2, no input stream; another simulation under the same build number). After 30 days their files are deleted (the runs stay "verifying"); `admin replay-purge-set-aside --older-than 7d` does it sooner |

### Before you switch it on (once)

1. **Backup:** `westbound-server backup /data/backups/pre-verifier-$(date +%F).db` (with the `docker exec <server container>` prefix).
2. **The backlog:** `westbound-server admin replays` shows how many replays wait (`pending`). They are verified oldest first once the verifier runs.
3. **Dry run** (nothing is written): on the VPS host, with the server's volume name (Coolify → the server resource → Persistent Storage, or `docker volume ls`):

   ```sh
   docker run --rm -v <volume>:/data:ro --entrypoint verify-backlog ghcr.io/b3vet/westbound-verifier:edge
   ```

   One line per stored replay (`accepted` / `rejected` with the reason / `cannot verify` / `no verifier for this build`) and a total. `rejected` here means rejected for real when you switch on. If honest-looking runs come out `rejected` (replays recorded by an older web build whose simulation differs under the same build number), do not switch on yet: ask for a `client_build` bump, then run the Verifier workflow by hand (GitHub → Actions → Verifier → Run workflow) with **keep builds = 1**. That image holds only the new build, so the old replays are set aside (their runs stay "verifying") instead of judged; the dry run then shows them as `no verifier for this build`. A rejection cannot be undone from the admin CLI.

### Set it up in Coolify (recommended: a second Docker Image resource)

The server keeps its current resource and volume; the verifier is a second resource that mounts the same volume.

0. **The image must be pullable:** after the Verifier workflow's first green run on the branch, GitHub → your profile → Packages → `westbound-verifier` → Package settings → Change visibility → **Public** (as `westbound-server` is), or give Coolify a GHCR login (a token with `read:packages`) for it.
1. **Server resource** → Environment Variables: add `WB_REPLAYS__WORKER_ENABLED` = `false`. (Today the server has no verifier command, so its own worker never starts; this keeps it that way should anyone add one. Exactly one worker may run per database.) It takes effect at the next redeploy; no need to redeploy for it now.
2. **The volume's name:** server resource → Persistent Storage: note the volume's **Name** (mounted at `/data`). On the host `docker inspect <server container> --format '{{range .Mounts}}{{.Name}} {{.Destination}}{{println}}{{end}}'` shows the same.
3. **New resource:** the same project and **the same server (host)** → + New → **Docker Image** → `ghcr.io/b3vet/westbound-verifier:edge`. Name it `westbound-verifier`.
   - **General:** no domain. Coolify asks for "Ports Exposes": leave its default (nothing listens; the verifier makes no connections at all). Health check: off (the image has none).
   - **Environment Variables:** `WB_AUTH__JWT_SECRET` and `WB_AUTH__DEVICE_SECRET_PEPPER` with the **same values as the server** (the configuration loader requires them; the worker never uses them). Nothing else is needed: the image sets the database path, the verifier command, `nice 10`, the poll interval and JSON logs.
   - **Persistent Storage** → + Add → **Volume Mount**: Name = the server's volume name from step 2, exactly; Destination Path = `/data`.
   - **Resource Limits:** Number of CPUs `1`; Maximum Memory Limit `1g`; Maximum Swap Limit `1g`. (Or, in Advanced → Custom Docker Options: `--cpus=1 --memory=1g --memory-swap=1g`.)
   - **Deploy.**
4. **Check the volume is shared:** `docker inspect <verifier container> --format '{{range .Mounts}}{{.Name}} {{.Destination}}{{println}}{{end}}'` shows the same name as step 2. If it shows another name (your Coolify version prefixed it), see "If the volume cannot be shared" below.

### Check it works

- **Verifier logs** (Coolify → westbound-verifier → Logs): `replay verification worker started` with the command, then one `replay verified` line per replay with `verdict`, `reason`, the recomputed and claimed score and the seconds it took (5–60 s each). `replay cannot be verified by this verifier; set aside` names a build the image lacks.
- **Queue:** `westbound-server admin replays` (on the server container): `pending` goes down, `done` up; set-aside replays are counted as `set_aside` and listed with their build and reason.
- **Metrics** (the server's `/metrics`, it counts the shared database): `wb_replay_jobs{status="pending"}` drains to 0 and stays low; the `WestboundReplayBacklog` alert covers a stuck verifier.
- **A test run:** play a Journey run on the web build with a new account (a first run is always a personal best, so it uploads a replay). Its board entry shows "verifying", and within about a minute it is verified: the verifier's log shows `replay verified run_id=<id> verdict="accepted"`.
- **Which builds it verifies:** `docker exec <verifier container> cat /verifier/BUILDS.txt` (build, commit, export date); the Verifier workflow's run summary shows the same. The build players run is the web build's `client_build` (`data/tuning/net.tres`).

### Updating

- The Verifier workflow pushes a new `:edge` after each game change; then **Redeploy** the verifier resource. To make that automatic: Coolify → westbound-verifier → Webhooks: copy the **Deploy Webhook** URL, create an API token (Keys & Tokens → API tokens, with deploy permission), and add both as repository secrets `COOLIFY_VERIFIER_WEBHOOK` and `COOLIFY_TOKEN` (GitHub → Settings → Secrets and variables → Actions); the workflow calls the webhook after pushing.
- A redeploy in the middle of a replay is harmless: that replay is retried (the interrupted attempt counts, three in all), and set-aside replays are retried with the new image.
- **Build parity:** the verifier must run the same simulation as the players' build. The image keeps the three newest client builds; the web build and the verifier are built from the same commits. When the simulation changes, the game's `client_build` must be bumped; the workflow warns (`Verifier build parity`) when a build number's simulation changed without one.

### Rollback

- **Switch it off:** Coolify → westbound-verifier → **Stop**. Nothing else changes: uploads continue, runs stay "verifying", and the backlog is verified whenever it runs again. Leave the server's `WB_REPLAYS__WORKER_ENABLED=false`.
- **An older image:** set the verifier resource's image tag to a `claude-game-implementation-phases-asl5jz-<sha7>` tag and redeploy.
- **Verdicts stay.** An accepted run stays verified and a rejected one stays off the boards; `westbound-server admin replay-requeue <run_id>` re-verifies a run whose replay file is still there (verified top-100 runs keep theirs; rejected runs' files are deleted).

### If the volume cannot be shared

Symptoms: the verifier logs `requeueing running replay jobs failed (is the server's database on this volume?)` or `replay queue error ... no such table: replays` (it opened an empty database), or the two containers mount volumes with different names. Two ways out:

1. **Directory mounts** on both resources (a host directory instead of a named volume): stop the server; on the host `mkdir -p /srv/westbound-data && cp -a /var/lib/docker/volumes/<volume>/_data/. /srv/westbound-data/ && chown -R 65532:65532 /srv/westbound-data`; server resource → Persistent Storage: replace the volume with a **Directory Mount** `/srv/westbound-data` → `/data`; start it and check `/api/v1/health` and `admin stats`; then give the verifier the same Directory Mount. The old volume stays as a copy until you delete it.
2. **One Docker Compose resource** with both services: `westbound-server/verifier/docker-compose.coolify.yml` (server + verifier, the limits, the server's worker off). It gets a new volume: take a backup, deploy the new resource, stop its server, restore the backup into it ("Restore" below, with the new volume), start it, move the domain over and retire the old resource.

The same container (the verifier inside the server image) is not offered: the server image is static and distroless (no glibc for the game build), and the 1 GB cap would then cover the server too (SERVER.md → Running the verifier).

## Backups

- **Nightly** at 03:17 UTC: `/data/backups/westbound-YYYY-MM-DD.db`, integrity-checked before it replaces anything. **At most 3 are kept** (N10.3, `backup.retention_days`, a count): after each good backup the oldest beyond 3 is deleted; the newest is never deleted, and a failed or skipped backup deletes nothing. Keep longer history off the machine (below).
- **List:** `westbound-server admin backups`: the files with sizes and ages, `newest: westbound-2026-09-30.db 5 h old: ok` (or `STALE` past 26 h), the volume's free space. **Check one:** `westbound-server verify-backup /data/backups/westbound-2026-09-28.db`. **Manual:** `westbound-server backup /data/backups/manual-2026-10-01.db`. Manual and pre-deploy copies are deleted after 7 days (`backup.other_retention_days`), as is the `westbound.db.before-restore-<time>` a restore leaves.
- **Watch:** the logs say `nightly backup written` every night; `wb_backups_failed_total` stays at 0 and `wb_backup_stale` at 0. A missed night shows within a few hours: `the newest backup is stale` (WARN, every 6 h while it lasts). With too little disk the backup is skipped instead of filling it: `nightly backup skipped: not enough disk space` (ERROR, `wb_backups_skipped_total`); see "Disk space".
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

## Disk space

The server's disk is small, so everything the server writes on the volume is capped (N10.3; technical detail: SERVER.md → "Housekeeping (N10.3)"). Nothing needs setting: these are the defaults.

**What is kept:**

| On the volume | Kept |
| --- | --- |
| Daily backups (`backups/westbound-YYYY-MM-DD.db`) | **3** (the newest three; each about the size of the database) |
| Manual / pre-deploy backups in `backups/`, `westbound.db.before-restore-*` | 7 days |
| Replays (`replays/`) | Verified: only while in a current top 100 (today, this week, this season, all-time). Set aside (no verifier for their build): 30 days. Waiting (`pending`): until the verifier verifies them, so keep the verifier running |
| Database rows | Shadow contacts 30 days; runs that hold no leaderboard entry 90 days; past Daily Drive days and Journey weeks 90 days; handled reports and the admin log 365 days; seasons, all-time boards, accounts, friends and crews are kept |
| The write-ahead log (`westbound.db-wal`) | Emptied every 5 minutes |
| `room-handover.json` | A few KB; deleted once expired |

**Expected steady state** (rough, for about 100 players a day; it scales with play):

| Item | Size |
| --- | --- |
| Database (`westbound.db`) | 50–150 MB: runs about 1 KB each for 90 days, shadow contacts about 20 KB per player-hour in rooms for 30 days, plus accounts and boards |
| Write-ahead log | under 10 MB |
| Backups | 3 × the database: 150–450 MB (a copy is compacted) |
| Replays | 10–50 MB (a 10-minute run is about 50 KB; a 6-hour one up to 2 MB) |
| Everything else on `/data` | under 1 MB (plus your `bin/rclone` if you use the off-site hook) |
| **Total** | **about 0.25–0.7 GB**, plus room for one more database copy while the nightly backup runs |

Once the retentions are reached the database file stops growing (deleted rows' space is reused); the daily pass runs a `VACUUM` to give space back when a quarter of the file is free.

**What to watch:**

- `westbound-server admin stats`: the `disk_*` lines (`disk_free_bytes`, `disk_low`, `disk_db_bytes`, `disk_backups_bytes`, `disk_replays_bytes`, `disk_other_bytes`) and `backup_newest` / `backup_stale`. `admin backups` shows the same for the backups.
- **The floor: 500 MB free** (`WB_HOUSEKEEPING__MIN_FREE_MB`). Below it the log says `disk space low on the data volume` (WARN, every 6 h), `wb_disk_low` is 1, the nightly backup is **skipped** (ERROR; older backups stay), and replay uploads wait (players' games retry later). The game itself keeps working. To make room: delete old manual files in `/data/backups`, run `westbound-server admin housekeeping`, purge parked replays (`admin replay-purge-set-aside --older-than 7d`), check `admin replays` for a large `pending` (is the verifier running?), or grow the disk.
- **The host, not just the volume:** container logs (stdout) are kept by Docker on the host and grow unless rotated. Check the VPS's `/etc/docker/daemon.json` has `"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}` (Coolify usually sets this on install; after changing it, `systemctl restart docker`, and it applies to newly created containers). Old images pile up too: Coolify → Settings → "Docker cleanup", or `docker image prune -a` on the host.
- **Alerts** (if you scrape metrics): `wb_disk_low == 1`, `wb_backup_stale == 1`, `increase(wb_backups_failed_total[1d]) > 0`.

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
| Backups | `wb_backups_failed_total`, `wb_backup_stale`, `wb_backup_newest_age_seconds`, `wb_backup_files` |
| Disk (small volume) | `wb_disk_low`, `wb_disk_free_bytes`, `wb_disk_backups_bytes`, `wb_disk_replays_bytes`, `wb_db_file_bytes` |
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

## Sign in with Apple / Google

N11. Players can sign in with Apple or Google on the account screen (pause → SETTINGS → ACCOUNT, or the title's profile chip); that is what lets their progress move between devices (cloud save). Everything is built and tested; **adding the credentials below is the only step left**. Until a provider's client ids are set, its button says NOT SET UP and the server answers `501 provider_not_enabled`, exactly as before. Reference: SERVER.md → "Sign in with Apple / Google", "Cloud save"; the client: NET_CLIENT.md → "Sign in with Apple / Google"; the merge rules: SAVE.md → "Cloud sync".

**What it costs.** Google sign-in is free (no Google Play developer account needed for the web). Apple needs the paid Apple Developer Program membership (99 USD a year; you will have it for TestFlight anyway). Cloud save storage on the VPS: one JSON document per player, a few KB (capped at 64 KB, old versions not kept), in the same database, so it is in the nightly backups automatically.

**Which builds get what.** The web build (`https://b3vet.github.io/westbound/`) gets both providers as soon as they are configured: the page loads Google's or Apple's script only then. iOS and Android need small native plugins that are not written yet (NET_CLIENT.md → "Native plugins"); until then those builds show NOT IN THIS BUILD.

### Google (web, free)

1. Open <https://console.cloud.google.com/>, sign in, and create a project (top bar → project picker → **New project**, e.g. `Westbound`).
2. **APIs & Services → OAuth consent screen** (newer consoles call it **Google Auth Platform → Branding / Audience**):
    - User type **External**; app name `Westbound`; your support email; developer contact email.
    - **Authorized domains:** `b3vet.github.io` (the web build) and `sipsakrandevu.com` (the server).
    - **Scopes:** none to add (Sign in with Google only uses `openid` and `email`, which need no review). Leave the logo empty: a logo triggers Google's brand verification.
    - **Audience / Publishing status:** press **Publish app** (In production). In "Testing" only listed test users can sign in.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID:**
    - Application type **Web application**, name `Westbound web`.
    - **Authorized JavaScript origins:** `https://b3vet.github.io`. For local testing also `http://localhost` and `http://localhost:8000` (Google allows plain http only for localhost).
    - **Authorized redirect URIs:** none (the button uses a popup).
    - Create, then copy the **Client ID** (`1234567890-abc….apps.googleusercontent.com`; the client *secret* is not used).
4. In Coolify → the server resource → **Environment Variables**: `WB_IDENTITY__GOOGLE_CLIENT_IDS` = that client id. Redeploy.
5. Check: `curl https://westbound.sipsakrandevu.com/api/v1/auth/providers` shows `"google":{"enabled":true,"client_id":"…"}`; on the web build, ACCOUNT → SIGN IN WITH GOOGLE opens a sheet with Google's button.
6. **Later (native):** an **iOS** OAuth client (bundle id `com.sipsakrandevu.westbound`) and an **Android** one (package + the signing certificate's SHA-1). Add the iOS client id to the list, comma-separated: `WB_IDENTITY__GOOGLE_CLIENT_IDS=<web id>,<ios id>`. Android's Credential Manager asks for tokens issued to the *web* client id, so the web id covers it.

### Apple (paid membership)

All in <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles**:

1. **Identifiers → App IDs → +** (if the app's App ID does not exist yet): type App, bundle id `com.sipsakrandevu.westbound` (the iOS app's; must match `deeplinks.apple_app_ids`). Under **Capabilities** tick **Sign in with Apple** (Enable as a primary App ID). Save.
2. **Identifiers → Services IDs → +**: description `Westbound web`, identifier `com.sipsakrandevu.westbound.web`. Save, open it, tick **Sign in with Apple → Configure**:
    - **Primary App ID:** the App ID above.
    - **Domains and Subdomains:** `b3vet.github.io`.
    - **Return URLs:** `https://b3vet.github.io/westbound/` (exactly the web build's URL, https). The web uses a popup, but Apple requires one.
    - If the portal asks to **verify the domain** (older accounts): it wants `https://b3vet.github.io/.well-known/apple-developer-domain-association.txt`, which a GitHub Pages *project* site cannot serve (that path belongs to a `b3vet.github.io` user-site repo). Either create that repo with the file, or move the web build to a domain you control. Current Apple accounts no longer ask for this for Sign in with Apple.
3. **Keys → +**: name `Westbound Sign in with Apple`, tick **Sign in with Apple → Configure** → primary App ID = the one above. Register, then **Download** the `.p8` file (only possible once; keep it with your other secrets). Note the **Key ID** (10 characters) shown with it.
4. Your **Team ID**: **Membership details** (10 characters, also in the top-right corner of the portal).
5. Coolify → Environment Variables (mark the key **secret**):

| Variable | Value |
| --- | --- |
| `WB_IDENTITY__APPLE_CLIENT_IDS` | `com.sipsakrandevu.westbound.web,com.sipsakrandevu.westbound` (the Services ID for the web, the bundle id for iOS) |
| `WB_IDENTITY__APPLE_WEB_REDIRECT_URI` | `https://b3vet.github.io/westbound/` |
| `WB_IDENTITY__APPLE_TEAM_ID` | the Team ID |
| `WB_IDENTITY__APPLE_KEY_ID` | the Key ID |
| `WB_IDENTITY__APPLE_PRIVATE_KEY` | the whole `.p8` file (`-----BEGIN PRIVATE KEY-----` … `-----END PRIVATE KEY-----`); if Coolify keeps only one line, write the line breaks as `\n`. Or put the file on the volume (e.g. `/data/secrets/AuthKey_<KEYID>.p8`, readable by uid 65532) and set `WB_IDENTITY__APPLE_PRIVATE_KEY_FILE` to its path instead |

6. Redeploy. The server refuses to start with a bad key or ids (the log names the setting), so a typo cannot go live silently.
7. Check: `/api/v1/auth/providers` shows `"apple":{"enabled":true,…}`; on the web build SIGN IN WITH APPLE opens Apple's popup.

**Why the key.** Apple requires apps that offer account deletion to **revoke** the user's Sign in with Apple grant when the account is deleted. With the key, the server exchanges each Apple sign-in's authorization code for a refresh token (stored sealed, never in the clear) and revokes it on DELETE ACCOUNT and on unlink. Without the key, Apple sign-in still works but nothing can be revoked (logged as `Apple grant not revoked: no Apple key configured`); set the key before the App Store review.

### How to test it

- **Before going live:** the server's tests sign tokens with test keys against a fake provider on loopback (`cargo test -p server --test identity`); the client's run against a fake server (`tools/test.sh --filter=identity`, `--filter=cloud_save`).
- **Live, web:** open the web build in a private window → ACCOUNT → SIGN IN WITH GOOGLE: the account stays the same, the button turns into SIGNED IN WITH GOOGLE with your masked address, and the cloud line says SYNCED. In another browser (or after clearing site data), SIGN IN WITH GOOGLE again: the chooser shows both accounts; pick one and the progress follows.
- `admin player <id>` shows the account; the database has `identity_links` (masked email hints only) and `cloud_saves` rows.

### Turning a provider off

Remove its `WB_IDENTITY__…_CLIENT_IDS` and redeploy: its button says NOT SET UP, signed-in players keep their sessions (device credentials), and nobody can sign in with it until it is back.

## Rate limits (what players can hit)

Everything is per client IP or per account and configurable (SERVER.md → "Rate limits: every route and message type"). Players behind one mobile carrier NAT share an IP: the per-IP limits are generous (600 requests and 60 connections a minute). If many players report "too many requests", check `wb_http_rate_limited_total` and `wb_ws_rate_limited_total{type}`, and raise the matching `WB_RATE_LIMITS__...` value.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| Players dropped at every deploy and land in the hub | The stop timeout is shorter than the notice (see "Coolify stop timeout"); the logs lack `rooms handed over` |
| "admin API is off" | `WB_ADMIN__TOKEN` not set (32+ characters) on the resource; redeploy after setting it |
| Health shows `draining` | A restart is in progress; it ends with the container exiting |
| `nightly backup failed` | The log line's error; disk space on the volume; `verify-backup` the last good file |
| `nightly backup skipped: not enough disk space` / `disk space low on the data volume` | "Disk space": make room, then the next night's backup runs (or take one by hand: `westbound-server backup ...`) |
| `the newest backup is stale` | No good backup for 26 h: look for `nightly backup failed` / `skipped` lines; `admin backups` |
| Everyone gets `map_mismatch` | A client build with another map; see SERVER.md → "Map hashes" |
| A player can't sign in after a restore | Their account was created after the backup: they get a new one |
| Runs stay "verifying" | Is the verifier resource running (its logs: `replay verified` lines)? `admin replays`: a growing `pending` = no verifier or a stuck one; `set_aside` = a build the image lacks (a newer image, redeployed, takes them; after 30 days their files are deleted and the runs stay "verifying") |
| The verifier logs `no such table: replays` | It does not see the server's database: "Replay verification → If the volume cannot be shared" |
| `Verifier build parity` warning in the Verifier workflow | The simulation changed without a `client_build` bump: replays from players still on the previous web build fail verification. Bump `client_build` (`data/tuning/net.tres`) |
