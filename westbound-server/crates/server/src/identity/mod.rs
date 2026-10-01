//! N11: Sign in with Apple / Google. ID-token verification against the providers'
//! published keys, sign-in nonces, Apple token revocation, and the routes that sign in,
//! link and unlink. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and
//! authentication" (Sign in with Apple / Google, account deletion with Apple revocation);
//! docs/MULTIPLAYER_PLAN.md MP-D2 (deferred until now); docs/SERVER.md → "Sign in with
//! Apple / Google".
//!
//! **What an ID token must be** (`Verifier::verify`):
//! - a JWT signed RS256 with a key from the provider's JWKS (`jwks.rs`: cached, rotated);
//! - `iss` = the provider (Google: `https://accounts.google.com` or `accounts.google.com`;
//!   Apple: `https://appleid.apple.com`);
//! - `aud` = one of our client ids for that provider (`identity.*_client_ids`: web, iOS,
//!   Android);
//! - `exp` in the future and `iat` not in the future, on the server clock with
//!   `identity.clock_skew_secs` of leeway;
//! - `nonce` = a nonce this server issued, unexpired (or its SHA-256; `nonce.rs`), when
//!   `identity.require_nonce` (the default);
//! - a non-empty `sub`: the identity, stored in `accounts.apple_sub` / `google_sub`.
//!
//! **Email.** Neither the address nor the name is stored. A masked hint
//! (`j***@gmail.com`) is kept for the account screen when the provider says the address
//! is verified. Apple's `email_verified` / `is_private_email` arrive as booleans or the
//! strings `"true"` / `"false"`; a Hide My Email relay address
//! (`…@privaterelay.appleid.com`, or `is_private_email`) shows as "private" with no hint.
//! Apple sends the email only in the token (the name only once, to the client): nothing
//! here depends on it.
//!
//! A provider with no client ids is disabled: its routes answer 501
//! `provider_not_enabled`, exactly the MP-D2 stubs.

pub mod apple;
pub mod jwks;
pub mod nonce;
pub mod routes;
pub mod seal;
pub mod store;

use std::sync::Arc;
use std::time::Duration;

use jsonwebtoken::errors::ErrorKind;
use jsonwebtoken::{Algorithm, Validation};
use serde::{Deserialize, Deserializer, Serialize};

use crate::auth::AuthKeys;
use crate::clock::Clock;
use crate::config::{Config, IdentityConfig};
use apple::AppleClient;
use jwks::{Jwks, JwksParams, KeyError};
use nonce::NonceKeys;
use seal::Sealer;

/// The domain Apple's Hide My Email relay addresses use.
const APPLE_RELAY_DOMAIN: &str = "privaterelay.appleid.com";
/// The masked part of an email hint.
const HINT_MASK: &str = "***";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Apple,
    Google,
}

impl Provider {
    pub const ALL: [Provider; 2] = [Provider::Apple, Provider::Google];

    /// `apple` / `google` (paths, the database, JSON).
    pub fn as_str(self) -> &'static str {
        match self {
            Provider::Apple => "apple",
            Provider::Google => "google",
        }
    }

    /// `Apple` / `Google` (messages).
    pub fn title(self) -> &'static str {
        match self {
            Provider::Apple => "Apple",
            Provider::Google => "Google",
        }
    }

    pub fn parse(s: &str) -> Option<Provider> {
        match s {
            "apple" => Some(Provider::Apple),
            "google" => Some(Provider::Google),
            _ => None,
        }
    }
}

/// What a verified ID token says about the player.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedIdentity {
    pub provider: Provider,
    pub sub: String,
    /// The client id the token was issued to (the matching `aud`).
    pub client_id: String,
    /// `j***@gmail.com`; None for no (verified) email or a private relay address.
    pub email_hint: Option<String>,
    pub private_email: bool,
}

/// Why an ID token was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IdTokenError {
    #[error("not a JWT, or too long")]
    Malformed,
    #[error("signature, issuer, audience or claims rejected")]
    Invalid,
    #[error("the ID token expired")]
    Expired,
    #[error("the nonce is missing, unknown, expired or does not match")]
    Nonce,
    #[error("the provider's signing keys are unavailable")]
    Unavailable,
}

/// A boolean claim that may arrive as `true` or `"true"` (Apple).
fn flexible_bool<'de, D: Deserializer<'de>>(d: D) -> Result<Option<bool>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum B {
        Bool(bool),
        Str(String),
        Other(serde::de::IgnoredAny),
    }
    Ok(match Option::<B>::deserialize(d)? {
        Some(B::Bool(b)) => Some(b),
        Some(B::Str(s)) => match s.as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        },
        _ => None,
    })
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum Aud {
    One(String),
    Many(Vec<String>),
}

#[derive(Debug, Deserialize)]
struct IdClaims {
    sub: String,
    aud: Aud,
    exp: i64,
    #[serde(default)]
    iat: Option<i64>,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    email: Option<String>,
    #[serde(default, deserialize_with = "flexible_bool")]
    email_verified: Option<bool>,
    #[serde(default, deserialize_with = "flexible_bool")]
    is_private_email: Option<bool>,
}

/// One provider's ID-token verifier.
pub struct Verifier {
    pub provider: Provider,
    pub jwks: Jwks,
    validation: Validation,
    client_ids: Vec<String>,
    skew: i64,
    max_token_bytes: usize,
}

impl std::fmt::Debug for Verifier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Verifier")
            .field("provider", &self.provider)
            .finish_non_exhaustive()
    }
}

/// The nonce rules for one verification.
pub struct NonceCheck<'a> {
    pub keys: &'a NonceKeys,
    pub required: bool,
    /// The nonce the client sent with the token.
    pub presented: Option<&'a str>,
}

impl Verifier {
    pub fn new(
        provider: Provider,
        issuers: &[String],
        client_ids: &[String],
        jwks: Jwks,
        cfg: &IdentityConfig,
    ) -> Self {
        let mut validation = Validation::new(Algorithm::RS256);
        // Expiry is checked against the injected clock below.
        validation.validate_exp = false;
        validation.validate_nbf = false;
        validation.set_issuer(issuers);
        validation.set_audience(client_ids);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        Self {
            provider,
            jwks,
            validation,
            client_ids: client_ids.to_vec(),
            skew: i64::try_from(cfg.clock_skew_secs).unwrap_or(i64::MAX),
            max_token_bytes: cfg.max_id_token_bytes,
        }
    }

    /// Verifies `token` at `now` (see the module docs for every check).
    pub async fn verify(
        &self,
        token: &str,
        nonce: NonceCheck<'_>,
        now: i64,
    ) -> Result<VerifiedIdentity, IdTokenError> {
        if token.is_empty() || token.len() > self.max_token_bytes {
            return Err(IdTokenError::Malformed);
        }
        let header = jsonwebtoken::decode_header(token).map_err(|_| IdTokenError::Malformed)?;
        if header.alg != Algorithm::RS256 {
            return Err(IdTokenError::Invalid);
        }
        let kid = header.kid.ok_or(IdTokenError::Invalid)?;
        let key = self.jwks.key(&kid).await.map_err(|e| match e {
            KeyError::Unknown => IdTokenError::Invalid,
            KeyError::Unavailable(_) => IdTokenError::Unavailable,
        })?;
        let data =
            jsonwebtoken::decode::<IdClaims>(token, &key, &self.validation).map_err(|e| match e
                .kind()
            {
                ErrorKind::InvalidToken | ErrorKind::Base64(_) | ErrorKind::Json(_) => {
                    IdTokenError::Malformed
                }
                _ => IdTokenError::Invalid,
            })?;
        let c = data.claims;
        if c.sub.is_empty() || c.sub.len() > store::MAX_SUB_BYTES {
            return Err(IdTokenError::Invalid);
        }
        if now >= c.exp.saturating_add(self.skew) {
            return Err(IdTokenError::Expired);
        }
        if c.iat.is_some_and(|iat| iat > now.saturating_add(self.skew)) {
            return Err(IdTokenError::Invalid);
        }
        // A presented nonce must be ours, unexpired and in the token; none is accepted
        // only when nonces are optional.
        let nonce_ok = match nonce.presented {
            Some(p) => c
                .nonce
                .as_deref()
                .is_some_and(|claim| nonce.keys.valid(p, now) && nonce::claim_matches(claim, p)),
            None => !nonce.required,
        };
        if !nonce_ok {
            return Err(IdTokenError::Nonce);
        }
        let client_id = match &c.aud {
            Aud::One(a) => Some(a.clone()),
            Aud::Many(v) => v.iter().find(|a| self.client_ids.contains(a)).cloned(),
        }
        .ok_or(IdTokenError::Invalid)?;
        let (email_hint, private_email) =
            email_hint(c.email.as_deref(), c.email_verified, c.is_private_email);
        Ok(VerifiedIdentity {
            provider: self.provider,
            sub: c.sub,
            client_id,
            email_hint,
            private_email,
        })
    }
}

/// The hint and the private flag for an email claim (see the module docs).
pub fn email_hint(
    email: Option<&str>,
    verified: Option<bool>,
    private: Option<bool>,
) -> (Option<String>, bool) {
    let Some(email) = email.map(str::trim).filter(|e| !e.is_empty()) else {
        return (None, private == Some(true));
    };
    let Some((local, domain)) = email.rsplit_once('@') else {
        return (None, private == Some(true));
    };
    let domain = domain.to_ascii_lowercase();
    if private == Some(true) || domain == APPLE_RELAY_DOMAIN {
        return (None, true);
    }
    if verified == Some(false) || domain.is_empty() {
        return (None, false);
    }
    let first: String = local.chars().take(1).collect();
    if first.is_empty() {
        return (None, false);
    }
    (Some(format!("{first}{HINT_MASK}@{domain}")), false)
}

/// The identity providers, built once from the config.
pub struct Identity {
    pub apple: Option<Verifier>,
    pub google: Option<Verifier>,
    /// Apple's token / revoke endpoints (None without the Apple key).
    pub apple_client: Option<AppleClient>,
    pub nonces: NonceKeys,
    pub sealer: Sealer,
    pub require_nonce: bool,
    pub max_device_secrets: i64,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("apple", &self.apple.is_some())
            .field("google", &self.google.is_some())
            .field("apple_client", &self.apple_client.is_some())
            .finish_non_exhaustive()
    }
}

impl Identity {
    pub fn from_config(
        cfg: &Config,
        keys: &AuthKeys,
        clock: Arc<dyn Clock>,
    ) -> anyhow::Result<Self> {
        let i = &cfg.identity;
        let http = reqwest::Client::builder()
            .timeout(Duration::from_millis(i.http_timeout_ms))
            .user_agent(concat!("westbound-server/", env!("CARGO_PKG_VERSION")))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        let secs = |v: u64| i64::try_from(v).unwrap_or(i64::MAX);
        let params = || JwksParams {
            min_ttl_secs: secs(i.jwks_cache_min_secs),
            max_ttl_secs: secs(i.jwks_cache_max_secs),
            refetch_min_secs: secs(i.jwks_refetch_min_secs),
        };
        let google = i.google_enabled().then(|| {
            Verifier::new(
                Provider::Google,
                &i.google_issuers,
                &i.google_client_ids,
                Jwks::new(&i.google_jwks_url, http.clone(), clock.clone(), params()),
                i,
            )
        });
        let apple = i.apple_enabled().then(|| {
            Verifier::new(
                Provider::Apple,
                std::slice::from_ref(&i.apple_issuer),
                &i.apple_client_ids,
                Jwks::new(&i.apple_jwks_url, http.clone(), clock.clone(), params()),
                i,
            )
        });
        Ok(Self {
            apple,
            google,
            apple_client: AppleClient::from_config(i, http)?,
            nonces: NonceKeys::new(keys, i.nonce_ttl_secs),
            sealer: Sealer::new(keys),
            require_nonce: i.require_nonce,
            max_device_secrets: i64::from(i.max_device_secrets),
        })
    }

    /// The provider's verifier (None: disabled).
    pub fn verifier(&self, p: Provider) -> Option<&Verifier> {
        match p {
            Provider::Apple => self.apple.as_ref(),
            Provider::Google => self.google.as_ref(),
        }
    }

    /// Exchanges an Apple authorization code for the refresh token kept for revocation,
    /// sealed. Best effort: None without the key or the code, or when Apple refuses (logged;
    /// the sign-in goes on).
    pub async fn apple_refresh_sealed(
        &self,
        client_id: &str,
        code: Option<&str>,
        now: i64,
    ) -> Option<Vec<u8>> {
        let (client, code) = (self.apple_client.as_ref()?, code.filter(|c| !c.is_empty())?);
        match client.exchange_code(client_id, code, now).await {
            Ok(Some(rt)) => Some(self.sealer.seal(rt.as_bytes())),
            Ok(None) => {
                tracing::warn!("Apple code exchange returned no refresh token");
                None
            }
            Err(e) => {
                tracing::warn!(error = %e, "Apple code exchange failed; this link cannot be revoked later");
                None
            }
        }
    }

    /// Revokes a sealed Apple refresh token (account deletion, unlink). Best effort: a
    /// no-op without the key; failures are logged. Returns whether Apple accepted it.
    pub async fn revoke_apple(&self, link: &store::AppleGrant, now: i64) -> bool {
        let Some(client) = self.apple_client.as_ref() else {
            tracing::info!("Apple grant not revoked: no Apple key configured");
            return false;
        };
        let Some(token) = self.sealer.open(&link.sealed_refresh) else {
            tracing::warn!("Apple grant not revoked: the stored token does not open");
            return false;
        };
        let token = String::from_utf8_lossy(&token).into_owned();
        match client.revoke(&link.client_id, &token, now).await {
            Ok(()) => {
                tracing::info!("Apple grant revoked");
                true
            }
            Err(e) => {
                tracing::warn!(error = %e, "Apple grant revocation failed");
                false
            }
        }
    }
}

/// Reads a response body up to `max` bytes (larger bodies are an error).
pub(crate) async fn read_limited(
    mut resp: reqwest::Response,
    max: usize,
) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::new();
    while let Some(chunk) = resp.chunk().await? {
        if out.len() + chunk.len() > max {
            anyhow::bail!("response larger than {max} bytes");
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn email_hints() {
        assert_eq!(
            email_hint(Some("Jane.Doe@Gmail.com"), Some(true), None),
            (Some("J***@gmail.com".into()), false)
        );
        assert_eq!(
            email_hint(Some("x@privaterelay.appleid.com"), Some(true), Some(false)),
            (None, true)
        );
        assert_eq!(email_hint(Some("a@b.c"), None, Some(true)), (None, true));
        assert_eq!(email_hint(Some("a@b.c"), Some(false), None), (None, false));
        assert_eq!(email_hint(None, None, Some(true)), (None, true));
        assert_eq!(email_hint(Some("nope"), None, None), (None, false));
        assert_eq!(
            email_hint(Some("ş@x.com"), None, None).0.as_deref(),
            Some("ş***@x.com")
        );
    }

    #[test]
    fn flexible_bools() {
        #[derive(Deserialize)]
        struct T {
            #[serde(default, deserialize_with = "flexible_bool")]
            v: Option<bool>,
        }
        let p = |s: &str| serde_json::from_str::<T>(s).unwrap().v;
        assert_eq!(p(r#"{"v":true}"#), Some(true));
        assert_eq!(p(r#"{"v":"true"}"#), Some(true));
        assert_eq!(p(r#"{"v":"false"}"#), Some(false));
        assert_eq!(p(r#"{"v":"maybe"}"#), None);
        assert_eq!(p(r#"{"v":3}"#), None);
        assert_eq!(p(r#"{}"#), None);
    }

    #[test]
    fn providers() {
        for p in Provider::ALL {
            assert_eq!(Provider::parse(p.as_str()), Some(p));
        }
        assert_eq!(Provider::parse("facebook"), None);
    }
}
