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
    view(
        conn,
        crew_id,
        Some(viewer),
        state.config.social.crew_max_members,
    )
    .await?
    .ok_or_else(crew_not_found)
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
    if membership(&mut tx, me).await?.is_some() {
        return Err(already_in_crew());
    }
    if member_count(&mut tx, crew_id).await? >= i64::from(state.config.social.crew_max_members) {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "crew_full",
            "That crew is full.",
        ));
    }
    sqlx::query!(
        "INSERT INTO crew_members (account_id, crew_id, role, joined_at)
         VALUES (?, ?, 'member', ?)",
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
    Ok(v)
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
