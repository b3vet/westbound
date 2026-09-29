//! `/api/v1/auth/*`: device account creation and sign-in, refresh rotation with reuse
//! detection, logout, and the Apple / Google shapes (501 until MP-D2).
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and authentication";
//! API reference: docs/SERVER.md → "Accounts API".

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use sqlx::SqliteConnection;

use super::{
    active_ban, b64, decode_secret, hash_refresh_token, new_family_id, parse_account_id,
    provider_not_enabled, random_bytes, AuthKeys, SECRET_BYTES,
};
use crate::accounts::{self, NameTakenError, Profile};
use crate::app::AppState;
use crate::error::{ApiError, ApiJson, ApiResult};
use crate::metrics::Metrics;
use crate::names;

/// Tokens returned by device creation, device sign-in and refresh.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    /// Decimal string (docs/PROTOCOL.md).
    pub account_id: String,
    /// JWT for `Authorization: Bearer` and the WebSocket `Hello`.
    pub access_token: String,
    /// Always `Bearer`.
    pub token_type: String,
    /// Access-token lifetime in seconds (3600) and its unix expiry.
    pub expires_in: i64,
    pub expires_at: i64,
    /// Single use: each refresh returns a new one.
    pub refresh_token: String,
    pub refresh_expires_at: i64,
}

/// `POST /api/v1/auth/device` (201).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceCreated {
    #[serde(flatten)]
    pub session: Session,
    /// Shown once. Store it (Keychain / encrypted storage / local storage) to recover
    /// the account with `POST /api/v1/auth/device/login`.
    pub device_secret: String,
    pub profile: Profile,
}

/// `POST /api/v1/auth/device/login` (200).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedIn {
    #[serde(flatten)]
    pub session: Session,
    pub profile: Profile,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceLoginRequest {
    pub account_id: String,
    pub device_secret: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogoutRequest {
    pub refresh_token: String,
    /// Also revoke every other session and every outstanding access token.
    #[serde(default)]
    pub all_devices: bool,
}

/// Starts a session: inserts a refresh token (a new family unless `rotate` names the
/// family and the token it replaces) and signs an access token.
async fn issue_session(
    conn: &mut SqliteConnection,
    keys: &AuthKeys,
    account_id: i64,
    token_version: i64,
    rotate: Option<(&[u8], &[u8])>,
    now: i64,
) -> anyhow::Result<Session> {
    let refresh = random_bytes::<SECRET_BYTES>();
    let hash = hash_refresh_token(&refresh);
    let hash = hash.as_slice();
    let new_family = new_family_id();
    let (family, rotated_from) = match rotate {
        Some((family, from)) => (family, Some(from)),
        None => (new_family.as_slice(), None),
    };
    let refresh_expires_at = now + keys.refresh_ttl_secs;
    sqlx::query!(
        "INSERT INTO refresh_tokens (token_hash, account_id, family, rotated_from, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        hash,
        account_id,
        family,
        rotated_from,
        now,
        refresh_expires_at
    )
    .execute(&mut *conn)
    .await?;
    let (access_token, expires_at) = keys.issue_access(account_id, token_version, now)?;
    Ok(Session {
        account_id: account_id.to_string(),
        access_token,
        token_type: "Bearer".into(),
        expires_in: keys.access_ttl_secs,
        expires_at,
        refresh_token: b64(&refresh),
        refresh_expires_at,
    })
}

fn name_full_error() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "name_unavailable",
        "Every #tag for that name is taken; pick another name.",
    )
}

/// `POST /api/v1/auth/device`: a new account with a generated name.
pub async fn device_create(State(state): State<AppState>) -> ApiResult<Response> {
    let now = state.clock.now();
    let keys = &state.auth;
    let secret = random_bytes::<SECRET_BYTES>();
    let secret_hash = keys.hash_device_secret(&secret);
    let mut tx = state.db.begin().await?;
    // A generated name can only be full after ~6.7M accounts share it; try a few.
    let mut created = None;
    for _ in 0..4 {
        let name = names::default_name(super::random_below(u32::MAX));
        match accounts::insert_device_account(&mut tx, &name, &secret_hash, now).await {
            Ok((id, _)) => {
                created = Some(id);
                break;
            }
            Err(NameTakenError::Full) => continue,
            Err(NameTakenError::Db(e)) => return Err(e.into()),
        }
    }
    let id = created.ok_or_else(name_full_error)?;
    let session = issue_session(&mut tx, keys, id, 0, None, now).await?;
    let account = accounts::get(&mut *tx, id)
        .await?
        .ok_or_else(|| ApiError::internal("account vanished inside its transaction"))?;
    tx.commit().await?;
    Metrics::inc(&state.metrics.accounts_created);
    tracing::info!(account_id = id, "device account created");
    let body = DeviceCreated {
        session,
        device_secret: b64(&secret),
        profile: account.profile(now, keys.rename_cooldown_secs),
    };
    Ok((StatusCode::CREATED, Json(body)).into_response())
}

fn invalid_credentials() -> ApiError {
    ApiError::unauthorized(
        "invalid_credentials",
        "Unknown account or wrong device secret.",
    )
}

/// `POST /api/v1/auth/device/login`: account id + device secret → a new session.
pub async fn device_login(
    State(state): State<AppState>,
    ApiJson(req): ApiJson<DeviceLoginRequest>,
) -> ApiResult<Json<SignedIn>> {
    let now = state.clock.now();
    let keys = &state.auth;
    let id = parse_account_id(&req.account_id).ok_or_else(|| {
        ApiError::bad_request("invalid_body", "account_id must be a decimal string.")
    })?;
    let secret = decode_secret(&req.device_secret);
    let row = sqlx::query!(
        "SELECT device_secret_hash, banned_until, token_version FROM accounts WHERE id = ?",
        id
    )
    .fetch_optional(&state.db)
    .await?;
    // Always compute the HMAC so an unknown account and a wrong secret take as long.
    let presented = secret.unwrap_or([0u8; SECRET_BYTES]);
    let stored = row
        .as_ref()
        .and_then(|r| r.device_secret_hash.clone())
        .unwrap_or_default();
    let ok = keys.device_secret_matches(&presented, &stored) && secret.is_some();
    let Some(row) = row.filter(|_| ok) else {
        return Err(invalid_credentials());
    };
    if let Some(until) = active_ban(row.banned_until, now) {
        return Err(ApiError::banned(until));
    }
    let mut tx = state.db.begin().await?;
    let session = issue_session(&mut tx, keys, id, row.token_version, None, now).await?;
    accounts::touch(&mut *tx, id, now).await?;
    let account = accounts::get(&mut *tx, id)
        .await?
        .ok_or_else(invalid_credentials)?;
    tx.commit().await?;
    Metrics::inc(&state.metrics.auth_logins);
    tracing::debug!(account_id = id, "device sign-in");
    Ok(Json(SignedIn {
        session,
        profile: account.profile(now, keys.rename_cooldown_secs),
    }))
}

fn invalid_refresh() -> ApiError {
    ApiError::unauthorized("invalid_token", "Unknown refresh token; sign in again.")
}

/// `POST /api/v1/auth/refresh`: rotates a refresh token. The old one is marked used;
/// presenting a used token again (reuse: it was stolen or replayed) revokes its whole
/// family, so both the thief and the owner must sign in again with the device secret.
pub async fn refresh(
    State(state): State<AppState>,
    ApiJson(req): ApiJson<RefreshRequest>,
) -> ApiResult<Json<Session>> {
    let now = state.clock.now();
    let keys = &state.auth;
    let token = decode_secret(&req.refresh_token).ok_or_else(invalid_refresh)?;
    let hash = hash_refresh_token(&token);
    let hash = hash.as_slice();
    let mut tx = state.db.begin().await?;
    // Claim the token first: the write takes SQLite's write lock, so of two concurrent
    // refreshes with the same token exactly one wins; the other sees reuse.
    let claimed = sqlx::query!(
        r#"UPDATE refresh_tokens SET used_at = ?
           WHERE token_hash = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?
           RETURNING account_id AS "account_id!", family AS "family!""#,
        now,
        hash,
        now
    )
    .fetch_optional(&mut *tx)
    .await?;
    let Some(claimed) = claimed else {
        let row = sqlx::query!(
            "SELECT account_id, family, used_at, revoked_at, expires_at
             FROM refresh_tokens WHERE token_hash = ?",
            hash
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(row) = row else {
            return Err(invalid_refresh());
        };
        if row.revoked_at.is_some() {
            return Err(ApiError::unauthorized(
                "token_revoked",
                "This session was signed out; sign in again.",
            ));
        }
        if row.used_at.is_some() {
            let family = row.family.as_slice();
            let revoked = sqlx::query!(
                "UPDATE refresh_tokens SET revoked_at = ? WHERE family = ? AND revoked_at IS NULL",
                now,
                family
            )
            .execute(&mut *tx)
            .await?
            .rows_affected();
            tx.commit().await?;
            Metrics::inc(&state.metrics.auth_refresh_reuse);
            tracing::warn!(
                account_id = row.account_id,
                revoked,
                "refresh token reuse detected; session family revoked"
            );
            return Err(ApiError::unauthorized(
                "token_reused",
                "This refresh token was already used; the session is revoked. Sign in again.",
            ));
        }
        debug_assert!(row.expires_at <= now);
        return Err(ApiError::unauthorized(
            "token_expired",
            "Refresh token expired; sign in again.",
        ));
    };
    let account_id = claimed.account_id;
    let acc = sqlx::query!(
        "SELECT banned_until, token_version FROM accounts WHERE id = ?",
        account_id
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(invalid_refresh)?;
    if let Some(until) = active_ban(acc.banned_until, now) {
        // Roll back: the token stays usable once the ban ends.
        return Err(ApiError::banned(until));
    }
    let family = claimed.family.as_slice();
    let session = issue_session(
        &mut tx,
        keys,
        account_id,
        acc.token_version,
        Some((family, hash)),
        now,
    )
    .await?;
    accounts::touch(&mut *tx, account_id, now).await?;
    tx.commit().await?;
    Metrics::inc(&state.metrics.auth_refreshes);
    Ok(Json(session))
}

/// `POST /api/v1/auth/logout`: revokes the refresh token's session (its family); with
/// `all_devices`, every session of the account and every access token (token version
/// bump). Always 204, also for an unknown token.
pub async fn logout(
    State(state): State<AppState>,
    ApiJson(req): ApiJson<LogoutRequest>,
) -> ApiResult<StatusCode> {
    let now = state.clock.now();
    let Some(token) = decode_secret(&req.refresh_token) else {
        return Ok(StatusCode::NO_CONTENT);
    };
    let hash = hash_refresh_token(&token);
    let hash = hash.as_slice();
    let mut tx = state.db.begin().await?;
    let row = sqlx::query!(
        "SELECT account_id, family FROM refresh_tokens WHERE token_hash = ?",
        hash
    )
    .fetch_optional(&mut *tx)
    .await?;
    if let Some(row) = row {
        if req.all_devices {
            sqlx::query!(
                "UPDATE refresh_tokens SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL",
                now,
                row.account_id
            )
            .execute(&mut *tx)
            .await?;
            sqlx::query!(
                "UPDATE accounts SET token_version = token_version + 1 WHERE id = ?",
                row.account_id
            )
            .execute(&mut *tx)
            .await?;
        } else {
            let family = row.family.as_slice();
            sqlx::query!(
                "UPDATE refresh_tokens SET revoked_at = ? WHERE family = ? AND revoked_at IS NULL",
                now,
                family
            )
            .execute(&mut *tx)
            .await?;
        }
        tracing::debug!(account_id = row.account_id, all = req.all_devices, "logout");
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /api/v1/auth/{link,signin}/apple`: 501 until MP-D2.
pub async fn apple_not_enabled() -> ApiError {
    provider_not_enabled("Apple")
}

/// `POST /api/v1/auth/{link,signin}/google`: 501 until MP-D2.
pub async fn google_not_enabled() -> ApiError {
    provider_not_enabled("Google")
}
