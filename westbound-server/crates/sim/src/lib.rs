//! Pure, deterministic simulation: road-space math, loop map, traffic, scoring, validation.
//! No I/O, no clocks, no global state (multiplayer handoff → Rules for the server code, rule 1).

pub mod map;
pub mod rng;
pub mod scoring;
pub mod trace_hash;
pub mod traffic;
