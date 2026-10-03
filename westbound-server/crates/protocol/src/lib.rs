//! Wire protocol: message types, binary codec, handshake, golden vectors
//! (multiplayer handoff → Networking protocol). WP N2.1. The contract is `docs/PROTOCOL.md`.
//!
//! - `messages`: every message in both directions (`ClientMsg`, `ServerMsg`).
//! - `frame`: framing, the never-panicking decoder, `FrameBuilder` and streaming batches.
//! - `quant`: physical ↔ wire unit conversions.
//! - `handshake`: the pure `Hello` → `Welcome` / `Error` state machine and keepalive timer.
//! - `budget`: per-player bandwidth accounting.
//! - `vectors`: golden test vectors (`cargo run -p protocol --bin gen_vectors` writes them).
#![forbid(unsafe_code)]

#[macro_use]
pub mod wire;
pub mod budget;
pub mod error;
pub mod frame;
pub mod handshake;
pub mod messages;
pub mod quant;
pub mod types;
pub mod vectors;

#[cfg(test)]
mod proptests;

/// Wire protocol version, sent in `Hello` and `Welcome`. Bumped on any wire change.
/// Version 2 (room and crew invites) added `lobby_command.room_invite` and
/// `lobby_event.room_invite` / `crew_invite` (docs/PROTOCOL.md §6).
pub const PROTOCOL_VERSION: u16 = 2;
/// Oldest client protocol this build accepts (see `handshake`). Version 1 clients keep
/// working: version 2 only added union kinds, and the server never sends a version 2 kind
/// to a session that said version 1 in its `Hello` ([`INVITES_PROTOCOL_VERSION`]).
pub const MIN_SUPPORTED_PROTOCOL_VERSION: u16 = 1;
/// First protocol version whose clients decode `lobby_event.room_invite` and
/// `lobby_event.crew_invite`. Older sessions are never sent either.
pub const INVITES_PROTOCOL_VERSION: u16 = 2;
/// Largest frame (one WebSocket message) in either direction: 16 KB.
pub const MAX_FRAME_LEN: usize = 16 * 1024;
/// `[u8 type][u16 length]`.
pub const MSG_HEADER_LEN: usize = 3;
/// Most messages one frame may hold.
pub const MAX_MESSAGES_PER_FRAME: usize = 64;

pub use error::{DecodeError, EncodeError, QuantError, ValidationError};
pub use frame::{
    decode_client_frame, decode_frame, decode_server_frame, encode_frame, read_frame, Batch,
    FrameBuilder, FrameReader, Message,
};
pub use messages::*;
pub use types::*;
