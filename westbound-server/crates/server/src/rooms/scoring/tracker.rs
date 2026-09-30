//! The server's own view of one player's passes and contacts (N6.1): every accepted
//! `PlayerState` is paired with the room's traffic at the state's tick
//! ([`CarHistory`](crate::rooms::car_history::CarHistory)) and run through the client's
//! pass rule (`scoring.gd`: a car fully ahead enters the longitudinal overlap window and
//! leaves it fully behind; the centres crossing gives the side and time; the minimum
//! hull-to-hull clearance over the window), and through the hit cross-check (spec: "The
//! server also detects contact from reported positions (overlap deeper than 0.3 m for 2
//! or more ticks)"). Claims are then matched against what this saw.
//!
//! Only cars near the player are tracked (from `track_ahead_m` ahead to a few metres
//! past the overlap window behind), in a fixed table; the observations go into rings.
//! Nothing allocates per state.

use sim::map::LoopMap;
use sim::scoring::hull;
use sim::scoring::rules::{PHASE_AHEAD, PHASE_NONE, PHASE_OVERLAP};

use super::ring::Ring;
use crate::rooms::car_history::CarSample;

const MM_PER_M: f64 = 1_000.0;
/// Cars more than this far behind the overlap window are not tracked (a car passed at up
/// to 200 m/s relative still completes within it at 20 Hz).
const BEHIND_MARGIN_M: f64 = 10.0;
/// A first cut on the distance before anything else (m past `ahead_m`; longer than any
/// vehicle's overlap window behind).
const NEAR_SCAN_M: f64 = 40.0;
/// Cars tracked at once (rush hour has ~30 within the window).
pub const MAX_TRACKS: usize = 64;
/// Observed passes, contacts and near misses remembered (seconds of play).
pub const PASS_RING: usize = 64;
pub const CONTACT_RING: usize = 16;
pub const NEAR_RING: usize = 128;

/// One accepted player state, as scoring uses it.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct StateRec {
    pub tick: u32,
    pub s_mm: u32,
    /// m, + right of travel.
    pub d: f64,
    /// Forward speed (m/s).
    pub v: f64,
    /// Heading relative to the road (rad).
    pub yaw: f64,
    pub boost: bool,
    /// Spawn / rejoin protection (no traffic hits).
    pub protected: bool,
    /// A placement or a teleport: no continuity with the state before.
    pub reset: bool,
}

/// What the tracker measures with (converted once).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrackRules {
    /// The player's hull half-length and half-width (inset).
    pub p_hl: f64,
    pub p_hw: f64,
    /// The hull inset applied to traffic bodies.
    pub inset: f64,
    pub ahead_m: f64,
    /// A contact: penetration deeper than this for `overlap_ticks` states in a row.
    pub overlap_m: f64,
    pub overlap_ticks: u32,
    /// Near misses closer than this are remembered (a reported hit's confirmation).
    pub confirm_m: f64,
}

#[derive(Debug, Clone, Copy, Default)]
struct Track {
    car_id: u16,
    stamp: u32,
    phase: i32,
    crossed: bool,
    min_clear: f64,
    cross_tick: u32,
    cross_dd: f64,
    /// States in a row with a deep overlap.
    deep: u32,
}

/// A pass the server saw.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ObservedPass {
    pub car_id: u16,
    /// The state tick the centres crossed.
    pub cross_tick: u32,
    /// The state tick the car was fully behind (the client pays the pass then).
    pub done_tick: u32,
    /// Minimum hull-to-hull clearance over the overlap window (m).
    pub min_clear: f64,
    /// Car d − player d when the centres crossed (+: the car was on the right).
    pub cross_dd: f64,
    /// Matched by an accepted pass / close-pass claim, or by a thread claim.
    pub claimed: bool,
    pub threaded: bool,
}

/// A server-detected contact (the hit cross-check).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Contact {
    pub car_id: u16,
    pub tick: u32,
    pub resolved: bool,
}

/// A car within `confirm_m` of the player at a tick.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Near {
    pub car_id: u16,
    pub tick: u32,
    pub clearance: f64,
}

#[derive(Debug, Clone)]
pub struct Tracker {
    rules: TrackRules,
    tracks: Vec<Track>,
    stamp: u32,
    pub passes: Ring<ObservedPass>,
    pub contacts: Ring<Contact>,
    pub near: Ring<Near>,
    /// The last state tick processed.
    pub processed: Option<u32>,
}

impl Tracker {
    pub fn new(rules: TrackRules) -> Self {
        Self {
            rules,
            tracks: Vec::with_capacity(MAX_TRACKS),
            stamp: 0,
            passes: Ring::new(PASS_RING),
            contacts: Ring::new(CONTACT_RING),
            near: Ring::new(NEAR_RING),
            processed: None,
        }
    }

    /// A new run: nothing carried over.
    pub fn reset(&mut self) {
        self.tracks.clear();
        self.passes.clear();
        self.contacts.clear();
        self.near.clear();
        self.processed = None;
    }

    /// A state with no traffic to pair it with (too old for the history): it still
    /// counts as processed, but nothing in progress survives the gap.
    pub fn skip(&mut self, tick: u32) {
        self.tracks.clear();
        self.processed = Some(tick);
    }

    /// One state against the traffic at its tick.
    pub fn process(&mut self, st: &StateRec, cars: &[CarSample], map: &LoopMap) {
        if st.reset {
            self.tracks.clear();
        }
        self.stamp = self.stamp.wrapping_add(1);
        let r = self.rules;
        let len = i64::from(map.length_mm());
        let (half, near_mm) = (len / 2, ((r.ahead_m + NEAR_SCAN_M) * MM_PER_M) as i64);
        for c in cars {
            // The wrapped signed difference without a division (s in [0, L) on both
            // sides), and most of the ring skipped on it.
            let mut dmm = i64::from(c.s_mm) - i64::from(st.s_mm);
            if dmm >= half {
                dmm -= len;
            } else if dmm < -half {
                dmm += len;
            }
            if dmm.abs() > near_mm {
                continue;
            }
            let ds = dmm as f64 / MM_PER_M;
            let c_hl = f64::from(c.length) * 0.5 - r.inset;
            let c_hw = f64::from(c.width) * 0.5 - r.inset;
            let hl_sum = c_hl + r.p_hl;
            if ds > r.ahead_m || ds < -hl_sum - BEHIND_MARGIN_M {
                continue;
            }
            let k = match self.tracks.iter().position(|t| t.car_id == c.car_id) {
                Some(k) => k,
                None if self.tracks.len() < MAX_TRACKS => {
                    self.tracks.push(Track {
                        car_id: c.car_id,
                        phase: if ds >= hl_sum {
                            PHASE_AHEAD
                        } else {
                            PHASE_NONE
                        },
                        min_clear: f64::INFINITY,
                        ..Track::default()
                    });
                    self.tracks.len() - 1
                }
                None => continue,
            };
            let stamp = self.stamp;
            let t = &mut self.tracks[k];
            t.stamp = stamp;
            let clearance = || {
                hull::clearance(
                    0.0,
                    st.d,
                    st.yaw,
                    r.p_hl,
                    r.p_hw,
                    ds,
                    f64::from(c.d),
                    c.yaw(),
                    c_hl,
                    c_hw,
                )
            };
            let mut clr = f64::NAN;
            if ds.abs() < hl_sum {
                clr = clearance();
                if clr <= r.confirm_m {
                    self.near.push(Near {
                        car_id: c.car_id,
                        tick: st.tick,
                        clearance: clr,
                    });
                }
                let deep = clr <= 0.0
                    && hull::penetration(
                        0.0,
                        st.d,
                        st.yaw,
                        r.p_hl,
                        r.p_hw,
                        ds,
                        f64::from(c.d),
                        c.yaw(),
                        c_hl,
                        c_hw,
                    ) > r.overlap_m;
                if deep {
                    t.deep += 1;
                    if t.deep == r.overlap_ticks {
                        self.contacts.push(Contact {
                            car_id: c.car_id,
                            tick: st.tick,
                            resolved: false,
                        });
                    }
                } else {
                    t.deep = 0;
                }
            } else {
                t.deep = 0;
            }
            // The client's pass rule (Scoring.step).
            let mut ph = t.phase;
            if ph == PHASE_AHEAD && ds < hl_sum {
                ph = PHASE_OVERLAP;
                t.min_clear = f64::INFINITY;
                t.crossed = false;
            }
            if ph == PHASE_OVERLAP {
                if clr.is_nan() {
                    clr = clearance();
                }
                t.min_clear = t.min_clear.min(clr);
                if ds <= 0.0 {
                    if !t.crossed {
                        t.crossed = true;
                        t.cross_tick = st.tick;
                        t.cross_dd = f64::from(c.d) - st.d;
                    }
                } else {
                    t.crossed = false;
                }
                if ds >= hl_sum {
                    ph = PHASE_AHEAD;
                } else if ds <= -hl_sum {
                    ph = PHASE_NONE;
                    self.passes.push(ObservedPass {
                        car_id: c.car_id,
                        cross_tick: t.cross_tick,
                        done_tick: st.tick,
                        min_clear: t.min_clear,
                        cross_dd: t.cross_dd,
                        claimed: false,
                        threaded: false,
                    });
                }
            } else if ph == PHASE_NONE && ds >= hl_sum {
                ph = PHASE_AHEAD;
            }
            self.tracks[k].phase = ph;
        }
        let stamp = self.stamp;
        self.tracks.retain(|t| t.stamp == stamp);
        self.processed = Some(st.tick);
    }

    /// Cars in the pass table (tests, diagnostics).
    pub fn tracked(&self) -> usize {
        self.tracks.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules() -> TrackRules {
        TrackRules {
            p_hl: 2.25 - 0.08,
            p_hw: 0.95 - 0.08,
            inset: 0.08,
            ahead_m: 60.0,
            overlap_m: 0.3,
            overlap_ticks: 2,
            confirm_m: 1.0,
        }
    }

    fn car(id: u16, s_mm: u32, d: f32) -> CarSample {
        CarSample {
            car_id: id,
            lane: 1,
            s_mm,
            d,
            v: 25.0,
            v_lat: 0.0,
            length: 4.5,
            width: 1.8,
        }
    }

    #[test]
    fn sees_a_pass_its_side_clearance_and_ticks() {
        let map = crate::map::builtin().expect("loop_v1");
        let mut t = Tracker::new(rules());
        // The player at 35 m/s, a car at 25 m/s in the lane to the right (3.6 m over),
        // starting 20 m ahead: 10 m/s closing, 0.5 m per tick.
        let (p_d, c_d) = (5.3, 8.9f32);
        for k in 0..120u32 {
            let p_s = 1_000_000 + k * 1_750;
            let c_s = 1_020_000 + k * 1_250;
            let st = StateRec {
                tick: 500 + k,
                s_mm: p_s,
                d: p_d,
                v: 35.0,
                ..StateRec::default()
            };
            t.process(&st, &[car(7, c_s, c_d)], &map.map);
        }
        assert_eq!(t.passes.len(), 1);
        let p = *t.passes.get(0).unwrap();
        assert_eq!(p.car_id, 7);
        assert_eq!(p.cross_tick, 540, "centres level after 20 m / 0.5 m");
        assert!(p.done_tick > p.cross_tick);
        assert!(p.cross_dd > 3.5);
        // 3.6 m − (0.87 + 0.82) = 1.91 m.
        assert!((p.min_clear - 1.91).abs() < 1e-3, "{}", p.min_clear);
        assert!(t.contacts.is_empty());
        assert!(t.tracked() <= 1);
    }

    #[test]
    fn a_deep_overlap_for_two_states_is_a_contact() {
        let map = crate::map::builtin().expect("loop_v1");
        let mut t = Tracker::new(rules());
        for k in 0..4u32 {
            let st = StateRec {
                tick: 10 + k,
                s_mm: 2_000_000,
                d: 5.3,
                v: 30.0,
                ..StateRec::default()
            };
            // Beside the player, 1.2 m apart centre to centre: 0.49 m deep.
            t.process(&st, &[car(3, 2_000_500, 6.5)], &map.map);
        }
        assert_eq!(
            t.contacts.len(),
            1,
            "one contact per overlap, at its second state"
        );
        assert_eq!(t.contacts.get(0).unwrap().tick, 11);
        assert!(t.near.len() >= 4);
        // A car first seen beside the player is no pass.
        assert!(t.passes.is_empty());
    }
}
