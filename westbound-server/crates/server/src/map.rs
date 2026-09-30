//! The loop map the server runs (N3.2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop
//! map (the road-space file shared by client and server, the hash check on join);
//! docs/LOOP_MAP.md → Road-space file; docs/SERVER.md → Map hashes.
//!
//! `loop_v1.json` is compiled into the binary (`include_str!`, like the profanity list):
//! the Docker build context is `westbound-server/`, which holds the server's copy
//! (`data/maps/`, written by the Godot editor's EXPORT together with the client's), so the
//! binary and its map can never drift apart and no file has to be mounted. At startup the
//! bytes are parsed and validated ([`sim::map::LoopMap`]) and hashed: the SHA-256 of every
//! byte is the `Hello.map_hash` a client of the same map sends. The gateway accepts it
//! automatically when `gateway.map_hashes` is empty; a configured list
//! (`WB_GATEWAY__MAP_HASHES`) is an explicit override.

use std::sync::{Arc, LazyLock};

use protocol::MapHash;
use sha2::{Digest, Sha256};
use sim::map::{LoopMap, MapError};

/// The committed road-space file (`westbound-server/data/maps/loop_v1.json`).
pub const LOOP_V1_JSON: &str = include_str!("../../../data/maps/loop_v1.json");
/// Its `sha256sum` sidecar (`<hex>  loop_v1.json`), checked by the tests.
pub const LOOP_V1_SHA256: &str = include_str!("../../../data/maps/loop_v1.sha256");

static BUILTIN: LazyLock<Result<Arc<ServerMap>, MapError>> =
    LazyLock::new(|| ServerMap::load(LOOP_V1_JSON).map(Arc::new));

/// A parsed, validated loop map and the hash of its bytes.
#[derive(Debug, Clone)]
pub struct ServerMap {
    pub map: LoopMap,
    /// SHA-256 of every byte of the file (`Hello.map_hash`).
    pub hash: MapHash,
    /// The same, 64 lowercase hex characters (the `gateway.map_hashes` form).
    pub hash_hex: String,
}

impl ServerMap {
    /// Parses, validates and hashes a road-space file.
    pub fn load(json: &str) -> Result<Self, MapError> {
        let map = LoopMap::from_json(json)?;
        let digest: [u8; 32] = Sha256::digest(json.as_bytes()).into();
        Ok(Self {
            map,
            hash: MapHash(digest),
            hash_hex: hex_lower(&digest),
        })
    }
}

/// The built-in `loop_v1` (parsed once).
pub fn builtin() -> Result<Arc<ServerMap>, MapError> {
    BUILTIN.clone()
}

/// A map hash as 64 lowercase hex characters (the `gateway.map_hashes` form).
pub fn hash_hex(h: &MapHash) -> String {
    hex_lower(&h.0)
}

fn hex_lower(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(char::from(DIGITS[usize::from(b >> 4)]));
        s.push(char::from(DIGITS[usize::from(b & 0x0F)]));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_loads_and_matches_the_sidecar() {
        let m = builtin().expect("loop_v1 is valid");
        assert_eq!(m.map.map_id, "loop_v1");
        assert_eq!(m.map.length_mm(), 25_000_000);
        let sidecar_hex = LOOP_V1_SHA256
            .split_whitespace()
            .next()
            .expect("sidecar hash");
        assert_eq!(
            m.hash_hex, sidecar_hex,
            "the SHA-256 of the bytes is the committed .sha256"
        );
        assert!(LOOP_V1_SHA256.trim_end().ends_with("loop_v1.json"));
        assert_eq!(
            crate::config::parse_map_hash(&m.hash_hex),
            Some(m.hash),
            "hex and bytes agree"
        );
    }

    #[test]
    fn any_byte_changes_the_hash() {
        let edited = LOOP_V1_JSON.replacen("\"seed\": 1", "\"seed\": 1 ", 1);
        let a = ServerMap::load(LOOP_V1_JSON).expect("valid");
        let b = ServerMap::load(&edited).expect("still valid JSON");
        assert_ne!(a.hash, b.hash);
    }

    #[test]
    fn invalid_maps_are_refused() {
        assert!(ServerMap::load("{}").is_err());
    }
}
