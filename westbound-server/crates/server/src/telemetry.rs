//! Logging setup (`tracing` + `tracing-subscriber`), text or JSON, to stderr
//! (collected by `docker logs` / Coolify). Tokens and secrets are
//! never logged: request spans carry method, path and a request id only (no query string,
//! no headers), and `config::Secret` redacts itself.
//!
//! N10.2: every WARN and ERROR event is also counted (`wb_log_events_total{level}`), so an
//! alert on errors covers every logged failure without a counter at each call site.

use std::io::IsTerminal;
use std::sync::atomic::{AtomicU64, Ordering};

use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{fmt, EnvFilter, Layer};

use crate::config::LogConfig;

static ERRORS: AtomicU64 = AtomicU64::new(0);
static WARNINGS: AtomicU64 = AtomicU64::new(0);

/// (errors, warnings) logged since start.
pub fn log_event_counts() -> (u64, u64) {
    (
        ERRORS.load(Ordering::Relaxed),
        WARNINGS.load(Ordering::Relaxed),
    )
}

/// Counts WARN and ERROR events that pass the filter.
struct CountLayer;

impl<S: Subscriber> Layer<S> for CountLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        match *event.metadata().level() {
            Level::ERROR => ERRORS.fetch_add(1, Ordering::Relaxed),
            Level::WARN => WARNINGS.fetch_add(1, Ordering::Relaxed),
            _ => 0,
        };
    }
}

/// Installs the global subscriber. `RUST_LOG` overrides `log.level` when set.
/// Safe to call more than once (later calls are ignored).
pub fn init(cfg: &LogConfig) {
    let filter = std::env::var("RUST_LOG")
        .ok()
        .and_then(|v| EnvFilter::try_new(v).ok())
        .unwrap_or_else(|| EnvFilter::new(&cfg.level));
    let registry = tracing_subscriber::registry().with(filter).with(CountLayer);
    let _ = if cfg.format == "json" {
        registry
            .with(
                fmt::layer()
                    .json()
                    .flatten_event(true)
                    .with_current_span(true)
                    .with_span_list(false)
                    .with_target(true)
                    .with_writer(std::io::stderr),
            )
            .try_init()
    } else {
        registry
            .with(
                fmt::layer()
                    .with_ansi(std::io::stderr().is_terminal())
                    .with_target(true)
                    .with_writer(std::io::stderr),
            )
            .try_init()
    };
}
