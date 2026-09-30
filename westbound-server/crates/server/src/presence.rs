//! Friends presence: who of an account's friends is online, and in which room. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties and matchmaking → Friends and
//! presence" (the friends list shows who is online, and a Join button when a friend is in a
//! room with space), "Data model" (presence lives only in memory). Wire: docs/PROTOCOL.md §4
//! (`lobby_command.presence_subscribe`, `lobby_event.presence`).
//!
//! **Source of truth.** Online means the account has a live session in the gateway's
//! registry ([`Sessions`]). The room comes from [`PresenceHub::set_room`], the **N5 seam**:
//! room tasks call it when a player joins or leaves a room (with whether the room still has
//! space), and it reaches subscribers at once. Until N5 nobody calls it, so friends are
//! `online` or `offline`.
//!
//! **Subscriptions.** A session subscribes over the WebSocket (`presence_subscribe`
//! `enabled: true`): the gateway reads its accepted friends from the database (no lock
//! held), then [`PresenceHub::subscribe`] registers them and sends the snapshot. Changes are
//! pushed as they happen: a friend's session starts or ends ([`PresenceHub::on_online`] /
//! [`PresenceHub::on_offline`], called by the gateway), a friend's room changes, a
//! friendship is accepted or removed (the friends routes), an account is deleted. A
//! subscription ends with `enabled: false` or with its session.
//!
//! **Concurrency** (the registry's design, `sessions.rs`). One `std::sync::Mutex` over the
//! maps below, held for map updates, the few lookups a change needs and non-blocking
//! `try_send`s into the subscribers' bounded outbound queues; never across an `.await`, and
//! never per game message. A full queue kicks that client (slow client) instead of blocking.
//! Lock order: this lock, then the session registry's; the registry never takes this one.
//! Sending under the lock keeps every subscriber's view in the order the changes happened.
//!
//! **Bounds.** A subscriber watches at most `social.max_friends` accounts; a snapshot is
//! split into `presence` messages of at most `MAX_PRESENCE_BATCH` (128) friends.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

use axum::body::Bytes;
use protocol::{
    AccountId, FrameBuilder, FriendPresence, LobbyEvent, PresenceStatus, ServerMsg,
    MAX_PRESENCE_BATCH,
};

use crate::sessions::{SessionHandle, Sessions};

/// Where a player is, as a room task reports it (N5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RoomPresence {
    pub room_id: u32,
    /// The room has space for one more player (the friend's Join button).
    pub joinable: bool,
}

struct Subscription {
    handle: SessionHandle,
    friends: HashSet<AccountId>,
}

#[derive(Default)]
struct Inner {
    /// Subscriber → its session and the friends it watches.
    subs: HashMap<AccountId, Subscription>,
    /// Account → the subscribers watching it (the reverse of `subs[..].friends`).
    watchers: HashMap<AccountId, HashSet<AccountId>>,
    /// N5: the room each player is in.
    rooms: HashMap<AccountId, RoomPresence>,
}

impl Inner {
    fn unwatch(&mut self, subscriber: AccountId, friend: AccountId) {
        if let Some(w) = self.watchers.get_mut(&friend) {
            w.remove(&subscriber);
            if w.is_empty() {
                self.watchers.remove(&friend);
            }
        }
    }

    fn remove_sub(&mut self, subscriber: AccountId) {
        if let Some(sub) = self.subs.remove(&subscriber) {
            for f in sub.friends {
                self.unwatch(subscriber, f);
            }
        }
    }
}

/// The presence registry (`AppState.presence`).
pub struct PresenceHub {
    inner: Mutex<Inner>,
    sessions: Arc<Sessions>,
}

impl std::fmt::Debug for PresenceHub {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PresenceHub").finish_non_exhaustive()
    }
}

/// `status` of a presence entry as the HTTP API spells it.
pub fn status_str(s: PresenceStatus) -> &'static str {
    match s {
        PresenceStatus::Offline => "offline",
        PresenceStatus::Online => "online",
        PresenceStatus::InRoom => "in_room",
    }
}

fn offline(id: AccountId) -> FriendPresence {
    FriendPresence {
        account_id: id,
        status: PresenceStatus::Offline,
        room_id: 0,
        joinable: false,
    }
}

/// Encodes entries as `lobby_event.presence` messages of at most `MAX_PRESENCE_BATCH`
/// friends, packed into as few frames as fit. An empty list is one empty message (the
/// snapshot of an account without friends).
fn frames(entries: &[FriendPresence]) -> Vec<Bytes> {
    let mut out = Vec::new();
    let mut fb = FrameBuilder::new();
    let chunks: Vec<&[FriendPresence]> = if entries.is_empty() {
        vec![&[]]
    } else {
        entries.chunks(usize::from(MAX_PRESENCE_BATCH)).collect()
    };
    for chunk in chunks {
        let msg = ServerMsg::LobbyEvent(LobbyEvent::Presence(protocol::Presence {
            friends: chunk.to_vec(),
        }));
        if fb.push(&msg).is_err() {
            if !fb.is_empty() {
                out.push(fb.finish());
            }
            if let Err(e) = fb.push(&msg) {
                tracing::error!(error = %e, "presence message failed to encode");
                continue;
            }
        }
    }
    if !fb.is_empty() {
        out.push(fb.finish());
    }
    out
}

impl PresenceHub {
    pub fn new(sessions: Arc<Sessions>) -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
            sessions,
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // Single map operations per step: a poisoned lock is still consistent enough.
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// One account's presence (called with the lock held: lock order hub → registry).
    fn entry(&self, inner: &Inner, id: AccountId) -> FriendPresence {
        if self.sessions.get(id).is_none() {
            return offline(id);
        }
        match inner.rooms.get(&id) {
            Some(r) => FriendPresence {
                account_id: id,
                status: PresenceStatus::InRoom,
                room_id: r.room_id,
                joinable: r.joinable,
            },
            None => FriendPresence {
                account_id: id,
                status: PresenceStatus::Online,
                room_id: 0,
                joinable: false,
            },
        }
    }

    /// The presence of each account (HTTP `GET /presence` and the friends list).
    pub fn statuses(&self, ids: &[i64]) -> Vec<FriendPresence> {
        let inner = self.lock();
        ids.iter()
            .map(|&id| self.entry(&inner, AccountId(id as u64)))
            .collect()
    }

    /// Subscribes `handle`'s account to its `friends` (replacing an earlier subscription of
    /// the account) and sends the snapshot on its queue. Returns false if the snapshot could
    /// not be queued (a full queue kicks the client).
    pub fn subscribe(&self, handle: &SessionHandle, friends: &[i64]) -> bool {
        let me = handle.account_id;
        let mut inner = self.lock();
        inner.remove_sub(me);
        let set: HashSet<AccountId> = friends
            .iter()
            .map(|&f| AccountId(f as u64))
            .filter(|&f| f != me)
            .collect();
        for &f in &set {
            inner.watchers.entry(f).or_default().insert(me);
        }
        let mut ids: Vec<AccountId> = set.iter().copied().collect();
        ids.sort_unstable_by_key(|a| a.0);
        inner.subs.insert(
            me,
            Subscription {
                handle: handle.clone(),
                friends: set,
            },
        );
        let entries: Vec<FriendPresence> = ids.iter().map(|&f| self.entry(&inner, f)).collect();
        frames(&entries).into_iter().all(|f| handle.send_frame(f))
    }

    /// Ends the account's subscription if it belongs to `session_id` (a replaced session's
    /// cleanup must not end its successor's). Returns whether one ended.
    pub fn unsubscribe(&self, account: AccountId, session_id: u64) -> bool {
        let mut inner = self.lock();
        match inner.subs.get(&account) {
            Some(s) if s.handle.session_id == session_id => {
                inner.remove_sub(account);
                true
            }
            _ => false,
        }
    }

    /// Whether the account has a live subscription (tests, metrics).
    pub fn is_subscribed(&self, account: AccountId) -> bool {
        self.lock().subs.contains_key(&account)
    }

    /// Pushes `account`'s current presence to everyone watching it.
    fn notify(&self, inner: &Inner, account: AccountId) {
        let Some(watchers) = inner.watchers.get(&account) else {
            return;
        };
        let entry = self.entry(inner, account);
        for frame in frames(&[entry]) {
            for w in watchers {
                if let Some(sub) = inner.subs.get(w) {
                    sub.handle.send_frame(frame.clone());
                }
            }
        }
    }

    /// A session started for `account` (the gateway, after registering a new session; not
    /// for a session that replaced another: the account never went offline).
    pub fn on_online(&self, account: AccountId) {
        let inner = self.lock();
        self.notify(&inner, account);
    }

    /// The account's session ended (the gateway, after removing it from the registry).
    pub fn on_offline(&self, account: AccountId) {
        let inner = self.lock();
        self.notify(&inner, account);
    }

    /// **N5 seam:** the player joined a room (`Some`, also when the room's space changes)
    /// or left it (`None`). Pushed to the player's watching friends.
    pub fn set_room(&self, account: AccountId, room: Option<RoomPresence>) {
        let mut inner = self.lock();
        let changed = match room {
            Some(r) => inner.rooms.insert(account, r) != Some(r),
            None => inner.rooms.remove(&account).is_some(),
        };
        if changed {
            self.notify(&inner, account);
        }
    }

    /// The room the player is in (N5 sets it).
    pub fn room_of(&self, account: AccountId) -> Option<RoomPresence> {
        self.lock().rooms.get(&account).copied()
    }

    /// `a` and `b` became friends: each one subscribed starts watching the other and gets
    /// their presence.
    pub fn friendship_added(&self, a: i64, b: i64) {
        let (a, b) = (AccountId(a as u64), AccountId(b as u64));
        let mut inner = self.lock();
        for (x, y) in [(a, b), (b, a)] {
            let Some(sub) = inner.subs.get_mut(&x) else {
                continue;
            };
            if !sub.friends.insert(y) {
                continue;
            }
            inner.watchers.entry(y).or_default().insert(x);
            let entry = self.entry(&inner, y);
            if let Some(sub) = inner.subs.get(&x) {
                for f in frames(&[entry]) {
                    sub.handle.send_frame(f);
                }
            }
        }
    }

    /// `a` and `b` are no longer friends (removed, or one blocked the other): each one
    /// subscribed stops watching the other and sees them `offline`.
    pub fn friendship_removed(&self, a: i64, b: i64) {
        let (a, b) = (AccountId(a as u64), AccountId(b as u64));
        let mut inner = self.lock();
        for (x, y) in [(a, b), (b, a)] {
            Self::drop_friend(&mut inner, x, y);
        }
    }

    fn drop_friend(inner: &mut Inner, subscriber: AccountId, friend: AccountId) {
        let Some(sub) = inner.subs.get_mut(&subscriber) else {
            return;
        };
        if !sub.friends.remove(&friend) {
            return;
        }
        for f in frames(&[offline(friend)]) {
            sub.handle.send_frame(f);
        }
        inner.unwatch(subscriber, friend);
    }

    /// The account was deleted: its subscription and room go, and its friends see it
    /// `offline` and stop watching it.
    pub fn forget_account(&self, account: i64) {
        let account = AccountId(account as u64);
        let mut inner = self.lock();
        inner.remove_sub(account);
        inner.rooms.remove(&account);
        let watchers: Vec<AccountId> = inner
            .watchers
            .get(&account)
            .map(|w| w.iter().copied().collect())
            .unwrap_or_default();
        for w in watchers {
            Self::drop_friend(&mut inner, w, account);
        }
        inner.watchers.remove(&account);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::Metrics;
    use axum::extract::ws::Message;
    use protocol::decode_server_frame;
    use tokio::sync::mpsc;

    fn session(s: &Sessions, account: u64) -> (SessionHandle, mpsc::Receiver<Message>) {
        let (tx, rx) = mpsc::channel(16);
        let (h, _kick) = SessionHandle::new(s.next_session_id(), AccountId(account), 0, tx);
        (h, rx)
    }

    fn drain(rx: &mut mpsc::Receiver<Message>) -> Vec<FriendPresence> {
        let mut out = Vec::new();
        while let Ok(Message::Binary(b)) = rx.try_recv() {
            for m in decode_server_frame(&b).unwrap() {
                let ServerMsg::LobbyEvent(LobbyEvent::Presence(p)) = m else {
                    panic!("expected presence, got {m:?}");
                };
                out.extend(p.friends);
            }
        }
        out
    }

    #[test]
    fn snapshot_pushes_rooms_and_removal() {
        let sessions = Arc::new(Sessions::new(Arc::new(Metrics::default())));
        let hub = PresenceHub::new(sessions.clone());
        let (a, mut a_rx) = session(&sessions, 1);
        sessions.register(a.clone());
        assert!(hub.subscribe(&a, &[2, 3, 1]));
        let snap = drain(&mut a_rx);
        assert_eq!(snap, vec![offline(AccountId(2)), offline(AccountId(3))]);
        // Friend 2 comes online, joins a room, leaves.
        let (b, _b_rx) = session(&sessions, 2);
        sessions.register(b.clone());
        hub.on_online(AccountId(2));
        assert_eq!(drain(&mut a_rx)[0].status, PresenceStatus::Online);
        hub.set_room(
            AccountId(2),
            Some(RoomPresence {
                room_id: 9,
                joinable: true,
            }),
        );
        let e = drain(&mut a_rx);
        assert_eq!(
            (e[0].status, e[0].room_id, e[0].joinable),
            (PresenceStatus::InRoom, 9, true)
        );
        // The same room again is not a change.
        hub.set_room(
            AccountId(2),
            Some(RoomPresence {
                room_id: 9,
                joinable: true,
            }),
        );
        assert!(drain(&mut a_rx).is_empty());
        sessions.unregister(AccountId(2), b.session_id);
        hub.on_offline(AccountId(2));
        assert_eq!(drain(&mut a_rx), vec![offline(AccountId(2))]);
        // Removal: an offline entry, then nothing more about 3.
        hub.friendship_removed(1, 3);
        assert_eq!(drain(&mut a_rx), vec![offline(AccountId(3))]);
        hub.on_online(AccountId(3));
        assert!(drain(&mut a_rx).is_empty());
        // A new friendship is watched at once.
        hub.friendship_added(3, 1);
        assert_eq!(drain(&mut a_rx), vec![offline(AccountId(3))]);
        // Unsubscribe with a stale session id does nothing; with the right one it ends.
        assert!(!hub.unsubscribe(AccountId(1), a.session_id + 1));
        assert!(hub.unsubscribe(AccountId(1), a.session_id));
        hub.on_online(AccountId(2));
        assert!(drain(&mut a_rx).is_empty());
        assert!(hub.lock().watchers.is_empty());
    }

    #[test]
    fn big_snapshots_are_split() {
        let sessions = Arc::new(Sessions::new(Arc::new(Metrics::default())));
        let hub = PresenceHub::new(sessions.clone());
        let (a, mut rx) = session(&sessions, 1);
        let friends: Vec<i64> = (2..302).collect();
        assert!(hub.subscribe(&a, &friends));
        let mut sizes = Vec::new();
        while let Ok(Message::Binary(b)) = rx.try_recv() {
            for m in decode_server_frame(&b).unwrap() {
                if let ServerMsg::LobbyEvent(LobbyEvent::Presence(p)) = m {
                    sizes.push(p.friends.len());
                }
            }
        }
        assert_eq!(sizes, vec![128, 128, 44]);
        // No friends: one empty snapshot.
        let (c, mut c_rx) = session(&sessions, 500);
        assert!(hub.subscribe(&c, &[]));
        let Ok(Message::Binary(b)) = c_rx.try_recv() else {
            panic!("an empty snapshot");
        };
        assert_eq!(
            decode_server_frame(&b).unwrap(),
            vec![ServerMsg::LobbyEvent(LobbyEvent::Presence(
                protocol::Presence { friends: vec![] }
            ))]
        );
        hub.forget_account(1);
        assert!(!hub.is_subscribed(AccountId(1)));
        assert!(hub.lock().watchers.is_empty());
    }
}
