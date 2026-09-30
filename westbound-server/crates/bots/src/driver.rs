//! N6.1: bots that drive through the traffic they are streamed and claim what they score.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Testing → Netcode harness ("bots drive
//! scripted paths through traffic, send honest claims"; "claim acceptance above 99%"),
//! Scoring in multiplayer (claims).
//!
//! - [`TrafficDriver`]: keeps a lane at its cruise speed, follows a slower car (a simple
//!   IDM), overtakes it through a clear neighbouring lane, leaves a lane that ends ahead,
//!   and wanders ±0.8 m inside its lane (so some passes are close).
//! - [`Scorer`]: the client's rule set (`sim::scoring::Scoring`, the parity-tested port)
//!   run on the bot's [`TrafficMirror`](crate::traffic::TrafficMirror) carried to each
//!   state's tick, turning its pass, close pass, thread and cut events into `score_claim`s
//!   exactly as N6.2's client is to (docs/SERVER.md → Scoring → For the client). A
//!   [`Cheat`] bends every claim: inflated clearance, fabricated cars, wrong timing.
//!
//! Positions are the bot's own (s wrapped on the loop, unwrapped near the bot for the
//! rules), cars come from the mirror (their last correction carried on at its speed and
//! their lane change's curve), so a bot sees what a client would, within centimetres.

use std::collections::HashMap;

use protocol::{ClaimCar, ClaimKind, ScoreClaim, Side};
use sim::map::LoopMap;
use sim::scoring::{
    Kind, LoopRoad, PlayerTick, ScoreEventBuffer, Scoring, ScoringCars, ScoringParams,
};
use sim::traffic::TrafficParams;

use crate::traffic::TrafficMirror;

const MM_PER_M: f64 = 1_000.0;
/// Frame slots (a rush-hour area holds ~95 cars).
const SLOTS: usize = 192;

/// How a bot drives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DriveMode {
    /// Straight in its placement lane at the cruise speed (N5.1's bots).
    #[default]
    Lane,
    /// Through traffic: follows, overtakes, merges ([`TrafficDriver`]).
    Traffic,
}

/// What a bot claims.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ClaimMode {
    #[default]
    Off,
    /// What its rules detect, as detected.
    Honest,
    /// Every claim bent this way.
    Cheat(Cheat),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cheat {
    /// Plain passes claimed as close passes at 0.3 m.
    InflateClearance,
    /// Passes of cars it never passed (one it has ahead, or an id it was never sent).
    FabricateCars,
    /// Real events claimed 1.5 s early.
    WrongTiming,
}

/// Claims a bot sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ClaimStats {
    pub passes: u32,
    pub close_passes: u32,
    pub threads: u32,
    pub cuts: u32,
}

impl ClaimStats {
    pub fn total(&self) -> u32 {
        self.passes + self.close_passes + self.threads + self.cuts
    }
}

/// A small deterministic generator (xorshift64*), so bots need no RNG crate.
#[derive(Debug, Clone, Copy)]
pub struct BotRng(u64);

impl BotRng {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform in [0, 1).
    pub fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.unit()
    }
}

/// Car body sizes by vehicle type (the exported traffic params' order).
#[derive(Debug, Clone)]
pub struct Bodies {
    sizes: Vec<(f64, f64)>,
}

impl Bodies {
    pub fn builtin() -> Self {
        let sizes = TrafficParams::builtin()
            .map(|p| p.types.iter().map(|t| (t.length_m, t.width_m)).collect())
            .unwrap_or_default();
        Self { sizes }
    }

    pub fn of(&self, vehicle: u8) -> (f64, f64) {
        self.sizes
            .get(usize::from(vehicle))
            .copied()
            .unwrap_or((4.5, 1.8))
    }
}

/// A mirrored car near the bot, relative to it.
#[derive(Debug, Clone, Copy)]
struct Near {
    /// Along the loop from the bot (m, + ahead).
    ds: f64,
    d: f64,
    v: f64,
    length: f64,
    width: f64,
}

/// Driving through traffic (see the module docs).
#[derive(Debug, Clone)]
pub struct TrafficDriver {
    rng: BotRng,
    target_lane: Option<i32>,
    offset: f64,
    next_offset_s: f64,
    change_cooldown_s: f64,
    near: Vec<Near>,
    /// Lane changes started (diagnostics).
    pub lane_changes: u32,
}

/// The driver's numbers (not tuning: a test harness's behaviour).
const LOOK_M: f64 = 120.0;
const FOLLOW_WHEN_M: f64 = 70.0;
const IDM_S0: f64 = 6.0;
const IDM_T: f64 = 1.2;
const IDM_B: f64 = 5.0;
const BRAKE_MAX: f64 = 8.0;
const LANE_CATCH_M: f64 = 1.8;
/// Wandering inside the lane: up to this far off the centre (inner lanes), or this far
/// toward the shoulder in the outer lanes (the wheels stay off it).
const OFFSET_MAX: f64 = 1.3;
const OFFSET_EDGE: f64 = 0.75;
const CHANGE_COOLDOWN_S: f64 = 2.5;
const LANE_ENDS_LOOK_M: f64 = 250.0;
const PLAYER_HALF_LEN: f64 = 2.25;
/// A lane is clear with this much room around the bot, plus the closing speed times
/// these (s) behind and ahead; a lane change must gain this much room ahead.
const CLEAR_M: f64 = 10.0;
const CLEAR_BEHIND_S: f64 = 2.0;
const CLEAR_AHEAD_S: f64 = 1.2;
const GAIN_M: f64 = 5.0;

impl TrafficDriver {
    pub fn new(seed: u64) -> Self {
        Self {
            rng: BotRng::new(seed),
            target_lane: None,
            offset: 0.0,
            next_offset_s: 0.0,
            change_cooldown_s: 0.0,
            near: Vec::with_capacity(SLOTS),
            lane_changes: 0,
        }
    }

    /// One control step at room tick `tick` (fractional): the acceleration to apply and
    /// the lateral offset to steer to.
    #[allow(clippy::too_many_arguments)]
    pub fn control(
        &mut self,
        s_m: f64,
        d: f64,
        v: f64,
        cruise: f64,
        accel_max: f64,
        tick: f64,
        dt: f64,
        mirror: &TrafficMirror,
        bodies: &Bodies,
        map: &LoopMap,
        tick_dt: f64,
    ) -> (f64, f64) {
        let road = LoopRoad::new(map);
        self.near.clear();
        for (&id, car) in &mirror.cars {
            let Some(c) = mirror.car_at(id, tick, map, tick_dt) else {
                continue;
            };
            let ds = map.signed_delta_m(s_m, c.s_m);
            if ds.abs() > LOOK_M {
                continue;
            }
            let (length, width) = bodies.of(car.vehicle);
            self.near.push(Near {
                ds,
                d: c.d,
                v: c.v,
                length,
                width,
            });
        }
        let left = road.lanes_left_edge_d();
        let width = road.lane_width(s_m);
        let lanes = road
            .lane_count(s_m)
            .min(road.lane_count(s_m + LANE_ENDS_LOOK_M));
        let centre = |lane: i32| left + (f64::from(lane) + 0.5) * width;
        let lane_now = (((d - left) / width).floor() as i32).clamp(0, (lanes - 1).max(0));
        self.change_cooldown_s -= dt;
        self.next_offset_s -= dt;
        if self.next_offset_s <= 0.0 {
            self.offset = self.rng.range(-OFFSET_MAX, OFFSET_MAX);
            self.next_offset_s = self.rng.range(3.0, 6.0);
        }
        let lane = self.target_lane.unwrap_or(lane_now);
        let lane = if lane >= lanes { lanes - 1 } else { lane };
        let (gap, lead_v) = self.leader(centre(lane), v);
        // Overtake a slower leader (or leave a lane that ends) through a clear lane.
        let slow_leader = gap < FOLLOW_WHEN_M && lead_v < cruise - 2.0;
        let lane_ends = lane_now >= lanes;
        if self.target_lane.is_none() && self.change_cooldown_s <= 0.0 && (slow_leader || lane_ends)
        {
            let mut best: Option<(i32, f64)> = None;
            for cand in [lane_now - 1, lane_now + 1] {
                if cand < 0 || cand >= lanes || !self.clear(centre(cand), v) {
                    continue;
                }
                let (g, _) = self.leader(centre(cand), v);
                if (g > gap + GAIN_M || lane_ends) && best.is_none_or(|(_, bg)| g > bg) {
                    best = Some((cand, g));
                }
            }
            if let Some((cand, _)) = best {
                self.target_lane = Some(cand);
                self.lane_changes += 1;
                self.change_cooldown_s = CHANGE_COOLDOWN_S;
            }
        }
        let steer_lane = self.target_lane.unwrap_or(lane);
        let lo = if steer_lane == 0 {
            -OFFSET_EDGE
        } else {
            -OFFSET_MAX
        };
        let hi = if steer_lane >= lanes - 1 {
            OFFSET_EDGE
        } else {
            OFFSET_MAX
        };
        let target_d = centre(steer_lane) + self.offset.clamp(lo, hi);
        if self.target_lane.is_some() && (d - centre(steer_lane)).abs() < LANE_CATCH_M * 0.5 {
            self.target_lane = None;
        }
        // Follow the leader in every lane the car overlaps (IDM).
        let mut acc = accel_max * (1.0 - (v / cruise.max(1.0)).powi(4));
        for lane_d in [d, target_d] {
            let (g, lv) = self.leader(lane_d, v);
            if g < LOOK_M {
                let s_star = IDM_S0 + v * IDM_T + v * (v - lv) / (2.0 * (accel_max * IDM_B).sqrt());
                let a = accel_max
                    * (1.0
                        - (v / cruise.max(1.0)).powi(4)
                        - (s_star.max(0.0) / g.max(0.1)).powi(2));
                acc = acc.min(a);
            }
        }
        (acc.clamp(-BRAKE_MAX, accel_max), target_d)
    }

    /// The nearest car ahead overlapping a car at lateral position `at`: its gap (m,
    /// bumper to bumper) and speed; (∞, v) when none.
    fn leader(&self, at: f64, v: f64) -> (f64, f64) {
        let mut best = (f64::INFINITY, v);
        for c in &self.near {
            let half = c.length * 0.5 + PLAYER_HALF_LEN;
            if c.ds <= 0.0 || (c.d - at).abs() > (c.width + 1.95) * 0.5 + 0.3 {
                continue;
            }
            let gap = c.ds - half;
            if gap < best.0 {
                best = (gap.max(0.0), c.v);
            }
        }
        best
    }

    /// No car in the lane at `at` near the bot (behind: room for its speed; ahead: room to
    /// fit in).
    fn clear(&self, at: f64, v: f64) -> bool {
        self.near.iter().all(|c| {
            if (c.d - at).abs() > (c.width + 1.95) * 0.5 + 0.5 {
                return true;
            }
            let half = c.length * 0.5 + PLAYER_HALF_LEN;
            let behind = CLEAR_M + (c.v - v).max(0.0) * CLEAR_BEHIND_S;
            let ahead = CLEAR_M + (v - c.v).max(0.0) * CLEAR_AHEAD_S;
            c.ds < -(half + behind) || c.ds > half + ahead
        })
    }
}

/// The client's rules on a bot's mirror (see the module docs).
pub struct Scorer {
    rules: Scoring,
    buf: ScoreEventBuffer,
    frame: Frame,
    slot_of: HashMap<u16, usize>,
    next_vid: i32,
    /// Recent passes (car, tick, right side, clearance mm) for threads.
    recent: Vec<(u16, u32, bool, u16)>,
    claim_id: u16,
    last: Option<(u32, u32)>,
    s_unw: f64,
    mode: ClaimMode,
    rng: BotRng,
    pub out: Vec<ScoreClaim>,
    pub stats: ClaimStats,
}

/// The mirror as the rules read it (a structure of arrays by slot).
struct Frame {
    active: Vec<bool>,
    vid: Vec<i32>,
    car: Vec<u16>,
    s: Vec<f64>,
    d: Vec<f64>,
    v: Vec<f64>,
    v_lat: Vec<f64>,
    length: Vec<f64>,
    width: Vec<f64>,
    lane: Vec<i32>,
}

impl ScoringCars for Frame {
    fn capacity(&self) -> usize {
        self.active.len()
    }
    fn active(&self, i: usize) -> bool {
        self.active[i]
    }
    fn vehicle_id(&self, i: usize) -> i32 {
        self.vid[i]
    }
    fn s(&self, i: usize) -> f64 {
        self.s[i]
    }
    fn d(&self, i: usize) -> f64 {
        self.d[i]
    }
    fn v(&self, i: usize) -> f64 {
        self.v[i]
    }
    fn v_lat(&self, i: usize) -> f64 {
        self.v_lat[i]
    }
    fn length(&self, i: usize) -> f64 {
        self.length[i]
    }
    fn width(&self, i: usize) -> f64 {
        self.width[i]
    }
    fn lane(&self, i: usize) -> i32 {
        self.lane[i]
    }
}

impl Scorer {
    pub fn new(mode: ClaimMode, seed: u64) -> Self {
        let params = ScoringParams::builtin().expect("the compiled-in scoring export");
        let n = SLOTS;
        Self {
            rules: Scoring::new(&params),
            buf: ScoreEventBuffer::new(64),
            frame: Frame {
                active: vec![false; n],
                vid: vec![0; n],
                car: vec![0; n],
                s: vec![0.0; n],
                d: vec![0.0; n],
                v: vec![0.0; n],
                v_lat: vec![0.0; n],
                length: vec![0.0; n],
                width: vec![0.0; n],
                lane: vec![0; n],
            },
            slot_of: HashMap::new(),
            next_vid: 1,
            recent: Vec::new(),
            claim_id: 0,
            last: None,
            s_unw: 0.0,
            mode,
            rng: BotRng::new(seed ^ 0xC1A1),
            out: Vec::new(),
            stats: ClaimStats::default(),
        }
    }

    /// A new run (a placement): the rules and the memory start over.
    pub fn restart(&mut self) {
        if let Ok(p) = ScoringParams::builtin() {
            self.rules.reset(&p);
        }
        for a in &mut self.frame.active {
            *a = false;
        }
        self.slot_of.clear();
        self.recent.clear();
        self.last = None;
    }

    /// The bot's state at room tick `tick` (s wrapped, mm): the rules step once, and what
    /// they detect becomes claims in `out`.
    #[allow(clippy::too_many_arguments)]
    pub fn step(
        &mut self,
        tick: u32,
        s_mm: u32,
        d: f64,
        v: f64,
        mirror: &TrafficMirror,
        bodies: &Bodies,
        map: &LoopMap,
        tick_dt: f64,
    ) {
        if self.mode == ClaimMode::Off {
            self.last = None;
            return;
        }
        let dt = match self.last {
            Some((t, s_prev)) => {
                self.s_unw += map.signed_delta_mm(s_prev, s_mm) as f64 / MM_PER_M;
                f64::from(tick.wrapping_sub(t)) * tick_dt
            }
            None => {
                self.s_unw = f64::from(s_mm) / MM_PER_M;
                0.0
            }
        };
        self.last = Some((tick, s_mm));
        let s_m = f64::from(s_mm) / MM_PER_M;
        let road = LoopRoad::new(map);
        // The frame: every mirrored car at this tick, unwrapped near the bot.
        for a in &mut self.frame.active {
            *a = false;
        }
        for (&id, car) in &mirror.cars {
            let Some(c) = mirror.car_at(id, f64::from(tick), map, tick_dt) else {
                continue;
            };
            let slot = match self.slot_of.get(&id) {
                Some(&k) => k,
                None => {
                    let Some(k) = (0..SLOTS).find(|&k| {
                        self.frame.car[k] == 0 || !self.slot_of.contains_key(&self.frame.car[k])
                    }) else {
                        continue;
                    };
                    self.slot_of.insert(id, k);
                    self.frame.car[k] = id;
                    self.frame.vid[k] = self.next_vid;
                    self.next_vid += 1;
                    k
                }
            };
            let (length, width) = bodies.of(car.vehicle);
            let f = &mut self.frame;
            f.active[slot] = true;
            f.s[slot] = self.s_unw + map.signed_delta_m(s_m, c.s_m);
            f.d[slot] = c.d;
            f.v[slot] = c.v;
            f.v_lat[slot] = c.v_lat;
            f.length[slot] = length;
            f.width[slot] = width;
            f.lane[slot] = c.lane;
        }
        // Cars gone from the mirror free their slots.
        let frame = &self.frame;
        self.slot_of.retain(|_, k| frame.active[*k]);
        let player = PlayerTick {
            s: self.s_unw,
            d,
            v,
            yaw: 0.0,
            boost_active: false,
        };
        self.buf.clear();
        self.rules
            .step(dt, &player, &self.frame, &road, &mut self.buf);
        let _ = self.rules.take_boost_fill();
        for k in 0..self.buf.len() {
            let e = self.buf.as_slice()[k];
            let slot = usize::try_from(e.slot).unwrap_or(0);
            let car = self.frame.car.get(slot).copied().unwrap_or(0);
            let right = self.frame.d.get(slot).is_some_and(|&cd| cd >= d);
            let clr = (e.clearance_m * MM_PER_M)
                .round()
                .clamp(0.0, f64::from(u16::MAX)) as u16;
            match e.kind {
                Kind::Pass | Kind::ClosePass => {
                    self.recent.push((car, tick, right, clr));
                    if self.recent.len() > 16 {
                        self.recent.remove(0);
                    }
                    let kind = if e.kind == Kind::Pass {
                        ClaimKind::Pass
                    } else {
                        ClaimKind::ClosePass
                    };
                    self.claim(
                        kind,
                        tick,
                        side(right),
                        &[(car, clr)],
                        mirror,
                        s_m,
                        map,
                        tick_dt,
                    );
                }
                Kind::Thread => {
                    let first = self
                        .recent
                        .iter()
                        .rev()
                        .find(|(c, t, r, _)| {
                            *c != car && *r != right && tick.wrapping_sub(*t) <= 20
                        })
                        .copied();
                    let second = self.recent.iter().rev().find(|(c, ..)| *c == car).copied();
                    if let (Some(a), Some(b)) = (first, second) {
                        self.claim(
                            ClaimKind::Thread,
                            tick,
                            side(a.2),
                            &[(a.0, a.3), (b.0, b.3)],
                            mirror,
                            s_m,
                            map,
                            tick_dt,
                        );
                    }
                }
                Kind::Cut => self.claim(
                    ClaimKind::Cut,
                    tick,
                    Side::None,
                    &[(car, 0)],
                    mirror,
                    s_m,
                    map,
                    tick_dt,
                ),
                _ => {}
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn claim(
        &mut self,
        mut kind: ClaimKind,
        mut tick: u32,
        side: Side,
        cars: &[(u16, u16)],
        mirror: &TrafficMirror,
        s_m: f64,
        map: &LoopMap,
        tick_dt: f64,
    ) {
        let mut cars: Vec<ClaimCar> = cars
            .iter()
            .map(|&(car_id, clearance_mm)| ClaimCar {
                car_id,
                clearance_mm,
            })
            .collect();
        match self.mode {
            ClaimMode::Cheat(Cheat::InflateClearance) => {
                if kind == ClaimKind::Pass {
                    kind = ClaimKind::ClosePass;
                }
                for c in &mut cars {
                    c.clearance_mm = c.clearance_mm.min(300);
                }
            }
            ClaimMode::Cheat(Cheat::FabricateCars) => {
                // A car well ahead (never passed), or an id it was never sent.
                let ahead = mirror.cars.keys().copied().find(|&id| {
                    mirror
                        .car_at(id, f64::from(tick), map, tick_dt)
                        .is_some_and(|c| map.signed_delta_m(s_m, c.s_m) > 50.0)
                });
                for c in &mut cars {
                    c.car_id = match ahead {
                        Some(id) if self.rng.unit() < 0.5 => id,
                        _ => 60_000 + (self.rng.next_u64() % 5_000) as u16,
                    };
                }
            }
            ClaimMode::Cheat(Cheat::WrongTiming) => tick = tick.wrapping_sub(30),
            ClaimMode::Honest | ClaimMode::Off => {}
        }
        match kind {
            ClaimKind::Pass => self.stats.passes += 1,
            ClaimKind::ClosePass => self.stats.close_passes += 1,
            ClaimKind::Thread => self.stats.threads += 1,
            ClaimKind::Cut => self.stats.cuts += 1,
        }
        self.claim_id = self.claim_id.wrapping_add(1);
        self.out.push(ScoreClaim {
            claim_id: self.claim_id,
            tick,
            kind,
            side,
            cars,
        });
    }

    /// Stops claiming (the rules keep running).
    pub fn stop_claims(&mut self) {
        self.mode = ClaimMode::Off;
    }

    /// The rules' current multiplier and banked total (diagnostics).
    pub fn local_score(&self) -> (f64, i64, i64) {
        (
            self.rules.multiplier(),
            self.rules.chain(),
            self.rules.banked(),
        )
    }
}

fn side(right: bool) -> Side {
    if right {
        Side::Right
    } else {
        Side::Left
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rng_is_deterministic_and_in_range() {
        let (mut a, mut b) = (BotRng::new(7), BotRng::new(7));
        for _ in 0..1_000 {
            let x = a.unit();
            assert_eq!(x, b.unit());
            assert!((0.0..1.0).contains(&x));
        }
        assert_ne!(BotRng::new(1).next_u64(), BotRng::new(2).next_u64());
    }

    #[test]
    fn bodies_come_from_the_export() {
        let b = Bodies::builtin();
        let (l, w) = b.of(0);
        assert!(l > 1.0 && w > 0.5);
        assert_eq!(b.of(250), (4.5, 1.8));
    }
}
