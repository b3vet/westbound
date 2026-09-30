//! Parties (WP N9.3): a small group that moves between rooms together and is each other's
//! crew in public rooms. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties and
//! matchmaking → Parties" ("Up to 8 players, led by one player. The leader invites online
//! friends, or shares a party code. The party moves between rooms together, and its members
//! are each other's crew in public rooms"), "Friends and presence" (a blocked player cannot
//! invite you), "Data model" (parties live only in memory). Wire: docs/PROTOCOL.md §4
//! (`party_*` lobby commands, `lobby_event.party_state` / `party_left` / `party_invite`).
//! Runbook: docs/SERVER.md → "Parties (N9.3)".
//!
//! **State.** One `std::sync::Mutex` over the parties, their codes, account → party, and
//! each connected account's *follow* channel (how the party moves: the leader's connection
//! asks every other member's connection to take a seat in the room it just joined). The lock
//! is held for map updates and non-blocking `try_send`s into the members' bounded outbound
//! queues (`SessionHandle::send_frame`: a full queue kicks that client); never across an
//! `.await`, never per game message. Lock order: this lock, then the session registry's
//! (the registry never takes this one; the presence hub and the rooms registry are never
//! taken under it).
//!
//! **Rules** (the gateway applies the database checks: friendship, blocks):
//! - `party_create`: a new party with you as leader (you leave any party you were in).
//! - `party_join {code}`: joins (also how an invite is accepted); `party_full`,
//!   `party_not_found`, `blocked` (you and a member blocked each other). You leave any
//!   other party first.
//! - `party_invite {account}`: the leader invites an online friend (without a party, one
//!   is made for you); the friend gets `lobby_event.party_invite {from, code}`. Declining
//!   needs no message (PROTOCOL.md §12).
//! - `party_leave`: `party_left {left}` to you; the leader's role passes to the
//!   longest-present member. An empty party closes (its code stops working).
//! - `party_kick {account}` (leader only): `party_left {kicked}` to them.
//! - Every change sends `party_state` (code, leader, members in join order) to every
//!   connected member.
//! - **Connections.** A member whose connection ends keeps their place for
//!   `social.party_member_hold_ms` (a new session takes it back and gets the state at once);
//!   after that they leave as if they had left.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use axum::body::Bytes;
use protocol::{
    AccountId, Code, ErrorCode, Identity, LobbyEvent, PartyInvite, PartyLeft, PartyLeftReason,
    PartyState, ServerMsg,
};
use tokio::sync::mpsc;

use crate::config::Config;
use crate::rooms::Refusal;
use crate::sessions::Sessions;

/// `Error.detail` texts of the parties (English; clients localize by code).
pub const DETAIL_PARTY_NOT_FOUND: &str = "No party with that code.";
pub const DETAIL_PARTY_FULL: &str = "That party is full.";
pub const DETAIL_NOT_LEADER: &str = "Only the party leader can do that.";
pub const DETAIL_LEADER_PICKS: &str = "Your party leader picks the room.";
pub const DETAIL_NOT_IN_PARTY: &str = "You are not in a party.";
pub const DETAIL_BLOCKED: &str = "You can't join this party.";
pub const DETAIL_CANT_INVITE: &str = "Only friends who are online can be invited.";
pub const DETAIL_ALREADY_MEMBER: &str = "That player is already in your party.";
pub const DETAIL_KICK_SELF: &str = "Leave the party instead.";
pub const DETAIL_NOT_MEMBER: &str = "That player is not in your party.";
pub const DETAIL_PARTY_TOO_BIG: &str = "That room can't fit your whole party.";

/// Follow orders a connection may have waiting (a newer one replaces nothing: the gateway
/// takes the latest room each time it wakes).
const FOLLOW_QUEUE: usize = 4;

/// `[social]` party numbers, converted once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PartyParams {
    pub max_members: usize,
    pub member_hold: Duration,
}

impl PartyParams {
    pub fn from_config(cfg: &Config) -> Self {
        Self {
            max_members: cfg.social.party_max_members as usize,
            member_hold: Duration::from_millis(cfg.social.party_member_hold_ms),
        }
    }
}

/// A follow order: the member's connection takes a seat in `room_id` (the leader's new
/// room), as part of party `party_id`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Follow {
    pub room_id: u32,
    pub party_id: u32,
}

/// What the gateway and the rooms need to know about an account's party.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PartyView {
    pub id: u32,
    pub code: Code,
    pub leader: AccountId,
    /// Every member, in join order (the leader included).
    pub members: Vec<AccountId>,
    /// Members with a live connection (the ones that move with the party).
    pub connected: Vec<AccountId>,
}

impl PartyView {
    pub fn is_leader(&self, account: AccountId) -> bool {
        self.leader == account
    }

    /// More than one member: the party rules for rooms apply.
    pub fn is_group(&self) -> bool {
        self.members.len() > 1
    }
}

struct Member {
    identity: Identity,
    connected: bool,
    /// Bumped at every disconnect and reconnect: a hold timer only removes the member when
    /// nothing happened since it started.
    generation: u64,
}

struct Party {
    id: u32,
    code: Code,
    leader: AccountId,
    members: Vec<Member>,
}

impl Party {
    fn account(m: &Member) -> AccountId {
        m.identity.account_id
    }

    fn index(&self, account: AccountId) -> Option<usize> {
        self.members
            .iter()
            .position(|m| Self::account(m) == account)
    }

    fn view(&self) -> PartyView {
        PartyView {
            id: self.id,
            code: self.code.clone(),
            leader: self.leader,
            members: self.members.iter().map(Self::account).collect(),
            connected: self
                .members
                .iter()
                .filter(|m| m.connected)
                .map(Self::account)
                .collect(),
        }
    }

    fn state_msg(&self) -> ServerMsg {
        ServerMsg::LobbyEvent(LobbyEvent::PartyState(PartyState {
            code: self.code.clone(),
            leader: self.leader,
            members: self.members.iter().map(|m| m.identity.clone()).collect(),
        }))
    }
}

#[derive(Default)]
struct Inner {
    parties: HashMap<u32, Party>,
    codes: HashMap<Code, u32>,
    of: HashMap<AccountId, u32>,
    /// Account → (session id, the connection's follow channel).
    follow: HashMap<AccountId, (u64, mpsc::Sender<Follow>)>,
}

/// Is a code taken outside the parties (a live room's code)?
pub type CodeTaken = Arc<dyn Fn(&Code) -> bool + Send + Sync>;

/// The parties registry (`AppState.parties`).
pub struct Parties {
    inner: Mutex<Inner>,
    sessions: Arc<Sessions>,
    params: PartyParams,
    next_id: AtomicU32,
    next_generation: AtomicU64,
    code_taken: CodeTaken,
}

impl std::fmt::Debug for Parties {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Parties")
            .field("parties", &self.count())
            .finish_non_exhaustive()
    }
}

fn encode(msg: &ServerMsg) -> Option<Bytes> {
    match protocol::encode_frame(std::slice::from_ref(msg)) {
        Ok(f) => Some(f),
        Err(e) => {
            tracing::error!(error = %e, "party message failed to encode");
            None
        }
    }
}

fn left_msg(reason: PartyLeftReason) -> ServerMsg {
    ServerMsg::LobbyEvent(LobbyEvent::PartyLeft(PartyLeft { reason }))
}

impl Parties {
    /// `code_taken` keeps party codes apart from live room codes (an invite link carries
    /// either).
    pub fn new(sessions: Arc<Sessions>, params: PartyParams, code_taken: CodeTaken) -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
            sessions,
            params,
            next_id: AtomicU32::new(1),
            next_generation: AtomicU64::new(1),
            code_taken,
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // Single map operations under the lock: a poisoned lock is still consistent.
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn params(&self) -> PartyParams {
        self.params
    }

    /// Live parties.
    pub fn count(&self) -> usize {
        self.lock().parties.len()
    }

    /// The account's party.
    pub fn view(&self, account: AccountId) -> Option<PartyView> {
        let inner = self.lock();
        let id = inner.of.get(&account)?;
        inner.parties.get(id).map(Party::view)
    }

    /// The party with this code.
    pub fn find_code(&self, code: &Code) -> Option<PartyView> {
        let inner = self.lock();
        let id = inner.codes.get(code)?;
        inner.parties.get(id).map(Party::view)
    }

    fn send(&self, account: AccountId, frame: &Bytes) {
        if let Some(h) = self.sessions.get(account) {
            h.send_frame(frame.clone());
        }
    }

    /// `party_state` to every connected member of party `id`.
    fn broadcast(&self, inner: &Inner, id: u32) {
        let Some(p) = inner.parties.get(&id) else {
            return;
        };
        let Some(frame) = encode(&p.state_msg()) else {
            return;
        };
        for m in p.members.iter().filter(|m| m.connected) {
            self.send(Party::account(m), &frame);
        }
    }

    fn fresh_generation(&self) -> u64 {
        self.next_generation.fetch_add(1, Ordering::Relaxed)
    }

    // ------------------------------------------------------------ Connections

    /// A session started: its follow channel, and the party state when the account is in
    /// a party (a reconnect takes its place back). The gateway sends the state right after
    /// `Welcome`, in the same frame.
    pub fn attach(
        &self,
        session_id: u64,
        account: AccountId,
    ) -> (mpsc::Receiver<Follow>, Option<ServerMsg>) {
        let (tx, rx) = mpsc::channel(FOLLOW_QUEUE);
        let generation = self.fresh_generation();
        let mut inner = self.lock();
        inner.follow.insert(account, (session_id, tx));
        let mut state = None;
        if let Some(&id) = inner.of.get(&account) {
            if let Some(p) = inner.parties.get_mut(&id) {
                if let Some(i) = p.index(account) {
                    p.members[i].connected = true;
                    p.members[i].generation = generation;
                }
                state = Some(p.state_msg());
            }
        }
        (rx, state)
    }

    /// A session ended. Its party place is held for `member_hold` (a newer session of the
    /// same account that already attached keeps everything as it is).
    pub fn detach(self: &Arc<Self>, session_id: u64, account: AccountId) {
        let generation = self.fresh_generation();
        {
            let mut inner = self.lock();
            match inner.follow.get(&account) {
                Some((s, _)) if *s == session_id => {
                    inner.follow.remove(&account);
                }
                _ => return,
            }
            let Some(&id) = inner.of.get(&account) else {
                return;
            };
            let Some(p) = inner.parties.get_mut(&id) else {
                return;
            };
            let Some(i) = p.index(account) else {
                return;
            };
            p.members[i].connected = false;
            p.members[i].generation = generation;
        }
        let me = self.clone();
        let hold = self.params.member_hold;
        tokio::spawn(async move {
            tokio::time::sleep(hold).await;
            me.expire(account, generation);
        });
    }

    /// The hold ran out: the member leaves unless they came back (or left) meanwhile.
    pub fn expire(&self, account: AccountId, generation: u64) -> bool {
        let mut inner = self.lock();
        let Some(&id) = inner.of.get(&account) else {
            return false;
        };
        let held = inner
            .parties
            .get(&id)
            .and_then(|p| p.index(account).map(|i| &p.members[i]))
            .is_some_and(|m| !m.connected && m.generation == generation);
        if !held {
            return false;
        }
        tracing::info!(
            account = account.0,
            party = id,
            "party place held too long; left"
        );
        self.remove(&mut inner, account, None);
        true
    }

    // ------------------------------------------------------------ Commands

    /// `party_create`: a new party led by `me` (leaving any party first).
    pub fn create(&self, me: Identity) -> Result<PartyView, Refusal> {
        let account = me.account_id;
        let mut inner = self.lock();
        if let Some(&old) = inner.of.get(&account) {
            if inner
                .parties
                .get(&old)
                .is_some_and(|p| p.members.len() == 1)
            {
                // Already alone in a party: it is the party (a double tap).
                self.broadcast(&inner, old);
                return Ok(inner.parties[&old].view());
            }
            self.remove(&mut inner, account, Some(PartyLeftReason::Left));
        }
        let id = loop {
            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            if id != 0 && !inner.parties.contains_key(&id) {
                break id;
            }
        };
        let code = loop {
            let c = Code(super::crews::new_invite_code(
                protocol::types::CODE_LEN as u32,
            ));
            if !inner.codes.contains_key(&c) && !(self.code_taken)(&c) {
                break c;
            }
        };
        let connected = inner.follow.contains_key(&account);
        inner.parties.insert(
            id,
            Party {
                id,
                code: code.clone(),
                leader: account,
                members: vec![Member {
                    identity: me,
                    connected,
                    generation: self.fresh_generation(),
                }],
            },
        );
        inner.codes.insert(code.clone(), id);
        inner.of.insert(account, id);
        tracing::info!(account = account.0, party = id, code = %code.0, "party created");
        self.broadcast(&inner, id);
        Ok(inner.parties[&id].view())
    }

    /// `party_join {code}`: `blocked` holds the accounts `me` blocked or was blocked by.
    pub fn join(&self, me: Identity, code: &Code, blocked: &[i64]) -> Result<PartyView, Refusal> {
        let account = me.account_id;
        let mut inner = self.lock();
        let Some(&id) = inner.codes.get(code) else {
            return Err(Refusal::new(
                ErrorCode::PartyNotFound,
                DETAIL_PARTY_NOT_FOUND,
            ));
        };
        let party = &inner.parties[&id];
        if party.index(account).is_some() {
            // Already a member: the state again.
            self.broadcast(&inner, id);
            return Ok(inner.parties[&id].view());
        }
        if party
            .members
            .iter()
            .any(|m| blocked.contains(&(Party::account(m).0 as i64)))
        {
            return Err(Refusal::new(ErrorCode::Blocked, DETAIL_BLOCKED));
        }
        if party.members.len() >= self.params.max_members {
            return Err(Refusal::new(ErrorCode::PartyFull, DETAIL_PARTY_FULL));
        }
        if inner.of.contains_key(&account) {
            self.remove(&mut inner, account, Some(PartyLeftReason::Left));
        }
        let connected = inner.follow.contains_key(&account);
        let generation = self.fresh_generation();
        let Some(p) = inner.parties.get_mut(&id) else {
            return Err(Refusal::new(
                ErrorCode::PartyNotFound,
                DETAIL_PARTY_NOT_FOUND,
            ));
        };
        p.members.push(Member {
            identity: me,
            connected,
            generation,
        });
        inner.of.insert(account, id);
        tracing::info!(account = account.0, party = id, "party joined");
        self.broadcast(&inner, id);
        Ok(inner.parties[&id].view())
    }

    /// `party_leave`.
    pub fn leave(&self, account: AccountId) -> Result<(), Refusal> {
        let mut inner = self.lock();
        if !inner.of.contains_key(&account) {
            return Err(Refusal::new(ErrorCode::PartyNotFound, DETAIL_NOT_IN_PARTY));
        }
        self.remove(&mut inner, account, Some(PartyLeftReason::Left));
        Ok(())
    }

    /// `party_kick {target}` (leader only).
    pub fn kick(&self, me: AccountId, target: AccountId) -> Result<(), Refusal> {
        let mut inner = self.lock();
        let Some(&id) = inner.of.get(&me) else {
            return Err(Refusal::new(ErrorCode::PartyNotFound, DETAIL_NOT_IN_PARTY));
        };
        let p = &inner.parties[&id];
        if p.leader != me {
            return Err(Refusal::new(ErrorCode::NotPartyLeader, DETAIL_NOT_LEADER));
        }
        if target == me {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_KICK_SELF));
        }
        if p.index(target).is_none() {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_NOT_MEMBER));
        }
        tracing::info!(account = target.0, party = id, "party kick");
        self.remove(&mut inner, target, Some(PartyLeftReason::Kicked));
        Ok(())
    }

    /// `party_invite {target}`: the gateway checked that `target` is `me`'s friend and
    /// online. Without a party one is made (its state goes to `me` first). Returns the
    /// party.
    pub fn invite(&self, me: Identity, target: AccountId) -> Result<PartyView, Refusal> {
        let account = me.account_id;
        if target == account {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_CANT_INVITE));
        }
        if self.sessions.get(target).is_none() {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_CANT_INVITE));
        }
        let has_party = self.lock().of.contains_key(&account);
        if !has_party {
            self.create(me.clone())?;
        }
        let inner = self.lock();
        let Some(&id) = inner.of.get(&account) else {
            return Err(Refusal::new(ErrorCode::PartyNotFound, DETAIL_NOT_IN_PARTY));
        };
        let p = &inner.parties[&id];
        if p.leader != account {
            return Err(Refusal::new(ErrorCode::NotPartyLeader, DETAIL_NOT_LEADER));
        }
        if p.index(target).is_some() {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_ALREADY_MEMBER));
        }
        if p.members.len() >= self.params.max_members {
            return Err(Refusal::new(ErrorCode::PartyFull, DETAIL_PARTY_FULL));
        }
        let msg = ServerMsg::LobbyEvent(LobbyEvent::PartyInvite(PartyInvite {
            from: me,
            code: p.code.clone(),
        }));
        if let Some(frame) = encode(&msg) {
            self.send(target, &frame);
        }
        tracing::info!(
            account = account.0,
            target = target.0,
            party = id,
            "party invite"
        );
        Ok(p.view())
    }

    /// The leader took a seat in `room_id`: every other connected member's connection is
    /// asked to follow. Returns how many were asked.
    pub fn follow(&self, leader: AccountId, room_id: u32) -> usize {
        let inner = self.lock();
        let Some(&id) = inner.of.get(&leader) else {
            return 0;
        };
        let p = &inner.parties[&id];
        if p.leader != leader {
            return 0;
        }
        let mut n = 0;
        for m in &p.members {
            let a = Party::account(m);
            if a == leader || !m.connected {
                continue;
            }
            if let Some((_, tx)) = inner.follow.get(&a) {
                if tx
                    .try_send(Follow {
                        room_id,
                        party_id: id,
                    })
                    .is_ok()
                {
                    n += 1;
                }
            }
        }
        n
    }

    /// Removes `account` from its party: `party_left {reason}` to it (when given and
    /// connected), the leader's role passed on, the state to the rest, an empty party
    /// closed.
    fn remove(&self, inner: &mut Inner, account: AccountId, reason: Option<PartyLeftReason>) {
        let Some(id) = inner.of.remove(&account) else {
            return;
        };
        let Some(p) = inner.parties.get_mut(&id) else {
            return;
        };
        if let Some(i) = p.index(account) {
            p.members.remove(i);
        }
        if let Some(reason) = reason {
            if let Some(frame) = encode(&left_msg(reason)) {
                self.send(account, &frame);
            }
        }
        if p.members.is_empty() {
            let code = p.code.clone();
            inner.parties.remove(&id);
            inner.codes.remove(&code);
            tracing::info!(party = id, "party closed (empty)");
            return;
        }
        if p.leader == account {
            // The longest-present member leads now (members are in join order); a
            // connected one first.
            let next = p
                .members
                .iter()
                .find(|m| m.connected)
                .or_else(|| p.members.first())
                .map(Party::account);
            if let Some(n) = next {
                p.leader = n;
                tracing::info!(party = id, leader = n.0, "party leader passed");
            }
        }
        self.broadcast(inner, id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::Metrics;
    use crate::sessions::{Kick, SessionHandle};
    use axum::extract::ws::Message;
    use protocol::{decode_server_frame, DisplayName};
    use tokio::sync::watch;

    struct Conn {
        rx: mpsc::Receiver<Message>,
        _kick: watch::Receiver<Option<Kick>>,
        follow: mpsc::Receiver<Follow>,
    }

    impl Conn {
        fn events(&mut self) -> Vec<LobbyEvent> {
            let mut out = Vec::new();
            while let Ok(Message::Binary(b)) = self.rx.try_recv() {
                for m in decode_server_frame(&b).expect("frame") {
                    if let ServerMsg::LobbyEvent(e) = m {
                        out.push(e);
                    }
                }
            }
            out
        }
    }

    fn ident(id: u64) -> Identity {
        Identity {
            account_id: AccountId(id),
            display_name: DisplayName(format!("P{id}")),
            name_tag: id as u16,
        }
    }

    fn setup(max: usize) -> (Arc<Parties>, Arc<Sessions>) {
        let sessions = Arc::new(Sessions::new(Arc::new(Metrics::default())));
        let params = PartyParams {
            max_members: max,
            member_hold: Duration::from_millis(50),
        };
        let taken: CodeTaken = Arc::new(|_| false);
        (
            Arc::new(Parties::new(sessions.clone(), params, taken)),
            sessions,
        )
    }

    fn online(p: &Parties, s: &Sessions, id: u64) -> (Conn, u64) {
        let (tx, rx) = mpsc::channel(64);
        let sid = s.next_session_id();
        let (h, kick) = SessionHandle::new(sid, AccountId(id), 0, tx.clone());
        s.register(h);
        let (follow, state) = p.attach(sid, AccountId(id));
        if let Some(m) = state {
            // The gateway sends it after Welcome.
            let _ = tx.try_send(Message::Binary(encode(&m).unwrap()));
        }
        (
            Conn {
                rx,
                _kick: kick,
                follow,
            },
            sid,
        )
    }

    fn state_of(events: &[LobbyEvent]) -> Option<&PartyState> {
        events.iter().rev().find_map(|e| match e {
            LobbyEvent::PartyState(s) => Some(s),
            _ => None,
        })
    }

    #[tokio::test]
    async fn create_join_leave_and_leader_passing() {
        let (p, s) = setup(8);
        let (mut a, _) = online(&p, &s, 1);
        let (mut b, _) = online(&p, &s, 2);
        let (mut c, _) = online(&p, &s, 3);
        let v = p.create(ident(1)).unwrap();
        assert_eq!(v.members, vec![AccountId(1)]);
        let st = a.events();
        let st = state_of(&st).expect("state to the creator");
        assert_eq!(st.leader, AccountId(1));
        assert_eq!(st.code, v.code);
        p.join(ident(2), &v.code, &[]).unwrap();
        p.join(ident(3), &v.code, &[]).unwrap();
        let ev = b.events();
        let st = state_of(&ev).unwrap();
        assert_eq!(st.members.len(), 3);
        assert_eq!(p.view(AccountId(3)).unwrap().members.len(), 3);
        // The leader leaves: party_left to them, the next member leads.
        a.events();
        p.leave(AccountId(1)).unwrap();
        assert!(a.events().contains(&LobbyEvent::PartyLeft(PartyLeft {
            reason: PartyLeftReason::Left
        })));
        let ev = c.events();
        assert_eq!(state_of(&ev).unwrap().leader, AccountId(2));
        assert_eq!(p.view(AccountId(2)).unwrap().leader, AccountId(2));
        assert!(p.view(AccountId(1)).is_none());
        // Everyone leaves: the party closes and its code stops working.
        p.leave(AccountId(2)).unwrap();
        p.leave(AccountId(3)).unwrap();
        assert_eq!(p.count(), 0);
        assert!(p.find_code(&v.code).is_none());
        assert_eq!(
            p.leave(AccountId(3)).unwrap_err().code,
            ErrorCode::PartyNotFound
        );
    }

    #[tokio::test]
    async fn refusals_full_unknown_blocked_and_leader_only() {
        let (p, s) = setup(2);
        let (_a, _) = online(&p, &s, 1);
        let (_b, _) = online(&p, &s, 2);
        let (_c, _) = online(&p, &s, 3);
        let v = p.create(ident(1)).unwrap();
        let unknown = Code("ZZZZZZ".into());
        assert_eq!(
            p.join(ident(2), &unknown, &[]).unwrap_err().code,
            ErrorCode::PartyNotFound
        );
        assert_eq!(
            p.join(ident(2), &v.code, &[1]).unwrap_err().code,
            ErrorCode::Blocked
        );
        p.join(ident(2), &v.code, &[]).unwrap();
        assert_eq!(
            p.join(ident(3), &v.code, &[]).unwrap_err().code,
            ErrorCode::PartyFull
        );
        assert_eq!(
            p.kick(AccountId(2), AccountId(1)).unwrap_err().code,
            ErrorCode::NotPartyLeader
        );
        assert_eq!(
            p.invite(ident(2), AccountId(3)).unwrap_err().code,
            ErrorCode::NotPartyLeader
        );
        assert_eq!(
            p.kick(AccountId(1), AccountId(1)).unwrap_err().code,
            ErrorCode::NotAllowed
        );
        assert_eq!(
            p.kick(AccountId(1), AccountId(3)).unwrap_err().code,
            ErrorCode::NotAllowed
        );
        assert_eq!(
            p.invite(ident(1), AccountId(3)).unwrap_err().code,
            ErrorCode::PartyFull
        );
    }

    #[tokio::test]
    async fn invite_makes_a_party_and_reaches_the_friend() {
        let (p, s) = setup(8);
        let (mut a, _) = online(&p, &s, 1);
        let (mut b, _) = online(&p, &s, 2);
        // Offline friends can't be invited.
        assert_eq!(
            p.invite(ident(1), AccountId(9)).unwrap_err().code,
            ErrorCode::NotAllowed
        );
        let v = p.invite(ident(1), AccountId(2)).unwrap();
        assert!(
            state_of(&a.events()).is_some(),
            "the new party's state first"
        );
        let ev = b.events();
        assert_eq!(
            ev,
            vec![LobbyEvent::PartyInvite(PartyInvite {
                from: ident(1),
                code: v.code.clone()
            })]
        );
        // Accepting is party_join with the invite's code.
        p.join(ident(2), &v.code, &[]).unwrap();
        assert_eq!(
            p.invite(ident(1), AccountId(2)).unwrap_err().code,
            ErrorCode::NotAllowed
        );
    }

    #[tokio::test]
    async fn kick_and_joining_another_party() {
        let (p, s) = setup(8);
        let (_a, _) = online(&p, &s, 1);
        let (mut b, _) = online(&p, &s, 2);
        let (_c, _) = online(&p, &s, 3);
        let v1 = p.create(ident(1)).unwrap();
        let v3 = p.create(ident(3)).unwrap();
        p.join(ident(2), &v1.code, &[]).unwrap();
        b.events();
        p.kick(AccountId(1), AccountId(2)).unwrap();
        assert_eq!(
            b.events(),
            vec![LobbyEvent::PartyLeft(PartyLeft {
                reason: PartyLeftReason::Kicked
            })]
        );
        p.join(ident(2), &v1.code, &[]).unwrap();
        // Joining another party leaves the first.
        p.join(ident(2), &v3.code, &[]).unwrap();
        assert_eq!(p.view(AccountId(1)).unwrap().members, vec![AccountId(1)]);
        assert_eq!(p.view(AccountId(2)).unwrap().id, v3.id);
    }

    #[tokio::test]
    async fn the_leader_moves_the_party() {
        let (p, s) = setup(8);
        let (_a, _) = online(&p, &s, 1);
        let (mut b, _) = online(&p, &s, 2);
        let (mut c, _) = online(&p, &s, 3);
        let v = p.create(ident(1)).unwrap();
        p.join(ident(2), &v.code, &[]).unwrap();
        p.join(ident(3), &v.code, &[]).unwrap();
        assert_eq!(
            p.follow(AccountId(2), 7),
            0,
            "only the leader moves the party"
        );
        assert_eq!(p.follow(AccountId(1), 7), 2);
        let want = Follow {
            room_id: 7,
            party_id: v.id,
        };
        assert_eq!(b.follow.try_recv().unwrap(), want);
        assert_eq!(c.follow.try_recv().unwrap(), want);
    }

    #[tokio::test]
    async fn a_dropped_member_is_held_then_leaves() {
        let (p, s) = setup(8);
        let (_a, _) = online(&p, &s, 1);
        let (mut b, sb) = online(&p, &s, 2);
        let v = p.create(ident(1)).unwrap();
        p.join(ident(2), &v.code, &[]).unwrap();
        // B drops and comes back within the hold: still a member, the state at once.
        p.detach(sb, AccountId(2));
        assert_eq!(p.view(AccountId(1)).unwrap().connected, vec![AccountId(1)]);
        assert_eq!(
            p.follow(AccountId(1), 3),
            0,
            "a dropped member is not asked"
        );
        b.events();
        let (mut b2, sb2) = online(&p, &s, 2);
        assert!(state_of(&b2.events()).is_some());
        tokio::time::sleep(Duration::from_millis(120)).await;
        assert_eq!(p.view(AccountId(1)).unwrap().members.len(), 2);
        // A replaced session ending does not touch its successor.
        p.detach(sb, AccountId(2));
        assert_eq!(p.view(AccountId(1)).unwrap().connected.len(), 2);
        // Dropped for longer than the hold: gone, and the leader is told.
        p.detach(sb2, AccountId(2));
        tokio::time::sleep(Duration::from_millis(120)).await;
        assert_eq!(p.view(AccountId(1)).unwrap().members, vec![AccountId(1)]);
        assert!(p.view(AccountId(2)).is_none());
    }

    #[tokio::test]
    async fn a_dropped_leader_hands_over_when_the_hold_ends() {
        let (p, s) = setup(8);
        let (_a, sa) = online(&p, &s, 1);
        let (_b, _) = online(&p, &s, 2);
        let v = p.create(ident(1)).unwrap();
        p.join(ident(2), &v.code, &[]).unwrap();
        p.detach(sa, AccountId(1));
        tokio::time::sleep(Duration::from_millis(120)).await;
        let view = p.view(AccountId(2)).unwrap();
        assert_eq!(view.leader, AccountId(2));
        assert_eq!(view.members, vec![AccountId(2)]);
    }
}
