//! Room scoring without sockets (N6.1): a scripted traffic with a history, players driving
//! by hand, claims honest and not. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Scoring in
//! multiplayer; Testing ("Scoring: every event, anti-exploit rule, banking and loss case,
//! plus crew proximity and train detection").

use std::sync::Arc;

use protocol::{
    ClaimCar, ClaimKind, Density, FrameBuilder, HitReport, HitTarget, PlayerFlags, PlayerState,
    RunState, ScoreClaim, ScoreEvent, ScoreEventKind, ScoreSync, ServerMsg, Side,
};
use sim::map::LoopMap;

use super::claims::Reject;
use super::{RoomScoring, RunScore, ScoringRules};
use crate::config::ScoringConfig;
use crate::map::ServerMap;
use crate::rooms::car_history::{CarHistory, CarSample};
use crate::rooms::metrics::RoomMetrics;
use crate::rooms::traffic::{PlayerView, RoomTraffic, SpawnSpot};

const DT: f64 = 0.05;
/// Lane centres at s ≈ 1 km on loop_v1 (4 lanes): 1.7 m + (i + 0.5) × 3.6 m.
const LANE: [f64; 4] = [3.5, 7.1, 10.7, 14.3];

#[derive(Debug, Clone, Copy)]
struct Car {
    id: u16,
    /// Position (m) at tick `t0` and speed (m/s).
    s0: f64,
    t0: u32,
    v: f64,
    d: f64,
    lane: i8,
    length: f32,
    width: f32,
}

impl Car {
    fn s_at(&self, tick: u32) -> f64 {
        self.s0 + self.v * f64::from(tick.wrapping_sub(self.t0)) * DT
    }
}

/// Cars on straight lines, recorded every tick like `SimTraffic`.
struct Fake {
    cars: Vec<Car>,
    history: CarHistory,
    hits: Vec<(u16, u16)>,
    samples: Vec<CarSample>,
}

impl Fake {
    fn new() -> Self {
        Self {
            cars: Vec::new(),
            history: CarHistory::new(48, 64),
            hits: Vec::new(),
            samples: Vec::with_capacity(64),
        }
    }
}

impl RoomTraffic for Fake {
    fn tick(&mut self, tick: u32, _players: &[PlayerView]) {
        self.samples.clear();
        for c in &self.cars {
            self.samples.push(CarSample {
                car_id: c.id,
                lane: c.lane,
                s_mm: (c.s_at(tick) * 1_000.0).round() as u32,
                d: c.d as f32,
                v: c.v as f32,
                v_lat: 0.0,
                length: c.length,
                width: c.width,
            });
        }
        self.history.record_samples(tick, &self.samples);
    }
    fn set_density(&mut self, _d: Density) {}
    fn set_night(&mut self, _n: bool) {}
    fn write_client(&mut self, _p: u16, _s: u32, _j: bool, _f: &mut FrameBuilder) {}
    fn player_left(&mut self, _p: u16) {}
    fn free_gap(&self, _m: &LoopMap, want: SpawnSpot) -> SpawnSpot {
        want
    }
    fn hit_car(&mut self, player_id: u16, car_id: u16) -> bool {
        self.hits.push((player_id, car_id));
        true
    }
    fn car_history(&self) -> Option<&CarHistory> {
        Some(&self.history)
    }
    fn client_has(&self, _player_id: u16, car_id: u16) -> bool {
        self.cars.iter().any(|c| c.id == car_id)
    }
}

/// A player driving a straight line: s(t) = s0 + v (t − t0) dt, at d (a lane change as a
/// step in d at `lane_change`).
#[derive(Debug, Clone, Copy)]
struct Driver {
    id: u16,
    s0: f64,
    t0: u32,
    v: f64,
    d: f64,
    lane_change: Option<(u32, f64)>,
}

impl Driver {
    fn state(&self, tick: u32) -> PlayerState {
        let s = self.s0 + self.v * f64::from(tick - self.t0) * DT;
        let d = match self.lane_change {
            Some((t, d2)) if tick >= t => d2,
            _ => self.d,
        };
        PlayerState {
            tick,
            s_mm: (s * 1_000.0).round() as u32,
            d_cm: (d * 100.0).round() as i16,
            speed_cms: (self.v * 100.0).round() as u16,
            flags: PlayerFlags::default(),
            run_state: RunState::Driving,
            ..PlayerState::default()
        }
    }
}

struct H {
    sc: RoomScoring,
    tr: Fake,
    map: Arc<ServerMap>,
    metrics: Arc<RoomMetrics>,
    now: u32,
    night: bool,
    drivers: Vec<Driver>,
    msgs: Vec<(u16, ServerMsg)>,
}

impl H {
    fn new() -> Self {
        Self::with(|_| {})
    }

    fn with(tweak: impl FnOnce(&mut ScoringConfig)) -> Self {
        let mut cfg = ScoringConfig::default();
        tweak(&mut cfg);
        let rules = ScoringRules::from_config(&cfg, 20, 2_000);
        let map = crate::map::builtin().expect("loop_v1");
        let metrics = Arc::new(RoomMetrics::default());
        Self {
            sc: RoomScoring::new(rules, &map.map, metrics.clone()),
            tr: Fake::new(),
            map,
            metrics,
            now: 1_000,
            night: false,
            drivers: Vec::new(),
            msgs: Vec::new(),
        }
    }

    /// A player in crew `crew` starting a run now at `s0` m, `v` m/s, in lane `lane`.
    fn driver(&mut self, id: u16, crew: u8, s0: f64, v: f64, lane: usize) -> usize {
        self.sc.add_player(id, crew);
        let d = Driver {
            id,
            s0,
            t0: self.now,
            v,
            d: LANE[lane],
            lane_change: None,
        };
        self.sc
            .start_run(id, 1, self.now, (s0 * 1_000.0).round() as u32);
        self.drivers.push(d);
        self.drivers.len() - 1
    }

    /// A car `ahead` m in front of driver `k` now, at `v` m/s, at `d`.
    fn car(&mut self, id: u16, k: usize, ahead: f64, v: f64, d: f64, lane: i8) {
        let drv = self.drivers[k];
        let s = drv.s0 + drv.v * f64::from(self.now - drv.t0) * DT + ahead;
        self.tr.cars.push(Car {
            id,
            s0: s,
            t0: self.now,
            v,
            d,
            lane,
            length: 4.5,
            width: 1.8,
        });
    }

    /// One room tick: the traffic steps, every driver reports its state for it, scoring.
    fn tick(&mut self) {
        self.now += 1;
        self.tr.tick(self.now, &[]);
        for d in &self.drivers {
            let st = d.state(self.now);
            self.sc.on_state(d.id, &st, false, 0);
        }
        let night = self.night;
        self.sc
            .tick(self.now, &mut self.tr, &self.map.map, &move |_| night);
        self.msgs.append(&mut self.sc.outbox);
    }

    fn ticks(&mut self, n: u32) {
        for _ in 0..n {
            self.tick();
        }
    }

    fn claim(&mut self, player: u16, id: u16, kind: ClaimKind, tick: u32, cars: &[(u16, u16)]) {
        let m = ScoreClaim {
            claim_id: id,
            tick,
            kind,
            side: Side::None,
            cars: cars
                .iter()
                .map(|&(car_id, clearance_mm)| ClaimCar {
                    car_id,
                    clearance_mm,
                })
                .collect(),
        };
        self.sc.on_claim(player, &m, self.now);
    }

    fn end(&mut self, player: u16) -> RunScore {
        let night = self.night;
        let r = self
            .sc
            .end_run(player, self.now, &mut self.tr, &self.map.map, &move |_| {
                night
            })
            .expect("a run in progress");
        self.msgs.append(&mut self.sc.outbox);
        r
    }

    fn events(&self, player: u16) -> Vec<ScoreEvent> {
        self.msgs
            .iter()
            .filter(|(p, _)| *p == player)
            .filter_map(|(_, m)| match m {
                ServerMsg::ScoreEvent(e) => Some(e.clone()),
                _ => None,
            })
            .collect()
    }

    fn syncs(&self, player: u16) -> Vec<ScoreSync> {
        self.msgs
            .iter()
            .filter(|(p, _)| *p == player)
            .filter_map(|(_, m)| match m {
                ServerMsg::ScoreSync(s) => Some(s.clone()),
                _ => None,
            })
            .collect()
    }

    fn rejected(&self, player: u16) -> Vec<u16> {
        self.events(player)
            .iter()
            .filter(|e| e.kind == ScoreEventKind::ClaimRejected)
            .map(|e| e.ref_id)
            .collect()
    }
}

/// The tick a car `ahead` m in front, closing at `closing` m/s, is fully behind the
/// server's hull (4.8 m player, 4.5 m car, 8 cm insets): what a client would claim.
fn done_tick(start: u32, ahead: f64, closing: f64) -> u32 {
    let hl_sum = (4.8 / 2.0 - 0.08) + (4.5 / 2.0 - 0.08);
    start + ((ahead + hl_sum) / (closing * DT)).ceil() as u32
}

fn speed_factor(v: f64) -> f64 {
    let t = ((v * 3.6 - 100.0) / 150.0).clamp(0.0, 1.0);
    1.0 + t
}

#[test]
fn an_honest_pass_is_accepted_and_paid_at_its_tick() {
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 35.0, 1);
    h.car(50, k, 20.0, 25.0, LANE[2], 2);
    let start = h.now;
    let t = done_tick(start, 20.0, 10.0);
    h.ticks(t - start);
    h.claim(1, 7, ClaimKind::Pass, t, &[(50, 1_900)]);
    h.ticks(80);
    assert!(h.rejected(1).is_empty(), "{:?}", h.events(1));
    assert_eq!(RoomMetrics::get(&h.metrics.claims_accepted), 1);
    // Paid once the official timeline passed the tick: 10 × 1.0 × speed factor.
    let pts = (10.0 * speed_factor(35.0)).round() as u32;
    let syncs = h.syncs(1);
    assert!(
        syncs.iter().any(|s| s.chain == pts || s.banked == pts),
        "{syncs:?}"
    );
    assert!(syncs.iter().all(|s| !s.flags.unverified && s.lives == 2));
    // At least once a second, and at banking moments (the cash-out after the decay).
    assert!(syncs.windows(2).all(|w| w[1].tick - w[0].tick <= 20));
    assert!(syncs.iter().any(|s| s.flags.banking && s.banked == pts));
    let r = h.end(1);
    assert_eq!(r.score, pts);
    assert_eq!(r.counts.passes, 1);
    assert_eq!(r.claims_accepted, 1);
    assert!(r.verified);
    assert!(r.max_multiplier_milli > 1_900, "{}", r.max_multiplier_milli);
}

#[test]
fn claims_that_do_not_match_the_server_are_rejected() {
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 35.0, 1);
    h.car(50, k, 20.0, 25.0, LANE[2], 2); // passed at ~1.9 m
    h.car(51, k, 300.0, 35.0, LANE[2], 2); // never passed
    let start = h.now;
    let t = done_tick(start, 20.0, 10.0);
    h.ticks(t - start + 2);
    // Fabricated id, a car never passed, wrong timing (2 s late), inflated clearance.
    h.claim(1, 1, ClaimKind::Pass, t, &[(999, 2_000)]);
    h.claim(1, 2, ClaimKind::Pass, t, &[(51, 2_000)]);
    h.claim(1, 3, ClaimKind::Pass, t + 40, &[(50, 2_000)]);
    h.claim(1, 4, ClaimKind::ClosePass, t, &[(50, 300)]);
    h.ticks(60);
    let mut rej = h.rejected(1);
    rej.sort_unstable();
    assert_eq!(rej, [1, 2, 3, 4]);
    let m = h.metrics.clone();
    assert_eq!(m.claims_rejected(Reject::UnknownCar), 1);
    assert_eq!(m.claims_rejected(Reject::NoPass), 1);
    assert_eq!(m.claims_rejected(Reject::Timing), 1);
    assert_eq!(m.claims_rejected(Reject::Clearance), 1);
    // The honest claim of the same pass still goes through; claiming it twice does not.
    h.claim(1, 5, ClaimKind::Pass, t, &[(50, 1_900)]);
    h.claim(1, 6, ClaimKind::Pass, t + 1, &[(50, 1_900)]);
    h.ticks(20);
    assert_eq!(RoomMetrics::get(&m.claims_accepted), 1);
    assert_eq!(m.claims_rejected(Reject::Duplicate), 1);
    let r = h.end(1);
    assert_eq!(r.claims_rejected, 5);
    assert_eq!(r.counts.passes, 1);
}

#[test]
fn close_passes_and_a_thread() {
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 40.0, 1);
    // A gate: one car either side, 0.6 m clear of the server's hull (0.895 + 0.82).
    let off = 0.895 + 0.82 + 0.6;
    h.car(60, k, 30.0, 30.0, LANE[1] - off, 0);
    h.car(61, k, 30.2, 30.0, LANE[1] + off, 2);
    let start = h.now;
    let t = done_tick(start, 30.2, 10.0);
    h.ticks(t - start);
    h.claim(1, 1, ClaimKind::ClosePass, t, &[(60, 650)]);
    h.claim(1, 2, ClaimKind::ClosePass, t, &[(61, 650)]);
    h.claim(1, 3, ClaimKind::Thread, t, &[(60, 650), (61, 650)]);
    h.ticks(60);
    assert!(h.rejected(1).is_empty(), "{:?}", h.events(1));
    // 30 × 1 × sf, 30 × 4 × sf, 50 × 7 × sf at 40 m/s, all paid on one tick; the chain
    // holds them until it cashes out.
    let sf = speed_factor(40.0);
    let want = (30.0 * sf).round() + (30.0 * 4.0 * sf).round() + (50.0 * 7.0 * sf).round();
    let last = h.syncs(1).last().cloned().expect("syncs");
    assert_eq!(f64::from(last.chain), want, "{last:?}");
    let r = h.end(1);
    assert_eq!((r.counts.close_passes, r.counts.threads), (2, 1));
    assert_eq!(r.max_multiplier_milli, 12_000, "1 + 3 + 3 + 5");
    assert_eq!(r.score, 0, "the run ended with the chain unbanked: lost");
    // A thread with both cars on one side is refused.
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 40.0, 1);
    h.car(60, k, 30.0, 30.0, LANE[1] + off, 2);
    h.car(61, k, 38.0, 30.0, LANE[1] + off, 2);
    let t = done_tick(h.now, 38.0, 10.0);
    h.ticks(t - h.now);
    h.claim(1, 9, ClaimKind::Thread, t, &[(60, 650), (61, 650)]);
    h.ticks(30);
    assert_eq!(h.rejected(1), [9]);
}

#[test]
fn cuts_need_traffic_in_the_window_and_respect_the_cooldown() {
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 45.0, 1);
    // A car in lane 2, 8 m ahead, at the player's speed.
    h.car(70, k, 8.0, 45.0, LANE[2], 2);
    let t = h.now + 10;
    h.drivers[k].lane_change = Some((t, LANE[2] - 1.0));
    h.ticks(15);
    h.claim(1, 1, ClaimKind::Cut, t, &[(70, 0)]);
    h.claim(1, 2, ClaimKind::Cut, t, &[(70, 0)]);
    // No lane change within the timing window of this one.
    h.ticks(20);
    h.claim(1, 3, ClaimKind::Cut, t + 20, &[(70, 0)]);
    h.ticks(40);
    let rej = h.rejected(1);
    assert_eq!(rej, [2, 3], "{:?}", h.events(1));
    assert_eq!(h.metrics.claims_rejected(Reject::Cooldown), 1);
    assert_eq!(h.metrics.claims_rejected(Reject::Cut), 1);
    let r = h.end(1);
    assert_eq!(r.counts.cuts, 1);
    // Too slow for a cut (120 km/h).
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 33.3, 1);
    h.car(70, k, 8.0, 33.3, LANE[2], 2);
    let t = h.now + 10;
    h.drivers[k].lane_change = Some((t, LANE[2] - 1.0));
    h.ticks(15);
    h.claim(1, 1, ClaimKind::Cut, t, &[(70, 0)]);
    h.ticks(20);
    assert_eq!(h.rejected(1), [1]);
}

#[test]
fn crew_proximity_and_trains() {
    let mut h = H::new();
    // Two crewmates, 10 m apart in lane 1, and a third player (another crew) far away.
    let a = h.driver(1, 0, 1_010.0, 35.0, 1);
    let _b = h.driver(2, 0, 1_000.0, 35.0, 1);
    let _c = h.driver(3, 5, 3_000.0, 35.0, 1);
    h.car(50, a, 20.0, 25.0, LANE[2], 2);
    let start = h.now;
    let ta = done_tick(start, 20.0, 10.0);
    let tb = done_tick(start, 30.0, 10.0); // 1 s later: 10 m further back
    h.ticks(ta - start);
    h.claim(1, 1, ClaimKind::Pass, ta, &[(50, 1_900)]);
    h.ticks(tb - ta);
    h.claim(2, 1, ClaimKind::Pass, tb, &[(50, 1_900)]);
    h.ticks(200); // both chains cash out
    let ra = h.end(1);
    let rb = h.end(2);
    // Each within 30 m of the other: ×1.25 on the pass.
    let pts = (10.0 * speed_factor(35.0) * 1.25).round() as u32;
    assert_eq!(ra.score, pts, "{ra:?}");
    assert_eq!(ra.counts.trains, 0);
    // B passed the same car on the same side within 1 s after A: a train (TRAIN ×2):
    // 25 base at the multiplier after B's pass (2.0), × speed, × crew.
    assert_eq!(rb.counts.trains, 1);
    let train = (25.0 * 2.0 * speed_factor(35.0) * 1.25).round() as u32;
    assert_eq!(rb.score, pts + train, "{rb:?}");
    let ev = h.events(2);
    let t = ev
        .iter()
        .find(|e| e.kind == ScoreEventKind::Train)
        .expect("train");
    assert_eq!((t.link, t.ref_id, t.player_id), (2, 50, 2));
    assert_eq!(t.multiplier_gain_milli, 2_000);
    // Crewmates see it; the other crew does not.
    assert!(h.events(1).iter().any(|e| e.kind == ScoreEventKind::Train));
    assert!(!h.events(3).iter().any(|e| e.kind == ScoreEventKind::Train));
    assert!(h.syncs(1).iter().any(|s| s.crew_in_range == 1));
    assert!(h.syncs(3).iter().all(|s| s.crew_in_range == 0));
    // The session crew total: both runs' scores.
    assert_eq!(h.sc.crew_total(0), ra.score + rb.score);
    assert!(h
        .sc
        .crew_events
        .iter()
        .any(|c| c.crew_slot == 0 && c.session_total == ra.score + rb.score));
}

#[test]
fn night_doubles_points() {
    let mut h = H::new();
    h.night = true;
    let k = h.driver(1, 0, 1_000.0, 35.0, 1);
    h.car(50, k, 20.0, 25.0, LANE[2], 2);
    let t = done_tick(h.now, 20.0, 10.0);
    h.ticks(t - h.now);
    h.claim(1, 1, ClaimKind::Pass, t, &[(50, 1_900)]);
    h.ticks(100);
    let r = h.end(1);
    assert_eq!(r.score, (10.0 * speed_factor(35.0) * 2.0).round() as u32);
    assert!(h.syncs(1).iter().all(|s| s.flags.night));
}

#[test]
fn sectors_bank_pay_bonuses_and_a_clean_one_gives_a_life_back() {
    let mut h = H::new();
    // 400 m before gantry 1 (4166.667 m), at 50 m/s (180 km/h: pace).
    let _k = h.driver(1, 0, 3_766.667, 50.0, 0);
    h.ticks(200); // crossed at ~8 s
    h.ticks(40);
    let ev = h.events(1);
    let kinds: Vec<ScoreEventKind> = ev.iter().map(|e| e.kind).collect();
    assert_eq!(
        kinds,
        [ScoreEventKind::SectorClean, ScoreEventKind::SectorPace],
        "{ev:?}"
    );
    assert!(
        ev.iter().all(|e| e.sector == 1),
        "sector 1 (from gantry 0) completed"
    );
    assert_eq!(ev[0].points, 5_000);
    assert_eq!(ev[1].points, 3_000);
    assert!(h
        .syncs(1)
        .iter()
        .any(|s| s.flags.banking && s.banked == 8_000));
    // A hit in the next sector: not clean, and a life is gone until a clean sector.
    let hit = HitReport {
        tick: h.now - 5,
        target: HitTarget::Barrier,
        car_id: 0,
        lives_left: 1,
    };
    h.sc.on_hit(1, &hit, h.now);
    h.ticks(1_700); // gantry 2 at 8333 m: ~83 s after gantry 1
    let ev = h.events(1);
    assert_eq!(ev.len(), 3, "only Pace for sector 2: {ev:?}");
    assert_eq!(ev[2].kind, ScoreEventKind::SectorPace);
    assert!(h.syncs(1).iter().any(|s| s.lives == 1));
    h.ticks(1_700);
    let ev = h.events(1);
    assert_eq!(ev[3].kind, ScoreEventKind::SectorClean);
    assert_eq!(
        h.syncs(1).last().map(|s| s.lives),
        Some(2),
        "a clean sector restores the life"
    );
    let r = h.end(1);
    assert_eq!(r.score, 8_000 + 3_000 + 8_000);
}

#[test]
fn an_unreported_contact_makes_the_run_unverified_and_a_reported_hit_makes_the_car_react() {
    // The car sits 0.5 m ahead, overlapping the player by ~0.5 m laterally.
    let run = |report: bool| {
        let mut h = H::new();
        let k = h.driver(1, 0, 1_000.0, 30.0, 1);
        h.ticks(5);
        h.car(80, k, 0.5, 30.0, LANE[1] + 1.2, 1);
        h.ticks(4);
        if report {
            let hit = HitReport {
                tick: h.now - 3,
                target: HitTarget::Traffic,
                car_id: 80,
                lives_left: 1,
            };
            h.sc.on_hit(1, &hit, h.now);
        }
        h.tr.cars.clear();
        h.ticks(60);
        let r = h.end(1);
        (r, h.tr.hits.clone(), h.syncs(1))
    };
    let (r, hits, syncs) = run(false);
    assert_eq!(r.unreported_hits, 1);
    assert!(!r.verified);
    assert!(hits.is_empty());
    assert!(syncs.last().is_some_and(|s| s.flags.unverified));
    let (r, hits, syncs) = run(true);
    assert_eq!(r.unreported_hits, 0);
    assert!(r.verified);
    assert_eq!(hits, [(1, 80)], "the confirmed hit's car reacts");
    assert!(syncs.iter().any(|s| s.lives == 1));
}

#[test]
fn rejoin_forfeits_the_chain_and_late_claims_have_no_run() {
    let mut h = H::new();
    let k = h.driver(1, 0, 1_000.0, 35.0, 1);
    h.car(50, k, 20.0, 25.0, LANE[2], 2);
    let t = done_tick(h.now, 20.0, 10.0);
    h.ticks(t - h.now);
    h.claim(1, 1, ClaimKind::Pass, t, &[(50, 1_900)]);
    h.ticks(2);
    h.sc.rejoin(1, h.now); // before the chain could cash out
    h.ticks(60);
    let r = h.end(1);
    assert_eq!(r.score, 0, "the chain went with the rejoin");
    assert_eq!(r.counts.passes, 1);
    // After the run: rejected as no_run, not counted against the player.
    h.claim(1, 2, ClaimKind::Pass, t, &[(50, 1_900)]);
    assert_eq!(h.metrics.claims_rejected(Reject::NoRun), 1);
    assert!(h
        .sc
        .end_run(1, h.now, &mut h.tr, &h.map.map, &|_| false)
        .is_none());
}

#[test]
fn acceptance_below_the_threshold_leaves_the_run_unverified() {
    let mut h = H::with(|c| c.verify_min_claims = 4);
    let k = h.driver(1, 0, 1_000.0, 35.0, 1);
    h.car(50, k, 20.0, 25.0, LANE[2], 2);
    let t = done_tick(h.now, 20.0, 10.0);
    h.ticks(t - h.now);
    h.claim(1, 1, ClaimKind::Pass, t, &[(50, 1_900)]);
    for id in 2..6 {
        h.claim(1, id, ClaimKind::Pass, t, &[(50, 1_900)]);
    }
    h.ticks(40);
    let r = h.end(1);
    assert_eq!((r.claims_accepted, r.claims_rejected), (1, 4));
    assert!(!r.verified, "20 % accepted");
}

#[test]
fn a_run_ending_decides_only_its_own_claims() {
    let mut h = H::new();
    let _a = h.driver(1, 0, 3_000.0, 35.0, 1);
    let b = h.driver(2, 1, 1_000.0, 35.0, 1);
    h.car(50, b, 20.0, 25.0, LANE[2], 2);
    let t = done_tick(h.now, 20.0, 10.0);
    // B claims its pass two ticks before the server will see it complete (inside the
    // tolerance): the claim waits for B's next states...
    h.ticks(t - 2 - h.now);
    h.claim(2, 1, ClaimKind::Pass, t - 2, &[(50, 1_900)]);
    // ...even when A's run ends meanwhile (A's claims alone are decided at once).
    h.end(1);
    h.ticks(20);
    assert!(h.rejected(2).is_empty(), "{:?}", h.events(2));
    assert_eq!(RoomMetrics::get(&h.metrics.claims_accepted), 1);
}

/// N10.1 shadow contacts: B drives through A (ghosted) 10 m/s faster in the same lane: one
/// contact over the ticks their boxes overlap, at the pair's speed, with no disagreement
/// (both drive straight: the extrapolated views are exact).
#[test]
fn a_player_driving_through_another_is_one_shadow_contact() {
    let mut h = H::new();
    h.driver(1, 0, 1_000.0, 30.0, 1);
    h.driver(2, 0, 980.0, 40.0, 1);
    h.ticks(120);
    let out = std::mem::take(&mut h.sc.shadow.out);
    assert_eq!(out.len(), 1, "{out:?}");
    let c = out[0];
    assert_eq!((c.player_a, c.player_b), (1, 2));
    // Overlap while the centres are within one hull length (2 × 2.32 m) of each other:
    // 9.28 m at 0.5 m per tick.
    assert!((17..=20).contains(&c.ticks), "{c:?}");
    assert!((c.speed_mps - 35.0).abs() < 0.3, "{c:?}");
    assert!((c.closing_mps - 10.0).abs() < 0.01, "{c:?}");
    assert!(c.depth_m > 1.5, "side by side: the full width: {c:?}");
    assert!(c.disagreement_m < 0.01, "{c:?}");
    assert_eq!(RoomMetrics::get(&h.metrics.shadow_contacts), 1);
    assert_eq!(
        RoomMetrics::get(&h.metrics.shadow_contact_ticks),
        u64::from(c.ticks)
    );
    // Two players checked per tick since the horizon reached their runs.
    let pt = RoomMetrics::get(&h.metrics.shadow_player_ticks);
    assert!((170..=182).contains(&pt), "{pt}");
}

#[test]
fn players_in_neighbouring_lanes_never_touch() {
    let mut h = H::new();
    h.driver(1, 0, 1_000.0, 30.0, 1);
    h.driver(2, 0, 980.0, 40.0, 2);
    h.ticks(120);
    h.sc.shadow.flush(&h.metrics);
    assert!(h.sc.shadow.out.is_empty());
    assert_eq!(RoomMetrics::get(&h.metrics.shadow_contacts), 0);
}

/// A lane change into the other car during the contact: the views, extrapolated from
/// 100 ms before, miss the step: the disagreement is the step.
#[test]
fn a_lane_change_during_a_contact_is_a_disagreement() {
    let mut h = H::new();
    h.driver(1, 0, 1_000.0, 30.0, 1);
    let k = h.driver(2, 0, 990.0, 31.0, 2);
    // B's centre reaches A's after 10 s at 1 m/s closing; it steps into A's lane at 8 s,
    // 2 m behind A's centre (inside the hull length): an overlap from that tick.
    h.drivers[k].lane_change = Some((h.now + 160, LANE[1]));
    h.ticks(260);
    h.sc.shadow.flush(&h.metrics);
    let out = std::mem::take(&mut h.sc.shadow.out);
    assert_eq!(out.len(), 1, "{out:?}");
    let c = out[0];
    assert!((c.disagreement_m - 3.6).abs() < 0.05, "{c:?}");
    assert_eq!(h.metrics.shadow_disagreement()[5], 1, "the 2–4 m bucket");
}
