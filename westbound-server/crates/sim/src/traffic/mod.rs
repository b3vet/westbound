//! Server traffic (N4.1): a port of the client's traffic model (`src/traffic/`) plus the
//! multiplayer rules. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Traffic: server-
//! authoritative with intents → Server simulation (`sim` crate); docs/TRAFFIC.md (the
//! model); docs/SERVER.md → Traffic simulation (the server's rules, parity, numbers).
//!
//! | Module | Ports | Adds |
//! | --- | --- | --- |
//! | [`idm`], [`mobil`], [`no_ambush`] | `idm.gd`, `mobil.gd`, `no_ambush.gd` (bit-exact) | |
//! | [`state`] | `traffic_state.gd` | |
//! | [`sim`] | `traffic_sim.gd` (function for function) | players, loop wrap, intents, ramps |
//! | [`population`] | `SpawnSources.Flow.draw_into` (the mix) | ring fill, density upkeep via ramps |
//! | [`road`] | the `RoadPath` subset | the loop in road space |
//! | [`params`] | `TrafficRegistry` / `TrafficTuning` (exported JSON) | server rules JSON |
//! | [`checker`] | `TrafficRuleChecker` (the soak's rules) | |
//! | [`world`] | | one room's traffic: sim + population, one call per tick |

pub mod checker;
pub mod gd;
pub mod idm;
pub mod mobil;
pub mod no_ambush;
pub mod params;
pub mod population;
pub mod road;
pub mod sim;
pub mod state;
pub mod world;

pub use params::{Density, MpTrafficRules, TrafficParams};
pub use road::RoadSpace;
pub use sim::{EventKind, EventTag, PlayerInput, SimConfig, SimEvent, SpawnRecord, TrafficSim};
pub use state::TrafficState;
pub use world::TrafficWorld;
