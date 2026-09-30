//! One room's traffic on the loop: the sim with the server's rules, the population
//! (fill, ramps, density) and the tick counter, behind one call per 20 Hz tick. This is
//! what the room task (N4.2) owns.
//!
//! ```
//! use sim::traffic::{Density, TrafficWorld, PlayerInput};
//! let map = sim::map::LoopMap::from_json(include_str!("../../../../data/maps/loop_v1.json")).unwrap();
//! let mut world = TrafficWorld::builtin(&map, Density::Light, 42).unwrap();
//! world.set_player(0, PlayerInput { s: 150.0, d: 3.5, s_dot: 30.0, d_dot: 0.0,
//!     length: 4.5, width: 1.9, tick: world.tick_index() });
//! world.tick();
//! for e in world.sim.events.as_slice() { let _ = e; }   // intents, spawns, despawns ...
//! ```

use super::params::{Density, MpTrafficRules, TrafficParams};
use super::population::Population;
use super::road::RoadSpace;
use super::sim::{PlayerInput, SimConfig, TrafficSim};
use crate::map::LoopMap;
use crate::rng::{Rng, STREAM_TRAFFIC};

pub struct TrafficWorld {
    pub sim: TrafficSim,
    pub population: Population,
    tick: u32,
    dt: f64,
}

impl TrafficWorld {
    /// A room's traffic on `map` at `density`, seeded by `seed` (the traffic stream is
    /// `Rng::new(seed).derive("traffic")`, as a client run's). The ring is filled; the
    /// fill's `Spawned` events are cleared.
    pub fn new(
        params: &TrafficParams,
        mp: &MpTrafficRules,
        map: &LoopMap,
        density: Density,
        seed: i64,
    ) -> Self {
        let rng_traffic = Rng::new(seed).derive(STREAM_TRAFFIC);
        let config = SimConfig::multiplayer(params, mp);
        let dt = config.tick_dt;
        let mut sim = TrafficSim::new(params, config, RoadSpace::from_loop(map), &rng_traffic);
        sim.add_road_closures();
        let mut population =
            Population::new(params, mp, &sim, density, rng_traffic.derive("population"));
        population.install(&mut sim);
        population.fill(&mut sim);
        sim.events.clear();
        TrafficWorld {
            sim,
            population,
            tick: 0,
            dt,
        }
    }

    /// With the compiled-in parameters.
    pub fn builtin(map: &LoopMap, density: Density, seed: i64) -> Result<Self, String> {
        let params = TrafficParams::builtin()?;
        let mp = MpTrafficRules::builtin()?;
        Ok(Self::new(&params, &mp, map, density, seed))
    }

    /// One fixed step: events cleared, the sim stepped at the next tick, then exits and
    /// entries. Read `sim.events` and `sim.state` afterwards. Returns the tick.
    pub fn tick(&mut self) -> u32 {
        self.sim.events.clear();
        self.tick = self.tick.wrapping_add(1);
        self.sim.step(self.dt, self.tick);
        self.population.update(&mut self.sim, self.dt);
        self.tick
    }

    /// The last tick stepped (0 before the first).
    pub fn tick_index(&self) -> u32 {
        self.tick
    }

    pub fn dt(&self) -> f64 {
        self.dt
    }

    /// Player p's latest reported state (its `tick` is the tick it describes).
    pub fn set_player(&mut self, p: usize, input: PlayerInput) {
        self.sim.set_player(p, input);
    }

    pub fn remove_player(&mut self, p: usize) {
        self.sim.remove_player(p);
    }

    /// The room's density (light / normal / rush); the ramps move the ring to it.
    pub fn set_density(&mut self, density: Density) {
        self.population.set_density(&self.sim, density);
    }

    /// Road works zone `index` on or off.
    pub fn set_road_works(&mut self, index: usize, on: bool) -> bool {
        self.population.set_road_works(&mut self.sim, index, on)
    }

    /// Headlights (the room clock's night).
    pub fn set_headlights(&mut self, on: bool) {
        self.sim.set_headlights(on);
    }

    /// A player's accepted hit on traffic car `slot`: the scripted reaction (swerve,
    /// hard brake, hazards; `Hazards` on at the next tick).
    pub fn notify_hit(&mut self, slot: usize, player: usize) {
        self.sim.notify_hit(slot, player);
    }
}
