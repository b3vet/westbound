//! Shadow collision logging between players (N10.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → Players ("Shadow collision logging (preparing for a later decision)": for every pair
//! of players, each moment their collision boxes would have overlapped, using both reported
//! states at the same tick; an estimate of how much the two players' views disagreed then;
//! aggregates in the admin stats), Data model (`shadow_contacts`), Future: soft-solid
//! player collisions.
//!
//! Players are ghosted in v1, so nothing here changes play. Every room tick, the tick at
//! the official timeline's horizon (`official_lag_ms` behind the room: every state of it
//! has arrived) is checked: each pair of players with a run in progress, their reported
//! states at that tick (interpolated between the neighbouring ticks when a state is
//! missing), the player hull (`scoring.player_length_m` × `player_width_m`, inset), the
//! separating-axis depth. A **contact** runs from the first overlapping tick to the last;
//! when it ends it goes out as one [`ShadowContact`] (the room logs a sample of them and
//! hands every one to the shadow sink: `shadow_contacts` in SQLite).
//!
//! **Disagreement** (the soft-solid proposal resolves contact "against remote players'
//! extrapolated positions"): each player sees the other as the other's state
//! `shadow_view_delay_ms` earlier (the relay's age; the spec's interpolation delay, 100 ms)
//! carried on to the contact tick at its reported forward and lateral speeds. The two
//! views of the pair's relative position then differ by `|e_a + e_b|`, where `e` is each
//! car's extrapolation error; the contact keeps its largest value. Straight driving
//! disagrees by centimetres, a lane change or a brake during the contact by metres.
//!
//! Nothing allocates per tick: the buffers are sized for a full room when the room starts.

use protocol::messages::MAX_ROOM_PLAYERS;
use sim::scoring::hull;

use super::tracker::StateRec;
use super::PlayerScore;
use crate::rooms::metrics::RoomMetrics;
use crate::rooms::plausibility::tick_diff;

const MM_PER_M: f64 = 1_000.0;
/// Ticks of states a missing one may be interpolated across.
const GAP_TICKS: i64 = 2;
/// At most this many ticks are checked per room tick (a stalled room skips ahead).
const MAX_CATCHUP: u32 = 40;

/// What the shadow check measures with.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShadowRules {
    /// The views' age (ticks): `scoring.shadow_view_delay_ms`.
    pub view_ticks: u32,
    /// The player hull's half length and width (inset), as the hit cross-check's.
    pub p_hl: f64,
    pub p_hw: f64,
    pub tick_dt: f64,
}

/// One contact between two players (their boxes overlapped on consecutive ticks).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ShadowContact {
    pub player_a: u16,
    pub player_b: u16,
    /// The first overlapping tick and how many ticks the contact lasted.
    pub tick: u32,
    pub ticks: u32,
    /// Deepest overlap (m).
    pub depth_m: f64,
    /// The pair's mean forward speed at the first tick (m/s), and the largest difference
    /// of their speeds over the contact (m/s).
    pub speed_mps: f64,
    pub closing_mps: f64,
    /// Largest disagreement of the two views (m; see the module docs).
    pub disagreement_m: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Sample {
    player_id: u16,
    s_m: f64,
    d: f64,
    v: f64,
    v_lat: f64,
    yaw: f64,
}

/// The pairs of one room.
#[derive(Debug)]
pub struct Shadow {
    rules: ShadowRules,
    loop_len_mm: u32,
    /// The next tick to check.
    next: Option<u32>,
    samples: Vec<Sample>,
    /// (sample now, sample `view_ticks` earlier) per player this tick.
    prev: Vec<Option<Sample>>,
    open: Vec<(ShadowContact, u32)>,
    /// Finished contacts (the room drains them).
    pub out: Vec<ShadowContact>,
}

impl Shadow {
    pub fn new(rules: ShadowRules, loop_len_mm: u32) -> Self {
        let n = usize::from(MAX_ROOM_PLAYERS);
        let pairs = n * (n - 1) / 2;
        Self {
            rules,
            loop_len_mm: loop_len_mm.max(1),
            next: None,
            samples: Vec::with_capacity(n),
            prev: Vec::with_capacity(n),
            open: Vec::with_capacity(pairs),
            out: Vec::with_capacity(pairs),
        }
    }

    fn delta_m(&self, a: f64, b: f64) -> f64 {
        let l = f64::from(self.loop_len_mm) / MM_PER_M;
        (b - a + l * 0.5).rem_euclid(l) - l * 0.5
    }

    /// Checks every tick up to `horizon`.
    pub(super) fn tick(&mut self, players: &[PlayerScore], horizon: u32, metrics: &RoomMetrics) {
        let mut t = match self.next {
            Some(t) if tick_diff(t, horizon) >= 0 => {
                if tick_diff(t, horizon) > i64::from(MAX_CATCHUP) {
                    horizon.wrapping_sub(MAX_CATCHUP)
                } else {
                    t
                }
            }
            Some(_) => return,
            None => horizon,
        };
        loop {
            self.check(players, t, metrics);
            if t == horizon {
                break;
            }
            t = t.wrapping_add(1);
        }
        self.next = Some(horizon.wrapping_add(1));
    }

    /// Ends every open contact (the room closes, or a test wants them).
    pub fn flush(&mut self, metrics: &RoomMetrics) {
        while let Some((c, _)) = self.open.pop() {
            self.finish(c, metrics);
        }
    }

    fn finish(&mut self, c: ShadowContact, metrics: &RoomMetrics) {
        metrics.observe_shadow_contact(c.ticks, c.speed_mps, c.disagreement_m);
        if self.out.len() < self.out.capacity() {
            self.out.push(c);
        }
    }

    fn check(&mut self, players: &[PlayerScore], t: u32, metrics: &RoomMetrics) {
        self.samples.clear();
        self.prev.clear();
        let back = t.wrapping_sub(self.rules.view_ticks);
        let loop_m = f64::from(self.loop_len_mm) / MM_PER_M;
        for p in players {
            if !p.official.active || tick_diff(p.official.start_tick, t) < 0 {
                continue;
            }
            let Some(s) = sample(p, t, loop_m) else {
                continue;
            };
            self.samples.push(s);
            self.prev.push(sample(p, back, loop_m));
        }
        RoomMetrics::add(&metrics.shadow_player_ticks, self.samples.len() as u64);
        let (hl, hw) = (self.rules.p_hl, self.rules.p_hw);
        let reach = 2.0 * (hl + hw);
        let view_s = f64::from(self.rules.view_ticks) * self.rules.tick_dt;
        for i in 0..self.samples.len() {
            for j in i + 1..self.samples.len() {
                let (a, b) = (self.samples[i], self.samples[j]);
                let ds = self.delta_m(a.s_m, b.s_m);
                if ds.abs() > reach {
                    continue;
                }
                let depth = hull::penetration(0.0, a.d, a.yaw, hl, hw, ds, b.d, b.yaw, hl, hw);
                if depth <= 0.0 {
                    continue;
                }
                RoomMetrics::inc(&metrics.shadow_contact_ticks);
                // Each car's extrapolation error from its state a view's age ago.
                let err = |now: &Sample, then: Option<Sample>| match then {
                    Some(p) => (
                        self.delta_m(p.s_m + p.v * view_s, now.s_m),
                        now.d - (p.d + p.v_lat * view_s),
                    ),
                    None => (0.0, 0.0),
                };
                let (ea, eb) = (err(&a, self.prev[i]), err(&b, self.prev[j]));
                let disagreement = (ea.0 + eb.0).hypot(ea.1 + eb.1);
                let closing = (a.v - b.v).abs();
                let (lo, hi) = if a.player_id < b.player_id {
                    (a.player_id, b.player_id)
                } else {
                    (b.player_id, a.player_id)
                };
                match self
                    .open
                    .iter_mut()
                    .find(|(c, _)| c.player_a == lo && c.player_b == hi)
                {
                    Some((c, last)) => {
                        c.ticks += 1;
                        c.depth_m = c.depth_m.max(depth);
                        c.closing_mps = c.closing_mps.max(closing);
                        c.disagreement_m = c.disagreement_m.max(disagreement);
                        *last = t;
                    }
                    None => {
                        if self.open.len() < self.open.capacity() {
                            self.open.push((
                                ShadowContact {
                                    player_a: lo,
                                    player_b: hi,
                                    tick: t,
                                    ticks: 1,
                                    depth_m: depth,
                                    speed_mps: (a.v + b.v) * 0.5,
                                    closing_mps: closing,
                                    disagreement_m: disagreement,
                                },
                                t,
                            ));
                        }
                    }
                }
            }
        }
        // Contacts that did not go on at this tick are over.
        let mut k = 0;
        while k < self.open.len() {
            if self.open[k].1 != t {
                let (c, _) = self.open.swap_remove(k);
                self.finish(c, metrics);
            } else {
                k += 1;
            }
        }
    }
}

/// Player `p`'s reported car at tick `t`: its state there, or interpolated between the
/// states around it (at most `GAP_TICKS` apart on each side), none across a placement.
fn sample(p: &PlayerScore, t: u32, loop_m: f64) -> Option<Sample> {
    let mut after: Option<&StateRec> = None;
    for st in p.states.iter().rev() {
        let dt = tick_diff(t, st.tick);
        if dt == 0 {
            return Some(of(p.player_id, st));
        }
        if dt > 0 {
            if dt <= GAP_TICKS {
                after = Some(st);
            }
            continue;
        }
        // st is before t.
        if -dt > GAP_TICKS {
            return None;
        }
        let a = after?;
        if a.reset {
            return None;
        }
        let span = tick_diff(st.tick, a.tick) as f64;
        let u = (-dt) as f64 / span;
        let (x, y) = (of(p.player_id, st), of(p.player_id, a));
        // Across the seam: s is wrapped on the loop.
        let ds = (y.s_m - x.s_m + loop_m * 0.5).rem_euclid(loop_m) - loop_m * 0.5;
        return Some(Sample {
            player_id: p.player_id,
            s_m: (x.s_m + ds * u).rem_euclid(loop_m),
            d: x.d + (y.d - x.d) * u,
            v: x.v + (y.v - x.v) * u,
            v_lat: x.v_lat + (y.v_lat - x.v_lat) * u,
            yaw: x.yaw + (y.yaw - x.yaw) * u,
        });
    }
    None
}

fn of(player_id: u16, st: &StateRec) -> Sample {
    Sample {
        player_id,
        s_m: f64::from(st.s_mm) / MM_PER_M,
        d: st.d,
        v: st.v,
        v_lat: st.v_lat,
        yaw: st.yaw,
    }
}
