//! Load-test and netcode-test bot clients (multiplayer handoff → Netcode harness).
//!
//! - `bot` (N5.1): [`bot::RoomBot`], a scripted room player without a transport: reads
//!   server frames, drives the loop at a set speed, takes server placements, keeps a room
//!   clock estimate, and records what it saw.
//! - `client` (N5.1): [`client::BotClient`], a `RoomBot` on a real WebSocket (handshake,
//!   room commands, a 20 Hz drive loop, disconnect / reconnect).
//! - `http`: device accounts for bots.
//!
//! N4.4 adds scripted paths through traffic, honest claims and the delay / jitter / loss
//! layer on top.

pub mod bot;
pub mod client;
pub mod http;

pub use bot::{BotConfig, RoomBot};
pub use client::BotClient;
