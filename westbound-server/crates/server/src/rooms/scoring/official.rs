//! One run's official score (N6.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Scoring in
//! multiplayer: "3. Official score. The server runs the same scoring rules
//! (`sim::scoring`) on accepted claims only, and adds crew bonuses and trains"; "Sectors
//! replace checkpoints"; "night ×2 comes from the room clock"; Hits ("the client ... is
//! authoritative for losing a life").
//!
//! The timeline runs a fixed lag behind the room (`scoring.official_lag_ms`), one step per
//! accepted `PlayerState` in tick order, so everything that happened at a tick (claims
//! decided, hits reported, crewmates' passes) is known when the tick is paid. A step at
//! tick T, after the previous state's tick P, in the client's order (`Run.tick`):
//!
//! 1. hits and rejoins reported for (P, T]: `notify_hit` (the chain is lost, the lives are
//!    the client's `lives_left`), `forfeit_chain`;
//! 2. night from the room clock at T, the crew factor at T; `begin_tick(dt = T − P)`: the
//!    shoulder (from the reported d), minimum speed and hesitation (from the reported
//!    speed);
//! 3. the accepted claims of (P, T] in arrival order, each paid with `award` like the
//!    client's detection pays it, then its train link (if any) right after it;
//! 4. `end_tick`: multiplier decay (boost from the state's flag), cash-out banking;
//! 5. the sector: its time and Heat hold; a gantry crossed between P and T banks the
//!    chain (`notify_checkpoint`), pays the earned bonuses (× night), and a clean sector
//!    gives a life back.

use protocol::{ClaimKind, ScoreEvent, ScoreEventKind};
use sim::map::LoopMap;
use sim::scoring::params::ScoringTuning;
use sim::scoring::{
    Kind, LoopRoad, PlayerTick, ScoreEventBuffer, Scoring, ScoringParams, SectorTracker, Tag,
};

use super::claims::Accepted;
use super::ring::Ring;
use super::tracker::StateRec;
use crate::rooms::plausibility::tick_diff;

const MM_PER_M: f64 = 1_000.0;
const MILLI: f64 = 1_000.0;
/// Claims waiting to be paid (a few seconds of play).
pub const EVENT_QUEUE: usize = 64;
const HIT_RING: usize = 16;
/// Scoring events one step writes at most (a sector crossing with every bonus, a few
/// claims): the buffer never drops.
const STEP_EVENTS: usize = 64;

/// Run statistics (`run_result`).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Counts {
    pub passes: u32,
    pub close_passes: u32,
    pub cuts: u32,
    pub threads: u32,
    pub trains: u32,
    pub max_multiplier: f64,
}

/// What a step needs from the room.
#[derive(Debug, Clone, Copy)]
pub struct StepCtx<'a> {
    pub player_id: u16,
    pub map: &'a LoopMap,
    pub tick_dt: f64,
    pub night: bool,
    pub crew_factor: f64,
    pub train_points: i64,
    pub train_gain: f64,
}

/// A paid pass or thread, offered to the room's train log: returns the link (2 = the
/// second car of a train) when it continues a crewmate's.
pub type TrainCheck<'a> = dyn FnMut(&Accepted) -> Option<u8> + 'a;

#[derive(Debug, Clone)]
pub struct Official {
    pub rules: Scoring,
    sectors: SectorTracker,
    params: ScoringParams,
    buf: ScoreEventBuffer,
    pub active: bool,
    pub start_tick: u32,
    last: StateRec,
    /// Unwrapped s (m) of `last`.
    s_unw: f64,
    pub lives: i64,
    pub counts: Counts,
    /// Accepted claims waiting for their tick, sorted by (tick, arrival).
    events: Vec<Accepted>,
    /// Reported hits (tick, lives left) and rejoins waiting for their tick.
    hits: Ring<(u32, u8)>,
    rejoins: Ring<u32>,
    /// The step banked (a `ScoreSync` goes out now).
    pub banked_now: bool,
    pub night: bool,
    /// Claims paid later than their tick (they arrived after it was scored).
    pub late: u64,
}

impl Official {
    pub fn new(params: &ScoringParams) -> Self {
        Self {
            rules: Scoring::new(params),
            sectors: SectorTracker::new(&params.legs),
            params: params.clone(),
            buf: ScoreEventBuffer::new(STEP_EVENTS),
            active: false,
            start_tick: 0,
            last: StateRec::default(),
            s_unw: 0.0,
            lives: params.lives.lives,
            counts: Counts::default(),
            events: Vec::with_capacity(EVENT_QUEUE),
            hits: Ring::new(HIT_RING),
            rejoins: Ring::new(HIT_RING),
            banked_now: false,
            night: false,
            late: 0,
        }
    }

    /// A new run placed at `s_mm` at room tick `tick`.
    pub fn start(&mut self, tick: u32, s_mm: u32) {
        self.rules.reset(&self.params);
        self.active = true;
        self.start_tick = tick;
        self.last = StateRec {
            tick,
            s_mm,
            reset: true,
            ..StateRec::default()
        };
        self.s_unw = f64::from(s_mm) / MM_PER_M;
        self.sectors.start(self.s_unw);
        self.lives = self.params.lives.lives;
        self.counts = Counts {
            max_multiplier: self.rules.multiplier(),
            ..Counts::default()
        };
        self.events.clear();
        self.hits.clear();
        self.rejoins.clear();
        self.banked_now = false;
        self.late = 0;
    }

    /// The last tick scored.
    pub fn scored_tick(&self) -> u32 {
        self.last.tick
    }

    pub fn push_event(&mut self, a: Accepted) {
        if tick_diff(self.last.tick, a.tick) <= 0 {
            self.late += 1;
        }
        if self.events.len() == self.events.capacity() {
            // Never expected (claims are paid within the lag); the oldest goes unpaid.
            self.events.remove(0);
        }
        let at = self
            .events
            .iter()
            .position(|e| tick_diff(a.tick, e.tick) > 0 || (e.tick == a.tick && e.seq > a.seq))
            .unwrap_or(self.events.len());
        self.events.insert(at, a);
    }

    pub fn push_hit(&mut self, tick: u32, lives_left: u8) {
        self.hits.push((tick, lives_left));
    }

    pub fn push_rejoin(&mut self, tick: u32) {
        self.rejoins.push(tick);
    }

    /// One accepted state at its tick (see the module docs). `trains` sees every paid pass
    /// and thread; `out` gets the sector bonuses and trains to announce.
    pub fn step(
        &mut self,
        st: &StateRec,
        ctx: &StepCtx<'_>,
        trains: &mut TrainCheck<'_>,
        out: &mut Vec<ScoreEvent>,
    ) {
        if !self.active {
            return;
        }
        let dt = tick_diff(self.last.tick, st.tick).max(0) as f64 * ctx.tick_dt;
        self.apply_hits(Some(st.tick));
        self.rules.set_night(ctx.night);
        self.night = ctx.night;
        self.rules.set_crew_factor(ctx.crew_factor);
        let road = LoopRoad::new(ctx.map);
        let s_m = f64::from(st.s_mm) / MM_PER_M;
        let player = PlayerTick {
            s: s_m,
            d: st.d,
            v: st.v,
            yaw: st.yaw,
            boost_active: st.boost,
        };
        self.rules.begin_tick(dt, &player, &road, &mut self.buf);
        self.pay_events(Some(st.tick), ctx, trains, out);
        self.rules.end_tick(dt, &player, &mut self.buf);
        self.counts.max_multiplier = self.counts.max_multiplier.max(self.rules.multiplier());
        // The sector.
        self.sectors.advance(dt);
        self.sectors.observe_multiplier(dt, self.rules.multiplier());
        let step_m = ctx.map.signed_delta_mm(self.last.s_mm, st.s_mm) as f64 / MM_PER_M;
        if !st.reset {
            if let Some(g) = ctx.map.sector_crossed(self.last.s_mm, st.s_mm) {
                let to_line = ctx
                    .map
                    .signed_delta_mm(self.last.s_mm, ctx.map.sectors[g].s_mm)
                    as f64
                    / MM_PER_M;
                self.cross_sector(g, self.s_unw + to_line, st.tick, ctx, out);
            }
        } else {
            // A placement: the sector restarts where the car now is.
            self.sectors.start(self.s_unw + step_m);
        }
        self.s_unw += step_m;
        self.last = *st;
        self.drain();
    }

    /// A gantry: bank, the earned bonuses (× night), a life back when clean.
    fn cross_sector(
        &mut self,
        gantry: usize,
        line_s: f64,
        tick: u32,
        ctx: &StepCtx<'_>,
        out: &mut Vec<ScoreEvent>,
    ) {
        let c = self.sectors.cross(line_s);
        self.rules.notify_checkpoint(&mut self.buf);
        let n = ctx.map.sector_count().max(1);
        // The sector just completed (1-based): from the gantry before this one.
        let sector = u8::try_from((gantry + n - 1) % n + 1).unwrap_or(0);
        for (tag, base) in c.bonuses(&self.params.legs) {
            let pts = self.rules.award_bonus(tag, base, &mut self.buf);
            let kind = match tag {
                Tag::Clean => ScoreEventKind::SectorClean,
                Tag::Pace => ScoreEventKind::SectorPace,
                Tag::Threads => ScoreEventKind::SectorThreads,
                _ => ScoreEventKind::SectorHeat,
            };
            push_out(
                out,
                ScoreEvent {
                    tick,
                    player_id: ctx.player_id,
                    kind,
                    points: u32::try_from(pts.max(0)).unwrap_or(u32::MAX),
                    multiplier_gain_milli: 0,
                    link: 0,
                    sector,
                    ref_id: 0,
                },
            );
        }
        if c.clean && self.params.lives.clean_leg_restore && self.lives < self.params.lives.lives {
            self.lives += 1;
        }
    }

    /// Hits and rejoins up to `upto` (all of them for `None`).
    fn apply_hits(&mut self, upto: Option<u32>) {
        let due = |t: u32| upto.is_none_or(|u| tick_diff(t, u) >= 0);
        while let Some(&(t, left)) = self.hits.get(0) {
            if !due(t) {
                break;
            }
            self.hits.drop_front(1);
            self.rules.notify_hit(&mut self.buf);
            self.sectors.notify_hit();
            self.lives = i64::from(left);
        }
        while let Some(&t) = self.rejoins.get(0) {
            if !due(t) {
                break;
            }
            self.rejoins.drop_front(1);
            self.rules.forfeit_chain(&mut self.buf);
        }
    }

    /// Pays the accepted claims up to `upto` (all of them for `None`).
    fn pay_events(
        &mut self,
        upto: Option<u32>,
        ctx: &StepCtx<'_>,
        trains: &mut TrainCheck<'_>,
        out: &mut Vec<ScoreEvent>,
    ) {
        let mut paid = 0;
        for k in 0..self.events.len() {
            let e = self.events[k];
            if upto.is_some_and(|u| tick_diff(e.tick, u) < 0) {
                break;
            }
            paid += 1;
            let (kind, base, gain) = claim_numbers(self.rules.tuning(), e.kind);
            self.rules.award(kind, base, gain, -1.0, &mut self.buf);
            match e.kind {
                ClaimKind::Pass => self.counts.passes += 1,
                ClaimKind::ClosePass => {
                    self.counts.close_passes += 1;
                    self.sectors.notify_close_pass();
                }
                ClaimKind::Cut => self.counts.cuts += 1,
                ClaimKind::Thread => {
                    self.counts.threads += 1;
                    self.sectors.notify_thread();
                }
            }
            if e.kind != ClaimKind::Cut {
                if let Some(link) = trains(&e) {
                    let pts = self.rules.award(
                        Kind::Train,
                        ctx.train_points,
                        ctx.train_gain,
                        -1.0,
                        &mut self.buf,
                    );
                    self.counts.trains += 1;
                    push_out(
                        out,
                        ScoreEvent {
                            tick: e.tick,
                            player_id: ctx.player_id,
                            kind: ScoreEventKind::Train,
                            points: u32::try_from(pts.max(0)).unwrap_or(u32::MAX),
                            multiplier_gain_milli: (ctx.train_gain * MILLI).round() as u32,
                            link,
                            sector: 0,
                            ref_id: e.car,
                        },
                    );
                }
            }
            self.counts.max_multiplier = self.counts.max_multiplier.max(self.rules.multiplier());
        }
        self.events.drain(..paid);
    }

    /// The run ends: everything still waiting is paid on the last state, then the held
    /// chain is lost (`notify_run_end`). Returns the final score (the banked total).
    pub fn finish(
        &mut self,
        ctx: &StepCtx<'_>,
        trains: &mut TrainCheck<'_>,
        out: &mut Vec<ScoreEvent>,
    ) -> i64 {
        if !self.active {
            return self.rules.banked();
        }
        self.apply_hits(None);
        if !self.events.is_empty() {
            let road = LoopRoad::new(ctx.map);
            let st = self.last;
            let player = PlayerTick {
                s: f64::from(st.s_mm) / MM_PER_M,
                d: st.d,
                v: st.v,
                yaw: st.yaw,
                boost_active: st.boost,
            };
            self.rules.begin_tick(0.0, &player, &road, &mut self.buf);
            self.pay_events(None, ctx, trains, out);
            self.rules.end_tick(0.0, &player, &mut self.buf);
        }
        self.rules.notify_run_end(&mut self.buf);
        self.drain();
        self.active = false;
        self.rules.banked()
    }

    fn drain(&mut self) {
        self.banked_now |= self
            .buf
            .as_slice()
            .iter()
            .any(|e| e.kind == Kind::Banked || e.kind == Kind::Bonus);
        self.buf.clear();
    }

    pub fn multiplier_milli(&self) -> u32 {
        (self.rules.multiplier() * MILLI)
            .round()
            .clamp(0.0, f64::from(u32::MAX)) as u32
    }
}

fn push_out(out: &mut Vec<ScoreEvent>, e: ScoreEvent) {
    if out.len() < out.capacity() {
        out.push(e);
    }
}

/// The base points and gain of a claim kind (`ScoringTuning`).
fn claim_numbers(sc: &ScoringTuning, kind: ClaimKind) -> (Kind, i64, f64) {
    match kind {
        ClaimKind::Pass => (Kind::Pass, sc.pass_points, sc.pass_multiplier_gain),
        ClaimKind::ClosePass => (
            Kind::ClosePass,
            sc.close_pass_points,
            sc.close_pass_multiplier_gain,
        ),
        ClaimKind::Cut => (Kind::Cut, sc.cut_points, sc.cut_multiplier_gain),
        ClaimKind::Thread => (Kind::Thread, sc.thread_points, sc.thread_multiplier_gain),
    }
}
