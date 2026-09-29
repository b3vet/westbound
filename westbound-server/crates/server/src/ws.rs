//! `/ws`: the realtime gateway's connection handling. In N0 it echoes every text and
//! binary message; N2 puts the protocol handshake on top.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (bounded everything:
//! 64-frame outbound queue, slow clients disconnected, 16 KB inbound max),
//! "Networking protocol" (ping every 2 s, dead after 8 s of silence),
//! "Resource budget and deployment" (400-connection cap).
//!
//! Each connection has a reader loop (this task) and a writer task that owns the
//! socket sink. Everything bound for the client goes through one bounded queue;
//! anything that finds it full (today the echo and the keepalive, later the room
//! task) disconnects the client instead of buffering without bound.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use axum::extract::ws::{close_code, CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures_util::stream::{SplitSink, StreamExt};
use futures_util::SinkExt;
use std::net::SocketAddr;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Instant, MissedTickBehavior};

use crate::app::AppState;
use crate::metrics::Metrics;

/// Why the server ended a connection (also the close frame it tries to send).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseReason {
    ClientClosed,
    Oversize,
    SlowClient,
    Timeout,
    Shutdown,
    Error,
}

impl CloseReason {
    fn frame(self) -> Option<CloseFrame> {
        let (code, reason) = match self {
            CloseReason::Oversize => (close_code::SIZE, "message too big"),
            CloseReason::Timeout => (close_code::AWAY, "keepalive timeout"),
            CloseReason::Shutdown => (close_code::AWAY, "server shutting down"),
            CloseReason::Error => (close_code::PROTOCOL, "protocol error"),
            // The queue is full, so a close frame could not get through anyway.
            CloseReason::SlowClient | CloseReason::ClientClosed => return None,
        };
        Some(CloseFrame {
            code,
            reason: reason.into(),
        })
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

pub async fn upgrade(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    ws: WebSocketUpgrade,
) -> Response {
    if state.shutdown.is_cancelled() {
        return (StatusCode::SERVICE_UNAVAILABLE, "shutting down").into_response();
    }
    let limits = &state.config.limits;
    let Some(slot) = ConnectionSlot::try_acquire(&state.metrics, limits.max_connections) else {
        Metrics::inc(&state.metrics.ws_rejected_full);
        tracing::warn!(%peer, "connection cap reached; upgrade refused");
        return (StatusCode::SERVICE_UNAVAILABLE, "server full").into_response();
    };
    let max = limits.max_message_bytes;
    ws.max_message_size(max)
        .max_frame_size(max)
        .on_upgrade(move |socket| {
            let tasks = state.tasks.clone();
            tasks.track_future(async move {
                let reason = run(socket, &state).await;
                tracing::info!(%peer, ?reason, "websocket closed");
                drop(slot);
            })
        })
}

/// Drives one connection until it closes; returns why.
pub async fn run(socket: WebSocket, state: &AppState) -> CloseReason {
    let limits = &state.config.limits;
    let metrics = state.metrics.clone();
    let (sink, mut stream) = socket.split();
    let (tx, rx) = mpsc::channel::<Message>(limits.outbound_queue_frames);
    let (close_tx, close_rx) = oneshot::channel::<Option<CloseFrame>>();
    let mut writer = tokio::spawn(write_loop(sink, rx, close_rx, metrics.clone()));

    let ping_every = state.config.ping_interval();
    let dead_after = state.config.dead_after();
    let mut ping = tokio::time::interval_at(Instant::now() + ping_every, ping_every);
    ping.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let silence = tokio::time::sleep(dead_after);
    tokio::pin!(silence);

    let reason = loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => break CloseReason::Shutdown,
            _ = &mut silence => {
                Metrics::inc(&metrics.ws_timeout_closed);
                break CloseReason::Timeout;
            }
            _ = ping.tick() => {
                if !enqueue(&tx, Message::Ping(Default::default())) {
                    break CloseReason::SlowClient;
                }
            }
            _ = &mut writer => break CloseReason::Error,
            msg = stream.next() => {
                let Some(msg) = msg else { break CloseReason::ClientClosed };
                let msg = match msg {
                    Ok(m) => m,
                    Err(e) => {
                        if is_oversize(&e) {
                            Metrics::inc(&metrics.ws_oversize_closed);
                            break CloseReason::Oversize;
                        }
                        tracing::debug!(error = %e, "websocket read error");
                        break CloseReason::Error;
                    }
                };
                silence.as_mut().reset(Instant::now() + dead_after);
                match msg {
                    Message::Text(_) | Message::Binary(_) => {
                        Metrics::inc(&metrics.ws_frames_in);
                        Metrics::add(&metrics.ws_bytes_in, payload_len(&msg) as u64);
                        // N0: echo. N2 replaces this with the protocol dispatcher.
                        if !enqueue(&tx, msg) {
                            break CloseReason::SlowClient;
                        }
                    }
                    Message::Ping(_) | Message::Pong(_) => {}
                    Message::Close(_) => break CloseReason::ClientClosed,
                }
            }
        }
    };

    match reason {
        CloseReason::SlowClient => {
            // The writer is stuck on a full socket: drop the connection outright.
            Metrics::inc(&metrics.ws_slow_client_closed);
            writer.abort();
        }
        CloseReason::Error if writer.is_finished() => {}
        _ => {
            let _ = close_tx.send(reason.frame());
            drop(tx);
            let grace = state.config.shutdown_grace();
            if tokio::time::timeout(grace, &mut writer).await.is_err() {
                writer.abort();
            }
        }
    }
    reason
}

/// `false` if the queue is full (slow client) or the writer is gone.
fn enqueue(tx: &mpsc::Sender<Message>, msg: Message) -> bool {
    match tx.try_send(msg) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) => {
            tracing::info!("outbound queue full; disconnecting slow client");
            false
        }
        Err(mpsc::error::TrySendError::Closed(_)) => false,
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

fn payload_len(msg: &Message) -> usize {
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
