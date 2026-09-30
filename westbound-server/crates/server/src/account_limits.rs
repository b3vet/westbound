//! Per-account token buckets that outlive a connection (N10.2). The per-connection limits
//! (`msg_limits.rs`) reset when a client reconnects; the few actions that cost the server
//! something lasting are limited per account here instead. Spec: WESTBOUND_MULTIPLAYER_
//! HANDOFF.md → "Accounts and authentication → Security" (rate limits per account).
//!
//! Used for `room_create` (`rooms.create_per_hour` / `create_burst`): an empty private room
//! lives 60 s, so leave-and-create in a loop could otherwise fill `limits.max_rooms`.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

use protocol::AccountId;

use crate::msg_limits::TokenBucket;

const SECS_PER_HOUR: f64 = 3_600.0;

/// Buckets keyed by account. One `std::sync::Mutex`, held for a map lookup only (a room
/// create is rare); full buckets are dropped by [`AccountBuckets::cleanup`].
#[derive(Debug)]
pub struct AccountBuckets {
    per_sec: f64,
    burst: u32,
    started: Instant,
    map: Mutex<HashMap<AccountId, TokenBucket>>,
}

impl AccountBuckets {
    pub fn per_hour(per_hour: u32, burst: u32) -> Self {
        Self {
            per_sec: f64::from(per_hour) / SECS_PER_HOUR,
            burst: burst.max(1),
            started: Instant::now(),
            map: Mutex::new(HashMap::new()),
        }
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// Takes a token for `account` at `now_ms` (milliseconds since the buckets started).
    pub fn try_take_at(&self, account: AccountId, now_ms: u64) -> bool {
        let mut map = self.map.lock().unwrap_or_else(|p| p.into_inner());
        map.entry(account)
            .or_insert_with(|| TokenBucket::new(self.per_sec, self.burst, now_ms))
            .try_take(now_ms)
    }

    /// Takes a token for `account` now.
    pub fn try_take(&self, account: AccountId) -> bool {
        self.try_take_at(account, self.now_ms())
    }

    /// Drops buckets that have refilled completely (they behave like new ones).
    pub fn cleanup_at(&self, now_ms: u64) {
        let burst = self.burst;
        self.map
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .retain(|_, b| b.available(now_ms) < burst);
    }

    pub fn cleanup(&self) {
        self.cleanup_at(self.now_ms());
    }

    /// Accounts with a bucket (tests).
    pub fn len(&self) -> usize {
        self.map.lock().unwrap_or_else(|p| p.into_inner()).len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burst_then_refill_per_account() {
        // 36 per hour = one every 100 s; burst 2.
        let b = AccountBuckets::per_hour(36, 2);
        let (a, c) = (AccountId(1), AccountId(2));
        assert!(b.try_take_at(a, 0));
        assert!(b.try_take_at(a, 0));
        assert!(!b.try_take_at(a, 1_000), "burst spent");
        assert!(
            b.try_take_at(c, 1_000),
            "another account has its own bucket"
        );
        assert!(!b.try_take_at(a, 99_000));
        assert!(b.try_take_at(a, 100_500), "one refilled after 100 s");
        assert_eq!(b.len(), 2);
        b.cleanup_at(100_500);
        assert_eq!(b.len(), 2, "neither is full yet");
        b.cleanup_at(1_000_000);
        assert!(b.is_empty(), "full buckets are dropped");
    }
}
