//! Graceful shutdown and the planned restart (N10.2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → "Resource budget and deployment" (restarts: "the server broadcasts a notice 60 seconds
//! before a planned restart. Clients reconnect automatically and rejoin the same private
//! room by code, or Quick Join again"). Runbook: docs/OPERATIONS.md → Restarts.
//!
//! On SIGTERM (a Coolify redeploy, `docker stop`) or SIGINT:
//! 1. **Drain.** `server_notice{restart, seconds}` goes to every live session (and to each
//!    session that signs in meanwhile, with the seconds left). The rooms stop taking new
//!    rooms and new seats (`server_full`, "restarting"); a held seat can still be taken back.
//!    `/api/v1/health` answers 503 `draining` so a proxy stops sending new clients here.
//!    Reminders go out at `server.restart_notice_reminders_secs` left. The notice ends early
//!    once nobody is connected, or on a second signal.
//! 2. **Handover** ([`handover`]): every room closes at its next tick: active runs end as
//!    `room_closed` with their banked score (verified runs are written to the boards) and
//!    the run results go out; the rooms' codes and settings go to `room-handover.json`
//!    (`crate::handover`) for the next instance.
//! 3. **Close.** `AppState::shutdown` is cancelled: the listeners stop, each socket gets its
//!    queued frames and then close **1012** (service restart): clients reconnect and rejoin
//!    by code. `Server::run` waits for the background writes (the runs above), then the
//!    caller checkpoints the WAL and closes the database.
//!
//! Without a restart (tests cancelling `shutdown` directly) sockets close with 1001.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use protocol::{NoticeKind, ServerMsg, ServerNotice, Text};
use tokio::time::Instant;

use crate::app::AppState;
use crate::metrics::Metrics;
use crate::rooms::CloseMode;

/// The restart notice's text (English; clients localize by `kind` and show `seconds`).
pub const RESTART_TEXT: &str = "Server restart soon. You'll reconnect automatically.";
/// How often the notice period checks whether anyone is still connected.
const NOTICE_POLL: Duration = Duration::from_secs(1);

/// The drain state shared by the gateway, the health route and the admin API.
#[derive(Debug, Default)]
pub struct Drain {
    draining: AtomicBool,
    /// The handover ran: sockets close with 1012 (clients rejoin the next instance).
    restart: AtomicBool,
    /// When the notice ends.
    deadline: Mutex<Option<Instant>>,
}

impl Drain {
    /// Starts draining with `secs` of notice.
    pub fn begin(&self, secs: u64) {
        *self.deadline.lock().unwrap_or_else(|p| p.into_inner()) =
            Some(Instant::now() + Duration::from_secs(secs));
        self.draining.store(true, Ordering::Release);
    }

    pub fn is_draining(&self) -> bool {
        self.draining.load(Ordering::Acquire)
    }

    /// The handover is done: closing sockets means "restart".
    pub fn set_restart(&self) {
        self.restart.store(true, Ordering::Release);
    }

    pub fn is_restart(&self) -> bool {
        self.restart.load(Ordering::Acquire)
    }

    /// Whole seconds of notice left (rounded up), while draining.
    pub fn seconds_left(&self) -> Option<u16> {
        if !self.is_draining() {
            return None;
        }
        let deadline = (*self.deadline.lock().unwrap_or_else(|p| p.into_inner()))?;
        let left = deadline.saturating_duration_since(Instant::now());
        let secs = left.as_millis().div_ceil(1_000);
        Some(u16::try_from(secs).unwrap_or(u16::MAX))
    }
}

/// A `server_notice`.
pub fn notice(kind: NoticeKind, seconds: u16, text: &str) -> ServerMsg {
    let mut text = text.replace(|c: char| c.is_control() && c != '\n', " ");
    // `text` is at most 255 bytes on the wire: cut at a character boundary.
    while text.len() > protocol::types::MAX_TEXT_BYTES {
        text.pop();
    }
    ServerMsg::ServerNotice(ServerNotice {
        kind,
        seconds,
        text: Text(text),
    })
}

/// The restart notice with `seconds` left.
pub fn restart_notice(seconds: u16) -> ServerMsg {
    notice(NoticeKind::Restart, seconds, RESTART_TEXT)
}

/// Sends `msg` (one frame) to every live session; returns how many took it.
pub fn broadcast(state: &AppState, msg: &ServerMsg) -> usize {
    let frame = match protocol::encode_frame(std::slice::from_ref(msg)) {
        Ok(f) => f,
        Err(e) => {
            tracing::error!(error = %e, "notice does not encode");
            return 0;
        }
    };
    let sent = state
        .sessions
        .snapshot()
        .iter()
        .filter(|s| s.send_frame(frame.clone()))
        .count();
    Metrics::inc(&state.metrics.server_notices);
    sent
}

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

/// Waits for a signal, then runs the planned restart (a second signal cuts the notice).
pub async fn watch(state: AppState) {
    signal().await;
    restart(&state, signal()).await;
}

/// The planned restart: drain with the notice, hand the rooms over, start the shutdown.
/// `skip` cuts the notice short when it resolves (a second signal).
pub async fn restart(state: &AppState, skip: impl std::future::Future<Output = ()>) {
    let secs = state.config.server.restart_notice_secs;
    state.drain.begin(secs);
    state.rooms.set_draining(true);
    Metrics::set(&state.metrics.server_draining, 1);
    tracing::info!(
        secs,
        sessions = state.sessions.len(),
        rooms = state.rooms.room_count(),
        "restart: draining"
    );
    if secs > 0 {
        notice_period(state, secs, skip).await;
    }
    let rooms = handover(state).await;
    state.drain.set_restart();
    tracing::info!(rooms, "restart: shutting down");
    state.shutdown.cancel();
}

/// The notice: the first one now, reminders at the configured seconds left, until the
/// deadline, `skip`, or nobody connected.
async fn notice_period(state: &AppState, secs: u64, skip: impl std::future::Future<Output = ()>) {
    let start = Instant::now();
    let end = start + Duration::from_secs(secs);
    let n = broadcast(
        state,
        &restart_notice(u16::try_from(secs).unwrap_or(u16::MAX)),
    );
    tracing::info!(secs, sessions = n, "restart notice sent");
    let mut reminders: Vec<u64> = state
        .config
        .server
        .restart_notice_reminders_secs
        .iter()
        .copied()
        .filter(|r| *r < secs)
        .collect();
    reminders.sort_unstable_by(|a, b| b.cmp(a));
    reminders.dedup();
    let mut next = reminders.into_iter().peekable();
    tokio::pin!(skip);
    loop {
        if state.sessions.is_empty() {
            tracing::info!("restart: nobody connected, the notice ends early");
            return;
        }
        let now = Instant::now();
        if now >= end {
            return;
        }
        let due = next.peek().map(|r| end - Duration::from_secs(*r));
        let wake = [Some(end), due, Some(now + NOTICE_POLL)]
            .into_iter()
            .flatten()
            .min()
            .unwrap_or(end);
        tokio::select! {
            _ = &mut skip => {
                tracing::info!("second signal: skipping the rest of the notice");
                return;
            }
            _ = tokio::time::sleep_until(wake) => {}
        }
        if let Some(r) = next.peek().copied() {
            if Instant::now() >= end - Duration::from_secs(r) {
                next.next();
                let n = broadcast(state, &restart_notice(u16::try_from(r).unwrap_or(u16::MAX)));
                tracing::info!(secs_left = r, sessions = n, "restart reminder sent");
            }
        }
    }
}

/// Closes every room for the restart and writes the handover file. Returns the number
/// of rooms handed over.
pub async fn handover(state: &AppState) -> usize {
    let rooms = state.rooms.close_all(CloseMode::Restart).await;
    let path = crate::handover::path_for(&state.config.db.path);
    let now = state.clock.now();
    match crate::handover::save(&path, &rooms, now, state.config.server.handover_ttl_secs).await {
        Ok(()) => tracing::info!(rooms = rooms.len(), path = %path.display(), "rooms handed over"),
        Err(e) => {
            tracing::error!(error = %format!("{e:#}"), "writing the room handover failed")
        }
    }
    Metrics::add(&state.metrics.rooms_handed_over, rooms.len() as u64);
    rooms.len()
}
