//! Logging setup (`tracing` + `tracing-subscriber`), text or JSON, to stderr
//! (collected by `docker logs` / Coolify). Tokens and secrets are
//! never logged: request spans carry method and path only (no query string, no
//! headers), and `config::Secret` redacts itself.

use std::io::IsTerminal;

use tracing_subscriber::{fmt, EnvFilter};

use crate::config::LogConfig;

/// Installs the global subscriber. `RUST_LOG` overrides `log.level` when set.
/// Safe to call more than once (later calls are ignored).
pub fn init(cfg: &LogConfig) {
    let filter = std::env::var("RUST_LOG")
        .ok()
        .and_then(|v| EnvFilter::try_new(v).ok())
        .unwrap_or_else(|| EnvFilter::new(&cfg.level));
    let builder = fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_ansi(std::io::stderr().is_terminal())
        .with_target(true);
    let _ = if cfg.format == "json" {
        builder
            .json()
            .flatten_event(true)
            .with_current_span(true)
            .try_init()
    } else {
        builder.try_init()
    };
}
