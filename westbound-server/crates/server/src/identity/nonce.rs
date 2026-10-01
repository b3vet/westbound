//! Sign-in nonces (N11). The client asks `POST /api/v1/auth/nonce` for one, passes it to
//! the provider (Google Identity Services `nonce`, Apple JS `nonce`, the native SDKs), and
//! sends it back with the ID token; the token's `nonce` claim must match. That binds an
//! ID token to a sign-in this server started, within `identity.nonce_ttl_secs`.
//!
//! Stateless: `base64url(random (16) ‖ expiry (8, big-endian) ‖ tag (16))`, the tag an
//! HMAC under a key derived from the pepper. Not single-use: the conflict flow sends the
//! same token to `/link` and then `/signin` (docs/SERVER.md → Sign in with Apple / Google).
//!
//! The claim may hold the nonce itself (Google, Apple JS) or its SHA-256 (hex or
//! base64url): Apple's native SDK convention is to hash the nonce before handing it over.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::auth::{random_bytes, AuthKeys};

type HmacSha256 = Hmac<Sha256>;

const RANDOM_BYTES: usize = 16;
const TAG_BYTES: usize = 16;
const RAW_BYTES: usize = RANDOM_BYTES + 8 + TAG_BYTES;
const CONTEXT: &[u8] = b"identity/nonce/v1";

pub struct NonceKeys {
    key: [u8; 32],
    ttl_secs: i64,
}

impl std::fmt::Debug for NonceKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NonceKeys").finish_non_exhaustive()
    }
}

impl NonceKeys {
    pub fn new(keys: &AuthKeys, ttl_secs: u64) -> Self {
        Self {
            key: keys.derive_key(CONTEXT),
            ttl_secs: i64::try_from(ttl_secs).unwrap_or(i64::MAX),
        }
    }

    /// A new nonce and its expiry.
    pub fn issue(&self, now: i64) -> (String, i64) {
        let exp = now.saturating_add(self.ttl_secs);
        let mut raw = Vec::with_capacity(RAW_BYTES);
        raw.extend_from_slice(&random_bytes::<RANDOM_BYTES>());
        raw.extend_from_slice(&exp.to_be_bytes());
        let tag = self.tag(&raw);
        raw.extend_from_slice(&tag);
        (URL_SAFE_NO_PAD.encode(raw), exp)
    }

    /// Whether `nonce` was issued here and has not expired at `now`.
    pub fn valid(&self, nonce: &str, now: i64) -> bool {
        let Ok(raw) = URL_SAFE_NO_PAD.decode(nonce) else {
            return false;
        };
        if raw.len() != RAW_BYTES {
            return false;
        }
        let (body, tag) = raw.split_at(RANDOM_BYTES + 8);
        if !bool::from(self.tag(body).as_slice().ct_eq(tag)) {
            return false;
        }
        let mut exp = [0u8; 8];
        exp.copy_from_slice(&body[RANDOM_BYTES..]);
        now < i64::from_be_bytes(exp)
    }

    fn tag(&self, body: &[u8]) -> [u8; TAG_BYTES] {
        let mut mac = HmacSha256::new_from_slice(&self.key).expect("HMAC takes any key length");
        mac.update(body);
        let full = mac.finalize().into_bytes();
        let mut t = [0u8; TAG_BYTES];
        t.copy_from_slice(&full[..TAG_BYTES]);
        t
    }
}

/// Whether a token's `nonce` claim is `nonce` itself or its SHA-256 (hex, either case, or
/// base64url).
pub fn claim_matches(claim: &str, nonce: &str) -> bool {
    if bool::from(claim.as_bytes().ct_eq(nonce.as_bytes())) {
        return true;
    }
    let digest = Sha256::digest(nonce.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let b64 = URL_SAFE_NO_PAD.encode(digest);
    claim.eq_ignore_ascii_case(&hex) || claim == b64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, Secret};

    fn keys(pepper: &str) -> NonceKeys {
        let mut c = Config::default();
        c.auth.jwt_secret = Secret::new("j".repeat(40));
        c.auth.device_secret_pepper = Secret::new(pepper);
        NonceKeys::new(&AuthKeys::from_config(&c), 600)
    }

    #[test]
    fn issue_verify_expire_tamper() {
        let k = keys(&"p".repeat(40));
        let (n, exp) = k.issue(1_000);
        assert_eq!(exp, 1_600);
        assert!(k.valid(&n, 1_000));
        assert!(k.valid(&n, 1_599));
        assert!(!k.valid(&n, 1_600));
        assert!(!keys(&"q".repeat(40)).valid(&n, 1_000));
        let mut raw = URL_SAFE_NO_PAD.decode(&n).unwrap();
        raw[RANDOM_BYTES + 7] ^= 0x7f; // push the expiry out
        assert!(!k.valid(&URL_SAFE_NO_PAD.encode(&raw), 1_000));
        assert!(!k.valid("", 1_000));
        assert!(!k.valid("not base64 !", 1_000));
        assert_ne!(k.issue(1_000).0, n);
    }

    #[test]
    fn claim_forms() {
        let n = "abc-nonce";
        let d = Sha256::digest(n.as_bytes());
        let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
        assert!(claim_matches(n, n));
        assert!(claim_matches(&hex, n));
        assert!(claim_matches(&hex.to_uppercase(), n));
        assert!(claim_matches(&URL_SAFE_NO_PAD.encode(d), n));
        assert!(!claim_matches("abc-nonc", n));
        assert!(!claim_matches("", n));
    }
}
