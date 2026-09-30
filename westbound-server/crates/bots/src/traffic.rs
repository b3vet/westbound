//! A bot's copy of the room traffic it has been told about (N4.2), and the checks a client
//! relies on. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Traffic → What the server sends;
//! docs/SERVER.md → "Traffic streaming (N4.2)" (the exact schedule this checks).
//!
//! The mirror applies `traffic_spawn`, `traffic_despawn`, `traffic_intent` and
//! `traffic_correction` as a client would (no local simulation: a car's state is its last
//! spawn or correction), counts entries and bytes per message type, and records every
//! broken promise in `violations`:
//!
//! - a spawn for a car it already has; a despawn, intent or correction for one it does not;
//! - a car spawned or given an intent without a correction for it in the same frame (the
//!   frame's tick and the lane count come from it);
//! - a frame whose traffic messages are out of order (despawns, spawns, intents,
//!   corrections);
//! - a lane change whose move starts less than `min_signal_ticks` after its start;
//! - a correction batch older than the previous one;
//! - a car id spawned again within `id_hold_ticks` of its despawn as a different car
//!   (vehicle, color or profile changed): the server's 30 s id hold, as far as a client
//!   can tell (the same car coming back into the area is fine).
//!
//! It also measures the largest gap between two corrections of a car that stayed within
//! `near_m` of the bot (5 Hz: 4 ticks) and of any car (1 Hz: 20 ticks).

use std::collections::HashMap;

use protocol::{
    CorrectionEntry, IntentKind, LaneChangePhase, Message, ServerMsg, TrafficFlags,
    TrafficIntentEntry, TrafficSpawnEntry,
};
use sim::map::LoopMap;

/// What the mirror checks against (the server's defaults).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MirrorRules {
    /// Lane changes signal at least this many ticks (1.0 s at 20 Hz).
    pub min_signal_ticks: u32,
    /// A car id is not reused for another car within this many ticks (30 s).
    pub id_hold_ticks: u32,
    /// Gaps are measured separately for cars within this distance of the bot (m); well
    /// inside the server's 100 m, since the bot's position runs ahead of the one the server
    /// used by its states' delay.
    pub near_m: f64,
}

impl Default for MirrorRules {
    fn default() -> Self {
        Self {
            min_signal_ticks: 20,
            id_hold_ticks: 600,
            near_m: 50.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MirrorCar {
    pub vehicle: u8,
    pub color: u8,
    pub profile: u8,
    pub lane: u8,
    pub s_mm: u32,
    pub d_cm: i16,
    pub speed_cms: u16,
    pub lc_phase: LaneChangePhase,
    pub lc_target_lane: u8,
    pub lc_move_start_tick: u32,
    pub lc_duration_ms: u16,
    pub flags: TrafficFlags,
    /// Tick of the last correction (0 until the first).
    pub corrected_tick: u32,
    /// The last correction was within `near_m` of the bot.
    pub near: bool,
}

/// A mirrored car carried to a tick (`TrafficMirror::car_at`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CarNow {
    /// Wrapped s (m).
    pub s_m: f64,
    pub d: f64,
    pub v: f64,
    pub v_lat: f64,
    /// The driving lane at d (0 = next to the median).
    pub lane: i32,
}

/// Counts per message type.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TrafficCounts {
    pub spawn_msgs: u64,
    pub spawns: u64,
    pub despawn_msgs: u64,
    pub despawns: u64,
    pub intent_msgs: u64,
    pub intents: u64,
    pub lane_changes: u64,
    pub cancels: u64,
    pub hazards: u64,
    pub hard_brakes: u64,
    pub correction_msgs: u64,
    pub corrections: u64,
    /// Encoded bytes (headers included) of each kind.
    pub spawn_bytes: u64,
    pub despawn_bytes: u64,
    pub intent_bytes: u64,
    pub correction_bytes: u64,
}

impl TrafficCounts {
    pub fn bytes(&self) -> u64 {
        self.spawn_bytes + self.despawn_bytes + self.intent_bytes + self.correction_bytes
    }
}

#[derive(Debug, Default, Clone)]
pub struct TrafficMirror {
    pub rules: MirrorRules,
    pub cars: HashMap<u16, MirrorCar>,
    /// Despawned ids: (tick of the despawn as the bot saw it, vehicle, color, profile).
    gone: HashMap<u16, (u32, u8, u8, u8)>,
    /// The latest correction batch's tick.
    pub last_tick: Option<u32>,
    pub counts: TrafficCounts,
    pub violations: Vec<String>,
    /// Shortest lane-change lead seen (move start − start, ticks).
    pub min_lead_ticks: Option<u32>,
    /// Largest correction gap (ticks) of a car near the bot at both corrections, and of
    /// any car.
    pub max_near_gap: u32,
    pub max_gap: u32,
    // This frame (for the same-frame correction rule).
    frame_needs: Vec<u16>,
    frame_corrected: Vec<u16>,
    /// The last traffic message's place in the order (despawn 0 … correction 3).
    frame_rank: u8,
}

impl TrafficMirror {
    pub fn new(rules: MirrorRules) -> Self {
        Self {
            rules,
            ..Self::default()
        }
    }

    /// A room snapshot: the client starts over (every car in its area is sent again).
    pub fn reset(&mut self) {
        self.cars.clear();
        self.gone.clear();
        self.last_tick = None;
    }

    fn violation(&mut self, what: String) {
        // Keep the first few; a broken stream would repeat forever.
        if self.violations.len() < 64 {
            self.violations.push(what);
        }
    }

    pub fn begin_frame(&mut self) {
        self.frame_needs.clear();
        self.frame_corrected.clear();
        self.frame_rank = 0;
    }

    fn in_order(&mut self, rank: u8) {
        if rank < self.frame_rank {
            self.violation(format!(
                "traffic messages out of order (a rank {rank} message after rank {})",
                self.frame_rank
            ));
        }
        self.frame_rank = rank;
    }

    pub fn end_frame(&mut self) {
        for i in 0..self.frame_needs.len() {
            let id = self.frame_needs[i];
            if !self.frame_corrected.contains(&id) {
                self.violation(format!(
                    "car {id} spawned or given an intent without a correction in its frame"
                ));
            }
        }
    }

    /// Applies one server message. `own_s_mm`: the bot's position (for the near gaps).
    /// Returns true for a traffic message.
    pub fn on_msg(&mut self, msg: &ServerMsg, own_s_mm: u32, map: &LoopMap) -> bool {
        let len = msg.encoded_len() as u64;
        match msg {
            ServerMsg::TrafficSpawn(m) => {
                self.in_order(1);
                self.counts.spawn_msgs += 1;
                self.counts.spawn_bytes += len;
                for e in &m.cars {
                    self.spawn(e);
                }
            }
            ServerMsg::TrafficDespawn(m) => {
                self.in_order(0);
                self.counts.despawn_msgs += 1;
                self.counts.despawn_bytes += len;
                for &id in &m.car_ids {
                    self.counts.despawns += 1;
                    match self.cars.remove(&id) {
                        Some(c) => {
                            let t = self.last_tick.unwrap_or(0);
                            self.gone.insert(id, (t, c.vehicle, c.color, c.profile));
                        }
                        None => self.violation(format!("despawn of unknown car {id}")),
                    }
                }
            }
            ServerMsg::TrafficIntent(m) => {
                self.in_order(2);
                self.counts.intent_msgs += 1;
                self.counts.intent_bytes += len;
                for e in &m.intents {
                    self.intent(e);
                }
            }
            ServerMsg::TrafficCorrection(m) => {
                self.in_order(3);
                self.counts.correction_msgs += 1;
                self.counts.correction_bytes += len;
                if let Some(t) = self.last_tick {
                    if (m.tick.wrapping_sub(t) as i32) < 0 {
                        self.violation(format!("correction tick {} after {t}", m.tick));
                    }
                }
                self.last_tick = Some(m.tick);
                for e in &m.cars {
                    self.correct(m.tick, e, own_s_mm, map);
                }
            }
            _ => return false,
        }
        true
    }

    fn spawn(&mut self, e: &TrafficSpawnEntry) {
        self.counts.spawns += 1;
        self.frame_needs.push(e.car_id);
        if self.cars.contains_key(&e.car_id) {
            self.violation(format!("spawn of car {} it already has", e.car_id));
        }
        if let Some(&(t, vehicle, color, profile)) = self.gone.get(&e.car_id) {
            let other = (vehicle, color, profile) != (e.vehicle, e.color, e.profile);
            let age = self.last_tick.map_or(0, |now| now.wrapping_sub(t));
            if other && age < self.rules.id_hold_ticks {
                self.violation(format!(
                    "car id {} reused for another car {age} ticks after its despawn",
                    e.car_id
                ));
            }
        }
        if e.lc_phase != LaneChangePhase::None && e.lc_duration_ms == 0 {
            self.violation(format!(
                "car {} spawned mid lane change without a duration",
                e.car_id
            ));
        }
        self.cars.insert(
            e.car_id,
            MirrorCar {
                vehicle: e.vehicle,
                color: e.color,
                profile: e.profile,
                lane: e.lane,
                s_mm: e.s_mm,
                d_cm: e.d_cm,
                speed_cms: e.speed_cms,
                lc_phase: e.lc_phase,
                lc_target_lane: e.lc_target_lane,
                lc_move_start_tick: e.lc_move_start_tick,
                lc_duration_ms: e.lc_duration_ms,
                flags: e.flags,
                corrected_tick: 0,
                near: false,
            },
        );
    }

    fn intent(&mut self, e: &TrafficIntentEntry) {
        self.counts.intents += 1;
        self.frame_needs.push(e.car_id);
        match e.kind {
            IntentKind::LaneChange => {
                self.counts.lane_changes += 1;
                let lead = e.move_start_tick.wrapping_sub(e.start_tick);
                self.min_lead_ticks = Some(self.min_lead_ticks.map_or(lead, |m| m.min(lead)));
                if lead < self.rules.min_signal_ticks || lead > u32::MAX / 2 {
                    self.violation(format!(
                        "car {} lane change moves {lead} ticks after its signal",
                        e.car_id
                    ));
                }
            }
            IntentKind::Cancel => self.counts.cancels += 1,
            IntentKind::Hazard => self.counts.hazards += 1,
            IntentKind::HardBrake => self.counts.hard_brakes += 1,
            IntentKind::Horn => {}
        }
        match self.cars.get_mut(&e.car_id) {
            Some(c) => match e.kind {
                IntentKind::LaneChange => {
                    c.lc_phase = LaneChangePhase::Signaling;
                    c.lc_target_lane = e.target_lane;
                    c.lc_move_start_tick = e.move_start_tick;
                    c.lc_duration_ms = e.duration_ms;
                }
                IntentKind::Cancel => c.lc_phase = LaneChangePhase::None,
                IntentKind::Hazard => c.flags.hazard = true,
                IntentKind::HardBrake => c.flags.braking = true,
                IntentKind::Horn => {}
            },
            None => self.violation(format!("intent for unknown car {}", e.car_id)),
        }
    }

    fn correct(&mut self, tick: u32, e: &CorrectionEntry, own_s_mm: u32, map: &LoopMap) {
        self.counts.corrections += 1;
        self.frame_corrected.push(e.car_id);
        let near_m = self.rules.near_m;
        let Some(c) = self.cars.get_mut(&e.car_id) else {
            self.violation(format!("correction for unknown car {}", e.car_id));
            return;
        };
        let near = (map.signed_delta_mm(own_s_mm, e.s_mm).abs() as f64) < near_m * 1_000.0;
        if c.corrected_tick != 0 {
            let gap = tick.wrapping_sub(c.corrected_tick);
            if gap < u32::MAX / 2 {
                self.max_gap = self.max_gap.max(gap);
                if near && c.near {
                    self.max_near_gap = self.max_near_gap.max(gap);
                }
            }
        }
        c.corrected_tick = tick;
        c.near = near;
        c.s_mm = e.s_mm;
        c.d_cm = e.d_cm;
        c.speed_cms = e.speed_cms;
    }

    /// Car `id` at room tick `tick` (fractional), as a client without its own traffic model
    /// would place it (N6.1: the bots' honest claims): its last correction carried on at its
    /// speed, and a lane change on its intent's curve (docs/SERVER.md → Intents: d(t) = d0 +
    /// (d_target − d0) × smoothstep(u) from the move-start tick).
    pub fn car_at(&self, id: u16, tick: f64, map: &LoopMap, tick_dt: f64) -> Option<CarNow> {
        let c = self.cars.get(&id)?;
        let v = f64::from(c.speed_cms) / 100.0;
        let since = tick - f64::from(c.corrected_tick);
        let s_m = map.wrap_m(f64::from(c.s_mm) / 1_000.0 + v * since * tick_dt);
        let d_c = f64::from(c.d_cm) / 100.0;
        let mut now = CarNow {
            s_m,
            d: d_c,
            v,
            v_lat: 0.0,
            lane: 0,
        };
        let road = sim::scoring::LoopRoad::new(map);
        let n = road.lane_count(s_m);
        if c.lc_phase != LaneChangePhase::None && c.lc_duration_ms > 0 {
            let target_lane = if c.lc_target_lane >= 7 {
                n
            } else {
                n - 1 - i32::from(c.lc_target_lane)
            };
            let target =
                road.lanes_left_edge_d() + (f64::from(target_lane) + 0.5) * road.lane_width(s_m);
            let dur_ticks = f64::from(c.lc_duration_ms) / 1_000.0 / tick_dt;
            let m = f64::from(c.lc_move_start_tick);
            let u_at = |t: f64| ((t - m) / dur_ticks).clamp(0.0, 1.0);
            let smooth = |u: f64| u * u * (3.0 - 2.0 * u);
            let (u, u_c) = (u_at(tick), u_at(f64::from(c.corrected_tick)));
            if u > 0.0 {
                if u_c >= 1.0 {
                    now.d = d_c;
                } else {
                    let d0 = (d_c - target * smooth(u_c)) / (1.0 - smooth(u_c));
                    now.d = d0 + (target - d0) * smooth(u);
                    if u < 1.0 {
                        now.v_lat = (target - d0) * 6.0 * u * (1.0 - u) / (dur_ticks * tick_dt);
                    }
                }
            }
        }
        now.lane = sim::scoring::ScoringRoad::lane_index_at(&road, now.d, s_m).max(0);
        Some(now)
    }

    /// The car ids the bot has, sorted.
    pub fn ids(&self) -> Vec<u16> {
        let mut v: Vec<u16> = self.cars.keys().copied().collect();
        v.sort_unstable();
        v
    }
}
