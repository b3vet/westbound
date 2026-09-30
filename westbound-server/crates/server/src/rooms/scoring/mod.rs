//! Multiplayer scoring in a room (N6.1, server side). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → Scoring in multiplayer (crew mechanics: proximity, trains, the session crew total;
//! server-authoritative scoring: claims, verification, the official score, score sync,
//! hits); Time of day in multiplayer (night ×2); Leaderboards ("Multiplayer runs go on the
//! boards automatically"). Runbook and the client contract: docs/SERVER.md → "Scoring
//! (N6.1)". Wire: PROTOCOL.md §4 (`score_claim`, `hit_report`, `score_sync`,
//! `score_event`, `run_result`, `room_event.crew`).
//!
//! | Module | What |
//! | --- | --- |
//! | this file | [`RoomScoring`]: the room's players, their state rings, claims, hits, the official timelines, trains, crew totals, `ScoreSync` / `ScoreEvent` |
//! | `tracker` | The server's own pass and contact observations per player |
//! | `claims` | Claim verification |
//! | `official` | One run's official score (`sim::scoring` on accepted claims) |
//! | `ring` | Fixed rings |
//!
//! **Flow per room tick** ([`RoomScoring::tick`], after the traffic stepped and recorded
//! its history): each player's new states are paired with the traffic at their ticks
//! (tracker); pending claims are decided; reported traffic hits are confirmed against
//! what the server saw (the car then reacts: `RoomTraffic::hit_car`); the official
//! timelines advance to `now − official_lag` (claims paid at their ticks, trains, sectors,
//! crew factor, night); `ScoreSync` goes out at banking moments and once a second;
//! server-detected contacts nobody reported mark the run unverified; crew session totals
//! go out as `room_event.crew`.
//!
//! Nothing allocates per tick: rings and queues are sized when a player joins; the outbox
//! keeps its capacity between ticks.

pub mod claims;
pub mod official;
pub mod ring;
#[cfg(test)]
mod tests;
pub mod tracker;

use std::sync::{Arc, OnceLock};

use protocol::{
    ClaimKind, HitReport, HitTarget, PlayerState, RoomCrew, RunState, ScoreClaim, ScoreEvent,
    ScoreEventKind, ScoreFlags, ScoreSync, ServerMsg,
};
use sim::map::LoopMap;
use sim::scoring::ScoringParams;

use super::car_history::CarHistory;
use super::metrics::RoomMetrics;
use super::plausibility::tick_diff;
use super::traffic::RoomTraffic;
use crate::config::ScoringConfig;
use claims::{Accepted, Claim, Decision, Evidence, Reject, VerifyRules};
use official::{Counts, Official, StepCtx};
use ring::Ring;
use tracker::{StateRec, TrackRules, Tracker};

const MS_PER_S: f64 = 1_000.0;
const MM_PER_M: f64 = 1_000.0;
const CM_PER_M: f64 = 100.0;
const HEADING_PER_RAD: f64 = 10_000.0;
const KMH_PER_MPS: f64 = 3.6;
const PCT: f64 = 100.0;
const MILLI: f64 = 1_000.0;
/// Accepted states kept per player (3.2 s at 20 Hz: the official lag, the claim window
/// and the history all fit).
pub const STATE_RING: usize = 64;
const CUT_RING: usize = 16;
const HIT_RING: usize = 16;
/// Trains remembered room-wide (every crew's recent passes).
const TRAIN_LOG: usize = 128;
/// A crewmate's state this close in time counts for proximity (ticks).
const CREW_STATE_TICKS: u32 = 2;
/// Score events one player's step may announce.
const STEP_OUT: usize = 16;

/// The compiled-in scoring export, parsed once.
pub fn builtin_params() -> Arc<ScoringParams> {
    static P: OnceLock<Arc<ScoringParams>> = OnceLock::new();
    P.get_or_init(|| {
        Arc::new(ScoringParams::builtin().expect("the compiled-in scoring export parses"))
    })
    .clone()
}

/// `[scoring]` converted once to ticks and SI, with the exported game rules.
#[derive(Debug, Clone, PartialEq)]
pub struct ScoringRules {
    pub params: Arc<ScoringParams>,
    pub tick_dt: f64,
    pub verify: VerifyRules,
    pub track: TrackRules,
    pub claim_queue: usize,
    pub lag_ticks: u32,
    pub sync_ticks: u32,
    pub crew_range_mm: i64,
    pub crew_bonus: f64,
    pub crew_cap: f64,
    pub train_ticks: u32,
    pub train_points: i64,
    pub train_gain: f64,
    pub hit_match_ticks: u32,
    pub ghost_ticks: u32,
    pub verify_min_acceptance: f64,
    pub verify_min_claims: u32,
    pub crew_total_ticks: u32,
    /// Traffic history depth (ticks).
    pub history_ticks: usize,
}

impl ScoringRules {
    pub fn from_config(c: &ScoringConfig, tick_rate_hz: u32, stale_state_ms: u64) -> Self {
        let params = builtin_params();
        let rate = f64::from(tick_rate_hz.max(1));
        let ticks = |ms: u64| ((ms as f64) * rate / MS_PER_S).ceil() as u32;
        let s_ticks = |s: f64| (s * rate).ceil() as u32;
        let sc = &params.scoring;
        let inset = params.lives.collision_inset_m;
        let p_hl = c.player_length_m * 0.5 - inset;
        let p_hw = c.player_width_m * 0.5 - inset;
        let timing = ticks(c.claim_timing_ms);
        Self {
            tick_dt: 1.0 / rate,
            verify: VerifyRules {
                timing_ticks: timing,
                clearance_tol_m: c.claim_clearance_tolerance_m,
                lateral_window_m: sc.pass_lateral_window_m,
                close_pass_m: sc.close_pass_clearance_m,
                thread_m: sc.thread_clearance_m,
                thread_window_ticks: s_ticks(sc.thread_window_s),
                cut_window_m: sc.cut_traffic_window_m,
                cut_gap_tol_m: c.cut_gap_tolerance_m,
                cut_min_v: (sc.cut_min_speed_kmh - c.cut_speed_tolerance_kmh) / KMH_PER_MPS,
                cut_cooldown_ticks: s_ticks(sc.cut_per_car_cooldown_s),
                wait_ticks: ticks(c.claim_max_wait_ms),
                inset,
                p_hl,
            },
            track: TrackRules {
                p_hl,
                p_hw,
                inset,
                ahead_m: c.track_ahead_m,
                overlap_m: c.hit_overlap_m,
                overlap_ticks: c.hit_overlap_ticks.max(1),
                confirm_m: c.hit_confirm_clearance_m,
            },
            claim_queue: c.claim_queue.max(1),
            lag_ticks: ticks(c.official_lag_ms),
            sync_ticks: ticks(c.sync_interval_ms).max(1),
            crew_range_mm: (c.crew_range_m * MM_PER_M).round() as i64,
            crew_bonus: c.crew_bonus_per_mate,
            crew_cap: c.crew_factor_cap,
            train_ticks: ticks(c.train_window_ms),
            train_points: c.train_points,
            train_gain: c.train_multiplier_gain,
            hit_match_ticks: ticks(c.hit_match_ms),
            ghost_ticks: s_ticks(params.lives.ghost_period_s),
            verify_min_acceptance: c.verify_min_acceptance_pct / PCT,
            verify_min_claims: c.verify_min_claims,
            crew_total_ticks: ticks(c.crew_total_interval_ms).max(1),
            history_ticks: (ticks(stale_state_ms) as usize + 2).max(STATE_RING / 2),
            params,
        }
    }

    /// The crew factor with `n` crewmates in range (spec: +0.25× each, capped at ×2.0).
    pub fn crew_factor(&self, n: u32) -> f64 {
        (1.0 + self.crew_bonus * f64::from(n)).min(self.crew_cap)
    }
}

/// A run's final numbers (`run_result` and the boards).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RunScore {
    pub score: u32,
    pub counts: Counts,
    pub max_multiplier_milli: u32,
    pub claims_accepted: u32,
    pub claims_rejected: u32,
    /// Server-detected contacts the client never reported.
    pub unreported_hits: u32,
    /// No unreported hit and the claim acceptance above the threshold (MP-D9).
    pub verified: bool,
}

#[derive(Debug, Clone, Copy, Default)]
struct PendingHit {
    tick: u32,
    car_id: u16,
    received: u32,
}

#[derive(Debug, Clone, Copy, Default)]
struct TrainEntry {
    player_id: u16,
    crew: u8,
    car: u16,
    car_b: u16,
    right: bool,
    cross_tick: u32,
    link: u8,
}

struct PlayerScore {
    player_id: u16,
    crew: u8,
    run_seq: u16,
    states: Ring<StateRec>,
    /// States ever pushed this run, and how many the tracker and the official score took.
    pushed: u64,
    tracked: u64,
    scored: u64,
    tracker: Tracker,
    claims: Vec<Claim>,
    claim_seq: u32,
    cuts: Ring<(u16, u32)>,
    official: Official,
    pending_hits: Ring<PendingHit>,
    /// Ticks of every hit the client reported this run.
    reported: Ring<u32>,
    /// A plausibility offence (the room's).
    offence: bool,
    accepted: u32,
    rejected: u32,
    unreported: u32,
    last_sync: Option<u32>,
    crew_n: u8,
    out: Vec<ScoreEvent>,
}

impl PlayerScore {
    fn new(player_id: u16, crew: u8, rules: &ScoringRules) -> Self {
        Self {
            player_id,
            crew,
            run_seq: 0,
            states: Ring::new(STATE_RING),
            pushed: 0,
            tracked: 0,
            scored: 0,
            tracker: Tracker::new(rules.track),
            claims: Vec::with_capacity(rules.claim_queue),
            claim_seq: 0,
            cuts: Ring::new(CUT_RING),
            official: Official::new(&rules.params),
            pending_hits: Ring::new(HIT_RING),
            reported: Ring::new(HIT_RING),
            offence: false,
            accepted: 0,
            rejected: 0,
            unreported: 0,
            last_sync: None,
            crew_n: 0,
            out: Vec::with_capacity(STEP_OUT),
        }
    }

    /// The state with absolute index `n`, if still in the ring.
    fn state(&self, n: u64) -> Option<StateRec> {
        let first = self.pushed - self.states.len() as u64;
        if n < first {
            return None;
        }
        self.states.get((n - first) as usize).copied()
    }

    /// The oldest index still in the ring.
    fn first(&self) -> u64 {
        self.pushed - self.states.len() as u64
    }

    fn acceptance_ok(&self, rules: &ScoringRules) -> bool {
        let decided = self.accepted + self.rejected;
        decided < rules.verify_min_claims
            || f64::from(self.accepted) >= rules.verify_min_acceptance * f64::from(decided)
    }

    fn verified(&self, rules: &ScoringRules) -> bool {
        self.unreported == 0 && self.acceptance_ok(rules)
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct CrewTotal {
    slot: u8,
    /// Banked scores of the crew's finished runs this session.
    ended: i64,
    sent: Option<u32>,
    sent_tick: u32,
}

/// Scoring for one room.
pub struct RoomScoring {
    rules: ScoringRules,
    /// The loop's length (mm): wrapped distances between players.
    loop_len_mm: u32,
    players: Vec<PlayerScore>,
    trains: Ring<TrainEntry>,
    crews: Vec<CrewTotal>,
    /// Messages for players: (player id, message). The room moves them into its frames.
    pub outbox: Vec<(u16, ServerMsg)>,
    /// Crews whose session total changed (`room_event.crew` to everyone).
    pub crew_events: Vec<RoomCrew>,
    hit_cars: Vec<(u16, u16)>,
    metrics: Arc<RoomMetrics>,
}

impl RoomScoring {
    pub fn new(rules: ScoringRules, map: &LoopMap, metrics: Arc<RoomMetrics>) -> Self {
        let cap = usize::from(protocol::messages::MAX_ROOM_PLAYERS);
        Self {
            rules,
            loop_len_mm: map.length_mm().max(1),
            players: Vec::with_capacity(cap),
            trains: Ring::new(TRAIN_LOG),
            crews: Vec::with_capacity(usize::from(protocol::messages::MAX_CREWS)),
            outbox: Vec::with_capacity(cap * 4),
            crew_events: Vec::with_capacity(usize::from(protocol::messages::MAX_CREWS)),
            hit_cars: Vec::with_capacity(cap),
            metrics,
        }
    }

    pub fn rules(&self) -> &ScoringRules {
        &self.rules
    }

    fn index(&self, player_id: u16) -> Option<usize> {
        self.players.iter().position(|p| p.player_id == player_id)
    }

    /// A seat: its scoring crew.
    pub fn add_player(&mut self, player_id: u16, crew: u8) {
        if self.index(player_id).is_none() {
            self.players
                .push(PlayerScore::new(player_id, crew, &self.rules));
        }
        if !self.crews.iter().any(|c| c.slot == crew) {
            // The room announces a new crew with a zero total itself.
            self.crews.push(CrewTotal {
                slot: crew,
                ended: 0,
                sent: Some(0),
                sent_tick: 0,
            });
        }
    }

    /// The seat went (its run already ended).
    pub fn remove_player(&mut self, player_id: u16) {
        if let Some(i) = self.index(player_id) {
            self.players.remove(i);
        }
    }

    /// The crew's session total: the banked scores of its finished runs this session plus
    /// its members' banked scores so far.
    pub fn crew_total(&self, slot: u8) -> u32 {
        let ended = self
            .crews
            .iter()
            .find(|c| c.slot == slot)
            .map_or(0, |c| c.ended);
        let live: i64 = self
            .players
            .iter()
            .filter(|p| p.crew == slot && p.official.active)
            .map(|p| p.official.rules.banked())
            .sum();
        u32::try_from((ended + live).max(0)).unwrap_or(u32::MAX)
    }

    /// A new run placed at `s_mm` (room tick `tick`).
    pub fn start_run(&mut self, player_id: u16, run_seq: u16, tick: u32, s_mm: u32) {
        let Some(i) = self.index(player_id) else {
            return;
        };
        let p = &mut self.players[i];
        p.run_seq = run_seq;
        p.states.clear();
        p.pushed = 0;
        p.tracked = 0;
        p.scored = 0;
        p.tracker.reset();
        p.claims.clear();
        p.cuts.clear();
        p.pending_hits.clear();
        p.reported.clear();
        p.offence = false;
        p.accepted = 0;
        p.rejected = 0;
        p.unreported = 0;
        p.last_sync = None;
        p.crew_n = 0;
        p.official.start(tick, s_mm);
    }

    /// An accepted state (clamped). `reset`: a placement or a teleport.
    pub fn on_state(&mut self, player_id: u16, st: &PlayerState, reset: bool) {
        let Some(i) = self.index(player_id) else {
            return;
        };
        let p = &mut self.players[i];
        if !p.official.active || tick_diff(p.official.start_tick, st.tick) < 0 {
            return;
        }
        p.states.push(StateRec {
            tick: st.tick,
            s_mm: st.s_mm,
            d: f64::from(st.d_cm) / CM_PER_M,
            v: f64::from(st.speed_cms) / CM_PER_M,
            yaw: f64::from(st.heading_e4) / HEADING_PER_RAD,
            boost: st.flags.boost,
            protected: st.run_state == RunState::Protected || st.flags.ghost,
            reset,
        });
        p.pushed += 1;
    }

    /// A plausibility offence: the run is unverified (`ScoreSync.flags.unverified`).
    pub fn mark_unverified(&mut self, player_id: u16) {
        if let Some(i) = self.index(player_id) {
            self.players[i].offence = true;
        }
    }

    /// A `score_claim` (decided in the next ticks).
    pub fn on_claim(&mut self, player_id: u16, m: &ScoreClaim, now: u32) {
        let Some(i) = self.index(player_id) else {
            return;
        };
        let p = &mut self.players[i];
        p.claim_seq = p.claim_seq.wrapping_add(1);
        let claim = Claim::new(m, now, p.claim_seq);
        let why = if !p.official.active || tick_diff(p.official.start_tick, m.tick) < 0 {
            Some(Reject::NoRun)
        } else if p.claims.len() >= p.claims.capacity() {
            Some(Reject::QueueFull)
        } else {
            None
        };
        match why {
            Some(r) => reject(&mut self.outbox, &self.metrics, p, &claim, r),
            None => p.claims.push(claim),
        }
    }

    /// A `hit_report`: the client's lives are authoritative; a traffic hit is confirmed
    /// against the server's view before the car reacts.
    pub fn on_hit(&mut self, player_id: u16, hit: &HitReport, now: u32) {
        let Some(i) = self.index(player_id) else {
            return;
        };
        let p = &mut self.players[i];
        if !p.official.active || tick_diff(p.official.start_tick, hit.tick) < 0 {
            return;
        }
        p.official.push_hit(hit.tick, hit.lives_left);
        p.reported.push(hit.tick);
        if hit.target == HitTarget::Traffic && hit.car_id != 0 {
            p.pending_hits.push(PendingHit {
                tick: hit.tick,
                car_id: hit.car_id,
                received: now,
            });
        }
    }

    /// "Rejoin crew": the unbanked chain is forfeited at `tick`.
    pub fn rejoin(&mut self, player_id: u16, tick: u32) {
        if let Some(i) = self.index(player_id) {
            if self.players[i].official.active {
                self.players[i].official.push_rejoin(tick);
            }
        }
    }

    /// One room tick (see the module docs).
    pub fn tick(
        &mut self,
        now: u32,
        traffic: &mut dyn RoomTraffic,
        map: &LoopMap,
        night: &dyn Fn(u32) -> bool,
    ) {
        self.observe(now, &*traffic, map, false);
        for (player, car) in self.hit_cars.drain(..) {
            traffic.hit_car(player, car);
        }
        let horizon = now.wrapping_sub(self.rules.lag_ticks);
        for i in 0..self.players.len() {
            self.score_until(i, Some(horizon), map, night);
            self.resolve_contacts(i, Some(horizon));
        }
        self.crew_totals(now, false);
    }

    /// The trackers, the claims and the hit confirmations. `flush`: decide everything
    /// with what is there (the run ends).
    fn observe(&mut self, now: u32, traffic: &dyn RoomTraffic, map: &LoopMap, flush: bool) {
        let hist = traffic.car_history();
        let rules = &self.rules;
        for p in &mut self.players {
            track(p, hist, map);
            let pid = p.player_id;
            let knows = |car: u16| traffic.client_has(pid, car);
            let decide_now = if flush {
                now.wrapping_add(rules.verify.wait_ticks)
            } else {
                now
            };
            let mut k = 0;
            while k < p.claims.len() {
                let c = p.claims[k];
                let ev = Evidence {
                    now: decide_now,
                    states: &p.states,
                    history: hist,
                    map,
                    knows: &knows,
                };
                match claims::decide(&c, &ev, &mut p.tracker, &mut p.cuts, &rules.verify) {
                    Decision::Wait => k += 1,
                    Decision::Accept(a) => {
                        p.claims.remove(k);
                        accept(&self.metrics, p, a);
                    }
                    Decision::Reject(r) => {
                        p.claims.remove(k);
                        reject(&mut self.outbox, &self.metrics, p, &c, r);
                    }
                }
            }
            let mut k = 0;
            while let Some(h) = p.pending_hits.get(k).copied() {
                let seen = p.tracker.processed.is_some_and(|t| {
                    tick_diff(h.tick.wrapping_add(rules.verify.timing_ticks), t) >= 0
                });
                let waited = tick_diff(h.received, now) >= i64::from(rules.verify.wait_ticks);
                if !(seen || waited || flush) {
                    k += 1;
                    continue;
                }
                let near = p.tracker.near.iter().any(|n| {
                    n.car_id == h.car_id
                        && tick_diff(n.tick, h.tick).unsigned_abs()
                            <= u64::from(rules.verify.timing_ticks)
                });
                if near {
                    RoomMetrics::inc(&self.metrics.hits_confirmed);
                    if self.hit_cars.len() < self.hit_cars.capacity() {
                        self.hit_cars.push((p.player_id, h.car_id));
                    }
                } else {
                    RoomMetrics::inc(&self.metrics.hits_refused);
                }
                // Drop entry k (the ring keeps order).
                remove_at(&mut p.pending_hits, k);
            }
        }
    }

    /// Advances player i's official timeline through its states up to `horizon` (all of
    /// them for `None`).
    fn score_until(
        &mut self,
        i: usize,
        horizon: Option<u32>,
        map: &LoopMap,
        night: &dyn Fn(u32) -> bool,
    ) {
        loop {
            let p = &self.players[i];
            if !p.official.active || p.scored >= p.pushed {
                return;
            }
            if p.scored < p.first() {
                // Fell out of the ring (never expected): skip to what is there.
                let first = p.first();
                self.players[i].scored = first;
                continue;
            }
            let Some(st) = p.state(p.scored) else {
                return;
            };
            if horizon.is_some_and(|h| tick_diff(st.tick, h) < 0) {
                return;
            }
            let n = self.crew_count(i, st.tick);
            let crew_factor = self.rules.crew_factor(n);
            let RoomScoring {
                rules,
                players,
                trains,
                outbox,
                metrics,
                ..
            } = self;
            let p = &mut players[i];
            p.scored += 1;
            p.crew_n = u8::try_from(n).unwrap_or(u8::MAX);
            let ctx = StepCtx {
                player_id: p.player_id,
                map,
                tick_dt: rules.tick_dt,
                night: night(st.tick),
                crew_factor,
                train_points: rules.train_points,
                train_gain: rules.train_gain,
            };
            let (pid, crew, window) = (p.player_id, p.crew, rules.train_ticks);
            let mut check = |a: &Accepted| train_link(trains, pid, crew, window, a);
            let mut out = std::mem::take(&mut p.out);
            out.clear();
            p.official.step(&st, &ctx, &mut check, &mut out);
            let late = p.official.late;
            if late > 0 {
                metrics
                    .scoring_late
                    .fetch_add(late, std::sync::atomic::Ordering::Relaxed);
                p.official.late = 0;
            }
            announce(outbox, metrics, &out, players, crew);
            let p = &mut players[i];
            p.out = out;
            let due = p.official.banked_now
                || p.last_sync
                    .is_none_or(|t| tick_diff(t, st.tick) >= i64::from(rules.sync_ticks));
            if due {
                let banking = p.official.banked_now;
                p.official.banked_now = false;
                p.last_sync = Some(st.tick);
                let verified = !p.offence && p.verified(rules);
                outbox.push((p.player_id, sync_msg(&*p, st.tick, banking, !verified)));
                RoomMetrics::inc(&metrics.score_syncs);
            }
        }
    }

    /// Crewmates within range of player i at `tick` (their nearest state within two ticks).
    fn crew_count(&self, i: usize, tick: u32) -> u32 {
        let me = &self.players[i];
        let Some(my) = me.states.iter().rev().find(|s| s.tick == tick) else {
            return 0;
        };
        let mut n = 0;
        for (j, q) in self.players.iter().enumerate() {
            if j == i || q.crew != me.crew || !q.official.active {
                continue;
            }
            let near =
                q.states.iter().rev().find(|s| {
                    tick_diff(s.tick, tick).unsigned_abs() <= u64::from(CREW_STATE_TICKS)
                });
            if let Some(s) = near {
                if self.delta_mm(my.s_mm, s.s_mm).abs() <= self.rules.crew_range_mm {
                    n += 1;
                }
            }
        }
        n
    }

    fn delta_mm(&self, a: u32, b: u32) -> i64 {
        let l = i64::from(self.loop_len_mm);
        let half = l / 2;
        (i64::from(b) - i64::from(a) + half).rem_euclid(l) - half
    }

    /// Server-detected contacts older than the match window: excused by a reported hit
    /// near them (or its ghost period), by protection or the ghost flag; else the run is
    /// unverified (spec: "A server-detected hit the client didn't report marks the run
    /// unverified").
    fn resolve_contacts(&mut self, i: usize, horizon: Option<u32>) {
        let r = &self.rules;
        let p = &mut self.players[i];
        for k in 0..p.tracker.contacts.len() {
            let Some(c) = p.tracker.contacts.get(k).copied() else {
                continue;
            };
            if c.resolved
                || horizon.is_some_and(|h| tick_diff(c.tick.wrapping_add(r.hit_match_ticks), h) < 0)
            {
                continue;
            }
            let reported = p.reported.iter().any(|&t| {
                let d = tick_diff(t, c.tick);
                d >= -i64::from(r.hit_match_ticks)
                    && d <= i64::from(r.ghost_ticks + r.hit_match_ticks)
            });
            let protected = p
                .states
                .iter()
                .any(|s| s.protected && tick_diff(s.tick, c.tick).unsigned_abs() <= 1);
            if !(reported || protected) {
                p.unreported += 1;
                RoomMetrics::inc(&self.metrics.hits_unreported);
                if p.unreported == 1 {
                    tracing::info!(
                        player = p.player_id,
                        car = c.car_id,
                        tick = c.tick,
                        "server-detected contact the client did not report; run unverified"
                    );
                }
            }
            if let Some(x) = p.tracker.contacts.get_mut(k) {
                x.resolved = true;
            }
        }
    }

    /// `room_event.crew` for crews whose total changed (at most once per interval, or at
    /// once when `now_all`).
    fn crew_totals(&mut self, now: u32, now_all: bool) {
        for k in 0..self.crews.len() {
            let c = self.crews[k];
            let total = self.crew_total(c.slot);
            if c.sent == Some(total)
                || (!now_all
                    && c.sent.is_some()
                    && tick_diff(c.sent_tick, now) < i64::from(self.rules.crew_total_ticks))
            {
                continue;
            }
            self.crews[k].sent = Some(total);
            self.crews[k].sent_tick = now;
            if self.crew_events.len() < self.crew_events.capacity() {
                self.crew_events.push(RoomCrew {
                    crew_slot: c.slot,
                    color: c.slot,
                    session_total: total,
                });
            }
        }
    }

    /// The run ends: everything waiting is decided and paid, the chain is lost; the
    /// crew's session total takes the banked score.
    pub fn end_run(
        &mut self,
        player_id: u16,
        now: u32,
        traffic: &mut dyn RoomTraffic,
        map: &LoopMap,
        night: &dyn Fn(u32) -> bool,
    ) -> Option<RunScore> {
        let i = self.index(player_id)?;
        if !self.players[i].official.active {
            return None;
        }
        self.observe(now, &*traffic, map, true);
        for (player, car) in self.hit_cars.drain(..) {
            traffic.hit_car(player, car);
        }
        self.score_until(i, None, map, night);
        self.resolve_contacts(i, None);
        let RoomScoring {
            rules,
            players,
            trains,
            outbox,
            metrics,
            crews,
            ..
        } = self;
        let p = &mut players[i];
        let last = p.official.scored_tick();
        let ctx = StepCtx {
            player_id: p.player_id,
            map,
            tick_dt: rules.tick_dt,
            night: night(last),
            crew_factor: 1.0,
            train_points: rules.train_points,
            train_gain: rules.train_gain,
        };
        let (pid, crew, window) = (p.player_id, p.crew, rules.train_ticks);
        let mut check = |a: &Accepted| train_link(trains, pid, crew, window, a);
        let mut out = std::mem::take(&mut p.out);
        out.clear();
        let score = p.official.finish(&ctx, &mut check, &mut out);
        announce(outbox, metrics, &out, players, crew);
        let p = &mut players[i];
        p.out = out;
        if let Some(c) = crews.iter_mut().find(|c| c.slot == p.crew) {
            c.ended += score;
        }
        let verified = p.verified(rules);
        let result = RunScore {
            score: u32::try_from(score.max(0)).unwrap_or(u32::MAX),
            counts: p.official.counts,
            max_multiplier_milli: (p.official.counts.max_multiplier * MILLI)
                .round()
                .clamp(0.0, f64::from(u32::MAX)) as u32,
            claims_accepted: p.accepted,
            claims_rejected: p.rejected,
            unreported_hits: p.unreported,
            verified,
        };
        p.claims.clear();
        p.pending_hits.clear();
        self.crew_totals(now, true);
        Some(result)
    }
}

/// Runs a player's new states through its tracker, as far as the traffic history goes.
fn track(p: &mut PlayerScore, hist: Option<&CarHistory>, map: &LoopMap) {
    if p.tracked < p.first() {
        p.tracked = p.first();
    }
    while p.tracked < p.pushed {
        let Some(st) = p.state(p.tracked) else {
            break;
        };
        match hist {
            None => p.tracker.skip(st.tick),
            Some(h) => {
                let Some(latest) = h.latest_tick() else {
                    break;
                };
                if tick_diff(st.tick, latest) < 0 {
                    break; // the traffic at this tick is not stepped yet
                }
                match h.at(st.tick) {
                    Some(cars) => p.tracker.process(&st, cars, map),
                    None => p.tracker.skip(st.tick),
                }
            }
        }
        p.tracked += 1;
    }
}

fn accept(metrics: &RoomMetrics, p: &mut PlayerScore, a: Accepted) {
    p.accepted += 1;
    RoomMetrics::inc(&metrics.claims_accepted);
    p.official.push_event(a);
}

fn reject(
    outbox: &mut Vec<(u16, ServerMsg)>,
    metrics: &RoomMetrics,
    p: &mut PlayerScore,
    c: &Claim,
    r: Reject,
) {
    if r != Reject::NoRun {
        p.rejected += 1;
    }
    metrics.count_claim_rejected(r);
    outbox.push((
        p.player_id,
        ServerMsg::ScoreEvent(ScoreEvent {
            tick: c.tick,
            player_id: p.player_id,
            kind: ScoreEventKind::ClaimRejected,
            points: 0,
            multiplier_gain_milli: 0,
            link: 0,
            sector: 0,
            ref_id: c.id,
        }),
    ));
}

/// The room's train log: a pass (or thread) the same crewmate side made within the window
/// before is a link. Records this one and returns its link count when it is a train.
fn train_link(
    log: &mut Ring<TrainEntry>,
    player_id: u16,
    crew: u8,
    window: u32,
    a: &Accepted,
) -> Option<u8> {
    let thread = a.kind == ClaimKind::Thread;
    let (car, car_b) = if thread {
        (a.car.min(a.car_b), a.car.max(a.car_b))
    } else {
        (a.car, 0)
    };
    let mut best: Option<TrainEntry> = None;
    for e in log.iter() {
        let dt = tick_diff(e.cross_tick, a.cross_tick);
        if e.crew == crew
            && e.player_id != player_id
            && e.car == car
            && e.car_b == car_b
            && (thread || e.right == a.right)
            && dt > 0
            && dt <= i64::from(window)
            && best.is_none_or(|b| tick_diff(b.cross_tick, e.cross_tick) > 0)
        {
            best = Some(*e);
        }
    }
    let link = best.map(|b| b.link.max(1).saturating_add(1));
    log.push(TrainEntry {
        player_id,
        crew,
        car,
        car_b,
        right: a.right,
        cross_tick: a.cross_tick,
        link: link.unwrap_or(1),
    });
    link
}

/// Sector bonuses go to the player; trains to the whole crew ("crews see each other's
/// trains").
fn announce(
    outbox: &mut Vec<(u16, ServerMsg)>,
    metrics: &RoomMetrics,
    events: &[ScoreEvent],
    players: &[PlayerScore],
    crew: u8,
) {
    for e in events {
        if e.kind == ScoreEventKind::Train {
            RoomMetrics::inc(&metrics.trains);
            for q in players.iter().filter(|q| q.crew == crew) {
                outbox.push((q.player_id, ServerMsg::ScoreEvent(e.clone())));
            }
        } else {
            outbox.push((e.player_id, ServerMsg::ScoreEvent(e.clone())));
        }
    }
}

fn sync_msg(p: &PlayerScore, tick: u32, banking: bool, unverified: bool) -> ServerMsg {
    let o = &p.official;
    ServerMsg::ScoreSync(ScoreSync {
        tick,
        run_seq: p.run_seq,
        banked: u32::try_from(o.rules.banked().max(0)).unwrap_or(u32::MAX),
        chain: u32::try_from(o.rules.chain().max(0)).unwrap_or(u32::MAX),
        multiplier_milli: o.multiplier_milli(),
        lives: u8::try_from(o.lives.clamp(0, i64::from(u8::MAX))).unwrap_or(0),
        crew_in_range: p.crew_n.min(protocol::messages::MAX_ROOM_PLAYERS),
        flags: ScoreFlags {
            banking,
            night: o.night,
            unverified,
        },
    })
}

/// Removes the k-th oldest entry of a ring, keeping the order.
fn remove_at<T: Copy + Default>(r: &mut Ring<T>, k: usize) {
    let n = r.len();
    if k >= n {
        return;
    }
    for j in k..n - 1 {
        if let Some(&next) = r.get(j + 1) {
            if let Some(x) = r.get_mut(j) {
                *x = next;
            }
        }
    }
    r.truncate_back(1);
}
