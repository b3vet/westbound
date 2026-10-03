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
//!    `Ping` → `Pong` with the tick clock (the room's while seated). `lobby_command.
//!    presence_subscribe` → friends presence (N9.1, `presence.rs`). Room commands
//!    (`room_create`, `room_join_code`, `room_join_id`, `quick_join`, `room_leave`,
//!    `room_browse`) → the rooms registry (N5.1, `rooms/`); a seated session's
//!    `player_state`, `run_event`, `hit_report`, `quick_chat` and `room_host_command` go to
//!    its room task through its bounded queue (`try_send`: a full queue drops, counted).
//!    Party commands go to the parties registry (N9.3, `social/parties.rs`); a party
//!    leader's join moves the party (the members' connections get a follow order and take
//!    a seat in the same room). When the connection ends, a seated player's seat is held
//!    (`rooms::RoomLink::disconnected`) and so is their party place.
//! 5. **Keepalive**: `ServerKeepalive` (protocol `Keepalive`), dead after 8 s of silence.
//! 6. **Fatal errors** are sent, then the close frame follows once the client has closed or
//!    `gateway.fatal_close_delay_ms` passed (see `linger`).
//! 7. **Presence**: a new session (not a replacement) is announced to watching friends as
//!    online, and its end as offline, after the registry changed; the session's own
//!    subscription ends with it.
//! 8. **Kicks** from outside (duplicate login, the ban sweep, a slow-client report from a
//!    room) arrive on the session's `watch` and end in a fatal `Error` + close.
//! 9. **Planned restart** (N10.2, `shutdown.rs`): a session that signs in while the server
//!    drains gets the `server_notice{restart}` with the seconds left after its `Welcome`; a
//!    `room_join_code` for a code this instance does not know recreates the room when the
//!    previous instance handed it over (`handover.rs`); at the end the socket closes with
//!    1012 behind the room's last frame. `room_create` is limited per account
//!    (`rooms.create_per_hour`, `account_limits.rs`).

use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use futures_util::StreamExt;
use protocol::handshake::{
    fatal_error, Action, AuthError, Handshake, HandshakePolicy, DETAIL_BANNED,
};
use protocol::{
    decode_client_frame, AccountId, ClientMsg, CrewTag, DecodeError, ErrorCode, ErrorMsg,
    FrameBuilder, Identity, LobbyCommand, LobbyEvent, MapHash, Pong, RoomInvite, RoomList,
    ServerMsg, Text,
};
use tokio::sync::{mpsc, watch};

use crate::app::AppState;
use crate::auth::{self, AuthFailure};
use crate::config::{parse_map_hash, Config};
use crate::map::ServerMap;
use crate::metrics::{HandshakeResult, Metrics};
use crate::msg_limits::{client_type_index, MessageLimits, Verdict};
use crate::rooms::{JoinOpts, JoinTarget, RoomLink};
use crate::sessions::{Kick, SessionHandle};
use crate::social::parties::{self, Follow};
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
pub const DETAIL_PARTIES_UNAVAILABLE: &str = "Parties are unavailable. Try again.";
pub const DETAIL_ROOMS_UNAVAILABLE: &str = "Rooms are unavailable. Try again.";
pub const DETAIL_PRESENCE_UNAVAILABLE: &str = "Friends presence is unavailable. Try again.";
pub const DETAIL_NOT_IN_ROOM: &str = "You are not in a room.";
/// N10.2: `room_create` past the per-account limit.
pub const DETAIL_CREATE_LIMITED: &str = "Too many rooms created. Try again later.";

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

/// The clock a `Pong` reports: the room's tick clock while the session is seated
/// (`server_tick` = the room tick, per PROTOCOL.md §1; tick 0 = the room's creation), else
/// the server-wide one (20 Hz since process start).
pub fn pong_clock<'a>(state: &'a AppState, room: Option<&'a RoomLink>) -> &'a dyn TickClock {
    match room {
        Some(r) if r.is_active() => r.clock(),
        _ => state.tick_clock.as_ref(),
    }
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
    /// The session's room seat (N5.1).
    room: Option<RoomLink>,
    /// N9.3: the party's follow orders for this session (the leader moved the party).
    follow_rx: Option<mpsc::Receiver<Follow>>,
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
                self.establish(a, hello.client_build, hello.protocol_version, &welcome)
            }
            Action::Reject(m) => self.reject(&m, true),
            _ => Step::Close(CloseReason::Error),
        }
    }

    fn establish(
        &mut self,
        a: auth::Authed,
        client_build: u32,
        protocol_version: u16,
        welcome: &ServerMsg,
    ) -> Step {
        let sessions = &self.state.sessions;
        let account = AccountId(a.account_id as u64);
        let (handle, kick_rx) = SessionHandle::new(
            sessions.next_session_id(),
            account,
            a.token_version,
            self.out.tx.clone(),
        );
        let handle = handle.with_protocol(protocol_version);
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
            protocol_version,
            replaced = replaced.is_some(),
            "session established"
        );
        let session_id = handle.session_id;
        self.session = Some(handle);
        self.kick_rx = Some(kick_rx);
        if let Err(r) = self.reply(welcome) {
            return Step::Close(r);
        }
        // N10.2: signed in during a planned restart's notice: the notice, with what is left.
        if let Some(left) = self.state.drain.seconds_left() {
            if let Err(r) = self.reply(&crate::shutdown::restart_notice(left)) {
                return Step::Close(r);
            }
        }
        // N9.3: the party's follow orders; a reconnect gets its party state after Welcome.
        let (rx, party) = self.state.parties.attach(session_id, account);
        self.follow_rx = Some(rx);
        match party.map(|m| self.reply(&m)) {
            Some(Err(r)) => Step::Close(r),
            _ => Step::Continue,
        }
    }

    /// N10.2: a code this instance does not know may be a room the previous instance
    /// handed over at a restart: recreate it (same code and settings) so the join finds it.
    async fn restore_handed_over(&self, target: &JoinTarget) {
        let JoinTarget::Code(code) = target else {
            return;
        };
        let rooms = &self.state.rooms;
        if rooms.is_draining() || rooms.find_code(code).is_some() {
            return;
        }
        let path = crate::handover::path_for(&self.state.config.db.path);
        let Some(settings) = crate::handover::lookup(&path, code, self.state.clock.now()).await
        else {
            return;
        };
        match rooms.restore(code.clone(), settings) {
            Ok(room) => {
                Metrics::inc(&self.metrics().rooms_restored);
                tracing::info!(room, code = %code.0, "handed-over room restored");
            }
            Err(r) => {
                tracing::info!(code = %code.0, detail = r.detail, "handed-over room not restored")
            }
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

    /// The seated room, if the room still holds the seat (a kick or a close ends it).
    fn seat(&mut self) -> Option<&RoomLink> {
        if self.room.as_ref().is_some_and(|r| !r.is_active()) {
            self.room = None;
        }
        self.room.as_ref()
    }

    /// `room_create` / `room_join_*` / `quick_join`: takes a seat through the registry.
    async fn room_join(&mut self, target: JoinTarget) -> Step {
        self.room_join_as(target, None).await
    }

    /// Takes a seat. `follow`: the party's leader moved the party there (N9.3): a seat
    /// held in another room is left first and the party rules below are skipped.
    ///
    /// **Party rules** (N9.3; docs/SERVER.md → "Parties"), in a party of two or more:
    /// - the **leader** moves the party: Quick Join needs a seat for every connected member
    ///   (and a join by code or id refuses a room without them, `room_full`); once seated,
    ///   every other connected member follows;
    /// - a **member**'s Quick Join goes to the leader's room (`not_party_leader` while the
    ///   leader has none); a member who creates or joins any other room leaves the party
    ///   and goes alone.
    ///
    /// Quick Join never picks a room with a player blocked either way with a mover.
    async fn room_join_as(&mut self, mut target: JoinTarget, follow: Option<Follow>) -> Step {
        let Some(session) = self.session.clone() else {
            return Step::Close(CloseReason::Error);
        };
        let me = session.account_id;
        if let Some(f) = follow {
            match self.seat() {
                Some(link) if link.room_id == f.room_id => return Step::Continue,
                Some(link) => {
                    link.leave().await;
                    self.room = None;
                }
                None => {}
            }
        } else if self.seat().is_some() {
            let e = error_msg(
                ErrorCode::AlreadyInRoom,
                false,
                crate::rooms::room::DETAIL_ALREADY_HERE,
            );
            return self.reply_step(&e);
        }
        if matches!(target, JoinTarget::Create(_)) && !self.state.room_creates.try_take(me) {
            Metrics::inc(&self.metrics().room_create_limited);
            let e = error_msg(ErrorCode::RateLimited, false, DETAIL_CREATE_LIMITED);
            return self.reply_step(&e);
        }
        self.restore_handed_over(&target).await;
        let rooms = self.state.rooms.clone();
        let party = self.state.parties.view(me);
        let mut opts = JoinOpts {
            party: party.as_ref().map(|p| p.id),
            movers: vec![me],
            avoid: Vec::new(),
        };
        let mut leads = false;
        if let (Some(p), None) = (&party, follow) {
            if p.is_group() && p.is_leader(me) {
                leads = true;
                opts.movers = p.connected.clone();
                if !opts.movers.contains(&me) {
                    opts.movers.push(me);
                }
            } else if p.is_group() {
                let leader_room = rooms.seat_of(p.leader);
                if target == JoinTarget::Quick {
                    match leader_room {
                        Some(r) => target = JoinTarget::Id(r),
                        None => {
                            let e = error_msg(
                                ErrorCode::NotPartyLeader,
                                false,
                                parties::DETAIL_LEADER_PICKS,
                            );
                            return self.reply_step(&e);
                        }
                    }
                } else {
                    let dest = rooms.target_room(&target);
                    let own = rooms.seat_of(me);
                    if dest.is_none() || (dest != leader_room && dest != own) {
                        // Going alone: out of the party first.
                        let _ = self.state.parties.leave(me);
                        opts.party = None;
                    }
                }
            }
        }
        let ident = match self.state.db.acquire().await {
            Ok(mut conn) => {
                let id = crate::rooms::identity_of(&mut conn, me).await;
                match (id, target == JoinTarget::Quick) {
                    (Ok(v), true) => {
                        let ids: Vec<i64> = opts.movers.iter().map(|a| a.0 as i64).collect();
                        crate::social::blocked_either(&mut conn, &ids)
                            .await
                            .map(|b| (v, b))
                    }
                    (Ok(v), false) => Ok((v, Vec::new())),
                    (Err(e), _) => Err(e),
                }
            }
            Err(e) => Err(e),
        };
        let ((identity, crew_tag), blocked) = match ident {
            Ok(v) => v,
            Err(e) => {
                tracing::error!(error = %e, "database error reading the room identity");
                let e = error_msg(ErrorCode::Internal, false, DETAIL_ROOMS_UNAVAILABLE);
                return self.reply_step(&e);
            }
        };
        opts.avoid = blocked.into_iter().map(|b| AccountId(b as u64)).collect();
        // Earlier replies of this frame go first; the room's snapshot follows on its tick.
        if let Err(r) = self.flush() {
            return Step::Close(r);
        }
        match rooms
            .join(target, &session, identity, crew_tag, &opts)
            .await
        {
            Ok(link) => {
                tracing::info!(
                    client = %self.client,
                    account = me.0,
                    room = link.room_id,
                    player = link.player_id,
                    reconnected = link.reconnected,
                    party = opts.party,
                    follow = follow.is_some(),
                    "joined room"
                );
                let room_id = link.room_id;
                self.room = Some(link);
                if leads {
                    let n = self.state.parties.follow(me, room_id);
                    tracing::info!(account = me.0, room = room_id, followers = n, "party moves");
                }
                Step::Continue
            }
            Err(refusal) => self.reply_step(&refusal.to_msg()),
        }
    }

    /// A follow order from the party (the leader took a seat): join that room, unless this
    /// session left the party meanwhile.
    async fn on_follow(&mut self, f: Follow) -> Step {
        let Some(session) = self.session.as_ref() else {
            return Step::Continue;
        };
        if self.state.parties.view(session.account_id).map(|p| p.id) != Some(f.party_id) {
            return Step::Continue;
        }
        let step = self.room_join_as(JoinTarget::Id(f.room_id), Some(f)).await;
        if let Step::Close(_) = step {
            return step;
        }
        match self.flush() {
            Ok(()) => Step::Continue,
            Err(r) => Step::Close(r),
        }
    }

    /// The account's room identity (name, tag, crew tag), or the reply that it failed.
    async fn identity(&mut self) -> Result<(Identity, CrewTag), Step> {
        let Some(session) = self.session.as_ref() else {
            return Err(Step::Close(CloseReason::Error));
        };
        let account = session.account_id;
        let ident = match self.state.db.acquire().await {
            Ok(mut conn) => crate::rooms::identity_of(&mut conn, account).await,
            Err(e) => Err(e),
        };
        match ident {
            Ok(v) => Ok(v),
            Err(e) => {
                tracing::error!(error = %e, "database error reading the party identity");
                let e = error_msg(ErrorCode::Internal, false, DETAIL_PARTIES_UNAVAILABLE);
                Err(self.reply_step(&e))
            }
        }
    }

    /// `party_create` / `party_join` / `party_invite` / `party_leave` / `party_kick`
    /// (N9.3). The state goes to the members from the parties registry; refusals are
    /// non-fatal errors. A joiner follows the leader into the leader's room.
    async fn party_command(&mut self, cmd: &LobbyCommand) -> Step {
        let Some(session) = self.session.clone() else {
            return Step::Close(CloseReason::Error);
        };
        let me = session.account_id;
        // Earlier replies of this frame go first (the party's state is sent directly).
        if let Err(r) = self.flush() {
            return Step::Close(r);
        }
        let parties = self.state.parties.clone();
        let mut follow = None;
        let result = match cmd {
            LobbyCommand::PartyCreate(_) => match self.identity().await {
                Ok((ident, _)) => parties.create(ident).map(|_| ()),
                Err(step) => return step,
            },
            LobbyCommand::PartyJoin(c) => {
                let (ident, _) = match self.identity().await {
                    Ok(v) => v,
                    Err(step) => return step,
                };
                let blocked = match self.state.db.acquire().await {
                    Ok(mut conn) => crate::social::blocked_either(&mut conn, &[me.0 as i64]).await,
                    Err(e) => Err(e),
                };
                let blocked = match blocked {
                    Ok(b) => b,
                    Err(e) => {
                        tracing::error!(error = %e, "database error reading blocks for a party");
                        let e = error_msg(ErrorCode::Internal, false, DETAIL_PARTIES_UNAVAILABLE);
                        return self.reply_step(&e);
                    }
                };
                parties.join(ident, &c.code, &blocked).map(|v| {
                    if v.leader != me {
                        follow = self.state.rooms.seat_of(v.leader).map(|room_id| Follow {
                            room_id,
                            party_id: v.id,
                        });
                    }
                })
            }
            LobbyCommand::PartyInvite(a) => {
                let target = a.account_id;
                let friends = match self.state.db.acquire().await {
                    Ok(mut conn) => crate::social::friend_ids(&mut conn, me.0 as i64).await,
                    Err(e) => Err(e),
                };
                let is_friend = match friends {
                    Ok(f) => f.unwrap_or_default().contains(&(target.0 as i64)),
                    Err(e) => {
                        tracing::error!(error = %e, "database error reading friends for an invite");
                        let e = error_msg(ErrorCode::Internal, false, DETAIL_PARTIES_UNAVAILABLE);
                        return self.reply_step(&e);
                    }
                };
                if !is_friend {
                    // Blocking removes the friendship, so a blocked player lands here too.
                    Err(crate::rooms::Refusal::new(
                        ErrorCode::NotAllowed,
                        parties::DETAIL_CANT_INVITE,
                    ))
                } else {
                    match self.identity().await {
                        Ok((ident, _)) => parties.invite(ident, target).map(|_| ()),
                        Err(step) => return step,
                    }
                }
            }
            LobbyCommand::PartyLeave(_) => parties.leave(me),
            LobbyCommand::PartyKick(a) => parties.kick(me, a.account_id),
            _ => return Step::Continue,
        };
        if let Err(refusal) = result {
            return self.reply_step(&refusal.to_msg());
        }
        match follow {
            Some(f) => self.on_follow(f).await,
            None => Step::Continue,
        }
    }

    /// `room_invite {account}` (protocol 2; docs/SERVER.md → "Room invites"): the seated
    /// player invites an online friend or crewmate to their room. The target gets
    /// `lobby_event.room_invite` on their own connection; refusals are non-fatal errors with
    /// the reason as the detail. Checked in this order, so nothing about a stranger's
    /// presence leaks: the seat, yourself, the relationship (friend or crewmate, no block
    /// either way), online (and a client that decodes the event), already in the room, the
    /// room full, then the registry (a repeat while showing, the per-minute limit).
    async fn room_invite(&mut self, target: AccountId) -> Step {
        use crate::social::room_invites as ri;
        let Some(session) = self.session.clone() else {
            return Step::Close(CloseReason::Error);
        };
        let me = session.account_id;
        let Some(room_id) = self.seat().map(|l| l.room_id) else {
            return self.reply_step(&error_msg(
                ErrorCode::NotInRoom,
                false,
                ri::DETAIL_NOT_SEATED,
            ));
        };
        let refuse = |code: ErrorCode, detail: &str| error_msg(code, false, detail);
        if target == me {
            return self.reply_step(&refuse(ErrorCode::NotAllowed, ri::DETAIL_SELF));
        }
        let related = match self.state.db.acquire().await {
            Ok(mut conn) => {
                crate::social::can_invite(&mut conn, me.0 as i64, target.0 as i64).await
            }
            Err(e) => Err(e),
        };
        match related {
            Ok(true) => {}
            Ok(false) => {
                return self.reply_step(&refuse(ErrorCode::NotAllowed, ri::DETAIL_NOT_RELATED))
            }
            Err(e) => {
                tracing::error!(error = %e, "database error checking a room invite");
                return self.reply_step(&refuse(ErrorCode::Internal, ri::DETAIL_UNAVAILABLE));
            }
        }
        let Some(to) = self.state.sessions.get(target) else {
            return self.reply_step(&refuse(ErrorCode::NotAllowed, ri::DETAIL_OFFLINE));
        };
        if !to.takes_invites() {
            return self.reply_step(&refuse(ErrorCode::NotAllowed, ri::DETAIL_OLD_CLIENT));
        }
        let Some(info) = self.state.rooms.info(room_id) else {
            return self.reply_step(&error_msg(
                ErrorCode::NotInRoom,
                false,
                ri::DETAIL_NOT_SEATED,
            ));
        };
        if self.state.rooms.seat_of(target) == Some(room_id) {
            return self.reply_step(&refuse(ErrorCode::NotAllowed, ri::DETAIL_ALREADY_HERE));
        }
        if info.players() >= info.max_players {
            return self.reply_step(&refuse(ErrorCode::RoomFull, ri::DETAIL_ROOM_FULL));
        }
        let now = self.state.clock.now();
        if let Err(r) = self.state.room_invites.record(me, target, room_id, now) {
            return self.reply_step(&r.to_msg());
        }
        let from = match self.identity().await {
            Ok((ident, _)) => ident,
            Err(step) => return step,
        };
        let msg = ServerMsg::LobbyEvent(LobbyEvent::RoomInvite(RoomInvite {
            from,
            room_id,
            code: info.code.clone(),
            visibility: info.visibility,
            players: info.players().min(protocol::messages::MAX_ROOM_PLAYERS),
            max_players: info.max_players,
            expires_in_s: self.state.room_invites.params().ttl_secs,
        }));
        match protocol::encode_frame(std::slice::from_ref(&msg)) {
            Ok(frame) => {
                to.send_frame(frame);
            }
            Err(e) => {
                tracing::error!(error = %e, "room invite failed to encode");
                return self.reply_step(&refuse(ErrorCode::Internal, ri::DETAIL_UNAVAILABLE));
            }
        }
        Metrics::inc(&self.metrics().room_invites);
        tracing::info!(
            account = me.0,
            target = target.0,
            room = room_id,
            "room invite"
        );
        Step::Continue
    }

    fn reply_step(&mut self, msg: &ServerMsg) -> Step {
        match self.reply(msg) {
            Ok(()) => Step::Continue,
            Err(r) => Step::Close(r),
        }
    }

    /// An established session's message, after its rate limit.
    async fn route(&mut self, msg: &ClientMsg) -> Step {
        let reply = match msg {
            ClientMsg::Ping(p) => {
                if self.session.is_none() {
                    return Step::Close(CloseReason::Error);
                }
                let state = self.state;
                let room = self.seat();
                Some(pong(p.client_time_ms, pong_clock(state, room).now()))
            }
            ClientMsg::LobbyCommand(cmd) => match cmd {
                LobbyCommand::PresenceSubscribe(p) => {
                    return self.presence_subscribe(p.enabled).await;
                }
                LobbyCommand::RoomCreate(s) => {
                    return self.room_join(JoinTarget::Create(s.clone())).await;
                }
                LobbyCommand::RoomJoinCode(c) => {
                    return self.room_join(JoinTarget::Code(c.code.clone())).await;
                }
                LobbyCommand::RoomJoinId(r) => {
                    return self.room_join(JoinTarget::Id(r.room_id)).await;
                }
                LobbyCommand::QuickJoin(_) => return self.room_join(JoinTarget::Quick).await,
                LobbyCommand::RoomLeave(_) => match self.seat() {
                    Some(link) => {
                        link.leave().await;
                        self.room = None;
                        None
                    }
                    None => Some(error_msg(ErrorCode::NotInRoom, false, DETAIL_NOT_IN_ROOM)),
                },
                LobbyCommand::RoomBrowse(_) => {
                    let rooms = self.state.rooms.browse();
                    Some(ServerMsg::LobbyEvent(LobbyEvent::RoomList(RoomList {
                        rooms,
                    })))
                }
                // N9.3: parties.
                LobbyCommand::PartyCreate(_)
                | LobbyCommand::PartyInvite(_)
                | LobbyCommand::PartyJoin(_)
                | LobbyCommand::PartyLeave(_)
                | LobbyCommand::PartyKick(_) => return self.party_command(cmd).await,
                // Protocol 2: invite a friend or crewmate to this room.
                LobbyCommand::RoomInvite(a) => return self.room_invite(a.account_id).await,
            },
            ClientMsg::RoomHostCommand(c) => match self.seat() {
                Some(link) => {
                    link.host(c.clone());
                    None
                }
                None => Some(error_msg(ErrorCode::NotInRoom, false, DETAIL_NOT_IN_ROOM)),
            },
            // Room traffic goes to the seat's room task. Outside a room it is dropped (a
            // client racing a leave), as the room drops stale states.
            ClientMsg::PlayerState(st) => {
                if let Some(link) = self.seat() {
                    link.state(st.clone());
                }
                None
            }
            ClientMsg::RunEvent(e) => {
                if let Some(link) = self.seat() {
                    link.run_event(e.clone());
                }
                None
            }
            ClientMsg::HitReport(h) => {
                if let Some(link) = self.seat() {
                    link.hit(h.clone());
                }
                None
            }
            ClientMsg::QuickChat(q) => {
                if let Some(link) = self.seat() {
                    link.chat(q.item.clone());
                }
                None
            }
            // N6.1: claims are verified by the room.
            ClientMsg::ScoreClaim(c) => {
                if let Some(link) = self.seat() {
                    link.claim(c.clone());
                }
                None
            }
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
        room: None,
        follow_rx: None,
    };
    let hello_deadline = tokio::time::sleep(state.config.hello_timeout());
    tokio::pin!(hello_deadline);

    let reason = loop {
        let established = conn.session.is_some();
        tokio::select! {
            _ = state.shutdown.cancelled() => break if state.drain.is_restart() {
                CloseReason::Restart
            } else {
                CloseReason::Shutdown
            },
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
            follow = wait_follow(conn.follow_rx.as_mut()), if established => {
                if let Step::Close(r) = conn.on_follow(follow).await {
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
    if let Some(link) = conn.room.take() {
        if link.is_active() {
            // Hold the seat (and the run) for the seat hold.
            link.disconnected().await;
        }
    }
    if let Some(s) = conn.session.take() {
        // N9.3: the party place is held for a while (a reconnect takes it back).
        state.parties.detach(s.session_id, s.account_id);
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

/// The next follow order of the session's party (pending forever without a session, or
/// when the parties registry dropped the channel for a newer session).
async fn wait_follow(rx: Option<&mut mpsc::Receiver<Follow>>) -> Follow {
    let Some(rx) = rx else {
        return std::future::pending().await;
    };
    match rx.recv().await {
        Some(f) => f,
        None => std::future::pending().await,
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
