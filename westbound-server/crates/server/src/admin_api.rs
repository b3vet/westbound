//! The admin API (N10.2): what the `admin` CLI needs from the **running** server, on its
//! own loopback listener (`admin.bind`, like the metrics port) behind a bearer token
//! (`WB_ADMIN__TOKEN`). The database-only commands (bans, renames, reports, board fixes)
//! don't need it; live rooms, notices and immediate kicks do. Spec: WESTBOUND_MULTIPLAYER_
//! HANDOFF.md → Moderation (admin CLI), "Server tech stack" (clap: the same binary runs
//! admin commands). Runbook: docs/OPERATIONS.md.
//!
//! | Route | What |
//! | --- | --- |
//! | `GET /admin/v1/stats` | live counts: sessions, rooms, seats, draining, uptime |
//! | `GET /admin/v1/stats/full` | N10.1: the admin stats view (`metrics_admin`: process, gateway, room ticks, netcode, shadow contacts) |
//! | `GET /admin/v1/rooms` | every live room: id, code, visibility, players, density, night, accounts |
//! | `POST /admin/v1/rooms/{code or id}/close` `{"message"}` | the room closes at its next tick: runs end (`room_closed`), the players get the message as a `server_notice{info}` and `room_left{closed}` |
//! | `POST /admin/v1/notice` `{"kind","seconds","text"}` | a `server_notice` to every live session |
//! | `POST /admin/v1/kick/{account_id}` `{"reason"}` | ends the account's session now (`banned`, `revoked` or `closed`) |
//! | `POST /admin/v1/boards/invalidate` | drops the cached board tops (after a CLI board fix) |
//!
//! Every request is counted (`wb_admin_requests_total`, refusals in `wb_admin_denied_total`)
//! and logged at INFO without the token.

use axum::extract::{Path, Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use protocol::{AccountId, NoticeKind};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;

use crate::app::AppState;
use crate::metrics::Metrics;
use crate::rooms::{CloseMode, RoomSummary};
use crate::sessions::Kick;

/// Path prefix of every admin route.
pub const PREFIX: &str = "/admin/v1";

/// `GET /admin/v1/stats`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiveStats {
    pub version: String,
    pub build: String,
    pub uptime_secs: u64,
    pub draining: bool,
    /// Seconds of restart notice left while draining.
    pub restart_in_secs: Option<u16>,
    pub sessions: usize,
    pub connections: u64,
    pub rooms: usize,
    /// Seats in all rooms (held ones included).
    pub seats: u64,
    pub public_rooms: usize,
    pub private_rooms: usize,
}

/// `POST /admin/v1/rooms/{target}/close` body.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CloseBody {
    /// Shown to the room's players (`server_notice{info}`); empty: none.
    #[serde(default)]
    pub message: String,
}

/// `POST /admin/v1/notice` body.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoticeBody {
    /// `info` (default), `maintenance` or `restart`.
    #[serde(default = "default_kind")]
    pub kind: String,
    /// Seconds until the event (0 for info).
    #[serde(default)]
    pub seconds: u16,
    pub text: String,
}

fn default_kind() -> String {
    "info".into()
}

/// `POST /admin/v1/kick/{account_id}` body.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct KickBody {
    /// `banned` (default), `revoked` or `closed`.
    #[serde(default)]
    pub reason: String,
}

/// A JSON `{"error": ...}` with a status.
fn error(status: StatusCode, msg: impl Into<String>) -> Response {
    (status, Json(serde_json::json!({ "error": msg.into() }))).into_response()
}

/// The notice kind named in a request.
pub fn parse_kind(s: &str) -> Option<NoticeKind> {
    match s {
        "" | "info" => Some(NoticeKind::Info),
        "maintenance" => Some(NoticeKind::Maintenance),
        "restart" => Some(NoticeKind::Restart),
        _ => None,
    }
}

/// The admin router (the caller checks that a token is configured).
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/admin/v1/stats", get(stats))
        .route("/admin/v1/stats/full", get(crate::metrics_admin::handler))
        .route("/admin/v1/rooms", get(rooms))
        .route("/admin/v1/rooms/{target}/close", post(close_room))
        .route("/admin/v1/notice", post(notice))
        .route("/admin/v1/kick/{account_id}", post(kick))
        .route("/admin/v1/boards/invalidate", post(invalidate_boards))
        .fallback(|| async { error(StatusCode::NOT_FOUND, "no such admin route") })
        .layer(middleware::from_fn_with_state(state.clone(), authorize))
        .with_state(state)
}

/// Bearer token check (constant time). Every request is counted.
async fn authorize(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let expected = state.config.admin.token.expose().as_bytes();
    let given = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split_once(' '))
        .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer"))
        .map(|(_, t)| t.trim().as_bytes().to_vec())
        .unwrap_or_default();
    let ok = !expected.is_empty() && bool::from(given.as_slice().ct_eq(expected));
    let (method, path) = (req.method().clone(), req.uri().path().to_string());
    if !ok {
        Metrics::inc(&state.metrics.admin_denied);
        tracing::warn!(%method, %path, "admin API request refused (token)");
        return error(StatusCode::UNAUTHORIZED, "bad or missing admin token");
    }
    Metrics::inc(&state.metrics.admin_requests);
    let resp = next.run(req).await;
    tracing::info!(%method, %path, status = resp.status().as_u16(), "admin API request");
    resp
}

/// The live counts (also used by `GET /admin/v1/stats`).
pub fn live_stats(state: &AppState) -> LiveStats {
    let rooms: Vec<RoomSummary> = state.rooms.list();
    let public = rooms
        .iter()
        .filter(|r| r.visibility == protocol::Visibility::Public)
        .count();
    LiveStats {
        version: crate::VERSION.into(),
        build: crate::BUILD.into(),
        uptime_secs: state.started.elapsed().as_secs(),
        draining: state.drain.is_draining(),
        restart_in_secs: state.drain.seconds_left(),
        sessions: state.sessions.len(),
        connections: Metrics::get(&state.metrics.ws_connections),
        rooms: rooms.len(),
        seats: rooms.iter().map(|r| r.accounts.len() as u64).sum(),
        public_rooms: public,
        private_rooms: rooms.len() - public,
    }
}

async fn stats(State(state): State<AppState>) -> Json<LiveStats> {
    Json(live_stats(&state))
}

async fn rooms(State(state): State<AppState>) -> Json<Vec<RoomSummary>> {
    Json(state.rooms.list())
}

/// A room by code (case and dashes forgiven, like invite links) or by numeric id.
fn find_room(state: &AppState, target: &str) -> Option<u32> {
    if let Ok(id) = target.parse::<u32>() {
        if state.rooms.info(id).is_some() {
            return Some(id);
        }
    }
    crate::http::invite_code(target).and_then(|c| state.rooms.find_code(&c))
}

async fn close_room(
    State(state): State<AppState>,
    Path(target): Path<String>,
    body: Option<Json<CloseBody>>,
) -> Response {
    let Some(id) = find_room(&state, &target) else {
        return error(StatusCode::NOT_FOUND, format!("no live room {target}"));
    };
    let message = body.map(|b| b.0.message).unwrap_or_default();
    let notice = (!message.trim().is_empty())
        .then(|| crate::shutdown::notice(NoticeKind::Info, 0, message.trim()));
    match state.rooms.close_room(id, CloseMode::Admin, notice).await {
        Some((code, _)) => {
            crate::db::admin_log(&state.db, "api", "room_close", &code.0, &message)
                .await
                .ok();
            tracing::info!(room = id, code = %code.0, "room closed by an operator");
            Json(serde_json::json!({ "closed": true, "room_id": id, "code": code.0 }))
                .into_response()
        }
        None => error(
            StatusCode::SERVICE_UNAVAILABLE,
            "the room did not answer (it may have just closed)",
        ),
    }
}

async fn notice(State(state): State<AppState>, Json(b): Json<NoticeBody>) -> Response {
    let Some(kind) = parse_kind(&b.kind) else {
        return error(
            StatusCode::BAD_REQUEST,
            "kind must be info, maintenance or restart",
        );
    };
    if b.text.trim().is_empty() {
        return error(StatusCode::BAD_REQUEST, "text is empty");
    }
    let msg = crate::shutdown::notice(kind, b.seconds, b.text.trim());
    let sessions = crate::shutdown::broadcast(&state, &msg);
    crate::db::admin_log(&state.db, "api", "notice", &b.kind, b.text.trim())
        .await
        .ok();
    tracing::info!(kind = %b.kind, seconds = b.seconds, sessions, "admin notice sent");
    Json(serde_json::json!({ "sessions": sessions })).into_response()
}

async fn kick(
    State(state): State<AppState>,
    Path(account_id): Path<u64>,
    body: Option<Json<KickBody>>,
) -> Response {
    let reason = body.map(|b| b.0.reason).unwrap_or_default();
    let why = match reason.as_str() {
        "" | "banned" => Kick::Banned,
        "revoked" => Kick::Revoked,
        "closed" => Kick::Closed,
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "reason must be banned, revoked or closed",
            )
        }
    };
    let account = AccountId(account_id);
    let kicked = match state.sessions.get(account) {
        Some(s) => {
            s.kick(why);
            true
        }
        None => false,
    };
    if why == Kick::Revoked {
        state
            .presence
            .forget_account(i64::try_from(account_id).unwrap_or(i64::MAX));
    }
    Json(serde_json::json!({ "kicked": kicked })).into_response()
}

async fn invalidate_boards(State(state): State<AppState>) -> Json<serde_json::Value> {
    state.boards.invalidate_all();
    Json(serde_json::json!({ "invalidated": true }))
}
