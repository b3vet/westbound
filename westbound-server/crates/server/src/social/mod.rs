//! The social layer (N9.1): friends and friend requests, blocks, persistent crews, reports,
//! and the queries the leaderboards, the gateway and (later) matchmaking read.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Rooms, parties and matchmaking" (friends and
//! presence, crews, moderation), "Leaderboards" (friends view, Loop crew), "Data model
//! (SQLite)" (`friends`, `blocks`, `crews`, `crew_members`, `reports`), "Accounts →
//! Account deletion". API: docs/SERVER.md → "Social API".
//!
//! - `friends`: requests, the friends list, removal, blocks, presence reads (routes too).
//! - `crews`: crews, roles, invite codes, the Loop crew sums (routes too).
//! - `reports`: player reports with the per-account daily limit.
//! - `parties` (N9.3): in-memory parties (create, join, invite, leave, kick, the leader
//!   moving the party between rooms, member holds on disconnect).
//!
//! This module holds the shared reads: [`friend_ids`] (the friends board view and presence),
//! [`crew_of`] / [`crew_snapshot`] (the Loop crew board, N6's multiplayer runs),
//! [`is_blocked`] (friend requests; N9's Quick Join and party invites), player summaries,
//! and the account-deletion hook [`on_account_delete`].

pub mod crews;
pub mod friends;
pub mod parties;
pub mod reports;

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use sqlx::SqliteConnection;

use crate::config::LeaderboardsConfig;
use crate::leaderboards::CrewSnapshot;
use crate::names;

/// The account's accepted friends (never `None` since N9.1; the `Option` is the
/// leaderboards' "friends available" seam).
pub async fn friend_ids(
    conn: &mut SqliteConnection,
    account_id: i64,
) -> sqlx::Result<Option<Vec<i64>>> {
    let ids = sqlx::query_scalar!(
        r#"SELECT account_b AS "id!: i64" FROM friends WHERE account_a = ?1 AND status = 'accepted'
           UNION ALL
           SELECT account_a AS "id!: i64" FROM friends WHERE account_b = ?1 AND status = 'accepted'"#,
        account_id
    )
    .fetch_all(conn)
    .await?;
    Ok(Some(ids))
}

/// The account's crew, if any: the subject of its entries on the Loop crew board ("me"
/// and "around me" there).
pub async fn crew_of(conn: &mut SqliteConnection, account_id: i64) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar!(
        "SELECT crew_id FROM crew_members WHERE account_id = ?",
        account_id
    )
    .fetch_optional(conn)
    .await
}

/// **For N6:** the account's crew as `record_multiplayer_run` takes it (the crew and all of
/// its members), or `None` without a crew.
pub async fn crew_snapshot(
    conn: &mut SqliteConnection,
    account_id: i64,
) -> sqlx::Result<Option<CrewSnapshot>> {
    let Some(crew_id) = crew_of(&mut *conn, account_id).await? else {
        return Ok(None);
    };
    let member_ids = crews::member_ids(conn, crew_id).await?;
    Ok(Some(CrewSnapshot {
        crew_id,
        member_ids,
    }))
}

/// Whether either account blocked the other. Friend requests use it; **N9 rooms:** Quick
/// Join never matches a blocked player into your room, and a player you blocked (or who
/// blocked you) cannot invite you to a party.
pub async fn is_blocked(conn: &mut SqliteConnection, a: i64, b: i64) -> sqlx::Result<bool> {
    let n = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM blocks
           WHERE (account_id = ?1 AND blocked_id = ?2) OR (account_id = ?2 AND blocked_id = ?1)"#,
        a,
        b
    )
    .fetch_one(conn)
    .await?;
    Ok(n > 0)
}

/// Whether `blocker` blocked `target` (one direction).
pub async fn has_blocked(
    conn: &mut SqliteConnection,
    blocker: i64,
    target: i64,
) -> sqlx::Result<bool> {
    let n = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "n!: i64" FROM blocks WHERE account_id = ? AND blocked_id = ?"#,
        blocker,
        target
    )
    .fetch_one(conn)
    .await?;
    Ok(n > 0)
}

/// **N9.3:** every account that blocked, or was blocked by, any of `ids` (one query). Quick
/// Join keeps them out of the rooms it picks for `ids` (a player or a whole party), and a
/// party refuses a joiner blocked either way with one of its members.
pub async fn blocked_either(conn: &mut SqliteConnection, ids: &[i64]) -> sqlx::Result<Vec<i64>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let json = serde_json::to_string(ids).unwrap_or_else(|_| "[]".into());
    sqlx::query_scalar!(
        r#"SELECT blocked_id AS "id!: i64" FROM blocks
             WHERE account_id IN (SELECT value FROM json_each(?1))
           UNION
           SELECT account_id AS "id!: i64" FROM blocks
             WHERE blocked_id IN (SELECT value FROM json_each(?1))"#,
        json
    )
    .fetch_all(conn)
    .await
}

/// A player as the social API shows them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Player {
    /// Decimal string.
    pub account_id: String,
    pub display_name: String,
    /// The `#1234` suffix.
    pub tag: u16,
    /// `display_name#0042`.
    pub full_name: String,
    /// The player's crew tag, if they are in a crew.
    pub crew_tag: Option<String>,
}

/// The given accounts as [`Player`]s (missing accounts are left out), one query.
pub async fn players(
    conn: &mut SqliteConnection,
    ids: &[i64],
) -> sqlx::Result<HashMap<i64, Player>> {
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let json = serde_json::to_string(ids).unwrap_or_else(|_| "[]".into());
    let rows = sqlx::query!(
        r#"SELECT a.id AS "id!: i64", a.display_name, a.tag, c.tag AS "crew_tag?: String"
           FROM accounts a
           LEFT JOIN crew_members m ON m.account_id = a.id
           LEFT JOIN crews c ON c.id = m.crew_id
           WHERE a.id IN (SELECT value FROM json_each(?))"#,
        json
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| {
            let tag = u16::try_from(r.tag).unwrap_or(0);
            (
                r.id,
                Player {
                    account_id: r.id.to_string(),
                    full_name: names::full_name(&r.display_name, tag),
                    display_name: r.display_name,
                    tag,
                    crew_tag: r.crew_tag,
                },
            )
        })
        .collect())
}

/// One player, if the account exists.
pub async fn player(conn: &mut SqliteConnection, id: i64) -> sqlx::Result<Option<Player>> {
    Ok(players(conn, &[id]).await?.remove(&id))
}

/// `name#1234` → (`name`, 1234). The name is trimmed; the tag is 1–4 digits.
pub fn parse_full_name(s: &str) -> Option<(String, u16)> {
    let (name, tag) = s.trim().rsplit_once('#')?;
    let name = name.trim();
    if name.is_empty()
        || name.chars().count() > names::MAX_NAME_CHARS
        || tag.is_empty()
        || tag.len() > 4
        || !tag.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let tag: u16 = tag.parse().ok()?;
    (tag <= names::MAX_TAG).then(|| (name.to_string(), tag))
}

/// The account with this `name#tag` (the name compares case-insensitively for ASCII
/// letters, like the unique index).
pub async fn find_by_full_name(
    conn: &mut SqliteConnection,
    name: &str,
    tag: u16,
) -> sqlx::Result<Option<i64>> {
    let tag = i64::from(tag);
    sqlx::query_scalar!(
        r#"SELECT id AS "id!: i64" FROM accounts WHERE display_name = ? AND tag = ?"#,
        name,
        tag
    )
    .fetch_optional(conn)
    .await
}

/// Crew tags of the given accounts that are in a crew (board entries).
pub async fn crew_tags_of(
    conn: &mut SqliteConnection,
    account_ids: &[i64],
) -> sqlx::Result<HashMap<i64, String>> {
    if account_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let json = serde_json::to_string(account_ids).unwrap_or_else(|_| "[]".into());
    let rows = sqlx::query!(
        r#"SELECT m.account_id AS "account_id!: i64", c.tag
           FROM crew_members m JOIN crews c ON c.id = m.crew_id
           WHERE m.account_id IN (SELECT value FROM json_each(?))"#,
        json
    )
    .fetch_all(conn)
    .await?;
    Ok(rows.into_iter().map(|r| (r.account_id, r.tag)).collect())
}

/// Name and tag of the given crews that exist (Loop crew board entries).
pub async fn crew_names(
    conn: &mut SqliteConnection,
    crew_ids: &[i64],
) -> sqlx::Result<HashMap<i64, (String, String)>> {
    if crew_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let json = serde_json::to_string(crew_ids).unwrap_or_else(|_| "[]".into());
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: i64", name, tag FROM crews
           WHERE id IN (SELECT value FROM json_each(?))"#,
        json
    )
    .fetch_all(conn)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, (r.name, r.tag))).collect())
}

/// What an account deletion removed from the social tables.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SocialDeleteReport {
    /// Friendships and requests, either side.
    pub friends: u64,
    /// Blocks, both ways.
    pub blocks: u64,
    /// The crew membership (0 or 1).
    pub crew_memberships: u64,
    /// The account owned its crew and it passed to another member.
    pub crew_transferred: bool,
    /// The account was its crew's last member, so the crew was disbanded.
    pub crew_disbanded: bool,
    /// Reports filed by or about the account: kept, with that side nulled.
    pub reports_kept: u64,
}

/// The social part of an account deletion, inside its transaction (`accounts::delete`),
/// after the account's leaderboard entries are gone:
/// - friendships and requests, and blocks both ways, are deleted;
/// - the crew membership goes. A crew the account owned passes to its longest-standing
///   officer, else its longest-standing member, and is disbanded when nobody is left; the
///   crew's Loop crew score for the current season is recomputed without the account;
/// - reports are **kept** for the moderation record: the deleted side (reporter or target)
///   is set to NULL, so nothing points at the deleted account, while the reason, the context
///   and the time stay for moderators (`admin reports` shows the side as `deleted`).
pub async fn on_account_delete(
    conn: &mut SqliteConnection,
    account_id: i64,
    boards: &LeaderboardsConfig,
    now: i64,
) -> sqlx::Result<SocialDeleteReport> {
    let mut report = SocialDeleteReport {
        friends: sqlx::query!(
            "DELETE FROM friends WHERE account_a = ?1 OR account_b = ?1",
            account_id
        )
        .execute(&mut *conn)
        .await?
        .rows_affected(),
        blocks: sqlx::query!(
            "DELETE FROM blocks WHERE account_id = ?1 OR blocked_id = ?1",
            account_id
        )
        .execute(&mut *conn)
        .await?
        .rows_affected(),
        ..Default::default()
    };
    if let Some(m) = crews::membership(&mut *conn, account_id).await? {
        let out = crews::remove_member(&mut *conn, &m, boards, now).await?;
        report.crew_memberships = 1;
        report.crew_transferred = out.new_owner.is_some();
        report.crew_disbanded = out.disbanded;
    }
    let reporter = sqlx::query!(
        "UPDATE reports SET reporter_id = NULL WHERE reporter_id = ?",
        account_id
    )
    .execute(&mut *conn)
    .await?
    .rows_affected();
    let target = sqlx::query!(
        "UPDATE reports SET target_id = NULL WHERE target_id = ?",
        account_id
    )
    .execute(&mut *conn)
    .await?
    .rows_affected();
    report.reports_kept = reporter + target;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::parse_full_name;

    #[test]
    fn full_names() {
        assert_eq!(
            parse_full_name("Şahin 34#0042"),
            Some(("Şahin 34".into(), 42))
        );
        assert_eq!(parse_full_name(" a#b#9999 "), Some(("a#b".into(), 9999)));
        assert_eq!(
            parse_full_name("Road Runner#7"),
            Some(("Road Runner".into(), 7))
        );
        for bad in [
            "",
            "#0042",
            "name",
            "name#",
            "name#12345",
            "name#-1",
            "name#12a",
            "name#+123",
            "abcdefghijklmnopq#0001",
        ] {
            assert_eq!(parse_full_name(bad), None, "{bad}");
        }
    }
}
