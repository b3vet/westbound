//! Persistent crews (N9.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties and
//! matchmaking → Crews (persistent)" (a named crew with a 2–4 character tag and up to 16
//! members, joined by invite code; the owner and officers can kick; the tag shows on
//! nametags and leaderboards), "Moderation" (profanity filter on crew names),
//! "Leaderboards → Loop crew". API: docs/SERVER.md → "Social API → Crews".
//!
//! **Rules.**
//! - One crew per account; at most `social.crew_max_members` (16) members, owner included.
//! - Names: the display-name rules (letters incl. Turkish, digits, single separators) with
//!   3–24 characters, profanity-filtered, unique case-insensitively. Tags: 2–4 characters
//!   `A–Z 0–9`, stored upper case, profanity-filtered, unique.
//! - Roles: `owner` (one), `officer`, `member`. The owner and officers kick; officers only
//!   kick members. The owner promotes, demotes, transfers ownership and disbands. The owner
//!   and officers rotate the invite code. Every member sees the code.
//! - When the owner leaves (or deletes their account) the crew passes to the
//!   longest-standing officer, else the longest-standing member; with nobody left it is
//!   disbanded.
//! - Every membership change recomputes the crew's Loop crew score for the current season
//!   (`leaderboards::recompute_crew`) in the same transaction. Disbanding deletes the crew's
//!   Loop crew entries (every season: the crew no longer exists to show).

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};
use sqlx::SqliteConnection;

use super::friends::{body_account_id, path_id};
use crate::app::AppState;
use crate::auth::Authed;
use crate::config::LeaderboardsConfig;
use crate::error::{ApiError, ApiJson, ApiResult};
use crate::leaderboards::{self, Board, Period, PeriodKind};
use crate::names::{self, NameError};
use crate::profanity::ProfanityFilter;

pub const MIN_CREW_NAME_CHARS: usize = 3;
pub const MAX_CREW_NAME_CHARS: usize = 24;
pub const MIN_CREW_TAG_CHARS: usize = 2;
/// The protocol's crew tag limit (nametags carry it).
pub const MAX_CREW_TAG_CHARS: usize = protocol::types::MAX_CREW_TAG_CHARS;
/// Longest invite code accepted as input (anything longer cannot exist).
const MAX_CODE_INPUT_CHARS: usize = 32;
/// Invite codes drawn before giving up on a collision (the space is 31^8).
const CODE_ATTEMPTS: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Owner,
    Officer,
    Member,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Owner => "owner",
            Role::Officer => "officer",
            Role::Member => "member",
        }
    }

    pub fn parse(s: &str) -> Option<Role> {
        match s {
            "owner" => Some(Role::Owner),
            "officer" => Some(Role::Officer),
            "member" => Some(Role::Member),
            _ => None,
        }
    }
}

/// One account's crew membership.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Membership {
    pub crew_id: i64,
    pub account_id: i64,
    pub role: Role,
    pub joined_at: i64,
}

pub async fn membership(
    conn: &mut SqliteConnection,
    account_id: i64,
) -> sqlx::Result<Option<Membership>> {
    let r = sqlx::query!(
        "SELECT crew_id, role, joined_at FROM crew_members WHERE account_id = ?",
        account_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(r.map(|r| Membership {
        crew_id: r.crew_id,
        account_id,
        role: Role::parse(&r.role).unwrap_or(Role::Member),
        joined_at: r.joined_at,
    }))
}

/// The crew's members' account ids, longest-standing first.
pub async fn member_ids(conn: &mut SqliteConnection, crew_id: i64) -> sqlx::Result<Vec<i64>> {
    sqlx::query_scalar!(
        r#"SELECT account_id AS "account_id!: i64" FROM crew_members WHERE crew_id = ?
           ORDER BY joined_at, account_id"#,
        crew_id
    )
    .fetch_all(conn)
    .await
}

async fn member_count(conn: &mut SqliteConnection, crew_id: i64) -> sqlx::Result<i64> {
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM crew_members WHERE crew_id = ?"#,
        crew_id
    )
    .fetch_one(conn)
    .await
}

/// A crew name: the display-name rules with 3–24 characters, and the filter.
pub fn validate_name(raw: &str) -> Result<String, ApiError> {
    names::validate_len(
        raw,
        ProfanityFilter::builtin(),
        MIN_CREW_NAME_CHARS,
        MAX_CREW_NAME_CHARS,
    )
    .map_err(|e| match e {
        NameError::NotAllowed => {
            ApiError::bad_request("crew_name_not_allowed", "That crew name is not allowed.")
        }
        NameError::Length => ApiError::bad_request(
            "invalid_crew_name",
            format!(
                "A crew name must be {MIN_CREW_NAME_CHARS} to {MAX_CREW_NAME_CHARS} characters."
            ),
        ),
        other => ApiError::bad_request("invalid_crew_name", other.to_string()),
    })
}

/// A crew tag: 2–4 characters `A–Z 0–9` (any case in, upper case out), and the filter.
pub fn validate_tag(raw: &str) -> Result<String, ApiError> {
    let tag = raw.trim().to_ascii_uppercase();
    let len = tag.chars().count();
    if !(MIN_CREW_TAG_CHARS..=MAX_CREW_TAG_CHARS).contains(&len)
        || !tag.bytes().all(|b| b.is_ascii_alphanumeric())
    {
        return Err(ApiError::bad_request(
            "invalid_crew_tag",
            format!(
                "A crew tag is {MIN_CREW_TAG_CHARS} to {MAX_CREW_TAG_CHARS} letters or digits."
            ),
        ));
    }
    if !ProfanityFilter::builtin().is_clean(&tag) {
        return Err(ApiError::bad_request(
            "crew_tag_not_allowed",
            "That crew tag is not allowed.",
        ));
    }
    Ok(tag)
}

/// A random invite code of `len` characters from the room-code alphabet (no 0/O, 1/I/L).
pub fn new_invite_code(len: u32) -> String {
    let alphabet: Vec<char> = protocol::types::CODE_ALPHABET.chars().collect();
    (0..len)
        .map(|_| alphabet[crate::auth::random_below(alphabet.len() as u32) as usize])
        .collect()
}

fn is_unique_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(d) if d.is_unique_violation())
}

/// Refuses a name or tag another crew (other than `except`) already uses.
async fn check_unique(
    conn: &mut SqliteConnection,
    name: Option<&str>,
    tag: Option<&str>,
    except: i64,
) -> ApiResult<()> {
    if let Some(name) = name {
        let n = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM crews WHERE name = ? AND id != ?"#,
            name,
            except
        )
        .fetch_one(&mut *conn)
        .await?;
        if n > 0 {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "crew_name_taken",
                "Another crew has that name.",
            ));
        }
    }
    if let Some(tag) = tag {
        let n = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM crews WHERE tag = ? AND id != ?"#,
            tag,
            except
        )
        .fetch_one(&mut *conn)
        .await?;
        if n > 0 {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "crew_tag_taken",
                "Another crew has that tag.",
            ));
        }
    }
    Ok(())
}

/// Deletes a crew, its memberships and its Loop crew entries (every season).
pub async fn disband_rows(conn: &mut SqliteConnection, crew_id: i64) -> sqlx::Result<bool> {
    let crew_board = Board::LoopCrew.id();
    sqlx::query!(
        "DELETE FROM leaderboard_entries WHERE board = ? AND subject_id = ?",
        crew_board,
        crew_id
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!("DELETE FROM crew_members WHERE crew_id = ?", crew_id)
        .execute(&mut *conn)
        .await?;
    sqlx::query!("DELETE FROM crew_invites WHERE crew_id = ?", crew_id)
        .execute(&mut *conn)
        .await?;
    let done = sqlx::query!("DELETE FROM crews WHERE id = ?", crew_id)
        .execute(&mut *conn)
        .await?;
    Ok(done.rows_affected() == 1)
}

/// What removing a member did to the crew.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RemoveOutcome {
    /// The owner left and the crew passed to this account.
    pub new_owner: Option<i64>,
    /// The last member left and the crew was disbanded.
    pub disbanded: bool,
}

/// Removes a membership (leave, kick, account deletion). An owner's crew passes to the
/// longest-standing officer, else member, or is disbanded when nobody is left. Recomputes
/// the crew's current-season Loop crew score.
pub async fn remove_member(
    conn: &mut SqliteConnection,
    m: &Membership,
    boards: &LeaderboardsConfig,
    now: i64,
) -> sqlx::Result<RemoveOutcome> {
    sqlx::query!(
        "DELETE FROM crew_members WHERE account_id = ?",
        m.account_id
    )
    .execute(&mut *conn)
    .await?;
    let mut out = RemoveOutcome::default();
    if m.role == Role::Owner {
        let next = sqlx::query_scalar!(
            r#"SELECT account_id AS "account_id!: i64" FROM crew_members WHERE crew_id = ?
               ORDER BY role = 'officer' DESC, joined_at ASC, account_id ASC LIMIT 1"#,
            m.crew_id
        )
        .fetch_optional(&mut *conn)
        .await?;
        match next {
            Some(id) => {
                set_owner(conn, m.crew_id, id).await?;
                out.new_owner = Some(id);
            }
            None => {
                disband_rows(conn, m.crew_id).await?;
                out.disbanded = true;
                return Ok(out);
            }
        }
    }
    let season = Period::at(PeriodKind::Season, now);
    leaderboards::recompute_crew(conn, boards, m.crew_id, &season, now).await?;
    Ok(out)
}

/// Makes `account` the owner (it must be a member).
async fn set_owner(conn: &mut SqliteConnection, crew_id: i64, account: i64) -> sqlx::Result<()> {
    sqlx::query!(
        "UPDATE crew_members SET role = 'owner' WHERE account_id = ? AND crew_id = ?",
        account,
        crew_id
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!(
        "UPDATE crews SET owner_id = ? WHERE id = ?",
        account,
        crew_id
    )
    .execute(&mut *conn)
    .await?;
    Ok(())
}

// ------------------------------------------------------------------------------------------
// Views
// ------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CrewMember {
    pub account_id: String,
    pub display_name: String,
    /// The `#1234` suffix.
    pub tag: u16,
    pub full_name: String,
    pub role: Role,
    pub joined_at: i64,
    /// Presence (`offline`, `online`, `in_room`) for the viewer's own crew (room invites
    /// list online crewmates); `null` for anyone else's crew.
    #[serde(default)]
    pub status: Option<String>,
}

/// `GET /api/v1/crews/{id}` and every crew write's answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CrewView {
    pub crew_id: String,
    pub name: String,
    /// 2–4 characters, upper case.
    pub tag: String,
    pub owner_id: String,
    pub created_at: i64,
    pub member_count: u32,
    pub max_members: u32,
    /// Owner first, then officers, then members, each by join time.
    pub members: Vec<CrewMember>,
    /// Only for members (`null` otherwise).
    pub invite_code: Option<String>,
    /// The caller's role, `null` when not a member.
    pub your_role: Option<Role>,
}

/// A crew as `viewer` sees it, or `None` if there is no such crew.
pub async fn view(
    conn: &mut SqliteConnection,
    crew_id: i64,
    viewer: Option<i64>,
    max_members: u32,
) -> sqlx::Result<Option<CrewView>> {
    let Some(c) = sqlx::query!(
        "SELECT name, tag, owner_id, invite_code, created_at FROM crews WHERE id = ?",
        crew_id
    )
    .fetch_optional(&mut *conn)
    .await?
    else {
        return Ok(None);
    };
    let rows = sqlx::query!(
        r#"SELECT m.account_id AS "account_id!: i64", m.role, m.joined_at, a.display_name, a.tag
           FROM crew_members m JOIN accounts a ON a.id = m.account_id
           WHERE m.crew_id = ?
           ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'officer' THEN 1 ELSE 2 END,
                    m.joined_at, m.account_id"#,
        crew_id
    )
    .fetch_all(&mut *conn)
    .await?;
    let members: Vec<CrewMember> = rows
        .into_iter()
        .map(|r| {
            let tag = u16::try_from(r.tag).unwrap_or(0);
            CrewMember {
                account_id: r.account_id.to_string(),
                full_name: names::full_name(&r.display_name, tag),
                display_name: r.display_name,
                tag,
                role: Role::parse(&r.role).unwrap_or(Role::Member),
                joined_at: r.joined_at,
                status: None,
            }
        })
        .collect();
    let your_role = viewer.and_then(|v| {
        members
            .iter()
            .find(|m| m.account_id == v.to_string())
            .map(|m| m.role)
    });
    Ok(Some(CrewView {
        crew_id: crew_id.to_string(),
        name: c.name,
        tag: c.tag,
        owner_id: c.owner_id.to_string(),
        created_at: c.created_at,
        member_count: members.len() as u32,
        max_members,
        members,
        invite_code: your_role.is_some().then_some(c.invite_code),
        your_role,
    }))
}

// ------------------------------------------------------------------------------------------
// Actions
// ------------------------------------------------------------------------------------------

fn crew_not_found() -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, "crew_not_found", "No such crew.")
}

fn not_in_crew() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "not_in_crew",
        "You are not in that crew.",
    )
}

fn not_permitted(what: &str) -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        "not_permitted",
        format!("Your crew role cannot {what}."),
    )
}

fn member_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "member_not_found",
        "That player is not in your crew.",
    )
}

fn already_in_crew() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "already_in_crew",
        "You are already in a crew; leave it first.",
    )
}

/// The caller's membership in `crew_id`, or `not_in_crew`.
async fn my_membership(
    conn: &mut SqliteConnection,
    me: i64,
    crew_id: i64,
) -> ApiResult<Membership> {
    membership(conn, me)
        .await?
        .filter(|m| m.crew_id == crew_id)
        .ok_or_else(not_in_crew)
}

/// Another member of the caller's crew, or `member_not_found`.
async fn their_membership(
    conn: &mut SqliteConnection,
    account: i64,
    crew_id: i64,
) -> ApiResult<Membership> {
    membership(conn, account)
        .await?
        .filter(|m| m.crew_id == crew_id)
        .ok_or_else(member_not_found)
}

async fn view_or_404(
    conn: &mut SqliteConnection,
    state: &AppState,
    crew_id: i64,
    viewer: i64,
) -> ApiResult<CrewView> {
    let mut v = view(
        conn,
        crew_id,
        Some(viewer),
        state.config.social.crew_max_members,
    )
    .await?
    .ok_or_else(crew_not_found)?;
    if v.your_role.is_some() {
        // A member sees who of the crew is online (room invites, protocol 2).
        let ids: Vec<i64> = v
            .members
            .iter()
            .filter_map(|m| m.account_id.parse().ok())
            .collect();
        let presence = state.presence.statuses(&ids);
        for (m, p) in v.members.iter_mut().zip(&presence) {
            m.status = Some(crate::presence::status_str(p.status).to_string());
        }
    }
    Ok(v)
}

fn invalidate_season(state: &AppState) {
    let season = Period::at(PeriodKind::Season, state.clock.now());
    state.boards.invalidate(Board::LoopCrew, &season.key);
}

/// Creates a crew with `me` as its owner.
pub async fn create(state: &AppState, me: i64, name: &str, tag: &str) -> ApiResult<CrewView> {
    let name = validate_name(name)?;
    let tag = validate_tag(tag)?;
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    if membership(&mut tx, me).await?.is_some() {
        return Err(already_in_crew());
    }
    check_unique(&mut tx, Some(&name), Some(&tag), 0).await?;
    let mut crew_id = None;
    for _ in 0..CODE_ATTEMPTS {
        let code = new_invite_code(state.config.social.crew_invite_code_len);
        let r = sqlx::query!(
            "INSERT INTO crews (name, tag, owner_id, invite_code, created_at)
             VALUES (?, ?, ?, ?, ?)",
            name,
            tag,
            me,
            code,
            now
        )
        .execute(&mut *tx)
        .await;
        match r {
            Ok(done) => {
                crew_id = Some(done.last_insert_rowid());
                break;
            }
            // Name and tag were checked in this transaction: a collision is the code.
            Err(e) if is_unique_violation(&e) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    let crew_id = crew_id.ok_or_else(|| ApiError::internal("no free crew invite code"))?;
    sqlx::query!(
        "INSERT INTO crew_members (account_id, crew_id, role, joined_at)
         VALUES (?, ?, 'owner', ?)",
        me,
        crew_id,
        now
    )
    .execute(&mut *tx)
    .await?;
    let season = Period::at(PeriodKind::Season, now);
    leaderboards::recompute_crew(&mut tx, state.boards.config(), crew_id, &season, now).await?;
    let v = view_or_404(&mut tx, state, crew_id, me).await?;
    tx.commit().await?;
    invalidate_season(state);
    tracing::info!(account_id = me, crew_id, "crew created");
    Ok(v)
}

/// Joins the crew with this invite code (any case; spaces ignored).
pub async fn join(state: &AppState, me: i64, code: &str) -> ApiResult<CrewView> {
    let code: String = code
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_ascii_uppercase();
    let bad_code = || {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "invalid_invite_code",
            "No crew has that invite code.",
        )
    };
    if code.is_empty() || code.chars().count() > MAX_CODE_INPUT_CHARS {
        return Err(bad_code());
    }
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let crew_id = sqlx::query_scalar!("SELECT id FROM crews WHERE invite_code = ?", code)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(bad_code)?;
    let v = join_tx(&mut tx, state, me, crew_id, now).await?;
    tx.commit().await?;
    invalidate_season(state);
    Ok(v)
}

fn crew_full() -> ApiError {
    ApiError::new(StatusCode::CONFLICT, "crew_full", "That crew is full.")
}

/// Makes `me` a member of `crew_id` inside the caller's transaction (join by code, an
/// accepted invite): `already_in_crew`, `crew_full`; recomputes the crew's season score and
/// drops the crew's invite to `me`.
async fn join_tx(
    conn: &mut SqliteConnection,
    state: &AppState,
    me: i64,
    crew_id: i64,
    now: i64,
) -> ApiResult<CrewView> {
    if membership(&mut *conn, me).await?.is_some() {
        return Err(already_in_crew());
    }
    if member_count(&mut *conn, crew_id).await? >= i64::from(state.config.social.crew_max_members) {
        return Err(crew_full());
    }
    sqlx::query!(
        "INSERT INTO crew_members (account_id, crew_id, role, joined_at)
         VALUES (?, ?, 'member', ?)",
        me,
        crew_id,
        now
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!(
        "DELETE FROM crew_invites WHERE crew_id = ? AND account_id = ?",
        crew_id,
        me
    )
    .execute(&mut *conn)
    .await?;
    let season = Period::at(PeriodKind::Season, now);
    leaderboards::recompute_crew(conn, state.boards.config(), crew_id, &season, now).await?;
    view_or_404(conn, state, crew_id, me).await
}

/// Leaves the crew (an owner's crew passes on, or is disbanded when they were alone).
pub async fn leave(state: &AppState, me: i64, crew_id: i64) -> ApiResult<RemoveOutcome> {
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let m = my_membership(&mut tx, me, crew_id).await?;
    let out = remove_member(&mut tx, &m, state.boards.config(), now).await?;
    tx.commit().await?;
    if out.disbanded {
        state.boards.invalidate_all();
    } else {
        invalidate_season(state);
    }
    Ok(out)
}

/// Kicks `target` (owner: anyone; officer: members only).
pub async fn kick(state: &AppState, me: i64, crew_id: i64, target: i64) -> ApiResult<CrewView> {
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let mine = my_membership(&mut tx, me, crew_id).await?;
    if target == me {
        return Err(ApiError::bad_request(
            "cannot_kick_self",
            "Leave the crew instead.",
        ));
    }
    if mine.role == Role::Member {
        return Err(not_permitted("kick"));
    }
    let theirs = their_membership(&mut tx, target, crew_id).await?;
    if mine.role == Role::Officer && theirs.role != Role::Member {
        return Err(not_permitted("kick officers or the owner"));
    }
    remove_member(&mut tx, &theirs, state.boards.config(), now).await?;
    let v = view_or_404(&mut tx, state, crew_id, me).await?;
    tx.commit().await?;
    invalidate_season(state);
    Ok(v)
}

/// Owner only: makes a member an officer (`Role::Officer`) or an officer a member.
pub async fn set_role(
    state: &AppState,
    me: i64,
    crew_id: i64,
    target: i64,
    role: Role,
) -> ApiResult<CrewView> {
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let mine = my_membership(&mut tx, me, crew_id).await?;
    if mine.role != Role::Owner {
        return Err(not_permitted("change roles"));
    }
    if target == me {
        return Err(ApiError::bad_request(
            "cannot_change_own_role",
            "Transfer ownership instead.",
        ));
    }
    their_membership(&mut tx, target, crew_id).await?;
    let r = role.as_str();
    sqlx::query!(
        "UPDATE crew_members SET role = ? WHERE account_id = ?",
        r,
        target
    )
    .execute(&mut *tx)
    .await?;
    let v = view_or_404(&mut tx, state, crew_id, me).await?;
    tx.commit().await?;
    Ok(v)
}

/// Owner only: hands the crew to another member; the old owner becomes an officer.
pub async fn transfer(state: &AppState, me: i64, crew_id: i64, target: i64) -> ApiResult<CrewView> {
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let mine = my_membership(&mut tx, me, crew_id).await?;
    if mine.role != Role::Owner {
        return Err(not_permitted("transfer the crew"));
    }
    if target == me {
        return Err(ApiError::bad_request(
            "cannot_transfer_to_self",
            "You already own the crew.",
        ));
    }
    their_membership(&mut tx, target, crew_id).await?;
    sqlx::query!(
        "UPDATE crew_members SET role = 'officer' WHERE account_id = ?",
        me
    )
    .execute(&mut *tx)
    .await?;
    set_owner(&mut tx, crew_id, target).await?;
    let v = view_or_404(&mut tx, state, crew_id, me).await?;
    tx.commit().await?;
    Ok(v)
}

/// Owner or officer: a new invite code (the old one stops working).
pub async fn rotate_code(state: &AppState, me: i64, crew_id: i64) -> ApiResult<CrewView> {
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let mine = my_membership(&mut tx, me, crew_id).await?;
    if mine.role == Role::Member {
        return Err(not_permitted("change the invite code"));
    }
    let mut done = false;
    for _ in 0..CODE_ATTEMPTS {
        let code = new_invite_code(state.config.social.crew_invite_code_len);
        match sqlx::query!(
            "UPDATE crews SET invite_code = ? WHERE id = ?",
            code,
            crew_id
        )
        .execute(&mut *tx)
        .await
        {
            Ok(_) => {
                done = true;
                break;
            }
            Err(e) if is_unique_violation(&e) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    if !done {
        return Err(ApiError::internal("no free crew invite code"));
    }
    let v = view_or_404(&mut tx, state, crew_id, me).await?;
    tx.commit().await?;
    Ok(v)
}

/// Owner only: deletes the crew for everyone.
pub async fn disband(state: &AppState, me: i64, crew_id: i64) -> ApiResult<()> {
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let mine = my_membership(&mut tx, me, crew_id).await?;
    if mine.role != Role::Owner {
        return Err(not_permitted("disband the crew"));
    }
    disband_rows(&mut tx, crew_id).await?;
    tx.commit().await?;
    state.boards.invalidate_all();
    tracing::info!(account_id = me, crew_id, "crew disbanded");
    Ok(())
}

/// Admin: renames a crew and/or changes its tag (rules, filter and uniqueness apply).
/// Returns the new (name, tag).
pub async fn admin_rename(
    pool: &sqlx::SqlitePool,
    crew_id: i64,
    name: Option<&str>,
    tag: Option<&str>,
) -> Result<(String, String), ApiError> {
    let name = name.map(validate_name).transpose()?;
    let tag = tag.map(validate_tag).transpose()?;
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let cur = sqlx::query!("SELECT name, tag FROM crews WHERE id = ?", crew_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(crew_not_found)?;
    check_unique(&mut tx, name.as_deref(), tag.as_deref(), crew_id).await?;
    let name = name.unwrap_or(cur.name);
    let tag = tag.unwrap_or(cur.tag);
    sqlx::query!(
        "UPDATE crews SET name = ?, tag = ? WHERE id = ?",
        name,
        tag,
        crew_id
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok((name, tag))
}

// ------------------------------------------------------------------------------------------
// Crew invites (the owner's request: "there is no way to invite my friends to my crew")
// ------------------------------------------------------------------------------------------

/// A crew invite as the invitee sees it (`GET /api/v1/crews/invites`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CrewInviteView {
    pub invite_id: String,
    pub crew_id: String,
    pub crew_name: String,
    pub crew_tag: String,
    pub member_count: u32,
    pub max_members: u32,
    /// The member who sent it (`null` once their account is gone; such invites are
    /// deleted with the account, so only a race shows it).
    pub from: Option<super::Player>,
    pub created_at: i64,
    pub expires_at: i64,
}

/// A crew's waiting invite as its members see it (`GET /api/v1/crews/{id}/invites`,
/// `POST /api/v1/crews/{id}/invites`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SentInviteView {
    pub invite_id: String,
    /// The invitee.
    pub player: super::Player,
    pub from: Option<super::Player>,
    pub created_at: i64,
    pub expires_at: i64,
}

fn invite_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "invite_not_found",
        "That crew invite is no longer valid.",
    )
}

/// The crew invite's lifetime in seconds.
fn invite_ttl_secs(state: &AppState) -> i64 {
    i64::from(state.config.social.crew_invite_ttl_hours) * 3_600
}

/// Invites `target` (an accepted friend of `me`) to `crew_id`. Any member may invite: every
/// member already sees and shares the invite code (SERVER.md → Crews), so an invite gives
/// no new power. A second invite renews the first (`200`); a new one answers `201`.
/// Refusals: `cannot_invite_self`; `not_in_crew`; `player_not_found`; `not_friends` (no
/// accepted friendship, or a block either way: blocking ends the friendship, and the answer
/// does not reveal which); `already_member`; `crew_full`; `crew_invites_limit` (the crew's
/// `social.crew_max_pending_invites`). The invitee, when online on a protocol 2 client, gets
/// `lobby_event.crew_invite` at once.
pub async fn invite(
    state: &AppState,
    me: i64,
    crew_id: i64,
    target: i64,
) -> ApiResult<(StatusCode, SentInviteView)> {
    if target == me {
        return Err(ApiError::bad_request(
            "cannot_invite_self",
            "You are already in your crew.",
        ));
    }
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    my_membership(&mut tx, me, crew_id).await?;
    let Some(player) = super::player(&mut tx, target).await? else {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "player_not_found",
            "No such player.",
        ));
    };
    let friends = super::friend_ids(&mut tx, me).await?.unwrap_or_default();
    if !friends.contains(&target) || super::is_blocked(&mut tx, me, target).await? {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "not_friends",
            "You can only invite friends to your crew.",
        ));
    }
    if membership(&mut tx, target)
        .await?
        .is_some_and(|m| m.crew_id == crew_id)
    {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "already_member",
            "That player is already in your crew.",
        ));
    }
    if member_count(&mut tx, crew_id).await? >= i64::from(state.config.social.crew_max_members) {
        return Err(crew_full());
    }
    let existing = sqlx::query_scalar!(
        r#"SELECT id AS "id!: i64" FROM crew_invites WHERE crew_id = ? AND account_id = ?"#,
        crew_id,
        target
    )
    .fetch_optional(&mut *tx)
    .await?;
    let pending = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM crew_invites
           WHERE crew_id = ? AND expires_at > ? AND account_id != ?"#,
        crew_id,
        now,
        target
    )
    .fetch_one(&mut *tx)
    .await?;
    if pending >= i64::from(state.config.social.crew_max_pending_invites) {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "crew_invites_limit",
            "Your crew has too many invites waiting. Try again when some are answered.",
        ));
    }
    let expires = now + invite_ttl_secs(state);
    let invite_id = sqlx::query_scalar!(
        r#"INSERT INTO crew_invites (crew_id, account_id, inviter_id, created_at, expires_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (crew_id, account_id) DO UPDATE
             SET inviter_id = excluded.inviter_id, created_at = excluded.created_at,
                 expires_at = excluded.expires_at
           RETURNING id AS "id!: i64""#,
        crew_id,
        target,
        me,
        now,
        expires
    )
    .fetch_one(&mut *tx)
    .await?;
    let from = super::player(&mut tx, me).await?;
    let crew = sqlx::query!("SELECT name, tag FROM crews WHERE id = ?", crew_id)
        .fetch_one(&mut *tx)
        .await?;
    let (ident, _) = crate::rooms::identity_of(&mut tx, protocol::AccountId(me as u64)).await?;
    tx.commit().await?;
    crate::metrics::Metrics::inc(&state.metrics.crew_invites);
    tracing::info!(
        account_id = me,
        crew_id,
        target,
        invite_id,
        renewed = existing.is_some(),
        "crew invite"
    );
    notify_invite(state, target, invite_id, &crew.name, &crew.tag, ident);
    let status = if existing.is_some() {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    Ok((
        status,
        SentInviteView {
            invite_id: invite_id.to_string(),
            player,
            from,
            created_at: now,
            expires_at: expires,
        },
    ))
}

/// `lobby_event.crew_invite` to the invitee's live session (protocol 2 clients only).
fn notify_invite(
    state: &AppState,
    target: i64,
    invite_id: i64,
    crew_name: &str,
    crew_tag: &str,
    from: protocol::Identity,
) {
    let Some(session) = state.sessions.get(protocol::AccountId(target as u64)) else {
        return;
    };
    if !session.takes_invites() {
        return;
    }
    let msg =
        protocol::ServerMsg::LobbyEvent(protocol::LobbyEvent::CrewInvite(protocol::CrewInvite {
            invite_id: protocol::AccountId(invite_id as u64),
            crew_tag: protocol::CrewTag::new(crew_tag).unwrap_or_default(),
            crew_name: protocol::Text(crew_name.to_owned()),
            from,
            expires_in_s: u32::try_from(invite_ttl_secs(state)).unwrap_or(u32::MAX),
        }));
    match protocol::encode_frame(std::slice::from_ref(&msg)) {
        Ok(frame) => {
            session.send_frame(frame);
        }
        Err(e) => tracing::error!(error = %e, "crew invite failed to encode"),
    }
}

/// The invites waiting for `me`, newest first: unexpired, and none from a player blocked
/// either way.
pub async fn invites_for(state: &AppState, me: i64) -> ApiResult<Vec<CrewInviteView>> {
    let now = state.clock.now();
    let mut conn = state.db.acquire().await?;
    let rows = sqlx::query!(
        r#"SELECT i.id AS "id!: i64", i.crew_id, i.inviter_id, i.created_at, i.expires_at,
                  c.name, c.tag,
                  (SELECT COUNT(*) FROM crew_members m WHERE m.crew_id = i.crew_id) AS "members!: i64"
           FROM crew_invites i JOIN crews c ON c.id = i.crew_id
           WHERE i.account_id = ?1 AND i.expires_at > ?2
             AND NOT EXISTS (SELECT 1 FROM blocks b
                             WHERE (b.account_id = ?1 AND b.blocked_id = i.inviter_id)
                                OR (b.account_id = i.inviter_id AND b.blocked_id = ?1))
           ORDER BY i.created_at DESC, i.id DESC"#,
        me,
        now
    )
    .fetch_all(&mut *conn)
    .await?;
    let inviters: Vec<i64> = rows.iter().filter_map(|r| r.inviter_id).collect();
    let players = super::players(&mut conn, &inviters).await?;
    let max_members = state.config.social.crew_max_members;
    Ok(rows
        .into_iter()
        .map(|r| CrewInviteView {
            invite_id: r.id.to_string(),
            crew_id: r.crew_id.to_string(),
            crew_name: r.name,
            crew_tag: r.tag,
            member_count: u32::try_from(r.members).unwrap_or(0),
            max_members,
            from: r.inviter_id.and_then(|id| players.get(&id).cloned()),
            created_at: r.created_at,
            expires_at: r.expires_at,
        })
        .collect())
}

/// The crew's waiting (unexpired) invites, for its members, newest first.
pub async fn sent_invites(
    state: &AppState,
    me: i64,
    crew_id: i64,
) -> ApiResult<Vec<SentInviteView>> {
    let now = state.clock.now();
    let mut conn = state.db.acquire().await?;
    my_membership(&mut conn, me, crew_id).await?;
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: i64", account_id, inviter_id, created_at, expires_at
           FROM crew_invites WHERE crew_id = ? AND expires_at > ?
           ORDER BY created_at DESC, id DESC"#,
        crew_id,
        now
    )
    .fetch_all(&mut *conn)
    .await?;
    let mut ids: Vec<i64> = rows.iter().map(|r| r.account_id).collect();
    ids.extend(rows.iter().filter_map(|r| r.inviter_id));
    let players = super::players(&mut conn, &ids).await?;
    Ok(rows
        .into_iter()
        .filter_map(|r| {
            Some(SentInviteView {
                invite_id: r.id.to_string(),
                player: players.get(&r.account_id)?.clone(),
                from: r.inviter_id.and_then(|id| players.get(&id).cloned()),
                created_at: r.created_at,
                expires_at: r.expires_at,
            })
        })
        .collect())
}

/// The invite `invite_id` addressed to `me`, unexpired and not from a player blocked either
/// way: (crew id, inviter).
async fn my_invite(
    conn: &mut SqliteConnection,
    me: i64,
    invite_id: i64,
    now: i64,
) -> ApiResult<(i64, Option<i64>)> {
    let r = sqlx::query!(
        r#"SELECT crew_id, inviter_id FROM crew_invites
           WHERE id = ? AND account_id = ? AND expires_at > ?"#,
        invite_id,
        me,
        now
    )
    .fetch_optional(&mut *conn)
    .await?
    .ok_or_else(invite_not_found)?;
    if let Some(from) = r.inviter_id {
        if super::is_blocked(conn, me, from).await? {
            return Err(invite_not_found());
        }
    }
    Ok((r.crew_id, r.inviter_id))
}

/// Accepts an invite: joins the crew with the join-by-code checks (`already_in_crew`: leave
/// your crew first; `crew_full`). Accepting an invite to the crew you are already in just
/// clears it.
pub async fn accept_invite(state: &AppState, me: i64, invite_id: i64) -> ApiResult<CrewView> {
    let now = state.clock.now();
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let (crew_id, _) = my_invite(&mut tx, me, invite_id, now).await?;
    if membership(&mut tx, me)
        .await?
        .is_some_and(|m| m.crew_id == crew_id)
    {
        sqlx::query!("DELETE FROM crew_invites WHERE id = ?", invite_id)
            .execute(&mut *tx)
            .await?;
        let v = view_or_404(&mut tx, state, crew_id, me).await?;
        tx.commit().await?;
        return Ok(v);
    }
    let v = join_tx(&mut tx, state, me, crew_id, now).await?;
    tx.commit().await?;
    invalidate_season(state);
    tracing::info!(account_id = me, crew_id, invite_id, "crew invite accepted");
    Ok(v)
}

/// Declines (deletes) an invite addressed to `me`.
pub async fn decline_invite(state: &AppState, me: i64, invite_id: i64) -> ApiResult<()> {
    let done = sqlx::query!(
        "DELETE FROM crew_invites WHERE id = ? AND account_id = ?",
        invite_id,
        me
    )
    .execute(&state.db)
    .await?;
    if done.rows_affected() == 0 {
        return Err(invite_not_found());
    }
    Ok(())
}

// ------------------------------------------------------------------------------------------
// Routes
// ------------------------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateBody {
    pub name: String,
    pub tag: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JoinBody {
    pub invite_code: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemberBody {
    pub account_id: String,
}

/// `POST /api/v1/crews/{id}/leave` answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaveResult {
    /// The crew was disbanded (you were its last member).
    pub disbanded: bool,
    /// You owned the crew and it passed to this member.
    pub new_owner_id: Option<String>,
}

fn crew_path(id: &str) -> ApiResult<i64> {
    path_id(id, "crew_not_found", "No such crew.")
}

/// `POST /api/v1/crews` `{"name", "tag"}`: 201.
pub async fn post_crew(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(body): ApiJson<CreateBody>,
) -> ApiResult<(StatusCode, Json<CrewView>)> {
    let v = create(&state, auth.account_id, &body.name, &body.tag).await?;
    Ok((StatusCode::CREATED, Json(v)))
}

/// `GET /api/v1/crews/mine`.
pub async fn get_mine(State(state): State<AppState>, auth: Authed) -> ApiResult<Json<CrewView>> {
    let mut conn = state.db.acquire().await?;
    let m = membership(&mut conn, auth.account_id)
        .await?
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::NOT_FOUND,
                "not_in_crew",
                "You are not in a crew.",
            )
        })?;
    Ok(Json(
        view_or_404(&mut conn, &state, m.crew_id, auth.account_id).await?,
    ))
}

/// `GET /api/v1/crews/{id}`.
pub async fn get_crew(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<CrewView>> {
    let id = crew_path(&id)?;
    let mut conn = state.db.acquire().await?;
    Ok(Json(
        view_or_404(&mut conn, &state, id, auth.account_id).await?,
    ))
}

/// `DELETE /api/v1/crews/{id}`: disband (owner). 204.
pub async fn delete_crew(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    disband(&state, auth.account_id, crew_path(&id)?).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /api/v1/crews/join` `{"invite_code"}`.
pub async fn post_join(
    State(state): State<AppState>,
    auth: Authed,
    ApiJson(body): ApiJson<JoinBody>,
) -> ApiResult<Json<CrewView>> {
    Ok(Json(
        join(&state, auth.account_id, &body.invite_code).await?,
    ))
}

/// `POST /api/v1/crews/{id}/leave`.
pub async fn post_leave(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<LeaveResult>> {
    let out = leave(&state, auth.account_id, crew_path(&id)?).await?;
    Ok(Json(LeaveResult {
        disbanded: out.disbanded,
        new_owner_id: out.new_owner.map(|id| id.to_string()),
    }))
}

/// `POST /api/v1/crews/{id}/kick` `{"account_id"}`.
pub async fn post_kick(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<MemberBody>,
) -> ApiResult<Json<CrewView>> {
    let target = body_account_id(&body.account_id)?;
    Ok(Json(
        kick(&state, auth.account_id, crew_path(&id)?, target).await?,
    ))
}

/// `POST /api/v1/crews/{id}/promote` `{"account_id"}`: member → officer.
pub async fn post_promote(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<MemberBody>,
) -> ApiResult<Json<CrewView>> {
    let target = body_account_id(&body.account_id)?;
    Ok(Json(
        set_role(
            &state,
            auth.account_id,
            crew_path(&id)?,
            target,
            Role::Officer,
        )
        .await?,
    ))
}

/// `POST /api/v1/crews/{id}/demote` `{"account_id"}`: officer → member.
pub async fn post_demote(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<MemberBody>,
) -> ApiResult<Json<CrewView>> {
    let target = body_account_id(&body.account_id)?;
    Ok(Json(
        set_role(
            &state,
            auth.account_id,
            crew_path(&id)?,
            target,
            Role::Member,
        )
        .await?,
    ))
}

/// `POST /api/v1/crews/{id}/transfer` `{"account_id"}`.
pub async fn post_transfer(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<MemberBody>,
) -> ApiResult<Json<CrewView>> {
    let target = body_account_id(&body.account_id)?;
    Ok(Json(
        transfer(&state, auth.account_id, crew_path(&id)?, target).await?,
    ))
}

/// `POST /api/v1/crews/{id}/invite-code`: rotate (owner, officers).
pub async fn post_invite_code(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<CrewView>> {
    Ok(Json(
        rotate_code(&state, auth.account_id, crew_path(&id)?).await?,
    ))
}

/// `GET /api/v1/crews/invites` answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InviteList {
    pub invites: Vec<CrewInviteView>,
}

/// `GET /api/v1/crews/{id}/invites` answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SentInviteList {
    pub invites: Vec<SentInviteView>,
}

fn invite_path(id: &str) -> ApiResult<i64> {
    path_id(
        id,
        "invite_not_found",
        "That crew invite is no longer valid.",
    )
}

/// `GET /api/v1/crews/invites`: the invites waiting for you.
pub async fn get_invites(
    State(state): State<AppState>,
    auth: Authed,
) -> ApiResult<Json<InviteList>> {
    Ok(Json(InviteList {
        invites: invites_for(&state, auth.account_id).await?,
    }))
}

/// `POST /api/v1/crews/{id}/invites` `{"account_id"}`: invite a friend (201; 200 renewed).
pub async fn post_crew_invite(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<MemberBody>,
) -> ApiResult<(StatusCode, Json<SentInviteView>)> {
    let target = body_account_id(&body.account_id)?;
    let (status, v) = invite(&state, auth.account_id, crew_path(&id)?, target).await?;
    Ok((status, Json(v)))
}

/// `GET /api/v1/crews/{id}/invites`: the crew's waiting invites (members).
pub async fn get_crew_invites(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<SentInviteList>> {
    Ok(Json(SentInviteList {
        invites: sent_invites(&state, auth.account_id, crew_path(&id)?).await?,
    }))
}

/// `POST /api/v1/crews/invites/{invite_id}/accept`: join the crew.
pub async fn post_accept_invite(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<Json<CrewView>> {
    Ok(Json(
        accept_invite(&state, auth.account_id, invite_path(&id)?).await?,
    ))
}

/// `POST /api/v1/crews/invites/{invite_id}/decline`: 204.
pub async fn post_decline_invite(
    State(state): State<AppState>,
    auth: Authed,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    decline_invite(&state, auth.account_id, invite_path(&id)?).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_and_names() {
        assert_eq!(validate_tag(" nr ").unwrap(), "NR");
        assert_eq!(validate_tag("W3st").unwrap(), "W3ST");
        for bad in ["", "A", "ABCDE", "A B", "Ş1", "A-B", "ÇÇ"] {
            assert_eq!(
                validate_tag(bad).unwrap_err().code,
                "invalid_crew_tag",
                "{bad}"
            );
        }
        assert_eq!(
            validate_tag("a55").unwrap_err().code,
            "crew_tag_not_allowed"
        );
        assert_eq!(validate_name("  Night Riders ").unwrap(), "Night Riders");
        assert_eq!(
            validate_name("Coastal Night Riders Crew").unwrap_err().code,
            "invalid_crew_name"
        );
        assert_eq!(validate_name("Ab").unwrap_err().code, "invalid_crew_name");
        assert_eq!(
            validate_name("Sh1t Drivers").unwrap_err().code,
            "crew_name_not_allowed"
        );
        let code = new_invite_code(8);
        assert_eq!(code.len(), 8);
        assert!(code
            .chars()
            .all(|c| protocol::types::CODE_ALPHABET.contains(c)));
    }
}
