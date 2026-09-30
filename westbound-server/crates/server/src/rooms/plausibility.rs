//! Plausibility checks on reported `PlayerState`s (N5.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → Players ("Plausibility checks on the server: speed at or below the car's top speed × 1.1
//! (boost included); acceleration and lateral movement within 1.2× the car's capability; no
//! teleports (except server-approved respawns and rejoins). A violation marks the current
//! run unverified (it never reaches a leaderboard) and is logged."); "Accounts and
//! authentication → Security" (every inbound message is validated for ranges before it
//! reaches a room: the decoder already enforced the protocol's sanity bounds).
//!
//! Pure: a state, the previous accepted state, a pending placement and the room tick in; a
//! [`Verdict`] out. The client is authoritative for its own car, so an implausible state is
//! still relayed (clamped where a value is simply out of range: speed, lateral velocity,
//! `d` past the barriers), and the offence is counted and marks the run unverified. Only
//! states that cannot be ordered (duplicates, out of order, too old, stamped in the
//! future) or that were in flight before a server placement are dropped. Nobody is kicked
//! for an offence (the spec has no such rule).
//!
//! Every distance along the loop is the wrapped signed difference
//! ([`LoopMap::signed_delta_mm`]), so crossing the seam is not a teleport.

use protocol::{PlayerState, RunState};
use sim::map::LoopMap;

use super::road::{d_bounds_mm, MM_PER_CM};

/// cm/s per m/s (speed, lateral velocity).
const CMS_PER_MPS: f64 = 100.0;
/// mm per m.
const MM_PER_M: f64 = 1_000.0;
/// Two quantization steps (1 cm, 1 cm/s): the rate checks' own slack.
const QUANT_SLACK: f64 = 0.02;
/// N6.1: a state answers a pending placement only when it is the placed car: in
/// protection (`run_state = protected`, what a client sends once it applied a placement),
/// or at the placement's speed and lateral offset within these (plus what the car's
/// acceleration and lateral speed cover since the placement). A state sent before the
/// client applied it (driving on, or stopped after a crash) is in flight even when the
/// placement is near the car (a respawn "where the car is"): acknowledging it would make
/// the client's jump to the placement a teleport. Not in spec.
const PLACEMENT_SPEED_SLACK_MPS: f64 = 3.0;
const PLACEMENT_D_SLACK_M: f64 = 1.0;

/// A kind of implausible state (`wb_room_offences_total{kind}`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Offence {
    /// Speed above the fastest car's boosted top speed × 1.1 (clamped).
    Speed = 0,
    /// Forward acceleration above 1.2× the car's.
    Accel = 1,
    /// Lateral velocity or movement above 1.2× the car's (lateral velocity is clamped).
    Lateral = 2,
    /// `d` past the median barrier or the guardrail (clamped).
    Bounds = 3,
    /// A jump along the loop the speed cap cannot explain (or backwards), outside a
    /// server placement; or a placement never acknowledged.
    Teleport = 4,
    /// Farther along the loop than the reported speeds allow.
    Distance = 5,
    /// Stamped ahead of the room clock (dropped).
    Clock = 6,
}

impl Offence {
    pub const ALL: [Offence; 7] = [
        Offence::Speed,
        Offence::Accel,
        Offence::Lateral,
        Offence::Bounds,
        Offence::Teleport,
        Offence::Distance,
        Offence::Clock,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Offence::Speed => "speed",
            Offence::Accel => "accel",
            Offence::Lateral => "lateral",
            Offence::Bounds => "bounds",
            Offence::Teleport => "teleport",
            Offence::Distance => "distance",
            Offence::Clock => "clock",
        }
    }

    pub fn bit(self) -> u8 {
        1 << (self as u8)
    }
}

/// The limits, converted once from `[rooms]` (tolerances applied).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CheckLimits {
    pub tick_rate_hz: f64,
    /// Top speed with boost × the speed tolerance (m/s).
    pub speed_cap_mps: f64,
    /// Forward acceleration × the capability tolerance (m/s²).
    pub accel_cap_mps2: f64,
    /// Lateral speed × the capability tolerance (m/s).
    pub lateral_cap_mps: f64,
    /// Allowed overshoot of the lateral bounds (m).
    pub lateral_margin_m: f64,
    /// Slack on the distance checks (m).
    pub slack_m: f64,
    /// Ticks a state may be stamped ahead of the room clock.
    pub future_ticks: u32,
    /// Ticks a state may lag the room clock.
    pub stale_ticks: u32,
    /// A state within this of a placement (plus its reach at the speed cap) acknowledges it.
    pub placement_radius_m: f64,
}

impl CheckLimits {
    fn speed_cap_cms(&self) -> u16 {
        (self.speed_cap_mps * CMS_PER_MPS)
            .round()
            .clamp(0.0, f64::from(protocol::messages::MAX_SPEED_CMS)) as u16
    }
}

/// A server placement (spawn, respawn, rejoin, reconnect) waiting for the client to take it.
#[derive(Debug, Clone, PartialEq)]
pub struct Placement {
    /// The placed state (tick = the placement tick, `run_state` = protected).
    pub state: PlayerState,
    /// States far from the placement are dropped as in flight until this tick; after it the
    /// next state is taken with a teleport offence.
    pub deadline_tick: u32,
}

/// Why a state was not taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropReason {
    /// Its tick is not after the last accepted state's (a duplicate or reordered state).
    OutOfOrder,
    /// Too far behind the room clock.
    Stale,
    /// Stamped ahead of the room clock (an offence).
    Future,
    /// Sent before the client applied a server placement.
    InFlight,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// Take `state` (clamped). `offences` is a bit set of [`Offence`]s; `placed` says this
    /// state answered the pending placement (which ends).
    Accept {
        state: PlayerState,
        offences: u8,
        placed: bool,
    },
    Drop(DropReason),
}

/// `b - a` for wrapping u32 ticks.
pub fn tick_diff(a: u32, b: u32) -> i64 {
    i64::from(b.wrapping_sub(a) as i32)
}

fn mps(cms: f64) -> f64 {
    cms / CMS_PER_MPS
}

/// Checks `st` against the room clock (`now_tick`), the previous accepted state and a
/// pending placement.
pub fn check(
    lim: &CheckLimits,
    map: &LoopMap,
    prev: Option<&PlayerState>,
    placement: Option<&Placement>,
    st: &PlayerState,
    now_tick: u32,
) -> Verdict {
    let ahead = tick_diff(now_tick, st.tick);
    if ahead > i64::from(lim.future_ticks) {
        return Verdict::Drop(DropReason::Future);
    }
    if -ahead > i64::from(lim.stale_ticks) {
        return Verdict::Drop(DropReason::Stale);
    }
    if prev.is_some_and(|p| tick_diff(p.tick, st.tick) <= 0) {
        return Verdict::Drop(DropReason::OutOfOrder);
    }

    let mut out = st.clone();
    let mut offences = 0u8;
    // Absolute limits (clamped for the relay).
    let speed_cap = lim.speed_cap_cms();
    if out.speed_cms > speed_cap {
        offences |= Offence::Speed.bit();
        out.speed_cms = speed_cap;
    }
    let lat_cap = (lim.lateral_cap_mps * CMS_PER_MPS)
        .round()
        .clamp(0.0, f64::from(i16::MAX)) as i16;
    if out.lat_vel_cms.unsigned_abs() > lat_cap.unsigned_abs() {
        offences |= Offence::Lateral.bit();
        out.lat_vel_cms = out.lat_vel_cms.clamp(-lat_cap, lat_cap);
    }
    let (lo, hi) = d_bounds_mm(map, out.s_mm);
    let margin = (lim.lateral_margin_m * MM_PER_M) as i64;
    let (lo, hi) = (lo - margin, hi + margin);
    let d_mm = i64::from(out.d_cm) * MM_PER_CM;
    if d_mm < lo || d_mm > hi {
        offences |= Offence::Bounds.bit();
        let clamped = d_mm.clamp(lo, hi) / MM_PER_CM;
        out.d_cm = clamped.clamp(
            i64::from(-protocol::messages::MAX_ABS_D_CM),
            i64::from(protocol::messages::MAX_ABS_D_CM),
        ) as i16;
    }

    // Relative to a placement, or to the previous state.
    if let Some(p) = placement {
        let since = tick_diff(p.state.tick, out.tick);
        let reach =
            lim.placement_radius_m + lim.speed_cap_mps * (since.max(0) as f64) / lim.tick_rate_hz;
        let along = map.signed_delta_mm(p.state.s_mm, out.s_mm).abs() as f64 / MM_PER_M;
        let across = (i64::from(out.d_cm) - i64::from(p.state.d_cm)).abs() as f64 / CMS_PER_MPS;
        let since_s = since.max(0) as f64 / lim.tick_rate_hz;
        let dv = (f64::from(out.speed_cms) - f64::from(p.state.speed_cms)).abs() / CMS_PER_MPS;
        let placed_car = out.run_state == RunState::Protected
            || (dv <= lim.accel_cap_mps2 * since_s + PLACEMENT_SPEED_SLACK_MPS
                && across <= lim.lateral_cap_mps * since_s + PLACEMENT_D_SLACK_M);
        // A client whose clock estimate lags may stamp its first state a little before
        // the placement tick; the placed car near the placement answers it.
        if since >= -i64::from(lim.future_ticks) && along + across <= reach && placed_car {
            return Verdict::Accept {
                state: out,
                offences,
                placed: true,
            };
        }
        if tick_diff(now_tick, p.deadline_tick) > 0 {
            return Verdict::Drop(DropReason::InFlight);
        }
        return Verdict::Accept {
            state: out,
            offences: offences | Offence::Teleport.bit(),
            placed: true,
        };
    }
    if let Some(p) = prev {
        offences |= rate_offences(lim, map, p, &out);
    }
    Verdict::Accept {
        state: out,
        offences,
        placed: false,
    }
}

/// Teleport, distance, acceleration and lateral-movement checks between two accepted
/// states (`b` after `a`).
fn rate_offences(lim: &CheckLimits, map: &LoopMap, a: &PlayerState, b: &PlayerState) -> u8 {
    let dt = tick_diff(a.tick, b.tick) as f64 / lim.tick_rate_hz;
    if dt <= 0.0 {
        return 0;
    }
    let mut offences = 0u8;
    let ds = map.signed_delta_mm(a.s_mm, b.s_mm) as f64 / MM_PER_M;
    let (va, vb) = (mps(f64::from(a.speed_cms)), mps(f64::from(b.speed_cms)));
    if ds < -lim.slack_m || ds > lim.speed_cap_mps * dt + lim.slack_m {
        offences |= Offence::Teleport.bit();
    } else {
        // The fastest the car can have gone in between, from the reported speeds.
        let peak = va.max(vb) + lim.accel_cap_mps2 * dt * 0.5;
        if ds > peak * dt + lim.slack_m {
            offences |= Offence::Distance.bit();
        }
    }
    if (vb - va) / dt > lim.accel_cap_mps2 + QUANT_SLACK / dt {
        offences |= Offence::Accel.bit();
    }
    let dd = (f64::from(b.d_cm) - f64::from(a.d_cm)).abs() / CMS_PER_MPS;
    if dd / dt > lim.lateral_cap_mps + QUANT_SLACK / dt {
        offences |= Offence::Lateral.bit();
    }
    offences
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::RunState;

    fn map() -> std::sync::Arc<crate::map::ServerMap> {
        crate::map::builtin().expect("loop_v1")
    }

    fn lim() -> CheckLimits {
        CheckLimits {
            tick_rate_hz: 20.0,
            // 307.8 km/h × 1.1
            speed_cap_mps: 307.8 / 3.6 * 1.1,
            accel_cap_mps2: 12.0 * 1.2,
            lateral_cap_mps: 12.0 * 1.2,
            lateral_margin_m: 1.0,
            slack_m: 2.0,
            future_ticks: 10,
            stale_ticks: 40,
            placement_radius_m: 30.0,
        }
    }

    fn st(tick: u32, s_mm: u32, d_cm: i16, speed_cms: u16) -> PlayerState {
        PlayerState {
            tick,
            s_mm,
            d_cm,
            speed_cms,
            run_state: RunState::Driving,
            ..PlayerState::default()
        }
    }

    fn accept(v: Verdict) -> (PlayerState, u8) {
        match v {
            Verdict::Accept {
                state, offences, ..
            } => (state, offences),
            Verdict::Drop(r) => panic!("dropped: {r:?}"),
        }
    }

    #[test]
    fn honest_driving_passes_across_the_seam() {
        let m = map();
        let l = lim();
        // 70 m/s = 3.5 m per tick, in lane 1 (d = 7.1 m), across s = L.
        let mut prev = st(100, 24_998_000, 710, 7_000);
        for i in 1..=20u32 {
            let s = m.map.wrap_mm(24_998_000 + i64::from(i) * 3_500);
            let next = st(100 + i, s, 710, 7_000);
            let (_, off) = accept(check(&l, &m.map, Some(&prev), None, &next, 100 + i));
            assert_eq!(off, 0, "tick {i}: s {s}");
            prev = next;
        }
        assert!(prev.s_mm < 100_000, "crossed the seam");
    }

    #[test]
    fn speed_lateral_and_bounds_are_clamped_and_counted() {
        let m = map();
        let l = lim();
        let fast = st(10, 1_000_000, 710, 12_000); // 432 km/h
        let (s, off) = accept(check(&l, &m.map, None, None, &fast, 10));
        assert_eq!(off, Offence::Speed.bit());
        assert_eq!(s.speed_cms, 9_405, "clamped to 338.6 km/h");
        let mut sideways = st(10, 1_000_000, 710, 5_000);
        sideways.lat_vel_cms = -3_000;
        let (s, off) = accept(check(&l, &m.map, None, None, &sideways, 10));
        assert_eq!(off, Offence::Lateral.bit());
        assert_eq!(s.lat_vel_cms, -1_440);
        // Past the guardrail (19.6 m at 1 km, 4 lanes) + 1 m margin.
        let out = st(10, 1_000_000, 2_500, 5_000);
        let (s, off) = accept(check(&l, &m.map, None, None, &out, 10));
        assert_eq!(off, Offence::Bounds.bit());
        assert_eq!(s.d_cm, 2_060);
        // The opposite carriageway: behind the median barrier.
        let (s, off) = accept(check(&l, &m.map, None, None, &st(10, 0, -300, 0), 10));
        assert_eq!(off, Offence::Bounds.bit());
        assert_eq!(s.d_cm, -50);
        // On the shoulder is fine.
        let (_, off) = accept(check(&l, &m.map, None, None, &st(10, 0, 1_500, 0), 10));
        assert_eq!(off, 0);
    }

    #[test]
    fn teleports_accel_and_lateral_moves() {
        let m = map();
        let l = lim();
        let a = st(100, 5_000_000, 710, 5_000);
        // 1 km in one tick.
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 6_000_000, 710, 5_000),
            101,
        ));
        assert_eq!(off, Offence::Teleport.bit());
        // Backwards.
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 4_990_000, 710, 5_000),
            101,
        ));
        assert_eq!(off, Offence::Teleport.bit());
    }

    #[test]
    fn distance_accel_lateral() {
        let m = map();
        let l = lim();
        // Reports 20 m/s but moves 4.6 m per tick (92 m/s): within the teleport bound
        // (4.7 + 2 m) but not the speeds' (1 m + 2 m).
        let a = st(100, 5_000_000, 710, 2_000);
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 5_004_600, 710, 2_000),
            101,
        ));
        assert_eq!(off, Offence::Distance.bit());
        // +2 m/s in one tick = 40 m/s².
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 5_001_000, 710, 2_200),
            101,
        ));
        assert_eq!(off, Offence::Accel.bit());
        // Braking hard (a hit) is fine.
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 5_001_000, 710, 0),
            101,
        ));
        assert_eq!(off, 0);
        // 1 m sideways in a tick = 20 m/s.
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 5_001_000, 810, 2_000),
            101,
        ));
        assert_eq!(off, Offence::Lateral.bit());
        // A lane change pace (0.4 m per tick = 8 m/s) is fine.
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&a),
            None,
            &st(101, 5_001_000, 750, 2_000),
            101,
        ));
        assert_eq!(off, 0);
    }

    #[test]
    fn ordering_and_the_clock() {
        let m = map();
        let l = lim();
        let a = st(100, 5_000_000, 710, 2_000);
        assert_eq!(
            check(&l, &m.map, Some(&a), None, &a.clone(), 101),
            Verdict::Drop(DropReason::OutOfOrder)
        );
        assert_eq!(
            check(
                &l,
                &m.map,
                Some(&a),
                None,
                &st(99, 5_000_000, 710, 2_000),
                101
            ),
            Verdict::Drop(DropReason::OutOfOrder)
        );
        assert_eq!(
            check(&l, &m.map, None, None, &st(111, 5_000_000, 710, 2_000), 100),
            Verdict::Drop(DropReason::Future)
        );
        assert_eq!(
            check(&l, &m.map, None, None, &st(59, 5_000_000, 710, 2_000), 100),
            Verdict::Drop(DropReason::Stale)
        );
        // Ten ticks ahead is still fine; ticks wrap like the wire's u32.
        let (_, off) = accept(check(&l, &m.map, None, None, &st(110, 0, 710, 0), 100));
        assert_eq!(off, 0);
        let (_, off) = accept(check(
            &l,
            &m.map,
            Some(&st(u32::MAX, 0, 710, 0)),
            None,
            &st(0, 3, 710, 0),
            1,
        ));
        assert_eq!(off, 0);
    }

    #[test]
    fn placements() {
        let m = map();
        let l = lim();
        let mut placed = st(200, 1_000_000, 350, 4_000);
        placed.run_state = RunState::Protected;
        let p = Placement {
            state: placed,
            deadline_tick: 240,
        };
        let old = st(150, 9_000_000, 710, 4_000);
        // In flight from the old position: dropped until the deadline, no offence.
        assert_eq!(
            check(
                &l,
                &m.map,
                Some(&old),
                Some(&p),
                &st(201, 9_000_200, 710, 4_000),
                205
            ),
            Verdict::Drop(DropReason::InFlight)
        );
        // Near the placement: taken, no teleport against the old position.
        match check(
            &l,
            &m.map,
            Some(&old),
            Some(&p),
            &st(203, 1_000_600, 350, 4_000),
            205,
        ) {
            Verdict::Accept {
                offences, placed, ..
            } => assert_eq!((offences, placed), (0, true)),
            v => panic!("{v:?}"),
        }
        // N6.1: near the placement but not the placed car (sent before the client applied
        // it: stopped after a crash, or on another lane at another speed): in flight...
        let mut crashed = st(202, 1_000_300, 350, 0);
        crashed.run_state = RunState::Crashed;
        assert_eq!(
            check(&l, &m.map, Some(&old), Some(&p), &crashed, 205),
            Verdict::Drop(DropReason::InFlight)
        );
        assert_eq!(
            check(
                &l,
                &m.map,
                Some(&old),
                Some(&p),
                &st(202, 1_000_300, 710, 2_000),
                205
            ),
            Verdict::Drop(DropReason::InFlight)
        );
        // ...while the placed car answers it in protection wherever it steered since.
        let mut protected = st(204, 1_000_500, 900, 3_000);
        protected.run_state = RunState::Protected;
        assert!(matches!(
            check(&l, &m.map, Some(&old), Some(&p), &protected, 205),
            Verdict::Accept { placed: true, .. }
        ));
        // After the deadline, a far state is taken as a teleport and ends the placement.
        match check(
            &l,
            &m.map,
            Some(&old),
            Some(&p),
            &st(241, 9_001_000, 710, 4_000),
            241,
        ) {
            Verdict::Accept {
                offences, placed, ..
            } => assert_eq!((offences, placed), (Offence::Teleport.bit(), true)),
            v => panic!("{v:?}"),
        }
    }
}
