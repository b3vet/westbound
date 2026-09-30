//! A scripted room player (N5.1), transport-free: it reads server frames and writes the
//! `PlayerState` a client would send each room tick. It drives the loop in its lane at a
//! set speed (accelerating like a car, never faster than `accel_mps2`), takes the server's
//! placements (its own id in `player_states`), keeps a server-tick estimate from the room
//! snapshot and `Pong`s, keeps a mirror of the traffic it is streamed (N4.2,
//! [`TrafficMirror`]), and records what it saw for the tests. N6.1: with
//! [`DriveMode::Traffic`] it drives through that traffic ([`TrafficDriver`]), and with a
//! [`ClaimMode`] it claims what the client's rules detect on it ([`Scorer`]); its states
//! describe the car at exactly their tick. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Players, Testing → Netcode harness ("bots drive
//! scripted paths"); docs/PROTOCOL.md §1 (clock sync), §4.

use std::collections::HashMap;
use std::sync::Arc;

use protocol::budget::{on_wire_len, Direction};
use protocol::{
    decode_server_frame, ClientMsg, Code, DecodeError, ErrorMsg, HitReport, HitTarget, LobbyEvent,
    Ping, PlayerFlags, PlayerState, RoomEvent, RoomLeftReason, RoomSnapshot, RunResult, RunState,
    ScoreEvent, ScoreEventKind, ScoreSync, ServerMsg,
};
use sim::map::LoopMap;

use crate::driver::{Bodies, ClaimMode, DriveMode, Scorer, TrafficDriver};
use crate::link::LinkSim;
use crate::traffic::TrafficMirror;

const MS_PER_S: f64 = 1_000.0;
const MM_PER_M: f64 = 1_000.0;
const CM_PER_M: f64 = 100.0;
const FRACTION_ONE: f64 = 65_536.0;
/// Lateral speed of the traffic driver's lane changes and wandering (m/s).
const LATERAL_MPS: f64 = 3.0;
/// The game's lives, ghost period (2 s) and spawn protection (3 s) at 20 Hz, the default
/// car body and the hull inset (data/tuning: lives, traffic).
const LIVES: u8 = 2;
const GHOST_TICKS: u32 = 40;
const PROTECTION_TICKS: u32 = 60;
const PLAYER_LENGTH_M: f64 = 4.5;
const PLAYER_WIDTH_M: f64 = 1.9;
const INSET_M: f64 = 0.08;
const HIT_LOOK_M: f64 = 12.0;
/// How hard a crashed-out car stops (m/s²).
const CRASH_DECEL_MPS2: f64 = 10.0;

/// How a bot drives.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BotConfig {
    /// Cruise speed (m/s).
    pub speed_mps: f64,
    /// Acceleration toward the cruise speed (m/s²), well inside a car's.
    pub accel_mps2: f64,
    /// Room tick rate (the server's `Welcome.tick_rate_hz`).
    pub tick_rate_hz: f64,
    /// N6.1: straight in its lane, or through traffic.
    pub drive: DriveMode,
    /// N6.1: no claims, honest ones, or a cheat.
    pub claims: ClaimMode,
    /// N6.1: the connection's simulated conditions (`None`: as is).
    pub link: Option<LinkSim>,
    /// Seeds the driver's choices, the cheats and the link.
    pub seed: u64,
}

impl Default for BotConfig {
    fn default() -> Self {
        Self {
            speed_mps: 40.0,
            accel_mps2: 4.0,
            tick_rate_hz: 20.0,
            drive: DriveMode::Lane,
            claims: ClaimMode::Off,
            link: None,
            seed: 1,
        }
    }
}

/// What a bot saw (for assertions).
#[derive(Debug, Default, Clone)]
pub struct Seen {
    pub frames: u64,
    pub snapshots: u32,
    pub last_snapshot: Option<RoomSnapshot>,
    pub placements: u32,
    /// Other players: id → the latest tick relayed and how many states.
    pub others: HashMap<u16, (u32, u64)>,
    pub room_events: Vec<RoomEvent>,
    pub errors: Vec<ErrorMsg>,
    pub run_results: Vec<RunResult>,
    pub room_left: Option<RoomLeftReason>,
    pub pongs: u32,
    /// Largest frame (bytes) and total bytes received.
    pub max_frame: usize,
    pub bytes: u64,
    /// Bytes on the wire with WebSocket and TLS framing (docs/PROTOCOL.md §11).
    pub wire_bytes: u64,
    /// The traffic the bot has been told about (N4.2).
    pub traffic: TrafficMirror,
    /// N6.1: `score_sync`s received and the latest; `score_event`s received.
    pub score_syncs: u32,
    pub last_sync: Option<ScoreSync>,
    pub score_events: Vec<ScoreEvent>,
}

impl Seen {
    /// Claims the server rejected (`score_event.claim_rejected`).
    pub fn claims_rejected(&self) -> usize {
        self.score_events
            .iter()
            .filter(|e| e.kind == ScoreEventKind::ClaimRejected)
            .count()
    }
}

pub struct RoomBot {
    pub cfg: BotConfig,
    map: Arc<LoopMap>,
    pub room_id: Option<u32>,
    pub code: Option<Code>,
    pub player_id: Option<u16>,
    /// Server tick = local ms × rate / 1000 + offset.
    offset: Option<f64>,
    best_rtt_ms: Option<f64>,
    /// Local ms of the snapshot (pongs for earlier pings carry another clock).
    joined_ms: Option<u64>,
    s_m: f64,
    d_m: f64,
    speed_mps: f64,
    last_ms: Option<u64>,
    last_sent: Option<u32>,
    last_placement: Option<u32>,
    pub seen: Seen,
    /// N6.1: lateral speed (m/s) of the last step, the driver, the scorer.
    lat_vel: f64,
    pub driver: TrafficDriver,
    /// Forward distance driven (m) and time driving (s) (diagnostics).
    pub odometer_m: f64,
    pub driven_s: f64,
    /// N6.1: the client's own hits (it reports them: the client is authoritative for its
    /// lives), its lives, the ghost period after a hit and the spawn protection (ticks).
    pub hits_reported: u32,
    lives: u8,
    ghost_until: u32,
    protected_until: u32,
    pending: Vec<ClientMsg>,
    pub scorer: Scorer,
    bodies: Bodies,
}

impl RoomBot {
    pub fn new(map: Arc<LoopMap>, cfg: BotConfig) -> Self {
        Self {
            cfg,
            map,
            room_id: None,
            code: None,
            player_id: None,
            offset: None,
            best_rtt_ms: None,
            joined_ms: None,
            s_m: 0.0,
            d_m: 0.0,
            speed_mps: 0.0,
            last_ms: None,
            last_sent: None,
            last_placement: None,
            seen: Seen::default(),
            lat_vel: 0.0,
            odometer_m: 0.0,
            driven_s: 0.0,
            hits_reported: 0,
            lives: LIVES,
            ghost_until: 0,
            protected_until: 0,
            pending: Vec::new(),
            driver: TrafficDriver::new(cfg.seed),
            scorer: Scorer::new(cfg.claims, cfg.seed),
            bodies: Bodies::builtin(),
        }
    }

    pub fn in_room(&self) -> bool {
        self.player_id.is_some() && self.seen.room_left.is_none()
    }

    /// Where the bot is (m, wrapped) and its lateral offset (m).
    pub fn position(&self) -> (f64, f64) {
        (self.s_m, self.d_m)
    }

    /// Forgets the room (a new connection starts clean; `seen` stays).
    pub fn reset_room(&mut self) {
        self.room_id = None;
        self.player_id = None;
        self.offset = None;
        self.best_rtt_ms = None;
        self.joined_ms = None;
        self.last_sent = None;
        self.last_ms = None;
        self.seen.room_left = None;
    }

    fn rate_per_ms(&self) -> f64 {
        self.cfg.tick_rate_hz / MS_PER_S
    }

    /// The estimated room tick now (fractional).
    pub fn server_now(&self, now_ms: u64) -> Option<f64> {
        self.offset.map(|o| now_ms as f64 * self.rate_per_ms() + o)
    }

    /// A clock-sync ping (`client_time_ms` = local ms, wrapping).
    pub fn ping(&self, now_ms: u64) -> ClientMsg {
        ClientMsg::Ping(Ping {
            client_time_ms: now_ms as u32,
        })
    }

    /// Reads one server frame.
    pub fn on_frame(&mut self, bytes: &[u8], now_ms: u64) -> Result<(), DecodeError> {
        self.seen.frames += 1;
        self.seen.bytes += bytes.len() as u64;
        self.seen.wire_bytes += on_wire_len(bytes.len(), Direction::ServerToClient) as u64;
        self.seen.max_frame = self.seen.max_frame.max(bytes.len());
        let own_s_mm = ((self.s_m * MM_PER_M).round() as u32) % self.map.length_mm();
        self.seen.traffic.begin_frame();
        for msg in decode_server_frame(bytes)? {
            if let ServerMsg::RoomSnapshot(_) = &msg {
                self.seen.traffic.reset();
            }
            if !self.seen.traffic.on_msg(&msg, own_s_mm, &self.map) {
                self.on_msg(msg, now_ms);
            }
        }
        self.seen.traffic.end_frame();
        Ok(())
    }

    fn on_msg(&mut self, msg: ServerMsg, now_ms: u64) {
        match msg {
            ServerMsg::RoomSnapshot(s) => {
                self.room_id = Some(s.room_id);
                self.code = Some(s.code.clone());
                self.player_id = Some(s.you);
                // Sent in the middle of its tick; the one-way delay is unknown here.
                self.offset = Some(f64::from(s.tick) + 0.5 - now_ms as f64 * self.rate_per_ms());
                self.best_rtt_ms = None;
                self.joined_ms = Some(now_ms);
                self.seen.snapshots += 1;
                self.seen.last_snapshot = Some(s);
            }
            ServerMsg::PlayerStates(ps) => {
                for e in ps.players {
                    if Some(e.player_id) == self.player_id {
                        self.place(&e.state);
                    } else {
                        let entry = self.seen.others.entry(e.player_id).or_insert((0, 0));
                        entry.0 = e.state.tick;
                        entry.1 += 1;
                    }
                }
            }
            ServerMsg::Pong(p) => {
                self.seen.pongs += 1;
                let sent = u64::from(p.client_time_ms);
                let local = now_ms as u32 as u64;
                let Some(joined) = self.joined_ms else {
                    return;
                };
                if now_ms < joined || (sent as i64) < (joined as u32 as i64) {
                    return;
                }
                let rtt = local.wrapping_sub(sent) as u32 as f64;
                if self.best_rtt_ms.is_none_or(|b| rtt <= b) {
                    self.best_rtt_ms = Some(rtt);
                    let server =
                        f64::from(p.server_tick) + f64::from(p.tick_fraction) / FRACTION_ONE;
                    let at_receive = server + rtt * 0.5 * self.rate_per_ms();
                    self.offset = Some(at_receive - now_ms as f64 * self.rate_per_ms());
                }
            }
            ServerMsg::RoomEvent(e) => self.seen.room_events.push(e),
            ServerMsg::Error(e) => self.seen.errors.push(e),
            ServerMsg::RunResult(r) => self.seen.run_results.push(r),
            ServerMsg::ScoreSync(s) => {
                self.seen.score_syncs += 1;
                self.seen.last_sync = Some(s);
            }
            ServerMsg::ScoreEvent(e) => self.seen.score_events.push(e),
            ServerMsg::LobbyEvent(LobbyEvent::RoomLeft(l)) => {
                self.seen.room_left = Some(l.reason);
                self.player_id = None;
            }
            _ => {}
        }
    }

    /// A server placement: jump there (once per placement tick) at its speed.
    fn place(&mut self, st: &PlayerState) {
        if self.last_placement == Some(st.tick) {
            return;
        }
        self.last_placement = Some(st.tick);
        self.seen.placements += 1;
        self.s_m = f64::from(st.s_mm) / MM_PER_M;
        self.d_m = f64::from(st.d_cm) / CM_PER_M;
        self.speed_mps = f64::from(st.speed_cms) / CM_PER_M;
        self.lat_vel = 0.0;
        self.scorer.restart();
        if self.lives == 0 {
            self.lives = LIVES;
        }
        self.protected_until = st.tick.wrapping_add(PROTECTION_TICKS);
    }

    /// N6.1: the claims its rules made since the last call.
    pub fn take_claims(&mut self) -> Vec<ClientMsg> {
        let mut out: Vec<ClientMsg> = self.pending.drain(..).collect();
        out.extend(self.scorer.out.drain(..).map(ClientMsg::ScoreClaim));
        out
    }

    /// The client's hit detection (Traffic mode): its hull touching a mirrored car at the
    /// state's tick is a hit, reported with the lives left; nothing more for the ghost
    /// period, nothing during spawn protection.
    fn detect_hit(&mut self, tick: u32, s_m: f64, d: f64) {
        if self.lives == 0
            || (tick.wrapping_sub(self.ghost_until) as i32) < 0
            || (tick.wrapping_sub(self.protected_until) as i32) < 0
        {
            return;
        }
        let tick_dt = 1.0 / self.cfg.tick_rate_hz;
        let (p_hl, p_hw) = (
            PLAYER_LENGTH_M * 0.5 - INSET_M,
            PLAYER_WIDTH_M * 0.5 - INSET_M,
        );
        let hit = self.seen.traffic.cars.iter().find_map(|(&id, car)| {
            let c = self
                .seen
                .traffic
                .car_at(id, f64::from(tick), &self.map, tick_dt)?;
            let ds = self.map.signed_delta_m(s_m, c.s_m);
            if ds.abs() > HIT_LOOK_M {
                return None;
            }
            let (length, width) = self.bodies.of(car.vehicle);
            let clr = sim::scoring::hull::clearance(
                0.0,
                d,
                0.0,
                p_hl,
                p_hw,
                ds,
                c.d,
                c.v_lat.atan2(c.v),
                length * 0.5 - INSET_M,
                width * 0.5 - INSET_M,
            );
            (clr <= 0.0).then_some(id)
        });
        if let Some(car_id) = hit {
            self.lives -= 1;
            self.hits_reported += 1;
            self.ghost_until = tick.wrapping_add(GHOST_TICKS);
            self.pending.push(ClientMsg::HitReport(HitReport {
                tick,
                target: HitTarget::Traffic,
                car_id,
                lives_left: self.lives,
            }));
        }
    }

    /// Advances the car to `now_ms` and returns the state for the current room tick (at
    /// most one per tick; none before the first placement).
    pub fn step(&mut self, now_ms: u64) -> Option<PlayerState> {
        let dt = self
            .last_ms
            .map_or(0.0, |t| now_ms.saturating_sub(t) as f64 / MS_PER_S);
        self.last_ms = Some(now_ms);
        if self.last_placement.is_none() || !self.in_room() {
            return None;
        }
        let now_tick = self.server_now(now_ms)?;
        let v0 = self.speed_mps;
        match self.cfg.drive {
            DriveMode::Lane => {
                let dv = (self.cfg.speed_mps - self.speed_mps)
                    .clamp(-self.cfg.accel_mps2 * dt, self.cfg.accel_mps2 * dt);
                self.speed_mps += dv;
            }
            DriveMode::Traffic => {
                let tick_dt = 1.0 / self.cfg.tick_rate_hz;
                let (acc, target_d) = self.driver.control(
                    self.s_m,
                    self.d_m,
                    self.speed_mps,
                    self.cfg.speed_mps,
                    self.cfg.accel_mps2,
                    now_tick,
                    dt,
                    &self.seen.traffic,
                    &self.bodies,
                    &self.map,
                    tick_dt,
                );
                // Crashed out (no lives): the car stops until the respawn placement.
                let acc = if self.lives == 0 {
                    -CRASH_DECEL_MPS2
                } else {
                    acc
                };
                self.speed_mps = (self.speed_mps + acc * dt).max(0.0);
                let step = LATERAL_MPS * dt;
                let dd = (target_d - self.d_m).clamp(-step, step);
                self.d_m += dd;
                self.lat_vel = if dt > 0.0 { dd / dt } else { 0.0 };
            }
        }
        self.s_m = self.map.wrap_m(self.s_m + (v0 + self.speed_mps) * 0.5 * dt);
        self.odometer_m += (v0 + self.speed_mps) * 0.5 * dt;
        self.driven_s += dt;
        let tick = now_tick.floor();
        if tick < 0.0 {
            return None;
        }
        // The state describes the car at exactly its tick: carried back from now.
        let back_s = (now_tick - tick) / self.cfg.tick_rate_hz;
        let tick = tick as u32;
        if self.last_sent.is_some_and(|t| t == tick) {
            return None;
        }
        self.last_sent = Some(tick);
        let s_at = self.map.wrap_m(self.s_m - self.speed_mps * back_s);
        let d_at = self.d_m - self.lat_vel * back_s;
        let s_mm = ((s_at * MM_PER_M).round() as u32) % self.map.length_mm();
        let tick_dt = 1.0 / self.cfg.tick_rate_hz;
        if self.cfg.drive == DriveMode::Traffic {
            self.detect_hit(tick, s_at, d_at);
        }
        // A crashed-out car claims nothing until its respawn.
        if self.lives > 0 {
            self.scorer.step(
                tick,
                s_mm,
                d_at,
                self.speed_mps,
                &self.seen.traffic,
                &self.bodies,
                &self.map,
                tick_dt,
            );
        }
        Some(PlayerState {
            tick,
            s_mm,
            d_cm: (d_at * CM_PER_M).round() as i16,
            speed_cms: (self.speed_mps * CM_PER_M).round() as u16,
            lat_vel_cms: (self.lat_vel * CM_PER_M).round() as i16,
            flags: PlayerFlags::default(),
            run_state: if self.lives == 0 {
                RunState::Crashed
            } else if (tick.wrapping_sub(self.protected_until) as i32) < 0 {
                RunState::Protected
            } else {
                RunState::Driving
            },
            ..PlayerState::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::{
        encode_frame, Density, PlayerStateEntry, PlayerStates, RoomClock, RoomSettings, TimeMode,
        Visibility,
    };

    fn map() -> Arc<LoopMap> {
        Arc::new(
            LoopMap::from_json(include_str!("../../../data/maps/loop_v1.json")).expect("loop_v1"),
        )
    }

    fn snapshot(tick: u32, you: u16) -> ServerMsg {
        ServerMsg::RoomSnapshot(RoomSnapshot {
            room_id: 7,
            code: Code("ABC234".into()),
            settings: RoomSettings {
                visibility: Visibility::Private,
                max_players: 8,
                density: Density::Normal,
                time_mode: TimeMode::Cycle,
                fixed_cycle_ms: 0,
            },
            tick,
            clock: RoomClock::default(),
            you,
            members: vec![protocol::Member {
                identity: protocol::Identity {
                    display_name: protocol::DisplayName("Bot".into()),
                    ..Default::default()
                },
                ..Default::default()
            }],
            crews: vec![],
        })
    }

    #[test]
    fn takes_placements_and_sends_one_state_per_tick() {
        let mut b = RoomBot::new(map(), BotConfig::default());
        let f = encode_frame(&[snapshot(100, 3)]).unwrap();
        b.on_frame(&f, 10_000).unwrap();
        assert_eq!(b.player_id, Some(3));
        assert!(b.step(10_000).is_none(), "no placement yet");
        let placed = PlayerState {
            tick: 100,
            s_mm: 24_999_000,
            d_cm: 710,
            speed_cms: 3_000,
            run_state: RunState::Protected,
            ..PlayerState::default()
        };
        let f = encode_frame(&[ServerMsg::PlayerStates(PlayerStates {
            players: vec![
                PlayerStateEntry {
                    player_id: 3,
                    state: placed.clone(),
                },
                PlayerStateEntry {
                    player_id: 9,
                    state: placed,
                },
            ],
        })])
        .unwrap();
        b.on_frame(&f, 10_010).unwrap();
        b.on_frame(&f, 10_020).unwrap();
        assert_eq!(b.seen.placements, 1, "a placement applies once");
        assert_eq!(b.seen.others.get(&9).map(|o| o.1), Some(2));
        let a = b.step(10_050).expect("tick 101");
        assert_eq!(a.tick, 101);
        assert!(b.step(10_060).is_none(), "same tick");
        let c = b.step(10_100).expect("tick 102");
        assert_eq!(c.tick, 102);
        // Crossed the seam: s wrapped, speed ramping up gently.
        assert!(c.s_mm < 5_000, "{}", c.s_mm);
        assert!(c.speed_cms > 3_000 && c.speed_cms < 3_050);
    }
}
