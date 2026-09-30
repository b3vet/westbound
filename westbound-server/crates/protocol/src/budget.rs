//! Bandwidth accounting (multiplayer handoff → Resource budget: 10 KB/s or less downstream per
//! player including framing, about 1 KB/s upstream). Sizes of the hot entries, WebSocket and
//! TLS overhead per frame, and a deterministic simulation that builds the real per-tick frames
//! for a scenario with `FrameBuilder` and counts the bytes.

use crate::frame::{encode_message_into, FrameBuilder};
use crate::messages::*;
use crate::types::*;
use crate::wire::Wire;
use crate::MSG_HEADER_LEN;

/// Downstream budget per player, bytes per second (10 KB/s, decimal).
pub const DOWNSTREAM_BUDGET_BYTES_PER_S: f64 = 10_000.0;
/// Upstream target per player, bytes per second (about 1 KB/s).
pub const UPSTREAM_TARGET_BYTES_PER_S: f64 = 1_000.0;
/// TLS 1.3 record overhead per WebSocket frame: 5-byte header + 1 content-type byte + 16-byte
/// AEAD tag (one record per frame).
pub const TLS_RECORD_OVERHEAD: usize = 22;
/// IPv4 + TCP headers with timestamps, per segment. Reported separately (not in the budget).
pub const TCP_IP_OVERHEAD: usize = 52;

/// Fixed entry sizes (checked against the encoder in tests).
pub const PLAYER_STATE_LEN: usize = 22;
pub const PLAYER_STATE_ENTRY_LEN: usize = 24;
pub const TRAFFIC_SPAWN_ENTRY_LEN: usize = 23;
pub const TRAFFIC_INTENT_ENTRY_LEN: usize = 14;
pub const CORRECTION_ENTRY_LEN: usize = 10;
pub const DESPAWN_ENTRY_LEN: usize = 2;

/// Which side sends the frame (client frames are masked: +4 bytes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    ClientToServer,
    ServerToClient,
}

/// WebSocket frame header length for a binary message of `payload_len` bytes.
pub fn ws_header_len(payload_len: usize, dir: Direction) -> usize {
    let base = if payload_len <= 125 {
        2
    } else if payload_len <= usize::from(u16::MAX) {
        4
    } else {
        10
    };
    base + if dir == Direction::ClientToServer {
        4
    } else {
        0
    }
}

/// Bytes on the wire for one protocol frame: frame + WebSocket header + TLS record overhead.
pub fn on_wire_len(frame_len: usize, dir: Direction) -> usize {
    frame_len + ws_header_len(frame_len, dir) + TLS_RECORD_OVERHEAD
}

/// A downstream traffic scenario for one player.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Scenario {
    pub tick_hz: u32,
    pub remote_players: u32,
    pub cars_in_aoi: u32,
    /// Cars within 100 m of the player (corrected at `near_hz`).
    pub near_cars: u32,
    pub near_hz: u32,
    /// Every other car in the area (corrected at `far_hz`, round-robin).
    pub far_hz: u32,
    pub spawns_per_s: u32,
    pub despawns_per_s: u32,
    pub intents_per_s: u32,
    pub score_syncs_per_s: u32,
    /// Seconds to simulate.
    pub seconds: u32,
}

impl Scenario {
    /// The spec's typical room: 7 remote players, 40 cars in the area of interest (normal
    /// density), 7 of them within 100 m at 5 Hz, the rest at 1 Hz; about one spawn and one
    /// despawn a second, two intents a second, one score sync a second.
    pub const TYPICAL: Scenario = Scenario {
        tick_hz: 20,
        remote_players: 7,
        cars_in_aoi: 40,
        near_cars: 7,
        near_hz: 5,
        far_hz: 1,
        spawns_per_s: 1,
        despawns_per_s: 1,
        intents_per_s: 2,
        score_syncs_per_s: 1,
        seconds: 10,
    };

    /// Rush hour: 14 vehicles/km/lane over 1.2 km and 4 lanes ≈ 67 cars, 11 within 100 m,
    /// more churn.
    pub const RUSH: Scenario = Scenario {
        tick_hz: 20,
        remote_players: 7,
        cars_in_aoi: 67,
        near_cars: 11,
        near_hz: 5,
        far_hz: 1,
        spawns_per_s: 3,
        despawns_per_s: 3,
        intents_per_s: 5,
        score_syncs_per_s: 2,
        seconds: 10,
    };
}

/// Result of `simulate`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Report {
    pub frames: u64,
    /// Protocol bytes (all frames).
    pub frame_bytes: u64,
    /// Protocol + WebSocket + TLS bytes.
    pub on_wire_bytes: u64,
    pub max_frame_len: usize,
    pub avg_frame_len: f64,
    pub frame_bytes_per_s: f64,
    /// Compare against `DOWNSTREAM_BUDGET_BYTES_PER_S`.
    pub on_wire_bytes_per_s: f64,
    /// Also counting one TCP/IP header per frame.
    pub with_tcp_ip_bytes_per_s: f64,
}

/// Events of a `rate_per_s` stream that land in tick `t` (evenly spread, integer math).
fn due(t: u32, rate_per_s: u32, tick_hz: u32) -> u32 {
    ((t + 1) * rate_per_s) / tick_hz - (t * rate_per_s) / tick_hz
}

fn sample_state(tick: u32) -> PlayerState {
    PlayerState {
        tick,
        s_mm: 12_345_678,
        d_cm: -175,
        heading_e4: 120,
        speed_cms: 6_500,
        lat_vel_cms: -30,
        yaw_rate_mrad_s: 15,
        steer_e4: -800,
        flags: PlayerFlags {
            headlights: true,
            ..PlayerFlags::default()
        },
        run_state: RunState::Driving,
    }
}

/// Builds every downstream frame of `sc` with `FrameBuilder` and counts the bytes.
/// Panics only if the scenario itself cannot be encoded (a bug in the scenario).
pub fn simulate(sc: &Scenario) -> Report {
    let mut fb = FrameBuilder::new();
    let ticks = sc.tick_hz * sc.seconds;
    let far_cars = sc.cars_in_aoi.saturating_sub(sc.near_cars);
    let near_period = (sc.tick_hz / sc.near_hz.max(1)).max(1);
    let far_period = (sc.tick_hz / sc.far_hz.max(1)).max(1);
    let (mut frames, mut frame_bytes, mut on_wire, mut max_frame) = (0u64, 0u64, 0u64, 0usize);

    for t in 0..ticks {
        {
            let mut b = fb.player_states().expect("player states");
            for p in 0..sc.remote_players {
                let entry = PlayerStateEntry {
                    player_id: p as u16,
                    state: sample_state(t),
                };
                b.push(&entry).expect("player state entry");
            }
        }
        {
            let mut b = fb.traffic_corrections(t).expect("corrections");
            let near = (0..sc.near_cars).filter(|i| (t + i) % near_period == 0);
            let far = (0..far_cars)
                .filter(|j| (t + j) % far_period == 0)
                .map(|j| j + sc.near_cars);
            for car in near.chain(far) {
                let e = CorrectionEntry {
                    car_id: car as u16,
                    s_mm: 12_400_000 + car * 30_000,
                    d_cm: 350,
                    speed_cms: 3_100,
                };
                b.push(&e).expect("correction");
            }
        }
        {
            let mut b = fb.traffic_spawns().expect("spawns");
            for k in 0..due(t, sc.spawns_per_s, sc.tick_hz) {
                let e = TrafficSpawnEntry {
                    car_id: (1000 + t + k) as u16,
                    vehicle: 3,
                    color: 5,
                    profile: 1,
                    lane: 2,
                    s_mm: 13_200_000,
                    d_cm: 700,
                    speed_cms: 3_000,
                    ..TrafficSpawnEntry::default()
                };
                b.push(&e).expect("spawn");
            }
        }
        {
            let mut b = fb.traffic_despawns().expect("despawns");
            for k in 0..due(t, sc.despawns_per_s, sc.tick_hz) {
                b.push(&((2000 + t + k) as u16)).expect("despawn");
            }
        }
        {
            let mut b = fb.traffic_intents().expect("intents");
            for k in 0..due(t, sc.intents_per_s, sc.tick_hz) {
                let e = TrafficIntentEntry {
                    car_id: (k + t) as u16,
                    kind: IntentKind::LaneChange,
                    start_tick: t,
                    move_start_tick: t + sc.tick_hz,
                    target_lane: 1,
                    duration_ms: 2_500,
                };
                b.push(&e).expect("intent");
            }
        }
        for _ in 0..due(t, sc.score_syncs_per_s, sc.tick_hz) {
            let sync = ServerMsg::ScoreSync(ScoreSync {
                tick: t,
                run_seq: 1,
                banked: 125_000,
                chain: 4_200,
                multiplier_milli: 12_500,
                lives: 2,
                crew_in_range: 2,
                flags: ScoreFlags::default(),
            });
            fb.push(&sync).expect("score sync");
        }
        let frame = fb.finish();
        frames += 1;
        frame_bytes += frame.len() as u64;
        on_wire += on_wire_len(frame.len(), Direction::ServerToClient) as u64;
        max_frame = max_frame.max(frame.len());
    }

    let secs = f64::from(sc.seconds.max(1));
    Report {
        frames,
        frame_bytes,
        on_wire_bytes: on_wire,
        max_frame_len: max_frame,
        avg_frame_len: frame_bytes as f64 / frames.max(1) as f64,
        frame_bytes_per_s: frame_bytes as f64 / secs,
        on_wire_bytes_per_s: on_wire as f64 / secs,
        with_tcp_ip_bytes_per_s: (on_wire + frames * TCP_IP_OVERHEAD as u64) as f64 / secs,
    }
}

/// Upstream bytes per second: one `PlayerState` frame per tick (with a `Ping` every
/// `ping_every_ticks` and `claims_per_s` single-car claims folded into those frames).
pub fn upstream_bytes_per_s(tick_hz: u32, ping_every_ticks: u32, claims_per_s: u32) -> f64 {
    let mut total = 0usize;
    for t in 0..tick_hz {
        let mut len = MSG_HEADER_LEN + PLAYER_STATE_LEN;
        if ping_every_ticks > 0 && t % ping_every_ticks == 0 {
            len += MSG_HEADER_LEN + Ping::default().wire_len();
        }
        let claim = ScoreClaim {
            cars: vec![ClaimCar::default()],
            ..ScoreClaim::default()
        };
        len += due(t, claims_per_s, tick_hz) as usize * (MSG_HEADER_LEN + claim.wire_len());
        total += on_wire_len(len, Direction::ClientToServer);
    }
    total as f64
}

/// Encoded size of one message including its 3-byte header.
pub fn message_len<M: crate::frame::Message>(m: &M) -> usize {
    m.encoded_len()
}

/// Checks that an actual encoding has the length `message_len` predicts.
pub fn encoded_len_matches<M: crate::frame::Message>(m: &M) -> bool {
    let mut v = Vec::new();
    encode_message_into(m, &mut v)
        .map(|n| n == v.len() && n == m.encoded_len())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_sizes_match_encoder() {
        assert_eq!(PlayerState::default().wire_len(), PLAYER_STATE_LEN);
        assert_eq!(
            PlayerStateEntry::default().wire_len(),
            PLAYER_STATE_ENTRY_LEN
        );
        assert_eq!(
            TrafficSpawnEntry::default().wire_len(),
            TRAFFIC_SPAWN_ENTRY_LEN
        );
        assert_eq!(
            TrafficIntentEntry::default().wire_len(),
            TRAFFIC_INTENT_ENTRY_LEN
        );
        assert_eq!(CorrectionEntry::default().wire_len(), CORRECTION_ENTRY_LEN);
        assert_eq!(0u16.wire_len(), DESPAWN_ENTRY_LEN);
        // Fixed payload sizes quoted in docs/PROTOCOL.md §4.
        assert_eq!(Welcome::default().wire_len(), 21);
        assert_eq!(Pong::default().wire_len(), 10);
        assert_eq!(Ping::default().wire_len(), 4);
        assert_eq!(HitReport::default().wire_len(), 8);
        assert_eq!(RunEvent::default().wire_len(), 5);
        assert_eq!(ScoreSync::default().wire_len(), 21);
        assert_eq!(ScoreEvent::default().wire_len(), 19);
        assert_eq!(RunResult::default().wire_len(), 32);
        assert_eq!(RoomSettings::default().wire_len(), 8);
        assert_eq!(RoomClock::default().wire_len(), 12);
        assert_eq!(RoomCrew::default().wire_len(), 6);
        assert_eq!(Identity::default().wire_len(), 11);
        assert_eq!(Member::default().wire_len(), 16);
        let snapshot = RoomSnapshot {
            code: Code("ABC234".into()),
            ..RoomSnapshot::default()
        };
        assert_eq!(snapshot.wire_len(), 39);
    }

    #[test]
    fn ws_headers() {
        assert_eq!(ws_header_len(125, Direction::ServerToClient), 2);
        assert_eq!(ws_header_len(126, Direction::ServerToClient), 4);
        assert_eq!(ws_header_len(70_000, Direction::ServerToClient), 10);
        assert_eq!(ws_header_len(25, Direction::ClientToServer), 6);
    }

    #[test]
    fn typical_room_fits_the_downstream_budget() {
        let r = simulate(&Scenario::TYPICAL);
        println!("typical: {r:?}");
        assert_eq!(r.frames, 200);
        assert!(
            r.on_wire_bytes_per_s <= DOWNSTREAM_BUDGET_BYTES_PER_S,
            "{r:?}"
        );
        // Pinned so docs/PROTOCOL.md stays accurate; update both together.
        assert_eq!(r.max_frame_len, 295);
        assert!(
            (r.avg_frame_len - 218.65).abs() < 1e-9,
            "{}",
            r.avg_frame_len
        );
    }

    #[test]
    fn rush_hour_fits_the_downstream_budget() {
        let r = simulate(&Scenario::RUSH);
        println!("rush: {r:?}");
        assert!(
            r.on_wire_bytes_per_s <= DOWNSTREAM_BUDGET_BYTES_PER_S,
            "{r:?}"
        );
    }

    #[test]
    fn upstream_is_about_one_kilobyte_per_second() {
        let up = upstream_bytes_per_s(20, 40, 2);
        println!("upstream: {up}");
        assert!(up <= UPSTREAM_TARGET_BYTES_PER_S * 1.2, "{up}");
    }

    #[test]
    fn predicted_lengths_match() {
        assert!(encoded_len_matches(&ServerMsg::ScoreSync(
            ScoreSync::default()
        )));
        let hello = ClientMsg::Hello(Hello {
            access_token: AccessToken("abc".into()),
            ..Hello::default()
        });
        assert!(encoded_len_matches(&hello));
        assert_eq!(message_len(&hello), 3 + 2 + 4 + 32 + 2 + 3);
    }
}
