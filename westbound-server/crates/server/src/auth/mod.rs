//! Device accounts, access tokens (JWT HS256), rotating refresh tokens, and the
//! authentication used by HTTP routes and the WebSocket gateway.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and authentication";
//! docs/MULTIPLAYER_PLAN.md MP-D2 (device accounts only for now).
//!
//! **Secrets and what is stored**
//! - Device secret: 32 random bytes, base64url, returned once. Stored as
//!   HMAC-SHA256(pepper, secret). The secret has 256 bits of entropy, so a slow
//!   password hash (argon2) would add nothing against brute force, while costing
//!   CPU on every login on a 1-vCPU budget and opening a CPU-exhaustion vector. The
//!   pepper (`auth.device_secret_pepper`, not in the database) means a leaked
//!   database alone cannot even test a guess. Compared in constant time.
//! - Refresh token: 32 random bytes, base64url. Stored as SHA-256(token) and looked
//!   up by that hash (a lookup timing leak reveals nothing about a preimage).
//! - Access token: JWT HS256 signed with `auth.jwt_secret`; claims `sub` (account
//!   id as a decimal string), `iat`, `exp`, `jti`, `ver` (token version), `iss`,
//!   `aud`. `ver` must match `accounts.token_version`, so bumping it (logout from
//!   all devices, deletion) revokes every outstanding access token at once.
//!
//! Nothing here logs a token, secret or IP.

pub mod routes;

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use axum::http::{header, StatusCode};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use subtle::ConstantTimeEq;

use crate::app::AppState;
use crate::config::Config;
use crate::error::ApiError;

/// Random bytes in a device secret and a refresh token.
pub const SECRET_BYTES: usize = 32;
/// Length of their base64url (unpadded) form.
pub const SECRET_B64_LEN: usize = 43;
/// JWT `iss` and `aud`.
pub const ISSUER: &str = "westbound";
pub const AUDIENCE: &str = "westbound-api";
/// Longest access token accepted (the protocol's `Hello` cap).
pub const MAX_ACCESS_TOKEN_BYTES: usize = protocol::types::MAX_TOKEN_BYTES;
/// Random bytes in a `jti` and a refresh-token family id.
const ID_BYTES: usize = 16;
/// Development-only secrets used when `server.env = "dev"` leaves them empty. Public:
/// never valid outside dev (config validation requires real ones there).
const DEV_JWT_SECRET: &str = "westbound-dev-only-jwt-secret-not-for-production";
const DEV_PEPPER: &str = "westbound-dev-only-device-pepper-not-for-production";
/// Domain separation for the device-secret HMAC.
const DEVICE_SECRET_CONTEXT: &[u8] = b"westbound/device-secret/v1\0";
/// Domain separation for log-safe IP tags.
const IP_TAG_CONTEXT: &[u8] = b"westbound/ip-tag/v1\0";
/// Bytes of the IP tag shown in logs (hex).
const IP_TAG_BYTES: usize = 6;

type HmacSha256 = Hmac<Sha256>;

/// Access-token claims.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccessClaims {
    /// Account id, decimal string (docs/PROTOCOL.md: account ids in JSON are strings).
    pub sub: String,
    pub iat: i64,
    pub exp: i64,
    pub jti: String,
    /// `accounts.token_version` when issued.
    pub ver: i64,
    pub iss: String,
    pub aud: String,
}

/// A verified access token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerifiedToken {
    pub account_id: i64,
    pub token_version: i64,
    pub expires_at: i64,
}

/// Why an access token was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TokenError {
    #[error("malformed or badly signed token")]
    Invalid,
    #[error("token expired")]
    Expired,
}

/// Signing keys, the pepper and token lifetimes, built once from the config.
pub struct AuthKeys {
    encoding: EncodingKey,
    decoding: DecodingKey,
    validation: Validation,
    pepper: Vec<u8>,
    pub access_ttl_secs: i64,
    pub refresh_ttl_secs: i64,
    pub rename_cooldown_secs: i64,
}

impl std::fmt::Debug for AuthKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthKeys").finish_non_exhaustive()
    }
}

impl AuthKeys {
    /// From a validated config. In `dev`, empty secrets use the public dev values.
    pub fn from_config(cfg: &Config) -> Self {
        let a = &cfg.auth;
        let pick = |s: &crate::config::Secret, dev: &'static str| -> Vec<u8> {
            if s.is_empty() {
                assert!(cfg.is_dev(), "auth secrets are required outside dev");
                dev.as_bytes().to_vec()
            } else {
                s.expose().as_bytes().to_vec()
            }
        };
        let jwt = pick(&a.jwt_secret, DEV_JWT_SECRET);
        let pepper = pick(&a.device_secret_pepper, DEV_PEPPER);
        let mut validation = Validation::new(Algorithm::HS256);
        // Expiry is checked against the injected clock in `verify`.
        validation.validate_exp = false;
        validation.set_issuer(&[ISSUER]);
        validation.set_audience(&[AUDIENCE]);
        validation.set_required_spec_claims(&["exp", "iat", "sub", "iss", "aud"]);
        Self {
            encoding: EncodingKey::from_secret(&jwt),
            decoding: DecodingKey::from_secret(&jwt),
            validation,
            pepper,
            access_ttl_secs: secs(a.access_token_ttl_secs),
            refresh_ttl_secs: secs(a.refresh_token_ttl_secs),
            rename_cooldown_secs: secs(a.rename_cooldown_secs),
        }
    }

    /// Signs an access token; returns it with its expiry.
    pub fn issue_access(
        &self,
        account_id: i64,
        token_version: i64,
        now: i64,
    ) -> anyhow::Result<(String, i64)> {
        let exp = now + self.access_ttl_secs;
        let claims = AccessClaims {
            sub: account_id.to_string(),
            iat: now,
            exp,
            jti: b64(&random_bytes::<ID_BYTES>()),
            ver: token_version,
            iss: ISSUER.into(),
            aud: AUDIENCE.into(),
        };
        let token = jsonwebtoken::encode(&Header::new(Algorithm::HS256), &claims, &self.encoding)?;
        Ok((token, exp))
    }

    /// Checks signature, algorithm, issuer, audience, subject and expiry at `now`.
    /// No database access: the gateway and the rate limiter call it directly.
    pub fn verify(&self, token: &str, now: i64) -> Result<VerifiedToken, TokenError> {
        let v = self.verify_signature(token)?;
        if now >= v.expires_at {
            return Err(TokenError::Expired);
        }
        Ok(v)
    }

    /// Like `verify` but ignores expiry (rate-limit keys only).
    pub fn verify_signature(&self, token: &str) -> Result<VerifiedToken, TokenError> {
        if token.is_empty() || token.len() > MAX_ACCESS_TOKEN_BYTES {
            return Err(TokenError::Invalid);
        }
        let data = jsonwebtoken::decode::<AccessClaims>(token, &self.decoding, &self.validation)
            .map_err(|_| TokenError::Invalid)?;
        let c = data.claims;
        let account_id = parse_account_id(&c.sub).ok_or(TokenError::Invalid)?;
        Ok(VerifiedToken {
            account_id,
            token_version: c.ver,
            expires_at: c.exp,
        })
    }

    /// HMAC-SHA256(pepper, context ‖ secret): the stored form of a device secret.
    pub fn hash_device_secret(&self, secret: &[u8]) -> [u8; 32] {
        let mut mac = HmacSha256::new_from_slice(&self.pepper).expect("HMAC takes any key length");
        mac.update(DEVICE_SECRET_CONTEXT);
        mac.update(secret);
        mac.finalize().into_bytes().into()
    }

    /// A log-safe stand-in for a client IP: a truncated HMAC under the pepper, stable
    /// across the process (so one client's lines can be correlated) but not reversible
    /// by enumerating addresses without the pepper.
    pub fn ip_tag(&self, ip: std::net::IpAddr) -> String {
        let mut mac = HmacSha256::new_from_slice(&self.pepper).expect("HMAC takes any key length");
        mac.update(IP_TAG_CONTEXT);
        mac.update(ip.to_string().as_bytes());
        let tag = mac.finalize().into_bytes();
        tag[..IP_TAG_BYTES]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    /// Constant-time check of a presented device secret against a stored hash.
    pub fn device_secret_matches(&self, secret: &[u8], stored: &[u8]) -> bool {
        let h = self.hash_device_secret(secret);
        bool::from(h.as_slice().ct_eq(stored))
    }
}

fn secs(v: u64) -> i64 {
    i64::try_from(v).unwrap_or(i64::MAX)
}

/// Account ids are positive SQLite rowids (≤ i64::MAX), decimal strings in JSON.
pub fn parse_account_id(s: &str) -> Option<i64> {
    if s.is_empty() || s.len() > 19 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse::<i64>().ok().filter(|&id| id > 0)
}

/// Cryptographically random bytes (OS RNG).
pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).expect("OS random number generator");
    b
}

/// A uniformly distributed random number below `n` (n > 0).
pub fn random_below(n: u32) -> u32 {
    let zone = u32::MAX - (u32::MAX % n);
    loop {
        let v = u32::from_le_bytes(random_bytes::<4>());
        if v < zone {
            return v % n;
        }
    }
}

pub fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Decodes a base64url secret or refresh token of exactly `SECRET_BYTES` bytes.
pub fn decode_secret(s: &str) -> Option<[u8; SECRET_BYTES]> {
    if s.len() != SECRET_B64_LEN {
        return None;
    }
    URL_SAFE_NO_PAD.decode(s).ok()?.try_into().ok()
}

/// SHA-256 of a refresh token's bytes: its stored form and lookup key.
pub fn hash_refresh_token(token: &[u8]) -> [u8; 32] {
    Sha256::digest(token).into()
}

/// A new refresh-token family id (one per device session).
pub fn new_family_id() -> [u8; ID_BYTES] {
    random_bytes::<ID_BYTES>()
}

// ---------------------------------------------------------------------------------------------
// Authentication: HTTP extractor and the gateway's entry point
// ---------------------------------------------------------------------------------------------

/// An authenticated request: the account behind a valid, current access token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Authed {
    pub account_id: i64,
    pub token_version: i64,
}

/// Why authentication failed.
#[derive(Debug, thiserror::Error)]
pub enum AuthFailure {
    #[error("missing bearer token")]
    Missing,
    #[error("invalid token")]
    Invalid,
    #[error("token expired")]
    Expired,
    /// Valid signature, but the account is gone or its token version moved on.
    #[error("token revoked")]
    Revoked,
    #[error("account banned until {0}")]
    Banned(i64),
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),
}

impl AuthFailure {
    /// The handshake's view (docs/PROTOCOL.md §5: rejected token → `auth_failed`,
    /// banned → `banned`).
    pub fn to_handshake(&self) -> protocol::handshake::AuthError {
        match self {
            AuthFailure::Banned(_) => protocol::handshake::AuthError::Banned,
            _ => protocol::handshake::AuthError::Invalid,
        }
    }
}

impl From<AuthFailure> for ApiError {
    fn from(f: AuthFailure) -> Self {
        match f {
            AuthFailure::Missing => ApiError::unauthorized(
                "unauthorized",
                "Send the access token as `Authorization: Bearer <token>`.",
            ),
            AuthFailure::Invalid => {
                ApiError::unauthorized("invalid_token", "Invalid access token.")
            }
            AuthFailure::Expired => {
                ApiError::unauthorized("token_expired", "Access token expired; refresh it.")
            }
            AuthFailure::Revoked => {
                ApiError::unauthorized("token_revoked", "Access token revoked; sign in again.")
            }
            AuthFailure::Banned(until) => ApiError::banned(until),
            AuthFailure::Db(e) => e.into(),
        }
    }
}

/// The ban end if `banned_until` is set and still in the future.
pub fn active_ban(banned_until: Option<i64>, now: i64) -> Option<i64> {
    banned_until.filter(|&t| t > now)
}

/// Validates an access token and checks the account: it exists, the token version
/// is current and (unless `allow_banned`) it is not banned. One indexed lookup.
pub async fn authenticate(
    db: &SqlitePool,
    keys: &AuthKeys,
    token: &str,
    now: i64,
    allow_banned: bool,
) -> Result<Authed, AuthFailure> {
    let v = keys.verify(token, now).map_err(|e| match e {
        TokenError::Expired => AuthFailure::Expired,
        TokenError::Invalid => AuthFailure::Invalid,
    })?;
    let row = sqlx::query!(
        "SELECT token_version, banned_until FROM accounts WHERE id = ?",
        v.account_id
    )
    .fetch_optional(db)
    .await?;
    let Some(row) = row else {
        return Err(AuthFailure::Revoked);
    };
    if row.token_version != v.token_version {
        return Err(AuthFailure::Revoked);
    }
    if !allow_banned {
        if let Some(until) = active_ban(row.banned_until, now) {
            return Err(AuthFailure::Banned(until));
        }
    }
    Ok(Authed {
        account_id: v.account_id,
        token_version: v.token_version,
    })
}

/// The gateway's check of `Hello.access_token`. Await it first, then hand the result
/// to the sync handshake: `handshake.on_message(&msg, |_| result)`.
pub async fn authenticate_hello(
    state: &AppState,
    token: &str,
) -> Result<protocol::AccountId, protocol::handshake::AuthError> {
    let now = state.clock.now();
    match authenticate(&state.db, &state.auth, token, now, false).await {
        Ok(a) => Ok(protocol::AccountId(a.account_id as u64)),
        Err(f) => {
            if let AuthFailure::Db(e) = &f {
                tracing::error!(error = %e, "database error during websocket authentication");
            }
            Err(f.to_handshake())
        }
    }
}

/// The bearer token from `Authorization`, if well-formed.
pub fn bearer_token(parts: &Parts) -> Option<&str> {
    let v = parts.headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = v.split_once(' ')?;
    scheme
        .eq_ignore_ascii_case("bearer")
        .then(|| token.trim())
        .filter(|t| !t.is_empty())
}

async fn extract(parts: &Parts, state: &AppState, allow_banned: bool) -> Result<Authed, ApiError> {
    let token = bearer_token(parts).ok_or(AuthFailure::Missing)?;
    let now = state.clock.now();
    Ok(authenticate(&state.db, &state.auth, token, now, allow_banned).await?)
}

impl FromRequestParts<AppState> for Authed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        extract(parts, state, false).await
    }
}

/// Like [`Authed`] but lets a banned account through (account deletion).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthedAllowBanned(pub Authed);

impl FromRequestParts<AppState> for AuthedAllowBanned {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        extract(parts, state, true).await.map(AuthedAllowBanned)
    }
}

/// Authentication when a token is sent, none otherwise (public reads that add the
/// caller's own data, e.g. `GET /api/v1/boards/{board}`). A token that is sent but
/// invalid, expired or banned is still refused, so clients learn to refresh it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OptionalAuthed(pub Option<Authed>);

impl FromRequestParts<AppState> for OptionalAuthed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        if !parts.headers.contains_key(header::AUTHORIZATION) {
            return Ok(OptionalAuthed(None));
        }
        extract(parts, state, false)
            .await
            .map(|a| OptionalAuthed(Some(a)))
    }
}

/// 501 for the Apple / Google routes until MP-D2's developer setup lands.
pub fn provider_not_enabled(provider: &str) -> ApiError {
    ApiError::new(
        StatusCode::NOT_IMPLEMENTED,
        "provider_not_enabled",
        format!("Sign-in with {provider} is not enabled on this server yet."),
    )
}
