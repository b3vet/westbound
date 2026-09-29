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
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Architecture", "Server tech stack",
//! "Resource budget and deployment"; docs/MULTIPLAYER_PLAN.md → N0, MP-D1.

pub mod accounts;
pub mod admin;
pub mod app;
pub mod auth;
pub mod backup;
pub mod clock;
pub mod config;
pub mod db;
pub mod error;
pub mod gateway;
pub mod healthcheck;
pub mod http;
pub mod leaderboards;
pub mod metrics;
pub mod msg_limits;
pub mod names;
pub mod profanity;
pub mod profile;
pub mod ratelimit;
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
