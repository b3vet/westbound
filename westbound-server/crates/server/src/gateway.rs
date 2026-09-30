//! `/ws`: the realtime protocol gateway (WP N2.3). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! Networking protocol → Connection ("one wss://<domain>/ws per client, authenticated by the
//! access token in the first message"; `Hello` → `Welcome` or `Error`; ping every 2 s, dead
//! after 8 s), "Rules for the server code" (bounded everything, per-connection rate limits on
//! every message type, one owner per room), "Accounts and authentication → Security" (tokens
//! never logged, input validated before it reaches a room). Contract: docs/PROTOCOL.md §1, §5.
//!
//! One task per connection owns everything about it:
//! 1. **Frames** are decoded with the protocol crate (sizes, counts, ranges, strings). A frame
//!    that does not decode goes through `Handshake::on_undecodable`: before `Hello` a
//!    too-old/too-new `Hello` still gets its version error (`peek_hello_version`), anything
//!    else is a fatal `malformed`. Text frames are not protocol frames (`malformed`).
//! 2. **Handshake** (`protocol::handshake`, the frozen order of PROTOCOL.md §5): protocol
//!    version, client build, map hash, then the access token (signature, expiry, account,
//!    token version) and the ban. `Hello` must arrive within `gateway.hello_timeout_ms`.
//!    The token is only checked (one indexed SQLite read) when every cheaper check passed.
//! 3. **Session**: `Welcome`, then the account is registered in `Sessions` (a second login
//!    replaces the first, see `sessions.rs`).
//! 4. **Messages**: each passes its type's token bucket (`msg_limits.rs`), then is routed.
//!    `Ping` → `Pong` with the tick clock. `lobby_command.presence_subscribe` → friends
//!    presence (N9.1, `presence.rs`). The other lobby and room messages have no owner yet
//!    (N5/N9).
//! 5. **Keepalive**: `ServerKeepalive` (protocol `Keepalive`), dead after 8 s of silence.
//! 6. **Fatal errors** are sent, then the close frame follows once the client has closed or
//!    `gateway.fatal_close_delay_ms` passed (see `linger`).
//! 7. **Presence**: a new session (not a replacement) is announced to watching friends as
//!    online, and its end as offline, after the registry changed; the session's own
//!    subscription ends with it.
//! 8. **Kicks** from outside (duplicate login, the ban sweep, a slow-client report from a
//!    room) arrive on the session's `watch` and end in a fatal `Error` + close.

use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use futures_util::StreamExt;
use protocol::handshake::{
    fatal_error, Action, AuthError, Handshake, HandshakePolicy, DETAIL_BANNED,
};
use protocol::{
    decode_client_frame, AccountId, ClientMsg, DecodeError, ErrorCode, ErrorMsg, FrameBuilder,
    LobbyCommand, MapHash, Pong, ServerMsg, Text,
};
use tokio::sync::watch;

use crate::app::AppState;
use crate::auth::{self, AuthFailure};
use crate::config::{parse_map_hash, Config};
use crate::map::ServerMap;
use crate::metrics::{HandshakeResult, Metrics};
use crate::msg_limits::{client_type_index, MessageLimits, Verdict};
use crate::sessions::{Kick, SessionHandle};
use crate::tick::{TickClock, TickTime};
use crate::ws::{error_label, next_message, payload_len, CloseReason, Outbound, ServerKeepalive};

/// `Error.detail` texts the gateway adds to the handshake's (English; clients localize by code).
pub const DETAIL_HELLO_TIMEOUT: &str = "No Hello received in time.";
pub const DETAIL_REPLACED: &str = "This account signed in on another device.";
pub const DETAIL_REVOKED: &str = "You were signed out. Please sign in again.";
pub const DETAIL_RATE_LIMITED: &str = "Too many messages; some were dropped.";
pub const DETAIL_FLOOD: &str = "Too many messages.";
pub const DETAIL_INTERNAL: &str = "Server error. Please try again.";
pub const DETAIL_NO_LOBBY: &str = "The lobby is not available yet.";
pub const DETAIL_PRESENCE_UNAVAILABLE: &str = "Friends presence is unavailable. Try again.";
pub const DETAIL_NOT_IN_ROOM: &str = "You are not in a room.";

/// What the gateway accepts and announces, built once from the config.
#[derive(Debug, Clone)]
pub struct GatewayPolicy {
    /// Version range, build minimum, timing. Its `map_hash` is set per `Hello`.
    pub handshake: HandshakePolicy,
    /// The accepted map hashes: `gateway.map_hashes` parsed, or (empty list) the built-in
    /// map's hash (N3.2).
    pub map_hashes: Vec<MapHash>,
    /// `gateway.map_hashes` is empty in dev: any map hash is accepted (edited maps in
    /// local runs), the built-in one included.
    pub accept_any_map: bool,
    /// True when the accepted hashes came from `gateway.map_hashes` (an explicit override).
    pub hashes_from_config: bool,
}

impl GatewayPolicy {
    /// With the built-in loop map's hash as the default (`crate::map::builtin`).
    pub fn from_config(cfg: &Config) -> Self {
        let builtin = crate::map::builtin().map(|m| m.hash).ok();
        Self::with_builtin_map(cfg, builtin)
    }

    /// `builtin`: the hash accepted when `gateway.map_hashes` is empty (None: nothing).
    pub fn with_builtin_map(cfg: &Config, builtin: Option<MapHash>) -> Self {
        let configured: Vec<MapHash> = cfg
            .gateway
            .map_hashes
            .iter()
            .filter_map(|h| parse_map_hash(h))
            .collect();
        let hashes_from_config = !configured.is_empty();
        let map_hashes: Vec<MapHash> = if hashes_from_config {
            configured
        } else {
            builtin.into_iter().collect()
        };
        let mut handshake = HandshakePolicy::new(
            map_hashes.first().copied().unwrap_or_default(),
            server_build(),
        );
        handshake.min_client_build = cfg.gateway.min_client_build;
        handshake.tick_rate_hz = cfg.gateway.tick_rate_hz;
        // Validated to fit (Welcome carries u16 milliseconds).
        handshake.ping_interval_ms = u16::try_from(cfg.limits.ping_interval_ms).unwrap_or(u16::MAX);
        handshake.timeout_ms = u16::try_from(cfg.limits.dead_after_ms).unwrap_or(u16::MAX);
        Self {
            accept_any_map: !hashes_from_config && cfg.is_dev(),
            map_hashes,
            hashes_from_config,
            handshake,
        }
    }

    pub fn accepts_map(&self, hash: &MapHash) -> bool {
        self.accept_any_map || self.map_hashes.contains(hash)
    }

    /// The policy for one `Hello`. The handshake compares against a single hash, so an
    /// accepted hash is used as-is and a refused one is replaced by a hash that differs from
    /// it (the handshake then answers `map_mismatch`, in its frozen check order).
    fn for_hello(&self, hello_hash: &MapHash) -> HandshakePolicy {
        let mut p = self.handshake.clone();
        p.map_hash = if self.accepts_map(hello_hash) {
            *hello_hash
        } else {
            let mut other = hello_hash.0;
            other[0] ^= 0xFF;
            MapHash(other)
        };
        p
    }
}

/// `Welcome.server_build`: the first 8 hex digits of the build id (the git sha in CI and the
/// image), 0 for `dev` builds.
pub fn server_build() -> u32 {
    let hex: String = crate::BUILD.chars().take(8).collect();
    u32::from_str_radix(&hex, 16).unwrap_or(0)
}

/// **N5 seam.** The clock a `Pong` reports. Today every session gets the server-wide tick
/// clock (20 Hz since process start); N5 returns the session's room clock while it is in a
/// room (`server_tick` = the room tick, per PROTOCOL.md §1).
pub fn pong_clock<'a>(state: &'a AppState, _session: &SessionHandle) -> &'a dyn TickClock {
    state.tick_clock.as_ref()
}

/// The `Pong` for a `Ping`.
pub fn pong(client_time_ms: u32, now: TickTime) -> ServerMsg {
    ServerMsg::Pong(Pong {
        client_time_ms,
        server_tick: now.tick,
        tick_fraction: now.fraction,
    })
}

fn error_msg(code: ErrorCode, fatal: bool, detail: &str) -> ServerMsg {
    ServerMsg::Error(ErrorMsg {
        code,
        fatal,
        detail: Text(detail.to_owned()),
    })
}

/// Per-connection state for the reader loop.
struct Conn<'a> {
    state: &'a AppState,
    client: &'a str,
    out: Outbound,
    handshake: Handshake,
    limits: MessageLimits,
    keepalive: ServerKeepalive,
    /// This inbound frame's replies (one outbound frame per inbound frame).
    replies: FrameBuilder,
    session: Option<SessionHandle>,
    /// The session's kick signal (see `sessions.rs`).
    kick_rx: Option<watch::Receiver<Option<Kick>>>,
}

/// The connection's next step after a message.
enum Step {
    Continue,
    Close(CloseReason),
}

impl Conn<'_> {
    fn metrics(&self) -> &Metrics {
        &self.state.metrics
    }

    /// Appends a reply to this frame's batch, flushing first if it is full.
    fn reply(&mut self, msg: &ServerMsg) -> Result<(), CloseReason> {
        if self.replies.push(msg).is_ok() {
            return Ok(());
        }
        self.flush()?;
        self.replies.push(msg).map_err(|e| {
            tracing::error!(error = %e, "server message failed to encode");
            CloseReason::Error
        })
    }

    /// Sends the batched replies as one frame.
    fn flush(&mut self) -> Result<(), CloseReason> {
        if self.replies.is_empty() {
            return Ok(());
        }
        let frame = self.replies.finish();
        if self.out.send(Message::Binary(frame)) {
            Ok(())
        } else {
            Err(CloseReason::SlowClient)
        }
    }

    /// Sends a fatal error (after this frame's earlier replies) and ends the connection.
    fn fatal(&mut self, code: ErrorCode, detail: &str) -> Step {
        let r = self
            .reply(&fatal_error(code, detail))
            .and_then(|()| self.flush());
        Step::Close(r.err().unwrap_or(CloseReason::Fatal(code)))
    }

    /// Acts on a handshake rejection; counts it while the handshake was still open.
    fn reject(&mut self, msg: &ServerMsg, during_handshake: bool) -> Step {
        let ServerMsg::Error(e) = msg else {
            return Step::Close(CloseReason::Error);
        };
        if during_handshake {
            self.metrics()
                .count_handshake(HandshakeResult::from_error(e.code));
            tracing::info!(client = %self.client, reason = error_label(e.code), "handshake refused");
        } else {
            tracing::info!(client = %self.client, reason = error_label(e.code), "session closed by protocol error");
        }
        let r = self.reply(msg).and_then(|()| self.flush());
        Step::Close(r.err().unwrap_or(CloseReason::Fatal(e.code)))
    }

    async fn on_data(&mut self, bytes: &[u8], text: bool) -> Step {
        let before = !self.handshake.is_established();
        let decoded = if text {
            // Protocol frames are binary only (PROTOCOL.md §1).
            Err(DecodeError::EmptyFrame)
        } else {
            decode_client_frame(bytes)
        };
        let msgs = match decoded {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(client = %self.client, error = %e, "undecodable frame");
                let frame = if text { &[][..] } else { bytes };
                return match self.handshake.on_undecodable(frame, &e) {
                    Action::Reject(msg) => self.reject(&msg, before),
                    _ => Step::Close(CloseReason::Error),
                };
            }
        };
        for msg in &msgs {
            let step = self.on_message(msg).await;
            if let Step::Close(_) = step {
                return step;
            }
        }
        match self.flush() {
            Ok(()) => Step::Continue,
            Err(r) => Step::Close(r),
        }
    }

    async fn on_message(&mut self, msg: &ClientMsg) -> Step {
        let ty = protocol::frame::Message::type_id(msg);
        if let Some(i) = client_type_index(ty) {
            self.metrics().count_message_in(i);
        }
        if !self.handshake.is_established() {
            return self.on_handshake_message(msg).await;
        }
        let now = self.keepalive.now_ms();
        match self.limits.check(ty, now) {
            Verdict::Allow => {}
            Verdict::Drop => {
                if let Some(i) = client_type_index(ty) {
                    self.metrics().count_rate_limited(i);
                }
                if self.limits.notice_due(now) {
                    let notice = error_msg(ErrorCode::RateLimited, false, DETAIL_RATE_LIMITED);
                    if let Err(r) = self.reply(&notice) {
                        return Step::Close(r);
                    }
                }
                return Step::Continue;
            }
            Verdict::Disconnect => {
                if let Some(i) = client_type_index(ty) {
                    self.metrics().count_rate_limited(i);
                }
                Metrics::inc(&self.metrics().ws_rate_limit_closed);
                tracing::info!(client = %self.client, "client flooding; disconnected");
                return self.fatal(ErrorCode::RateLimited, DETAIL_FLOOD);
            }
        }
        match self.handshake.on_message(msg, |_| Err(AuthError::Invalid)) {
            Action::Forward => self.route(msg).await,
            Action::Reject(m) => self.reject(&m, false),
            Action::Reply(_) | Action::Ignore => Step::Close(CloseReason::Error),
        }
    }

    /// Before `Welcome`: `Hello` (checked and authenticated) or a refusal.
    async fn on_handshake_message(&mut self, msg: &ClientMsg) -> Step {
        let ClientMsg::Hello(hello) = msg else {
            return match self.handshake.on_message(msg, |_| Err(AuthError::Invalid)) {
                Action::Reject(m) => self.reject(&m, true),
                _ => Step::Close(CloseReason::Error),
            };
        };
        let policy = &self.state.gateway;
        self.handshake = Handshake::new(policy.for_hello(&hello.map_hash));
        // Dry run on a copy: does this Hello get as far as the token check? Only then is the
        // token verified (the database read), and the real run applies the frozen order.
        let mut needs_auth = false;
        let _ = self.handshake.clone().on_message(msg, |_| {
            needs_auth = true;
            Err(AuthError::Invalid)
        });
        let mut authed = None;
        if needs_auth {
            let token = hello.access_token.as_str();
            let now = self.state.clock.now();
            match auth::authenticate(&self.state.db, &self.state.auth, token, now, false).await {
                Ok(a) => authed = Some(a),
                Err(AuthFailure::Db(e)) => {
                    tracing::error!(error = %e, "database error during websocket authentication");
                    self.metrics().count_handshake(HandshakeResult::Internal);
                    return self.fatal(ErrorCode::Internal, DETAIL_INTERNAL);
                }
                Err(f) => {
                    // The reason only (invalid, expired, revoked, banned): never the token.
                    tracing::info!(client = %self.client, reason = %f, "websocket sign-in refused");
                    let e = f.to_handshake();
                    return match self.handshake.on_message(msg, |_| Err(e)) {
                        Action::Reject(m) => self.reject(&m, true),
                        _ => Step::Close(CloseReason::Error),
                    };
                }
            }
        }
        let result = authed
            .map(|a| AccountId(a.account_id as u64))
            .ok_or(AuthError::Invalid);
        match self.handshake.on_message(msg, |_| result) {
            Action::Reply(welcome) => {
                let Some(a) = authed else {
                    return Step::Close(CloseReason::Error);
                };
                self.establish(a, hello.client_build, &welcome)
            }
            Action::Reject(m) => self.reject(&m, true),
            _ => Step::Close(CloseReason::Error),
        }
    }

    fn establish(&mut self, a: auth::Authed, client_build: u32, welcome: &ServerMsg) -> Step {
        let sessions = &self.state.sessions;
        let account = AccountId(a.account_id as u64);
        let (handle, kick_rx) = SessionHandle::new(
            sessions.next_session_id(),
            account,
            a.token_version,
            self.out.tx.clone(),
        );
        let replaced = sessions.register(handle.clone());
        if replaced.is_none() {
            self.state.presence.on_online(account);
        }
        self.metrics().count_handshake(HandshakeResult::Ok);
        tracing::info!(
            client = %self.client,
            account = a.account_id,
            session = handle.session_id,
            client_build,
            replaced = replaced.is_some(),
            "session established"
        );
        self.session = Some(handle);
        self.kick_rx = Some(kick_rx);
        match self.reply(welcome) {
            Ok(()) => Step::Continue,
            Err(r) => Step::Close(r),
        }
    }

    /// `presence_subscribe`: `enabled` reads the account's friends (no lock held across the
    /// read), sends this frame's earlier replies, then subscribes, which queues the
    /// snapshot as its own frame (under the presence lock, so it is ordered with the pushes;
    /// see `presence.rs`). `enabled: false` ends the subscription.
    async fn presence_subscribe(&mut self, enabled: bool) -> Step {
        let Some(session) = self.session.clone() else {
            return Step::Close(CloseReason::Error);
        };
        let presence = &self.state.presence;
        if !enabled {
            presence.unsubscribe(session.account_id, session.session_id);
            return Step::Continue;
        }
        let me = session.account_id.0 as i64;
        let friends = match self.state.db.acquire().await {
            Ok(mut conn) => crate::social::friend_ids(&mut conn, me).await,
            Err(e) => Err(e),
        };
        let friends = match friends {
            Ok(f) => f.unwrap_or_default(),
            Err(e) => {
                tracing::error!(error = %e, "database error reading friends for presence");
                let notice = error_msg(ErrorCode::Internal, false, DETAIL_PRESENCE_UNAVAILABLE);
                return match self.reply(&notice) {
                    Ok(()) => Step::Continue,
                    Err(r) => Step::Close(r),
                };
            }
        };
        if let Err(r) = self.flush() {
            return Step::Close(r);
        }
        if presence.subscribe(&session, &friends) {
            Step::Continue
        } else {
            Step::Close(CloseReason::SlowClient)
        }
    }

    /// An established session's message, after its rate limit.
    async fn route(&mut self, msg: &ClientMsg) -> Step {
        let reply = match msg {
            ClientMsg::Ping(p) => {
                let Some(session) = &self.session else {
                    return Step::Close(CloseReason::Error);
                };
                Some(pong(
                    p.client_time_ms,
                    pong_clock(self.state, session).now(),
                ))
            }
            ClientMsg::LobbyCommand(LobbyCommand::PresenceSubscribe(p)) => {
                return self.presence_subscribe(p.enabled).await;
            }
            // N5 / N9: party, rooms, Quick Join, the room browser go to the lobby.
            ClientMsg::LobbyCommand(_) => {
                Some(error_msg(ErrorCode::NotAllowed, false, DETAIL_NO_LOBBY))
            }
            ClientMsg::RoomHostCommand(_) => {
                Some(error_msg(ErrorCode::NotInRoom, false, DETAIL_NOT_IN_ROOM))
            }
            // N5: room traffic goes to the session's room task. Outside a room it is dropped
            // (a client racing a leave), as the room would drop stale states.
            ClientMsg::PlayerState(_)
            | ClientMsg::ScoreClaim(_)
            | ClientMsg::HitReport(_)
            | ClientMsg::RunEvent(_)
            | ClientMsg::QuickChat(_) => None,
            ClientMsg::Hello(_) => return Step::Close(CloseReason::Error),
        };
        match reply.map(|r| self.reply(&r)) {
            Some(Err(r)) => Step::Close(r),
            _ => Step::Continue,
        }
    }

    fn on_kick(&mut self, kick: Kick) -> Step {
        let label = match kick {
            Kick::Replaced => "replaced",
            Kick::Banned => "banned",
            Kick::Revoked => "revoked",
            Kick::SlowClient => "slow_client",
            Kick::Closed => "closed",
        };
        self.metrics().count_kick(label);
        tracing::info!(
            client = %self.client,
            account = self.session.as_ref().map(|s| s.account_id.0),
            reason = label,
            "session kicked"
        );
        match kick {
            Kick::Replaced => self.fatal(ErrorCode::NotAllowed, DETAIL_REPLACED),
            Kick::Banned => self.fatal(ErrorCode::Banned, DETAIL_BANNED),
            Kick::Revoked => self.fatal(ErrorCode::AuthFailed, DETAIL_REVOKED),
            Kick::SlowClient => Step::Close(CloseReason::SlowClient),
            Kick::Closed => Step::Close(CloseReason::Shutdown),
        }
    }
}

/// Drives one `/ws` connection until it closes; returns why.
pub async fn run(socket: WebSocket, state: &AppState, client: &str) -> CloseReason {
    let metrics = state.metrics.clone();
    let (sink, mut stream) = socket.split();
    let keepalive = ServerKeepalive::new(state);
    let now = keepalive.now_ms();
    let mut conn = Conn {
        state,
        client,
        out: Outbound::spawn(sink, state),
        handshake: Handshake::new(state.gateway.handshake.clone()),
        limits: MessageLimits::new(&state.config.ws_rate_limits, now),
        keepalive,
        replies: FrameBuilder::new(),
        session: None,
        kick_rx: None,
    };
    let hello_deadline = tokio::time::sleep(state.config.hello_timeout());
    tokio::pin!(hello_deadline);

    let reason = loop {
        let established = conn.session.is_some();
        tokio::select! {
            _ = state.shutdown.cancelled() => break CloseReason::Shutdown,
            _ = conn.keepalive.check.tick() => {
                if let Err(r) = conn.keepalive.on_check(&conn.out) {
                    break r;
                }
            }
            _ = &mut hello_deadline, if !established => {
                metrics.count_handshake(HandshakeResult::HelloTimeout);
                tracing::info!(%client, "no hello in time");
                if let Step::Close(r) = conn.fatal(ErrorCode::HandshakeRequired, DETAIL_HELLO_TIMEOUT) {
                    break r;
                }
            }
            kick = wait_kick(conn.kick_rx.as_mut()), if established => {
                if let Step::Close(r) = conn.on_kick(kick) {
                    break r;
                }
            }
            _ = &mut conn.out.writer => break CloseReason::Error,
            msg = next_message(&mut stream, &metrics) => {
                let msg = match msg {
                    Ok(m) => m,
                    Err(r) => break r,
                };
                conn.keepalive.on_receive();
                let step = match &msg {
                    Message::Binary(b) => {
                        Metrics::inc(&metrics.ws_frames_in);
                        Metrics::add(&metrics.ws_bytes_in, payload_len(&msg) as u64);
                        conn.on_data(b, false).await
                    }
                    Message::Text(t) => {
                        Metrics::inc(&metrics.ws_frames_in);
                        Metrics::add(&metrics.ws_bytes_in, payload_len(&msg) as u64);
                        conn.on_data(t.as_bytes(), true).await
                    }
                    Message::Ping(_) | Message::Pong(_) => Step::Continue,
                    Message::Close(_) => Step::Close(CloseReason::ClientClosed),
                };
                if let Step::Close(r) = step {
                    break r;
                }
            }
        }
    };

    if conn.session.is_none()
        && matches!(
            reason,
            CloseReason::ClientClosed
                | CloseReason::Error
                | CloseReason::Timeout
                | CloseReason::Oversize
        )
    {
        metrics.count_handshake(HandshakeResult::Abandoned);
    }
    if reason == CloseReason::Timeout {
        Metrics::inc(&metrics.ws_timeout_closed);
    }
    if let Some(s) = conn.session.take() {
        state.presence.unsubscribe(s.account_id, s.session_id);
        if state.sessions.unregister(s.account_id, s.session_id) {
            state.presence.on_offline(s.account_id);
        }
    }
    if let CloseReason::Fatal(_) = reason {
        linger(&mut stream, state).await;
    }
    let Conn { out, .. } = conn;
    out.finish(reason, state).await
}

/// After a fatal `Error`: wait for the client to close (NetClient closes as soon as it reads
/// a fatal error), at most `gateway.fatal_close_delay_ms`, before sending our close frame.
/// A WebSocket client that receives the last data frame and the close frame in one read can
/// lose the data frame (Godot's `WebSocketPeer` goes straight to CLOSED and drops the
/// packet), and the player would see "connection closed" instead of "please update".
/// Anything the client sends meanwhile is ignored.
async fn linger(stream: &mut futures_util::stream::SplitStream<WebSocket>, state: &AppState) {
    let delay = std::time::Duration::from_millis(state.config.gateway.fatal_close_delay_ms);
    let deadline = tokio::time::sleep(delay);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            _ = &mut deadline => return,
            _ = state.shutdown.cancelled() => return,
            msg = stream.next() => match msg {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return,
                Some(Ok(_)) => {}
            },
        }
    }
}

/// The next kick on a session's signal (pending forever without a session).
async fn wait_kick(rx: Option<&mut watch::Receiver<Option<Kick>>>) -> Kick {
    let Some(rx) = rx else {
        return std::future::pending().await;
    };
    loop {
        if let Some(k) = *rx.borrow_and_update() {
            return k;
        }
        if rx.changed().await.is_err() {
            return std::future::pending().await;
        }
    }
}

/// Every `gateway.ban_recheck_ms`: re-checks each live session against the database and
/// kicks banned accounts (`banned`), and deleted accounts or revoked tokens (`auth_failed`).
/// The admin CLI runs as a separate process and writes only to the database, so a periodic
/// sweep is how its bans reach open sockets. One primary-key read per session per sweep
/// (400 sessions every 30 s ≈ 13 reads/s). Stops at shutdown.
pub async fn ban_sweep(state: AppState) {
    let period = std::time::Duration::from_millis(state.config.gateway.ban_recheck_ms);
    let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => return,
            _ = tick.tick() => {}
        }
        sweep_once(&state).await;
    }
}

/// One pass of [`ban_sweep`]; returns how many sessions were kicked.
pub async fn sweep_once(state: &AppState) -> usize {
    let now = state.clock.now();
    let mut kicked = 0;
    for s in state.sessions.snapshot() {
        let id = s.account_id.0 as i64;
        let row = sqlx::query!(
            "SELECT token_version, banned_until FROM accounts WHERE id = ?",
            id
        )
        .fetch_optional(&state.db)
        .await;
        let kick = match row {
            Err(e) => {
                tracing::warn!(error = %e, "ban re-check failed; retrying next sweep");
                return kicked;
            }
            Ok(None) => Some(Kick::Revoked),
            Ok(Some(r)) if r.token_version != s.token_version => Some(Kick::Revoked),
            Ok(Some(r)) if auth::active_ban(r.banned_until, now).is_some() => Some(Kick::Banned),
            Ok(Some(_)) => None,
        };
        if let Some(k) = kick {
            if state.sessions.kick(s.account_id, s.session_id, k) {
                kicked += 1;
            }
        }
    }
    kicked
}

/// Shared gateway state for `AppState`: the built-in map's hash is accepted unless
/// `gateway.map_hashes` lists others. Logs the map and the accepted hashes.
pub fn policy(cfg: &Config, map: &ServerMap) -> Arc<GatewayPolicy> {
    let p = GatewayPolicy::with_builtin_map(cfg, Some(map.hash));
    tracing::info!(
        map_id = %map.map.map_id,
        length_mm = map.map.length_mm(),
        sections = map.map.sections.len(),
        sectors = map.map.sector_count(),
        sha256 = %map.hash_hex,
        "loop map loaded"
    );
    let accepted: Vec<String> = p.map_hashes.iter().map(crate::map::hash_hex).collect();
    if p.hashes_from_config {
        tracing::info!(accepted = ?accepted, "gateway map hashes from gateway.map_hashes");
        if !p.map_hashes.contains(&map.hash) {
            tracing::warn!(
                builtin = %map.hash_hex,
                "gateway.map_hashes does not list the built-in map's hash: clients of this map get map_mismatch"
            );
        }
    } else {
        tracing::info!(accepted = ?accepted, "gateway map hashes: the built-in map");
    }
    if p.accept_any_map {
        tracing::warn!("gateway.map_hashes is empty in dev: every map hash is accepted");
    }
    Arc::new(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_policy() {
        let mut cfg = Config::default();
        let any = MapHash([9; 32]);
        let builtin = crate::map::builtin().expect("loop_v1").hash;
        // Production with no hashes: the built-in map only (N3.2).
        let p = GatewayPolicy::from_config(&cfg);
        assert!(!p.accepts_map(&any));
        assert_ne!(p.for_hello(&any).map_hash, any);
        assert!(p.accepts_map(&builtin));
        assert_eq!(p.for_hello(&builtin).map_hash, builtin);
        assert_eq!(p.map_hashes, vec![builtin]);
        assert_eq!(
            p.handshake.map_hash, builtin,
            "Welcome's default is the built-in map"
        );
        assert!(!p.hashes_from_config);
        // Without a built-in map, nothing.
        let p = GatewayPolicy::with_builtin_map(&cfg, None);
        assert!(!p.accepts_map(&builtin));
        // Dev with no hashes: anything, the built-in map included.
        cfg.server.env = "dev".into();
        let p = GatewayPolicy::from_config(&cfg);
        assert!(p.accepts_map(&any));
        assert!(p.accepts_map(&builtin));
        assert_eq!(p.for_hello(&any).map_hash, any);
        // A configured list wins (an explicit override), also in dev.
        cfg.gateway.map_hashes = vec!["ab".repeat(32)];
        let p = GatewayPolicy::from_config(&cfg);
        assert!(p.accepts_map(&MapHash([0xAB; 32])));
        assert!(!p.accepts_map(&any));
        assert!(
            !p.accepts_map(&builtin),
            "the override replaces the built-in hash"
        );
        assert!(p.hashes_from_config);
        assert_eq!(p.handshake.map_hash, MapHash([0xAB; 32]));
    }

    #[test]
    fn welcome_timing_comes_from_config() {
        let mut cfg = Config::default();
        cfg.limits.ping_interval_ms = 1_500;
        cfg.limits.dead_after_ms = 6_000;
        cfg.gateway.tick_rate_hz = 30;
        cfg.gateway.min_client_build = 12;
        let p = GatewayPolicy::from_config(&cfg).handshake;
        assert_eq!(
            (
                p.ping_interval_ms,
                p.timeout_ms,
                p.tick_rate_hz,
                p.min_client_build
            ),
            (1_500, 6_000, 30, 12)
        );
    }

    #[test]
    fn pong_carries_tick_and_fraction() {
        let t = crate::tick::tick_at(625_000_000, 20);
        assert_eq!(
            pong(77, t),
            ServerMsg::Pong(Pong {
                client_time_ms: 77,
                server_tick: 12,
                tick_fraction: 32_768
            })
        );
    }
}
