# Load test and netcode acceptance (N4.4, N10.1)

Spec: [multiplayer handoff](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → Testing → Netcode harness (the acceptance numbers at 150 ms RTT, ±30 ms jitter, 2 % loss), Load test ("20 rooms of 8 bots on a 1-vCPU limit: at or below 50% CPU, tick p99 under 5 ms, under 300 MB of memory, 10 KB/s or less per player"), Resource budget; Players → shadow collision logging. Plan: [MULTIPLAYER_PLAN.md](MULTIPLAYER_PLAN.md) N4.4, N10. Server runbook: [SERVER.md](SERVER.md) → "Load test, shadow collisions and admin stats (N4.4, N10.1)". The client's side of the same numbers: [NET_TRAFFIC.md](NET_TRAFFIC.md).

| Path | What |
| --- | --- |
| `westbound-server/crates/bots/src/link.rs` | The in-process delay layer: per-direction delay, jitter and loss; TCP (late, in order) or datagram (gone, reordered); statistics |
| `westbound-server/crates/bots/src/predict.rs` | The client's traffic model on a bot: correction sizes and late intents as the client measures them |
| `westbound-server/crates/bots/src/load.rs` | `/metrics` scrapes, windows between them, `/proc/<pid>` samples |
| `westbound-server/crates/bots/src/bin/loadtest.rs` | The load test: N rooms × M bots against a running server, the report against the targets |
| `westbound-server/crates/server/tests/netcode.rs` | The acceptance test in the normal suite (1 room × 8 bots × 30 s) and the long one (ignored) |

## Results

### Load: 20 rooms × 8 bots, Docker `--cpus=1 --memory=512m` (2026-09-30)

The release image built from `westbound-server/Dockerfile` (`westbound-server:n10.1`, production mode), 20 private rooms at normal density, 160 bots through traffic with honest claims, every bot on its own 150 ms / ±30 ms / 2 % TCP link, 15 s warm-up, then a 600 s window. The load generator ran on the same 4-vCPU machine outside the container, which other agents were also using (load average 6–8 during the normal run, 2–5 during the rush run: a headless browser and a Godot soak), so the wall-time numbers (tick p99, max) are pessimistic. The container was CPU-throttled in 0 of 6,202 CFS periods (normal) and 1 of 3,201 (rush). The rush run is 300 s after the same warm-up.

| Measure | Target | Normal, 600 s | Rush, 300 s |
| --- | --- | --- | --- |
| Server CPU (process, over the window) | ≤ 50 % of one core | **38.1 %** (`docker stats` 35–45 %) | **42.8 %** (`docker stats` 40–49 %) |
| Room tick p99 (histogram bucket bound) | < 5 ms | **≤ 3 ms** (mean 0.64 ms, p50 ≤ 0.75 ms) | **≤ 2 ms** (mean 0.69 ms) |
| Room tick max | | 105 ms (host scheduler stalls; the tick is wall time) | 39 ms |
| Room ticks' share of the CPU | | 25.8 % of a core (the rest: gateway, sockets, SQLite) | 27.5 % |
| Server memory (RSS at the end / peak) | < 300 MB | **99.6 / 99.4 MB** (`docker stats` 97 MiB with page cache) | **100.9 / 100.7 MB** |
| Down per player, worst bot, on the wire | ≤ 10 KB/s | **5.09 KB/s** (mean 4.69; server payload 4.16 KB/s per session) | **5.61 KB/s** (mean 4.90; server payload 4.37 KB/s) |
| Up per player (payload) | ~1 KB/s | 0.50 KB/s | 0.50 KB/s |
| Largest frame | | 1,754 B (a join's area) | 2,350 B |

**After merging N10.2 (ops) and N8.2 (DetMath in the `sim` crate)** the same load at normal density for 300 s on a quieter box (load average 1–3): 36.3 % of the core, room tick p99 ≤ 1.5 ms (mean 0.51 ms, max 183 ms), 99.9 MB, 4.91 KB/s worst player, 7,027 of 7,027 claims, correction p99 0.275 m, 0.08 late intents per 10 bot-minutes, 0 offences, 0 false hits, not throttled.

### Netcode acceptance at 150 ms RTT, ±30 ms jitter, 2 % loss

The same run (160 bots × 10 min: 27.5 bot-hours), and the in-process test (`acceptance_30s`, 1 room × 8 bots, rush, 30 s, debug build):

| Measure | Target | Load run, normal | Load run, rush | `acceptance_30s` |
| --- | --- | --- | --- | --- |
| Claim acceptance | > 99 % | **99.92 %** (13,161 of 13,171; 10 rejected: `no_pass` 5, `thread` 2, `clearance`, `side`, `timing` 1 each) | **99.95 %** (10,994 of 10,999; `no_pass` 3, `cut`, `side` 1 each) | 100 % (25 of 25) |
| False server-detected hits | < 1 per hour | **0** in 27.5 bot-hours (21 hits reported, 12 confirmed, 1 refused, 8 crash-outs) | **0** in 14.2 bot-hours (27 reported, 17 confirmed) | 0 |
| Traffic correction median / p99 | < 0.15 m / < 0.6 m | **5 mm / 0.285 m** (max 3.7 m; 8.4 M corrections) | **5 mm / 0.39 m** (max 3.65 m; 5.4 M) | 5 mm / 0.21 m |
| Corrections of cars within 100 m: p99 / max | | 3.5 cm / 1.7 m | 4 cm / 1.25 m | 4 cm / 0.2 m |
| Snap-sized (≥ 5 m) correction of a car in view | (none visible) | **0** | **0** | 0 |
| Late intents | < 1 per 10 min | **0.06 per 10 bot-minutes** (10 late, 9 of them after their move tick, of 144,702 lane changes) | **0.02** (2 of 71,778) | 0 |
| Plausibility offences (honest bots) | 0 | **0** | **0** | 0 |
| Traffic stream violations (bots' mirrors) | 0 | 0 | 0 | 0 |

For comparison, plain dead reckoning (the last correction carried on at its speed) has a p99 of 0.90 m on the same corrections: the bots' model is what makes the bound. The client's own soak (NET_TRAFFIC.md, the fake authority, 10.5 min) measured 5 mm / 0.22 m.

**The link as delivered** (both directions, 4 M frames): 2.0 % of frames retransmitted, mean delay 86 ms (75 ± 15 ms plus the retransmissions and the frames they hold up), p99 278 ms, max 1.48 s (a retransmission lost again: 200 + 400 ms back-off plus head-of-line).

### Shadow contacts in the load run

6,569 contacts between bots (534 pairs), 239 per player-hour, 2.5 M pair-ticks, mean contact 376 ticks (19 s): the bots are ghosts that never avoid each other and drive the same lanes at similar speeds, so this is an upper bound on what human crews will produce. Disagreement of the two views: 95 % under 0.5 m, 30 contacts (0.5 %) over 1 m, max 5.9 m. Speeds: 94 % between 100 and 200 km/h. Every contact reached `shadow_contacts` (0 dropped).

### Fixes found by the load test

The server met every target unchanged; what the runs found were bot artefacts, fixed in the bots:

- **A joined bot that stopped driving jumped on its next step** (its step integrates the wall time since the last one): the first runs had `teleport` / `distance` offences for bots waiting for the others to join. The load test now starts each room's bots driving as soon as the room is joined, and `drive_for` no longer flushes the delay lines at its end (a drive in steps bunched their frames up; `close()` flushes).
- **A backward step of the bot's clock estimate** (a lower-RTT Pong) made the next accepted state cover more road than its tick difference allowed (`distance`). The bot now slews its clock back at 5 % like the client (MP-D4), forward at once.
- **A state sent late in its tick carried the current speed** (only the position was carried back): two such states read as more than the acceleration cap (`accel`, 6 in the first run). The speed is carried back too.
- **The bots' traffic model lacked the lane-drop harmonisation zones:** correction p99 0.66 m in the first 10-minute run, 0.285 m with them (NET_TRAFFIC.md measured the same effect on the client: 0.61 → 0.22 m).

No server hot spot needed a fix: the room tick averages 0.64 ms (the traffic ring's step, the `sim` crate, is most of it; N4.1 measured ~200 µs at normal density, and streaming ~50 µs and scoring ~30 µs per tick come on top), the gateway and sockets the other ~12 % of a core. `perf` is not installed in this container; the cost split comes from the existing timers (`wb_room_tick_seconds`, `wb_room_scoring_seconds_total`) and `bench_streaming_cost_per_room_tick`.

## Running it

### Against Docker (the N10 condition)

```sh
docker build -t westbound-server:local westbound-server          # (behind a TLS proxy: see SERVER.md → Docker image)
docker run -d --name wb-lt --cpus=1 --memory=512m --network host \
  -e WB_SERVER__BIND=127.0.0.1:18080 -e WB_METRICS__BIND=127.0.0.1:19090 \
  -e WB_AUTH__JWT_SECRET=$(openssl rand -hex 32) -e WB_AUTH__DEVICE_SECRET_PEPPER=$(openssl rand -hex 32) \
  -e WB_GATEWAY__MAP_HASHES=$(printf 'ab%.0s' {1..32}) \
  -e WB_RATE_LIMITS__ENABLED=false -e WB_BACKUP__ENABLED=false -e WB_LOG__FORMAT=json \
  westbound-server:local
cd westbound-server
cargo run -p bots --release --bin loadtest -- --server ws://127.0.0.1:18080/ws --metrics 127.0.0.1:19090 \
  --rooms 20 --bots 8 --rtt 150 --jitter 30 --loss 0.02 --secs 600
cat /sys/fs/cgroup/cpu/docker/$(docker inspect -f "{{.Id}}" wb-lt)/cpu.stat   # throttling (cgroup v1; v2: /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.stat)
```

- `--network host`: the metrics listener must be a loopback address (`metrics.bind`), and the load test reads it. Without host networking, publish the public port only and pass `--pid` (the container's process as the host sees it: `docker inspect -f '{{.State.Pid}}' wb-lt`) for `/proc` CPU and memory; the tick times then come from nowhere (`n/a`).
- `WB_RATE_LIMITS__ENABLED=false`: 160 device accounts from one address (the default allows 5 per hour).
- `WB_GATEWAY__MAP_HASHES`: the bots send `ab…ab` (`--map-hash` changes it); `WB_SERVER__ENV=dev` accepts any hash instead (and needs no secrets).

### On the host, without Docker

`taskset -c 0 westbound-server serve` (with the same environment) pins the server to one core without a cgroup quota; run the load test on the other cores (`taskset -c 1-3 loadtest …`) so they do not compete. The CPU share is the same measurement (the server's own `/proc/self/stat`); only the cap differs (a core, not a quota).

### Options

| Option | Default | |
| --- | --- | --- |
| `--server` | required | `ws://HOST:PORT/ws` (no TLS); device accounts go to the same `HOST:PORT` |
| `--metrics` | `HOST:9090` | The server's metrics listener (`/metrics`, `/admin/stats`) |
| `--pid` | | Read `/proc/<pid>` for CPU and memory when the metrics lack them |
| `--rooms`, `--bots` | 20, 8 | Private rooms and bots per room |
| `--rtt`, `--jitter`, `--loss` | 150, 30, 0.02 | Each direction `rtt/2 ± jitter/2`; loss a fraction (above 1: percent) |
| `--mode` | `stream` | `stream` (TCP: late, in order) or `datagram` (gone, reordered: experiments only, a WebSocket never does this) |
| `--no-link` | | Loopback as is |
| `--secs`, `--warmup` | 600, 10 | The measured window, after the warm-up |
| `--density` | `normal` | `light`, `normal`, `rush` |
| `--map-hash`, `--build`, `--seed` | `ab…ab`, 100, 1 | |
| `--strict` | | Exit 3 when a target is missed (default: 0; 1 on a failed run) |

The report is a Markdown table of the targets (`ok` / `MISS`), then the server's detail (tick mean, p50, max, room share, payload per session), the bots' bytes, claims and rejections by reason, offences by kind, the shadow counters, corrections (all, near, dead reckoning), intents and the link statistics, and the `/admin/stats` JSON.

## How each number is measured

| Number | Source |
| --- | --- |
| Server CPU | `process_cpu_seconds_total` (the server's `/proc/self/stat`) over the window's wall time |
| Memory | `process_resident_memory_bytes` / `_peak_bytes` (`VmRSS` / `VmHWM`) |
| Tick p50 / p99 | `wb_room_tick_seconds` bucket deltas over the window: the bucket bound (25 µs … 100 ms) at or below which the share falls; the mean from `_sum` / `_count`; the max is `wb_room_tick_max_seconds` since the start |
| Down per player | Each bot's received frames with WebSocket and TLS framing (`protocol::budget::on_wire_len`), over its window; the worst bot is the target's |
| Claim acceptance | `wb_room_claims_total` after the tail (claims off for 2.5 s, so every claim is decided); rejections of claims that arrived after their run ended (`no_run`) do not count against anyone |
| False hits | `wb_room_hits_unreported_total` (server-detected contacts with no hit report) per bot-hour driven |
| Corrections | `bots::predict::TrafficPredictor` (below): every correction against the model at the correction's tick, `hypot(e_s, e_d)`, 5 mm bins |
| Late intents | A `lane_change` arriving (by the bot's room clock) later than 0.25 s before its move tick; after it: very late (NET_TRAFFIC.md → Intents) |

### The delay layer (`bots::link`)

Each direction is a `DelayLine` with its own mean delay, jitter (peak to peak) and loss. **Stream** (the WebSocket over TCP): a lost frame is retransmitted after `rto_ms` (200 ms: Linux's minimum RTO and the Godot harness's `test_link_rto_ms`), lost again after twice that (up to 6 back-offs), and every frame behind it waits: frames come out in order. **Datagram**: a lost frame is dropped, jitter reorders. Seeded (`BotRng`): the same seed and pushes give the same schedule (`link::tests::the_schedule_is_deterministic_by_seed`). Statistics per line: frames, bytes, lost, retransmits, dropped, held (head-of-line), reordered, and a 1 ms delay histogram (mean, quantiles, min, max). A `BotClient` owns its two lines for its whole connection; `link_stats()` reads them.

### The client's traffic model on a bot (`bots::predict`)

A compact port of `NetworkTrafficSource` + `TrafficCorrector` (docs/NET_TRAFFIC.md → Time and the model, Corrections): every streamed car runs IDM at room ticks (the ballistic step with the held acceleration, leaders by lateral overlap with a moving car spanning to its target, players stretched by their lateral velocity, the racers' weaving parameters, the MP-D5 look-through and leader-braking anticipation, hard brakes, the 6 m/s² clamp), the lane-drop harmonisation zones, the desired speed estimated from free-driving corrections (else a fading bias), lane changes only from intents on the server's curve. The model is brought to each frame's correction tick with the players there (the bot from its own recent states, the others from their relayed states) and the frame's despawns, spawns, intents and corrections apply in order; a correction is compared with the model at its tick (the client compares with its history at that tick: the same value). Not ported: the merge zones, the zipper, the closure wall and the cut-in brake tap (the client does not mirror them either, except the tap). Its errors are therefore an upper bound on the client's.

## Tests

| Test | What |
| --- | --- |
| `bots::link::tests` | Stream order, mean, loss, head-of-line; datagram drops and reordering; per-direction delays; determinism by seed; merged statistics and quantiles |
| `bots::predict::tests` | A car at its desired speed predicted to the millimetre; a new desired speed learned; a follower braking for its leader; late and very late intents; the loop's drop zones and a car braking into one; the histograms |
| `bots::load::tests` | Prometheus text parsing, window deltas and histogram quantiles; `/proc` |
| `tests/netcode.rs` `acceptance_30s` | Normal suite: 1 room × 8 honest bots × 30 s at rush over the acceptance link: every claim decided, > 99 % accepted, 0 offences, 0 false hits, 0 stream violations, correction median < 0.15 m and p99 < 0.6 m, no snap-sized correction in view, no late intent |
| `tests/netcode.rs` `acceptance_long` (ignored) | The same for `NETCODE_SECS` (600) at `NETCODE_DENSITY`, with the spec's rates (false hits < 1 per hour, late intents < 1 per 10 minutes): `cargo test --release -p server --test netcode acceptance_long -- --ignored --nocapture` |
| `tests/rooms.rs` `bench_20_rooms_of_8_bots` (ignored) | The in-process bench (bots and server in one process, SERVER.md → Rooms → Bench) |
