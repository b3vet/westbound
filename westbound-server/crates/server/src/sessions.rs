//! The live-session registry: account id → the connection that account is signed in on.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Architecture" (one WebSocket per client, the
//! lobby talks to connections), "Rules for the server code" (one owner per room, bounded
//! everything, no shared locks in the hot path).
//!
//! **Concurrency design.**
//! - Each connection task owns its socket, handshake, rate limiters and keepalive outright.
//!   Nothing else touches them.
//! - The only shared structure is this map, behind one `std::sync::Mutex`. It is held for a
//!   hash-map insert, remove, lookup or snapshot, never across an `.await`, and only on
//!   session start and end, lobby lookups and the periodic ban sweep: never per message.
//! - What others get is a [`SessionHandle`] (cheap to clone): the connection's **bounded**
//!   outbound queue (the same 64-frame queue the writer drains) and a kick signal. The lobby
//!   (N9) and room tasks (N5) keep handles and push frames with `try_send`; a full queue
//!   disconnects that client instead of blocking the sender (`SessionHandle::send_frame`).
//! - A kick is a `watch` value, so it never blocks and never fails; the connection task sends
//!   the fatal `Error`, closes, and removes itself from the map.
//!
//! **One session per account.** A second login of the same account replaces the first: the
//! newer connection is registered and the older one is kicked with a fatal `not_allowed`
//! ("signed in on another device"). The newest device wins, so a player whose old
//! connection is half-dead (phone switched networks) is never locked out by it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use axum::body::Bytes;
use axum::extract::ws::Message;
use protocol::AccountId;
use tokio::sync::{mpsc, watch};

use crate::metrics::Metrics;

/// Why a live session is being ended from outside its connection task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kick {
    /// The same account signed in on another connection.
    Replaced,
    /// An admin ban (seen by the periodic re-check).
    Banned,
    /// The account was deleted or its tokens revoked (logout everywhere).
    Revoked,
    /// The outbound queue was full when someone else pushed a frame.
    SlowClient,
    /// Server shutdown or an operator action.
    Closed,
}

/// Another task's way to reach one connection.
#[derive(Debug, Clone)]
pub struct SessionHandle {
    pub session_id: u64,
    pub account_id: AccountId,
    /// `accounts.token_version` of the token the session signed in with.
    pub token_version: i64,
    outbound: mpsc::Sender<Message>,
    kick: Arc<watch::Sender<Option<Kick>>>,
}

impl SessionHandle {
    /// A handle and the receiving end of its kick signal (kept by the connection task).
    pub fn new(
        session_id: u64,
        account_id: AccountId,
        token_version: i64,
        outbound: mpsc::Sender<Message>,
    ) -> (Self, watch::Receiver<Option<Kick>>) {
        let (kick, kick_rx) = watch::channel(None);
        (
            Self {
                session_id,
                account_id,
                token_version,
                outbound,
                kick: Arc::new(kick),
            },
            kick_rx,
        )
    }

    /// Queues one binary frame without waiting. A full queue kicks the client
    /// (`Kick::SlowClient`) and returns false, as does a closed connection.
    pub fn send_frame(&self, frame: Bytes) -> bool {
        match self.outbound.try_send(Message::Binary(frame)) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.kick(Kick::SlowClient);
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    /// Ends the session. The first kick wins; later ones are ignored.
    pub fn kick(&self, why: Kick) {
        self.kick.send_if_modified(|k| {
            if k.is_none() {
                *k = Some(why);
                true
            } else {
                false
            }
        });
    }

    pub fn is_closed(&self) -> bool {
        self.outbound.is_closed()
    }
}

/// account id → live session. See the module docs for the locking rules.
#[derive(Debug)]
pub struct Sessions {
    map: Mutex<HashMap<AccountId, SessionHandle>>,
    next_id: AtomicU64,
    metrics: Arc<Metrics>,
}

impl Sessions {
    pub fn new(metrics: Arc<Metrics>) -> Self {
        Self {
            map: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            metrics,
        }
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<AccountId, SessionHandle>> {
        // A panic while holding this lock cannot leave the map half-updated (single
        // HashMap calls), so a poisoned lock is still consistent.
        self.map.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// A fresh session id (never reused within the process).
    pub fn next_session_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Registers `handle` for its account. An older session of the same account is kicked
    /// (`Kick::Replaced`) and returned.
    pub fn register(&self, handle: SessionHandle) -> Option<SessionHandle> {
        let old = self.lock().insert(handle.account_id, handle);
        match &old {
            Some(o) => {
                Metrics::inc(&self.metrics.ws_sessions_replaced);
                o.kick(Kick::Replaced);
            }
            None => {
                self.metrics.ws_sessions.fetch_add(1, Ordering::Relaxed);
            }
        }
        old
    }

    /// Removes the account's session if it is still `session_id` (a replaced session must
    /// not remove its successor). Returns true if it was removed.
    pub fn unregister(&self, account_id: AccountId, session_id: u64) -> bool {
        let mut map = self.lock();
        if map.get(&account_id).map(|h| h.session_id) == Some(session_id) {
            map.remove(&account_id);
            drop(map);
            self.metrics.ws_sessions.fetch_sub(1, Ordering::Relaxed);
            true
        } else {
            false
        }
    }

    /// The account's live session (lobby: invites, presence, joins).
    pub fn get(&self, account_id: AccountId) -> Option<SessionHandle> {
        self.lock().get(&account_id).cloned()
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Every live session (the ban sweep; not for per-tick use).
    pub fn snapshot(&self) -> Vec<SessionHandle> {
        self.lock().values().cloned().collect()
    }

    /// Kicks the account's session if it is still `session_id`.
    pub fn kick(&self, account_id: AccountId, session_id: u64, why: Kick) -> bool {
        match self.get(account_id) {
            Some(h) if h.session_id == session_id => {
                h.kick(why);
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn handle(
        s: &Sessions,
        account: u64,
    ) -> (
        SessionHandle,
        watch::Receiver<Option<Kick>>,
        mpsc::Receiver<Message>,
    ) {
        let (tx, rx) = mpsc::channel(2);
        let (h, k) = SessionHandle::new(s.next_session_id(), AccountId(account), 0, tx);
        (h, k, rx)
    }

    #[test]
    fn second_login_replaces_and_kicks_the_first() {
        let m = Arc::new(Metrics::default());
        let s = Sessions::new(m.clone());
        let (a, a_kick, _a_rx) = handle(&s, 7);
        let (b, b_kick, _b_rx) = handle(&s, 7);
        assert!(s.register(a.clone()).is_none());
        assert_eq!(Metrics::get(&m.ws_sessions), 1);
        let old = s.register(b.clone()).expect("replaced");
        assert_eq!(old.session_id, a.session_id);
        assert_eq!(*a_kick.borrow(), Some(Kick::Replaced));
        assert_eq!(*b_kick.borrow(), None);
        assert_eq!(Metrics::get(&m.ws_sessions), 1);
        assert_eq!(Metrics::get(&m.ws_sessions_replaced), 1);
        // The old connection's cleanup must not remove the new session.
        assert!(!s.unregister(AccountId(7), a.session_id));
        assert_eq!(s.get(AccountId(7)).unwrap().session_id, b.session_id);
        assert!(s.unregister(AccountId(7), b.session_id));
        assert!(s.is_empty());
        assert_eq!(Metrics::get(&m.ws_sessions), 0);
    }

    #[test]
    fn full_queue_kicks_slow_client_and_first_kick_wins() {
        let s = Sessions::new(Arc::new(Metrics::default()));
        let (h, kick, _rx) = handle(&s, 1);
        assert!(h.send_frame(Bytes::from_static(b"a")));
        assert!(h.send_frame(Bytes::from_static(b"b")));
        assert!(!h.send_frame(Bytes::from_static(b"c")));
        assert_eq!(*kick.borrow(), Some(Kick::SlowClient));
        h.kick(Kick::Banned);
        assert_eq!(*kick.borrow(), Some(Kick::SlowClient));
    }

    #[test]
    fn kick_by_id_only_hits_the_named_session() {
        let s = Sessions::new(Arc::new(Metrics::default()));
        let (h, kick, _rx) = handle(&s, 3);
        s.register(h.clone());
        assert!(!s.kick(AccountId(3), h.session_id + 100, Kick::Banned));
        assert_eq!(*kick.borrow(), None);
        assert!(s.kick(AccountId(3), h.session_id, Kick::Banned));
        assert_eq!(*kick.borrow(), Some(Kick::Banned));
        assert_eq!(s.snapshot().len(), 1);
    }
}
