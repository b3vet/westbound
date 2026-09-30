# Westbound Online: implementation plan

Plan for [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) (the multiplayer spec; it extends [`WESTBOUND HANDOFF.md`](../WESTBOUND%20HANDOFF.md)). Same process as the single-player plan ([`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)): orchestrator + up to 5 parallel agents in worktrees, work packages (WPs) with owned paths, tests first, merge gate, handoff notes, deviations flagged.

## 1. Kickoff decisions (owner, 2026-09-29)

| Topic | Decision |
| --- | --- |
| Sequencing | **Parallel tracks.** The server track (N0–N10) runs alongside single-player Phases 7–9, sharing the agent slots. N0–N2 need nothing from the game and start at once. N3+ start once Phase 6 (traffic/biomes) has closed, because the server ports that traffic |
| Deployment | **Coolify on the owner's VPS, Docker images.** GitHub Actions builds the server image and pushes it to GHCR; Coolify pulls and runs it. Everything is tested locally first (Docker, a local TLS proxy, bots) |
| Gates | **No milestone waits.** The owner playtests in parallel; every push keeps the single-player game and the web build working |
| Accounts | **Device accounts only for now.** Apple / Google linking, sign-in and the native secure-storage plugins are deferred until the iOS export is set up (MP-D2) |

## 2. Deviations from the multiplayer spec (flagged)

| # | Spec says | Plan does | Why |
| --- | --- | --- | --- |
| MP-D1 | Caddy in front (TLS, web build, deep-link files); systemd unit; static musl binary on the VPS; nightly `.backup` script | The server ships as a Docker image (static musl binary in a minimal image) built by GitHub Actions and pushed to GHCR. Coolify runs it; **Coolify's proxy terminates TLS** and routes `/api/*` and `/ws` to the container. SQLite lives on a Coolify persistent volume; the nightly `.backup` runs inside the container (a scheduled task in the server, 7-day retention on the volume) plus Coolify's volume backups. Deep-link files (`apple-app-site-association`, `assetlinks.json`) are served by the server itself. The web build stays on GitHub Pages until the owner moves it. A `deploy/Caddyfile` is kept for local TLS testing and non-Coolify hosts | Owner decision: Coolify is already running on the VPS |
| MP-D2 | N1: Apple / Google linking and sign-in, account-deletion Apple revocation, iOS Keychain / Android encrypted-storage plugins | N1 ships device accounts, tokens, refresh rotation, names, deletion. The server keeps the identity columns (`apple_sub`, `google_sub`) and the route shapes, returning "not enabled" until configured. On web the device secret lives in local storage; native builds use an encrypted `user://` file until the Keychain plugin lands | Owner decision: needs the Apple/Google developer setup |
| MP-D3 | Loop sections: desert, canyon, coast, city, farmland | Same sections, built from the Phase 6 biomes (WP6.4a/b/c). The loop needs a closed road: the procedural road generator is open-ended, so N3 adds a loop-closing generator and editor tool | Implementation note, not a design change |
| MP-D4 | Clock sync: offset from the lowest-RTT sample of the last 8, slewed smoothly | Same rule, plus smoothing: the estimate moves toward that sample with a 30 s time constant (1 s while the window fills), capped at 5 % correction speed; forward jumps above 250 ms apply at once. A pure lowest-RTT-of-8 estimate leaves ±12–15 ms error at 150 ± 30 ms RTT; with smoothing the worst error is 3.2–3.8 ms (spec target ±5 ms). All in `NetTuning` | N2.2 |
| MP-D5 | Server traffic runs the single-player traffic model | Same model (bit-exact parity), plus three safety extensions the loop's rush-density lane-drop queues need (without them one rush hour has 11,622 collision ticks): `look_through_leaving_leaders`, `predict_leader_braking`, `anticipate_leader_braking` (flags in `crates/sim/data/mp_traffic.json`). **Ported to `traffic_sim.gd` in WP6.11** (on in single-player and in the parity config; the client mirrors look-through and anticipation). WP6.11 changed two things in both models: the leader prediction applies only to a braking leader (predicting approach to a steady leader refused every closing gap and quadrupled canyon standstills), and prediction and look-through use the car's own IDM toward that vehicle (racers: their weaving parameters). One-hour soaks at every density: 0 contacts. Lane splitting is off on the server (a split targets a lane boundary, which `target_lane` cannot express). Server-only numbers (capacity 1600, extrapolation cap 0.5 s, ramp and fill rates) are marked "not in spec" | N4.1 |
| MP-D6 | Protocol lane numbering and ids (no wire-format change) | `lane` / `target_lane` stay 0 = rightmost on the wire; the server converts from the sim's median-first lanes at encode, the client back at decode. Lane value **7** is reserved for a ramp (off- and on-ramp cars; the loop has at most 4 lanes). `car_id` u16 is allocated by the server from a free list, never reused within 30 s of its despawn, mapped from the sim's i32 `vehicle_id` | Orchestrator, N4.1 → N4.2 |
| MP-D7 | Room rules the spec leaves open (N5.1) | A private room's `cycle` clock is UTC-derived like public rooms; `night` holds mid-night (27 min). A run counts for the boards when verified and public, or private at normal density on `cycle` for the whole run. "No crew nearby" = no crewmate driving; the leader is the longest-present driving crewmate; with none, a respawn is where the car is. Kicked players can't rejoin that room. `run_result` goes to the whole room. The lateral-speed cap is 12 m/s (a lane change peaks ~8.4). New numbers (gap search ±60 m / 5 m / 15 m clear, placement grace, clock tolerances, queue sizes) live in `[rooms]` config | N5.1 |
| MP-D8 | Client traffic follows intents exactly; corrections blend | Late intents: the move still begins at its tick, but the client never moves a car sideways before its blinker has shown 0.25 s, then catches the server's curve within 0.2 s. Errors over 5 m snap only out of view; in view they slide at ≤ 30 m/s (blend times apply to the running offset). A cancel that arrives after its move tick (the server cancels unsafe gaps at the move tick) shows as a 1–3 cm start and a slide back with the blinker on. Client capacity 90 cars; spawns beyond it are dropped and counted (NET_TRAFFIC.md) | N4.3 |
| MP-D9 | Client room behaviour the spec leaves open (N5.2) | Pause in a room pauses the local run (no states go up; others see the car fade; the seat is kept). REJOIN CREW forfeits the unbanked chain (as a hit: multiplier reset, 3 s minimum-speed grace). Room runs award no garage XP (for now). Remote players are not IDM leaders for network cars on the client (the per-car bias and corrections cover it). Room traffic capacity 128 on the client (single-player stays 90). Host settings after creation have no UI yet | N5.2 |
| MP-D10 | Scoring rules the spec leaves open (N6.1) | A run is `verified` with no plausibility offence and ≥ 90 % of claims accepted over ≥ 20 claims (`[scoring]` config). The official score runs on a timeline lagged 1.5 s (config, ≤ 2.5 s); `ScoreSync` at banking moments and ≥ 1 Hz. A placement is acknowledged only by a state of the placed car (`run_state = protected`, or speed and d within the caps plus slack), so clients send `protected` during protection. Claim semantics (a pass claim's tick is the pass's completion; `score_sync.tick` is the lagged official tick; a sector claim names the 1-based sector just completed) are in SERVER.md. MP board rows carry car "unknown" and build 0 (not on the wire) | N6.1 |

New deviations get a row here before they are built.

## 3. Repository layout

- `westbound-server/`: the Cargo workspace from the spec (`crates/{protocol,sim,server,bots}`, `migrations/`, `data/`, `deploy/`). Built and tested by `cargo` in CI.
- `src/net/`: the Godot client module from the spec (`transport`, `ws_transport`, `codec`, `clock`, `session`, `api`, `lobby`, `room_client`, `remote_player`, `network_traffic_source`, `traffic_corrector`, `score_client`, `replay_recorder`).
- `tools/server_data/`: Godot headless exporters that write `westbound-server/data/` (driver profiles, loop road-space file, parity vectors). CI checks the committed data is up to date ("data shared with the client comes from the client").
- `.github/workflows/server.yml`: `cargo fmt --check`, `clippy -D warnings`, `cargo test`, golden-vector check on both sides, Docker build; pushes to GHCR on this branch.

**Orchestrator-owned shared files (MP):** `westbound-server/Cargo.toml` (workspace members, shared dependency versions), `westbound-server/crates/protocol/src/messages.rs` after N2 freezes it, `.github/workflows/*`, this plan, plus the single-player shared files.

## 4. Merge gate (MP WPs)

1. `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test --workspace` green.
2. Godot side: `tools/test.sh` ALL PASSED, `tools/lint`, and `tools/check_warnings.sh` printing `0 with warnings`.
3. Golden vectors pass on both sides once N2 exists.
4. `sim` stays pure (no I/O, clocks or globals) and deterministic, with a trace-hash test for each seeded system.
5. Resource checks where the WP touches them: tick p99, memory, bytes per player (N4+).
6. The single-player game and web build keep working (web smoke PASS).

## 5. Phases

Milestone names follow the spec (N0–N10). None of them pause for the owner.

### N0 Server foundation

| WP | Scope |
| --- | --- |
| N0.1 Server skeleton | Workspace; axum server: `/api/v1/health`, `/ws` echo, config (file + env), tracing, `/metrics` (Prometheus text, localhost only), SQLite (WAL) with sqlx migrations and offline query data, clap admin subcommands (`migrate`, `serve`), graceful shutdown; tests |
| N0.2 Image & CI | Multi-stage Dockerfile (musl static binary, minimal runtime image, non-root, healthcheck, `/data` volume); `docker-compose.yml` for Coolify and local runs; a local TLS proxy config (`deploy/Caddyfile`, self-signed) for wss testing; `server.yml` workflow (fmt, clippy, test, build, push `ghcr.io/<owner>/westbound-server` on this branch); `docs/SERVER.md` runbook for Coolify (image, env, volume, domain, health check) |

**Done when:** the image runs locally, a Godot headless client (or the web build in Chromium) connects over `wss://` through the local TLS proxy and echoes, and CI pushes the image. On the owner's side, Coolify deploys it and a phone connects.

### N1 Accounts (device only, MP-D2)

| WP | Scope |
| --- | --- |
| N1.1 Server accounts | `POST /api/v1/auth/device`, JWT (1 h) + rotating refresh (30 d) + device secret (hash only stored), `POST /auth/refresh`, `GET/PATCH /me` (display name `name#1234`, 3–16 chars, profanity filter with a normalized word list, rename every 30 days), `DELETE /api/v1/account`, bans; per-IP and per-account rate limits (`tower_governor`); Apple/Google route shapes returning "not enabled"; tests |
| N1.2 Client session | `src/net/session.gd` (device account, secure-ish storage per platform, token refresh), `src/net/api.gd` (HTTPRequest wrapper, retries, errors), a minimal profile panel (name, rename, delete account) behind the dev menu; headless tests against a local server |

### N2 Protocol and clock

| WP | Scope |
| --- | --- |
| N2.1 Protocol crate | Every message in the spec with its quantization, the `[u8 type][u16 len][payload]` framing, validation (sizes, ranges), and golden vectors (JSON + bytes) written to `westbound-server/crates/protocol/vectors/`; the handshake (`Hello`/`Welcome`/`Error`, version and map hash), keepalive, and the WebSocket gateway wired to it; fuzz tests for the decoder |
| N2.2 Client codec & clock | `src/net/transport.gd`, `ws_transport.gd`, `codec.gd` (every golden vector encodes/decodes byte-identically), `clock.gd` (8 samples, lowest RTT, slewing, `server_now()`; converges within ±5 ms on a simulated link), handshake client; tests |

**The protocol freezes after N2** (changes need an orchestrator decision and a vector update).

### N3 Loop map (after Phase 6)

| WP | Scope |
| --- | --- |
| N3.1 Loop generator & editor | A closed-loop road generator (fixed seed, about 25 km, sections desert → canyon → coast → city → farmland, lanes 3/4/2-in-tunnel, two ramp pairs, 6 sector gantries, sun constraint relaxed for the loop), an editor tool to hand-tune it, and an export of the client scene data plus `loop_v1` road-space JSON (version and content hash) |
| N3.2 Wrap-around & server map | Client chunk streaming with `s` wrapping modulo L (road builder, roadside, biome features, floating origin, traffic view); a "loop test" single-player mode; server map loading, wrapped signed-difference math, and the hash check on join |

### N4 Networked traffic

| WP | Scope |
| --- | --- |
| N4.1 Rust traffic sim | `sim` crate: IDM, MOBIL, driver profiles (exported from Godot), lane discipline, keep-right, ramps and density upkeep (light/normal/rush), the player as participant, no-ambush against predicted players, 1.0 s minimum signal time; parity vectors with the GDScript models (≤ 1e-9); a one-hour loop soak (0 collisions, stable density, signals ≥ 1.0 s) |
| N4.2 Server traffic streaming | Room-side traffic: area of interest (−300/+900 m), `TrafficSpawn/Despawn/Intent/Correction`, correction schedule (5 Hz within 100 m, ≥ 1 Hz otherwise), one frame per tick per client, bytes budget |
| N4.3 Client network traffic | `network_traffic_source.gd` (a SpawnSource; client director and MOBIL off), local IDM at `server_now`, `traffic_corrector.gd` (history, blend rules, late intents), sandbox network overlays, dev HUD network metrics |
| N4.4 Bots & delay layer | `bots` crate: scripted drivers, in-process delay/jitter/loss layer, metrics (correction sizes, late intents); acceptance at 150 ms RTT / ±30 ms / 2 % loss |

### N5 Rooms and players

Room tasks (one tokio task each, bounded channels, 20 Hz); private rooms with codes and host rules; `PlayerState` relay and plausibility checks; remote players (100 ms interpolation, 250 ms extrapolation, ghosting, nametags); spawning in a traffic gap near the crew; crash-out respawn; rejoin crew; reconnect with a 15 s seat hold; the loop strip; the room clock (32 min cycle, UTC-derived for public rooms, host options for private ones) replacing the sun bar in rooms.

### N6 Multiplayer scoring

`sim::scoring` port (parity with GDScript scoring), claims and verification (timing ±300 ms, clearance +0.35 m), official score and `ScoreSync` easing, hit cross-check (overlap > 0.3 m for 2+ ticks), sectors with bonuses and clean-sector restore, crew proximity (+0.25× per crewmate within 30 m, cap ×2), trains, session crew total, night ×2 from the room clock; client `score_client.gd` and HUD (crew indicator, train counter); bots reach > 99 % claim acceptance.

### N7 Leaderboards

Boards and seasons (Loop, Loop crew, Journey, Daily Drive, Distance; global / around me / friends); multiplayer runs written automatically; `POST /api/v1/runs` with plausibility checks; legacy personal-best upload; leaderboard UI replacing the Game Center / Play boards (achievements stay).

### N8 Replay verification

Replay recorder (30 Hz path, inputs, event log); **determinism audit of the single-player sim** (seeded RNG only; no `pow`/`sin`/`cos`/`exp` in sim paths; fixed tick; no iteration-order dependence); a headless Godot verifier image (a second Docker image, one job at a time, `nice 10`, 1 GB memory cap) keyed by build id; the verification queue in SQLite; "verifying" UI state; honest replays 100 % accepted, tampered replays rejected.

### N9 Social and public play

Friends (name#1234 codes, requests), presence, parties, persistent crews (tag, roles, invite code), public rooms (normal density, UTC clock), Quick Join (fits the whole party), room browser with ping, quick chat (presets, horn, emotes, mute), report and block, moderation admin CLI, deep-link invites (`/r/<code>`, served deep-link files).

### N10 Hardening

Load test (20 rooms × 8 bots under a 1-vCPU Docker limit: ≤ 50 % CPU, tick p99 < 5 ms, < 300 MB, ≤ 10 KB/s per player), shadow collision logging and admin stats, full admin CLI, rate-limit review, backups, graceful restart with the 60 s notice and auto-reconnect, metrics.

## 6. Waves

- **Now (alongside Phase 6's tail):** N0.1, N0.2, N2.1 (the protocol crate can start on the workspace skeleton the orchestrator lays down first).
- **Next:** N1.1, N1.2, N2.2.
- **After Phase 6 closes:** N3 → N4 → N5 → N6 (the critical path), with N7 and N9's account-side pieces (friends, crews) in parallel once N1 is in, and N8's determinism audit in parallel with single-player Phase 7.
- **Last:** N10.

## 7. Status tracker

| Milestone | Status |
| --- | --- |
| N0 Server foundation | ✅ **gate met on the real VPS** (owner, 2026-09-29): deployed on Coolify at `westbound.sipsakrandevu.com`, reachable, wss echo works from a phone. Image 3.6 MB; CI pushes `ghcr.io/b3vet/westbound-server:edge` |
| N1 Accounts (device) | ✅ server accounts (N1.1) + client session and profile panel (N1.2); autoload `Net` signs in silently on web and release builds (native dev runs stay offline unless `--server=`). **Owner: set `WB_AUTH__JWT_SECRET` and `WB_AUTH__DEVICE_SECRET_PEPPER` in Coolify before redeploying.** The "survives an iOS reinstall / second device" check waits for the Keychain plugin and providers (MP-D2) |
| N2 Protocol & clock | ✅ protocol crate + golden vectors, GDScript codec/transports/clock (MP-D4), gateway on `/ws` (handshake, auth, bans, map hashes, keepalive, rate limits, newest-login-wins sessions); echo check moved to `/ws/echo`. Production answers `map_mismatch` until N3 sets `WB_GATEWAY__MAP_HASHES` |
| N3 Loop map | ✅ `loop_v1` (25 km) + editor + canonical export; the client drives it lap after lap in loop practice mode (`?mode=loop`: sectors, room clock, per-section traffic; 3-lap soak clean); the server compiles the map in and accepts its hash automatically (`26a4e08b…d296`). Open question: should roadside props repeat every lap |
| N4 Networked traffic | 🟨 N4.1 ✅ `sim` crate: bit-exact parity with `traffic_sim.gd` (IDM, MOBIL, no-ambush, RNG, 4 traces tick-identical incl. WP6.8 drops and WP6.9 racers), 8 players, loop wrap, ramps, light/normal/rush upkeep, 0 allocations per tick; 1-hour soaks at every density: 0 collisions, 0 violations, signals ≥ 1.05 s; rush 362 µs per tick (20 rooms = 14.5 % of a core). MP-D5, MP-D6. N4.3 ✅ client: `NetworkTrafficSource` runs the server model at `server_now()` (no MOBIL, no director; lane changes from intents), corrector with history and blend rules, fake authority + delay link, sandbox overlay, dev HUD rows; 10.5-min soaks at 150 ± 30 ms / 2 % loss: 0 visible teleports, near-player correction p99 1.5–2 cm, ~970 B/s. MP-D8. N4.2 ✅ server streaming (default `rooms.traffic = "sim"`): per-client AOI −300/+900 m (20 m hysteresis), the N4.3 contract item by item, car_id holds, 0 allocations; 8-bot rush room 5.0–5.2 KB/s per player on the wire (traffic ~1.35 KB/s); 20 rooms × 8 bots at rush: 21 % of a core, p99 ≤ 4 ms. Open: client capacity 90 vs 90+ cars at rush in the city (raise it or narrow the AOI). Next: N4.4 bots & delay-layer acceptance |
| N5 Rooms & players | ✅ N5.1 ✅ server: 20 Hz room tasks, private rooms (codes, host kick/density/time, host hand-off), public rooms + Quick Join + browse, PlayerState relay + plausibility (offences mark the run unverified, no kicks), spawns behind the crew leader in a real traffic gap, crash-out respawn, rejoin, 15 s seat hold, room clock, presence; `RoomTraffic` seam with the N4.1 `TrafficWorld` behind it; bots crate drives rooms over real sockets. Bench 20 rooms × 8 bots: 2 % of a core without traffic, 14.8 % with (p99 ≤ 4 ms). MP-D7. N5.2 ✅ client: hub QUICK JOIN / PRIVATE ROOM / JOIN BY CODE / BROWSER, placement, remote players (100 ms interpolation, 250 ms extrapolation, ghosted, nametags, pool of 7), room clock, crash-out and respawn, REJOIN CREW, reconnect into the same seat within 15 s, loop strip, room HUD, quick chat, streamed network traffic (capacity 128). Live check against a local server: all steps OK, 0 plausibility offences. MP-D9 |
| N6 Multiplayer scoring | 🟨 N6.1 ✅ server: `sim::scoring` bit-exact with `src/scoring/` (hull 2000/2000, 3 traces event- and hash-identical), claim verification (±300 ms, +0.35 m, AOI; 12 reject reasons, no kicks), hit cross-check → `hit_car`, official score + ScoreSync, sectors with bonuses, crew proximity, trains, session crew total, night ×2, verified MP runs to the Loop boards. Honest bots at 150 ± 30 ms: 100 % of 555 claims accepted; cheating bots rejected. +28.5 µs per room tick. MP-D10. Next: N6.2 client (claims, ScoreSync easing, crew indicator, train counter) |
| N7 Leaderboards | ✅ server (N7.1) + client (N7.2): Journey/Daily runs submitted after each run (offline queue, idempotent, legacy PB upload), placements on the results screen, leaderboards screen (5 boards, periods, global/around me/friends, report/block). Loop boards fill from N6. Replays come with N8 |
| N8 Replay verification | 🟨 N8.1 ✅ recorder (30 Hz, `.wbr`, ~35–54 KB per 10 min), upload with offline retry (`POST /runs/{id}/replay`), SQLite queue (one job at a time, retries, retention), Godot verifier core (`tools/verifier/`), tamper tests rejected. **Not deployed:** honest runs longer than a few tens of seconds diverge (director decisions sit on knife edges of the player's exact state), so runs stay "verifying" until N8.2. N8.2 ⬜ determinism: WP8.4 measured native vs wasm: identical 18–19 s, then 1 ulp from libm (`sin`, `cos`, `tan`, `exp`, `pow`, `atan*` differ; `sqrt`, `log` match) in `VehiclePhysics.step`, `Lives`, `HitDetection`, `TrafficSim`, `Scoring`, `RoadHull`, `VehicleParams`; the quality tier's view distance sets the director's spawn distance (tier-dependent traffic). Needs deterministic transcendentals, a fixed spawn distance, and decoupled director decisions (docs/DAILY.md → Findings); needs a verifier export preset (current presets exclude `tools/*`) and the verifier Docker image |
| N9 Social & public play | 🟡 server (N9.1) + client (N9.2): friends, requests, blocks, presence (WS or polling), crews with roles, report dialog — under Pause → SETTINGS → ACCOUNT → FRIENDS / CREW. Room-dependent parts (parties, public rooms, Quick Join, browser, quick chat, Join button, invite links) after N5 |
| N10 Hardening | ⬜ |

## 8. Open items for the owner

1. ~~Domain~~ **Decided:** `westbound.sipsakrandevu.com` for the API (`/api/v1/*`), the WebSocket (`/ws`), invite links (`/r/<code>`) and the deep-link files (owner, 2026-09-29).
2. **VPS transfer allowance** (the spec budgets about 36 MB per player-hour).
3. ~~GHCR access~~ **Done:** Coolify already has a GHCR registry token (the owner's other projects deploy from GHCR).
4. Apple / Google developer setup when the iOS export happens (MP-D2).
