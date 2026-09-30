//! Scoring (N6): a port of the client's rule set (`src/scoring/`) for the server's
//! official score. Spec: WESTBOUND HANDOFF.md → Scoring (all of it);
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Scoring in multiplayer ("The server runs the same
//! scoring rules (`sim::scoring`) on accepted claims only, and adds crew bonuses and
//! trains"); docs/SCORING.md (the rules as implemented); docs/SERVER.md → Scoring (N6.1).
//!
//! | Module | Ports | Adds |
//! | --- | --- | --- |
//! | [`rules`] | `scoring.gd` (`Scoring`, function for function; parity-tested) | the claim path (`begin_tick` / `award` / `end_tick`), crew factor, rejoin forfeit |
//! | [`hull`] | `road_hull.gd` (`RoadHull.clearance`) | `penetration` (hit cross-check) |
//! | [`events`] | `score_event_buffer.gd`, `score_events.gd` | the `train` kind, the `rejoin` tag |
//! | [`params`] | `ScoringTuning` + the scoring-related `LegsTuning`, `LivesTuning`, `SunTuning` (exported JSON) | |
//! | [`sectors`] | `leg_tracker.gd`'s per-leg facts (loop mode's sectors) | |
//! | [`road`] | `RoadPath.lane_index_at` / `is_on_shoulder` | the loop map's |
//!
//! Pure: no I/O, clocks or globals; allocation-free per tick.

pub mod events;
pub mod hull;
pub mod params;
pub mod road;
pub mod rules;
pub mod sectors;

pub use events::{Kind, ScoreEventBuffer, ScoreRecord, Tag};
pub use params::ScoringParams;
pub use road::{LaneRoad, LoopRoad};
pub use rules::{PlayerTick, Scoring, ScoringCars, ScoringRoad};
pub use sectors::{SectorCrossing, SectorTracker};
