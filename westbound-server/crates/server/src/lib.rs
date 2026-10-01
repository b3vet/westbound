//! westbound-server: HTTP API, realtime gateway, lobby, rooms, DB, admin CLI.
//! N0 (WPs N0.1 + N0.2): health route, WebSocket echo gateway, config, tracing,
//! metrics, SQLite + migrations, nightly backup, graceful shutdown.
//! N1.1: device accounts, JWT access + rotating refresh tokens, profiles and display
//! names with a profanity filter, account deletion, bans, rate limits, admin CLI
//! (docs/MULTIPLAYER_PLAN.md MP-D2: device accounts only).
//! N2.3: the `/ws` protocol gateway (handshake, sessions, per-message rate limits, tick
//! clock for Pong, live ban sweep); the echo moved to `/ws/echo`.
//! N7.1: leaderboards (boards, periods, views, top-N cache), single-player run
//! submissions with plausibility checks, legacy personal bests, the multiplayer-run hook
//! for N6, the replay-verdict hook for N8, admin removals.
//! N9.1: the social API (friends and requests, blocks, persistent crews with roles and
//! invite codes, reports), friends presence over HTTP and the WebSocket, the friends
//! leaderboard view, crew tags on boards, and the moderation admin commands.
//! N3.2: the loop map (`map`: `loop_v1.json` compiled in, validated, hashed; its hash is
//! accepted by the gateway unless `gateway.map_hashes` overrides it).
//! N8.1: replay uploads (`POST /api/v1/runs/{run_id}/replay`), the verification queue
//! (one verifier process at a time, timeouts, retries; none configured = jobs wait) and
//! replay retention (top-N entries keep their files).
//! N5.1: rooms and players (`rooms`): room tasks at 20 Hz, private rooms with codes and
//! host rules, public rooms (Quick Join, the browser), the `PlayerState` relay with
//! plausibility checks, spawns, crash-out respawns, rejoin crew, the 15 s seat hold and
//! the room clock; the gateway routes room messages to the session's room.
//! N10.2: operations: the admin API and the full admin CLI, the planned restart (notice,
//! drain, room handover, close 1012), backups with verification, an off-site hook and
//! restore, per-IP and per-account rate limits, request ids, and the ops metrics.
//! N10.3: housekeeping on the small data volume: at most 3 daily backups, the backup age
//! check, free-space guard, row retention (shadow contacts, admin log, handled reports,
//! old board periods, runs without entries), WAL checkpoints and VACUUM, disk metrics,
//! and the `set_aside` replay status with its purge.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Architecture", "Server tech stack",
//! "Resource budget and deployment"; docs/MULTIPLAYER_PLAN.md → N0, MP-D1.

pub mod account_limits;
pub mod accounts;
pub mod admin;
pub mod admin_api;
pub mod admin_client;
pub mod app;
pub mod auth;
pub mod backup;
pub mod clock;
pub mod config;
pub mod db;
pub mod error;
pub mod gateway;
pub mod handover;
pub mod healthcheck;
pub mod housekeeping;
pub mod http;
pub mod leaderboards;
pub mod map;
pub mod metrics;
pub mod metrics_admin;
pub mod msg_limits;
pub mod names;
pub mod ops;
pub mod presence;
pub mod profanity;
pub mod profile;
pub mod ratelimit;
pub mod replays;
pub mod rooms;
pub mod runs;
pub mod sessions;
pub mod shutdown;
pub mod social;
pub mod telemetry;
pub mod tick;
pub mod ws;

pub use app::{AppState, Server};
pub use config::Config;

/// Crate version (`Cargo.toml`).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Build id baked in at compile time from `WB_BUILD` (the git sha in CI and the
/// Docker image), `dev` otherwise.
pub const BUILD: &str = match option_env!("WB_BUILD") {
    Some(b) => b,
    None => "dev",
};
