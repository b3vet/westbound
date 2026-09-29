//! Account rows: creation with a unique `name#tag`, profile reads, renames, bans and
//! deletion. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and authentication"
//! (display names, account deletion), "Data model (SQLite)", "Moderation" (bans).

use serde::{Deserialize, Serialize};
use sqlx::{SqliteConnection, SqlitePool};

use crate::names::{self, TAG_COUNT};

/// Random tags tried before falling back to scanning the free ones.
const RANDOM_TAG_ATTEMPTS: usize = 8;
/// `banned_until` for a permanent ban: 9999-12-31T23:59:59Z.
pub const PERMANENT_BAN_UNTIL: i64 = 253_402_300_799;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    pub id: i64,
    pub display_name: String,
    pub tag: u16,
    pub created_at: i64,
    pub last_seen: i64,
    pub banned_until: Option<i64>,
    pub name_changed_at: Option<i64>,
    pub token_version: i64,
    pub apple_linked: bool,
    pub google_linked: bool,
}

/// `GET /api/v1/me`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    /// Decimal string (docs/PROTOCOL.md).
    pub account_id: String,
    pub display_name: String,
    /// The `#1234` suffix, 0–9999.
    pub name_tag: u16,
    /// `display_name#0042`.
    pub full_name: String,
    pub created_at: i64,
    pub name_changed_at: Option<i64>,
    /// When the next rename is allowed; `null` = now.
    pub next_rename_at: Option<i64>,
    pub linked: Linked,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Linked {
    pub apple: bool,
    pub google: bool,
}

impl Account {
    /// When this account may rename next, if not now.
    pub fn next_rename_at(&self, now: i64, cooldown: i64) -> Option<i64> {
        self.name_changed_at
            .map(|t| t.saturating_add(cooldown))
            .filter(|&t| t > now)
    }

    pub fn profile(&self, now: i64, cooldown: i64) -> Profile {
        Profile {
            account_id: self.id.to_string(),
            display_name: self.display_name.clone(),
            name_tag: self.tag,
            full_name: names::full_name(&self.display_name, self.tag),
            created_at: self.created_at,
            name_changed_at: self.name_changed_at,
            next_rename_at: self.next_rename_at(now, cooldown),
            linked: Linked {
                apple: self.apple_linked,
                google: self.google_linked,
            },
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum NameTakenError {
    /// Every tag 0000–9999 is taken for this name.
    #[error("every tag for this name is taken")]
    Full,
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),
}

fn tag_of(v: i64) -> u16 {
    u16::try_from(v).unwrap_or(0)
}

pub async fn get(db: impl sqlx::SqliteExecutor<'_>, id: i64) -> sqlx::Result<Option<Account>> {
    let row = sqlx::query!(
        r#"SELECT id AS "id!", display_name, tag, created_at, last_seen, banned_until,
                  name_changed_at, token_version,
                  apple_sub IS NOT NULL AS "apple_linked!: bool",
                  google_sub IS NOT NULL AS "google_linked!: bool"
           FROM accounts WHERE id = ?"#,
        id
    )
    .fetch_optional(db)
    .await?;
    Ok(row.map(|r| Account {
        id: r.id,
        display_name: r.display_name,
        tag: tag_of(r.tag),
        created_at: r.created_at,
        last_seen: r.last_seen,
        banned_until: r.banned_until,
        name_changed_at: r.name_changed_at,
        token_version: r.token_version,
        apple_linked: r.apple_linked,
        google_linked: r.google_linked,
    }))
}

fn is_unique_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(d) if d.is_unique_violation())
}

/// Tags already used with `name` (case-insensitive, like the unique index).
async fn used_tags(conn: &mut SqliteConnection, name: &str) -> sqlx::Result<Vec<i64>> {
    sqlx::query_scalar!("SELECT tag FROM accounts WHERE display_name = ?", name)
        .fetch_all(conn)
        .await
}

/// A random tag that is free for `name`, from the full scan (after random tries).
async fn free_tag(conn: &mut SqliteConnection, name: &str) -> Result<u16, NameTakenError> {
    let mut used = vec![false; TAG_COUNT as usize];
    for t in used_tags(conn, name).await? {
        if let Some(slot) = usize::try_from(t).ok().and_then(|i| used.get_mut(i)) {
            *slot = true;
        }
    }
    let free: Vec<u16> = (0..TAG_COUNT as u16)
        .filter(|&t| !used[t as usize])
        .collect();
    if free.is_empty() {
        return Err(NameTakenError::Full);
    }
    Ok(free[crate::auth::random_below(free.len() as u32) as usize])
}

/// Inserts a device account with `name` and a free random tag. Returns its id and tag.
pub async fn insert_device_account(
    conn: &mut SqliteConnection,
    name: &str,
    device_secret_hash: &[u8],
    now: i64,
) -> Result<(i64, u16), NameTakenError> {
    for attempt in 0..=RANDOM_TAG_ATTEMPTS {
        let tag = if attempt < RANDOM_TAG_ATTEMPTS {
            crate::auth::random_below(TAG_COUNT) as u16
        } else {
            free_tag(conn, name).await?
        };
        let tag_i = tag as i64;
        let r = sqlx::query!(
            "INSERT INTO accounts (display_name, tag, device_secret_hash, created_at, last_seen)
             VALUES (?, ?, ?, ?, ?)",
            name,
            tag_i,
            device_secret_hash,
            now,
            now
        )
        .execute(&mut *conn)
        .await;
        match r {
            Ok(done) => return Ok((done.last_insert_rowid(), tag)),
            Err(e) if is_unique_violation(&e) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    Err(NameTakenError::Full)
}

#[derive(Debug, thiserror::Error)]
pub enum RenameError {
    #[error("no such account")]
    NotFound,
    #[error("renamed too recently; next rename at {0}")]
    Cooldown(i64),
    #[error(transparent)]
    Taken(#[from] NameTakenError),
}

impl From<sqlx::Error> for RenameError {
    fn from(e: sqlx::Error) -> Self {
        RenameError::Taken(NameTakenError::Db(e))
    }
}

/// Renames an account to an already validated `name`, keeping its tag when that is
/// free for the new name. With `cooldown`, refuses if the last rename was less than
/// that long ago (checked in the UPDATE itself, so concurrent renames cannot both
/// pass). Sets `name_changed_at = now`.
pub async fn rename(
    db: &SqlitePool,
    id: i64,
    name: &str,
    now: i64,
    cooldown: Option<i64>,
) -> Result<Account, RenameError> {
    let mut conn = db.acquire().await?;
    let current = get(&mut *conn, id).await?.ok_or(RenameError::NotFound)?;
    // Renames at or before this time are old enough.
    let changed_before = cooldown.map_or(i64::MAX, |c| now.saturating_sub(c));
    if let Some(next) = cooldown.and_then(|c| current.next_rename_at(now, c)) {
        return Err(RenameError::Cooldown(next));
    }
    for attempt in 0..=RANDOM_TAG_ATTEMPTS + 1 {
        let tag = match attempt {
            0 => current.tag,
            a if a <= RANDOM_TAG_ATTEMPTS => crate::auth::random_below(TAG_COUNT) as u16,
            _ => free_tag(&mut conn, name).await?,
        };
        let tag_i = tag as i64;
        let r = sqlx::query!(
            "UPDATE accounts SET display_name = ?, tag = ?, name_changed_at = ?
             WHERE id = ? AND (name_changed_at IS NULL OR name_changed_at <= ?)",
            name,
            tag_i,
            now,
            id,
            changed_before
        )
        .execute(&mut *conn)
        .await;
        match r {
            Ok(done) if done.rows_affected() == 1 => {
                return get(&mut *conn, id).await?.ok_or(RenameError::NotFound);
            }
            Ok(_) => {
                // Lost a race with another rename (or the account is gone).
                let acc = get(&mut *conn, id).await?.ok_or(RenameError::NotFound)?;
                let next = cooldown
                    .and_then(|c| acc.next_rename_at(now, c))
                    .unwrap_or(now);
                return Err(RenameError::Cooldown(next));
            }
            Err(e) if is_unique_violation(&e) => continue,
            Err(e) => return Err(e.into()),
        }
    }
    Err(NameTakenError::Full.into())
}

/// Sets or clears `banned_until`. Returns false if there is no such account.
pub async fn set_ban(db: &SqlitePool, id: i64, until: Option<i64>) -> sqlx::Result<bool> {
    let r = sqlx::query!(
        "UPDATE accounts SET banned_until = ? WHERE id = ?",
        until,
        id
    )
    .execute(db)
    .await?;
    Ok(r.rows_affected() == 1)
}

/// What an account deletion removed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DeleteReport {
    pub accounts: u64,
    pub refresh_tokens: u64,
}

/// Deletes an account and everything that belongs to it, in one transaction, and
/// records it in `admin_log` (account id and row counts only: no name, no PII).
///
/// **Hook for later milestones.** Each table that references an account adds its
/// delete here, inside the same transaction, when its WP lands:
/// - `friends` (N9): rows where `account_a` or `account_b` is the account;
/// - `blocks` (N9): rows where `account_id` or `blocked_id` is the account;
/// - `crew_members` (N9): the membership; a crew it owns passes to the oldest member
///   or is disbanded when empty (`crews`);
/// - `leaderboard_entries` (N7): the account's entries;
/// - `runs` (N7) and `replays` (N8): the rows, then the replay files under
///   `data/replays/` after commit;
/// - `reports` (N9): keep the report for moderation but null out the reporter;
/// - Apple token revocation (MP-D2): call Apple's revoke endpoint before deleting
///   when `apple_sub` is set.
pub async fn delete(db: &SqlitePool, id: i64, actor: &str) -> anyhow::Result<DeleteReport> {
    let mut tx = db.begin().await?;
    let refresh_tokens = sqlx::query!("DELETE FROM refresh_tokens WHERE account_id = ?", id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    // (future tables: see the list above)
    let accounts = sqlx::query!("DELETE FROM accounts WHERE id = ?", id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    let report = DeleteReport {
        accounts,
        refresh_tokens,
    };
    if accounts == 1 {
        crate::db::admin_log(
            &mut *tx,
            actor,
            "account_delete",
            &id.to_string(),
            &format!("refresh_tokens={refresh_tokens}"),
        )
        .await?;
    }
    tx.commit().await?;
    Ok(report)
}

/// `last_seen = now` (sign-in and refresh).
pub async fn touch(db: impl sqlx::SqliteExecutor<'_>, id: i64, now: i64) -> sqlx::Result<()> {
    sqlx::query!("UPDATE accounts SET last_seen = ? WHERE id = ?", now, id)
        .execute(db)
        .await?;
    Ok(())
}

/// Deletes refresh tokens past their expiry (used ones included: after expiry a
/// replay is refused as expired or unknown either way). Returns how many.
pub async fn prune_refresh_tokens(db: &SqlitePool, now: i64) -> sqlx::Result<u64> {
    Ok(
        sqlx::query!("DELETE FROM refresh_tokens WHERE expires_at <= ?", now)
            .execute(db)
            .await?
            .rows_affected(),
    )
}
