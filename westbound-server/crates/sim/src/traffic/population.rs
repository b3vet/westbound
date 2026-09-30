//! The room's traffic population (multiplayer handoff → Server simulation: "the ring is
//! kept at the room's density through the ramps. Normal density is 10 vehicles per km per
//! lane, about 800 cars. Light is 6 and rush hour is 14"; The loop map: "two on-ramp /
//! off-ramp pairs where traffic enters and leaves, so traffic doesn't feel like a closed
//! conveyor belt").
//!
//! - **The mix** is the client's (`SpawnSources.Flow.draw_into`, ported as [`Population::draw`]):
//!   per lane, the profiles that fit its flow speed, the aggressive and racer shares of the
//!   loop's director leg, keep-right and fast-lane rules, v0 in the lane's band with the
//!   per-car jitter, a type from the profile's list, a colour from the section's palette.
//! - **Fill:** a new room starts with the ring at its density (lane by lane, spacing
//!   1000 / (density x section share) jittered, never closer than IDM's s* with the closing
//!   speed, nothing in a lane that closes soon).
//! - **Upkeep:** off-ramps take a share of the rightmost lane's cars (more when the ring is
//!   above its target, none below); on-ramps add a car whenever the ring is below it. An
//!   exit is a telegraphed move into the off-ramp lane (`TrafficSim::try_exit`); an entry
//!   is a car on the on-ramp lane, which is closed at the ramp's end, so the car merges
//!   like at a lane drop (WP6.8: long zone, zipper, own-advantage merging).
//!
//! Allocation-free per tick (vectors sized at construction).

use super::gd::{clampf, maxf};
use super::idm;
use super::params::{Density, FillRules, MpTrafficRules, RampRules, TrafficParams};
use super::sim::{EventTag, SpawnRecord, TrafficSim, RAMP_CLOSURE_TAG, ZONE_CLOSURE_TAG_BASE};
use super::state::{FLAG_HIT, FLAG_SCRIPTED, LC_NONE};
use crate::rng::Rng;

/// Density sampling step for the target count (m).
const TARGET_STEP_M: f64 = 10.0;
const M_PER_KM: f64 = 1000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PopulationStats {
    pub filled: u64,
    pub ramp_spawns: u64,
    pub ramp_spawn_blocked: u64,
    pub exit_rolls: u64,
    pub exits_started: u64,
}

pub struct Population {
    rng: Rng,
    density: Density,
    densities: [f64; 3],
    target: usize,
    ramp: RampRules,
    fill: FillRules,
    // Mix (Flow)
    n_profiles: usize,
    p_weight: Vec<f64>,
    p_vmin: Vec<f64>,
    p_vmax: Vec<f64>,
    p_min_leg: Vec<i32>,
    p_keep_right: Vec<u8>,
    p_left_lanes: Vec<i32>,
    p_types: Vec<Vec<i32>>,
    p_a: Vec<f64>,
    p_b: Vec<f64>,
    p_s0: Vec<f64>,
    /// IDM T x the loop leg's headway scale.
    p_t: Vec<f64>,
    t_len: Vec<f64>,
    t_variants: Vec<i32>,
    aggressive: i32,
    racer: i32,
    hesitant: i32,
    leg: i32,
    agg_share: f64,
    racer_share: f64,
    hesitant_allowed: bool,
    headway_scale: f64,
    tolerance: f64,
    keep_right_spawn: i32,
    jitter: f64,
    palette: Vec<i32>,
    section_frac: Vec<f64>,
    merge_spawn_clear: f64,
    w: Vec<f64>,
    // Ramps
    on_ramps: Vec<(f64, f64)>,
    off_ramps: Vec<(f64, f64)>,
    on_timer: Vec<f64>,
    /// Per slot: the ramp pass this vehicle rolled for (vehicle id, ramp) and whether it
    /// wants out.
    rolled_vid: Vec<i32>,
    rolled_ramp: Vec<i32>,
    wants_exit: Vec<u8>,
    pub stats: PopulationStats,
}

impl Population {
    /// A population for `sim`'s road at `density`. `rng` is its own stream (derive it from
    /// the room's traffic stream). Call [`Population::install`] once, then
    /// [`Population::fill`].
    pub fn new(
        params: &TrafficParams,
        mp: &MpTrafficRules,
        sim: &TrafficSim,
        density: Density,
        rng: Rng,
    ) -> Self {
        let t = &params.tuning;
        let lt = &params.loop_traffic;
        let pr = &params.profiles;
        let np = pr.len();
        let road = &sim.road;
        let mut on_ramps = Vec::new();
        let mut off_ramps = Vec::new();
        for r in &road.ramps {
            if r.on {
                on_ramps.push((r.s, r.length));
            } else {
                off_ramps.push((r.s, r.length));
            }
        }
        let cap = sim.state.capacity;
        let d = &mp.density_per_km_lane;
        let mut pop = Population {
            rng,
            density,
            densities: [d.light, d.normal, d.rush],
            target: 0,
            ramp: mp.ramps.clone(),
            fill: mp.fill.clone(),
            n_profiles: np,
            p_weight: pr.iter().map(|p| p.spawn_weight).collect(),
            p_vmin: pr.iter().map(|p| p.v0_min_mps).collect(),
            p_vmax: pr.iter().map(|p| p.v0_max_mps).collect(),
            p_min_leg: pr.iter().map(|p| p.min_leg).collect(),
            p_keep_right: pr.iter().map(|p| u8::from(p.keep_right)).collect(),
            p_left_lanes: pr.iter().map(|p| p.spawn_left_lane_count).collect(),
            p_types: params.spawn.types_for_profile.clone(),
            p_a: pr.iter().map(|p| p.a_max_mps2).collect(),
            p_b: pr.iter().map(|p| p.b_comfort_mps2).collect(),
            p_s0: pr.iter().map(|p| p.s0_m).collect(),
            p_t: pr.iter().map(|p| p.headway_s * lt.headway_scale).collect(),
            t_len: params.types.iter().map(|x| x.length_m).collect(),
            t_variants: params
                .types
                .iter()
                .map(|x| x.model_variants.max(1))
                .collect(),
            aggressive: params.spawn.aggressive_profile,
            racer: params.spawn.racer_profile,
            hesitant: params.spawn.hesitant_profile,
            leg: lt.director_leg,
            agg_share: lt.aggressive_share_frac,
            racer_share: lt.racer_share_frac,
            hesitant_allowed: lt.hesitant_allowed,
            headway_scale: lt.headway_scale,
            tolerance: t.spawn_lane_speed_tolerance_mps,
            keep_right_spawn: t.spawn_keep_right_lane_count,
            jitter: t.spawn_v0_jitter_frac,
            palette: lt.palette_counts.iter().map(|c| (*c).max(1)).collect(),
            section_frac: lt.section_density_frac.clone(),
            merge_spawn_clear: t.merge_spawn_clear_m,
            w: vec![0.0; np],
            on_timer: vec![0.0; on_ramps.len()],
            on_ramps,
            off_ramps,
            rolled_vid: vec![0; cap],
            rolled_ramp: vec![-1; cap],
            wants_exit: vec![0; cap],
            stats: PopulationStats::default(),
        };
        pop.target = pop.target_for(sim, density);
        pop
    }

    pub fn density(&self) -> Density {
        self.density
    }

    /// Changes the room's density; the ramps move the ring to it.
    pub fn set_density(&mut self, sim: &TrafficSim, density: Density) {
        self.density = density;
        self.target = self.target_for(sim, density);
    }

    /// Target vehicle count: density x section share, integrated over every lane of the
    /// loop.
    pub fn target(&self) -> usize {
        self.target
    }

    fn per_km_lane(&self, density: Density) -> f64 {
        match density {
            Density::Light => self.densities[0],
            Density::Normal => self.densities[1],
            Density::Rush => self.densities[2],
        }
    }

    fn section_share(&self, sim: &TrafficSim, s: f64) -> f64 {
        let i = sim.road.section_index(s);
        self.section_frac.get(i).copied().unwrap_or(1.0)
    }

    fn target_for(&self, sim: &TrafficSim, density: Density) -> usize {
        let road = &sim.road;
        let length = road.period();
        if length <= 0.0 {
            return 0;
        }
        let k = self.per_km_lane(density);
        let mut total = 0.0;
        let mut s = TARGET_STEP_M * 0.5;
        while s < length {
            total += f64::from(road.lane_count(s)) * self.section_share(sim, s) * k * TARGET_STEP_M
                / M_PER_KM;
            s += TARGET_STEP_M;
        }
        (total.round() as usize).min(sim.state.capacity)
    }

    /// The ramps' merge walls (the on-ramp lane closed from the ramp's end) and the
    /// headway scale of the loop's director leg (plan D11).
    pub fn install(&self, sim: &mut TrafficSim) {
        sim.set_headway_scale(self.headway_scale);
        let zone = sim_drop_zone(sim);
        for &(s, len) in &self.on_ramps {
            let lane = sim.ramp_lane(s);
            let s0 = sim.road.wrap(s + len);
            let s1 = sim.road.wrap(s + len + self.ramp.merge_wall_m);
            sim.add_lane_closure(lane, s0, s1, RAMP_CLOSURE_TAG, zone.0, zone.1);
        }
    }

    /// Road works zone `index` on or off (the room's toggle): its lanes from the right are
    /// closed like a set-piece closure. False when the zone does not exist.
    pub fn set_road_works(&self, sim: &mut TrafficSim, index: usize, on: bool) -> bool {
        let Some(z) = sim.road.closure_zones.get(index).copied() else {
            return false;
        };
        let tag = ZONE_CLOSURE_TAG_BASE + index as i32;
        sim.remove_lane_closures(tag);
        if on {
            let lanes = sim.road.lane_count(z.s_start);
            for k in 0..z.lanes_closed_from_right {
                sim.add_lane_closure(lanes - 1 - k, z.s_start, z.s_end, tag, 0.0, 0.0);
            }
        }
        true
    }

    // ------------------------------------------------------------ The mix (Flow)

    /// `SpawnSources.Flow.draw_into` for lane `lane` of `lanes` at s: profile, v0, v, type,
    /// variant and colour. None when no profile fits the lane.
    pub fn draw(
        &mut self,
        sim: &TrafficSim,
        lane: i32,
        lanes: i32,
        s: f64,
        min_speed: f64,
    ) -> Option<SpawnRecord> {
        let flow_v = sim.road.lane_flow_speed_mps(lane, lanes, s);
        let floor_v = maxf(flow_v - self.tolerance, min_speed);
        let right_first = lanes - self.keep_right_spawn;
        let mut others = 0.0;
        let mut aggressive_ok = false;
        let mut racer_ok = false;
        for p in 0..self.n_profiles {
            self.w[p] = 0.0;
            if !self.eligible(p, lane, lanes, right_first, floor_v) {
                continue;
            }
            if p as i32 == self.aggressive {
                aggressive_ok = true;
            } else if p as i32 == self.racer {
                racer_ok = true;
            } else {
                self.w[p] = self.p_weight[p];
                others += self.w[p];
            }
        }
        let mut agg = if aggressive_ok {
            clampf(self.agg_share, 0.0, 1.0)
        } else {
            0.0
        };
        let mut rac = if racer_ok {
            clampf(self.racer_share, 0.0, 1.0)
        } else {
            0.0
        };
        if agg + rac > 1.0 {
            let k = 1.0 / (agg + rac);
            agg *= k;
            rac *= k;
        }
        if others <= 0.0 {
            if !(aggressive_ok || racer_ok) {
                return None;
            }
            if agg + rac <= 0.0 {
                agg = if aggressive_ok { 1.0 } else { 0.0 };
                rac = 1.0 - agg;
            } else {
                let k = 1.0 / (agg + rac);
                agg *= k;
                rac *= k;
            }
        }
        let fast = agg + rac;
        let r = self.rng.unit();
        let mut p = self.racer;
        if r >= rac {
            p = self.aggressive;
            if r >= fast {
                p = self.pick((r - fast) / (1.0 - fast) * others);
            }
        }
        if p < 0 {
            return None;
        }
        let pu = p as usize;
        let mut v0 = self
            .rng
            .float_range(maxf(self.p_vmin[pu], floor_v), self.p_vmax[pu]);
        if self.jitter > 0.0 {
            v0 = clampf(
                v0 * (1.0 + self.jitter * (2.0 * self.rng.unit() - 1.0)),
                maxf(self.p_vmin[pu], min_speed),
                self.p_vmax[pu],
            );
        }
        let allowed = &self.p_types[pu];
        let t = allowed[self.rng.int_range(0, allowed.len() as i32 - 1) as usize];
        let variants = self.t_variants[t as usize];
        let model_variant = if variants > 1 {
            self.rng.int_range(0, variants - 1)
        } else {
            0
        };
        let palette = self
            .palette
            .get(sim.road.section_index(s))
            .copied()
            .unwrap_or(1);
        let color_index = self.rng.int_range(0, palette - 1);
        Some(SpawnRecord {
            s,
            lane,
            d: f64::NAN,
            v: flow_v,
            v0,
            type_id: t,
            profile_id: p,
            model_variant,
            color_index,
            flags: 0,
        })
    }

    fn eligible(&self, p: usize, lane: i32, lanes: i32, right_first: i32, floor_v: f64) -> bool {
        let pi = p as i32;
        if pi != self.aggressive && pi != self.racer && self.p_weight[p] <= 0.0 {
            return false;
        }
        if self.p_min_leg[p] > self.leg {
            return false;
        }
        if pi == self.hesitant && !self.hesitant_allowed {
            return false;
        }
        if self.p_vmax[p] < floor_v {
            return false;
        }
        if self.p_keep_right[p] == 1 && lane < right_first {
            return false;
        }
        if self.p_left_lanes[p] > 0 && (lane >= self.p_left_lanes[p] || lane >= lanes - 1) {
            return false;
        }
        !self.p_types[p].is_empty()
    }

    fn pick(&self, mut x: f64) -> i32 {
        let mut last = -1;
        for p in 0..self.n_profiles {
            if self.w[p] <= 0.0 {
                continue;
            }
            last = p as i32;
            x -= self.w[p];
            if x < 0.0 {
                return p as i32;
            }
        }
        last
    }

    // ------------------------------------------------------------ Fill

    /// Fills the ring at the target density (a new room): lane by lane at the density's
    /// spacing (jittered), each car pushed back to IDM's s* behind the one before it, then
    /// gap-filling passes until the target count. Returns the vehicles placed. Not a
    /// per-tick path (it allocates).
    pub fn fill(&mut self, sim: &mut TrafficSim) -> usize {
        let length = sim.road.period();
        if length <= 0.0 {
            return 0;
        }
        let k = self.per_km_lane(self.density);
        let mut max_lanes = 0;
        for (_, _, c) in sim.road.lane_ranges() {
            max_lanes = max_lanes.max(c);
        }
        let mut placed = 0;
        for lane in 0..max_lanes {
            // (s, v, half length, profile) of the previous car in this lane.
            let mut prev: Option<(f64, f64, f64, usize)> = None;
            let mut s = self.rng.float_range(0.0, M_PER_KM / k);
            while s < length && placed < self.target {
                let lanes = sim.road.lane_count(s);
                if lane >= lanes || sim.closure_ahead(lane, s) < self.merge_spawn_clear {
                    s += TARGET_STEP_M;
                    continue;
                }
                let Some(mut rec) = self.draw(sim, lane, lanes, s, 0.0) else {
                    s += TARGET_STEP_M;
                    continue;
                };
                rec.v = rec.v.min(rec.v0);
                let hl = self.t_len[rec.type_id as usize] * 0.5;
                let p = rec.profile_id as usize;
                if let Some((ps, pv, phl, pp)) = prev {
                    let need =
                        ps + self.min_gap(pp, pv, p, rec.v) + phl + hl + self.fill.extra_gap_m;
                    if s < need {
                        s = need;
                        continue;
                    }
                }
                if !self.fits_in_lane(sim, lane, s, hl, p, rec.v) || !self.clear_of_players(sim, s)
                {
                    s += TARGET_STEP_M;
                    continue;
                }
                rec.s = s;
                if sim.spawn(&rec).is_some() {
                    placed += 1;
                    prev = Some((s, rec.v, hl, p));
                }
                let share = self.section_share(sim, s);
                s += M_PER_KM / (k * share)
                    * (1.0 + self.fill.spacing_jitter_frac * (2.0 * self.rng.unit() - 1.0));
            }
        }
        // Gap-filling passes: a car into the middle of any gap that holds it.
        let mut progress = true;
        while placed < self.target && progress {
            progress = false;
            for lane in 0..max_lanes {
                let cars: Vec<usize> = sim
                    .order()
                    .iter()
                    .copied()
                    .filter(|&i| i < sim.state.capacity && sim.state.lane[i] == lane)
                    .collect();
                for w in 0..cars.len() {
                    if placed >= self.target {
                        break;
                    }
                    let a = cars[w];
                    let b = cars[(w + 1) % cars.len()];
                    let (sa, sb) = (sim.state.s[a], sim.state.s[b]);
                    let mut gap = sim.road.signed_delta(sa, sb);
                    if gap <= 0.0 {
                        gap += length;
                    }
                    let mid = sim.road.wrap(sa + gap * 0.5);
                    let lanes = sim.road.lane_count(mid);
                    if lane >= lanes || sim.closure_ahead(lane, mid) < self.merge_spawn_clear {
                        continue;
                    }
                    let Some(mut rec) = self.draw(sim, lane, lanes, mid, 0.0) else {
                        continue;
                    };
                    rec.v = rec.v.min(rec.v0);
                    let hl = self.t_len[rec.type_id as usize] * 0.5;
                    let p = rec.profile_id as usize;
                    if !self.fits_in_lane(sim, lane, mid, hl, p, rec.v)
                        || !self.clear_of_players(sim, mid)
                    {
                        continue;
                    }
                    rec.s = mid;
                    if sim.spawn(&rec).is_some() {
                        placed += 1;
                        progress = true;
                    }
                }
            }
        }
        self.stats.filled += placed as u64;
        placed
    }

    /// A car of profile p at s in `lane` (speed v, half length hl) keeps IDM's s* (both
    /// orders) to every vehicle in that lane or moving into it.
    fn fits_in_lane(&self, sim: &TrafficSim, lane: i32, s: f64, hl: f64, p: usize, v: f64) -> bool {
        let st = &sim.state;
        for i in 0..st.capacity {
            if st.active[i] == 0 || (st.lane[i] != lane && st.target_lane[i] != lane) {
                continue;
            }
            let ds = sim.road.signed_delta(s, st.s[i]);
            let q = st.profile_id[i] as usize;
            let need = if ds >= 0.0 {
                self.min_gap(p, v, q, st.v[i])
            } else {
                self.min_gap(q, st.v[i], p, v)
            };
            if ds.abs() < need + hl + st.length[i] * 0.5 + self.fill.extra_gap_m {
                return false;
            }
        }
        true
    }

    /// IDM's s* between a follower (profile pf at vf) and a leader (pl at vl), whichever
    /// is faster closing: the larger of the two orders (SpawnSources' rule (b)).
    fn min_gap(&self, pf: usize, vf: f64, pl: usize, vl: f64) -> f64 {
        let a = idm::desired_gap(
            vf,
            vf - vl,
            self.p_a[pf],
            self.p_b[pf],
            self.p_t[pf],
            self.p_s0[pf],
        );
        let b = idm::desired_gap(
            vl,
            vl - vf,
            self.p_a[pl],
            self.p_b[pl],
            self.p_t[pl],
            self.p_s0[pl],
        );
        maxf(a, b)
    }

    fn clear_of_players(&self, sim: &TrafficSim, s: f64) -> bool {
        for p in 0..sim.config.max_players {
            if sim.player_active(p) {
                let ps = sim.state_player_s(p);
                if sim.road.signed_delta(ps, s).abs() < self.ramp.spawn_player_clear_m {
                    return false;
                }
            }
        }
        true
    }

    // ------------------------------------------------------------ Upkeep (every tick)

    /// Exits and entries for this tick (after `sim.step`).
    pub fn update(&mut self, sim: &mut TrafficSim, dt: f64) {
        let count = sim.state.count;
        let target = self.target.max(1);
        let surplus = (count as f64 - target as f64) / target as f64;
        let exit_p = if surplus < 0.0 {
            0.0
        } else {
            clampf(
                self.ramp.exit_share_base_frac + self.ramp.exit_share_gain * surplus,
                0.0,
                self.ramp.exit_share_max_frac,
            )
        };
        for r in 0..self.off_ramps.len() {
            self.exits_at(sim, r, exit_p);
        }
        for r in 0..self.on_ramps.len() {
            self.on_timer[r] += dt;
            let limit = (self.target as f64 * (1.0 + self.ramp.spawn_stop_surplus_frac)) as usize;
            if sim.state.count < limit && self.on_timer[r] >= self.ramp.spawn_interval_s {
                if self.enter_at(sim, r) {
                    self.on_timer[r] = 0.0;
                } else {
                    self.stats.ramp_spawn_blocked += 1;
                }
            }
        }
    }

    fn exits_at(&mut self, sim: &mut TrafficSim, r: usize, exit_p: f64) {
        let (s_off, _len) = self.off_ramps[r];
        let window = self.ramp.exit_decision_window_m;
        let n = sim.order().len();
        if n == 0 {
            return;
        }
        // Vehicles whose centre lies in [s_off, s_off + window): the order is sorted by s.
        let start = sim.order_lower_bound(s_off);
        for x in 0..n {
            let k = (start + x) % n;
            let i = sim.order()[k];
            if i >= sim.state.capacity {
                continue;
            }
            let ahead = sim.road.signed_delta(s_off, sim.state.s[i]);
            if !(0.0..window).contains(&ahead) {
                break;
            }
            let vid = sim.state.vehicle_id[i];
            if self.rolled_vid[i] != vid || self.rolled_ramp[i] != r as i32 {
                self.rolled_vid[i] = vid;
                self.rolled_ramp[i] = r as i32;
                self.wants_exit[i] = 0;
                if self.exit_candidate(sim, i) {
                    self.stats.exit_rolls += 1;
                    if self.rng.chance(exit_p) {
                        self.wants_exit[i] = 1;
                    }
                }
            }
            if self.wants_exit[i] == 1 && self.exit_candidate(sim, i) && sim.try_exit(i) {
                self.wants_exit[i] = 0;
                self.stats.exits_started += 1;
            }
        }
    }

    fn exit_candidate(&self, sim: &TrafficSim, i: usize) -> bool {
        let st = &sim.state;
        st.lc_state[i] == LC_NONE
            && (st.flags[i] & (FLAG_HIT | FLAG_SCRIPTED)) == 0
            && !sim.is_exiting(i)
            && !sim.is_lane_splitting(i)
            && st.lane[i] == sim.road.lane_count(st.s[i]) - 1
    }

    /// One car onto on-ramp r when its start is clear. True when it spawned.
    fn enter_at(&mut self, sim: &mut TrafficSim, r: usize) -> bool {
        let (s_on, _len) = self.on_ramps[r];
        let lanes = sim.road.lane_count(s_on);
        let ramp = lanes;
        let lo = sim.lane_d(ramp) - lane_half(sim);
        let hi = sim.lane_d(ramp) + lane_half(sim);
        if !self.clear_of_players(sim, s_on) {
            return false;
        }
        let Some(mut rec) = self.draw(sim, lanes - 1, lanes, s_on, 0.0) else {
            return false;
        };
        let len = self.t_len[rec.type_id as usize];
        let p = rec.profile_id as usize;
        let clear = self.ramp.spawn_clear_m;
        let need_ahead = idm::desired_gap(
            rec.v,
            0.0,
            self.p_a[p],
            self.p_b[p],
            self.p_t[p],
            self.p_s0[p],
        );
        if !sim.space_clear(s_on, len, lo, hi, clear, need_ahead.max(clear)) {
            return false;
        }
        rec.lane = ramp;
        rec.d = f64::NAN;
        if sim.spawn(&rec).is_some() {
            if let Some(e) = sim.events_last_mut() {
                e.tag = EventTag::Ramp;
            }
            self.stats.ramp_spawns += 1;
            return true;
        }
        false
    }
}

fn lane_half(sim: &TrafficSim) -> f64 {
    (sim.lane_d(1) - sim.lane_d(0)) * 0.5
}

/// The road drop's merge zone and base urgency (WP6.8), used for the ramps' walls too:
/// a car on an on-ramp merges like one in a dropping lane.
fn sim_drop_zone(sim: &TrafficSim) -> (f64, f64) {
    sim.drop_merge_params()
}
