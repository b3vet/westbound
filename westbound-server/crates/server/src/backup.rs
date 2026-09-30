//! Nightly online backup with retention. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Resource budget and deployment" (nightly `.backup` to a dated file, 7-day
//! retention, "plus an optional copy off the machine"); docs/MULTIPLAYER_PLAN.md MP-D1 (a
//! scheduled task inside the server).
//!
//! N10.2: each backup is checked (`PRAGMA integrity_check` on the copy, opened read-only),
//! an optional off-site hook runs after a good one (`backup.upload_command`, argv with
//! `{file}`), the last success is in `/metrics`, and [`restore`] puts a backup in place of
//! the live database (the server stopped): the current file is kept beside it, the copy is
//! verified, migrations run. Runbook: docs/OPERATIONS.md → Backups.

use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;
use tokio_util::sync::CancellationToken;

use crate::clock::{self, SECS_PER_DAY};
use crate::config::{parse_hh_mm, BackupConfig, DbConfig};
use crate::metrics::Metrics;

const FILE_PREFIX: &str = "westbound-";
const FILE_SUFFIX: &str = ".db";
const SECS_PER_MINUTE: i64 = 60;

/// `westbound-YYYY-MM-DD.db` for the UTC date of `unix_secs`.
pub fn dated_file_name(unix_secs: i64) -> String {
    format!(
        "{FILE_PREFIX}{}{FILE_SUFFIX}",
        clock::utc_date_string(unix_secs)
    )
}

/// Next unix time strictly after `now` at `minutes_utc` past UTC midnight.
pub fn next_run_after(now: i64, minutes_utc: u32) -> i64 {
    let midnight = now.div_euclid(SECS_PER_DAY) * SECS_PER_DAY;
    let today = midnight + i64::from(minutes_utc) * SECS_PER_MINUTE;
    if today > now {
        today
    } else {
        today + SECS_PER_DAY
    }
}

/// Writes today's dated backup (replacing an earlier one from the same day), then
/// prunes old files. Returns the backup path. With `cfg.verify` the copy is checked before
/// it replaces anything (a bad copy is deleted and the run fails).
pub async fn run_once(pool: &SqlitePool, cfg: &BackupConfig, now: i64) -> anyhow::Result<PathBuf> {
    tokio::fs::create_dir_all(&cfg.dir).await?;
    let name = dated_file_name(now);
    let dest = cfg.dir.join(&name);
    let tmp = cfg.dir.join(format!("{name}.tmp"));
    let _ = tokio::fs::remove_file(&tmp).await;
    crate::db::backup_to(pool, &tmp).await?;
    if cfg.verify {
        if let Err(e) = verify(&tmp).await {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(e.context(format!("backup {name} failed its integrity check")));
        }
    }
    tokio::fs::rename(&tmp, &dest).await?;
    let removed = prune(&cfg.dir, cfg.retention_days, now)?;
    let detail = format!("removed {} old", removed.len());
    crate::db::admin_log(pool, "system", "backup", &name, &detail).await?;
    Ok(dest)
}

/// Deletes `westbound-YYYY-MM-DD.db` files dated `retention_days` or more days
/// before `now`'s date (so exactly `retention_days` dated files remain). Other
/// files are left alone.
pub fn prune(dir: &Path, retention_days: u32, now: i64) -> std::io::Result<Vec<PathBuf>> {
    let today = now.div_euclid(SECS_PER_DAY);
    let mut removed = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(date) = name
            .strip_prefix(FILE_PREFIX)
            .and_then(|r| r.strip_suffix(FILE_SUFFIX))
        else {
            continue;
        };
        let Some(days) = clock::parse_date_days(date) else {
            continue;
        };
        if today - days >= i64::from(retention_days) {
            std::fs::remove_file(entry.path())?;
            removed.push(entry.path());
        }
    }
    removed.sort();
    Ok(removed)
}

/// The scheduled task: sleeps until `time_utc`, backs up, repeats until cancelled.
pub async fn nightly(
    pool: SqlitePool,
    cfg: BackupConfig,
    metrics: Arc<Metrics>,
    cancel: CancellationToken,
) {
    let Some(minutes) = parse_hh_mm(&cfg.time_utc) else {
        return;
    };
    loop {
        let now = clock::unix_now_secs();
        let wait = (next_run_after(now, minutes) - now).max(0) as u64;
        tracing::info!(in_secs = wait, dir = %cfg.dir.display(), "next nightly backup scheduled");
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(Duration::from_secs(wait)) => {}
        }
        run_and_record(&pool, &cfg, &metrics, clock::unix_now_secs()).await;
    }
}

/// One scheduled backup with its metrics, logs and the off-site hook.
pub async fn run_and_record(
    pool: &SqlitePool,
    cfg: &BackupConfig,
    metrics: &Metrics,
    now: i64,
) -> Option<PathBuf> {
    let t0 = Instant::now();
    match run_once(pool, cfg, now).await {
        Ok(path) => {
            Metrics::inc(&metrics.backups_ok);
            Metrics::set(
                &metrics.backup_last_success_unix,
                u64::try_from(now).unwrap_or(0),
            );
            Metrics::set(
                &metrics.backup_last_bytes,
                std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
            );
            Metrics::set(
                &metrics.backup_last_duration_ms,
                u64::try_from(t0.elapsed().as_millis()).unwrap_or(u64::MAX),
            );
            tracing::info!(path = %path.display(), "nightly backup written");
            if !cfg.upload_command.is_empty() {
                match upload(cfg, &path).await {
                    Ok(()) => {
                        Metrics::inc(&metrics.backup_uploads_ok);
                        tracing::info!(path = %path.display(), "backup copied off-site");
                    }
                    Err(e) => {
                        Metrics::inc(&metrics.backup_uploads_failed);
                        tracing::error!(error = %format!("{e:#}"), "off-site backup hook failed");
                    }
                }
            }
            Some(path)
        }
        Err(e) => {
            Metrics::inc(&metrics.backups_failed);
            if format!("{e:#}").contains("integrity check") {
                Metrics::inc(&metrics.backup_verify_failed);
            }
            tracing::error!(error = %format!("{e:#}"), "nightly backup failed");
            None
        }
    }
}

/// Opens `path` read-only (immutable: nothing is written beside it) and runs
/// `PRAGMA integrity_check`; `Ok` only for `ok`. Also returns the number of applied
/// migrations it records.
pub async fn verify(path: &Path) -> anyhow::Result<i64> {
    if !path.is_file() {
        bail!("{} is not a file", path.display());
    }
    let opts = SqliteConnectOptions::from_str("sqlite://")?
        .filename(path)
        .read_only(true)
        .immutable(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(opts)
        .await
        .with_context(|| format!("opening {}", path.display()))?;
    let result: anyhow::Result<i64> = async {
        let rows: Vec<String> = sqlx::query_scalar("PRAGMA integrity_check")
            .fetch_all(&pool)
            .await
            .context("PRAGMA integrity_check")?;
        if rows != ["ok"] {
            bail!("integrity check: {}", rows.join("; "));
        }
        let migrations: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE success = 1")
                .fetch_one(&pool)
                .await
                .context("not a westbound database (no _sqlx_migrations)")?;
        Ok(migrations)
    }
    .await;
    pool.close().await;
    result
}

/// Runs `backup.upload_command` for `file` (`{file}` in any argument), killed after
/// `backup.upload_timeout_secs`. `Ok` on exit status 0.
pub async fn upload(cfg: &BackupConfig, file: &Path) -> anyhow::Result<()> {
    let Some((program, args)) = cfg.upload_command.split_first() else {
        return Ok(());
    };
    let f = file.to_string_lossy();
    let mut cmd = tokio::process::Command::new(program.replace("{file}", &f));
    cmd.args(args.iter().map(|a| a.replace("{file}", &f)))
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let run = async {
        let out = cmd
            .output()
            .await
            .with_context(|| format!("starting {program}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            let tail: String = err
                .chars()
                .rev()
                .take(UPLOAD_STDERR_TAIL)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            bail!("{program} exited with {}: {}", out.status, tail.trim());
        }
        Ok(())
    };
    tokio::time::timeout(Duration::from_secs(cfg.upload_timeout_secs), run)
        .await
        .with_context(|| {
            format!(
                "{program} ran over {} s and was killed",
                cfg.upload_timeout_secs
            )
        })?
}

/// Characters of the hook's stderr kept in the error.
const UPLOAD_STDERR_TAIL: usize = 400;

/// A dated backup file in the backup directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupFile {
    pub name: String,
    pub bytes: u64,
}

/// The `westbound-YYYY-MM-DD.db` files in `dir`, oldest first (others are ignored).
pub fn list(dir: &Path) -> std::io::Result<Vec<BackupFile>> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let dated = name
            .strip_prefix(FILE_PREFIX)
            .and_then(|r| r.strip_suffix(FILE_SUFFIX))
            .and_then(clock::parse_date_days)
            .is_some();
        if dated {
            out.push(BackupFile {
                name,
                bytes: entry.metadata()?.len(),
            });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// What [`restore`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Restored {
    /// Where the database that was replaced went (None: there was none).
    pub previous: Option<PathBuf>,
    /// Migrations recorded in the backup, and after the restore (newer ones applied).
    pub migrations_in_backup: i64,
    pub migrations_now: i64,
}

/// Puts `backup` in place of `db.path`. **The server must be stopped** (the caller checks
/// that nothing answers on its port). Steps: verify the backup; move the current database
/// and its `-wal` / `-shm` aside to `<db>.before-restore-<unix secs>` (nothing is deleted);
/// copy the backup next to the database and rename it into place; apply newer migrations.
pub async fn restore(db: &DbConfig, backup: &Path, now: i64) -> anyhow::Result<Restored> {
    let migrations_in_backup = verify(backup)
        .await
        .with_context(|| format!("backup {} is not usable", backup.display()))?;
    let target = &db.path;
    if let Some(dir) = target.parent() {
        if !dir.as_os_str().is_empty() {
            tokio::fs::create_dir_all(dir).await?;
        }
    }
    let previous = if target.exists() {
        let aside = PathBuf::from(format!("{}.before-restore-{now}", target.display()));
        tokio::fs::rename(target, &aside)
            .await
            .with_context(|| format!("moving {} aside", target.display()))?;
        for suffix in ["-wal", "-shm"] {
            let side = PathBuf::from(format!("{}{suffix}", target.display()));
            if side.exists() {
                let to = PathBuf::from(format!("{}{suffix}", aside.display()));
                tokio::fs::rename(&side, &to).await?;
            }
        }
        Some(aside)
    } else {
        None
    };
    let tmp = PathBuf::from(format!("{}.restore-tmp", target.display()));
    tokio::fs::copy(backup, &tmp)
        .await
        .with_context(|| format!("copying {}", backup.display()))?;
    tokio::fs::rename(&tmp, target).await?;
    let pool = crate::db::connect(db).await?;
    crate::db::migrate(&pool).await?;
    let migrations_now: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE success = 1")
            .fetch_one(&pool)
            .await?;
    crate::db::admin_log(
        &pool,
        "cli",
        "restore",
        &backup.display().to_string(),
        &format!(
            "previous={} migrations={migrations_in_backup}->{migrations_now}",
            previous
                .as_ref()
                .map_or("none".to_string(), |p| p.display().to_string())
        ),
    )
    .await?;
    crate::db::close(&pool).await;
    Ok(Restored {
        previous,
        migrations_in_backup,
        migrations_now,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedules_next_run() {
        let day = 20_000 * SECS_PER_DAY;
        let at = 3 * 60 + 17;
        assert_eq!(next_run_after(day, at), day + 3 * 3600 + 17 * 60);
        assert_eq!(
            next_run_after(day + 3 * 3600 + 17 * 60, at),
            day + SECS_PER_DAY + 3 * 3600 + 17 * 60
        );
        assert_eq!(
            next_run_after(day + 23 * 3600, at),
            day + SECS_PER_DAY + 3 * 3600 + 17 * 60
        );
    }

    #[tokio::test]
    async fn backup_verifies_restores_and_lists() {
        let dir = tempfile::tempdir().unwrap();
        let db = DbConfig {
            path: dir.path().join("live").join("westbound.db"),
            ..Default::default()
        };
        let pool = crate::db::connect(&db).await.unwrap();
        crate::db::migrate(&pool).await.unwrap();
        sqlx::query("INSERT INTO admin_log (actor, action, target, detail, created_at) VALUES ('t', 'marker', 'x', '', 1)")
            .execute(&pool)
            .await
            .unwrap();
        let cfg = BackupConfig {
            dir: dir.path().join("backups"),
            ..Default::default()
        };
        let now = clock::parse_date_days("2026-09-29").unwrap() * SECS_PER_DAY + 5_000;
        let file = run_once(&pool, &cfg, now).await.unwrap();
        assert_eq!(file.file_name().unwrap(), "westbound-2026-09-29.db");
        let migrations = verify(&file).await.unwrap();
        assert_eq!(migrations, crate::db::MIGRATOR.iter().count() as i64);
        assert_eq!(list(&cfg.dir).unwrap().len(), 1);
        // Changes after the backup are gone after the restore; the old file is kept.
        sqlx::query("DELETE FROM admin_log")
            .execute(&pool)
            .await
            .unwrap();
        crate::db::close(&pool).await;
        let r = restore(&db, &file, now).await.unwrap();
        let aside = r.previous.expect("the replaced database is kept");
        assert!(aside.exists());
        assert_eq!(r.migrations_now, migrations);
        let pool = crate::db::connect(&db).await.unwrap();
        let marker: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM admin_log WHERE action = 'marker'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(marker, 1);
        crate::db::close(&pool).await;
        // Not a database, or corrupt: refused, and the live file stays.
        let junk = dir.path().join("junk.db");
        std::fs::write(&junk, vec![7u8; 8192]).unwrap();
        assert!(verify(&junk).await.is_err());
        assert!(restore(&db, &junk, now + 1).await.is_err());
        assert!(db.path.exists());
    }

    #[tokio::test]
    async fn upload_hook_runs_with_the_file_and_reports_failures() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("westbound-2026-09-29.db");
        std::fs::write(&file, b"x").unwrap();
        let copy = dir.path().join("offsite.db");
        let ok = BackupConfig {
            upload_command: vec![
                "cp".into(),
                "{file}".into(),
                copy.to_string_lossy().into_owned(),
            ],
            upload_timeout_secs: 10,
            ..Default::default()
        };
        upload(&ok, &file).await.unwrap();
        assert!(copy.exists());
        let fails = BackupConfig {
            upload_command: vec!["false".into()],
            upload_timeout_secs: 10,
            ..Default::default()
        };
        assert!(upload(&fails, &file).await.is_err());
        let slow = BackupConfig {
            upload_command: vec!["sleep".into(), "5".into()],
            upload_timeout_secs: 1,
            ..Default::default()
        };
        let e = upload(&slow, &file).await.unwrap_err();
        assert!(format!("{e:#}").contains("killed"), "{e:#}");
    }

    #[test]
    fn prunes_old_dated_files_only() {
        let dir = tempfile::tempdir().unwrap();
        let now = clock::parse_date_days("2026-09-29").unwrap() * SECS_PER_DAY + 5_000;
        for name in [
            "westbound-2026-09-29.db",
            "westbound-2026-09-23.db",
            "westbound-2026-09-22.db",
            "westbound-2026-08-01.db",
            "westbound-not-a-date.db",
            "notes.txt",
        ] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        let removed = prune(dir.path(), 7, now).unwrap();
        let removed: Vec<String> = removed
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            removed,
            vec!["westbound-2026-08-01.db", "westbound-2026-09-22.db"]
        );
        assert!(dir.path().join("westbound-2026-09-23.db").exists());
        assert!(dir.path().join("notes.txt").exists());
    }
}
