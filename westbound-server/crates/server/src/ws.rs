//! WebSocket plumbing shared by the two socket routes:
//! - `/ws`: the realtime protocol gateway (`gateway.rs`, N2.3);
//! - `/ws/echo`: an echo of every text and binary message, kept for ops checks (the
//!   `/api/v1/echo-check` page, `tools/net_echo_check.gd`), with the same limits.
//!
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (bounded everything:
//! 64-frame outbound queue, slow clients disconnected, 16 KB inbound max),
//! "Networking protocol" (ping every 2 s, dead after 8 s of silence),
//! "Resource budget and deployment" (400-connection cap).
//!
//! Each connection has a reader loop (its task) and a writer task that owns the socket sink.
//! Everything bound for the client goes through one bounded queue; anything that finds it
//! full (a reply, the keepalive, later the room task) disconnects the client instead of
//! buffering without bound. A close frame queued behind data (after a fatal `Error`) is
//! delivered in order; shutdown and timeouts close ahead of the queue.

use std::net::SocketAddr;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use axum::extract::ws::{close_code, CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::stream::{SplitSink, SplitStream, StreamExt};
use futures_util::SinkExt;
use protocol::handshake::Keepalive;
use protocol::ErrorCode;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::{Instant, MissedTickBehavior};

use crate::app::AppState;
use crate::metrics::Metrics;

/// Keepalive checks per ping interval (the timeout is detected within a quarter interval).
const KEEPALIVE_CHECKS_PER_INTERVAL: u32 = 4;

/// Why the server ended a connection (also the close frame it tries to send).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseReason {
    ClientClosed,
    Oversize,
    SlowClient,
    Timeout,
    Shutdown,
    /// N10.2: the planned restart's close (1012): the client reconnects and rejoins.
    Restart,
    Error,
    /// The gateway sent this fatal protocol `Error` (handshake failure, kick, flood).
    Fatal(ErrorCode),
}

impl CloseReason {
    fn frame(self) -> Option<CloseFrame> {
        let (code, reason) = match self {
            CloseReason::Oversize => (close_code::SIZE, "message too big"),
            CloseReason::Timeout => (close_code::AWAY, "keepalive timeout"),
            CloseReason::Shutdown => (close_code::AWAY, "server shutting down"),
            CloseReason::Restart => (close_code::RESTART, "server restarting"),
            CloseReason::Error => (close_code::PROTOCOL, "protocol error"),
            CloseReason::Fatal(ErrorCode::Internal) => (close_code::ERROR, "internal"),
            CloseReason::Fatal(code) => (close_code::POLICY, error_label(code)),
            // The queue is full, so a close frame could not get through anyway.
            CloseReason::SlowClient | CloseReason::ClientClosed => return None,
        };
        Some(CloseFrame {
            code,
            reason: reason.into(),
        })
    }
}

/// The snake_case name of an error code (docs/PROTOCOL.md §7), for close frames and logs.
pub fn error_label(code: ErrorCode) -> &'static str {
    match code {
        ErrorCode::UpdateRequired => "update_required",
        ErrorCode::ServerOutdated => "server_outdated",
        ErrorCode::MapMismatch => "map_mismatch",
        ErrorCode::AuthFailed => "auth_failed",
        ErrorCode::Banned => "banned",
        ErrorCode::HandshakeRequired => "handshake_required",
        ErrorCode::Malformed => "malformed",
        ErrorCode::RateLimited => "rate_limited",
        ErrorCode::ServerFull => "server_full",
        ErrorCode::RoomNotFound => "room_not_found",
        ErrorCode::RoomFull => "room_full",
        ErrorCode::PartyNotFound => "party_not_found",
        ErrorCode::PartyFull => "party_full",
        ErrorCode::NotHost => "not_host",
        ErrorCode::NotPartyLeader => "not_party_leader",
        ErrorCode::NotInRoom => "not_in_room",
        ErrorCode::AlreadyInRoom => "already_in_room",
        ErrorCode::Blocked => "blocked",
        ErrorCode::NotAllowed => "not_allowed",
        ErrorCode::Internal => "internal",
    }
}

/// Holds one slot of `limits.max_connections`; frees it on drop.
struct ConnectionSlot(Arc<Metrics>);

impl ConnectionSlot {
    fn try_acquire(metrics: &Arc<Metrics>, cap: usize) -> Option<Self> {
        let cap = cap as u64;
        metrics
            .ws_connections
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < cap).then_some(n + 1)
            })
            .ok()?;
        Metrics::inc(&metrics.ws_connections_total);
        Some(Self(metrics.clone()))
    }
}

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        self.0.ws_connections.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Route {
    Gateway,
    Echo,
}

/// `GET /ws`: the protocol gateway.
pub async fn upgrade(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    accept(state, peer, &headers, ws, Route::Gateway)
}

/// `GET /ws/echo`: the ops echo.
pub async fn upgrade_echo(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    if !state.config.gateway.echo_enabled {
        return crate::http::not_found().await;
    }
    accept(state, peer, &headers, ws, Route::Echo)
}

fn accept(
    state: AppState,
    peer: SocketAddr,
    headers: &HeaderMap,
    ws: WebSocketUpgrade,
    route: Route,
) -> Response {
    // Logs carry a keyed hash of the client IP, never the IP itself.
    let client = state.auth.ip_tag(
        state
            .rate_limiters
            .proxies
            .client_ip_from(peer.ip(), headers),
    );
    if state.shutdown.is_cancelled() {
        return (StatusCode::SERVICE_UNAVAILABLE, "shutting down").into_response();
    }
    let limits = &state.config.limits;
    let Some(slot) = ConnectionSlot::try_acquire(&state.metrics, limits.max_connections) else {
        Metrics::inc(&state.metrics.ws_rejected_full);
        tracing::warn!(%client, "connection cap reached; upgrade refused");
        return (StatusCode::SERVICE_UNAVAILABLE, "server full").into_response();
    };
    let max = limits.max_message_bytes;
    ws.max_message_size(max)
        .max_frame_size(max)
        .on_upgrade(move |socket| {
            let tasks = state.tasks.clone();
            tasks.track_future(async move {
                let reason = match route {
                    Route::Gateway => crate::gateway::run(socket, &state, &client).await,
                    Route::Echo => {
                        Metrics::inc(&state.metrics.ws_echo_connections_total);
                        run_echo(socket, &state).await
                    }
                };
                tracing::info!(%client, ?route, ?reason, "websocket closed");
                drop(slot);
            })
        })
}

/// The writer half of a connection: its bounded queue and the task draining it.
pub struct Outbound {
    /// The connection's bounded outbound queue (`limits.outbound_queue_frames`).
    pub tx: mpsc::Sender<Message>,
    pub writer: JoinHandle<()>,
    close_tx: Option<oneshot::Sender<Option<CloseFrame>>>,
}

impl Outbound {
    pub fn spawn(sink: SplitSink<WebSocket, Message>, state: &AppState) -> Self {
        let (tx, rx) = mpsc::channel::<Message>(state.config.limits.outbound_queue_frames);
        let (close_tx, close_rx) = oneshot::channel();
        let writer = tokio::spawn(write_loop(sink, rx, close_rx, state.metrics.clone()));
        Self {
            tx,
            writer,
            close_tx: Some(close_tx),
        }
    }

    /// Queues a message; `false` if the queue is full (slow client) or the writer is gone.
    pub fn send(&self, msg: Message) -> bool {
        match self.tx.try_send(msg) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => {
                tracing::info!("outbound queue full; disconnecting slow client");
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    /// Ends the connection for `reason` and waits (up to the shutdown grace) for the writer.
    pub async fn finish(mut self, reason: CloseReason, state: &AppState) -> CloseReason {
        let grace = state.config.shutdown_grace();
        let reason = match reason {
            CloseReason::SlowClient => reason,
            CloseReason::Error if self.writer.is_finished() => return reason,
            // In order, behind the fatal `Error` already queued (N10.2: a restart's close
            // goes behind the rooms' last frames, the run results).
            CloseReason::Fatal(_) | CloseReason::Restart => {
                if self.send(Message::Close(reason.frame())) {
                    reason
                } else {
                    CloseReason::SlowClient
                }
            }
            _ => {
                if let Some(close_tx) = self.close_tx.take() {
                    let _ = close_tx.send(reason.frame());
                }
                reason
            }
        };
        if reason == CloseReason::SlowClient {
            // The writer is stuck on a full socket: drop the connection outright.
            Metrics::inc(&state.metrics.ws_slow_client_closed);
            self.writer.abort();
            return reason;
        }
        drop(self.tx);
        if tokio::time::timeout(grace, &mut self.writer).await.is_err() {
            self.writer.abort();
        }
        reason
    }
}

async fn write_loop(
    mut sink: SplitSink<WebSocket, Message>,
    mut rx: mpsc::Receiver<Message>,
    mut close_rx: oneshot::Receiver<Option<CloseFrame>>,
    metrics: Arc<Metrics>,
) {
    loop {
        tokio::select! {
            biased;
            close = &mut close_rx => {
                if let Ok(Some(frame)) = close {
                    let _ = sink.send(Message::Close(Some(frame))).await;
                }
                let _ = sink.close().await;
                return;
            }
            msg = rx.recv() => {
                let Some(msg) = msg else {
                    let _ = sink.close().await;
                    return;
                };
                if matches!(msg, Message::Close(_)) {
                    let _ = sink.send(msg).await;
                    let _ = sink.close().await;
                    return;
                }
                let data = matches!(msg, Message::Text(_) | Message::Binary(_));
                let len = payload_len(&msg) as u64;
                if sink.send(msg).await.is_err() {
                    return;
                }
                if data {
                    Metrics::inc(&metrics.ws_frames_out);
                    Metrics::add(&metrics.ws_bytes_out, len);
                }
            }
        }
    }
}

/// Keepalive on the server side (docs/PROTOCOL.md §1): a WebSocket ping every
/// `limits.ping_interval_ms` (keeps proxies and NATs open; clients answer automatically) and
/// dead after `limits.dead_after_ms` without receiving anything. Wraps the protocol crate's
/// `Keepalive` with a monotonic millisecond clock started at the upgrade.
pub struct ServerKeepalive {
    started: Instant,
    keepalive: Keepalive,
    pub check: tokio::time::Interval,
}

impl ServerKeepalive {
    pub fn new(state: &AppState) -> Self {
        let l = &state.config.limits;
        // Validated to fit in u16 (`Welcome` carries them).
        let ping = u16::try_from(l.ping_interval_ms).unwrap_or(u16::MAX);
        let dead = u16::try_from(l.dead_after_ms).unwrap_or(u16::MAX);
        let period = (state.config.ping_interval() / KEEPALIVE_CHECKS_PER_INTERVAL)
            .max(std::time::Duration::from_millis(1));
        let mut check = tokio::time::interval_at(Instant::now() + period, period);
        check.set_missed_tick_behavior(MissedTickBehavior::Delay);
        Self {
            started: Instant::now(),
            keepalive: Keepalive::new(0, ping, dead),
            check,
        }
    }

    /// Milliseconds since the upgrade.
    pub fn now_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    pub fn on_receive(&mut self) {
        let now = self.now_ms();
        self.keepalive.on_receive(now);
    }

    /// On each `check` tick: `Err(Timeout)` when dead, `Err(SlowClient)` when the ping could
    /// not be queued.
    pub fn on_check(&mut self, out: &Outbound) -> Result<(), CloseReason> {
        let now = self.now_ms();
        if self.keepalive.is_dead(now) {
            return Err(CloseReason::Timeout);
        }
        if self.keepalive.ping_due(now) {
            self.keepalive.on_ping_sent(now);
            if !out.send(Message::Ping(Default::default())) {
                return Err(CloseReason::SlowClient);
            }
        }
        Ok(())
    }
}

/// Reads one message; maps read errors (oversize → 1009) to a close reason.
pub async fn next_message(
    stream: &mut SplitStream<WebSocket>,
    metrics: &Metrics,
) -> Result<Message, CloseReason> {
    let Some(msg) = stream.next().await else {
        return Err(CloseReason::ClientClosed);
    };
    match msg {
        Ok(m) => Ok(m),
        Err(e) => {
            if is_oversize(&e) {
                Metrics::inc(&metrics.ws_oversize_closed);
                return Err(CloseReason::Oversize);
            }
            tracing::debug!(error = %e, "websocket read error");
            Err(CloseReason::Error)
        }
    }
}

/// `/ws/echo`: echoes every text and binary message until the client leaves.
pub async fn run_echo(socket: WebSocket, state: &AppState) -> CloseReason {
    let metrics = state.metrics.clone();
    let (sink, mut stream) = socket.split();
    let mut out = Outbound::spawn(sink, state);
    let mut keepalive = ServerKeepalive::new(state);

    let reason = loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => break CloseReason::Shutdown,
            _ = keepalive.check.tick() => {
                if let Err(r) = keepalive.on_check(&out) {
                    break r;
                }
            }
            _ = &mut out.writer => break CloseReason::Error,
            msg = next_message(&mut stream, &metrics) => {
                let msg = match msg {
                    Ok(m) => m,
                    Err(r) => break r,
                };
                keepalive.on_receive();
                match msg {
                    Message::Text(_) | Message::Binary(_) => {
                        Metrics::inc(&metrics.ws_frames_in);
                        Metrics::add(&metrics.ws_bytes_in, payload_len(&msg) as u64);
                        if !out.send(msg) {
                            break CloseReason::SlowClient;
                        }
                    }
                    Message::Ping(_) | Message::Pong(_) => {}
                    Message::Close(_) => break CloseReason::ClientClosed,
                }
            }
        }
    };
    if reason == CloseReason::Timeout {
        Metrics::inc(&metrics.ws_timeout_closed);
    }
    out.finish(reason, state).await
}

pub fn payload_len(msg: &Message) -> usize {
    match msg {
        Message::Text(t) => t.len(),
        Message::Binary(b) => b.len(),
        Message::Ping(b) | Message::Pong(b) => b.len(),
        Message::Close(_) => 0,
    }
}

/// tungstenite reports a message or frame over `max_message_size` as a capacity
/// error; everything else is a protocol or I/O failure.
fn is_oversize(e: &axum::Error) -> bool {
    let mut src: Option<&(dyn std::error::Error + 'static)> = Some(e);
    while let Some(err) = src {
        if let Some(t) = err.downcast_ref::<tungstenite::Error>() {
            return matches!(t, tungstenite::Error::Capacity(_));
        }
        src = err.source();
    }
    false
}
