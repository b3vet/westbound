//! Graceful shutdown on SIGTERM / SIGINT. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Resource budget and deployment" (restarts: a notice 60 s before a planned
//! restart; clients reconnect automatically).
//!
//! Order: signal → [`pre_shutdown`] hook → cancel `AppState::shutdown` (stop
//! accepting, close sockets with a close frame) → caller closes the database.

use std::time::Duration;

use crate::app::AppState;

/// Resolves on the first SIGTERM (Docker / Coolify stop) or SIGINT (Ctrl-C).
pub async fn signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(e) => {
                tracing::error!(error = %e, "cannot install SIGTERM handler");
                std::future::pending::<()>().await;
            }
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => tracing::info!("SIGINT received"),
        _ = term => tracing::info!("SIGTERM received"),
    }
}

/// Runs between the signal and the cancel, while clients are still connected.
/// N10 hook: broadcast `ServerNotice` and wait `server.restart_notice_secs`
/// (60 s in the spec) so clients can reconnect on their own. The wait is here
/// already; the notice needs the N2 protocol.
pub async fn pre_shutdown(state: &AppState) {
    let notice = state.config.server.restart_notice_secs;
    if notice > 0 {
        tracing::info!(secs = notice, "restart notice period");
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(notice)) => {}
            _ = signal() => tracing::info!("second signal: skipping the rest of the notice"),
        }
    }
}

/// Waits for a signal, runs the hook, then starts the shutdown.
pub async fn watch(state: AppState) {
    signal().await;
    pre_shutdown(&state).await;
    tracing::info!("shutting down");
    state.shutdown.cancel();
}
