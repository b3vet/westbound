//! SQLite (WAL) pool, migrations, online backup. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Data model (SQLite)", "Resource budget and deployment" (nightly backup);
//! docs/MULTIPLAYER_PLAN.md MP-D1 (backup runs inside the server, onto the volume).
//!
//! Compile-time checked queries use the offline metadata in `westbound-server/.sqlx/`;
//! regenerate it with `cargo sqlx prepare --workspace` (see docs/SERVER.md).

use std::path::Path;
use std::str::FromStr;
use std::time::Duration;

use anyhow::{bail, Context};
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::SqlitePool;

use crate::config::DbConfig;

pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

/// Opens (creating if missing) the database in WAL mode with foreign keys on.
pub async fn connect(cfg: &DbConfig) -> anyhow::Result<SqlitePool> {
    if let Some(parent) = cfg.path.parent() {
        if !parent.as_os_str().is_empty() {
            tokio::fs::create_dir_all(parent)
                .await
                .with_context(|| format!("creating database directory {}", parent.display()))?;
        }
    }
    let opts = SqliteConnectOptions::from_str("sqlite://")?
        .filename(&cfg.path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_millis(cfg.busy_timeout_ms));
    let pool = SqlitePoolOptions::new()
        .max_connections(cfg.max_connections)
        .connect_with(opts)
        .await
        .with_context(|| format!("opening database {}", cfg.path.display()))?;
    Ok(pool)
}

pub async fn migrate(pool: &SqlitePool) -> anyhow::Result<()> {
    MIGRATOR.run(pool).await.context("applying migrations")?;
    Ok(())
}

/// Cheap liveness probe for `/api/v1/health`.
pub async fn ping(pool: &SqlitePool) -> bool {
    sqlx::query_scalar!("SELECT 1 AS ok")
        .fetch_one(pool)
        .await
        .is_ok()
}

/// Consistent online snapshot of the live database into `dest` (`VACUUM INTO`),
/// safe while the server is writing. `dest` must not exist yet.
pub async fn backup_to(pool: &SqlitePool, dest: &Path) -> anyhow::Result<()> {
    if dest.exists() {
        bail!("backup target {} already exists", dest.display());
    }
    if let Some(parent) = dest.parent() {
        if !parent.as_os_str().is_empty() {
            tokio::fs::create_dir_all(parent)
                .await
                .with_context(|| format!("creating backup directory {}", parent.display()))?;
        }
    }
    let dest_str = dest
        .to_str()
        .with_context(|| format!("backup path {} is not UTF-8", dest.display()))?;
    sqlx::query("VACUUM INTO ?")
        .bind(dest_str)
        .execute(pool)
        .await
        .with_context(|| format!("VACUUM INTO {}", dest.display()))?;
    Ok(())
}

/// Appends to `admin_log` (actor = who, e.g. `system`, `cli` or `self`). Takes a pool
/// or a transaction. Never put tokens, secrets, IPs or other PII in it.
pub async fn admin_log(
    db: impl sqlx::SqliteExecutor<'_>,
    actor: &str,
    action: &str,
    target: &str,
    detail: &str,
) -> anyhow::Result<()> {
    let now = crate::clock::unix_now_secs();
    sqlx::query!(
        "INSERT INTO admin_log (actor, action, target, detail, created_at) VALUES (?, ?, ?, ?, ?)",
        actor,
        action,
        target,
        detail,
        now
    )
    .execute(db)
    .await
    .context("writing admin_log")?;
    Ok(())
}

/// Checkpoints the WAL into the main file and closes the pool (graceful shutdown).
pub async fn close(pool: &SqlitePool) {
    if let Err(e) = sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .execute(pool)
        .await
    {
        tracing::warn!(error = %e, "wal checkpoint on shutdown failed");
    }
    pool.close().await;
}
