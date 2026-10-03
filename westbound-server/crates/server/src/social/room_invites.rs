//! Room invites (protocol 2): a player seated in a room invites an online friend or a
//! fellow crew member to it. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties and
//! matchmaking" (Private rooms: "The creator gets a code and an invite link"; Friends and
//! presence: "a blocked player ... cannot invite you"; Crews (persistent)), the owner's
//! request "invite my friends or crew into a private room in online mode". Wire:
//! docs/PROTOCOL.md §4 (`lobby_command.room_invite`, `lobby_event.room_invite`). Runbook:
//! docs/SERVER.md → "Room invites".
//!
//! The gateway checks the relationship (friend, or the same crew; no block either way) and
//! the seat; this registry holds what lives only in memory:
//! - **the rate limit** per sender: at most `social.room_invites_per_minute` invites in any
//!   rolling minute (refused ones don't count);
//! - **pending invites** (sender, target) → (room, expiry): a second invite of the same
//!   player to the same room while the first is still showing is refused, so a player can't
//!   be spammed; after `social.room_invite_ttl_secs` it may be sent again.
//!
//! Invites are not a key to the room: accepting is `room_join_code` with the code, the
//! same join anyone with the code or the link makes. Expired entries are dropped on every
//! call (the map holds at most a few minutes of invites).
//!
//! **Concurrency.** One `std::sync::Mutex`, held for the map updates only; never across an
//! `.await`. Nothing else is taken under it.

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, MutexGuard};

use protocol::{AccountId, ErrorCode};

use crate::config::Config;
use crate::rooms::Refusal;

/// `Error.detail` texts of room invites (English; clients show them as the refusal).
pub const DETAIL_NOT_SEATED: &str = "Join a room before inviting players to it.";
pub const DETAIL_SELF: &str = "You can't invite yourself.";
pub const DETAIL_NOT_RELATED: &str = "You can only invite friends and crew members.";
pub const DETAIL_OFFLINE: &str = "That player is offline.";
pub const DETAIL_OLD_CLIENT: &str = "That player's game needs an update to get room invites.";
pub const DETAIL_ALREADY_HERE: &str = "That player is already in this room.";
pub const DETAIL_ALREADY_INVITED: &str = "You already invited that player. Give them a moment.";
pub const DETAIL_TOO_MANY: &str = "Too many invites. Wait a minute and try again.";
pub const DETAIL_ROOM_FULL: &str = "Your room is full.";
pub const DETAIL_UNAVAILABLE: &str = "Invites are unavailable right now. Try again.";

/// The rolling window of the per-sender limit.
const WINDOW_SECS: i64 = 60;

/// `[social]` room-invite numbers, converted once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RoomInviteParams {
    /// How long an invite shows (and blocks a repeat to the same player and room).
    pub ttl_secs: u16,
    /// Invites one player may send in any rolling minute.
    pub per_minute: u32,
}

impl RoomInviteParams {
    pub fn from_config(cfg: &Config) -> Self {
        Self {
            ttl_secs: u16::try_from(cfg.social.room_invite_ttl_secs).unwrap_or(u16::MAX),
            per_minute: cfg.social.room_invites_per_minute,
        }
    }
}

#[derive(Default)]
struct Inner {
    /// Sender → the times (unix seconds) of their invites in the last window, oldest first.
    sent: HashMap<AccountId, VecDeque<i64>>,
    /// (sender, target) → (room, expires at).
    pending: HashMap<(AccountId, AccountId), (u32, i64)>,
}

/// The in-memory side of room invites (see the module docs).
pub struct RoomInvites {
    params: RoomInviteParams,
    inner: Mutex<Inner>,
}

impl RoomInvites {
    pub fn new(params: RoomInviteParams) -> Self {
        Self {
            params,
            inner: Mutex::new(Inner::default()),
        }
    }

    pub fn params(&self) -> RoomInviteParams {
        self.params
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // Single map operations: a poisoned lock is still consistent.
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Records an invite from `from` to `to` for `room_id` at `now` (unix seconds), or
    /// refuses it: `not_allowed` while the same invite is still showing, `rate_limited`
    /// past the per-minute limit. Refused invites are not counted.
    pub fn record(
        &self,
        from: AccountId,
        to: AccountId,
        room_id: u32,
        now: i64,
    ) -> Result<(), Refusal> {
        let mut inner = self.lock();
        inner.pending.retain(|_, (_, until)| *until > now);
        inner.sent.retain(|_, times| {
            while times.front().is_some_and(|t| now - *t >= WINDOW_SECS) {
                times.pop_front();
            }
            !times.is_empty()
        });
        if inner
            .pending
            .get(&(from, to))
            .is_some_and(|(room, _)| *room == room_id)
        {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_ALREADY_INVITED));
        }
        let times = inner.sent.entry(from).or_default();
        if times.len() >= self.params.per_minute as usize {
            return Err(Refusal::new(ErrorCode::RateLimited, DETAIL_TOO_MANY));
        }
        times.push_back(now);
        let until = now + i64::from(self.params.ttl_secs);
        inner.pending.insert((from, to), (room_id, until));
        Ok(())
    }

    /// Entries held (tests: expired ones go).
    pub fn len(&self) -> usize {
        self.lock().pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invites(per_minute: u32) -> RoomInvites {
        RoomInvites::new(RoomInviteParams {
            ttl_secs: 120,
            per_minute,
        })
    }

    #[test]
    fn a_repeat_waits_for_the_expiry_and_another_room_is_fine() {
        let r = invites(10);
        let (a, b) = (AccountId(1), AccountId(2));
        r.record(a, b, 7, 1_000).unwrap();
        let e = r.record(a, b, 7, 1_119).unwrap_err();
        assert_eq!(e.code, ErrorCode::NotAllowed);
        assert_eq!(e.detail, DETAIL_ALREADY_INVITED);
        // Another room (the sender moved) is a new invite.
        r.record(a, b, 8, 1_119).unwrap();
        // Expired: again.
        r.record(a, b, 8, 1_239).unwrap();
        // Another target, and another sender to the same target.
        r.record(a, AccountId(3), 8, 1_239).unwrap();
        r.record(AccountId(4), b, 8, 1_239).unwrap();
    }

    #[test]
    fn the_rolling_minute_limits_each_sender() {
        let r = invites(3);
        let a = AccountId(1);
        for t in 0..3 {
            r.record(a, AccountId(10 + t), 7, 1_000 + t as i64).unwrap();
        }
        let e = r.record(a, AccountId(20), 7, 1_010).unwrap_err();
        assert_eq!(e.code, ErrorCode::RateLimited);
        // Refusals don't count; another sender is not limited.
        r.record(AccountId(2), AccountId(20), 7, 1_010).unwrap();
        // A minute after the first: one slot again.
        r.record(a, AccountId(20), 7, 1_060).unwrap();
        assert_eq!(
            r.record(a, AccountId(21), 7, 1_060).unwrap_err().code,
            ErrorCode::RateLimited
        );
    }

    #[test]
    fn expired_entries_are_dropped() {
        let r = invites(10);
        r.record(AccountId(1), AccountId(2), 7, 1_000).unwrap();
        r.record(AccountId(3), AccountId(2), 7, 1_050).unwrap();
        assert_eq!(r.len(), 2);
        r.record(AccountId(5), AccountId(6), 7, 1_121).unwrap();
        assert_eq!(r.len(), 2, "the first expired");
    }
}
