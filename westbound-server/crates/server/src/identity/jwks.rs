//! A provider's signing keys (JWKS), fetched over HTTPS and cached (N11).
//!
//! - **Caching:** the keys live for the response's `Cache-Control: max-age`, clamped to
//!   `identity.jwks_cache_min_secs ..= jwks_cache_max_secs` (Google sends about 6 h; Apple
//!   none, so the minimum applies).
//! - **Rotation:** a token signed with a `kid` the cache does not hold refetches the set,
//!   at most once per `identity.jwks_refetch_min_secs` (a stream of tokens with made-up
//!   kids cannot turn into a stream of fetches).
//! - **Outages:** when a refetch fails, the old keys keep working (stale-if-error) and
//!   the next try waits `jwks_refetch_min_secs`; with no usable key the caller gets
//!   `Unavailable` (503 `provider_unavailable`), never a false "invalid token".
//! - One fetch at a time (an async mutex), on the injected wall clock (tests move it).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use jsonwebtoken::jwk::Jwk;
use jsonwebtoken::DecodingKey;

use crate::clock::Clock;

/// Largest JWKS document read (both providers' are about 1–2 KB).
const MAX_JWKS_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeyError {
    /// The set was fetched and has no such key.
    #[error("unknown key id")]
    Unknown,
    /// No usable key: the provider could not be reached.
    #[error("signing keys unavailable: {0}")]
    Unavailable(String),
}

pub struct JwksParams {
    pub min_ttl_secs: i64,
    pub max_ttl_secs: i64,
    pub refetch_min_secs: i64,
}

struct State {
    keys: HashMap<String, DecodingKey>,
    /// Keys are fresh before this (unix seconds).
    fresh_until: i64,
    /// The last fetch attempt (None = never).
    last_attempt: Option<i64>,
}

pub struct Jwks {
    url: String,
    http: reqwest::Client,
    clock: Arc<dyn Clock>,
    params: JwksParams,
    state: tokio::sync::Mutex<State>,
    /// Fetch attempts (tests, logs).
    pub fetches: AtomicU64,
}

impl std::fmt::Debug for Jwks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Jwks")
            .field("url", &self.url)
            .finish_non_exhaustive()
    }
}

impl Jwks {
    pub fn new(
        url: &str,
        http: reqwest::Client,
        clock: Arc<dyn Clock>,
        params: JwksParams,
    ) -> Self {
        Self {
            url: url.to_string(),
            http,
            clock,
            params,
            state: tokio::sync::Mutex::new(State {
                keys: HashMap::new(),
                fresh_until: i64::MIN,
                last_attempt: None,
            }),
            fetches: AtomicU64::new(0),
        }
    }

    /// The decoding key for `kid` (see the module docs for when this fetches).
    pub async fn key(&self, kid: &str) -> Result<DecodingKey, KeyError> {
        let now = self.clock.now();
        let mut st = self.state.lock().await;
        let fresh = now < st.fresh_until;
        if fresh {
            if let Some(k) = st.keys.get(kid) {
                return Ok(k.clone());
            }
        }
        let may_fetch = !fresh
            || st
                .last_attempt
                .is_none_or(|t| now.saturating_sub(t) >= self.params.refetch_min_secs);
        if may_fetch {
            st.last_attempt = Some(now);
            self.fetches.fetch_add(1, Ordering::Relaxed);
            match self.fetch().await {
                Ok((keys, ttl)) => {
                    st.keys = keys;
                    st.fresh_until = now.saturating_add(ttl);
                }
                Err(e) => {
                    tracing::warn!(url = %self.url, error = %e, "JWKS fetch failed");
                    // Keep the old keys; try again after the refetch interval.
                    st.fresh_until = now.saturating_add(self.params.refetch_min_secs);
                    return st
                        .keys
                        .get(kid)
                        .cloned()
                        .ok_or(KeyError::Unavailable(e.to_string()));
                }
            }
        }
        st.keys.get(kid).cloned().ok_or(KeyError::Unknown)
    }

    async fn fetch(&self) -> anyhow::Result<(HashMap<String, DecodingKey>, i64)> {
        let resp = self.http.get(&self.url).send().await?;
        let status = resp.status();
        if !status.is_success() {
            anyhow::bail!("HTTP {status}");
        }
        let max_age = resp
            .headers()
            .get(reqwest::header::CACHE_CONTROL)
            .and_then(|v| v.to_str().ok())
            .and_then(parse_max_age);
        let body = super::read_limited(resp, MAX_JWKS_BYTES).await?;
        let keys = parse_jwks(&body)?;
        if keys.is_empty() {
            anyhow::bail!("no usable RSA keys in the set");
        }
        let ttl = max_age
            .unwrap_or(self.params.min_ttl_secs)
            .clamp(self.params.min_ttl_secs, self.params.max_ttl_secs);
        Ok((keys, ttl))
    }
}

/// The RSA signing keys of a JWKS document by `kid`. Keys of other types, without a
/// `kid`, marked for encryption or unparseable are skipped.
pub fn parse_jwks(body: &[u8]) -> anyhow::Result<HashMap<String, DecodingKey>> {
    let doc: serde_json::Value = serde_json::from_slice(body)?;
    let list = doc
        .get("keys")
        .and_then(|k| k.as_array())
        .ok_or_else(|| anyhow::anyhow!("no `keys` array"))?;
    let mut out = HashMap::new();
    for v in list {
        if v.get("kty").and_then(|k| k.as_str()) != Some("RSA") {
            continue;
        }
        if v.get("use")
            .and_then(|u| u.as_str())
            .is_some_and(|u| u != "sig")
        {
            continue;
        }
        let Ok(jwk) = serde_json::from_value::<Jwk>(v.clone()) else {
            continue;
        };
        let Some(kid) = jwk.common.key_id.clone() else {
            continue;
        };
        if let Ok(key) = DecodingKey::from_jwk(&jwk) {
            out.insert(kid, key);
        }
    }
    Ok(out)
}

/// `max-age=N` from a Cache-Control value.
pub fn parse_max_age(v: &str) -> Option<i64> {
    v.split(',').find_map(|part| {
        let (k, n) = part.trim().split_once('=')?;
        if k.trim().eq_ignore_ascii_case("max-age") {
            n.trim().trim_matches('"').parse().ok()
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_age() {
        assert_eq!(
            parse_max_age("public, max-age=21600, must-revalidate"),
            Some(21_600)
        );
        assert_eq!(parse_max_age("Max-Age=60"), Some(60));
        assert_eq!(parse_max_age("no-cache"), None);
        assert_eq!(parse_max_age("max-age=x"), None);
    }

    #[test]
    fn skips_unusable_keys() {
        let body = br#"{"keys":[
            {"kty":"EC","kid":"ec","crv":"P-256","x":"AA","y":"AA"},
            {"kty":"RSA","n":"sXch","e":"AQAB"},
            {"kty":"RSA","kid":"enc","use":"enc","n":"sXch","e":"AQAB"},
            {"kty":"RSA","kid":"ok","use":"sig","alg":"RS256","n":"sXch","e":"AQAB"}
        ]}"#;
        let keys = parse_jwks(body).unwrap();
        assert_eq!(keys.len(), 1);
        assert!(keys.contains_key("ok"));
        assert!(parse_jwks(b"{}").is_err());
        assert!(parse_jwks(b"nope").is_err());
    }
}
