//! `GET/PATCH /api/v1/me` and `DELETE /api/v1/account`.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and authentication" (display
//! names: renamable once every 30 days; account deletion).

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;

use crate::accounts::{self, NameTakenError, Profile, RenameError};
use crate::app::AppState;
use crate::auth::{Authed, AuthedAllowBanned};
use crate::error::{ApiError, ApiJson, ApiResult};
use crate::names;
use crate::profanity::ProfanityFilter;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PatchMe {
    pub display_name: String,
}

fn gone() -> ApiError {
    ApiError::unauthorized("token_revoked", "This account no longer exists.")
}

/// `GET /api/v1/me`.
pub async fn get_me(State(state): State<AppState>, auth: Authed) -> ApiResult<Json<Profile>> {
    let now = state.clock.now();
    let acc = accounts::get(&state.db, auth.account_id)
        .await?
        .ok_or_else(gone)?;
    Ok(Json(acc.profile(now, state.auth.rename_cooldown_secs)))
}

/// Maps rename failures to API errors (shared with the admin CLI's messages).
pub fn rename_error(e: RenameError) -> ApiError {
    match e {
        RenameError::NotFound => gone(),
        RenameError::Cooldown(next) => ApiError::new(
            StatusCode::CONFLICT,
            "rename_cooldown",
            "Too soon to rename again (once every 30 days by default); see next_rename_at.",
        )
        .with("next_rename_at", next),
        RenameError::Taken(NameTakenError::Full) => ApiError::new(
            StatusCode::CONFLICT,
            "name_unavailable",
            "Every #tag for that name is taken; pick another name.",
        ),
        RenameError::Taken(NameTakenError::Db(e)) => e.into(),
    }
}

/// `PATCH /api/v1/me` `{"display_name": "..."}`: rename (once per cooldown). Keeps the
/// current tag when it is free for the new name, otherwise assigns a free one.
pub async fn patch_me(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(req): ApiJson<PatchMe>,
) -> ApiResult<Json<Profile>> {
    let now = state.clock.now();
    let cooldown = state.auth.rename_cooldown_secs;
    let name = names::validate(&req.display_name, ProfanityFilter::builtin())
        .map_err(|e| ApiError::bad_request(e.code(), e.to_string()))?;
    let current = accounts::get(&state.db, auth.account_id)
        .await?
        .ok_or_else(gone)?;
    if current.display_name == name {
        return Err(ApiError::bad_request(
            "name_unchanged",
            "That is already your name.",
        ));
    }
    let acc = accounts::rename(&state.db, auth.account_id, &name, now, Some(cooldown))
        .await
        .map_err(rename_error)?;
    // Cached board tops show display names.
    state.boards.invalidate_all();
    tracing::info!(account_id = acc.id, "display name changed");
    Ok(Json(acc.profile(now, cooldown)))
}

/// `DELETE /api/v1/account`: deletes the account and all of its data (also allowed
/// while banned). 204.
pub async fn delete_account(
    State(state): State<AppState>,
    AuthedAllowBanned(auth): AuthedAllowBanned,
) -> ApiResult<StatusCode> {
    let now = state.clock.now();
    let report = accounts::delete(
        &state.db,
        state.boards.config(),
        auth.account_id,
        "self",
        now,
    )
    .await?;
    if report.accounts == 0 {
        return Err(gone());
    }
    state.boards.invalidate_all();
    // Friends see the account go offline and stop watching it now; its open session (if
    // any) ends now rather than at the next ban sweep.
    state.presence.forget_account(auth.account_id);
    if let Some(s) = state
        .sessions
        .get(protocol::AccountId(auth.account_id as u64))
    {
        s.kick(crate::sessions::Kick::Revoked);
    }
    tracing::info!(account_id = auth.account_id, "account deleted");
    Ok(StatusCode::NO_CONTENT)
}
