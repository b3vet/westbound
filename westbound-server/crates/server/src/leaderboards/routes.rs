//! `GET /api/v1/boards/{board}?period=&view=&limit=`. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → "Leaderboards" (API, views). Shapes: docs/SERVER.md → "Leaderboards & runs API".
//!
//! - `period`: a key the board keeps (`YYYY-MM`, `YYYY-Www`, `YYYY-MM-DD` or `all`);
//!   left out or `current`: the board's current default period.
//! - `view`: `global` (default; the top `limit`, public), `around_me` (`limit` ranks on
//!   each side of the caller) or `friends` (the caller and their friends). The last two
//!   need the bearer token; `global` reads it when sent, to add `me`.
//! - `limit`: `global` 1..=`leaderboards.global_limit_max`, `around_me`
//!   1..=`leaderboards.around_me_max`; defaults from the config.

use axum::extract::{Path, RawQuery, State};
use axum::http::StatusCode;
use axum::Json;

use super::{Board, BoardView, View};
use crate::app::AppState;
use crate::auth::OptionalAuthed;
use crate::error::{ApiError, ApiResult};

/// The longest query string read (a few short parameters).
const MAX_QUERY_BYTES: usize = 256;
/// `period=current` asks for the default period explicitly.
const CURRENT: &str = "current";

struct Params<'a> {
    period: Option<&'a str>,
    view: Option<&'a str>,
    limit: Option<&'a str>,
}

/// Splits `a=1&b=2`. Values are plain ASCII tokens (no percent-encoding needed); a
/// repeated or unknown parameter is an error.
fn parse_query(q: &str) -> Result<Params<'_>, ApiError> {
    let bad = |m: String| ApiError::bad_request("invalid_query", m);
    if q.len() > MAX_QUERY_BYTES {
        return Err(bad("Query string too long.".into()));
    }
    let mut p = Params {
        period: None,
        view: None,
        limit: None,
    };
    for pair in q.split('&').filter(|s| !s.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let slot = match k {
            "period" => &mut p.period,
            "view" => &mut p.view,
            "limit" => &mut p.limit,
            _ => return Err(bad(format!("Unknown parameter `{k}`."))),
        };
        if slot.replace(v).is_some() {
            return Err(bad(format!("Parameter `{k}` given twice.")));
        }
    }
    Ok(p)
}

/// `GET /api/v1/boards/{board}`.
pub async fn get_board(
    State(state): State<AppState>,
    Path(board): Path<String>,
    RawQuery(query): RawQuery,
    OptionalAuthed(auth): OptionalAuthed,
) -> ApiResult<Json<BoardView>> {
    let board = Board::parse(&board).ok_or_else(|| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "unknown_board",
            "Boards: loop, loop_crew, journey, daily, distance.",
        )
    })?;
    let q = parse_query(query.as_deref().unwrap_or(""))?;
    let now = state.clock.now();
    let period = match q.period.filter(|p| !p.is_empty() && *p != CURRENT) {
        None => board.current_period(now),
        Some(key) => board.parse_period(key).ok_or_else(|| {
            let kinds: Vec<&str> = board.periods().iter().map(|k| k.as_str()).collect();
            ApiError::bad_request(
                "invalid_period",
                format!(
                    "Board `{}` keeps these periods: {}.",
                    board.id(),
                    kinds.join(", ")
                ),
            )
        })?,
    };
    let view = match q.view.filter(|v| !v.is_empty()) {
        None => View::Global,
        Some(v) => View::parse(v).ok_or_else(|| {
            ApiError::bad_request("invalid_view", "Views: global, around_me, friends.")
        })?,
    };
    let cfg = state.boards.config();
    let (default, max) = match view {
        View::AroundMe => (cfg.around_me_default, cfg.around_me_max),
        View::Global | View::Friends => (cfg.global_limit_default, cfg.global_limit_max),
    };
    let limit = match q.limit.filter(|l| !l.is_empty()) {
        None => default,
        Some(l) => l
            .parse::<u32>()
            .ok()
            .filter(|n| (1..=max).contains(n))
            .ok_or_else(|| {
                ApiError::bad_request("invalid_limit", format!("`limit` must be 1..={max}."))
            })?,
    };
    let caller = auth.map(|a| a.account_id);
    if caller.is_none() && view != View::Global {
        return Err(ApiError::unauthorized(
            "unauthorized",
            "This view needs `Authorization: Bearer <token>`.",
        ));
    }
    let body = state
        .boards
        .read(board, &period, view, limit, caller)
        .await?;
    Ok(Json(body))
}
