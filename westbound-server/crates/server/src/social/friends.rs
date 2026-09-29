//! Friends, friend requests, blocks and presence reads (N9.1). Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties and matchmaking → Friends and
//! presence" (friend codes in `name#1234` form; adding sends a request that must be
//! accepted; presence; blocking). API: docs/SERVER.md → "Social API".
//!
//! **Pairs.** One `friends` row per pair of accounts (lower id in `account_a`): a pending
//! request (with its requester) or an accepted friendship. A request to someone who already
//! asked you accepts theirs.
//!
//! **Blocks.** A block in either direction refuses friend requests with the same error as an
//! unknown name (`player_not_found`), so a player never learns that someone blocked them.
//! Blocking deletes the pair's friendship or pending request.
//!
//! **Caps** (`[social]`): `max_friends` accepted friends (both sides are checked when a
//! request is sent and when it is accepted), `max_outgoing_requests`,
//! `max_incoming_requests`, `max_blocks`.
//!
//! Every write runs in one `BEGIN IMMEDIATE` transaction (SQLite's single writer), so the
//! checks and the write cannot interleave with another request's. Presence pushes happen
//! after commit.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};
use sqlx::SqliteConnection;

use super::{find_by_full_name, is_blocked, parse_full_name, player, players, Player};
use crate::app::AppState;
use crate::auth::{parse_account_id, Authed};
use crate::error::{ApiError, ApiJson, ApiResult};
use crate::presence::status_str;
use protocol::FriendPresence;

fn player_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "player_not_found",
        "No player with that name can be added.",
    )
}

fn conflict(code: &'static str, message: &str) -> ApiError {
    ApiError::new(StatusCode::CONFLICT, code, message)
}

fn request_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "request_not_found",
        "No such friend request.",
    )
}

/// `(lower, higher)`.
fn pair(a: i64, b: i64) -> (i64, i64) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

/// A presence entry as JSON (`status`: `offline`, `online`, `in_room`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceJson {
    pub account_id: String,
    pub status: String,
    /// The friend's room (N5), `null` when none.
    pub room_id: Option<u32>,
    /// The room has space (the Join button).
    pub joinable: bool,
}

impl From<&FriendPresence> for PresenceJson {
    fn from(p: &FriendPresence) -> Self {
        Self {
            account_id: p.account_id.0.to_string(),
            status: status_str(p.status).to_string(),
            room_id: (p.room_id != 0).then_some(p.room_id),
            joinable: p.joinable,
        }
    }
}

/// A friend, or the other side of a request, with their presence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FriendEntry {
    #[serde(flatten)]
    pub player: Player,
    /// The request's id (decimal string). For a friend, the id its request had.
    pub request_id: String,
    /// When the request was sent.
    pub created_at: i64,
    /// When it was accepted (friends only).
    pub since: Option<i64>,
    /// `offline`, `online` or `in_room`.
    pub status: String,
    pub room_id: Option<u32>,
    pub joinable: bool,
}

/// `GET /api/v1/friends`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FriendsList {
    /// Accepted friends: in a room first, then online, then offline; by name within each.
    pub friends: Vec<FriendEntry>,
    /// Requests waiting for you, newest first.
    pub incoming: Vec<FriendEntry>,
    /// Your requests waiting for them, newest first.
    pub outgoing: Vec<FriendEntry>,
    pub max_friends: u32,
}

/// The result of sending or accepting a request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestOutcome {
    pub request_id: String,
    /// `pending` (sent) or `accepted` (you are friends now).
    pub status: String,
    pub player: Player,
}

struct PairRow {
    id: i64,
    requester_id: i64,
    status: String,
}

async fn pair_row(conn: &mut SqliteConnection, a: i64, b: i64) -> sqlx::Result<Option<PairRow>> {
    let (lo, hi) = pair(a, b);
    let r = sqlx::query!(
        r#"SELECT id AS "id!: i64", requester_id, status FROM friends
           WHERE account_a = ? AND account_b = ?"#,
        lo,
        hi
    )
    .fetch_optional(conn)
    .await?;
    Ok(r.map(|r| PairRow {
        id: r.id,
        requester_id: r.requester_id,
        status: r.status,
    }))
}

/// Accepted friends of the account.
pub async fn friend_count(conn: &mut SqliteConnection, id: i64) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM friends
           WHERE (account_a = ?1 OR account_b = ?1) AND status = 'accepted'"#,
        id
    )
    .fetch_one(conn)
    .await
}

/// Pending requests the account sent (`outgoing`) or received.
async fn pending_count(conn: &mut SqliteConnection, id: i64, outgoing: bool) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM friends
           WHERE (account_a = ?1 OR account_b = ?1) AND status = 'pending'
             AND (requester_id = ?1) = ?2"#,
        id,
        outgoing
    )
    .fetch_one(conn)
    .await
}

/// Refuses when either side already has `max_friends` friends.
async fn check_friend_caps(
    conn: &mut SqliteConnection,
    me: i64,
    other: i64,
    max: u32,
) -> ApiResult<()> {
    let max = i64::from(max);
    if friend_count(&mut *conn, me).await? >= max {
        return Err(conflict(
            "friends_limit",
            "Your friends list is full; remove someone first.",
        ));
    }
    if friend_count(&mut *conn, other).await? >= max {
        return Err(conflict(
            "target_friends_limit",
            "Their friends list is full.",
        ));
    }
    Ok(())
}

async fn accept_row(conn: &mut SqliteConnection, id: i64, now: i64) -> sqlx::Result<()> {
    sqlx::query!(
        "UPDATE friends SET status = 'accepted', accepted_at = ? WHERE id = ?",
        now,
        id
    )
    .execute(conn)
    .await?;
    Ok(())
}

async fn outcome(
    conn: &mut SqliteConnection,
    request_id: i64,
    status: &str,
    other: i64,
) -> ApiResult<RequestOutcome> {
    let player = player(conn, other).await?.ok_or_else(player_not_found)?;
    Ok(RequestOutcome {
        request_id: request_id.to_string(),
        status: status.to_string(),
        player,
    })
}

/// Sends a friend request to `full_name` (`name#1234`). Returns 201 with a pending request,
/// or 200 when they had already asked you (their request is accepted).
pub async fn send_request(
    state: &AppState,
    me: i64,
    full_name: &str,
) -> ApiResult<(StatusCode, RequestOutcome)> {
    let (name, tag) = parse_full_name(full_name).ok_or_else(|| {
        ApiError::bad_request("invalid_full_name", "A friend code looks like name#1234.")
    })?;
    let cfg = &state.config.social;
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let other = find_by_full_name(&mut tx, &name, tag)
        .await?
        .ok_or_else(player_not_found)?;
    if other == me {
        return Err(ApiError::bad_request(
            "cannot_friend_self",
            "That is your own friend code.",
        ));
    }
    if is_blocked(&mut tx, me, other).await? {
        return Err(player_not_found());
    }
    let (status, id) = match pair_row(&mut tx, me, other).await? {
        Some(r) if r.status == "accepted" => {
            return Err(conflict("already_friends", "You are already friends."));
        }
        Some(r) if r.requester_id == me => {
            return Err(conflict(
                "request_exists",
                "You already sent them a request.",
            ));
        }
        Some(r) => {
            // They asked first: this accepts their request.
            check_friend_caps(&mut tx, me, other, cfg.max_friends).await?;
            accept_row(&mut tx, r.id, now).await?;
            (StatusCode::OK, r.id)
        }
        None => {
            check_friend_caps(&mut tx, me, other, cfg.max_friends).await?;
            if pending_count(&mut tx, me, true).await? >= i64::from(cfg.max_outgoing_requests) {
                return Err(conflict(
                    "requests_limit",
                    "Too many requests waiting for an answer; cancel some first.",
                ));
            }
            if pending_count(&mut tx, other, false).await? >= i64::from(cfg.max_incoming_requests) {
                return Err(conflict(
                    "target_requests_limit",
                    "They have too many requests waiting. Try again later.",
                ));
            }
            let (lo, hi) = pair(me, other);
            let id = sqlx::query!(
                "INSERT INTO friends (account_a, account_b, requester_id, status, created_at)
                 VALUES (?, ?, ?, 'pending', ?)",
                lo,
                hi,
                me,
                now
            )
            .execute(&mut *tx)
            .await?
            .last_insert_rowid();
            (StatusCode::CREATED, id)
        }
    };
    let accepted = status == StatusCode::OK;
    let out = outcome(
        &mut tx,
        id,
        if accepted { "accepted" } else { "pending" },
        other,
    )
    .await?;
    tx.commit().await?;
    if accepted {
        state.presence.friendship_added(me, other);
    }
    Ok((status, out))
}

/// Accepts a request sent to `me`.
pub async fn accept(state: &AppState, me: i64, request_id: i64) -> ApiResult<RequestOutcome> {
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let r = sqlx::query!(
        r#"SELECT account_a, account_b, requester_id FROM friends
           WHERE id = ? AND status = 'pending'"#,
        request_id
    )
    .fetch_optional(&mut *tx)
    .await?
    .filter(|r| r.requester_id != me && (r.account_a == me || r.account_b == me))
    .ok_or_else(request_not_found)?;
    let other = r.requester_id;
    check_friend_caps(&mut tx, me, other, state.config.social.max_friends).await?;
    accept_row(&mut tx, request_id, now).await?;
    let out = outcome(&mut tx, request_id, "accepted", other).await?;
    tx.commit().await?;
    state.presence.friendship_added(me, other);
    Ok(out)
}

/// Declines a request sent to `me`, or cancels one `me` sent.
pub async fn decline(state: &AppState, me: i64, request_id: i64) -> ApiResult<()> {
    let done = sqlx::query!(
        "DELETE FROM friends WHERE id = ?1 AND status = 'pending'
           AND (account_a = ?2 OR account_b = ?2)",
        request_id,
        me
    )
    .execute(&state.db)
    .await?;
    if done.rows_affected() == 0 {
        return Err(request_not_found());
    }
    Ok(())
}

/// Removes a friend, or a pending request either way, between `me` and `other`.
pub async fn remove(state: &AppState, me: i64, other: i64) -> ApiResult<()> {
    let (lo, hi) = pair(me, other);
    let done = sqlx::query!(
        "DELETE FROM friends WHERE account_a = ? AND account_b = ?",
        lo,
        hi
    )
    .execute(&state.db)
    .await?;
    if done.rows_affected() == 0 {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "friend_not_found",
            "They are not on your friends list.",
        ));
    }
    state.presence.friendship_removed(me, other);
    Ok(())
}

fn status_rank(s: &str) -> u8 {
    match s {
        "in_room" => 0,
        "online" => 1,
        _ => 2,
    }
}

/// The friends list with requests and presence.
pub async fn list(state: &AppState, me: i64) -> ApiResult<FriendsList> {
    let mut conn = state.db.acquire().await?;
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: i64", account_a, account_b, requester_id, status, created_at,
                  accepted_at
           FROM friends WHERE account_a = ?1 OR account_b = ?1"#,
        me
    )
    .fetch_all(&mut *conn)
    .await?;
    let others: Vec<i64> = rows
        .iter()
        .map(|r| {
            if r.account_a == me {
                r.account_b
            } else {
                r.account_a
            }
        })
        .collect();
    let players = players(&mut conn, &others).await?;
    drop(conn);
    let presence = state.presence.statuses(&others);
    let mut list = FriendsList {
        friends: Vec::new(),
        incoming: Vec::new(),
        outgoing: Vec::new(),
        max_friends: state.config.social.max_friends,
    };
    for ((r, other), p) in rows.iter().zip(&others).zip(&presence) {
        let Some(player) = players.get(other) else {
            continue;
        };
        let p = PresenceJson::from(p);
        let entry = FriendEntry {
            player: player.clone(),
            request_id: r.id.to_string(),
            created_at: r.created_at,
            since: r.accepted_at,
            status: p.status,
            room_id: p.room_id,
            joinable: p.joinable,
        };
        match (r.status.as_str(), r.requester_id == me) {
            ("accepted", _) => list.friends.push(entry),
            (_, true) => list.outgoing.push(entry),
            (_, false) => list.incoming.push(entry),
        }
    }
    list.friends.sort_by(|a, b| {
        (status_rank(&a.status), a.player.full_name.to_lowercase())
            .cmp(&(status_rank(&b.status), b.player.full_name.to_lowercase()))
    });
    for l in [&mut list.incoming, &mut list.outgoing] {
        l.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    }
    Ok(list)
}

/// `GET /api/v1/presence`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceList {
    pub friends: Vec<PresenceJson>,
}

/// The presence of `me`'s accepted friends.
pub async fn presence(state: &AppState, me: i64) -> ApiResult<PresenceList> {
    let mut conn = state.db.acquire().await?;
    let mut ids = super::friend_ids(&mut conn, me).await?.unwrap_or_default();
    drop(conn);
    ids.sort_unstable();
    Ok(PresenceList {
        friends: state
            .presence
            .statuses(&ids)
            .iter()
            .map(PresenceJson::from)
            .collect(),
    })
}

// ------------------------------------------------------------------------------------------
// Blocks
// ------------------------------------------------------------------------------------------

/// A blocked player.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockEntry {
    #[serde(flatten)]
    pub player: Player,
    pub blocked_at: i64,
}

/// `GET /api/v1/blocks`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockList {
    /// Newest first.
    pub blocks: Vec<BlockEntry>,
    pub max_blocks: u32,
}

/// Blocks `other`: deletes the pair's friendship or pending request. 201, or 200 when
/// already blocked.
pub async fn block(state: &AppState, me: i64, other: i64) -> ApiResult<(StatusCode, BlockEntry)> {
    if other == me {
        return Err(ApiError::bad_request(
            "cannot_block_self",
            "You cannot block yourself.",
        ));
    }
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let target = player(&mut tx, other).await?.ok_or_else(|| {
        ApiError::new(StatusCode::NOT_FOUND, "player_not_found", "No such player.")
    })?;
    let existing = sqlx::query_scalar!(
        "SELECT created_at FROM blocks WHERE account_id = ? AND blocked_id = ?",
        me,
        other
    )
    .fetch_optional(&mut *tx)
    .await?;
    if let Some(at) = existing {
        return Ok((
            StatusCode::OK,
            BlockEntry {
                player: target,
                blocked_at: at,
            },
        ));
    }
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM blocks WHERE account_id = ?"#,
        me
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= i64::from(state.config.social.max_blocks) {
        return Err(conflict(
            "blocks_limit",
            "Your block list is full; unblock someone first.",
        ));
    }
    sqlx::query!(
        "INSERT INTO blocks (account_id, blocked_id, created_at) VALUES (?, ?, ?)",
        me,
        other,
        now
    )
    .execute(&mut *tx)
    .await?;
    let (lo, hi) = pair(me, other);
    let unfriended = sqlx::query!(
        "DELETE FROM friends WHERE account_a = ? AND account_b = ?",
        lo,
        hi
    )
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;
    if unfriended > 0 {
        state.presence.friendship_removed(me, other);
    }
    Ok((
        StatusCode::CREATED,
        BlockEntry {
            player: target,
            blocked_at: now,
        },
    ))
}

/// Lifts `me`'s block of `other`.
pub async fn unblock(state: &AppState, me: i64, other: i64) -> ApiResult<()> {
    let done = sqlx::query!(
        "DELETE FROM blocks WHERE account_id = ? AND blocked_id = ?",
        me,
        other
    )
    .execute(&state.db)
    .await?;
    if done.rows_affected() == 0 {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "block_not_found",
            "You have not blocked that player.",
        ));
    }
    Ok(())
}

/// The accounts `me` blocked.
pub async fn blocks(state: &AppState, me: i64) -> ApiResult<BlockList> {
    let mut conn = state.db.acquire().await?;
    let rows = sqlx::query!(
        "SELECT blocked_id, created_at FROM blocks WHERE account_id = ?
         ORDER BY created_at DESC, blocked_id DESC",
        me
    )
    .fetch_all(&mut *conn)
    .await?;
    let ids: Vec<i64> = rows.iter().map(|r| r.blocked_id).collect();
    let players = players(&mut conn, &ids).await?;
    Ok(BlockList {
        blocks: rows
            .iter()
            .filter_map(|r| {
                players.get(&r.blocked_id).map(|p| BlockEntry {
                    player: p.clone(),
                    blocked_at: r.created_at,
                })
            })
            .collect(),
        max_blocks: state.config.social.max_blocks,
    })
}

// ------------------------------------------------------------------------------------------
// Routes
// ------------------------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FriendRequestBody {
    /// `name#1234`.
    pub full_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccountBody {
    /// Decimal string.
    pub account_id: String,
}

/// A path or body id (a positive decimal); anything else is `not_found` with `code`.
pub fn path_id(s: &str, code: &'static str, message: &'static str) -> ApiResult<i64> {
    parse_account_id(s).ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, code, message))
}

/// A body `account_id`.
pub fn body_account_id(s: &str) -> ApiResult<i64> {
    parse_account_id(s).ok_or_else(|| {
        ApiError::bad_request("invalid_body", "`account_id` must be a decimal account id.")
    })
}

/// `POST /api/v1/friends/requests` `{"full_name": "name#1234"}`.
pub async fn post_request(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(body): ApiJson<FriendRequestBody>,
) -> ApiResult<(StatusCode, Json<RequestOutcome>)> {
    let (status, out) = send_request(&state, auth.account_id, &body.full_name).await?;
    Ok((status, Json(out)))
}

/// `GET /api/v1/friends`.
pub async fn get_friends(
    State(state): State<AppState>,
    auth: Authed,
) -> ApiResult<Json<FriendsList>> {
    Ok(Json(list(&state, auth.account_id).await?))
}

/// `POST /api/v1/friends/requests/{id}/accept`.
pub async fn post_accept(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<RequestOutcome>> {
    let id = path_id(&id, "request_not_found", "No such friend request.")?;
    Ok(Json(accept(&state, auth.account_id, id).await?))
}

/// `POST /api/v1/friends/requests/{id}/decline` (also cancels your own request).
pub async fn post_decline(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id = path_id(&id, "request_not_found", "No such friend request.")?;
    decline(&state, auth.account_id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /api/v1/friends/{account_id}`.
pub async fn delete_friend(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id = path_id(
        &id,
        "friend_not_found",
        "They are not on your friends list.",
    )?;
    remove(&state, auth.account_id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /api/v1/presence`.
pub async fn get_presence(
    State(state): State<AppState>,
    auth: Authed,
) -> ApiResult<Json<PresenceList>> {
    Ok(Json(presence(&state, auth.account_id).await?))
}

/// `POST /api/v1/blocks` `{"account_id": "42"}`.
pub async fn post_block(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(body): ApiJson<AccountBody>,
) -> ApiResult<(StatusCode, Json<BlockEntry>)> {
    let other = body_account_id(&body.account_id)?;
    let (status, entry) = block(&state, auth.account_id, other).await?;
    Ok((status, Json(entry)))
}

/// `DELETE /api/v1/blocks/{account_id}`.
pub async fn delete_block(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let id = path_id(&id, "block_not_found", "You have not blocked that player.")?;
    unblock(&state, auth.account_id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /api/v1/blocks`.
pub async fn get_blocks(State(state): State<AppState>, auth: Authed) -> ApiResult<Json<BlockList>> {
    Ok(Json(blocks(&state, auth.account_id).await?))
}
