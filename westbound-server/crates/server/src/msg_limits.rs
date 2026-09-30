//! Per-connection rate limits on every WebSocket message type (token buckets).
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rules for the server code" (per-connection rate
//! limits on every message type) and "Accounts and authentication → Security".
//!
//! Each client → server message type has its own bucket (`ws_rate_limits.<type>_per_sec`,
//! `_burst`). A message that finds its bucket empty is dropped before it reaches any game
//! logic. Every drop also takes a token from a shared *violation* bucket
//! (`violation_burst`, refilled at `violation_per_sec`); a client that empties it is flooding
//! and is disconnected with a fatal `rate_limited`. Owned by the connection task: no locks.
//! Time is caller-supplied monotonic milliseconds.

use protocol::type_id;

use crate::config::WsRateLimitsConfig;

const MS_PER_SEC: f64 = 1_000.0;

/// A token bucket: `burst` tokens available at once, refilled at `per_sec`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TokenBucket {
    tokens: f64,
    burst: f64,
    per_ms: f64,
    last_ms: u64,
}

impl TokenBucket {
    /// Starts full at `now_ms`.
    pub fn new(per_sec: f64, burst: u32, now_ms: u64) -> Self {
        let burst = f64::from(burst.max(1));
        Self {
            tokens: burst,
            burst,
            per_ms: per_sec.max(0.0) / MS_PER_SEC,
            last_ms: now_ms,
        }
    }

    fn refill(&mut self, now_ms: u64) {
        let dt = now_ms.saturating_sub(self.last_ms);
        self.last_ms = self.last_ms.max(now_ms);
        self.tokens = (self.tokens + dt as f64 * self.per_ms).min(self.burst);
    }

    /// Takes one token if there is one.
    pub fn try_take(&mut self, now_ms: u64) -> bool {
        self.refill(now_ms);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }

    /// Whole tokens left at `now_ms`.
    pub fn available(&mut self, now_ms: u64) -> u32 {
        self.refill(now_ms);
        self.tokens as u32
    }
}

/// Client → server message types (`0x01..=0x09`), by index `type_id - 1`.
pub const CLIENT_TYPES: usize = 9;
/// Snake-case names by index (metrics labels, logs).
pub const CLIENT_TYPE_NAMES: [&str; CLIENT_TYPES] = [
    "hello",
    "ping",
    "lobby_command",
    "player_state",
    "score_claim",
    "hit_report",
    "run_event",
    "quick_chat",
    "room_host_command",
];

/// Index of a client message type id, if it is one.
pub fn client_type_index(type_id: u8) -> Option<usize> {
    let i = usize::from(type_id).checked_sub(usize::from(type_id::HELLO))?;
    (i < CLIENT_TYPES).then_some(i)
}

/// What to do with one inbound message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    /// Drop it (and maybe tell the client, see `notice_due`).
    Drop,
    /// The client keeps flooding: close with a fatal `rate_limited`.
    Disconnect,
}

/// One connection's buckets.
#[derive(Debug, Clone)]
pub struct MessageLimits {
    enabled: bool,
    buckets: [TokenBucket; CLIENT_TYPES],
    violations: TokenBucket,
    notice_interval_ms: u64,
    last_notice_ms: Option<u64>,
}

impl MessageLimits {
    pub fn new(cfg: &WsRateLimitsConfig, now_ms: u64) -> Self {
        let b = |per_sec: f64, burst: u32| TokenBucket::new(per_sec, burst, now_ms);
        Self {
            enabled: cfg.enabled,
            buckets: [
                // `hello` is handled by the handshake (a second one is fatal): never limited.
                b(0.0, 1),
                b(cfg.ping_per_sec, cfg.ping_burst),
                b(cfg.lobby_command_per_sec, cfg.lobby_command_burst),
                b(cfg.player_state_per_sec, cfg.player_state_burst),
                b(cfg.score_claim_per_sec, cfg.score_claim_burst),
                b(cfg.hit_report_per_sec, cfg.hit_report_burst),
                b(cfg.run_event_per_sec, cfg.run_event_burst),
                b(cfg.quick_chat_per_sec, cfg.quick_chat_burst),
                b(cfg.room_host_command_per_sec, cfg.room_host_command_burst),
            ],
            violations: b(cfg.violation_per_sec, cfg.violation_burst),
            notice_interval_ms: cfg.notice_interval_ms,
            last_notice_ms: None,
        }
    }

    /// Checks one message of type `type_id`.
    pub fn check(&mut self, type_id: u8, now_ms: u64) -> Verdict {
        if !self.enabled || type_id == protocol::type_id::HELLO {
            return Verdict::Allow;
        }
        let Some(i) = client_type_index(type_id) else {
            return Verdict::Allow;
        };
        if self.buckets[i].try_take(now_ms) {
            Verdict::Allow
        } else if self.violations.try_take(now_ms) {
            Verdict::Drop
        } else {
            Verdict::Disconnect
        }
    }

    /// After a drop: true at most once per `notice_interval_ms`, when the client should get
    /// a non-fatal `rate_limited` error.
    pub fn notice_due(&mut self, now_ms: u64) -> bool {
        let due = self
            .last_notice_ms
            .is_none_or(|t| now_ms.saturating_sub(t) >= self.notice_interval_ms);
        if due {
            self.last_notice_ms = Some(now_ms);
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_burst_then_refill() {
        let mut b = TokenBucket::new(2.0, 3, 1_000);
        assert!(b.try_take(1_000));
        assert!(b.try_take(1_000));
        assert!(b.try_take(1_000));
        assert!(!b.try_take(1_000));
        // 2 per second: one token every 500 ms.
        assert!(!b.try_take(1_499));
        assert!(b.try_take(1_500));
        assert!(!b.try_take(1_500));
        // Never above the burst.
        assert_eq!(b.available(100_000), 3);
        // Time going backward refills nothing.
        let mut b = TokenBucket::new(1.0, 1, 5_000);
        assert!(b.try_take(5_000));
        assert!(!b.try_take(1_000));
        assert!(!b.try_take(5_999));
        assert!(b.try_take(6_000));
    }

    #[test]
    fn type_indices() {
        assert_eq!(client_type_index(type_id::HELLO), Some(0));
        assert_eq!(client_type_index(type_id::ROOM_HOST_COMMAND), Some(8));
        assert_eq!(CLIENT_TYPE_NAMES[3], "player_state");
        assert_eq!(client_type_index(0), None);
        assert_eq!(client_type_index(type_id::WELCOME), None);
    }

    /// N10.2 rate-limit review: every client type has its own bucket with the configured
    /// burst and rate (the production defaults, docs/SERVER.md → "Rate limits: every route
    /// and message type").
    #[test]
    fn every_type_has_its_configured_bucket() {
        let cfg = WsRateLimitsConfig {
            violation_burst: 10_000,
            ..WsRateLimitsConfig::default()
        };
        let types: Vec<_> = cfg
            .entries()
            .into_iter()
            .filter(|(name, _, _)| *name != "violation")
            .collect();
        assert_eq!(types.len(), CLIENT_TYPES - 1, "every type but hello");
        for (name, per_sec, burst) in types {
            let i = CLIENT_TYPE_NAMES
                .iter()
                .position(|n| *n == name)
                .unwrap_or_else(|| panic!("{name} is a client type"));
            let tid = type_id::HELLO + u8::try_from(i).unwrap();
            let mut l = MessageLimits::new(&cfg, 0);
            for k in 0..burst {
                assert_eq!(l.check(tid, 0), Verdict::Allow, "{name} #{k}");
            }
            assert_eq!(l.check(tid, 0), Verdict::Drop, "{name} past its burst");
            // Other types are untouched by this one's flood.
            for other in type_id::PING..=type_id::ROOM_HOST_COMMAND {
                if other != tid {
                    assert_eq!(l.check(other, 0), Verdict::Allow, "{name} vs {other}");
                }
            }
            // One token back after 1 / rate seconds.
            let refill_ms = (1_000.0 / per_sec).ceil() as u64;
            assert_eq!(l.check(tid, refill_ms), Verdict::Allow, "{name} refilled");
            assert_eq!(
                l.check(tid, refill_ms),
                Verdict::Drop,
                "{name} one at a time"
            );
        }
    }

    #[test]
    fn drops_then_disconnects() {
        let cfg = WsRateLimitsConfig {
            ping_per_sec: 1.0,
            ping_burst: 2,
            violation_per_sec: 1.0,
            violation_burst: 3,
            notice_interval_ms: 1_000,
            ..WsRateLimitsConfig::default()
        };
        let mut l = MessageLimits::new(&cfg, 0);
        assert_eq!(l.check(type_id::PING, 0), Verdict::Allow);
        assert_eq!(l.check(type_id::PING, 0), Verdict::Allow);
        assert_eq!(l.check(type_id::PING, 0), Verdict::Drop);
        assert!(l.notice_due(0));
        assert_eq!(l.check(type_id::PING, 0), Verdict::Drop);
        assert!(!l.notice_due(10));
        // Other types have their own buckets.
        assert_eq!(l.check(type_id::PLAYER_STATE, 0), Verdict::Allow);
        assert_eq!(l.check(type_id::HELLO, 0), Verdict::Allow);
        assert_eq!(l.check(type_id::PING, 0), Verdict::Drop);
        assert_eq!(l.check(type_id::PING, 0), Verdict::Disconnect);
        assert!(l.notice_due(1_000));
        // Disabled: everything passes.
        let mut off = MessageLimits::new(
            &WsRateLimitsConfig {
                enabled: false,
                ..cfg
            },
            0,
        );
        for _ in 0..100 {
            assert_eq!(off.check(type_id::PING, 0), Verdict::Allow);
        }
    }
}
