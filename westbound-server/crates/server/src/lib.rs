//! westbound-server: HTTP API, realtime gateway, lobby, rooms, DB, admin CLI.
//! N0 (WPs N0.1 + N0.2): health route, WebSocket echo gateway, config, tracing,
//! metrics, SQLite + migrations, nightly backup, graceful shutdown.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Architecture", "Server tech stack",
//! "Resource budget and deployment"; docs/MULTIPLAYER_PLAN.md → N0, MP-D1.

pub mod app;
pub mod backup;
pub mod clock;
pub mod config;
pub mod db;
pub mod healthcheck;
pub mod http;
pub mod metrics;
pub mod shutdown;
pub mod telemetry;
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
