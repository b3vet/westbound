//! Port of `src/scoring/scoring.gd` (`Scoring`, the v1 rule set), function for function:
//! the same fields without the `_`, the same functions in the same order, the same float
//! expressions, so a replay on the same inputs gives the GDScript's events and trace
//! hash (parity: `tests/scoring_parity.rs`). docs/SCORING.md describes the rules.
//!
//! Inputs are traits so the same code scores the server's `TrafficState`, a parity
//! trace's cars and a bot's traffic mirror: [`ScoringCars`] (a structure of arrays by
//! slot) and [`ScoringRoad`] (the lane at d, the shoulder test). Distances between the
//! player and cars are plain differences of `s`, as on the client (unwrapped s): callers
//! on the loop pass positions unwrapped near the player.
//!
//! **Multiplayer additions** (N6; none of them changes what the port computes when unused):
//! - [`Scoring::begin_tick`] / [`Scoring::end_tick`] split [`Scoring::step`] around its
//!   detection, and [`Scoring::award`] pays one event as the detection would (the
//!   server's official score pays **verified claims** between the two: "the server runs
//!   the same scoring rules on accepted claims only");
//! - [`Scoring::set_crew_factor`]: crew proximity, a factor on every scored event's points
//!   (1.0 by default: `x * 1.0 == x`, so parity is untouched);
//! - [`Scoring::forfeit_chain`]: "Rejoin crew" forfeits the unbanked chain.
//!
//! Pure and allocation-free per tick: per-slot memory is allocated in `new` (and grown
//! once only if a larger traffic state shows up).

use super::events::{Kind, ScoreEventBuffer, Tag};
use super::hull;
use super::params::{pct_to_frac, ScoringParams, ScoringTuning};
use crate::trace_hash::{mix_bool, mix_float, mix_int, SEED};
use crate::traffic::gd::{maxf, minf};
use crate::traffic::TrafficState;

/// Pass-tracking phase per slot: not eligible (seen beside or behind the player first).
pub const PHASE_NONE: i32 = 0;
/// Fully ahead of the player (no longitudinal hull overlap).
pub const PHASE_AHEAD: i32 = 1;
/// Overlapping longitudinally, having come from ahead.
pub const PHASE_OVERLAP: i32 = 2;
const TAINT_GHOST: i32 = 1;
const TAINT_SHOULDER: i32 = 2;
/// Recent qualifying passes remembered for the thread window (a ring).
const THREAD_RING: usize = 8;

/// Traffic as scoring reads it: slots `0..capacity()`, the `TrafficState` columns.
pub trait ScoringCars {
    fn capacity(&self) -> usize;
    fn active(&self, i: usize) -> bool;
    fn vehicle_id(&self, i: usize) -> i32;
    fn s(&self, i: usize) -> f64;
    fn d(&self, i: usize) -> f64;
    fn v(&self, i: usize) -> f64;
    fn v_lat(&self, i: usize) -> f64;
    fn length(&self, i: usize) -> f64;
    fn width(&self, i: usize) -> f64;
    /// Current lane (0 = next to the median).
    fn lane(&self, i: usize) -> i32;
}

impl ScoringCars for TrafficState {
    fn capacity(&self) -> usize {
        self.capacity
    }
    fn active(&self, i: usize) -> bool {
        self.active[i] != 0
    }
    fn vehicle_id(&self, i: usize) -> i32 {
        self.vehicle_id[i]
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

/// The `RoadPath` queries scoring makes.
pub trait ScoringRoad {
    /// Lane index containing d, or -1 off the driving lanes (`RoadPath.lane_index_at`).
    fn lane_index_at(&self, d: f64, s: f64) -> i32;
    /// d lies on the inner or outer shoulder (`RoadPath.is_on_shoulder`).
    fn is_on_shoulder(&self, d: f64, s: f64) -> bool;
}

/// The player's `VehicleState` as scoring reads it.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PlayerTick {
    pub s: f64,
    pub d: f64,
    /// Forward speed (m/s).
    pub v: f64,
    /// Heading relative to the road (rad, + right).
    pub yaw: f64,
    pub boost_active: bool,
}

#[derive(Debug, Clone)]
pub struct Scoring {
    sc: ScoringTuning,
    inset: f64,
    day_span_nudge_thread: f64,
    day_span_nudge_close: f64,
    cp_window: f64,
    // Params (SI), converted once.
    floor: f64,
    min_v: f64,
    cut_v: f64,
    slip_v: f64,
    night_f: f64,
    /// MP: crew proximity factor on scored events' points.
    crew_f: f64,
    // Player hull (half sizes, inset).
    p_hl: f64,
    p_hw: f64,
    // Run state.
    t: f64,
    mult: f64,
    chain: i64,
    banked: i64,
    boost_fill: f64,
    night: bool,
    ghost: bool,
    ended: bool,
    reached_min: bool,
    hit_grace: f64,
    too_slow: bool,
    slow_time: f64,
    hesitated: bool,
    dipped: bool,
    on_shoulder: bool,
    shoulder_time: f64,
    penalty_block: f64,
    penalty: bool,
    slip: bool,
    prev_lane: i32,
    sf: f64,
    // Per-slot memory, valid while vid[i] == vehicle_id(i).
    cap: usize,
    vid: Vec<i32>,
    phase: Vec<i32>,
    taint: Vec<i32>,
    crossed: Vec<u8>,
    min_clear: Vec<f64>,
    cross_dd: Vec<f64>,
    cross_t: Vec<f64>,
    cut_t: Vec<f64>,
    // Thread ring.
    tr_t: [f64; THREAD_RING],
    tr_side: [i32; THREAD_RING],
    tr_clear: [f64; THREAD_RING],
    tr_used: [u8; THREAD_RING],
    tr_head: usize,
    // Close passes for the sun nudge.
    cp_t: Vec<f64>,
    cp_head: usize,
    cp_n: i64,
}

impl Scoring {
    /// A new run (`Scoring.new(ctx)`): the params, the default player body, the per-slot
    /// memory sized to `body.max_active_vehicles`.
    pub fn new(p: &ScoringParams) -> Self {
        let mut s = Scoring {
            sc: p.scoring.clone(),
            inset: 0.0,
            day_span_nudge_thread: 0.0,
            day_span_nudge_close: 0.0,
            cp_window: 0.0,
            floor: 0.0,
            min_v: 0.0,
            cut_v: 0.0,
            slip_v: 0.0,
            night_f: 1.0,
            crew_f: 1.0,
            p_hl: 0.0,
            p_hw: 0.0,
            t: 0.0,
            mult: 1.0,
            chain: 0,
            banked: 0,
            boost_fill: 0.0,
            night: false,
            ghost: false,
            ended: false,
            reached_min: false,
            hit_grace: 0.0,
            too_slow: false,
            slow_time: 0.0,
            hesitated: false,
            dipped: false,
            on_shoulder: false,
            shoulder_time: 0.0,
            penalty_block: 0.0,
            penalty: false,
            slip: false,
            prev_lane: -1,
            sf: 1.0,
            cap: 0,
            vid: Vec::new(),
            phase: Vec::new(),
            taint: Vec::new(),
            crossed: Vec::new(),
            min_clear: Vec::new(),
            cross_dd: Vec::new(),
            cross_t: Vec::new(),
            cut_t: Vec::new(),
            tr_t: [0.0; THREAD_RING],
            tr_side: [0; THREAD_RING],
            tr_clear: [0.0; THREAD_RING],
            tr_used: [0; THREAD_RING],
            tr_head: 0,
            cp_t: Vec::new(),
            cp_head: 0,
            cp_n: 0,
        };
        s.reset(p);
        s
    }

    /// New run (`reset(ctx)`).
    pub fn reset(&mut self, p: &ScoringParams) {
        self.sc = p.scoring.clone();
        self.inset = p.lives.collision_inset_m;
        self.day_span_nudge_thread = pct_to_frac(p.sun.thread_nudge_pct);
        self.day_span_nudge_close = pct_to_frac(p.sun.close_pass_nudge_pct);
        self.cp_window = p.sun.close_pass_nudge_window_s;
        self.floor = self.sc.multiplier_start;
        self.min_v = self.sc.min_speed_mps();
        self.cut_v = self.sc.cut_min_speed_mps();
        self.slip_v = self.sc.slipstream_min_speed_mps();
        self.set_player_body(p.body.player_length_m, p.body.player_width_m);
        self.ensure_slots(p.body.max_active_vehicles);
        let n = usize::try_from(p.sun.close_pass_nudge_count.max(1)).unwrap_or(1);
        self.cp_t.resize(n, 0.0);
        self.t = 0.0;
        self.mult = self.floor;
        self.chain = 0;
        self.banked = 0;
        self.boost_fill = 0.0;
        self.night = false;
        self.night_f = 1.0;
        self.crew_f = 1.0;
        self.ghost = false;
        self.ended = false;
        self.reached_min = !self.sc.min_speed_grace_until_reached;
        self.hit_grace = 0.0;
        self.too_slow = false;
        self.slow_time = 0.0;
        self.hesitated = false;
        self.dipped = false;
        self.on_shoulder = false;
        self.shoulder_time = 0.0;
        self.penalty_block = 0.0;
        self.penalty = false;
        self.slip = false;
        self.prev_lane = -1;
        self.sf = 1.0;
        self.vid.fill(0);
        self.clear_thread_ring();
        self.cp_head = 0;
        self.cp_n = 0;
    }

    /// The player's visual body; the hull is inset by the collision inset on each side.
    pub fn set_player_body(&mut self, length_m: f64, width_m: f64) {
        self.p_hl = length_m * 0.5 - self.inset;
        self.p_hw = width_m * 0.5 - self.inset;
    }

    // ------------------------------------------------------------ Tick

    /// One tick (`step`): timers, then detection against `traffic`, then the multiplier.
    pub fn step<C: ScoringCars + ?Sized, R: ScoringRoad + ?Sized>(
        &mut self,
        dt: f64,
        player: &PlayerTick,
        traffic: &C,
        road: &R,
        out: &mut ScoreEventBuffer,
    ) {
        if !self.begin_tick(dt, player, road, out) {
            return;
        }
        self.detect(dt, player, traffic, road, out);
        self.end_tick(dt, player, out);
    }

    /// MP: the part of `step` before detection (time, speed factor, shoulder, minimum
    /// speed). False after the run ended (then skip the rest of the tick).
    pub fn begin_tick<R: ScoringRoad + ?Sized>(
        &mut self,
        dt: f64,
        player: &PlayerTick,
        road: &R,
        out: &mut ScoreEventBuffer,
    ) -> bool {
        if self.ended {
            return false;
        }
        self.t += dt;
        self.sf = self.sc.speed_factor(player.v);
        self.step_shoulder(dt, player.s, player.d, road, out);
        self.step_min_speed(dt, player.v, out);
        true
    }

    /// MP: the part of `step` after detection (multiplier decay, cash-out).
    pub fn end_tick(&mut self, dt: f64, player: &PlayerTick, out: &mut ScoreEventBuffer) {
        if self.ended {
            return;
        }
        self.step_multiplier(dt, player, out);
    }

    fn detect<C: ScoringCars + ?Sized, R: ScoringRoad + ?Sized>(
        &mut self,
        dt: f64,
        player: &PlayerTick,
        traffic: &C,
        road: &R,
        out: &mut ScoreEventBuffer,
    ) {
        let v = player.v;
        let ps = player.s;
        let pd = player.d;
        if traffic.capacity() > self.cap {
            self.ensure_slots(traffic.capacity());
        }
        let lane = road.lane_index_at(pd, ps);
        let mut slip = false;
        let slip_ok = !self.ghost && lane >= 0 && v >= self.slip_v;
        for i in 0..traffic.capacity() {
            if !traffic.active(i) {
                self.vid[i] = 0;
                continue;
            }
            let ds = traffic.s(i) - ps;
            let hl_sum = traffic.length(i) * 0.5 - self.inset + self.p_hl;
            if self.vid[i] != traffic.vehicle_id(i) {
                self.vid[i] = traffic.vehicle_id(i);
                self.cut_t[i] = f64::NEG_INFINITY;
                self.phase[i] = if ds >= hl_sum {
                    PHASE_AHEAD
                } else {
                    PHASE_NONE
                };
            }
            if slip_ok
                && !slip
                && traffic.lane(i) == lane
                && ds > 0.0
                && ds - hl_sum <= self.sc.slipstream_distance_m
            {
                slip = true;
            }
            let mut ph = self.phase[i];
            if ph == PHASE_AHEAD && ds < hl_sum {
                ph = PHASE_OVERLAP;
                self.min_clear[i] = f64::INFINITY;
                self.crossed[i] = 0;
                self.taint[i] = 0;
            }
            if ph == PHASE_OVERLAP {
                let clr = hull::clearance(
                    ps,
                    pd,
                    player.yaw,
                    self.p_hl,
                    self.p_hw,
                    traffic.s(i),
                    traffic.d(i),
                    traffic.v_lat(i).atan2(traffic.v(i)),
                    traffic.length(i) * 0.5 - self.inset,
                    traffic.width(i) * 0.5 - self.inset,
                );
                self.min_clear[i] = minf(self.min_clear[i], clr);
                if self.ghost {
                    self.taint[i] |= TAINT_GHOST;
                }
                if self.on_shoulder {
                    self.taint[i] |= TAINT_SHOULDER;
                }
                if ds <= 0.0 {
                    if self.crossed[i] == 0 {
                        self.crossed[i] = 1;
                        self.cross_dd[i] = traffic.d(i) - pd;
                        self.cross_t[i] = self.t;
                    }
                } else {
                    self.crossed[i] = 0;
                }
                if ds >= hl_sum {
                    ph = PHASE_AHEAD; // the player dropped back: no pass
                } else if ds <= -hl_sum {
                    ph = PHASE_NONE; // fully behind: the pass is complete
                    self.complete_pass(i, out);
                }
            } else if ph == PHASE_NONE && ds >= hl_sum {
                ph = PHASE_AHEAD;
            }
            self.phase[i] = ph;
        }
        // Cut: the player's centre crossed a lane line.
        if lane >= 0
            && self.prev_lane >= 0
            && lane != self.prev_lane
            && !self.ghost
            && v >= self.cut_v
        {
            self.try_cut(lane, self.prev_lane, ps, traffic, out);
        }
        self.prev_lane = lane;
        // Slipstream.
        if slip {
            self.boost_fill += pct_to_frac(self.sc.boost_fill_slipstream_pct_per_s) * dt;
        }
        if slip != self.slip {
            self.slip = slip;
            out.push_flag(Kind::Slipstream, slip);
        }
    }

    fn step_shoulder<R: ScoringRoad + ?Sized>(
        &mut self,
        dt: f64,
        ps: f64,
        pd: f64,
        road: &R,
        out: &mut ScoreEventBuffer,
    ) {
        // "Any wheel on the shoulder": either side of the hull is over a shoulder.
        let on = road.is_on_shoulder(pd - self.p_hw, ps) || road.is_on_shoulder(pd + self.p_hw, ps);
        if on {
            self.shoulder_time = if self.on_shoulder {
                self.shoulder_time + dt
            } else {
                dt
            };
        } else if self.on_shoulder && self.shoulder_time > self.sc.shoulder_penalty_after_s {
            self.penalty_block = self.sc.shoulder_penalty_block_s;
        } else if self.penalty_block > 0.0 {
            self.penalty_block -= dt;
        }
        self.on_shoulder = on;
        let pen = (on && self.shoulder_time > self.sc.shoulder_penalty_after_s)
            || self.penalty_block > 0.0;
        if pen != self.penalty {
            self.penalty = pen;
            out.push_flag(Kind::ShoulderPenalty, pen);
        }
    }

    fn step_min_speed(&mut self, dt: f64, v: f64, out: &mut ScoreEventBuffer) {
        if v >= self.min_v {
            self.reached_min = true;
        }
        if self.hit_grace > 0.0 {
            self.hit_grace -= dt;
        }
        let slow = self.reached_min && self.hit_grace <= 0.0 && v < self.min_v;
        if slow != self.too_slow {
            self.too_slow = slow;
            out.push_flag(Kind::TooSlow, slow);
        }
        if !slow {
            self.slow_time = 0.0;
            self.hesitated = false;
            return;
        }
        self.slow_time += dt;
        if self.slow_time > self.sc.hesitation_timeout_s && !self.hesitated {
            self.hesitated = true;
            out.push(Kind::Hesitated, 0, 0.0, -1.0, -1, 0.0, Tag::None);
            self.lose_chain(Tag::Hesitated, out);
            self.mult = self.floor;
        }
    }

    fn step_multiplier(&mut self, dt: f64, player: &PlayerTick, out: &mut ScoreEventBuffer) {
        if self.too_slow {
            self.mult = maxf(self.floor, self.mult - self.sc.below_min_drain_per_s * dt);
        } else {
            let mut rate = self.sc.multiplier_decay_per_s * self.sc.decay_term(player.v);
            if player.boost_active {
                rate *= self.sc.boost_decay_factor;
            }
            if self.on_shoulder {
                rate *= self.sc.shoulder_decay_factor;
            }
            self.mult = maxf(self.floor, self.mult - rate * dt);
        }
        if player.v < self.min_v {
            self.dipped = true;
        }
        // Cash-out: the multiplier is back at its floor and the player stayed above the
        // minimum speed since the last gain.
        if self.chain > 0 && self.mult <= self.floor && !self.dipped {
            self.bank(Tag::CashOut, out);
        }
    }

    // ------------------------------------------------------------ Events

    fn complete_pass(&mut self, i: usize, out: &mut ScoreEventBuffer) {
        let dd = self.cross_dd[i];
        if dd.abs() > self.sc.pass_lateral_window_m {
            return;
        }
        let clr = self.min_clear[i];
        let close = clr < self.sc.close_pass_clearance_m;
        let taint = self.taint[i];
        let slot = i as i32;
        if close && (taint & TAINT_GHOST) == 0 {
            out.push(Kind::NearMiss, 0, 0.0, clr, slot, 0.0, Tag::None);
        }
        if taint != 0 {
            return; // ghost period or shoulder during the overlap: scores nothing
        }
        if close {
            self.score(
                Kind::ClosePass,
                self.sc.close_pass_points,
                self.sc.close_pass_multiplier_gain,
                clr,
                slot,
                out,
            );
            self.boost_fill += pct_to_frac(self.sc.boost_fill_close_pass_pct);
            self.note_close_pass(out);
        } else {
            self.score(
                Kind::Pass,
                self.sc.pass_points,
                self.sc.pass_multiplier_gain,
                clr,
                slot,
                out,
            );
        }
        if clr < self.sc.thread_clearance_m {
            let side = if dd >= 0.0 { 1 } else { -1 };
            self.thread_check(i, side, self.cross_t[i], clr, out);
        }
    }

    /// One car on each side within the thread window, both under the thread clearance.
    fn thread_check(
        &mut self,
        i: usize,
        side: i32,
        cross_t: f64,
        clr: f64,
        out: &mut ScoreEventBuffer,
    ) {
        for k in 0..THREAD_RING {
            if self.tr_used[k] == 1
                || self.tr_side[k] != -side
                || (cross_t - self.tr_t[k]).abs() > self.sc.thread_window_s
            {
                continue;
            }
            self.tr_used[k] = 1;
            self.score(
                Kind::Thread,
                self.sc.thread_points,
                self.sc.thread_multiplier_gain,
                maxf(clr, self.tr_clear[k]),
                i as i32,
                out,
            );
            self.boost_fill += pct_to_frac(self.sc.boost_fill_thread_pct);
            out.push(
                Kind::SunNudge,
                0,
                0.0,
                -1.0,
                -1,
                self.day_span_nudge_thread,
                Tag::None,
            );
            return;
        }
        let h = self.tr_head;
        self.tr_t[h] = cross_t;
        self.tr_side[h] = side;
        self.tr_clear[h] = clr;
        self.tr_used[h] = 0;
        self.tr_head = (h + 1) % THREAD_RING;
    }

    /// N close passes within the window lift the sun (then the count starts over).
    fn note_close_pass(&mut self, out: &mut ScoreEventBuffer) {
        let n = self.cp_t.len();
        self.cp_t[self.cp_head] = self.t;
        self.cp_head = (self.cp_head + 1) % n;
        self.cp_n += 1;
        if self.cp_n >= n as i64 && self.t - self.cp_t[self.cp_head] <= self.cp_window {
            self.cp_n = 0;
            out.push(
                Kind::SunNudge,
                0,
                0.0,
                -1.0,
                -1,
                self.day_span_nudge_close,
                Tag::None,
            );
        }
    }

    fn try_cut<C: ScoringCars + ?Sized>(
        &mut self,
        lane: i32,
        prev_lane: i32,
        ps: f64,
        traffic: &C,
        out: &mut ScoreEventBuffer,
    ) {
        let mut nearest: i32 = -1;
        let mut nearest_gap = f64::INFINITY;
        for i in 0..traffic.capacity() {
            if !self.cut_candidate(i, lane, prev_lane, ps, traffic) {
                continue;
            }
            let gap =
                (traffic.s(i) - ps).abs() - (traffic.length(i) * 0.5 - self.inset + self.p_hl);
            if gap < nearest_gap {
                nearest_gap = gap;
                nearest = i as i32;
            }
        }
        if nearest < 0 {
            return; // no traffic nearby (or all of it on cooldown): weaving scores nothing
        }
        for i in 0..traffic.capacity() {
            if self.cut_candidate(i, lane, prev_lane, ps, traffic) {
                self.cut_t[i] = self.t;
            }
        }
        self.score(
            Kind::Cut,
            self.sc.cut_points,
            self.sc.cut_multiplier_gain,
            -1.0,
            nearest,
            out,
        );
    }

    fn cut_candidate<C: ScoringCars + ?Sized>(
        &self,
        i: usize,
        lane: i32,
        prev_lane: i32,
        ps: f64,
        traffic: &C,
    ) -> bool {
        if !traffic.active(i) || (traffic.lane(i) != lane && traffic.lane(i) != prev_lane) {
            return false;
        }
        if self.t - self.cut_t[i] < self.sc.cut_per_car_cooldown_s {
            return false;
        }
        let gap = (traffic.s(i) - ps).abs() - (traffic.length(i) * 0.5 - self.inset + self.p_hl);
        gap <= self.sc.cut_traffic_window_m
    }

    /// Pays one scored event (`_score`); returns its points.
    fn score(
        &mut self,
        kind: Kind,
        base: i64,
        gain: f64,
        clearance: f64,
        slot: i32,
        out: &mut ScoreEventBuffer,
    ) -> i64 {
        let pts = (base as f64 * self.mult * self.sf * self.night_f * self.crew_f).round() as i64;
        out.push(kind, pts, self.mult, clearance, slot, 0.0, Tag::None);
        self.chain += pts;
        if !self.gains_blocked() {
            self.mult += gain;
            self.dipped = false;
        }
        pts
    }

    fn bank(&mut self, reason: Tag, out: &mut ScoreEventBuffer) {
        if self.chain <= 0 {
            return;
        }
        let amount = self.chain;
        self.chain = 0;
        self.banked += amount;
        out.push(
            Kind::Banked,
            amount,
            self.mult,
            -1.0,
            -1,
            self.banked as f64,
            reason,
        );
    }

    fn lose_chain(&mut self, reason: Tag, out: &mut ScoreEventBuffer) {
        if self.chain <= 0 {
            return;
        }
        let amount = self.chain;
        self.chain = 0;
        out.push(Kind::ChainLost, amount, self.mult, -1.0, -1, 0.0, reason);
    }

    // ------------------------------------------------------------ Run hooks

    /// Night doubles everything scored.
    pub fn set_night(&mut self, on: bool) {
        self.night = on;
        self.night_f = if on { self.sc.night_factor } else { 1.0 };
    }

    /// The ghost period after a hit: nothing scores (a pass whose overlap touches it
    /// never scores; cuts and slipstream are off).
    pub fn set_ghost(&mut self, on: bool) {
        self.ghost = on;
    }

    /// A hit: the chain is lost, the multiplier drops to its start, the minimum-speed rule
    /// pauses for the grace period.
    pub fn notify_hit(&mut self, out: &mut ScoreEventBuffer) {
        if self.ended {
            return;
        }
        self.lose_chain(Tag::Hit, out);
        self.mult = self.floor;
        self.hit_grace = self.sc.min_speed_grace_after_hit_s;
        self.slow_time = 0.0;
        self.hesitated = false;
        if self.too_slow {
            self.too_slow = false;
            out.push_flag(Kind::TooSlow, false);
        }
        self.clear_thread_ring();
    }

    /// Checkpoint (a sector gantry in multiplayer): the chain banks, the multiplier is kept.
    pub fn notify_checkpoint(&mut self, out: &mut ScoreEventBuffer) {
        if self.ended {
            return;
        }
        self.bank(Tag::Checkpoint, out);
    }

    /// Straight into the banked total, × the night factor while night is on.
    pub fn award_bonus(&mut self, bonus: Tag, base_points: i64, out: &mut ScoreEventBuffer) -> i64 {
        if self.ended {
            return 0;
        }
        let pts = (base_points as f64 * self.night_f).round() as i64;
        self.banked += pts;
        out.push(Kind::Bonus, pts, 0.0, -1.0, -1, self.banked as f64, bonus);
        pts
    }

    /// Run over: the held chain is lost; the final score is `banked()`.
    pub fn notify_run_end(&mut self, out: &mut ScoreEventBuffer) {
        if self.ended {
            return;
        }
        self.lose_chain(Tag::RunEnd, out);
        self.ended = true;
    }

    // ------------------------------------------------------------ MP additions

    /// MP: crew proximity (spec: +0.25× per crewmate within 30 m, capped at ×2.0) as a
    /// factor on every scored event's points. 1.0 = no crewmate.
    pub fn set_crew_factor(&mut self, f: f64) {
        self.crew_f = f;
    }

    pub fn crew_factor(&self) -> f64 {
        self.crew_f
    }

    /// MP: pays one event the way detection would (`_score`: points from the current
    /// multiplier, speed, night and crew factors; the gain unless gains are blocked).
    /// Call between [`begin_tick`](Self::begin_tick) and [`end_tick`](Self::end_tick).
    /// Returns the points (0 after the run ended).
    pub fn award(
        &mut self,
        kind: Kind,
        base: i64,
        gain: f64,
        clearance: f64,
        out: &mut ScoreEventBuffer,
    ) -> i64 {
        if self.ended {
            return 0;
        }
        self.score(kind, base, gain, clearance, -1, out)
    }

    /// MP: "Rejoin crew" forfeits the unbanked chain (tag `rejoin`); the multiplier drops
    /// to its start, as after a hit, without the hit's grace.
    pub fn forfeit_chain(&mut self, out: &mut ScoreEventBuffer) {
        if self.ended {
            return;
        }
        self.lose_chain(Tag::Rejoin, out);
        self.mult = self.floor;
        self.clear_thread_ring();
    }

    // ------------------------------------------------------------ Queries

    pub fn multiplier(&self) -> f64 {
        self.mult
    }

    pub fn chain(&self) -> i64 {
        self.chain
    }

    pub fn banked(&self) -> i64 {
        self.banked
    }

    /// Boost fill earned since the last call.
    pub fn take_boost_fill(&mut self) -> f64 {
        let f = self.boost_fill;
        self.boost_fill = 0.0;
        f
    }

    pub fn is_too_slow(&self) -> bool {
        self.too_slow
    }

    pub fn is_on_shoulder(&self) -> bool {
        self.on_shoulder
    }

    pub fn shoulder_penalty_active(&self) -> bool {
        self.penalty
    }

    /// Multiplier gains are blocked (on the shoulder, or the shoulder penalty).
    pub fn gains_blocked(&self) -> bool {
        self.on_shoulder || self.penalty
    }

    pub fn is_slipstreaming(&self) -> bool {
        self.slip
    }

    pub fn is_ghost(&self) -> bool {
        self.ghost
    }

    pub fn is_night(&self) -> bool {
        self.night
    }

    pub fn is_ended(&self) -> bool {
        self.ended
    }

    /// Rule time (s since the run started).
    pub fn time(&self) -> f64 {
        self.t
    }

    pub fn tuning(&self) -> &ScoringTuning {
        &self.sc
    }

    /// Hash of the rule state (determinism traces), as `hash_into`.
    pub fn hash_into(&self, mut h: u64) -> u64 {
        h = mix_float(h, self.t);
        h = mix_float(h, self.mult);
        h = mix_int(h, self.chain);
        h = mix_int(h, self.banked);
        h = mix_float(h, self.boost_fill);
        h = mix_float(h, self.slow_time);
        h = mix_float(h, self.hit_grace);
        h = mix_float(h, self.shoulder_time);
        h = mix_float(h, self.penalty_block);
        h = mix_int(h, i64::from(self.prev_lane));
        h = mix_bool(h, self.too_slow);
        h = mix_bool(h, self.dipped);
        h = mix_bool(h, self.slip);
        for &x in &self.vid[..self.cap] {
            h = mix_int(h, i64::from(x));
        }
        for &x in &self.phase[..self.cap] {
            h = mix_int(h, i64::from(x));
        }
        for &x in &self.min_clear[..self.cap] {
            h = mix_float(h, x);
        }
        for &x in &self.cut_t[..self.cap] {
            h = mix_float(h, x);
        }
        h
    }

    pub fn trace_hash(&self) -> u64 {
        self.hash_into(SEED)
    }

    // ------------------------------------------------------------ Storage

    fn ensure_slots(&mut self, n: usize) {
        if n <= self.cap {
            return;
        }
        self.vid.resize(n, 0);
        self.phase.resize(n, 0);
        self.taint.resize(n, 0);
        self.crossed.resize(n, 0);
        self.min_clear.resize(n, 0.0);
        self.cross_dd.resize(n, 0.0);
        self.cross_t.resize(n, 0.0);
        self.cut_t.resize(n, 0.0);
        for x in &mut self.vid[self.cap..n] {
            *x = 0;
        }
        self.cap = n;
    }

    fn clear_thread_ring(&mut self) {
        self.tr_used = [1; THREAD_RING];
        self.tr_head = 0;
    }
}
