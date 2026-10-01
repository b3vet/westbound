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
//!
//! N10.3 (the volume is small): `backup.retention_days` is a **count** of dated daily
//! backups (default 3): after a good backup the older ones beyond it go, newest kept first
//! and the one just written never deleted; a failed or skipped run deletes nothing.
//! Before writing, the run checks the volume has room for a copy of the database plus
//! `housekeeping.min_free_mb` and skips (an error, `wb_backups_skipped_total`) when not.
//! [`status`] reads the newest backup's age for the stale check (`backup.max_age_hours`),
//! and [`prune_other`] ages out manual backups and the copies a restore left.

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
const TMP_SUFFIX: &str = ".tmp";
const SECS_PER_MINUTE: i64 = 60;
const SECS_PER_HOUR: i64 = 3_600;
/// A leftover `.tmp` (an interrupted backup) older than this is deleted.
const TMP_MAX_AGE_SECS: i64 = SECS_PER_DAY;
/// What a restore calls the database it moved aside: `<db>.before-restore-<unix secs>`.
pub const BEFORE_RESTORE: &str = ".before-restore-";

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
    let removed = prune(&cfg.dir, cfg.retention_days, Some(&dest))?;
    let detail = format!("removed {} old", removed.len());
    crate::db::admin_log(pool, "system", "backup", &name, &detail).await?;
    Ok(dest)
}

/// The date of a `westbound-YYYY-MM-DD.db` name (days since the epoch).
fn dated(name: &str) -> Option<i64> {
    name.strip_prefix(FILE_PREFIX)
        .and_then(|r| r.strip_suffix(FILE_SUFFIX))
        .and_then(clock::parse_date_days)
}

/// Keeps the newest `keep` dated backups (`westbound-YYYY-MM-DD.db`, by date) and deletes
/// the older ones; `protect` (the backup just written) is never deleted, whatever its
/// date. `keep` 0 is treated as 1: the newest backup always stays. Other files are left
/// alone. Returns the deleted paths, sorted.
pub fn prune(dir: &Path, keep: u32, protect: Option<&Path>) -> std::io::Result<Vec<PathBuf>> {
    let mut files: Vec<(i64, PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(day) = name.to_str().and_then(dated) else {
            continue;
        };
        if entry.file_type()?.is_file() {
            files.push((day, entry.path()));
        }
    }
    // Newest first.
    files.sort_by(|a, b| b.cmp(a));
    let keep = usize::try_from(keep.max(1)).unwrap_or(usize::MAX);
    let mut removed = Vec::new();
    for (_, path) in files.into_iter().skip(keep) {
        if protect.is_some_and(|p| p == path) {
            continue;
        }
        std::fs::remove_file(&path)?;
        removed.push(path);
    }
    removed.sort();
    Ok(removed)
}

/// N10.3: ages out what else holds a database copy on the volume, `max_age_days` after it
/// was written (0: nothing): non-dated `.db` files in the backup directory (manual and
/// pre-deploy backups, by modification time) and `<db>.before-restore-<unix secs>` beside
/// the database (with its `-wal` / `-shm`, by the time in the name). Leftover `.tmp` files
/// in the backup directory go after a day regardless. Returns the deleted paths, sorted.
pub fn prune_other(
    dir: &Path,
    db_path: &Path,
    max_age_days: u32,
    now: i64,
) -> std::io::Result<Vec<PathBuf>> {
    let max_age = i64::from(max_age_days) * SECS_PER_DAY;
    let mut removed = Vec::new();
    match std::fs::read_dir(dir) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let meta = entry.metadata()?;
                if !meta.is_file() {
                    continue;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                let age = now - modified_unix(&meta);
                let old_tmp = name.ends_with(TMP_SUFFIX) && age >= TMP_MAX_AGE_SECS;
                let old_manual = max_age_days > 0
                    && name.ends_with(FILE_SUFFIX)
                    && dated(&name).is_none()
                    && age >= max_age;
                if old_tmp || old_manual {
                    remove_existing(entry.path(), &mut removed)?;
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    if let (true, Some(parent), Some(db_name)) =
        (max_age_days > 0, db_path.parent(), db_path.file_name())
    {
        let parent = if parent.as_os_str().is_empty() {
            Path::new(".")
        } else {
            parent
        };
        let prefix = format!("{}{BEFORE_RESTORE}", db_name.to_string_lossy());
        if let Ok(entries) = std::fs::read_dir(parent) {
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                let Some(rest) = name.strip_prefix(&prefix) else {
                    continue;
                };
                let at = rest
                    .trim_end_matches("-wal")
                    .trim_end_matches("-shm")
                    .parse::<i64>();
                if at.is_ok_and(|at| now - at >= max_age) && entry.file_type()?.is_file() {
                    remove_existing(entry.path(), &mut removed)?;
                }
            }
        }
    }
    removed.sort();
    Ok(removed)
}

fn remove_existing(path: PathBuf, removed: &mut Vec<PathBuf>) -> std::io::Result<()> {
    match std::fs::remove_file(&path) {
        Ok(()) => {
            removed.push(path);
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

fn modified_unix(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// N10.3: what the nightly backup needs from the volume before it writes: room for a copy
/// of the database (its file and WAL) plus the housekeeping floor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiskGuard {
    pub db_path: PathBuf,
    pub min_free_bytes: u64,
}

impl DiskGuard {
    /// `Err` with why when the backup would take the volume below the floor. Unknown free
    /// space (not Linux, no such directory) lets the backup run.
    pub fn check(&self, backup_dir: &Path) -> Result<(), String> {
        let db = file_len(&self.db_path) + file_len(&crate::ops::wal_path(&self.db_path));
        let need = db.saturating_add(self.min_free_bytes);
        match crate::housekeeping::free_bytes(backup_dir) {
            Some(free) if free < need => Err(format!(
                "{free} bytes free on the volume; a backup needs {db} plus the {} byte floor \
                 (housekeeping.min_free_mb)",
                self.min_free_bytes
            )),
            _ => Ok(()),
        }
    }
}

fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

/// N10.3: the dated backups and the newest one's age, for the stale check and
/// `admin backups`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Status {
    /// Oldest first.
    pub files: Vec<BackupFile>,
    pub total_bytes: u64,
    /// Seconds since the newest dated backup was written (`None`: there is none).
    pub newest_age_secs: Option<i64>,
    /// The newest backup is older than `max_age_hours`, or there is none.
    pub stale: bool,
}

impl Status {
    /// The newest dated backup (by date).
    pub fn newest(&self) -> Option<&BackupFile> {
        self.files.last()
    }
}

/// The dated backups in `dir` and whether the newest is older than `max_age_hours` at
/// `now` (a missing directory: no backups).
pub fn status(dir: &Path, now: i64, max_age_hours: u64) -> std::io::Result<Status> {
    let files = match list(dir) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(e),
    };
    let total_bytes = files.iter().map(|f| f.bytes).sum();
    let newest_age_secs = files
        .iter()
        .map(|f| f.modified_unix)
        .max()
        .map(|at| (now - at).max(0));
    let max_age = i64::try_from(max_age_hours)
        .unwrap_or(i64::MAX / SECS_PER_HOUR)
        .saturating_mul(SECS_PER_HOUR);
    Ok(Status {
        stale: newest_age_secs.is_none_or(|age| age > max_age),
        files,
        total_bytes,
        newest_age_secs,
    })
}

/// The scheduled task: sleeps until `time_utc`, backs up, repeats until cancelled.
pub async fn nightly(
    pool: SqlitePool,
    cfg: BackupConfig,
    guard: DiskGuard,
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
        run_and_record(&pool, &cfg, &guard, &metrics, clock::unix_now_secs()).await;
    }
}

/// One scheduled backup with its metrics, logs and the off-site hook. N10.3: skipped (an
/// error log, `wb_backups_skipped_total` and `wb_backups_failed_total`, nothing deleted)
/// when the volume has no room for it (`guard`).
pub async fn run_and_record(
    pool: &SqlitePool,
    cfg: &BackupConfig,
    guard: &DiskGuard,
    metrics: &Metrics,
    now: i64,
) -> Option<PathBuf> {
    if let Err(why) = guard.check(&cfg.dir) {
        Metrics::inc(&metrics.backups_skipped);
        Metrics::inc(&metrics.backups_failed);
        tracing::error!(reason = %why, "nightly backup skipped: not enough disk space");
        return None;
    }
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
    /// When it was written (its modification time, unix seconds).
    pub modified_unix: i64,
}

/// The `westbound-YYYY-MM-DD.db` files in `dir`, oldest first (others are ignored).
pub fn list(dir: &Path) -> std::io::Result<Vec<BackupFile>> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if dated(&name).is_some() {
            let meta = entry.metadata()?;
            if meta.is_file() {
                out.push(BackupFile {
                    name,
                    bytes: meta.len(),
                    modified_unix: modified_unix(&meta),
                });
            }
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

    fn names(paths: &[PathBuf]) -> Vec<String> {
        paths
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect()
    }

    fn set_mtime(path: &Path, unix: i64) {
        let t = std::time::UNIX_EPOCH + Duration::from_secs(u64::try_from(unix).unwrap());
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(t)
            .unwrap();
    }

    #[test]
    fn keeps_the_newest_dated_files_only() {
        let dir = tempfile::tempdir().unwrap();
        for name in [
            "westbound-2026-09-29.db",
            "westbound-2026-09-23.db",
            "westbound-2026-09-22.db",
            "westbound-2026-08-01.db",
            "westbound-not-a-date.db",
            "manual-2026-01-01.db",
            "notes.txt",
        ] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        // N10.3: a count, whatever the gaps between the dates.
        let removed = prune(dir.path(), 3, None).unwrap();
        assert_eq!(names(&removed), vec!["westbound-2026-08-01.db".to_string()]);
        let removed = prune(dir.path(), 1, None).unwrap();
        assert_eq!(
            names(&removed),
            vec!["westbound-2026-09-22.db", "westbound-2026-09-23.db"]
        );
        assert!(dir.path().join("westbound-2026-09-29.db").exists());
        for other in [
            "westbound-not-a-date.db",
            "manual-2026-01-01.db",
            "notes.txt",
        ] {
            assert!(dir.path().join(other).exists(), "{other}");
        }
        // 0 is read as 1: the newest backup always stays.
        assert!(prune(dir.path(), 0, None).unwrap().is_empty());
        // The file just written is never deleted, even with newer-dated files around (a
        // clock that went back).
        for name in ["westbound-2030-01-01.db", "westbound-2030-01-02.db"] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        let just_written = dir.path().join("westbound-2026-09-29.db");
        let removed = prune(dir.path(), 1, Some(&just_written)).unwrap();
        assert_eq!(names(&removed), vec!["westbound-2030-01-01.db".to_string()]);
        assert!(just_written.exists());
    }

    #[test]
    fn prunes_other_copies_by_age() {
        let dir = tempfile::tempdir().unwrap();
        let backups = dir.path().join("backups");
        std::fs::create_dir_all(&backups).unwrap();
        let db = dir.path().join("westbound.db");
        let now = clock::unix_now_secs();
        let day = SECS_PER_DAY;
        let files = [
            (backups.join("pre-deploy-old.db"), now - 8 * day),
            (backups.join("manual-recent.db"), now - day),
            (backups.join("westbound-2020-01-01.db"), now - 900 * day),
            (backups.join("westbound-2026-09-29.db.tmp"), now - 2 * day),
            (backups.join("westbound-2026-09-30.db.tmp"), now - 60),
            (backups.join("notes.txt"), now - 900 * day),
            (db.clone(), now - 900 * day),
        ];
        for (path, at) in &files {
            std::fs::write(path, b"x").unwrap();
            set_mtime(path, *at);
        }
        // Before-restore copies are aged by the time in their name (a rename keeps the
        // database's own modification time).
        let old = now - 8 * day;
        let recent = now - day;
        for name in [
            format!("westbound.db.before-restore-{old}"),
            format!("westbound.db.before-restore-{old}-wal"),
            format!("westbound.db.before-restore-{recent}"),
            "westbound.db.before-restore-garbage".to_string(),
        ] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        let removed = prune_other(&backups, &db, 7, now).unwrap();
        let mut expected = vec![
            format!("westbound.db.before-restore-{old}"),
            format!("westbound.db.before-restore-{old}-wal"),
            "pre-deploy-old.db".to_string(),
            "westbound-2026-09-29.db.tmp".to_string(),
        ];
        let mut got = names(&removed);
        expected.sort();
        got.sort();
        assert_eq!(got, expected);
        for kept in [
            backups.join("manual-recent.db"),
            backups.join("westbound-2020-01-01.db"),
            backups.join("westbound-2026-09-30.db.tmp"),
            backups.join("notes.txt"),
            db.clone(),
            dir.path()
                .join(format!("westbound.db.before-restore-{recent}")),
            dir.path().join("westbound.db.before-restore-garbage"),
        ] {
            assert!(kept.exists(), "{}", kept.display());
        }
        // 0 keeps them (stray .tmp files still go).
        std::fs::write(backups.join("x.tmp"), b"x").unwrap();
        set_mtime(&backups.join("x.tmp"), now - 2 * day);
        let removed = prune_other(&backups, &db, 0, now).unwrap();
        assert_eq!(names(&removed), vec!["x.tmp".to_string()]);
        // A missing backup directory is nothing to prune.
        assert!(prune_other(&dir.path().join("none"), &db, 7, now)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn status_reports_the_newest_backup_and_staleness() {
        let dir = tempfile::tempdir().unwrap();
        let now = clock::unix_now_secs();
        let none = status(&dir.path().join("missing"), now, 26).unwrap();
        assert!(none.files.is_empty() && none.stale && none.newest_age_secs.is_none());
        for (name, age_h) in [
            ("westbound-2026-09-28.db", 50),
            ("westbound-2026-09-29.db", 25),
        ] {
            let p = dir.path().join(name);
            std::fs::write(&p, b"abc").unwrap();
            set_mtime(&p, now - age_h * SECS_PER_HOUR);
        }
        let s = status(dir.path(), now, 26).unwrap();
        assert_eq!(s.files.len(), 2);
        assert_eq!(s.total_bytes, 6);
        assert_eq!(s.newest().unwrap().name, "westbound-2026-09-29.db");
        assert_eq!(s.newest_age_secs, Some(25 * SECS_PER_HOUR));
        assert!(!s.stale);
        assert!(
            status(dir.path(), now + 2 * SECS_PER_HOUR, 26)
                .unwrap()
                .stale
        );
    }

    #[tokio::test]
    async fn a_backup_without_room_is_skipped_and_deletes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let db = DbConfig {
            path: dir.path().join("westbound.db"),
            ..Default::default()
        };
        let pool = crate::db::connect(&db).await.unwrap();
        crate::db::migrate(&pool).await.unwrap();
        let cfg = BackupConfig {
            dir: dir.path().join("backups"),
            retention_days: 1,
            ..Default::default()
        };
        std::fs::create_dir_all(&cfg.dir).unwrap();
        let old = cfg.dir.join("westbound-2020-01-01.db");
        std::fs::write(&old, b"good").unwrap();
        let metrics = Metrics::default();
        let full = DiskGuard {
            db_path: db.path.clone(),
            min_free_bytes: u64::MAX / 2,
        };
        let now = clock::unix_now_secs();
        assert!(run_and_record(&pool, &cfg, &full, &metrics, now)
            .await
            .is_none());
        assert_eq!(Metrics::get(&metrics.backups_skipped), 1);
        assert_eq!(Metrics::get(&metrics.backups_failed), 1);
        assert!(old.exists(), "a skipped backup deletes nothing");
        assert_eq!(list(&cfg.dir).unwrap().len(), 1);
        // With room it runs, and the older backup beyond the count goes.
        let room = DiskGuard {
            min_free_bytes: 0,
            ..full
        };
        let path = run_and_record(&pool, &cfg, &room, &metrics, now)
            .await
            .unwrap();
        assert!(path.exists() && !old.exists());
        assert_eq!(Metrics::get(&metrics.backups_ok), 1);
        crate::db::close(&pool).await;
    }
}
