//! N11 routes: `GET /auth/providers`, `POST /auth/nonce`, `POST /auth/signin/{provider}`,
//! `POST /auth/link/{provider}`, `POST /auth/unlink/{provider}`. docs/SERVER.md → "Sign
//! in with Apple / Google".
//!
//! **Sign-in** (no bearer): the identity's account, or a new one with a generated name.
//! Either way this device gets its own device credential (`device_secret`, returned once,
//! stored hashed in `device_secrets` or as the new account's first), so it renews its
//! session exactly like a device account (`/auth/device/login`).
//!
//! **Link** (bearer): adds the identity to the caller's account, so its progress is kept.
//! When the identity already belongs to another account, `409 identity_in_use` carries
//! both accounts' summaries (`conflict.current`, `conflict.other`); the client asks the
//! player and, to switch, calls sign-in with the same token (accounts are never merged:
//! the spec's "merging accounts is out of scope for v1").
//!
//! **Unlink** (bearer): removes it, unless that would leave the account no way in (no
//! other provider and no device credential): `409 last_sign_in_method`. Unlinking Apple
//! revokes the Apple grant when one is stored.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};

use super::store::{self, LinkError};
use super::{IdTokenError, NonceCheck, Provider, VerifiedIdentity};
use crate::accounts::{self, NameTakenError, Profile};
use crate::app::AppState;
use crate::auth::routes::{issue_session, Session};
use crate::auth::{active_ban, b64, provider_not_enabled, random_bytes, Authed, SECRET_BYTES};
use crate::error::{ApiError, ApiJson, ApiResult};
use crate::names;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IdTokenRequest {
    /// The provider's ID token (JWT).
    pub id_token: String,
    /// The nonce from `POST /auth/nonce` the client passed to the provider.
    #[serde(default)]
    pub nonce: Option<String>,
    /// Apple only, optional: the sign-in's authorization code. With the Apple key
    /// configured the server exchanges it for the refresh token it revokes later.
    #[serde(default)]
    pub authorization_code: Option<String>,
}

/// `POST /auth/signin/{provider}`: 200 for an existing account, 201 for a new one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderSignedIn {
    #[serde(flatten)]
    pub session: Session,
    /// This device's credential, shown once (store it like a device account's secret).
    pub device_secret: String,
    pub profile: Profile,
    /// A new account was created for the identity.
    pub created: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderPublic {
    pub enabled: bool,
    /// The web client id (Google) or Services ID (Apple); "" when disabled.
    pub client_id: String,
    /// Apple: the Services ID's return URL (Apple JS needs it, popup or not).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub redirect_uri: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudSavePublic {
    pub enabled: bool,
    pub max_bytes: usize,
}

/// `GET /auth/providers`: what the client may offer (public, no secrets).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Providers {
    pub apple: ProviderPublic,
    pub google: ProviderPublic,
    pub nonce_required: bool,
    pub cloud_save: CloudSavePublic,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NonceIssued {
    pub nonce: String,
    pub expires_at: i64,
}

/// `conflict` of a `409 identity_in_use`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkConflict {
    pub provider: Provider,
    /// The signed-in account (this device's).
    pub current: store::AccountSummary,
    /// The account the identity belongs to.
    pub other: store::AccountSummary,
}

fn provider_of(name: &str) -> ApiResult<Provider> {
    Provider::parse(name).ok_or_else(ApiError::not_found)
}

fn verify_error(e: IdTokenError, p: Provider) -> ApiError {
    match e {
        IdTokenError::Malformed | IdTokenError::Invalid => ApiError::unauthorized(
            "invalid_id_token",
            format!("The {} ID token was not accepted.", p.title()),
        ),
        IdTokenError::Expired => ApiError::unauthorized(
            "id_token_expired",
            format!("The {} ID token expired; sign in again.", p.title()),
        ),
        IdTokenError::Nonce => ApiError::bad_request(
            "invalid_nonce",
            "The sign-in nonce is missing, expired or does not match; start the sign-in again.",
        ),
        IdTokenError::Unavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider_unavailable",
            format!(
                "{} sign-in is unavailable right now; try again soon.",
                p.title()
            ),
        ),
    }
}

async fn verify(
    state: &AppState,
    p: Provider,
    req: &IdTokenRequest,
) -> ApiResult<VerifiedIdentity> {
    let id = &state.identity;
    let v = id
        .verifier(p)
        .ok_or_else(|| provider_not_enabled(p.title()))?;
    let check = NonceCheck {
        keys: &id.nonces,
        required: id.require_nonce,
        presented: req.nonce.as_deref().filter(|n| !n.is_empty()),
    };
    v.verify(&req.id_token, check, state.clock.now())
        .await
        .map_err(|e| {
            tracing::debug!(provider = p.as_str(), error = %e, "ID token refused");
            verify_error(e, p)
        })
}

/// The Apple grant to keep for revocation (sealed), when this is Apple with a code.
async fn apple_sealed(
    state: &AppState,
    v: &VerifiedIdentity,
    req: &IdTokenRequest,
) -> Option<Vec<u8>> {
    if v.provider != Provider::Apple {
        return None;
    }
    state
        .identity
        .apple_refresh_sealed(
            &v.client_id,
            req.authorization_code.as_deref(),
            state.clock.now(),
        )
        .await
}

/// `GET /api/v1/auth/providers`.
pub async fn get_providers(State(state): State<AppState>) -> Json<Providers> {
    let i = &state.config.identity;
    let id = &state.identity;
    Json(Providers {
        apple: ProviderPublic {
            enabled: id.apple.is_some(),
            client_id: i.apple_web_client().to_string(),
            redirect_uri: Some(i.apple_web_redirect_uri.clone()),
        },
        google: ProviderPublic {
            enabled: id.google.is_some(),
            client_id: i.google_web_client().to_string(),
            redirect_uri: None,
        },
        nonce_required: id.require_nonce,
        cloud_save: CloudSavePublic {
            enabled: state.config.cloud_save.enabled,
            max_bytes: state.config.cloud_save.max_bytes,
        },
    })
}

/// `POST /api/v1/auth/nonce`.
pub async fn post_nonce(State(state): State<AppState>) -> Json<NonceIssued> {
    let (nonce, expires_at) = state.identity.nonces.issue(state.clock.now());
    Json(NonceIssued { nonce, expires_at })
}

fn name_full_error() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "name_unavailable",
        "Every #tag for that name is taken; try again.",
    )
}

/// `POST /api/v1/auth/signin/{provider}`.
pub async fn signin(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    ApiJson(req): ApiJson<IdTokenRequest>,
) -> ApiResult<Response> {
    let p = provider_of(&provider)?;
    let v = verify(&state, p, &req).await?;
    let sealed = apple_sealed(&state, &v, &req).await;
    let now = state.clock.now();
    let keys = &state.auth;
    let secret = random_bytes::<SECRET_BYTES>();
    let secret_hash = keys.hash_device_secret(&secret);
    // IMMEDIATE: the lookup and the creation hold the write lock together, so two
    // first sign-ins with one identity cannot make two accounts.
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let existing = store::account_for(&mut *tx, p, &v.sub).await?;
    let (id, created) = match existing {
        Some(id) => {
            let ban = sqlx::query_scalar!("SELECT banned_until FROM accounts WHERE id = ?", id)
                .fetch_one(&mut *tx)
                .await?;
            if let Some(until) = active_ban(ban, now) {
                return Err(ApiError::banned(until));
            }
            store::record_link(&mut tx, id, &v, sealed.as_deref(), now).await?;
            store::add_device_secret(
                &mut tx,
                id,
                &secret_hash,
                state.identity.max_device_secrets,
                now,
            )
            .await?;
            accounts::touch(&mut *tx, id, now).await?;
            (id, false)
        }
        None => {
            let mut made = None;
            for _ in 0..4 {
                let name = names::default_name(crate::auth::random_below(u32::MAX));
                match accounts::insert_device_account(&mut tx, &name, &secret_hash, now).await {
                    Ok((id, _)) => {
                        made = Some(id);
                        break;
                    }
                    Err(NameTakenError::Full) => continue,
                    Err(NameTakenError::Db(e)) => return Err(e.into()),
                }
            }
            let id = made.ok_or_else(name_full_error)?;
            store::link(&mut tx, id, &v, sealed.as_deref(), now)
                .await
                .map_err(|e| match e {
                    LinkError::Db(e) => ApiError::from(e),
                    other => ApiError::internal(other),
                })?;
            (id, true)
        }
    };
    let acc = accounts::get(&mut *tx, id)
        .await?
        .ok_or_else(|| ApiError::internal("account vanished inside its transaction"))?;
    let session = issue_session(&mut tx, keys, id, acc.token_version, None, now).await?;
    let profile = acc
        .profile_with_identities(&mut *tx, now, keys.rename_cooldown_secs)
        .await?;
    tx.commit().await?;
    if created {
        crate::metrics::Metrics::inc(&state.metrics.accounts_created);
    }
    crate::metrics::Metrics::inc(&state.metrics.auth_logins);
    tracing::info!(
        account_id = id,
        provider = p.as_str(),
        created,
        "provider sign-in"
    );
    let body = ProviderSignedIn {
        session,
        device_secret: b64(&secret),
        profile,
        created,
    };
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(body)).into_response())
}

async fn conflict(state: &AppState, p: Provider, me: i64, other: i64) -> ApiResult<ApiError> {
    let current = store::summary(&state.db, me)
        .await?
        .ok_or_else(|| ApiError::unauthorized("token_revoked", "This account no longer exists."))?;
    let other = store::summary(&state.db, other)
        .await?
        .ok_or_else(|| ApiError::internal("conflicting account vanished"))?;
    let body = LinkConflict {
        provider: p,
        current,
        other,
    };
    Ok(ApiError::new(
        StatusCode::CONFLICT,
        "identity_in_use",
        format!(
            "This {} account is linked to another player; sign in to switch to it.",
            p.title()
        ),
    )
    .with(
        "conflict",
        serde_json::to_value(body).map_err(ApiError::internal)?,
    ))
}

fn already_linked(p: Provider) -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "provider_already_linked",
        format!("Another {} account is linked; unlink it first.", p.title()),
    )
}

async fn my_profile(state: &AppState, id: i64) -> ApiResult<Profile> {
    let now = state.clock.now();
    let acc = accounts::get(&state.db, id)
        .await?
        .ok_or_else(|| ApiError::unauthorized("token_revoked", "This account no longer exists."))?;
    Ok(acc
        .profile_with_identities(&state.db, now, state.auth.rename_cooldown_secs)
        .await?)
}

/// `POST /api/v1/auth/link/{provider}` (bearer): the profile.
pub async fn link(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    auth: Authed,
    ApiJson(req): ApiJson<IdTokenRequest>,
) -> ApiResult<Json<Profile>> {
    let p = provider_of(&provider)?;
    let v = verify(&state, p, &req).await?;
    let me = auth.account_id;
    match store::account_for(&state.db, p, &v.sub).await? {
        Some(owner) if owner == me => {
            // Already linked here: refresh the hint (idempotent).
            let sealed = apple_sealed(&state, &v, &req).await;
            let mut conn = state.db.acquire().await?;
            store::record_link(&mut conn, me, &v, sealed.as_deref(), state.clock.now()).await?;
            drop(conn);
            return Ok(Json(my_profile(&state, me).await?));
        }
        Some(other) => return Err(conflict(&state, p, me, other).await?),
        None => {}
    }
    if store::linked_sub(&state.db, p, me).await?.is_some() {
        return Err(already_linked(p));
    }
    let sealed = apple_sealed(&state, &v, &req).await;
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    match store::link(&mut tx, me, &v, sealed.as_deref(), now).await {
        Ok(()) => {}
        Err(LinkError::InUse(other)) => {
            drop(tx);
            return Err(conflict(&state, p, me, other).await?);
        }
        Err(LinkError::AlreadyLinked) => return Err(already_linked(p)),
        Err(LinkError::NotFound) => {
            return Err(ApiError::unauthorized(
                "token_revoked",
                "This account no longer exists.",
            ))
        }
        Err(LinkError::Db(e)) => return Err(e.into()),
    }
    tx.commit().await?;
    tracing::info!(account_id = me, provider = p.as_str(), "provider linked");
    Ok(Json(my_profile(&state, me).await?))
}

/// `POST /api/v1/auth/unlink/{provider}` (bearer): the profile.
pub async fn unlink(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    auth: Authed,
) -> ApiResult<Json<Profile>> {
    let p = provider_of(&provider)?;
    let me = auth.account_id;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    if store::linked_sub(&mut *tx, p, me).await?.is_none() {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "not_linked",
            format!("No {} account is linked.", p.title()),
        ));
    }
    let (providers, device) = store::other_sign_in_methods(&mut tx, me, p).await?;
    if providers == 0 && !device {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "last_sign_in_method",
            format!(
                "{} is this account's only way to sign in; link another first.",
                p.title()
            ),
        ));
    }
    let grant = if p == Provider::Apple {
        store::apple_grant(&mut *tx, me).await?
    } else {
        None
    };
    store::unlink(&mut tx, me, p).await?;
    tx.commit().await?;
    tracing::info!(account_id = me, provider = p.as_str(), "provider unlinked");
    if let Some(g) = grant {
        state.identity.revoke_apple(&g, state.clock.now()).await;
    }
    Ok(Json(my_profile(&state, me).await?))
}
