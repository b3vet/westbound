//! Sealing a provider token at rest (N11): Apple's refresh token, kept only to revoke it
//! on unlink and account deletion (Apple requires revocation when an account goes).
//!
//! Format: `version (1) ‖ nonce (16) ‖ ciphertext ‖ tag (16)`. The keystream is
//! HMAC-SHA256(enc_key, nonce ‖ counter) blocks XORed with the plaintext (a PRF in counter
//! mode); the tag is HMAC-SHA256(mac_key, version ‖ nonce ‖ ciphertext) truncated to 16
//! bytes (encrypt-then-MAC, checked in constant time). Both keys are derived from the
//! pepper (`AuthKeys::derive_key`), so a leaked database alone does not reveal the tokens.

use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;

use crate::auth::{random_bytes, AuthKeys};

type HmacSha256 = Hmac<Sha256>;

const VERSION: u8 = 1;
const NONCE_BYTES: usize = 16;
const TAG_BYTES: usize = 16;
const BLOCK: usize = 32;
const ENC_CONTEXT: &[u8] = b"identity/seal/enc/v1";
const MAC_CONTEXT: &[u8] = b"identity/seal/mac/v1";

/// The sealing keys.
pub struct Sealer {
    enc: [u8; 32],
    mac: [u8; 32],
}

impl std::fmt::Debug for Sealer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Sealer").finish_non_exhaustive()
    }
}

impl Sealer {
    pub fn new(keys: &AuthKeys) -> Self {
        Self {
            enc: keys.derive_key(ENC_CONTEXT),
            mac: keys.derive_key(MAC_CONTEXT),
        }
    }

    pub fn seal(&self, plain: &[u8]) -> Vec<u8> {
        let nonce = random_bytes::<NONCE_BYTES>();
        let mut out = Vec::with_capacity(1 + NONCE_BYTES + plain.len() + TAG_BYTES);
        out.push(VERSION);
        out.extend_from_slice(&nonce);
        out.extend_from_slice(plain);
        self.xor_stream(&nonce, &mut out[1 + NONCE_BYTES..]);
        let tag = self.tag(&out);
        out.extend_from_slice(&tag);
        out
    }

    /// The plaintext, or None for a damaged or foreign blob.
    pub fn open(&self, sealed: &[u8]) -> Option<Vec<u8>> {
        if sealed.len() < 1 + NONCE_BYTES + TAG_BYTES || sealed[0] != VERSION {
            return None;
        }
        let (body, tag) = sealed.split_at(sealed.len() - TAG_BYTES);
        if !bool::from(self.tag(body).as_slice().ct_eq(tag)) {
            return None;
        }
        let mut nonce = [0u8; NONCE_BYTES];
        nonce.copy_from_slice(&body[1..1 + NONCE_BYTES]);
        let mut plain = body[1 + NONCE_BYTES..].to_vec();
        self.xor_stream(&nonce, &mut plain);
        Some(plain)
    }

    fn xor_stream(&self, nonce: &[u8; NONCE_BYTES], data: &mut [u8]) {
        for (i, chunk) in data.chunks_mut(BLOCK).enumerate() {
            let mut mac = HmacSha256::new_from_slice(&self.enc).expect("HMAC takes any key length");
            mac.update(nonce);
            mac.update(&(i as u64).to_be_bytes());
            let block = mac.finalize().into_bytes();
            for (b, k) in chunk.iter_mut().zip(block.iter()) {
                *b ^= k;
            }
        }
    }

    fn tag(&self, body: &[u8]) -> [u8; TAG_BYTES] {
        let mut mac = HmacSha256::new_from_slice(&self.mac).expect("HMAC takes any key length");
        mac.update(body);
        let full = mac.finalize().into_bytes();
        let mut t = [0u8; TAG_BYTES];
        t.copy_from_slice(&full[..TAG_BYTES]);
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, Secret};

    fn sealer(pepper: &str) -> Sealer {
        let mut c = Config::default();
        c.auth.jwt_secret = Secret::new("j".repeat(40));
        c.auth.device_secret_pepper = Secret::new(pepper);
        Sealer::new(&AuthKeys::from_config(&c))
    }

    #[test]
    fn round_trip_tamper_and_wrong_key() {
        let s = sealer(&"p".repeat(40));
        for len in [0usize, 1, 31, 32, 33, 100, 500] {
            let plain: Vec<u8> = (0..len).map(|i| i as u8).collect();
            let sealed = s.seal(&plain);
            assert_eq!(sealed.len(), 1 + NONCE_BYTES + len + TAG_BYTES);
            assert_eq!(s.open(&sealed).as_deref(), Some(plain.as_slice()));
            if len > 0 {
                assert_ne!(
                    &sealed[1 + NONCE_BYTES..1 + NONCE_BYTES + len],
                    plain.as_slice()
                );
            }
            for i in 0..sealed.len() {
                let mut bad = sealed.clone();
                bad[i] ^= 1;
                assert!(s.open(&bad).is_none(), "flip at {i}");
            }
        }
        let a = s.seal(b"same");
        let b = s.seal(b"same");
        assert_ne!(a, b, "fresh nonce each time");
        assert!(sealer(&"q".repeat(40)).open(&a).is_none());
        assert!(s.open(&[]).is_none());
    }
}
