//! The identity tables (N11): provider subjects on `accounts`, `identity_links`,
//! `device_secrets`, and the account summaries a link conflict shows. Migration 0008.

use serde::{Deserialize, Serialize};
use sqlx::{SqliteConnection, SqlitePool};

use super::{Provider, VerifiedIdentity};
use crate::accounts::Linked;

/// Longest provider subject stored (Google's are 21 digits, Apple's about 44 characters).
pub const MAX_SUB_BYTES: usize = 255;

/// A linked identity as the profile shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdentityInfo {
    pub provider: Provider,
    /// `j***@gmail.com`; null for none or a private relay address.
    pub email_hint: Option<String>,
    /// Apple's Hide My Email.
    pub private_email: bool,
    pub linked_at: i64,
}

/// What Apple needs to revoke a grant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleGrant {
    pub client_id: String,
    pub sealed_refresh: Vec<u8>,
}

/// One side of a link conflict (`409 identity_in_use`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountSummary {
    pub account_id: String,
    pub full_name: String,
    pub created_at: i64,
    pub last_seen: i64,
    pub linked: Linked,
    /// Runs on the server (leaderboard submissions and multiplayer runs).
    pub runs: i64,
    pub best_score: i64,
    /// The account's cloud save, if any.
    pub cloud_save: Option<SaveSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SaveSummary {
    pub revision: i64,
    pub updated_at: i64,
    pub bytes: i64,
    /// `stats.xp` and `stats.runs` of the saved document, when present (the driver level
    /// and runs played, for the chooser).
    pub xp: Option<i64>,
    pub runs: Option<i64>,
}

fn is_unique_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(d) if d.is_unique_violation())
}

/// The account a provider identity belongs to.
pub async fn account_for(
    db: impl sqlx::SqliteExecutor<'_>,
    provider: Provider,
    sub: &str,
) -> sqlx::Result<Option<i64>> {
    match provider {
        Provider::Apple => {
            sqlx::query_scalar!(
                r#"SELECT id AS "id!" FROM accounts WHERE apple_sub = ?"#,
                sub
            )
            .fetch_optional(db)
            .await
        }
        Provider::Google => {
            sqlx::query_scalar!(
                r#"SELECT id AS "id!" FROM accounts WHERE google_sub = ?"#,
                sub
            )
            .fetch_optional(db)
            .await
        }
    }
}

/// The subject linked to `id` for `provider` (None: not linked or no account).
pub async fn linked_sub(
    db: impl sqlx::SqliteExecutor<'_>,
    provider: Provider,
    id: i64,
) -> sqlx::Result<Option<String>> {
    let v = match provider {
        Provider::Apple => {
            sqlx::query_scalar!("SELECT apple_sub FROM accounts WHERE id = ?", id)
                .fetch_optional(db)
                .await?
        }
        Provider::Google => {
            sqlx::query_scalar!("SELECT google_sub FROM accounts WHERE id = ?", id)
                .fetch_optional(db)
                .await?
        }
    };
    Ok(v.flatten())
}

#[derive(Debug, thiserror::Error)]
pub enum LinkError {
    /// The identity is linked to this other account.
    #[error("identity linked to account {0}")]
    InUse(i64),
    /// The account already has another identity of this provider.
    #[error("another identity of this provider is linked")]
    AlreadyLinked,
    #[error("no such account")]
    NotFound,
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),
}

/// Sets the account's subject for the provider (it must have none) and records the link.
pub async fn link(
    conn: &mut SqliteConnection,
    id: i64,
    v: &VerifiedIdentity,
    apple_sealed: Option<&[u8]>,
    now: i64,
) -> Result<(), LinkError> {
    let sub = v.sub.as_str();
    let r = match v.provider {
        Provider::Apple => {
            sqlx::query!(
                "UPDATE accounts SET apple_sub = ? WHERE id = ? AND apple_sub IS NULL",
                sub,
                id
            )
            .execute(&mut *conn)
            .await
        }
        Provider::Google => {
            sqlx::query!(
                "UPDATE accounts SET google_sub = ? WHERE id = ? AND google_sub IS NULL",
                sub,
                id
            )
            .execute(&mut *conn)
            .await
        }
    };
    match r {
        Ok(done) if done.rows_affected() == 1 => {}
        Ok(_) => {
            let exists = sqlx::query_scalar!("SELECT 1 AS one FROM accounts WHERE id = ?", id)
                .fetch_optional(&mut *conn)
                .await?;
            return Err(if exists.is_some() {
                LinkError::AlreadyLinked
            } else {
                LinkError::NotFound
            });
        }
        Err(e) if is_unique_violation(&e) => {
            let other = account_for(&mut *conn, v.provider, sub).await?;
            return Err(other.map_or(LinkError::AlreadyLinked, LinkError::InUse));
        }
        Err(e) => return Err(e.into()),
    }
    record_link(conn, id, v, apple_sealed, now).await?;
    Ok(())
}

/// Inserts or refreshes the `identity_links` row (a sign-in refreshes the hint and the
/// last use; a new Apple grant replaces the old one).
pub async fn record_link(
    conn: &mut SqliteConnection,
    id: i64,
    v: &VerifiedIdentity,
    apple_sealed: Option<&[u8]>,
    now: i64,
) -> sqlx::Result<()> {
    let provider = v.provider.as_str();
    let private = i64::from(v.private_email);
    let client_id =
        (v.provider == Provider::Apple && apple_sealed.is_some()).then_some(v.client_id.as_str());
    sqlx::query!(
        "INSERT INTO identity_links
             (account_id, provider, email_hint, private_email, linked_at, last_used_at,
              apple_client_id, apple_refresh_sealed)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (account_id, provider) DO UPDATE SET
             email_hint = excluded.email_hint,
             private_email = excluded.private_email,
             last_used_at = excluded.last_used_at,
             apple_client_id = COALESCE(excluded.apple_client_id, apple_client_id),
             apple_refresh_sealed = COALESCE(excluded.apple_refresh_sealed, apple_refresh_sealed)",
        id,
        provider,
        v.email_hint,
        private,
        now,
        now,
        client_id,
        apple_sealed
    )
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// The stored Apple grant of an account (None: none kept).
pub async fn apple_grant(
    db: impl sqlx::SqliteExecutor<'_>,
    id: i64,
) -> sqlx::Result<Option<AppleGrant>> {
    let row = sqlx::query!(
        "SELECT apple_client_id, apple_refresh_sealed FROM identity_links
         WHERE account_id = ? AND provider = 'apple'",
        id
    )
    .fetch_optional(db)
    .await?;
    Ok(row.and_then(|r| {
        Some(AppleGrant {
            client_id: r.apple_client_id?,
            sealed_refresh: r.apple_refresh_sealed?,
        })
    }))
}

/// Removes the provider from the account. Returns false when it was not linked.
pub async fn unlink(
    conn: &mut SqliteConnection,
    id: i64,
    provider: Provider,
) -> sqlx::Result<bool> {
    let done = match provider {
        Provider::Apple => {
            sqlx::query!(
                "UPDATE accounts SET apple_sub = NULL WHERE id = ? AND apple_sub IS NOT NULL",
                id
            )
            .execute(&mut *conn)
            .await?
        }
        Provider::Google => {
            sqlx::query!(
                "UPDATE accounts SET google_sub = NULL WHERE id = ? AND google_sub IS NOT NULL",
                id
            )
            .execute(&mut *conn)
            .await?
        }
    };
    let p = provider.as_str();
    sqlx::query!(
        "DELETE FROM identity_links WHERE account_id = ? AND provider = ?",
        id,
        p
    )
    .execute(&mut *conn)
    .await?;
    Ok(done.rows_affected() == 1)
}

/// The ways into an account other than `except`: (other providers linked, device
/// credentials on the server).
pub async fn other_sign_in_methods(
    conn: &mut SqliteConnection,
    id: i64,
    except: Provider,
) -> sqlx::Result<(u32, bool)> {
    let r = sqlx::query!(
        r#"SELECT apple_sub IS NOT NULL AS "apple!: bool",
                  google_sub IS NOT NULL AS "google!: bool",
                  (device_secret_hash IS NOT NULL
                   OR EXISTS (SELECT 1 FROM device_secrets WHERE account_id = accounts.id))
                      AS "device!: bool"
           FROM accounts WHERE id = ?"#,
        id
    )
    .fetch_optional(&mut *conn)
    .await?;
    let Some(r) = r else {
        return Ok((0, false));
    };
    let providers = u32::from(r.apple && except != Provider::Apple)
        + u32::from(r.google && except != Provider::Google);
    Ok((providers, r.device))
}

/// The account's linked identities (the profile's `identities`).
pub async fn identities(
    db: impl sqlx::SqliteExecutor<'_>,
    id: i64,
) -> sqlx::Result<Vec<IdentityInfo>> {
    let rows = sqlx::query!(
        "SELECT provider, email_hint, private_email, linked_at FROM identity_links
         WHERE account_id = ? ORDER BY provider",
        id
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(|r| {
            Some(IdentityInfo {
                provider: Provider::parse(&r.provider)?,
                email_hint: r.email_hint,
                private_email: r.private_email != 0,
                linked_at: r.linked_at,
            })
        })
        .collect())
}

/// Stores a new device credential for the account and drops the least recently used
/// beyond `max`.
pub async fn add_device_secret(
    conn: &mut SqliteConnection,
    id: i64,
    hash: &[u8],
    max: i64,
    now: i64,
) -> sqlx::Result<()> {
    sqlx::query!(
        "INSERT INTO device_secrets (secret_hash, account_id, created_at, last_used_at)
         VALUES (?, ?, ?, ?)",
        hash,
        id,
        now,
        now
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!(
        "DELETE FROM device_secrets WHERE account_id = ?1 AND secret_hash NOT IN
             (SELECT secret_hash FROM device_secrets WHERE account_id = ?1
              ORDER BY last_used_at DESC, created_at DESC LIMIT ?2)",
        id,
        max
    )
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Whether `hash` is one of the account's extra device credentials (and marks it used).
pub async fn use_device_secret(
    db: impl sqlx::SqliteExecutor<'_>,
    id: i64,
    hash: &[u8],
    now: i64,
) -> sqlx::Result<bool> {
    let done = sqlx::query!(
        "UPDATE device_secrets SET last_used_at = ? WHERE secret_hash = ? AND account_id = ?",
        now,
        hash,
        id
    )
    .execute(db)
    .await?;
    Ok(done.rows_affected() == 1)
}

/// A conflict side's summary (None: no such account).
pub async fn summary(db: &SqlitePool, id: i64) -> sqlx::Result<Option<AccountSummary>> {
    let Some(acc) = crate::accounts::get(db, id).await? else {
        return Ok(None);
    };
    let runs = sqlx::query!(
        r#"SELECT COUNT(*) AS "n!: i64", COALESCE(MAX(score), 0) AS "best!: i64"
           FROM runs WHERE account_id = ?"#,
        id
    )
    .fetch_one(db)
    .await?;
    let save = sqlx::query!(
        r#"SELECT revision, updated_at, bytes,
                  CAST(json_extract(data, '$.stats.xp') AS INTEGER) AS "xp?: i64",
                  CAST(json_extract(data, '$.stats.runs') AS INTEGER) AS "runs?: i64"
           FROM cloud_saves WHERE account_id = ?"#,
        id
    )
    .fetch_optional(db)
    .await?;
    Ok(Some(AccountSummary {
        account_id: acc.id.to_string(),
        full_name: crate::names::full_name(&acc.display_name, acc.tag),
        created_at: acc.created_at,
        last_seen: acc.last_seen,
        linked: Linked {
            apple: acc.apple_linked,
            google: acc.google_linked,
        },
        runs: runs.n,
        best_score: runs.best,
        cloud_save: save.map(|s| SaveSummary {
            revision: s.revision,
            updated_at: s.updated_at,
            bytes: s.bytes,
            xp: s.xp,
            runs: s.runs,
        }),
    }))
}
