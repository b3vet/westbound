//! N4.4: a bot's prediction of the traffic it is streamed, and the correction sizes and
//! late intents a client would see. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Testing →
//! Netcode harness (acceptance: "median traffic correction under 0.15 m, 99th percentile
//! under 0.6 m", "late intents under 1 per 10 minutes"); docs/NET_TRAFFIC.md (the client's
//! model, `NetworkTrafficSource` + `TrafficCorrector`, and what it measures).
//!
//! [`TrafficPredictor`] is a compact Rust port of the client's model, enough to measure
//! what the client measures against the real server's stream:
//!
//! - every streamed car runs the server's longitudinal model at room ticks: the ballistic
//!   step with the acceleration held from the tick before, then IDM against the nearest
//!   vehicle ahead whose lateral interval overlaps (a moving car spans to its target; the
//!   players stretched by their lateral velocity), the racers' weaving parameters, the
//!   MP-D5 look-through and leader-braking anticipation, hard brakes, the 6 m/s² clamp;
//! - the desired speed (not on the wire) is estimated at each correction from the server's
//!   own mean acceleration when the car drove free, else the unexplained acceleration goes
//!   into a fading per-car bias (NetTuning's `traffic_v0_*`, `traffic_bias_*`);
//! - lane changes come only from intents, on the server's curve.
//!
//! - the lane-drop harmonisation zones (WP6.8), as the client mirrors them: each drop's
//!   zone from `lane_drop_slow_zone_m` before its taper to `lane_drop_slow_after_m` past
//!   the lanes coming back, the eased braking into it, the speed cap and the matching of
//!   slow desired speeds toward the merge-lane speed (inverted in the estimate).
//!
//! Not ported (docs/NET_TRAFFIC.md: corrections cover them): the merge zones, the zipper,
//! the closure wall, the player's cut-in brake tap. So its error is an upper bound on the
//! client's.
//!
//! **Measured per correction** (the client's `add_correction`): the error between the
//! correction and the model at the correction's tick, `hypot(e_s, e_d)`, for every car and
//! for cars within 100 m of the bot; and, for comparison, the error of plain dead
//! reckoning (the last correction carried on at its speed). **Late intents:** a lane
//! change arriving later than 0.25 s before its move tick (after it: very late), by the
//! bot's estimate of the room clock at arrival.

use std::collections::HashMap;

use protocol::{
    CorrectionEntry, IntentKind, LaneChangePhase, TrafficIntentEntry, TrafficSpawnEntry,
};
use sim::map::LoopMap;
use sim::scoring::LoopRoad;
use sim::traffic::idm;
use sim::traffic::{RoadSpace, TrafficParams};

const MM_PER_M: f64 = 1_000.0;
const CM_PER_M: f64 = 100.0;
const MS_PER_S: f64 = 1_000.0;
/// The wire's ramp lane (MP-D6).
const RAMP_LANE: u8 = 7;
/// Correction-size histogram: 5 mm bins up to 2 m (the client's), then an overflow bin.
const BIN_M: f64 = 0.005;
const BINS: usize = 400;
const SMOOTH_A: f64 = 3.0;

/// The client's `NetTuning` numbers the model uses (data/tuning/net.tres).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetRules {
    pub tick_rate_hz: f64,
    /// `traffic_correction_near_m`.
    pub near_m: f64,
    /// `traffic_late_min_blinker_s`.
    pub late_min_blinker_s: f64,
    /// `traffic_unsignaled_lateral_m`.
    pub unsignaled_lateral_m: f64,
    pub v0_gain: f64,
    pub v0_free_accel_mps2: f64,
    pub v0_margin_frac: f64,
    pub bias_gain: f64,
    pub bias_max_mps2: f64,
    pub bias_fade_s: f64,
    /// Snaps: a correction this large (m) is a snap out of view, a slide in view
    /// (`traffic_blend_medium_m`); in view from `visible_behind_m` behind to
    /// `visible_ahead_m` ahead.
    pub snap_m: f64,
    pub visible_behind_m: f64,
    pub visible_ahead_m: f64,
}

impl Default for NetRules {
    fn default() -> Self {
        Self {
            tick_rate_hz: 20.0,
            near_m: 100.0,
            late_min_blinker_s: 0.25,
            unsignaled_lateral_m: 0.6,
            v0_gain: 0.5,
            v0_free_accel_mps2: 0.15,
            v0_margin_frac: 0.1,
            bias_gain: 1.0,
            bias_max_mps2: 2.0,
            bias_fade_s: 6.0,
            snap_m: 5.0,
            visible_behind_m: 60.0,
            visible_ahead_m: 800.0,
        }
    }
}

/// Per-profile IDM numbers as the client caches them (`_init_profiles`).
#[derive(Debug, Clone, Copy, PartialEq)]
struct Profile {
    a: f64,
    b: f64,
    t: f64,
    s0: f64,
    delta: i32,
    weave: bool,
    w_tk: f64,
    w_s0: f64,
    w_b: f64,
    v0_lo: f64,
    v0_hi: f64,
    v0_mid: f64,
}

/// The exported traffic tuning the model needs.
#[derive(Debug, Clone)]
pub struct ModelParams {
    profiles: Vec<Profile>,
    types: Vec<(f64, f64)>,
    max_decel: f64,
    look: f64,
    gap_floor: f64,
    lat_m: f64,
    antic_s: f64,
    hit_decel: f64,
    // The lane-drop zones (WP6.8).
    drop_slow: f64,
    drop_after: f64,
    drop_narrow: f64,
    drop_view: f64,
    drop_release: f64,
    drop_onset: f64,
    v_through: f64,
    v_merge: f64,
    player_len: f64,
    player_width: f64,
    pub net: NetRules,
}

impl ModelParams {
    /// From the compiled-in export (`sim::traffic::TrafficParams::builtin`).
    pub fn builtin() -> Self {
        let p = TrafficParams::builtin().expect("the compiled-in traffic export");
        let net = NetRules::default();
        let t = &p.tuning;
        let scale = p.loop_traffic.headway_scale;
        let v_merge = t.lane_drop_merge_lane_mps;
        let profiles = p
            .profiles
            .iter()
            .map(|d| {
                let hw = d.idm_headway_vs_traffic_s;
                Profile {
                    a: d.a_max_mps2,
                    b: d.b_comfort_mps2,
                    t: d.headway_s * scale,
                    s0: d.s0_m,
                    delta: d.delta,
                    weave: hw >= 0.0
                        || d.idm_s0_vs_traffic_m >= 0.0
                        || d.idm_b_comfort_vs_traffic_mps2 > 0.0
                        || d.mobil_b_safe_vs_traffic_mps2 > 0.0
                        || d.lookahead_lane_choice_m > 0.0
                        || d.lane_change_cooldown_s >= 0.0
                        || d.lane_change_cap_count > 0,
                    w_tk: if hw >= 0.0 && d.raw_headway_s > 0.0 {
                        hw / d.raw_headway_s
                    } else {
                        1.0
                    },
                    w_s0: if d.idm_s0_vs_traffic_m >= 0.0 {
                        d.idm_s0_vs_traffic_m
                    } else {
                        d.s0_m
                    },
                    w_b: if d.idm_b_comfort_vs_traffic_mps2 > 0.0 {
                        d.idm_b_comfort_vs_traffic_mps2
                    } else {
                        d.b_comfort_mps2
                    },
                    v0_lo: d.v0_min_mps * (1.0 - net.v0_margin_frac),
                    v0_hi: (d.v0_max_mps * (1.0 + net.v0_margin_frac)).max(v_merge),
                    v0_mid: (d.v0_min_mps + d.v0_max_mps) * 0.5,
                }
            })
            .collect();
        Self {
            profiles,
            types: p.types.iter().map(|x| (x.length_m, x.width_m)).collect(),
            max_decel: t.max_decel_mps2,
            look: t.idm_lookahead_m,
            gap_floor: t.idm_gap_floor_m,
            lat_m: t.lateral_margin_m,
            antic_s: t.player_lateral_anticipation_s,
            hit_decel: t.hit_brake_decel_mps2,
            drop_slow: t.lane_drop_slow_zone_m,
            drop_after: t.lane_drop_slow_after_m,
            drop_narrow: t.lane_drop_narrow_max_m,
            drop_view: t.lane_drop_view_m,
            drop_release: t.lane_drop_release_m,
            drop_onset: t.lane_drop_brake_onset_frac,
            v_through: t.lane_drop_through_mps,
            v_merge,
            player_len: t.player_length_m,
            player_width: t.player_width_m,
            net,
        }
    }

    fn profile(&self, p: u8) -> Profile {
        let i = usize::from(p).min(self.profiles.len().saturating_sub(1));
        self.profiles[i]
    }

    fn body(&self, vehicle: u8) -> (f64, f64) {
        self.types
            .get(usize::from(vehicle))
            .copied()
            .unwrap_or((4.5, 1.8))
    }
}

/// A player as a participant (the bot itself, the others it is relayed), at the model's
/// tick: wrapped s (m), d, forward and lateral speed.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Participant {
    pub s_m: f64,
    pub d: f64,
    pub v: f64,
    pub v_lat: f64,
}

/// A lane change's plan (the server's curve).
#[derive(Debug, Clone, Copy, PartialEq)]
struct Plan {
    blink: f64,
    move_t: f64,
    dur: f64,
    from: f64,
    to: f64,
    /// A cancel dated ahead: the plan ends there.
    cancel: f64,
}

#[derive(Debug, Clone)]
struct Car {
    id: u16,
    profile: Profile,
    hl: f64,
    width: f64,
    /// Wrapped s (m).
    s: f64,
    v: f64,
    /// The acceleration at the model tick (integrated over the next step), and the one
    /// the last step integrated with.
    a: f64,
    a_held: f64,
    d_base: f64,
    plan: Option<Plan>,
    v0e: f64,
    /// The drop zones' matching factor at the last evaluation (0: none).
    matchf: f64,
    bias: f64,
    last_ct: Option<u32>,
    last_cv: f64,
    last_cs: f64,
    int_sum: f64,
    int_n: u32,
    brake_from: f64,
    brake_until: f64,
}

/// Correction sizes (5 mm bins to 2 m).
#[derive(Debug, Clone)]
pub struct SizeHist {
    bins: Vec<u64>,
    pub n: u64,
    pub sum: f64,
    pub max: f64,
}

impl Default for SizeHist {
    fn default() -> Self {
        Self {
            bins: vec![0; BINS + 1],
            n: 0,
            sum: 0.0,
            max: 0.0,
        }
    }
}

impl SizeHist {
    pub fn add(&mut self, err_m: f64) {
        let bin = ((err_m / BIN_M).floor() as usize).min(BINS);
        self.bins[bin] += 1;
        self.n += 1;
        self.sum += err_m;
        self.max = self.max.max(err_m);
    }

    /// The upper edge (m) of the bin holding quantile `q` (0..1); the max beyond 2 m.
    pub fn quantile(&self, q: f64) -> f64 {
        if self.n == 0 {
            return 0.0;
        }
        let need = ((q * self.n as f64).ceil() as u64).max(1);
        let mut seen = 0;
        for (i, &c) in self.bins.iter().enumerate() {
            seen += c;
            if seen >= need {
                return if i == BINS {
                    self.max
                } else {
                    (i + 1) as f64 * BIN_M
                };
            }
        }
        self.max
    }

    pub fn mean(&self) -> f64 {
        self.sum / self.n.max(1) as f64
    }

    /// Corrections larger than `m`.
    pub fn above(&self, m: f64) -> u64 {
        let from = ((m / BIN_M).floor() as usize + 1).min(BINS);
        self.bins[from..].iter().sum()
    }

    pub fn merge(&mut self, o: &SizeHist) {
        for (a, b) in self.bins.iter_mut().zip(&o.bins) {
            *a += b;
        }
        self.n += o.n;
        self.sum += o.sum;
        self.max = self.max.max(o.max);
    }
}

/// What the predictor measured.
#[derive(Debug, Clone, Default)]
pub struct NetStats {
    /// Every correction, and those of cars within `near_m` of the bot: the model's error.
    pub all: SizeHist,
    pub near: SizeHist,
    /// The same corrections against dead reckoning (the last correction at its speed).
    pub dead_reckoning: SizeHist,
    /// Corrections of at least `snap_m` for a car in view (a client slides these).
    pub large_in_view: u64,
    /// Lateral errors of at least `unsignaled_lateral_m` with no lane change planned.
    pub unsignaled_lateral: u64,
    pub intents: u64,
    /// Lane changes arriving later than 0.25 s before their move tick, and after it.
    pub late_intents: u64,
    pub very_late_intents: u64,
    pub cancels: u64,
    /// Cancels arriving after the move started.
    pub late_cancels: u64,
    /// Frames and model ticks run.
    pub frames: u64,
    pub model_ticks: u64,
    /// The model jumped more than `MAX_CATCHUP` ticks (a stall) and re-anchored.
    pub reanchors: u64,
}

impl NetStats {
    pub fn merge(&mut self, o: &NetStats) {
        self.all.merge(&o.all);
        self.near.merge(&o.near);
        self.dead_reckoning.merge(&o.dead_reckoning);
        self.large_in_view += o.large_in_view;
        self.unsignaled_lateral += o.unsignaled_lateral;
        self.intents += o.intents;
        self.late_intents += o.late_intents;
        self.very_late_intents += o.very_late_intents;
        self.cancels += o.cancels;
        self.late_cancels += o.late_cancels;
        self.frames += o.frames;
        self.model_ticks += o.model_ticks;
        self.reanchors += o.reanchors;
    }
}

/// The model steps at most this many ticks to reach a frame; more re-anchors it.
const MAX_CATCHUP: u32 = 200;

/// The client's traffic model on a bot (see the module docs).
pub struct TrafficPredictor {
    params: ModelParams,
    cars: Vec<Car>,
    slot_of: HashMap<u16, usize>,
    /// The model's room tick.
    tick: Option<u32>,
    tick_dt: f64,
    ord: Vec<usize>,
    /// Sort keys this tick: s relative to the bot, v, half length, lateral interval, and
    /// whether the entry is a player (index ≥ cars.len()).
    ks: Vec<f64>,
    kv: Vec<f64>,
    khl: Vec<f64>,
    klo: Vec<f64>,
    khi: Vec<f64>,
    players: Vec<Participant>,
    /// The loop's lane-drop zones (first merge lane, s0, s1), built at the first frame.
    zones: Option<Vec<(i32, f64, f64)>>,
    pub stats: NetStats,
}

impl TrafficPredictor {
    pub fn new(params: ModelParams) -> Self {
        let tick_dt = 1.0 / params.net.tick_rate_hz;
        Self {
            params,
            cars: Vec::with_capacity(160),
            slot_of: HashMap::with_capacity(160),
            tick: None,
            tick_dt,
            ord: Vec::with_capacity(170),
            ks: Vec::with_capacity(170),
            kv: Vec::with_capacity(170),
            khl: Vec::with_capacity(170),
            klo: Vec::with_capacity(170),
            khi: Vec::with_capacity(170),
            players: Vec::with_capacity(8),
            zones: None,
            stats: NetStats::default(),
        }
    }

    /// A room snapshot: the client clears its cars.
    pub fn reset(&mut self) {
        self.cars.clear();
        self.slot_of.clear();
        self.tick = None;
    }

    pub fn car_count(&self) -> usize {
        self.cars.len()
    }

    pub fn model_tick(&self) -> Option<u32> {
        self.tick
    }

    /// Brings the model to `tick` (a frame's correction tick) with the players at it.
    /// `players[0]` is the bot itself (the near and view distances are from it).
    pub fn advance_to(&mut self, tick: u32, map: &LoopMap, players: &[Participant]) {
        self.stats.frames += 1;
        if self.zones.is_none() {
            self.zones = Some(drop_zones(&self.params, map));
        }
        self.players.clear();
        self.players.extend_from_slice(players);
        let Some(t0) = self.tick else {
            self.tick = Some(tick);
            return;
        };
        let steps = tick.wrapping_sub(t0);
        if steps > MAX_CATCHUP {
            // A stall (or a clock step back): start over from here; the next
            // corrections re-anchor every car.
            if steps < u32::MAX / 2 {
                self.stats.reanchors += 1;
            }
            self.tick = Some(tick);
            return;
        }
        for _ in 0..steps {
            self.step(map);
        }
    }

    fn step(&mut self, map: &LoopMap) {
        let dt = self.tick_dt;
        let fade = (dt / self.params.net.bias_fade_s.max(dt)).min(1.0);
        for c in &mut self.cars {
            let a = c.a;
            c.a_held = a;
            let v = c.v;
            let mut nv = v + a * dt;
            if nv < 0.0 {
                if a < 0.0 {
                    c.s = map.wrap_m(c.s - v * v / (2.0 * a));
                }
                nv = 0.0;
            } else {
                c.s = map.wrap_m(c.s + (v + nv) * 0.5 * dt);
            }
            c.v = nv;
            c.bias -= c.bias * fade;
        }
        let t = self.tick.map_or(0, |t| t.wrapping_add(1));
        self.tick = Some(t);
        self.stats.model_ticks += 1;
        // Lane changes that finished: the car is in its new lane.
        let tf = f64::from(t);
        for c in &mut self.cars {
            if let Some(p) = c.plan {
                if tf >= p.cancel {
                    c.plan = None;
                } else if tf >= p.move_t + p.dur {
                    c.d_base = p.to;
                    c.plan = None;
                }
            }
        }
        self.accel_pass(map, true);
    }

    /// The model's d of car `c` at tick `t` (and whether it is moving sideways).
    fn lat_at(c: &Car, t: f64) -> (f64, bool) {
        let Some(p) = c.plan else {
            return (c.d_base, false);
        };
        if t < p.blink || t >= p.cancel || t < p.move_t {
            return (p.from, false);
        }
        let u = ((t - p.move_t) / p.dur).clamp(0.0, 1.0);
        (p.from + (p.to - p.from) * smooth(u), true)
    }

    /// The sort keys at the model tick and the order by s (insertion sort: nearly sorted
    /// from the tick before).
    fn sort(&mut self, map: &LoopMap) {
        let n = self.cars.len();
        let np = self.players.len();
        let total = n + np;
        let tf = f64::from(self.tick.unwrap_or(0));
        let me = self.players.first().map_or(0.0, |p| p.s_m);
        self.ks.resize(total, 0.0);
        self.kv.resize(total, 0.0);
        self.khl.resize(total, 0.0);
        self.klo.resize(total, 0.0);
        self.khi.resize(total, 0.0);
        for (i, c) in self.cars.iter().enumerate() {
            self.ks[i] = map.signed_delta_m(me, c.s);
            self.kv[i] = c.v;
            self.khl[i] = c.hl;
            let (d, moving) = Self::lat_at(c, tf);
            let hw = c.width * 0.5;
            let (mut lo, mut hi) = (d - hw, d + hw);
            if moving {
                if let Some(p) = c.plan {
                    lo = lo.min(p.to - hw);
                    hi = hi.max(p.to + hw);
                }
            }
            self.klo[i] = lo;
            self.khi[i] = hi;
        }
        let (plen, pw, antic) = (
            self.params.player_len,
            self.params.player_width,
            self.params.antic_s,
        );
        for (k, p) in self.players.iter().enumerate() {
            let i = n + k;
            let ahead = p.v_lat * antic;
            self.ks[i] = map.signed_delta_m(me, p.s_m);
            self.kv[i] = p.v;
            self.khl[i] = plen * 0.5;
            self.klo[i] = p.d - pw * 0.5 + ahead.min(0.0);
            self.khi[i] = p.d + pw * 0.5 + ahead.max(0.0);
        }
        if self.ord.len() != total || self.ord.iter().any(|&i| i >= total) {
            self.ord.clear();
            self.ord.extend(0..total);
        }
        for k in 1..total {
            let x = self.ord[k];
            let sx = self.ks[x];
            let mut m = k;
            while m > 0 && self.ks[self.ord[m - 1]] > sx {
                self.ord[m] = self.ord[m - 1];
                m -= 1;
            }
            self.ord[m] = x;
        }
    }

    /// Every car's acceleration at the model tick (`_accel_pass`). `advance`: a real model
    /// tick (the estimator's interaction sums).
    fn accel_pass(&mut self, map: &LoopMap, advance: bool) {
        self.sort(map);
        let n = self.cars.len();
        let total = self.ord.len();
        let tk = f64::from(self.tick.unwrap_or(0));
        let (look, floor, lat_m) = (self.params.look, self.params.gap_floor, self.params.lat_m);
        for k in 0..total {
            let i = self.ord[k];
            if i >= n {
                continue;
            }
            let c = &self.cars[i];
            let p = c.profile;
            let (si, vi) = (self.ks[i], self.kv[i]);
            let (drop_a, v0, matchf) = self.drop_accel(c, map, vi);
            let lo = self.klo[i] - lat_m;
            let hi = self.khi[i] + lat_m;
            let mut lead = None;
            let mut kk = k + 1;
            while kk < total {
                let j = self.ord[kk];
                if self.ks[j] - si > look {
                    break;
                }
                if self.klo[j] < hi && self.khi[j] > lo {
                    lead = Some(j);
                    break;
                }
                kk += 1;
            }
            let free = idm::free_accel(vi, v0, p.a, p.delta);
            let mut a = free;
            if let Some(l) = lead {
                let gap = self.ks[l] - si - self.khl[l] - self.khl[i];
                a = self.idm_to(p, l < n, vi, v0, gap, self.kv[l], floor);
                // MP-D5: past a leader leaving the path, the next one counts too.
                if l < n && self.leaving_path(l, lo, hi, tk) {
                    a = a.min(self.look_through(i, l, kk, lo, hi, vi, v0, p, tk));
                }
                // MP-D5: the leader's own stopping point.
                let (vl, al) = (self.kv[l], if l < n { self.cars[l].a_held } else { 0.0 });
                if al < 0.0 || vl <= 0.0 {
                    let stop_l = if al < 0.0 { vl * vl / (-2.0 * al) } else { 0.0 };
                    let room = gap - p.s0 + stop_l;
                    let a_stop = if room > 0.0 {
                        -(vi * vi) / (2.0 * room)
                    } else {
                        f64::NEG_INFINITY
                    };
                    if a_stop < -p.b {
                        a = a.min(a_stop);
                    }
                }
            }
            a = a.min(drop_a);
            let c = &mut self.cars[i];
            c.matchf = matchf;
            if advance {
                c.int_sum += free - a;
                c.int_n += 1;
            }
            a += c.bias;
            if tk >= c.brake_from && tk < c.brake_until {
                a = a.min(-self.params.hit_decel);
            }
            c.a = a.max(-self.params.max_decel);
        }
    }

    /// The harmonisation zones for car `c` (`_drop_accel`): their acceleration limit, the
    /// matched desired speed and the matching factor.
    fn drop_accel(&self, c: &Car, map: &LoopMap, vi: f64) -> (f64, f64, f64) {
        let pr = &self.params;
        let p = c.profile;
        let front = map.wrap_m(c.s + c.hl);
        let road = LoopRoad::new(map);
        let lane = sim::scoring::ScoringRoad::lane_index_at(&road, c.d_base, c.s);
        let (mut m, mut acc, mut lim) = (0.0f64, f64::INFINITY, f64::INFINITY);
        for &(first, s0, s1) in self.zones.as_deref().unwrap_or(&[]) {
            let past = map.signed_delta_m(s1, front);
            if past > 0.0 {
                m = m.max(1.0 - past / pr.drop_release);
                continue;
            }
            let vz = if lane >= first {
                pr.v_merge
            } else {
                pr.v_through
            };
            let ahead = map.signed_delta_m(front, s0);
            if ahead <= 0.0 {
                lim = lim.min(vz);
                m = 1.0;
            } else if ahead < pr.drop_view {
                lim = lim.min((vz * vz + 2.0 * p.b * ahead).sqrt());
                if vi > vz {
                    let req = (vz * vz - vi * vi) / (2.0 * ahead);
                    let ease =
                        ((-req / p.b - pr.drop_onset) / (1.0 - pr.drop_onset)).clamp(0.0, 1.0);
                    acc = acc.min((req * ease).max(-p.b));
                }
            }
        }
        let v0 = c.v0e;
        let v0e = if v0 < pr.v_merge {
            v0 + (pr.v_merge - v0) * m
        } else {
            v0
        };
        if lim < v0e {
            acc = acc.min(idm::free_accel(vi, lim, p.a, p.delta));
        }
        (acc, v0e, m)
    }

    #[allow(clippy::too_many_arguments)]
    fn idm_to(
        &self,
        p: Profile,
        traffic: bool,
        v: f64,
        v0: f64,
        gap: f64,
        vl: f64,
        floor: f64,
    ) -> f64 {
        if p.weave && traffic {
            idm::accel(
                v,
                v0,
                gap,
                v - vl,
                p.a,
                p.w_b,
                p.t * p.w_tk,
                p.w_s0,
                p.delta,
                floor,
            )
        } else {
            idm::accel(v, v0, gap, v - vl, p.a, p.b, p.t, p.s0, p.delta, floor)
        }
    }

    /// A lane change signalled or moving at `tk` whose target body is off [lo, hi].
    fn leaving_path(&self, j: usize, lo: f64, hi: f64, tk: f64) -> bool {
        let c = &self.cars[j];
        let Some(p) = c.plan else {
            return false;
        };
        if tk < p.blink || tk >= p.cancel {
            return false;
        }
        let hw = c.width * 0.5;
        !(p.to - hw < hi && p.to + hw > lo)
    }

    #[allow(clippy::too_many_arguments)]
    fn look_through(
        &self,
        i: usize,
        l: usize,
        lk: usize,
        lo: f64,
        hi: f64,
        vi: f64,
        v0: f64,
        p: Profile,
        tk: f64,
    ) -> f64 {
        let n = self.cars.len();
        let si = self.ks[i];
        let mut a = f64::INFINITY;
        let mut cur = l;
        let mut kk = lk + 1;
        while cur < n && self.leaving_path(cur, lo, hi, tk) {
            let mut next = None;
            while kk < self.ord.len() {
                let j = self.ord[kk];
                kk += 1;
                if j == i || self.ks[j] - si > self.params.look {
                    break;
                }
                if self.klo[j] < hi && self.khi[j] > lo {
                    next = Some(j);
                    break;
                }
            }
            let Some(j) = next else {
                break;
            };
            let gap = self.ks[j] - si - self.khl[j] - self.khl[i];
            if gap <= 0.0 {
                return f64::NEG_INFINITY;
            }
            a = a.min(self.idm_to(p, j < n, vi, v0, gap, self.kv[j], self.params.gap_floor));
            cur = j;
        }
        a
    }

    /// Re-evaluates the accelerations after a frame changed the state at the model tick.
    pub fn end_frame(&mut self, map: &LoopMap) {
        if self.tick.is_some() {
            self.accel_pass(map, false);
        }
    }

    fn target_d(map: &LoopMap, wire: u8, s_m: f64) -> f64 {
        let road = LoopRoad::new(map);
        let n = road.lane_count(s_m);
        let lane = if wire >= RAMP_LANE {
            n
        } else {
            n - 1 - i32::from(wire)
        };
        road.lanes_left_edge_d() + (f64::from(lane) + 0.5) * road.lane_width(s_m)
    }

    /// A `traffic_spawn` entry: its state is at the model tick (the frame's).
    pub fn spawn(&mut self, e: &TrafficSpawnEntry, map: &LoopMap) {
        self.despawn(e.car_id);
        let prof = self.params.profile(e.profile);
        let (len, width) = self.params.body(e.vehicle);
        let s = f64::from(e.s_mm) / MM_PER_M;
        let d = f64::from(e.d_cm) / CM_PER_M;
        let v = f64::from(e.speed_cms) / CM_PER_M;
        let tick = f64::from(self.tick.unwrap_or(0));
        let plan = (e.lc_phase != LaneChangePhase::None && e.lc_duration_ms > 0).then(|| {
            let to = Self::target_d(map, e.lc_target_lane, s);
            let move_t = f64::from(e.lc_move_start_tick);
            let dur =
                (f64::from(e.lc_duration_ms) / MS_PER_S * self.params.net.tick_rate_hz).max(1.0);
            let mut from = d;
            if e.lc_phase == LaneChangePhase::Moving {
                let sm = smooth(((tick - move_t) / dur).clamp(0.0, 1.0));
                from = if sm < 1.0 {
                    (d - to * sm) / (1.0 - sm)
                } else {
                    to
                };
            }
            Plan {
                blink: tick,
                move_t,
                dur,
                from,
                to,
                cancel: f64::INFINITY,
            }
        });
        let v0e = v.max(prof.v0_mid).clamp(prof.v0_lo, prof.v0_hi);
        self.slot_of.insert(e.car_id, self.cars.len());
        self.cars.push(Car {
            id: e.car_id,
            profile: prof,
            hl: len * 0.5,
            width,
            s,
            v,
            a: 0.0,
            a_held: 0.0,
            d_base: plan.map_or(d, |p| p.from),
            plan,
            v0e,
            matchf: 0.0,
            bias: 0.0,
            last_ct: None,
            last_cv: v,
            last_cs: s,
            int_sum: 0.0,
            int_n: 0,
            brake_from: if e.flags.braking { tick } else { f64::INFINITY },
            brake_until: f64::NEG_INFINITY,
        });
    }

    pub fn despawn(&mut self, car_id: u16) {
        let Some(i) = self.slot_of.remove(&car_id) else {
            return;
        };
        self.cars.swap_remove(i);
        if let Some(moved) = self.cars.get(i) {
            self.slot_of.insert(moved.id, i);
        }
    }

    /// A `traffic_intent` entry, received when the bot's room clock read `now` (ticks).
    pub fn intent(&mut self, e: &TrafficIntentEntry, now: f64, map: &LoopMap) {
        let Some(&i) = self.slot_of.get(&e.car_id) else {
            return;
        };
        let rate = self.params.net.tick_rate_hz;
        let start = f64::from(e.start_tick);
        let move_t = f64::from(e.move_start_tick);
        let dur_t = f64::from(e.duration_ms) / MS_PER_S * rate;
        let min_blink = self.params.net.late_min_blinker_s * rate;
        let c = &mut self.cars[i];
        match e.kind {
            IntentKind::LaneChange => {
                self.stats.intents += 1;
                if let Some(p) = c.plan {
                    // A new plan while one runs: the old one is done.
                    c.d_base = p.to;
                }
                let to = Self::target_d(map, e.target_lane, c.s);
                c.plan = Some(Plan {
                    blink: start.max(now),
                    move_t,
                    dur: dur_t.max(1.0),
                    from: c.d_base,
                    to,
                    cancel: f64::INFINITY,
                });
                if now > move_t - min_blink {
                    self.stats.late_intents += 1;
                }
                if now > move_t {
                    self.stats.very_late_intents += 1;
                }
            }
            IntentKind::Cancel => {
                self.stats.cancels += 1;
                let Some(p) = c.plan.as_mut() else {
                    return;
                };
                if start > now {
                    p.cancel = start;
                } else {
                    if now >= p.move_t {
                        self.stats.late_cancels += 1;
                    }
                    c.plan = None;
                }
            }
            IntentKind::HardBrake => {
                c.brake_from = start;
                c.brake_until = start + dur_t;
            }
            IntentKind::Hazard | IntentKind::Horn => {}
        }
    }

    /// A `traffic_correction` entry at `tick` (the model is there: [`Self::advance_to`]).
    pub fn correct(&mut self, tick: u32, e: &CorrectionEntry, map: &LoopMap) {
        let Some(&i) = self.slot_of.get(&e.car_id) else {
            return;
        };
        let net = self.params.net;
        let me = self.players.first().copied().unwrap_or_default();
        let tf = f64::from(tick);
        let dt = self.tick_dt;
        let c = &mut self.cars[i];
        let s_srv = f64::from(e.s_mm) / MM_PER_M;
        let d_srv = f64::from(e.d_cm) / CM_PER_M;
        let v_srv = f64::from(e.speed_cms) / CM_PER_M;
        let (pd, _) = Self::lat_at(c, tf);
        let e_s = map.signed_delta_m(c.s, s_srv);
        let e_v = v_srv - c.v;
        let e_d = d_srv - pd;
        let err = e_s.hypot(e_d);
        let rel = map.signed_delta_m(me.s_m, s_srv);
        self.stats.all.add(err);
        if rel.abs() <= net.near_m {
            self.stats.near.add(err);
        }
        if err >= net.snap_m && rel >= -net.visible_behind_m && rel <= net.visible_ahead_m {
            self.stats.large_in_view += 1;
        }
        // Dead reckoning from the last correction (the spawn's state before the first).
        let since = c
            .last_ct
            .map_or(0.0, |t| f64::from(tick.wrapping_sub(t)) * dt);
        let dr_s = map.signed_delta_m(map.wrap_m(c.last_cs + c.last_cv * since), s_srv);
        self.stats.dead_reckoning.add(dr_s.hypot(e_d));
        // The desired-speed estimate, or the bias (`_estimate`).
        if let Some(last) = c.last_ct {
            let n_ticks = tick.wrapping_sub(last);
            if n_ticks > 0 && n_ticks < u32::MAX / 2 {
                let dtc = f64::from(n_ticks) * dt;
                let p = c.profile;
                let free = c.int_n > 0 && c.int_sum / f64::from(c.int_n) < net.v0_free_accel_mps2;
                let braking = c.brake_from < tf && c.brake_until > f64::from(last);
                if free && !braking {
                    let a_obs = (v_srv - c.last_cv) / dtc;
                    let v_mean = (v_srv + c.last_cv) * 0.5;
                    let q = 1.0 - (a_obs - c.bias) / p.a;
                    let m = c.matchf;
                    let v_merge = self.params.v_merge;
                    if q > 0.0 && v_mean > 0.0 && m < 1.0 {
                        // The model's v0 is matched toward the zones' merge-lane speed:
                        // invert that too.
                        let v0m = v_mean / q.sqrt().sqrt();
                        let v0 = if m <= 0.0 || v0m >= v_merge {
                            v0m
                        } else {
                            (v0m - v_merge * m) / (1.0 - m)
                        };
                        let v0 = v0.clamp(p.v0_lo, p.v0_hi);
                        c.v0e += (v0 - c.v0e) * net.v0_gain;
                    }
                } else if !braking {
                    c.bias = (c.bias + e_v / dtc * net.bias_gain)
                        .clamp(-net.bias_max_mps2, net.bias_max_mps2);
                }
            }
        }
        c.last_ct = Some(tick);
        c.last_cv = v_srv;
        c.last_cs = s_srv;
        c.int_sum = 0.0;
        c.int_n = 0;
        c.s = s_srv;
        c.v = v_srv;
        let unexplained = e_d.abs() >= net.unsignaled_lateral_m;
        match c.plan {
            Some(_) if unexplained => {
                c.plan = None;
                c.d_base = d_srv;
            }
            Some(_) => {}
            None => {
                if unexplained {
                    self.stats.unsignaled_lateral += 1;
                }
                c.d_base = d_srv;
            }
        }
    }
}

/// The loop's lane-drop harmonisation zones as the server's sim makes them
/// (`TrafficSim::add_road_closures`): (first merge lane, s0, s1), wrapped.
fn drop_zones(pr: &ModelParams, map: &LoopMap) -> Vec<(i32, f64, f64)> {
    let road = RoadSpace::from_loop(map);
    let changes = &road.lane_changes;
    let lanes_back = |s_end: f64, lanes: i32| {
        let mut best = f64::INFINITY;
        let mut out = s_end;
        for f in changes {
            let ahead = road.signed_delta(s_end, f.s_start);
            if ahead >= 0.0 && ahead <= pr.drop_narrow && f.after >= lanes && ahead < best {
                best = ahead;
                out = s_end + ahead + (f.s_end - f.s_start);
            }
        }
        out
    };
    changes
        .iter()
        .filter(|f| f.after < f.before)
        .map(|f| {
            (
                f.after,
                road.wrap(f.s_start - pr.drop_slow),
                road.wrap(lanes_back(f.s_end, f.before) + pr.drop_after),
            )
        })
        .collect()
}

fn smooth(u: f64) -> f64 {
    u * u * (SMOOTH_A - 2.0 * u)
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::TrafficFlags;
    use std::sync::Arc;

    fn map() -> Arc<LoopMap> {
        Arc::new(
            LoopMap::from_json(include_str!("../../../data/maps/loop_v1.json")).expect("loop_v1"),
        )
    }

    fn spawn(id: u16, s_mm: u32, d_cm: i16, speed_cms: u16) -> TrafficSpawnEntry {
        TrafficSpawnEntry {
            car_id: id,
            vehicle: 0,
            color: 0,
            profile: 0,
            lane: 1,
            s_mm,
            d_cm,
            speed_cms,
            lc_phase: LaneChangePhase::None,
            lc_target_lane: 0,
            lc_move_start_tick: 0,
            lc_duration_ms: 0,
            flags: TrafficFlags::default(),
        }
    }

    fn me(s: f64) -> [Participant; 1] {
        [Participant {
            s_m: s,
            d: -50.0,
            v: 0.0,
            v_lat: 0.0,
        }]
    }

    #[test]
    fn a_car_at_its_desired_speed_is_predicted_exactly() {
        let m = map();
        let mut p = TrafficPredictor::new(ModelParams::builtin());
        p.advance_to(100, &m, &me(1_000.0));
        let prof = p.params.profile(0);
        let v = prof.v0_mid;
        p.spawn(&spawn(5, 1_050_000, 500, (v * 100.0).round() as u16), &m);
        p.end_frame(&m);
        // The server's car keeps its speed; corrections every 4 ticks for 10 s.
        let v = f64::from((v * 100.0).round() as u16) / 100.0;
        for k in 1..=50u32 {
            let t = 100 + 4 * k;
            let s = 1_050.0 + v * f64::from(4 * k) * 0.05;
            // The bot drives 50 m behind it (a different lane).
            p.advance_to(t, &m, &me(s - 50.0));
            p.correct(
                t,
                &CorrectionEntry {
                    car_id: 5,
                    s_mm: (s * 1_000.0).round() as u32,
                    d_cm: 500,
                    speed_cms: (v * 100.0).round() as u16,
                },
                &m,
            );
            p.end_frame(&m);
        }
        assert_eq!(p.stats.all.n, 50);
        assert!(p.stats.all.max < 0.02, "{}", p.stats.all.max);
        assert_eq!(p.stats.near.n, 50);
    }

    #[test]
    fn a_new_desired_speed_is_learned() {
        let m = map();
        let mut p = TrafficPredictor::new(ModelParams::builtin());
        p.advance_to(0, &m, &me(0.0));
        p.spawn(&spawn(9, 500_000, 500, 3_000), &m);
        p.end_frame(&m);
        // The server's car slows at 1 m/s² to 25 m/s and holds it (its desired speed is
        // not on the wire); corrected at 1 Hz.
        let (mut s, mut v) = (500.0f64, 30.0f64);
        let mut model_err = Vec::new();
        for k in 1..=15u32 {
            for _ in 0..20 {
                let nv = (v - 0.05).max(25.0);
                s += (v + nv) * 0.5 * 0.05;
                v = nv;
            }
            let t = 20 * k;
            p.advance_to(t, &m, &me(0.0));
            let before = p.stats.all.sum;
            p.correct(
                t,
                &CorrectionEntry {
                    car_id: 9,
                    s_mm: (s * 1_000.0).round() as u32,
                    d_cm: 500,
                    speed_cms: (v * 100.0).round() as u16,
                },
                &m,
            );
            model_err.push(p.stats.all.sum - before);
            p.end_frame(&m);
        }
        // The model's errors fade as its estimate settles (dead reckoning is right once
        // the speed holds, and 0.5 m off every second before).
        let late: f64 = model_err[10..].iter().sum::<f64>() / 5.0;
        assert!(late < 0.1, "{model_err:?}");
        assert!(model_err[0] > 0.3, "{model_err:?}");
    }

    #[test]
    fn a_follower_brakes_for_its_leader_and_late_intents_count() {
        let m = map();
        let mut p = TrafficPredictor::new(ModelParams::builtin());
        p.advance_to(0, &m, &me(0.0));
        // A fast car 30 m behind a stopped one in the same lane.
        p.spawn(&spawn(1, 300_000, 500, 0), &m);
        p.spawn(&spawn(2, 270_000, 500, 3_000), &m);
        p.end_frame(&m);
        p.advance_to(20, &m, &me(0.0));
        let c = &p.cars[p.slot_of[&2]];
        assert!(c.v < 25.0, "brakes: {}", c.v);
        // An intent whose move starts 0.1 s after it arrives is late; one after its move
        // tick very late; one 1 s ahead neither.
        let lc = |start: u32, mv: u32| TrafficIntentEntry {
            car_id: 1,
            kind: IntentKind::LaneChange,
            start_tick: start,
            move_start_tick: mv,
            target_lane: 0,
            duration_ms: 3_000,
        };
        p.intent(&lc(20, 40), 21.0, &m);
        p.intent(&lc(20, 40), 38.0, &m);
        p.intent(&lc(20, 40), 41.0, &m);
        assert_eq!(p.stats.intents, 3);
        assert_eq!(p.stats.late_intents, 2);
        assert_eq!(p.stats.very_late_intents, 1);
    }

    #[test]
    fn the_loops_lane_drops_are_zones_and_slow_a_car_down() {
        let m = map();
        let pr = ModelParams::builtin();
        let zones = drop_zones(&pr, &m);
        assert!(!zones.is_empty(), "loop_v1 has lane drops");
        for &(first, s0, s1) in &zones {
            assert!(first >= 1);
            assert!((0.0..m.length_m()).contains(&s0) && (0.0..m.length_m()).contains(&s1));
            let len = m.signed_delta_m(s0, s1);
            assert!(len > 0.0 && len < 5_000.0, "{s0} → {s1}");
        }
        // A fast car in the merge lane 200 m before a zone brakes into it.
        let (first, s0, _) = zones[0];
        let mut p = TrafficPredictor::new(ModelParams::builtin());
        let at = m.wrap_m(s0 - 200.0);
        p.advance_to(0, &m, &me(m.wrap_m(at - 50.0)));
        let road = LoopRoad::new(&m);
        let d = road.lanes_left_edge_d() + (f64::from(first) + 0.5) * road.lane_width(at);
        p.spawn(
            &spawn(3, (at * 1_000.0) as u32, (d * 100.0) as i16, 3_500),
            &m,
        );
        p.end_frame(&m);
        let c = &p.cars[0];
        assert!(c.a < -0.5, "brakes for the zone: {}", c.a);
    }

    #[test]
    fn histograms_quantiles_and_merge() {
        let mut h = SizeHist::default();
        for k in 0..100 {
            h.add(f64::from(k) * 0.01);
        }
        assert!(
            (h.quantile(0.5) - 0.495).abs() < 0.006,
            "{}",
            h.quantile(0.5)
        );
        assert!((h.quantile(0.99) - 0.985).abs() < 0.006);
        h.add(3.0);
        assert_eq!(h.quantile(1.0), 3.0);
        assert_eq!(h.above(0.5), 50);
        let mut g = SizeHist::default();
        g.merge(&h);
        assert_eq!(g.n, 101);
        assert_eq!(g.max, 3.0);
    }
}
