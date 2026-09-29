//! Connection handshake and keepalive (multiplayer handoff → Networking protocol → Connection):
//! `Hello {protocol_version, client_build, map_hash, access_token}` → `Welcome` or a fatal
//! `Error`. Pure: no I/O, no clocks. The gateway feeds it decoded messages (or the raw frame
//! when decoding failed) plus a token verifier, and acts on the returned `Action`.
//!
//! Checks, in order (the first failure wins):
//! 1. protocol version below the supported range → `update_required`;
//!    above it → `server_outdated`
//! 2. `client_build` below `min_client_build` → `update_required`
//! 3. `map_hash` differs from the server's map → `map_mismatch`
//! 4. token verification fails → `auth_failed` (or `banned`)
//!
//! Any message before `Hello` → `handshake_required`; a second `Hello` or an undecodable frame
//! → `malformed`. All handshake errors are fatal.

use crate::error::DecodeError;
use crate::messages::{type_id, ClientMsg, ErrorMsg, Hello, ServerMsg, Welcome};
use crate::types::{AccountId, ErrorCode, MapHash, Text};
use crate::{MAX_FRAME_LEN, MIN_SUPPORTED_PROTOCOL_VERSION, PROTOCOL_VERSION};

/// Spec defaults (multiplayer handoff → Tuning reference); the server config may override.
pub const DEFAULT_TICK_RATE_HZ: u8 = 20;
pub const DEFAULT_PING_INTERVAL_MS: u16 = 2_000;
pub const DEFAULT_TIMEOUT_MS: u16 = 8_000;

/// What the server accepts and announces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandshakePolicy {
    pub min_protocol_version: u16,
    pub max_protocol_version: u16,
    pub min_client_build: u32,
    pub map_hash: MapHash,
    pub server_build: u32,
    pub tick_rate_hz: u8,
    pub ping_interval_ms: u16,
    pub timeout_ms: u16,
}

impl HandshakePolicy {
    /// This build's protocol range, spec timing defaults, every client build accepted.
    pub fn new(map_hash: MapHash, server_build: u32) -> Self {
        Self {
            min_protocol_version: MIN_SUPPORTED_PROTOCOL_VERSION,
            max_protocol_version: PROTOCOL_VERSION,
            min_client_build: 0,
            map_hash,
            server_build,
            tick_rate_hz: DEFAULT_TICK_RATE_HZ,
            ping_interval_ms: DEFAULT_PING_INTERVAL_MS,
            timeout_ms: DEFAULT_TIMEOUT_MS,
        }
    }
}

/// Protocol version compatibility.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionCheck {
    Compatible,
    /// The client must update ("please update").
    ClientTooOld,
    /// The client is ahead of the server (store release before server deploy): retry later.
    ClientTooNew,
}

pub fn check_version(client_version: u16, policy: &HandshakePolicy) -> VersionCheck {
    if client_version < policy.min_protocol_version {
        VersionCheck::ClientTooOld
    } else if client_version > policy.max_protocol_version {
        VersionCheck::ClientTooNew
    } else {
        VersionCheck::Compatible
    }
}

/// Reads the protocol version from a frame whose first message is a `Hello`, without decoding
/// the rest. `Hello`'s first two payload bytes are frozen as the version, so a server can
/// answer "please update" even when a newer or older `Hello` no longer decodes.
pub fn peek_hello_version(frame: &[u8]) -> Option<u16> {
    match frame {
        [ty, _, _, lo, hi, ..] if *ty == type_id::HELLO => Some(u16::from_le_bytes([*lo, *hi])),
        _ => None,
    }
}

/// Token verification failure reported by the server's verifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthError {
    /// Missing, malformed, expired or badly signed token.
    Invalid,
    /// The account is banned.
    Banned,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HandshakeState {
    AwaitingHello,
    Established {
        account_id: AccountId,
        protocol_version: u16,
        client_build: u32,
    },
    Closed,
}

/// What the gateway should do next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Send this message (the `Welcome`); the connection is established.
    Reply(ServerMsg),
    /// Send this fatal `Error`, then close.
    Reject(ServerMsg),
    /// Established: hand the message to the lobby / room.
    Forward,
    /// The connection is closed; drop the message.
    Ignore,
}

/// Per-connection handshake state machine.
#[derive(Debug, Clone)]
pub struct Handshake {
    policy: HandshakePolicy,
    state: HandshakeState,
}

/// Human-readable details (English; clients localize by `ErrorCode`).
pub const DETAIL_UPDATE: &str = "Please update Westbound to play online.";
pub const DETAIL_SERVER_OUTDATED: &str = "The server is being updated. Try again in a few minutes.";
pub const DETAIL_MAP: &str = "Your map data is out of date. Please update Westbound.";
pub const DETAIL_AUTH: &str = "Sign-in failed. Please try again.";
pub const DETAIL_BANNED: &str = "This account is banned from online play.";
pub const DETAIL_HELLO_FIRST: &str = "Hello must be the first message.";
pub const DETAIL_MALFORMED: &str = "Malformed message.";

/// A fatal `Error` message.
pub fn fatal_error(code: ErrorCode, detail: &str) -> ServerMsg {
    ServerMsg::Error(ErrorMsg {
        code,
        fatal: true,
        detail: Text(detail.to_owned()),
    })
}

impl Handshake {
    pub fn new(policy: HandshakePolicy) -> Self {
        Self {
            policy,
            state: HandshakeState::AwaitingHello,
        }
    }

    pub fn state(&self) -> &HandshakeState {
        &self.state
    }

    pub fn policy(&self) -> &HandshakePolicy {
        &self.policy
    }

    pub fn is_established(&self) -> bool {
        matches!(self.state, HandshakeState::Established { .. })
    }

    fn reject(&mut self, code: ErrorCode, detail: &str) -> Action {
        self.state = HandshakeState::Closed;
        Action::Reject(fatal_error(code, detail))
    }

    fn version_reject(&mut self, version: u16) -> Option<Action> {
        match check_version(version, &self.policy) {
            VersionCheck::Compatible => None,
            VersionCheck::ClientTooOld => {
                Some(self.reject(ErrorCode::UpdateRequired, DETAIL_UPDATE))
            }
            VersionCheck::ClientTooNew => {
                Some(self.reject(ErrorCode::ServerOutdated, DETAIL_SERVER_OUTDATED))
            }
        }
    }

    /// Handles a decoded message. `authenticate` is only called for an otherwise acceptable
    /// `Hello`.
    pub fn on_message(
        &mut self,
        msg: &ClientMsg,
        authenticate: impl FnOnce(&str) -> Result<AccountId, AuthError>,
    ) -> Action {
        match (&self.state, msg) {
            (HandshakeState::Closed, _) => Action::Ignore,
            (HandshakeState::AwaitingHello, ClientMsg::Hello(hello)) => {
                self.on_hello(hello, authenticate)
            }
            (HandshakeState::AwaitingHello, _) => {
                self.reject(ErrorCode::HandshakeRequired, DETAIL_HELLO_FIRST)
            }
            (HandshakeState::Established { .. }, ClientMsg::Hello(_)) => {
                self.reject(ErrorCode::Malformed, DETAIL_MALFORMED)
            }
            (HandshakeState::Established { .. }, _) => Action::Forward,
        }
    }

    /// Handles a frame that failed to decode. Before the handshake, a `Hello` with an
    /// incompatible version still gets the version error.
    pub fn on_undecodable(&mut self, frame: &[u8], _err: &DecodeError) -> Action {
        match self.state {
            HandshakeState::Closed => Action::Ignore,
            HandshakeState::AwaitingHello => {
                if let Some(action) = peek_hello_version(frame).and_then(|v| self.version_reject(v))
                {
                    return action;
                }
                self.reject(ErrorCode::Malformed, DETAIL_MALFORMED)
            }
            HandshakeState::Established { .. } => {
                self.reject(ErrorCode::Malformed, DETAIL_MALFORMED)
            }
        }
    }

    fn on_hello(
        &mut self,
        hello: &Hello,
        authenticate: impl FnOnce(&str) -> Result<AccountId, AuthError>,
    ) -> Action {
        if let Some(action) = self.version_reject(hello.protocol_version) {
            return action;
        }
        if hello.client_build < self.policy.min_client_build {
            return self.reject(ErrorCode::UpdateRequired, DETAIL_UPDATE);
        }
        if hello.map_hash != self.policy.map_hash {
            return self.reject(ErrorCode::MapMismatch, DETAIL_MAP);
        }
        if hello.access_token.as_str().is_empty() {
            return self.reject(ErrorCode::AuthFailed, DETAIL_AUTH);
        }
        match authenticate(hello.access_token.as_str()) {
            Ok(account_id) => {
                self.state = HandshakeState::Established {
                    account_id,
                    protocol_version: hello.protocol_version,
                    client_build: hello.client_build,
                };
                Action::Reply(ServerMsg::Welcome(Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    server_build: self.policy.server_build,
                    account_id,
                    tick_rate_hz: self.policy.tick_rate_hz,
                    ping_interval_ms: self.policy.ping_interval_ms,
                    timeout_ms: self.policy.timeout_ms,
                    max_frame_bytes: u16::try_from(MAX_FRAME_LEN).unwrap_or(u16::MAX),
                }))
            }
            Err(AuthError::Invalid) => self.reject(ErrorCode::AuthFailed, DETAIL_AUTH),
            Err(AuthError::Banned) => self.reject(ErrorCode::Banned, DETAIL_BANNED),
        }
    }
}

/// Keepalive timer for either side: ping every `ping_interval_ms`, dead after `timeout_ms`
/// without receiving anything. Times are caller-supplied monotonic milliseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Keepalive {
    ping_interval_ms: u64,
    timeout_ms: u64,
    last_heard_ms: u64,
    last_ping_ms: u64,
}

impl Keepalive {
    pub fn new(now_ms: u64, ping_interval_ms: u16, timeout_ms: u16) -> Self {
        Self {
            ping_interval_ms: u64::from(ping_interval_ms),
            timeout_ms: u64::from(timeout_ms),
            last_heard_ms: now_ms,
            last_ping_ms: now_ms,
        }
    }

    /// Anything arrived from the peer.
    pub fn on_receive(&mut self, now_ms: u64) {
        self.last_heard_ms = self.last_heard_ms.max(now_ms);
    }

    /// A ping should be sent now.
    pub fn ping_due(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.last_ping_ms) >= self.ping_interval_ms
    }

    pub fn on_ping_sent(&mut self, now_ms: u64) {
        self.last_ping_ms = now_ms;
    }

    /// The peer has been silent for at least `timeout_ms`.
    pub fn is_dead(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.last_heard_ms) >= self.timeout_ms
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::encode_frame;
    use crate::messages::{Ping, PlayerState};
    use crate::types::AccessToken;

    const MAP: MapHash = MapHash([7; 32]);

    fn hello(version: u16, build: u32, map: MapHash, token: &str) -> ClientMsg {
        ClientMsg::Hello(Hello {
            protocol_version: version,
            client_build: build,
            map_hash: map,
            access_token: AccessToken(token.to_owned()),
        })
    }

    fn ok_auth(_: &str) -> Result<AccountId, AuthError> {
        Ok(AccountId(42))
    }

    fn error_code(a: &Action) -> Option<ErrorCode> {
        match a {
            Action::Reject(ServerMsg::Error(e)) if e.fatal => Some(e.code),
            _ => None,
        }
    }

    #[test]
    fn valid_hello_gets_welcome() {
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 9));
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 100, MAP, "tok"), ok_auth);
        let Action::Reply(ServerMsg::Welcome(w)) = a else {
            panic!("expected welcome, got {a:?}")
        };
        assert_eq!(w.account_id, AccountId(42));
        assert_eq!(w.protocol_version, PROTOCOL_VERSION);
        assert_eq!(w.server_build, 9);
        assert_eq!(w.tick_rate_hz, 20);
        assert_eq!(w.ping_interval_ms, 2000);
        assert_eq!(w.timeout_ms, 8000);
        assert_eq!(usize::from(w.max_frame_bytes), MAX_FRAME_LEN);
        assert!(hs.is_established());
        let ping = ClientMsg::Ping(Ping { client_time_ms: 1 });
        assert_eq!(hs.on_message(&ping, ok_auth), Action::Forward);
    }

    #[test]
    fn old_protocol_gets_update_required() {
        let mut policy = HandshakePolicy::new(MAP, 1);
        policy.min_protocol_version = 5;
        policy.max_protocol_version = 6;
        let mut hs = Handshake::new(policy.clone());
        assert_eq!(
            error_code(&hs.on_message(&hello(4, 1, MAP, "t"), ok_auth)),
            Some(ErrorCode::UpdateRequired)
        );
        assert_eq!(hs.state(), &HandshakeState::Closed);
        let mut hs = Handshake::new(policy);
        assert_eq!(
            error_code(&hs.on_message(&hello(7, 1, MAP, "t"), ok_auth)),
            Some(ErrorCode::ServerOutdated)
        );
    }

    #[test]
    fn old_build_gets_update_required() {
        let mut policy = HandshakePolicy::new(MAP, 1);
        policy.min_client_build = 200;
        let mut hs = Handshake::new(policy);
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 199, MAP, "t"), ok_auth);
        assert_eq!(error_code(&a), Some(ErrorCode::UpdateRequired));
    }

    #[test]
    fn map_mismatch_is_refused_before_auth() {
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 1, MapHash([8; 32]), "t"), |_| {
            panic!("auth must not run")
        });
        assert_eq!(error_code(&a), Some(ErrorCode::MapMismatch));
    }

    #[test]
    fn auth_failures() {
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 1, MAP, ""), ok_auth);
        assert_eq!(error_code(&a), Some(ErrorCode::AuthFailed));
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 1, MAP, "x"), |_| {
            Err(AuthError::Invalid)
        });
        assert_eq!(error_code(&a), Some(ErrorCode::AuthFailed));
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 1, MAP, "x"), |_| {
            Err(AuthError::Banned)
        });
        assert_eq!(error_code(&a), Some(ErrorCode::Banned));
    }

    #[test]
    fn message_before_hello_and_second_hello_are_rejected() {
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        let a = hs.on_message(&ClientMsg::PlayerState(PlayerState::default()), ok_auth);
        assert_eq!(error_code(&a), Some(ErrorCode::HandshakeRequired));
        assert_eq!(
            hs.on_message(&hello(PROTOCOL_VERSION, 1, MAP, "t"), ok_auth),
            Action::Ignore
        );

        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        hs.on_message(&hello(PROTOCOL_VERSION, 1, MAP, "t"), ok_auth);
        let a = hs.on_message(&hello(PROTOCOL_VERSION, 1, MAP, "t"), ok_auth);
        assert_eq!(error_code(&a), Some(ErrorCode::Malformed));
    }

    #[test]
    fn undecodable_future_hello_still_gets_version_error() {
        // A Hello from a newer protocol with an extra trailing field does not decode here,
        // but its frozen version prefix still yields a clear answer.
        let mut frame = encode_frame(&[hello(PROTOCOL_VERSION + 1, 1, MAP, "t")])
            .unwrap()
            .to_vec();
        frame.push(0xEE);
        frame[1] += 1;
        let err = crate::frame::decode_client_frame(&frame).unwrap_err();
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        assert_eq!(
            error_code(&hs.on_undecodable(&frame, &err)),
            Some(ErrorCode::ServerOutdated)
        );
        let mut hs = Handshake::new(HandshakePolicy::new(MAP, 1));
        assert_eq!(
            error_code(&hs.on_undecodable(&[0xFF], &err)),
            Some(ErrorCode::Malformed)
        );
        assert_eq!(peek_hello_version(&frame), Some(PROTOCOL_VERSION + 1));
        assert_eq!(peek_hello_version(&[type_id::PING, 0, 0, 1, 0]), None);
    }

    #[test]
    fn keepalive_timing() {
        let mut k = Keepalive::new(1_000, DEFAULT_PING_INTERVAL_MS, DEFAULT_TIMEOUT_MS);
        assert!(!k.ping_due(2_999));
        assert!(k.ping_due(3_000));
        k.on_ping_sent(3_000);
        assert!(!k.ping_due(4_000));
        assert!(!k.is_dead(8_999));
        assert!(k.is_dead(9_000));
        k.on_receive(8_500);
        assert!(!k.is_dead(9_000));
        assert!(k.is_dead(16_500));
        k.on_receive(100); // clocks never move backward
        assert!(k.is_dead(16_500));
    }
}
