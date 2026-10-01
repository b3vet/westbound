//! Apple's token and revoke endpoints (N11), for the one thing the server needs beyond
//! verifying ID tokens: **revoking** the player's Sign in with Apple grant when they delete
//! their account (App Store Review Guideline 5.1.1(v), Apple's "Revoke tokens" docs) or
//! unlink Apple.
//!
//! Revocation needs a token Apple issued to us. The ID token is not one; the refresh token
//! from exchanging the sign-in's **authorization code** is. So at sign-in or link, when the
//! client sends `authorization_code` and the key is configured, the server exchanges it
//! (`POST /auth/token`) and keeps the refresh token sealed (`seal.rs`). On deletion or
//! unlink it posts that token to `/auth/revoke`. Without the key (or without a code) both
//! steps are skipped: sign-in still works, and revocation is a logged no-op.
//!
//! Both calls authenticate with a **client secret**: a short-lived ES256 JWT signed with
//! the `.p8` key (`kid` = key id; `iss` = team id; `aud` = Apple's issuer; `sub` = the
//! client id the code or token belongs to: the Services ID on the web, the bundle id on
//! iOS). The web flow's code exchange also names the Services ID's return URL.

use std::fmt::Write as _;

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};

use crate::config::IdentityConfig;

/// Client secrets are made per call and live this long (Apple allows up to 6 months).
const CLIENT_SECRET_TTL_SECS: i64 = 300;
/// Largest token response read.
const MAX_RESPONSE_BYTES: usize = 16 * 1024;

#[derive(Serialize)]
struct ClientSecretClaims<'a> {
    iss: &'a str,
    iat: i64,
    exp: i64,
    aud: &'a str,
    sub: &'a str,
}

#[derive(Deserialize)]
struct TokenResponse {
    refresh_token: Option<String>,
}

pub struct AppleClient {
    http: reqwest::Client,
    team_id: String,
    key_id: String,
    key: EncodingKey,
    audience: String,
    token_url: String,
    revoke_url: String,
    web_client_id: String,
    web_redirect_uri: String,
}

impl std::fmt::Debug for AppleClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppleClient")
            .field("team_id", &self.team_id)
            .field("key_id", &self.key_id)
            .finish_non_exhaustive()
    }
}

impl AppleClient {
    /// None when the Apple key is not configured.
    pub fn from_config(
        cfg: &IdentityConfig,
        http: reqwest::Client,
    ) -> anyhow::Result<Option<Self>> {
        if !cfg.apple_key_configured() {
            return Ok(None);
        }
        let pem = cfg
            .apple_private_key_pem()?
            .ok_or_else(|| anyhow::anyhow!("identity.apple_private_key is empty"))?;
        let key = parse_p8(&pem)?;
        Ok(Some(Self {
            http,
            team_id: cfg.apple_team_id.clone(),
            key_id: cfg.apple_key_id.clone(),
            key,
            audience: cfg.apple_issuer.clone(),
            token_url: cfg.apple_token_url.clone(),
            revoke_url: cfg.apple_revoke_url.clone(),
            web_client_id: cfg.apple_web_client().to_string(),
            web_redirect_uri: cfg.apple_web_redirect_uri.clone(),
        }))
    }

    /// The ES256 client secret for `client_id`.
    pub fn client_secret(&self, client_id: &str, now: i64) -> anyhow::Result<String> {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let claims = ClientSecretClaims {
            iss: &self.team_id,
            iat: now,
            exp: now + CLIENT_SECRET_TTL_SECS,
            aud: &self.audience,
            sub: client_id,
        };
        Ok(jsonwebtoken::encode(&header, &claims, &self.key)?)
    }

    /// Exchanges a sign-in's authorization code; returns Apple's refresh token (None when
    /// the answer has none).
    pub async fn exchange_code(
        &self,
        client_id: &str,
        code: &str,
        now: i64,
    ) -> anyhow::Result<Option<String>> {
        let secret = self.client_secret(client_id, now)?;
        let mut form = vec![
            ("client_id", client_id),
            ("client_secret", secret.as_str()),
            ("code", code),
            ("grant_type", "authorization_code"),
        ];
        if client_id == self.web_client_id && !self.web_redirect_uri.is_empty() {
            form.push(("redirect_uri", self.web_redirect_uri.as_str()));
        }
        let resp = self.post(&self.token_url, &form).await?;
        let status = resp.status();
        let body = super::read_limited(resp, MAX_RESPONSE_BYTES).await?;
        if !status.is_success() {
            anyhow::bail!("Apple token endpoint: HTTP {status}: {}", error_code(&body));
        }
        let t: TokenResponse = serde_json::from_slice(&body)?;
        Ok(t.refresh_token)
    }

    /// Revokes a refresh token issued to `client_id`.
    pub async fn revoke(
        &self,
        client_id: &str,
        refresh_token: &str,
        now: i64,
    ) -> anyhow::Result<()> {
        let secret = self.client_secret(client_id, now)?;
        let form = [
            ("client_id", client_id),
            ("client_secret", secret.as_str()),
            ("token", refresh_token),
            ("token_type_hint", "refresh_token"),
        ];
        let resp = self.post(&self.revoke_url, &form).await?;
        let status = resp.status();
        if !status.is_success() {
            let body = super::read_limited(resp, MAX_RESPONSE_BYTES)
                .await
                .unwrap_or_default();
            anyhow::bail!(
                "Apple revoke endpoint: HTTP {status}: {}",
                error_code(&body)
            );
        }
        Ok(())
    }

    async fn post(&self, url: &str, form: &[(&str, &str)]) -> anyhow::Result<reqwest::Response> {
        Ok(self
            .http
            .post(url)
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(form_encode(form))
            .send()
            .await?)
    }
}

/// The `.p8` key: a PKCS#8 PEM holding a P-256 private key. Checked by signing a test
/// token (a key of the wrong kind fails here, at startup, not at the first deletion).
pub fn parse_p8(pem: &str) -> anyhow::Result<EncodingKey> {
    use base64::Engine as _;
    let body: String = pem
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("-----"))
        .collect();
    let der = base64::engine::general_purpose::STANDARD
        .decode(body.as_bytes())
        .map_err(|_| {
            anyhow::anyhow!("the .p8 key is not PEM (base64 between the BEGIN / END lines)")
        })?;
    let key = EncodingKey::from_ec_der(&der);
    let probe = ClientSecretClaims {
        iss: "probe",
        iat: 0,
        exp: 1,
        aud: "probe",
        sub: "probe",
    };
    jsonwebtoken::encode(&Header::new(Algorithm::ES256), &probe, &key)
        .map_err(|_| anyhow::anyhow!("the .p8 key is not a PKCS#8 P-256 private key"))?;
    Ok(key)
}

/// Apple's `{"error": "invalid_grant"}` code, never the body (it could echo a token).
fn error_code(body: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
        .unwrap_or_else(|| "no error code".into())
}

/// `application/x-www-form-urlencoded`.
pub fn form_encode(pairs: &[(&str, &str)]) -> String {
    let mut out = String::new();
    for (i, (k, v)) in pairs.iter().enumerate() {
        if i > 0 {
            out.push('&');
        }
        encode_into(&mut out, k);
        out.push('=');
        encode_into(&mut out, v);
    }
    out
}

fn encode_into(out: &mut String, s: &str) {
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => {
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn form_encoding() {
        assert_eq!(
            form_encode(&[("a", "b c"), ("x", "1+2=3&é"), ("u", "https://x/y?z")]),
            "a=b+c&x=1%2B2%3D3%26%C3%A9&u=https%3A%2F%2Fx%2Fy%3Fz"
        );
    }

    #[test]
    fn error_codes_only() {
        assert_eq!(
            error_code(br#"{"error":"invalid_grant","token":"x"}"#),
            "invalid_grant"
        );
        assert_eq!(error_code(b"<html>"), "no error code");
    }
}
