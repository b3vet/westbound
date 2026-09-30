//! Load-test and netcode-test bot clients (multiplayer handoff → Netcode harness).
//!
//! - `bot` (N5.1): [`bot::RoomBot`], a scripted room player without a transport: reads
//!   server frames, drives the loop at a set speed, takes server placements, keeps a room
//!   clock estimate, and records what it saw.
//! - `client` (N5.1): [`client::BotClient`], a `RoomBot` on a real WebSocket (handshake,
//!   room commands, a 20 Hz drive loop, disconnect / reconnect).
//! - `http`: device accounts for bots.
//! - `traffic` (N4.2): [`traffic::TrafficMirror`], the traffic a bot has been streamed,
//!   with the checks a client relies on (ids, same-frame corrections, intent leads, gaps).
//!
//! - `driver` (N6.1): [`driver::TrafficDriver`] (drives through the streamed traffic)
//!   and [`driver::Scorer`] (the client's rules on the mirror, turned into honest or
//!   cheating `score_claim`s).
//! - `link` (N6.1): a minimal delay / jitter / loss line per direction (N4.4 owns the
//!   full layer and its metrics).

pub mod bot;
pub mod client;
pub mod driver;
pub mod http;
pub mod link;
pub mod traffic;

pub use bot::{BotConfig, RoomBot};
pub use client::BotClient;
pub use driver::{Cheat, ClaimMode, DriveMode};
pub use link::LinkSim;
pub use traffic::{MirrorRules, TrafficMirror};
