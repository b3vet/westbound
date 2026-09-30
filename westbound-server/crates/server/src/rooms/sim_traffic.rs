//! [`RoomTraffic`] backed by the `sim` crate's [`TrafficWorld`] (N4.1): the room's players
//! go into the sim every tick, the ring steps in lock-step with the room tick, and spawn
//! requests move to a real gap. Streaming (`write_client`) is N4.2's; until then this
//! adapter only runs the ring (`rooms.traffic = "sim"`; the default is `"none"`, since
//! nobody sees the cars yet). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Traffic → Server
//! simulation ("Players are in the simulation"), Players → Spawning ("a gap in traffic").
//!
//! Tick alignment: the world counts its own ticks from 0; the room tick it was created at
//! is its origin, and every room tick steps the world up to the same number (a room that
//! missed ticks catches up, at most [`MAX_CATCH_UP`] steps, else it re-anchors).

use std::sync::Arc;

use protocol::{Density, FrameBuilder};
use sim::map::LoopMap;
use sim::traffic::{
    Density as SimDensity, MpTrafficRules, PlayerInput, TrafficParams, TrafficWorld,
};

use super::plausibility::tick_diff;
use super::road::{lane_center_d_mm, lane_width_mm};
use super::traffic::{PlayerView, RoomTraffic, SpawnSpot};

/// Most world steps one room tick may run to catch up.
pub const MAX_CATCH_UP: u32 = 20;
const MM_PER_M: f64 = 1_000.0;
const CM_PER_M: f64 = 100.0;
const HEADING_PER_RAD: f64 = 10_000.0;

/// What a room needs to build its world (parsed once at startup).
#[derive(Debug, Clone)]
pub struct SimTrafficData {
    pub params: Arc<TrafficParams>,
    pub mp: Arc<MpTrafficRules>,
}

impl SimTrafficData {
    pub fn builtin() -> Result<Self, String> {
        Ok(Self {
            params: Arc::new(TrafficParams::builtin()?),
            mp: Arc::new(MpTrafficRules::builtin()?),
        })
    }
}

/// Free-gap search: candidates every `step_m` out to `search_m` either side of the wanted
/// spot (then the neighbouring lanes), each needing `clear_m` to the nearest car in its
/// lane both ways.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GapRules {
    pub search_m: f64,
    pub step_m: f64,
    pub clear_m: f64,
}

pub struct SimTraffic {
    world: TrafficWorld,
    /// Player id in each sim player index (0: free).
    slots: Vec<u16>,
    /// Room tick of world tick 0.
    origin: u32,
    length_m: f64,
    width_m: f64,
    gap: GapRules,
}

pub fn density(d: Density) -> SimDensity {
    match d {
        Density::Light => SimDensity::Light,
        Density::Normal => SimDensity::Normal,
        Density::Rush => SimDensity::Rush,
    }
}

impl SimTraffic {
    /// A filled ring at `density`, anchored at room tick `origin`.
    pub fn new(
        data: &SimTrafficData,
        map: &LoopMap,
        d: Density,
        seed: i64,
        origin: u32,
        gap: GapRules,
    ) -> Self {
        let world = TrafficWorld::new(&data.params, &data.mp, map, density(d), seed);
        Self {
            slots: vec![0; data.mp.max_players],
            world,
            origin,
            length_m: data.params.tuning.player_length_m,
            width_m: data.params.tuning.player_width_m,
            gap,
        }
    }

    pub fn world(&self) -> &TrafficWorld {
        &self.world
    }

    fn slot_of(&mut self, player_id: u16) -> Option<usize> {
        if let Some(p) = self.slots.iter().position(|&id| id == player_id) {
            return Some(p);
        }
        let p = self.slots.iter().position(|&id| id == 0)?;
        self.slots[p] = player_id;
        Some(p)
    }

    fn world_tick_of(&self, room_tick: u32) -> u32 {
        room_tick.wrapping_sub(self.origin)
    }

    /// Distance to the nearest car in `lane` at `s_m` (either way), up to `limit`.
    fn clearance(&self, map: &LoopMap, s_mm: u32, lane: u8, limit: f64) -> f64 {
        let st = &self.world.sim.state;
        let half = lane_width_mm(map, s_mm) as f64 / MM_PER_M * 0.5;
        let d_lane = lane_center_d_mm(map, lane, s_mm) as f64 / MM_PER_M;
        let s_m = f64::from(s_mm) / MM_PER_M;
        let mut best = limit;
        for i in 0..st.capacity {
            if st.active[i] == 0 || (st.d[i] - d_lane).abs() >= half + st.width[i] * 0.5 {
                continue;
            }
            let gap = map.signed_delta_m(s_m, st.s[i]).abs() - st.length[i] * 0.5;
            best = best.min(gap.max(0.0));
        }
        best
    }
}

impl RoomTraffic for SimTraffic {
    fn tick(&mut self, tick: u32, players: &[PlayerView]) {
        for v in players {
            let Some(p) = self.slot_of(v.player_id) else {
                continue;
            };
            let input = PlayerInput::from_vehicle(
                f64::from(v.s_mm) / MM_PER_M,
                f64::from(v.d_cm) / CM_PER_M,
                f64::from(v.speed_cms) / CM_PER_M,
                f64::from(v.lat_vel_cms) / CM_PER_M,
                f64::from(v.heading_e4) / HEADING_PER_RAD,
                0.0,
                self.length_m,
                self.width_m,
                self.world_tick_of(v.tick),
            );
            self.world.set_player(p, input);
        }
        let behind = tick_diff(self.world.tick_index(), self.world_tick_of(tick));
        if behind > i64::from(MAX_CATCH_UP) {
            // Far behind (a stalled task): step once and re-anchor the origin.
            self.world.tick();
            self.origin = tick.wrapping_sub(self.world.tick_index());
            return;
        }
        for _ in 0..behind.max(0) {
            self.world.tick();
        }
    }

    fn set_density(&mut self, d: Density) {
        self.world.set_density(density(d));
    }

    fn set_night(&mut self, night: bool) {
        self.world.set_headlights(night);
    }

    fn write_client(
        &mut self,
        _player_id: u16,
        _s_mm: u32,
        _joined: bool,
        _frame: &mut FrameBuilder,
    ) {
        // N4.2: TrafficSpawn / Despawn / Intent / Correction for the client's area.
    }

    fn player_left(&mut self, player_id: u16) {
        if let Some(p) = self.slots.iter().position(|&id| id == player_id) {
            self.slots[p] = 0;
            self.world.remove_player(p);
        }
    }

    fn free_gap(&self, map: &LoopMap, want: SpawnSpot) -> SpawnSpot {
        let g = self.gap;
        let steps = (g.search_m / g.step_m.max(1.0)).floor() as i64;
        let lanes = map.lane_count_at(want.s_mm);
        // The wanted lane first, then its neighbours; each from the wanted s outwards,
        // behind before ahead (spawns come in behind the crew).
        let lane_order = [
            Some(want.lane),
            want.lane.checked_add(1).filter(|l| *l < lanes),
            want.lane.checked_sub(1),
        ];
        for lane in lane_order.into_iter().flatten() {
            for k in 0..=steps {
                for sign in [-1i64, 1] {
                    if k == 0 && sign > 0 {
                        continue;
                    }
                    let off = (sign * k) as f64 * g.step_m * MM_PER_M;
                    let s_mm = map.wrap_mm(i64::from(want.s_mm) + off as i64);
                    let lane = lane.min(map.lane_count_at(s_mm).saturating_sub(1));
                    if self.clearance(map, s_mm, lane, g.clear_m) >= g.clear_m {
                        let mut spot = want;
                        spot.s_mm = s_mm;
                        spot.lane = lane;
                        spot.d_cm = (lane_center_d_mm(map, lane, s_mm) / 10) as i16;
                        spot.speed_cms = super::road::flow_speed_cms(map, lane, s_mm);
                        return spot;
                    }
                }
            }
        }
        want
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::RunState;

    const GAP: GapRules = GapRules {
        search_m: 60.0,
        step_m: 5.0,
        clear_m: 15.0,
    };

    #[test]
    fn players_ride_along_and_spawns_find_gaps() {
        let map = crate::map::builtin().expect("loop_v1");
        let data = SimTrafficData::builtin().expect("sim data");
        let origin = 1_000;
        let mut t = SimTraffic::new(&data, &map.map, Density::Rush, 7, origin, GAP);
        // A player at 40 m/s in lane 1.
        let mut view = PlayerView {
            player_id: 3,
            tick: origin,
            s_mm: 1_000_000,
            d_cm: 710,
            speed_cms: 4_000,
            heading_e4: 0,
            lat_vel_cms: 0,
            run_state: RunState::Driving,
            protected_until: 0,
        };
        for k in 1..=5u32 {
            view.tick = origin + k;
            view.s_mm += 2_000;
            t.tick(origin + k, std::slice::from_ref(&view));
        }
        assert_eq!(t.world().tick_index(), 5, "one world step per room tick");
        assert!(t.world().sim.player_active(0));
        // A skipped room tick is caught up.
        t.tick(origin + 8, &[]);
        assert_eq!(t.world().tick_index(), 8);
        t.player_left(3);
        assert!(!t.world().sim.player_active(0));
        // Every spot the search returns is clear of cars in its lane.
        let lane_d = lane_center_d_mm(&map.map, 1, 3_000_000);
        let want = SpawnSpot {
            s_mm: 3_000_000,
            lane: 1,
            d_cm: (lane_d / 10) as i16,
            speed_cms: 3_000,
        };
        let got = t.free_gap(&map.map, want);
        assert!(t.clearance(&map.map, got.s_mm, got.lane, GAP.clear_m) >= GAP.clear_m);
        assert!(map.map.signed_delta_mm(want.s_mm, got.s_mm).abs() <= 60_000);
    }
}
