//! An independent rule checker for traffic soaks (port of the rules of
//! `tests/fixtures/traffic/traffic_rule_checker.gd`, plus the server's intents). It reads
//! only the published state, the events and the players, never the sim's internals:
//!
//! - **Signal time:** blinker on to the first lateral motion is at least the profile's
//!   signal time with this sim's floor (1.0 s on the server); no unsignaled lateral motion
//!   (hit swerves excepted).
//! - **Intents:** every `Signal` names a move-start tick at least the floor after it, and
//!   the car starts its move exactly then with the announced move time.
//! - **Collisions:** traffic-to-traffic, oriented boxes in road space (yaw from
//!   `atan2(v_lat, max(v, 0))`, clamped to +-MAX_BOX_YAW_RAD as since WP6.8), inset by
//!   `collision_inset_m`, separating axes; across the loop's seam too.
//! - **Deceleration clamp** and **brake-light flags**.
//! - **Off road:** a car's body outside the driving lanes (ramp lanes excepted).
//!
//! Not allocation-free (test code): messages are collected for the first failures.

use super::gd::maxf;
use super::params::TrafficParams;
use super::sim::{EventKind, TrafficSim};
use super::state::*;

/// `TrafficRuleChecker.MAX_BOX_YAW_RAD` (WP6.8).
pub const MAX_BOX_YAW_RAD: f64 = 0.28;
const LATERAL_EPS: f64 = 1e-6;
const OFFROAD_TOL_M: f64 = 0.3;
const MAX_MESSAGES: usize = 40;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct CheckerCounts {
    pub ticks: u64,
    pub signals: u64,
    pub moves: u64,
    pub cancels: u64,
    pub signal_violations: u64,
    pub unsignaled_moves: u64,
    pub intents: u64,
    pub intent_lead_violations: u64,
    pub intent_mismatches: u64,
    pub collision_ticks: u64,
    pub collision_pairs: u64,
    /// Pairs whose un-yawed road-space bodies overlap (the sim's own geometry).
    pub body_overlap_pairs: u64,
    /// Reported, not gated: overlaps with the single-player checker's heading
    /// (atan2(v_lat, max(v, 0)) within +-MAX_BOX_YAW_RAD) whose bodies and rendered boxes
    /// do not overlap (a 12-16 m vehicle crawling through a lane change at a lane drop),
    /// and the fastest car in one (m/s).
    pub yaw_only_pairs: u64,
    pub yaw_only_max_speed: f64,
    pub decel_violations: u64,
    pub brake_flag_violations: u64,
    pub offroad: u64,
    /// Shortest blinker-to-motion seen (s), and shortest intent lead (s).
    pub min_signal_s: f64,
    pub min_intent_lead_s: f64,
}

pub struct RuleChecker {
    dt: f64,
    floor: f64,
    inset: f64,
    view_yaw_min_v: f64,
    view_yaw_max: f64,
    max_decel: f64,
    brake: f64,
    strong: f64,
    signal_s: Vec<f64>,
    check_intents: bool,
    vid: Vec<i32>,
    blink_tick: Vec<u32>,
    blinking: Vec<u8>,
    moved: Vec<u8>,
    prev_d: Vec<f64>,
    prev_lc: Vec<i32>,
    intent_tick: Vec<u32>,
    intent_move: Vec<u32>,
    intent_dur: Vec<f64>,
    has_intent: Vec<u8>,
    max_len: f64,
    pub counts: CheckerCounts,
    pub messages: Vec<String>,
}

impl RuleChecker {
    /// `check_intents`: the sim draws move times at the signal (the server config).
    pub fn new(params: &TrafficParams, sim: &TrafficSim, check_intents: bool) -> Self {
        let cap = sim.state.capacity;
        let floor = sim.config.signal_time_floor_s;
        let t = &params.tuning;
        let mut max_len: f64 = 0.0;
        for x in &params.types {
            max_len = max_len.max(x.length_m);
        }
        RuleChecker {
            dt: sim.config.tick_dt,
            floor,
            inset: t.collision_inset_m,
            view_yaw_min_v: t.view_yaw_min_speed_mps,
            view_yaw_max: t.view_yaw_max_rad,
            max_decel: t.max_decel_mps2,
            brake: t.brake_light_decel_mps2,
            strong: t.brake_light_strong_decel_mps2,
            signal_s: params
                .profiles
                .iter()
                .map(|p| maxf(p.signal_time_s, floor))
                .collect(),
            check_intents,
            vid: vec![0; cap],
            blink_tick: vec![0; cap],
            blinking: vec![0; cap],
            moved: vec![0; cap],
            prev_d: vec![0.0; cap],
            prev_lc: vec![0; cap],
            intent_tick: vec![0; cap],
            intent_move: vec![0; cap],
            intent_dur: vec![0.0; cap],
            has_intent: vec![0; cap],
            max_len,
            counts: CheckerCounts {
                min_signal_s: f64::INFINITY,
                min_intent_lead_s: f64::INFINITY,
                ..CheckerCounts::default()
            },
            messages: Vec::new(),
        }
    }

    pub fn total_violations(&self) -> u64 {
        let c = &self.counts;
        c.signal_violations
            + c.unsignaled_moves
            + c.intent_lead_violations
            + c.intent_mismatches
            + c.collision_ticks
            + c.decel_violations
            + c.brake_flag_violations
            + c.offroad
    }

    pub fn summary(&self) -> String {
        format!("{:?}; first messages: {:?}", self.counts, self.messages)
    }

    fn msg(&mut self, text: String) {
        if self.messages.len() < MAX_MESSAGES {
            self.messages.push(text);
        }
    }

    /// Checks one tick: call after the sim's step (and the population's update), before
    /// its events are cleared. `tick` is the step's tick.
    pub fn observe(&mut self, sim: &TrafficSim, tick: u32) {
        self.counts.ticks += 1;
        for e in sim.events.as_slice() {
            let i = e.slot as usize;
            match e.kind {
                EventKind::Signal => {
                    self.counts.intents += 1;
                    let lead = f64::from(e.move_start_tick.wrapping_sub(e.tick)) * self.dt;
                    self.counts.min_intent_lead_s = self.counts.min_intent_lead_s.min(lead);
                    if lead < self.floor - 1e-9 {
                        self.counts.intent_lead_violations += 1;
                        self.msg(format!(
                            "tick {tick}: slot {i} intent lead {lead:.3} s < {}",
                            self.floor
                        ));
                    }
                    self.has_intent[i] = 1;
                    self.intent_tick[i] = e.tick;
                    self.intent_move[i] = e.move_start_tick;
                    self.intent_dur[i] = e.duration_s;
                }
                EventKind::Cancel | EventKind::Despawned => self.has_intent[i] = 0,
                _ => {}
            }
        }
        let st = &sim.state;
        for i in 0..st.capacity {
            if st.active[i] == 0 {
                continue;
            }
            if self.vid[i] != st.vehicle_id[i] {
                self.vid[i] = st.vehicle_id[i];
                self.blinking[i] = 0;
                self.moved[i] = 0;
                self.prev_d[i] = st.d[i];
                self.prev_lc[i] = st.lc_state[i];
            }
            self.check_car(sim, i, tick);
        }
        self.check_boxes(sim, tick);
    }

    fn check_car(&mut self, sim: &TrafficSim, i: usize, tick: u32) {
        let st = &sim.state;
        let f = st.flags[i];
        let s = st.s[i];
        let lanes = sim.road.lane_count(s);
        let hw = st.width[i] * 0.5;
        let ramp = st.lane[i] >= lanes || st.target_lane[i] >= lanes || sim.is_exiting(i);
        if !ramp
            && (st.d[i] + hw > sim.road.lanes_right_edge_d(s) + OFFROAD_TOL_M
                || st.d[i] - hw < sim.road.lanes_left_edge_d(s) - OFFROAD_TOL_M)
        {
            self.counts.offroad += 1;
            let text = format!(
                "tick {tick}: slot {i} lane {} d {:.2} off the lanes at s {s:.1}",
                st.lane[i], st.d[i]
            );
            self.msg(text);
        }
        let blink = (f & (FLAG_BLINKER_LEFT | FLAG_BLINKER_RIGHT)) != 0;
        let hit = (f & FLAG_HIT) != 0;
        if blink && self.blinking[i] == 0 {
            self.blinking[i] = 1;
            self.moved[i] = 0;
            self.blink_tick[i] = tick;
            self.counts.signals += 1;
        } else if !blink && self.blinking[i] == 1 {
            self.blinking[i] = 0;
            if self.moved[i] == 0 {
                self.counts.cancels += 1;
            }
        }
        if (st.d[i] - self.prev_d[i]).abs() > LATERAL_EPS && !hit {
            if !blink {
                self.counts.unsignaled_moves += 1;
                self.msg(format!(
                    "tick {tick}: slot {i} moved laterally with no blinker"
                ));
            } else if self.moved[i] == 0 {
                self.moved[i] = 1;
                self.counts.moves += 1;
                let need = self.signal_s[st.profile_id[i] as usize];
                let had = f64::from(tick.wrapping_sub(self.blink_tick[i])) * self.dt;
                self.counts.min_signal_s = self.counts.min_signal_s.min(had);
                if had < need - 1e-9 {
                    self.counts.signal_violations += 1;
                    self.msg(format!(
                        "tick {tick}: slot {i} moved after {had:.3} s of signal < {need:.3} s"
                    ));
                }
            }
        }
        self.prev_d[i] = st.d[i];
        let moving = st.lc_state[i] == LC_MOVING;
        if moving && self.prev_lc[i] != LC_MOVING && self.check_intents {
            if self.has_intent[i] == 0 {
                self.counts.intent_mismatches += 1;
                self.msg(format!(
                    "tick {tick}: slot {i} started a move without an intent"
                ));
            } else if self.intent_move[i] != tick
                || (st.lc_duration[i] - self.intent_dur[i]).abs() > 0.0
            {
                self.counts.intent_mismatches += 1;
                let text = format!(
                    "tick {tick}: slot {i} moved at tick {tick} for {:.3} s, intent said {} for {:.3} s",
                    st.lc_duration[i], self.intent_move[i], self.intent_dur[i]
                );
                self.msg(text);
            }
            self.has_intent[i] = 0;
        }
        self.prev_lc[i] = st.lc_state[i];
        let a = st.accel[i];
        if a < -self.max_decel - 1e-9 && (f & FLAG_SCRIPTED) == 0 {
            self.counts.decel_violations += 1;
            self.msg(format!(
                "tick {tick}: slot {i} decel {:.3} beyond the clamp",
                -a
            ));
        }
        let want_brake = -a > self.brake;
        let want_strong = -a > self.strong;
        if want_brake != ((f & FLAG_BRAKE) != 0) || want_strong != ((f & FLAG_BRAKE_STRONG) != 0) {
            self.counts.brake_flag_violations += 1;
            self.msg(format!(
                "tick {tick}: slot {i} brake flags do not match decel {:.3}",
                -a
            ));
        }
    }

    fn check_boxes(&mut self, sim: &TrafficSim, tick: u32) {
        let st = &sim.state;
        let ord = sim.order();
        let n = ord.len();
        let cap = st.capacity;
        let mut hit_tick = false;
        let periodic = sim.road.period() > 0.0;
        for a in 0..n {
            let i = ord[a];
            if i >= cap {
                continue;
            }
            for x in 1..n {
                let b = a + x;
                if b >= n && !periodic {
                    break;
                }
                let j = ord[b % n];
                if j == i {
                    break;
                }
                if j >= cap {
                    continue; // a player (ghosted to each other; contacts are the room's)
                }
                let ds = sim.road.signed_delta(st.s[i], st.s[j]);
                if ds >= (st.length[i] + self.max_len) * 0.5 || ds < 0.0 {
                    break;
                }
                if ds >= (st.length[i] + st.length[j]) * 0.5 {
                    continue;
                }
                let body = self.overlap(
                    0.0,
                    st.d[i],
                    st.length[i],
                    st.width[i],
                    0.0,
                    ds,
                    st.d[j],
                    st.length[j],
                    st.width[j],
                    0.0,
                );
                // As clients render them (TrafficViewTuning's yaw).
                let seen = body
                    || self.overlap(
                        0.0,
                        st.d[i],
                        st.length[i],
                        st.width[i],
                        self.view_yaw(st.v_lat[i], st.v[i]),
                        ds,
                        st.d[j],
                        st.length[j],
                        st.width[j],
                        self.view_yaw(st.v_lat[j], st.v[j]),
                    );
                if body {
                    self.counts.body_overlap_pairs += 1;
                }
                if !seen
                    && self.overlap(
                        0.0,
                        st.d[i],
                        st.length[i],
                        st.width[i],
                        box_yaw(st.v_lat[i], st.v[i]),
                        ds,
                        st.d[j],
                        st.length[j],
                        st.width[j],
                        box_yaw(st.v_lat[j], st.v[j]),
                    )
                {
                    self.counts.yaw_only_pairs += 1;
                    self.counts.yaw_only_max_speed =
                        self.counts.yaw_only_max_speed.max(st.v[i].max(st.v[j]));
                }
                if seen {
                    self.counts.collision_pairs += 1;
                    hit_tick = true;
                    let text = format!(
                        "tick {tick}: collision slots {i}/{j} at s {:.1} d {:.2}/{:.2} v {:.1}/{:.1} lanes {}/{} lc {}/{}",
                        st.s[i], st.d[i], st.d[j], st.v[i], st.v[j], st.lane[i], st.lane[j], st.lc_state[i], st.lc_state[j]
                    );
                    self.msg(text);
                }
            }
        }
        if hit_tick {
            self.counts.collision_ticks += 1;
        }
    }

    /// Oriented boxes (centre s, d; full length, width; yaw) inset on every side. SAT.
    #[allow(clippy::too_many_arguments)]
    pub fn overlap(
        &self,
        s1: f64,
        d1: f64,
        l1: f64,
        w1: f64,
        y1: f64,
        s2: f64,
        d2: f64,
        l2: f64,
        w2: f64,
        y2: f64,
    ) -> bool {
        let hl1 = l1 * 0.5 - self.inset;
        let hw1 = w1 * 0.5 - self.inset;
        let hl2 = l2 * 0.5 - self.inset;
        let hw2 = w2 * 0.5 - self.inset;
        let (n1, c1) = y1.sin_cos();
        let (n2, c2) = y2.sin_cos();
        let ts = s2 - s1;
        let td = d2 - d1;
        let axes = [(c1, n1), (-n1, c1), (c2, n2), (-n2, c2)];
        for (us, ud) in axes {
            let r1 = hl1 * (c1 * us + n1 * ud).abs() + hw1 * (-n1 * us + c1 * ud).abs();
            let r2 = hl2 * (c2 * us + n2 * ud).abs() + hw2 * (-n2 * us + c2 * ud).abs();
            if (ts * us + td * ud).abs() > r1 + r2 {
                return false;
            }
        }
        true
    }
}

impl RuleChecker {
    /// A traffic car's heading as clients render it (`TrafficView`: atan2(v_lat, max(v,
    /// yaw_min_speed)) within +-yaw_max).
    pub fn view_yaw(&self, v_lat: f64, v: f64) -> f64 {
        v_lat
            .atan2(maxf(v, self.view_yaw_min_v))
            .clamp(-self.view_yaw_max, self.view_yaw_max)
    }
}

/// A traffic box's heading in the single-player checker (`TrafficRuleChecker.box_yaw`).
pub fn box_yaw(v_lat: f64, v: f64) -> f64 {
    v_lat
        .atan2(maxf(v, 0.0))
        .clamp(-MAX_BOX_YAW_RAD, MAX_BOX_YAW_RAD)
}
