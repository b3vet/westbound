//! Player reports (N9.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Moderation" (a report
//! button from the room menu or a leaderboard entry, rate-limited per account; the admin
//! CLI lists reports). API: docs/SERVER.md → "Social API → Reports".
//!
//! The per-account limit is counted in the database (`social.reports_per_day` in any
//! rolling 24 hours), so it survives restarts and holds across devices; the HTTP social
//! limiter still applies on top.

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::SqlitePool;

use super::friends::body_account_id;
use crate::app::AppState;
use crate::auth::Authed;
use crate::clock::SECS_PER_DAY;
use crate::error::{ApiError, ApiJson, ApiResult};

/// Why a player is reported.
pub const REASONS: &[&str] = &[
    "cheating",
    "offensive_name",
    "offensive_crew",
    "harassment",
    "griefing",
    "other",
];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReportBody {
    /// Decimal string.
    pub target_account_id: String,
    /// One of [`REASONS`].
    pub reason: String,
    /// Where the report comes from, e.g. `{"source": "room", "room_id": 12}` or
    /// `{"source": "leaderboard", "board": "loop", "run_id": "917"}`. A JSON object.
    #[serde(default)]
    pub context: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportReceipt {
    pub report_id: String,
}

/// Files a report by `me`. 201.
pub async fn file(
    state: &AppState,
    me: i64,
    target: i64,
    reason: &str,
    context: Option<&Value>,
) -> ApiResult<ReportReceipt> {
    let cfg = &state.config.social;
    if !REASONS.contains(&reason) {
        return Err(ApiError::bad_request(
            "invalid_reason",
            format!("`reason` is one of: {}.", REASONS.join(", ")),
        ));
    }
    let context = match context {
        None | Some(Value::Null) => "{}".to_string(),
        Some(v @ Value::Object(_)) => v.to_string(),
        Some(_) => {
            return Err(ApiError::bad_request(
                "invalid_context",
                "`context` must be a JSON object.",
            ))
        }
    };
    if context.len() > cfg.report_context_max_bytes as usize {
        return Err(ApiError::bad_request(
            "invalid_context",
            format!(
                "`context` is limited to {} bytes.",
                cfg.report_context_max_bytes
            ),
        ));
    }
    if target == me {
        return Err(ApiError::bad_request(
            "cannot_report_self",
            "You cannot report yourself.",
        ));
    }
    let now = state.clock.now();
    let since = now - SECS_PER_DAY;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let exists = sqlx::query_scalar!(
        r#"SELECT id AS "id!: i64" FROM accounts WHERE id = ?"#,
        target
    )
    .fetch_optional(&mut *tx)
    .await?
    .is_some();
    if !exists {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "player_not_found",
            "No such player.",
        ));
    }
    let window = sqlx::query!(
        r#"SELECT COUNT(*) AS "n!: i64", MIN(created_at) AS "oldest?: i64" FROM reports
           WHERE reporter_id = ? AND created_at > ?"#,
        me,
        since
    )
    .fetch_one(&mut *tx)
    .await?;
    if window.n >= i64::from(cfg.reports_per_day) {
        let retry = window
            .oldest
            .map_or(SECS_PER_DAY, |t| t + SECS_PER_DAY - now)
            .max(1);
        return Err(ApiError::rate_limited(retry as u64));
    }
    let id = sqlx::query!(
        "INSERT INTO reports (reporter_id, target_id, reason, context, created_at)
         VALUES (?, ?, ?, ?, ?)",
        me,
        target,
        reason,
        context,
        now
    )
    .execute(&mut *tx)
    .await?
    .last_insert_rowid();
    tx.commit().await?;
    tracing::info!(report_id = id, reason, "player reported");
    Ok(ReportReceipt {
        report_id: id.to_string(),
    })
}

/// `POST /api/v1/reports`.
pub async fn post_report(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(body): ApiJson<ReportBody>,
) -> ApiResult<(StatusCode, Json<ReportReceipt>)> {
    let target = body_account_id(&body.target_account_id)?;
    let r = file(
        &state,
        auth.account_id,
        target,
        &body.reason,
        body.context.as_ref(),
    )
    .await?;
    Ok((StatusCode::CREATED, Json(r)))
}

/// One report as the admin CLI lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportRow {
    pub id: i64,
    /// `None` once that account was deleted.
    pub reporter_id: Option<i64>,
    pub target_id: Option<i64>,
    pub reason: String,
    pub context: String,
    pub created_at: i64,
    pub handled: bool,
    pub handled_at: Option<i64>,
}

/// Reports, newest first (only unhandled ones with `unhandled_only`), at most `limit`.
pub async fn list(
    pool: &SqlitePool,
    unhandled_only: bool,
    limit: i64,
) -> sqlx::Result<Vec<ReportRow>> {
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: i64", reporter_id, target_id, reason, context, created_at,
                  handled AS "handled: bool", handled_at
           FROM reports WHERE handled = 0 OR NOT ?1
           ORDER BY created_at DESC, id DESC LIMIT ?2"#,
        unhandled_only,
        limit
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| ReportRow {
            id: r.id,
            reporter_id: r.reporter_id,
            target_id: r.target_id,
            reason: r.reason,
            context: r.context,
            created_at: r.created_at,
            handled: r.handled,
            handled_at: r.handled_at,
        })
        .collect())
}

/// Marks a report handled. `None` if there is no such report; `Some(false)` if it already
/// was.
pub async fn mark_handled(pool: &SqlitePool, id: i64, now: i64) -> sqlx::Result<Option<bool>> {
    let done = sqlx::query!(
        "UPDATE reports SET handled = 1, handled_at = ? WHERE id = ? AND handled = 0",
        now,
        id
    )
    .execute(pool)
    .await?;
    if done.rows_affected() == 1 {
        return Ok(Some(true));
    }
    let exists = sqlx::query_scalar!(r#"SELECT id AS "id!: i64" FROM reports WHERE id = ?"#, id)
        .fetch_optional(pool)
        .await?
        .is_some();
    Ok(exists.then_some(false))
}
