//! `POST /api/v1/runs/{run_id}/replay` (bearer): the replay upload. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards" (single-player runs, step 3).
//! docs/SERVER.md → "Replays and verification". Rate-limited like run submissions; the
//! body limit is `replays.max_bytes` (413 `body_too_large` above it).

use axum::body::Bytes;
use axum::extract::rejection::BytesRejection;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use super::{UploadError, UploadReceipt};
use crate::app::AppState;
use crate::auth::Authed;
use crate::error::{ApiError, ApiResult};

/// 201 with the receipt for a new replay; 200 with `duplicate: true` when the run already
/// has one (nothing is stored again).
pub async fn upload(
    State(state): State<AppState>,
    auth: Authed,
    Path(run_id): Path<String>,
    body: Result<Bytes, BytesRejection>,
) -> ApiResult<(StatusCode, Json<UploadReceipt>)> {
    let body = body.map_err(|rej| {
        if rej.status() == StatusCode::PAYLOAD_TOO_LARGE {
            ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "body_too_large",
                format!(
                    "a replay may be at most {} bytes",
                    state.config.replays.max_bytes
                ),
            )
        } else {
            ApiError::bad_request("invalid_replay", rej.body_text())
        }
    })?;
    let run_id = parse_run_id(&run_id).ok_or_else(unknown_run)?;
    // N10.3: the data volume is below its floor (the disk check): the client keeps the
    // replay and retries later (5xx), instead of the upload filling the disk.
    if crate::metrics::Metrics::get(&state.metrics.disk_low) == 1 {
        let mut e = ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "storage_low",
            "the server is short of disk space; try again later",
        )
        .with("retry_after_secs", STORAGE_LOW_RETRY_SECS);
        e.retry_after = Some(STORAGE_LOW_RETRY_SECS);
        return Err(e);
    }
    let outcome = super::upload(
        &state.db,
        &state.config.replays,
        auth.account_id,
        run_id,
        &body,
        state.clock.now(),
    )
    .await?;
    match outcome {
        Ok((receipt, new)) => {
            if new {
                state.replay_jobs.notify_one();
            }
            let status = if new {
                StatusCode::CREATED
            } else {
                StatusCode::OK
            };
            Ok((status, Json(receipt)))
        }
        Err(UploadError::UnknownRun) => Err(unknown_run()),
        Err(UploadError::NotOwner) => Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "not_owner",
            "this run is another account's",
        )),
        Err(UploadError::NotRequired) => Err(ApiError::new(
            StatusCode::CONFLICT,
            "replay_not_required",
            "this run's receipt did not ask for a replay",
        )),
        Err(UploadError::Invalid(why)) => Err(ApiError::bad_request("invalid_replay", why)),
        Err(UploadError::Mismatch(why)) => Err(ApiError::bad_request("replay_mismatch", why)),
    }
}

/// What a 503 `storage_low` suggests to the client (its own retry schedule decides).
const STORAGE_LOW_RETRY_SECS: u64 = 3_600;

fn parse_run_id(s: &str) -> Option<i64> {
    if s.is_empty() || s.len() > 19 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok().filter(|v| *v > 0)
}

fn unknown_run() -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, "unknown_run", "no such run")
}
