//! Load-test and netcode-test bot clients (multiplayer handoff → Netcode harness).
//!
//! - `bot` (N5.1): [`bot::RoomBot`], a scripted room player without a transport: reads
//!   server frames, drives the loop at a set speed, takes server placements, keeps a room
//!   clock estimate, and records what it saw.
//! - `client` (N5.1): [`client::BotClient`], a `RoomBot` on a real WebSocket (handshake,
//!   room commands, a 20 Hz drive loop, disconnect / reconnect).
//! - `http`: device accounts for bots; plain GETs (the load test's scrapes).
//! - `load` (N10.1): `/metrics` scrapes, windows between them, `/proc/<pid>` samples.
//! - `traffic` (N4.2): [`traffic::TrafficMirror`], the traffic a bot has been streamed,
//!   with the checks a client relies on (ids, same-frame corrections, intent leads, gaps).
//!
//! - `driver` (N6.1): [`driver::TrafficDriver`] (drives through the streamed traffic)
//!   and [`driver::Scorer`] (the client's rules on the mirror, turned into honest or
//!   cheating `score_claim`s).
//! - `link` (N4.4): the in-process delay layer: per-direction delay, jitter and loss
//!   (TCP: late and in order; datagram: gone and reordered), with statistics.
//! - `predict` (N4.4): [`predict::TrafficPredictor`], the client's traffic model on a bot:
//!   correction sizes and late intents as a client measures them.
//! - `loadtest` (N10.1, `src/bin/loadtest.rs`): N rooms × M bots against a running server,
//!   with the server's CPU, memory, tick times and the netcode numbers.

pub mod bot;
pub mod client;
pub mod driver;
pub mod http;
pub mod link;
pub mod load;
pub mod predict;
pub mod traffic;

pub use bot::{BotConfig, RoomBot};
pub use client::BotClient;
pub use driver::{Cheat, ClaimMode, DriveMode};
pub use link::{LinkMode, LinkSim, LinkStats};
pub use predict::{NetStats, TrafficPredictor};
pub use traffic::{MirrorRules, TrafficMirror};
