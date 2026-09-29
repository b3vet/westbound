//! `POST /api/v1/runs` and `POST /api/v1/runs/legacy` (bearer). Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards". Rate-limited per account
//! (`rate_limits.runs_per_hour`) on top of the account limit.

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;

use super::{LegacyReceipt, LegacyUpload, RunReceipt, RunSubmission, SubmitContext};
use crate::app::AppState;
use crate::auth::Authed;
use crate::error::{ApiError, ApiJson, ApiResult};

fn ctx(state: &AppState, account_id: i64) -> SubmitContext<'_> {
    SubmitContext {
        db: &state.db,
        runs: &state.config.runs,
        boards: &state.boards,
        account_id,
        now: state.clock.now(),
    }
}

/// `POST /api/v1/runs`: 201 with the receipt (also for a rejected run: see `reason`); 200
/// with `duplicate: true` for a key already submitted.
pub async fn submit(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(sub): ApiJson<RunSubmission>,
) -> ApiResult<(StatusCode, Json<RunReceipt>)> {
    sub.validate()
        .map_err(|m| ApiError::bad_request("invalid_body", m))?;
    let (receipt, new) = super::submit(ctx(&state, auth.account_id), &sub).await?;
    let status = if new {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(receipt)))
}

/// `POST /api/v1/runs/legacy`: 200 with a result per item.
pub async fn legacy(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(up): ApiJson<LegacyUpload>,
) -> ApiResult<Json<LegacyReceipt>> {
    up.validate()
        .map_err(|m| ApiError::bad_request("invalid_body", m))?;
    let receipt = super::upload_legacy(ctx(&state, auth.account_id), &up).await?;
    Ok(Json(receipt))
}
