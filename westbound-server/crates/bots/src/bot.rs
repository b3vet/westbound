//! A scripted room player (N5.1), transport-free: it reads server frames and writes the
//! `PlayerState` a client would send each room tick. It drives the loop in its lane at a
//! set speed (accelerating like a car, never faster than `accel_mps2`), takes the server's
//! placements (its own id in `player_states`), keeps a server-tick estimate from the room
//! snapshot and `Pong`s, keeps a mirror of the traffic it is streamed (N4.2,
//! [`TrafficMirror`]), and records what it saw for the tests. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Players, Testing → Netcode harness ("bots drive
//! scripted paths"); docs/PROTOCOL.md §1 (clock sync), §4.

use std::collections::HashMap;
use std::sync::Arc;

use protocol::budget::{on_wire_len, Direction};
use protocol::{
    decode_server_frame, ClientMsg, Code, DecodeError, ErrorMsg, LobbyEvent, Ping, PlayerFlags,
    PlayerState, RoomEvent, RoomLeftReason, RoomSnapshot, RunResult, RunState, ServerMsg,
};
use sim::map::LoopMap;

use crate::traffic::TrafficMirror;

const MS_PER_S: f64 = 1_000.0;
const MM_PER_M: f64 = 1_000.0;
const CM_PER_M: f64 = 100.0;
const FRACTION_ONE: f64 = 65_536.0;

/// How a bot drives.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BotConfig {
    /// Cruise speed (m/s).
    pub speed_mps: f64,
    /// Acceleration toward the cruise speed (m/s²), well inside a car's.
    pub accel_mps2: f64,
    /// Room tick rate (the server's `Welcome.tick_rate_hz`).
    pub tick_rate_hz: f64,
}

impl Default for BotConfig {
    fn default() -> Self {
        Self {
            speed_mps: 40.0,
            accel_mps2: 4.0,
            tick_rate_hz: 20.0,
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
        let dv = (self.cfg.speed_mps - self.speed_mps)
            .clamp(-self.cfg.accel_mps2 * dt, self.cfg.accel_mps2 * dt);
        let v0 = self.speed_mps;
        self.speed_mps += dv;
        self.s_m = self.map.wrap_m(self.s_m + (v0 + self.speed_mps) * 0.5 * dt);
        let tick = self.server_now(now_ms)?.floor();
        if tick < 0.0 {
            return None;
        }
        let tick = tick as u32;
        if self.last_sent.is_some_and(|t| t == tick) {
            return None;
        }
        self.last_sent = Some(tick);
        Some(PlayerState {
            tick,
            s_mm: ((self.s_m * MM_PER_M).round() as u32) % self.map.length_mm(),
            d_cm: (self.d_m * CM_PER_M).round() as i16,
            speed_cms: (self.speed_mps * CM_PER_M).round() as u16,
            flags: PlayerFlags::default(),
            run_state: RunState::Driving,
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
