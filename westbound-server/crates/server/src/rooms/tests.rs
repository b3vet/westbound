//! The room core without sockets or timers: commands and ticks by hand, frames read from
//! the sessions' queues. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, Players, Time of
//! day in multiplayer.

use std::sync::{Arc, Mutex};

use axum::extract::ws::Message;
use protocol::{
    decode_server_frame, AccountId, ChatItem, ClaimCar, ClaimKind, Code, CrewTag, Density,
    DisplayName, ErrorCode, HitReport, HitTarget, Identity, LeaveReason, LobbyEvent, PlayerRef,
    PlayerState, RoomEvent, RoomHostCommand, RoomLeftReason, RoomSettings, RunEndReason, RunEvent,
    RunEventKind, RunResult, RunState, ScoreClaim, ScoreEventKind, ServerMsg, SetDensity,
    SetTimeMode, Side, TimeMode, Visibility,
};
use tokio::sync::{mpsc, oneshot, watch};

use super::clock::RoomTime;
use super::plausibility::Offence;
use super::room::{Cmd, JoinReq, Joined, Refusal, Room};
use super::traffic::NoTraffic;
use super::{FinishedRun, Registry, RoomInfo, RoomMetrics, RoomParams, Shared};
use crate::leaderboards::RoomKind;
use crate::metrics::Metrics;
use crate::presence::PresenceHub;
use crate::sessions::{Kick, SessionHandle, Sessions};
use crate::Config;

const L: u32 = 25_000_000;

fn settings(visibility: Visibility, max_players: u8) -> RoomSettings {
    RoomSettings {
        visibility,
        max_players,
        density: Density::Normal,
        time_mode: TimeMode::Cycle,
        fixed_cycle_ms: 0,
    }
}

struct Client {
    h: SessionHandle,
    rx: mpsc::Receiver<Message>,
    _kick: watch::Receiver<Option<Kick>>,
    pid: u16,
}

impl Client {
    fn new(account: u64, session_id: u64) -> Self {
        let (tx, rx) = mpsc::channel(256);
        let (h, kick) = SessionHandle::new(session_id, AccountId(account), 0, tx);
        Self {
            h,
            rx,
            _kick: kick,
            pid: 0,
        }
    }

    /// Every frame queued since the last call, decoded.
    fn frames(&mut self) -> Vec<Vec<ServerMsg>> {
        let mut out = Vec::new();
        while let Ok(m) = self.rx.try_recv() {
            if let Message::Binary(b) = m {
                out.push(decode_server_frame(&b).expect("server frame decodes"));
            }
        }
        out
    }

    fn msgs(&mut self) -> Vec<ServerMsg> {
        self.frames().into_iter().flatten().collect()
    }
}

struct T {
    room: Room,
    shared: Arc<Shared>,
    now: u32,
}

impl T {
    fn new(s: RoomSettings) -> Self {
        Self::with(s, |_| {})
    }

    fn with(s: RoomSettings, tweak: impl FnOnce(&mut Config)) -> Self {
        let mut cfg = Config::default();
        tweak(&mut cfg);
        let params = RoomParams::from_config(&cfg);
        let sessions = Arc::new(Sessions::new(Arc::new(Metrics::default())));
        let shared = Arc::new(Shared {
            params,
            map: crate::map::builtin().expect("loop_v1"),
            presence: Arc::new(PresenceHub::new(sessions)),
            metrics: Arc::new(RoomMetrics::default()),
            registry: Mutex::new(Registry::default()),
            runs: Mutex::new(None),
        });
        let time = RoomTime {
            shape: shared.params.clock,
            start_unix_ms: 1_790_000_000_000,
            tick_rate_hz: 20,
        };
        let code = Code("ABC234".into());
        let info = Arc::new(RoomInfo::new(1, code.clone(), &s));
        let room = Room::new(1, code, s, time, shared.clone(), info, Box::new(NoTraffic));
        Self {
            room,
            shared,
            now: 100,
        }
    }

    fn join(&mut self, c: &mut Client) -> Result<Joined, Refusal> {
        self.join_party(c, None)
    }

    /// N9.3: a join as a member of `party`.
    fn join_party(&mut self, c: &mut Client, party: Option<u32>) -> Result<Joined, Refusal> {
        let (reply, mut rx) = oneshot::channel();
        let identity = Identity {
            account_id: c.h.account_id,
            display_name: DisplayName::new(format!("P{}", c.h.account_id.0)).unwrap(),
            name_tag: 1,
        };
        self.room.on_cmd(
            Cmd::Join(JoinReq {
                session: c.h.clone(),
                identity,
                crew_tag: CrewTag::default(),
                party,
                reply,
            }),
            self.now,
        );
        let r = rx.try_recv().expect("the room answers at once");
        if let Ok(j) = &r {
            c.pid = j.player_id;
        }
        r
    }

    fn tick(&mut self) {
        self.now += 1;
        assert!(self.room.advance_to(self.now), "room still open");
    }

    fn ticks(&mut self, n: u32) {
        for _ in 0..n {
            self.tick();
        }
    }

    fn cmd(&mut self, c: Cmd) {
        self.room.on_cmd(c, self.now);
    }

    fn state(&mut self, c: &Client, st: PlayerState) {
        self.cmd(Cmd::State {
            player_id: c.pid,
            session_id: c.h.session_id,
            state: st,
        });
    }

    fn run(&mut self, c: &Client, kind: RunEventKind) {
        let tick = self.now;
        self.cmd(Cmd::Run {
            player_id: c.pid,
            session_id: c.h.session_id,
            event: RunEvent { kind, tick },
        });
    }

    fn host(&mut self, c: &Client, cmd: RoomHostCommand) {
        self.cmd(Cmd::Host {
            player_id: c.pid,
            session_id: c.h.session_id,
            cmd,
        });
    }
}

/// The client's own placement in these messages (its id in `player_states`).
fn placement(msgs: &[ServerMsg], pid: u16) -> Option<PlayerState> {
    msgs.iter().rev().find_map(|m| match m {
        ServerMsg::PlayerStates(ps) => ps
            .players
            .iter()
            .find(|e| e.player_id == pid)
            .map(|e| e.state.clone()),
        _ => None,
    })
}

fn relayed(msgs: &[ServerMsg], pid: u16) -> Vec<PlayerState> {
    msgs.iter()
        .filter_map(|m| match m {
            ServerMsg::PlayerStates(ps) => Some(ps.players.clone()),
            _ => None,
        })
        .flatten()
        .filter(|e| e.player_id == pid)
        .map(|e| e.state)
        .collect()
}

fn room_events(msgs: &[ServerMsg]) -> Vec<RoomEvent> {
    msgs.iter()
        .filter_map(|m| match m {
            ServerMsg::RoomEvent(e) => Some(e.clone()),
            _ => None,
        })
        .collect()
}

fn run_results(msgs: &[ServerMsg]) -> Vec<RunResult> {
    msgs.iter()
        .filter_map(|m| match m {
            ServerMsg::RunResult(r) => Some(r.clone()),
            _ => None,
        })
        .collect()
}

fn errors(msgs: &[ServerMsg]) -> Vec<ErrorCode> {
    msgs.iter()
        .filter_map(|m| match m {
            ServerMsg::Error(e) if !e.fatal => Some(e.code),
            _ => None,
        })
        .collect()
}

fn room_left(msgs: &[ServerMsg]) -> Option<RoomLeftReason> {
    msgs.iter().find_map(|m| match m {
        ServerMsg::LobbyEvent(LobbyEvent::RoomLeft(l)) => Some(l.reason),
        _ => None,
    })
}

/// A state `ahead_m` along from `from`, same lane, stamped `tick`.
fn moved(from: &PlayerState, tick: u32, ahead_m: f64, speed_cms: u16) -> PlayerState {
    PlayerState {
        tick,
        s_mm: ((i64::from(from.s_mm) + (ahead_m * 1000.0) as i64).rem_euclid(i64::from(L))) as u32,
        d_cm: from.d_cm,
        speed_cms,
        run_state: RunState::Driving,
        ..PlayerState::default()
    }
}

/// Takes the placement: a state just ahead of it at its speed.
fn ack(t: &mut T, c: &mut Client) -> PlayerState {
    t.tick();
    let p = placement(&c.msgs(), c.pid).expect("a placement");
    t.tick();
    let st = moved(&p, t.now, f64::from(p.speed_cms) / 2000.0, p.speed_cms);
    t.state(c, st.clone());
    t.tick();
    let _ = c.msgs();
    st
}

/// Drives `n` ticks at the state's speed, one state per tick (stamped with the room tick).
fn drive(t: &mut T, c: &Client, from: &PlayerState, n: u32) -> PlayerState {
    let mut st = from.clone();
    for _ in 0..n {
        t.tick();
        st = moved(&st, t.now, f64::from(st.speed_cms) / 2000.0, st.speed_cms);
        t.state(c, st.clone());
    }
    st
}

#[test]
fn private_room_snapshot_join_leave_and_host_passing() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let mut a = Client::new(10, 1);
    let j = t.join(&mut a).expect("seat");
    assert_eq!((j.player_id, j.reconnected), (1, false));
    t.tick();
    let frames = a.frames();
    assert_eq!(frames.len(), 1, "one frame per tick");
    let ServerMsg::RoomSnapshot(snap) = &frames[0][0] else {
        panic!("the snapshot comes first: {frames:?}");
    };
    assert_eq!((snap.room_id, snap.you, snap.tick), (1, 1, 101));
    assert_eq!(snap.code.0, "ABC234");
    assert_eq!(snap.members.len(), 1);
    assert!(snap.members[0].flags.host, "the creator is host");
    assert_eq!(snap.crews.len(), 1);
    assert_eq!(snap.clock.cycle_len_ms, 1_920_000);
    // The spawn: start gantry, protected, at the lane's flow speed.
    let p = placement(&frames[0], 1).expect("own placement");
    assert_eq!(p.s_mm, 150_000);
    assert_eq!(p.run_state, RunState::Protected);
    assert!(p.speed_cms > 2_000);
    assert_eq!(t.shared.lock().seats.get(&AccountId(10)), Some(&1));

    let mut b = Client::new(11, 2);
    t.join(&mut b).expect("seat");
    t.tick();
    let am = a.msgs();
    let joins: Vec<u16> = room_events(&am)
        .iter()
        .filter_map(|e| match e {
            RoomEvent::Join(m) => Some(m.player_id),
            _ => None,
        })
        .collect();
    assert_eq!(joins, vec![2]);
    let bm = b.msgs();
    let Some(ServerMsg::RoomSnapshot(s)) = bm.first() else {
        panic!("{bm:?}");
    };
    assert_eq!((s.you, s.members.len()), (2, 2));
    assert!(
        room_events(&bm).is_empty(),
        "the snapshot replaces this tick's events"
    );
    // Both are one crew in a private room.
    assert!(s.members.iter().all(|m| m.crew_slot == 0));

    // The host leaves: the host passes to the longest-present player.
    t.cmd(Cmd::Leave {
        player_id: 1,
        session_id: 1,
    });
    assert_eq!(room_left(&a.msgs()), Some(RoomLeftReason::Left));
    t.tick();
    let ev = room_events(&b.msgs());
    assert!(ev.contains(&RoomEvent::Leave(protocol::MemberLeft {
        player_id: 1,
        reason: LeaveReason::Left
    })));
    assert!(ev.contains(&RoomEvent::HostChange(PlayerRef { player_id: 2 })));
    assert_eq!(t.room.host(), Some(2));
    assert!(!t.shared.lock().seats.contains_key(&AccountId(10)));
}

#[test]
fn relay_one_frame_per_tick_and_placement_ack() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    // A keeps getting its placement until it answers.
    t.tick();
    assert!(placement(&a.msgs(), 1).is_some());
    let _ = b.msgs();
    let sa = ack(&mut t, &mut a);
    let sb = ack(&mut t, &mut b);
    t.tick();
    assert!(
        placement(&a.msgs(), 1).is_none(),
        "acknowledged: no more placements"
    );
    // Both drive; each tick each gets exactly one frame with the other's state.
    let (mut sa, mut sb) = (sa, sb);
    for _ in 0..20 {
        t.tick();
        // A tick without new states carries at most the official score's sync (N6.1).
        for f in a.frames().into_iter().chain(b.frames()) {
            assert!(
                f.iter().all(|m| matches!(m, ServerMsg::ScoreSync(_))),
                "{f:?}"
            );
        }
        sa = moved(&sa, t.now, 1.5, sa.speed_cms);
        sb = moved(&sb, t.now, 1.5, sb.speed_cms);
        t.state(&a, sa.clone());
        t.state(&b, sb.clone());
        t.tick();
        let fa = a.frames();
        let fb = b.frames();
        assert_eq!(
            (fa.len(), fb.len()),
            (1, 1),
            "one frame per tick per client"
        );
        let seen = relayed(&fa[0], 2);
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].s_mm, sb.s_mm);
        assert!(relayed(&fa[0], 1).is_empty(), "never your own state back");
        assert_eq!(relayed(&fb[0], 1)[0].tick, sa.tick);
    }
    // A tick without new states sends no states (and no empty frames; N6.1's score sync
    // may go out).
    t.tick();
    for f in a.frames() {
        assert!(!f.is_empty());
        assert!(
            f.iter().all(|m| matches!(m, ServerMsg::ScoreSync(_))),
            "{f:?}"
        );
    }
    assert_eq!(RoomMetrics::get(&t.shared.metrics.placements), 2);
    assert_eq!(
        Offence::ALL
            .iter()
            .map(|o| t.shared.metrics.offences(*o))
            .sum::<u64>(),
        0
    );
}

/// N6.1 through the room: a claim is routed to scoring and its rejection comes back in
/// the player's frame; `ScoreSync` goes out; a run's result carries the official score
/// and a verified run reaches the run sink (an unverified one does not).
#[test]
fn claims_score_sync_and_verified_runs_reach_the_sink() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let runs: Arc<Mutex<Vec<FinishedRun>>> = Arc::default();
    let sink = runs.clone();
    *t.shared.runs.lock().unwrap() = Some(Arc::new(move |r| sink.lock().unwrap().push(r)));
    let mut a = Client::new(10, 1);
    t.join(&mut a).unwrap();
    t.tick();
    let sa = ack(&mut t, &mut a);
    let sa = drive(&mut t, &a, &sa, 10);
    // No traffic in this room: the car was never streamed to the client.
    t.cmd(Cmd::Claim {
        player_id: 1,
        session_id: 1,
        claim: ScoreClaim {
            claim_id: 42,
            tick: t.now,
            kind: ClaimKind::Pass,
            side: Side::Left,
            cars: vec![ClaimCar {
                car_id: 9,
                clearance_mm: 800,
            }],
        },
    });
    t.tick();
    let msgs = a.msgs();
    assert!(
        msgs.iter().any(|m| matches!(m, ServerMsg::ScoreEvent(e)
            if e.kind == ScoreEventKind::ClaimRejected && e.ref_id == 42 && e.player_id == 1)),
        "{msgs:?}"
    );
    let sa = drive(&mut t, &a, &sa, 40);
    assert!(a
        .msgs()
        .iter()
        .any(|m| matches!(m, ServerMsg::ScoreSync(s) if s.run_seq == 1 && s.lives == 2)));
    t.run(&a, RunEventKind::End);
    t.tick();
    let r = run_results(&a.msgs());
    assert_eq!(r.len(), 1);
    assert!(
        r[0].flags.verified && r[0].flags.leaderboard_eligible,
        "{r:?}"
    );
    assert_eq!(r[0].score, 0);
    {
        let got = runs.lock().unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].account, AccountId(10));
        assert_eq!(got[0].room, RoomKind::PrivateDefault);
        assert_eq!(got[0].result, r[0]);
        assert_eq!(
            got[0].ended_at,
            (1_790_000_000_000 + i64::from(t.now - 1) * 50) / 1_000
        );
    }
    // A second run with an offence: unverified, never handed to the boards.
    t.run(&a, RunEventKind::Start);
    let st = ack(&mut t, &mut a);
    let _ = sa;
    t.tick();
    let far = moved(&st, t.now, 2_000.0, st.speed_cms);
    t.state(&a, far);
    t.run(&a, RunEventKind::End);
    t.tick();
    let r = run_results(&a.msgs());
    assert!(!r[0].flags.verified);
    assert_eq!(runs.lock().unwrap().len(), 1);
    assert_eq!(RoomMetrics::get(&t.shared.metrics.runs_recorded), 1);
}

#[test]
fn implausible_states_mark_the_run_unverified() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let mut a = Client::new(10, 1);
    t.join(&mut a).unwrap();
    t.tick();
    let st = ack(&mut t, &mut a);
    let st = drive(&mut t, &a, &st, 5);
    // A teleport 2 km ahead.
    t.tick();
    let far = moved(&st, t.now, 2_000.0, st.speed_cms);
    t.state(&a, far.clone());
    assert_eq!(t.shared.metrics.offences(Offence::Teleport), 1);
    // Over the speed cap: relayed clamped.
    t.tick();
    let fast = moved(&far, t.now, 4.0, 15_000);
    t.state(&a, fast);
    assert_eq!(t.shared.metrics.offences(Offence::Speed), 1);
    // A state from the future is dropped and counted.
    let future = moved(&far, t.now + 50, 4.0, 3_000);
    t.state(&a, future);
    assert_eq!(t.shared.metrics.offences(Offence::Clock), 1);
    assert_eq!(t.shared.metrics.drops("future"), 1);
    t.run(&a, RunEventKind::End);
    t.tick();
    let r = run_results(&a.msgs());
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].end_reason, RunEndReason::Quit);
    assert!(!r[0].flags.verified);
    assert!(!r[0].flags.leaderboard_eligible);
    assert!(r[0].distance_m > 0, "the honest part counts");
}

#[test]
fn seat_hold_reconnect_keeps_the_run() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    let sa = ack(&mut t, &mut a);
    let _ = ack(&mut t, &mut b);
    let sa = drive(&mut t, &a, &sa, 10);
    t.cmd(Cmd::Disconnected {
        player_id: 1,
        session_id: 1,
    });
    t.tick();
    assert!(
        room_events(&b.msgs()).contains(&RoomEvent::Connection(protocol::MemberConnection {
            player_id: 1,
            connected: false
        }))
    );
    // A state from the dead session is not taken.
    t.state(&a, moved(&sa, t.now, 1.0, sa.speed_cms));
    assert_eq!(t.shared.metrics.drops("not_seated"), 1);
    t.ticks(200); // 10 s: inside the 15 s hold.
    let mut a2 = Client::new(10, 3);
    let j = t.join(&mut a2).expect("the held seat");
    assert_eq!((j.player_id, j.reconnected), (1, true));
    t.tick();
    let m = a2.msgs();
    let Some(ServerMsg::RoomSnapshot(s)) = m.first() else {
        panic!("{m:?}");
    };
    assert_eq!(s.you, 1);
    // Back at the last position, protected, same run.
    let p = placement(&m, 1).expect("reconnect placement");
    assert_eq!(p.s_mm, sa.s_mm);
    assert_eq!(p.run_state, RunState::Protected);
    assert!(
        room_events(&b.msgs()).contains(&RoomEvent::Connection(protocol::MemberConnection {
            player_id: 1,
            connected: true
        }))
    );
    let _ = ack(&mut t, &mut a2);
    t.run(&a2, RunEventKind::End);
    t.tick();
    let r = run_results(&b.msgs());
    assert_eq!(
        (r[0].run_seq, r[0].end_reason),
        (1, RunEndReason::Quit),
        "the run went on"
    );
    assert!(
        r[0].flags.verified,
        "a reconnect placement is not a teleport"
    );
}

#[test]
fn seat_hold_expires_after_15_s() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    t.cmd(Cmd::Disconnected {
        player_id: 1,
        session_id: 1,
    });
    t.ticks(299);
    let _ = b.msgs();
    assert_eq!(t.room.seat_count(), 2);
    t.tick();
    assert_eq!(t.room.seat_count(), 1);
    let m = b.msgs();
    let r = run_results(&m);
    assert_eq!(r[0].end_reason, RunEndReason::Disconnected);
    assert!(
        room_events(&m).contains(&RoomEvent::Leave(protocol::MemberLeft {
            player_id: 1,
            reason: LeaveReason::TimedOut
        }))
    );
    assert_eq!(t.room.host(), Some(2));
    assert_eq!(RoomMetrics::get(&t.shared.metrics.seat_timeouts), 1);
    // A later join is a new seat.
    let mut a2 = Client::new(10, 3);
    assert_eq!(t.join(&mut a2).unwrap().player_id, 3);
}

#[test]
fn crash_out_respawns_behind_the_crew_leader_after_3_s() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    let _ = ack(&mut t, &mut a);
    let sb = ack(&mut t, &mut b);
    let sb = drive(&mut t, &b, &sb, 5);
    t.cmd(Cmd::Hit {
        player_id: 2,
        session_id: 2,
        hit: HitReport {
            tick: t.now,
            target: HitTarget::Traffic,
            car_id: 5,
            lives_left: 1,
        },
    });
    t.tick();
    assert!(
        run_results(&b.msgs()).is_empty(),
        "one hit does not end the run"
    );
    // B (not the leader) crashes out: A is the leader. Move A first.
    let sa = PlayerState {
        tick: t.now,
        s_mm: 5_000_000,
        d_cm: 1_070,
        speed_cms: 3_000,
        run_state: RunState::Driving,
        ..PlayerState::default()
    };
    // (A teleport for A: fine for this test.)
    t.state(&a, sa.clone());
    let _ = drive(&mut t, &a, &sa, 2);
    t.cmd(Cmd::Hit {
        player_id: 1,
        session_id: 1,
        hit: HitReport {
            tick: t.now,
            target: HitTarget::Barrier,
            car_id: 0,
            lives_left: 0,
        },
    });
    // A crashed: A's leader is now B.
    t.tick();
    let r = run_results(&a.msgs());
    assert_eq!(r.len(), 1);
    assert_eq!(
        (r[0].player_id, r[0].end_reason),
        (1, RunEndReason::Crashed)
    );
    let sb_now = drive(&mut t, &b, &sb, 58);
    let _ = a.msgs();
    t.tick();
    let p = placement(&a.msgs(), 1).expect("respawn after 3 s");
    let map = &t.shared.map.map;
    assert_eq!(
        map.signed_delta_mm(p.s_mm, sb_now.s_mm),
        40_000,
        "40 m behind the crew leader"
    );
    assert_eq!(
        super::road::lane_at(map, i64::from(p.d_cm) * 10, p.s_mm),
        2,
        "the leader's lane (B spawned in lane 2)"
    );
    assert_eq!(p.run_state, RunState::Protected);
    assert_eq!(RoomMetrics::get(&t.shared.metrics.crash_outs), 1);
    // Leftovers of the old run (a crashed state, the fatal hit) don't end the new one.
    let old = PlayerState {
        tick: t.now - 5,
        run_state: RunState::Crashed,
        ..p.clone()
    };
    t.state(&a, old);
    t.cmd(Cmd::Hit {
        player_id: 1,
        session_id: 1,
        hit: HitReport {
            tick: t.now - 5,
            target: HitTarget::Barrier,
            car_id: 0,
            lives_left: 0,
        },
    });
    assert_eq!(RoomMetrics::get(&t.shared.metrics.crash_outs), 1);
    // The new run.
    let _ = ack(&mut t, &mut a);
    t.run(&a, RunEventKind::End);
    t.tick();
    assert_eq!(run_results(&a.msgs())[0].run_seq, 2);
}

#[test]
fn rejoin_crew_across_the_seam() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    let _ = ack(&mut t, &mut a);
    let _ = ack(&mut t, &mut b);
    // The leader (A) just past the start line; B far away.
    t.tick();
    let sa = PlayerState {
        tick: t.now,
        s_mm: 10_000,
        d_cm: 350,
        speed_cms: 3_000,
        run_state: RunState::Driving,
        ..PlayerState::default()
    };
    t.state(&a, sa);
    t.tick();
    let _ = b.msgs();
    t.run(&b, RunEventKind::Rejoin);
    t.tick();
    let p = placement(&b.msgs(), 2).expect("rejoin placement");
    assert_eq!(p.s_mm, L - 30_000, "40 m behind, across the seam");
    assert_eq!(
        super::road::lane_at(&t.shared.map.map, i64::from(p.d_cm) * 10, p.s_mm),
        0
    );
    assert_eq!(p.run_state, RunState::Protected);
}

#[test]
fn host_rules_kick_density_and_time_mode() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    let _ = (a.msgs(), b.msgs());
    // Not the host.
    t.host(&b, RoomHostCommand::Kick(PlayerRef { player_id: 1 }));
    t.tick();
    assert_eq!(errors(&b.msgs()), vec![ErrorCode::NotHost]);
    // Kicking yourself or nobody.
    t.host(&a, RoomHostCommand::Kick(PlayerRef { player_id: 1 }));
    t.host(&a, RoomHostCommand::Kick(PlayerRef { player_id: 9 }));
    t.tick();
    assert_eq!(
        errors(&a.msgs()),
        vec![ErrorCode::NotAllowed, ErrorCode::NotAllowed]
    );
    // Settings: night mode; everyone gets the new clock.
    t.host(
        &a,
        RoomHostCommand::SetTimeMode(SetTimeMode {
            time_mode: TimeMode::Fixed,
            fixed_cycle_ms: 1_920_000 + 60_000,
        }),
    );
    t.host(
        &a,
        RoomHostCommand::SetDensity(SetDensity {
            density: Density::Rush,
        }),
    );
    t.tick();
    let ev = room_events(&b.msgs());
    let settings_events: Vec<_> = ev
        .iter()
        .filter_map(|e| match e {
            RoomEvent::Settings(s) => Some(s.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(settings_events.len(), 2);
    let last = settings_events.last().unwrap();
    assert_eq!(last.settings.time_mode, TimeMode::Fixed);
    assert_eq!(last.settings.fixed_cycle_ms, 60_000, "taken into the cycle");
    assert_eq!(last.clock.cycle_ms, 60_000);
    assert_eq!(last.settings.density, Density::Rush);
    // Kick: B is told, the room sees it, B cannot come back.
    t.host(&a, RoomHostCommand::Kick(PlayerRef { player_id: 2 }));
    assert_eq!(room_left(&b.msgs()), Some(RoomLeftReason::Kicked));
    t.tick();
    assert!(room_events(&a.msgs()).contains(&RoomEvent::Kick(PlayerRef { player_id: 2 })));
    let mut b2 = Client::new(11, 3);
    assert_eq!(t.join(&mut b2).unwrap_err().code, ErrorCode::NotAllowed);
    // A custom room's run is not for the boards.
    t.run(&a, RunEventKind::End);
    t.tick();
    let r = run_results(&a.msgs());
    assert!(r[0].flags.verified && !r[0].flags.leaderboard_eligible);
}

/// N9.3: in a public room a party is one crew (its members share a crew slot); players
/// alone or in another party get crews of their own. Private rooms stay one crew.
#[test]
fn a_party_is_one_crew_in_a_public_room() {
    let mut t = T::new(settings(Visibility::Public, 8));
    let mut a = Client::new(10, 1);
    let mut b = Client::new(11, 2);
    let mut c = Client::new(12, 3);
    let mut d = Client::new(13, 4);
    t.join_party(&mut a, Some(7)).unwrap();
    t.join(&mut c).unwrap();
    t.join_party(&mut b, Some(7)).unwrap();
    t.join_party(&mut d, Some(9)).unwrap();
    t.tick();
    let m = d.msgs();
    let Some(ServerMsg::RoomSnapshot(s)) = m.first() else {
        panic!("{m:?}");
    };
    let slot = |pid: u16| {
        s.members
            .iter()
            .find(|m| m.player_id == pid)
            .map(|m| m.crew_slot)
            .unwrap()
    };
    assert_eq!(slot(a.pid), slot(b.pid), "party 7 shares a crew");
    assert_ne!(slot(a.pid), slot(c.pid), "a solo player is a crew of one");
    assert_ne!(slot(d.pid), slot(a.pid));
    assert_ne!(slot(d.pid), slot(c.pid));
    assert_eq!(
        s.crews.len(),
        3,
        "three crews: party 7, the solo player, party 9"
    );
    // A private room ignores parties: everyone is crew 0.
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut e, mut f) = (Client::new(20, 5), Client::new(21, 6));
    t.join_party(&mut e, Some(1)).unwrap();
    t.join_party(&mut f, Some(2)).unwrap();
    t.tick();
    let m = f.msgs();
    let Some(ServerMsg::RoomSnapshot(s)) = m.first() else {
        panic!("{m:?}");
    };
    assert!(s.members.iter().all(|m| m.crew_slot == 0));
}

#[test]
fn public_rooms_have_no_host_and_a_crew_per_player() {
    let mut t = T::new(settings(Visibility::Public, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.tick();
    let m = b.msgs();
    let Some(ServerMsg::RoomSnapshot(s)) = m.first() else {
        panic!("{m:?}");
    };
    assert!(s.members.iter().all(|m| !m.flags.host));
    assert_eq!(s.crews.len(), 2);
    assert_ne!(s.members[0].crew_slot, s.members[1].crew_slot);
    t.host(
        &a,
        RoomHostCommand::SetDensity(SetDensity {
            density: Density::Light,
        }),
    );
    t.tick();
    assert_eq!(errors(&a.msgs()), vec![ErrorCode::NotAllowed]);
    // Public runs count for the boards; a solo player respawns where they were.
    let sa = ack(&mut t, &mut a);
    let sa = drive(&mut t, &a, &sa, 3);
    t.run(&a, RunEventKind::End);
    t.tick();
    let r = run_results(&a.msgs());
    assert!(r[0].flags.leaderboard_eligible);
    t.run(&a, RunEventKind::Start);
    t.tick();
    let p = placement(&a.msgs(), a.pid).expect("a new run");
    assert_eq!(
        p.s_mm, sa.s_mm,
        "no crewmate: the new run starts where the car is"
    );
}

#[test]
fn full_rooms_second_joins_and_quick_chat() {
    let mut t = T::new(settings(Visibility::Private, 2));
    let (mut a, mut b, mut c) = (Client::new(10, 1), Client::new(11, 2), Client::new(12, 3));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    assert_eq!(t.join(&mut c).unwrap_err().code, ErrorCode::RoomFull);
    assert_eq!(t.join(&mut a).unwrap_err().code, ErrorCode::AlreadyInRoom);
    // The same account from a newer connection takes the seat over.
    let mut a2 = Client::new(10, 4);
    let j = t.join(&mut a2).unwrap();
    assert_eq!((j.player_id, j.reconnected), (1, true));
    t.state(&a, PlayerState::default());
    assert_eq!(
        t.shared.metrics.drops("not_seated"),
        1,
        "the old session is out"
    );
    t.tick();
    let _ = (a2.msgs(), b.msgs());
    t.cmd(Cmd::Chat {
        player_id: 2,
        session_id: 2,
        item: ChatItem::Horn(Default::default()),
    });
    t.tick();
    assert!(a2
        .msgs()
        .iter()
        .any(|m| matches!(m, ServerMsg::QuickChat(q) if q.player_id == 2)));
    assert!(!b
        .msgs()
        .iter()
        .any(|m| matches!(m, ServerMsg::QuickChat(_))));
}

#[test]
fn an_empty_room_closes_after_60_s() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let mut a = Client::new(10, 1);
    t.join(&mut a).unwrap();
    t.tick();
    t.cmd(Cmd::Leave {
        player_id: 1,
        session_id: 1,
    });
    t.tick(); // empty from here
    t.ticks(1_199);
    t.now += 1;
    assert!(!t.room.advance_to(t.now), "60 s after it emptied");
    let mut b = Client::new(11, 2);
    assert_eq!(t.join(&mut b).unwrap_err().code, ErrorCode::RoomNotFound);
}

#[test]
fn shutdown_tells_everyone_the_room_closed() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let (mut a, mut b) = (Client::new(10, 1), Client::new(11, 2));
    t.join(&mut a).unwrap();
    t.join(&mut b).unwrap();
    t.room.close();
    assert_eq!(room_left(&a.msgs()), Some(RoomLeftReason::Closed));
    assert_eq!(room_left(&b.msgs()), Some(RoomLeftReason::Closed));
    assert!(t.shared.lock().seats.is_empty());
}

#[test]
fn night_follows_the_room_clock() {
    // Start 1 s before nightfall (UTC-derived).
    let mut t = T::new(settings(Visibility::Private, 8));
    t.room = {
        let s = settings(Visibility::Private, 8);
        let code = Code("ABC234".into());
        let info = Arc::new(RoomInfo::new(1, code.clone(), &s));
        let time = RoomTime {
            shape: t.shared.params.clock,
            start_unix_ms: 1_920_000 * 900_000 + 1_320_000 - 1_000,
            tick_rate_hz: 20,
        };
        Room::new(
            1,
            code,
            s,
            time,
            t.shared.clone(),
            info,
            Box::new(NoTraffic),
        )
    };
    t.now = 0;
    t.room.advance_to(0);
    let info = |t: &T| t.room_info_night();
    assert!(!info(&t));
    t.ticks(20);
    assert!(info(&t));
}

impl T {
    fn room_info_night(&self) -> bool {
        self.room.info().night()
    }
}

/// N6.1: a respawn where the car is (no crewmate driving) is not acknowledged by the
/// crashed car's in-flight states near it; the client's first protected state answers
/// it, so the jump to the placement is no teleport and the new run stays verified.
#[test]
fn a_respawn_where_the_car_stopped_is_no_teleport() {
    let mut t = T::new(settings(Visibility::Private, 8));
    let mut a = Client::new(10, 1);
    t.join(&mut a).unwrap();
    t.tick();
    let sa = ack(&mut t, &mut a);
    let sa = drive(&mut t, &a, &sa, 10);
    t.cmd(Cmd::Hit {
        player_id: 1,
        session_id: 1,
        hit: HitReport {
            tick: t.now,
            target: HitTarget::Barrier,
            car_id: 0,
            lives_left: 0,
        },
    });
    // The crashed car stops and waits for its respawn (3 s), reporting `crashed`.
    let mut stopped = PlayerState {
        speed_cms: 0,
        run_state: RunState::Crashed,
        ..sa.clone()
    };
    for _ in 0..60 {
        t.tick();
        stopped.tick = t.now;
        t.state(&a, stopped.clone());
    }
    let _ = a.msgs();
    t.tick();
    let p = placement(&a.msgs(), 1).expect("the respawn");
    assert!(
        t.shared.map.map.signed_delta_mm(p.s_mm, stopped.s_mm).abs() < 5_000,
        "where the car is"
    );
    // In flight: a crashed state stamped after the placement tick, before the client got it.
    t.tick();
    stopped.tick = t.now;
    t.state(&a, stopped.clone());
    assert_eq!(t.shared.metrics.drops("in_flight"), 1);
    // The client applies the placement: protected, at its speed, then driving on.
    t.tick();
    let mut st = moved(&p, t.now, f64::from(p.speed_cms) / 2000.0, p.speed_cms);
    st.run_state = RunState::Protected;
    t.state(&a, st.clone());
    let _ = drive(&mut t, &a, &st, 20);
    t.run(&a, RunEventKind::End);
    t.tick();
    let r = run_results(&a.msgs());
    assert_eq!((r.len(), r[0].run_seq), (1, 2));
    assert!(r[0].flags.verified, "no offence after the respawn");
    assert_eq!(
        Offence::ALL
            .iter()
            .map(|o| t.shared.metrics.offences(*o))
            .sum::<u64>(),
        0
    );
}
