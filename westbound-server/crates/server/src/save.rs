//! N11 cloud save: `GET/PUT /api/v1/save`, one JSON document per account.
//! docs/SERVER.md → "Cloud save"; the merge rules are the client's (docs/SAVE.md →
//! Cloud sync): the server stores what it is given, whole, and never merges.
//!
//! - **Size:** the document (`data`, as JSON) is at most `cloud_save.max_bytes` (64 KB;
//!   the local save is a few KB). One row per account, so that is also the per-account
//!   disk cap. Old revisions are not kept.
//! - **Concurrency:** every write names the revision it replaces (`If-Match: "<rev>"`;
//!   `"0"` when the account has none yet). A mismatch is `409 revision_conflict` with the
//!   server's copy in `save`, so the client merges and tries again. The revision counts
//!   up from 1 and is also the `ETag`.
//! - **Rate:** reads under the account limit; writes also under
//!   `cloud_save.writes_per_hour` / `writes_burst`.
//! - Same database as everything else: backups, restores and the account deletion
//!   include it.

use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::app::AppState;
use crate::auth::Authed;
use crate::error::{ApiError, ApiJson, ApiResult};

/// Request-body slack over `cloud_save.max_bytes` (the `{"data": …}` envelope).
pub const BODY_SLACK_BYTES: usize = 1_024;

/// `GET /api/v1/save` and the `save` of a 409.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloudSave {
    /// 0 = no save yet.
    pub revision: i64,
    pub updated_at: Option<i64>,
    pub bytes: i64,
    /// The document (null when none).
    pub data: Option<Value>,
}

/// `PUT /api/v1/save` (200).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Saved {
    pub revision: i64,
    pub updated_at: i64,
    pub bytes: i64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PutSave {
    pub data: Value,
}

fn not_enabled() -> ApiError {
    ApiError::new(
        StatusCode::NOT_IMPLEMENTED,
        "cloud_save_not_enabled",
        "Cloud save is not enabled on this server.",
    )
}

fn etag(revision: i64) -> HeaderValue {
    HeaderValue::from_str(&format!("\"{revision}\"")).expect("digits are a valid header")
}

/// `If-Match: "3"` (or `3`, or a weak `W/"3"`) → 3.
pub fn parse_if_match(headers: &HeaderMap) -> Option<i64> {
    let v = headers.get(header::IF_MATCH)?.to_str().ok()?.trim();
    let v = v.strip_prefix("W/").unwrap_or(v);
    let v = v.trim_matches('"');
    if v.is_empty() || v.len() > 18 || !v.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    v.parse().ok()
}

/// The account's save (revision 0 when none).
pub async fn load(db: impl sqlx::SqliteExecutor<'_>, id: i64) -> ApiResult<CloudSave> {
    let row = sqlx::query!(
        "SELECT revision, updated_at, bytes, data FROM cloud_saves WHERE account_id = ?",
        id
    )
    .fetch_optional(db)
    .await?;
    Ok(match row {
        Some(r) => CloudSave {
            revision: r.revision,
            updated_at: Some(r.updated_at),
            bytes: r.bytes,
            data: Some(serde_json::from_str(&r.data).map_err(ApiError::internal)?),
        },
        None => CloudSave {
            revision: 0,
            updated_at: None,
            bytes: 0,
            data: None,
        },
    })
}

/// `GET /api/v1/save`.
pub async fn get_save(State(state): State<AppState>, auth: Authed) -> ApiResult<Response> {
    if !state.config.cloud_save.enabled {
        return Err(not_enabled());
    }
    let save = load(&state.db, auth.account_id).await?;
    let mut resp = Json(&save).into_response();
    let h = resp.headers_mut();
    h.insert(header::ETAG, etag(save.revision));
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(resp)
}

/// `PUT /api/v1/save` with `If-Match` and `{"data": {...}}`.
pub async fn put_save(
    State(state): State<AppState>,
    auth: Authed,
    headers: HeaderMap,
    ApiJson(req): ApiJson<PutSave>,
) -> ApiResult<Response> {
    let cfg = &state.config.cloud_save;
    if !cfg.enabled {
        return Err(not_enabled());
    }
    let Some(expected) = parse_if_match(&headers) else {
        return Err(ApiError::new(
            StatusCode::PRECONDITION_REQUIRED,
            "precondition_required",
            "Send If-Match with the revision this save replaces (\"0\" for the first).",
        ));
    };
    if !req.data.is_object() {
        return Err(ApiError::bad_request(
            "invalid_body",
            "`data` must be a JSON object.",
        ));
    }
    let text = serde_json::to_string(&req.data).map_err(ApiError::internal)?;
    if text.len() > cfg.max_bytes {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "save_too_large",
            format!("The save is over {} bytes.", cfg.max_bytes),
        )
        .with("max_bytes", cfg.max_bytes));
    }
    let now = state.clock.now();
    let id = auth.account_id;
    let bytes = i64::try_from(text.len()).unwrap_or(i64::MAX);
    // IMMEDIATE: the read and the write hold the write lock together, so two devices
    // writing on the same revision cannot both win.
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let current = load(&mut *tx, id).await?;
    if current.revision != expected {
        drop(tx);
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "revision_conflict",
            "The cloud save changed; merge with `save` and send again.",
        )
        .with(
            "save",
            serde_json::to_value(&current).map_err(ApiError::internal)?,
        ));
    }
    let revision = current.revision + 1;
    sqlx::query!(
        "INSERT INTO cloud_saves (account_id, revision, data, bytes, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (account_id) DO UPDATE SET
             revision = excluded.revision, data = excluded.data,
             bytes = excluded.bytes, updated_at = excluded.updated_at",
        id,
        revision,
        text,
        bytes,
        now
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    tracing::debug!(account_id = id, revision, bytes, "cloud save written");
    let mut resp = Json(Saved {
        revision,
        updated_at: now,
        bytes,
    })
    .into_response();
    resp.headers_mut().insert(header::ETAG, etag(revision));
    Ok(resp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn if_match_forms() {
        let h = |v: &str| {
            let mut m = HeaderMap::new();
            m.insert(header::IF_MATCH, HeaderValue::from_str(v).unwrap());
            parse_if_match(&m)
        };
        assert_eq!(h("\"3\""), Some(3));
        assert_eq!(h("0"), Some(0));
        assert_eq!(h("W/\"12\""), Some(12));
        assert_eq!(h("*"), None);
        assert_eq!(h("\"-1\""), None);
        assert_eq!(h("\"\""), None);
        assert_eq!(parse_if_match(&HeaderMap::new()), None);
    }
}
