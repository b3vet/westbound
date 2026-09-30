//! Claim verification (N6.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Scoring in
//! multiplayer → Server-authoritative scoring, 2. Verification: "a pass needs the car to
//! go from ahead to behind within ±300 ms of the claimed tick; a close pass needs
//! server-measured clearance under 1.0 m + 0.35 m tolerance; a thread needs both sides to
//! pass; a cut needs a traffic car within the cut window". Wire: PROTOCOL.md §4
//! `score_claim`.
//!
//! **What a claim means** (the contract for N6.2's client, docs/SERVER.md → Scoring):
//!
//! | `kind` | `tick` | `cars` | `side` |
//! | --- | --- | --- | --- |
//! | `pass`, `close_pass` | the room tick the client paid it: the car fully behind | the car, its minimum clearance (mm) | the car's side at the crossing |
//! | `thread` | the tick of the second (completing) pass | first car, second car, each with its clearance | the first car's side |
//! | `cut` | the tick the player's centre crossed into the new lane | the nearest eligible car (clearance 0) | `none` |
//!
//! **Checks**, against the server's own observations ([`Tracker`]) and the traffic
//! history (every car must also be one this client was streamed):
//!
//! - pass: the server saw the car pass (ahead → overlap → fully behind) with its
//!   completion within `claim_timing_ms` of the claim's tick, not already claimed, the
//!   centres' lateral offset inside the pass window (+ tolerance), on the claimed side;
//! - close pass: also the server's minimum clearance under the close-pass threshold +
//!   tolerance, and at most the claimed clearance + tolerance ("inflated" claims fail);
//! - thread: both cars passed on opposite sides, crossing within the thread window (+
//!   timing), each under the thread clearance + tolerance and its claimed clearance +
//!   tolerance, the second completing within the timing window;
//! - cut: the player's states show a lane change within the timing window, at the cut
//!   speed (− tolerance), the named car in the lane left or entered within the cut window
//!   (+ tolerance) of the player, and not named in an accepted cut within the cooldown.
//!
//! A claim with no match yet waits until the states that could still make it true have
//! been seen (the claim's tick + the timing window) or `claim_max_wait_ms` passed; a match
//! accepts at once.

use protocol::{ClaimKind, ScoreClaim, Side};
use sim::map::LoopMap;
use sim::scoring::{LoopRoad, ScoringRoad};

use super::ring::Ring;
use super::tracker::{ObservedPass, StateRec, Tracker};
use crate::rooms::car_history::CarHistory;
use crate::rooms::plausibility::tick_diff;

const MM_PER_M: f64 = 1_000.0;
/// Side checks only when the centres were this far apart laterally (m): a car straight
/// ahead has no side.
const SIDE_MIN_OFFSET_M: f64 = 1.0;

/// Why a claim was rejected (metrics label; the client gets `score_event.claim_rejected`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reject {
    /// No run in progress, or the claim is from before it.
    NoRun,
    /// The player's claim queue is full.
    QueueFull,
    /// A car this client was never streamed (or no such car).
    UnknownCar,
    /// The server saw no pass of that car.
    NoPass,
    /// It saw the pass, outside the timing window.
    Timing,
    /// The pass was already claimed.
    Duplicate,
    /// Outside the pass window laterally.
    Lateral,
    /// The server's clearance is too large for the claim.
    Clearance,
    /// The car passed on the other side.
    Side,
    /// The two cars do not make a thread.
    Thread,
    /// No lane change, too slow, or no car in the cut window.
    Cut,
    /// The car was named in a cut within the cooldown.
    Cooldown,
}

impl Reject {
    pub const ALL: [Reject; 12] = [
        Reject::NoRun,
        Reject::QueueFull,
        Reject::UnknownCar,
        Reject::NoPass,
        Reject::Timing,
        Reject::Duplicate,
        Reject::Lateral,
        Reject::Clearance,
        Reject::Side,
        Reject::Thread,
        Reject::Cut,
        Reject::Cooldown,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Reject::NoRun => "no_run",
            Reject::QueueFull => "queue_full",
            Reject::UnknownCar => "unknown_car",
            Reject::NoPass => "no_pass",
            Reject::Timing => "timing",
            Reject::Duplicate => "duplicate",
            Reject::Lateral => "lateral",
            Reject::Clearance => "clearance",
            Reject::Side => "side",
            Reject::Thread => "thread",
            Reject::Cut => "cut",
            Reject::Cooldown => "cooldown",
        }
    }
}

/// A claim waiting for its decision (copied out of the message: no heap).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Claim {
    pub id: u16,
    pub tick: u32,
    pub kind: ClaimKind,
    pub side: Side,
    /// (car_id, clearance_mm); `n` of them are set.
    pub cars: [(u16, u16); 2],
    pub n: usize,
    /// Room tick it arrived.
    pub received: u32,
    /// Arrival order (the official score pays claims of one tick in this order).
    pub seq: u32,
}

impl Claim {
    pub fn new(m: &ScoreClaim, received: u32, seq: u32) -> Self {
        let mut cars = [(0, 0); 2];
        for (slot, c) in cars.iter_mut().zip(&m.cars) {
            *slot = (c.car_id, c.clearance_mm);
        }
        Self {
            id: m.claim_id,
            tick: m.tick,
            kind: m.kind,
            side: m.side,
            cars,
            n: m.cars.len().min(2),
            received,
            seq,
        }
    }
}

/// An accepted claim, to be paid by the official score at its tick.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Accepted {
    pub tick: u32,
    pub seq: u32,
    pub claim_id: u16,
    pub kind: ClaimKind,
    /// The car (a thread's second car).
    pub car: u16,
    /// A thread's first car; 0 otherwise.
    pub car_b: u16,
    /// The server saw the car on the right (+d) at the crossing.
    pub right: bool,
    /// When the centres crossed (the server's): trains compare these.
    pub cross_tick: u32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Decision {
    Wait,
    Accept(Accepted),
    Reject(Reject),
}

/// The verification numbers, converted once (ticks, metres, m/s).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VerifyRules {
    pub timing_ticks: u32,
    pub clearance_tol_m: f64,
    pub lateral_window_m: f64,
    pub close_pass_m: f64,
    pub thread_m: f64,
    pub thread_window_ticks: u32,
    pub cut_window_m: f64,
    pub cut_gap_tol_m: f64,
    /// The cut speed minus its tolerance (m/s).
    pub cut_min_v: f64,
    pub cut_cooldown_ticks: u32,
    pub wait_ticks: u32,
    pub inset: f64,
    pub p_hl: f64,
}

/// What a decision reads.
pub struct Evidence<'a> {
    pub now: u32,
    pub states: &'a Ring<StateRec>,
    pub history: Option<&'a CarHistory>,
    pub map: &'a LoopMap,
    /// The car was streamed to this client.
    pub knows: &'a dyn Fn(u16) -> bool,
}

fn within(a: u32, b: u32, ticks: u32) -> bool {
    tick_diff(a, b).unsigned_abs() <= u64::from(ticks)
}

fn right_of(p: &ObservedPass) -> bool {
    p.cross_dd >= 0.0
}

fn side_ok(claimed: Side, p: &ObservedPass) -> bool {
    if p.cross_dd.abs() < SIDE_MIN_OFFSET_M {
        return true;
    }
    match claimed {
        Side::None => true,
        Side::Right => right_of(p),
        Side::Left => !right_of(p),
    }
}

/// Decides one claim (or leaves it waiting). Marks the passes it uses and records cuts.
pub fn decide(
    c: &Claim,
    ev: &Evidence<'_>,
    tracker: &mut Tracker,
    cuts: &mut Ring<(u16, u32)>,
    r: &VerifyRules,
) -> Decision {
    for &(car, _) in &c.cars[..c.n] {
        if car == 0 || !(ev.knows)(car) {
            return Decision::Reject(Reject::UnknownCar);
        }
    }
    let timed_out = tick_diff(c.received, ev.now) >= i64::from(r.wait_ticks);
    let seen_to =
        |t: Option<u32>| t.is_some_and(|p| tick_diff(c.tick.wrapping_add(r.timing_ticks), p) >= 0);
    let ready = timed_out || seen_to(tracker.processed);
    match c.kind {
        ClaimKind::Pass | ClaimKind::ClosePass => pass(c, tracker, ready, r),
        ClaimKind::Thread => thread(c, tracker, ready, r),
        ClaimKind::Cut => {
            let last = ev.states.iter().next_back().map(|s| s.tick);
            cut(c, ev, cuts, timed_out || seen_to(last), r)
        }
    }
}

fn pass(c: &Claim, tracker: &mut Tracker, ready: bool, r: &VerifyRules) -> Decision {
    let (car, clr_mm) = c.cars[0];
    let mut best: Option<(usize, u64)> = None;
    for (k, p) in tracker.passes.iter().enumerate() {
        if p.car_id != car || p.claimed || !within(p.done_tick, c.tick, r.timing_ticks) {
            continue;
        }
        let off = tick_diff(p.done_tick, c.tick).unsigned_abs();
        if best.is_none_or(|(_, o)| off < o) {
            best = Some((k, off));
        }
    }
    let Some((k, _)) = best else {
        if !ready {
            return Decision::Wait;
        }
        let seen = tracker.passes.iter().filter(|p| p.car_id == car);
        let mut why = Reject::NoPass;
        for p in seen {
            why = if p.claimed && within(p.done_tick, c.tick, r.timing_ticks) {
                Reject::Duplicate
            } else if why == Reject::NoPass {
                Reject::Timing
            } else {
                why
            };
        }
        return Decision::Reject(why);
    };
    let Some(p) = tracker.passes.get_mut(k) else {
        return Decision::Reject(Reject::NoPass);
    };
    if p.cross_dd.abs() > r.lateral_window_m + r.clearance_tol_m {
        return Decision::Reject(Reject::Lateral);
    }
    if c.kind == ClaimKind::ClosePass {
        let claimed = f64::from(clr_mm) / MM_PER_M;
        if p.min_clear >= r.close_pass_m + r.clearance_tol_m
            || p.min_clear > claimed + r.clearance_tol_m
        {
            return Decision::Reject(Reject::Clearance);
        }
    }
    if !side_ok(c.side, p) {
        return Decision::Reject(Reject::Side);
    }
    p.claimed = true;
    Decision::Accept(Accepted {
        tick: c.tick,
        seq: c.seq,
        claim_id: c.id,
        kind: c.kind,
        car,
        car_b: 0,
        right: right_of(p),
        cross_tick: p.cross_tick,
    })
}

fn thread(c: &Claim, tracker: &mut Tracker, ready: bool, r: &VerifyRules) -> Decision {
    if c.n < 2 {
        return Decision::Reject(Reject::Thread);
    }
    let (first, first_mm) = c.cars[0];
    let (second, second_mm) = c.cars[1];
    let passes = &tracker.passes;
    let k1 = passes.iter().position(|p| {
        p.car_id == second && !p.threaded && within(p.done_tick, c.tick, r.timing_ticks)
    });
    let k0 = k1.and_then(|k1| {
        let p1 = passes.get(k1)?;
        passes.iter().position(|p| {
            p.car_id == first
                && !p.threaded
                && within(
                    p.cross_tick,
                    p1.cross_tick,
                    r.thread_window_ticks + r.timing_ticks,
                )
        })
    });
    let (Some(k0), Some(k1)) = (k0, k1) else {
        return if ready {
            Decision::Reject(Reject::Thread)
        } else {
            Decision::Wait
        };
    };
    let (Some(&p0), Some(&p1)) = (passes.get(k0), passes.get(k1)) else {
        return Decision::Reject(Reject::Thread);
    };
    if right_of(&p0) == right_of(&p1) {
        return Decision::Reject(Reject::Side);
    }
    for (p, mm) in [(&p0, first_mm), (&p1, second_mm)] {
        if p.cross_dd.abs() > r.lateral_window_m + r.clearance_tol_m {
            return Decision::Reject(Reject::Lateral);
        }
        let claimed = f64::from(mm) / MM_PER_M;
        if p.min_clear >= r.thread_m + r.clearance_tol_m
            || p.min_clear > claimed + r.clearance_tol_m
        {
            return Decision::Reject(Reject::Clearance);
        }
    }
    for k in [k0, k1] {
        if let Some(p) = tracker.passes.get_mut(k) {
            p.threaded = true;
        }
    }
    Decision::Accept(Accepted {
        tick: c.tick,
        seq: c.seq,
        claim_id: c.id,
        kind: ClaimKind::Thread,
        car: second,
        car_b: first,
        right: right_of(&p1),
        cross_tick: p1.cross_tick,
    })
}

fn cut(
    c: &Claim,
    ev: &Evidence<'_>,
    cuts: &mut Ring<(u16, u32)>,
    ready: bool,
    r: &VerifyRules,
) -> Decision {
    let road = LoopRoad::new(ev.map);
    let lane_of = |s: &StateRec| road.lane_index_at(s.d, f64::from(s.s_mm) / MM_PER_M);
    // The lane change nearest the claimed tick: consecutive states in two driving lanes.
    let mut found: Option<(StateRec, i32, i32)> = None;
    let mut prev_lane: Option<i32> = None;
    for s in ev.states.iter() {
        let lane = lane_of(s);
        if let Some(la) = prev_lane {
            let near = within(s.tick, c.tick, r.timing_ticks + 1);
            if near && !s.reset && la >= 0 && lane >= 0 && la != lane {
                let better = found.is_none_or(|(b, _, _)| {
                    tick_diff(s.tick, c.tick).abs() < tick_diff(b.tick, c.tick).abs()
                });
                if better {
                    found = Some((*s, la, lane));
                }
            }
        }
        prev_lane = Some(lane);
    }
    let Some((b, from, to)) = found else {
        return if ready {
            Decision::Reject(Reject::Cut)
        } else {
            Decision::Wait
        };
    };
    if b.v < r.cut_min_v {
        return Decision::Reject(Reject::Cut);
    }
    let car = c.cars[0].0;
    let Some(sample) = ev.history.and_then(|h| h.car_at(b.tick, car)) else {
        return Decision::Reject(Reject::Cut);
    };
    let lane = i32::from(sample.lane);
    if lane != from && lane != to {
        return Decision::Reject(Reject::Cut);
    }
    let ds = ev.map.signed_delta_mm(b.s_mm, sample.s_mm) as f64 / MM_PER_M;
    let gap = ds.abs() - (f64::from(sample.length) * 0.5 - r.inset + r.p_hl);
    if gap > r.cut_window_m + r.cut_gap_tol_m {
        return Decision::Reject(Reject::Cut);
    }
    let cooldown = r.cut_cooldown_ticks.saturating_sub(r.timing_ticks);
    if cuts.iter().any(|&(id, t)| {
        id == car && tick_diff(t, b.tick) >= 0 && tick_diff(t, b.tick) < i64::from(cooldown)
    }) {
        return Decision::Reject(Reject::Cooldown);
    }
    cuts.push((car, b.tick));
    Decision::Accept(Accepted {
        tick: c.tick,
        seq: c.seq,
        claim_id: c.id,
        kind: ClaimKind::Cut,
        car,
        car_b: 0,
        right: ds >= 0.0,
        cross_tick: b.tick,
    })
}
