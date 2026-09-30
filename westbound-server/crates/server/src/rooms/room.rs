//! One room's state and rules (N5.1), driven by its task (`task.rs`). Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and matchmaking → Rooms (settings,
//! private rooms: host kicks and changes density or time mode, host passes to the
//! longest-present player, the room closes 60 s after it empties; public rooms), Players
//! (the `PlayerState` relay, plausibility, spawning, crash-out, rejoin crew, reconnect with
//! a 15 s seat hold), Time of day in multiplayer, "Rules for the server code" (one owner
//! per room; one frame per tick per client). Wire: docs/PROTOCOL.md §4.
//!
//! **Synchronous and owned.** `Room` has no locks and no `.await`: the task hands it each
//! command as it arrives ([`Room::on_cmd`]) and each 20 Hz tick ([`Room::advance_to`]).
//! Everything a client receives goes out in **one frame per tick**, built into the seat's
//! own reused `FrameBuilder`: its `RoomSnapshot` on the tick it (re)joined, else the room
//! events of the tick, then its private replies, then `player_states`, then traffic. Only a
//! player leaving the room gets a direct `lobby_event.room_left` (it has no next tick).
//!
//! **Placements.** The protocol has no spawn message; the server places a player by
//! putting **the player's own id** in its `player_states` (a state with `run_state =
//! protected` and the placement tick). It is repeated every tick until the client sends a
//! state near it (`plausibility::check`). This needs no wire change (see the N5.1 handoff:
//! proposed for PROTOCOL.md). Placements happen on join (spawn), after a crash-out
//! (respawn), on `run_event.rejoin`, on `run_event.start` after a run ended, and on
//! reconnect (at the last position, run intact).
//!
//! **Scoring (N6.1).** The room owns a [`RoomScoring`]: accepted states, claims, hits and
//! rejoins go to it; it runs after the traffic every tick; its `ScoreSync` / `ScoreEvent`
//! messages go out with each player's private replies, crew totals as `room_event.crew`;
//! a run's end asks it for the official score (`run_result`), and a verified run goes to
//! the boards through the rooms' run sink.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use protocol::{
    AccountId, ChatItem, Code, CrewTag, Density, EncodeError, ErrorCode, ErrorMsg, FrameBuilder,
    HitReport, Identity, LeaveReason, LobbyEvent, Member as WireMember, MemberConnection,
    MemberFlags, MemberLeft, PlayerRef, PlayerState, PlayerStateEntry, QuickChatRelay, RoomCrew,
    RoomEvent, RoomHostCommand, RoomLeft, RoomLeftReason, RoomSettings, RoomSnapshot, RunEndReason,
    RunEvent, RunEventKind, RunResult, RunResultFlags, RunState, ScoreClaim, ServerMsg,
    SettingsChanged, Text, TimeMode, Visibility,
};
use tokio::sync::oneshot;

use super::clock::RoomTime;
use super::plausibility::{self, tick_diff, DropReason, Offence, Placement, Verdict};
use super::road::{flow_speed_cms, lane_at, lane_center_d_mm, start_spawn_points, MM_PER_CM};
use super::scoring::RoomScoring;
use super::traffic::{PlayerView, RoomTraffic, SpawnSpot};
use super::{FinishedRun, RoomInfo, Shared};
use crate::leaderboards::RoomKind;
use crate::sessions::SessionHandle;

/// `Error.detail` texts rooms send (English; clients localize by code).
pub const DETAIL_ROOM_FULL: &str = "This room is full.";
pub const DETAIL_KICKED_BEFORE: &str = "You were removed from this room.";
pub const DETAIL_ALREADY_HERE: &str = "You are already in this room.";
pub const DETAIL_NOT_HOST: &str = "Only the host can do that.";
pub const DETAIL_PUBLIC_NO_HOST: &str = "Public rooms have no host.";
pub const DETAIL_NO_SUCH_PLAYER: &str = "That player is not in this room.";
pub const DETAIL_KICK_SELF: &str = "The host cannot kick themselves.";
pub const DETAIL_ROOM_CLOSED: &str = "This room has closed.";

/// Commands from connections (and the registry) to a room task.
#[derive(Debug)]
pub enum Cmd {
    Join(JoinReq),
    /// `lobby_command.room_leave`.
    Leave {
        player_id: u16,
        session_id: u64,
    },
    /// The connection ended while seated: hold the seat.
    Disconnected {
        player_id: u16,
        session_id: u64,
    },
    State {
        player_id: u16,
        session_id: u64,
        state: PlayerState,
    },
    Run {
        player_id: u16,
        session_id: u64,
        event: RunEvent,
    },
    Hit {
        player_id: u16,
        session_id: u64,
        hit: HitReport,
    },
    /// `score_claim` (N6.1).
    Claim {
        player_id: u16,
        session_id: u64,
        claim: ScoreClaim,
    },
    Host {
        player_id: u16,
        session_id: u64,
        cmd: RoomHostCommand,
    },
    Chat {
        player_id: u16,
        session_id: u64,
        item: ChatItem,
    },
    /// The account took a seat in another room: free its seat here.
    Release {
        account: AccountId,
    },
    /// N10.2: close the room at its next tick (an operator's `room-close`, or the restart
    /// handover). Active runs end as `room_closed` (verified ones go to the boards), the
    /// notice and the run results go out in that tick's frame, then the seats go:
    /// `room_left{closed}` for [`CloseMode::Admin`], nothing for [`CloseMode::Restart`]
    /// (the sockets close with 1012 and the clients rejoin the next instance by code).
    /// `reply` gets the room's settings at the end (the handover saves them).
    Close {
        mode: CloseMode,
        notice: Option<ServerMsg>,
        reply: oneshot::Sender<RoomSettings>,
    },
}

/// How a room closes (N10.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseMode {
    /// An operator closed it: everyone gets `room_left{closed}`.
    Admin,
    /// The planned-restart handover: seats end quietly.
    Restart,
}

/// A close waiting for the room's next tick.
#[derive(Debug)]
struct Closing {
    mode: CloseMode,
    notice: Option<ServerMsg>,
    reply: Option<oneshot::Sender<RoomSettings>>,
    begun: bool,
}

/// A request for a seat.
#[derive(Debug)]
pub struct JoinReq {
    pub session: SessionHandle,
    pub identity: Identity,
    pub crew_tag: CrewTag,
    /// N9.3: the joiner's party (one crew in public rooms).
    pub party: Option<u32>,
    pub reply: oneshot::Sender<Result<Joined, Refusal>>,
}

/// A seat, as the connection keeps it.
#[derive(Debug, Clone)]
pub struct Joined {
    pub player_id: u16,
    /// False once the room let the seat go (kick, close, a later reconnect elsewhere).
    pub active: Arc<AtomicBool>,
    /// The seat was held or replaced and is taken back (run intact).
    pub reconnected: bool,
}

/// Why a join (or a host command) was refused: a non-fatal `Error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Refusal {
    pub code: ErrorCode,
    pub detail: &'static str,
}

impl Refusal {
    pub fn new(code: ErrorCode, detail: &'static str) -> Self {
        Self { code, detail }
    }

    pub fn to_msg(self) -> ServerMsg {
        ServerMsg::Error(ErrorMsg {
            code: self.code,
            fatal: false,
            detail: Text(self.detail.to_owned()),
        })
    }
}

/// Why a server placement happens (where it goes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Purpose {
    /// A new seat: behind the crew leader, else at the start gantry.
    Spawn,
    /// After a crash-out, a `run_event.start` or a rejoin: next to the crew, else where
    /// the player is.
    Crew,
    /// Back from a dropped connection: where the player was.
    Reconnect,
}

/// How a seat ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Removal {
    Left,
    TimedOut,
    Kicked,
    Closed,
    /// N10.2: the restart handover (no message: the socket closes with 1012).
    Handover,
}

#[derive(Debug, Default)]
struct Run {
    /// Counts runs in this room (wrapping), 1 for the first.
    seq: u16,
    active: bool,
    start_tick: u32,
    /// Forward distance driven (mm), teleports left out.
    distance_mm: u64,
    /// A plausibility offence (never reaches a leaderboard).
    unverified: bool,
    /// The room ran on non-default settings during the run (private rooms).
    custom: bool,
    protected_until: u32,
    /// A crash-out's respawn is due at this tick.
    respawn_at: Option<u32>,
    offences: [u32; Offence::ALL.len()],
    /// Offence kinds already logged this run (one log line per kind per run).
    logged: u8,
}

struct Seat {
    player_id: u16,
    account: AccountId,
    identity: Identity,
    crew_tag: CrewTag,
    crew_slot: u8,
    /// N9.3: the party the player joined with (public rooms: the crew).
    party: Option<u32>,
    /// The live connection; `None` while the seat is held.
    session: Option<SessionHandle>,
    active: Arc<AtomicBool>,
    held_until: Option<u32>,
    /// Reused for every tick frame of this seat.
    frame: FrameBuilder,
    snapshot_due: bool,
    /// Replies to this player (host-command errors), sent with the next tick.
    private: Vec<ServerMsg>,
    /// Latest accepted state (clamped).
    state: Option<PlayerState>,
    /// `state` is new since the last tick's relay.
    fresh: bool,
    placement: Option<Placement>,
    run: Run,
}

impl Seat {
    fn session_is(&self, session_id: u64) -> bool {
        self.session
            .as_ref()
            .is_some_and(|s| s.session_id == session_id)
    }

    fn wire(&self, host: Option<u16>) -> WireMember {
        WireMember {
            player_id: self.player_id,
            identity: self.identity.clone(),
            crew_tag: self.crew_tag.clone(),
            crew_slot: self.crew_slot,
            flags: MemberFlags {
                host: host == Some(self.player_id),
                disconnected: self.session.is_none(),
            },
        }
    }
}

pub struct Room {
    pub id: u32,
    code: Code,
    settings: RoomSettings,
    time: RoomTime,
    shared: Arc<Shared>,
    info: Arc<RoomInfo>,
    traffic: Box<dyn RoomTraffic>,
    seats: Vec<Seat>,
    next_player_id: u16,
    host: Option<u16>,
    kicked: Vec<AccountId>,
    tick: u32,
    ticked: bool,
    empty_since: Option<u32>,
    /// This tick's room events and the player each one skips (0: nobody).
    events: Vec<(ServerMsg, u16)>,
    /// This tick's relayed states (reused).
    relay: Vec<PlayerStateEntry>,
    /// Players for traffic (reused).
    views: Vec<PlayerView>,
    /// N6.1: claims, the official score, trains, crew totals.
    scoring: RoomScoring,
    closed: bool,
    /// N10.2: a close waiting for the next tick.
    closing: Option<Closing>,
}

impl Room {
    pub fn new(
        id: u32,
        code: Code,
        settings: RoomSettings,
        time: RoomTime,
        shared: Arc<Shared>,
        info: Arc<RoomInfo>,
        mut traffic: Box<dyn RoomTraffic>,
    ) -> Self {
        traffic.set_density(settings.density);
        let cap = usize::from(protocol::messages::MAX_ROOM_PLAYERS);
        let scoring = RoomScoring::new(
            shared.params.scoring.clone(),
            &shared.map.map,
            shared.metrics.clone(),
        );
        Self {
            scoring,
            id,
            code,
            settings,
            time,
            shared,
            info,
            traffic,
            seats: Vec::with_capacity(cap),
            next_player_id: 1,
            host: None,
            kicked: Vec::new(),
            tick: 0,
            ticked: false,
            empty_since: None,
            events: Vec::with_capacity(cap * 2),
            relay: Vec::with_capacity(cap),
            views: Vec::with_capacity(cap),
            closed: false,
            closing: None,
        }
    }

    pub fn code(&self) -> &Code {
        &self.code
    }

    pub fn settings(&self) -> &RoomSettings {
        &self.settings
    }

    pub fn seat_count(&self) -> usize {
        self.seats.len()
    }

    pub fn host(&self) -> Option<u16> {
        self.host
    }

    pub fn info(&self) -> &Arc<RoomInfo> {
        &self.info
    }

    fn is_public(&self) -> bool {
        self.settings.visibility == Visibility::Public
    }

    /// Default density and the UTC cycle (spec: "Private rooms left on the defaults also
    /// count" for the Loop boards).
    fn on_defaults(&self) -> bool {
        self.settings.density == Density::Normal && self.settings.time_mode == TimeMode::Cycle
    }

    fn seat_index(&self, player_id: u16, session_id: u64) -> Option<usize> {
        self.seats
            .iter()
            .position(|s| s.player_id == player_id && s.session_is(session_id))
    }

    fn ticks(&self, ms: u64) -> u32 {
        self.shared.params.ms_to_ticks(ms)
    }

    // ------------------------------------------------------------------ Commands

    /// Applies one command at room tick `now`.
    pub fn on_cmd(&mut self, cmd: Cmd, now: u32) {
        match cmd {
            Cmd::Join(req) => {
                let r = self.join(req.session, req.identity, req.crew_tag, req.party, now);
                // The connection may have gone meanwhile; its cleanup handles the seat.
                let _ = req.reply.send(r);
            }
            Cmd::Leave {
                player_id,
                session_id,
            } => {
                if let Some(i) = self.seat_index(player_id, session_id) {
                    self.end_run(i, RunEndReason::Quit, now);
                    self.remove(i, Removal::Left);
                }
            }
            Cmd::Disconnected {
                player_id,
                session_id,
            } => {
                if let Some(i) = self.seat_index(player_id, session_id) {
                    self.hold(i, now);
                }
            }
            Cmd::State {
                player_id,
                session_id,
                state,
            } => match self.seat_index(player_id, session_id) {
                Some(i) => self.on_state(i, &state, now),
                None => self.shared.metrics.count_drop("not_seated"),
            },
            Cmd::Run {
                player_id,
                session_id,
                event,
            } => {
                if let Some(i) = self.seat_index(player_id, session_id) {
                    self.on_run_event(i, event, now);
                }
            }
            Cmd::Hit {
                player_id,
                session_id,
                hit,
            } => {
                if let Some(i) = self.seat_index(player_id, session_id) {
                    // The client is authoritative for its lives; scoring loses the chain
                    // at the hit's tick and cross-checks a traffic hit before the car
                    // reacts. A hit stamped before the run started belongs to the run
                    // before.
                    self.scoring.on_hit(player_id, &hit, now);
                    let run_start = self.seats[i].run.start_tick;
                    if hit.lives_left == 0 && tick_diff(run_start, hit.tick) >= 0 {
                        self.crash_out(i, now);
                    }
                }
            }
            Cmd::Claim {
                player_id,
                session_id,
                claim,
            } => {
                if self.seat_index(player_id, session_id).is_some() {
                    self.scoring.on_claim(player_id, &claim, now);
                }
            }
            Cmd::Host {
                player_id,
                session_id,
                cmd,
            } => {
                if let Some(i) = self.seat_index(player_id, session_id) {
                    if let Err(r) = self.host_command(i, cmd, now) {
                        self.seats[i].private.push(r.to_msg());
                    }
                }
            }
            Cmd::Chat {
                player_id,
                session_id,
                item,
            } => {
                if self.seat_index(player_id, session_id).is_some() {
                    self.events.push((
                        ServerMsg::QuickChat(QuickChatRelay { player_id, item }),
                        player_id,
                    ));
                }
            }
            Cmd::Release { account } => {
                if let Some(i) = self.seats.iter().position(|s| s.account == account) {
                    self.end_run(i, RunEndReason::Quit, now);
                    self.remove(i, Removal::Left);
                }
            }
            Cmd::Close {
                mode,
                notice,
                reply,
            } => {
                if self.closing.is_some() {
                    // Already closing: this caller gets the settings now.
                    let _ = reply.send(self.settings.clone());
                } else {
                    self.closing = Some(Closing {
                        mode,
                        notice,
                        reply: Some(reply),
                        begun: false,
                    });
                }
            }
        }
    }

    /// N10.2: the start of a close tick: every active run ends (`room_closed`) and the
    /// notice joins the tick's events.
    fn begin_close(&mut self, now: u32) {
        let notice = match &mut self.closing {
            Some(c) if !c.begun => {
                c.begun = true;
                c.notice.take()
            }
            _ => return,
        };
        for i in 0..self.seats.len() {
            self.end_run(i, RunEndReason::RoomClosed, now);
        }
        if let Some(n) = notice {
            self.events.push((n, 0));
        }
    }

    /// N10.2: the end of a close tick (its frame is out): the seats go and the waiting
    /// caller gets the settings. Returns false (the room is done) when a close ran.
    fn finish_close(&mut self) -> bool {
        let Some(c) = self.closing.take() else {
            return true;
        };
        match c.mode {
            CloseMode::Admin => self.close(),
            CloseMode::Restart => {
                self.closed = true;
                while !self.seats.is_empty() {
                    self.remove(0, Removal::Handover);
                }
            }
        }
        tracing::info!(room = self.id, mode = ?c.mode, "room closed");
        if let Some(r) = c.reply {
            let _ = r.send(self.settings.clone());
        }
        false
    }

    fn join(
        &mut self,
        session: SessionHandle,
        identity: Identity,
        crew_tag: CrewTag,
        party: Option<u32>,
        now: u32,
    ) -> Result<Joined, Refusal> {
        if self.closed {
            return Err(Refusal::new(ErrorCode::RoomNotFound, DETAIL_ROOM_CLOSED));
        }
        let account = session.account_id;
        if let Some(i) = self.seats.iter().position(|s| s.account == account) {
            return self.reclaim(i, session, now);
        }
        if self.kicked.contains(&account) {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_KICKED_BEFORE));
        }
        if self.seats.len() >= usize::from(self.settings.max_players) {
            return Err(Refusal::new(ErrorCode::RoomFull, DETAIL_ROOM_FULL));
        }
        let player_id = self.alloc_player_id();
        // Private room: everyone is one crew. Public room: the party you joined with (N9.3:
        // a seat of the same party gives its crew slot); alone, a crew of one.
        let crew_slot = if self.is_public() {
            let party_slot = party.and_then(|p| {
                self.seats
                    .iter()
                    .find(|s| s.party == Some(p))
                    .map(|s| s.crew_slot)
            });
            party_slot.unwrap_or_else(|| {
                (0..protocol::messages::MAX_CREWS)
                    .find(|c| self.seats.iter().all(|s| s.crew_slot != *c))
                    .unwrap_or(0)
            })
        } else {
            0
        };
        if self.seats.iter().all(|s| s.crew_slot != crew_slot) {
            self.events.push((
                ServerMsg::RoomEvent(RoomEvent::Crew(crew(crew_slot))),
                player_id,
            ));
        }
        if !self.is_public() && self.host.is_none() {
            self.host = Some(player_id);
        }
        let active = Arc::new(AtomicBool::new(true));
        let seat = Seat {
            player_id,
            account,
            identity,
            crew_tag,
            crew_slot,
            party,
            session: Some(session),
            active: active.clone(),
            held_until: None,
            frame: FrameBuilder::new(),
            snapshot_due: true,
            private: Vec::new(),
            state: None,
            fresh: false,
            placement: None,
            run: Run::default(),
        };
        self.events.push((
            ServerMsg::RoomEvent(RoomEvent::Join(seat.wire(self.host))),
            player_id,
        ));
        self.seats.push(seat);
        self.scoring.add_player(player_id, crew_slot);
        let i = self.seats.len() - 1;
        self.start_run(i, Purpose::Spawn, now);
        self.empty_since = None;
        super::RoomMetrics::inc(&self.shared.metrics.joins);
        super::RoomMetrics::inc(&self.shared.metrics.seats);
        self.shared.seat_taken(account, self.id);
        self.seats_changed();
        tracing::info!(
            room = self.id,
            account = account.0,
            player = player_id,
            "room seat taken"
        );
        Ok(Joined {
            player_id,
            active,
            reconnected: false,
        })
    }

    /// The account already has a seat: a reconnect (held seat) or a second login (the
    /// newest connection wins, like the session registry). The run continues.
    fn reclaim(&mut self, i: usize, session: SessionHandle, now: u32) -> Result<Joined, Refusal> {
        if self.seats[i].session_is(session.session_id) {
            return Err(Refusal::new(ErrorCode::AlreadyInRoom, DETAIL_ALREADY_HERE));
        }
        let seat = &mut self.seats[i];
        let was_held = seat.session.is_none();
        seat.active.store(false, Ordering::Release);
        seat.active = Arc::new(AtomicBool::new(true));
        seat.session = Some(session);
        seat.held_until = None;
        seat.snapshot_due = true;
        seat.private.clear();
        let player_id = seat.player_id;
        let active = seat.active.clone();
        if was_held {
            self.events.push((
                ServerMsg::RoomEvent(RoomEvent::Connection(MemberConnection {
                    player_id,
                    connected: true,
                })),
                player_id,
            ));
        }
        let run = &self.seats[i].run;
        if run.active {
            self.place(i, Purpose::Reconnect, now);
        } else if run.respawn_at.is_none() {
            self.start_run(i, Purpose::Crew, now);
        }
        super::RoomMetrics::inc(&self.shared.metrics.reconnects);
        self.seats_changed();
        tracing::info!(
            room = self.id,
            player = player_id,
            was_held,
            "room seat taken back"
        );
        Ok(Joined {
            player_id,
            active,
            reconnected: true,
        })
    }

    fn alloc_player_id(&mut self) -> u16 {
        loop {
            let id = self.next_player_id;
            self.next_player_id = self.next_player_id.wrapping_add(1).max(1);
            if self.seats.iter().all(|s| s.player_id != id) {
                return id;
            }
        }
    }

    /// The connection dropped: hold the seat (and the run) for the seat hold.
    fn hold(&mut self, i: usize, now: u32) {
        let hold = self.ticks(self.shared.params.seat_hold_ms);
        let seat = &mut self.seats[i];
        seat.session = None;
        seat.active.store(false, Ordering::Release);
        seat.held_until = Some(now.wrapping_add(hold));
        seat.snapshot_due = false;
        seat.private.clear();
        let player_id = seat.player_id;
        self.events.push((
            ServerMsg::RoomEvent(RoomEvent::Connection(MemberConnection {
                player_id,
                connected: false,
            })),
            player_id,
        ));
        self.shared
            .set_presence(seat_account(&self.seats[i]), self.id, None);
        tracing::info!(room = self.id, player = player_id, "room seat held");
    }

    fn remove(&mut self, i: usize, how: Removal) {
        let seat = self.seats.remove(i);
        seat.active.store(false, Ordering::Release);
        self.traffic.player_left(seat.player_id);
        self.scoring.remove_player(seat.player_id);
        let reason = match how {
            Removal::Left => Some(RoomLeftReason::Left),
            Removal::Kicked => Some(RoomLeftReason::Kicked),
            Removal::Closed => Some(RoomLeftReason::Closed),
            Removal::TimedOut | Removal::Handover => None,
        };
        if let (Some(reason), Some(s)) = (reason, &seat.session) {
            let msg = ServerMsg::LobbyEvent(LobbyEvent::RoomLeft(RoomLeft { reason }));
            if let Ok(frame) = protocol::encode_frame(std::slice::from_ref(&msg)) {
                s.send_frame(frame);
            }
        }
        let event = match how {
            Removal::Left => Some(RoomEvent::Leave(MemberLeft {
                player_id: seat.player_id,
                reason: LeaveReason::Left,
            })),
            Removal::TimedOut => Some(RoomEvent::Leave(MemberLeft {
                player_id: seat.player_id,
                reason: LeaveReason::TimedOut,
            })),
            Removal::Kicked => Some(RoomEvent::Kick(PlayerRef {
                player_id: seat.player_id,
            })),
            Removal::Closed | Removal::Handover => None,
        };
        if let Some(e) = event {
            self.events.push((ServerMsg::RoomEvent(e), 0));
        }
        if self.host == Some(seat.player_id) {
            // Host passes to the longest-present player (seats are in join order).
            self.host = if self.is_public() {
                None
            } else {
                self.seats.first().map(|s| s.player_id)
            };
            if let Some(h) = self.host {
                self.events.push((
                    ServerMsg::RoomEvent(RoomEvent::HostChange(PlayerRef { player_id: h })),
                    0,
                ));
            }
        }
        super::RoomMetrics::dec(&self.shared.metrics.seats);
        self.shared.seat_released(seat.account, self.id);
        self.seats_changed();
        tracing::info!(
            room = self.id,
            player = seat.player_id,
            ?how,
            "room seat released"
        );
    }

    /// Seat count or joinability changed: the browser's count and every seated player's
    /// presence (`joinable`).
    fn seats_changed(&self) {
        let n = self.seats.len();
        self.info.set_players(n);
        let joinable = n < usize::from(self.settings.max_players);
        for s in &self.seats {
            if s.session.is_some() {
                self.shared.set_presence(s.account, self.id, Some(joinable));
            }
        }
    }

    fn on_state(&mut self, i: usize, st: &PlayerState, now: u32) {
        let lim = &self.shared.params.checks;
        let map = &self.shared.map.map;
        let seat = &self.seats[i];
        let verdict = plausibility::check(
            lim,
            map,
            seat.state.as_ref(),
            seat.placement.as_ref(),
            st,
            now,
        );
        match verdict {
            Verdict::Drop(r) => {
                let label = match r {
                    DropReason::OutOfOrder => "out_of_order",
                    DropReason::Stale => "stale",
                    DropReason::Future => "future",
                    DropReason::InFlight => "in_flight",
                };
                self.shared.metrics.count_drop(label);
                if r == DropReason::Future {
                    self.offend(i, Offence::Clock.bit());
                }
            }
            Verdict::Accept {
                state,
                offences,
                placed,
            } => {
                let reset = placed || offences & Offence::Teleport.bit() != 0;
                let seat = &self.seats[i];
                self.scoring
                    .on_state(seat.player_id, &state, reset, seat.run.protected_until);
                let seat = &mut self.seats[i];
                if placed {
                    seat.placement = None;
                } else if offences & Offence::Teleport.bit() == 0 {
                    if let Some(prev) = &seat.state {
                        let ds = map.signed_delta_mm(prev.s_mm, state.s_mm);
                        seat.run.distance_mm += ds.max(0) as u64;
                    }
                }
                // A crashed state counts for the current run only: not one answering a
                // placement, nor one stamped before the run started (in flight from the
                // run before a respawn).
                let crashed = state.run_state == RunState::Crashed
                    && !placed
                    && tick_diff(seat.run.start_tick, state.tick) >= 0;
                seat.state = Some(state);
                seat.fresh = true;
                if offences != 0 {
                    self.offend(i, offences);
                }
                if crashed {
                    self.crash_out(i, now);
                }
            }
        }
    }

    /// Counts offences, marks the run unverified, logs each kind once per run.
    fn offend(&mut self, i: usize, offences: u8) {
        self.scoring.mark_unverified(self.seats[i].player_id);
        let seat = &mut self.seats[i];
        seat.run.unverified = true;
        for o in Offence::ALL {
            if offences & o.bit() == 0 {
                continue;
            }
            seat.run.offences[o as usize] += 1;
            self.shared.metrics.count_offence(o);
            if seat.run.logged & o.bit() == 0 {
                seat.run.logged |= o.bit();
                tracing::info!(
                    room = self.id,
                    account = seat.account.0,
                    player = seat.player_id,
                    run = seat.run.seq,
                    offence = o.label(),
                    "implausible player state; run unverified"
                );
            }
        }
    }

    fn on_run_event(&mut self, i: usize, ev: RunEvent, now: u32) {
        let run = &self.seats[i].run;
        match ev.kind {
            RunEventKind::Start => {
                if !run.active && run.respawn_at.is_none() {
                    self.start_run(i, Purpose::Crew, now);
                }
            }
            RunEventKind::End => self.end_run(i, RunEndReason::Quit, now),
            // Rejoin crew: to the crew with protection; the chain is forfeited.
            RunEventKind::Rejoin => {
                if run.active {
                    self.scoring.rejoin(self.seats[i].player_id, now);
                    self.place(i, Purpose::Crew, now);
                }
            }
        }
    }

    fn crash_out(&mut self, i: usize, now: u32) {
        if !self.seats[i].run.active {
            return;
        }
        self.end_run(i, RunEndReason::Crashed, now);
        let delay = self.ticks(self.shared.params.crash_respawn_ms);
        self.seats[i].run.respawn_at = Some(now.wrapping_add(delay));
        super::RoomMetrics::inc(&self.shared.metrics.crash_outs);
    }

    /// A fresh run, placed for `purpose`.
    fn start_run(&mut self, i: usize, purpose: Purpose, now: u32) {
        let custom = !self.on_defaults();
        let run = &mut self.seats[i].run;
        let seq = run.seq.wrapping_add(1);
        *run = Run {
            seq,
            active: true,
            start_tick: now,
            custom,
            ..Run::default()
        };
        self.place(i, purpose, now);
        let seat = &self.seats[i];
        let s_mm = seat.state.as_ref().map_or(0, |s| s.s_mm);
        self.scoring.start_run(seat.player_id, seq, now, s_mm);
    }

    /// Ends the active run: the official score (N6.1), `RunResult` to the room, and a
    /// verified run to the boards (MP-D7 eligibility: public, or private on the default
    /// density and clock for the whole run; MP-D9: `verified` also needs no unreported
    /// hit and the claim acceptance).
    fn end_run(&mut self, i: usize, reason: RunEndReason, now: u32) {
        let public = self.is_public();
        let eligible_room = public || !self.seats[i].run.custom;
        let rate = self.shared.params.tick_rate_hz;
        if !self.seats[i].run.active {
            return;
        }
        let player_id = self.seats[i].player_id;
        let (time, settings) = (&self.time, &self.settings);
        let night = |t: u32| time.is_night(settings, t);
        let official = self
            .scoring
            .end_run(
                player_id,
                now,
                &mut *self.traffic,
                &self.shared.map.map,
                &night,
            )
            .unwrap_or_default();
        let seat = &mut self.seats[i];
        seat.run.active = false;
        let ticks = u64::try_from(tick_diff(seat.run.start_tick, now).max(0)).unwrap_or(0);
        let verified = !seat.run.unverified && official.verified;
        let c = official.counts;
        let n16 = |n: u32| u16::try_from(n).unwrap_or(u16::MAX);
        let result = RunResult {
            player_id: seat.player_id,
            run_seq: seat.run.seq,
            end_reason: reason,
            flags: RunResultFlags {
                verified,
                leaderboard_eligible: verified && eligible_room,
            },
            score: official.score,
            duration_ms: u32::try_from(ticks * 1_000 / u64::from(rate.max(1))).unwrap_or(u32::MAX),
            distance_m: u32::try_from(seat.run.distance_mm / 1_000).unwrap_or(u32::MAX),
            passes: n16(c.passes),
            close_passes: n16(c.close_passes),
            cuts: n16(c.cuts),
            threads: n16(c.threads),
            trains: n16(c.trains),
            max_multiplier_milli: official.max_multiplier_milli,
        };
        if verified {
            let room = if public {
                RoomKind::Public
            } else if eligible_room {
                RoomKind::PrivateDefault
            } else {
                RoomKind::PrivateCustom
            };
            let ms_per_tick = 1_000 / i64::from(rate.max(1));
            let ended_ms = self.time.start_unix_ms + i64::from(now) * ms_per_tick;
            self.shared.record_run(FinishedRun {
                account: seat.account,
                room,
                result: result.clone(),
                duration_s: ticks as f64 / f64::from(rate.max(1)),
                distance_m: seat.run.distance_mm as f64 / 1_000.0,
                ended_at: ended_ms.div_euclid(1_000),
            });
        }
        tracing::info!(
            room = self.id,
            player = seat.player_id,
            run = seat.run.seq,
            reason = ?reason,
            verified,
            score = result.score,
            claims_accepted = official.claims_accepted,
            claims_rejected = official.claims_rejected,
            unreported_hits = official.unreported_hits,
            distance_m = result.distance_m,
            "run ended"
        );
        self.events.push((ServerMsg::RunResult(result), 0));
    }

    /// Places the player (see the module docs) with spawn / rejoin protection.
    fn place(&mut self, i: usize, purpose: Purpose, now: u32) {
        let spot = self.spawn_spot(i, purpose);
        let grace = self.ticks(self.shared.params.placement_grace_ms);
        let protection = self.ticks(self.shared.params.protection_ms);
        let state = PlayerState {
            tick: now,
            s_mm: spot.s_mm,
            d_cm: spot.d_cm,
            speed_cms: spot.speed_cms,
            run_state: RunState::Protected,
            ..PlayerState::default()
        };
        let seat = &mut self.seats[i];
        seat.placement = Some(Placement {
            state: state.clone(),
            deadline_tick: now.wrapping_add(grace),
        });
        seat.run.protected_until = now.wrapping_add(protection);
        // Others see the car at its new place at once.
        seat.state = Some(state);
        seat.fresh = true;
        super::RoomMetrics::inc(&self.shared.metrics.placements);
    }

    /// The crew leader: the longest-present connected crewmate who is driving (seats are in
    /// join order).
    fn crew_leader(&self, i: usize) -> Option<&PlayerState> {
        let me = &self.seats[i];
        self.seats
            .iter()
            .enumerate()
            .filter(|(j, s)| {
                *j != i
                    && s.crew_slot == me.crew_slot
                    && s.session.is_some()
                    && s.run.active
                    && s.placement.is_none()
            })
            .find_map(|(_, s)| s.state.as_ref())
    }

    fn spawn_spot(&self, i: usize, purpose: Purpose) -> SpawnSpot {
        let map = &self.shared.map.map;
        let own = self.seats[i].state.as_ref();
        let leader = match purpose {
            Purpose::Reconnect => None,
            Purpose::Spawn | Purpose::Crew => self.crew_leader(i),
        };
        let (s_mm, lane) = if let Some(l) = leader {
            let behind = i64::from(self.shared.params.spawn_behind_mm);
            let s = map.wrap_mm(i64::from(l.s_mm) - behind);
            (s, lane_at(map, i64::from(l.d_cm) * MM_PER_CM, l.s_mm))
        } else if let (Some(o), true) = (own, purpose != Purpose::Spawn) {
            (o.s_mm, lane_at(map, i64::from(o.d_cm) * MM_PER_CM, o.s_mm))
        } else {
            // The start gantry: its spawn points, one lane per player id in turn.
            let n = start_spawn_points(map).count().max(1);
            let k = usize::from(self.seats[i].player_id) % n;
            start_spawn_points(map).nth(k).unwrap_or((0, 0))
        };
        let lane = lane.min(map.lane_count_at(s_mm).saturating_sub(1));
        let want = SpawnSpot {
            s_mm,
            lane,
            d_cm: (lane_center_d_mm(map, lane, s_mm) / MM_PER_CM) as i16,
            speed_cms: flow_speed_cms(map, lane, s_mm),
        };
        self.traffic.free_gap(map, want)
    }

    fn host_command(&mut self, i: usize, cmd: RoomHostCommand, now: u32) -> Result<(), Refusal> {
        if self.is_public() {
            return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_PUBLIC_NO_HOST));
        }
        if self.host != Some(self.seats[i].player_id) {
            return Err(Refusal::new(ErrorCode::NotHost, DETAIL_NOT_HOST));
        }
        match cmd {
            RoomHostCommand::Kick(p) => {
                if p.player_id == self.seats[i].player_id {
                    return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_KICK_SELF));
                }
                let Some(j) = self.seats.iter().position(|s| s.player_id == p.player_id) else {
                    return Err(Refusal::new(ErrorCode::NotAllowed, DETAIL_NO_SUCH_PLAYER));
                };
                self.kicked.push(self.seats[j].account);
                self.end_run(j, RunEndReason::Quit, now);
                self.remove(j, Removal::Kicked);
            }
            RoomHostCommand::SetDensity(d) => {
                self.settings.density = d.density;
                self.traffic.set_density(d.density);
                self.settings_changed(now);
            }
            RoomHostCommand::SetTimeMode(t) => {
                self.settings.time_mode = t.time_mode;
                self.settings.fixed_cycle_ms = self.time.shape.normalize(t.fixed_cycle_ms);
                self.settings_changed(now);
            }
        }
        Ok(())
    }

    fn settings_changed(&mut self, now: u32) {
        if !self.on_defaults() {
            for s in &mut self.seats {
                s.run.custom = true;
            }
        }
        self.info.set_density(self.settings.density);
        let msg = ServerMsg::RoomEvent(RoomEvent::Settings(SettingsChanged {
            tick: now,
            settings: self.settings.clone(),
            clock: self.time.clock_at(&self.settings, now),
        }));
        self.events.push((msg, 0));
    }

    // ------------------------------------------------------------------ Ticks

    /// Runs room tick `now` (once per tick number; a repeated or older number is ignored).
    /// Returns false when the room is done (empty past the close delay).
    pub fn advance_to(&mut self, now: u32) -> bool {
        if self.ticked && tick_diff(self.tick, now) <= 0 {
            return true;
        }
        self.ticked = true;
        self.tick = now;
        self.begin_close(now);
        self.expire_seats(now);
        self.respawns(now);
        let night = self.time.is_night(&self.settings, now);
        if self.info.set_night(night) {
            self.traffic.set_night(night);
        }
        self.views.clear();
        for s in &self.seats {
            if let Some(st) = &s.state {
                self.views.push(PlayerView {
                    player_id: s.player_id,
                    tick: st.tick,
                    s_mm: st.s_mm,
                    d_cm: st.d_cm,
                    speed_cms: st.speed_cms,
                    heading_e4: st.heading_e4,
                    lat_vel_cms: st.lat_vel_cms,
                    run_state: st.run_state,
                    protected_until: s.run.protected_until,
                });
            }
        }
        self.traffic.tick(now, &self.views);
        let t0 = Instant::now();
        let (time, settings) = (&self.time, &self.settings);
        let night = |t: u32| time.is_night(settings, t);
        self.scoring
            .tick(now, &mut *self.traffic, &self.shared.map.map, &night);
        let us = u64::try_from(t0.elapsed().as_micros()).unwrap_or(u64::MAX);
        self.shared
            .metrics
            .scoring_us_sum
            .fetch_add(us, Ordering::Relaxed);
        self.route_scoring();
        self.send_frames(now);
        self.events.clear();
        if !self.finish_close() {
            return false;
        }
        if self.seats.is_empty() {
            let since = *self.empty_since.get_or_insert(now);
            if tick_diff(since, now) >= i64::from(self.ticks(self.shared.params.empty_close_ms)) {
                self.closed = true;
                tracing::info!(room = self.id, "room closed (empty)");
                return false;
            }
        }
        true
    }

    /// Scoring's messages into the seats' private replies (`ScoreSync`, `ScoreEvent`) and
    /// the room's events (`room_event.crew`).
    fn route_scoring(&mut self) {
        for (pid, msg) in self.scoring.outbox.drain(..) {
            if let Some(seat) = self
                .seats
                .iter_mut()
                .find(|s| s.player_id == pid && s.session.is_some())
            {
                seat.private.push(msg);
            }
        }
        for c in self.scoring.crew_events.drain(..) {
            self.events
                .push((ServerMsg::RoomEvent(RoomEvent::Crew(c)), 0));
        }
    }

    fn expire_seats(&mut self, now: u32) {
        while let Some(i) = self
            .seats
            .iter()
            .position(|s| s.held_until.is_some_and(|t| tick_diff(t, now) >= 0))
        {
            // Spec: the run ends with its banked score kept.
            self.end_run(i, RunEndReason::Disconnected, now);
            super::RoomMetrics::inc(&self.shared.metrics.seat_timeouts);
            self.remove(i, Removal::TimedOut);
        }
    }

    fn respawns(&mut self, now: u32) {
        for i in 0..self.seats.len() {
            let s = &self.seats[i];
            if s.session.is_some() && s.run.respawn_at.is_some_and(|t| tick_diff(t, now) >= 0) {
                self.start_run(i, Purpose::Crew, now);
            }
        }
    }

    fn snapshot(&self, now: u32) -> ServerMsg {
        let mut crews: Vec<RoomCrew> = Vec::new();
        for s in &self.seats {
            if crews.iter().all(|c| c.crew_slot != s.crew_slot) {
                crews.push(RoomCrew {
                    session_total: self.scoring.crew_total(s.crew_slot),
                    ..crew(s.crew_slot)
                });
            }
        }
        ServerMsg::RoomSnapshot(RoomSnapshot {
            room_id: self.id,
            code: self.code.clone(),
            settings: self.settings.clone(),
            tick: now,
            clock: self.time.clock_at(&self.settings, now),
            you: 0,
            members: self.seats.iter().map(|s| s.wire(self.host)).collect(),
            crews,
        })
    }

    /// One frame per connected seat.
    fn send_frames(&mut self, now: u32) {
        self.relay.clear();
        for s in &mut self.seats {
            if s.fresh {
                s.fresh = false;
                if let Some(st) = &s.state {
                    self.relay.push(PlayerStateEntry {
                        player_id: s.player_id,
                        state: st.clone(),
                    });
                }
            }
        }
        let snapshot = self
            .seats
            .iter()
            .any(|s| s.snapshot_due && s.session.is_some())
            .then(|| self.snapshot(now));
        let Room {
            seats,
            events,
            relay,
            traffic,
            ..
        } = self;
        for seat in seats.iter_mut() {
            let Some(session) = &seat.session else {
                continue;
            };
            let fb = &mut seat.frame;
            fb.clear();
            let joined = seat.snapshot_due;
            if joined {
                seat.snapshot_due = false;
                if let Some(ServerMsg::RoomSnapshot(mut snap)) = snapshot.clone() {
                    snap.you = seat.player_id;
                    push(fb, session, &ServerMsg::RoomSnapshot(snap));
                }
            } else {
                for (msg, skip) in events.iter() {
                    if *skip != seat.player_id {
                        push(fb, session, msg);
                    }
                }
            }
            for msg in seat.private.drain(..) {
                push(fb, session, &msg);
            }
            if let Ok(mut batch) = fb.player_states() {
                if let Some(p) = &seat.placement {
                    let _ = batch.push(&PlayerStateEntry {
                        player_id: seat.player_id,
                        state: p.state.clone(),
                    });
                }
                for e in relay.iter() {
                    if e.player_id != seat.player_id {
                        let _ = batch.push(e);
                    }
                }
            }
            let s_mm = seat.state.as_ref().map_or(0, |s| s.s_mm);
            traffic.write_client(seat.player_id, s_mm, joined, fb);
            if !fb.is_empty() {
                session.send_frame(fb.finish());
            }
        }
    }

    /// Server shutdown: everyone gets `room_left{closed}`.
    pub fn close(&mut self) {
        self.closed = true;
        while !self.seats.is_empty() {
            self.remove(0, Removal::Closed);
        }
    }
}

fn seat_account(s: &Seat) -> AccountId {
    s.account
}

/// A new crew's wire entry: its palette color is its slot, its session total 0 (scoring
/// announces changes).
fn crew(slot: u8) -> RoomCrew {
    RoomCrew {
        crew_slot: slot,
        color: slot,
        session_total: 0,
    }
}

/// Appends `msg`; when the frame is full, sends it and starts another (never expected: a
/// tick frame is a few hundred bytes).
fn push(fb: &mut FrameBuilder, session: &SessionHandle, msg: &ServerMsg) {
    match fb.push(msg) {
        Ok(()) => {}
        Err(EncodeError::FrameFull { .. } | EncodeError::TooManyMessages { .. }) => {
            session.send_frame(fb.finish());
            if let Err(e) = fb.push(msg) {
                tracing::error!(error = %e, "room message does not fit a frame");
            }
        }
        Err(e) => tracing::error!(error = %e, "room message failed to encode"),
    }
}

impl std::fmt::Debug for Room {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Room")
            .field("id", &self.id)
            .field("seats", &self.seats.len())
            .field("tick", &self.tick)
            .finish_non_exhaustive()
    }
}
